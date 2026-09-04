import AppKit
import SwiftUI
import AnglesiteCore

/// The AppKit shell's owned `NSToolbar` delegate (#1699 Stage 3 slice 2, design doc
/// §"Toolbar (slice 2)"). Item identity is `SiteToolbarItemID`'s raw value, reused verbatim —
/// `AXID.toolbar(_:)` (`toolbar.<rawValue>`, `docs/testing-macos-app.md` §"Accessibility
/// identifiers") and every user's *default* customization both key off that string, so this
/// class must never remap it. The toolbar's own identifier is a fresh key, `"site.shell"` —
/// deliberately distinct from the legacy `"NSToolbar Configuration site"` blob SwiftUI wrote,
/// which embeds Beta-7-poisoned internal identifiers (#1704) this design abandons on purpose.
@MainActor
final class SiteShellToolbarDelegate: NSObject, NSToolbarDelegate {
    static let toolbarIdentifier = NSToolbar.Identifier("site.shell")

    static let sidebarTrackingSeparator = NSToolbarItem.Identifier("site.shell.sidebarSeparator")
    static let inspectorTrackingSeparator = NSToolbarItem.Identifier("site.shell.inspectorSeparator")

    static func itemIdentifier(for id: SiteToolbarItemID) -> NSToolbarItem.Identifier {
        NSToolbarItem.Identifier(id.rawValue)
    }

    /// The out-of-the-box toolbar: the sidebar toggle and its tracking separator, then the
    /// curated `SiteToolbarItemID.isDefaultVisible` set, then the inspector tracking separator
    /// and the trailing search field.
    ///
    /// The four non-`SiteToolbarItemID` entries are *declared* here rather than inserted
    /// imperatively once per window (#1699 slice 2, final-review fix). The imperative seeding
    /// this replaces was a one-shot latch per controller, so "Restore Default Set" in the
    /// Customize Toolbar sheet permanently dropped the search field and both separators for the
    /// rest of that window's session — restoring a *default* set can only bring back what the
    /// default set says it contains. The sidebar toggle is new here: SwiftUI auto-inserted one
    /// for `NavigationSplitView`, and the design doc's compatibility table has the shell adding
    /// its own once the toolbar is owned. `NSToolbarItem.Identifier.toggleSidebar` needs no case
    /// in `toolbar(_:itemForItemIdentifier:willBeInsertedIntoToolbar:)` below — AppKit builds
    /// standard system identifiers itself (verified: it yields an `NSToolbarToggleSidebarItem`
    /// labelled "Sidebar" with action `toggleSidebar:` and a nil target, i.e. down the responder
    /// chain to `NSSplitViewController`, and the delegate is never asked for it).
    static var defaultItemIdentifiers: [NSToolbarItem.Identifier] {
        [.toggleSidebar, sidebarTrackingSeparator]
            + SiteToolbarItemID.allCases.filter(\.isDefaultVisible).map(itemIdentifier(for:))
            + [inspectorTrackingSeparator, SiteShellSearchToolbarItem.identifier]
    }

    /// Every identifier the toolbar may legitimately hold — the frozen `SiteToolbarItemID` set
    /// **plus** the shell's own four: the sidebar toggle, the trailing search field, and the two
    /// tracking separators.
    ///
    /// `NSToolbar` reconciles a restored autosaved configuration against this set, and
    /// `autosavesConfiguration` is on, so an identifier missing from it is silently dropped on
    /// the next launch — and by the same rule a Customize Toolbar round trip could drop it too.
    static var allowedItemIdentifiers: [NSToolbarItem.Identifier] {
        SiteToolbarItemID.allCases.map(itemIdentifier(for:))
            + [
                .toggleSidebar, SiteShellSearchToolbarItem.identifier,
                sidebarTrackingSeparator, inspectorTrackingSeparator,
            ]
    }

