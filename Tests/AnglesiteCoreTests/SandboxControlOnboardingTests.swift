import Testing
import Foundation
@testable import AnglesiteCore

/// Tests the iOS connect flow's verify → persist → (maybe) proceed orchestration in isolation
/// from any UI, mirroring `TokenOnboardingTests`/`GitHubTokenOnboardingTests`. Verification is
/// `SandboxControlClient.status(siteID:)` against `FakeSandboxControlClient`, so the "a cancelled
/// connect must not confirm behind the user's back" rule is asserted deterministically under
/// `swift test` (#889) — `RemoteSessionModel` itself lives in the iOS-only app target.
@MainActor
struct SandboxControlOnboardingTests {
    private static let readyStatus = SandboxStatus(siteID: "site-1", previewReady: true, mcpReady: true)

    private func makeOnboarding(
        statusResult: Result<SandboxStatus, SandboxControlError>,
        onMakeClient: @escaping (URL, String) -> Void = { _, _ in }
    ) -> SandboxControlOnboarding {
        SandboxControlOnboarding(makeClient: { url, token in
            onMakeClient(url, token)
            return FakeSandboxControlClient(
                startResult: .failure(.notProvisioned),
                statusResult: statusResult
            )
        })
    }

    @Test("A reachable Worker yields .proceed and persists the trimmed credentials once")
    func proceedsWhenNotCancelled() async {
        var clientURL: URL?
        var clientToken: String?
        let onboarding = makeOnboarding(statusResult: .success(Self.readyStatus)) { url, token in
            clientURL = url
            clientToken = token
        }
        var persisted: [SandboxControlOnboarding.Credentials] = []
        var connected: SandboxStatus?
        let outcome = await onboarding.run(
            workerURLString: "  https://sandbox.example.workers.dev  ",
            token: "  tok  ",
            siteID: "  site-1  ",
            persist: { persisted.append($0) },
            onConnected: { connected = $0 },
            delay: {},
            isCancelled: { false }
        )
        #expect(outcome == .proceed(Self.readyStatus))
        #expect(persisted == [SandboxControlOnboarding.Credentials(
            workerURLString: "https://sandbox.example.workers.dev",
            token: "tok",
            siteID: "site-1"
        )])
        #expect(connected == Self.readyStatus)
        #expect(clientURL == URL(string: "https://sandbox.example.workers.dev"))
        #expect(clientToken == "tok")
    }

    @Test("Cancellation after a successful verify yields .abort (no proceed)")
    func abortsWhenCancelled() async {
        let onboarding = makeOnboarding(statusResult: .success(Self.readyStatus))
        var persistCount = 0
        let outcome = await onboarding.run(
            workerURLString: "https://sandbox.example.workers.dev",
            token: "tok",
            siteID: "site-1",
            persist: { _ in persistCount += 1 },
            onConnected: { _ in },
            delay: {},
            isCancelled: { true }
        )
        #expect(outcome == .abort)
        // The token verified against the Worker, so it's still persisted; only the
        // connected-confirmation is skipped.
        #expect(persistCount == 1)
    }

    @Test("A rejected token yields .stay with the rejection message and never persists")
    func staysOnUnauthorized() async {
        let onboarding = makeOnboarding(statusResult: .failure(.unauthorized))
        var persistCount = 0
        let outcome = await onboarding.run(
            workerURLString: "https://sandbox.example.workers.dev",
            token: "bad",
            siteID: "site-1",
            persist: { _ in persistCount += 1 },
            onConnected: { _ in },
            delay: {},
            isCancelled: { false }
        )
        #expect(outcome == .stay(message: "That token was rejected by the Worker."))
        #expect(persistCount == 0)
    }

    @Test("An unreachable Worker yields .stay carrying the transport detail")
    func staysOnUnreachable() async {
        let onboarding = makeOnboarding(statusResult: .failure(.unreachable("DNS lookup failed")))
        var persistCount = 0
        let outcome = await onboarding.run(
            workerURLString: "https://sandbox.example.workers.dev",
            token: "tok",
            siteID: "site-1",
            persist: { _ in persistCount += 1 },
            onConnected: { _ in },
            delay: {},
            isCancelled: { false }
        )
        #expect(outcome == .stay(message: "Couldn’t reach the Worker: DNS lookup failed"))
        #expect(persistCount == 0)
    }

    @Test("Any other verification failure yields a generic .stay and never persists")
    func staysOnOtherError() async {
        let onboarding = makeOnboarding(statusResult: .failure(.startFailed("boom")))
        var persistCount = 0
        let outcome = await onboarding.run(
            workerURLString: "https://sandbox.example.workers.dev",
            token: "tok",
            siteID: "site-1",
            persist: { _ in persistCount += 1 },
            onConnected: { _ in },
            delay: {},
            isCancelled: { false }
        )
        if case .stay = outcome {} else { Issue.record("expected .stay, got \(outcome)") }
        #expect(persistCount == 0)
    }

    @Test("Empty fields stay without building a client or persisting")
    func staysOnEmptyFields() async {
        var clientCount = 0
        let onboarding = makeOnboarding(statusResult: .success(Self.readyStatus)) { _, _ in
            clientCount += 1
        }
        var persistCount = 0
        let outcome = await onboarding.run(
            workerURLString: "https://sandbox.example.workers.dev",
            token: "   ",
            siteID: "site-1",
            persist: { _ in persistCount += 1 },
            onConnected: { _ in },
            delay: {},
            isCancelled: { false }
        )
        if case .stay = outcome {} else { Issue.record("expected .stay, got \(outcome)") }
        #expect(persistCount == 0)
        #expect(clientCount == 0)
    }

    @Test("A malformed Worker URL stays without building a client")
    func staysOnMalformedURL() async {
        var clientCount = 0
        let onboarding = makeOnboarding(statusResult: .success(Self.readyStatus)) { _, _ in
            clientCount += 1
        }
        var persistCount = 0
        let outcome = await onboarding.run(
            workerURLString: "not a url",
            token: "tok",
            siteID: "site-1",
            persist: { _ in persistCount += 1 },
            onConnected: { _ in },
            delay: {},
            isCancelled: { false }
        )
        if case .stay = outcome {} else { Issue.record("expected .stay, got \(outcome)") }
        #expect(persistCount == 0)
        #expect(clientCount == 0)
    }

    @Test("workerURL(from:) accepts http(s) URLs and rejects missing or non-http schemes")
    func workerURLParsing() {
        #expect(SandboxControlOnboarding.workerURL(from: "https://sandbox.example.workers.dev")
            == URL(string: "https://sandbox.example.workers.dev"))
        #expect(SandboxControlOnboarding.workerURL(from: "http://localhost:8787")
            == URL(string: "http://localhost:8787"))
        #expect(SandboxControlOnboarding.workerURL(from: "sandbox.example.workers.dev") == nil)
        #expect(SandboxControlOnboarding.workerURL(from: "ftp://sandbox.example") == nil)
        #expect(SandboxControlOnboarding.workerURL(from: "not a url") == nil)
    }

    @Test("A persist failure surfaces as .stay, not .proceed")
    func staysWhenPersistThrows() async {
        struct Boom: Error {}
        let onboarding = makeOnboarding(statusResult: .success(Self.readyStatus))
        let outcome = await onboarding.run(
            workerURLString: "https://sandbox.example.workers.dev",
            token: "tok",
            siteID: "site-1",
            persist: { _ in throw Boom() },
            onConnected: { _ in },
            delay: {},
            isCancelled: { false }
        )
        if case .stay = outcome {} else { Issue.record("expected .stay, got \(outcome)") }
    }
}
