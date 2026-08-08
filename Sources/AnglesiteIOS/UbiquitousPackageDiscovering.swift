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
    ///
    /// Implementations must always return: a conforming type may report "no packages" but may
    /// never leave the caller suspended indefinitely, because `SitePickerModel.refresh()`'s
    /// `.loading` state has no other way out.
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
/// No stored mutable state: each call creates and tears down its own `GatherSession`, so
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
    /// How long to wait for `.NSMetadataQueryDidFinishGathering` before giving up and reporting
    /// "no packages". Generous on purpose: a cold ubiquity container on a slow network can take a
    /// few seconds to finish its first gather, and a spurious "No Sites Found" is a worse failure
    /// than a slightly longer spinner. Bounded all the same, because the alternative — the
    /// notification never arriving (iCloud daemon hiccup, degraded network) — strands the iOS
    /// app's only root scene on a `ProgressView` with no way out. Same bounded-wait convention as
    /// `AnglesiteCore`'s server-readiness budget, which reports an overrun rather than hanging.
    static let gatherTimeout: Duration = .seconds(25)

    public init() {}

    public func discoverPackages() async -> [URL] {
        let session = GatherSession()
        return await withCheckedContinuation { continuation in
            session.begin(timeout: Self.gatherTimeout, continuation: continuation)
        }
    }
}

/// One in-flight `NSMetadataQuery` gather and everything that has to be torn down with it.
///
/// The query, its observer token, and the timeout task live as properties here rather than as
/// locals captured by the observer block: `addObserver(forName:object:queue:using:)`'s block is
/// `@Sendable @escaping`, so the self-removing-observer idiom (assign a captured local `var
/// observer` *after* building the closure that reads it) is exactly the shape strict concurrency
/// warns about. `SyncModel.observeBundleChanges` avoids it by storing the token on the model;
/// this type does the same, but scoped to a single call rather than to the discovery object, so
/// two overlapping `discoverPackages()` calls still get fully independent queries.
@MainActor
private final class GatherSession {
    private let query = NSMetadataQuery()
    private var observer: NSObjectProtocol?
    private var timeoutTask: Task<Void, Never>?
    /// Non-`nil` until whichever of {gather finished, timeout, failed start} happens first —
    /// `finish(with:)` uses it as the "not yet resumed" flag, so the continuation is resumed
    /// exactly once no matter how many of those race.
    private var continuation: CheckedContinuation<[URL], Never>?

    func begin(timeout: Duration, continuation: CheckedContinuation<[URL], Never>) {
        self.continuation = continuation

        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        // Filename-suffix matching, not a UTI/content-type match: `NSMetadataItemContentTypeTreeKey`
        // is only populated once iCloud has resolved an item, so a UTI predicate would miss
        // packages this device has never opened. A stray non-package item merely *named*
        // `something.anglesite` therefore also matches; that's the accepted fallback, since it
        // fails `AnglesitePackage.readMarker(fileManager:)` and gets skipped by the caller.
        query.predicate = NSPredicate(
            format: "%K ENDSWITH %@",
            NSMetadataItemFSNameKey, ".\(AnglesitePackage.packageExtension)"
        )

        observer = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
        ) { [self] _ in
            // `queue: .main` guarantees this block runs on the main thread, which is the main
            // actor's executor — the same assumption `SyncModel`'s metadata observer makes.
            MainActor.assumeIsolated { finishGathering() }
        }

        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.finish(with: [])
        }

        // A `false` return means gathering never begins (malformed predicate or scope), so
        // `.NSMetadataQueryDidFinishGathering` would never fire. Unreachable with the constants
        // above, and the timeout would eventually cover it anyway, but there's no reason to make
        // the user wait out the full budget for a failure we already know about.
        guard query.start() else {
            finish(with: [])
            return
        }
    }

    private func finishGathering() {
        let urls = (0..<query.resultCount).compactMap { index -> URL? in
            (query.result(at: index) as? NSMetadataItem)?
                .value(forAttribute: NSMetadataItemURLKey) as? URL
        }
        finish(with: urls)
    }

    /// Tears the query and observer down and resumes the caller. Idempotent: later callers (a
    /// gather that lands just after the timeout fired, say) find `continuation == nil` and return
    /// without double-resuming. Stopping a query that never started is harmless, so every exit
    /// path can share this teardown.
    private func finish(with urls: [URL]) {
        guard let continuation else { return }
        self.continuation = nil

        timeoutTask?.cancel()
        timeoutTask = nil
        query.disableUpdates()
        query.stop()
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }

        continuation.resume(returning: urls)
    }
}
