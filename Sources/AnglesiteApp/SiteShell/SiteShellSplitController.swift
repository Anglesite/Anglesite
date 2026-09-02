import AppKit
import SwiftUI

/// The site window's AppKit split shell (#1699 Stage 3, slice 1): sidebar | content |
/// inspector as native `NSSplitViewItem`s over `NSHostingController` columns.
///
/// The crash-class mechanism this replaces is absent by construction (design doc §"Why this
/// fixes the crash"): every hosting controller sets `sizingOptions = []`, so no column
/// publishes min/ideal/max constraints, and the private SwiftUI `SplitViewChildController`
/// negotiation that aborted the app (#1696, 5/5 on 26A5425a) has no counterpart here. Column
/// widths are governed solely by the constant thicknesses below plus the split view's own
/// autosave. Collapse changes are explicit, app-ordered mutations; the KVO hooks report
/// user/AppKit-driven changes (drag-collapse, `toggleSidebar:` from the stock View-menu
/// item, which `NSSplitViewController` answers natively) back to the SwiftUI bindings.
@MainActor
final class SiteShellSplitController<Sidebar: View, Content: View, Inspector: View>:
    NSSplitViewController {
    /// Matches the legacy `navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)`.
    static var sidebarThickness: (min: CGFloat, max: CGFloat) { (200, 360) }
    /// Matches the legacy `.inspectorColumnWidth(min: 260, ideal: 300, max: 420)`.
    static var inspectorThickness: (min: CGFloat, max: CGFloat) { (260, 420) }
    /// Legacy ideal widths, applied once on first run (afterwards autosave restores).
    private static var idealSidebarWidth: CGFloat { 240 }
    private static var idealInspectorWidth: CGFloat { 300 }

    let sidebarHost: NSHostingController<Sidebar>
    let contentHost: NSHostingController<Content>
    let inspectorHost: NSHostingController<Inspector>
    let sidebarItem: NSSplitViewItem
    let inspectorItem: NSSplitViewItem

    /// Fired on every `isCollapsed` change, including the KVO echo of our own setters —
    /// `SiteShellState.visibilityWriteBack` filters echoes to no-ops on the SwiftUI side.
    var onSidebarCollapseChange: (@MainActor (Bool) -> Void)?
    var onInspectorCollapseChange: (@MainActor (Bool) -> Void)?

    private var observations: [NSKeyValueObservation] = []
    private var appliedInitialLayout = false

    init(sidebar: Sidebar, content: Content, inspector: Inspector) {
        sidebarHost = NSHostingController(rootView: sidebar)
        contentHost = NSHostingController(rootView: content)
        inspectorHost = NSHostingController(rootView: inspector)
        sidebarHost.sizingOptions = []
        contentHost.sizingOptions = []
        inspectorHost.sizingOptions = []

        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebarItem.minimumThickness = Self.sidebarThickness.min
        sidebarItem.maximumThickness = Self.sidebarThickness.max
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorHost)
        inspectorItem.minimumThickness = Self.inspectorThickness.min
        inspectorItem.maximumThickness = Self.inspectorThickness.max

        super.init(nibName: nil, bundle: nil)

        addSplitViewItem(sidebarItem)
        addSplitViewItem(NSSplitViewItem(viewController: contentHost))
        addSplitViewItem(inspectorItem)
        splitView.autosaveName = "site-shell"

        observations = [
            sidebarItem.observe(\.isCollapsed, options: [.new]) { [weak self] item, _ in
                // NSSplitViewItem state changes land on the main thread; assumeIsolated
                // documents that rather than hopping through a Task that could reorder
                // against a subsequent programmatic mutation.
                MainActor.assumeIsolated {
                    self?.onSidebarCollapseChange?(item.isCollapsed)
                }
            },
            inspectorItem.observe(\.isCollapsed, options: [.new]) { [weak self] item, _ in
                MainActor.assumeIsolated {
                    self?.onInspectorCollapseChange?(item.isCollapsed)
                }
            },
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SiteShellSplitController is code-constructed only")
    }

    /// Re-pushes SwiftUI content into the hosted columns — called from
    /// `SiteShellView.updateNSViewController` on every SwiftUI update so the columns stay live.
    func update(sidebar: Sidebar, content: Content, inspector: Inspector) {
        sidebarHost.rootView = sidebar
        contentHost.rootView = content
        inspectorHost.rootView = inspector
    }

    func setSidebarCollapsed(_ collapsed: Bool, animated: Bool) {
        guard sidebarItem.isCollapsed != collapsed else { return }
        (animated ? sidebarItem.animator() : sidebarItem).isCollapsed = collapsed
    }

    func setInspectorCollapsed(_ collapsed: Bool, animated: Bool) {
        guard inspectorItem.isCollapsed != collapsed else { return }
        (animated ? inspectorItem.animator() : inspectorItem).isCollapsed = collapsed
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applyInitialLayoutIfNeeded()
    }

    /// First-run column widths (the legacy chrome's ideals). Subsequent runs are restored by
    /// `autosaveName`; the guard keys off the autosave defaults entry AppKit writes.
    private func applyInitialLayoutIfNeeded() {
        guard !appliedInitialLayout, view.frame.width > 0 else { return }
        appliedInitialLayout = true
        let autosaveDefaultsKey = "NSSplitView Subview Frames site-shell"
        guard UserDefaults.standard.object(forKey: autosaveDefaultsKey) == nil else { return }
        splitView.setPosition(Self.idealSidebarWidth, ofDividerAt: 0)
        if !inspectorItem.isCollapsed {
            splitView.setPosition(view.frame.width - Self.idealInspectorWidth, ofDividerAt: 1)
        }
    }
}
