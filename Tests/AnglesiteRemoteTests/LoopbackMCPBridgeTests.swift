import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteRemote

final class MCPMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { fatalError("no handler set") }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct LoopbackMCPBridgeTests {
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MCPMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private static func httpBodyAsData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            return data
        }
        return nil
    }

    @Test func requestGetsMatchingResponse() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MCPMockURLProtocol.self]
        MCPMockURLProtocol.handler = { request in
            let bodyData = Self.httpBodyAsData(request) ?? Data()
            let body = try! JSONSerialization.jsonObject(with: bodyData) as! [String: Any]
            let id = body["id"] as! Int
            let reply: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": ["ok": true]]
            let data = try! JSONSerialization.data(withJSONObject: reply)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                     headerFields: ["Content-Type": "application/json"])!, data)
        }
        let bridge = LoopbackMCPBridge(mcpURL: URL(string: "http://127.0.0.1:4399")!,
                                        urlSession: URLSession(configuration: config))
        let reply = await bridge.handle(.object([
            "jsonrpc": .string("2.0"), "id": .int(1), "method": .string("initialize"),
        ]))
        guard case let .object(fields)? = reply else {
            Issue.record("no reply"); return
        }
        guard case let .int(id)? = fields["id"] else {
            Issue.record("missing id"); return
        }
        #expect(id == 1)
    }

    @Test func notificationReturnsNilAndStillSends() async throws {
        var sawNotification = false
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MCPMockURLProtocol.self]
        MCPMockURLProtocol.handler = { request in
            sawNotification = true
            return (HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: [:])!, Data())
        }
        let bridge = LoopbackMCPBridge(mcpURL: URL(string: "http://127.0.0.1:4399")!,
                                        urlSession: URLSession(configuration: config))
        let reply = await bridge.handle(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/x")]))
        #expect(reply == nil)
        #expect(sawNotification)
    }

    /// A failed send for a *request* must not return `nil`: `MCPChannelResponder.run()` reads
    /// `nil` as "notification, send no reply", so the phone-side caller would wait on that request
    /// id forever. It gets a JSON-RPC error carrying its own id instead.
    @Test func sendFailureForRequestReturnsJSONRPCError() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailingProtocol.self]
        let bridge = LoopbackMCPBridge(mcpURL: URL(string: "http://127.0.0.1:1")!,
                                        urlSession: URLSession(configuration: config))
        let reply = await bridge.handle(.object([
            "jsonrpc": .string("2.0"), "id": .int(7), "method": .string("tools/call"),
        ]))
        guard case let .object(fields)? = reply else {
            Issue.record("send failure produced no reply at all"); return
        }
        #expect(fields["id"] == .int(7))
        #expect(fields["jsonrpc"] == .string("2.0"))
        #expect(fields["result"] == nil)
        guard case let .object(error)? = fields["error"] else {
            Issue.record("reply carried no error object: \(String(describing: fields))"); return
        }
        #expect(error["code"] == .int(-32000))
        guard case let .string(message)? = error["message"] else {
            Issue.record("error carried no message"); return
        }
        #expect(message.contains("send failed"))
    }

    /// A notification whose send fails still has no reply to give — only requests get one.
    @Test func sendFailureForNotificationStillReturnsNil() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailingProtocol.self]
        let bridge = LoopbackMCPBridge(mcpURL: URL(string: "http://127.0.0.1:1")!,
                                        urlSession: URLSession(configuration: config))
        let reply = await bridge.handle(.object([
            "jsonrpc": .string("2.0"), "method": .string("notifications/x"),
        ]))
        #expect(reply == nil)
    }

    /// An empty (or undecodable) 200 makes `HTTPTransport.send` yield nothing into `inbound()`,
    /// so the read that follows it used to block forever — wedging not just this request but the
    /// whole `mcp` channel, since `MCPChannelResponder.run()` is strictly sequential. The bounded
    /// read turns that into a prompt error reply. The tight `responseTimeout` keeps this test
    /// fast; the deadline assertion is what proves it didn't hang.
    @Test func missingResponseTimesOutInsteadOfHanging() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MCPMockURLProtocol.self]
        MCPMockURLProtocol.handler = { request in
            // 200 with an empty body: nothing decodable to yield.
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                             headerFields: ["Content-Type": "application/json"])!, Data())
        }
        let bridge = LoopbackMCPBridge(mcpURL: URL(string: "http://127.0.0.1:4399")!,
                                        urlSession: URLSession(configuration: config),
                                        responseTimeout: .milliseconds(200))
        let started = ContinuousClock.now
        let reply = await bridge.handle(.object([
            "jsonrpc": .string("2.0"), "id": .string("abc"), "method": .string("tools/list"),
        ]))
        let elapsed = ContinuousClock.now - started
        #expect(elapsed < .seconds(10), "the bridge hung instead of timing out")
        guard case let .object(fields)? = reply else {
            Issue.record("timed-out request produced no reply at all"); return
        }
        // String ids are replayed verbatim — JSON-RPC allows them, and the caller correlates on it.
        #expect(fields["id"] == .string("abc"))
        guard case let .object(error)? = fields["error"] else {
            Issue.record("reply carried no error object: \(String(describing: fields))"); return
        }
        #expect(error["code"] == .int(-32000))
    }
}
