import Foundation
// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin
// platforms (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What a sitemap reachability probe learned. Three-valued rather than a `Bool` because a
/// probe that couldn't get an HTTP answer at all must not be conflated with a definitive
/// "no sitemap" — the preflight is advisory, and only a definitive answer may block (#1494).
public enum SitemapPreflightResult: Sendable, Equatable {
    /// An HTTP 2xx came back — the sitemap is live at the domain.
    case reachable
    /// The server definitively said the sitemap isn't there (404/410). Only these statuses
    /// count: anything else non-2xx can't distinguish "no sitemap" from the *probe itself*
    /// being rejected — notably Bot Fight Mode 403-challenging a bare `URLSession` request on
    /// a perfectly deployed site (the same bot-detection this feature's WAF skip rule exists
    /// for, see `AISearchExecutor`), or an origin hiccup (5xx).
    case unreachable
    /// Anything that isn't a definitive answer: no HTTP response at all (timeout, DNS
    /// failure, TLS error, …) or an ambiguous status (403 challenge, 429, 5xx). Treat as
    /// "don't know" and let the create call itself decide — the 7028 mapping (#1486)
    /// remains the backstop.
    case indeterminate
}

/// Probes whether a domain serves a sitemap, so the AI Search wizard can surface the
/// deploy-first fix *before* the owner is asked to confirm cost (#1494) instead of after a
/// failed create (#1486). Seam-shaped like the other Cloudflare clients: tests stub it.
public protocol SitemapPreflighting: Sendable {
    /// Checks `https://{domain}/sitemap.xml`. Never throws — every failure mode is folded
    /// into ``SitemapPreflightResult``.
    func checkSitemap(domain: String) async -> SitemapPreflightResult
}

/// Live implementation: `HEAD https://{domain}/sitemap.xml` with a short timeout. Some hosts
/// answer HEAD oddly, so a 405/501 falls back to a one-byte ranged GET before concluding
/// anything. Redirects are followed (the transport's URLSession default) — a sitemap behind
/// a canonical-host redirect still counts as reachable.
public struct HTTPSitemapPreflight: SitemapPreflighting {
    /// Short deliberately: this runs inline in the wizard's zone-resolution step, and a slow
    /// host shouldn't hold the owner hostage for an *advisory* answer.
    private static let timeout: TimeInterval = 5
    private let transport: CloudflareTransport

    /// The transport parameter exists for tests (fake responses, no network); production uses
    /// ``defaultTransport``. Reuses the ``CloudflareTransport`` seam shape even though this
    /// probe never talks to Cloudflare — it's the package's standard injectable HTTP boundary.
    public init(transport: @escaping CloudflareTransport = HTTPSitemapPreflight.defaultTransport) {
        self.transport = transport
    }

    /// Production transport: a plain shared-`URLSession` request, mirroring
    /// `HTTPCloudflareClient.defaultTransport`.
    public static let defaultTransport: CloudflareTransport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    public func checkSitemap(domain: String) async -> SitemapPreflightResult {
        guard let url = URL(string: "https://\(domain)/sitemap.xml") else { return .indeterminate }
        var head = URLRequest(url: url, timeoutInterval: Self.timeout)
        head.httpMethod = "HEAD"
        do {
            let (_, http) = try await transport(head)
            if http.statusCode == 405 || http.statusCode == 501 {
                // Host doesn't do HEAD — ask again with the cheapest possible GET.
                var get = URLRequest(url: url, timeoutInterval: Self.timeout)
                get.setValue("bytes=0-0", forHTTPHeaderField: "Range")
                let (_, getHTTP) = try await transport(get)
                return Self.result(forStatus: getHTTP.statusCode)
            }
            return Self.result(forStatus: http.statusCode)
        } catch {
            return .indeterminate
        }
    }

    /// See ``SitemapPreflightResult``'s case docs for why only 404/410 are definitive.
    private static func result(forStatus status: Int) -> SitemapPreflightResult {
        switch status {
        case 200..<300: return .reachable
        case 404, 410: return .unreachable
        default: return .indeterminate
        }
    }
}
