import SwiftUI
import AppKit
import WebKit
import AppIntents
import AnglesiteBridge
import AnglesiteCore
import AnglesiteIntents

/// SwiftUI wrapper around a `WKWebView` showing the live Astro dev server.
///
/// `url` is owned by the caller (a `PreviewModel` driven by a `SiteRuntime`). When it changes —
/// e.g. a supervised dev-server restart rebinds a new port — the web view reloads from the new URL.
///
/// `router` is the `EditRouter` the in-page overlay's `AnglesiteScriptHandler` forwards edits to.
/// In production it's the `MCPApplyEditRouter` from `PreviewModel`, wrapping the session's
/// `MCPClient`; tests can substitute any `EditRouter`.
///
/// `annotationProvider` is the per-window `PreviewAnnotationProvider` (Siri AI Phase B). When
/// supplied, the script handler routes `anglesite:visible-elements` messages into it, and the
/// WKWebView gets an `appEntityUIElementProvider` so AppKit's hit-test resolves visible regions
/// to live entities. Nil → those features are inert (overlay still works for hover/click/drop).
struct PreviewView: NSViewRepresentable {
    let url: URL
    let router: EditRouter
    let annotationProvider: PreviewAnnotationProvider?

    /// The mounted WYSIWYG canvas controller (#1225), or `nil` when edit mode is off. When
    /// non-nil, `makeNSView` registers a `WYSIWYGScriptHandler` wrapping it as a second
    /// `WKScriptMessageHandler` alongside the overlay's — `WYSIWYGCanvasController` forwards to
    /// its own transport, so no separate transport type is needed here. `PreviewModel.wysiwygCanvas`
    /// is the source of truth; `SiteWindow.previewPane(for:)` passes it straight through.
    var wysiwygTransport: (any WYSIWYGHostTransport)?

    /// Called with the `WKWebView` once it's created, so the owning `PreviewModel` can hold a weak
    /// reference and drive the View-menu preview commands (reload/history/zoom).
    /// Defaults to a no-op for callers (e.g. tests) that don't need it.
    var onWebView: (WKWebView) -> Void = { _ in }

    /// Called with the `WKWebView` when SwiftUI tears this view down (`dismantleNSView`) — e.g. a
    /// dev-server restart or failure switches `previewPane` away from the `.ready` branch. The
    /// owning `PreviewModel` needs this explicit signal: its `webView` reference is weak, and ARC
    /// zeroing a weak var does NOT fire `didSet`, so without it the model's KVO-fed
    /// `canGoBack`/`canGoForward` mirrors would freeze at their last values (#546 review).
    /// Defaults to a no-op for callers that don't track the web view.
    var onWebViewDismantled: (WKWebView) -> Void = { _ in }

