import Testing
import AppKit
import Observation
import SwiftUI
import AnglesiteCore
import AnglesiteTestSupport
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

    /// The shell's own four identifiers — everything in the toolbar that isn't a
    /// `SiteToolbarItemID`.
    private static let shellOwned: Set<NSToolbarItem.Identifier> = [
        SiteShellToolbarDelegate.sidebarToggle,
        SiteShellSearchToolbarItem.identifier,
        SiteShellToolbarDelegate.sidebarTrackingSeparator,
        SiteShellToolbarDelegate.inspectorTrackingSeparator,
    ]

    @Test("default set is the sidebar toggle, the separators and search around SiteToolbarItemID.isDefaultVisible")
    func defaultItemIdentifiersMatchIsDefaultVisible() {
        // All four shell-owned entries are *declared* defaults rather than seeded imperatively
        // (#1699 slice 2, final-review fix): a "Restore Default Set" in the Customize Toolbar
        // sheet restores exactly what this array says, and the seeding it replaced was a
        // one-shot latch per window, so the search field and separators never came back.
        let expected: [NSToolbarItem.Identifier] =
            [SiteShellToolbarDelegate.sidebarToggle, SiteShellToolbarDelegate.sidebarTrackingSeparator]
            + SiteToolbarItemID.allCases
                .filter(\.isDefaultVisible)
                .map { SiteShellToolbarDelegate.itemIdentifier(for: $0) }
            + [SiteShellToolbarDelegate.inspectorTrackingSeparator, SiteShellSearchToolbarItem.identifier]
        #expect(SiteShellToolbarDelegate.defaultItemIdentifiers == expected)
    }

    @Test("the sidebar toggle leads the default set and the search field trails it")
    func sidebarToggleLeadsAndSearchTrails() {
        // The design doc's compatibility table requires the shell to supply its own sidebar
        // toggle item once `NavigationSplitView` (which auto-inserted one) is gone.
        let defaults = SiteShellToolbarDelegate.defaultItemIdentifiers
        #expect(defaults.first == SiteShellToolbarDelegate.sidebarToggle)
        #expect(defaults.dropFirst().first == SiteShellToolbarDelegate.sidebarTrackingSeparator)
        #expect(defaults.last == SiteShellSearchToolbarItem.identifier)
        #expect(defaults.dropLast().last == SiteShellToolbarDelegate.inspectorTrackingSeparator)
    }

    @Test("allowed item identifiers cover every SiteToolbarItemID exactly once, plus the shell's own four")
    func allowedItemIdentifiersCoverAllCases() {
        let allowed = SiteShellToolbarDelegate.allowedItemIdentifiers
        let expected = Set(SiteToolbarItemID.allCases.map { SiteShellToolbarDelegate.itemIdentifier(for: $0) })
            .union(Self.shellOwned)
        #expect(Set(allowed) == expected)
        #expect(allowed.count == expected.count, "no duplicate identifiers")
        for identifier in Self.shellOwned {
            #expect(allowed.contains(identifier))
        }
    }

    @Test("every shell-owned identifier is in the allowed set")
    func seededItemsAreAllowed() {
        // `NSToolbar` reconciles a restored autosaved configuration against the allowed set, and
        // `autosavesConfiguration` is on — an identifier in the default set but missing here is
        // silently dropped on the next launch.
        let allowed = Set(SiteShellToolbarDelegate.allowedItemIdentifiers)
        for identifier in Self.shellOwned {
            #expect(allowed.contains(identifier))
        }
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

    @Test("the shell builds its own sidebar toggle, targeted at the delegate")
    func sidebarToggleIsBuiltByTheDelegate() throws {
        // The Task 7 fix (#1699 slice 2): the toggle used to be declared as AppKit's own
        // `.toggleSidebar`, which never rendered in the real app — see
        // `systemSidebarToggleNeverReachesTheDelegate` below for the mechanism. It is the
        // delegate's item now, with a real target/action pair instead of a responder-chain hunt.
        let delegate = SiteShellToolbarDelegate(
            itemView: { _ in AnyView(EmptyView()) }, insertMenuItems: { [] })
        let toolbar = NSToolbar(identifier: SiteShellToolbarDelegate.toolbarIdentifier)

        let item = try #require(
            delegate.toolbar(
                toolbar,
                itemForItemIdentifier: SiteShellToolbarDelegate.sidebarToggle,
                willBeInsertedIntoToolbar: true),
            "the delegate must build the sidebar toggle — nothing else will")
        #expect(item.itemIdentifier == SiteShellToolbarDelegate.sidebarToggle)
        #expect(!item.label.isEmpty)
        #expect(item.paletteLabel == item.label)
        #expect(item.image != nil, "an item with neither title nor view draws as an empty slot")
        #expect(item.isBordered)
        #expect(item.target as? SiteShellToolbarDelegate === delegate, "a direct target, not the responder chain")
        #expect(item.action != nil)
    }

    @Test("clicking the sidebar toggle runs the delegate's toggle closure")
    func sidebarToggleActionRunsTheToggleClosure() throws {
        // Sending the item's own action to the item's own target is exactly what AppKit does on a
        // click, so this covers the wiring end to end on the delegate's side;
        // `SiteShellSplitControllerTests.sidebarToggleItemCollapsesAndExpandsTheSidebar` drives
        // the same action against a real split controller.
        var toggles = 0
        let delegate = SiteShellToolbarDelegate(
            itemView: { _ in AnyView(EmptyView()) }, insertMenuItems: { [] })
        delegate.toggleSidebar = { toggles += 1 }
        let toolbar = NSToolbar(identifier: SiteShellToolbarDelegate.toolbarIdentifier)
        let item = try #require(
            delegate.toolbar(
                toolbar,
                itemForItemIdentifier: SiteShellToolbarDelegate.sidebarToggle,
                willBeInsertedIntoToolbar: true))

        let target = try #require(item.target as? NSObject)
        let action = try #require(item.action)
        target.perform(action, with: item)
        #expect(toggles == 1)
        target.perform(action, with: item)
        #expect(toggles == 2, "the item toggles on every click rather than latching")
    }

    @Test("a sidebar toggle with no toggle closure set is inert, not a crash")
    func sidebarToggleWithoutClosureIsInert() throws {
        // `toggleSidebar` is set by `SiteShellSplitController.installToolbar`; a delegate built
        // without one (or one whose controller has gone away — the closure captures it weakly)
        // must simply do nothing.
        let delegate = SiteShellToolbarDelegate(
            itemView: { _ in AnyView(EmptyView()) }, insertMenuItems: { [] })
        let toolbar = NSToolbar(identifier: SiteShellToolbarDelegate.toolbarIdentifier)
        let item = try #require(
            delegate.toolbar(
                toolbar,
                itemForItemIdentifier: SiteShellToolbarDelegate.sidebarToggle,
                willBeInsertedIntoToolbar: true))
        let target = try #require(item.target as? NSObject)
        target.perform(try #require(item.action), with: item)
    }

    @Test("AppKit's own .toggleSidebar identifier never reaches a delegate — the reason the shell has its own")
    func systemSidebarToggleNeverReachesTheDelegate() throws {
        // The root cause of the Task 7 bug, pinned so nobody re-derives it the hard way (and so
        // the comment on `defaultItemIdentifiers` can't silently go stale): `NSToolbar` constructs
        // `NSToolbarToggleSidebarItem` for `.toggleSidebar` *itself* and does not ask the
        // delegate, so a delegate cannot supply, target or repair that item. What it builds
        // carries a nil target and `toggleSidebar:` — and under the SwiftUI-hosted shell that item
        // rendered nothing at all (measured live; the exact reason is left open in
        // `SiteShellToolbarDelegate.defaultItemIdentifiers`, because this test's fact already
        // rules the identifier out).
        //
        // Note the earlier version of this test asserted the delegate "is never asked" using a
        // recorder wired to the `itemView` closure, which the `.toggleSidebar` path never calls
        // for an unrelated reason — it proved nothing. This spy records the delegate callback
        // itself and offers a fully-formed item for every identifier, so a future AppKit that
        // starts consulting the delegate makes it fail loudly.
        let spy = SpyToolbarDelegate()
        let toolbar = NSToolbar(identifier: NSToolbar.Identifier("site.shell.test.systemToggle"))
        toolbar.delegate = spy

        toolbar.insertItem(withItemIdentifier: .toggleSidebar, at: 0)
        toolbar.insertItem(withItemIdentifier: SiteShellToolbarDelegate.sidebarToggle, at: 1)

        // Read `items` *before* asserting on the recorded callbacks: `insertItem` only records the
        // identifier, and AppKit doesn't ask the delegate to build anything until the item set is
        // actually read (or displayed). Asserting first sees an empty log for every identifier and
        // "passes" the wrong way round.
        let items = toolbar.items
        #expect(items.map(\.itemIdentifier) == [.toggleSidebar, SiteShellToolbarDelegate.sidebarToggle])
        #expect(
            spy.asked == [SiteShellToolbarDelegate.sidebarToggle],
            "AppKit intercepts .toggleSidebar and only delegates the shell's own identifier")
        let systemItem = try #require(items.first)
        #expect(systemItem.target == nil, "nil target = a responder-chain hunt this app's window loses")
        #expect(systemItem.action == #selector(NSSplitViewController.toggleSidebar(_:)))
    }

    @Test("the system sidebar-toggle identifier is neither offered nor accepted by the shell")
    func systemSidebarToggleIsNotAllowed() {
        // Allowing it would let it back in from View ▸ Customize Toolbar… or from a pre-fix
        // autosaved configuration, in either case as an item that renders nothing here.
        #expect(!SiteShellToolbarDelegate.allowedItemIdentifiers.contains(.toggleSidebar))
        #expect(!SiteShellToolbarDelegate.defaultItemIdentifiers.contains(.toggleSidebar))
        #expect(SiteShellToolbarDelegate.sidebarToggle != .toggleSidebar)
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
        // The root view is the deferring wrapper, never the built `AnyView` itself — see
        // `hostedItemContentIsRebuiltOnEveryBodyEvaluation` for why that distinction is the
        // whole difference between a live toolbar and a cosmetic one.
        #expect(item?.view is NSHostingView<HostedToolbarItemContent>)
    }

    @Test("hosted item content is rebuilt on every body evaluation, not captured once")
    func hostedItemContentIsRebuiltOnEveryBodyEvaluation() throws {
        // The bug this pins (#1699 slice 2 final review, Critical): building the hosting view as
        // `NSHostingView(rootView: itemView(id))` ran `SiteWindow.toolbarItemContent(_:site:)`'s
        // whole `@ViewBuilder` switch eagerly at delegate-callback time — outside any SwiftUI
        // body — so none of its `model.*` reads registered as `@Observable` dependencies and the
        // item rendered one frozen snapshot forever (Publish Site never enabling, Audit never
        // showing "Auditing…", the Chat icon never toggling).
        //
        // This half is the deterministic one: the build closure is invoked from `body`, once per
        // evaluation, reading whatever the model holds *then* — never cached at construction.
        // `hostedItemRerendersWhenObservedStateChanges` below then drives the real
        // `NSHostingView` through an `@Observable` mutation for the end-to-end proof.
        final class Box { var value = "first" }
        let box = Box()
        var reads: [String] = []
        let delegate = SiteShellToolbarDelegate(
            itemView: { _ in
                reads.append(box.value)
                return AnyView(Text(box.value))
            },
            insertMenuItems: { [] })
        let toolbar = NSToolbar(identifier: SiteShellToolbarDelegate.toolbarIdentifier)

        let item = delegate.toolbar(
            toolbar,
            itemForItemIdentifier: SiteShellToolbarDelegate.itemIdentifier(for: .deploy),
            willBeInsertedIntoToolbar: true)
        let hosting = try #require(item?.view as? NSHostingView<HostedToolbarItemContent>)
        #expect(reads.isEmpty, "constructing the item must not evaluate the content")

        let content = hosting.rootView
        _ = content.body
        #expect(reads == ["first"])

        // The same `NSToolbarItem` and the same root view, re-evaluated after the state moved.
        box.value = "second"
        _ = content.body
        #expect(reads == ["first", "second"], "body must re-read live state, not a frozen snapshot")
    }

    @Test("a hosted item's NSHostingView re-renders when the observed model changes")
    func hostedItemRerendersWhenObservedStateChanges() async throws {
        // The end-to-end half of the fix above: build the item through the real delegate, render
        // its `NSHostingView`, mutate the `@Observable` the content reads, and watch it render
        // again. Against the pre-fix shape — `NSHostingView(rootView: itemView(id))`, the whole
        // `@ViewBuilder` switch evaluated outside any body — this poll never completes, because
        // SwiftUI never saw the dependency and the item stays frozen on its first snapshot.
        //
        // No window and no `NSApplication` are needed: `NSHostingView` renders and re-renders on
        // demand through `layoutSubtreeIfNeeded()`/`fittingSize` (verified both ways before this
        // test was written — the eager shape stays frozen under the identical driving).
        let model = StubToolbarModel()
        final class Reads { var values: [Bool] = [] }
        let reads = Reads()
        let delegate = SiteShellToolbarDelegate(
            itemView: { _ in
                reads.values.append(model.isRunning)
                return AnyView(Text(model.isRunning ? "Auditing…" : "Audit"))
            },
            insertMenuItems: { [] })
        let toolbar = NSToolbar(identifier: SiteShellToolbarDelegate.toolbarIdentifier)

        let item = delegate.toolbar(
            toolbar,
            itemForItemIdentifier: SiteShellToolbarDelegate.itemIdentifier(for: .audit),
            willBeInsertedIntoToolbar: true)
        let hosting = try #require(item?.view as? NSHostingView<HostedToolbarItemContent>)
        hosting.frame = NSRect(x: 0, y: 0, width: 120, height: 30)
        hosting.layoutSubtreeIfNeeded()
        _ = hosting.fittingSize
        #expect(reads.values == [false], "first render reads the model's current value")

        model.isRunning = true
        try await waitUntil("the hosted item to re-render after the observed change") {
            hosting.layoutSubtreeIfNeeded()
            _ = hosting.fittingSize
            return reads.values.last == true
        }
        #expect(reads.values.contains(true))
    }

    @Test("every hosted item carries a label and paletteLabel")
    func hostedItemsAreNamed() throws {
        // Without these an `NSHostingView`-backed item is nameless in View ▸ Customize Toolbar…
        // and in the toolbar's overflow menu — it has no title of its own for AppKit to use.
        let delegate = SiteShellToolbarDelegate(
            itemView: { _ in AnyView(EmptyView()) }, insertMenuItems: { [] })
        let toolbar = NSToolbar(identifier: SiteShellToolbarDelegate.toolbarIdentifier)
        for id in SiteToolbarItemID.allCases {
            let item = try #require(
                delegate.toolbar(
                    toolbar,
                    itemForItemIdentifier: SiteShellToolbarDelegate.itemIdentifier(for: id),
                    willBeInsertedIntoToolbar: true),
                "no item built for \(id.rawValue)")
            #expect(!id.displayTitle.isEmpty, "\(id.rawValue) has no display title")
            #expect(item.label == id.displayTitle, "\(id.rawValue) label")
            #expect(item.paletteLabel == id.displayTitle, "\(id.rawValue) paletteLabel")
        }
    }

    @Test("display titles are unique, so the customization palette has no ambiguous rows")
    func displayTitlesAreUnique() {
        let titles = SiteToolbarItemID.allCases.map(\.displayTitle)
        #expect(Set(titles).count == titles.count)
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

/// Records every `toolbar(_:itemForItemIdentifier:willBeInsertedIntoToolbar:)` callback, for
/// `systemSidebarToggleNeverReachesTheDelegate`. It offers a fully-formed item for whatever it is
/// asked, so "the delegate was never asked" is the only way that test can see nothing.
///
/// File scope rather than nested in the test function: a function-local class's `@objc` protocol
/// conformance doesn't reach the AppKit runtime here, and `NSToolbar` then silently treats the
/// delegate as implementing none of these methods (confirmed the hard way — every callback list
/// came back empty, including for the shell's own identifier).
private final class SpyToolbarDelegate: NSObject, NSToolbarDelegate {
    var asked: [NSToolbarItem.Identifier] = []

    /// Both sets are required, not decoration: `NSToolbar.insertItem` silently no-ops for an
    /// identifier the delegate doesn't allow, which would make the test pass vacuously.
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, SiteShellToolbarDelegate.sidebarToggle]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, SiteShellToolbarDelegate.sidebarToggle]
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        asked.append(itemIdentifier)
        return NSToolbarItem(itemIdentifier: itemIdentifier)
    }
}

/// Stand-in for `SiteWindowModel` in `hostedItemRerendersWhenObservedStateChanges` — the point is
/// only that the item's content reads `@Observable` state the way
/// `SiteWindow.toolbarItemContent(_:site:)` reads `model.*`. File scope rather than nested in the
/// suite because `@Observable` expands to an extension on the type, which a `private` nested type
/// isn't visible to.
@Observable
@MainActor
private final class StubToolbarModel {
    var isRunning = false
}
