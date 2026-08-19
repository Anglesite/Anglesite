import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteAppCore

/// Pins what the *production* wiring hands `PageModelClient`/`insertBlock` — the gap every other
/// click-to-place test left open by supplying a correct `src/pages/….astro` path by hand
/// (#768 final review, Finding 1). `SiteWindowModel.effectPlacementController` used to pass
/// `preview.activeRoute ?? "/"` straight through, which the sidecar rejects outright with
/// `invalid-input: not a project-relative .astro path: /`.
@Suite("SiteWindowModel effect-placement path")
@MainActor
struct SiteWindowModelEffectPlacementPathTests {
    private func makeModel(contentGraph: SiteContentGraph = SiteContentGraph()) -> SiteWindowModel {
        SiteWindowModel(
            contentGraph: contentGraph,
            knowledgeIndex: SiteKnowledgeIndex(),
            semanticRanker: nil,
            conventionsEngine: ProjectConventionsEngine(),
            runtimeFactory: NeverStartedSiteRuntimeFactory(),
            contentIndexerStore: ContentIndexerStore()
        )
    }

    @Test("targets the home page source with no active route")
    func noRouteTargetsHomePageSource() {
        let path = makeModel().effectPlacementController.path
        #expect(path == "src/pages/index.astro")
        #expect(PageSourcePath.isValidPageSourcePath(path))
    }

    @Test("targets the active route's page source, never the route itself")
    func activeRouteResolvesToAPageSourcePath() {
        let model = makeModel()
        model.preview.navigate(toRoute: "/about")
        let path = model.effectPlacementController.path
        #expect(!path.hasPrefix("/"))
        #expect(path.hasSuffix(".astro"))
        #expect(path == "src/pages/about.astro")
    }

    @Test("prefers the scanned page's real source path over the naming convention")
    func usesTheContentGraphsFilePath() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("effect-placement-path-\(UUID().uuidString)")
        let pagesDir = root.appendingPathComponent("src/pages/blog")
        try FileManager.default.createDirectory(at: pagesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<h1>Blog</h1>".utf8).write(to: pagesDir.appendingPathComponent("index.astro"))

        let model = makeModel()
        await model.refreshContentGraph(siteID: "s1", sourceDirectory: root)
        model.preview.navigate(toRoute: "/blog")

        // The convention alone would guess `src/pages/blog.astro` — a file that doesn't exist.
        #expect(model.effectPlacementController.path == "src/pages/blog/index.astro")
    }
}
