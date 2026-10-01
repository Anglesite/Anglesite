import Foundation
// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin
// (AnglesiteCore is in the Linux portable target set — see WXRAssetDownloader.swift).
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The one HTTP call ``EmDashContentAPI`` makes, as a seam so tests can answer it without a
/// network and the app can route it through whatever session policy it already has. Wrap a
/// `URLSession` with ``EmDashContentAPI/init(session:)``.
///
/// A conformance must not follow redirects on its own: the request carries a Bearer token, and
/// ``EmDashContentAPI`` refuses any 3xx (and any response whose URL left the request's origin)
/// so the token is never replayed to a host the owner didn't name. The default session gets a
/// delegate that declines every redirect; a caller-supplied session should do the same.
public protocol EmDashHTTPClient: Sendable {
    /// Performs `request` and returns the body and response.
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

/// `URLSession` behind the seam. A conformance on `URLSession` itself would have to declare a
/// one-argument `data(for:)` beside Foundation's `data(for:delegate:)` (whose `delegate` defaults
/// to `nil`), and that overload pair makes every existing `session.data(for:)` call site in this
/// module ambiguous on Darwin — so the session is wrapped instead.
private struct URLSessionClient: EmDashHTTPClient {
    let session: URLSession

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

/// Declines every HTTP redirect, so a 3xx comes back as the task's response instead of being
/// followed with the Authorization header still attached. Session-level (not per-task) because
/// `URLSession.data(for:delegate:)` isn't available on every Foundation this module builds on.
private final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Why ``EmDashContentAPI/fetchExport(siteURL:token:)`` couldn't read the site.
public enum EmDashContentAPIError: Error, Equatable {
    /// `siteURL` isn't an `http`/`https` URL with a host.
    case invalidSiteURL(String)
    /// `siteURL` is plain `http` on a host that isn't loopback — the token would travel in
    /// cleartext. Only `localhost`, `*.localhost`, `127.0.0.0/8` and `::1` may use `http`.
    case insecureSiteURL(String)
    /// The site answered 401/403 — the token is missing, expired, or lacks `content:read` +
    /// `schema:read`.
    case unauthorized
    /// The site answered 404, or answered 2xx with something that isn't JSON (a login page, a
    /// CDN interstitial) — there's no EmDash API at this URL.
    case notEmDash
    /// The site answered with a redirect, or the response came from a different origin than the
    /// one asked. Not followed: the request carries the Bearer token, and the owner named this
    /// site, not wherever it points.
    case redirected
    /// The snapshot is larger than ``EmDashContentAPI/maximumSnapshotBytes``, by `Content-Length`
    /// or by the bytes actually received.
    case snapshotTooLarge(bytes: Int)
    /// Any other non-2xx status.
    case httpStatus(Int)
}

/// Reads an EmDash site's content over its API (#2051): one `GET /_emdash/api/snapshot` with a
/// Bearer API token, parsed by ``EmDashSnapshotDocument`` into an ``EmDashExport``.
///
/// The snapshot endpoint is used rather than the paginated `/_emdash/api/content/{collection}`
/// listing because it returns, in one round trip, everything the import needs and the listing
/// doesn't carry: the collections' schema (field slugs and types), the taxonomy terms assigned
/// to each entry, and the media table that turns an image's `_ref` into a servable URL. It
/// serves published content only unless the token holder asks for drafts, which this never does.
/// A token is required: the endpoint checks `content:read` and `schema:read`, and EmDash's
/// `wrangler`-less owner mints one in its admin under Settings ▸ API tokens.
///
/// The token is only ever sent over `https` (plain `http` is allowed for loopback hosts, for a
/// local EmDash dev server), never across a redirect, and the body is bounded by
/// ``maximumSnapshotBytes``.
public struct EmDashContentAPI: Sendable {
    /// The largest snapshot body accepted, 64 MiB — far above any real site's published content
    /// (EmDash itself materializes the whole snapshot in memory on the Worker, which caps it well
    /// below this), so the bound only ever stops a hostile or broken server from handing the app
    /// an unbounded download to parse. Checked against `Content-Length` when the server sends
    /// one and against the bytes actually received; the seam hands back a complete body, so the
    /// second check bounds what is parsed rather than what is downloaded.
    public static let maximumSnapshotBytes = 64 * 1024 * 1024

    private let client: any EmDashHTTPClient

    /// Creates a client over an HTTP seam.
    /// - Parameter client: The HTTP seam; `nil` uses an ephemeral `URLSession` (no cookies, no
    ///   cache — a one-off read of an export, not a browsing session) that declines redirects.
    public init(client: (any EmDashHTTPClient)? = nil) {
        if let client {
            self.client = client
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = NetworkTimeouts.emdashSnapshotRequest
            config.timeoutIntervalForResource = NetworkTimeouts.emdashSnapshotResource
            let session = URLSession(configuration: config, delegate: RedirectRefusingDelegate(), delegateQueue: nil)
            self.client = URLSessionClient(session: session)
        }
    }

    /// Creates a client over a caller-configured `URLSession`. The session should decline
    /// redirects (see ``EmDashHTTPClient``); a redirect it does follow off-origin is still
    /// refused after the fact as ``EmDashContentAPIError/redirected``, but the token will
    /// already have travelled.
    /// - Parameter session: The session to send the snapshot request through.
    public init(session: URLSession) {
        self.client = URLSessionClient(session: session)
    }

