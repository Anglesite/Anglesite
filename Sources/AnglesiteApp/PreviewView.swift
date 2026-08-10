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

    /// DOM `clientX`/`clientY` (top-left origin) → AppKit view space (bottom-left origin, since
    /// `WKWebView` is non-flipped) for `NSMenu.popUp(positioning:at:in:)`. A pure function so it's
    /// testable without a real `WKWebView` (#1225 final-review fix wave, Finding 3).
    static func convertContextMenuPoint(_ domPoint: CGPoint, viewHeight: CGFloat) -> CGPoint {
        CGPoint(x: domPoint.x, y: viewHeight - domPoint.y)
    }

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
        // `wysiwygTransport` is always a `WYSIWYGCanvasController` in production
        // (`PreviewModel.wysiwygCanvas`'s concrete type); casting once here — rather than inside
        // the handler closure on every message — is what lets `updateNSView` below compare "is
        // this the same controller as last render" by plain reference identity.
        let wysiwygController = wysiwygTransport as? WYSIWYGCanvasController
        // `onContextMenu` needs the `WKWebView` to pop the menu up in (`NSMenu.popUp(positioning:at:in:)`),
        // but the handler has to exist before the web view does — it's part of the configuration
        // the web view is constructed from. Resolved the same way `onWebView`/`onWebViewDismantled`
        // resolve their own "needs the view, doesn't exist yet" problem below: a weak capture of
        // `context.coordinator`, whose `webView` is set immediately after construction.
        let wysiwygHandler = wysiwygController.map { makeWYSIWYGHandler(for: $0, coordinator: context.coordinator) }
        let configuration = WebViewBridge.localDevConfiguration(handler: handler, wysiwygHandler: wysiwygHandler)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        context.coordinator.webView = webView
        context.coordinator.wysiwygController = wysiwygController
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
        // Best-effort — mirrors `PreviewModel.enterEditMode`'s own call: covers the case where
        // this `PreviewView` (and its web view) is being built fresh while edit mode is already on
        // (a dev-server restart mid-edit re-creates the whole NSView, see the `.ready` branch in
        // `SiteWindow.previewPane(for:)`). No-op if the page hasn't loaded yet — see
        // `WYSIWYGCanvasController.mountEngine()`'s doc comment.
        wysiwygController?.mountEngine()
        return webView
    }

    /// Wraps `controller` as the WYSIWYG `WKScriptMessageHandler` — shared by `makeNSView` (initial
    /// registration) and `updateNSView` (registration on an edit-mode-off → on transition, #1225
    /// final-review fix wave, Finding 6) so the two don't drift.
    private func makeWYSIWYGHandler(for controller: WYSIWYGCanvasController, coordinator: Coordinator) -> WYSIWYGScriptHandler {
        WYSIWYGScriptHandler(transport: controller) { [weak coordinator] blockId, point in
            Task { @MainActor in
                guard let webView = coordinator?.webView else { return }
                let menu = WYSIWYGBlockContextMenu.build(for: blockId, controller: controller)
                // `point` is the DOM `contextmenu` event's `clientX`/`clientY` (top-left origin);
                // `WKWebView` is a non-flipped AppKit view (bottom-left origin), so popping the
                // menu up at the raw DOM point mirrors it vertically — near the top of the page it
                // appeared near the bottom of the view (#1225 final-review fix wave, Finding 3).
                let converted = Self.convertContextMenuPoint(point, viewHeight: webView.bounds.height)
                menu.popUp(positioning: nil, at: converted, in: webView)
            }
        }
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onDismantle = onWebViewDismantled

        // `makeNSView` only ever registers the WYSIWYG handler / mounts the JS engine once, at
        // construction — a `PreviewView` whose `wysiwygTransport` flips from nil to non-nil (Site ▸
        // Edit Page toggled on against an already-built preview pane) or non-nil to nil (toggled
        // off) re-renders through `updateNSView`, not `makeNSView`, since SwiftUI reuses the
        // existing `WKWebView` rather than tearing it down. Without this block the handler/engine
        // stayed permanently out of sync with `isEditModeEnabled` after the very first toggle
        // (#1225 final-review fix wave, Finding 6 — the mirror-image gap to Finding 1's "never
        // mounted at all"). Compared by reference identity via the coordinator's stashed
        // controller, matching `Coordinator`'s other stored-state pattern (`loadedURL`).
        let newController = wysiwygTransport as? WYSIWYGCanvasController
        if newController !== context.coordinator.wysiwygController {
            if let previous = context.coordinator.wysiwygController {
                webView.configuration.userContentController.removeScriptMessageHandler(forName: WebViewBridge.wysiwygScriptMessageNamespace)
                previous.unmountEngine()
            }
            context.coordinator.wysiwygController = newController
            if let newController {
                let handler = makeWYSIWYGHandler(for: newController, coordinator: context.coordinator)
                webView.configuration.userContentController.add(handler, name: WebViewBridge.wysiwygScriptMessageNamespace)
                newController.mountEngine()
            }
        }

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
        /// The controller last registered/mounted against `webView` — `updateNSView` diffs this
        /// against the current `wysiwygTransport` (by reference identity) to detect an edit-mode
        /// on/off transition (#1225 final-review fix wave, Finding 6). Strong: unlike `webView`,
        /// nothing else on this side keeps the controller alive once edit mode is toggled off, and
        /// `updateNSView` needs it after `wysiwygTransport` has already gone `nil` in order to call
        /// `unmountEngine()`/`removeScriptMessageHandler(forName:)` on the right instance.
        var wysiwygController: WYSIWYGCanvasController?
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
