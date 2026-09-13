import Foundation
import Adwaita
import AnglesiteCore
import AnglesiteBridgeCore
import CWebKitGTK

/// WebKitGTK adapter for the preview + page bridge — the Linux twin of `AnglesiteBridge`'s
/// WKWebView stack (`WebViewBridge` + `WYSIWYGScriptHandler`). All message schema, decoding,
/// and routing live in the portable `WYSIWYGOpsDispatcher`; this widget's only jobs are the
/// WebKitGTK equivalents of the WKWebView adapter's:
///
/// - inject the compiled engine bundle (`WebKitUserScript` at document-end, all frames —
///   mirroring `WebViewBridge.makeEngineUserScript`),
/// - register the shared `wysiwyg` script-message namespace on the user-content manager and
///   forward each `JSCValue` body (via its JSON projection) to the dispatcher,
/// - evaluate request/reply answers back into the page as
///   `window.__anglesiteWysiwygHost?.<callback>?.(...)`.
///
/// No block engine is mounted here yet — the Mac host's `WYSIWYGCanvasController` is the only
/// host, so this preview is view-only since #1957 retired the click-to-edit overlay; hosting
/// the block editor in the GTK shell is the cross-platform port's job (#571). The dispatcher
/// therefore runs with no transport, and the page bridge's reports land silently until the
/// shell grows consumers for them.
///
/// WebKitGTK's `WebKitUserContentManager` script-message API maps 1:1 onto the
/// `WKScriptMessageHandler` pattern (port design §6), so the shape here deliberately follows
/// `WYSIWYGScriptHandler.userContentController(_:didReceive:)`.
struct PreviewWebView: AdwaitaWidget {
    /// The dev-server URL to display. Loaded on first render and re-loaded whenever it changes.
    var url: String
    /// The engine JS to inject, or `nil` to preview without it (non-fatal, matching the
    /// WKWebView adapter when the bundle wasn't produced).
    var engineSource: String?
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
        if let engineSource {
            let script = webkit_user_script_new(
                engineSource,
                WEBKIT_USER_CONTENT_INJECT_ALL_FRAMES,
                WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_END,
                nil,
                nil
            )
            webkit_user_content_manager_add_script(ucm, script)
            webkit_user_script_unref(script)
        }

        let namespace = WYSIWYGOpsDispatcher.scriptMessageNamespace
        webkit_user_content_manager_register_script_message_handler(ucm, namespace, nil)
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
            // Deserialize inside the task, not before it: the handler runs on the GTK main
            // actor (adwaita-swift ≥ df1b4f3 is main-actor-isolated by default), and the
            // `Any` JSONSerialization produces isn't Sendable, so handing it across would be
            // a data-race diagnostic — an error once this target adopts Swift 6 mode. The
            // `String` crosses instead.
            Task {
                guard let data = json.data(using: .utf8),
                      let body = try? JSONSerialization.jsonObject(with: data)
                else {
                    await logCenter.append(source: "bridge-gtk", stream: .stderr, text: "undecodable script message: \(json)")
                    return
                }
                // Evaluates `window.__anglesiteWysiwygHost?.<callback>?.(<requestId>, <payload>)`
                // back into the page — the one reply shape every request/reply message on this
                // bridge shares (`WYSIWYGScriptHandler.reply` is the WKWebView twin).
                func reply(_ callback: String, requestId: String, payload: some Encodable) async {
                    guard let encoded = try? JSONEncoder().encode(payload),
                          let payloadJSON = String(data: encoded, encoding: .utf8),
                          let idData = try? JSONEncoder().encode(requestId),
                          let idJSON = String(data: idData, encoding: .utf8)
                    else {
                        await logCenter.append(source: "bridge-gtk", stream: .stderr, text: "failed to encode \(callback) reply for id=\(requestId)")
                        return
                    }
                    let script = "window.__anglesiteWysiwygHost?.\(callback)?.(\(idJSON), \(payloadJSON))"
                    Idle {
                        let webView = UnsafeMutableRawPointer(bitPattern: webViewBits)?
                            .assumingMemoryBound(to: WebKitWebView.self)
                        webkit_web_view_evaluate_javascript(webView, script, -1, nil, nil, nil, nil, nil)
                    }
                }
                switch await WYSIWYGOpsDispatcher.dispatch(body: body, via: nil) {
                case .opResult(let requestId, let result):
                    await reply("_handleOpResult", requestId: requestId, payload: result)
                case .writingHelpReply(let requestId, let outcome):
                    await reply("_handleWritingHelpReply", requestId: requestId, payload: outcome)
                case .imageReplaceReply(let requestId, let editReply):
                    await reply("_handleImageReplaceReply", requestId: requestId, payload: editReply)
                case .contextMenu, .selectionChanged, .focusInspector:
                    // Engine chrome messages — unreachable without a mounted engine, and the GTK
                    // shell has no block-editor host chrome to drive yet.
                    return
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
