import Foundation
import Observation
import AnglesiteCore

/// Backs the Moderation section (V-5.1b/V-5.3, #907/#370, design doc §5): moderator-list
/// display, and ban/remove actions over this site's own `CommunityMember`/`AnnouncedPost`
/// snapshot files. App glue only, mirroring `CommunitiesModel`'s shape — protocol logic
/// (`Remove`) lives in `AnglesiteCore`'s `CommunityMembershipClient`. Approval-queue and
/// report-review are explicitly out of scope (design doc D4/D5) — no state for either here.
@MainActor
@Observable
final class ModerationModel {
    private(set) var members: [CommunityMember] = []
    private(set) var posts: [AnnouncedPost] = []
    private(set) var moderators: [String] = []
    var errorMessage: String?
    /// Cleared by whichever confirmation-dialog button runs — same no-op-setter/
    /// clear-in-button-action contract `SiteWindow.swift:898-916`'s delete confirmation uses
    /// (#968/#969), and `CommunitiesModel.leaveConfirmation`'s sibling pattern.
    var banConfirmation: CommunityMember?
    var removeConfirmation: AnnouncedPost?

    private var siteID: String?
    private var sourceDirectory: URL?
    private var configDirectory: URL?
    private var ownActorURL: URL?
    private let secretStore: any SecretStore
    private let membershipTransport: CommunityMembershipClient.Transport

    init(
        secretStore: any SecretStore = PlatformSecretStore.make(),
        membershipTransport: @escaping CommunityMembershipClient.Transport
            = CommunityMembershipClient.defaultTransport
    ) {
        self.secretStore = secretStore
        self.membershipTransport = membershipTransport
    }

    /// Records which site this pane talks to, resolves `ownActorURL`, and loads the moderator
    /// list plus every member/post snapshot once, at site open. No network I/O. Unlike
    /// `CommunitiesModel.configure(site:)` this is called unconditionally for *every* site
    /// (including a plain personal one, not just once `canOpenModeration` is already true) —
    /// Moderation has no `.noSiteURL`-retry surface of its own, so there's nothing here to gate.
    /// This only loads once: the member/post snapshot files are written later, by
    /// `CommunityMembersSync`/`AnnouncedPostSync` running from `PreviewModel` after the dev
    /// server starts, so this alone would show a stale (often empty) list for the rest of the
    /// window session — ``reload()`` is what `SiteWindowModel.presentModeration()` calls on every
    /// presentation to pick up whatever's landed since.
    func configure(site: CurrentSite) async {
        siteID = site.id
        sourceDirectory = site.sourceDirectory
        configDirectory = site.configDirectory
        if let siteURLString = DeployCoordinator.resolveSiteURL(siteDirectory: site.sourceDirectory),
           let siteURL = URL(string: siteURLString) {
            ownActorURL = ActivityPubActor.actorURL(siteURL: siteURL)
        }
        await reload()
    }

    /// Re-reads the moderator list plus every member/post snapshot from disk. No-ops until
    /// ``configure(site:)`` has run at least once (no `sourceDirectory`/`configDirectory` to read
    /// yet). Split out of ``configure(site:)`` so `SiteWindowModel.presentModeration()` can call
    /// it on every presentation, not just once at site open — see that method's doc comment for
    /// why a single load isn't enough.
    ///
    /// The settings load and both directory scans all run off the main actor: `Config/` and
    /// `Source/` live inside the `.anglesite` package, whose default home is the iCloud Drive
    /// ubiquity container, so a not-yet-materialized file can block on an iCloud download.
    /// `SiteConfigStore`'s async `load()` is itself an actor method (hops off `@MainActor` on its
    /// own); ``decodeAll(_:from:)`` is `nonisolated` for the same reason — its doc comment has the
    /// detail.
    func reload() async {
        guard let sourceDirectory, let configDirectory else { return }
        let settings = (try? await SiteConfigStore(configDirectory: configDirectory).load()) ?? SiteSettings()
        async let loadedMembers = Self.decodeAll(
            CommunityMember.self, from: sourceDirectory.appendingPathComponent("data/community-members"))
        async let loadedPosts = Self.decodeAll(
            AnnouncedPost.self, from: sourceDirectory.appendingPathComponent("data/community-posts"))
        moderators = settings.moderators ?? []
        members = await loadedMembers
        posts = await loadedPosts
    }

    /// Reads every `.json` file in `directory` and decodes it as `T`, skipping (not throwing on)
    /// any file that fails to decode — a malformed or in-progress-write snapshot must never make
    /// the whole Moderation pane unusable, matching `SiteConfigStore.load()`'s "a bad file falls
    /// back to a safe default" philosophy rather than propagating the failure.
    ///
    /// `nonisolated` — and `async` — so this runs on the global concurrent executor instead of
    /// `ModerationModel`'s `@MainActor` one: a member/post directory can hold many files (each a
    /// synchronous `Data(contentsOf:)` read), and doing that scan-and-decode pass on the main
    /// thread would block the UI for however long disk (or, for an un-materialized iCloud file,
    /// a download) takes. `reload()` awaits this and assigns the result back on the actor.
    nonisolated private static func decodeAll<T: Decodable>(_ type: T.Type, from directory: URL) async -> [T] {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries.filter { $0.pathExtension == "json" }.compactMap { url in
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
        }
    }

    private var publishToken: String? {
        guard let siteID else { return nil }
        return try? secretStore.read(account: SecretAccounts.activityPubPublishToken(siteID: siteID))
    }

    func ban(_ member: CommunityMember) async throws {
        guard let ownActorURL, let publishToken else {
            errorMessage = "This site has no known public URL yet — deploy it at least once first."
            return
        }
        let client = CommunityMembershipClient(ownActorURL: ownActorURL, publishToken: publishToken, transport: membershipTransport)
        try await client.remove(target: member.actorURL)
        members.removeAll { $0.id == member.id }
    }

    func confirmBan() async {
        guard let member = banConfirmation else { return }
        banConfirmation = nil
        do { try await ban(member) }
        catch { errorMessage = "Couldn't ban \(member.name ?? member.actorURL.absoluteString): \(error.localizedDescription)" }
    }

    func removePost(_ post: AnnouncedPost) async throws {
        guard let ownActorURL, let publishToken else {
            errorMessage = "This site has no known public URL yet — deploy it at least once first."
            return
        }
        let client = CommunityMembershipClient(ownActorURL: ownActorURL, publishToken: publishToken, transport: membershipTransport)
        try await client.remove(target: post.sourceURL)
        posts.removeAll { $0.id == post.id }
        // Deletes the local snapshot file too, mirroring the C.3 deletion flow
        // (docs/specs/2026-06-29-c3-received-interaction-canonicality.md's "owner deletes the
        // JSON file from their repo" convention) — the Worker's `Remove` above handles the
        // federation side (un-announce), this handles the git side, so the post disappears from
        // the rebuilt timeline on the next deploy without waiting for a full-set reconcile.
        if let sourceDirectory {
            try? FileManager.default.removeItem(at: sourceDirectory.appendingPathComponent(post.gitPath))
        }
    }

    func confirmRemove() async {
        guard let post = removeConfirmation else { return }
        removeConfirmation = nil
        do { try await removePost(post) }
        catch { errorMessage = "Couldn't remove this post: \(error.localizedDescription)" }
    }
}
