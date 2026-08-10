import AnglesiteSiteModel
import Foundation

/// Pure, platform-neutral mapping from discovered `.anglesite` package URLs to `SiteEntity`
/// values. Deliberately carries **no** discovery of its own and **no** platform gate: callers own
/// resolving the URL list (macOS's `SiteEntityQuery` doesn't use this at all — it stays
/// `SiteStore`-backed; iOS's `SiteEntityQueryIOS` resolves the list via
/// `UbiquityContainerResolving`/`UbiquitousPackageDiscovering` and hands it here). Keeping this
/// logic gate-free is what makes it exercisable by plain `swift test` on the macOS host, unlike
/// the `#if os(iOS)`-gated wrapper that calls it.
enum SiteEntityUbiquitySource {
    /// Reads each URL's package marker and builds a `SiteEntity`. A package whose marker fails to
    /// read (mid-materializing iCloud item, corrupt or missing `Info.plist`) is dropped, not
    /// thrown — matches `SitePickerModel.refresh()`'s existing behavior
    /// (`Sources/AnglesiteIOS/SitePickerModel.swift`).
    static func siteEntities(
        fromPackageURLs urls: [URL], fileManager: FileManager = .default
    ) -> [SiteEntity] {
        urls.compactMap { url in
            let package = AnglesitePackage(url: url)
            guard let marker = try? package.readMarker(fileManager: fileManager) else {
                return nil
            }
            let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey]
            let values = try? package.sourceURL.resourceValues(forKeys: keys)
            return SiteEntity(
                id: marker.siteID.uuidString,
                name: marker.displayName,
                creationDate: values?.creationDate,
                modificationDate: values?.contentModificationDate,
                directory: url
            )
        }
    }

    /// Exact-id resolution — the path Shortcuts uses to re-resolve a previously captured entity.
    /// Unknown ids are silently dropped (deleted/renamed sites), not errors.
    static func entities(
        for identifiers: [String], in urls: [URL], fileManager: FileManager = .default
    ) -> [SiteEntity] {
        siteEntities(fromPackageURLs: urls, fileManager: fileManager)
            .filter { identifiers.contains($0.id) }
    }

    /// Case-insensitive substring match on the site name, for Siri utterances like "my portfolio
    /// site".
    static func entities(
        matching string: String, in urls: [URL], fileManager: FileManager = .default
    ) -> [SiteEntity] {
        let needle = string.lowercased()
        return siteEntities(fromPackageURLs: urls, fileManager: fileManager)
            .filter { $0.name.lowercased().contains(needle) }
    }

    /// The single site when there is exactly one, so Siri can skip the "which site?" prompt
    /// entirely; `nil` (forcing disambiguation) in every other case.
    static func defaultResult(in urls: [URL], fileManager: FileManager = .default) -> SiteEntity? {
        let sites = siteEntities(fromPackageURLs: urls, fileManager: fileManager)
        return sites.count == 1 ? sites.first : nil
    }
}
