import CryptoKit
import Foundation

/// A snapshot of all content and metadata extracted from a website during the crawl phase.
public struct ImportSnapshot: Codable, Sendable, Equatable {
    /// The root URL of the website that was crawled.
    public var siteURL: String

    /// Site-level data probes: WordPress endpoints, feed links, etc.
    public var probes: SiteProbes

    /// All content pages extracted from the site.
    public var pages: [CapturedPage]

    /// All downloadable assets referenced by captured content.
    public var assets: [CapturedAsset]

    /// SHA-256 hex of a UTF-8 HTML string → the Markdown the capture engine produced for it.
    public var conversions: [String: String]

    /// Creates a snapshot with the given content and metadata.
    public init(siteURL: String, probes: SiteProbes, pages: [CapturedPage],
                assets: [CapturedAsset], conversions: [String: String]) {
        self.siteURL = siteURL
        self.probes = probes
        self.pages = pages
        self.assets = assets
        self.conversions = conversions
    }

    /// Computes the stable SHA-256 hex digest of a UTF-8 HTML string.
    public static func htmlKey(_ html: String) -> String {
        SHA256.hash(data: Data(html.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Looks up the Markdown for a given HTML string, if a conversion was recorded for it.
    public func markdown(forHTML html: String) -> String? {
        conversions[Self.htmlKey(html)]
    }

    /// Normalizes a URL: trims whitespace; lowercases scheme and host; drops fragment; drops a single
    /// trailing `/` unless the path is `/` or empty; keeps the query string.
    public static func normalizeURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else { return trimmed }
        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.path.count > 1, components.path.hasSuffix("/") {
            components.path = String(components.path.dropLast())
        }
        return components.string ?? trimmed
    }

    /// Finds a page by URL, matching against the page's canonical URL (if present) or its direct URL.
    public func page(forURL url: String) -> CapturedPage? {
        let key = Self.normalizeURL(url)
        return pages.first { Self.normalizeURL($0.extraction.canonical ?? $0.url) == key }
    }

    /// Finds an asset by its source URL.
    public func asset(forURL url: String) -> CapturedAsset? {
        let key = Self.normalizeURL(url)
        return assets.first { Self.normalizeURL($0.sourceURL) == key }
    }
}

/// Site-level metadata and discovery probes from a crawled website.
public struct SiteProbes: Codable, Sendable, Equatable {
    /// WordPress `/wp-json/wp/v2/posts` endpoint response, if the site exposes it.
    public var wpPostsJSON: String?

    /// WordPress `/wp-json/wp/v2/pages` endpoint response, if the site exposes it.
    public var wpPagesJSON: String?

    /// Feed autodiscovery links found in the site's `<head>`.
    public var feeds: [CapturedFeed]

    /// Creates a probes record with the given endpoints and feeds.
    public init(wpPostsJSON: String? = nil, wpPagesJSON: String? = nil, feeds: [CapturedFeed] = []) {
        self.wpPostsJSON = wpPostsJSON
        self.wpPagesJSON = wpPagesJSON
        self.feeds = feeds
    }
}

/// A single feed autodiscovery link.
public struct CapturedFeed: Codable, Sendable, Equatable {
    /// The `href` of the feed link (e.g., `https://example.com/feed/`).
    public var url: String

    /// The fetched feed body (XML or JSON).
    public var body: String

    /// Creates a feed record with the given URL and fetched body.
    public init(url: String, body: String) {
        self.url = url
        self.body = body
    }
}

/// A content page extracted from the website.
public struct CapturedPage: Codable, Sendable, Equatable {
    /// The page's URL as crawled.
    public var url: String

    /// The extraction result: title, byline, body, images, metadata, etc.
    public var extraction: ExtractionRecord

    /// Creates a page record with the given URL and extraction result.
    public init(url: String, extraction: ExtractionRecord) {
        self.url = url
        self.extraction = extraction
    }
}

/// The extraction result for a single page: title, body, dates, links, etc.
public struct ExtractionRecord: Codable, Sendable, Equatable {
    /// The page's title, if extracted.
    public var title: String?

    /// The page's author or byline, if extracted.
    public var byline: String?

    /// The publication date in ISO 8601 format, if extracted.
    public var publishedISO: String?

    /// The page's language code (e.g., `en`, `fr`), if detected.
    public var lang: String?

    /// The page's canonical URL, if declared.
    public var canonical: String?

    /// The main body content, converted to Markdown.
    public var markdown: String

    /// A short excerpt or summary, if extracted.
    public var excerpt: String?

    /// URLs of images embedded in the page content.
    public var images: [String]

    /// microformats2 JSON representation of the page, if extracted.
    public var mf2JSON: String?

    /// URLs of feed links discovered in the page's `<head>`.
    public var feedLinks: [String]

    /// Creates an extraction record with the given fields.
    public init(title: String? = nil, byline: String? = nil, publishedISO: String? = nil,
                lang: String? = nil, canonical: String? = nil, markdown: String,
                excerpt: String? = nil, images: [String] = [], mf2JSON: String? = nil,
                feedLinks: [String] = []) {
        self.title = title
        self.byline = byline
        self.publishedISO = publishedISO
        self.lang = lang
        self.canonical = canonical
        self.markdown = markdown
        self.excerpt = excerpt
        self.images = images
        self.mf2JSON = mf2JSON
        self.feedLinks = feedLinks
    }
}

/// A downloadable asset referenced by captured content.
public struct CapturedAsset: Codable, Sendable, Equatable {
    /// The original URL of the asset in the crawled website.
    public var sourceURL: String

    /// Path of the downloaded bytes relative to the snapshot directory (e.g., `assets/ab12….jpg`).
    public var relativePath: String

    /// Creates an asset record with the given source URL and relative path.
    public init(sourceURL: String, relativePath: String) {
        self.sourceURL = sourceURL
        self.relativePath = relativePath
    }
}
