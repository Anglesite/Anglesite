# Local `wrangler dev` Runtime Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a local `wrangler dev --local` guest process to `LocalContainerSiteRuntime`, started only when a site's effective active-worker set is non-empty, crash-restart-capable via a new generic guest-process supervisor, and reachable through the runtime's existing state/session payloads — the last of #708's three prerequisites.

**Architecture:** Two additive type extensions (`LocalContainerSession`, `SiteRuntimeState.ready` both gain an optional `workersDevURL`) plus two new `LocalContainerControl` protocol methods (`startWorkersDev`/`stopWorkersDev`) let `LocalContainerSiteRuntime` start/stop a fourth guest process alongside astro/mcp/bridges, without changing `SiteRuntime`'s three-method protocol surface. A new, generic `GuestProcessSupervisor` (mirroring `InProcessBackend`'s host-process `RestartPolicy` shape, but driving a guest process via a new `GuestProcessLauncher` seam) gives wrangler-dev real crash-restart — the first guest process in this codebase to get that. The effective active-worker set is computed once, inside `LocalContainerSiteRuntime.start()`, using the same `WorkerActivation`/`SiteConfigStore` pipeline `DeployModel` already uses.

**Tech Stack:** Swift 6.4, Apple's Containerization framework (`LinuxContainer`/`LinuxProcess`), Swift Testing, SwiftPM (`AnglesiteCore`, `AnglesiteContainer`, `AnglesiteContainerLocalTests` — the last gated behind `ANGLESITE_CONTAINER_TESTS=1`), Xcode/`xcodebuild` for `AnglesiteApp`.

## Global Constraints

- Governing spec: `docs/superpowers/specs/2026-07-13-workers-local-debugging-design.md` §7. This plan's own design doc: `docs/superpowers/specs/2026-07-20-local-wrangler-dev-runtime-design.md`.
- No `SiteRuntime` protocol change — `start`/`stop`/`observe`/`mcpClient` stay exactly as they are. All new capability is additive to `SiteRuntimeState`/`LocalContainerSession`/`LocalContainerControl`.
- Out of scope (per the design doc, do not build): a live-toggle-restart UI caller (the Workers tab, #700c, doesn't exist yet — build `updateActiveWorkers(_:)` and test it directly, but `start()` is its only caller); retrofitting `astro`/`mcp` onto `GuestProcessSupervisor`; any new SwiftUI status indicator for supervisor state.
- `wrangler` becomes a new `Resources/Template/package.json` devDependency — no Dockerfile change, no paired sidecar PR (template changes are app-only per CLAUDE.md).
- The ephemeral `wrangler.toml` for local dev lives at a path outside `/workspace/site` entirely (`/tmp/anglesite-workers-dev/<siteID>/wrangler.toml` inside the guest) — refining the design doc's "git-ignored path under `Source/`" sketch to something that needs no `.gitignore` entry at all, since it's outside the cloned repo.
- Every `AnglesiteCoreTests`/`AnglesiteContainerLocalTests` suite touched must pass. `AnglesiteContainerLocalTests` requires `ANGLESITE_CONTAINER_TESTS=1` in the build environment; its live-VM cases additionally require `ANGLESITE_CONTAINER_E2E=1` at runtime and can only really run via `scripts/run-container-probe.sh`, never bare `swift test` (`swiftpm-testing-helper` cannot carry the virtualization entitlement).
- `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build` must succeed.
- If you touch `Resources/Template/`, run `swift test` too (CONTRIBUTING.md) — some Swift tests couple to template markup.

---

## File Structure

| File | Change |
|---|---|
| `Sources/AnglesiteCore/SiteRuntime.swift` | `SiteRuntimeState.ready` gains `workersDevURL: URL? = nil` |
| `Sources/AnglesiteCore/LocalContainerControl.swift` | `LocalContainerSession` gains `workersDevURL: URL? = nil`; protocol gains `startWorkersDev`/`stopWorkersDev` |
| `Sources/AnglesiteSiteModel/AnglesitePackage.swift` | New static helper: package root from a `Source/` URL |
| `Tests/AnglesiteCoreTests/FakeLocalContainerControl.swift` | All four `LocalContainerControl` conformers gain the two new methods |
| `Resources/Template/package.json` | Add `wrangler` devDependency |
| `Sources/AnglesiteContainer/GuestProcessSupervisor.swift` | New file: `GuestProcessLauncher`/`GuestProcessHandle` protocols, `LinuxContainerProcessLauncher` real conformer, `GuestProcessSupervisor` actor |
| `Tests/AnglesiteContainerLocalTests/GuestProcessSupervisorTests.swift` | New file: restart-policy state-machine tests against a fake launcher |
| `Sources/AnglesiteContainer/ContainerizationControl.swift` | `startWorkersDev`/`stopWorkersDev`, `LiveContainers` gains a supervisors dict, `Self.workersPort` |
| `Sources/AnglesiteCore/LocalContainerSiteRuntime.swift` | Worker-awareness: compute effective active set, call `startWorkersDev`, `updateActiveWorkers(_:)` |
| `Tests/AnglesiteCoreTests/LocalContainerSiteRuntimeTests.swift` | New cases for the above |
| `Sources/AnglesiteApp/PreviewModel.swift`, `SiteWindow.swift`, `StartupProgressModel.swift` | Fix the 3 real `.ready(...)` pattern-match sites; add `PreviewModel.workersDevURL` |
| `Tests/AnglesiteContainerLocalTests/ContainerizationControlTests.swift` | New e2e case (boot with an active worker, assert workers-dev URL answers HTTP) |
| `Sources/AnglesiteContainerProbe/main.swift`, `scripts/run-container-probe.sh` | New `workers-dev` subcommand |

---

## Task 1: AnglesiteCore — additive type/protocol surface

**Files:**
- Modify: `Sources/AnglesiteCore/SiteRuntime.swift:7`
- Modify: `Sources/AnglesiteCore/LocalContainerControl.swift`
- Modify: `Sources/AnglesiteSiteModel/AnglesitePackage.swift`
- Modify: `Tests/AnglesiteCoreTests/FakeLocalContainerControl.swift`
- Test: `Tests/AnglesiteSiteModelTests/AnglesitePackageTests.swift` (or wherever existing `AnglesitePackage` tests live — locate via `grep -rl "AnglesitePackage(" Tests/AnglesiteSiteModelTests/`)

**Interfaces:**
- Produces: `SiteRuntimeState.ready(siteID:url:workersDevURL:)`; `LocalContainerSession.workersDevURL`; `LocalContainerControl.startWorkersDev(siteID:workers:onOutput:) -> URL` / `.stopWorkersDev(siteID:)`; `AnglesitePackage.packageRoot(fromSourceURL:) -> URL`. Task 5 (`LocalContainerSiteRuntime`) and Task 6 (`AnglesiteApp`) consume all four.

- [ ] **Step 1: Add `workersDevURL` to `SiteRuntimeState.ready`**

In `Sources/AnglesiteCore/SiteRuntime.swift`, replace:

```swift
    case ready(siteID: String, url: URL)
```

with:

```swift
    /// `workersDevURL` is the local `wrangler dev --local` endpoint, present only when the site's
    /// effective active-worker set was non-empty at start time (#708) — `nil` for a static-only
    /// site, and always `nil` for `RemoteSandboxSiteRuntime`/`UnavailableSiteRuntime` (a
    /// local-container-only capability for v1). Defaulted so every existing `.ready(siteID:url:)`
    /// construction site keeps compiling unchanged.
    case ready(siteID: String, url: URL, workersDevURL: URL? = nil)
```

- [ ] **Step 2: Add `workersDevURL` to `LocalContainerSession` and the two new protocol methods**

In `Sources/AnglesiteCore/LocalContainerControl.swift`, replace:

```swift
public struct LocalContainerSession: Sendable, Equatable {
    public let previewURL: URL
    public let mcpURL: URL
    public init(previewURL: URL, mcpURL: URL) {
        self.previewURL = previewURL
        self.mcpURL = mcpURL
    }
}
```

with:

```swift
public struct LocalContainerSession: Sendable, Equatable {
    public let previewURL: URL
    public let mcpURL: URL
    /// The local `wrangler dev --local` endpoint, populated only when `startWorkersDev` has been
    /// called for this session (#708) — not part of the initial `start()` payload, since the
    /// workers-dev process is started conditionally, after boot, not during it.
    public let workersDevURL: URL?
    public init(previewURL: URL, mcpURL: URL, workersDevURL: URL? = nil) {
        self.previewURL = previewURL
        self.mcpURL = mcpURL
        self.workersDevURL = workersDevURL
    }
}
```

Then add the two new protocol methods. Find the `LocalContainerControl` protocol's method list (ends with `resetNetworking()`'s default extension) and add, on the protocol itself:

```swift
    /// Starts a local `wrangler dev --local` (Miniflare-backed, no real Cloudflare account calls)
    /// guest process for the given site's currently-active workers, as a fourth guest process
    /// sibling to astro/mcp/bridges — called only after `start()` has already succeeded, and only
    /// when `workers` is non-empty (#708 design §7 "started on demand, not unconditionally").
    /// Crash-restart-capable (via `GuestProcessSupervisor`) — a wrangler-dev crash after this
    /// returns does not throw back to any caller; it's handled internally.
    /// - Returns: The host-proxied URL wrangler-dev is reachable at.
    func startWorkersDev(
        siteID: String,
        workers: [WorkerDescriptor],
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> URL

    /// Stops the workers-dev process (and its supervisor) for `siteID`, independent of astro/mcp —
    /// used both when the effective active set becomes empty and as part of a full container
    /// teardown (`LiveContainers.teardown` already calls this before `container.stop()`).
    func stopWorkersDev(siteID: String) async throws
```

- [ ] **Step 3: Add the reverse package-root derivation to `AnglesitePackage`**

In `Sources/AnglesiteSiteModel/AnglesitePackage.swift`, after the existing `sourceURL`/`configURL` computed properties (near line 28-29), add:

```swift
    /// The inverse of `sourceURL`: reconstructs a package's root `url` from its `Source/`
    /// directory. For callers (like `LocalContainerSiteRuntime`) that are only ever handed the
    /// `Source/` path, not the package root itself.
    public static func packageRoot(fromSourceURL sourceURL: URL) -> URL {
        sourceURL.deletingLastPathComponent()
    }
```

- [ ] **Step 4: Add a round-trip test for the new `AnglesitePackage` helper**

Find the existing `AnglesitePackage` test file (`grep -rl "AnglesitePackage(" Tests/AnglesiteSiteModelTests/`) and add:

```swift
    @Test("packageRoot(fromSourceURL:) is the inverse of sourceURL")
    func packageRootFromSourceURLRoundTrips() {
        let root = URL(fileURLWithPath: "/tmp/my-site.anglesite", isDirectory: true)
        let pkg = AnglesitePackage(url: root)
        #expect(AnglesitePackage.packageRoot(fromSourceURL: pkg.sourceURL) == root)
    }
```

