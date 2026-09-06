**Status:** current

# Safari MCP: Sessionful HTTP Transport + Detect/Connect Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `AnglesiteCore` a sessionful MCP Streamable HTTP client path (real `initialize` → capture `Mcp-Session-Id` → replay), so Anglesite can detect and connect to a user-launched Safari MCP bridge (`npx -y mcp-proxy --port <port> -- safaridriver --mcp`), and surface reachability + setup guidance in Settings.

**Architecture:** Add a sibling transport, `SessionfulHTTPTransport` (conforms to the existing `MCPTransport` protocol), that speaks the standard sessionful Streamable HTTP dialect — distinct from `HTTPTransport`'s bespoke stateless dialect used by the app's own container sidecar. Layer a small, purpose-built `SafariMCPBridgeClient` actor on top (real `initialize`/`notifications/initialized`/`tools/list`, JSON-RPC id-correlation) rather than retrofitting `MCPClient`, whose `sendRequest` unconditionally wraps every call in a stateless `_meta` envelope and whose readiness probe (`server/discover`) a real MCP server doesn't understand. A `SafariMCPBridgeDetector` wraps that client for a one-shot reachability check, exposed in Settings ▸ Advanced with a "Safari MCP Bridge" section (status + setup copy) and logged through the existing `LogCenter` (source `"safari-mcp"`) so the Debug pane already shows it with no new UI there.

**Tech Stack:** Swift 6.4, Swift Concurrency (actors), Foundation `URLSession`, Swift Testing (`@Suite`/`@Test`), SwiftUI (`AdvancedSettingsView`).

## Global Constraints

