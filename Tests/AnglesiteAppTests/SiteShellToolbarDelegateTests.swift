import Testing
import AppKit
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

    @Test("allowed item identifiers cover every SiteToolbarItemID exactly once")
    func allowedItemIdentifiersCoverAllCases() {
        let allowed = SiteShellToolbarDelegate.allowedItemIdentifiers
        let expected = Set(SiteToolbarItemID.allCases.map { SiteShellToolbarDelegate.itemIdentifier(for: $0) })
        #expect(Set(allowed) == expected)
        #expect(allowed.count == expected.count, "no duplicate identifiers")
    }

    @Test("default set is a subset of the allowed set")
    func defaultIsSubsetOfAllowed() {
        let allowed = Set(SiteShellToolbarDelegate.allowedItemIdentifiers)
        for identifier in SiteShellToolbarDelegate.defaultItemIdentifiers {
            #expect(allowed.contains(identifier))
        }
    }
}
