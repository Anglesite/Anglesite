import Foundation
import AnglesiteSiteModel

/// Share-extension-side counterpart to `SiteAccess`: resolves a site's folder access from the
/// App-Group-published manifest instead of the main app's own `SiteStore`/`recents.json` — the
/// extension runs as a separate sandboxed process (#1450) that can't see the app's container.
public enum ShareExtensionSiteAccess {
    /// Failures acquiring scoped access from the extension side. Cases carry ready-to-show
    /// messages — the extension's compose sheet has no window chrome to elaborate further.
    public enum AccessError: Error, Sendable, Equatable {
        /// The App Group container isn't reachable — no entitlement/provisioning profile, or the
        /// main app has never published a bookmark to share.
        case unavailable
        /// The manifest has no entry for the requested site (stale/removed since the picker last
        /// refreshed).
        case siteNotFound
        /// The bookmark exists but couldn't be resolved or started. Carries a user-facing message.
        case noGrant(String)
    }

    /// The sites currently shared by the main app, most-recently-seen first — for the extension's
    /// site picker. Empty (never throws) when sharing is unavailable.
    public static func listSites(
        directory: URL? = SharedContainer.url(),
        fileManager: FileManager = .default
    ) -> [SharedSite] {
        guard let directory else { return [] }
        return SharedSiteRegistry.read(from: directory, fileManager: fileManager)
    }

    /// Run `body` with read/write access to `siteID`'s source directory, resolved from the shared
    /// manifest. Mirrors `SiteAccess.withScopedAccess`'s bracketed-grant shape: starts access,
    /// hands `body` the site's `Source/` directory, then stops access before returning.
    public static func withScopedAccess<T: Sendable>(
        toSiteID siteID: String,
        directory: URL? = SharedContainer.url(),
        fileManager: FileManager = .default,
        _ body: (URL) async -> T
    ) async throws -> T {
        guard let directory else { throw AccessError.unavailable }
        let sites = SharedSiteRegistry.read(from: directory, fileManager: fileManager)
        guard let site = sites.first(where: { $0.id == siteID }) else {
            throw AccessError.siteNotFound
        }
        let bookmarker = PlatformSecurityScopedBookmark.make()
        guard let resolved = try? bookmarker.resolve(site.bookmarkData) else {
            throw AccessError.noGrant(
                "Couldn't access \(site.name)'s folder. Open it once in Anglesite, then try again.")
        }
        guard bookmarker.startAccessing(resolved.url) else {
            throw AccessError.noGrant(
                "Couldn't access \(site.name)'s folder. Open it once in Anglesite, then try again.")
        }
        defer { bookmarker.stopAccessing(resolved.url) }
        let sourceDirectory = AnglesitePackage(url: resolved.url).sourceURL
        return await body(sourceDirectory)
    }
}
