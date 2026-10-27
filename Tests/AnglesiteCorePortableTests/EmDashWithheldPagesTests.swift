// Portable target: the withheld-pages client and loader are pure Foundation over an injected
// transport, and this is the AnglesiteCore test target the Linux CI leg runs.
import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import AnglesiteCore

@Suite("EmDash withheld pages (#2097)")
struct EmDashWithheldPagesTests {
    /// Records each request's SQL and answers from `respond`.
    final class StubD1: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var statements: [(sql: String, params: [String])] = []
        let respond: @Sendable (String) -> (Int, String)

        init(respond: @escaping @Sendable (String) -> (Int, String)) { self.respond = respond }

        var transport: CloudflareTransport {
            { [self] request in
                let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
                let sql = body?["sql"] as? String ?? ""
                lock.withLock { statements.append((sql, body?["params"] as? [String] ?? [])) }
                let (status, json) = respond(sql)
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                return (Data(json.utf8), response)
            }
        }
    }

    private static let rowsJSON = """
    {"success":true,"errors":[],"result":[{"success":true,"results":[
      {"path":"/articles/leak/","categories":"[\\"exposed-token\\",\\"keystatic-route\\"]","messages":"[]",
       "first_seen":"2026-09-30T18:00:00.000Z","last_seen":"2026-09-30T18:10:00.000Z","count":3},
      {"path":"/articles/fixed/","categories":"[\\"something-new\\"]","messages":"[]",
       "first_seen":"2026-09-29T10:00:00.000Z","last_seen":"2026-09-29T10:00:00.000Z","count":1}
    ]}]}
    """
    private static let okJSON = #"{"success":true,"errors":[],"result":[{"success":true,"results":[]}]}"#

    private static func client(_ stub: StubD1) -> WithheldPagesD1Client {
        WithheldPagesD1Client(accountID: "acct", databaseID: "db1", apiToken: "t", baseURL: "https://cf.test", transport: stub.transport)
    }

    @Test("rows map to owner reasons, deduplicated, and unknown checks read as uncheckable")
    func listsRows() async throws {
        let stub = StubD1 { _ in (200, Self.rowsJSON) }
        let pages = try await Self.client(stub).list()
        #expect(pages.map(\.path) == ["/articles/leak/", "/articles/fixed/"])
        #expect(pages[0].reasons == [.secret, .adminLink])
        #expect(pages[1].reasons == [.uncheckable])
        #expect(pages[0].lastSeen == ISO8601DateFormatter().date(from: "2026-09-30T18:10:00Z"))
        #expect(stub.statements.first?.sql.hasPrefix("SELECT path, categories, first_seen, last_seen FROM anglesite_withheld_pages") == true)
    }

    @Test("a site whose backstop never withheld anything has no table, which reads as no pages")
    func noTableIsEmpty() async throws {
        let stub = StubD1 { _ in (400, #"{"success":false,"errors":[{"code":7500,"message":"no such table: anglesite_withheld_pages: SQLITE_ERROR"}],"result":[]}"#) }
        #expect(try await Self.client(stub).list().isEmpty)
        try await Self.client(stub).clear(path: "/a/")
    }

    @Test("an unauthorized token is an error, not an empty list")
    func unauthorizedThrows() async {
        let stub = StubD1 { _ in (403, "{}") }
        await #expect(throws: CloudflareError.self) { try await Self.client(stub).list() }
    }

    @Test("pages the site serves again are cleared and left out; the rest stay")
    func clearsRecoveredPages() async throws {
        let stub = StubD1 { sql in (200, sql.hasPrefix("SELECT") ? Self.rowsJSON : Self.okJSON) }
        let probed = LockedURLs()
        let pages = await EmDashWithheldPages.load(
            client: Self.client(stub), siteURL: URL(string: "https://news.example")!,
            isServing: { url in probed.append(url); return url.absoluteString.hasSuffix("/articles/fixed/") })
        #expect(pages?.map(\.path) == ["/articles/leak/"])
        #expect(probed.all.map(\.absoluteString).sorted() == ["https://news.example/articles/fixed/", "https://news.example/articles/leak/"])
        let deletes = stub.statements.filter { $0.sql.hasPrefix("DELETE") }
        #expect(deletes.map(\.params) == [["/articles/fixed/"]])
    }

    @Test("a recorded path that would resolve to another host is never probed or cleared")
    func offSitePathsAreNotProbed() async throws {
        let site = URL(string: "https://news.example")!
        #expect(EmDashWithheldPages.probeURL(path: "//evil.example/x", siteURL: site) == nil)
        #expect(EmDashWithheldPages.probeURL(path: "https://evil.example/x", siteURL: site) == nil)
        #expect(EmDashWithheldPages.probeURL(path: "x", siteURL: site) == nil)
        #expect(EmDashWithheldPages.probeURL(path: "/a/b/", siteURL: site)?.absoluteString == "https://news.example/a/b/")

        let rows = #"{"success":true,"errors":[],"result":[{"success":true,"results":[{"path":"//evil.example/x","categories":"[\"exposed-token\"]","messages":"[]","first_seen":"2026-09-30T18:00:00Z","last_seen":"2026-09-30T18:00:00Z","count":1}]}]}"#
        let stub = StubD1 { sql in (200, sql.hasPrefix("SELECT") ? rows : Self.okJSON) }
        let probed = LockedURLs()
        let pages = await EmDashWithheldPages.load(
            client: Self.client(stub), siteURL: site, isServing: { url in probed.append(url); return true })
        #expect(pages?.map(\.path) == ["//evil.example/x"])
        #expect(probed.all.isEmpty)
        #expect(!stub.statements.contains { $0.sql.hasPrefix("DELETE") })
    }

    @Test("a page answering 200, or gone as 404/410, is resolved; a 503 or no answer is not")
    func resolvedStatuses() {
        #expect(EmDashWithheldPages.isResolved(status: 200))
        #expect(EmDashWithheldPages.isResolved(status: 404))
        #expect(EmDashWithheldPages.isResolved(status: 410))
        #expect(!EmDashWithheldPages.isResolved(status: 503))
        #expect(!EmDashWithheldPages.isResolved(status: 500))
        #expect(!EmDashWithheldPages.isResolved(status: nil))
    }

    @Test("a hidden notice comes back for a new page or a new reason, not for the same list")
    func noticeKeyTracksReasons() {
        let adminLink = WithheldPage(path: "/a/", reasons: [.adminLink], firstSeen: nil, lastSeen: nil)
        let secret = WithheldPage(path: "/a/", reasons: [.secret], firstSeen: nil, lastSeen: nil)
        let other = WithheldPage(path: "/b/", reasons: [.adminLink], firstSeen: nil, lastSeen: nil)
        let refreshed = WithheldPage(path: "/a/", reasons: [.adminLink], firstSeen: nil, lastSeen: Date())
        let hidden = EmDashWithheldPages.noticeKey([adminLink])
        #expect(EmDashWithheldPages.noticeKey([refreshed]) == hidden)
        #expect(EmDashWithheldPages.noticeKey([secret]) != hidden)
        #expect(EmDashWithheldPages.noticeKey([adminLink, other]) != hidden)
    }

    @Test("without a known site URL nothing is cleared, and every recorded page is shown")
    func noSiteURLKeepsAll() async {
        let stub = StubD1 { _ in (200, Self.rowsJSON) }
        let pages = await EmDashWithheldPages.load(client: Self.client(stub), siteURL: nil, isServing: { _ in true })
        #expect(pages?.count == 2)
        #expect(!stub.statements.contains { $0.sql.hasPrefix("DELETE") })
    }

    @Test("the site URL comes from .site-config, https only")
    func siteURLFromConfig() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("withheld-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent(".site-config")
        try Data("SITE_URL=https://news.example\n".utf8).write(to: config)
        #expect(EmDashWithheldPages.siteURL(sourceDirectory: dir)?.absoluteString == "https://news.example")
        try Data("SITE_URL=http://news.example\n".utf8).write(to: config)
        #expect(EmDashWithheldPages.siteURL(sourceDirectory: dir) == nil)
    }

    @Test("a site without an EmDash database isn't checked at all")
    func unconfiguredSiteIsNil() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("withheld-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = StubD1 { _ in (200, Self.rowsJSON) }
        let pages = await EmDashWithheldPages.loadIfConfigured(
            sourceDirectory: dir, configDirectory: dir, baseURL: "https://cf.test", transport: stub.transport)
        #expect(pages == nil)
        #expect(stub.statements.isEmpty)
    }

    @Test("settings round-trip the EmDash database id, and older settings decode without it")
    func settingsRoundTrip() throws {
        let settings = SiteSettings(emdashD1DatabaseID: "db1")
        let data = try PropertyListEncoder().encode(settings)
        #expect(try PropertyListDecoder().decode(SiteSettings.self, from: data).emdashD1DatabaseID == "db1")
        let legacy = try PropertyListEncoder().encode(SiteSettings())
        #expect(try PropertyListDecoder().decode(SiteSettings.self, from: legacy).emdashD1DatabaseID == nil)
    }

    final class LockedURLs: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        func append(_ url: URL) { lock.withLock { urls.append(url) } }
        var all: [URL] { lock.withLock { urls } }
    }
}
