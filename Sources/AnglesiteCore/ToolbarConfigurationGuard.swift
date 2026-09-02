import Foundation

/// Guards the site window's customizable toolbar (`.toolbar(id: "site")`, SiteWindow.swift)
/// against a launch crash seen on macOS beta updates (#1704): NSToolbar's own autosave writes
/// SwiftUI-internal item identifiers into its persisted configuration, and those identifiers are
/// an implementation detail of the SwiftUI/AppKit build that wrote them — a *different* build
/// (e.g. after an OS update) can trap in `applyItemCustomizations` trying to apply them.
///
/// The framework can't be made to tolerate stale identifiers, so this purges the persisted
/// configuration itself whenever the OS build has changed since the last successful launch —
/// losing a custom toolbar layout beats a launch crash. Call `purgeIfNeeded()` once, as early as
/// possible and before any window with the guarded toolbar can be created (see
/// `AppDelegate.applicationWillFinishLaunching`).
public final class ToolbarConfigurationGuard: @unchecked Sendable {
    /// Shared instance bound to `UserDefaults.standard`. Tests construct their own with a scratch suite.
    public static let shared = ToolbarConfigurationGuard(defaults: .standard)

    /// NSToolbar's own autosave key for the site window's `.toolbar(id: "site")` (SiteWindow.swift) —
    /// AppKit's `"NSToolbar Configuration <identifier>"` format, not app-namespaced, so it
    /// deliberately doesn't live in `AppSettings.Key`.
    public static let siteToolbarConfigurationKey = "NSToolbar Configuration site"

    private static let lastLaunchedOSBuildKey = "anglesite.lastLaunchedOSBuild"

    private let defaults: UserDefaults

    /// Creates a guard over `defaults`. Injectable so tests can use a scratch suite instead of
    /// polluting (or depending on) `UserDefaults.standard`.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Purges `toolbarConfigurationKey` when `currentOSBuild` differs from the OS build recorded at
    /// the last successful launch, then records `currentOSBuild` for next time. A first-ever launch
    /// (nothing recorded yet) never purges — there's no evidence yet that anything's stale.
    public func purgeIfNeeded(
        toolbarConfigurationKey: String = ToolbarConfigurationGuard.siteToolbarConfigurationKey,
        currentOSBuild: String = ProcessInfo.processInfo.operatingSystemVersionString
    ) {
        let lastKnownOSBuild = defaults.string(forKey: Self.lastLaunchedOSBuildKey)
        if Self.shouldPurge(lastKnownOSBuild: lastKnownOSBuild, currentOSBuild: currentOSBuild) {
            defaults.removeObject(forKey: toolbarConfigurationKey)
        }
        defaults.set(currentOSBuild, forKey: Self.lastLaunchedOSBuildKey)
    }

    /// Pure decision, exposed for testing without touching `UserDefaults`: purge only when a prior
    /// build was recorded and it differs from the current one.
    public static func shouldPurge(lastKnownOSBuild: String?, currentOSBuild: String) -> Bool {
        guard let lastKnownOSBuild else { return false }
        return lastKnownOSBuild != currentOSBuild
    }
}
