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
    /// The shell's *own* sidebar toggle, deliberately **not** `NSToolbarItem.Identifier
    /// .toggleSidebar` — see `defaultItemIdentifiers` for why the system identifier can't be used
    /// here.
    static let sidebarToggle = NSToolbarItem.Identifier("site.shell.sidebarToggle")

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
    /// its own once the toolbar is owned.
    ///
    /// That toggle is `sidebarToggle`, the shell's own identifier with its own case in
    /// `toolbar(_:itemForItemIdentifier:willBeInsertedIntoToolbar:)` below, **not**
    /// `NSToolbarItem.Identifier.toggleSidebar` (#1699 slice 2, Task 7 live-verification fix).
    /// The system identifier looked like the shorter road and does not work here, for two
    /// stacked reasons:
    ///
    /// 1. AppKit intercepts it. `NSToolbar` builds an `NSToolbarToggleSidebarItem` for
    ///    `.toggleSidebar` itself and never consults the delegate — measured, not assumed: a
    ///    delegate that returns a fully-configured item for that identifier is not even called
    ///    (`SiteShellToolbarDelegateTests.systemSidebarToggleNeverReachesTheDelegate` freezes
    ///    this). So the delegate cannot fix the item it produces.
    /// 2. And the item it produces doesn't show up here anyway. Measured: with `.toggleSidebar` in
    ///    the default set, a freshly launched `ANGLESITE_APPKIT_SHELL=1` window (toolbar autosave
    ///    key deleted first, so this is not stale customization) has no sidebar button in the
    ///    toolbar's AX tree at all. *Why* is not measured, and two accounts fit: the item's nil
    ///    target plus the action `toggleSidebar:` failing to resolve when the message is walked
    ///    from the window (the split controller is not the window's `contentViewController` here —
    ///    `SiteShellView` hosts it inside a SwiftUI `WindowGroup`'s own hierarchy), or AppKit
    ///    hiding a standard item it can't validate against this window's content-view-controller
    ///    shape. They were not distinguished, and it doesn't matter for this fix: (1) already
    ///    makes the system identifier unusable. What is clear either way is that the bare
    ///    `NSWindow` whose `contentViewController` *is* the split controller — Apple's document-app
    ///    template shape, and the shape this was first prototyped in — renders the item fine, which
    ///    is why the system identifier passed in isolation and failed in the app.
    ///
    ///    Do not read this as "the responder chain never reaches the split controller here". It
    ///    demonstrably does at least sometimes: slice 1's windowed gate found `toggleSidebar:` from
    ///    the stock `SidebarCommands` View-menu item *toggling the sidebar correctly* under this
    ///    same shell (its menu title inverts, which is that gate finding's separate open point).
    ///
    /// The shell's own item sidesteps both: the delegate builds it, and it targets this delegate
    /// directly rather than fishing in the responder chain.
    static var defaultItemIdentifiers: [NSToolbarItem.Identifier] {
        [sidebarToggle, sidebarTrackingSeparator]
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
    ///
    /// `NSToolbarItem.Identifier.toggleSidebar` is deliberately absent: it is the system item
    /// `sidebarToggle` replaces, and leaving it allowed would both offer it in View ▸ Customize
    /// Toolbar… and preserve it out of an older autosaved configuration — in either case putting
    /// an item in the toolbar that renders nothing here (see `defaultItemIdentifiers`). Dropping
    /// it from this set is what retires it from a saved configuration on the next launch.
    static var allowedItemIdentifiers: [NSToolbarItem.Identifier] {
        SiteToolbarItemID.allCases.map(itemIdentifier(for:))
            + [
                sidebarToggle, SiteShellSearchToolbarItem.identifier,
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
    /// Flips the shell sidebar's collapsed state, set by `SiteShellSplitController.installToolbar`
    /// alongside `splitView` — the `sidebarToggle` item's whole behavior.
    ///
    /// A closure rather than a reference to the controller because
    /// `SiteShellSplitController` is generic over its three column views, and a generic class can
    /// neither be named without its parameters nor expose `@objc` members for a target/action
    /// pair. The controller captures itself weakly here, so a toolbar outliving its window
    /// toggles nothing instead of resurrecting it.
    var toggleSidebar: (@MainActor () -> Void)?

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
        if itemIdentifier == Self.sidebarToggle {
            // "Sidebar" is the wording AppKit's own toggle uses, kept so the item reads the same
            // in the overflow menu and the customization palette as it does in every other Mac
            // app. It is a literal rather than a `SiteToolbarItemID.displayTitle` because the
            // sidebar toggle is shell chrome, not one of the frozen toolbar item ids.
            let title = String(localized: "Sidebar")
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = title
            item.paletteLabel = title
            item.toolTip = String(localized: "Show or hide the sidebar")
            item.image = NSImage(systemSymbolName: "sidebar.leading", accessibilityDescription: title)
            // Without this the item draws as a bare glyph — every other item here is a bordered
            // SwiftUI button, and AppKit's own sidebar toggle is bordered too.
            item.isBordered = true
            // Deliberately *not* `isNavigational = true`, which would match AppKit's own toggle by
            // pinning the item leading and keeping it out of the overflow menu. It is very likely
            // right and it is one line, but it is a layout assumption, and the bug this whole item
            // exists to fix came from trusting an AppKit behavior that held everywhere except in
            // this app's window. Nobody has watched it narrow a real shell window yet.
            // A direct target, which is the entire point of building this item ourselves: it needs
            // nothing from the responder chain and nothing from the window's view-controller
            // shape, unlike the system item this replaces (see `defaultItemIdentifiers`).
            // `NSToolbarItem.target` is a weak reference, and this delegate lives as long as the
            // controller that owns the toolbar.
            item.target = self
            item.action = #selector(sidebarToggleAction(_:))
            return item
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

    /// The `sidebarToggle` item's action. Named for the item rather than `toggleSidebar:` on
    /// purpose: this is a direct target/action pair on the delegate, not a responder-chain
    /// message, and the two must not be confused for one another again.
    @objc private func sidebarToggleAction(_ sender: Any?) {
        toggleSidebar?()
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