    /// The snapshot endpoint for a site.
    /// - Parameter siteURL: The EmDash site's public URL (`https://blog.example`, with or
    ///   without a path or trailing slash — only the origin is used).
    /// - Returns: `<origin>/_emdash/api/snapshot`.
    /// - Throws: ``EmDashContentAPIError/invalidSiteURL(_:)`` for anything but an `http`/`https`
    ///   URL with a host; ``EmDashContentAPIError/insecureSiteURL(_:)`` for `http` on a host that
    ///   isn't loopback.
    public static func snapshotURL(siteURL: String) throws -> URL {
        let trimmed = siteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else {
            throw EmDashContentAPIError.invalidSiteURL(siteURL)
        }
        guard scheme == "https" || isLoopbackHost(host) else {
            throw EmDashContentAPIError.insecureSiteURL(siteURL)
        }
        components.scheme = scheme
        components.path = "/_emdash/api/snapshot"
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw EmDashContentAPIError.invalidSiteURL(siteURL) }
        return url
    }

    /// `true` for `localhost`, `*.localhost`, a `127.0.0.0/8` literal, or `::1` — the hosts a
    /// local EmDash dev server answers on, where cleartext never leaves the machine.
    static func isLoopbackHost(_ host: String) -> Bool {
        let lowered = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if lowered == "localhost" || lowered.hasSuffix(".localhost") || lowered == "::1" { return true }
        // Every label must be an octet: `127.0.0.1.evil.example` is a hostname, not an address.
        let labels = lowered.split(separator: ".", omittingEmptySubsequences: false)
        let octets = labels.compactMap { UInt8($0) }
        return labels.count == 4 && octets.count == 4 && octets[0] == 127
    }

    /// Fetches the site's snapshot JSON.
    /// - Parameters:
    ///   - siteURL: The EmDash site's public URL.
    ///   - token: The EmDash API token, sent as `Authorization: Bearer`.
    /// - Returns: The raw response body on a 2xx JSON answer within ``maximumSnapshotBytes``.
    /// - Throws: ``EmDashContentAPIError``, or the transport error the client raised.
    public func fetchSnapshot(siteURL: String, token: String) async throws -> Data {
        let url = try Self.snapshotURL(siteURL: siteURL)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await client.data(for: request)
        guard let http = response as? HTTPURLResponse else { return data }

        // Any origin change means the session followed a redirect the token shouldn't cross.
        if let answered = http.url, Self.origin(of: answered) != Self.origin(of: url) {
            throw EmDashContentAPIError.redirected
        }
        switch http.statusCode {
        case 200...299: break
        case 300...399: throw EmDashContentAPIError.redirected
        case 401, 403: throw EmDashContentAPIError.unauthorized
        case 404: throw EmDashContentAPIError.notEmDash
        default: throw EmDashContentAPIError.httpStatus(http.statusCode)
        }

        if let declared = Self.header("Content-Length", in: http).flatMap({ Int($0) }), declared > Self.maximumSnapshotBytes {
            throw EmDashContentAPIError.snapshotTooLarge(bytes: declared)
        }
        guard data.count <= Self.maximumSnapshotBytes else {
            throw EmDashContentAPIError.snapshotTooLarge(bytes: data.count)
        }
        guard Self.looksLikeJSON(contentType: Self.header("Content-Type", in: http), body: data) else {
            throw EmDashContentAPIError.notEmDash
        }
        return data
    }

    /// Fetches and parses the site's content.
    /// - Parameters:
    ///   - siteURL: The EmDash site's public URL.
    ///   - token: The EmDash API token.
    /// - Returns: The parsed export, ready for ``EmDashRung/items(from:siteURL:htmlConversions:)``.
    /// - Throws: ``EmDashContentAPIError``, ``EmDashSnapshotError``, or a transport error.
    public func fetchExport(siteURL: String, token: String) async throws -> EmDashExport {
        try EmDashSnapshotDocument.parse(try await fetchSnapshot(siteURL: siteURL, token: token))
    }

    /// `scheme://host:port`, lowercased, for comparing where a response came from.
    private static func origin(of url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host?.lowercased() ?? ""
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    /// A response header by case-insensitive name — `allHeaderFields` keys keep the server's
    /// capitalization, and the typed accessor isn't on every Foundation this builds against.
    private static func header(_ name: String, in response: HTTPURLResponse) -> String? {
        for (key, value) in response.allHeaderFields {
            if String(describing: key).caseInsensitiveCompare(name) == .orderedSame {
                return String(describing: value)
            }
        }
        return nil
    }

    /// Whether the answer can be the snapshot: a JSON `Content-Type` when one is declared, else
    /// a body whose first non-whitespace byte opens a JSON object or array. A login page or a
    /// CDN interstitial is HTML and fails both.
    static func looksLikeJSON(contentType: String?, body: Data) -> Bool {
        if let contentType {
            return contentType.lowercased().contains("json")
        }
        guard let first = body.first(where: { !($0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09) }) else { return false }
        return first == UInt8(ascii: "{") || first == UInt8(ascii: "[")
    }
}
