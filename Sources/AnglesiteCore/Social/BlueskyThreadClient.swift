import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Unauthenticated reader for Bluesky's public AppView (#1236): pulls the reply thread, likes,
/// and reposts of a POSSE'd post so `BlueskyBackfeedSync` can snapshot them into
/// `data/interactions/` per the received-interaction canonicality design
/// (`docs/specs/2026-06-29-c3-received-interaction-canonicality.md`). No app password or session
/// is needed — `public.api.bsky.app` serves `getPostThread`/`getLikes`/`getRepostedBy` to anyone,
/// the same trust posture the inline-embed fetch in
/// `Resources/Template/scripts/embeds/adapters.ts` already relies on for Bluesky link cards.
/// See `docs/superpowers/specs/2026-08-17-bluesky-replies-comment-section-design.md`.
public enum BlueskyThreadClient {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    static let timeout: TimeInterval = 10
    static let resourceTimeout: TimeInterval = 20
    /// A thread with many replies (or a heavily-liked post) can be sizeable; generous but bounded
    /// — the same "cap a third-party response, don't trust it blindly" posture
    /// `CappedHTTPTransport`'s other callers (`ActorProfileFetcher`, `AnnouncedPostSync.OutboxClient`) use.
    static let maximumResponseBytes = 4 * 1024 * 1024
    /// How deep into nested replies-to-replies `getPostThread` is asked to walk. Comfortably
    /// beyond any realistic blog-comment thread; deeper nesting is a documented limitation — the
    /// API gives no truncation marker past this depth to detect and log against.
    static let threadDepth = 100

    /// Likes/reposts are paginated 100 at a time, up to this many pages — a generous, fixed cap
    /// rather than trusting a peer-controlled `cursor` chain to terminate, matching
    /// `AnnouncedPostSync.OutboxClient`'s own paging cap.
    static let maximumPages = 20
    static let pageSize = 100

    private static let session = CappedHTTPTransport.session(requestTimeout: timeout, resourceTimeout: resourceTimeout)

    /// Production transport — public so callers (`BlueskyBackfeedSync`, tests) can inject a fake,
    /// matching `AnnouncedPostSync.defaultTransport`'s own rationale.
    public static let defaultTransport: Transport = { request in
        try await CappedHTTPTransport.fetch(
            request, session: session, cap: maximumResponseBytes,
            tooLarge: { _ in URLError(.dataLengthExceedsMaximum) })
    }

    /// One reply flattened out of a `getPostThread` tree, before mapping to `ReceivedInteraction`
    /// (which needs a `target` this client has no reason to know about).
    struct RawReply: Sendable, Equatable {
        let rkey: String
        let authorHandle: String
        let authorName: String?
        let authorPhoto: URL?
        let text: String
        let createdAt: Date
    }

    /// One like or repost, before mapping to `ReceivedInteraction`.
    struct RawActorEvent: Sendable, Equatable {
        let actorDID: String
        let actorHandle: String
        let actorName: String?
        let actorPhoto: URL?
        /// `nil` when the endpoint exposes no per-item timestamp — observed on `getRepostedBy`,
        /// whose items are bare actor profiles with no `createdAt` of their own. The caller falls
        /// back to sync time rather than inventing a value.
        let createdAt: Date?
    }

    private static let iso8601 = ISO8601DateFormatter()
    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Bluesky timestamps are ISO 8601 with fractional seconds (`...000Z`); tries the fractional
    /// formatter first and falls back to the plain one rather than assuming either shape.
    private static func parseDate(_ raw: Any?) -> Date? {
        guard let string = raw as? String else { return nil }
        return iso8601Fractional.date(from: string) ?? iso8601.date(from: string)
    }

    private static let adultLabels: Set<String> = ["porn", "sexual", "nudity", "graphic-media"]

    /// Whether `post` (a `getPostThread` node's `post` object) carries any label — AppView-applied
    /// or self-applied — this codebase treats as adult content. `Interactions.astro` has no
    /// content-warning UI to gate display on, so such a reply is excluded entirely rather than
    /// rendered.
    static func isAdultLabeled(_ post: [String: Any]) -> Bool {
        let appViewLabels = (post["labels"] as? [[String: Any]]) ?? []
        if appViewLabels.contains(where: { adultLabels.contains(($0["val"] as? String) ?? "") }) {
            return true
        }
        let record = post["record"] as? [String: Any]
        let selfLabels = (record?["labels"] as? [String: Any])?["values"] as? [[String: Any]] ?? []
        return selfLabels.contains { adultLabels.contains(($0["val"] as? String) ?? "") }
    }

    /// Extracts a `RawReply` from a `getPostThread` node's `post` object, or `nil` if it's missing
    /// a field this schema requires — a malformed/unexpected AppView response shouldn't crash the
    /// whole sync, just skip this one reply.
    static func makeRawReply(from post: [String: Any]) -> RawReply? {
        guard let uri = post["uri"] as? String, let rkey = uri.split(separator: "/").last,
              let author = post["author"] as? [String: Any], let handle = author["handle"] as? String,
              let record = post["record"] as? [String: Any], let text = record["text"] as? String,
              let createdAt = parseDate(record["createdAt"])
        else { return nil }
        return RawReply(
            rkey: String(rkey), authorHandle: handle,
            authorName: (author["displayName"] as? String) ?? handle,
            authorPhoto: (author["avatar"] as? String).flatMap(URL.init(string:)),
            text: text, createdAt: createdAt)
    }

