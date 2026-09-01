import Foundation

/// Slice-1 rollout gate for the AppKit site-window shell (#1699 Stage 3 design §Rollout):
/// off by default so `main` keeps shipping the legacy `NavigationSplitView` chrome; enabled
/// per-machine via defaults or per-launch via environment for harness runs. Deleted in
/// slice 3 when the shell becomes the only chrome.
enum SiteShellFlag {
    static let defaultsKey = "experimental.appKitShell"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["ANGLESITE_APPKIT_SHELL"] == "1"
            || UserDefaults.standard.bool(forKey: defaultsKey)
    }
}
