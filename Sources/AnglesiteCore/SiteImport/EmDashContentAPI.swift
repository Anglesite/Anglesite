import Foundation
// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin
// (AnglesiteCore is in the Linux portable target set — see WXRAssetDownloader.swift).
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The one HTTP call ``EmDashContentAPI`` makes, as a seam so tests can answer it without a
/// network and the app can route it through whatever session policy it already has. Wrap a
/// `URLSession` with ``EmDashContentAPI/init(session:)``.
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

/// Why ``EmDashContentAPI/fetchExport(siteURL:token:)`` couldn't read the site.
public enum EmDashContentAPIError: Error, Equatable {
    /// `siteURL` isn't an `http`/`https` URL with a host.
    case invalidSiteURL(String)
    /// The site answered 401/403 — the token is missing, expired, or lacks `content:read` +
    /// `schema:read`.
    case unauthorized
    /// The site answered 404 — there's no EmDash at this URL (or its API is mounted elsewhere).
    case notEmDash
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
public struct EmDashContentAPI: Sendable {
    private let client: any EmDashHTTPClient

    /// Creates a client over an HTTP seam.
    /// - Parameter client: The HTTP seam; `nil` uses an ephemeral `URLSession` (no cookies, no
    ///   cache — a one-off read of an export, not a browsing session).
    public init(client: (any EmDashHTTPClient)? = nil) {
        if let client {
            self.client = client
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = NetworkTimeouts.emdashSnapshotRequest
            config.timeoutIntervalForResource = NetworkTimeouts.emdashSnapshotResource
            self.client = URLSessionClient(session: URLSession(configuration: config))
        }
    }

    /// Creates a client over a caller-configured `URLSession`.
    /// - Parameter session: The session to send the snapshot request through.
    public init(session: URLSession) {
        self.client = URLSessionClient(session: session)
    }

    /// The snapshot endpoint for a site.
    /// - Parameter siteURL: The EmDash site's public URL (`https://blog.example`, with or
    ///   without a path or trailing slash — only the origin is used).
    /// - Returns: `<origin>/_emdash/api/snapshot`.
    /// - Throws: ``EmDashContentAPIError/invalidSiteURL(_:)``.
    public static func snapshotURL(siteURL: String) throws -> URL {
        let trimmed = siteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else {
            throw EmDashContentAPIError.invalidSiteURL(siteURL)
        }
        components.scheme = scheme
        components.path = "/_emdash/api/snapshot"
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw EmDashContentAPIError.invalidSiteURL(siteURL) }
        return url
    }

    /// Fetches the site's snapshot JSON.
    /// - Parameters:
    ///   - siteURL: The EmDash site's public URL.
    ///   - token: The EmDash API token, sent as `Authorization: Bearer`.
    /// - Returns: The raw response body on a 2xx.
    /// - Throws: ``EmDashContentAPIError``, or the transport error the client raised.
    public func fetchSnapshot(siteURL: String, token: String) async throws -> Data {
        var request = URLRequest(url: try Self.snapshotURL(siteURL: siteURL))
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await client.data(for: request)
        guard let http = response as? HTTPURLResponse else { return data }
        switch http.statusCode {
        case 200...299: return data
        case 401, 403: throw EmDashContentAPIError.unauthorized
        case 404: throw EmDashContentAPIError.notEmDash
        default: throw EmDashContentAPIError.httpStatus(http.statusCode)
        }
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
}