    /// Recursively flattens every reply under `node` (a `getPostThread` thread or reply object)
    /// into `results`, depth-first. Skips `#blockedPost`/`#notFoundPost` branches (Bluesky-side
    /// moderation/deletion — see the design doc) and adult-labeled posts, but still walks an
    /// adult-labeled post's own children (their labels are independent of their parent's).
    static func flattenReplies(_ node: [String: Any], into results: inout [RawReply]) {
        guard (node["$type"] as? String) == "app.bsky.feed.defs#threadViewPost",
              let post = node["post"] as? [String: Any]
        else { return }
        if !isAdultLabeled(post), let reply = makeRawReply(from: post) {
            results.append(reply)
        }
        for child in (node["replies"] as? [[String: Any]]) ?? [] {
            flattenReplies(child, into: &results)
        }
    }

    /// Extracts one page of actor events from a `getLikes`/`getRepostedBy` response. `itemsKey` is
    /// `"likes"` (each item wraps `{actor, createdAt}`) or `"repostedBy"` (each item *is* the
    /// actor profile directly) — `item["actor"] ?? item` handles both shapes with one function.
    static func makeActorEvents(from json: [String: Any], itemsKey: String) -> [RawActorEvent] {
        let items = (json[itemsKey] as? [[String: Any]]) ?? []
        return items.compactMap { item -> RawActorEvent? in
            let actor = (item["actor"] as? [String: Any]) ?? item
            guard let did = actor["did"] as? String, let handle = actor["handle"] as? String else { return nil }
            return RawActorEvent(
                actorDID: did, actorHandle: handle,
                actorName: (actor["displayName"] as? String) ?? handle,
                actorPhoto: (actor["avatar"] as? String).flatMap(URL.init(string:)),
                createdAt: parseDate(item["createdAt"]))
        }
    }

    /// Shared paging loop for `fetchLikes`/`fetchReposts`: follows `cursor` up to `maximumPages`,
    /// stopping early once a page returns no cursor. Returns `nil` on *any* page's hard failure,
    /// first or later — a later-page failure must not return the partial results gathered so far,
    /// since `BlueskyBackfeedSync` treats a non-`nil` result as "this is the complete, current
    /// set" and hands it straight to the committer's scoped reconcile: a partial set there would
    /// read the unfetched remainder as "no longer present" and delete real, still-current
    /// likes/reposts. All-or-nothing here matches `fetchReplies`'s own failure contract.
    private static func paginate(
        endpoint: String, atURI: String, itemsKey: String, transport: Transport
    ) async -> [RawActorEvent]? {
        var results: [RawActorEvent] = []
        var cursor: String?
        var page = 0
        repeat {
            var items = [URLQueryItem(name: "uri", value: atURI), URLQueryItem(name: "limit", value: String(pageSize))]
            if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
            guard let url = Self.url(path: endpoint, queryItems: items),
                  let (data, http) = try? await transport(URLRequest(url: url)), (200..<300).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            results.append(contentsOf: makeActorEvents(from: json, itemsKey: itemsKey))
            cursor = json["cursor"] as? String
            page += 1
        } while cursor != nil && page < maximumPages
        return results
    }

    static func fetchLikes(atURI: String, transport: Transport) async -> [RawActorEvent]? {
        await paginate(endpoint: "app.bsky.feed.getLikes", atURI: atURI, itemsKey: "likes", transport: transport)
    }

    static func fetchReposts(atURI: String, transport: Transport) async -> [RawActorEvent]? {
        await paginate(endpoint: "app.bsky.feed.getRepostedBy", atURI: atURI, itemsKey: "repostedBy", transport: transport)
    }

    private static func url(path: String, queryItems: [URLQueryItem]) -> URL? {
        var components = URLComponents(string: "https://public.api.bsky.app/xrpc/\(path)")
        components?.queryItems = queryItems
        return components?.url
    }

    /// Fetches and flattens every reply under `atURI`'s thread, at any depth. Returns `nil` on any
    /// hard failure (network error, non-2xx, undecodable body) — callers must treat `nil` as
    /// "retry next time," never as "zero replies," since a root post that's genuinely gone comes
    /// back as a *successful* response whose `thread` is `#notFoundPost`/`#blockedPost` (handled
    /// here as an empty result, not a `nil` one).
    ///
    /// **Important:** this walks `thread["replies"]`, not `thread` itself. `thread["post"]` is the
    /// *tracked post's own copy* (the same post `atURI` names) — `flattenReplies` on `thread`
    /// directly would append the owner's own post as if it were a reply to itself. Each element of
    /// `thread["replies"]`, by contrast, genuinely is a reply — that's where `flattenReplies`
    /// (append this node's post, recurse into its own nested `replies`) is the correct walk.
    static func fetchReplies(atURI: String, transport: Transport) async -> [RawReply]? {
        guard let url = Self.url(path: "app.bsky.feed.getPostThread", queryItems: [
            URLQueryItem(name: "uri", value: atURI),
            URLQueryItem(name: "depth", value: String(threadDepth)),
            URLQueryItem(name: "parentHeight", value: "0"),
        ]) else { return nil }
        guard let (data, http) = try? await transport(URLRequest(url: url)), (200..<300).contains(http.statusCode)
        else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let thread = json["thread"] as? [String: Any]
        else { return nil }
        guard (thread["$type"] as? String) == "app.bsky.feed.defs#threadViewPost" else { return [] }
        var results: [RawReply] = []
        for child in (thread["replies"] as? [[String: Any]]) ?? [] {
            flattenReplies(child, into: &results)
        }
        return results
    }
}
