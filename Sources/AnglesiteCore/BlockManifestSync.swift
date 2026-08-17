import Foundation

/// Keeps a site's `blocks.manifest.json` up to date with the app's shipped effect components.
/// New sites get the template's manifest copied in wholesale by the scaffold script; this covers
/// sites created before an effect existed. Never touches an entry it didn't write itself — an
/// owner is free to hand-edit or remove any entry, and a later sync leaves that alone, only
/// filling in entries genuinely missing by `path`. This is a plain JSON merge, not sidecar code:
/// `blocks.manifest.json` is a project-root data file the sidecar only *reads*.
public enum BlockManifestSync {
    public enum SyncError: Error {
        case invalidTemplateManifest
    }

    /// Merges `templateBlocksManifest`'s `modules` into `siteBlocksManifest`, creating the site
    /// file if absent, appending only entries whose `path` isn't already present.
    public static func sync(templateBlocksManifest: URL, siteBlocksManifest: URL) throws {
        let templateData = try Data(contentsOf: templateBlocksManifest)
        guard let templateManifest = try JSONSerialization.jsonObject(with: templateData) as? [String: Any],
              let templateModules = templateManifest["modules"] as? [[String: Any]] else {
            throw SyncError.invalidTemplateManifest
        }

        var siteManifest: [String: Any]
        var siteModules: [[String: Any]]
        if let siteData = try? Data(contentsOf: siteBlocksManifest),
           let decoded = try? JSONSerialization.jsonObject(with: siteData) as? [String: Any],
           let modules = decoded["modules"] as? [[String: Any]] {
            siteManifest = decoded
            siteModules = modules
        } else {
            siteManifest = ["schemaVersion": "anglesite-block-manifest/1", "modules": [[String: Any]]()]
            siteModules = []
        }

        let existingPaths = Set(siteModules.compactMap { $0["path"] as? String })
        for entry in templateModules {
            guard let path = entry["path"] as? String, !existingPaths.contains(path) else { continue }
            siteModules.append(entry)
        }
        siteManifest["modules"] = siteModules

        let output = try JSONSerialization.data(withJSONObject: siteManifest, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: siteBlocksManifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try output.write(to: siteBlocksManifest, options: .atomic)
    }
}
