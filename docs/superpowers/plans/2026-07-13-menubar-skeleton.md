# Menu Bar Skeleton (Phase 1) Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the full north-star menu bar skeleton — every menu and item from the approved spec, with unbacked items disabled — plus the shortcut re-keys and renames, in one release.

**Architecture:** Declarative SwiftUI `Commands` types, one per menu concern (established pattern). A `PlannedItem` helper renders spec-mandated-but-unbacked items as standard disabled buttons. No new logic layers; live items keep binding through `.focusedSceneValue` → `@FocusedValue`.

**Tech Stack:** Swift 6.4 / SwiftUI (macOS 27), XcodeGen project, String Catalog localization.

**Spec:** `docs/superpowers/specs/2026-07-13-menubar-ia-design.md` (approved 2026-07-13). Section references (§2.x) below point there.

## Global Constraints

- Worktree setup before anything: `xcodegen generate` (the `.xcodeproj` is gitignored) and `export ANGLESITE_PLUGIN_SRC=/Users/dwk/Developer/github.com/Anglesite/anglesite` (worktree default resolves wrong).
- Build verification command (every task): `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -5` — expected `** BUILD SUCCEEDED **`.
- **No unit tests for these tasks.** The menu code lives in the `AnglesiteApp` app target, which has no SwiftPM test target and hosted app tests don't run on CI (CLAUDE.md "Build"). Verification is per-task build + the final manual smoke (Task 11). Do not add test targets.
- All menu strings are plain literals in `Button`/`Menu`/`Toggle` (they auto-extract to the String Catalog, #528). No `String(format:)`, no interpolation in labels.
- Menu-anchor asymmetry (verified in the running app, comments in `AnglesiteApp.swift`): `CommandGroup(after:)` groups render in **declaration order**; `CommandGroup(before:)` groups render in **reverse declaration order**. `CommandMenu`s appear between View and Window in declaration order.
- Target shipping menu order (spec §2 deviation note): Anglesite · File · Edit · View · Insert · Page · Format · Arrange · Website · Window · Help.
- Every task ends with a commit; commit messages use the repo's `feat(menu):` / `refactor(menu):` style and end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: `PlannedItem` helper

**Files:**
- Create: `Sources/AnglesiteApp/MenuSkeleton.swift`

**Interfaces:**
- Produces: `PlannedItem` — `init(_ title: LocalizedStringKey, shortcut: KeyEquivalent? = nil, modifiers: EventModifiers = .command)`, a SwiftUI `View`. Every later task uses it for disabled skeleton items.

- [ ] **Step 1: Write the helper**

```swift
// Sources/AnglesiteApp/MenuSkeleton.swift
import SwiftUI

/// A disabled placeholder for a menu item whose backing feature hasn't landed yet.
/// The full north-star menu skeleton ships ahead of its features
/// (docs/superpowers/specs/2026-07-13-menubar-ia-design.md §1); every `PlannedItem`
/// corresponds to a tagged row in that spec's §2 tables. Items keep their spec'd
/// keyboard shortcut so the assignment is reserved from day one (disabled items
/// don't respond to their key equivalents).
///
/// When a feature lands, replace its `PlannedItem` with a live `Button` bound to a
/// focused value — don't add capability logic here.
struct PlannedItem: View {
    private let title: LocalizedStringKey
    private let shortcut: KeyEquivalent?
    private let modifiers: EventModifiers

    init(
        _ title: LocalizedStringKey,
        shortcut: KeyEquivalent? = nil,
        modifiers: EventModifiers = .command
    ) {
        self.title = title
        self.shortcut = shortcut
        self.modifiers = modifiers
    }

    var body: some View {
        if let shortcut {
            Button(title) {}
                .keyboardShortcut(shortcut, modifiers: modifiers)
                .disabled(true)
        } else {
            Button(title) {}
                .disabled(true)
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteApp/MenuSkeleton.swift
git commit -m "feat(menu): PlannedItem helper for the north-star menu skeleton"
```

---

### Task 2: Shortcut re-keys — Chat ⌃⌘K, preview Back/Forward ⌃⌘←/→

Frees ⌘K for Format ▸ Add Link… and ⌘[/⌘] for Format ▸ Text indent (spec §3).

**Files:**
- Modify: `Sources/AnglesiteApp/ViewMenuCommands.swift:44-52`
- Modify: `Sources/AnglesiteApp/PreviewNavigationCommands.swift:24-34`

**Interfaces:**
- Consumes: existing `\.siteWindowModel` / `\.preview` focused values (unchanged).
- Produces: ⌘K and ⌘[/⌘] unbound app-wide (Tasks 6 reserves them on `PlannedItem`s).

- [ ] **Step 1: Re-key Chat in `ViewMenuCommands.swift`**

Replace the Chat button block (including its stale comment):

```swift
            // ⌃⌘K — ⌘K is reserved for Format ▸ Add Link… per the macOS editing
            // convention (menu-bar spec §3). The shortcut lives here, not on the
            // toolbar chat button — a shortcut on a toolbar item is invisible in
            // the menu bar (the discoverability gap #512 exists to close).
            Button(model?.chatPresented == true ? "Hide Chat" : "Show Chat") {
                model?.chatPresented.toggle()
            }
            .keyboardShortcut("k", modifiers: [.command, .control])
            .disabled(model == nil)
```

- [ ] **Step 2: Re-key Back/Forward in `PreviewNavigationCommands.swift`**

Replace the Back and Forward button blocks:

```swift
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
```

Also update the file's doc comment first line to match: `/// Browser-style View-menu commands for the live preview (#514): Reload Preview ⌘R, Back ⌃⌘← / Forward ⌃⌘→, and page zoom (Actual Size ⌘0, Zoom In ⌘+, Zoom Out ⌘−).`

- [ ] **Step 3: Build**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteApp/ViewMenuCommands.swift Sources/AnglesiteApp/PreviewNavigationCommands.swift
git commit -m "feat(menu): re-key Chat to ctrl-cmd-K, preview nav to ctrl-cmd-arrows

Frees cmd-K (Add Link) and cmd-bracket (indent) per menu-bar spec section 3."
```

---

### Task 3: Page menu + File ▸ New restructure

New Page ⌘N / New Post move from File ▸ New to the new Page menu (spec §2.5); File gets a direct New Site… ⇧⌘N (§2.2). New Component… stays temporarily in File (Task 4 relocates it to Insert).

**Files:**
- Create: `Sources/AnglesiteApp/PageCommands.swift`
- Modify: `Sources/AnglesiteApp/FocusedSite.swift:50-86` (`NewContentCommands.body`)
- Modify: `Sources/AnglesiteApp/AnglesiteApp.swift:246` (declare `PageCommands()` before `SiteMenuCommands()`)

**Interfaces:**
- Consumes: `\.newContentActions` focused value (`NewContentActions.newPage/newPost/newCollection`, all `@MainActor () -> Void`).
- Produces: `PageCommands: Commands` (a `CommandMenu("Page")`).

- [ ] **Step 1: Create `PageCommands.swift`**

```swift
// Sources/AnglesiteApp/PageCommands.swift
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
```

- [ ] **Step 2: Slim `NewContentCommands` in `FocusedSite.swift`**

Replace the whole `var body: some Commands { ... }` of `NewContentCommands` (keep `openSiteFromMenu()` untouched):

```swift
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Site…") {
                openWindow(id: "sites")
                WindowRouter.shared.requestNewSite()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            // Temporary home — relocates to Insert ▸ Component when the Insert menu
            // lands (menu-bar spec §2.4).
            Button("New Component…") {
                focusedActions?.newComponent()
            }
            .disabled(focusedActions == nil)

            Button("Open Site…") {
                Task { await openSiteFromMenu() }
            }
            .keyboardShortcut("o")
        }
    }
