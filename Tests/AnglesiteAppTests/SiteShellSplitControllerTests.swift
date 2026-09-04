import Testing
import AppKit
import SwiftUI
import AnglesiteCore
@testable import AnglesiteAppCore

/// Freezes the shell controller's crash-class invariants (#1699 slice 1, design doc §"Why
/// this fixes the crash"): no column may publish sizing constraints, thicknesses are the
/// legacy chrome's constants, and collapse setters are idempotent. The crash itself is only
/// provable in the windowed 5× harness (plan Task 6); these tests pin what makes the shell
/// negotiation-free by construction.
@MainActor
@Suite("SiteShellSplitController invariants (#1699)")
struct SiteShellSplitControllerTests {
    private func makeController() -> SiteShellSplitController<Text, Text, Text> {
        let controller = SiteShellSplitController(
            sidebar: Text("s"), content: Text("c"), inspector: Text("i"))
        _ = controller.view // force viewDidLoad
        return controller
    }

    @Test("no hosting column publishes sizing constraints")
    func sizingOptionsEmpty() {
        let controller = makeController()
        #expect(controller.sidebarHost.sizingOptions == [])
        #expect(controller.contentHost.sizingOptions == [])
        #expect(controller.inspectorHost.sizingOptions == [])
    }

    @Test("three items with sidebar/inspector behaviors and legacy thicknesses")
    func itemsAndThicknesses() {
        let controller = makeController()
        #expect(controller.splitViewItems.count == 3)
        #expect(controller.sidebarItem.behavior == .sidebar)
        #expect(controller.inspectorItem.behavior == .inspector)
        #expect(controller.sidebarItem.minimumThickness == 200)
        #expect(controller.sidebarItem.maximumThickness == 360)
        #expect(controller.inspectorItem.minimumThickness == 260)
        #expect(controller.inspectorItem.maximumThickness == 420)
        #expect(controller.splitView.autosaveName == "site-shell")
    }

    @Test("collapse setters converge and are idempotent")
    func collapseSetters() {
        let controller = makeController()
        controller.setSidebarCollapsed(true, animated: false)
        #expect(controller.sidebarItem.isCollapsed)
        controller.setSidebarCollapsed(true, animated: false) // no-op, must not throw/toggle
        #expect(controller.sidebarItem.isCollapsed)
        controller.setInspectorCollapsed(true, animated: false)
        #expect(controller.inspectorItem.isCollapsed)
        controller.setInspectorCollapsed(false, animated: false)
        #expect(!controller.inspectorItem.isCollapsed)
    }

    @Test("update replaces the hosted root views")
    func updateReplacesRoots() {
        let controller = makeController()
        controller.update(sidebar: Text("s2"), content: Text("c2"), inspector: Text("i2"))
        // No public accessor for rootView equality on Text; the contract here is just that
        // update() executes without touching the split structure.
        #expect(controller.splitViewItems.count == 3)
    }

    @Test("installToolbar builds a toolbar with the shell's identifier and delegate")
    @MainActor
    func installToolbarSetsIdentifierAndDelegate() {
        let controller = SiteShellSplitController(
            sidebar: Text("sidebar"), content: Text("content"), inspector: Text("inspector"))
        controller.installToolbar(itemView: { _ in AnyView(EmptyView()) }, insertMenuItems: { [] })
        let toolbar = try? #require(controller.ownedToolbar)
        #expect(toolbar?.identifier == SiteShellToolbarDelegate.toolbarIdentifier)
        #expect(toolbar?.allowsUserCustomization == true)
        #expect(toolbar?.autosavesConfiguration == true)
    }

    @Test("installToolbar is idempotent — calling it twice keeps one toolbar")
    @MainActor
    func installToolbarIsIdempotent() {
        let controller = SiteShellSplitController(
            sidebar: Text("sidebar"), content: Text("content"), inspector: Text("inspector"))
        controller.installToolbar(itemView: { _ in AnyView(EmptyView()) }, insertMenuItems: { [] })
        let first = controller.ownedToolbar
        controller.installToolbar(itemView: { _ in AnyView(EmptyView()) }, insertMenuItems: { [] })
        #expect(controller.ownedToolbar === first)
    }

    @Test("insertTrackingSeparators lands the separators at the intended positions for a realistically populated toolbar")
    @MainActor
    func insertTrackingSeparatorsPositionsForRealisticItemCount() {
        // Seeds a standalone toolbar with the real default-item set — without a window,
        // `NSToolbar.items` never gets populated by SiteShellSplitController's own
        // installToolbar path, so this builds one directly via the same delegate the shell
        // uses, exercising the N>0 branch of the clamped-index math the N=0 tests above
        // can't reach.
        let delegate = SiteShellToolbarDelegate(itemView: { _ in AnyView(EmptyView()) }, insertMenuItems: { [] })
        // The tracking-separator branches only build an item when `splitView` is set (see
        // `SiteShellToolbarDelegateTests.trackingSeparatorItemsRequireSplitView`) — without
        // this, `NSToolbar.insertItem` below would call the delegate, get `nil` back, and
        // silently no-op instead of inserting anything.
        delegate.splitView = NSSplitView()
        let toolbar = NSToolbar(identifier: SiteShellToolbarDelegate.toolbarIdentifier)
        toolbar.delegate = delegate
        for id in SiteShellToolbarDelegate.defaultItemIdentifiers {
            toolbar.insertItem(withItemIdentifier: id, at: toolbar.items.count)
        }
        let defaultCount = toolbar.items.count
        #expect(defaultCount > 1, "the default set must have more than one item for this test to be meaningful")

        SiteShellSplitController<Text, Text, Text>.insertTrackingSeparators(into: toolbar)

        #expect(toolbar.items.count == defaultCount + 2)
        #expect(toolbar.items[1].itemIdentifier == SiteShellToolbarDelegate.sidebarTrackingSeparator)
        #expect(toolbar.items[toolbar.items.count - 2].itemIdentifier == SiteShellToolbarDelegate.inspectorTrackingSeparator)
        // Every original default item is still present, undisturbed, on either side of the
        // two separators that were spliced in.
        let survivingIdentifiers = toolbar.items.map(\.itemIdentifier).filter {
            $0 != SiteShellToolbarDelegate.sidebarTrackingSeparator && $0 != SiteShellToolbarDelegate.inspectorTrackingSeparator
        }
        #expect(survivingIdentifiers == SiteShellToolbarDelegate.defaultItemIdentifiers)
    }
}
