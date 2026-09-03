# E2E Acceptance — Part 3: Basic Edits

**Sequence:** Part 3 of 4 — requires Part 2's exit state ("QA Bakery" open, preview ready).
**Scope:** the everyday editing loop: navigator + inspector edits, in-preview click-to-edit and image drop, new page/post/component, rename/duplicate/delete, the Component Editor styles panel, save/undo/conflict semantics, and the git ledger.

A PASS here (with evidence) closes the owed manual verifications **#586** (navigator content commands), **#491** (Component Editor slice-1 smoke), and — run on this sandboxed target with the git evidence recorded — **#656** (SwiftGit2 content-ops MAS smoke).

## Purpose

Verify the app's editing surfaces write to `Source/`, the preview hot-reloads, undo behaves per surface, and git stays the source of truth: per-operation commits for content ops and typed saves, working-tree-only writes (plus the hidden `anglesite/edits` undo branch) for overlay edits.

## Layout orientation (case 1 verifies this inventory)

- **Navigator** (sidebar): Pages, Posts, Collections, Components, Styles, Metadata groups; a Cleanup section once content exists.
- **Center pane**: segmented **Preview / Editor / Graph** switcher pinned in the toolbar center (⌘1/⌘2/⌘3); the Editor tag only exists while a file editor is active.
- **Inspector** (right, ⌥⌘I): metadata form for the selected page/post.
- **Selection semantics — the key UX rule:** selecting a **page or post** keeps the center pane on **Preview** (navigating to that route) and loads its metadata into the **Inspector**; selecting a **component/style/metadata file** opens the center **Editor**. There is no center-pane document editor for pages/posts.
- **Toolbar** defaults: Site Graph, Backup, Audit, Open in Browser, Publish Site (+health badge), Chat, Inspector.

## Acceptance Matrix

| # | Case | Result | Notes |
|---|---|---|---|
| 1 | Window layout + selection semantics |  |  |
| 2 | Edit page metadata via inspector (⌘S, commit) |  |  |
| 3 | In-preview click-to-edit text (+ ⌘Z undo) |  |  |
| 4 | Image drop with auto alt text |  |  |
| 5 | Save conflict: Keep My Changes / Reload |  |  |
| 6 | New Page / New Post / New Component |  |  |
| 7 | Rename (inline) |  |  |
| 8 | Duplicate (⌘D) |  |  |
| 9 | Delete (⌘⌫) with undo + redirect offer |  |  |
| 10 | Component Editor: styles write round-trip |  |  |
| 11 | Dev-server controls (Stop/Start/Restart) |  |  |
| 12 | Git ledger matches the surface rules |  |  |
| 13 | (Device-gated) Chat edit + unavailable copy |  |  |

## Test Cases

### 1. Window layout + selection semantics

Verify the inventory above. Specifically: select the About page → center pane stays on Preview showing `/about`, inspector shows its metadata; select a component `.astro` file → center pane switches to Editor.

### 2. Edit page metadata via inspector

Select the About page; in the inspector change the title and a business field; observe the dirty indicator; press **⌘S** (File ▸ Save).

Expected:

- Save button/dot clears; the file under `Source/` reflects the change; the preview updates via Astro HMR without a manual reload.
- Typed-entry saves **commit immediately**: `git log` gains an `anglesite: edit <type> <slug>` commit.
- Navigate away with unsaved inspector edits → the buffer flushes to disk (autosave-on-leave), no data loss.
- **File ▸ Revert to Saved** restores disk state after an unsaved change (with confirmation).

### 3. In-preview click-to-edit text

In the Preview pane, hover the homepage headline (blue outline), click, type a change, click elsewhere (blur).

Expected:

- The edit applies: the source file under `Source/` changes; preview keeps the new text after HMR.
- The Chat panel records an `.edit` row with an inline **Undo**; **⌘Z** (Edit ▸ Undo) reverts the edit through the git `undo_edit` path — file and preview both revert. No redo is offered.
- The edit is **not** committed on the working branch (see case 12) but is committed on the hidden `refs/heads/anglesite/edits` branch.

### 4. Image drop with auto alt text

Drag an image file from Finder onto an `<img>` in the preview.

