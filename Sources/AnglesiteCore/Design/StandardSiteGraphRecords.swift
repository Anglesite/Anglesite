import Foundation

/// `site.standard.graph.subscription` record — one per followed publication, written into the
/// owner's own PDS repo. See https://standard.site/docs/lexicons/subscription/.
///
/// Unlike ``StandardSitePublicationRecord``/``StandardSiteDocumentRecord``, this lexicon has no
/// grapheme-limited text fields — `publication` is an at-URI, `createdAt` a timestamp — so there
/// is no truncation-at-construction step here.
public struct StandardSiteGraphSubscriptionRecord: Encodable, Equatable, Sendable {
    let type = "site.standard.graph.subscription"
    /// The followed site's `site.standard.publication` at-URI, resolved from its
    /// `/.well-known/site.standard.publication` (``StandardSitePublicationResolver``).
    public let publication: String
    /// ISO 8601 timestamp string.
    public let createdAt: String

    enum CodingKeys: String, CodingKey {
        case type = "$type"
        case publication, createdAt
    }

    public init(publication: String, createdAt: String) {
        self.publication = publication
        self.createdAt = createdAt
    }
}
