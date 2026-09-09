import Foundation

// MARK: - Types

/// Identifies one logical step in the deploy sequence.
public enum DeployStep: Sendable {
    /// `npm run build` — produces `dist/`.
    case build
    /// `npx tsx scripts/pre-deploy-check.ts --json` — the bundled plugin's security scan.
    case preflight
    /// `wrangler deploy` — publishes the built site to Cloudflare Workers.
    case wrangler
    /// Tars `Source/` and uploads it to the site's configured R2 bucket via `wrangler r2 object
    /// put` — the code side of a future Worker-triggered bake (#799, spec §C.4). Only reached
    /// when `SiteSettings.sourceBundleBucket` is set (#1960); `CloudflareDeployTarget` skips this
    /// step entirely otherwise (today, for every site — no provisioning flow writes it yet).
    case bundleUpload
    /// Force-pushes the built `dist/` to the site's dedicated GitHub Pages repo (#1015 slice 2a),
    /// declared in `Source/anglesite.json`'s `githubPages` section. Only meaningful for
    /// `ContainerDeployExecutor` — `dist/` lives in the guest's filesystem, never synced to the
    /// host, so this step (like `.wrangler`) must run in-guest. Not yet reached by any
    /// `DeployTarget` — the conformer that calls it is a later slice.
    case githubPagesPublish
    /// An arbitrary `wrangler <args>` subcommand outside the fixed pipeline — `d1 create`,
    /// `kv namespace create`, `queues create`, `d1 migrations apply`, etc. Used by
    /// `SocialWorkerProvisionTarget`'s resource-creation sequence (#1821) so those calls run
    /// through the same executor abstraction as `.wrangler`/`.bundleUpload`, instead of a
    /// separately-injected `CommandRunner` seam.
    case wranglerSubcommand(args: [String])
}

/// The result of running a single deploy step.
///
/// - `exitCode`: the process exit code, or `nil` for pre-spawn failures (resolver reported
///   `.unavailable`, or the process could not be spawned at all). Mirrors the `exitCode`
///   convention in `DeployCommand.Result.failed`.
/// - `output`: captured stdout, used for URL/scan parsing by the caller. Also streamed
///   line-by-line to `LogCenter` under the caller-supplied source during execution.
public struct DeployStepResult: Sendable, Equatable {
    /// The process exit code, or `nil` for pre-spawn failures — see the type-level convention
    /// above.
    public let exitCode: Int32?
    /// Captured stdout for the caller to parse — see the type-level note above; the same lines
    /// were already streamed live to `LogCenter` during execution.
    public let output: String

    /// Memberwise initializer — public so executors in other files (and test fakes) can
    /// construct results directly.
    public init(exitCode: Int32?, output: String) {
        self.exitCode = exitCode
        self.output = output
    }
}

// MARK: - Protocol

/// Abstraction over the execution substrate for one deploy step.
///
/// `HostDeployExecutor` is retained as the generic process-backed executor for tests and injected
/// tooling. Its production defaults fail explicitly after host Node retirement; deploys should use
/// `ContainerDeployExecutor` once a container control is available.
///
/// The `source` parameter is the `LogCenter` source tag (e.g. `"deploy:<id>:build"`,
/// `"deploy:<id>"`). Callers supply it so the right log row receives the output.
public protocol DeployExecutor: Sendable {
    /// Runs one deploy step at `siteDirectory`, streaming output to `LogCenter` under `source`.
    ///
    /// Deliberately non-throwing: every failure mode (unavailable substrate, spawn failure,
    /// non-zero exit, cancellation) is encoded in ``DeployStepResult`` instead, so
    /// ``DeployCommand`` renders one uniform failure path rather than juggling thrown errors
    /// alongside exit codes.
    func run(
        step: DeployStep,
        siteDirectory: URL,
        environment: [String: String],
        source: String
    ) async -> DeployStepResult

    /// Paths this deploy provider affirmatively owns (e.g. ACME managed-TLS challenge paths) —
    /// see docs/superpowers/specs/2026-07-14-well-known-support-design.md. Defaults to no claims;
    /// override only when this executor can prove ownership, never speculatively.
    func reportOwnedPathClaims() async -> [RuntimeOwnedPathClaim]

