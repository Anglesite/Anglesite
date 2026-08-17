// Placeholder — replaced in full by Task 6 of docs/superpowers/plans/2026-08-16-share-extension-quick-capture-plan.md.
import Cocoa

// NSViewController already conforms to NSExtensionRequestHandling (see
// NSExtensionRequestHandling.h) on the macOS 27 SDK, so restating the conformance here is a
// redundant-conformance compile error and beginRequest(with:) must carry `override`.
final class ShareViewController: NSViewController {
    override var nibName: NSNib.Name? { nil }
    override func loadView() { view = NSView() }

    override func beginRequest(with context: NSExtensionContext) {
        context.cancelRequest(withError: NSError(domain: "AnglesiteShareExtension", code: -1))
    }
}
