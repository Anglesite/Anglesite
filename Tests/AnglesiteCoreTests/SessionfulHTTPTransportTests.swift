import Testing
import Foundation
@testable import AnglesiteCore

/// A dedicated `URLProtocol` stub for these tests — modeled on `StubURLProtocol`
/// (`HTTPTransportTests.swift`) but a separate type/instance so this suite's per-test queue
/// mutations can never race with that suite's, even though both can run concurrently.
final class SessionfulStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response {
        let status: Int
        let headers: [String: String]
        let body: Data
    }
    nonisolated(unsafe) static var queue: [Response] = []
    nonisolated(unsafe) static var lastSessionHeaders: [String?] = []
    nonisolated(unsafe) static var lastProtocolVersionHeaders: [String?] = []

    static func reset() { queue = []; lastSessionHeaders = []; lastProtocolVersionHeaders = [] }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastSessionHeaders.append(request.value(forHTTPHeaderField: "Mcp-Session-Id"))
        Self.lastProtocolVersionHeaders.append(request.value(forHTTPHeaderField: "MCP-Protocol-Version"))
        let r = Self.queue.isEmpty ? Response(status: 500, headers: [:], body: Data()) : Self.queue.removeFirst()
        let http = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        if !r.body.isEmpty { client?.urlProtocol(self, didLoad: r.body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct SessionfulHTTPTransportTests {
    private func makeTransport() -> (SessionfulHTTPTransport, URLSession) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SessionfulStubURLProtocol.self]
        let session = URLSession(configuration: config)
        let t = SessionfulHTTPTransport(endpoint: URL(string: "http://127.0.0.1:4399/mcp")!, urlSession: session)
        return (t, session)
    }

    @Test("initialize response's Mcp-Session-Id is captured and replayed on the next request")
    func sessionIDCapturedAndReplayed() async throws {
        SessionfulStubURLProtocol.reset()
        SessionfulStubURLProtocol.queue.append(.init(
            status: 200,
            headers: ["Content-Type": "application/json", "Mcp-Session-Id": "sess-42"],
            body: #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05"}}"#.data(using: .utf8)!
        ))
        SessionfulStubURLProtocol.queue.append(.init(
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

        #expect(SessionfulStubURLProtocol.lastSessionHeaders == [nil, "sess-42"])
        await t.close()
    }

    @Test("MCP-Protocol-Version header is never sent") func noProtocolVersionHeader() async throws {
        SessionfulStubURLProtocol.reset()
        SessionfulStubURLProtocol.queue.append(.init(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: #"{"jsonrpc":"2.0","id":1,"result":{}}"#.data(using: .utf8)!
        ))
        let (t, _) = makeTransport()
        try await t.open()
        try await t.send(.object(["jsonrpc": .string("2.0"), "id": .int(1), "method": .string("initialize")]))
        #expect(SessionfulStubURLProtocol.lastProtocolVersionHeaders == [nil])
        await t.close()
    }

    @Test("SSE response is parsed into a message") func sseResponse() async throws {
        SessionfulStubURLProtocol.reset()
        SessionfulStubURLProtocol.queue.append(.init(
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
        SessionfulStubURLProtocol.reset()
        SessionfulStubURLProtocol.queue.append(.init(status: 202, headers: [:], body: Data()))
        let (t, _) = makeTransport()
        try await t.open()
        try await t.send(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")]))
        await t.close()
        var iterator = t.inbound().makeAsyncIterator()
        let next = await iterator.next()
        #expect(next == nil)
    }

    @Test("Non-2xx/202 status throws HTTPError.http") func httpErrorStatus() async throws {
        SessionfulStubURLProtocol.reset()
        SessionfulStubURLProtocol.queue.append(.init(status: 500, headers: [:], body: Data()))
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
