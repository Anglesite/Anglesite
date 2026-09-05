import Testing
import Foundation
import AnglesiteTestSupport
@testable import AnglesiteCore

struct ProcessSupervisorShutdownTests {
    @Test("A live child holds sudden termination disabled until shutdown")
    func liveChildBracketsSuddenTermination() async throws {
        let controller = SuddenTerminationController(disable: {}, enable: {})
        let supervisor = ProcessSupervisor(suddenTerminationController: controller)
        _ = try await supervisor.launch(
            source: "sudden-termination-test",
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exec sleep 30"],
            logCenter: LogCenter()
        )

        #expect(controller.activeLeaseCount == 1)
        await supervisor.shutdownAll(timeout: 2)
        #expect(controller.activeLeaseCount == 0)
    }

    @Test("Shutdown all terminates every supervised process") func shutdownAllTerminatesEverySupervisedProcess() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()

        var handles: [ProcessSupervisor.Handle] = []
        for i in 0..<3 {
            let h = try await supervisor.launch(
                source: "long-\(i)",
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "exec sleep 30"],
                logCenter: center
            )
            handles.append(h)
        }
        // Let them actually start.
        for h in handles {
            try await waitUntil("the process to report running") { await supervisor.isRunning(h) }
        }

        await supervisor.shutdownAll(timeout: 2)

        for h in handles {
            let reason = await supervisor.waitForExit(h)
            #expect(reason == .terminated)
            let running = await supervisor.isRunning(h)
            #expect(!running)
        }
    }

    @Test("Shutdown all on idle supervisor returns immediately") func shutdownAllOnIdleSupervisorReturnsImmediately() async {
        let supervisor = ProcessSupervisor()
        // No processes launched — must not hang.
        await supervisor.shutdownAll(timeout: 1)
    }

    @Test("Shutdown all stops restarting crash-looped process") func shutdownAllStopsRestartingCrashLoopedProcess() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        // A process that crashes immediately, configured to retry many times with a
        // small backoff. shutdownAll must break the restart loop, not wait it out.
        let handle = try await supervisor.launch(
            source: "crashloop",
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 3"],
            restartPolicy: .onCrash(maxAttempts: 100, baseBackoff: 0.2),
            logCenter: center
        )
        try? await Task.sleep(nanoseconds: 100_000_000)

        await supervisor.shutdownAll(timeout: 1)

        let reason = await supervisor.waitForExit(handle)
        #expect(reason == .terminated)
    }

    // MARK: waitForExitOrTerminate + group-wide escalation (#1758)

    /// Wait for `marker` to appear in `center` (bounded) — readiness sync only, never the assertion.
    private func awaitMarker(_ marker: String, in center: LogCenter) async -> Bool {
        (try? await waitUntil("marker '\(marker)'", timeout: .seconds(10)) {
            await center.snapshot().contains { $0.text == marker }
        }) != nil
    }

    @Test("waitForExitOrTerminate: a cancelled waiter resolves only once the child is dead and drained")
    func waitForExitOrTerminateKillsAndDrainsOnCancellation() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let handle = try await supervisor.launch(
            source: "cancel-wait",
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", SIGTERMTrapFixture.script],
            logCenter: center
        )
        #expect(await awaitMarker("__STARTED__", in: center), "fixture never started")

        let waiter = Task { await supervisor.waitForExitOrTerminate(handle) }
        try await Task.sleep(for: .milliseconds(100))   // let the waiter park on the exit continuation
        waiter.cancel()
        let reason = await waiter.value

        #expect(reason == .terminated)
        #expect(await supervisor.isRunning(handle) == false, "child must be gone when the cancelled wait resolves")
        let texts = await center.snapshot().map(\.text)
        #expect(texts.contains("__SIGTERM__"), "SIGTERM must have been delivered and its output drained before resolving: \(texts)")
        #expect(!texts.contains("__COMPLETED__"))
    }

    @Test("waitForExitOrTerminate: a waiter cancelled before it parks still kills the child")
    func waitForExitOrTerminateHandlesPreCancelledWaiter() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let handle = try await supervisor.launch(
            source: "cancel-early",
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", SIGTERMTrapFixture.script],
            logCenter: center
        )
        #expect(await awaitMarker("__STARTED__", in: center), "fixture never started")

        let waiter = Task { await supervisor.waitForExitOrTerminate(handle) }
        waiter.cancel()   // very likely before the task body has run at all
        let reason = await waiter.value

        #expect(reason == .terminated)
        #expect(await supervisor.isRunning(handle) == false)
        #expect(await center.snapshot().contains { $0.text == "__SIGTERM__" })
    }

    @Test("waitForExitOrTerminate: an uncancelled waiter gets the real exit reason")
    func waitForExitOrTerminateReturnsNaturalExit() async throws {
        let supervisor = ProcessSupervisor()
        let handle = try await supervisor.launch(
            source: "natural-exit",
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 7"],
            logCenter: LogCenter()
        )
        #expect(await supervisor.waitForExitOrTerminate(handle) == .exited(code: 7))
    }

    @Test("terminate sweeps a straggler that outlives its leader while holding the log pipes")
    func terminateSweepsPipeHoldingStraggler() async throws {
        // `trap '' TERM` is inherited across exec, so the backgrounded `sleep` ignores the
        // group-wide SIGTERM; the leader then exits on its own, leaving the orphan holding our
        // stdout pipe open. Without the group sweep the supervision loop could only finalize —
        // and `waitForExit` only resolve — once the orphan exited by itself (60 s here).
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let handle = try await supervisor.launch(
            source: "straggler",
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; sleep 60 & echo __STARTED__; exit 0"],
            logCenter: center
        )
        #expect(await awaitMarker("__STARTED__", in: center), "fixture never started")

        let start = ContinuousClock.now
        await supervisor.terminate(handle, timeout: 1)
        _ = await supervisor.waitForExit(handle)
        #expect(ContinuousClock.now - start < .seconds(30), "sweep must not wait for the orphan's own exit")
        #expect(await supervisor.isRunning(handle) == false)
    }
}
