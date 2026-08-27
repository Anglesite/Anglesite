import Foundation
// XMLParser/XMLParserDelegate live in FoundationXML on non-Darwin platforms
// (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationXML)
import FoundationXML
#endif

/// One `<item>` from a WordPress eXtended RSS (WXR) export — the file WordPress's own "Export"
/// screen and Cloudflare's EmDash Exporter plugin both produce (#1636). `WXRParser` decodes every
/// `<item>` regardless of type or status; filtering to published posts/pages and mapping to
/// ``ImportItem/Hint`` is ``WXRRung``'s job, mirroring how the other rungs keep structural
/// decoding separate from classification.
public struct WXREntry: Sendable, Equatable {
    /// The post/page title (`<title>`), HTML-entity-decoded the same way `WordPressRESTRung`
    /// decodes REST titles.
    public var title: String?
    /// The canonical URL of the post/page (`<link>`).
    public var link: String
    /// WordPress's post type (`<wp:post_type>`): `"post"`, `"page"`, `"attachment"`,
    /// `"nav_menu_item"`, etc.
    public var postType: String
    /// WordPress's publish status (`<wp:status>`): `"publish"`, `"draft"`, `"private"`,
    /// `"trash"`, `"inherit"` (attachments), etc.
    public var status: String
    /// The publish date, parsed from `<wp:post_date_gmt>` (preferred) or `<pubDate>` (fallback)
    /// — `nil` if neither parses. WordPress writes the sentinel `"0000-00-00 00:00:00"` for
    /// `post_date_gmt` on content that was never actually published with a real date.
    public var published: Date?
    /// The rendered post/page body (`<content:encoded>`), unwrapped from its CDATA section.
    public var contentEncoded: String
    /// The rendered excerpt (`<excerpt:encoded>`), unwrapped from its CDATA section — `nil` if
    /// absent or empty.
    public var excerptEncoded: String?

    public init(title: String?, link: String, postType: String, status: String,
                published: Date?, contentEncoded: String, excerptEncoded: String?) {
        self.title = title
        self.link = link
        self.postType = postType
        self.status = status
        self.published = published
        self.contentEncoded = contentEncoded
        self.excerptEncoded = excerptEncoded
    }
}

/// The parsed `<channel>` header of a WXR file: the site-level metadata WordPress's exporter
/// writes once, above the per-item `<item>` elements.
public struct WXRChannel: Sendable, Equatable {
    /// The exporting site's title (`<channel><title>`) — a candidate name for the new package.
    public var title: String?
    /// The exporting site's URL (`<channel><link>`).
    public var link: String?

    public init(title: String?, link: String?) {
        self.title = title
        self.link = link
    }
}

/// A file couldn't be parsed as WXR — malformed XML, or well-formed XML with no `<channel>`
/// (not a WordPress export at all).
public struct WXRParseError: Error, Equatable {
    public var message: String
    public init(message: String) { self.message = message }
}

/// Parses a WordPress eXtended RSS (WXR) export file into its channel header and item entries
/// (#1636). Pure structural decoding over `Foundation.XMLParser` — no XML library dependency,
/// portable to the Linux `AnglesiteCore` target.
public enum WXRParser {
    /// Parses `data` as a WXR document.
    /// - Parameter data: The raw bytes of the `.xml` export file.
    /// - Returns: The channel header and every `<item>`, in document order.
    /// - Throws: ``WXRParseError`` if the data isn't well-formed XML, or has no `<channel>`.
    public static func parse(_ data: Data) throws -> (channel: WXRChannel, entries: [WXREntry]) {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            let underlying = delegate.parseError ?? parser.parserError
            throw WXRParseError(message: underlying?.localizedDescription ?? "Malformed XML")
        }
        guard delegate.sawChannel else {
            throw WXRParseError(message: "No <channel> element — this doesn't look like a WXR export")
        }
        return (delegate.channel, delegate.entries)
    }

    /// SQL-datetime format WordPress writes `<wp:post_date_gmt>` in, e.g. `"2024-05-01 10:00:00"`
    /// — always UTC, no timezone marker in the text itself.
    private static let gmtFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// RFC 822 format `<pubDate>` is written in, e.g. `"Wed, 01 May 2024 10:00:00 +0000"`.
    private static let rfc822Formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Parses `gmtText`/`pubDateText` in that preference order, treating WordPress's
    /// never-published sentinel (`"0000-00-00 00:00:00"`) as absent.
    fileprivate static func published(gmtText: String?, pubDateText: String?) -> Date? {
        if let gmtText, gmtText != "0000-00-00 00:00:00", let date = gmtFormatter.date(from: gmtText) {
            return date
        }
        if let pubDateText, let date = rfc822Formatter.date(from: pubDateText) {
            return date
        }
        return nil
    }

    /// `XMLParserDelegate` accumulator. WXR's `<content:encoded>`/`<excerpt:encoded>` fields
    /// arrive CDATA-wrapped, which `Foundation.XMLParser` only delivers via `foundCDATA` — NOT
    /// `foundCharacters` — so both must feed the same buffer or every CDATA-wrapped field would
    /// silently come back empty. Matches elements by (tag, immediate parent) rather than tracking
    /// an ad hoc "inside item" flag, so a channel-level `<title>`/`<link>` never collides with an
    /// item's, and neither collides with an RSS `<image>` block's own nested `<title>`/`<link>`.
    private final class Delegate: NSObject, XMLParserDelegate {
        var channel = WXRChannel(title: nil, link: nil)
        var sawChannel = false
        var entries: [WXREntry] = []
        var parseError: Error?

        private var path: [String] = []
        private var buffer = ""
        private var current: (title: String?, link: String?, postType: String?, status: String?,
                              gmt: String?, pubDate: String?, content: String, excerpt: String)?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                   qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            path.append(elementName)
            buffer = ""
            if elementName == "channel" { sawChannel = true }
            if elementName == "item" { current = (nil, nil, nil, nil, nil, nil, "", "") }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            buffer += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            buffer += String(data: CDATABlock, encoding: .utf8) ?? ""
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                   qualifiedName qName: String?) {
            defer { path.removeLast() }
            let parent = path.dropLast().last
            switch (elementName, parent) {
            case ("title", "channel"): channel.title = buffer
            case ("link", "channel"): channel.link = buffer
            case ("title", "item"): current?.title = buffer
            case ("link", "item"): current?.link = buffer
            case ("wp:post_type", "item"): current?.postType = buffer
            case ("wp:status", "item"): current?.status = buffer
            case ("pubDate", "item"): current?.pubDate = buffer
            case ("wp:post_date_gmt", "item"): current?.gmt = buffer
            case ("content:encoded", "item"): current?.content = buffer
            case ("excerpt:encoded", "item"): current?.excerpt = buffer
            case ("item", _):
                if let c = current, let link = c.link, !link.isEmpty,
                   let postType = c.postType, let status = c.status {
                    entries.append(WXREntry(
                        title: c.title.map(decodeHTMLEntities), link: link, postType: postType,
                        status: status,
                        published: WXRParser.published(gmtText: c.gmt, pubDateText: c.pubDate),
                        contentEncoded: c.content,
                        excerptEncoded: (c.excerpt.isEmpty ? nil : c.excerpt)))
                }
                current = nil
            default: break
            }
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
            self.parseError = parseError
        }
    }
}
