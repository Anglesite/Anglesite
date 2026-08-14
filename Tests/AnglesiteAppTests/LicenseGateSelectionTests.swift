import Foundation
import Testing
import AnglesiteCore
@testable import AnglesiteAppCore

@Suite("LicenseGateSheetView.Selection (#999)")
struct LicenseGateSelectionTests {
    @Test("All rights reserved and a catalog choice are always continue-enabled")
    func nonCustomAlwaysEnabled() {
        var selection = LicenseGateSheetView.Selection()
        #expect(selection.isContinueEnabled)
        selection.choice = .catalog("cc-by-4.0")
        #expect(selection.isContinueEnabled)
    }

    @Test("Custom is disabled until a URL is typed")
    func customRequiresURL() {
        var selection = LicenseGateSheetView.Selection()
        selection.choice = .custom
        #expect(!selection.isContinueEnabled)
        selection.customURL = "https://example.com/license"
        #expect(selection.isContinueEnabled)
    }

    @Test("resolvedLicense maps All rights reserved to nil")
    func allRightsReservedResolvesToNil() {
        let selection = LicenseGateSheetView.Selection()
        #expect(selection.resolvedLicense() == nil)
    }

    @Test("resolvedLicense maps a catalog choice to its catalog LicenseRef")
    func catalogResolvesToCatalogRef() {
        var selection = LicenseGateSheetView.Selection()
        selection.choice = .catalog("cc-by-4.0")
        let expected = LicenseCatalog.entries.first { $0.id == "cc-by-4.0" }?.ref
        #expect(selection.resolvedLicense() == expected)
    }

    @Test("resolvedLicense falls back the custom name to the URL when empty")
    func customFallsBackNameToURL() {
        var selection = LicenseGateSheetView.Selection()
        selection.choice = .custom
        selection.customURL = "https://example.com/license"
        #expect(selection.resolvedLicense() == LicenseRef(
            url: "https://example.com/license", name: "https://example.com/license"))
    }

    @Test("resolvedLicense uses a typed custom name when present")
    func customUsesTypedName() {
        var selection = LicenseGateSheetView.Selection()
        selection.choice = .custom
        selection.customURL = "https://example.com/license"
        selection.customName = "House terms"
        #expect(selection.resolvedLicense() == LicenseRef(
            url: "https://example.com/license", name: "House terms"))
    }
}
