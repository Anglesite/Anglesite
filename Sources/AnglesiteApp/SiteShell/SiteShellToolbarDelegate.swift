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

    static var defaultItemIdentifiers: [NSToolbarItem.Identifier] {
        SiteToolbarItemID.allCases.filter(\.isDefaultVisible).map(itemIdentifier(for:))
    }

    /// Every identifier the toolbar may legitimately hold — the frozen `SiteToolbarItemID` set
    /// **plus** the three items the shell seeds itself (`SiteShellSplitController
    /// .attachOwnedToolbarIfNeeded()`): the trailing search field and the two tracking separators.
    ///
    /// Those three have to be here even though they never appear in `defaultItemIdentifiers`.
    /// `NSToolbar` reconciles a restored autosaved configuration against this set, and
    /// `autosavesConfiguration` is on, so an identifier missing from it survives the first launch
    /// (where the seeding inserts it directly) and is then silently dropped on the second — and by
    /// the same rule a Customize Toolbar round trip could drop it too.
    static var allowedItemIdentifiers: [NSToolbarItem.Identifier] {
        SiteToolbarItemID.allCases.map(itemIdentifier(for:))
            + [SiteShellSearchToolbarItem.identifier, sidebarTrackingSeparator, inspectorTrackingSeparator]
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
            menuItem.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Insert")
            menuItem.label = "Insert"
            menuItem.toolTip = "Add a new page, post, collection entry, or block"
            menuItem.showsIndicator = true
            return menuItem
        }

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        let hosting = NSHostingView(rootView: itemView(id))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        item.view = hosting
        return item
    }
}

extension SiteShellToolbarDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.items = insertMenuItems()
    }
}
