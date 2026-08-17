import Cocoa
import SwiftUI
import AnglesiteCore

// NSViewController already conforms to NSExtensionRequestHandling (see
// NSExtensionRequestHandling.h) on the macOS 27 SDK, so restating the conformance here is a
// redundant-conformance compile error and beginRequest(with:) must carry `override`.
final class ShareViewController: NSViewController {
    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 480))
    }

    override func beginRequest(with context: NSExtensionContext) {
        Task { @MainActor in
            let input = await ShareExtensionInputExtractor.extract(from: context)
            presentCompose(input: input, context: context)
        }
    }

    @MainActor
    private func presentCompose(input: ShareExtensionInput?, context: NSExtensionContext) {
        guard let input else {
            context.cancelRequest(withError: ShareExtensionError.noURL)
            return
        }
        let model = ShareComposeModel(
            urlString: input.urlString,
            initialTitle: input.title,
            onFinish: { context.completeRequest(returningItems: [], completionHandler: nil) },
            onCancel: { context.cancelRequest(withError: ShareExtensionError.cancelled) }
        )
        let hosting = NSHostingController(rootView: ShareComposeView(model: model))
        addChild(hosting)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.width, .height]
        view.addSubview(hosting.view)
    }
}

enum ShareExtensionError: Error {
    case noURL
    case cancelled
}
