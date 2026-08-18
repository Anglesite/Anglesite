import Foundation

/// The licenses the Content Licensing facet offers, and how each relates to the site's AI usage
/// permissions (#991) and to the first-publish license gate's "AI systems" comparison column
/// (#999).
///
/// The classification is deliberately narrow. Whether model training is a "derivative work" or a
/// "commercial use" is a live legal question, so only licenses whose grant unambiguously covers
/// any use are marked `.permits`; NC and ND variants, custom URLs, and all-rights-reserved get
/// `.unclear` unless a specific, defensible case exists to mark them otherwise (as
/// `allRightsReservedInterpretation` below does — an unlicensed work grants no permission by
/// construction, which is not the same live question NC/ND raise about an *existing* grant's
/// scope). That follows the spike's rule that Anglesite never asserts on the user's behalf — see
/// docs/superpowers/specs/2026-07-26-really-simple-licensing-spike.md §Q3.
public enum LicenseCatalog {
    /// How Anglesite reads a license's grant with respect to AI training/use. Three states, not
    /// two, so "we don't know" and "this affirmatively grants nothing" stay distinguishable —
    /// collapsing them back into a bool is what the #999 expansion was asked to stop doing.
    public enum AIInterpretation: String, Sendable, Equatable, CaseIterable {
        /// The license's grant unambiguously covers AI training and AI answers.
        case permits
        /// Not classified — the grant's scope with respect to AI use is a live legal question
        /// Anglesite declines to resolve on the user's behalf.
        case unclear
        /// No permission is granted at all (the all-rights-reserved default) — distinct from
        /// `.unclear`, which is about the *scope* of a grant that does exist.
        case prohibits
    }

    /// One offered license: stable picker identity, display strings, and the app-side AI-use
    /// classification (which is deliberately *not* part of what gets stored — see `ref`).
    public struct Entry: Sendable, Equatable, Hashable, Identifiable {
        /// Stable across releases — it is the SwiftUI picker tag, not display text.
        public let id: String
        /// Display name shown in the picker, e.g. "CC BY 4.0".
        public let name: String
        /// Canonical deed URL — the identity `entry(for:)` matches stored licenses on.
        public let url: String
        /// How this license's grant reads with respect to AI training and AI answers.
        public let aiInterpretation: AIInterpretation

        /// The `LicenseRef` this entry stores and publishes — URL + name only. The
        /// `aiInterpretation` classification stays app-side, because it is Anglesite's reading of
        /// the license, not something to assert on the user's behalf (see the type doc).
        public var ref: LicenseRef { LicenseRef(url: url, name: name) }
    }

    /// The offered licenses in picker order: CC0 first, then the CC 4.0 suite from most to least
    /// permissive. Extending this list requires the same "unambiguous grant" test the type doc
    /// describes before marking an entry `.permits`.
    public static let entries: [Entry] = [
        Entry(id: "cc0-1.0", name: "CC0 1.0",
              url: "https://creativecommons.org/publicdomain/zero/1.0/", aiInterpretation: .permits),
        Entry(id: "cc-by-4.0", name: "CC BY 4.0",
              url: "https://creativecommons.org/licenses/by/4.0/", aiInterpretation: .permits),
        Entry(id: "cc-by-sa-4.0", name: "CC BY-SA 4.0",
              url: "https://creativecommons.org/licenses/by-sa/4.0/", aiInterpretation: .permits),
        Entry(id: "cc-by-nc-4.0", name: "CC BY-NC 4.0",
              url: "https://creativecommons.org/licenses/by-nc/4.0/", aiInterpretation: .unclear),
        Entry(id: "cc-by-nd-4.0", name: "CC BY-ND 4.0",
              url: "https://creativecommons.org/licenses/by-nd/4.0/", aiInterpretation: .unclear),
        Entry(id: "cc-by-nc-sa-4.0", name: "CC BY-NC-SA 4.0",
              url: "https://creativecommons.org/licenses/by-nc-sa/4.0/", aiInterpretation: .unclear),
        Entry(id: "cc-by-nc-nd-4.0", name: "CC BY-NC-ND 4.0",
              url: "https://creativecommons.org/licenses/by-nc-nd/4.0/", aiInterpretation: .unclear),
    ]

    /// "All rights reserved" — the untouched-scaffold default — is not a catalog entry (it has no
    /// URL), but the first-publish gate's comparison table asks the same interpretation question
    /// about it. An unlicensed work grants no permission under copyright law absent a stated TDM
    /// exception, so this is `.prohibits` rather than `.unclear`: unlike NC/ND (a live question
    /// about how far an *existing* grant reaches), there is no grant here to be uncertain about.
    public static let allRightsReservedInterpretation: AIInterpretation = .prohibits

    /// A custom (non-catalog) license's grant is unknown by construction — Anglesite has never
    /// read its text, so this is always `.unclear`, never guessed at.
    public static let customLicenseInterpretation: AIInterpretation = .unclear

    /// The catalog entry a stored license refers to, matched on URL — a hand-edited `name` should
    /// not stop the picker recognizing a standard license. nil means custom or none.
    public static func entry(for license: LicenseRef?) -> Entry? {
        guard let license else { return nil }
        return entries.first { $0.url == license.url }
    }

    /// Suggests AI permissions consistent with a newly-chosen license, filling **only** purposes
    /// the user has not stated. Overwriting a stated purpose would silently discard a deliberate
    /// choice, so this never does; an unclassified license suggests nothing at all.
    public static func prefilled(_ usage: AIUsage, for license: LicenseRef?) -> AIUsage {
        guard entry(for: license)?.aiInterpretation == .permits else { return usage }
        var filled = usage
        if filled.search == .unset { filled.search = .yes }
        if filled.aiInput == .unset { filled.aiInput = .yes }
        if filled.aiTrain == .unset { filled.aiTrain = .yes }
        return filled
    }

    /// Why the facet should show an inline note, or nil when there is nothing to say. The typed
    /// case (rather than a `String`) keeps user-facing copy in the app module where Xcode's string
    /// extraction can reach it.
    public enum CoherenceWarning: Sendable, Equatable {
        /// The site default license already grants an AI use the policy asks crawlers not to make.
        case licensePermitsDeniedUse(licenseName: String)
    }

    /// Fires only for a classified license against a denied AI purpose — the one contradiction
    /// detectable without interpreting license text. Permitting *more* than a restrictive license
    /// requires is never flagged: it is the user's own content, and they may grant what they like.
    /// `search` is not an AI purpose and never triggers this.
    public static func coherenceWarning(for license: LicenseRef?, usage: AIUsage) -> CoherenceWarning? {
        guard let entry = entry(for: license), entry.aiInterpretation == .permits else { return nil }
        guard usage.aiInput == .no || usage.aiTrain == .no else { return nil }
        return .licensePermitsDeniedUse(licenseName: entry.name)
    }
}
