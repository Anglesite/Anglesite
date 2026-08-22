import Foundation
import Testing
@testable import AnglesiteCore

@Suite struct SiteImportResolverTests {
    @Test func laddersDeduplicatesAndSkipsArchives() {
        let postHTML = "<p>wp</p>"
        let posts = """
        [{"link":"https://example.com/one/","date_gmt":"2024-05-01T10:00:00",
          "title":{"rendered":"One"},"content":{"rendered":"<p>wp</p>"},"excerpt":{"rendered":""}}]
        """
        let rss = """
        <?xml version="1.0"?><rss version="2.0"><channel><item>
        <title>One (from feed)</title><link>https://example.com/one/</link>
        <description><![CDATA[<p>feed</p>]]></description></item></channel></rss>
        """
        let snapshot = ImportSnapshot(
            siteURL: "https://example.com/",
            probes: SiteProbes(wpPostsJSON: posts,
                               feeds: [CapturedFeed(url: "https://example.com/feed", body: rss)]),
            pages: [
                CapturedPage(url: "https://example.com/",
                             extraction: ExtractionRecord(title: "My Site", markdown: "home")),
                CapturedPage(url: "https://example.com/one/",
                             extraction: ExtractionRecord(title: "One", markdown: "wp page")),
                CapturedPage(url: "https://example.com/contact/",
                             extraction: ExtractionRecord(title: "Contact", markdown: "call me")),
                CapturedPage(url: "https://example.com/tag/foo/",
                             extraction: ExtractionRecord(title: "Tag: foo", markdown: "archive")),
            ],
            assets: [],
            conversions: [ImportSnapshot.htmlKey(postHTML): "wp",
                          ImportSnapshot.htmlKey("<p>feed</p>"): "feed"])
        let resolved = ImportSourceResolver.resolve(snapshot)
        #expect(resolved.homepage?.extraction.title == "My Site")
        #expect(resolved.skippedURLs == ["https://example.com/tag/foo/"])
        #expect(resolved.items.count == 2) // "one" (wpREST wins) + "contact" fallback
        let one = resolved.items.first { $0.sourceURL == "https://example.com/one" }
        #expect(one?.rung == .wpREST)
        #expect(one?.markdown == "wp")
        let contact = resolved.items.first { $0.sourceURL == "https://example.com/contact" }
        #expect(contact?.rung == .readability)
    }
}
