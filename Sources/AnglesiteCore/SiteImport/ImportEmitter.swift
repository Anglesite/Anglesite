import Foundation

/// A single content file to write into the site's `Source/` root as part of an import.
public struct ImportFileEmission: Sendable, Equatable {
    /// The file's path, relative to the site's `Source/` root (e.g. `src/content/blog/one.md`).
    public var relativePath: String
    /// The complete file contents, including frontmatter and body.
    public var contents: String

    /// Initializes an emission with its destination path and complete contents.
    /// - Parameters:
    ///   - relativePath: The file's path, relative to the site's `Source/` root.
    ///   - contents: The complete file contents, including frontmatter and body.
    public init(relativePath: String, contents: String) {
        self.relativePath = relativePath
        self.contents = contents
    }
}

/// Renders a `ClassifiedItem` into the Markdown file the template's content collections expect.
///
/// Frontmatter fields and their order are byte-faithful to the `.strict()` zod schemas in
/// `Resources/Template/src/content.config.ts` — an extra or misordered key would fail validation
/// at build time, and `.strict()` rejects unknown keys outright, so only fields the schema
/// declares are ever emitted, and only when the source item actually has a value for them.
public enum ImportEmitter {
    /// Renders a classified item into its destination file: content-collection Markdown with
    /// strict frontmatter, or a Markdown page with a `layout` pointing at `BaseLayout.astro`.
    /// - Parameter classified: The item and the destination `ContentClassifier` assigned it.
    /// - Returns: The file's site-relative path and complete contents.
    public static func emission(for classified: ClassifiedItem) -> ImportFileEmission {
        switch classified.destination {
        case .collection(let name, let slug):
            return collectionEmission(item: classified.item, collection: name, slug: slug)
        case .page(let route):
            return pageEmission(item: classified.item, route: route)
        }
    }

    /// Dispatches to the frontmatter builder for `collection`, then assembles the file.
    private static func collectionEmission(item: ImportItem, collection: String, slug: String) -> ImportFileEmission {
        let fields = frontmatterFields(item: item, collection: collection)
        let relativePath = ContentScaffold.postRelativePath(collection: collection, slug: slug)
        return ImportFileEmission(relativePath: relativePath, contents: render(fields: fields, body: item.markdown))
    }

    /// Ordered `(key, value)` pairs for a collection entry: the collection's non-`draft` required
    /// fields (in the order the task brief's table lists them), then its optional fields (table
    /// order, only when the item has a value), then `draft: false` last. `.strict()` rejects any
    /// key the schema doesn't declare, so only fields the target collection's schema actually
    /// declares are ever produced — an unrecognized collection name falls back to `draft: false`
    /// alone, which fails loudly (missing a required field) rather than emitting a key `.strict()`
    /// would reject.
    private static func frontmatterFields(item: ImportItem, collection: String) -> [(String, String)] {
        var fields: [(String, String)]

        switch collection {
        case "blog":
            fields = [
                ("title", yamlString(item.title ?? "")),
                ("pubDate", dateString(item.published)),
            ]
            if let excerpt = item.excerpt { fields.append(("description", yamlString(excerpt))) }

        case "notes":
            fields = [("publishDate", dateString(item.published))]
            if let lang = item.lang { fields.append(("lang", yamlString(lang))) }
            if !item.tags.isEmpty { fields.append(("tags", yamlList(item.tags))) }

        case "photos":
            fields = [
                ("image", yamlString(photoImage(item))),
                ("publishDate", dateString(item.published)),
            ]
            if let excerpt = item.excerpt { fields.append(("caption", yamlString(excerpt))) }
            if let lang = item.lang { fields.append(("lang", yamlString(lang))) }
            if !item.tags.isEmpty { fields.append(("tags", yamlList(item.tags))) }

        case "bookmarks":
            fields = [
                ("bookmarkOf", yamlString(bookmarkOf(item))),
                ("publishDate", dateString(item.published)),
            ]
            if let title = item.title { fields.append(("title", yamlString(title))) }
            if let image = item.images.first { fields.append(("image", yamlString(image))) }
            if let lang = item.lang { fields.append(("lang", yamlString(lang))) }
            if !item.tags.isEmpty { fields.append(("tags", yamlList(item.tags))) }

        case "replies":
            fields = [
                ("inReplyTo", yamlString(replyTo(item))),
                ("publishDate", dateString(item.published)),
            ]
            if let lang = item.lang { fields.append(("lang", yamlString(lang))) }

        case "likes":
            fields = [
                ("likeOf", yamlString(likeOf(item))),
                ("publishDate", dateString(item.published)),
            ]
            if let lang = item.lang { fields.append(("lang", yamlString(lang))) }

        default:
            fields = []
        }

        fields.append(("draft", "false"))
        return fields
    }

