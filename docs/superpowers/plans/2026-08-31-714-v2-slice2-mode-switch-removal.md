# Website Design Window v2 — Slice 2: Mode-Switch Removal Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Retire the toolbar's `panes` Preview/Editor/Graph segmented control and turn Editor, Graph, and Cleanup into drill-in "takeovers" with a shared Done header that returns to the canvas, per [#714](https://github.com/Anglesite/Anglesite/issues/714) v2 slice 2 (spec §2, §4–5, Slices item 2).

**Architecture:** `MainPaneMode` stays the routing enum; only the *UI surface* for reaching Editor/Graph/Cleanup changes. A new `SiteWindowModel.returnToCanvas()` replaces the old `setPaneSelection(_:)`/`paneSelection` Int-indexed API as the one path back to `.preview`. A new shared SwiftUI view, `MainPaneTakeoverHeader`, gives each takeover (`MainPaneEditorView`, `PlistEditorView`, `SiteGraphExplorerView`, `ProjectCleanupView`) an identical title-row-plus-Done affordance. The `panes` toolbar item and its View-menu ⌘2/⌘3 Toggles are deleted outright — not hidden or deprecated — and `SiteToolbarItemID.panes` is retired from the frozen id set.

**Tech Stack:** Swift 6.4 / SwiftUI (macOS 27), Swift Testing (`@Test`/`#expect`), SwiftPM (`AnglesiteCore`, `AnglesiteAppCore`/`AnglesiteApp` targets).

## Global Constraints

