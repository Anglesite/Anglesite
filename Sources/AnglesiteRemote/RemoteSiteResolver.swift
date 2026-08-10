import Foundation
import os.log
import AnglesiteCore

/// Errors surfaced when the site can't be resolved.
public enum RemoteSiteResolverError: Error, Equatable {
    /// The user dismissed the open panel without picking a location.
    case userCancelledGrant
    /// A persisted (or freshly created) bookmark could not be resolved to a URL.
    case bookmarkResolutionFailed(String)
}

/// Tiny persisted `[siteID: Data]` bookmark map — the helper's own equivalent of
/// `SiteStore.Site.bookmarkData`, but stored under this bundle's own container, never shared
/// with the main app's `recents.json`. Reads/writes the whole map atomically, matching
/// `RemoteSessionRegistry`'s atomic-write technique (Task 2) — appropriate here because this
/// store is expected to hold a handful of entries (one per site this helper has ever needed a
/// grant for), not a high-write-volume ledger.
public actor RemoteBookmarkStore {
    private let fileURL: URL
    private static let logger = os.Logger(subsystem: "io.dwk.anglesite.remote", category: "RemoteBookmarkStore")

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Returns the persisted bookmark data for `siteID`, or `nil` if none has been stored yet.
    public func bookmarkData(for siteID: String) throws -> Data? {
        try readAll()[siteID]
    }

    /// Persists `data` as the bookmark for `siteID`, replacing any previous entry.
    public func setBookmark(_ data: Data, for siteID: String) throws {
        var all = try readAll()
        all[siteID] = data
        try writeAll(all)
    }

    private func readAll() throws -> [String: Data] {
        do {
            let raw = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode([String: Data].self, from: raw)
        } catch let nsError as NSError where nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError {
            // No store written yet — an empty map, not an error.
            return [:]
        } catch let decodingError as DecodingError {
            Self.logger.error("Failed to decode bookmark store at \(self.fileURL.path)")
            throw decodingError
        }
    }

    private func writeAll(_ map: [String: Data]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(map)
        try data.write(to: fileURL, options: .atomic)
    }
}

/// Resolves a siteID to its `Source/` directory for the helper — independent of `SiteStore`
/// (that type's `recents.json` lives in the MAIN APP's sandbox container, which this helper's
/// distinct bundle ID cannot read without an App Group; see Step 5). Two paths, per design spec
/// §2 "File access": iCloud-stored sites resolve with zero prompts (both bundle IDs carry the
/// same ubiquity-container entitlement); everything else needs a one-time bookmark this resolver
/// mints and persists itself.
public actor RemoteSiteResolver {
    private let bookmarkStore: RemoteBookmarkStore
    private let bookmarking: any SecurityScopedBookmarking
    private let presentOpenPanel: @Sendable (URL) async -> URL?
    private let ubiquityContainerURLProvider: @Sendable () -> URL?

    /// - Parameters:
    ///   - bookmarkStore: Where this resolver persists its OWN bookmarks (never the main app's).
    ///     Production: a JSON file under this helper's own `Application Support`. Tests: inject
    ///     a temp-file-backed store.
    ///   - bookmarking: The `SecurityScopedBookmarking` seam (`PlatformSecurityScopedBookmark.make()`
    ///     in production, a fake in tests).
    ///   - presentOpenPanel: Closure invoked when a site has no bookmark yet — production shows
    ///     a real `NSOpenPanel` pre-targeted at the expected package path; tests inject a stub
    ///     returning a canned URL (or `nil` for "user cancelled").
    ///   - ubiquityContainerURLProvider: Returns the shared iCloud ubiquity container's root URL,
    ///     or `nil` when iCloud is unavailable. Production defaults to the real
    ///     `FileManager.default.url(forUbiquityContainerIdentifier:)` lookup; tests inject a fake
    ///     pointing at a temp directory standing in for the container.
    public init(
        bookmarkStore: RemoteBookmarkStore,
        bookmarking: any SecurityScopedBookmarking,
        presentOpenPanel: @escaping @Sendable (URL) async -> URL?,
        ubiquityContainerURLProvider: @escaping @Sendable () -> URL? = {
            FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.io.dwk.anglesite")
        }
    ) {
        self.bookmarkStore = bookmarkStore
        self.bookmarking = bookmarking
        self.presentOpenPanel = presentOpenPanel
        self.ubiquityContainerURLProvider = ubiquityContainerURLProvider
    }

    /// Resolves `siteID` to its `Source/` directory. `expectedPackageURL` is only used to
    /// pre-target the open panel on the non-iCloud path (best-effort UX, not a security check —
    /// the user can navigate elsewhere in the panel, same as the main app's own Import flow).
    public func resolveSourceDirectory(siteID: String, expectedPackageURL: URL) async throws -> URL {
        // Fast path: the package already sits inside the shared iCloud ubiquity container, which
        // both bundle IDs (main app + helper) carry the same entitlement for — no bookmark needed,
        // no prompt, no persisted grant.
        if let ubiquityRoot = ubiquityContainerURLProvider(),
           isURL(expectedPackageURL, containedIn: ubiquityRoot) {
            return expectedPackageURL.appendingPathComponent("Source")
        }

        if let existingData = try await bookmarkStore.bookmarkData(for: siteID) {
            return try await resolveAndPersistIfStale(existingData, siteID: siteID)
        }

        guard let grantedURL = await presentOpenPanel(expectedPackageURL) else {
            throw RemoteSiteResolverError.userCancelledGrant
        }

        // Scope the bookmark directly to Source/ — unlike the main app's `SiteAccess` (which
        // bookmarks the whole package to cover both Source/ and Config/), this resolver only
        // ever needs Source/, so the persisted grant is narrower.
        let freshData: Data
        do {
            freshData = try bookmarking.create(for: grantedURL.appendingPathComponent("Source"))
        } catch {
            throw RemoteSiteResolverError.bookmarkResolutionFailed(String(describing: error))
        }
        try await bookmarkStore.setBookmark(freshData, for: siteID)
        return try await resolveAndPersistIfStale(freshData, siteID: siteID)
    }

    /// Resolves bookmark `data` — already scoped to the site's `Source/` directory — re-`create`ing
    /// and persisting a fresh bookmark when the platform reports staleness, the same dance
    /// `SiteAccess` already performs for the main app.
    private func resolveAndPersistIfStale(_ data: Data, siteID: String) async throws -> URL {
        let resolution: SecurityScopedBookmarkResolution
        do {
            resolution = try bookmarking.resolve(data)
        } catch {
            throw RemoteSiteResolverError.bookmarkResolutionFailed(String(describing: error))
        }

        if resolution.isStale {
            _ = bookmarking.startAccessing(resolution.url)
            defer { bookmarking.stopAccessing(resolution.url) }
            if let refreshedData = try? bookmarking.create(for: resolution.url) {
                try await bookmarkStore.setBookmark(refreshedData, for: siteID)
            }
        }

        return resolution.url
    }

    /// True when `url` is `container` itself or nested inside it.
    private func isURL(_ url: URL, containedIn container: URL) -> Bool {
        let containerPath = container.standardizedFileURL.resolvingSymlinksInPath().path
        let candidatePath = url.standardizedFileURL.resolvingSymlinksInPath().path
        return candidatePath == containerPath || candidatePath.hasPrefix(containerPath + "/")
    }
}
