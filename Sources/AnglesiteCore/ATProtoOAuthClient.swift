import Foundation
// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin
// platforms (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

/// atproto OAuth's own registered "native" client identity. Unlike `CloudflareOAuthConfiguration`'s
/// opaque registered string, atproto's `client_id` is itself a URL that must resolve to a public
/// JSON client-metadata document (`redirect_uris`, `grant_types`, `scope`, …) — served by the
/// callback Worker (#1889), same origin as the redirect below.
public enum ATProtoOAuthConfiguration {
    /// Also the client-metadata document URL (owner-decided, 2026-09-04) — #1889's Worker route.
    public static let clientID = URL(string: "https://auth.anglesite.dwk.io/atproto/client-metadata.json")!
    /// Custom URI scheme redirect (locked decision in the design doc): simpler than Associated
    /// Domains, no domain-verification dependency, and the typical shape for atproto native OAuth
    /// clients — deliberately diverges from `CloudflareOAuthConfiguration`'s universal-link choice.
    /// Matches `SiteIndieAuthAppAuth`'s existing `io.dwk.anglesite://` scheme shape.
    public static let redirectURI = URL(string: "io.dwk.anglesite://oauth-callback")!
}

/// The PAR endpoint's response (RFC 9126 §2.2): a `request_uri` reference the authorize URL
/// carries instead of the full parameter set, plus its lifetime.
private struct PushedAuthorizationResponse: Decodable {
    let requestURI: String
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case requestURI = "request_uri"
        case expiresIn = "expires_in"
    }
}

/// One PAR + authorize attempt's outcome: the URL to present plus what's needed to complete it
/// once a callback comes back. Mirrors `CloudflareOAuthRequest`'s shape — `state`/`codeVerifier`
/// stay internal so callers can't leak or tamper with them, only hand the whole value back to the
/// completion APIs.
public struct ATProtoOAuthRequest: Sendable {
    /// The URL to present in the browser (`ASWebAuthenticationSession`). Carries only `client_id`
    /// and `request_uri` — per the PAR spec, the rest of the authorize params already reached the
    /// server via the pushed request, so they're never repeated here.
    public let authorizeURL: URL
    let state: String
    let codeVerifier: String
    /// Resolved once by whoever discovered the auth server's metadata and handed it to
    /// `pushAuthorizationRequest`; carried here so `exchange` reuses it without rediscovery.
    public let tokenEndpoint: URL

    public init(authorizeURL: URL, state: String, codeVerifier: String, tokenEndpoint: URL) {
        self.authorizeURL = authorizeURL
        self.state = state
        self.codeVerifier = codeVerifier
        self.tokenEndpoint = tokenEndpoint
    }
}

/// The token response from an atproto authorization server's `/token` endpoint. DPoP-bound
/// (`token_type` is `DPoP`, not `Bearer`) — every subsequent XRPC call must accompany the access
/// token with a proof signed by the same `DPoPKeyPair` that ran this exchange, not just present it
/// as a bearer header.
public struct ATProtoOAuthTokenResponse: Decodable, Sendable, Equatable {
    public let accessToken: String
    public let tokenType: String
    public let expiresIn: Int?
    /// atproto rotates refresh tokens on every use (unlike Cloudflare) — callers must persist
    /// this value immediately, overwriting whatever refresh token was just consumed.
    public let refreshToken: String?
    public let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
    }
}

/// Failure modes across the PAR push → authorize → callback → exchange/refresh flow. `Equatable`
/// so tests can assert exact cases, mirroring `CloudflareOAuthError`/`SiteIndieAuthError`. Identity
/// resolution and auth-server discovery aren't this type's job (a separate, not-yet-scoped
/// component per the design doc), so there's no case for either failing here.
public enum ATProtoOAuthError: Error, Equatable, Sendable {
    /// The PAR endpoint rejected the pushed request or returned something undecodable.
    case pushedAuthorizationRequestFailed(String)
    /// The callback's `state` didn't match the one this request minted — possible CSRF, never
    /// silently accepted.
    case stateMismatch
    /// The authorization server (or the user) denied the request, e.g. `error=access_denied`.
    case callbackDenied(String)
    /// The callback had a matching `state` but no `code`.
    case missingAuthorizationCode
    /// The token endpoint rejected the exchange or returned something undecodable.
    case tokenExchangeFailed(String)
    /// Signing the DPoP proof needs CryptoKit (Apple platforms only).
    case dpopUnavailable
    /// A refresh was rejected — atproto rotates refresh tokens per use, so a revoked/expired/
    /// already-consumed token always means "run the full sign-in flow again," never "retry the
    /// same token." Distinct from `.tokenExchangeFailed` so a caller can tell the two apart.
    case sessionExpired
}

