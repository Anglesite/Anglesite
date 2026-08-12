import AppKit
import AuthenticationServices
import AnglesiteIOS

/// macOS conformer of `SiteWebAuthenticating` (`AnglesiteIOS/MicropubOnboardingModel.swift`) —
/// the per-site IndieAuth sign-in adapter `MicropubOnboardingModel` needs on the Mac. Mirrors
/// `CloudflareOAuthSignIn.defaultPresenter`'s AppKit `ASWebAuthenticationSession` wrapper
/// (`CloudflareOAuthSignIn.swift`), including its lifetime-management idiom: the presentation
/// context and session are locals declared inside (or just before) the
/// `withCheckedThrowingContinuation` closure, kept alive for free by the suspended async frame
/// rather than by any manual retain trick, until the completion handler resumes the
/// continuation. This flow matches a custom-scheme callback (IndieAuth's redirect URI) rather
/// than an Associated-Domains HTTPS callback — the same distinction the iOS counterpart,
/// `SessionWebAuthenticator` in `AnglesiteMobile/SiteSignInScreen.swift`, draws via SwiftUI's
/// `webAuthenticationSession` environment. This type can't use that SwiftUI environment key
/// (it isn't a View), so it drives `ASWebAuthenticationSession` directly, like
/// `CloudflareOAuthSignIn` does.
struct SiteMicropubSignIn: SiteWebAuthenticating {
    func authenticate(authorizeURL: URL, callbackScheme: String) async throws -> URL {
        let contextProvider = SiteMicropubSignInPresentationContext()
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authorizeURL,
                callback: .customScheme(callbackScheme)
            ) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else if let error = error as? ASWebAuthenticationSessionError,
                    error.code == .canceledLogin
                {
                    continuation.resume(throwing: SiteWebAuthenticationCancelled())
                } else {
                    continuation.resume(throwing: error ?? SiteWebAuthenticationCancelled())
                }
            }
            session.presentationContextProvider = contextProvider
            session.start()
        }
    }
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
