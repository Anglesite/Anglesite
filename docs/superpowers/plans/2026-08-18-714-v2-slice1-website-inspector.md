# #714 v2 Slice 1: Website Inspector + Row Removal — Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the Pages-style Website inspector (Document analog) with mutually-exclusive activation against the selection inspector, and remove the navigator's website-title row.

**Architecture:** A new `WebsiteInspectorModel` (owned by `SiteWindowModel`, keyed to the open site) loads/saves the site identity basics; a new `WebsiteInspectorView` renders it with the same Metadata | Style tab shape as `SiteInspectorView`. Scene state gains an `ActiveSiteInspector` enum so exactly one inspector occupies the window's `.inspector` slot. `buildSiteURLTree` stops emitting the website node.

**Tech Stack:** Swift 6.4 / SwiftUI (macOS 27), SwiftPM tests (Swift Testing), `PlistDocumentIO`, `SiteLanguageAsset`, `SiteConfigFile`, `SiteFileTree`.

**Spec:** `docs/superpowers/specs/2026-08-18-website-design-window-v2-design.md` §1, §3.2, §3.3, §5 (menu part), Slices ▸ 1.

## Global Constraints

- Toolchain: Xcode 27+, Swift 6.4. Run all commands from the worktree root; if `Anglesite.xcodeproj` is missing run `xcodegen generate` first.
- Plain SwiftUI + actors — no third-party libraries.
- **#968/#969 discipline:** every inspector presentation/selection transition must land as one synchronous MainActor transaction *after* any awaits; never let `@SceneStorage("siteInspector.shown")` observe a transient-nil selection as an explicit hide. Read the comment blocks at `Sources/AnglesiteApp/SiteWindowModel.swift:1228-1244` before touching the gate.
- **Frozen toolbar IDs:** this slice does NOT add or remove toolbar items (that's v2 slice 3). Only the existing `inspector` item's *action closure* changes.
- New user-visible strings require the localization-catalog sync (CONTRIBUTING.md ▸ "Commit String Catalog updates") — done once in Task 6, not per task.
- `AnglesiteAppTests` execute only locally (CI compiles but cannot run them) — run `swift test` on this machine before every commit that touches `Sources/AnglesiteApp`.
- Full-suite `swift test` runs must not run concurrently with another agent's (FoundationModels contention); check `pgrep -fl swift-test` first.
- Commits: conventional, subject ≤72 chars, issue number in subject.

---

### Task 1: Remove the website node from the URL tree

**Files:**
- Modify: `Sources/AnglesiteCore/SiteURLTree.swift`
- Modify: `Sources/AnglesiteApp/SiteNavigatorModel.swift`
- Modify: `Sources/AnglesiteApp/SiteNavigatorView.swift:148-168` (icon switch)
- Test: `Tests/AnglesiteCoreTests/SiteURLTreeTests.swift`

**Interfaces:**
- Consumes: existing `buildSiteURLTree(websiteTitle:pages:posts:feedCollections:contentTypes:)`.
- Produces: `buildSiteURLTree(pages:posts:feedCollections:contentTypes:)` — `websiteTitle` parameter and `URLTreeNode.Kind.website` case removed. `NavigatorTarget.websiteSettings` (in `NavigatorTree.swift`) is **kept** — menus still route through `SiteWindowModel.openWebsiteSettings()`.

- [ ] **Step 1: Update the tests to the new contract**

In `Tests/AnglesiteCoreTests/SiteURLTreeTests.swift`: delete/rewrite every assertion that expects a first row with `id == "website"` / `kind == .website` (and the title-fallback test for it). The tree's first row is now home (`/`) when an index page exists. Update every `buildSiteURLTree(websiteTitle: ..., ...)` call to drop the argument. Add one regression test:

```swift
@Test func treeHasNoWebsiteRow() {
    let home = SiteContentGraph.Page(/* use the file's existing page fixture helper */)
    let tree = buildSiteURLTree(pages: [home], posts: [], feedCollections: [])
    #expect(tree.allSatisfy { $0.id != "website" })
    #expect(tree.first?.kind == .home)
}
```

(Use the fixture/builder helpers already present in that test file for constructing `Page`/`Post` values — do not invent new ones.)

- [ ] **Step 2: Run the suite to verify it fails to compile / fails**

Run: `swift test --filter SiteURLTreeTests`
Expected: compile error (extra argument `websiteTitle:`) — the new signature doesn't exist yet. Note: `--filter` still compiles the whole package, so the app target must also be updated before this compiles; treat steps 2–4 as one red→green cycle across both files.

- [ ] **Step 3: Implement the removal**

In `Sources/AnglesiteCore/SiteURLTree.swift`:
- Delete `case website` from `URLTreeNode.Kind` and the `.website` branch of `var target`.
- Change the builder signature to `buildSiteURLTree(pages:posts:feedCollections:contentTypes:)`; delete the `trimmed`/`websiteNode` block; `var nodes = [websiteNode]` becomes building directly from `root.buildTopLevel(...)`. Update the type's doc comments (they describe the pinned website row).

In `Sources/AnglesiteApp/SiteNavigatorModel.swift`:
- Remove the `websiteTitle` stored property (line ~30), the `websiteTitle:` parameter of `start(site:websiteTitle:)` (line ~61), the assignment at line ~125, and the argument at the `buildSiteURLTree` call (line ~296). Chase the callers of `start(...)` and the title-update path (`grep -n "websiteTitle" Sources/AnglesiteApp/*.swift`) and remove the threading — the callers live in `SiteWindowModel`.

In `Sources/AnglesiteApp/SiteNavigatorView.swift`:
- Delete the `case .website:` branch of `icon(for:)` and update its `#714 icon table` comment.

Then sweep for stragglers: `grep -rn '"website"\|\.website\b' Sources/AnglesiteCore/SiteURLTree.swift Sources/AnglesiteApp/SiteNavigator*.swift Tests/` — the only intended remaining references are `NavigatorTarget.websiteSettings` ones. `SiteWindowModel.applyNavigatorSelection`'s `.websiteSettings` branch (line ~1262) **stays** — it is the routing value's handler, now reached only via future callers, and removing it would orphan the enum case.

- [ ] **Step 4: Run tests to verify green**

Run: `swift test --filter SiteURLTreeTests && swift test --filter NavigatorTreeTests`
Expected: PASS. Then the app-side suites: `swift test --filter SiteNavigatorModel` (run whatever navigator suites exist in `Tests/AnglesiteAppTests` — `ls Tests/AnglesiteAppTests | grep -i navigator`).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SiteURLTree.swift Sources/AnglesiteApp/SiteNavigatorModel.swift Sources/AnglesiteApp/SiteNavigatorView.swift Tests/
git commit -m "feat(#714): remove website row from navigator URL tree"
```

---

### Task 2: `WebsiteInspectorModel`

**Files:**
- Create: `Sources/AnglesiteApp/WebsiteInspectorModel.swift`
- Test: `Tests/AnglesiteAppTests/WebsiteInspectorModelTests.swift`

**Interfaces:**
- Consumes: `PlistDocumentIO.load(_:fileManager:)` / `.save(_:to:fileManager:)` (`Sources/AnglesiteCore/PlistDocumentIO.swift:118,140`), `SiteLanguageAsset.parseSettings(from:)` / `.install(_:siteDirectory:)`, `WebsiteAnalyticsAsset.bestHost(from:fallback:)`, `SiteFileTree.layout(for:)` + `.scan(siteRoot:)`, and `PlistEditorModel.isWebsiteTitleEntry` (make that static predicate `internal` instead of `private` — same module, it's the single owner of "which plist entry is the title").
- Produces:

```swift
@MainActor @Observable
final class WebsiteInspectorModel {
    let packageURL: URL          // the .anglesite package root
    private(set) var isLoading: Bool
    private(set) var loadError: String?
    var title: String            // bindable; dirty vs savedTitle
    var lang: String             // bindable; dirty vs savedLang
    private(set) var domain: String?          // nil = not configured (read-only)
    private(set) var stylesheets: [FileRef]   // SiteFileTree.scan[.styles] ?? []
    var isDirty: Bool
    private(set) var saveError: String?
    init(packageURL: URL)
    func load() async
    @discardableResult func saveTitle() async -> Bool
    @discardableResult func saveLang() async -> Bool
}
```

- [ ] **Step 1: Write the failing tests**

`Tests/AnglesiteAppTests/WebsiteInspectorModelTests.swift` (Swift Testing). Build a fixture `.anglesite` package in a temp dir: `Info.plist` written via `PlistDocumentIO.save` (copy the entry set an existing `AnglesitePackage`/plist test fixture in `Tests/` uses — find one with `grep -rln "Info.plist" Tests/AnglesiteAppTests | head`), `Source/.site-config` containing `DOMAIN=example.com` and `SITE_LANG=en` (match the keys `SiteLanguageAsset.parseSettings` and `WebsiteAnalyticsAsset.bestHost` actually read — confirm in those files before writing the fixture), and `Source/src/styles/global.css`.

```swift
@Test func loadPopulatesIdentityAndStyles() async throws {
    let pkg = try makeFixturePackage(title: "My Site", domain: "example.com", lang: "en")
    let model = WebsiteInspectorModel(packageURL: pkg)
    await model.load()
    #expect(model.title == "My Site")
    #expect(model.lang == "en")
    #expect(model.domain == "example.com")
    #expect(model.stylesheets.map(\.name) == ["global.css"])
}

@Test func saveTitleRoundTrips() async throws {
    let pkg = try makeFixturePackage(title: "My Site", domain: nil, lang: "en")
    let model = WebsiteInspectorModel(packageURL: pkg)
    await model.load()
    model.title = "Renamed"
    #expect(model.isDirty)
    #expect(await model.saveTitle())
    let reread = WebsiteInspectorModel(packageURL: pkg)
    await reread.load()
    #expect(reread.title == "Renamed")
    #expect(!model.isDirty)
}

@Test func missingDomainReadsNil() async throws { /* fixture without DOMAIN → model.domain == nil */ }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter WebsiteInspectorModelTests`
Expected: compile failure (type doesn't exist).

- [ ] **Step 3: Implement**

`WebsiteInspectorModel`: `load()` resolves `SiteFileTree.layout(for: packageURL)`, then in one `Task.detached(priority: .userInitiated)` block reads: plist entries from `layout.infoPlist` (title = first entry matching `PlistEditorModel.isWebsiteTitleEntry`, mirroring `PlistEditorModel.websiteTitle`'s getter), `.site-config` contents from `layout.sourceDir` (lang via `SiteLanguageAsset.parseSettings(from:)`; domain via `WebsiteAnalyticsAsset.bestHost(from:fallback:"")`, mapping empty → nil), and `SiteFileTree.scan(siteRoot: packageURL)[.styles] ?? []` — then assigns all results back on the MainActor in one hop. `saveTitle()` re-runs `PlistDocumentIO.load`, replaces the title entry's value, `PlistDocumentIO.save`s (off-main), updates `savedTitle`. `saveLang()` mirrors `PlistEditorModel.saveLang` (`SiteLanguageAsset.install(Settings(lang: lang), siteDirectory: layout.sourceDir)` off-main). Both guard `isDirty`-per-field and set `saveError` on throw. No conflict-detection machinery in v1 (the deep editor keeps that); keep the model ~150 lines.

- [ ] **Step 4: Run to verify green**

Run: `swift test --filter WebsiteInspectorModelTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/WebsiteInspectorModel.swift Sources/AnglesiteApp/PlistEditorModel.swift Tests/AnglesiteAppTests/WebsiteInspectorModelTests.swift
git commit -m "feat(#714): WebsiteInspectorModel for site identity basics"
```

---

### Task 3: `WebsiteInspectorView`

**Files:**
- Create: `Sources/AnglesiteApp/WebsiteInspectorView.swift`

**Interfaces:**
- Consumes: `WebsiteInspectorModel` (Task 2), `SiteInspectorTab` (reused for the segmented shape).
- Produces: `struct WebsiteInspectorView: View { @Bindable var model: WebsiteInspectorModel; let openStylesheet: (FileRef) -> Void; let openMoreSettings: () -> Void }`

- [ ] **Step 1: Implement the view** (view-only task; behavior is covered by Task 2's model tests and Task 6's smoke run)

Mirror `SiteInspectorView`'s chrome exactly (segmented `Picker` + `Divider` + content, `.padding(8)`), persisting via `@SceneStorage("websiteInspector.tab") private var tab: SiteInspectorTab = .metadata`. Content:

```swift
@ViewBuilder private var content: some View {
    switch tab {
    case .metadata:
        Form {
            TextField("Title", text: $model.title)
                .onSubmit { Task { await model.saveTitle() } }
            TextField("Language", text: $model.lang)
                .onSubmit { Task { await model.saveLang() } }
            LabeledContent("Domain", value: model.domain ?? "Not configured")
            if let saveError = model.saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout)
            }
            Section {
                Button("More Settings…") { openMoreSettings() }
            }
        }
        .formStyle(.grouped)
    case .style:
        List(model.stylesheets) { sheet in
            Button { openStylesheet(sheet) } label: {
                Label(sheet.name, systemImage: "doc.text")
            }
            .buttonStyle(.plain)
        }
        .overlay {
            if model.stylesheets.isEmpty {
                ContentUnavailableView("No stylesheets", systemImage: "paintbrush")
            }
        }
    }
}
```

Add `@Bindable var model` (it's `@Observable`). Commit each field on focus loss too, matching `PlistEditorView`'s `titleFocused`/`languageFocused` pattern (`@FocusState` + `.onChange(of:)` calling the save — copy that shape from `PlistEditorView.swift:44-70`). Language keeps the BCP-47 caption `Text` from `PlistEditorView.swift:268` verbatim (reuse the same string so no new localization key is minted for it).

- [ ] **Step 2: Build**

Run: `swift build`
Expected: compiles clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteApp/WebsiteInspectorView.swift
git commit -m "feat(#714): WebsiteInspectorView metadata + styles tabs"
```

