import Foundation
import CoreGraphics
import WebKit
import AnglesiteCore
import AnglesiteBridgeCore

/// `WKScriptMessageHandler` adapter for the `wysiwyg` namespace — the WKWebView-specific thin
/// layer over `WYSIWYGOpsDispatcher`, mirroring `AnglesiteScriptHandler`'s split.
public final class WYSIWYGScriptHandler: NSObject, WKScriptMessageHandler {
    private let transport: any WYSIWYGHostTransport
    private let logCenter: LogCenter
    private let onContextMenu: (@Sendable (BlockId, CGPoint) -> Void)?
    private let onSelectionChanged: (@Sendable (BlockId?) -> Void)?
    private let onFocusInspectorRequested: (@Sendable (WYSIWYGOpsDispatcher.FocusDirection, BlockId) -> Void)?
    /// Answers a `writing-help-request` message with a rewrite outcome (#1227 PR 2). `nil` when
    /// the app layer has no site context to build a `WritingHelpAssisting` call with (e.g. outside
    /// edit mode) — `WYSIWYGOpsDispatcher.dispatch` already falls back to `.unavailable` on its own
    /// when `writingHelp` is nil, so this handler doesn't need its own fallback branch.
    private let onWritingHelpRequested: (@Sendable (_ text: String, _ instruction: String) async -> WritingHelpOutcome)?

    public init(
        transport: any WYSIWYGHostTransport, logCenter: LogCenter = .shared,
        onContextMenu: (@Sendable (BlockId, CGPoint) -> Void)? = nil,
        onSelectionChanged: (@Sendable (BlockId?) -> Void)? = nil,
        onFocusInspectorRequested: (@Sendable (WYSIWYGOpsDispatcher.FocusDirection, BlockId) -> Void)? = nil,
        onWritingHelpRequested: (@Sendable (_ text: String, _ instruction: String) async -> WritingHelpOutcome)? = nil
    ) {
        self.transport = transport
        self.logCenter = logCenter
        self.onContextMenu = onContextMenu
        self.onSelectionChanged = onSelectionChanged
        self.onFocusInspectorRequested = onFocusInspectorRequested
        self.onWritingHelpRequested = onWritingHelpRequested
        super.init()
    }

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == WYSIWYGOpsDispatcher.scriptMessageNamespace else { return }
        let body = message.body
        let webView = message.webView
        let transport = self.transport
        let logCenter = self.logCenter
        let onContextMenu = self.onContextMenu
        let onSelectionChanged = self.onSelectionChanged
        let onFocusInspectorRequested = self.onFocusInspectorRequested
        let onWritingHelpRequested = self.onWritingHelpRequested
        Task {
            switch await WYSIWYGOpsDispatcher.dispatch(body: body, via: transport, writingHelp: onWritingHelpRequested) {
            case .contextMenu(let blockId, let point):
                onContextMenu?(blockId, CGPoint(x: point.x, y: point.y))
            case .selectionChanged(let blockId):
                onSelectionChanged?(blockId)
            case .focusInspector(let direction, let blockId):
                onFocusInspectorRequested?(direction, blockId)
            case .opResult(let requestId, let result):
                guard let webView else {
                    await logCenter.append(source: "wysiwyg-bridge", stream: .stderr, text: "webView deallocated before submit-op reply for id=\(requestId)")
                    return
                }
                guard let data = try? JSONEncoder().encode(result),
                      let json = String(data: data, encoding: .utf8)
                else {
                    await logCenter.append(source: "wysiwyg-bridge", stream: .stderr, text: "failed to encode OpResult for id=\(requestId)")
                    return
                }
                guard let requestIdData = try? JSONEncoder().encode(requestId),
                      let requestIdJSON = String(data: requestIdData, encoding: .utf8)
                else {
                    await logCenter.append(source: "wysiwyg-bridge", stream: .stderr, text: "failed to encode requestId for id=\(requestId)")
                    return
                }
                let script = "window.__anglesiteWysiwygHost?._handleOpResult?.(\(requestIdJSON), \(json))"
                await MainActor.run { webView.evaluateJavaScript(script) }
            case .writingHelpReply(let requestId, let outcome):
                guard let webView else {
                    await logCenter.append(source: "wysiwyg-bridge", stream: .stderr, text: "webView deallocated before writing-help-request reply for id=\(requestId)")
                    return
                }
                guard let data = try? JSONEncoder().encode(outcome),
                      let json = String(data: data, encoding: .utf8)
                else {
                    await logCenter.append(source: "wysiwyg-bridge", stream: .stderr, text: "failed to encode WritingHelpOutcome for id=\(requestId)")
                    return
                }
                guard let requestIdData = try? JSONEncoder().encode(requestId),
                      let requestIdJSON = String(data: requestIdData, encoding: .utf8)
                else {
                    await logCenter.append(source: "wysiwyg-bridge", stream: .stderr, text: "failed to encode requestId for id=\(requestId)")
                    return
                }
                let script = "window.__anglesiteWysiwygHost?._handleWritingHelpReply?.(\(requestIdJSON), \(json))"
                await MainActor.run { webView.evaluateJavaScript(script) }
            case .rejected(let reason):
                await logCenter.append(source: "wysiwyg-bridge", stream: .stderr, text: "rejected message: \(reason)")
            }
        }
    }
}