    /// Builds the SwiftUI content for a given item, matching `SiteWindow.toolbarItemContent`
    /// (Task 1) exactly — the shell and the legacy toolbar render the same view.
    private let itemView: @MainActor (SiteToolbarItemID) -> AnyView
    /// Rebuilt fresh on every menu open (Insert's Blocks section depends on live WYSIWYG canvas
    /// state) — see `menuNeedsUpdate(_:)` below.
    private let insertMenuItems: @MainActor () -> [NSMenuItem]
    /// The shell's split view, set by `SiteShellSplitController.installToolbar` once the
    /// toolbar is installed — backs the two tracking-separator toolbar items below.
    weak var splitView: NSSplitView?
    /// The window's one search item (#1699 slice 2, Task 6), set alongside `splitView` by
    /// `SiteShellSplitController.installToolbar`. Handed back *by identity* rather than rebuilt:
    /// a fresh `NSSearchToolbarItem` per request would drop the field's current text and
    /// first-responder state every time the toolbar re-asked for it (autosave restore, a
    /// customization-palette round trip). `weak` because the owning `SiteWindow` holds it for the
    /// window's lifetime and the toolbar retains the items it displays — this reference exists only
    /// to answer the delegate callback.
    weak var searchItem: SiteShellSearchToolbarItem?

    init(
        itemView: @escaping @MainActor (SiteToolbarItemID) -> AnyView,
        insertMenuItems: @escaping @MainActor () -> [NSMenuItem]
    ) {
        self.itemView = itemView
        self.insertMenuItems = insertMenuItems
        super.init()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.defaultItemIdentifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.allowedItemIdentifiers
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        if itemIdentifier == Self.sidebarTrackingSeparator, let splitView {
            return NSTrackingSeparatorToolbarItem(
                identifier: itemIdentifier, splitView: splitView, dividerIndex: 0)
        }
        if itemIdentifier == Self.inspectorTrackingSeparator, let splitView {
            return NSTrackingSeparatorToolbarItem(
                identifier: itemIdentifier, splitView: splitView, dividerIndex: 1)
        }
        if itemIdentifier == SiteShellSearchToolbarItem.identifier {
            return searchItem
        }

        guard let id = SiteToolbarItemID.allCases.first(where: { Self.itemIdentifier(for: $0) == itemIdentifier }) else {
            return nil
        }

        if id == .insert {
            let menuItem = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            menuItem.menu = NSMenu()
            menuItem.menu.delegate = self
            // Populate synchronously so the menu isn't empty before its first open —
            // `menuNeedsUpdate(_:)` below then keeps it fresh on every subsequent open.
            menuItem.menu.items = insertMenuItems()
            menuItem.image = NSImage(
                systemSymbolName: "plus", accessibilityDescription: id.displayTitle)
            menuItem.label = id.displayTitle
            menuItem.paletteLabel = id.displayTitle
            menuItem.toolTip = String(
                localized: "Add a new page, post, collection entry, or block")
            menuItem.showsIndicator = true
            return menuItem
        }

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        // Both, always: `label` names the item in the toolbar's overflow menu, `paletteLabel` in
        // View ▸ Customize Toolbar…. An `NSHostingView`-backed item has no title of its own, so
        // without these it appears nameless in both places.
        item.label = id.displayTitle
        item.paletteLabel = id.displayTitle
        let hosting = NSHostingView(
            rootView: HostedToolbarItemContent(build: { [itemView] in itemView(id) }))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        item.view = hosting
        return item
    }
}

/// Defers a hosted toolbar item's content build into a real SwiftUI `body` (#1699 slice 2,
/// final-review fix).
///
/// `SiteWindow.toolbarItemContent(_:site:)` is a `@ViewBuilder` *function*, and calling it
/// straight from `NSHostingView(rootView:)` — as this delegate first did — evaluates its whole
/// switch eagerly at delegate-callback time, outside any body evaluation. Every `model.*` read
/// in it (`!model.canRunDeploy`, `model.audit.isRunning`, `model.chatPresented`,
/// `model.inspectorSelection == nil`, the `site.isValid` help strings…) then registers no
/// `@Observable` dependency, and the hosting view renders one frozen snapshot for the window's
/// lifetime: Publish Site never enables, Audit never shows "Auditing…", the Chat and Related
/// Pages icons never toggle. Running the same call inside `body` puts those reads back under
/// SwiftUI's observation tracking, so the item re-renders when the model changes.
struct HostedToolbarItemContent: View {
    /// Invoked on every body evaluation — never cached, which is the entire point.
    let build: @MainActor () -> AnyView

    var body: some View { build() }
}

extension SiteShellToolbarDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.items = insertMenuItems()
    }
}
