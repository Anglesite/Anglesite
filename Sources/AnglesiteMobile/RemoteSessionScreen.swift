import SwiftUI
import WebKit
import AuthenticationServices
import AnglesiteCore
import AnglesiteBridge
import AnglesiteIOS

/// Root screen of the iOS thin client: connect form until a session is configured and started,
/// then the live sandbox preview. iPad-first, but nothing here is size-class-specific yet.
struct RemoteSessionScreen: View {
    @Bindable var model: RemoteSessionModel
    @State private var showsSettings = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(Text("Anglesite"))
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showsSettings = true
                        } label: {
                            Label("Session Settings", systemImage: "gearshape")
                        }
                    }
                    if case .ready = model.state {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                model.stop()
                            } label: {
                                Label("Stop", systemImage: "stop.circle")
                            }
                        }
                    }
                }
                .sheet(isPresented: $showsSettings) {
                    RemoteConnectForm(model: model)
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            ContentUnavailableView {
                Label("No Site Open", systemImage: "globe")
            } description: {
                Text("Open your site in the remote sandbox to preview and edit it.")
            } actions: {
                if model.isConfigured {
                    Button("Open Site") { model.start() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Connect…") { showsSettings = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        case .starting(let siteID):
            VStack(spacing: 12) {
                ProgressView()
                Text("Starting \(siteID) in the sandbox…")
                    .foregroundStyle(.secondary)
            }
        case .ready(_, let url, _):
            RemoteSandboxPreview(url: url, model: model)
                .ignoresSafeArea(edges: .bottom)
        case .failed(_, let message):
            ContentUnavailableView {
                Label("Couldn't Open Site", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { model.start() }
                    .buttonStyle(.borderedProminent)
                Button("Session Settings…") { showsSettings = true }
            }
        }
    }
}

/// The `WKWebView` leg: composes the shared bridge configuration (script handler + edit
/// overlay user script) and injects the session-token cookie before the first request so the
/// in-container auth-proxy accepts the preview and its HMR WebSocket (#67).
private struct RemoteSandboxPreview: View {
    let url: URL
    let model: RemoteSessionModel

    var body: some View {
        let token = model.sessionToken
        let handler = AnglesiteScriptHandler(
            router: MCPApplyEditRouter(mcpClient: { [weak model] in await MainActor.run { model?.mcpClient } })
        )
        RemotePreviewWebView(
            url: url,
            makeConfiguration: {
                WebViewBridge.localDevConfiguration(handler: handler)
            },
            prepareBeforeLoad: { webView in
                guard let token, let host = url.host() else { return }
                await WebViewBridge.injectSessionToken(
                    into: webView.configuration.websiteDataStore.httpCookieStore,
                    token: token,
                    for: host
                )
            }
        )
    }
}

/// Connect form: the Worker URL + bearer token from the one-time Deploy-to-Cloudflare
/// provisioning, plus the site's git coordinates. The token field writes through to the iOS
/// Keychain (`SecretAccounts.sandboxControlToken`), never to defaults.
private struct RemoteConnectForm: View {
    @Bindable var model: RemoteSessionModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var isSigningInWithCloudflare = false
    @State private var cloudflareSignInError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://anglesite-sandbox.example.workers.dev", text: $model.workerURLString)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("Control Worker token", text: $model.controlToken)
                        // Disabled alongside the button below: a token pasted while the browser
                        // sheet is up would be silently overwritten when the flow completes.
                        .disabled(isSigningInWithCloudflare)
                    Button {
                        Task { await connectViaCloudflare() }
                    } label: {
                        HStack {
                            Text("Connect via Cloudflare")
                            if isSigningInWithCloudflare {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isSigningInWithCloudflare)
                } header: {
                    Text("Cloudflare Control Worker")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("From the one-time Deploy to Cloudflare setup. The token is stored in the Keychain on this device only.")
                        if let cloudflareSignInError {
                            Text(cloudflareSignInError)
                                .foregroundStyle(.red)
                        }
                    }
                }

                Section {
                    TextField("Site ID", text: $model.siteID)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("https://github.com/you/site.git", text: $model.gitRemoteString)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Branch", text: $model.gitRef)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Site")
                } footer: {
                    Text("The sandbox clones this repository — git stays the source of truth for your site.")
                }
            }
            .navigationTitle(Text("Remote Session"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Runs the Cloudflare OAuth flow (#891) via the shared `CloudflareOAuthSignIn`
    /// orchestration (AnglesiteCore — the same sequencing `DeployModel` uses on macOS) and
    /// fills the token field with the resulting access token — the same field the paste flow
    /// writes, so nothing downstream changes. The browser sheet's callback is matched via
    /// Associated Domains against the #891 callback Worker
    /// (`webcredentials:auth.anglesite.dwk.io`). Error split mirrors
    /// `DeployModel.signInWithCloudflare`: cancel and consent-decline are silent, everything
    /// else (including a `state` mismatch, never silently accepted) surfaces as one
    /// plain-language line — raw errors can carry server response bodies that aren't fit to
    /// show a non-technical site owner, so the real error goes to `LogCenter` instead.
    private func connectViaCloudflare() async {
        cloudflareSignInError = nil
        isSigningInWithCloudflare = true
        defer { isSigningInWithCloudflare = false }
        let session = webAuthenticationSession
        let signIn = CloudflareOAuthSignIn(
            client: CloudflareOAuthClient(scope: AnglesiteTokenTemplate.oauthScope),
            present: { authorizeURL in
                try await session.authenticate(
                    using: authorizeURL,
                    callback: .https(
                        host: CloudflareOAuthConfiguration.redirectURI.host!,
                        path: CloudflareOAuthConfiguration.redirectURI.path),
                    additionalHeaderFields: [:])
            })
        do {
            let result = try await signIn.run()
            model.controlToken = result.token.accessToken
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // The user dismissed the browser sheet — normal abort, no error banner.
        } catch CloudflareOAuthError.callbackDenied {
            // The user declined on Cloudflare's own consent screen — same treatment as
            // cancelling the sheet itself, not a connection failure.
        } catch {
            await LogCenter.shared.append(
                source: "cloudflare-oauth-sign-in", stream: .stderr,
                text: "Cloudflare sign-in failed: \(error)")
            cloudflareSignInError = String(localized: "Couldn't sign in to Cloudflare. Try again in a moment.")
        }
    }
}
