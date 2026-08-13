import Foundation

/// WCAG contrast checks against the site's global design tokens (spec §6) — not per-block, since
/// the block model carries component props, not resolved computed style (design doc §3). Findings
/// anchor to `rootParentID`: there is no single block a color-pair choice belongs to, so the chip
/// renders as a page-level advisory (`quality-gates.ts`'s anchoring falls back to a fixed tray
/// position when `computeHandleRect` finds no element for `rootParentID`).
public enum ContrastGate {
    private struct Pair {
        let foreground: String
        let background: String
        let label: String
    }

    private static let pairs: [Pair] = [
        Pair(foreground: "color-text", background: "color-background", label: "body text"),
        Pair(foreground: "color-text-muted", background: "color-background", label: "muted text"),
        Pair(foreground: "color-text", background: "color-surface", label: "text on surfaces"),
        Pair(foreground: "color-primary", background: "color-background", label: "links and buttons"),
        Pair(foreground: "color-accent", background: "color-background", label: "accented text"),
    ]

    public static func analyze(model: BlockModel, context: GateContext) throws -> [Finding] {
        var findings: [Finding] = []
        for pair in pairs {
            guard let fg = context.resolvedTokens[pair.foreground],
                  let bg = context.resolvedTokens[pair.background]
            else { continue } // token not set for this theme — nothing to check
            guard !WCAGContrast.meetsAA(fg: fg, bg: bg) else { continue }
            let ratio = WCAGContrast.contrastRatio(fg, bg)
            findings.append(Finding(
                blockId: rootParentID,
                category: .contrast,
                discriminator: pair.foreground,
                severity: .warning,
                message: "\(pair.label.capitalized) is hard to read — its contrast ratio is \(String(format: "%.1f", ratio)):1, below the 4.5:1 most readers need."))
        }
        return findings
    }

    /// Parses `--name: value;` custom properties out of raw CSS text — the site's actual on-disk
    /// source of truth for its resolved tokens (design doc §3: there is no runtime token reader
    /// today, so this reads the same file the site itself renders from). Deliberately simple:
    /// matches `--token-name: value;` pairs anywhere in the text rather than parsing full CSS syntax
    /// or scoping to `:root` — `Resources/Template/src/styles/global.css` only ever declares custom
    /// properties at the top level, so a stricter parser would add complexity with no behavioral
    /// difference for the files this actually runs against.
    public static func parseCSSCustomProperties(from css: String) -> [String: String] {
        var result: [String: String] = [:]
        let pattern = #"--([a-zA-Z0-9-]+)\s*:\s*([^;]+);"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let nsrange = NSRange(css.startIndex..<css.endIndex, in: css)
        regex.enumerateMatches(in: css, range: nsrange) { match, _, _ in
            guard let match, let nameRange = Range(match.range(at: 1), in: css), let valueRange = Range(match.range(at: 2), in: css) else { return }
            result[String(css[nameRange])] = css[valueRange].trimmingCharacters(in: .whitespaces)
        }
        return result
    }
}
