import SwiftUI
import WebKit
import AuthenticationServices
import AnglesiteCore
import AnglesiteBridge
import AnglesiteIOS
import AnglesiteIntents

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
        let annotationProvider = model.annotationProvider
        let onVisibleElements: AnglesiteScriptHandler.VisibleElementsHandler? = annotationProvider.map { provider in
            { @Sendable elements in await provider.update(elements) }
        }
        let handler = AnglesiteScriptHandler(
            router: MCPApplyEditRouter(mcpClient: { [weak model] in await MainActor.run { model?.mcpClient } }),
            onVisibleElements: onVisibleElements
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
            },
            configureWebView: { webView in
                // `appEntityUIElementProvider` and `uiElements(for:)` are gated behind
                // `#if compiler(>=6.4)` in AnglesiteIntents (iOS 26+ SDK symbols); CI's
                // `ios-build` job still resolves an older toolchain (Xcode 26.6 / Swift 6.3.3)
                // that lacks both, so this call site must stay gated in lockstep or it fails to
                // compile there even though the surrounding view type-checks fine.
                #if compiler(>=6.4)
                guard let annotationProvider else { return }
                webView.appEntityUIElementProvider = { [weak annotationProvider] _, hitContext in
                    guard let annotationProvider else { return [] }
                    return annotationProvider.uiElements(for: hitContext)
                }
                #endif
            }
        )
    }
}

/// Connect form: the Worker URL + bearer token + site ID are local drafts that only persist via
/// the verify-then-persist Connect flow (#889) — nothing is stored until the Worker actually
/// answers a status probe with that URL + token. The token then writes through to the iOS
/// Keychain (`SecretAccounts.sandboxControlToken`), never to defaults. The git coordinates below
/// stay directly bound: they're not part of the verified secret pair and there's nothing to
/// verify them against.
private struct RemoteConnectForm: View {
    @Bindable var model: RemoteSessionModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var isSigningInWithCloudflare = false
    @State private var cloudflareSignInError: String?

    @State private var workerURLDraft: String
    @State private var tokenDraft: String
    @State private var siteIDDraft: String
    @State private var connectTask: Task<Void, Never>?

    /// Interim target until the Control Worker template repo ships (2026-07-21 design §4) —
    /// labeled as a setup *guide* because tapping it doesn't deploy anything. Swapping in the
    /// real Deploy-to-Cloudflare URL later is a one-line change.
    private static let setupGuideURL = URL(string: "https://developers.cloudflare.com/containers/get-started/")!

    init(model: RemoteSessionModel) {
        self.model = model
        _workerURLDraft = State(initialValue: model.workerURLString)
        _tokenDraft = State(initialValue: model.controlToken)
        _siteIDDraft = State(initialValue: model.siteID)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        openSetupGuide()
                    } label: {
                        Label("Cloudflare Container Setup Guide", systemImage: "book")
                    }
                    TextField("https://anglesite-sandbox.example.workers.dev", text: $workerURLDraft)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("Control Worker token", text: $tokenDraft)
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
                    TextField("Site ID", text: $siteIDDraft)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    connectRow
                } header: {
                    Text("Cloudflare Control Worker")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        connectFooter
                        if let cloudflareSignInError {
                            Text(cloudflareSignInError)
                                .foregroundStyle(.red)
                        }
                    }
                }
                .disabled(model.connectionCheck == .checking)

                Section {
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
            .onDisappear {
                // A torn-down form must not let an in-flight connect confirm behind the user's
                // back — the onboarding re-checks this cancellation before proceeding.
                connectTask?.cancel()
            }
        }
    }

    private var canConnect: Bool {
        let blank = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return !blank(workerURLDraft) && !blank(tokenDraft) && !blank(siteIDDraft)
            && model.connectionCheck != .checking && !isSigningInWithCloudflare
    }

    private var connectRow: some View {
        Button {
            let workerURLString = workerURLDraft
            let token = tokenDraft
            let siteID = siteIDDraft
            connectTask = Task {
                await model.connect(workerURLString: workerURLString, token: token, siteID: siteID)
            }
        } label: {
            if model.connectionCheck == .checking {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Connecting…")
                }
            } else {
                Text("Connect")
            }
        }
        .disabled(!canConnect)
    }

    @ViewBuilder
    private var connectFooter: some View {
        switch model.connectionCheck {
        case .connected:
            Label("Reached your Worker", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
        case .idle, .checking:
            Text("From the one-time Cloudflare Container setup. The token is stored in the Keychain on this device only, after the Worker confirms it.")
        }
    }

    private func openSetupGuide() {
        Task {
            // No callback ever comes back from a docs page — the user reads the guide and
            // dismisses the sheet manually, so the resulting cancellation error is expected
            // and swallowed, not surfaced.
            _ = try? await webAuthenticationSession.authenticate(
                using: Self.setupGuideURL,
                callbackURLScheme: "anglesite"
            )
        }
    }

    /// Runs the Cloudflare OAuth flow (#891) via the shared `CloudflareOAuthSignIn`
    /// orchestration (AnglesiteCore — the same sequencing `DeployModel` uses on macOS) and
    /// fills the token *draft* with the resulting access token — the same draft the paste flow
    /// writes, so it still only persists via the verify-then-persist Connect flow (#889); OAuth
    /// is an additional way to populate the draft, not a bypass of verification. The browser
    /// sheet's callback is matched via Associated Domains against the #891 callback Worker
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
            tokenDraft = result.token.accessToken
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
