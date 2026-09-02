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

    /// Called with a decoded `anglesite:pick-placement` message when the owner clicks an element
    /// in the live preview while the Effects gallery's click-to-place overlay is armed (#768).
    /// Forwarded straight into `AnglesiteScriptHandler`'s own `onPlacementPick` — see that type's
    /// doc comment. Defaults to a no-op for callers (e.g. tests) that don't need it.
    var onPlacementPick: AnglesiteScriptHandler.PlacementPickHandler = { _ in }

    /// Called with a decoded `anglesite:pick-goal-element` message when the owner clicks an
    /// element in the live preview while the experiment configure step's goal picker is armed
    /// (#1518). Forwarded straight into `AnglesiteScriptHandler`'s own `onGoalElementPick` — see
    /// that type's doc comment. Defaults to a no-op for callers (e.g. tests) that don't need it.
    var onGoalElementPick: AnglesiteScriptHandler.GoalElementPickHandler = { _ in }

    /// Called every time a navigation finishes in the preview — an HMR reload, a route change, ⌘R.
    /// The overlay's placement-pick mode is closure-local JS state that a real navigation wipes
    /// (the `WKUserScript` re-runs and comes back inactive), so anything holding "we're waiting for
    /// a placement click" on the native side has to hear about it or it waits forever on a
    /// listener that no longer exists (#768 final review, Finding 8).
    var onPreviewNavigated: () -> Void = {}

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
        let handler = AnglesiteScriptHandler(
            router: router, onVisibleElements: onVisibleElements,
            onPlacementPick: onPlacementPick, onGoalElementPick: onGoalElementPick)
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
        // The `WKNavigationDelegate` below is what actually mounts the JS engine once the page
        // (and thus the `WKUserScript` that defines `window.__anglesiteWysiwygMount`) has really
        // finished loading — see `Coordinator.webView(_:didFinish:)`'s doc comment (#1225
        // final-review round 2, Finding B). Assigning it before `load(_:)` below means it's live
        // for this very first navigation too, not just later ones.
        webView.navigationDelegate = context.coordinator
        context.coordinator.onNavigated = onPreviewNavigated
        webView.load(URLRequest(url: url))
        context.coordinator.loadedURL = url
        // Stashed on the coordinator because `dismantleNSView` is static — it has no access to
        // this instance's closures at teardown time.
        context.coordinator.onDismantle = onWebViewDismantled
        onWebView(webView)
        return webView
    }

    /// Wraps `controller` as the WYSIWYG `WKScriptMessageHandler` — shared by `makeNSView` (initial
    /// registration) and `updateNSView` (registration on an edit-mode-off → on transition, #1225
    /// final-review fix wave, Finding 6) so the two don't drift.
    private func makeWYSIWYGHandler(for controller: WYSIWYGCanvasController, coordinator: Coordinator) -> WYSIWYGScriptHandler {
        WYSIWYGScriptHandler(
            transport: controller,
            onContextMenu: { [weak coordinator] blockId, point in
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
            },
            // Each `selection-changed` bridge message is handled by its own unstructured `Task`
            // (`WYSIWYGScriptHandler`), with no ordering guarantee relative to other such messages —
            // compounded here by this closure's own additional `Task` hop to `MainActor`. Under rapid
            // arrow-key auto-repeat this could theoretically let two in-flight messages complete out
            // of order, briefly landing `selectedBlockId` on a stale block until the next
            // selection-changed message corrects it. Accepted for now per the #1589 final review — a
            // real fix needs a sequencing mechanism (e.g. a monotonic version counter) across the
            // JS↔native bridge, which is out of scope for this fix wave.
            onSelectionChanged: { [weak controller] blockId in
                Task { @MainActor in
                    controller?.selectedBlockId = blockId
                }
            },
            // `blockId` rides along with the request rather than trusting `controller
            // .selectedBlockId` to already have caught up: that's set by the separate
            // `selection-changed` message above, posted and dispatched independently (same
            // no-ordering-guarantee caveat that closure's own doc comment states) — a fast
            // select-then-Tab could otherwise land this request while the selection mirror is
            // still stale. Setting both here, in the same MainActor hop, keeps them consistent
            // regardless of which order the two messages' own `Task`s actually settle in.
            onFocusInspectorRequested: { [weak controller] direction, blockId in
                Task { @MainActor in
                    controller?.selectedBlockId = blockId
                    controller?.inspectorFocusRequest = direction
                }
            }
        )
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onDismantle = onWebViewDismantled
        context.coordinator.onNavigated = onPreviewNavigated

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
    ///
    /// Subclasses `NSObject` (rather than a plain Swift class) because `WKNavigationDelegate` is
    /// an `@objc` protocol — `WKWebView.navigationDelegate` requires its target to be an
    /// `NSObject`. `webView.navigationDelegate` holds it weakly; SwiftUI's own `Context` is what
    /// keeps this instance alive for the represented view's lifetime, same as every other
    /// `NSViewRepresentable.Coordinator`.
    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, Sendable {
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
        /// `unmountEngine()`/`removeScriptMessageHandler(forName:)` on the right instance. Also
        /// what `webView(_:didFinish:)` below reads to decide whether a finished navigation should
        /// (re)mount the JS engine.
        var wysiwygController: WYSIWYGCanvasController?

        /// Mounts the JS engine once a navigation has actually finished — the single reliable
        /// mount point (#1225 final-review round 2, Finding B). Every other `mountEngine()` call
        /// site in this file/`SiteWindow.swift`/`PreviewModel.swift` fires synchronously right
        /// after `webView.load(...)` is dispatched, before the page (and the `atDocumentEnd`
        /// `WKUserScript` that defines `window.__anglesiteWysiwygMount`) has actually loaded — so
        /// those calls were silent no-ops except in the one case where the page was *already*
        /// fully loaded when the toggle happened (`PreviewModel.enterEditMode`'s own call,
        /// `updateNSView`'s edit-mode-transition call). This delegate method is what makes the
        /// *other* orderings work: the initial load (including when edit mode is already on
        /// because this whole `PreviewView`/`WKWebView` was just rebuilt, e.g. a dev-server
        /// restart mid-edit), and every later reload/navigation while edit mode stays on — a
        /// route change (`updateNSView`'s own `webView.load(...)` path) or ⌘R
        /// (`PreviewModel.reloadPreview()`) both silently killed the mounted JS engine before this
        /// fix, since a real navigation discards all page-injected JS state; only the native side's
        /// `isEditModeEnabled` kept reading "on".
        ///
        /// No-op when edit mode is currently off (`wysiwygController` nil) — same guard every
        /// other `mountEngine()` call site uses. Safe against the double-mount this could
        /// otherwise cause when a navigation-driven call races one of the toggle-transition call
        /// sites above (e.g. the page finishes loading in the same beat the owner toggles edit
        /// mode on): `mount.ts`'s `mount()` now disposes any already-mounted engine first, making
        /// repeat calls idempotent rather than stacking two live engine instances on one page.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            wysiwygController?.mountEngine()
            onNavigated?()
        }

        /// Set from `makeNSView`/`updateNSView` (the represented view's `onPreviewNavigated`), so
        /// a finished navigation can tell the native side that all page-injected JS state — the
        /// overlay's placement-pick mode included — has just been discarded.
        var onNavigated: (() -> Void)?
    }
}

