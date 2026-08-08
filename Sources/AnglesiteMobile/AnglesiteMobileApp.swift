import SwiftUI

/// Entry point (#866): lists `.anglesite` packages discovered via iCloud. `RemoteSessionScreen`
/// (the #71 remote-sandbox thin client, deferred to v2.0 under #342) is still in this target but
/// no longer wired to the root scene — see this file's git history, and #800's owner decision
/// (2026-07-17) that the iCloud-discovery + Micropub flow is the default iOS experience now.
@main
struct AnglesiteMobileApp: App {
    var body: some Scene {
        WindowGroup {
            SitePickerScreen()
        }
    }
}
