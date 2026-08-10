import Testing
import Foundation
import AnglesiteP2P
@testable import AnglesiteRemote

final class MockURLProtocol: URLProtocol {
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

@Suite(.serialized) struct LoopbackHTTPExecutorTests {
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    @Test func forwardsMethodPathAndHeaders() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.handler = { request in
            capturedRequest = request
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!,
                    Data("<h1>hi</h1>".utf8))
        }
        let executor = LoopbackHTTPExecutor(baseURL: URL(string: "http://127.0.0.1:4321")!, urlSession: Self.makeSession())
        let (head, body) = try await executor.execute(
            BridgeRequestHead(method: "GET", path: "/blog/?draft=1", headers: ["Accept": "text/html"]), body: nil)
        #expect(head.status == 200)
        #expect(head.headers["Content-Type"] == "text/html")
        var collected = Data()
        for try await chunk in body { collected.append(chunk) }
        #expect(String(decoding: collected, as: UTF8.self) == "<h1>hi</h1>")
        #expect(capturedRequest?.url?.path == "/blog")
        #expect(capturedRequest?.url?.query == "draft=1")
        #expect(capturedRequest?.httpMethod == "GET")
        #expect(capturedRequest?.value(forHTTPHeaderField: "Accept") == "text/html")
    }

    @Test func forwardsRequestBody() async throws {
        var capturedBody: Data?
        MockURLProtocol.handler = { request in
            capturedBody = request.httpBodyStream.map { stream -> Data in
                stream.open(); defer { stream.close() }
                var data = Data(); var buf = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let n = stream.read(&buf, maxLength: buf.count)
                    if n <= 0 { break }
                    data.append(buf, count: n)
                }
                return data
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: [:])!, Data())
        }
        let executor = LoopbackHTTPExecutor(baseURL: URL(string: "http://127.0.0.1:4321")!, urlSession: Self.makeSession())
        let (head, _) = try await executor.execute(
            BridgeRequestHead(method: "POST", path: "/api", headers: [:]), body: Data("payload".utf8))
        #expect(head.status == 201)
        #expect(capturedBody == Data("payload".utf8))
    }

    @Test func propagatesConnectionFailureAsThrow() async {
        MockURLProtocol.handler = { _ in fatalError("should not be called") }
        let unreachable = URLSession(configuration: {
            let c = URLSessionConfiguration.ephemeral
            c.protocolClasses = [FailingProtocol.self]
            return c
        }())
        let executor = LoopbackHTTPExecutor(baseURL: URL(string: "http://127.0.0.1:1")!, urlSession: unreachable)
        await #expect(throws: (any Error).self) {
            _ = try await executor.execute(BridgeRequestHead(method: "GET", path: "/", headers: [:]), body: nil)
        }
    }
}

final class FailingProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    }
    override func stopLoading() {}
}
