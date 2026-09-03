import Foundation
import Testing
import AnglesiteCore
@testable import AnglesiteIOS

/// A scripted `SiteRuntime` standing in for #1208 P4's `P2PSiteRuntime` — the design's testing
/// contract (iOS v2.0 spec §5: "Swift Testing suites drive the 'Edit Site' flow against a fake
/// `P2PSiteRuntime` behind the `SiteRuntime` seam").
actor FakeP2PSiteRuntime: SiteRuntime {
    let mcpClient = MCPClient(supervisor: ProcessSupervisor())
    private let stateMachine = SiteRuntimeStateMachine()
    private(set) var startCalls: [String] = []
    private(set) var stopCount = 0
    /// States `start()` settles through, in order.
    private let script: [SiteRuntimeState]

    init(script: [SiteRuntimeState]) {
        self.script = script
    }

    func start(siteID: String, siteDirectory: URL) async {
        startCalls.append(siteID)
        let gen = stateMachine.beginStarting(siteID: siteID)
        for state in script {
            stateMachine.settle(gen: gen, to: state)
        }
    }

    func stop() async {
        stopCount += 1
        stateMachine.settle(gen: stateMachine.beginAttempt(), to: .idle)
    }

    func observe() -> AsyncStream<SiteRuntimeState> {
        stateMachine.observe()
    }
}

@MainActor
@Suite("EditSessionModel")
struct EditSessionModelTests {
    private static let siteID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private static let previewURL = URL(string: "anglesite-p2p://site/index.html")!

    private static func pairedMac() -> PairedDevice {
        PairedDevice(
            deviceID: "mac-1", displayName: "My Mac",
            pinnedPublicKey: Data([0x04]), pairedAt: Date())
    }

    /// Builds a model whose runtime factory hands out `runtime` and counts invocations.
    private func makeModel(
        paired: [PairedDevice],
        runtime: FakeP2PSiteRuntime,
        factoryCalls: SharedCount = SharedCount(),
        lastMacContact: @escaping @Sendable () async -> Date? = { nil },
        onPhaseChange: @escaping @MainActor (EditSessionModel.Phase) -> Void = { _ in }
    ) -> EditSessionModel {
        EditSessionModel(
            siteID: Self.siteID,
            siteDisplayName: "Pullets Forever",
            pairedMacs: { paired },
            makeRuntime: {
                factoryCalls.value += 1
                return runtime
            },
            lastMacContact: lastMacContact,
            onPhaseChange: onPhaseChange
        )
    }

    @MainActor
    final class SharedCount {
        var value = 0
    }

    /// Bounded wait for an async phase transition — no wall-clock sleeps.
    private func waitForPhase(
        _ model: EditSessionModel, _ predicate: (EditSessionModel.Phase) -> Bool
    ) async -> Bool {
        for _ in 0..<2_000 {
            if predicate(model.phase) { return true }
            await Task.yield()
        }
        return predicate(model.phase)
    }

    @Test("no paired Mac gates on pairing without touching the runtime")
    func pairingGate() async {
        let calls = SharedCount()
        let model = makeModel(paired: [], runtime: FakeP2PSiteRuntime(script: []), factoryCalls: calls)
        await model.open()
        #expect(model.phase == .pairingRequired)
        #expect(calls.value == 0)
        #expect(model.mcpClient == nil)
    }

    @Test("a throwing paired-device store also gates on pairing")
    func pairingStoreThrow() async {
        let model = EditSessionModel(
            siteID: Self.siteID, siteDisplayName: "Site",
            pairedMacs: { throw CocoaError(.fileReadNoSuchFile) },
            makeRuntime: { FakeP2PSiteRuntime(script: []) }
        )
        await model.open()
        #expect(model.phase == .pairingRequired)
    }

    @Test("a paired Mac starts the runtime through to ready")
    func startsToReady() async {
        let runtime = FakeP2PSiteRuntime(
            script: [.ready(siteID: Self.siteID.uuidString, url: Self.previewURL)])
        let model = makeModel(paired: [Self.pairedMac()], runtime: runtime)
        await model.open()
        #expect(await waitForPhase(model) { $0 == .ready(Self.previewURL) })
        #expect(model.mcpClient != nil)
        #expect(await runtime.startCalls == [Self.siteID.uuidString])
    }

