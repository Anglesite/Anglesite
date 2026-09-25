import Testing
import Foundation
import AnglesiteTestSupport
@testable import AnglesiteCore

@Suite("Draft content render smoke")
struct DraftContentRenderSmokeTests {

    static var templateDir: URL { get throws { try templateRoot() } }

    static var buildable: Bool { ((try? templateDir).map { E2EPrerequisites.astroBuildable(templateDir: $0) }) ?? false }

    /// One temporary draft entry per draft-bearing collection, with distinguishable slugs/titles
    /// so a leak into `dist/` is unambiguous. `blog` uses `pubDate`; every post-family type uses
    /// `publishDate` — both accept the same ISO8601 literal.
    private static let draftFixtures: [(collection: String, slug: String, frontmatter: String)] = [
        ("blog", "draft-smoke-blog", "title: \"Draft Smoke Blog\"\npubDate: 2026-01-01T00:00:00.000Z\ndraft: true"),
        ("notes", "draft-smoke-note", "publishDate: 2026-01-01T00:00:00.000Z\ndraft: true"),
        ("articles", "draft-smoke-article", "title: \"Draft Smoke Article\"\npublishDate: 2026-01-01T00:00:00.000Z\ndraft: true"),
        ("photos", "draft-smoke-photo", "image: \"/images/hello.svg\"\npublishDate: 2026-01-01T00:00:00.000Z\ndraft: true"),
        ("albums", "draft-smoke-album", "title: \"Draft Smoke Album\"\nimages: [\"/images/one.jpg\"]\npublishDate: 2026-01-01T00:00:00.000Z\ndraft: true"),
        ("bookmarks", "draft-smoke-bookmark", "bookmarkOf: \"https://example.com/\"\npublishDate: 2026-01-01T00:00:00.000Z\ndraft: true"),
        ("replies", "draft-smoke-reply", "inReplyTo: \"https://example.com/post\"\npublishDate: 2026-01-01T00:00:00.000Z\ndraft: true"),
        ("likes", "draft-smoke-like", "likeOf: \"https://example.com/liked\"\npublishDate: 2026-01-01T00:00:00.000Z\ndraft: true"),
    ]

    @Test("a draft entry in every collection emits no dist/ page and no feed entry",
          .enabled(if: DraftContentRenderSmokeTests.buildable))
    func draftsNeverBuild() async throws {
        let node = try #require(E2EPrerequisites.locateNode())
        let dist = try Self.templateDir.appendingPathComponent("dist", isDirectory: true)
        let fm = FileManager.default

        var writtenFiles: [URL] = []
        for fixture in Self.draftFixtures {
            let dir = try Self.templateDir.appendingPathComponent("src/content/\(fixture.collection)", isDirectory: true)
            let file = dir.appendingPathComponent("\(fixture.slug).md")
            let contents = "---\n\(fixture.frontmatter)\n---\n\nDraft smoke fixture; must not build.\n"
            try contents.write(to: file, atomically: true, encoding: .utf8)
            writtenFiles.append(file)
        }
        defer { for file in writtenFiles { try? fm.removeItem(at: file) } }

        try await TemplateBuildSerializer.shared.serialize {
            try? fm.removeItem(at: dist)
            defer { try? fm.removeItem(at: dist) }

            let result = try await ProcessSupervisor.shared.run(
                source: "test",
                executable: node,
                arguments: [E2EPrerequisites.astroCLIRelativePath, "build"],
                currentDirectoryURL: Self.templateDir)
            try #require(result.exitCode == 0, "astro build failed: \(result.stdout)\n\(result.stderr)")

            for fixture in Self.draftFixtures {
                let pagePath = fixture.collection == "blog"
                    ? "blog/\(fixture.slug)/index.html"
                    : "\(fixture.collection)/\(fixture.slug)/index.html"
                #expect(!fm.fileExists(atPath: dist.appendingPathComponent(pagePath).path),
                        "\(fixture.collection): draft entry leaked into \(pagePath)")

                let feedPath = "\(fixture.collection)/feed.json"
                let feedJSON = try String(contentsOf: dist.appendingPathComponent(feedPath), encoding: .utf8)
                #expect(!feedJSON.contains(fixture.slug), "\(fixture.collection): draft slug leaked into \(feedPath)")
            }

            let blogIndex = try String(
                contentsOf: dist.appendingPathComponent("blog/index.html"), encoding: .utf8)
            #expect(!blogIndex.contains("Draft Smoke Blog"), "draft blog post leaked into the /blog/ index")

            let combinedFeed = try String(
                contentsOf: dist.appendingPathComponent("feed.json"), encoding: .utf8)
            for fixture in Self.draftFixtures {
                #expect(!combinedFeed.contains(fixture.slug), "\(fixture.slug) leaked into the combined feed")
            }
        }
    }
}
