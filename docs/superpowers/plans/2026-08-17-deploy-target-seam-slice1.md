# DeployTarget Seam (Slice 1) Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract a `DeployTarget` protocol from `DeployCommand` with `CloudflareDeployTarget` as the sole conformer, and add a `deployTarget` field to `anglesite.json` — zero behavior change, no GitHub Pages conformer yet.

**Architecture:** `DeployCommand.deploy` keeps the provider-agnostic spine (well-known merge, build, non-bypassable `PreDeployCheck`) and delegates everything Cloudflare-specific — credential resolution, worker-name-conflict/domain-config-drift checks, the wrangler upload, and every post-publish effect — to a `CloudflareDeployTarget` reached through the new `DeployTarget` protocol. `DeployCommand`'s `target` parameter defaults to `CloudflareDeployTarget()`, so every existing call site keeps compiling and deploying through Cloudflare unchanged.

**Tech Stack:** Swift 6.4, Swift Testing (`@Test`/`#expect`), SwiftPM (`swift test --package-path .`).

## Global Constraints

- Zero behavior change for existing sites: every `DeployCommand.Result` case, every `.site-config`/`anglesite.json` side effect, and every observed test assertion must stay identical.
- `PreDeployCheck` (the pre-deploy security scan) stays hard-coded in `DeployCommand.deploy`, never delegated to a `DeployTarget` conformer — no target gets a hook to bypass it (CONTRIBUTING.md: "the app cannot bypass plugin security hooks").
- No GitHub Pages conformer, no target-selection logic, no Settings UI this slice — `deployTarget` is written to schema but not yet read to pick a conformer.
- Commit subject ≤ 72 characters; reference `#1015`; conventional-commit format (`feat(#1015): …`).
- Run `swift test --package-path .` and `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build` before considering either task done — this touches `Sources/AnglesiteApp` as well as `Sources/AnglesiteCore`.

---

### Task 1: Add `deployTarget` to `anglesite.json` (`DomainConfig`)

**Files:**
- Modify: `Sources/AnglesiteCore/DomainConfig.swift:15-39` (properties + init), `Sources/AnglesiteCore/DomainConfig.swift:172-196` (Codable conformance)
- Test: `Tests/AnglesiteCoreTests/DomainConfigStoreTests.swift:22-52`

