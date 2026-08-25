import Testing
import Foundation
@testable import AnglesiteCore

@Suite("BotPreferenceSyncDashboardLinks (#1628)")
struct BotPreferenceSyncDashboardLinksTests {
    @Test("settings deep link targets the zone's security settings, keyed by zoneID")
    func settingsURL() {
        #expect(
            BotPreferenceSyncDashboardLinks.settingsURL(zoneID: "z1").absoluteString
                == "https://dash.cloudflare.com/?to=/:account/:zone/security/settings")
    }
}
