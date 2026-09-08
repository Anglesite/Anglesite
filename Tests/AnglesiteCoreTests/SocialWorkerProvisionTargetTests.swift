import Foundation
import Testing
@testable import AnglesiteCore

/// Shared no-op stub seams for tests that don't exercise the ActivityPub/Solid-OIDC/WebDAV
/// secret-push paths — mirrors the fixtures `SocialWorkerProvisionCommandTests.swift` uses for the
/// same closures.
private let stubKeyPairSource: SocialWorkerProvisionCommand.KeyPairSource = { _ in
    .init(privateKeyPem: "", publicKeyPem: "", publishToken: "")
}
private let stubSolidOidcSigningKeySource: SocialWorkerProvisionCommand.SolidOidcSigningKeySource = { _ in "" }
private let stubWebdavPepperSource: SocialWorkerProvisionCommand.WebdavPepperSource = { _ in "" }
private let stubSecretRunner: SocialWorkerProvisionCommand.SecretRunner = { _, _, _, _, _ in
    .init(stdout: "", stderr: "", exitCode: 0)
}
private let stubAccountIDSource: SocialWorkerProvisionCommand.AccountIDSource = { _ in nil }

@Suite("SocialWorkerProvisionTarget.authorize")
struct SocialWorkerProvisionTargetAuthorizeTests {
    @Test("delegates to CloudflareDeployTarget's full authorize, including domain-drift")
    func delegatesFullAuthorize() async throws {
        let tmpDir = try temporaryDirectory()
        let inner = CloudflareDeployTarget(
            tokenSource: { "tok" },
            domainConfigDriftSource: { _, _, _ in
                [DomainConfigAudit.Finding(category: .dns, title: "dns", detail: "drift", remediation: .informational)]
            })
        try DomainConfigStore(sourceDirectory: tmpDir).save(DomainConfig(domain: .init(hostname: "example.com")))
        let target = SocialWorkerProvisionTarget(
            cloudflareTarget: inner, siteName: "site", workers: [], knownResources: .init(),
            keyPairSource: stubKeyPairSource, solidOidcSigningKeySource: stubSolidOidcSigningKeySource,
            webdavPepperSource: stubWebdavPepperSource, secretRunner: stubSecretRunner,
            accountIDSource: stubAccountIDSource)
        let result = await target.authorize(siteDirectory: tmpDir)
        guard case .blocked(.domainConfigDrift) = result else {
            Issue.record("expected .blocked(.domainConfigDrift), got \(result)")
            return
        }
    }