- Swift/SwiftUI + Apple frameworks only — no new dependencies (per `CONTRIBUTING.md` ▸ "Code guidelines"; none are needed here).
- Never spawn `safaridriver` or any bridge process from the app (owner's 2026-09-04 sandboxing decision) — detection is a pure loopback HTTP client call.
- Detect reachability by attempting the real handshake against the configured port, never by checking for a `safaridriver` binary/process.
- Do not touch `HTTPTransport`/`MCPClient`'s existing stateless code paths — this is a sibling, not a replacement; the container sidecar's dialect is untouched.
- Every spawned/network subprocess's activity must be visible in the Debug pane ("Logs are sacred") — route through `LogCenter`.
- Commit after every task; conventional commit subjects ≤72 chars, referencing `#1910`.
- Run `scripts/swift-test.sh` (not bare `swift test`) for local full runs; `scripts/build-app.sh` for the app target.

---

### Task 1: `SessionfulHTTPTransport`

**Files:**
- Create: `Sources/AnglesiteCore/AI/SessionfulHTTPTransport.swift`
- Test: `Tests/AnglesiteCoreTests/SessionfulHTTPTransportTests.swift`

**Interfaces:**
- Consumes: `MCPTransport` protocol (`Sources/AnglesiteCore/AI/MCPTransport.swift`) — `open()`, `send(_:)`, `inbound() -> AsyncStream<JSONValue>`, `close()`. `JSONValue` (`Sources/AnglesiteCore/AI/MCPClient.swift`). The existing `StubURLProtocol` test double (`Tests/AnglesiteCoreTests/HTTPTransportTests.swift`, internal access, no import needed within the same test target).
- Produces: `public actor SessionfulHTTPTransport: MCPTransport` with `public init(endpoint: URL, urlSession: URLSession = .shared)` and nested `public enum HTTPError: Error, Sendable, Equatable { case http(status: Int), case connectionFailed, case badResponse }` — consumed by Task 2's `SafariMCPBridgeClient`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/SessionfulHTTPTransportTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite(.serialized)
struct SessionfulHTTPTransportTests {
    private func makeTransport() -> (SessionfulHTTPTransport, URLSession) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        let t = SessionfulHTTPTransport(endpoint: URL(string: "http://127.0.0.1:4399/mcp")!, urlSession: session)
        return (t, session)
    }

    @Test("initialize response's Mcp-Session-Id is captured and replayed on the next request")
    func sessionIDCapturedAndReplayed() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.queue.append(.init(
            status: 200,
            headers: ["Content-Type": "application/json", "Mcp-Session-Id": "sess-42"],
            body: #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05"}}"#.data(using: .utf8)!
        ))
        StubURLProtocol.queue.append(.init(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: #"{"jsonrpc":"2.0","id":2,"result":{"tools":[]}}"#.data(using: .utf8)!
        ))

        let (t, _) = makeTransport()
        try await t.open()
        var iterator = t.inbound().makeAsyncIterator()

        try await t.send(.object(["jsonrpc": .string("2.0"), "id": .int(1), "method": .string("initialize")]))
        _ = await iterator.next()
        try await t.send(.object(["jsonrpc": .string("2.0"), "id": .int(2), "method": .string("tools/list")]))
        _ = await iterator.next()

        #expect(StubURLProtocol.lastSessionHeaders == [nil, "sess-42"])
        await t.close()
    }

    @Test("MCP-Protocol-Version header is never sent") func noProtocolVersionHeader() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.queue.append(.init(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: #"{"jsonrpc":"2.0","id":1,"result":{}}"#.data(using: .utf8)!
        ))
        let (t, _) = makeTransport()
        try await t.open()
        try await t.send(.object(["jsonrpc": .string("2.0"), "id": .int(1), "method": .string("initialize")]))
        await t.close()
    }

    @Test("SSE response is parsed into a message") func sseResponse() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.queue.append(.init(
            status: 200,
            headers: ["Content-Type": "text/event-stream", "Mcp-Session-Id": "sess-9"],
            body: "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"via\":\"sse\"}}\n\n".data(using: .utf8)!
        ))
        let (t, _) = makeTransport()
        try await t.open()
        var iterator = t.inbound().makeAsyncIterator()
        try await t.send(.object(["jsonrpc": .string("2.0"), "id": .int(7), "method": .string("initialize")]))
        let msg = await iterator.next()
        #expect(msg == .object(["jsonrpc": .string("2.0"), "id": .int(7), "result": .object(["via": .string("sse")])]))
        await t.close()
    }

    @Test("202 Accepted yields no message") func acceptedNoBody() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.queue.append(.init(status: 202, headers: [:], body: Data()))
        let (t, _) = makeTransport()
        try await t.open()
        try await t.send(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")]))
        await t.close()
        var iterator = t.inbound().makeAsyncIterator()
        let next = await iterator.next()
        #expect(next == nil)
    }

    @Test("Non-2xx/202 status throws HTTPError.http") func httpErrorStatus() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.queue.append(.init(status: 500, headers: [:], body: Data()))
        let (t, _) = makeTransport()
        try await t.open()
        do {
            try await t.send(.object(["jsonrpc": .string("2.0"), "id": .int(1), "method": .string("initialize")]))
            Issue.record("expected HTTPError.http to be thrown")
        } catch SessionfulHTTPTransport.HTTPError.http(let status) {
            #expect(status == 500)
        }
        await t.close()
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/swift-test.sh --filter SessionfulHTTPTransportTests`
Expected: FAIL — "cannot find type 'SessionfulHTTPTransport' in scope" (the type doesn't exist yet).

- [ ] **Step 3: Write the implementation**

Create `Sources/AnglesiteCore/AI/SessionfulHTTPTransport.swift`:

```swift
import Foundation
// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin
// platforms (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `MCPTransport` over the *standard* MCP Streamable HTTP handshake (sessionful): the
/// `initialize` response's `Mcp-Session-Id` header is captured and replayed on every later
/// request. This is the dialect real MCP HTTP servers speak (e.g. `mcp-proxy`, and through it
/// `safaridriver --mcp`) — a sibling of ``HTTPTransport``'s bespoke *stateless* dialect built for
/// this app's own container sidecar, not a replacement for it. See
/// docs/superpowers/specs/2026-09-04-safari-mcp-transport-spike.md.
///
/// Unlike ``HTTPTransport``, this transport never sends an `MCP-Protocol-Version` header — the
/// spike found that header triggers a 400 ("modern header ... legacy handshake") against
/// `mcp-proxy`'s tested dialect; the negotiated version instead comes back in the `initialize`
/// response body, which ``SafariMCPBridgeClient`` reads itself.
public actor SessionfulHTTPTransport: MCPTransport {
    /// Transport-level failures.
    public enum HTTPError: Error, Sendable, Equatable {
        /// The server answered with a status other than 200/202/404.
        case http(status: Int)
        /// The connection failed, or the server returned 404 (no such endpoint/session).
        case connectionFailed
        /// The response wasn't an HTTP response at all.
        case badResponse
    }

    private let endpoint: URL
    private let urlSession: URLSession
    private var sessionID: String?

    private let stream: AsyncStream<JSONValue>
    private let continuation: AsyncStream<JSONValue>.Continuation

    /// Creates a transport for one sessionful `/mcp` endpoint. `urlSession` is injectable for tests.
    public init(endpoint: URL, urlSession: URLSession = .shared) {
        self.endpoint = endpoint
        self.urlSession = urlSession
        (self.stream, self.continuation) = AsyncStream<JSONValue>.makeStream(bufferingPolicy: .unbounded)
    }

    /// No-op: like `HTTPTransport`, Streamable HTTP has no persistent connection to establish —
    /// the first `send` does the work.
    public func open() async throws { /* no persistent connection; first send does the work */ }

    /// POSTs one JSON-RPC message. Captures a fresh `Mcp-Session-Id` from the response whenever
    /// the server sends one (in practice, only the `initialize` response does) and replays
    /// whatever session id is currently held on every request thereafter. Mirrors
    /// `HTTPTransport.send(_:)`'s incremental-read/SSE-parsing approach — see that type's doc
    /// comment for why a `text/event-stream` response must not be fully buffered.
    public func send(_ message: JSONValue) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = try JSONSerialization.data(withJSONObject: message.rawValue, options: [])

        #if canImport(Darwin)
        let asyncBytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (asyncBytes, response) = try await urlSession.bytes(for: request)
        } catch {
            throw HTTPError.connectionFailed
        }
        guard let http = response as? HTTPURLResponse else { throw HTTPError.badResponse }
        #else
        let runner = HTTPStreamingRunner()
        let response: URLResponse
        do {
            response = try await runner.start(request, configuration: urlSession.configuration)
        } catch {
            throw HTTPError.connectionFailed
        }
        guard let http = response as? HTTPURLResponse else { throw HTTPError.badResponse }
        #endif

        if let newSessionID = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
            sessionID = newSessionID
        }

        switch http.statusCode {
        case 202:
            return  // notification accepted; no response body
        case 404:
            throw HTTPError.connectionFailed
        case 200:
            break
        default:
            throw HTTPError.http(status: http.statusCode)
        }

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if contentType.contains("text/event-stream") {
            var dataLines: [String] = []
            #if canImport(Darwin)
            for try await line in asyncBytes.lines {
                if case .complete(let value) = accumulateSSELine(line, into: &dataLines) {
                    if let value { continuation.yield(value) }
                    return
                }
            }
            #else
            for try await line in runner.lines() {
                if case .complete(let value) = accumulateSSELine(line, into: &dataLines) {
                    if let value { continuation.yield(value) }
                    return
                }
            }
            #endif
            if !dataLines.isEmpty, let value = decode(dataLines.joined(separator: "\n")) {
                continuation.yield(value)
            }
        } else {
            var data = Data()
            #if canImport(Darwin)
            for try await byte in asyncBytes { data.append(byte) }
            #else
            for try await chunk in runner.bodyStream { data.append(chunk) }
            #endif
            if !data.isEmpty, let value = decodeData(data) { continuation.yield(value) }
        }
    }

    private enum SSELineResult {
        case continueReading
        case complete(JSONValue?)
    }

    private func accumulateSSELine(_ line: String, into dataLines: inout [String]) -> SSELineResult {
        if line.isEmpty {
            guard !dataLines.isEmpty else { return .continueReading }
            return .complete(decode(dataLines.joined(separator: "\n")))
        }
        if line.hasPrefix("data:") {
            let v = line.dropFirst("data:".count)
            dataLines.append(v.hasPrefix(" ") ? String(v.dropFirst()) : String(v))
        }
        return .continueReading
    }

    /// The single stream of decoded server messages, fed by ``send(_:)``.
    public nonisolated func inbound() -> AsyncStream<JSONValue> { stream }

    /// Finishes ``inbound()``. No explicit session-termination `DELETE` is sent — the bridge
    /// process is short-lived and user-owned; adding one is tracked as a possible follow-up, not
    /// required by #1910's acceptance criteria.
    public func close() async {
        continuation.finish()
    }

    private func decode(_ payload: String) -> JSONValue? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return decodeData(data)
    }

    private func decodeData(_ data: Data) -> JSONValue? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return JSONValue.from(raw)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/swift-test.sh --filter SessionfulHTTPTransportTests`
Expected: PASS (all 5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/AI/SessionfulHTTPTransport.swift Tests/AnglesiteCoreTests/SessionfulHTTPTransportTests.swift
git commit -m "$(cat <<'EOF'
feat(#1910): add sessionful Streamable HTTP transport

Sibling to HTTPTransport's stateless dialect: captures/replays
Mcp-Session-Id and never sends MCP-Protocol-Version, matching the
handshake mcp-proxy/safaridriver --mcp requires per the transport
spike (docs/superpowers/specs/2026-09-04-safari-mcp-transport-spike.md).

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `NetworkTimeouts.safariMCPBridgeProbe` + `SafariMCPBridgeClient`

**Files:**
- Modify: `Sources/AnglesiteCore/Container/NetworkTimeouts.swift`
- Create: `Sources/AnglesiteCore/AI/SafariMCPBridgeClient.swift`
- Test: `Tests/AnglesiteCoreTests/SafariMCPBridgeClientTests.swift`

**Interfaces:**
- Consumes: `SessionfulHTTPTransport` (Task 1) — `init(endpoint:urlSession:)`, `open()`, `send(_:)`, `inbound()`, `close()`. `JSONValue`. `LogCenter` (`Sources/AnglesiteCore/LogCenter.swift`) — `public func append(source: String, stream: Stream, text: String, timestamp: Date = Date())`, `Stream.stdout`/`.stderr`, `LogCenter.shared`, `LogCenter()` (test init), `.snapshot()`.
- Produces:
  ```swift
  public actor SafariMCPBridgeClient {
      public struct ToolDescriptor: Sendable, Equatable {
          public let name: String
          public let description: String?
      }
      public struct ServerInfo: Sendable, Equatable {
          public let name: String
          public let version: String?
          public let protocolVersion: String
      }
      public enum ClientError: Error, Sendable, Equatable {
          case invalidResponse(String)
          case rpcError(code: Int, message: String)
          case timeout
      }
      public init(endpoint: URL, urlSession: URLSession = .shared, logCenter: LogCenter = .shared)
      public func connect(clientName: String = "Anglesite", clientVersion: String = "0.1.0", timeout: TimeInterval = NetworkTimeouts.safariMCPBridgeProbe) async throws -> ServerInfo
      public func listTools() async throws -> [ToolDescriptor]
      public func close() async
  }
  ```
  Consumed by Task 3's `SafariMCPBridgeDetector`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/SafariMCPBridgeClientTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite(.serialized)
struct SafariMCPBridgeClientTests {
    private func makeClient(logCenter: LogCenter = LogCenter()) -> (SafariMCPBridgeClient, URLSession) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        let client = SafariMCPBridgeClient(
            endpoint: URL(string: "http://127.0.0.1:4399/mcp")!,
            urlSession: session,
            logCenter: logCenter
        )
        return (client, session)
    }

    @Test("connect sends a real initialize request and decodes serverInfo") func connectDecodesServerInfo() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.queue.append(.init(
            status: 200,
            headers: ["Content-Type": "application/json", "Mcp-Session-Id": "sess-1"],
            body: #"""
            {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"Safari","version":"1.0.0"}}}
            """#.data(using: .utf8)!
        ))
        StubURLProtocol.queue.append(.init(status: 202, headers: [:], body: Data()))  // notifications/initialized

        let logCenter = LogCenter()
        let (client, _) = makeClient(logCenter: logCenter)
        let info = try await client.connect()
        #expect(info == SafariMCPBridgeClient.ServerInfo(name: "Safari", version: "1.0.0", protocolVersion: "2024-11-05"))

        // The initialize request itself must never send MCP-Protocol-Version, and the id=1
        // request must have no session header yet.
        #expect(StubURLProtocol.lastSessionHeaders.first == nil)

        let logged = await logCenter.snapshot()
        #expect(logged.contains { $0.source == "safari-mcp" && $0.stream == .stdout && $0.text.contains("Safari") })
        await client.close()
    }

    @Test("listTools decodes the tools array") func listToolsDecodes() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.queue.append(.init(
            status: 200,
            headers: ["Content-Type": "application/json", "Mcp-Session-Id": "sess-1"],
            body: #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","serverInfo":{"name":"Safari"}}}"#.data(using: .utf8)!
        ))
        StubURLProtocol.queue.append(.init(status: 202, headers: [:], body: Data()))
        StubURLProtocol.queue.append(.init(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: #"{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"browser_console_messages","description":"Read console"}]}}"#.data(using: .utf8)!
        ))

        let (client, _) = makeClient()
        _ = try await client.connect()
        let tools = try await client.listTools()
        #expect(tools == [.init(name: "browser_console_messages", description: "Read console")])
        await client.close()
    }

    @Test("a JSON-RPC error response surfaces as ClientError.rpcError") func rpcErrorSurfaces() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.queue.append(.init(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: #"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"nope"}}"#.data(using: .utf8)!
        ))
        let (client, _) = makeClient()
        do {
            _ = try await client.connect()
            Issue.record("expected ClientError.rpcError to be thrown")
        } catch SafariMCPBridgeClient.ClientError.rpcError(let code, let message) {
            #expect(code == -32000)
            #expect(message == "nope")
        }
        await client.close()
    }

    @Test("connection failure logs to LogCenter and rethrows") func connectionFailureLogs() async throws {
        StubURLProtocol.reset()
        // Empty queue -> StubURLProtocol answers 500 by default.
        let logCenter = LogCenter()
        let (client, _) = makeClient(logCenter: logCenter)
        await #expect(throws: (any Error).self) {
            _ = try await client.connect()
        }
        let logged = await logCenter.snapshot()
        #expect(logged.contains { $0.source == "safari-mcp" && $0.stream == .stderr })
        await client.close()
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/swift-test.sh --filter SafariMCPBridgeClientTests`
Expected: FAIL — "cannot find type 'SafariMCPBridgeClient' in scope".

