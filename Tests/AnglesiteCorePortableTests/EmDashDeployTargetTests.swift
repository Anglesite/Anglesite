// Portable target: EmDash provisioning is Foundation plus injected seams (executor, secret push,
// key source), and this is the AnglesiteCore test target the Linux CI leg runs.
import AnglesiteSiteModel
import Foundation
import Testing
@testable import AnglesiteCore

@Suite("EmDash provisioning (#2103)")
struct EmDashDeployTargetTests {
    /// Answers each step from `outputs` (keyed by the wrangler arguments) and records the order.
    final class FakeExecutor: DeployExecutor, @unchecked Sendable {
        private let lock = NSLock()
        private var outputs: [String: DeployStepResult]
        private(set) var steps: [String] = []

        init(_ outputs: [String: DeployStepResult]) { self.outputs = outputs }

        static func key(_ step: DeployStep) -> String {
            switch step {
            case .wranglerSubcommand(let args): return args.joined(separator: " ")
            case .build: return "build"
            case .preflight: return "preflight"
            case .wrangler: return "wrangler"
            case .bundleUpload: return "bundleUpload"
            case .githubPagesPublish: return "githubPagesPublish"
            }
        }

        func run(step: DeployStep, siteDirectory: URL, environment: [String: String], source: String) async -> DeployStepResult {
            let key = Self.key(step)
            return lock.withLock {
                steps.append(key)
                return outputs[key] ?? DeployStepResult(exitCode: 0, output: "")
            }
        }
    }

