#if os(iOS)
import AppIntents
import AnglesiteCore
import AnglesiteIOS
import Foundation

/// Resolves `SiteEntity`s on iOS by discovering `.anglesite` packages in the app's iCloud
/// ubiquity container — the same mechanism `SitePickerModel` uses in production
/// (`Sources/AnglesiteIOS/SitePickerModel.swift`). Deliberately holds no logic of its own: the
/// discovery (cached and coalesced across the several calls one Siri interaction makes) belongs to
/// ``SiteEntityUbiquityDiscovery``, and the URL-to-entity mapping belongs to
/// `SiteEntityUbiquitySource` — both gate-free and covered by `swift test`, so this `#if
/// os(iOS)`-gated wrapper stays small enough to be verified by `xcodebuild ... -scheme
/// AnglesiteMobile ... build` alone.
public struct SiteEntityQueryIOS: EntityStringQuery {
    private let discovery: SiteEntityUbiquityDiscovery

    /// The no-argument initializer AppIntents requires — binds to the real iCloud container
    /// resolver and `NSMetadataQuery`-backed discovery, matching every other production call
    /// site.
    public init() {
        self.discovery = SiteEntityUbiquityDiscovery(
            containerResolver: FileManager.default,
            makePackageDiscovery: { NSMetadataQueryPackageDiscovery() },
            ubiquityContainerIdentifier: AppSettings.ubiquityContainerIdentifier
        )
    }

    /// Test seam: bind the query to fakes instead of real iCloud state.
    public init(
        containerResolver: any UbiquityContainerResolving,
        packageDiscovery: any UbiquitousPackageDiscovering
    ) {
        self.discovery = SiteEntityUbiquityDiscovery(
            containerResolver: containerResolver,
            makePackageDiscovery: { packageDiscovery },
            ubiquityContainerIdentifier: AppSettings.ubiquityContainerIdentifier
        )
    }

    /// Maps the discovered package URLs with `body`, off the calling task.
    ///
    /// Every `SiteEntityUbiquitySource` entry point calls `AnglesitePackage.readMarker` once per
    /// package — an `Info.plist` read inside the ubiquity container, which can block on a
    /// materializing iCloud item. `SitePickerModel.refresh()` gives those reads a
    /// `Task.detached(priority: .userInitiated)` hop for exactly that reason; this does the same,
    /// one hop for the whole list rather than one per package.
    private func mapDiscovered<T: Sendable>(
        _ body: @escaping @Sendable ([URL]) -> T
    ) async -> T {
        let urls = await discovery.discoveredURLs()
        return await Task.detached(priority: .userInitiated) { body(urls) }.value
    }

    public func entities(for identifiers: [String]) async throws -> [SiteEntity] {
        await mapDiscovered { SiteEntityUbiquitySource.entities(for: identifiers, in: $0) }
    }

    public func entities(matching string: String) async throws -> [SiteEntity] {
        await mapDiscovered { SiteEntityUbiquitySource.entities(matching: string, in: $0) }
    }

    public func suggestedEntities() async throws -> [SiteEntity] {
        await mapDiscovered { SiteEntityUbiquitySource.siteEntities(fromPackageURLs: $0) }
    }

    public func defaultResult() async -> SiteEntity? {
        await mapDiscovered { SiteEntityUbiquitySource.defaultResult(in: $0) }
    }
}
#endif
