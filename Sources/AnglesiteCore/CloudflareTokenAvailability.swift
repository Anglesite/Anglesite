import Dispatch
import Foundation

/// "Is a Cloudflare API credential available right now?" — the presence check that gates a
/// deploy, in a form a background caller can ask without wedging the main actor (#1705).
///
/// This is deliberately *not* ``CloudflareAPICredentials/resolve(secretStore:diagnosticSource:surfaceOAuthReadErrors:)``:
/// that one produces a usable bearer token and will refresh an expired OAuth credential over the
/// network. This one only answers whether a deploy is worth starting, so it never refreshes and
/// never returns the secret itself.
///
/// ## Why the probe exists
///
/// On macOS every read here bottoms out in `SecItemCopyMatching`, a *blocking* call that can put
/// up securityd's authorization panel — the "Anglesite wants to use your confidential information"
/// prompt. Run from the main actor, the whole app stops rendering until the panel is answered; with
/// an ad-hoc-signed Debug build (a fresh code signature per rebuild invalidates the item's ACL) that
/// fires on the first site-open after every build, and a signed release build hits it whenever
/// keychain authorization stalls. At window restore that reads as "the app launched and then died":
/// no window, no beachball, nothing to click unless you know to look for SecurityAgent.
///
/// There is no way to ask for a genuinely non-interactive read of these items on macOS 27. The
/// `SecItem` knobs that look like they'd do it don't: `kSecUseNoAuthenticationUI` is documented to
/// apply only to Data Protection keychain items ("Legacy keychain items will still activate UI if
/// needed"), and ``KeychainStore``'s generic passwords are legacy file-based items; the
/// `kSecUseAuthenticationUI`/`LAContext.interactionNotAllowed` pair governs LocalAuthentication,
/// not the securityd ACL panel; and `SecKeychainSetUserInteractionAllowed`, the one API that did
/// suppress that panel, is gone from the macOS 27 SDK. So ``probe(secretStore:environment:now:timeout:)``
/// does the next best thing: it runs the blocking read off the caller's actor and gives up waiting
/// after `timeout`, reporting ``Outcome/undetermined`` so a background caller can defer instead of
/// blocking. The read itself is left running — the user can still answer the panel, and the next
/// probe sees the settled answer.
public enum CloudflareTokenAvailability {
    /// What ``probe(secretStore:environment:now:timeout:)`` learned.
    public enum Outcome: Sendable, Equatable {
        /// A credential is configured — the env var, a refreshable OAuth credential, or the
        /// legacy pasted token.
        case available
        /// Nothing is configured. A user-facing flow should offer sign-in.
        case unavailable
        /// The secret store didn't answer in time — on macOS, almost always a keychain read
        /// parked in securityd's authorization panel. Not "no token": the answer is unknown, so
        /// a background caller should defer and ask again later rather than concluding anything.
        case undetermined
    }

    /// How long ``probe(secretStore:environment:now:timeout:)`` waits before reporting
    /// ``Outcome/undetermined``. Long enough that an ordinary keychain read (an in-process system
    /// call, sub-millisecond) never trips it under load; short enough that a publish queued behind
    /// an unanswered authorization panel gives up while the window is still opening.
    public static let defaultTimeout: Duration = .seconds(2)

