import Foundation
import Testing
import AnglesiteCore
@testable import AnglesiteContainer

private actor FakeGuestProcessHandle: GuestProcessHandle {
    private var waitContinuation: CheckedContinuation<Int32, Error>?
    private var pendingExitCode: Int32?
    private(set) var started = false
    private(set) var killed = false
    private(set) var deleted = false

    func start() async throws { started = true }

    func wait() async throws -> Int32 {
        if let code = pendingExitCode { pendingExitCode = nil; return code }
        return try await withCheckedThrowingContinuation { waitContinuation = $0 }
    }

    func kill() async throws { killed = true }
    func delete() async throws { deleted = true }

    /// Test control: makes the next (or currently-parked) `wait()` return `code`.
    func exit(code: Int32) {
        if let cont = waitContinuation {
            waitContinuation = nil
            cont.resume(returning: code)
        } else {
            pendingExitCode = code
        }
    }
}

private actor FakeGuestProcessLauncher: GuestProcessLauncher {
    private(set) var launchCalls: [(id: String, argv: [String])] = []
    /// One handle per launch, in call order — the test drives each one's `exit(code:)` directly.
    private(set) var handles: [FakeGuestProcessHandle] = []

    func launch(
        id: String,
        argv: [String],
        environment: [String: String],
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> any GuestProcessHandle {
        launchCalls.append((id: id, argv: argv))
        let handle = FakeGuestProcessHandle()
        handles.append(handle)
        return handle
    }
}

@Suite("GuestProcessSupervisor")
struct GuestProcessSupervisorTests {
    @Test("start() launches and reaches .running")
    func startReachesRunning() async throws {
        let launcher = FakeGuestProcessLauncher()
        let supervisor = GuestProcessSupervisor(
            launcher: launcher, id: "test", argv: ["true"], restartPolicy: .never, onOutput: { _, _ in })
        try await supervisor.start()
        var seen: [GuestProcessSupervisor.State] = []
        for await s in await supervisor.observe() { seen.append(s); if s == .running { break } }
        #expect(seen.last == .running)
        #expect(await launcher.launchCalls.count == 1)
    }

    @Test("a non-zero exit under .never gives up without restarting")
    func neverPolicyGivesUpOnNonZeroExit() async throws {
        let launcher = FakeGuestProcessLauncher()
        let supervisor = GuestProcessSupervisor(
            launcher: launcher, id: "test", argv: ["true"], restartPolicy: .never, onOutput: { _, _ in })
        try await supervisor.start()
        let stream = await supervisor.observe()
        var iterator = stream.makeAsyncIterator()
        while await iterator.next() != .running {}
        await launcher.handles[0].exit(code: 1)
        var final: GuestProcessSupervisor.State?
        while let s = await iterator.next() {
            final = s
            if case .failed = s { break }
        }
        guard case .failed = final else {
            Issue.record("expected .failed, got \(String(describing: final))")
            return
        }
        #expect(await launcher.launchCalls.count == 1)
    }

    @Test("a clean exit (code 0) under .never stops, not fails — clean exit is never a crash regardless of policy")
    func cleanExitUnderNeverStopsNotFails() async throws {
        let launcher = FakeGuestProcessLauncher()
        let supervisor = GuestProcessSupervisor(
            launcher: launcher, id: "test", argv: ["true"], restartPolicy: .never, onOutput: { _, _ in })
        try await supervisor.start()
        let stream = await supervisor.observe()
        var iterator = stream.makeAsyncIterator()
        while await iterator.next() != .running {}
        await launcher.handles[0].exit(code: 0)
        var final: GuestProcessSupervisor.State?
        while let s = await iterator.next() {
            final = s
            if s == .stopped { break }
        }
        #expect(final == .stopped)
        #expect(await launcher.launchCalls.count == 1)
    }

    @Test("a crash under .onCrash relaunches, up to maxAttempts, then gives up")
    func onCrashPolicyRestartsThenGivesUp() async throws {
        let launcher = FakeGuestProcessLauncher()
        let supervisor = GuestProcessSupervisor(
            launcher: launcher, id: "test", argv: ["true"],
            restartPolicy: .onCrash(maxAttempts: 2, baseBackoff: 0.01), onOutput: { _, _ in })
        try await supervisor.start()
        let stream = await supervisor.observe()
        var iterator = stream.makeAsyncIterator()
        while await iterator.next() != .running {}

        // Crash 1 → restarting(1) → running (relaunch #2)
        await launcher.handles[0].exit(code: 1)
        var sawRestarting1 = false
        while let s = await iterator.next() {
            if s == .restarting(attempt: 1) { sawRestarting1 = true }
            if s == .running, sawRestarting1 { break }
        }
        #expect(await launcher.launchCalls.count == 2)

        // Crash 2 → restarting(2) → running (relaunch #3)
        await launcher.handles[1].exit(code: 1)
        var sawRestarting2 = false
        while let s = await iterator.next() {
            if s == .restarting(attempt: 2) { sawRestarting2 = true }
            if s == .running, sawRestarting2 { break }
        }
        #expect(await launcher.launchCalls.count == 3)

        // Crash 3 → attempt 3 exceeds maxAttempts(2) → .failed, no further relaunch.
        await launcher.handles[2].exit(code: 1)
        var final: GuestProcessSupervisor.State?
        while let s = await iterator.next() {
            final = s
            if case .failed = s { break }
        }
        guard case .failed = final else {
            Issue.record("expected .failed after exhausting retries, got \(String(describing: final))")
            return
        }
        #expect(await launcher.launchCalls.count == 3)
    }

    @Test("a clean exit (code 0) under .onCrash stops without restarting — clean exit is never a crash")
    func cleanExitUnderOnCrashStopsWithoutRestarting() async throws {
        let launcher = FakeGuestProcessLauncher()
        let supervisor = GuestProcessSupervisor(
            launcher: launcher, id: "test", argv: ["true"],
            restartPolicy: .onCrash(maxAttempts: 3, baseBackoff: 0.01), onOutput: { _, _ in })
        try await supervisor.start()
        let stream = await supervisor.observe()
        var iterator = stream.makeAsyncIterator()
        while await iterator.next() != .running {}

        await launcher.handles[0].exit(code: 0)
        var final: GuestProcessSupervisor.State?
        while let s = await iterator.next() {
            final = s
            if s == .stopped { break }
        }
        #expect(final == .stopped)
        // No relaunch happened — a clean exit isn't a crash.
        #expect(await launcher.launchCalls.count == 1)
    }

    @Test("stop() suppresses the next restart — an intentional stop never relaunches")
    func stopSuppressesRestart() async throws {
        let launcher = FakeGuestProcessLauncher()
        let supervisor = GuestProcessSupervisor(
            launcher: launcher, id: "test", argv: ["true"],
            restartPolicy: .onCrash(maxAttempts: 5, baseBackoff: 0.01), onOutput: { _, _ in })
        try await supervisor.start()
        let stream = await supervisor.observe()
        var iterator = stream.makeAsyncIterator()
        while await iterator.next() != .running {}

        await supervisor.stop()
        #expect(await iterator.next() == .stopped)
        #expect(await launcher.handles[0].killed)

        // Give the (now-cancelled) supervise loop a beat to prove it does NOT relaunch.
        try await Task.sleep(for: .milliseconds(50)) // sleep-is-subject: negative assertion, no event to wait for
        #expect(await launcher.launchCalls.count == 1)
    }
}
