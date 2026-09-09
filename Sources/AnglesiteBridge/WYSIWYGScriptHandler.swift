import Foundation
import CoreGraphics
import WebKit
import AnglesiteCore
import AnglesiteBridgeCore

/// `WKScriptMessageHandler` adapter for the `wysiwyg` namespace — the WKWebView-specific thin
/// layer over `WYSIWYGOpsDispatcher`, and the only script-message handler the app registers on a
/// preview or Component Editor canvas since #1957 retired the overlay's `anglesite` namespace.
/// All the message schema, decoding, and routing live in the portable dispatcher; this class's
/// own job is exactly what `WKScriptMessage` requires: unwrap `message.body`/`.webView`, evaluate
/// reply scripts back into the page, and log the outcomes that mean broken native wiring.
public final class WYSIWYGScriptHandler: NSObject, WKScriptMessageHandler {
    /// The mounted block engine's transport, or `nil` on a web view that hosts only the page
    /// bridge (the Component Editor's harness canvas; a preview whose canvas is off).
    private let transport: (any WYSIWYGHostTransport)?
    private let handlers: WYSIWYGOpsDispatcher.Handlers
    private let logCenter: LogCenter
    private let onContextMenu: (@Sendable (BlockId, CGPoint) -> Void)?
    private let onSelectionChanged: (@Sendable (BlockId?) -> Void)?
    private let onFocusInspectorRequested: (@Sendable (WYSIWYGOpsDispatcher.FocusDirection, BlockId) -> Void)?

    /// - Parameters:
    ///   - transport: Applies the engine's `submit-op` envelopes; `nil` when no block engine is
    ///     mounted on this web view (a `submit-op` is then rejected and logged).
    ///   - handlers: The optional per-message consumers — writing help, image replacement, and
    ///     the page-bridge reports (Siri visible elements, Component Editor canvas selection +
    ///     computed styles, Effects/experiment picks). A report whose consumer is absent is
    ///     logged as dropped; see `WYSIWYGOpsDispatcher.Handlers`.
    ///   - logCenter: Destination for rejection/drop diagnostics — injectable for tests.
    ///   - onContextMenu: Presents the host-native block context menu (spec §8.1).
    ///   - onSelectionChanged: Mirrors the engine's selection into the native controller.
    ///   - onFocusInspectorRequested: Moves AppKit focus into the native inspector (#1616).
    public init(
        transport: (any WYSIWYGHostTransport)?,
        handlers: WYSIWYGOpsDispatcher.Handlers = WYSIWYGOpsDispatcher.Handlers(),
        logCenter: LogCenter = .shared,
        onContextMenu: (@Sendable (BlockId, CGPoint) -> Void)? = nil,
        onSelectionChanged: (@Sendable (BlockId?) -> Void)? = nil,
        onFocusInspectorRequested: (@Sendable (WYSIWYGOpsDispatcher.FocusDirection, BlockId) -> Void)? = nil
    ) {
        self.transport = transport
        self.handlers = handlers
        self.logCenter = logCenter
        self.onContextMenu = onContextMenu
        self.onSelectionChanged = onSelectionChanged
        self.onFocusInspectorRequested = onFocusInspectorRequested
        super.init()
    }

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == WYSIWYGOpsDispatcher.scriptMessageNamespace else { return }
        let body = message.body
        let webView = message.webView
        let transport = self.transport
        let handlers = self.handlers
        let logCenter = self.logCenter
        let onContextMenu = self.onContextMenu
        let onSelectionChanged = self.onSelectionChanged
        let onFocusInspectorRequested = self.onFocusInspectorRequested
        Task {
            switch await WYSIWYGOpsDispatcher.dispatch(body: body, via: transport, handlers: handlers) {
            case .contextMenu(let blockId, let point):
                onContextMenu?(blockId, CGPoint(x: point.x, y: point.y))
            case .selectionChanged(let blockId):
                onSelectionChanged?(blockId)
            case .focusInspector(let direction, let blockId):
                onFocusInspectorRequested?(direction, blockId)
            case .opResult(let requestId, let result):
                await Self.reply(
                    webView: webView, callback: "_handleOpResult", requestId: requestId, payload: result,
                    describing: "submit-op", logCenter: logCenter)
            case .writingHelpReply(let requestId, let outcome):
                await Self.reply(
                    webView: webView, callback: "_handleWritingHelpReply", requestId: requestId, payload: outcome,
                    describing: "writing-help-request", logCenter: logCenter)
            case .imageReplaceReply(let requestId, let reply):
                await Self.reply(
                    webView: webView, callback: "_handleImageReplaceReply", requestId: requestId, payload: reply,
                    describing: "replace-image", logCenter: logCenter)
            case .visibleElementsHandled, .canvasSelectionHandled, .computedStylesHandled,
                 .placementPickHandled, .goalElementPickHandled:
                return
            case .visibleElementsDropped:
                // Production wiring (`PreviewView` with an annotationProvider) always installs
                // one; reaching here implies a regression. Log so the wiring failure is
                // observable rather than silently swallowing every Siri report.
                await logCenter.append(
                    source: "wysiwyg-bridge", stream: .stderr,
                    text: "visible-elements message dropped: no handler installed (provider not threaded through PreviewView?)")
            case .canvasSelectionDropped:
                await logCenter.append(source: "wysiwyg-bridge", stream: .stderr, text: "canvas-selection message dropped: no handler installed")
            case .computedStylesDropped:
                await logCenter.append(source: "wysiwyg-bridge", stream: .stderr, text: "computed-styles message dropped: no handler installed")
            case .placementPickDropped:
                await logCenter.append(source: "wysiwyg-bridge", stream: .stderr, text: "pick-placement message dropped: no handler installed")
            case .goalElementPickDropped:
                await logCenter.append(source: "wysiwyg-bridge", stream: .stderr, text: "pick-goal-element message dropped: no handler installed")
            case .rejected(let reason):
                await logCenter.append(source: "wysiwyg-bridge", stream: .stderr, text: "rejected message: \(reason)")
            }
        }
    }

    /// Evaluates `window.__anglesiteWysiwygHost?.<callback>?.(<requestId>, <payload>)` back into
    /// the page — the one reply shape every request/reply message on this bridge shares.
    private static func reply(
        webView: WKWebView?, callback: String, requestId: String, payload: some Encodable,
        describing messageName: String, logCenter: LogCenter
    ) async {
        guard let webView else {
            await logCenter.append(source: "wysiwyg-bridge", stream: .stderr, text: "webView deallocated before \(messageName) reply for id=\(requestId)")
            return
        }
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8),
              let requestIdData = try? JSONEncoder().encode(requestId),
              let requestIdJSON = String(data: requestIdData, encoding: .utf8)
        else {
            await logCenter.append(source: "wysiwyg-bridge", stream: .stderr, text: "failed to encode \(messageName) reply for id=\(requestId)")
            return
        }
        let script = "window.__anglesiteWysiwygHost?.\(callback)?.(\(requestIdJSON), \(json))"
        await MainActor.run { webView.evaluateJavaScript(script) }
    }
}
