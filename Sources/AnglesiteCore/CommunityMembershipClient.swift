import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Failures from ``CommunityMembershipClient``'s outbox POSTs. `Equatable` so tests can assert
/// on the exact failure rather than string-compare error dumps.
public enum CommunityMembershipError: Error, Equatable, Sendable {
    /// The outbox POST failed — non-2xx from the Worker, or a transport error (reported as
    /// status 0). `body` is capped at the first 400 bytes, enough to diagnose without echoing an
    /// arbitrary payload into logs/UI.
    case requestFailed(status: Int, body: String)
    /// Reserved for a response body that can't be interpreted; currently unused because
    /// ``CommunityMembershipClient/follow(target:)`` degrades gracefully when the outbox reply
    /// carries no activity id instead of failing.
    case decodingFailed(String)
}

/// Joins/leaves a fediverse `Group` (V-5.1a, #368) by POSTing `Follow`/`Undo(Follow)` to this
/// site's own outbox — the same owner-gated endpoint and `publishToken` bearer
/// `ActivityPubOutboxBackfill` already uses (`@dwk/activitypub`'s "Owner-published Follow /
/// Undo(Follow) now record the relationship and deliver to the target actor" behavior, phase 2).
/// This site's Worker is the trusted party here (it holds the signing key and does the actual
/// federated delivery), so — unlike `CommunityActorResolver` — there is no HTTPS/size-cap guard
/// on this client itself; the target IRI it's given already passed through that resolver.
public struct CommunityMembershipClient: Sendable {
    /// Injection seam for tests — lets suites capture the outbox request and feed canned
    /// responses without a network. Production uses ``defaultTransport``.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let outboxURL: URL
    private let ownActorURL: URL
    private let publishToken: String
    private let transport: Transport

    /// Creates a client for one site's own actor. The outbox endpoint isn't a parameter — it's
    /// derived as `ownActorURL/outbox`, the shape `@dwk/activitypub` guarantees, so a caller
    /// can't accidentally point the bearer-authenticated POST at some other endpoint.
    ///
    /// - Parameters:
    ///   - ownActorURL: This site's own actor IRI (the `actor` in every activity posted).
    ///   - publishToken: The owner-gated bearer token the Worker's outbox requires — the same
    ///     credential `ActivityPubOutboxBackfill` uses.
    ///   - transport: Test seam; defaults to ``defaultTransport``.
    public init(
        ownActorURL: URL, publishToken: String,
        transport: @escaping Transport = CommunityMembershipClient.defaultTransport
    ) {
        self.ownActorURL = ownActorURL
        self.outboxURL = ownActorURL.appendingPathComponent("outbox")
        self.publishToken = publishToken
        self.transport = transport
    }

    /// Returns the activity id the outbox reports back — persist it (`CommunitiesLedger`) so
    /// `unfollow` can reference the exact original `Follow` in its `Undo`.
    @discardableResult
    public func follow(target: URL) async throws -> String {
        let body: [String: Any] = [
            "@context": "https://www.w3.org/ns/activitystreams",
            "type": "Follow",
            "actor": ownActorURL.absoluteString,
            "object": target.absoluteString,
        ]
        let data = try await post(body)
        return Self.activityID(from: data) ?? target.absoluteString
    }

    /// `followActivityID` is the id `follow(target:)` returned, if this membership was joined
    /// through this client (the common case). When it's `nil` — e.g. membership predates this
    /// feature — a synthetic nested `Follow` object stands in, a shape most AP implementations
    /// accept for `Undo` since the concrete activity id was never recorded client-side.
    public func unfollow(target: URL, followActivityID: String?) async throws {
        let followObject: Any = followActivityID ?? [
            "type": "Follow",
            "actor": ownActorURL.absoluteString,
            "object": target.absoluteString,
        ]
        let body: [String: Any] = [
            "@context": "https://www.w3.org/ns/activitystreams",
            "type": "Undo",
            "actor": ownActorURL.absoluteString,
            "object": followObject,
        ]
        _ = try await post(body)
    }

    /// Bans a member or un-announces a member post — one primitive, two moderation effects, per
    /// workers#473: the Worker's `Remove` handler treats `object` as either a member actor IRI
    /// (ban) or an announced post's IRI (un-announce), authorized by the owner's bearer
    /// `publishToken` alone — no `config.moderators` membership required, since the owner is
    /// implicitly the top moderator of their own actor. `target` is whichever IRI the caller
    /// wants removed; there's no separate "kind" parameter because the Worker itself dispatches
    /// on what `target` resolves to, not on anything this client declares up front.
    public func remove(target: URL) async throws {
        let body: [String: Any] = [
            "@context": "https://www.w3.org/ns/activitystreams",
            "type": "Remove",
            "actor": ownActorURL.absoluteString,
            "object": target.absoluteString,
        ]
        _ = try await post(body)
    }

