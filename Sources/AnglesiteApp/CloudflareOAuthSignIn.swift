import AuthenticationServices
import AnglesiteCore

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
            let session = ASWebAuthenticationSession(
                url: authorizeURL,
                callback: .https(
                    host: CloudflareOAuthConfiguration.redirectURI.host!,
                    path: CloudflareOAuthConfiguration.redirectURI.path)
            ) { callbackURL, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: CloudflareOAuthError.missingAuthorizationCode)
                }
            }
            session.presentationContextProvider = contextProvider
            session.start()
        }
    }
}
