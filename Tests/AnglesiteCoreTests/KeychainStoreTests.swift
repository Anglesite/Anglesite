// Exercises the Darwin SecretStore implementation; compiles out with it off-Darwin.
#if canImport(Security)
import Testing
import Foundation
import Security
@testable import AnglesiteCore

/// Confirms the test process can talk to the keychain at all. Avoids opaque failures in CI by
/// converting "no keychain access" into a clean suite skip, evaluated once for the whole suite.
/// Kept at file scope rather than as a static member of `KeychainStoreTests` itself — referencing
/// a type's own static from its `@Suite` trait creates a circular macro-expansion error.
private let keychainStoreTestsKeychainReachable: Bool = {
    let probe = KeychainStore(service: "io.dwk.anglesite.tests.probe-\(UUID().uuidString)")
    do {
        try probe.write("probe", account: "__probe__")
        try probe.delete(account: "__probe__")
        return true
    } catch {
        return false
    }
}()

/// Each test uses a unique service name so it can't collide with the user's real Keychain entries
/// or with other tests running in parallel. The suite is skipped cleanly (via the `.enabled(if:)`
/// trait below) when the keychain isn't reachable (some CI environments and unsigned test binaries
/// reject `SecItemAdd` with `errSecMissingEntitlement` (-34018) or similar). Locally, the first run
/// may surface a one-time Keychain Access prompt — that's the system asking the user to authorize
/// the test binary.
@Suite(.enabled(if: keychainStoreTestsKeychainReachable, "keychain not reachable in this environment"))
final class KeychainStoreTests {
    private let service: String
    private let store: KeychainStore

    init() {
        service = "io.dwk.anglesite.tests." + UUID().uuidString
        store = KeychainStore(service: service)
    }

    deinit {
        // Best effort — cleanup only matters when the writes above actually landed.
        try? store.delete(account: "alpha")
        try? store.delete(account: "beta")
        try? store.delete(account: KeychainStore.cloudflareTokenAccount)
        try? store.clearCloudflareOAuthCredential()
    }

    // MARK: Round trips

    @Test("read returns nil when no entry exists")
    func readReturnsNilWhenNoEntryExists() throws {
        #expect(try store.read(account: "alpha") == nil)
    }

    @Test("write then read round trips")
    func writeThenReadRoundTrips() throws {
        try store.write("super-secret", account: "alpha")
        #expect(try store.read(account: "alpha") == "super-secret")
    }

    @Test("a second write replaces the first")
    func secondWriteReplacesTheFirst() throws {
        try store.write("first", account: "alpha")
        try store.write("second", account: "alpha")
        #expect(try store.read(account: "alpha") == "second")
    }

    @Test("delete removes an entry")
    func deleteRemovesEntry() throws {
        try store.write("temp", account: "alpha")
        try store.delete(account: "alpha")
        #expect(try store.read(account: "alpha") == nil)
    }

