import Foundation
import Observation
import AnglesiteCore

/// Backs the Moderation section (V-5.1b/V-5.3, #907/#370, design doc §5): moderator-list
/// display, ban/remove actions over this site's own `CommunityMember`/`AnnouncedPost` snapshot
/// files, and the approval queue (design doc D4, unblocked by `davidwkeith/workers` PR #488).
/// App glue only, mirroring `CommunitiesModel`'s shape — protocol logic (`Remove`/`Accept`/the
/// `follow_requests` listing) lives in `AnglesiteCore`'s `CommunityMembershipClient`.
/// Report-review remains explicitly out of scope (design doc D5) — no state for it here.
@MainActor
@Observable
final class ModerationModel {
    private(set) var members: [CommunityMember] = []
    /// Members banned this session (#1742), kept so the Moderation UI has something to show an
    /// "Unban" action against. Not persisted: a banned member's snapshot file is deleted from
    /// `Source/` on the next `CommunityMembersSync` reconcile (see the type-level doc), so there
    /// is nothing on disk to reload this from after the window closes — same as `members`/`posts`,
    /// this is only ever populated by ``ban(_:)`` running in the current session, and
    /// ``reload()`` reconciles it against whatever the snapshot scan just found.
    private(set) var bannedMembers: [CommunityMember] = []
    private(set) var posts: [AnnouncedPost] = []
    private(set) var moderators: [String] = []
    private(set) var pendingFollowers: [PendingFollower] = []
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
    /// list plus every member/post snapshot once, at site open — plus one best-effort network
    /// fetch of pending follow requests (see ``loadPendingFollowers()``, which never blocks this
    /// on failure). Unlike `CommunitiesModel.configure(site:)` this is called unconditionally
    /// for *every* site
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