    /// Runs the `.build` step with `claimManifest` made available to the build, returning the
    /// observed `.well-known` artifact inventory and findings alongside the normal step result.
    /// Defaults to `.unsupported` — #744 must not claim cross-owner collision protection when
    /// this returns `.unsupported`.
    func runBuildWithClaimManifest(
        siteDirectory: URL,
        environment: [String: String],
        source: String,
        claimManifest: WellKnownClaimManifest
    ) async -> WellKnownBuildSeamOutcome
}

public extension DeployExecutor {
    /// Default: no claims — an executor must override to opt in only when it can prove path
    /// ownership (see the requirement's doc), so a new executor never inherits a speculative
    /// claim by accident.
    func reportOwnedPathClaims() async -> [RuntimeOwnedPathClaim] { [] }

    /// Default: `.unsupported`, so callers can tell "this substrate has no manifest seam" apart
    /// from a build that ran and produced no findings — the distinction #744's cross-owner
    /// collision protection depends on (see the requirement's doc).
    func runBuildWithClaimManifest(
        siteDirectory: URL,
        environment: [String: String],
        source: String,
        claimManifest: WellKnownClaimManifest
    ) async -> WellKnownBuildSeamOutcome {
        .unsupported
    }
}

// MARK: - ContainerDeployExecutor

/// Runs deploy steps inside a running container via `LocalContainerControl.exec`.
///
/// The site is cloned to `/workspace/site` in the guest at boot time; Node 22 and the
/// site's `node_modules` are already installed there. Each step is mapped to an in-guest
/// argv and executed at that working directory.
///
/// `CLOUDFLARE_API_TOKEN` is forwarded through the `environment` dict that the caller
/// supplies — it is never added here and never written to logs.
public struct ContainerDeployExecutor: DeployExecutor {
    private let control: any LocalContainerControl
    private let siteID: String
    private let configDirectory: URL
    private let logCenter: LogCenter

    /// Creates an executor that runs steps in `siteID`'s container through `control`.
    /// `configDirectory` is the site package's `Config/` — the host home of the generated
    /// `wrangler.toml` this executor stages into the guest before every wrangler call that reads
    /// it, and of `SiteSettings.sourceBundleBucket` (#1960). `logCenter` is injectable for tests;
    /// production uses the shared instance.
    public init(
        control: any LocalContainerControl,
        siteID: String,
        configDirectory: URL,
        logCenter: LogCenter = .shared
    ) {
        self.control = control
        self.siteID = siteID
        self.configDirectory = configDirectory
        self.logCenter = logCenter
    }

    // MARK: DeployExecutor

