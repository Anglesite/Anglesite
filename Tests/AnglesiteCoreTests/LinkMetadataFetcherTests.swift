import Foundation
import Testing
@testable import AnglesiteCore

/// Canned-response URLProtocol so the fetcher runs with no network — mirrors
/// `WorkerCatalogFetcherTests`' `WorkerCatalogStubURLProtocol`.
private final class LinkStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var body = ""
    nonisolated(unsafe) static var mimeType: String? = "text/html"
    nonisolated(unsafe) static var shouldFailToLoad = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if Self.shouldFailToLoad {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        var headers: [String: String] = [:]
        if let mime = Self.mimeType { headers["Content-Type"] = mime }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LinkStubURLProtocol.self]
        return URLSession(configuration: config)
    }
}

@Suite("LinkMetadataFetcher", .serialized)  // stub state is static; keep cases sequential
struct LinkMetadataFetcherTests {
    private func reset(status: Int = 200, body: String = "", mime: String? = "text/html", fail: Bool = false) {
        LinkStubURLProtocol.statusCode = status
        LinkStubURLProtocol.body = body
        LinkStubURLProtocol.mimeType = mime
        LinkStubURLProtocol.shouldFailToLoad = fail
    }

    @Test("returns parsed metadata for an HTML page")
    func success() async throws {
        reset(body: #"<head><meta property="og:title" content="Hello"></head>"#)
        let fetcher = LinkMetadataFetcher(session: LinkStubURLProtocol.makeSession())
        let meta = try await fetcher.fetch(url: URL(string: "https://example.com/a")!)
        #expect(meta.title == "Hello")
    }

    @Test("non-2xx status throws")
    func httpError() async {
        reset(status: 404)
        let fetcher = LinkMetadataFetcher(session: LinkStubURLProtocol.makeSession())
        await #expect(throws: LinkMetadataFetchError.self) {
            _ = try await fetcher.fetch(url: URL(string: "https://example.com/missing")!)
        }
    }

    @Test("non-HTML content type throws")
    func nonHTML() async {
        reset(body: "%PDF-1.4", mime: "application/pdf")
        let fetcher = LinkMetadataFetcher(session: LinkStubURLProtocol.makeSession())
        await #expect(throws: LinkMetadataFetchError.self) {
            _ = try await fetcher.fetch(url: URL(string: "https://example.com/doc.pdf")!)
        }
    }

    @Test("transport failure propagates as an error")
    func transportFailure() async {
        reset(fail: true)
        let fetcher = LinkMetadataFetcher(session: LinkStubURLProtocol.makeSession())
        await #expect(throws: (any Error).self) {
            _ = try await fetcher.fetch(url: URL(string: "https://example.com/x")!)
        }
    }

    @Test("body beyond the byte cap is ignored, head metadata still parses")
    func byteCap() async throws {
        let head = #"<head><meta property="og:title" content="Capped"></head>"#
        reset(body: head + String(repeating: "x", count: LinkMetadataFetcher.maximumBodyBytes))
        let fetcher = LinkMetadataFetcher(session: LinkStubURLProtocol.makeSession())
        let meta = try await fetcher.fetch(url: URL(string: "https://example.com/big")!)
        #expect(meta.title == "Capped")
    }

    @Test("missing Content-Type still parses — servers that omit the header are common")
    func nilMIMEProceeds() async throws {
        reset(body: #"<head><meta property="og:title" content="No MIME"></head>"#, mime: nil)
        let fetcher = LinkMetadataFetcher(session: LinkStubURLProtocol.makeSession())
        let meta = try await fetcher.fetch(url: URL(string: "https://example.com/n")!)
        #expect(meta.title == "No MIME")
    }

    @Test("declared charset drives the decode (ISO-8859-1 body decodes correctly)")
    func charsetDecode() {
        // Exercises the CFStringConvertIANACharSetNameToEncoding branch of decode(_:textEncodingName:)
        // directly: 0xE9 is "é" in ISO-8859-1 but invalid as a UTF-8 sequence.
        let latin1 = Data([0xE9])
        #expect(LinkMetadataFetcher.decode(latin1, textEncodingName: "iso-8859-1") == "é")
        #expect(LinkMetadataFetcher.decode(latin1, textEncodingName: nil) == "\u{FFFD}")  // lossy UTF-8 fallback
    }
}
