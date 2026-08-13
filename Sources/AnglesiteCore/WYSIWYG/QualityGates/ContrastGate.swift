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
                // Both sides of the pair, not just the foreground: two of the pairs above share
                // `color-text` as their foreground, so a foreground-only discriminator gave them
                // the same `Finding.id` — and the engine's keyed diff would then silently collapse
                // two simultaneously-failing pairs into one chip, dropping a real finding.
                discriminator: "\(pair.foreground)-on-\(pair.background)",
                severity: .warning,
                message: "\(Self.sentenceCased(pair.label)) is hard to read — its contrast ratio is \(String(format: "%.1f", ratio)):1, below the 4.5:1 most readers need."))
        }
        return findings
    }

    /// Uppercases only the first character of an owner-facing label — `String.capitalized`
    /// title-cases *every* word, turning "links and buttons" into the oddly shouty "Links And
    /// Buttons" in a sentence the owner reads.
    private static func sentenceCased(_ label: String) -> String {
        label.prefix(1).uppercased() + label.dropFirst()
    }

    /// Parses `--name: value;` custom properties out of raw CSS text — the site's actual on-disk
    /// source of truth for its resolved tokens (design doc §3: there is no runtime token reader
    /// today, so this reads the same file the site itself renders from). Deliberately simple:
    /// matches `--token-name: value;` pairs anywhere in the text rather than parsing full CSS
    /// syntax.
    ///
    /// **First occurrence of a name wins**, and that is load-bearing rather than incidental.
    /// `global.css` declares the whole palette at the top-level `:root` and then *re-declares* the
    /// dark-scheme overrides inside a later `@media (prefers-color-scheme: dark)` block, so
    /// last-wins silently graded contrast against the dark palette — and, worse, kept doing so
    /// after an owner customized their theme, since the design-apply flow only ever rewrites the
    /// top-level `:root` block (see that file's own comment) and leaves the dark block stock.
    /// First-wins reads the light palette the owner actually chose, because `:root` always comes
    /// first, while still degrading gracefully on a file that declares its tokens under some other
    /// selector — where scoping strictly to a literal top-level `:root { … }` block would instead
    /// yield no tokens at all and leave the gate silently checking nothing.
    public static func parseCSSCustomProperties(from css: String) -> [String: String] {
        var result: [String: String] = [:]
        let pattern = #"--([a-zA-Z0-9-]+)\s*:\s*([^;]+);"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let nsrange = NSRange(css.startIndex..<css.endIndex, in: css)
        regex.enumerateMatches(in: css, range: nsrange) { match, _, _ in
            guard let match, let nameRange = Range(match.range(at: 1), in: css), let valueRange = Range(match.range(at: 2), in: css) else { return }
            let name = String(css[nameRange])
            guard result[name] == nil else { return } // first declaration wins — see doc comment
            result[name] = css[valueRange].trimmingCharacters(in: .whitespaces)
        }
        return result
    }
}
