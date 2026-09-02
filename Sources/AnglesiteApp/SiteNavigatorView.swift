import SwiftUI
import AnglesiteCore

/// Xcode-Project-Navigator-style sidebar. Selection is bound to the model; `SiteWindow` reacts to
/// changes and either navigates the preview or opens the editor.
struct SiteNavigatorView: View {
    @Bindable var model: SiteNavigatorModel
    /// True while the live preview's `WKWebView` holds real keyboard focus elsewhere in the window
    /// (#1423, widened #1715) — while true, this view's `.onDeleteCommand` AND its
    /// `.background`-attached ⌘⌫ Button are both withheld, so nothing here competes with the
    /// preview's own delete/text-editing handling for the keystroke. Covers both the full
    /// `wysiwygCanvas` block editor AND the overlay JS's lighter-weight `contentEditable`
    /// quick-edit (e.g. clicking a page/post title) — see `PreviewModel.hasKeyboardFocus`'s doc
    /// comment for why the two need one shared flag rather than a canvas-only check. See
    /// `SiteWindow.previewPane(for:)`'s matching canvas-side gate and
    /// `onDeleteCommand(active:perform:)`'s doc comment (`PreviewView.swift`) for why two
    /// simultaneously-attached handlers made AppKit's Edit ▸ Delete menu unreliable.
    var previewHasKeyboardFocus: Bool = false
    var onDeleteRequested: (NavigatorItem) -> Void
    var onDuplicateRequested: (NavigatorItem) -> Void
    var onRepurposeRequested: (NavigatorItem) -> Void
    var onPublishRequested: (NavigatorItem) -> Void
    var onUnpublishRequested: (NavigatorItem) -> Void
    @FocusState private var editingFocused: Bool
    /// True while the navigator `List` itself (or the inline-rename field inside it) holds
    /// keyboard focus. Gates the hidden Return-to-rename key equivalent below (#1732): a SwiftUI
    /// `.keyboardShortcut` is window-scoped, so without this gate Return pressed with focus in any
    /// other view that doesn't consume it — the Site Graph takeover's Explorer outline, the Related
    /// Pages panel, inspector controls — started renaming whatever THIS list happened to have
    /// selected. Finder semantics: Return renames only when the list has focus.
    @FocusState private var listHasKeyboardFocus: Bool

