import Testing
import AnglesiteCore
import AnglesiteTestSupport
@testable import AnglesiteAppCore

private final class FakeLANHostDiscovery: LANHostDiscovering, @unchecked Sendable {
    var hostsToReport: [DiscoveredLANHost] = []
    private(set) var stopCallCount = 0

    func start(onUpdate: @escaping @Sendable ([DiscoveredLANHost]) -> Void) {
        onUpdate(hostsToReport)
    }

    func stop() {
        stopCallCount += 1
    }
}

private func lanHost(_ name: String) -> DiscoveredLANHost {
    DiscoveredLANHost(siteName: name, dnsName: "\(name).local", ipAddress: "192.168.1.1",
                       previewPort: 4321, mcpPort: 4399)
}

/// Uses `waitUntil` (not a fixed `Task.sleep` before asserting) to observe `startScan`'s
/// 10ms-delayed timeout: a fixed sleep-then-assert window raced the `MainActor` executor under
/// full-parallel `swift test` contention and reproducibly left `state` stuck at `.scanning`
/// instead of `.result(...)` (#1810) — the many other `@MainActor`-isolated suites running
/// concurrently oversubscribed the shared executor badly enough that a 100ms assertion window
/// missed the 10ms-delayed continuation. Polling for the actual state transition removes the
/// race regardless of scheduler load, so this suite no longer needs `.serialized` or the
/// isolated CI lane (`scripts/lib/timing-sensitive-tests.sh`).
@MainActor
@Suite("LANHostScanCoordinator")
struct LANHostScanCoordinatorTests {
    @Test("starts in idle state")
    func startsIdle() {
        let coordinator = LANHostScanCoordinator(discovery: FakeLANHostDiscovery())
        #expect(coordinator.state == .idle)
    }

    @Test("immediately after starting a scan, state is scanning")
    func scanningWhileInFlight() {
        let coordinator = LANHostScanCoordinator(discovery: FakeLANHostDiscovery())
        coordinator.startScan(scanDuration: .seconds(30))
        #expect(coordinator.state == .scanning)
    }

    @Test("a scan that finds one host ends in autoPopulate and stops discovery")
    func oneHostAutoPopulates() async throws {
        let fake = FakeLANHostDiscovery()
        fake.hostsToReport = [lanHost("blog")]
        let coordinator = LANHostScanCoordinator(discovery: fake)
        coordinator.startScan(scanDuration: .milliseconds(10))
        try await waitUntil("scan result") { coordinator.state != .scanning }
        #expect(coordinator.state == .result(.autoPopulate(lanHost("blog"))))
        #expect(fake.stopCallCount == 1)
    }

    @Test("a scan that finds nothing ends empty")
    func noHostsIsEmpty() async throws {
        let coordinator = LANHostScanCoordinator(discovery: FakeLANHostDiscovery())
        coordinator.startScan(scanDuration: .milliseconds(10))
        try await waitUntil("scan result") { coordinator.state != .scanning }
        #expect(coordinator.state == .result(.empty))
    }

    @Test("a scan that finds multiple hosts ends in chooseFrom")
    func multipleHostsChooseFrom() async throws {
        let fake = FakeLANHostDiscovery()
        fake.hostsToReport = [lanHost("blog"), lanHost("docs")]
        let coordinator = LANHostScanCoordinator(discovery: fake)
        coordinator.startScan(scanDuration: .milliseconds(10))
        try await waitUntil("scan result") { coordinator.state != .scanning }
        #expect(coordinator.state == .result(.chooseFrom([lanHost("blog"), lanHost("docs")])))
    }
}
