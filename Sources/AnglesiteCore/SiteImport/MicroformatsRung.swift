import Foundation

/// The microformats2 extraction rung: decodes `h-entry` posts from a page's parsed mf2 JSON.
public enum MicroformatsRung {
    /// Extracts items from every captured page's microformats2 JSON in the snapshot.
    ///
    /// Each page's `extraction.mf2JSON` is parsed as canonical mf2 JSON (`{"items":[…]}`). Every
    /// top-level `h-entry` is taken, plus any `h-entry` found one level down inside an `h-feed`'s
    /// `children`. A page with no `h-entry` (most pages aren't posts) contributes nothing — that's
    /// not a problem worth reporting. The item's semantic hint is derived from which mf2 properties
    /// are present, first match wins: `bookmark-of` → `.bookmark(of:)`, `like-of` → `.like(of:)`,
    /// `in-reply-to` → `.reply(to:)`, a `photo` with no substantial `content` → `.photo(image:)`, a
    /// missing/empty `name` → `.note`, otherwise `.article`. The body prefers `content[0].html`
    /// converted via `snapshot.markdown(forHTML:)`, falls back to `content[0].value` (or a bare
    /// string) as plain text, and finally falls back to the page's own extracted Markdown.
    ///
    /// - Parameter snapshot: The import snapshot containing captured pages and HTML conversions.
    /// - Returns: A tuple containing extracted items and any problems encountered during extraction.
    public static func items(from snapshot: ImportSnapshot)
        -> (items: [ImportItem], problems: [ImportProblem]) {
        var items: [ImportItem] = []
        let problems: [ImportProblem] = []

        for page in snapshot.pages {
            guard let mf2JSON = page.extraction.mf2JSON else { continue }
            guard let root = try? JSONSerialization.jsonObject(with: Data(mf2JSON.utf8)) as? [String: Any] else {
                continue
            }
            for entry in hEntries(in: root) {
                guard let properties = entry["properties"] as? [String: Any] else { continue }
                items.append(item(fromProperties: properties, page: page, snapshot: snapshot))
            }
        }
        return (items, problems)
    }

    /// Finds every `h-entry` in a parsed mf2 document: top-level items, plus any nested one level
    /// down inside an `h-feed`'s `children`.
    ///
    /// - Parameter root: The top-level mf2 JSON object (`{"items":[…]}`).
    /// - Returns: The mf2 item objects whose `type` array contains `h-entry`.
    private static func hEntries(in root: [String: Any]) -> [[String: Any]] {
        guard let topLevel = root["items"] as? [[String: Any]] else { return [] }
        var entries: [[String: Any]] = []
        for mfItem in topLevel {
            if isType(mfItem, "h-entry") {
                entries.append(mfItem)
            } else if isType(mfItem, "h-feed"), let children = mfItem["children"] as? [[String: Any]] {
                entries.append(contentsOf: children.filter { isType($0, "h-entry") })
            }
        }
        return entries
    }

    /// Checks whether an mf2 item's `type` array contains the given microformat type.
    private static func isType(_ mfItem: [String: Any], _ type: String) -> Bool {
        (mfItem["type"] as? [String])?.contains(type) ?? false
    }

    /// Builds an `ImportItem` from an `h-entry`'s mf2 properties.
    private static func item(fromProperties properties: [String: Any], page: CapturedPage,
                              snapshot: ImportSnapshot) -> ImportItem {
        let name = firstStringValue(properties["name"])
        let title = (name?.isEmpty ?? true) ? nil : name

        let hint: ImportItem.Hint
        if let bookmarkOf = firstStringValue(properties["bookmark-of"]) {
            hint = .bookmark(of: bookmarkOf)
        } else if let likeOf = firstStringValue(properties["like-of"]) {
            hint = .like(of: likeOf)
        } else if let replyTo = firstStringValue(properties["in-reply-to"]) {
            hint = .reply(to: replyTo)
        } else if let photo = firstStringValue(properties["photo"]), isShortOrAbsentContent(properties["content"]) {
            hint = .photo(image: photo)
        } else if title == nil {
            hint = .note
        } else {
            hint = .article
        }

        let markdown = body(from: properties["content"], snapshot: snapshot) ?? page.extraction.markdown
        let published = firstStringValue(properties["published"]).flatMap(parseDate)
        let sourceURL = firstStringValue(properties["url"]) ?? page.url

        return ImportItem(sourceURL: ImportSnapshot.normalizeURL(sourceURL), title: title,
                          published: published, markdown: markdown, rung: .microformats, hint: hint)
    }

    /// Resolves an entry's body: HTML content converted to Markdown, else the plain-text content
    /// value, else `nil` (the caller falls back to the page's extracted Markdown).
    private static func body(from content: Any?, snapshot: ImportSnapshot) -> String? {
        guard let first = firstElement(of: content) else { return nil }
        if let html = htmlValue(first), let markdown = snapshot.markdown(forHTML: html) {
            return markdown
        }
        return stringValue(first)
    }

    /// Whether a `content` property is absent, or present but shorter than 50 characters — the
    /// signal that a `photo` property should win the hint over an `.article`/`.note` default.
    /// Length is measured on the plain-text `value` (mf2 always pairs an `html` form with a
    /// stripped `value` form for `content`), not the markup-bearing `html` form.
    private static func isShortOrAbsentContent(_ content: Any?) -> Bool {
        guard let first = firstElement(of: content) else { return true }
        let text = stringValue(first) ?? htmlValue(first) ?? ""
        return text.count < 50
    }

    /// Parses an ISO 8601 timestamp, trying both with and without fractional seconds.
    private static func parseDate(_ text: String) -> Date? {
        iso8601Formatter.date(from: text) ?? iso8601FractionalFormatter.date(from: text)
    }

    private nonisolated(unsafe) static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private nonisolated(unsafe) static let iso8601FractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// The first element of an mf2 property's array value, if any.
    private static func firstElement(of propertyArray: Any?) -> Any? {
        (propertyArray as? [Any])?.first
    }

    /// The first element of an mf2 property's array value, resolved to a plain string.
    private static func firstStringValue(_ propertyArray: Any?) -> String? {
        firstElement(of: propertyArray).flatMap(stringValue)
    }

    /// Resolves an mf2 property value to a plain string: either the value is itself a string, or
    /// it's an object carrying a `value` key (mf2's representation for a property with both a plain
    /// and an HTML form, e.g. `content`).
    ///
    /// - Parameter any: A single mf2 property value (one element of a property's array).
    /// - Returns: The plain-text form of the value, if one could be resolved.
    static func stringValue(_ any: Any) -> String? {
        if let string = any as? String { return string }
        if let dict = any as? [String: Any] { return dict["value"] as? String }
        return nil
    }

    /// Resolves an mf2 property value to its HTML form: the `html` key of a `{"value": …, "html":
    /// …}` object. Plain strings have no HTML form.
    ///
    /// - Parameter any: A single mf2 property value (one element of a property's array).
    /// - Returns: The HTML form of the value, if one is present.
    static func htmlValue(_ any: Any) -> String? {
        (any as? [String: Any])?["html"] as? String
    }
}
