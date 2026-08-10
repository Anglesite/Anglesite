// Sources/AnglesiteIOS/SiteSelectionModel.swift
import Foundation
import Observation

/// Owns which site the iOS shell (`SiteSplitScreen`, #869) currently has selected, and persists
/// that choice across launches (#71 "multi-site UX" follow-up). Deliberately separate from
/// `SitePickerModel`, which only discovers sites and is also used standalone by `SitePickerScreen`
/// (no selection concept there) — folding selection into it would blur that model's one job.
@MainActor
@Observable
public final class SiteSelectionModel {
    public private(set) var selectedSite: SitePickerModel.DiscoveredSite?

    private let defaults: UserDefaults
    private static let selectedSiteIDKey = "siteSelection.selectedSiteID"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// User-driven selection (a sidebar tap or the switcher menu). Always wins immediately and
    /// persists the choice; `nil` clears both.
    public func select(_ site: SitePickerModel.DiscoveredSite?) {
        selectedSite = site
        if let site {
            defaults.set(site.id.uuidString, forKey: Self.selectedSiteIDKey)
        } else {
            defaults.removeObject(forKey: Self.selectedSiteIDKey)
        }
    }

    /// Called once discovery produces a list. Resolves the persisted site ID against `sites` and
    /// selects it if found. A no-op when a site is already selected — a user tapping around before
    /// discovery/restore settles must never be clobbered by a late restore — or when nothing is
    /// persisted, or the persisted site isn't in `sites` (deleted, moved, not yet synced): in every
    /// one of those cases the screen's existing empty/picker state is already correct.
    public func restoreSelection(from sites: [SitePickerModel.DiscoveredSite]) {
        guard selectedSite == nil,
              let storedIDString = defaults.string(forKey: Self.selectedSiteIDKey),
              let storedID = UUID(uuidString: storedIDString),
              let match = sites.first(where: { $0.id == storedID })
        else { return }
        selectedSite = match
    }
}
