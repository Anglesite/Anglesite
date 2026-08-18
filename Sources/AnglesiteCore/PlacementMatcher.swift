// Sources/AnglesiteCore/PlacementMatcher.swift
import Foundation

/// Resolves a live-preview click's ``ElementInfo`` to an insertion point in a fetched
/// ``PageModel`` — the bridge between the overlay's click-to-select infrastructure (which knows
/// nothing about node ids) and `insertBlock`'s `{parentId, index}` addressing (which knows
/// nothing about DOM clicks). Mirrors the sidecar's `selector.mjs` ancestor-walk priority so a
/// match here would resolve to the same element `selector.mjs` would pick for a page-level
/// selector op — deliberately duplicated (in Swift, not called into the sidecar) because this
/// resolution happens client-side against an already-fetched tree, with no extra round trip.
///
/// Matching runs in two tiers, following `selector.mjs`'s own priority order:
///
/// 1. **Identity attributes** — `data-anglesite-id`, then `data-testid`, then `#id`. Any one of
///    these is meant to be unique, so a single hit resolves immediately with no positional
///    reasoning at all. These are the highest-value signals the overlay collects and they were
///    previously ignored entirely (#768 final review, Finding 5).
/// 2. **Positional fallback** — tag + `nth-child` position among element siblings + (when the
///    catalog entry constrains it) the immediate parent's tag.
///
/// **Known follow-up:** `selector.mjs`'s remaining priorities — `role`/`aria-label` and
/// `tag.stableClasses` — and full ancestor-chain disambiguation (`ElementInfo.ancestors` is
/// decoded but unused here) are not implemented. Tier 2 can still report `.ambiguous` on a page
/// where the same tag sits at the same sibling position under two different ancestors; walking the
/// ancestor chain would resolve many of those. Deliberately deferred out of this fix wave.
///
/// **Known follow-up (confirm-before-apply):** the design's risk table calls for highlighting the
/// matched target in the WKWebView before committing the insert. That needs new Swift→JS bridge
/// messaging; the `inline` before/after toggle threaded through ``resolve(element:in:placement:inlinePosition:)``
/// is this round's mitigation instead.
public enum PlacementMatcher {
    public struct Insertion: Equatable {
        public let parentId: String
        public let index: Int

        public init(parentId: String, index: Int) {
            self.parentId = parentId
            self.index = index
        }
    }

    /// Which side of the clicked element an `inline` effect goes on. The placement HUD's
    /// before/after toggle writes this; `background` placements ignore it.
    public enum InlinePosition: String, Sendable, Equatable, CaseIterable {
        case before
        case after
    }

    public enum MatchError: Error, Equatable {
        /// No node in the tree matches the clicked element's tag + position + ancestry.
        case noMatch
        /// More than one node matches — refuse rather than guess which one the owner meant.
        case ambiguous
    }

    /// One candidate node plus the addressing `insertBlock` needs for it.
    private typealias Match = (node: PageModel.Node, parentId: String, indexInParent: Int)

    /// Finds the node matching `element` in `model.tree`, then computes the insertion point per
    /// `placement.kind`: `.inline` inserts immediately before or after the matched node (same
    /// parent), per `inlinePosition`; `.background` inserts as the first child (index 0) of the
    /// matched node's *parent* — behind it, not adjacent. `placement.allowedParents`, when
    /// non-nil, restricts matches to nodes whose immediate parent's tag is in the list.
    public static func resolve(
        element: ElementInfo, in model: PageModel, placement: EffectCatalogEntry.Placement,
        inlinePosition: InlinePosition = .after
    ) -> Result<Insertion, MatchError> {
        let allowedParents = placement.allowedParents

        // Tier 1: identity attributes, in `selector.mjs`'s priority order. A single hit is an
        // unambiguous answer — no tag/nth-child reasoning needed. An attribute the tree doesn't
        // carry at all (e.g. one a client-side script added after render) simply falls through to
        // the next signal, and finally to the positional match.
        for (attribute, value) in [
            ("data-anglesite-id", element.dataAnglesiteId),
            ("data-testid", element.dataTestId),
            ("id", element.id),
        ] {
            guard let value, !value.isEmpty else { continue }
            var hits: [Match] = []
            collectByAttribute(
                node: model.tree, attribute: attribute, value: value,
                allowedParents: allowedParents, into: &hits)
            if hits.count == 1 { return .success(insertion(for: hits[0], placement: placement, inlinePosition: inlinePosition)) }
            if hits.count > 1 { return .failure(.ambiguous) }
        }

        // Tier 2: positional match.
        var matches: [Match] = []
        collectMatches(node: model.tree, parentId: nil, element: element, allowedParents: allowedParents, into: &matches)
        guard !matches.isEmpty else { return .failure(.noMatch) }
        guard matches.count == 1 else { return .failure(.ambiguous) }
        return .success(insertion(for: matches[0], placement: placement, inlinePosition: inlinePosition))
    }

