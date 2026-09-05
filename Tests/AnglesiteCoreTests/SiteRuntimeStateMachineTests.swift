import Testing
import Foundation
import AnglesiteTestSupport
@testable import AnglesiteCore

/// Focused spec for the shared `SiteRuntimeStateMachine` plumbing extracted from the three
/// `SiteRuntime` conformers (#821). These cases mirror the observer/dedup/generation-guard tests
/// that used to live redundantly in `LocalContainerSiteRuntimeTests` and
/// `RemoteSandboxSiteRuntimeTests` — this is now the one place that behavior is specified.
struct SiteRuntimeStateMachineTests {
    // MARK: - Initial state / observe

    @Test("starts at .idle")
    func startsIdle() {
        let machine = SiteRuntimeStateMachine()
        #expect(machine.state == .idle)
    }

    @Test("observe replays the current state immediately")
    func observeReplaysCurrentState() async {
        let machine = SiteRuntimeStateMachine()
        machine.setState(.failed(siteID: "s1", message: "boom"))

        var iterator = machine.observe().makeAsyncIterator()
        #expect(await iterator.next() == .failed(siteID: "s1", message: "boom"))
    }

    @Test("a live observer sees every transition in order")
    func liveObserverSeesTransitionsInOrder() async {
        let machine = SiteRuntimeStateMachine()
        var iterator = machine.observe().makeAsyncIterator()
        #expect(await iterator.next() == .idle)

        machine.setState(.starting(siteID: "s1"))
        #expect(await iterator.next() == .starting(siteID: "s1"))

        let url = URL(string: "http://127.0.0.1:1")!
        machine.setState(.ready(siteID: "s1", url: url))
        #expect(await iterator.next() == .ready(siteID: "s1", url: url))
    }

    @Test("fan-out: every registered observer receives the same transitions")
    func fanOutToMultipleObservers() async {
        let machine = SiteRuntimeStateMachine()
        var first = machine.observe().makeAsyncIterator()
        var second = machine.observe().makeAsyncIterator()
        #expect(await first.next() == .idle)
        #expect(await second.next() == .idle)

        machine.setState(.starting(siteID: "s1"))
        #expect(await first.next() == .starting(siteID: "s1"))
        #expect(await second.next() == .starting(siteID: "s1"))
    }

    // MARK: - setState dedup

    @Test("setState dedups against the current value")
    func setStateDedupsAgainstCurrentValue() async {
        let machine = SiteRuntimeStateMachine()
        let stream = machine.observe()
        let collector = StateMachineCollector()

        let drainTask = Task {
            var count = 0
            for await s in stream {
                await collector.append(s)
                count += 1
                if count >= 2 { break }
            }
        }

        // Redundant .idle must be swallowed — the only delivery is observe()'s initial replay.
        machine.setState(.idle)

        drainTask.cancel()
        _ = await drainTask.result
        #expect(await collector.states == [.idle])
    }

    // MARK: - Observer removal

    @Test("removeObserver: cancelling the consumer's task unregisters it")
    func observerRemovedWhenConsumerCancels() async throws {
        let machine = SiteRuntimeStateMachine()
        let stream = machine.observe()
        #expect(machine.observerCount == 1)

        let drainTask = Task {
            for await _ in stream { }
        }
        drainTask.cancel()
        _ = await drainTask.result

        try await waitUntil("the cancelled observer to unregister") { machine.observerCount == 0 }
    }

    // MARK: - Generation guard

    @Test("beginAttempt returns strictly increasing generations")
    func beginAttemptIncreasesGeneration() {
        let machine = SiteRuntimeStateMachine()
        let first = machine.beginAttempt()
        let second = machine.beginAttempt()
        #expect(second == first + 1)
    }

    @Test("currentGeneration reads without bumping")
    func currentGenerationDoesNotBump() {
        let machine = SiteRuntimeStateMachine()
        let gen = machine.beginAttempt()
        #expect(machine.currentGeneration == gen)
        #expect(machine.currentGeneration == gen)
    }

    @Test("isCurrent is true only for the latest generation")
    func isCurrentReflectsOnlyLatestGeneration() {
        let machine = SiteRuntimeStateMachine()
        let stale = machine.beginAttempt()
        let latest = machine.beginAttempt()
        #expect(!machine.isCurrent(stale))
        #expect(machine.isCurrent(latest))
    }

