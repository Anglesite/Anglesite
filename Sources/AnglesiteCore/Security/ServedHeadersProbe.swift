import Foundation
// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin
// platforms (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fetches a site's live response headers so ``ServedHeadersAudit`` can diff them against
/// `dist/_headers` (#2007). Folded into a single optional rather than a three-valued result like
/// `SitemapPreflightResult`: there's only one useful "don't know" bucket here, and `nil` means
/// exactly that — never report a declared header as missing from an answer the probe couldn't
/// actually get.
public protocol ServedHeadersProbing: Sendable {
    /// `GET https://{domain}/`, 5s timeout, following redirects. Returns the response headers on
    /// a 2xx; `nil` on anything else (ambiguous status, thrown request) — never throws.
    func fetchHeaders(domain: String) async -> [String: String]?
}

/// Live implementation, shaped like `HTTPSitemapPreflight`: a plain `URLSession` request behind
/// the package's standard `CloudflareTransport` seam. A non-2xx response or a thrown request
/// yields `nil`, not a failure — `SitemapPreflight.swift` documents exactly why (Bot Fight Mode
/// 403-challenging a bare `URLSession` on a perfectly deployed site; a 5xx origin hiccup); the
/// same reasoning applies here, and an unanswerable probe must never be reported as missing
/// headers.
public struct HTTPServedHeadersProbe: ServedHeadersProbing {
    /// Short deliberately: this runs inline in the domain-config audit, and a slow host shouldn't
    /// hold the owner hostage for an *advisory* answer.
    private static let timeout: TimeInterval = 5
    private let transport: CloudflareTransport

    /// The transport parameter exists for tests (fake responses, no network); production uses
    /// ``defaultTransport``.
    public init(transport: @escaping CloudflareTransport = HTTPServedHeadersProbe.defaultTransport) {
        self.transport = transport
    }

    /// Production transport: a plain shared-`URLSession` request, mirroring
    /// `HTTPCloudflareClient.defaultTransport`.
    public static let defaultTransport: CloudflareTransport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    public func fetchHeaders(domain: String) async -> [String: String]? {
        guard let url = URL(string: "https://\(domain)/") else { return nil }
        let request = URLRequest(url: url, timeoutInterval: Self.timeout)
        do {
            let (_, http) = try await transport(request)
            guard (200..<300).contains(http.statusCode) else { return nil }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                guard let name = key as? String, let stringValue = value as? String else { continue }
                headers[name] = stringValue
            }
            return headers
        } catch {
            return nil
        }
    }
}
