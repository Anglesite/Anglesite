import Testing
import Foundation
@testable import AnglesiteCore

/// Tests for the GitHub PAT verifier used to surface the connected account in Settings (#653
/// follow-up: "surfaced like Xcode does" — Xcode's Accounts pane shows who you're signed in as,
/// not just "token stored"). The HTTP step is injected, so classification is exercised without
/// real network.
struct GitHubAPITokenVerifierTests {
    private static func transport(status: Int, json: String) -> GitHubAPITokenVerifier.Transport {
        { request in
            let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(json.utf8), http)
        }
    }

    @Test("a valid token verifies and surfaces login, name, and avatar")
    func validToken() async {
        let verifier = GitHubAPITokenVerifier(transport: Self.transport(
            status: 200,
            json: #"{"login":"octocat","name":"The Octocat","avatar_url":"https://avatars.githubusercontent.com/u/1"}"#))
        let result = await verifier.verify(token: "good")
        #expect(result == .success(GitHubAccount(
            login: "octocat",
            name: "The Octocat",
            avatarURL: URL(string: "https://avatars.githubusercontent.com/u/1"))))
    }

    @Test("a user with no display name still verifies, with a nil name")
    func validTokenNoDisplayName() async {
        let verifier = GitHubAPITokenVerifier(transport: Self.transport(
            status: 200,
            json: #"{"login":"octocat","name":null,"avatar_url":"https://avatars.githubusercontent.com/u/1"}"#))
        let result = await verifier.verify(token: "good")
        #expect(result == .success(GitHubAccount(
            login: "octocat",
            name: nil,
            avatarURL: URL(string: "https://avatars.githubusercontent.com/u/1"))))
    }

    @Test("a 401 rejection maps to .invalidToken")
    func rejectedToken() async {
        let verifier = GitHubAPITokenVerifier(transport: Self.transport(
            status: 401,
            json: #"{"message":"Bad credentials"}"#))
        let result = await verifier.verify(token: "bad")
        #expect(result == .failure(.invalidToken))
    }

    @Test("a connection failure maps to .network")
    func networkFailure() async {
        let verifier = GitHubAPITokenVerifier(transport: { _ in throw URLError(.notConnectedToInternet) })
        let result = await verifier.verify(token: "any")
        #expect(result == .failure(.network))
    }

    @Test("a transient server error (5xx/429/403) maps to .unavailable, not .invalidToken")
    func transientServerError() async {
        let verifier = GitHubAPITokenVerifier(transport: Self.transport(
            status: 503,
            json: #"{"message":"Service unavailable"}"#))
        let result = await verifier.verify(token: "any")
        guard case .failure(.unavailable) = result else {
            Issue.record("expected .unavailable, got \(result)")
            return
        }
    }

    @Test("a 403 (rate limit or fine-grained-scope quirk) maps to .unavailable, not .invalidToken")
    func rateLimited() async {
        // GET /user needs no specific token scope, so a 403 here is far more likely a rate limit
        // than a genuinely bad token — must not be misreported as "your token is invalid".
        let verifier = GitHubAPITokenVerifier(transport: Self.transport(
            status: 403,
            json: #"{"message":"API rate limit exceeded"}"#))
        let result = await verifier.verify(token: "any")
        guard case .failure(.unavailable) = result else {
            Issue.record("expected .unavailable, got \(result)")
            return
        }
    }

    @Test("an unparseable body maps to .unavailable")
    func unparseableBody() async {
        let verifier = GitHubAPITokenVerifier(transport: Self.transport(status: 200, json: "not json"))
        let result = await verifier.verify(token: "any")
        guard case .failure(.unavailable) = result else {
            Issue.record("expected .unavailable, got \(result)")
            return
        }
    }

    @Test("invalidToken's recipe copy includes the Pages permission needed for GitHub Pages publishing (#1015 slice 2c)")
    func invalidTokenMessageMentionsPages() {
        #expect(GitHubTokenVerifyError.invalidToken.userMessage.contains("Pages: Read and write"))
    }
}
