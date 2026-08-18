import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Orchestrates #1236's "pull the Bluesky replies/likes/reposts of every POSSE'd post and snapshot
/// them into the site's git working copy" step, mirroring `ReceivedInteractionSync`'s shape but
/// reading `POSSESyndicationLog` (the local POSSE ledger) instead of a Worker's D1 database — no
/// Cloudflare token or provisioned Worker resource is needed, since Bluesky's `getPostThread`/
/// `getLikes`/`getRepostedBy` are public, unauthenticated AppView endpoints (same trust posture as
/// `AnnouncedPostSync`'s outbox fetch). Designed to be called once per site-open
/// (`PreviewModel.open(site:)`), alongside the other per-site syncs.
///
/// See `docs/superpowers/specs/2026-08-17-bluesky-replies-comment-section-design.md` for the full
/// design, including why `ReceivedInteractionCommitter.commit` needed a `scopedTo` parameter for
/// this to share `data/interactions/` safely with `ReceivedInteractionSync`.
public enum BlueskyBackfeedSync {
    /// Derives the `at://` URI (and the post's own rkey) `BlueskyThreadClient` needs from a
    /// `POSSESyndicationLog.Entry.syndicationURL` — the Bluesky permalink
    /// `https://bsky.app/profile/<handle>/post/<rkey>` `BlueskyPOSSEClient.publicURL` produces
    /// (`Sources/AnglesiteCore/POSSEClients.swift`). `nil` for anything not shaped like that
    /// permalink — the entry is simply skipped rather than guessed at.
    static func atURI(from syndicationURL: URL) -> (uri: String, rkey: String)? {
        let components = syndicationURL.pathComponents
        guard components.count == 5, components[1] == "profile", components[3] == "post" else { return nil }
        return ("at://\(components[2])/app.bsky.feed.post/\(components[4])", components[4])
    }

    /// Maps one flattened reply to the git-canonical schema. `nil` only when
    /// `ReceivedInteraction`'s own path-traversal guard rejects the derived id — not expected for
    /// a real AT-proto rkey, but mirrors `ReceivedInteractionSync.makeInteraction`'s `try?` rather
    /// than trusting the upstream shape unconditionally.
    static func makeInteraction(from reply: BlueskyThreadClient.RawReply, target: URL, now: Date) -> ReceivedInteraction? {
        try? ReceivedInteraction(
            id: "bsky-\(reply.rkey)", type: .bluesky,
            source: URL(string: "https://bsky.app/profile/\(reply.authorHandle)/post/\(reply.rkey)")!,
            target: target, interactionType: .reply,
            author: .init(
                name: reply.authorName, url: URL(string: "https://bsky.app/profile/\(reply.authorHandle)"),
                photo: reply.authorPhoto),
            content: String(reply.text.prefix(500)),
            published: reply.createdAt, verified: now, verificationStatus: .verified)
    }

    /// Maps one like/repost. Bluesky has no distinct per-like/-repost resource URL (unlike a
    /// webmention `like-of`/`repost-of` post) — the interaction *is* the actor's relationship to
    /// the target post, so `source` and `author.url` both fall back to the actor's own profile.
    /// `id` folds in `targetRkey` so the same actor liking two different tracked posts can't
    /// collide (`POSSEStableKey.make` already produces a `[0-9a-f]+` hash, a safe subset of the id
    /// charset).
    static func makeInteraction(
        from event: BlueskyThreadClient.RawActorEvent, interactionType: ReceivedInteraction.InteractionType,
        targetRkey: String, target: URL, now: Date
    ) -> ReceivedInteraction? {
        let kind = interactionType == .like ? "like" : "repost"
        let profileURL = URL(string: "https://bsky.app/profile/\(event.actorHandle)")!
        return try? ReceivedInteraction(
            id: "bsky-\(kind)-" + POSSEStableKey.make("\(targetRkey)\n\(event.actorDID)"), type: .bluesky,
            source: profileURL, target: target, interactionType: interactionType,
            author: .init(name: event.actorName, url: profileURL, photo: event.actorPhoto),
            content: nil, published: event.createdAt ?? now, verified: now, verificationStatus: .verified)
    }

    /// One tracked post's full result set, or `nil` if any of its three fetches hard-failed.
    private static func interactions(
        for entry: POSSESyndicationLog.Entry, transport: BlueskyThreadClient.Transport, now: Date
    ) async -> [ReceivedInteraction]? {
        guard let (atURI, rkey) = Self.atURI(from: entry.syndicationURL) else { return [] }
        async let repliesTask = BlueskyThreadClient.fetchReplies(atURI: atURI, transport: transport)
        async let likesTask = BlueskyThreadClient.fetchLikes(atURI: atURI, transport: transport)
        async let repostsTask = BlueskyThreadClient.fetchReposts(atURI: atURI, transport: transport)
        guard let replies = await repliesTask, let likes = await likesTask, let reposts = await repostsTask
        else { return nil }

        var out: [ReceivedInteraction] = []
        out.append(contentsOf: replies.compactMap { Self.makeInteraction(from: $0, target: entry.canonicalURL, now: now) })
        out.append(contentsOf: likes.compactMap {
            Self.makeInteraction(from: $0, interactionType: .like, targetRkey: rkey, target: entry.canonicalURL, now: now)
        })
        out.append(contentsOf: reposts.compactMap {
            Self.makeInteraction(from: $0, interactionType: .repost, targetRkey: rkey, target: entry.canonicalURL, now: now)
        })
        return out
    }

    /// Pulls every Bluesky-syndicated entry's replies/likes/reposts and reconciles them into
    /// `siteDirectory`. Returns 0 (never throws, never partially reconciles) if `ledger` has no
    /// `"bluesky"` entries, or if *any* tracked post's fetch hard-fails — a transient failure on
    /// one post must not be misread as "this post now has zero replies" and wipe its real,
    /// previously-fetched snapshots (see the design doc's failure-handling section).
    public static func pullAndCommit(
        ledger: POSSESyndicationLog, siteDirectory: URL,
        transport: BlueskyThreadClient.Transport = BlueskyThreadClient.defaultTransport,
        now: Date = Date()
    ) async -> Int {
        let entries = ledger.entries.filter { $0.platform == "bluesky" }
        guard !entries.isEmpty else { return 0 }

        var all: [ReceivedInteraction] = []
        for entry in entries {
            guard let interactions = await Self.interactions(for: entry, transport: transport, now: now) else { return 0 }
            all.append(contentsOf: interactions)
        }
        let committedIDs = await ReceivedInteractionCommitter.commit(interactions: all, scopedTo: [.bluesky], into: siteDirectory)
        return committedIDs.count
    }

    /// Reads the site's POSSE ledger from `configDirectory`; no-ops (returns 0, no network call)
    /// when the site has never syndicated to Bluesky. `configDirectory` is the package's `Config/`
    /// directory (`AnglesitePackage.configURL`), a sibling of `siteDirectory`
    /// (`AnglesitePackage.sourceURL`).
    public static func pullAndCommitIfConfigured(
        siteDirectory: URL, configDirectory: URL,
        transport: BlueskyThreadClient.Transport = BlueskyThreadClient.defaultTransport
    ) async -> Int {
        guard let ledger = POSSESyndicationLog.load(from: configDirectory) else { return 0 }
        return await pullAndCommit(ledger: ledger, siteDirectory: siteDirectory, transport: transport)
    }
}
