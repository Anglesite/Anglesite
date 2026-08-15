import Foundation

/// Drives the "connect Control Worker" flow — verify the drafted Worker URL / bearer token /
/// site ID against the Worker, persist them only if they're good, surface the reachable status,
/// then decide whether to proceed — independent of any SwiftUI (#889).
///
/// Mirrors `TokenOnboarding`/`GitHubTokenOnboarding`'s verify → persist → flash → re-check-cancel →
/// proceed ordering. Verification reuses `SandboxControlClient.status(siteID:)` — any authorized
/// response proves the URL + token pair reaches the user's Worker; no new server API is needed.
/// The caller's view-model owns the observable state; this type owns the ordering, so the "a
/// cancelled connect must not confirm behind the user's back" rule is unit-tested under
/// `swift test` rather than only in an iOS-hosted app test.
///
/// No UI reaches this flow since #1433 retired the iOS connect form (iOS v2.0 design §2): it
/// stays in-tree with the rest of the Cloudflare-sandbox control-client plumbing as the
/// deferred #66 "Mac offline" fallback, behind the `SiteRuntime` seam.
///
/// `@MainActor` so it composes naturally with a MainActor view-model without `Sendable`
/// gymnastics on the closures.
@MainActor
public struct SandboxControlOnboarding {
    /// The trimmed, verified field set handed to `persist` — one value object so the persist
    /// closure can't accidentally store an untrimmed draft.
    public struct Credentials: Equatable, Sendable {
        /// The Worker base URL exactly as it should be persisted (trimmed draft).
        public let workerURLString: String
        /// The verified bearer token (trimmed draft).
        public let token: String
        /// The site identifier the status probe ran against (trimmed draft).
        public let siteID: String

        /// Memberwise creation, public for tests.
        public init(workerURLString: String, token: String, siteID: String) {
            self.workerURLString = workerURLString
            self.token = token
            self.siteID = siteID
        }
    }

    /// What the flow decided — the caller's whole contract. Three-way rather than a thrown error
    /// so "keep the form editable" (``stay(message:)``) and "user walked away" (``abort``) can't
    /// be conflated: only an explicit cancellation skips the connected confirmation.
    public enum Outcome: Equatable {
        /// The Worker answered the status probe — credentials verified and persisted.
        case proceed(SandboxStatus)
        /// Verification (or persistence) failed — the caller keeps the form open with `message`.
        case stay(message: String)
        /// The user cancelled during the flow — the caller does nothing.
        case abort
    }

    /// The one definition of "a usable Worker base URL" (http/https scheme required) — a shared
    /// helper so the verify guard and any future start path can't drift apart on what they
    /// accept.
    public static func workerURL(from string: String) -> URL? {
        guard let url = URL(string: string), url.scheme?.hasPrefix("http") == true else { return nil }
        return url
    }

    private let makeClient: (URL, String) -> any SandboxControlClient

    /// The client factory is the only injected dependency — production passes
    /// `HTTPSandboxControlClient.init`, tests a fake, keeping the flow's ordering logic testable
    /// without network.
    public init(makeClient: @escaping (URL, String) -> any SandboxControlClient) {
        self.makeClient = makeClient
    }

    /// - persist: stores the verified credentials (UserDefaults + Keychain writes); only called
    ///   on a successful verify, and a throw turns the run into `.stay`.
    /// - onConnected: surfaces the reachable status for the success flash, before `delay`.
    /// - delay: the success-flash pause — injectable so tests don't wait real time.
    /// - isCancelled: re-checked after verify + delay; `true` ⇒ `.abort` (no proceed).
    public func run(
        workerURLString: String,
        token: String,
        siteID: String,
        persist: (Credentials) throws -> Void,
        onConnected: (SandboxStatus) -> Void,
        delay: () async -> Void,
        isCancelled: () -> Bool
    ) async -> Outcome {
        let trimmedURLString = workerURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSiteID = siteID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURLString.isEmpty, !trimmedToken.isEmpty, !trimmedSiteID.isEmpty else {
            return .stay(message: "Fill in the Worker URL, token, and site ID first.")
        }
        // Via the shared helper so the verify path and any future start path can't diverge on
        // what they accept.
        guard let workerURL = Self.workerURL(from: trimmedURLString) else {
            return .stay(message: "That Worker URL doesn’t look valid.")
        }

        let client = makeClient(workerURL, trimmedToken)
        let status: SandboxStatus
        do {
            status = try await client.status(siteID: trimmedSiteID)
        } catch SandboxControlError.unauthorized {
            return .stay(message: "That token was rejected by the Worker.")
        } catch SandboxControlError.unreachable(let detail) {
            return .stay(message: "Couldn’t reach the Worker: \(detail)")
        } catch {
            return .stay(message: "Couldn’t verify the Worker connection. Check the URL and try again.")
        }

        do {
            try persist(Credentials(workerURLString: trimmedURLString, token: trimmedToken, siteID: trimmedSiteID))
        } catch {
            return .stay(message: "Couldn’t save to Keychain: \(error)")
        }
        // Let the user see the Worker answered, then re-check cancellation before confirming a
        // connection behind their back.
        onConnected(status)
        await delay()
        if isCancelled() { return .abort }
        return .proceed(status)
    }
}
