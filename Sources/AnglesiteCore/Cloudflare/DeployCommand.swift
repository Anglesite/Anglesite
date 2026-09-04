import Foundation

/// One-shot orchestrator for a site deploy — the provider-agnostic spine shared by every
/// `DeployTarget` (#1015): resolve the target's credential and run its fail-fast checks, build
/// `dist/`, run the non-bypassable `PreDeployCheck` pre-deploy scan, then hand off to the target
/// to publish. `CloudflareDeployTarget` is the only conformer today; `target` defaults to it so
/// every existing call site keeps compiling and deploying through Cloudflare unchanged.
///
/// A deploy is a single foreground action, run through the injected `DeployExecutor` seam for the
/// steps this spine owns directly (build, preflight). Container runtimes run the steps in a
/// guest; the default process-backed executor fails explicitly after embedded Node retirement.
///   1. `target.authorize(siteDirectory:)` — credential resolution plus any target-specific
///      fail-fast checks (e.g. Cloudflare's worker-name-conflict and domain-config-drift checks).
///      `.blocked` short-circuits immediately, before any build time is spent.
///   2. `executor.runBuildWithClaimManifest(…)` so `dist/` is fresh — the build carries the derived
///      `/.well-known/` claim manifest (#744/#748) so the runtime can reject a collision in its own
///      clone and report the artifacts it produced. An executor without the seam falls back to
///      `executor.run(step: .build, …)` and gets no post-build well-known verification.
///   3. `executor.run(step: .preflight, …)` — the bundled plugin's pre-deploy scan; its captured
///      stdout is parsed into a `PreDeployCheck.Outcome`. `.blocked` short-circuits with no
///      override (per CLAUDE.md, the app cannot bypass plugin security hooks) — and no
///      `DeployTarget` conformer gets a hook into this gate; `target.publish` is never called when
///      it blocks.
///   4. `target.publish(context:)` — publishes the build and performs any post-publish effects.
///      `CloudflareDeployTarget`'s conformance runs `executor.run(step: .wrangler, …)` and parses
///      the deployed URL out of the captured output.
///
/// The executor streams each step's stdout+stderr into `LogCenter` line-by-line (under the
/// caller-supplied source) and returns the accumulated stdout in `DeployStepResult.output`, so
/// URL/scan parsing re-reads the captured stdout rather than re-snapshotting `LogCenter`.
///
/// **Environment contract:**
///   - `.build` and `.preflight` get a curated subset of the host environment (see
///     `hostDeployEnvironment()`) — safe shell/locale/proxy/Node vars only, no unrelated secrets.
///     This same curated environment is handed to the target via `DeployTargetContext
///     .baseEnvironment`; `CloudflareDeployTarget.publish` adds `CLOUDFLARE_API_TOKEN` to it only
///     for the `.wrangler` (and `.bundleUpload`) steps it runs.
///
/// **Cancellation**: cancelling the deploy task propagates through `executor.run` (the host
/// executor awaits `ProcessSupervisor.waitForExitOrTerminate`, which SIGTERMs the in-flight
/// subprocess and returns only once it has exited), so a cancelled build/wrangler is actually
/// killed — and known to be dead by the time `.failed` comes back — rather than orphaned.
public actor DeployCommand {
    /// Terminal outcome of one `deploy(...)` call. Every failure mode is a case, not a thrown
    /// error — `deploy` never throws, so UI callers switch exhaustively over this instead of
    /// also maintaining a separate error path. `.workerNameConflict`/`.domainConfigDrift` are
    /// Cloudflare-specific outcomes `CloudflareDeployTarget` produces; a target with no equivalent
    /// concept simply never returns them.
    public enum Result: Sendable, Equatable {
        /// The target published successfully and a deployed URL was found. `duration` covers the
        /// target's publish step only — build and preflight time are excluded.
        case succeeded(url: URL, duration: TimeInterval)
        /// The pre-deploy security scan refused the deploy. Carries the structured
        /// failures (and any warnings) so the UI can render a sheet with no override.
        case blocked(failures: [PreDeployCheck.ScanFailure], warnings: [PreDeployCheck.ScanWarning])
        /// The candidate Worker name (`.site-config`'s `CF_PROJECT_NAME`) already exists on the
        /// connected Cloudflare account, and this site has never deployed before
        /// (`CF_WORKER_DEPLOYED` is not yet set in `.site-config`) — refusing to silently let
        /// `wrangler deploy` take over an unrelated (or stale) Worker. Carries the taken name for
        /// the UI's rename prompt (#740).
        case workerNameConflict(name: String)
        /// The site declares a `Source/anglesite.json` domain (#1169) whose live Cloudflare state
        /// has drifted from it (#1171) — refusing to ship against a domain/DNS/edge configuration
        /// the app no longer knows is accurate. Carries the findings so the UI can summarize them
        /// and point at the Domain Config Audit flow, where the owner reviews and reconciles
        /// before redeploying (investigation doc §5.5 — deploy-time validation is a cheap check,
        /// not a second remediation surface).
        case domainConfigDrift(findings: [DomainConfigAudit.Finding])
        /// `exitCode` is `nil` for pre-spawn refusals (no credential, no wrangler) and for spawn
        /// failures; otherwise it's the failing subprocess's exit code (including `0` for the
        /// "wrangler exited cleanly but we couldn't find a URL" case).
        case failed(reason: String, exitCode: Int32?)
    }

    /// How to run a subprocess for a site directory — or why it can't be run.
    public enum LaunchPlan: Sendable, Equatable {
        /// Spawn `executable` with `arguments` (the caller supplies cwd and environment).
        case run(executable: URL, arguments: [String])
        /// The command can't run at all in this configuration; `reason` is user-facing text
        /// (e.g. `HostNodeRetirement`'s explanation) surfaced instead of a spawn attempt.
        case unavailable(reason: String)
    }

    /// Maps a site directory to how — or whether — a deploy-related subprocess can run there.
    /// The host-side defaults on this type (`resolveBuildCommand`, `resolveWranglerCommand`) all
    /// return `.unavailable` since embedded Node was retired; container runtimes inject real
    /// resolvers.
    public typealias CommandResolver = @Sendable (_ siteDirectory: URL) -> LaunchPlan
    /// Runs the bundled plugin's pre-deploy scan against a site and returns the outcome.
    /// Real callers use `DeployCommand.defaultPreflight`; tests inject a fake.
    public typealias PreflightChecker = @Sendable (_ siteDirectory: URL) async -> PreDeployCheck.Outcome
    /// Fires once the preflight step resolves, with the outcome that was used to
    /// decide whether to continue with the target's publish step. The closure runs inside the
    /// actor's isolation; bridge to MainActor via a Task if you need to touch SwiftUI state.
    /// Fires for every preflight result (.passed, .blocked, .error) — including the
    /// cases where deploy() returns .failed afterwards.
    public typealias PreflightObserver = @Sendable (PreDeployCheck.Outcome) -> Void

    /// Fires once the domain-attach step resolves (#1077), for a "Transfer an existing domain"
    /// site — or immediately with `.skipped` for every other site. Only fired by
    /// `CloudflareDeployTarget`, and only after a successful `wrangler` step; never fires on a
    /// failed/blocked deploy, and never fires for a target with no equivalent concept.
    public typealias DomainAttachObserver = @Sendable (CustomDomainAttachCommand.Result) -> Void

    /// Fires once the Markdown for Agents step resolves (#1247) — only for a site whose domain
    /// attach just confirmed a live zone; never fires when there's no custom domain, or on a
    /// failed/blocked deploy. Only fired by `CloudflareDeployTarget`.
    public typealias MarkdownForAgentsObserver = @Sendable (MarkdownForAgentsCommand.Result) -> Void

    /// How this command picks the target it publishes through — by default, whatever the site
    /// itself declares in `Source/anglesite.json` (`DeployTargetSelection.fromSiteConfig`, #1682),
    /// which is Cloudflare for every site that predates the `deployTarget` field.
    ///
    /// Deliberately *not* exposed: a caller that needs the selection reads it once through
    /// ``target(for:)`` and freezes it with ``pinning(target:)``, so it can't end up performing a
    /// second, independent resolution that disagrees with this command's own.
    private nonisolated let targetResolver: DeployTargetSelection.Resolver
    private let executor: any DeployExecutor

    /// The target `deploy(siteID:siteDirectory:…)` would publish `siteDirectory` through.
    ///
    /// Public so a caller that needs the concrete conformer for a companion command can downcast
    /// to reach its own exposed seams (`CloudflareDeployTarget.tokenSource`,
    /// `workerScriptNamesSource`, …) — see `DeployModel.runDeploy`'s
    /// `SocialWorkerProvisionCommand` wiring.
    ///
    /// - Parameter siteDirectory: The site's `Source/` directory, the same value `deploy` takes.
    /// - Returns: The conformer this command would publish that site through — freshly built on
    ///   each call, since the default resolver reads the site's declaration from disk.
    public nonisolated func target(for siteDirectory: URL) -> any DeployTarget {
        targetResolver(siteDirectory)
    }

    /// Both dependencies are injectable seams with production defaults, so tests can drive a full
    /// deploy — target selection, target authorization, every shared step — with a scripted
    /// resolver and a scripted executor, never touching the network or spawning a process.
    public init(
        targetResolver: @escaping DeployTargetSelection.Resolver = DeployTargetSelection.fromSiteConfig,
        executor: any DeployExecutor = HostDeployExecutor()
    ) {
        self.targetResolver = targetResolver
        self.executor = executor
    }

    /// Pins one target for every site this command deploys, bypassing the site's own declaration.
    /// For a caller whose deploy is target-specific by construction — `SocialWorkerProvisionCommand`'s
    /// Cloudflare-only publish — and for tests driving a scripted conformer.
    public init(target: any DeployTarget, executor: any DeployExecutor = HostDeployExecutor()) {
        self.init(targetResolver: { _ in target }, executor: executor)
    }

    /// This command with its selection frozen to `target`, keeping its executor.
    ///
    /// For an orchestrator that needs the concrete conformer *before* calling
    /// `deploy(siteID:siteDirectory:…)` — see `DeployModel.runDeploy`, which downcasts to
    /// `CloudflareDeployTarget` to build `SocialWorkerProvisionCommand`'s two Cloudflare-only
    /// closures. Resolving once and pinning the result is what makes that method's "read once, so
    /// authorization and the publish hand-off can't disagree" guarantee hold across the *outer*
    /// call too: without it the orchestrator's read and the deploy's own read are two independent
    /// disk reads separated by several `await`s, and an owner flipping Website Settings ▸
    /// Publishing in between would leave the closures resolved against a different target than
    /// the one this command publishes through.
    ///
    /// - Parameter target: The conformer to publish every site through, normally the result of
    ///   ``target(for:)`` for the site this attempt is about to deploy.
    public nonisolated func pinning(target: any DeployTarget) -> DeployCommand {
        DeployCommand(target: target, executor: executor)
    }

    /// Run a deploy for `siteID`. Returns once the target's publish step has resolved (or before,
    /// if the target's authorization step or the preflight gate refuses first). Build output
    /// streams under source `"deploy:<siteID>:build"`, the deploy itself under `"deploy:<siteID>"`,
    /// so a UI consumer can distinguish phases.
    public func deploy(
        siteID: String,
        siteDirectory: URL,
        /// The site's `Config/` directory. `nil` skips route-coverage scanning and the
        /// deployed-routes snapshot write entirely — callers that don't pass it (tests, and the
        /// two non-primary deploy paths in `SocialWorkerProvisionCommand`/`SiteOperations`) are
        /// unaffected (#530).
        configDirectory: URL? = nil,
        /// The site's currently published route set (from `SiteContentGraph`), used only when
        /// `configDirectory` is non-nil.
        currentRoutes: [String] = [],
        /// Effective active dynamic `/.well-known/` route claims (#746), already validated via
        /// `WorkerRouteClaims.activeClaims` and filtered with `WorkerRouteClaims.wellKnownClaims`.
        /// Empty means "no active dynamic well-known routes," not "skip the #744 collision check"
        /// — the check always runs, using whatever this array and `executor.reportOwnedPathClaims()`
        /// report.
        wellKnownDynamicClaims: [WorkerRouteClaims.OwnedClaim] = [],
        onPreflight: PreflightObserver? = nil,
        onDomainAttach: DomainAttachObserver? = nil,
        onMarkdownForAgents: MarkdownForAgentsObserver? = nil,
        onProgress: ProgressHandler? = nil
    ) async -> Result {
        // Which host this site publishes to (#1682) — read once, here, so authorization and the
        // publish hand-off below can't disagree about the target even if the site's declaration
        // changes mid-deploy.
        let target = targetResolver(siteDirectory)

        // Pre-build gate: the target resolves its credential and runs any fail-fast checks
        // against current deployed state, so a deploy that can't succeed never spends time on a
        // build or scan. The credential comes back opaque here — only the target that produced it
        // knows what to do with it.
        let credential: String
        switch await target.authorize(siteDirectory: siteDirectory) {
        case .blocked(let result):
            return result
        case .ready(let resolvedCredential):
            credential = resolvedCredential
        }

        // Curated environment for the non-secret steps: a safe subset of the host process env,
        // stripping unrelated secrets the developer's shell may carry. Target-specific
        // credentials are added only inside the target's own `publish(context:)`.
        let baseEnvironment = Self.hostDeployEnvironment()

        // #744: validate the effective /.well-known/ inventory before spending time on a build.
        // Static/generated rows come from whatever's already on disk in Source/public/.well-known/
        // (which mirrors the guest's clone — see ContainerDeployExecutor's HOST-path doc comment,
        // and note `scanUserStatic` classifies a previously-generated file like security.txt by its
        // own marker, so a redeploy sees it correctly without this re-deriving the TS generator's
        // activation logic); dynamic rows from the caller's already-validated active route claims;
        // runtime rows from whatever this executor can affirmatively prove it owns (empty when
        // unsupported or when the runtime reports no claims — either way, no reservation). A
        // collision blocks the deploy immediately with no override, matching the design doc's "no
        // collision precedence" (docs/superpowers/specs/2026-07-14-well-known-support-design.md).
        // Non-fatal scan findings (a rejected symlink/oversized/percent-encoded file) are folded
        // into the preflight outcome's warnings below rather than blocking.
        let wellKnownScan = WellKnownInventory.scanUserStatic(
            wellKnownDirectory: siteDirectory.appendingPathComponent("public/.well-known", isDirectory: true))
        let wellKnownRuntimeRows = WellKnownInventory.runtimeRows(from: await executor.reportOwnedPathClaims())
        let wellKnownDynamicRows = WellKnownInventory.dynamicRows(from: wellKnownDynamicClaims)
        let wellKnownInventory: [WellKnownEndpointDescriptor]
        do {
            wellKnownInventory = try WellKnownInventory.merge(
                userStatic: wellKnownScan.rows.filter { $0.delivery == .userStatic },
                generated: wellKnownScan.rows.filter { $0.delivery == .generated },
                dynamic: wellKnownDynamicRows,
                runtime: wellKnownRuntimeRows)
        } catch {
            let failure = PreDeployCheck.ScanFailure(
                category: .wellKnownCollision,
                message: "\(error)",
                remediation: "Resolve the /.well-known/ ownership conflict named above (rename or remove one of the claims), then redeploy."
            )
            let outcome = PreDeployCheck.Outcome.blocked(failures: [failure], warnings: [])
            onPreflight?(outcome)
            return .blocked(failures: [failure], warnings: [])
        }
        let wellKnownScanWarnings = wellKnownScan.findings.map {
            PreDeployCheck.ScanWarning(
                category: .wellKnownArtifact, message: $0.message,
                file: $0.path.map { "public/.well-known/\($0)" })
        }

        // Build dist/ before the scan needs it. Streams to LogCenter via the executor.
        //
        // #744/#748 build seam: when the executor implements it, the build runs with the derived
        // claim manifest so the runtime can (a) rescan its OWN clone before any generator writes —
        // catching a collision the host's working-tree scan above could not see — and (b) report
        // the exact `dist/.well-known/...` artifacts it produced. An executor that returns
        // `.unsupported` falls back to the plain build step and gets NO post-build verification;
        // we must not claim protection that never ran.
        onProgress?(.deployBuilding)
        var wellKnownArtifactWarnings: [PreDeployCheck.ScanWarning] = []
        let buildResult: DeployStepResult
        switch await executor.runBuildWithClaimManifest(
            siteDirectory: siteDirectory,
            environment: baseEnvironment,
            source: "deploy:\(siteID):build",
            claimManifest: WellKnownInventory.claimManifest(from: wellKnownInventory)
        ) {
        case .unsupported:
            buildResult = await executor.run(
                step: .build,
                siteDirectory: siteDirectory,
                environment: baseEnvironment,
                source: "deploy:\(siteID):build"
            )
        case .cancelled:
            return .failed(reason: "build was terminated", exitCode: nil)
        case .completed(let stepResult, let seamResult):
            buildResult = stepResult
            // A failed build that still reported findings is the runtime's own collision rejection
            // (`scripts/well-known.ts check` writes ONLY the blocking findings before exiting
            // non-zero). Surface it as a `.blocked` security outcome with both owners named, not as
            // an opaque "npm run build failed (exit 1)".
            if stepResult.exitCode != 0, !seamResult.findings.isEmpty {
                let failures = seamResult.findings.map {
                    PreDeployCheck.ScanFailure(
                        category: .wellKnownCollision,
                        message: $0.message,
                        file: $0.path.map { "public/.well-known/\($0)" },
                        remediation: "Resolve the /.well-known/ ownership conflict named above (rename or remove one of the claims), then redeploy.")
                }
                let outcome = PreDeployCheck.Outcome.blocked(failures: failures, warnings: [])
                onPreflight?(outcome)
                return .blocked(failures: failures, warnings: [])
            }
            wellKnownArtifactWarnings = WellKnownInventory.verifyBuildArtifacts(
                expected: wellKnownInventory, result: seamResult
            ).map {
                PreDeployCheck.ScanWarning(
                    category: .wellKnownArtifact, message: $0.message,
                    file: $0.path.map { "dist/.well-known/\($0)" })
            }
        }
        guard buildResult.exitCode == 0 else {
            if let code = buildResult.exitCode {
                return .failed(reason: "npm run build failed (exit \(code))", exitCode: code)
            }
            // nil exit code → unavailable resolver, spawn failure, or termination (cancellation).
            if Task.isCancelled {
                return .failed(reason: "build was terminated", exitCode: nil)
            }
            // The executor put the reason (unavailable/spawn) in `output`.
            return .failed(reason: buildResult.output.isEmpty ? "build was terminated" : buildResult.output, exitCode: nil)
        }

        // Pre-deploy scan runs after the build (so dist/ exists) and before the target's publish
        // step. If the bundled plugin's checks find PII, exposed tokens, unauthorized third-party
        // scripts, or Keystatic admin routes in dist/, the deploy is blocked — per the durable
        // rule in CLAUDE.md, the app cannot bypass plugin security hooks; the UI sheet for
        // `.blocked` has no override, and no `DeployTarget` conformer gets a hook here.
        onProgress?(.deployPreflight)
        let preflightResult = await executor.run(
            step: .preflight,
            siteDirectory: siteDirectory,
            environment: baseEnvironment,
            source: "deploy:\(siteID):preflight"
        )
        var preflightOutcome = Self.parseScanReport(output: preflightResult.output, exitCode: preflightResult.exitCode)
        // Swift-computed warnings, not emitted by the JS scan script — merged into the outcome
        // the same way `RouteCoverageScanner`'s `.orphanedRoute` findings always have been.
        var extraWarnings = wellKnownScanWarnings + wellKnownArtifactWarnings
        if let configDirectory {
            let previousRoutes = DeployedRoutesSnapshot.load(from: configDirectory)
            let redirects = (try? RedirectsStore(sourceDirectory: siteDirectory).load()) ?? []
            extraWarnings += RouteCoverageScanner.scan(
                currentRoutes: currentRoutes,
                previousRoutes: previousRoutes,
                redirectSources: Set(redirects.map(\.source))
            )
        }
        if !extraWarnings.isEmpty {
            switch preflightOutcome {
            case .passed(let warnings):
                preflightOutcome = .passed(warnings: warnings + extraWarnings)
            case .blocked(let failures, let warnings):
                preflightOutcome = .blocked(failures: failures, warnings: warnings + extraWarnings)
            case .error:
                break
            }
        }
        onPreflight?(preflightOutcome)
        switch preflightOutcome {
        case .passed:
            break
        case .blocked(let failures, let warnings):
            return .blocked(failures: failures, warnings: warnings)
        case .error(let reason):
            return .failed(reason: "pre-deploy scan could not run: \(reason)", exitCode: nil)
        }

        // Hand off to the target: publish the build and perform any post-publish effects
        // (Cloudflare's URL extraction, custom-domain attach, Markdown for Agents, `.site-config`
        // persistence, R2 bundle upload — see `CloudflareDeployTarget.publish`).
        let context = DeployTargetContext(
            siteID: siteID,
            siteDirectory: siteDirectory,
            configDirectory: configDirectory,
            currentRoutes: currentRoutes,
            credential: credential,
            baseEnvironment: baseEnvironment,
            executor: executor,
            onDomainAttach: onDomainAttach,
            onMarkdownForAgents: onMarkdownForAgents,
            onProgress: onProgress
        )
        return await target.publish(context: context)
    }

    // MARK: Scan report parsing

    /// Parses the captured stdout of the pre-deploy scan (`scripts/pre-deploy-check.ts --json`)
    /// into a `PreDeployCheck.Outcome`. Thin forwarding wrapper — `PreDeployCheck.parse` is the
    /// one real decoder (#742); this keeps the existing public call-site signature stable.
    public static func parseScanReport(output: String, exitCode: Int32?) -> PreDeployCheck.Outcome {
        PreDeployCheck.parse(output: output, exitCode: exitCode)
    }

    // MARK: Host environment curation

    /// Keys that a host-path build or preflight step legitimately needs. The allowlist is
    /// intentionally conservative — add a key only when a build script demonstrably requires it.
    /// Mirrors the tight `guestEnvAllowlist` in `ContainerDeployExecutor`, adapted for the host
    /// where Node/npm/Astro rely on the user's shell plumbing.
    private static let hostEnvAllowlist: Set<String> = [
        // Shell / process fundamentals
        "PATH", "HOME", "USER", "LOGNAME", "SHELL",
        // Temp directories — Node/npm/Astro write to these
        "TMPDIR", "TEMP", "TMP",
        // CI — Astro, Vite, and many post-install scripts check this to suppress interactive prompts
        "CI",
        // Locale — affects sorting, date formatting in build output
        "LANG", "LC_ALL", "LC_COLLATE", "LC_CTYPE", "LC_MESSAGES", "LC_MONETARY",
        "LC_NUMERIC", "LC_TIME",
        // Proxy — corporate/VPN environments need these for npm registry + API fetches
        "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY",
        "http_proxy", "https_proxy", "no_proxy",
        // Node-specific
        "NODE_ENV", "NODE_OPTIONS", "NODE_PATH", "NODE_EXTRA_CA_CERTS", "NPM_CONFIG_CACHE",
        // XDG — npm/pnpm/yarn respect these for cache and config paths
        "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME",
        // Terminal — some build tools check these for color/width
        "TERM", "COLORTERM", "COLUMNS",
    ]

    /// Key prefixes that Astro/Vite projects use for build-time environment variables. These are
    /// standard conventions for variables inlined into client-side output (`PUBLIC_*`) or consumed
    /// by Vite's pipeline (`VITE_*`). Users set them in their shell and expect them to flow through
    /// to `astro build`. `ASTRO_` covers Astro's own config overrides (e.g. `ASTRO_TELEMETRY_DISABLED`).
    private static let hostEnvPrefixes: [String] = ["PUBLIC_", "VITE_", "ASTRO_"]

    /// Returns a curated subset of the given environment safe for host-path build and preflight
    /// steps. Strips unrelated secrets (`AWS_SECRET_ACCESS_KEY`, `GITHUB_TOKEN`, …) that the
    /// developer's shell may carry. Target-specific credentials are excluded here; the target adds
    /// its own only to the steps it runs inside `publish(context:)`.
    ///
    /// The `env` parameter defaults to the current process environment; tests inject a literal
    /// dictionary instead (avoiding `setenv`/`unsetenv` races and the `ProcessInfo` launch-time
    /// snapshot issue).
    static func hostDeployEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        env.filter { key, _ in
            hostEnvAllowlist.contains(key) ||
            hostEnvPrefixes.contains(where: { key.hasPrefix($0) })
        }
    }

    // MARK: Default seams

    /// Default `PreflightChecker`: host-side preflight was retired with embedded Node. Container
    /// runtimes must provide the executable preflight path.
    public static let defaultPreflight: PreflightChecker = { siteDirectory in
        .error(reason: HostNodeRetirement.reason("pre-deploy check"))
    }

    /// Default `CommandResolver`: host-side wrangler deploy was retired with embedded Node.
    public static let resolveWranglerCommand: CommandResolver = { siteDirectory in
        .unavailable(reason: HostNodeRetirement.reason("wrangler deploy"))
    }

    /// Default `BuildCommandResolver`: host-side site build was retired with embedded Node.
    public static let resolveBuildCommand: CommandResolver = { siteDirectory in
        .unavailable(reason: HostNodeRetirement.reason("site build"))
    }
}
