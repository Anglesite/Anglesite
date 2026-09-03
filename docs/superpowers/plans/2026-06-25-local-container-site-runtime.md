# LocalContainerSiteRuntime (#69) Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the local macOS runtime that runs a site's `astro dev` + Node MCP sidecar inside an Apple-Containerization Linux VM, hydrated from the site's `Source/` git repo, exposed to the host over a vsock→TCP proxy.

**Architecture:** A three-piece split mirroring `RemoteSandboxSiteRuntime` (#315). The actor (`LocalContainerSiteRuntime`), the control-protocol seam (`LocalContainerControl`), the `VsockTCPProxy`, and the capability gate (`LocalContainerSupport`) live in **`AnglesiteCore`** and are fully unit-tested on CI with fakes. The concrete `Containerization`-importing conformer (`ContainerizationControl`) and the vendored arm64 OCI image live in a **new `AnglesiteContainer` SPM target** that CI never compiles and that only the macOS app targets link.

**Tech Stack:** Swift 6 / Swift Testing, `apple/containerization` (Swift 6.2, macOS 15+), POSIX sockets + `DispatchSource` for the proxy, `Virtualization.framework` (vsock + NAT) via the containerization package, a Go vsock→TCP bridge baked into the arm64 OCI image.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-06-25-local-container-site-runtime-design.md` — read it before starting.
- **Platform:** `LocalContainerSiteRuntime` is **Apple Silicon + macOS 26+ only**. Intel/iOS fall back to `RemoteSandboxSiteRuntime`.
- **CI boundary:** anything that imports `Containerization` or executes the VM must live in `AnglesiteContainer` and must NOT be reachable from any `swift test` target. `AnglesiteCore` stays free of the native dependency.
- **No native dep in core:** `AnglesiteCore` tests run on GitHub `macos-15` runners with no virtualization entitlement. Every core test must pass there.
- **Seam purity:** no `Containerization` / `Virtualization` types may appear in any `AnglesiteCore` signature. The seam speaks only `URL`, `String`, `FileHandle`, and the plan's own value types.
- **Ports:** the proxy always binds `127.0.0.1:0` (OS-assigned). Never hardcode a host port.
- **Selection is capability-only:** no feature flag. `LocalContainerSupport.isAvailable` is the sole gate (the entitlement is unforgeable — see spec §6.1).
- **Scope:** boot → hydrate-from-repo → preview → MCP → lifecycle. Repo push-back/sync is OUT of scope (#72 §8).
- **Linking:** DevID `Anglesite` target only; `AnglesiteMAS` deferred until the virtualization entitlement is granted.
- **Commit trailer:** end every commit message with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

## File Structure

**`AnglesiteCore` (CI-tested, no native dependency):**
- `Sources/AnglesiteCore/LocalContainerControl.swift` — protocol + `LocalContainerSession` + `LocalContainerError`.
- `Sources/AnglesiteCore/LocalContainerSiteRuntime.swift` — the `SiteRuntime` actor.
- `Sources/AnglesiteCore/VsockTCPProxy.swift` — TCP listener + bidirectional splice + `VsockDialer` seam.
- `Sources/AnglesiteCore/LocalContainerSupport.swift` — capability gate.

**`AnglesiteCore` tests:**
- `Tests/AnglesiteCoreTests/FakeLocalContainerControl.swift` — fake + gated fake.
- `Tests/AnglesiteCoreTests/LocalContainerSiteRuntimeTests.swift`
- `Tests/AnglesiteCoreTests/VsockTCPProxyTests.swift`
- `Tests/AnglesiteCoreTests/LocalContainerSupportTests.swift`

**`AnglesiteContainer` (new SPM target, app-linked, NOT CI-compiled):**
- `Sources/AnglesiteContainer/ContainerizationControl.swift` — conformer.
- `Sources/AnglesiteContainer/BundledImage.swift` — bundled OCI-layout import via `Bundle.module`.
- `Resources/container-image/` — vendored arm64 OCI layout (gitignored).

**Guest image / scripts:**
- `scripts/vendor-container-image.sh` — build arm64 image, export OCI layout into `Resources/container-image/`.
- `Containers/anglesite-dev/Dockerfile` — arm64 image (rebuild of #62).
- `Containers/anglesite-dev/vsock-bridge/main.go` — guest vsock→TCP forwarder.

**Wiring:**
- `Package.swift` — add `AnglesiteContainer` target + product + `containerization` dependency.
- `project.yml` — link `AnglesiteContainer` into the DevID `Anglesite` target; add the virtualization entitlement.
- `Sources/AnglesiteApp/PreviewModel.swift:40` — capability-driven runtime factory.
- `.gitignore` — ignore `Resources/container-image/`.

---

## Phase 1 — `AnglesiteCore` seam (CI-green, full TDD)

### Task 1: `LocalContainerControl` protocol + value types + fakes

**Files:**
- Create: `Sources/AnglesiteCore/LocalContainerControl.swift`
- Create: `Tests/AnglesiteCoreTests/FakeLocalContainerControl.swift`
- Test: `Tests/AnglesiteCoreTests/FakeLocalContainerControl.swift` (compile + a smoke assertion)

**Interfaces:**
- Produces: `protocol LocalContainerControl: Sendable { func start(siteID: String, sourceRepo: URL, ref: String) async throws -> LocalContainerSession; func stop(siteID: String) async throws }`
- Produces: `struct LocalContainerSession: Sendable, Equatable { let previewURL: URL; let mcpURL: URL }`
- Produces: `enum LocalContainerError: Error, Equatable { case virtualizationUnavailable; case imageUnavailable(String); case bootFailed(String); case cloneFailed(String) }`
- Produces (test target): `actor FakeLocalContainerControl` with `init(startResult:)`, `private(set) var stopped: [String]`, `private(set) var startedRepos: [(siteID: String, repo: URL, ref: String)]`.

- [ ] **Step 1: Write the source file**

Create `Sources/AnglesiteCore/LocalContainerControl.swift`:

```swift
import Foundation

/// Host-reachable endpoints a started local container exposes. Both are 127.0.0.1 URLs on
/// OS-assigned ports, delivered by the host-side vsock→TCP proxy. Mirrors `SandboxSession`.
public struct LocalContainerSession: Sendable, Equatable {
    public let previewURL: URL
    public let mcpURL: URL
    public init(previewURL: URL, mcpURL: URL) {
        self.previewURL = previewURL
        self.mcpURL = mcpURL
    }
}

public enum LocalContainerError: Error, Equatable {
    case virtualizationUnavailable      // no entitlement / not Apple Silicon / macOS < 26
    case imageUnavailable(String)       // bundled OCI layout missing or failed to import
    case bootFailed(String)             // VM/container failed to boot
    case cloneFailed(String)            // git clone of Source/ into the guest failed
}

/// Typed wrapper over "boot a container, hydrate it from a repo, start the guest processes, and
/// return host-reachable endpoints." `ContainerizationControl` (in AnglesiteContainer) is the
/// production conformer; `FakeLocalContainerControl` backs the tests. Mirrors `SandboxControlClient`.
/// No `Containerization`/`Virtualization` types cross this seam.
public protocol LocalContainerControl: Sendable {
    func start(siteID: String, sourceRepo: URL, ref: String) async throws -> LocalContainerSession
    func stop(siteID: String) async throws
}
```

- [ ] **Step 2: Write the fakes**

Create `Tests/AnglesiteCoreTests/FakeLocalContainerControl.swift`:

```swift
import Foundation
@testable import AnglesiteCore

actor FakeLocalContainerControl: LocalContainerControl {
    var startResult: Result<LocalContainerSession, LocalContainerError>
    private(set) var stopped: [String] = []
    private(set) var startedRepos: [(siteID: String, repo: URL, ref: String)] = []

    init(startResult: Result<LocalContainerSession, LocalContainerError>) {
        self.startResult = startResult
    }

    func start(siteID: String, sourceRepo: URL, ref: String) async throws -> LocalContainerSession {
        startedRepos.append((siteID, sourceRepo, ref))
        return try startResult.get()
    }

    func stop(siteID: String) async throws { stopped.append(siteID) }
}

/// A `LocalContainerControl` whose `start` suspends until `release()` is called — for
/// deterministically interleaving a concurrent `stop()`/second `start()` while the first
/// `start()` is parked. Mirrors `GatedFakeSandboxControlClient`.
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

    func start(siteID: String, sourceRepo: URL, ref: String) async throws -> LocalContainerSession {
        await withCheckedContinuation { cont in
            parkedContinuation?.resume()
            parkedContinuation = nil
            gateContinuation = cont
        }
        return try result.get()
    }
    func stop(siteID: String) async throws { stopped.append(siteID) }
}
```

- [ ] **Step 3: Build the test target to verify it compiles**

Run: `swift build --build-tests 2>&1 | tail -5`
Expected: builds with no errors (the fakes conform to the new protocol).

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteCore/LocalContainerControl.swift Tests/AnglesiteCoreTests/FakeLocalContainerControl.swift
git commit -m "feat(#69): LocalContainerControl seam + test fakes

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `LocalContainerSiteRuntime` actor

**Files:**
- Create: `Sources/AnglesiteCore/LocalContainerSiteRuntime.swift`
- Test: `Tests/AnglesiteCoreTests/LocalContainerSiteRuntimeTests.swift`

**Interfaces:**
- Consumes: `LocalContainerControl`, `LocalContainerSession`, `LocalContainerError` (Task 1); `SiteRuntime`, `SiteRuntimeState`, `MCPClient`, `ProcessSupervisor`, `LogCenter` (existing).
- Produces: `actor LocalContainerSiteRuntime: SiteRuntime` with `init(sourceRepo: URL, ref: String, control: any LocalContainerControl, mcpClient: MCPClient, connect: @escaping @Sendable (MCPClient, URL) async throws -> Void = { c, u in try await c.connect(httpEndpoint: u) })`, plus `var state: SiteRuntimeState`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/LocalContainerSiteRuntimeTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

struct LocalContainerSiteRuntimeTests {
    private func makeRuntime(
        _ result: Result<LocalContainerSession, LocalContainerError>,
        connect: @escaping @Sendable (MCPClient, URL) async throws -> Void = { _, _ in }
    ) -> (LocalContainerSiteRuntime, FakeLocalContainerControl) {
        let fake = FakeLocalContainerControl(startResult: result)
        let mcp = MCPClient(supervisor: ProcessSupervisor(), logCenter: LogCenter())
        let rt = LocalContainerSiteRuntime(
            sourceRepo: URL(fileURLWithPath: "/sites/Foo.anglesite/Source"),
            ref: "HEAD",
            control: fake,
            mcpClient: mcp,
            connect: connect)
        return (rt, fake)
    }

    private static let ok = LocalContainerSession(
        previewURL: URL(string: "http://127.0.0.1:51001")!,
        mcpURL: URL(string: "http://127.0.0.1:51002/mcp")!)

    @Test("start settles to .ready with the preview URL")
    func startReady() async {
        let (rt, _) = makeRuntime(.success(Self.ok))
        await rt.start(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/sites/Foo.anglesite/Source"))
        #expect(await rt.state == .ready(siteID: "s1", url: Self.ok.previewURL))
    }

    @Test("start passes the siteDirectory as a file:// sourceRepo to the control")
    func startHydratesFromRepo() async {
        let (rt, fake) = makeRuntime(.success(Self.ok))
        let dir = URL(fileURLWithPath: "/sites/Foo.anglesite/Source")
        await rt.start(siteID: "s1", siteDirectory: dir)
        let started = await fake.startedRepos
        #expect(started.count == 1)
        #expect(started.first?.repo == dir)
        #expect(started.first?.ref == "HEAD")
    }

    @Test("start connects the MCP client to the session's mcpURL")
    func startConnectsMCP() async {
        let box = ConnectedURLBox()
        let (rt, _) = makeRuntime(.success(Self.ok), connect: { _, url in await box.set(url) })
        await rt.start(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/unused"))
        #expect(await box.url == Self.ok.mcpURL)
    }

    @Test("control failure settles to .failed with a friendly message")
    func startFailed() async {
        let (rt, _) = makeRuntime(.failure(.bootFailed("vm refused to boot")))
        await rt.start(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/unused"))
        if case .failed(let id, let msg) = await rt.state {
            #expect(id == "s1")
            #expect(msg.contains("vm refused to boot"))
        } else { Issue.record("expected .failed, got \(await rt.state)") }
    }

    @Test("stop calls the control client and returns to .idle")
    func stop() async {
        let (rt, fake) = makeRuntime(.success(Self.ok))
        await rt.start(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/unused"))
        await rt.stop()
        #expect(await rt.state == .idle)
        #expect(await fake.stopped == ["s1"])
    }

    @Test("stop during suspended start: stale-generation guard drops the result")
    func staleGenerationGuard() async {
        let gated = GatedFakeLocalContainerControl(result: .success(Self.ok))
        let mcp = MCPClient(supervisor: ProcessSupervisor(), logCenter: LogCenter())
        let rt = LocalContainerSiteRuntime(
            sourceRepo: URL(fileURLWithPath: "/sites/Foo/Source"), ref: "HEAD",
            control: gated, mcpClient: mcp, connect: { _, _ in })
        let startTask = Task { await rt.start(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/unused")) }
        await gated.waitUntilParked()
        await rt.stop()
        await gated.release()
        await startTask.value
        #expect(await rt.state == .idle)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter LocalContainerSiteRuntimeTests 2>&1 | tail -15`