    /// Runs `step` in the guest at `/workspace/site`, streaming output live to `LogCenter`.
    ///
    /// `siteDirectory` is the HOST path — the guest always executes in its own boot-time clone.
    /// The host path is consulted only where the clone can be stale or incomplete: the
    /// `Config/wrangler.toml` staging before every wrangler call that reads configuration (#1084,
    /// #1960), and `SiteSettings.sourceBundleBucket` for `.bundleUpload` (see the inline
    /// rationale for both).
    public func run(
        step: DeployStep,
        siteDirectory: URL,
        environment: [String: String],
        source: String
    ) async -> DeployStepResult {
        // `siteDirectory` is the HOST path — the guest always uses /workspace/site.
        //
        // #1084/#1960: `/workspace/site` is a `git clone` of the site's `Source/` repo, and since
        // #1960 that repo carries no `wrangler.toml` at all — the site's concrete config (worker
        // bindings, `main`, resource ids) lives in the package's `Config/`, which the guest never
        // sees. Every wrangler invocation that reads configuration therefore gets the host's
        // current `Config/wrangler.toml` staged into the guest's working directory first:
        // `wrangler deploy` (without it, an assets-only Worker with no `main` script would be
        // published — every dynamic route 404s and `wrangler tail` refuses to attach), and the
        // `.wranglerSubcommand` steps (`d1 migrations apply <BINDING>` resolves the binding from
        // the config; `d1/kv/r2/queues create` merely warn without one). `astro build` and the
        // preflight scan never read `wrangler.toml` (confirmed against `Resources/Template`), so
        // staging before them would be pure overhead. The staged copy is gitignored in the guest
        // (the template's `.gitignore` lists it), so it can never travel back into the repo.
        if Self.stepReadsWranglerConfig(step) {
            if let syncArgv = WranglerInvocation.configStagingArgv(configDirectory: configDirectory) {
                do {
                    let syncResult = try await control.exec(
                        siteID: siteID,
                        argv: syncArgv,
                        environment: [:],
                        workingDirectory: "/workspace/site",
                        onOutput: { _, _ in }
                    )
                    guard syncResult.exitCode == 0 else {
                        return DeployStepResult(
                            exitCode: nil,
                            output: "couldn't sync wrangler.toml into the container (exit \(syncResult.exitCode))"
                        )
                    }
                } catch is CancellationError {
                    return DeployStepResult(exitCode: nil, output: "")
                } catch {
                    return DeployStepResult(exitCode: nil, output: "couldn't sync wrangler.toml into the container: \(error)")
                }
            }
            // No host file (a site never scaffolded for deploy): nothing to stage; wrangler
            // reports the missing configuration itself, exactly as before #1960.
        }
        // Stream guest output to LogCenter LIVE (matching the host path) and drain fully on every
        // exit path (success or thrown error) — `WranglerInvocation.exec` (#1821) owns that
        // AsyncStream/detached-task mechanics now, so there's no local `continuation`/`drain` to
        // finish here; a `catch` below must NOT attempt to drain again. Never log the environment
        // dict — CLOUDFLARE_API_TOKEN stays off disk and out of logs.
        let argv = Self.guestArgv(for: step, siteDirectory: siteDirectory, configDirectory: configDirectory)
        let result: ContainerExecResult
        do {
            result = try await WranglerInvocation.exec(
                control: control, siteID: siteID, argv: argv,
                environment: Self.guestEnvironment(from: environment, step: step),
                logCenter: logCenter, source: source)
        } catch is CancellationError {
            // A cancelled deploy: surface a termination (nil exitCode, empty output).
            // `DeployCommand` checks `Task.isCancelled` and renders "terminated" — we must NOT bury
            // cancellation under a generic exec-error string. (The `DeployExecutor` seam is
            // non-throwing, so we signal termination via the nil/empty result rather than
            // re-throwing; `Task.isCancelled` carries the intent.)
            return DeployStepResult(exitCode: nil, output: "")
        } catch let error as LocalContainerError {
            // A dead/never-booted container surfaces as `.bootFailed`; give the user an actionable
            // message instead of the raw error (the Deploy-button gating half lives app-side).
            if case .bootFailed = error {
                return DeployStepResult(
                    exitCode: nil,
                    output: "Container isn't running — open/start the site's preview first.")
            }
            return DeployStepResult(exitCode: nil, output: "couldn't exec in the container: \(error)")
        } catch let error {
            return DeployStepResult(exitCode: nil, output: "couldn't exec in the container: \(error)")
        }
        // `.wranglerSubcommand` needs the same stdout-or-stderr fallback
        // `SocialWorkerProvisionCommand.runWrangler` relied on before this refactor (a failed wrangler
        // subcommand can write its error to stderr with empty stdout, e.g. a name-conflict on `d1
        // create`) — every other step keeps stdout-only capture, its existing behavior.
        if case .wranglerSubcommand = step {
            return DeployStepResult(exitCode: result.exitCode, output: result.stdout.isEmpty ? result.stderr : result.stdout)
        }
        return DeployStepResult(exitCode: result.exitCode, output: result.stdout)
    }

    // MARK: Well-known claim manifest seam (#748)

    /// Marks the boundary in `.build` stdout between ordinary build output and the seam's JSON
    /// result blob. `wellKnownSeamArgv`'s guest script echoes this line itself, after the build
    /// exits — a future template-side consumer (#744) only needs to write its result JSON to
    /// `wellKnownResultGuestPath`; it must NOT also echo this marker itself, or the script's own
    /// `cat` would emit it twice and break the host-side split.
    static let wellKnownResultMarker = "---ANGLESITE-WELLKNOWN-RESULT---"
    /// Guest-side scratch path for the incoming manifest — deliberately under `/tmp`, never
    /// `/workspace/site` (the guest's clone of `Source/`).
    static let wellKnownManifestGuestPath = "/tmp/anglesite-wellknown-manifest.json"
    /// Guest-side scratch path a future build script writes its result JSON to — also `/tmp`,
    /// for the same "never inside Source/" reason.
    static let wellKnownResultGuestPath = "/tmp/anglesite-wellknown-result.json"

