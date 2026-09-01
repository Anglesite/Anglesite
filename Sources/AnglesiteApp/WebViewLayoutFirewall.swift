import AppKit
import WebKit

/// Frame-based container for a `WKWebView` mounted via `NSViewRepresentable` inside the site
/// window's `NavigationSplitView`/`.inspector()` chrome — Stage 2 of the #1699 design
/// (`docs/superpowers/specs/2026-08-31-wkwebview-split-chrome-crash-design.md`).
///
/// On macOS 27 beta, a `WKWebView`-hosting representable mounting while the detail column
/// reconfigures feeds a self-sustaining min/max-size negotiation loop between `NSHostingView`
/// and AppKit's private `SplitViewChildController`, which ends in the runaway-constraints
/// guard aborting the process (#1696, 5/5 reproductions on 26A5425a). This container starves
/// that loop by presenting constant sizing metrics: it has no intrinsic size, holds no Auto
/// Layout relationship with the webview (autoresizing masks only), and — via
/// ``sizeResponse(width:height:)`` — answers SwiftUI's sizing probes as a pure function of
/// the proposal, so repeated probes can never produce new values to renegotiate.
@MainActor
final class WebViewLayoutFirewall: NSView {
    /// The wrapped webview. Exposed so representable `updateNSView`/coordinator logic keeps
    /// operating on the `WKWebView` itself (loads, bridges, `onWebView` reporting).
    let webView: WKWebView

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("WebViewLayoutFirewall is code-constructed only") }

    /// Constant by contract: the firewall never has an opinion the layout system could react
    /// to. (`NSView`'s default is already `noIntrinsicMetric`; overriding pins the invariant
    /// against AppKit changing that default and gives the unit test a symbol to freeze.)
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    /// The answer `ComponentCanvasView.sizeThatFits(_:nsView:context:)` returns for a sizing
    /// proposal: the proposal itself, with unspecified dimensions collapsed to zero. Min probe
    /// → 0, max probe → infinity, concrete proposal → itself — fully flexible, zero-opinion,
    /// and (the property the firewall exists for) a pure function of the input, so SwiftUI's
    /// measurement never varies across passes. Static and view-independent so the unit tests
    /// can freeze it without constructing a representable `Context`.
    static func sizeResponse(width: CGFloat?, height: CGFloat?) -> CGSize {
        CGSize(width: width ?? 0, height: height ?? 0)
    }
}