```

- [ ] **Step 3: Declare the menu in `AnglesiteApp.swift`**

In the `.commands` block, immediately **before** the `SiteMenuCommands()` line:

```swift
            // Page menu (menu-bar spec §2.5) — declared before SiteMenuCommands so it
            // renders left of it (CommandMenus appear in declaration order).
            PageCommands()
```

- [ ] **Step 4: Build**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/PageCommands.swift Sources/AnglesiteApp/FocusedSite.swift Sources/AnglesiteApp/AnglesiteApp.swift
git commit -m "feat(menu): Page menu with New Page cmd-N; File gets direct New Site shift-cmd-N"
```

---

### Task 4: Insert menu

The full §2.4 structure. Everything is a `PlannedItem` except Component ▸ New Component… (live, relocated from File). Variant-bearing rich blocks (Table/Image/…) render as flat disabled items in the skeleton — their submenus arrive with the editor's component-library variants.

**Files:**
- Create: `Sources/AnglesiteApp/InsertCommands.swift`
- Modify: `Sources/AnglesiteApp/FocusedSite.swift` (remove the temporary New Component… button from `NewContentCommands`)
- Modify: `Sources/AnglesiteApp/AnglesiteApp.swift` (declare `InsertCommands()` immediately before `PageCommands()`)

**Interfaces:**
- Consumes: `\.newContentActions` (`newComponent`), `PlannedItem` (Task 1).
- Produces: `InsertCommands: Commands`.

