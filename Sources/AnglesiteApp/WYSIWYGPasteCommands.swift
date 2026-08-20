import SwiftUI
import AppKit
import AnglesiteCore

/// Edit ▸ Copy and Edit ▸ Paste and Match Style for the WYSIWYG canvas (#1588 Tasks 15-16, design
/// doc §8.4). Follows `FormatCommands`'s `EditorFocusRegistry`-based dispatch (plain `let`, not
/// `@FocusedValue` or `@ObservedObject` — `EditorFocusRegistry` is `@MainActor @Observable` via
/// the Observation framework, not Combine's `ObservableObject`, so `@ObservedObject` wouldn't even
/// compile against it) since Copy, Paste and Match Style, and Format all need the same "which
/// editor currently owns keyboard focus" answer.
///
/// The plain ⌘V "Paste" (not Match Style) is deliberately **not** added here — the standard system
/// Edit ▸ Paste item already exists and today routes into whatever `RichTextEditor`'s
/// contentEditable paste handling does; this only adds the new ⇧⌥⌘V command, which has no system
/// default to conflict with. This is genuinely "paste onto the canvas, inserting new blocks," not
/// paste-into-an-actively-edited-text-run. ⌘C "Copy", by contrast, has no existing system item to
/// conflict with either — the canvas's block selection isn't `NSResponder` text selection, so there
/// is no default Edit ▸ Copy target for it until this command supplies one.
struct WYSIWYGPasteCommands: Commands {
    private let registry = EditorFocusRegistry.shared

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button("Copy") {
                wysiwygController?.copySelectedBlock()
            }
            .keyboardShortcut("c", modifiers: [.command])
            .disabled(wysiwygController?.selectedBlockId == nil)

            Button("Paste and Match Style") {
                pasteMatchingStyle()
            }
            .keyboardShortcut("v", modifiers: [.command, .option, .shift])
            .disabled(wysiwygController == nil)
        }
    }

    private var wysiwygController: WYSIWYGCanvasController? {
        if case .wysiwygCanvas(let box) = registry.active { return box.value }
        return nil
    }

    private func pasteMatchingStyle() {
        guard let controller = wysiwygController else { return }
        let pasteboard = NSPasteboard.general
        let attributed: NSAttributedString?
        if let rtfData = pasteboard.data(forType: .rtf) {
            attributed = try? NSAttributedString(data: rtfData, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        } else if let htmlData = pasteboard.data(forType: .html) {
            attributed = try? NSAttributedString(data: htmlData, options: [.documentType: NSAttributedString.DocumentType.html], documentAttributes: nil)
        } else if let plain = pasteboard.string(forType: .string) {
            attributed = NSAttributedString(string: plain)
        } else {
            attributed = nil
        }
        guard let attributed else { return }
        let paragraphs = WYSIWYGRichTextPasteMapper.map(attributed, plainTextOnly: true)
        Task {
            for runs in paragraphs where !runs.isEmpty {
                let newId = UUID().uuidString
                let content = BlockNodeContent(kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0], richText: runs)
                await controller.submit(.insertBlock(parentId: rootParentID, slot: "main", index: controller.model.rootIds.count, newId: newId, block: content))
            }
        }
    }
}
