// Portable target: finding and connecting an existing EmDash install is Foundation over an
// injected transport, and this is the AnglesiteCore test target the Linux CI leg runs.
import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import AnglesiteCore

@Suite("Connecting an existing EmDash install (#2106)")
struct EmDashConnectionTests {
    /// Answers the Cloudflare API from canned JSON, keyed by request path (and, for D1 queries,
    /// by the SQL's first matching fragment).
    final class StubAPI: @unchecked Sendable {
        private let lock = NSLock()
        var responses: [String: (Int, String)]
        var queries: [String: [(fragment: String, rows: String)]]
        private(set) var paths: [String] = []

        init(responses: [String: (Int, String)], queries: [String: [(fragment: String, rows: String)]] = [:]) {
            self.responses = responses
            self.queries = queries
        }

        var transport: CloudflareTransport {
            { [self] request in
                let path = request.url!.path.replacingOccurrences(of: "/client/v4", with: "")
                lock.withLock { paths.append(path) }
                var (status, json) = responses[path] ?? (404, #"{"success":false,"errors":[]}"#)
                if path.hasSuffix("/query") {
                    let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
                    let sql = body?["sql"] as? String ?? ""
                    let database = path.components(separatedBy: "/").dropLast().last ?? ""
                    let rows = queries[database]?.first { sql.contains($0.fragment) }?.rows ?? "[]"
                    (status, json) = (200, #"{"success":true,"result":[{"success":true,"results":\#(rows)}]}"#)
                }
                return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
        }
    }

    private static func ok(_ result: String) -> (Int, String) { (200, #"{"success":true,"result":\#(result)}"#) }

    private static let account = "/accounts/acct"

    /// Three Workers: a static site, an EmDash install with a sandbox, and one bound to a D1
    /// database that isn't EmDash's.
    private static func api() -> StubAPI {
        StubAPI(
            responses: [
                "\(account)/workers/scripts": ok(#"[{"id":"blog"},{"id":"news_room"},{"id":"tools"}]"#),
                "\(account)/workers/scripts/blog/settings": ok(#"{"bindings":[{"type":"assets","name":"ASSETS"}]}"#),
                "\(account)/workers/scripts/news_room/settings": ok(#"""
                    {"bindings":[
                      {"type":"d1","name":"DB","id":"db-news"},
                      {"type":"r2_bucket","name":"MEDIA","bucket_name":"news-media"},
                      {"type":"r2_bucket","name":"BACKUPS","bucket_name":"news-backups"},
                      {"type":"kv_namespace","name":"SESSION","namespace_id":"kv-news"},
                      {"type":"worker_loader","name":"LOADER"},
                      {"type":"secret_text","name":"EMDASH_ENCRYPTION_KEY"}
                    ]}
                    """#),
                "\(account)/workers/scripts/tools/settings": ok(#"{"bindings":[{"type":"d1","name":"DB","id":"db-tools"}]}"#),
                "\(account)/d1/database/db-news": ok(#"{"uuid":"db-news","name":"news-db"}"#),
            ],
            queries: [
                "db-news": [
                    ("'_emdash_collections'", #"[{"name":"_emdash_collections"}]"#),
                    ("'_plugin_state'", #"[{"name":"_plugin_state"}]"#),
                    ("SELECT plugin_id", #"""
                        [{"plugin_id":"anglesite-gate","source":"config"},{"plugin_id":"audit-log","source":"config"},
                         {"plugin_id":"seo-helper","source":"marketplace"}]
                        """#),
                ],
            ])
    }

    private static func finder(_ api: StubAPI) -> EmDashInstallFinder {
        EmDashInstallFinder(accountID: "acct", apiToken: "t", baseURL: "https://cf.test/client/v4", transport: api.transport)
    }

    @Test("an install is recognised by EmDash's schema in a bound database, with its bindings and plugins")
    func findsInstall() async throws {
        let installs = try await Self.finder(Self.api()).installs()
        #expect(installs == [EmDashInstall(
            workerName: "news_room", databaseName: "news-db", databaseID: "db-news", mediaBucketName: "news-media",
            sessionKVNamespaceID: "kv-news", hasWorkerLoader: true,
            marketplacePlugins: ["seo-helper"], codePlugins: ["audit-log"], problem: nil)])
        #expect(installs[0].stoppedMarketplacePlugins.isEmpty)
    }

    @Test("without a Worker Loader its marketplace plugins would stop; without a plugin table there are none")
    func loaderAndPlugins() async throws {
        let api = Self.api()
        api.responses["\(Self.account)/workers/scripts/news_room/settings"] = Self.ok(
            #"{"bindings":[{"type":"d1","name":"DB","id":"db-news"},{"type":"r2_bucket","name":"STORAGE","bucket_name":"news-media"}]}"#)
        var install = try #require(try await Self.finder(api).installs().first)
        #expect(!install.hasWorkerLoader)
        #expect(install.stoppedMarketplacePlugins == ["seo-helper"])
        // A single bucket is the media bucket whatever it's called; no SESSION means one is made later.
        #expect(install.mediaBucketName == "news-media")
        #expect(install.sessionKVNamespaceID == nil)
        #expect(install.resources.workerLoader == nil)

        api.queries["db-news"] = [("'_emdash_collections'", #"[{"name":"_emdash_collections"}]"#)]
        install = try #require(try await Self.finder(api).installs().first)
        #expect(install.marketplacePlugins.isEmpty && install.codePlugins.isEmpty)
    }

    @Test("several buckets, none called MEDIA, leave the media bucket unclear, and the install can't be connected")
    func unclearMedia() async throws {
        let api = Self.api()
        api.responses["\(Self.account)/workers/scripts/news_room/settings"] = Self.ok(#"""
            {"bindings":[{"type":"d1","name":"DB","id":"db-news"},
              {"type":"r2_bucket","name":"A","bucket_name":"a"},{"type":"r2_bucket","name":"B","bucket_name":"b"}]}
            """#)
        let install = try #require(try await Self.finder(api).installs().first)
        #expect(install.problem == .mediaBucketUnclear)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("connect-\(UUID().uuidString)")
        await #expect(throws: EmDashConnection.ConnectError.notConnectable(.mediaBucketUnclear)) {
            try await EmDashConnection.connect(install, sourceDirectory: dir, configDirectory: dir)
        }
    }

    @Test("a Worker whose settings can't be read is skipped; a refused token is an error")
    func unreadableAndUnauthorized() async throws {
        let api = Self.api()
        api.responses["\(Self.account)/workers/scripts/blog/settings"] = (500, "{}")
        #expect(try await Self.finder(api).installs().map(\.workerName) == ["news_room"])

        api.responses["\(Self.account)/workers/scripts"] = (403, "{}")
        await #expect(throws: CloudflareError.self) { try await Self.finder(api).installs() }
    }

    @Test("connecting records the install, so the publish binds its resources and deploys to its Worker")
    func connectThenPublish() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("connect-\(UUID().uuidString)")
        let source = root.appendingPathComponent("Source")
        let config = root.appendingPathComponent("Config")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("SITE_NAME=News\n".utf8).write(to: source.appendingPathComponent(".site-config"))

        let install = EmDashInstall(
            workerName: "news_room", databaseName: "news-db", databaseID: "db-news", mediaBucketName: "news-media",
            sessionKVNamespaceID: nil, hasWorkerLoader: true, marketplacePlugins: [], codePlugins: [], problem: nil)
        try await EmDashConnection.connect(install, sourceDirectory: source, configDirectory: config)

        let settings = try await SiteConfigStore(configDirectory: config).load()
        #expect(settings.workerProvisioned == true)
        #expect(settings.emdashD1DatabaseID == "db-news")
        let siteConfig = try String(contentsOf: source.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(siteConfig.contains("CF_PROJECT_NAME=news_room"))
        #expect(siteConfig.contains("SITE_NAME=News"))

        // The publish then creates only the session store the install lacked, and keeps the key.
        let executor = EmDashDeployTargetTests.FakeExecutor([
            "kv namespace list": .init(exitCode: 0, output: "[]"),
            "kv namespace create news_room-cms-session": .init(exitCode: 0, output: #"{"id":"kv-new"}"#),
            "secret list --format json": .init(exitCode: 0, output: #"[{"name":"EMDASH_ENCRYPTION_KEY"}]"#),
        ])
        let target = EmDashDeployTarget(
            cloudflareTarget: CloudflareDeployTarget(tokenSource: { "tok" }), siteName: "news_room",
            encryptionKeySource: { _ in
                Issue.record("a connected install keeps its own key")
                return "k"
            },
            secretRunner: { _, _, _, _, _ in .init(stdout: "", stderr: "", exitCode: 0) })
        let context = DeployTargetContext(
            siteID: "news", siteDirectory: source, configDirectory: config, currentRoutes: [], credential: "tok",
            baseEnvironment: [:], executor: executor, onDomainAttach: nil, onMarkdownForAgents: nil, onProgress: nil)
        #expect(await target.prepare(context: context) == nil)
        #expect(executor.steps == ["kv namespace list", "kv namespace create news_room-cms-session", "secret list --format json"])

        let toml = try #require(WranglerConfigFile.read(configDirectory: config))
        #expect(toml.contains(#"name = "news_room""#))
        #expect(toml.contains(#"database_id = "db-news""#))
        #expect(toml.contains(#"bucket_name = "news-media""#))
        #expect(toml.contains(#"id = "kv-new""#))
        #expect(toml.contains("[[worker_loaders]]\nbinding = \"LOADER\""))
    }

    @Test("a provisioned site's Worker config has no Worker Loader")
    func noLoaderByDefault() throws {
        let toml = try EmDashWorkerConfig.toml(workerName: "news", resources: .init(
            d1DatabaseName: "news-cms", d1DatabaseID: "db1", mediaBucketName: "news-cms-media", sessionKVNamespaceID: "kv1"))
        #expect(!toml.contains("worker_loaders"))
    }
}
