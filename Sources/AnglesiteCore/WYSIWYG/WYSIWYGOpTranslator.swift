import Foundation

/// Translates the WYSIWYG engine's `Op` (`WYSIWYGOps.swift`) into the sidecar's `apply_edit`
/// wire format via `ComponentStructureEditBuilder`. The two shapes don't match field-for-field —
/// see `docs/superpowers/plans/2026-08-19-wysiwyg-sidecar-backed-transport.md`'s "Design
/// decisions" section for why `slot` names are dropped and `setDesignToken` retargets its path.
public enum WYSIWYGOpTranslator {
    /// - Parameters:
    ///   - op: the engine-originated semantic op to translate into the sidecar's wire format.
    ///   - requestId: correlation id echoed back on the `apply_edit` reply — the same id the
    ///     caller stamped on the originating `OpEnvelope`.
    ///   - path: project-relative path of the file the op targets (a page for most ops;
    ///     `setDesignToken` ignores this and always retargets to `src/styles/global.css`).
    ///   - baseVersion: the content-hash version the op was computed against — the sidecar
    ///     refuses the write if the file has changed since.
    ///   - rootId: the CURRENT model's real root-fragment id (`PageModel.tree.id`, e.g.
    ///     `"n0"`) — substituted for the app-side ``rootParentID`` sentinel (`"__root__"`) wherever
    ///     a `ParentRef` reaches the wire. The sidecar has no concept of that sentinel: its root
    ///     fragment has a real id assigned by `server/component-node-index.mjs`'s
    ///     `buildTemplateNodeIndex`, and a wire request literally carrying `parentId: "__root__"`
    ///     is refused with `no-match` (`byId.get(parentId)` returns `undefined`). Callers must pass
    ///     the id of the model the op was actually computed against — see
    ///     `SidecarWYSIWYGHostTransport`, which tracks it from the `PageModel` it last fetched.
    public static func translate(_ op: Op, requestId: String, path: String, baseVersion: String, rootId: BlockId) -> EditMessage {
        switch op {
        case .insertBlock(let parentId, _, let index, _, let block):
            return ComponentStructureEditBuilder.insertBlockNode(
                id: requestId, path: path, baseVersion: baseVersion,
                parentId: resolveParent(parentId, rootId: rootId), index: index, node: nodeSpec(for: block))

        case .deleteBlock(let parentId, _, _, let blockId, _):
            _ = parentId // the wire op addresses purely by nodeId; parentId is app-side bookkeeping only
            return ComponentStructureEditBuilder.deleteBlock(
                id: requestId, path: path, baseVersion: baseVersion, nodeId: blockId)

        case .moveBlock(let blockId, _, _, _, let toParentId, _, let toIndex):
            return ComponentStructureEditBuilder.moveBlock(
                id: requestId, path: path, baseVersion: baseVersion,
                nodeId: blockId, newParentId: resolveParent(toParentId, rootId: rootId), newIndex: toIndex)

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
            //
            // KNOWN GAP (final-review Finding 3, unresolved — tracked for follow-up, not silently
            // guessed at): `baseVersion` below is still the PAGE's content hash (the model this
            // op was computed against), not global.css's own. design-token-edit.mjs's
            // resolveDesignToken reads global.css fresh and refuses with "stale" unless the
            // request's baseVersion matches THAT file's hash — so every setDesignToken currently
            // gets refused. Fixing this needs a real way for the app to learn global.css's
            // CURRENT content hash before sending the op. As of this writing the sidecar exposes
            // no such capability: get_component_model/get_page_model both require a `.astro`
            // path (component-model.mjs/page-model.mjs's validPath checks), there is no generic
            // "get file version" tool, and design-token-edit.mjs's "stale" refusal carries only
            // `{reason, detail}` — no fresh hash to retry with (apply-edit-schema.mjs's
            // createEditFailedContent never attaches one). This is a sidecar-side gap, not
            // something the app can close on its own; see the final-review fix report for the
            // BLOCKED writeup.
            return ComponentStructureEditBuilder.setDesignToken(
                id: requestId, path: "src/styles/global.css", baseVersion: baseVersion,
                token: tokenName, tokenValue: value)
        }
    }

    /// Substitutes the CURRENT model's real root-fragment id for the app-side ``rootParentID``
    /// sentinel; passes any other `ParentRef` through unchanged (it's already a real node id).
    private static func resolveParent(_ ref: ParentRef, rootId: BlockId) -> BlockId {
        ref == rootParentID ? rootId : ref
    }

    /// `setProp`'s wire `value` is a plain optional string (`set-attr`'s existing contract) —
    /// `PropValue` is richer (numbers/bools/objects/arrays) than the wire currently accepts for
    /// this op family. Non-string values stringify; `.null` removes the attribute, matching
    /// `setAttr`'s existing `value: nil` convention.
    ///
    /// `nil` is reserved for ``PropValue/null`` alone — `ComponentStructureEditBuilder.setAttr`
    /// treats `value: nil` as "remove the attribute" (its own doc comment), so any other case
    /// returning `nil` here would silently delete whatever attribute was already on the wire
    /// instead of just failing to translate it richly. `.object`/`.array` therefore JSON-encode
    /// into a string rather than dropping to `nil`: lossy (the wire has no structured-value
    /// slot for this op family) but non-destructive, and round-trippable by re-parsing the JSON
    /// text back out on read.
    ///
    /// Package-visible (not `private`) so `SidecarWYSIWYGHostTransport` can reuse the same
    /// `PropValue` → wire-string mapping for its `insertBlock`-props `setAttr` follow-up calls
    /// (see that type's `sendOp`) instead of duplicating this logic.
    static func stringValue(_ value: PropValue) -> String? {
        switch value {
        case .string(let s): return s
        case .number(let n):
            // Avoid Double's default `String(n)` formatting a whole number as "5.0" — the wire
            // attribute value should read "5", matching how the number was almost certainly
            // authored (props round-trip through JSON, where 5 and 5.0 are the same number).
            if n.truncatingRemainder(dividingBy: 1) == 0, let whole = Int(exactly: n) {
                return String(whole)
            }
            return String(n)
        case .bool(let b): return String(b)
        case .null: return nil
        case .object, .array:
            let encoder = JSONEncoder()
            guard let data = try? encoder.encode(value), let json = String(data: data, encoding: .utf8) else {
                return nil
            }
            return json
        }
    }

    private static func nodeSpec(for block: BlockNodeContent) -> ComponentStructureEditBuilder.NodeSpec {
        switch block.kind {
        case .astro, .customElement:
            return .component(tag: block.componentName, componentPath: block.componentName)
        case .element:
            return .element(tag: block.componentName)
        case .text:
            // `componentName` IS the real tag name for a `.text`-kind block (see
            // JS/wysiwyg-engine/src/types.ts's `BlockNode.componentName` doc comment) — the
            // shipped palette entries are `.text` blocks named "p"/"h2". Hardcoding "span" here
            // discarded that and silently inserted an empty <span> for every palette entry.
            return .element(tag: block.componentName)
        case .fragment:
            // A fragment is the page's synthetic tree root (or a nested fragment) —
            // PageModelBlockAdapter only ever produces this kind for nodes already in the tree,
            // never for a freshly-authored insertBlock payload, so this arm is unreachable in
            // practice. Exhaustiveness requires it; degrade to a plain wrapper rather than crash
            // if it's ever hit.
            return .element(tag: "div")
        }
    }
}