    @Test("persists CF_WORKER_PROVISIONED on a successful authorize")
    func persistsWorkerProvisionedOnSuccess() async throws {
        let tmpDir = try temporaryDirectory()
        let inner = CloudflareDeployTarget(tokenSource: { "tok" })
        let target = SocialWorkerProvisionTarget(
            cloudflareTarget: inner, siteName: "site", workers: [], knownResources: .init(),
            keyPairSource: stubKeyPairSource, solidOidcSigningKeySource: stubSolidOidcSigningKeySource,
            webdavPepperSource: stubWebdavPepperSource, secretRunner: stubSecretRunner,
            accountIDSource: stubAccountIDSource)
        let result = await target.authorize(siteDirectory: tmpDir)
        guard case .ready = result else {
            Issue.record("expected .ready, got \(result)")
            return
        }
        let config = try String(contentsOf: tmpDir.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(SiteConfigFile.value(forKey: "CF_WORKER_PROVISIONED", in: config) == "true")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SocialWorkerProvisionTargetTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@Suite("SocialWorkerProvisionTarget.publish")
struct SocialWorkerProvisionTargetPublishTests {
    /// A minimal `DeployExecutor` fake keyed by step (mirrors `DeployCommandTests.swift`'s
    /// `FakeExecutor`, kept local here per Task 13's brief — see task-13-brief.md Step 3 — so this
    /// task's diff stays confined to `SocialWorkerProvisionTarget.swift` and its own test file).
    private final class FakeExecutor: DeployExecutor, @unchecked Sendable {
        private let lock = NSLock()
        private var byStep: [String: DeployStepResult] = [:]

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

        private var seenSteps: [String] = []

        func run(step: DeployStep, siteDirectory: URL, environment: [String: String], source: String) async -> DeployStepResult {
            lock.lock(); defer { lock.unlock() }
            seenSteps.append(key(step))
            return byStep[key(step)] ?? DeployStepResult(exitCode: 0, output: "")
        }

        /// Whether `step` was actually run through `run(step:...)` — as opposed to merely stubbed
        /// via `set(_:exitCode:output:)`, which a step that's never reached (e.g. a gate that
        /// returns early) would still leave unexercised.
        func ran(_ step: DeployStep) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return seenSteps.contains(key(step))
        }
    }

    private func scanJSON(ok: Bool) -> String {
        ok ? #"{"version":1,"ok":true,"failures":[],"warnings":[]}"#
           : #"{"version":1,"ok":false,"failures":[{"category":"pii-email","message":"email","file":"dist/index.html","remediation":"wrap it"}],"warnings":[]}"#
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SocialWorkerProvisionTargetPublishTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func worker(_ id: String, d1: Bool, kv: Bool, r2: Bool) -> WorkerDescriptor {
        WorkerDescriptor(
            id: id, displayName: id, description: "test fixture", group: "test",
            binding: .settingsActivated, resources: .init(needsD1: d1, needsKV: kv, needsR2: r2)
        )
    }

    @Test("publish creates D1 before delegating to CloudflareDeployTarget for the final deploy")
    func publishCreatesD1ThenDeploys() async throws {
        let tmpDir = try temporaryDirectory()
        let executor = FakeExecutor()
            .set(.wranglerSubcommand(args: ["d1", "create", "site-social"]), exitCode: 0, output: #"{"database_id":"db-abc"}"#)
            .set(.build, exitCode: 0, output: "")
            .set(.preflight, exitCode: 0, output: scanJSON(ok: true))
            .set(.wrangler, exitCode: 0, output: "Published site (0.1 sec)\n  https://site.workers.dev")
        let inner = CloudflareDeployTarget(tokenSource: { "tok" })
        let indieauth = worker(WorkerComposition.indieauthWorkerID, d1: true, kv: false, r2: false)
        let target = SocialWorkerProvisionTarget(
            cloudflareTarget: inner, siteName: "site", workers: [indieauth],
            keyPairSource: stubKeyPairSource, solidOidcSigningKeySource: stubSolidOidcSigningKeySource,
            webdavPepperSource: stubWebdavPepperSource, secretRunner: stubSecretRunner,
            accountIDSource: stubAccountIDSource)
        let cmd = DeployCommand(target: target, executor: executor)
        let result = await cmd.deploy(siteID: "s", siteDirectory: tmpDir)
        guard case .succeeded(let url, _) = result else { Issue.record("expected .succeeded, got \(result)"); return }
        #expect(url.absoluteString == "https://site.workers.dev")
        let resources = await target.resources
        #expect(resources.d1DatabaseID == "db-abc")
    }

    @Test("domain-config-drift blocks before any resource is created")
    func domainDriftBlocksBeforeResourceCreation() async throws {
        let tmpDir = try temporaryDirectory()
        try DomainConfigStore(sourceDirectory: tmpDir).save(DomainConfig(domain: .init(hostname: "example.com")))
        let inner = CloudflareDeployTarget(
            tokenSource: { "tok" },
            domainConfigDriftSource: { _, _, _ in
                [DomainConfigAudit.Finding(category: .dns, title: "dns", detail: "drift", remediation: .informational)]
            })
        // No steps scripted on this executor — if `publish` ever ran a wrangler subcommand before
        // the domain-drift gate, `ran(_:)` below would still (correctly) report it, since `run`
        // records every step it's actually invoked with regardless of whether it was pre-stubbed.
        let executor = FakeExecutor()
        let indieauth = worker(WorkerComposition.indieauthWorkerID, d1: true, kv: false, r2: false)
        let target = SocialWorkerProvisionTarget(
            cloudflareTarget: inner, siteName: "site", workers: [indieauth],
            keyPairSource: stubKeyPairSource, solidOidcSigningKeySource: stubSolidOidcSigningKeySource,
            webdavPepperSource: stubWebdavPepperSource, secretRunner: stubSecretRunner,
            accountIDSource: stubAccountIDSource)
        let cmd = DeployCommand(target: target, executor: executor)
        let result = await cmd.deploy(siteID: "s", siteDirectory: tmpDir)
        guard case .domainConfigDrift = result else { Issue.record("expected .domainConfigDrift, got \(result)"); return }
        #expect(!executor.ran(.wranglerSubcommand(args: ["d1", "create", "site-social"])))
    }

    @Test("publish returns .webmentionPaidPlanConfirmationNeeded before creating a Queue when unacknowledged")
    func publishGatesQueueOnPaidPlanAcknowledgement() async throws {
        let tmpDir = try temporaryDirectory()
        let executor = FakeExecutor()
            .set(.build, exitCode: 0, output: "")
            .set(.preflight, exitCode: 0, output: scanJSON(ok: true))
        let inner = CloudflareDeployTarget(tokenSource: { "tok" })
        let webmention = worker(WorkerComposition.webmentionWorkerID, d1: false, kv: false, r2: false)
        let target = SocialWorkerProvisionTarget(
            cloudflareTarget: inner, siteName: "site", workers: [webmention], acknowledgesPaidPlan: false,
            keyPairSource: stubKeyPairSource, solidOidcSigningKeySource: stubSolidOidcSigningKeySource,
            webdavPepperSource: stubWebdavPepperSource, secretRunner: stubSecretRunner,
            accountIDSource: stubAccountIDSource)
        let cmd = DeployCommand(target: target, executor: executor)
        let result = await cmd.deploy(siteID: "s", siteDirectory: tmpDir)
        #expect(result == .webmentionPaidPlanConfirmationNeeded)
        let resources = await target.resources
        #expect(resources.queueName == nil)
    }

    /// The resumability property this actor exists for (per its own doc comment on `resources`
    /// and on the type itself): a resource id already created in a failed run must survive that
    /// failure so a retry doesn't recreate it. D1 creation succeeds; the very next step (KV
    /// creation) fails outright. If a future refactor reverted `resources` to a local `var` or
    /// reordered a mutation to after its `persistConfig` call, this would start failing while
    /// `DeployCommand.Result` still reported `.failed` — the id itself would silently be lost.
    @Test("a D1 id created before a later KV failure survives on target.resources")
    func d1IDSurvivesLaterKVFailure() async throws {
        let tmpDir = try temporaryDirectory()
        let executor = FakeExecutor()
            .set(.wranglerSubcommand(args: ["d1", "create", "site-social"]), exitCode: 0, output: #"{"database_id":"db-abc"}"#)
            .set(.wranglerSubcommand(args: ["kv", "namespace", "create", "site-social"]), exitCode: 1, output: "kv namespace create failed")
            .set(.build, exitCode: 0, output: "")
            .set(.preflight, exitCode: 0, output: scanJSON(ok: true))
        let inner = CloudflareDeployTarget(tokenSource: { "tok" })
        let websub = worker(WorkerComposition.websubWorkerID, d1: true, kv: true, r2: false)
        let target = SocialWorkerProvisionTarget(
            cloudflareTarget: inner, siteName: "site", workers: [websub],
            keyPairSource: stubKeyPairSource, solidOidcSigningKeySource: stubSolidOidcSigningKeySource,
            webdavPepperSource: stubWebdavPepperSource, secretRunner: stubSecretRunner,
            accountIDSource: stubAccountIDSource)
        let cmd = DeployCommand(target: target, executor: executor)
        let result = await cmd.deploy(siteID: "s", siteDirectory: tmpDir)
        guard case .failed = result else {
            Issue.record("expected .failed, got \(result)")
            return
        }
        let resources = await target.resources
        #expect(resources.d1DatabaseID == "db-abc")
        #expect(resources.kvNamespaceID == nil)
    }

    @Test("indieauth worker triggers the AUTH_DB migration wrangler subcommand")
    func indieauthTriggersAuthDBMigration() async throws {
        let tmpDir = try temporaryDirectory()
        let executor = FakeExecutor()
            .set(.wranglerSubcommand(args: ["d1", "create", "site-social"]), exitCode: 0, output: #"{"database_id":"db-abc"}"#)
            .set(.wranglerSubcommand(args: ["d1", "migrations", "apply", "AUTH_DB", "--remote"]), exitCode: 0, output: "Migrations applied")
            .set(.build, exitCode: 0, output: "")
            .set(.preflight, exitCode: 0, output: scanJSON(ok: true))
            .set(.wrangler, exitCode: 0, output: "Published site (0.1 sec)\n  https://site.workers.dev")
        let inner = CloudflareDeployTarget(tokenSource: { "tok" })
        let indieauth = worker(WorkerComposition.indieauthWorkerID, d1: true, kv: false, r2: false)
        let target = SocialWorkerProvisionTarget(
            cloudflareTarget: inner, siteName: "site", workers: [indieauth],
            keyPairSource: stubKeyPairSource, solidOidcSigningKeySource: stubSolidOidcSigningKeySource,
            webdavPepperSource: stubWebdavPepperSource, secretRunner: stubSecretRunner,
            accountIDSource: stubAccountIDSource)
        let cmd = DeployCommand(target: target, executor: executor)
        let result = await cmd.deploy(siteID: "s", siteDirectory: tmpDir)
        guard case .succeeded = result else {
            Issue.record("expected .succeeded, got \(result)")
            return
        }
        #expect(executor.ran(.wranglerSubcommand(args: ["d1", "migrations", "apply", "AUTH_DB", "--remote"])))
    }

    @Test("a successful websub Queue creation writes WEBSUB_ENABLED=true into .site-config")
    func websubQueueWritesEnabledFlag() async throws {
        let tmpDir = try temporaryDirectory()
        let executor = FakeExecutor()
            .set(.wranglerSubcommand(args: ["queues", "create", "site-websub"]), exitCode: 0, output: #"{"queue_name":"site-websub"}"#)
            .set(.build, exitCode: 0, output: "")
            .set(.preflight, exitCode: 0, output: scanJSON(ok: true))
            .set(.wrangler, exitCode: 0, output: "Published site (0.1 sec)\n  https://site.workers.dev")
        let inner = CloudflareDeployTarget(tokenSource: { "tok" })
        let websub = worker(WorkerComposition.websubWorkerID, d1: false, kv: false, r2: false)
        let target = SocialWorkerProvisionTarget(
            cloudflareTarget: inner, siteName: "site", workers: [websub], acknowledgesPaidPlan: true,
            keyPairSource: stubKeyPairSource, solidOidcSigningKeySource: stubSolidOidcSigningKeySource,
            webdavPepperSource: stubWebdavPepperSource, secretRunner: stubSecretRunner,
            accountIDSource: stubAccountIDSource)
        let cmd = DeployCommand(target: target, executor: executor)
        let result = await cmd.deploy(siteID: "s", siteDirectory: tmpDir)
        guard case .succeeded = result else {
            Issue.record("expected .succeeded, got \(result)")
            return
        }
        let config = try String(contentsOf: tmpDir.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(SiteConfigFile.value(forKey: "WEBSUB_ENABLED", in: config) == "true")
    }
}
