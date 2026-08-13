import Foundation

/// Heading-hierarchy validation — hand-ported from `a11y-validate.ts`'s `validateHeadingHierarchy`
/// (skip detection only; the multiple-h1 check is left to the deploy-time backstop, which runs over
/// the full built page rather than one page's live block model). See `AltTextGate`'s header comment
/// for why this is a port rather than a shared implementation.
public enum HeadingOrderGate {
    /// A block's heading level, or `nil` if it isn't a heading. Two representations exist in the
    /// model today (design doc §3): a `text`-kind block whose `componentName` is literally `"h1"`
    /// through `"h6"` (level fixed at authoring time, no `level` prop — the stub block palette's
    /// "Heading" entry works this way), or any block carrying a numeric `level` prop (an Astro
    /// `Heading` component). Only the second form can be corrected via `setProp` — see `fix(for:)`.
    private static func level(of node: BlockNode) -> Int? {
        if case .number(let n)? = node.props["level"] { return Int(n) }
        if node.kind == .text, node.componentName.count == 2, node.componentName.hasPrefix("h"),
           let level = Int(node.componentName.dropFirst()), (1...6).contains(level) {
            return level
        }
        return nil
    }

    private static func fix(for node: BlockNode, correctedLevel: Int) -> Op? {
        guard let previous = node.props["level"] else { return nil } // no `level` prop to rewrite
        return .setProp(blockId: node.id, propName: "level", value: .number(Double(correctedLevel)), previousValue: previous)
    }

    public static func analyze(model: BlockModel, context: GateContext) throws -> [Finding] {
        var findings: [Finding] = []
        var previousLevel: Int?
        for node in model.orderedBlocks {
            guard let currentLevel = level(of: node) else { continue }
            defer { previousLevel = currentLevel }
            guard let previousLevel, currentLevel > previousLevel + 1 else { continue }
            let corrected = previousLevel + 1
            findings.append(Finding(
                blockId: node.id, category: .headingOrder, severity: .warning,
                message: "This heading jumps from h\(previousLevel) to h\(currentLevel) — screen reader visitors navigating by heading will think content is missing.",
                fix: fix(for: node, correctedLevel: corrected)))
        }
        return findings
    }
}
