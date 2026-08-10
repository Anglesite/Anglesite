import Foundation

/// Locates the compiled WYSIWYG engine JS (built by `scripts/build-wysiwyg-engine.sh`) inside an
/// app bundle — mirrors `AnglesiteOverlayBundle` exactly for the new engine bundle.
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
