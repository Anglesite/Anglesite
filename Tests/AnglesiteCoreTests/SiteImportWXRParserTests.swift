import Foundation
import Testing
@testable import AnglesiteCore

@Suite struct SiteImportWXRParserTests {
    private static let sample = """
    <?xml version="1.0" encoding="UTF-8" ?>
    <rss version="2.0"
      xmlns:excerpt="http://wordpress.org/export/1.1/excerpt/"
      xmlns:content="http://purl.org/rss/1.0/modules/content/"
      xmlns:wp="http://wordpress.org/export/1.2/">
    <channel>
      <title>Sample &amp; Blog</title>
      <link>https://example.com</link>
      <item>
        <title>Hello &amp; Welcome</title>
        <link>https://example.com/2024/05/01/hello/</link>
        <content:encoded><![CDATA[<p>Hello <em>world</em></p>]]></content:encoded>
        <excerpt:encoded><![CDATA[<p>Hello</p>]]></excerpt:encoded>
        <wp:post_date_gmt>2024-05-01 10:00:00</wp:post_date_gmt>
        <pubDate>Wed, 01 May 2024 10:00:00 +0000</pubDate>
        <wp:status>publish</wp:status>
        <wp:post_type>post</wp:post_type>
      </item>
      <item>
        <title>About</title>
        <link>https://example.com/about/</link>
        <content:encoded><![CDATA[<p>About us.</p>]]></content:encoded>
        <excerpt:encoded><![CDATA[]]></excerpt:encoded>
        <wp:post_date_gmt>0000-00-00 00:00:00</wp:post_date_gmt>
        <pubDate>Thu, 02 May 2024 00:00:00 +0000</pubDate>
        <wp:status>publish</wp:status>
        <wp:post_type>page</wp:post_type>
      </item>
      <item>
        <title>A draft</title>
        <link>https://example.com/?p=99</link>
        <content:encoded><![CDATA[<p>Not ready.</p>]]></content:encoded>
        <excerpt:encoded><![CDATA[]]></excerpt:encoded>
        <wp:post_date_gmt>0000-00-00 00:00:00</wp:post_date_gmt>
        <pubDate>Thu, 02 May 2024 00:00:00 +0000</pubDate>
        <wp:status>draft</wp:status>
        <wp:post_type>post</wp:post_type>
      </item>
      <item>
        <title>cat.jpg</title>
        <link>https://example.com/cat-jpg/</link>
        <content:encoded><![CDATA[]]></content:encoded>
        <excerpt:encoded><![CDATA[]]></excerpt:encoded>
        <wp:post_date_gmt>0000-00-00 00:00:00</wp:post_date_gmt>
        <pubDate>Thu, 02 May 2024 00:00:00 +0000</pubDate>
        <wp:status>inherit</wp:status>
        <wp:post_type>attachment</wp:post_type>
      </item>
    </channel>
    </rss>
    """

    @Test func parsesChannelHeader() throws {
        let result = try WXRParser.parse(Data(Self.sample.utf8))
        #expect(result.channel.link == "https://example.com")
    }

    /// The channel title becomes the imported site's display name and package directory name
    /// (`SiteActions.candidateSiteName`), so it must be HTML-entity-decoded exactly like item
    /// titles already are — asymmetric decoding here would leave a literal `&amp;` in a new
    /// site's name (#1636 final review, Minor #6).
    @Test func channelTitleIsHTMLEntityDecoded() throws {
        let result = try WXRParser.parse(Data(Self.sample.utf8))
        #expect(result.channel.title == "Sample & Blog")
    }

    @Test func parsesEveryItemRegardlessOfTypeOrStatus() throws {
        let result = try WXRParser.parse(Data(Self.sample.utf8))
        #expect(result.entries.count == 4)
    }

    @Test func decodesCDATAWrappedContentAndExcerpt() throws {
        let result = try WXRParser.parse(Data(Self.sample.utf8))
        let hello = try #require(result.entries.first { $0.link.hasSuffix("/hello/") })
        #expect(hello.contentEncoded == "<p>Hello <em>world</em></p>")
        #expect(hello.excerptEncoded == "<p>Hello</p>")
        #expect(hello.title == "Hello & Welcome")
        #expect(hello.postType == "post")
        #expect(hello.status == "publish")
    }

    @Test func emptyExcerptBecomesNil() throws {
        let result = try WXRParser.parse(Data(Self.sample.utf8))
        let about = try #require(result.entries.first { $0.link.hasSuffix("/about/") })
        #expect(about.excerptEncoded == nil)
    }

    @Test func prefersPostDateGMTOverPubDate() throws {
        let result = try WXRParser.parse(Data(Self.sample.utf8))
        let hello = try #require(result.entries.first { $0.link.hasSuffix("/hello/") })
        let expected = DateComponents(
            calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"),
            year: 2024, month: 5, day: 1, hour: 10, minute: 0, second: 0
        ).date!
        #expect(hello.published == expected)
    }

    @Test func fallsBackToPubDateWhenGMTIsTheNeverPublishedSentinel() throws {
        let result = try WXRParser.parse(Data(Self.sample.utf8))
        let about = try #require(result.entries.first { $0.link.hasSuffix("/about/") })
        let expected = DateComponents(
            calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"),
            year: 2024, month: 5, day: 2, hour: 0, minute: 0, second: 0
        ).date!
        #expect(about.published == expected)
    }

    @Test func draftAndAttachmentEntriesStillParse() throws {
        // WXRParser is pure structural decoding — filtering by status/post_type is WXRRung's job
        // (Task 2), so drafts and attachments still come through here.
        let result = try WXRParser.parse(Data(Self.sample.utf8))
        #expect(result.entries.contains { $0.status == "draft" })
        #expect(result.entries.contains { $0.postType == "attachment" })
    }

    @Test func malformedXMLThrows() {
        #expect(throws: WXRParseError.self) {
            try WXRParser.parse(Data("<rss><channel><item>".utf8))
        }
    }

    @Test func nonWXRXMLThrows() {
        #expect(throws: WXRParseError.self) {
            try WXRParser.parse(Data("<html><body>Not a feed</body></html>".utf8))
        }
    }
}