Expected: optimistic swap, then the server-returned asset (new `src`/`srcset`); the image file lands under `Source/`; with Apple Intelligence available and the General setting ON, alt text is generated. Failure/timeout (~30 s) reverts with a toast rather than leaving a broken image.

### 5. Save conflict: Keep My Changes / Reload

With a dirty inspector or file-editor buffer, edit the same file externally (e.g. `echo` an extra line via Terminal), then refocus the app window.

Expected: the "`<file>` changed on disk" alert with **Keep My Changes** / **Reload from Disk**; each button does what it says; dismissing the dialog must not silently pick a side. Navigating away with a conflicted buffer surfaces the conflict instead of clobbering.

### 6. New Page / New Post / New Component

- **File ▸ New ▸ Page…** (⌘N): sheet with Title, auto-slugged editable route, template picker → creates `src/pages/<route>/index.astro`, commits `anglesite: add page …`, appears in the navigator, and selecting it previews the route once Astro rebuilds. Creating over an existing route is refused.
- **File ▸ New ▸ Post…**: Title → markdown file in the posts collection, commits `anglesite: add posts …`; `/blog/` now lists it (empty state gone).
- **File ▸ New ▸ Component…**: Name → PascalCase `src/components/<Name>.astro`, committed.

### 7. Rename (inline)

Context-menu **Rename** (or Return) on a page row → inline text field; Return/Tab/click-away commits, **Esc cancels**. Title rewrites in place; navigator and preview stay consistent.

### 8. Duplicate (⌘D)

Context menu or Edit ▸ Duplicate on a page → "<title> Copy" with a `-copy` slug appears, committed as `anglesite: duplicate …`.

### 9. Delete (⌘⌫) with undo + redirect offer

Delete the duplicate from case 8.

Expected: confirmation dialog → row and file removed, committed `anglesite: delete …` → post-delete **Undo** alert restores it (commit `anglesite: restore …`) → delete again and this time check the **"Add Redirect?"** offer for the freed route. At no point may a file disappear without a commit recording it.

### 10. Component Editor: styles write round-trip (#491 + slice 2)

Open a component `.astro`; verify **Design/Source** toggle, outline → canvas → inspector selection sync, and props knobs. In the **Styles** panel edit a color value (color-picker scrub), add a declaration, and add a rule.

Expected: each write lands in the component's scoped `<style>` in `Source/` and the canvas reflects it; edits carry `baseVersion` — editing the file externally mid-session produces the "changed outside Anglesite" banner + auto-reload, not a silent overwrite. An unparseable component degrades to Source with a diagnostic banner.

### 11. Dev-server controls

**Site ▸ Stop Dev Server** → preview parks at "Dev server stopped" with a Start button; **Start** recovers; **Restart** (⌥⌘R) cycles cleanly. Rapid re-clicks must not double-dispatch. After a forced failure, the failed pane's **Retry** works.

### 12. Git ledger matches the surface rules

Run `git -C …/Source log --oneline` and `git status --porcelain`, plus `git log anglesite/edits --oneline`.

Expected:

- Working-branch history shows the per-op commits from cases 2, 6–9 (`anglesite: add/edit/delete/duplicate/restore …`) on top of the initial commit.
- Overlay/click-to-edit changes (case 3) and plain file-editor saves appear as **uncommitted working-tree changes** on the branch, and as commits on the hidden `anglesite/edits` branch.
- Nothing under `Config/` is tracked.
- (Out of the minimal loop: **Backup** requires an `origin` remote and refuses on `main`, so a fresh local-only site can't run it — do not treat that refusal as a failure. Remote backup under sandbox is #654/#655.)

### 13. (Device-gated) Chat edit + unavailable copy

With Apple Intelligence available: toolbar **Chat** (⌃⌘K), ask for a small copy edit → same `.edit` row + Undo + ⌘Z semantics as case 3. Without it: the assistant surfaces "Apple Intelligence isn't available…" with the System Settings pointer. This case is optional for the run's PASS.

## Exit state for Part 4

"QA Bakery" previewing with several commits of real content history and a clean-enough working tree (commit or revert stray overlay edits if you want a tidy pre-publish state — the app itself does not require it).