---

### Task 4: Mutually-exclusive activation + window wiring

**Files:**
- Modify: `Sources/AnglesiteApp/SiteInspectorView.swift` (add the enum at top)
- Modify: `Sources/AnglesiteApp/SiteWindow.swift:26,180-184,196-204,298-307,632-641`
- Modify: `Sources/AnglesiteApp/ViewMenuCommands.swift:6-19`
- Modify: `Sources/AnglesiteApp/SiteWindowModel.swift` (model ownership)
- Test: `Tests/AnglesiteAppTests/SiteWindowModelTests.swift` (or the existing model-test file that covers `inspectorSelection` — find with `grep -rln "inspectorSelection" Tests/AnglesiteAppTests`)

**Interfaces:**
- Consumes: `WebsiteInspectorModel`/`View` (Tasks 2–3), existing `inspectorShown` scene storage and `inspectorSelection` gate.
- Produces:

```swift
/// Which inspector occupies the window's trailing panel (Pages: Format vs Document).
enum ActiveSiteInspector: String { case selection, website }

struct InspectorPanelActions {           // ViewMenuCommands.swift — grown, not replaced
    let isShown: Bool                    // selection inspector visible
    let isAvailable: Bool
    let toggle: @MainActor () -> Void
    let isWebsiteShown: Bool             // website inspector visible
    let toggleWebsite: @MainActor () -> Void
}
```

