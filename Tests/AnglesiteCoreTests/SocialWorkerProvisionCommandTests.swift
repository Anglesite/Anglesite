import Foundation
import Testing
@testable import AnglesiteCore

private func worker(_ id: String, d1: Bool, kv: Bool, r2: Bool) -> WorkerDescriptor {
    WorkerDescriptor(
        id: id, displayName: id, description: "test fixture", group: "test",
        binding: .settingsActivated, resources: .init(needsD1: d1, needsKV: kv, needsR2: r2)
    )
}

private let webmentionWorker = worker("webmention", d1: true, kv: true, r2: false)
private let indieauthWorker = worker("indieauth", d1: true, kv: true, r2: false)
private let micropubWorker = worker("micropub", d1: true, kv: true, r2: true)
private let websubWorker = worker("websub", d1: true, kv: true, r2: false)
private let v2Workers = [webmentionWorker, indieauthWorker]
private let v3Workers = [webmentionWorker, indieauthWorker, micropubWorker, websubWorker]
private let solidOidcWorker = worker(WorkerComposition.solidOidcWorkerID, d1: true, kv: false, r2: false)
private let solidPodWorker = worker(WorkerComposition.solidPodWorkerID, d1: false, kv: false, r2: true)
private let webdavWorker = worker(WorkerComposition.webdavWorkerID, d1: false, kv: false, r2: true)

@Suite("SocialWorkerProvisionCommand")
struct SocialWorkerProvisionCommandTests {
    // MARK: Fake executor

    /// A `DeployExecutor` that returns canned `DeployStepResult`s per step, records the
    /// environment/arguments it was handed per step, and counts how many times each step ran.
    /// Mirrors `DeployCommandTests.swift`'s `FakeExecutor` (kept as this file's own copy, per
    /// Task 13's precedent in `SocialWorkerProvisionTargetTests.swift` — each test file that
    /// drives a full `DeployCommand` spine keeps a local copy rather than sharing one across
    /// files), plus two conveniences (`wranglerSubcommandArguments`/`wranglerSubcommandCalls`)
    /// this file's tests lean on heavily since most of them care only about the `d1`/`kv`/`r2`/
    /// `queues`/migrations argv `SocialWorkerProvisionTarget` issues via `.wranglerSubcommand`.
    private final class FakeExecutor: DeployExecutor, @unchecked Sendable {
        struct Call: Sendable { let step: DeployStep; let environment: [String: String]; let source: String }

        private let lock = NSLock()
        private var byStep: [String: DeployStepResult] = [:]
        private(set) var calls: [Call] = []
        private var runtimeClaims: [RuntimeOwnedPathClaim] = []

        init() {}

        @discardableResult
        func withRuntimeClaims(_ claims: [RuntimeOwnedPathClaim]) -> FakeExecutor {
            lock.lock(); runtimeClaims = claims; lock.unlock()
            return self
        }

        func reportOwnedPathClaims() async -> [RuntimeOwnedPathClaim] {
            lock.lock(); defer { lock.unlock() }
            return runtimeClaims
        }

        private func key(_ step: DeployStep) -> String {
            switch step {
            case .build: return "build"
            case .preflight: return "preflight"
            case .wrangler: return "wrangler"
            case .bundleUpload: return "bundleUpload"
            case .githubPagesPublish: return "githubPagesPublish"
            case .wranglerSubcommand(let args): return "wranglerSubcommand:\(args.joined(separator: " "))"
            }
        }

        @discardableResult
        func set(_ step: DeployStep, exitCode: Int32?, output: String) -> FakeExecutor {
            lock.lock(); byStep[key(step)] = DeployStepResult(exitCode: exitCode, output: output); lock.unlock()
            return self
        }

        func ran(_ step: DeployStep) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return calls.contains { key($0.step) == key(step) }
        }

        func environment(for step: DeployStep) -> [String: String]? {
            lock.lock(); defer { lock.unlock() }
            return calls.first { key($0.step) == key(step) }?.environment
        }

        /// Every `.wranglerSubcommand` call's argv, in call order — the direct equivalent of the
        /// pre-executor `WranglerRecorder.arguments` most of this file's tests asserted against.
        var wranglerSubcommandArguments: [[String]] {
            calls.compactMap {
                if case .wranglerSubcommand(let args) = $0.step { return args }
                return nil
            }
        }

        /// Every `.wranglerSubcommand` call, in order — used where a test needs more than just
        /// the argv (e.g. the environment each call ran with).
        var wranglerSubcommandCalls: [Call] {
            calls.filter {
                if case .wranglerSubcommand = $0.step { return true }
                return false
            }
        }

