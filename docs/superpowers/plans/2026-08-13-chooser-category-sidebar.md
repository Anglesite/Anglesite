# Chooser Category Sidebar Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the New Site chooser's category sidebar (Business, Personal, Blog, Portfolio, Organization, Blank), filter the theme grid by category, record the chosen category as `SITE_TYPE`, and render committed thumbnails for pack-based themes.

**Architecture:** All new state and logic lives in `NewSiteWizardModel` (already the sole owner of chooser rules per its own doc comment) — a `selectedCategory` property, a `filteredThemes` computed property, and a `selectCategory(_:)` method that updates `NewSiteDraft.siteType` and pre-selects a theme. `NewSiteWizard` (the view) becomes a thin sidebar + filtered-grid layout driven entirely by that state; it gains a `templateURL` so theme cards can resolve a pack's committed `thumbnail.png`. `SiteScaffolder` already writes `SITE_TYPE` for any non-blank `siteType` — this plan proves that path with a real test rather than changing it.

**Tech Stack:** Swift 6.4, SwiftUI (macOS), XCTest (`AnglesiteCoreTests`, existing suite).

## Global Constraints

- Design authority: `docs/superpowers/specs/2026-07-31-curated-theme-ports-design.md` §3 (`.site-config`) and §4 (Chooser UI) — implement exactly what's there, no more.
- The six sidebar categories are `[.business, .personal, .blog, .portfolio, .organization, .blank]` in that order — `SiteType.community` is excluded (hosted communities are a separate flow, `NewCommunityWizardModel`).
- `Theme.category == nil` means Blank (already true for all 8 existing built-in themes — no `themes.json` changes needed in this plan).
- No packs exist yet (theme ports are a separate future issue per #1179 slice 4) — a category with zero matching themes must degrade gracefully (empty grid, `canCreate == false`), not crash or show a phantom selection.
- Every touched file needs `swift test --package-path .` green (CONTRIBUTING.md: template-coupled/Core suites) before considering a task done.

---

### Task 1: Category state and filtering in `NewSiteWizardModel`

**Files:**
- Modify: `Sources/AnglesiteCore/NewSiteWizardModel.swift`
- Test: `Tests/AnglesiteCoreTests/NewSiteWizardModelTests.swift`

**Interfaces:**
- Produces: `NewSiteWizardModel.chooserCategories: [SiteType]` (static), `NewSiteWizardModel.selectedCategory: SiteType` (read-only property), `NewSiteWizardModel.filteredThemes: [Theme]` (computed), `NewSiteWizardModel.selectCategory(_ category: SiteType)` (method) — all consumed by Task 3 (the view).

- [ ] **Step 1: Write the failing tests**

Add to `Tests/AnglesiteCoreTests/NewSiteWizardModelTests.swift`, after the existing `catalog()` helper (around line 11):

```swift
    /// Two Blank (uncategorized) themes plus one Business and one Personal — enough to prove
    /// filtering, pre-selection, and the empty-category case without needing a real pack.
    private func categorizedCatalog() -> ThemeCatalog {
        ThemeCatalog(themes: [
            Theme(id: "classic", name: "Classic", blurb: "", swatch: [], cssVars: [:]),
            Theme(id: "warm", name: "Warm", blurb: "", swatch: [], cssVars: [:]),
            Theme(id: "astrowind", name: "AstroWind", blurb: "", swatch: [], cssVars: [:], category: "business"),
            Theme(id: "cactus", name: "Astro Cactus", blurb: "", swatch: [], cssVars: [:], category: "personal"),
        ])
    }

    // MARK: Category sidebar (#1452)

    func testStartsOnBlankCategoryShowingUncategorizedThemes() {
        let m = NewSiteWizardModel(catalog: categorizedCatalog(), isNameTaken: { _ in false })
        XCTAssertEqual(m.selectedCategory, .blank)
        XCTAssertEqual(m.filteredThemes.map(\.id), ["classic", "warm"])
    }

    func testSelectingCategoryFiltersGridAndRecordsSiteType() {
        let m = NewSiteWizardModel(catalog: categorizedCatalog(), isNameTaken: { _ in false })
        m.selectCategory(.business)
        XCTAssertEqual(m.selectedCategory, .business)
        XCTAssertEqual(m.draft.siteType, .business)
        XCTAssertEqual(m.filteredThemes.map(\.id), ["astrowind"])
        XCTAssertEqual(m.draft.themeID, "astrowind")
    }

    func testSelectingCategoryWithNoThemesLeavesEmptySelection() {
        let m = NewSiteWizardModel(catalog: categorizedCatalog(), isNameTaken: { _ in false })
        m.selectCategory(.portfolio)
        XCTAssertTrue(m.filteredThemes.isEmpty)
        XCTAssertEqual(m.draft.themeID, "")
        XCTAssertFalse(m.canCreate)
    }

    func testSwitchingBackToBlankRestoresUncategorizedGridAndPreSelects() {
        let m = NewSiteWizardModel(catalog: categorizedCatalog(), isNameTaken: { _ in false })
        m.selectCategory(.business)
        m.selectCategory(.blank)
        XCTAssertEqual(m.draft.siteType, .blank)
        XCTAssertEqual(m.filteredThemes.map(\.id), ["classic", "warm"])
        XCTAssertEqual(m.draft.themeID, "classic")   // defaultThemeID(for: .blank) == "classic", present in candidates
    }

    func testChooserCategoriesExcludesCommunity() {
        XCTAssertEqual(NewSiteWizardModel.chooserCategories,
                       [.business, .personal, .blog, .portfolio, .organization, .blank])
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter NewSiteWizardModelTests`
Expected: FAIL — `value of type 'NewSiteWizardModel' has no member 'selectedCategory'` (and similarly for `filteredThemes`, `selectCategory`, `chooserCategories`).

- [ ] **Step 3: Implement the model changes**

In `Sources/AnglesiteCore/NewSiteWizardModel.swift`, add after the `catalog` property (after line 41):

```swift
    /// The six chooser sidebar categories, in the order the sidebar lists them (design spec
    /// `docs/superpowers/specs/2026-07-31-curated-theme-ports-design.md` §4).
    /// ``SiteType/community`` is excluded — hosted communities are a separate creation flow
    /// (`NewCommunityWizardModel`), not a chooser category.
    public static let chooserCategories: [SiteType] = [.business, .personal, .blog, .portfolio, .organization, .blank]

    /// The sidebar category currently selected. Starts on ``SiteType/blank`` — today's
    /// default: all eight built-in CSS-var themes, no site type recorded.
    public private(set) var selectedCategory: SiteType = .blank
```

Add after `canCreate` (after line 78):

```swift
    /// Catalog themes matching ``selectedCategory``: themes whose `category` equals the
    /// selection's raw value, or — for ``SiteType/blank`` — themes with no `category` at all
    /// (the eight built-in CSS-var themes today; pack schema per spec §1).
    public var filteredThemes: [Theme] { Self.themes(in: catalog, matching: selectedCategory) }

    private static func themes(in catalog: ThemeCatalog, matching category: SiteType) -> [Theme] {
        if category == .blank { return catalog.themes.filter { $0.category == nil } }
        return catalog.themes.filter { $0.category == category.rawValue }
    }

    /// Switches the sidebar to `category`: records it on ``NewSiteDraft/siteType`` and
    /// pre-selects a theme from the filtered set — the category's flagship pack
    /// (``ThemeCatalog/defaultThemeID(for:)``) when present in the filtered set, else the
    /// filtered set's first entry, else no selection (a category with no ported themes yet
    /// shows an empty grid; ``canCreate`` is false until one exists).
    public func selectCategory(_ category: SiteType) {
        selectedCategory = category
        draft.siteType = category
        let candidates = Self.themes(in: catalog, matching: category)
        let preferred = catalog.defaultThemeID(for: category)
        draft.themeID = candidates.contains { $0.id == preferred } ? preferred : (candidates.first?.id ?? "")
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter NewSiteWizardModelTests`
Expected: PASS — all tests in the file, including the 5 new ones.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/NewSiteWizardModel.swift Tests/AnglesiteCoreTests/NewSiteWizardModelTests.swift
git commit -m "feat(#1452): category filtering + selection in NewSiteWizardModel"
```

---

### Task 2: Prove `SiteScaffolder` writes `SITE_TYPE` for a non-blank category

**Files:**
- Modify: `Tests/AnglesiteCoreTests/SiteScaffolderTests.swift`

**Interfaces:**
- Consumes: `SiteScaffolder.scaffold(_:)` (existing), `NewSiteWizardModelTests`'s `makeDraft()` helper pattern (not shared code — this file has its own `makeDraft()` at line 14, `siteType: .business`).

`SiteScaffolder.appendSiteConfig` (`Sources/AnglesiteCore/SiteScaffolder.swift:245`) already writes `SITE_TYPE` for any `draft.siteType != .blank` — this was built for a since-removed wizard step and never exercised end-to-end by a test. Task 1 makes the chooser capable of producing a non-blank `siteType`; this task closes the coverage gap so that path is actually proven, not just assumed.

- [ ] **Step 1: Write the failing (well, currently-unproven) test**

Add to `Tests/AnglesiteCoreTests/SiteScaffolderTests.swift`, immediately after `testChooserDraftKeepsTemplatePlaceholderAndOmitsSiteType` (after line 187's closing brace):

```swift
    /// The chooser's category sidebar (#1452) can now produce a non-blank `siteType` — prove
    /// the scaffolder actually writes it. Complements the Blank case above, which omits it.
    func testNonBlankSiteTypeWritesSiteConfigKey() async throws {
        let root = tmpDir()
        let scaffolder = makeScaffolder(root: root)
        let draft = makeDraft()   // siteType: .business
        for await _ in scaffolder.scaffold(draft) {}

        let cfg = try String(
            contentsOf: root.appendingPathComponent("acme-co.anglesite/Source/.site-config"),
            encoding: .utf8)
        XCTAssertTrue(cfg.contains("SITE_TYPE=business"))
    }
```

- [ ] **Step 2: Run it**

Run: `swift test --package-path . --filter SiteScaffolderTests/testNonBlankSiteTypeWritesSiteConfigKey`
Expected: PASS immediately — this is characterization, not new behavior. If it fails, `appendSiteConfig`'s existing conditional (`SiteScaffolder.swift:245`) regressed; stop and investigate before continuing to Task 3.

- [ ] **Step 3: Commit**

```bash
git add Tests/AnglesiteCoreTests/SiteScaffolderTests.swift
git commit -m "test(#1452): cover SITE_TYPE written for a non-blank chooser draft"
```

---

### Task 3: Sidebar UI + filtered grid in `NewSiteWizard`

**Files:**
- Modify: `Sources/AnglesiteApp/NewSiteWizard.swift`
- Modify: `Sources/AnglesiteApp/SitesLauncherView.swift` (thread `templateURL` through to the wizard)

**Interfaces:**
- Consumes: `NewSiteWizardModel.chooserCategories`, `.selectedCategory`, `.filteredThemes`, `.selectCategory(_:)` (Task 1); `SiteType.label`/`.symbol` (already exist, `NewSiteDraft.swift:11-47`).
- Produces: `NewSiteWizard(model:scaffolder:templateURL:onComplete:onCancel:)` — the new `templateURL: URL` parameter, consumed by Task 4's thumbnail rendering in the same file.

No unit tests for this task — this codebase has no SwiftUI view-body test target (`Tests/AnglesiteAppTests` tests view *models*, not view bodies); correctness is proven by Task 1's model tests plus a build + manual smoke check at the end of this plan.

- [ ] **Step 1: Add `templateURL` to `NewSiteWizard` and thread it from `SitesLauncherView`**

In `Sources/AnglesiteApp/NewSiteWizard.swift`, add a stored property after `let scaffolder: SiteScaffolder` (line 11):

```swift
    let templateURL: URL
```

In `Sources/AnglesiteApp/SitesLauncherView.swift`:

1. Add a field to `ScaffoldingContext` (line 443-447):

```swift
    private struct ScaffoldingContext {
        let catalog: ThemeCatalog
        let scaffolder: SiteScaffolder
        let templateURL: URL
        let isNameTaken: (String) -> Bool
    }
```

2. Pass it at the `return` (line 529):

```swift
        return ScaffoldingContext(catalog: catalog, scaffolder: scaffolder, templateURL: templateURL, isNameTaken: isNameTaken)
```

3. Add a field to `NewSiteSession` (line 45-49):

```swift
    private struct NewSiteSession: Identifiable {
        let id = UUID()
        let model: NewSiteWizardModel
        let scaffolder: SiteScaffolder
        let templateURL: URL
    }
```

4. Pass it at construction (line 539):

```swift
        newSiteSession = NewSiteSession(model: model, scaffolder: context.scaffolder, templateURL: context.templateURL)
```

5. Pass it into the view (line 99-101):

```swift
            NewSiteWizard(
                model: session.model,
                scaffolder: session.scaffolder,
                templateURL: session.templateURL,
```

- [ ] **Step 2: Replace `chooserStep` with a sidebar + filtered grid**

In `Sources/AnglesiteApp/NewSiteWizard.swift`, replace the entire `chooserStep` computed property (lines 33-52) with:

```swift
    private var chooserStep: some View {
        HStack(alignment: .top, spacing: 0) {
            categorySidebar
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose a Template").font(.title2.bold())
                if model.filteredThemes.isEmpty {
                    emptyCategoryState
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 12) {
                            ForEach(model.filteredThemes) { theme in
                                ThemeChooserCard(
                                    theme: theme,
                                    isSelected: model.draft.themeID == theme.id,
                                    onSelect: { model.draft.themeID = theme.id },
                                    onCreate: {
                                        model.draft.themeID = theme.id
                                        create()
                                    }
                                )
                            }
                        }
                    }
                }
            }.padding(24)
        }
    }

    /// The six chooser categories (`NewSiteWizardModel.chooserCategories`), each a plain-style
    /// button so the whole row is one hit target and VoiceOver reads a single control per row.
    private var categorySidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(NewSiteWizardModel.chooserCategories, id: \.self) { category in
                let isSelected = model.selectedCategory == category
                Button { model.selectCategory(category) } label: {
                    Label(category.label, systemImage: category.symbol)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(12)
        .frame(width: 160)
    }

    /// Shown when a category has no matching themes yet (every non-Blank category, until
    /// #1179 slice 4 ports real themes into it) — an empty grid with no explanation would
    /// read as a bug.
    private var emptyCategoryState: some View {
        VStack {
            Spacer()
            Text("No themes in this category yet").font(.callout).foregroundStyle(.secondary)
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
```

- [ ] **Step 3: Update the frame to fit the sidebar**

In `Sources/AnglesiteApp/NewSiteWizard.swift`, the wizard's fixed frame (line 21) is `560x460` — wide enough for the old single-pane grid, not a sidebar + grid. Change it to:

```swift
        .frame(width: 720, height: 480)
```

- [ ] **Step 4: Build**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED. `NewSiteWizard`'s new `templateURL` property is unused by `chooserStep` until Task 4 wires it into the card views — that's fine, an unread stored property isn't a compiler error, so this task builds standalone.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/NewSiteWizard.swift Sources/AnglesiteApp/SitesLauncherView.swift
git commit -m "feat(#1452): category sidebar in the New Site chooser"
```

---

### Task 4: Render committed thumbnails for pack themes

**Files:**
- Modify: `Sources/AnglesiteApp/NewSiteWizard.swift`

**Interfaces:**
- Consumes: `Theme.thumbnail: String?` (already decoded, `Sources/AnglesiteCore/ThemeCatalog.swift:35`), `templateURL: URL` (Task 3).

No packs exist yet, so this path has no real fixture to exercise end-to-end (that's the honest state — theme ports are a future issue). This task implements the contract from spec §4 ("Cards — pack entries render their committed `thumbnail.png`") so it's ready the moment a pack lands, verified by build success and a synthetic manual check (Step 3).

- [ ] **Step 1: Thread `templateURL` into the two card views**

In `Sources/AnglesiteApp/NewSiteWizard.swift`, first update `chooserStep`'s `ThemeChooserCard(...)` call (added in Task 3 Step 2) to pass the property Task 3 already stored but didn't use yet:

```swift
                                ThemeChooserCard(
                                    theme: theme,
                                    templateURL: templateURL,
                                    isSelected: model.draft.themeID == theme.id,
                                    onSelect: { model.draft.themeID = theme.id },
                                    onCreate: {
                                        model.draft.themeID = theme.id
                                        create()
                                    }
                                )
```

Then update the `ThemeChooserCard` struct itself (lines 137-163):

```swift
private struct ThemeChooserCard: View {
    let theme: Theme
    let templateURL: URL
    let isSelected: Bool
    let onSelect: () -> Void
    let onCreate: () -> Void

    @State private var isHovering = false
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isHoverActive: Bool { isHovering && controlActiveState != .inactive && !isSelected }

    var body: some View {
        Button(action: onSelect) {
            ThemePreviewCard(theme: theme, templateURL: templateURL, isSelected: isSelected, isHoverActive: isHoverActive)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded(onCreate))
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: isHoverActive)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(theme.name). \(theme.blurb)")
        .accessibilityValue(isSelected ? "Selected" : "")
    }
}
```

- [ ] **Step 2: Render a committed thumbnail when the theme has one**

Update `ThemePreviewCard` (lines 167-211) — add the `templateURL` property and a `thumbnailImage` computed property, and branch the top mock block on it:

```swift
private struct ThemePreviewCard: View {
    let theme: Theme
    let templateURL: URL
    let isSelected: Bool
    let isHoverActive: Bool

    private var primary: Color { Color(hex: theme.cssVars["color-primary"] ?? "#333333") }
    private var accent: Color { Color(hex: theme.cssVars["color-accent"] ?? "#888888") }

    /// Loaded synchronously — pack thumbnails are small, committed, bundle-local PNGs (same
    /// assumption `WebsiteIconInstaller` makes for site icons), so there's no async/loading
    /// state to model.
    private var thumbnailImage: NSImage? {
        guard let thumbnail = theme.thumbnail else { return nil }
        return NSImage(contentsOf: templateURL.appendingPathComponent(thumbnail))
    }

    private var borderColor: Color {
        if isSelected { return Color.accentColor }
        if isHoverActive { return Color.accentColor.opacity(0.4) }
        return Color.clear
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let thumbnailImage {
                    Image(nsImage: thumbnailImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .accessibilityHidden(true)
                } else {
                    syntheticMock
                }
            }
            Text(theme.name).font(.subheadline.bold())
            Text(theme.blurb).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(isHoverActive ? Color.accentColor.opacity(0.08) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderColor, lineWidth: 2))
    }

    /// The two-color miniature page mock for CSS-var themes (#1071) — unchanged from before
    /// thumbnails existed, just extracted so `body` can branch on `thumbnailImage`.
    private var syntheticMock: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Circle().fill(accent).frame(width: 6, height: 6)
                Capsule().fill(Color.white.opacity(0.9)).frame(width: 34, height: 4)
                Spacer()
            }
            .padding(6)
            .background(primary)
            RoundedRectangle(cornerRadius: 2).fill(accent.opacity(0.85)).frame(height: 22)
                .padding(.horizontal, 6)
            Capsule().fill(Color.primary.opacity(0.5)).frame(width: 70, height: 4)
                .padding(.horizontal, 6)
            Capsule().fill(Color.primary.opacity(0.25)).frame(height: 3)
                .padding(.horizontal, 6)
            Capsule().fill(Color.primary.opacity(0.25)).frame(width: 90, height: 3)
                .padding(.horizontal, 6).padding(.bottom, 8)
        }
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
        .accessibilityHidden(true)
    }
}
```

- [ ] **Step 3: Build and manually verify the synthetic-mock path still renders (the thumbnail path has no fixture to click through yet)**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED.

Then launch the built app, open File ▸ New ▸ Site, and confirm:
- The sidebar shows Business, Personal, Blog, Portfolio, Organization, Blank (in that order), Blank selected by default, showing all 8 existing themes exactly as before.
- Clicking each non-Blank category shows the "No themes in this category yet" empty state (expected — no packs exist).
- Clicking back to Blank restores the 8-theme grid with the same card mocks as before (proves `syntheticMock` extraction didn't change rendering).
- Create/double-click still scaffolds a site as before.

- [ ] **Step 4: Run the full Core suite once more**

Run: `swift test --package-path .`
Expected: PASS (no regressions in `AnglesiteCoreTests`, `AnglesiteSiteModelTests`, `AnglesiteBridgeTests`, and — on Swift 6.4+/Xcode 27 — `AnglesiteIntentsTests`).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/NewSiteWizard.swift
git commit -m "feat(#1452): render committed pack thumbnails in theme cards"
```

---

### Task 5: Update the epic tracking checklist

**Files:**
- No repo files — a `gh issue` update.

- [ ] **Step 1: Check off slice 3 on #1179**

Run:
```bash
gh issue edit 1179 --body "$(gh issue view 1179 --json body -q .body | sed 's/- \[ \] \*\*Chooser sidebar\*\*/- [x] **Chooser sidebar**/')"
```

- [ ] **Step 2: Open the PR**

Follow `CONTRIBUTING.md` ▸ "Commits and pull requests" exactly: PR template headings (Summary, Paired PR check, Test plan), `Closes #1452` closing keyword. This is app-only (no MCP schema change) — no paired sidecar PR needed.