- [ ] **Step 1: Create `InsertCommands.swift`**

```swift
// Sources/AnglesiteApp/InsertCommands.swift
import SwiftUI

/// The Insert menu (menu-bar spec §2.4). Every item emits semantic HTML/MDX into the page
/// source through the Component Editor write path (#496) — the menu is grammar, the editor
/// is the pen — so the whole menu enables wholesale when that write path lands. Until then
/// everything but New Component… is a PlannedItem. Rich blocks (Table…Navigation) are flat
/// disabled items here; their variant submenus arrive with the component library.
struct InsertCommands: Commands {
    @FocusedValue(\.newContentActions) private var actions

    var body: some Commands {
        CommandMenu("Insert") {
            Menu("Component") {
                PlannedItem("Component Gallery…")

                Button("New Component…") {
                    actions?.newComponent()
                }
                .disabled(actions == nil)
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
            PlannedItem("Image")
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
```

- [ ] **Step 2: Remove the temporary button from `FocusedSite.swift`**

Delete this block from `NewContentCommands.body` (added in Task 3):

```swift
            // Temporary home — relocates to Insert ▸ Component when the Insert menu
            // lands (menu-bar spec §2.4).
            Button("New Component…") {
                focusedActions?.newComponent()
            }
            .disabled(focusedActions == nil)
```

If `focusedActions` is now unused in `NewContentCommands`, also delete its `@FocusedValue(\.newContentActions) private var focusedActions` property.

- [ ] **Step 3: Declare in `AnglesiteApp.swift`**

Immediately **before** the `PageCommands()` line:

```swift
            // Insert menu (menu-bar spec §2.4) — leftmost of the custom menus.
            InsertCommands()
```

- [ ] **Step 4: Build**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/InsertCommands.swift Sources/AnglesiteApp/FocusedSite.swift Sources/AnglesiteApp/AnglesiteApp.swift
git commit -m "feat(menu): Insert menu skeleton; New Component relocates from File"
```

---

### Task 5: Website menu (renames Site; regroups; Publish ⇧⌘P)

Spec §2.9. `git mv` keeps history. "Deploy ⇧⌘D" becomes "Publish… ⇧⌘P"; "Recheck Deploy Readiness" becomes "Recheck Readiness"; "Open in Browser" becomes Preview in ▸ Default Browser; dev-server items move into a Dev Server ▸ submenu; GitHub items move into a GitHub ▸ submenu (still `#if !ANGLESITE_MAS`); assistant flows move into Assistant ▸.

**Files:**
- Rename: `Sources/AnglesiteApp/SiteMenuCommands.swift` → `Sources/AnglesiteApp/WebsiteCommands.swift`
- Modify: `Sources/AnglesiteApp/AnglesiteApp.swift` (`SiteMenuCommands()` → `WebsiteCommands()`, keep its position after `PageCommands()`)

**Interfaces:**
- Consumes: `\.siteWindowModel` focused value and its existing `canRun…`/action members (unchanged); `PlannedItem`.
- Produces: `WebsiteCommands: Commands`. The type name `SiteMenuCommands` ceases to exist — later tasks must not reference it.

- [ ] **Step 1: Rename and rewrite**

```bash
git mv Sources/AnglesiteApp/SiteMenuCommands.swift Sources/AnglesiteApp/WebsiteCommands.swift
```

Replace the file's contents:

```swift
// Sources/AnglesiteApp/WebsiteCommands.swift
import SwiftUI
import AppKit

/// The Website menu (menu-bar spec §2.9): the single home for "operate the site". Absorbs the
/// former Site menu (#511) and regroups it Configure → Preview → Publish → Quality → Grow →
/// Source → Run → Provider. Reads the `\.siteWindowModel` focused scene value; every live item
/// disables when no site window is focused, mirroring the toolbar via the shared `canRun…`
/// properties on `SiteWindowModel`.
struct WebsiteCommands: Commands {
    @FocusedValue(\.siteWindowModel) private var model

    var body: some Commands {
        CommandMenu("Website") {
            // Configure — in-app provider-backed views (spec §2.9). No site-settings
            // sheet exists yet, so all three are planned.
            PlannedItem("Website Settings…")
            PlannedItem("Analytics…")
            PlannedItem("Logs…")

            Divider()

            Menu("Preview in") {
                Button("Default Browser") { model?.openPreviewInBrowser() }
                    .disabled(model?.canOpenPreviewInBrowser != true)

                Divider()

                PlannedItem("Safari")
                PlannedItem("Chrome")
                PlannedItem("Firefox")
            }

            Divider()

            // "Publish" is the user-facing verb (Personal Publishing OS, #334); the
            // pre-deploy check still gates it, no override (spec §2.9).
            Button("Publish…") { model?.deploySite() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(model?.canRunDeploy != true)

            Button("Recheck Readiness") { model?.recheckHealth() }
                .disabled(model?.canRecheckHealth != true)

            Button("Backup") { model?.backupSite() }
                .disabled(model?.canRunBackup != true)

            Divider()

            Button("Audit") { model?.auditSite() }
                .disabled(model?.canRunAudit != true)

            // Ellipsis items open a sheet for further input, per the HIG.
            Button("Harden…") { model?.harden.openSheet() }
                .disabled(model?.canRunHarden != true)

            Button("Siri AI Readiness…") { model?.openSiriReadiness() }
                .disabled(model?.canOpenSiriReadiness != true)

            Divider()

            Button("Domain…") { model?.domain.openSheet() }
                .disabled(model?.canOpenDomain != true)

            Button("Add Integration…") { model?.openIntegrationWizard() }
                .disabled(model?.canOpenIntegrationWizard != true)

            Menu("Assistant") {
                Button("Review Copy…") { model?.presentCopyEdit() }
                    .disabled(model?.canOpenCopyEdit != true)

                Button("Social Media Plan…") { model?.presentSocialPlan() }
                    .disabled(model?.canOpenSocialPlan != true)

                Button("Design Interview…") { model?.presentDesignInterview() }
                    .disabled(model?.canOpenDesignInterview != true)
            }

            #if !ANGLESITE_MAS
            Menu("GitHub") {
                // Same identity swap as the toolbar: menus rebuild on every open, so a
                // state-dependent item is fine here (unlike the customizable toolbar, #519).
                if let remote = model?.publish.existingRemote {
                    Button("View on GitHub") { NSWorkspace.shared.open(remote.url) }
                } else {
                    Button("Publish to GitHub…") {
                        guard let model, let site = model.site else { return }
                        model.publish.publish(source: site.sourceDirectory, repoName: site.name)
                    }
                    .disabled(model?.canPublishToGitHub != true)
                }
            }
            #endif

            Divider()

            Menu("Dev Server") {
                // Dev-server lifecycle (#515). Start covers the stopped and failed states;
                // Restart is for a wedged Astro process. Enablement rules are
                // `DevServerControls` in AnglesiteCore.
                Button("Start") { model?.startDevServer() }
                    .disabled(model?.canStartDevServer != true)

                Button("Stop") { model?.stopDevServer() }
                    .disabled(model?.canStopDevServer != true)

                // ⌥⌘R: plain ⌘R stays reserved for preview reload (#514).
                Button("Restart") { model?.restartDevServer() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled(model?.canRestartDevServer != true)
            }

            Divider()

            Menu("Cloudflare") {
                PlannedItem("Dashboard")
                PlannedItem("Config…")
            }
        }
    }
}
```

- [ ] **Step 2: Update the reference in `AnglesiteApp.swift`**

Replace the `SiteMenuCommands()` line (and its comment) with:

```swift
            // Website menu: the site window's operations, regrouped (menu-bar spec §2.9).
            WebsiteCommands()
```

- [ ] **Step 3: Build**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add -A Sources/AnglesiteApp/
git commit -m "feat(menu): Site menu becomes Website; Publish shift-cmd-P; spec 2.9 groups"
```

---

### Task 6: Format menu

Spec §2.6 — all planned. Reserves ⌘B/⌘I/⌘U, alignment keys, indent ⌘[/⌘] (freed in Task 2), Add Link ⌘K (freed in Task 2), Copy/Paste Style ⌥⌘C/⌥⌘V.

**Files:**
- Create: `Sources/AnglesiteApp/FormatCommands.swift`
- Modify: `Sources/AnglesiteApp/AnglesiteApp.swift` (declare `FormatCommands()` between `PageCommands()` and `WebsiteCommands()`)

**Interfaces:**
- Consumes: `PlannedItem`.
- Produces: `FormatCommands: Commands`.

- [ ] **Step 1: Create `FormatCommands.swift`**

```swift
// Sources/AnglesiteApp/FormatCommands.swift
import SwiftUI