/// Structural insertion target for a palette drop, decoded from the mounted engine's
/// `window.__anglesiteWysiwygMount.dropTargetAt` (Task 10) — matches its JS return shape.
struct WYSIWYGDropTargetPayload: Decodable {
    let parentId: String
    let slot: String
    let index: Int
}

/// Resolves a screen location to a structural insertion target via the mounted engine's
/// `dropTargetAt` (Task 10) — shared by every drop mechanism that lands on the canvas
/// (`performWYSIWYGPaletteDrop`'s palette-row drag, and Task 13's Finder/Photos `.onDrop`) so the
/// JS-evaluate-and-decode step isn't duplicated per call site.
///
/// Every `nil` return logs its reason to `LogCenter` first (the plan's Global Constraints: "no
/// silent failure paths — every bridge rejection/drop logs"). The drop still no-ops for the owner;
/// the point is that "I dragged an image in and nothing happened" is diagnosable from the debug
/// pane rather than invisible inside a `try?`.
@MainActor
func resolveWYSIWYGDropTarget(
    at location: CGPoint, webView: WKWebView, logCenter: LogCenter = .shared
) async -> WYSIWYGDropTargetPayload? {
    let script = "JSON.stringify(window.__anglesiteWysiwygMount?.dropTargetAt?.(\(location.x), \(location.y)) ?? null)"
    let evaluated: Any?
    do {
        evaluated = try await webView.evaluateJavaScript(script)
    } catch {
        await logCenter.append(
            source: WYSIWYGImageAssetIngestor.logSource, stream: .stderr,
            text: "dropTargetAt evaluation failed at (\(location.x), \(location.y)): \(error.localizedDescription)")
        return nil
    }
    // `?? null` above means a page with no mounted engine stringifies to the literal "null" —
    // i.e. a drop landed on the preview while edit mode wasn't actually mounted.
    guard let json = evaluated as? String, let data = json.data(using: .utf8) else {
        await logCenter.append(
            source: WYSIWYGImageAssetIngestor.logSource, stream: .stderr,
            text: "dropTargetAt returned a non-string result — no engine mounted?")
        return nil
    }
    do {
        return try JSONDecoder().decode(WYSIWYGDropTargetPayload.self, from: data)
    } catch {
        await logCenter.append(
            source: WYSIWYGImageAssetIngestor.logSource, stream: .stderr,
            text: "could not decode dropTargetAt payload \(json): \(error.localizedDescription)")
        return nil
    }
}