    /// Runs the `.build` step with the #748 claim manifest delivered through `/tmp` scratch
    /// files in the guest (never `/workspace/site` — see the path constants above), then splits
    /// the seam's JSON result blob out of stdout at the marker line so the ordinary build output
    /// still reaches the caller intact. An encode failure or exec error degrades to
    /// `.completed` with an empty seam result rather than throwing — same non-throwing contract
    /// as ``run(step:siteDirectory:environment:source:)``.
    public func runBuildWithClaimManifest(
        siteDirectory: URL,
        environment: [String: String],
        source: String,
        claimManifest: WellKnownClaimManifest
    ) async -> WellKnownBuildSeamOutcome {
        guard let manifestData = try? JSONEncoder().encode(claimManifest) else {
            return .completed(
                DeployStepResult(exitCode: nil, output: "couldn't encode well-known claim manifest"),
                WellKnownBuildSeamResult())
        }
        let argv = Self.wellKnownSeamArgv(manifestBase64: manifestData.base64EncodedString())

        // `WranglerInvocation.exec` (#1821) owns the stream-to-LogCenter/drain mechanics now — it
        // drains fully on both the success and throw paths, so there's no local
        // `continuation`/`drain` to finish here.
        let result: ContainerExecResult
        do {
            result = try await WranglerInvocation.exec(
                control: control, siteID: siteID, argv: argv,
                environment: Self.guestEnvironment(from: environment, step: .build),
                logCenter: logCenter, source: source)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .completed(
                DeployStepResult(exitCode: nil, output: "couldn't exec in the container: \(error)"),
                WellKnownBuildSeamResult())
        }

        let outputLines = result.stdout.components(separatedBy: "\n")
        let seamResult: WellKnownBuildSeamResult
        let buildOutput: String
        // `lastIndex`, not `firstIndex`: the guest script echoes this marker exactly once, as the
        // last thing it does before `cat`-ing the result file (see `wellKnownSeamArgv` below), so
        // the real split point is always the LAST occurrence in stdout. `firstIndex` would
        // misparse if `npm run build`'s own output ever coincidentally contained this exact line,
        // or if a future #744 build script violated the "never echo this marker yourself"
        // contract documented on `wellKnownResultMarker` above.
        if let markerIndex = outputLines.lastIndex(of: Self.wellKnownResultMarker) {
            buildOutput = outputLines[..<markerIndex].joined(separator: "\n")
            seamResult = .parsing(outputLines[(markerIndex + 1)...].joined(separator: "\n"))
        } else {
            buildOutput = result.stdout
            seamResult = WellKnownBuildSeamResult()
        }
        return .completed(DeployStepResult(exitCode: result.exitCode, output: buildOutput), seamResult)
    }

    /// Builds the guest shell command that: (1) writes the base64-decoded manifest to
    /// `/tmp` — passed as `$1`, a positional parameter, never spliced into the script string,
    /// mirroring `guestArgv`'s `.bundleUpload` injection-safety pattern; (2) runs `npm run build`
    /// with both #748 env vars pointed at their `/tmp` paths; (3) echoes the result marker plus
    /// whatever the build wrote to the result path; and (4) traps EXIT/INT/TERM to remove both
    /// `/tmp` scratch files on every path this shell can gracefully reach (a hard-killed guest
    /// process's `/tmp` is still disposed of when its ephemeral VM is next torn down or rebooted).
    static func wellKnownSeamArgv(manifestBase64: String) -> [String] {
        let script = """
        trap 'rm -f \(wellKnownManifestGuestPath) \(wellKnownResultGuestPath)' EXIT INT TERM
        printf '%s' "$1" | base64 -d > \(wellKnownManifestGuestPath)
        \(WellKnownClaimManifest.environmentVariableName)=\(wellKnownManifestGuestPath) \
        \(WellKnownClaimManifest.resultPathEnvironmentVariable)=\(wellKnownResultGuestPath) npm run build
        code=$?
        echo "\(wellKnownResultMarker)"
        cat \(wellKnownResultGuestPath) 2>/dev/null || true
        exit $code
        """
        return ["sh", "-c", script, "sh", manifestBase64]
    }