    @Test("delete is a no-op when the entry is absent")
    func deleteIsNoOpWhenEntryAbsent() throws {
        #expect(throws: Never.self) {
            try store.delete(account: "never-existed")
        }
    }

    @Test("writing an empty value deletes the entry")
    func emptyValueWriteDeletesTheEntry() throws {
        try store.write("present", account: "alpha")
        try store.write("", account: "alpha")
        #expect(try store.read(account: "alpha") == nil)
    }

    @Test("accounts are independent under the same service")
    func accountsAreIndependentUnderTheSameService() throws {
        try store.write("A", account: "alpha")
        try store.write("B", account: "beta")
        #expect(try store.read(account: "alpha") == "A")
        #expect(try store.read(account: "beta") == "B")
        try store.delete(account: "alpha")
        #expect(try store.read(account: "alpha") == nil)
        #expect(try store.read(account: "beta") == "B")
    }

    @Test("services are independent")
    func servicesAreIndependent() throws {
        let other = KeychainStore(service: service + ".other")
        do {
            try store.write("here", account: "alpha")
            try other.write("there", account: "alpha")
            #expect(try store.read(account: "alpha") == "here")
            #expect(try other.read(account: "alpha") == "there")
        }
        try? other.delete(account: "alpha")
    }

    // MARK: Access group (#1208 P2 — live at the two device-pairing call sites)

    /// The safety property for the `accessGroup` parameter: the default init must construct exactly
    /// the query it did before the parameter existed. Asserted structurally rather than only
    /// behaviorally because "no `kSecAttrAccessGroup` key at all" is the specific thing that keeps
    /// the system applying the process's own default group.
    @Test("the default init omits accessGroup from queries")
    func defaultInitOmitsAccessGroupFromQueries() throws {
        #expect(store.accessGroup == nil)
        let query = store.baseQuery(account: "alpha")
        #expect(query[kSecAttrAccessGroup as String] == nil)
        #expect(query.keys.sorted() == [
            kSecAttrAccount as String,
            kSecAttrService as String,
            kSecAttrSynchronizable as String,
            kSecClass as String
        ].sorted())
    }

    /// An explicit `accessGroup: nil` is the same store as the default — pinned so a future caller
    /// threading an optional through can't accidentally change behavior.
    @Test("an explicit nil accessGroup matches the default init")
    func explicitNilAccessGroupMatchesDefaultInit() throws {
        let explicit = KeychainStore(service: service, accessGroup: nil)
        #expect(explicit.accessGroup == nil)
        #expect(
            explicit.baseQuery(account: "alpha").keys.sorted() ==
            store.baseQuery(account: "alpha").keys.sorted())
        // And it still round-trips against the real keychain, unchanged.
        try explicit.write("via-explicit-nil", account: "alpha")
        #expect(try store.read(account: "alpha") == "via-explicit-nil")
    }

    /// A non-nil group reaches the query dictionary under `kSecAttrAccessGroup`.
    ///
    /// This is as far as this suite can go: whether the *system* then shares the item between
    /// `Anglesite.app` and `AnglesiteRemote` depends on both bundles carrying the group in a
    /// `keychain-access-groups` entitlement, which their Release entitlements files now do — but
    /// this test binary does not, and an unentitled `SecItem` call carrying an access group is
    /// simply rejected. So no test runnable here can prove or disprove the sharing itself, and the
    /// binary deliberately never issues such a call: only a real signed launch of the two apps
    /// observes it (`Resources/AnglesiteRemote.entitlements` ▸ step 2).
    @Test("accessGroup appears in queries when set")
    func accessGroupAppearsInQueriesWhenSet() throws {
        let scoped = KeychainStore(service: service, accessGroup: "TESTPREFIX.io.dwk.anglesite.shared")
        #expect(scoped.accessGroup == "TESTPREFIX.io.dwk.anglesite.shared")
        let query = scoped.baseQuery(account: "alpha")
        #expect(query[kSecAttrAccessGroup as String] as? String == "TESTPREFIX.io.dwk.anglesite.shared")
        // Everything else about the query is unchanged by the new attribute.
        #expect(query[kSecAttrService as String] as? String == service)
        #expect(query[kSecAttrAccount as String] as? String == "alpha")
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
    }

    /// Pins the shared group string's shape. Every entitlements file that declares the group spells
    /// it `$(AppIdentifierPrefix)io.dwk.anglesite.shared`, which the build expands to this — a
    /// mismatch between the two forms is silent (the processes just never see a shared item), so
    /// the suffix and the team prefix are asserted rather than left to review. `M34HBJZNYA` is the
    /// team holding the paid Apple Developer Program membership the portal-gated CloudKit and
    /// App-Groups capabilities — and this group's own provisioning-profile requirement — depend on,
    /// so it is the team the entitlements declaring this group are signed under.
    @Test("sharedPairingAccessGroup is team-prefixed")
    func sharedPairingAccessGroupIsTeamPrefixed() {
        #expect(KeychainStore.sharedPairingAccessGroup == "M34HBJZNYA.io.dwk.anglesite.shared")
        #expect(KeychainStore.sharedPairingAccessGroup.hasSuffix(".io.dwk.anglesite.shared"))
    }

    /// The plain `KeychainStore()` every non-pairing caller constructs still carries no access
    /// group. Only the two device-pairing call sites opt into ``KeychainStore/sharedPairingAccessGroup``,
    /// so activating it must not have dragged the Cloudflare/GitHub/ACP slots into a shared group —
    /// those would then fail with `errSecMissingEntitlement` on every build that lacks it.
    @Test("the production default store still uses no access group")
    func productionDefaultStoreStillUsesNoAccessGroup() {
        #expect(KeychainStore().accessGroup == nil)
        #expect(KeychainStore().service == KeychainStore.defaultService)
    }

    // MARK: Cloudflare convenience

    @Test("Cloudflare convenience methods round trip")
    func cloudflareConvenienceRoundTrips() throws {
        #expect(try store.readCloudflareToken() == nil)
        try store.writeCloudflareToken("cf-token-xyz")
        #expect(try store.readCloudflareToken() == "cf-token-xyz")
        try store.clearCloudflareToken()
        #expect(try store.readCloudflareToken() == nil)
    }

    // MARK: OAuth credential

    @Test("the OAuth credential convenience methods round trip")
    func oAuthCredentialConvenienceRoundTrips() throws {
        let endpoint = URL(string: "https://dash.cloudflare.com/oauth2/token")!
        defer { try? store.clearCloudflareOAuthCredential() }
        #expect(try store.readCloudflareOAuthCredential() == nil)
        let credential = CloudflareOAuthCredential(
            accessToken: "tok", refreshToken: "refresh",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000), tokenEndpoint: endpoint)
        try store.writeCloudflareOAuthCredential(credential)
        #expect(try store.readCloudflareOAuthCredential() == credential)
        try store.clearCloudflareOAuthCredential()
        #expect(try store.readCloudflareOAuthCredential() == nil)
    }

    @Test("the OAuth token source resolves against the real keychain")
    func oAuthTokenSourceResolvesAgainstRealKeychain() async throws {
        let endpoint = URL(string: "https://dash.cloudflare.com/oauth2/token")!
        defer { try? store.clearCloudflareOAuthCredential() }
        try store.writeCloudflareOAuthCredential(CloudflareOAuthCredential(
            accessToken: "real-keychain-tok", refreshToken: nil, expiresAt: nil, tokenEndpoint: endpoint))
        let source = CloudflareOAuthTokenSource(secretStore: store, refresh: { _, _ in
            Issue.record("refresh should not be called for a non-expiring credential")
            throw CloudflareOAuthError.tokenExchangeFailed("unexpected")
        })
        let resolved = try await source.resolve()
        #expect(resolved == "real-keychain-tok")
    }

    // MARK: ACP agent token convenience

    @Test("ACP agent token convenience methods round trip")
    func acpAgentTokenConvenienceRoundTrips() throws {
        let agentID = UUID()
        defer { try? store.clearACPAgentToken(id: agentID) }
        #expect(try store.readACPAgentToken(id: agentID) == nil)
        try store.writeACPAgentToken("acp-token-xyz", id: agentID)
        #expect(try store.readACPAgentToken(id: agentID) == "acp-token-xyz")
        try store.clearACPAgentToken(id: agentID)
        #expect(try store.readACPAgentToken(id: agentID) == nil)
    }

    @Test("ACP agent tokens are independent per agent id")
    func acpAgentTokensAreIndependentPerAgentID() throws {
        let a = UUID()
        let b = UUID()
        defer {
            try? store.clearACPAgentToken(id: a)
            try? store.clearACPAgentToken(id: b)
        }
        try store.writeACPAgentToken("token-a", id: a)
        try store.writeACPAgentToken("token-b", id: b)
        #expect(try store.readACPAgentToken(id: a) == "token-a")
        #expect(try store.readACPAgentToken(id: b) == "token-b")
    }
}
#endif