- Swift/SwiftUI with Apple frameworks only — no new third-party dependencies (none needed here).
- `SiteToolbarItemID` raw values are frozen API (macOS persists user toolbar customizations by these strings) — `panes` is being *removed*, which is a deliberate, one-time migration documented by a new `SiteToolbarItemIDTests` case; every other raw value must stay untouched and in its existing order.
- Toolbar items in `SiteWindow.swift`'s `.toolbar(id: "site")` block must stay unconditional (no `if let` wrappers) — this plan does not add any new toolbar items, only deletes one.
- Every spawned subprocess still streams to the debug pane — not touched by this plan (no new process spawning).
- Conventional commit subjects, ≤72 characters, referencing `#714` — but do **not** use a closing-keyword commit type (`fix`/`close`/`resolve`) scoped to `#714` itself, since this PR will not close the tracking issue (slices 3–4 remain); use `feat(#714): …` or scope interim commits to the eventual PR number per `CONTRIBUTING.md`'s "commit-scope/closing-keyword collision" note.
- Run `swift test --package-path .` for every model-layer task; `swift build --package-path .` is sufficient (and fast) to verify a pure-SwiftUI-view task compiles, since this codebase has no view-body unit tests (confirmed: no test target references `MainPaneEditorView`, `PlistEditorView`, `SiteGraphExplorerView`, `ProjectCleanupView`, `ViewMenuCommands`, or `WebsiteCommands` — verified by `grep`). The final task runs the full suite plus `scripts/build-app.sh` and a manual GUI smoke pass, matching this repo's established PR test-plan pattern.
- New user-visible strings ("Graph…") need the Xcode String Catalog sync described in `CONTRIBUTING.md` if built outside the Xcode IDE — call this out in the final task.
- Do not touch toolbar default-item curation, `insert`/`websiteInspector` ids, or demotions — that is slice 3, out of scope here (spec §4, Slices item 3).

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/AnglesiteApp/SiteWindowModel.swift` | Adds `returnToCanvas()`; deletes `paneSelection`/`setPaneSelection(_:)` once nothing calls them. |
| `Sources/AnglesiteCore/SiteToolbarItemID.swift` | Deletes `case panes`. |
| `Sources/AnglesiteApp/SiteWindow.swift` | Deletes the `panes` `ToolbarItem`/`Picker` block; wires `onDone:` into the four takeover views from `mainPaneContent(for:)`. |
| `Sources/AnglesiteApp/ViewMenuCommands.swift` | Collapses the Preview/Editor/Graph Toggles (⌘1–3) into a single Preview control (⌘1) calling `returnToCanvas()`; deletes the now-unused `paneBinding(_:)` helper. |
| `Sources/AnglesiteApp/WebsiteCommands.swift` | Adds a `Graph…` menu item next to the existing `Cleanup…` item. |
| `Sources/AnglesiteApp/MainPaneTakeoverHeader.swift` *(new)* | Shared title-row-plus-Done header view reused by all four takeovers. |
| `Sources/AnglesiteApp/MainPaneEditorView.swift` | Adopts `MainPaneTakeoverHeader` in its existing `header`; gains `onDone`. |
| `Sources/AnglesiteApp/PlistEditorView.swift` | Adopts `MainPaneTakeoverHeader` in its existing `header`; gains `onDone`. |
| `Sources/AnglesiteApp/SiteGraphExplorerView.swift` | Gains a new `MainPaneTakeoverHeader` (had no header before) + `onDone`. |
| `Sources/AnglesiteApp/ProjectCleanupView.swift` | Gains a new `MainPaneTakeoverHeader` (had no header before) + `onDone`. |
| `Tests/AnglesiteAppTests/SiteWindowModelTests.swift` | New `returnToCanvas()` coverage; deletes the three stale `model.paneSelection` assertions. |
| `Tests/AnglesiteCoreTests/SiteToolbarItemIDTests.swift` | Updates the frozen array; adds a "first retired id" test. |

---

### Task 1: `SiteWindowModel.returnToCanvas()`

**Files:**
- Modify: `Sources/AnglesiteApp/SiteWindowModel.swift:518-528` (insert after `setPaneSelection(_:)`, before `showGraph()`)
- Test: `Tests/AnglesiteAppTests/SiteWindowModelTests.swift`

**Interfaces:**
- Produces: `SiteWindowModel.returnToCanvas() -> Void` (fire-and-forget, wraps its own `Task`) — later tasks' Done buttons and the simplified View-menu Preview control both call this.
- Consumes: existing `SiteWindowModel.leaveCurrentEditor() async -> Bool` (`SiteWindowModel.swift:1317`), existing `mainPaneMode: MainPaneMode` (`SiteWindowModel.swift:286`).

This task is purely additive — `paneSelection`/`setPaneSelection(_:)` stay untouched and still compile/pass, so the model builds and tests green both before and after.

- [ ] **Step 1: Write the failing tests**

Add both tests to `Tests/AnglesiteAppTests/SiteWindowModelTests.swift`, directly after the existing `constructs()` test (after line 48, before `close retains its sudden-termination lease…`):

```swift
    @Test("returnToCanvas switches the main pane back to Preview from a takeover")
    func returnToCanvasSwitchesToPreview() async throws {
        let model = makeModel()
        model.mainPaneMode = .cleanup

        model.returnToCanvas()

        while model.mainPaneMode != .preview { await Task.yield() }
        #expect(model.mainPaneMode == .preview)
    }

    /// Mirrors `presentCleanupAbortsOnEditorConflict`'s fixture: a dirty editor whose file changed
    /// on disk under it makes `flushBeforeLeaving()` (invoked via `leaveCurrentEditor()`) return
    /// `false`, so `returnToCanvas()` should abort before touching `mainPaneMode`. This exact guard
    /// was previously only reachable through the untested `setPaneSelection(0)` branch — closing a
    /// real coverage gap, not just moving existing coverage.
    @Test("returnToCanvas doesn't switch panes when leaveCurrentEditor aborts on an editor conflict")
    func returnToCanvasAbortsOnEditorConflict() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let model = makeModel()
        let editedFile = root.appendingPathComponent("conflict.txt")
        try Data("original".utf8).write(to: editedFile)
        let fileRef = FileRef(url: editedFile, group: .components, name: "conflict.txt")
        let editorModel = FileEditorModel(file: fileRef)
        await editorModel.load()
        editorModel.text = "dirty edit"
        try Data("changed on disk".utf8).write(to: editedFile)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: editedFile.path
        )
        model.mainPaneMode = .editor(fileRef)
        model.activeEditor = .text(editorModel)

        model.returnToCanvas()

        var iterations = 0
        while editorModel.conflictDiskContents == nil, iterations < 10_000 {
            await Task.yield()
            iterations += 1
        }
        guard editorModel.conflictDiskContents != nil else {
            Issue.record("flushBeforeLeaving never surfaced the external conflict")
            return
        }

        #expect(model.mainPaneMode == .editor(fileRef))
        #expect(model.activeEditor != nil)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter SiteWindowModelTests`
Expected: FAIL to compile — `value of type 'SiteWindowModel' has no member 'returnToCanvas'`.

- [ ] **Step 3: Add `returnToCanvas()`**

In `Sources/AnglesiteApp/SiteWindowModel.swift`, insert immediately after the closing brace of `setPaneSelection(_:)` (line 528) and before the `showGraph()` doc comment (line 530):

