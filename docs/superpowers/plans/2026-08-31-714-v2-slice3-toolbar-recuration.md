# Website Design Window v2 — Slice 3: Toolbar Re-curation Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the `insert` (`+`) and `websiteInspector` toolbar items, make them (plus `openInBrowser`/`deploy`/`chat`/`inspector`) the new default toolbar set, and demote `graph`/`backup`/`audit` to the hidden customization palette — per [#714](https://github.com/Anglesite/Anglesite/issues/714) v2 slice 3 (spec §4, Slices item 3). This branch is layered directly on slice 2 (`claude/issue-714-remaining-188829`, PR [#1686](https://github.com/Anglesite/Anglesite/pull/1686)), since it edits the exact toolbar block slice 2 already touched.

**Architecture:** No new types beyond two `SiteToolbarItemID` cases and their `ToolbarItem`s. `insert` is a `Menu` reusing the exact model state (`newPagePresented`/`newPostPresented`/`newCollectionPresented`) `NewContentActions`' own closures already set — no new action plumbing. `websiteInspector` mirrors the existing `inspector` `ToolbarItem` shape exactly, calling the pre-existing `toggleWebsiteInspector()`. The default/hidden split is realized the way this file already does it: per-item `.defaultCustomization(.hidden)`, with visual default order following declaration order among non-hidden items — no top-level ordered-default-list modifier exists or is being introduced.

**Tech Stack:** Swift 6.4 / SwiftUI (macOS 27), Swift Testing (`@Test`/`#expect`), SwiftPM (`AnglesiteCore`, `AnglesiteAppCore`/`AnglesiteApp` targets).

## Global Constraints

