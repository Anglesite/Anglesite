import Testing
import Foundation
@testable import AnglesiteCore

/// A dedicated `URLProtocol` stub for these tests — same rationale as
/// `SafariMCPBridgeClientStubURLProtocol` (Task 2): a separate type/instance so this suite can
/// never race with `SafariMCPBridgeClientTests` (or any other suite's stub) when Swift Testing
/// runs suites concurrently. See `Tests/AnglesiteCoreTests/ACPHTTPTransportTests.swift:5-8`.
final class SafariMCPBridgeDetectorStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response { let status: Int; let headers: [String: String]; let body: Data }
    nonisolated(unsafe) static var queue: [Response] = []

    static func reset() { queue = [] }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let r = Self.queue.isEmpty ? Response(status: 500, headers: [:], body: Data()) : Self.queue.removeFirst()
        let http = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        if !r.body.isEmpty { client?.urlProtocol(self, didLoad: r.body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct SafariMCPBridgeDetectorTests {
    private func makeDetector() -> (SafariMCPBridgeDetector, URLSession) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SafariMCPBridgeDetectorStubURLProtocol.self]
        let session = URLSession(configuration: config)
        return (SafariMCPBridgeDetector(urlSession: session, logCenter: LogCenter()), session)
    }

    @Test("a reachable bridge reports .reachable with the server name") func reachable() async throws {
        SafariMCPBridgeDetectorStubURLProtocol.reset()
        SafariMCPBridgeDetectorStubURLProtocol.queue.append(.init(
            status: 200,
            headers: ["Content-Type": "application/json", "Mcp-Session-Id": "sess-1"],
            body: #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","serverInfo":{"name":"Safari"}}}"#.data(using: .utf8)!
        ))
        SafariMCPBridgeDetectorStubURLProtocol.queue.append(.init(status: 202, headers: [:], body: Data()))
        let (detector, _) = makeDetector()
        let status = await detector.checkReachability(port: 8931)
        #expect(status == SafariMCPBridgeStatus(state: .reachable(serverName: "Safari"), port: 8931))
    }

    @Test("an unreachable port reports .unreachable") func unreachable() async throws {
        SafariMCPBridgeDetectorStubURLProtocol.reset()  // empty queue -> 500 from every request
        let (detector, _) = makeDetector()
        let status = await detector.checkReachability(port: 8931)
        #expect(status == SafariMCPBridgeStatus(state: .unreachable, port: 8931))
    }
}
