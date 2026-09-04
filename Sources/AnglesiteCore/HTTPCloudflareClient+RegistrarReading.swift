import Foundation
// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin
// platforms (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private struct CFRegistrarSearchResult: Decodable, Sendable {
    let name: String
}
/// The Registrar search/check `result` is an object wrapping a `domains` array (not a bare
/// array like most other Cloudflare v4 list endpoints) — confirmed against the live API docs.
private struct CFRegistrarSearchResponse: Decodable, Sendable {
    let domains: [CFRegistrarSearchResult]
}
private struct CFRegistrarCheckResult: Decodable, Sendable {
    let name: String
    let registrable: Bool
    let reason: String?
    let pricing: Pricing?
    struct Pricing: Decodable, Sendable {
        let currency: String
        let registration_cost: String
        let renewal_cost: String
    }
}
private struct CFRegistrarCheckResponse: Decodable, Sendable {
    let domains: [CFRegistrarCheckResult]
}
private struct CFRegistrarCheckRequest: Encodable, Sendable {
    let domains: [String]
}

// MARK: - CloudflareRegistrarReading conformance

extension HTTPCloudflareClient: CloudflareRegistrarReading {
    /// Public entry point for the token's first visible account id — for callers that need it
    /// directly rather than through one of this type's already-account-scoped operations (e.g.
    /// `SocialWorkerProvisionCommand`'s inbox-capture provisioning, #764).
    public func accountID(apiToken: String) async throws -> String {
        try await core.resolveAccountID(apiToken: apiToken)
    }

    /// See ``CloudflareRegistrarReading/searchDomains(query:apiToken:)``.
    ///
    /// Builds the request with `URLComponents`/`URLQueryItem` rather than manual string
    /// interpolation: `query` is free-text (e.g. a business name like "Smith & Sons"), and
    /// `CharacterSet.urlQueryAllowed` — the encoding used elsewhere in this client for hostnames,
    /// which never contain `&`/`=`/`+` — does not escape those characters. Left unescaped, `&`/`=`
    /// would truncate the `q` value at the API and corrupt or drop the `limit` parameter.
    ///
    /// `+` needs separate handling: `URLComponents.queryItems`/`.url` treat it as a legal RFC 3986
    /// sub-delimiter and never percent-encode it, but many server-side query parsers conventionally
    /// form-decode a literal `+` as a space. Left as-is, a search for "A+ Dental" or "C++ Institute"
    /// would silently arrive at the API as "A Dental" / "C  Institute". So `q`'s value is percent-encoded
    /// by hand — down to RFC 3986 unreserved characters, which also covers `&`/`=` — and assigned via
    /// `percentEncodedQueryItems` rather than `queryItems` (which would double-encode it).
    public func searchDomains(query: String, apiToken: String) async throws -> [String] {
        let accountID = try await core.resolveAccountID(apiToken: apiToken)
        guard var components = URLComponents(string: Self.base + "/accounts/\(accountID)/registrar/domain-search") else {
            throw CloudflareError.malformedResponse
        }
        var queryValueAllowed = CharacterSet.alphanumerics
        queryValueAllowed.insert(charactersIn: "-._~")
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) else {
            throw CloudflareError.malformedResponse
        }
        components.percentEncodedQueryItems = [
            URLQueryItem(name: "q", value: encodedQuery),
            URLQueryItem(name: "limit", value: "20"),
        ]
        guard let url = components.url else { throw CloudflareError.malformedResponse }
        let response = try await core.get(url: url, apiToken: apiToken, as: CFRegistrarSearchResponse.self)
        return response.domains.map(\.name)
    }

    /// See ``CloudflareRegistrarReading/checkDomainAvailability(domains:apiToken:)``.
    public func checkDomainAvailability(domains: [String], apiToken: String) async throws -> [RegistrarDomainCheck] {
        let accountID = try await core.resolveAccountID(apiToken: apiToken)
        let response = try await core.post(
            "/accounts/\(accountID)/registrar/domain-check",
            body: CFRegistrarCheckRequest(domains: domains), apiToken: apiToken,
            as: CFRegistrarCheckResponse.self)
        return response.domains.map {
            RegistrarDomainCheck(
                name: $0.name, registrable: $0.registrable, reason: $0.reason,
                registrationCost: $0.pricing?.registration_cost, currency: $0.pricing?.currency)
        }
    }
}
