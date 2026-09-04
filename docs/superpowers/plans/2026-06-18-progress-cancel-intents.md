# Progress reporting + cancellation for long-running intents — Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make deploy/backup/audit/create/edit intents emit structured progress milestones and honor cancellation all the way into the MCP layer.

**Architecture:** A new `OperationProgress` value type is emitted by the command actors (the source of truth) through an additive `onProgress` callback threaded down from the operation-service protocols. Cancellation is unified: `MCPClient.callTool` becomes interruptible (a fourth `failPending` path), `BackupCommand`/`AuditCommand` reach SIGTERM/loop-guard parity with `DeployCommand`, and intents map `Task.isCancelled` to a friendly per-operation dialog. A `#if compiler(>=6.4)`-gated adapter forwards milestones into the system `ProgressReportingIntent` reporter.

**Tech Stack:** Swift 6.4 / Swift Concurrency (actors, `withTaskCancellationHandler`, `CheckedContinuation`), Swift Testing (`@Test`/`@Suite`), App Intents.

## Global Constraints

- **Command actors are the source of truth; intents stay thin adapters.** No milestone/cancel logic in intent structs beyond reading `Task.isCancelled` and constructing the adapter handler.
- **Reuse `CancellationError`** — do NOT add an `MCPError.cancelled` case (design decision (b)).
- **macOS-27-only App Intents symbols stay behind `#if compiler(>=6.4)`** (matches existing `LongRunningIntent`/`CancellableIntent` conformances; CI runs Swift 6.3).
- **CI-testable logic lives in `AnglesiteCore`** — all deterministic coverage targets `AnglesiteCore`; intent-layer tests live in `AnglesiteIntentsTests` (compiled only under `compiler(>=6.4)`).
- **Build/test in the worktree** with `ANGLESITE_PLUGIN_SRC=/Users/dwk/Developer/github.com/Anglesite/anglesite` exported. Core tests: `swift test --package-path . --filter AnglesiteCoreTests`.
- **Additive signatures only** — existing zero-`onProgress` call sites must keep compiling via protocol-extension overloads / defaulted parameters.

---

## Phase 1 — Foundations

### Task 1: `OperationProgress` model

**Files:**
- Create: `Sources/AnglesiteCore/OperationProgress.swift`
- Test: `Tests/AnglesiteCoreTests/OperationProgressTests.swift`

**Interfaces:**
- Produces: `OperationProgress` (struct), `OperationProgress.Kind` (enum), `ProgressHandler` typealias, and the static milestone factories used by every command actor: `.deployPreflight`, `.deployBuilding`, `.deployDeploying`, `.deployFinalizing`, `.backupStaging`, `.backupCommitting`, `.backupPushing`, `.auditBuilding`, `auditRunning(category:index:of:)`, `.auditFinalizing`, `.createResolvingRuntime`, `.createCallingPlugin`, `.createFinalizing`, `.editResolvingRouter`, `.editApplying`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/OperationProgressTests.swift
import Testing
@testable import AnglesiteCore

@Suite("OperationProgress")
struct OperationProgressTests {
    @Test("static milestones carry the expected kind and phase")
    func milestones() {
        #expect(OperationProgress.deployBuilding.kind == .deploy)
        #expect(OperationProgress.deployBuilding.phase == "building")
        #expect(OperationProgress.backupPushing.kind == .backup)
        #expect(OperationProgress.auditFinalizing.phase == "finalizing")
        #expect(OperationProgress.createCallingPlugin.kind == .createContent)
        #expect(OperationProgress.editApplying.kind == .edit)
    }

    @Test("auditRunning computes a determinate fraction")
    func auditFraction() {
        let p = OperationProgress.auditRunning(category: "accessibility", index: 0, of: 2)
        #expect(p.kind == .audit)
        #expect(p.phase == "running")
        #expect(p.fraction == 0.5)
        #expect(p.label.contains("accessibility"))
    }

