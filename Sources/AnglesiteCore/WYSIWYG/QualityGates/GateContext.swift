import Foundation

/// What a quality-gate checker needs beyond the `BlockModel` itself (design doc §3). Constructed by
/// `GateContext.build(fromSourceDirectory:)` (Task 4) and set on `WYSIWYGCanvasController` (Task 10)
/// once per mount.
public struct GateContext: Sendable {
    /// CSS custom-property name (without the `--` prefix) -> value, e.g. "color-text" -> "#222222".
    /// Parsed from the site's `src/styles/global.css` by `ContrastGate.parseCSSCustomProperties`.
    public var resolvedTokens: [String: String]
    /// Site-relative route paths that resolve to a real page, e.g. "/blog/hello-world" — built by
    /// walking `src/pages/**`.
    public var internalRoutes: Set<String>
    /// The site's `public/` directory — where a `src`/`href` prop pointing at a leading-`/` path
    /// resolves to a file on disk.
    public var assetRoot: URL

    public init(resolvedTokens: [String: String], internalRoutes: Set<String>, assetRoot: URL) {
        self.resolvedTokens = resolvedTokens
        self.internalRoutes = internalRoutes
        self.assetRoot = assetRoot
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
        let routes = Self.routes(underPagesDirectory: pagesURL)

        let assetRoot = sourceDirectory.appendingPathComponent("public")
        return GateContext(resolvedTokens: tokens, internalRoutes: routes, assetRoot: assetRoot)
    }

    /// Recursively lists `src/pages/**/*.{astro,md,mdx}` and turns each into the site-relative route
    /// it renders at — Astro's file-based routing convention: strip the extension, and an `index`
    /// file's route is its parent directory. `[collection]`-style dynamic routes (bracketed path
    /// segments) are skipped — resolving them needs the content collection they iterate, not just
    /// the filesystem, so a real page under one would false-positive as "no matching route" against
    /// this gate; the deploy-time backstop already covers dynamic routes.
    private static func routes(underPagesDirectory pagesURL: URL) -> Set<String> {
        guard let enumerator = FileManager.default.enumerator(at: pagesURL, includingPropertiesForKeys: nil) else { return [] }
        var routes: Set<String> = []
        let pageExtensions: Set<String> = ["astro", "md", "mdx"]
        let pagesPath = pagesURL.standardizedFileURL.path
        for case let fileURL as URL in enumerator {
            guard pageExtensions.contains(fileURL.pathExtension) else { continue }
            let filePath = fileURL.standardizedFileURL.path
            guard let relative = filePath.hasPrefix(pagesPath) ? String(filePath.dropFirst(pagesPath.count)) : nil else { continue }
            guard !relative.contains("[") else { continue } // dynamic route — see doc comment
            let ext = fileURL.pathExtension
            var route: String
            if relative.hasSuffix("/index.\(ext)") {
                route = String(relative.dropLast("index.\(ext)".count + 1))
            } else {
                route = String(relative.dropLast(ext.count + 1))
            }
            if route.isEmpty { route = "/" }
            routes.insert(route)
        }
        return routes
    }
}
