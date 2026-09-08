import Foundation

/// Renders `Source/DESIGN.md` — the visual-system context an external agent (Codex, Claude Code,
/// an ACP backend) reads before touching a site's `Source/` repo, so its first edit doesn't drift
/// from the brand the owner just established in the design interview or theme wizard (#72, #1947).
///
/// Section headings (`Colors`, `Typography`, `Radius scale`) match the current
/// [Impeccable](https://impeccable.style/docs) `DESIGN.md` convention where this module has the
/// data to back them, so Impeccable's own commands can read this file unmodified; the remaining
/// sections (mood, brand voice, design-system attribution) are Anglesite-specific facts appended
/// after, per the same "extend, don't replace" rule the PR template uses for its own sections.
/// Pure string rendering — no I/O — so it's unit-testable without a filesystem; writing (and the
/// hand-authored-file gate) is ``DesignApplyService``'s job, same division of labor as
/// ``DesignTokenWriter``.
public enum DesignContextDocument {
    /// - Parameters:
    ///   - axes: The five design axes, when an interview produced them — `nil` for a flow that
    ///     applied a canned theme/system without running the axes conversation (the Mood section
    ///     is omitted in that case rather than guessing a mood from tokens alone).
    ///   - cssVars: The same `[String: String]` ``DesignApplyService`` writes into `global.css`
    ///     (see ``DesignTokenWriter``), keyed without the `--` prefix. Empty means no CSS was
    ///     written this apply (e.g. the freedesignmd token-translation stub) — the Colors/
    ///     Typography/Radius sections are omitted rather than rendered with nothing in them.
    ///   - brandVoicePreamble: ``BrandVoiceGuidance/preamble(conventions:businessType:)``'s
    ///     result, included verbatim when non-`nil`.
    ///   - freedesignmdSystem: The freedesignmd.com system the owner picked, when the design came
    ///     from that flow.
    ///   - appliedThemeOrPackID: The built-in theme or pack id that was applied, when any.
    public static func render(
        axes: DesignAxes?,
        cssVars: [String: String],
        brandVoicePreamble: String?,
        freedesignmdSystem: FreedesignmdSystem?,
        appliedThemeOrPackID: String?
    ) -> String {
        var sections: [String] = []

        if let axes {
            let mood = DesignAxesCatalog.moodWords(for: axes).joined(separator: ", ")
            let rows = zip(DesignAxesCatalog.poleLabels, DesignAxesCatalog.moodWords(for: axes))
                .map { label, word -> String in
                    let value = axesValue(axes, named: label.axis)
                    return "| \(label.axis.capitalized) (\(label.low) ↔ \(label.high)) | \(value) | \(word) |"
                }
            sections.append("""
            ## Mood

            The design reads as **\(mood)** — each axis below is a value from 0 to 1.

            | Axis | Value | Reading |
            |------|-------|---------|
            \(rows.joined(separator: "\n"))
            """)
        }

        let colorRows = tokenRows(cssVars, prefix: "color-")
        if !colorRows.isEmpty {
            sections.append("""
            ## Colors

            These CSS custom properties in `src/styles/global.css` are the only source of palette \
            values — introduce a new color by changing one of these, not by hardcoding a hex value \
            elsewhere.

            | Token | Value |
            |-------|-------|
            \(colorRows.joined(separator: "\n"))
            """)
        }

        let typeRows = tokenRows(cssVars, prefix: "font-")
        if !typeRows.isEmpty {
            sections.append("""
            ## Typography

            | Token | Value |
            |-------|-------|
            \(typeRows.joined(separator: "\n"))
            """)
        }

        let radiusRows = tokenRows(cssVars, prefix: "radius-") + tokenRows(cssVars, prefix: "spacing-")
        if !radiusRows.isEmpty {
            sections.append("""
            ## Radius scale

            | Token | Value |
            |-------|-------|
            \(radiusRows.joined(separator: "\n"))
            """)
        }

        if let brandVoicePreamble {
            sections.append("## Brand voice\n\n\(brandVoicePreamble)")
        }

        if let freedesignmdSystem {
            sections.append("""
            ## Design system

            Picked from freedesignmd.com: **\(freedesignmdSystem.name)** (`/system/\(freedesignmdSystem.slug)`).
            """)
        }

        if let appliedThemeOrPackID {
            sections.append("## Applied theme\n\n`\(appliedThemeOrPackID)`")
        }

        let intro = """
        This file records this site's visual design system for any agent editing `Source/` — set \
        once in Anglesite's design interview or theme picker. Treat it as the single source of \
        truth for palette, type, and radius, not something to re-derive from the CSS.
        """

        return ([GeneratedDesignDocument.marker, "", "# Design", "", intro] + sections.flatMap { ["", $0] })
            .joined(separator: "\n") + "\n"
    }

    /// `true` when `content` is this document's own prior generated output (see
    /// ``GeneratedDesignDocument``) and therefore safe for ``DesignApplyService`` to overwrite.
    public static func isOwned(_ content: String?) -> Bool { GeneratedDesignDocument.isOwned(content) }

    private static func tokenRows(_ cssVars: [String: String], prefix: String) -> [String] {
        cssVars.filter { $0.key.hasPrefix(prefix) }
            .sorted { $0.key < $1.key }
            .map { "| `--\($0.key)` | `\($0.value)` |" }
    }

    private static func axesValue(_ axes: DesignAxes, named axis: String) -> Double {
        switch axis {
        case "temperature": return axes.temperature
        case "weight": return axes.weight
        case "register": return axes.register
        case "time": return axes.time
        default: return axes.voice
        }
    }
}
