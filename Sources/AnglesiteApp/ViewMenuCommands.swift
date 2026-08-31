import SwiftUI

/// The page inspector's visibility lives in `SiteWindow` scene state (`@SceneStorage`), not on the
/// window model, so the View menu reaches it through this focused value rather than
/// `\.siteWindowModel` (#512).
struct InspectorPanelActions {
    let isShown: Bool
    let isAvailable: Bool
    let toggle: @MainActor () -> Void
    /// Website inspector visibility (#714 v2 slice 1) — mutually exclusive with `isShown`'s
    /// selection inspector. Always available: the website inspector has content whenever a site
    /// is open, unlike the selection inspector which gates on `isAvailable`.
    let isWebsiteShown: Bool
    let toggleWebsite: @MainActor () -> Void
}

private struct FocusedInspectorPanelKey: FocusedValueKey { typealias Value = InspectorPanelActions }

extension FocusedValues {
    var inspectorPanel: InspectorPanelActions? {
        get { self[FocusedInspectorPanelKey.self] }
        set { self[FocusedInspectorPanelKey.self] = newValue }
    }
}

/// View-menu commands for the focused site window: returning to the canvas (⌘1) and the side-panel
/// toggles (#512). Declared before `PreviewNavigationCommands` so these sit above it in the View
/// menu.
struct ViewMenuCommands: Commands {
    @FocusedValue(\.siteWindowModel) private var model
    @FocusedValue(\.inspectorPanel) private var inspectorPanel

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            // A Toggle (not a Button) so the menu still shows a checkmark once the canvas is
            // showing; setting it off is a no-op, matching the old three-way group's radio
            // behavior for its own Preview entry. Editor/Graph retired with the `panes` toolbar
            // control (#714 v2 slice 2): both are drill-in takeovers now — opening a file, or
            // Website ▸ Graph… — each with its own Done control back to here.
            Toggle("Preview", isOn: Binding(
                get: { model?.mainPaneMode == .preview },
                set: { isOn in if isOn { model?.returnToCanvas() } }
            ))
            .keyboardShortcut("1")
            .disabled(model == nil)

            Divider()

            // ⌃⌘K — ⌘K is reserved for Format ▸ Add Link… per the macOS editing
            // convention (menu-bar spec §3). The shortcut lives here, not on the
            // toolbar chat button — a shortcut on a toolbar item is invisible in
            // the menu bar (the discoverability gap #512 exists to close).
            Button(model?.chatPresented == true ? "Hide Chat" : "Show Chat") {
                model?.chatPresented.toggle()
            }
            .keyboardShortcut("k", modifiers: [.command, .control])
            .disabled(model == nil)

            Button(model?.relatedPagesPresented == true ? "Hide Related Pages" : "Show Related Pages") {
                model?.relatedPagesPresented.toggle()
            }
            .disabled(model == nil)

            // ⌥⌘I per the HIG-standard inspector shortcut — reserved for this in #510, when the
            // Web Inspector moved to ⌥⇧⌘I. Submenu shape per menu-bar spec §2.8; the tab items
            // are planned until the inspector grows Style/Animation/Attributes tabs.
            Menu("Inspector") {
                PlannedItem("Style")
                PlannedItem("Animation")
                PlannedItem("Attributes")

                Divider()

                PlannedItem("Show Next Inspector Tab")
                PlannedItem("Show Previous Inspector Tab")

                Divider()

                Button(inspectorPanel?.isShown == true ? "Hide Inspector" : "Show Inspector") {
                    inspectorPanel?.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(inspectorPanel?.isAvailable != true)
            }

            Button(inspectorPanel?.isWebsiteShown == true ? "Hide Website Inspector" : "Show Website Inspector") {
                inspectorPanel?.toggleWebsite()
            }
            .keyboardShortcut("j", modifiers: [.command, .option])
            .disabled(inspectorPanel == nil)

            Divider()
        }
    }
}
