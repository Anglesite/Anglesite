import Testing
import Foundation
@testable import AnglesiteCore
import AnglesiteTestSupport

struct BlogrollTrustSyncTests {
    private static func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.cloudflare.com/")!, statusCode: status,
                         httpVersion: nil, headerFields: nil)!
    }

    private static func makeSiteDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blogroll-trust-sync-\(UUID().uuidString)", isDirectory: true)
        let blogrollDir = dir.appendingPathComponent("src/content/blogroll", isDirectory: true)
        try FileManager.default.createDirectory(at: blogrollDir, withIntermediateDirectories: true)
        return dir
    }

    private static func writeEntry(name: String, url: String, in siteDirectory: URL) throws {
        let content = """
        ---
        name: \(name)
        url: \(url)
        addedDate: 2026-08-01
        ---
        """
        let file = siteDirectory.appendingPathComponent("src/content/blogroll/\(name).md")
        try content.write(to: file, atomically: true, encoding: .utf8)
    }

    @Test("push extracts hostnames from blogroll entries and forwards them to the client")
    func pushForwardsHostnames() async throws {
        let siteDirectory = try Self.makeSiteDirectory()
        defer { try? FileManager.default.removeItem(at: siteDirectory) }
        try Self.writeEntry(name: "alice", url: "https://alice.example/", in: siteDirectory)
        try Self.writeEntry(name: "bob", url: "https://bob.example/blog", in: siteDirectory)
        let plan = BlogrollPlan.build(projectRoot: siteDirectory)

        let captured = CapturedURLs()
        let client = BlogrollTrustKVClient(
            accountID: "acct1", namespaceID: "ns1", apiToken: "token",
            transport: { request in
                if let body = request.httpBody, let domains = try? JSONDecoder().decode([String].self, from: body) {
                    await captured.set(domains)
                }
                return (Data(), Self.response(200))
            })

        await BlogrollTrustSync.push(entries: plan.entries, client: client)

        #expect(await captured.value == ["alice.example", "bob.example"])
    }

    @Test("push lowercases hostnames so a mixed-case blogroll URL still matches the lookup")
    func pushLowercasesHostnames() async throws {
        let siteDirectory = try Self.makeSiteDirectory()
        defer { try? FileManager.default.removeItem(at: siteDirectory) }
        try Self.writeEntry(name: "alice", url: "https://Alice.Example/", in: siteDirectory)
        let plan = BlogrollPlan.build(projectRoot: siteDirectory)

        let captured = CapturedURLs()
        let client = BlogrollTrustKVClient(
            accountID: "acct1", namespaceID: "ns1", apiToken: "token",
            transport: { request in
                if let body = request.httpBody, let domains = try? JSONDecoder().decode([String].self, from: body) {
                    await captured.set(domains)
                }
                return (Data(), Self.response(200))
            })

        await BlogrollTrustSync.push(entries: plan.entries, client: client)

        // `vouch-trust.ts`'s isTrustedVouchDomain is looked up against a hostname already
        // lowercased by `verifyVouch`, so the pushed set must be lowercased too.
        #expect(await captured.value == ["alice.example"])
    }

    @Test("push dedupes multiple entries on the same host")
    func pushDedupesHosts() async throws {
        let siteDirectory = try Self.makeSiteDirectory()
        defer { try? FileManager.default.removeItem(at: siteDirectory) }
        try Self.writeEntry(name: "alice-posts", url: "https://alice.example/posts", in: siteDirectory)
        try Self.writeEntry(name: "alice-notes", url: "https://alice.example/notes", in: siteDirectory)
        let plan = BlogrollPlan.build(projectRoot: siteDirectory)

        let captured = CapturedURLs()
        let client = BlogrollTrustKVClient(
            accountID: "acct1", namespaceID: "ns1", apiToken: "token",
            transport: { request in
                if let body = request.httpBody, let domains = try? JSONDecoder().decode([String].self, from: body) {
                    await captured.set(domains)
                }
                return (Data(), Self.response(200))
            })

        await BlogrollTrustSync.push(entries: plan.entries, client: client)

        #expect(await captured.value == ["alice.example"])
    }

    @Test("push sends an empty array for an empty blogroll, not a no-op")
    func pushSendsEmptyArray() async throws {
        let siteDirectory = try Self.makeSiteDirectory()
        defer { try? FileManager.default.removeItem(at: siteDirectory) }
        let plan = BlogrollPlan.build(projectRoot: siteDirectory)
        #expect(plan.entries.isEmpty)

        let captured = CapturedURLs()
        let client = BlogrollTrustKVClient(
            accountID: "acct1", namespaceID: "ns1", apiToken: "token",
            transport: { request in
                if let body = request.httpBody, let domains = try? JSONDecoder().decode([String].self, from: body) {
                    await captured.set(domains)
                }
                return (Data(), Self.response(200))
            })

        await BlogrollTrustSync.push(entries: plan.entries, client: client)

        #expect(await captured.value == [])
    }

    @Test("push logs and does not throw when the client fails")
    func pushSwallowsClientFailure() async throws {
        let siteDirectory = try Self.makeSiteDirectory()
        defer { try? FileManager.default.removeItem(at: siteDirectory) }
        try Self.writeEntry(name: "alice", url: "https://alice.example/", in: siteDirectory)
        let plan = BlogrollPlan.build(projectRoot: siteDirectory)
        let client = BlogrollTrustKVClient(
            accountID: "acct1", namespaceID: "ns1", apiToken: "token",
            transport: { _ in (Data(), Self.response(500)) })

        await BlogrollTrustSync.push(entries: plan.entries, client: client)
    }

    @Test("pushIfConfigured no-ops (no network call) when SOCIAL_KV has not been provisioned")
    func noOpsWithoutKVNamespace() async throws {
        let siteDirectory = try Self.makeSiteDirectory()
        defer { try? FileManager.default.removeItem(at: siteDirectory) }
        let configDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blogroll-trust-sync-config-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: configDir) }

        await BlogrollTrustSync.pushIfConfigured(
            siteDirectory: siteDirectory,
            configDirectory: configDir,
            secretStore: InMemorySecretStore(token: "unused"),
            transport: { _ in
                Issue.record("transport must not be called with no provisioned SOCIAL_KV namespace")
                struct UnexpectedNetworkCall: Error {}
                throw UnexpectedNetworkCall()
            })
    }

    @Test("pushIfConfigured resolves the account id and pushes the current blogroll domains")
    func resolvesAccountAndPushes() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimClear()
        defer { cfToken.release() }
        let siteDirectory = try Self.makeSiteDirectory()
        defer { try? FileManager.default.removeItem(at: siteDirectory) }
        try Self.writeEntry(name: "alice", url: "https://alice.example/", in: siteDirectory)
        let configDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blogroll-trust-sync-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: configDir) }
        try await SiteConfigStore(configDirectory: configDir).save(
            SiteSettings(provisionedWorkerResources: .init(kvNamespaceID: "ns1")))

        let accountsBody = Data("""
        {"success": true, "result": [{"id": "acct1"}]}
        """.utf8)
        let capturedPUT = CapturedURLs()

        await BlogrollTrustSync.pushIfConfigured(
            siteDirectory: siteDirectory,
            configDirectory: configDir,
            secretStore: InMemorySecretStore(token: "token"),
            transport: { request in
                if request.url!.path.hasSuffix("/accounts") { return (accountsBody, Self.response(200)) }
                if request.url!.path.hasSuffix("/values/vouch:trusted-domains") {
                    if let body = request.httpBody, let domains = try? JSONDecoder().decode([String].self, from: body) {
                        await capturedPUT.set(domains)
                    }
                    return (Data(), Self.response(200))
                }
                return (Data(), Self.response(404))
            })

        #expect(await capturedPUT.value == ["alice.example"])
    }
}

private actor CapturedURLs {
    private(set) var value: [String]?
    func set(_ urls: [String]) { value = urls }
}
