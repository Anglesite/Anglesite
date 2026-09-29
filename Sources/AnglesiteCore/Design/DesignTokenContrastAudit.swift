import Foundation

/// One unreadable token pairing found by ``DesignTokenContrastAudit`` (#2021). Deliberately not an
/// `AuditReport.Finding`: it arrives before any build exists and lives in the theme wizard's own
/// view state.
public struct DesignTokenContrastFinding: Sendable, Equatable, Identifiable {
    /// How urgently the pairing needs fixing.
    public enum Severity: Sendable, Equatable {
        /// Below 4.5:1 for text, or below 3:1 for a link or button label — unreadable at any size.
        case error
        /// A link or button label between 3:1 and 4.5:1 — readable only if it renders large, which
        /// the token map can't tell us.
        case warning
    }

    /// The pairing that failed.
    public let pair: DesignTokenContrastAudit.Pair
    /// The foreground token's value, as found in the token map.
    public let foreground: String
    /// The background token's value, as found in the token map.
    public let background: String
    /// The measured contrast ratio.
    public let ratio: Double
    /// See ``Severity``.
    public let severity: Severity
    /// What ``DesignTokenContrastAudit/applyingFix(_:to:)`` would set ``DesignTokenContrastAudit/Pair/adjustedToken``
    /// to — `nil` when no adjustment of that token reaches 4.5:1 (e.g. against a mid-grey background).
    public let suggestedValue: String?

    /// The contrast every pairing is held to: WCAG AA for normal text.
    public var requiredRatio: Double { DesignTokenContrastAudit.requiredRatio }

    /// Stable per pairing, so a list keeps its rows across re-audits.
    public var id: String { pair.id }
}

/// Design-time contrast check for the colour tokens the theme wizard is about to write (#2021) —
/// the half of #1998 that runs before any build exists. Pure and `Sendable`: it takes the
/// `[String: String]` map `DesignTokenWriter.templateCSSVars(for:)` produces and returns findings.
///
/// The math is ``WCAGContrast``'s; what this type adds is the set of pairings the template
/// actually renders (read from `Resources/Template/src/styles/global.css`) and the fix. A pairing
/// is checked only when both tokens are present and parse as hex — a theme that doesn't define
/// `--color-surface` produces no surface findings. `--color-accent` is never checked: the template
/// never puts text on it or in it.
public enum DesignTokenContrastAudit {
    /// WCAG AA for normal text. A pairing below this is a finding.
    public static let requiredRatio = 4.5
    /// WCAG AA for large text and UI components — below this, a link or button pairing escalates
    /// from a warning to an error.
    public static let largeTextRatio = 3.0

    /// One foreground/background token pairing the template renders.
    public struct Pair: Sendable, Equatable {
        /// Token names without the leading `--`, matching `DesignTokenWriter`'s keys.
        public let foregroundToken: String
        /// The token the foreground is drawn on.
        public let backgroundToken: String
        /// Owner-facing name for where the pairing shows up, e.g. "Links".
        public let place: String
        /// Whether this renders as a link or button — possibly large, so 3:1 is the error line.
        public let isLinkOrButton: Bool

        /// The token the fix changes: the foreground, except where the foreground is the site
        /// background (a button label on the primary fill). There it changes the primary colour
        /// instead — the same change the links fix makes, since both pairings compare the same
        /// two colours — so the owner's background is never touched.
        public var adjustedToken: String {
            foregroundToken == "color-background" ? backgroundToken : foregroundToken
        }

        /// The token the fix measures against — the other half of the pairing.
        var fixedToken: String {
            adjustedToken == foregroundToken ? backgroundToken : foregroundToken
        }

        /// `foreground|background`.
        public var id: String { "\(foregroundToken)|\(backgroundToken)" }
    }

