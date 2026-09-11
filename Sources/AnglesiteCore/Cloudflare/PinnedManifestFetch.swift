import Foundation
// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin
// platforms (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Why a pinned-manifest fetch produced no trustworthy bytes. Never escapes
/// `WorkerCatalogFetcher.catalog()` / `WorkersConformanceFetcher.status()`, which degrade to the
/// last verified cache instead of throwing; public so tests can match on the case.
public enum PinnedManifestFetchError: Error, Sendable, Equatable {
    /// The HTTP fetch didn't produce a usable 2xx response; the string names the URL for the log.
    case fetchFailed(String)
    /// The response arrived but its SHA-256 doesn't match the pin (#1961, decision D7). The bytes
    /// are discarded unread — a mismatch means either the pin is stale (bump it deliberately with
    /// `scripts/bump-worker-catalog.sh`) or something between the pinned commit and this process
    /// changed the file, and the fetcher can't tell which, so it trusts neither.
    case digestMismatch(url: String, expected: String, actual: String)
}

/// Fetches one manifest from its pinned URL and returns the bytes only if their SHA-256 matches
/// the digest recorded in ``WorkerCatalogPin``. Shared by ``WorkerCatalogFetcher`` and
/// ``WorkersConformanceFetcher`` so both apply exactly the same "verify before parse, never cache
/// unverified bytes" rule.
enum PinnedManifestFetch {
    /// Lowercase-hex SHA-256 of `data` — the same encoding `scripts/bump-worker-catalog.sh`
    /// records in the lock (`sha256sum` / `shasum -a 256`). CryptoKit on Darwin; the vendored
    /// `PortableSHA256` on the Linux `AnglesiteCore` build, mirroring `ImportSnapshot.htmlKey`.
    static func sha256Hex(_ data: Data) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        return PortableSHA256.hexDigest(of: data)
        #endif
    }

    /// Downloads `url` through `session` and verifies the body against `expectedSHA256`.
    ///
    /// - Parameters:
    ///   - url: The pinned, commit-addressed manifest URL (see `WorkerCatalogPin.url(forPath:)`).
    ///   - expectedSHA256: Lowercase-hex digest the body must match, from the lock.
    ///   - session: Session to fetch with; tests inject a stub `URLProtocol`.
    /// - Returns: The verified body bytes.
    /// - Throws: ``PinnedManifestFetchError/fetchFailed(_:)`` on a transport error or non-2xx
    ///   status, ``PinnedManifestFetchError/digestMismatch(url:expected:actual:)`` when the body
    ///   doesn't hash to `expectedSHA256`.
    static func verifiedData(from url: URL, expectedSHA256: String, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw PinnedManifestFetchError.fetchFailed("bad response from \(url)")
        }
        let actual = sha256Hex(data)
        guard actual == expectedSHA256.lowercased() else {
            throw PinnedManifestFetchError.digestMismatch(
                url: url.absoluteString, expected: expectedSHA256.lowercased(), actual: actual)
        }
        return data
    }
}

extension WorkerCatalogPin {
    /// Raw-content host the pinned manifests are read from. `raw.githubusercontent.com` addressed
    /// by commit is immutable; the digest check covers the CDN itself, so the host is trusted for
    /// availability only, never for content. Decision D7 documents the catalog (and this host it
    /// is read through) as a first-party dependency (`docs/architecture.md` ▸ "First-party
    /// infrastructure").
    public static let rawContentBase = URL(string: "https://raw.githubusercontent.com")!

    /// `https://raw.githubusercontent.com/<repository>/<commit>/<path>` — always the pinned
    /// ``commit``, never a branch name.
    ///
    /// - Parameter path: Repo-relative file path, e.g. ``catalogPath``.
    /// - Returns: The commit-addressed URL for that file.
    public static func url(forPath path: String) -> URL {
        rawContentBase
            .appendingPathComponent(repository)
            .appendingPathComponent(commit)
            .appendingPathComponent(path)
    }

    /// Pinned URL of the worker catalog manifest.
    public static var catalogURL: URL { url(forPath: catalogPath) }

    /// Pinned URL of the conformance status manifest.
    public static var conformanceStatusURL: URL { url(forPath: conformanceStatusPath) }
}
