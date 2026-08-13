import Foundation

/// Alt-text quality — hand-ported from `Resources/Template/scripts/a11y-validate.ts`'s
/// `validateImageAlt` (design doc §2: no cross-language sharing bridge exists, and the logic is
/// small enough that porting is cheaper than building one). The TS version parses raw HTML with
/// regexes; this version walks the typed `BlockModel` instead — simpler, not harder, since no HTML
/// parsing is needed. Kept independent from this point: a change to one does not automatically
/// apply to the other.
public enum AltTextGate {
    /// A block is image-like if it carries a `src` prop — deliberately not scoped to a specific
    /// `componentName`, since an image block could be an Astro `<Image>` component, a raw `text`-kind
    /// `<img>`, or (once theme blocks migrate, spec §4.1) a custom element — all of them carry `src`.
    private static func isImageLike(_ node: BlockNode) -> Bool {
        if case .string? = node.props["src"] { return true }
        return false
    }

    private static let placeholderPatterns: Set<String> = [
        "image", "photo", "picture", "img", "untitled", "placeholder", "screenshot", "banner", "hero",
    ]

    public static func analyze(model: BlockModel, context: GateContext) throws -> [Finding] {
        var findings: [Finding] = []
        for node in model.orderedBlocks where isImageLike(node) {
            guard case .string(let alt)? = node.props["alt"] else {
                findings.append(Finding(
                    blockId: node.id, category: .altText, severity: .warning,
                    message: "This image has no alt text — screen reader visitors won't know what it shows."))
                continue
            }
            let trimmed = alt.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue } // intentionally decorative, matches a11y-validate.ts
            if placeholderPatterns.contains(trimmed.lowercased()) {
                findings.append(Finding(
                    blockId: node.id, category: .altText, severity: .advisory,
                    message: "The alt text \"\(alt)\" is a placeholder — describe what the image actually shows."))
            }
        }
        return findings
    }
}
