import Foundation
import SwiftUI
import AnglesiteCore
import AnglesiteSiteModel

/// Drives the iOS app's entry point (#866): lists the user's `.anglesite` packages found in their
/// iCloud ubiquity container, in place of the old "type a site URL" flow. `@MainActor` +
/// `@Observable` so `SitePickerScreen` (`AnglesiteMobile`) can bind to it directly, matching
/// `RemoteSessionModel`'s existing convention in this target.
@MainActor
@Observable
public final class SitePickerModel {
    /// A discovered `.anglesite` package, ready to show in the picker. `Hashable` so it can be
    /// a `NavigationLink` value (the picker pushes the #868 sign-in screen for it).
    public struct DiscoveredSite: Identifiable, Sendable, Hashable {
        /// The package's stable site UUID (`AnglesitePackage.Marker.siteID`) — path-independent,
        /// matching how `SiteStore.Site` identifies sites on the Mac.
        public let id: UUID
        public let displayName: String
        public let packageURL: URL
    }

    /// Distinguishes "iCloud itself isn't available" from "iCloud is available but has no sites
    /// yet" — the design's explicit requirement (spec §4/§7): the empty state's "create a site on
    /// your Mac" message must never show when the real problem is iCloud access.
    public enum State: Equatable {
        case loading
        case iCloudUnavailable
        case empty
        case sites([DiscoveredSite])
    }

    public private(set) var state: State = .loading

    private let ubiquityContainerResolver: UbiquityContainerResolving
    private let packageDiscovery: UbiquitousPackageDiscovering
    private let fileManager: FileManager

    /// Bumped by every `refresh()` call; a call only publishes its result while it still owns the
    /// latest value. See `refresh()`.
    private var refreshGeneration: UInt64 = 0

    public init(
        ubiquityContainerResolver: UbiquityContainerResolving = FileManager.default,
        packageDiscovery: UbiquitousPackageDiscovering = NSMetadataQueryPackageDiscovery(),
        fileManager: FileManager = .default
    ) {
        self.ubiquityContainerResolver = ubiquityContainerResolver
        self.packageDiscovery = packageDiscovery
        self.fileManager = fileManager
    }

    /// Re-runs discovery from scratch. Safe to call repeatedly (pull-to-refresh, a "Try Again"
    /// button, or the initial `.task` on `SitePickerScreen`).
    ///
    /// The `.loading` placeholder is only published when there's nothing on screen yet: a refresh
    /// from an already-populated list (pull-to-refresh) re-queries quietly underneath the existing
    /// rows instead of tearing the list down to a spinner mid-gesture.
    ///
    /// Overlapping calls are ordered by a generation counter rather than serialized: `refresh()`
    /// has two independent callers in `SitePickerScreen` (the initial `.task` and
    /// `.refreshable`), so a pull-to-refresh shortly after launch can start a second discovery
    /// while the first is still gathering. Whichever call started last owns the result — an
    /// older, slower call finds its generation stale on resume and drops its findings instead of
    /// reverting the list to a pre-refresh snapshot. Every caller still awaits its own work, so
    /// the pull-to-refresh spinner stays up for the duration of the gesture's own query.
    public func refresh() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration

        switch state {
        case .sites:
            break
        case .loading, .iCloudUnavailable, .empty:
            state = .loading
        }
        // `url(forUbiquityContainerIdentifier:)` is documented as potentially slow (it may hit the
        // network) and not to be called on the main thread — see the same warning on
        // `AppSettings.resolvedUbiquityContainerURL()`, which has to accept that cost because
        // `sitesRoot` is a synchronous `@MainActor` property. `refresh()` is `async`, so it can
        // simply hop off instead, matching the `Task.detached(priority:)` IO idiom used across
        // `AnglesiteApp`'s models.
        let resolver = ubiquityContainerResolver
        let hasContainer = await Task.detached(priority: .userInitiated) {
            resolver.url(forUbiquityContainerIdentifier: AppSettings.ubiquityContainerIdentifier) != nil
        }.value
        guard generation == refreshGeneration else { return }
        guard hasContainer else {
            state = .iCloudUnavailable
            return
        }

        let packageURLs = await packageDiscovery.discoverPackages()
        // Same reason the container hop above is detached: `readMarker` is a per-package
        // `Info.plist` read inside the ubiquity container, which can block on a materializing
        // iCloud item. One hop covers the whole list rather than one per package.
        let fileManager = self.fileManager
        let sites = await Task.detached(priority: .userInitiated) {
            packageURLs
                .compactMap { url -> DiscoveredSite? in
                    let package = AnglesitePackage(url: url)
                    guard let marker = try? package.readMarker(fileManager: fileManager) else {
                        return nil
                    }
                    return DiscoveredSite(
                        id: marker.siteID, displayName: marker.displayName, packageURL: url)
                }
                .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        }.value

        guard generation == refreshGeneration else { return }
        state = sites.isEmpty ? .empty : .sites(sites)
    }
}
