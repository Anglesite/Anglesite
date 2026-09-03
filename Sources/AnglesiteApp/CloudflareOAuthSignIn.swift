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
                if let error {
                    resume(.failure(error))
                } else if let callbackURL {
                    resume(.success(callbackURL))
                } else {
                    resume(.failure(CloudflareOAuthError.missingAuthorizationCode))
                }
            }
            session.presentationContextProvider = contextProvider
            if !session.start() {
                resume(.failure(CloudflareOAuthPresentationError.sessionFailedToStart))
            }
        }
    }
}