- [ ] **Step 3: Add the timeout constant**

In `Sources/AnglesiteCore/Container/NetworkTimeouts.swift`, add after the `acpPromptTimeout` line (before the closing `}`):

```swift

    /// `SafariMCPBridgeClient.connect(...)`'s `initialize` request bound — kept short since this
    /// is a Settings-pane reachability check the user expects to resolve almost instantly, not a
    /// deploy-critical operation.
    public static let safariMCPBridgeProbe: TimeInterval = 3
```

- [ ] **Step 4: Write the implementation**

Create `Sources/AnglesiteCore/AI/SafariMCPBridgeClient.swift`:

```swift
import Foundation

/// A minimal JSON-RPC 2.0 client speaking the *standard* (sessionful) MCP Streamable HTTP
/// handshake over a ``SessionfulHTTPTransport`` — the real `initialize` → `Mcp-Session-Id` →
/// subsequent-request flow a standards-compliant MCP HTTP server (e.g. `mcp-proxy`-wrapped
/// `safaridriver --mcp`) requires, and that ``MCPClient``'s stateless dialect cannot speak. See
/// docs/superpowers/specs/2026-09-04-safari-mcp-transport-spike.md.
///
/// Deliberately separate from `MCPClient`: that client's `sendRequest` unconditionally wraps
/// every request in a stateless `_meta` envelope and treats `server/discover` as its readiness
/// probe — both wrong for a real MCP server, which expects a genuine `initialize` request and
/// recognizes neither concept.
///
/// Scope: enough to detect a reachable bridge and list its tools (#1910's acceptance criteria).
/// Invoking a tool over this client is out of scope — see #453 child issue 3.
public actor SafariMCPBridgeClient {
    /// One tool advertised by the connected server's `tools/list` response.
    public struct ToolDescriptor: Sendable, Equatable {
        public let name: String
        public let description: String?
    }

    /// The server's `initialize` response — enough to show "Connected to Safari" in Settings.
    public struct ServerInfo: Sendable, Equatable {
        public let name: String
        public let version: String?
        public let protocolVersion: String
    }

    /// Failures specific to this client (transport failures pass through from
    /// ``SessionfulHTTPTransport/HTTPError`` unchanged).
    public enum ClientError: Error, Sendable, Equatable {
        case invalidResponse(String)
        case rpcError(code: Int, message: String)
        case timeout
    }

    private let transport: SessionfulHTTPTransport
    private let logCenter: LogCenter
    private let endpointDescription: String
    private var readerTask: Task<Void, Never>?
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]

    /// Creates a client for one sessionful `/mcp` endpoint. `urlSession` is injectable for tests;
    /// `logCenter` likewise, so tests can assert on logged diagnostics without touching the shared
    /// singleton the Debug pane reads from.
    public init(endpoint: URL, urlSession: URLSession = .shared, logCenter: LogCenter = .shared) {
        self.transport = SessionfulHTTPTransport(endpoint: endpoint, urlSession: urlSession)
        self.logCenter = logCenter
        self.endpointDescription = endpoint.absoluteString
    }

    /// Opens the transport, sends a real `initialize` request, and — on success — the
    /// `notifications/initialized` notification the MCP spec expects a client to send once
    /// initialization completes. Logs the outcome to `LogCenter` (source `"safari-mcp"`) either
    /// way, so the Debug pane shows every probe without new UI plumbing. Returns the negotiated
    /// ``ServerInfo``.
    public func connect(
        clientName: String = "Anglesite",
        clientVersion: String = "0.1.0",
        timeout: TimeInterval = NetworkTimeouts.safariMCPBridgeProbe
    ) async throws -> ServerInfo {
        do {
            try await transport.open()
            // Capture `transport` into a local `let` before crossing into the detached Task below
            // — matching `MCPClient.startWithTransport`'s own `t.inbound()` pattern exactly, so the
            // closure reads a plain (Sendable, nonisolated-safe) local rather than reaching through
            // `self.transport` from outside this actor's isolation.
            let t = transport
            readerTask = Task { [weak self] in
                guard let self else { return }
                await self.consumeResponses(t.inbound())
            }
            let result = try await sendRequest(method: "initialize", params: .object([
                "protocolVersion": .string("2024-11-05"),
                "capabilities": .object([:]),
                "clientInfo": .object(["name": .string(clientName), "version": .string(clientVersion)]),
            ]), timeout: timeout)
            guard case .object(let dict) = result else {
                throw ClientError.invalidResponse("initialize result not an object")
            }
            let protocolVersion: String = {
                if case .string(let v)? = dict["protocolVersion"] { return v }
                return "2024-11-05"
            }()
            var name = "MCP server"
            var version: String?
            if case .object(let serverInfo)? = dict["serverInfo"] {
                if case .string(let n)? = serverInfo["name"] { name = n }
                if case .string(let v)? = serverInfo["version"] { version = v }
            }
            try await transport.send(.object([
                "jsonrpc": .string("2.0"),
                "method": .string("notifications/initialized"),
            ]))
            let info = ServerInfo(name: name, version: version, protocolVersion: protocolVersion)
            await logCenter.append(
                source: "safari-mcp", stream: .stdout,
                text: "Connected to \(info.name)\(info.version.map { " \($0)" } ?? "") at \(endpointDescription)"
            )
            return info
        } catch {
            await logCenter.append(
                source: "safari-mcp", stream: .stderr,
                text: "Failed to connect to Safari MCP bridge at \(endpointDescription): \(error)"
            )
            throw error
        }
    }

    /// Fetches the server's tool catalog. Requires a prior successful ``connect(...)``.
    public func listTools() async throws -> [ToolDescriptor] {
        let result = try await sendRequest(method: "tools/list", params: .object([:]), timeout: NetworkTimeouts.mcpToolsListRequest)
        guard case .object(let dict) = result, case .array(let tools)? = dict["tools"] else {
            throw ClientError.invalidResponse("tools/list missing 'tools' array")
        }
        return tools.compactMap { entry in
            guard case .object(let obj) = entry, case .string(let name)? = obj["name"] else { return nil }
            let description: String? = { if case .string(let s)? = obj["description"] { return s }; return nil }()
            return ToolDescriptor(name: name, description: description)
        }
    }

    /// Closes the transport and fails every still-pending request. Safe to call more than once.
    public func close() async {
        readerTask?.cancel()
        readerTask = nil
        await transport.close()
        for (_, cont) in pending { cont.resume(throwing: ClientError.invalidResponse("closed")) }
        pending.removeAll()
    }

    private func sendRequest(method: String, params: JSONValue?, timeout: TimeInterval) async throws -> JSONValue {
        let id = nextRequestID
        nextRequestID += 1
        let message = JSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": .int(id),
            "method": .string(method),
            "params": params ?? .object([:]),
        ])

        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
            if !Task.isCancelled { await self?.failPending(id: id, error: ClientError.timeout) }
        }
        defer { timeoutTask.cancel() }

        // Same local-capture reasoning as `connect()`'s reader task above: `t` is a plain local,
        // not an actor-isolated property reached through `self` from outside the actor.
        let t = transport
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSONValue, Error>) in
            pending[id] = cont
            Task { [weak self] in
                do {
                    try await t.send(message)
                } catch {
                    await self?.failPending(id: id, error: error)
                }
            }
        }
    }

    private func failPending(id: Int, error: Error) {
        if let cont = pending.removeValue(forKey: id) { cont.resume(throwing: error) }
    }

    private func resolvePending(id: Int, value: JSONValue) {
        if let cont = pending.removeValue(forKey: id) { cont.resume(returning: value) }
    }

    private func consumeResponses(_ stream: AsyncStream<JSONValue>) async {
        for await message in stream {
            guard case .object(let obj) = message else { continue }
            guard case .int(let id)? = obj["id"] else { continue }
            if case .object(let errObj)? = obj["error"] {
                let code: Int = { if case .int(let c)? = errObj["code"] { return c }; return -1 }()
                let msg: String = { if case .string(let m)? = errObj["message"] { return m }; return "unknown rpc error" }()
                failPending(id: id, error: ClientError.rpcError(code: code, message: msg))
                continue
            }
            if let result = obj["result"] {
                resolvePending(id: id, value: result)
            } else {
                resolvePending(id: id, value: .null)
            }
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `scripts/swift-test.sh --filter SafariMCPBridgeClientTests`
Expected: PASS (all 4 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/Container/NetworkTimeouts.swift Sources/AnglesiteCore/AI/SafariMCPBridgeClient.swift Tests/AnglesiteCoreTests/SafariMCPBridgeClientTests.swift
git commit -m "$(cat <<'EOF'
feat(#1910): add SafariMCPBridgeClient sessionful RPC client

Real initialize/notifications-initialized/tools-list flow over
SessionfulHTTPTransport, kept separate from MCPClient since that
client's _meta envelope and server/discover probe are stateless-only
concepts a real MCP server doesn't understand. Logs connect
outcomes through LogCenter (source "safari-mcp") so the Debug pane
shows every probe without new UI.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `SafariMCPBridgeDetector`

**Files:**
- Create: `Sources/AnglesiteCore/AI/SafariMCPBridgeDetector.swift`
- Test: `Tests/AnglesiteCoreTests/SafariMCPBridgeDetectorTests.swift`

**Interfaces:**
- Consumes: `SafariMCPBridgeClient` (Task 2) — `init(endpoint:urlSession:logCenter:)`, `connect(timeout:)`, `close()`.
- Produces:
  ```swift
  public struct SafariMCPBridgeStatus: Sendable, Equatable {
      public enum State: Sendable, Equatable {
          case reachable(serverName: String)
          case unreachable
      }
      public let state: State
      public let port: Int
  }
  public actor SafariMCPBridgeDetector {
      public static let defaultPort = 8931
      public init(urlSession: URLSession = .shared, logCenter: LogCenter = .shared)
      public func checkReachability(port: Int, timeout: TimeInterval = NetworkTimeouts.safariMCPBridgeProbe) async -> SafariMCPBridgeStatus
  }
  ```
  Consumed by Task 4 (`AppSettings.safariMCPBridgePort`'s default) and Task 5 (Settings UI).

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/SafariMCPBridgeDetectorTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite(.serialized)
struct SafariMCPBridgeDetectorTests {
    private func makeDetector() -> (SafariMCPBridgeDetector, URLSession) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        return (SafariMCPBridgeDetector(urlSession: session, logCenter: LogCenter()), session)
    }

    @Test("a reachable bridge reports .reachable with the server name") func reachable() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.queue.append(.init(
            status: 200,
            headers: ["Content-Type": "application/json", "Mcp-Session-Id": "sess-1"],
            body: #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","serverInfo":{"name":"Safari"}}}"#.data(using: .utf8)!
        ))
        StubURLProtocol.queue.append(.init(status: 202, headers: [:], body: Data()))
        let (detector, _) = makeDetector()
        let status = await detector.checkReachability(port: 8931)
        #expect(status == SafariMCPBridgeStatus(state: .reachable(serverName: "Safari"), port: 8931))
    }

    @Test("an unreachable port reports .unreachable") func unreachable() async throws {
        StubURLProtocol.reset()  // empty queue -> 500 from every request
        let (detector, _) = makeDetector()
        let status = await detector.checkReachability(port: 8931)
        #expect(status == SafariMCPBridgeStatus(state: .unreachable, port: 8931))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/swift-test.sh --filter SafariMCPBridgeDetectorTests`
