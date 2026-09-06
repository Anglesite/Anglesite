import Testing
import Foundation
@testable import AnglesiteCore

/// A URLProtocol that answers each POST to /mcp from a queue of canned responses, so HTTPTransport
/// is tested without a real server. Responses are matched in FIFO order.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response { let status: Int; let headers: [String: String]; let body: Data }
    nonisolated(unsafe) static var queue: [Response] = []
    nonisolated(unsafe) static var lastRequestBodies: [Data] = []
    nonisolated(unsafe) static var lastSessionHeaders: [String?] = []
    nonisolated(unsafe) static var lastAuthHeaders: [String?] = []
    nonisolated(unsafe) static var lastMethodHeaders: [String?] = []
    nonisolated(unsafe) static var lastNameHeaders: [String?] = []

    static func reset() {
        queue = []; lastRequestBodies = []; lastSessionHeaders = []; lastAuthHeaders = []
        lastMethodHeaders = []; lastNameHeaders = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // URLSession strips httpBody for custom protocols unless read via stream; capture both.
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
            Self.lastRequestBodies.append(data)
        } else {
            Self.lastRequestBodies.append(request.httpBody ?? Data())
        }
        Self.lastSessionHeaders.append(request.value(forHTTPHeaderField: "Mcp-Session-Id"))
        Self.lastAuthHeaders.append(request.value(forHTTPHeaderField: "Authorization"))
        Self.lastMethodHeaders.append(request.value(forHTTPHeaderField: "Mcp-Method"))
        Self.lastNameHeaders.append(request.value(forHTTPHeaderField: "Mcp-Name"))

        let r = Self.queue.isEmpty
            ? Response(status: 500, headers: [:], body: Data())
            : Self.queue.removeFirst()
        let http = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        if !r.body.isEmpty { client?.urlProtocol(self, didLoad: r.body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct HTTPTransportTests {
    private func makeTransport(bearerToken: SessionToken? = nil) -> (HTTPTransport, URLSession) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        let t = HTTPTransport(endpoint: URL(string: "http://127.0.0.1:4399/mcp")!, bearerToken: bearerToken, urlSession: session)
        return (t, session)
    }

    @Test("JSON response is decoded and yielded; requests are stateless with method headers")
    func jsonResponseStateless() async throws {
        StubURLProtocol.reset()
        // A server-sent session header must be ignored — stateless clients never replay one.
        StubURLProtocol.queue.append(.init(
            status: 200,
            headers: ["Content-Type": "application/json", "Mcp-Session-Id": "sess-1"],
            body: #"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#.data(using: .utf8)!
        ))
        StubURLProtocol.queue.append(.init(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: #"{"jsonrpc":"2.0","id":2,"result":{"again":true}}"#.data(using: .utf8)!
        ))

        let (t, _) = makeTransport()
        try await t.open()
        var iterator = t.inbound().makeAsyncIterator()

        try await t.send(.object(["jsonrpc": .string("2.0"), "id": .int(1), "method": .string("tools/list")]))
        let first = await iterator.next()
        #expect(first == .object(["jsonrpc": .string("2.0"), "id": .int(1), "result": .object(["ok": .bool(true)])]))

        try await t.send(.object([
            "jsonrpc": .string("2.0"), "id": .int(2), "method": .string("tools/call"),
            "params": .object(["name": .string("echo")]),
        ]))
        _ = await iterator.next()

        // No Mcp-Session-Id is ever sent — not even after the server offered one.
        #expect(StubURLProtocol.lastSessionHeaders == [nil, nil])
        #expect(StubURLProtocol.lastMethodHeaders == ["tools/list", "tools/call"])
        #expect(StubURLProtocol.lastNameHeaders == [nil, "echo"])
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
        try await t.send(.object(["jsonrpc": .string("2.0"), "id": .int(7), "method": .string("tools/list")]))
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

    @Test("Authorization header sent when bearerToken is set") func authHeaderWithToken() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.queue.append(.init(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: #"{"jsonrpc":"2.0","id":1,"result":{}}"#.data(using: .utf8)!
        ))
        let token = SessionToken(value: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890ab")
        let (t, _) = makeTransport(bearerToken: token)
        try await t.open()
        try await t.send(.object(["jsonrpc": .string("2.0"), "id": .int(1), "method": .string("tools/list")]))
        #expect(StubURLProtocol.lastAuthHeaders == ["Bearer \(token.value)"])
        await t.close()
    }

    @Test("No Authorization header when bearerToken is nil") func noAuthHeaderWithoutToken() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.queue.append(.init(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: #"{"jsonrpc":"2.0","id":1,"result":{}}"#.data(using: .utf8)!
        ))
        let (t, _) = makeTransport()
        try await t.open()
        try await t.send(.object(["jsonrpc": .string("2.0"), "id": .int(1), "method": .string("tools/list")]))
        #expect(StubURLProtocol.lastAuthHeaders == [nil])
        await t.close()
    }

    @Test("400 with a session-shaped JSON-RPC error is recognized as a stale sidecar")
    func staleSidecar400IsDetected() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.queue.append(.init(
            status: 400,
            headers: ["Content-Type": "application/json"],
            body: #"{"jsonrpc":"2.0","error":{"code":-32000,"message":"Bad Request: Server not initialized"},"id":null}"#.data(using: .utf8)!
        ))
        let (t, _) = makeTransport()
        try await t.open()
        do {
            try await t.send(.object(["jsonrpc": .string("2.0"), "id": .int(1), "method": .string("server/discover")]))
            Issue.record("expected HTTPError.staleSidecarProtocol to be thrown")
        } catch HTTPTransport.HTTPError.staleSidecarProtocol(let detail) {
            #expect(detail == "Bad Request: Server not initialized")
        }
        await t.close()
    }

    @Test("400 with an unrelated JSON-RPC error stays a plain HTTP error")
    func unrelated400StaysPlain() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.queue.append(.init(
            status: 400,
            headers: ["Content-Type": "application/json"],
            body: #"{"jsonrpc":"2.0","error":{"code":-32600,"message":"Invalid Request"},"id":null}"#.data(using: .utf8)!
        ))
        let (t, _) = makeTransport()
        try await t.open()
        do {
            try await t.send(.object(["jsonrpc": .string("2.0"), "id": .int(1), "method": .string("server/discover")]))
            Issue.record("expected HTTPError.http(status: 400) to be thrown")
        } catch HTTPTransport.HTTPError.http(let status) {
            #expect(status == 400)
        }
        await t.close()
    }

    @Test("MCPClient.connect surfaces a stale-sidecar 400 as MCPError.staleSidecarProtocol and logs it")
    func staleSidecarSurfacesFromConnect() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.queue.append(.init(
            status: 400,
            headers: ["Content-Type": "application/json"],
            body: #"{"jsonrpc":"2.0","error":{"code":-32000,"message":"Bad Request: No valid session ID provided"},"id":null}"#.data(using: .utf8)!
        ))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        let logCenter = LogCenter()
        let client = MCPClient(supervisor: ProcessSupervisor(), logCenter: logCenter)

        do {
            try await client.connect(httpEndpoint: URL(string: "http://127.0.0.1:4399/mcp")!, urlSession: session)
            Issue.record("expected connect() to throw")
        } catch MCPClient.MCPError.staleSidecarProtocol(let detail) {
            #expect(detail == "Bad Request: No valid session ID provided")
        }

        let logged = await logCenter.snapshot()
        #expect(logged.contains { $0.source == "mcp" && $0.stream == .stderr && $0.text.contains("#1277") })
    }

    @Test("MCPClient.connect probes and lists tools over HTTP") func clientOverHTTP() async throws {
        StubURLProtocol.reset()
        // server/discover ready-probe response (resultType per 2026-07-28)
        StubURLProtocol.queue.append(.init(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: #"{"jsonrpc":"2.0","id":1,"result":{"supportedVersions":["2026-07-28"],"capabilities":{"tools":{}},"resultType":"complete"}}"#.data(using: .utf8)!
        ))
        // tools/list response
        StubURLProtocol.queue.append(.init(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: #"{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"echo","description":"E","inputSchema":{"type":"object"}}],"resultType":"complete","ttlMs":0,"cacheScope":"private"}}"#.data(using: .utf8)!
        ))

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)

        let client = MCPClient(supervisor: ProcessSupervisor(), logCenter: LogCenter())
        try await client.connect(httpEndpoint: URL(string: "http://127.0.0.1:4399/mcp")!, urlSession: session)
        let tools = try await client.listTools()
        #expect(tools.first?.name == "echo")
        await client.stop()
    }
}
