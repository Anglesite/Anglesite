import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteRemote

@Suite(.serialized) struct LoopbackMCPBridgeTests {
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
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
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { request in
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
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { request in
            sawNotification = true
            return (HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: [:])!, Data())
        }
        let bridge = LoopbackMCPBridge(mcpURL: URL(string: "http://127.0.0.1:4399")!,
                                        urlSession: URLSession(configuration: config))
        let reply = await bridge.handle(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/x")]))
        #expect(reply == nil)
        #expect(sawNotification)
    }
}
