// Tests/AnglesiteCoreTests/ContentScannerTests.swift
import Testing
import Foundation
import AnglesiteTestSupport
@testable import AnglesiteCore

/// Native port of `server/list-content.mjs` — scans a site's `Source/` directory into a
/// `ContentListing`, replacing the `list_content` MCP round-trip. Pins behavior to the Node tool.
@Suite("ContentScanner")
struct ContentScannerTests {

    private let siteID = "site-1"

    @Test("pages: route derivation, dynamic-route + non-page skips")
    func pages() {
        let root = try! writeSiteTree(prefix: "content-scan", [
            "src/pages/index.astro": "<h1>Home</h1>",
            "src/pages/about.astro": "<h1>About</h1>",
            "src/pages/blog/index.astro": "<h1>Blog</h1>",
            "src/pages/blog/[slug].astro": "<h1>dynamic</h1>",   // dynamic → skipped
            "src/pages/styles.css": "body{}",                     // non-page ext → skipped
        ])
        let pages = ContentScanner.scan(projectRoot: root, siteID: siteID).pages
        let routes = Set(pages.map(\.route))
        #expect(routes == ["/", "/about", "/blog"])
        #expect(pages.allSatisfy { $0.siteID == siteID })
        let about = pages.first { $0.route == "/about" }
        #expect(about?.id == "site-1:page:/about")
        #expect(about?.filePath == "src/pages/about.astro")
    }

    @Test("page title: frontmatter title, then title= prop, else nil")
    func pageTitles() {
        let root = try! writeSiteTree(prefix: "content-scan", [
            "src/pages/fm.md": "---\ntitle: From Frontmatter\n---\nbody",
            "src/pages/prop.astro": "---\nimport L from '../layouts/Base.astro';\n---\n<L title=\"From Prop\">x</L>",
            "src/pages/none.astro": "<h1>no title</h1>",
        ])
        let pages = ContentScanner.scan(projectRoot: root, siteID: siteID).pages
        func title(_ route: String) -> String?? { pages.first { $0.route == route }?.title }
        #expect(title("/fm") == "From Frontmatter")
        #expect(title("/prop") == "From Prop")
        #expect(title("/none") == .some(nil))
    }

    @Test("posts: article collections only, fields derived from frontmatter")
    func posts() {
        let root = try! writeSiteTree(prefix: "content-scan", [
            "src/content/posts/hello-world.md": "---\ntitle: Hello World\npublishDate: 2026-06-01\ndraft: false\ntags: [intro, news]\n---\nBody",
            "src/content/notes/2026-06-05-quick.md": "---\nslug: quick-note\npublishDate: 2026-06-05\ndraft: false\n---\njust a note",
            "src/content/gallery/photo.md": "---\ntitle: Not A Post\n---\nx",  // non-article collection → ignored
        ])
        let posts = ContentScanner.scan(projectRoot: root, siteID: siteID).posts
        #expect(posts.count == 2)

        let hello = posts.first { $0.collection == "posts" }
        #expect(hello?.slug == "hello-world")
        #expect(hello?.title == "Hello World")
        #expect(hello?.draft == false)
        #expect(hello?.tags == ["intro", "news"])
        #expect(hello?.id == "site-1:post:hello-world")
        // publishDate 2026-06-01 → UTC midnight, matching `new Date("2026-06-01").toISOString()`.
        #expect(hello?.publishDate == ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z"))

        let note = posts.first { $0.collection == "notes" }
        #expect(note?.slug == "quick-note")     // slug from frontmatter
        #expect(note?.title == "quick-note")    // title falls back to slug
    }

    @Test("post date also reads the template blog collection's `pubDate` key (#1716)")
    func postPubDate() {
        let root = try! writeSiteTree(prefix: "content-scan", [
            "src/content/blog/welcome.md": "---\ntitle: Welcome\npubDate: 2026-01-01\n---\nBody",
        ])
        let posts = ContentScanner.scan(projectRoot: root, siteID: siteID).posts
        #expect(posts.first?.collection == "blog")
        #expect(posts.first?.publishDate == ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z"))
    }

    @Test("post slug falls back to filename when frontmatter omits it")
    func postSlugFallback() {
        let root = try! writeSiteTree(prefix: "content-scan", [
            "src/content/posts/my-file.mdx": "---\ntitle: T\n---\nx",
        ])
        let posts = ContentScanner.scan(projectRoot: root, siteID: siteID).posts
        #expect(posts.first?.slug == "my-file")
    }

