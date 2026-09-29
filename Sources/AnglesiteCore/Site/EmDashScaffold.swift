import Foundation

/// Scaffold adjustments for a new EmDash site (#2050).
///
/// An EmDash site's articles and media are canonical in EmDash and never copied into `Source/`
/// (`docs/specs/2026-09-28-external-cms-content-source-decision.md`, decision 2), so the
/// template's starter entries (`src/content/<collection>/hello-*.md` and friends) don't belong in
/// its repo. The collection folders stay, each with a `.gitkeep`, so the template's content
/// config still finds every collection it declares.
public enum EmDashScaffold {
    /// Removes every file under `Source/src/content/<collection>/`, leaving each collection
    /// folder in place with an empty `.gitkeep`. Files directly in `src/content/` and anything
    /// outside it are untouched. A site without `src/content/` is left as is.
    public static func removeStarterContent(siteDirectory: URL, fileManager: FileManager = .default) throws {
        let contentRoot = siteDirectory.appendingPathComponent("src/content", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: contentRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return
        }
        for collection in try fileManager.contentsOfDirectory(at: contentRoot, includingPropertiesForKeys: nil) {
            var collectionIsDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: collection.path, isDirectory: &collectionIsDirectory),
                  collectionIsDirectory.boolValue else { continue }
            for entry in try fileManager.contentsOfDirectory(at: collection, includingPropertiesForKeys: nil) {
                try fileManager.removeItem(at: entry)
            }
            try Data().write(to: collection.appendingPathComponent(".gitkeep"))
        }
    }
}
