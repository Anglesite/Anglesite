import AppKit
import AuthenticationServices
import AnglesiteIOS

/// macOS conformer of `SiteWebAuthenticating` (`AnglesiteIOS/MicropubOnboardingModel.swift`) —
/// the per-site IndieAuth sign-in adapter `MicropubOnboardingModel` needs on the Mac. Presents an
/// `ASWebAuthenticationSession` directly (unlike the iOS counterpart, `SessionWebAuthenticator`
/// in `AnglesiteMobile/SiteSignInScreen.swift`, which drives SwiftUI's `webAuthenticationSession`
/// environment — not available here since this isn't a View). Matches a custom-scheme callback
/// (IndieAuth's redirect URI) rather than an Associated-Domains HTTPS callback.
///
/// `ASWebAuthenticationSession` doesn't retain itself, and `presentationContextProvider` is a
/// *weak* property, so both the session and its context provider need an explicit strong owner
/// for the lifetime of the operation — a bare local in the `withCheckedThrowingContinuation`
/// setup closure is not enough, since that closure is synchronous/non-escaping and returns (and
/// its locals become collectible) as soon as `.start()` is called, typically well before the OS
/// invokes the completion handler. `SessionRetainer` below is that owner: it's captured strongly
/// by the completion handler closure that `session` itself stores, which — because `retainer`
/// also stores `session` — forms a deliberate, temporary retain cycle (retainer → session →
/// completion handler → retainer). A cycle can't be prematurely collected by ARC (Swift has no
/// cycle collector), so the whole group is guaranteed to survive until the handler fires; the
/// handler then breaks the cycle itself by clearing `retainer`'s stored properties, so nothing
/// leaks past that point.
struct SiteMicropubSignIn: SiteWebAuthenticating {
    @MainActor
    func authenticate(authorizeURL: URL, callbackScheme: String) async throws -> URL {
        let retainer = SessionRetainer()
        return try await withCheckedThrowingContinuation { continuation in
            let contextProvider = SiteMicropubSignInPresentationContext()
            let session = ASWebAuthenticationSession(
                url: authorizeURL,
                callback: .customScheme(callbackScheme)
            ) { callbackURL, error in
                // Breaks the retain cycle described above now that the session is done with —
                // must run after `mapCompletion` reads `callbackURL`/`error` (it doesn't touch
                // `retainer`), but before returning, so nothing outlives this call.
                defer {
                    retainer.session = nil
                    retainer.contextProvider = nil
                }
                continuation.resume(with: Self.mapCompletion(callbackURL: callbackURL, error: error))
            }
            retainer.session = session
            retainer.contextProvider = contextProvider
            session.presentationContextProvider = contextProvider
            session.start()
        }
    }

    /// Pure mapping from `ASWebAuthenticationSession`'s completion-handler arguments to the
    /// `Result` `authenticate` resolves with. Split out from the closure above so the
    /// cancellation/error-mapping logic — the only part of this type with any real branching —
    /// is unit-testable without driving a real `ASWebAuthenticationSession`, which needs system
    /// UI and can't run headlessly.
    static func mapCompletion(callbackURL: URL?, error: Error?) -> Result<URL, Error> {
        if let callbackURL {
            return .success(callbackURL)
        } else if let error = error as? ASWebAuthenticationSessionError,
            error.code == .canceledLogin
        {
            return .failure(SiteWebAuthenticationCancelled())
        } else {
            return .failure(error ?? SiteWebAuthenticationCancelled())
        }
    }
}

/// Strong owner of the in-flight session + presentation context, for the reason explained on
/// `SiteMicropubSignIn.authenticate`.
private final class SessionRetainer {
    var session: ASWebAuthenticationSession?
    var contextProvider: SiteMicropubSignInPresentationContext?
}

/// Anchors the sign-in sheet to the app's key window — same approach as
/// `CloudflareOAuthPresentationContext`, kept as its own type because it's a distinct sign-in
/// flow (Micropub/IndieAuth, not Cloudflare OAuth).
private final class SiteMicropubSignInPresentationContext: NSObject,
    ASWebAuthenticationPresentationContextProviding
{
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}
