import Testing
import Foundation
@testable import AnglesiteCore

/// `.serialized` so the one test that still spawns a real subprocess (`reconnectsAfterServerCrash`,
/// exercising `ProcessSupervisor`'s crash-detection and restart) doesn't contend for CPU with other
/// subprocess-spawning suites under `swift test --parallel`. See #609 / #610.
@Suite(.serialized)
struct MCPClientTests {
    /// In-process fake `MCPTransport` implementing `tools/list` / `tools/call` (stateless
    /// 2026-07-28 — no `initialize`; unknown methods, including the `server/discover` ready
    /// probe, get `-32601`, which the client accepts as proof of life) with no subprocess, no
    /// pipes, and no wall-clock dependency — responses are yielded synchronously from `send(_:)`.
    /// This is the event-driven fix #609 asked for: the CI flake was CPU contention delaying a
    /// real python3 interpreter's startup past a fixed timeout, and the fix is to not depend on
    /// process scheduling at all for tests that aren't actually exercising subprocess behavior.
    ///
    /// Every request must carry the per-request `_meta` envelope — the fake rejects requests
    /// without it, so a regression that drops the envelope fails these tests.
    private actor FakeMCPServerTransport: MCPTransport {
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
            guard case .object(let obj) = message, case .string(let method)? = obj["method"] else { return }
            guard case .int(let id)? = obj["id"] else { return }  // notifications get no response
            // Stateless spec: every request carries the _meta envelope with the protocol version.
            guard case .object(let params)? = obj["params"],
                  case .object(let meta)? = params["_meta"],
                  case .string? = meta["io.modelcontextprotocol/protocolVersion"]
            else {
                continuation?.yield(errorResponse(id: id, code: -32602, message: "missing _meta envelope"))
                return
            }
            switch method {
            case "tools/list":
                continuation?.yield(.object([
                    "jsonrpc": .string("2.0"),
                    "id": .int(id),
                    "result": .object(["tools": .array([
                        .object([
                            "name": .string("echo"),
                            "description": .string("Echoes back"),
                            "inputSchema": .object([
                                "type": .string("object"),
                                "properties": .object(["text": .object(["type": .string("string")])]),
                            ]),
                        ]),
                    ])]),
                ]))
            case "tools/call":
                if case .string(let name)? = params["name"], name == "needs-input" {
                    // MRTR interim result: a flow this client doesn't drive — must throw.
                    continuation?.yield(.object([
                        "jsonrpc": .string("2.0"),
                        "id": .int(id),
                        "result": .object([
                            "resultType": .string("input_required"),
                            "inputRequests": .array([]),
                        ]),
                    ]))
                    return
                }
                guard case .string(let name)? = params["name"], name == "echo" else {
                    continuation?.yield(errorResponse(id: id, code: -32601, message: "unknown tool"))
                    return
                }
                let text: String = {
                    if case .object(let args)? = params["arguments"], case .string(let t)? = args["text"] { return t }
                    return ""
                }()
                continuation?.yield(.object([
                    "jsonrpc": .string("2.0"),
                    "id": .int(id),
                    "result": .object([
                        "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                        "isError": .bool(false),
                    ]),
                ]))
            default:
                continuation?.yield(errorResponse(id: id, code: -32601, message: "method not found"))
            }
        }

