import SwiftUI

/// File ▸ Rename… / Move To… / Revert To ▸ / Reveal in Finder / Share… for the focused site
/// window (#513). Rename targets the navigator's selected item (the same inline-edit flow as its
/// context menu); Reveal targets the most specific focused surface — the open editor's file, else
/// the inspected page's file, else the site's `Source/` directory. Declared BEFORE `SaveCommands`
/// in AnglesiteApp.swift: groups sharing a `before:` anchor insert above earlier declarations, so
/// declaring this one first is what lands these items below Save/Duplicate/Save As.
struct FileItemCommands: Commands {
    @FocusedValue(\.siteWindowModel) private var model

    var body: some Commands {
        CommandGroup(before: .importExport) {
            Button("Rename…") { model?.renameNavigatorItem() }
                .disabled(model?.canRenameNavigatorItem != true)

            // Relocates the package; recents + (MAS) security-scoped bookmark update
            // (menu-bar spec §2.2). Planned until the move flow exists.
            PlannedItem("Move To…")

            // Revert To nests the shipped editor revert (moved from SaveCommands, same
            // action) beside the git-backed version browser (spec §4.1) — iWork's
            // File ▸ Revert To shape. Revert to Saved disables while a save/revert is
            // already in flight (PR #532 review).
            Menu("Revert To") {
                Button("Revert to Saved") {
                    model?.requestRevertToSaved()
                }
                .disabled(model?.hasUnsavedEdits != true || model?.editCommandInFlight == true)

                Divider()

                PlannedItem("Browse All Versions…")
            }

            Divider()

            Button("Reveal in Finder") { model?.revealInFinder() }
                .disabled(model?.canRevealInFinder != true)

            Divider()

            // Full Share popover (ShareLink + "Package as Single File", spec §4.2) is still
            // planned; this narrower slice (#1617) shows an in-app Quick Look of the package
            // instead, scoped per the WYSIWYG design doc §5.
            Button("Share…") { model?.shareSite() }
                .disabled(model?.canShareSite != true)
        }
    }
}
