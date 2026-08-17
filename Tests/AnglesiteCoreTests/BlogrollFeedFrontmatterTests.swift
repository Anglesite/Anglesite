import Testing
@testable import AnglesiteCore

@Suite("Blogroll feed frontmatter")
struct BlogrollFeedFrontmatterTests {
    @Test("sets feedURL when the key is absent, inside an existing fence")
    func setsWhenAbsent() {
        let contents = """
        ---
        name: Friend's Blog
        url: https://friend.example
        addedDate: 2026-08-01
        ---
        A friend's blog.
        """
        let result = BlogrollFeedFrontmatter.setting(feedURL: "https://friend.example/feed.xml", in: contents)
        #expect(result.contains("feedURL: \"https://friend.example/feed.xml\""))
        #expect(result.contains("name: Friend's Blog"))
        #expect(result.contains("A friend's blog."))
    }

    @Test("synthesizes a fence when the file has none")
    func synthesizesFence() {
        let contents = "No frontmatter here."
        let result = BlogrollFeedFrontmatter.setting(feedURL: "https://x.example/feed.xml", in: contents)
        #expect(result.hasPrefix("---\n"))
        #expect(result.contains("feedURL: \"https://x.example/feed.xml\""))
        #expect(result.contains("No frontmatter here."))
    }

    @Test("is a no-op when feedURL is already set")
    func noopWhenAlreadySet() {
        let contents = """
        ---
        name: Friend's Blog
        url: https://friend.example
        feedURL: https://friend.example/already-set.xml
        addedDate: 2026-08-01
        ---
        Body.
        """
        let result = BlogrollFeedFrontmatter.setting(feedURL: "https://different.example/feed.xml", in: contents)
        #expect(result == contents)
    }

    @Test("replaces a blank feedURL value")
    func replacesBlankValue() {
        let contents = """
        ---
        name: Friend's Blog
        url: https://friend.example
        feedURL:
        addedDate: 2026-08-01
        ---
        Body.
        """
        let result = BlogrollFeedFrontmatter.setting(feedURL: "https://friend.example/feed.xml", in: contents)
        #expect(result.contains("feedURL: \"https://friend.example/feed.xml\""))
        #expect(!result.contains("feedURL:\n"))
    }

    @Test("preserves CRLF line endings")
    func preservesCRLF() {
        let contents = "---\r\nname: Friend\r\nurl: https://friend.example\r\naddedDate: 2026-08-01\r\n---\r\nBody.\r\n"
        let result = BlogrollFeedFrontmatter.setting(feedURL: "https://friend.example/feed.xml", in: contents)
        #expect(result.contains("\r\n"))
        #expect(!result.contains("feedURL: \"https://friend.example/feed.xml\"\n\n"))  // no stray LF introduced
    }
}
