import Foundation
import Adwaita
import AnglesiteCore
import AnglesiteBridgeCore
import CWebKitGTK

/// WebKitGTK adapter for the preview + edit-overlay bridge — the Linux twin of
/// `AnglesiteBridge`'s WKWebView stack (`WebViewBridge` + `AnglesiteScriptHandler`). All
/// message schema, decoding, and routing live in the portable `AnglesiteMessageDispatcher`;
/// this widget's only jobs are the WebKitGTK equivalents of the WKWebView adapter's:
///
/// - inject the compiled overlay bundle (`WebKitUserScript` at document-end, all frames —
///   mirroring `WebViewBridge.makeOverlayUserScript`),
/// - register the shared `anglesite` script-message namespace on the user-content manager and
///   forward each `JSCValue` body (via its JSON projection) to the dispatcher,
/// - evaluate apply-edit replies back into the page as `window.anglesite?._handleReply?.(...)`.
///
/// WebKitGTK's `WebKitUserContentManager` script-message API maps 1:1 onto the
/// `WKScriptMessageHandler` pattern (port design §6), so the shape here deliberately follows
/// `AnglesiteScriptHandler.userContentController(_:didReceive:)`.
struct PreviewWebView: AdwaitaWidget {
    /// The dev-server URL to display. Loaded on first render and re-loaded whenever it changes.
    var url: String
    /// Routes decoded `apply-edit` messages (production: `MCPApplyEditRouter` over the site's
    /// MCP client).
    var router: any EditRouter
    /// The overlay JS to inject, or `nil` to preview without edit affordances (non-fatal,
    /// matching the WKWebView adapter when the bundle wasn't produced).
    var overlaySource: String?
    var logCenter: LogCenter = .shared

    func container<Data>(data: WidgetData, type: Data.Type) -> ViewStorage where Data: ViewRenderData {
        guard let widget = webkit_web_view_new() else {
            // webkit_web_view_new is infallible in practice (GObject construction aborts on
            // OOM before returning nil); this guard is for the type system.
            return ViewStorage(nil)
        }
        let storage = ViewStorage(OpaquePointer(widget))
        // GObject downcast (GtkWidget* → WebKitWebView*): the parent instance is the first
        // member, so rebinding the same address is the C-idiomatic WEBKIT_WEB_VIEW() cast.
        let webView = UnsafeMutableRawPointer(widget).assumingMemoryBound(to: WebKitWebView.self)

        // Inspector parity with `WebViewBridge.applyPreviewDefaults` (`isInspectable = true`):
        // right-click → Inspect Element in every build configuration.
        webkit_settings_set_enable_developer_extras(webkit_web_view_get_settings(webView), 1)

        guard let ucm = webkit_web_view_get_user_content_manager(webView) else { return storage }
        if let overlaySource {
            let script = webkit_user_script_new(
                overlaySource,
                WEBKIT_USER_CONTENT_INJECT_ALL_FRAMES,
                WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_END,
                nil,
                nil
            )
            webkit_user_content_manager_add_script(ucm, script)
            webkit_user_script_unref(script)
        }

        let namespace = AnglesiteMessageDispatcher.scriptMessageNamespace
        webkit_user_content_manager_register_script_message_handler(ucm, namespace, nil)
        let router = router
        let logCenter = logCenter
        // The reply hops threads (GTK signal → Swift concurrency → GTK idle), so the webview
        // travels as a bit pattern rather than a non-Sendable pointer. Lifetime: the webview
        // lives for the window's (and app's) whole run in this one-window shell, so the idle
        // callback can't outlive it.
        let webViewBits = UInt(bitPattern: UnsafeMutableRawPointer(webView))
        // `.oneArg`: the signal's C signature is (manager, JSCValue*, user_data) — one
        // argument between the instance and the closure data, delivered as `args[0]`.
        // (adwaita-swift's `argCount:` spelling of the same thing was removed upstream in
        // da5aad1, the revision bump for #1760.)
        storage.connectSignal(
            name: "script-message-received::\(namespace)",
            type: .oneArg,
            pointer: ucm
        ) { (args: [Any]) -> Void in
            guard let raw = args.first as? UnsafeRawPointer else {
                // A marshaling mismatch (e.g. Adwaita boxing the signal argument differently)
                // would otherwise be a completely silent dead bridge — logs are sacred.
                let got: String
                if let first = args.first { got = String(describing: Swift.type(of: first)) } else { got = "nothing" }
                Task { await logCenter.append(source: "bridge-gtk", stream: .stderr, text: "script-message signal argument was not a pointer (got \(got))") }
                return
            }
            guard let jsonC = jsc_value_to_json(OpaquePointer(raw), 0) else {
                Task { await logCenter.append(source: "bridge-gtk", stream: .stderr, text: "jsc_value_to_json returned NULL for a script message") }
                return
            }
            let json = String(cString: jsonC)
            g_free(jsonC)
            guard let data = json.data(using: .utf8),
                  let body = try? JSONSerialization.jsonObject(with: data)
            else {
                Task { await logCenter.append(source: "bridge-gtk", stream: .stderr, text: "undecodable script message: \(json)") }
                return
            }
            Task {
                switch await AnglesiteMessageDispatcher.dispatch(body: body, via: router) {
                case .editReply(let reply):
                    guard let encoded = try? JSONEncoder().encode(reply),
                          let replyJSON = String(data: encoded, encoding: .utf8)
                    else {
                        await logCenter.append(source: "bridge-gtk", stream: .stderr, text: "failed to encode reply for id=\(reply.id)")
                        return
                    }
                    let script = "window.anglesite?._handleReply?.(\(replyJSON))"
                    Idle {
                        let webView = UnsafeMutableRawPointer(bitPattern: webViewBits)?
                            .assumingMemoryBound(to: WebKitWebView.self)
                        webkit_web_view_evaluate_javascript(webView, script, -1, nil, nil, nil, nil, nil)
                    }
                case .visibleElementsHandled, .canvasSelectionHandled, .computedStylesHandled, .placementPickHandled, .goalElementPickHandled:
                    return
                case .visibleElementsDropped, .canvasSelectionDropped, .computedStylesDropped, .placementPickDropped, .goalElementPickDropped:
                    // Expected in the MVP shell: no annotation/canvas/placement consumers are
                    // wired yet (they arrive with the component editor / Effects gallery), so
                    // these land silently — unlike the macOS adapter, where a drop means broken
                    // wiring and is logged.
                    return
                case .rejected(let reason):
                    await logCenter.append(source: "bridge-gtk", stream: .stderr, text: "rejected message: \(reason)")
                }
            }
        }

        return storage
    }

    func update<Data>(_ storage: ViewStorage, data: WidgetData, updateProperties: Bool, type: Data.Type) where Data: ViewRenderData {
        guard updateProperties else { return }
        if !url.isEmpty, storage.fields["loaded-url"] as? String != url, let pointer = storage.opaquePointer {
            storage.fields["loaded-url"] = url
            webkit_web_view_load_uri(UnsafeMutablePointer<WebKitWebView>(pointer), url)
        }
        storage.previousState = self
    }
}