```swift
    /// Returns the main pane to the canvas (View ▸ Preview, ⌘1) — the one way back from any
    /// drill-in takeover (Editor, Graph, Cleanup) via each one's Done control (#714 v2 slice 2).
    /// Async because leaving a dirty text/plist editor autosaves off-main first; an unresolved
    /// external conflict aborts the switch, same contract `leaveCurrentEditor()` gives every other
    /// caller. A no-op when there's nothing to flush: `leaveCurrentEditor()` itself reads `true`
    /// immediately whenever `mainPaneMode` isn't `.editor` (Graph/Cleanup have nothing to save).
    ///
    /// Deliberately leaves `activeEditor` untouched — same behavior as this method's prior form,
    /// `setPaneSelection(0)`'s Preview branch: a file that was open stays loaded in memory so
    /// reopening it from the navigator resumes it instead of reloading from disk.
    func returnToCanvas() {
        Task { if await leaveCurrentEditor() { mainPaneMode = .preview } }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter SiteWindowModelTests`
Expected: PASS (all tests in the suite, including the two new ones).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/SiteWindowModel.swift Tests/AnglesiteAppTests/SiteWindowModelTests.swift
git commit -m "feat(#714): add SiteWindowModel.returnToCanvas()"
```

---

### Task 2: Retire the `panes` toolbar control and id

**Files:**
- Modify: `Sources/AnglesiteCore/SiteToolbarItemID.swift:12`
- Modify: `Sources/AnglesiteApp/SiteWindow.swift:539-556`
- Test: `Tests/AnglesiteCoreTests/SiteToolbarItemIDTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1 (independent).
- Produces: `SiteToolbarItemID` with `panes` removed from `allCases`/the type entirely — the toolbar Picker that showed Preview/Editor/Graph as a segmented control is gone from `SiteWindow`'s toolbar. The `graph` toolbar button (unrelated, pre-existing) is untouched. `SiteWindowModel.paneSelection`/`setPaneSelection(_:)` are **not** removed yet (Task 3 does that, once their remaining caller — the View menu Toggles — is also removed) — this task only removes the *toolbar* consumer, so the model still compiles with an intentionally-unused-by-the-toolbar API in between tasks.

This task must land the `SiteToolbarItemID.panes` case removal and the `SiteWindow.swift` `ToolbarItem` block removal together: the toolbar file is the only remaining reference to `SiteToolbarItemID.panes`/`AXID.toolbar(.panes)`, so removing the case first would break the build.

- [ ] **Step 1: Write the failing test**

Replace the whole array literal in `Tests/AnglesiteCoreTests/SiteToolbarItemIDTests.swift` — remove the leading `"panes",` line (currently line 11) — and append a new test documenting the retirement:

```swift
import Testing
@testable import AnglesiteCore

struct SiteToolbarItemIDTests {
    /// The site-window toolbar item ids are API: macOS persists user toolbar customizations keyed
    /// by these strings, so a rename silently discards every user's saved layout (#519). This test
    /// freezes the exact set — if it fails, you are breaking saved customizations; only proceed
    /// with a deliberate migration story, then update the expectation.
    @Test func toolbarItemIDsAreFrozen() {
        #expect(SiteToolbarItemID.allCases.map(\.rawValue) == [
            "graph",
            "backup",
            "audit",
            "openInBrowser",
            "harden",
            "domainConfigAudit",
            "agentReadiness",
            "onionRouting",
            "aiSearch",
            "domain",
            "integration",
            "siriReadiness",
            "relatedPages",
            "github",
            "deploy",
            "chat",
            "inspector",
            "wysiwygPalette",
            "styleGuide",
            "sync",
            "securityReports",
        ])
    }

    /// First retired toolbar id (#714 v2 slice 2): `panes` — the Preview/Editor/Graph segmented
    /// control — is gone from the toolbar entirely; Editor and Graph are reached by drilling in
    /// (opening a file, Website ▸ Graph…) instead. SwiftUI silently drops unknown ids from a saved
    /// `NSToolbar` customization, so a user who customized their toolbar before this ship keeps
    /// the rest of their layout; "panes" just never reappears. Don't reuse this raw value.
    @Test func panesIsRetiredNotReused() {
        #expect(!SiteToolbarItemID.allCases.map(\.rawValue).contains("panes"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter SiteToolbarItemIDTests`
Expected: FAIL — `toolbarItemIDsAreFrozen` fails (actual array still starts with `"panes"`).

- [ ] **Step 3: Delete the `panes` case**

In `Sources/AnglesiteCore/SiteToolbarItemID.swift`, delete line 12 (`case panes`) so the enum starts:

```swift
public enum SiteToolbarItemID: String, CaseIterable, Sendable {
    case graph
    case backup
```

- [ ] **Step 4: Delete the `panes` `ToolbarItem` from `SiteWindow.swift`**

