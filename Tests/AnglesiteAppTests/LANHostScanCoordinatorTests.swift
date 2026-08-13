import Testing
import AnglesiteCore
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

/// `.serialized` + isolated CI lane (`scripts/lib/timing-sensitive-tests.sh`): these tests assert
/// on wall-clock outcomes of a `MainActor` `Task.sleep`-driven timeout (`startScan`'s 10ms
/// `scanDuration` racing a 100ms assertion window). Self-diagnosed cross-suite contention, in the
/// style of `VsockTCPProxyTests`/#1344: a local `swift test --filter LANHostScanCoordinatorTests`
/// run passes all 5 tests in ~0.1s every time, but running the same suite as part of the full
/// `AnglesiteAppTests` filter (471 tests, all suites in parallel) reproducibly left `state` stuck
/// at `.scanning` instead of `.result(...)` — the many other `@MainActor`-isolated suites running
/// concurrently oversubscribe the shared MainActor executor badly enough that this suite's own
/// 10ms-delayed continuation misses its 100ms budget. `.serialized` removes this suite's internal
/// contention with itself; the isolated lane removes contention from the rest of the test binary.
@MainActor
@Suite("LANHostScanCoordinator", .serialized)
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
        try await Task.sleep(for: .milliseconds(100))
        #expect(coordinator.state == .result(.autoPopulate(lanHost("blog"))))
        #expect(fake.stopCallCount == 1)
    }

    @Test("a scan that finds nothing ends empty")
    func noHostsIsEmpty() async throws {
        let coordinator = LANHostScanCoordinator(discovery: FakeLANHostDiscovery())
        coordinator.startScan(scanDuration: .milliseconds(10))
        try await Task.sleep(for: .milliseconds(100))
        #expect(coordinator.state == .result(.empty))
    }

    @Test("a scan that finds multiple hosts ends in chooseFrom")
    func multipleHostsChooseFrom() async throws {
        let fake = FakeLANHostDiscovery()
        fake.hostsToReport = [lanHost("blog"), lanHost("docs")]
        let coordinator = LANHostScanCoordinator(discovery: fake)
        coordinator.startScan(scanDuration: .milliseconds(10))
        try await Task.sleep(for: .milliseconds(100))
        #expect(coordinator.state == .result(.chooseFrom([lanHost("blog"), lanHost("docs")])))
    }
}
