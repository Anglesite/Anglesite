import Testing
import Foundation
@testable import AnglesiteCore

/// Stub `URLProtocol` returning a canned status/body for every request, so
/// `WorkersConformanceFetcher` can be exercised without a real network call — mirrors
/// `WorkerCatalogFetcherTests`' `WorkerCatalogStubURLProtocol`.
private final class WorkersConformanceStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var body = ""
    nonisolated(unsafe) static var shouldFailToLoad = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if Self.shouldFailToLoad {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WorkersConformanceStubURLProtocol.self]
        return URLSession(configuration: config)
    }
}

// .serialized: tests share WorkersConformanceStubURLProtocol's mutable static status/body/
// failure flag, which would race under Swift Testing's default parallel execution.
@Suite(.serialized) struct WorkersConformanceFetcherTests {
    private let sampleJSON = """
    {
      "packages": {
        "@dwk/webmention": {
          "standard": "Webmention",
          "suites": { "webmention.rocks/receiver": { "status": "pending" } },
          "integration": { "status": "passing" }
        }
      }
    }
    """

    /// The digest a fetcher must be handed for `sampleJSON` to pass verification — computed the
    /// same way `scripts/bump-worker-catalog.sh` records it in the lock.
    private var sampleDigest: String { PinnedManifestFetch.sha256Hex(Data(sampleJSON.utf8)) }

    private func tempCacheURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("worker-conformance-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("worker-conformance-cache.json")
    }

    @Test("fetches, parses, and writes the cache file on success")
    func fetchesAndCachesOnSuccess() async throws {
        WorkersConformanceStubURLProtocol.shouldFailToLoad = false
        WorkersConformanceStubURLProtocol.statusCode = 200
        WorkersConformanceStubURLProtocol.body = sampleJSON
        let cacheURL = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }

        let fetcher = WorkersConformanceFetcher(
            statusURL: URL(string: "https://example.invalid/status.json")!,
            expectedSHA256: sampleDigest,
            cacheURL: cacheURL,
            session: WorkersConformanceStubURLProtocol.makeSession()
        )

        let status = await fetcher.status()
        #expect(status.packages["@dwk/webmention"]?.integrationStatus == "passing")
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    @Test("falls back to the cached status when the fetch fails")
    func fallsBackToCacheOnFetchFailure() async throws {
        let cacheURL = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(sampleJSON.utf8).write(to: cacheURL)

        WorkersConformanceStubURLProtocol.shouldFailToLoad = true
        let fetcher = WorkersConformanceFetcher(
            statusURL: URL(string: "https://example.invalid/status.json")!,
            expectedSHA256: sampleDigest,
            cacheURL: cacheURL,
            session: WorkersConformanceStubURLProtocol.makeSession()
        )

        let status = await fetcher.status()
        #expect(status.packages["@dwk/webmention"]?.integrationStatus == "passing")
    }

    @Test("falls back to an empty status on total failure (no network, no cache)")
    func fallsBackToEmpty() async throws {
        WorkersConformanceStubURLProtocol.shouldFailToLoad = true
        let cacheURL = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }

        let fetcher = WorkersConformanceFetcher(
            statusURL: URL(string: "https://example.invalid/status.json")!,
            expectedSHA256: sampleDigest,
            cacheURL: cacheURL,
            session: WorkersConformanceStubURLProtocol.makeSession()
        )
        let status = await fetcher.status()
        #expect(status.packages.isEmpty)
    }

    @Test("returns an empty status on a non-2xx response with no cache")
    func returnsEmptyOnBadStatusWithNoCache() async {
        WorkersConformanceStubURLProtocol.shouldFailToLoad = false
        WorkersConformanceStubURLProtocol.statusCode = 404
        WorkersConformanceStubURLProtocol.body = "not found"
        let cacheURL = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }

        let fetcher = WorkersConformanceFetcher(
            statusURL: URL(string: "https://example.invalid/status.json")!,
            expectedSHA256: sampleDigest,
            cacheURL: cacheURL,
            session: WorkersConformanceStubURLProtocol.makeSession()
        )

        let status = await fetcher.status()
        #expect(status.packages.isEmpty)
    }

    @Test("falls back to the cached status when the response is 200 but the body is malformed JSON")
    func fallsBackToCacheOnMalformedJSONBody() async throws {
        let cacheURL = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(sampleJSON.utf8).write(to: cacheURL)

        WorkersConformanceStubURLProtocol.shouldFailToLoad = false
        WorkersConformanceStubURLProtocol.statusCode = 200
        WorkersConformanceStubURLProtocol.body = "{ not valid json"
        let fetcher = WorkersConformanceFetcher(
            statusURL: URL(string: "https://example.invalid/status.json")!,
            expectedSHA256: sampleDigest,
            cacheURL: cacheURL,
            session: WorkersConformanceStubURLProtocol.makeSession()
        )

        let status = await fetcher.status()
        #expect(status.packages["@dwk/webmention"]?.integrationStatus == "passing")
    }

    @Test("returns an empty status when the cache file on disk is corrupted and the fetch also fails")
    func returnsEmptyWhenCacheIsCorruptedAndFetchFails() async throws {
        let cacheURL = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not valid json".utf8).write(to: cacheURL)

        WorkersConformanceStubURLProtocol.shouldFailToLoad = true
        let fetcher = WorkersConformanceFetcher(
            statusURL: URL(string: "https://example.invalid/status.json")!,
            expectedSHA256: sampleDigest,
            cacheURL: cacheURL,
            session: WorkersConformanceStubURLProtocol.makeSession()
        )

        let status = await fetcher.status()
        #expect(status.packages.isEmpty)
    }

    @Test("a 200 body whose digest doesn't match the pin is discarded: cache served, mismatch logged, cache not overwritten")
    func digestMismatchFallsBackToCacheAndLogs() async throws {
        let cacheURL = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(sampleJSON.utf8).write(to: cacheURL)

        let tampered = sampleJSON.replacingOccurrences(of: "\"status\": \"passing\"", with: "\"status\": \"failing\"")
        WorkersConformanceStubURLProtocol.shouldFailToLoad = false
        WorkersConformanceStubURLProtocol.statusCode = 200
        WorkersConformanceStubURLProtocol.body = tampered
        let logs = PinnedManifestLogCollector()
        let fetcher = WorkersConformanceFetcher(
            statusURL: URL(string: "https://example.invalid/status.json")!,
            expectedSHA256: sampleDigest,
            cacheURL: cacheURL,
            session: WorkersConformanceStubURLProtocol.makeSession(),
            log: { logs.sink($0) }
        )

        let status = await fetcher.status()
        #expect(status.packages["@dwk/webmention"]?.integrationStatus == "passing", "the last verified cache is served")
        #expect(try String(contentsOf: cacheURL, encoding: .utf8) == sampleJSON, "unverified bytes never reach the cache")
        #expect(logs.messages.contains { $0.contains("digest mismatch") }, "the fallback is diagnosed: \(logs.messages)")
    }

    @Test("a digest mismatch with no cache fails closed to an empty status and writes nothing")
    func digestMismatchWithNoCacheFailsClosed() async {
        WorkersConformanceStubURLProtocol.shouldFailToLoad = false
        WorkersConformanceStubURLProtocol.statusCode = 200
        WorkersConformanceStubURLProtocol.body = sampleJSON
        let cacheURL = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }

        let logs = PinnedManifestLogCollector()
        let fetcher = WorkersConformanceFetcher(
            statusURL: URL(string: "https://example.invalid/status.json")!,
            expectedSHA256: String(repeating: "0", count: 64),
            cacheURL: cacheURL,
            session: WorkersConformanceStubURLProtocol.makeSession(),
            log: { logs.sink($0) }
        )

        let status = await fetcher.status()
        #expect(status.packages.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: cacheURL.path), "nothing unverified is cached")
        #expect(logs.messages.contains { $0.contains("digest mismatch") })
    }

    @Test("productionStatusURL is the commit-pinned davidwkeith/workers conformance status, never a branch")
    func productionStatusURLIsPinned() {
        #expect(WorkersConformanceFetcher.productionStatusURL == WorkerCatalogPin.conformanceStatusURL)
        #expect(
            WorkersConformanceFetcher.productionStatusURL
                == URL(string: "https://raw.githubusercontent.com/davidwkeith/workers/\(WorkerCatalogPin.commit)/conformance/status.json")!
        )
        #expect(!WorkersConformanceFetcher.productionStatusURL.path.contains("/main/"))
    }
}