    /// The bookmarked URL from the item's `.bookmark` hint, or `""` if the hint doesn't match.
    private static func bookmarkOf(_ item: ImportItem) -> String {
        if case .bookmark(let of) = item.hint { return of }
        return ""
    }

    /// The liked URL from the item's `.like` hint, or `""` if the hint doesn't match.
    private static func likeOf(_ item: ImportItem) -> String {
        if case .like(let of) = item.hint { return of }
        return ""
    }

    /// The replied-to URL from the item's `.reply` hint, or `""` if the hint doesn't match.
    private static func replyTo(_ item: ImportItem) -> String {
        if case .reply(let to) = item.hint { return to }
        return ""
    }

    /// The photo's image URL from the item's `.photo` hint, falling back to the first collected
    /// image, or `""` if neither is present.
    private static func photoImage(_ item: ImportItem) -> String {
        if case .photo(let image) = item.hint { return image }
        return item.images.first ?? ""
    }

    /// Renders a Markdown page: `layout` pointing back at `BaseLayout.astro` plus `title`, body =
    /// the item's markdown. Path swaps `ContentScaffold.pageRelativePath`'s `.astro` for `.md`
    /// since imported pages carry no Astro component syntax, only Markdown content Astro's
    /// Markdown-layout convention renders through `BaseLayout` directly.
    private static func pageEmission(item: ImportItem, route: String) -> ImportFileEmission {
        let normalizedRoute = ContentScaffold.normalizeRoute(route)
        let astroPath = ContentScaffold.pageRelativePath(normalizedRoute: normalizedRoute)
        let relativePath = String(astroPath.dropLast("astro".count)) + "md"

        var fields: [(String, String)] = [("layout", layoutPath(for: normalizedRoute))]
        if let title = item.title { fields.append(("title", yamlString(title))) }

        return ImportFileEmission(relativePath: relativePath, contents: render(fields: fields, body: item.markdown))
    }

    /// The relative path from a page's Markdown file back to `src/layouts/BaseLayout.astro`.
    /// `src/pages/about.md` -> `../layouts/BaseLayout.astro`; each additional route segment
    /// nests the page one directory deeper under `src/pages/`, adding one more `../`.
    private static func layoutPath(for normalizedRoute: String) -> String {
        let segments = normalizedRoute.split(separator: "/", omittingEmptySubsequences: true)
        let depth = max(segments.count, 1)
        let ups = Array(repeating: "..", count: depth).joined(separator: "/")
        return "\(ups)/layouts/BaseLayout.astro"
    }

    /// Assembles `---\n` + one `key: value` line per field + `---\n\n` + the Markdown body,
    /// matching the byte-exact shape the template's frontmatter parser and this task's tests
    /// expect (fenced, blank line before body, no trailing fence blank line beyond the one
    /// separator).
    private static func render(fields: [(String, String)], body: String) -> String {
        var lines = ["---"]
        lines.append(contentsOf: fields.map { "\($0.0): \($0.1)" })
        lines.append("---")
        lines.append("")
        lines.append(body)
        return lines.joined(separator: "\n")
    }

    /// Formats a date as `YYYY-MM-DD` (`en_US_POSIX`, UTC), falling back to today's date (in the
    /// same fixed calendar) when the item carries none — every collection's `publishDate`/`pubDate`
    /// field is required by its `.strict()` schema, so an emission must never omit it.
    private static func dateString(_ date: Date?) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date ?? Date())
    }

    /// Renders a YAML flow-sequence of already-quoted strings, e.g. `["a", "b"]`.
    private static func yamlList(_ values: [String]) -> String {
        "[" + values.map(yamlString).joined(separator: ", ") + "]"
    }

    /// Quotes `value` for YAML scalar output when it would otherwise be ambiguous or invalid
    /// unquoted: contains `: ` (looks like a nested mapping), `#` (looks like a comment), `"`,
    /// leading/trailing whitespace, or starts with a YAML indicator character. Quoted output
    /// backslash-escapes `\` and `"` so the value round-trips through a YAML double-quoted
    /// scalar unchanged.
    /// - Parameter value: The raw scalar value to render as YAML.
    /// - Returns: `value` unquoted when safe to emit bare, otherwise a double-quoted, escaped form.
    static func yamlString(_ value: String) -> String {
        let indicatorCharacters = CharacterSet(charactersIn: "-?[]{}&*!|>%@`")
        let needsQuoting = value.contains(": ")
            || value.contains("#")
            || value.contains("\"")
            || value.hasPrefix(" ")
            || value.hasSuffix(" ")
            || (value.unicodeScalars.first.map { indicatorCharacters.contains($0) } ?? false)

        guard needsQuoting else { return value }

        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
