import Testing
import Foundation
@testable import AnglesiteCore

/// A dedicated `URLProtocol` stub for these tests — modeled on `HTTPTransportTests.swift`'s
/// `StubURLProtocol` (and `ACPHTTPTransportTests.swift`'s `ACPStubURLProtocol`) but a separate
/// type/instance so this suite's per-test queue mutations can never race with those suites',
/// even though Swift Testing can run all three concurrently (each is independently `.serialized`,
/// which only serializes tests *within* a suite, not across suites — see
/// `Tests/AnglesiteCoreTests/ACPHTTPTransportTests.swift:5-8`'s identical rationale).
final class SafariMCPBridgeClientStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response { let status: Int; let headers: [String: String]; let body: Data }
    nonisolated(unsafe) static var queue: [Response] = []
    nonisolated(unsafe) static var lastSessionHeaders: [String?] = []

    static func reset() { queue = []; lastSessionHeaders = [] }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastSessionHeaders.append(request.value(forHTTPHeaderField: "Mcp-Session-Id"))
        let r = Self.queue.isEmpty ? Response(status: 500, headers: [:], body: Data()) : Self.queue.removeFirst()
        let http = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        if !r.body.isEmpty { client?.urlProtocol(self, didLoad: r.body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct SafariMCPBridgeClientTests {
    private func makeClient(logCenter: LogCenter = LogCenter()) -> (SafariMCPBridgeClient, URLSession) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SafariMCPBridgeClientStubURLProtocol.self]
        let session = URLSession(configuration: config)
        let client = SafariMCPBridgeClient(
            endpoint: URL(string: "http://127.0.0.1:4399/mcp")!,
            urlSession: session,
            logCenter: logCenter
        )
        return (client, session)
    }

    @Test("connect sends a real initialize request and decodes serverInfo") func connectDecodesServerInfo() async throws {
        SafariMCPBridgeClientStubURLProtocol.reset()
        SafariMCPBridgeClientStubURLProtocol.queue.append(.init(
            status: 200,
            headers: ["Content-Type": "application/json", "Mcp-Session-Id": "sess-1"],
            body: #"""
            {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"Safari","version":"1.0.0"}}}
            """#.data(using: .utf8)!
        ))
        SafariMCPBridgeClientStubURLProtocol.queue.append(.init(status: 202, headers: [:], body: Data()))  // notifications/initialized

        let logCenter = LogCenter()
        let (client, _) = makeClient(logCenter: logCenter)
        let info = try await client.connect(timeout: 10)
        #expect(info == SafariMCPBridgeClient.ServerInfo(name: "Safari", version: "1.0.0", protocolVersion: "2024-11-05"))

        // The initialize request itself must never send MCP-Protocol-Version, and the id=1
        // request must have no session header yet. [String?].first returns Optional<Optional<String>>,
        // so compare against the array directly.
        #expect(!SafariMCPBridgeClientStubURLProtocol.lastSessionHeaders.isEmpty && SafariMCPBridgeClientStubURLProtocol.lastSessionHeaders[0] == nil)

        let logged = await logCenter.snapshot()
        #expect(logged.contains { $0.source == "safari-mcp" && $0.stream == .stdout && $0.text.contains("Safari") })
        await client.close()
    }

    @Test("listTools decodes the tools array") func listToolsDecodes() async throws {
        SafariMCPBridgeClientStubURLProtocol.reset()
        SafariMCPBridgeClientStubURLProtocol.queue.append(.init(
            status: 200,
            headers: ["Content-Type": "application/json", "Mcp-Session-Id": "sess-1"],
            body: #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","serverInfo":{"name":"Safari"}}}"#.data(using: .utf8)!
        ))
        SafariMCPBridgeClientStubURLProtocol.queue.append(.init(status: 202, headers: [:], body: Data()))
        SafariMCPBridgeClientStubURLProtocol.queue.append(.init(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: #"{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"browser_console_messages","description":"Read console"}]}}"#.data(using: .utf8)!
        ))

        let (client, _) = makeClient()
        _ = try await client.connect(timeout: 10)
        let tools = try await client.listTools()
        #expect(tools == [.init(name: "browser_console_messages", description: "Read console")])
        await client.close()
    }

    @Test("a JSON-RPC error response surfaces as ClientError.rpcError") func rpcErrorSurfaces() async throws {
        SafariMCPBridgeClientStubURLProtocol.reset()
        SafariMCPBridgeClientStubURLProtocol.queue.append(.init(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: #"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"nope"}}"#.data(using: .utf8)!
        ))
        let (client, _) = makeClient()
        do {
            _ = try await client.connect(timeout: 10)
            Issue.record("expected ClientError.rpcError to be thrown")
        } catch SafariMCPBridgeClient.ClientError.rpcError(let code, let message) {
            #expect(code == -32000)
            #expect(message == "nope")
        }
        await client.close()
    }

    @Test("connection failure logs to LogCenter and rethrows") func connectionFailureLogs() async throws {
        SafariMCPBridgeClientStubURLProtocol.reset()
        // Empty queue -> the stub answers 500 by default.
        let logCenter = LogCenter()
        let (client, _) = makeClient(logCenter: logCenter)
        await #expect(throws: (any Error).self) {
            _ = try await client.connect(timeout: 10)
        }
        let logged = await logCenter.snapshot()
        #expect(logged.contains { $0.source == "safari-mcp" && $0.stream == .stderr })
        await client.close()
    }

    @Test("callTool decodes text and image content blocks") func callToolDecodesContent() async throws {
        SafariMCPBridgeClientStubURLProtocol.reset()
        SafariMCPBridgeClientStubURLProtocol.queue.append(.init(
            status: 200,
            headers: ["Content-Type": "application/json", "Mcp-Session-Id": "sess-1"],
            body: #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","serverInfo":{"name":"Safari"}}}"#.data(using: .utf8)!
        ))
        SafariMCPBridgeClientStubURLProtocol.queue.append(.init(status: 202, headers: [:], body: Data()))
        SafariMCPBridgeClientStubURLProtocol.queue.append(.init(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: #"""
            {"jsonrpc":"2.0","id":2,"result":{"isError":false,"content":[
              {"type":"text","text":"hello"},
              {"type":"image","data":"YWJj","mimeType":"image/png"}
            ]}}
            """#.data(using: .utf8)!
        ))

        let (client, _) = makeClient()
        _ = try await client.connect(timeout: 10)
        let result = try await client.callTool(name: "get_page_content")
        #expect(result.content == [
            .init(type: "text", text: "hello", data: nil, mimeType: nil),
            .init(type: "image", text: nil, data: "YWJj", mimeType: "image/png"),
        ])
        await client.close()
    }

    @Test("callTool throws ClientError.toolError when isError is true") func callToolSurfacesToolError() async throws {
        SafariMCPBridgeClientStubURLProtocol.reset()
        SafariMCPBridgeClientStubURLProtocol.queue.append(.init(
            status: 200,
            headers: ["Content-Type": "application/json", "Mcp-Session-Id": "sess-1"],
            body: #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","serverInfo":{"name":"Safari"}}}"#.data(using: .utf8)!
        ))
        SafariMCPBridgeClientStubURLProtocol.queue.append(.init(status: 202, headers: [:], body: Data()))
        SafariMCPBridgeClientStubURLProtocol.queue.append(.init(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: #"""
            {"jsonrpc":"2.0","id":2,"result":{"isError":true,"content":[{"type":"text","text":"boom"}]}}
            """#.data(using: .utf8)!
        ))

        let (client, _) = makeClient()
        _ = try await client.connect(timeout: 10)
        do {
            _ = try await client.callTool(name: "navigate_to_url")
            Issue.record("expected ClientError.toolError to be thrown")
        } catch SafariMCPBridgeClient.ClientError.toolError(let message) {
            #expect(message == "boom")
        }
        await client.close()
    }

    @Test("callTool replays the captured Mcp-Session-Id") func callToolReplaysSessionID() async throws {
        SafariMCPBridgeClientStubURLProtocol.reset()
        SafariMCPBridgeClientStubURLProtocol.queue.append(.init(
            status: 200,
            headers: ["Content-Type": "application/json", "Mcp-Session-Id": "sess-77"],
            body: #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","serverInfo":{"name":"Safari"}}}"#.data(using: .utf8)!
        ))
        SafariMCPBridgeClientStubURLProtocol.queue.append(.init(status: 202, headers: [:], body: Data()))
        SafariMCPBridgeClientStubURLProtocol.queue.append(.init(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: #"{"jsonrpc":"2.0","id":2,"result":{"isError":false,"content":[]}}"#.data(using: .utf8)!
        ))

        let (client, _) = makeClient()
        _ = try await client.connect(timeout: 10)
        _ = try await client.callTool(name: "get_page_content")
        #expect(SafariMCPBridgeClientStubURLProtocol.lastSessionHeaders.last == "sess-77")
        await client.close()
    }
}