/// Pushed Authorization Request (RFC 9126) + DPoP-bound token exchange/refresh against an
/// atproto authorization server — the "DPoP/PAR client mechanics" slice of atproto OAuth (#1890).
/// Every endpoint (PAR, authorize, token) is passed in already-resolved: identity resolution
/// (handle/DID → PDS) and auth-server metadata discovery are a distinct, not-yet-scoped follow-up
/// per the design doc, so this type has no network step of its own beyond PAR/exchange/refresh.
///
/// This type only builds requests, parses callbacks, and exchanges/refreshes tokens — presenting
/// the actual browser sheet (`ASWebAuthenticationSession`) is the caller's job, kept out of this
/// type entirely so it stays fully unit-testable without `AuthenticationServices` or any UI, the
/// same separation `CloudflareOAuthClient`/`SiteIndieAuthClient` keep.
public struct ATProtoOAuthClient: Sendable {
    /// One HTTP round trip. Injected so tests drive PAR, callback, and exchange/refresh handling
    /// without network — the same seam `CloudflareOAuthClient`/`SiteIndieAuthClient` use.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let clientID: URL
    private let redirectURI: URL
    private let transport: Transport

    /// Creates a client. Defaults to the registered Anglesite client (`ATProtoOAuthConfiguration`)
    /// and the production transport; override both for tests.
    public init(
        clientID: URL = ATProtoOAuthConfiguration.clientID,
        redirectURI: URL = ATProtoOAuthConfiguration.redirectURI,
        transport: @escaping Transport = ATProtoOAuthClient.defaultTransport
    ) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.transport = transport
    }

    /// Pushes an authorization request (RFC 9126) to `parEndpoint`, DPoP-proofed with
    /// `dpopKeyPair`, then builds the resulting authorize URL against `authorizationEndpoint` —
    /// carrying only `client_id` and `request_uri`, per the PAR spec. `tokenEndpoint` rides along
    /// in the returned request purely so `exchange` can reuse it later without rediscovery.
    ///
    /// Handles the DPoP nonce challenge the same way `SiteIndieAuthClient.exchange` does: a first
    /// attempt with no nonce, and — if the server answers with an RFC 9449 §8 `use_dpop_nonce`
    /// challenge — exactly one retry echoing the nonce. Anything else, including a second
    /// challenge, surfaces as `.pushedAuthorizationRequestFailed`.
    public func pushAuthorizationRequest(
        parEndpoint: URL,
        authorizationEndpoint: URL,
        tokenEndpoint: URL,
        scope: String,
        dpopKeyPair: DPoPKeyPair
    ) async throws -> ATProtoOAuthRequest {
        let verifier = Self.makeCodeVerifier()
        let state = Self.makeState()
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID.absoluteString),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: try Self.codeChallenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        let bodyData = Data((form.percentEncodedQuery ?? "").utf8)

        func makeRequest(nonce: String?) throws -> URLRequest {
            var urlRequest = URLRequest(url: parEndpoint)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = bodyData
            do {
                urlRequest.setValue(
                    try dpopKeyPair.proof(htm: "POST", htu: parEndpoint.absoluteString, nonce: nonce),
                    forHTTPHeaderField: "DPoP")
            } catch is DPoPError {
                throw ATProtoOAuthError.dpopUnavailable
            }
            return urlRequest
        }

        var (data, http) = try await sendPAR(makeRequest(nonce: nil))
        if let nonce = DPoPNonceChallenge.nonce(in: data, response: http) {
            (data, http) = try await sendPAR(makeRequest(nonce: nonce))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ATProtoOAuthError.pushedAuthorizationRequestFailed(
                "HTTP \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
        }
        let pushed: PushedAuthorizationResponse
        do {
            pushed = try JSONDecoder().decode(PushedAuthorizationResponse.self, from: data)
        } catch {
            throw ATProtoOAuthError.pushedAuthorizationRequestFailed("bad response: \(error)")
        }

        guard var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false) else {
            throw ATProtoOAuthError.pushedAuthorizationRequestFailed("malformed authorization endpoint")
        }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID.absoluteString),
            URLQueryItem(name: "request_uri", value: pushed.requestURI),
        ]
        guard let authorizeURL = components.url else {
            throw ATProtoOAuthError.pushedAuthorizationRequestFailed("couldn't build the authorize URL")
        }
        return ATProtoOAuthRequest(
            authorizeURL: authorizeURL, state: state, codeVerifier: verifier, tokenEndpoint: tokenEndpoint)
    }

    /// Extracts and validates the authorization code from a completed browser session's callback
    /// URL against the `state` minted for `request`. Static and side-effect-free: pure URL
    /// parsing, mirroring `CloudflareOAuthClient.authorizationCode(from:matching:)`.
    public static func authorizationCode(from callbackURL: URL, matching request: ATProtoOAuthRequest) throws -> String {
        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        guard let state = value("state"), state == request.state else {
            throw ATProtoOAuthError.stateMismatch
        }
        if let error = value("error") {
            throw ATProtoOAuthError.callbackDenied(value("error_description") ?? error)
        }
        guard let code = value("code"), !code.isEmpty else {
            throw ATProtoOAuthError.missingAuthorizationCode
        }
        return code
    }

    /// Exchanges `code` (from `authorizationCode(from:matching:)`) + the matching request's PKCE
    /// verifier for a DPoP-bound access token, proving possession of `dpopKeyPair` at the token
    /// endpoint (RFC 9449 §5) — the same key pair must sign every later resource-request proof and
    /// any future refresh, since the minted token's `cnf.jkt` binds to it.
    public func exchange(
        code: String,
        for request: ATProtoOAuthRequest,
        dpopKeyPair: DPoPKeyPair
    ) async throws -> ATProtoOAuthTokenResponse {
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "client_id", value: clientID.absoluteString),
            URLQueryItem(name: "code_verifier", value: request.codeVerifier),
        ]
        return try await postToken(form: form, tokenEndpoint: request.tokenEndpoint, dpopKeyPair: dpopKeyPair)
    }

    /// Exchanges a stored refresh token for a new DPoP-bound access token — no discovery, no PKCE,
    /// since those belong to the original interactive `pushAuthorizationRequest`/`exchange` already
    /// resolved once. atproto rotates refresh tokens per use: the returned response's
    /// `refreshToken` is what the caller must persist, never the one passed in here.
    ///
    /// Any failure (HTTP or transport) surfaces as `.sessionExpired`, not `.tokenExchangeFailed` —
    /// per the design doc, a refresh failure always means "run the full sign-in flow again."
    public func refresh(
        refreshToken: String,
        tokenEndpoint: URL,
        dpopKeyPair: DPoPKeyPair
    ) async throws -> ATProtoOAuthTokenResponse {
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientID.absoluteString),
        ]
        do {
            return try await postToken(form: form, tokenEndpoint: tokenEndpoint, dpopKeyPair: dpopKeyPair)
        } catch ATProtoOAuthError.tokenExchangeFailed {
            throw ATProtoOAuthError.sessionExpired
        }
    }

    /// Shared POST body for `exchange`/`refresh`: DPoP-proofs `form` against `tokenEndpoint` with
    /// the same nonce-retry-once behavior as `pushAuthorizationRequest`, then decodes the token.
    private func postToken(
        form: URLComponents,
        tokenEndpoint: URL,
        dpopKeyPair: DPoPKeyPair
    ) async throws -> ATProtoOAuthTokenResponse {
        let bodyData = Data((form.percentEncodedQuery ?? "").utf8)

        func makeRequest(nonce: String?) throws -> URLRequest {
            var urlRequest = URLRequest(url: tokenEndpoint)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = bodyData
            do {
                urlRequest.setValue(
                    try dpopKeyPair.proof(htm: "POST", htu: tokenEndpoint.absoluteString, nonce: nonce),
                    forHTTPHeaderField: "DPoP")
            } catch is DPoPError {
                throw ATProtoOAuthError.dpopUnavailable
            }
            return urlRequest
        }

        var (data, http) = try await sendToken(makeRequest(nonce: nil))
        if let nonce = DPoPNonceChallenge.nonce(in: data, response: http) {
            (data, http) = try await sendToken(makeRequest(nonce: nonce))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ATProtoOAuthError.tokenExchangeFailed("HTTP \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
        }
        do {
            return try JSONDecoder().decode(ATProtoOAuthTokenResponse.self, from: data)
        } catch {
            throw ATProtoOAuthError.tokenExchangeFailed("bad response: \(error)")
        }
    }

    private func sendPAR(_ urlRequest: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport(urlRequest)
        } catch {
            throw ATProtoOAuthError.pushedAuthorizationRequestFailed(error.localizedDescription)
        }
    }

    private func sendToken(_ urlRequest: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport(urlRequest)
        } catch {
            throw ATProtoOAuthError.tokenExchangeFailed(error.localizedDescription)
        }
    }

    /// Production transport: a plain `URLSession` POST, no auth of its own.
    public static let defaultTransport: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    /// 32 random bytes, base64url-encoded (no padding) — well within RFC 7636's 43-128 char range.
    /// Mirrors `CloudflareOAuthClient.makeCodeVerifier()`/`SiteIndieAuthClient.makeCodeVerifier()`.
    static func makeCodeVerifier() -> String {
        var rng = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        return base64URLEncode(Data(bytes))
    }

    static func makeState() -> String {
        var rng = SystemRandomNumberGenerator()
        let bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        return base64URLEncode(Data(bytes))
    }

    #if canImport(CryptoKit)
    static func codeChallenge(for verifier: String) throws -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(digest))
    }
    #else
    static func codeChallenge(for verifier: String) throws -> String {
        // OAuth login only ever happens from the UI layer (`ASWebAuthenticationSession`), which
        // doesn't exist on Linux either — matches CloudflareOAuthClient.codeChallenge(for:)'s posture.
        throw ATProtoOAuthError.pushedAuthorizationRequestFailed("PKCE S256 challenge needs CryptoKit (Apple platforms only)")
    }
    #endif

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