    func makeNSView(context: Context) -> WKWebView {
        let onVisibleElements: AnglesiteScriptHandler.VisibleElementsHandler? = annotationProvider.map { provider in
            // `provider` is `@MainActor`, so the implicit hop happens at the `update(_:)` call.
            // Captured strongly: the handler is owned by the WKWebView, which is owned by
            // SwiftUI's NSViewRepresentable lifecycle; the provider is owned by SiteWindow's
            // `@State`, which outlives the WKWebView. The closure becomes unreachable when the
            // WKWebView is torn down, releasing the strong reference.
            { @Sendable elements in await provider.update(elements) }
        }
        let handler = AnglesiteScriptHandler(router: router, onVisibleElements: onVisibleElements)
        // `onContextMenu` needs the `WKWebView` to pop the menu up in (`NSMenu.popUp(positioning:at:in:)`),
        // but the handler has to exist before the web view does — it's part of the configuration
        // the web view is constructed from. Resolved the same way `onWebView`/`onWebViewDismantled`
        // resolve their own "needs the view, doesn't exist yet" problem below: a weak capture of
        // `context.coordinator`, whose `webView` is set immediately after construction.
        let wysiwygHandler = wysiwygTransport.map { transport in
            WYSIWYGScriptHandler(transport: transport) { [weak coordinator = context.coordinator] blockId, point in
                Task { @MainActor in
                    guard let webView = coordinator?.webView, let controller = transport as? WYSIWYGCanvasController else { return }
                    let menu = WYSIWYGBlockContextMenu.build(for: blockId, controller: controller)
                    menu.popUp(positioning: nil, at: point, in: webView)
                }
            }
        }
        let configuration = WebViewBridge.localDevConfiguration(handler: handler, wysiwygHandler: wysiwygHandler)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        context.coordinator.webView = webView
        WebViewBridge.applyPreviewDefaults(to: webView)
        if let annotationProvider {
            webView.appEntityUIElementProvider = { [weak annotationProvider] _, hitContext in
                guard let annotationProvider else { return [] }
                return annotationProvider.uiElements(for: hitContext)
            }
        }
        webView.load(URLRequest(url: url))
        context.coordinator.loadedURL = url
        // Stashed on the coordinator because `dismantleNSView` is static — it has no access to
        // this instance's closures at teardown time.
        context.coordinator.onDismantle = onWebViewDismantled
        onWebView(webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onDismantle = onWebViewDismantled
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        webView.load(URLRequest(url: url))
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.onDismantle?(webView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// `@MainActor` + `Sendable`: every access happens on the main actor (SwiftUI calls
    /// `makeNSView`/`updateNSView`/`dismantleNSView` there), so the class is safe to conform
    /// directly rather than needing per-property isolation — same reasoning as
    /// `WYSIWYGCanvasController`'s implicit `WYSIWYGHostTransport: Sendable` conformance. Needed
    /// so `makeNSView`'s `onContextMenu` closure (a `@Sendable` parameter of `WYSIWYGScriptHandler`)
    /// can weakly capture `webView` below without the compiler rejecting the capture.
    @MainActor
    final class Coordinator: Sendable {
        var loadedURL: URL?
        var onDismantle: ((WKWebView) -> Void)?
        /// Set right after `WKWebView(frame:configuration:)` in `makeNSView`, so the
        /// `WYSIWYGScriptHandler`'s `onContextMenu` closure — built *before* the web view exists,
        /// since it's baked into the configuration the web view is constructed from — has
        /// somewhere to find it once a context-menu message actually arrives.
        weak var webView: WKWebView?
    }
}

/// Watches whether the WYSIWYG canvas (#1225) holds real AppKit keyboard focus, so
/// `WYSIWYGCanvasController.hasKeyboardFocus` (Task 11) and `EditorFocusRegistry`'s
/// `.wysiwygCanvas` case (added inert in Task 10 — `FormatCommands`/`EditMenuSkeletonCommands`
/// already read it, nothing wrote it until now) reflect reality.
///
/// Reuses `SentinelView` (`MarkdownTextView.swift`) rather than re-deriving the same mechanism:
/// `PreviewView` wraps a raw `WKWebView` directly as its `NSViewRepresentable.NSViewType` (Task 8
/// mounted the canvas onto the existing preview pane, not a purpose-built SwiftUI-native host), so
/// a plain `.focused($binding)` has nothing AppKit-focusable of SwiftUI's own to bind to — the
/// same "raw AppKit view embedded via NSViewRepresentable" shape `SentinelView` was already built
/// to solve for `NativeTextViewWrapper` (see that file's header comment for why `.focused` /
/// documented `NSText` notifications were tried and dropped in favor of `NSWindow.firstResponder`
/// KVO + geometry containment). Placed as a `.background` on `PreviewView` in
/// `SiteWindow.previewPane(for:)` — sharing that exact frame is what makes the plain geometry
/// containment check correct without needing a `webView` reference here at all.
private struct WYSIWYGCanvasFocusSentinel: NSViewRepresentable {
    let canvas: WYSIWYGCanvasController

    func makeNSView(context: Context) -> SentinelView {
        let view = SentinelView()
        view.onFocusChange = { [weak canvas] focused in
            guard let canvas else { return }
            canvas.hasKeyboardFocus = focused
            let token = ObjectIdentifier(canvas)
            if focused {
                EditorFocusRegistry.shared.activate(.wysiwygCanvas(Weak(canvas)), token: token)
            } else {
                EditorFocusRegistry.shared.resign(token: token)
            }
        }
        return view
    }

    func updateNSView(_ nsView: SentinelView, context: Context) {}

    static func dismantleNSView(_ nsView: SentinelView, coordinator: ()) {
        nsView.prepareForRemoval()
    }
}

/// `SiteWindow.previewPane(for:)`'s hook for mounting `WYSIWYGCanvasFocusSentinel` — kept here
/// (rather than exposing the private type directly) so the sentinel's implementation stays a
/// `PreviewView.swift`-local concern, mirroring `EditorFocusSentinel`'s privacy in
/// `MarkdownTextView.swift`.
extension View {
    @ViewBuilder
    func wysiwygCanvasFocusTracking(_ canvas: WYSIWYGCanvasController?) -> some View {
        if let canvas {
            background(WYSIWYGCanvasFocusSentinel(canvas: canvas))
        } else {
            self
        }
    }
}
