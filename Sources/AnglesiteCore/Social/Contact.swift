import Foundation

/// A person the site owner knows, stored privately per site (#966). Distinct from the public
/// `member` content type (`ContentTypeRegistry.swift`) — this is never published.
public struct Contact: Codable, Equatable, Sendable, Identifiable {
    /// Stable identity for SwiftUI list diffing and lookup. Not one of the issue's three literal
    /// fields (`me`, `displayName`, `addedDate`) — needed because `me` itself is editable, so it
    /// can't double as a stable key the way `FollowerRow.id` uses `actor.absoluteString`.
    public let id: UUID
    /// The person's canonical identity URL — their own website, in the IndieAuth `me` sense.
    public var me: URL
    public var displayName: String
    public let addedDate: Date
    /// The ActivityPub actor IRI, set when this contact was promoted from a follower.
    public var linkedActor: URL?
    /// A followed Microsub feed URL. No promotion flow populates this yet (`MicrosubClient` has
    /// no "list followed feeds" endpoint) — settable only via manual edit until one exists.
    public var linkedFeed: URL?

    public init(
        id: UUID = UUID(),
        me: URL,
        displayName: String,
        addedDate: Date = Date(),
        linkedActor: URL? = nil,
        linkedFeed: URL? = nil
    ) {
        self.id = id
        self.me = me
        self.displayName = displayName
        self.addedDate = addedDate
        self.linkedActor = linkedActor
        self.linkedFeed = linkedFeed
    }
}

/// Normalizes a URL for identity comparison: lowercased host, scheme dropped, trailing slash
/// trimmed. Contacts enter `me` and social/website URLs by hand, so two URLs that only differ by
/// http/https or a trailing slash must still compare equal. Shared by `ContactStore` (identity
/// dedup) and `ContactsMatcher` (Task 2, matching against system Contacts).
func normalizedIdentityKey(for url: URL) -> String {
    let host = (url.host ?? "").lowercased()
    var path = url.path
    if path.hasSuffix("/") {
        path.removeLast()
    }
    return host + path
}