/// The Format menu (menu-bar spec §2.6). Font items are semantic elements
/// (strong/em/u/s/code), not visual styling. Entirely editor-gated: everything is a
/// PlannedItem until the Component Editor write path (#496) lands. Table/Image are flat
/// items here; their selection-typed submenus arrive with the editor.
struct FormatCommands: Commands {
    var body: some Commands {
        CommandMenu("Format") {
            Menu("Font") {
                PlannedItem("Strong", shortcut: "b")
                PlannedItem("Emphasis", shortcut: "i")
                PlannedItem("Underline", shortcut: "u")
                PlannedItem("Strikethrough")
                PlannedItem("Code")
            }

            Menu("Text") {
                PlannedItem("Align Left", shortcut: "{")
                PlannedItem("Align Center", shortcut: "|")
                PlannedItem("Align Right", shortcut: "}")
                PlannedItem("Justify")
                PlannedItem("Auto-Align Table Cell")

                Divider()

                PlannedItem("Increase Indent Level", shortcut: "]")
                PlannedItem("Decrease Indent Level", shortcut: "[")

                Divider()

                PlannedItem("Reverse Text Direction")
            }

            PlannedItem("Table")
            PlannedItem("Image")

            Divider()

            PlannedItem("Copy Style", shortcut: "c", modifiers: [.command, .option])
            PlannedItem("Paste Style", shortcut: "v", modifiers: [.command, .option])
            PlannedItem("Copy Animation")
            PlannedItem("Paste Animation")

            Divider()

            PlannedItem("Add Link…", shortcut: "k")
            PlannedItem("Remove Link")
        }
    }
}
```

- [ ] **Step 2: Declare in `AnglesiteApp.swift`**

Immediately **after** the `PageCommands()` line:

```swift
            // Format menu skeleton (menu-bar spec §2.6) — editor-gated.
            FormatCommands()
```

- [ ] **Step 3: Build**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteApp/FormatCommands.swift Sources/AnglesiteApp/AnglesiteApp.swift
git commit -m "feat(menu): Format menu skeleton; reserves cmd-K for Add Link"
```

---

### Task 7: Arrange menu

Spec §2.7 — all planned (contextual enablement arrives with freeform-capable editor contexts). Reserves ⌘L/⌥⌘L Lock/Unlock, ⌥⌘G/⇧⌥⌘G Group/Ungroup.

**Files:**
- Create: `Sources/AnglesiteApp/ArrangeCommands.swift`
- Modify: `Sources/AnglesiteApp/AnglesiteApp.swift` (declare `ArrangeCommands()` between `FormatCommands()` and `WebsiteCommands()`)

**Interfaces:**
- Consumes: `PlannedItem`.
- Produces: `ArrangeCommands: Commands`.

- [ ] **Step 1: Create `ArrangeCommands.swift`**

```swift
// Sources/AnglesiteApp/ArrangeCommands.swift
import SwiftUI

/// The Arrange menu (menu-bar spec §2.7). Contextual by design: items enable only when the
/// selection lives in a freeform-capable context (hero/canvas components, image overlays);
/// Group on flow content wraps the selection in a container element. Entirely editor-gated —
/// all PlannedItems until #496 grows freeform contexts.
struct ArrangeCommands: Commands {
    var body: some Commands {
        CommandMenu("Arrange") {
            PlannedItem("Bring Forward")
            PlannedItem("Bring to Front")
            PlannedItem("Send Backward")
            PlannedItem("Send to Back")

            Divider()

            Menu("Align Objects") {
                PlannedItem("Left")
                PlannedItem("Center")
                PlannedItem("Right")
                Divider()
                PlannedItem("Top")
                PlannedItem("Middle")
                PlannedItem("Bottom")
            }

            Menu("Distribute Objects") {
                PlannedItem("Horizontally")
                PlannedItem("Vertically")
            }

            Divider()

            PlannedItem("Flip Horizontally")
            PlannedItem("Flip Vertically")

            Divider()

            PlannedItem("Lock", shortcut: "l")
            PlannedItem("Unlock", shortcut: "l", modifiers: [.command, .option])

            Divider()

            PlannedItem("Group", shortcut: "g", modifiers: [.command, .option])
            PlannedItem("Ungroup", shortcut: "g", modifiers: [.command, .option, .shift])
        }
    }
}
```

- [ ] **Step 2: Declare in `AnglesiteApp.swift`**

Immediately **after** the `FormatCommands()` line:

```swift
            // Arrange menu skeleton (menu-bar spec §2.7) — editor-gated, contextual.
            ArrangeCommands()
```

