import Foundation

/// A destination for classified content within the Anglesite site structure.
public enum ImportDestination: Sendable, Equatable {
    /// A collection entry (blog, notes, photos, bookmarks, replies, likes, etc.).
    /// - Parameters:
    ///   - name: The collection name (e.g., "blog", "notes", "photos").
    ///   - slug: The entry's slug, derived from the item's source URL.
    case collection(name: String, slug: String)

    /// A site page (e.g., /about, /contact).
    /// - Parameters:
    ///   - route: The page route, normalized from the source URL path.
    case page(route: String)
}

/// An import item paired with its destination within the site structure.
public struct ClassifiedItem: Sendable, Equatable {
    /// The item being classified.
    public var item: ImportItem

    /// The destination for this item.
    public var destination: ImportDestination

    /// Initializes a classified item with an item and its destination.
    /// - Parameters:
    ///   - item: The import item.
    ///   - destination: The destination for this item.
    public init(item: ImportItem, destination: ImportDestination) {
        self.item = item
        self.destination = destination
    }
}

/// Classifies resolved content items into their target site structure destinations.
///
/// Classification assigns each `ImportItem` to a destination — either a collection
/// (blog, notes, photos, etc.) or a page — based on semantic hints and URL patterns.
public enum ContentClassifier {
    /// Classifies resolved content items into their destination structure.
    ///
    /// Items are classified using the following rule order:
    /// 1. `.wpPost` → `collection("blog", slug)`
    /// 2. `.wpPage` → `page(route:)` from URL path
    /// 3. Microformat hints → `.bookmark` → bookmarks, `.like` → likes, `.reply` → replies,
    ///    `.photo` → photos, `.note` → notes, `.article` → blog
    /// 4. `.none` with blog/posts patterns or date paths → `collection("blog", slug)`
    /// 5. Otherwise → `page(route:)` from URL path
    ///
    /// Titled blog items without a published date are assigned `published = now` at
    /// classification time, since emitters require a date.
    ///
    /// - Parameters:
    ///   - resolved: The resolved content items to classify.
    ///   - now: The current date, used as a fallback for undated blog items and URL-based slugs.
    /// - Returns: An array of classified items.
    public static func classify(_ resolved: ResolvedContent, now: Date) -> [ClassifiedItem] {
        resolved.items.map { item in
            var classifiedItem = item
            let destination = classifyDestination(for: item, now: now)

            // Titled blog items with no published date get published = now
            if case .collection(let name, _) = destination, name == "blog",
               item.title != nil && !item.title!.trimmingCharacters(in: .whitespaces).isEmpty,
               item.published == nil {
                classifiedItem.published = now
            }

            return ClassifiedItem(item: classifiedItem, destination: destination)
        }
    }

    /// Classifies a single item to its destination.
    private static func classifyDestination(for item: ImportItem, now: Date) -> ImportDestination {
        let slug = extractSlug(from: item.sourceURL, now: now)
        let route = normalizeRoute(from: item.sourceURL)

        // Rule 1: .wpPost → collection("blog", slug)
        if case .wpPost = item.hint {
            return .collection(name: "blog", slug: slug)
        }

        // Rule 2: .wpPage → page(route)
        if case .wpPage = item.hint {
            return .page(route: route)
        }

        // Rule 3: Microformat hints
        switch item.hint {
        case .bookmark:
            return .collection(name: "bookmarks", slug: slug)
        case .like:
            return .collection(name: "likes", slug: slug)
        case .reply:
            return .collection(name: "replies", slug: slug)
        case .photo:
            return .collection(name: "photos", slug: slug)
        case .note:
            return .collection(name: "notes", slug: slug)
        case .article:
            return .collection(name: "blog", slug: slug)
        case .wpPost, .wpPage, .none:
            break
        }

        // Rule 4: .none with blog/posts patterns or date paths
        if case .none = item.hint {
            let path = URLComponents(string: item.sourceURL)?.path ?? ""
            if isBlogPath(path) {
                return .collection(name: "blog", slug: slug)
            }
        }

        // Rule 5: Otherwise → page(route)
        return .page(route: route)
    }

    /// Extracts a slug from an item's source URL.
    ///
    /// The slug is the last non-empty path segment, run through `ContentScaffold.slugify`.
    /// If the last segment is empty or missing, falls back to `ContentScaffold.slugFromURL` with
    /// the provided date, ensuring deterministic output.
    private static func extractSlug(from sourceURL: String, now: Date) -> String {
        let path = URLComponents(string: sourceURL)?.path ?? ""
        let lastSegment = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init) ?? ""

        if lastSegment.isEmpty {
            // Fallback to date-based slug from URL using the provided date
            return ContentScaffold.slugFromURL(sourceURL, now: now)
        }

        return ContentScaffold.slugify(lastSegment)
    }

    /// Normalizes a route from an item's source URL path.
    private static func normalizeRoute(from sourceURL: String) -> String {
        let path = URLComponents(string: sourceURL)?.path ?? ""
        return ContentScaffold.normalizeRoute(path)
    }

    /// Whether a URL path matches blog/posts patterns or looks like a dated archive.
    ///
    /// Returns true if the path contains `/blog/` or `/posts/`, or matches the pattern
    /// `/YYYY/MM/` (four digits, slash, two digits, slash).
    private static func isBlogPath(_ path: String) -> Bool {
        if path.contains("/blog/") || path.contains("/posts/") {
            return true
        }

        // Match YYYY/MM date pattern
        let datePattern = "^/[0-9]{4}/[0-9]{2}/"
        let regex = try? NSRegularExpression(pattern: datePattern)
        let range = NSRange(path.startIndex..<path.endIndex, in: path)
        return regex?.firstMatch(in: path, range: range) != nil
    }
}
