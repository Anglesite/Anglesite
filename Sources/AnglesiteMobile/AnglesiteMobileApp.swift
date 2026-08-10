import SwiftUI

/// Entry point: the adaptive posting shell (#869) — iCloud-discovered sites in a
/// `NavigationSplitView` that collapses to a stack on iPhone (design §3). `SitePickerScreen`
/// (#866's standalone list) and `RemoteSessionScreen` (the #71 remote-sandbox thin client,
/// deferred to v2.0 under #342) remain in this target but are no longer wired to the root
/// scene — see this file's git history, and #800's owner decision (2026-07-17) that the
/// iCloud-discovery + Micropub flow is the default iOS experience now.
@main
struct AnglesiteMobileApp: App {
    var body: some Scene {
        WindowGroup {
            SiteSplitScreen()
        }
    }
}
