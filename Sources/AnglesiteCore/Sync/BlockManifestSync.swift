import Foundation

/// Keeps a site's `blocks.manifest.json` — and the component files it points at — up to date with
/// the app's shipped effect components. New sites get both copied in wholesale by the scaffold
/// script; this covers sites created before an effect existed. Never touches an entry (or a file)
/// it didn't write itself — an owner is free to hand-edit or remove any entry, and a later sync
/// leaves that alone, only filling in what's genuinely missing. This is a plain JSON merge plus a
/// file copy, not sidecar code: `blocks.manifest.json` is a project-root data file the sidecar only
/// *reads*.
public enum BlockManifestSync {
    public enum SyncError: Error {
        case invalidTemplateManifest
        case corruptSiteManifest
    }

    /// What one ``sync(templateBlocksManifest:siteBlocksManifest:)`` call actually did — returned
    /// rather than logged from in here so the caller (which owns the app's log surface) decides how
    /// to report it.
    public struct Outcome: Equatable, Sendable {
        /// Manifest entries appended to the site's file.
        public var addedPaths: [String] = []
        /// Component files copied from the template into the site.
        public var copiedComponentPaths: [String] = []
        /// Entries deliberately left unregistered because their component file couldn't be made to
        /// exist in the site — a dangling manifest entry would make the sidecar write an `import`
        /// of a file that isn't there, breaking the owner's Astro build.
        public var skippedMissingComponentPaths: [String] = []
        /// Whether the site's manifest file was rewritten at all.
        public var didWriteManifest = false
    }

    /// Merges `templateBlocksManifest`'s `modules` into `siteBlocksManifest`, creating the site
    /// file if absent, appending only entries whose `path` isn't already present, and copying each
    /// appended entry's component file in from the template when the site doesn't have one.
    ///
    /// The manifest files sit at the root of the template and the site's `Source/` respectively, so
    /// their parent directories are the two roots component paths resolve against.
    ///
    /// If the site manifest exists but is invalid or malformed, throws `.corruptSiteManifest`
    /// rather than silently overwriting the owner's file. Writes nothing at all when the merge
    /// added no entries — this file is git-tracked in the owner's `Source/` tree, and rewriting it
    /// on every site open would show up as a spurious dirty file for any owner whose JSON
    /// formatting or key order differs from the canonical serialization.
    @discardableResult
    public static func sync(templateBlocksManifest: URL, siteBlocksManifest: URL) throws -> Outcome {
        let templateData = try Data(contentsOf: templateBlocksManifest)
        guard let templateManifest = try JSONSerialization.jsonObject(with: templateData) as? [String: Any],
              let templateModules = templateManifest["modules"] as? [[String: Any]] else {
            throw SyncError.invalidTemplateManifest
        }

        var siteManifest: [String: Any]
        var siteModules: [[String: Any]]

        let siteFileExists = FileManager.default.fileExists(atPath: siteBlocksManifest.path)
        if siteFileExists {
            // Site file exists; it must be valid or we error rather than overwrite
            guard let siteData = try? Data(contentsOf: siteBlocksManifest) else {
                throw SyncError.corruptSiteManifest
            }
            guard let decoded = try? JSONSerialization.jsonObject(with: siteData) as? [String: Any],
                  let modules = decoded["modules"] as? [[String: Any]] else {
                throw SyncError.corruptSiteManifest
            }
            siteManifest = decoded
            siteModules = modules
        } else {
            // Site file doesn't exist; build fresh from template schema
            siteManifest = ["schemaVersion": "anglesite-block-manifest/1", "modules": [[String: Any]]()]
            siteModules = []
        }

        let templateRoot = templateBlocksManifest.deletingLastPathComponent()
        let siteRoot = siteBlocksManifest.deletingLastPathComponent()
        var outcome = Outcome()

        let existingPaths = Set(siteModules.compactMap { $0["path"] as? String })
        for entry in templateModules {
            guard let path = entry["path"] as? String, !existingPaths.contains(path) else { continue }
            switch ensureComponentFile(relativePath: path, templateRoot: templateRoot, siteRoot: siteRoot) {
            case .alreadyPresent:
                break
            case .copied:
                outcome.copiedComponentPaths.append(path)
            case .unavailable:
                // Defensive backstop: registering a block whose file doesn't exist would have the
                // sidecar emit `import X from "…/X.astro"` for a missing file on the owner's page.
                outcome.skippedMissingComponentPaths.append(path)
                continue
            }
            siteModules.append(entry)
            outcome.addedPaths.append(path)
        }

        guard !outcome.addedPaths.isEmpty else { return outcome }

        siteManifest["modules"] = siteModules
        let output = try JSONSerialization.data(withJSONObject: siteManifest, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: siteBlocksManifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try output.write(to: siteBlocksManifest, options: .atomic)
        outcome.didWriteManifest = true
        return outcome
    }

    private enum ComponentFileResult {
        case alreadyPresent
        case copied
        case unavailable
    }

    /// Copies `relativePath` from the template into the site when the site doesn't already have it.
    /// Never overwrites: a file already at the destination is the owner's (possibly edited) copy
    /// and always wins — the same discipline `IntegrationScaffolder` applies to every owner-editable
    /// file it writes. Returns `.unavailable` when the template has no such file or the copy fails,
    /// so the caller can leave the entry unregistered rather than dangling.
    private static func ensureComponentFile(relativePath: String, templateRoot: URL, siteRoot: URL) -> ComponentFileResult {
        let fileManager = FileManager.default
        let destination = siteRoot.appendingPathComponent(relativePath)
        if fileManager.fileExists(atPath: destination.path) { return .alreadyPresent }
        let source = templateRoot.appendingPathComponent(relativePath)
        guard fileManager.fileExists(atPath: source.path) else { return .unavailable }
        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: destination)
            return .copied
        } catch {
            return .unavailable
        }
    }
}
