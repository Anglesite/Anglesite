// Tests for the composer's waiting-for-network trigger (#1968): it resumes on a satisfied
// path, resumes promptly on cancellation (no leaked monitor or continuation, #1370 review), and
// the once-only gate underneath tolerates either order of the racing callbacks.
import Foundation
import Testing
import AnglesiteTestSupport
@testable import AnglesiteMobileCore

/// A hand-driven path monitor: the test decides when the path is "satisfied".
private final class FakePathMonitor: NetworkPathMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var onSatisfied: (@Sendable () -> Void)?
    private var _cancelled = false

    var isWatching: Bool { lock.withLock { onSatisfied != nil } }
    var cancelled: Bool { lock.withLock { _cancelled } }

    func startWatching(onSatisfied: @escaping @Sendable () -> Void) {
        lock.withLock { self.onSatisfied = onSatisfied }
    }

    func cancelWatching() {
        lock.withLock { _cancelled = true }
    }

    func satisfy() {
        lock.withLock { onSatisfied }?()
    }
}

@Suite("NetworkWait")
struct NetworkWaitTests {
    @Test("resumes once the path is satisfied and stops the monitor afterwards")
    func resumesOnSatisfiedPath() async throws {
        let monitor = FakePathMonitor()
        let waiter = Task { await NetworkWait.untilSatisfied(monitor: monitor) }
        try await waitUntil("monitor started") { monitor.isWatching }
        #expect(!monitor.cancelled)
        monitor.satisfy()
        await waiter.value
        #expect(monitor.cancelled)
    }

    @Test("cancelling the waiting task resumes it without a satisfied path")
    func resumesOnCancellation() async throws {
        let monitor = FakePathMonitor()
        let waiter = Task { await NetworkWait.untilSatisfied(monitor: monitor) }
        try await waitUntil("monitor started") { monitor.isWatching }
        waiter.cancel()
        await waiter.value
        #expect(monitor.cancelled)
    }

    @Test("a task cancelled before it even starts waiting still returns")
    func alreadyCancelledReturns() async {
        let monitor = FakePathMonitor()
        let waiter = Task {
            // Cancel before the wait begins: the cancellation handler fires on entry, so the
            // gate resumes "early" and arming must resume immediately.
            withUnsafeCurrentTask { $0?.cancel() }
            await NetworkWait.untilSatisfied(monitor: monitor)
        }
        await waiter.value
        #expect(monitor.cancelled)
    }

    @Test("a second satisfied callback after the resume is harmless")
    func doubleSatisfyIsHarmless() async throws {
        let monitor = FakePathMonitor()
        let waiter = Task { await NetworkWait.untilSatisfied(monitor: monitor) }
        try await waitUntil("monitor started") { monitor.isWatching }
        monitor.satisfy()
        monitor.satisfy()
        await waiter.value
        #expect(monitor.cancelled)
    }

    @Test("the gate resumes exactly once in either order")
    func gateResumesOnce() async {
        // resume-before-arm: arming resumes immediately.
        let early = ContinuationGate()
        early.resume()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in early.arm(c) }

        // arm-before-resume, then a redundant resume: no double-resume crash.
        let late = ContinuationGate()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            late.arm(c)
            late.resume()
            late.resume()
        }
    }
}
