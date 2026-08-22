import Foundation
import Testing
@testable import AnglesiteCore

@Suite struct SiteImportFeedRungTests {
    @Test func parsesRSS2WithContentEncoded() {
        let html = "<p>Full <b>body</b> here</p>"
        let rss = """
        <?xml version="1.0"?><rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/">
        <channel><title>Feed</title><item>
        <title>Post One</title><link>https://example.com/one/</link>
        <pubDate>Wed, 01 May 2024 10:00:00 +0000</pubDate>
        <content:encoded><![CDATA[\(html)]]></content:encoded>
        </item></channel></rss>
        """
        let snapshot = ImportSnapshot(
            siteURL: "https://example.com", probes: SiteProbes(feeds: [CapturedFeed(url: "https://example.com/feed", body: rss)]),
            pages: [], assets: [], conversions: [ImportSnapshot.htmlKey(html): "Full **body** here"])
        let result = FeedRung.items(from: snapshot)
        #expect(result.items.count == 1)
        #expect(result.items[0].title == "Post One")
        #expect(result.items[0].markdown == "Full **body** here")
        #expect(result.items[0].rung == .feed)
        #expect(result.items[0].published != nil)
    }

    @Test func excerptOnlyFeedFallsBackToPageBody() {
        let excerptHTML = "<p>Teaser…</p>"
        let rss = """
        <?xml version="1.0"?><rss version="2.0"><channel><item>
        <title>Long Post</title><link>https://example.com/long/</link>
        <description><![CDATA[\(excerptHTML)]]></description>
        </item></channel></rss>
        """
        let longBody = String(repeating: "A full paragraph of real content. ", count: 20)
        let snapshot = ImportSnapshot(
            siteURL: "https://example.com",
            probes: SiteProbes(feeds: [CapturedFeed(url: "https://example.com/feed", body: rss)]),
            pages: [CapturedPage(url: "https://example.com/long/",
                                 extraction: ExtractionRecord(markdown: longBody))],
            assets: [], conversions: [ImportSnapshot.htmlKey(excerptHTML): "Teaser…"])
        let result = FeedRung.items(from: snapshot)
        #expect(result.items.first?.markdown == longBody)
        #expect(result.items.first?.title == "Long Post")
    }

    @Test func parsesJSONFeed() {
        let html = "<p>json body</p>"
        let feed = """
        {"version":"https://jsonfeed.org/version/1.1","title":"F",
         "items":[{"url":"https://example.com/j/","title":"J",
                   "date_published":"2024-05-01T10:00:00Z","content_html":"\(html.replacingOccurrences(of: "\"", with: "\\\""))"}]}
        """
        let snapshot = ImportSnapshot(
            siteURL: "https://example.com",
            probes: SiteProbes(feeds: [CapturedFeed(url: "https://example.com/feed.json", body: feed)]),
            pages: [], assets: [], conversions: [ImportSnapshot.htmlKey(html): "json body"])
        #expect(FeedRung.items(from: snapshot).items.first?.markdown == "json body")
    }

    @Test func parsesRSS2PubDateWithLiteralZoneName() {
        let html = "<p>GMT body</p>"
        let rss = """
        <?xml version="1.0"?><rss version="2.0"><channel><item>
        <title>GMT Post</title><link>https://example.com/gmt/</link>
        <pubDate>Mon, 01 Jan 2024 00:00:00 GMT</pubDate>
        <description><![CDATA[\(html)]]></description>
        </item></channel></rss>
        """
        let snapshot = ImportSnapshot(
            siteURL: "https://example.com",
            probes: SiteProbes(feeds: [CapturedFeed(url: "https://example.com/feed", body: rss)]),
            pages: [], assets: [], conversions: [ImportSnapshot.htmlKey(html): "GMT body"])
        let result = FeedRung.items(from: snapshot)
        #expect(result.items.first?.published != nil)
    }
}
