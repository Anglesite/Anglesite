import Testing
import AppKit
import SwiftUI
import AnglesiteCore
@testable import AnglesiteAppCore

@Suite("SiteShellToolbarDelegate")
@MainActor
struct SiteShellToolbarDelegateTests {
    @Test("toolbar identifier is a fresh key, distinct from the legacy SwiftUI one")
    func toolbarIdentifierIsFresh() {
        #expect(SiteShellToolbarDelegate.toolbarIdentifier == NSToolbar.Identifier("site.shell"))
    }

    @Test("item identifier round-trips SiteToolbarItemID's raw value")
    func itemIdentifierRoundTrips() {
        for id in SiteToolbarItemID.allCases {
            #expect(
                SiteShellToolbarDelegate.itemIdentifier(for: id).rawValue == id.rawValue,
                "AXID.toolbar(_:) and saved-customization compatibility both key off the raw SiteToolbarItemID string — the shell must reuse it verbatim, not remap it.")
        }
    }

    @Test("default item identifiers match SiteToolbarItemID.isDefaultVisible, in enum order")
    func defaultItemIdentifiersMatchIsDefaultVisible() {
        let expected = SiteToolbarItemID.allCases
            .filter(\.isDefaultVisible)
            .map { SiteShellToolbarDelegate.itemIdentifier(for: $0) }
        #expect(SiteShellToolbarDelegate.defaultItemIdentifiers == expected)
    }

    @Test("allowed item identifiers cover every SiteToolbarItemID exactly once, plus the shell's own three")
    func allowedItemIdentifiersCoverAllCases() {
        let allowed = SiteShellToolbarDelegate.allowedItemIdentifiers
        // The three the shell seeds itself rather than declaring as defaults. They must be
        // *allowed* even so: `NSToolbar` reconciles a restored autosaved configuration against
        // this set, so anything missing from it survives the launch that inserts it and is
        // dropped on the next one.
        let shellOwned: Set<NSToolbarItem.Identifier> = [
            SiteShellSearchToolbarItem.identifier,
            SiteShellToolbarDelegate.sidebarTrackingSeparator,
            SiteShellToolbarDelegate.inspectorTrackingSeparator,
        ]
        let expected = Set(SiteToolbarItemID.allCases.map { SiteShellToolbarDelegate.itemIdentifier(for: $0) })
            .union(shellOwned)
        #expect(Set(allowed) == expected)
        #expect(allowed.count == expected.count, "no duplicate identifiers")
        for identifier in shellOwned {
            #expect(allowed.contains(identifier))
        }
    }

    @Test("every item the shell seeds into the toolbar is in the allowed set")
    func seededItemsAreAllowed() {
        // The seeding in `SiteShellSplitController.attachOwnedToolbarIfNeeded()` and this set have
        // to agree — an identifier inserted but not allowed vanishes on the next launch.
        let allowed = Set(SiteShellToolbarDelegate.allowedItemIdentifiers)
        #expect(allowed.contains(SiteShellSearchToolbarItem.identifier))
        #expect(allowed.contains(SiteShellToolbarDelegate.sidebarTrackingSeparator))
        #expect(allowed.contains(SiteShellToolbarDelegate.inspectorTrackingSeparator))
        for identifier in SiteShellToolbarDelegate.defaultItemIdentifiers {
            #expect(allowed.contains(identifier))
        }
    }

    @Test("default set is a subset of the allowed set")
    func defaultIsSubsetOfAllowed() {
        let allowed = Set(SiteShellToolbarDelegate.allowedItemIdentifiers)
        for identifier in SiteShellToolbarDelegate.defaultItemIdentifiers {
            #expect(allowed.contains(identifier))
        }
    }

    @Test("non-insert items become a plain NSToolbarItem hosting the supplied view")
    func nonInsertItemsAreHostedViewItems() {
        let delegate = SiteShellToolbarDelegate(
            itemView: { _ in AnyView(Text("stub")) },
            insertMenuItems: { [] }
        )
        let toolbar = NSToolbar(identifier: SiteShellToolbarDelegate.toolbarIdentifier)
        let item = delegate.toolbar(
            toolbar,
            itemForItemIdentifier: SiteShellToolbarDelegate.itemIdentifier(for: .backup),
            willBeInsertedIntoToolbar: true)
        #expect(item?.itemIdentifier == SiteShellToolbarDelegate.itemIdentifier(for: .backup))
        #expect(item?.view is NSHostingView<AnyView>)
    }

    @Test("insert item is an NSMenuToolbarItem carrying the supplied menu items")
    func insertItemIsMenuToolbarItem() throws {
        let stubItem = NSMenuItem(title: "New Page…", action: nil, keyEquivalent: "")
        let delegate = SiteShellToolbarDelegate(
            itemView: { _ in AnyView(Text("stub")) },
            insertMenuItems: { [stubItem] }
        )
        let toolbar = NSToolbar(identifier: SiteShellToolbarDelegate.toolbarIdentifier)
        let item = delegate.toolbar(
            toolbar,
            itemForItemIdentifier: SiteShellToolbarDelegate.itemIdentifier(for: .insert),
            willBeInsertedIntoToolbar: true)
        let menuItem = try #require(item as? NSMenuToolbarItem)
        #expect(menuItem.menu.items.map(\.title) == ["New Page…"])
    }

    @Test("tracking separator identifiers return an NSTrackingSeparatorToolbarItem-free nil outside a split view")
    func unknownIdentifierReturnsNil() {
        let delegate = SiteShellToolbarDelegate(itemView: { _ in AnyView(EmptyView()) }, insertMenuItems: { [] })
        let toolbar = NSToolbar(identifier: SiteShellToolbarDelegate.toolbarIdentifier)
        let item = delegate.toolbar(
            toolbar,
            itemForItemIdentifier: NSToolbarItem.Identifier("not.a.real.item"),
            willBeInsertedIntoToolbar: true)
        #expect(item == nil)
    }

    @Test("tracking separator identifiers become NSTrackingSeparatorToolbarItems bound to the split view's dividers")
    func trackingSeparatorItemsUseSplitViewDividers() throws {
        let delegate = SiteShellToolbarDelegate(itemView: { _ in AnyView(EmptyView()) }, insertMenuItems: { [] })
        let splitView = NSSplitView()
        delegate.splitView = splitView
        let toolbar = NSToolbar(identifier: SiteShellToolbarDelegate.toolbarIdentifier)

        let sidebarItem = try #require(
            delegate.toolbar(
                toolbar,
                itemForItemIdentifier: SiteShellToolbarDelegate.sidebarTrackingSeparator,
                willBeInsertedIntoToolbar: true) as? NSTrackingSeparatorToolbarItem)
        #expect(sidebarItem.itemIdentifier == SiteShellToolbarDelegate.sidebarTrackingSeparator)
        #expect(sidebarItem.splitView === splitView)
        #expect(sidebarItem.dividerIndex == 0)

        let inspectorItem = try #require(
            delegate.toolbar(
                toolbar,
                itemForItemIdentifier: SiteShellToolbarDelegate.inspectorTrackingSeparator,
                willBeInsertedIntoToolbar: true) as? NSTrackingSeparatorToolbarItem)
        #expect(inspectorItem.itemIdentifier == SiteShellToolbarDelegate.inspectorTrackingSeparator)
        #expect(inspectorItem.splitView === splitView)
        #expect(inspectorItem.dividerIndex == 1)
    }

    @Test("tracking separator identifiers return nil when no split view has been set")
    func trackingSeparatorItemsRequireSplitView() {
        let delegate = SiteShellToolbarDelegate(itemView: { _ in AnyView(EmptyView()) }, insertMenuItems: { [] })
        let toolbar = NSToolbar(identifier: SiteShellToolbarDelegate.toolbarIdentifier)
        #expect(delegate.splitView == nil)
        #expect(
            delegate.toolbar(
                toolbar,
                itemForItemIdentifier: SiteShellToolbarDelegate.sidebarTrackingSeparator,
                willBeInsertedIntoToolbar: true) == nil)
        #expect(
            delegate.toolbar(
                toolbar,
                itemForItemIdentifier: SiteShellToolbarDelegate.inspectorTrackingSeparator,
                willBeInsertedIntoToolbar: true) == nil)
    }
}