/// Resolves a palette drop's screen location to a structural insertion target via the mounted
/// engine's `dropTargetAt` (Task 10), then submits the resulting `insertBlock` — the WYSIWYG
/// analog of `ComponentEditorCanvasPane.performCanvasDrop`.
@MainActor
func performWYSIWYGPaletteDrop(
    payload: WYSIWYGPaletteDragPayload, location: CGPoint, webView: WKWebView,
    controller: WYSIWYGCanvasController, logCenter: LogCenter = .shared
) async {
    guard let target = await resolveWYSIWYGDropTarget(at: location, webView: webView, logCenter: logCenter) else {
        // `resolveWYSIWYGDropTarget` already logged *why*; this records what was lost with it, so
        // the debug pane names the block the owner was trying to add rather than only the failure.
        await logCenter.append(
            source: WYSIWYGImageAssetIngestor.logSource, stream: .stderr,
            text: "palette drop of \(payload.componentName) discarded — no insertion target")
        return
    }
    let newId = UUID().uuidString
    let content = BlockNodeContent(kind: payload.kind, componentName: payload.componentName, props: [:], slots: [:], sourceSpan: [0, 0])
    await controller.submit(.insertBlock(parentId: target.parentId, slot: target.slot, index: target.index, newId: newId, block: content))
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

/// Attaches `.onDeleteCommand` only while `isActive` (#1423) — `previewPane(for:)`'s canvas delete
/// target and `SiteNavigatorView`'s Navigator delete target both use this, gated on
/// `WYSIWYGCanvasController.hasKeyboardFocus` (this sentinel above), so exactly one
/// `.onDeleteCommand` is ever attached to the window's view tree at a time. Two coexisting
/// `.onDeleteCommand`s made AppKit's Edit ▸ Delete menu-bridging non-deterministic: sometimes the
/// item stayed disabled with a valid Navigator selection, sometimes clicking it invoked the
/// canvas's handler (a silent no-op with no block selected) instead of the Navigator's. Splitting
/// them back into mutually-exclusive attachment restores the single-handler shape #989 already
/// validated as reliable, before the canvas target (#1225 Task 11) started coexisting with it.
///
/// `action` is optional (#1714), mirroring SwiftUI's own `onDeleteCommand(perform:)`: passing
/// `nil` keeps the modifier attached — so the modified view's identity is stable, unlike the
/// `isActive` branch flip, which recreates it — while AppKit validates Edit ▸ Delete as disabled,
/// exactly as if nothing were attached (verified live on macOS 27 with a focused `List`: non-nil
/// → enabled, nil → disabled, selection preserved across the flip). So `isActive` is the
/// *which surface owns the command* gate (focus), and `nil` the *does the current selection
/// support it* gate (`SiteNavigatorModel.deletableSelection()`).
extension View {
    @ViewBuilder
    func onDeleteCommand(active isActive: Bool, perform action: (() -> Void)?) -> some View {
        if isActive {
            onDeleteCommand(perform: action)
        } else {
            self
        }
    }
}

/// Attaches `.onCopyCommand` only while `isActive` (#1588 Task 16, reviewed) — same shape as
/// `onDeleteCommand(active:perform:)` above and for the same reason (#989/#1423): the canvas's
/// block-copy target is gated on `WYSIWYGCanvasController.hasKeyboardFocus` rather than added as a
/// second `Commands`-level menu item, so it never contends with AppKit's own default Edit ▸ Copy
/// menu-bridging for whatever else might respond to `copy:` elsewhere in the window.
extension View {
    @ViewBuilder
    func onCopyCommand(active isActive: Bool, perform action: @escaping () -> [NSItemProvider]) -> some View {
        if isActive {
            onCopyCommand(perform: action)
        } else {
            self
        }
    }
}
