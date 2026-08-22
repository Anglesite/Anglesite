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
}
