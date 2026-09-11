import Testing
import Foundation
import AnglesiteTestSupport
@testable import AnglesiteCore

@Suite("Personal type render smoke")
struct PersonalTypeRenderSmokeTests {

    /// Repo-root-relative path to the committed template. `swift test` runs with CWD = package root.
    static var templateDir: URL { get throws { try templateRoot() } }

    /// True when the template can actually be built: a Node binary plus an installed Astro.
    static var buildable: Bool { ((try? templateDir).map { E2EPrerequisites.astroBuildable(templateDir: $0) }) ?? false }

    @Test("seeded personal types build and render their mf2 classes",
          .enabled(if: PersonalTypeRenderSmokeTests.buildable))
    func rendersMicroformats() async throws {
        let node = try #require(E2EPrerequisites.locateNode())
        let dist = try Self.templateDir.appendingPathComponent("dist", isDirectory: true)

        func html(_ rel: String) throws -> String {
            try String(contentsOf: dist.appendingPathComponent(rel), encoding: .utf8)
        }

        // Hold the shared template-build lock across the build *and* the assertions: other
        // render-smoke suites (e.g. FeedsRenderSmokeTests) `rm -rf dist` around their own build,
        // so a concurrent build/read would race against this one on the shared template tree.
        try await TemplateBuildSerializer.shared.serialize {
            try? FileManager.default.removeItem(at: dist)
            defer { try? FileManager.default.removeItem(at: dist) }

            let result = try await ProcessSupervisor.shared.run(
                source: "test",
                executable: node,
                arguments: [E2EPrerequisites.astroCLIRelativePath, "build"],
                currentDirectoryURL: Self.templateDir)
            try #require(result.exitCode == 0, "astro build failed: \(result.stdout)\n\(result.stderr)")

            let noteHTML = try html("notes/hello-note/index.html")
            #expect(noteHTML.contains("h-entry"))
            #expect(noteHTML.contains("dt-published"))
            #expect(try html("articles/hello-article/index.html").contains("p-name"))
            #expect(try html("photos/hello-photo/index.html").contains("u-photo"))
            #expect(try html("albums/hello-album/index.html").contains("u-photo"))
            #expect(try html("bookmarks/hello-bookmark/index.html").contains("u-bookmark-of"))
            #expect(try html("replies/hello-reply/index.html").contains("u-in-reply-to"))
            #expect(try html("likes/hello-like/index.html").contains("u-like-of"))
        }
    }
}
