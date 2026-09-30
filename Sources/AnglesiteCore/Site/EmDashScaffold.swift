import Foundation
import AnglesiteSiteModel

/// Scaffold adjustments for a new EmDash site (#2050).
///
/// An EmDash site's articles and media are canonical in EmDash and never copied into `Source/`
/// (`docs/specs/2026-09-28-external-cms-content-source-decision.md`, decision 2), and the site
/// is server-rendered against EmDash (decision 4). So a new EmDash site gets the template with
/// its starter entries removed and the template's EmDash overlay (`Resources/Template/emdash/`)
/// applied on top.
public enum EmDashScaffold {
    /// The overlay's directory inside the template. `scripts/scaffold.sh` leaves it out, so an
    /// Anglesite site never gets it.
    public static let overlayDirectoryName = "emdash"

    /// What the template's `astro.config.ts` is renamed to on an EmDash site. The overlay's own
    /// `astro.config.ts` imports it and adds server rendering and EmDash.
    public static let templateConfigFileName = "astro.anglesite.config.ts"

    /// Overlay entries that describe the overlay itself, or are local build state, and never
    /// enter a site.
    static let overlaySkippedNames: Set<String> = ["README.md", "node_modules", "dist", ".astro", ".wrangler", ".DS_Store"]

    /// Errors from ``applyTemplateOverlay(templateURL:siteDirectory:fileManager:)``.
    public enum OverlayError: Error, Sendable, Equatable {
        /// The template has no `emdash/` overlay. The associated value is the path checked.
        case overlayNotFound(String)
        /// The scaffolded site has no `astro.config.ts` for the overlay's config to build on.
        case templateConfigMissing(String)
    }

    /// Where the overlay lives in a template.
    public static func overlayURL(templateURL: URL) -> URL {
        templateURL.appendingPathComponent(overlayDirectoryName, isDirectory: true)
    }

    /// The directory whose `package.json` is a site's dependency baseline and sync target: the
    /// overlay's for an EmDash site, the template's own for every other kind. An EmDash site
    /// synced against the plain template would be offered the template's versions of the
    /// packages the overlay moves or pins.
    public static func packageTemplateDirectory(templateURL: URL, kind: AnglesitePackage.SiteKind) -> URL {
        kind == .emdash ? overlayURL(templateURL: templateURL) : templateURL
    }

    /// Applies the EmDash overlay to a freshly scaffolded site: renames the template's
    /// `astro.config.ts` to ``templateConfigFileName``, then copies the overlay over
    /// `siteDirectory` file by file, replacing any file it names and never deleting the site's
    /// other files. The overlay's README and any local build state are skipped.
    public static func applyTemplateOverlay(templateURL: URL, siteDirectory: URL,
                                            fileManager: FileManager = .default) throws {
        let overlay = overlayURL(templateURL: templateURL)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: overlay.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw OverlayError.overlayNotFound(overlay.path)
        }
        let config = siteDirectory.appendingPathComponent("astro.config.ts")
        guard fileManager.fileExists(atPath: config.path) else {
            throw OverlayError.templateConfigMissing(config.path)
        }
        let renamed = siteDirectory.appendingPathComponent(templateConfigFileName)
        if fileManager.fileExists(atPath: renamed.path) { try fileManager.removeItem(at: renamed) }
        try fileManager.moveItem(at: config, to: renamed)
        try copyTree(from: overlay, to: siteDirectory, fileManager: fileManager)
    }

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

    private static func copyTree(from source: URL, to destination: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in try fileManager.contentsOfDirectory(atPath: source.path) where !overlaySkippedNames.contains(name) {
            let src = source.appendingPathComponent(name)
            let dst = destination.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            fileManager.fileExists(atPath: src.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                try copyTree(from: src, to: dst, fileManager: fileManager)
            } else {
                if fileManager.fileExists(atPath: dst.path) { try fileManager.removeItem(at: dst) }
                try fileManager.copyItem(at: src, to: dst)
            }
        }
    }
}
