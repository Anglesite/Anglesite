import Foundation
// URLSession lives in FoundationNetworking on non-Darwin platforms (swift-corelibs-foundation);
// this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
    ///
    /// Each instance supports exactly one `connect()` attempt — a failed connect closes the
    /// client internally; create a fresh instance to retry.
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
                if case .string(let n)? = serverInfo["name"] { name = Self.sanitize(n) }
                if case .string(let v)? = serverInfo["version"] { version = Self.sanitize(v) }
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
            await self.close()
            throw error
        }
    }

    /// Fetches the server's tool catalog. Requires a prior successful
    /// ``connect(clientName:clientVersion:timeout:)``.
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
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSONValue, Error>) in
                pending[id] = cont
                Task { [weak self] in
                    do {
                        try await t.send(message)
                    } catch {
                        await self?.failPending(id: id, error: error)
                    }
                }
            }
        } onCancel: {
            // The awaiting task was cancelled. Resolve the pending continuation with Swift's
            // CancellationError, matching `MCPClient.sendRequest`'s parity handling — if the
            // response already arrived, `failPending` finds no entry and no-ops, preserving
            // single-resume.
            Task { [self] in await self.failPending(id: id, error: CancellationError()) }
        }
    }

    /// Strips control characters and caps the length of a field the (unauthenticated,
    /// user-configured) remote bridge self-reports in its `initialize` response — `serverInfo`'s
    /// `name`/`version` flow straight into a `LogCenter` line and the Settings UI's "Connected to
    /// …" label, so a hostile or malformed bridge shouldn't be able to inject newlines/control
    /// characters or blow out either surface's layout with an unbounded string.
    private static func sanitize(_ value: String) -> String {
        let stripped = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String.UnicodeScalarView(stripped)).prefix(100).description
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
