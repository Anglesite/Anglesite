import Foundation
// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin
// platforms (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
// OSLog is Darwin-only; AnglesiteCore is part of the Linux-portable target set (Package.swift,
// cross-platform port design §9/§10), so logging falls back to stderr off-Darwin.
#if canImport(OSLog)
import OSLog
#endif

/// Fetches, verifies, parses, and disk-caches `conformance/status.json` from the `@dwk/workers`
/// monorepo.
///
/// Pinned the same way as ``WorkerCatalogFetcher`` (#1961, decision D7): commit-addressed URL from
/// ``WorkerCatalogPin``, body verified against ``WorkerCatalogPin/conformanceStatusSHA256``
/// before parse or cache. Network, digest, or parse failures degrade to the last successfully
/// verified cached copy, then to an empty status — this is advisory-only (see
/// `WorkerActivation.conformanceAdvisory`), so a fetch failure must never block a deploy.
public actor WorkersConformanceFetcher {
    #if canImport(OSLog)
    private static let logger = Logger(subsystem: "io.dwk.anglesite", category: "WorkersConformanceFetcher")
    #endif

    /// Degraded-path logging, portable off-Darwin (no OSLog on Linux — cross-platform port
    /// design §9/§10).
    private static func logDegradation(_ message: String) {
        #if canImport(OSLog)
        logger.error("\(message, privacy: .public)")
        #else
        FileHandle.standardError.write(Data("[WorkersConformanceFetcher] \(message)\n".utf8))
        #endif
    }

    private let statusURL: URL
    private let expectedSHA256: String
    private let cacheURL: URL
    private let session: URLSession
    private let fileManager: FileManager
    private let log: @Sendable (String) -> Void

    /// Creates a fetcher. `statusURL` and `expectedSHA256` are deliberately required (use
    /// ``productionBounded(timeout:)`` for the pinned production values) so tests point at a
    /// local fixture server with a digest of the fixture, and so no call site can construct an
    /// unverified fetcher by omission.
    ///
    /// - Parameters:
    ///   - statusURL: Where to fetch `conformance/status.json` from.
    ///   - expectedSHA256: Lowercase-hex SHA-256 the response body must match.
    ///   - cacheURL: On-disk location of the last verified copy.
    ///   - session: Session to fetch with.
    ///   - fileManager: File manager for the cache directory.
    ///   - log: Degradation sink; `nil` (the default) means the `io.dwk.anglesite` logger (stderr
    ///     off-Darwin). Tests inject a collector to assert on fallback diagnostics.
    public init(
        statusURL: URL,
        expectedSHA256: String,
        cacheURL: URL = WorkersConformanceFetcher.defaultCacheURL(),
        session: URLSession = .shared,
        fileManager: FileManager = .default,
        log: (@Sendable (String) -> Void)? = nil
    ) {
        self.statusURL = statusURL
        self.expectedSHA256 = expectedSHA256
        self.cacheURL = cacheURL
        self.session = session
        self.fileManager = fileManager
        // Resolved here rather than as a default argument: a public init's default can't name the
        // private logger.
        self.log = log ?? { Self.logDegradation($0) }
    }

    /// Fetches the pinned conformance status, verifies its digest, and caches the raw manifest
    /// bytes to disk on success. On any failure (network error, non-2xx response, digest
    /// mismatch, malformed JSON), falls back to the last cached status; if there is no cache
    /// either, returns an empty status. Never throws — this is advisory-only, so callers must
    /// never have to handle a failure path. A digest mismatch is logged with both digests and the
    /// bytes are never cached.
    public func status() async -> WorkersConformanceStatus {
        do {
            return try await fetchAndCache()
        } catch let PinnedManifestFetchError.digestMismatch(url, expected, actual) {
            log("conformance status digest mismatch at \(url): expected \(expected), got \(actual) — discarding the response and falling back to the last verified cache (bump the pin with scripts/bump-worker-catalog.sh if the status moved deliberately)")
        } catch {
            log("status fetch failed, falling back to cache: \(error)")
        }
        do {
            return try Self.readCache(cacheURL)
        } catch {
            log("status cache read failed, falling back to empty status: \(error)")
            return WorkersConformanceStatus(packages: [:])
        }
    }

    private func fetchAndCache() async throws -> WorkersConformanceStatus {
        let data = try await PinnedManifestFetch.verifiedData(
            from: statusURL, expectedSHA256: expectedSHA256, session: session)
        let status = try WorkersConformanceReader.parse(data)
        do {
            try Self.writeCache(data, to: cacheURL, fileManager: fileManager)
        } catch {
            log("status cache write failed (serving fresh data anyway): \(error)")
        }
        return status
    }

    private static func readCache(_ url: URL) throws -> WorkersConformanceStatus {
        let data = try Data(contentsOf: url)
        return try WorkersConformanceReader.parse(data)
    }

    private static func writeCache(_ data: Data, to url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    /// The pinned conformance status manifest — ``WorkerCatalogPin/conformanceStatusURL``,
    /// addressed by commit. Production fetchers come from ``productionBounded(timeout:)``, which
    /// pairs this URL with its digest.
    public static var productionStatusURL: URL { WorkerCatalogPin.conformanceStatusURL }

    /// A fetcher pointed at ``productionStatusURL`` and verified against
    /// ``WorkerCatalogPin/conformanceStatusSHA256``, with a request timeout bounded well under
    /// `URLSession.shared`'s ~60s default — so an unreachable `raw.githubusercontent.com`
    /// (offline use, corporate firewall) can't add meaningful latency to a caller before this
    /// degrades to cache/empty. Every advisory-only production call site should go through this
    /// rather than hand-rolling the same `URLSessionConfiguration` (previously duplicated between
    /// `DeployModel` and `MicropubOnboardingModel` — #800 review feedback).
    ///
    /// - Parameter timeout: Per-request timeout in seconds.
    /// - Returns: A fetcher for the pinned conformance status.
    public static func productionBounded(timeout: TimeInterval = 5) -> WorkersConformanceFetcher {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        return WorkersConformanceFetcher(
            statusURL: productionStatusURL,
            expectedSHA256: WorkerCatalogPin.conformanceStatusSHA256,
            session: URLSession(configuration: config)
        )
    }

    /// `~/Library/Application Support/Anglesite/worker-conformance-cache.json` — mirrors
    /// `WorkerCatalogFetcher.defaultCacheURL`'s convention.
    public static func defaultCacheURL(fileManager: FileManager = .default) -> URL {
        let support = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.portableHomeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("Anglesite", isDirectory: true)
            .appendingPathComponent("worker-conformance-cache.json")
    }
}
