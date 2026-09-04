import Foundation

/// Page metadata scraped from an HTML document's head, used to pre-fill the quick-capture
/// link-post compose sheet and `AddLinkPostIntent` (#531). All fields optional — a page with
/// no usable metadata yields an empty value, never a failure.
public struct LinkMetadata: Sendable, Equatable {
    public var title: String?
    public var description: String?
    public var siteName: String?
    /// The page's `og:image`, **exactly as the document spelled it** — which is often relative
    /// (`/card.png`) or protocol-relative (`//cdn/card.png`). Resolving it against the page URL
    /// needs a page URL, which the parser doesn't have; ``LinkMetadataFetcher`` does that on the
    /// way out (see its `resolvedImageURL(_:relativeTo:)`), so a fetched
    /// `LinkMetadata` always carries an absolute http(s) value here or none (#1451).
    public var imageURL: String?

    public init(title: String? = nil, description: String? = nil, siteName: String? = nil,
                imageURL: String? = nil) {
        self.title = title
        self.description = description
        self.siteName = siteName
        self.imageURL = imageURL
    }
}

/// Pure scanner from HTML text to ``LinkMetadata``: `og:title` / `og:description` /
/// `og:site_name` / `og:image` (via `property=` or `name=`), with `<title>` as the title's only
/// fallback. Deliberately not a
/// full HTML parser — article pages carry server-rendered `og:` tags in the head, and a regex
/// scan over `<meta>` tags is robust to attribute order and quote style without a WebKit
/// dependency (spec §3.1's case against `LPMetadataProvider`). Chosen over `NSAttributedString`'s
/// HTML importer, which spins up WebKit machinery and must run on the main thread.
public enum LinkMetadataParser {
    public static func parse(html: String) -> LinkMetadata {
        LinkMetadata(
            title: normalized(metaContent(in: html, key: "og:title") ?? titleText(in: html)),
            description: normalized(metaContent(in: html, key: "og:description")),
            siteName: normalized(metaContent(in: html, key: "og:site_name")),
            // No `<title>`-style fallback: a page with no `og:image` has no card image, and
            // guessing at some other `<img>` in the document would capture a logo or a tracking
            // pixel as often as the article's own artwork (#1451).
            imageURL: normalized(metaContent(in: html, key: "og:image"))
        )
    }

    /// The decoded `content` of the first `<meta>` whose `property` or `name` equals `key`.
    private static func metaContent(in html: String, key: String) -> String? {
        guard let tagRegex = try? NSRegularExpression(pattern: "<meta\\b[^>]*>", options: [.caseInsensitive]) else {
            return nil
        }
        let fullRange = NSRange(html.startIndex..., in: html)
        var result: String?
        tagRegex.enumerateMatches(in: html, range: fullRange) { match, _, stop in
            guard let match, let tagRange = Range(match.range, in: html) else { return }
            let tag = String(html[tagRange])
            let keyValue = attribute("property", in: tag) ?? attribute("name", in: tag)
            guard keyValue?.lowercased() == key else { return }
            if let content = attribute("content", in: tag) {
                result = content
                stop.pointee = true
            }
        }
        return result
    }

    private static func titleText(in html: String) -> String? {
        firstCapture(pattern: "<title[^>]*>(.*?)</title>", in: html).map(decodeEntities)
    }

    /// The decoded value of `name="…"` / `name='…'` inside one tag, regardless of attribute order.
    private static func attribute(_ name: String, in tag: String) -> String? {
        firstCapture(pattern: "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')", in: tag)
            .map(decodeEntities)
    }

    /// First non-empty capture group of `pattern`'s first match, or nil.
    private static func firstCapture(pattern: String, in text: String) -> String? {
        let options: NSRegularExpression.Options = [.caseInsensitive, .dotMatchesLineSeparators]
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        for group in 1..<match.numberOfRanges {
            if let range = Range(match.range(at: group), in: text) { return String(text[range]) }
        }
        return nil
    }

    /// Minimal HTML entity decoder: the named entities that actually appear in titles/descriptions
    /// plus numeric (`&#39;`) and hex (`&#x2019;`) forms. Unknown entities pass through verbatim.
    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            rest = rest[amp...]
            // Entity names are short; a far-away `;` means this `&` is literal.
            guard let semi = rest.firstIndex(of: ";"),
                  rest.distance(from: rest.startIndex, to: semi) <= 10,
                  let decoded = decodeEntity(rest[rest.index(after: rest.startIndex)..<semi])
            else {
                out += "&"
                rest = rest.dropFirst()
                continue
            }
            out += decoded
            rest = rest[rest.index(after: semi)...]
        }
        out += rest
        return out
    }

    private static func decodeEntity(_ entity: Substring) -> String? {
        switch entity {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return "\u{00A0}"
        default:
            guard entity.hasPrefix("#") else { return nil }
            let digits = entity.dropFirst()
            let value: UInt32? = digits.hasPrefix("x") || digits.hasPrefix("X")
                ? UInt32(digits.dropFirst(), radix: 16)
                : UInt32(digits)
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }
    }

    /// Trimmed; empty → nil.
    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
