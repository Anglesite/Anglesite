import Testing
import Foundation
@testable import AnglesiteCore

/// A dedicated `URLProtocol` stub for `ExternalLLMVerifier` tests — modeled on
/// `ExternalLLMStubURLProtocol` in `ExternalLLMBackendTests.swift`, but simplified for a plain
/// non-streaming GET (`ExternalLLMBackend`'s stub also handles SSE gating/mid-stream failure,
/// neither of which the verifier's single `/models` request needs).
final class ExternalLLMVerifierStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response {
        let status: Int
        let headers: [String: String]
        let body: Data
    }
    nonisolated(unsafe) static var queue: [Response] = []
    nonisolated(unsafe) static var capturedRequests: [URLRequest] = []

    static func reset() { queue = []; capturedRequests = [] }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.capturedRequests.append(request)
        let r = Self.queue.isEmpty ? Response(status: 500, headers: [:], body: Data()) : Self.queue.removeFirst()
        let http = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        if !r.body.isEmpty { client?.urlProtocol(self, didLoad: r.body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("ExternalLLMVerifier", .serialized)
struct ExternalLLMVerifierTests {
    private func makeVerifier() -> ExternalLLMVerifier {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ExternalLLMVerifierStubURLProtocol.self]
        return ExternalLLMVerifier(urlSession: URLSession(configuration: config))
    }

    @Test("empty base URL fails with a prompt to enter one")
    func emptyBaseURLFails() async {
        let result = await makeVerifier().verify(baseURLText: "   ", apiKey: "")
        #expect(result == .failure("enter a base URL first"))
    }

    @Test("invalid base URL fails with a prompt to enter one")
    func invalidBaseURLFails() async {
        let result = await makeVerifier().verify(baseURLText: "http://exa mple.com", apiKey: "")
        #expect(result == .failure("enter a base URL first"))
    }

    @Test("trailing slash on base URL is trimmed before the /models suffix")
    func trailingSlashTrimmed() async throws {
        ExternalLLMVerifierStubURLProtocol.reset()
        ExternalLLMVerifierStubURLProtocol.queue.append(.init(status: 200, headers: [:], body: Data()))
        _ = await makeVerifier().verify(baseURLText: "https://api.example.com/v1/", apiKey: "")
        let captured = try #require(ExternalLLMVerifierStubURLProtocol.capturedRequests.first)
        #expect(captured.url?.absoluteString == "https://api.example.com/v1/models")
    }

    @Test("200 response with N models in `data` reports the model count")
    func successWithModelCount() async throws {
        ExternalLLMVerifierStubURLProtocol.reset()
        let body = #"{"data": [{"id":"a"},{"id":"b"},{"id":"c"}]}"#.data(using: .utf8)!
        ExternalLLMVerifierStubURLProtocol.queue.append(.init(status: 200, headers: [:], body: body))
        let result = await makeVerifier().verify(baseURLText: "https://api.example.com/v1", apiKey: "")
        #expect(result == .success(detail: "3 models available"))
    }

    @Test("200 response with exactly one model uses the singular form")
    func successWithSingleModel() async throws {
        ExternalLLMVerifierStubURLProtocol.reset()
        let body = #"{"data": [{"id":"a"}]}"#.data(using: .utf8)!
        ExternalLLMVerifierStubURLProtocol.queue.append(.init(status: 200, headers: [:], body: body))
        let result = await makeVerifier().verify(baseURLText: "https://api.example.com/v1", apiKey: "")
        #expect(result == .success(detail: "1 model available"))
    }

    @Test("200 response with a non-JSON body still succeeds, with nil detail")
    func successWithNonJSONBody() async throws {
        ExternalLLMVerifierStubURLProtocol.reset()
        ExternalLLMVerifierStubURLProtocol.queue.append(.init(status: 200, headers: [:], body: "not json".data(using: .utf8)!))
        let result = await makeVerifier().verify(baseURLText: "https://api.example.com/v1", apiKey: "")
        #expect(result == .success(detail: nil))
    }

    @Test("401 response fails with the HTTP status")
    func unauthorizedFails() async throws {
        ExternalLLMVerifierStubURLProtocol.reset()
        ExternalLLMVerifierStubURLProtocol.queue.append(.init(status: 401, headers: [:], body: Data()))
        let result = await makeVerifier().verify(baseURLText: "https://api.example.com/v1", apiKey: "sk-test")
        #expect(result == .failure("HTTP 401"))
    }

    @Test("Bearer header is present only when an API key is supplied")
    func bearerHeaderOnlyWithKey() async throws {
        ExternalLLMVerifierStubURLProtocol.reset()
        ExternalLLMVerifierStubURLProtocol.queue.append(.init(status: 200, headers: [:], body: Data()))
        _ = await makeVerifier().verify(baseURLText: "https://api.example.com/v1", apiKey: "sk-test")
        #expect(ExternalLLMVerifierStubURLProtocol.capturedRequests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")

        ExternalLLMVerifierStubURLProtocol.reset()
        ExternalLLMVerifierStubURLProtocol.queue.append(.init(status: 200, headers: [:], body: Data()))
        _ = await makeVerifier().verify(baseURLText: "https://api.example.com/v1", apiKey: "")
        #expect(ExternalLLMVerifierStubURLProtocol.capturedRequests.last?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("a response body exceeding the byte cap is truncated, not fully read")
    func byteCapTruncatesBody() async throws {
        ExternalLLMVerifierStubURLProtocol.reset()
        // A valid `{"data":[...]}` JSON body whose serialized form is larger than
        // `verifyResponseByteLimit` — if the verifier read the whole thing, this would parse
        // and report a real model count. The truncated bytes land mid-array, so JSON parsing
        // fails and `detail` comes back nil instead, confirming only the capped prefix was read.
        let models = (0..<5_000).map { "{\"id\":\"model-\($0)\"}" }.joined(separator: ",")
        let body = "{\"data\":[\(models)]}".data(using: .utf8)!
        #expect(body.count > ExternalLLMVerifier.verifyResponseByteLimit)
        ExternalLLMVerifierStubURLProtocol.queue.append(.init(status: 200, headers: [:], body: body))
        let result = await makeVerifier().verify(baseURLText: "https://api.example.com/v1", apiKey: "")
        #expect(result == .success(detail: nil))
    }
}