Expected: FAIL — `cannot find 'LocalContainerSiteRuntime' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/AnglesiteCore/LocalContainerSiteRuntime.swift` (a near-verbatim copy of `RemoteSandboxSiteRuntime`, swapping the control type and deriving `sourceRepo` from init):

```swift
import Foundation

/// `SiteRuntime` over a local Apple-Containerization VM (macOS 26+/Apple Silicon; see design
/// 2026-06-25). Mirrors `LocalSiteRuntime`'s state machine but drives a `LocalContainerControl`
/// instead of a local subprocess: boot the container, hydrate it from the site's `Source/` git
/// repo, connect the MCP client to the returned MCP endpoint, settle to `.ready`/`.failed`.
/// Spawns nothing in-process.
public actor LocalContainerSiteRuntime: SiteRuntime {
    private let sourceRepo: URL
    private let ref: String
    private let control: any LocalContainerControl
    public let mcpClient: MCPClient
    private let connect: @Sendable (MCPClient, URL) async throws -> Void

    private var current: SiteRuntimeState = .idle
    private var observers: [UUID: AsyncStream<SiteRuntimeState>.Continuation] = [:]
    private var generation = 0
    private var activeSiteID: String?

    public init(
        sourceRepo: URL,
        ref: String,
        control: any LocalContainerControl,
        mcpClient: MCPClient,
        connect: @escaping @Sendable (MCPClient, URL) async throws -> Void = { c, u in try await c.connect(httpEndpoint: u) }
    ) {
        self.sourceRepo = sourceRepo
        self.ref = ref
        self.control = control
        self.mcpClient = mcpClient
        self.connect = connect
    }

    public var state: SiteRuntimeState { current }

    public func observe() -> AsyncStream<SiteRuntimeState> {
        let (stream, continuation) = AsyncStream<SiteRuntimeState>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        continuation.yield(current)
        return stream
    }

    /// `siteDirectory` is the package's `Source/` directory; it becomes the `file://` repo the
    /// container clones (git is the source of truth, #72). The configured `ref` selects the commit.
    public func start(siteID: String, siteDirectory: URL) async {
        await teardown()
        generation += 1
        let gen = generation
        setState(.starting(siteID: siteID))
        do {
            let session = try await control.start(siteID: siteID, sourceRepo: siteDirectory, ref: ref)
            guard gen == generation else { return }
            try await connect(mcpClient, session.mcpURL)
            guard gen == generation else { return }
            activeSiteID = siteID
            setState(.ready(siteID: siteID, url: session.previewURL))
        } catch {
            guard gen == generation else { return }
            setState(.failed(siteID: siteID, message: Self.friendlyMessage(for: error)))
        }
    }

    public func stop() async {
        generation += 1
        await teardown()
        setState(.idle)
    }

    // MARK: Internals

    private func teardown() async {
        await mcpClient.stop()
        if let id = activeSiteID {
            try? await control.stop(siteID: id)
            activeSiteID = nil
        }
    }

    private func setState(_ s: SiteRuntimeState) {
        guard s != current else { return }
        current = s
        for c in observers.values { c.yield(s) }
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    static func friendlyMessage(for error: Error) -> String {
        switch error {
        case LocalContainerError.virtualizationUnavailable:
            return "This Mac can't run a local preview — using the remote runtime instead."
        case LocalContainerError.imageUnavailable(let m):
            return "The preview image isn't available: \(m)"
        case LocalContainerError.bootFailed(let m):
            return "Couldn't start the local preview: \(m)"
        case LocalContainerError.cloneFailed(let m):
            return "Couldn't load this site into the preview: \(m)"
        default:
            return "Couldn't start the local preview: \(error)"
        }
    }
}
```

> Note: `ConnectedURLBox` already exists in `RemoteSandboxSiteRuntimeTests.swift` in the same test target — reuse it; do not redefine.

- [ ] **Step 4: Run to verify the tests pass**

Run: `swift test --filter LocalContainerSiteRuntimeTests 2>&1 | tail -15`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/LocalContainerSiteRuntime.swift Tests/AnglesiteCoreTests/LocalContainerSiteRuntimeTests.swift
git commit -m "feat(#69): LocalContainerSiteRuntime actor (state machine + tests)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `VsockTCPProxy` — TCP listener + bidirectional splice

**Files:**
- Create: `Sources/AnglesiteCore/VsockTCPProxy.swift`
- Test: `Tests/AnglesiteCoreTests/VsockTCPProxyTests.swift`

**Interfaces:**
- Produces: `public typealias VsockDialer = @Sendable (_ guestPort: UInt32) async throws -> FileHandle`
- Produces: `public actor VsockTCPProxy` with `init(guestPort: UInt32, dial: @escaping VsockDialer)`, `func start() throws -> URL` (returns `http://127.0.0.1:<assignedPort>`), `func stop()`.

