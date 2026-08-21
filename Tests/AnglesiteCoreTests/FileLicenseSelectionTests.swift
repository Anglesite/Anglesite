import Foundation
import Testing
@testable import AnglesiteCore

@Suite("AppSettings.lastUsedFileLicenseSelection (#999)")
struct FileLicenseSelectionTests {
    private func makeSettings() -> AppSettings {
        let suiteName = "FileLicenseSelectionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return AppSettings(defaults: defaults)
    }

    @Test("nil until a choice is ever persisted")
    func absentByDefault() {
        #expect(makeSettings().lastUsedFileLicenseSelection == nil)
    }

    @Test("round-trips a persisted choice")
    func roundTrips() {
        let settings = makeSettings()
        let selection = FileLicenseSelection(isEnabled: true, catalogID: "cc-by-4.0")
        settings.lastUsedFileLicenseSelection = selection
        #expect(settings.lastUsedFileLicenseSelection == selection)
    }

    @Test("clearing writes back to nil")
    func clears() {
        let settings = makeSettings()
        settings.lastUsedFileLicenseSelection = FileLicenseSelection(isEnabled: true, catalogID: "cc0-1.0")
        settings.lastUsedFileLicenseSelection = nil
        #expect(settings.lastUsedFileLicenseSelection == nil)
    }
}
