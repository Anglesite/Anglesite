import AppKit
import SwiftUI
import AnglesiteCore

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

    private(set) var ownedToolbar: NSToolbar?
    private var toolbarDelegate: SiteShellToolbarDelegate?

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

    /// Builds this window's owned `NSToolbar` (#1699 slice 2). Idempotent — a second call is a
    /// no-op, since `SiteShellView.makeNSViewController` runs once per window but `viewDidAppear`
    /// can fire more than once (e.g. window re-key).
    ///
    /// Building and *attaching* are deliberately separate: this runs from
    /// `makeNSViewController`, before the controller's view has ever been in a window, so
    /// `view.window` is still nil here. `attachOwnedToolbarIfNeeded()` — driven by
    /// `viewDidAppear()` — is what hands the finished toolbar to the window.
    func installToolbar(
        itemView: @escaping @MainActor (SiteToolbarItemID) -> AnyView,
        insertMenuItems: @escaping @MainActor () -> [NSMenuItem],
        searchItem: SiteShellSearchToolbarItem
    ) {
        guard ownedToolbar == nil else { return }
        let delegate = SiteShellToolbarDelegate(itemView: itemView, insertMenuItems: insertMenuItems)
        let toolbar = NSToolbar(identifier: SiteShellToolbarDelegate.toolbarIdentifier)
        toolbar.delegate = delegate
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        delegate.splitView = splitView
        delegate.searchItem = searchItem
        toolbarDelegate = delegate
        ownedToolbar = toolbar
        attachOwnedToolbarIfNeeded()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        attachOwnedToolbarIfNeeded()
    }

    /// Hands `ownedToolbar` to the window. It can't happen in `installToolbar`: that is called
    /// from `SiteShellView.makeNSViewController`, one full layout pass before this controller's
    /// view reaches a window.
    ///
    /// Called from three places on purpose — `installToolbar` (a no-op then, but free),
    /// `viewDidAppear()`, and `SiteShellView.updateNSViewController` on every SwiftUI update. The
    /// last one makes the attachment *self-healing* rather than single-shot: if `viewDidAppear`
    /// ever fails to reach us through the representable's containment, or SwiftUI re-assigns
    /// `window.toolbar` on its own (the flag-on branch still applies `.toolbarRole`/
    /// `.navigationTitle`/`.navigationDocument` to this window), the next update puts the shell's
    /// toolbar back instead of leaving the window permanently toolbar-less. It is cheap and
    /// idempotent: the window assignment compares identity.
    ///
    /// There is deliberately no item *seeding* here any more (#1699 slice 2, final-review fix).
    /// The search field and both tracking separators are declared in
    /// `SiteShellToolbarDelegate.defaultItemIdentifiers`, so AppKit populates them the same way
    /// it populates every other default item — including on "Restore Default Set", which the
    /// old one-shot-latched imperative seeding could not survive.
    func attachOwnedToolbarIfNeeded() {
        guard let toolbar = ownedToolbar, let window = view.window else { return }
        if window.toolbar !== toolbar { window.toolbar = toolbar }
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
