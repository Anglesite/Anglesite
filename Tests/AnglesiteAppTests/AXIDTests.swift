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

    // MARK: Frozen values (#1751, #1752)

    /// The Website Settings takeover's hand-assigned ids. Frozen: automation scripts key off
    /// them.
    @Test func settingsIdentifiersAreFrozen() {
        #expect(AXID.settingsTabs == "settings.tabs")
        #expect(AXID.settingsWorkersLogs == "settings.workers.logs")
        #expect(AXID.settingsWorkersAnalytics == "settings.workers.analytics")
    }

    /// Per-worker ids embed the catalog's worker id verbatim — including its hyphens
    /// (`solid-pod`), which is why the static-only camelCase format rule doesn't apply here.
    @Test func workersTabRowIdentifiersDeriveFromCatalogWorkerIDs() {
        #expect(AXID.settingsWorkerToggle("solid-pod") == "settings.workers.toggle.solid-pod")
        #expect(AXID.settingsWorkerStatus("webmention") == "settings.workers.status.webmention")
        #expect(AXID.settingsWorkerToggle("x") != AXID.settingsWorkerStatus("x"))
    }

    @Test func debugHeadingIdentifiersAreFrozen() {
        #expect(AXID.debugServerHeader == "debug.serverHeader")
        #expect(AXID.debugLocalWorkersHeader == "debug.localWorkersHeader")
    }

    /// Per-site Local Workers row ids embed `WorkersDevSession.siteID` verbatim, and every part
    /// of one row has a distinct id from the row group and from its siblings.
    @Test func debugWorkerRowIdentifiersDeriveFromSiteIDs() {
        let siteID = "6E3F0A1C-9B2D-4F5E-8A7B-0C1D2E3F4A5B"
        #expect(AXID.debugWorkerRow(siteID) == "debug.worker.\(siteID)")
        #expect(AXID.debugWorkerName(siteID) == "debug.worker.\(siteID).name")
        #expect(AXID.debugWorkerStatus(siteID) == "debug.worker.\(siteID).status")
        #expect(AXID.debugWorkerURL(siteID) == "debug.worker.\(siteID).url")
        #expect(AXID.debugWorkerCopy(siteID) == "debug.worker.\(siteID).copy")
        #expect(AXID.debugWorkerFailure(siteID) == "debug.worker.\(siteID).failure")
        let parts = [
            AXID.debugWorkerRow(siteID), AXID.debugWorkerName(siteID), AXID.debugWorkerStatus(siteID),
            AXID.debugWorkerURL(siteID), AXID.debugWorkerCopy(siteID), AXID.debugWorkerFailure(siteID),
        ]
        #expect(Set(parts).count == parts.count)
    }

    /// The generated families never collide with a hand-assigned id.
    @Test func parameterizedIdentifiersStayOutOfTheStaticSet() {
        let generated = [
            AXID.settingsWorkerToggle("webmention"), AXID.settingsWorkerStatus("webmention"),
            AXID.debugWorkerRow("s1"), AXID.debugWorkerStatus("s1"),
        ]
        #expect(generated.allSatisfy { !AXID.allStatic.contains($0) })
    }
}
