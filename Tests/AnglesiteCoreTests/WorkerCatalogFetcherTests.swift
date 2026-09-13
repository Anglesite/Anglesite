import Testing
import Foundation
@testable import AnglesiteCore

/// Stub `URLProtocol` returning a canned status/body for every request, so
/// `WorkerCatalogFetcher` can be exercised without a real network call — mirrors
/// `FreedesignmdCatalogTests`' `FreedesignmdStubURLProtocol`.
private final class WorkerCatalogStubURLProtocol: URLProtocol, @unchecked Sendable {
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
        config.protocolClasses = [WorkerCatalogStubURLProtocol.self]
        return URLSession(configuration: config)
    }
}

/// Collects the degradation log lines a fetcher emits (its `log:` sink), so tests can assert a
/// fallback was diagnosed and not just silently taken. Shared with
/// `WorkersConformanceFetcherTests`.
final class PinnedManifestLogCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var messages: [String] {
        lock.withLock { lines }
    }

    func sink(_ message: String) {
        lock.withLock { lines.append(message) }
    }
}

// .serialized: tests share WorkerCatalogStubURLProtocol's mutable static status/body/failure
// flag, which would race under Swift Testing's default parallel execution.
@Suite(.serialized) struct WorkerCatalogFetcherTests {
    private let sampleJSON = """
    {
      "workers": [
        {
          "id": "webmention",
          "displayName": "Webmentions",
          "description": "Receive and verify webmentions for posts",
          "group": "social",
          "binding": { "kind": "componentTied", "componentIDs": ["webmention-form"] },
          "resources": { "needsD1": true, "needsKV": true, "needsR2": false }
        }
      ]
    }
    """

    /// The digest a fetcher must be handed for `sampleJSON` to pass verification — computed the
    /// same way `scripts/bump-worker-catalog.sh` records it in the lock.
    private var sampleDigest: String { PinnedManifestFetch.sha256Hex(Data(sampleJSON.utf8)) }

    private func tempCacheURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("worker-catalog-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("worker-catalog-cache.json")
    }

    @Test("fetches, parses, and writes the cache file on success")
    func fetchesAndCachesOnSuccess() async throws {
        WorkerCatalogStubURLProtocol.shouldFailToLoad = false
        WorkerCatalogStubURLProtocol.statusCode = 200
        WorkerCatalogStubURLProtocol.body = sampleJSON
        let cacheURL = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }

        let fetcher = WorkerCatalogFetcher(
            catalogURL: URL(string: "https://example.invalid/catalog.json")!,
            expectedSHA256: sampleDigest,
            cacheURL: cacheURL,
            session: WorkerCatalogStubURLProtocol.makeSession()
        )

        let workers = await fetcher.catalog()
        #expect(workers.map(\.id) == ["webmention"])
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    @Test("falls back to the cached catalog when the fetch fails")
    func fallsBackToCacheOnFetchFailure() async throws {
        let cacheURL = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(sampleJSON.utf8).write(to: cacheURL)

        WorkerCatalogStubURLProtocol.shouldFailToLoad = true
        let fetcher = WorkerCatalogFetcher(
            catalogURL: URL(string: "https://example.invalid/catalog.json")!,
            expectedSHA256: sampleDigest,
            cacheURL: cacheURL,
            session: WorkerCatalogStubURLProtocol.makeSession()
        )

        let workers = await fetcher.catalog()
        #expect(workers.map(\.id) == ["webmention"])
    }

    @Test("returns an empty catalog when the fetch fails and there is no cache")
    func returnsEmptyWhenNoCacheAndFetchFails() async {
        WorkerCatalogStubURLProtocol.shouldFailToLoad = true
        let cacheURL = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }

        let fetcher = WorkerCatalogFetcher(
            catalogURL: URL(string: "https://example.invalid/catalog.json")!,
            expectedSHA256: sampleDigest,
            cacheURL: cacheURL,
            session: WorkerCatalogStubURLProtocol.makeSession()
        )

