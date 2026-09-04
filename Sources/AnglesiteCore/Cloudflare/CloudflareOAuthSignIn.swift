import Foundation

/// Drives one Cloudflare OAuth sign-in attempt: authorize → present the browser sheet → exchange
/// the callback for a token. Presentation is injected so callers can be tested without
/// `AuthenticationServices` or a real browser window — the same seam philosophy
/// `TokenVerifying`/``CloudflareOAuthClient/Transport`` already use elsewhere in this codebase.
///
/// Shared by both UI shells (#891): the macOS app supplies an `ASWebAuthenticationSession`
/// presenter anchored to a window (`CloudflareOAuthSignIn.defaultPresenter` in the app target);
/// the iOS connect form supplies SwiftUI's `webAuthenticationSession` environment action. Keeping
/// the sequencing here — including ``CloudflareOAuthClient/authorizationCode(from:matching:)``'s
/// state-before-error precedence — means the two platforms can't drift apart as the flow evolves.
public struct CloudflareOAuthSignIn: Sendable {
    /// One completed OAuth sign-in: the token plus the token endpoint used to obtain it — needed
    /// later to refresh, since ``OAuthToken`` itself doesn't carry it.
    public struct Result: Sendable {
        /// The token the exchange returned.
        public let token: OAuthToken
        /// The endpoint that issued ``token``, for later refresh without re-running discovery.
        public let tokenEndpoint: URL
    }

    /// Presents `authorizeURL` (e.g. via `ASWebAuthenticationSession`) and returns the callback URL
    /// the session completes with. Throws on cancel/failure.
    public typealias Presenter = @Sendable (_ authorizeURL: URL) async throws -> URL

    private let client: CloudflareOAuthClient
    private let present: Presenter

    /// Creates a sign-in attempt over `client`, presenting the browser session via `present`.
    public init(client: CloudflareOAuthClient, present: @escaping Presenter) {
        self.client = client
        self.present = present
    }

    /// Runs the whole flow once and returns the exchanged token. Errors from any phase —
    /// discovery, the presenter (e.g. user cancel), callback validation, exchange — propagate
    /// unchanged so callers can distinguish a cancel from a hard failure.
    public func run() async throws -> Result {
        let request = try await client.makeAuthorizationRequest()
        let callbackURL = try await present(request.authorizeURL)
        let code = try CloudflareOAuthClient.authorizationCode(from: callbackURL, matching: request)
        let token = try await client.exchange(code: code, for: request)
        return Result(token: token, tokenEndpoint: request.tokenEndpoint)
    }
}
