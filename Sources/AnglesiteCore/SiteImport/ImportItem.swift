import Foundation

/// A problem encountered during import, e.g. unreadable JSON or missing markdown conversion.
public struct ImportProblem: Codable, Sendable, Equatable {
    /// The URL where the problem occurred.
    public var sourceURL: String
    /// A human-readable message describing the problem.
    public var message: String

    /// Initializes an ImportProblem with a source URL and message.
    public init(sourceURL: String, message: String) {
        self.sourceURL = sourceURL
        self.message = message
    }
}

/// An item to import: a post, page, or other content with metadata and markdown.
public struct ImportItem: Sendable, Equatable {
    /// The provenance of the item (which extraction rung produced it).
    public enum Rung: String, Codable, Sendable {
        case wpREST = "wp-rest"
        case feed
        case microformats
        case readability
    }

    /// A semantic hint about the item's content type.
    public enum Hint: Sendable, Equatable {
        /// A WordPress post.
        case wpPost
        /// A WordPress page.
        case wpPage
        /// A short note or status update.
        case note
        /// An article.
        case article
        /// A photo with caption.
        case photo(image: String)
        /// A bookmark or link.
        case bookmark(of: String)
        /// A like or favorite.
        case like(of: String)
        /// A reply to another post.
        case reply(to: String)
        /// No specific hint.
        case none
    }

    /// The normalized source URL of the item.
    public var sourceURL: String
    /// The item's title, if available.
    public var title: String?
    /// The item's publication date, if available.
    public var published: Date?
    /// The item's language code, if available.
    public var lang: String?
    /// The item's content as Markdown.
    public var markdown: String
    /// The item's excerpt, if available.
    public var excerpt: String?
    /// URLs of images associated with the item.
    public var images: [String]
    /// Tags associated with the item.
    public var tags: [String]
    /// The extraction rung that produced this item.
    public var rung: Rung
    /// A semantic hint about the item's content type.
    public var hint: Hint

    /// Initializes an ImportItem with metadata and content.
    /// - Parameters:
    ///   - sourceURL: The normalized source URL of the item, pre-normalized via `ImportSnapshot.normalizeURL`.
    ///   - title: The item's title, if available.
    ///   - published: The item's publication date, if available.
    ///   - lang: The item's language code, if available.
    ///   - markdown: The item's content as Markdown.
    ///   - excerpt: The item's excerpt, if available.
    ///   - images: URLs of images associated with the item.
    ///   - tags: Tags associated with the item.
    ///   - rung: The extraction rung that produced this item.
    ///   - hint: A semantic hint about the item's content type.
    public init(sourceURL: String, title: String? = nil, published: Date? = nil,
                lang: String? = nil, markdown: String, excerpt: String? = nil,
                images: [String] = [], tags: [String] = [], rung: Rung, hint: Hint) {
        self.sourceURL = sourceURL
        self.title = title
        self.published = published
        self.lang = lang
        self.markdown = markdown
        self.excerpt = excerpt
        self.images = images
        self.tags = tags
        self.rung = rung
        self.hint = hint
    }
}
