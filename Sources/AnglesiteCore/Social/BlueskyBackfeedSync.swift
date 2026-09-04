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

    /// Maps one flattened reply to the git-canonical schema. `nil` when `ReceivedInteraction`'s
    /// own path-traversal guard rejects the derived id (not expected for a real AT-proto rkey,
    /// but mirrors `ReceivedInteractionSync.makeInteraction`'s `try?` rather than trusting the
    /// upstream shape unconditionally), or when `urlBuilder` can't turn `authorHandle`/`rkey`
    /// (untrusted AppView JSON) into a `URL` — skip this one reply rather than trap the process
    /// on a force-unwrap, matching `BlueskyPOSSEClient.publicURL`'s guarded sibling in
    /// `POSSEClients.swift`. `urlBuilder` defaults to `URL.init(string:)`; tests inject a
    /// failing builder to exercise the guard without depending on Foundation ever actually
    /// rejecting a given string.
    static func makeInteraction(
        from reply: BlueskyThreadClient.RawReply, target: URL, now: Date,
        urlBuilder: (String) -> URL? = { URL(string: $0) }
    ) -> ReceivedInteraction? {
        guard let source = urlBuilder("https://bsky.app/profile/\(reply.authorHandle)/post/\(reply.rkey)") else { return nil }
        return try? ReceivedInteraction(
            id: "bsky-\(reply.rkey)", type: .bluesky,
            source: source,
            target: target, interactionType: .reply,
            author: .init(
                name: reply.authorName, url: urlBuilder("https://bsky.app/profile/\(reply.authorHandle)"),
                photo: reply.authorPhoto),
            content: String(reply.text.prefix(500)),
            published: reply.createdAt, verified: now, verificationStatus: .verified)
    }

    /// Maps one like/repost. Bluesky has no distinct per-like/-repost resource URL (unlike a
    /// webmention `like-of`/`repost-of` post) — the interaction *is* the actor's relationship to
    /// the target post, so `source` and `author.url` both fall back to the actor's own profile.
    /// `id` folds in `targetRkey` so the same actor liking two different tracked posts can't
    /// collide (`POSSEStableKey.make` already produces a `[0-9a-f]+` hash, a safe subset of the id
    /// charset). `nil` when `urlBuilder` can't turn `actorHandle` into a `URL` — see the reply
    /// overload's doc for why this guards instead of force-unwrapping.
    static func makeInteraction(
        from event: BlueskyThreadClient.RawActorEvent, interactionType: ReceivedInteraction.InteractionType,
        targetRkey: String, target: URL, now: Date,
        urlBuilder: (String) -> URL? = { URL(string: $0) }
    ) -> ReceivedInteraction? {
        let kind = interactionType == .like ? "like" : "repost"
        guard let profileURL = urlBuilder("https://bsky.app/profile/\(event.actorHandle)") else { return nil }
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

    /// Carries `existing`'s `verified` (and, for reposts with no upstream timestamp, `published`)
    /// forward onto `interaction` when nothing else about it changed, so a sync that finds no
    /// real upstream change writes nothing. Without this, `verified: now` (stamped fresh on every
    /// `makeInteraction` call, per site-open) would make every snapshot byte-different from what's
    /// on disk every time, defeating `ReceivedInteractionCommitter.commit`'s byte-identical no-op
    /// check and producing a spurious commit on every site-open forever (#1236 review finding 1).
    /// Reads `siteDirectory/data/interactions/<id>.json` directly — the reuse decision has to
    /// happen before `commit`'s own byte-identical check ever sees the candidate data, since that
    /// check compares against what THIS call is about to write, not what varies within it.
    private static func stabilized(_ interaction: ReceivedInteraction, siteDirectory: URL, fileManager: FileManager) -> ReceivedInteraction {
        guard let data = fileManager.contents(atPath: siteDirectory.appendingPathComponent(interaction.gitPath).path)
        else { return interaction }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let existing = try? decoder.decode(ReceivedInteraction.self, from: data),
              let reusingExistingTimestamps = try? ReceivedInteraction(
                  id: interaction.id, type: interaction.type, source: interaction.source, target: interaction.target,
                  interactionType: interaction.interactionType, author: interaction.author, content: interaction.content,
                  published: existing.published, verified: existing.verified, verificationStatus: interaction.verificationStatus),
              reusingExistingTimestamps == existing
        else { return interaction }
        return reusingExistingTimestamps
    }

    /// Reads whatever bluesky-sourced snapshots already exist on disk for `entry`'s target.
    /// `pullAndCommit` calls this only for an entry whose fetch hard-failed this round, so the
    /// committer's scoped reconcile still sees these ids as "current" and doesn't delete them —
    /// without this, a post whose fetch failed would drop out of the fresh set entirely and the
    /// scoped reconcile would read that absence as "no longer present, delete" (#1236 review
    /// finding 3).
    private static func existingSnapshots(
        for entry: POSSESyndicationLog.Entry, siteDirectory: URL, fileManager: FileManager
    ) -> [ReceivedInteraction] {
        let dir = siteDirectory.appendingPathComponent("data/interactions", isDirectory: true)
        guard let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files.compactMap { file -> ReceivedInteraction? in
            guard file.pathExtension == "json", let data = fileManager.contents(atPath: file.path),
                  let interaction = try? decoder.decode(ReceivedInteraction.self, from: data),
                  interaction.type == .bluesky, interaction.target == entry.canonicalURL
            else { return nil }
            return interaction
        }
    }

    /// Pulls every Bluesky-syndicated entry's replies/likes/reposts and reconciles them into
    /// `siteDirectory`. Returns 0 (never throws) if `ledger` has no `"bluesky"` entries. A
    /// transient failure on one tracked post's fetch no longer aborts the whole pass (#1236
    /// review finding 3): that entry is skipped for this round — contributing no new
    /// interactions, but also not losing whatever snapshots it already has on disk (see
    /// `existingSnapshots`) — while every other entry still fetches and commits normally. The
    /// return value is the number of ids actually written or deleted this round (from entries
    /// that succeeded); an entry whose fetch failed contributes nothing to that count either way,
    /// since its on-disk files are carried forward unchanged.
    public static func pullAndCommit(
        ledger: POSSESyndicationLog, siteDirectory: URL,
        transport: BlueskyThreadClient.Transport = BlueskyThreadClient.defaultTransport,
        now: Date = Date(), fileManager: FileManager = .default
    ) async -> Int {
        let entries = ledger.entries.filter { $0.platform == "bluesky" }
        guard !entries.isEmpty else { return 0 }

        var all: [ReceivedInteraction] = []
        for entry in entries {
            if let interactions = await Self.interactions(for: entry, transport: transport, now: now) {
                all.append(contentsOf: interactions.map { Self.stabilized($0, siteDirectory: siteDirectory, fileManager: fileManager) })
            } else {
                all.append(contentsOf: Self.existingSnapshots(for: entry, siteDirectory: siteDirectory, fileManager: fileManager))
            }
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
