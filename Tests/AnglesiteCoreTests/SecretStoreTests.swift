import Foundation
import Testing
@testable import AnglesiteCore

/// Portable contract tests for the SecretStore seam — run on every platform (unlike
/// `KeychainStoreTests`, which exercises the Darwin implementation against the real
/// keychain). The in-memory store below doubles as a reference for the semantics every
/// platform implementation must uphold.
struct SecretStoreTests {
    /// Minimal conforming store used to pin the protocol-extension convenience methods.
    private final class InMemorySecretStore: SecretStore, @unchecked Sendable {
        private var entries: [String: String] = [:]
        private let lock = NSLock()

        func read(account: String) throws -> String? {
            lock.withLock { entries[account] }
        }

        func write(_ value: String, account: String) throws {
            lock.withLock {
                if value.isEmpty {
                    entries[account] = nil
                } else {
                    entries[account] = value
                }
            }
        }

        func delete(account: String) throws {
            lock.withLock { entries[account] = nil }
        }
    }

    @Test("Cloudflare convenience methods address the shared SecretAccounts slot")
    func cloudflareConvenienceUsesSharedAccount() throws {
        let store = InMemorySecretStore()
        try store.writeCloudflareToken("tok-123")
        #expect(try store.read(account: SecretAccounts.cloudflareToken) == "tok-123")
        #expect(try store.readCloudflareToken() == "tok-123")
        try store.clearCloudflareToken()
        #expect(try store.readCloudflareToken() == nil)
    }

    @Test("GitHub convenience methods address the shared SecretAccounts slot")
    func gitHubConvenienceUsesSharedAccount() throws {
        let store = InMemorySecretStore()
        try store.writeGitHubToken("ghp_123")
        #expect(try store.read(account: SecretAccounts.gitHubToken) == "ghp_123")
        #expect(try store.readGitHubToken() == "ghp_123")
        // Distinct from the Cloudflare slot — writing one must not clobber the other.
        try store.writeCloudflareToken("cf-456")
        #expect(try store.readGitHubToken() == "ghp_123")
        try store.clearGitHubToken()
        #expect(try store.readGitHubToken() == nil)
        #expect(try store.readCloudflareToken() == "cf-456")
    }

    @Test("External LLM API key convenience methods address the shared SecretAccounts slot")
    func externalLLMAPIKeyConvenienceUsesSharedAccount() throws {
        let store = InMemorySecretStore()
        try store.writeExternalLLMAPIKey("sk-test-123")
        #expect(try store.read(account: SecretAccounts.externalLLMAPIKey) == "sk-test-123")
        #expect(try store.readExternalLLMAPIKey() == "sk-test-123")
        // Distinct from the GitHub slot — writing one must not clobber the other.
        try store.writeGitHubToken("ghp_456")
        #expect(try store.readExternalLLMAPIKey() == "sk-test-123")
        try store.clearExternalLLMAPIKey()
        #expect(try store.readExternalLLMAPIKey() == nil)
        #expect(try store.readGitHubToken() == "ghp_456")
    }

