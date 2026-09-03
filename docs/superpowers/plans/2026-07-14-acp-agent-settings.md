# ACP Agent Settings Tab + Active-Backend Selection Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user register connections to arbitrary ACP (Agent Client Protocol) agents in a
new Settings tab, and pick which one (or Apple Intelligence on-device) is the app's active chat
assistant backend.

**Architecture:** Bottom-up: a JSON-RPC `ACPClient`/`ACPTransport` pair (mirroring the existing
`MCPClient`/`MCPTransport` seam) speaks ACP over either an in-container stdio process (via a new
`LocalContainerControl.execInteractive` extension) or a remote HTTP endpoint; `ACPAssistant`
wraps `ACPClient` as a `ConversationalAssistant`; `AssistantBackendResolver` + a small
`ACPAgentStore`/`AppSettings.activeAssistantBackend` decide, per site-open, whether
`SiteAssistantSessionFactory` hands `ChatModel` the resolved `ACPAssistant` instead of the
existing `FoundationModelAssistant`-backed path; a new Settings tab manages the store and the
active-backend setting.

**Tech Stack:** Swift 6.4, SwiftUI, Swift Testing (new tests) / XCTest (existing suites this plan
touches), Apple Containerization framework (`LinuxProcessConfiguration.stdin`).

## Global Constraints

- Every new public type lives in `AnglesiteCore` unless it's a SwiftUI view (`AnglesiteApp`) or
  the Containerization-framework-specific implementation (`AnglesiteContainer`).
- No `Containerization`/`Virtualization` types may cross the `LocalContainerControl` seam —
  `InteractiveExecHandle` and `ContainerExecResult` are the only vocabulary that crosses it.
- Secrets never get logged; follow `SecretStore`'s existing contract (`read` → `nil` when absent,
  empty `write` deletes, `delete` of a missing entry is a no-op).
- New Settings UI follows `SettingsView.swift`'s existing per-tab `Form`/`Section` shape — no new
  navigation chrome.
- `swift test --package-path .` (SwiftPM suites) must stay green after every task; container e2e
  tests are gated behind `ANGLESITE_CONTAINER_TESTS=1` / `ANGLESITE_CONTAINER_E2E=1` and are not
  expected to run in the default loop.

---

### Task 1: `ACPAgentConnection` model

**Files:**
- Create: `Sources/AnglesiteCore/ACPAgentConnection.swift`
- Test: `Tests/AnglesiteCoreTests/ACPAgentConnectionTests.swift`

