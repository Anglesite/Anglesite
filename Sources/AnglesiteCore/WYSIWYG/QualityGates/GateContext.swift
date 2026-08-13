import Foundation

/// What a quality-gate checker needs beyond the `BlockModel` itself (design doc §3). Constructed by
/// `GateContext.build(fromSourceDirectory:)` (Task 4) and set on `WYSIWYGCanvasController` (Task 10)
/// once per mount.
public struct GateContext: Sendable {
    /// CSS custom-property name (without the `--` prefix) -> value, e.g. "color-text" -> "#222222".
    /// Parsed from the site's `src/styles/global.css` by `ContrastGate.parseCSSCustomProperties`.
    public var resolvedTokens: [String: String]
    /// Site-relative route paths that resolve to a real page, e.g. "/blog/hello-world" — built by
    /// walking `src/pages/**`. Always in `normalizedRoute(_:)` form (no trailing slash except the
    /// root `/`, no query/fragment), so `LinkIntegrityGate` can compare an equally-normalized href
    /// against them directly.
    public var internalRoutes: Set<String>
    /// The site's `public/` directory — where a `src`/`href` prop pointing at a leading-`/` path
    /// resolves to a file on disk.
    public var assetRoot: URL
    /// First-level directory names under `src/pages/` whose subtree contains a bracketed
    /// (`[slug]`-style) source file — e.g. `"blog"` for `blog/[...slug].astro`, `"tags"` for
    /// `tags/[tag]/index.astro`. Those files generate real pages this gate can't enumerate without
    /// the content collection behind them, so `internalRoutes` never lists them; `LinkIntegrityGate`
    /// uses this set to *skip* (neither flag nor confirm) any href whose first segment falls inside
    /// that generated space, instead of reporting a false 404.
    public var dynamicRouteDirectories: Set<String>

    public init(
        resolvedTokens: [String: String],
        internalRoutes: Set<String>,
        assetRoot: URL,
        dynamicRouteDirectories: Set<String> = []
    ) {
        self.resolvedTokens = resolvedTokens
        self.internalRoutes = internalRoutes
        self.assetRoot = assetRoot
        self.dynamicRouteDirectories = dynamicRouteDirectories
    }
}

extension GateContext {
    /// Builds a `GateContext` by reading straight off `sourceDirectory` (a site's `Source/`, design
    /// doc §3): parses `src/styles/global.css` for design tokens, walks `src/pages/**` for internal
    /// routes, and points `assetRoot` at `public/`. Best-effort — a missing/unreadable `global.css`
    /// yields an empty token set (`ContrastGate` simply has nothing to check) rather than throwing,
    /// since a `GateContext` with partial data is still useful for the other four gates.
    public static func build(fromSourceDirectory sourceDirectory: URL) -> GateContext {
        let cssURL = sourceDirectory.appendingPathComponent("src/styles/global.css")
        let css = (try? String(contentsOf: cssURL, encoding: .utf8)) ?? ""
        let tokens = ContrastGate.parseCSSCustomProperties(from: css)

        let pagesURL = sourceDirectory.appendingPathComponent("src/pages")
        let derived = Self.routes(underPagesDirectory: pagesURL)

        let assetRoot = sourceDirectory.appendingPathComponent("public")
        return GateContext(
            resolvedTokens: tokens,
            internalRoutes: derived.routes,
            assetRoot: assetRoot,
            dynamicRouteDirectories: derived.dynamicDirectories)
    }

    /// Canonical form for a site-relative path, applied to **both** sides of `LinkIntegrityGate`'s
    /// comparison so an authored href and a derived route can never miss each other on punctuation
    /// alone: drops a trailing `?query` and/or `#fragment`, then drops trailing slashes except on
    /// the root `/` itself. `"/blog/"`, `"/blog?page=2"` and `"/blog#recent"` all normalize to
    /// `"/blog"`; `"/"` and `"/#contact"` both stay `"/"`. This is the single place that
    /// normalization lives — the gate calls it rather than re-deriving its own rules.
    public static func normalizedRoute(_ path: String) -> String {
        var value = path
        if let hash = value.firstIndex(of: "#") { value = String(value[value.startIndex..<hash]) }
        if let query = value.firstIndex(of: "?") { value = String(value[value.startIndex..<query]) }
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value.isEmpty ? "/" : value
    }

