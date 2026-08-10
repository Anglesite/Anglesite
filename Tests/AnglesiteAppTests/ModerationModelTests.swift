// Tests/AnglesiteAppTests/ModerationModelTests.swift
import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteAppCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("ModerationModel")
@MainActor
struct ModerationModelTests {
    final class InMemorySecretStore: SecretStore, @unchecked Sendable {
        var values: [String: String] = [:]
        func read(account: String) throws -> String? { values[account] }
        func write(_ value: String, account: String) throws { values[account] = value }
        func delete(account: String) throws { values.removeValue(forKey: account) }
    }

    private static func site(configDirectory: URL, sourceDirectory: URL) -> CurrentSite {
        CurrentSite(
            id: "site-1", name: "Test Community",
            packageURL: sourceDirectory.deletingLastPathComponent(),
            sourceDirectory: sourceDirectory, configDirectory: configDirectory)
    }

    /// Mirrors `CommunitiesModelTests.makeSiteDirectories(domain:)` — a fixture site with a
    /// public URL (so `DeployCoordinator.resolveSiteURL` resolves) and one member snapshot file.
    private static func makeSiteDirectories() throws -> (config: URL, source: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("moderation-model-test-\(UUID().uuidString)")
        let config = root.appendingPathComponent("Config")
        let source = root.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "DOMAIN=my-community.example\n".write(
            to: source.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)
        let member = try CommunityMember(
            id: "abc123", actorURL: URL(string: "https://lemmy.ml/u/spammer")!, name: "Spammer", photo: nil)
        let memberPath = source.appendingPathComponent(member.gitPath)
        try FileManager.default.createDirectory(at: memberPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(member).write(to: memberPath)
        return (config, source)
    }

    @Test("banning a member POSTs Remove and drops them from the visible list")
    func banRemovesMember() async throws {
        let (config, source) = try Self.makeSiteDirectories()
        defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }
        let secretStore = InMemorySecretStore()
        secretStore.values[SecretAccounts.activityPubPublishToken(siteID: "site-1")] = "token"
        actor Recorder {
            private(set) var bodies: [[String: Any]] = []
            func record(_ body: [String: Any]) { bodies.append(body) }
        }
        let recorder = Recorder()

        let model = ModerationModel(secretStore: secretStore, membershipTransport: { request in
            if let data = request.httpBody, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                await recorder.record(json)
            }
            let http = HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!
            return (Data("{}".utf8), http)
        })
        model.configure(site: Self.site(configDirectory: config, sourceDirectory: source))

        #expect(model.members.count == 1)
        try await model.ban(model.members[0])

        let body = await recorder.bodies.first
        #expect(body?["type"] as? String == "Remove")
        #expect(body?["object"] as? String == "https://lemmy.ml/u/spammer")
        #expect(model.members.isEmpty)
    }
}
