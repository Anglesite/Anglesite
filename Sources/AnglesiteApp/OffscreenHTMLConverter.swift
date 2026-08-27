import Foundation
import WebKit
import AnglesiteCore

/// Converts a fragment of rendered HTML (a WXR entry's `content:encoded`/`excerpt:encoded`) into
/// Markdown + referenced image URLs by running the same `JS/import-engine` bundle the design doc
/// specifies for every HTML-string body in the import pipeline — "one converter for every ladder
/// rung" (`docs/superpowers/specs/2026-08-21-website-import-transform-design.md`). `AnglesiteCore`
/// stays portable (no WebKit), so this — the concrete `ImportHTMLConverter` — lives here (#1636).
///
/// Owns one reusable, offscreen `WKWebView`: never added to a window or view hierarchy, created
/// lazily on first use. A `WKWebView` can't run two navigations concurrently, so `convert(html:)`
/// calls must be serialized by the caller — `WXRRung.items(from:convert:)`'s own `for` loop with
/// `await` already does this naturally; nothing here enforces it independently.
@MainActor
final class OffscreenHTMLConverter: NSObject, ImportHTMLConverter, WKNavigationDelegate {
    private let bundle: Bundle
    private var pendingLoadContinuation: CheckedContinuation<Void, Never>?

    init(bundle: Bundle = .main) {
        self.bundle = bundle
        super.init()
    }

    private lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        if let scriptSource = Self.importEngineSource(bundle: bundle) {
            configuration.userContentController.addUserScript(
                WKUserScript(source: scriptSource, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        return view
    }()

    /// Reads `Resources/ImportEngine/import-engine.js` from `bundle` — `nil` if the resource is
    /// missing (an unlikely but non-fatal build issue; conversion then always yields `("", [])`,
    /// which `WXRRung` already turns into a per-entry `ImportProblem` rather than crashing).
    ///
    /// `internal` (not `private`) so tests can point it at a fixture `Bundle` and verify the
    /// path-construction logic directly, decoupled from whether Xcode's real build actually
    /// bundles `Resources/ImportEngine/` (that half can only be verified by a real app build —
    /// see `project.yml`'s `Anglesite` target `sources:` list).
    static func importEngineSource(bundle: Bundle) -> String? {
        guard let resourceURL = bundle.resourceURL else { return nil }
        return try? String(contentsOf: resourceURL.appendingPathComponent("ImportEngine/import-engine.js"),
                           encoding: .utf8)
    }

    func convert(html: String) async -> (markdown: String, images: [String]) {
        await withCheckedContinuation { continuation in
            pendingLoadContinuation = continuation
            webView.loadHTMLString(Self.wrap(html), baseURL: nil)
        }
        guard let raw = try? await webView.evaluateJavaScript(Self.extractScript) as? String,
              let record = Self.decodeExtraction(raw)
        else {
            return ("", [])
        }
        return (record.markdown, record.images)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            pendingLoadContinuation?.resume()
            pendingLoadContinuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            pendingLoadContinuation?.resume()
            pendingLoadContinuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                             withError error: Error) {
        Task { @MainActor in
            pendingLoadContinuation?.resume()
            pendingLoadContinuation = nil
        }
    }

    /// Wraps a bare content fragment in a minimal document shell so `loadHTMLString` has
    /// something well-formed to parse. Factored out so it's testable without a real `WKWebView` —
    /// same reasoning as `WYSIWYGCanvasController.mountScript(for:)`'s split.
    static func wrap(_ html: String) -> String {
        "<!doctype html><html><body>\(html)</body></html>"
    }

    /// The `evaluateJavaScript` call string. `?? ""` guards the case the injected `WKUserScript`
    /// never ran (e.g. `importEngineSource` returned `nil`, or the load errored before the
    /// document script phase) — `window.__anglesiteImportExtract` would be `undefined`, and
    /// calling it directly would throw instead of resolving to a decodable value.
    static let extractScript = "window.__anglesiteImportExtract?.() ?? \"\""

    /// Decodes the JSON string `__anglesiteImportExtract()` returns into an ``ExtractionRecord``
    /// — `nil` for the empty-string fallback above, or any malformed payload.
    static func decodeExtraction(_ json: String) -> ExtractionRecord? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ExtractionRecord.self, from: data)
    }
}
