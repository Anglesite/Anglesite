import Foundation

/// Locates the compiled block-editor engine JS (built by `scripts/build-wysiwyg-engine.sh`) inside
/// an app bundle — the one script injected into every preview and Component Editor canvas since
/// #1957 retired the edit-overlay bundle. Portable: every platform adapter (`WKUserScript` on
/// WKWebView, the WebKitGTK/WebView2 equivalents) wraps this same source string in its own
/// native script-injection type; only the lookup + read is shared here.
public enum AnglesiteWysiwygEngineBundle {
    /// Reads the bundled engine source, or `nil` when the bundle hasn't been produced (e.g.
    /// `swift test`, or a build where the prebuild script was skipped) — non-fatal, callers
    /// should just skip script injection.
    public static func source(in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "engine", withExtension: "js", subdirectory: "wysiwyg-engine")
        else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