The proxy binds `127.0.0.1:0`, reads the OS-assigned port via `getsockname`, and on each accepted TCP connection dials the guest vsock port and splices the two `FileHandle`s. CI tests pass a loopback dialer (one end of a `socketpair`) — no framework, no entitlement.

- [ ] **Step 1: Write the failing test**

Create `Tests/AnglesiteCoreTests/VsockTCPProxyTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

struct VsockTCPProxyTests {
    /// Make a connected pair of FileHandles via socketpair(2). One end is handed to the proxy as
    /// the "guest"; the test holds the other to act as the guest peer.
    private func socketPair() -> (FileHandle, FileHandle) {
        var fds: [Int32] = [0, 0]
        let rc = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        #expect(rc == 0)
        return (FileHandle(fileDescriptor: fds[0], closeOnDealloc: true),
                FileHandle(fileDescriptor: fds[1], closeOnDealloc: true))
    }

    private func connectTCP(to url: URL) throws -> FileHandle {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #expect(fd >= 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(url.port!)).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(rc == 0)
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    @Test("client→guest: bytes written to the TCP client appear on the guest handle")
    func clientToGuest() async throws {
        let (guestForProxy, guestPeer) = socketPair()
        let proxy = VsockTCPProxy(guestPort: 4321, dial: { _ in guestForProxy })
        let url = try await proxy.start()
        let client = try connectTCP(to: url)
        try client.write(contentsOf: Data("hello".utf8))
        // Read 5 bytes from the guest peer.
        let got = try guestPeer.read(upToCount: 5)
        #expect(got == Data("hello".utf8))
        await proxy.stop()
    }

    @Test("guest→client: bytes written to the guest handle appear at the TCP client")
    func guestToClient() async throws {
        let (guestForProxy, guestPeer) = socketPair()
        let proxy = VsockTCPProxy(guestPort: 4321, dial: { _ in guestForProxy })
        let url = try await proxy.start()
        let client = try connectTCP(to: url)
        try guestPeer.write(contentsOf: Data("world".utf8))
        let got = try client.read(upToCount: 5)
        #expect(got == Data("world".utf8))
        await proxy.stop()
    }

    @Test("start returns a loopback URL with a nonzero OS-assigned port")
    func assignsPort() async throws {
        let (guestForProxy, _) = socketPair()
        let proxy = VsockTCPProxy(guestPort: 4321, dial: { _ in guestForProxy })
        let url = try await proxy.start()
        #expect(url.host == "127.0.0.1")
        #expect((url.port ?? 0) > 0)
        await proxy.stop()
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter VsockTCPProxyTests 2>&1 | tail -15`
Expected: FAIL — `cannot find 'VsockTCPProxy' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/AnglesiteCore/VsockTCPProxy.swift`:

