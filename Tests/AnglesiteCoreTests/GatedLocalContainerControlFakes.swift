import Foundation
@testable import AnglesiteCore

actor BundleImportRecorder {
    struct Call: Sendable {
        let bundleURL: URL
        let commit: String
        let sourceDirectory: URL
    }

    private(set) var calls: [Call] = []
    let error: Error?

    init(error: Error? = nil) {
        self.error = error
    }

    func run(bundleURL: URL, commit: String, sourceDirectory: URL) throws {
        calls.append(.init(bundleURL: bundleURL, commit: commit, sourceDirectory: sourceDirectory))
        if let error { throw error }
    }
}

actor PersistenceGatedFakeLocalContainerControl: LocalContainerControl {
    private let result: Result<LocalContainerSession, LocalContainerError>
    private let execResult: ContainerExecResult
    private var parkedContinuation: CheckedContinuation<Void, Never>?
    private var gateContinuation: CheckedContinuation<Void, Never>?
    private var execParked = false

    init(result: Result<LocalContainerSession, LocalContainerError>, execResult: ContainerExecResult) {
        self.result = result
        self.execResult = execResult
    }

    func waitUntilExecParked() async {
        if execParked { return }
        await withCheckedContinuation { parkedContinuation = $0 }
    }

    func releaseExec() {
        gateContinuation?.resume()
        gateContinuation = nil
    }

    func start(
        siteID: String,
        sourceRepo: URL,
        ref: String,
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> LocalContainerSession {
        try result.get()
    }

    func stop(siteID: String) async throws {}

    func startWorkersDev(
        siteID: String,
        workers: [WorkerDescriptor],
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> URL {
        URL(string: "http://127.0.0.1:51003")!
    }

    func stopWorkersDev(siteID: String) async throws {}

    func exec(
        siteID: String,
        argv: [String],
        environment: [String: String],
        workingDirectory: String,
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> ContainerExecResult {
        execParked = true
        parkedContinuation?.resume()
        parkedContinuation = nil
        await withCheckedContinuation { continuation in
            gateContinuation = continuation
        }
        return execResult
    }

    // Not exercised by any test — this fake exists to test `exec`'s persistence-gating race,
    // not `execInteractive`. Trivial no-op handle, matching the other not-exercised conformances
    // in this file (`StopGatedFakeLocalContainerControl`, `GatedFakeLocalContainerControl`).
    func execInteractive(
        siteID: String,
        argv: [String],
        environment: [String: String],
        workingDirectory: String,
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> InteractiveExecHandle {
        InteractiveExecHandle(write: { _ in }, terminate: {})
    }
}

/// A `LocalContainerControl` whose `start` suspends until `release()` is called — for
/// deterministically interleaving a concurrent `stop()`/second `start()` while the first
/// `start()` is parked. Mirrors `GatedFakeSandboxControlClient`.
///
/// Note: the park/release rendezvous relies on Swift's cooperative executor not running the
/// spawned `start()` Task before `waitUntilParked()` installs its continuation. This matches the
/// pattern in `GatedFakeSandboxControlClient` and is sufficient for Swift Testing's executor.
/// The mirror image of `GatedFakeLocalContainerControl`: `start` succeeds immediately, while the
/// FIRST `stop` suspends until `releaseStop()` — for deterministically interleaving a superseding
/// `start()` while a `stop()`'s teardown is parked inside `control.stop(...)` (the rapid
/// Stop → Restart race from the PR #542 review). Subsequent `stop` calls pass straight through so
/// the superseding path can't deadlock on the gate.
actor StopGatedFakeLocalContainerControl: LocalContainerControl {
    private let result: Result<LocalContainerSession, LocalContainerError>
    private(set) var stopped: [String] = []
    private var parkedContinuation: CheckedContinuation<Void, Never>?
    private var gateContinuation: CheckedContinuation<Void, Never>?
    private var gateArmed = true

    init(result: Result<LocalContainerSession, LocalContainerError>) { self.result = result }

    func waitUntilStopParked() async {
        await withCheckedContinuation { cont in parkedContinuation = cont }
    }
    func releaseStop() { gateContinuation?.resume(); gateContinuation = nil }

    func start(
        siteID: String,
        sourceRepo: URL,
        ref: String,
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> LocalContainerSession {
        try result.get()
    }

    func stop(siteID: String) async throws {
        stopped.append(siteID)
        guard gateArmed else { return }
        gateArmed = false
        await withCheckedContinuation { cont in
            parkedContinuation?.resume()
            parkedContinuation = nil
            gateContinuation = cont
        }
    }

    func startWorkersDev(
        siteID: String,
        workers: [WorkerDescriptor],
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> URL {
        URL(string: "http://127.0.0.1:51003")!
    }

    func stopWorkersDev(siteID: String) async throws {}

    func exec(
        siteID: String,
        argv: [String],
        environment: [String: String],
        workingDirectory: String,
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> ContainerExecResult {
        ContainerExecResult(exitCode: 0, stdout: "", stderr: "")
    }

    func execInteractive(
        siteID: String,
        argv: [String],
        environment: [String: String],
        workingDirectory: String,
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> InteractiveExecHandle {
        InteractiveExecHandle(write: { _ in }, terminate: {})
    }
}

actor GatedFakeLocalContainerControl: LocalContainerControl {
    private let result: Result<LocalContainerSession, LocalContainerError>
    private(set) var stopped: [String] = []
    private var parkedContinuation: CheckedContinuation<Void, Never>?
    private var gateContinuation: CheckedContinuation<Void, Never>?

    init(result: Result<LocalContainerSession, LocalContainerError>) { self.result = result }

    func waitUntilParked() async {
        await withCheckedContinuation { cont in parkedContinuation = cont }
    }
    func release() { gateContinuation?.resume(); gateContinuation = nil }

    func start(
        siteID: String,
        sourceRepo: URL,
        ref: String,
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> LocalContainerSession {
        await withCheckedContinuation { cont in
            parkedContinuation?.resume()
            parkedContinuation = nil
            gateContinuation = cont
        }
        return try result.get()
    }
    func stop(siteID: String) async throws { stopped.append(siteID) }

    func startWorkersDev(
        siteID: String,
        workers: [WorkerDescriptor],
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> URL {
        URL(string: "http://127.0.0.1:51003")!
    }

    func stopWorkersDev(siteID: String) async throws {}

    func exec(
        siteID: String,
        argv: [String],
        environment: [String: String],
        workingDirectory: String,
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> ContainerExecResult {
        ContainerExecResult(exitCode: 0, stdout: "", stderr: "")
    }

    func execInteractive(
        siteID: String,
        argv: [String],
        environment: [String: String],
        workingDirectory: String,
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> InteractiveExecHandle {
        InteractiveExecHandle(write: { _ in }, terminate: {})
    }
}