    /// `DeployCommand` hands every step the full HOST (macOS) environment; almost none of it is valid
    /// in the Linux guest. We must NOT forward it wholesale: the host `PATH` (`/opt/homebrew/bin:…`)
    /// would shadow the guest's Linux PATH and break `node`/`npm`/`wrangler` resolution, and
    /// `HOME`/`TMPDIR`/`XPC_*`/`__CF*` are host-only noise. The guest provides its own PATH/HOME; the
    /// only host-originated values the deploy ever needs across the boundary are per-step secrets —
    /// the Cloudflare token for `.wrangler`/`.bundleUpload`/`.wranglerSubcommand` (all three invoke
    /// `wrangler`), plus the account id `CloudflareDeployTarget.publish` resolves for `.wrangler`/
    /// `.bundleUpload` so `wrangler` doesn't have to auto-discover it itself (#1853) — and the
    /// GitHub Pages token for `.githubPagesPublish`. Scoped per step, not merely per key: a secret
    /// for one deploy target must never reach a step that has no business seeing it, e.g. a GitHub
    /// Pages push must never see `CLOUDFLARE_API_TOKEN` even when both happen to be present in the
    /// caller-supplied environment dict. The three wrangler-invoking steps delegate to
    /// `WranglerInvocation.guestEnvironment(from:scope:)` — the single source of truth for which
    /// Cloudflare keys a wrangler call may see in-guest (#1821 final review) — rather than
    /// re-declaring the same sets here, so a future change to `WranglerInvocation.EnvScope` reaches
    /// every wrangler call site instead of silently missing this one.
    private static func guestEnvironment(from hostEnvironment: [String: String], step: DeployStep) -> [String: String] {
        switch step {
        case .build, .preflight:
            return [:]
        case .wrangler, .bundleUpload:
            return WranglerInvocation.guestEnvironment(from: hostEnvironment, scope: .tokenAndAccount)
        case .wranglerSubcommand:
            return WranglerInvocation.guestEnvironment(from: hostEnvironment, scope: .tokenOnly)
        case .githubPagesPublish:
            return hostEnvironment.filter { $0.key == "GITHUB_PAGES_TOKEN" }
        }
    }

    // MARK: wrangler.toml staging (#1084, #1960)

    /// Which steps invoke `wrangler` in a way that reads `wrangler.toml` — the ones
    /// `WranglerInvocation.configStagingArgv(configDirectory:)` runs ahead of. `.bundleUpload`
    /// (`wrangler r2 object put`) and `.githubPagesPublish` never read it.
    static func stepReadsWranglerConfig(_ step: DeployStep) -> Bool {
        switch step {
        case .wrangler, .wranglerSubcommand: return true
        case .build, .preflight, .bundleUpload, .githubPagesPublish: return false
        }
    }

    // MARK: argv mapping

    static func guestArgv(for step: DeployStep, siteDirectory: URL, configDirectory: URL) -> [String] {
        switch step {
        case .build:
            return ["npm", "run", "build"]
        case .preflight:
            return ["npx", "tsx", "scripts/pre-deploy-check.ts", "--json"]
        case .wrangler:
            return ["npx", "wrangler", "deploy"]
        case .bundleUpload:
            let bucket = bundleUploadBucket(configDirectory: configDirectory) ?? ""
            // `bucket` is owner-influenceable config (`Config/settings.plist`) that must
            // never be spliced into shell script text. Instead of interpolating it, the script
            // references it only via `$1`, a POSITIONAL shell parameter: `sh -c 'script' sh
            // "$bucket"` sets `$1` to `bucket`'s value as a single opaque word. The shell
            // substitutes that word without re-parsing its *content* as syntax, so characters
            // like `;`, `` ` ``, `$()`, or quotes inside `bucket` can't break out of the
            // intended command — verified locally with
            // `sh -c 'echo "$1"' sh '$(echo pwned)'` printing the literal string, not executing
            // it. `"sh"` (the second argv element) fills the `$0`/argv0 slot that `sh -c` expects
            // before the first real positional parameter; it is never itself used as `$1`.
            return [
                "sh", "-c",
                "tar czf /tmp/source-bundle.tar.gz -C /workspace/site --exclude=dist --exclude=node_modules . " +
                "&& npx wrangler r2 object put \"$1/source/$(basename \"$1\").tar.gz\" " +
                "--file=/tmp/source-bundle.tar.gz --remote",
                "sh", bucket
            ]
        case .githubPagesPublish:
            guard let (owner, repo) = githubPagesRepo(siteDirectory: siteDirectory) else {
                return ["sh", "-c", "echo 'GitHub Pages repo is not configured in anglesite.json' >&2; exit 1"]
            }
            // Fresh, force-pushed commit each deploy (#1015 slice 2a design decision) — no
            // incremental history, matching how the ecosystem's gh-pages tool and
            // peaceiris/actions-gh-pages both work by default. `owner`/`repo` come from
            // anglesite.json — attacker/owner-controlled content that must never be spliced into
            // shell script text. Instead of interpolating them, the script references them only
            // via `$1`/`$2`, POSITIONAL shell parameters, the same injection-safety pattern
            // `.bundleUpload` uses for the source bundle bucket above. The token crosses the host→guest
            // boundary only via `$GITHUB_PAGES_TOKEN` (an environment variable, never a shell
            // argument, never logged) — see `guestEnvironment`. `touch .nojekyll` before staging:
            // GitHub Pages' branch-source publish path runs the site through Jekyll by default,
            // which excludes every underscore-prefixed path — including Astro's `dist/_astro/`
            // asset directory — unless `.nojekyll` exists at the repo root. Without it, a deploy
            // reports success but silently serves an unstyled, scriptless site. Both ecosystem
            // tools cited above (`gh-pages`, `peaceiris/actions-gh-pages`) write this file by
            // default too.
            return [
                "sh", "-c",
                "cd dist && touch .nojekyll && git init -q && git checkout -q -B main && git add -A && " +
                "git -c user.email=deploy@anglesite.app -c user.name=Anglesite commit -q -m Deploy && " +
                "git push -q --force \"https://x-access-token:$GITHUB_PAGES_TOKEN@github.com/$1/$2.git\" HEAD:main",
                "sh", owner, repo
            ]
        case .wranglerSubcommand(let args):
            return WranglerInvocation.argv(subcommand: args)
        }
    }

