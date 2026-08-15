import SwiftUI

/// Entry point: the adaptive posting shell (#869) — iCloud-discovered sites in a
/// `NavigationSplitView` that collapses to a stack on iPhone (design §3). `SitePickerScreen`
/// (#866's standalone list) remains in this target but is no longer wired to the root scene —
/// see this file's git history, and #800's owner decision (2026-07-17) that the
/// iCloud-discovery + Micropub flow is the default iOS experience now. The #71 remote-sandbox
/// thin-client UI (`RemoteSessionScreen` + its connect form and view-model) is retired
/// entirely (#1433, iOS v2.0 design §2): editing rides the P2P "Edit Site" session UI, and
/// the Cloudflare scaffold survives only behind the `SiteRuntime` seam in `AnglesiteCore`.
@main
struct AnglesiteMobileApp: App {
    var body: some Scene {
        WindowGroup {
            SiteSplitScreen()
        }
    }
}
