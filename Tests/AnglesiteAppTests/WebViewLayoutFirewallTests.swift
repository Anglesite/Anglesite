import Testing
import AppKit
import WebKit
@testable import AnglesiteAppCore

/// Sizing invariants for the #1699 Stage 2 layout firewall: the container must present
/// constant metrics to `NSHostingView`/`SplitViewChildController` no matter what the wrapped
/// `WKWebView` does internally. The crash itself is only provable in a windowed run (see the
/// spec's Verification section); these tests freeze the invariants that make the firewall one.
@MainActor
@Suite("WebViewLayoutFirewall sizing invariants (#1699)")
struct WebViewLayoutFirewallTests {
    private func makeFirewall() -> WebViewLayoutFirewall {
        WebViewLayoutFirewall(webView: WKWebView(frame: .zero, configuration: WKWebViewConfiguration()))
    }

    @Test("reports no intrinsic size on either axis")
    func noIntrinsicSize() {
        let firewall = makeFirewall()
        #expect(firewall.intrinsicContentSize.width == NSView.noIntrinsicMetric)
        #expect(firewall.intrinsicContentSize.height == NSView.noIntrinsicMetric)
    }

    @Test("hosts the webview frame-based, not with Auto Layout")
    func frameBasedHosting() {
        let firewall = makeFirewall()
        #expect(firewall.webView.superview === firewall)
        #expect(firewall.webView.translatesAutoresizingMaskIntoConstraints)
        #expect(firewall.webView.autoresizingMask.contains(.width))
        #expect(firewall.webView.autoresizingMask.contains(.height))
        #expect(firewall.constraints.isEmpty)
        #expect(firewall.webView.constraints.allSatisfy { $0.firstItem !== firewall && $0.secondItem !== firewall })
    }

    @Test("webview tracks the container's frame")
    func webViewTracksFrame() {
        let firewall = makeFirewall()
        firewall.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        #expect(firewall.webView.frame == firewall.bounds)
        firewall.setFrameSize(NSSize(width: 800, height: 300))
        #expect(firewall.webView.frame == firewall.bounds)
    }

    @Test("sizeResponse is a pure function of the proposal")
    func sizeResponseIsPure() {
        // Min probe (0), max probe (infinity), and a concrete proposal each map straight
        // through; unspecified dimensions collapse to 0 (fully flexible, no opinion).
        #expect(WebViewLayoutFirewall.sizeResponse(width: 0, height: 0) == .zero)
        #expect(WebViewLayoutFirewall.sizeResponse(width: .infinity, height: .infinity)
            == CGSize(width: CGFloat.infinity, height: CGFloat.infinity))
        #expect(WebViewLayoutFirewall.sizeResponse(width: 512, height: 384)
            == CGSize(width: 512, height: 384))
        #expect(WebViewLayoutFirewall.sizeResponse(width: nil, height: nil) == .zero)
    }
}
