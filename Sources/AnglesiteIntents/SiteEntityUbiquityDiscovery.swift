import AnglesiteCore
import AnglesiteIOS
import Foundation

/// Caches and coalesces iCloud package discovery behind `SiteEntityQueryIOS` (#1394).
/// `NSMetadataQueryPackageDiscovery.discoverPackages()` runs a full `NSMetadataQuery` gather
/// bounded at 25s (tuned for `SitePickerScreen`'s picker UX, not Siri's interaction budget) —
/// AppIntents routinely calls more than one `EntityStringQuery` method per interaction (e.g.
/// `defaultResult()` then `suggestedEntities()` for disambiguation), so without caching a single
/// utterance could trigger 2-4 independent 25s-bounded gathers, each able to time out to an empty
/// `[]` result — silently telling the user "no sites found" when sites exist.
///
/// Also restores the off-caller-task handling `SitePickerModel.refresh()` established for the
/// container lookup (`UbiquityContainerResolving.url(forUbiquityContainerIdentifier:)` is
/// documented as potentially slow — it may hit the network) by running it inside a
/// `Task.detached`. The other half of that precedent, the per-package `readMarker` reads, happens
/// in `SiteEntityUbiquitySource` rather than here, so `SiteEntityQueryIOS` gives *those* their own
/// detached hop at the point it maps this type's URLs into entities.
///
/// No platform gate: `UbiquityContainerResolving`/`UbiquitousPackageDiscovering` are both
/// platform-neutral, so this actor is `swift test`-able on the macOS host with fakes, unlike the
/// `#if os(iOS)`-gated query type that owns an instance of it.
actor SiteEntityUbiquityDiscovery {
    private let containerResolver: any UbiquityContainerResolving
    /// `NSMetadataQueryPackageDiscovery` is `@MainActor`-isolated (see
    /// `Sources/AnglesiteIOS/UbiquitousPackageDiscovering.swift`), so its construction is deferred
    /// to the discovery task rather than happening in `init()`, which is not isolated to the main
    /// actor and so cannot call it. The real implementation holds no mutable state (each
    /// `discoverPackages()` call builds and tears down its own gather session), so constructing it
    /// per discovery rather than caching the instance costs nothing — and it keeps the whole
    /// `@MainActor` hop inside the coalesced task, where it can't reintroduce a suspension point
    /// ahead of `inFlight` being published.
    private let makePackageDiscovery: @MainActor @Sendable () -> any UbiquitousPackageDiscovering
    private let ubiquityContainerIdentifier: String
    private let cacheTTL: Duration

    private var cachedURLs: [URL]?
    private var cachedAt: ContinuousClock.Instant?
    private var inFlight: Task<[URL], Never>?
    private let clock = ContinuousClock()

    /// - Parameters:
    ///   - cacheTTL: how long a cached result stays fresh before the next call re-discovers.
    ///     Short on purpose: long enough to collapse the several `EntityStringQuery` calls one
    ///     Siri interaction makes into a single gather, short enough that a newly-created or
    ///     renamed site shows up quickly on the next interaction. Defaults to 5 seconds.
    init(
        containerResolver: any UbiquityContainerResolving,
        makePackageDiscovery: @escaping @MainActor @Sendable () -> any UbiquitousPackageDiscovering,
        ubiquityContainerIdentifier: String,
        cacheTTL: Duration = .seconds(5)
    ) {
        self.containerResolver = containerResolver
        self.makePackageDiscovery = makePackageDiscovery
        self.ubiquityContainerIdentifier = ubiquityContainerIdentifier
        self.cacheTTL = cacheTTL
    }

    /// Discovered package URLs: served from cache when fresh, coalesced with any in-flight
    /// discovery so concurrent calls share one gather rather than racing two, or freshly
    /// discovered (off this actor's task, via `Task.detached`) otherwise.
    ///
    /// An unavailable ubiquity container yields `[]` without starting a gather, matching
    /// `SitePickerModel.refresh()`'s `.iCloudUnavailable` short-circuit (this type has no
    /// equivalent state to publish, so an empty result is the only signal available).
    func discoveredURLs() async -> [URL] {
        if let cachedAt, let cachedURLs, cachedAt.duration(to: clock.now) < cacheTTL {
            return cachedURLs
        }
        if let inFlight {
            return await inFlight.value
        }

        // Everything between the `inFlight` check above and this assignment must stay
        // `await`-free: a suspension point in here would let a second caller past the check and
        // start a redundant gather, which is exactly what this type exists to prevent.
        let resolver = containerResolver
        let identifier = ubiquityContainerIdentifier
        let make = makePackageDiscovery
        let task = Task.detached(priority: .userInitiated) { () -> [URL] in
            guard resolver.url(forUbiquityContainerIdentifier: identifier) != nil else {
                return []
            }
            return await make().discoverPackages()
        }
        inFlight = task
        let urls = await task.value
        cachedURLs = urls
        cachedAt = clock.now
        inFlight = nil
        return urls
    }
}
