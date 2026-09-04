import Foundation
import AnglesiteCore

/// A configurable `LocalContainerControl` fake shared by `AnglesiteCoreTests` and
/// `AnglesiteRemoteTests` — previously one copy per target. `startResult` defaults to a fixed
/// successful session so a bare `FakeLocalContainerControl()` (`AnglesiteRemoteTests`' usage)
/// works unconfigured, while every knob below stays available for a test that needs to script a
/// specific boot/exec outcome (`AnglesiteCoreTests`' usage).
public actor FakeLocalContainerControl: LocalContainerControl {
    public var startResult: Result<LocalContainerSession, LocalContainerError>
    public private(set) var stopped: [String] = []
    public private(set) var suspended: [String] = []
    public private(set) var startedRepos: [(siteID: String, repo: URL, ref: String)] = []
    /// Overrides `LocalContainerControl`'s default no-op so tests can assert
    /// `resetNetworking()` calls actually reach the control, not just that the call compiles.
    public private(set) var resetNetworkingCallCount = 0

    /// Lines replayed to `start`'s `onOutput` in order before it returns (or throws).
    public var startStdoutLines: [String]

    /// Canned result returned by `exec`. Defaults to a successful empty run.
    public var execResult: ContainerExecResult
    /// Lines replayed to `onOutput` in order before `exec` returns.
    public var execStdoutLines: [String]
    /// When set, `exec` throws this immediately — before appending to `execCalls` or replaying
    /// `execStdoutLines` — so a caller's throw path (e.g. draining a still-empty `AsyncStream`
    /// before rethrowing) can be exercised without a real container.
    public var execError: (any Error)?
    /// All `exec` invocations recorded for assertion.
    public private(set) var execCalls: [(siteID: String, argv: [String], env: [String: String], cwd: String)] = []

    /// Lines replayed to `execInteractive`'s `onOutput` (as `.stdout`) in order before it returns
    /// the handle — separate from `execStdoutLines`, which only feeds the older `exec`. Pass at
    /// construction (mirrors `startStdoutLines`/`execStdoutLines`) so a transport test can
    /// simulate the agent's first stdout lines arriving.
    public var execInteractiveStdoutLines: [String]
    /// All `execInteractive` invocations recorded for assertion.
    public private(set) var execInteractiveCalls: [(siteID: String, argv: [String], env: [String: String], cwd: String)] = []
    /// Data written to the most recently returned handle, recorded for assertion.
    public private(set) var execInteractiveWrites: [Data] = []
    /// Whether the most recently returned handle's `terminate()` was called.
    public private(set) var execInteractiveTerminated = false

    /// Canned result returned by `startWorkersDev`. Defaults to a successful fixed URL.
    public var startWorkersDevResult: Result<URL, LocalContainerError> = .success(URL(string: "http://127.0.0.1:51003")!)
    /// Lines replayed to `startWorkersDev`'s `onOutput` in order before it returns.
    public var startWorkersDevStdoutLines: [String] = []
    /// All `startWorkersDev` invocations recorded for assertion.
    public private(set) var startWorkersDevCalls: [(siteID: String, workers: [WorkerDescriptor])] = []
    /// All `stopWorkersDev` invocations recorded for assertion.
    public private(set) var stopWorkersDevCalls: [String] = []
    /// The `onState` callback captured from the most recent 4-param `startWorkersDev` call —
    /// tests `await` it directly to simulate supervisor transitions (crash-restart, failure);
    /// delivery has fully landed in the status center when the await returns.
    public private(set) var lastWorkersDevOnState: (@Sendable (WorkersDevProcessState) async -> Void)?

    /// `AnglesiteRemoteTests`' original convenience name for `startedRepos.count`.
    public var startCallCount: Int { startedRepos.count }
    /// `AnglesiteRemoteTests`' original convenience name for `stopped.count`.
    public var stopCallCount: Int { stopped.count }

    /// Actor-isolated setter: `startWorkersDevResult` can't be assigned from outside the actor.
    public func setStartWorkersDevResult(_ result: Result<URL, LocalContainerError>) {
        startWorkersDevResult = result
    }

    /// Actor-isolated setter, same reason as `setStartWorkersDevResult`.
    public func setStartWorkersDevStdoutLines(_ lines: [String]) {
        startWorkersDevStdoutLines = lines
    }

    /// `startResult` defaults to a fixed successful session — `AnglesiteRemoteTests`' bare
    /// `FakeLocalContainerControl()` never configures it.
    public init(
        startResult: Result<LocalContainerSession, LocalContainerError> = .success(LocalContainerSession(
            previewURL: URL(string: "http://127.0.0.1:4321")!,
            mcpURL: URL(string: "http://127.0.0.1:4399")!
        )),
        startStdoutLines: [String] = [],
        execResult: ContainerExecResult = ContainerExecResult(exitCode: 0, stdout: "", stderr: ""),
        execStdoutLines: [String] = [],
        execError: (any Error)? = nil,
        execInteractiveStdoutLines: [String] = []
    ) {
        self.startResult = startResult
        self.startStdoutLines = startStdoutLines
        self.execResult = execResult
        self.execStdoutLines = execStdoutLines
        self.execError = execError
        self.execInteractiveStdoutLines = execInteractiveStdoutLines
    }

    public func start(
        siteID: String,
        sourceRepo: URL,
        ref: String,
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> LocalContainerSession {
        startedRepos.append((siteID, sourceRepo, ref))
        for line in startStdoutLines { onOutput(line, .stdout) }
        return try startResult.get()
    }

    public func stop(siteID: String) async throws { stopped.append(siteID) }

    public func suspend(siteID: String) async throws { suspended.append(siteID) }

    public func resetNetworking() async { resetNetworkingCallCount += 1 }

    public func startWorkersDev(
        siteID: String,
        workers: [WorkerDescriptor],
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> URL {
        startWorkersDevCalls.append((siteID: siteID, workers: workers))
        for line in startWorkersDevStdoutLines { onOutput(line, .stdout) }
        return try startWorkersDevResult.get()
    }

    public func startWorkersDev(
        siteID: String,
        workers: [WorkerDescriptor],
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void,
        onState: @escaping @Sendable (WorkersDevProcessState) async -> Void
    ) async throws -> URL {
        lastWorkersDevOnState = onState
        return try await startWorkersDev(siteID: siteID, workers: workers, onOutput: onOutput)
    }

    public func stopWorkersDev(siteID: String) async throws {
        stopWorkersDevCalls.append(siteID)
    }

    public func exec(
        siteID: String,
        argv: [String],
        environment: [String: String],
        workingDirectory: String,
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> ContainerExecResult {
        if let execError { throw execError }
        execCalls.append((siteID: siteID, argv: argv, env: environment, cwd: workingDirectory))
        for line in execStdoutLines { onOutput(line, .stdout) }
        return execResult
    }

    public func execInteractive(
        siteID: String,
        argv: [String],
        environment: [String: String],
        workingDirectory: String,
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> InteractiveExecHandle {
        execInteractiveCalls.append((siteID: siteID, argv: argv, env: environment, cwd: workingDirectory))
        for line in execInteractiveStdoutLines { onOutput(line, .stdout) }
        return InteractiveExecHandle(
            write: { [weak self] data in await self?.recordExecInteractiveWrite(data) },
            terminate: { [weak self] in await self?.recordExecInteractiveTerminated() }
        )
    }

    private func recordExecInteractiveWrite(_ data: Data) { execInteractiveWrites.append(data) }
    private func recordExecInteractiveTerminated() { execInteractiveTerminated = true }
}