- [ ] **Step 3: Build**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteApp/ArrangeCommands.swift Sources/AnglesiteApp/AnglesiteApp.swift
git commit -m "feat(menu): Arrange menu skeleton"
```

---

### Task 8: File menu skeleton — Duplicate/Save As/Move To/Revert To, Export To ▸, Advanced ▸, Set Password

Spec §2.2. `SaveCommands` gains the document verbs; `Revert to Saved` nests under Revert To ▸ (iWork shape); `FileItemCommands` gains Move To… and Share…; `ExportSiteCommands` becomes an Export To ▸ submenu and gains the Advanced/Set Password tail.

**Files:**
- Modify: `Sources/AnglesiteApp/SaveCommands.swift` (the `CommandGroup(before: .importExport)` body)
- Modify: `Sources/AnglesiteApp/FileItemCommands.swift` (same-group additions)
- Modify: `Sources/AnglesiteApp/FocusedSite.swift:127-145` (`ExportSiteCommands.body`)

**Interfaces:**
- Consumes: existing `SaveCommands`/`ExportSiteCommands` focused values (unchanged); `PlannedItem`; `modifierKeyAlternate(_:_:)` (macOS 27 SDK, verified present).
- Produces: File-menu structure later tasks don't touch.

- [ ] **Step 1: Extend `SaveCommands`**

In `Sources/AnglesiteApp/SaveCommands.swift`, replace the `CommandGroup(before: .importExport) { ... }` body so the group reads (Save is unchanged; Revert to Saved nests; Duplicate/Save As are new):

```swift
        CommandGroup(before: .importExport) {
            // Both items also disable while a save/revert is already in flight — a revert racing a
            // slow in-flight save would desync the buffer from disk (PR #532 review).
            Button("Save") {
                guard let model = siteWindowModel else { return }
                Task { await model.saveAllEdits() }
            }
            .keyboardShortcut("s")
            .disabled(siteWindowModel?.hasUnsavedEdits != true || siteWindowModel?.editCommandInFlight == true)

            // Duplicate copies the package with a fresh site UUID (#242 identity rule);
            // Save As… is its ⌥-alternate, per modern macOS document conventions
            // (menu-bar spec §2.2). Both planned until the package-copy flow exists.
            PlannedItem("Duplicate", shortcut: "s", modifiers: [.command, .shift])
                .modifierKeyAlternate(.option) {
                    PlannedItem("Save As…")
                }
        }
```

(The old flat `Button("Revert to Saved")` moves to `FileItemCommands` in Step 2 — `before:` groups render in reverse declaration order, and spec §2.2 puts Revert To ▸ after Rename/Move To, which live there.)

- [ ] **Step 2: Extend `FileItemCommands`**

In `Sources/AnglesiteApp/FileItemCommands.swift`, replace the `CommandGroup(before: .importExport) { ... }` body with:

```swift
        CommandGroup(before: .importExport) {
            Button("Rename…") { model?.renameNavigatorItem() }
                .disabled(model?.canRenameNavigatorItem != true)

            // Relocates the package; recents + (MAS) security-scoped bookmark update
            // (menu-bar spec §2.2). Planned until the move flow exists.
            PlannedItem("Move To…")

            // Revert To nests the shipped editor revert (moved from SaveCommands, same
            // action) beside the git-backed version browser (spec §4.1) — iWork's
            // File ▸ Revert To shape. Both items also disable while a save/revert is in
            // flight (PR #532 review).
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

            // ShareLink ships in the toolbar (#523); the menu item is planned until the
            // File-menu share popover (incl. "Package as Single File", spec §4.2) exists.
            PlannedItem("Share…")
        }
```

- [ ] **Step 3: Rewrite `ExportSiteCommands.body` in `FocusedSite.swift`**

```swift
    var body: some Commands {
        // Export lives after the standard Save items. Enabled only when a site window is focused.
        CommandGroup(after: .importExport) {
            Menu("Export To") {
                Button("Astro Website…") {
                    // Capture now — focus may shift between press and Task execution.
                    guard let id = focusedSiteID else { return }
                    Task { @MainActor in
                        if let site = await SiteStore.shared.find(id: id) {
                            SiteActions.exportSource(of: site)
                        }
                    }
                }
                .disabled(focusedSiteID == nil)

                // Runs the build in the site runtime and saves dist/ (spec §2.2).
                PlannedItem("Built HTML…")
            }

            // Git-repo size reduction — unused binary blobs (spec §4.3).
            PlannedItem("Reduce File Size…")

            Menu("Advanced") {
                Menu("Change File Type") {
                    // Keynote semantics; single-file is an at-rest state (spec §4.2).
                    PlannedItem("Single File")
                    PlannedItem("Package")
                }

                PlannedItem("Language & Region…")
            }

            Divider()

            // iWork-style package encryption; at-rest state (spec §4.2).
            PlannedItem("Set Password…")
        }
    }
```

- [ ] **Step 4: Build**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/SaveCommands.swift Sources/AnglesiteApp/FileItemCommands.swift Sources/AnglesiteApp/FocusedSite.swift
git commit -m "feat(menu): File document verbs, Export To submenu, Advanced, Set Password"
```

---

### Task 9: Edit menu skeleton — selection walkers, annotations, Find ▸

