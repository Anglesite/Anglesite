import Foundation

/// The WordPress REST extraction rung: decodes WordPress API posts and pages.
public enum WordPressRESTRung {
    private struct WPEntry: Decodable {
        struct Rendered: Decodable { var rendered: String }
        var link: String
        var date_gmt: String
        var title: Rendered
        var content: Rendered
        var excerpt: Rendered
    }

    /// Extracts items from WordPress REST API JSON in the snapshot.
    ///
    /// The REST payload carries no image inventory of its own, so each item's `images` come from
    /// the crawled page record for the same URL (`extraction.images`) — the list ``AssetLocalizer``
    /// needs to install the captured bytes into `public/images/` and rewrite the entry's remote
    /// image URLs. An entry with no matching crawled page contributes no images.
    ///
    /// - Parameter snapshot: The import snapshot containing WordPress REST JSON and HTML conversions.
    /// - Returns: A tuple containing extracted items and any problems encountered during extraction.
    public static func items(from snapshot: ImportSnapshot)
        -> (items: [ImportItem], problems: [ImportProblem]) {
        var items: [ImportItem] = []
        var problems: [ImportProblem] = []
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")

        for (json, hint) in [(snapshot.probes.wpPostsJSON, ImportItem.Hint.wpPost),
                             (snapshot.probes.wpPagesJSON, ImportItem.Hint.wpPage)] {
            guard let json else { continue }
            guard let entries = try? JSONDecoder().decode([WPEntry].self, from: Data(json.utf8)) else {
                problems.append(ImportProblem(sourceURL: snapshot.siteURL,
                                              message: "Unreadable WordPress API payload"))
                continue
            }
            for entry in entries {
                let page = snapshot.page(forURL: entry.link)
                let markdown = snapshot.markdown(forHTML: entry.content.rendered)
                    ?? page?.extraction.markdown
                guard let markdown else {
                    problems.append(ImportProblem(sourceURL: entry.link,
                                                  message: "No Markdown conversion for this entry"))
                    continue
                }
                items.append(ImportItem(
                    sourceURL: ImportSnapshot.normalizeURL(entry.link),
                    title: decodeHTMLEntities(entry.title.rendered),
                    published: formatter.date(from: entry.date_gmt),
                    markdown: markdown,
                    excerpt: snapshot.markdown(forHTML: entry.excerpt.rendered),
                    images: page?.extraction.images ?? [],
                    rung: .wpREST, hint: hint))
            }
        }
        return (items, problems)
    }
}

/// Decodes the five predefined XML entities plus decimal/hex numeric character references.
///
/// `&amp;` is decoded last, mirroring `ContentScanner.decodeHTMLEntities(_:)`, so that a
/// double-escaped entity like `&amp;lt;` (WordPress's rendering of a literal `&lt;` in a title)
/// becomes `&lt;` rather than being corrupted into `<` by an early, greedy `&amp;` pass.
func decodeHTMLEntities(_ value: String) -> String {
    var result = value
    for (entity, char) in [("&lt;", "<"), ("&gt;", ">"),
                           ("&quot;", "\""), ("&#039;", "'"), ("&apos;", "'")] {
        result = result.replacingOccurrences(of: entity, with: char)
    }
    while let range = result.range(of: "&#[xX]?[0-9a-fA-F]+;", options: .regularExpression) {
        let body = result[range].dropFirst(2).dropLast()
        let scalar: UInt32? = body.hasPrefix("x") || body.hasPrefix("X")
            ? UInt32(body.dropFirst(), radix: 16) : UInt32(body)
        let replacement = scalar.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ""
        result.replaceSubrange(range, with: replacement)
    }
    result = result.replacingOccurrences(of: "&amp;", with: "&")
    return result
}
