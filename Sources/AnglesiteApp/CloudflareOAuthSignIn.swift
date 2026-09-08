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
    /// `start()` returned `true` but macOS rejected the session before anything could present —
    /// the system session host (`SafariLaunchAgent`) refuses an `.https` callback whose domain
    /// association it hasn't verified for this copy of the app, and reports that to the app as
    /// `ASWebAuthenticationSessionError.canceledLogin` (code 1), indistinguishable from the user
    /// closing the sheet unless the timing and the host's failure reason are taken into account
    /// (#1951). `reason` is the host's `NSLocalizedFailureReason` when it survives the round trip.
    case sessionRejectedBeforePresenting(reason: String?)
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
    /// the design doc's Testing section; the resume/cancel plumbing it sits on is
    /// `ContinuationGate`, which is.
    ///
    /// Cancellation-aware (#1951): when macOS has the Associated Domains *entitlement* but hasn't
    /// *verified* the association for this copy of the app, `start()` returns `true`, the system
    /// session host rejects the session ("Application … is not associated with domain …") and the
    /// completion handler is never invoked — the continuation would wait forever. Cancelling the
    /// calling task (the sheet's Cancel button, or `DeployModel`'s sign-in timeout) resumes it with
    /// `CancellationError` and tears the session down, so the wait is always escapable.
    ///
    /// Runs on the main actor — and must (#1951). `ASWebAuthenticationSession` is AppKit-adjacent
    /// UI (the anchor lookup in `CloudflareOAuthPresentationContext` reads `NSApp.keyWindow`), and
    /// the previous presenter executed on whatever cooperative-pool thread
    /// `CloudflareOAuthSignIn.run()` resumed on after discovery: a session started off the main
    /// thread never received the host's reply at all (verified from the system log — the host
    /// rejected the session 1 ms after `start()`, and the completion handler never ran), which is
    /// the indefinite "Signing in…" the issue reports. Started on the main thread the same
    /// rejection is delivered promptly, as `canceledLogin` — see `classifyCompletion` for how that
    /// is told apart from a real cancel.
    @MainActor
    static let defaultPresenter: Presenter = { @MainActor authorizeURL in
        let gate = ContinuationGate<URL>()
        let live = LiveSession()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.attach(continuation)
                // Cancelled before we got here: `attach` already resumed with `CancellationError`;
                // don't start a session nobody is waiting on.
                if gate.isCancelled { return }

                let contextProvider = CloudflareOAuthPresentationContext()
                let clock = ContinuousClock()
                let startedAt = clock.now
                let session = ASWebAuthenticationSession(
                    url: authorizeURL,
                    callback: .https(
                        host: CloudflareOAuthConfiguration.redirectURI.host!,
                        path: CloudflareOAuthConfiguration.redirectURI.path)
                ) { callbackURL, error in
                    // Release the strong references only once the session has reported back.
                    live.release()
                    // `session.start()` returning `false` and the completion handler firing are
                    // not mutually exclusive in practice (#1766: a session that fails to start due
                    // to a missing entitlement still completes with `.canceledLogin`), so both
                    // paths race to resume — the gate lets only the first through. `start()` is
                    // synchronous, so its check below deliberately always wins that race.
                    gate.finish(classifyCompletion(
                        callbackURL: callbackURL, error: error, sinceStart: clock.now - startedAt))
                }
                session.presentationContextProvider = contextProvider
                live.session = session
                live.context = contextProvider
                gate.setCancelHandler {
                    // `cancel()` dismisses the sheet if one is up and, for a session that never
                    // presented (#1951), is the only way to let go of it. Back on main because the
                    // cancelling task can be running anywhere.
                    DispatchQueue.main.async {
                        live.session?.cancel()
                        live.release()
                    }
                }
                if !session.start() {
                    live.release()
                    gate.finish(.failure(CloudflareOAuthPresentationError.sessionFailedToStart))
                }
            }
        } onCancel: {
            gate.cancel()
        }
    }

    /// How soon after `start()` a `canceledLogin` can't have been the user: the system sheet takes
    /// longer than this to appear at all, so a "cancel" inside the window is the host declining to
    /// present (#1951), whatever its userInfo says.
    static let presentationGracePeriod: Duration = .seconds(1)

    /// Pure mapping from `ASWebAuthenticationSession`'s completion-handler arguments — plus how
    /// long after `start()` they arrived — to what `defaultPresenter` resumes with. Split out (like
    /// `SiteMicropubSignIn.mapCompletion`) so the one judgement call here is unit-testable without
    /// real `AuthenticationServices` UI:
    ///
    /// `canceledLogin` is what the user's Cancel produces, but it is *also* how macOS reports a
    /// session its host refused to present because the app's Associated Domains aren't verified
    /// (observed 2026-09-08 on macOS 27: "Application with identifier … is not associated with
    /// domain auth.anglesite.dwk.io", delivered as code 1). Treating that as a user cancel is a
    /// silent failure — sheet back to idle, nothing logged — so a `canceledLogin` that either
    /// carries a failure reason from the host or arrives inside `presentationGracePeriod` becomes
    /// `CloudflareOAuthPresentationError.sessionRejectedBeforePresenting`. Everything else passes
    /// through unchanged so `DeployModel`'s existing branches keep their meaning.
    nonisolated static func classifyCompletion(
        callbackURL: URL?, error: Error?, sinceStart: Duration
    ) -> Swift.Result<URL, Error> {
        if let callbackURL { return .success(callbackURL) }
        guard let error else { return .failure(CloudflareOAuthError.missingAuthorizationCode) }
        let nsError = error as NSError
        let isCanceledLogin = nsError.domain == ASWebAuthenticationSessionError.errorDomain
            && nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue
        guard isCanceledLogin else { return .failure(error) }
        let reason = hostFailureReason(in: nsError)
        if reason != nil || sinceStart < presentationGracePeriod {
            return .failure(CloudflareOAuthPresentationError.sessionRejectedBeforePresenting(reason: reason))
        }
        return .failure(error)
    }

    /// The session host's own failure reason, if the framework carried it through — on the error
    /// itself or on an underlying error. Only the Associated Domains rejection is recognised;
    /// any other reason text is left for the generic branches.
    private nonisolated static func hostFailureReason(in error: NSError) -> String? {
        var current: NSError? = error
        var depth = 0
        while let candidate = current, depth < 4 {
            if let reason = candidate.userInfo[NSLocalizedFailureReasonErrorKey] as? String,
                reason.contains("not associated with domain")
            {
                return reason
            }
            current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return nil
    }
}
