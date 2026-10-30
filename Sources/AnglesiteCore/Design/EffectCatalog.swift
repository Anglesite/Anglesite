// Sources/AnglesiteCore/Design/EffectCatalog.swift
import Foundation

/// One curated entry from the template's `integrations/effects.json` manifest — either a legacy
/// `@astroanimate/core` micro-animation (no `placement`, copy-paste only) or a hand-authored
/// visual effect with a real `src/components/effects/*.astro` file in every site (`placement`
/// non-nil, placeable via the click-to-place flow). Foundation-only: the Linux CI lane builds
/// AnglesiteCore, so no AppKit/Darwin-only APIs belong here — the AppKit-facing gallery UI lives
/// in `Sources/AnglesiteApp/EffectsGalleryView.swift`.
public struct EffectCatalogEntry: Sendable, Codable, Identifiable, Hashable {
    /// `Identifiable` conformance for SwiftUI lists — the component export name, which the
    /// manifest keeps unique, so no separate id field is needed.
    public var id: String { component }
    /// The component's export/tag name (e.g. `FadeInText`, `ParticleField`) — the stable key
    /// everything else (demo pages, snippets, blocks.manifest lookups) derives from.
    public let component: String
    /// Short human title shown in the gallery grid.
    public let title: String
    /// Plain-language description written for site owners, not developers.
    public let ownerDescription: String
    /// Which gallery section the entry belongs to.
    public let category: EffectCategory
    /// The props worth tuning, mapped to a human hint about each — display strings for the
    /// gallery, not machine-readable defaults.
    public let keyProps: [String: String]
    /// Ready-to-paste Astro usage snippet, import line included.
    public let snippet: String
    /// How this effect gets deterministically inserted, or `nil` for a legacy library-backed
    /// micro-animation with no local component file to place.
    public let placement: Placement?
    /// Everyday phrasings an owner might use to describe what a visitor sees ("text fades in"),
    /// matched by ``EffectCatalog/search(_:)``. Optional in the manifest — a missing key is `[]`.
    public let aliases: [String]

    public init(component: String, title: String, ownerDescription: String, category: EffectCategory, keyProps: [String: String], snippet: String, placement: Placement? = nil, aliases: [String] = []) {
        self.component = component
        self.title = title
        self.ownerDescription = ownerDescription
        self.category = category
        self.keyProps = keyProps
        self.snippet = snippet
        self.placement = placement
        self.aliases = aliases
    }

    private enum CodingKeys: String, CodingKey {
        case component, title, ownerDescription, category, keyProps, snippet, placement, aliases
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        component = try c.decode(String.self, forKey: .component)
        title = try c.decode(String.self, forKey: .title)
        ownerDescription = try c.decode(String.self, forKey: .ownerDescription)
        category = try c.decode(EffectCategory.self, forKey: .category)
        keyProps = try c.decode([String: String].self, forKey: .keyProps)
        snippet = try c.decode(String.self, forKey: .snippet)
        placement = try c.decodeIfPresent(Placement.self, forKey: .placement)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
    }

    /// Insertion behavior for a placeable effect.
    public struct Placement: Sendable, Codable, Hashable {
        public let kind: Kind
        /// Tag allowlist for the click-to-place target's parent; `nil` means any element.
        public let allowedParents: [String]?

        public init(kind: Kind, allowedParents: [String]?) {
            self.kind = kind
            self.allowedParents = allowedParents
        }

        /// `inline`: insert before/after the clicked element. `background`: insert as the first
        /// child of the clicked element's *parent*, behind it.
        public enum Kind: String, Sendable, Codable, Hashable {
            case inline
            case background
        }
    }
}

/// `category` values from the manifest schema. The first five are legacy `@astroanimate/core`
/// micro-animations (unchanged from the original `AnimationCategory`); the last four are the new
/// hand-authored visual effects (#768).
public enum EffectCategory: String, Sendable, Codable, CaseIterable, Hashable {
    case text
    case cards
    case buttons
    case backgrounds
    case navigation
    case canvasBackground
    case cursorReactive
    case scrollDriven
    case generativeArt
}