    final class Secrets: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var pushed: [(name: String, value: String)] = []
        var runner: SocialWorkerProvisionCommand.SecretRunner {
            { [self] _, name, value, _, _ in
                lock.withLock { pushed.append((name, value)) }
                return .init(stdout: "", stderr: "", exitCode: 0)
            }
        }
    }

    final class MemorySecretStore: SecretStore, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]
        func read(account: String) throws -> String? { lock.withLock { values[account] } }
        func write(_ value: String, account: String) throws { lock.withLock { values[account] = value.isEmpty ? nil : value } }
        func delete(account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
    }

    /// A fresh account: nothing exists yet, and the Worker hasn't been deployed.
    private static let created: [String: DeployStepResult] = [
        "d1 list --json": .init(exitCode: 0, output: #"[{"uuid":"other-db","name":"blog-cms"}]"#),
        "d1 create news-cms": .init(exitCode: 0, output: #"{"uuid":"0f2c1d3e-aaaa-bbbb-cccc-1234567890ab"}"#),
        "r2 bucket info news-cms-media --json": .init(exitCode: 1, output: "The specified bucket does not exist."),
        "r2 bucket create news-cms-media": .init(exitCode: 0, output: "Created bucket news-cms-media"),
        "kv namespace list": .init(exitCode: 0, output: "[]"),
        "kv namespace create news-cms-session": .init(exitCode: 0, output: #"{ binding = "news-cms-session", id = "5a5b5c5d5e5f" }"#),
        "secret list --format json": .init(exitCode: 1, output: "Worker \"news\" not found.\nIf this is a new Worker, run `wrangler deploy` first to create it."),
    ]

    private static let freshSteps = [
        "d1 list --json", "d1 create news-cms",
        "r2 bucket info news-cms-media --json", "r2 bucket create news-cms-media",
        "kv namespace list", "kv namespace create news-cms-session",
        "secret list --format json",
    ]

    private static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("emdash-provision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func context(_ dir: URL, executor: any DeployExecutor) -> DeployTargetContext {
        DeployTargetContext(
            siteID: "news", siteDirectory: dir.appendingPathComponent("Source"), configDirectory: dir.appendingPathComponent("Config"),
            currentRoutes: [], credential: "tok", baseEnvironment: [:], executor: executor,
            onDomainAttach: nil, onMarkdownForAgents: nil, onProgress: nil)
    }

    private static func target(_ secrets: Secrets, key: String = "emdash_enc_v1_key") -> EmDashDeployTarget {
        EmDashDeployTarget(
            cloudflareTarget: CloudflareDeployTarget(tokenSource: { "tok" }), siteName: "news",
            encryptionKeySource: { _ in key }, secretRunner: secrets.runner)
    }

    @Test("a first publish creates the database, bucket and session store, writes the Worker config and pushes the key")
    func provisionsFreshSite() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let executor = FakeExecutor(Self.created)
        let secrets = Secrets()
        let context = Self.context(dir, executor: executor)

        let failure = await Self.target(secrets).prepare(context: context)
        #expect(failure == nil)
        #expect(executor.steps == Self.freshSteps)

        let settings = try await SiteConfigStore(configDirectory: context.configDirectory).load()
        #expect(settings.emdashResources == .init(
            d1DatabaseName: "news-cms", d1DatabaseID: "0f2c1d3e-aaaa-bbbb-cccc-1234567890ab",
            mediaBucketName: "news-cms-media", sessionKVNamespaceID: "5a5b5c5d5e5f"))
        #expect(settings.emdashD1DatabaseID == "0f2c1d3e-aaaa-bbbb-cccc-1234567890ab")

        let toml = try #require(WranglerConfigFile.read(configDirectory: context.configDirectory))
        #expect(toml.contains(#"main = "./src/worker.ts""#))
        #expect(toml.contains(#"database_id = "0f2c1d3e-aaaa-bbbb-cccc-1234567890ab""#))
        #expect(toml.contains(#"bucket_name = "news-cms-media""#))
        // Not asked about the Workers plan (a background publish): the Worker doesn't cache.
        #expect(toml.contains("[cache]\nenabled = false"))
        #expect(secrets.pushed.map(\.name) == ["EMDASH_ENCRYPTION_KEY"])
        #expect(secrets.pushed.first?.value == "emdash_enc_v1_key")
    }

    @Test("a publish after a partial one creates only what's missing")
    func resumes() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let executor = FakeExecutor(Self.created)
        let context = Self.context(dir, executor: executor)
        _ = try await SiteConfigStore(configDirectory: context.configDirectory).update {
            $0.emdashResources = .init(d1DatabaseName: "news-cms", d1DatabaseID: "db1")
        }
        #expect(await Self.target(Secrets()).prepare(context: context) == nil)
        #expect(executor.steps == Array(Self.freshSteps.dropFirst(2)))
    }

    @Test("resources already on the account (an interrupted publish, lost settings) are adopted, not created again")
    func adoptsExisting() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var outputs = Self.created
        outputs["d1 list --json"] = .init(exitCode: 0, output: """
            ▲ [WARNING] Proxy environment variables detected. We'll use your proxy for fetch requests.
            [{"uuid":"other-db","name":"blog-cms"},{"uuid":"db-existing","name":"news-cms"}]
            """)
        outputs["r2 bucket info news-cms-media --json"] = .init(exitCode: 0, output: #"{"name":"news-cms-media"}"#)
        outputs["kv namespace list"] = .init(exitCode: 0, output: #"[{"id":"kv-existing","title":"news-cms-session"}]"#)
        let executor = FakeExecutor(outputs)
        let context = Self.context(dir, executor: executor)

        #expect(await Self.target(Secrets()).prepare(context: context) == nil)
        #expect(!executor.steps.contains { $0.contains(" create ") })
        let resources = try await SiteConfigStore(configDirectory: context.configDirectory).load().emdashResources
        #expect(resources == .init(
            d1DatabaseName: "news-cms", d1DatabaseID: "db-existing",
            mediaBucketName: "news-cms-media", sessionKVNamespaceID: "kv-existing"))
    }

    @Test("a Worker that already holds the encryption key keeps it: nothing is pushed and no key is made")
    func keepsWorkersKey() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var outputs = Self.created
        outputs["secret list --format json"] = .init(exitCode: 0, output: #"[{"name":"EMDASH_ENCRYPTION_KEY","type":"secret_text"}]"#)
        let secrets = Secrets()
        let target = EmDashDeployTarget(
            cloudflareTarget: CloudflareDeployTarget(tokenSource: { "tok" }), siteName: "news",
            encryptionKeySource: { _ in
                Issue.record("a key must not be read or made when the Worker already has one")
                return "new-key"
            },
            secretRunner: secrets.runner)
        #expect(await target.prepare(context: Self.context(dir, executor: FakeExecutor(outputs))) == nil)
        #expect(secrets.pushed.isEmpty)
    }

    @Test("a Worker without the key gets it; one whose secrets can't be read stops the publish")
    func keyPushRules() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var outputs = Self.created
        outputs["secret list --format json"] = .init(exitCode: 0, output: "[]")
        let secrets = Secrets()
        #expect(await Self.target(secrets).prepare(context: Self.context(dir, executor: FakeExecutor(outputs))) == nil)
        #expect(secrets.pushed.map(\.name) == ["EMDASH_ENCRYPTION_KEY"])

        let other = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: other) }
        outputs["secret list --format json"] = .init(exitCode: 1, output: "Authentication error [code: 10000]")
        let blocked = Secrets()
        let failure = await Self.target(blocked).prepare(context: Self.context(other, executor: FakeExecutor(outputs)))
        #expect(failure == .failed(reason: "Authentication error [code: 10000]", exitCode: 1))
        #expect(blocked.pushed.isEmpty)

        #expect(EmDashDeployTarget.isWorkerNotFound(#"Worker "news" not found."#))
        #expect(EmDashDeployTarget.isWorkerNotFound(#"Worker "news" (env: production) not found."#))
        #expect(!EmDashDeployTarget.isWorkerNotFound("Authentication error"))
    }

    @Test("a failed step stops the publish and keeps what was already created")
    func failureKeepsProgress() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var outputs = Self.created
        outputs["r2 bucket create news-cms-media"] = .init(exitCode: 1, output: "R2 isn't enabled on this account")
        let secrets = Secrets()
        let context = Self.context(dir, executor: FakeExecutor(outputs))

        let failure = await Self.target(secrets).prepare(context: context)
        #expect(failure == .failed(reason: "R2 isn't enabled on this account", exitCode: 1))
        let settings = try await SiteConfigStore(configDirectory: context.configDirectory).load()
        #expect(settings.emdashResources?.d1DatabaseID == "0f2c1d3e-aaaa-bbbb-cccc-1234567890ab")
        #expect(settings.emdashResources?.mediaBucketName == nil)
        #expect(WranglerConfigFile.read(configDirectory: context.configDirectory) == nil)
        #expect(secrets.pushed.isEmpty)
    }

    @Test("an id that isn't a plain identifier is refused, not saved")
    func refusesOddID() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var outputs = Self.created
        outputs["d1 create news-cms"] = .init(exitCode: 0, output: #"database_id = "abc\"\n[vars]""#)
        let context = Self.context(dir, executor: FakeExecutor(outputs))
        let failure = await Self.target(Secrets()).prepare(context: context)
        #expect(failure == .failed(reason: "wrangler created D1 database news-cms but no database id was found", exitCode: 0))
        #expect(try await SiteConfigStore(configDirectory: context.configDirectory).load().emdashResources == nil)
    }

    @Test("the Worker config binds EmDash's database, media and sessions, and refuses anything but plain identifiers")
    func workerConfig() throws {
        let resources = EmDashWorkerConfig.Resources(
            d1DatabaseName: "news-cms", d1DatabaseID: "db1", mediaBucketName: "news-cms-media", sessionKVNamespaceID: "kv1")
        let toml = try EmDashWorkerConfig.toml(workerName: "news", resources: resources)
        #expect(toml.contains("[cache]\nenabled = false"))
        #expect(try EmDashWorkerConfig.toml(workerName: "news", resources: resources, cache: true).contains("[cache]\nenabled = true"))
        for line in [
            #"name = "news""#, #"compatibility_flags = ["nodejs_compat"]"#, #"crons = ["* * * * *"]"#,
            #"binding = "DB""#, #"binding = "MEDIA""#, #"binding = "SESSION""#, #"id = "kv1""#,
        ] {
            #expect(toml.contains(line), "\(line)")
        }
        #expect(throws: EmDashWorkerConfig.ConfigError.incomplete) {
            try EmDashWorkerConfig.toml(workerName: "news", resources: .init(d1DatabaseName: "news-cms"))
        }
        var odd = resources
        odd.sessionKVNamespaceID = "kv1\"\n[vars]"
        #expect(throws: EmDashWorkerConfig.ConfigError.invalidValue("kv1\"\n[vars]")) {
            try EmDashWorkerConfig.toml(workerName: "news", resources: odd)
        }
    }

    @Test("the Worker caches only when the owner said the account is on the Workers Paid plan")
    func cacheFollowsTheOwnersAnswer() async throws {
        for (answer, enabled) in [(true, true), (false, false)] {
            let dir = try Self.tempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let context = Self.context(dir, executor: FakeExecutor(Self.created))
            try await EmDashDeployTarget.recordWorkersPlan(paid: answer, configDirectory: context.configDirectory)
            #expect(await Self.target(Secrets()).prepare(context: context) == nil)
            let toml = try #require(WranglerConfigFile.read(configDirectory: context.configDirectory))
            #expect(toml.contains("[cache]\nenabled = \(enabled)"), "answer \(answer)")
        }
    }

    @Test("Publish Site asks about the Workers plan once, and only for an EmDash site")
    func asksOnceForEmDash() async throws {
        let root = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let (emdash, _) = try AnglesitePackage.createSkeleton(
            at: root.appendingPathComponent("News.anglesite"), displayName: "News", kind: .emdash)
        let (anglesite, _) = try AnglesitePackage.createSkeleton(
            at: root.appendingPathComponent("Blog.anglesite"), displayName: "Blog")
        #expect(EmDashDeployTarget.needsWorkersPlanAnswer(sourceDirectory: emdash.sourceURL, configDirectory: emdash.configURL))
        #expect(!EmDashDeployTarget.needsWorkersPlanAnswer(sourceDirectory: anglesite.sourceURL, configDirectory: anglesite.configURL))

        // Either answer is final: "Free Plan" isn't asked again either.
        try await EmDashDeployTarget.recordWorkersPlan(paid: false, configDirectory: emdash.configURL)
        #expect(!EmDashDeployTarget.needsWorkersPlanAnswer(sourceDirectory: emdash.sourceURL, configDirectory: emdash.configURL))
        #expect(try await SiteConfigStore(configDirectory: emdash.configURL).load().emdashWorkersPaidPlan == false)
    }

    @Test("resource names fit Cloudflare's limits for the longest Worker name Anglesite allows")
    func namesFit() {
        let longest = String(repeating: "a", count: 52)
        #expect(WorkerSiteName.isValidR2BucketName(EmDashWorkerConfig.mediaBucketName(siteName: longest)))
        #expect(EmDashWorkerConfig.databaseName(siteName: longest).count <= 63)
    }

    @Test("the encryption key is EmDash's format, generated once and then reused")
    func encryptionKey() throws {
        let key = EmDashWorkerConfig.generateEncryptionKey()
        #expect(key.hasPrefix("emdash_enc_v1_"))
        let body = key.dropFirst("emdash_enc_v1_".count)
        #expect(body.count == 43)
        #expect(body.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        #expect(EmDashWorkerConfig.generateEncryptionKey() != key)

        let store = MemorySecretStore()
        let first = try EmDashWorkerConfig.encryptionKey(siteID: "news", secretStore: store)
        #expect(try EmDashWorkerConfig.encryptionKey(siteID: "news", secretStore: store) == first)
        #expect(try EmDashWorkerConfig.encryptionKey(siteID: "other", secretStore: store) != first)
    }

    @Test("Open EmDash goes to the admin on the published https address")
    func adminURL() {
        #expect(EmDashDeployTarget.adminURL(siteURL: URL(string: "https://news.example.workers.dev")!)?.absoluteString
            == "https://news.example.workers.dev/_emdash/admin")
        #expect(EmDashDeployTarget.adminURL(siteURL: URL(string: "https://news.example/articles/?x=1")!)?.absoluteString
            == "https://news.example/_emdash/admin")
        #expect(EmDashDeployTarget.adminURL(siteURL: URL(string: "http://news.example")!) == nil)
    }

    @Test("the deploy takes an EmDash site through the EmDash target, and refuses the wrong pairing")
    func deployPairsKindAndTarget() async throws {
        let root = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let (emdash, _) = try AnglesitePackage.createSkeleton(
            at: root.appendingPathComponent("News.anglesite"), displayName: "News", kind: .emdash)
        let (anglesite, _) = try AnglesitePackage.createSkeleton(
            at: root.appendingPathComponent("Blog.anglesite"), displayName: "Blog")
        let emdashTarget = EmDashDeployTarget(
            cloudflareTarget: CloudflareDeployTarget(tokenSource: { nil }), siteName: "news",
            encryptionKeySource: { _ in "k" }, secretRunner: Secrets().runner)
        let command = DeployCommand(target: emdashTarget, templateDirectory: { nil })

        let refused = await command.deploy(siteID: "blog", siteDirectory: anglesite.sourceURL, configDirectory: anglesite.configURL)
        #expect(refused == .failed(reason: SiteEditingSurfaces.serverRenderedDeployUnavailableReason, exitCode: nil))

        // Past the kind check: it stops at the missing Cloudflare token instead.
        let emdashResult = await command.deploy(siteID: "news", siteDirectory: emdash.sourceURL, configDirectory: emdash.configURL)
        #expect(emdashResult != .failed(reason: SiteEditingSurfaces.staticDeployUnavailableReason, exitCode: nil))
        #expect(emdashResult != .failed(reason: SiteEditingSurfaces.serverRenderedDeployUnavailableReason, exitCode: nil))

        #expect(SiteEditingSurfaces.publishRefusal(sourceDirectory: emdash.sourceURL) == nil)
        #expect(SiteEditingSurfaces.publishRefusal(sourceDirectory: anglesite.sourceURL) == nil)
        try FileManager.default.removeItem(at: anglesite.infoPlistURL)
        #expect(SiteEditingSurfaces.publishRefusal(sourceDirectory: anglesite.sourceURL) == SiteEditingSurfaces.siteKindUnconfirmedReason)
    }
}
