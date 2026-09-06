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
        #expect(StubURLProtocol.lastProtocolVersionHeaders == [nil])
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
