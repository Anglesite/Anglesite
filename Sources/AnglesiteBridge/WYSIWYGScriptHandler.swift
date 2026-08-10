import Foundation
import WebKit
import AnglesiteCore
import AnglesiteBridgeCore

/// `WKScriptMessageHandler` adapter for the `wysiwyg` namespace — the WKWebView-specific thin
/// layer over `WYSIWYGOpsDispatcher`, mirroring `AnglesiteScriptHandler`'s split.
public final class WYSIWYGScriptHandler: NSObject, WKScriptMessageHandler {
    private let transport: any WYSIWYGHostTransport
    private let logCenter: LogCenter

    public init(transport: any WYSIWYGHostTransport, logCenter: LogCenter = .shared) {
        self.transport = transport
        self.logCenter = logCenter
        super.init()
    }

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == WYSIWYGOpsDispatcher.scriptMessageNamespace else { return }
        let body = message.body
        let webView = message.webView
        let transport = self.transport
        let logCenter = self.logCenter
        Task {
            switch await WYSIWYGOpsDispatcher.dispatch(body: body, via: transport) {
            case .opResult(let requestId, let result):
                guard let webView else { return }
                guard let data = try? JSONEncoder().encode(result),
                      let json = String(data: data, encoding: .utf8)
                else {
                    await logCenter.append(source: "wysiwyg-bridge", stream: .stderr, text: "failed to encode OpResult for id=\(requestId)")
                    return
                }
                guard let requestIdData = try? JSONEncoder().encode(requestId),
                      let requestIdJSON = String(data: requestIdData, encoding: .utf8)
                else { return }
                let script = "window.__anglesiteWysiwygHost?._handleOpResult?.(\(requestIdJSON), \(json))"
                await MainActor.run { webView.evaluateJavaScript(script) }
            case .rejected(let reason):
                await logCenter.append(source: "wysiwyg-bridge", stream: .stderr, text: "rejected message: \(reason)")
            }
        }
    }
}