    /// Re-reads the moderator list plus every member/post snapshot from disk, and re-fetches the
    /// pending-follow-request list from this site's own Worker (``loadPendingFollowers()``).
    /// No-ops until ``configure(site:)`` has run at least once (no `sourceDirectory`/
    /// `configDirectory` to read yet). Split out of ``configure(site:)`` so
    /// `SiteWindowModel.presentModeration()` can call it on every presentation, not just once at
    /// site open — see that method's doc comment for why a single load isn't enough.
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
        async let loadedPending = loadPendingFollowers()
        moderators = settings.moderators ?? []
        members = await loadedMembers
        posts = await loadedPosts
        pendingFollowers = await loadedPending
        // A member banned in-app and then restored some other way (direct Worker/git access,
        // another Anglesite session) would otherwise show up in both lists at once.
        let currentMemberIDs = Set(members.map(\.id))
        bannedMembers.removeAll { currentMemberIDs.contains($0.id) }
    }

    /// Fetches pending join requests from this site's own Worker
    /// (`CommunityMembershipClient.listFollowRequests()`). A 404 fails silently to an empty list
    /// — same "a bad read must never make the pane unusable" philosophy ``decodeAll(_:from:)``
    /// follows for member/post snapshots — because the underlying `GET <actor>/follow_requests`
    /// route (`davidwkeith/workers` PR #488) postdates the latest tagged `@dwk/workers` release
    /// as of this writing: a deployed community's Worker will 404 until it redeploys against a
    /// newer one, and that expected 404 must never pop a blocking alert on every pane open. Any
    /// other failure (an expired/revoked `publishToken`, a genuinely broken deploy) surfaces via
    /// `errorMessage`, same as ``ban(_:)``/``removePost(_:)`` — swallowing *every* failure would
    /// make a real regression on this endpoint invisible to the owner indefinitely. No-ops
    /// (returns `[]`) until `ownActorURL`/`publishToken` are both available, same guard
    /// ``ban(_:)``/``removePost(_:)`` use.
    private func loadPendingFollowers() async -> [PendingFollower] {
        guard let ownActorURL, let publishToken else { return [] }
        let client = CommunityMembershipClient(ownActorURL: ownActorURL, publishToken: publishToken, transport: membershipTransport)
        do {
            return try await client.listFollowRequests()
        } catch CommunityMembershipError.requestFailed(status: 404, body: _) {
            return []
        } catch {
            errorMessage = "Couldn't load pending join requests: \(error.localizedDescription)"
            return []
        }
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
            errorMessage = "This site has no known public URL yet — publish it at least once first."
            return
        }
        let client = CommunityMembershipClient(ownActorURL: ownActorURL, publishToken: publishToken, transport: membershipTransport)
        try await client.remove(target: member.actorURL)
        members.removeAll { $0.id == member.id }
        bannedMembers.append(member)
    }

    func confirmBan() async {
        guard let member = banConfirmation else { return }
        banConfirmation = nil
        do { try await ban(member) }
        catch { errorMessage = "Couldn't ban \(member.name ?? member.actorURL.absoluteString): \(error.localizedDescription)" }
    }

    /// Reverses a ban (#1742) — posts `Add` (``CommunityMembershipClient/add(target:)``, the AS2
    /// inverse of the `Remove` ``ban(_:)`` sends) and moves the member back from
    /// ``bannedMembers`` to ``members``. No confirmation dialog: same "not destructive, and a bad
    /// call is reversible via the existing ban action" rationale ``approve(_:)`` and
    /// ``addModerator(_:)`` already use.
    func unban(_ member: CommunityMember) async {
        guard let ownActorURL, let publishToken else {
            errorMessage = "This site has no known public URL yet — publish it at least once first."
            return
        }
        let client = CommunityMembershipClient(ownActorURL: ownActorURL, publishToken: publishToken, transport: membershipTransport)
        do {
            try await client.add(target: member.actorURL)
            bannedMembers.removeAll { $0.id == member.id }
            members.append(member)
        } catch {
            errorMessage = "Couldn't unban \(member.name ?? member.actorURL.absoluteString): \(error.localizedDescription)"
        }
    }

    /// Confirms a pending join request. No confirmation dialog (unlike ``ban(_:)``/
    /// ``removePost(_:)``) — admitting a member isn't destructive; a bad admit is reversible via
    /// the existing ``ban(_:)`` action, so this mirrors ``addModerator(_:)``'s no-confirmation
    /// precedent.
    func approve(_ follower: PendingFollower) async {
        guard let ownActorURL, let publishToken else {
            errorMessage = "This site has no known public URL yet — publish it at least once first."
            return
        }
        let client = CommunityMembershipClient(ownActorURL: ownActorURL, publishToken: publishToken, transport: membershipTransport)
        do {
            try await client.acceptFollow(target: follower.actor)
            pendingFollowers.removeAll { $0.id == follower.id }
        } catch {
            errorMessage = "Couldn't approve \(follower.actor.absoluteString): \(error.localizedDescription)"
        }
    }

    func removePost(_ post: AnnouncedPost) async throws {
        guard let ownActorURL, let publishToken else {
            errorMessage = "This site has no known public URL yet — publish it at least once first."
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

    /// Validates and appends an actor IRI to `SiteSettings.moderators`, persisting via
    /// `SiteConfigStore` (design doc §5 — "Moderators — list of actor IRIs from
    /// `SiteSettings.moderators`, add/remove"; #1263 final review finding 5: this list was
    /// previously read-only, so it could never actually be populated in production). Same
    /// well-formed-URL check `CommunityActorResolver.resolve` uses for a pasted actor IRI: must
    /// parse as a URL with an `http`/`https` scheme and a host — a low-stakes, owner-only, local
    /// config list, so no confirmation dialog (unlike ban/remove, which reach the network).
    /// Returns whether the IRI was accepted (valid and, after any dedup, actually persisted) —
    /// the view uses this to decide whether to clear the text field, so a rejected/invalid entry
    /// stays put for the owner to fix instead of silently vanishing.
    @discardableResult
    func addModerator(_ iri: String) async -> Bool {
        let trimmed = iri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme, url.host != nil,
            ["http", "https"].contains(scheme.lowercased())
        else {
            errorMessage = "Enter a valid actor URL, e.g. https://example.social/users/alice."
            return false
        }
        guard let configDirectory else { return false }
        let store = SiteConfigStore(configDirectory: configDirectory)
        var settings = (try? await store.load()) ?? SiteSettings()
        var updated = settings.moderators ?? []
        guard !updated.contains(trimmed) else { return true }
        updated.append(trimmed)
        settings.moderators = updated
        do {
            try await store.save(settings)
            moderators = updated
            return true
        } catch {
            errorMessage = "Couldn't save the moderator: \(error.localizedDescription)"
            return false
        }
    }

    /// Removes an actor IRI from `SiteSettings.moderators`. Counterpart to ``addModerator(_:)`` —
    /// same no-confirmation-dialog rationale.
    func removeModerator(_ iri: String) async {
        guard let configDirectory else { return }
        let store = SiteConfigStore(configDirectory: configDirectory)
        var settings = (try? await store.load()) ?? SiteSettings()
        var updated = settings.moderators ?? []
        updated.removeAll { $0 == iri }
        settings.moderators = updated
        do {
            try await store.save(settings)
            moderators = updated
        } catch {
            errorMessage = "Couldn't remove the moderator: \(error.localizedDescription)"
        }
    }
}