    /// Evaluates the availability rule synchronously, blocking the caller until the store answers.
    ///
    /// - Important: on Darwin this can block for as long as an unanswered keychain authorization
    ///   panel stays on screen. Only call it where blocking is acceptable — a foreground,
    ///   user-initiated action whose window is already on screen, where the panel is both visible
    ///   and expected. Background and window-restore paths must use
    ///   ``probe(secretStore:environment:now:timeout:)`` instead (#1705).
    ///
    /// - Parameters:
    ///   - secretStore: Where the OAuth credential and the legacy pasted token live.
    ///   - environment: The process environment to check `CLOUDFLARE_API_TOKEN` in.
    ///   - now: The instant an OAuth credential's expiry is measured against.
    public static func evaluate(
        secretStore: any SecretStore = PlatformSecretStore.make(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) -> Bool {
        if hasEnvironmentToken(environment) { return true }
        return storeHoldsUsableCredential(secretStore: secretStore, now: now)
    }

    /// Evaluates the same rule as ``evaluate(secretStore:environment:now:)`` without ever running
    /// the store read on the caller's actor, and without waiting on it forever.
    ///
    /// The `CLOUDFLARE_API_TOKEN` check happens inline: reading the process environment can't
    /// prompt, so a developer's shell-provided token still resolves with no hop and no wait.
    ///
    /// - Parameters:
    ///   - secretStore: Where the OAuth credential and the legacy pasted token live.
    ///   - environment: The process environment to check `CLOUDFLARE_API_TOKEN` in.
    ///   - now: The instant an OAuth credential's expiry is measured against.
    ///   - timeout: How long to wait for the store before reporting ``Outcome/undetermined``.
    ///     Defaults to ``defaultTimeout``.
    /// - Returns: ``Outcome/available``, ``Outcome/unavailable``, or ``Outcome/undetermined`` when
    ///   the store didn't answer in time.
    public static func probe(
        secretStore: any SecretStore = PlatformSecretStore.make(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        timeout: Duration = CloudflareTokenAvailability.defaultTimeout
    ) async -> Outcome {
        if hasEnvironmentToken(environment) { return .available }

        let settled = FirstAnswer<Bool>()
        // A *serial* queue on purpose: if one read is stuck behind an authorization panel, every
        // later probe queues behind it and times out rather than spawning a second blocked thread
        // per attempt. The queue drains the moment the user answers.
        probeQueue.async {
            let usable = storeHoldsUsableCredential(secretStore: secretStore, now: now)
            Task { await settled.settle(usable) }
        }
        let deadline = Task {
            try? await Task.sleep(for: timeout)
            await settled.settle(nil)
        }
        defer { deadline.cancel() }

        guard let usable = await settled.value() else { return .undetermined }
        return usable ? .available : .unavailable
    }

    // MARK: Internals

    /// The one background queue every probe's blocking read runs on. See ``probe`` for why it is
    /// serial rather than concurrent.
    private static let probeQueue = DispatchQueue(
        label: "io.dwk.anglesite.cloudflare-token-probe", qos: .userInitiated)

    /// True when the env var holds something non-empty. Kept byte-identical to the check the
    /// deploy path has always made, so a token that used to gate a deploy still does.
    private static func hasEnvironmentToken(_ environment: [String: String]) -> Bool {
        guard let value = environment["CLOUDFLARE_API_TOKEN"] else { return false }
        return !value.isEmpty
    }

    /// The store half of the rule: a stored OAuth credential counts unless it is *definitely*
    /// unrefreshable (expired with no refresh token, e.g. because Cloudflare's OAuth didn't issue
    /// one for this client), in which case this falls through to the legacy pasted-token slot so
    /// the sign-in sheet re-presents rather than deploys failing forever with a generic "no token"
    /// error. No refresh is attempted — this is a presence check, and refreshing is
    /// ``CloudflareDeployTarget/keychainTokenSource``'s job at actual deploy time. Store errors
    /// read as "no credential": the user recovers by signing in again.
    private static func storeHoldsUsableCredential(secretStore: any SecretStore, now: Date) -> Bool {
        if let credential = try? secretStore.readCloudflareOAuthCredential() {
            let isDefinitelyUnrefreshable = credential.refreshToken == nil
                && (credential.expiresAt.map { $0 <= now } ?? false)
            if !isDefinitelyUnrefreshable { return true }
        }
        if let stored = try? secretStore.readCloudflareToken(), !stored.isEmpty { return true }
        return false
    }
}

/// A one-shot rendezvous: whichever of the blocking read and the timeout finishes first settles
/// the answer, and the loser's later `settle` is dropped. Exists because the read can't be
/// cancelled — a structured task group would re-block on the abandoned child at scope exit, which
/// is exactly the wait the timeout is there to avoid.
private actor FirstAnswer<Value: Sendable> {
    /// `nil` while unsettled; `.some(nil)` once settled to "no answer" (the timeout won).
    private var answer: Value??
    private var waiter: CheckedContinuation<Value?, Never>?

    func settle(_ value: Value?) {
        guard answer == nil else { return }
        answer = .some(value)
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: value)
        }
    }

    func value() async -> Value? {
        if let answer { return answer }
        return await withCheckedContinuation { waiter = $0 }
    }
}