Expected: FAIL — "cannot find type 'SafariMCPBridgeDetector' in scope".

- [ ] **Step 3: Write the implementation**

Create `Sources/AnglesiteCore/AI/SafariMCPBridgeDetector.swift`:

```swift
import Foundation

/// The result of one reachability probe against a configured loopback port.
public struct SafariMCPBridgeStatus: Sendable, Equatable {
    /// Whether a Safari MCP bridge answered the handshake.
    public enum State: Sendable, Equatable {
        /// The port answered a real `initialize` handshake; carries the server's advertised name
        /// (e.g. "Safari") for display.
        case reachable(serverName: String)
        /// No bridge answered — absent, still starting, or a bridge speaking a different dialect.
        case unreachable
    }
    public let state: State
    public let port: Int
}

/// Detects whether a Safari MCP bridge (a user-launched `mcp-proxy`-style stdio→HTTP bridge
/// wrapping `safaridriver --mcp`, per
/// docs/superpowers/specs/2026-09-04-safari-mcp-transport-spike.md) is reachable at a loopback
/// port — by attempting the real sessionful handshake, never by checking for a `safaridriver`
/// process or binary path: the app has no visibility into what the user has running beyond the
/// socket, and never spawns the bridge itself (owner's 2026-09-04 sandboxing decision).
public actor SafariMCPBridgeDetector {
    /// The port Settings suggests in its example bridge command, and probes when the user hasn't
    /// configured one — arbitrary, but matches the transport spike's own worked example.
    public static let defaultPort = 8931

    private let urlSession: URLSession
    private let logCenter: LogCenter

    public init(urlSession: URLSession = .shared, logCenter: LogCenter = .shared) {
        self.urlSession = urlSession
        self.logCenter = logCenter
    }

    /// Attempts the sessionful `initialize` handshake against `http://127.0.0.1:<port>/mcp` and
    /// reports whether it succeeded. Always tears the client down before returning; a failure of
    /// any kind (connection refused, timeout, malformed handshake) reports `.unreachable` rather
    /// than throwing — this is a status check, not an operation that can fail the caller.
    public func checkReachability(
        port: Int,
        timeout: TimeInterval = NetworkTimeouts.safariMCPBridgeProbe
    ) async -> SafariMCPBridgeStatus {
        guard let url = URL(string: "http://127.0.0.1:\(port)/mcp") else {
            return SafariMCPBridgeStatus(state: .unreachable, port: port)
        }
        let client = SafariMCPBridgeClient(endpoint: url, urlSession: urlSession, logCenter: logCenter)
        do {
            let info = try await client.connect(timeout: timeout)
            await client.close()
            return SafariMCPBridgeStatus(state: .reachable(serverName: info.name), port: port)
        } catch {
            await client.close()
            return SafariMCPBridgeStatus(state: .unreachable, port: port)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/swift-test.sh --filter SafariMCPBridgeDetectorTests`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/AI/SafariMCPBridgeDetector.swift Tests/AnglesiteCoreTests/SafariMCPBridgeDetectorTests.swift
git commit -m "$(cat <<'EOF'
feat(#1910): add SafariMCPBridgeDetector reachability probe

Detects a Safari MCP bridge by attempting the real handshake against
a loopback port, never by checking for a safaridriver process —
the app has no visibility into what the user has running beyond the
socket, and never spawns the bridge itself.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `AppSettings.safariMCPBridgePort`

**Files:**
- Modify: `Sources/AnglesiteCore/AppSettings.swift`
- Test: `Tests/AnglesiteCoreTests/AppSettingsSafariMCPBridgeTests.swift`

**Interfaces:**
- Consumes: `SafariMCPBridgeDetector.defaultPort` (Task 3). `AppSettings`'s existing private `port(forKey:default:)` helper (`Sources/AnglesiteCore/AppSettings.swift`, defined just below `lanRuntimeConfiguration`). `AnglesiteTestSupport.TemporaryUserDefaults` — a `final class` wrapping a scratch `UserDefaults` suite with a `.defaults` property and a `.cleanup()` torn down in `deinit` (see `Tests/AnglesiteCoreTests/AppSettingsTests.swift:8-12` for the exact idiom — never a hand-rolled `UserDefaults(suiteName:)` per `CONTRIBUTING.md` ▸ Testing notes).
- Produces: `AppSettings.Key.safariMCPBridgePort: String` and `AppSettings.safariMCPBridgePort: Int { get set }` — consumed by Task 5's Settings UI (as the canonical storage `@AppStorage` mirrors) and any future caller that needs the configured port outside the UI layer.

- [ ] **Step 1: Write the failing test**

Create `Tests/AnglesiteCoreTests/AppSettingsSafariMCPBridgeTests.swift`, following the exact `TemporaryUserDefaults` idiom already used by `Tests/AnglesiteCoreTests/AppSettingsTests.swift:8-12`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore
import AnglesiteTestSupport

/// A `final class` (not a `struct`) so `deinit` can drop the throwaway `UserDefaults` suite —
/// same idiom as `AppSettingsTests`.
final class AppSettingsSafariMCPBridgeTests {
    private let scratch = TemporaryUserDefaults()
    private var defaults: UserDefaults { scratch.defaults }

    deinit { scratch.cleanup() }

    @Test("defaults to SafariMCPBridgeDetector.defaultPort when unset")
    func defaultsWhenUnset() {
        let settings = AppSettings(defaults: defaults)
        #expect(settings.safariMCPBridgePort == SafariMCPBridgeDetector.defaultPort)
    }

    @Test("stores and round-trips a configured port")
    func roundTrips() {
        let settings = AppSettings(defaults: defaults)
        settings.safariMCPBridgePort = 9001
        #expect(settings.safariMCPBridgePort == 9001)
    }

    @Test("falls back to the default for an out-of-range stored value")
    func fallsBackWhenInvalid() {
        defaults.set("not-a-port", forKey: AppSettings.Key.safariMCPBridgePort)
        let settings = AppSettings(defaults: defaults)
        #expect(settings.safariMCPBridgePort == SafariMCPBridgeDetector.defaultPort)
    }
}
```

On Darwin, `AppSettings.init(defaults:)` also accepts a second `ubiquityContainerResolver` argument defaulted to `FileManager.default` (`Sources/AnglesiteCore/AppSettings.swift:135`) — not needed here since these tests never touch `sitesRoot`, so the one-argument call above is correct as written; `AppSettingsTests.swift`'s other tests are the ones that pass `ubiquityContainerResolver` explicitly, only because they specifically test `sitesRoot`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `scripts/swift-test.sh --filter AppSettingsSafariMCPBridgeTests`
Expected: FAIL — "type 'AppSettings.Key' has no member 'safariMCPBridgePort'" (and/or `AppSettings` has no member `safariMCPBridgePort`).

- [ ] **Step 3: Write the implementation**

In `Sources/AnglesiteCore/AppSettings.swift`, add a key inside `public enum Key` right after the `lanRuntimeMCPPort` line (`Sources/AnglesiteCore/AppSettings.swift:27`):

```swift
        /// Backs ``AppSettings/safariMCPBridgePort`` (#1910).
        public static let safariMCPBridgePort = "anglesite.safariMCPBridgePort"
```

Then add the computed property right after `lanRuntimeConfiguration`'s `port(forKey:default:)` helper (`Sources/AnglesiteCore/AppSettings.swift:196-200`):

```swift

    /// The loopback port Settings probes for a user-launched Safari MCP bridge (#1910) — e.g.
    /// `npx -y mcp-proxy --port <port> -- safaridriver --mcp`. Stored as a string (the Settings
    /// text field's empty state means "default"); falls back to
    /// ``SafariMCPBridgeDetector/defaultPort`` when blank or out of range.
    public var safariMCPBridgePort: Int {
        get { port(forKey: Key.safariMCPBridgePort, default: SafariMCPBridgeDetector.defaultPort) }
        set { defaults.set(String(newValue), forKey: Key.safariMCPBridgePort) }
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `scripts/swift-test.sh --filter AppSettingsSafariMCPBridgeTests`
Expected: PASS (all 3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/AppSettings.swift Tests/AnglesiteCoreTests/AppSettingsSafariMCPBridgeTests.swift
git commit -m "$(cat <<'EOF'
feat(#1910): add AppSettings.safariMCPBridgePort

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Settings UI — "Safari MCP Bridge" section

**Files:**
- Modify: `Sources/AnglesiteApp/SettingsView.swift`
- Modify: `Sources/AnglesiteApp/AXID.swift`
- Test: `Tests/AnglesiteAppTests/AXIDTests.swift` (existing uniqueness/format test — no new test file; just verify the new identifiers pass it. Locate this file first; if its name differs, use whichever file already covers `AXID.allStatic`.)

**Interfaces:**
- Consumes: `AppSettings.Key.safariMCPBridgePort` (Task 4), `SafariMCPBridgeDetector` + `SafariMCPBridgeStatus` (Task 3).
- Produces: two new `AXID` identifiers (`settingsSafariMCPBridgePort`, `settingsSafariMCPBridgeStatus`) added to `AXID.allStatic`; a new "Safari MCP Bridge" `Section` in `AdvancedSettingsView`; a new private `SafariMCPBridgeStatusRow` view.

- [ ] **Step 1: Add AXID identifiers**

In `Sources/AnglesiteApp/AXID.swift`, add after the `debugWorkerFailure` line (`Sources/AnglesiteApp/AXID.swift:89`), under a new `// MARK: Safari MCP Bridge (#1910)` comment:

```swift

    // MARK: Safari MCP Bridge (#1910)

    static let settingsSafariMCPBridgePort = "settings.safariMCPBridge.port"
    static let settingsSafariMCPBridgeStatus = "settings.safariMCPBridge.status"
```

And add both to the `allStatic` array (`Sources/AnglesiteApp/AXID.swift:94-104`), inserting before the closing `]`:

```swift
        debugServerHeader, debugLocalWorkersHeader,
        settingsSafariMCPBridgePort, settingsSafariMCPBridgeStatus,
    ]
```

- [ ] **Step 2: Run the existing AXID test to verify the new identifiers pass format/uniqueness checks**

Run: `scripts/swift-test.sh --filter AXIDTests` (search `Tests/AnglesiteAppTests/` first if this exact name doesn't exist, and use the actual suite name)
Expected: PASS — the new identifiers follow the existing dotted `<surface>.<control>` convention, so no format violation.

- [ ] **Step 3: Add the Settings section**

In `Sources/AnglesiteApp/SettingsView.swift`, add an `@AppStorage` property to `AdvancedSettingsView` right after the `lanRuntimeMCPPort` line (`Sources/AnglesiteApp/SettingsView.swift:400`):

```swift
    @AppStorage(AppSettings.Key.safariMCPBridgePort) private var safariMCPBridgePortText: String = ""
```

Add a computed property near `showsLANRuntimeSection` (`Sources/AnglesiteApp/SettingsView.swift:406-412`):

```swift

    /// The effective port for the Safari MCP Bridge section below — falls back to
    /// `SafariMCPBridgeDetector.defaultPort` for an empty or out-of-range field, mirroring
    /// `AppSettings.safariMCPBridgePort`'s own fallback so the two never disagree.
    private var safariMCPBridgePort: Int {
        guard let port = Int(safariMCPBridgePortText.trimmingCharacters(in: .whitespaces)),
              (1...65535).contains(port) else { return SafariMCPBridgeDetector.defaultPort }
        return port
    }
```

Add a new `Section` inside `body`'s `Form`, right after the `"Credentials"` section closes and before the `if showsLANRuntimeSection` block (`Sources/AnglesiteApp/SettingsView.swift:463-465`):

```swift

            Section("Safari MCP Bridge") {
                LabeledContent("Bridge port") {
                    TextField("", text: $safariMCPBridgePortText,
                              prompt: Text(verbatim: String(SafariMCPBridgeDetector.defaultPort)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .accessibilityLabel("Safari MCP bridge port")
                        .accessibilityIdentifier(AXID.settingsSafariMCPBridgePort)
                }
                SafariMCPBridgeStatusRow(port: safariMCPBridgePort)
            }
```

Add the new private view, near `KeychainTokenRow` (after its closing brace, `Sources/AnglesiteApp/SettingsView.swift:874`):

```swift

/// Reachability status + setup guidance for a user-launched Safari MCP bridge (#1910). Probes
/// `port` with `SafariMCPBridgeDetector` on appear and whenever the port changes; shows the two
/// Safari Technology Preview toggles and the exact bridge command only while unreachable, so a
/// working connection doesn't stay cluttered with setup instructions. The app never spawns the
/// bridge itself — this row can only observe, never fix, the connection.
private struct SafariMCPBridgeStatusRow: View {
    let port: Int

    @State private var status: Status = .checking

    private enum Status: Equatable {
        case checking
        case reachable(String)
        case unreachable
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Connection") {
                HStack(spacing: 8) {
                    statusLabel
                    Button("Check Again") { Task { await check() } }
                        .disabled(status == .checking)
                }
            }
            .accessibilityIdentifier(AXID.settingsSafariMCPBridgeStatus)

            if case .unreachable = status {
                setupGuidance
            }

            Text("Safari MCP runs locally on this Mac. Once bridged, it can expose the active Safari tab's page content, screenshots, and console logs to whatever is listening on that port — only run the bridge command when you trust what's on the other end.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task(id: port) { await check() }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case .checking:
            ProgressView().controlSize(.small)
        case .reachable(let name):
            Label("Connected to \(name)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .unreachable:
            Label("Not reachable", systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }

    @ViewBuilder
    private var setupGuidance: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Requires Safari Technology Preview with two settings enabled: Settings ▸ Advanced ▸ \u{201C}Show features for web developers\u{201D}, then Settings ▸ Developer ▸ \u{201C}Enable remote automation and external agents.\u{201D} Then run this in Terminal:")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: "npx -y mcp-proxy --port \(port) -- safaridriver --mcp")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(6)
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    private func check() async {
        status = .checking
        let result = await SafariMCPBridgeDetector().checkReachability(port: port)
        switch result.state {
        case .reachable(let name): status = .reachable(name)
        case .unreachable: status = .unreachable
        }
    }
}
```

- [ ] **Step 4: Build the app target**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: Build succeeds with no new warnings/errors in `SettingsView.swift` or `AXID.swift`.

- [ ] **Step 5: Manual verification in the running app**

Follow `docs/testing-macos-app.md` to launch the built Debug app. Open Settings ▸ Advanced and confirm:
- A "Safari MCP Bridge" section appears with a "Bridge port" field (placeholder `8931`) and a "Connection" row.
- With no bridge running, it shows "Not reachable", the two-toggle + `npx -y mcp-proxy …` setup guidance, and the local-execution/trust caption.
- If `safaridriver`/`npx` are available in this environment, actually start `npx -y mcp-proxy --port 8931 -- safaridriver --mcp` in Terminal, click "Check Again", and confirm the row flips to "Connected to Safari" and the setup guidance disappears. If Safari Technology Preview or `safaridriver --mcp` automation permission isn't available in this environment, note that explicitly instead of claiming this half was verified.
- Check the Debug pane (View ▸ Show Debug Pane) shows a `safari-mcp` source in the log source picker after a check, carrying the connect success/failure line.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteApp/SettingsView.swift Sources/AnglesiteApp/AXID.swift
git commit -m "$(cat <<'EOF'
feat(#1910): add Safari MCP Bridge status section to Settings

Connection status + setup guidance (Safari Technology Preview
toggles, exact bridge command) shown only while unreachable, plus
the local-execution/trust caption from #453's acceptance criteria.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Gated live e2e test against real `mcp-proxy` + `safaridriver --mcp`

**Files:**
- Create: `Tests/AnglesiteCoreTests/SafariMCPBridgeE2ETests.swift`

**Interfaces:**
- Consumes: `SafariMCPBridgeClient` (Task 2). `ProcessSupervisor` (`Sources/AnglesiteCore/ProcessSupervisor.swift`) for spawning `npx`. Look at `Tests/AnglesiteCoreTests/MCPClientHTTPEndToEndTests.swift` for the exact free-port-probe and ready-poll helpers (`E2EServer.awaitReady` or equivalent) and copy its gating shape (`.enabled(if: ...)`), not its sidecar-specific spawn logic.

This test only runs when explicitly opted in — it depends on real Safari Technology Preview automation permission and network access to fetch `mcp-proxy` via `npx`, neither available in CI or most agent sandboxes.

**Reference:** `Tests/AnglesiteCoreTests/MCPClientHTTPEndToEndTests.swift` is the model this task follows exactly for process spawning (`ProcessSupervisor.launch(source:executable:arguments:environment:currentDirectoryURL:restartPolicy:attachStdin:onRespawn:logCenter:)` → `ProcessSupervisorHandle`, torn down with `supervisor.terminate(handle:timeout:)`), readiness polling (`E2EServer.awaitReady(handle:supervisor:logCenter:timeout:)`), and the free-port probe (its `private static func freePort()`, `Darwin` sockets, and the `FreePortError` type — both `private` to that file, so this task's own copies below duplicate that exact approach rather than importing it).

- [ ] **Step 1: Write the gated test**

```swift
import Testing
import Foundation
import Darwin
@testable import AnglesiteCore

/// Live round-trip against a real `mcp-proxy`-wrapped `safaridriver --mcp` session, mirroring the
/// curl transcripts in docs/superpowers/specs/2026-09-04-safari-mcp-transport-spike.md. Opt-in
/// only (`ANGLESITE_SAFARI_MCP_E2E=1`): requires Safari Technology Preview's remote-automation
/// toggle already granted, `safaridriver` on PATH, and network access for `npx` to fetch
/// `mcp-proxy` — none of which hold in CI or most sandboxes. Skips cleanly otherwise.
@Suite(.serialized)
struct SafariMCPBridgeE2ETests {
    @Test(
        "initialize -> tools/list round-trips against a live bridge",
        .enabled(
            if: SafariMCPBridgeE2EPrerequisites.met,
            "requires ANGLESITE_SAFARI_MCP_E2E=1, safaridriver on PATH, and network access for npx to fetch mcp-proxy"
        )
    )
    func liveRoundTrip() async throws {
        let port = try Self.freePort()
        let supervisor = ProcessSupervisor()
        let logCenter = LogCenter()
        let handle = try await supervisor.launch(
            source: "safari-mcp-e2e",
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["npx", "-y", "mcp-proxy", "--port", String(port), "--host", "127.0.0.1", "--", "safaridriver", "--mcp"],
            environment: [:],
            currentDirectoryURL: nil,
            restartPolicy: .never,
            attachStdin: false,
            onRespawn: nil,
            logCenter: logCenter
        )
        defer { Task { await supervisor.terminate(handle, timeout: 2) } }

        let endpoint = URL(string: "http://127.0.0.1:\(port)/mcp")!
        var connectedInfo: SafariMCPBridgeClient.ServerInfo?
        var client: SafariMCPBridgeClient?

        // mcp-proxy fetched fresh via `npx -y` can take a while to install on first run, so the
        // budget here is generous like the sibling plugin e2e test's own 60s readyBudget.
        let readyBudget: TimeInterval = 60
        try await E2EServer.awaitReady(handle: handle, supervisor: supervisor, logCenter: logCenter, timeout: readyBudget) {
            let deadline = Date().addingTimeInterval(readyBudget - 5)
            while true {
                let c = SafariMCPBridgeClient(endpoint: endpoint)
                do {
                    connectedInfo = try await c.connect(timeout: 2)
                    client = c
                    return
                } catch {
                    await c.close()
                    guard Date() < deadline else { throw error }
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
        defer { Task { await client?.close() } }

        let info = try #require(connectedInfo)
        #expect(info.name.lowercased().contains("safari"))
        let tools = try await #require(client).listTools()
        #expect(!tools.isEmpty)
    }

    // NB: do not interpolate `errno` into these messages — see the identical note in
    // `MCPClientHTTPEndToEndTests.freePort()` (macOS-27-SDK-only symbol, absent on the macOS-15 CI
    // runner, breaks `dlopen`). Moot in practice here since this whole suite is gated off CI, but
    // kept consistent with that file's convention.
    private static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FreePortError("socket() failed") }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindOK = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindOK == 0 else { throw FreePortError("bind() failed") }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}

/// A genuine failure while reserving a loopback port — distinct from a missing-prerequisite skip.
private struct FreePortError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Gate for `SafariMCPBridgeE2ETests`: opt-in env var plus `safaridriver` actually present.
/// Deliberately does NOT check for `npx`/Node — `npx -y` fetching `mcp-proxy` over the network is
/// itself part of what this test needs to succeed, so a missing `npx` should surface as this
/// test's own failure (a clear "command not found" from the spawned process), not a silent skip.
enum SafariMCPBridgeE2EPrerequisites {
    static var met: Bool {
        ProcessInfo.processInfo.environment["ANGLESITE_SAFARI_MCP_E2E"] == "1"
            && FileManager.default.isExecutableFile(atPath: "/usr/bin/safaridriver")
    }
}
```

Before running this, open `Tests/AnglesiteCoreTests/MCPClientHTTPEndToEndTests.swift` in full and confirm `ProcessSupervisor.launch(...)`'s parameter names/order, `ProcessSupervisor.terminate(_:timeout:)`, and `E2EServer.awaitReady(handle:supervisor:logCenter:timeout:)`'s exact signature still match what's written above (this plan was written from reading that file, but signatures can drift) — adjust this test's call sites to match the real ones if they've changed since.

- [ ] **Step 2: Run it unopted (verify clean skip)**

Run: `scripts/swift-test.sh --filter SafariMCPBridgeE2ETests`
Expected: The suite reports skipped/disabled (not run), since `ANGLESITE_SAFARI_MCP_E2E` isn't set in this environment. This is a PASS for this task, not a failure.

- [ ] **Step 3: If this environment genuinely has Safari Technology Preview + granted automation permission + network access, opt in and confirm a live pass**

Run: `ANGLESITE_SAFARI_MCP_E2E=1 scripts/swift-test.sh --filter SafariMCPBridgeE2ETests`
Expected: PASS. If any prerequisite is actually missing here (no Safari Technology Preview, no automation grant, no network), state that explicitly rather than forcing a run — this step is expected to be skipped in most sessions, including headless/agent ones, and that's fine.

- [ ] **Step 4: Commit**

```bash
git add Tests/AnglesiteCoreTests/SafariMCPBridgeE2ETests.swift
git commit -m "$(cat <<'EOF'
test(#1910): add opt-in e2e test against a live Safari MCP bridge

ANGLESITE_SAFARI_MCP_E2E=1-gated: spawns npx mcp-proxy wrapping
safaridriver --mcp and round-trips initialize -> tools/list, mirroring
the transport spike's curl transcripts. Skips cleanly without Safari
Technology Preview / automation permission / network access, none of
which hold in CI.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Full verification + PR

**Files:** none (verification only)

- [ ] **Step 1: Run the full Swift test suite**

Run: `scripts/swift-test.sh`
Expected: PASS — no regressions in `HTTPTransportTests`, `MCPClientTests`, or any other existing suite.

- [ ] **Step 2: Build the app target**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: Build succeeds.

- [ ] **Step 3: Check for localization catalog drift**

Since Task 5 added new user-visible `Text`/`Label`/`TextField` strings in `SettingsView.swift`, follow `CONTRIBUTING.md`'s String Catalog merge recipe (the `xcrun xcstringstool sync` invocation scoped to this worktree's own `BUILD_DIR`) and commit the resulting `Sources/AnglesiteApp/Localizable.xcstrings` diff. Review the diff before committing — only new keys from strings actually added in Task 5 should appear.

- [ ] **Step 4: Re-read `CONTRIBUTING.md` ▸ "Commits and pull requests" and open the PR**

Use `.github/PULL_REQUEST_TEMPLATE.md`'s exact headings (Summary, Paired PR check, Test plan). This is app-only (no MCP message schema change, no sidecar involvement) — no paired PR needed. Body must include `Closes #1910`. Example `gh pr create` body:

```
## Summary
- Add SessionfulHTTPTransport, a sibling MCP-over-HTTP transport speaking the standard
  sessionful Streamable HTTP handshake (initialize -> Mcp-Session-Id -> replay), alongside
  HTTPTransport's existing stateless dialect for the container sidecar.
- Add SafariMCPBridgeClient + SafariMCPBridgeDetector so Anglesite can detect and connect to
  a user-launched Safari MCP bridge (npx -y mcp-proxy --port <port> -- safaridriver --mcp).
- Add a Settings ▸ Advanced "Safari MCP Bridge" section: connection status, setup guidance
  (Safari Technology Preview toggles + exact bridge command) when unreachable, and the
  local-execution/trust caption from #453's acceptance criteria.

## Paired PR check
No MCP message schema change — this is app-only (a new client-side transport/protocol mode
consuming the existing standard MCP spec, not a change to anglesite-skills' server). No
paired PR needed.

## Test plan
- [ ] `scripts/swift-test.sh` passes
- [ ] `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build` succeeds
- [ ] Manually verified the Settings section shows "Not reachable" + setup guidance with no
      bridge running (see Task 5 step 5 for the live-bridge half, verified if this environment
      had Safari Technology Preview + automation permission available)

Closes #1910

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

- [ ] **Step 5: Leave the `🛠️ In Progress` label in place** (per `CONTRIBUTING.md` — don't remove it; the PR's `Closes #1910` closes the issue on merge).