and on `SiteWindowModel`: `private(set) var websiteInspector: WebsiteInspectorModel?` + `func ensureWebsiteInspectorLoaded()`.

- [ ] **Step 1: Write the failing model test**

In the model-test file, add: creating the model and calling `ensureWebsiteInspectorLoaded()` with a loaded site creates `websiteInspector` keyed to the site's `packageURL`; calling it again returns the same instance; `handleSiteChanged()` clears it.

```swift
@Test func websiteInspectorLifecycle() async throws {
    let model = /* use the file's existing SiteWindowModel test harness */
    /* load fixture site … */
    model.ensureWebsiteInspectorLoaded()
    let first = model.websiteInspector
    #expect(first != nil)
    model.ensureWebsiteInspectorLoaded()
    #expect(model.websiteInspector === first)
    model.handleSiteChanged()
    #expect(model.websiteInspector == nil)
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter websiteInspectorLifecycle` → compile failure.

- [ ] **Step 3: Implement**

`SiteWindowModel`: stored `private(set) var websiteInspector: WebsiteInspectorModel?`. `ensureWebsiteInspectorLoaded()` — if nil and `site != nil`: create with `site.packageURL`, then `Task { await websiteInspector?.load() }`. Clear it in `handleSiteChanged()` and in `close(...)` alongside the other per-site teardown (find where `componentEditor` is torn down and mirror it).

