import Foundation
import Testing
import AnglesiteTestSupport
@testable import AnglesiteCore

@Suite("Blogroll plan")
struct BlogrollPlanTests {
    @Test("builds one entry per blogroll file, skipping malformed entries")
    func buildsEntries() throws {
        let root = try writeSiteTree(prefix: "blogroll-plan", [
            "src/content/blogroll/friend.md": """
            ---
            name: Friend's Blog
            url: https://friend.example
            addedDate: 2026-08-01
            ---
            A friend's blog.
            """,
            "src/content/blogroll/with-feed.md": """
            ---
            name: Has A Feed
            url: https://hasafeed.example
            feedURL: https://hasafeed.example/feed.xml
            addedDate: 2026-08-02
            ---
            """,
            "src/content/blogroll/malformed.md": """
            ---
            addedDate: 2026-08-03
            ---
            Missing name and url.
            """,
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let plan = BlogrollPlan.build(projectRoot: root)
        #expect(plan.entries.count == 2)

        let friend = try #require(plan.entries.first { $0.sourceFile.contains("friend.md") })
        #expect(friend.name == "Friend's Blog")
        #expect(friend.url == URL(string: "https://friend.example"))
        #expect(friend.feedURL == nil)

        let withFeed = try #require(plan.entries.first { $0.sourceFile.contains("with-feed.md") })
        #expect(withFeed.feedURL == URL(string: "https://hasafeed.example/feed.xml"))
    }

    @Test("entries are sorted by source file for stable output")
    func sortedOutput() throws {
        let root = try writeSiteTree(prefix: "blogroll-plan", [
            "src/content/blogroll/zzz.md": "---\nname: Z\nurl: https://z.example\naddedDate: 2026-08-01\n---\n",
            "src/content/blogroll/aaa.md": "---\nname: A\nurl: https://a.example\naddedDate: 2026-08-01\n---\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let plan = BlogrollPlan.build(projectRoot: root)
        #expect(plan.entries.map(\.sourceFile).first?.contains("aaa.md") == true)
    }
}
