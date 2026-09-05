import Foundation

/// Resolves a live-preview *route* (`/`, `/about`, what `PreviewModel.activeRoute` holds) to the
/// *project-relative page source path* (`src/pages/index.astro`) the sidecar's page tools require.
///
/// This mapping is load-bearing, not cosmetic: `get_page_model`'s `validPagePath`
/// (`server/page-model.mjs`) and `component-structure-edit.mjs`'s own path validation both reject
/// anything that isn't a project-relative path ending in `.astro` — a route like `/` fails
/// immediately with `invalid-input: not a project-relative .astro path: /`. Every caller that
/// feeds ``PageModelClient/fetch(path:)`` or `ComponentStructureEditBuilder.insertBlock`'s
/// `component.path` from a route has to come through here first (#768 final review, Finding 1).
///
/// Resolution order:
///
/// 1. The site's scanned pages (``SiteContentGraph/Page``), matched on `route` — the authoritative
///    answer, since it comes from the actual filesystem walk (`ContentScanner.scanPages`) and
///    handles directory-index pages (`/blog` → `src/pages/blog/index.astro`) that no naming
///    convention can infer.
/// 2. Failing that (graph not populated yet — it fills in asynchronously after a site opens), the
///    Astro naming convention, matching `ContentScaffold.pageRelativePath(normalizedRoute:)`.
///
/// The return value is always a project-relative `.astro` path, never a route: a page that exists
/// only as `.md`/`.mdx` resolves to the conventional `.astro` sibling, which the sidecar then
/// reports as an ordinary read failure. That's deliberate — a structural `insertBlock` has nothing
/// to insert into on a Markdown page, and "couldn't read this page" is a truer answer than
/// "invalid input".
public enum PageSourcePath {
    /// The home page's source path — the fallback target for front doors with no page picker
    /// (Siri's `AddEffectIntent`) and for a preview sitting on the site root.
    public static let homePage = "src/pages/index.astro"

    /// Resolves `route` against `pages`, falling back to the Astro naming convention. `nil` or an
    /// empty route means the site root.
    public static func resolve(route: String?, pages: [SiteContentGraph.Page]) -> String {
        let normalized = normalize(route)
        if let match = pages.first(where: { normalize($0.route) == normalized && isAstro($0.filePath) }) {
            return match.filePath
        }
        return conventionalPath(forNormalizedRoute: normalized)
    }

    /// Whether `path` satisfies the sidecar's project-relative-`.astro` contract. Exposed so
    /// callers (and tests pinning production wiring) can assert it without duplicating the rule.
    public static func isValidPageSourcePath(_ path: String) -> Bool {
        !path.hasPrefix("/") && !path.hasPrefix("../") && isAstro(path)
    }

    /// `/` → `src/pages/index.astro`, `/about` → `src/pages/about.astro`. Expects an already
    /// normalized route.
    static func conventionalPath(forNormalizedRoute route: String) -> String {
        let trimmed = route.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? homePage : "src/pages/\(trimmed).astro"
    }

    /// Leading slash, no trailing slash (except the root), no query or fragment — the shape
    /// `ContentScanner.routeFromPagePath` produces, so graph routes and preview routes compare
    /// equal.
    static func normalize(_ route: String?) -> String {
        guard var value = route, !value.isEmpty else { return "/" }
        if let cut = value.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            value = String(value[value.startIndex..<cut])
        }
        while value.hasSuffix("/"), value.count > 1 { value.removeLast() }
        if !value.hasPrefix("/") { value = "/" + value }
        return value.isEmpty ? "/" : value
    }

    private static func isAstro(_ path: String) -> Bool {
        path.lowercased().hasSuffix(".astro")
    }
}
