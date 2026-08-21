import SwiftUI
import AuthenticationServices
import AnglesiteIOS

/// Production `SiteWebAuthenticating` adapter over SwiftUI's `webAuthenticationSession`
/// environment — the system-managed `ASWebAuthenticationSession` sheet. Maps the session's
/// user-dismissal error to `SiteWebAuthenticationCancelled` so `MicropubOnboardingModel` can
/// keep cancellation distinct from failure (#868's explicit requirement).
private struct SessionWebAuthenticator: SiteWebAuthenticating {
    let session: WebAuthenticationSession

    func authenticate(authorizeURL: URL, callbackScheme: String) async throws -> URL {
        do {
            return try await session.authenticate(
                using: authorizeURL, callback: .customScheme(callbackScheme),
                additionalHeaderFields: [:])
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            throw SiteWebAuthenticationCancelled()
        }
    }
}

/// Per-site IndieAuth onboarding (#868): pushed from `SitePickerScreen` when the user picks a
/// site. The user authenticates against *their own site's* IndieAuth server in the system
/// web-auth sheet; the resulting token stays in the Keychain, scoped to this site.
struct SiteSignInScreen: View {
    let site: SitePickerModel.DiscoveredSite
    /// Fired whenever this screen's flow reaches the signed-in state — including a restore
    /// found on configure — so an embedding shell (`SiteSplitScreen`, #869) can re-resolve the
    /// site's session and swap in the posting surfaces.
    var onAuthenticated: () -> Void = {}

    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var model: MicropubOnboardingModel?

    var body: some View {
        content
            .navigationTitle(Text(verbatim: site.displayName))
            .navigationBarTitleDisplayMode(.inline)
            // `content` switches over the model's state, so its identity changes per
            // transition — same reasoning as `SitePickerScreen`: hang `.task` off the stable
            // outer view so configuration runs once.
            .task {
                guard model == nil else { return }
                let model = MicropubOnboardingModel(
                    webAuthenticator: SessionWebAuthenticator(session: webAuthenticationSession))
                self.model = model
                await model.configure(site: site)
                notifyIfSignedIn()
                await model.refreshConformanceAdvisory()
            }
    }

    private func notifyIfSignedIn() {
        if case .signedIn = model?.state { onAuthenticated() }
    }

    @ViewBuilder
    private var content: some View {
        switch model?.state ?? .idle {
        case .idle:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .needsDeployedSite:
            ContentUnavailableView {
                Label("Not Deployed Yet", systemImage: "icloud.and.arrow.up")
            } description: {
                Text("Deploy this site from Anglesite on your Mac first, then come back to post from here.")
            }
        case .signedOut:
            signInPrompt(
                title: Text("Post to Your Site"),
                message: Text("Sign in with your site to create and edit posts from this device.")
            )
        case .discovering, .exchanging:
            ProgressView("Signing in…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .authorizing:
            // The web-auth sheet is up; this sits behind it.
            ProgressView("Waiting for sign-in…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .signedIn(let me):
            signedIn(me: me)
        case .cancelled:
            // A dismissal is a choice, not an error — calm copy, no warning iconography.
            signInPrompt(
                title: Text("Sign-In Canceled"),
                message: Text("You closed the sign-in page before finishing. Sign in when you're ready.")
            )
        case .reauthorizationRequired:
            signInPrompt(
                title: Text("Session Expired"),
                message: Text("Your site signed you out. Sign in again to keep posting.")
            )
        case .failed(let reason):
            failure(reason: reason)
        }
    }

    private func signInPrompt(title: Text, message: Text) -> some View {
        VStack(spacing: 12) {
            title.font(.title2.bold())
            message
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                Task {
                    await model?.signIn()
                    notifyIfSignedIn()
                }
            } label: {
                Text("Sign In")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
            ConformanceAdvisoryLabel(advisory: model?.conformanceAdvisory)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func signedIn(me: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text("Signed In")
                .font(.title2.bold())
            Text(verbatim: me)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
            Button("Sign Out", role: .destructive) {
                model?.signOut()
            }
            .buttonStyle(.bordered)
            .padding(.top, 8)
            ConformanceAdvisoryLabel(advisory: model?.conformanceAdvisory)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func failure(reason: MicropubOnboardingModel.FailureReason) -> some View {
        switch reason {
        case .micropubNotSupported:
            // Conformance gate not met: name the requirement instead of degrading (§7 of the
            // iOS posting-client design).
            ContentUnavailableView {
                Label("Posting Not Available", systemImage: "square.and.pencil")
            } description: {
                Text("This site's Worker doesn't include Micropub yet. Update and redeploy it from Anglesite on your Mac.")
            }
        case .indieAuthNotSupported:
            ContentUnavailableView {
                Label("Sign-In Not Available", systemImage: "person.crop.circle.badge.questionmark")
            } description: {
                Text("This site doesn't offer IndieAuth sign-in yet. Update and redeploy it from Anglesite on your Mac.")
            }
        case .siteUnreachable:
            ContentUnavailableView {
                Label("Site Unreachable", systemImage: "wifi.slash")
            } description: {
                Text("Couldn't reach your site. Check your connection and try again.")
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
        Button("Try Again") {
            Task {
                await model?.signIn()
                notifyIfSignedIn()
            }
        }
        .buttonStyle(.borderedProminent)
    }
}
