import Foundation
// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin
// platforms (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What standard Micropub client discovery finds on a site's homepage (#868): the write
/// endpoint itself plus the IndieAuth server-metadata document sign-in starts from.
public struct SiteMicropubEndpoints: Sendable, Equatable {
    /// The site's Micropub endpoint (`rel="micropub"`).
    public let micropub: URL
    /// The RFC 8414 authorization-server metadata document (`rel="indieauth-metadata"`) —
    /// what `SiteIndieAuthClient.makeAuthorizationRequest(metadataURL:…)` consumes.
    public let indieAuthMetadata: URL
}

/// Discovery failures, kept distinct so the UI can name the real problem: an unreachable site
/// is a network condition, a missing `rel` means the site's Worker simply doesn't offer the
/// capability yet (the V-3 conformance story) — conflating them would misdirect the owner.
public enum MicropubDiscoveryError: Error, Equatable, Sendable {
    /// The homepage couldn't be fetched (network failure or non-2xx status).
    case unreachable(String)
    /// The homepage advertises no `rel="micropub"` — the site doesn't offer Micropub yet.
    case micropubNotAdvertised
    /// The homepage advertises no `rel="indieauth-metadata"` — no IndieAuth server to sign in
    /// against.
    case indieAuthNotAdvertised
}

/// Standard Micropub client discovery (#868): fetch the site's homepage and read the
/// `micropub` + `indieauth-metadata` rel values from its HTTP `Link` headers and HTML
/// `<link>` elements — `Link` headers win, per the Micropub spec's discovery order. This is
/// the entry point of the iOS posting client's onboarding: it turns "a site picked from the
/// iCloud list" into concrete endpoints without any hardcoded paths.
public struct MicropubEndpointDiscovery: Sendable {
    /// The single seam all network traffic flows through, so tests exercise discovery with
    /// canned responses and zero real networking. Mirrors `SiteIndieAuthClient.Transport`.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let transport: Transport

    /// Defaults to ``defaultTransport`` (plain `URLSession`); inject a fake to unit-test.
    public init(transport: @escaping Transport = MicropubEndpointDiscovery.defaultTransport) {
        self.transport = transport
    }

    /// Fetches `siteURL` and resolves both endpoints, throwing the first
    /// ``MicropubDiscoveryError`` encountered. Relative hrefs resolve against the response's
    /// final URL (not the input), so a site that redirects — say to its `www.` host — yields
    /// endpoints on the host that actually serves it.
    public func discover(siteURL: URL) async throws -> SiteMicropubEndpoints {
        var request = URLRequest(url: siteURL)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let data: Data, http: HTTPURLResponse
        do {
            (data, http) = try await transport(request)
        } catch {
            throw MicropubDiscoveryError.unreachable(error.localizedDescription)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MicropubDiscoveryError.unreachable("HTTP \(http.statusCode)")
        }

        let baseURL = http.url ?? siteURL
        let html = String(data: data, encoding: .utf8) ?? ""
        let linkHeader = http.value(forHTTPHeaderField: "Link") ?? ""

        func endpoint(rel: String) -> URL? {
            // `Link` headers take precedence over HTML <link> elements (Micropub §3.3).
            let href = Self.href(rel: rel, inLinkHeader: linkHeader)
                ?? Self.href(rel: rel, inHTML: html)
            return href.flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }
        }

        guard let micropub = endpoint(rel: "micropub") else {
            throw MicropubDiscoveryError.micropubNotAdvertised
        }
        guard let metadata = endpoint(rel: "indieauth-metadata") else {
            throw MicropubDiscoveryError.indieAuthNotAdvertised
        }
        return SiteMicropubEndpoints(micropub: micropub, indieAuthMetadata: metadata)
    }

    /// Production transport: a plain `URLSession` GET following redirects, no auth.
    public static let defaultTransport: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    // MARK: - rel parsing

    /// First target in an RFC 8288 `Link` header whose `rel` list contains `rel`. Handles the
    /// combined form `HTTPURLResponse` returns for repeated headers (comma-joined values):
    /// each `<target>; params` element is scanned independently.
    static func href(rel: String, inLinkHeader header: String) -> String? {
        guard !header.isEmpty else { return nil }
        // `<([^>]*)>` — the target; `([^,<]*)` — its params, up to the next element. Splitting
        // on bare commas would break `rel="a b"` never, but a quoted comma in a param could
        // confuse it; targets can't contain `<`/`>`, so anchoring on them is robust for the
        // header shapes IndieAuth/Micropub servers emit.
        let pattern = #/<([^>]*)>\s*;([^<]*)/#
        for match in header.matches(of: pattern) {
            let params = String(match.output.2)
            if relList(inParams: params).contains(rel) {
                return String(match.output.1)
            }
        }
        return nil
    }

    /// The `rel` param's whitespace-separated tokens from one Link element's parameter string.
    private static func relList(inParams params: String) -> Set<String> {
        let pattern = #/rel\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s;,]+))/#.ignoresCase()
        guard let match = params.firstMatch(of: pattern) else { return [] }
        let value = match.output.1 ?? match.output.2 ?? match.output.3 ?? ""
        return Set(value.split(separator: " ").map(String.init))
    }

    /// First `<link>` element in `html` whose `rel` list contains `rel`, returning its `href`.
    /// A lenient scan, not a full HTML parse (no third-party frameworks): case-insensitive tag
    /// and attribute names, any attribute order, double/single/no quotes — covering what the
    /// template's `BaseLayout.astro` renders plus reasonable hand-edited variation.
    static func href(rel: String, inHTML html: String) -> String? {
        let tagPattern = #/<link\b[^>]*>/#.ignoresCase()
        // Unquoted values run to whitespace or `>` — they may contain `/` (URLs), so a
        // self-closing tag needs a space before its `/>` for an unquoted final attribute,
        // which is how browsers parse it too.
        let attrPattern = #/([a-zA-Z][a-zA-Z0-9-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/#
        for tagMatch in html.matches(of: tagPattern) {
            var attributes: [String: String] = [:]
            for attr in String(tagMatch.output).matches(of: attrPattern) {
                let name = String(attr.output.1).lowercased()
                let value = attr.output.2 ?? attr.output.3 ?? attr.output.4 ?? ""
                // First occurrence wins, matching browser behavior for duplicate attributes.
                if attributes[name] == nil { attributes[name] = String(value) }
            }
            guard let relValue = attributes["rel"],
                  relValue.split(separator: " ").map(String.init).contains(rel),
                  let href = attributes["href"], !href.isEmpty
            else { continue }
            return href
        }
        return nil
    }
}
