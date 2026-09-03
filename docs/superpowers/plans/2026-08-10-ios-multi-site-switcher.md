# iOS multi-site switcher polish Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the iOS Micropub posting shell (`SiteSplitScreen`) visible site context and a fast switcher, and remember the last-selected site across launches.

**Architecture:** A new `@Observable` model, `SiteSelectionModel` (`AnglesiteIOS`), owns which site is selected and persists it to `UserDefaults`; `SiteSplitScreen` (`AnglesiteMobile`) replaces its bare `@State` selection with this model and adds a small new `SiteSwitcherMenu` view to both its content and detail panes' toolbars.

**Tech Stack:** Swift 6.4, SwiftUI, `Observation` framework, Swift Testing (`import Testing`), SwiftPM (`AnglesiteIOS`/`AnglesiteIOSTests` targets) + XcodeGen/`xcodebuild` (`AnglesiteMobile` app target).

## Global Constraints

- Toolchain: macOS 27+ / Xcode 27+ / Swift 6.4. Apple frameworks only — no new third-party dependencies.
- Persisted site not found on restore (deleted, moved, iCloud not yet synced) → silently fall back to no selection. No new error UI for this case.
- The switcher UI is hidden entirely when fewer than 2 sites are discovered.
- `SiteSelectionModel.restoreSelection(from:)` must never overwrite an already-active `selectedSite`.
- Commit subjects ≤72 characters (`CONTRIBUTING.md` ▸ "Commits and pull requests").
- `swift test --package-path .` and the `AnglesiteMobile` iOS-simulator `xcodebuild` must both pass before this is done.

---

### Task 1: `SiteSelectionModel`

**Files:**
- Create: `Sources/AnglesiteIOS/SiteSelectionModel.swift`
- Test: `Tests/AnglesiteIOSTests/SiteSelectionModelTests.swift`

**Interfaces:**
- Consumes: `SitePickerModel.DiscoveredSite` (`Sources/AnglesiteIOS/SitePickerModel.swift:15-21`) — `Identifiable, Sendable, Hashable`, with `id: UUID`, `displayName: String`, `packageURL: URL`. Its memberwise init is internal, reachable from `Tests/AnglesiteIOSTests` via `@testable import AnglesiteIOS` (same pattern already used in `Tests/AnglesiteIOSTests/MicropubOnboardingModelTests.swift:98-99` and `StoredMicropubSessionsTests.swift`).
- Produces (consumed by Task 3):
  ```swift
  @MainActor
  @Observable
  public final class SiteSelectionModel {
      public private(set) var selectedSite: SitePickerModel.DiscoveredSite?
      public init(defaults: UserDefaults = .standard)
      public func select(_ site: SitePickerModel.DiscoveredSite?)
      public func restoreSelection(from sites: [SitePickerModel.DiscoveredSite])
  }
  ```

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteIOSTests/SiteSelectionModelTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteIOS

/// A `final class` (not a `struct`) so `deinit` can drop the throwaway `UserDefaults` suite,
/// mirroring `AppSettingsTests`' scratch-suite pattern (`Tests/AnglesiteCoreTests/AppSettingsTests.swift`).
@MainActor
final class SiteSelectionModelTests {
    private let suiteName: String
    private let defaults: UserDefaults

