import SwiftUI
import AnglesiteCore

struct SiteGraphExplorerView: View {
    @Bindable var model: SiteGraphExplorerModel
    let onOpenFile: (SiteGraphNode) -> Void
    /// Returns the main pane to the canvas (#714 v2 slice 2's Done chrome) — Graph is a
    /// menu-invoked takeover (Website ▸ Graph…), not a peer toolbar pane, so this is its only way
    /// back besides picking a page in the navigator.
    var onDone: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            MainPaneTakeoverHeader(
                title: "Site Graph", systemImage: "point.3.connected.trianglepath.dotted", onDone: onDone)
            Divider()
            HSplitView {
                SiteGraphTree(model: model)
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)

                VStack(spacing: 0) {
                    SiteGraphToolbar(model: model)
                    Divider()
                    SiteGraphCanvas(
                        nodes: model.filteredNodes,
                        edges: model.filteredEdges,
                        referenceCounts: model.visibleReferenceCounts,
                        selectedNodeID: model.selectedNodeID,
                        onSelect: { model.selectedNodeID = $0 }
                    )
                }
                .frame(minWidth: 520)

                SiteGraphInspector(
                    model: model,
                    onOpenFile: onOpenFile
                )
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.windowBackgroundColor))
        }
    }
}

private struct SiteGraphToolbar: View {
    @Bindable var model: SiteGraphExplorerModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Label("Site Graph", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.headline)
                Text(model.visibleSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("Search graph", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(SiteGraphNodeKind.allCases) { kind in
                        Toggle(isOn: Binding(
                            get: { model.enabledKinds.contains(kind) },
                            set: { model.setKind(kind, enabled: $0) }
                        )) {
                            Label(kind.title, systemImage: kind.systemImage)
                        }
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .help("Show or hide \(kind.title.lowercased())")
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(12)
    }
}

private struct SiteGraphTree: View {
    @Bindable var model: SiteGraphExplorerModel

    var body: some View {
        let referenceCounts = model.visibleReferenceCounts
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Explorer", systemImage: "list.bullet.indent")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            List(selection: $model.selectedNodeID) {
                ForEach(model.groupedFilteredNodes, id: \.kind) { group in
                    Section {
                        ForEach(group.nodes) { node in
                            SiteGraphTreeRow(
                                node: node,
                                referenceCount: referenceCounts[node.id, default: 0]
                            )
                            .tag(Optional(node.id))
                        }
                    } header: {
                        Label(group.kind.title, systemImage: group.kind.systemImage)
                    }
                }
                if !model.unusedAssets.isEmpty {
                    Section {
                        ForEach(model.unusedAssets) { node in
                            SiteGraphTreeRow(node: node, referenceCount: 0, badge: "unused")
                                .tag(Optional(node.id))
                        }
                    } header: {
                        Label("Unused Assets", systemImage: "exclamationmark.triangle")
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .background(Color(NSColor.controlBackgroundColor))
    }
}

private struct SiteGraphTreeRow: View {
    let node: SiteGraphNode
    var referenceCount: Int
    var badge: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: node.kind.systemImage)
                .foregroundStyle(node.kind.tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.title)
                    .lineLimit(1)
                if let detail = node.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let badge {
                Text(badge)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if referenceCount > 0 {
                Text("\(referenceCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("\(referenceCount) incoming references")
            }
        }
        .help(node.filePath ?? node.detail ?? node.title)
    }
}

private struct SiteGraphCanvas: View {
    let nodes: [SiteGraphNode]
    let edges: [SiteGraphEdge]
    let referenceCounts: [String: Int]
    let selectedNodeID: String?
    let onSelect: (String) -> Void

    var body: some View {
        GeometryReader { proxy in
            let positions = SiteGraphLayout.positions(for: nodes, in: proxy.size)
            ZStack {
                Canvas { context, _ in
                    for edge in edges {
                        guard let start = positions[edge.sourceID], let end = positions[edge.targetID] else { continue }
                        var path = Path()
                        path.move(to: start)
                        let controlOffset = max(40, abs(end.x - start.x) * 0.35)
                        path.addCurve(
                            to: end,
                            control1: CGPoint(x: start.x + controlOffset, y: start.y),
                            control2: CGPoint(x: end.x - controlOffset, y: end.y)
                        )
                        context.stroke(
                            path,
                            with: .color(edgeColor(edge, selectedNodeID: selectedNodeID)),
                            lineWidth: highlighted(edge, selectedNodeID: selectedNodeID) ? 2 : 1
                        )
                    }
                }
                ForEach(nodes) { node in
                    if let point = positions[node.id] {
                        SiteGraphNodeButton(
                            node: node,
                            referenceCount: referenceCounts[node.id, default: 0],
                            selected: node.id == selectedNodeID,
                            related: isRelated(node.id, selectedNodeID: selectedNodeID)
                        ) {
                            onSelect(node.id)
                        }
                        .position(point)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if nodes.isEmpty {
                    ContentUnavailableView("No matching graph nodes", systemImage: "point.3.connected.trianglepath.dotted")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if SiteGraphMiniMapGeometry.shouldShow(nodeCount: nodes.count) {
                    SiteGraphMiniMap(
                        nodes: nodes,
                        edges: edges,
                        positions: positions,
                        canvasSize: proxy.size,
                        selectedNodeID: selectedNodeID,
                        onSelect: onSelect
                    )
                    .padding(12)
                }
            }
        }
    }

    private func highlighted(_ edge: SiteGraphEdge, selectedNodeID: String?) -> Bool {
        guard let selectedNodeID else { return false }
        return edge.sourceID == selectedNodeID || edge.targetID == selectedNodeID
    }

    private func isRelated(_ nodeID: String, selectedNodeID: String?) -> Bool {
        guard let selectedNodeID, nodeID != selectedNodeID else { return false }
        return edges.contains {
            ($0.sourceID == selectedNodeID && $0.targetID == nodeID)
                || ($0.targetID == selectedNodeID && $0.sourceID == nodeID)
        }
    }

    private func edgeColor(_ edge: SiteGraphEdge, selectedNodeID: String?) -> Color {
        if highlighted(edge, selectedNodeID: selectedNodeID) { return .accentColor }
        switch edge.kind {
        case .imports: return .secondary.opacity(0.45)
        case .usesLayout: return .blue.opacity(0.55)
        case .referencesAsset: return .green.opacity(0.5)
        case .contains: return .orange.opacity(0.45)
        }
    }
}

/// Scaled-down overview of the whole visible graph (#613), overlaid bottom-trailing on the main
/// canvas once the node count crosses `SiteGraphMiniMapGeometry.nodeCountThreshold`. Nodes render
/// as kind-tinted dots and edges as hairlines at the same relative positions as the main canvas;
/// clicking selects the nearest node there. No viewport rectangle yet — the main canvas has no
/// pan/zoom to reflect (see #613's "if/when" note).
///
/// Like any corner mini-map, it occludes the canvas region beneath it (where `SiteGraphLayout`
/// clamps overflow rows). Accepted tradeoff: a click there lands on the mini-map, whose scaled
/// coordinates put the tap next to the *same* node's dot, so click-to-jump still selects the
/// intended node; the bounded hit radius makes genuinely empty space a no-op.
private struct SiteGraphMiniMap: View {
    let nodes: [SiteGraphNode]
    let edges: [SiteGraphEdge]
    let positions: [String: CGPoint]
    let canvasSize: CGSize
    let selectedNodeID: String?
    let onSelect: (String) -> Void

    private static let size = CGSize(width: 180, height: 120)

    var body: some View {
        let miniPositions = positions.mapValues {
            SiteGraphMiniMapGeometry.scaledPoint($0, from: canvasSize, to: Self.size)
        }
        Canvas { context, _ in
            for edge in edges {
                guard let start = miniPositions[edge.sourceID], let end = miniPositions[edge.targetID] else { continue }
                var path = Path()
                path.move(to: start)
                path.addLine(to: end)
                context.stroke(path, with: .color(.secondary.opacity(0.25)), lineWidth: 0.5)
            }
            for node in nodes {
                guard let point = miniPositions[node.id] else { continue }
                let selected = node.id == selectedNodeID
                let radius: CGFloat = selected ? 3.5 : 2
                context.fill(
                    Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
                    with: .color(selected ? Color.accentColor : node.kind.tint.opacity(0.9))
                )
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        }
        .onTapGesture { location in
            // Bounded hit radius: a click on empty mini-map space is a no-op, not a jump to
            // whatever node happens to be least far away.
            if let id = SiteGraphMiniMapGeometry.nearestNodeID(to: location, positions: miniPositions, maxDistance: 16) {
                onSelect(id)
            }
        }
        .accessibilityLabel("Site graph overview")
        .accessibilityHint("Click to select the nearest node")
        .help("Overview of the whole graph — click to jump to a node")
    }
}

private struct SiteGraphNodeButton: View {
    let node: SiteGraphNode
    let referenceCount: Int
    let selected: Bool
    let related: Bool
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Hover only paints while the window is key, so Cmd-Tabbing away mid-hover doesn't leave a
    /// ghost highlight behind in an inactive window (#677).
    private var isHoverActive: Bool { isHovering && controlActiveState != .inactive && !selected }

    private var backgroundOpacity: Double {
        if selected { return 0.24 }
        if related || isHoverActive { return 0.16 }
        return 0.1
    }

    private var tintBorderOpacity: Double { isHoverActive ? 0.55 : 0.35 }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: node.kind.systemImage)
                    .font(.headline)
                Text(node.title)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 112)
                if referenceCount > 0 {
                    Text("\(referenceCount) refs")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(width: 132)
            .frame(minHeight: 76)
            .background(node.kind.tint.opacity(backgroundOpacity))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? Color.accentColor : node.kind.tint.opacity(tintBorderOpacity), lineWidth: selected ? 2 : 1)
            }
            .clipShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: isHoverActive)
        .accessibilityLabel("\(node.kind.title), \(node.title)")
        .help(node.detail ?? node.title)
    }
}

private struct SiteGraphInspector: View {
    @Bindable var model: SiteGraphExplorerModel
    let onOpenFile: (SiteGraphNode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let node = model.selectedNode {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Label(node.kind.title, systemImage: node.kind.systemImage)
                            .font(.headline)
                        Text(node.title)
                            .font(.title3)
                            .fontWeight(.semibold)
                            .textSelection(.enabled)
                        if let detail = node.detail {
                            Text(detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        if node.filePath != nil {
                            Button("Open File", systemImage: "doc.text.magnifyingglass") {
                                onOpenFile(node)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        if let impact = model.selectedImpact {
                            Divider()
                            SiteGraphImpactSection(impact: impact, model: model)
                        }
                        if model.canExplain {
                            Divider()
                            SiteGraphExplainSection(model: model)
                        }
                        Divider()
                        SiteGraphEdgeList(
                            title: "Depends On",
                            edges: model.selectedOutgoing,
                            endpoint: \.targetID,
                            model: model
                        )
                        SiteGraphEdgeList(
                            title: "Referenced By",
                            edges: model.selectedIncoming,
                            endpoint: \.sourceID,
                            model: model
                        )
                    }
                    .padding()
                }
            } else {
                ContentUnavailableView("Select a node", systemImage: "cursorarrow.click")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }
}

/// AI explanation of the selected node (#614): a plain-language synthesis of the structured
/// Impact Analysis above it, generated on-device by Apple Intelligence (never a network call —
/// see the LLM policy under #459). Runtime unavailability renders as guidance, not an error.
private struct SiteGraphExplainSection: View {
    @Bindable var model: SiteGraphExplorerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Explain", systemImage: "sparkles")
                .font(.subheadline)
                .fontWeight(.semibold)
            switch model.explainState {
            case .idle:
                Button("Explain This Node", systemImage: "sparkles") {
                    model.explainSelectedNode()
                }
                .buttonStyle(.bordered)
                Text("Uses on-device Apple Intelligence. Nothing leaves your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .generating(let text):
                if text.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Thinking…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    explanationText(text)
                }
            case .complete(let text):
                explanationText(text)
                retryButton("Regenerate")
            case .unavailable(let message):
                Label(message, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                // The message names a remedy (enable Apple Intelligence); once the user has
                // applied it they must be able to retry without changing the selection.
                retryButton("Try Again")
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                retryButton("Try Again")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("AI explanation")
    }

    private func explanationText(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func retryButton(_ title: LocalizedStringKey) -> some View {
        Button(title, systemImage: "arrow.clockwise") {
            model.explainSelectedNode()
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }
}

/// Project Impact Analysis (#309): shows what editing the selected node would affect — pages
/// (transitively, through any depth of layouts/components), plus dependent layouts, components,
/// styles, containing collections, and directly referenced assets. Every row navigates to that
/// node so the blast radius can be explored in place.
private struct SiteGraphImpactSection: View {
    let impact: ImpactAnalysis.Report
    @Bindable var model: SiteGraphExplorerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Impact", systemImage: "dot.radiowaves.left.and.right")
                .font(.subheadline)
                .fontWeight(.semibold)
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
            SiteGraphImpactNodeList(
                title: "Affects \(count(impact.affectedPages.count, "Page"))",
                nodes: impact.affectedPages, model: model)
            SiteGraphImpactNodeList(
                title: "Affects \(count(impact.affectedEntries.count, "Entry", plural: "Entries"))",
                nodes: impact.affectedEntries, model: model)
            SiteGraphImpactNodeList(
                title: "Included in \(count(impact.affectedCollections.count, "Collection"))",
                nodes: impact.affectedCollections, model: model)
            SiteGraphImpactNodeList(
                title: "Used by \(count(impact.dependentLayouts.count, "Layout"))",
                nodes: impact.dependentLayouts, model: model)
            SiteGraphImpactNodeList(
                title: "Used by \(count(impact.dependentComponents.count, "Component"))",
                nodes: impact.dependentComponents, model: model)
            SiteGraphImpactNodeList(
                title: "Used by \(count(impact.dependentStyles.count, "Style"))",
                nodes: impact.dependentStyles, model: model)
            SiteGraphImpactNodeList(
                title: "References \(count(impact.referencedAssets.count, "Asset"))",
                nodes: impact.referencedAssets, model: model)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Impact analysis")
    }

    /// "This change would affect 18 pages." — the issue's headline number, pages + entries.
    /// The zero-dependents copy acknowledges a non-empty collection membership shown right
    /// below it (membership isn't a dependency, but "nothing else depends on it" directly above
    /// an "Included in 1 Collection" list reads as self-contradictory).
    private var summary: String {
        let routes = impact.affectedPages.count + impact.affectedEntries.count
        if routes > 0 {
            return "Editing this would affect \(count(routes, "page"))."
        }
        if impact.hasDependents {
            return "Editing this would affect other site files, but no rendered pages."
        }
        if !impact.affectedCollections.isEmpty {
            return "Nothing else on this site depends on it — editing it affects only this entry within its collection."
        }
        return "Nothing else on this site depends on it — editing it affects only this file."
    }

    private func count(_ n: Int, _ singular: String, plural: String? = nil) -> String {
        "\(n) \(n == 1 ? singular : (plural ?? singular + "s"))"
    }
}

/// A titled, clickable node list for one impact group. Hidden entirely when the group is empty —
/// unlike `SiteGraphEdgeList`, an empty impact group is noise, not information.
private struct SiteGraphImpactNodeList: View {
    let title: String
    let nodes: [SiteGraphNode]
    @Bindable var model: SiteGraphExplorerModel

    var body: some View {
        if !nodes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                ForEach(nodes) { node in
                    Button {
                        // Not a plain `selectedNodeID = …`: the impact list is computed over the
                        // full snapshot, so the node may be hidden by the toolbar kind filter or
                        // search — revealNode un-hides it so the canvas and edge lists can show
                        // the new selection (PR #545 review).
                        model.revealNode(node)
                    } label: {
                        HStack {
                            Label(node.title, systemImage: node.kind.systemImage)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            if let route = node.route {
                                Text(route)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help(node.detail ?? node.title)
                }
            }
        }
    }
}

private struct SiteGraphEdgeList: View {
    let title: String
    let edges: [SiteGraphEdge]
    let endpoint: KeyPath<SiteGraphEdge, String>
    @Bindable var model: SiteGraphExplorerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
            if edges.isEmpty {
                Text("None")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(edges) { edge in
                    if let node = model.node(id: edge[keyPath: endpoint]) {
                        Button {
                            model.selectedNodeID = node.id
                        } label: {
                            HStack {
                                Label(node.title, systemImage: node.kind.systemImage)
                                Spacer()
                                Text(edge.kind.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private enum SiteGraphLayout {
    static func positions(for nodes: [SiteGraphNode], in size: CGSize) -> [String: CGPoint] {
        guard !nodes.isEmpty else { return [:] }
        let grouped = Dictionary(grouping: nodes, by: \.kind)
        let kinds = SiteGraphNodeKind.allCases.filter { grouped[$0]?.isEmpty == false }
        let columnWidth = max(170, size.width / CGFloat(max(kinds.count, 1)))
        var output: [String: CGPoint] = [:]
        for (column, kind) in kinds.enumerated() {
            let columnNodes = (grouped[kind] ?? []).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            let rowHeight = max(96, (size.height - 60) / CGFloat(max(columnNodes.count, 1)))
            for (row, node) in columnNodes.enumerated() {
                output[node.id] = CGPoint(
                    x: min(size.width - 76, max(76, CGFloat(column) * columnWidth + columnWidth / 2)),
                    y: min(size.height - 50, max(50, CGFloat(row) * rowHeight + rowHeight / 2 + 24))
                )
            }
        }
        return output
    }
}

private extension SiteGraphNodeKind {
    var title: String {
        switch self {
        case .page: return "Pages"
        case .layout: return "Layouts"
        case .component: return "Components"
        case .collection: return "Collections"
        case .contentEntry: return "Entries"
        case .asset: return "Assets"
        case .style: return "Styles"
        }
    }

    var systemImage: String {
        switch self {
        case .page: return "doc.richtext"
        case .layout: return "rectangle.split.3x1"
        case .component: return "square.stack.3d.up"
        case .collection: return "tray.full"
        case .contentEntry: return "text.document"
        case .asset: return "photo"
        case .style: return "paintbrush"
        }
    }

    var tint: Color {
        switch self {
        case .page: return .blue
        case .layout: return .indigo
        case .component: return .teal
        case .collection: return .orange
        case .contentEntry: return .pink
        case .asset: return .green
        case .style: return .purple
        }
    }
}

private extension SiteGraphEdgeKind {
    var title: String {
        switch self {
        case .imports: return "imports"
        case .usesLayout: return "layout"
        case .referencesAsset: return "asset"
        case .contains: return "contains"
        }
    }
}
