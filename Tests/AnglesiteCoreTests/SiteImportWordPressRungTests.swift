import Foundation
import Testing
@testable import AnglesiteCore

@Suite struct SiteImportWordPressRungTests {
    private func makeSnapshot(postsJSON: String, conversions: [String: String] = [:]) -> ImportSnapshot {
        ImportSnapshot(siteURL: "https://example.com",
                       probes: SiteProbes(wpPostsJSON: postsJSON),
                       pages: [], assets: [], conversions: conversions)
    }

    @Test func decodesPostWithConvertedMarkdown() {
        let html = "<p>Hello <em>world</em></p>"
        let posts = """
        [{"link":"https://example.com/2024/05/01/hello/","date_gmt":"2024-05-01T10:00:00",
          "title":{"rendered":"Hello &#8212; again"},
          "content":{"rendered":"\(html.replacingOccurrences(of: "\"", with: "\\\""))"},
          "excerpt":{"rendered":"<p>Hello</p>"}}]
        """
        let snapshot = makeSnapshot(postsJSON: posts,
                                    conversions: [ImportSnapshot.htmlKey(html): "Hello *world*"])
        let result = WordPressRESTRung.items(from: snapshot)
        #expect(result.problems.isEmpty)
        #expect(result.items.count == 1)
        let item = result.items[0]
        #expect(item.title == "Hello — again")
        #expect(item.markdown == "Hello *world*")
        #expect(item.rung == .wpREST)
        #expect(item.hint == .wpPost)
        #expect(item.published != nil)
    }

    /// The REST payload has no image inventory, so an item's `images` — the list
    /// `AssetLocalizer` works from — can only come from the crawled page for the same URL.
    @Test func threadsCrawledPageImages() {
        let html = "<p>See <img src=\\\"https://example.com/cat.jpg\\\"></p>"
        let posts = """
        [{"link":"https://example.com/2024/05/01/hello/","date_gmt":"2024-05-01T10:00:00",
          "title":{"rendered":"Hello"},"content":{"rendered":"\(html)"},
          "excerpt":{"rendered":""}}]
        """
        var snapshot = makeSnapshot(
            postsJSON: posts,
            conversions: [ImportSnapshot.htmlKey("<p>See <img src=\"https://example.com/cat.jpg\"></p>"):
                            "See ![](https://example.com/cat.jpg)"])
        // No crawled page for the post → no images to localize, rather than a wrong guess.
        #expect(WordPressRESTRung.items(from: snapshot).items.first?.images == [])

        snapshot.pages = [CapturedPage(
            url: "https://example.com/2024/05/01/hello/",
            extraction: ExtractionRecord(markdown: "ignored", images: ["https://example.com/cat.jpg"]))]
        let result = WordPressRESTRung.items(from: snapshot)
        #expect(result.items.first?.images == ["https://example.com/cat.jpg"])
        // The REST conversion still wins the body; only the images come from the page.
        #expect(result.items.first?.markdown == "See ![](https://example.com/cat.jpg)")
    }

    @Test func missingConversionFallsBackToCrawledPageThenProblem() {
        let posts = """
        [{"link":"https://example.com/p/","date_gmt":"2024-01-01T00:00:00",
          "title":{"rendered":"P"},"content":{"rendered":"<p>x</p>"},"excerpt":{"rendered":""}}]
        """
        var snapshot = makeSnapshot(postsJSON: posts)
        // No conversion, no page → problem.
        #expect(WordPressRESTRung.items(from: snapshot).problems.count == 1)
        // Crawled page exists → its readability markdown is used.
        snapshot.pages = [CapturedPage(url: "https://example.com/p/",
                                       extraction: ExtractionRecord(markdown: "x from page"))]
        let result = WordPressRESTRung.items(from: snapshot)
        #expect(result.items.first?.markdown == "x from page")
    }

    @Test func wpPagesGetPageHint() {
        var snapshot = makeSnapshot(postsJSON: "[]")
        snapshot.probes.wpPagesJSON = """
        [{"link":"https://example.com/about/","date_gmt":"2024-01-01T00:00:00",
          "title":{"rendered":"About"},"content":{"rendered":"<p>a</p>"},"excerpt":{"rendered":""}}]
        """
        snapshot.conversions = [ImportSnapshot.htmlKey("<p>a</p>"): "a"]
        #expect(WordPressRESTRung.items(from: snapshot).items.first?.hint == .wpPage)
    }

    /// WordPress renders a literal title `5 &lt; 10` as the double-escaped `5 &amp;lt; 10`.
    /// Decoding `&amp;` first (the original, buggy order) would turn that into `5 < 10` — an
    /// entity that was never actually present in the source title. `&amp;` must decode last, as
    /// `ContentScanner.decodeHTMLEntities(_:)` already does.
    @Test func decodeHTMLEntitiesLeavesDoubleEscapedEntitiesIntact() {
        #expect(decodeHTMLEntities("5 &amp;lt; 10") == "5 &lt; 10")
        // Numeric character references (e.g. an em dash) still decode correctly.
        #expect(decodeHTMLEntities("Hello &#8212; again") == "Hello — again")
        // A plain, single-escaped entity still decodes as expected.
        #expect(decodeHTMLEntities("Tom &amp; Jerry") == "Tom & Jerry")
    }
}
