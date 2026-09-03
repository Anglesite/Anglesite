# File menu: New Site / Open Site / Open Recent — Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add **New Site** (`⌘N`), **Open Site…** (`⌘O`), and an **Open Recent ▸** submenu to the macOS File menu, available from any window, reusing the launcher's existing create/import logic.

**Architecture:** A `CommandGroup(replacing: .newItem)` in the SwiftUI `App` provides the three commands. New Site routes to the launcher via `WindowRouter` (which already bridges App Intents to `openWindow`); Open Site… runs a window-independent `NSOpenPanel` through a shared `SiteActions` helper; Open Recent reads a `@MainActor @Observable` `RecentSitesModel` that mirrors `SiteStore.changeStream()` and is shaped by a pure `RecentSites.select(...)` function unit-tested in `AnglesiteCore`.

**Tech Stack:** Swift 6.4 / SwiftUI (macOS 27+), Swift Testing (`import Testing`), SwiftPM. AppKit `NSOpenPanel`/`NSAlert`. No new dependencies.

## Global Constraints

- **Toolchain:** Xcode 27+ / Swift 6.4.
- **No third-party frameworks** (Apple-only).
- **Process spawning stays in `ProcessSupervisor`** — not touched by this work, but do not introduce `Process()` anywhere.
- **MAS gating:** sandbox-only code goes behind `#if ANGLESITE_MAS`. That symbol is **not** set on the `AnglesiteCore`/`AnglesiteBridge` SPM packages, so any `#if ANGLESITE_MAS` in those packages is a no-op — keep MAS-only code (e.g. `SecurityScopedBookmark` minting) in the **app target** (`Sources/AnglesiteApp`).
- **Branch base:** stacked on `#188` (`SiteStore.changeStream()` must exist). Merges after #188.
- **Tests:** `swift test --package-path .` only covers `AnglesiteCore`/`AnglesiteBridge` (no app-target unit suite). App-layer wiring is verified by `xcodebuild` builds + manual smoke. Two e2e tests (`AppliesEditEndToEndTests`, `MCPClientHTTPEndToEndTests`) fail without a sibling `anglesite` plugin checkout — that is the pre-existing baseline, not a regression.
- **Labels verbatim:** menu items are exactly `New Site`, `Open Site…` (with a real `…` ellipsis, U+2026), `Open Recent`, and the empty placeholder `No Recent Sites`.

## Existing interfaces this plan relies on (verified)

- `SiteStore.Site`: `id: String`, `name: String`, `path: URL`, `isValid: Bool`, `missingSentinels: [String]`, `lastSeen: Date`, `bookmarkData: Data?` — `Sendable, Codable, Equatable, Identifiable`.
- `actor SiteStore` (`SiteStore.shared`):
  - `func load() async throws`
  - `func refresh() async throws -> [Site]`
  - `func add(_ url: URL) async throws -> Site`
  - `func setBookmark(_ data: Data, for id: String) throws`
  - `nonisolated func changeStream() -> AsyncStream<[Site]>` — **yields the current snapshot immediately on subscribe**, then on every mutation (`bufferingNewest(1)`).
- `enum SecurityScopedBookmark { static func create(for url: URL) throws -> Data }` (AnglesiteCore).
- `WindowRouter` (AnglesiteIntents, `@MainActor @Observable`): `static let shared`, `var requested: String?`, `func requestOpen(siteID:)`.
- `SitesLauncherView` (AnglesiteApp): private `openFolder()`, private `@MainActor presentNewSite() async`, `@State showingNewSite`, `refreshSites()`, `open(site:)`; `@Environment(\.openWindow)`.
- `AnglesiteApp` (AnglesiteApp): `Window("Sites", id: "sites")` scene with a `.commands { }` block; `WindowGroup(for: String.self)`; `AppDelegate.applicationDidFinishLaunching`.

## File structure