/// Decodes the template's curated Effects catalog and locates its prerendered demo pages.
public struct EffectCatalog: Sendable {
    /// Every curated entry, preserving manifest order — the template's curation order *is* the
    /// gallery's display order, so no re-sorting happens app-side.
    public let entries: [EffectCatalogEntry]

    /// Wraps an already-decoded entry list — mirrors `ThemeCatalog.init(themes:)`. Production
    /// loads via ``load(templateDirectory:)``; `Bootstrap.swift` uses this directly for the
    /// empty fallback when the bundled template can't be resolved.
    public init(entries: [EffectCatalogEntry]) {
        self.entries = entries
    }

    /// Mirrors the manifest's top-level shape (`{ "version": 2, "components": [...] }`); only
    /// `components` is consumed today.
    private struct ManifestFile: Codable {
        let version: Int
        let components: [EffectCatalogEntry]
    }

    /// Decodes `templateDirectory/integrations/effects.json`.
    public static func load(templateDirectory: URL) throws -> EffectCatalog {
        let manifestURL = templateDirectory.appendingPathComponent("integrations/effects.json")
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(ManifestFile.self, from: data)
        return EffectCatalog(entries: manifest.components)
    }

    /// Curated entries in `category`, in manifest order.
    public func entries(in category: EffectCategory) -> [EffectCatalogEntry] {
        entries.filter { $0.category == category }
    }

    /// The prerendered demo page for `component`: `integrations/effects-demos/<component>.html`
    /// under the same template root.
    public static func demoURL(templateDirectory: URL, component: String) -> URL {
        templateDirectory.appendingPathComponent("integrations/effects-demos/\(component).html")
    }

    // MARK: - Search (#2180)

    private static let stopWords: Set<String> = [
        "a", "an", "and", "at", "by", "for", "in", "is", "it", "its", "my", "of", "on", "one", "the", "to", "with",
    ]

    /// Folds case/diacritics, splits on non-alphanumerics, drops stop words, and lightly stems.
    private static func tokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !stopWords.contains($0) }
            .map(stem)
    }

    /// Strips one of `ing`, `ed`, `es`, `ly`, `s` (first match, in that order) when at least
    /// three characters remain, then a trailing `e` from words longer than three characters.
    private static func stem(_ token: String) -> String {
        var result = token
        for suffix in ["ing", "ed", "es", "ly", "s"] where token.hasSuffix(suffix) {
            let stem = String(token.dropLast(suffix.count))
            if stem.count >= 3 { result = stem; break }
        }
        // "wipe"/"wipes"/"wiping" must share a root, so also drop a trailing silent "e".
        if result.count > 3, result.hasSuffix("e") { result.removeLast() }
        return result
    }

    /// Deterministic plain-language search over titles, aliases and owner descriptions.
    ///
    /// Each distinct query token scores its best match: an exact stemmed token in the title or an
    /// alias is worth 3, in the description 1; a prefix match (query token of three or more
    /// characters) is worth half. Results are sorted by score, ties in manifest order. A query with
    /// no meaningful tokens returns every entry in manifest order.
    public func search(_ query: String) -> [EffectCatalogEntry] {
        var seen = Set<String>()
        let queryTokens = Self.tokens(query).filter { seen.insert($0).inserted }
        guard !queryTokens.isEmpty else { return entries }

        let scored: [(index: Int, score: Double, entry: EffectCatalogEntry)] = entries.enumerated().compactMap { index, entry in
            let strong = Set(Self.tokens(entry.title) + entry.aliases.flatMap(Self.tokens))
            let weak = Set(Self.tokens(entry.ownerDescription))
            var total = 0.0
            for token in queryTokens {
                var best = 0.0
                if strong.contains(token) { best = 3 }
                else if weak.contains(token) { best = 1 }
                if best < 3, token.count >= 3 {
                    if strong.contains(where: { $0.hasPrefix(token) }) { best = max(best, 1.5) }
                    else if weak.contains(where: { $0.hasPrefix(token) }) { best = max(best, 0.5) }
                }
                total += best
            }
            return total > 0 ? (index, total, entry) : nil
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }.map(\.entry)
    }
}