        private func errorResponse(id: Int, code: Int, message: String) -> JSONValue {
            .object([
                "jsonrpc": .string("2.0"),
                "id": .int(id),
                "error": .object(["code": .int(code), "message": .string(message)]),
            ])
        }
    }

    /// Fake server advertising an `apply_edit` tool with a deliberately narrow `op` enum in its
    /// `inputSchema` — mirrors what a real sidecar's zod-derived JSON Schema looks like (#1415) —
    /// so `MCPClient.callTool`'s client-side op-support gate has something real to check against.
    /// Never actually applies anything; `tools/call` just echoes success for any op the schema
    /// admits, since these tests only exercise the gate, not `apply-edit-dispatcher.mjs`.
    private actor FakeApplyEditServerTransport: MCPTransport {
        private var continuation: AsyncStream<JSONValue>.Continuation?
        private let stream: AsyncStream<JSONValue>
        static let supportedOps = ["replace-text", "replace-attr"]

        init() {
            var cont: AsyncStream<JSONValue>.Continuation!
            stream = AsyncStream { cont = $0 }
            continuation = cont
        }

        func open() async throws {}
        nonisolated func inbound() -> AsyncStream<JSONValue> { stream }
        func close() async { continuation?.finish() }

        func send(_ message: JSONValue) async throws {
            guard case .object(let obj) = message, case .string(let method)? = obj["method"] else { return }
            guard case .int(let id)? = obj["id"] else { return }
            switch method {
            case "tools/list":
                continuation?.yield(.object([
                    "jsonrpc": .string("2.0"),
                    "id": .int(id),
                    "result": .object(["tools": .array([
                        .object([
                            "name": .string("apply_edit"),
                            "description": .string("Applies a structured edit"),
                            "inputSchema": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "op": .object([
                                        "type": .string("string"),
                                        "enum": .array(Self.supportedOps.map { .string($0) }),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ])]),
                ]))
            case "tools/call":
                continuation?.yield(.object([
                    "jsonrpc": .string("2.0"),
                    "id": .int(id),
                    "result": .object([
                        "content": .array([.object(["type": .string("text"), "text": .string("applied")])]),
                        "isError": .bool(false),
                    ]),
                ]))
            default:
                continuation?.yield(.object([
                    "jsonrpc": .string("2.0"),
                    "id": .int(id),
                    "error": .object(["code": .int(-32601), "message": .string("method not found")]),
                ]))
            }
        }
    }

    /// Fake server that handles one `crash` tool call (responds, then `exit(1)`) so the supervisor
    /// restarts it. The fresh instance behaves like the standard fake server. Lets us exercise
    /// reconnect — genuinely needs a real subprocess since it tests `ProcessSupervisor`'s
    /// crash-detection and restart, not just JSON-RPC request/response shape. Stateless: no
    /// `initialize` branch — the client's `server/discover` ready probe falls to the `-32601`
    /// method-not-found reply, which the client accepts as proof of life.
    private static let crashOnceServerScript = """
    import sys, json
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except Exception:
            continue
        method = msg.get("method", "")
        rid = msg.get("id")
        if rid is None:
            continue
        if method == "tools/list":
            resp = {"jsonrpc":"2.0","id":rid,"result":{"tools":[{"name":"echo","description":"Echoes back","inputSchema":{"type":"object"}}]}}
        elif method == "tools/call":
            params = msg.get("params", {})
            name = params.get("name")
            args = params.get("arguments", {}) or {}
            if name == "crash":
                sys.stdout.write(json.dumps({"jsonrpc":"2.0","id":rid,"result":{"content":[{"type":"text","text":"crashing"}],"isError":False}}) + chr(10))
                sys.stdout.flush()
                sys.exit(1)
            elif name == "echo":
                resp = {"jsonrpc":"2.0","id":rid,"result":{"content":[{"type":"text","text":args.get("text","")}],"isError":False}}
            else:
                resp = {"jsonrpc":"2.0","id":rid,"error":{"code":-32601,"message":"unknown tool"}}
        else:
            resp = {"jsonrpc":"2.0","id":rid,"error":{"code":-32601,"message":"method not found"}}
        sys.stdout.write(json.dumps(resp) + chr(10))
        sys.stdout.flush()
    """

    /// Timeout for the one test that still spawns a real python3 subprocess — matches the
    /// already-proven precedent from `AppliesEditEndToEndTests`/`ComponentModelEndToEndTests`
    /// (heavier real-Node-server startup) rather than introducing a new number.
    private static let realSubprocessReadyTimeout: TimeInterval = 15

    private static let pythonURL: URL = {
        for path in ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/opt/anaconda3/bin/python3"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return URL(fileURLWithPath: "/usr/bin/python3")
    }()

    private func makeFakeClient() async throws -> (MCPClient, FakeMCPServerTransport) {
        let transport = FakeMCPServerTransport()
        let client = MCPClient(supervisor: .shared)
        try await client.startWithTransport(transport, readyTimeout: 5, clientName: "test", clientVersion: "0")
        return (client, transport)
    }

    @Test("Start probes the server and reports running") func startProbesAndReportsRunning() async throws {
        let (client, _) = try await makeFakeClient()
        let running = await client.isRunning
        #expect(running)
        await client.stop()
        let runningAfter = await client.isRunning
        #expect(!runningAfter)
    }

    @Test("List tools returns server tool definitions") func listToolsReturnsServerToolDefinitions() async throws {
        let (client, _) = try await makeFakeClient()
        defer { Task { await client.stop() } }

        let tools = try await client.listTools()
        #expect(tools.count == 1)
        #expect(tools.first?.name == "echo")
        #expect(tools.first?.description == "Echoes back")
        #expect(tools.first?.inputSchema != nil)
    }

    @Test("Call tool returns text content") func callToolReturnsTextContent() async throws {
        let (client, _) = try await makeFakeClient()
        defer { Task { await client.stop() } }

        let result = try await client.callTool(
            name: "echo",
            arguments: .object(["text": .string("hello")])
        )
        #expect(result.isError == false)
        #expect(result.content.count == 1)
        #expect(result.content.first?.type == "text")
        #expect(result.content.first?.text == "hello")
    }

    @Test("Call tool unknown returns RPC error") func callToolUnknownReturnsRPCError() async throws {
        let (client, _) = try await makeFakeClient()
        defer { Task { await client.stop() } }

        await #expect(throws: MCPClient.MCPError.rpcError(code: -32601, message: "unknown tool")) {
            _ = try await client.callTool(name: "does-not-exist")
        }
    }

    @Test("An input_required result throws invalidResponse") func inputRequiredResultThrows() async throws {
        let (client, _) = try await makeFakeClient()
        defer { Task { await client.stop() } }

        await #expect(throws: MCPClient.MCPError.invalidResponse("unsupported resultType 'input_required'")) {
            _ = try await client.callTool(name: "needs-input")
        }
    }

    @Test("Call tool before start throws not initialized") func callToolBeforeStartThrowsNotInitialized() async throws {
        let client = MCPClient(supervisor: .shared)
        await #expect(throws: MCPClient.MCPError.notInitialized) {
            _ = try await client.callTool(name: "echo")
        }
    }

    // MARK: apply_edit op-support gate (#1415)

    @Test("apply_edit call for an op missing from the advertised schema throws unsupportedOp")
    func applyEditUnadvertisedOpThrowsUnsupportedOp() async throws {
        let transport = FakeApplyEditServerTransport()
        let client = MCPClient(supervisor: .shared)
        try await client.startWithTransport(transport, readyTimeout: 5, clientName: "test", clientVersion: "0")
        defer { Task { await client.stop() } }

        // "insert-image" isn't in FakeApplyEditServerTransport.supportedOps — mirrors #1415's
        // stale-vendored-image repro, where the app sent an op the sidecar's schema didn't know.
        await #expect(throws: MCPClient.MCPError.unsupportedOp(op: "insert-image")) {
            _ = try await client.callTool(name: "apply_edit", arguments: .object(["op": .string("insert-image")]))
        }
    }

    @Test("apply_edit call for an op present in the advertised schema goes through")
    func applyEditAdvertisedOpSucceeds() async throws {
        let transport = FakeApplyEditServerTransport()
        let client = MCPClient(supervisor: .shared)
        try await client.startWithTransport(transport, readyTimeout: 5, clientName: "test", clientVersion: "0")
        defer { Task { await client.stop() } }

        let result = try await client.callTool(name: "apply_edit", arguments: .object(["op": .string("replace-text")]))
        #expect(result.isError == false)
        #expect(result.content.first?.text == "applied")
    }

    @Test("apply_edit call fails open when the server doesn't advertise an apply_edit tool")
    func applyEditFailsOpenWithoutSchema() async throws {
        // Reuses the plain echo-only fake — no `apply_edit` tool in its tools/list at all, e.g. a
        // very old sidecar predating this check. The gate must not invent a refusal; it should let
        // the call through to the normal path, which then fails the ordinary way (unknown tool).
        let (client, _) = try await makeFakeClient()
        defer { Task { await client.stop() } }

        await #expect(throws: MCPClient.MCPError.rpcError(code: -32601, message: "unknown tool")) {
            _ = try await client.callTool(name: "apply_edit", arguments: .object(["op": .string("replace-text")]))
        }
    }

    // MARK: reconnect on crash

    @Test("Reconnects after server crash") func reconnectsAfterServerCrash() async throws {
        let client = MCPClient(supervisor: ProcessSupervisor())
        try await client.start(
            executable: Self.pythonURL,
            arguments: ["-u", "-c", Self.crashOnceServerScript],
            source: "mcp-reconnect",
            restartPolicy: .onCrash(maxAttempts: 3, baseBackoff: 0.05),
            readyTimeout: Self.realSubprocessReadyTimeout
        )
        defer { Task { await client.stop() } }

        // This call's response arrives, then the server exits(1) → supervisor restarts it.
        let crashResult = try await client.callTool(name: "crash")
        #expect(crashResult.content.first?.text == "crashing")

        // Fresh instance should answer normally — proves the client reconnected. Poll instead of
        // a fixed sleep: respawn + ready probe comfortably fits in a few hundred ms locally but
        // can take seconds on a loaded CI runner. .notInitialized / .reconnecting are the
        // documented transient errors during a supervised respawn; anything else is real.
        let tools = try await Self.listToolsAwaitingReconnect(client, timeout: Self.realSubprocessReadyTimeout)
        #expect(tools.first?.name == "echo")

        let echoed = try await client.callTool(name: "echo", arguments: .object(["text": .string("after-reconnect")]))
        #expect(echoed.content.first?.text == "after-reconnect")
    }

    private static func listToolsAwaitingReconnect(
        _ client: MCPClient,
        timeout: TimeInterval
    ) async throws -> [MCPClient.ToolDescriptor] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            do {
                return try await client.listTools()
            } catch MCPClient.MCPError.notInitialized, MCPClient.MCPError.reconnecting {
                guard Date() < deadline else { throw MCPClient.MCPError.timeout }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    // MARK: JSONValue round-trip

    @Test("JSON value round trip") func jSONValueRoundTrip() throws {
        let original: JSONValue = .object([
            "s": .string("hello"),
            "n": .int(42),
            "d": .double(3.14),
            "b": .bool(true),
            "z": .null,
            "a": .array([.int(1), .int(2)]),
            "o": .object(["nested": .string("value")]),
        ])
        let data = try JSONSerialization.data(withJSONObject: original.rawValue)
        let decoded = try JSONSerialization.jsonObject(with: data)
        let round = JSONValue.from(decoded)
        #expect(round == original)
    }
}