**Interfaces:**
- Produces: `DomainConfig.deployTarget: String?` — an open string (not a closed enum), `nil` meaning "cloudflare" (today's only target). Round-tripped by `DomainConfigStore` like every other field. Not consumed by anything yet — Task 2 does not read it.

- [ ] **Step 1: Update the failing-first test — add `deployTarget` to the comprehensive round-trip test**

In `Tests/AnglesiteCoreTests/DomainConfigStoreTests.swift`, change the `saveLoadRoundTrips` test (lines 22-52) so the constructed `DomainConfig` also sets `deployTarget`:

```swift
    @Test("save then load round-trips a fully populated config")
    func saveLoadRoundTrips() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DomainConfigStore(sourceDirectory: dir)
        let config = DomainConfig(
            version: 1,
            domain: .init(
                hostname: "example.com", choice: "transfer", attach: true,
                registrar: "Example Registrar, LLC", expiresAt: "2027-08-13T04:00:00Z"),
            dns: .init(managedRecords: [
                .init(type: "MX", name: "@", content: "mx01.mail.icloud.com", priority: 10, purpose: "email:icloud"),
            ]),
            edge: .init(
                dnssec: true,
                alwaysUseHTTPS: true,
                hsts: .init(maxAge: 31536000, includeSubdomains: true, preload: false),
                cloudflare: .init(botFightMode: true, wafRules: [
                    .init(description: "Block bad bots", expression: "cf.client.bot", action: "block"),
                ])
            ),
            email: .init(provider: "icloud", dmarcReportEmail: "postmaster@example.com"),
            workers: .init(active: ["webmention-receive", "micropub"]),
            deployTarget: "cloudflare"
        )
        try store.save(config)
        let fileURL = dir.appendingPathComponent("anglesite.json")
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(try store.load() == config)
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(contents.hasSuffix("\n"), "anglesite.json should end with a trailing newline")
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path . --filter DomainConfigStoreTests/saveLoadRoundTrips`
Expected: FAIL — `DomainConfig(... deployTarget: "cloudflare")` doesn't compile yet (`extra argument 'deployTarget' in call`).

- [ ] **Step 3: Add the field to `DomainConfig`'s properties and memberwise init**

In `Sources/AnglesiteCore/DomainConfig.swift`, replace lines 15-39:

```swift
public struct DomainConfig: Equatable, Sendable {
    /// The schema version. Always written; tolerated as absent on read (defaults to `1`) so a
    /// file hand-authored before this field existed still loads.
    public var version: Int
    public var domain: Domain?
    public var dns: DNS?
    public var edge: Edge?
    public var email: Email?
    public var workers: Workers?
    /// The publish destination this site uses (#1015) — an open string (not a closed `enum`),
    /// matching `Domain.choice`'s precedent, so an unrecognized future value degrades gracefully
    /// for a reader that predates it. `nil` means "cloudflare," the only target that exists today
    /// — nothing reads this field to select a `DeployTarget` conformer yet (that's a later
    /// slice); it exists so that slice needs no schema migration when it lands.
    public var deployTarget: String?

    public init(
        version: Int = 1,
        domain: Domain? = nil,
        dns: DNS? = nil,
        edge: Edge? = nil,
        email: Email? = nil,
        workers: Workers? = nil,
        deployTarget: String? = nil
    ) {
        self.version = version
        self.domain = domain
        self.dns = dns
        self.edge = edge
        self.email = email
        self.workers = workers
        self.deployTarget = deployTarget
    }
```

- [ ] **Step 4: Add the field to the manual `Codable` conformance**

In the same file, replace the `Codable` extension (lines 172-196):

```swift
extension DomainConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case version, domain, dns, edge, email, workers, deployTarget
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        domain = try container.decodeIfPresent(Domain.self, forKey: .domain)
        dns = try container.decodeIfPresent(DNS.self, forKey: .dns)
        edge = try container.decodeIfPresent(Edge.self, forKey: .edge)
        email = try container.decodeIfPresent(Email.self, forKey: .email)
        workers = try container.decodeIfPresent(Workers.self, forKey: .workers)
        deployTarget = try container.decodeIfPresent(String.self, forKey: .deployTarget)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(domain, forKey: .domain)
        try container.encodeIfPresent(dns, forKey: .dns)
        try container.encodeIfPresent(edge, forKey: .edge)
        try container.encodeIfPresent(email, forKey: .email)
        try container.encodeIfPresent(workers, forKey: .workers)
        try container.encodeIfPresent(deployTarget, forKey: .deployTarget)
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --package-path . --filter DomainConfigStoreTests`
Expected: PASS (all `DomainConfigStoreTests` cases, including `saveLoadRoundTrips`).

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/DomainConfig.swift Tests/AnglesiteCoreTests/DomainConfigStoreTests.swift
git commit -m "feat(#1015): add deployTarget field to anglesite.json"
```

---

### Task 2: Extract the `DeployTarget` seam

**Files:**
- Create: `Sources/AnglesiteCore/DeployTarget.swift`
- Create: `Sources/AnglesiteCore/CloudflareDeployTarget.swift`
- Modify: `Sources/AnglesiteCore/DeployCommand.swift` (full rewrite of the sections listed in Step 3)
- Modify: `Sources/AnglesiteApp/DeployModel.swift:708`, `:748-758`, `:876-925`
- Modify: `Sources/AnglesiteApp/AgentReadinessModel.swift:22`, `:29`
- Modify: `Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift:115`, `:121`, `:132`, `:247-249`, `:252`, `:840`
- Modify (mechanical, see Step 8): `Tests/AnglesiteCoreTests/DeployCommandTests.swift`, `Tests/AnglesiteCoreTests/DeployExecutorSelectionTests.swift`, `Tests/AnglesiteCoreTests/DeployCommandProgressTests.swift`, `Tests/AnglesiteCoreTests/SiteOperationsProgressSeamTests.swift`, `Tests/AnglesiteAppTests/DeployModelTests.swift`

**Interfaces:**
- Consumes: `DeployStep`/`DeployStepResult`/`DeployExecutor` (`Sources/AnglesiteCore/DeployExecutor.swift`, unchanged), `PreDeployCheck` (`Sources/AnglesiteCore/PreDeployCheck.swift`, unchanged), `CustomDomainAttachCommand`/`MarkdownForAgentsCommand` (unchanged), `ProgressHandler` (`Sources/AnglesiteCore/OperationProgress.swift`, unchanged).
- Produces: `public protocol DeployTarget: Sendable { static var id: String { get }; func authorize(siteDirectory: URL) async -> DeployTargetAuthorization; func publish(context: DeployTargetContext) async -> DeployCommand.Result }`; `public enum DeployTargetAuthorization { case ready(credential: String); case blocked(DeployCommand.Result) }`; `public struct DeployTargetContext` (fields: `siteID: String`, `siteDirectory: URL`, `configDirectory: URL?`, `currentRoutes: [String]`, `credential: String`, `baseEnvironment: [String: String]`, `executor: any DeployExecutor`, `onDomainAttach: DeployCommand.DomainAttachObserver?`, `onMarkdownForAgents: DeployCommand.MarkdownForAgentsObserver?`, `onProgress: ProgressHandler?`); `public struct CloudflareDeployTarget: DeployTarget` with public `tokenSource`/`workerScriptNamesSource`/`customDomainAttachCommand`/`markdownForAgentsCommand`/`domainConfigDriftSource` properties, `public static func hasDeployedBefore(siteDirectory:) -> Bool`, `public static func extractDeployedURL(from:) -> URL?`; `DeployCommand.init(target: any DeployTarget = CloudflareDeployTarget(), executor: any DeployExecutor = HostDeployExecutor())` and `public nonisolated let target: any DeployTarget`.

This task is one atomic change: `DeployCommand`'s old `init` shape (`tokenSource:`/`workerScriptNamesSource:`/`customDomainAttachCommand:`/`markdownForAgentsCommand:`/`domainConfigDriftSource:`/`executor:`) is fully replaced by `target:`/`executor:`, so production code and every test call site must move together or the package won't compile. Steps 1-2 are additive (new files); Steps 3-9 land together in one commit.

- [ ] **Step 1: Create `Sources/AnglesiteCore/DeployTarget.swift`**

```swift
import Foundation

/// Outcome of a `DeployTarget`'s pre-build gate (`authorize(siteDirectory:)`). `DeployCommand`
/// calls this before spending any time on the well-known scan or the build, so a deploy that
/// can't succeed fails fast — matches `DeployCommand.deploy`'s original pre-spawn-refusal
/// behavior exactly.
public enum DeployTargetAuthorization: Sendable {
    /// The target is ready to publish. `credential` is opaque to `DeployCommand` — only the
    /// target that produced it (via `publish(context:)`'s `DeployTargetContext.credential`) knows
    /// what to do with it (e.g. `CloudflareDeployTarget` treats it as a Cloudflare API token).
    case ready(credential: String)
    /// The deploy is refused before any build work happens — a missing/invalid credential, or a
    /// target-specific fail-fast check (e.g. Cloudflare's worker-name-conflict or
    /// domain-config-drift checks). `DeployCommand.deploy` returns this `Result` immediately.
    case blocked(DeployCommand.Result)
}

/// Everything a `DeployTarget` needs to publish one deploy, assembled by `DeployCommand.deploy`
/// after the shared build + `PreDeployCheck` spine has passed.
public struct DeployTargetContext: Sendable {
    public let siteID: String
    public let siteDirectory: URL
    /// The site's `Config/` directory, or `nil` when the caller didn't supply one (tests, and the
    /// two non-primary deploy paths in `SocialWorkerProvisionCommand`/`SiteOperations`) — mirrors
    /// `DeployCommand.deploy`'s own `configDirectory` parameter (#530).
    public let configDirectory: URL?
    /// The site's currently published route set, forwarded from `DeployCommand.deploy`'s
    /// `currentRoutes` parameter — only meaningful when `configDirectory` is non-nil.
    public let currentRoutes: [String]
    /// The credential `authorize(siteDirectory:)` resolved, forwarded verbatim from its
    /// `.ready(credential:)` case.
    public let credential: String
    /// The curated, secret-stripped environment `DeployCommand.hostDeployEnvironment()` produced
    /// for the build/preflight steps — the target adds its own credential to this (rather than
    /// receiving a pre-mixed environment) so the base environment's secret-stripping guarantee is
    /// visible at the target's own call site, not just asserted by the caller.
    public let baseEnvironment: [String: String]
    /// The same `DeployExecutor` `DeployCommand` used for the build/preflight steps — the target
    /// uses it to run its own steps (e.g. `CloudflareDeployTarget` runs `.wrangler` and
    /// `.bundleUpload` through it).
    public let executor: any DeployExecutor
    /// Forwarded verbatim from `DeployCommand.deploy`'s `onDomainAttach` parameter. Only
    /// `CloudflareDeployTarget` fires it today; a target with no equivalent concept simply never
    /// calls it.
    public let onDomainAttach: DeployCommand.DomainAttachObserver?
    /// Forwarded verbatim from `DeployCommand.deploy`'s `onMarkdownForAgents` parameter. Only
    /// `CloudflareDeployTarget` fires it today; a target with no equivalent concept simply never
    /// calls it.
    public let onMarkdownForAgents: DeployCommand.MarkdownForAgentsObserver?
    /// Forwarded verbatim from `DeployCommand.deploy`'s `onProgress` parameter, so the target can
    /// report its own publish-phase milestones (e.g. `.deployDeploying`/`.deployFinalizing`).
    public let onProgress: ProgressHandler?

    public init(
        siteID: String,
        siteDirectory: URL,
        configDirectory: URL?,
        currentRoutes: [String],
        credential: String,
        baseEnvironment: [String: String],
        executor: any DeployExecutor,
        onDomainAttach: DeployCommand.DomainAttachObserver?,
        onMarkdownForAgents: DeployCommand.MarkdownForAgentsObserver?,
        onProgress: ProgressHandler?
    ) {
        self.siteID = siteID
        self.siteDirectory = siteDirectory
        self.configDirectory = configDirectory
        self.currentRoutes = currentRoutes
        self.credential = credential
        self.baseEnvironment = baseEnvironment
        self.executor = executor
        self.onDomainAttach = onDomainAttach
        self.onMarkdownForAgents = onMarkdownForAgents
        self.onProgress = onProgress
    }
}

/// A publishable destination for a site's built static output — the seam that lets
/// `DeployCommand` support hosts beyond Cloudflare (#1015). Each conformer owns everything
/// specific to its provider: credential resolution, any target-specific pre-checks, the actual
/// upload, and post-publish effects. `CloudflareDeployTarget` is the only conformer today.
///
/// `DeployCommand.deploy` calls `authorize(siteDirectory:)` before the shared well-known-scan and
/// build steps run, then `publish(context:)` only after those and the non-bypassable
/// `PreDeployCheck` preflight have all passed — no conformer gets a hook into the preflight gate
/// itself.
public protocol DeployTarget: Sendable {
    /// Stable identifier persisted in `Source/anglesite.json`'s `deployTarget` field (e.g.
    /// `"cloudflare"`). Not yet read by `DeployCommand` to select a conformer (#1015 slice 1) —
    /// reserved for the target-selection slice.
    static var id: String { get }

    /// Pre-build gate: resolves this target's credential and runs any fail-fast checks against
    /// current deployed state. Called before the well-known scan and the build, so a deploy that
    /// can't succeed never pays for either.
    func authorize(siteDirectory: URL) async -> DeployTargetAuthorization

    /// Publishes the build produced by the shared spine and performs any post-publish effects.
    /// Only called after `authorize` returned `.ready`, the well-known scan passed, the build
    /// succeeded, and `PreDeployCheck` passed.
    func publish(context: DeployTargetContext) async -> DeployCommand.Result
}
```

- [ ] **Step 2: Create `Sources/AnglesiteCore/CloudflareDeployTarget.swift`**

```swift
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

    /// All five dependencies are injectable seams with production defaults, so tests can drive a
    /// full deploy — credential gate, name-conflict check, domain-config-drift check, publish —
    /// with a literal token, a canned script-name list, and a scripted executor, never touching
    /// the network or spawning a process.
    public init(
        tokenSource: @escaping TokenSource = CloudflareDeployTarget.keychainTokenSource,
        workerScriptNamesSource: @escaping WorkerScriptNamesSource = CloudflareDeployTarget.defaultWorkerScriptNames,
        customDomainAttachCommand: CustomDomainAttachCommand = CustomDomainAttachCommand(),
        markdownForAgentsCommand: MarkdownForAgentsCommand = MarkdownForAgentsCommand(),
        domainConfigDriftSource: @escaping DomainConfigDriftSource = CloudflareDeployTarget.defaultDomainConfigDriftSource
    ) {
        self.tokenSource = tokenSource
        self.workerScriptNamesSource = workerScriptNamesSource
        self.customDomainAttachCommand = customDomainAttachCommand
        self.markdownForAgentsCommand = markdownForAgentsCommand
        self.domainConfigDriftSource = domainConfigDriftSource
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
}
```

- [ ] **Step 3: Rewrite `Sources/AnglesiteCore/DeployCommand.swift`**

Replace the entire file contents with:

```swift
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
/// executor wraps its `waitForExit` in a cancellation handler that SIGTERMs the in-flight
/// subprocess), so a cancelled build/wrangler is actually killed rather than orphaned.
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

    /// The deploy target this command publishes through — `CloudflareDeployTarget` by default, so
    /// every existing call site keeps deploying through Cloudflare unchanged. `nonisolated` and
    /// public so callers that need to build a parallel command with the same target (e.g.
    /// `DeployModel.runDeploy` swapping in a container executor) can forward it, and so a caller
    /// that knows it's Cloudflare can downcast to reach `CloudflareDeployTarget`'s own exposed
    /// seams (`tokenSource`, `workerScriptNamesSource`, …) for a companion command.
    public nonisolated let target: any DeployTarget
    private let executor: any DeployExecutor

    /// Both dependencies are injectable seams with production defaults, so tests can drive a full
    /// deploy — target authorization, every shared step — with a scripted target and a scripted
    /// executor, never touching the network or spawning a process.
    public init(
        target: any DeployTarget = CloudflareDeployTarget(),
        executor: any DeployExecutor = HostDeployExecutor()
    ) {
        self.target = target
        self.executor = executor
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
```

- [ ] **Step 4: Fix `Sources/AnglesiteApp/DeployModel.swift` (three call sites)**

At line 708, change:
```swift
        wasFirstDeploy = !DeployCommand.hasDeployedBefore(siteDirectory: siteDirectory)
```
to:
```swift
        wasFirstDeploy = !CloudflareDeployTarget.hasDeployedBefore(siteDirectory: siteDirectory)
```

At lines 748-758, change:
```swift
            activeCommand = DeployCommand(
                tokenSource: command.tokenSource,
                workerScriptNamesSource: command.workerScriptNamesSource,
                customDomainAttachCommand: command.customDomainAttachCommand,
                markdownForAgentsCommand: command.markdownForAgentsCommand,
                executor: ContainerDeployExecutor(
                    control: cc.control,
                    siteID: cc.siteID,
                    logCenter: logCenter
                )
            )
```
to:
```swift
            activeCommand = DeployCommand(
                target: command.target,
                executor: ContainerDeployExecutor(
                    control: cc.control,
                    siteID: cc.siteID,
                    logCenter: logCenter
                )
            )
```

At lines 876-925, change:
```swift
        let socialCommand = SocialWorkerProvisionCommand(
            tokenSource: { [weak self] in try await self?.command.tokenSource() },
            runner: containerRunner ?? SocialWorkerProvisionCommand.defaultRunner,
            secretRunner: containerSecretRunner ?? SocialWorkerProvisionCommand.defaultSecretRunner,
            deployer: { [weak self] _, deploySiteID, deploySiteDirectory, _ in
                await activeCommand.deploy(
                    siteID: deploySiteID,
                    siteDirectory: deploySiteDirectory,
                    configDirectory: configDirectory,
                    currentRoutes: currentRoutes,
                    // #744: feeds the same already-validated active route claims (#746, computed
                    // above) into DeployCommand's pre-build /.well-known/ collision check.
                    wellKnownDynamicClaims: WorkerRouteClaims.wellKnownClaims(routeClaims),
                    onPreflight: { [weak self] outcome in
                        Task { @MainActor in self?.onScanComplete?(outcome) }
                    },
                    // Unlike `onPreflight`/`onProgress` (fire-and-forget display state), this
                    // value is read back synchronously in the `.succeeded` case below to decide
                    // the URL swap and the conflict sheet — so the MainActor hop here has an
                    // implicit happens-before dependency, not just a display one. It holds today
                    // only because MainActor drains equal-priority jobs FIFO and several real
                    // `await`s (`uploadSourceBundleIfConfigured`, `runPostDeploySequencing`, the
                    // `SiteConfigStore` load) sit between this closure firing and that read — there
                    // is no structural guarantee. If those intervening `await`s are ever shortened
                    // or removed, this needs an explicit wait instead of relying on scheduling.
                    onDomainAttach: { [weak self] outcome in
                        Task { @MainActor in self?.domainAttachStatus = outcome }
                    },
                    onMarkdownForAgents: { [weak self] outcome in
                        Task { @MainActor in self?.markdownForAgentsStatus = outcome }
                    },
                    onProgress: { [weak self] progress in
                        Task { @MainActor in
                            self?.currentMilestone = progress.label
                            self?.currentMilestonePhase = progress.phase
                            self?.onMilestone?(siteID, progress)
                        }
                    }
                )
            },
            // Forwards the same seam `activeCommand` uses for its own end-of-pipeline check (both
            // are built from `command.workerScriptNamesSource` above), so `provision()`'s new
            // pre-provisioning check (#1075) agrees with `deployer`'s — and so a test's injected
            // fake `DeployCommand` governs both instead of this defaulting to the real network
            // implementation.
            workerScriptNamesSource: { [weak self] token in
                guard let self else { return [] }
                return try await self.command.workerScriptNamesSource(token)
            }
        )
```
to:
```swift
        // Both closures below only make sense against a Cloudflare target — `SocialWorkerProvisionCommand`
        // is itself entirely a Cloudflare Workers concept (out of scope to generalize in #1015
        // slice 1). `cloudflareTarget` is `nil` only if `command.target` were ever something else;
        // today it's always `CloudflareDeployTarget` (the default), so the closures behave exactly
        // as before.
        let cloudflareTarget = command.target as? CloudflareDeployTarget
        let socialCommand = SocialWorkerProvisionCommand(
            tokenSource: {
                guard let cloudflareTarget else { return nil }
                return try await cloudflareTarget.tokenSource()
            },
            runner: containerRunner ?? SocialWorkerProvisionCommand.defaultRunner,
            secretRunner: containerSecretRunner ?? SocialWorkerProvisionCommand.defaultSecretRunner,
            deployer: { [weak self] _, deploySiteID, deploySiteDirectory, _ in
                await activeCommand.deploy(
                    siteID: deploySiteID,
                    siteDirectory: deploySiteDirectory,
                    configDirectory: configDirectory,
                    currentRoutes: currentRoutes,
                    // #744: feeds the same already-validated active route claims (#746, computed
                    // above) into DeployCommand's pre-build /.well-known/ collision check.
                    wellKnownDynamicClaims: WorkerRouteClaims.wellKnownClaims(routeClaims),
                    onPreflight: { [weak self] outcome in
                        Task { @MainActor in self?.onScanComplete?(outcome) }
                    },
                    // Unlike `onPreflight`/`onProgress` (fire-and-forget display state), this
                    // value is read back synchronously in the `.succeeded` case below to decide
                    // the URL swap and the conflict sheet — so the MainActor hop here has an
                    // implicit happens-before dependency, not just a display one. It holds today
                    // only because MainActor drains equal-priority jobs FIFO and several real
                    // `await`s (`uploadSourceBundleIfConfigured`, `runPostDeploySequencing`, the
                    // `SiteConfigStore` load) sit between this closure firing and that read — there
                    // is no structural guarantee. If those intervening `await`s are ever shortened
                    // or removed, this needs an explicit wait instead of relying on scheduling.
                    onDomainAttach: { [weak self] outcome in
                        Task { @MainActor in self?.domainAttachStatus = outcome }
                    },
                    onMarkdownForAgents: { [weak self] outcome in
                        Task { @MainActor in self?.markdownForAgentsStatus = outcome }
                    },
                    onProgress: { [weak self] progress in
                        Task { @MainActor in
                            self?.currentMilestone = progress.label
                            self?.currentMilestonePhase = progress.phase
                            self?.onMilestone?(siteID, progress)
                        }
                    }
                )
            },
            // Forwards the same seam `activeCommand` uses for its own end-of-pipeline check (both
            // are built from `cloudflareTarget.workerScriptNamesSource` above), so `provision()`'s
            // pre-provisioning check (#1075) agrees with `deployer`'s — and so a test's injected
            // fake `DeployCommand`/`CloudflareDeployTarget` governs both instead of this defaulting
            // to the real network implementation.
            workerScriptNamesSource: { token in
                guard let cloudflareTarget else { return [] }
                return try await cloudflareTarget.workerScriptNamesSource(token)
            }
        )
```

- [ ] **Step 5: Fix `Sources/AnglesiteApp/AgentReadinessModel.swift` (one property, one default)**

At lines 21-33, change:
```swift
    private let scanner: any AgentReadinessScanning
    private let tokenSource: DeployCommand.TokenSource
    private var inFlight: Task<Void, Never>?

    private var currentSite: CurrentSite?

    init(
        scanner: any AgentReadinessScanning = HTTPCloudflareClient(),
        tokenSource: @escaping DeployCommand.TokenSource = DeployCommand.keychainTokenSource
    ) {
```
to:
```swift
    private let scanner: any AgentReadinessScanning
    private let tokenSource: CloudflareDeployTarget.TokenSource
    private var inFlight: Task<Void, Never>?

    private var currentSite: CurrentSite?

    init(
        scanner: any AgentReadinessScanning = HTTPCloudflareClient(),
        tokenSource: @escaping CloudflareDeployTarget.TokenSource = CloudflareDeployTarget.keychainTokenSource
    ) {
```

- [ ] **Step 6: Fix `Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift` (five spots)**

At line 115, change:
```swift
    private let workerScriptNamesSource: DeployCommand.WorkerScriptNamesSource
```
to:
```swift
    private let workerScriptNamesSource: CloudflareDeployTarget.WorkerScriptNamesSource
```

At line 121, change:
```swift
        tokenSource: @escaping TokenSource = DeployCommand.keychainTokenSource,
```
to:
```swift
        tokenSource: @escaping TokenSource = CloudflareDeployTarget.keychainTokenSource,
```

At line 132, change:
```swift
        workerScriptNamesSource: @escaping DeployCommand.WorkerScriptNamesSource = DeployCommand.defaultWorkerScriptNames,
```
to:
```swift
        workerScriptNamesSource: @escaping CloudflareDeployTarget.WorkerScriptNamesSource = CloudflareDeployTarget.defaultWorkerScriptNames,
```

At lines 247-249, change:
```swift
        if case .workerNameConflict(let name)? = await DeployCommand.checkWorkerNameConflict(
            siteDirectory: siteDirectory, apiToken: token, workerScriptNamesSource: workerScriptNamesSource
        ) {
```
to:
```swift
        if case .workerNameConflict(let name)? = await CloudflareDeployTarget.checkWorkerNameConflict(
            siteDirectory: siteDirectory, apiToken: token, workerScriptNamesSource: workerScriptNamesSource
        ) {
```

At line 252, change:
```swift
        DeployCommand.persistWorkerProvisioned(siteDirectory: siteDirectory)
```
to:
```swift
        CloudflareDeployTarget.persistWorkerProvisioned(siteDirectory: siteDirectory)
```

At line 840, change:
```swift
    public static let defaultDeployer: Deployer = { token, siteID, siteDirectory, wellKnownDynamicClaims in
        await DeployCommand(tokenSource: { token }).deploy(
            siteID: siteID, siteDirectory: siteDirectory, wellKnownDynamicClaims: wellKnownDynamicClaims)
    }
```
to:
```swift
    public static let defaultDeployer: Deployer = { token, siteID, siteDirectory, wellKnownDynamicClaims in
        await DeployCommand(target: CloudflareDeployTarget(tokenSource: { token })).deploy(
            siteID: siteID, siteDirectory: siteDirectory, wellKnownDynamicClaims: wellKnownDynamicClaims)
    }
```

- [ ] **Step 7: Build `AnglesiteCore` and confirm only test targets fail to compile**

Run: `swift build --package-path . --target AnglesiteCore`
Expected: SUCCEED. This confirms Steps 1-3 and 6 are internally consistent before touching `AnglesiteApp` or tests.

Run: `swift build --package-path . --target AnglesiteApp` (or `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build` if `AnglesiteApp` isn't a standalone SwiftPM build target in this checkout)
Expected: SUCCEED after Steps 4-5. If it fails, the error names the exact remaining `DeployCommand.<removed member>` reference — fix it the same way as Steps 4-6 (retarget to `CloudflareDeployTarget.<member>`).

- [ ] **Step 8: Fix every test call site — mechanical transform**

`DeployCommand`'s old init parameters (`tokenSource:`, `workerScriptNamesSource:`, `customDomainAttachCommand:`, `markdownForAgentsCommand:`, `domainConfigDriftSource:`) moved to `CloudflareDeployTarget`'s init. Every test that constructed a `DeployCommand` with any of those parameters must now construct a `CloudflareDeployTarget` with them instead, and pass it as `DeployCommand`'s new `target:` parameter. `DeployCommand(executor: ...)` calls with no Cloudflare-specific parameter (i.e. bare `DeployCommand()`) need **no change** — the default `target: CloudflareDeployTarget()` behaves identically.

The transform has exactly five shapes, all present in the codebase today. Apply the matching one to every call site listed below, then verify nothing was missed via Step 9's build.

**Shape A — `tokenSource:` + `executor:` only:**
```swift
// before
DeployCommand(tokenSource: { "tok" }, executor: exec)
// after
DeployCommand(target: CloudflareDeployTarget(tokenSource: { "tok" }), executor: exec)
```

**Shape B — `tokenSource:` + `workerScriptNamesSource:` + `executor:`:**
```swift
// before
DeployCommand(
    tokenSource: { "tok" },
    workerScriptNamesSource: { _ in ["taken-name", "other-site"] },
    executor: exec
)
// after
DeployCommand(
    target: CloudflareDeployTarget(
        tokenSource: { "tok" },
        workerScriptNamesSource: { _ in ["taken-name", "other-site"] }
    ),
    executor: exec
)
```

**Shape C — `tokenSource:` + `executor:` + `domainConfigDriftSource:`:**
```swift
// before
DeployCommand(
    tokenSource: { "tok" },
    executor: exec,
    domainConfigDriftSource: { _, _, _ in [finding] }
)
// after
DeployCommand(
    target: CloudflareDeployTarget(
        tokenSource: { "tok" },
        domainConfigDriftSource: { _, _, _ in [finding] }
    ),
    executor: exec
)
```

**Shape D — `tokenSource:` + `customDomainAttachCommand:` + `executor:`:**
```swift
// before
DeployCommand(
    tokenSource: { "test-token" },
    customDomainAttachCommand: CustomDomainAttachCommand(client: writer),
    executor: executor
)
// after
DeployCommand(
    target: CloudflareDeployTarget(
        tokenSource: { "test-token" },
        customDomainAttachCommand: CustomDomainAttachCommand(client: writer)
    ),
    executor: executor
)
```

**Shape E — `tokenSource:` + `customDomainAttachCommand:` + `markdownForAgentsCommand:` + `executor:`:**
```swift
// before
DeployCommand(
    tokenSource: { "test-token" },
    customDomainAttachCommand: CustomDomainAttachCommand(client: writer),
    markdownForAgentsCommand: MarkdownForAgentsCommand(client: writer),
    executor: executor
)
// after
DeployCommand(
    target: CloudflareDeployTarget(
        tokenSource: { "test-token" },
        customDomainAttachCommand: CustomDomainAttachCommand(client: writer),
        markdownForAgentsCommand: MarkdownForAgentsCommand(client: writer)
    ),
    executor: executor
)
```

**No change needed** — bare `DeployCommand()` with no Cloudflare-specific parameter:
- `Tests/AnglesiteCoreTests/SiteOperationsTests.swift:13`, `:565` (`DeployCommand()`)

**Also rename these direct static-member references** (same file, `DeployCommandTests.swift`) — the members moved to `CloudflareDeployTarget`:
- Lines 737, 756, 757: `DeployCommand.persistWorkerProvisioned(...)` → `CloudflareDeployTarget.persistWorkerProvisioned(...)`
- Lines 767, 773: `DeployCommand.hasDeployedBefore(...)` → `CloudflareDeployTarget.hasDeployedBefore(...)`
- Lines 905, 911, 919: `DeployCommand.extractDeployedURL(...)` → `CloudflareDeployTarget.extractDeployedURL(...)`
- Lines 1201, 1220: `DeployCommand.persistSiteURL(...)` → `CloudflareDeployTarget.persistSiteURL(...)`

(`DeployCommand.parseScanReport` at lines 931, 935, 939, 943 stays unchanged — it didn't move.)

Complete inventory of every `DeployCommand(` construction call site to transform, by file:

*`Tests/AnglesiteCoreTests/DeployCommandTests.swift`* — Shape A at lines 112, 128, 161, 181, 206, 229, 288, 307, 327, 352, 371, 389, 462, 475, 489, 502, 518, 535, 551, 567, 582, 597, 623, 639, 895, 974, 1006, 1054, 1075, 1098, 1134, 1164, 1182, 1243, 1273. Shape B at lines 668, 688, 705, 721, 742. Shape C at lines 816, 836, 852, 871. Shape D at lines 1382, 1458. Shape E at line 1415.

*`Tests/AnglesiteCoreTests/DeployExecutorSelectionTests.swift`* — Shape A at lines 42, 64, 88, 101.

*`Tests/AnglesiteCoreTests/DeployCommandProgressTests.swift`* — Shape A at line 13.

*`Tests/AnglesiteCoreTests/SiteOperationsProgressSeamTests.swift`* — Shape A at line 26 (`DeployCommand(tokenSource: { nil })` → `DeployCommand(target: CloudflareDeployTarget(tokenSource: { nil }))`, no `executor:` argument — omit it from the transformed call too, matching the original).

*`Tests/AnglesiteAppTests/DeployModelTests.swift`* — Shape A at lines 102, 439, 577, 610, 647, 685 (no `executor:` argument — omit it, matching the original), 749, 783, 815, 842, 901, 960, 977, 1009, 1029, 1053, 1093. Shape B at lines 146, 214, 259, 465, 512, 546, 707. Shape C at line 178. Shape E at lines 300, 338. Shape D at lines 371, 404.

- [ ] **Step 9: Run the full test suite and fix anything Step 8's inventory missed**

Run: `swift test --package-path .`
Expected: every `AnglesiteCoreTests` and `AnglesiteAppTests` (if runnable outside Xcode — otherwise see below) target compiles and passes. A compile error naming a `DeployCommand(...)` call with an extraneous label (e.g. `tokenSource`) or a missing `CloudflareDeployTarget.` qualifier means Step 8's inventory missed a site — apply the matching Shape transform there too.

`AnglesiteAppTests` (which includes `DeployModelTests.swift`) only runs hosted, per CONTRIBUTING.md: build and run it via
```bash
scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
```
then `xcodebuild test -project Anglesite.xcodeproj -scheme Anglesite -destination 'platform=macOS' -only-testing:AnglesiteAppTests` (or run it from within the Xcode IDE) — do this on Xcode 27 per CONTRIBUTING.md's note that CI never executes this target.

- [ ] **Step 10: Commit**

```bash
git add Sources/AnglesiteCore/DeployTarget.swift Sources/AnglesiteCore/CloudflareDeployTarget.swift \
  Sources/AnglesiteCore/DeployCommand.swift Sources/AnglesiteApp/DeployModel.swift \
  Sources/AnglesiteApp/AgentReadinessModel.swift Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift \
  Tests/AnglesiteCoreTests/DeployCommandTests.swift Tests/AnglesiteCoreTests/DeployExecutorSelectionTests.swift \
  Tests/AnglesiteCoreTests/DeployCommandProgressTests.swift Tests/AnglesiteCoreTests/SiteOperationsProgressSeamTests.swift \
  Tests/AnglesiteAppTests/DeployModelTests.swift
git commit -m "feat(#1015): extract DeployTarget seam, CloudflareDeployTarget"
```

---

## Notes for the executing agent

- **Scope discipline:** this plan intentionally does NOT create a `CloudflareDeployTargetTests.swift` file or relocate any tests — every existing test stays in its current file, only its `DeployCommand(...)` construction call changes. Splitting test files by target is deferred to whichever slice actually adds a second `DeployTarget` conformer (GitHub Pages), when a second file has something real to contrast against. Don't invent that split here.
- **Don't touch** `Sources/AnglesiteCore/DeployExecutor.swift`, `DeployStep`, `DeployStepResult`, `ContainerDeployExecutor`, `HostDeployExecutor` — the executor seam is orthogonal to this refactor and stays exactly as-is.
- **Don't touch** `DeployCommand.LaunchPlan`, `.CommandResolver`, `.PreflightChecker`, `.defaultPreflight`, `.resolveWranglerCommand`, `.resolveBuildCommand`, `.hostDeployEnvironment` (and its allowlist/prefix constants) — these stay on `DeployCommand` because they belong to the shared build/preflight spine, not to Cloudflare specifically, even though `resolveWranglerCommand`'s name mentions wrangler (it's about which `DeployStep` a host-side `CommandResolver` handles, not about the `DeployTarget` seam).
- If `swift build`/`swift test` hangs with no output, a stale SwiftPM process may be holding the `.build` lock (`pgrep -fl swift-test`) — see AGENTS.md ▸ Build.
