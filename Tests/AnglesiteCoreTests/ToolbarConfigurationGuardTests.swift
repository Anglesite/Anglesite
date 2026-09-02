import Testing
import Foundation
@testable import AnglesiteCore
import AnglesiteTestSupport

/// `final class` so `deinit` drops the throwaway suite (mirrors AppSettingsTests/StartupTimingStoreTests).
final class ToolbarConfigurationGuardTests {
    private let scratch = TemporaryUserDefaults(label: "toolbar-guard")
    private var defaults: UserDefaults { scratch.defaults }

    deinit { scratch.cleanup() }

    @Test("First-ever launch (no recorded OS build) does not purge")
    func firstLaunchDoesNotPurge() {
        defaults.set("stale-config", forKey: "NSToolbar Configuration site")
        let guardian = ToolbarConfigurationGuard(defaults: defaults)
        guardian.purgeIfNeeded(currentOSBuild: "26A5421a")
        #expect(defaults.string(forKey: "NSToolbar Configuration site") == "stale-config")
    }

    @Test("Same OS build across launches does not purge")
    func sameBuildDoesNotPurge() {
        let guardian = ToolbarConfigurationGuard(defaults: defaults)
        guardian.purgeIfNeeded(currentOSBuild: "26A5421a")
        defaults.set("layout", forKey: "NSToolbar Configuration site")
        guardian.purgeIfNeeded(currentOSBuild: "26A5421a")
        #expect(defaults.string(forKey: "NSToolbar Configuration site") == "layout")
    }

    @Test("A changed OS build purges the stale toolbar configuration")
    func changedBuildPurges() {
        let guardian = ToolbarConfigurationGuard(defaults: defaults)
        guardian.purgeIfNeeded(currentOSBuild: "26A5421a")
        defaults.set("layout", forKey: "NSToolbar Configuration site")
        guardian.purgeIfNeeded(currentOSBuild: "26A5425a")
        #expect(defaults.string(forKey: "NSToolbar Configuration site") == nil)
    }

    @Test("A changed OS build records the new build for next time")
    func changedBuildRecordsNewBuild() {
        let guardian = ToolbarConfigurationGuard(defaults: defaults)
        guardian.purgeIfNeeded(currentOSBuild: "26A5421a")
        guardian.purgeIfNeeded(currentOSBuild: "26A5425a")
        guardian.purgeIfNeeded(currentOSBuild: "26A5425a")
        // Third call sees the same build as the second, so a layout set after the second call survives.
        defaults.set("layout", forKey: "NSToolbar Configuration site")
        guardian.purgeIfNeeded(currentOSBuild: "26A5425a")
        #expect(defaults.string(forKey: "NSToolbar Configuration site") == "layout")
    }

    @Test("Absent last-known build never purges regardless of current build")
    func shouldPurgePureFunctionFirstLaunch() {
        #expect(ToolbarConfigurationGuard.shouldPurge(lastKnownOSBuild: nil, currentOSBuild: "26A5425a") == false)
    }

    @Test("Matching builds do not purge")
    func shouldPurgePureFunctionMatching() {
        #expect(ToolbarConfigurationGuard.shouldPurge(lastKnownOSBuild: "26A5421a", currentOSBuild: "26A5421a") == false)
    }

    @Test("Differing builds purge")
    func shouldPurgePureFunctionDiffering() {
        #expect(ToolbarConfigurationGuard.shouldPurge(lastKnownOSBuild: "26A5421a", currentOSBuild: "26A5425a") == true)
    }
}
