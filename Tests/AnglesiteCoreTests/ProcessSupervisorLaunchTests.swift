import Testing
import Foundation
import AnglesiteTestSupport
@testable import AnglesiteCore

struct ProcessSupervisorLaunchTests {
    @Test("Launch streams stdout lines to log center") func launchStreamsStdoutLinesToLogCenter() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let handle = try await supervisor.launch(
            source: "stdout-test",
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'one\\ntwo\\nthree\\n'"],
            logCenter: center
        )
        let reason = await supervisor.waitForExit(handle)

        #expect(reason == .exited(code: 0))
        let lines = await center.snapshot().filter { $0.source == "stdout-test" && $0.stream == .stdout }
        #expect(lines.map(\.text) == ["one", "two", "three"])
    }

    @Test("Launch separates stderr from stdout") func launchSeparatesStderrFromStdout() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let handle = try await supervisor.launch(
            source: "stderr-test",
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'out\\n'; printf 'err\\n' 1>&2"],
            logCenter: center
        )
        _ = await supervisor.waitForExit(handle)

        let snapshot = await center.snapshot().filter { $0.source == "stderr-test" }
        let outs = snapshot.filter { $0.stream == .stdout }.map(\.text)
        let errs = snapshot.filter { $0.stream == .stderr }.map(\.text)
        #expect(outs == ["out"])
        #expect(errs == ["err"])
    }

    /// Regression: `waitForExit` must not resume until every byte read from the child's
    /// stdout/stderr is in `LogCenter`. The previous pump fired untracked
    /// `Task { await logCenter.append }` from the readabilityHandler, so a snapshot taken
    /// immediately after `waitForExit` could miss the tail of the output — `DeployCommand`
    /// papered over the gap with a 100ms sleep, and `DeployCommandTests` still flaked under
    /// CI load. This test runs the burst-then-exit pattern that triggered the flake (lots of
    /// output crammed into the last few milliseconds before exit) and asserts that the very
    /// last line is present in the snapshot with zero post-exit sleep.
    @Test("Snapshot includes last line after wait for exit without sleep") func snapshotIncludesLastLineAfterWaitForExitWithoutSleep() async throws {
        for _ in 0..<25 {
            let supervisor = ProcessSupervisor()
            let center = LogCenter()
            let handle = try await supervisor.launch(
                source: "drain-race",
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    // Burst a few lines, then write a sentinel right before exiting. If the
                    // pump ever loses the tail, this test will fail on the sentinel.
                    "for i in 1 2 3 4 5 6 7 8 9 10; do printf 'line %s\\n' $i; done; printf 'SENTINEL\\n'"
                ],
                logCenter: center
            )
            _ = await supervisor.waitForExit(handle)
            let lines = await center.snapshot()
                .filter { $0.source == "drain-race" && $0.stream == .stdout }
                .map(\.text)
            #expect(lines.last == "SENTINEL", "last stdout line must be in LogCenter the moment waitForExit returns")
            #expect(lines.count == 11, "all lines must be present, none lost: \(lines)")
        }
    }

    @Test("Wait for exit reports non-zero code") func waitForExitReportsNonZeroCode() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let handle = try await supervisor.launch(
            source: "exit-test",
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 9"],
            logCenter: center
        )
        let reason = await supervisor.waitForExit(handle)
        #expect(reason == .exited(code: 9))
    }

    @Test("Terminate stops long-running process") func terminateStopsLongRunningProcess() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let handle = try await supervisor.launch(
            source: "long",
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exec sleep 30"],
            logCenter: center
        )
        // Let it actually start.
        try await waitUntil("the process to report running") { await supervisor.isRunning(handle) }

        await supervisor.terminate(handle, timeout: 2)
        let reason = await supervisor.waitForExit(handle)
        #expect(reason == .terminated)
        let runningAfter = await supervisor.isRunning(handle)
        #expect(!runningAfter)
    }

    @Test("Restart on crash gives up after max attempts") func restartOnCrashGivesUpAfterMaxAttempts() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let handle = try await supervisor.launch(
            source: "crashy",
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo boom 1>&2; exit 2"],
            restartPolicy: .onCrash(maxAttempts: 2, baseBackoff: 0.0),
            logCenter: center
        )
        let reason = await supervisor.waitForExit(handle)

        #expect(reason == .retriesExhausted(lastCode: 2))
        let boomCount = await center.snapshot().filter {
            $0.source == "crashy" && $0.text == "boom"
        }.count
        // Initial attempt + 2 retries = 3 emissions of "boom".
        #expect(boomCount == 3)
    }

    @Test("Restart on crash stops after clean exit") func restartOnCrashStopsAfterCleanExit() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let handle = try await supervisor.launch(
            source: "clean",
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 0"],
            restartPolicy: .onCrash(maxAttempts: 5, baseBackoff: 0.0),
            logCenter: center
        )
        let reason = await supervisor.waitForExit(handle)
        #expect(reason == .exited(code: 0))
    }

    @Test("On respawn fires once per successful restart") func onRespawnFiresOncePerSuccessfulRestart() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let respawns = RespawnCounter()
        let handle = try await supervisor.launch(
            source: "respawn-test",
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 4"],
            restartPolicy: .onCrash(maxAttempts: 3, baseBackoff: 0.0),
            onRespawn: { await respawns.bump() },
            logCenter: center
        )
        let reason = await supervisor.waitForExit(handle)

        #expect(reason == .retriesExhausted(lastCode: 4))
        // Initial spawn doesn't count; 3 retries → 3 respawn callbacks.
        let count = await respawns.value
        #expect(count == 3)
    }

    @Test("On respawn not called when process never crashes") func onRespawnNotCalledWhenProcessNeverCrashes() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let respawns = RespawnCounter()
        let handle = try await supervisor.launch(
            source: "no-respawn",
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 0"],
            restartPolicy: .onCrash(maxAttempts: 3, baseBackoff: 0.0),
            onRespawn: { await respawns.bump() },
            logCenter: center
        )
        _ = await supervisor.waitForExit(handle)
        let count = await respawns.value
        #expect(count == 0)
    }

    @Test("Launch attach stdin allows writes") func launchAttachStdinAllowsWrites() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        // `cat` echoes whatever we feed it; then we close stdin and it exits cleanly.
        let handle = try await supervisor.launch(
            source: "cat",
            executable: URL(fileURLWithPath: "/bin/cat"),
            arguments: [],
            attachStdin: true,
            logCenter: center
        )
        let stdin = try #require(await supervisor.stdinWriter(handle), "expected stdin writer")
        try stdin.writer.write(contentsOf: Data("hello\n".utf8))
        try stdin.writer.close()

        let reason = await supervisor.waitForExit(handle)

        #expect(reason == .exited(code: 0))
        let lines = await center.snapshot().filter { $0.source == "cat" && $0.stream == .stdout }.map(\.text)
        #expect(lines == ["hello"])
    }
}

private actor RespawnCounter {
    private(set) var value = 0
    func bump() { value += 1 }
}
