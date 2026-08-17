import Foundation

/// One entry in the share-extension-visible site manifest — the trimmed subset of
/// `SiteStore.Site` a share extension needs to list sites and resolve folder access (#1450).
public struct SharedSite: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let bookmarkData: Data
    public let lastSeen: Date

    public init(id: String, name: String, bookmarkData: Data, lastSeen: Date) {
        self.id = id
        self.name = name
        self.bookmarkData = bookmarkData
        self.lastSeen = lastSeen
    }
}

/// Publishes/reads the share-extension site manifest, a single JSON file in the App Group
/// container. The main app calls `publish` whenever `SiteStore` persists; the share extension —
/// a separate sandboxed process with no visibility into the main app's own container — calls
/// `read` to list sites and resolve a chosen site's bookmark.
///
/// Deliberately dumb: no actor, no caching — every operation is a single file read/write against
/// an injected directory URL, so tests exercise it against a plain temp directory with no App
/// Group entitlement required.
public enum SharedSiteRegistry {
    private static let manifestFilename = "shared-sites.json"

    /// Best-effort publish, most-recently-seen first (mirrors `SiteStore`'s own MRU order, so the
    /// extension's default site pick matches the app's). Never throws: a write failure (e.g. the
    /// App Group container is unavailable, as on every ad-hoc Debug build with no real Team) just
    /// means the extension has nothing to list, not a broken app.
    public static func publish(_ sites: [SharedSite], to directory: URL, fileManager: FileManager = .default) {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let sorted = sites.sorted { $0.lastSeen > $1.lastSeen }
            let data = try encoder.encode(sorted)
            try data.write(to: directory.appendingPathComponent(manifestFilename), options: [.atomic])
        } catch {
            // Best-effort (#1450, mirrors LinkPostImageCapture's rule): sharing is a bonus
            // feature, never a reason to fail whatever bookmark mutation triggered this publish.
        }
    }

    /// Reads the manifest. Empty array (never throws) when the file is absent or unreadable — the
    /// extension shows "no sites" rather than crashing when the app hasn't published yet, or the
    /// App Group isn't provisioned.
    public static func read(from directory: URL, fileManager: FileManager = .default) -> [SharedSite] {
        let url = directory.appendingPathComponent(manifestFilename)
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? decoder.decode([SharedSite].self, from: data)) ?? []
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
