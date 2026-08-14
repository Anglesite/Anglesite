import Combine
import AnglesiteCore

/// What `AdvancedSettingsView`'s "Find on local network" control is doing right now.
enum LANDiscoveryScanState: Equatable {
    case idle
    case scanning
    case result(LANHostSelection)
}

/// Drives one time-boxed LAN host scan per button click, bridging `LANHostDiscovering`'s
/// arbitrary-queue callback into `@MainActor`-safe, `@Published` state `AdvancedSettingsView` can
/// observe directly. Injectable `discovery` (default `PlatformLANHostDiscovery.make()`) is the
/// seam `LANHostScanCoordinatorTests` uses to avoid touching real `NWBrowser`.
@MainActor
final class LANHostScanCoordinator: ObservableObject {
    @Published private(set) var state: LANDiscoveryScanState = .idle

    private let discovery: any LANHostDiscovering
    private var latestHosts: [DiscoveredLANHost] = []

    init(discovery: any LANHostDiscovering = PlatformLANHostDiscovery.make()) {
        self.discovery = discovery
    }

    /// Starts a scan: resets accumulated results, begins browsing, and after `scanDuration`
    /// stops browsing and publishes the selection `selectLANHost(from:)` computes from whatever
    /// was seen. A scan already in flight is left alone (no re-entrant restart) — this guard,
    /// combined with everything below running on `MainActor`, is what keeps a second `startScan`
    /// call from racing the first: there's no window where two scans' timeout `Task`s are both
    /// live at once.
    func startScan(scanDuration: Duration = .seconds(4)) {
        guard state != .scanning else { return }
        state = .scanning
        latestHosts = []

        // `discovery.start`'s callback may arrive on an arbitrary queue (per `LANHostDiscovering`'s
        // contract), so hop back to `MainActor` before touching `latestHosts` — it's otherwise only
        // ever read/written from this actor.
        discovery.start { [weak self] hosts in
            Task { @MainActor in
                self?.latestHosts = hosts
            }
        }
        Task { [weak self] in
            try? await Task.sleep(for: scanDuration)
            guard let self else { return }
            self.discovery.stop()
            self.state = .result(selectLANHost(from: self.latestHosts))
        }
    }
}