`SiteWindow`:
- Add `@SceneStorage("siteInspector.active") private var activeInspector: ActiveSiteInspector = .selection`.
- `inspectorPresented` binding becomes:

```swift
let inspectorPresented = Binding(
    get: {
        inspectorShown && (activeInspector == .website || model.inspectorSelection != nil)
    },
    set: { newValue in
        // Website inspector always has content, so its show/hide is always an explicit
        // user choice. Selection keeps the #968 guard: never persist an auto-hide
        // caused by a transient-nil selection.
        if activeInspector == .website || model.inspectorSelection != nil {
            inspectorShown = newValue
        }
    }
)
```

- `.inspector` content: `switch activeInspector` — `.website`: `if let websiteModel = model.websiteInspector { WebsiteInspectorView(model: websiteModel, openStylesheet: { model.openFile($0) }, openMoreSettings: { model.openWebsiteSettings() }) }` with a `.task(id: model.site?.id) { model.ensureWebsiteInspectorLoaded() }` on the container; `.selection`: the existing `SiteInspectorView` branch unchanged. Keep `inspectorColumnWidth(min: 260, ideal: 300, max: 420)` applied to both.
- `focusedValues(for:)`: extend the `InspectorPanelActions` construction:

```swift
.focusedSceneValue(\.inspectorPanel, InspectorPanelActions(
    isShown: inspectorShown && activeInspector == .selection && model.inspectorSelection != nil,
    isAvailable: model.inspectorSelection != nil,
    toggle: {
        if activeInspector == .selection { inspectorShown.toggle() }
        else { activeInspector = .selection; inspectorShown = true }
    },
    isWebsiteShown: inspectorShown && activeInspector == .website,
    toggleWebsite: {
        if activeInspector == .website { inspectorShown.toggle() }
        else { activeInspector = .website; inspectorShown = true }
    }
))
```