In `Sources/AnglesiteApp/SiteWindow.swift`, delete lines 539-556 (the leading comment, the `ToolbarItem(id: SiteToolbarItemID.panes.rawValue, ...)` block, its `.customizationBehavior(.disabled)`, and the trailing blank line), so `.toolbar(id: "site") {` is immediately followed by the pre-existing `graph` `ToolbarItem`:

```swift
        .toolbar(id: "site") {
            ToolbarItem(id: SiteToolbarItemID.graph.rawValue, placement: .primaryAction) {
                Button {
                    Task { await model.showGraph() }
                } label: {
                    Label("Site Graph", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .help("Explore pages, layouts, components, collections, and assets")
                .accessibilityIdentifier(AXID.toolbar(.graph))
            }
```

- [ ] **Step 5: Run tests to verify they pass, and build**

Run: `swift test --package-path . --filter SiteToolbarItemIDTests`
Expected: PASS.

Run: `swift build --package-path .`
Expected: BUILD SUCCEEDED (proves `SiteWindow.swift` no longer references the deleted case, and `AXIDTests.swift`'s `SiteToolbarItemID.allCases.map(AXID.toolbar)` — which doesn't pin a count — still compiles).

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/SiteToolbarItemID.swift Sources/AnglesiteApp/SiteWindow.swift Tests/AnglesiteCoreTests/SiteToolbarItemIDTests.swift
git commit -m "feat(#714): retire the panes toolbar segmented control"
```

---

### Task 3: Menu updates — simplify View menu, add Website ▸ Graph…, delete dead pane-selection API

**Files:**
- Modify: `Sources/AnglesiteApp/ViewMenuCommands.swift:34-48,98-103`
- Modify: `Sources/AnglesiteApp/WebsiteCommands.swift:56-57` (after the existing `Cleanup…` button)
- Modify: `Sources/AnglesiteApp/SiteWindowModel.swift:504-528` (delete `paneSelection`/`setPaneSelection(_:)`, now fully unused)
- Test: `Tests/AnglesiteAppTests/SiteWindowModelTests.swift:47,1184-1189,1257-1260`

**Interfaces:**
- Consumes: `SiteWindowModel.returnToCanvas()` (Task 1), `SiteWindowModel.showGraph() async -> Bool` (pre-existing, `SiteWindowModel.swift:534-539`), `SiteWindowModel.canShowGraph: Bool` (pre-existing, `SiteWindowModel.swift:1056`), `SiteWindowModel.mainPaneMode: MainPaneMode` (`Equatable`).
- Produces: nothing new consumed by later tasks — this is the last consumer of `paneSelection`/`setPaneSelection(_:)`, so this task deletes both.

- [ ] **Step 1: Write the failing test (model-layer)**

The View-menu/Website-menu `Commands` structs have no unit tests in this codebase (confirmed: no test file references `ViewMenuCommands` or `WebsiteCommands`), so the only TDD-able piece here is the model deletion. Update the three stale assertions in `Tests/AnglesiteAppTests/SiteWindowModelTests.swift` to stop referencing `paneSelection` (which this task's Step 4 deletes):

Replace line 47 (inside `constructs()`):

```swift
        #expect(model.mainPaneMode == .preview)
```

Replace the `presentCleanupSwitchesPane` test's trailing block (currently lines ~1184-1189):

```swift
        while model.mainPaneMode != .cleanup { await Task.yield() }
        #expect(model.activeEditor == nil)
        #expect(model.inspectorContext == nil)
    }
```

Replace the `presentReaderSwitchesPane` test's trailing block (currently lines ~1256-1260):

```swift
        while model.mainPaneMode != .reader { await Task.yield() }
        #expect(model.activeEditor == nil)
        #expect(model.inspectorContext == nil)
    }
