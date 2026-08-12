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
