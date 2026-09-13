import Foundation

/// Spawns and supervises subprocesses (git, gh, container tooling, and other non-Node helpers).
///
/// All subprocess spawning in the app goes through this actor. Direct `Process()` use from views or
/// other modules is not allowed — it would bypass log streaming and shutdown handling.
///
/// This is a thin **facade** over a `SupervisorBackend`. The actual spawn and supervision
/// implementation lives in `InProcessBackend`; the app is sandboxed and spawns directly while
/// holding a per-window security-scoped grant for site packages.
///
/// The public API below is unchanged from the pre-split supervisor; every caller and test keeps
/// working. Each method builds a `SpawnSpec` and delegates to `self.backend`. `Handle.id` and the
/// backend's `SpawnedProcessHandle.id` are the same UUID, so the facade maps between them for free.
///
/// Two flavors of spawn:
///   - `run(...)` — fire-and-await for short-lived commands; returns captured stdout/stderr/exitCode.
///   - `launch(...)` — long-running supervised process; streams output into a `LogCenter`, exposes a
///     `Handle` for `terminate(_:)` / `waitForExit(_:)`, and honors `RestartPolicy` on crash.
public actor ProcessSupervisor {
    /// App-wide supervisor. The UI and app delegate share this so that `shutdownAll()` on quit
    /// reaches every child the app spawned. Tests build their own instances.
    public static let shared = ProcessSupervisor()

    /// Default SIGTERM→SIGKILL escalation grace period for `terminate`/`waitForExitOrTerminate`/
    /// `shutdownAll` (#1801).
    public static let defaultTerminationGrace: TimeInterval = 5
    /// Faster escalation grace period for child processes whose teardown shouldn't block a caller
    /// for the full ``defaultTerminationGrace`` — used by `StdioTransport.close()` and
    /// `PodmanContainerControl`'s interactive-exec teardown (#1801).
    public static let fastTerminationGrace: TimeInterval = 2

    /// Neutralize `SIGPIPE` process-wide. Every child's stdin pipe is owned here; if a child closes
    /// its read end (crash/exit) while we're mid-write, the default `SIGPIPE` disposition terminates
    /// the **whole process** with signal 13 — which under `swift test --parallel` aborts the entire
    /// test run with no failing-test marker. A no-op handler makes the write fail with `EPIPE`
    /// instead, which `FileHandle`/backend writes already surface or absorb.
    ///
    /// We install a no-op handler rather than `SIG_IGN` deliberately: the Swift-vended
    /// `Darwin.SIG_IGN` constant is exported from the `libswift_DarwinFoundation3` overlay, which the
    /// macOS-26 CI runners don't ship — referencing it makes the whole test bundle fail to load
    /// ("Library not loaded: libswift_DarwinFoundation3.dylib"). A non-capturing closure handler
    /// avoids that symbol entirely while achieving the same crash-suppression. Installed exactly once
    /// (Swift evaluates a `static let` lazily and thread-safely) the first time any supervisor is
    /// constructed — before any child can exist — so both the app and the test process are covered.
    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, { _ in }) }()

    private let backend: SupervisorBackend

    private let suddenTerminationController: SuddenTerminationController
    private var processLeases: [UUID: SuddenTerminationController.Lease] = [:]

    /// Environment for spawns that don't pass one. Injectable for tests.
    private let defaultEnvironment: @Sendable () -> [String: String]?

    /// Source-compat re-exports. These used to be nested types; they now live at the protocol layer
    /// (so the backend can speak them too), re-exposed here so existing call sites such as
    /// `ProcessSupervisor.RestartPolicy.onCrash(...)` and `ProcessSupervisor.ExitReason` compile
    /// unchanged.
    public typealias RestartPolicy = AnglesiteCore.RestartPolicy
    /// Source-compat re-export of ``ProcessExitReason`` — see ``RestartPolicy`` for why these
    /// aliases exist.
    public typealias ExitReason = AnglesiteCore.ProcessExitReason
    /// Source-compat re-export of the module-level `RespawnHandler` — see ``RestartPolicy`` for
    /// why these aliases exist.
    public typealias RespawnHandler = AnglesiteCore.RespawnHandler

    /// `Handle.source` is preserved (the backend's opaque handle doesn't carry it), so map by `id`.
    private func backendHandle(for handle: Handle) -> SpawnedProcessHandle {
        SpawnedProcessHandle(id: handle.id, pid: 0)
    }

    /// Convenience for the app and tests: the default in-process backend. The app is sandboxed and
    /// still uses subprocesses for non-Node helper tools, holding a per-`SiteWindow`
    /// security-scoped grant so spawned children inherit folder access. iOS has no
    /// `Foundation.Process`, so `InProcessBackend` compiles out there (#71) and the remote-only
    /// client gets `UnavailableProcessBackend` — every spawn fails capability-flagged; the iOS
    /// runtime selection never reaches this backend in normal operation.
    public init(suddenTerminationController: SuddenTerminationController = .shared) {
        _ = Self.ignoreSIGPIPE
        #if os(iOS)
        self.backend = UnavailableProcessBackend()
        #else
        self.backend = InProcessBackend()
        #endif
        self.defaultEnvironment = { nil }
        self.suddenTerminationController = suddenTerminationController
    }

    /// Inject a backend explicitly (tests, future MAS wiring); `defaultEnvironment` applies to spawns that don't pass one.
    public init(backend: SupervisorBackend,
                defaultEnvironment: @escaping @Sendable () -> [String: String]? = { nil },
                suddenTerminationController: SuddenTerminationController = .shared) {
        _ = Self.ignoreSIGPIPE
        self.backend = backend
        self.defaultEnvironment = defaultEnvironment
        self.suddenTerminationController = suddenTerminationController
    }

    // MARK: One-shot run

    /// Captured outcome of a one-shot
    /// ``run(source:executable:arguments:environment:currentDirectoryURL:logging:logCenter:)`` or
    /// ``runDetaching(source:executable:arguments:environment:currentDirectoryURL:logging:logCenter:)``.
    ///
    /// A nonzero exit is *not* thrown — short-lived tools routinely use exit codes as answers
    /// (e.g. `git diff --quiet`), so callers inspect ``exitCode`` themselves.
    public struct RunResult: Sendable, Equatable {
        /// Everything the process wrote to stdout, decoded as UTF-8 (empty on decode failure).
        public let stdout: String
        /// Everything the process wrote to stderr, decoded as UTF-8 (empty on decode failure).
        public let stderr: String
        /// The process's exit status. `0` means success by convention; interpreting anything
        /// else is the caller's job.
        public let exitCode: Int32

        /// Memberwise initializer — public so tests and fake backends can fabricate results.
        public init(stdout: String, stderr: String, exitCode: Int32) {
            self.stdout = stdout
            self.stderr = stderr
            self.exitCode = exitCode
        }
    }

    /// Failures the supervisor surfaces to callers, translated from the backend's
    /// ``SupervisorBackendError`` so call sites don't couple to the backend seam.
    public enum SupervisorError: Error, Sendable {
        /// The process could not be spawned (missing executable, sandbox denial, backend
        /// unavailable). The underlying error carries the backend's message.
        case spawnFailed(underlying: Error)
        /// The ``Handle`` doesn't correspond to a live supervised process — it already exited
        /// and was reaped, or was never launched by this supervisor instance.
        case unknownHandle
    }

    /// How a one-shot ``run(source:executable:arguments:environment:currentDirectoryURL:logging:logCenter:)``
    /// reports the child's output to the debug pane (#1966).
    ///
    /// "Logs are sacred" (CLAUDE.md): every spawned subprocess streams stdout+stderr into the
    /// debug pane. `launch` always did; `run` used to hand the captured output back and leave
    /// forwarding to each call site, and an audit found eight that never did. The default is
    /// now to stream, and the two ways out are explicit cases with a mandatory payload — so a
    /// future secret-bearing call can't disable logging by simply omitting a parameter, and a
    /// `grep` for `.redacted(` / `.relayed(` lists every exception with its stated reason.
    ///
    /// Whatever the mode, the supervisor still records a `[supervisor] …` marker line under the
    /// run's `source` when the executable can't be spawned (executable path and OS error only,
    /// never argv) and when it exits non-zero, so a failed run is always traceable in the pane.
    public enum RunLogging: Sendable, Equatable {
        /// Stream every stdout/stderr line into the `LogCenter` under the run's `source` as it
        /// arrives — same live path `launch` uses. The default.
        case streamed
        /// The output itself carries a secret (a token echoed by a CLI, credentials in a URL git
        /// prints back) and must not reach the debug pane. Only a one-line marker naming
        /// `reason` and the exit code is logged, so the pane still shows that the process ran.
        /// Argv is never logged in any mode — this case is for *output* that leaks, not
        /// arguments.
        case redacted(reason: String)
        /// The caller forwards the captured output to the `LogCenter` itself through a
        /// protocol-mandated path (e.g. `LocalContainerControl.exec`'s `onOutput` callback, whose
        /// macOS implementation receives guest output that never was a host subprocess), so
        /// streaming here would duplicate every line under a second source. `via` names that
        /// path for the reader. Nothing is logged on a clean exit; a non-zero exit still gets
        /// the marker line.
        case relayed(via: String)
    }

    /// Spawns `executable`, waits for it to exit, returns captured stdout/stderr/exitCode.
    ///
    /// Both pipes are drained concurrently so output larger than the pipe buffer (~64KB) does not
    /// deadlock. Every line is streamed into `logCenter` under `source` *while* the child runs
    /// (see ``RunLogging``), and the last line has landed by the time this returns — a caller can
    /// `snapshot()` immediately afterwards. For long-running processes use `launch(...)`; for a
    /// command that forks a daemon which outlives it, use
    /// ``runDetaching(source:executable:arguments:environment:currentDirectoryURL:logging:logCenter:)``.
    ///
    /// - Parameters:
    ///   - source: The `LogCenter` tag for this run's output (the Debug pane's Source-picker
    ///     key), e.g. `"scaffold"` or `"podman"`. Required, like `launch`'s, so no call site can
    ///     forget to name its output.
    ///   - executable: Absolute path to the binary; never `PATH`-resolved here.
    ///   - arguments: Passed verbatim (no shell), so no quoting concerns.
    ///   - environment: The child's whole environment, or `nil` to use the supervisor's default
    ///     (which itself defaults to inheriting the app's).
    ///   - currentDirectoryURL: The child's working directory, or `nil` to inherit.
    ///   - logging: See ``RunLogging``. Defaults to streaming.
    ///   - logCenter: Where the output (and the supervisor's marker lines) go. Defaults to the
    ///     app-wide `LogCenter.shared`; tests pass their own.
    /// - Returns: The captured output and exit code. A non-zero exit is not an error.
    /// - Throws: ``SupervisorError/spawnFailed(underlying:)`` when the process can't be started.
    public func run(
        source: String,
        executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil,
        logging: RunLogging = .streamed,
        logCenter: LogCenter = .shared
    ) async throws -> RunResult {
        let spec = SpawnSpec(
            executable: executable,
            arguments: arguments,
            environment: environment ?? defaultEnvironment(),
            workingDirectory: currentDirectoryURL,
            logSource: source
        )
        let backend = self.backend
        return try await oneShot(spec, logging: logging, logCenter: logCenter) { spec, streamTarget in
            try await backend.runOneShot(spec, logCenter: streamTarget)
        }
    }

    /// Like ``run(source:executable:arguments:environment:currentDirectoryURL:logging:logCenter:)``,
    /// for a command that forks a daemon which outlives it — `podman run -d` leaves `conmon`
    /// behind, and `Foundation.Process`'s exit detection then hangs indefinitely on Linux (see
    /// `PodmanContainerControl.start`). The backend spawns with `posix_spawn`/`waitpid` and
    /// captures stdout/stderr through files instead of pipes (a pipe wouldn't see EOF until the
    /// daemon grandchild let go of it — the same hang in different clothes), so the output can
    /// only be replayed into `logCenter` after exit rather than streamed live. Everything else —
    /// the sudden-termination lease, the ``RunLogging`` contract, the marker lines, the error
    /// translation — matches `run`. This exists so that the one spawn that can't go through
    /// `Process` still goes through the supervisor rather than through raw C at a call site.
    ///
    /// - Parameters: Identical to `run`'s. `environment: nil` resolves to the supervisor's
    ///   default, else the app's own environment — the child never starts with an empty one.
    /// - Returns: The captured output and exit code; a death by signal is reported as
    ///   `128 + signal`, the shell convention.
    /// - Throws: ``SupervisorError/spawnFailed(underlying:)`` when the process can't be started,
    ///   including when the backend has no `posix_spawn` (iOS).
    public func runDetaching(
        source: String,
        executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil,
        logging: RunLogging = .streamed,
        logCenter: LogCenter = .shared
    ) async throws -> RunResult {
        let spec = SpawnSpec(
            executable: executable,
            arguments: arguments,
            environment: environment ?? defaultEnvironment(),
            workingDirectory: currentDirectoryURL,
            logSource: source
        )
        let backend = self.backend
        return try await oneShot(spec, logging: logging, logCenter: logCenter) { spec, streamTarget in
            let result = try await backend.runDetaching(spec)
            if let streamTarget {
                await Self.replay(result, source: spec.logSource, into: streamTarget)
            }
            return result
        }
    }

    /// Shared body of `run`/`runDetaching`: holds the sudden-termination lease across the spawn,
    /// resolves ``RunLogging`` into the backend's optional stream target, and writes the
    /// `[supervisor]` marker lines. `spawn` does the actual work and receives the `LogCenter` to
    /// stream into (`nil` when the mode withholds output).
    private func oneShot(
        _ spec: SpawnSpec,
        logging: RunLogging,
        logCenter: LogCenter,
        spawn: (SpawnSpec, LogCenter?) async throws -> ProcessResult
    ) async throws -> RunResult {
        let suddenTerminationLease = suddenTerminationController.acquire()
        defer { suddenTerminationLease.release() }
        let name = spec.executable.lastPathComponent
        let streamTarget: LogCenter? = logging == .streamed ? logCenter : nil
        let result: ProcessResult
        do {
            result = try await spawn(spec, streamTarget)
        } catch let error as SupervisorBackendError {
            // Executable path + OS error only — argv may carry a secret in any mode.
            await logCenter.append(
                source: spec.logSource, stream: .stderr,
                text: "[supervisor] \(name) could not be spawned: \(Self.message(for: error))"
            )
            throw Self.translate(error)
        }
        switch logging {
        case .redacted(let reason):
            await logCenter.append(
                source: spec.logSource, stream: .stderr,
                text: "[supervisor] \(name) exited \(result.exitCode); output redacted (\(reason))"
            )
        case .streamed, .relayed:
            if result.exitCode != 0 {
                await logCenter.append(
                    source: spec.logSource, stream: .stderr,
                    text: "[supervisor] \(name) exited \(result.exitCode)"
                )
            }
        }
        return RunResult(
            stdout: String(data: result.stdout, encoding: .utf8) ?? "",
            stderr: String(data: result.stderr, encoding: .utf8) ?? "",
            exitCode: result.exitCode
        )
    }

    /// Post-hoc equivalent of the backend's live line reader, for output that was captured to a
    /// file (`runDetaching`): splits each stream on newlines and appends the lines in order. A
    /// newline-terminated blob yields a trailing empty piece the live reader would never emit,
    /// so it's dropped; interior blank lines are kept, as the live reader keeps them.
    private static func replay(_ result: ProcessResult, source: String, into logCenter: LogCenter) async {
        for (stream, data) in [(LogCenter.Stream.stdout, result.stdout), (.stderr, result.stderr)] {
            guard let text = String(data: data, encoding: .utf8) else { continue }
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.last?.isEmpty == true { lines.removeLast() }
            for line in lines {
                await logCenter.append(source: source, stream: stream, text: String(line))
            }
        }
    }

    // MARK: Long-running launch

    /// Opaque reference to a launched, supervised process.
    ///
    /// Deliberately carries no PID: under a ``RestartPolicy`` the underlying OS process can be
    /// respawned (new PID) while the handle stays valid, so identity is the supervisor-assigned
    /// ``id``, not anything the kernel hands out.
    public struct Handle: Sendable, Identifiable, Hashable {
        /// Supervisor-assigned identity — shared with the backend's `SpawnedProcessHandle.id`,
        /// which is how the facade maps between the two without extra bookkeeping.
        public let id: UUID
        /// The log-source tag given to `launch(...)`, kept on the handle so callers can label
        /// UI (debug pane sections, error messages) without a supervisor round-trip.
        public let source: String
    }

    /// Wrapper for a launched process's stdin pipe, vended by ``stdinWriter(_:)``.
    ///
    /// Prefer ``writeStdin(_:_:)`` for routine writes — it stays on the backend and surfaces
    /// errors; the raw handle exists for callers that need `FileHandle`-level control.
    public struct StdinHandle: Sendable {
        /// The write end of the child's stdin pipe. Writing after the child exits raises
        /// `EPIPE` rather than killing the app — see the supervisor's `SIGPIPE` handling.
        public let writer: FileHandle
    }

    /// Spawn a long-running supervised process. Log lines flow into `logCenter` tagged with `source`.
    ///
    /// Returns once the process has been spawned (or thrown). Use `waitForExit(_:)` for the final
    /// disposition and `terminate(_:)` to stop it.
    ///
    /// If you need to write to the process's stdin (e.g. MCP JSON-RPC framing), pass `attachStdin: true`
    /// and call `stdinWriter(_:)` afterward. Pass `onRespawn` to react to supervised restarts.
    @discardableResult
    public func launch(
        source: String,
        executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil,
        restartPolicy: RestartPolicy = .never,
        attachStdin: Bool = false,
        onRespawn: RespawnHandler? = nil,
        logCenter: LogCenter = .shared
    ) async throws -> Handle {
        let suddenTerminationLease = suddenTerminationController.acquire()
        let spec = SpawnSpec(
            executable: executable,
            arguments: arguments,
            environment: environment ?? defaultEnvironment(),
            workingDirectory: currentDirectoryURL,
            stdinPipe: attachStdin,
            logSource: source
        )
        let spawned: SpawnedProcessHandle
        do {
            spawned = try await backend.launch(
                spec,
                restartPolicy: restartPolicy,
                onRespawn: onRespawn,
                logCenter: logCenter
            )
        } catch let error as SupervisorBackendError {
            suddenTerminationLease.release()
            throw Self.translate(error)
        } catch {
            suddenTerminationLease.release()
            throw error
        }
        processLeases[spawned.id] = suddenTerminationLease
        let backend = self.backend
        Task { [weak self] in
            _ = await backend.waitForExit(spawned)
            await self?.releaseProcessLease(id: spawned.id)
        }
        return Handle(id: spawned.id, source: source)
    }

    /// Awaits the final exit reason for a launched process. Resolves once the supervision loop ends
    /// (either the process exited and isn't being restarted, or `terminate(_:)` ran). If the
    /// awaiting task is cancelled, returns `.terminated` immediately — letting task groups
    /// unwind without waiting for the real process exit.
    ///
    /// Contract: this **returns** on cancellation (it is non-`throws`), it does not raise
    /// `CancellationError`. Callers that race it inside a task group — e.g. `E2EServer.awaitReady`,
    /// which parks a death-waiter against a readiness poll — rely on a cancelled wait unwinding as a
    /// plain return so it can't surface as a spurious error. Preserve that if this ever gains
    /// cooperative cancellation.
    public func waitForExit(_ handle: Handle) async -> ExitReason {
        await backend.waitForExit(backendHandle(for: handle))
    }

    /// Awaits `handle`'s exit like ``waitForExit(_:)``, but treats cancellation of the awaiting
    /// task as an instruction to stop the child: it SIGTERMs the process (escalating to SIGKILL
    /// after `timeout`, see ``terminate(_:timeout:)``) and then waits for the *real* exit —
    /// supervision finalized, log pipes drained — before returning `.terminated`. A cancelled
    /// caller therefore never observes "terminated" while the child is still alive or its last
    /// output is still in flight, which is what lets `AuditCommand`/`DeployCommand` report a
    /// cancelled step as genuinely killed (#124, #1758).
    ///
    /// Use this instead of pairing `waitForExit` with a fire-and-forget `Task { terminate }` in
    /// an `onCancel` handler: that shape resumed the caller before the SIGTERM was even sent, so
    /// nothing downstream could rely on the child being gone. Non-throwing, like `waitForExit`;
    /// if the process exits on its own before cancellation is observed, its real exit reason is
    /// returned unchanged.
    public func waitForExitOrTerminate(_ handle: Handle, timeout: TimeInterval = defaultTerminationGrace) async -> ExitReason {
        let reason = await waitForExit(handle)
        guard Task.isCancelled else { return reason }
        // Hand the kill to a task cancellation can't reach: `terminate`'s graceful-exit poll
        // sleeps between checks, and `Task.sleep` in a cancelled task returns immediately —
        // which would turn that poll into a busy spin for the whole `timeout`.
        let backend = self.backend
        let backendHandle = backendHandle(for: handle)
        return await Task {
            await backend.terminate(backendHandle, timeout: timeout)
            return await backend.waitForExit(backendHandle)
        }.value
    }

    /// Sends SIGTERM to the child's process group and waits up to `timeout` seconds before
    /// escalating to SIGKILL (also group-wide — see `InProcessBackend.terminate`).
    public func terminate(_ handle: Handle, timeout: TimeInterval = defaultTerminationGrace) async {
        await backend.terminate(backendHandle(for: handle), timeout: timeout)
    }

    /// Terminates every supervised process. SIGTERM (with SIGKILL escalation after `timeout`) is
    /// sent to all live entries concurrently; resolves once each supervision loop has settled.
    /// Marking entries `manuallyTerminated` first means an in-flight `RestartPolicy.onCrash`
    /// backoff is broken instead of waited out. Wire this to the app's quit notification so no
    /// Node / Astro / MCP child outlives the app process.
    public func shutdownAll(timeout: TimeInterval = defaultTerminationGrace) async {
        await backend.shutdownAll(timeout: timeout)
        for id in Array(processLeases.keys) {
            releaseProcessLease(id: id)
        }
    }

    /// Whether the supervised process behind `handle` is currently alive. `false` for an unknown
    /// handle as well as an exited process — callers polling for liveness don't need to
    /// distinguish the two.
    public func isRunning(_ handle: Handle) async -> Bool {
        await backend.isRunning(backendHandle(for: handle))
    }

    /// File handle for writing to the launched process's stdin. Only available when `launch` was
    /// called with `attachStdin: true`. Returns `nil` if the handle is unknown or stdin wasn't attached.
    public func stdinWriter(_ handle: Handle) async -> StdinHandle? {
        guard let writer = await backend.stdinHandle(backendHandle(for: handle)) else { return nil }
        return StdinHandle(writer: writer)
    }

    /// Writes `bytes` to the launched process's stdin via the backend (`InProcessBackend` writes to
    /// the tracked child's stdin pipe). MCP JSON-RPC framing uses this. Throws if the handle is
    /// unknown or `launch` wasn't called with `attachStdin: true`.
    public func writeStdin(_ handle: Handle, _ bytes: Data) async throws {
        do {
            try await backend.writeStdin(backendHandle(for: handle), bytes)
        } catch let error as SupervisorBackendError {
            throw Self.translate(error)
        }
    }

    private func releaseProcessLease(id: UUID) {
        processLeases.removeValue(forKey: id)?.release()
    }

    // MARK: Error translation

    private static func translate(_ error: SupervisorBackendError) -> SupervisorError {
        switch error {
        case .spawnFailed:
            return .spawnFailed(underlying: NSError(
                domain: "AnglesiteCore.SupervisorBackend",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message(for: error)]
            ))
        case .unknownHandle:
            return .unknownHandle
        case .bookmarkResolutionFailed, .backendUnavailable:
            return .spawnFailed(underlying: NSError(
                domain: "AnglesiteCore.SupervisorBackend",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: message(for: error)]
            ))
        }
    }

    /// The backend's human-readable failure text — what `translate(_:)` wraps into the
    /// `NSError`, and what the one-shot `[supervisor] … could not be spawned` marker line shows.
    private static func message(for error: SupervisorBackendError) -> String {
        switch error {
        case .spawnFailed(let message), .bookmarkResolutionFailed(let message), .backendUnavailable(let message):
            return message
        case .unknownHandle:
            return "unknown process handle"
        }
    }
}
