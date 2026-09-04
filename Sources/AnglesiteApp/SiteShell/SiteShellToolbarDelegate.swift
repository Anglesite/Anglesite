import AppKit
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

    static var allowedItemIdentifiers: [NSToolbarItem.Identifier] {
        SiteToolbarItemID.allCases.map(itemIdentifier(for:))
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.defaultItemIdentifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.allowedItemIdentifiers
    }
}
