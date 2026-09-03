import Foundation

/// Adapts the sidecar's `get_page_model` tree (`PageModel.Node`) into this feature's flat,
/// ID-indexed `BlockModel` (`WYSIWYGOps.swift`). See
/// `docs/superpowers/plans/2026-08-19-wysiwyg-sidecar-backed-transport.md`'s "Design decisions"
/// section for why every node (not just manifest-registered blocks) becomes a `BlockNode`, and
/// why all children collapse into a single `"default"` slot key.
public enum PageModelBlockAdapter {
    public static func adapt(_ pageModel: PageModel) -> BlockModel {
        var blocks: [BlockId: BlockNode] = [:]
        walk(pageModel.tree, into: &blocks)
        return BlockModel(
            path: pageModel.path,
            version: pageModel.version,
            rootIds: pageModel.tree.children.map(\.id),
            blocks: blocks)
    }

    private static func walk(_ node: PageModel.Node, into blocks: inout [BlockId: BlockNode]) {
        var props: [String: PropValue] = [:]
        for attr in node.attrs {
            props[attr.name] = attr.value.map(PropValue.string) ?? .null
        }
        blocks[node.id] = BlockNode(
            id: node.id,
            kind: blockKind(for: node),
            componentName: node.tag ?? "",
            props: props,
            slots: node.children.isEmpty ? [:] : ["default": node.children.map(\.id)],
            sourceSpan: [node.span.start ?? 0, node.span.end ?? 0],
            // A lossy-but-honest baseline: the page model carries only a flat plain-text
            // snapshot, no bold/italic/link marks, so a single `.text` run is the most this can
            // ever be — but it's a strict improvement over the previous hardcoded `nil`, which
            // made `RichTextEditor`'s undo baseline (`rich-text.ts:257`) always empty, so undoing
            // any text edit restored to nothing rather than the original text (#1602 item 1).
            richText: node.text.map { [RichTextRun(kind: .text, text: $0)] })
        for child in node.children {
            walk(child, into: &blocks)
        }
    }

    private static func blockKind(for node: PageModel.Node) -> BlockKind {
        if node.block != nil { return .astro } // manifest-registered — the only case where "astro"/"custom-element" actually matters downstream; refine to .customElement if `node.block` ever carries a kind flag
        switch node.kind {
        case .fragment: return .fragment
        case .text: return .text
        case .element, .component, .slot, .expression: return .element
        }
    }
}
