// Lives in the portable target (not AnglesiteCoreTests, beside the other SiteImport rung suites)
// because the rung, its parser and its API client are pure Foundation and this is the only
// AnglesiteCore test target the Linux CI leg executes — the same reasoning as EmDashNewSiteTests
// (#2050). The backup fixture mirrors EmDash 1.0.1's real table dump: system columns per its
// collection DDL, JSON-typed columns as strings, `content_taxonomies` keyed by translation
// group, media by storage key, and `options` values JSON-encoded.
import Foundation
import Testing
@testable import AnglesiteCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("EmDash import rung (#2051)")
struct EmDashRungTests {
    private static let siteURL = "https://blog.example/"

    private static func fixtureData(_ name: String, _ ext: String = "json") throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/EmDash"))
        return try Data(contentsOf: url)
    }

    private static func export() throws -> EmDashExport {
        try EmDashSnapshotDocument.parse(try fixtureData("emdash-backup"))
    }

    private static func items() throws -> (items: [ImportItem], problems: [ImportProblem]) {
        EmDashRung.items(from: try export(), siteURL: siteURL)
    }

    private static func item(_ sourceURL: String) throws -> ImportItem {
        try #require(try items().items.first { $0.sourceURL == sourceURL }, "no item for \(sourceURL)")
    }

    private static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmDashRungTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Parsing the dump

    @Test("the backup dump parses into collections, fields in order, entries, terms, media and settings")
    func parsesBackup() throws {
        let export = try Self.export()
        #expect(export.collections.map(\.slug) == ["articles", "notes", "pages", "recipes"]) // admin sort_order
        let articles = try #require(export.collections.first)
        #expect(articles.fields.map(\.slug) == ["title", "summary", "image", "content"]) // field sort_order
        #expect(articles.fields.map(\.type) == ["string", "text", "image", "portableText"])
        #expect(articles.fields.first?.required == true)
        #expect(articles.urlPattern == "/articles/{slug}")
        #expect(articles.titleField == "title")

        #expect(export.entries.count == 8)
        let a1 = try #require(export.entries.first { $0.id == "a1" })
        #expect(a1.slug == "hello-world")
        #expect(a1.status == "published")
        #expect(a1.trashed == false)
        #expect(a1.translationGroup == "tg-a1")
        #expect(a1.data["title"] == .string("Hello, world"))
        #expect(a1.data["content"]?.arrayValue?.count == 4) // the JSON column was decoded
        #expect(a1.data["image"]?.objectValue?["id"] == .string("m1"))
        #expect(a1.data["status"] == nil) // system columns never leak into data
        #expect(try #require(export.entries.first { $0.id == "a4" }).trashed)

        #expect(export.terms.map(\.label) == ["Swift", "Travel", "Thai"])
        #expect(export.termAssignments.count == 5)
        #expect(export.media.map(\.storageKey) == ["2026/09/sunrise.jpg", "2026/09/dog.jpg"])
        #expect(export.siteTitle == "Ada's Notebook")
        #expect(export.siteTagline == "Notes from the engine room")
        #expect(export.siteLocale == "en")
    }

    @Test("the snapshot API's envelope and a bare tables object parse the same way")
    func parsesEnvelopes() throws {
        let tables = #"{"_emdash_collections":[{"id":"c","slug":"notes","label":"Notes"}],"ec_notes":[{"id":"n","slug":"n","status":"published","content":"[]"}]}"#
        let bare = try EmDashSnapshotDocument.parse(Data(#"{"schema":{},"tables":\#(tables)}"#.utf8))
        let enveloped = try EmDashSnapshotDocument.parse(Data(#"{"success":true,"data":{"schema":{},"tables":\#(tables)}}"#.utf8))
        #expect(bare == enveloped)
        #expect(bare.collections.map(\.slug) == ["notes"])
        #expect(bare.entries.map(\.id) == ["n"])
    }

    @Test("something that isn't an EmDash dump is refused with a reason")
    func refusesNonDumps() {
        #expect(throws: EmDashSnapshotError.invalidJSON) { try EmDashSnapshotDocument.parse(Data("<html>".utf8)) }
        #expect(throws: EmDashSnapshotError.notASnapshot) { try EmDashSnapshotDocument.parse(Data(#"{"posts":[]}"#.utf8)) }
        #expect(throws: EmDashSnapshotError.apiError(code: "FORBIDDEN", message: "no")) {
            try EmDashSnapshotDocument.parse(Data(#"{"success":false,"error":{"code":"FORBIDDEN","message":"no"}}"#.utf8))
        }
    }

    @Test("the fixture's articles collection is the template seed's")
    func fixtureTracksTemplateSeed() throws {
        // Resources/Template/emdash/seed/seed.json declares the collection every new EmDash site
        // starts with; the fixture must keep its field slugs and types, or the rung is being
        // tested against a shape no Anglesite-made site has.
        let seedURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Template/emdash/seed/seed.json")
        let seed = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: seedURL)) as? [String: Any])
        let seedArticles = try #require((seed["collections"] as? [[String: Any]])?.first { $0["slug"] as? String == "articles" })
        let seedFields = try #require(seedArticles["fields"] as? [[String: Any]]).map {
            EmDashExport.Field(slug: $0["slug"] as? String ?? "", label: $0["label"] as? String ?? "",
                               type: $0["type"] as? String ?? "", required: $0["required"] as? Bool ?? false)
        }
        let fixtureArticles = try #require(try Self.export().collections.first { $0.slug == "articles" })
        #expect(fixtureArticles.fields == seedFields)
        #expect(fixtureArticles.urlPattern == seedArticles["urlPattern"] as? String)
    }

    // MARK: Mapping entries

    @Test("published articles become article items with title, date, excerpt, hero image, tags and body")
    func mapsArticles() throws {
        let hello = try Self.item("https://blog.example/articles/hello-world")
        #expect(hello.rung == .emdash)
        #expect(hello.hint == .article)
        #expect(hello.title == "Hello, world")
        #expect(hello.excerpt == "Where it starts.")
        #expect(hello.lang == "en")
        #expect(hello.published == EmDashRung.parseDate("2026-09-20T10:15:00.000Z"))
        #expect(hello.tags == ["Swift", "Travel"]) // via translation groups; the dangling term is ignored
        #expect(hello.images == [
            "https://blog.example/_emdash/api/media/file/2026/09/sunrise.jpg", // hero: `src` injected by the snapshot
            "https://blog.example/_emdash/api/media/file/2026/09/dog.jpg", // body: `_ref` → media table → storage key
        ])
        #expect(hello.markdown == """
        ![Sunrise](https://blog.example/_emdash/api/media/file/2026/09/sunrise.jpg)

        ## Welcome

        This is **the start** of something, see [the docs](https://example.com/).

        ![A dog](https://blog.example/_emdash/api/media/file/2026/09/dog.jpg)
        *Rex.*

        ```json emdash-block=callout
        {
          "_key" : "co",
          "_type" : "callout",
          "children" : [
            {
              "_key" : "co1",
              "_type" : "span",
              "marks" : [

              ],
              "text" : "Mind the gap"
            }
          ],
          "tone" : "warning"
        }
        ```
        """)

        let second = try Self.item("https://blog.example/articles/second-post")
        #expect(second.excerpt == nil)
        #expect(second.published == EmDashRung.parseDate("2026-09-21 08:00:00")) // SQLite timestamp form
        #expect(second.tags == ["Swift"]) // assigned by plain id, not translation group
        #expect(second.images == ["https://blog.example/_emdash/api/media/file/2026/09/dog.jpg"]) // hero via meta.storageKey
        #expect(second.markdown == "![A dog](https://blog.example/_emdash/api/media/file/2026/09/dog.jpg)\n\nShort and sweet.")
    }

    @Test("drafts and trashed entries are skipped; an empty entry is a problem, not an item")
    func filtersEntries() throws {
        let (items, problems) = try Self.items()
        let urls = Set(items.map(\.sourceURL))
        #expect(!urls.contains("https://blog.example/articles/work-in-progress"))
        #expect(!urls.contains("https://blog.example/articles/old-news"))
        #expect(!urls.contains("https://blog.example/articles/empty"))
        #expect(problems.contains { $0.sourceURL == "https://blog.example/articles/empty" && $0.message.contains("no content") })
    }

    @Test("notes and pages map to note and page hints")
    func mapsNotesAndPages() throws {
        let note = try Self.item("https://blog.example/notes/quick-one")
        #expect(note.hint == .note)
        #expect(note.title == nil)
        #expect(note.markdown == "Just a quick note.")

        let about = try Self.item("https://blog.example/about")
        #expect(about.hint == .page)
        #expect(about.title == "About")
        #expect(about.markdown == "All about this site.")
    }

    @Test("a custom collection is brought over as articles, with its extra fields kept in the body")
    func mapsCustomCollection() throws {
        let (_, problems) = try Self.items()
        let recipe = try Self.item("https://blog.example/kitchen/pad-thai")
        #expect(recipe.hint == .article)
        #expect(recipe.title == "Pad Thai")
        #expect(recipe.tags == ["Thai"])
        #expect(recipe.published == EmDashRung.parseDate("2026-09-27T19:00:00.000Z")) // no published_at → date_field
        #expect(recipe.markdown == """
        1. Soak the noodles.
        2. Stir-fry everything.

        ## Ingredients

        Rice noodles
        Tamarind
        Peanuts

        ```json emdash-field=nutrition
        {
          "kcal" : 540,
          "protein" : "18g"
        }
        ```

        - **Servings:** 4
        - **Spicy:** yes
        - **Cuisine:** thai
        - **Diet:** vegetarian, gluten-free
        - **Cooked on:** 2026-09-27T19:00:00.000Z
        """)
        #expect(problems.contains {
            $0.sourceURL == "https://blog.example/kitchen/" && $0.message.contains("“Recipes” has no Anglesite equivalent")
        })
        #expect(problems.contains {
            $0.sourceURL == "https://blog.example/kitchen/pad-thai" && $0.message == "Kept as code for review: field “Nutrition”"
        })
    }

    @Test("an entry with unknown block types is flagged by what was kept as code")
    func flagsUnknownBlocks() throws {
        let (_, problems) = try Self.items()
        #expect(problems.contains {
            $0.sourceURL == "https://blog.example/articles/hello-world" && $0.message == "Kept as code for review: blocks of kind callout"
        })
    }

    @Test("response collections take their target URL from a url-shaped field")
    func mapsResponseTypes() {
        let bookmarks = EmDashExport.Collection(slug: "bookmarks", label: "Bookmarks", urlPattern: "/bookmarks/{slug}", fields: [
            EmDashExport.Field(slug: "url", label: "URL", type: "url"),
            EmDashExport.Field(slug: "content", label: "Content", type: "portableText"),
        ])
        let photos = EmDashExport.Collection(slug: "photos", label: "Photos", fields: [
            EmDashExport.Field(slug: "photo", label: "Photo", type: "image"),
            EmDashExport.Field(slug: "caption", label: "Caption", type: "text"),
        ])
        let paragraph: JSONValue = .array([.object([
            "_type": .string("block"), "_key": .string("p"),
            "children": .array([.object(["_type": .string("span"), "_key": .string("s"), "text": .string("Nice."), "marks": .array([])])]),
        ])])
        let export = EmDashExport(collections: [bookmarks, photos], entries: [
            EmDashExport.Entry(collection: "bookmarks", id: "b1", slug: "nice", status: "published",
                               data: ["url": .string("https://example.com/nice"), "content": paragraph]),
            EmDashExport.Entry(collection: "photos", id: "ph1", slug: "sunset", status: "published",
                               data: ["photo": .string("https://cdn.example.com/sunset.jpg"), "caption": .string("Dusk.")]),
            EmDashExport.Entry(collection: "photos", id: "ph2", slug: "nothing", status: "published", data: [:]),
        ])
        let (items, problems) = EmDashRung.items(from: export, siteURL: "https://blog.example")
        #expect(problems.map(\.sourceURL) == ["https://blog.example/photos/nothing"])
        #expect(items.count == 2)
        #expect(items[0].hint == .bookmark(of: "https://example.com/nice"))
        #expect(items[0].sourceURL == "https://blog.example/bookmarks/nice")
        #expect(items[1].hint == .photo(image: "https://cdn.example.com/sunset.jpg"))
        #expect(items[1].sourceURL == "https://blog.example/photos/sunset") // no urlPattern → /<collection>/<slug>
        #expect(items[1].excerpt == "Dusk.") // the `photos` collection's `caption:` frontmatter comes from the excerpt
        #expect(items[1].markdown == "") // and the photo's image rides in its hint, not the body
    }

    @Test("embedded HTML blocks are converted through the injected converter, once per distinct block")
    func convertsHTMLBlocks() async throws {
        final class Converter: ImportHTMLConverter, @unchecked Sendable {
            var calls: [String] = []
            func convert(html: String) async -> (markdown: String, images: [String]) {
                calls.append(html)
                return (html == "<b>x</b>" ? "**x**" : "", [])
            }
        }
        let html: (String) -> JSONValue = { .object(["_type": .string("htmlBlock"), "_key": .string("h"), "html": .string($0)]) }
        let export = EmDashExport(
            collections: [EmDashExport.Collection(slug: "notes", label: "Notes", fields: [EmDashExport.Field(slug: "content", label: "Content", type: "portableText")])],
            entries: [
                EmDashExport.Entry(collection: "notes", id: "1", slug: "one", status: "published", data: ["content": .array([html("<b>x</b>"), html("<i>raw</i>")])]),
                EmDashExport.Entry(collection: "notes", id: "2", slug: "two", status: "published", data: ["content": .array([html("<b>x</b>")])]),
                EmDashExport.Entry(collection: "notes", id: "3", slug: "draft", status: "draft", data: ["content": .array([html("<s>draft</s>")])]),
            ])
        #expect(EmDashRung.htmlBlocks(in: export) == ["<b>x</b>", "<i>raw</i>"])
        let converter = Converter()
        let (items, _) = await EmDashRung.items(from: export, siteURL: "https://blog.example", convert: converter)
        #expect(converter.calls == ["<b>x</b>", "<i>raw</i>"])
        #expect(items.map(\.markdown) == ["**x**\n\n<i>raw</i>", "**x**"]) // an empty conversion leaves the HTML
    }

    @Test("the site's title and tagline seed .site-config through a stand-in homepage")
    func homepageSeeds() throws {
        let homepage = try #require(EmDashRung.homepage(from: try Self.export(), siteURL: Self.siteURL))
        let seeds = ImportSiteConfig.seeds(fromHomepage: homepage)
        #expect(seeds.siteName == "Ada's Notebook")
        #expect(seeds.tagline == "Notes from the engine room")
        #expect(seeds.lang == "en")
        #expect(EmDashRung.homepage(from: EmDashExport(collections: [], entries: []), siteURL: Self.siteURL) == nil)
    }

    @Test("timestamps parse in every form EmDash writes")
    func parsesDates() {
        #expect(EmDashRung.parseDate("2026-09-20T10:15:00Z") == Date(timeIntervalSince1970: 1_789_899_300))
        #expect(EmDashRung.parseDate("2026-09-20T10:15:00.250Z") == Date(timeIntervalSince1970: 1_789_899_300.25))
        #expect(EmDashRung.parseDate("2026-09-20 10:15:00") == Date(timeIntervalSince1970: 1_789_899_300))
        #expect(EmDashRung.parseDate("2026-09-20") == Date(timeIntervalSince1970: 1_789_862_400))
        #expect(EmDashRung.parseDate("") == nil)
        #expect(EmDashRung.parseDate("yesterday") == nil)
        #expect(EmDashRung.parseDate(nil) == nil)
    }

    // MARK: Downstream pipeline

    @Test("the items classify, emit and redirect like any other rung's")
    func runsThroughTheTransform() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("Source", isDirectory: true)
        let config = dir.appendingPathComponent("Config", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)

        let export = try Self.export()
        let (items, problems) = EmDashRung.items(from: export, siteURL: Self.siteURL)
        let resolved = ResolvedContent(items: items, homepage: EmDashRung.homepage(from: export, siteURL: Self.siteURL),
                                       skippedURLs: [], problems: problems)
        let report = try ImportTransform.run(
            resolved: resolved, assets: [], assetsDirectory: dir, sourceDirectory: source, configDirectory: config,
            now: Date(timeIntervalSince1970: 1_700_000_000), onStep: { _ in })

        #expect(Set(report.writtenPaths) == [
            "src/content/blog/hello-world.md", "src/content/blog/second-post.md", "src/content/blog/pad-thai.md",
            "src/content/notes/quick-one.md", "src/pages/about.md",
        ])
        #expect(report.plan.counts == ["blog": 3, "notes": 1, "pages": 1])
        #expect(report.plan.rungBreakdown == ["emdash": 5])
        #expect(report.redirects.contains(RedirectEntry(source: "/articles/hello-world/", destination: "/blog/hello-world/", code: 301)))
        #expect(report.redirects.contains(RedirectEntry(source: "/kitchen/pad-thai/", destination: "/blog/pad-thai/", code: 301)))
        #expect(!report.redirects.contains { $0.source == "/notes/quick-one/" }) // same path on both sides
        #expect(!report.redirects.contains { $0.source == "/about/" })

        let hello = try String(contentsOf: source.appendingPathComponent("src/content/blog/hello-world.md"), encoding: .utf8)
        #expect(hello.hasPrefix("---\ntitle: \"Hello, world\"\npubDate: 2026-09-20\ndescription: \"Where it starts.\"\nlang: \"en\"\ndraft: false\n---\n\n![Sunrise](https://blog.example/_emdash/api/media/file/2026/09/sunrise.jpg)\n\n## Welcome"))
        let siteConfig = try String(contentsOf: source.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(siteConfig.contains("Ada's Notebook"))

        // With no captured assets, every image is reported rather than silently left remote.
        #expect(report.writeProblems.contains { $0.sourceURL == "https://blog.example/_emdash/api/media/file/2026/09/sunrise.jpg" })
        let summary = ImportSummaryModel(plan: report.plan)
        #expect(summary.countLines == ["3 blog posts", "1 page", "1 note", "3 images"])
        #expect(summary.attentionLine == "4 pages couldn't be brought over cleanly")
    }

    @Test("a crawled snapshot carrying the EmDash probe resolves through the rung, ahead of WordPress")
    func resolverPrefersEmDash() throws {
        let json = String(decoding: try Self.fixtureData("emdash-backup"), as: UTF8.self)
        let wpPosts = """
        [{"link":"https://blog.example/articles/hello-world/","date_gmt":"2026-09-20T10:15:00",
          "title":{"rendered":"Hello from WP"},"content":{"rendered":"<p>wp</p>"},"excerpt":{"rendered":""}}]
        """
        let snapshot = ImportSnapshot(
            siteURL: Self.siteURL,
            probes: SiteProbes(wpPostsJSON: wpPosts, emdashSnapshotJSON: json),
            pages: [CapturedPage(url: Self.siteURL, extraction: ExtractionRecord(title: "Ada's Notebook", markdown: "home"))],
            assets: [], conversions: [ImportSnapshot.htmlKey("<p>wp</p>"): "wp"])
        let resolved = ImportSourceResolver.resolve(snapshot)
        let hello = try #require(resolved.items.first { $0.sourceURL == "https://blog.example/articles/hello-world" })
        #expect(hello.rung == .emdash)
        #expect(hello.title == "Hello, world")
        #expect(resolved.items.filter { $0.rung == .emdash }.count == 5)
        #expect(resolved.homepage?.extraction.title == "Ada's Notebook")

        let broken = ImportSnapshot(siteURL: Self.siteURL, probes: SiteProbes(emdashSnapshotJSON: "{\"nope\":1}"),
                                    pages: [], assets: [], conversions: [:])
        let brokenResolved = ImportSourceResolver.resolve(broken)
        #expect(brokenResolved.items.isEmpty)
        #expect(brokenResolved.problems.map(\.message) == ["Unreadable EmDash content export"])

        // A snapshot captured before the probe existed decodes with it absent.
        let legacy = try JSONDecoder().decode(SiteProbes.self, from: Data(#"{"feeds":[]}"#.utf8))
        #expect(legacy.emdashSnapshotJSON == nil)
    }

    // MARK: Content API

    private final class FakeHTTP: EmDashHTTPClient, @unchecked Sendable {
        var requests: [URLRequest] = []
        var status = 200
        var body = Data()

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (body, response)
        }
    }

    @Test("the content API reads the snapshot endpoint with a Bearer token")
    func fetchesSnapshot() async throws {
        let http = FakeHTTP()
        http.body = try Self.fixtureData("emdash-backup")
        let api = EmDashContentAPI(client: http)
        let export = try await api.fetchExport(siteURL: "https://blog.example/some/page?x=1", token: "tok-123")
        #expect(export.collections.count == 4)
        let request = try #require(http.requests.first)
        #expect(request.url?.absoluteString == "https://blog.example/_emdash/api/snapshot")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok-123")
    }

    @Test("the content API turns auth and not-found answers into named errors")
    func reportsHTTPErrors() async throws {
        let http = FakeHTTP()
        let api = EmDashContentAPI(client: http)
        http.status = 401
        await #expect(throws: EmDashContentAPIError.unauthorized) { try await api.fetchSnapshot(siteURL: "https://blog.example", token: "t") }
        http.status = 403
        await #expect(throws: EmDashContentAPIError.unauthorized) { try await api.fetchSnapshot(siteURL: "https://blog.example", token: "t") }
        http.status = 404
        await #expect(throws: EmDashContentAPIError.notEmDash) { try await api.fetchSnapshot(siteURL: "https://blog.example", token: "t") }
        http.status = 503
        await #expect(throws: EmDashContentAPIError.httpStatus(503)) { try await api.fetchSnapshot(siteURL: "https://blog.example", token: "t") }
        http.status = 200
        http.body = Data(#"{"success":false,"error":{"code":"FORBIDDEN","message":"needs schema:read"}}"#.utf8)
        await #expect(throws: EmDashSnapshotError.apiError(code: "FORBIDDEN", message: "needs schema:read")) {
            try await api.fetchExport(siteURL: "https://blog.example", token: "t")
        }
    }

    @Test("only http(s) site URLs with a host are accepted")
    func validatesSiteURL() throws {
        #expect(try EmDashContentAPI.snapshotURL(siteURL: " HTTPS://Blog.Example:8443/x/ ").absoluteString
                == "https://Blog.Example:8443/_emdash/api/snapshot")
        #expect(throws: EmDashContentAPIError.invalidSiteURL("blog.example")) { try EmDashContentAPI.snapshotURL(siteURL: "blog.example") }
        #expect(throws: EmDashContentAPIError.invalidSiteURL("file:///etc/passwd")) { try EmDashContentAPI.snapshotURL(siteURL: "file:///etc/passwd") }
        #expect(throws: EmDashContentAPIError.invalidSiteURL("")) { try EmDashContentAPI.snapshotURL(siteURL: "") }
    }
}
