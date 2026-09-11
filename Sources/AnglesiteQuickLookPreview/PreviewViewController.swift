import Cocoa
import Quartz
import SwiftUI
import AnglesiteQuickLookUI

/// The Quick Look preview extension's entry point. Deliberately nothing but the
/// `QLPreviewingController` plumbing: the summary + view live in `AnglesiteQuickLookUI`, where
/// `Tests/AnglesiteQuickLookUITests` renders them against a fixture package (#1968) — hosted
/// extension tests never run on CI.
final class PreviewViewController: NSViewController, QLPreviewingController {
    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        view = NSView()
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        let hosting = NSHostingController(rootView: PreviewContentView(packageURL: url))
        addChild(hosting)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.width, .height]
        view.addSubview(hosting.view)

        handler(nil)
    }
}
