import Testing
import Foundation
import AnglesiteTestSupport
@testable import AnglesiteCore

/// V-1.8 (#350): the schema.org JSON-LD twin of the mf2 markup. Builds the committed template and
/// asserts each routed type emits a `<script type="application/ld+json">` with the right `@type`,
/// and that `likes` (an interaction, no rich-result type) emits none.
@Suite("JSON-LD render smoke")
struct JsonLdRenderSmokeTests {

    static var templateDir: URL { get throws { try templateRoot() } }

    /// True when the template can actually be built: a Node binary plus an installed Astro.
    static var buildable: Bool { ((try? templateDir).map { E2EPrerequisites.astroBuildable(templateDir: $0) }) ?? false }

    @Test("seeded types emit schema.org JSON-LD with the expected @type",
          .enabled(if: JsonLdRenderSmokeTests.buildable))
    func emitsJsonLd() async throws {
        let node = try #require(E2EPrerequisites.locateNode())
        let dist = try Self.templateDir.appendingPathComponent("dist", isDirectory: true)

        func html(_ rel: String) throws -> String {
            try String(contentsOf: dist.appendingPathComponent(rel), encoding: .utf8)
        }

        // Hold the shared template-build lock across build + assertions: other render-smoke suites
        // rm -rf dist around their own build and would race on the shared template tree.
        try await TemplateBuildSerializer.shared.serialize {
            try? FileManager.default.removeItem(at: dist)
            defer { try? FileManager.default.removeItem(at: dist) }

            let result = try await ProcessSupervisor.shared.run(
                source: "test",
                executable: node,
                arguments: [E2EPrerequisites.astroCLIRelativePath, "build"],
                currentDirectoryURL: Self.templateDir)
            try #require(result.exitCode == 0, "astro build failed: \(result.stdout)\n\(result.stderr)")

            let ldScript = "application/ld+json"

            let article = try html("articles/hello-article/index.html")
            #expect(article.contains(ldScript))
            #expect(article.contains("\"@type\":\"Article\""))
            // Google requires `author` for the Article/BlogPosting rich result; absent a
            // configured profile.json owner, the projection emits a site-origin Person stub.
            #expect(article.contains("\"author\""))

            let event = try html("events/hello-event/index.html")
            #expect(event.contains("\"@type\":\"Event\""))
            #expect(event.contains("\"startDate\""))

            let review = try html("reviews/hello-review/index.html")
            #expect(review.contains("\"@type\":\"Review\""))
            #expect(review.contains("\"reviewRating\""))

            let blog = try html("blog/welcome-to-your-blog/index.html")
            #expect(blog.contains("\"@type\":\"BlogPosting\""))
            #expect(blog.contains("\"author\""))

            #expect(try html("photos/hello-photo/index.html").contains("\"@type\":\"ImageObject\""))
            #expect(try html("albums/hello-album/index.html").contains("\"@type\":\"ImageGallery\""))
            #expect(try html("notes/hello-note/index.html").contains("\"@type\":\"SocialMediaPosting\""))
            #expect(try html("announcements/hello-announcement/index.html").contains("\"@type\":\"Article\""))

            // Distinct field mappings worth guarding against drift from content.config.ts.
            let bookmark = try html("bookmarks/hello-bookmark/index.html")
            #expect(bookmark.contains("\"@type\":\"WebPage\""))
            #expect(bookmark.contains("\"relatedLink\""))

            let reply = try html("replies/hello-reply/index.html")
            #expect(reply.contains("\"@type\":\"Comment\""))
            #expect(reply.contains("\"about\""))

            // A like is an interaction, not a CreativeWork — it gets no JSON-LD.
            #expect(try !html("likes/hello-like/index.html").contains(ldScript))
        }
    }
}
