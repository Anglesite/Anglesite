import SwiftUI

/// The Page menu (menu-bar spec §2.5): page-scoped creation and chrome. New Page owns ⌘N —
/// the everyday create action gets the fast key (Xcode convention); New Site is ⇧⌘N in File.
/// Edit Header/Footer and Styles are editor-gated placeholders; typed collections and the
/// feed directory are app/subsystem-gated (spec §2.5, §4.6).
struct PageCommands: Commands {
    @FocusedValue(\.newContentActions) private var actions

    var body: some Commands {
        CommandMenu("Page") {
            Button("New Page…") {
                actions?.newPage()
            }
            .keyboardShortcut("n")
            .disabled(actions == nil)

            Button("New Post…") {
                actions?.newPost()
            }
            .disabled(actions == nil)

            Button("New Link Post…") {
                actions?.newLinkPost()
            }
            .disabled(actions == nil)

            Divider()

            PlannedItem("Edit Header")
            PlannedItem("Edit Footer")

            Divider()

            PlannedItem("Styles…")

            Menu("Collections") {
                Button("New Collection…") {
                    actions?.newCollection()
                }
                .disabled(actions == nil)

                // Typed collections (content-type registry, #335) replace the generic
                // sheet when they land — spec §2.5.
                PlannedItem("New Blog…")
                PlannedItem("New Podcast…")
                PlannedItem("New Inventory…")

                Divider()

                PlannedItem("Add RSS Feed to Directory")
                PlannedItem("Remove RSS Feed")
            }
        }
    }
}
