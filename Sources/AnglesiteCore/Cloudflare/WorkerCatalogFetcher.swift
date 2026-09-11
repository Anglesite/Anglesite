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

/// Fetches, verifies, parses, and disk-caches the `@dwk/workers` catalog manifest (`catalog.json`).
///
/// The fetch is pinned (#1961, decision D7): the URL names the commit in ``WorkerCatalogPin``,
/// never a branch, and the body must hash to ``WorkerCatalogPin/catalogSHA256`` before it is
/// parsed or cached. Network, digest, or parse failures degrade to the last successfully
/// *verified* cached copy, then to an empty catalog — the Workers Settings tab and deploy
/// composition must never block or crash on a catalog fetch failure (design doc §3), and a
/// digest mismatch must never reach the deploy pipeline as trusted descriptors or route claims.
public actor WorkerCatalogFetcher {
    #if canImport(OSLog)
    private static let logger = Logger(subsystem: "io.dwk.anglesite", category: "WorkerCatalogFetcher")
    #endif

    /// Degraded-path logging, portable off-Darwin (no OSLog on Linux — cross-platform port
    /// design §9/§10). Diagnostics only: nothing here is owner-facing (the owner's surface
    /// carries no infrastructure vocabulary), so a digest mismatch is a log line, not a sheet.
    private static func logDegradation(_ message: String) {
        #if canImport(OSLog)
        logger.error("\(message, privacy: .public)")
        #else
        FileHandle.standardError.write(Data("[WorkerCatalogFetcher] \(message)\n".utf8))
        #endif
    }

    private let catalogURL: URL
    private let expectedSHA256: String
    private let cacheURL: URL
    private let session: URLSession
    private let fileManager: FileManager
    private let log: @Sendable (String) -> Void

    /// Creates a fetcher. `catalogURL` and `expectedSHA256` are deliberately required (use
    /// ``production(session:)`` for the pinned production values) so tests point at a local
    /// fixture server with a digest of the fixture, and so no call site can construct an
    /// unverified fetcher by omission.
    ///
    /// - Parameters:
    ///   - catalogURL: Where to fetch `catalog.json` from.
    ///   - expectedSHA256: Lowercase-hex SHA-256 the response body must match.
    ///   - cacheURL: On-disk location of the last verified copy.
    ///   - session: Session to fetch with.
    ///   - fileManager: File manager for the cache directory.
    ///   - log: Degradation sink; `nil` (the default) means the `io.dwk.anglesite` logger (stderr
    ///     off-Darwin). Tests inject a collector to assert on fallback diagnostics.
    public init(
        catalogURL: URL,
        expectedSHA256: String,
        cacheURL: URL = WorkerCatalogFetcher.defaultCacheURL(),
        session: URLSession = .shared,
        fileManager: FileManager = .default,
        log: (@Sendable (String) -> Void)? = nil
    ) {
        self.catalogURL = catalogURL
        self.expectedSHA256 = expectedSHA256
        self.cacheURL = cacheURL
        self.session = session
        self.fileManager = fileManager
        // Resolved here rather than as a default argument: a public init's default can't name the
        // private logger.
        self.log = log ?? { Self.logDegradation($0) }
    }

    /// A fetcher pointed at the pinned production manifest — ``WorkerCatalogPin/catalogURL``
    /// verified against ``WorkerCatalogPin/catalogSHA256``. Every production call site goes
    /// through this rather than spelling the pin out.
    ///
    /// - Parameter session: Session to fetch with; defaults to `URLSession.shared`.
    /// - Returns: A fetcher for the pinned catalog.
    public static func production(session: URLSession = .shared) -> WorkerCatalogFetcher {
        WorkerCatalogFetcher(
            catalogURL: WorkerCatalogPin.catalogURL,
            expectedSHA256: WorkerCatalogPin.catalogSHA256,
            session: session
        )
    }

    /// Fetches the pinned catalog, verifies its digest, and caches the raw manifest bytes to disk
    /// on success. On any failure (network error, non-2xx response, digest mismatch, malformed
    /// JSON), falls back to the last cached catalog; if there is no cache either, returns an
    /// empty catalog. Never throws. A digest mismatch is logged with both digests and the bytes
    /// are never cached — the cache only ever holds a copy that passed verification.
    public func catalog() async -> [WorkerDescriptor] {
        do {
            return try await fetchAndCache()
        } catch let PinnedManifestFetchError.digestMismatch(url, expected, actual) {
            log("catalog digest mismatch at \(url): expected \(expected), got \(actual) — discarding the response and falling back to the last verified cache (bump the pin with scripts/bump-worker-catalog.sh if the catalog moved deliberately)")
        } catch {
            log("catalog fetch failed, falling back to cache: \(error)")
        }
        do {
            return try Self.readCache(cacheURL)
        } catch {
            log("catalog cache read failed, falling back to empty catalog: \(error)")
            return []
        }
    }

    private func fetchAndCache() async throws -> [WorkerDescriptor] {
        let data = try await PinnedManifestFetch.verifiedData(
            from: catalogURL, expectedSHA256: expectedSHA256, session: session)
        let descriptors = try WorkerCatalogReader.parse(data)
        do {
            try Self.writeCache(data, to: cacheURL, fileManager: fileManager)
        } catch {
            log("catalog cache write failed (serving fresh data anyway): \(error)")
        }
        return descriptors
    }

    private static func readCache(_ url: URL) throws -> [WorkerDescriptor] {
        let data = try Data(contentsOf: url)
        return try WorkerCatalogReader.parse(data)
    }

    private static func writeCache(_ data: Data, to url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    /// The last successfully cached catalog, without any network fetch — for callers with no
    /// fetcher wiring (the headless deploy path, `SiteOperations`) that still need descriptor
    /// metadata such as route claims (#746). Returns an empty catalog when nothing has ever been
    /// cached or the cache is unreadable, mirroring `catalog()`'s final degradation step — and,
    /// like `catalog()`, never degrades silently: the fallback is logged so a headless deploy
    /// that loses route claims to a missing/corrupt cache leaves a diagnostic trace.
    public static func cachedCatalog(cacheURL: URL = WorkerCatalogFetcher.defaultCacheURL()) -> [WorkerDescriptor] {
        do {
            return try readCache(cacheURL)
        } catch {
            logDegradation("catalog cache read failed, falling back to empty catalog: \(error)")
            return []
        }
    }

    /// The pinned `@dwk/workers` monorepo catalog manifest — ``WorkerCatalogPin/catalogURL``,
    /// addressed by commit. Kept as a named constant for callers and docs that refer to "the
    /// production catalog URL"; production fetchers come from ``production(session:)``, which
    /// pairs this URL with its digest.
    public static var productionCatalogURL: URL { WorkerCatalogPin.catalogURL }

    /// `~/Library/Application Support/Anglesite/worker-catalog-cache.json` — mirrors
    /// `SiteStore`'s `defaultPersistenceURL` convention (`SiteStore.swift:323-333`).
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
            .appendingPathComponent("worker-catalog-cache.json")
    }
}
