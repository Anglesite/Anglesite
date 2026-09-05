import Foundation
// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin
// platforms (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Discovers a target URL's declared RSS/Atom feed for the blogroll's OPML export (#1483):
/// fetch the target once, scan its `<link>` elements in document order for the first
/// `rel="alternate"` with an RSS or Atom `type`. Shares its tag/attribute scanning with
/// `WebmentionEndpointDiscovery` via ``HTMLLinkAttributeScanning``.
enum FeedEndpointDiscovery {
    private static let feedTypes: Set<String> = ["application/rss+xml", "application/atom+xml"]

    static func discover(target: URL, transport: POSSEHTTPTransport) async throws -> URL? {
        var request = URLRequest(url: target)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (data, http) = try await transport(request)
        let finalURL = http.url ?? target
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }

        for attrs in HTMLLinkAttributeScanning.tagAttributeStrings(in: html) {
            guard let rel = HTMLLinkAttributeScanning.attributeValue("rel", in: attrs),
                  isAlternateRel(rel),
                  let type = HTMLLinkAttributeScanning.attributeValue("type", in: attrs),
                  feedTypes.contains(type.lowercased()),
                  let href = HTMLLinkAttributeScanning.attributeValue("href", in: attrs)
            else { continue }
            if let url = URL(string: href, relativeTo: finalURL)?.absoluteURL, isHTTPOrHTTPS(url) {
                return url
            }
        }
        return nil
    }

    private static func isAlternateRel(_ rel: String) -> Bool {
        rel.split(whereSeparator: { $0.isWhitespace }).contains { $0.caseInsensitiveCompare("alternate") == .orderedSame }
    }

    /// A discovered feed URL gets committed into the owner's own git repo (write-back) and later
    /// emitted into `/blogroll.opml`, so a hostile or malformed target's markup can't smuggle a
    /// `javascript:`/`data:` (or other non-web) scheme through — filtered out here the same way a
    /// non-matching `rel`/`type` is: as "no feed found", not as an error (#1483 final review, Fix 7).
    private static func isHTTPOrHTTPS(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}