    var body: some View {
        List(selection: $model.selection) {
            OutlineGroup(model.nodes, children: \.children) { node in
                row(for: node)
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier(AXID.navigatorList)
        .focused($listHasKeyboardFocus)
        // A click on a row must also give the list keyboard focus (Finder semantics) so the
        // ordinary click-then-Return rename gesture satisfies the gate below. Verified on-device:
        // once SwiftUI's focus goes nil (e.g. the focused Site Graph explorer is torn down when a
        // navigator click closes the takeover), a plain click selects a row WITHOUT moving focus
        // to the list — ↓ and Return then go nowhere until the user Tabs. `simultaneousGesture`
        // so selection, drag-out (`.draggable`) and the context menu keep working.
        //
        // Primary click only, deliberately: `TapGesture` ignores secondary clicks, which matches
        // AppKit — only a left mouse-down moves first responder; a right-click is routed to
        // `rightMouseDown`/`menu(for:)` and leaves the responder chain alone. It also keeps
        // Return honest: a right-click doesn't change `selection`, so focusing the list on one
        // would let Return rename a row other than the one the context menu targeted. The menu's
        // own Rename acts on `node.id` directly and needs no focus.
        //
        // No automated coverage for this wiring or the gate below: `@FocusState` only reflects
        // focus for a key window in an active app, and a hosted `swift test` process is not
        // reliably either (a synthesized `sendEvent` click doesn't even select a row there), so
        // a hosted test would flake. Re-verify by hand — see docs/testing-macos-app.md ▸
        // "Re-verifying navigator keyboard-focus gating".
        .simultaneousGesture(TapGesture().onEnded {
            if !listHasKeyboardFocus { listHasKeyboardFocus = true }
        })
        // Bare Delete key deletes the selection, matching Xcode/Mail/Notes sidebar convention
        // (#674). `deletableSelection()` is nil during inline-rename, so Delete edits the text
        // field there instead — same guard the Return-to-rename affordance above uses. This is
        // also the ONLY Commands-level wiring for content delete (#989): `.onDeleteCommand` is
        // what AppKit's standard Edit ▸ Delete menu item invokes too, so it doubles as that item's
        // handler — a separate Commands `Button("Delete")` alongside it just renders as a second,
        // indistinguishable "Delete" row. The `active:` gate (#1423) keeps this the ONLY
        // `.onDeleteCommand` attached while the preview has focus — see `previewHasKeyboardFocus`'s
        // doc comment above. The action is `nil` while the selection isn't deletable (#1714) — a
        // folder row, the home row, nothing selected, or inline-rename in progress — so AppKit
        // validates Edit ▸ Delete as disabled, rather than enabling it for whatever row this list
        // happens to hold focus on and leaving the item live as a silent no-op. Passing `nil`
        // (instead of also dropping the modifier via `active:`) keeps the List's identity stable
        // across selection changes; see `onDeleteCommand(active:perform:)`'s doc comment.
        .onDeleteCommand(
            active: !previewHasKeyboardFocus,
            perform: model.deletableSelection() == nil ? nil : {
                if let item = model.deletableSelection() {
                    onDeleteRequested(item)
                }
            })
        .overlay {
            if model.nodes.isEmpty {
                ContentUnavailableView("No content yet", systemImage: "sidebar.left")
            }
        }
        .background {
            // Return-to-rename (Finder semantics) as a view-level key equivalent. Attached only
            // while `listHasKeyboardFocus` (#1732) — see its doc comment: the shortcut is
            // window-scoped, so mounting the Button unconditionally let Return leak in from any
            // other focused view (e.g. the Site Graph explorer) and rename the navigator's
            // selection. Detaching rather than `.disabled`-ing is what frees the keystroke for
            // the focused view — the same conditional-attachment shape as
            // `onDeleteCommand(active:perform:)` (`PreviewView.swift`).
            //
            // `listHasKeyboardFocus` stays true during inline rename: `.focused` on a container
            // reflects focus anywhere in its subtree, so while the rename `TextField` (a
            // descendant, focused via `$editingFocused`) is the window's first responder this
            // block stays mounted. Verified with an in-process `NSHostingView` probe of the same
            // List › OutlineGroup › TextField nesting: first responder = the field editor, the
            // binding still true, the block never unmounted, and focus back on the list once the
            // field went away. That is why the `.disabled` below is needed at all — it is the
            // in-rename guard, not the focus gate.
            if listHasKeyboardFocus {
                Button("") {
                    if let id = model.renameableSelection() {
                        model.beginEditing(id)
                    }
                }
                .keyboardShortcut(.return, modifiers: [])
                .hidden()
                // `.hidden()` still exposes the empty-label button to VoiceOver; keep it out of
                // the accessibility tree (it's a keyboard-shortcut affordance, not a real control).
                .accessibilityHidden(true)
                // Disabled while editing: otherwise this default-button shortcut swallows Return
                // before the focused TextField's onSubmit, so commits never fire (#299 review).
                .disabled(model.editingItemID != nil)
            }
        }
        .background {
            // ⌘⌫ as a second key equivalent for the same delete action (#989) — a view-level key
            // command, not a Commands-scene item, so it doesn't add another Edit-menu row.
            // Gated on `previewHasKeyboardFocus` (#1715) exactly like `.onDeleteCommand` above:
            // this predates that gate (#989 shipped before #1423) and was never updated to respect
            // it, so ⌘⌫ typed into the live preview — e.g. mid-edit in a contentEditable title —
            // always deleted the Navigator's selected item instead of editing text, regardless of
            // where real keyboard focus was. `.disabled` alone isn't enough: a disabled Button
            // still claims its shortcut and no-ops, which would swallow ⌘⌫ instead of letting it
            // fall through to the preview's own text editing. Not attaching the modifier at all
            // (same conditional-attachment shape as `onDeleteCommand(active:perform:)`,
            // `PreviewView.swift`) is what actually frees the keystroke.
            if !previewHasKeyboardFocus {
                Button("") {
                    if let item = model.deletableSelection() {
                        onDeleteRequested(item)
                    }
                }
                .keyboardShortcut(.delete, modifiers: [.command])
                .hidden()
                .accessibilityHidden(true)
            }
        }
        .alert(
            "Rename failed",
            isPresented: Binding(
                get: { model.renameError != nil },
                set: { if !$0 { model.renameError = nil } }),
            presenting: model.renameError
        ) { _ in
            Button("OK", role: .cancel) { model.renameError = nil }
        } message: { msg in
            Text(msg)
        }
    }

    @ViewBuilder
    private func row(for node: URLTreeNode) -> some View {
        if model.editingItemID == node.id {
            TextField("Title", text: $model.draftTitle)
                .textFieldStyle(.plain)
                .accessibilityIdentifier(AXID.navigatorRenameField)
                .focused($editingFocused)
                .onSubmit { Task { await model.commitEditing() } }
                .onExitCommand { model.cancelEditing() }   // Esc
                .onChange(of: editingFocused) { _, focused in
                    // TextField.onSubmit does not fire reliably inside a sidebar List on macOS — Return is
                    // consumed by the list and only surfaces as focus loss. So commit on focus loss
                    // (Return / Tab / click-away, Finder-style). Esc cancels first via onExitCommand,
                    // which clears editingItemID, so this guard then skips the commit.
                    if !focused && model.editingItemID == node.id {
                        Task { await model.commitEditing() }
                    }
                }
                .task { editingFocused = true }
                .tag(node.id)
        } else if let url = model.fileURL(for: node.id) {
            // Draggable out to Finder/another app (#676) — only rows backed by a single source
            // file (today: page/post `.route` rows) qualify; see `fileURL(for:)`.
            rowLabel(for: node).draggable(url)
        } else {
            rowLabel(for: node)
        }
    }

    private func rowLabel(for node: URLTreeNode) -> some View {
        Label { Text(node.title) } icon: { icon(for: node) }
            .tag(node.id)
            .lineLimit(1)
            .truncationMode(.middle)
            .contextMenu {
                if model.canRename(node.id) {
                    Button("Rename") { model.beginEditing(node.id) }
                }
                if model.canDuplicate(node.id), let item = model.item(for: node.id) {
                    Button("Duplicate") { onDuplicateRequested(item) }
                }
                if model.canRepurpose(node.id), let item = model.item(for: node.id) {
                    Button("Repurpose Post…") { onRepurposeRequested(item) }
                }
                if model.canPublish(node.id), let item = model.item(for: node.id) {
                    Button("Publish") { onPublishRequested(item) }
                }
                if model.canUnpublish(node.id), let item = model.item(for: node.id) {
                    Button("Unpublish") { onUnpublishRequested(item) }
                }
                if model.canDelete(node.id), let item = model.item(for: node.id) {
                    Button("Delete", role: .destructive) { onDeleteRequested(item) }
                }
            }
    }

    /// #714 icon table: house (home) / doc.richtext (pages, entries) / folder (directory) —
    /// with a radio-waves badge composed on feed-bearing directories until the custom symbol
    /// from docs/art-briefs/2026-07-13-folder-rss-symbol.md ships.
    @ViewBuilder
    private func icon(for node: URLTreeNode) -> some View {
        switch node.kind {
        case .home:
            Image(systemName: "house")
        case .page:
            Image(systemName: "doc.richtext")
        case .directory(_, hasFeed: false):
            Image(systemName: "folder")
        case .directory(_, hasFeed: true):
            Image(systemName: "folder")
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "dot.radiowaves.up.forward")
                        .font(.system(size: 7, weight: .bold))
                        .symbolRenderingMode(.monochrome)
                        .padding(1)
                        .background(.background, in: .circle)
                        .accessibilityLabel("Has RSS feed")
                }
        }
    }
}
