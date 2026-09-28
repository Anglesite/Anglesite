import Testing
import Foundation
@testable import AnglesiteCore

/// Single-shot transport stub: returns one canned response (or throws) and records the request.
private final class StubTransport: @unchecked Sendable {
    private(set) var requests: [URLRequest] = []
    private let result: Result<(Int, [String: String]), any Error>
    init(_ result: Result<(Int, [String: String]), any Error>) { self.result = result }

    var transport: CloudflareTransport {
        { [self] request in
            requests.append(request)
            let (status, headers) = try result.get()
            let http = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            return (Data(), http)
        }
    }
}

struct ServedHeadersProbeTests {
    @Test("a 2xx GET response's headers are returned, requested at https://{domain}/")
    func okResponseReturnsHeaders() async throws {
        let spy = StubTransport(.success((200, ["X-Frame-Options": "DENY"])))
        let headers = await HTTPServedHeadersProbe(transport: spy.transport).fetchHeaders(domain: "example.com")
        #expect(headers?["X-Frame-Options"] == "DENY")
        let request = try #require(spy.requests.first)
        #expect(request.httpMethod == nil || request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://example.com/")
    }

    @Test("a 403 (Bot Fight Mode challenge) returns nil, not an empty/failed diff")
    func forbiddenReturnsNil() async {
        let spy = StubTransport(.success((403, [:])))
        let headers = await HTTPServedHeadersProbe(transport: spy.transport).fetchHeaders(domain: "example.com")
        #expect(headers == nil)
    }

    @Test("a 5xx (origin hiccup) returns nil")
    func serverErrorReturnsNil() async {
        let spy = StubTransport(.success((503, [:])))
        let headers = await HTTPServedHeadersProbe(transport: spy.transport).fetchHeaders(domain: "example.com")
        #expect(headers == nil)
    }

    @Test("a thrown transport error (timeout/DNS) returns nil")
    func thrownRequestReturnsNil() async {
        let spy = StubTransport(.failure(URLError(.timedOut)))
        let headers = await HTTPServedHeadersProbe(transport: spy.transport).fetchHeaders(domain: "example.com")
        #expect(headers == nil)
    }
}
