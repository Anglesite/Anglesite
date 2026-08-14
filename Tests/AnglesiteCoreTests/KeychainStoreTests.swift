// Exercises the Darwin SecretStore implementation; compiles out with it off-Darwin.
#if canImport(Security)
import Security
import XCTest
@testable import AnglesiteCore

/// Each test uses a unique service name so it can't collide with the user's real Keychain entries
/// or with other tests running in parallel. Tests `XCTSkip` cleanly when the keychain isn't
/// reachable (some CI environments and unsigned test binaries reject `SecItemAdd` with
/// `errSecMissingEntitlement` (-34018) or similar). Locally, the first run may surface a one-time
/// Keychain Access prompt — that's the system asking the user to authorize the test binary.
final class KeychainStoreTests: XCTestCase {
    private var service: String = ""
    private var store: KeychainStore!

    override func setUp() async throws {
        service = "io.dwk.anglesite.tests." + UUID().uuidString
        store = KeychainStore(service: service)
        try await probeKeychainOrSkip()
    }

    override func tearDown() async throws {
        // Best effort — if the keychain refused us in setUp, this won't matter.
        try? store.delete(account: "alpha")
        try? store.delete(account: "beta")
        try? store.delete(account: KeychainStore.cloudflareTokenAccount)
        try? store.clearCloudflareOAuthCredential()
    }

    /// Confirm the test process can talk to the keychain at all. Avoids opaque failures in CI by
    /// converting "no keychain access" into a clean skip.
    private func probeKeychainOrSkip() async throws {
        do {
            try store.write("probe", account: "__probe__")
            try store.delete(account: "__probe__")
        } catch KeychainStore.Error.unhandled(let status) {
            throw XCTSkip("keychain not reachable in this environment (OSStatus \(status))")
        }
    }

    // MARK: Round trips

    func testReadReturnsNilWhenNoEntryExists() throws {
        XCTAssertNil(try store.read(account: "alpha"))
    }

    func testWriteThenReadRoundTrips() throws {
        try store.write("super-secret", account: "alpha")
        XCTAssertEqual(try store.read(account: "alpha"), "super-secret")
    }

    func testSecondWriteReplacesTheFirst() throws {
        try store.write("first", account: "alpha")
        try store.write("second", account: "alpha")
        XCTAssertEqual(try store.read(account: "alpha"), "second")
    }

    func testDeleteRemovesEntry() throws {
        try store.write("temp", account: "alpha")
        try store.delete(account: "alpha")
        XCTAssertNil(try store.read(account: "alpha"))
    }

    func testDeleteIsNoOpWhenEntryAbsent() throws {
        XCTAssertNoThrow(try store.delete(account: "never-existed"))
    }

    func testEmptyValueWriteDeletesTheEntry() throws {
        try store.write("present", account: "alpha")
        try store.write("", account: "alpha")
        XCTAssertNil(try store.read(account: "alpha"))
    }

    func testAccountsAreIndependentUnderTheSameService() throws {
        try store.write("A", account: "alpha")
        try store.write("B", account: "beta")
        XCTAssertEqual(try store.read(account: "alpha"), "A")
        XCTAssertEqual(try store.read(account: "beta"), "B")
        try store.delete(account: "alpha")
        XCTAssertNil(try store.read(account: "alpha"))
        XCTAssertEqual(try store.read(account: "beta"), "B")
    }

    func testServicesAreIndependent() throws {
        let other = KeychainStore(service: service + ".other")
        do {
            try store.write("here", account: "alpha")
            try other.write("there", account: "alpha")
            XCTAssertEqual(try store.read(account: "alpha"), "here")
            XCTAssertEqual(try other.read(account: "alpha"), "there")
        }
        try? other.delete(account: "alpha")
    }

    // MARK: Access group (#1208 P2 — live at the two device-pairing call sites)

    /// The safety property for the `accessGroup` parameter: the default init must construct exactly
    /// the query it did before the parameter existed. Asserted structurally rather than only
    /// behaviorally because "no `kSecAttrAccessGroup` key at all" is the specific thing that keeps
    /// the system applying the process's own default group.
    func testDefaultInitOmitsAccessGroupFromQueries() throws {
        XCTAssertNil(store.accessGroup)
        let query = store.baseQuery(account: "alpha")
        XCTAssertNil(query[kSecAttrAccessGroup as String])
        XCTAssertEqual(query.keys.sorted(), [
            kSecAttrAccount as String,
            kSecAttrService as String,
            kSecAttrSynchronizable as String,
            kSecClass as String
        ].sorted())
    }

    /// An explicit `accessGroup: nil` is the same store as the default — pinned so a future caller
    /// threading an optional through can't accidentally change behavior.
    func testExplicitNilAccessGroupMatchesDefaultInit() throws {
        let explicit = KeychainStore(service: service, accessGroup: nil)
        XCTAssertNil(explicit.accessGroup)
        XCTAssertEqual(
            explicit.baseQuery(account: "alpha").keys.sorted(),
            store.baseQuery(account: "alpha").keys.sorted())
        // And it still round-trips against the real keychain, unchanged.
        try explicit.write("via-explicit-nil", account: "alpha")
        XCTAssertEqual(try store.read(account: "alpha"), "via-explicit-nil")
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
    func testAccessGroupAppearsInQueriesWhenSet() throws {
        let scoped = KeychainStore(service: service, accessGroup: "TESTPREFIX.io.dwk.anglesite.shared")
        XCTAssertEqual(scoped.accessGroup, "TESTPREFIX.io.dwk.anglesite.shared")
        let query = scoped.baseQuery(account: "alpha")
        XCTAssertEqual(query[kSecAttrAccessGroup as String] as? String, "TESTPREFIX.io.dwk.anglesite.shared")
        // Everything else about the query is unchanged by the new attribute.
        XCTAssertEqual(query[kSecAttrService as String] as? String, service)
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "alpha")
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
    }

