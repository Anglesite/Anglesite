import Foundation

/// The Cloudflare `wrangler deploy` conformer of `DeployTarget` (#1015 slice 1) — every piece of
/// `DeployCommand` that used to be Cloudflare-specific now lives here: credential resolution, the
/// worker-name-conflict and domain-config-drift pre-checks, the wrangler upload itself, and every
/// post-publish effect (custom-domain attach, Markdown for Agents, `.site-config` persistence, the
/// R2 source-bundle upload). `DeployCommand` calls `authorize(siteDirectory:)` before the shared
/// build/`PreDeployCheck` spine runs, then `publish(context:)` only after that spine has passed.
public struct CloudflareDeployTarget: DeployTarget {
    public static let id = "cloudflare"

    /// Returns the Cloudflare API token, or `nil` if none is configured. Production callers use
    /// `CloudflareDeployTarget.keychainTokenSource` (Keychain with an env-var fallback for
    /// development); tests typically inject a closure returning a literal.
    public typealias TokenSource = @Sendable () async throws -> String?
    /// Returns the account's existing Worker script names for the given token. Production
    /// callers use `CloudflareDeployTarget.defaultWorkerScriptNames` (`HTTPCloudflareClient`);
    /// tests inject a fake list or a throwing closure.
    public typealias WorkerScriptNamesSource = @Sendable (_ apiToken: String) async throws -> [String]
    /// Grades a declared `Source/anglesite.json` domain against live Cloudflare state and returns
    /// any drift (#1171's `DomainConfigAudit.evaluate`, given a fresh zone read). Production
    /// callers use `CloudflareDeployTarget.defaultDomainConfigDriftSource`; tests inject a canned
    /// findings list or a throwing closure — same rationale as `WorkerScriptNamesSource`.
    public typealias DomainConfigDriftSource = @Sendable (
        _ declared: DomainConfig, _ hostname: String, _ apiToken: String
    ) async throws -> [DomainConfigAudit.Finding]
    /// Resolves the token's Cloudflare account id, or `nil` when it can't be resolved (most
    /// commonly a token scoped only to Workers Scripts/Routes/Tail — exactly what a user
    /// following bare "give it Workers access" guidance would create — which authenticates fine
    /// but lacks the "Account Settings: Read" permission `GET /accounts` needs, #1853). Defaults
    /// to always returning `nil` — safe for every test that doesn't care about this seam, since a
    /// `nil` account id just means `publish(context:)` skips the `CLOUDFLARE_ACCOUNT_ID`
    /// convenience below and `wrangler` falls back to its own auto-discovery exactly as before
    /// this seam existed. Production wiring is `CloudflareDeployTarget.defaultAccountIDSource`
    /// (`HTTPCloudflareClient`), passed explicitly by the two call sites that construct a live
    /// deploy target (`DeployTargetSelection.fromSiteConfig`,
    /// `SocialWorkerProvisionCommand.defaultDeployer`) — unlike `tokenSource` this seam is a
    /// best-effort convenience, not a hard gate, so it doesn't need every test call site to inject
    /// a fake the way the always-consulted `tokenSource` does.
    public typealias AccountIDSource = @Sendable (_ apiToken: String) async -> String?

    /// The token seam this target was constructed with. Exposed so `DeployModel.runDeploy` can
    /// forward the exact same seam into companion commands (e.g. `SocialWorkerProvisionCommand`)
    /// instead of letting them silently default to the production implementation and diverge
    /// from a test's injected fake — see `workerScriptNamesSource` below for the full rationale.
    public let tokenSource: TokenSource
    /// Exposed (like `tokenSource`) so callers that build a parallel `SocialWorkerProvisionCommand`
    /// alongside this target — `DeployModel.runDeploy` — can forward the exact same seam into its
    /// own pre-provisioning conflict check (#1075) instead of silently defaulting to the real
    /// network implementation and diverging from whatever this target was built with (production
    /// default or a test's injected fake).
    public let workerScriptNamesSource: WorkerScriptNamesSource
    /// Exposed like `tokenSource`/`workerScriptNamesSource` so `DeployModel.runDeploy` can forward
    /// the exact same seam into a container-path target it constructs on the fly (#1077).
    public let customDomainAttachCommand: CustomDomainAttachCommand
    /// Exposed like `customDomainAttachCommand` so `DeployModel.runDeploy` can forward the exact
    /// same seam into a container-path target it constructs on the fly (#1247).
    public let markdownForAgentsCommand: MarkdownForAgentsCommand
    /// Exposed like the other seams above so callers building a parallel target (e.g.
    /// `SocialWorkerProvisionCommand`'s `defaultDeployer`) forward the same one rather than
    /// silently defaulting to production and diverging from a test's injected fake.
    public let domainConfigDriftSource: DomainConfigDriftSource
    /// The account-id seam this target was constructed with — see ``AccountIDSource``'s doc for
    /// why its default is inert `nil` rather than a production closure.
    public let accountIDSource: AccountIDSource

