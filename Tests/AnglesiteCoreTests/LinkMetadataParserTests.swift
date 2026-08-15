import Testing
@testable import AnglesiteCore

@Suite("LinkMetadataParser")
struct LinkMetadataParserTests {
    @Test("parses og:title, og:description, og:site_name")
    func parsesOpenGraph() {
        let html = """
        <html><head>
        <meta property="og:title" content="Interesting Thing" />
        <meta property="og:description" content="Why it matters." />
        <meta property="og:site_name" content="Example Blog" />
        <title>Interesting Thing — Example Blog</title>
        </head><body></body></html>
        """
        let meta = LinkMetadataParser.parse(html: html)
        #expect(meta.title == "Interesting Thing")
        #expect(meta.description == "Why it matters.")
        #expect(meta.siteName == "Example Blog")
    }

    @Test("falls back to <title> when og:title is absent")
    func titleFallback() {
        let meta = LinkMetadataParser.parse(html: "<head><title>Plain Page</title></head>")
        #expect(meta.title == "Plain Page")
        #expect(meta.description == nil)
    }

    @Test("attribute order and quote style don't matter; name= works like property=")
    func attributeVariants() {
        let html = """
        <meta content='Reversed' property='og:title'>
        <meta name="og:description" content="Named, not property.">
        """
        let meta = LinkMetadataParser.parse(html: html)
        #expect(meta.title == "Reversed")
        #expect(meta.description == "Named, not property.")
    }

    @Test("decodes HTML entities, named and numeric")
    func entityDecoding() {
        let html = #"<meta property="og:title" content="Q&amp;A: 5 &lt; 6 &#39;quoted&#x2019;">"#
        #expect(LinkMetadataParser.parse(html: html).title == "Q&A: 5 < 6 'quoted\u{2019}")
    }

    @Test("whitespace-trimmed; empty values become nil; garbage input is empty metadata")
    func normalization() {
        #expect(LinkMetadataParser.parse(html: #"<meta property="og:title" content="  ">"#).title == nil)
        #expect(LinkMetadataParser.parse(html: "<title>  Padded  </title>").title == "Padded")
        let binaryish = String(repeating: "\u{0}garbage<>&", count: 100)
        #expect(LinkMetadataParser.parse(html: binaryish) == LinkMetadata())
    }

    @Test("first matching meta wins")
    func firstWins() {
        let html = """
        <meta property="og:title" content="First">
        <meta property="og:title" content="Second">
        """
        #expect(LinkMetadataParser.parse(html: html).title == "First")
    }

    @Test("parses og:image, verbatim (resolution against the page URL is the fetcher's job)")
    func parsesOpenGraphImage() {
        let html = """
        <html><head>
        <meta property="og:title" content="Interesting Thing">
        <meta property="og:image" content="https://cdn.example.com/card.jpg">
        </head></html>
        """
        #expect(LinkMetadataParser.parse(html: html).imageURL == "https://cdn.example.com/card.jpg")
        // Relative values pass through unchanged — the parser has no page URL to resolve against.
        #expect(LinkMetadataParser.parse(html: #"<meta name="og:image" content="/card.png">"#)
            .imageURL == "/card.png")
        // No og:image, and an empty one, both mean "no image" — never a <title>-style fallback.
        #expect(LinkMetadataParser.parse(html: "<head><title>Plain</title></head>").imageURL == nil)
        #expect(LinkMetadataParser.parse(html: #"<meta property="og:image" content="  ">"#).imageURL == nil)
    }
}