Spec §2.3. All planned. Find ▸ reserves the standard find keys for #517; Search Site… shares the future #520 backend.

**Files:**
- Create: `Sources/AnglesiteApp/EditMenuSkeletonCommands.swift`
- Modify: `Sources/AnglesiteApp/AnglesiteApp.swift` (declare `EditMenuSkeletonCommands()` immediately after `NavigatorEditCommands()`)

**Interfaces:**
- Consumes: `PlannedItem`.
- Produces: `EditMenuSkeletonCommands: Commands`.

- [ ] **Step 1: Create `EditMenuSkeletonCommands.swift`**

```swift
// Sources/AnglesiteApp/EditMenuSkeletonCommands.swift
import SwiftUI

/// Edit-menu skeleton items (menu-bar spec §2.3): selection walkers and annotations after
/// the pasteboard block, Find ▸ in the text-editing block. All editor/subsystem-gated
/// PlannedItems; NavigatorEditCommands owns the live Delete/Duplicate next to them.
struct EditMenuSkeletonCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            PlannedItem("Deselect All", shortcut: "a", modifiers: [.command, .shift])
            PlannedItem("Select Parent", shortcut: .upArrow, modifiers: [.command, .option])

            Divider()

            // Clears draft annotations in the current page (spec §4.4).
            PlannedItem("Remove Highlights and Comments")
        }

        CommandGroup(before: .textEditing) {
            Menu("Find") {
                PlannedItem("Find…", shortcut: "f")
                PlannedItem("Find Next", shortcut: "g")
                PlannedItem("Find Previous", shortcut: "g", modifiers: [.command, .shift])
                PlannedItem("Find & Replace…", shortcut: "f", modifiers: [.command, .option])
                PlannedItem("Use Selection for Find", shortcut: "e")

                Divider()

                // Shares the #520 site-search backend when it lands.
                PlannedItem("Search Site…")
            }
        }
    }
}
```

- [ ] **Step 2: Declare in `AnglesiteApp.swift`**

Immediately **after** the `NavigatorEditCommands()` line:

```swift
            // Edit-menu skeleton: selection walkers, annotations, Find ▸ (menu-bar spec §2.3).
            EditMenuSkeletonCommands()
```

- [ ] **Step 3: Build**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteApp/EditMenuSkeletonCommands.swift Sources/AnglesiteApp/AnglesiteApp.swift
git commit -m "feat(menu): Edit skeleton - Select Parent, annotations, Find submenu"
```

---

### Task 10: App menu, Help menu, View ▸ Inspector submenu

Spec §2.1, §2.10, §2.8. Feedback and Anglesite Website are live URL opens; the rest is planned. The flat Inspector toggle becomes the Inspector ▸ submenu.

**Files:**
- Modify: `Sources/AnglesiteApp/AnglesiteApp.swift` (app-menu group after `CommandGroup(replacing: .appInfo)`; Help group at the end of `.commands`)
- Modify: `Sources/AnglesiteApp/ViewMenuCommands.swift:59-65` (Inspector button → submenu)

**Interfaces:**
- Consumes: `\.inspectorPanel` (`InspectorPanelActions`, unchanged); `PlannedItem`.
- Produces: nothing new.

- [ ] **Step 1: App-menu items in `AnglesiteApp.swift`**

Immediately after the `CommandGroup(replacing: .appInfo) { ... }` block:

```swift
            // NOTE (as shipped): `after: .appSettings` renders ABOVE the automatic
            // Settings… item at runtime; `before: .systemServices` is what lands the
            // group between Settings… and Services per spec §2.1 (found in the T11 smoke).
            CommandGroup(before: .systemServices) {
                Divider()

                Button("Provide Anglesite Feedback…") {
                    NSWorkspace.shared.open(URL(string: "https://anglesite.dwk.io/feedback/")!)
                }

                Divider()

                // Opens the App Store analytics-consent pane when it exists (spec §2.1).
                PlannedItem("Privacy & Analytics…")
            }
```

- [ ] **Step 2: Help-menu items in `AnglesiteApp.swift`**

At the end of the `.commands` block (after the debug-pane `CommandGroup`):

```swift
            CommandGroup(after: .help) {
                PlannedItem("What's New in Anglesite")

                Button("Anglesite Website") {
                    NSWorkspace.shared.open(URL(string: "https://anglesite.dwk.io/")!)
                }
            }
```

- [ ] **Step 3: Inspector submenu in `ViewMenuCommands.swift`**

Replace the Inspector button block (keeping its ⌥⌘I comment) with:

```swift
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
```

- [ ] **Step 4: Build**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/AnglesiteApp.swift Sources/AnglesiteApp/ViewMenuCommands.swift
git commit -m "feat(menu): app-menu feedback/privacy, Help links, Inspector submenu"
```