    /// All six dependencies are injectable seams, so tests can drive a full deploy — credential
    /// gate, name-conflict check, domain-config-drift check, publish — with a literal token, a
    /// canned script-name list, and a scripted executor, never touching the network or spawning a
    /// process. Five have production defaults; `accountIDSource` deliberately doesn't (see its
    /// doc) — production callers pass `CloudflareDeployTarget.defaultAccountIDSource` explicitly.
    public init(
        tokenSource: @escaping TokenSource = CloudflareDeployTarget.keychainTokenSource,
        workerScriptNamesSource: @escaping WorkerScriptNamesSource = CloudflareDeployTarget.defaultWorkerScriptNames,
        customDomainAttachCommand: CustomDomainAttachCommand = CustomDomainAttachCommand(),
        markdownForAgentsCommand: MarkdownForAgentsCommand = MarkdownForAgentsCommand(),
        domainConfigDriftSource: @escaping DomainConfigDriftSource = CloudflareDeployTarget.defaultDomainConfigDriftSource,
        accountIDSource: @escaping AccountIDSource = { _ in nil }
    ) {
        self.tokenSource = tokenSource
        self.workerScriptNamesSource = workerScriptNamesSource
        self.customDomainAttachCommand = customDomainAttachCommand
        self.markdownForAgentsCommand = markdownForAgentsCommand
        self.domainConfigDriftSource = domainConfigDriftSource
        self.accountIDSource = accountIDSource
    }

    // MARK: DeployTarget

    /// Pre-build gate: token resolution plus the worker-name-conflict (#740) and
    /// domain-config-drift (#1173) checks, in that order — matches `DeployCommand.deploy`'s
    /// original pre-spawn sequence exactly, so a deploy that can't succeed still fails before any
    /// build time is spent.
    public func authorize(siteDirectory: URL) async -> DeployTargetAuthorization {
        let token: String?
        do {
            token = try await tokenSource()
        } catch {
            return .blocked(.failed(reason: "couldn't read Cloudflare API token: \(error)", exitCode: nil))
        }
        guard let token, !token.isEmpty else {
            return .blocked(.failed(
                reason: "no CLOUDFLARE_API_TOKEN — add it in Settings → Advanced → Credentials, or set the env var",
                exitCode: nil))
        }
        if let conflict = await Self.checkWorkerNameConflict(
            siteDirectory: siteDirectory, apiToken: token, workerScriptNamesSource: workerScriptNamesSource
        ) {
            return .blocked(conflict)
        }
        if let drift = await Self.checkDomainConfigDrift(
            siteDirectory: siteDirectory, apiToken: token, domainConfigDriftSource: domainConfigDriftSource
        ) {
            return .blocked(drift)
        }
        return .ready(credential: token)
    }

