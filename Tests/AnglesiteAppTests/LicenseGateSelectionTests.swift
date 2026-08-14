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

    @Test("Custom stays disabled for a whitespace-only URL")
    func customRejectsWhitespaceOnlyURL() {
        var selection = LicenseGateSheetView.Selection()
        selection.choice = .custom
        selection.customURL = "   \n "
        #expect(!selection.isContinueEnabled)
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

    @Test("an absent existing license starts on All rights reserved")
    func seedsAllRightsReservedWithoutExistingLicense() {
        #expect(LicenseGateSheetView.Selection(existing: nil).choice == .allRightsReserved)
    }

    @Test("an existing catalog license is preselected instead of being discarded")
    func seedsCatalogChoiceFromExistingLicense() {
        let ccBY = LicenseCatalog.entries.first { $0.id == "cc-by-4.0" }!.ref
        let selection = LicenseGateSheetView.Selection(existing: ccBY)
        #expect(selection.choice == .catalog("cc-by-4.0"))
        #expect(selection.resolvedLicense() == ccBY)
    }

    @Test("an existing off-catalog license is preselected as Custom with its URL and name")
    func seedsCustomChoiceFromExistingLicense() {
        let ref = LicenseRef(url: "https://example.com/terms", name: "House terms")
        let selection = LicenseGateSheetView.Selection(existing: ref)
        #expect(selection.choice == .custom)
        #expect(selection.customURL == "https://example.com/terms")
        #expect(selection.customName == "House terms")
        #expect(selection.isContinueEnabled)
        #expect(selection.resolvedLicense() == ref)
    }

    @Test("an existing custom license whose name is just its URL leaves the name field empty")
    func seedsCustomWithoutEchoingURLAsName() {
        let ref = LicenseRef(url: "https://example.com/terms", name: "https://example.com/terms")
        let selection = LicenseGateSheetView.Selection(existing: ref)
        #expect(selection.customName == "")
        // Still resolves back to the same ref, since an empty name falls back to the URL.
        #expect(selection.resolvedLicense() == ref)
    }
}