- Swift/SwiftUI with Apple frameworks only — no new dependencies.
- **`SiteToolbarItemID` raw values are frozen, append-only API** (spec §4: "frozen-ID rules apply (IDs are append/retire-only, items render unconditionally)"). The two new cases (`insert`, `websiteInspector`) MUST be appended after the existing last case (`securityReports`), never inserted elsewhere in the declaration — `SiteToolbarItemIDTests.toolbarItemIDsAreFrozen()` pins the exact order and must gain the two new raw values at the end of its array.
- Toolbar items in `SiteWindow.swift`'s `.toolbar(id: "site")` block stay unconditional (no `if let` wrappers) — state-dependent items render `.disabled(...)` instead, matching the file's own documented rule (comment above `.toolbar(id: "site") {`).
- **Scope boundary — explicitly OUT of scope for this plan:** the Blocks section of the `insert` menu (spec §4: "The Blocks section appears once #1224's palette actions exist; the menu ships content-only before that" — that is slice 4, a separate follow-up). This plan ships `insert` as New Page…/New Post…/New Collection Entry… only, nothing else.
- **Two deliberate, documented interpretation calls this plan makes** (spec §4's prose doesn't fully disambiguate these — flagging both so review can override before or after implementation):
  1. `sync`/`securityReports` (the two self-hiding status badges) stay exactly where they are declared today (right after the new `insert` item, ahead of the now-hidden `backup`/`audit`) rather than being moved to trail `chat`/`websiteInspector`/`inspector`. Spec's "Defaults: insert · openInBrowser · deploy · chat · websiteInspector · inspector, plus the self-hiding status items (sync, securityReports)" reads as "the self-hiding badges are additionally part of the default set," not as a positional claim — moving them wasn't asked for and isn't done here.
  2. `wysiwygPalette` (#1588 Task 20, a different epic's toolbar toggle, `.disabled` not `.hidden` per its own comment) is untouched — spec §4's demotion list is a closed set ("Demoted to the hidden palette: `graph`, `backup`, `audit`") that does not name it, and the new-default list doesn't claim to be an exhaustive relisting of every already-existing default item. It stays declared last, after `inspector`, exactly as today.
- Run `swift test --package-path . --filter SiteToolbarItemIDTests` for Task 1 (the only task with real unit-test coverage — `SiteWindow.swift` has none, matching slice 2's established pattern in this codebase). `swift build --package-path .` is the verification for the SwiftUI-only tasks (2-4). The final task runs the full suite plus `scripts/build-app.sh` and a manual GUI smoke pass.
- New user-visible strings ("Insert", "Website Inspector", "New Collection Entry…") need the Xcode String Catalog sync described in `CONTRIBUTING.md` if built outside the Xcode IDE — call this out in the final task (slice 2's Task 6 caught exactly this kind of gap; don't repeat it).
- Commit subjects ≤72 chars, `feat(#714): ...` — this branch does not close #714 (slice 4 remains), so no closing-keyword commit type scoped to `#714` itself.

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/AnglesiteCore/SiteToolbarItemID.swift` | Appends `insert`, `websiteInspector` cases. |
| `Tests/AnglesiteCoreTests/SiteToolbarItemIDTests.swift` | Frozen array gains the two new raw values at the end. |
| `Sources/AnglesiteApp/SiteWindow.swift` | Adds the `insert` `ToolbarItem` (first in the closure) and `websiteInspector` `ToolbarItem` (immediately before `inspector`); adds `.defaultCustomization(.hidden)` to `graph`/`backup`/`audit`. |

No other files change. `NewContentActions`, `InspectorPanelActions`, `toggleWebsiteInspector()`, `AXID.toolbar(_:)`, and the Website-menu items (`Backup`, `Audit`, `Graph…`) this slice relies on already exist and are untouched.

---

### Task 1: `SiteToolbarItemID` gains `insert` and `websiteInspector`

**Files:**
- Modify: `Sources/AnglesiteCore/SiteToolbarItemID.swift:39` (append after `case securityReports`)
- Test: `Tests/AnglesiteCoreTests/SiteToolbarItemIDTests.swift`

**Interfaces:**
- Produces: `SiteToolbarItemID.insert`, `SiteToolbarItemID.websiteInspector` (raw values `"insert"`, `"websiteInspector"`) — Tasks 2 and 3 reference `SiteToolbarItemID.insert.rawValue`/`SiteToolbarItemID.websiteInspector.rawValue` and `AXID.toolbar(.insert)`/`AXID.toolbar(.websiteInspector)`.

- [ ] **Step 1: Write the failing test**

Replace the array literal in `Tests/AnglesiteCoreTests/SiteToolbarItemIDTests.swift`'s `toolbarItemIDsAreFrozen()` — append two new entries at the very end, after `"securityReports",`:

```swift
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
            "insert",
            "websiteInspector",
        ])
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path . --filter SiteToolbarItemIDTests`
Expected: FAIL — `toolbarItemIDsAreFrozen` fails (actual array is two entries shorter; `panesIsRetiredNotReused` still passes, untouched).

- [ ] **Step 3: Append the two cases**

In `Sources/AnglesiteCore/SiteToolbarItemID.swift`, add after the existing last case (`case securityReports`, currently the line just before the closing `}`):

```swift
    /// iCloud sync status badge (#881) — synced/syncing/waiting-for-iCloud/needs-attention.
    case sync
    /// Open GitHub security advisories + Dependabot alerts badge (#975).
    case securityReports
    /// The `+` content-creation menu (#714 v2 slice 3): New Page…/New Post…/New Collection
    /// Entry…, joined later by a Blocks section (slice 4).
    case insert
    /// Toggles the Website inspector (Document analog, #714 v2 slice 1/3) — mutually exclusive
    /// with `inspector` (the selection/Format-analog inspector).
    case websiteInspector
