# Website Design Window v2 — Slice 4: Blocks in the + Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Blocks section to the toolbar's `insert` (`+`) menu, listing the theme's insertable components and inserting them the same way the WYSIWYG block palette panel and the Insert ▸ Component menu already do — per [#714](https://github.com/Anglesite/Anglesite/issues/714) v2 slice 4 (spec §4, Slices item 4), the final slice of the v2 redesign. This branch is layered directly on the slice-3 toolbar hoist follow-up (`claude/issue-714-slice3-hoist-actions`, PR [#1690](https://github.com/Anglesite/Anglesite/pull/1690)), since it edits the exact `insert` `Menu` that follow-up just touched.

**Architecture:** No new types, no new plumbing. The "shared action layer" spec §4 calls for already exists: `WYSIWYGCanvasController.blockPalette: [WYSIWYGBlockPaletteEntry]` and `insertBlock(_ entry:) async` are already the single source both the palette panel (`WYSIWYGPaletteView`) and the menu-bar Insert ▸ Component submenu (`InsertCommands.swift`) call. This slice adds a third caller — the toolbar's `insert` `Menu` — reusing that exact API, mirroring `InsertCommands`'s own `if let canvas = wysiwygCanvas { ForEach(canvas.blockPalette) { ... } }` shape line-for-line.

**Tech Stack:** Swift 6.4 / SwiftUI (macOS 27), SwiftPM (`AnglesiteApp`/`AnglesiteAppCore` targets).

## Global Constraints