    @Test("failure renders the runtime message plus when the Mac was last reachable")
    func failureWithLastContact() async {
        let lastSeen = Date(timeIntervalSince1970: 1_755_200_000)
        let runtime = FakeP2PSiteRuntime(
            script: [.failed(siteID: Self.siteID.uuidString, message: "Your Mac couldn't be reached.")])
        let model = makeModel(
            paired: [Self.pairedMac()], runtime: runtime,
            lastMacContact: { lastSeen })
        await model.open()
        let reachedFailed = await waitForPhase(model) {
            if case .failed = $0 { return true } else { return false }
        }
        #expect(reachedFailed)
        guard case .failed(let message) = model.phase else { return }
        #expect(message.contains("Your Mac couldn't be reached."))
        #expect(message.contains(EditSessionModel.lastReachableClause(lastSeen)))
    }

    @Test("reopening a warm session reuses the runtime — dismissal never stops it")
    func warmReuse() async {
        let calls = SharedCount()
        let runtime = FakeP2PSiteRuntime(
            script: [.ready(siteID: Self.siteID.uuidString, url: Self.previewURL)])
        let model = makeModel(paired: [Self.pairedMac()], runtime: runtime, factoryCalls: calls)
        await model.open()
        _ = await waitForPhase(model) { $0 == .ready(Self.previewURL) }
        // The cover was dismissed and re-presented: open() again.
        await model.open()
        _ = await waitForPhase(model) { $0 == .ready(Self.previewURL) }
        #expect(calls.value == 1)
        #expect(await runtime.startCalls.count == 1)
        #expect(await runtime.stopCount == 0)
    }

    @Test("stop ends the session; the next open builds a fresh runtime")
    func stopEndsSession() async {
        let calls = SharedCount()
        let runtime = FakeP2PSiteRuntime(
            script: [.ready(siteID: Self.siteID.uuidString, url: Self.previewURL)])
        let model = makeModel(paired: [Self.pairedMac()], runtime: runtime, factoryCalls: calls)
        await model.open()
        _ = await waitForPhase(model) { $0 == .ready(Self.previewURL) }
        await model.stop()
        #expect(model.phase == .idle)
        #expect(model.mcpClient == nil)
        #expect(await runtime.stopCount == 1)
        await model.open()
        #expect(calls.value == 2)
    }

    @Test("completePairing proceeds into the session once a Mac is pinned")
    func completePairingStarts() async {
        let store = StoreBox()
        let runtime = FakeP2PSiteRuntime(
            script: [.ready(siteID: Self.siteID.uuidString, url: Self.previewURL)])
        let model = EditSessionModel(
            siteID: Self.siteID, siteDisplayName: "Site",
            pairedMacs: { store.devices },
            makeRuntime: { runtime }
        )
        await model.open()
        #expect(model.phase == .pairingRequired)
        store.devices = [Self.pairedMac()]
        await model.completePairing()
        #expect(await waitForPhase(model) { $0 == .ready(Self.previewURL) })
    }

    @MainActor
    final class StoreBox {
        var devices: [PairedDevice] = []
    }

    @MainActor
    final class PhaseLog {
        var phases: [EditSessionModel.Phase] = []
    }

    @Test("onPhaseChange fires for every phase transition, in order")
    func onPhaseChangeFiresInOrder() async {
        let log = PhaseLog()
        let runtime = FakeP2PSiteRuntime(
            script: [
                .starting(siteID: Self.siteID.uuidString),
                .ready(siteID: Self.siteID.uuidString, url: Self.previewURL),
            ])
        let model = makeModel(
            paired: [Self.pairedMac()], runtime: runtime,
            onPhaseChange: { log.phases.append($0) })

        await model.open()
        _ = await waitForPhase(model) { $0 == .ready(Self.previewURL) }
        #expect(log.phases == [.waking, .starting, .ready(Self.previewURL)])

        await model.stop()
        #expect(log.phases.last == .idle)
    }
}