| File | Responsibility |
|---|---|
| `Sources/AnglesiteCore/RecentSites.swift` | **New.** Pure `select(from:limit:)` — sort by `lastSeen` desc, cap. |
| `Tests/AnglesiteCoreTests/RecentSitesTests.swift` | **New.** Unit tests for `select`. |
| `Sources/AnglesiteIntents/WindowRouter.swift` | **Modify.** Add `newSiteRequested` + `requestNewSite()`. |
| `Sources/AnglesiteApp/SiteActions.swift` | **New.** `pickAndRegisterSite()` — shared NSOpenPanel→add→bookmark. |
| `Sources/AnglesiteApp/RecentSitesModel.swift` | **New.** `@MainActor @Observable` mirror over `changeStream()`. |
| `Sources/AnglesiteApp/SitesLauncherView.swift` | **Modify.** `openFolder()` → `SiteActions`; observe `newSiteRequested`; guard `presentNewSite()`. |
| `Sources/AnglesiteApp/AnglesiteApp.swift` | **Modify.** `CommandGroup(replacing: .newItem)`; hold `RecentSitesModel`; `openSiteFromMenu()`; start the model in `AppDelegate`. |

Task order: Core (testable foundation) → router → shared action → model → launcher refactor → menu wiring → verification. Each task ends with a build or test gate and a commit.

---

### Task 1: Pure recent-sites selection (`RecentSites.select`)

**Files:**
- Create: `Sources/AnglesiteCore/RecentSites.swift`
- Test: `Tests/AnglesiteCoreTests/RecentSitesTests.swift`

**Interfaces:**
- Consumes: `SiteStore.Site` (existing).
- Produces: `RecentSites.select(from: [SiteStore.Site], limit: Int = 10) -> [SiteStore.Site]` — used by Task 4 (`RecentSitesModel`).

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/RecentSitesTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

// `RecentSites.select` is the pure ordering+capping rule behind the File ▸ Open Recent
// submenu. It lives in Core so it is covered by `swift test` (there is no app-target unit
// suite). The App's `RecentSitesModel` feeds it `SiteStore.changeStream()` snapshots.

@Suite("RecentSites.select")
struct RecentSitesTests {

    /// Build a Site with a controllable `lastSeen`; other fields are irrelevant to ordering.
    private func site(_ name: String, lastSeen: Date, isValid: Bool = true) -> SiteStore.Site {
        SiteStore.Site(
            id: "/Sites/\(name)",
            name: name,
            path: URL(fileURLWithPath: "/Sites/\(name)"),
            isValid: isValid,
            missingSentinels: [],
            lastSeen: lastSeen
        )
    }

    @Test("orders most-recently-seen first")
    func ordersByLastSeenDescending() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let input = [
            site("old", lastSeen: base),
            site("new", lastSeen: base.addingTimeInterval(100)),
            site("mid", lastSeen: base.addingTimeInterval(50)),
        ]
        let names = RecentSites.select(from: input).map(\.name)
        #expect(names == ["new", "mid", "old"])
    }

    @Test("caps the result at limit, keeping the most recent")
    func capsAtLimit() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let input = (0..<15).map { i in
            site("s\(i)", lastSeen: base.addingTimeInterval(Double(i)))
        }
        let result = RecentSites.select(from: input, limit: 10)
        #expect(result.count == 10)
        #expect(result.first?.name == "s14")   // most recent
        #expect(result.last?.name == "s5")     // 10th most recent
        #expect(!result.contains { $0.name == "s4" })  // dropped
    }

    @Test("returns empty for empty input")
    func emptyInput() {
        #expect(RecentSites.select(from: []).isEmpty)
    }

    @Test("returns all when fewer than limit")
    func fewerThanLimit() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let input = [site("a", lastSeen: base), site("b", lastSeen: base.addingTimeInterval(1))]
        #expect(RecentSites.select(from: input, limit: 10).count == 2)
    }

    @Test("includes invalid sites (the menu disables them, it does not hide them)")
    func includesInvalid() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let input = [site("broken", lastSeen: base, isValid: false)]
        let result = RecentSites.select(from: input)
        #expect(result.count == 1)
        #expect(result[0].isValid == false)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path . --filter RecentSitesTests 2>&1 | tail -20`
Expected: FAIL — compile error, `cannot find 'RecentSites' in scope`.

- [ ] **Step 3: Write the minimal implementation**

Create `Sources/AnglesiteCore/RecentSites.swift`:

```swift
import Foundation

/// Pure ordering + capping rule for the File ▸ Open Recent submenu.
///
/// Kept free of SwiftUI/actor state so it is unit-testable under `swift test`
/// (the App target has no unit suite). The App's `RecentSitesModel` pipes
/// `SiteStore.changeStream()` snapshots through this and publishes the result.
public enum RecentSites {
    /// Most-recently-seen first, capped at `limit`.
    ///
    /// Invalid sites are *kept* — the menu shows them disabled, matching the launcher
    /// list — so callers see exactly what the registry holds, just trimmed and ordered.
    public static func select(from sites: [SiteStore.Site], limit: Int = 10) -> [SiteStore.Site] {
        Array(sites.sorted { $0.lastSeen > $1.lastSeen }.prefix(limit))
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path . --filter RecentSitesTests 2>&1 | tail -20`
Expected: PASS — all 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/RecentSites.swift Tests/AnglesiteCoreTests/RecentSitesTests.swift
git commit -m "feat(core): RecentSites.select for the Open Recent submenu"
```

---

### Task 2: Add the new-site routing signal to `WindowRouter`

**Files:**
- Modify: `Sources/AnglesiteIntents/WindowRouter.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `WindowRouter.shared.newSiteRequested: Bool` and `func requestNewSite()` — used by Task 6 (menu) and Task 5 (launcher observer).

- [ ] **Step 1: Add the signal**

Edit `Sources/AnglesiteIntents/WindowRouter.swift`. After the existing `requestOpen(siteID:)` method, inside the class, add:

```swift
    /// Set true by File ▸ New Site (which can't host the wizard sheet itself). The "Sites"
    /// launcher observes this, runs `presentNewSite()`, then clears the flag. Mirrors
    /// `requested`/`requestOpen` for the open-existing path.
    public var newSiteRequested = false

    public func requestNewSite() { newSiteRequested = true }
```

The full class body becomes:

```swift
@MainActor
@Observable
public final class WindowRouter {
    public static let shared = WindowRouter()
    private init() {}

    /// The site id the intent asked to open; the scene clears it after handling.
    public var requested: String?

    public func requestOpen(siteID: String) { requested = siteID }

    /// Set true by File ▸ New Site (which can't host the wizard sheet itself). The "Sites"
    /// launcher observes this, runs `presentNewSite()`, then clears the flag. Mirrors
    /// `requested`/`requestOpen` for the open-existing path.
    public var newSiteRequested = false

    public func requestNewSite() { newSiteRequested = true }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build --package-path . 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteIntents/WindowRouter.swift
git commit -m "feat(intents): WindowRouter.requestNewSite signal for the File menu"
```

---

### Task 3: Shared import helper (`SiteActions.pickAndRegisterSite`)

**Files:**
- Create: `Sources/AnglesiteApp/SiteActions.swift`

**Interfaces:**
- Consumes: `SiteStore.shared.add(_:)`, `SecurityScopedBookmark.create(for:)`, `SiteStore.shared.setBookmark(_:for:)`.
- Produces: `@MainActor SiteActions.pickAndRegisterSite() async throws -> SiteStore.Site?` — used by Task 5 (launcher `openFolder`) and Task 6 (menu `openSiteFromMenu`).

- [ ] **Step 1: Create the helper**

Create `Sources/AnglesiteApp/SiteActions.swift`:

```swift
import AppKit
import AnglesiteCore

/// File-menu / launcher actions that are window-independent. Today this is just the
/// "open an existing folder as a site" flow, extracted from `SitesLauncherView.openFolder()`
/// so the File ▸ Open Site… command and the launcher footer share one implementation —
/// in particular the MAS security-scoped-bookmark minting, which must live in exactly one place.
@MainActor
enum SiteActions {
    /// Run the folder picker, register the chosen project with `SiteStore`, and (on MAS)
    /// mint + persist a security-scoped bookmark so the grant survives relaunch.
    ///
    /// - Returns: the newly registered site, or `nil` if the user cancelled the panel.
    /// - Throws: whatever `SiteStore.add` / bookmark creation throws (caller surfaces it).
    static func pickAndRegisterSite() async throws -> SiteStore.Site? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose an Anglesite project directory."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        let site = try await SiteStore.shared.add(url)
        #if ANGLESITE_MAS
        // The panel grant is the only chance to mint a scoped bookmark — persist it now so
        // the grant survives relaunch. SiteWindow resolves it and holds access.
        let bookmark = try SecurityScopedBookmark.create(for: url)
        try await SiteStore.shared.setBookmark(bookmark, for: site.id)
        #endif
        return site
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteApp/SiteActions.swift
git commit -m "refactor(app): extract SiteActions.pickAndRegisterSite for reuse"
```