    @Test("settle applies the state when gen is current")
    func settleAppliesWhenCurrent() {
        let machine = SiteRuntimeStateMachine()
        let gen = machine.beginAttempt()
        machine.settle(gen: gen, to: .idle)
        #expect(machine.state == .idle)

        let gen2 = machine.beginAttempt()
        machine.settle(gen: gen2, to: .failed(siteID: "s1", message: "x"))
        #expect(machine.state == .failed(siteID: "s1", message: "x"))
    }

    @Test("settle drops a stale result instead of clobbering the current state")
    func settleDropsStaleResult() {
        let machine = SiteRuntimeStateMachine()
        let stale = machine.beginAttempt()
        let latest = machine.beginAttempt()
        machine.settle(gen: latest, to: .starting(siteID: "s2"))

        // The stale attempt's settle must be a no-op: it must not clobber the newer attempt's state.
        machine.settle(gen: stale, to: .idle)
        #expect(machine.state == .starting(siteID: "s2"))
    }

    // MARK: - beginStarting (the "wedged boot" dedup-defeat)

    @Test("beginStarting from .idle transitions directly to .starting")
    func beginStartingFromIdle() async {
        let machine = SiteRuntimeStateMachine()
        let stream = machine.observe()
        let collector = StateMachineCollector()
        let drainTask = Task {
            for await s in stream {
                await collector.append(s)
                if case .starting = s { break }
            }
        }

        _ = machine.beginStarting(siteID: "s1")
        await drainTask.value

        // Only the initial .idle replay, then a single .starting — no forced transient .idle when
        // there was nothing to "un-stick".
        #expect(await collector.states == [.idle, .starting(siteID: "s1")])
    }

    @Test("beginStarting re-entering .starting for the SAME site forces a transient .idle first")
    func beginStartingSameSiteForcesTransientIdle() async {
        let machine = SiteRuntimeStateMachine()
        _ = machine.beginStarting(siteID: "s1")

        let stream = machine.observe()
        let collector = StateMachineCollector()
        let drainTask = Task {
            var count = 0
            for await s in stream {
                await collector.append(s)
                count += 1
                if count >= 3 { break }
            }
        }

        // Re-entering .starting(siteID: "s1") while already .starting(siteID: "s1") would otherwise
        // be silently swallowed by setState's dedup — the wedged-boot Restart case (#542-adjacent).
        _ = machine.beginStarting(siteID: "s1")

        drainTask.cancel()
        _ = await drainTask.result
        #expect(await collector.states == [.starting(siteID: "s1"), .idle, .starting(siteID: "s1")])
    }

    @Test("beginStarting for a DIFFERENT site does not force a transient .idle")
    func beginStartingDifferentSiteSkipsTransientIdle() async {
        let machine = SiteRuntimeStateMachine()
        _ = machine.beginStarting(siteID: "s1")

        let stream = machine.observe()
        let collector = StateMachineCollector()
        let drainTask = Task {
            var count = 0
            for await s in stream {
                await collector.append(s)
                count += 1
                if count >= 2 { break }
            }
        }

        _ = machine.beginStarting(siteID: "s2")

        drainTask.cancel()
        _ = await drainTask.result
        #expect(await collector.states == [.starting(siteID: "s1"), .starting(siteID: "s2")])
    }

    @Test("beginStarting bumps the generation")
    func beginStartingBumpsGeneration() {
        let machine = SiteRuntimeStateMachine()
        let before = machine.beginAttempt()
        let started = machine.beginStarting(siteID: "s1")
        #expect(started == before + 1)
        #expect(machine.isCurrent(started))
        #expect(!machine.isCurrent(before))
    }
}

/// Test-only collector for `SiteRuntimeState` sequences (avoids Sendable warnings across the
/// drain `Task`), mirroring `StateCollector` in `RemoteSandboxSiteRuntimeTests`.
actor StateMachineCollector {
    private(set) var states: [SiteRuntimeState] = []
    func append(_ s: SiteRuntimeState) { states.append(s) }
}
