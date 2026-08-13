import Testing
import AuthenticationServices
import AnglesiteIOS
@testable import AnglesiteAppCore

// `ASWebAuthenticationSession` itself can't be driven headlessly in a unit test (it needs real
// system UI), so these tests exercise `SiteMicropubSignIn.mapCompletion` directly — the pure
// function `authenticate` delegates to for turning the session's completion-handler arguments
// into the `Result` it resolves with. That's the only part of `SiteMicropubSignIn` with any
// branching logic; the rest (constructing the session, retaining it, presenting it) needs real
// `AuthenticationServices` UI and is covered by manual QA instead (documented in the PR).
@Suite("SiteMicropubSignIn.mapCompletion")
struct SiteMicropubSignInTests {
    @Test("a callback URL maps to success, even alongside a non-nil error")
    func callbackURLMapsToSuccess() throws {
        let url = URL(string: "anglesite://callback?code=abc")!
        struct IgnoredError: Error {}
        // `ASWebAuthenticationSession` can hand back both a callback URL and a non-nil `error`
        // in some edge cases; the callback URL must win.
        let result = SiteMicropubSignIn.mapCompletion(callbackURL: url, error: IgnoredError())
        #expect(try result.get() == url)
    }

    @Test("a canceledLogin error maps to SiteWebAuthenticationCancelled, not the raw session error")
    func cancellationMapsToDedicatedError() {
        let cancellation = ASWebAuthenticationSessionError(.canceledLogin)
        let result = SiteMicropubSignIn.mapCompletion(callbackURL: nil, error: cancellation)
        #expect(throws: SiteWebAuthenticationCancelled()) {
            try result.get()
        }
    }

    @Test("a non-cancellation error passes through unchanged")
    func otherErrorPassesThrough() {
        struct SomeOtherError: Error, Equatable {}
        let result = SiteMicropubSignIn.mapCompletion(callbackURL: nil, error: SomeOtherError())
        #expect(throws: SomeOtherError()) {
            try result.get()
        }
    }

    @Test("no callback URL and no error still resolves as a cancellation, not a hang")
    func nilCallbackAndNilErrorMapsToCancellation() {
        let result = SiteMicropubSignIn.mapCompletion(callbackURL: nil, error: nil)
        #expect(throws: SiteWebAuthenticationCancelled()) {
            try result.get()
        }
    }
}
