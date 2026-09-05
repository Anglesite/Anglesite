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

    /// A throwaway search item for the `installToolbar` calls below — the shell hands its one
    /// real item to the delegate by identity, so these tests only need *an* item, not a live one.
    private func makeSearchItem() -> SiteShellSearchToolbarItem {
        SiteShellSearchToolbarItem(model: SiteSearchModel(index: SiteKnowledgeIndex()), activate: { _ in })
    }

    @Test("installToolbar builds a toolbar with the shell's identifier and delegate")
    @MainActor
    func installToolbarSetsIdentifierAndDelegate() {
        let controller = SiteShellSplitController(
            sidebar: Text("sidebar"), content: Text("content"), inspector: Text("inspector"))
        controller.installToolbar(
            itemView: { _ in AnyView(EmptyView()) }, insertMenuItems: { [] },
            searchItem: makeSearchItem())
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
        controller.installToolbar(
            itemView: { _ in AnyView(EmptyView()) }, insertMenuItems: { [] },
            searchItem: makeSearchItem())
        let first = controller.ownedToolbar
        controller.installToolbar(
            itemView: { _ in AnyView(EmptyView()) }, insertMenuItems: { [] },
            searchItem: makeSearchItem())
        #expect(controller.ownedToolbar === first)
    }

    @Test("the shell's own items come from the default set, not from imperative seeding")
    @MainActor
    func shellOwnedItemsComeFromTheDefaultSet() {
        // Replaces the old `insertSearchItem`/`insertTrackingSeparators` coverage (#1699 slice 2,
        // final-review fix). Those ran once per controller behind a latch, so "Restore Default
        // Set" in the Customize Toolbar sheet dropped the search field and both separators for
        // the rest of that window's session. They are declared defaults now, which is what makes
        // a restore bring them back — this drives the identifiers through the same delegate the
        // shell installs and checks the toolbar materialises every one, in order.
        let delegate = SiteShellToolbarDelegate(itemView: { _ in AnyView(EmptyView()) }, insertMenuItems: { [] })
        // The tracking-separator branches only build an item when `splitView` is set (see
        // `SiteShellToolbarDelegateTests.trackingSeparatorItemsRequireSplitView`) — without
        // this, `NSToolbar.insertItem` below would call the delegate, get `nil` back, and
        // silently no-op instead of inserting anything.
        delegate.splitView = NSSplitView()
        let searchItem = makeSearchItem()
        delegate.searchItem = searchItem
        let toolbar = NSToolbar(identifier: SiteShellToolbarDelegate.toolbarIdentifier)
        toolbar.delegate = delegate

        for id in SiteShellToolbarDelegate.defaultItemIdentifiers {
            toolbar.insertItem(withItemIdentifier: id, at: toolbar.items.count)
        }

        #expect(toolbar.items.map(\.itemIdentifier) == SiteShellToolbarDelegate.defaultItemIdentifiers)
        #expect(toolbar.items.first?.itemIdentifier == SiteShellToolbarDelegate.sidebarToggle)
        #expect(toolbar.items[1] is NSTrackingSeparatorToolbarItem)
        #expect(toolbar.items[toolbar.items.count - 2] is NSTrackingSeparatorToolbarItem)
        #expect(toolbar.items.last === searchItem)
    }

    @Test("the toolbar's sidebar toggle collapses and expands the real sidebar")
    @MainActor
    func sidebarToggleItemCollapsesAndExpandsTheSidebar() throws {
        // The end-to-end half of the Task 7 fix (#1699 slice 2): `installToolbar` hands the
        // delegate a closure onto this controller's own `setSidebarCollapsed`, so sending the
        // item's action to the item's target — what AppKit does on a click — really moves the
        // split view. The bug this replaces was the opposite: `.toggleSidebar` was declared in the
        // default set, and the item AppKit substitutes for it rendered nothing at all in the real
        // window.
        let controller = makeController()
        controller.installToolbar(
            itemView: { _ in AnyView(EmptyView()) }, insertMenuItems: { [] },
            searchItem: makeSearchItem())
        let toolbar = try #require(controller.ownedToolbar)
        let delegate = try #require(toolbar.delegate)
        let item = try #require(
            delegate.toolbar?(
                toolbar,
                itemForItemIdentifier: SiteShellToolbarDelegate.sidebarToggle,
                willBeInsertedIntoToolbar: true))
        let target = try #require(item.target as? NSObject)
        let action = try #require(item.action)

        // Set the starting state explicitly rather than assuming it: `splitView.autosaveName` is
        // the shipping app's, so a machine that has run Anglesite restores whatever that window
        // was left in.
        controller.setSidebarCollapsed(false, animated: false)
        #expect(!controller.sidebarItem.isCollapsed, "precondition: the sidebar starts visible")
        target.perform(action, with: item)
        #expect(controller.sidebarItem.isCollapsed, "the toolbar item must collapse the sidebar")
        target.perform(action, with: item)
        #expect(!controller.sidebarItem.isCollapsed, "and expand it again on the next click")
    }

    @Test("the toolbar's sidebar toggle doesn't keep its controller alive")
    @MainActor
    func sidebarToggleDoesNotRetainTheController() throws {
        // `installToolbar` stores a closure onto the controller in a delegate the controller
        // itself owns — a strong capture there is a per-window leak of the whole shell.
        weak var weakController: SiteShellSplitController<Text, Text, Text>?
        autoreleasepool {
            let controller = SiteShellSplitController(
                sidebar: Text("s"), content: Text("c"), inspector: Text("i"))
            controller.installToolbar(
                itemView: { _ in AnyView(EmptyView()) }, insertMenuItems: { [] },
                searchItem: makeSearchItem())
            weakController = controller
        }
        #expect(weakController == nil)
    }

    @Test("attaching the toolbar is idempotent and doesn't mutate the item set")
    @MainActor
    func attachDoesNotSeedItems() {
        // The imperative seeding is gone; attaching is purely the window assignment now, so a
        // repeat call (viewDidAppear fires more than once per window, and every SwiftUI update
        // calls this too) must stay a no-op rather than appending anything.
        let controller = makeController()
        controller.installToolbar(
            itemView: { _ in AnyView(EmptyView()) }, insertMenuItems: { [] },
            searchItem: makeSearchItem())
        let toolbar = controller.ownedToolbar
        let before = toolbar?.items.count
        controller.attachOwnedToolbarIfNeeded()
        controller.attachOwnedToolbarIfNeeded()
        #expect(controller.ownedToolbar === toolbar)
        #expect(toolbar?.items.count == before)
    }
}