    /// Reads `SiteSettings.sourceBundleBucket` from the HOST package's `Config/settings.plist`
    /// (#1960 — formerly `.site-config`'s `CF_SOURCE_BUCKET`) — `nil` when unset, which
    /// `CloudflareDeployTarget` treats as "skip this step" before it ever reaches the executor.
    private static func bundleUploadBucket(configDirectory: URL) -> String? {
        (try? SiteConfigStore.read(from: configDirectory))?.sourceBundleBucket
    }

    /// Reads `Source/anglesite.json`'s `githubPages.owner`/`.repo` from the HOST `siteDirectory`
    /// (the guest's copy is a clone of the same repo, so the value is identical) — `nil` when
    /// either is unset, mirroring `bundleUploadBucket`'s "not configured" precedent. Unlike
    /// `.bundleUpload` (where "not configured" means `DeployCommand.deploy` skips the step
    /// entirely before it ever reaches the executor), a `.githubPagesPublish` step that's reached
    /// with no configured repo is a real misconfiguration — the caller above returns a script
    /// that fails loudly instead of silently pushing to a malformed URL.
    private static func githubPagesRepo(siteDirectory: URL) -> (owner: String, repo: String)? {
        guard let config = try? DomainConfigStore(sourceDirectory: siteDirectory).load(),
              let owner = config.githubPages?.owner, !owner.isEmpty,
              let repo = config.githubPages?.repo, !repo.isEmpty
        else { return nil }
        return (owner, repo)
    }
}

/// Test-only visibility onto `ContainerDeployExecutor`'s argv mapping — `guestArgv` itself is
/// `static` and package-internal so `@testable import AnglesiteCore` sees it directly; this
/// wrapper exists only so tests don't depend on `ContainerDeployExecutor`'s internal method name
/// staying `guestArgv` specifically. Kept minimal since it's exercised by exactly one test.
enum ContainerDeployExecutorTestHook {
    static func guestArgv(for step: DeployStep, siteDirectory: URL, configDirectory: URL) -> [String] {
        ContainerDeployExecutor.guestArgv(for: step, siteDirectory: siteDirectory, configDirectory: configDirectory)
    }
}

// MARK: - HostDeployExecutor

/// Runs deploy steps through `ProcessSupervisor` when a caller injects explicit commands.
///
/// Injecting a custom `resolveCommand` lets tests drive arbitrary shell fixtures without
/// requiring a container to be present (same pattern as `DeployCommand`'s `CommandResolver`
/// injection).
///
/// Normally (i.e. not in tests) the default resolver returns explicit unavailability for every
/// deploy step. This prevents silent host subprocess fallback after embedded Node retirement.
///
/// Output is streamed line-by-line to `logCenter` under `source` *and* accumulated into
/// `DeployStepResult.output` so callers can parse the deployed URL or scan JSON.
public struct HostDeployExecutor: DeployExecutor {
    private let supervisor: ProcessSupervisor
    private let logCenter: LogCenter
    /// Injectable per-step command resolver. Defaults to `HostDeployExecutor.defaultResolver`.
    private let resolveCommand: @Sendable (DeployStep) -> DeployCommand.CommandResolver