    /// Runs `wrangler deploy` and every post-publish effect: URL extraction, custom-domain
    /// attach, Markdown for Agents, `.site-config` persistence, and the optional R2 source-bundle
    /// upload — matches `DeployCommand.deploy`'s original wrangler-step-and-after sequence exactly.
    public func publish(context: DeployTargetContext) async -> DeployCommand.Result {
        var wranglerEnvironment = context.baseEnvironment
        wranglerEnvironment["CLOUDFLARE_API_TOKEN"] = context.credential
        // #1853: resolve the account ourselves and hand it to wrangler explicitly, rather than
        // relying entirely on wrangler's own `GET /accounts` auto-discovery inside the guest — a
        // token scoped only to Workers Scripts/Routes/Tail authenticates fine but can't enumerate
        // accounts, so auto-discovery dies with a cryptic "Failed to automatically retrieve
        // account IDs" error at the very last step, after the build and pre-deploy scan already
        // ran. `accountIDSource` fails open (`nil`) on any resolution error — same posture as
        // `checkWorkerNameConflict`/`checkDomainConfigDrift` above: a token that genuinely can't
        // resolve an account is no worse off than before this fix, since wrangler still gets its
        // own shot at auto-discovery.
        if let accountID = await accountIDSource(context.credential) {
            wranglerEnvironment["CLOUDFLARE_ACCOUNT_ID"] = accountID
        }

        let started = Date()
        context.onProgress?(.deployDeploying)
        let wranglerResult = await context.executor.run(
            step: .wrangler,
            siteDirectory: context.siteDirectory,
            environment: wranglerEnvironment,
            source: "deploy:\(context.siteID)"
        )
        let duration = Date().timeIntervalSince(started)

        if !Task.isCancelled { context.onProgress?(.deployFinalizing) }

        guard let code = wranglerResult.exitCode else {
            // nil exit code → unavailable resolver, spawn failure, or termination (e.g. cancellation).
            // The cancellation path must say "terminated" (the cancellation test asserts on it);
            // for the unavailable/spawn-failure cases the executor surfaces the reason in `output`.
            if Task.isCancelled {
                return .failed(reason: "wrangler was terminated", exitCode: nil)
            }
            return .failed(reason: wranglerResult.output.isEmpty ? "wrangler was terminated" : wranglerResult.output, exitCode: nil)
        }
        guard code == 0 else {
            return .failed(reason: "wrangler exited with code \(code)", exitCode: code)
        }
        guard let url = Self.extractDeployedURL(from: wranglerResult.output) else {
            return .failed(
                reason: "wrangler exited successfully (code 0), but no deployed URL could be found in its output — the deploy likely succeeded; check the deploy log for the URL",
                exitCode: 0
            )
        }

        if let configDirectory = context.configDirectory {
            try? DeployedRoutesSnapshot.save(context.currentRoutes, to: configDirectory)
        }
        // Runs before `persistSiteURL` (#1077/#1124): a fresh confirmation from *this* deploy
        // persists `CF_DOMAIN_ATTACHED` as a side effect, which `persistSiteURL` checks to decide
        // whether to leave `SITE_URL` alone.
        let domainAttachOutcome = await customDomainAttachCommand.attach(
            siteDirectory: context.siteDirectory, apiToken: context.credential, source: "deploy:\(context.siteID)")
        context.onDomainAttach?(domainAttachOutcome)
        // Only a confirmed-attached custom domain has a zone to configure — a workers.dev-only
        // site (or one not yet delegated) has nothing for Markdown for Agents to apply to (#1247).
        if case .confirmed(let hostname) = domainAttachOutcome {
            let markdownOutcome = await markdownForAgentsCommand.apply(
                hostname: hostname, siteDirectory: context.siteDirectory, configDirectory: context.configDirectory,
                apiToken: context.credential, source: "deploy:\(context.siteID)")
            context.onMarkdownForAgents?(markdownOutcome)
        }
        Self.persistSiteURL(url, siteDirectory: context.siteDirectory)
        Self.persistWorkerDeployed(siteDirectory: context.siteDirectory)
        if let configDirectory = context.configDirectory {
            await Self.uploadSourceBundleIfConfigured(
                siteDirectory: context.siteDirectory, configDirectory: configDirectory,
                environment: wranglerEnvironment, executor: context.executor, siteID: context.siteID
            )
        }
        return .succeeded(url: url, duration: duration)
    }

    // MARK: URL extraction

