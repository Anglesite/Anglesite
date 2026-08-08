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
    /// A discovered `.anglesite` package, ready to show in the picker.
    public struct DiscoveredSite: Identifiable, Sendable, Equatable {
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
    public func refresh() async {
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
        guard hasContainer else {
            state = .iCloudUnavailable
            return
        }

        let packageURLs = await packageDiscovery.discoverPackages()
        let sites = packageURLs
            .compactMap { url -> DiscoveredSite? in
                let package = AnglesitePackage(url: url)
                guard let marker = try? package.readMarker(fileManager: fileManager) else {
                    return nil
                }
                return DiscoveredSite(id: marker.siteID, displayName: marker.displayName, packageURL: url)
            }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }

        state = sites.isEmpty ? .empty : .sites(sites)
    }
}
