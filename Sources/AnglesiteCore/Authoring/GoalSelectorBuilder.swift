import Foundation

/// Builds a literal CSS-selector string for the A/B testing "visible" goal (#1270 slice 5) from
/// the same `ElementInfo`/`AncestorInfo` payload `PlacementPickMessage` already decodes. Reuses
/// the proven priority order documented in `JS/edit-overlay/src/selector.ts`
/// (`data-anglesite-id` > `data-testid` > `#id` > `role`/`aria-label` > stable classes >
/// `tag:nth-child`) — nothing before this emitted a literal selector string; the two adjacent
/// mechanisms (the sidecar's `selector.mjs`, `PlacementMatcher`) resolve to a source-file patch
/// location or a `PageModel` node id instead. Astro's dev-time `astro-*` scoped-class hashes are
/// filtered before the class fallback is tried, since they don't survive `astro build`.
public enum GoalSelectorBuilder {
    public enum BuildError: Error, Equatable {}

    /// Anchors on the nearest ancestor (searching nearest-first) with a stable single-element
    /// identifier, then walks down to the leaf with `>` combinators, using each hop's own
    /// simple-selector. If no ancestor anchors, walks the *entire* chain (root-first) the same
    /// way — always succeeds; the result may just be a longer nth-child chain.
    public static func build(for element: ElementInfo) -> Result<String, BuildError> {
        if let leaf = anchoredSelector(tag: element.tag, id: element.id, classes: element.classes,
                                        dataAnglesiteId: element.dataAnglesiteId, dataTestId: element.dataTestId,
                                        role: element.role, ariaLabel: element.ariaLabel, nthChild: element.nthChild) {
            return .success(leaf)
        }
        // No anchor at the leaf: find the nearest ancestor (search reversed — ancestors is
        // root-first) that anchors, then join from there down through to the leaf.
        for (index, ancestor) in element.ancestors.enumerated().reversed() {
            if let anchor = anchoredSelector(tag: ancestor.tag, id: ancestor.id, classes: ancestor.classes,
                                              dataAnglesiteId: nil, dataTestId: nil,
                                              role: ancestor.role, ariaLabel: ancestor.ariaLabel, nthChild: ancestor.nthChild ?? 1) {
                let remaining = element.ancestors[(index + 1)...].map { simpleSelector(for: $0) } + [simpleSelector(for: element)]
                return .success(([anchor] + remaining).joined(separator: " > "))
            }
        }
        // No anchor anywhere: full chain from the root-most ancestor down to the leaf.
        let chain = element.ancestors.map { simpleSelector(for: $0) } + [simpleSelector(for: element)]
        return .success(chain.joined(separator: " > "))
    }

    /// A simple selector that alone identifies the element (a data attribute, `#id`, or
    /// `role`+`aria-label` pair) — or `nil` if it has none, meaning the caller must fall back to
    /// stable classes or `tag:nth-child` (never "anchoring" material on their own).
    private static func anchoredSelector(
        tag: String, id: String?, classes: [String], dataAnglesiteId: String?, dataTestId: String?,
        role: String?, ariaLabel: String?, nthChild: Int
    ) -> String? {
        if let dataAnglesiteId, !dataAnglesiteId.isEmpty { return "[data-anglesite-id=\"\(dataAnglesiteId)\"]" }
        if let dataTestId, !dataTestId.isEmpty { return "[data-testid=\"\(dataTestId)\"]" }
        if let id, !id.isEmpty { return "#\(id)" }
        if let role, let ariaLabel, !role.isEmpty, !ariaLabel.isEmpty {
            return "[role=\"\(role)\"][aria-label=\"\(ariaLabel)\"]"
        }
        return nil
    }

    /// A simple selector for one hop in a combinator chain — always succeeds (falls back to
    /// `tag:nth-child(n)`), unlike `anchoredSelector` which only returns something when the
    /// element is identifiable on its own.
    private static func simpleSelector(for info: ElementInfo) -> String {
        simpleSelector(tag: info.tag, classes: info.classes, nthChild: info.nthChild)
    }
    private static func simpleSelector(for ancestor: AncestorInfo) -> String {
        simpleSelector(tag: ancestor.tag, classes: ancestor.classes, nthChild: ancestor.nthChild ?? 1)
    }
    private static func simpleSelector(tag: String, classes: [String], nthChild: Int) -> String {
        let lowered = tag.lowercased()
        let stableClasses = classes.filter { !$0.hasPrefix("astro-") }
        if !stableClasses.isEmpty { return lowered + stableClasses.map { ".\($0)" }.joined() }
        return "\(lowered):nth-child(\(nthChild))"
    }
}
