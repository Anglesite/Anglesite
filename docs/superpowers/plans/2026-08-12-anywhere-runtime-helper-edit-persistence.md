# Anywhere Runtime — Helper Edit Persistence Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the gap [PR #1405](https://github.com/Anglesite/Anglesite/pull/1405) (Anywhere Runtime P1) shipped deliberately open: a phone/second-process edit relayed through the `AnglesiteRemote` Mac helper is live in the guest but never lands in the host's canonical `Source/` git repo. After this plan, a commit-bearing MCP edit reply flowing through the helper's `mcp` data channel is exported from the guest and imported into `Source/` — mirroring `LocalContainerSiteRuntime.persistEdit`, which the main `Anglesite.app` already does for every local edit.

**Architecture:** Extract the guest-export + host-import sequence already proven by `LocalContainerSiteRuntime.persistEdit` into a shared, actor-independent function (`ContainerEditExport`, new file in `AnglesiteCore`) so both the main app's runtime and the helper can drive it. Add a new decorator, `HelperEditPersister` (new file in `AnglesiteRemote`), that wraps the helper's existing `LoopbackMCPBridge.handle` — after relaying a reply verbatim, it inspects commit-bearing `tools/call` replies and fires the export/import hop, synthesizing a JSON-RPC error back to the caller only if persistence itself fails (mirroring `MCPApplyEditRouter.apply`'s existing ack-after-persist ordering, which exists specifically to prevent #718-style data loss). Wire it into the helper's session loop (`Sources/anglesite-remote-helper/main.swift`), gated so it only runs when this helper session actually booted (owns) the container — a borrowed container (another process's claim) belongs to a process this one has no in-process VM handle for, so `control.exec` against it cannot work (confirmed: `ContainerizationControl` keys its guest VM handles in an in-process `[String: LinuxContainer]` dictionary, not a system-wide registry).

**Tech Stack:** Swift 6.4 / Xcode 27, Swift Testing, `AnglesiteCore` (`InProcessEditPersistence`, `LocalContainerControl`, `SiteRuntimePersistenceError`, `LogCenter`), `AnglesiteP2P` (`MCPChannelResponder.Handler`, `JSONValue`), `AnglesiteRemote` (P1, already shipped: `LoopbackMCPBridge`, `RemoteContainerSession`).

## Global Constraints

- `swift test` needs `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` on the owner's machine (CommandLineTools swift is too old).
- New public API needs `///` doc comments per `docs/comment-style-guide.md` (CI fails on broken DocC links).
- Commit subjects ≤72 chars, conventional-commit format, reference #1208.
- Tests are Swift Testing (`@Test`, `#expect`), not XCTest.
- **Persistence only runs when this helper session owns the container.** `RemoteContainerSession.ensureRunning` returns a borrowed `LocalContainerSession` (built from another process's published claim) without ever calling `control.start`/`control.exec` against it. This plan adds `RemoteContainerSession.isOwner(siteID:)` and gates the persister on it — persisting a borrowed session's edits is out of scope (the owning process, if it wires its own persistence, is responsible; today that is only ever `LocalContainerSiteRuntime`-backed `Anglesite.app`, which already persists its own edits).
- **`create_page`/`create_post` still can't be used to prove this end-to-end** — their guest-side commit is `nil` today (a separate, out-of-scope sidecar bug in `Anglesite/anglesite-skills`, already pinned by `HelperContainerE2ETests`'s existing `guestCommit == nil` assertion — untouched by this plan). This plan's new E2E proof uses `apply_edit` instead, whose guest-side commit already works (proven daily by the main app, and by `AnglesiteContainerProbe.runApplyEdit`, `Sources/AnglesiteContainerProbe/main.swift:538-635`).
- Code lands on the current branch/worktree (already dedicated to #1208 work). Run `xcodegen generate` if `project.yml` changes (it does not, in this plan) — not needed here since no new targets/files outside existing `Sources/AnglesiteCore`, `Sources/AnglesiteRemote`, `Sources/anglesite-remote-helper`, `Tests/AnglesiteCoreTests`, `Tests/AnglesiteRemoteTests` are added at the target level.

## File Structure

```
Sources/AnglesiteCore/ContainerEditExport.swift        # new — shared guest-export + host-import
Sources/AnglesiteCore/LocalContainerSiteRuntime.swift   # modified — persistEdit calls the shared type
Sources/AnglesiteRemote/HelperEditPersister.swift       # new — decorator over LoopbackMCPBridge.handle
Sources/AnglesiteRemote/RemoteContainerSession.swift    # modified — + isOwner(siteID:)
Sources/anglesite-remote-helper/main.swift               # modified — wires the persister, shares one
                                                           #   ContainerizationControl() instance
Tests/AnglesiteCoreTests/ContainerEditExportTests.swift  # new
Tests/AnglesiteRemoteTests/HelperEditPersisterTests.swift  # new
Tests/AnglesiteRemoteTests/RemoteContainerSessionTests.swift  # modified — + isOwner tests
Tests/AnglesiteRemoteTests/FakeLocalContainerControl.swift  # modified — + injectable execHandler
Tests/AnglesiteRemoteTests/HelperContainerE2ETests.swift  # modified — new apply_edit persistence
                                                           #   proof; delete the now-inverted
                                                           #   HelperEditDurabilityBoundaryTests pin
```

Out of scope: fixing the sidecar's `create_page`/`create_post` git-identity bug (separate repo,
`Anglesite/anglesite-skills`); wiring persistence for a *borrowed* (non-owned) helper session;
any change to `RemoteSiteResolver`/production site discovery (main.swift's CLI-arg entry point is
untouched by this plan beyond adding the persister).

---

### Task 1: `ContainerEditExport` — shared guest-export + host-import

**Files:**
- Create: `Sources/AnglesiteCore/ContainerEditExport.swift`
- Modify: `Sources/AnglesiteCore/LocalContainerSiteRuntime.swift:259-370` (`persistEdit` calls the new type instead of inlining the script/exec/parse/import sequence)
- Test: `Tests/AnglesiteCoreTests/ContainerEditExportTests.swift`

**Interfaces:**
- Consumes: `LocalContainerControl`, `ContainerExecResult`, `LogCenter.Stream`, `SiteRuntimePersistenceError`, `InProcessEditPersistence.importBundle` (all pre-existing, `AnglesiteCore`).
- Produces:

```swift
public enum ContainerEditExport {
    public static func isPlausibleCommit(_ commit: String) -> Bool
    public static func exportAndImport(
        commit: String,
        siteID: String,
        control: any LocalContainerControl,
        sourceDirectory: URL,
        onLog: @escaping @Sendable (String, LogCenter.Stream) -> Void,
        importBundle: @Sendable (URL, String, URL) async throws -> Void = /* InProcessEditPersistence.importBundle by default */
    ) async throws
}
```

- [ ] **Step 1: Write failing tests**

```swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct ContainerEditExportTests {
    @Test func isPlausibleCommitAcceptsSevenToSixtyFourHexChars() {
        #expect(ContainerEditExport.isPlausibleCommit("abc1234"))
        #expect(ContainerEditExport.isPlausibleCommit(String(repeating: "a", count: 64)))
        #expect(!ContainerEditExport.isPlausibleCommit("abc123")) // 6 chars, too short
        #expect(!ContainerEditExport.isPlausibleCommit(String(repeating: "a", count: 65))) // too long
        #expect(!ContainerEditExport.isPlausibleCommit("not-hex!"))
    }

    /// A `LocalContainerControl` fake whose `exec` returns a canned export-script result instead
    /// of running a real container — this suite never boots anything.
    actor ScriptedControl: LocalContainerControl {
        private let result: Result<ContainerExecResult, Error>
        private(set) var lastArgv: [String]?
        init(result: Result<ContainerExecResult, Error>) { self.result = result }
        func start(siteID: String, sourceRepo: URL, ref: String, onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void) async throws -> LocalContainerSession {
            fatalError("not exercised by this suite")
        }
        func stop(siteID: String) async throws {}
        func exec(siteID: String, argv: [String], environment: [String: String], workingDirectory: String, onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void) async throws -> ContainerExecResult {
            lastArgv = argv
            return try result.get()
        }
        func execInteractive(siteID: String, argv: [String], environment: [String: String], workingDirectory: String, onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void) async throws -> InteractiveExecHandle {
            InteractiveExecHandle(write: { _ in }, terminate: {})
        }
        func startWorkersDev(siteID: String, workers: [WorkerDescriptor], onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void) async throws -> URL {
            URL(string: "http://127.0.0.1:1")!
        }
        func stopWorkersDev(siteID: String) async throws {}
    }

    @Test func exportAndImportCallsImportBundleWithParsedCommitAndBundleBytes() async throws {
        let bundleBytes = Data("bundle-bytes".utf8)
        let stdout = "abcdef0123456789abcdef0123456789abcdef01\n" + bundleBytes.base64EncodedString()
        let control = ScriptedControl(result: .success(ContainerExecResult(exitCode: 0, stdout: stdout, stderr: "")))
        var imported: (bundle: URL, commit: String, source: URL)?
        var loggedLines: [(String, LogCenter.Stream)] = []

        try await ContainerEditExport.exportAndImport(
            commit: "abcdef0",
            siteID: "site-1",
            control: control,
            sourceDirectory: URL(fileURLWithPath: "/tmp/source"),
            onLog: { line, stream in loggedLines.append((line, stream)) },
            importBundle: { bundle, commit, source in
                imported = (bundle, commit, source)
                #expect(try Data(contentsOf: bundle) == bundleBytes)
            }
        )

        #expect(imported?.commit == "abcdef0123456789abcdef0123456789abcdef01")
        #expect(imported?.source == URL(fileURLWithPath: "/tmp/source"))
        #expect(loggedLines.contains { $0.0.contains("persisted") && $0.1 == .stdout })
        #expect(await control.lastArgv?.contains("abcdef0") == true)
    }

    @Test func exportAndImportThrowsOnNonZeroExit() async {
        let control = ScriptedControl(result: .success(ContainerExecResult(exitCode: 1, stdout: "", stderr: "boom")))
        await #expect(throws: SiteRuntimePersistenceError.self) {
            try await ContainerEditExport.exportAndImport(
                commit: "abcdef0", siteID: "site-1", control: control,
                sourceDirectory: URL(fileURLWithPath: "/tmp/source"),
                onLog: { _, _ in }, importBundle: { _, _, _ in Issue.record("must not import on exec failure") })
        }
    }

    @Test func exportAndImportThrowsOnMalformedStdout() async {
        let control = ScriptedControl(result: .success(ContainerExecResult(exitCode: 0, stdout: "only-one-line", stderr: "")))
        await #expect(throws: SiteRuntimePersistenceError.self) {
            try await ContainerEditExport.exportAndImport(
                commit: "abcdef0", siteID: "site-1", control: control,
                sourceDirectory: URL(fileURLWithPath: "/tmp/source"),
                onLog: { _, _ in }, importBundle: { _, _, _ in Issue.record("must not import on malformed stdout") })
        }
    }

    @Test func exportAndImportLogsAndRethrowsWhenImportBundleFails() async {
        let stdout = "abcdef0123456789abcdef0123456789abcdef01\n" + Data("x".utf8).base64EncodedString()
        let control = ScriptedControl(result: .success(ContainerExecResult(exitCode: 0, stdout: stdout, stderr: "")))
        var loggedLines: [(String, LogCenter.Stream)] = []
        await #expect(throws: SiteRuntimePersistenceError.self) {
            try await ContainerEditExport.exportAndImport(
                commit: "abcdef0", siteID: "site-1", control: control,
                sourceDirectory: URL(fileURLWithPath: "/tmp/source"),
                onLog: { line, stream in loggedLines.append((line, stream)) },
                importBundle: { _, _, _ in throw SiteRuntimePersistenceError.syncFailed("nope") })
        }
        #expect(loggedLines.contains { $0.0.contains("persist failed") && $0.1 == .stderr })
    }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter ContainerEditExportTests` → FAIL (`ContainerEditExport` doesn't exist yet).

- [ ] **Step 3: Implement `Sources/AnglesiteCore/ContainerEditExport.swift`**

```swift
import Foundation

/// Exports one commit from a running container's guest clone as a git bundle and imports it into
/// the host's canonical `Source/` repository — the guest-to-host half of edit persistence
/// (design spec `docs/superpowers/specs/2026-08-03-anywhere-runtime-webrtc-design.md`
/// §Architecture 5). Factored out of `LocalContainerSiteRuntime.persistEdit` so
/// `HelperEditPersister` (Anywhere-runtime P1's Mac helper — no actor lifecycle/generation state
/// of its own; one session per process) can drive the identical guest-export + host-import
/// sequence without depending on that actor. `LocalContainerSiteRuntime` keeps its own
/// generation/activeSiteID/persistence-slot guards *around* a call to this function; this
/// function itself has no opinion about site lifecycle or concurrency — callers own that.
///
/// `LocalContainerSiteRuntime.persistEdit`'s original inline version re-checked its actor's
/// generation *between* the guest exec and the host import, refusing to import into a
/// `siteDirectory` captured before a since-superseded site switch. That check is dropped here
/// deliberately, not by oversight: the `siteDirectory` a caller passes is already a value fixed
/// before the call (never re-read), and `InProcessEditPersistence.importBundle`'s own
/// fast-forward-only precondition (the exported commit's parent must equal the target repo's
/// current HEAD) refuses exactly the case the removed check existed to avoid — a diverged/
/// superseded repository fails there instead, loudly, rather than silently importing into the
/// wrong state.
public enum ContainerEditExport {
    private static let hexDigits = CharacterSet(charactersIn: "0123456789abcdefABCDEF")

    /// True when `commit` looks like a plausible (partial or full) git hash: 7–64 hex characters.
    public static func isPlausibleCommit(_ commit: String) -> Bool {
        (7...64).contains(commit.count) && commit.unicodeScalars.allSatisfy { hexDigits.contains($0) }
    }

    /// Runs the guest-side bundle-export script inside `siteID`'s container, then imports the
    /// resulting bundle into `sourceDirectory`. Throws `SiteRuntimePersistenceError` on any
    /// failure — the same taxonomy `LocalContainerSiteRuntime.persistEdit` already surfaces.
    ///
    /// - Parameters:
    ///   - commit: The guest-side commit hash to export. Callers are expected to have already
    ///     checked `isPlausibleCommit` for their own reason string; this function does not
    ///     re-validate the input commit (only the container's *returned* full hash, below).
    ///   - siteID: The container's identity, passed straight to `control.exec`.
    ///   - control: The container backend to `exec` the export script against. Must be the same
    ///     `LocalContainerControl` instance that booted `siteID` — `exec` addresses an in-process
    ///     guest VM handle, not a system-wide registry.
    ///   - sourceDirectory: The host's canonical `Source/` git repository to import into.
    ///   - onLog: Receives the export script's stderr lines as they arrive, plus one final
    ///     summary line — `"persisted <commit> to Source"` (`.stdout`) on success, or
    ///     `"persist failed: <reason>"` (`.stderr`) on failure. Callers route this to their own
    ///     log sink (`LogCenter`, stderr, `os.Logger`, ...).
    ///   - importBundle: The host-side import hop. Defaults to
    ///     `InProcessEditPersistence.importBundle`; injectable so callers can fake the libgit2 hop
    ///     in tests without touching a real repository.
    public static func exportAndImport(
        commit: String,
        siteID: String,
        control: any LocalContainerControl,
        sourceDirectory: URL,
        onLog: @escaping @Sendable (String, LogCenter.Stream) -> Void,
        importBundle: @Sendable (URL, String, URL) async throws -> Void = { bundle, commit, source in
            #if !os(iOS)
            try await InProcessEditPersistence.importBundle(bundle, commit: commit, into: source)
            #else
            throw SiteRuntimePersistenceError.syncFailed("edit persistence is unavailable on this platform")
            #endif
        }
    ) async throws {
        // Export exactly the requested commit through stdout as a base64 git bundle. The canonical
        // repo remains mounted read-only, so no guest process can alter its worktree, refs, or hooks.
        let exportScript = #"""
        set -eu
        runtime=/workspace/site
        commit="$1"
        ref=refs/heads/anglesite-persist
        bundle=/tmp/anglesite-persist-$$.bundle
        cleanup() {
          git -C "$runtime" update-ref -d "$ref" >/dev/null 2>&1 || true
          rm -f "$bundle"
        }
        trap cleanup EXIT HUP INT TERM

        full=$(git -C "$runtime" rev-parse "$commit^{commit}")
        git -C "$runtime" update-ref "$ref" "$full"
        if parent=$(git -C "$runtime" rev-parse "$full^" 2>/dev/null); then
          git -C "$runtime" bundle create "$bundle" "$ref" "^$parent"
        else
          git -C "$runtime" bundle create "$bundle" "$ref"
        fi
        printf '%s\n' "$full"
        base64 "$bundle"
        """#

        let result: ContainerExecResult
        do {
            result = try await control.exec(
                siteID: siteID,
                argv: ["sh", "-c", exportScript, "anglesite-export", commit],
                environment: [:],
                workingDirectory: "/workspace/site",
                onOutput: { line, stream in
                    // stdout is the base64 bundle transport, not human-readable diagnostic output.
                    guard stream == .stderr else { return }
                    onLog(line, stream)
                }
            )
        } catch {
            throw SiteRuntimePersistenceError.syncFailed(error.localizedDescription)
        }
        guard result.exitCode == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SiteRuntimePersistenceError.syncFailed(
                detail.isEmpty ? "git handoff exited \(result.exitCode)" : detail)
        }

        let outputParts = result.stdout.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard outputParts.count == 2 else {
            throw SiteRuntimePersistenceError.syncFailed("container returned an invalid git bundle")
        }
        let fullCommit = String(outputParts[0])
        guard (40...64).contains(fullCommit.count),
              fullCommit.unicodeScalars.allSatisfy({ hexDigits.contains($0) }),
              let bundleData = Data(base64Encoded: String(outputParts[1]), options: .ignoreUnknownCharacters)
        else {
            throw SiteRuntimePersistenceError.syncFailed("container returned an invalid git bundle")
        }

        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("anglesite-persist-\(UUID().uuidString).bundle")
        do {
            try bundleData.write(to: bundleURL, options: .atomic)
        } catch {
            throw SiteRuntimePersistenceError.syncFailed(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        do {
            try await importBundle(bundleURL, fullCommit, sourceDirectory)
            onLog("persisted \(fullCommit) to Source", .stdout)
        } catch {
            onLog("persist failed: \(error.localizedDescription)", .stderr)
            throw SiteRuntimePersistenceError.syncFailed(error.localizedDescription)
        }
    }
}
```

- [ ] **Step 4: Run to verify pass** — `swift test --filter ContainerEditExportTests` → PASS.

- [ ] **Step 5: Refactor `LocalContainerSiteRuntime.persistEdit` to call the shared type**

Replace the body from `// Export exactly the requested commit...` (`Sources/AnglesiteCore/LocalContainerSiteRuntime.swift:280`) through the end of the function (`:370`) — i.e. everything after the two `guard stateMachine.isCurrent(...)` blocks that bracket the export — with:

```swift
        let logCenter = self.logCenter
        let source = "container:\(siteID):persist"
        do {
            try await ContainerEditExport.exportAndImport(
                commit: commit,
                siteID: siteID,
                control: control,
                sourceDirectory: siteDirectory,
                onLog: { line, stream in Task { await logCenter.append(source: source, stream: stream, text: line) } },
                importBundle: importBundle
            )
        } catch {
            guard stateMachine.isCurrent(expectedGeneration), activeSiteID == siteID else {
                throw SiteRuntimePersistenceError.runtimeNotRunning
            }
            throw error
        }
    }
```

Keep the two pre-existing guards above this (commit-format validation and the `acquirePersistenceSlot`/generation checks before the export starts) exactly as they are — only the body *after* the second `guard stateMachine.isCurrent(...)` block (the actual script/exec/parse/import sequence) moves into `ContainerEditExport`. `importBundle` here is `self.importBundle`, the actor's own already-injectable closure (`LocalContainerSiteRuntime.swift:28`) — passed straight through so `LocalContainerSiteRuntimeTests`' existing fakes for it keep working unmodified.

- [ ] **Step 6: Run the full existing `LocalContainerSiteRuntime` suite to confirm no regression**

```bash
swift test --filter LocalContainerSiteRuntimeTests
```

Expected: PASS, unchanged from before this refactor (same commit/behavior, different internal structure).

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteCore/ContainerEditExport.swift \
  Sources/AnglesiteCore/LocalContainerSiteRuntime.swift \
  Tests/AnglesiteCoreTests/ContainerEditExportTests.swift
git commit -m "refactor(#1208): extract ContainerEditExport from persistEdit"
```

---

### Task 2: `RemoteContainerSession.isOwner(siteID:)`

**Files:**
- Modify: `Sources/AnglesiteRemote/RemoteContainerSession.swift`
- Test: `Tests/AnglesiteRemoteTests/RemoteContainerSessionTests.swift`

**Interfaces:**
- Produces: `public func isOwner(siteID: String) -> Bool` on `RemoteContainerSession` — true only for a `siteID` this session itself booted (i.e. is in `ownedSiteIDs`), false for a borrowed claim or an unknown site.

- [ ] **Step 1: Write failing tests** (append to the existing `RemoteContainerSessionTests` suite)

```swift
@Test func isOwnerTrueAfterBootingFresh() async throws {
    let control = FakeLocalContainerControl()
    let registry = try Self.makeRegistry()
    let session = RemoteContainerSession(control: control, registry: registry, pid: 111)
    _ = try await session.ensureRunning(
        siteID: "site-1", sourceRepo: URL(fileURLWithPath: "/tmp/site"), ref: "HEAD", onOutput: { _, _ in })
    #expect(await session.isOwner(siteID: "site-1"))
}

@Test func isOwnerFalseWhenBorrowingAnExistingClaim() async throws {
    let registry = try Self.makeRegistry()
    try await registry.publish(RemoteSessionClaim(
        siteID: "site-1", previewURL: URL(string: "http://127.0.0.1:9001")!,
        mcpURL: URL(string: "http://127.0.0.1:9002")!, ownerPID: 999))
    let control = FakeLocalContainerControl()
    let session = RemoteContainerSession(control: control, registry: registry, pid: 111)
    _ = try await session.ensureRunning(
        siteID: "site-1", sourceRepo: URL(fileURLWithPath: "/tmp/site"), ref: "HEAD", onOutput: { _, _ in })
    #expect(!(await session.isOwner(siteID: "site-1")))
}

@Test func isOwnerFalseForUnknownSite() async throws {
    let session = RemoteContainerSession(control: FakeLocalContainerControl(), registry: try Self.makeRegistry(), pid: 111)
    #expect(!(await session.isOwner(siteID: "never-booted")))
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter RemoteContainerSessionTests` → FAIL (`isOwner` doesn't exist yet).

- [ ] **Step 3: Implement.** Add to `RemoteContainerSession`, immediately after `tearDown`:

```swift
    /// True when this session itself booted `siteID`'s container (and therefore holds the
    /// only in-process VM handle `control.exec` can reach for it) — false for a borrowed claim
    /// (another process's container) or a `siteID` this session has never touched.
    public func isOwner(siteID: String) -> Bool {
        ownedSiteIDs.contains(siteID)
    }
```

- [ ] **Step 4: Run to verify pass** — PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteRemote/RemoteContainerSession.swift Tests/AnglesiteRemoteTests/RemoteContainerSessionTests.swift
git commit -m "feat(#1208): RemoteContainerSession.isOwner(siteID:)"
```

---

### Task 3: `FakeLocalContainerControl` — injectable `exec`

**Files:**
- Modify: `Tests/AnglesiteRemoteTests/FakeLocalContainerControl.swift`

**Interfaces:**
- Produces: an `execHandler` closure property Task 4's tests configure per-test; defaults to today's canned zero-exit-code result so every existing caller of this fake keeps compiling and passing unchanged.

- [ ] **Step 1: Add the seam.** Replace the fake's `exec` method with:

```swift
    /// Configurable per-test — defaults to today's canned success so every existing caller of
    /// this fake (which never configures it) keeps its current behavior unchanged.
    var execHandler: @Sendable (String, [String]) async throws -> ContainerExecResult = { _, _ in
        ContainerExecResult(exitCode: 0, stdout: "", stderr: "")
    }

    func exec(
        siteID: String,
        argv: [String],
        environment: [String: String],
        workingDirectory: String,
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> ContainerExecResult {
        try await execHandler(siteID, argv)
    }
```

(This is the only change in this file — `execHandler`'s default reproduces the fake's prior unconditional-success body exactly, so no existing test's behavior changes.)

- [ ] **Step 2: Build to confirm no regression** (no new test file for this task alone — Task 4 exercises the new seam):

```bash
swift build --target AnglesiteRemoteTests 2>&1 | tail -20
swift test --filter RemoteContainerSessionTests
```

Expected: builds and passes unchanged.

- [ ] **Step 3: Commit**

```bash
git add Tests/AnglesiteRemoteTests/FakeLocalContainerControl.swift
git commit -m "test(#1208): injectable exec on the AnglesiteRemote container fake"
```

---

### Task 4: `HelperEditPersister`

**Files:**
- Create: `Sources/AnglesiteRemote/HelperEditPersister.swift`
- Test: `Tests/AnglesiteRemoteTests/HelperEditPersisterTests.swift`

**Interfaces:**
- Consumes: `MCPChannelResponder.Handler` (`AnglesiteP2P`), `JSONValue`, `ContainerEditExport` (Task 1), `LocalContainerControl`, `LogCenter.Stream`.
- Produces:

```swift
public actor HelperEditPersister {
    public typealias Handler = @Sendable (JSONValue) async -> JSONValue?

    public init(
        wrapping inner: @escaping Handler,
        siteID: String,
        control: any LocalContainerControl,
        sourceDirectory: URL,
        onLog: @escaping @Sendable (String, LogCenter.Stream) -> Void,
        exportAndImport: @escaping @Sendable (String, String, any LocalContainerControl, URL, @escaping @Sendable (String, LogCenter.Stream) -> Void) async throws -> Void
            = ContainerEditExport.exportAndImport(commit:siteID:control:sourceDirectory:onLog:)
    )

    /// Conforms to `MCPChannelResponder.Handler`'s shape.
    public func handle(_ message: JSONValue) async -> JSONValue?
}
```

- [ ] **Step 1: Write failing tests**

```swift
import Testing
import Foundation
import AnglesiteCore
import AnglesiteP2P
@testable import AnglesiteRemote

@Suite struct HelperEditPersisterTests {
    /// A `tools/call` JSON-RPC response carrying `apply_edit`'s structured content body.
    static func applyEditReply(id: Int, commit: String?, isError: Bool = false) -> JSONValue {
        var body: [String: JSONValue] = ["file": .string("src/pages/index.astro")]
        if let commit { body["commit"] = .string(commit) }
        let bodyText = String(decoding: try! JSONSerialization.data(withJSONObject: body.mapValues { $0.rawJSONObject }), as: UTF8.self)
        return .object([
            "jsonrpc": .string("2.0"), "id": .int(id),
            "result": .object([
                "content": .array([.object(["type": .string("text"), "text": .string(bodyText)])]),
                "isError": .bool(isError),
            ]),
        ])
    }

    @Test func passesThroughAReplyWithNoCommitUnchanged() async {
        let reply = Self.applyEditReply(id: 1, commit: nil)
        var exportCalled = false
        let persister = HelperEditPersister(
            wrapping: { _ in reply }, siteID: "site-1", control: FakeLocalContainerControl(),
            sourceDirectory: URL(fileURLWithPath: "/tmp/source"), onLog: { _, _ in },
            exportAndImport: { _, _, _, _, _ in exportCalled = true })
        let result = await persister.handle(.object(["jsonrpc": .string("2.0"), "id": .int(1)]))
        #expect(result == reply)
        #expect(!exportCalled)
    }

    @Test func persistsAndPassesThroughUnchangedOnSuccess() async {
        let reply = Self.applyEditReply(id: 2, commit: "abcdef0")
        var capturedCommit: String?
        let persister = HelperEditPersister(
            wrapping: { _ in reply }, siteID: "site-1", control: FakeLocalContainerControl(),
            sourceDirectory: URL(fileURLWithPath: "/tmp/source"), onLog: { _, _ in },
            exportAndImport: { commit, siteID, _, source, _ in
                capturedCommit = commit
                #expect(siteID == "site-1")
                #expect(source == URL(fileURLWithPath: "/tmp/source"))
            })
        let result = await persister.handle(.object(["jsonrpc": .string("2.0"), "id": .int(2)]))
        #expect(result == reply)
        #expect(capturedCommit == "abcdef0")
    }

    @Test func synthesizesAnErrorReplyWhenPersistFails() async {
        let reply = Self.applyEditReply(id: 3, commit: "abcdef0")
        var loggedFailure = false
        let persister = HelperEditPersister(
            wrapping: { _ in reply }, siteID: "site-1", control: FakeLocalContainerControl(),
            sourceDirectory: URL(fileURLWithPath: "/tmp/source"),
            onLog: { line, stream in if stream == .stderr { loggedFailure = true } },
            exportAndImport: { _, _, _, _, _ in throw SiteRuntimePersistenceError.syncFailed("disk full") })
        let result = await persister.handle(.object(["jsonrpc": .string("2.0"), "id": .int(3)]))
        guard case .object(let obj)? = result, case .object(let errorObj)? = obj["error"] else {
            Issue.record("expected a JSON-RPC error object, got \(String(describing: result))")
            return
        }
        #expect(obj["id"] == .int(3))
        if case .string(let message)? = errorObj["message"] {
            #expect(message.contains("disk full"))
        } else {
            Issue.record("error object had no message")
        }
        #expect(loggedFailure)
    }

    @Test func ignoresErrorRepliesEvenIfTheyCarryACommitLikeString() async {
        // isError:true replies never trigger persistence — a tool-level failure has nothing valid
        // to export, regardless of what its content text happens to contain.
        let reply = Self.applyEditReply(id: 4, commit: "abcdef0", isError: true)
        var exportCalled = false
        let persister = HelperEditPersister(
            wrapping: { _ in reply }, siteID: "site-1", control: FakeLocalContainerControl(),
            sourceDirectory: URL(fileURLWithPath: "/tmp/source"), onLog: { _, _ in },
            exportAndImport: { _, _, _, _, _ in exportCalled = true })
        _ = await persister.handle(.object(["jsonrpc": .string("2.0"), "id": .int(4)]))
        #expect(!exportCalled)
    }

    @Test func notificationsPassThroughWithoutInspection() async {
        let persister = HelperEditPersister(
            wrapping: { _ in nil }, siteID: "site-1", control: FakeLocalContainerControl(),
            sourceDirectory: URL(fileURLWithPath: "/tmp/source"), onLog: { _, _ in },
            exportAndImport: { _, _, _, _, _ in Issue.record("must not be called") })
        let result = await persister.handle(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/x")]))
        #expect(result == nil)
    }
}
```

`JSONValue` needs a `rawJSONObject`-style bridge to `JSONSerialization` for building the test fixture's text body — check whether `AnglesiteCore` already exposes one (grep `JSONValue` for an existing `Foundation`-bridging helper used by other tests, e.g. `MCPApplyEditRouterTests` or `MCPClientTests`) before hand-rolling `rawJSONObject` here; if one exists, use it and delete the placeholder reference above. If none exists, build the text body with plain `JSONSerialization.data(withJSONObject:)` over a `[String: Any]` dictionary instead of going through `JSONValue` at all — simpler, and this is a test fixture, not production code.

- [ ] **Step 2: Run to verify failure** — `swift test --filter HelperEditPersisterTests` → FAIL.

- [ ] **Step 3: Implement `Sources/AnglesiteRemote/HelperEditPersister.swift`**

```swift
import Foundation
import AnglesiteCore
import AnglesiteP2P
import os.log

/// Wraps an `MCPChannelResponder.Handler` (in practice, `LoopbackMCPBridge.handle`) so that after
/// relaying a reply verbatim, any commit-bearing edit reply gets the same guest-to-host
/// persistence hop `LocalContainerSiteRuntime.persistEdit` already performs for the main app —
/// the app-side half of the Anywhere-runtime P1 exit criterion the shipped `LoopbackMCPBridge`
/// deliberately left unwired (design spec §Architecture 5; see `HelperContainerE2ETests`'s
/// doc comment for the shipped gap this closes).
///
/// Reply timing mirrors `MCPApplyEditRouter.apply`'s existing "await persist before acknowledging"
/// ordering, which exists specifically to avoid #718-style data loss (acknowledging an edit
/// before it is durable). On persist failure, the reply that reaches the caller is NOT the
/// original "applied" body — it is synthesized into a JSON-RPC error carrying the same request
/// id, so a phone/client cannot come away believing an edit landed on `Source/` when it didn't.
/// Every other reply (no commit, or a `.isError` tool-level failure) passes through completely
/// unmodified — this decorator only ever *replaces* a reply for the specific case it just caused
/// (a persist failure of its own), never edits the container's own success/failure verdict.
public actor HelperEditPersister {
    private static let logger = os.Logger(subsystem: "io.dwk.anglesite.remote", category: "HelperEditPersister")

    public typealias Handler = @Sendable (JSONValue) async -> JSONValue?

    private let inner: Handler
    private let siteID: String
    private let control: any LocalContainerControl
    private let sourceDirectory: URL
    private let onLog: @Sendable (String, LogCenter.Stream) -> Void
    private let exportAndImport: @Sendable (String, String, any LocalContainerControl, URL, @escaping @Sendable (String, LogCenter.Stream) -> Void) async throws -> Void

    /// - Parameters:
    ///   - inner: The handler to wrap — production always passes `LoopbackMCPBridge.handle`.
    ///   - siteID: The container's identity, passed straight to `exportAndImport`.
    ///   - control: The **same** `LocalContainerControl` instance that booted `siteID` — see
    ///     `ContainerEditExport.exportAndImport`'s doc comment for why this must not be a second,
    ///     freshly constructed instance.
    ///   - sourceDirectory: The host's canonical `Source/` git repository to import into.
    ///   - onLog: Routed to the helper's own log sink (stderr + `os.Logger`, matching
    ///     `RemoteContainerSession.report`/`LoopbackMCPBridge.report`'s existing pattern).
    ///   - exportAndImport: The guest-export + host-import hop. Defaults to
    ///     `ContainerEditExport.exportAndImport`; injectable for tests.
    public init(
        wrapping inner: @escaping Handler,
        siteID: String,
        control: any LocalContainerControl,
        sourceDirectory: URL,
        onLog: @escaping @Sendable (String, LogCenter.Stream) -> Void,
        exportAndImport: @escaping @Sendable (String, String, any LocalContainerControl, URL, @escaping @Sendable (String, LogCenter.Stream) -> Void) async throws -> Void
            = { commit, siteID, control, sourceDirectory, onLog in
                try await ContainerEditExport.exportAndImport(
                    commit: commit, siteID: siteID, control: control, sourceDirectory: sourceDirectory, onLog: onLog)
            }
    ) {
        self.inner = inner
        self.siteID = siteID
        self.control = control
        self.sourceDirectory = sourceDirectory
        self.onLog = onLog
        self.exportAndImport = exportAndImport
    }

    /// Conforms to `MCPChannelResponder.Handler`'s shape; pass `persister.handle` directly to
    /// `MCPChannelResponder.init(connection:handler:)` in place of the bare `bridge.handle` P1
    /// wired.
    public func handle(_ message: JSONValue) async -> JSONValue? {
        guard let reply = await inner(message) else { return nil }
        guard let commit = Self.extractCommit(from: reply), ContainerEditExport.isPlausibleCommit(commit) else {
            return reply
        }
        do {
            try await exportAndImport(commit, siteID, control, sourceDirectory, onLog)
            return reply
        } catch {
            let detail = String(describing: error)
            Self.report("persist failed for commit \(commit): \(detail)")
            return Self.errorResponse(replacing: reply, message: "the edit applied but could not be saved to Source: \(detail)")
        }
    }

    /// Extracts a `commit` from a raw JSON-RPC `tools/call` response object — mirrors
    /// `MCPApplyEditRouter.parseStructured`'s `content[0].text` JSON parse, but reads the full
    /// wire envelope (`{jsonrpc, id, result: {content, isError}}`) this bridge deals in, rather
    /// than an already-unwrapped `MCPClient.ToolCallResult`. Returns `nil` for a tool-level
    /// failure (`isError: true`) — nothing valid to export regardless of content text — or any
    /// shape that isn't a successful `tools/call` response carrying a `commit` string.
    static func extractCommit(from reply: JSONValue) -> String? {
        guard case .object(let root) = reply,
              case .object(let result)? = root["result"] else { return nil }
        if case .bool(true)? = result["isError"] { return nil }
        guard case .array(let content)? = result["content"] else { return nil }
        for item in content {
            guard case .object(let obj) = item,
                  case .string("text")? = obj["type"],
                  case .string(let text)? = obj["text"],
                  let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let commit = json["commit"] as? String, !commit.isEmpty
            else { continue }
            return commit
        }
        return nil
    }

    /// Builds a JSON-RPC error object carrying `reply`'s own request id — same shape
    /// `LoopbackMCPBridge.errorResponse` already uses for its own bridge-level failures.
    private static func errorResponse(replacing reply: JSONValue, message: String) -> JSONValue {
        let id: JSONValue = {
            if case .object(let obj) = reply, let id = obj["id"] { return id }
            return .null
        }()
        return .object([
            "jsonrpc": .string("2.0"), "id": id,
            "error": .object(["code": .int(-32000), "message": .string(message)]),
        ])
    }

    private static func report(_ message: String) {
        logger.error("HelperEditPersister: \(message, privacy: .public)")
        FileHandle.standardError.write(Data("HelperEditPersister: \(message)\n".utf8))
    }
}
```

- [ ] **Step 4: Run to verify pass** — `swift test --filter HelperEditPersisterTests` → PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteRemote/HelperEditPersister.swift Tests/AnglesiteRemoteTests/HelperEditPersisterTests.swift
git commit -m "feat(#1208): HelperEditPersister — persist commit-bearing helper edits"
```

---

### Task 5: Wire the persister into the helper session loop

**Files:**
- Modify: `Sources/anglesite-remote-helper/main.swift`

**Interfaces:**
- Consumes: `HelperEditPersister` (Task 4), `RemoteContainerSession.isOwner(siteID:)` (Task 2).

- [ ] **Step 1: Share one `ContainerizationControl()` instance and gate the persister on ownership.**

Replace:

```swift
let containerSession = RemoteContainerSession(
    control: ContainerizationControl(),
    registry: RemoteSessionRegistry(directory: registryDir))
```

with:

```swift
let control = ContainerizationControl()
let containerSession = RemoteContainerSession(
    control: control,
    registry: RemoteSessionRegistry(directory: registryDir))
```

And replace:

```swift
let httpBridge = FetchBridgeServer(connection: peer, executor: LoopbackHTTPExecutor(baseURL: session.previewURL))
let mcpBridge = LoopbackMCPBridge(mcpURL: session.mcpURL)
let mcpResponder = MCPChannelResponder(connection: peer, handler: mcpBridge.handle)
```

with:

```swift
let httpBridge = FetchBridgeServer(connection: peer, executor: LoopbackHTTPExecutor(baseURL: session.previewURL))
let mcpBridge = LoopbackMCPBridge(mcpURL: session.mcpURL)
// Persistence only runs for a container THIS process booted — a borrowed claim (another
// process's container) has no in-process VM handle `control.exec` can reach (see
// ContainerEditExport's doc comment). `await` is fine here: `isOwner` only reads actor state
// already settled by the `ensureRunning` call above, no I/O.
let mcpHandler: LoopbackMCPBridge.Handler
if await containerSession.isOwner(siteID: siteID) {
    let persister = HelperEditPersister(
        wrapping: mcpBridge.handle, siteID: siteID, control: control, sourceDirectory: siteRoot,
        onLog: { line, stream in FileHandle.standardError.write(Data(("[\(stream)] " + line + "\n").utf8)) })
    mcpHandler = persister.handle
} else {
    FileHandle.standardError.write(Data("remote-helper: bridging a borrowed container — edits will not be persisted by this process\n".utf8))
    mcpHandler = mcpBridge.handle
}
let mcpResponder = MCPChannelResponder(connection: peer, handler: mcpHandler)
```

`LoopbackMCPBridge.Handler` doesn't exist as a named typealias yet (the type currently just uses `MCPChannelResponder.Handler`'s bare closure shape inline) — use `MCPChannelResponder.Handler` for the `mcpHandler` local's type annotation instead:

```swift
let mcpHandler: MCPChannelResponder.Handler
```

- [ ] **Step 2: Build**

```bash
swift build --product anglesite-remote-helper
```

Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/anglesite-remote-helper/main.swift
git commit -m "feat(#1208): wire HelperEditPersister into the session loop"
```

---

### Task 6: Retire the durability-boundary pin; add a real persistence proof

**Files:**
- Modify: `Tests/AnglesiteRemoteTests/HelperContainerE2ETests.swift`

**Interfaces:**
- Consumes: everything above, plus `EditMessage`/`EditMessage.jsonValue` shape (`AnglesiteCore`, matching `AnglesiteContainerProbe.runApplyEdit`'s proven `apply_edit` payload, `Sources/AnglesiteContainerProbe/main.swift:589-597`).

- [ ] **Step 1: Delete `HelperEditDurabilityBoundaryTests`.** Its entire premise — "no file under `Sources/AnglesiteRemote` or `Sources/anglesite-remote-helper` references `InProcessEditPersistence`/`persistEdit`" — is now false by design (Task 5 makes `main.swift` reference `HelperEditPersister`, which itself calls `ContainerEditExport`, whose default `importBundle` calls `InProcessEditPersistence.importBundle`). The suite's own doc comment instructs exactly this: "When helper-side persistence lands this *should* fail; invert it then... and fold it into `secondProcessEditsSiteWithNoMainAppRunning()`." Remove the whole `@Suite struct HelperEditDurabilityBoundaryTests { ... }` block (and its leading doc comment) from the end of the file.

- [ ] **Step 2: Add a new gated test proving the real persistence hop**, in the same file, alongside `secondProcessEditsSiteWithNoMainAppRunning` (same `@Suite` — it needs the identical real-container-boot + real-P2P-handshake setup, so it is not folded into the *existing* test body per the doc comment's literal suggestion; `create_page`'s reply still can't carry a commit until the separate sidecar fix lands, so the existing test's assertions are untouched, and this is a sibling test using `apply_edit`, which already works, instead):

```swift
    /// The app-side half of Anywhere-runtime persistence, proven end-to-end: an `apply_edit`
    /// relayed through the helper's `mcp` channel (which — unlike `create_page`, see the sibling
    /// test above — already gets a real guest-side commit, per `AnglesiteContainerProbe`'s daily
    /// proof of the same tool) lands in the HOST's canonical `Source/` repository: the file
    /// changes on disk and `git log` shows a new commit whose parent is the pre-edit HEAD.
    ///
    /// Closes the gap `HelperEditDurabilityBoundaryTests` used to pin (removed by this same
    /// change — see this test file's own history for that pin's doc comment and rationale).
    @Test(.timeLimit(.minutes(15)))
    func secondProcessPersistsAnApplyEditToHostSource() async throws {
        let helperBinary = try Self.locateHelperBinary()
        try Self.entitleForVirtualization(helperBinary)

        let siteRoot = try Self.makeThrowawayAstroRepo()
        defer { try? FileManager.default.removeItem(at: siteRoot) }
        let pagePath = siteRoot.appendingPathComponent("src/pages/index.astro")
        let beforeHead = try Self.git(["rev-parse", "HEAD"], in: siteRoot)

        let signalDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helper-e2e-persist-sig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: signalDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: signalDirectory) }

        let helper = Process()
        helper.executableURL = helperBinary
        helper.arguments = ["session", signalDirectory.path, siteRoot.path]
        let helperOutput = ProcessOutputCapture()
        helperOutput.attach(to: helper)
        try helper.run()
        defer {
            if helper.isRunning { helper.terminate() }
            helper.waitUntilExit()
            helperOutput.stop()
        }
        let booted = await Self.waitForOutput(
            "remote-helper: container ready", from: helperOutput, timeout: .seconds(600))
        #expect(booted, "the helper never reported a booted container\n\(helperOutput.transcript)")
        try #require(booted)

        let clientPeer = try await WebRTCPeer.connect(
            role: .offerer, signaling: FileSignalingChannel(directory: signalDirectory, sender: "client"))
        var peerIsOpen = true
        defer { if peerIsOpen { Task { await clientPeer.close() } } }
        let mcp = WebRTCTransport(connection: clientPeer)
        try await mcp.open()
        var mcpInbound = mcp.inbound().makeAsyncIterator()

        // Same selector shape AnglesiteContainerProbe.runApplyEdit already proves works against a
        // real guest — this fixture's index.astro ships `<h1>Anglesite helper e2e</h1>`.
        let newHeading = "Anglesite helper e2e — persisted"
        try await mcp.send(Self.request(id: 1, method: "tools/call", params: .object([
            "name": .string("apply_edit"),
            "arguments": .object([
                "id": .string("persist-e2e-1"),
                "type": .string("anglesite:apply-edit"),
                "path": .string("/"),
                "op": .string("replace-text"),
                "selector": .object([
                    "tag": .string("H1"), "classes": .array([]), "nthChild": .int(1),
                    "textContent": .string("Anglesite helper e2e"),
                ]),
                "value": .string(newHeading),
            ]),
        ])))
        guard let reply = await mcpInbound.next() else {
            Issue.record("no MCP reply for apply_edit\n\(helperOutput.transcript)")
            return
        }
        let toolText = Self.toolResultText(reply)
        try #require(toolText != nil, "apply_edit reply had no text content: \(Self.describe(reply))")
        guard let applied = Self.decodeObject(toolText ?? "") else {
            Issue.record("apply_edit did not return JSON: \(toolText ?? "<nil>")")
            return
        }
        let commit = applied["commit"] as? String
        try #require(commit != nil, "apply_edit returned no commit — cannot prove persistence\n\(String(describing: applied))")

        await mcp.close()
        await clientPeer.close()
        peerIsOpen = false
        let exitedOnItsOwn = await Self.waitForExit(helper, timeout: .seconds(120))
        #expect(exitedOnItsOwn, "the helper did not exit after the peer closed\n\(helperOutput.transcript)")

        // The proof: the HOST file changed, and HEAD advanced with the guest's commit as its
        // sole parent — read straight off disk, nothing MCP-shaped involved in this assertion.
        let afterHead = try Self.git(["rev-parse", "HEAD"], in: siteRoot)
        #expect(afterHead != beforeHead, "host Source/ HEAD did not move\n\(helperOutput.transcript)")
        let afterContent = try String(contentsOf: pagePath, encoding: .utf8)
        #expect(afterContent.contains(newHeading),
                "host Source/'s index.astro does not carry the edit:\n\(afterContent)\n\(helperOutput.transcript)")
    }
```

`Self.git` is currently `private static func git(_ arguments: [String], in directory: URL) throws` with no return value (it only runs, per the existing fixture-setup usage). Extend it to capture and return stdout — check its current signature at the bottom of the file (`Tests/AnglesiteRemoteTests/HelperContainerE2ETests.swift`, near `makeThrowawayAstroRepo`) and add a `@discardableResult` stdout-returning overload (or modify the existing one to return `String`) rather than adding a parallel duplicate — every existing call site (`makeThrowawayAstroRepo`'s `git init`/`add`/`commit`) ignores a return value fine either way.

- [ ] **Step 3: Run the exit criterion + new proof**

```bash
ANGLESITE_CONTAINER_TESTS=1 ANGLESITE_CONTAINER_E2E=1 ANGLESITE_P2P_E2E=1 \
  swift test --filter HelperContainerE2ETests
```

Expected: PASS — both `secondProcessEditsSiteWithNoMainAppRunning` (unchanged assertions, still pinning `create_page`'s nil commit) and the new `secondProcessPersistsAnApplyEditToHostSource`.

- [ ] **Step 4: Full-suite check**

```bash
swift test --package-path .
```

All green; gated suites skip cleanly without their env vars. `HelperEditDurabilityBoundaryTests` no longer exists to run (deleted in Step 1).

- [ ] **Step 5: Commit**

```bash
git add Tests/AnglesiteRemoteTests/HelperContainerE2ETests.swift
git commit -m "test(#1208): prove helper edits persist to host Source/, retire the boundary pin"
```

---

### Task 7: PR

- [ ] **Step 1:** Re-read `CONTRIBUTING.md` ▸ "Commits and pull requests"; build the PR body from `.github/PULL_REQUEST_TEMPLATE.md`'s exact headings (**Summary**, **Paired PR check** — self-contained, no sidecar schema change — and **Test plan**, listing every command actually run including the gated E2E). Reference `Part of #1208`. Note in the Summary that `create_page`/`create_post` guest-commit remains blocked on a separate sidecar-repo fix (unchanged by this PR) and that borrowed (non-owned) helper sessions still don't persist (documented limitation, not a regression — no prior behavior existed for that path either).
- [ ] **Step 2:** Push and `gh pr create`; verify CI. No `project.yml` changes in this plan, so the `xcodeproj-sync` job should be unaffected; confirm anyway.

## Self-Review Notes

- **Spec coverage:** the PR #1405 gap — "a helper-mediated edit is live but not yet durable" — is closed for the owning-session case (Tasks 1, 4, 5); the borrowed-session case is explicitly out of scope and documented, not silently dropped (Global Constraints, Task 7 Step 1). The `create_page`/`create_post` sidecar bug is untouched, as it must be (separate repo, separate PR, per `CONTRIBUTING.md` ▸ "Paired PRs").
- **Known gap flagged inline, not hidden:** Task 6 keeps `secondProcessEditsSiteWithNoMainAppRunning`'s existing `guestCommit == nil` pin exactly as PR #1405 left it — this plan does not and cannot fix the sidecar-side bug that pin documents — and adds a sibling test using `apply_edit` (which already works) as the real persistence proof instead of waiting on that fix.
- **Type consistency check:** `ContainerEditExport.exportAndImport`'s parameter order/types (`commit, siteID, control, sourceDirectory, onLog, importBundle`) are used identically in Task 1's refactor of `persistEdit` and Task 4's `HelperEditPersister` default closure. `LocalContainerSession`/`RemoteSessionClaim` field names (`previewURL`, `mcpURL`, `siteID`, `ownerPID`) match the as-shipped P1 code (`Sources/AnglesiteRemote/RemoteContainerSession.swift`, `Sources/AnglesiteCore/LocalContainerControl.swift`), not guessed. `MCPChannelResponder.Handler`'s exact signature (`@Sendable (JSONValue) async -> JSONValue?`) is copied from `Sources/AnglesiteP2P/MCPChannelResponder.swift:15`, confirmed directly against this checkout, and `HelperEditPersister.Handler` is declared identically so `HelperEditPersister.handle` is a drop-in replacement for `LoopbackMCPBridge.handle` at every call site.
