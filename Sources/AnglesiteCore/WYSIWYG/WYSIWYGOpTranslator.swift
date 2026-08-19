import Foundation

/// Translates the WYSIWYG engine's `Op` (`WYSIWYGOps.swift`) into the sidecar's `apply_edit`
/// wire format via `ComponentStructureEditBuilder`. The two shapes don't match field-for-field —
/// see `docs/superpowers/plans/2026-08-19-wysiwyg-sidecar-backed-transport.md`'s "Design
/// decisions" section for why `slot` names are dropped and `setDesignToken` retargets its path.
public enum WYSIWYGOpTranslator {
    public static func translate(_ op: Op, requestId: String, path: String, baseVersion: String) -> EditMessage {
        switch op {
        case .insertBlock(let parentId, _, let index, _, let block):
            return ComponentStructureEditBuilder.insertBlockNode(
                id: requestId, path: path, baseVersion: baseVersion,
                parentId: parentId, index: index, node: nodeSpec(for: block))

        case .deleteBlock(let parentId, _, _, let blockId, _):
            _ = parentId // the wire op addresses purely by nodeId; parentId is app-side bookkeeping only
            return ComponentStructureEditBuilder.deleteBlock(
                id: requestId, path: path, baseVersion: baseVersion, nodeId: blockId)

        case .moveBlock(let blockId, _, _, _, let toParentId, _, let toIndex):
            return ComponentStructureEditBuilder.moveBlock(
                id: requestId, path: path, baseVersion: baseVersion,
                nodeId: blockId, newParentId: toParentId, newIndex: toIndex)

        case .setProp(let blockId, let propName, let value, _):
            return ComponentStructureEditBuilder.setAttr(
                id: requestId, path: path, baseVersion: baseVersion,
                nodeId: blockId, name: propName, value: Self.stringValue(value))

        case .editText(let blockId, let runs, _):
            return ComponentStructureEditBuilder.editText(
                id: requestId, path: path, baseVersion: baseVersion, textNodeId: blockId, runs: runs)

        case .setDesignToken(let tokenName, let value, _):
            // The sidecar hardcodes and validates src/styles/global.css as setDesignToken's only
            // valid target (design-token-edit.mjs) — always retarget, ignore the page `path` arg.
            return ComponentStructureEditBuilder.setDesignToken(
                id: requestId, path: "src/styles/global.css", baseVersion: baseVersion,
                token: tokenName, tokenValue: value)
        }
    }

    /// `setProp`'s wire `value` is a plain optional string (`set-attr`'s existing contract) —
    /// `PropValue` is richer (numbers/bools/objects/arrays) than the wire currently accepts for
    /// this op family. Non-string values stringify; `.null` removes the attribute, matching
    /// `setAttr`'s existing `value: nil` convention.
    private static func stringValue(_ value: PropValue) -> String? {
        switch value {
        case .string(let s): return s
        case .number(let n): return String(n)
        case .bool(let b): return String(b)
        case .null: return nil
        case .object, .array: return nil // not representable on this wire op; see follow-up note below
        }
    }

    private static func nodeSpec(for block: BlockNodeContent) -> ComponentStructureEditBuilder.NodeSpec {
        switch block.kind {
        case .astro, .customElement:
            return .component(tag: block.componentName, componentPath: block.componentName)
        case .text:
            return .element(tag: "span") // no dedicated text-node insert on the wire; a follow-up
        }
    }
}
