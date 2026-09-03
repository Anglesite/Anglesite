import Testing
import Foundation
@testable import AnglesiteCore
import AnglesiteTestSupport

struct ContactsAllowlistSyncTests {
    private static func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.cloudflare.com/")!, statusCode: status,
                         httpVersion: nil, headerFields: nil)!
    }

    private static func makeConfigDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("contacts-allowlist-sync-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("push reads the store's known me-URLs and forwards them to the client")
    func pushForwardsKnownMeURLs() async throws {
        let configDir = Self.makeConfigDir()
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: configDir) }
        let store = ContactStore(configDirectory: configDir)
        try await store.add(Contact(me: URL(string: "https://alice.example")!, displayName: "Alice"))

        let captured = CapturedURLs()
        let client = ContactsAllowlistKVClient(
            accountID: "acct1", namespaceID: "ns1", apiToken: "token",
            transport: { request in
                if let body = request.httpBody, let urls = try? JSONDecoder().decode([String].self, from: body) {
                    await captured.set(urls)
                }
                return (Data(), Self.response(200))
            })

        await ContactsAllowlistSync.push(store: store, client: client)

        #expect(await captured.value == ["alice.example"])
    }

    @Test("push logs and does not throw when the client fails")
    func pushSwallowsClientFailure() async throws {
        let configDir = Self.makeConfigDir()
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: configDir) }
        let store = ContactStore(configDirectory: configDir)
        let client = ContactsAllowlistKVClient(
            accountID: "acct1", namespaceID: "ns1", apiToken: "token",
            transport: { _ in (Data(), Self.response(500)) })

        // Must not throw and must not hang — the whole point of `push` is that it's safe to call
        // fire-and-forget from a UI action.
        await ContactsAllowlistSync.push(store: store, client: client)
    }

    @Test("pushIfConfigured no-ops (no network call) when SOCIAL_KV has not been provisioned")
    func noOpsWithoutKVNamespace() async {
        let configDir = Self.makeConfigDir()
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: configDir) }

        await ContactsAllowlistSync.pushIfConfigured(
            configDirectory: configDir,
            secretStore: InMemorySecretStore(token: "unused"),
            transport: { _ in
                Issue.record("transport must not be called with no provisioned SOCIAL_KV namespace")
                struct UnexpectedNetworkCall: Error {}
                throw UnexpectedNetworkCall()
            })
    }

    @Test("pushIfConfigured no-ops (no network call) when no Cloudflare token is available")
    func noOpsWithoutToken() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimClear()
        defer { cfToken.release() }
        let configDir = Self.makeConfigDir()
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: configDir) }
        try await SiteConfigStore(configDirectory: configDir).save(
            SiteSettings(provisionedWorkerResources: .init(kvNamespaceID: "ns1")))

        await ContactsAllowlistSync.pushIfConfigured(
            configDirectory: configDir,
            secretStore: InMemorySecretStore(token: nil),
            transport: { _ in
                Issue.record("transport must not be called with no Cloudflare token")
                struct UnexpectedNetworkCall: Error {}
                throw UnexpectedNetworkCall()
            })
    }

    @Test("pushIfConfigured resolves the account id and pushes the current allowlist")
    func resolvesAccountAndPushes() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimClear()
        defer { cfToken.release() }
        let configDir = Self.makeConfigDir()
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: configDir) }
        try await SiteConfigStore(configDirectory: configDir).save(
            SiteSettings(provisionedWorkerResources: .init(kvNamespaceID: "ns1")))
        let store = ContactStore(configDirectory: configDir)
        try await store.add(Contact(me: URL(string: "https://alice.example")!, displayName: "Alice"))

        let accountsBody = Data("""
        {"success": true, "result": [{"id": "acct1"}]}
        """.utf8)
        let seenAuthorization = SeenHeader()
        let capturedPUT = CapturedURLs()

        await ContactsAllowlistSync.pushIfConfigured(
            configDirectory: configDir,
            secretStore: InMemorySecretStore(token: "token"),
            transport: { request in
                await seenAuthorization.record(request.value(forHTTPHeaderField: "Authorization"))
                if request.url!.path.hasSuffix("/accounts") { return (accountsBody, Self.response(200)) }
                if request.url!.path.hasSuffix("/values/contacts:allowlist") {
                    if let body = request.httpBody, let urls = try? JSONDecoder().decode([String].self, from: body) {
                        await capturedPUT.set(urls)
                    }
                    return (Data(), Self.response(200))
                }
                return (Data(), Self.response(404))
            })

        #expect(await capturedPUT.value == ["alice.example"])
        #expect(await seenAuthorization.value == "Bearer token")
    }
}

private actor CapturedURLs {
    private(set) var value: [String]?
    func set(_ urls: [String]) { value = urls }
}

private actor SeenHeader {
    private(set) var value: String?
    func record(_ value: String?) { self.value = value }
}
