// Portable target: composing the social endpoints into an EmDash Worker is Foundation plus the
// same injected seams as `EmDashDeployTargetTests`, and this is the target the Linux CI leg runs.
import AnglesiteSiteModel
import Foundation
import Testing
@testable import AnglesiteCore

@Suite("EmDash social composition (#2162)")
struct EmDashSocialCompositionTests {
    private typealias FakeExecutor = EmDashDeployTargetTests.FakeExecutor
    private typealias Secrets = EmDashDeployTargetTests.Secrets

    private static func worker(_ id: String, needsD1: Bool = true, needsKV: Bool = true) -> WorkerDescriptor {
        WorkerDescriptor(
            id: id, displayName: id.capitalized, description: id, group: "social", binding: .settingsActivated,
            resources: .init(needsD1: needsD1, needsKV: needsKV, needsR2: false))
    }

    private static let webmention = worker(WorkerComposition.webmentionWorkerID)
    private static let indieauth = worker(WorkerComposition.indieauthWorkerID)
    private static let activitypub = worker(WorkerComposition.activitypubWorkerID, needsD1: false, needsKV: false)
    private static let micropub = worker(WorkerComposition.micropubWorkerID)

    /// A fresh account, as in `EmDashDeployTargetTests`, plus the social endpoints' resources.
    private static let created: [String: DeployStepResult] = [
        "d1 list --json": .init(exitCode: 0, output: "[]"),
        "d1 create news-cms": .init(exitCode: 0, output: #"{"uuid":"0f2c1d3e-aaaa-bbbb-cccc-1234567890ab"}"#),
        "r2 bucket info news-cms-media --json": .init(exitCode: 1, output: "The specified bucket does not exist."),
        "kv namespace list": .init(exitCode: 0, output: "[]"),
        "kv namespace create news-cms-session": .init(exitCode: 0, output: #"{ binding = "news-cms-session", id = "5a5b5c5d5e5f" }"#),
        "secret list --format json": .init(exitCode: 1, output: "Worker \"news\" not found."),
        "d1 create news-social": .init(exitCode: 0, output: #"{"uuid":"9e8d7c6b-aaaa-bbbb-cccc-1234567890ab"}"#),
        "kv namespace create news-social": .init(exitCode: 0, output: #"{ binding = "news-social", id = "6a6b6c6d6e6f" }"#),
    ]

    private static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("emdash-social-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Source"), withIntermediateDirectories: true)
        return url
    }

    private static func context(_ dir: URL, executor: any DeployExecutor) -> DeployTargetContext {
        DeployTargetContext(
            siteID: "news", siteDirectory: dir.appendingPathComponent("Source"), configDirectory: dir.appendingPathComponent("Config"),
            currentRoutes: [], credential: "tok", baseEnvironment: [:], executor: executor,
            onDomainAttach: nil, onMarkdownForAgents: nil, onProgress: nil)
    }

    private static func target(
        _ secrets: Secrets, workers: [WorkerDescriptor], acknowledgesPaidPlan: Bool = true
    ) -> EmDashDeployTarget {
        let cloudflareTarget = CloudflareDeployTarget(tokenSource: { "tok" })
        return EmDashDeployTarget(
            cloudflareTarget: cloudflareTarget, siteName: "news",
            encryptionKeySource: { _ in "emdash_enc_v1_key" }, secretRunner: secrets.runner,
            social: { composeInto in
                SocialWorkerProvisionTarget(
                    cloudflareTarget: cloudflareTarget, siteName: "news", workers: workers,
                    siteURL: "https://news.example", displayName: "News",
                    acknowledgesPaidPlan: acknowledgesPaidPlan,
                    keyPairSource: { _ in .init(privateKeyPem: "private", publicKeyPem: "public", publishToken: "publish") },
                    solidOidcSigningKeySource: { _ in "jwk" }, webdavPepperSource: { _ in "pepper" },
                    secretRunner: secrets.runner, accountIDSource: { _ in nil }, composeInto: composeInto)
            })
    }

    @Test("an EmDash site's social endpoints are provisioned into its Worker's config, before the build")
    func provisionsIntoEmDashWorker() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let executor = FakeExecutor(Self.created)
        let secrets = Secrets()
        let context = Self.context(dir, executor: executor)
        let target = Self.target(secrets, workers: [Self.webmention, Self.indieauth, Self.activitypub])

        #expect(await target.prepare(context: context) == nil)

        // EmDash's resources first, then the social endpoints'; the migration names the config
        // just written rather than a previous build's.
        #expect(executor.steps.prefix(5) == ["d1 list --json", "d1 create news-cms", "r2 bucket info news-cms-media --json", "r2 bucket create news-cms-media", "kv namespace list"])
        #expect(executor.steps.contains("queues create news-webmention"))
        #expect(executor.steps.last == "d1 migrations apply AUTH_DB --remote --config wrangler.toml")
        #expect(secrets.pushed.map(\.name) == ["EMDASH_ENCRYPTION_KEY", "AP_PRIVATE_KEY", "AP_PUBLIC_KEY", "AP_PUBLISH_TOKEN"])

        let toml = try #require(WranglerConfigFile.read(configDirectory: context.configDirectory))
        #expect(toml.contains(#"main = "./src/worker.ts""#))
        #expect(!toml.contains("[assets]"))
        #expect(toml.components(separatedBy: "binding = \"DB\"").count == 2, "only EmDash's database is bound as DB")
        #expect(toml.components(separatedBy: "\nname = \"news\"\n").count == 2, "one Worker name")
        for binding in ["AUTH_DB", "WEBMENTION_INBOX", "WEBMENTION_QUEUE", "SOCIAL_KV"] {
            #expect(toml.contains("binding = \"\(binding)\""))
        }
        #expect(toml.contains(#"class_name = "ActivityPubObject""#))
        #expect(toml.contains(#"database_id = "9e8d7c6b-aaaa-bbbb-cccc-1234567890ab""#))
        #expect(toml.contains(#"SITE_URL = "https://news.example""#))
        #expect(toml.contains(#"crons = ["* * * * *"]"#))

        #expect(await target.socialResources == .init(
            d1DatabaseID: "9e8d7c6b-aaaa-bbbb-cccc-1234567890ab", kvNamespaceID: "6a6b6c6d6e6f",
            queueName: "news-webmention"))
        // Bundled into the server build, so the pages advertise the endpoint the Worker serves.
        let siteConfig = try String(contentsOf: context.siteDirectory.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(siteConfig.contains("WEBMENTION_RECEIVE_ENABLED=true"))
    }

