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
        // `/blog`, not `/blog/`: `URL.path`'s getter strips a trailing slash. The request really
        // does carry `/blog/` on the wire (see `absoluteString` below) — don't "fix" this to
        // `/blog/`, it only reintroduces a false failure.
        #expect(capturedRequest?.url?.path == "/blog")
        #expect(capturedRequest?.url?.absoluteString == "http://127.0.0.1:4321/blog/?draft=1")
        #expect(capturedRequest?.url?.query == "draft=1")
        #expect(capturedRequest?.httpMethod == "GET")
        #expect(capturedRequest?.value(forHTTPHeaderField: "Accept") == "text/html")
    }

    /// `BridgeRequestHead.path` arrives already percent-encoded (the contract P0's
    /// `DirectoryHTTPExecutor` relies on when it percent-*decodes* the same field), so the
    /// executor must splice it on verbatim. Building the URL through `appendingPathComponent`
    /// re-encoded the `%` itself and turned every filename with a space or non-ASCII character
    /// into a 404.
    @Test func forwardsPercentEncodedPathWithoutDoubleEncoding() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.handler = { request in
            capturedRequest = request
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!, Data())
        }
        let executor = LoopbackHTTPExecutor(baseURL: URL(string: "http://127.0.0.1:4321")!, urlSession: Self.makeSession())
        _ = try await executor.execute(
            BridgeRequestHead(method: "GET", path: "/img/My%20Photo.jpg?w=64%2C64", headers: [:]), body: nil)
        // The SAME encoded path the peer sent — not `/img/My%2520Photo.jpg`.
        #expect(capturedRequest?.url?.absoluteString == "http://127.0.0.1:4321/img/My%20Photo.jpg?w=64%2C64")
        // And it still decodes back to the filename the site actually has on disk.
        #expect(capturedRequest?.url?.path == "/img/My Photo.jpg")
        #expect(capturedRequest?.url?.query == "w=64%2C64")
    }

    @Test func forwardsRequestBody() async throws {
        var capturedBody: Data?
        MockURLProtocol.handler = { request in
            // The executor sets `httpBody` (replayable), but `URLProtocol` hands the protocol
            // implementation a request whose body has been converted to a stream — so read
            // whichever form is actually present rather than assuming one.
            if let direct = request.httpBody { capturedBody = direct }
            capturedBody = capturedBody ?? request.httpBodyStream.map { stream -> Data in
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

    /// SSRF regression: a network-path reference (`//host/...`) is an RFC 3986 reference that
    /// `URL(string:relativeTo:)` resolves against a *different* host, ignoring `baseURL`'s host
    /// entirely. `request.path` is peer-supplied and unvalidated, so an unchecked splice would
    /// let a WebRTC peer redirect this host-side helper's request to an arbitrary host. The mock
    /// handler `fatalError`s if invoked — proof the executor never makes a real network call.
    @Test func rejectsNetworkPathReferenceAsUnsafe() async {
        MockURLProtocol.handler = { _ in fatalError("should not be called: network-path reference must be rejected before dispatch") }
        let executor = LoopbackHTTPExecutor(baseURL: URL(string: "http://127.0.0.1:4321")!, urlSession: Self.makeSession())
        await #expect(throws: URLError.self) {
            _ = try await executor.execute(
                BridgeRequestHead(method: "GET", path: "//evil.example/x", headers: [:]), body: nil)
        }
    }

    /// SSRF regression: an absolute reference (`scheme://host/...`) resolves to itself under RFC
    /// 3986 resolution, ignoring `baseURL` entirely. Same proof shape as the network-path case
    /// above — the mock handler must never be invoked.
    @Test func rejectsAbsoluteURLReferenceAsUnsafe() async {
        MockURLProtocol.handler = { _ in fatalError("should not be called: absolute URL reference must be rejected before dispatch") }
        let executor = LoopbackHTTPExecutor(baseURL: URL(string: "http://127.0.0.1:4321")!, urlSession: Self.makeSession())
        await #expect(throws: URLError.self) {
            _ = try await executor.execute(
                BridgeRequestHead(method: "GET", path: "http://evil.example/x", headers: [:]), body: nil)
        }
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
