import Foundation
// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin
// platforms (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Resolves a blogroll target's `site.standard.publication` at-URI by fetching *their*
/// `/.well-known/site.standard.publication` — the reverse direction of the verification
/// `Resources/Template/scripts/edge-artifacts.ts`'s `applyStandardSitePublicationPlan` emits for
/// this app's own site. `nil` is the expected, common outcome (most blogroll targets don't run
/// standard.site) — never thrown as an error.
public enum StandardSitePublicationResolver {
    /// Matches `at://<did>/site.standard.publication/<rkey>` — same shape check as the
    /// template's `isStandardSitePublicationURI`.
    private static let publicationURIPattern: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: #"^at://[^/]+/site\.standard\.publication/[^/\s]+$"#)
        } catch {
            fatalError("Invalid standard.site publication URI regex: \(error)")
        }
    }()

    public static func resolve(homepage: URL, transport: POSSEHTTPTransport) async -> String? {
        guard let host = homepage.host else { return nil }
        var components = URLComponents()
        components.scheme = homepage.scheme ?? "https"
        components.host = host
        components.port = homepage.port
        components.path = "/.well-known/site.standard.publication"
        guard let wellKnownURL = components.url else { return nil }

        let request = URLRequest(url: wellKnownURL)
        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await transport(request)
        } catch {
            return nil
        }
        guard (200..<300).contains(http.statusCode) else { return nil }
        let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        guard publicationURIPattern.firstMatch(in: body, range: range) != nil else { return nil }
        return body
    }
}
