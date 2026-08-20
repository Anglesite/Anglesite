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
            richText: nil) // rich-text runs come from a dedicated read, not the page-model tree; see Task 5's caveat
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
