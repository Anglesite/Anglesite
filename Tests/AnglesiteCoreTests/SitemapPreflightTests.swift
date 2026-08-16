import Testing
import Foundation
@testable import AnglesiteCore

/// Serial transport stub: replays `responses` in call order and records every request.
/// Distinct from `fakeTransport` (keyed by path suffix) because the preflight's HEAD→GET
/// fallback hits the *same* URL twice and must get different answers per call.
private final class SequencedTransport: @unchecked Sendable {
    private(set) var requests: [URLRequest] = []
    private var responses: [Result<(Int, String), any Error>]
    init(_ responses: [Result<(Int, String), any Error>]) { self.responses = responses }

    var transport: CloudflareTransport {
        { [self] request in
            requests.append(request)
            guard !responses.isEmpty else { throw URLError(.badServerResponse) }
            let (status, body) = try responses.removeFirst().get()
            let http = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), http)
        }
    }
}

struct SitemapPreflightTests {
    @Test("a 2xx HEAD response is .reachable, requested at https://{domain}/sitemap.xml")
    func headReachable() async throws {
        let spy = SequencedTransport([.success((200, ""))])
        let result = await HTTPSitemapPreflight(transport: spy.transport).checkSitemap(domain: "example.com")
        #expect(result == .reachable)
        let request = try #require(spy.requests.first)
        #expect(request.httpMethod == "HEAD")
        #expect(request.url?.absoluteString == "https://example.com/sitemap.xml")
    }

    @Test("a definitive not-there HEAD response (404) is .unreachable")
    func headNotFound() async {
        let spy = SequencedTransport([.success((404, "not found"))])
        let result = await HTTPSitemapPreflight(transport: spy.transport).checkSitemap(domain: "example.com")
        #expect(result == .unreachable)
        #expect(spy.requests.count == 1)
    }

    @Test("a 410 Gone is .unreachable too")
    func headGone() async {
        let spy = SequencedTransport([.success((410, ""))])
        let result = await HTTPSitemapPreflight(transport: spy.transport).checkSitemap(domain: "example.com")
        #expect(result == .unreachable)
    }

    @Test("a 403 is .indeterminate — Bot Fight Mode challenges a bare URLSession probe on a live site")
    func headForbiddenIsIndeterminate() async {
        let spy = SequencedTransport([.success((403, "challenge page"))])
        let result = await HTTPSitemapPreflight(transport: spy.transport).checkSitemap(domain: "example.com")
        #expect(result == .indeterminate)
    }

    @Test("a 5xx is .indeterminate — an origin hiccup says nothing about the sitemap")
    func headServerErrorIsIndeterminate() async {
        let spy = SequencedTransport([.success((522, ""))])
        let result = await HTTPSitemapPreflight(transport: spy.transport).checkSitemap(domain: "example.com")
        #expect(result == .indeterminate)
    }

    @Test("a 405 to HEAD falls back to a ranged GET; 206 there is .reachable")
    func headMethodNotAllowedFallsBackToRangedGET() async throws {
        let spy = SequencedTransport([.success((405, "")), .success((206, "<urlset/>"))])
        let result = await HTTPSitemapPreflight(transport: spy.transport).checkSitemap(domain: "example.com")
        #expect(result == .reachable)
        #expect(spy.requests.count == 2)
        let fallback = try #require(spy.requests.last)
        #expect(fallback.httpMethod == "GET")
        #expect(fallback.value(forHTTPHeaderField: "Range") == "bytes=0-0")
    }

    @Test("a 405 to HEAD whose GET fallback 404s is .unreachable")
    func fallbackGETNotFound() async {
        let spy = SequencedTransport([.success((501, "")), .success((404, ""))])
        let result = await HTTPSitemapPreflight(transport: spy.transport).checkSitemap(domain: "example.com")
        #expect(result == .unreachable)
    }

    @Test("a 405 to HEAD whose GET fallback is also ambiguous (403) is .indeterminate")
    func fallbackGETForbiddenIsIndeterminate() async {
        let spy = SequencedTransport([.success((405, "")), .success((403, ""))])
        let result = await HTTPSitemapPreflight(transport: spy.transport).checkSitemap(domain: "example.com")
        #expect(result == .indeterminate)
    }

    @Test("a transport failure (timeout/DNS) is .indeterminate — advisory, never a wedge")
    func transportFailureIsIndeterminate() async {
        let spy = SequencedTransport([.failure(URLError(.timedOut))])
        let result = await HTTPSitemapPreflight(transport: spy.transport).checkSitemap(domain: "example.com")
        #expect(result == .indeterminate)
    }

    @Test("a transport failure on the GET fallback is .indeterminate too")
    func fallbackTransportFailureIsIndeterminate() async {
        let spy = SequencedTransport([.success((405, "")), .failure(URLError(.cannotConnectToHost))])
        let result = await HTTPSitemapPreflight(transport: spy.transport).checkSitemap(domain: "example.com")
        #expect(result == .indeterminate)
    }
}
