import Foundation

/// Every op ships with its inverse (spec §3.2) — this is the single source of truth for that
/// guarantee on the Swift side, ported line-for-line from `JS/wysiwyg-engine/src/ops.ts`'s
/// `invertOp`. A missing/wrong case here is a protocol bug, not a style nit.
public enum WYSIWYGOpInverter {
    public static func invert(_ op: Op) -> Op {
        switch op {
        case .insertBlock(let parentId, let slot, let index, let newId, let block):
            return .deleteBlock(
                parentId: parentId, slot: slot, index: index, blockId: newId,
                block: BlockNode(id: newId, kind: block.kind, componentName: block.componentName, props: block.props, slots: block.slots, sourceSpan: block.sourceSpan, richText: block.richText, manifestName: block.manifestName))
        case .deleteBlock(let parentId, let slot, let index, let blockId, let block):
            return .insertBlock(
                parentId: parentId, slot: slot, index: index, newId: blockId,
                block: BlockNodeContent(kind: block.kind, componentName: block.componentName, props: block.props, slots: block.slots, sourceSpan: block.sourceSpan, richText: block.richText, manifestName: block.manifestName))
        case .moveBlock(let blockId, let fromParentId, let fromSlot, let fromIndex, let toParentId, let toSlot, let toIndex):
            return .moveBlock(blockId: blockId, fromParentId: toParentId, fromSlot: toSlot, fromIndex: toIndex, toParentId: fromParentId, toSlot: fromSlot, toIndex: fromIndex)
        case .setProp(let blockId, let propName, let value, let previousValue):
            return .setProp(blockId: blockId, propName: propName, value: previousValue, previousValue: value)
        case .editText(let blockId, let runs, let previousRuns):
            return .editText(blockId: blockId, runs: previousRuns, previousRuns: runs)
        case .setDesignToken(let tokenName, let value, let previousValue):
            return .setDesignToken(tokenName: tokenName, value: previousValue, previousValue: value)
        }
    }
}
