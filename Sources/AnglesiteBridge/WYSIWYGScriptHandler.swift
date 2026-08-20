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

    public init(
        transport: any WYSIWYGHostTransport, logCenter: LogCenter = .shared,
        onContextMenu: (@Sendable (BlockId, CGPoint) -> Void)? = nil,
        onSelectionChanged: (@Sendable (BlockId?) -> Void)? = nil
    ) {
        self.transport = transport
        self.logCenter = logCenter
        self.onContextMenu = onContextMenu
        self.onSelectionChanged = onSelectionChanged
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
        Task {
            switch await WYSIWYGOpsDispatcher.dispatch(body: body, via: transport) {
            case .contextMenu(let blockId, let point):
                onContextMenu?(blockId, CGPoint(x: point.x, y: point.y))
            case .selectionChanged(let blockId):
                onSelectionChanged?(blockId)
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
            case .rejected(let reason):
                await logCenter.append(source: "wysiwyg-bridge", stream: .stderr, text: "rejected message: \(reason)")
            }
        }
    }
}
