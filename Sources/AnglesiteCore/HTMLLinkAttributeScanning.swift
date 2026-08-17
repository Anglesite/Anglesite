import Foundation

/// Shared HTML `<link>`/`<a>` tag and attribute scanning, factored out of
/// `WebmentionEndpointDiscovery` (webmention.org endpoint discovery) so `FeedEndpointDiscovery`
/// (#1483, RSS/Atom feed discovery for the blogroll's OPML export) can reuse the same
/// subtle regex/attribute-parsing logic instead of duplicating it. Neither caller's `rel`/`type`
/// matching predicate lives here — only the generic "find tags, read an attribute" machinery.
enum HTMLLinkAttributeScanning {
    /// Matches `<link ...>` and `<a ...>` tags in document order.
    ///
    /// Known, accepted limitation: `[^>]*` truncates the tag at the first literal `>`, including
    /// one embedded inside a quoted attribute value (e.g. `href="/x?a=1>2"`). A correct HTML
    /// tokenizer would track quote state to know that `>` isn't a tag terminator there. This is a
    /// conscious won't-fix, not an oversight — a literal, unencoded `>` inside an attribute value
    /// is invalid per the URL spec (it must be percent-encoded as `%3E`) and vanishingly rare in
    /// real-world markup; handling it would mean replacing this regex scan with a full tokenizer
    /// for a case that essentially never occurs.
    private static let tagPattern: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: #"<(?:link|a)\b([^>]*)>"#, options: [.caseInsensitive])
        } catch {
            fatalError("Invalid HTML link-tag scan regex: \(error)")
        }
    }()

    /// Returns each matched tag's raw attribute string, in document order.
    static func tagAttributeStrings(in html: String) -> [String] {
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return tagPattern.matches(in: html, range: range).compactMap { match in
            guard let attrsRange = Range(match.range(at: 1), in: html) else { return nil }
            return String(html[attrsRange])
        }
    }

    /// Extracts `name="value"` / `name='value'` / `name=value` from an HTML tag's attribute
    /// string or an HTTP Link-header parameter string. The lookahead-free anchor
    /// `(?:^|[\s;<])` before `name` requires the name to start at the beginning of the source,
    /// or be preceded by whitespace, a `;` (Link-header parameter separator), or `<` — so a
    /// lookup for `rel` does not match inside a longer attribute name like `data-rel=`. (A
    /// plain `\b` word-boundary anchor does *not* achieve this: `-` is a non-word character, so
    /// `\brel\b` still matches the `rel` inside `data-rel=`.)
    /// Cached compiled regexes for the three attribute names this scanner is actually called with —
    /// recompiling an `NSRegularExpression` on every `attributeValue(_:in:)` call was a real
    /// performance regression versus the pre-refactor `WebmentionEndpointDiscovery`, which cached
    /// its `rel`/`href` regexes as `static let`s. This scanner runs on every `<link>`/`<a>` tag on
    /// every target page, for both webmention discovery and (#1483) feed discovery.
    private static let relRegex = attributeRegex(for: "rel")
    private static let hrefRegex = attributeRegex(for: "href")
    private static let typeRegex = attributeRegex(for: "type")

    static func attributeValue(_ name: String, in source: String) -> String? {
        let regex: NSRegularExpression
        switch name {
        case "rel": regex = relRegex
        case "href": regex = hrefRegex
        case "type": regex = typeRegex
        default: regex = attributeRegex(for: name)
        }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = regex.firstMatch(in: source, range: range) else { return nil }
        for groupIndex in [2, 3, 4] {
            let group = match.range(at: groupIndex)
            if group.location != NSNotFound, let r = Range(group, in: source) {
                return String(source[r])
            }
        }
        return nil
    }

    private static func attributeRegex(for name: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(
                pattern: "(?:^|[\\s;<])\(name)\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+))",
                options: [.caseInsensitive]
            )
        } catch {
            fatalError("Invalid HTML attribute scan regex for \(name): \(error)")
        }
    }
}
