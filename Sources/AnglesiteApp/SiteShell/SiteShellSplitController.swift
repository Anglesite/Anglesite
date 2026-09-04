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
    /// One-shot latch for `attachOwnedToolbarIfNeeded()`'s item seeding — `viewDidAppear` fires
    /// more than once per window (re-key, miniaturize/restore), and the seeding is additive.
    private var seededToolbarItems = false

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
    /// `viewDidAppear()` — is what hands the finished toolbar to the window and does the item
    /// seeding that only means anything once `NSToolbar.items` is populated.
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

    /// Hands `ownedToolbar` to the window and seeds the items that aren't part of the delegate's
    /// default set (the trailing search field, the two tracking separators). Runs on every
    /// appearance because `installToolbar` can't: it is called from
    /// `SiteShellView.makeNSViewController`, one full layout pass before this controller's view
    /// reaches a window. Both halves are idempotent — the window assignment compares identity,
    /// and the seeding runs once per controller *and* skips identifiers a restored autosaved
    /// configuration already put in the toolbar.
    private func attachOwnedToolbarIfNeeded() {
        guard let toolbar = ownedToolbar, let window = view.window else { return }
        if window.toolbar !== toolbar { window.toolbar = toolbar }
        guard !seededToolbarItems else { return }
        seededToolbarItems = true
        Self.insertSearchItem(into: toolbar)
        Self.insertTrackingSeparators(into: toolbar)
    }

    /// Appends the search item's identifier at the trailing edge, matching where `.searchable`
    /// put the legacy field. The item itself comes back from
    /// `SiteShellToolbarDelegate.toolbar(_:itemForItemIdentifier:willBeInsertedIntoToolbar:)` by
    /// identity, so the window's one `SiteShellSearchToolbarItem` is what lands here.
    static func insertSearchItem(into toolbar: NSToolbar) {
        guard !toolbar.items.contains(where: { $0.itemIdentifier == SiteShellSearchToolbarItem.identifier })
        else { return }
        toolbar.insertItem(withItemIdentifier: SiteShellSearchToolbarItem.identifier, at: toolbar.items.count)
    }

    /// Inserts the two tracking-separator identifiers (design doc §"Toolbar (slice 2)": "a
    /// strict chrome upgrade over today"). The items themselves are constructed by
    /// `SiteShellToolbarDelegate.toolbar(_:itemForItemIdentifier:willBeInsertedIntoToolbar:)`
    /// when the toolbar asks for them — `NSToolbar` retains only the identifier once inserted,
    /// not the instance, so there is nothing to build here beyond the identifiers themselves.
    ///
    /// `static` (#1699 slice 2 review fix) so the clamped-index math can be exercised directly,
    /// against a toolbar pre-populated with a realistic default-item count, without needing a
    /// real window — `NSToolbar.items` only reflects the delegate's default set once the toolbar
    /// is attached to one. `attachOwnedToolbarIfNeeded()` is the only production call site.
    ///
    /// Clamped rather than the literal `1` / `count - 1`: `NSToolbar.insertItem(at:)`
    /// requires `0...items.count`, and `toolbar.items` is empty for a toolbar that has never
    /// been attached to a window (this class's own unit tests included, since `view.window`
    /// is nil there). These positions land at the intended spots (right after the leading
    /// item, right before the trailing one) once real default items exist, and degrade to
    /// safe no-crash inserts otherwise.
    static func insertTrackingSeparators(into toolbar: NSToolbar) {
        let present = Set(toolbar.items.map(\.itemIdentifier))
        guard !present.contains(SiteShellToolbarDelegate.sidebarTrackingSeparator),
              !present.contains(SiteShellToolbarDelegate.inspectorTrackingSeparator)
        else { return }
        let sidebarIndex = min(1, toolbar.items.count)
        toolbar.insertItem(withItemIdentifier: SiteShellToolbarDelegate.sidebarTrackingSeparator, at: sidebarIndex)
        let inspectorIndex = max(sidebarIndex + 1, toolbar.items.count - 1)
        toolbar.insertItem(
            withItemIdentifier: SiteShellToolbarDelegate.inspectorTrackingSeparator, at: inspectorIndex)
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
