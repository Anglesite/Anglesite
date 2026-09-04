import Testing
import Foundation
@testable import AnglesiteCore

/// Tests `ATProtoOAuthClient`'s DPoP/PAR mechanics — pushed authorization request construction,
/// DPoP proof/nonce-retry handling, callback validation, and token exchange/refresh — all against
/// an injected `Transport`, no real network. Mirrors `CloudflareOAuthClientTests`/
/// `SiteIndieAuthClientTests`' style; identity resolution and auth-server discovery are a
/// separate, not-yet-scoped follow-up (see the design doc), so every endpoint here is passed in
/// already-resolved rather than discovered by the client itself.
@Suite(.serialized)
struct ATProtoOAuthClientTests {
    private let parEndpoint = URL(string: "https://pds.example/oauth/par")!
    private let authorizationEndpoint = URL(string: "https://pds.example/oauth/authorize")!
    private let tokenEndpoint = URL(string: "https://pds.example/oauth/token")!
    private let clientID = URL(string: "https://auth.anglesite.dwk.io/atproto/client-metadata.json")!
    private let redirectURI = URL(string: "io.dwk.anglesite://oauth-callback")!

    private func response(_ code: Int, url: URL, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: headers)!
    }

    private func base64urlDecode(_ segment: String) -> Data {
        var base64 = segment.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64) ?? Data()
    }

    private func jsonSegment(_ segment: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: base64urlDecode(segment))) as? [String: Any] ?? [:]
    }

    private func dpopClaims(from request: URLRequest) -> [String: Any] {
        guard let proof = request.value(forHTTPHeaderField: "DPoP") else { return [:] }
        let segments = proof.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { return [:] }
        return jsonSegment(String(segments[1]))
    }

    private func makeClient(transport: @escaping ATProtoOAuthClient.Transport) -> ATProtoOAuthClient {
        ATProtoOAuthClient(clientID: clientID, redirectURI: redirectURI, transport: transport)
    }

    // MARK: Pushed Authorization Request

    /// Parses a `application/x-www-form-urlencoded` body the same way the production code builds
    /// it (`URLComponents.percentEncodedQuery`), so assertions compare decoded values rather than
    /// hand-rolling percent-encoding themselves.
    private func formValues(_ body: String?) -> [String: String] {
        var components = URLComponents()
        components.percentEncodedQuery = body
        var result: [String: String] = [:]
        for item in components.queryItems ?? [] { result[item.name] = item.value }
        return result
    }

    @Test("pushAuthorizationRequest posts a DPoP-proofed PAR body and builds the authorize URL from request_uri")
    func pushBuildsAuthorizeURL() async throws {
        var capturedBody: String?
        var capturedRequest: URLRequest?
        let client = makeClient { req in
            capturedRequest = req
            capturedBody = req.httpBody.flatMap { String(data: $0, encoding: .utf8) }
            let body = #"{"request_uri":"urn:ietf:params:oauth:request_uri:abc123","expires_in":300}"#
            return (Data(body.utf8), self.response(200, url: self.parEndpoint))
        }
        let request = try await client.pushAuthorizationRequest(
            parEndpoint: parEndpoint, authorizationEndpoint: authorizationEndpoint,
            tokenEndpoint: tokenEndpoint, scope: "atproto transition:generic", dpopKeyPair: DPoPKeyPair())

        #expect(capturedRequest?.url == parEndpoint)
        #expect(capturedRequest?.httpMethod == "POST")
        let form = formValues(capturedBody)
        #expect(form["response_type"] == "code")
        #expect(form["client_id"] == clientID.absoluteString)
        #expect(form["redirect_uri"] == redirectURI.absoluteString)
        #expect(form["scope"] == "atproto transition:generic")
        #expect(form["code_challenge_method"] == "S256")
        #expect(form["code_challenge"]?.isEmpty == false)
        #expect(form["state"]?.isEmpty == false)

        let items = URLComponents(url: request.authorizeURL, resolvingAgainstBaseURL: false)!.queryItems!
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        #expect(request.authorizeURL.host == "pds.example")
        #expect(request.authorizeURL.path == "/oauth/authorize")
        #expect(items.count == 2) // only client_id + request_uri, per the PAR spec
        #expect(value("client_id") == clientID.absoluteString)
        #expect(value("request_uri") == "urn:ietf:params:oauth:request_uri:abc123")
    }

    @Test("the PAR request's DPoP proof binds htm/htu to the PAR endpoint, with no ath claim")
    func pushDPoPProofBindsToPAREndpoint() async throws {
        var capturedRequest: URLRequest?
        let client = makeClient { req in
            capturedRequest = req
            let body = #"{"request_uri":"urn:x","expires_in":300}"#
            return (Data(body.utf8), self.response(200, url: self.parEndpoint))
        }
        _ = try await client.pushAuthorizationRequest(
            parEndpoint: parEndpoint, authorizationEndpoint: authorizationEndpoint,
            tokenEndpoint: tokenEndpoint, scope: "atproto", dpopKeyPair: DPoPKeyPair())

        let claims = dpopClaims(from: try #require(capturedRequest))
        #expect(claims["htm"] as? String == "POST")
        #expect(claims["htu"] as? String == parEndpoint.absoluteString)
        #expect(claims["ath"] == nil)
        #expect(claims["nonce"] == nil)
    }

    @Test("a use_dpop_nonce challenge on PAR retries once with the echoed nonce")
    func pushRetriesOnceOnNonceChallenge() async throws {
        var attempts = 0
        let client = makeClient { req in
            attempts += 1
            if attempts == 1 {
                let body = #"{"error":"use_dpop_nonce"}"#
                return (Data(body.utf8), self.response(400, url: self.parEndpoint, headers: ["DPoP-Nonce": "server-nonce-1"]))
            }
            let claims = self.dpopClaims(from: req)
            #expect(claims["nonce"] as? String == "server-nonce-1")
            let body = #"{"request_uri":"urn:x","expires_in":300}"#
            return (Data(body.utf8), self.response(200, url: self.parEndpoint))
        }
        let request = try await client.pushAuthorizationRequest(
            parEndpoint: parEndpoint, authorizationEndpoint: authorizationEndpoint,
            tokenEndpoint: tokenEndpoint, scope: "atproto", dpopKeyPair: DPoPKeyPair())

        #expect(attempts == 2)
        #expect(URLComponents(url: request.authorizeURL, resolvingAgainstBaseURL: false)!
            .queryItems!.first { $0.name == "request_uri" }?.value == "urn:x")
    }

    @Test("a second nonce challenge is not retried again and surfaces as .pushedAuthorizationRequestFailed")
    func pushDoesNotRetryTwice() async {
        var attempts = 0
        let client = makeClient { _ in
            attempts += 1
            let body = #"{"error":"use_dpop_nonce"}"#
            return (Data(body.utf8), self.response(400, url: self.parEndpoint, headers: ["DPoP-Nonce": "nonce-\(attempts)"]))
        }
        await #expect(throws: ATProtoOAuthError.self) {
            _ = try await client.pushAuthorizationRequest(
                parEndpoint: parEndpoint, authorizationEndpoint: authorizationEndpoint,
                tokenEndpoint: tokenEndpoint, scope: "atproto", dpopKeyPair: DPoPKeyPair())
        }
        #expect(attempts == 2)
    }

    @Test("a non-2xx PAR response throws .pushedAuthorizationRequestFailed")
    func pushHTTPFailure() async {
        let client = makeClient { _ in (Data("bad".utf8), self.response(500, url: self.parEndpoint)) }
        await #expect(throws: ATProtoOAuthError.self) {
            _ = try await client.pushAuthorizationRequest(
                parEndpoint: parEndpoint, authorizationEndpoint: authorizationEndpoint,
                tokenEndpoint: tokenEndpoint, scope: "atproto", dpopKeyPair: DPoPKeyPair())
        }
    }

    @Test("an undecodable PAR response throws .pushedAuthorizationRequestFailed")
    func pushBadJSON() async {
        let client = makeClient { _ in (Data("not json".utf8), self.response(200, url: self.parEndpoint)) }
        await #expect(throws: ATProtoOAuthError.self) {
            _ = try await client.pushAuthorizationRequest(
                parEndpoint: parEndpoint, authorizationEndpoint: authorizationEndpoint,
                tokenEndpoint: tokenEndpoint, scope: "atproto", dpopKeyPair: DPoPKeyPair())
        }
    }

    // MARK: Callback validation (pure, no network)

    private func makeRequest(state: String = "abc123") -> ATProtoOAuthRequest {
        ATProtoOAuthRequest(
            authorizeURL: authorizationEndpoint, state: state, codeVerifier: "verifier",
            tokenEndpoint: tokenEndpoint)
    }

    @Test("a matching state yields the code")
    func callbackMatchingState() throws {
        let request = makeRequest()
        let callback = URL(string: "io.dwk.anglesite://oauth-callback?code=xyz&state=abc123")!
        #expect(try ATProtoOAuthClient.authorizationCode(from: callback, matching: request) == "xyz")
    }

    @Test("a mismatched state throws .stateMismatch, never returns the code")
    func callbackMismatchedState() {
        let request = makeRequest()
        let callback = URL(string: "io.dwk.anglesite://oauth-callback?code=xyz&state=WRONG")!
        #expect(throws: ATProtoOAuthError.stateMismatch) {
            _ = try ATProtoOAuthClient.authorizationCode(from: callback, matching: request)
        }
    }

    @Test("an error query param throws .callbackDenied when the state matches")
    func callbackDenied() {
        let request = makeRequest()
        let callback = URL(string: "io.dwk.anglesite://oauth-callback?error=access_denied&state=abc123")!
        #expect(throws: ATProtoOAuthError.callbackDenied("access_denied")) {
            _ = try ATProtoOAuthClient.authorizationCode(from: callback, matching: request)
        }
    }

    @Test("an error query param with a non-matching state throws .stateMismatch, not .callbackDenied")
    func callbackErrorWithMismatchedStateIsStateMismatch() {
        let request = makeRequest()
        let callback = URL(string: "io.dwk.anglesite://oauth-callback?error=access_denied&state=WRONG")!
        #expect(throws: ATProtoOAuthError.stateMismatch) {
            _ = try ATProtoOAuthClient.authorizationCode(from: callback, matching: request)
        }
    }

    @Test("a matching state but missing code throws .missingAuthorizationCode")
    func callbackMissingCode() {
        let request = makeRequest()
        let callback = URL(string: "io.dwk.anglesite://oauth-callback?state=abc123")!
        #expect(throws: ATProtoOAuthError.missingAuthorizationCode) {
            _ = try ATProtoOAuthClient.authorizationCode(from: callback, matching: request)
        }
    }

    // MARK: Token exchange

    @Test("exchange posts the PKCE verifier and a DPoP proof, decoding the token")
    func exchangeParsesToken() async throws {
        let request = ATProtoOAuthRequest(
            authorizeURL: authorizationEndpoint, state: "abc123", codeVerifier: "verifier",
            tokenEndpoint: tokenEndpoint)
        var capturedBody: String?
        var capturedRequest: URLRequest?
        var transportCallCount = 0
        let client = makeClient { req in
            transportCallCount += 1
            capturedRequest = req
            #expect(req.url == tokenEndpoint)
            #expect(req.httpMethod == "POST")
            capturedBody = req.httpBody.flatMap { String(data: $0, encoding: .utf8) }
            let body = #"{"access_token":"tok-123","token_type":"DPoP","expires_in":3600,"refresh_token":"refresh-abc"}"#
            return (Data(body.utf8), self.response(200, url: tokenEndpoint))
        }
        let token = try await client.exchange(code: "auth-code", for: request, dpopKeyPair: DPoPKeyPair())

        #expect(token.accessToken == "tok-123")
        #expect(token.tokenType == "DPoP")
        #expect(token.expiresIn == 3600)
        #expect(token.refreshToken == "refresh-abc")
        #expect(capturedBody?.contains("code_verifier=verifier") == true)
        #expect(capturedBody?.contains("code=auth-code") == true)
        #expect(capturedBody?.contains("grant_type=authorization_code") == true)
        #expect(capturedBody?.contains("redirect_uri=") == true)
        #expect(transportCallCount == 1)

        let claims = dpopClaims(from: try #require(capturedRequest))
        #expect(claims["htm"] as? String == "POST")
        #expect(claims["htu"] as? String == tokenEndpoint.absoluteString)
        #expect(claims["ath"] == nil) // no access token exists yet at exchange time
    }

    @Test("a use_dpop_nonce challenge on exchange retries once with the echoed nonce")
    func exchangeRetriesOnceOnNonceChallenge() async throws {
        let request = makeRequest()
        var attempts = 0
        let client = makeClient { req in
            attempts += 1
            if attempts == 1 {
                let body = #"{"error":"use_dpop_nonce"}"#
                return (Data(body.utf8), self.response(400, url: tokenEndpoint, headers: ["DPoP-Nonce": "nonce-1"]))
            }
            let claims = self.dpopClaims(from: req)
            #expect(claims["nonce"] as? String == "nonce-1")
            let body = #"{"access_token":"tok","token_type":"DPoP"}"#
            return (Data(body.utf8), self.response(200, url: tokenEndpoint))
        }
        let token = try await client.exchange(code: "auth-code", for: request, dpopKeyPair: DPoPKeyPair())
        #expect(attempts == 2)
        #expect(token.accessToken == "tok")
    }

    @Test("a non-2xx exchange response throws .tokenExchangeFailed")
    func exchangeHTTPFailure() async {
        let request = makeRequest()
        let client = makeClient { _ in (Data("bad code".utf8), self.response(400, url: tokenEndpoint)) }
        await #expect(throws: ATProtoOAuthError.self) {
            _ = try await client.exchange(code: "auth-code", for: request, dpopKeyPair: DPoPKeyPair())
        }
    }

    @Test("an undecodable exchange response throws .tokenExchangeFailed")
    func exchangeBadJSON() async {
        let request = makeRequest()
        let client = makeClient { _ in (Data("not json".utf8), self.response(200, url: tokenEndpoint)) }
        await #expect(throws: ATProtoOAuthError.self) {
            _ = try await client.exchange(code: "auth-code", for: request, dpopKeyPair: DPoPKeyPair())
        }
    }

    // MARK: Refresh

    @Test("refresh posts grant_type=refresh_token with a DPoP proof and decodes the rotated token")
    func refreshPostsGrantType() async throws {
        var capturedBody: String?
        let client = makeClient { req in
            capturedBody = req.httpBody.flatMap { String(data: $0, encoding: .utf8) }
            let body = #"{"access_token":"new-tok","token_type":"DPoP","expires_in":3600,"refresh_token":"new-refresh"}"#
            return (Data(body.utf8), self.response(200, url: tokenEndpoint))
        }
        let token = try await client.refresh(refreshToken: "old-refresh", tokenEndpoint: tokenEndpoint, dpopKeyPair: DPoPKeyPair())

        #expect(token.accessToken == "new-tok")
        // atproto rotates refresh tokens per use — the caller must persist the *new* one, never
        // the one that was just consumed.
        #expect(token.refreshToken == "new-refresh")
        #expect(capturedBody?.contains("grant_type=refresh_token") == true)
        #expect(capturedBody?.contains("refresh_token=old-refresh") == true)
    }

    @Test("a non-2xx refresh response throws .sessionExpired, not .tokenExchangeFailed")
    func refreshHTTPFailureIsSessionExpired() async {
        let client = makeClient { _ in (Data("revoked".utf8), self.response(400, url: tokenEndpoint)) }
        await #expect(throws: ATProtoOAuthError.sessionExpired) {
            _ = try await client.refresh(refreshToken: "old", tokenEndpoint: tokenEndpoint, dpopKeyPair: DPoPKeyPair())
        }
    }
}
