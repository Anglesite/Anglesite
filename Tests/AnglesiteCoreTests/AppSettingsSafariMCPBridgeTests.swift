import Testing
import Foundation
@testable import AnglesiteCore
import AnglesiteTestSupport

/// A `final class` (not a `struct`) so `deinit` can drop the throwaway `UserDefaults` suite —
/// same idiom as `AppSettingsTests`.
final class AppSettingsSafariMCPBridgeTests {
    private let scratch = TemporaryUserDefaults()
    private var defaults: UserDefaults { scratch.defaults }

    deinit { scratch.cleanup() }

    @Test("defaults to SafariMCPBridgeDetector.defaultPort when unset")
    func defaultsWhenUnset() {
        let settings = AppSettings(defaults: defaults)
        #expect(settings.safariMCPBridgePort == SafariMCPBridgeDetector.defaultPort)
    }

    @Test("stores and round-trips a configured port")
    func roundTrips() {
        let settings = AppSettings(defaults: defaults)
        settings.safariMCPBridgePort = 9001
        #expect(settings.safariMCPBridgePort == 9001)
    }

    @Test("falls back to the default for an out-of-range stored value")
    func fallsBackWhenInvalid() {
        defaults.set("not-a-port", forKey: AppSettings.Key.safariMCPBridgePort)
        let settings = AppSettings(defaults: defaults)
        #expect(settings.safariMCPBridgePort == SafariMCPBridgeDetector.defaultPort)
    }
}