- Swift/SwiftUI with Apple frameworks only — no new dependencies.
- **Scope is exactly one thing**: add a Blocks section to the existing `insert` toolbar `Menu`, reusing the existing `blockPalette`/`insertBlock(_:)` API unchanged. No new insertion-point tracking, no new palette data source, no changes to `WYSIWYGCanvasController`, `WYSIWYGPaletteView`, or `InsertCommands`.
- **Documented judgment call**: spec §4 says "the same actions as the palette," and the palette's own `insertBlock(_:)` (per its doc comment) "always inserts unconditionally at the root" — there is no tracked "canvas insertion point" cursor concept anywhere in this codebase today (confirmed: the only position-aware insert path is drag-and-drop, which resolves a target from mouse coordinates, not from a stored insertion point). Spec's "inserting at the canvas insertion point" is read here as "the same root-append behavior the palette panel and Insert ▸ Component menu already use," not as a new feature to build — matching exactly what both existing consumers of this API already do. If a real insertion-point concept lands later (e.g. from #1222's manifest work), all three call sites gain it together for free, since they all go through the one `insertBlock(_:)` entry point.
- **Second documented judgment call**: the new Blocks section uses SwiftUI `Section("Blocks") { ... }` (a titled group, rendering as a labeled break in the dropdown) rather than `InsertCommands`'s bare `Divider()` — spec §4 names it "a **Blocks** section," and a titled `Section` is the more literal, more discoverable reading for a flatter menu (the toolbar's `+` menu has no enclosing "Component" submenu the way `InsertCommands` does, so an unlabeled divider would be less clear here).
- No `SiteToolbarItemID` change — the `insert` case already exists (added in slice 3); only its `Menu`'s content changes.
- This codebase has no unit test infrastructure for SwiftUI view bodies (`SiteWindow.swift` has none, matching every prior slice's established pattern) — `swift build --package-path .` is this task's verification, plus the full existing `WYSIWYGCanvasControllerTests` suite (unaffected by this change, but proves `blockPalette`/`insertBlock` themselves still work) as a regression check.
- New user-visible string: `"Blocks"` (the new `Section` header) needs the Xcode String Catalog sync described in `CONTRIBUTING.md` if built outside the Xcode IDE — the four `entry.displayName` values ("Paragraph", "Heading", "Callout", "Image") already exist in the catalog from `InsertCommands`'s and `WYSIWYGPaletteView`'s existing use of the same `stubBlockPalette`, so only `"Blocks"` itself is new.
- Commit subject ≤72 chars, `feat(#714): ...` — closes the issue (this is the last of the four v2 slices), so use the closing keyword `Closes #714` in the PR body (not in commit subjects — see `CONTRIBUTING.md`'s "commit-scope/closing-keyword collision" note) once this PR is ready.

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/AnglesiteApp/SiteWindow.swift` | The `insert` `ToolbarItem`'s `Menu` gains a Blocks section after its three existing content-creation buttons. |

No other files change. `WYSIWYGCanvasController.blockPalette`/`insertBlock(_:)`, `PreviewModel.wysiwygCanvas`, and `AXID.toolbar(_:)` all already exist and are untouched.

---

### Task 1: Add the Blocks section to the `insert` toolbar menu

**Files:**
- Modify: `Sources/AnglesiteApp/SiteWindow.swift:552-562` (the `insert` `ToolbarItem`'s `Menu`)

**Interfaces:**
- Consumes: `model.preview.wysiwygCanvas: WYSIWYGCanvasController?` (`PreviewModel.swift:93`), `WYSIWYGCanvasController.blockPalette: [WYSIWYGBlockPaletteEntry]` and `insertBlock(_ entry: WYSIWYGBlockPaletteEntry) async` (`WYSIWYGCanvasController.swift`) — all pre-existing, unchanged by this task.
- Produces: nothing new — this is the plan's only task.

This mirrors `InsertCommands.swift`'s existing Component-submenu shape exactly:

```swift
if let canvas = wysiwygCanvas {
    Divider()
    ForEach(canvas.blockPalette) { entry in
        Button(entry.displayName) {
            Task { await canvas.insertBlock(entry) }
        }
    }
}
```

adapted to a titled `Section` (per this plan's second documented judgment call) and to `SiteWindow`'s direct `model.preview` access (no `@FocusedValue` needed here — `SiteWindow` is a `View`, not a `Commands` struct, and already owns `model`).

- [ ] **Step 1: Edit the `insert` menu**

In `Sources/AnglesiteApp/SiteWindow.swift`, replace the `insert` `ToolbarItem` block (currently lines 550-562, including its leading comment):

```swift
            // Leading, per Pages/Freeform convention for the content-creation `+` menu (#714 v2
            // slice 3). Content-only for now — a Blocks section joins once the WYSIWYG palette's
            // insert actions exist (slice 4, tracked separately so this menu isn't blocked on it).
            ToolbarItem(id: SiteToolbarItemID.insert.rawValue, placement: .primaryAction) {
                Menu {
                    Button("New Page…") { newContentActions?.newPage() }
                    Button("New Post…") { newContentActions?.newPost() }
                    Button("New Collection Entry…") { newContentActions?.newCollection() }
                } label: {
                    Label("Insert", systemImage: "plus")
                }
                .help("Add a new page, post, or collection entry")
                .accessibilityIdentifier(AXID.toolbar(.insert))
            }
```

with:

```swift
            // Leading, per Pages/Freeform convention for the content-creation `+` menu (#714 v2
            // slice 3). The Blocks section (#714 v2 slice 4) reuses the exact same
            // `WYSIWYGCanvasController.blockPalette`/`insertBlock(_:)` pair the block palette
            // panel and Insert ▸ Component already call — see `InsertCommands.swift`'s identical
            // `if let canvas = wysiwygCanvas { ... }` shape, the shared action layer spec §4 asks
            // for. Present only in WYSIWYG edit mode, same gating as the Block Palette toggle.
            ToolbarItem(id: SiteToolbarItemID.insert.rawValue, placement: .primaryAction) {
                Menu {
                    Button("New Page…") { newContentActions?.newPage() }
                    Button("New Post…") { newContentActions?.newPost() }
                    Button("New Collection Entry…") { newContentActions?.newCollection() }
                    if let canvas = model.preview.wysiwygCanvas {
                        Section("Blocks") {
                            ForEach(canvas.blockPalette) { entry in
                                Button(entry.displayName) {
                                    Task { await canvas.insertBlock(entry) }
                                }
                            }
                        }
                    }
                } label: {
                    Label("Insert", systemImage: "plus")
                }
                .help("Add a new page, post, or collection entry")
                .accessibilityIdentifier(AXID.toolbar(.insert))
            }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build --package-path .`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Run the WYSIWYG canvas controller test suite as a regression check**

Run: `swift test --package-path . --filter WYSIWYGCanvasControllerTests`
Expected: PASS (unaffected by this change — this only proves `blockPalette`/`insertBlock` themselves are still correct, since this task adds a new caller but changes no shared code).

- [ ] **Step 4: Full verification pass**

Run the complete SwiftPM suite:

```bash
swift test --package-path .
```

Expected: PASS, zero regressions.

Build the app target:

```bash
scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
```

Expected: BUILD SUCCEEDED. The new `"Blocks"` string needs the Xcode String Catalog sync described in `CONTRIBUTING.md` if built outside the Xcode IDE — follow that recipe, scoped to this worktree's own `BUILD_DIR`, and review the resulting `Localizable.xcstrings` diff before committing: it should contain only the `"Blocks"` key (the four `entry.displayName` strings — "Paragraph", "Heading", "Callout", "Image" — already exist in the catalog from `InsertCommands`'s and `WYSIWYGPaletteView`'s prior use of the same `stubBlockPalette`, so they should NOT appear as new keys; if they do, something's wrong with the sync scope, not with this task's code).

Manual GUI smoke (per `docs/testing-macos-app.md`), launch the built app and verify:

- With WYSIWYG edit mode OFF, the toolbar's `+` menu shows only New Page…/New Post…/New Collection Entry… — no Blocks section, no empty divider.
- With WYSIWYG edit mode ON, the `+` menu additionally shows a "Blocks" section listing Paragraph/Heading/Callout/Image (the current `stubBlockPalette` contents).
- Clicking a Blocks entry inserts that component at the page root — the same behavior as double-clicking the same entry in the Block Palette panel (View ▸ ... Block Palette toggle) or choosing it from Insert ▸ Component.
- The `+` menu's content-creation items (New Page…/New Post…/New Collection Entry…) still work exactly as before — this task only adds content below them, never changes them.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/SiteWindow.swift
git commit -m "feat(#714): add Blocks section to the insert toolbar menu"
```

If the String Catalog sync in Step 4 produced a diff, commit it separately:

```bash
git add Sources/AnglesiteApp/Localizable.xcstrings
git commit -m "feat(#714): sync String Catalog for the Blocks menu section"
```
