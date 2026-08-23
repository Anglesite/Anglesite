import Foundation

/// Produces owner-language strings describing an import plan: item counts, problem summary, and
/// skipped-URL summary — never using internal terms ("collection", "frontmatter", "markdown",
/// rung names).
public struct ImportSummaryModel: Sendable, Equatable {
    /// e.g. `["42 blog posts", "6 pages", "3 notes", "310 images"]` — non-zero counts only,
    /// fixed order: blog, pages, notes, photos, bookmarks, replies, likes, then images.
    public var countLines: [String]

    /// e.g. `"3 pages couldn't be brought over cleanly"` — nil when problems is empty.
    public var attentionLine: String?

    /// e.g. `"12 archive pages were left behind (tags, categories)"` — nil when skippedURLs is empty.
    public var skippedLine: String?

    /// Creates an import summary from a plan.
    /// - Parameters:
    ///   - plan: The import plan to summarize.
    public init(plan: ImportPlan) {
        // Fixed order of count keys to display
        let countOrder = ["blog", "pages", "notes", "photos", "bookmarks", "replies", "likes"]

        var lines: [String] = []

        // Build count lines in fixed order, skipping zero counts
        for key in countOrder {
            if let count = plan.counts[key], count > 0 {
                let displayName = Self.displayName(for: key, count: count)
                lines.append("\(count) \(displayName)")
            }
        }

        // Add images at the end if imageCount > 0
        if plan.imageCount > 0 {
            let displayName = Self.displayName(for: "images", count: plan.imageCount)
            lines.append("\(plan.imageCount) \(displayName)")
        }

        self.countLines = lines

        // Build attention line if there are problems
        if !plan.problems.isEmpty {
            let displayName = Self.displayName(for: "pages", count: plan.problems.count)
            self.attentionLine = "\(plan.problems.count) \(displayName) couldn't be brought over cleanly"
        } else {
            self.attentionLine = nil
        }

        // Build skipped line if there are skipped URLs
        if !plan.skippedURLs.isEmpty {
            let displayName = Self.displayName(for: "archive-page", count: plan.skippedURLs.count)
            let verb = plan.skippedURLs.count == 1 ? "was" : "were"
            self.skippedLine = "\(plan.skippedURLs.count) \(displayName) \(verb) left behind (tags, categories)"
        } else {
            self.skippedLine = nil
        }
    }

    /// Returns the display name for a category with correct singular/plural.
    private static func displayName(for category: String, count: Int) -> String {
        let singular: String
        switch category {
        case "blog":
            singular = "blog post"
        case "pages":
            singular = "page"
        case "notes":
            singular = "note"
        case "photos":
            singular = "photo"
        case "bookmarks":
            singular = "bookmark"
        case "replies":
            singular = "reply"
        case "likes":
            singular = "like"
        case "images":
            singular = "image"
        case "archive-page":
            singular = "archive page"
        case _:
            singular = "page"
        }

        if count == 1 {
            return singular
        } else {
            // Pluralize: most just add 's', 'reply' → 'replies'
            if category == "replies" {
                return "replies"
            }
            return singular + "s"
        }
    }
}