    /// Turns a matched node into an insertion point per the effect's placement kind.
    private static func insertion(for match: Match, placement: EffectCatalogEntry.Placement, inlinePosition: InlinePosition) -> Insertion {
        switch placement.kind {
        case .inline:
            return Insertion(
                parentId: match.parentId,
                index: inlinePosition == .after ? match.indexInParent + 1 : match.indexInParent)
        case .background:
            // Known follow-up: a `background` effect is absolutely positioned, so its containing
            // block needs `position: relative` on the parent. The app has no CSS-injection
            // mechanism yet, so this isn't guaranteed here — tracked as a separate piece of work.
            return Insertion(parentId: match.parentId, index: 0)
        }
    }

    /// Depth-first walk collecting every child node carrying `attribute` == `value`. The root is
    /// never a candidate (it has no parent to address an insertion against), matching
    /// `collectMatches` below.
    private static func collectByAttribute(
        node: PageModel.Node, attribute: String, value: String,
        allowedParents: [String]?, into matches: inout [Match]
    ) {
        for (index, child) in node.children.enumerated() {
            let carries = child.attrs.contains { $0.name.lowercased() == attribute && $0.value == value }
            if carries, parentIsAllowed(node, allowedParents: allowedParents) {
                matches.append((child, node.id, index))
            }
            collectByAttribute(
                node: child, attribute: attribute, value: value,
                allowedParents: allowedParents, into: &matches)
        }
    }

    /// Depth-first walk collecting every node whose tag, `nthChild` position among its element
    /// siblings, and immediate-parent tag (if `allowedParents` is set) line up with `element`.
    /// Returns matches with full-array child indices (for correct insertion positions when
    /// mixed with non-element siblings like `.text` or `.expression` nodes).
    private static func collectMatches(
        node: PageModel.Node, parentId: String?, element: ElementInfo, allowedParents: [String]?,
        into matches: inout [Match]
    ) {
        let elementSiblings = node.children.filter { $0.kind == .element || $0.kind == .component }
        for (index, child) in elementSiblings.enumerated() {
            let position = index + 1 // 1-based, matches CSS :nth-child / the overlay's nthChild
            if child.tag?.uppercased() == element.tag.uppercased(), position == element.nthChild {
                if parentIsAllowed(node, allowedParents: allowedParents) {
                    // Find the child's actual index in the full children array (not filtered)
                    if let fullIndex = node.children.firstIndex(where: { $0.id == child.id }) {
                        matches.append((child, node.id, fullIndex))
                    }
                }
            }
        }
        for child in node.children {
            collectMatches(node: child, parentId: node.id, element: element, allowedParents: allowedParents, into: &matches)
        }
    }

    /// Whether `parent` satisfies the catalog entry's `allowedParents` tag allowlist (`nil` = any).
    private static func parentIsAllowed(_ parent: PageModel.Node, allowedParents: [String]?) -> Bool {
        guard let allowedParents else { return true }
        return allowedParents.map { $0.uppercased() }.contains(parent.tag?.uppercased() ?? "")
    }
}