**Interfaces:**
- Produces: `public struct ACPAgentConnection: Codable, Identifiable, Sendable, Equatable` with
  `let id: UUID`, `var name: String`, `var transport: Transport`, and nested
  `enum Transport: Codable, Sendable, Equatable { case stdio(command: String, arguments: [String]); case remote(url: URL) }`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/ACPAgentConnectionTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct ACPAgentConnectionTests {
    @Test func stdioConnectionRoundTripsThroughJSON() throws {
        let original = ACPAgentConnection(
            id: UUID(),
            name: "Local Agent",
            transport: .stdio(command: "claude-code-acp", arguments: ["--flag"])
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ACPAgentConnection.self, from: data)
        #expect(decoded == original)
    }

    @Test func remoteConnectionRoundTripsThroughJSON() throws {
        let original = ACPAgentConnection(
            id: UUID(),
            name: "Hosted Agent",
            transport: .remote(url: URL(string: "https://agent.example.com/acp")!)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ACPAgentConnection.self, from: data)
        #expect(decoded == original)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter ACPAgentConnectionTests`
Expected: FAIL — `ACPAgentConnection` does not exist yet (compile error).

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/AnglesiteCore/ACPAgentConnection.swift
import Foundation

/// One user-registered connection to an ACP (Agent Client Protocol) agent — Zed's JSON-RPC
/// protocol for editor<->agent communication. Non-secret fields only; a `.remote` connection's
/// bearer token lives in `SecretStore` under `SecretAccounts.acpAgentToken(id:)`, keyed by `id`.
public struct ACPAgentConnection: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var transport: Transport

    public enum Transport: Codable, Sendable, Equatable {
        /// Launched inside the open site's container, alongside the dev server and MCP sidecar.
        case stdio(command: String, arguments: [String])
        /// Reached over the network; the bearer token (if any) is stored separately in Keychain.
        case remote(url: URL)
    }

    public init(id: UUID, name: String, transport: Transport) {
        self.id = id
        self.name = name
        self.transport = transport
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter ACPAgentConnectionTests`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/ACPAgentConnection.swift Tests/AnglesiteCoreTests/ACPAgentConnectionTests.swift
git commit -m "feat(acp): add ACPAgentConnection model"
```

---

### Task 2: `ACPAgentStore`

**Files:**
- Create: `Sources/AnglesiteCore/ACPAgentStore.swift`
- Test: `Tests/AnglesiteCoreTests/ACPAgentStoreTests.swift`

**Interfaces:**
- Consumes: `ACPAgentConnection` (Task 1).
- Produces: `public final class ACPAgentStore: @unchecked Sendable` with
  `init(persistenceURL: URL? = nil, fileManager: FileManager = .default)`,
  `func load() throws -> [ACPAgentConnection]`,
  `func add(_ connection: ACPAgentConnection) throws`,
  `func update(_ connection: ACPAgentConnection) throws`,
  `func remove(id: UUID) throws`. Synchronous by design (unlike the actor-based `SiteStore`) —
  called from a non-async context in Task 11's resolver.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/ACPAgentStoreTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

final class ACPAgentStoreTests {
    private let tempDir: URL
    private let persistenceURL: URL
    private let fileManager = FileManager.default

    init() throws {
        tempDir = fileManager.temporaryDirectory.appendingPathComponent("acp-agent-store-\(UUID().uuidString)", isDirectory: true)
        persistenceURL = tempDir.appendingPathComponent("acp-agents.json")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    deinit {
        try? fileManager.removeItem(at: tempDir)
    }

    @Test("load returns empty array when no file exists") func loadReturnsEmptyWhenNoFile() throws {
        let store = ACPAgentStore(persistenceURL: persistenceURL)
        #expect(try store.load() == [])
    }

    @Test("add then load round trips") func addThenLoadRoundTrips() throws {
        let store = ACPAgentStore(persistenceURL: persistenceURL)
        let connection = ACPAgentConnection(id: UUID(), name: "Local Agent", transport: .stdio(command: "acp-agent", arguments: []))
        try store.add(connection)
        #expect(try store.load() == [connection])
    }

    @Test("update replaces the matching entry by id") func updateReplacesMatchingEntry() throws {
        let store = ACPAgentStore(persistenceURL: persistenceURL)
        let original = ACPAgentConnection(id: UUID(), name: "Original", transport: .stdio(command: "a", arguments: []))
        try store.add(original)
        var renamed = original
        renamed.name = "Renamed"
        try store.update(renamed)
        #expect(try store.load() == [renamed])
    }

    @Test("remove deletes the matching entry by id") func removeDeletesMatchingEntry() throws {
        let store = ACPAgentStore(persistenceURL: persistenceURL)
        let a = ACPAgentConnection(id: UUID(), name: "A", transport: .stdio(command: "a", arguments: []))
        let b = ACPAgentConnection(id: UUID(), name: "B", transport: .stdio(command: "b", arguments: []))
        try store.add(a)
        try store.add(b)
        try store.remove(id: a.id)
        #expect(try store.load() == [b])
    }

    @Test("a fresh store instance re-reads persisted entries") func freshInstanceReadsPersistedEntries() throws {
        let writer = ACPAgentStore(persistenceURL: persistenceURL)
        let connection = ACPAgentConnection(id: UUID(), name: "Local Agent", transport: .remote(url: URL(string: "https://example.com")!))
        try writer.add(connection)

        let reader = ACPAgentStore(persistenceURL: persistenceURL)
        #expect(try reader.load() == [connection])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter ACPAgentStoreTests`
Expected: FAIL — `ACPAgentStore` does not exist yet (compile error).

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/AnglesiteCore/ACPAgentStore.swift
import Foundation

/// Registry of user-configured ACP agent connections, persisted as JSON — mirrors `SiteStore`'s
/// `recents.json` pattern but stays synchronous (a plain class, not an actor): callers include
/// `AssistantBackendResolver`, which runs from a non-async closure (`SiteAssistantSessionFactory`'s
/// `AssistantBuilder`), and the store is tiny and touched rarely (Settings edits only).
public final class ACPAgentStore: @unchecked Sendable {
    private let fileManager: FileManager
    private let persistenceURL: URL

    /// - Parameters:
    ///   - persistenceURL: where to read/write `acp-agents.json`. Defaults to
    ///     `~/Library/Application Support/Anglesite/acp-agents.json`. Tests should pass a temp URL.
    public init(persistenceURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.persistenceURL = persistenceURL ?? Self.defaultPersistenceURL(fileManager: fileManager)
    }

    /// Reads the full list fresh from disk. Returns `[]` if no file exists yet.
    public func load() throws -> [ACPAgentConnection] {
        guard fileManager.fileExists(atPath: persistenceURL.path) else { return [] }
        let data = try Data(contentsOf: persistenceURL)
        return try Self.decoder.decode([ACPAgentConnection].self, from: data)
    }

    /// Appends `connection`. Callers are responsible for using a fresh `UUID` — this does not
    /// check for an existing entry with the same `id` (use `update` for that).
    public func add(_ connection: ACPAgentConnection) throws {
        var all = try load()
        all.append(connection)
        try persist(all)
    }

    /// Replaces the entry whose `id` matches `connection.id`. No-op if no entry matches.
    public func update(_ connection: ACPAgentConnection) throws {
        var all = try load()
        guard let index = all.firstIndex(where: { $0.id == connection.id }) else { return }
        all[index] = connection
        try persist(all)
    }

    /// Removes the entry with `id`. No-op if no entry matches.
    public func remove(id: UUID) throws {
        var all = try load()
        all.removeAll { $0.id == id }
        try persist(all)
    }

    private func persist(_ connections: [ACPAgentConnection]) throws {
        let dir = persistenceURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(connections)
        try data.write(to: persistenceURL, options: [.atomic])
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static var decoder: JSONDecoder { JSONDecoder() }

    private static func defaultPersistenceURL(fileManager: FileManager) -> URL {
        let support = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("Anglesite", isDirectory: true)
            .appendingPathComponent("acp-agents.json")
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter ACPAgentStoreTests`
Expected: PASS (5 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/ACPAgentStore.swift Tests/AnglesiteCoreTests/ACPAgentStoreTests.swift
git commit -m "feat(acp): add ACPAgentStore for persisting agent connections"
```

---

### Task 3: `SecretStore` ACP agent token extension

**Files:**
- Modify: `Sources/AnglesiteCore/Platform/SecretStore.swift`
- Modify: `Tests/AnglesiteCoreTests/KeychainStoreTests.swift`

**Interfaces:**
- Consumes: `ACPAgentConnection.id: UUID` (Task 1) for the account-key function's parameter.
- Produces: `SecretAccounts.acpAgentToken(id: UUID) -> String`,
  `SecretStore.readACPAgentToken(id: UUID) throws -> String?`,
  `SecretStore.writeACPAgentToken(_ token: String, id: UUID) throws`,
  `SecretStore.clearACPAgentToken(id: UUID) throws`.

- [ ] **Step 1: Write the failing test**

Add to the bottom of `KeychainStoreTests` (inside the existing `#if canImport(Security)` block,
before the closing `}` of the class):

```swift
    // MARK: ACP agent token convenience

    func testACPAgentTokenConvenienceRoundTrips() throws {
        let agentID = UUID()
        defer { try? store.clearACPAgentToken(id: agentID) }
        XCTAssertNil(try store.readACPAgentToken(id: agentID))
        try store.writeACPAgentToken("acp-token-xyz", id: agentID)
        XCTAssertEqual(try store.readACPAgentToken(id: agentID), "acp-token-xyz")
        try store.clearACPAgentToken(id: agentID)
        XCTAssertNil(try store.readACPAgentToken(id: agentID))
    }

    func testACPAgentTokensAreIndependentPerAgentID() throws {
        let a = UUID()
        let b = UUID()
        defer {
            try? store.clearACPAgentToken(id: a)
            try? store.clearACPAgentToken(id: b)
        }
        try store.writeACPAgentToken("token-a", id: a)
        try store.writeACPAgentToken("token-b", id: b)
        XCTAssertEqual(try store.readACPAgentToken(id: a), "token-a")
        XCTAssertEqual(try store.readACPAgentToken(id: b), "token-b")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter KeychainStoreTests`
Expected: FAIL — `readACPAgentToken`/`writeACPAgentToken`/`clearACPAgentToken` don't exist yet
(compile error).

- [ ] **Step 3: Write minimal implementation**

Add to `Sources/AnglesiteCore/Platform/SecretStore.swift`, inside `enum SecretAccounts`:

```swift
    /// Bearer token for a `.remote` ACP agent connection, keyed by the connection's `id` — there
    /// can be many connections, so this is a function, not a single constant like
    /// `cloudflareToken`/`gitHubToken`.
    public static func acpAgentToken(id: UUID) -> String {
        "acp-agent-token-\(id.uuidString)"
    }
```

Add to `extension SecretStore` (same file):

```swift
    /// Read the bearer token for a `.remote` ACP agent connection.
    func readACPAgentToken(id: UUID) throws -> String? {
        try read(account: SecretAccounts.acpAgentToken(id: id))
    }

    /// Store the bearer token for a `.remote` ACP agent connection. Empty string clears.
    func writeACPAgentToken(_ token: String, id: UUID) throws {
        try write(token, account: SecretAccounts.acpAgentToken(id: id))
    }

    /// Clear the bearer token for a `.remote` ACP agent connection.
    func clearACPAgentToken(id: UUID) throws {
        try delete(account: SecretAccounts.acpAgentToken(id: id))
    }
```

(`import Foundation` at the top of the file already provides `UUID`.)

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter KeychainStoreTests`
Expected: PASS (all `KeychainStoreTests` cases, including the 2 new ones)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/Platform/SecretStore.swift Tests/AnglesiteCoreTests/KeychainStoreTests.swift
git commit -m "feat(acp): add per-agent ACP token accessors to SecretStore"
```

---

### Task 4: `AppSettings.activeAssistantBackend`

**Files:**
- Modify: `Sources/AnglesiteCore/AppSettings.swift`
- Modify: `Tests/AnglesiteCoreTests/AppSettingsTests.swift`

**Interfaces:**
- Produces: `AppSettings.Key.activeAssistantBackend`, `AppSettings.activeAssistantBackend: String`
  (get/set property, default `"foundationModels"`).

- [ ] **Step 1: Write the failing test**

Add to `Tests/AnglesiteCoreTests/AppSettingsTests.swift`:

```swift
    @Test("Active assistant backend defaults to foundationModels") func activeAssistantBackendDefaultsToFoundationModels() {
        let settings = AppSettings(defaults: defaults)
        #expect(settings.activeAssistantBackend == "foundationModels")
    }

    @Test("Active assistant backend round trip") func activeAssistantBackendRoundTrip() {
        let settings = AppSettings(defaults: defaults)
        settings.activeAssistantBackend = "acp:\(UUID().uuidString)"
        #expect(settings.activeAssistantBackend.hasPrefix("acp:"))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter AppSettingsTests`
Expected: FAIL — `activeAssistantBackend` does not exist yet (compile error).

- [ ] **Step 3: Write minimal implementation**

In `Sources/AnglesiteCore/AppSettings.swift`, add to `enum Key`:

```swift
        public static let activeAssistantBackend = "anglesite.activeAssistantBackend"
```

Add a new property (near `debugPaneEnabled`):

```swift
    /// Which backend answers chat/content-help requests: `"foundationModels"` (default) or
    /// `"acp:<ACPAgentConnection.id>"`. Global, not per-site (#602 design decision). An unresolvable
    /// value (agent removed, malformed) is handled by `AssistantBackendResolver`, which falls back
    /// to Foundation Models rather than this property validating its own contents.
    public var activeAssistantBackend: String {
        get { defaults.string(forKey: Key.activeAssistantBackend) ?? "foundationModels" }
        set { defaults.set(newValue, forKey: Key.activeAssistantBackend) }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter AppSettingsTests`
Expected: PASS (all `AppSettingsTests` cases, including the 2 new ones)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/AppSettings.swift Tests/AnglesiteCoreTests/AppSettingsTests.swift
git commit -m "feat(acp): add AppSettings.activeAssistantBackend"
```

---

### Task 5: `LocalContainerControl.execInteractive` protocol addition

**Files:**
- Modify: `Sources/AnglesiteCore/LocalContainerControl.swift`
- Modify: `Tests/AnglesiteCoreTests/FakeLocalContainerControl.swift`
- Modify: `Tests/AnglesiteCoreTests/ContainerDeployExecutorTests.swift`
- Modify: `Tests/AnglesiteCoreTests/DeployExecutorSelectionTests.swift`

**Interfaces:**
- Produces: `public final class InteractiveExecHandle: Sendable` with
  `func write(_ data: Data) async throws` and `func terminate() async`;
  `LocalContainerControl.execInteractive(siteID:argv:environment:workingDirectory:onOutput:) async throws -> InteractiveExecHandle`.
  No `Containerization`/`Virtualization` types cross this seam (same rule as `exec`).
- Consumes: nothing new — extends the existing `LocalContainerControl` protocol
  (`Sources/AnglesiteCore/LocalContainerControl.swift:53`).

`LocalContainerControl` is a `public protocol`, so adding a required method breaks every existing
conformer until it's updated. There are **eight** in this codebase, not just the three in
`FakeLocalContainerControl.swift` — a full-repo search (`grep -rln ": LocalContainerControl"`)
turns up three more test fakes (`ThrowingFakeLocalContainerControl`/`CancelParkingFakeContainerControl`
in `ContainerDeployExecutorTests.swift`, `StepAwareFakeContainerControl` in
`DeployExecutorSelectionTests.swift` — six test fakes total) plus the two real production
conformers: `ContainerizationControl` (macOS, Task 6) and
`Sources/AnglesiteCore/Platform/PodmanContainerControl.swift` (Linux, gated
`#if canImport(Glibc)` so it never compiles on this macOS worktree — Task 6b). This task only adds
the protocol requirement and updates the six *test* fakes; the two production implementations are
Tasks 6 and 6b.

- [ ] **Step 1: Write the failing test**

```swift
// Add to Tests/AnglesiteCoreTests/FakeLocalContainerControl.swift, as a new test file instead:
// Tests/AnglesiteCoreTests/InteractiveExecHandleTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct InteractiveExecHandleTests {
    @Test func writeAndTerminateInvokeInjectedHandlers() async throws {
        actor Recorder {
            private(set) var written: [Data] = []
            private(set) var terminated = false
            func recordWrite(_ data: Data) { written.append(data) }
            func recordTerminate() { terminated = true }
        }
        let recorder = Recorder()
        let handle = InteractiveExecHandle(
            write: { data in await recorder.recordWrite(data) },
            terminate: { await recorder.recordTerminate() }
        )
        try await handle.write(Data("hello".utf8))
        await handle.terminate()
        let written = await recorder.written
        let terminated = await recorder.terminated
        #expect(written == [Data("hello".utf8)])
        #expect(terminated)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter InteractiveExecHandleTests`
Expected: FAIL — `InteractiveExecHandle` does not exist yet (compile error). Note: the whole
package will also fail to build once Step 3 adds the protocol requirement without updating the
fakes — that's expected and resolved within this same task before Step 4.

- [ ] **Step 3: Write minimal implementation**

Add to `Sources/AnglesiteCore/LocalContainerControl.swift`, above the `LocalContainerControl`
protocol:

```swift
/// A live handle to an interactively-exec'd guest process — unlike `exec`'s wait-to-completion
/// result, this returns as soon as the process starts, so the caller can both feed it `stdin`
/// (e.g. outbound JSON-RPC messages) and keep receiving `onOutput` lines for as long as it runs.
/// Closure-backed (like `ContainerExecResult` is a plain struct) so no `Containerization`/
/// `Virtualization` type crosses this seam, and so `FakeLocalContainerControl` can hand back a
/// fully in-memory handle with no real process behind it.
public final class InteractiveExecHandle: Sendable {
    private let writeHandler: @Sendable (Data) async throws -> Void
    private let terminateHandler: @Sendable () async -> Void

    public init(
        write: @escaping @Sendable (Data) async throws -> Void,
        terminate: @escaping @Sendable () async -> Void
    ) {
        self.writeHandler = write
        self.terminateHandler = terminate
    }

    /// Feeds `data` to the process's stdin.
    public func write(_ data: Data) async throws { try await writeHandler(data) }

    /// Terminates the process. Safe to call more than once; a terminated process's later
    /// `onOutput` calls (if any were in flight) still fire per `exec`'s existing `@escaping`
    /// contract.
    public func terminate() async { await terminateHandler() }
}
```

Add to the `LocalContainerControl` protocol, after `exec(...)`:

```swift
    /// Like `exec`, but returns as soon as the guest process starts rather than waiting for it to
    /// exit, and the returned handle can feed the process's stdin — for a long-lived, bidirectional
    /// child (an ACP agent speaking JSON-RPC over stdio) rather than a one-shot command.
    func execInteractive(
        siteID: String,
        argv: [String],
        environment: [String: String],
        workingDirectory: String,
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> InteractiveExecHandle
```

Add a conformance to each of the three fakes in `Tests/AnglesiteCoreTests/FakeLocalContainerControl.swift`
(`FakeLocalContainerControl`, `StopGatedFakeLocalContainerControl`, `GatedFakeLocalContainerControl`).
Add the new `execInteractiveStdoutLines` parameter to `FakeLocalContainerControl`'s existing
`init(...)`, right after `execStdoutLines: [String] = []`:

```swift
        execStdoutLines: [String] = [],
        execInteractiveStdoutLines: [String] = []
```

and inside the initializer body, alongside `self.execStdoutLines = execStdoutLines`:

```swift
        self.execInteractiveStdoutLines = execInteractiveStdoutLines
```

For `FakeLocalContainerControl`, also record calls for future test use, mirroring `execCalls`:

```swift
    /// Lines replayed to `execInteractive`'s `onOutput` (as `.stdout`) in order before it returns
    /// the handle — separate from `execStdoutLines`, which only feeds the older `exec`. Pass at
    /// construction (mirrors `startStdoutLines`/`execStdoutLines`) so a transport test can
    /// simulate the agent's first stdout lines arriving.
    var execInteractiveStdoutLines: [String]
    /// All `execInteractive` invocations recorded for assertion.
    private(set) var execInteractiveCalls: [(siteID: String, argv: [String], env: [String: String], cwd: String)] = []
    /// Data written to the most recently returned handle, recorded for assertion.
    private(set) var execInteractiveWrites: [Data] = []
    /// Whether the most recently returned handle's `terminate()` was called.
    private(set) var execInteractiveTerminated = false

    func execInteractive(
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
```

For the two gated fakes (`StopGatedFakeLocalContainerControl`, `GatedFakeLocalContainerControl`),
add the minimal pass-through conformance (they don't need to record anything — they exist to test
`start`/`stop` race timing, not exec):

```swift
    func execInteractive(
        siteID: String,
        argv: [String],
        environment: [String: String],
        workingDirectory: String,
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> InteractiveExecHandle {
        InteractiveExecHandle(write: { _ in }, terminate: {})
    }
```

Add the same minimal conformance to the two fakes in
`Tests/AnglesiteCoreTests/ContainerDeployExecutorTests.swift` — `ThrowingFakeLocalContainerControl`
mirrors its existing `exec`'s throw-only behavior:

```swift
    func execInteractive(
        siteID: String,
        argv: [String],
        environment: [String: String],
        workingDirectory: String,
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> InteractiveExecHandle {
        throw ExecError.boom
    }
```

and `CancelParkingFakeContainerControl` (not exercised for `execInteractive` by any existing test —
a trivial no-op handle is sufficient to satisfy the protocol):

```swift
    func execInteractive(
        siteID: String,
        argv: [String],
        environment: [String: String],
        workingDirectory: String,
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> InteractiveExecHandle {
        InteractiveExecHandle(write: { _ in }, terminate: {})
    }
```

And to `StepAwareFakeContainerControl` in `Tests/AnglesiteCoreTests/DeployExecutorSelectionTests.swift`
(also not exercised for `execInteractive` — same trivial no-op handle):

```swift
    func execInteractive(
        siteID: String,
        argv: [String],
        environment: [String: String],
        workingDirectory: String,
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> InteractiveExecHandle {
        InteractiveExecHandle(write: { _ in }, terminate: {})
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter InteractiveExecHandleTests`
Expected: PASS (1 test)

Run: `swift build --package-path .` then `swift test --package-path .`
Expected: both succeed — confirms all five test fakes still conform to `LocalContainerControl`
and every existing test that depends on them (`ContainerDeployExecutorTests`,
`DeployExecutorSelectionTests`, etc.) still passes unmodified.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/LocalContainerControl.swift Tests/AnglesiteCoreTests/FakeLocalContainerControl.swift Tests/AnglesiteCoreTests/ContainerDeployExecutorTests.swift Tests/AnglesiteCoreTests/DeployExecutorSelectionTests.swift Tests/AnglesiteCoreTests/InteractiveExecHandleTests.swift
git commit -m "feat(acp): add LocalContainerControl.execInteractive + InteractiveExecHandle"
```

---

### Task 6: `ContainerizationControl.execInteractive` real implementation

**Files:**
- Modify: `Sources/AnglesiteContainer/ContainerizationControl.swift`
- Modify: `Tests/AnglesiteContainerLocalTests/ContainerizationControlTests.swift`

**Interfaces:**
- Consumes: `InteractiveExecHandle` (Task 5), Apple's `LinuxProcessConfiguration.stdin: ReaderStream?`
  and `Writer`/`ReaderStream` protocols (`.build/checkouts/containerization/Sources/Containerization/IO/{Writer,ReaderStream}.swift`).
- Produces: `ContainerizationControl.execInteractive(siteID:argv:environment:workingDirectory:onOutput:) async throws -> InteractiveExecHandle`,
  matching the new protocol requirement from Task 5.

`AnglesiteContainerLocalTests` is a real target in `Package.swift`, but it is only appended to the
package graph when `ANGLESITE_CONTAINER_TESTS=1` is set at `swift build`/`swift test` invocation
time (see `Package.swift` around the `includeContainer &&` block) — a bare `swift test` never even
sees this target, by design (it pulls in the Apple Containerization framework, which only links on
an entitled Apple-Silicon Mac). Every test body *inside* that target additionally guards on
`ANGLESITE_CONTAINER_E2E=1` via `try #require(enabled, ...)`, the existing
`ContainerizationControlTests`'s pattern. This task adds a new `@Test` method to that same
existing `struct` (not a new file/suite) so it can reuse its private `makeThrowawayAstroRepo()`
helper directly.

- [ ] **Step 1: Write the failing test**

Add this `@Test` method to the existing `ContainerizationControlTests` struct in
`Tests/AnglesiteContainerLocalTests/ContainerizationControlTests.swift`, right after
`bootsAndServes()`:

```swift
    @Test("execInteractive echoes what's written to its stdin back out through onOutput")
    func execInteractiveEchoesStdin() async throws {
        try #require(enabled, "set ANGLESITE_CONTAINER_E2E=1 on an entitled Apple-Silicon Mac")

        let control = ContainerizationControl()
        let repo = try makeThrowawayAstroRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await control.start(siteID: "e2e-interactive", sourceRepo: repo, ref: "HEAD") { _, _ in }
        defer { Task { try? await control.stop(siteID: "e2e-interactive") } }

        var receivedLines: [String] = []
        let handle = try await control.execInteractive(
            siteID: "e2e-interactive",
            argv: ["cat"],
            environment: [:],
            workingDirectory: "/workspace/site",
            onOutput: { line, _ in receivedLines.append(line) }
        )
        try await handle.write(Data("hello from the host\n".utf8))
        // `cat` echoes what it reads from stdin; give the guest a moment before asserting.
        try await Task.sleep(for: .milliseconds(500))
        #expect(receivedLines.contains("hello from the host"))
        await handle.terminate()

        try? await control.stop(siteID: "e2e-interactive")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ANGLESITE_CONTAINER_TESTS=1 ANGLESITE_CONTAINER_E2E=1 swift test --package-path . --filter ContainerizationControlTests`
Expected: FAIL — `execInteractive` does not exist on `ContainerizationControl` yet (compile error).

- [ ] **Step 3: Write minimal implementation**

Add to `Sources/AnglesiteContainer/ContainerizationControl.swift`, right after `exec(...)`:

```swift
    /// A `ReaderStream` fed by explicit `write(_:)` calls rather than a fixed source — the bridge
    /// between `InteractiveExecHandle.write(_:)` and the guest process's stdin. `@unchecked Sendable`
    /// because `AsyncStream.Continuation` is already safe to call concurrently; there is no other
    /// mutable state here.
    private final class PipeReaderStream: ReaderStream, @unchecked Sendable {
        private let backing: AsyncStream<Data>
        private let continuation: AsyncStream<Data>.Continuation

        init() {
            (backing, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        }

        func stream() -> AsyncStream<Data> { backing }
        func write(_ data: Data) { continuation.yield(data) }
        func finish() { continuation.finish() }
    }

    /// Like `exec`, but starts the guest process and returns immediately with a live handle instead
    /// of awaiting completion, and wires `LinuxProcessConfiguration.stdin` so the caller can keep
    /// feeding the process input (an ACP agent's JSON-RPC stdin) for as long as it runs. A detached
    /// task drains `proc.wait()` in the background so the process is still reaped (flushing the
    /// output sinks and calling `proc.delete()`) even though nothing here awaits it synchronously —
    /// mirrors `runDetached`'s reaping story (container `stop()` also SIGKILLs and deletes every
    /// vended process, so a caller that never calls `terminate()` still gets cleaned up on teardown).
    public func execInteractive(
        siteID: String,
        argv: [String],
        environment: [String: String],
        workingDirectory: String,
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> InteractiveExecHandle {
        guard let container = await live.container(for: siteID) else {
            throw LocalContainerError.bootFailed("execInteractive: no live container for siteID '\(siteID)'")
        }

        let stdinStream = PipeReaderStream()
        let stdoutSink = LineStreamingWriter(stream: .stdout, onLine: onOutput)
        let stderrSink = LineStreamingWriter(stream: .stderr, onLine: onOutput)

        let label = Self.execLabel(for: argv)
        let proc = try await container.exec("\(siteID)-interactive-\(label)-\(UUID().uuidString.prefix(8))") { config in
            config.arguments = argv
            config.environmentVariables =
                ["PATH=\(LinuxProcessConfiguration.defaultPath)"]
                + environment.map { "\($0.key)=\($0.value)" }
            config.workingDirectory = workingDirectory
            config.stdin = stdinStream
            config.stdout = stdoutSink
            config.stderr = stderrSink
        }
        try await proc.start()

        Task {
            _ = try? await proc.wait()
            stdoutSink.flush()
            stderrSink.flush()
            try? await proc.delete()
        }

        return InteractiveExecHandle(
            write: { data in stdinStream.write(data) },
            terminate: {
                try? await proc.kill(.term)
                try? await proc.delete()
            }
        )
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ANGLESITE_CONTAINER_TESTS=1 ANGLESITE_CONTAINER_E2E=1 swift test --package-path . --filter ContainerizationControlTests`
Expected: PASS (needs a Mac that can boot the local container runtime — Apple Silicon,
virtualization entitlement present; see `scripts/run-container-probe.sh` if this doesn't boot).

Run: `swift build --package-path .`
Expected: builds clean without either env var set (confirms the default, non-container build is
unaffected — `AnglesiteContainerLocalTests` isn't even part of the graph in that invocation).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteContainer/ContainerizationControl.swift Tests/AnglesiteContainerLocalTests/ContainerizationControlTests.swift
git commit -m "feat(acp): implement ContainerizationControl.execInteractive"
```

---

### Task 6b: `PodmanContainerControl.execInteractive` (Linux conformer)

**Files:**
- Modify: `Sources/AnglesiteCore/Platform/PodmanContainerControl.swift`

**Interfaces:**
- Consumes: `InteractiveExecHandle` (Task 5), `ProcessSupervisor.launch(attachStdin:logCenter:)` +
  `.writeStdin(_:_:)` (`Sources/AnglesiteCore/ProcessSupervisor.swift:143`, `:218`), `LogCenter.subscribe()`.
- Produces: `PodmanContainerControl.execInteractive(...)`, completing the protocol conformance
  added in Task 5.

This whole file compiles only on Linux (`#if canImport(Glibc)`, `PodmanContainerControl.swift:5`)
— it is not part of this macOS worktree's build at all, so **this task cannot be built or tested
in this environment**; treat it as a careful, honest best-effort port of the same pattern
`StdioTransport` already uses on the host side (`ProcessSupervisor.launch(attachStdin: true)` +
`writeStdin` + a `logCenter.subscribe()` forwarding loop), not a placeholder. Whoever lands the
Linux CI leg (cross-platform port epic #571 P1) should give this a real run on Linux before
trusting it.

No TDD cycle here (nothing to run) — implement directly, matching the file's existing style.

- [ ] **Step 1: Add a `logCenter` property**

The file has no stored `LogCenter` today (`execOneShot`'s one-shot `supervisor.run(...)` doesn't
log through it). Add one, following the same injectable-with-default pattern as `astroCommand`:

```swift
    private let logCenter: LogCenter
```

Add to `init(...)`'s parameter list (after `mcpCommand`):

```swift
        mcpCommand: String = PodmanContainerControl.defaultMCPCommand,
        logCenter: LogCenter = .shared
```

and inside the initializer body:

```swift
        self.logCenter = logCenter
```

- [ ] **Step 2: Implement `execInteractive`**

Add right after the existing `exec(...)` method:

```swift
    /// Like `exec`, but launches `podman exec -i` as a long-running supervised process
    /// (`ProcessSupervisor.launch(attachStdin: true)`) instead of a one-shot `run`, so the caller
    /// can keep writing to its stdin — mirrors `StdioTransport`'s exact approach on the host side.
    /// Output flows through `logCenter` (matching every other `launch`-based process here) and is
    /// forwarded to `onOutput` by a subscription filtered to this call's `source`, tagged with the
    /// original `LogCenter.Stream` it arrived on.
    public func execInteractive(
        siteID: String,
        argv: [String],
        environment: [String: String],
        workingDirectory: String,
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> InteractiveExecHandle {
        guard let name = await live.containerName(for: siteID) else {
            throw LocalContainerError.bootFailed("execInteractive: no running container for site \(siteID)")
        }
        var arguments = ["exec", "-i", "-w", workingDirectory]
        for (key, value) in environment.sorted(by: { $0.key < $1.key }) {
            arguments += ["-e", "\(key)=\(value)"]
        }
        arguments.append(name)
        arguments += argv

        let source = "acp-interactive:\(siteID)"
        let subscription = await logCenter.subscribe()
        let forwardTask = Task { [source] in
            for await line in subscription.stream {
                guard line.source == source else { continue }
                onOutput(line.text, line.stream)
            }
        }

        let handle = try await supervisor.launch(
            source: source,
            executable: podmanExecutable,
            arguments: arguments,
            attachStdin: true,
            logCenter: logCenter
        )

        return InteractiveExecHandle(
            write: { [supervisor] data in try await supervisor.writeStdin(handle, data) },
            terminate: { [supervisor] in
                // `.cancel()` finishes the subscription's own continuation — the guaranteed way
                // to end the `for await` forwarding loop (matches `StdioTransport.close()`);
                // `forwardTask.cancel()` alone would NOT reliably stop a `for await` over an
                // `AsyncStream` that's still open.
                subscription.cancel()
                forwardTask.cancel()
                await supervisor.terminate(handle, timeout: 2)
                _ = await supervisor.waitForExit(handle)
            }
        )
    }
```

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteCore/Platform/PodmanContainerControl.swift
git commit -m "feat(acp): implement PodmanContainerControl.execInteractive (Linux, untested here)"
```

---

### Task 7: `ACPTransport` protocol + `ACPContainerExecTransport`

**Files:**
- Create: `Sources/AnglesiteCore/ACPTransport.swift`
- Create: `Sources/AnglesiteCore/ACPContainerExecTransport.swift`
- Test: `Tests/AnglesiteCoreTests/ACPContainerExecTransportTests.swift`

**Interfaces:**
- Consumes: `LocalContainerControl.execInteractive` (Task 5), `JSONValue` (`Sources/AnglesiteCore/MCPTransport.swift`'s
  sibling file `MCPClient.swift`, already public in `AnglesiteCore`), `InteractiveExecHandle` (Task 5).
- Produces: `public protocol ACPTransport: Sendable { func open() async throws; func send(_ message: JSONValue) async throws; func inbound() -> AsyncStream<JSONValue>; func close() async }`;
  `public actor ACPContainerExecTransport: ACPTransport` with
  `init(control: any LocalContainerControl, siteID: String, command: String, arguments: [String], workingDirectory: String = "/workspace/site")`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/ACPContainerExecTransportTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct ACPContainerExecTransportTests {
    @Test func openInvokesExecInteractiveWithGivenCommand() async throws {
        let control = FakeLocalContainerControl(startResult: .success(LocalContainerSession(
            previewURL: URL(string: "http://127.0.0.1:1")!, mcpURL: URL(string: "http://127.0.0.1:2")!)))
        let transport = ACPContainerExecTransport(
            control: control, siteID: "site-1", command: "acp-agent", arguments: ["--flag"])
        try await transport.open()
        let calls = await control.execInteractiveCalls
        #expect(calls.count == 1)
        #expect(calls.first?.siteID == "site-1")
        #expect(calls.first?.argv == ["acp-agent", "--flag"])
        #expect(calls.first?.cwd == "/workspace/site")
    }

    @Test func sendWritesNewlineFramedJSONToTheHandle() async throws {
        let control = FakeLocalContainerControl(startResult: .success(LocalContainerSession(
            previewURL: URL(string: "http://127.0.0.1:1")!, mcpURL: URL(string: "http://127.0.0.1:2")!)))
        let transport = ACPContainerExecTransport(
            control: control, siteID: "site-1", command: "acp-agent", arguments: [])
        try await transport.open()
        try await transport.send(.object(["jsonrpc": .string("2.0"), "id": .int(1), "method": .string("initialize")]))
        let writes = await control.execInteractiveWrites
        #expect(writes.count == 1)
        let line = String(decoding: writes[0], as: UTF8.self)
        #expect(line.hasSuffix("\n"))
        #expect(line.contains("\"method\":\"initialize\""))
    }

    @Test func inboundParsesNewlineDelimitedJSONFromOnOutput() async throws {
        let message = #"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#
        let control = FakeLocalContainerControl(
            startResult: .success(LocalContainerSession(
                previewURL: URL(string: "http://127.0.0.1:1")!, mcpURL: URL(string: "http://127.0.0.1:2")!)),
            execInteractiveStdoutLines: [message]
        )
        let transport = ACPContainerExecTransport(
            control: control, siteID: "site-1", command: "acp-agent", arguments: [])
        try await transport.open()
        var received: [JSONValue] = []
        for await value in transport.inbound() {
            received.append(value)
            break
        }
        #expect(received.count == 1)
        guard case .object(let obj) = received[0], case .int(1)? = obj["id"] else {
            Issue.record("expected the parsed initialize response")
            return
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter ACPContainerExecTransportTests`
Expected: FAIL — `ACPTransport`/`ACPContainerExecTransport` don't exist yet (compile error).

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/AnglesiteCore/ACPTransport.swift
import Foundation

/// A duplex channel for ACP (Agent Client Protocol) JSON-RPC messages. Mirrors `MCPTransport`'s
/// shape exactly — `ACPClient` owns id-correlation, the handshake, and session/notification
/// routing, and delegates raw message send/receive to a transport, so an in-container stdio agent
/// and a remote HTTP agent share the same client code path.
public protocol ACPTransport: Sendable {
    func open() async throws
    func send(_ message: JSONValue) async throws
    func inbound() -> AsyncStream<JSONValue>
    func close() async
}
```

```swift
// Sources/AnglesiteCore/ACPContainerExecTransport.swift
import Foundation

/// `ACPTransport` over a local ACP agent process running inside the site's own container —
/// launched via `LocalContainerControl.execInteractive`, alongside the dev server and MCP sidecar
/// (not a host `ProcessSupervisor` subprocess; see the ACP agent settings design spec §3 for why
/// neither existing `MCPTransport` conformer fits this). Each `send` writes one newline-framed
/// JSON-RPC message to the guest process's stdin; `inbound()` parses each stdout line as a
/// `JSONValue`. Every line on BOTH streams also flows to `LogCenter` ("logs are sacred" — every
/// spawned subprocess streams stdout+stderr into the debug pane, matching `StdioTransport`'s
/// existing MCP protocol-traffic-is-visible precedent), tagged `source: "acp:<siteID>"`.
public actor ACPContainerExecTransport: ACPTransport {
    private let control: any LocalContainerControl
    private let siteID: String
    private let command: String
    private let arguments: [String]
    private let workingDirectory: String
    private let logCenter: LogCenter

    private var handle: InteractiveExecHandle?
    private let stream: AsyncStream<JSONValue>
    private let continuation: AsyncStream<JSONValue>.Continuation

    public init(
        control: any LocalContainerControl,
        siteID: String,
        command: String,
        arguments: [String],
        workingDirectory: String = "/workspace/site",
        logCenter: LogCenter = .shared
    ) {
        self.control = control
        self.siteID = siteID
        self.command = command
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.logCenter = logCenter
        (self.stream, self.continuation) = AsyncStream<JSONValue>.makeStream(bufferingPolicy: .unbounded)
    }

    public func open() async throws {
        let logSource = "acp:\(siteID)"
        handle = try await control.execInteractive(
            siteID: siteID,
            argv: [command] + arguments,
            environment: [:],
            workingDirectory: workingDirectory,
            onOutput: { [continuation, logCenter] line, stream in
                Task { await logCenter.append(source: logSource, stream: stream, text: line) }
                guard stream == .stdout else { return }
                guard let data = line.data(using: .utf8),
                      let raw = try? JSONSerialization.jsonObject(with: data),
                      let value = JSONValue.from(raw) else { return }
                continuation.yield(value)
            }
        )
    }

    public func send(_ message: JSONValue) async throws {
        guard let handle else { throw ACPTransportError.notOpen }
        let data = try JSONSerialization.data(withJSONObject: message.rawValue)
        try await handle.write(data + Data("\n".utf8))
    }

    public func inbound() -> AsyncStream<JSONValue> { stream }

    public func close() async {
        await handle?.terminate()
        continuation.finish()
    }
}

public enum ACPTransportError: Error, Sendable, Equatable {
    case notOpen
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter ACPContainerExecTransportTests`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/ACPTransport.swift Sources/AnglesiteCore/ACPContainerExecTransport.swift Tests/AnglesiteCoreTests/ACPContainerExecTransportTests.swift
git commit -m "feat(acp): add ACPTransport protocol + in-container stdio transport"
```

---

### Task 8: `ACPHTTPTransport`

**Files:**
- Create: `Sources/AnglesiteCore/ACPHTTPTransport.swift`
- Test: `Tests/AnglesiteCoreTests/ACPHTTPTransportTests.swift`

**Interfaces:**
- Consumes: `ACPTransport` (Task 7), `SessionToken` (`Sources/AnglesiteCore/SessionToken.swift`), `JSONValue`.
  Models its stub on `StubURLProtocol` (`Tests/AnglesiteCoreTests/HTTPTransportTests.swift:7`, MCP's
  `HTTPTransport` tests) but declares its own type rather than reusing that one's static queue —
  `HTTPTransportTests` and this suite are independent `@Suite`s that Swift Testing can run
  concurrently with each other (`.serialized` only serializes *within* one suite, per the existing
  `MCPClientTests`/`MCPClientHTTPEndToEndTests` rationale comment), so sharing one mutable static
  queue across both would be a real race.
- Produces: `public actor ACPHTTPTransport: ACPTransport` with
  `init(endpoint: URL, bearerToken: SessionToken? = nil, urlSession: URLSession = .shared)`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/ACPHTTPTransportTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

/// A dedicated `URLProtocol` stub for these tests — modeled on `StubURLProtocol`
/// (`HTTPTransportTests.swift`) but a separate type/instance so this suite's per-test queue
/// mutations can never race with that suite's, even though both can run concurrently.
final class ACPStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response { let status: Int; let headers: [String: String]; let body: Data }
    nonisolated(unsafe) static var queue: [Response] = []
    nonisolated(unsafe) static var lastAuthHeaders: [String?] = []

    static func reset() { queue = []; lastAuthHeaders = [] }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastAuthHeaders.append(request.value(forHTTPHeaderField: "Authorization"))
        let r = Self.queue.isEmpty ? Response(status: 500, headers: [:], body: Data()) : Self.queue.removeFirst()
        let http = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        if !r.body.isEmpty { client?.urlProtocol(self, didLoad: r.body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct ACPHTTPTransportTests {
    private func makeTransport(bearerToken: SessionToken? = nil) -> ACPHTTPTransport {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ACPStubURLProtocol.self]
        let session = URLSession(configuration: config)
        return ACPHTTPTransport(endpoint: URL(string: "https://agent.example.com/acp")!, bearerToken: bearerToken, urlSession: session)
    }

    @Test("send posts JSON-RPC and decodes the response") func sendPostsJSONRPCAndDecodesTheResponse() async throws {
        ACPStubURLProtocol.reset()
        ACPStubURLProtocol.queue.append(.init(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: #"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#.data(using: .utf8)!
        ))
        let transport = makeTransport(bearerToken: SessionToken(value: "test-token"))
        try await transport.open()
        var iterator = transport.inbound().makeAsyncIterator()
        try await transport.send(.object(["jsonrpc": .string("2.0"), "id": .int(1), "method": .string("initialize")]))
        let received = await iterator.next()
        #expect(received == .object(["jsonrpc": .string("2.0"), "id": .int(1), "result": .object(["ok": .bool(true)])]))
        #expect(ACPStubURLProtocol.lastAuthHeaders == ["Bearer test-token"])
        await transport.close()
    }

    @Test("non-2xx status throws") func nonTwoHundredStatusThrows() async throws {
        ACPStubURLProtocol.reset()
        ACPStubURLProtocol.queue.append(.init(status: 500, headers: [:], body: Data()))
        let transport = makeTransport()
        try await transport.open()
        await #expect(throws: (any Error).self) {
            try await transport.send(.object(["jsonrpc": .string("2.0"), "id": .int(1), "method": .string("initialize")]))
        }
        await transport.close()
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter ACPHTTPTransportTests`
Expected: FAIL — `ACPHTTPTransport` does not exist yet (compile error).

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/AnglesiteCore/ACPHTTPTransport.swift
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `ACPTransport` over plain HTTP: each `send` POSTs one JSON-RPC message to the configured
/// endpoint and decodes its `application/json` response directly into `inbound()`. Unlike MCP's
/// `HTTPTransport`, this slice does not implement an SSE read path — a remote ACP agent's
/// `session/update` push notifications are a fast-follow (see the ACP agent settings design spec
/// §4.3); every response this transport sees is a direct reply to the request that produced it.
public actor ACPHTTPTransport: ACPTransport {
    public enum HTTPError: Error, Sendable, Equatable {
        case http(status: Int)
        case badResponse
    }

    private let endpoint: URL
    private let bearerToken: SessionToken?
    private let urlSession: URLSession
    private let stream: AsyncStream<JSONValue>
    private let continuation: AsyncStream<JSONValue>.Continuation

    public init(endpoint: URL, bearerToken: SessionToken? = nil, urlSession: URLSession = .shared) {
        self.endpoint = endpoint
        self.bearerToken = bearerToken
        self.urlSession = urlSession
        (self.stream, self.continuation) = AsyncStream<JSONValue>.makeStream(bufferingPolicy: .unbounded)
    }

    public func open() async throws { /* no persistent connection; first send does the work */ }

    public func send(_ message: JSONValue) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearerToken {
            request.setValue("Bearer \(bearerToken.value)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: message.rawValue)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HTTPError.badResponse }
        guard (200...299).contains(http.statusCode) else { throw HTTPError.http(status: http.statusCode) }
        // A notification (no "id") may legitimately get an empty body back — nothing to decode.
        guard !data.isEmpty else { return }
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let value = JSONValue.from(raw) else { throw HTTPError.badResponse }
        continuation.yield(value)
    }

    public func inbound() -> AsyncStream<JSONValue> { stream }

    public func close() async { continuation.finish() }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter ACPHTTPTransportTests`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/ACPHTTPTransport.swift Tests/AnglesiteCoreTests/ACPHTTPTransportTests.swift
git commit -m "feat(acp): add ACPHTTPTransport for remote agent connections"
```

---

### Task 9: `ACPClient`

**Files:**
- Create: `Sources/AnglesiteCore/ACPClient.swift`
- Test: `Tests/AnglesiteCoreTests/ACPClientTests.swift`

**Interfaces:**
- Consumes: `ACPTransport` (Tasks 7-8), `JSONValue`, `AssistantEvent` (`Sources/AnglesiteCore/ConversationalAssistant.swift`).
- Produces: `public actor ACPClient` with `init(transport: any ACPTransport)`,
  `func initialize() async throws`,
  `func newSession(cwd: String) async throws -> String`,
  `func sendPrompt(sessionID: String, text: String) async throws -> AsyncStream<AssistantEvent>`,
  `func cancelSession(sessionID: String) async`, `func stop() async`.

ACP's JSON-RPC method/field names below (`session/new`, `session/prompt`, `session/update`,
`session/request_permission`) are pinned to the Agent Client Protocol schema this client targets;
they are centralized as string literals in this one file, so a future schema correction is a
localized edit, not a redesign.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/ACPClientTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct ACPClientTests {
    /// In-process fake `ACPTransport`, mirroring `MCPClientTests`'s `FakeMCPServerTransport`:
    /// responses/notifications are yielded synchronously from `send(_:)`, no subprocess, no
    /// wall-clock dependency.
    private actor FakeACPAgentTransport: ACPTransport {
        private var continuation: AsyncStream<JSONValue>.Continuation?
        private let stream: AsyncStream<JSONValue>
        /// Extra `session/update` notifications to emit right after the `session/prompt` response
        /// this test wants to exercise (set per test before calling `sendPrompt`).
        private var updatesToEmitBeforePromptResult: [JSONValue] = []
        private(set) var sentMethods: [String] = []

        init() {
            var cont: AsyncStream<JSONValue>.Continuation!
            stream = AsyncStream { cont = $0 }
            continuation = cont
        }

        func setUpdatesToEmit(_ updates: [JSONValue]) {
            updatesToEmitBeforePromptResult = updates
        }

        func open() async throws {}
        nonisolated func inbound() -> AsyncStream<JSONValue> { stream }
        func close() async { continuation?.finish() }

        func send(_ message: JSONValue) async throws {
            guard case .object(let obj) = message, case .string(let method)? = obj["method"] else { return }
            sentMethods.append(method)
            guard case .int(let id)? = obj["id"] else { return }  // notifications get no response
            switch method {
            case "initialize":
                continuation?.yield(.object(["jsonrpc": .string("2.0"), "id": .int(id), "result": .object([:])]))
            case "session/new":
                continuation?.yield(.object(["jsonrpc": .string("2.0"), "id": .int(id), "result": .object(["sessionId": .string("sess-1")])]))
            case "session/prompt":
                for update in updatesToEmitBeforePromptResult { continuation?.yield(update) }
                continuation?.yield(.object(["jsonrpc": .string("2.0"), "id": .int(id), "result": .object(["stopReason": .string("end_turn")])]))
            default:
                break
            }
        }
    }

    @Test func initializeSucceedsAgainstAConformingAgent() async throws {
        let client = ACPClient(transport: FakeACPAgentTransport())
        try await client.initialize()
    }

    @Test func newSessionReturnsTheAgentAssignedSessionID() async throws {
        let client = ACPClient(transport: FakeACPAgentTransport())
        try await client.initialize()
        let sessionID = try await client.newSession(cwd: "/workspace/site")
        #expect(sessionID == "sess-1")
    }

    @Test func sendPromptStreamsTextDeltasThenTurnComplete() async throws {
        let transport = FakeACPAgentTransport()
        await transport.setUpdatesToEmit([
            .object(["jsonrpc": .string("2.0"), "method": .string("session/update"), "params": .object([
                "sessionId": .string("sess-1"),
                "update": .object(["sessionUpdate": .string("agent_message_chunk"), "content": .object(["type": .string("text"), "text": .string("Hello")])]),
            ])]),
        ])
        let client = ACPClient(transport: transport)
        try await client.initialize()
        let sessionID = try await client.newSession(cwd: "/workspace/site")
        let events = try await client.sendPrompt(sessionID: sessionID, text: "hi")
        var collected: [AssistantEvent] = []
        for await event in events { collected.append(event) }
        #expect(collected.contains(.textDelta("Hello")))
        #expect(collected.contains(.turnComplete(nil)))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter ACPClientTests`
Expected: FAIL — `ACPClient` does not exist yet (compile error).

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/AnglesiteCore/ACPClient.swift
import Foundation

/// JSON-RPC 2.0 client speaking the Agent Client Protocol (ACP) over a pluggable `ACPTransport`.
///
/// Differs from `MCPClient` in one important way: MCP discards every server notification, but ACP
/// notifications (`session/update`) and server-initiated requests (`session/request_permission`)
/// carry the actual conversation content and must be acted on. This client owns id-correlation for
/// request/response pairs (like `MCPClient`) plus routing `session/update` to the matching
/// in-flight `sendPrompt` call, and auto-declines any `session/request_permission` — this slice
/// has no tool-permission UI (see the ACP agent settings design spec §4.4/§5), so an agent that
/// attempts a tool call during the proof-of-concept turn is told "no" rather than left hanging.
public actor ACPClient {
    public enum ACPError: Error, Sendable, Equatable {
        case invalidResponse(String)
        case rpcError(code: Int, message: String)
    }

    private let transport: any ACPTransport
    private var readerTask: Task<Void, Never>?
    private var nextRequestID: Int = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    /// One live `session/update` listener per session — this slice only ever drives one turn at a
    /// time per `ACPAssistant`, so a single continuation per session id is sufficient.
    private var sessionUpdateContinuations: [String: AsyncStream<AssistantEvent>.Continuation] = [:]

    public init(transport: any ACPTransport) {
        self.transport = transport
    }

    public func initialize() async throws {
        try await transport.open()
        readerTask = Task { [weak self] in
            guard let self else { return }
            await self.consumeInbound(transport.inbound())
        }
        let params: JSONValue = .object([
            "protocolVersion": .int(1),
            "clientCapabilities": .object(["fs": .object(["readTextFile": .bool(false), "writeTextFile": .bool(false)])]),
        ])
        _ = try await sendRequest(method: "initialize", params: params)
    }

    public func newSession(cwd: String) async throws -> String {
        let result = try await sendRequest(method: "session/new", params: .object(["cwd": .string(cwd), "mcpServers": .array([])]))
        guard case .object(let obj) = result, case .string(let sessionID)? = obj["sessionId"] else {
            throw ACPError.invalidResponse("session/new missing 'sessionId'")
        }
        return sessionID
    }

    /// Streams one turn as `AssistantEvent`s: `.started` immediately, `.textDelta`/`.toolUse`/
    /// `.toolResult` as `session/update` notifications arrive for `sessionID`, then `.turnComplete`
    /// (or `.failed`) once the `session/prompt` response itself resolves.
    public func sendPrompt(sessionID: String, text: String) async throws -> AsyncStream<AssistantEvent> {
        let (stream, continuation) = AsyncStream<AssistantEvent>.makeStream(bufferingPolicy: .unbounded)
        sessionUpdateContinuations[sessionID] = continuation
        continuation.yield(.started(model: nil, toolNames: []))

        let params: JSONValue = .object([
            "sessionId": .string(sessionID),
            "prompt": .array([.object(["type": .string("text"), "text": .string(text)])]),
        ])
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.sendRequest(method: "session/prompt", params: params)
                continuation.yield(.turnComplete(nil))
            } catch {
                continuation.yield(.failed(message: String(describing: error)))
            }
            await self.finishSessionUpdates(sessionID: sessionID)
            continuation.finish()
        }
        return stream
    }

    public func cancelSession(sessionID: String) async {
        try? await sendNotification(method: "session/cancel", params: .object(["sessionId": .string(sessionID)]))
    }

    public func stop() async {
        readerTask?.cancel()
        readerTask = nil
        await transport.close()
        for (_, cont) in pending { cont.resume(throwing: CancellationError()) }
        pending.removeAll()
        for cont in sessionUpdateContinuations.values { cont.finish() }
        sessionUpdateContinuations.removeAll()
    }

    // MARK: Internals

    private func finishSessionUpdates(sessionID: String) {
        sessionUpdateContinuations.removeValue(forKey: sessionID)
    }

    private func sendRequest(method: String, params: JSONValue?) async throws -> JSONValue {
        let id = nextRequestID
        nextRequestID += 1
        var obj: [String: JSONValue] = ["jsonrpc": .string("2.0"), "id": .int(id), "method": .string(method)]
        if let params { obj["params"] = params }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSONValue, Error>) in
            pending[id] = cont
            Task { [weak self] in
                do {
                    try await self?.transport.send(.object(obj))
                } catch {
                    await self?.failPending(id: id, error: error)
                }
            }
        }
    }

    private func sendNotification(method: String, params: JSONValue?) async throws {
        var obj: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method)]
        if let params { obj["params"] = params }
        try await transport.send(.object(obj))
    }

    private func failPending(id: Int, error: Error) {
        if let cont = pending.removeValue(forKey: id) { cont.resume(throwing: error) }
    }

    private func resolvePending(id: Int, value: JSONValue) {
        if let cont = pending.removeValue(forKey: id) { cont.resume(returning: value) }
    }

    private func consumeInbound(_ stream: AsyncStream<JSONValue>) async {
        for await message in stream {
            guard case .object(let obj) = message else { continue }

            if case .string(let method)? = obj["method"] {
                if case .int(let id)? = obj["id"] {
                    // Server-initiated request. Only `session/request_permission` is expected this
                    // slice; auto-decline since there is no tool-permission UI yet.
                    if method == "session/request_permission" {
                        try? await transport.send(.object([
                            "jsonrpc": .string("2.0"), "id": .int(id),
                            "result": .object(["outcome": .object(["outcome": .string("cancelled")])]),
                        ]))
                    }
                    continue
                }
                if method == "session/update" { routeSessionUpdate(obj["params"]) }
                continue
            }

            guard case .int(let id)? = obj["id"] else { continue }  // response
            if case .object(let errObj)? = obj["error"] {
                let code: Int = { if case .int(let c)? = errObj["code"] { return c }; return -1 }()
                let msg: String = { if case .string(let m)? = errObj["message"] { return m }; return "unknown rpc error" }()
                failPending(id: id, error: ACPError.rpcError(code: code, message: msg))
            } else {
                resolvePending(id: id, value: obj["result"] ?? .null)
            }
        }
    }

    private func routeSessionUpdate(_ params: JSONValue?) {
        guard case .object(let params)? = params,
              case .string(let sessionID)? = params["sessionId"],
              case .object(let update)? = params["update"],
              case .string(let kind)? = update["sessionUpdate"],
              let continuation = sessionUpdateContinuations[sessionID]
        else { return }

        switch kind {
        case "agent_message_chunk":
            if case .object(let content)? = update["content"], case .string(let text)? = content["text"] {
                continuation.yield(.textDelta(text))
            }
        case "agent_thought_chunk":
            if case .object(let content)? = update["content"], case .string(let text)? = content["text"] {
                continuation.yield(.thinking(text))
            }
        case "tool_call":
            let id: String = { if case .string(let s)? = update["toolCallId"] { return s }; return UUID().uuidString }()
            let name: String = { if case .string(let s)? = update["title"] { return s }; return "tool" }()
            continuation.yield(.toolUse(id: id, name: name, input: .null))
        case "tool_call_update":
            guard case .string(let id)? = update["toolCallId"] else { return }
            let status: String = { if case .string(let s)? = update["status"] { return s }; return "" }()
            continuation.yield(.toolResult(id: id, content: status, isError: status == "failed"))
        default:
            break  // unrecognized update kind — safely ignored
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter ACPClientTests`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/ACPClient.swift Tests/AnglesiteCoreTests/ACPClientTests.swift
git commit -m "feat(acp): add ACPClient JSON-RPC handshake + session/prompt handling"
```

---

### Task 10: `ACPAssistant`

**Files:**
- Create: `Sources/AnglesiteCore/ACPAssistant.swift`
- Test: `Tests/AnglesiteCoreTests/ACPAssistantTests.swift`

**Interfaces:**
- Consumes: `ACPClient` (Task 9), `ACPAgentConnection` (Task 1), `ConversationalAssistant`/`ContentAssistant`/`AssistantContext`/`AssistantCapabilities`/`AssistantEvent`/`AssistantError`
  (`Sources/AnglesiteCore/ConversationalAssistant.swift`, `ContentAssistant.swift`), `LocalContainerControl` (for the stdio transport factory path).
- Produces: `public actor ACPAssistant: ConversationalAssistant` with
  `public typealias ContainerControlProvider = @Sendable () async -> (siteID: String, control: any LocalContainerControl)?`
  and
  `init(connection: ACPAgentConnection, siteID: String, sourceDirectory: URL, containerControlProvider: @escaping ContainerControlProvider = { nil }, secretStore: any SecretStore = PlatformSecretStore.make(), transportFactory: (@Sendable () async throws -> any ACPTransport)? = nil)`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/ACPAssistantTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct ACPAssistantTests {
    private actor FakeACPAgentTransport: ACPTransport {
        private var continuation: AsyncStream<JSONValue>.Continuation?
        private let stream: AsyncStream<JSONValue>

        init() {
            var cont: AsyncStream<JSONValue>.Continuation!
            stream = AsyncStream { cont = $0 }
            continuation = cont
        }

        func open() async throws {}
        nonisolated func inbound() -> AsyncStream<JSONValue> { stream }
        func close() async { continuation?.finish() }

        func send(_ message: JSONValue) async throws {
            guard case .object(let obj) = message, case .string(let method)? = obj["method"],
                  case .int(let id)? = obj["id"] else { return }
            switch method {
            case "initialize":
                continuation?.yield(.object(["jsonrpc": .string("2.0"), "id": .int(id), "result": .object([:])]))
            case "session/new":
                continuation?.yield(.object(["jsonrpc": .string("2.0"), "id": .int(id), "result": .object(["sessionId": .string("sess-1")])]))
            case "session/prompt":
                continuation?.yield(.object(["jsonrpc": .string("2.0"), "method": .string("session/update"), "params": .object([
                    "sessionId": .string("sess-1"),
                    "update": .object(["sessionUpdate": .string("agent_message_chunk"), "content": .object(["type": .string("text"), "text": .string("Hi there")])]),
                ])]))
                continuation?.yield(.object(["jsonrpc": .string("2.0"), "id": .int(id), "result": .object(["stopReason": .string("end_turn")])]))
            default:
                break
            }
        }
    }

    private func makeAssistant() -> ACPAssistant {
        let connection = ACPAgentConnection(id: UUID(), name: "Test Agent", transport: .remote(url: URL(string: "https://example.com")!))
        return ACPAssistant(
            connection: connection,
            siteID: "site-1",
            sourceDirectory: URL(fileURLWithPath: "/tmp/site-1"),
            transportFactory: { FakeACPAgentTransport() }
        )
    }

    @Test func generateYieldsTheAgentsTextReply() async throws {
        let assistant = makeAssistant()
        let context = AssistantContext(siteID: "site-1", siteDirectory: URL(fileURLWithPath: "/tmp/site-1"))
        let stream = try await assistant.generate(prompt: "hello", context: context)
        var collected = ""
        for try await chunk in stream { collected += chunk }
        #expect(collected == "Hi there")
    }

    @Test func capabilitiesReportsTheConnectionName() {
        let connection = ACPAgentConnection(id: UUID(), name: "My Agent", transport: .remote(url: URL(string: "https://example.com")!))
        let assistant = ACPAssistant(
            connection: connection, siteID: "site-1", sourceDirectory: URL(fileURLWithPath: "/tmp/site-1"),
            transportFactory: { FakeACPAgentTransport() })
        #expect(assistant.capabilities.providerName == "My Agent")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter ACPAssistantTests`
Expected: FAIL — `ACPAssistant` does not exist yet (compile error).

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/AnglesiteCore/ACPAssistant.swift
import Foundation

// Same toolchain/runtime gate as `ContentAssistant.swift` — `Generable` (used only by the
// `generateStructured` conformance below) comes from FoundationModels, which is absent from
// GitHub's macos-15 CI runner at *load* time even when the SDK has the symbol at compile time.
#if compiler(>=6.4) && canImport(FoundationModels)
import FoundationModels
#endif

/// `ConversationalAssistant` backed by an ACP agent connection (`ACPAgentConnection`). Constructed
/// synchronously (matching `FoundationModelAssistant`'s init) — the actual transport/handshake
/// happens lazily on first `converse`/`generate`, so building this assistant never blocks on a
/// container being up or a network round trip.
///
/// Proof-of-concept scope (ACP agent settings design spec §4.4): implements enough (`session/new`
/// + single-turn prompt/response) to make "switch which model answers chat" real. No multi-turn
/// tool-permission UI yet — `ACPClient` auto-declines any `session/request_permission`.
public actor ACPAssistant: ConversationalAssistant {
    public typealias ContainerControlProvider = @Sendable () async -> (siteID: String, control: any LocalContainerControl)?

    public enum ACPAssistantError: Error, Sendable, Equatable {
        /// A `.stdio` connection is active but no container is currently running for this site
        /// (e.g. the preview hasn't finished starting yet).
        case containerUnavailable
    }

    private let connection: ACPAgentConnection
    private let siteID: String
    private let sourceDirectory: URL
    private let makeTransport: @Sendable () async throws -> any ACPTransport

    private var client: ACPClient?
    private var sessionID: String?

    public init(
        connection: ACPAgentConnection,
        siteID: String,
        sourceDirectory: URL,
        containerControlProvider: @escaping ContainerControlProvider = { nil },
        secretStore: any SecretStore = PlatformSecretStore.make(),
        transportFactory: (@Sendable () async throws -> any ACPTransport)? = nil
    ) {
        self.connection = connection
        self.siteID = siteID
        self.sourceDirectory = sourceDirectory
        if let transportFactory {
            self.makeTransport = transportFactory
        } else {
            self.makeTransport = {
                switch connection.transport {
                case .stdio(let command, let arguments):
                    guard let snapshot = await containerControlProvider() else {
                        throw ACPAssistantError.containerUnavailable
                    }
                    return ACPContainerExecTransport(
                        control: snapshot.control, siteID: snapshot.siteID,
                        command: command, arguments: arguments
                    )
                case .remote(let url):
                    let token = try? secretStore.readACPAgentToken(id: connection.id)
                    return ACPHTTPTransport(endpoint: url, bearerToken: token.map { SessionToken(value: $0) })
                }
            }
        }
    }

    public nonisolated var capabilities: AssistantCapabilities {
        AssistantCapabilities(
            supportsStreaming: true, supportsStructuredOutput: false, supportsVision: false,
            supportsTools: true, maxContextTokens: nil, providerName: connection.name
        )
    }

    public func generate(prompt: String, context: AssistantContext) async throws -> AsyncThrowingStream<String, Error> {
        let events = try await converse(prompt: prompt, context: context)
        return AsyncThrowingStream { continuation in
            Task {
                for await event in events {
                    switch event {
                    case .textDelta(let text): continuation.yield(text)
                    case .failed(let message): continuation.finish(throwing: AssistantError.streamFailed(message)); return
                    case .turnComplete, .backendExited: continuation.finish(); return
                    default: break
                    }
                }
                continuation.finish()
            }
        }
    }

    #if compiler(>=6.4) && canImport(FoundationModels)
    public func generateStructured<T: Generable & Sendable>(prompt: String, context: AssistantContext, resultType: T.Type) async throws -> T {
        throw AssistantError.unsupported("ACP agents do not support FoundationModels guided generation")
    }
    #endif

    public func converse(prompt: String, context: AssistantContext) async throws -> AsyncStream<AssistantEvent> {
        let client = try await connectedClient()
        let sessionID = try await ensureSession(client: client)
        return try await client.sendPrompt(sessionID: sessionID, text: prompt)
    }

    /// `session/new`'s `cwd` means different filesystems depending on transport: a `.stdio` agent
    /// runs inside the site's container, where the repo is always cloned to the fixed guest path
    /// `/workspace/site` (matches `DeployExecutor`'s convention); a `.remote` agent runs wherever
    /// its own host is, where the only filesystem path that means anything to it is the one on
    /// THIS Mac — `sourceDirectory`.
    private var effectiveWorkingDirectory: String {
        switch connection.transport {
        case .stdio: return "/workspace/site"
        case .remote: return sourceDirectory.path
        }
    }

    public func cancel() async {
        guard let client, let sessionID else { return }
        await client.cancelSession(sessionID: sessionID)
    }

    public func resetSession() async {
        sessionID = nil
    }

    private func connectedClient() async throws -> ACPClient {
        if let client { return client }
        let transport = try await makeTransport()
        let newClient = ACPClient(transport: transport)
        try await newClient.initialize()
        client = newClient
        return newClient
    }

    private func ensureSession(client: ACPClient) async throws -> String {
        if let sessionID { return sessionID }
        let newSessionID = try await client.newSession(cwd: effectiveWorkingDirectory)
        sessionID = newSessionID
        return newSessionID
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter ACPAssistantTests`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/ACPAssistant.swift Tests/AnglesiteCoreTests/ACPAssistantTests.swift
git commit -m "feat(acp): add ACPAssistant ConversationalAssistant conformance"
```

---

### Task 11: `AssistantBackendResolver` + wire into `SiteAssistantSessionFactory`/`SiteWindowModel`

**Files:**
- Create: `Sources/AnglesiteCore/AssistantBackendResolver.swift`
- Test: `Tests/AnglesiteCoreTests/AssistantBackendResolverTests.swift`
- Modify: `Sources/AnglesiteApp/SiteAssistantSessionFactory.swift`
- Modify: `Sources/AnglesiteApp/SiteWindowModel.swift`
- Modify: `Tests/AnglesiteAppTests/SiteAssistantSessionFactoryTests.swift`

Note: despite the directory name, everything under `Sources/AnglesiteApp/` (except the `@main`
entry point and `LiveSiteRuntimeFactory.swift`) compiles into the `AnglesiteAppCore` **library**
target (`Package.swift:225`), which `Tests/AnglesiteAppTests` already exercises with plain
`swift test` — no `xcodebuild`/hosted-app run needed to verify this task's `SiteAssistantSessionFactory`/
`SiteWindowModel` edits, only to confirm the `Anglesite` app target itself still links (Step 4).

**Interfaces:**
- Consumes: `AppSettings.activeAssistantBackend` (Task 4), `ACPAgentStore` (Task 2), `ACPAssistant`
  (Task 10), `PreviewModel.activeContainerControl()` (`Sources/AnglesiteApp/PreviewModel.swift:449`, already exists).
- Produces: `public enum AssistantBackendResolver` with
  `static func activeAgentID(from raw: String) -> UUID?` and
  `static func resolveActiveACPAssistant(siteID:sourceDirectory:containerControlProvider:agentStore:appSettings:secretStore:) -> ACPAssistant?`.
  Modifies `SiteAssistantSessionFactory.makeSession(...)` to take a new
  `containerControlProvider: @escaping ContainerControlProvider` parameter and branch on the
  resolver's result before building `ChatModel`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/AssistantBackendResolverTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

final class AssistantBackendResolverTests {
    private let tempDir: URL
    private let persistenceURL: URL
    private let fileManager = FileManager.default
    private let defaults: UserDefaults
    private let suiteName: String

    init() throws {
        tempDir = fileManager.temporaryDirectory.appendingPathComponent("assistant-backend-resolver-\(UUID().uuidString)", isDirectory: true)
        persistenceURL = tempDir.appendingPathComponent("acp-agents.json")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        suiteName = "test-anglesite-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        try? fileManager.removeItem(at: tempDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test("activeAgentID parses a well-formed acp: prefix") func activeAgentIDParsesWellFormedPrefix() {
        let id = UUID()
        #expect(AssistantBackendResolver.activeAgentID(from: "acp:\(id.uuidString)") == id)
    }

    @Test("activeAgentID returns nil for foundationModels") func activeAgentIDReturnsNilForFoundationModels() {
        #expect(AssistantBackendResolver.activeAgentID(from: "foundationModels") == nil)
    }

    @Test("activeAgentID returns nil for a malformed UUID") func activeAgentIDReturnsNilForMalformedUUID() {
        #expect(AssistantBackendResolver.activeAgentID(from: "acp:not-a-uuid") == nil)
    }

    @Test("resolveActiveACPAssistant returns nil when backend is foundationModels") func resolveReturnsNilWhenBackendIsFoundationModels() {
        let settings = AppSettings(defaults: defaults)
        settings.activeAssistantBackend = "foundationModels"
        let resolved = AssistantBackendResolver.resolveActiveACPAssistant(
            siteID: "site-1", sourceDirectory: URL(fileURLWithPath: "/tmp/site-1"),
            containerControlProvider: { nil },
            agentStore: ACPAgentStore(persistenceURL: persistenceURL), appSettings: settings
        )
        #expect(resolved == nil)
    }

    @Test("resolveActiveACPAssistant returns nil when the referenced agent is missing") func resolveReturnsNilWhenAgentMissing() {
        let settings = AppSettings(defaults: defaults)
        settings.activeAssistantBackend = "acp:\(UUID().uuidString)"
        let resolved = AssistantBackendResolver.resolveActiveACPAssistant(
            siteID: "site-1", sourceDirectory: URL(fileURLWithPath: "/tmp/site-1"),
            containerControlProvider: { nil },
            agentStore: ACPAgentStore(persistenceURL: persistenceURL), appSettings: settings
        )
        #expect(resolved == nil)
    }

    @Test("resolveActiveACPAssistant returns an assistant when the referenced agent exists") func resolveReturnsAssistantWhenAgentExists() throws {
        let store = ACPAgentStore(persistenceURL: persistenceURL)
        let connection = ACPAgentConnection(id: UUID(), name: "Test Agent", transport: .remote(url: URL(string: "https://example.com")!))
        try store.add(connection)
        let settings = AppSettings(defaults: defaults)
        settings.activeAssistantBackend = "acp:\(connection.id.uuidString)"
        let resolved = AssistantBackendResolver.resolveActiveACPAssistant(
            siteID: "site-1", sourceDirectory: URL(fileURLWithPath: "/tmp/site-1"),
            containerControlProvider: { nil },
            agentStore: store, appSettings: settings
        )
        #expect(resolved != nil)
        #expect(resolved?.capabilities.providerName == "Test Agent")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter AssistantBackendResolverTests`
Expected: FAIL — `AssistantBackendResolver` does not exist yet (compile error).

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/AnglesiteCore/AssistantBackendResolver.swift
import Foundation

/// Resolves `AppSettings.activeAssistantBackend` into an `ACPAssistant`, or `nil` when the active
/// backend is `"foundationModels"` (the default) or references an agent that no longer exists —
/// `SiteAssistantSessionFactory` falls back to the existing `FoundationModelAssistant` path on
/// `nil`, exactly like `ContentAssistantFactory`'s "not compiled in" `nil` case (ACP agent
/// settings design spec §4.5).
public enum AssistantBackendResolver {
    /// Parses the `"acp:<uuid>"` convention. Returns `nil` for `"foundationModels"` or any
    /// malformed value — callers treat that as "use Foundation Models."
    public static func activeAgentID(from raw: String) -> UUID? {
        guard raw.hasPrefix("acp:") else { return nil }
        return UUID(uuidString: String(raw.dropFirst(4)))
    }

    public static func resolveActiveACPAssistant(
        siteID: String,
        sourceDirectory: URL,
        containerControlProvider: @escaping ACPAssistant.ContainerControlProvider,
        agentStore: ACPAgentStore = ACPAgentStore(),
        appSettings: AppSettings = .shared,
        secretStore: any SecretStore = PlatformSecretStore.make()
    ) -> ACPAssistant? {
        guard let agentID = activeAgentID(from: appSettings.activeAssistantBackend) else { return nil }
        guard let connections = try? agentStore.load(),
              let connection = connections.first(where: { $0.id == agentID }) else { return nil }
        return ACPAssistant(
            connection: connection,
            siteID: siteID,
            sourceDirectory: sourceDirectory,
            containerControlProvider: containerControlProvider,
            secretStore: secretStore
        )
    }
}
```

Modify `Sources/AnglesiteApp/SiteAssistantSessionFactory.swift`:

Add a new typealias near the existing ones (after `GraphSnapshotProvider`):

```swift
    typealias ContainerControlProvider = @Sendable () async -> (siteID: String, control: any LocalContainerControl)?
```

Add a parameter to `makeSession(...)`'s signature, right after `mcpClient`:

```swift
        mcpClient: @escaping MCPClientProvider,
        containerControlProvider: @escaping ContainerControlProvider,
```

Inside `makeSession`, replace the existing:

```swift
        let chat = ChatModel(
            siteID: siteID,
            siteDirectory: sourceDirectory,
            configDirectory: configDirectory,
            assistant: dependencies.assistant(
                editBridge,
                contentGraph,
                knowledgeIndex,
                semanticRanker,
                integrationService,
                conventionsEngine,
                conventionsStore,
                themeCatalog,
                designInterviewFactory,
                graphSnapshotProvider
            ),
            annotationFeed: dependencies.annotationFeed(sourceDirectory),
```

with:

```swift
        let resolvedAssistant: any ConversationalAssistant = AssistantBackendResolver.resolveActiveACPAssistant(
            siteID: siteID,
            sourceDirectory: sourceDirectory,
            containerControlProvider: containerControlProvider
        ) ?? dependencies.assistant(
            editBridge,
            contentGraph,
            knowledgeIndex,
            semanticRanker,
            integrationService,
            conventionsEngine,
            conventionsStore,
            themeCatalog,
            designInterviewFactory,
            graphSnapshotProvider
        )
        let chat = ChatModel(
            siteID: siteID,
            siteDirectory: sourceDirectory,
            configDirectory: configDirectory,
            assistant: resolvedAssistant,
            annotationFeed: dependencies.annotationFeed(sourceDirectory),
```

Modify `Sources/AnglesiteApp/SiteWindowModel.swift`: add a provider right next to the existing
`mcpClient` closure (around line 1234) and pass it into the `makeSession(...)` call (around line
1245):

```swift
        let containerControlProvider: SiteAssistantSessionFactory.ContainerControlProvider = { [preview] in
            await preview.activeContainerControl()
        }
```

```swift
        let assistantSession = SiteAssistantSessionFactory.makeSession(
            siteID: resolved.id,
            sourceDirectory: resolved.sourceDirectory,
            configDirectory: resolved.configDirectory,
            packageURL: resolved.packageURL,
            mcpClient: mcpClient,
            containerControlProvider: containerControlProvider,
            contentGraph: contentGraph,
```

(leave the rest of that call unchanged.)

Adding a required parameter to `makeSession(...)` breaks its two existing test call sites in
`Tests/AnglesiteAppTests/SiteAssistantSessionFactoryTests.swift` — update both (they otherwise
fail to compile, not just this task's new code):

```swift
        _ = SiteAssistantSessionFactory.makeSession(
            siteID: "site-1",
            sourceDirectory: root,
            configDirectory: root,
            mcpClient: { nil },
            containerControlProvider: { nil },
            contentGraph: SiteContentGraph(),
```

(in `forwardsGraphSnapshotProvider()`) and:

```swift
        _ = SiteAssistantSessionFactory.makeSession(
            siteID: "site-1",
            sourceDirectory: root,
            configDirectory: root,
            packageURL: packageURL,
            mcpClient: { nil },
            containerControlProvider: { nil },
            contentGraph: SiteContentGraph(),
```

(in `interviewFactoryPresence(packageURL:)`). Both tests keep passing unmodified otherwise: with
no ACP agent configured in the ambient `AppSettings.shared`/`ACPAgentStore()` defaults these tests
run against (neither test — nor anything else in this plan — ever mutates the real
`UserDefaults.standard`-backed `AppSettings.shared` or the real `~/Library/Application
Support/Anglesite/acp-agents.json`; `AppSettingsTests`/`AssistantBackendResolverTests` only ever
touch throwaway `UserDefaults(suiteName:)`/temp-dir `ACPAgentStore` instances), `resolveActiveACPAssistant`
returns `nil` and `dependencies.assistant(...)` fires exactly as it did before this task.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter AssistantBackendResolverTests`
Expected: PASS (6 tests)

Run: `swift test --package-path . --filter SiteAssistantSessionFactoryTests`
Expected: PASS (3 tests — both existing tests still pass with the new required parameter added,
per the fallback reasoning above).

Also run `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
(per this repo's rule that passing SwiftPM tests alone doesn't prove the real `.app` target links
— run `xcodegen generate` first if `Anglesite.xcodeproj` is stale relative to `project.yml`).
Expected: builds clean.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/AssistantBackendResolver.swift Tests/AnglesiteCoreTests/AssistantBackendResolverTests.swift Sources/AnglesiteApp/SiteAssistantSessionFactory.swift Sources/AnglesiteApp/SiteWindowModel.swift Tests/AnglesiteAppTests/SiteAssistantSessionFactoryTests.swift
git commit -m "feat(acp): resolve the active ACP backend into the chat assistant seam"
```

---

### Task 12: Settings "Agents" tab

**Files:**
- Modify: `Sources/AnglesiteApp/SettingsView.swift`

**Interfaces:**
- Consumes: `ACPAgentConnection`, `ACPAgentStore` (Task 2), `AppSettings.activeAssistantBackend`
  (Task 4), `SecretStore`/`KeychainStore`'s ACP token accessors (Task 3), the existing
  `KeychainTokenRow` view (`SettingsView.swift:232`).
- Produces: a 4th Settings tab, "Agents", with an active-model picker and ACP connection
  list/editor. No new public API — this is leaf UI.

No automated test — this repo has no UI test infra for Settings (per the design spec §4.6); this
task ends with a manual GUI smoke pass instead of a unit test cycle.

- [ ] **Step 1: Add the tab to the `TabView`**

In `Sources/AnglesiteApp/SettingsView.swift`, modify the `TabView` in `SettingsView.body`:

```swift
struct SettingsView: View {
    var body: some View {
        TabView {
            // General leads (#529): everyday toggles shouldn't hide behind an "Advanced" label.
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            SiriReadinessSettingsView()
                .tabItem { Label("Siri AI", systemImage: "sparkles") }
            AgentsSettingsView()
                .tabItem { Label("Agents", systemImage: "network") }
            AdvancedSettingsView()
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }
        }
        .frame(width: 540, height: 360)
    }
}
```

- [ ] **Step 2: Write `AgentsSettingsView` and its editor sheet**

Add this new private view to `SettingsView.swift`, near `AdvancedSettingsView`:

```swift
/// Configure ACP (Agent Client Protocol) agent connections and pick the active chat backend —
/// Apple Intelligence (on-device) or one of the registered agents (#602).
private struct AgentsSettingsView: View {
    @AppStorage(AppSettings.Key.activeAssistantBackend) private var activeAssistantBackend: String = "foundationModels"
    @State private var agents: [ACPAgentConnection] = []
    @State private var editingAgent: ACPAgentConnection?
    @State private var isPresentingEditor = false
    @State private var loadError: String?

    private let store = ACPAgentStore()

    var body: some View {
        Form {
            Section("Active Model") {
                Picker("Model", selection: $activeAssistantBackend) {
                    Text("Apple Intelligence (On-Device)").tag("foundationModels")
                    ForEach(agents) { agent in
                        Text(agent.name).tag("acp:\(agent.id.uuidString)")
                    }
                }
                .labelsHidden()
            }

            Section("ACP Agents") {
                if agents.isEmpty {
                    Text("No agents configured.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(agents) { agent in
                    LabeledContent(agent.name) {
                        HStack(spacing: 8) {
                            Text(transportSummary(agent.transport))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Edit…") {
                                editingAgent = agent
                                isPresentingEditor = true
                            }
                            Button("Remove") { remove(agent) }
                        }
                    }
                }
                Button("Add Agent…") {
                    editingAgent = nil
                    isPresentingEditor = true
                }
                if let loadError {
                    Text(loadError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task { reload() }
        .sheet(isPresented: $isPresentingEditor) {
            ACPAgentEditorSheet(existing: editingAgent) { saved in
                do {
                    if editingAgent != nil {
                        try store.update(saved)
                    } else {
                        try store.add(saved)
                    }
                    reload()
                } catch {
                    loadError = "couldn't save: \(error.localizedDescription)"
                }
                isPresentingEditor = false
            } onCancel: {
                isPresentingEditor = false
            }
        }
    }

    private func reload() {
        do {
            agents = try store.load()
            loadError = nil
        } catch {
            loadError = "couldn't load agents: \(error.localizedDescription)"
        }
    }

    private func remove(_ agent: ACPAgentConnection) {
        do {
            try store.remove(id: agent.id)
            // Selecting Foundation Models back if the removed agent was active avoids leaving
            // `activeAssistantBackend` pointing at a now-nonexistent agent — `AssistantBackendResolver`
            // would already fall back gracefully, but resetting the picker keeps the UI honest.
            if activeAssistantBackend == "acp:\(agent.id.uuidString)" {
                activeAssistantBackend = "foundationModels"
            }
            reload()
        } catch {
            loadError = "couldn't remove agent: \(error.localizedDescription)"
        }
    }

    private func transportSummary(_ transport: ACPAgentConnection.Transport) -> String {
        switch transport {
        case .stdio(let command, _): return "Local · \(command)"
        case .remote(let url): return "Remote · \(url.absoluteString)"
        }
    }
}

/// Add/edit sheet for one `ACPAgentConnection`. `onSave` receives the fully-formed connection;
/// the remote credential (if any) is written directly to the Keychain here (not threaded back
/// through `onSave`) since it never belongs in the non-secret `ACPAgentStore` record.
private struct ACPAgentEditorSheet: View {
    enum TransportKind: String, CaseIterable { case local = "Local", remote = "Remote" }

    let existing: ACPAgentConnection?
    let onSave: (ACPAgentConnection) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var kind: TransportKind
    @State private var command: String
    @State private var argumentsText: String
    @State private var urlText: String
    // A fresh, STABLE id for a new agent — seeded once via `init` below, not a computed
    // `existing?.id ?? UUID()`. That looks equivalent but is a real bug: `UUID()` in the fallback
    // branch would mint a NEW random id every time the property is read, so the Keychain write
    // (`KeychainTokenRow`'s `write` closure, evaluated at Save time) and the
    // `ACPAgentConnection(id:...)` constructed a few lines later in `save()` would end up with two
    // DIFFERENT ids — silently orphaning the just-saved token.
    @State private var agentID: UUID

    /// Seeds every `@State` property synchronously from `existing` before the first render —
    /// deliberately NOT an `.onAppear { populate() }` pattern, because `KeychainTokenRow`'s own
    /// `.task { await refreshStatus() }` (which reads `agentID` to look up the stored token) has
    /// no guaranteed ordering against a parent's `.onAppear`. Seeding in `init` means `agentID` is
    /// already correct on the very first render, so there is no race to reason about.
    init(existing: ACPAgentConnection?, onSave: @escaping (ACPAgentConnection) -> Void, onCancel: @escaping () -> Void) {
        self.existing = existing
        self.onSave = onSave
        self.onCancel = onCancel

        var kind: TransportKind = .local
        var command = ""
        var argumentsText = ""
        var urlText = ""
        switch existing?.transport {
        case .stdio(let cmd, let arguments):
            kind = .local
            command = cmd
            argumentsText = arguments.joined(separator: " ")
        case .remote(let url):
            kind = .remote
            urlText = url.absoluteString
        case nil:
            break
        }

        _agentID = State(initialValue: existing?.id ?? UUID())
        _name = State(initialValue: existing?.name ?? "")
        _kind = State(initialValue: kind)
        _command = State(initialValue: command)
        _argumentsText = State(initialValue: argumentsText)
        _urlText = State(initialValue: urlText)
    }

    var body: some View {
        Form {
            TextField("Name", text: $name)
            Picker("Transport", selection: $kind) {
                ForEach(TransportKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if kind == .local {
                TextField("Command", text: $command, prompt: Text("claude-code-acp"))
                TextField("Arguments (space-separated)", text: $argumentsText)
            } else {
                TextField("URL", text: $urlText, prompt: Text("https://agent.example.com/acp"))
                KeychainTokenRow(
                    title: "Bearer token",
                    read: { try KeychainStore().readACPAgentToken(id: agentID) },
                    write: { try KeychainStore().writeACPAgentToken($0, id: agentID) },
                    clear: { try KeychainStore().clearACPAgentToken(id: agentID) }
                )
            }

            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button("Save") { save() }
                    .disabled(!isValid)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 420)
    }

    private var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch kind {
        case .local: return !command.trimmingCharacters(in: .whitespaces).isEmpty
        case .remote: return URL(string: urlText) != nil
        }
    }

    private func save() {
        let transport: ACPAgentConnection.Transport
        switch kind {
        case .local:
            let args = argumentsText.split(separator: " ").map(String.init)
            transport = .stdio(command: command, arguments: args)
        case .remote:
            guard let url = URL(string: urlText) else { return }
            transport = .remote(url: url)
        }
        onSave(ACPAgentConnection(id: agentID, name: name, transport: transport))
    }
}
```

- [ ] **Step 3: Build**

Run: `swift build --package-path .` first for fast feedback (`SettingsView.swift` is part of the
`AnglesiteAppCore` library target, so this alone catches any compile error here).
Expected: builds clean.

Then run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: builds clean (run `xcodegen generate` first if the project file is stale — see this
repo's worktree note on `project.yml` regeneration).

- [ ] **Step 4: Manual GUI smoke**

Launch the app, open Settings (⌘,), select the new "Agents" tab, and verify:
1. "Apple Intelligence (On-Device)" is selected by default in the Active Model picker.
2. "Add Agent…" → fill in a Local agent (name + command) → Save → it appears in the list and in
   the Active Model picker.
3. Selecting the new agent in the picker persists across closing and reopening Settings.
4. "Edit…" on that agent opens the sheet pre-filled with its values; changing the name and saving
   updates the list entry.
5. Add a Remote agent with a URL and a bearer token via the `KeychainTokenRow` — confirm the
   token field shows "stored" after Save without ever displaying the raw value again.
6. "Remove" on the currently-active agent removes it from the list and the Active Model picker
   snaps back to "Apple Intelligence (On-Device)".

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/SettingsView.swift
git commit -m "feat(acp): add Agents Settings tab for ACP connections + active-model picker"
```
