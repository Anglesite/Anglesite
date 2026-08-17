// Sources/AnglesiteCore/PlacementMatcher.swift
import Foundation

/// Resolves a live-preview click's ``ElementInfo`` to an insertion point in a fetched
/// ``PageModel`` — the bridge between the overlay's click-to-select infrastructure (which knows
/// nothing about node ids) and `insertBlock`'s `{parentId, index}` addressing (which knows
/// nothing about DOM clicks). Mirrors the sidecar's `selector.mjs` ancestor-walk priority so a
/// match here would resolve to the same element `selector.mjs` would pick for a page-level
/// selector op — deliberately duplicated (in Swift, not called into the sidecar) because this
/// resolution happens client-side against an already-fetched tree, with no extra round trip.
public enum PlacementMatcher {
    public struct Insertion: Equatable {
        public let parentId: String
        public let index: Int

        public init(parentId: String, index: Int) {
            self.parentId = parentId
            self.index = index
        }
    }

    public enum MatchError: Error, Equatable {
        /// No node in the tree matches the clicked element's tag + position + ancestry.
        case noMatch
        /// More than one node matches — refuse rather than guess which one the owner meant.
        case ambiguous
    }

    /// Finds the node matching `element` in `model.tree`, then computes the insertion point per
    /// `placement.kind`: `.inline` inserts immediately after the matched node (same parent,
    /// index + 1); `.background` inserts as the first child (index 0) of the matched node's
    /// *parent* — behind it, not adjacent. `placement.allowedParents`, when non-nil, restricts
    /// matches to nodes whose immediate parent's tag is in the list.
    public static func resolve(element: ElementInfo, in model: PageModel, placement: EffectCatalogEntry.Placement) -> Result<Insertion, MatchError> {
        var matches: [(node: PageModel.Node, parentId: String, indexInParent: Int)] = []
        collectMatches(node: model.tree, parentId: nil, element: element, allowedParents: placement.allowedParents, into: &matches)
        guard !matches.isEmpty else { return .failure(.noMatch) }
        guard matches.count == 1 else { return .failure(.ambiguous) }
        let match = matches[0]
        switch placement.kind {
        case .inline:
            return .success(Insertion(parentId: match.parentId, index: match.indexInParent + 1))
        case .background:
            return .success(Insertion(parentId: match.parentId, index: 0))
        }
    }

    /// Depth-first walk collecting every node whose tag, `nthChild` position among its element
    /// siblings, and immediate-parent tag (if `allowedParents` is set) line up with `element`.
    /// Ancestor chain is consulted only to break ties when more than one node shares the same
    /// (tag, nthChild) pair at different depths — the common case (one match) never needs it.
    private static func collectMatches(
        node: PageModel.Node, parentId: String?, element: ElementInfo, allowedParents: [String]?,
        into matches: inout [(node: PageModel.Node, parentId: String, indexInParent: Int)]
    ) {
        let elementSiblings = node.children.filter { $0.kind == .element || $0.kind == .component }
        for (index, child) in elementSiblings.enumerated() {
            let position = index + 1 // 1-based, matches CSS :nth-child / the overlay's nthChild
            if child.tag?.uppercased() == element.tag.uppercased(), position == element.nthChild {
                if allowedParents == nil || allowedParents!.map({ $0.uppercased() }).contains(node.tag?.uppercased() ?? "") {
                    matches.append((child, node.id, index))
                }
            }
        }
        for child in node.children {
            collectMatches(node: child, parentId: node.id, element: element, allowedParents: allowedParents, into: &matches)
        }
    }
}
