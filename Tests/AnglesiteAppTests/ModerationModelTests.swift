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

    /// Captures the JSON bodies of every POST a test's `membershipTransport` sees, so a test can
    /// assert on the activity shape (`type`/`object`) sent to the Worker. Shared by
    /// `banRemovesMember()` and `approveAcceptsAndRemovesFromPendingList()` — hoisted out of both
    /// to a single definition instead of each declaring its own local copy.
    private actor Recorder {
        private(set) var bodies: [[String: Any]] = []
        func record(_ body: [String: Any]) { bodies.append(body) }
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
        let recorder = Recorder()

        let model = ModerationModel(secretStore: secretStore, membershipTransport: { request in
            if let data = request.httpBody, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                await recorder.record(json)
            }
            let http = HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!
            return (Data("{}".utf8), http)
        })
        await model.configure(site: Self.site(configDirectory: config, sourceDirectory: source))

        #expect(model.members.count == 1)
        try await model.ban(model.members[0])

        let body = await recorder.bodies.first
        #expect(body?["type"] as? String == "Remove")
        #expect(body?["object"] as? String == "https://lemmy.ml/u/spammer")
        #expect(model.members.isEmpty)
        #expect(model.bannedMembers.map(\.id) == ["abc123"])
    }

    /// #1742: unban is the recovery path that lets the Ban confirmation dialog use the same
    /// action-default keyboard shape as the other eight destructive confirmations. Confirms it
    /// POSTs the AS2 inverse of ban's `Remove` and moves the member back to the visible list.
    @Test("unbanning a member POSTs Add and moves them back from banned to visible")
    func unbanRestoresMember() async throws {
        let (config, source) = try Self.makeSiteDirectories()
        defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }
        let secretStore = InMemorySecretStore()
        secretStore.values[SecretAccounts.activityPubPublishToken(siteID: "site-1")] = "token"
        let recorder = Recorder()

        let model = ModerationModel(secretStore: secretStore, membershipTransport: { request in
            if let data = request.httpBody, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                await recorder.record(json)
            }
            let http = HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!
            return (Data("{}".utf8), http)
        })
        await model.configure(site: Self.site(configDirectory: config, sourceDirectory: source))
        let member = model.members[0]
        try await model.ban(member)
        #expect(model.bannedMembers.count == 1)

        await model.unban(member)

        let body = await recorder.bodies.last
        #expect(body?["type"] as? String == "Add")
        #expect(body?["object"] as? String == "https://lemmy.ml/u/spammer")
        #expect(model.bannedMembers.isEmpty)
        #expect(model.members.map(\.id) == ["abc123"])
    }

    /// A failed unban (e.g. a genuinely broken deploy) must leave the member in `bannedMembers`
    /// rather than silently dropping them from both lists — same leave-state-untouched-on-failure
    /// contract ``approve(_:)`` follows. The `Remove` POST that puts the member into
    /// `bannedMembers` in the first place must still succeed, so the stub only fails `Add`.
    @Test("a failed unban sets errorMessage and leaves the member in bannedMembers")
    func unbanFailureSetsErrorMessage() async throws {
        let (config, source) = try Self.makeSiteDirectories()
        defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }
        let secretStore = InMemorySecretStore()
        secretStore.values[SecretAccounts.activityPubPublishToken(siteID: "site-1")] = "token"

        let model = ModerationModel(secretStore: secretStore, membershipTransport: { request in
            let isAdd: Bool
            if let data = request.httpBody, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                isAdd = (json["type"] as? String) == "Add"
            } else {
                isAdd = false
            }
            let http = HTTPURLResponse(
                url: request.url!, statusCode: isAdd ? 500 : 202, httpVersion: nil, headerFields: nil)!
            return (Data(isAdd ? "server error".utf8 : "{}".utf8), http)
        })
        await model.configure(site: Self.site(configDirectory: config, sourceDirectory: source))
        let member = model.members[0]
        try await model.ban(member)
        #expect(model.bannedMembers.count == 1)

        await model.unban(member)

        #expect(model.errorMessage != nil)
        #expect(model.bannedMembers.count == 1)
        #expect(model.members.isEmpty)
    }

    /// The sync jobs that write member/post snapshot files (`CommunityMembersSync`/
    /// `AnnouncedPostSync`) run later than `configure(site:)` — from `PreviewModel`, after the dev
    /// server starts — so a site can genuinely go from zero members at `configure(site:)` time to
    /// some the next time the pane is opened. `reload()` (what `SiteWindowModel.presentModeration()`
    /// calls on every presentation) must pick that up without a fresh `configure(site:)`.
    @Test("reload picks up member/post snapshot files written after configure(site:)")
    func reloadPicksUpNewlyWrittenSnapshots() async throws {
        let (config, source) = try Self.makeSiteDirectories()
        defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }
        let secretStore = InMemorySecretStore()

        let model = ModerationModel(secretStore: secretStore, membershipTransport: { request in
            let http = HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!
            return (Data("{}".utf8), http)
        })
        await model.configure(site: Self.site(configDirectory: config, sourceDirectory: source))
        #expect(model.members.count == 1)
        #expect(model.posts.isEmpty)

        // Simulates a sync job landing a new post snapshot after `configure(site:)` already ran.
        let post = try AnnouncedPost(
            id: "post1", objectType: .note, sourceURL: URL(string: "https://member.example/posts/1")!,
            author: nil, content: "Hello, community!", published: Date(), announcedAt: Date())
        let postPath = source.appendingPathComponent(post.gitPath)
        try FileManager.default.createDirectory(at: postPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(post).write(to: postPath)

        await model.reload()

        #expect(model.posts.count == 1)
        #expect(model.posts.first?.id == "post1")
        // The pre-existing member snapshot is still picked up on every reload, not just the first.
        #expect(model.members.count == 1)
    }

    /// #1263 final review finding 5: `SiteSettings.moderators` had no writer anywhere in the
    /// app — the design doc calls for add/remove, but before this fix the list could only ever
    /// be empty in production. Confirms a moderator survives a round trip through
    /// `SiteConfigStore` and that the model's own `moderators` property reflects it immediately.
    @Test("addModerator persists a well-formed actor URL and removeModerator undoes it")
    func addAndRemoveModeratorPersistsViaSiteConfigStore() async throws {
        let (config, source) = try Self.makeSiteDirectories()
        defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }
        let secretStore = InMemorySecretStore()

        let model = ModerationModel(secretStore: secretStore, membershipTransport: { request in
            let http = HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!
            return (Data("{}".utf8), http)
        })
        await model.configure(site: Self.site(configDirectory: config, sourceDirectory: source))
        #expect(model.moderators.isEmpty)

        let added = await model.addModerator("https://mastodon.social/users/alice")
        #expect(added)
        #expect(model.moderators == ["https://mastodon.social/users/alice"])
        let persisted = try await SiteConfigStore(configDirectory: config).load()
        #expect(persisted.moderators == ["https://mastodon.social/users/alice"])

        await model.removeModerator("https://mastodon.social/users/alice")
        #expect(model.moderators.isEmpty)
        let persistedAfterRemove = try await SiteConfigStore(configDirectory: config).load()
        #expect(persistedAfterRemove.moderators?.isEmpty ?? true)
    }

    @Test("addModerator rejects a malformed actor URL without persisting it")
    func addModeratorRejectsInvalidURL() async throws {
        let (config, source) = try Self.makeSiteDirectories()
        defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }
        let secretStore = InMemorySecretStore()

        let model = ModerationModel(secretStore: secretStore, membershipTransport: { request in
            let http = HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!
            return (Data("{}".utf8), http)
        })
        await model.configure(site: Self.site(configDirectory: config, sourceDirectory: source))

        let added = await model.addModerator("not a url")
        #expect(!added)
        #expect(model.moderators.isEmpty)
        #expect(model.errorMessage != nil)
    }

    @Test("reload fetches pending follow requests from this site's own actor")
    func reloadLoadsPendingFollowRequests() async throws {
        let (config, source) = try Self.makeSiteDirectories()
        defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }
        let secretStore = InMemorySecretStore()
        secretStore.values[SecretAccounts.activityPubPublishToken(siteID: "site-1")] = "token"

        let model = ModerationModel(secretStore: secretStore, membershipTransport: { request in
            if request.url?.lastPathComponent == "follow_requests" {
                let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (
                    Data(
                        #"{"items":[{"actor":"https://lemmy.ml/u/newmember","addedAt":"2026-08-10T18:28:14.000Z"}],"total":1}"#
                            .utf8), http
                )
            }
            let http = HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!
            return (Data("{}".utf8), http)
        })
        await model.configure(site: Self.site(configDirectory: config, sourceDirectory: source))

        #expect(model.pendingFollowers.count == 1)
        #expect(model.pendingFollowers.first?.actor.absoluteString == "https://lemmy.ml/u/newmember")
    }

    /// The upstream listing endpoint (`davidwkeith/workers` PR #488) postdates the latest tagged
    /// `@dwk/workers` release as of this writing (see the plan's Global Constraints) — a deployed
    /// community's Worker will 404 on this route until it redeploys against a newer release. That
    /// must degrade to an empty list, never a blocking alert.
    @Test("a 404 from follow_requests leaves pendingFollowers empty without surfacing an error")
    func reloadIgnoresFollowRequests404() async throws {
        let (config, source) = try Self.makeSiteDirectories()
        defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }
        let secretStore = InMemorySecretStore()
        secretStore.values[SecretAccounts.activityPubPublishToken(siteID: "site-1")] = "token"

        let model = ModerationModel(secretStore: secretStore, membershipTransport: { request in
            let http = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (Data("Not Found".utf8), http)
        })
        await model.configure(site: Self.site(configDirectory: config, sourceDirectory: source))

        #expect(model.pendingFollowers.isEmpty)
        #expect(model.errorMessage == nil)
    }

    /// Only a 404 is the expected "route not yet released" case (see the test above). Any other
    /// failure — an expired/revoked publish token, a genuinely broken deploy — must surface via
    /// `errorMessage` like `ban(_:)`/`removePost(_:)` do, rather than swallowing it the same way
    /// as the 404 case: silently hiding a real regression on this endpoint would leave the owner
    /// with no signal that requests might be piling up unseen.
    @Test("a non-404 failure from follow_requests surfaces via errorMessage")
    func reloadSurfacesNon404FollowRequestsFailure() async throws {
        let (config, source) = try Self.makeSiteDirectories()
        defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }
        let secretStore = InMemorySecretStore()
        secretStore.values[SecretAccounts.activityPubPublishToken(siteID: "site-1")] = "token"

        let model = ModerationModel(secretStore: secretStore, membershipTransport: { request in
            let http = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (Data("server error".utf8), http)
        })
        await model.configure(site: Self.site(configDirectory: config, sourceDirectory: source))

        #expect(model.pendingFollowers.isEmpty)
        #expect(model.errorMessage != nil)
    }

    @Test("approving a follower POSTs Accept and drops them from the pending list")
    func approveAcceptsAndRemovesFromPendingList() async throws {
        let (config, source) = try Self.makeSiteDirectories()
        defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }
        let secretStore = InMemorySecretStore()
        secretStore.values[SecretAccounts.activityPubPublishToken(siteID: "site-1")] = "token"
        let recorder = Recorder()

        let model = ModerationModel(secretStore: secretStore, membershipTransport: { request in
            if request.url?.lastPathComponent == "follow_requests" {
                let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (
                    Data(
                        #"{"items":[{"actor":"https://lemmy.ml/u/newmember","addedAt":"2026-08-10T18:28:14.000Z"}],"total":1}"#
                            .utf8), http
                )
            }
            if let data = request.httpBody, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                await recorder.record(json)
            }
            let http = HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!
            return (Data("{}".utf8), http)
        })
        await model.configure(site: Self.site(configDirectory: config, sourceDirectory: source))
        #expect(model.pendingFollowers.count == 1)

        await model.approve(model.pendingFollowers[0])

        let body = await recorder.bodies.first
        #expect(body?["type"] as? String == "Accept")
        #expect(body?["object"] as? String == "https://lemmy.ml/u/newmember")
        #expect(model.pendingFollowers.isEmpty)
    }

    @Test("a failed approve sets errorMessage and leaves the follower in the pending list")
    func approveFailureSetsErrorMessage() async throws {
        let (config, source) = try Self.makeSiteDirectories()
        defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }
        let secretStore = InMemorySecretStore()
        secretStore.values[SecretAccounts.activityPubPublishToken(siteID: "site-1")] = "token"

        let model = ModerationModel(secretStore: secretStore, membershipTransport: { request in
            if request.url?.lastPathComponent == "follow_requests" {
                let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (
                    Data(
                        #"{"items":[{"actor":"https://lemmy.ml/u/newmember","addedAt":"2026-08-10T18:28:14.000Z"}],"total":1}"#
                            .utf8), http
                )
            }
            let http = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (Data("forbidden".utf8), http)
        })
        await model.configure(site: Self.site(configDirectory: config, sourceDirectory: source))
        #expect(model.pendingFollowers.count == 1)

        await model.approve(model.pendingFollowers[0])

        #expect(model.errorMessage != nil)
        #expect(model.pendingFollowers.count == 1)
    }
}