- [ ] **Step 5: Run the test target to confirm it fails to compile (expected — the four `LocalContainerControl` test conformers don't implement the two new protocol methods yet)**

Run: `swift test --package-path . --filter AnglesiteSiteModelTests`
Expected: PASS (Step 3/4 alone compile and pass — this step is really about confirming the *next* build step's failure mode, so run this instead: `swift build --package-path . --target AnglesiteCoreTests` or just `swift test --package-path . --filter LocalContainerSiteRuntimeTests`)
Expected: **build error** — `type 'FakeLocalContainerControl' does not conform to protocol 'LocalContainerControl'` (missing `startWorkersDev`/`stopWorkersDev`), same for the other three conformers in that file.

- [ ] **Step 6: Add the two new methods to all four test conformers in `Tests/AnglesiteCoreTests/FakeLocalContainerControl.swift`**

To `FakeLocalContainerControl` (the main one, used by richer tests — Task 5 extends this further), add stored state and the two methods:

```swift
    /// Canned result returned by `startWorkersDev`. Defaults to a successful fixed URL.
    var startWorkersDevResult: Result<URL, LocalContainerError> = .success(URL(string: "http://127.0.0.1:51003")!)
    /// Lines replayed to `startWorkersDev`'s `onOutput` in order before it returns.
    var startWorkersDevStdoutLines: [String] = []
    /// All `startWorkersDev` invocations recorded for assertion.
    private(set) var startWorkersDevCalls: [(siteID: String, workers: [WorkerDescriptor])] = []
    /// All `stopWorkersDev` invocations recorded for assertion.
    private(set) var stopWorkersDevCalls: [String] = []
```

and the two methods, alongside the existing `stop(siteID:)`:

```swift
    func startWorkersDev(
        siteID: String,
        workers: [WorkerDescriptor],
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> URL {
        startWorkersDevCalls.append((siteID: siteID, workers: workers))
        for line in startWorkersDevStdoutLines { onOutput(line, .stdout) }
        return try startWorkersDevResult.get()
    }

    func stopWorkersDev(siteID: String) async throws {
        stopWorkersDevCalls.append(siteID)
    }
```

To each of `PersistenceGatedFakeLocalContainerControl`, `StopGatedFakeLocalContainerControl`, and `GatedFakeLocalContainerControl` (none of which exercise the new methods — mirror their existing trivial `execInteractive` no-op pattern), add:

```swift
    func startWorkersDev(
        siteID: String,
        workers: [WorkerDescriptor],
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> URL {
        URL(string: "http://127.0.0.1:51003")!
    }

    func stopWorkersDev(siteID: String) async throws {}
```

- [ ] **Step 7: Run the full AnglesiteCore test target**

Run: `swift test --package-path .`
Expected: PASS — everything compiles (the four conformers satisfy the protocol again) and every existing test still passes unchanged (all four new methods are additive; no existing test calls them yet).

- [ ] **Step 8: Commit**

```bash
git add Sources/AnglesiteCore/SiteRuntime.swift Sources/AnglesiteCore/LocalContainerControl.swift Sources/AnglesiteSiteModel/AnglesitePackage.swift Tests/AnglesiteCoreTests/FakeLocalContainerControl.swift Tests/AnglesiteSiteModelTests/*.swift
git commit -m "feat(workers): additive type/protocol surface for local wrangler-dev runtime (#708)"
```

---

## Task 2: Template — make `wrangler` available inside the container

**Files:**
- Modify: `Resources/Template/package.json`

**Interfaces:**
- Consumes: nothing new.
- Produces: `wrangler` resolvable via `npx wrangler` (or directly, once installed) inside any site's `node_modules`, hydrated by the existing `anglesite-hydrate` pre-baked-tarball path — no code depends on this directly; Task 4's guest `argv` is the first real consumer.

- [ ] **Step 1: Add the devDependency**

In `Resources/Template/package.json`, in the `"devDependencies"` object, add (alphabetically, next to the other Cloudflare-adjacent deps):

```json
    "@cloudflare/vitest-pool-workers": "0.18.5",
    "@cloudflare/workers-types": "5.20260715.1",
```

becomes:

```json
    "@cloudflare/vitest-pool-workers": "0.18.5",
    "@cloudflare/workers-types": "5.20260715.1",
    "wrangler": "^4.0.0",
```

(pin the exact version by checking what's current at implementation time — `npm view wrangler version` — rather than assuming `^4.0.0` is still accurate; update this step's exact string before running `npm install`.)

- [ ] **Step 2: Regenerate the lockfile**

Run: `cd Resources/Template && npm install && cd ../..`
Expected: `Resources/Template/package-lock.json` updates to include `wrangler` and its transitive dependencies. Review the diff — this is a large lockfile change, expected and fine.

- [ ] **Step 3: Run the template-coupled Swift test suite**

Per CONTRIBUTING.md, touching `Resources/Template/` needs a `swift test` pass (some Swift tests couple to template markup/manifest contents — find them via `grep -rl "Resources/Template/package.json\|ProjectValidator" Tests/`).

Run: `swift test --package-path .`
Expected: PASS — a devDependency addition doesn't change any sentinel file `ProjectValidator` checks for, so no test should react to this change. If something does fail, read why before assuming it's unrelated — per [`project_projectvalidator_sentinel_drift`], this exact class of drift has bitten this repo before.

- [ ] **Step 4: Commit**

```bash
git add Resources/Template/package.json Resources/Template/package-lock.json
git commit -m "feat(workers): add wrangler as a template devDependency for local dev (#708)"
```

---

## Task 3: `GuestProcessSupervisor` — the generic guest-process crash-restart component

**Files:**
- Create: `Sources/AnglesiteContainer/GuestProcessSupervisor.swift`
- Test: `Tests/AnglesiteContainerLocalTests/GuestProcessSupervisorTests.swift`

**Interfaces:**
- Consumes: `RestartPolicy`/`ProcessExitReason` from `Sources/AnglesiteCore/SupervisorBackend.swift` (reused, not redefined); `LogCenter.Stream` from `AnglesiteCore`.
- Produces: `GuestProcessLauncher` protocol, `GuestProcessHandle` protocol, `LinuxContainerProcessLauncher` (real conformer, consumed by Task 4), `GuestProcessSupervisor` actor with `start()`/`stop()`/`observe() -> AsyncStream<State>`. Task 4 (`ContainerizationControl.startWorkersDev`) is the first real caller.

- [ ] **Step 1: Write the failing tests first — the restart-policy state machine against a fake launcher**

Create `Tests/AnglesiteContainerLocalTests/GuestProcessSupervisorTests.swift`:

```swift
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

    @Test("a clean exit under .never gives up without restarting")
    func neverPolicyGivesUpOnExit() async throws {
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
        try await Task.sleep(for: .milliseconds(50))
        #expect(await launcher.launchCalls.count == 1)
    }
}
```

- [ ] **Step 2: Run the test target to confirm it fails to compile**

Run: `ANGLESITE_CONTAINER_TESTS=1 swift test --package-path . --filter GuestProcessSupervisorTests`
Expected: **build error** — `no such module 'AnglesiteContainer'` findable types (`GuestProcessLauncher`, `GuestProcessHandle`, `GuestProcessSupervisor` don't exist yet).

- [ ] **Step 3: Implement `GuestProcessSupervisor.swift`**

Create `Sources/AnglesiteContainer/GuestProcessSupervisor.swift`:

```swift
import Foundation
import Containerization
import AnglesiteCore

/// Abstraction over "launch one guest process and get back a live handle" — the seam
/// `GuestProcessSupervisor` tests against with a fake launcher, since a real launch needs a live
/// `LinuxContainer` inside a booted VM. `LinuxContainerProcessLauncher` (below) is the real
/// conformer, wrapping `LinuxContainer.exec`.
protocol GuestProcessLauncher: Sendable {
    func launch(
        id: String,
        argv: [String],
        environment: [String: String],
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> any GuestProcessHandle
}

/// One launched guest process: start it, wait for it to exit, or kill it early.
protocol GuestProcessHandle: Sendable {
    func start() async throws
    /// Suspends until the process exits (normally or via `kill()`), returning its exit code.
    func wait() async throws -> Int32
    func kill() async throws
    func delete() async throws
}

/// The real `GuestProcessLauncher`, wrapping `LinuxContainer.exec` — one instance per
/// `LinuxContainer`, constructed by `ContainerizationControl.startWorkersDev` alongside the
/// container itself.
struct LinuxContainerProcessLauncher: GuestProcessLauncher {
    let container: LinuxContainer

    func launch(
        id: String,
        argv: [String],
        environment: [String: String],
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> any GuestProcessHandle {
        let stdoutSink = LineStreamingWriter(stream: .stdout, onLine: onOutput)
        let stderrSink = LineStreamingWriter(stream: .stderr, onLine: onOutput)
        let proc = try await container.exec(id) { config in
            config.arguments = argv
            config.environmentVariables =
                ["PATH=\(LinuxProcessConfiguration.defaultPath)"]
                + environment.map { "\($0.key)=\($0.value)" }
            config.stdout = stdoutSink
            config.stderr = stderrSink
        }
        return LinuxProcessHandle(process: proc, stdoutSink: stdoutSink, stderrSink: stderrSink)
    }
}

private struct LinuxProcessHandle: GuestProcessHandle {
    let process: LinuxProcess
    let stdoutSink: LineStreamingWriter
    let stderrSink: LineStreamingWriter

    func start() async throws { try await process.start() }

    func wait() async throws -> Int32 {
        let status = try await process.wait()
        stdoutSink.flush()
        stderrSink.flush()
        return status.exitCode
    }

    func kill() async throws { try await process.kill(.term) }
    func delete() async throws { try await process.delete() }
}

/// Supervises one long-lived guest process with crash-restart, mirroring
/// `InProcessBackend.superviseLoop`'s host-process restart-policy shape but driving a guest
/// process via `GuestProcessLauncher` instead of a host `Process`. Generic — not specific to
/// wrangler-dev — so a future PR could retrofit `astro`/`mcp` onto the same mechanism without a
/// redesign, though only wrangler-dev uses it today; `astro`/`mcp` stay on the existing
/// fire-and-forget `runDetached` path (#708 design decision — out of scope to touch them here).
actor GuestProcessSupervisor {
    enum State: Sendable, Equatable {
        case running
        case restarting(attempt: Int)
        case stopped
        case failed(reason: String)
    }

    private let launcher: any GuestProcessLauncher
    private let id: String
    private let argv: [String]
    private let environment: [String: String]
    private let restartPolicy: RestartPolicy
    private let onOutput: @Sendable (String, LogCenter.Stream) -> Void

    private var current: (any GuestProcessHandle)?
    private var state: State = .stopped
    private var observers: [UUID: AsyncStream<State>.Continuation] = [:]
    private var isStopping = false
    private var superviseTask: Task<Void, Never>?
    private var generation = 0

    init(
        launcher: any GuestProcessLauncher,
        id: String,
        argv: [String],
        environment: [String: String] = [:],
        restartPolicy: RestartPolicy,
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) {
        self.launcher = launcher
        self.id = id
        self.argv = argv
        self.environment = environment
        self.restartPolicy = restartPolicy
        self.onOutput = onOutput
    }

    func observe() -> AsyncStream<State> {
        AsyncStream { continuation in
            let token = UUID()
            observers[token] = continuation
            continuation.yield(state)
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.removeObserver(token) }
            }
        }
    }

    private func removeObserver(_ token: UUID) { observers[token] = nil }

    private func setState(_ new: State) {
        state = new
        for continuation in observers.values { continuation.yield(new) }
    }

    /// Launches the process and begins supervising it. Throws only if the *first* launch fails —
    /// once running, crashes are handled by the restart loop internally, never by throwing back
    /// to this call's caller.
    func start() async throws {
        generation += 1
        let gen = generation
        let handle = try await launcher.launch(id: id, argv: argv, environment: environment, onOutput: onOutput)
        try await handle.start()
        current = handle
        isStopping = false
        setState(.running)
        superviseTask = Task { [weak self] in await self?.superviseLoop(handle: handle, generation: gen) }
    }

    /// Intentional stop — suppresses the next restart attempt. Idempotent.
    func stop() async {
        isStopping = true
        generation += 1
        if let current {
            try? await current.kill()
            try? await current.delete()
        }
        current = nil
        superviseTask?.cancel()
        superviseTask = nil
        setState(.stopped)
    }

    private func superviseLoop(handle initialHandle: any GuestProcessHandle, generation gen: Int) async {
        var handle = initialHandle
        var attempt = 0
        while true {
            let exitCode = try? await handle.wait()
            try? await handle.delete()
            guard gen == generation, !isStopping else { return }
            switch restartPolicy {
            case .never:
                setState(.failed(reason: "exited with code \(exitCode.map(String.init) ?? "unknown")"))
                return
            case .onCrash(let maxAttempts, let baseBackoff):
                attempt += 1
                guard attempt <= maxAttempts else {
                    onOutput("[\(id)] gave up restarting after \(attempt - 1) attempt(s)", .stderr)
                    setState(.failed(reason: "retries exhausted after \(attempt - 1) attempt(s), last exit code \(exitCode.map(String.init) ?? "unknown")"))
                    return
                }
                onOutput("[\(id)] crashed (exit \(exitCode.map(String.init) ?? "unknown")), restarting (attempt \(attempt)/\(maxAttempts))", .stderr)
                setState(.restarting(attempt: attempt))
                let backoffSeconds = baseBackoff * pow(2.0, Double(attempt - 1))
                try? await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
                guard gen == generation, !isStopping else { return }
                do {
                    let newHandle = try await launcher.launch(id: id, argv: argv, environment: environment, onOutput: onOutput)
                    try await newHandle.start()
                    current = newHandle
                    handle = newHandle
                    setState(.running)
                } catch {
                    setState(.failed(reason: "relaunch failed: \(error)"))
                    return
                }
            }
        }
    }
}
```

- [ ] **Step 4: Run the test target to confirm it passes**

Run: `ANGLESITE_CONTAINER_TESTS=1 swift test --package-path . --filter GuestProcessSupervisorTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteContainer/GuestProcessSupervisor.swift Tests/AnglesiteContainerLocalTests/GuestProcessSupervisorTests.swift
git commit -m "feat(workers): add GuestProcessSupervisor — generic guest-process crash-restart (#708)"
```

---

## Task 4: `ContainerizationControl` — real `startWorkersDev`/`stopWorkersDev`

**Files:**
- Modify: `Sources/AnglesiteContainer/ContainerizationControl.swift`

**Interfaces:**
- Consumes: `GuestProcessSupervisor`/`LinuxContainerProcessLauncher` (Task 3); `WorkerComposition.generateWranglerToml(workers:)` (existing, from PR #834); `VsockTCPProxy` (existing).
- Produces: `ContainerizationControl.startWorkersDev(siteID:workers:onOutput:) -> URL` / `.stopWorkersDev(siteID:)` — the real conformances of Task 1's protocol methods. Task 5 (`LocalContainerSiteRuntime`) is the first real caller.

This task has no separate unit-test step of its own — `ContainerizationControl` can only be exercised against a live VM (`ANGLESITE_CONTAINER_TESTS=1 ANGLESITE_CONTAINER_E2E=1`, via the probe script), which is Task 7. Verify this task by confirming the package still builds (`swift build --package-path .`) and by code review against Task 3's already-tested `GuestProcessSupervisor` contract.

- [ ] **Step 1: Add the guest port constant**

In `Sources/AnglesiteContainer/ContainerizationControl.swift`, near the existing port constants:

```swift
    private static let previewPort: UInt32 = 4321
    private static let mcpPort: UInt32 = 4399
```

add:

```swift
    /// Wrangler's own conventional local-dev port.
    private static let workersPort: UInt32 = 8787
```

- [ ] **Step 2: Extend `LiveContainers` with a supervisors dict and workers-dev proxy tracking**

Replace:

```swift
actor LiveContainers {
    private var containers: [String: LinuxContainer] = [:]
    private var proxies: [String: [VsockTCPProxy]] = [:]
    /// Per-site ext4 files (rootfs + initfs) to delete on teardown so disk doesn't grow per start/stop.
    private var ext4Artifacts: [String: [URL]] = [:]

    func container(for siteID: String) -> LinuxContainer? { containers[siteID] }

    func store(siteID: String, container: LinuxContainer, proxies ps: [VsockTCPProxy], ext4Artifacts artifacts: [URL]) {
        containers[siteID] = container
        proxies[siteID] = ps
        ext4Artifacts[siteID] = artifacts
    }

    func teardown(siteID: String) async {
        for p in proxies[siteID] ?? [] { await p.stop() }
        proxies[siteID] = nil
        // Stop the VM first (releases the file handles), then remove the backing ext4 images.
        if let c = containers[siteID] { try? await c.stop() }
        containers[siteID] = nil
        for url in ext4Artifacts[siteID] ?? [] {
            try? FileManager.default.removeItem(at: url)
        }
        ext4Artifacts[siteID] = nil
    }
}
```

with:

```swift
actor LiveContainers {
    private var containers: [String: LinuxContainer] = [:]
    private var proxies: [String: [VsockTCPProxy]] = [:]
    /// Per-site ext4 files (rootfs + initfs) to delete on teardown so disk doesn't grow per start/stop.
    private var ext4Artifacts: [String: [URL]] = [:]
    /// The workers-dev supervisor + its own proxy, present only while `startWorkersDev` has an
    /// active session for that site — absent entirely for a static-only site.
    private var workersDevSupervisors: [String: GuestProcessSupervisor] = [:]
    private var workersDevProxies: [String: VsockTCPProxy] = [:]

    func container(for siteID: String) -> LinuxContainer? { containers[siteID] }

    func store(siteID: String, container: LinuxContainer, proxies ps: [VsockTCPProxy], ext4Artifacts artifacts: [URL]) {
        containers[siteID] = container
        proxies[siteID] = ps
        ext4Artifacts[siteID] = artifacts
    }

    func storeWorkersDev(siteID: String, supervisor: GuestProcessSupervisor, proxy: VsockTCPProxy) {
        workersDevSupervisors[siteID] = supervisor
        workersDevProxies[siteID] = proxy
    }

    func workersDevSupervisor(for siteID: String) -> GuestProcessSupervisor? { workersDevSupervisors[siteID] }

    /// Stops just the workers-dev process + its proxy for `siteID`, leaving astro/mcp/the
    /// container itself untouched — used both for an explicit `stopWorkersDev` call and as the
    /// first step of a full `teardown`.
    func teardownWorkersDev(siteID: String) async {
        if let supervisor = workersDevSupervisors[siteID] { await supervisor.stop() }
        workersDevSupervisors[siteID] = nil
        if let proxy = workersDevProxies[siteID] { await proxy.stop() }
        workersDevProxies[siteID] = nil
    }

    func teardown(siteID: String) async {
        await teardownWorkersDev(siteID: siteID)
        for p in proxies[siteID] ?? [] { await p.stop() }
        proxies[siteID] = nil
        // Stop the VM first (releases the file handles), then remove the backing ext4 images.
        if let c = containers[siteID] { try? await c.stop() }
        containers[siteID] = nil
        for url in ext4Artifacts[siteID] ?? [] {
            try? FileManager.default.removeItem(at: url)
        }
        ext4Artifacts[siteID] = nil
    }
}
```

- [ ] **Step 3: Implement `startWorkersDev`/`stopWorkersDev` on `ContainerizationControl`**

Add these two methods to `ContainerizationControl` (near `stop(siteID:)`):

```swift
    /// See `LocalContainerControl.startWorkersDev` for the full contract.
    public func startWorkersDev(
        siteID: String,
        workers: [WorkerDescriptor],
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> URL {
        guard let container = await live.container(for: siteID) else {
            throw LocalContainerError.bootFailed("startWorkersDev: no live container for siteID '\(siteID)'")
        }

        // Any previously-running workers-dev session for this site is torn down first — this
        // method also serves as the "restart with a new active set" entry point once a future
        // Workers tab calls `LocalContainerSiteRuntime.updateActiveWorkers(_:)` (#708 design §2:
        // this PR builds that capability even though `start()` is its only caller today).
        await live.teardownWorkersDev(siteID: siteID)

        // Ephemeral, git-ignore-free local config: lives outside /workspace/site entirely, so a
        // transient local-dev session can never dirty the site's real, git-tracked wrangler.toml
        // (#708 design §4). No real resource ids — Miniflare creates local-persisted D1/KV/R2
        // stores automatically for declared bindings in --local mode.
        let toml = try WorkerComposition.generateWranglerToml(siteName: siteID, workers: workers)
        let configDir = "/tmp/anglesite-workers-dev/\(siteID)"
        let configPath = "\(configDir)/wrangler.toml"
        try await runToCompletion(container, id: "workers-dev-mkdir", onOutput: onOutput,
            ["mkdir", "-p", configDir])
        try await writeGuestFile(container, path: configPath, contents: toml, onOutput: onOutput)

        let launcher = LinuxContainerProcessLauncher(container: container)
        let supervisor = GuestProcessSupervisor(
            launcher: launcher,
            id: "workers-dev",
            argv: ["sh", "-lc",
                "cd /workspace/site && npx wrangler dev --local --config \(configPath) --port \(Self.workersPort)"],
            restartPolicy: .onCrash(maxAttempts: 3, baseBackoff: 0.5),
            onOutput: { line, stream in onOutput("[workers-dev] \(line)", stream) })
        try await supervisor.start()

        let dial: VsockDialer = { port in try await container.dialVsock(port: port) }
        let proxy = VsockTCPProxy(
            guestPort: Self.workersPort,
            dial: dial,
            onDialError: { error in onOutput("[proxy:workers-dev] dialVsock(\(Self.workersPort)) failed: \(error)", .stderr) },
            onEvent: { event in onOutput("[proxy:workers-dev] \(event)", .stdout) })
        let url: URL
        do {
            url = try await proxy.start()
        } catch {
            await supervisor.stop()
            throw LocalContainerError.bootFailed("workers-dev proxy start failed: \(error)")
        }

        await live.storeWorkersDev(siteID: siteID, supervisor: supervisor, proxy: proxy)
        return url
    }

    /// See `LocalContainerControl.stopWorkersDev` for the full contract.
    public func stopWorkersDev(siteID: String) async throws {
        await live.teardownWorkersDev(siteID: siteID)
    }
```

- [ ] **Step 4: Add the small `writeGuestFile` helper this uses**

`runToCompletion` (the existing `git clone`/`checkout` helper) only runs argv commands, no built-in way to write file contents from the host. Add a small helper near `runToCompletion`:

```swift
    /// Writes `contents` to `path` inside the guest via a one-shot `sh -c 'cat > path'` fed the
    /// text as a heredoc-safe base64 payload (avoiding any shell-quoting/escaping surface for
    /// `contents`, which is a generated wrangler.toml — untrusted only in the sense that it embeds
    /// a site name, already validated by `WorkerComposition.isValidSiteName`).
    private func writeGuestFile(
        _ container: LinuxContainer, path: String, contents: String,
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws {
        let encoded = Data(contents.utf8).base64EncodedString()
        try await runToCompletion(container, id: "write-\(path.replacingOccurrences(of: "/", with: "-"))",
            onOutput: onOutput,
            ["sh", "-c", "echo \(encoded) | base64 -d > \(path)"])
    }
```

- [ ] **Step 5: Build the package to confirm it compiles**

Run: `swift build --package-path .`
Expected: `Build complete!` — no errors. (This target can't be unit-tested without a live VM; Task 7 is the real verification.)

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteContainer/ContainerizationControl.swift
git commit -m "feat(workers): ContainerizationControl.startWorkersDev/stopWorkersDev (#708)"
```

---

## Task 5: `LocalContainerSiteRuntime` — worker-awareness

**Files:**
- Modify: `Sources/AnglesiteCore/LocalContainerSiteRuntime.swift`
- Test: `Tests/AnglesiteCoreTests/LocalContainerSiteRuntimeTests.swift`

**Interfaces:**
- Consumes: `WorkerActivation.effectiveActiveIDs`/`activeDescriptors` (existing, PR #834); `SiteConfigStore`/`SiteSettings` (existing); `WorkerCatalogFetcher` (existing); `AnglesitePackage.packageRoot(fromSourceURL:)` (Task 1); `LocalContainerControl.startWorkersDev` (Task 1's protocol addition, Task 4's real implementation, Task 1's fake).
- Produces: `LocalContainerSiteRuntime.updateActiveWorkers(_:)` (built and tested, `start()` is its only caller in this plan); `.ready(siteID:url:workersDevURL:)` populated when applicable.

- [ ] **Step 1: Write the failing tests first**

In `Tests/AnglesiteCoreTests/LocalContainerSiteRuntimeTests.swift`, add (adjust the exact helper names — `makeRuntime`/similar — to match this file's actual existing construction helper, found via reading the file's `start`-family tests):

```swift
    @Test("workers-dev starts when the effective active set is non-empty")
    func startsWorkersDevWhenActiveSetNonEmpty() async throws {
        let control = FakeLocalContainerControl(startResult: .success(Self.ok))
        await control.startWorkersDevResult = .success(URL(string: "http://127.0.0.1:51003")!)
        let package = try temporaryPackage()  // see Step 2 for this helper if it doesn't exist yet
        let configStore = SiteConfigStore(configDirectory: AnglesitePackage(url: package).configURL)
        try await configStore.save(SiteSettings(activeWorkerIDs: ["indieauth"]))
        let rt = LocalContainerSiteRuntime(
            ref: "HEAD", control: control, mcpClient: MCPClient(supervisor: .shared),
            workerCatalog: { [WorkerDescriptor(
                id: "indieauth", displayName: "IndieAuth", description: "d", group: "identity",
                binding: .settingsActivated, resources: .init(needsD1: true, needsKV: true, needsR2: false))] })

        await rt.start(siteID: "s1", siteDirectory: AnglesitePackage(url: package).sourceURL)

        guard case .ready(_, _, let workersDevURL) = await rt.state else {
            Issue.record("expected .ready, got \(await rt.state)")
            return
        }
        #expect(workersDevURL == URL(string: "http://127.0.0.1:51003")!)
        #expect(await control.startWorkersDevCalls.map(\.siteID) == ["s1"])
    }

    @Test("workers-dev does not start when the effective active set is empty")
    func doesNotStartWorkersDevWhenActiveSetEmpty() async throws {
        let control = FakeLocalContainerControl(startResult: .success(Self.ok))
        let package = try temporaryPackage()
        let rt = LocalContainerSiteRuntime(
            ref: "HEAD", control: control, mcpClient: MCPClient(supervisor: .shared),
            workerCatalog: { [] })

        await rt.start(siteID: "s1", siteDirectory: AnglesitePackage(url: package).sourceURL)

        guard case .ready(_, _, let workersDevURL) = await rt.state else {
            Issue.record("expected .ready, got \(await rt.state)")
            return
        }
        #expect(workersDevURL == nil)
        #expect(await control.startWorkersDevCalls.isEmpty)
    }

    @Test("teardown stops workers-dev via the ordinary control.stop(siteID:) path")
    func teardownStopsWorkersDev() async throws {
        let control = FakeLocalContainerControl(startResult: .success(Self.ok))
        await control.startWorkersDevResult = .success(URL(string: "http://127.0.0.1:51003")!)
        let package = try temporaryPackage()
        let configStore = SiteConfigStore(configDirectory: AnglesitePackage(url: package).configURL)
        try await configStore.save(SiteSettings(activeWorkerIDs: ["indieauth"]))
        let rt = LocalContainerSiteRuntime(
            ref: "HEAD", control: control, mcpClient: MCPClient(supervisor: .shared),
            workerCatalog: { [WorkerDescriptor(
                id: "indieauth", displayName: "IndieAuth", description: "d", group: "identity",
                binding: .settingsActivated, resources: .init(needsD1: true, needsKV: true, needsR2: false))] })

        await rt.start(siteID: "s1", siteDirectory: AnglesitePackage(url: package).sourceURL)
        await rt.stop()

        // stopWorkersDev is not called directly — teardown relies on the same control.stop(siteID:)
        // call it already makes, which (per Task 4) tears down workers-dev too. This test documents
        // that expectation against the fake, which only records `stop`, not `stopWorkersDev`.
        #expect(await control.stopped == ["s1"])
    }
```

- [ ] **Step 2: Confirm/add the `temporaryPackage()` helper if this test file doesn't already have one**

Check `Tests/AnglesiteCoreTests/LocalContainerSiteRuntimeTests.swift` for an existing `temporaryPackage()`/similar helper (other test files in this plan's earlier task, e.g. `SiteOperationsTests.swift`, already have one — mirror it exactly if this file needs its own):

```swift
    private func temporaryPackage() throws -> URL {
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalContainerSiteRuntimeTests-\(UUID().uuidString).anglesite", isDirectory: true)
        try FileManager.default.createDirectory(
            at: AnglesitePackage(url: package).sourceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: AnglesitePackage(url: package).configURL, withIntermediateDirectories: true)
        return package
    }
```

- [ ] **Step 3: Run the test target to confirm it fails to compile**

Run: `swift test --package-path . --filter LocalContainerSiteRuntimeTests`
Expected: **build error** — `extra argument 'workerCatalog' in call` (the initializer doesn't accept it yet) and `.ready` pattern-match arity errors in the new tests.

- [ ] **Step 4: Add worker-awareness to `LocalContainerSiteRuntime`**

Add the new init parameter. Replace:

```swift
        suddenTerminationController: SuddenTerminationController = .shared,
        beginActivity: @escaping @Sendable (String) -> ActivityAssertion.Lease = ActivityAssertion.begin
    ) {
        self.ref = ref
        self.control = control
        self.mcpClient = mcpClient
        self.knowledgeIndex = knowledgeIndex
        self.semanticRanker = semanticRanker
        self.conventionsEngine = conventionsEngine
        self.logCenter = logCenter
        self.connect = connect
        self.makeFileWatcher = makeFileWatcher
        self.importBundle = importBundle
        self.suddenTerminationController = suddenTerminationController
        self.beginActivity = beginActivity
    }
```

with:

```swift
        suddenTerminationController: SuddenTerminationController = .shared,
        beginActivity: @escaping @Sendable (String) -> ActivityAssertion.Lease = ActivityAssertion.begin,
        workerCatalog: @escaping @Sendable () async -> [WorkerDescriptor] = {
            await WorkerCatalogFetcher(catalogURL: WorkerCatalogFetcher.productionCatalogURL).catalog()
        }
    ) {
        self.ref = ref
        self.control = control
        self.mcpClient = mcpClient
        self.knowledgeIndex = knowledgeIndex
        self.semanticRanker = semanticRanker
        self.conventionsEngine = conventionsEngine
        self.logCenter = logCenter
        self.connect = connect
        self.makeFileWatcher = makeFileWatcher
        self.importBundle = importBundle
        self.suddenTerminationController = suddenTerminationController
        self.beginActivity = beginActivity
        self.workerCatalog = workerCatalog
    }
```

and add the stored property alongside the other `private let` closures near the top of the actor:

```swift
    private let workerCatalog: @Sendable () async -> [WorkerDescriptor]
```

Now wire it into `start()`. Replace:

```swift
            loadedKnowledgeSiteID = siteID
            startFileWatcher(siteID: siteID, projectRoot: siteDirectory, generation: gen)
            activeSiteID = siteID
            activeSiteDirectory = siteDirectory
            containerTerminationLease = suddenTerminationLease
            activityLease.release()
            setState(.ready(siteID: siteID, url: session.previewURL))
```

with:

```swift
            loadedKnowledgeSiteID = siteID
            startFileWatcher(siteID: siteID, projectRoot: siteDirectory, generation: gen)
            activeSiteID = siteID
            activeSiteDirectory = siteDirectory
            containerTerminationLease = suddenTerminationLease
            activityLease.release()

            // Local wrangler-dev (#708): computed once here, not wired to a live Settings
            // toggle yet (no Workers tab exists to trigger one — #700c). A start failure here
            // degrades to `workersDevURL: nil` rather than failing the whole runtime — wrangler-
            // dev is an add-on capability, unlike the MCP connection above.
            let workersDevURL = await self.startWorkersDevIfActive(siteID: siteID, siteDirectory: siteDirectory)
            guard gen == generation else { await abandonSupersededAttempt(); return }
            setState(.ready(siteID: siteID, url: session.previewURL, workersDevURL: workersDevURL))
```

Add the new private helper and the public `updateActiveWorkers(_:)` (built per the design doc's §2 scope decision — tested directly, `start()` is its only caller) near `resetNetworking()`:

```swift
    /// Computes the site's effective active-worker set (mirroring `DeployModel.runDeploy`'s own
    /// pipeline) and starts local `wrangler dev` if it's non-empty. Returns `nil` on any failure —
    /// logged, never thrown — or when there are no active workers. #708 design §7/§6: a settings-
    /// activated worker reliably resolves here; a component-tied worker may not, if this site's
    /// `SiteGraphExplorerSnapshot` hasn't been populated yet (accepted thin-slice limitation, not
    /// solved by this PR — see the design doc §6).
    private func startWorkersDevIfActive(siteID: String, siteDirectory: URL) async -> URL? {
        let configDirectory = AnglesitePackage(url: AnglesitePackage.packageRoot(fromSourceURL: siteDirectory)).configURL
        let settings = (try? await SiteConfigStore(configDirectory: configDirectory).load()) ?? SiteSettings()
        let catalog = await workerCatalog()
        let effectiveActiveIDs = WorkerActivation.effectiveActiveIDs(settings: settings, catalog: catalog, graph: nil)
        let workers = WorkerActivation.activeDescriptors(catalog: catalog, activeIDs: effectiveActiveIDs)
        guard !workers.isEmpty else { return nil }
        do {
            return try await control.startWorkersDev(
                siteID: siteID, workers: workers,
                onOutput: { [weak self] line, stream in
                    Task { await self?.appendBootLog(line, stream) }
                })
        } catch {
            await logCenter.append(
                source: "container:\(siteID)", stream: .stderr,
                text: "local wrangler-dev failed to start: \(error) — active workers will have no local dev endpoint this session")
            return nil
        }
    }

    /// `startWorkersDevIfActive`'s `onOutput` needs an actor-isolated sink for lines that may
    /// arrive after `start()` itself has returned (wrangler-dev keeps running for the session's
    /// lifetime) — appends directly to `logCenter` rather than routing through the boot-log
    /// stream/continuation, which is intentionally finished once `start()` settles.
    private func appendBootLog(_ line: String, _ stream: LogCenter.Stream) async {
        guard let siteID = activeSiteID else { return }
        await logCenter.append(source: "container:\(siteID)", stream: stream, text: line)
    }

    /// Recomputes the effective active-worker set and restarts local wrangler-dev to match — the
    /// capability a future Workers tab (#700c) calls on toggle. Not called anywhere in this PR
    /// besides `start()`'s own initial computation (#708 design §2) — built and tested now so
    /// #700c needs no further runtime-side work.
    public func updateActiveWorkers(_ settings: SiteSettings) async {
        guard let siteID = activeSiteID, let siteDirectory = activeSiteDirectory else { return }
        let catalog = await workerCatalog()
        let effectiveActiveIDs = WorkerActivation.effectiveActiveIDs(settings: settings, catalog: catalog, graph: nil)
        let workers = WorkerActivation.activeDescriptors(catalog: catalog, activeIDs: effectiveActiveIDs)
        let workersDevURL: URL?
        if workers.isEmpty {
            try? await control.stopWorkersDev(siteID: siteID)
            workersDevURL = nil
        } else {
            workersDevURL = await startWorkersDevIfActive(siteID: siteID, siteDirectory: siteDirectory)
        }
        if case .ready(let readySiteID, let url, _) = current, readySiteID == siteID {
            setState(.ready(siteID: readySiteID, url: url, workersDevURL: workersDevURL))
        }
    }
```

Note: `startWorkersDevIfActive` re-derives the effective set from disk rather than accepting it as a parameter, so `updateActiveWorkers(_:)` can call it too without duplicating the settings→descriptors pipeline — the `settings` parameter to `updateActiveWorkers` is accepted for a future caller's convenience (a Workers tab that just saved new settings and wants to push them immediately) but this method still re-reads the catalog itself; only `graph: nil` is a shared simplification with `start()`, consistent with the design doc's accepted component-tied limitation.

- [ ] **Step 5: Run the test target**

Run: `swift test --package-path . --filter LocalContainerSiteRuntimeTests`
Expected: PASS — all pre-existing tests unaffected (the new `workerCatalog` param defaults to a real fetch only reachable in production, but existing tests never inspect `workersDevURL` and default-construct without it, so `.ready(siteID:url:)`-shaped `#expect` comparisons still compile and pass against a `.ready(...)` value whose `workersDevURL` is `nil` on both sides — unless a pre-existing test's `workerCatalog` default triggers a real network call. Check this specifically: if any pre-existing test doesn't inject `workerCatalog: { [] }` explicitly, its `start()` call will invoke the REAL `WorkerCatalogFetcher` default, doing a live network fetch in a unit test — unacceptable. If so, this step must add `workerCatalog: { [] }` to every pre-existing `LocalContainerSiteRuntime(...)` test construction as part of this step, not skip it.)

Run: `grep -n "LocalContainerSiteRuntime(" Tests/AnglesiteCoreTests/LocalContainerSiteRuntimeTests.swift` and add `workerCatalog: { [] }` to every construction this step's grep finds that doesn't already specify one, before considering this step done.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/LocalContainerSiteRuntime.swift Tests/AnglesiteCoreTests/LocalContainerSiteRuntimeTests.swift
git commit -m "feat(workers): LocalContainerSiteRuntime starts local wrangler-dev when workers are active (#708)"
```

---

## Task 6: AnglesiteApp — fix pattern-match sites, expose `workersDevURL`

**Files:**
- Modify: `Sources/AnglesiteApp/PreviewModel.swift:312`
- Modify: `Sources/AnglesiteApp/SiteWindow.swift:754`
- Modify: `Sources/AnglesiteApp/StartupProgressModel.swift:42`

**Interfaces:**
- Consumes: `SiteRuntimeState.ready(siteID:url:workersDevURL:)` (Task 1).
- Produces: `PreviewModel.workersDevURL: URL?` — no consumer yet in this plan (no Workers tab/debug UI to show it), but the accessor exists so one doesn't need retrofitting later, mirroring `readyURL`'s exact pattern.

- [ ] **Step 1: Fix the three pattern-match sites (mechanical — none of these three need the new value, they only need to keep compiling)**

In `Sources/AnglesiteApp/StartupProgressModel.swift`, replace:
```swift
        case .ready(let id, _):
```
with:
```swift
        case .ready(let id, _, _):
```

In `Sources/AnglesiteApp/SiteWindow.swift`, replace:
```swift
        case .ready(_, let url):
```
with:
```swift
        case .ready(_, let url, _):
```

- [ ] **Step 2: Add `PreviewModel.workersDevURL`, updating the one site that should extract the new value**

In `Sources/AnglesiteApp/PreviewModel.swift`, replace:

```swift
    /// The ready preview URL, if the session is currently `.ready`.
    var readyURL: URL? {
        if case .ready(_, let url) = state { return url }
        return nil
    }
```

with:

```swift
    /// The ready preview URL, if the session is currently `.ready`.
    var readyURL: URL? {
        if case .ready(_, let url, _) = state { return url }
        return nil
    }

    /// The local `wrangler dev --local` endpoint, if the session is `.ready` and the site has an
    /// active worker (#708). `nil` for a static-only site — no debug-panel consumer exists yet
    /// (no Workers tab, #700c), so this is currently unread outside tests, but the accessor
    /// mirrors `readyURL`'s exact pattern so a future consumer needs no runtime changes.
    var workersDevURL: URL? {
        if case .ready(_, _, let workersDevURL) = state { return workersDevURL }
        return nil
    }
```

- [ ] **Step 3: Build the app target**

Run: `xcodegen generate` (if `Anglesite.xcodeproj` doesn't exist in this worktree yet), then:
Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteApp/PreviewModel.swift Sources/AnglesiteApp/SiteWindow.swift Sources/AnglesiteApp/StartupProgressModel.swift
git commit -m "feat(workers): thread workersDevURL through AnglesiteApp's runtime-state consumers (#708)"
```

---

## Task 7: End-to-end verification

**Files:**
- Modify: `Tests/AnglesiteContainerLocalTests/ContainerizationControlTests.swift`
- Modify: `Sources/AnglesiteContainerProbe/main.swift`
- Modify: `scripts/run-container-probe.sh`

**Interfaces:**
- Consumes: everything from Tasks 1-6.
- Produces: a real, live-VM-backed proof that a booted container with an active worker serves a reachable `wrangler dev --local` endpoint — the human-run verification gate this whole feature needs, since neither CI nor a bare `swift test` can carry the virtualization entitlement.

- [ ] **Step 1: Add the e2e test case to `ContainerizationControlTests.swift`**

Read the existing `bootsAndServes` test in this file first (it's this suite's closest sibling — same throwaway-repo/HTTP-poll shape) and add a new case following its exact structure:

```swift
    @Test("startWorkersDev boots a reachable local wrangler-dev endpoint for an active worker")
    func startsWorkersDevForActiveWorker() async throws {
        try #require(enabled)  // this file's existing ANGLESITE_CONTAINER_E2E runtime gate
        let siteID = "workers-dev-e2e"
        let control = ContainerizationControl()
        let repo = try makeThrowawayAstroRepo()  // this file's existing helper
        defer { try? FileManager.default.removeItem(at: repo) }

        let session = try await control.start(siteID: siteID, sourceRepo: repo, ref: "HEAD", onOutput: { _, _ in })
        defer { Task { try? await control.stop(siteID: siteID) } }

        let workers = [WorkerDescriptor(
            id: "indieauth", displayName: "IndieAuth", description: "d", group: "identity",
            binding: .settingsActivated, resources: .init(needsD1: true, needsKV: true, needsR2: false))]
        let workersDevURL = try await control.startWorkersDev(siteID: siteID, workers: workers, onOutput: { _, _ in })

        let ok = await pollForHTTPResponse(workersDevURL, timeout: .seconds(60))  // this file's existing helper
        #expect(ok, "wrangler dev --local never answered within the timeout")
    }
```

(`enabled`/`makeThrowawayAstroRepo`/`pollForHTTPResponse` — confirm the exact existing helper names in this file at implementation time and reuse them verbatim; do not reintroduce duplicates.)

- [ ] **Step 2: Add the `workers-dev` subcommand to the probe**

In `Sources/AnglesiteContainerProbe/main.swift`, replace:

```swift
        switch subcommand {
        case "echo":
            exitCode = await runEcho()
        case "boot":
            exitCode = await runBoot()
        default:
            FileHandle.standardError.write(Data("unknown subcommand '\(subcommand)' (expected echo|boot)\n".utf8))
            exitCode = 2
        }
```

with:

```swift
        switch subcommand {
        case "echo":
            exitCode = await runEcho()
        case "boot":
            exitCode = await runBoot()
        case "workers-dev":
            exitCode = await runWorkersDev()
        default:
            FileHandle.standardError.write(Data("unknown subcommand '\(subcommand)' (expected echo|boot|workers-dev)\n".utf8))
            exitCode = 2
        }
```

and add a new method mirroring `runBoot()`'s exact shape:

```swift
    // MARK: - workers-dev

    /// Mirrors `ContainerizationControlTests.startsWorkersDevForActiveWorker`: boot a container,
    /// start local wrangler-dev for one active (fixture) worker, poll its URL for a live HTTP
    /// response. The #708 local-runtime feature's own decision gate.
    private static func runWorkersDev() async -> Int32 {
        let siteID = "workers-dev-probe"
        let control = ContainerizationControl()

        let repo: URL
        do {
            repo = try makeThrowawayAstroRepo()
        } catch {
            print("WORKERS-DEV: FAIL — could not create throwaway Astro repo: \(error)")
            return 1
        }
        defer { try? FileManager.default.removeItem(at: repo) }

        do {
            _ = try await control.start(siteID: siteID, sourceRepo: repo, ref: "HEAD", onOutput: logLine)
        } catch {
            print("WORKERS-DEV: FAIL — control.start threw: \(error)")
            return 1
        }

        let workers = [WorkerDescriptor(
            id: "indieauth", displayName: "IndieAuth", description: "probe fixture", group: "identity",
            binding: .settingsActivated, resources: .init(needsD1: true, needsKV: true, needsR2: false))]
        let workersDevURL: URL
        do {
            workersDevURL = try await control.startWorkersDev(siteID: siteID, workers: workers, onOutput: logLine)
        } catch {
            print("WORKERS-DEV: FAIL — control.startWorkersDev threw: \(error)")
            try? await control.stop(siteID: siteID)
            return 1
        }

        let ok = await pollForHTTPResponse(workersDevURL, timeout: .seconds(60))
        try? await control.stop(siteID: siteID)

        guard ok else {
            print("WORKERS-DEV: FAIL — \(workersDevURL) never answered within the timeout")
            return 1
        }

        print("WORKERS-DEV: PASS")
        return 0
    }
```

- [ ] **Step 3: Update `scripts/run-container-probe.sh`'s subcommand list**

Replace:

```sh
SUBCOMMAND="${1:-}"
case "${SUBCOMMAND}" in
    echo|boot) ;;
    *)
        echo "usage: $(basename "$0") <echo|boot>" >&2
        exit 2
        ;;
esac
```

with:

```sh
SUBCOMMAND="${1:-}"
case "${SUBCOMMAND}" in
    echo|boot|workers-dev) ;;
    *)
        echo "usage: $(basename "$0") <echo|boot|workers-dev>" >&2
        exit 2
        ;;
esac
```

and update the script's own header comment (the `Usage:` block near the top) to list `workers-dev` alongside `echo`/`boot`.

- [ ] **Step 4: Attempt the probe run**

Run: `scripts/run-container-probe.sh workers-dev`
Expected: `WORKERS-DEV: PASS`. **If this sandboxed execution environment cannot boot a real VM** (nested virtualization is frequently unavailable inside a CI/agent sandbox, unlike a real entitled Mac), this step will fail for reasons unrelated to the code — report that explicitly rather than treating a sandbox limitation as a code bug, and flag to the user that they need to run this command themselves on a real Mac before merging, per CLAUDE.md's "the app cannot bypass" spirit applied to this verification gate.

- [ ] **Step 5: Full verification**

Run: `swift test --package-path .` (expect PASS, modulo the known unrelated `GenerableTypesTests` FM flake)
Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build` (expect `** BUILD SUCCEEDED **`)

- [ ] **Step 6: Commit**

```bash
git add Tests/AnglesiteContainerLocalTests/ContainerizationControlTests.swift Sources/AnglesiteContainerProbe/main.swift scripts/run-container-probe.sh
git commit -m "test(workers): e2e coverage + probe subcommand for local wrangler-dev (#708)"
```

- [ ] **Step 7: Open the PR**

```bash
git push -u origin HEAD
gh pr create --title "feat(workers): local wrangler-dev runtime in LocalContainerSiteRuntime (#708)" --body "$(cat <<'EOF'
## Summary
- Adds a local `wrangler dev --local` guest process to `LocalContainerSiteRuntime`, started only when a site's effective active-worker set is non-empty — the last of #708's three prerequisites.
- New generic `GuestProcessSupervisor` (`Sources/AnglesiteContainer/GuestProcessSupervisor.swift`) gives it real crash-restart, the first guest process in this codebase to have that — mirrors `InProcessBackend`'s host-process `RestartPolicy` shape.
- Additive-only surface: `SiteRuntimeState.ready`/`LocalContainerSession` both gain an optional `workersDevURL`; `LocalContainerControl` gains `startWorkersDev`/`stopWorkersDev`. No `SiteRuntime` protocol change.
- `wrangler` becomes a template devDependency (no Dockerfile change, no paired sidecar PR).
- Design doc: `docs/superpowers/specs/2026-07-20-local-wrangler-dev-runtime-design.md`.

**Known, accepted thin-slice limitations** (see design doc §2/§6):
- No live-toggle-restart caller yet — `updateActiveWorkers(_:)` is built and tested, but only `start()` calls it; the Workers tab (#700c) becomes its second caller later.
- Component-tied worker detection needs a populated `SiteGraphExplorerSnapshot`, likely not yet scanned when a site window first opens — a settings-activated worker reliably starts; a component-tied one may not, this session.
- `astro`/`mcp` are not retrofitted onto `GuestProcessSupervisor` — they stay on the existing `runDetached` path.

## Paired PR check
- [x] This change is **self-contained** to `Anglesite-app`.
- [ ] This change **needs a paired PR** in `Anglesite/anglesite`.

> No MCP schema change — only consumes existing `WorkerDescriptor`/`WorkerComposition` from PR #834.

## Test plan
- [x] `swift test --package-path .`
- [x] `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
- [ ] `scripts/run-container-probe.sh workers-dev` — **requires a real entitled Mac**, not this sandboxed environment; run before merging.
EOF
)"
```

- [ ] **Step 8: Close out #708**

Once this PR merges, close #708 (all three prerequisites done) and remove the `🛠️ In Progress` label if still present.