---

### Task 4: Recent-sites observable mirror (`RecentSitesModel`)

**Files:**
- Create: `Sources/AnglesiteApp/RecentSitesModel.swift`

**Interfaces:**
- Consumes: `RecentSites.select(from:limit:)` (Task 1), `SiteStore.shared.load()/refresh()/changeStream()`.
- Produces: `@MainActor @Observable RecentSitesModel` with `static let shared`, `private(set) var sites: [SiteStore.Site]`, `func start()` — read by Task 6 (menu), started by Task 6 (AppDelegate).

- [ ] **Step 1: Create the model**

Create `Sources/AnglesiteApp/RecentSitesModel.swift`:

```swift
import Foundation
import Observation
import AnglesiteCore

/// Synchronous, live-updating mirror of the site registry for the File ▸ Open Recent submenu.
///
/// SwiftUI menus can't `await`, but `SiteStore` is an `actor`. This `@MainActor @Observable`
/// holds the current selection so the menu reads it synchronously, and stays current by
/// consuming `SiteStore.changeStream()` (the #188 broadcast), shaping each snapshot through
/// `RecentSites.select`.
@MainActor
@Observable
final class RecentSitesModel {
    static let shared = RecentSitesModel()
    private init() {}

    /// Most-recent-first, capped. Drives the Open Recent submenu.
    private(set) var sites: [SiteStore.Site] = []

    private var started = false

    /// Begin mirroring the registry. Idempotent — safe to call once at launch.
    func start() {
        guard !started else { return }
        started = true
        Task {
            // Populate from disk + scan first so the menu is correct before any mutation.
            try? await SiteStore.shared.load()
            if let scanned = try? await SiteStore.shared.refresh() {
                sites = RecentSites.select(from: scanned)
            }
            // Then track every mutation. `changeStream()` also re-emits the current snapshot
            // on subscribe, which simply reaffirms what we just set.
            for await snapshot in SiteStore.shared.changeStream() {
                sites = RecentSites.select(from: snapshot)
            }
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteApp/RecentSitesModel.swift
git commit -m "feat(app): RecentSitesModel mirror over SiteStore.changeStream"
```

---

### Task 5: Wire the launcher to the shared helper and the new-site signal

**Files:**
- Modify: `Sources/AnglesiteApp/SitesLauncherView.swift`

**Interfaces:**
- Consumes: `SiteActions.pickAndRegisterSite()` (Task 3), `WindowRouter.shared.newSiteRequested` (Task 2).
- Produces: launcher now reacts to `newSiteRequested` and its `openFolder()` delegates to `SiteActions`.

- [ ] **Step 1: Import the router and observe it**

In `Sources/AnglesiteApp/SitesLauncherView.swift`, add the import near the top (after `import AnglesiteCore`):

```swift
import AnglesiteIntents
```

Add a router property alongside the other `@State` declarations (after `@State private var sitesRootScopedURL: URL?` at line ~34):

```swift
    @State private var router = WindowRouter.shared
```

- [ ] **Step 2: React to the new-site signal**

In `var body`, attach an `.onChange` to the `Group`. The current body is:

```swift
    var body: some View {
        Group {
            if deciding {
                Color(NSColor.windowBackgroundColor)
            } else {
                launcherUI
            }
        }
        .task { await onFirstAppear() }
        .navigationTitle("Sites")
    }
```

Change it to add the observer (handles the **launcher-already-open** case):

```swift
    var body: some View {
        Group {
            if deciding {
                Color(NSColor.windowBackgroundColor)
            } else {
                launcherUI
            }
        }
        .task { await onFirstAppear() }
        .onChange(of: router.newSiteRequested) { _, requested in
            guard requested else { return }
            router.newSiteRequested = false
            Task { await presentNewSite() }
        }
        .navigationTitle("Sites")
    }
```

- [ ] **Step 3: Handle the launcher-just-created case in `onFirstAppear`**

`.onChange` does not fire for an initial `true`, so a launcher opened *by* the menu must also check the flag once. In `onFirstAppear()`, after `await refreshSites()` and before the autoopen block, add the check. The current method:

```swift
    private func onFirstAppear() async {
        await refreshSites()

        if !Self.didAutoOpenAttempt {
            Self.didAutoOpenAttempt = true
            if let id = AppSettings.shared.lastOpenedSiteID,
               sites.contains(where: { $0.id == id && $0.isValid }) {
                openWindow(value: id)
                dismissWindow()
                return
            }
        }
        deciding = false
    }
```

Becomes:

```swift
    private func onFirstAppear() async {
        await refreshSites()

        // A File ▸ New Site that opened this launcher set the flag before our `.task` ran;
        // `.onChange` won't fire for that initial value, so consume it here.
        if router.newSiteRequested {
            router.newSiteRequested = false
            deciding = false
            await presentNewSite()
            return
        }

        if !Self.didAutoOpenAttempt {
            Self.didAutoOpenAttempt = true
            if let id = AppSettings.shared.lastOpenedSiteID,
               sites.contains(where: { $0.id == id && $0.isValid }) {
                openWindow(value: id)
                dismissWindow()
                return
            }
        }
        deciding = false
    }
```

- [ ] **Step 4: Guard `presentNewSite` against a double-present**

At the very start of `presentNewSite()` (before `let resolution = PluginRuntime.resolve()`), add:

```swift
        guard !showingNewSite else { return }
```

- [ ] **Step 5: Delegate `openFolder()` to the shared helper**

Replace the body of `openFolder()`. Current:

```swift
    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose an Anglesite project directory."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let site = try await SiteStore.shared.add(url)
                #if ANGLESITE_MAS
                let bookmark = try SecurityScopedBookmark.create(for: url)
                try await SiteStore.shared.setBookmark(bookmark, for: site.id)
                #endif
                await refreshSites()
                open(site: site)
            } catch {
                loadError = "Couldn't add \(url.lastPathComponent): \(error)"
            }
        }
    }
```

Replace with:

```swift
    private func openFolder() {
        Task {
            do {
                guard let site = try await SiteActions.pickAndRegisterSite() else { return }
                await refreshSites()
                open(site: site)
            } catch {
                loadError = "Couldn't add the chosen folder: \(error)"
            }
        }
    }
```

- [ ] **Step 6: Build both targets to verify it compiles**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

Run: `xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **` (this exercises the `#if ANGLESITE_MAS` bookmark path in `SiteActions`).

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteApp/SitesLauncherView.swift
git commit -m "feat(app): launcher reacts to New Site signal, shares import logic"
```

---

### Task 6: Add the File-menu commands and start the model

**Files:**
- Modify: `Sources/AnglesiteApp/AnglesiteApp.swift`

**Interfaces:**
- Consumes: `RecentSitesModel.shared` (Task 4), `SiteActions.pickAndRegisterSite()` (Task 3), `WindowRouter.shared.requestNewSite()` (Task 2).
- Produces: the File menu (terminal — no later task depends on this).

- [ ] **Step 1: Hold the recent-sites model on the App**

In `Sources/AnglesiteApp/AnglesiteApp.swift`, add a property to `struct AnglesiteApp` next to the existing `@Environment(\.openWindow)` (around line 49):

```swift
    /// Live mirror of the site registry for the File ▸ Open Recent submenu. Held as `@State`
    /// so SwiftUI re-evaluates `.commands` when its `sites` change. Started in AppDelegate.
    @State private var recent = RecentSitesModel.shared
```

- [ ] **Step 2: Start the model at launch**

In `AppDelegate.applicationDidFinishLaunching(_:)`, after the existing `Task { await AnglesiteIntents.bootstrap(...) }` block, add:

```swift
        // Begin mirroring the site registry so the File ▸ Open Recent submenu is populated
        // and stays current. Idempotent; safe on the main actor.
        Task { @MainActor in RecentSitesModel.shared.start() }
```

- [ ] **Step 3: Add the File-menu command group**

In the `.commands { }` block on the `Window("Sites", id: "sites")` scene, add a new `CommandGroup(replacing: .newItem)` as the first entry (before the `#if !ANGLESITE_MAS` updates group). `replacing: .newItem` removes the "New Window" item SwiftUI auto-generates for the `WindowGroup(for:)`, so our `⌘N` owns that slot:

```swift
            CommandGroup(replacing: .newItem) {
                Button("New Site") {
                    // Ensure the launcher exists to host the wizard sheet, then ask it to open.
                    openWindow(id: "sites")
                    WindowRouter.shared.requestNewSite()
                }
                .keyboardShortcut("n")

                Button("Open Site…") {
                    Task { await openSiteFromMenu() }
                }
                .keyboardShortcut("o")

                Menu("Open Recent") {
                    ForEach(recent.sites) { site in
                        Button(site.name) { openWindow(value: site.id) }
                            .disabled(!site.isValid)
                    }
                    if recent.sites.isEmpty {
                        Button("No Recent Sites") {}.disabled(true)
                    }
                }
            }
```

- [ ] **Step 4: Add the menu's open-site handler**

Add a private `@MainActor` method to `struct AnglesiteApp` (after the `init()`, before `var body`). It surfaces failures with `NSAlert` since there may be no launcher to host an inline error:

```swift
    /// File ▸ Open Site… — window-independent, so it runs from any focused window.
    @MainActor
    private func openSiteFromMenu() async {
        do {
            guard let site = try await SiteActions.pickAndRegisterSite() else { return }
            openWindow(value: site.id)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't open that folder"
            alert.informativeText = "\(error)"
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
```

- [ ] **Step 5: Build both targets**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

Run: `xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteApp/AnglesiteApp.swift
git commit -m "feat(app): File menu New Site / Open Site / Open Recent"
```

---

### Task 7: Full verification

**Files:** none (verification only).

- [ ] **Step 1: Full test suite**

Run: `swift test --package-path . 2>&1 | grep -E "Test run with|recorded an issue" | head`
Expected: the only failures are `AppliesEditEndToEndTests` and `MCPClientHTTPEndToEndTests` (plugin-checkout e2e, pre-existing). `RecentSitesTests` passes. No other failures.

- [ ] **Step 2: Both app targets build clean**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

Run: `xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Manual smoke (launch the Anglesite scheme app)**

Verify by hand and check each:
- File menu shows **New Site (⌘N)**, **Open Site… (⌘O)**, **Open Recent ▸**. No stray "New Window" item.
- With the launcher focused: **⌘O** → folder picker → choosing a valid project opens its window; cancelling is a no-op.
- With a **site window** focused (launcher closed): **⌘N** → launcher opens and the new-site wizard appears.
- With a **site window** focused: **⌘O** → folder picker works (no launcher needed).
- **Open Recent** lists known sites most-recent-first, reopens one on click, shows invalid sites disabled, and shows "No Recent Sites" disabled when the registry is empty.
- Add or remove a site, then reopen the menu: **Open Recent** reflects the change (live via `changeStream`).

- [ ] **Step 4: No-op commit guard**

If Steps 1–3 surfaced fixes, commit them with a descriptive message. Otherwise nothing to commit.

---

## Self-review

**Spec coverage:**
- Menu structure (`CommandGroup(replacing: .newItem)`, three items, labels, shortcuts) → Task 6. ✓
- Shared import logic (`SiteActions.pickAndRegisterSite`, MAS bookmark in one place) → Task 3, consumed by Tasks 5 & 6. ✓
- New-Site routing via `WindowRouter` (both already-open and just-created cases, double-present guard) → Tasks 2 & 5. ✓
- Open Recent data source: pure `RecentSites.select` in Core → Task 1; `RecentSitesModel` mirror over `changeStream()` started in AppDelegate → Tasks 4 & 6. ✓
- Footer keeps working, delegates to shared logic → Task 5 (footer untouched; `openFolder` delegates). ✓
- Error handling: cancel no-op, add failure → NSAlert (menu) / loadError (launcher), invalid disabled, empty placeholder → Tasks 3/5/6. ✓
- MAS/sandbox gating in app target → Tasks 3 & 5 (built under both schemes). ✓
- Testing: TDD unit for `select`, dual-scheme build, manual smoke → Tasks 1 & 7. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code; every command has expected output. ✓

**Type consistency:** `RecentSites.select(from:limit:)`, `SiteActions.pickAndRegisterSite() -> SiteStore.Site?`, `WindowRouter.newSiteRequested`/`requestNewSite()`, `RecentSitesModel.shared`/`.sites`/`.start()` are used identically everywhere they appear. `SiteStore.Site` field names match the verified struct. ✓
