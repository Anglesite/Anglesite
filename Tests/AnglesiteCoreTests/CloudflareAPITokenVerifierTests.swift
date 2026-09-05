import Testing
import Foundation
@testable import AnglesiteCore

/// Tests for the native (Node-free) Cloudflare token verifier. The HTTP step is injected, so the
/// classification logic is exercised without real network: the fake transport dispatches by request
/// path — `…/user/tokens/verify` vs `…/accounts` — and returns canned envelopes.
struct CloudflareAPITokenVerifierTests {
    private static let siteDir = URL(fileURLWithPath: "/unused")

    /// Build a transport that returns `(status, json)` per request, chosen by URL path suffix.
    private static func transport(
        verify: (Int, String),
        accounts: (Int, String) = (200, #"{"success":true,"result":[]}"#)
    ) -> CloudflareTransport {
        { request in
            let path = request.url?.path ?? ""
            let (status, json): (Int, String) = path.hasSuffix("tokens/verify") ? verify : accounts
            let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(json.utf8), http)
        }
    }

    @Test("a valid active token verifies and surfaces the account name")
    func validActiveTokenWithAccount() async {
        let verifier = CloudflareAPITokenVerifier(transport: Self.transport(
            verify: (200, #"{"success":true,"result":{"id":"abc","status":"active"}}"#),
            accounts: (200, #"{"success":true,"result":[{"id":"a1","name":"Acme Corp"}]}"#)))
        let result = await verifier.verify(token: "good", siteDirectory: Self.siteDir)
        #expect(result == .success(CloudflareAccount(name: "Acme Corp", email: nil)))
    }

    @Test("a rejected token maps to .invalidToken")
    func invalidToken() async {
        let verifier = CloudflareAPITokenVerifier(transport: Self.transport(
            verify: (401, #"{"success":false,"result":null,"errors":[{"code":1000,"message":"Invalid API Token"}]}"#)))
        let result = await verifier.verify(token: "bad", siteDirectory: Self.siteDir)
        #expect(result == .failure(.invalidToken))
    }

    @Test("a non-active token status maps to .invalidToken")
    func inactiveTokenStatus() async {
        let verifier = CloudflareAPITokenVerifier(transport: Self.transport(
            verify: (200, #"{"success":true,"result":{"id":"abc","status":"disabled"}}"#)))
        let result = await verifier.verify(token: "expired", siteDirectory: Self.siteDir)
        #expect(result == .failure(.invalidToken))
    }

    @Test("a connection failure maps to .network")
    func networkFailure() async {
        let verifier = CloudflareAPITokenVerifier(transport: { _ in throw URLError(.notConnectedToInternet) })
        let result = await verifier.verify(token: "any", siteDirectory: Self.siteDir)
        #expect(result == .failure(.network))
    }

    @Test("a valid token still verifies when the best-effort accounts lookup fails")
    func validTokenButAccountsLookupFails() async {
        let verifier = CloudflareAPITokenVerifier(transport: Self.transport(
            verify: (200, #"{"success":true,"result":{"id":"abc","status":"active"}}"#),
            accounts: (403, #"{"success":false,"errors":[{"code":9109,"message":"Unauthorized"}]}"#)))
        let result = await verifier.verify(token: "good", siteDirectory: Self.siteDir)
        #expect(result == .success(CloudflareAccount(name: nil, email: nil)))
    }

    @Test("an unparseable verify response maps to .unavailable (not a bad-token claim)")
    func unparseableResponse() async {
        let verifier = CloudflareAPITokenVerifier(transport: Self.transport(verify: (200, "not json at all")))
        let result = await verifier.verify(token: "any", siteDirectory: Self.siteDir)
        guard case .failure(.unavailable) = result else {
            Issue.record("expected .unavailable, got \(result)")
            return
        }
    }

    @Test("a transient server error (5xx/429) maps to .unavailable, not .invalidToken")
    func transientServerError() async {
        // Cloudflare can return a `{"success":false}` body on a 503/429; that's an outage/rate-limit,
        // not a bad token — it must not be misclassified as .invalidToken.
        let verifier = CloudflareAPITokenVerifier(transport: Self.transport(
            verify: (503, #"{"success":false,"errors":[{"code":10000,"message":"service unavailable"}]}"#)))
        let result = await verifier.verify(token: "valid-but-cf-is-down", siteDirectory: Self.siteDir)
        guard case .failure(.unavailable) = result else {
            Issue.record("expected .unavailable, got \(result)")
            return
        }
    }

    @Test("the request carries the bearer token and hits the verify endpoint")
    func sendsBearerTokenToVerifyEndpoint() async {
        let captured = CapturedRequest()
        let verifier = CloudflareAPITokenVerifier(transport: { request in
            await captured.record(request)
            let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"success":true,"result":{"id":"x","status":"active"}}"#.utf8), http)
        })
        _ = await verifier.verify(token: "secret-token", siteDirectory: Self.siteDir)
        #expect(await captured.authHeader == "Bearer secret-token")
        #expect(await captured.firstPath?.hasSuffix("user/tokens/verify") == true)
    }

    private actor CapturedRequest {
        private(set) var authHeader: String?
        private(set) var firstPath: String?
        func record(_ request: URLRequest) {
            if firstPath == nil {
                firstPath = request.url?.path
                authHeader = request.value(forHTTPHeaderField: "Authorization")
            }
        }
    }
}