    /// Pins the shared group string's shape. Every entitlements file that declares the group spells
    /// it `$(AppIdentifierPrefix)io.dwk.anglesite.shared`, which the build expands to this — a
    /// mismatch between the two forms is silent (the processes just never see a shared item), so
    /// the suffix and the team prefix are asserted rather than left to review. `M34HBJZNYA` is the
    /// team holding the paid Apple Developer Program membership the portal-gated CloudKit and
    /// App-Groups capabilities — and this group's own provisioning-profile requirement — depend on,
    /// so it is the team the entitlements declaring this group are signed under.
    func testSharedPairingAccessGroupIsTeamPrefixed() {
        XCTAssertEqual(KeychainStore.sharedPairingAccessGroup, "M34HBJZNYA.io.dwk.anglesite.shared")
        XCTAssertTrue(KeychainStore.sharedPairingAccessGroup.hasSuffix(".io.dwk.anglesite.shared"))
    }

    /// The plain `KeychainStore()` every non-pairing caller constructs still carries no access
    /// group. Only the two device-pairing call sites opt into ``KeychainStore/sharedPairingAccessGroup``,
    /// so activating it must not have dragged the Cloudflare/GitHub/ACP slots into a shared group —
    /// those would then fail with `errSecMissingEntitlement` on every build that lacks it.
    func testProductionDefaultStoreStillUsesNoAccessGroup() {
        XCTAssertNil(KeychainStore().accessGroup)
        XCTAssertEqual(KeychainStore().service, KeychainStore.defaultService)
    }

    // MARK: Cloudflare convenience

    func testCloudflareConvenienceRoundTrips() throws {
        XCTAssertNil(try store.readCloudflareToken())
        try store.writeCloudflareToken("cf-token-xyz")
        XCTAssertEqual(try store.readCloudflareToken(), "cf-token-xyz")
        try store.clearCloudflareToken()
        XCTAssertNil(try store.readCloudflareToken())
    }

    // MARK: OAuth credential

    func testOAuthCredentialConvenienceRoundTrips() throws {
        let endpoint = URL(string: "https://dash.cloudflare.com/oauth2/token")!
        defer { try? store.clearCloudflareOAuthCredential() }
        XCTAssertNil(try store.readCloudflareOAuthCredential())
        let credential = CloudflareOAuthCredential(
            accessToken: "tok", refreshToken: "refresh",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000), tokenEndpoint: endpoint)
        try store.writeCloudflareOAuthCredential(credential)
        XCTAssertEqual(try store.readCloudflareOAuthCredential(), credential)
        try store.clearCloudflareOAuthCredential()
        XCTAssertNil(try store.readCloudflareOAuthCredential())
    }

    func testOAuthTokenSourceResolvesAgainstRealKeychain() async throws {
        let endpoint = URL(string: "https://dash.cloudflare.com/oauth2/token")!
        defer { try? store.clearCloudflareOAuthCredential() }
        try store.writeCloudflareOAuthCredential(CloudflareOAuthCredential(
            accessToken: "real-keychain-tok", refreshToken: nil, expiresAt: nil, tokenEndpoint: endpoint))
        let source = CloudflareOAuthTokenSource(secretStore: store, refresh: { _, _ in
            XCTFail("refresh should not be called for a non-expiring credential")
            throw CloudflareOAuthError.tokenExchangeFailed("unexpected")
        })
        let resolved = try await source.resolve()
        XCTAssertEqual(resolved, "real-keychain-tok")
    }

    // MARK: ACP agent token convenience

    func testACPAgentTokenConvenienceRoundTrips() throws {
        let agentID = UUID()
        defer { try? store.clearACPAgentToken(id: agentID) }
        XCTAssertNil(try store.readACPAgentToken(id: agentID))
        try store.writeACPAgentToken("acp-token-xyz", id: agentID)
        XCTAssertEqual(try store.readACPAgentToken(id: agentID), "acp-token-xyz")
        try store.clearACPAgentToken(id: agentID)
        XCTAssertNil(try store.readACPAgentToken(id: agentID))
    }

    func testACPAgentTokensAreIndependentPerAgentID() throws {
        let a = UUID()
        let b = UUID()
        defer {
            try? store.clearACPAgentToken(id: a)
            try? store.clearACPAgentToken(id: b)
        }
        try store.writeACPAgentToken("token-a", id: a)
        try store.writeACPAgentToken("token-b", id: b)
        XCTAssertEqual(try store.readACPAgentToken(id: a), "token-a")
        XCTAssertEqual(try store.readACPAgentToken(id: b), "token-b")
    }
}
#endif