    /// Un-bans a member — the AS2 inverse of ``remove(target:)``'s ban effect (#1742): same
    /// bearer-`publishToken`-to-`/outbox` POST, same bare-actor-IRI `object` shape, just `"Add"`
    /// instead of `"Remove"`. Unlike `remove(target:)` this has only one moderation effect (there
    /// is no "un-remove a post" concept to disambiguate), so there's no risk of the Worker
    /// resolving `object` against the wrong collection the way a hypothetical generic "Undo"
    /// might.
    public func add(target: URL) async throws {
        let body: [String: Any] = [
            "@context": "https://www.w3.org/ns/activitystreams",
            "type": "Add",
            "actor": ownActorURL.absoluteString,
            "object": target.absoluteString,
        ]
        _ = try await post(body)
    }

    /// Confirms a pending join request — the owner-triggered half of workers#473's `Accept`
    /// routing, which already ships in `dwk-server-v1.0.0-beta.3`. Same shorthand `object` shape
    /// as ``remove(target:)``: a bare actor IRI, which the Worker's `#singleFollowTarget` resolves
    /// against the stored `Follow` row.
    public func acceptFollow(target: URL) async throws {
        let body: [String: Any] = [
            "@context": "https://www.w3.org/ns/activitystreams",
            "type": "Accept",
            "actor": ownActorURL.absoluteString,
            "object": target.absoluteString,
        ]
        _ = try await post(body)
    }

    /// Declines a pending join request — the owner's alternative to ``acceptFollow(target:)``.
    /// Same `POST <actor>/outbox` seam and target-resolution rules (bare actor IRI as
    /// `object`), just `"Reject"` instead of `"Accept"`. Unlike `remove(target:)` (which bans
    /// an *already-accepted* member), this only makes sense against a still-pending request —
    /// the Worker's `#singleFollowTarget` resolves it the same way either verb does.
    public func rejectFollow(target: URL) async throws {
        let body: [String: Any] = [
            "@context": "https://www.w3.org/ns/activitystreams",
            "type": "Reject",
            "actor": ownActorURL.absoluteString,
            "object": target.absoluteString,
        ]
        _ = try await post(body)
    }

    /// Lists everyone whose `Follow` is awaiting this owner's `Accept` — the bearer-gated
    /// `GET <actor>/follow_requests` `davidwkeith/workers` PR #488 added (closing workers#487),
    /// mirroring `GET <actor>/blocked`'s unpaged flat `{items, total}` JSON exactly. **Not yet in
    /// a tagged `@dwk/workers` release** as of `dwk-server-v1.0.0-beta.3` — callers must treat a
    /// failure here (most likely a 404 from a not-yet-updated deployed Worker) as "nothing
    /// pending", never as a user-facing error; see `ModerationModel.loadPendingFollowers()`.
    public func listFollowRequests() async throws -> [PendingFollower] {
        var request = URLRequest(url: ownActorURL.appendingPathComponent("follow_requests"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(publishToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = ActorProfileFetcher.timeout
        let data = try await send(request)
        return Self.decodeFollowRequests(data)
    }

    /// Decodes the Worker's `{items: [{actor, addedAt}], total}` response. A response that
    /// doesn't parse as this shape at all (missing `items`, wrong field types) yields an empty
    /// list — same "a bad read must never make the pane unusable" rule ``ModerationModel``'s
    /// snapshot decoding already follows. An individual item's `addedAt` that fails ISO 8601
    /// parsing (with or without fractional seconds — `Date.toISOString()` always emits
    /// `.000`-style milliseconds, which the plain `ISO8601DateFormatter()` default options
    /// reject) defaults to `.distantPast` rather than dropping the item: a malformed timestamp
    /// must never make a real pending requester silently unapprovable.
    private static func decodeFollowRequests(_ data: Data) -> [PendingFollower] {
        struct Response: Decodable {
            struct Item: Decodable { let actor: URL; let addedAt: String }
            let items: [Item]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        let withFractional: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()
        let plain = ISO8601DateFormatter()
        return response.items.map { item in
            let date = withFractional.date(from: item.addedAt) ?? plain.date(from: item.addedAt) ?? .distantPast
            return PendingFollower(actor: item.actor, addedAt: date)
        }
    }

    /// Shared POST/GET status handling: maps a transport error or non-2xx response to
    /// ``CommunityMembershipError/requestFailed(status:body:)``, otherwise returns the raw body.
    /// Factored out of `post(_:)` so ``listFollowRequests()``'s GET reuses the exact same mapping
    /// instead of duplicating it.
    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await transport(request)
        } catch {
            throw CommunityMembershipError.requestFailed(status: 0, body: "\(error)")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CommunityMembershipError.requestFailed(
                status: http.statusCode, body: String(decoding: data.prefix(400), as: UTF8.self))
        }
        return data
    }

    private func post(_ activity: [String: Any]) async throws -> Data {
        var request = URLRequest(url: outboxURL)
        request.httpMethod = "POST"
        request.setValue("application/activity+json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(publishToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: activity)
        request.timeoutInterval = ActorProfileFetcher.timeout
        return try await send(request)
    }

    static func activityID(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["id"] as? String
    }

    /// Production transport: plain `URLSession.shared`, deliberately *without* the byte-cap
    /// wrapper the read-side clients use — the responder here is this site's own trusted Worker,
    /// not an arbitrary remote instance (see the type-level doc).
    public static let defaultTransport: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}