```swift
import Foundation

/// Dials a guest vsock port and returns a `FileHandle` for the bidirectional byte stream.
/// Production passes `{ port in try container.dialVsock(port: port) }`; tests pass a loopback
/// (socketpair) dialer. This closure is the ONLY framework-bound part of the proxy.
public typealias VsockDialer = @Sendable (_ guestPort: UInt32) async throws -> FileHandle

/// Host-side proxy: listens on `127.0.0.1:0` and, for each accepted TCP connection, dials the
/// guest vsock port and splices the two `FileHandle`s bidirectionally until either side closes.
/// This is the seam that lets `WKWebView` load `http://127.0.0.1:<port>` and `MCPClient` connect
/// over plain HTTP while the actual server runs inside the VM, reachable only over vsock.
public actor VsockTCPProxy {
    private let guestPort: UInt32
    private let dial: VsockDialer
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [ProxyConnection] = []

    public init(guestPort: UInt32, dial: @escaping VsockDialer) {
        self.guestPort = guestPort
        self.dial = dial
    }

    /// Bind + listen on 127.0.0.1:0, install the accept handler, and return the loopback URL with
    /// the OS-assigned port. Throws `LocalContainerError.bootFailed` on any socket error.
    public func start() throws -> URL {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LocalContainerError.bootFailed("socket() failed") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0                                   // OS-assigned
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindRC = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRC == 0 else { close(fd); throw LocalContainerError.bootFailed("bind() failed") }
        guard listen(fd, 16) == 0 else { close(fd); throw LocalContainerError.bootFailed("listen() failed") }

        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        let port = UInt16(bigEndian: bound.sin_port)

        self.listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd)
        source.setEventHandler { [weak self] in
            let conn = accept(fd, nil, nil)
            guard conn >= 0 else { return }
            Task { await self?.handleAccepted(conn) }
        }
        source.resume()
        self.acceptSource = source

        return URL(string: "http://127.0.0.1:\(port)")!
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        for c in connections { c.close() }
        connections.removeAll()
    }

    private func handleAccepted(_ tcpFD: Int32) async {
        let tcp = FileHandle(fileDescriptor: tcpFD, closeOnDealloc: true)
        do {
            let guest = try await dial(guestPort)
            let conn = ProxyConnection(tcp: tcp, guest: guest)
            connections.append(conn)
            conn.start()
        } catch {
            try? tcp.close()
        }
    }
}

/// One spliced TCP↔vsock pair. Uses each handle's `readabilityHandler` to copy bytes both ways;
/// an empty read (EOF) tears the pair down.
final class ProxyConnection: @unchecked Sendable {
    private let tcp: FileHandle
    private let guest: FileHandle
    private let lock = NSLock()
    private var closed = false

    init(tcp: FileHandle, guest: FileHandle) { self.tcp = tcp; self.guest = guest }

    func start() {
        pump(from: tcp, to: guest)
        pump(from: guest, to: tcp)
    }

    private func pump(from: FileHandle, to: FileHandle) {
        from.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { self?.close(); return }
            try? to.write(contentsOf: data)
        }
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        tcp.readabilityHandler = nil
        guest.readabilityHandler = nil
        try? tcp.close()
        try? guest.close()
    }
}
```

- [ ] **Step 4: Run to verify the tests pass**

Run: `swift test --filter VsockTCPProxyTests 2>&1 | tail -15`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/VsockTCPProxy.swift Tests/AnglesiteCoreTests/VsockTCPProxyTests.swift
git commit -m "feat(#69): VsockTCPProxy with injectable dialer (loopback-tested)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: `LocalContainerSupport` capability gate

**Files:**
- Create: `Sources/AnglesiteCore/LocalContainerSupport.swift`
- Test: `Tests/AnglesiteCoreTests/LocalContainerSupportTests.swift`

**Interfaces:**
- Produces: `public enum LocalContainerSupport { public static func isAvailable(isAppleSilicon: Bool = Self.hostIsAppleSilicon, osIsSupported: Bool = Self.hostOSIsSupported, hasVirtualizationEntitlement: Bool = Self.hostHasVirtualizationEntitlement) -> Bool }` plus the three default host-probe statics.

The three inputs are injectable so the pure decision is testable on CI (where all three host probes are false). Production calls `isAvailable()` with defaults.

- [ ] **Step 1: Write the failing test**

Create `Tests/AnglesiteCoreTests/LocalContainerSupportTests.swift`:

```swift
import Testing
@testable import AnglesiteCore

struct LocalContainerSupportTests {
    @Test("available only when all three conditions hold")
    func allThree() {
        #expect(LocalContainerSupport.isAvailable(isAppleSilicon: true, osIsSupported: true, hasVirtualizationEntitlement: true) == true)
    }

    @Test("unavailable if not Apple Silicon")
    func notAppleSilicon() {
        #expect(LocalContainerSupport.isAvailable(isAppleSilicon: false, osIsSupported: true, hasVirtualizationEntitlement: true) == false)
    }

    @Test("unavailable if OS too old")
    func oldOS() {
        #expect(LocalContainerSupport.isAvailable(isAppleSilicon: true, osIsSupported: false, hasVirtualizationEntitlement: true) == false)
    }

