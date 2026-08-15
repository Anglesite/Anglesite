import SwiftUI
import WebKit
import AVFoundation
import AnglesiteCore
import AnglesiteBridge
import AnglesiteIOS
import AnglesiteIntents

/// The full-screen "Edit Site" session cover (#1431, iOS v2.0 design §3): live preview plus
/// edit overlay over the P2P session, with session states rendered in the owner's vocabulary.
/// Done suspends the UI while the session stays warm (the shell owns the model); the explicit
/// Stop action ends the session. First entry with no paired Mac walks into pairing onboarding.
struct EditSiteScreen: View {
    @Bindable var model: EditSessionModel
    @Environment(\.dismiss) private var dismiss

    /// Built lazily so the camera-access prompt can't fire before the walk-in needs it.
    @State private var pairingModel: PairingOnboardingModel?
    /// Per-session Siri onscreen-entity provider — the same wiring the retired #71 scaffold
    /// used (#1386), owned by the screen because the annotation feed only matters while the
    /// cover renders.
    @State private var annotationProvider: PreviewAnnotationProvider?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(Text(verbatim: model.siteDisplayName))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        // Suspends the session *UI* only — the session stays warm for quick
                        // re-entry (design §3); Stop is the explicit way to end it.
                        Button("Done") { dismiss() }
                    }
                    if model.isSessionActive {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                Task {
                                    await model.stop()
                                    dismiss()
                                }
                            } label: {
                                Label("Stop", systemImage: "stop.circle")
                            }
                        }
                    }
                }
        }
        .task { await model.open() }
        .onAppear { registerAnnotationProvider() }
        .onDisappear { unregisterAnnotationProvider() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .pairingRequired:
            PairingOnboardingScreen(model: resolvedPairingModel()) {
                Task { await model.completePairing() }
            }
        case .idle, .waking:
            sessionProgress(String(localized: "Waking your Mac…"))
        case .starting:
            sessionProgress(String(localized: "Starting your site…"))
        case .ready(let url):
            P2PSessionPreview(url: url, model: model, annotationProvider: annotationProvider)
                .ignoresSafeArea(edges: .bottom)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Reach Your Site", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: message)
            } actions: {
                Button("Try Again") {
                    Task { await model.open() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func sessionProgress(_ message: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(verbatim: message)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// One pairing model per walk-in, wired to the real camera prompt and the real store.
    private func resolvedPairingModel() -> PairingOnboardingModel {
        if let pairingModel { return pairingModel }
        let fresh = PairingOnboardingModel(
            requestCameraAccess: { await AVCaptureDevice.requestAccess(for: .video) },
            storeDevice: { try PairedDeviceStore().add($0) }
        )
        pairingModel = fresh
        return fresh
    }

    private func registerAnnotationProvider() {
        guard annotationProvider == nil else { return }
        let provider = PreviewAnnotationProvider(
            siteID: model.siteID.uuidString, graph: SiteContentGraph())
        annotationProvider = provider
        PreviewAnnotationProviderRegistry.shared.register(provider, for: provider.siteID)
    }

    private func unregisterAnnotationProvider() {
        guard let provider = annotationProvider else { return }
        PreviewAnnotationProviderRegistry.shared.unregister(siteID: provider.siteID)
        annotationProvider = nil
    }
}

/// The `WKWebView` leg over the P2P session: the same shared-bridge composition the remote
/// sandbox preview used (`AnglesiteScriptHandler` + edit-overlay user script + the Siri
/// annotation hookup), minus its session-token cookie injection — pinned-key DTLS replaces
/// bearer auth end to end (design §3), so there is nothing to inject before the first load.
private struct P2PSessionPreview: View {
    let url: URL
    let model: EditSessionModel
    let annotationProvider: PreviewAnnotationProvider?

    var body: some View {
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
            configureWebView: { webView in
                // `appEntityUIElementProvider` and `uiElements(for:)` are gated behind
                // `#if compiler(>=6.4)` in AnglesiteIntents (iOS 26+ SDK symbols); CI's
                // `ios-build` toolchain predates both, so this call site must stay gated in
                // lockstep or it fails to compile there even though the surrounding view
                // type-checks fine.
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