- The existing `inspector` toolbar item's action (SiteWindow.swift:632-641): point it at the same selection-toggle closure logic (extract the two closures as private funcs `toggleSelectionInspector()` / `toggleWebsiteInspector()` on `SiteWindow` so toolbar, focused value, and menu share one implementation).

Every branch above is a synchronous MainActor mutation — no awaits between reading `activeInspector` and writing `inspectorShown` (#968 discipline).

- [ ] **Step 4: Run to verify green** — `swift test --filter websiteInspectorLifecycle`, then the whole model suite: `swift test --filter SiteWindowModel`. Expected: PASS, no regressions in the existing inspector-gate tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/SiteWindow.swift Sources/AnglesiteApp/SiteWindowModel.swift Sources/AnglesiteApp/SiteInspectorView.swift Sources/AnglesiteApp/ViewMenuCommands.swift Tests/
git commit -m "feat(#714): mutually-exclusive website/selection inspectors"
```

---

### Task 5: View menu — Show Website Inspector (⌥⌘J)

**Files:**
- Modify: `Sources/AnglesiteApp/ViewMenuCommands.swift:64-81`

**Interfaces:**
- Consumes: `InspectorPanelActions.isWebsiteShown` / `.toggleWebsite` (Task 4).
- Produces: menu item **View ▸ Show/Hide Website Inspector**, ⌥⌘J.

- [ ] **Step 1: Implement**

Directly after the `Menu("Inspector") { ... }` block (still inside the same `CommandGroup`), add:

```swift
Button(inspectorPanel?.isWebsiteShown == true ? "Hide Website Inspector" : "Show Website Inspector") {
    inspectorPanel?.toggleWebsite()
}
.keyboardShortcut("j", modifiers: [.command, .option])
.disabled(inspectorPanel == nil)
```

(No availability gating beyond a focused site window — the Website inspector always has content. ⌥⌘J verified unclaimed.)

- [ ] **Step 2: Build + verify in the running app**

Run: `swift build`, then per `docs/testing-macos-app.md` build and launch the app; verify: ⌥⌘J shows the Website inspector with the site's title/language/domain; ⌥⌘I switches to the selection inspector (with a page selected); each toggle hides its own panel on second press; the navigator has no website row; Website ▸ Website Settings… still opens the deep-config surface; "More Settings…" does the same.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteApp/ViewMenuCommands.swift
git commit -m "feat(#714): View menu Show Website Inspector, opt-cmd-J"
```

---

### Task 6: Full verification + localization catalog

**Files:**
- Modify: `Sources/AnglesiteApp/Localizable.xcstrings` (generated sync)

- [ ] **Step 1: Full test suite** — check `pgrep -fl swift-test` is clear, then run `swift test --package-path .`. Expected: PASS (template-markup suites included).

- [ ] **Step 2: App build + string catalog sync** — run the exact CONTRIBUTING.md recipe: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`, then the `xcstringstool sync` command from CONTRIBUTING.md ▸ "Commit String Catalog updates" **scoped to this worktree's own `BUILD_DIR`** with `--skip-marking-strings-stale`. Review the diff: only keys added by this slice (Website-inspector strings, the menu item) may appear; discard and re-sync if foreign keys show up.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteApp/Localizable.xcstrings
git commit -m "feat(#714): localization catalog for website inspector"
```

- [ ] **Step 4: Re-check against CONTRIBUTING.md, then PR**

Re-read CONTRIBUTING.md ▸ "Commits and pull requests". PR body from `.github/PULL_REQUEST_TEMPLATE.md`'s actual headings (Summary / Paired PR check / Test plan) — no MCP schema changes, so Paired PR check states none needed. Reference the spec; the PR advances #714 but does not close it (three v2 slices remain), so write `Part of #714`, **not** a closing keyword.