    /// The pairings `global.css` renders, in the order findings are reported.
    public static let pairs: [Pair] = [
        Pair(foregroundToken: "color-text", backgroundToken: "color-background", place: "Body text", isLinkOrButton: false),
        Pair(foregroundToken: "color-text-muted", backgroundToken: "color-background", place: "Secondary text", isLinkOrButton: false),
        Pair(foregroundToken: "color-primary", backgroundToken: "color-background", place: "Links", isLinkOrButton: true),
        Pair(foregroundToken: "color-background", backgroundToken: "color-primary", place: "Button labels", isLinkOrButton: true),
        Pair(foregroundToken: "color-text", backgroundToken: "color-surface", place: "Text on cards", isLinkOrButton: false),
        Pair(foregroundToken: "color-text-muted", backgroundToken: "color-surface", place: "Secondary text on cards", isLinkOrButton: false),
        Pair(foregroundToken: "color-primary", backgroundToken: "color-surface", place: "Links on cards", isLinkOrButton: true),
    ]

    /// Every pairing in `cssVars` below 4.5:1. Keys may be written with or without the leading
    /// `--`; a missing or unparseable token skips its pairings silently.
    public static func findings(for cssVars: [String: String]) -> [DesignTokenContrastFinding] {
        let tokens = normalized(cssVars)
        return pairs.compactMap { pair in
            guard let foreground = tokens[pair.foregroundToken], let background = tokens[pair.backgroundToken],
                  WCAGContrast.hexToRGB(foreground) != nil, WCAGContrast.hexToRGB(background) != nil
            else { return nil }
            let ratio = WCAGContrast.contrastRatio(foreground, background)
            guard ratio < requiredRatio else { return nil }
            let severity: DesignTokenContrastFinding.Severity =
                pair.isLinkOrButton && ratio >= largeTextRatio ? .warning : .error
            return DesignTokenContrastFinding(
                pair: pair, foreground: foreground, background: background, ratio: ratio,
                severity: severity, suggestedValue: suggestion(for: pair, in: tokens))
        }
    }

    /// `cssVars` with `finding`'s ``DesignTokenContrastFinding/suggestedValue`` written to its
    /// pairing's ``Pair/adjustedToken`` — unchanged when there's no suggestion. Keeps the key's
    /// original spelling (with or without `--`).
    public static func applyingFix(_ finding: DesignTokenContrastFinding, to cssVars: [String: String]) -> [String: String] {
        guard let value = finding.suggestedValue else { return cssVars }
        var fixed = cssVars
        let key = cssVars.keys.first { stripped($0) == finding.pair.adjustedToken } ?? finding.pair.adjustedToken
        fixed[key] = value
        return fixed
    }

    /// `cssVars` with every fixable finding fixed. Re-audits between passes, because one token
    /// can sit in several pairings (body text on the background *and* on cards); bounded, so two
    /// pairings pulling a token in opposite directions can't loop.
    public static func applyingAllFixes(to cssVars: [String: String]) -> [String: String] {
        var current = cssVars
        for _ in 0..<pairs.count {
            let next = findings(for: current).reduce(current) { applyingFix($1, to: $0) }
            if next == current { break }
            current = next
        }
        return current
    }

    /// ``WCAGContrast/suggestReadable(fg:bg:)`` on the adjusted token — the same correction
    /// `DesignPaletteGenerator` applies — or `nil` when it can't reach 4.5:1.
    private static func suggestion(for pair: Pair, in tokens: [String: String]) -> String? {
        guard let adjusted = tokens[pair.adjustedToken], let fixed = tokens[pair.fixedToken] else { return nil }
        let suggested = WCAGContrast.suggestReadable(fg: adjusted, bg: fixed)
        return WCAGContrast.meetsAA(fg: suggested, bg: fixed) ? suggested : nil
    }

    private static func stripped(_ key: String) -> String {
        key.hasPrefix("--") ? String(key.dropFirst(2)) : key
    }

    private static func normalized(_ cssVars: [String: String]) -> [String: String] {
        Dictionary(cssVars.map { (stripped($0.key), $0.value.trimmingCharacters(in: .whitespaces)) }) { first, _ in first }
    }
}
