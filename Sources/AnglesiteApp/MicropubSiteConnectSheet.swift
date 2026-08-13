import SwiftUI
import AnglesiteCore
import AnglesiteIOS

/// Mac-side entry point for the same IndieAuth onboarding flow the iOS app already ships (#868)
/// — reused as-is via `MicropubOnboardingModel`, with `SiteMicropubSignIn` (Task A1) standing in
/// as the AppKit `ASWebAuthenticationSession` adapter where iOS drives SwiftUI's
/// `webAuthenticationSession` environment value instead (see `SiteMicropubSignIn.swift`'s doc
/// comment). A successful sign-in leaves a `MicropubSession` resolvable from Keychain for this
/// site (`SecretStore.readMicropubAccessToken(siteID:)`) — the CMS-mode save path (Task A5)
/// checks for exactly that.
///
/// Presented from Website ▸ Connect for CMS Mode… (`WebsiteCommands`); the site is captured at
/// sheet-presentation time from `SiteWindowModel.site`, mirroring how `SiteWindow.swift` already
/// passes `site` into `NewPageSheet`/`NewCollectionEntrySheet` for its other `.sheet(isPresented:)`
/// presentations.
struct MicropubSiteConnectSheet: View {
    let site: SiteStore.Site

    @Environment(\.dismiss) private var dismiss
    @State private var model: MicropubOnboardingModel?
    /// Set when `site.id` (a `String`) doesn't parse as a `UUID` — `SitePickerModel.DiscoveredSite`
    /// requires a real `UUID`, unlike `SiteStore.Site`. This should never happen in practice (both
    /// ultimately trace back to the same `AnglesitePackage.Marker.siteID`), but `configure(site:)`
    /// can't run without one, so this is surfaced rather than silently substituting a fresh
    /// `UUID()` that would scope Keychain reads/writes to the wrong identity.
    @State private var invalidSiteID = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Connect for CMS Mode")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
        .padding()
        .frame(minWidth: 380, minHeight: 220)
        // Guarded the same way `SiteSignInScreen.task` guards its `model == nil` check: the
        // outer `NavigationStack`/`content` identity is stable across the state transitions
        // this drives, so `.task` only runs configuration once per sheet presentation.
        .task {
            guard model == nil, !invalidSiteID else { return }
            guard let siteID = UUID(uuidString: site.id) else {
                invalidSiteID = true
                return
            }
            let discovered = SitePickerModel.DiscoveredSite(
                id: siteID, displayName: site.name, packageURL: site.packageURL)
            let model = MicropubOnboardingModel(webAuthenticator: SiteMicropubSignIn())
            self.model = model
            await model.configure(site: discovered)
        }
    }

    @ViewBuilder
    private var content: some View {
        if invalidSiteID {
            ContentUnavailableView {
                Label("Can't Connect", systemImage: "exclamationmark.triangle")
            } description: {
                Text("This site's identity couldn't be read. Try reopening it and connecting again.")
            }
        } else {
            switch model?.state ?? .idle {
            case .idle, .discovering:
                ProgressView("Looking for this site's Micropub endpoint…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .needsDeployedSite:
                ContentUnavailableView {
                    Label("Not Deployed Yet", systemImage: "icloud.and.arrow.up")
                } description: {
                    Text("Publish this site at least once before connecting it for CMS mode.")
                }
            case .signedOut:
                signInPrompt(
                    title: Text("Connect This Site"),
                    message: Text(
                        "Sign in with this site's own IndieAuth server to enable editing it as a CMS from other devices."
                    )
                )
            case .exchanging:
                ProgressView("Signing in…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .authorizing:
                // The web-auth sheet is up; this sits behind it.
                ProgressView("Waiting for sign-in…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .signedIn(let me):
                signedIn(me: me)
            case .cancelled:
                signInPrompt(
                    title: Text("Sign-In Canceled"),
                    message: Text("You closed the sign-in page before finishing. Sign in when you're ready.")
                )
            case .reauthorizationRequired:
                signInPrompt(
                    title: Text("Session Expired"),
                    message: Text("This site signed you out. Sign in again to keep CMS mode connected.")
                )
            case .failed(let reason):
                failure(reason: reason)
            }
        }
    }

    private func signInPrompt(title: Text, message: Text) -> some View {
        VStack(spacing: 12) {
            title.font(.title2.bold())
            message
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Sign In") { Task { await model?.signIn() } }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func signedIn(me: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text("Connected")
                .font(.title2.bold())
            Text(verbatim: me)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // One-time import of this site's existing typed content into D1 (Task B1/B2, spec §C.7).
        // `micropubClient` is only non-nil right after a fresh `signIn()` — a session restored
        // from Keychain on `configure(site:)` leaves it `nil` (endpoint discovery isn't
        // persisted), so this simply no-ops until the next real sign-in, matching
        // `MicropubOnboardingModel`'s documented contract rather than forcing rediscovery here.
        .task {
            guard let client = model?.micropubClient else { return }
            var settings = (try? SiteConfigStore.read(from: site.configDirectory)) ?? SiteSettings()
            guard settings.contentImportCompleted != true else { return }
            _ = await MicropubContentImport.importIfNeeded(
                siteDirectory: site.sourceDirectory, configDirectory: site.configDirectory, client: client)
            settings.contentImportCompleted = true
            try? await SiteConfigStore(configDirectory: site.configDirectory).save(settings)
        }
    }

    @ViewBuilder
    private func failure(reason: MicropubOnboardingModel.FailureReason) -> some View {
        switch reason {
        case .micropubNotSupported:
            ContentUnavailableView {
                Label("CMS Mode Not Available", systemImage: "server.rack")
            } description: {
                Text("This site's Worker doesn't include Micropub yet. Redeploy it with a current Anglesite build.")
            }
        case .indieAuthNotSupported:
            ContentUnavailableView {
                Label("Sign-In Not Available", systemImage: "person.crop.circle.badge.questionmark")
            } description: {
                Text("This site doesn't offer IndieAuth sign-in yet. Redeploy it with a current Anglesite build.")
            }
        case .siteUnreachable:
            ContentUnavailableView {
                Label("Site Unreachable", systemImage: "wifi.slash")
            } description: {
                Text("Couldn't reach this site. Check your connection and try again.")
            } actions: {
                retryButton
            }
        case .signInFailed:
            ContentUnavailableView {
                Label("Sign-In Failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Something went wrong while signing in. Try again.")
            } actions: {
                retryButton
            }
        }
    }

    private var retryButton: some View {
        Button("Try Again") { Task { await model?.signIn() } }
            .buttonStyle(.borderedProminent)
    }
}
