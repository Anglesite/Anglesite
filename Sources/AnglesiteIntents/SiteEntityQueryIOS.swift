#if os(iOS)
import AppIntents
import AnglesiteCore
import AnglesiteIOS
import Foundation

/// Resolves `SiteEntity`s on iOS by discovering `.anglesite` packages in the app's iCloud
/// ubiquity container — the same mechanism `SitePickerModel` uses in production
/// (`Sources/AnglesiteIOS/SitePickerModel.swift`). All mapping/matching logic lives in
/// `SiteEntityUbiquitySource`; this type's only job is resolving the discovered `[URL]` list and
/// handing it off. Not exercised by `swift test` (excluded on a macOS host by this `#if
/// os(iOS)` gate) — verified by `xcodebuild ... -scheme AnglesiteMobile ... build` only.
public struct SiteEntityQueryIOS: EntityStringQuery {
    private let containerResolver: any UbiquityContainerResolving
    /// `NSMetadataQueryPackageDiscovery` is `@MainActor`-isolated (see
    /// `Sources/AnglesiteIOS/UbiquitousPackageDiscovering.swift`), so its no-arg initializer can't
    /// be called synchronously from this struct's plain, non-isolated `init()`. Storing a
    /// `@MainActor`-isolated factory instead of an already-constructed instance defers that call
    /// to `discoveredURLs()`, which is `async` and can `await` across the actor hop.
    private let makePackageDiscovery: @MainActor @Sendable () -> any UbiquitousPackageDiscovering

    /// The no-argument initializer AppIntents requires — binds to the real iCloud container
    /// resolver and `NSMetadataQuery`-backed discovery, matching every other production call
    /// site.
    public init() {
        self.containerResolver = FileManager.default
        self.makePackageDiscovery = { NSMetadataQueryPackageDiscovery() }
    }

    /// Test seam: bind the query to fakes instead of real iCloud state.
    public init(
        containerResolver: any UbiquityContainerResolving,
        packageDiscovery: any UbiquitousPackageDiscovering
    ) {
        self.containerResolver = containerResolver
        self.makePackageDiscovery = { packageDiscovery }
    }

    /// Ubiquity container check, then package discovery. `nil` container → `[]`, matching
    /// `SitePickerModel.refresh()`'s `.iCloudUnavailable` short-circuit (this type has no
    /// equivalent state to publish, so an empty result is the only signal available).
    private func discoveredURLs() async -> [URL] {
        guard containerResolver.url(
            forUbiquityContainerIdentifier: AppSettings.ubiquityContainerIdentifier
        ) != nil else {
            return []
        }
        let packageDiscovery = await makePackageDiscovery()
        return await packageDiscovery.discoverPackages()
    }

    public func entities(for identifiers: [String]) async throws -> [SiteEntity] {
        SiteEntityUbiquitySource.entities(for: identifiers, in: await discoveredURLs())
    }

    public func entities(matching string: String) async throws -> [SiteEntity] {
        SiteEntityUbiquitySource.entities(matching: string, in: await discoveredURLs())
    }

    public func suggestedEntities() async throws -> [SiteEntity] {
        SiteEntityUbiquitySource.siteEntities(fromPackageURLs: await discoveredURLs())
    }

    public func defaultResult() async -> SiteEntity? {
        SiteEntityUbiquitySource.defaultResult(in: await discoveredURLs())
    }
}
#endif
