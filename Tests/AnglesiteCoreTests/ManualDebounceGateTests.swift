import Foundation
import Testing
import AnglesiteTestSupport

/// Contract tests for the shared test-support gate and poller (#1721 review): the debounce
/// suites that drive them assume cancellation is both honoured and counted, and that a timeout
/// surfaces as a thrown error rather than a silent hang.
@Suite("ManualDebounceGate / waitUntil (test support)")
struct ManualDebounceGateTests {
    @Test("release elapses every armed timer at once")
    func releaseElapsesArmedTimers() async throws {
        let gate = ManualDebounceGate()
        let first = Task { try await gate.sleep() }
        let second = Task { try await gate.sleep() }
        try await waitUntil("both timers armed") { await gate.armedCount() == 2 }

        await gate.release()
        try await first.value
        try await second.value
        #expect(await gate.armedCount() == 0)
        #expect(await gate.cancelledCount() == 0)
    }

    @Test("cancelling a parked timer throws CancellationError, disarms it, and is counted")
    func cancelWhileParkedIsCounted() async throws {
        let gate = ManualDebounceGate()
        let timer = Task { try await gate.sleep() }
        try await waitUntil("timer armed") { await gate.armedCount() == 1 }

        timer.cancel()
        await #expect(throws: CancellationError.self) { try await timer.value }
        #expect(await gate.armedCount() == 0)
        #expect(await gate.cancelledCount() == 1)
    }

    /// The race the file-private predecessor of this gate could lose: cancellation landing before
    /// `park` stored a continuation. A task added to an already-cancelled group is created
    /// cancelled, which forces that ordering deterministically — a plain `Task` + `cancel()`
    /// would only hit it by luck.
    @Test("a timer whose task was cancelled before it parked still throws and is counted")
    func cancelBeforeParkIsCounted() async throws {
        let gate = ManualDebounceGate()
        let outcome: Result<Void, any Error> = await withThrowingTaskGroup(of: Void.self) { group in
            group.cancelAll()
            group.addTask { try await gate.sleep() }
            do {
                try await group.waitForAll()
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        guard case .failure(let error) = outcome else {
            Issue.record("a pre-cancelled timer completed instead of throwing")
            return
        }
        #expect(error is CancellationError)
        #expect(await gate.armedCount() == 0)
        #expect(await gate.cancelledCount() == 1)
    }

    @Test("waitUntil returns as soon as the condition holds")
    func waitUntilReturnsOnCondition() async throws {
        let counter = Counter()
        let bump = Task { await counter.increment() }
        try await waitUntil("counter bumped", timeout: .seconds(5)) { await counter.value == 1 }
        await bump.value
        #expect(await counter.value == 1)
    }

    @Test("waitUntil throws WaitUntilTimeout, naming the condition, when the deadline passes")
    func waitUntilThrowsOnTimeout() async {
        await #expect(throws: WaitUntilTimeout.self) {
            try await waitUntil("a condition that never holds", timeout: .milliseconds(50)) { false }
        }
        do {
            try await waitUntil("the impossible", timeout: .milliseconds(20)) { false }
        } catch let timeout as WaitUntilTimeout {
            #expect(timeout.what == "the impossible")
            #expect(timeout.description.contains("the impossible"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }
}
