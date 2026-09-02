import Testing
import AnglesiteCore
@testable import AnglesiteAppCore

/// Freezes the accessibility-identifier contract (#1535). Identifiers are automation API —
/// external AX scripts key off these strings the same way saved toolbar customizations key
/// off `SiteToolbarItemID` — so renames are breaking changes, not refactors.
struct AXIDTests {
    @Test func staticIdentifiersAreUnique() {
        #expect(Set(AXID.allStatic).count == AXID.allStatic.count)
    }

    @Test func staticIdentifiersAreDottedCamelCasePaths() {
        for id in AXID.allStatic {
            let segments = id.split(separator: ".", omittingEmptySubsequences: false)
            #expect(segments.count >= 2, "\(id) should be a <surface>.<control> path")
            for segment in segments {
                #expect(!segment.isEmpty, "\(id) has an empty segment")
                #expect(segment.first?.isLowercase == true, "\(id) segments start lowercase")
                #expect(segment.allSatisfy { $0.isLetter || $0.isNumber }, "\(id) segments are alphanumeric")
            }
        }
    }

    /// `toolbar.*` is reserved for the family derived from `SiteToolbarItemID`.
    @Test func staticIdentifiersStayOutOfTheToolbarNamespace() {
        #expect(AXID.allStatic.allSatisfy { !$0.hasPrefix("toolbar.") })
    }

    /// Frozen values automation scripts key off (`docs/testing-macos-app.md` § Accessibility
    /// identifiers); a rename here is a breaking change for those scripts.
    @Test func frozenValues() {
        #expect(AXID.navigatorList == "navigator.list")
        #expect(AXID.launcherList == "launcher.list")
        #expect(AXID.allStatic.contains(AXID.launcherList))
    }

    @Test func toolbarIdentifiersDeriveFromFrozenCustomizationIDs() {
        #expect(AXID.toolbar(.deploy) == "toolbar.deploy")
        let derived = SiteToolbarItemID.allCases.map(AXID.toolbar)
        #expect(Set(derived).count == derived.count)
    }
}
