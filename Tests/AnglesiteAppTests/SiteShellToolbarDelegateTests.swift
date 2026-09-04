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
        .toggleSidebar,
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
            [.toggleSidebar, SiteShellToolbarDelegate.sidebarTrackingSeparator]
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
        #expect(defaults.first == .toggleSidebar)
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

    @Test("AppKit builds the sidebar toggle itself — the delegate is never asked for it")
    func sidebarToggleIsAStandardSystemItem() throws {
        // Why `toolbar(_:itemForItemIdentifier:willBeInsertedIntoToolbar:)` has no
        // `.toggleSidebar` case: standard system identifiers are constructed by AppKit, not the
        // delegate. Asserted rather than assumed — the whole default-set restructuring depends
        // on it, and a silently-dropped leading item is exactly the failure this test catches.
        final class AskRecorder: NSObject {
            var asked: [NSToolbarItem.Identifier] = []
        }
        let recorder = AskRecorder()
        let delegate = SiteShellToolbarDelegate(
            itemView: { _ in
                recorder.asked.append(NSToolbarItem.Identifier("itemView"))
                return AnyView(EmptyView())
            },
            insertMenuItems: { [] })
        let toolbar = NSToolbar(identifier: SiteShellToolbarDelegate.toolbarIdentifier)
        toolbar.delegate = delegate

        toolbar.insertItem(withItemIdentifier: .toggleSidebar, at: 0)

        let item = try #require(toolbar.items.first)
        #expect(item.itemIdentifier == .toggleSidebar)
        #expect(item.action == #selector(NSSplitViewController.toggleSidebar(_:)))
        #expect(item.target == nil, "nil target = down the responder chain to NSSplitViewController")
        #expect(!item.label.isEmpty, "AppKit supplies the system item's own localized label")
        #expect(recorder.asked.isEmpty, "the delegate must not be consulted for a system identifier")
        // And the delegate still answers nil for it, which is fine precisely because nothing asks.
        #expect(
            delegate.toolbar(toolbar, itemForItemIdentifier: .toggleSidebar, willBeInsertedIntoToolbar: true)
                == nil)
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
