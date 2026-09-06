import Foundation

/// Pure ordering + capping rule for the File ▸ Open Recent submenu.
///
/// Kept free of SwiftUI/actor state so it is unit-testable under `swift test`
/// (the App target has no unit suite). The App's `RecentSitesModel` pipes
/// `SiteStore.changeStream()` snapshots through this and publishes the result.
public enum RecentSites {
    /// Most-recently-seen first, capped at `limit`.
    ///
    /// Invalid sites are *kept* — the menu shows them disabled, matching the launcher
    /// list — so callers see exactly what the registry holds, just trimmed and ordered.
    public static func select(from sites: [SiteStore.Site], limit: Int = 10) -> [SiteStore.Site] {
        Array(sites.sorted { $0.lastSeen > $1.lastSeen }.prefix(limit))
    }
}
