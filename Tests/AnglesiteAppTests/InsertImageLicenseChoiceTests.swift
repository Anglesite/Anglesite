import Foundation
import Testing
import AnglesiteCore
@testable import AnglesiteAppCore

@Suite("InsertImageLicenseChoice (#999)")
struct InsertImageLicenseChoiceTests {
    private let ccBY = LicenseRef(url: "https://creativecommons.org/licenses/by/4.0/", name: "CC BY 4.0")

    @Test("resolvedLicense is nil when disabled, regardless of catalogID")
    func disabledResolvesNil() {
        let choice = InsertImageLicenseChoice(isEnabled: false, catalogID: "cc-by-4.0")
        #expect(choice.resolvedLicense() == nil)
    }

    @Test("resolvedLicense looks up the catalog entry when enabled")
    func enabledResolvesCatalogEntry() {
        let choice = InsertImageLicenseChoice(isEnabled: true, catalogID: "cc-by-4.0")
        #expect(choice.resolvedLicense() == ccBY)
    }

    @Test("resolvedLicense is nil for an unrecognized catalogID even when enabled")
    func unknownCatalogIDResolvesNil() {
        let choice = InsertImageLicenseChoice(isEnabled: true, catalogID: "not-a-real-id")
        #expect(choice.resolvedLicense() == nil)
    }

    @Test("initial seeds from lastUsed when present")
    func initialFromLastUsed() {
        let lastUsed = FileLicenseSelection(isEnabled: true, catalogID: "cc0-1.0")
        let choice = InsertImageLicenseChoice.initial(resolvedDefault: ccBY, lastUsed: lastUsed)
        #expect(choice == InsertImageLicenseChoice(isEnabled: true, catalogID: "cc0-1.0"))
    }

    @Test("initial falls back to the resolved collection default, disabled, when no lastUsed exists")
    func initialFromResolvedDefault() {
        let choice = InsertImageLicenseChoice.initial(resolvedDefault: ccBY, lastUsed: nil)
        #expect(choice == InsertImageLicenseChoice(isEnabled: false, catalogID: "cc-by-4.0"))
    }

    @Test("initial falls back to the first catalog entry when there's no resolved default and no lastUsed")
    func initialFallsBackToFirstCatalogEntry() {
        let choice = InsertImageLicenseChoice.initial(resolvedDefault: nil, lastUsed: nil)
        #expect(choice == InsertImageLicenseChoice(isEnabled: false, catalogID: LicenseCatalog.entries[0].id))
    }

    @Test("persisted round-trips through FileLicenseSelection")
    func persistedRoundTrips() {
        let choice = InsertImageLicenseChoice(isEnabled: true, catalogID: "cc-by-sa-4.0")
        #expect(choice.persisted == FileLicenseSelection(isEnabled: true, catalogID: "cc-by-sa-4.0"))
    }
}
