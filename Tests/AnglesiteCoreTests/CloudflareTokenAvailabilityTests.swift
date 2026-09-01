import Foundation
import Testing
import AnglesiteTestSupport
@testable import AnglesiteCore

/// #1705 — `CloudflareTokenAvailability.probe` exists so a background caller can ask "is a
/// Cloudflare credential configured?" without running `SecItemCopyMatching` on its own actor,
/// where an unanswered securityd authorization panel would stop the whole app rendering.
///
/// `.serialized`: the busy-store tests park a read on the process-wide serial probe queue, so they
/// must not overlap each other or the tests that expect a prompt answer.
@Suite("CloudflareTokenAvailability", .serialized, .timeLimit(.minutes(1)))
struct CloudflareTokenAvailabilityTests {
    private let endpoint = URL(string: "https://dash.cloudflare.com/oauth2/token")!

    @Test("the env var resolves without consulting the store at all")
    func environmentTokenShortCircuitsTheStore() async {
        let store = RecordingSecretStore()

        let outcome = await CloudflareTokenAvailability.probe(
            secretStore: store, environment: ["CLOUDFLARE_API_TOKEN": "env-token"])

        #expect(outcome == .available)
        // Reading the environment can't prompt, so there's no reason to pay for a hop or a read.
        #expect(store.accountsRead.isEmpty)
    }

    @Test("an empty env var falls through to the store")
    func emptyEnvironmentTokenFallsThrough() async {
        let store = InMemorySecretStore()
        try? store.writeCloudflareToken("pasted-token")

        let outcome = await CloudflareTokenAvailability.probe(
            secretStore: store, environment: ["CLOUDFLARE_API_TOKEN": ""])

        #expect(outcome == .available)
    }

    @Test("nothing configured reads as unavailable, not undetermined")
    func emptyStoreIsUnavailable() async {
        let outcome = await CloudflareTokenAvailability.probe(
            secretStore: InMemorySecretStore(), environment: [:])

        #expect(outcome == .unavailable)
    }

    @Test("a stored OAuth credential is available")
    func oauthCredentialIsAvailable() async {
        let store = InMemorySecretStore()
        try? store.writeCloudflareOAuthCredential(CloudflareOAuthCredential(
            accessToken: "signed-in", refreshToken: nil, expiresAt: nil, tokenEndpoint: endpoint))

        let outcome = await CloudflareTokenAvailability.probe(secretStore: store, environment: [:])

        #expect(outcome == .available)
    }

    @Test("an expired credential with no refresh token falls through to the legacy slot")
    func deadOAuthCredentialFallsThroughToLegacyToken() async {
        let store = InMemorySecretStore()
        let expired = Date(timeIntervalSince1970: 1_000)
        try? store.writeCloudflareOAuthCredential(CloudflareOAuthCredential(
            accessToken: "stale", refreshToken: nil, expiresAt: expired, tokenEndpoint: endpoint))

        let withoutLegacy = await CloudflareTokenAvailability.probe(
            secretStore: store, environment: [:], now: expired.addingTimeInterval(1))
        #expect(withoutLegacy == .unavailable)

        try? store.writeCloudflareToken("pasted-token")
        let withLegacy = await CloudflareTokenAvailability.probe(
            secretStore: store, environment: [:], now: expired.addingTimeInterval(1))
        #expect(withLegacy == .available)
    }

    @Test("an expired credential that can still be refreshed stays available")
    func refreshableExpiredCredentialIsAvailable() async {
        let store = InMemorySecretStore()
        let expired = Date(timeIntervalSince1970: 1_000)
        try? store.writeCloudflareOAuthCredential(CloudflareOAuthCredential(
            accessToken: "stale", refreshToken: "refresh-me", expiresAt: expired,
            tokenEndpoint: endpoint))

        let outcome = await CloudflareTokenAvailability.probe(
            secretStore: store, environment: [:], now: expired.addingTimeInterval(1))

        #expect(outcome == .available)
    }

    @Test("the store read never runs on the main thread, even when probed from the main actor")
    @MainActor
    func probeReadsOffTheMainThread() async {
        let store = RecordingSecretStore()

        let outcome = await CloudflareTokenAvailability.probe(secretStore: store, environment: [:])

        #expect(outcome == .unavailable)
        #expect(!store.accountsRead.isEmpty)
        #expect(store.mainThreadReadCount == 0)
    }

    @Test("a store that hasn't answered yet reads as undetermined rather than as no token")
    func busyStoreIsUndetermined() async {
        // Stands in for `SecItemCopyMatching` parked in securityd's authorization panel. The gate
        // must be opened before this test returns — the probe queue is process-wide and serial.
        let store = RecordingSecretStore(gated: true)
        defer { store.openGate() }

        let clock = ContinuousClock()
        let started = clock.now
        let outcome = await CloudflareTokenAvailability.probe(
            secretStore: store, environment: [:], timeout: .milliseconds(50))
        let elapsed = clock.now - started

        // "Undetermined", not "unavailable": a credential may well be stored behind that panel.
        #expect(outcome == .undetermined)
        #expect(elapsed < .seconds(5), "the probe waited on the blocked read instead of giving up")
    }

    @Test("evaluate() agrees with probe() when the store answers immediately")
    func evaluateMatchesProbe() async {
        let store = InMemorySecretStore()
        #expect(!CloudflareTokenAvailability.evaluate(secretStore: store, environment: [:]))

        try? store.writeCloudflareToken("pasted-token")
        #expect(CloudflareTokenAvailability.evaluate(secretStore: store, environment: [:]))
        #expect(CloudflareTokenAvailability.evaluate(
            secretStore: InMemorySecretStore(), environment: ["CLOUDFLARE_API_TOKEN": "env-token"]))
    }
}