    @Test("images: public/images scanned with byte size, non-images skipped")
    func images() {
        let root = try! writeSiteTree(prefix: "content-scan", [
            "public/images/hero.png": "PNGDATA",
            "public/images/nested/logo.svg": "<svg/>",
            "public/images/readme.txt": "notes",   // non-image → skipped
        ])
        let images = ContentScanner.scan(projectRoot: root, siteID: siteID).images
        #expect(images.count == 2)
        let hero = images.first { $0.fileName == "hero.png" }
        #expect(hero?.relativePath == "public/images/hero.png")
        #expect(hero?.id == "site-1:image:public/images/hero.png")
        #expect(hero?.byteSize == 7)               // "PNGDATA"
        #expect(hero?.usedOnPages == [])
    }

    @Test("images: usedOnPages is populated from real references, not left empty")
    func usedOnPagesPopulatedFromReferences() {
        let root = try! writeSiteTree(prefix: "content-scan", [
            "public/images/hero.png": "PNGDATA",
            "public/images/orphan.png": "PNGDATA",
            "src/pages/index.astro": #"<img src="/images/hero.png" />"#,
        ])
        let images = ContentScanner.scan(projectRoot: root, siteID: siteID).images
        let hero = images.first { $0.fileName == "hero.png" }
        let orphan = images.first { $0.fileName == "orphan.png" }
        #expect(hero?.usedOnPages == ["src/pages/index.astro"])
        #expect(orphan?.usedOnPages == [])
    }

    @Test("missing directories yield empty lists, not errors")
    func emptySite() {
        let root = try! writeSiteTree(prefix: "content-scan", ["README.md": "nothing here"])
        let listing = ContentScanner.scan(projectRoot: root, siteID: siteID)
        #expect(listing.pages.isEmpty)
        #expect(listing.posts.isEmpty)
        #expect(listing.images.isEmpty)
    }

    // MARK: - HTML entity decoding in title attribute (Fix 2)

    @Test("page title: title= attribute HTML entities are decoded")
    func pageTitleAttrEntityDecoding() {
        // Writer emits: title="Tom &amp; &quot;X&quot;"  for original title: Tom & "X"
        let root = try! writeSiteTree(prefix: "content-scan", [
            "src/pages/test.astro": "<Layout title=\"Tom &amp; &quot;X&quot;\" />"
        ])
        let pages = ContentScanner.scan(projectRoot: root, siteID: siteID).pages
        #expect(pages.first?.title == "Tom & \"X\"")
    }

    @Test("page title: all five emitted entities decode correctly")
    func pageTitleAttrAllEntities() {
        // &amp; &lt; &gt; &quot; &#39;
        let root = try! writeSiteTree(prefix: "content-scan", [
            "src/pages/ent.astro": "<L title=\"a&amp;b&lt;c&gt;d&quot;e&#39;f\" />"
        ])
        let pages = ContentScanner.scan(projectRoot: root, siteID: siteID).pages
        #expect(pages.first?.title == "a&b<c>d\"e'f")
    }

    @Test("page title: &amp;lt; decodes to &lt; not < (amp decoded last)")
    func pageTitleAttrAmpLast() {
        // If &amp; is decoded first, &amp;lt; would become &lt; then < — wrong.
        // Correct: &amp;lt; → &lt; (only one decode pass, amp last).
        let root = try! writeSiteTree(prefix: "content-scan", [
            "src/pages/amp.astro": "<L title=\"&amp;lt;\" />"
        ])
        let pages = ContentScanner.scan(projectRoot: root, siteID: siteID).pages
        #expect(pages.first?.title == "&lt;")
    }

    @Test("round-trip: single-quoted .astro title with special chars survives rewrite → scan")
    func astroSingleQuoteRoundTrip() {
        // PageTitleEditor.attrEscaped (writer) must be symmetric with decodeHTMLEntities (reader),
        // including the single-quote delimiter branch (&#39;).
        let original = "Ben & Jerry's <Best> 'Picks'"
        let written = PageTitleEditor.rewrite(
            contents: "<Layout title='Old' />", fileExtension: "astro", newTitle: original)
        guard case let .success(content) = written else {
            Issue.record("rewrite failed: \(written)"); return
        }
        let root = try! writeSiteTree(prefix: "content-scan", ["src/pages/rt.astro": content])
        let pages = ContentScanner.scan(projectRoot: root, siteID: siteID).pages
        #expect(pages.first?.title == original)
    }
}