    @Test("unavailable without the virtualization entitlement")
    func noEntitlement() {
        #expect(LocalContainerSupport.isAvailable(isAppleSilicon: true, osIsSupported: true, hasVirtualizationEntitlement: false) == false)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter LocalContainerSupportTests 2>&1 | tail -15`
Expected: FAIL — `cannot find 'LocalContainerSupport' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/AnglesiteCore/LocalContainerSupport.swift`:

```swift
import Foundation

/// Decides whether `LocalContainerSiteRuntime` can run on this build/host. The entitlement is the
/// real gate (it's unforgeable — an un-entitled build is SIGKILL'd by `amfid` at launch, see the
/// #60 spike), so no feature flag is needed: a build without it simply reports `false` and the app
/// falls back to `LocalSiteRuntime` / `RemoteSandboxSiteRuntime`.
public enum LocalContainerSupport {
    public static func isAvailable(
        isAppleSilicon: Bool = hostIsAppleSilicon,
        osIsSupported: Bool = hostOSIsSupported,
        hasVirtualizationEntitlement: Bool = hostHasVirtualizationEntitlement
    ) -> Bool {
        isAppleSilicon && osIsSupported && hasVirtualizationEntitlement
    }

    /// True on arm64. Intel Macs report false.
    public static var hostIsAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// True on macOS 26+ (the floor for Apple Containerization's vsock + NAT model).
    public static var hostOSIsSupported: Bool {
        if #available(macOS 26.0, *) { return true } else { return false }
    }

    /// Whether this process carries `com.apple.security.virtualization`. Read from the signed
    /// entitlements via `SecTaskCopyValueForEntitlement`; absent/unsigned → false. The concrete
    /// probe lives in `AnglesiteContainer` (it needs `Security`/`Virtualization` to confirm a
    /// usable VM); in `AnglesiteCore` the default is conservatively false so CI never selects the
    /// container path. Production overrides this via the `isAvailable(...)` parameter from the app.
    public static var hostHasVirtualizationEntitlement: Bool { false }
}
```

> The app target (Task 9) passes the real entitlement check (from `AnglesiteContainer`) into `isAvailable(hasVirtualizationEntitlement:)`. Core's default of `false` guarantees CI and un-entitled builds never select the container path.

- [ ] **Step 4: Run to verify the tests pass**

Run: `swift test --filter LocalContainerSupportTests 2>&1 | tail -15`
Expected: PASS (4 tests).

- [ ] **Step 5: Run the full core suite to confirm no regressions**

Run: `swift test 2>&1 | tail -15`
Expected: all tests pass (existing + the new Phase-1 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/LocalContainerSupport.swift Tests/AnglesiteCoreTests/LocalContainerSupportTests.swift
git commit -m "feat(#69): LocalContainerSupport capability gate

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Phase 2 — `AnglesiteContainer` target + image (local build, NOT CI)

> These tasks add the native dependency and the VM-touching code. They build only on an
> Apple-Silicon Mac with Xcode 27 and a development provisioning profile carrying
> `com.apple.security.virtualization`. **CI does not compile this target.** Verification is local
> (`swift build --target AnglesiteContainer`) plus the running DevID app.

### Task 5: Add the `AnglesiteContainer` SPM target + dependency

**Files:**
- Modify: `Package.swift`
- Create: `Sources/AnglesiteContainer/Placeholder.swift` (temporary, so the target compiles before Task 6/7 add real files)

**Interfaces:**
- Produces: a `.library(name: "AnglesiteContainer", targets: ["AnglesiteContainer"])` product and an `AnglesiteContainer` target depending on `AnglesiteCore` + the `Containerization` product of `apple/containerization`. No test target depends on it.

- [ ] **Step 1: Add the package dependency and target to `Package.swift`**

Add to the `Package(...)` call:

```swift
    dependencies: [
        .package(url: "https://github.com/apple/containerization.git", from: "0.1.0")
    ],
```

Add a placeholder source so the target has something to compile:

Create `Sources/AnglesiteContainer/Placeholder.swift`:

```swift
// AnglesiteContainer: the Apple-Containerization-backed conformer of LocalContainerControl.
// CI never compiles this target; only the macOS app targets link it. Real content arrives in
// Tasks 6–7. This placeholder keeps the target buildable in between.
import Foundation
enum AnglesiteContainerModule { static let marker = true }
```

Append the target to `packageTargets` (after `AnglesiteIntents`, before the test targets):

```swift
    .target(
        name: "AnglesiteContainer",
        dependencies: [
            "AnglesiteCore",
            .product(name: "Containerization", package: "containerization")
        ],
        path: "Sources/AnglesiteContainer",
        resources: [.copy("../../Resources/container-image")],
        swiftSettings: strictConcurrency
    ),
```

Add the product to the `products:` array:

```swift
        .library(name: "AnglesiteContainer", targets: ["AnglesiteContainer"]),
```

> The `resources: [.copy(...)]` points at `Resources/container-image` (populated in Task 7). Create an empty `Resources/container-image/.gitkeep` now so the `.copy` path resolves during this task's build.

- [ ] **Step 2: Create the resource directory placeholder**

```bash
mkdir -p Resources/container-image && touch Resources/container-image/.gitkeep
```

- [ ] **Step 3: Verify the package resolves and the new target builds locally**

Run: `swift build --target AnglesiteContainer 2>&1 | tail -20`
Expected: resolves `containerization` + its graph (NIO/gRPC/protobuf) and builds the placeholder. (First resolve is slow.)

- [ ] **Step 4: Verify the CI flow still ignores it**

Run: `swift test --filter LocalContainerSupportTests 2>&1 | tail -5`
Expected: PASS — `swift test` builds the test targets only; it does NOT compile `AnglesiteContainer` (no test target depends on it). Confirm `AnglesiteContainer` does not appear in the build log.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/AnglesiteContainer/Placeholder.swift Resources/container-image/.gitkeep
git commit -m "build(#69): add AnglesiteContainer target + containerization dependency

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Vendored arm64 OCI image + guest vsock→TCP bridge

**Files:**
- Create: `Containers/anglesite-dev/Dockerfile`
- Create: `Containers/anglesite-dev/vsock-bridge/main.go`
- Create: `Containers/anglesite-dev/vsock-bridge/go.mod`
- Create: `scripts/vendor-container-image.sh`
- Modify: `.gitignore`

**Interfaces:**
- Produces: `Resources/container-image/` populated with an arm64 OCI layout (an `index.json` + `blobs/` tree) after running the vendor script. Consumed by `BundledImage` (Task 7).
- Produces: a guest process that listens on vsock ports 4321/4399 and forwards to `127.0.0.1:4321`/`127.0.0.1:4399`.

- [ ] **Step 1: Write the guest vsock→TCP bridge**

Create `Containers/anglesite-dev/vsock-bridge/go.mod`:

```
module anglesite/vsock-bridge

go 1.22

require golang.org/x/sys v0.21.0
```

Create `Containers/anglesite-dev/vsock-bridge/main.go`:

```go
// vsock-bridge listens on the given AF_VSOCK ports and forwards each connection to the matching
// 127.0.0.1 TCP port inside the guest. The host reaches astro/MCP (which speak TCP) by dialing
// these vsock ports; this bridge is the vsock↔TCP shim. Usage: vsock-bridge 4321:4321 4399:4399
package main

import (
	"fmt"
	"io"
	"net"
	"os"
	"strconv"
	"strings"

	"golang.org/x/sys/unix"
)

func main() {
	for _, arg := range os.Args[1:] {
		parts := strings.SplitN(arg, ":", 2)
		vport, _ := strconv.Atoi(parts[0])
		tport := parts[1]
		go listen(uint32(vport), tport)
	}
	select {} // run forever
}

func listen(vport uint32, tcpPort string) {
	fd, err := unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM, 0)
	if err != nil { panic(err) }
	sa := &unix.SockaddrVM{CID: unix.VMADDR_CID_ANY, Port: vport}
	if err := unix.Bind(fd, sa); err != nil { panic(err) }
	if err := unix.Listen(fd, 16); err != nil { panic(err) }
	for {
		nfd, _, err := unix.Accept(fd)
		if err != nil { continue }
		go splice(nfd, tcpPort)
	}
}

func splice(vfd int, tcpPort string) {
	vconn := osConn(vfd)
	tconn, err := net.Dial("tcp", "127.0.0.1:"+tcpPort)
	if err != nil { vconn.Close(); return }
	go func() { io.Copy(tconn, vconn); tconn.Close() }()
	io.Copy(vconn, tconn); vconn.Close()
}

func osConn(fd int) net.Conn {
	f := os.NewFile(uintptr(fd), fmt.Sprintf("vsock-%d", fd))
	c, _ := net.FileConn(f) // net.FileConn dup's the fd
	f.Close()
	return c
}
```

- [ ] **Step 2: Write the Dockerfile (arm64)**

Create `Containers/anglesite-dev/Dockerfile`:

```dockerfile
# Anglesite local dev-server image (arm64 / Apple Silicon). Built and exported as an OCI layout by
# scripts/vendor-container-image.sh, then bundled into AnglesiteContainer. Bakes Node + the app's
# MCP sidecar + the vsock→TCP bridge so first run needs no in-guest install.
FROM --platform=linux/arm64 node:22-bookworm-slim

# git is needed to clone the site's Source/ repo at boot; ca-certificates for npm/outbound.
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Build the vsock bridge.
FROM --platform=linux/arm64 golang:1.22-bookworm AS bridge
WORKDIR /src
COPY vsock-bridge/ ./vsock-bridge/
RUN cd vsock-bridge && go mod tidy && CGO_ENABLED=0 GOARCH=arm64 go build -o /vsock-bridge .

FROM node:22-bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=bridge /vsock-bridge /usr/local/bin/vsock-bridge
# The MCP sidecar + entrypoint are layered in by the build script from the app's bundled plugin.
WORKDIR /workspace
```

> The boot orchestration (clone the repo, `npm install` if needed, start `astro dev` on 4321, start the MCP sidecar, then `vsock-bridge 4321:4321 4399:4399`) is driven from the host by `ContainerizationControl.start` issuing guest commands (Task 7) — not an `ENTRYPOINT` — so the host controls hydration timing per `start()` call.

- [ ] **Step 3: Write the vendor script**

Create `scripts/vendor-container-image.sh`:

```bash
#!/usr/bin/env bash
# Build the arm64 Anglesite dev image and export it as an OCI layout into Resources/container-image/.
# Mirrors scripts/vendor-node.sh: produces a gitignored, bundled app resource. Requires Docker (or
# a compatible buildx) with linux/arm64 support, run on an Apple-Silicon Mac.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CTX="$ROOT/Containers/anglesite-dev"
OUT="$ROOT/Resources/container-image"

echo "Building anglesite-dev:latest (linux/arm64)…"
docker buildx build --platform linux/arm64 -t anglesite-dev:latest "$CTX" --load

echo "Exporting OCI layout → $OUT"
rm -rf "$OUT"; mkdir -p "$OUT"
# `docker save` produces a docker-archive; convert to an OCI layout with skopeo.
docker save anglesite-dev:latest -o "$OUT/image.tar"
skopeo copy docker-archive:"$OUT/image.tar" oci:"$OUT":anglesite-dev:latest
rm -f "$OUT/image.tar"
echo "Done. Resources/container-image/ now holds an OCI layout."
```

```bash
chmod +x scripts/vendor-container-image.sh
```

- [ ] **Step 4: Gitignore the vendored layout**

Add to `.gitignore`:

```
# Vendored arm64 OCI image (populated by scripts/vendor-container-image.sh; bundled into AnglesiteContainer)
Resources/container-image/
!Resources/container-image/.gitkeep
```

- [ ] **Step 5: Build the image locally**

Run: `./scripts/vendor-container-image.sh 2>&1 | tail -20`
Expected: `Resources/container-image/` contains `index.json`, `oci-layout`, and a `blobs/sha256/` tree. (Requires Docker + skopeo: `brew install skopeo`.)

- [ ] **Step 6: Commit (script + Dockerfile + bridge + gitignore — NOT the image blob)**

```bash
git add Containers/anglesite-dev scripts/vendor-container-image.sh .gitignore
git commit -m "build(#69): arm64 dev image + guest vsock->TCP bridge + vendor script

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: `ContainerizationControl` conformer (boot → hydrate → run → expose)

**Files:**
- Create: `Sources/AnglesiteContainer/BundledImage.swift`
- Create: `Sources/AnglesiteContainer/ContainerizationControl.swift`
- Delete: `Sources/AnglesiteContainer/Placeholder.swift`
- Test (local-only, env-gated): `Tests/AnglesiteContainerLocalTests/ContainerizationControlTests.swift` — see Step 5.

**Interfaces:**
- Consumes: `LocalContainerControl`, `LocalContainerSession`, `LocalContainerError`, `VsockTCPProxy`, `VsockDialer` (Phase 1).
- Produces: `public struct ContainerizationControl: LocalContainerControl` with `public init(imageLayoutURL: URL = BundledImage.layoutURL)`.
- Produces: `public enum BundledImage { public static var layoutURL: URL }` resolving `Resources/container-image` via `Bundle.module`.

> The exact `apple/containerization` API names (`ImageStore`, `LinuxContainer`, `LocalOCILayoutClient`, `dialVsock`, `VZNATNetworkDeviceAttachment`) must be confirmed against the installed package version while implementing — pin the version in `Package.resolved` and adapt. The structure below is fixed; the symbol spellings may need minor adjustment. Spec §6.4 flags `UnixSocketRelay`/`VsockListener` as reference-only.

- [ ] **Step 1: Write `BundledImage`**

Create `Sources/AnglesiteContainer/BundledImage.swift`:

```swift
import Foundation

/// Resolves the vendored arm64 OCI layout that ships inside AnglesiteContainer's resource bundle
/// (`Resources/container-image/`, copied in via Package.swift). A Settings override
/// (`ANGLESITE_CONTAINER_IMAGE`) lets a developer point at a freshly-built layout without
/// rebuilding the app — mirrors TemplateRuntime's dev override.
public enum BundledImage {
    public static var layoutURL: URL {
        if let override = ProcessInfo.processInfo.environment["ANGLESITE_CONTAINER_IMAGE"] {
            return URL(fileURLWithPath: override)
        }
        guard let url = Bundle.module.url(forResource: "container-image", withExtension: nil) else {
            fatalError("AnglesiteContainer resource bundle is missing container-image/")
        }
        return url
    }
}
```

- [ ] **Step 2: Write `ContainerizationControl`**

Create `Sources/AnglesiteContainer/ContainerizationControl.swift`:

```swift
import Foundation
import AnglesiteCore
import Containerization

/// `LocalContainerControl` over Apple Containerization. Imports the bundled OCI layout into the
/// on-disk image store, boots a Linux VM with NAT (outbound) + vsock (inbound), clones the site's
/// `Source/` repo into the guest, starts `astro dev` + the Node MCP sidecar + the vsock bridge,
/// and exposes both via host-side `VsockTCPProxy` instances. CI never compiles this file.
public struct ContainerizationControl: LocalContainerControl {
    private let imageLayoutURL: URL

    // One live container + its two proxies per siteID, kept in an actor box so start/stop are safe.
    private let live = LiveContainers()

    public init(imageLayoutURL: URL = BundledImage.layoutURL) {
        self.imageLayoutURL = imageLayoutURL
    }

    public func start(siteID: String, sourceRepo: URL, ref: String) async throws -> LocalContainerSession {
        // 1. Import the bundled OCI layout into the local ImageStore (idempotent; first run only).
        let image: Image
        do {
            image = try await ImageStore.shared.importIfNeeded(ociLayout: imageLayoutURL, reference: "anglesite-dev:latest")
        } catch {
            throw LocalContainerError.imageUnavailable("\(error)")
        }

        // 2. Boot the container: NAT outbound + auto vsock device. Apple Silicon only.
        let container: LinuxContainer
        do {
            container = try await LinuxContainer(image: image, networking: .nat)
            try await container.start()
        } catch {
            throw LocalContainerError.bootFailed("\(error)")
        }

        // 3. Hydrate from the repo: clone the host file:// repo into /workspace, then check out ref.
        //    Two steps because `--branch` rejects "HEAD" and bare SHAs; `git checkout` accepts both.
        do {
            try await container.exec(["git", "clone", sourceRepo.path, "/workspace/site"])
            try await container.exec(["git", "-C", "/workspace/site", "checkout", ref])
        } catch {
            try? await container.stop()
            throw LocalContainerError.cloneFailed("\(error)")
        }

        // 4. Start astro dev (TCP 4321), the MCP sidecar (TCP 4399), and the vsock bridge.
        try await container.execDetached(["sh", "-lc",
            "cd /workspace/site && npm install --no-audit --no-fund && npx astro dev --port 4321 --host 127.0.0.1 &"])
        try await container.execDetached(["sh", "-lc",
            "node /usr/local/lib/anglesite-mcp/index.mjs --port 4399 &"])
        try await container.execDetached(["/usr/local/bin/vsock-bridge", "4321:4321", "4399:4399"])

        // 5. Expose: a host-side vsock→TCP proxy per port.
        let dial: VsockDialer = { port in try container.dialVsock(port: port) }
        let previewProxy = VsockTCPProxy(guestPort: 4321, dial: dial)
        let mcpProxy = VsockTCPProxy(guestPort: 4399, dial: dial)
        let previewURL = try await previewProxy.start()
        let mcpBase = try await mcpProxy.start()
        let mcpURL = mcpBase.appendingPathComponent("mcp")

        await live.store(siteID: siteID, container: container, proxies: [previewProxy, mcpProxy])
        return LocalContainerSession(previewURL: previewURL, mcpURL: mcpURL)
    }

    public func stop(siteID: String) async throws {
        await live.teardown(siteID: siteID)
    }
}

/// Actor box holding the live container + proxies keyed by siteID.
actor LiveContainers {
    private var containers: [String: LinuxContainer] = [:]
    private var proxies: [String: [VsockTCPProxy]] = [:]

    func store(siteID: String, container: LinuxContainer, proxies ps: [VsockTCPProxy]) {
        containers[siteID] = container
        proxies[siteID] = ps
    }

    func teardown(siteID: String) async {
        for p in proxies[siteID] ?? [] { await p.stop() }
        proxies[siteID] = nil
        if let c = containers[siteID] { try? await c.stop() }
        containers[siteID] = nil
    }
}
```

> `ImageStore.shared.importIfNeeded`, `LinuxContainer(image:networking:)`, `.exec`, `.execDetached`, and `.dialVsock` are the *intended* shapes — confirm/adjust to the pinned `containerization` version's real API during implementation. If `importIfNeeded` isn't a library method, implement it via `ImageStore` + `LocalOCILayoutClient` per spec §2.4 step 1.

- [ ] **Step 3: Delete the placeholder**

```bash
git rm Sources/AnglesiteContainer/Placeholder.swift
```

- [ ] **Step 4: Build the target locally**

Run: `swift build --target AnglesiteContainer 2>&1 | tail -30`
Expected: compiles against the real `containerization` API. Fix any symbol-name drift flagged by the compiler (see notes above).

- [ ] **Step 5: Add a local-only, env-gated integration test**

Create `Tests/AnglesiteContainerLocalTests/ContainerizationControlTests.swift`. This target is added to `Package.swift` as a test target depending on `AnglesiteContainer`, and **every test guards on the `ANGLESITE_CONTAINER_E2E` env var** (like the existing MCP e2e gating) so it is skipped unless explicitly run on an entitled machine:

```swift
import Testing
import Foundation
@testable import AnglesiteContainer
import AnglesiteCore

struct ContainerizationControlTests {
    private var enabled: Bool { ProcessInfo.processInfo.environment["ANGLESITE_CONTAINER_E2E"] == "1" }

    @Test("boots a container, hydrates a repo, and serves a loadable preview URL")
    func bootsAndServes() async throws {
        try #require(enabled, "set ANGLESITE_CONTAINER_E2E=1 on an entitled Apple-Silicon Mac")
        // Arrange a throwaway git repo on disk with a minimal Astro site, then:
        let control = ContainerizationControl()
        let repo = try makeThrowawayAstroRepo()        // helper: git init + minimal site + commit
        let session = try await control.start(siteID: "e2e", sourceRepo: repo, ref: "HEAD")
        defer { Task { try? await control.stop(siteID: "e2e") } }
        // The preview URL must serve HTTP 200 within the ready window.
        let (_, resp) = try await URLSession.shared.data(from: session.previewURL)
        #expect((resp as? HTTPURLResponse)?.statusCode == 200)
    }
}
```

> Add this test target to `Package.swift` with `.testTarget(name: "AnglesiteContainerLocalTests", dependencies: ["AnglesiteContainer", "AnglesiteCore"], path: "Tests/AnglesiteContainerLocalTests")`. Because it depends on `AnglesiteContainer`, a bare `swift test` on CI WOULD try to compile it — so guard the whole target behind the same `#if` the team uses for entitlement-only code, OR (preferred) keep it out of the default `packageTargets` array and append it only when an env var like `ANGLESITE_CONTAINER_TESTS=1` is set, mirroring the `#if compiler(>=6.4)` conditional already used for `AnglesiteIntentsTests`. Implement the conditional-append so CI's `swift test` never sees it.

- [ ] **Step 6: Run the gated test locally on your entitled machine**

Run: `ANGLESITE_CONTAINER_TESTS=1 ANGLESITE_CONTAINER_E2E=1 swift test --filter ContainerizationControlTests 2>&1 | tail -20`
Expected: PASS (boots a real container, fetches the preview). Requires the vendored image (Task 6) + the entitlement.

- [ ] **Step 7: Confirm CI's default flow still excludes it**

Run: `swift test --filter LocalContainerSupportTests 2>&1 | tail -5`
Expected: PASS; `AnglesiteContainer` and `AnglesiteContainerLocalTests` are NOT compiled.

- [ ] **Step 8: Commit**

```bash
git add Sources/AnglesiteContainer Tests/AnglesiteContainerLocalTests Package.swift
git commit -m "feat(#69): ContainerizationControl conformer + bundled-image loader

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Phase 3 — Wiring & selection

### Task 8: Link `AnglesiteContainer` into the DevID target + entitlement

**Files:**
- Modify: `project.yml`
- Modify: the DevID `Anglesite` target's entitlements file (path discovered from `project.yml` / `Resources/*.entitlements`)

**Interfaces:** none (build config only).

- [ ] **Step 1: Add the product dependency to the DevID target in `project.yml`**

Under `targets: Anglesite: dependencies:` (the DevID target, around `project.yml:98`), add:

```yaml
      - package: Anglesite
        product: AnglesiteContainer
```

Do NOT add it under `AnglesiteMAS` (around `project.yml:185`) — MAS linking is deferred (spec §3).

- [ ] **Step 2: Add the virtualization entitlement to the DevID entitlements**

In the DevID `Anglesite` target's entitlements plist, add:

```xml
<key>com.apple.security.virtualization</key>
<true/>
```

- [ ] **Step 3: Regenerate the Xcode project and build the DevID app**

Run: `xcodegen generate && xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED with `AnglesiteContainer` linked. (Run with `ANGLESITE_PLUGIN_SRC` set per CLAUDE.md if in a worktree.)

- [ ] **Step 4: Commit**

```bash
git add project.yml Resources/*.entitlements
git commit -m "build(#69): link AnglesiteContainer into DevID + virtualization entitlement

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: Capability-driven runtime selection in `PreviewModel`

**Files:**
- Modify: `Sources/AnglesiteApp/PreviewModel.swift:40`
- Create: `Sources/AnglesiteContainer/VirtualizationEntitlement.swift` (the real entitlement probe)

**Interfaces:**
- Consumes: `LocalContainerSupport.isAvailable(hasVirtualizationEntitlement:)`, `LocalContainerSiteRuntime`, `ContainerizationControl`, `LocalSiteRuntime` (existing fallback).
- Produces: `public enum VirtualizationEntitlement { public static var isPresent: Bool }`.

- [ ] **Step 1: Write the entitlement probe (in AnglesiteContainer, where Security/VZ are available)**

Create `Sources/AnglesiteContainer/VirtualizationEntitlement.swift`:

```swift
import Foundation
import Security

/// Reads `com.apple.security.virtualization` from this process's signed entitlements. Returns false
/// for unsigned/un-entitled builds (every CI build and any pre-approval distribution). Lives here
/// because AnglesiteContainer is the only target that should ever consult it.
public enum VirtualizationEntitlement {
    public static var isPresent: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.virtualization" as CFString, nil)
        return (value as? Bool) == true
    }
}
```

- [ ] **Step 2: Update the runtime factory at `PreviewModel.swift:40`**

Replace:

```swift
        let runtime = runtime ?? LocalSiteRuntime(contentGraph: contentGraph)
```

with a capability-driven factory:

```swift
        let runtime = runtime ?? Self.makeRuntime(sourceRepo: sourceRepo, contentGraph: contentGraph)
```

and add the factory method to `PreviewModel`:

```swift
    /// Pick the runtime by capability (no feature flag): a local Apple-Containerization VM when the
    /// build is entitled on Apple-Silicon macOS 26+, else today's host-subprocess runtime.
    static func makeRuntime(sourceRepo: URL, contentGraph: SiteContentGraph?) -> any SiteRuntime {
        if LocalContainerSupport.isAvailable(hasVirtualizationEntitlement: VirtualizationEntitlement.isPresent) {
            return LocalContainerSiteRuntime(
                sourceRepo: sourceRepo,
                ref: "HEAD",
                control: ContainerizationControl(),
                mcpClient: MCPClient())
        }
        return LocalSiteRuntime(contentGraph: contentGraph)
    }
```

> `import AnglesiteContainer` at the top of `PreviewModel.swift`. `sourceRepo` is the open package's `Source/` directory — thread it from the existing `SiteWindow`/package context already available to `PreviewModel` (it already knows the site directory it passes to `runtime.start`).

- [ ] **Step 3: Regenerate + build the DevID app**

Run: `xcodegen generate && xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Confirm the core test suite is still green**

Run: `swift test 2>&1 | tail -10`
Expected: all pass (the app-target change doesn't touch `swift test`).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/PreviewModel.swift Sources/AnglesiteContainer/VirtualizationEntitlement.swift
git commit -m "feat(#69): capability-driven runtime selection (container vs subprocess)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: Local end-to-end verification (author, entitled machine)

**Files:** none (manual verification + notes).

**Interfaces:** none.

- [ ] **Step 1: Vendor the image (if not already)**

Run: `./scripts/vendor-container-image.sh`
Expected: `Resources/container-image/` populated.

- [ ] **Step 2: Build + run the DevID app**

Run: `xcodegen generate && open Anglesite.xcodeproj` then ⌘R, OR `xcodebuild ... build` and launch the `.app`.

- [ ] **Step 3: Open a site and confirm the container path is selected**

Open a `.anglesite` package. In the Debug pane, confirm the preview loads from `http://127.0.0.1:<port>` (a proxy port), the container booted, and the site rendered. Confirm an `apply_edit` round-trips through the in-container MCP endpoint (edit overlay → change appears in preview).

- [ ] **Step 4: Confirm graceful fallback on an un-entitled build**

Temporarily build without the entitlement (or on the MAS scheme) and confirm `LocalContainerSupport.isAvailable` returns false and the app falls back to `LocalSiteRuntime` with no crash.

- [ ] **Step 5: Confirm stop/idle lifecycle**

Close the site window; confirm in Activity Monitor / the Debug pane that the VM + proxies tear down (no orphaned `com.apple.Virtualization` processes).

- [ ] **Step 6: Record results**

Note wall-clock cold-boot time and per-container memory (the numbers spec §6.2 / the #60 notes left unmeasured) in a short comment on #69 for the bundle-size/hybrid decision.

---

## Self-Review

**Spec coverage:**
- §2.1 seam → Task 1. §2.1 actor → Task 2. §2.2 proxy → Task 3. §2.3 capability gate → Task 4.
- §2.4 conformer → Task 7. §2.5 guest image/bridge → Task 6. §2.6 selection → Task 9.
- §3 packaging (target/product/dep) → Task 5; image-as-resource → Tasks 5+6; iOS exclusion → Task 5 (no iOS link); DevID-only + entitlement → Task 8; gitignore → Task 6.
- §4 lifecycle (stop/idle) → Tasks 2 (stop) + 7 (teardown) + 10 (verify).
- §5 testing → Tasks 2/3/4 (CI) + 7/10 (local). §6 risks → flagged inline (API drift Task 7, bundle size Task 10 Step 6, hydration mechanism Task 7).

**Placeholder scan:** No "TBD/TODO" left. The two genuine unknowns (exact `containerization` symbol names; the host-`file://`-into-guest clone mechanism) are explicitly called out as confirm-during-implementation with a concrete default, not hidden.

**Type consistency:** `LocalContainerControl.start(siteID:sourceRepo:ref:)` is consumed identically in Tasks 2 (actor passes `siteDirectory` as `sourceRepo`, `ref` from init), 7 (conformer), and the fakes (Task 1). `VsockDialer = (UInt32) async throws -> FileHandle` matches in Task 3 (def), Task 7 (real dial). `LocalContainerSession { previewURL, mcpURL }` consistent across Tasks 1/2/7. `LocalContainerSupport.isAvailable(hasVirtualizationEntitlement:)` consistent across Tasks 4/9.

---

## Execution Handoff

Two execution options:

1. **Subagent-Driven (recommended)** — a fresh subagent per task, with review between tasks. Note: Tasks 5–7 and 10 require an Apple-Silicon machine with Docker + the virtualization entitlement, so they can't run on CI or a generic agent box — they're author-run. Phase 1 (Tasks 1–4) is fully CI-testable and ideal for subagent execution.
2. **Inline Execution** — execute in this session with checkpoints.