    /// Extracts the deployed URL from wrangler's captured stdout. Wrangler's exact wording has
    /// already drifted across major versions (older wrangler printed a `Published <name> (1.23
    /// sec)` status line; current wrangler instead prints separate `Uploaded <name> (…)` /
    /// `Deployed <name> triggers (…)` lines), and `wrangler deploy` (unlike `wrangler pages
    /// deploy`) has no `--json` output mode to depend on instead, so multiple status-line prefixes
    /// are recognized as the anchor:
    ///
    /// 1. Anchor on a recognized start-of-line status prefix (`Published`/`Deployed`/`Uploaded`)
    ///    and search only the anchor line and lines after it — never anything before it — for a
    ///    URL. A `*.workers.dev` URL there is preferred (the common case); any URL is accepted as a
    ///    fallback for custom-domain deploys, which have no workers.dev host in their output.
    ///    Scoping to at/after the anchor (rather than the whole output) matters because this
    ///    result gets persisted as the site's live URL: an incidental workers.dev mention earlier
    ///    in the log (e.g. a subdomain-already-exists notice) must not outrank the real result.
    /// 2. If no anchor line is recognized at all (a future wrangler layout this doesn't know
    ///    about), fall back to a whole-output scan for a `*.workers.dev` URL — still a
    ///    distinctive, version-independent signature of a genuine deploy result, just without
    ///    anchor confirmation.
    public static func extractDeployedURL(from output: String) -> URL? {
        let anchors = ["Published", "Deployed", "Uploaded"]
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        if let anchorIdx = lines.firstIndex(where: { line in anchors.contains(where: line.hasPrefix) }) {
            let tail = lines[anchorIdx...].joined(separator: "\n")
            return firstURL(in: tail, requiringHostSuffix: ".workers.dev") ?? firstURL(in: tail)
        }
        return firstURL(in: output, requiringHostSuffix: ".workers.dev")
    }

