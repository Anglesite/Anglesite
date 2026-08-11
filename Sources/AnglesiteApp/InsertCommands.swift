import AppKit
import SwiftUI
import UniformTypeIdentifiers
import AnglesiteCore

/// The Insert menu (menu-bar spec §2.4). Every item emits semantic HTML/MDX into the page
/// source through the Component Editor write path (#496) — the menu is grammar, the editor
/// is the pen — so the whole menu enables wholesale when that write path lands. Until then
/// everything but New Component… is a PlannedItem. Rich blocks (Table…Navigation) are flat
/// disabled items here; their variant submenus arrive with the component library.
struct InsertCommands: Commands {
    @FocusedValue(\.newContentActions) private var actions
    @FocusedValue(\.preview) private var preview

    /// The focused window's WYSIWYG canvas, when edit mode is on — source of `blockPalette` for
    /// the Component submenu below (#1225 Task 12). `nil` (no palette entries shown) whenever
    /// edit mode is off, same as `preview` itself being unfocused.
    private var wysiwygCanvas: WYSIWYGCanvasController? { preview?.wysiwygCanvas }

    /// `Insert ▸ Image…`'s action: pick a file, write it through the same `insert-image` op the
    /// overlay's empty-page drop branch uses, via the focused window's real `MCPApplyEditRouter`
    /// (`preview.editRouter` — shared with the overlay and the Component Editor, per
    /// `SiteWindowModel.makeComponentEditorContext`'s doc comment).
    @MainActor
    private static func insertImage(into preview: PreviewModel) async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = String(localized: "Insert")
        panel.message = String(localized: "Choose an image to insert into this page.")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let bytes: Data
        do {
            bytes = try Data(contentsOf: url)
        } catch {
            presentFailureAlert(detail: error.localizedDescription)
            return
        }

        let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let dataURL = InsertImageEditBuilder.dataURL(bytes: bytes, mimeType: mimeType)
        let message = InsertImageEditBuilder.message(
            path: preview.activeRoute ?? "/",
            filename: url.lastPathComponent,
            mimeType: mimeType,
            dataURL: dataURL
        )

        let reply = await preview.editRouter.apply(message)
        if reply.status != .applied {
            presentFailureAlert(detail: reply.message ?? "Unknown error")
        }
    }

    @MainActor
    private static func presentFailureAlert(detail: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Couldn't insert that image")
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.runModal()
    }

    var body: some Commands {
        CommandMenu("Insert") {
            Menu("Component") {
                PlannedItem("Component Gallery…")

                Button("New Component…") {
                    actions?.newComponent()
                }
                .disabled(actions == nil)

                if let canvas = wysiwygCanvas {
                    Divider()
                    ForEach(canvas.blockPalette) { entry in
                        Button(entry.displayName) {
                            Task { await canvas.insertBlock(entry) }
                        }
                    }
                }
            }

            Divider()

            PlannedItem("Article")
            PlannedItem("Section")
            PlannedItem("Figure")

            Menu("Heading") {
                PlannedItem("Heading 1")
                PlannedItem("Heading 2")
                PlannedItem("Heading 3")
                PlannedItem("Heading 4")
                PlannedItem("Heading 5")
                PlannedItem("Heading 6")
            }

            PlannedItem("Paragraph")
            PlannedItem("Horizontal Rule")
            PlannedItem("Preformatted Text")
            PlannedItem("Blockquote")

            Menu("List") {
                PlannedItem("Ordered")
                PlannedItem("Unordered")
                PlannedItem("Association")
                Divider()
                PlannedItem("List Item")
            }

            Divider()

            PlannedItem("Table")
            Button("Image…") {
                guard let preview else { return }
                Task { await InsertCommands.insertImage(into: preview) }
            }
            .disabled(preview == nil)
            PlannedItem("Video")
            PlannedItem("Audio")
            PlannedItem("Image Gallery")
            PlannedItem("Form")
            PlannedItem("Navigation")

            Divider()

            PlannedItem("Highlight")
            PlannedItem("Comment", shortcut: "k", modifiers: [.command, .shift])

            Divider()

            PlannedItem("Image Playground…")
            PlannedItem("Web Video…")
            PlannedItem("Import from Phone")
            PlannedItem("Record Audio…")

            Divider()

            PlannedItem("Equation…", shortcut: "e", modifiers: [.command, .option])

            Menu("Advanced") {
                PlannedItem("Script")
                PlannedItem("Canvas")
                PlannedItem("Inline Frame")
                PlannedItem("Embed")
                PlannedItem("Details & Summary")
                PlannedItem("Dialog")
                PlannedItem("Custom Element…")
            }

            Divider()

            PlannedItem("Choose…", shortcut: "v", modifiers: [.command, .shift])
        }
    }
}