    @Test("the social crons join EmDash's, which keeps its own")
    func mergesCrons() throws {
        let resources = EmDashWorkerConfig.Resources(
            d1DatabaseName: "news-cms", d1DatabaseID: "db", mediaBucketName: "news-cms-media", sessionKVNamespaceID: "kv")
        let social = try WorkerComposition.generateWranglerToml(
            siteName: "news", workers: [Self.worker(WorkerComposition.microsubWorkerID), Self.indieauth], host: .emdash)
        #expect(social.cronSchedules == ["*/15 * * * *"])
        #expect(!social.toml.contains("[triggers]"))
        let toml = try EmDashWorkerConfig.toml(workerName: "news", resources: resources, social: social)
        #expect(toml.contains(#"crons = ["* * * * *", "*/15 * * * *"]"#))
        #expect(toml.components(separatedBy: "[triggers]").count == 2)
    }

    @Test("a queue-backed endpoint waits for the owner's paid-plan confirmation, as on any site")
    func asksAboutPaidPlan() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let executor = FakeExecutor(Self.created)
        let target = Self.target(Secrets(), workers: [Self.webmention], acknowledgesPaidPlan: false)
        #expect(await target.prepare(context: Self.context(dir, executor: executor)) == .webmentionPaidPlanConfirmationNeeded)
        #expect(!executor.steps.contains { $0.hasPrefix("queues create") })
        // What was created before the question is kept for the next publish.
        #expect(await target.socialResources?.d1DatabaseID == "9e8d7c6b-aaaa-bbbb-cccc-1234567890ab")
    }

    @Test("features an EmDash site doesn't offer are left out, and named")
    func leavesOutGitFeatures() throws {
        #expect(EmDashSocialComposition.composableWorkers([Self.webmention, Self.micropub, Self.activitypub]).map(\.id)
            == [WorkerComposition.webmentionWorkerID, WorkerComposition.activitypubWorkerID])
        let running = DomainConfig.Experiments.Experiment(
            id: "hero", name: "Hero", page: "/", variant: .init(id: "b", name: "B", page: "/b/"), split: 0.5,
            goal: .init(kind: "pageview", path: "/thanks"), status: "running")
        #expect(EmDashSocialComposition.leftOff(
            workers: [Self.webmention, Self.micropub], inboxCaptureEnabled: true, experiments: [running], mcpEnabled: true)
            == ["Micropub", "Inbox Capture", "experiments", "MCP"])
        #expect(EmDashSocialComposition.leftOff(workers: [Self.webmention], inboxCaptureEnabled: false, experiments: [], mcpEnabled: false).isEmpty)

        // The backstop: EmDash's own bindings can never be shadowed.
        #expect(throws: WorkerComposition.ConfigError.self) {
            try WorkerComposition.generateWranglerToml(siteName: "news", workers: [Self.micropub], host: .emdash)
        }
        #expect(throws: WorkerComposition.ConfigError.self) {
            try WorkerComposition.generateWranglerToml(siteName: "news", workers: [Self.webmention], mcpEnabled: true, host: .emdash)
        }
    }

    /// The config `scripts/check-emdash-overlay.sh` builds and boots an EmDash site with, so the
    /// check exercises exactly what `EmDashWorkerConfig` writes. Local ids stand in for Cloudflare's.
    @Test("the overlay check's Worker config is the one Anglesite writes")
    func overlayCheckFixture() throws {
        let resources = EmDashWorkerConfig.Resources(
            d1DatabaseName: "anglesite-check-cms", d1DatabaseID: "00000000-0000-4000-8000-000000002162",
            mediaBucketName: "anglesite-check-cms-media", sessionKVNamespaceID: "00000000000000000000000000002162")
        let social = try WorkerComposition.generateWranglerToml(
            siteName: "anglesite-check", workers: [Self.webmention, Self.indieauth, Self.activitypub],
            resources: .init(
                d1DatabaseID: "00000000-0000-4000-8000-000000002163", kvNamespaceID: "00000000000000000000000000002163",
                queueName: "anglesite-check-webmention"),
            siteURL: "https://example.com", displayName: "Anglesite Check", host: .emdash)
        let toml = try EmDashWorkerConfig.toml(workerName: "anglesite-check", resources: resources, social: social)
        let fixture = try #require(Bundle.module.url(
            forResource: "composed-wrangler", withExtension: "toml", subdirectory: "Fixtures/EmDash"))
        #expect(toml == (try String(contentsOf: fixture, encoding: .utf8)))
    }
}