    /// Creates a host-process executor. Inject `resolveCommand` in tests to point each step at a
    /// shell fixture; the production default (``defaultResolver``) reports every step
    /// unavailable, per the host-Node retirement rationale in the type doc.
    public init(
        supervisor: ProcessSupervisor = .shared,
        logCenter: LogCenter = .shared,
        resolveCommand: @escaping @Sendable (DeployStep) -> DeployCommand.CommandResolver =
            HostDeployExecutor.defaultResolver
    ) {
        self.supervisor = supervisor
        self.logCenter = logCenter
        self.resolveCommand = resolveCommand
    }

    // MARK: DeployExecutor

    /// Resolves `step` to a host command and spawns it via `ProcessSupervisor`. An
    /// `.unavailable` resolution short-circuits to a nil-exit-code result carrying the reason as
    /// its output — the same shape a pre-spawn failure takes, so callers surface both
    /// identically.
    public func run(
        step: DeployStep,
        siteDirectory: URL,
        environment: [String: String],
        source: String
    ) async -> DeployStepResult {
        let resolver = resolveCommand(step)
        let plan = resolver(siteDirectory)

        switch plan {
        case .unavailable(let reason):
            return DeployStepResult(exitCode: nil, output: reason)
        case .run(let executable, let arguments):
            return await spawn(
                executable: executable,
                arguments: arguments,
                environment: environment,
                siteDirectory: siteDirectory,
                source: source
            )
        }
    }

    // MARK: Spawn helpers

    private func spawn(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        siteDirectory: URL,
        source: String
    ) async -> DeployStepResult {
        let handle: ProcessSupervisor.Handle
        do {
            handle = try await supervisor.launch(
                source: source,
                executable: executable,
                arguments: arguments,
                environment: environment,
                currentDirectoryURL: siteDirectory,
                logCenter: logCenter
            )
        } catch {
            return DeployStepResult(exitCode: nil, output: "couldn't spawn process: \(error)")
        }

        // On cancellation this SIGTERMs the child and returns only once it has really exited and
        // its log pipes are drained — so the snapshot below is complete and `.terminated` means
        // "dead", not "kill requested" (#1758).
        let reason = await supervisor.waitForExitOrTerminate(handle)

        // Snapshot stdout from LogCenter — identical to DeployCommand's approach.
        let snapshot = await logCenter.snapshot()
        let output = snapshot
            .filter { $0.source == source && $0.stream == .stdout }
            .map(\.text)
            .joined(separator: "\n")

        switch reason {
        case .exited(let code):
            return DeployStepResult(exitCode: code, output: output)
        case .terminated:
            return DeployStepResult(exitCode: nil, output: output)
        case .retriesExhausted(let lastCode):
            return DeployStepResult(exitCode: lastCode, output: output)
        }
    }

    // MARK: Default command resolvers

    /// Returns the appropriate `CommandResolver` for each step, mirroring `DeployCommand`'s
    /// static resolvers exactly.
    public static let defaultResolver: @Sendable (DeployStep) -> DeployCommand.CommandResolver = { step in
        switch step {
        case .build:
            return DeployCommand.resolveBuildCommand
        case .preflight:
            return preflightResolver
        case .wrangler:
            return DeployCommand.resolveWranglerCommand
        case .bundleUpload:
            return { _ in .unavailable(reason: HostNodeRetirement.reason("source bundle upload")) }
        case .githubPagesPublish:
            return { _ in .unavailable(reason: HostNodeRetirement.reason("GitHub Pages publish")) }
        case .wranglerSubcommand:
            return { _ in .unavailable(reason: HostNodeRetirement.reason("social worker provisioning")) }
        }
    }

    /// Host-side preflight is retired with embedded Node. Container runtimes must provide the
    /// executable preflight path.
    public static let preflightResolver: DeployCommand.CommandResolver = { siteDirectory in
        .unavailable(reason: HostNodeRetirement.reason("pre-deploy check"))
    }
}