    /// The first `http(s)` URL in `text` — optionally required to have a host ending in
    /// `hostSuffix` — with trailing punctuation a terminal might tack on (commas, periods, closing
    /// parens) stripped. Scans the whole string (not line-by-line), so callers doing a
    /// version-independent signature scan can pass multi-line output directly.
    private static func firstURL(in text: String, requiringHostSuffix hostSuffix: String? = nil) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: #"https?://\S+"#) else { return nil }
        let fullRange = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: fullRange) {
            guard let range = Range(match.range, in: text) else { continue }
            var raw = String(text[range])
            while let last = raw.last, ",.)]}>".contains(last) {
                raw.removeLast()
            }
            guard let url = URL(string: raw) else { continue }
            if let hostSuffix {
                guard let host = url.host, host.hasSuffix(hostSuffix) else { continue }
            }
            return url
        }
        return nil
    }

    // MARK: `.site-config` persistence

    /// Persists the deployed URL into `.site-config`'s `SITE_URL` (#702) so the *next* build's
    /// `astro.config.ts` picks up the real host for canonical URLs, feed self-links, and JSON-LD
    /// instead of the `https://example.com` placeholder. This deploy's own `dist/` was already
    /// built before the URL was known, so the placeholder still ships on a site's first deploy —
    /// every deploy after that carries the real host.
    ///
    /// Written even when a custom domain (`DOMAIN`/`SITE_DOMAIN`) is configured but not yet
    /// confirmed live (#1085): before #1077, nothing in the deploy pipeline attached a custom
    /// domain, so an unverified `DOMAIN` was never trustworthy and `SITE_URL` — the site's real,
    /// reachable address — had to win `DeployCoordinator.resolveSiteURL`'s precedence regardless.
    ///
    /// Skipped once `CF_DOMAIN_ATTACHED` matches `DOMAIN` — the same "confirmed" signal
    /// `CustomDomainAttachCommand.attach` itself checks (#1077) — because at that point `DOMAIN`
    /// *is* verified live, and overwriting `SITE_URL` with the workers.dev host would shadow it in
    /// `resolveSiteURL`'s precedence forever after, silently undoing every confirmed domain attach
    /// on its very next deploy. Callers must call `customDomainAttachCommand.attach` (and let it
    /// persist `CF_DOMAIN_ATTACHED`) before this, so a domain confirmed *in this same deploy* is
    /// already visible to the check. Best-effort — a write failure must never turn a successful
    /// deploy into a failed one.
    static func persistSiteURL(_ url: URL, siteDirectory: URL) {
        let configURL = siteDirectory.appendingPathComponent(WebsiteAnalyticsAsset.configRelativePath)
        let config = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        if let domain = SiteConfigFile.value(forKey: "DOMAIN", in: config),
           SiteConfigFile.value(forKey: "CF_DOMAIN_ATTACHED", in: config) == domain {
            return
        }
        let updated = SiteConfigFile.upsert([("SITE_URL", url.absoluteString)], into: config)
        guard updated != config else { return }
        try? updated.write(to: configURL, atomically: true, encoding: .utf8)
    }

    /// Marks this site as having successfully deployed at least once, via `.site-config`'s
    /// `CF_WORKER_DEPLOYED` — the signal `checkWorkerNameConflict` uses to skip the collision
    /// check on every deploy after the first (#740). Written unconditionally, unlike
    /// `persistSiteURL` (which skips when a custom domain is already configured) — deploy
    /// history isn't confounded by domain choice. Best-effort, matching `persistSiteURL`.
    static func persistWorkerDeployed(siteDirectory: URL) {
        let configURL = siteDirectory.appendingPathComponent(WebsiteAnalyticsAsset.configRelativePath)
        let config = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        guard SiteConfigFile.value(forKey: "CF_WORKER_DEPLOYED", in: config) == nil else { return }
        let updated = SiteConfigFile.upsert([("CF_WORKER_DEPLOYED", "true")], into: config)
        try? updated.write(to: configURL, atomically: true, encoding: .utf8)
    }

    /// Whether this site has already completed at least one successful deploy — the same
    /// `.site-config` `CF_WORKER_DEPLOYED` signal `persistWorkerDeployed` writes and
    /// `checkWorkerNameConflict` reads. A read-only counterpart for callers (`DeployModel`) that
    /// need to know, *before* a deploy runs, whether this one would be the site's first — without
    /// duplicating the file read `checkWorkerNameConflict` already does inline. Public (unlike its
    /// siblings) because `DeployModel` lives in a different module.
    public static func hasDeployedBefore(siteDirectory: URL) -> Bool {
        let configURL = siteDirectory.appendingPathComponent(WebsiteAnalyticsAsset.configRelativePath)
        let config = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        return SiteConfigFile.value(forKey: "CF_WORKER_DEPLOYED", in: config) != nil
    }

    /// Marks this site's candidate Worker name as confirmed-ours, via `.site-config`'s
    /// `CF_WORKER_PROVISIONED` — a second, earlier-firing signal `checkWorkerNameConflict` treats
    /// the same as `CF_WORKER_DEPLOYED` (#1075). `CF_WORKER_DEPLOYED` alone only covers a *fully
    /// succeeded* deploy, but `SocialWorkerProvisionCommand.provision()` can already have pushed
    /// live Cloudflare state under this candidate name (`wrangler secret put` for ActivityPub, run
    /// before the final `wrangler deploy`, auto-vivifies an empty Worker script under the target
    /// name as a side effect) in an attempt that then failed for an unrelated reason before
    /// `persistWorkerDeployed` ever ran. Without this second signal, a retry of that same site
    /// would see its own auto-vivified script on the account and misreport it as a foreign
    /// conflict. Called once, immediately after a fresh `checkWorkerNameConflict` pass at the very
    /// start of provisioning — before any wrangler call that could touch the name — so a *genuine*
    /// foreign collision is still caught before this site's own provisioning ever runs. Written
    /// unconditionally like `persistWorkerDeployed`; best-effort, matching `persistSiteURL`.
    static func persistWorkerProvisioned(siteDirectory: URL) {
        let configURL = siteDirectory.appendingPathComponent(WebsiteAnalyticsAsset.configRelativePath)
        let config = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        guard SiteConfigFile.value(forKey: "CF_WORKER_PROVISIONED", in: config) == nil else { return }
        let updated = SiteConfigFile.upsert([("CF_WORKER_PROVISIONED", "true")], into: config)
        try? updated.write(to: configURL, atomically: true, encoding: .utf8)
    }

    /// Uploads `Source/`'s snapshot to R2 (`DeployStep.bundleUpload`) when `.site-config`'s
    /// `CF_SOURCE_BUCKET` is set, then persists the uploaded commit SHA into `Config/settings.plist`
    /// (#799, spec §C.4 — the code side of a future Worker-triggered bake). A no-op today for every
    /// real site — no provisioning flow writes `CF_SOURCE_BUCKET` yet — and the executor call is
    /// skipped entirely rather than run-and-ignore-the-result, so a redeploy on an unprovisioned
    /// site pays no extra subprocess cost. Best-effort like `persistSiteURL`/`persistWorkerDeployed`:
    /// a failure here must never turn a successful deploy into a failed one.
    static func uploadSourceBundleIfConfigured(
        siteDirectory: URL,
        configDirectory: URL,
        environment: [String: String],
        executor: any DeployExecutor,
        siteID: String
    ) async {
        let configURL = siteDirectory.appendingPathComponent(WebsiteAnalyticsAsset.configRelativePath)
        let config = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        guard SiteConfigFile.value(forKey: "CF_SOURCE_BUCKET", in: config) != nil else { return }

        let uploadResult = await executor.run(
            step: .bundleUpload,
            siteDirectory: siteDirectory,
            environment: environment,
            source: "deploy:\(siteID):bundle"
        )
        guard uploadResult.exitCode == 0 else { return }

        guard let headResult = try? await BackupCommand.defaultRunner(siteDirectory, ["rev-parse", "HEAD"]) else { return }
        guard headResult.exitCode == 0 else { return }
        let commitSHA = headResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commitSHA.isEmpty else { return }

        let store = SiteConfigStore(configDirectory: configDirectory)
        guard var settings = try? await store.load() else { return }
        settings.deployedSourceBundleCommit = commitSHA
        try? await store.save(settings)
    }

    // MARK: Pre-build checks

    /// Checks whether `.site-config`'s `CF_PROJECT_NAME` collides with an existing Worker on the
    /// connected Cloudflare account, but only when neither `CF_WORKER_DEPLOYED` (a full deploy has
    /// already succeeded under this name) nor `CF_WORKER_PROVISIONED` (this site's own earlier
    /// provisioning already confirmed the name as ours, #1075) is set yet. Returns
    /// `.workerNameConflict` on a confirmed collision, or `nil` when the check doesn't apply
    /// (redeploy, already-provisioned, no candidate name) or can't be confirmed — a Cloudflare API
    /// failure here must never block a deploy that would otherwise succeed (fail open).
    static func checkWorkerNameConflict(
        siteDirectory: URL,
        apiToken: String,
        workerScriptNamesSource: WorkerScriptNamesSource
    ) async -> DeployCommand.Result? {
        let configURL = siteDirectory.appendingPathComponent(WebsiteAnalyticsAsset.configRelativePath)
        let config = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        guard SiteConfigFile.value(forKey: "CF_WORKER_DEPLOYED", in: config) == nil,
              SiteConfigFile.value(forKey: "CF_WORKER_PROVISIONED", in: config) == nil,
              let candidateName = SiteConfigFile.value(forKey: "CF_PROJECT_NAME", in: config)
        else { return nil }
        guard let names = try? await workerScriptNamesSource(apiToken) else { return nil }
        guard names.contains(candidateName) else { return nil }
        return .workerNameConflict(name: candidateName)
    }

    /// Grades the site's declared `anglesite.json` domain against live Cloudflare state (#1173).
    /// Returns `.domainConfigDrift` when the audit finds any drift, or `nil` when the check
    /// doesn't apply (no `anglesite.json`, or no declared `domain.hostname` — nothing to compare
    /// against live state) or can't be confirmed. A read/decode error and a thrown/failed
    /// `domainConfigDriftSource` both fail open — same posture as `checkWorkerNameConflict`, since
    /// a transient Cloudflare API hiccup here must never block an otherwise-good deploy.
    static func checkDomainConfigDrift(
        siteDirectory: URL,
        apiToken: String,
        domainConfigDriftSource: DomainConfigDriftSource
    ) async -> DeployCommand.Result? {
        guard let declared = try? DomainConfigStore(sourceDirectory: siteDirectory).load(),
              let hostname = declared.domain?.hostname, !hostname.isEmpty
        else { return nil }
        guard let findings = try? await domainConfigDriftSource(declared, hostname, apiToken), !findings.isEmpty
        else { return nil }
        return .domainConfigDrift(findings: findings)
    }

    // MARK: Default seams

    /// Reads `CLOUDFLARE_API_TOKEN` from the process environment. Useful in development (the env
    /// var dominates the Keychain entry when both are set, so a shell with `CLOUDFLARE_API_TOKEN`
    /// exported behaves the way a wrangler user expects).
    public static let envTokenSource: TokenSource = {
        ProcessInfo.processInfo.environment["CLOUDFLARE_API_TOKEN"]
    }

    /// Default `TokenSource` for production: thin forwarding wrapper around
    /// ``CloudflareAPICredentials/resolve(secretStore:diagnosticSource:surfaceOAuthReadErrors:)``
    /// (#1211) — env var first (so a developer's shell still wins), then a stored OAuth credential
    /// (refreshing it first if expired), then the legacy pasted token, kept so a token a user
    /// already pasted keeps working. Passes `surfaceOAuthReadErrors: true`, preserving this call
    /// site's original (pre-#1211) behavior: a genuine Keychain error reading the OAuth slot
    /// surfaces as an actionable "couldn't read token" deploy failure rather than silently reading
    /// as "no token configured" and nudging the user toward an unnecessary re-sign-in — deploy is
    /// the highest-stakes call site this resolver serves, so it alone keeps that stricter
    /// diagnosis. The resolver's other callers (background sync jobs, Harden, Domain Config Audit,
    /// …) default to swallowing that error and falling through to the legacy token instead, which
    /// isn't a behavior change for them — none of them surfaced this class of error before #1211
    /// either.
    public static let keychainTokenSource: TokenSource = {
        try await CloudflareAPICredentials.resolve(surfaceOAuthReadErrors: true)
    }

    /// Default `WorkerScriptNamesSource` for production: the account's Worker script names via
    /// `HTTPCloudflareClient`.
    public static let defaultWorkerScriptNames: WorkerScriptNamesSource = { apiToken in
        try await HTTPCloudflareClient().workerScriptNames(apiToken: apiToken)
    }

    /// Default `DomainConfigDriftSource` for production: resolves the declared hostname's zone,
    /// reads its live edge state and DNS records via `HTTPCloudflareClient`, then grades them with
    /// `DomainConfigAudit.evaluate` — the same three calls `DomainConfigAuditModel.performAudit`
    /// makes App-side, just without the SwiftUI-facing `Phase` machinery. A zone that can't be
    /// resolved (not yet attached, or a Cloudflare read failure) returns no findings rather than
    /// throwing — nothing to compare declared state against yet, not drift.
    public static let defaultDomainConfigDriftSource: DomainConfigDriftSource = { declared, hostname, apiToken in
        let reader: any CloudflareReading = HTTPCloudflareClient()
        guard let zoneID = try await reader.resolveZoneID(domain: hostname, apiToken: apiToken) else { return [] }
        let state = try await reader.zoneState(zoneID: zoneID, domain: hostname, apiToken: apiToken)
        let records = try await reader.listDNSRecords(zoneID: zoneID, apiToken: apiToken)
        return DomainConfigAudit.evaluate(declared: declared, live: state, liveDNSRecords: records, domain: hostname)
    }

    /// Default `AccountIDSource` for production: the token's first visible Cloudflare account id
    /// via `HTTPCloudflareClient`, or `nil` on any resolution failure (including a token that
    /// can't list accounts at all — see ``AccountIDSource``). Not this type's own `init` default
    /// (see there for why); passed explicitly by every call site that builds a live deploy target.
    public static let defaultAccountIDSource: AccountIDSource = { apiToken in
        try? await HTTPCloudflareClient().accountID(apiToken: apiToken)
    }
}
