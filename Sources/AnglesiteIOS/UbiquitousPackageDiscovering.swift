import Foundation
import AnglesiteSiteModel

/// Wraps `NSMetadataQuery` so `SitePickerModel` can be tested against fixtured results (#866)
/// instead of the real iCloud state of whatever machine runs `swift test` — mirrors
/// `AnglesiteCore`'s `UbiquityContainerResolving`/`FakeUbiquityContainerResolver` seam (#865).
public protocol UbiquitousPackageDiscovering: Sendable {
    /// Runs a one-shot query for `.anglesite` packages in the app's iCloud ubiquity container
    /// and returns their URLs once the initial gather completes. Callers are expected to have
    /// already confirmed the container is available (`UbiquityContainerResolving`) before calling
    /// this — it does not itself distinguish "no container" from "container has no packages".
    func discoverPackages() async -> [URL]
}

/// Real `NSMetadataQuery`-backed implementation. Scoped to
/// `NSMetadataQueryUbiquitousDocumentsScope` (the app's own ubiquity container's `Documents/`
/// folder — matching `AppSettings.sitesRoot`'s `container/Documents` convention, #865) rather than
/// a raw file-URL scope or a broader ubiquitous-data scope: per `SyncModel.observeBundleChanges`'s
/// prior art (`Sources/AnglesiteApp/SyncModel.swift`), ubiquitous item metadata keys like
/// `NSMetadataItemPathKey` aren't reliably populated until an item is first resolved, so filtering
/// by path prefix is unreliable — the predefined scope constant is the documented-correct way to
/// scope a search to this app's own ubiquitous documents instead.
///
/// No stored mutable state: each call creates and tears down its own query and observer, so
/// concurrent calls can't interfere with each other.
///
/// `@MainActor`-isolated on purpose: `NSMetadataQuery` only gathers and delivers its notifications
/// when started from a thread with a serviced run loop, which in practice means the main thread —
/// exactly what `SyncModel.observeBundleChanges` (`Sources/AnglesiteApp/SyncModel.swift`) relies on
/// by virtue of running from a `@MainActor` model. A plain `async` method here would instead run
/// its body on the cooperative thread pool, where `.NSMetadataQueryDidFinishGathering` may never
/// fire and the continuation would hang forever. The isolation still satisfies the non-isolated
/// `async` protocol requirement above — the hop happens transparently at each `await` call site.
@MainActor
public final class NSMetadataQueryPackageDiscovery: UbiquitousPackageDiscovering {
    public init() {}

    public func discoverPackages() async -> [URL] {
        await withCheckedContinuation { continuation in
            let query = NSMetadataQuery()
            query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
            query.predicate = NSPredicate(
                format: "%K ENDSWITH %@",
                NSMetadataItemFSNameKey, ".\(AnglesitePackage.packageExtension)"
            )

            var observer: NSObjectProtocol?
            observer = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
            ) { _ in
                query.disableUpdates()
                query.stop()
                if let observer {
                    NotificationCenter.default.removeObserver(observer)
                }
                let urls = (0..<query.resultCount).compactMap { index -> URL? in
                    (query.result(at: index) as? NSMetadataItem)?
                        .value(forAttribute: NSMetadataItemURLKey) as? URL
                }
                continuation.resume(returning: urls)
            }
            // A `false` return means gathering never begins (malformed predicate or scope), so
            // `.NSMetadataQueryDidFinishGathering` would never fire and the continuation would
            // hang forever. Unreachable with the constants above, but the failure mode is a
            // permanently stuck "Finding your sites…", so tear the observer back down and report
            // "no packages" instead.
            guard query.start() else {
                if let observer {
                    NotificationCenter.default.removeObserver(observer)
                }
                continuation.resume(returning: [])
                return
            }
        }
    }
}