    init() {
        let suite = "test-site-selection-\(UUID().uuidString)"
        suiteName = suite
        defaults = UserDefaults(suiteName: suite)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeSite(name: String, id: UUID = UUID()) -> SitePickerModel.DiscoveredSite {
        SitePickerModel.DiscoveredSite(
            id: id, displayName: name, packageURL: URL(fileURLWithPath: "/tmp/\(name).anglesite"))
    }

    @Test("select persists the site and updates selectedSite")
    func selectPersists() {
        let model = SiteSelectionModel(defaults: defaults)
        let site = makeSite(name: "My Blog")

        model.select(site)

        #expect(model.selectedSite == site)
        #expect(defaults.string(forKey: "siteSelection.selectedSiteID") == site.id.uuidString)
    }

    @Test("select(nil) clears the persisted site")
    func selectNilClears() {
        let model = SiteSelectionModel(defaults: defaults)
        model.select(makeSite(name: "My Blog"))

        model.select(nil)

        #expect(model.selectedSite == nil)
        #expect(defaults.string(forKey: "siteSelection.selectedSiteID") == nil)
    }

    @Test("restoreSelection selects the persisted site when present in the list")
    func restoreSelectsPersistedSite() {
        let site = makeSite(name: "My Blog")
        let other = makeSite(name: "Other Site")
        let writer = SiteSelectionModel(defaults: defaults)
        writer.select(site)

        let restored = SiteSelectionModel(defaults: defaults)
        restored.restoreSelection(from: [other, site])

        #expect(restored.selectedSite == site)
    }

    @Test("restoreSelection leaves selectedSite nil when the persisted site isn't in the list")
    func restoreLeavesNilWhenMissing() {
        let site = makeSite(name: "My Blog")
        let writer = SiteSelectionModel(defaults: defaults)
        writer.select(site)

        let restored = SiteSelectionModel(defaults: defaults)
        restored.restoreSelection(from: [makeSite(name: "Different Site")])

        #expect(restored.selectedSite == nil)
    }

    @Test("restoreSelection leaves selectedSite nil when nothing was persisted")
    func restoreLeavesNilWhenNothingPersisted() {
        let model = SiteSelectionModel(defaults: defaults)

        model.restoreSelection(from: [makeSite(name: "My Blog")])

        #expect(model.selectedSite == nil)
    }

    @Test("restoreSelection never overwrites an already-active selection")
    func restoreDoesNotOverwriteActiveSelection() {
        let active = makeSite(name: "Active Site")
        let persisted = makeSite(name: "Persisted Site")
        let writer = SiteSelectionModel(defaults: defaults)
        writer.select(persisted)

        let model = SiteSelectionModel(defaults: defaults)
        model.select(active)
        model.restoreSelection(from: [persisted, active])

        #expect(model.selectedSite == active)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path . --filter SiteSelectionModelTests`
Expected: FAIL to compile — `SiteSelectionModel` doesn't exist yet.

- [ ] **Step 3: Write the implementation**

Create `Sources/AnglesiteIOS/SiteSelectionModel.swift`:

```swift
// Sources/AnglesiteIOS/SiteSelectionModel.swift
import Foundation
import Observation

/// Owns which site the iOS shell (`SiteSplitScreen`, #869) currently has selected, and persists
/// that choice across launches (#71 "multi-site UX" follow-up). Deliberately separate from
/// `SitePickerModel`, which only discovers sites and is also used standalone by `SitePickerScreen`
/// (no selection concept there) — folding selection into it would blur that model's one job.
@MainActor
@Observable
public final class SiteSelectionModel {
    public private(set) var selectedSite: SitePickerModel.DiscoveredSite?

    private let defaults: UserDefaults
    private static let selectedSiteIDKey = "siteSelection.selectedSiteID"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// User-driven selection (a sidebar tap or the switcher menu). Always wins immediately and
    /// persists the choice; `nil` clears both.
    public func select(_ site: SitePickerModel.DiscoveredSite?) {
        selectedSite = site
        if let site {
            defaults.set(site.id.uuidString, forKey: Self.selectedSiteIDKey)
        } else {
            defaults.removeObject(forKey: Self.selectedSiteIDKey)
        }
    }

    /// Called once discovery produces a list. Resolves the persisted site ID against `sites` and
    /// selects it if found. A no-op when a site is already selected — a user tapping around before
    /// discovery/restore settles must never be clobbered by a late restore — or when nothing is
    /// persisted, or the persisted site isn't in `sites` (deleted, moved, not yet synced): in every
    /// one of those cases the screen's existing empty/picker state is already correct.
    public func restoreSelection(from sites: [SitePickerModel.DiscoveredSite]) {
        guard selectedSite == nil,
              let storedIDString = defaults.string(forKey: Self.selectedSiteIDKey),
              let storedID = UUID(uuidString: storedIDString),
              let match = sites.first(where: { $0.id == storedID })
        else { return }
        selectedSite = match
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path . --filter SiteSelectionModelTests`
Expected: PASS, all 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteIOS/SiteSelectionModel.swift Tests/AnglesiteIOSTests/SiteSelectionModelTests.swift
git commit -m "feat(#71): add SiteSelectionModel for persisted site choice"
```

---

### Task 2: `SiteSwitcherMenu` view

**Files:**
- Create: `Sources/AnglesiteMobile/SiteSwitcherMenu.swift`

**Interfaces:**
- Consumes: `SitePickerModel.DiscoveredSite` (as above).
- Produces (consumed by Task 3):
  ```swift
  struct SiteSwitcherMenu: View {
      let sites: [SitePickerModel.DiscoveredSite]
      let selected: SitePickerModel.DiscoveredSite?
      var onSelect: (SitePickerModel.DiscoveredSite) -> Void
  }
  ```

This is a plain SwiftUI view with no model of its own (same convention as `ComposerPane` in
`SiteSplitScreen.swift`) — there's no SwiftPM test target for `AnglesiteMobile` views in this
codebase (they're verified by building + manual simulator smoke, consistent with how
`SitePickerScreen`/`SiteSignInScreen` are handled), so this task has no automated test step.

- [ ] **Step 1: Write the view**

Create `Sources/AnglesiteMobile/SiteSwitcherMenu.swift`:

```swift
// Sources/AnglesiteMobile/SiteSwitcherMenu.swift
import SwiftUI
import AnglesiteIOS

/// A compact site switcher for a toolbar (#71 "multi-site UX"): shows the current site's name with
/// a chevron, and a `Menu` listing every discovered site with a checkmark on the current one.
/// `SiteSplitScreen` attaches this to both its content and detail panes so the current site stays
/// visible even when the sidebar column isn't (iPhone's collapsed `NavigationStack`).
struct SiteSwitcherMenu: View {
    let sites: [SitePickerModel.DiscoveredSite]
    let selected: SitePickerModel.DiscoveredSite?
    var onSelect: (SitePickerModel.DiscoveredSite) -> Void

    var body: some View {
        Menu {
            ForEach(sites) { site in
                Button {
                    onSelect(site)
                } label: {
                    if site == selected {
                        Label(site.displayName, systemImage: "checkmark")
                    } else {
                        Text(verbatim: site.displayName)
                    }
                }
            }
        } label: {
            Label(selected?.displayName ?? "", systemImage: "chevron.down")
                .labelStyle(.titleAndIcon)
        }
    }
}
```

This file can't be independently compiled here: `Sources/AnglesiteMobile` is an Xcode-only app
target (not listed in `Package.swift`), so there is no `swift build` invocation that touches it.
Task 3 Step 5's `xcodebuild` is the first real compile check for this file, once it's actually
referenced from `SiteSplitScreen.swift` — Xcode/`xcodebuild` only type-checks files that are part
of a build phase's source list, which XcodeGen populates from `project.yml`'s `Sources/AnglesiteMobile`
path glob, so this new file is already picked up automatically; no `project.yml` change is needed.

- [ ] **Step 2: Commit**

```bash
git add Sources/AnglesiteMobile/SiteSwitcherMenu.swift
git commit -m "feat(#71): add SiteSwitcherMenu toolbar view"
```

---

### Task 3: Wire `SiteSelectionModel` + `SiteSwitcherMenu` into `SiteSplitScreen`

**Files:**
- Modify: `Sources/AnglesiteMobile/SiteSplitScreen.swift`

**Interfaces:**
- Consumes: `SiteSelectionModel` (Task 1), `SiteSwitcherMenu` (Task 2).
- Produces: no new public API — `SiteSplitScreen` stays an internal `View`.

This task has no automated test (SwiftUI view wiring, same as Task 2) — verified by building the
`AnglesiteMobile` scheme and a manual simulator smoke covering the four checks the design calls
out.

- [ ] **Step 1: Replace the bare `@State` selection with `SiteSelectionModel`**

In `Sources/AnglesiteMobile/SiteSplitScreen.swift`, replace line 20:

```swift
    @State private var selectedSite: SitePickerModel.DiscoveredSite?
```

with:

```swift
    @State private var siteSelection = SiteSelectionModel()
```

Then replace every other read of `selectedSite` in the file with `siteSelection.selectedSite`:

- Line 91 (`if selectedSite != nil {` inside the sidebar's `Content` section): →
  `if siteSelection.selectedSite != nil {`
- Line 131 (`if let selectedTypeID { ... }` / `if selectedSite != nil { return .allPosts }` inside
  `sidebarSelection`'s `get`): → `if siteSelection.selectedSite != nil { return .allPosts }`
- Line 169 (`if selectedSite == nil {` in `contentPane`): → `if siteSelection.selectedSite == nil {`
- Line 183 (`if let site = selectedSite {` in the `.signedOut` case): →
  `if let site = siteSelection.selectedSite {`
- Line 223 (`if let session, let site = selectedSite, let selection {` in `detailPane`): →
  `if let session, let site = siteSelection.selectedSite, let selection {`
- Line 244 (`guard let site = selectedSite else {` in `resolveSession()`): →
  `guard let site = siteSelection.selectedSite else {`
- Line 253 (`guard site == selectedSite else { return }` in `resolveSession()`): →
  `guard site == siteSelection.selectedSite else { return }`

- [ ] **Step 2: Replace the sidebar's inline site-select logic with a shared helper**

Replace the `sidebarSelection` binding's `.site(let id)` case (originally lines 138-146):

```swift
                case .site(let id):
                    guard case .sites(let sites) = sitePicker.state,
                          let site = sites.first(where: { $0.id == id })
                    else { return }
                    if site != selectedSite {
                        selectedSite = site
                        selectedTypeID = nil
                        selection = nil
                    }
```

with:

```swift
                case .site(let id):
                    guard case .sites(let sites) = sitePicker.state,
                          let site = sites.first(where: { $0.id == id })
                    else { return }
                    selectSite(site)
```

Add the new helper as a private method on `SiteSplitScreen`, near `resolveSession()`:

```swift
    /// Single path for every site-switch trigger (sidebar row, switcher menu) so the
    /// reset-filter-and-selection side effect can't drift between call sites.
    private func selectSite(_ site: SitePickerModel.DiscoveredSite) {
        guard site != siteSelection.selectedSite else { return }
        siteSelection.select(site)
        selectedTypeID = nil
        selection = nil
    }
```

- [ ] **Step 3: Restore the persisted selection once discovery has results**

In `body`, add an `.onChange(of:)` alongside the existing `.task` modifiers:

```swift
    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationTitle(Text("Anglesite"))
        } content: {
            contentPane
                .navigationTitle(contentTitle)
        } detail: {
            detailPane
        }
        .task { await sitePicker.refresh() }
        .task(id: siteSelection.selectedSite?.id) { await resolveSession() }
        .onChange(of: sitePicker.state) { _, newState in
            if case .sites(let sites) = newState {
                siteSelection.restoreSelection(from: sites)
            }
        }
    }
```

- [ ] **Step 4: Add the switcher to the content and detail panes**

Add a computed property near `postTypes` that reads the current site list once:

```swift
    /// The discovered site list, or empty when discovery hasn't produced one yet — feeds
    /// `SiteSwitcherMenu`, which is hidden entirely below 2 sites.
    private var switcherSites: [SitePickerModel.DiscoveredSite] {
        guard case .sites(let sites) = sitePicker.state else { return [] }
        return sites
    }

    @ToolbarContentBuilder
    private func siteSwitcherToolbarItem() -> some ToolbarContent {
        if switcherSites.count >= 2 {
            ToolbarItem(placement: .navigation) {
                SiteSwitcherMenu(sites: switcherSites, selected: siteSelection.selectedSite, onSelect: selectSite)
            }
        }
    }
```

Replace `contentPane` (originally lines 167-203) with:

```swift
    @ViewBuilder
    private var contentPane: some View {
        if siteSelection.selectedSite == nil {
            ContentUnavailableView {
                Label("Pick a Site", systemImage: "globe")
            } description: {
                Text("Choose one of your sites to see its posts.")
            }
        } else {
            Group {
                switch sessionState {
                case .none, .checking:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .signedOut:
                    if let site = siteSelection.selectedSite {
                        SiteSignInScreen(site: site) {
                            Task { await resolveSession() }
                        }
                    }
                case .ready:
                    if let postList {
                        PostListScreen(
                            model: postList,
                            collection: selectedCollection,
                            selection: $selection
                        )
                        .toolbar {
                            ToolbarItem(placement: .primaryAction) {
                                newPostButton
                            }
                        }
                    }
                }
            }
            .toolbar {
                siteSwitcherToolbarItem()
            }
        }
    }
```

Replace `detailPane` (originally lines 221-241) with:

```swift
    @ViewBuilder
    private var detailPane: some View {
        if let session, let site = siteSelection.selectedSite, let selection {
            ComposerPane(
                selection: selection,
                session: session,
                siteID: site.id,
                registry: registry,
                postList: postList,
                onSent: { Task { await postList?.refresh() } }
            )
            // A fresh pane per selection: composer state must never leak across posts.
            .id(selection)
            .toolbar {
                siteSwitcherToolbarItem()
            }
        } else {
            ContentUnavailableView {
                Label("Nothing Selected", systemImage: "square.and.pencil")
            } description: {
                Text("Pick a post to edit, or start a new one.")
            }
        }
    }
```

Add the `import AnglesiteIOS` requirement check: `SiteSplitScreen.swift` already imports
`AnglesiteIOS` (line 3), so no import changes are needed — `SiteSwitcherMenu` lives in the same
`AnglesiteMobile` target and needs no extra import either.

- [ ] **Step 5: Regenerate the Xcode project and build the iOS target**

Run:
```bash
xcodegen generate --quiet
xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMobile \
  -configuration Debug -destination 'generic/platform=iOS Simulator' build
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Manual simulator smoke test**

Using the iOS Simulator (a real `.anglesite` package with at least 2 sites signed in via Micropub
is needed for full coverage — if unavailable, note in the PR body which checks couldn't run):

1. Launch the app with 2+ discovered sites, none previously selected — confirm no switcher appears
   until you pick one (fewer than 2 selectable is not the "hide" case here; this checks first-launch
   behavior).
2. Pick a site, confirm the switcher (site name + chevron) appears in the post-list toolbar.
3. Tap the switcher, confirm it lists all sites with a checkmark on the current one; pick another —
   confirm the post list refreshes for the new site and the switcher updates.
4. Open a post into the composer, confirm the switcher also appears there and switching sites from
   the composer navigates back to that site's post list (via the existing `selection = nil` reset).
5. Force-quit and relaunch the app — confirm it lands directly on the last-selected site's post
   list instead of "Pick a Site."
6. With only 1 discovered site, confirm the switcher never appears.

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteMobile/SiteSplitScreen.swift
git commit -m "feat(#71): wire site selection + switcher into SiteSplitScreen"
```

---

### Task 4: Full verification pass

**Files:** None (verification only).

**Interfaces:** None.

- [ ] **Step 1: Run the full SwiftPM suite**

Run: `swift test --package-path .`
Expected: PASS, including the new `SiteSelectionModelTests`.

- [ ] **Step 2: Build the macOS app target (confirm nothing in shared code broke)**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Re-confirm the iOS build**

Run:
```bash
xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMobile \
  -configuration Debug -destination 'generic/platform=iOS Simulator' build
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Diff review against `CONTRIBUTING.md`**

Confirm: commit subjects ≤72 chars; no drive-by unrelated changes (in particular,
`RemoteSessionScreen.swift`/`RemoteSessionModel.swift` — the dead, unwired #71 remote-sandbox
path — stay untouched, that's separate cleanup, not this plan's scope); PR body uses the
template's exact headings (Summary / Paired PR check / Test plan) with `Closes #71` only if this
was the issue's last remaining piece (it isn't — Siri annotations and the blocked live e2e smoke
remain, so use a non-closing reference like the audit-script PR did).

- [ ] **Step 5: Open the PR**

Follow `CONTRIBUTING.md` ▸ "Commits and pull requests": use `.github/PULL_REQUEST_TEMPLATE.md`'s
exact section headings, note this is app-only (no paired sidecar PR — no MCP schema touched),
and list the manual simulator smoke results from Task 3 Step 6 in the Test plan section.
