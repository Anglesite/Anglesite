import AppKit
import Quartz
import SwiftUI

/// Backs File ▸ Share…'s in-app Quick Look of the open site's `.anglesite` package (#1617, design
/// doc §5's "Share menu, scoped down to Quick Look"). A thin `NSViewController` embedded invisibly
/// into `SiteWindow`'s view tree via ``QuickLookPreviewHost`` so it sits in the window's responder
/// chain, where `QLPreviewPanel`'s shared-panel mechanism looks for a data source/delegate — this
/// is Apple's standard `QLPreviewPanelController` informal-protocol integration (`begin`/
/// `endPreviewPanelControl`, `acceptsPreviewPanelControl`), not something bespoke to this app.
///
/// Rendering is free: the already-shipped `AnglesiteQuickLookPreview` Finder extension
/// (`Sources/AnglesiteQuickLookPreview/PreviewViewController.swift`) is the system-registered Quick
/// Look provider for `.anglesite` packages, and `QLPreviewPanel` calls into it the same way
/// Finder's Space-bar preview does — this controller only has to supply the package's `URL` as a
/// `QLPreviewItem` (`NSURL` already conforms, via Quick Look's own category).
@MainActor
final class QuickLookPreviewController: NSViewController, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    /// The focused site's package root, or `nil` when no site is open. `SiteWindowModel.shareSite()`
    /// refreshes this immediately before toggling the panel, so it's always current at that point
    /// even though nothing keeps it live in between.
    var packageURL: URL?

    override func loadView() {
        // A zero-size view: this controller exists purely to sit in the responder chain and answer
        // `QLPreviewPanel`'s data-source queries, never to render anything itself.
        view = NSView(frame: .zero)
    }

    override var acceptsFirstResponder: Bool { true }

    /// Toggles the shared Quick Look panel for the current `packageURL`. Explicitly makes this
    /// controller first responder before ordering the panel front — `QLPreviewPanel` resolves its
    /// data source/delegate by walking the key window's responder chain from whatever is currently
    /// first responder, and this controller's invisible view has no reason to already be there
    /// (SwiftUI's own content typically holds first responder). A no-op when `packageURL` is `nil`.
    ///
    /// Closes only when THIS controller is the one currently controlling the shared panel
    /// (`panel.dataSource === self`), not merely when the panel happens to be visible: the panel
    /// is one instance app-wide, so `panel.isVisible` alone can't distinguish "already showing
    /// this window's package" from "showing a different window's package" — the latter must take
    /// over control and refresh, not close (review finding on #1619). `reloadData()` after taking
    /// over forces the panel to re-query this controller's data source rather than keep showing
    /// whatever the previous controller supplied.
    func togglePanel() {
        guard packageURL != nil, let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible, panel.dataSource === self {
            panel.orderOut(nil)
        } else {
            view.window?.makeFirstResponder(self)
            panel.makeKeyAndOrderFront(nil)
            panel.reloadData()
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        packageURL != nil
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        packageURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard let packageURL, index == 0 else { return nil }
        return packageURL as NSURL
    }
}

/// Embeds ``QuickLookPreviewController`` invisibly into `SiteWindow`'s view tree — see that
/// type's doc comment for why it needs to be a real, view-hierarchy-attached view controller
/// rather than a bare helper object. Zero-sized so it never affects layout.
struct QuickLookPreviewHost: NSViewControllerRepresentable {
    let model: SiteWindowModel

    func makeNSViewController(context: Context) -> QuickLookPreviewController {
        let controller = QuickLookPreviewController()
        model.quickLookController = controller
        return controller
    }

    func updateNSViewController(_ nsViewController: QuickLookPreviewController, context: Context) {}
}
