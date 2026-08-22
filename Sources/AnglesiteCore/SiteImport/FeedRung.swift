import Foundation

/// The feed extraction rung: decodes RSS 2.0, Atom, and JSON Feed documents.
public enum FeedRung {
    /// Extracts items from every captured feed in the snapshot.
    ///
    /// Feed format is detected per feed (JSON Feed if the body starts with `{`, otherwise RSS/Atom
    /// XML). Each entry's body HTML is converted via `snapshot.markdown(forHTML:)`. When the entry's
    /// URL matches a crawled page and the feed body looks like an excerpt — missing entirely, or
    /// less than half the length of the page's extracted Markdown — the page's Markdown is used
    /// instead, while the feed's title and publish date are kept.
    ///
    /// - Parameter snapshot: The import snapshot containing captured feeds, crawled pages, and HTML
    ///   conversions.
    /// - Returns: A tuple containing extracted items and any problems encountered during extraction.
    public static func items(from snapshot: ImportSnapshot)
        -> (items: [ImportItem], problems: [ImportProblem]) {
        var items: [ImportItem] = []
        var problems: [ImportProblem] = []
        for feed in snapshot.probes.feeds {
            let entries: [RawFeedEntry]
            if feed.body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
                entries = JSONFeedParser.entries(from: feed.body)
            } else {
                entries = FeedXMLParser.entries(from: feed.body)
            }
            if entries.isEmpty {
                problems.append(ImportProblem(sourceURL: feed.url, message: "Feed could not be read"))
            }
            for entry in entries {
                guard let url = entry.url else {
                    problems.append(ImportProblem(sourceURL: feed.url, message: "Feed entry without a link"))
                    continue
                }
                var markdown = entry.bodyHTML.flatMap(snapshot.markdown(forHTML:))
                if let page = snapshot.page(forURL: url) {
                    let pageMarkdown = page.extraction.markdown
                    if markdown == nil || markdown!.count * 2 < pageMarkdown.count {
                        // Excerpt-only feed: body comes from the crawled page; metadata stays the feed's.
                        markdown = pageMarkdown
                    }
                }
                guard let markdown else {
                    problems.append(ImportProblem(sourceURL: url, message: "No Markdown conversion for this entry"))
                    continue
                }
                items.append(ImportItem(sourceURL: ImportSnapshot.normalizeURL(url),
                                        title: entry.title, published: entry.published,
                                        markdown: markdown, rung: .feed, hint: .none))
            }
        }
        return (items, problems)
    }
}

/// An entry decoded from a feed, before Markdown resolution and URL validation.
struct RawFeedEntry {
    /// The entry's link, if the feed declared one.
    var url: String?
    /// The entry's title, if the feed declared one.
    var title: String?
    /// The entry's publish date, if the feed declared one.
    var published: Date?
    /// The entry's body, as HTML, if the feed declared one.
    var bodyHTML: String?
}

/// Decodes JSON Feed (1.0/1.1) documents into raw entries.
enum JSONFeedParser {
    private struct Feed: Decodable {
        struct Item: Decodable {
            var url: String?
            var title: String?
            var date_published: String?
            var content_html: String?
        }
        var items: [Item]
    }

    /// Decodes the entries of a JSON Feed document.
    ///
    /// - Parameter body: The raw JSON Feed document text.
    /// - Returns: The decoded entries, or an empty array if the document could not be parsed.
    static func entries(from body: String) -> [RawFeedEntry] {
        guard let feed = try? JSONDecoder().decode(Feed.self, from: Data(body.utf8)) else { return [] }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return feed.items.map { item in
            let published = item.date_published.flatMap { formatter.date(from: $0) ?? fractionalFormatter.date(from: $0) }
            return RawFeedEntry(url: item.url, title: item.title, published: published, bodyHTML: item.content_html)
        }
    }
}

/// Parses RSS 2.0 and Atom XML documents into raw entries via `XMLParser`.
///
/// A single delegate handles both formats since their element names don't collide (`item`/`entry`,
/// `pubDate`/`published`/`updated`, `description`/`content`/`summary`).
final class FeedXMLParser: NSObject, XMLParserDelegate {
    /// Parses the entries of an RSS 2.0 or Atom XML document.
    ///
    /// - Parameter body: The raw XML document text.
    /// - Returns: The decoded entries, or an empty array if the document could not be parsed.
    static func entries(from body: String) -> [RawFeedEntry] {
        let delegate = FeedXMLParser()
        let parser = XMLParser(data: Data(body.utf8))
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.entries
    }

    private var entries: [RawFeedEntry] = []
    private var current: RawFeedEntry?
    private var textBuffer = ""
    private var contentEncodedText: String?
    private var descriptionText: String?
    private var contentText: String?
    private var summaryText: String?
    private var linkURL: String?
    private var linkIsAlternate = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = localName(qName ?? elementName)
        textBuffer = ""

        if name == "item" || name == "entry" {
            current = RawFeedEntry()
            contentEncodedText = nil
            descriptionText = nil
            contentText = nil
            summaryText = nil
            linkURL = nil
            linkIsAlternate = false
            return
        }
        guard current != nil, name == "link" else { return }
        // Atom: <link rel="alternate" href="..."/>; RSS: <link>text</link> (no attributes).
        if let href = attributeDict["href"] {
            let rel = attributeDict["rel"] ?? "alternate"
            if linkURL == nil || (rel == "alternate" && !linkIsAlternate) {
                linkURL = href
                linkIsAlternate = rel == "alternate"
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        textBuffer += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let name = localName(qName ?? elementName)
        guard current != nil else { return }
        let text = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)

        switch name {
        case "item", "entry":
            if var entry = current {
                entry.url = linkURL ?? entry.url
                entry.bodyHTML = contentEncodedText ?? descriptionText ?? contentText ?? summaryText
                entries.append(entry)
            }
            current = nil
        case "title":
            current?.title = text
        case "link" where !text.isEmpty:
            // RSS: plain text node inside <link>...</link>.
            if linkURL == nil { linkURL = text }
        case "pubDate":
            if current?.published == nil {
                current?.published = Self.rfc822Formatter.date(from: text) ?? Self.rfc822ZoneNameFormatter.date(from: text)
            }
        case "published", "updated":
            if name == "published" || current?.published == nil {
                current?.published = Self.parseISO8601(text) ?? current?.published
            }
        case "content:encoded":
            contentEncodedText = text
        case "description":
            descriptionText = text
        case "content":
            contentText = text
        case "summary":
            summaryText = text
        default:
            break
        }
    }

    /// Strips an XML namespace prefix (e.g. `content:encoded` keeps its prefix deliberately, since
    /// it's the marker RSS uses to distinguish full content from `description`; every other
    /// namespaced element is matched on its local name only).
    private func localName(_ qualified: String) -> String {
        if qualified == "content:encoded" { return qualified }
        guard let colonIndex = qualified.firstIndex(of: ":") else { return qualified }
        return String(qualified[qualified.index(after: colonIndex)...])
    }

    private nonisolated(unsafe) static let rfc822Formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    /// Fallback for RFC822 dates using a literal zone name (`GMT`, `UT`, `EST`, …) instead of a
    /// numeric offset — common in feeds from WordPress, Blogger, and other RSS generators, and not
    /// matched by `rfc822Formatter`'s `Z` specifier.
    private nonisolated(unsafe) static let rfc822ZoneNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    /// Parses an ISO 8601 timestamp, trying both with and without fractional seconds since Atom
    /// feeds emit either form.
    private static func parseISO8601(_ text: String) -> Date? {
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
}