```

- [ ] **Step 2: Run tests to verify they still pass (pre-deletion sanity check)**

Run: `swift test --package-path . --filter SiteWindowModelTests`
Expected: PASS — these edits only remove assertions on an API that still exists at this point, so nothing should break yet. This confirms the edits themselves are correct before the deletion step below removes their compile-time safety net.

- [ ] **Step 3: Simplify the View menu**

In `Sources/AnglesiteApp/ViewMenuCommands.swift`, replace the three Toggles (lines 34-48):

```swift
        CommandGroup(after: .toolbar) {
            // Toggles (not Buttons) so the active pane gets a menu checkmark; setting an already-on
            // pane to false is a no-op, giving radio behavior.
            Toggle("Preview", isOn: paneBinding(0))
                .keyboardShortcut("1")
                .disabled(model == nil)

            Toggle("Editor", isOn: paneBinding(1))
                .keyboardShortcut("2")
                .disabled(model?.activeEditorFile == nil)

            Toggle("Graph", isOn: paneBinding(2))
                .keyboardShortcut("3")
                .disabled(model?.canShowGraph != true)

            Divider()
```

with:

```swift
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
```

Then delete the now-unused `paneBinding(_:)` helper at the bottom of the file (lines 98-103):

```swift
    private func paneBinding(_ index: Int) -> Binding<Bool> {
        Binding(
            get: { model?.paneSelection == index },
            set: { isOn in if isOn { model?.setPaneSelection(index) } }
        )
    }
```

(delete this whole method — nothing else calls it after the Toggle replacement above).

- [ ] **Step 4: Add Website ▸ Graph…**

In `Sources/AnglesiteApp/WebsiteCommands.swift`, insert right after the existing `Cleanup…` button (currently lines 56-57):

```swift
            Button("Cleanup…") { model?.presentCleanup() }
                .disabled(model == nil)

            Button("Graph…") { Task { await model?.showGraph() } }
                .disabled(model?.canShowGraph != true)
```

- [ ] **Step 5: Delete `paneSelection`/`setPaneSelection(_:)` from the model**

In `Sources/AnglesiteApp/SiteWindowModel.swift`, delete the whole block from `var paneSelection: Int {` through the closing brace of `setPaneSelection(_:)` (lines 504-528):

```swift
    var paneSelection: Int {
        if case .editor = mainPaneMode { return 1 }
        if case .graph = mainPaneMode { return 2 }
        // Cleanup has no toolbar/View-menu segment of its own (Site ▸ Cleanup… is the only way
        // in) — an out-of-range value so the pane Picker and the Preview/Editor/Graph Toggles
        // all correctly read as unselected instead of Cleanup falsely appearing as Preview (#723
        // review).
        if case .cleanup = mainPaneMode { return 3 }
        // Same reasoning as Cleanup above: Reader has no toolbar/View-menu segment (Website ▸
        // Reader… is the only way in).
        if case .reader = mainPaneMode { return 4 }
        return 0
    }

    func setPaneSelection(_ value: Int) {
        if value == 0 {
            // Switching to Preview auto-saves the open editor (abort on an unresolved conflict).
            // The flush is async (off-main IO), so do it in a Task and only switch on success.
            Task { if await leaveCurrentEditor() { mainPaneMode = .preview } }
        } else if value == 1, let file = activeEditorFile {
            mainPaneMode = .editor(file)
        } else if value == 2 {
            Task { await showGraph() }
        }
    }
```

`returnToCanvas()` (Task 1, now directly below where this block was) already covers everything the deleted `value == 0` branch did.

- [ ] **Step 6: Build and run the full model test suite**

Run: `swift build --package-path .`
Expected: BUILD SUCCEEDED (proves no remaining caller of `paneSelection`/`setPaneSelection(_:)`/`paneBinding(_:)` anywhere in `AnglesiteApp`/`AnglesiteAppCore`).

Run: `swift test --package-path . --filter SiteWindowModelTests`
Expected: PASS — every test, including the three edited in Step 1.

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteApp/ViewMenuCommands.swift Sources/AnglesiteApp/WebsiteCommands.swift Sources/AnglesiteApp/SiteWindowModel.swift Tests/AnglesiteAppTests/SiteWindowModelTests.swift
git commit -m "feat(#714): View ▸ Preview replaces the pane Toggles, add Website ▸ Graph…"
```

---

### Task 4: `MainPaneTakeoverHeader` shared component

**Files:**
- Create: `Sources/AnglesiteApp/MainPaneTakeoverHeader.swift`

**Interfaces:**
- Produces: `MainPaneTakeoverHeader<Accessory: View>(title: String, systemImage: String, onDone: @escaping () -> Void, accessory: @ViewBuilder () -> Accessory)`, plus a convenience `init(title:systemImage:onDone:)` when `Accessory == EmptyView`. Row layout, leading to trailing: title `Label`, `Spacer()`, `accessory()`, `Button("Done")`. Tasks 5 and 6 both consume this.

This is a pure SwiftUI view with no model logic — this codebase has no test infrastructure for view bodies (verified in Task 3's research), so its verification step is a build, not a unit test, matching how every other pure-View file in this codebase (e.g. `SyncStatusView.swift`, `SecurityReportsBadgeView.swift`) ships without a dedicated test file.

- [ ] **Step 1: Write the component**

Create `Sources/AnglesiteApp/MainPaneTakeoverHeader.swift`:

```swift
import SwiftUI

/// Shared header for a main-pane "takeover" — Editor, Graph, or Cleanup (#714 v2 slice 2): a
/// leading icon/title, an optional trailing accessory (e.g. the editor's dirty dot and Save
/// button), and a Done control that always returns to the canvas. Selecting a page in the
/// navigator already does this via `SiteWindowModel.applyNavigatorSelection`'s `.route` branch;
/// this is the explicit, discoverable equivalent for a takeover reached with no page selection in
/// play — opening a file directly, Website ▸ Graph…, or Website ▸ Cleanup….
struct MainPaneTakeoverHeader<Accessory: View>: View {
    let title: String
    let systemImage: String
    let onDone: () -> Void
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
                .font(.headline)
            Spacer()
            accessory()
            Button("Done", action: onDone)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

extension MainPaneTakeoverHeader where Accessory == EmptyView {
    init(title: String, systemImage: String, onDone: @escaping () -> Void) {
        self.init(title: title, systemImage: systemImage, onDone: onDone) { EmptyView() }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build --package-path .`
Expected: BUILD SUCCEEDED. (The file isn't referenced anywhere yet — this only proves the new type itself is well-formed.)

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteApp/MainPaneTakeoverHeader.swift
git commit -m "feat(#714): add MainPaneTakeoverHeader shared component"
```

---

### Task 5: Wire Done chrome into the Editor takeover

**Files:**
- Modify: `Sources/AnglesiteApp/MainPaneEditorView.swift:11-20` (properties), `:106-118` (`header`)
- Modify: `Sources/AnglesiteApp/PlistEditorView.swift:35` (properties), `:107-119` (`header`)
- Modify: `Sources/AnglesiteApp/SiteWindow.swift` (`mainPaneContent(for:)`'s `.editor` case, both the `.text` and `.plist` branches)

**Interfaces:**
- Consumes: `MainPaneTakeoverHeader` (Task 4), `SiteWindowModel.returnToCanvas()` (Task 1).
- Produces: `MainPaneEditorView.onDone: () -> Void` and `PlistEditorView.onDone: () -> Void`, both defaulted to `{}` so the change is source-compatible with any future preview/instantiation that doesn't care about dismissal.

- [ ] **Step 1: Add `onDone` to `MainPaneEditorView` and adopt the shared header**

In `Sources/AnglesiteApp/MainPaneEditorView.swift`, add a new property after `onCanvasWebView` (currently ending at line 20):

```swift
    /// Bubbles the component harness canvas's webview up to the window (for the inspector's
    /// scrub preview). nil when unused (previews/tests).
    var onCanvasWebView: ((WKWebView?) -> Void)? = nil
    /// Returns the main pane to the canvas (#714 v2 slice 2's Done chrome).
    var onDone: () -> Void = {}
```

Replace the `header` computed property (currently lines 106-118):

```swift
    private var header: some View {
        HStack {
            Label(model.file.name, systemImage: "doc.text")
                .font(.headline)
            if model.isDirty {
                Circle().fill(.secondary).frame(width: 7, height: 7)
                    .help("Unsaved changes")
            }
            Spacer()
            Button("Save") { Task { await model.save() } }
                .disabled(!model.isDirty)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
```

with:

```swift
    private var header: some View {
        MainPaneTakeoverHeader(title: model.file.name, systemImage: "doc.text", onDone: onDone) {
            if model.isDirty {
                Circle().fill(.secondary).frame(width: 7, height: 7)
                    .help("Unsaved changes")
            }
            Button("Save") { Task { await model.save() } }
                .disabled(!model.isDirty)
        }
    }
```

(This moves the dirty-dot and Save button to sit just before Done, on the trailing edge, instead of just after the filename on the leading edge — a deliberate small layout change so both "this file needs attention" signals — Save and Done — read together.)

- [ ] **Step 2: Add `onDone` to `PlistEditorView` and adopt the shared header**

In `Sources/AnglesiteApp/PlistEditorView.swift`, add a new stored property **before** `onWebsiteTitleSaved` (so the existing trailing-closure call site at `SiteWindow.swift` keeps targeting `onWebsiteTitleSaved`, the last parameter):

```swift
struct PlistEditorView: View {
    @Bindable var model: PlistEditorModel
    /// Returns the main pane to the canvas (#714 v2 slice 2's Done chrome).
    var onDone: () -> Void = {}
    let onWebsiteTitleSaved: (String) -> Void
```

Replace the `header` computed property (currently lines 107-119):

```swift
    private var header: some View {
        HStack {
            Label("Settings", systemImage: "gearshape")
                .font(.headline)
            if model.hasAnyUnsavedEdits {
                Circle().fill(.secondary).frame(width: 7, height: 7)
                    .help("Unsaved changes")
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
```

with:

```swift
    private var header: some View {
        MainPaneTakeoverHeader(title: "Settings", systemImage: "gearshape", onDone: onDone) {
            if model.hasAnyUnsavedEdits {
                Circle().fill(.secondary).frame(width: 7, height: 7)
                    .help("Unsaved changes")
            }
        }
    }
```

- [ ] **Step 3: Wire both call sites in `SiteWindow.swift`**

In `mainPaneContent(for:)`'s `.editor` case, update the `.text` branch's `MainPaneEditorView(...)` call to add `onDone:`:

```swift
                MainPaneEditorView(
                    model: editorModel,
                    componentEditor: model.componentEditor,
                    onCanvasWebView: { componentCanvasWebView = $0 },
                    onDone: { model.returnToCanvas() }
                )
```

And the `.plist` branch's `PlistEditorView(...)` call:

```swift
            } else if case .plist(let plistEditorModel) = model.activeEditor {
                PlistEditorView(model: plistEditorModel, onDone: { model.returnToCanvas() }) { title in
                    Task { await model.saveWebsiteTitle(title) }
                }
```

- [ ] **Step 4: Build to verify it compiles**

Run: `swift build --package-path .`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/MainPaneEditorView.swift Sources/AnglesiteApp/PlistEditorView.swift Sources/AnglesiteApp/SiteWindow.swift
git commit -m "feat(#714): Done chrome for the Editor takeover"
```

---

### Task 6: Wire Done chrome into Graph + Cleanup takeovers, final verification

**Files:**
- Modify: `Sources/AnglesiteApp/SiteGraphExplorerView.swift:1-32`
- Modify: `Sources/AnglesiteApp/ProjectCleanupView.swift:8-52`
- Modify: `Sources/AnglesiteApp/SiteWindow.swift` (`mainPaneContent(for:)`'s `.graph` and `.cleanup` cases)

**Interfaces:**
- Consumes: `MainPaneTakeoverHeader` (Task 4), `SiteWindowModel.returnToCanvas()` (Task 1).
- Produces: `SiteGraphExplorerView.onDone: () -> Void` and `ProjectCleanupView.onDone: () -> Void`, both defaulted to `{}`.

- [ ] **Step 1: Add the header + `onDone` to `SiteGraphExplorerView`**

Replace the whole file's struct body in `Sources/AnglesiteApp/SiteGraphExplorerView.swift` (currently lines 4-32):

```swift
struct SiteGraphExplorerView: View {
    @Bindable var model: SiteGraphExplorerModel
    let onOpenFile: (SiteGraphNode) -> Void
    /// Returns the main pane to the canvas (#714 v2 slice 2's Done chrome) — Graph is a
    /// menu-invoked takeover (Website ▸ Graph…), not a peer toolbar pane, so this is its only way
    /// back besides picking a page in the navigator.
    var onDone: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            MainPaneTakeoverHeader(
                title: "Site Graph", systemImage: "point.3.connected.trianglepath.dotted", onDone: onDone)
            Divider()
            HSplitView {
                SiteGraphTree(model: model)
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)

                VStack(spacing: 0) {
                    SiteGraphToolbar(model: model)
                    Divider()
                    SiteGraphCanvas(
                        nodes: model.filteredNodes,
                        edges: model.filteredEdges,
                        referenceCounts: model.visibleReferenceCounts,
                        selectedNodeID: model.selectedNodeID,
                        onSelect: { model.selectedNodeID = $0 }
                    )
                }
                .frame(minWidth: 520)

                SiteGraphInspector(
                    model: model,
                    onOpenFile: onOpenFile
                )
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.windowBackgroundColor))
        }
    }
}
```

(Only the outer `VStack`/header/`Divider` wrapper and the `.frame(maxWidth: .infinity, maxHeight: .infinity)` on the `HSplitView` are new; the `HSplitView`'s three children are unchanged.)

- [ ] **Step 2: Add the header + `onDone` to `ProjectCleanupView`**

In `Sources/AnglesiteApp/ProjectCleanupView.swift`, add a property after `onDelete` (before the `@State` properties):

```swift
    @Bindable var cleanup: ProjectCleanupModel
    var onOpen: (DeadAssetScanner.CleanupCandidate) -> Void
    var onDelete: (DeadAssetScanner.CleanupCandidate) async -> Void
    /// Returns the main pane to the canvas (#714 v2 slice 2's Done chrome) — Cleanup is a
    /// menu-invoked takeover (Website ▸ Cleanup…), not a peer toolbar pane.
    var onDone: () -> Void = {}
```

Replace the `body` (currently lines 17-49) so the existing `List` and all its modifiers move inside a new outer `VStack` with the header:

```swift
    var body: some View {
        VStack(spacing: 0) {
            MainPaneTakeoverHeader(title: "Cleanup", systemImage: "trash", onDone: onDone)
            Divider()
            List {
                cleanupContent
            }
            .navigationSubtitle("Cleanup")
            .confirmationDialog(
                candidateToDeleteTitle,
                isPresented: Binding(
                    get: { candidateToDelete != nil },
                    set: { if !$0 { candidateToDelete = nil } }),
                titleVisibility: .visible,
                presenting: candidateToDelete
            ) { candidate in
                Button("Delete", role: .destructive) {
                    Task { await onDelete(candidate) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { candidate in
                Text(candidate.kind == .page
                    ? "This page has no incoming links and will be permanently removed."
                    : "This file appears unused and will be permanently removed.")
            }
            .alert(
                "Delete failed",
                isPresented: Binding(
                    get: { cleanup.deleteError != nil },
                    set: { if !$0 { cleanup.deleteError = nil } }),
                presenting: cleanup.deleteError
            ) { _ in
                Button("OK", role: .cancel) { cleanup.deleteError = nil }
            } message: { msg in
                Text(msg)
            }
            .task {
                if !cleanup.hasScanned && !cleanup.isBusy { await cleanup.scan() }
            }
        }
    }
```

(`cleanupContent` and every other member of the file below `body` — `cleanupIcon(for:)`, `deleteConfirmationTitle(for:)`, etc. — are unchanged.)

- [ ] **Step 3: Wire both call sites in `SiteWindow.swift`**

In `mainPaneContent(for:)`, update the `.graph` and `.cleanup` cases:

```swift
        case .graph:
            SiteGraphExplorerView(
                model: model.graphExplorer,
                onOpenFile: { node in model.openGraphNode(node, site: site) },
                onDone: { model.returnToCanvas() }
            )
        case .cleanup:
            ProjectCleanupView(
                cleanup: model.cleanup,
                onOpen: { model.openCleanupCandidate($0) },
                onDelete: { await model.deleteCleanupCandidate($0) },
                onDone: { model.returnToCanvas() }
            )
```

- [ ] **Step 4: Build to verify it compiles**

Run: `swift build --package-path .`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Full verification pass**

Run the complete SwiftPM suite:

```bash
swift test --package-path .
```

Expected: PASS, zero regressions (this exercises every `SiteWindowModel`/`SiteToolbarItemID`/`AXID` test touched across all six tasks, plus everything else in the package).

Build the app target:

```bash
scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
```

Expected: BUILD SUCCEEDED. If any user-visible string was added or changed outside the Xcode IDE (`"Graph…"` in `WebsiteCommands.swift`), follow `CONTRIBUTING.md`'s String Catalog sync recipe and commit the resulting `Localizable.xcstrings` diff scoped to this worktree's own `BUILD_DIR` — review the diff before committing; it should contain only the new `"Graph…"` key (and any other genuinely new/changed strings from this branch), nothing from unrelated in-flight work.

Manual GUI smoke (per `docs/testing-macos-app.md`), launch the built app and verify:

- Opening any file (navigator or Website ▸ Website Settings…) still shows the Editor/Settings takeover, now with a Done button in its header; clicking Done returns to the live preview.
- The toolbar no longer shows a Preview/Editor/Graph segmented control.
- Website ▸ Graph… opens the Site Graph takeover with a header (title + Done); Done returns to preview. The pre-existing toolbar Graph button still opens the same view.
- Website ▸ Cleanup… opens the Cleanup takeover with a header; Done returns to preview.
- ⌘1 returns to the canvas from any of the above takeovers; there is no ⌘2/⌘3 anymore, and the View menu shows a single "Preview" item.
- Selecting a page in the navigator while a takeover is showing still returns to the canvas and navigates there (unchanged `.route` behavior — should not regress).
- The Site Graph's three-pane layout still fills the whole window height/width under its new header (not just its intrinsic size).
- View ▸ Customize Toolbar… opens without error and no longer offers "panes" in the palette.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteApp/SiteGraphExplorerView.swift Sources/AnglesiteApp/ProjectCleanupView.swift Sources/AnglesiteApp/SiteWindow.swift
git commit -m "feat(#714): Done chrome for the Graph and Cleanup takeovers"
```

If the String Catalog sync in Step 5 produced a diff, commit it separately:

```bash
git add Sources/AnglesiteApp/Localizable.xcstrings
git commit -m "feat(#714): sync String Catalog for Website ▸ Graph…"
```
