import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteAppCore

/// `.timeLimit`: see #1349/#1355 — the full `AnglesiteAppTests` target has hung indefinitely
/// under local machine contention (many concurrent `swift test` runs oversubscribing the
/// cooperative thread pool), with this suite one observed stall point. A wedged test now fails
/// as an unambiguous time-limit violation instead of hanging the whole run for hours.
@Suite(.timeLimit(.minutes(1)))
struct CloudflareOAuthSignInTests {
    private let discoveryURL = URL(string: "https://dash.cloudflare.com/.well-known/openid-configuration")!
    private let redirectURI = URL(string: "https://auth.anglesite.dwk.io/oauth-callback")!
    private let discoveryJSON = Data("""
    {"authorization_endpoint":"https://dash.cloudflare.com/oauth2/auth","token_endpoint":"https://dash.cloudflare.com/oauth2/token"}
    """.utf8)

    private func response(_ code: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: discoveryURL, statusCode: code, httpVersion: nil, headerFields: nil)!
    }

    /// Records a value written from a `@Sendable` closure. `run()`'s `present`/`transport`
    /// callbacks are `@Sendable` and cross `await` suspension points, so the compiler can't prove
    /// a plain captured `var` isn't accessed concurrently — actor isolation is the fix the rest of
    /// this codebase already uses for the same shape of problem (see `CloudflareAPITokenTestEnvironment`,
    /// `HTTPGitHubClientTests.RequestBox`).
    actor Box<Value: Sendable> {
        private(set) var value: Value
        init(_ value: Value) { self.value = value }
        func set(_ value: Value) { self.value = value }
    }

    @Test("run() authorizes, presents, and exchanges the callback for a token")
    func fullRoundTrip() async throws {
        let client = CloudflareOAuthClient(
            redirectURI: redirectURI, scope: "workers_scripts", discoveryURL: discoveryURL,
            transport: { req in
                if req.url == self.discoveryURL { return (self.discoveryJSON, self.response(200)) }
                let body = #"{"access_token":"tok","token_type":"bearer","expires_in":3600,"refresh_token":"refresh"}"#
                return (Data(body.utf8), self.response(200))
            })
        let presentedURLBox = Box<URL?>(nil)
        let signIn = CloudflareOAuthSignIn(client: client, present: { authorizeURL in
            await presentedURLBox.set(authorizeURL)
            let state = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "state" }?.value ?? ""
            return URL(string: "https://auth.anglesite.dwk.io/oauth-callback?code=auth-code&state=\(state)")!
        })

        let result = try await signIn.run()

        #expect(result.token.accessToken == "tok")
        #expect(result.token.refreshToken == "refresh")
        #expect(result.tokenEndpoint == URL(string: "https://dash.cloudflare.com/oauth2/token")!)
        let presentedURL = await presentedURLBox.value
        #expect(presentedURL?.host == "dash.cloudflare.com")
    }

    @Test("a presenter failure propagates without exchanging a token")
    func presenterFailurePropagates() async {
        struct Cancelled: Error {}
        let client = CloudflareOAuthClient(
            redirectURI: redirectURI, scope: "workers_scripts", discoveryURL: discoveryURL,
            transport: { _ in (self.discoveryJSON, self.response(200)) })
        let signIn = CloudflareOAuthSignIn(client: client, present: { _ in throw Cancelled() })
        await #expect(throws: Cancelled.self) {
            _ = try await signIn.run()
        }
    }

    @Test("a callback with a mismatched state throws before exchanging")
    func mismatchedStateNeverExchanges() async {
        let exchangeCalledBox = Box(false)
        let client = CloudflareOAuthClient(
            redirectURI: redirectURI, scope: "workers_scripts", discoveryURL: discoveryURL,
            transport: { req in
                if req.url == self.discoveryURL { return (self.discoveryJSON, self.response(200)) }
                await exchangeCalledBox.set(true)
                return (Data(), self.response(200))
            })
        let signIn = CloudflareOAuthSignIn(client: client, present: { _ in
            URL(string: "https://auth.anglesite.dwk.io/oauth-callback?code=xyz&state=WRONG")!
        })
        await #expect(throws: CloudflareOAuthError.stateMismatch) {
            _ = try await signIn.run()
        }
        let exchangeCalled = await exchangeCalledBox.value
        #expect(!exchangeCalled)
    }
}
