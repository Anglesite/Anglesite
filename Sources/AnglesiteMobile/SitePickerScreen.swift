import SwiftUI
import AnglesiteIOS

/// The iOS app's entry point (#866): lists `.anglesite` packages discovered in the user's iCloud
/// container instead of asking for a typed site URL. Replaces `RemoteSessionScreen` as
/// `AnglesiteMobileApp`'s root — per #800's owner decision (2026-07-17) that this iCloud-discovery
/// + Micropub flow, not the older remote-sandbox thin client (#71, deferred to v2.0 under #342),
/// is the default iOS experience. Picking a site doesn't do anything yet — that's the sibling
/// IndieAuth-onboarding issue.
struct SitePickerScreen: View {
    @State private var model = SitePickerModel()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(Text("Your Sites"))
        }
        // Attached to the `NavigationStack`, not to `content`: `content` is a `switch` over
        // `model.state`, so its view identity changes on every state transition — and `refresh()`
        // starts by publishing a new state. Hanging `.task` off it risks re-firing discovery on
        // each transition; the stack's identity is stable, so this runs once on first appearance.
        .task { await model.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView("Finding your sites…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .iCloudUnavailable:
            ContentUnavailableView {
                Label("iCloud Unavailable", systemImage: "icloud.slash")
            } description: {
                Text("Sign in to iCloud and turn on iCloud Drive to see your Anglesite sites.")
            } actions: {
                Button("Try Again") { Task { await model.refresh() } }
                    .buttonStyle(.borderedProminent)
            }
        case .empty:
            ContentUnavailableView {
                Label("No Sites Found", systemImage: "globe")
            } description: {
                Text("No sites found — create a site in Anglesite on your Mac first.")
            } actions: {
                Button("Refresh") { Task { await model.refresh() } }
                    .buttonStyle(.borderedProminent)
            }
        case .sites(let sites):
            List(sites) { site in
                Text(site.displayName)
            }
            .refreshable { await model.refresh() }
        }
    }
}
