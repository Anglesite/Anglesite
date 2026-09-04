import Foundation

/// Pure grouping/filtering helpers for the Site Graph Explorer's node list, factored out of
/// `SiteGraphExplorerModel` (`AnglesiteApp`) so they get real `swift test` coverage — see #554.
/// Both functions treat `referenceCounts` as the caller's already-computed
/// (typically filtered-edge-derived, per #552) inbound-reference count keyed by node id; they do
/// no counting of their own.
public enum SiteGraphExplorerGrouping {
    /// Groups `nodes` by kind, sorted alphabetically within each group and by
    /// `SiteGraphNodeKind.allCases` order across groups. Assets with a zero reference count are
    /// dropped from this grouping (they surface only via `unusedAssets`); empty kind groups are
    /// omitted entirely.
    public static func grouped(
        nodes: [SiteGraphNode],
        referenceCounts: [String: Int]
    ) -> [(kind: SiteGraphNodeKind, nodes: [SiteGraphNode])] {
        let byKind = Dictionary(grouping: nodes, by: \.kind)
        return SiteGraphNodeKind.allCases.compactMap { kind in
            let visible = (byKind[kind] ?? []).filter { node in
                kind != .asset || (referenceCounts[node.id, default: 0]) > 0
            }
            guard !visible.isEmpty else { return nil }
            return (kind, visible.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
        }
    }

    /// Assets from `nodes` with a zero reference count, sorted alphabetically.
    public static func unusedAssets(
        nodes: [SiteGraphNode],
        referenceCounts: [String: Int]
    ) -> [SiteGraphNode] {
        nodes
            .filter { $0.kind == .asset && referenceCounts[$0.id, default: 0] == 0 }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// The Explorer's status-line summary text.
    public static func summary(nodeCount: Int, edgeCount: Int) -> String {
        "\(nodeCount) nodes, \(edgeCount) links"
    }
}
