import Foundation

/// Homepage-derived seed values for a site's `.site-config` file.
public struct SiteConfigSeeds: Codable, Sendable, Equatable {
    /// The site's display name, derived from the homepage title.
    public var siteName: String?

    /// The site's tagline or description, derived from the homepage excerpt.
    public var tagline: String?

    /// The site's language code, derived from the homepage's detected language.
    public var lang: String?

    /// Creates seed values for `.site-config`.
    ///
    /// - Parameters:
    ///   - siteName: The site's display name, if known.
    ///   - tagline: The site's tagline or description, if known.
    ///   - lang: The site's language code, if known.
    public init(siteName: String? = nil, tagline: String? = nil, lang: String? = nil) {
        self.siteName = siteName
        self.tagline = tagline
        self.lang = lang
    }
}

/// Derives `.site-config` seed values from an imported site's homepage and applies them to
/// existing `.site-config` text.
public enum ImportSiteConfig {
    /// Delimiters that separate a homepage `<title>`'s leading site name from a trailing
    /// suffix (tagline, or a second copy of the site name). Each is space-hyphen-space (or an
    /// em/en-dash variant) so a bare hyphen inside a word, like "Well-Known", is never split.
    private static let titleSuffixDelimiters = [" — ", " – ", " | ", " - "]

    /// Derives `.site-config` seed values from a site's imported homepage.
    ///
    /// The capture engine's `extraction.title` can still carry the raw `<title>` tag's trailing
    /// site-name suffix (e.g. "Hello — My Site") when Readability falls back to it instead of
    /// isolating the article headline — a known upstream behavior (ledgered in Task 2). For a
    /// homepage this is the opposite problem: its `<title>` is typically "SiteName — Tagline" or
    /// just "SiteName", so `siteName` here strips a suffix delimited by " — ", " – ", " | ", or
    /// " - " (space-hyphen-space; a bare hyphen inside a word is never split) and keeps only the
    /// first segment.
    ///
    /// - Parameter homepage: The site's homepage page, if the crawl found one.
    /// - Returns: Seed values with `siteName` from the (de-suffixed) title, `tagline` from the
    ///   excerpt, and `lang` from the detected language — or all-`nil` seeds when `homepage` is
    ///   `nil`.
    public static func seeds(fromHomepage homepage: CapturedPage?) -> SiteConfigSeeds {
        guard let homepage else { return SiteConfigSeeds() }
        return SiteConfigSeeds(
            siteName: firstTitleSegment(of: homepage.extraction.title),
            tagline: homepage.extraction.excerpt,
            lang: homepage.extraction.lang
        )
    }

    /// Replaces or appends `KEY="value"` lines in `.site-config` text for each non-`nil` field
    /// of `seeds`.
    ///
    /// - Parameters:
    ///   - seeds: The seed values to apply. A `nil` field leaves its key untouched.
    ///   - text: The existing `.site-config` file contents.
    /// - Returns: The updated text. `siteName`, `tagline`, and `lang` map to `SITE_NAME`,
    ///   `TAGLINE`, and `LANG` respectively. An existing `KEY=…` line is replaced in place; a
    ///   commented `#KEY=…` line counts as absent, is left untouched, and the key is appended
    ///   at the end instead. Values are double-quoted with embedded `"` escaped. All other
    ///   lines and comments are preserved byte-for-byte. Applying the same seeds twice produces
    ///   the same text as applying them once.
    public static func apply(_ seeds: SiteConfigSeeds, toConfigText text: String) -> String {
        let assignments: [(key: String, value: String?)] = [
            ("SITE_NAME", seeds.siteName),
            ("TAGLINE", seeds.tagline),
            ("LANG", seeds.lang),
        ]
        var pendingValues = Dictionary(uniqueKeysWithValues: assignments.compactMap { key, value in
            value.map { (key, $0) }
        })
        guard !pendingValues.isEmpty else { return text }

        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }

        for index in lines.indices {
            guard let key = assignedKey(inLine: lines[index]), let value = pendingValues[key] else { continue }
            lines[index] = "\(key)=\(quoted(value))"
            pendingValues.removeValue(forKey: key)
        }

        for (key, value) in assignments {
            guard let value, pendingValues[key] != nil else { continue }
            lines.append("\(key)=\(quoted(value))")
        }

        guard !lines.isEmpty else { return text }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Strips a title-suffix delimiter (see ``seeds(fromHomepage:)``) from a homepage title,
    /// keeping only the first segment.
    private static func firstTitleSegment(of title: String?) -> String? {
        guard let title else { return nil }
        let earliestDelimiterRange = titleSuffixDelimiters
            .compactMap { title.range(of: $0) }
            .min { $0.lowerBound < $1.lowerBound }
        guard let range = earliestDelimiterRange else { return title }
        return String(title[title.startIndex..<range.lowerBound])
    }

    /// The `KEY` of an active (non-commented) `KEY=…` line, or `nil` if the line is a comment
    /// or has no `=`.
    private static func assignedKey(inLine line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let equalsIndex = trimmed.firstIndex(of: "=") else { return nil }
        return String(trimmed[trimmed.startIndex..<equalsIndex])
    }

    /// Double-quotes a value for a `.site-config` line, escaping embedded `"` characters.
    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