---

### Task 11: Final verification, manual smoke, follow-up spike

**Files:**
- No source changes expected (fixes only if smoke finds defects).

- [ ] **Step 1: Full clean build**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: SwiftPM tests still green** (menu work must not break library targets)

Run: `swift test --package-path . 2>&1 | tail -5`
Expected: all suites pass (`AstroDevServerTests` port flakes are re-run, not debugged — project memory).

- [ ] **Step 3: Manual GUI smoke (human or GUI-capable agent; see project memory "GUI-verify gotchas" — kill duplicate instances first)**

Launch the built app with a site window open and verify against spec §2:

1. Menu order: Anglesite · File · Edit · View · Insert · Page · Format · Arrange · Website · Window · Help.
2. App menu: Feedback… opens the browser at anglesite.dwk.io/feedback/; Privacy & Analytics… dimmed.
3. File: New Site… ⇧⌘N; Duplicate dimmed with ⇧⌘S; holding ⌥ swaps it to Save As…; Revert To ▸ shows live Revert to Saved + dimmed Browse All Versions…; Export To ▸ Astro Website… works; Set Password… dimmed.
4. Edit: Deselect All/Select Parent/Remove Highlights and Comments dimmed; Find ▸ all dimmed with ⌘F visible; Delete/Duplicate still live on a navigator selection.
5. Insert: New Component… live; everything else dimmed; Comment shows ⇧⌘K; Choose… shows ⇧⌘V.
6. Page: New Page… ⌘N and New Post… live; Collections ▸ New Collection… live, typed items dimmed.
7. Format/Arrange: all dimmed; Add Link… shows ⌘K; pressing ⌘K does nothing (disabled), and ⌃⌘K toggles Chat.
8. View: ⌃⌘←/⌃⌘→ navigate preview history; ⌘[/⌘] do nothing; Inspector ▸ submenu shows tabs dimmed and live Show/Hide Inspector ⌥⌘I.
9. Website: Publish… ⇧⌘P deploys (or dims without a configured target); Preview in ▸ Default Browser opens the preview; Dev Server ▸ Restart ⌥⌘R works; Cloudflare ▸ items dimmed.
10. Help: Anglesite Help opens the Help Book; Anglesite Website opens the browser.

Record any failures as fix-commits before proceeding.

- [ ] **Step 4: File the menu-order spike issue**

```bash
gh issue create \
  --title "Spike: AppKit main-menu reordering for iWork menu order" \
  --body "$(cat <<'EOF'
The menu-bar spec (docs/superpowers/specs/2026-07-13-menubar-ia-design.md, §2 deviation note)
accepts SwiftUI's fixed CommandMenu placement: View renders before Insert/Page/Format/Arrange.
The iWork reference order puts the editing menus before View.

Investigate an NSApp.mainMenu reordering shim that survives SwiftUI's menu rebuilds
(focus/scene changes regenerate the main menu). Outcome: either a working enforcer with a
re-application strategy, or a documented decision to keep SwiftUI order permanently.
EOF
)"
```

- [ ] **Step 5: Update tracking**

```bash
# Format-menu line of the #518 umbrella is now skeleton-complete (backend still #517):
gh issue comment 518 --body "Menu-bar skeleton (spec 2026-07-13) shipped: Insert/Page/Format/Arrange/Website menus, re-keys (Chat ctrl-cmd-K, preview nav ctrl-cmd-arrows, Publish shift-cmd-P), File document verbs as disabled planned items. #517/#520 remain the backends for Find/search."
```

---

## Self-review notes (spec coverage)

- §2.1 → Task 10 · §2.2 → Tasks 3, 8 · §2.3 → Task 9 · §2.4 → Task 4 · §2.5 → Task 3 ·
  §2.6 → Task 6 · §2.7 → Task 7 · §2.8 → Tasks 2, 10 · §2.9 → Task 5 · §2.10 → Task 10 ·
  §3 re-keys → Tasks 2, 3, 5 (⌘N was already correct; ⇧⌘D retires with the Publish rename).
- §4 subsystems and §6 later phases are intentionally out of scope: phase 1 ships their
  menu items as `PlannedItem`s only.
- Not in phase 1 (explicit): Website Settings…/Analytics…/Logs… backends, named-browser
  preview, single-file/password, git version browser, annotations, typed collections,
  Import from Phone submenu, component-library variant submenus.
- Edit ▸ system submenus (Spelling and Grammar/Substitutions/Transformations/Speech) and
  Paste and Match Style — SwiftUI provides no placeholder surface for system text menus;
  they arrive with the editor (spec §2.3).
