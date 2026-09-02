import Testing
import Foundation
@testable import AnglesiteCore
import AnglesiteTestSupport

/// `final class` so `deinit` drops the throwaway suite (mirrors AppSettingsTests).
final class StartupTimingStoreTests {
    private let scratch = TemporaryUserDefaults(label: "startup")
    private var defaults: UserDefaults { scratch.defaults }

    deinit { scratch.cleanup() }

    @Test("Absent timing falls back to the default profile")
    func absentFallsBackToDefault() {
        let store = StartupTimingStore(defaults: defaults)
        #expect(store.profile(for: "site-a") == StartupProfile.default)
    }

    @Test("Record then read round-trips a plausible profile")
    func roundTrip() {
        let store = StartupTimingStore(defaults: defaults)
        let p = StartupProfile(launchingToBuilding: 0.4, buildingToConnecting: 2.1, connectingToReady: 0.9)
        store.record(p, for: "site-a")
        #expect(store.profile(for: "site-a") == p)
    }

    @Test("Timing is isolated per site id")
    func perSiteIsolation() {
        let store = StartupTimingStore(defaults: defaults)
        let p = StartupProfile(launchingToBuilding: 0.4, buildingToConnecting: 2.1, connectingToReady: 0.9)
        store.record(p, for: "site-a")
        #expect(store.profile(for: "site-b") == StartupProfile.default)
    }

    @Test("Implausible profile is not recorded")
    func implausibleIgnored() {
        let store = StartupTimingStore(defaults: defaults)
        let bad = StartupProfile(launchingToBuilding: -1, buildingToConnecting: 0, connectingToReady: 0)
        store.record(bad, for: "site-a")
        #expect(store.profile(for: "site-a") == StartupProfile.default)
    }

    @Test("Corrupt stored data falls back to the default profile")
    func corruptFallsBack() {
        let store = StartupTimingStore(defaults: defaults)
        defaults.set(Data([0x00, 0x01, 0x02]), forKey: "anglesite.startupTiming.site-a")
        #expect(store.profile(for: "site-a") == StartupProfile.default)
    }

    @Test("Default profile is plausible and weighted toward building")
    func defaultIsPlausible() {
        let d = StartupProfile.default
        #expect(d.isPlausible)
        #expect(d.buildingToConnecting > d.launchingToBuilding)
        #expect(d.buildingToConnecting > d.connectingToReady)
    }
}