    @Test("zero runners yields a nil fraction rather than dividing by zero")
    func auditFractionZero() {
        #expect(OperationProgress.auditRunning(category: "x", index: 0, of: 0).fraction == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter OperationProgressTests`
Expected: FAIL — `cannot find 'OperationProgress' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/AnglesiteCore/OperationProgress.swift
import Foundation

/// A structured progress milestone emitted by a command actor at a phase boundary.
///
/// Command actors are the single source of truth for progress (per #238): they call a
/// `ProgressHandler` at each named milestone. The app's `@Observable` models, the App Intents
/// `ProgressReportingIntent` adapter, and tests all consume the same stream. `fraction` is
/// populated only where a real denominator exists (e.g. audit runner *i of n*); otherwise it is
/// `nil` (indeterminate) — never a fabricated percentage.
public struct OperationProgress: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case deploy, backup, audit, createContent, edit
    }

    public let kind: Kind
    /// Stable milestone id, e.g. `"building"`. Compared in tests; not shown to users.
    public let phase: String
    /// Human/Siri-readable label, e.g. `"Building site…"`.
    public let label: String
    /// Optional 0...1 completion when determinable; `nil` = indeterminate.
    public let fraction: Double?

    public init(kind: Kind, phase: String, label: String, fraction: Double? = nil) {
        self.kind = kind
        self.phase = phase
        self.label = label
        self.fraction = fraction
    }
}

/// Synchronous progress sink threaded through the operation services into the command actors.
/// Synchronous (not an `AsyncStream`) so it needs no extra task/continuation plumbing and is
/// trivially captured by a fake in tests. Runs inside the emitting actor's isolation — bridge to
/// MainActor via a `Task` if a consumer touches SwiftUI state.
public typealias ProgressHandler = @Sendable (OperationProgress) -> Void

public extension OperationProgress {
    static let deployPreflight = OperationProgress(kind: .deploy, phase: "preflightScan", label: "Running pre-deploy checks…")
    static let deployBuilding = OperationProgress(kind: .deploy, phase: "building", label: "Building site…")
    static let deployDeploying = OperationProgress(kind: .deploy, phase: "deploying", label: "Deploying to production…")
    static let deployFinalizing = OperationProgress(kind: .deploy, phase: "finalizing", label: "Finishing up…")

    static let backupStaging = OperationProgress(kind: .backup, phase: "staging", label: "Staging changes…")
    static let backupCommitting = OperationProgress(kind: .backup, phase: "committing", label: "Committing…")
    static let backupPushing = OperationProgress(kind: .backup, phase: "pushing", label: "Pushing backup…")

    static let auditBuilding = OperationProgress(kind: .audit, phase: "building", label: "Building site…")
    static func auditRunning(category: String, index: Int, of total: Int) -> OperationProgress {
        // Denominator is `total + 1` so the running phase never reaches 1.0 while runners are
        // still executing — the reserved slice lets the terminal `auditFinalizing` step own
        // completion.
        let fraction = total > 0 ? Double(index + 1) / Double(total + 1) : nil
        return OperationProgress(kind: .audit, phase: "running", label: "Checking \(category)…", fraction: fraction)
    }
    static let auditFinalizing = OperationProgress(kind: .audit, phase: "finalizing", label: "Summarizing findings…")

    static let createResolvingRuntime = OperationProgress(kind: .createContent, phase: "resolvingRuntime", label: "Starting the Anglesite plugin…")
    static let createCallingPlugin = OperationProgress(kind: .createContent, phase: "callingPlugin", label: "Creating content…")
    static let createFinalizing = OperationProgress(kind: .createContent, phase: "finalizing", label: "Finishing up…")

    static let editResolvingRouter = OperationProgress(kind: .edit, phase: "resolvingRouter", label: "Locating the page…")
    static let editApplying = OperationProgress(kind: .edit, phase: "applying", label: "Applying the edit…")
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter OperationProgressTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/OperationProgress.swift Tests/AnglesiteCoreTests/OperationProgressTests.swift
git commit -m "feat(#238): OperationProgress milestone model + ProgressHandler"
```

---

### Task 2: `MCPClient.callTool` cancellation (pre-call + in-flight)

**Files:**
- Modify: `Sources/AnglesiteCore/MCPClient.swift` — `callTool` (251-277) and `sendRequest` (285-325)
- Test: `Tests/AnglesiteCoreTests/MCPClientCancellationTests.swift`

**Interfaces:**
- Consumes: the `internal func startWithTransport(_:initializeTimeout:clientName:clientVersion:)` seam (173) and the `MCPTransport` protocol (`open`/`send`/`inbound`/`close`).
- Produces: `callTool` and `listTools` now throw Swift's `CancellationError` when their task is cancelled before send or while awaiting a reply (no in-flight JSON-RPC `send` happens for a pre-cancelled call).

- [ ] **Step 1: Write the failing test**

The test double completes the `initialize` handshake (so `initialized == true`) but never answers `tools/call`, so the call hangs until cancellation resolves it.

```swift
// Tests/AnglesiteCoreTests/MCPClientCancellationTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

/// Transport that answers `initialize` (to let the handshake complete) and records every send,
/// but never replies to any other request — so a `callTool` hangs until cancelled.
private actor HangingTransport: MCPTransport {
    private(set) var sentMethods: [String] = []
    private var continuation: AsyncStream<JSONValue>.Continuation?
    private let stream: AsyncStream<JSONValue>
    init() {
        var cont: AsyncStream<JSONValue>.Continuation!
        stream = AsyncStream { cont = $0 }
        continuation = cont
    }
    func sentMethodsSnapshot() -> [String] { sentMethods }
    func open() async throws {}
    func inbound() -> AsyncStream<JSONValue> { stream }
    func close() async { continuation?.finish() }
    func send(_ message: JSONValue) async throws {
        guard case .object(let obj) = message,
              case .string(let method)? = obj["method"] else { return }
        sentMethods.append(method)
        if method == "initialize", case .int(let id)? = obj["id"] {
            // Minimal valid initialize response so the handshake completes.
            continuation?.yield(.object([
                "jsonrpc": .string("2.0"),
                "id": .int(id),
                "result": .object(["protocolVersion": .string("2024-11-05"), "capabilities": .object([:])]),
            ]))
        }
        // tools/call: deliberately no response.
    }
}

@Suite(.serialized)
struct MCPClientCancellationTests {
    private func makeInitializedClient() async throws -> (MCPClient, HangingTransport) {
        let transport = HangingTransport()
        let client = MCPClient(supervisor: .shared)
        try await client.startWithTransport(transport, initializeTimeout: 5, clientName: "test", clientVersion: "0")
        return (client, transport)
    }

    @Test("a call whose task is cancelled mid-flight throws CancellationError, not timeout")
    func inFlightCancel() async throws {
        let (client, _) = try await makeInitializedClient()
        let task = Task { try await client.callTool(name: "echo", arguments: .object([:])) }
        // Give the call time to register its pending continuation, then cancel.
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test("a call whose task is cancelled before it runs never sends tools/call")
    func preCancelledSendsNothing() async throws {
        let (client, transport) = try await makeInitializedClient()
        // Gate the task so we can cancel it *before* callTool runs — deterministic, no sleep race.
        let gate = Gate()
        let task = Task {
            await gate.wait()   // suspends here; resumes only after release()
            return try await client.callTool(name: "echo", arguments: .object([:]))
        }
        task.cancel()           // task is parked at gate.wait(), so this lands before the call
        await gate.release()     // now callTool runs and its pre-call checkCancellation() fires
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let sent = await transport.sentMethodsSnapshot()
        #expect(sent.contains("tools/call") == false)
        #expect(sent.contains("initialize"))   // handshake still happened
    }
}

/// One-shot await/resume barrier with no cancellation check of its own, so a task parked on
/// `wait()` stays parked (and cancellable) until `release()`.
private actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter MCPClientCancellationTests`
Expected: FAIL — `inFlightCancel` hangs ~30s then the call resolves with `MCPError.timeout` (not `CancellationError`); `preCancelledSendsNothing` records a `tools/call` send.

- [ ] **Step 3: Write minimal implementation**

In `MCPClient.swift`, add an early cancellation check at the top of `callTool` (just after the `initialized` guard, 252):

```swift
    public func callTool(name: String, arguments: JSONValue = .object([:])) async throws -> ToolCallResult {
        guard initialized else { throw MCPError.notInitialized }
        try Task.checkCancellation()   // pre-call guard: never send for an already-cancelled task
        let params: JSONValue = .object([
```

Then wrap the continuation in `sendRequest` (308-324) with a cancellation handler. Replace the existing `return try await withCheckedThrowingContinuation { ... }` block with:

```swift
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSONValue, Error>) in
                // This closure runs synchronously on the actor, so the continuation is registered
                // *before* the send — a response (which the HTTP transport produces during `send`)
                // can never be missed, and there is no registration race.
                pending[id] = cont
                // Send on a detached task so a synchronous transport failure (e.g. connection refused)
                // resolves THIS continuation via `failPending` instead of leaking it. Every exit path —
                // response (`resolvePending` from the reader), timeout, cancellation, or send error —
                // resumes the continuation exactly once (`pending` removal guarantees single-resume).
                Task { [weak self] in
                    do {
                        try await self?.send(message)
                    } catch {
                        await self?.failPending(id: id, error: error)
                    }
                }
            }
        } onCancel: {
            // The awaiting task was cancelled. Resolve the pending continuation with Swift's
            // CancellationError (decision (b) — no MCPError.cancelled). If the response already
            // arrived, `failPending` finds no entry and no-ops, preserving single-resume.
            Task { [weak self] in await self?.failPending(id: id, error: CancellationError()) }
        }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter MCPClientCancellationTests`
Expected: PASS (2 tests), both returning in well under a second.

- [ ] **Step 5: Run the full MCPClient suite to confirm no regression**

Run: `swift test --package-path . --filter MCPClientTests`
Expected: PASS (existing suite unchanged).

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/MCPClient.swift Tests/AnglesiteCoreTests/MCPClientCancellationTests.swift
git commit -m "feat(#238): make MCPClient.callTool cancellable (pre-call + in-flight)"
```

---

## Phase 2 — Command-actor cancellation parity

### Task 3: `BackupCommand` cancellation

**Files:**
- Modify: `Sources/AnglesiteCore/BackupCommand.swift` — `backup(siteID:siteDirectory:)` (58-155) and `defaultStreamer` (215-244)
- Test: `Tests/AnglesiteCoreTests/BackupCommandCancellationTests.swift`

**Interfaces:**
- Consumes: existing `GitRunner`/`GitStreamer` injectable seams (44-45).
- Produces: a `BackupCommand` that stops issuing further git steps once its task is cancelled, returning `.failed(reason: "backup canceled", exitCode: nil)`; the default streamer SIGTERMs the running `git` on cancel.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/BackupCommandCancellationTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite(.serialized)
struct BackupCommandCancellationTests {
    @Test("cancelling after staging prevents the commit and push steps")
    func cancelBeforeCommit() async throws {
        let streamed = StreamRecorder()
        let runner: BackupCommand.GitRunner = { _, args in
            // Pass all pre-flight introspection so we reach the streamed action steps.
            switch args.first {
            case "rev-parse" where args.contains("--is-inside-work-tree"):
                return .init(exitCode: 0, stdout: "true", stderr: "")
            case "rev-parse" where args.contains("--abbrev-ref"):
                return .init(exitCode: 0, stdout: "draft", stderr: "")
            case "remote":
                return .init(exitCode: 0, stdout: "git@example.com:me/site.git", stderr: "")
            case "status":
                return .init(exitCode: 0, stdout: " M index.html", stderr: "")
            case "rev-parse":   // rev-parse HEAD
                return .init(exitCode: 0, stdout: "abc1234", stderr: "")
            default:
                return .init(exitCode: 0, stdout: "", stderr: "")
            }
        }
        let cancelHolder = TaskHolder()
        let streamer: BackupCommand.GitStreamer = { _, args, _ in
            await streamed.record(args.joined(separator: " "))
            if args.first == "add" { await cancelHolder.cancel() }   // cancel right after staging
            return (0, "")
        }
        let cmd = BackupCommand(runner: runner, streamer: streamer)
        let task = Task { await cmd.backup(siteID: "s", siteDirectory: URL(fileURLWithPath: "/tmp/s")) }
        await cancelHolder.hold(task)
        let result = await task.value

        let recorded = await streamed.snapshot()
        #expect(recorded.contains { $0.hasPrefix("add") })
        #expect(recorded.contains { $0.hasPrefix("commit") } == false)
        #expect(recorded.contains { $0.hasPrefix("push") } == false)
        #expect(result == .failed(reason: "backup canceled", exitCode: nil))
    }
}

/// Records streamed git invocations.
private actor StreamRecorder {
    private var calls: [String] = []
    func record(_ c: String) { calls.append(c) }
    func snapshot() -> [String] { calls }
}

/// Lets a streamer closure cancel the backup task once it has a handle to it.
private actor TaskHolder {
    private var pending = false
    private var task: Task<BackupCommand.Result, Never>?
    func cancel() { pending = true; task?.cancel() }
    func hold(_ t: Task<BackupCommand.Result, Never>) { task = t; if pending { t.cancel() } }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter BackupCommandCancellationTests`
Expected: FAIL — `commit`/`push` are still recorded; result is `.succeeded(...)`, because `backup()` has no cancellation checks.

- [ ] **Step 3: Write minimal implementation**

In `BackupCommand.backup(...)`, add a cancellation checkpoint helper and call it before each streamed action. After the status check (128) and before the `add` step (133), and again before `commit` and before `push`, insert guards. Concretely, replace the action block (130-152) with:

```swift
        // 4. add → 5. commit → 6. read HEAD SHA → 7. push.
        // A CancellableIntent (Siri/Shortcuts) may cancel between steps; bail before issuing the
        // next git mutation. The streamed step itself SIGTERMs on cancel (see defaultStreamer).
        if Task.isCancelled { return .failed(reason: "backup canceled", exitCode: nil) }
        if let failure = await streamGit(["add", "-A"], in: siteDirectory, source: source, label: "git add") {
            return failure
        }
        if Task.isCancelled { return .failed(reason: "backup canceled", exitCode: nil) }
        let commitMessage = "Backup \(Self.iso8601Formatter.string(from: clock()))"
        if let failure = await streamGit(["commit", "-m", commitMessage], in: siteDirectory, source: source, label: "git commit") {
            return failure
        }
        let sha: String
        do {
            let result = try await runner(siteDirectory, ["rev-parse", "HEAD"])
            guard result.exitCode == 0 else {
                return .failed(reason: "couldn't read commit SHA (`git rev-parse HEAD` exit \(result.exitCode))", exitCode: result.exitCode)
            }
            sha = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return .failed(reason: "couldn't read commit SHA: \(error)", exitCode: nil)
        }
        if Task.isCancelled { return .failed(reason: "backup canceled", exitCode: nil) }
        if let failure = await streamGit(["push", "origin", branch], in: siteDirectory, source: source, label: "git push") {
            return failure
        }
```

Then give `defaultStreamer` SIGTERM-on-cancel parity with `DeployCommand`/`AuditCommand`. In `defaultStreamer` (215-244) wrap the `waitForExit` (230):

```swift
        let reason = await withTaskCancellationHandler {
            await ProcessSupervisor.shared.waitForExit(handle)
        } onCancel: {
            Task { await ProcessSupervisor.shared.terminate(handle) }
        }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter BackupCommandCancellationTests`
Expected: PASS.

- [ ] **Step 5: Run the existing BackupCommand suite**

Run: `swift test --package-path . --filter BackupCommand`
Expected: PASS (no regression in the non-cancelled paths).

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/BackupCommand.swift Tests/AnglesiteCoreTests/BackupCommandCancellationTests.swift
git commit -m "feat(#238): BackupCommand honors cancellation between git steps + SIGTERM"
```

---

### Task 4: `AuditCommand` runner-loop cancellation

**Files:**
- Modify: `Sources/AnglesiteCore/AuditCommand.swift` — runner loop (88-109)
- Test: `Tests/AnglesiteCoreTests/AuditCommandCancellationTests.swift`

**Interfaces:**
- Consumes: existing `AuditRunner` protocol + injectable `runners:` / `resolveBuildCommand:` seams.
- Produces: an `AuditCommand` that stops invoking later runners once cancelled (the build step already SIGTERMs via its existing handler at 145-152).

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/AuditCommandCancellationTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite(.serialized)
struct AuditCommandCancellationTests {
    @Test("cancelling after the first runner skips the remaining runners")
    func cancelBetweenRunners() async throws {
        let counter = RunCounter()
        let holder = AuditTaskHolder()
        let first = ClosureRunner(category: .accessibility) { await counter.bump(); await holder.cancel(); return [] }
        let second = ClosureRunner(category: .seo) { await counter.bump(); return [] }
        // resolveBuildCommand returns .unavailable so runBuild is skipped? No — .unavailable fails the
        // audit. Instead inject a build command that exits 0 immediately via `true`.
        let cmd = AuditCommand(
            resolveBuildCommand: { _ in .run(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: []) },
            runners: [first, second]
        )
        let task = Task { await cmd.audit(siteID: "s", siteDirectory: URL(fileURLWithPath: "/tmp/s")) }
        await holder.hold(task)
        _ = await task.value
        #expect(await counter.value == 1)   // only the first runner ran
    }
}

private actor RunCounter { private(set) var value = 0; func bump() { value += 1 } }
private actor AuditTaskHolder {
    private var pending = false
    private var task: Task<AuditCommand.Result, Never>?
    func cancel() { pending = true; task?.cancel() }
    func hold(_ t: Task<AuditCommand.Result, Never>) { task = t; if pending { t.cancel() } }
}
private struct ClosureRunner: AuditRunner {
    let category: AuditReport.Finding.Category
    let body: @Sendable () async -> [AuditReport.Finding]
    func run(siteDirectory: URL, supervisor: ProcessSupervisor, logCenter: LogCenter, source: String) async throws -> [AuditReport.Finding] {
        await body()
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter AuditCommandCancellationTests`
Expected: FAIL — `counter.value == 2` (both runners ran; the loop ignores cancellation).

- [ ] **Step 3: Write minimal implementation**

In `AuditCommand.audit(...)`, add a cancellation guard at the top of the runner loop (just inside `for runner in runners {`, before line 89):

```swift
        for runner in runners {
            if Task.isCancelled { break }   // CancellableIntent cancel — stop before the next runner
            let source = "audit:\(siteID):\(runner.category.rawValue)"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter AuditCommandCancellationTests`
Expected: PASS (`counter.value == 1`).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/AuditCommand.swift Tests/AnglesiteCoreTests/AuditCommandCancellationTests.swift
git commit -m "feat(#238): AuditCommand stops between runners on cancellation"
```

---

## Phase 3 — Progress seam + per-operation milestones

### Task 5: Thread `onProgress` through the operation services (nil-wired)

This task adds the seam end-to-end with `nil` wiring so everything compiles and stays green; later tasks make the command actors actually emit.

**Files:**
- Modify: `Sources/AnglesiteCore/SiteOperationsService.swift` (9-16)
- Modify: `Sources/AnglesiteCore/SiteOperations.swift` (25-59)
- Modify: `Sources/AnglesiteCore/ContentOperationsService.swift` (7-10)
- Modify: `Sources/AnglesiteCore/ContentOperations.swift` (19-30)
- Modify: `Tests/AnglesiteIntentsTests/Support/FakeOperations.swift` (16-46)
- Test: `Tests/AnglesiteCoreTests/SiteOperationsProgressSeamTests.swift`

**Interfaces:**
- Consumes: `ProgressHandler` (Task 1).
- Produces:
  - `SiteOperationsService.deploy(site:onProgress:)`, `.backup(site:onProgress:)`, `.audit(site:onProgress:)` (required) + protocol-extension overloads `deploy(site:)` etc. forwarding `onProgress: nil`.
  - `ContentOperationsService.createPage(siteID:name:route:onProgress:)`, `.createPost(siteID:title:collection:slug:onProgress:)` (required) + nil-forwarding overloads.
  - `FakeOperations` records the handler it was passed (`lastDeployProgress`, etc.) — used by later intent tests.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/SiteOperationsProgressSeamTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite(.serialized)
struct SiteOperationsProgressSeamTests {
    @Test("the no-onProgress overload still resolves and forwards nil")
    func overloadCompiles() async {
        // A SiteOperations with a fake factory whose commands return immediately.
        let ops = SiteOperations(factory: NoopCommandFactory(), store: .shared)
        // Just assert the zero-arg overload is callable (compile-level contract).
        let site = SiteStore.Site(id: "nope", name: "nope", directory: URL(fileURLWithPath: "/tmp/nope"))
        _ = await ops.deploy(site: site)            // overload
        _ = await ops.deploy(site: site, onProgress: nil)  // primary
    }
}

/// Minimal CommandFactory whose actors fail fast (no subprocess) — we only exercise signatures here.
private struct NoopCommandFactory: CommandFactory {
    func deploy() -> DeployCommand { DeployCommand(tokenSource: { nil }) }
    func backup() -> BackupCommand { BackupCommand(runner: { _, _ in .init(exitCode: 1, stdout: "", stderr: "") }, streamer: { _, _, _ in (1, "") }) }
    func audit() -> AuditCommand { AuditCommand(resolveBuildCommand: { _ in .unavailable(reason: "noop") }, runners: []) }
}
```

> NOTE: confirm `SiteStore.Site`'s initializer signature at implementation time (read `SiteStore.swift`); adjust the fixture to match. If a public memberwise init isn't available, reuse the test target's existing `TestStore` fixture helper instead.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter SiteOperationsProgressSeamTests`
Expected: FAIL — `deploy(site:onProgress:)` does not exist.

- [ ] **Step 3: Write minimal implementation**

`SiteOperationsService.swift` — add the parameter to the requirements and a nil-forwarding extension:

```swift
public protocol SiteOperationsService: Sendable {
    func site(id: String) async -> SiteStore.Site?
    func deploy(site: SiteStore.Site, onProgress: ProgressHandler?) async -> DeployCommand.Result
    func backup(site: SiteStore.Site, onProgress: ProgressHandler?) async -> BackupCommand.Result
    func audit(site: SiteStore.Site, onProgress: ProgressHandler?) async -> AuditCommand.Result
}

public extension SiteOperationsService {
    func deploy(site: SiteStore.Site) async -> DeployCommand.Result { await deploy(site: site, onProgress: nil) }
    func backup(site: SiteStore.Site) async -> BackupCommand.Result { await backup(site: site, onProgress: nil) }
    func audit(site: SiteStore.Site) async -> AuditCommand.Result { await audit(site: site, onProgress: nil) }
}

extension SiteOperations: SiteOperationsService {}
```

`SiteOperations.swift` — add `onProgress` to the three methods, passing `nil` to the command actors for now (later tasks wire the real handler):

```swift
    public func deploy(site: SiteStore.Site, onProgress: ProgressHandler? = nil) async -> DeployCommand.Result {
        do {
            return try await SiteAccess.withScopedAccess(to: site, in: store) { url in
                await factory.deploy().deploy(siteID: site.id, siteDirectory: url, onProgress: onProgress)
            }
        } catch let SiteAccess.AccessError.noGrant(message) {
            return .failed(reason: message, exitCode: nil)
        } catch {
            return .failed(reason: error.localizedDescription, exitCode: nil)
        }
    }
```

Apply the same shape to `backup` and `audit` (passing `onProgress:` into `factory.backup().backup(...)` / `factory.audit().audit(...)`). The command-actor methods don't accept `onProgress` until Tasks 6-8 — so for THIS task, do NOT yet add `onProgress:` to the `factory.*` calls; pass nothing and just store the parameter unused (prefix `_ = onProgress`), OR sequence Tasks 6-8 before wiring. To keep each task green, in Task 5 the `SiteOperations` methods accept `onProgress` and pass `nil`/ignore it; Tasks 6-8 replace the `factory.*().deploy(...)` call to forward it.

Concretely for Task 5, ignore it safely:

```swift
    public func deploy(site: SiteStore.Site, onProgress: ProgressHandler? = nil) async -> DeployCommand.Result {
        _ = onProgress   // wired to DeployCommand in Task 6
        do { ... existing body unchanged ... }
    }
```

`ContentOperationsService.swift` — mirror the pattern:

```swift
public protocol ContentOperationsService: Sendable {
    func createPage(siteID: String, name: String, route: String?, onProgress: ProgressHandler?) async -> ContentCreateResult
    func createPost(siteID: String, title: String, collection: String?, slug: String?, onProgress: ProgressHandler?) async -> ContentCreateResult
}

public extension ContentOperationsService {
    func createPage(siteID: String, name: String, route: String?) async -> ContentCreateResult {
        await createPage(siteID: siteID, name: name, route: route, onProgress: nil)
    }
    func createPost(siteID: String, title: String, collection: String?, slug: String?) async -> ContentCreateResult {
        await createPost(siteID: siteID, title: title, collection: collection, slug: slug, onProgress: nil)
    }
}
```

`ContentOperations.swift` — add `onProgress` to the two methods (ignored for now, wired in Task 9):

```swift
    public func createPage(siteID: String, name: String, route: String?, onProgress: ProgressHandler? = nil) async -> ContentCreateResult {
        var args: [String: JSONValue] = ["name": .string(name)]
        if let route, !route.isEmpty { args["route"] = .string(route) }
        return await create(siteID: siteID, tool: "create_page", arguments: args, identifierKey: "route", onProgress: onProgress)
    }
```

…and add `onProgress: ProgressHandler? = nil` to `create(...)` (ignored for now: `_ = onProgress`).

`FakeOperations.swift` — update to the new required signatures and record the handler:

```swift
    private(set) var lastDeployProgress: ProgressHandler?
    private(set) var lastBackupProgress: ProgressHandler?
    private(set) var lastAuditProgress: ProgressHandler?

    func deploy(site: SiteStore.Site, onProgress: ProgressHandler?) async -> DeployCommand.Result {
        deployCalls.append(site)
        lastDeployProgress = onProgress
        return deployResult
    }
    func backup(site: SiteStore.Site, onProgress: ProgressHandler?) async -> BackupCommand.Result {
        backupCalls.append(site)
        lastBackupProgress = onProgress
        return backupResult
    }
    func audit(site: SiteStore.Site, onProgress: ProgressHandler?) async -> AuditCommand.Result {
        auditCalls.append(site)
        lastAuditProgress = onProgress
        return auditResult
    }
```

> If a `FakeContentOperations` exists in the intents test support, give it the same `onProgress` treatment. (Grep `Tests/AnglesiteIntentsTests` for `ContentOperationsService` conformers.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter SiteOperationsProgressSeamTests`
Expected: PASS.
Run: `swift test --package-path . --filter AnglesiteCoreTests`
Expected: PASS (no regression).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SiteOperationsService.swift Sources/AnglesiteCore/SiteOperations.swift Sources/AnglesiteCore/ContentOperationsService.swift Sources/AnglesiteCore/ContentOperations.swift Tests/AnglesiteIntentsTests/Support/FakeOperations.swift Tests/AnglesiteCoreTests/SiteOperationsProgressSeamTests.swift
git commit -m "feat(#238): thread onProgress seam through operation services (nil-wired)"
```

---

### Task 6: `DeployCommand` milestones

**Files:**
- Modify: `Sources/AnglesiteCore/DeployCommand.swift` — `deploy(...)` signature (80-84) + emit points
- Modify: `Sources/AnglesiteCore/SiteOperations.swift` — forward `onProgress` into `factory.deploy().deploy(...)`
- Test: `Tests/AnglesiteCoreTests/DeployCommandProgressTests.swift`

**Interfaces:**
- Consumes: `OperationProgress` milestones (Task 1), the existing `onPreflight` param pattern.
- Produces: `DeployCommand.deploy(siteID:siteDirectory:onPreflight:onProgress:)` emitting `.deployBuilding` → `.deployPreflight` → `.deployDeploying` → `.deployFinalizing`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/DeployCommandProgressTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite(.serialized)
struct DeployCommandProgressTests {
    @Test("a blocked deploy still emits building then preflight milestones")
    func milestonesUpToBlock() async {
        let recorder = ProgressRecorder()
        // Build resolves to `/usr/bin/true` (exit 0); preflight returns .blocked so we stop early
        // without needing wrangler.
        let cmd = DeployCommand(
            resolveCommand: { _ in .unavailable(reason: "no wrangler in test") },
            resolveBuildCommand: { _ in .run(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: []) },
            tokenSource: { "token" },
            preflight: { _ in .blocked(failures: [], warnings: []) }
        )
        _ = await cmd.deploy(siteID: "s", siteDirectory: URL(fileURLWithPath: "/tmp/s"),
                             onProgress: { recorder.record($0) })
        let phases = await recorder.phases()
        #expect(phases.prefix(2) == ["building", "preflightScan"])
    }
}

final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [OperationProgress] = []
    func record(_ p: OperationProgress) { lock.lock(); items.append(p); lock.unlock() }
    func phases() async -> [String] { lock.lock(); defer { lock.unlock() }; return items.map(\.phase) }
}
```

> NOTE: confirm `DeployCommand.init` parameter labels at implementation time (read 60-79). The fields are `resolveCommand`, `resolveBuildCommand`, `tokenSource`, `preflight` per 54-59; adjust if the init exposes different external labels.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter DeployCommandProgressTests`
Expected: FAIL — `deploy(...)` has no `onProgress:` parameter.

- [ ] **Step 3: Write minimal implementation**

Add `onProgress` to the signature and emit at the four boundaries. Change the signature (80-84):

```swift
    public func deploy(
        siteID: String,
        siteDirectory: URL,
        onPreflight: PreflightObserver? = nil,
        onProgress: ProgressHandler? = nil
    ) async -> Result {
```

Emit before `runBuild` (just before line 98):

```swift
        onProgress?(.deployBuilding)
        switch await runBuild(siteID: siteID, siteDirectory: siteDirectory) {
```

Emit before the preflight call (just before line 110):

```swift
        onProgress?(.deployPreflight)
        let preflightOutcome = await preflight(siteDirectory)
```

Emit before `supervisor.launch` (just before line 137):

```swift
        onProgress?(.deployDeploying)
        let handle: ProcessSupervisor.Handle
```

Emit after the wait resolves (just before line 165, `let snapshot = ...`):

```swift
        onProgress?(.deployFinalizing)
        let snapshot = await logCenter.snapshot()
```

Then in `SiteOperations.deploy` (Task 5 left it `_ = onProgress`), forward it:

```swift
    public func deploy(site: SiteStore.Site, onProgress: ProgressHandler? = nil) async -> DeployCommand.Result {
        do {
            return try await SiteAccess.withScopedAccess(to: site, in: store) { url in
                await factory.deploy().deploy(siteID: site.id, siteDirectory: url, onProgress: onProgress)
            }
        } catch let SiteAccess.AccessError.noGrant(message) {
            return .failed(reason: message, exitCode: nil)
        } catch {
            return .failed(reason: error.localizedDescription, exitCode: nil)
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter DeployCommandProgressTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/DeployCommand.swift Sources/AnglesiteCore/SiteOperations.swift Tests/AnglesiteCoreTests/DeployCommandProgressTests.swift
git commit -m "feat(#238): DeployCommand emits build/preflight/deploy/finalize milestones"
```

---

### Task 7: `AuditCommand` milestones

**Files:**
- Modify: `Sources/AnglesiteCore/AuditCommand.swift` — `audit(...)` signature (74) + emit points; `SiteOperations.audit` forwards `onProgress`
- Test: `Tests/AnglesiteCoreTests/AuditCommandProgressTests.swift`

**Interfaces:**
- Produces: `AuditCommand.audit(siteID:siteDirectory:onProgress:)` emitting `.auditBuilding` → `auditRunning(category:index:of:)` per runner → `.auditFinalizing`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/AuditCommandProgressTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite(.serialized)
struct AuditCommandProgressTests {
    @Test("emits building, one running-per-runner with fractions, then finalizing")
    func milestones() async {
        let recorder = ProgressRecorder()
        let r1 = PassRunner(category: .accessibility)
        let r2 = PassRunner(category: .seo)
        let cmd = AuditCommand(
            resolveBuildCommand: { _ in .run(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: []) },
            runners: [r1, r2]
        )
        _ = await cmd.audit(siteID: "s", siteDirectory: URL(fileURLWithPath: "/tmp/s"),
                            onProgress: { recorder.record($0) })
        let phases = await recorder.phases()
        #expect(phases == ["building", "running", "running", "finalizing"])
    }
}

private struct PassRunner: AuditRunner {
    let category: AuditReport.Finding.Category
    func run(siteDirectory: URL, supervisor: ProcessSupervisor, logCenter: LogCenter, source: String) async throws -> [AuditReport.Finding] { [] }
}
```

> `ProgressRecorder` is defined in `DeployCommandProgressTests.swift` (Task 6) in the same test target — reuse it; do not redefine.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter AuditCommandProgressTests`
Expected: FAIL — no `onProgress:` parameter.

- [ ] **Step 3: Write minimal implementation**

Signature (74):

```swift
    public func audit(siteID: String, siteDirectory: URL, onProgress: ProgressHandler? = nil) async -> Result {
        let started = Date()
        onProgress?(.auditBuilding)
        switch await runBuild(siteID: siteID, siteDirectory: siteDirectory) {
```

In the runner loop, emit per runner (combine with the Task 4 cancel guard):

```swift
        for (index, runner) in runners.enumerated() {
            if Task.isCancelled { break }
            onProgress?(.auditRunning(category: runner.category.rawValue, index: index, of: runners.count))
            let source = "audit:\(siteID):\(runner.category.rawValue)"
```

Before building the report (just before line 111):

```swift
        onProgress?(.auditFinalizing)
        let report = AuditReport(findings: findings, runnersExecuted: executed, runnersSkipped: skipped)
```

Then forward in `SiteOperations.audit` (mirror Task 6's deploy edit, passing `onProgress:` into `factory.audit().audit(...)`).

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter AuditCommandProgressTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/AuditCommand.swift Sources/AnglesiteCore/SiteOperations.swift Tests/AnglesiteCoreTests/AuditCommandProgressTests.swift
git commit -m "feat(#238): AuditCommand emits build/running/finalize milestones"
```

---

### Task 8: `BackupCommand` milestones

**Files:**
- Modify: `Sources/AnglesiteCore/BackupCommand.swift` — `backup(...)` signature (58) + emit points; `SiteOperations.backup` forwards `onProgress`
- Test: `Tests/AnglesiteCoreTests/BackupCommandProgressTests.swift`

**Interfaces:**
- Produces: `BackupCommand.backup(siteID:siteDirectory:onProgress:)` emitting `.backupStaging` → `.backupCommitting` → `.backupPushing`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/BackupCommandProgressTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite(.serialized)
struct BackupCommandProgressTests {
    @Test("a successful backup emits staging, committing, pushing")
    func milestones() async {
        let recorder = ProgressRecorder()
        let runner: BackupCommand.GitRunner = { _, args in
            switch args.first {
            case "rev-parse" where args.contains("--is-inside-work-tree"): return .init(exitCode: 0, stdout: "true", stderr: "")
            case "rev-parse" where args.contains("--abbrev-ref"): return .init(exitCode: 0, stdout: "draft", stderr: "")
            case "remote": return .init(exitCode: 0, stdout: "git@x:me/s.git", stderr: "")
            case "status": return .init(exitCode: 0, stdout: " M a", stderr: "")
            default: return .init(exitCode: 0, stdout: "abc1234", stderr: "")
            }
        }
        let streamer: BackupCommand.GitStreamer = { _, _, _ in (0, "") }
        let cmd = BackupCommand(runner: runner, streamer: streamer)
        _ = await cmd.backup(siteID: "s", siteDirectory: URL(fileURLWithPath: "/tmp/s"),
                            onProgress: { recorder.record($0) })
        #expect(await recorder.phases() == ["staging", "committing", "pushing"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter BackupCommandProgressTests`
Expected: FAIL — no `onProgress:` parameter.

- [ ] **Step 3: Write minimal implementation**

Signature (58):

```swift
    public func backup(siteID: String, siteDirectory: URL, onProgress: ProgressHandler? = nil) async -> Result {
```

Emit immediately before each streamed action (interleave with the Task 3 cancel guards):

```swift
        if Task.isCancelled { return .failed(reason: "backup canceled", exitCode: nil) }
        onProgress?(.backupStaging)
        if let failure = await streamGit(["add", "-A"], in: siteDirectory, source: source, label: "git add") { return failure }

        if Task.isCancelled { return .failed(reason: "backup canceled", exitCode: nil) }
        onProgress?(.backupCommitting)
        let commitMessage = "Backup \(Self.iso8601Formatter.string(from: clock()))"
        if let failure = await streamGit(["commit", "-m", commitMessage], in: siteDirectory, source: source, label: "git commit") { return failure }

        // ... read SHA (unchanged) ...

        if Task.isCancelled { return .failed(reason: "backup canceled", exitCode: nil) }
        onProgress?(.backupPushing)
        if let failure = await streamGit(["push", "origin", branch], in: siteDirectory, source: source, label: "git push") { return failure }
```

Forward in `SiteOperations.backup` (mirror Task 6).

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter BackupCommandProgressTests`
Expected: PASS.

- [ ] **Step 5: Run all backup tests (cancel + progress + existing)**

Run: `swift test --package-path . --filter BackupCommand`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/BackupCommand.swift Sources/AnglesiteCore/SiteOperations.swift Tests/AnglesiteCoreTests/BackupCommandProgressTests.swift
git commit -m "feat(#238): BackupCommand emits staging/committing/pushing milestones"
```

---

### Task 9: `ContentOperations` milestones + cancellation mapping

**Files:**
- Modify: `Sources/AnglesiteCore/ContentOperations.swift` — `create(...)` (32-56)
- Test: `Tests/AnglesiteCoreTests/ContentOperationsProgressTests.swift`

**Interfaces:**
- Consumes: `OperationProgress.createResolvingRuntime/createCallingPlugin/createFinalizing`, `MCPClient` cancellation (Task 2).
- Produces: `create(...)` emits the three create milestones and, when `callTool` throws `CancellationError`, returns `.failed(reason: "canceled")` (mapped distinctly from a plugin error so the intent can recognize it; see Task 11 for dialog).

> Testing the MCP path fully requires faking `HeadlessRuntimePool` + a runtime exposing an `MCPClient`. `MCPClient` is a concrete actor, so a unit test that drives a real `callTool` is integration-level (covered by Task 2 at the client level). This task's unit test covers the **early** milestone (`resolvingRuntime`) and the `siteNotFound` short-circuit, which need no live MCP. The `callingPlugin`/`finalizing` emissions and cancellation mapping are verified by reading the code path; the end-to-end behavior rides on Task 2's client-level cancellation test.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/ContentOperationsProgressTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite(.serialized)
struct ContentOperationsProgressTests {
    @Test("an unknown site emits resolvingRuntime then returns siteNotFound")
    func unknownSite() async {
        let recorder = ProgressRecorder()
        let ops = ContentOperations(pool: HeadlessRuntimePool(), siteDirectory: { _ in nil })
        let result = await ops.createPage(siteID: "ghost", name: "About", route: nil,
                                          onProgress: { recorder.record($0) })
        #expect(result == .siteNotFound)
        #expect(await recorder.phases().first == "resolvingRuntime")
    }
}
```

> NOTE: confirm `HeadlessRuntimePool()`'s initializer (read `HeadlessRuntimePool.swift`). If it requires arguments, construct it with the minimal production defaults; the test only needs `siteDirectory` to return `nil` so the pool is never consulted.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter ContentOperationsProgressTests`
Expected: FAIL — `createPage` has no `onProgress:` (or no milestone emitted before the `siteNotFound` guard).

- [ ] **Step 3: Write minimal implementation**

Wire `onProgress` through `create(...)` and emit. Replace `create(...)` (32-56):

```swift
    private func create(
        siteID: String,
        tool: String,
        arguments: [String: JSONValue],
        identifierKey: String,
        onProgress: ProgressHandler? = nil
    ) async -> ContentCreateResult {
        onProgress?(.createResolvingRuntime)
        guard let directory = await siteDirectory(siteID) else { return .siteNotFound }
        guard let runtime = await pool.runtime(siteID: siteID, siteDirectory: directory) else {
            return .failed(reason: "Couldn't start the Anglesite plugin for this site.")
        }
        let client = runtime.mcpClient
        onProgress?(.createCallingPlugin)
        do {
            let result = try await client.callTool(name: tool, arguments: .object(arguments))
            let text = result.content.compactMap(\.text).joined(separator: "\n")
            if result.isError {
                return .failed(reason: text.isEmpty ? "The plugin rejected the request." : text)
            }
            guard let parsed = Self.parseCreated(text, identifierKey: identifierKey) else {
                return .failed(reason: "The plugin's reply couldn't be read.")
            }
            onProgress?(.createFinalizing)
            return .created(filePath: parsed.filePath, identifier: parsed.identifier)
        } catch is CancellationError {
            return .failed(reason: "canceled")
        } catch {
            return .failed(reason: "\(error)")
        }
    }
```

Update `createPage`/`createPost` (Task 5 left them ignoring `onProgress`) to pass it through to `create(...)`:

```swift
    public func createPage(siteID: String, name: String, route: String?, onProgress: ProgressHandler? = nil) async -> ContentCreateResult {
        var args: [String: JSONValue] = ["name": .string(name)]
        if let route, !route.isEmpty { args["route"] = .string(route) }
        return await create(siteID: siteID, tool: "create_page", arguments: args, identifierKey: "route", onProgress: onProgress)
    }
    public func createPost(siteID: String, title: String, collection: String?, slug: String?, onProgress: ProgressHandler? = nil) async -> ContentCreateResult {
        var args: [String: JSONValue] = ["title": .string(title)]
        if let collection, !collection.isEmpty { args["collection"] = .string(collection) }
        if let slug, !slug.isEmpty { args["slug"] = .string(slug) }
        return await create(siteID: siteID, tool: "create_post", arguments: args, identifierKey: "slug", onProgress: onProgress)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter ContentOperationsProgressTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/ContentOperations.swift Tests/AnglesiteCoreTests/ContentOperationsProgressTests.swift
git commit -m "feat(#238): ContentOperations emits create milestones + maps CancellationError"
```

---

## Phase 4 — Intent layer

### Task 10: Cancelled-dialog mapping for site intents (deploy/backup/audit)

**Files:**
- Modify: `Sources/AnglesiteCore/SiteOperations.swift` — add static `dialog(forCanceled:)` helpers (pure)
- Modify: `Sources/AnglesiteIntents/SiteIntents.swift` — post-await `Task.isCancelled` check (DeploySiteIntent 52-64, BackupSiteIntent 89-101, AuditSiteIntent 125-137)
- Test: `Tests/AnglesiteCoreTests/SiteOperationsDialogTests.swift` (or extend an existing dialog test file)

**Interfaces:**
- Produces: `SiteOperations.canceledDialog(operation:siteName:) -> String` returning e.g. `"Canceled the deploy of My Site."`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/SiteOperationsDialogTests.swift
import Testing
@testable import AnglesiteCore

@Suite("SiteOperations cancel dialog")
struct SiteOperationsDialogTests {
    @Test("canceled dialog names the operation and site")
    func canceled() {
        #expect(SiteOperations.canceledDialog(operation: "deploy", siteName: "My Site") == "Canceled the deploy of My Site.")
        #expect(SiteOperations.canceledDialog(operation: "backup", siteName: "Blog") == "Canceled the backup of Blog.")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter SiteOperationsDialogTests`
Expected: FAIL — `canceledDialog` does not exist.

- [ ] **Step 3: Write minimal implementation**

Add to `SiteOperations` (after the existing dialog helpers, ~97):

```swift
    /// Friendly dialog for a Siri/Shortcuts cancellation, mapped from `Task.isCancelled` at the
    /// intent boundary (the command actor SIGTERMs the underlying subprocess on cancel).
    public static func canceledDialog(operation: String, siteName: String) -> String {
        "Canceled the \(operation) of \(siteName)."
    }
```

Then in each site intent, after the operation returns, check cancellation BEFORE building the result dialog. For `DeploySiteIntent.perform()` replace the final `return` (64):

```swift
        if Task.isCancelled {
            return .result(value: site, dialog: IntentDialog(stringLiteral: SiteOperations.canceledDialog(operation: "deploy", siteName: site.displayName)))
        }
        return .result(value: site, dialog: IntentDialog(stringLiteral: SiteOperations.dialog(forDeploy: result)))
```

Apply the same pattern to `BackupSiteIntent` (operation: "backup", before line 101) and `AuditSiteIntent` (operation: "check", before line 137). Use `"check"` for audit to match its user-facing verb ("Check Site").

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter SiteOperationsDialogTests`
Expected: PASS.

- [ ] **Step 5: Build the intents target to confirm the perform() edits compile**

Run: `swift build --package-path . --target AnglesiteIntents`
Expected: build succeeds.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/SiteOperations.swift Sources/AnglesiteIntents/SiteIntents.swift Tests/AnglesiteCoreTests/SiteOperationsDialogTests.swift
git commit -m "feat(#238): site intents map cancellation to a friendly dialog"
```

---

### Task 11: Cancelled dialog for create + edit intents; remove EditContentIntent limitation

**Files:**
- Modify: `Sources/AnglesiteIntents/ContentIntents.swift` — `ContentDialogs.created(...)` + AddPage/AddPost `perform()` (163-185, 224-243)
- Modify: `Sources/AnglesiteIntents/EditContentIntent.swift` — remove the known-limitation comment (27-36), add post-await cancel check (56-72)
- Modify: `Sources/AnglesiteCore/MCPApplyEditRouter.swift` — map `CancellationError` in `apply`'s catch (86-88)
- Test: `Tests/AnglesiteCoreTests/MCPApplyEditRouterCancelTests.swift`

**Interfaces:**
- Consumes: `ContentCreateResult.failed(reason: "canceled")` sentinel (Task 9), `MCPClient` cancellation (Task 2).
- Produces: `MCPApplyEditRouter.apply` returns `EditReply(status: .failed, message: "canceled")` on `CancellationError`; create/edit intents surface a "Canceled…" dialog when `Task.isCancelled`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/MCPApplyEditRouterCancelTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("MCPApplyEditRouter cancellation")
struct MCPApplyEditRouterCancelTests {
    @Test("a CancellationError from the tool caller maps to a clean failed reply")
    func mapsCancellation() async {
        let router = MCPApplyEditRouter(toolCaller: { _, _ in throw CancellationError() })
        let msg = EditMessage(id: "e1", type: .applyEdit, path: "/about", selector: .object([:]), op: "apply-instruction", value: .string("x"))
        let reply = await router.apply(msg)
        #expect(reply.status == .failed)
        #expect(reply.message == "canceled")
    }
}
```

> NOTE: confirm `EditMessage`'s initializer + `EditMessage.MessageType.applyEdit` spelling at implementation time (read `EditRouter.swift` / `EditMessage`). The router test in `MCPApplyEditRouterTests.swift` already constructs an `EditMessage` — copy its exact call.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter MCPApplyEditRouterCancelTests`
Expected: FAIL — `reply.message` is the stringified `CancellationError()`, not `"canceled"`.

- [ ] **Step 3: Write minimal implementation**

In `MCPApplyEditRouter.apply`, special-case cancellation in the catch (86-88):

```swift
        } catch is CancellationError {
            return EditReply(id: message.id, status: .failed, message: "canceled")
        } catch {
            return EditReply(id: message.id, status: .failed, message: "\(error)")
        }
```

In `ContentIntents.swift`, add a `canceled` dialog and use it. Add to `ContentDialogs` (find the enum/struct in this file):

```swift
    /// Friendly dialog for a Siri/Shortcuts cancellation of a create operation.
    public static func canceled(kind: Kind, siteName: String) -> String {
        "Canceled adding the \(kind == .page ? "page" : "post") to \(siteName)."
    }
```

In `AddPageIntent.perform()`, before the final `return .result(...)` (181), add:

```swift
        if Task.isCancelled {
            return .result(value: nil, dialog: IntentDialog(stringLiteral: ContentDialogs.canceled(kind: .page, siteName: site.displayName)))
        }
```

Same for `AddPostIntent.perform()` (before 239) with `kind: .post`.

In `EditContentIntent.swift`: delete the "Known cancellation limitation" doc comment block (27-36) — it's now fixed. After `let reply = await resolved.applyEdit(...)` (63-69) add:

```swift
        if Task.isCancelled {
            return .result(dialog: IntentDialog(stringLiteral: "Canceled the edit to \(element.displayName)."))
        }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter MCPApplyEditRouterCancelTests`
Expected: PASS.

- [ ] **Step 5: Build the intents target**

Run: `swift build --package-path . --target AnglesiteIntents`
Expected: build succeeds.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/MCPApplyEditRouter.swift Sources/AnglesiteIntents/ContentIntents.swift Sources/AnglesiteIntents/EditContentIntent.swift Tests/AnglesiteCoreTests/MCPApplyEditRouterCancelTests.swift
git commit -m "feat(#238): create/edit intents map cancellation; close EditContentIntent limitation"
```

---

### Task 12: System-progress adapter (`ProgressReportingIntent`)

**Files:**
- Create: `Sources/AnglesiteIntents/IntentProgressAdapter.swift`
- Modify: `Sources/AnglesiteIntents/SiteIntents.swift`, `ContentIntents.swift`, `EditContentIntent.swift` — pass the adapter handler into the operation calls (replacing the empty `onCancel: { _ in }` wiring)

**Interfaces:**
- Consumes: `OperationProgress` + the system `ProgressReportingIntent` API.
- Produces: a gated helper that, given the running intent's progress reporter, returns a `ProgressHandler` forwarding each milestone's `label`/`fraction`.

> **SDK-DEPENDENT TASK.** The exact `ProgressReportingIntent` reporter API on macOS 27 must be verified before writing this code. Step 1 is verification, not a test — the adapter is a thin forwarder whose deterministic behavior (milestone → label/fraction) is already covered by the Core progress tests; the system bridge cannot be unit-tested off-device. Keep the whole file behind `#if compiler(>=6.4)`.

- [ ] **Step 1: Verify the reporter API**

Run: search the SDK for the progress surface exposed by `ProgressReportingIntent`:

```bash
xcrun --sdk macosx --show-sdk-path
# Inspect the AppIntents module interface for the progress API:
find "$(xcrun --sdk macosx --show-sdk-path)/../.." -name "AppIntents.swiftinterface" 2>/dev/null | head
grep -rn "ProgressReportingIntent\|progress" "$(xcrun --sdk macosx --show-sdk-path)/System/Library/Frameworks/AppIntents.framework/Modules" 2>/dev/null | grep -i progress | head -40
```

Expected: identify the property/method the running intent uses to report progress (e.g. a `progress` reporter the intent can update with a completed-unit count or a description). Record the exact symbol; the implementation in Step 2 uses it.

- [ ] **Step 2: Write the adapter and wire it**

```swift
// Sources/AnglesiteIntents/IntentProgressAdapter.swift
#if compiler(>=6.4)
import AppIntents
import AnglesiteCore

/// Bridges `OperationProgress` milestones from the command actors into the system progress UI
/// that Siri/Shortcuts shows for a `ProgressReportingIntent`. Thin by design — the milestone
/// values themselves are produced and tested in `AnglesiteCore`; this only forwards them.
///
/// Gated on `compiler(>=6.4)` because `ProgressReportingIntent` is a macOS 27 symbol absent on
/// the Xcode 26.3 CI toolchain (same gate as the intents' LongRunningIntent conformance).
enum IntentProgressAdapter {
    /// Returns a `ProgressHandler` that forwards each milestone to `report`. `report` wraps the
    /// concrete reporter call verified in Step 1.
    static func handler(_ report: @escaping @Sendable (_ label: String, _ fraction: Double?) -> Void) -> ProgressHandler {
        { progress in report(progress.label, progress.fraction) }
    }
}
#endif
```

Then, in each long-running intent's non-scoped branch, replace `onCancel: { _ in }` wiring so the operation receives the adapter handler. For `DeploySiteIntent` (56-62):

```swift
            #if compiler(>=6.4)
            let onProgress = IntentProgressAdapter.handler { label, fraction in
                // VERIFIED API CALL from Step 1 — update the intent's progress reporter.
                // e.g. self.progress.report(label, fraction: fraction)
            }
            result = try await performBackgroundTask {
                await ops.deploy(site: resolved, onProgress: onProgress)
            } onCancel: { _ in }
            #else
            result = await ops.deploy(site: resolved)
            #endif
```

Apply the analogous change to `BackupSiteIntent`, `AuditSiteIntent`, `AddPageIntent`, `AddPostIntent`, and `EditContentIntent` (the edit intent has no `performBackgroundTask` today — wrap its `applyEdit` call the same way the create intents do, passing the adapter via a future `onProgress` on `IntentEditBridge.applyEdit` if added; otherwise forward only the cancel/budget behavior and leave edit progress to the single `.editApplying` milestone surfaced through the bridge). Keep each intent's `scoped != nil` test path calling the no-`onProgress` overload so existing tests are unaffected.

- [ ] **Step 3: Build both the package and the app target**

Run: `swift build --package-path . --target AnglesiteIntents`
Then (per the "verify with xcodebuild" rule): `xcodegen generate && xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: both succeed. (Run `xcodegen generate` first in the worktree; export `ANGLESITE_PLUGIN_SRC`.)

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteIntents/IntentProgressAdapter.swift Sources/AnglesiteIntents/SiteIntents.swift Sources/AnglesiteIntents/ContentIntents.swift Sources/AnglesiteIntents/EditContentIntent.swift
git commit -m "feat(#238): forward OperationProgress milestones into ProgressReportingIntent"
```

---

## Phase 5 — UI consumption

### Task 13: `DeployModel` / `BackupModel` consume the progress handler

**Files:**
- Modify: `Sources/AnglesiteApp/DeployModel.swift` — `runDeploy(...)` (170-186) to pass an `onProgress` that updates an observable phase label
- Modify: `Sources/AnglesiteApp/BackupModel.swift` — same shape
- (No unit test — app-target logic isn't hosted on CI; verify by build + the existing `swift test` suite staying green.)

**Interfaces:**
- Consumes: `command.deploy(siteID:siteDirectory:onProgress:)` (via the concrete command/SiteOperations the model holds).
- Produces: an `@Observable` `currentMilestone: String?` (or similar) the deploy drawer can show alongside the log stream.

- [ ] **Step 1: Add the observable field and pass the handler**

In `DeployModel`, add:

```swift
    /// The latest milestone label from the running deploy (drives a status line above the log).
    private(set) var currentMilestone: String?
```

In `runDeploy(...)` where it calls `command.deploy(...)` (≈186), pass a handler that hops to the main actor:

```swift
        let result = await command.deploy(
            siteID: siteID,
            siteDirectory: siteDirectory,
            onProgress: { [weak self] progress in
                Task { @MainActor in self?.currentMilestone = progress.label }
            }
        )
```

> NOTE: read `DeployModel.swift` 56-186 to confirm whether it holds a `DeployCommand` directly or a `SiteOperations`; pass `onProgress:` to whichever `deploy(...)` it calls (both now accept it). Clear `currentMilestone = nil` wherever the model resets to `.idle`.

Apply the analogous change to `BackupModel`.

- [ ] **Step 2: Build the app target**

Run: `xcodegen generate && xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: build succeeds.

- [ ] **Step 3: Run the full Core + Intents suite to confirm no regression**

Run: `swift test --package-path .`
Expected: PASS (existing counts + the new tests added in this plan).

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteApp/DeployModel.swift Sources/AnglesiteApp/BackupModel.swift
git commit -m "feat(#238): surface deploy/backup progress milestones in the UI models"
```

---

## Final verification

- [ ] **Run the complete test suite** with the plugin path set:

```bash
ANGLESITE_PLUGIN_PATH=/Users/dwk/Developer/github.com/Anglesite/anglesite \
ANGLESITE_PLUGIN_SRC=/Users/dwk/Developer/github.com/Anglesite/anglesite \
swift test --package-path .
```
Expected: all suites green, including the new `OperationProgress`, `MCPClientCancellation`, `BackupCommandCancellation`, `AuditCommandCancellation`, and per-command progress tests.

- [ ] **Build both schemes** (DevID + MAS) to confirm the gated adapter compiles on the real toolchain:

```bash
xcodegen generate
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build
```

- [ ] **Open the PR** referencing #238, summarizing: in-flight MCP cancellation (closes the EditContentIntent known-limitation), command-actor cancel parity, structured `OperationProgress` milestones, and the gated `ProgressReportingIntent` adapter.

---

## Notes / deviations from the spec

- **Pre-call guard placement.** The spec listed `try Task.checkCancellation()` in both `ContentOperations` and `MCPApplyEditRouter`. This plan places the authoritative guard once, at the top of `MCPClient.callTool` (Task 2), so every caller (create + edit) inherits it (DRY) and it is deterministically tested at the client level. The call-site catches map the resulting `CancellationError` to clean outcomes (Tasks 9, 11). Net behavior — "cancel before the MCP call prevents the MCP call" — is satisfied and unit-tested.
- **Site-intent cancellation dialog** is driven by a post-await `Task.isCancelled` check rather than new `.cancelled` cases on the `DeployCommand`/`BackupCommand`/`AuditCommand` `Result` enums, avoiding churn to their exhaustive switches and the UI models that consume them.
