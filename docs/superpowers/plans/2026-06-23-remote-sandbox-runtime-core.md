# RemoteSandboxSiteRuntime — AnglesiteCore layer — Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Swift `AnglesiteCore` layer of the iOS remote runtime — a `RemoteSandboxSiteRuntime` that conforms to the existing `SiteRuntime` protocol by driving a Cloudflare Sandbox through a typed control client, minting a per-session token, and pointing its `MCPClient` at the in-container MCP tunnel.

**Architecture:** Mirror `LocalSiteRuntime`'s actor state machine (`current`/`observers`/`generation`/`setState`), but back it with a `SandboxControlClient` (protocol seam — faked in tests) instead of `AstroDevServer`+`ProcessSupervisor`. The runtime mints a `SessionToken`, asks the control client to `start` a session (returning preview + MCP tunnel URLs), connects its `MCPClient` over HTTP to the MCP URL, and settles to `.ready`/`.failed`.

**Tech Stack:** Swift 6.4, Swift Testing (`@Test`), `AnglesiteCore` SPM target, CryptoKit (token), `URLProtocol` stub (HTTP client tests). No Cloudflare in unit tests.

## Global Constraints

- Targets macOS 27+ / Swift 6.4; the `AnglesiteCore` package is **not** compiled with `ANGLESITE_MAS`, so no `#if ANGLESITE_MAS` guards here.
- Process spawning is centralized in `ProcessSupervisor` — this layer spawns **nothing**; it only makes HTTPS calls and owns an `MCPClient`.
- The session token is a secret: **never** log its value (consistent with `KeychainStore`).
- `SiteRuntime` is fixed (#64, closed): `start(siteID:siteDirectory:) async`, `stop() async`, `observe() -> AsyncStream<SiteRuntimeState>`, `var mcpClient: MCPClient { get }`. Do not change it.
- The remote path has no local files. `siteDirectory` (a `SiteRuntime` parameter) is **unused** on this runtime; the git remote + ref are supplied at `init` (the iOS onboarding constructs the runtime). Document this at the call site.
- Tests live in `Tests/AnglesiteCoreTests/`, use Swift Testing, and must pass under `swift test --package-path .`.

---

### Task 1: `SessionToken`

**Files:**
- Create: `Sources/AnglesiteCore/SessionToken.swift`
- Test: `Tests/AnglesiteCoreTests/SessionTokenTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `public struct SessionToken: Sendable, Equatable { public let value: String; public init(value: String); public static func mint() -> SessionToken }` — `value` is 32 random bytes hex-encoded (64 chars); `description` is redacted.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import AnglesiteCore

struct SessionTokenTests {
    @Test("mint produces a 64-char hex string")
    func mintFormat() {
        let t = SessionToken.mint()
        #expect(t.value.count == 64)
        #expect(t.value.allSatisfy { $0.isHexDigit })
    }

    @Test("two mints differ")
    func mintUnique() {
        #expect(SessionToken.mint() != SessionToken.mint())
    }

    @Test("description never leaks the value")
    func redactedDescription() {
        let t = SessionToken(value: "deadbeef")
        #expect(!"\(t)".contains("deadbeef"))
        #expect("\(t)".contains("SessionToken"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter SessionTokenTests`
Expected: FAIL — `cannot find 'SessionToken' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation
import CryptoKit

/// A per-session bearer secret minted by the app and validated in-container (auth-proxy + MCP
/// sidecar). Opaque; symmetric compare. The value is a secret — never log it (see `KeychainStore`).
public struct SessionToken: Sendable, Equatable, CustomStringConvertible {
    public let value: String

    public init(value: String) { self.value = value }

    /// 32 cryptographically-random bytes, hex-encoded (64 chars).
    public static func mint() -> SessionToken {
        let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) }
        return SessionToken(value: bytes.map { String(format: "%02x", $0) }.joined())
    }

    /// Redacted — keeps the secret out of logs and crash dumps.
    public var description: String { "SessionToken(redacted)" }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter SessionTokenTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SessionToken.swift Tests/AnglesiteCoreTests/SessionTokenTests.swift
git commit -m "feat(#67): SessionToken — per-session bearer secret"
```

---

### Task 2: `SandboxControlClient` seam + fake

**Files:**
- Create: `Sources/AnglesiteCore/SandboxControlClient.swift`
- Create: `Tests/AnglesiteCoreTests/FakeSandboxControlClient.swift`
- Test: `Tests/AnglesiteCoreTests/SandboxControlClientTests.swift`

**Interfaces:**
- Consumes: `SessionToken` (Task 1).
- Produces:
  - `public struct SandboxSession: Sendable, Equatable { public let previewURL: URL; public let mcpURL: URL }`
  - `public enum SandboxControlError: Error, Equatable { case notProvisioned; case unauthorized; case unreachable(String); case startFailed(String) }`
  - `public protocol SandboxControlClient: Sendable { func start(siteID: String, gitRemote: URL, gitRef: String, token: SessionToken) async throws -> SandboxSession; func stop(siteID: String) async throws }`
  - Test helper `actor FakeSandboxControlClient: SandboxControlClient` with `var startResult: Result<SandboxSession, SandboxControlError>`, `private(set) var stopped: [String]`, `private(set) var startedToken: SessionToken?`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import AnglesiteCore

struct SandboxControlClientTests {
    @Test("fake returns the configured session and records the token")
    func fakeStart() async throws {
        let session = SandboxSession(
            previewURL: URL(string: "https://preview.trycloudflare.com")!,
            mcpURL: URL(string: "https://mcp.trycloudflare.com/mcp")!)
        let fake = FakeSandboxControlClient(startResult: .success(session))
        let token = SessionToken.mint()
        let got = try await fake.start(
            siteID: "site-1",
            gitRemote: URL(string: "https://example.com/repo.git")!,
            gitRef: "main",
            token: token)
        #expect(got == session)
        #expect(await fake.startedToken == token)
    }

    @Test("fake propagates the configured error")
    func fakeStartError() async {
        let fake = FakeSandboxControlClient(startResult: .failure(.notProvisioned))
        await #expect(throws: SandboxControlError.notProvisioned) {
            _ = try await fake.start(
                siteID: "s", gitRemote: URL(string: "https://x/r.git")!,
                gitRef: "main", token: .mint())
        }
    }

    @Test("fake records stop calls")
    func fakeStop() async throws {
        let fake = FakeSandboxControlClient(
            startResult: .success(SandboxSession(
                previewURL: URL(string: "https://p")!, mcpURL: URL(string: "https://m/mcp")!)))
        try await fake.stop(siteID: "site-1")
        #expect(await fake.stopped == ["site-1"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter SandboxControlClientTests`
Expected: FAIL — `cannot find 'SandboxSession'` / `FakeSandboxControlClient`.

- [ ] **Step 3: Write the seam**

```swift
// Sources/AnglesiteCore/SandboxControlClient.swift
import Foundation

/// The two tunnel URLs a started remote session exposes: the preview (auth-proxy port) and the
/// in-container MCP server. Both are `*.trycloudflare.com` quick-tunnel URLs.
public struct SandboxSession: Sendable, Equatable {
    public let previewURL: URL
    public let mcpURL: URL
    public init(previewURL: URL, mcpURL: URL) {
        self.previewURL = previewURL
        self.mcpURL = mcpURL
    }
}

public enum SandboxControlError: Error, Equatable {
    case notProvisioned          // no Control Worker / token on file → route to onboarding
    case unauthorized            // token rejected by the Worker
    case unreachable(String)     // network / DNS
    case startFailed(String)     // Worker reported a boot/clone/hydrate failure
}

/// Typed wrapper over the user's Control Worker RPCs. The HTTPS impl (`HTTPSandboxControlClient`)
/// is one conformer; tests use `FakeSandboxControlClient`. No Cloudflare types leak across this seam.
public protocol SandboxControlClient: Sendable {
    /// Boot (or resume) the sandbox for `siteID`, clone `gitRemote` at `gitRef`, start the in-guest
    /// processes with `token` in their environment, and return the two tunnel URLs.
    func start(siteID: String, gitRemote: URL, gitRef: String, token: SessionToken) async throws -> SandboxSession
    /// Stop the session (drop tunnels, let the sandbox sleep).
    func stop(siteID: String) async throws
}
```

```swift
// Tests/AnglesiteCoreTests/FakeSandboxControlClient.swift
import Foundation
@testable import AnglesiteCore

actor FakeSandboxControlClient: SandboxControlClient {
    var startResult: Result<SandboxSession, SandboxControlError>
    private(set) var stopped: [String] = []
    private(set) var startedToken: SessionToken?

    init(startResult: Result<SandboxSession, SandboxControlError>) {
        self.startResult = startResult
    }

    func start(siteID: String, gitRemote: URL, gitRef: String, token: SessionToken) async throws -> SandboxSession {
        startedToken = token
        return try startResult.get()
    }

    func stop(siteID: String) async throws { stopped.append(siteID) }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter SandboxControlClientTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SandboxControlClient.swift Tests/AnglesiteCoreTests/FakeSandboxControlClient.swift Tests/AnglesiteCoreTests/SandboxControlClientTests.swift
git commit -m "feat(#66): SandboxControlClient seam + test fake"
```

---

### Task 3: `RemoteSandboxSiteRuntime`

**Files:**
- Create: `Sources/AnglesiteCore/RemoteSandboxSiteRuntime.swift`
- Test: `Tests/AnglesiteCoreTests/RemoteSandboxSiteRuntimeTests.swift`

**Interfaces:**
- Consumes: `SiteRuntime`, `SiteRuntimeState`, `MCPClient` (existing); `SessionToken` (Task 1); `SandboxControlClient`, `SandboxSession`, `SandboxControlError`, `FakeSandboxControlClient` (Task 2).
- Produces: `public actor RemoteSandboxSiteRuntime: SiteRuntime` with
  `public init(gitRemote: URL, gitRef: String, control: any SandboxControlClient, mcpClient: MCPClient, mintToken: @Sendable () -> SessionToken = SessionToken.mint, connect: @Sendable (MCPClient, URL) async throws -> Void = { c, u in try await c.connect(httpEndpoint: u) })`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import AnglesiteCore

struct RemoteSandboxSiteRuntimeTests {
    private func makeRuntime(
        _ result: Result<SandboxSession, SandboxControlError>,
        connect: @escaping @Sendable (MCPClient, URL) async throws -> Void = { _, _ in }
    ) -> (RemoteSandboxSiteRuntime, FakeSandboxControlClient) {
        let fake = FakeSandboxControlClient(startResult: result)
        let mcp = MCPClient(supervisor: ProcessSupervisor(), logCenter: LogCenter())
        let rt = RemoteSandboxSiteRuntime(
            gitRemote: URL(string: "https://example.com/repo.git")!,
            gitRef: "main",
            control: fake,
            mcpClient: mcp,
            mintToken: { SessionToken(value: "fixedtoken") },
            connect: connect)
        return (rt, fake)
    }

    private static let ok = SandboxSession(
        previewURL: URL(string: "https://preview.trycloudflare.com")!,
        mcpURL: URL(string: "https://mcp.trycloudflare.com/mcp")!)

    @Test("start settles to .ready with the preview URL")
    func startReady() async {
        let (rt, _) = makeRuntime(.success(Self.ok))
        await rt.start(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/unused"))
        #expect(await rt.state == .ready(siteID: "s1", url: Self.ok.previewURL))
    }

    @Test("start connects the MCP client to the mcp tunnel URL")
    func startConnectsMCP() async {
        let box = ConnectedURLBox()
        let (rt, _) = makeRuntime(.success(Self.ok), connect: { _, url in await box.set(url) })
        await rt.start(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/unused"))
        #expect(await box.url == Self.ok.mcpURL)
    }

    @Test("control failure settles to .failed")
    func startFailed() async {
        let (rt, _) = makeRuntime(.failure(.startFailed("clone failed")))
        await rt.start(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/unused"))
        if case .failed(let id, let msg) = await rt.state {
            #expect(id == "s1")
            #expect(msg.contains("clone failed"))
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

    @Test("observe yields starting then ready")
    func observeTransitions() async {
        let (rt, _) = makeRuntime(.success(Self.ok))
        let stream = await rt.observe()
        await rt.start(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/unused"))
        var seen: [SiteRuntimeState] = []
        for await s in stream { seen.append(s); if case .ready = s { break } }
        #expect(seen.contains(.starting(siteID: "s1")))
        #expect(seen.last == .ready(siteID: "s1", url: Self.ok.previewURL))
    }
}

/// Test-only sink so the injected `connect` closure can record the URL it was handed.
actor ConnectedURLBox { private(set) var url: URL?; func set(_ u: URL) { url = u } }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter RemoteSandboxSiteRuntimeTests`
Expected: FAIL — `cannot find 'RemoteSandboxSiteRuntime' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// `SiteRuntime` over a Cloudflare Sandbox (iOS-only; see design 2026-06-23). Mirrors
/// `LocalSiteRuntime`'s state machine but drives a `SandboxControlClient` instead of a local
/// subprocess: mint a token, start the session, connect the MCP client to the returned MCP tunnel,
/// settle to `.ready`/`.failed`. Spawns nothing locally.
public actor RemoteSandboxSiteRuntime: SiteRuntime {
    private let gitRemote: URL
    private let gitRef: String
    private let control: any SandboxControlClient
    public let mcpClient: MCPClient
    private let mintToken: @Sendable () -> SessionToken
    private let connect: @Sendable (MCPClient, URL) async throws -> Void

    private var current: SiteRuntimeState = .idle
    private var observers: [UUID: AsyncStream<SiteRuntimeState>.Continuation] = [:]
    private var generation = 0
    private var activeSiteID: String?

    public init(
        gitRemote: URL,
        gitRef: String,
        control: any SandboxControlClient,
        mcpClient: MCPClient,
        mintToken: @escaping @Sendable () -> SessionToken = SessionToken.mint,
        connect: @escaping @Sendable (MCPClient, URL) async throws -> Void = { c, u in try await c.connect(httpEndpoint: u) }
    ) {
        self.gitRemote = gitRemote
        self.gitRef = gitRef
        self.control = control
        self.mcpClient = mcpClient
        self.mintToken = mintToken
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

    /// `siteDirectory` is unused on the remote path (no local files on iOS); the git remote + ref
    /// come from `init`. Tears down any previous session, then settles to `.ready`/`.failed`.
    public func start(siteID: String, siteDirectory: URL) async {
        await teardown()
        generation += 1
        let gen = generation
        setState(.starting(siteID: siteID))
        do {
            let session = try await control.start(
                siteID: siteID, gitRemote: gitRemote, gitRef: gitRef, token: mintToken())
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
        current = s
        for c in observers.values { c.yield(s) }
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    static func friendlyMessage(for error: Error) -> String {
        switch error {
        case SandboxControlError.notProvisioned: return "Connect a Cloudflare account to preview this site."
        case SandboxControlError.unauthorized:   return "Cloudflare rejected the session. Reconnect your account."
        case SandboxControlError.unreachable(let m): return "Couldn't reach Cloudflare: \(m)"
        case SandboxControlError.startFailed(let m): return "Couldn't start the remote preview: \(m)"
        default: return "Couldn't start the remote preview: \(error)"
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter RemoteSandboxSiteRuntimeTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/RemoteSandboxSiteRuntime.swift Tests/AnglesiteCoreTests/RemoteSandboxSiteRuntimeTests.swift
git commit -m "feat(#66): RemoteSandboxSiteRuntime over SandboxControlClient"
```

---

### Task 4: `HTTPSandboxControlClient` (real Worker calls)

**Files:**
- Create: `Sources/AnglesiteCore/HTTPSandboxControlClient.swift`
- Test: `Tests/AnglesiteCoreTests/HTTPSandboxControlClientTests.swift`

**Interfaces:**
- Consumes: `SandboxControlClient`, `SandboxSession`, `SandboxControlError`, `SessionToken`.
- Produces: `public struct HTTPSandboxControlClient: SandboxControlClient` with
  `public init(workerBaseURL: URL, apiToken: String, urlSession: URLSession = .shared)`.
  Wire protocol: `POST {base}/start` JSON `{siteID,gitRemote,gitRef,token}` → 200 `{previewURL,mcpURL}`; `POST {base}/stop` JSON `{siteID}` → 200; `Authorization: Bearer {apiToken}`; 401 → `.unauthorized`; non-2xx → `.startFailed(body)`; transport error → `.unreachable(desc)`.

- [ ] **Step 1: Write the failing test (URLProtocol stub)**

```swift
import Testing
import Foundation
@testable import AnglesiteCore

struct HTTPSandboxControlClientTests {
    private func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    @Test("start posts and parses the two URLs")
    func startParses() async throws {
        StubURLProtocol.handler = { req in
            #expect(req.url?.path == "/start")
            #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer api-tok")
            let body = #"{"previewURL":"https://p.trycloudflare.com","mcpURL":"https://m.trycloudflare.com/mcp"}"#
            return (200, Data(body.utf8))
        }
        let client = HTTPSandboxControlClient(
            workerBaseURL: URL(string: "https://worker.example.workers.dev")!,
            apiToken: "api-tok", urlSession: session())
        let s = try await client.start(
            siteID: "s1", gitRemote: URL(string: "https://x/r.git")!,
            gitRef: "main", token: SessionToken(value: "t"))
        #expect(s.previewURL == URL(string: "https://p.trycloudflare.com")!)
        #expect(s.mcpURL == URL(string: "https://m.trycloudflare.com/mcp")!)
    }

    @Test("401 maps to .unauthorized")
    func unauthorized() async {
        StubURLProtocol.handler = { _ in (401, Data()) }
        let client = HTTPSandboxControlClient(
            workerBaseURL: URL(string: "https://w.workers.dev")!, apiToken: "x", urlSession: session())
        await #expect(throws: SandboxControlError.unauthorized) {
            _ = try await client.start(
                siteID: "s", gitRemote: URL(string: "https://x/r.git")!, gitRef: "main", token: SessionToken(value: "t"))
        }
    }
}

/// Minimal URLProtocol stub for offline HTTP-client tests.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        let (status, data) = handler(request)
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter HTTPSandboxControlClientTests`
Expected: FAIL — `cannot find 'HTTPSandboxControlClient' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// `SandboxControlClient` that calls the user's deployed Control Worker over HTTPS. No Cloudflare
/// SDK — plain JSON. Used by the iOS app once onboarding has stored the Worker URL + API token.
public struct HTTPSandboxControlClient: SandboxControlClient {
    private let workerBaseURL: URL
    private let apiToken: String
    private let urlSession: URLSession

    public init(workerBaseURL: URL, apiToken: String, urlSession: URLSession = .shared) {
        self.workerBaseURL = workerBaseURL
        self.apiToken = apiToken
        self.urlSession = urlSession
    }

    private struct StartBody: Encodable { let siteID, gitRemote, gitRef, token: String }
    private struct StartResponse: Decodable { let previewURL: URL; let mcpURL: URL }
    private struct StopBody: Encodable { let siteID: String }

    public func start(siteID: String, gitRemote: URL, gitRef: String, token: SessionToken) async throws -> SandboxSession {
        let body = StartBody(siteID: siteID, gitRemote: gitRemote.absoluteString, gitRef: gitRef, token: token.value)
        let data = try await post("start", body: body)
        do {
            let r = try JSONDecoder().decode(StartResponse.self, from: data)
            return SandboxSession(previewURL: r.previewURL, mcpURL: r.mcpURL)
        } catch {
            throw SandboxControlError.startFailed("bad response: \(error)")
        }
    }

    public func stop(siteID: String) async throws {
        _ = try await post("stop", body: StopBody(siteID: siteID))
    }

    private func post(_ path: String, body: some Encodable) async throws -> Data {
        var req = URLRequest(url: workerBaseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        let data: Data, resp: URLResponse
        do { (data, resp) = try await urlSession.data(for: req) }
        catch { throw SandboxControlError.unreachable(error.localizedDescription) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200...299: return data
        case 401, 403: throw SandboxControlError.unauthorized
        default: throw SandboxControlError.startFailed(String(data: data, encoding: .utf8) ?? "HTTP \(code)")
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter HTTPSandboxControlClientTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Run the whole Core suite + commit**

Run: `swift test --package-path . --filter AnglesiteCoreTests`
Expected: PASS (existing suite + the new tests; 0 failures).

```bash
git add Sources/AnglesiteCore/HTTPSandboxControlClient.swift Tests/AnglesiteCoreTests/HTTPSandboxControlClientTests.swift
git commit -m "feat(#66): HTTPSandboxControlClient — Control Worker calls over HTTPS"
```

---

## Deferred sub-plans (separate specs/plans — NOT in this plan)

This plan delivers the unit-testable Swift core only. The other three subsystems each need their own plan (and #71 must exist before the iOS one can build):

1. **Control Worker + amd64 image + in-guest auth-proxy** (TS/Docker, template repo) — implements the `/start` `/stop` `/status` RPCs this client calls, `tunnels.get(8080)`+`tunnels.get(4399)`, and the cookie-validating auth-proxy in front of `astro dev`.
2. **MCP sidecar bearer check** (Node) — validate `Authorization: Bearer` on HTTP + WS upgrade.
3. **iOS onboarding + WebView** (blocked on #71) — Deploy-to-Cloudflare flow, Keychain (Worker URL + API token), `WKWebView` via `UIViewRepresentable`, session-token cookie injection.
4. **Live integration test** — boots a real sandbox; retires the #61 spike TBDs.

## Self-Review

- **Spec coverage (this subsystem):** SessionToken (Task 1) ✓ · control seam (Task 2) ✓ · runtime state machine + MCP connect + teardown (Task 3) ✓ · real Worker HTTPS calls (Task 4) ✓. Worker/image/auth-proxy, MCP-sidecar auth, iOS onboarding, live test → explicitly deferred above.
- **Placeholder scan:** none — every step has real test + impl code and exact `swift test --filter` commands.
- **Type consistency:** `SandboxSession{previewURL,mcpURL}`, `SandboxControlError` cases, and `SandboxControlClient.start(siteID:gitRemote:gitRef:token:)`/`stop(siteID:)` are used identically across Tasks 2–4 and the runtime. `RemoteSandboxSiteRuntime.init` matches its Interfaces block. `MCPClient.connect(httpEndpoint:)` matches `MCPClient.swift:161`. `SiteRuntime` conformance matches `SiteRuntime.swift` (`mcpClient` getter satisfied by `public let`).