        let workers = await fetcher.catalog()
        #expect(workers.isEmpty)
    }

    @Test("returns an empty catalog on a non-2xx response with no cache")
    func returnsEmptyOnBadStatusWithNoCache() async {
        WorkerCatalogStubURLProtocol.shouldFailToLoad = false
        WorkerCatalogStubURLProtocol.statusCode = 404
        WorkerCatalogStubURLProtocol.body = "not found"
        let cacheURL = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }

        let fetcher = WorkerCatalogFetcher(
            catalogURL: URL(string: "https://example.invalid/catalog.json")!,
            expectedSHA256: sampleDigest,
            cacheURL: cacheURL,
            session: WorkerCatalogStubURLProtocol.makeSession()
        )

        let workers = await fetcher.catalog()
        #expect(workers.isEmpty)
    }

    @Test("falls back to the cached catalog when the response is 200 but the body is malformed JSON")
    func fallsBackToCacheOnMalformedJSONBody() async throws {
        let cacheURL = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(sampleJSON.utf8).write(to: cacheURL)

        WorkerCatalogStubURLProtocol.shouldFailToLoad = false
        WorkerCatalogStubURLProtocol.statusCode = 200
        WorkerCatalogStubURLProtocol.body = "{ not valid json"
        let fetcher = WorkerCatalogFetcher(
            catalogURL: URL(string: "https://example.invalid/catalog.json")!,
            expectedSHA256: sampleDigest,
            cacheURL: cacheURL,
            session: WorkerCatalogStubURLProtocol.makeSession()
        )

        let workers = await fetcher.catalog()
        #expect(workers.map(\.id) == ["webmention"])
    }

    @Test("returns an empty catalog when the cache file on disk is corrupted and the fetch also fails")
    func returnsEmptyWhenCacheIsCorruptedAndFetchFails() async throws {
        let cacheURL = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not valid json".utf8).write(to: cacheURL)

        WorkerCatalogStubURLProtocol.shouldFailToLoad = true
        let fetcher = WorkerCatalogFetcher(
            catalogURL: URL(string: "https://example.invalid/catalog.json")!,
            expectedSHA256: sampleDigest,
            cacheURL: cacheURL,
            session: WorkerCatalogStubURLProtocol.makeSession()
        )

        let workers = await fetcher.catalog()
        #expect(workers.isEmpty)
    }

    @Test("a 200 body whose digest doesn't match the pin is discarded: cache served, mismatch logged, cache not overwritten")
    func digestMismatchFallsBackToCacheAndLogs() async throws {
        let cacheURL = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(sampleJSON.utf8).write(to: cacheURL)

        // A well-formed catalog that is *not* the pinned bytes — exactly what a tampered branch
        // or CDN would serve. It parses fine, so only the digest check can reject it.
        let tampered = sampleJSON.replacingOccurrences(of: "\"id\": \"webmention\"", with: "\"id\": \"tampered\"")
        WorkerCatalogStubURLProtocol.shouldFailToLoad = false
        WorkerCatalogStubURLProtocol.statusCode = 200
        WorkerCatalogStubURLProtocol.body = tampered
        let logs = PinnedManifestLogCollector()
        let fetcher = WorkerCatalogFetcher(
            catalogURL: URL(string: "https://example.invalid/catalog.json")!,
            expectedSHA256: sampleDigest,
            cacheURL: cacheURL,
            session: WorkerCatalogStubURLProtocol.makeSession(),
            log: { logs.sink($0) }
        )

        let workers = await fetcher.catalog()
        #expect(workers.map(\.id) == ["webmention"], "the last verified cache is served, not the tampered body")
        #expect(try String(contentsOf: cacheURL, encoding: .utf8) == sampleJSON, "unverified bytes never reach the cache")
        let mismatch = logs.messages.first { $0.contains("digest mismatch") }
        #expect(mismatch != nil, "the fallback is diagnosed: \(logs.messages)")
        #expect(mismatch?.contains(sampleDigest) == true, "the log names the expected digest")
        #expect(mismatch?.contains(PinnedManifestFetch.sha256Hex(Data(tampered.utf8))) == true, "the log names the actual digest")
    }

    @Test("a digest mismatch with no cache fails closed to an empty catalog and writes nothing")
    func digestMismatchWithNoCacheFailsClosed() async {
        WorkerCatalogStubURLProtocol.shouldFailToLoad = false
        WorkerCatalogStubURLProtocol.statusCode = 200
        WorkerCatalogStubURLProtocol.body = sampleJSON
        let cacheURL = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }

        let logs = PinnedManifestLogCollector()
        let fetcher = WorkerCatalogFetcher(
            catalogURL: URL(string: "https://example.invalid/catalog.json")!,
            expectedSHA256: String(repeating: "0", count: 64),
            cacheURL: cacheURL,
            session: WorkerCatalogStubURLProtocol.makeSession(),
            log: { logs.sink($0) }
        )

        let workers = await fetcher.catalog()
        #expect(workers.isEmpty, "a parseable body with the wrong digest is not trusted")
        #expect(!FileManager.default.fileExists(atPath: cacheURL.path), "nothing unverified is cached")
        #expect(logs.messages.contains { $0.contains("digest mismatch") })
    }

    @Test("the expected digest is compared case-insensitively (the lock is lowercase, but be tolerant)")
    func digestComparisonIsCaseInsensitive() async {
        WorkerCatalogStubURLProtocol.shouldFailToLoad = false
        WorkerCatalogStubURLProtocol.statusCode = 200
        WorkerCatalogStubURLProtocol.body = sampleJSON
        let cacheURL = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }

        let fetcher = WorkerCatalogFetcher(
            catalogURL: URL(string: "https://example.invalid/catalog.json")!,
            expectedSHA256: sampleDigest.uppercased(),
            cacheURL: cacheURL,
            session: WorkerCatalogStubURLProtocol.makeSession()
        )

        let workers = await fetcher.catalog()
        #expect(workers.map(\.id) == ["webmention"])
    }

    @Test("productionCatalogURL is the commit-pinned davidwkeith/workers catalog.json, never a branch")
    func productionCatalogURLIsPinned() {
        #expect(WorkerCatalogFetcher.productionCatalogURL == WorkerCatalogPin.catalogURL)
        #expect(
            WorkerCatalogFetcher.productionCatalogURL
                == URL(string: "https://raw.githubusercontent.com/davidwkeith/workers/\(WorkerCatalogPin.commit)/catalog.json")!
        )
        #expect(!WorkerCatalogFetcher.productionCatalogURL.path.contains("/main/"))
    }
}
