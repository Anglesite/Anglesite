import SwiftUI
import AnglesiteCore

private struct FocusedPreviewKey: FocusedValueKey { typealias Value = PreviewModel }

extension FocusedValues {
    /// The focused site window's `PreviewModel`, published by `SiteWindow`. Lets View-menu commands
    /// reach the live preview without owning it.
    var preview: PreviewModel? {
        get { self[FocusedPreviewKey.self] }
        set { self[FocusedPreviewKey.self] = newValue }
    }
}

/// Browser-style View-menu commands for the live preview (#514): Reload Preview ⌘R, Back ⌃⌘← / Forward ⌃⌘→, and page zoom (Actual Size ⌘0, Zoom In ⌘+, Zoom Out ⌘−).
///
/// Reads the focused site window's `PreviewModel` through the `\.preview` focused value above.
/// Everything is disabled until that window's preview web view exists
/// (the dev server has become ready at least once); Back/Forward additionally track the web view's
/// history via the model's KVO-fed `canGoBack`/`canGoForward` mirrors, and the zoom items pin at
/// the `PreviewZoom` detent-ladder bounds. All actions no-op safely if the weak web view has
/// already been torn down.
struct PreviewNavigationCommands: Commands {
    @FocusedValue(\.preview) private var focusedPreview
    /// Read only for its `windowUndoManager` — the same instance `SiteWindowModel`'s own
    /// `didSet` fan-out forwards to `chat`/`contentUndoCoordinator` — so a freshly-entered edit
    /// mode's canvas gets a real undo manager instead of a permanently-nil one (#1225 final-review
    /// round 2, Finding A). See `editModeBinding` below.
    @FocusedValue(\.siteWindowModel) private var focusedSiteWindowModel

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Reload Preview") {
                focusedPreview?.reloadPreview()
            }
            .keyboardShortcut("r")
            .disabled(focusedPreview?.hasWebView != true)

            // ⌃⌘←/⌃⌘→ — Xcode's navigation-history keys. ⌘[/⌘] are reserved for
            // Format ▸ Text indent per the macOS editor convention (menu-bar spec §3).
            Button("Back") {
                focusedPreview?.goBack()
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .control])
            .disabled(focusedPreview?.canGoBack != true)

            Button("Forward") {
                focusedPreview?.goForward()
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .control])
            .disabled(focusedPreview?.canGoForward != true)

            Divider()

            Button("Actual Size") {
                focusedPreview?.zoomActualSize()
            }
            .keyboardShortcut("0")
            .disabled(focusedPreview?.hasWebView != true || focusedPreview?.zoomLevel == PreviewZoom.actualSize)

            Button("Zoom In") {
                focusedPreview?.zoomIn()
            }
            // KeyEquivalent "+" — macOS menu matching also accepts the unshifted ⌘= chord for it,
            // matching Safari/Xcode behavior.
            .keyboardShortcut("+")
            .disabled(focusedPreview?.hasWebView != true || focusedPreview?.canZoomIn != true)

            Button("Zoom Out") {
                focusedPreview?.zoomOut()
            }
            .keyboardShortcut("-")
            .disabled(focusedPreview?.hasWebView != true || focusedPreview?.canZoomOut != true)

            Divider()

            // Site ▸ Edit Page (#1225): the WYSIWYG canvas toggle — mounts/tears down
            // `WYSIWYGCanvasController` against the existing preview pane (`PreviewModel
            // .enterEditMode(seedModel:)`/`.exitEditMode()`). `Toggle` (not `Button`) so the menu
            // shows a checkmark while edit mode is on, same convention `ViewMenuCommands`'s pane
            // switcher uses. Gated on `hasWebView` (not `canDeploy`/`state`) since edit mode reuses
            // the live preview web view directly and has no requirements beyond it existing.
            Toggle("Edit Page", isOn: editModeBinding)
                .disabled(focusedPreview?.hasWebView != true)
        }
    }

    /// Drives `PreviewModel.enterEditMode(seedModel:undoManager:)`/`.exitEditMode()` from the
    /// Toggle above. `seedModel` is a placeholder empty page — #1222's sidecar `get_page_model`
    /// fetch is still blocked, so there is no real page model to seed the canvas with yet; this
    /// exists purely to exercise the vertical slice (mount → context menu → ops → undo) until
    /// that lands.
    ///
    /// Passes `focusedSiteWindowModel?.windowUndoManager` — read fresh at the moment the toggle
    /// flips on — so the newly-built `wysiwygCanvas`'s `undoCoordinator` gets a real `UndoManager`
    /// (#1225 final-review round 2, Finding A). Re-reading here (rather than relying solely on
    /// `SiteWindowModel`'s one-time `didSet` fan-out) also covers toggling edit mode off and back
    /// on: `exitEditMode()` drops `wysiwygCanvas` entirely, so a later `enterEditMode` call builds
    /// a brand-new canvas that needs the manager threaded through again, not just once.
    private var editModeBinding: Binding<Bool> {
        Binding(
            get: { focusedPreview?.isEditModeEnabled ?? false },
            set: { isOn in
                guard let focusedPreview else { return }
                if isOn {
                    let seed = BlockModel(
                        path: focusedPreview.activeRoute ?? "/", version: "v0", rootIds: [], blocks: [:])
                    let undoManager = focusedSiteWindowModel?.windowUndoManager
                    Task { await focusedPreview.enterEditMode(seedModel: seed, undoManager: undoManager) }
                } else {
                    focusedPreview.exitEditMode()
                }
            }
        )
    }
}
