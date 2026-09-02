import Foundation
import Testing
@testable import AnglesiteCore
import AnglesiteTestSupport

@Suite("AppSettings.lastUsedFileLicenseSelection (#999)")
struct FileLicenseSelectionTests {
    @Test("nil until a choice is ever persisted")
    func absentByDefault() {
        withTemporaryUserDefaults { defaults in
            #expect(AppSettings(defaults: defaults).lastUsedFileLicenseSelection == nil)
        }
    }

    @Test("round-trips a persisted choice")
    func roundTrips() {
        withTemporaryUserDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            let selection = FileLicenseSelection(isEnabled: true, catalogID: "cc-by-4.0")
            settings.lastUsedFileLicenseSelection = selection
            #expect(settings.lastUsedFileLicenseSelection == selection)
        }
    }

    @Test("clearing writes back to nil")
    func clears() {
        withTemporaryUserDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.lastUsedFileLicenseSelection = FileLicenseSelection(isEnabled: true, catalogID: "cc0-1.0")
            settings.lastUsedFileLicenseSelection = nil
            #expect(settings.lastUsedFileLicenseSelection == nil)
        }
    }
}
