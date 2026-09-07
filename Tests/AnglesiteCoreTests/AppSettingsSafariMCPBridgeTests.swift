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

    // MARK: AppSettings.parsePort — the shared rule behind the getter above and
    // AdvancedSettingsView's reactive text field (final-review finding #2).

    @Test("parsePort accepts a valid in-range port")
    func parsePortValid() {
        #expect(AppSettings.parsePort("9001", default: 1234) == 9001)
    }

    @Test("parsePort trims whitespace")
    func parsePortTrimsWhitespace() {
        #expect(AppSettings.parsePort("  9001  ", default: 1234) == 9001)
    }

    @Test("parsePort falls back to the default for a blank value")
    func parsePortBlank() {
        #expect(AppSettings.parsePort("", default: 1234) == 1234)
        #expect(AppSettings.parsePort("   ", default: 1234) == 1234)
    }

    @Test("parsePort falls back to the default for a non-numeric value")
    func parsePortNonNumeric() {
        #expect(AppSettings.parsePort("not-a-port", default: 1234) == 1234)
    }

    @Test("parsePort falls back to the default for an out-of-range value")
    func parsePortOutOfRange() {
        #expect(AppSettings.parsePort("0", default: 1234) == 1234)
        #expect(AppSettings.parsePort("65536", default: 1234) == 1234)
        #expect(AppSettings.parsePort("-1", default: 1234) == 1234)
    }
}