```

(Shown with the two pre-existing cases above it for placement context — only the two new lines are additions; `case sync`/`case securityReports` and their doc comments are unchanged.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --package-path . --filter SiteToolbarItemIDTests`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SiteToolbarItemID.swift Tests/AnglesiteCoreTests/SiteToolbarItemIDTests.swift
git commit -m "feat(#714): add insert and websiteInspector toolbar ids"
```

---

### Task 2: Add the `websiteInspector` toolbar toggle

**Files:**
- Modify: `Sources/AnglesiteApp/SiteWindow.swift` (insert immediately before the existing `inspector` `ToolbarItem`, currently opening at `SiteWindow.swift:830`)

**Interfaces:**
- Consumes: `SiteToolbarItemID.websiteInspector` (Task 1), the pre-existing private method `toggleWebsiteInspector()` (`SiteWindow.swift:277-278`: `@MainActor private func toggleWebsiteInspector() { activateInspector(.website) }`), the pre-existing `@SceneStorage` state `activeInspector: ActiveSiteInspector` (`SiteWindow.swift:34`) and `inspectorShown: Bool` (`SiteWindow.swift:26`), `AXID.toolbar(_:)`.
- Produces: nothing new consumed by later tasks in this plan — this is a self-contained UI addition.

This mirrors the existing `inspector` `ToolbarItem`'s shape exactly (same file, same struct, same pattern — see that block immediately below where this one is inserted).

- [ ] **Step 1: Add the `ToolbarItem`**

In `Sources/AnglesiteApp/SiteWindow.swift`, insert directly before the existing `inspector` `ToolbarItem` (which currently reads, starting at line 829):

```swift
            // Far trailing, adjacent to the inspector panel it controls (Pages/Freeform convention).
            ToolbarItem(id: SiteToolbarItemID.inspector.rawValue, placement: .primaryAction) {
                Button {
                    toggleSelectionInspector()
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .disabled(model.inspectorSelection == nil)
                .help("Show or hide the inspector")
                .accessibilityIdentifier(AXID.toolbar(.inspector))
            }
```

New code, inserted immediately above that block (so the trailing pair reads `websiteInspector` then `inspector`, matching spec §4's "The two inspector toggles sit last on the trailing edge" and §3's "Document/Format" ordering convention):

```swift
            // Far trailing, immediately before the selection inspector toggle (#714 v2 slice 3) —
            // the Website inspector (Document analog) is always available, unlike `inspector`
            // (Format analog) which disables with no selection, so this item never disables.
            ToolbarItem(id: SiteToolbarItemID.websiteInspector.rawValue, placement: .primaryAction) {
                Button {
                    toggleWebsiteInspector()
                } label: {
                    Label("Website Inspector", systemImage: "globe")
                }
                .help("Show or hide the website inspector")
                .accessibilityIdentifier(AXID.toolbar(.websiteInspector))
            }

            // Far trailing, adjacent to the inspector panel it controls (Pages/Freeform convention).
            ToolbarItem(id: SiteToolbarItemID.inspector.rawValue, placement: .primaryAction) {
                Button {
                    toggleSelectionInspector()
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .disabled(model.inspectorSelection == nil)
                .help("Show or hide the inspector")
                .accessibilityIdentifier(AXID.toolbar(.inspector))
            }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build --package-path .`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteApp/SiteWindow.swift
git commit -m "feat(#714): add websiteInspector toolbar toggle"
```

---

### Task 3: Add the `insert` (`+`) toolbar menu

**Files:**
- Modify: `Sources/AnglesiteApp/SiteWindow.swift` (insert as the very first item inside `.toolbar(id: "site") { `, currently opening at `SiteWindow.swift:539`, ahead of the existing `graph` `ToolbarItem`)

**Interfaces:**
- Consumes: `SiteToolbarItemID.insert` (Task 1), `model.newPagePresented`/`newPostPresented`/`newCollectionPresented` (`Bool`, `SiteWindowModel.swift:229-231` — the exact same state `NewContentActions`' closures at `SiteWindow.swift:236-245` already set), `AXID.toolbar(_:)`.
- Produces: nothing new consumed by later tasks in this plan.

**Label note:** the Page menu's existing "New Collection…" item (`PageCommands.swift`) is bound to `actions?.newCollection()` → `model.newCollectionPresented = true`, which actually presents `NewCollectionEntrySheet` (a collection-*entry* creator, not a new-collection-type creator — there is no separate "new collection type" flow in this codebase today). This task's menu item is deliberately labeled **"New Collection Entry…"** (the spec's own wording, and the more accurate one) for the identical action — this is not a bug to reconcile with the Page menu's own (arguably stale) wording, which this task does not touch.

- [ ] **Step 1: Add the `ToolbarItem`**

In `Sources/AnglesiteApp/SiteWindow.swift`, insert as the first line inside `.toolbar(id: "site") { ` (immediately before the existing `graph` `ToolbarItem`, currently the first thing in the closure):

```swift
            // Leading, per Pages/Freeform convention for the content-creation `+` menu (#714 v2
            // slice 3). Content-only for now — a Blocks section joins once the WYSIWYG palette's
            // insert actions exist (slice 4, tracked separately so this menu isn't blocked on it).
            ToolbarItem(id: SiteToolbarItemID.insert.rawValue, placement: .primaryAction) {
                Menu {
                    Button("New Page…") { model.newPagePresented = true }
                    Button("New Post…") { model.newPostPresented = true }
                    Button("New Collection Entry…") { model.newCollectionPresented = true }
                } label: {
                    Label("Insert", systemImage: "plus")
                }
                .help("Add a new page, post, or collection entry")
                .accessibilityIdentifier(AXID.toolbar(.insert))
            }

```

(The existing `graph` `ToolbarItem` and everything after it are unchanged — this is a pure insertion above them.)

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build --package-path .`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteApp/SiteWindow.swift
git commit -m "feat(#714): add insert toolbar menu (content-only)"
```

---

### Task 4: Demote `graph`/`backup`/`audit` to the hidden palette, final verification

**Files:**
- Modify: `Sources/AnglesiteApp/SiteWindow.swift` (three existing `ToolbarItem` blocks: `graph` at ~line 540 post-Task-3, `backup` at ~line 569, `audit` at ~line 582 — exact line numbers will have shifted by Tasks 2-3's insertions; locate by `ToolbarItem(id: SiteToolbarItemID.graph.rawValue`, etc.)

**Interfaces:**
- Consumes: nothing new — this only adds `.defaultCustomization(.hidden)` to three already-existing `ToolbarItem` blocks, the same modifier already used on `harden`/`aiSearch`/etc. (`SiteWindow.swift:630` et al.).
- Produces: nothing consumed by later work in this plan — this is the plan's final task.

Each existing Website-menu equivalent already exists and needs no change: `Button("Backup")` and `Button("Audit")` in `WebsiteCommands.swift` (both pre-existing), and `Button("Graph…")` (added in slice 2). Verify their presence in Step 1 rather than adding anything.

- [ ] **Step 1: Verify the Website-menu equivalents already exist**

Run: `grep -n 'Button("Backup")\|Button("Audit")\|Button("Graph…")' Sources/AnglesiteApp/WebsiteCommands.swift`
Expected: all three match. If any is missing, STOP and report — that would mean the "keeps its Website-menu equivalent" precondition this task relies on doesn't hold, and needs a human decision before hiding the toolbar item.

- [ ] **Step 2: Add `.defaultCustomization(.hidden)` to `graph`**

Find (now the first `ToolbarItem` after Task 3's `insert` item):

```swift
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

Add `.defaultCustomization(.hidden)` after its closing brace, matching the existing pattern on e.g. `harden`:

```swift
            ToolbarItem(id: SiteToolbarItemID.graph.rawValue, placement: .primaryAction) {
                Button {
                    Task { await model.showGraph() }
                } label: {
                    Label("Site Graph", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .help("Explore pages, layouts, components, collections, and assets")
                .accessibilityIdentifier(AXID.toolbar(.graph))
            }
            .defaultCustomization(.hidden)
```

- [ ] **Step 3: Add `.defaultCustomization(.hidden)` to `backup`**

Find:

```swift
            ToolbarItem(id: SiteToolbarItemID.backup.rawValue, placement: .primaryAction) {
                Button {
                    model.backupSite()
                } label: {
                    Label("Backup", systemImage: "externaldrive.fill.badge.icloud")
                }
                .disabled(!model.canRunBackup)
                .help(site.isValid
                      ? "Commit and push working-tree changes to your current branch"
                      : "Site is missing required files")
                .accessibilityIdentifier(AXID.toolbar(.backup))
            }
```

Add `.defaultCustomization(.hidden)` after its closing brace:

```swift
            ToolbarItem(id: SiteToolbarItemID.backup.rawValue, placement: .primaryAction) {
                Button {
                    model.backupSite()
                } label: {
                    Label("Backup", systemImage: "externaldrive.fill.badge.icloud")
                }
                .disabled(!model.canRunBackup)
                .help(site.isValid
                      ? "Commit and push working-tree changes to your current branch"
                      : "Site is missing required files")
                .accessibilityIdentifier(AXID.toolbar(.backup))
            }
            .defaultCustomization(.hidden)
```

- [ ] **Step 4: Add `.defaultCustomization(.hidden)` to `audit`**

Find:

```swift
            ToolbarItem(id: SiteToolbarItemID.audit.rawValue, placement: .primaryAction) {
                Button {
                    model.auditSite()
                } label: {
                    if model.audit.isRunning {
                        Label("Auditing…", systemImage: "magnifyingglass")
                    } else {
                        Label("Audit", systemImage: "checkmark.shield.fill")
                    }
                }
                .disabled(!model.canRunAudit)
                .help(site.isValid && model.preview.canDeploy
                      ? "Run the structured accessibility audit against this site"
                      : site.isValid
                        ? "Open the preview first to start the runtime before auditing"
                        : "Site is missing required files")
                .accessibilityIdentifier(AXID.toolbar(.audit))
            }
```

Add `.defaultCustomization(.hidden)` after its closing brace:

```swift
            ToolbarItem(id: SiteToolbarItemID.audit.rawValue, placement: .primaryAction) {
                Button {
                    model.auditSite()
                } label: {
                    if model.audit.isRunning {
                        Label("Auditing…", systemImage: "magnifyingglass")
                    } else {
                        Label("Audit", systemImage: "checkmark.shield.fill")
                    }
                }
                .disabled(!model.canRunAudit)
                .help(site.isValid && model.preview.canDeploy
                      ? "Run the structured accessibility audit against this site"
                      : site.isValid
                        ? "Open the preview first to start the runtime before auditing"
                        : "Site is missing required files")
                .accessibilityIdentifier(AXID.toolbar(.audit))
            }
            .defaultCustomization(.hidden)
```

- [ ] **Step 5: Update the toolbar's default-count comment if it's now materially wrong**

Read the comment block above `.toolbar(id: "site") {` (currently: `// Curated default ≈8 items; episodic setup/maintenance actions ship hidden and live in // the palette (View ▸ Customize Toolbar…, added in #510).`). Count the current default (non-`.hidden`, non-`.disabled`-instead-of-hidden) items after this task: `insert`, `sync`, `securityReports`, `openInBrowser`, `deploy`, `chat`, `websiteInspector`, `inspector`, `wysiwygPalette` — 9 items (two of which, `sync`/`securityReports`, often render as `EmptyView` and are invisible in practice). If "≈8" still reads as a reasonable approximation, leave it; if you judge it worth tightening, update it to reflect the new composition — this is a documentation nicety, not a hard requirement, so use your judgment and don't over-invest in precision here.

- [ ] **Step 6: Build and run the focused toolbar test**

Run: `swift build --package-path .`
Expected: BUILD SUCCEEDED.

Run: `swift test --package-path . --filter SiteToolbarItemIDTests`
Expected: PASS (unaffected by this task's changes — this is a sanity check that Task 1's frozen array is still accurate).

- [ ] **Step 7: Full verification pass**

Run the complete SwiftPM suite:

```bash
swift test --package-path .
```

Expected: PASS, zero regressions.

Build the app target:

```bash
scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
```

Expected: BUILD SUCCEEDED. If any user-visible string was added or changed outside the Xcode IDE ("Insert", "Website Inspector", "New Collection Entry…" from Tasks 2-3), follow `CONTRIBUTING.md`'s String Catalog sync recipe and commit the resulting `Localizable.xcstrings` diff scoped to this worktree's own `BUILD_DIR` — review the diff before committing; it should contain only genuinely new keys from this branch.

Manual GUI smoke (per `docs/testing-macos-app.md`), launch the built app and verify:

- The toolbar's default set now shows, left to right: the `+` (Insert) menu, then (if applicable) the sync/security-reports status badges, then Open in Browser, the Health+Deploy cluster, Chat, the Website Inspector (globe) toggle, and the selection Inspector toggle — with Graph/Backup/Audit no longer visible by default.
- Clicking the `+` menu shows New Page…/New Post…/New Collection Entry…, and each opens its existing sheet correctly (unchanged behavior — this task only adds a new entry point, not new sheet logic).
- The Website Inspector toolbar toggle shows/hides the same panel as View ▸ Show Website Inspector (⌥⌘J), and is mutually exclusive with the selection Inspector toggle, matching the existing Format/Document exclusivity.
- View ▸ Customize Toolbar… shows Graph/Backup/Audit in the palette (not the default bar), each still reachable via Website ▸ Graph…/Backup/Audit.
- A pre-slice-3 saved toolbar customization (if testable) doesn't crash on load — unknown/removed defaults simply degrade per SwiftUI's existing unknown-id handling (same precedent as slice 2's `panes` retirement).

- [ ] **Step 8: Commit**

```bash
git add Sources/AnglesiteApp/SiteWindow.swift
git commit -m "feat(#714): demote graph/backup/audit to the hidden toolbar palette"
```

If the String Catalog sync in Step 7 produced a diff, commit it separately:

```bash
git add Sources/AnglesiteApp/Localizable.xcstrings
git commit -m "feat(#714): sync String Catalog for slice 3 toolbar strings"
```
