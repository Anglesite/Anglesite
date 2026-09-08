import AuthenticationServices
import Foundation
import Testing
import AnglesiteCore
@testable import AnglesiteAppCore

/// `CloudflareOAuthSignIn.classifyCompletion` is the pure part of the macOS presenter: the mapping
/// from `ASWebAuthenticationSession`'s completion-handler arguments (plus how long after `start()`
/// they arrived) to the error the presenter throws. Split out so the one decision that matters for
/// #1951 — is this `canceledLogin` the user closing the sheet, or macOS rejecting a session that
/// never presented? — is testable without driving real `AuthenticationServices` UI.
@Suite("CloudflareOAuthSignIn presenter completion")
struct CloudflareOAuthPresenterCompletionTests {
    private let callback = URL(string: "https://auth.anglesite.dwk.io/oauth-callback?code=c&state=s")!

    @Test("a callback URL is a success regardless of timing")
    func callbackURLSucceeds() throws {
        let result = CloudflareOAuthSignIn.classifyCompletion(
            callbackURL: callback, error: nil, sinceStart: .milliseconds(5))
        #expect(try result.get() == callback)
    }

    @Test("canceledLogin carrying the host's 'not associated with domain' reason is a rejection, not a cancel")
    func rejectionReasonIsClassifiedAsRejected() {
        let reason = "Application with identifier M34HBJZNYA.io.dwk.anglesite is not associated with domain "
            + "auth.anglesite.dwk.io. Using HTTPS callbacks requires Associated Domains using the "
            + "`webcredentials` service type for auth.anglesite.dwk.io."
        let error = NSError(
            domain: ASWebAuthenticationSessionError.errorDomain,
            code: ASWebAuthenticationSessionError.canceledLogin.rawValue,
            userInfo: [NSLocalizedFailureReasonErrorKey: reason])
        let result = CloudflareOAuthSignIn.classifyCompletion(
            callbackURL: nil, error: error, sinceStart: .seconds(30))
        guard case .failure(CloudflareOAuthPresentationError.sessionRejectedBeforePresenting(let got)) = result else {
            Issue.record("expected sessionRejectedBeforePresenting, got \(result)"); return
        }
        #expect(got?.contains("not associated with domain") == true)
    }

    @Test("canceledLogin arriving before a sheet could have been shown is a rejection with no reason")
    func earlyCancelIsClassifiedAsRejected() {
        let error = ASWebAuthenticationSessionError(.canceledLogin)
        let result = CloudflareOAuthSignIn.classifyCompletion(
            callbackURL: nil, error: error, sinceStart: .milliseconds(50))
        guard case .failure(CloudflareOAuthPresentationError.sessionRejectedBeforePresenting(let reason)) = result else {
            Issue.record("expected sessionRejectedBeforePresenting, got \(result)"); return
        }
        #expect(reason == nil)
    }

    @Test("canceledLogin after the sheet has been up is passed through as the user's cancel")
    func lateCancelIsTheUsersCancel() {
        let error = ASWebAuthenticationSessionError(.canceledLogin)
        let result = CloudflareOAuthSignIn.classifyCompletion(
            callbackURL: nil, error: error, sinceStart: .seconds(12))
        guard case .failure(let thrown as ASWebAuthenticationSessionError) = result else {
            Issue.record("expected the ASWebAuthenticationSessionError through unchanged, got \(result)"); return
        }
        #expect(thrown.code == .canceledLogin)
    }

    @Test("any other error is passed through unchanged")
    func otherErrorsPassThrough() {
        let error = ASWebAuthenticationSessionError(.presentationContextInvalid)
        let result = CloudflareOAuthSignIn.classifyCompletion(
            callbackURL: nil, error: error, sinceStart: .milliseconds(1))
        guard case .failure(let thrown as ASWebAuthenticationSessionError) = result else {
            Issue.record("expected pass-through, got \(result)"); return
        }
        #expect(thrown.code == .presentationContextInvalid)
    }

    @Test("neither a callback nor an error is a missing authorization code")
    func nothingIsMissingCode() {
        let result = CloudflareOAuthSignIn.classifyCompletion(callbackURL: nil, error: nil, sinceStart: .seconds(3))
        guard case .failure(CloudflareOAuthError.missingAuthorizationCode) = result else {
            Issue.record("expected missingAuthorizationCode, got \(result)"); return
        }
    }
}