    /// Recursively lists `src/pages/**/*.{astro,md,mdx,ts}` and turns each into the site-relative
    /// route it renders at — Astro's file-based routing convention: strip the extension, and an
    /// `index` file's route is its parent directory. `.ts` counts because Astro's endpoint routes
    /// are plain TypeScript modules (`rss.xml.ts` renders at `/rss.xml`), and a real page linking
    /// to one would otherwise never find a match.
    ///
    /// Bracketed (`[collection]`/`[...slug]`) *source files* are left out of `routes`: enumerating
    /// the pages they actually generate needs the content collection they iterate, not just the
    /// filesystem. That omission alone is **not** enough to keep the gate honest, though — a link
    /// *to* one of those generated pages (`/blog/my-post`) would still find no matching route and
    /// false-positive as a 404. So each such file also contributes something to `dynamicDirectories`,
    /// and the consumer (`LinkIntegrityGate`) is responsible for skipping any href that lands in that
    /// generated space. The deploy-time backstop still covers dynamic routes properly.
    ///
    /// Two shapes need different handling, and conflating them is a real bug, not just a stripping
    /// detail: a fixed directory holding a bracketed *file* (`blog/[...slug].astro`) has a real,
    /// literal first segment — `"blog"` — that a matching href's first segment can be compared
    /// against directly. A bracketed *directory itself* (`[collection]/[...slug].astro`, this
    /// template's actual shape) has no literal name at all — `collection` is a route *parameter*
    /// standing in for whichever of the site's content collections (`notes`, `articles`, `photos`,
    /// …) the generated page belongs to, so no href's first segment will ever literally read
    /// `"collection"`. Stripping the brackets and storing that placeholder verbatim would silently
    /// never match anything, leaving every link into that space flagged as broken — the skip this
    /// set exists to provide would never actually fire. Recording it as the wildcard sentinel below
    /// instead makes `LinkIntegrityGate` skip *any* multi-segment href once a root-level dynamic
    /// directory is known to exist, which is the honest scope of what the filesystem alone can tell
    /// it: not which collection a link names, only that this template has at least one route whose
    /// first segment is never enumerable without the content collection behind it.
    private static func routes(underPagesDirectory pagesURL: URL) -> (routes: Set<String>, dynamicDirectories: Set<String>) {
        guard let enumerator = FileManager.default.enumerator(at: pagesURL, includingPropertiesForKeys: nil) else { return ([], []) }
        var routes: Set<String> = []
        var dynamicDirectories: Set<String> = []
        let pageExtensions: Set<String> = ["astro", "md", "mdx", "ts"]
        let pagesPath = pagesURL.standardizedFileURL.path
        for case let fileURL as URL in enumerator {
            guard pageExtensions.contains(fileURL.pathExtension) else { continue }
            let filePath = fileURL.standardizedFileURL.path
            guard filePath.hasPrefix(pagesPath) else { continue }
            let relative = String(filePath.dropFirst(pagesPath.count))
            guard !relative.contains("[") else { // dynamic route — see doc comment
                let components = relative.split(separator: "/")
                if let first = components.first, components.count > 1 {
                    dynamicDirectories.insert(first.hasPrefix("[") ? Self.rootLevelDynamicSentinel : String(first))
                }
                continue
            }
            let ext = fileURL.pathExtension
            let route: String
            if relative.hasSuffix("/index.\(ext)") {
                route = String(relative.dropLast("index.\(ext)".count + 1))
            } else {
                route = String(relative.dropLast(ext.count + 1))
            }
            routes.insert(normalizedRoute(route))
        }
        return (routes, dynamicDirectories)
    }

    /// Marks that this site has at least one root-level dynamic route directory (`[collection]`-
    /// style) whose real first path segments the filesystem can't enumerate — see the doc comment on
    /// `routes(underPagesDirectory:)`. Not a real directory name; `LinkIntegrityGate` checks for this
    /// sentinel specifically rather than as a literal href segment.
    static let rootLevelDynamicSentinel = "*"
}
