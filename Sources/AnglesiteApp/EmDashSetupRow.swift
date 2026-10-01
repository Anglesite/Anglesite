import SwiftUI
import AnglesiteCore
import AuthenticationServices

/// The New Site chooser's EmDash setup choice (#2106): set up a new EmDash, or connect one the
/// owner already has. Connecting finds the EmDash sites in the owner's Cloudflare account
/// (signing in first if needed) and lets them pick one. Owner terms throughout (decision D1):
/// sites, images and plugins, never Workers or databases.
struct EmDashSetupRow: View {
    @Bindable var model: NewSiteWizardModel
    @State private var signingIn = false

    var body: some View {
        @Bindable var search = model.emdashSearch
        VStack(alignment: .leading, spacing: 8) {
            Picker("EmDash:", selection: $model.connectsExistingEmDash) {
                Text("Set Up a New One").tag(false)
                Text("Connect One I Already Have").tag(true)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .accessibilityIdentifier(AXID.newSiteEmDashSetup)
            if model.connectsExistingEmDash {
                chooser(search: $search.selectedWorkerName)
            }
        }
        // Look as soon as the owner picks "connect", without a second click.
        .task(id: model.connectsExistingEmDash) {
            if model.connectsExistingEmDash, model.emdashSearch.state == .idle {
                await model.emdashSearch.search()
            }
        }
    }

    @ViewBuilder private func chooser(search selection: Binding<String?>) -> some View {
        switch model.emdashSearch.state {
        case .idle, .searching:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Looking for your EmDash sites…").font(.callout).foregroundStyle(.secondary)
            }
        case .needsSignIn:
            HStack {
                Text("Sign in to Cloudflare so Anglesite can find your EmDash sites.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Sign In to Cloudflare…") { signIn() }.disabled(signingIn)
            }
        case .found(let installs) where installs.isEmpty:
            HStack {
                Text("No EmDash sites were found in your Cloudflare account.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Search Again") { search() }
            }
        case .found(let installs):
            VStack(alignment: .leading, spacing: 4) {
                Picker("Site:", selection: selection) {
                    Text("Choose…").tag(String?.none)
                    ForEach(installs) { install in
                        Text(install.workerName).tag(Optional(install.workerName))
                    }
                }
                .fixedSize()
                .accessibilityIdentifier(AXID.newSiteEmDashSite)
                if model.emdashSearch.selectedInstall?.problem == .mediaBucketUnclear {
                    Text("Anglesite can't tell where this EmDash site keeps its images, so it can't connect it.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .failed(let failure):
            HStack {
                Text(Self.message(for: failure)).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { search() }
            }
        }
    }

    private func search() {
        Task { await model.emdashSearch.search() }
    }

    private func signIn() {
        signingIn = true
        Task {
            defer { signingIn = false }
            switch await EmDashSearchSignIn.signIn() {
            case .signedIn: await model.emdashSearch.search()
            case .cancelled: break
            case .failed: model.emdashSearch.signInFailed()
            }
        }
    }

    static func message(for failure: EmDashInstallSearch.Failure) -> String {
        switch failure {
        case .cannotReadDatabases:
            return String(localized: "Your Cloudflare sign-in can't read your EmDash sites, so they can't be found. Sign out in Settings ▸ Advanced ▸ Credentials, then sign in again here.")
        case .signInRefused:
            return String(localized: "Cloudflare didn't accept the saved sign-in. Sign out in Settings ▸ Advanced ▸ Credentials, then sign in again here.")
        case .noAccount:
            return String(localized: "Anglesite couldn't find a Cloudflare account for this sign-in.")
        case .signInFailed:
            return String(localized: "Couldn't sign in to Cloudflare. Try again in a moment.")
        case .unavailable:
            return String(localized: "Couldn't reach Cloudflare. Try again in a moment.")
        }
    }

    /// What connecting does to the owner's site, for the confirmation before the site is created.
    static func connectMessage(for install: EmDashInstall) -> String {
        var message = String(localized: "The website will switch to the design you chose here. Its articles, writers and settings stay in EmDash.")
        let stopping = install.pluginsThatStop
        if !stopping.isEmpty {
            let list = stopping.formatted(.list(type: .and))
            message += "\n\n" + String(localized: "These plugins will stop working: \(list).")
        }
        return message
    }
}

/// Signs in to Cloudflare from the New Site chooser, so it can look for the owner's EmDash sites
/// before any site exists to publish. The same OAuth flow and stored credential as Publish Site's
/// sign-in (`DeployModel.signInWithCloudflare()`); a failure is logged in full and reported plainly.
@MainActor
enum EmDashSearchSignIn {
    enum Outcome { case signedIn, cancelled, failed }

    static func signIn(
        keychain: any SecretStore = KeychainStore(),
        logCenter: LogCenter = .shared,
        oauthSignIn: CloudflareOAuthSignIn = CloudflareOAuthSignIn(
            client: CloudflareOAuthClient(scope: AnglesiteTokenTemplate.oauthScope),
            present: CloudflareOAuthSignIn.defaultPresenter)
    ) async -> Outcome {
        do {
            let result = try await oauthSignIn.run()
            try keychain.writeCloudflareOAuthCredential(CloudflareOAuthCredential(
                accessToken: result.token.accessToken,
                refreshToken: result.token.refreshToken,
                expiresAt: result.token.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) },
                tokenEndpoint: result.tokenEndpoint))
            return .signedIn
        } catch is CancellationError {
            return .cancelled
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return .cancelled
        } catch CloudflareOAuthError.callbackDenied {
            return .cancelled
        } catch {
            await logCenter.append(
                source: "cloudflare-oauth-sign-in", stream: .stderr,
                text: "Cloudflare sign-in from New Site failed: \(error)")
            return .failed
        }
    }
}