        func run(step: DeployStep, siteDirectory: URL, environment: [String: String], source: String) async -> DeployStepResult {
            lock.lock()
            calls.append(Call(step: step, environment: environment, source: source))
            let result = byStep[key(step)] ?? DeployStepResult(exitCode: 0, output: "")
            lock.unlock()
            return result
        }
    }

    /// Build the JSON payload the plugin's `pre-deploy-check.ts --json` emits.
    private func scanJSON(ok: Bool) -> String {
        ok ? #"{"version":1,"ok":true,"failures":[],"warnings":[]}"#
           : #"{"version":1,"ok":false,"failures":[{"category":"pii-email","message":"email","file":"dist/index.html","remediation":"wrap it"}],"warnings":[]}"#
    }

    /// A `FakeExecutor` pre-scripted with a successful `.build`/`.preflight`/`.wrangler` trio —
    /// the baseline every provisioning test needs now that `provision()` always drives a full
    /// `DeployCommand` spine (mirrors the old `deployer` closure's canned `.succeeded(...)`
    /// return). Each test layers its own `.wranglerSubcommand` scripts on top via the returned
    /// instance's chainable `set(_:exitCode:output:)`.
    private func successExecutor(url: String = "https://my-site.example.workers.dev") -> FakeExecutor {
        FakeExecutor()
            .set(.build, exitCode: 0, output: "")
            .set(.preflight, exitCode: 0, output: scanJSON(ok: true))
            .set(.wrangler, exitCode: 0, output: "Published site (0.1 sec)\n  \(url)")
    }

    @Test("first-ever deploy (no existing wrangler.toml/CF_PROJECT_NAME) sends a non-empty database name as the d1 create positional argument")
    func firstDeployD1CreateArgumentsAreWellFormed() async throws {
        // Regression coverage for a suspected first-deploy D1-provisioning bug: a brand-new site
        // (empty `siteDirectory`, `knownResources` defaults to `.init()`) with a D1-needing
        // worker active. The concern was that `wrangler d1 create <name> --json` might reach the
        // real subprocess with an empty/missing name positional (reproducing wrangler's own "Not
        // enough non-option arguments" usage synopsis) — this asserts the exact argv
        // `SocialWorkerProvisionTarget` hands to the executor's `.wranglerSubcommand` step
        // contains a well-formed, non-empty name in the correct position, so any future refactor
        // that drops or empties it fails this test immediately.
        let site = try temporaryDirectory()
        #expect(!FileManager.default.fileExists(atPath: site.appendingPathComponent("wrangler.toml").path))
        let executor = successExecutor(url: "https://example.com")
            .set(.wranglerSubcommand(args: ["d1", "create", "my-site-social"]), exitCode: 0, output: #"{"result":{"uuid":"d1-id"}}"#)
            .set(.wranglerSubcommand(args: ["d1", "migrations", "apply", "AUTH_DB", "--remote"]), exitCode: 0, output: "Migrations applied")
        let command = SocialWorkerProvisionCommand(tokenSource: { "token" }, executor: executor)
        let indieauth = worker(WorkerComposition.indieauthWorkerID, d1: true, kv: false, r2: false)

        let result = await command.provision(
            siteID: "site-1", siteDirectory: site, siteName: "my-site",
            workers: [indieauth], knownResources: .init()
        )

        guard case .succeeded = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        let d1CreateCall = try #require(executor.wranglerSubcommandArguments.first { $0.first == "d1" && $0.dropFirst().first == "create" })
        #expect(d1CreateCall.count == 3, "expected exactly [\"d1\", \"create\", <name>], got \(d1CreateCall)")
        let name = d1CreateCall[2]
        #expect(!name.isEmpty, "the database name positional must never be empty")
        #expect(name == "my-site-social")
        #expect(d1CreateCall == ["d1", "create", "my-site-social"])
    }

    @Test("provisions V-2 D1 and KV, writes wrangler.toml, then deploys through DeployCommand seam")
    func provisionsV2Worker() async throws {
        let site = try temporaryDirectory()
        let executor = successExecutor()
            .set(.wranglerSubcommand(args: ["d1", "create", "my-site-social"]), exitCode: 0, output: #"{"result":{"uuid":"d1-id"}}"#)
            .set(.wranglerSubcommand(args: ["kv", "namespace", "create", "my-site-social"]), exitCode: 0, output: #"{"result":{"id":"kv-id"}}"#)
            .set(.wranglerSubcommand(args: ["queues", "create", "my-site-webmention"]), exitCode: 0, output: #"{"result":{"queue_name":"my-site-webmention"}}"#)
            .set(.wranglerSubcommand(args: ["d1", "migrations", "apply", "AUTH_DB", "--remote"]), exitCode: 0, output: "Migrations applied")
        let command = SocialWorkerProvisionCommand(tokenSource: { "token" }, executor: executor)

        let result = await command.provision(
            siteID: "site-1", siteDirectory: site, siteName: "my-site", workers: v2Workers,
            acknowledgesPaidPlan: true
        )

        guard case .succeeded(let url, let resources, _) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(url == URL(string: "https://my-site.example.workers.dev"))
        #expect(resources.d1DatabaseID == "d1-id")
        #expect(resources.kvNamespaceID == "kv-id")
        #expect(resources.r2BucketName == nil)
        #expect(resources.queueName == "my-site-webmention")
        #expect(executor.wranglerSubcommandArguments == [
            ["d1", "create", "my-site-social"],
            ["kv", "namespace", "create", "my-site-social"],
            ["queues", "create", "my-site-webmention"],
            ["d1", "migrations", "apply", "AUTH_DB", "--remote"],
        ])
        #expect(executor.wranglerSubcommandCalls.allSatisfy { $0.environment["CLOUDFLARE_API_TOKEN"] == "token" })
        #expect(executor.ran(.wrangler))
        #expect(executor.environment(for: .wrangler)?["CLOUDFLARE_API_TOKEN"] == "token")

        let toml = try String(contentsOf: site.appendingPathComponent("wrangler.toml"), encoding: .utf8)
        #expect(toml.contains("main = \"worker/worker.ts\""))
        #expect(toml.contains("database_id = \"d1-id\""))
        #expect(toml.contains("id = \"kv-id\""))
        #expect(!toml.contains("[[r2_buckets]]"))
    }

    @Test("a running experiment on a static-only site (no active workers) provisions D1 and applies its migration")
    func runningExperimentProvisionsD1() async throws {
        let site = try temporaryDirectory()
        let executor = successExecutor()
            .set(.wranglerSubcommand(args: ["d1", "create", "my-site-social"]), exitCode: 0, output: #"{"result":{"uuid":"d1-id"}}"#)
            .set(.wranglerSubcommand(args: ["d1", "migrations", "apply", "EXPERIMENTS_DB", "--remote"]), exitCode: 0, output: "Migrations applied")
        let command = SocialWorkerProvisionCommand(tokenSource: { "token" }, executor: executor)
        let experiment = DomainConfig.Experiments.Experiment(
            id: "homepage-hero", name: "Homepage headline", page: "/",
            variant: .init(id: "b", name: "Fresh eggs headline", page: "/x/homepage-hero/b/"),
            split: 0.5, goal: .init(kind: "pageview", path: "/contact/thanks/"), status: "running"
        )

        let result = await command.provision(
            siteID: "site-1", siteDirectory: site, siteName: "my-site",
            workers: [], experiments: [experiment]
        )

        guard case .succeeded(_, let resources, _) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(resources.d1DatabaseID == "d1-id")
        #expect(executor.wranglerSubcommandArguments == [
            ["d1", "create", "my-site-social"],
            ["d1", "migrations", "apply", "EXPERIMENTS_DB", "--remote"],
        ])
        let toml = try String(contentsOf: site.appendingPathComponent("wrangler.toml"), encoding: .utf8)
        #expect(toml.contains("binding = \"EXPERIMENTS_DB\""))
        #expect(toml.contains("database_id = \"d1-id\""))
        #expect(toml.contains(#"run_worker_first = ["/", "/contact/thanks/"]"#))
    }

    @Test("no running experiment never invokes the EXPERIMENTS_DB migration")
    func noRunningExperimentSkipsMigration() async throws {
        let site = try temporaryDirectory()
        let executor = successExecutor()
        let command = SocialWorkerProvisionCommand(tokenSource: { "token" }, executor: executor)

        let result = await command.provision(
            siteID: "site-1", siteDirectory: site, siteName: "my-site", workers: []
        )

        guard case .succeeded = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(executor.wranglerSubcommandArguments.isEmpty)
    }

    @Test("mcpEnabled alone (no active workers) provisions SOCIAL_KV and composes the Worker")
    func mcpEnabledProvisionsSocialKV() async throws {
        let site = try temporaryDirectory()
        let executor = successExecutor()
            .set(.wranglerSubcommand(args: ["kv", "namespace", "create", "my-site-social"]), exitCode: 0, output: #"{"result":{"id":"kv-id"}}"#)
        let command = SocialWorkerProvisionCommand(tokenSource: { "token" }, executor: executor)

        let result = await command.provision(
            siteID: "site-1", siteDirectory: site, siteName: "my-site", workers: [],
            mcpEnabled: true
        )

        guard case .succeeded(_, let resources, _) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(resources.kvNamespaceID == "kv-id")
        let toml = try String(contentsOf: site.appendingPathComponent("wrangler.toml"), encoding: .utf8)
        #expect(toml.contains("main = \"worker/worker.ts\""))
        #expect(toml.contains("binding = \"SOCIAL_KV\""))
        #expect(toml.contains("run_worker_first = [\"/mcp\"]"))
    }

    @Test("mcpEnabled false with no workers provisions nothing")
    func mcpDisabledProvisionsNothing() async throws {
        let site = try temporaryDirectory()
        let executor = successExecutor()
        let command = SocialWorkerProvisionCommand(tokenSource: { "token" }, executor: executor)

        let result = await command.provision(siteID: "site-1", siteDirectory: site, siteName: "my-site", workers: [])

        guard case .succeeded = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(executor.wranglerSubcommandArguments.isEmpty)
    }

    @Test("threads activityPubActorType and moderators into the deployed wrangler.toml")
    func provisionsGroupActorWithModerators() async throws {
        let site = try temporaryDirectory()
        let executor = successExecutor()
        let command = SocialWorkerProvisionCommand(
            tokenSource: { "token" },
            executor: executor,
            keyPairSource: { _ in
                .init(privateKeyPem: "PRIVATE-PEM", publicKeyPem: "PUBLIC-PEM", publishToken: "TOKEN-VALUE")
            },
            secretRunner: { _, _, _, _, _ in .init(stdout: "Success!", stderr: "", exitCode: 0) }
        )
        // AP_ACTOR_TYPE/AP_MODERATORS are gated on `hasActivityPub`
        // (`WorkerComposition.swift`'s `workers.contains(where: { $0.id == activitypubWorkerID })`),
        // so the activitypub worker must be active for this test to observe the threaded values.
        let activitypub = worker(WorkerComposition.activitypubWorkerID, d1: false, kv: false, r2: false)

        let result = await command.provision(
            siteID: "site-1", siteDirectory: site, siteName: "my-site", workers: [activitypub],
            activityPubActorType: "Group", moderators: ["https://mod.example/actor"]
        )

        guard case .succeeded = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        let toml = try String(contentsOf: site.appendingPathComponent("wrangler.toml"), encoding: .utf8)
        #expect(toml.contains("AP_ACTOR_TYPE = \"Group\""))
        #expect(toml.contains("AP_MODERATORS = \"https://mod.example/actor\""))
    }

    @Test("omitting activityPubActorType leaves an ordinary Person actor, unaffected")
    func provisionsWithoutActorTypeStaysUnaffected() async throws {
        let site = try temporaryDirectory()
        let executor = successExecutor()
        let command = SocialWorkerProvisionCommand(tokenSource: { "token" }, executor: executor)

        let result = await command.provision(siteID: "site-1", siteDirectory: site, siteName: "my-site", workers: [])

        guard case .succeeded = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        let toml = try String(contentsOf: site.appendingPathComponent("wrangler.toml"), encoding: .utf8)
        #expect(!toml.contains("AP_ACTOR_TYPE"))
        #expect(!toml.contains("AP_MODERATORS"))
    }

    @Test("a forwarded wellKnownDynamicClaim reaches the deploy spine's collision check (#934)")
    func forwardsWellKnownDynamicClaimsToDeployer() async throws {
        // Proves `provision()` forwards `wellKnownDynamicClaims` all the way to
        // `DeployCommand.deploy` (not just to some intermediate step): a runtime claim planted at
        // the exact suffix the forwarded dynamic claim covers must collide, which is only
        // possible if the claim genuinely reached the real #744 merge. This is strictly stronger
        // than the old assertion (which only checked a fake `deployer` closure's argument
        // values) — see `DeployCommandTests.wellKnownDynamicRuntimeCollisionBlocks` for the same
        // mechanic exercised directly against `DeployCommand`.
        let site = try temporaryDirectory()
        let executor = FakeExecutor()
            .withRuntimeClaims([RuntimeOwnedPathClaim(
                id: "acme", owner: "cloudflare-managed-tls", path: "acme-challenge/", match: .prefix,
                capability: "RFC 8555 managed-TLS ownership")])
            .set(.build, exitCode: 0, output: "should not run")
        let command = SocialWorkerProvisionCommand(tokenSource: { "token" }, executor: executor)
        let claim = WorkerRouteClaims.OwnedClaim(
            owner: "webfinger",
            claim: WorkerRouteClaim(path: "/.well-known/acme-challenge/http-01", match: .exact, methods: ["GET"], handler: "webfinger")
        )

        let result = await command.provision(
            siteID: "site-1", siteDirectory: site, siteName: "my-site", workers: v2Workers,
            acknowledgesPaidPlan: true, wellKnownDynamicClaims: [claim]
        )

        guard case .blocked(let failures, _, _) = result else {
            Issue.record("expected .blocked once the forwarded claim collides with the runtime reservation, got \(result)")
            return
        }
        #expect(failures.first?.category == .wellKnownCollision)
        #expect(!executor.ran(.build), "the collision must block before any provisioning or build work runs")
    }

    @Test("provisions R2 only when a selected feature needs media")
    func provisionsR2ForMicropub() async throws {
        let site = try temporaryDirectory()
        let executor = successExecutor()
            .set(.wranglerSubcommand(args: ["d1", "create", "my-site-social"]), exitCode: 0, output: #"{"uuid":"d1-id"}"#)
            .set(.wranglerSubcommand(args: ["kv", "namespace", "create", "my-site-social"]), exitCode: 0, output: #"{"id":"kv-id"}"#)
            .set(.wranglerSubcommand(args: ["r2", "bucket", "create", "my-site-media"]), exitCode: 0, output: "Created bucket my-site-media")
            .set(.wranglerSubcommand(args: ["queues", "create", "my-site-webmention"]), exitCode: 0, output: #"{"result":{"queue_name":"my-site-webmention"}}"#)
            .set(.wranglerSubcommand(args: ["queues", "create", "my-site-websub"]), exitCode: 0, output: #"{"result":{"queue_name":"my-site-websub"}}"#)
            .set(.wranglerSubcommand(args: ["d1", "migrations", "apply", "AUTH_DB", "--remote"]), exitCode: 0, output: "Migrations applied")
        let command = SocialWorkerProvisionCommand(tokenSource: { "token" }, executor: executor)

        let result = await command.provision(
            siteID: "site-1",
            siteDirectory: site,
            siteName: "my-site",
            workers: v3Workers,
            acknowledgesPaidPlan: true
        )

        guard case .succeeded(_, let resources, _) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(resources.r2BucketName == "my-site-media")

        let toml = try String(contentsOf: site.appendingPathComponent("wrangler.toml"), encoding: .utf8)
        #expect(toml.contains("[[r2_buckets]]"))
        #expect(toml.contains("bucket_name = \"my-site-media\""))
    }

    @Test("inboxCaptureEnabled creates the INBOX_KV namespace, resolves the account id, and writes both into wrangler.toml")
    func provisionsInboxCapture() async throws {
        let site = try temporaryDirectory()
        let executor = successExecutor()
            .set(.wranglerSubcommand(args: ["kv", "namespace", "create", "my-site-inbox"]), exitCode: 0, output: #"{"result":{"id":"inbox-kv-id"}}"#)
        let command = SocialWorkerProvisionCommand(
            tokenSource: { "token" },
            executor: executor,
            accountIDSource: { _ in "acct-1" }
        )

        let result = await command.provision(
            siteID: "site-1", siteDirectory: site, siteName: "my-site", workers: [],
            inboxCaptureEnabled: true
        )

        guard case .succeeded(_, let resources, _) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(resources.inboxKVNamespaceID == "inbox-kv-id")
        #expect(resources.inboxAccountID == "acct-1")
        #expect(executor.wranglerSubcommandArguments == [
            ["kv", "namespace", "create", "my-site-inbox"],
        ])

        let toml = try String(contentsOf: site.appendingPathComponent("wrangler.toml"), encoding: .utf8)
        #expect(toml.contains("main = \"worker/worker.ts\""))
        #expect(toml.contains("id = \"inbox-kv-id\""))
    }

    @Test("inboxCaptureEnabled + inboxForwardEmail writes a send_email binding into wrangler.toml")
    func provisionsInboxCaptureWithForwardEmail() async throws {
        let site = try temporaryDirectory()
        let executor = successExecutor()
            .set(.wranglerSubcommand(args: ["kv", "namespace", "create", "my-site-inbox"]), exitCode: 0, output: #"{"result":{"id":"inbox-kv-id"}}"#)
        let command = SocialWorkerProvisionCommand(
            tokenSource: { "token" },
            executor: executor,
            accountIDSource: { _ in "acct-1" }
        )

        let result = await command.provision(
            siteID: "site-1", siteDirectory: site, siteName: "my-site", workers: [],
            inboxCaptureEnabled: true, inboxForwardEmail: "owner@example.com"
        )

        guard case .succeeded = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        let toml = try String(contentsOf: site.appendingPathComponent("wrangler.toml"), encoding: .utf8)
        #expect(toml.contains("[[send_email]]"))
        #expect(toml.contains("destination_address = \"owner@example.com\""))
        #expect(toml.contains("INBOX_FORWARD_EMAIL = \"owner@example.com\""))
    }

    @Test("inboxCaptureEnabled false never invokes wrangler kv namespace create")
    func inboxCaptureDisabledNeverCreatesNamespace() async throws {
        let site = try temporaryDirectory()
        let executor = successExecutor()
        // `accountIDSource` is also consulted unconditionally by `CloudflareDeployTarget.publish`
        // for its own CLOUDFLARE_ACCOUNT_ID convenience (#1853) — unrelated to inbox capture, and
        // not skippable by toggling that feature off. So this counts calls instead of asserting
        // zero: exactly one (the deploy-stage resolution) proves the inbox-specific block below it
        // (gated on `inboxCaptureEnabled`) never separately consulted the same seam.
        var accountIDSourceCallCount = 0
        let command = SocialWorkerProvisionCommand(
            tokenSource: { "token" },
            executor: executor,
            accountIDSource: { _ in
                accountIDSourceCallCount += 1
                return "acct-1"
            }
        )

        let result = await command.provision(siteID: "site-1", siteDirectory: site, siteName: "my-site", workers: [])

        guard case .succeeded(_, let resources, _) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(resources.inboxKVNamespaceID == nil)
        #expect(executor.wranglerSubcommandArguments.isEmpty)
        #expect(accountIDSourceCallCount == 1, "must not additionally resolve an account id for disabled inbox capture")
    }

    @Test("toggling inbox capture off after provisioning drops the route/binding but keeps the namespace id")
    func inboxCaptureToggledOffAfterProvisioningDropsRouteKeepsNamespace() async throws {
        // Regression coverage for the review's "provisioned, then paused" gap: unlike
        // `inboxCaptureDisabledNeverCreatesNamespace` (which only covers "never provisioned,
        // stays off"), this starts from a site that already has a live namespace
        // (`knownResources.inboxKVNamespaceID` set) and re-provisions with the toggle off — the
        // actual de-provisioning path the Settings UI toggle exists to support.
        let site = try temporaryDirectory()
        let executor = successExecutor()
        // See `inboxCaptureDisabledNeverCreatesNamespace`'s comment: `accountIDSource` is also
        // consulted unconditionally by the deploy stage's own CLOUDFLARE_ACCOUNT_ID convenience,
        // so this counts calls (expecting exactly one) instead of asserting zero.
        var accountIDSourceCallCount = 0
        let command = SocialWorkerProvisionCommand(
            tokenSource: { "token" },
            executor: executor,
            accountIDSource: { _ in
                accountIDSourceCallCount += 1
                return "acct-1"
            }
        )

        let result = await command.provision(
            siteID: "site-1", siteDirectory: site, siteName: "my-site", workers: [],
            knownResources: .init(inboxKVNamespaceID: "existing-ns", inboxAccountID: "existing-acct"),
            inboxCaptureEnabled: false
        )

        guard case .succeeded(_, let resources, _) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        // The KV namespace and its staged submissions are never deleted by toggling off — only
        // the wrangler.toml route/binding drops. The next re-enable reuses this same namespace
        // instead of creating a new, orphaned one.
        #expect(resources.inboxKVNamespaceID == "existing-ns")
        #expect(resources.inboxAccountID == "existing-acct")
        #expect(executor.wranglerSubcommandArguments.isEmpty, "must not call wrangler kv namespace create/delete when toggling off")
        #expect(accountIDSourceCallCount == 1, "must not additionally resolve an account id for disabled inbox capture")

        let toml = try String(contentsOf: site.appendingPathComponent("wrangler.toml"), encoding: .utf8)
        #expect(!toml.contains("INBOX_KV"), "the [[kv_namespaces]] binding must drop once inbox capture is off")
        #expect(!toml.contains("/inbox"), "the /inbox route claim must drop once inbox capture is off")
    }

    @Test("a namespace id already known from settings is reused, not recreated")
    func inboxCaptureReusesKnownNamespace() async throws {
        let site = try temporaryDirectory()
        let executor = successExecutor()
        // See `inboxCaptureDisabledNeverCreatesNamespace`'s comment: `accountIDSource` is also
        // consulted unconditionally by the deploy stage's own CLOUDFLARE_ACCOUNT_ID convenience,
        // so this counts calls (expecting exactly one) instead of asserting zero.
        var accountIDSourceCallCount = 0
        let command = SocialWorkerProvisionCommand(
            tokenSource: { "token" },
            executor: executor,
            accountIDSource: { _ in
                accountIDSourceCallCount += 1
                return "acct-1"
            }
        )

        let result = await command.provision(
            siteID: "site-1", siteDirectory: site, siteName: "my-site", workers: [],
            knownResources: .init(inboxKVNamespaceID: "existing-ns", inboxAccountID: "existing-acct"),
            inboxCaptureEnabled: true
        )

        guard case .succeeded(_, let resources, _) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(resources.inboxKVNamespaceID == "existing-ns")
        #expect(resources.inboxAccountID == "existing-acct")
        #expect(executor.wranglerSubcommandArguments.isEmpty)
        #expect(accountIDSourceCallCount == 1, "must not additionally resolve an account id when it's already known")
    }

    @Test("a known namespace with a still-nil account id retries account resolution without re-creating the namespace")
    func inboxCaptureRetriesStrandedAccountID() async throws {
        // Regression coverage for the final-review finding: if a prior provisioning run created
        // the KV namespace but `accountIDSource` returned nil that time (e.g. a transient
        // Cloudflare API error), the account id must still be resolvable on a later run — it must
        // not be permanently stranded just because the namespace already exists.
        let site = try temporaryDirectory()
        let executor = successExecutor()
        let command = SocialWorkerProvisionCommand(
            tokenSource: { "token" },
            executor: executor,
            accountIDSource: { _ in "acct-2" }
        )

        let result = await command.provision(
            siteID: "site-1", siteDirectory: site, siteName: "my-site", workers: [],
            knownResources: .init(inboxKVNamespaceID: "existing-ns", inboxAccountID: nil),
            inboxCaptureEnabled: true
        )

        guard case .succeeded(_, let resources, _) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(resources.inboxKVNamespaceID == "existing-ns")
        #expect(resources.inboxAccountID == "acct-2")
        #expect(executor.wranglerSubcommandArguments.isEmpty, "must not call wrangler kv namespace create again for a namespace that already exists")
    }

    @Test("a KV creation failure for inbox capture is reported without corrupting resources")
    func inboxCapturePartialFailure() async throws {
        let site = try temporaryDirectory()
        let executor = successExecutor()
            .set(.wranglerSubcommand(args: ["kv", "namespace", "create", "my-site-inbox"]), exitCode: 1, output: "KV failed")
        let command = SocialWorkerProvisionCommand(
            tokenSource: { "token" },
            executor: executor,
            accountIDSource: { _ in "acct-1" }
        )

        let result = await command.provision(
            siteID: "site-1", siteDirectory: site, siteName: "my-site", workers: [],
            inboxCaptureEnabled: true
        )

        guard case .failed(let reason, let exitCode, let resources) = result else {
            Issue.record("expected failure, got \(result)")
            return
        }
        #expect(reason == "KV failed")
        #expect(exitCode == 1)
        #expect(resources.inboxKVNamespaceID == nil)
        #expect(!executor.ran(.wrangler))
    }

    @Test("provisions Micropub (real catalog id, requires indieauth) end-to-end")
    func provisionsMicropubWithIndieauth() async throws {
        let site = try temporaryDirectory()
        let executor = successExecutor()
            .set(.wranglerSubcommand(args: ["d1", "create", "my-site-social"]), exitCode: 0, output: #"{"result":{"uuid":"d1-id"}}"#)
            .set(.wranglerSubcommand(args: ["r2", "bucket", "create", "my-site-media"]), exitCode: 0, output: "Created bucket my-site-media")
            .set(.wranglerSubcommand(args: ["d1", "migrations", "apply", "AUTH_DB", "--remote"]), exitCode: 0, output: "Migrations applied")
        let command = SocialWorkerProvisionCommand(tokenSource: { "token" }, executor: executor)
        let indieauth = worker(WorkerComposition.indieauthWorkerID, d1: true, kv: false, r2: false)
        let micropub = worker(WorkerComposition.micropubWorkerID, d1: true, kv: false, r2: true)

        let result = await command.provision(
            siteID: "site-1", siteDirectory: site, siteName: "my-site",
            workers: [indieauth, micropub], acknowledgesPaidPlan: true
        )

        guard case .succeeded(_, let resources, _) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(resources.d1DatabaseID == "d1-id")
        #expect(resources.r2BucketName == "my-site-media")

        let toml = try String(contentsOf: site.appendingPathComponent("wrangler.toml"), encoding: .utf8)
        #expect(toml.contains("binding = \"MICROPUB_DB\""))
        #expect(toml.contains("binding = \"AUTH_DB\""))
        #expect(toml.contains("[[r2_buckets]]"))
        #expect(toml.contains("bucket_name = \"my-site-media\""))
    }

    @Test("provisions ActivityPub: generates keys once, pushes secrets, writes the DO binding")
    func provisionsActivityPub() async throws {
        let site = try temporaryDirectory()
        let executor = successExecutor()
        var pushedSecrets: [(name: String, value: String)] = []
        let secretRunnerLock = NSLock()
        let command = SocialWorkerProvisionCommand(
            tokenSource: { "token" },
            executor: executor,
            keyPairSource: { _ in
                .init(privateKeyPem: "PRIVATE-PEM", publicKeyPem: "PUBLIC-PEM", publishToken: "TOKEN-VALUE")
            },
            secretRunner: { _, name, value, _, _ in
                secretRunnerLock.lock()
                pushedSecrets.append((name, value))
                secretRunnerLock.unlock()
                return .init(stdout: "Success!", stderr: "", exitCode: 0)
            }
        )
        let activitypub = worker(WorkerComposition.activitypubWorkerID, d1: false, kv: false, r2: false)

        let result = await command.provision(siteID: "site-1", siteDirectory: site, siteName: "my-site", workers: [activitypub])

        guard case .succeeded = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(pushedSecrets.contains { $0.name == "AP_PRIVATE_KEY" && $0.value == "PRIVATE-PEM" })
        #expect(pushedSecrets.contains { $0.name == "AP_PUBLIC_KEY" && $0.value == "PUBLIC-PEM" })
        #expect(pushedSecrets.contains { $0.name == "AP_PUBLISH_TOKEN" && $0.value == "TOKEN-VALUE" })

        let toml = try String(contentsOf: site.appendingPathComponent("wrangler.toml"), encoding: .utf8)
        #expect(toml.contains("[[durable_objects.bindings]]"))
    }

    @Test("ActivityPub-only (no D1/KV/R2 worker active) has wrangler.toml on disk before the first secret push")
    func activitypubOnlyPersistsConfigBeforeSecrets() async throws {
        // ActivityPub's catalog resources are all needsD1/needsKV/needsR2 == false (it only needs
        // a Durable Object, which isn't tracked by those flags), so when it's the only active
        // worker none of the D1/KV/R2 blocks in `SocialWorkerProvisionTarget.publish` run.
        // Regression coverage for #363: `wrangler secret put` resolves its target Worker's name
        // from `wrangler.toml` in the working directory, so that file must already exist by the
        // time the first secretRunner call happens — checking only the final on-disk state (as
        // `provisionsActivityPub` above does) wouldn't catch an ordering bug, since the
        // unconditional `persistConfig` call at the very end of `publish()` would paper over it
        // in a passing test even with the bug present. So this secretRunner closure itself reads
        // and asserts on `wrangler.toml` *before* returning success — that's exactly the moment a
        // real `wrangler secret put` subprocess would need the file to already be resolvable.
        let site = try temporaryDirectory()
        let executor = successExecutor()
        var secretRunnerCallCount = 0
        var tomlContentsAtFirstSecretCall: String?
        let command = SocialWorkerProvisionCommand(
            tokenSource: { "token" },
            executor: executor,
            keyPairSource: { _ in
                .init(privateKeyPem: "PRIVATE-PEM", publicKeyPem: "PUBLIC-PEM", publishToken: "TOKEN-VALUE")
            },
            secretRunner: { siteDirectory, _, _, _, _ in
                secretRunnerCallCount += 1
                if secretRunnerCallCount == 1 {
                    tomlContentsAtFirstSecretCall = try? String(
                        contentsOf: siteDirectory.appendingPathComponent("wrangler.toml"), encoding: .utf8
                    )
                }
                return .init(stdout: "Success!", stderr: "", exitCode: 0)
            }
        )
        let activitypub = worker(WorkerComposition.activitypubWorkerID, d1: false, kv: false, r2: false)

        let result = await command.provision(siteID: "site-1", siteDirectory: site, siteName: "my-site", workers: [activitypub])

        guard case .succeeded = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(secretRunnerCallCount == 3)
        let toml = try #require(tomlContentsAtFirstSecretCall, "wrangler.toml must exist before the first secretRunner call")
        #expect(toml.contains("[[durable_objects.bindings]]"))
    }

    @Test("no activitypub worker means keyPairSource and the ActivityPub secretRunner calls never run")
    func noActivitypubSkipsKeyGeneration() async throws {
        let site = try temporaryDirectory()
        let executor = successExecutor()
        var keyPairSourceCalled = false
        var secretRunnerCalled = false
        let command = SocialWorkerProvisionCommand(
            tokenSource: { "token" },
            executor: executor,
            keyPairSource: { _ in
                keyPairSourceCalled = true
                return .init(privateKeyPem: "x", publicKeyPem: "y", publishToken: "z")
            },
            secretRunner: { _, _, _, _, _ in
                secretRunnerCalled = true
                return .init(stdout: "", stderr: "", exitCode: 0)
            }
        )

        _ = await command.provision(siteID: "site-1", siteDirectory: site, siteName: "my-site", workers: [])

        #expect(!keyPairSourceCalled)
        #expect(!secretRunnerCalled)
    }

    @Test("a secretRunner failure fails provisioning before deploy")
    func secretPushFailureFailsProvisioning() async throws {
        let site = try temporaryDirectory()
        let executor = successExecutor()
        let command = SocialWorkerProvisionCommand(
            tokenSource: { "token" },
            executor: executor,
            keyPairSource: { _ in .init(privateKeyPem: "PRIVATE-PEM", publicKeyPem: "PUBLIC-PEM", publishToken: "TOKEN-VALUE") },
            secretRunner: { _, name, _, _, _ in
                if name == "AP_PUBLIC_KEY" {
                    return .init(stdout: "", stderr: "authentication error", exitCode: 1)
                }
                return .init(stdout: "Success!", stderr: "", exitCode: 0)
            }
        )
        let activitypub = worker(WorkerComposition.activitypubWorkerID, d1: false, kv: false, r2: false)

        let result = await command.provision(siteID: "site-1", siteDirectory: site, siteName: "my-site", workers: [activitypub])

        guard case .failed = result else {
            Issue.record("expected failure, got \(result)")
            return
        }
        #expect(!executor.ran(.wrangler))
    }

    @Test("A retry after an earlier attempt's own secret push isn't mistaken for a foreign Worker-name conflict (#1075)")
    func retryAfterOwnSecretPushDoesNotFalselyConflict() async throws {
        let site = try temporaryDirectory()
        // Mirrors the reported repro: `.site-config` already carries this site's own established
        // project name from an earlier (partially-failed) attempt.
        try "CF_PROJECT_NAME=my-site\n".write(to: site.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)
        let remoteNames = ToggleableWorkerNames()
        // First attempt fails at the deploy stage for an unrelated reason, AFTER secrets have
        // already pushed (activitypub needs no D1/KV/R2, so `.wrangler` is the very next step).
        let executor = successExecutor().set(.wrangler, exitCode: 1, output: "network timeout")
        let command = SocialWorkerProvisionCommand(
            tokenSource: { "token" },
            executor: executor,
            keyPairSource: { _ in
                .init(privateKeyPem: "PRIVATE-PEM", publicKeyPem: "PUBLIC-PEM", publishToken: "TOKEN-VALUE")
            },
            secretRunner: { _, _, _, _, _ in
                // Mirrors the real `wrangler secret put` side effect described in the bug report:
                // once our own secret push succeeds, the account reports this name as an existing
                // Worker script from then on.
                await remoteNames.set(["my-site"])
                return .init(stdout: "Success!", stderr: "", exitCode: 0)
            },
            workerScriptNamesSource: { _ in await remoteNames.current }
        )
        let activitypub = worker(WorkerComposition.activitypubWorkerID, d1: false, kv: false, r2: false)

        let firstResult = await command.provision(
            siteID: "site-1", siteDirectory: site, siteName: "my-site", workers: [activitypub]
        )
        guard case .failed = firstResult else {
            Issue.record("expected the first attempt to fail for the unrelated reason, got \(firstResult)")
            return
        }

        executor.set(.wrangler, exitCode: 0, output: "Published site (0.1 sec)\n  https://my-site.example.workers.dev")
        let secondResult = await command.provision(
            siteID: "site-1", siteDirectory: site, siteName: "my-site", workers: [activitypub]
        )
        guard case .succeeded = secondResult else {
            Issue.record("expected the retry to succeed instead of reporting a false worker-name conflict, got \(secondResult)")
            return
        }
    }

    @Test("A genuinely foreign name collision is caught before any wrangler call touches it (#1075)")
    func foreignConflictCaughtBeforeAnyProvisioning() async throws {
        let site = try temporaryDirectory()
        try "CF_PROJECT_NAME=my-site\n".write(to: site.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)
        var secretRunnerCalled = false
        let executor = successExecutor()
        let command = SocialWorkerProvisionCommand(
            tokenSource: { "token" },
            executor: executor,
            keyPairSource: { _ in .init(privateKeyPem: "x", publicKeyPem: "y", publishToken: "z") },
            secretRunner: { _, _, _, _, _ in
                secretRunnerCalled = true
                return .init(stdout: "Success!", stderr: "", exitCode: 0)
            },
            // The account already has a script under this exact name — a genuinely foreign
            // project this site's local config has no history with.
            workerScriptNamesSource: { _ in ["my-site"] }
        )
        let activitypub = worker(WorkerComposition.activitypubWorkerID, d1: true, kv: false, r2: false)

        let result = await command.provision(
            siteID: "site-1", siteDirectory: site, siteName: "my-site", workers: [activitypub]
        )

        guard case .workerNameConflict(let name, _) = result else {
            Issue.record("expected .workerNameConflict, got \(result)")
            return
        }
        #expect(name == "my-site")
        #expect(executor.calls.isEmpty, "must not touch build/preflight/wrangler for a name that isn't confirmed ours")
        #expect(!secretRunnerCalled, "must not push ActivityPub secrets into a Worker name that isn't confirmed ours")
    }

    @Test("fails before running wrangler when no token is available")
    func missingToken() async throws {
        let site = try temporaryDirectory()
        let executor = FakeExecutor()
        let command = SocialWorkerProvisionCommand(tokenSource: { nil }, executor: executor)

        let result = await command.provision(siteID: "site-1", siteDirectory: site, siteName: "my-site", workers: [])

        guard case .failed(let reason, nil, let resources) = result else {
            Issue.record("expected token failure, got \(result)")
            return
        }
        #expect(reason.contains("no CLOUDFLARE_API_TOKEN"))
        #expect(resources == .init())
        #expect(executor.calls.isEmpty)
    }

    @Test("reuses known resource ids and does not recreate Cloudflare backing stores")
    func reusesPersistedResources() async throws {
        let site = try temporaryDirectory()
        let executor = successExecutor()
            .set(.wranglerSubcommand(args: ["d1", "migrations", "apply", "AUTH_DB", "--remote"]), exitCode: 0, output: "Migrations applied")
        let command = SocialWorkerProvisionCommand(tokenSource: { "token" }, executor: executor)

        let result = await command.provision(
            siteID: "site-1",
            siteDirectory: site,
            siteName: "my-site",
            workers: v3Workers,
            // Every resource v3Workers could need is already known (as it would be from
            // `SiteSettings.provisionedWorkerResources`, #1015/#1821) — including the webmention
            // and websub queues, so the paid-plan confirmation gate never triggers.
            knownResources: .init(
                d1DatabaseID: "d1-existing",
                kvNamespaceID: "kv-existing",
                r2BucketName: "my-site-media",
                queueName: "my-site-webmention",
                websubQueueName: "my-site-websub"
            )
        )

        guard case .succeeded(_, let resources, _) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(resources.d1DatabaseID == "d1-existing")
        #expect(resources.kvNamespaceID == "kv-existing")
        #expect(resources.r2BucketName == "my-site-media")
        #expect(executor.wranglerSubcommandArguments == [
            ["d1", "migrations", "apply", "AUTH_DB", "--remote"],
        ])
    }

    @Test("persists partial D1 resources and reports them when KV creation fails")
    func partialFailureReportsResources() async throws {
        let site = try temporaryDirectory()
        let executor = successExecutor()
            .set(.wranglerSubcommand(args: ["d1", "create", "my-site-social"]), exitCode: 0, output: #"{"uuid":"d1-id"}"#)
            .set(.wranglerSubcommand(args: ["kv", "namespace", "create", "my-site-social"]), exitCode: 1, output: "KV failed")
        let command = SocialWorkerProvisionCommand(tokenSource: { "token" }, executor: executor)

        let result = await command.provision(siteID: "site-1", siteDirectory: site, siteName: "my-site", workers: v2Workers)

        guard case .failed(let reason, let exitCode, let resources) = result else {
            Issue.record("expected failure, got \(result)")
            return
        }
        #expect(reason == "KV failed")
        #expect(exitCode == 1)
        #expect(resources.d1DatabaseID == "d1-id")
        #expect(resources.kvNamespaceID == nil)
        #expect(!executor.ran(.wrangler))

        let toml = try String(contentsOf: site.appendingPathComponent("wrangler.toml"), encoding: .utf8)
        #expect(toml.contains("database_id = \"d1-id\""))
    }

    @Test("keeps provisioned resources when DeployCommand fails after config is written")
    func deployFailureReportsResources() async throws {
        let site = try temporaryDirectory()
        let executor = FakeExecutor()
            .set(.wranglerSubcommand(args: ["d1", "create", "my-site-social"]), exitCode: 0, output: #"{"uuid":"d1-id"}"#)
            .set(.wranglerSubcommand(args: ["kv", "namespace", "create", "my-site-social"]), exitCode: 0, output: #"{"id":"kv-id"}"#)
            .set(.wranglerSubcommand(args: ["queues", "create", "my-site-webmention"]), exitCode: 0, output: #"{"result":{"queue_name":"my-site-webmention"}}"#)
            .set(.wranglerSubcommand(args: ["d1", "migrations", "apply", "AUTH_DB", "--remote"]), exitCode: 0, output: "Migrations applied")
            .set(.build, exitCode: 0, output: "")
            .set(.preflight, exitCode: 0, output: scanJSON(ok: true))
            .set(.wrangler, exitCode: nil, output: "pre-deploy scan could not run")
        let command = SocialWorkerProvisionCommand(tokenSource: { "token" }, executor: executor)

        let result = await command.provision(
            siteID: "site-1", siteDirectory: site, siteName: "my-site", workers: v2Workers,
            acknowledgesPaidPlan: true
        )

        guard case .failed(let reason, nil, let resources) = result else {
            Issue.record("expected deploy failure, got \(result)")
            return
        }
        #expect(reason == "pre-deploy scan could not run")
        #expect(resources.d1DatabaseID == "d1-id")
        #expect(resources.kvNamespaceID == "kv-id")

        let toml = try String(contentsOf: site.appendingPathComponent("wrangler.toml"), encoding: .utf8)
        #expect(toml.contains("database_id = \"d1-id\""))
        #expect(toml.contains("id = \"kv-id\""))
    }

    @Test("a worker-name conflict from authorize is propagated, not collapsed to failed")
    func workerNameConflictPropagates() async throws {
        // `.workerNameConflict` originates solely from `CloudflareDeployTarget.authorize`'s
        // pre-build check (#1075/#740) — it can no longer surface mid-deploy the way the old fake
        // `deployer` closure could return it arbitrarily, since a genuine conflict is now always
        // caught before any D1/KV/queue resource is created (see
        // `foreignConflictCaughtBeforeAnyProvisioning` above). So the resources riding along on
        // this propagated result are always exactly the (empty) `knownResources` this call
        // started with, not partial provisioning progress.
        let site = try temporaryDirectory()
        try "CF_PROJECT_NAME=taken-name\n".write(to: site.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)
        let executor = successExecutor()
        let command = SocialWorkerProvisionCommand(
            tokenSource: { "token" },
            executor: executor,
            workerScriptNamesSource: { _ in ["taken-name"] }
        )

        let result = await command.provision(
            siteID: "site-1", siteDirectory: site, siteName: "my-site", workers: v2Workers,
            acknowledgesPaidPlan: true
        )

        guard case .workerNameConflict(let name, let resources) = result else {
            Issue.record("expected .workerNameConflict, got \(result)"); return
        }
        #expect(name == "taken-name")
        #expect(resources == .init())
        #expect(executor.calls.isEmpty, "must not touch build/preflight/wrangler once authorize() finds a conflict")
    }

    @Test("stops before deploy when the IndieAuth schema migration fails")
    func migrationFailureStopsDeploy() async throws {
        let site = try temporaryDirectory()
        let executor = successExecutor()
            .set(.wranglerSubcommand(args: ["d1", "create", "my-site-social"]), exitCode: 0, output: #"{"uuid":"d1-id"}"#)
            .set(.wranglerSubcommand(args: ["kv", "namespace", "create", "my-site-social"]), exitCode: 0, output: #"{"id":"kv-id"}"#)
            .set(.wranglerSubcommand(args: ["queues", "create", "my-site-webmention"]), exitCode: 0, output: #"{"result":{"queue_name":"my-site-webmention"}}"#)
            .set(.wranglerSubcommand(args: ["d1", "migrations", "apply", "AUTH_DB", "--remote"]), exitCode: 1, output: "Migration failed")
        let command = SocialWorkerProvisionCommand(tokenSource: { "token" }, executor: executor)

        let result = await command.provision(
            siteID: "site-1", siteDirectory: site, siteName: "my-site", workers: v2Workers,
            acknowledgesPaidPlan: true
        )

        guard case .failed(let reason, let exitCode, let resources) = result else {
            Issue.record("expected migration failure, got \(result)")
            return
        }
        #expect(reason == "Migration failed")
        #expect(exitCode == 1)
        #expect(resources.d1DatabaseID == "d1-id")
        #expect(resources.kvNamespaceID == "kv-id")
        #expect(!executor.ran(.wrangler))
    }

    @Test("extracts resource ids from common wrangler JSON shapes")
    func resourceIDExtraction() {
        #expect(SocialWorkerProvisionCommand.extractResourceID(from: #"{"result":{"uuid":"d1-id"}}"#) == "d1-id")
        #expect(SocialWorkerProvisionCommand.extractResourceID(from: #"{"id":"kv-id"}"#) == "kv-id")
        #expect(SocialWorkerProvisionCommand.extractResourceID(from: #"{"result":[{"database_id":"db-id"}]}"#) == "db-id")
        #expect(SocialWorkerProvisionCommand.extractResourceID(from: #"binding = "SOCIAL_KV"\nid = "text-id""#) == "text-id")
    }

    @Test("asDeployCommandResult maps succeeded, dropping the resources payload")
    func asDeployCommandResultMapsSucceeded() {
        let url = URL(string: "https://my-site.example.workers.dev")!
        let result = SocialWorkerProvisionCommand.Result.succeeded(
            url: url, resources: .init(d1DatabaseID: "d1-id"), duration: 3
        )
        #expect(result.asDeployCommandResult == .succeeded(url: url, duration: 3))
    }

    @Test("asDeployCommandResult maps blocked, dropping the resources payload")
    func asDeployCommandResultMapsBlocked() {
        let failure = PreDeployCheck.ScanFailure(
            category: .exposedToken, message: "API key committed", file: "src/index.md", remediation: "Remove it"
        )
        let result = SocialWorkerProvisionCommand.Result.blocked(
            failures: [failure], warnings: [], resources: .init(kvNamespaceID: "kv-id")
        )
        #expect(result.asDeployCommandResult == .blocked(failures: [failure], warnings: []))
    }

    @Test("asDeployCommandResult maps workerNameConflict, dropping the resources payload")
    func asDeployCommandResultMapsWorkerNameConflict() {
        let result = SocialWorkerProvisionCommand.Result.workerNameConflict(
            name: "taken-name", resources: .init(r2BucketName: "media")
        )
        #expect(result.asDeployCommandResult == .workerNameConflict(name: "taken-name"))
    }

    @Test("asDeployCommandResult passes webmentionPaidPlanConfirmationNeeded through directly, dropping the resources payload")
    func asDeployCommandResultMapsWebmentionPaidPlanConfirmationNeeded() {
        let result = SocialWorkerProvisionCommand.Result.webmentionPaidPlanConfirmationNeeded(
            resources: .init(kvNamespaceID: "kv-id")
        )
        #expect(result.asDeployCommandResult == .webmentionPaidPlanConfirmationNeeded)
    }

    @Test("asDeployCommandResult maps failed, dropping the resources payload")
    func asDeployCommandResultMapsFailed() {
        let result = SocialWorkerProvisionCommand.Result.failed(
            reason: "KV failed", exitCode: 1, resources: .init(d1DatabaseID: "d1-id")
        )
        #expect(result.asDeployCommandResult == .failed(reason: "KV failed", exitCode: 1))
    }

    @Test("webmention worker without paid-plan acknowledgment returns webmentionPaidPlanConfirmationNeeded, no wrangler call")
    func webmentionWithoutAcknowledgmentBlocksBeforeAnyCall() async throws {
        let site = try temporaryDirectory()
        let executor = successExecutor(url: "https://example.com")
        let command = SocialWorkerProvisionCommand(tokenSource: { "tok" }, executor: executor)
        let webmention = WorkerDescriptor(
            id: "webmention", displayName: "Webmentions", description: "test", group: "social",
            binding: .settingsActivated, resources: .init(needsD1: false, needsKV: false, needsR2: false))

        let result = await command.provision(
            siteID: "site-1", siteDirectory: site, siteName: "my-site",
            workers: [webmention], acknowledgesPaidPlan: false)

        guard case .webmentionPaidPlanConfirmationNeeded = result else {
            Issue.record("expected .webmentionPaidPlanConfirmationNeeded, got \(result)")
            return
        }
        #expect(executor.wranglerSubcommandArguments.isEmpty, "must not call wrangler before the user acknowledges the paid-plan requirement")
        #expect(!executor.ran(.wrangler))
    }

    @Test("webmention worker with acknowledgment creates the queue")
    func webmentionWithAcknowledgmentCreatesQueue() async throws {
        let site = try temporaryDirectory()
        let executor = successExecutor(url: "https://example.com")
            .set(.wranglerSubcommand(args: ["queues", "create", "my-site-webmention"]), exitCode: 0, output: #"{"result":{"queue_name":"my-site-webmention"}}"#)
        let command = SocialWorkerProvisionCommand(tokenSource: { "tok" }, executor: executor)
        let webmention = WorkerDescriptor(
            id: "webmention", displayName: "Webmentions", description: "test", group: "social",
            binding: .settingsActivated, resources: .init(needsD1: false, needsKV: false, needsR2: false))

        let result = await command.provision(
            siteID: "site-1", siteDirectory: site, siteName: "my-site",
            workers: [webmention], acknowledgesPaidPlan: true)

        guard case .succeeded(_, let resources, _) = result else {
            Issue.record("expected .succeeded, got \(result)")
            return
        }
        #expect(resources.queueName == "my-site-webmention")
        #expect(executor.wranglerSubcommandArguments.contains(["queues", "create", "my-site-webmention"]))
    }

    @Test("an already-provisioned queue is not re-created")
    func alreadyProvisionedQueueSkipsCreation() async throws {
        let site = try temporaryDirectory()
        let executor = successExecutor(url: "https://example.com")
        let command = SocialWorkerProvisionCommand(tokenSource: { "tok" }, executor: executor)
        let webmention = WorkerDescriptor(
            id: "webmention", displayName: "Webmentions", description: "test", group: "social",
            binding: .settingsActivated, resources: .init(needsD1: false, needsKV: false, needsR2: false))

        let result = await command.provision(
            siteID: "site-1", siteDirectory: site, siteName: "my-site",
            workers: [webmention], knownResources: .init(queueName: "my-site-webmention"),
            acknowledgesPaidPlan: true)

        guard case .succeeded = result else {
            Issue.record("expected .succeeded, got \(result)")
            return
        }
        #expect(!executor.wranglerSubcommandArguments.contains(where: { $0.first == "queues" }))
    }

    @Test("webmention receive writes WEBMENTION_RECEIVE_ENABLED into .site-config")
    func webmentionWritesReceiveEnabledFlag() async throws {
        let siteDirectory = try temporaryDirectory()
        let executor = successExecutor(url: "https://example.com")
            .set(.wranglerSubcommand(args: ["queues", "create", "my-site-webmention"]), exitCode: 0, output: #"{"result":{"queue_name":"my-site-webmention"}}"#)
        let command = SocialWorkerProvisionCommand(tokenSource: { "tok" }, executor: executor)
        let webmention = WorkerDescriptor(
            id: "webmention", displayName: "Webmentions", description: "test", group: "social",
            binding: .settingsActivated, resources: .init(needsD1: false, needsKV: false, needsR2: false))

        _ = await command.provision(
            siteID: "site-1", siteDirectory: siteDirectory, siteName: "my-site",
            workers: [webmention], acknowledgesPaidPlan: true)

        let config = try String(contentsOf: siteDirectory.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(SiteConfigFile.value(forKey: "WEBMENTION_RECEIVE_ENABLED", in: config) == "true")
    }

    @Test("deactivating webmention reconciles WEBMENTION_RECEIVE_ENABLED back to false")
    func webmentionDeactivationReconcilesFlagToFalse() async throws {
        let siteDirectory = try temporaryDirectory()
        let executor = successExecutor(url: "https://example.com")
            .set(.wranglerSubcommand(args: ["queues", "create", "my-site-webmention"]), exitCode: 0, output: #"{"result":{"queue_name":"my-site-webmention"}}"#)
        let command = SocialWorkerProvisionCommand(tokenSource: { "tok" }, executor: executor)
        let webmention = WorkerDescriptor(
            id: "webmention", displayName: "Webmentions", description: "test", group: "social",
            binding: .settingsActivated, resources: .init(needsD1: false, needsKV: false, needsR2: false))

        _ = await command.provision(
            siteID: "site-1", siteDirectory: siteDirectory, siteName: "my-site",
            workers: [webmention], acknowledgesPaidPlan: true)

        let enabledConfig = try String(contentsOf: siteDirectory.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(SiteConfigFile.value(forKey: "WEBMENTION_RECEIVE_ENABLED", in: enabledConfig) == "true")

        _ = await command.provision(
            siteID: "site-1", siteDirectory: siteDirectory, siteName: "my-site",
            workers: [], acknowledgesPaidPlan: true)

        let disabledConfig = try String(contentsOf: siteDirectory.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(SiteConfigFile.value(forKey: "WEBMENTION_RECEIVE_ENABLED", in: disabledConfig) == "false")
    }

    @Test("cancelling the paid-plan gate never lets WEBMENTION_RECEIVE_ENABLED reach true")
    func webmentionPaidPlanGateCancelKeepsFlagFalse() async throws {
        let siteDirectory = try temporaryDirectory()
        let executor = successExecutor(url: "https://example.com")
            .set(.wranglerSubcommand(args: ["d1", "create", "my-site-social"]), exitCode: 0, output: #"{"result":{"uuid":"d1-id"}}"#)
        let command = SocialWorkerProvisionCommand(tokenSource: { "tok" }, executor: executor)
        // needsD1: true so the D1 block's persistConfig call runs (and reconciles the flag to
        // "false") before the code reaches the paid-plan gate below it — mirrors production,
        // where webmention's real WorkerComposition resources need D1 for the inbox table.
        let webmention = WorkerDescriptor(
            id: "webmention", displayName: "Webmentions", description: "test", group: "social",
            binding: .settingsActivated, resources: .init(needsD1: true, needsKV: false, needsR2: false))

        let result = await command.provision(
            siteID: "site-1", siteDirectory: siteDirectory, siteName: "my-site",
            workers: [webmention], acknowledgesPaidPlan: false)

        guard case .webmentionPaidPlanConfirmationNeeded = result else {
            Issue.record("expected .webmentionPaidPlanConfirmationNeeded, got \(result)")
            return
        }
        #expect(!executor.wranglerSubcommandArguments.contains(where: { $0.first == "queues" }), "must not create the Queue before the paid-plan gate is acknowledged")
        let config = try String(contentsOf: siteDirectory.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(SiteConfigFile.value(forKey: "WEBMENTION_RECEIVE_ENABLED", in: config) == "false")
    }

    @Test("Micropub writes MICROPUB_ENABLED into .site-config, gating BaseLayout.astro's rel=micropub discovery tag")
    func micropubWritesEnabledFlag() async throws {
        let siteDirectory = try temporaryDirectory()
        let executor = successExecutor(url: "https://example.com")
            .set(.wranglerSubcommand(args: ["d1", "create", "my-site-social"]), exitCode: 0, output: #"{"result":{"uuid":"d1-id"}}"#)
            .set(.wranglerSubcommand(args: ["r2", "bucket", "create", "my-site-media"]), exitCode: 0, output: "Created bucket my-site-media")
            .set(.wranglerSubcommand(args: ["d1", "migrations", "apply", "AUTH_DB", "--remote"]), exitCode: 0, output: "Migrations applied")
        let command = SocialWorkerProvisionCommand(tokenSource: { "tok" }, executor: executor)
        let indieauth = worker(WorkerComposition.indieauthWorkerID, d1: true, kv: false, r2: false)
        let micropub = worker(WorkerComposition.micropubWorkerID, d1: true, kv: false, r2: true)

        _ = await command.provision(
            siteID: "site-1", siteDirectory: siteDirectory, siteName: "my-site",
            workers: [indieauth, micropub], acknowledgesPaidPlan: true)

        let config = try String(contentsOf: siteDirectory.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(SiteConfigFile.value(forKey: "MICROPUB_ENABLED", in: config) == "true")
    }

    @Test("deactivating Micropub reconciles MICROPUB_ENABLED back to false")
    func micropubDeactivationReconcilesFlagToFalse() async throws {
        let siteDirectory = try temporaryDirectory()
        let executor = successExecutor(url: "https://example.com")
            .set(.wranglerSubcommand(args: ["d1", "create", "my-site-social"]), exitCode: 0, output: #"{"result":{"uuid":"d1-id"}}"#)
            .set(.wranglerSubcommand(args: ["r2", "bucket", "create", "my-site-media"]), exitCode: 0, output: "Created bucket my-site-media")
            .set(.wranglerSubcommand(args: ["d1", "migrations", "apply", "AUTH_DB", "--remote"]), exitCode: 0, output: "Migrations applied")
        let command = SocialWorkerProvisionCommand(tokenSource: { "tok" }, executor: executor)
        let indieauth = worker(WorkerComposition.indieauthWorkerID, d1: true, kv: false, r2: false)
        let micropub = worker(WorkerComposition.micropubWorkerID, d1: true, kv: false, r2: true)

        _ = await command.provision(
            siteID: "site-1", siteDirectory: siteDirectory, siteName: "my-site",
            workers: [indieauth, micropub], acknowledgesPaidPlan: true)

        let enabledConfig = try String(contentsOf: siteDirectory.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(SiteConfigFile.value(forKey: "MICROPUB_ENABLED", in: enabledConfig) == "true")

        _ = await command.provision(
            siteID: "site-1", siteDirectory: siteDirectory, siteName: "my-site",
            workers: [indieauth], acknowledgesPaidPlan: true)

        let disabledConfig = try String(contentsOf: siteDirectory.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(SiteConfigFile.value(forKey: "MICROPUB_ENABLED", in: disabledConfig) == "false")
    }

    @Test("websub worker without paid-plan acknowledgment returns the confirmation-needed gate, no wrangler call")
    func websubWithoutAcknowledgmentBlocksBeforeAnyCall() async throws {
        let site = try temporaryDirectory()
        let executor = successExecutor(url: "https://example.com")
        let command = SocialWorkerProvisionCommand(tokenSource: { "tok" }, executor: executor)
        let websub = WorkerDescriptor(
            id: "websub", displayName: "WebSub", description: "test", group: "social",
            binding: .settingsActivated, resources: .init(needsD1: false, needsKV: false, needsR2: false))

        let result = await command.provision(
            siteID: "site-1", siteDirectory: site, siteName: "my-site",
            workers: [websub], acknowledgesPaidPlan: false)

        guard case .webmentionPaidPlanConfirmationNeeded = result else {
            Issue.record("expected .webmentionPaidPlanConfirmationNeeded, got \(result)")
            return
        }
        #expect(executor.wranglerSubcommandArguments.isEmpty, "must not call wrangler before the user acknowledges the paid-plan requirement")
    }

    @Test("websub worker with acknowledgment creates its own queue")
    func websubWithAcknowledgmentCreatesQueue() async throws {
        let site = try temporaryDirectory()
        let executor = successExecutor(url: "https://example.com")
            .set(.wranglerSubcommand(args: ["queues", "create", "my-site-websub"]), exitCode: 0, output: #"{"result":{"queue_name":"my-site-websub"}}"#)
        let command = SocialWorkerProvisionCommand(tokenSource: { "tok" }, executor: executor)
        let websub = WorkerDescriptor(
            id: "websub", displayName: "WebSub", description: "test", group: "social",
            binding: .settingsActivated, resources: .init(needsD1: false, needsKV: false, needsR2: false))

        let result = await command.provision(
            siteID: "site-1", siteDirectory: site, siteName: "my-site",
            workers: [websub], acknowledgesPaidPlan: true)

        guard case .succeeded(_, let resources, _) = result else {
            Issue.record("expected .succeeded, got \(result)")
            return
        }
        #expect(resources.websubQueueName == "my-site-websub")
        #expect(resources.queueName == nil, "no webmention worker, so no webmention queue")
        #expect(executor.wranglerSubcommandArguments.contains(["queues", "create", "my-site-websub"]))
        #expect(!executor.wranglerSubcommandArguments.contains(["queues", "create", "my-site-webmention"]))
    }

    @Test("an already-provisioned websub queue is not re-created")
    func alreadyProvisionedWebsubQueueSkipsCreation() async throws {
        let site = try temporaryDirectory()
        let executor = successExecutor(url: "https://example.com")
        let command = SocialWorkerProvisionCommand(tokenSource: { "tok" }, executor: executor)
        let websub = WorkerDescriptor(
            id: "websub", displayName: "WebSub", description: "test", group: "social",
            binding: .settingsActivated, resources: .init(needsD1: false, needsKV: false, needsR2: false))

        let result = await command.provision(
            siteID: "site-1", siteDirectory: site, siteName: "my-site",
            workers: [websub], knownResources: .init(websubQueueName: "my-site-websub"),
            acknowledgesPaidPlan: true)

        guard case .succeeded = result else {
            Issue.record("expected .succeeded, got \(result)")
            return
        }
        #expect(!executor.wranglerSubcommandArguments.contains(where: { $0.first == "queues" }))
    }

    @Test("webmention and websub active together create both queues under one acknowledgment")
    func webmentionAndWebsubCreateBothQueues() async throws {
        let site = try temporaryDirectory()
        let executor = successExecutor(url: "https://example.com")
            .set(.wranglerSubcommand(args: ["queues", "create", "my-site-webmention"]), exitCode: 0, output: #"{"result":{"queue_name":"my-site-webmention"}}"#)
            .set(.wranglerSubcommand(args: ["queues", "create", "my-site-websub"]), exitCode: 0, output: #"{"result":{"queue_name":"my-site-websub"}}"#)
        let command = SocialWorkerProvisionCommand(tokenSource: { "tok" }, executor: executor)
        let webmention = WorkerDescriptor(
            id: "webmention", displayName: "Webmentions", description: "test", group: "social",
            binding: .settingsActivated, resources: .init(needsD1: false, needsKV: false, needsR2: false))
        let websub = WorkerDescriptor(
            id: "websub", displayName: "WebSub", description: "test", group: "social",
            binding: .settingsActivated, resources: .init(needsD1: false, needsKV: false, needsR2: false))

        let result = await command.provision(
            siteID: "site-1", siteDirectory: site, siteName: "my-site",
            workers: [webmention, websub], acknowledgesPaidPlan: true)

        guard case .succeeded(_, let resources, _) = result else {
            Issue.record("expected .succeeded, got \(result)")
            return
        }
        #expect(resources.queueName == "my-site-webmention")
        #expect(resources.websubQueueName == "my-site-websub")
    }

    @Test("websub writes WEBSUB_ENABLED into .site-config, and deactivation reconciles it to false")
    func websubWritesEnabledFlagAndReconciles() async throws {
        let siteDirectory = try temporaryDirectory()
        let executor = successExecutor(url: "https://example.com")
            .set(.wranglerSubcommand(args: ["queues", "create", "my-site-websub"]), exitCode: 0, output: #"{"result":{"queue_name":"my-site-websub"}}"#)
        let command = SocialWorkerProvisionCommand(tokenSource: { "tok" }, executor: executor)
        let websub = WorkerDescriptor(
            id: "websub", displayName: "WebSub", description: "test", group: "social",
            binding: .settingsActivated, resources: .init(needsD1: false, needsKV: false, needsR2: false))

        _ = await command.provision(
            siteID: "site-1", siteDirectory: siteDirectory, siteName: "my-site",
            workers: [websub], acknowledgesPaidPlan: true)

        let enabledConfig = try String(contentsOf: siteDirectory.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(SiteConfigFile.value(forKey: "WEBSUB_ENABLED", in: enabledConfig) == "true")

        _ = await command.provision(
            siteID: "site-1", siteDirectory: siteDirectory, siteName: "my-site",
            workers: [], acknowledgesPaidPlan: true)

        let disabledConfig = try String(contentsOf: siteDirectory.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(SiteConfigFile.value(forKey: "WEBSUB_ENABLED", in: disabledConfig) == "false")
    }

    @Test("microsub worker without paid-plan acknowledgment returns the confirmation-needed gate, no wrangler call")
    func microsubWithoutAcknowledgmentBlocksBeforeAnyCall() async throws {
        let site = try temporaryDirectory()
        let executor = successExecutor(url: "https://example.com")
        let command = SocialWorkerProvisionCommand(tokenSource: { "tok" }, executor: executor)
        let microsub = WorkerDescriptor(
            id: "microsub", displayName: "Microsub", description: "test", group: "publishing",
            binding: .settingsActivated, resources: .init(needsD1: false, needsKV: false, needsR2: false))

        let result = await command.provision(
            siteID: "site-1", siteDirectory: site, siteName: "my-site",
            workers: [microsub], acknowledgesPaidPlan: false)

        guard case .webmentionPaidPlanConfirmationNeeded = result else {
            Issue.record("expected .webmentionPaidPlanConfirmationNeeded, got \(result)")
            return
        }
        #expect(executor.wranglerSubcommandArguments.isEmpty, "must not call wrangler before the user acknowledges the paid-plan requirement")
    }

    @Test("microsub worker with acknowledgment creates its own queue")
    func microsubWithAcknowledgmentCreatesQueue() async throws {
        let site = try temporaryDirectory()
        let executor = successExecutor(url: "https://example.com")
            .set(.wranglerSubcommand(args: ["queues", "create", "my-site-microsub"]), exitCode: 0, output: #"{"result":{"queue_name":"my-site-microsub"}}"#)
        let command = SocialWorkerProvisionCommand(tokenSource: { "tok" }, executor: executor)
        let microsub = WorkerDescriptor(
            id: "microsub", displayName: "Microsub", description: "test", group: "publishing",
            binding: .settingsActivated, resources: .init(needsD1: false, needsKV: false, needsR2: false))

        let result = await command.provision(
            siteID: "site-1", siteDirectory: site, siteName: "my-site",
            workers: [microsub], acknowledgesPaidPlan: true)

        guard case .succeeded(_, let resources, _) = result else {
            Issue.record("expected .succeeded, got \(result)")
            return
        }
        #expect(resources.microsubQueueName == "my-site-microsub")
        #expect(executor.wranglerSubcommandArguments.contains(["queues", "create", "my-site-microsub"]))
    }

    @Test("an already-provisioned microsub queue is not re-created")
    func alreadyProvisionedMicrosubQueueSkipsCreation() async throws {
        let site = try temporaryDirectory()
        let executor = successExecutor(url: "https://example.com")
        let command = SocialWorkerProvisionCommand(tokenSource: { "tok" }, executor: executor)
        let microsub = WorkerDescriptor(
            id: "microsub", displayName: "Microsub", description: "test", group: "publishing",
            binding: .settingsActivated, resources: .init(needsD1: false, needsKV: false, needsR2: false))

        let result = await command.provision(
            siteID: "site-1", siteDirectory: site, siteName: "my-site",
            workers: [microsub], knownResources: .init(microsubQueueName: "my-site-microsub"),
            acknowledgesPaidPlan: true)

        guard case .succeeded = result else {
            Issue.record("expected .succeeded, got \(result)")
            return
        }
        #expect(!executor.wranglerSubcommandArguments.contains(where: { $0.first == "queues" }))
    }

    @Test("provisions solid-pod's own BLOBS bucket, distinct from micropub's MEDIA bucket")
    func provisionsSolidPodBlobsBucket() async throws {
        let site = try temporaryDirectory()
        let executor = successExecutor()
            .set(.wranglerSubcommand(args: ["d1", "create", "my-site-social"]), exitCode: 0, output: #"{"result":{"uuid":"d1-id"}}"#)
            .set(.wranglerSubcommand(args: ["r2", "bucket", "create", "my-site-media"]), exitCode: 0, output: "Created bucket my-site-media")
            .set(.wranglerSubcommand(args: ["r2", "bucket", "create", "my-site-pod-blobs"]), exitCode: 0, output: "Created bucket my-site-pod-blobs")
            .set(.wranglerSubcommand(args: ["queues", "create", "my-site-webmention"]), exitCode: 0, output: #"{"result":{"queue_name":"my-site-webmention"}}"#)
            .set(.wranglerSubcommand(args: ["d1", "migrations", "apply", "AUTH_DB", "--remote"]), exitCode: 0, output: "Migrations applied")
        let command = SocialWorkerProvisionCommand(tokenSource: { "token" }, executor: executor)
        let micropubWorker = worker(WorkerComposition.micropubWorkerID, d1: true, kv: false, r2: true)
        let indieauthWorker = worker(WorkerComposition.indieauthWorkerID, d1: true, kv: false, r2: false)
        let webmentionWorker = worker(WorkerComposition.webmentionWorkerID, d1: true, kv: false, r2: false)

        let result = await command.provision(
            siteID: "site-1", siteDirectory: site, siteName: "my-site",
            workers: [indieauthWorker, webmentionWorker, micropubWorker, solidPodWorker],
            acknowledgesPaidPlan: true
        )

        guard case .succeeded(_, let resources, _) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(resources.r2BucketName == "my-site-media")
        #expect(resources.podBlobsR2BucketName == "my-site-pod-blobs")
        #expect(executor.wranglerSubcommandArguments.contains(["r2", "bucket", "create", "my-site-media"]))
        #expect(executor.wranglerSubcommandArguments.contains(["r2", "bucket", "create", "my-site-pod-blobs"]))

        let toml = try String(contentsOf: site.appendingPathComponent("wrangler.toml"), encoding: .utf8)
        #expect(toml.contains("binding = \"MEDIA\""))
        #expect(toml.contains("binding = \"BLOBS\""))
    }

    @Test("solid-oidc and webdav push their secrets via the injected key/pepper sources")
    func pushesSolidOidcAndWebdavSecrets() async throws {
        let site = try temporaryDirectory()
        let executor = successExecutor()
            .set(.wranglerSubcommand(args: ["d1", "create", "my-site-social"]), exitCode: 0, output: #"{"result":{"uuid":"d1-id"}}"#)
            .set(.wranglerSubcommand(args: ["r2", "bucket", "create", "my-site-pod-blobs"]), exitCode: 0, output: "Created bucket my-site-pod-blobs")
            .set(.wranglerSubcommand(args: ["d1", "migrations", "apply", "AUTH_DB", "--remote"]), exitCode: 0, output: "Migrations applied")
        var pushedSecrets: [(name: String, value: String)] = []
        let secretRunnerLock = NSLock()
        let command = SocialWorkerProvisionCommand(
            tokenSource: { "token" },
            executor: executor,
            solidOidcSigningKeySource: { _ in #"{"kty":"EC","crv":"P-256","x":"X","y":"Y","d":"D"}"# },
            webdavPepperSource: { _ in "PEPPER-VALUE" },
            secretRunner: { _, name, value, _, _ in
                secretRunnerLock.lock()
                pushedSecrets.append((name, value))
                secretRunnerLock.unlock()
                return .init(stdout: "Success!", stderr: "", exitCode: 0)
            }
        )
        let indieauthWorker = worker(WorkerComposition.indieauthWorkerID, d1: true, kv: false, r2: false)

        let result = await command.provision(
            siteID: "site-1", siteDirectory: site, siteName: "my-site",
            workers: [indieauthWorker, solidOidcWorker, solidPodWorker, webdavWorker]
        )

        guard case .succeeded = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(pushedSecrets.contains { $0.name == "OIDC_SIGNING_KEY" && $0.value.contains("P-256") })
        #expect(pushedSecrets.contains { $0.name == "WEBDAV_PEPPER" && $0.value == "PEPPER-VALUE" })
    }

    @Test("no solid-oidc/webdav worker means their sources and secret pushes never run")
    func noSolidOidcOrWebdavMeansNoSecretPush() async throws {
        let site = try temporaryDirectory()
        let executor = successExecutor()
        var solidOidcSourceCalled = false
        var webdavSourceCalled = false
        let command = SocialWorkerProvisionCommand(
            tokenSource: { "token" },
            executor: executor,
            solidOidcSigningKeySource: { _ in
                solidOidcSourceCalled = true
                return "unused"
            },
            webdavPepperSource: { _ in
                webdavSourceCalled = true
                return "unused"
            }
        )

        _ = await command.provision(siteID: "site-1", siteDirectory: site, siteName: "my-site", workers: [])

        #expect(!solidOidcSourceCalled)
        #expect(!webdavSourceCalled)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SocialWorkerProvisionCommandTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// A mutable account-wide Worker-script-name list, so a test can simulate `wrangler secret put`'s
/// side effect of auto-vivifying a script under the target name partway through a `provision()`
/// call (#1075).
private actor ToggleableWorkerNames {
    private var names: [String] = []
    func set(_ new: [String]) { names = new }
    var current: [String] { names }
}
