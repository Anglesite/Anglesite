import SwiftUI
import AppKit

/// Bridges `WYSIWYGCanvasController.hasUncommittedOps` into `NSWindow.isDocumentEdited` (#1588
/// Task 17) — the titlebar's edited dot. No existing `NSDocument`/`isDocumentEdited` precedent in
/// this app (every other editor auto-saves on focus-leave instead), so this is the minimal
/// SwiftUI-to-AppKit-window bridge for the one surface that genuinely needs it.
struct WindowEditedStateBridge: NSViewRepresentable {
    var isEdited: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { view.window?.isDocumentEdited = isEdited }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.isDocumentEdited = isEdited
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        nsView.window?.isDocumentEdited = false
    }
}
