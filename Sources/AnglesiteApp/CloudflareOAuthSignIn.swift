import AuthenticationServices
import AnglesiteCore

/// Thrown by `CloudflareOAuthSignIn.defaultPresenter` when `ASWebAuthenticationSession.start()`
/// returns `false` — the session never presented, so any completion the session later delivers
/// (observed in practice: `ASWebAuthenticationSessionError.canceledLogin`, #1766) is not a real
/// user cancel. The most common cause is a Debug build signed without the Associated Domains
/// entitlement (`com.apple.developer.associated-domains`), which `.https(host:path:)` callback
/// matching requires; that entitlement is deliberately absent from the default ad-hoc Debug
/// entitlements (see `Resources/Anglesite-Debug.entitlements`) because it needs a real
/// provisioning profile.
enum CloudflareOAuthPresentationError: Error {
    case sessionFailedToStart
}

// `CloudflareOAuthSignIn` itself lives in AnglesiteCore (shared with the iOS connect form,
// #891); only the macOS presenter is app-target code, because it needs AppKit anchoring.
extension CloudflareOAuthSignIn {
    /// Holds the in-flight session and its anchor provider for as long as the browser sheet is
    /// up. `ASWebAuthenticationSession` cancels itself when it is deallocated, and nothing else
    /// retains it: a session held only by a local inside the continuation closure was released
    /// the moment `start()` returned, so its completion handler fired straight away with
    /// `.canceledLogin` — which `DeployModel` read as the user dismissing the sheet. That is the
    /// "spinner clears, nothing happens" symptom of #1766 on *every* build, entitled or not; the
    /// `start()`-returns-`false` path handled below is the separate, unentitled-build case.
    ///
    /// The session's completion handler captures this holder strongly (session → handler →
    /// holder → session), and clearing the holder from inside that handler is what breaks the
    /// cycle once the session has reported back. A per-call object rather than actor-isolated
    /// static state because the completion handler runs nonisolated.
    private final class LiveSession: @unchecked Sendable {
        var session: ASWebAuthenticationSession?
        var context: CloudflareOAuthPresentationContext?

        func release() {
            session = nil
            context = nil
        }
    }

    /// Production presenter: a real `ASWebAuthenticationSession` anchored via
    /// `CloudflareOAuthPresentationContext`, matched against the callback Worker's `/oauth-callback`
    /// route via Associated Domains. `.https(host:path:)` callback matching has been available
    /// since macOS 14.4 (well under this app's macOS 27 floor) — confirmed against the macOS 27 SDK
    /// (`init(url:callback:completionHandler:)`) while implementing this task. It isn't
    /// unit-testable (real `AuthenticationServices` UI), so this is a manual/smoke-test item per
    /// the design doc's Testing section.
    @MainActor
    static let defaultPresenter: Presenter = { authorizeURL in
        let contextProvider = CloudflareOAuthPresentationContext()
        let live = LiveSession()
        return try await withCheckedThrowingContinuation { continuation in
            // `session.start()` returning `false` and the completion handler firing are not
            // mutually exclusive in practice (#1766: a session that fails to start due to a
            // missing entitlement still completes with `.canceledLogin`), so both paths can race
            // to resume this continuation. Guard so only the first — deliberately the `start()`
            // check, since it's synchronous and therefore always wins that race — takes effect.
            var didResume = false
            // `Result` alone would resolve to `CloudflareOAuthSignIn.Result` (this extension's
            // enclosing type), not the standard library's — qualify it.
            func resume(_ result: Swift.Result<URL, Error>) {
                guard !didResume else { return }
                didResume = true
                continuation.resume(with: result)
            }

            let session = ASWebAuthenticationSession(
                url: authorizeURL,
                callback: .https(
                    host: CloudflareOAuthConfiguration.redirectURI.host!,
                    path: CloudflareOAuthConfiguration.redirectURI.path)
            ) { callbackURL, error in
                // Release the strong references only once the session has reported back.
                live.release()
                if let error {
                    resume(.failure(error))
                } else if let callbackURL {
                    resume(.success(callbackURL))
                } else {
                    resume(.failure(CloudflareOAuthError.missingAuthorizationCode))
                }
            }
            session.presentationContextProvider = contextProvider
            live.session = session
            live.context = contextProvider
            if !session.start() {
                live.release()
                resume(.failure(CloudflareOAuthPresentationError.sessionFailedToStart))
            }
        }
    }
}