    @Test("Micropub session conveniences round-trip the token and DPoP key pair per site")
    func micropubSessionRoundTrips() throws {
        let store = InMemorySecretStore()
        let keyPair = DPoPKeyPair()
        try store.writeMicropubAccessToken("mp-tok", siteID: "site-a")
        try store.writeMicropubDPoPKeyPair(keyPair, siteID: "site-a")
        #expect(try store.readMicropubAccessToken(siteID: "site-a") == "mp-tok")
        #expect(try store.readMicropubDPoPKeyPair(siteID: "site-a")?.persistedRepresentation
            == keyPair.persistedRepresentation)
        // Scoped per site — another site's slots stay empty.
        #expect(try store.readMicropubAccessToken(siteID: "site-b") == nil)
    }

    @Test("clearMicropubSession removes the token and key pair as one unit")
    func clearMicropubSessionClearsBoth() throws {
        let store = InMemorySecretStore()
        try store.writeMicropubAccessToken("mp-tok", siteID: "site-a")
        try store.writeMicropubDPoPKeyPair(DPoPKeyPair(), siteID: "site-a")
        try store.clearMicropubSession(siteID: "site-a")
        #expect(try store.readMicropubAccessToken(siteID: "site-a") == nil)
        #expect(try store.readMicropubDPoPKeyPair(siteID: "site-a") == nil)
    }

    @Test("the Micropub session is a distinct entry from the Microsub IndieAuth session")
    func micropubSessionDistinctFromMicrosub() throws {
        // #868's requirement: the phone's Micropub credential must never clobber (or be
        // clobbered by) the Mac reader's Microsub credential for the same site.
        let store = InMemorySecretStore()
        try store.writeIndieAuthAccessToken("microsub-tok", siteID: "site-a")
        try store.writeMicropubAccessToken("micropub-tok", siteID: "site-a")
        #expect(try store.readIndieAuthAccessToken(siteID: "site-a") == "microsub-tok")
        try store.clearMicropubSession(siteID: "site-a")
        #expect(try store.readIndieAuthAccessToken(siteID: "site-a") == "microsub-tok")
    }

    /// A store that simulates the #1705 scenario: `read` behaves normally (as the foreground,
    /// interactive path would), but `readNonInteractive` always reports "unavailable" — standing
    /// in for a keychain query that would need to show a prompt nobody can answer. Used to pin that
    /// the `*NonInteractive` convenience methods actually route through the store's own
    /// `readNonInteractive` override rather than silently falling back to `read`.
    private final class WouldPromptSecretStore: SecretStore, @unchecked Sendable {
        private var entries: [String: String] = [:]

        func read(account: String) throws -> String? { entries[account] }
        func readNonInteractive(account: String) throws -> String? { nil }
        func write(_ value: String, account: String) throws { entries[account] = value.isEmpty ? nil : value }
        func delete(account: String) throws { entries[account] = nil }
    }

    @Test("readCloudflareTokenNonInteractive defaults to read(account:) when a store has no override")
    func readCloudflareTokenNonInteractiveDefaultsToRead() throws {
        let store = InMemorySecretStore()
        try store.writeCloudflareToken("tok-123")
        #expect(try store.readCloudflareTokenNonInteractive() == "tok-123")
    }

    @Test("readCloudflareTokenNonInteractive reports nothing when the store's override would prompt")
    func readCloudflareTokenNonInteractiveHonorsOverride() throws {
        let store = WouldPromptSecretStore()
        try store.writeCloudflareToken("tok-123")
        #expect(try store.readCloudflareToken() == "tok-123")
        #expect(try store.readCloudflareTokenNonInteractive() == nil)
    }

    @Test("readCloudflareOAuthCredentialNonInteractive defaults to read(account:) when a store has no override")
    func readCloudflareOAuthCredentialNonInteractiveDefaultsToRead() throws {
        let store = InMemorySecretStore()
        let credential = CloudflareOAuthCredential(
            accessToken: "tok", refreshToken: "refresh", expiresAt: nil,
            tokenEndpoint: URL(string: "https://dash.cloudflare.com/oauth2/token")!)
        try store.writeCloudflareOAuthCredential(credential)
        #expect(try store.readCloudflareOAuthCredentialNonInteractive() == credential)
    }

    @Test("readCloudflareOAuthCredentialNonInteractive reports nothing when the store's override would prompt")
    func readCloudflareOAuthCredentialNonInteractiveHonorsOverride() throws {
        let store = WouldPromptSecretStore()
        try store.writeCloudflareOAuthCredential(CloudflareOAuthCredential(
            accessToken: "tok", refreshToken: "refresh", expiresAt: nil,
            tokenEndpoint: URL(string: "https://dash.cloudflare.com/oauth2/token")!))
        #expect(try store.readCloudflareOAuthCredential() != nil)
        #expect(try store.readCloudflareOAuthCredentialNonInteractive() == nil)
    }

    @Test("UnavailableSecretStore reads nothing, deletes as no-op, and refuses writes")
    func unavailableStoreBehavior() throws {
        let store = UnavailableSecretStore()
        #expect(try store.read(account: "anything") == nil)
        try store.delete(account: "anything")  // must not throw
        // Empty write means delete (protocol contract), so it must succeed as a no-op
        // even though persisting is unsupported.
        try store.write("", account: "anything")
        #expect(throws: UnavailableSecretStore.WriteUnsupported.self) {
            try store.write("secret", account: "anything")
        }
    }

    @Test("PlatformSecretStore.make returns the platform default")
    func platformDefaultResolves() {
        let store = PlatformSecretStore.make()
        #if canImport(Security)
        #expect(store is KeychainStore)
        #else
        #expect(store is UnavailableSecretStore)
        #endif
    }
}

@Suite("SecretAccounts")
struct SecretAccountsTests {
    @Test("activityPubPrivateKeyPem is namespaced per site, matching the mastodonAccessToken pattern")
    func activityPubPrivateKeyPemIsPerSite() {
        let a = SecretAccounts.activityPubPrivateKeyPem(siteID: "site-a")
        let b = SecretAccounts.activityPubPrivateKeyPem(siteID: "site-b")
        #expect(a != b)
        #expect(a.contains("site-a"))
    }

    @Test("activityPubPublishToken is namespaced per site and distinct from the private key account")
    func activityPubPublishTokenIsPerSiteAndDistinct() {
        let token = SecretAccounts.activityPubPublishToken(siteID: "site-a")
        let key = SecretAccounts.activityPubPrivateKeyPem(siteID: "site-a")
        #expect(token != key)
        #expect(token.contains("site-a"))
    }
}
