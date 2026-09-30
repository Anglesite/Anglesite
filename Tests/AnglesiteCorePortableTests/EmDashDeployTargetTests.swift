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

    private static let created: [String: DeployStepResult] = [
        "d1 create news-cms": .init(exitCode: 0, output: #"{"uuid":"0f2c1d3e-aaaa-bbbb-cccc-1234567890ab"}"#),
        "r2 bucket create news-cms-media": .init(exitCode: 0, output: "Created bucket news-cms-media"),
        "kv namespace create news-cms-session": .init(exitCode: 0, output: #"{ binding = "news-cms-session", id = "5a5b5c5d5e5f" }"#),
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
        #expect(executor.steps == ["d1 create news-cms", "r2 bucket create news-cms-media", "kv namespace create news-cms-session"])

        let settings = try await SiteConfigStore(configDirectory: context.configDirectory).load()
        #expect(settings.emdashResources == .init(
            d1DatabaseName: "news-cms", d1DatabaseID: "0f2c1d3e-aaaa-bbbb-cccc-1234567890ab",
            mediaBucketName: "news-cms-media", sessionKVNamespaceID: "5a5b5c5d5e5f"))
        #expect(settings.emdashD1DatabaseID == "0f2c1d3e-aaaa-bbbb-cccc-1234567890ab")

        let toml = try #require(WranglerConfigFile.read(configDirectory: context.configDirectory))
        #expect(toml.contains(#"main = "./src/worker.ts""#))
        #expect(toml.contains(#"database_id = "0f2c1d3e-aaaa-bbbb-cccc-1234567890ab""#))
        #expect(toml.contains(#"bucket_name = "news-cms-media""#))
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
        #expect(executor.steps == ["r2 bucket create news-cms-media", "kv namespace create news-cms-session"])
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
