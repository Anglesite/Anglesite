import Testing
import Foundation
@testable import AnglesiteCore

/// Pins the route → page-source-path mapping every click-to-place caller depends on (#768 final
/// review, Finding 1): the sidecar rejects a route (`/`) outright, so this resolution is what
/// stands between a placement and `invalid-input: not a project-relative .astro path: /`.
@Suite struct PageSourcePathTests {
    private static func page(route: String, filePath: String) -> SiteContentGraph.Page {
        SiteContentGraph.Page(
            id: "s:page:\(route)", siteID: "s", route: route, filePath: filePath,
            title: nil, lastModified: .distantPast)
    }

    @Test func rootRouteResolvesToTheHomePageSource() {
        #expect(PageSourcePath.resolve(route: "/", pages: []) == "src/pages/index.astro")
        #expect(PageSourcePath.resolve(route: nil, pages: []) == "src/pages/index.astro")
    }

    @Test func prefersTheScannedPageForTheRoute() {
        let pages = [Self.page(route: "/blog", filePath: "src/pages/blog/index.astro")]
        // The naming convention alone would guess `src/pages/blog.astro`; the graph knows better.
        #expect(PageSourcePath.resolve(route: "/blog", pages: pages) == "src/pages/blog/index.astro")
    }

    @Test func fallsBackToTheAstroNamingConvention() {
        #expect(PageSourcePath.resolve(route: "/about", pages: []) == "src/pages/about.astro")
    }

    @Test func normalizesTrailingSlashQueryAndFragment() {
        let pages = [Self.page(route: "/about", filePath: "src/pages/about.astro")]
        #expect(PageSourcePath.resolve(route: "/about/", pages: pages) == "src/pages/about.astro")
        #expect(PageSourcePath.resolve(route: "/about?x=1", pages: pages) == "src/pages/about.astro")
        #expect(PageSourcePath.resolve(route: "/about#top", pages: pages) == "src/pages/about.astro")
    }

    @Test func skipsNonAstroPagesRatherThanHandingTheSidecarAPathItRejects() {
        let pages = [Self.page(route: "/about", filePath: "src/pages/about.md")]
        let resolved = PageSourcePath.resolve(route: "/about", pages: pages)
        #expect(resolved == "src/pages/about.astro")
        #expect(PageSourcePath.isValidPageSourcePath(resolved))
    }

    @Test func everyResolutionSatisfiesTheSidecarsPathContract() {
        for route in ["/", "", "/about", "/blog/", "/deep/nested/page", "//", "/x?y=1"] {
            let resolved = PageSourcePath.resolve(route: route, pages: [])
            #expect(PageSourcePath.isValidPageSourcePath(resolved), "route \(route) → \(resolved)")
        }
    }

    @Test func routesAreNotValidPageSourcePaths() {
        #expect(!PageSourcePath.isValidPageSourcePath("/"))
        #expect(!PageSourcePath.isValidPageSourcePath("/about"))
        #expect(!PageSourcePath.isValidPageSourcePath("src/pages/about.md"))
        #expect(PageSourcePath.isValidPageSourcePath("src/pages/about.astro"))
    }
}
