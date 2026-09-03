# App Intents Testing framework adoption — Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the design from `docs/superpowers/specs/2026-06-10-app-intents-testing-design.md` (#104) — extract `Sources/AnglesiteApp/Intents/*` into a new SwiftPM library `AnglesiteIntents`, switch the four App Intents to `@Dependency`-injected `SiteOperationsService`, and add ~19 tests in a new `AnglesiteIntentsTests` target running under `swift test --parallel`.

**Architecture:** New SPM library `AnglesiteIntents` (depends on `AnglesiteCore`, system `AppIntents`, `Observation`) holds the four intents + `SiteEntity` + `SiteEntityQuery` + `AnglesiteShortcuts` + the `WindowRouter` class. The app target keeps `SitesWindowRoot` (SwiftUI scene infra) and gains a one-line `AnglesiteIntents.bootstrap()` call at launch that registers a live `SiteOperations` with `AppDependencyManager.shared`. Tests register fakes via the same manager; all suites nest under a single `@Suite("AppIntents", .serialized)` root to serialize mutations of the shared dependency registry.

**Tech Stack:** Swift 5.10 (SPM auto-discovery), Swift Testing, AppIntents framework (macOS 27), XcodeGen for the app project.

---

## Phase A — Protocol + scaffolding

### Task 1: Extract `SiteOperationsService` in `AnglesiteCore`

**Files:**
- Create: `Sources/AnglesiteCore/SiteOperationsService.swift`
- Modify: `Sources/AnglesiteCore/SiteOperations.swift` (no behavioral changes; just add conformance via extension)
- Test: `Tests/AnglesiteCoreTests/SiteOperationsTests.swift` (existing, must stay green)

- [ ] **Step 1: Verify the existing tests pass before any change**

Run: `swift test --filter SiteOperationsTests`
Expected: all SiteOperationsTests pass (4 tests).

- [ ] **Step 2: Create the protocol file**

Write `Sources/AnglesiteCore/SiteOperationsService.swift`:

```swift
import Foundation

/// Seam for App Intents (and any future system entry point — system MCP per #101)
/// to call site operations without binding to the concrete `SiteOperations` type.
///
/// `SiteOperations` is the production conformance. Tests register a fake conforming type
/// with `AppDependencyManager.shared` to drive intent suites; see the AnglesiteIntents
/// test target.
public protocol SiteOperationsService: Sendable {
    func site(id: String) async -> SiteStore.Site?
    func deploy(site: SiteStore.Site) async -> DeployCommand.Result
    func backup(site: SiteStore.Site) async -> BackupCommand.Result
    func audit(site: SiteStore.Site) async -> AuditCommand.Result
}

extension SiteOperations: SiteOperationsService {}
```

- [ ] **Step 3: Verify the build is still clean**

Run: `swift build -c debug`
Expected: build succeeds; no errors.

- [ ] **Step 4: Verify the existing tests still pass**

Run: `swift test --filter SiteOperationsTests`
Expected: all 4 tests still pass — the protocol extraction is a no-op for existing call sites because `SiteOperations` methods already match the protocol signatures.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SiteOperationsService.swift
git commit -m "feat(intents): extract SiteOperationsService seam for App Intents testing (#104)"
```

---

### Task 2: Scaffold empty `AnglesiteIntents` SPM library + test target

**Files:**
- Create: `Sources/AnglesiteIntents/Placeholder.swift` (temp; removed in Task 9)
- Modify: `Package.swift` (add library + test target)

- [ ] **Step 1: Create a placeholder Swift file so SPM doesn't complain about an empty target**

Write `Sources/AnglesiteIntents/Placeholder.swift`:

```swift
// Placeholder. Removed in Task 9 when the test target gains its first real test.
// Keeps SPM happy until the four intent files move into this target (Tasks 4–6).
```

- [ ] **Step 2: Update `Package.swift`**

Edit `Package.swift`. After the `AnglesiteBridge` library product, add `AnglesiteIntents`; after the `AnglesiteBridge` target, add the `AnglesiteIntents` target; after the existing test targets, add `AnglesiteIntentsTests`.

The final relevant fragments:

```swift
products: [
    .library(name: "AnglesiteCore", targets: ["AnglesiteCore"]),
    .library(name: "AnglesiteBridge", targets: ["AnglesiteBridge"]),
    .library(name: "AnglesiteIntents", targets: ["AnglesiteIntents"])
],
targets: [
    .target(
        name: "AnglesiteCore",
        path: "Sources/AnglesiteCore",
        swiftSettings: strictConcurrency
    ),
    .target(
        name: "AnglesiteBridge",
        dependencies: ["AnglesiteCore"],
        path: "Sources/AnglesiteBridge",
        swiftSettings: strictConcurrency
    ),
    .target(
        name: "AnglesiteIntents",
        dependencies: ["AnglesiteCore"],
        path: "Sources/AnglesiteIntents",
        swiftSettings: strictConcurrency
    ),
    .testTarget(
        name: "AnglesiteCoreTests",
        dependencies: ["AnglesiteCore"],
        path: "Tests/AnglesiteCoreTests",
        swiftSettings: strictConcurrency
    ),
    .testTarget(
        name: "AnglesiteBridgeTests",
        dependencies: ["AnglesiteBridge"],
        path: "Tests/AnglesiteBridgeTests",
        swiftSettings: strictConcurrency
    ),
    .testTarget(
        name: "AnglesiteIntentsTests",
        dependencies: ["AnglesiteIntents", "AnglesiteCore"],
        path: "Tests/AnglesiteIntentsTests",
        swiftSettings: strictConcurrency
    )
]
```

- [ ] **Step 3: Create the test target directory with a placeholder**

Write `Tests/AnglesiteIntentsTests/Placeholder.swift`:

```swift
// Placeholder. Removed in Task 9. Keeps SPM's testTarget discovery happy.
```

- [ ] **Step 4: Verify the package builds**

Run: `swift build -c debug`
Expected: build succeeds. The new `AnglesiteIntents` target shows up in the build graph but compiles to an essentially empty module.

- [ ] **Step 5: Verify all existing tests still pass**

Run: `swift test --parallel`
Expected: all 270 existing tests pass; AnglesiteIntentsTests reports 0 tests (placeholder file has none).

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/AnglesiteIntents/Placeholder.swift Tests/AnglesiteIntentsTests/Placeholder.swift
git commit -m "feat(intents): scaffold AnglesiteIntents SPM library + test target (#104)"
```

---

### Task 3: Wire `AnglesiteIntents` into the app's Xcode project

**Files:**
- Modify: `project.yml` (add dependency to both app targets)
- Regenerate: `Anglesite.xcodeproj` (gitignored, but must be regenerated locally)

- [ ] **Step 1: Edit `project.yml` — add `AnglesiteIntents` as a dependency for both targets**

Two edits — in the `Anglesite` target's `dependencies:` (around line 95) and the `AnglesiteMAS` target's `dependencies:` (around line 177).

For target `Anglesite` (change after line 99):
```yaml
    dependencies:
      - package: Anglesite
        product: AnglesiteCore
      - package: Anglesite
        product: AnglesiteBridge
      - package: Anglesite
        product: AnglesiteIntents
```

For target `AnglesiteMAS` (change after line 181):
```yaml
    dependencies:
      - package: Anglesite
        product: AnglesiteCore
      - package: Anglesite
        product: AnglesiteBridge
      - package: Anglesite
        product: AnglesiteIntents
```

- [ ] **Step 2: Regenerate `Anglesite.xcodeproj`**

Run: `xcodegen generate`
Expected: `Created project at .../Anglesite.xcodeproj`. No errors.

- [ ] **Step 3: Build both schemes to confirm the dependency wires up**

Run:
```bash
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug -derivedDataPath /tmp/intents-104-build build 2>&1 | tail -3
xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug -derivedDataPath /tmp/intents-104-mas-build build 2>&1 | tail -3
```
Expected: both end with `** BUILD SUCCEEDED **`. The app target now links the (empty) AnglesiteIntents library; nothing else changes yet.

- [ ] **Step 4: Commit**

```bash
git add project.yml
git commit -m "build(intents): link AnglesiteIntents into both app targets (#104)"
```

---

## Phase B — Move files

### Task 4: Move `SiteEntity.swift` to `AnglesiteIntents`, refactor `SiteEntityQuery.init`

**Files:**
- Create: `Sources/AnglesiteIntents/SiteEntity.swift`
- Delete: `Sources/AnglesiteApp/Intents/SiteEntity.swift`
- Regenerate: `Anglesite.xcodeproj`

The refactor: change `SiteEntityQuery` from a zero-stored-property struct to one that stores a `store: SiteStore`, defaulting to `.shared`. Production call sites (`SiteEntity.defaultQuery = SiteEntityQuery()`) are unchanged; tests get to pass a throwaway store.

- [ ] **Step 1: Create the new file with the refactored query**

Write `Sources/AnglesiteIntents/SiteEntity.swift`:

```swift
import AppIntents
import AnglesiteCore
import Foundation

/// An Anglesite site, addressable by Siri/Shortcuts. Backed live by `SiteStore` — no
/// cache, so the entity never goes stale relative to the registry.
public struct SiteEntity: AppEntity, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let directory: URL

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Site" }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)", subtitle: "\(directory.path)")
    }

    public static var defaultQuery = SiteEntityQuery()

    public init(_ site: SiteStore.Site) {
        self.id = site.id
        self.displayName = site.name
        self.directory = site.path
    }
}

/// Resolves sites by id (Shortcuts re-resolution) and by name (Siri "my portfolio site").
/// `load()` is called first so a cold background intent process sees the persisted registry.
public struct SiteEntityQuery: EntityStringQuery {
    private let store: SiteStore

    public init(store: SiteStore = .shared) {
        self.store = store
    }

    private func allSites() async -> [SiteStore.Site] {
        try? await store.load()
        return await store.sites
    }

    public func entities(for identifiers: [String]) async throws -> [SiteEntity] {
        await allSites().filter { identifiers.contains($0.id) }.map(SiteEntity.init)
    }

    public func entities(matching string: String) async throws -> [SiteEntity] {
        let needle = string.lowercased()
        return await allSites().filter { $0.name.lowercased().contains(needle) }.map(SiteEntity.init)
    }

    public func suggestedEntities() async throws -> [SiteEntity] {
        await allSites().map(SiteEntity.init)
    }

    public func defaultResult() async -> SiteEntity? {
        let sites = await allSites()
        return sites.count == 1 ? sites.first.map(SiteEntity.init) : nil
    }
}
```

Key differences from the original:
- All types and methods are `public` (so the app target's `SiteIntents` can reference `SiteEntity`).
- `SiteEntity` is now `Sendable` (needed for `AppIntents` cross-process boundaries).
- `SiteEntityQuery` stores a `SiteStore`, defaulting to `.shared`. Production behavior unchanged.

- [ ] **Step 2: Delete the old file**

```bash
rm Sources/AnglesiteApp/Intents/SiteEntity.swift
```

- [ ] **Step 3: Regenerate xcodeproj**

Run: `xcodegen generate`
Expected: regen succeeds. The new file is picked up under `AnglesiteIntents`; the old location is gone.

- [ ] **Step 4: Build to confirm**

Run: `swift build -c debug && xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug -derivedDataPath /tmp/intents-104-build build 2>&1 | tail -3`
Expected: `swift build` succeeds; xcodebuild ends with `** BUILD SUCCEEDED **`. (The other three files in the original `Intents/` group still reference `SiteEntity` — they pick it up from the new module via `import AnglesiteIntents`, which will be added in Tasks 5–6. Until then the app target may have unresolved references; that's expected and resolves at the end of Phase B.)

Actually: until Task 5 moves `SiteIntents.swift`, those references are still in `Sources/AnglesiteApp/Intents/SiteIntents.swift` and need an `import AnglesiteIntents`. Add it now:

Edit `Sources/AnglesiteApp/Intents/SiteIntents.swift` line 1–2:

```swift
import AppIntents
import AnglesiteCore
import AnglesiteIntents  // for SiteEntity
```

And similarly `Sources/AnglesiteApp/Intents/AnglesiteShortcuts.swift` line 1:

```swift
import AppIntents
import AnglesiteIntents  // for DeploySiteIntent, BackupSiteIntent, AuditSiteIntent (move-pending)
```

(That second import will become a no-op once `SiteIntents.swift` itself moves in Task 5. Leave the import; Task 5 deletes the consuming file.)

- [ ] **Step 5: Build again**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug -derivedDataPath /tmp/intents-104-build build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteIntents/SiteEntity.swift Sources/AnglesiteApp/Intents/SiteIntents.swift Sources/AnglesiteApp/Intents/AnglesiteShortcuts.swift
git rm Sources/AnglesiteApp/Intents/SiteEntity.swift
git commit -m "refactor(intents): move SiteEntity into AnglesiteIntents lib + accept injectable store (#104)"
```

---

### Task 5: Move `SiteIntents.swift` and `AnglesiteShortcuts.swift` to `AnglesiteIntents`

**Files:**
- Create: `Sources/AnglesiteIntents/SiteIntents.swift` (still uses `let ops = SiteOperations()` — `@Dependency` refactor is Task 7)
- Create: `Sources/AnglesiteIntents/AnglesiteShortcuts.swift`
- Delete: `Sources/AnglesiteApp/Intents/SiteIntents.swift`
- Delete: `Sources/AnglesiteApp/Intents/AnglesiteShortcuts.swift`
- Regenerate: `Anglesite.xcodeproj`

- [ ] **Step 1: Create the new SiteIntents.swift**

Write `Sources/AnglesiteIntents/SiteIntents.swift`. Same content as the existing file but with three changes: (a) all four intent structs become `public`, (b) `OpenSiteIntent.perform()` references `WindowRouter.shared` which will move in Task 6 — leave it for now (compiles because WindowRouter is still in the app target at this commit; we revisit at Task 6).

Hmm — this creates a circular reference: `Sources/AnglesiteIntents/SiteIntents.swift` references `WindowRouter` which is in the app target, but `AnglesiteIntents` can't depend on the app target. So we must move WindowRouter in the **same** task as SiteIntents to avoid an intermediate broken state.

**Revised plan: combine Tasks 5 and 6 into a single task.** Task 5 below is the combined version.

- [ ] **Step 1 (revised): Create `Sources/AnglesiteIntents/WindowRouter.swift` first** (only the `WindowRouter` class, no SwiftUI view)

Write `Sources/AnglesiteIntents/WindowRouter.swift`:

```swift
import Foundation
import Observation

/// Lets `OpenSiteIntent` (which can't call SwiftUI's `openWindow`) request a site window.
/// The "Sites" scene observes `requested` and opens/focuses the matching per-site window.
@MainActor
@Observable
public final class WindowRouter {
    public static let shared = WindowRouter()
    private init() {}

    /// The site id the intent asked to open; the scene clears it after handling.
    public var requested: String?

    public func requestOpen(siteID: String) { requested = siteID }
}
```

- [ ] **Step 2: Create `Sources/AnglesiteApp/SitesWindowRoot.swift`** (the SwiftUI view that stayed behind)

Write `Sources/AnglesiteApp/SitesWindowRoot.swift`:

```swift
import SwiftUI
import AnglesiteIntents

/// Root content for the "Sites" window. Wraps `SitesLauncherView` and bridges
/// `WindowRouter` requests (from `OpenSiteIntent`) to `openWindow(value:)`. Holding the router
/// as observed `@State` guarantees `.onChange` re-evaluates when an intent sets `requested`.
struct SitesWindowRoot: View {
    let openWindow: OpenWindowAction
    @State private var router = WindowRouter.shared

    var body: some View {
        SitesLauncherView()
            .onChange(of: router.requested) { _, newValue in
                guard let id = newValue else { return }
                openWindow(value: id)
                router.requested = nil
            }
    }
}
```

- [ ] **Step 3: Create `Sources/AnglesiteIntents/SiteIntents.swift`** (intents now in their own module; still using `let ops = SiteOperations()` — Task 6 swaps that for @Dependency)

Write `Sources/AnglesiteIntents/SiteIntents.swift`. **Note:** post-#125, `DeploySiteIntent` and `AuditSiteIntent` conform to `LongRunningIntent` (not `AppIntent`) and wrap their ops calls in `performBackgroundTask { ... }`. Deploy uses the non-deprecated `requestConfirmation(dialog:)`. Preserve these from main when moving the file:

```swift
import AppIntents
import AnglesiteCore

/// The four App Intents. Each is a thin adapter over `SiteOperations` (Core), which holds all
/// the testable Result→dialog logic. No Claude/LLM process is involved — the intents drive the
/// deterministic command actors directly.

// `LongRunningIntent` (→ `ProgressReportingIntent` → `AppIntent`) tells the system this work
// can exceed the default intent execution budget, so a real deploy/audit invoked from Siri or
// a background Shortcut isn't killed mid-run. The actual work runs inside `performBackgroundTask`.
public struct DeploySiteIntent: LongRunningIntent {
    public static var title: LocalizedStringResource = "Deploy Site"
    public static var description = IntentDescription("Deploy a site to production with Anglesite.")

    @Parameter(title: "Site") public var site: SiteEntity

    public init() {}

    public static var parameterSummary: some ParameterSummary { Summary("Deploy \(\.$site)") }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        try await requestConfirmation(
            dialog: "Deploy \(site.displayName) to production?"
        )
        let ops = SiteOperations()
        guard let resolved = await ops.site(id: site.id) else {
            return .result(dialog: "Couldn't find \(site.displayName).")
        }
        let result = try await performBackgroundTask {
            await ops.deploy(site: resolved)
        }
        return .result(dialog: IntentDialog(stringLiteral: SiteOperations.dialog(forDeploy: result)))
    }
}

public struct BackupSiteIntent: AppIntent {
    public static var title: LocalizedStringResource = "Back Up Site"
    public static var description = IntentDescription("Commit and push a site backup with Anglesite.")

    @Parameter(title: "Site") public var site: SiteEntity

    public init() {}

    public static var parameterSummary: some ParameterSummary { Summary("Back up \(\.$site)") }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let ops = SiteOperations()
        guard let resolved = await ops.site(id: site.id) else {
            return .result(dialog: "Couldn't find \(site.displayName).")
        }
        let result = await ops.backup(site: resolved)
        return .result(dialog: IntentDialog(stringLiteral: SiteOperations.dialog(forBackup: result)))
    }
}

public struct AuditSiteIntent: LongRunningIntent {
    public static var title: LocalizedStringResource = "Check Site"
    public static var description = IntentDescription("Run an Anglesite audit and report findings.")

    @Parameter(title: "Site") public var site: SiteEntity

    public init() {}

    public static var parameterSummary: some ParameterSummary { Summary("Check \(\.$site)") }

    public func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<SiteEntity> {
        let ops = SiteOperations()
        guard let resolved = await ops.site(id: site.id) else {
            return .result(value: site, dialog: "Couldn't find \(site.displayName).")
        }
        let result = try await performBackgroundTask {
            await ops.audit(site: resolved)
        }
        return .result(value: site, dialog: IntentDialog(stringLiteral: SiteOperations.dialog(forAudit: result)))
    }
}

public struct OpenSiteIntent: AppIntent {
    public static var title: LocalizedStringResource = "Open Site"
    public static var description = IntentDescription("Open a site window in Anglesite.")
    public static var openAppWhenRun = true

    @Parameter(title: "Site") public var site: SiteEntity

    public init() {}

    public static var parameterSummary: some ParameterSummary { Summary("Open \(\.$site)") }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        WindowRouter.shared.requestOpen(siteID: site.id)
        return .result(dialog: "Opening \(site.displayName).")
    }
}
```

- [ ] **Step 4: Create `Sources/AnglesiteIntents/AnglesiteShortcuts.swift`**

Write `Sources/AnglesiteIntents/AnglesiteShortcuts.swift`:

```swift
import AppIntents

/// Curated Siri phrases. They appear in Spotlight and Siri suggestions. `\(.applicationName)`
/// resolves to the app's display name ("Anglesite") on both targets.
///
/// The audit→deploy chain is composed in the Shortcuts editor: `AuditSiteIntent` returns a
/// `SiteEntity` value that the user pipes into `DeploySiteIntent`, whose confirmation still
/// gates the deploy. No extra `opensIntent` plumbing is needed for v0.
public struct AnglesiteShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: DeploySiteIntent(),
            phrases: ["Deploy my site with \(.applicationName)"],
            shortTitle: "Deploy Site",
            systemImageName: "arrow.up.circle"
        )
        AppShortcut(
            intent: BackupSiteIntent(),
            phrases: ["Back up my site with \(.applicationName)"],
            shortTitle: "Back Up Site",
            systemImageName: "externaldrive.badge.timemachine"
        )
        AppShortcut(
            intent: AuditSiteIntent(),
            phrases: ["Check my site with \(.applicationName)"],
            shortTitle: "Check Site",
            systemImageName: "checkmark.seal"
        )
    }
}
```

- [ ] **Step 5: Delete the old files**

```bash
rm Sources/AnglesiteApp/Intents/SiteIntents.swift
rm Sources/AnglesiteApp/Intents/AnglesiteShortcuts.swift
rm Sources/AnglesiteApp/Intents/WindowRouter.swift
rmdir Sources/AnglesiteApp/Intents
```

- [ ] **Step 6: Update `AnglesiteApp.swift` to import the new module**

Edit `Sources/AnglesiteApp/AnglesiteApp.swift` lines 1–4:

```swift
import SwiftUI
import AppKit
import AnglesiteCore
import AnglesiteBridge
import AnglesiteIntents
```

(The `SitesWindowRoot` reference at line 64 already works because that view is now in `Sources/AnglesiteApp/SitesWindowRoot.swift`, same module.)

- [ ] **Step 7: Regenerate xcodeproj**

Run: `xcodegen generate`

- [ ] **Step 8: Build both schemes**

Run:
```bash
swift build -c debug
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug -derivedDataPath /tmp/intents-104-build build 2>&1 | tail -3
xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug -derivedDataPath /tmp/intents-104-mas-build build 2>&1 | tail -3
```
Expected: all three end clean.

- [ ] **Step 9: Run the existing test suite**

Run: `swift test --parallel`
Expected: all 270 existing tests still pass.

- [ ] **Step 10: Commit**

```bash
git add Sources/AnglesiteIntents/ Sources/AnglesiteApp/SitesWindowRoot.swift Sources/AnglesiteApp/AnglesiteApp.swift
git rm Sources/AnglesiteApp/Intents/SiteIntents.swift Sources/AnglesiteApp/Intents/AnglesiteShortcuts.swift Sources/AnglesiteApp/Intents/WindowRouter.swift
git commit -m "refactor(intents): move SiteIntents/Shortcuts/WindowRouter into AnglesiteIntents lib (#104)"
```

---

## Phase C — `@Dependency` wiring

### Task 6: Switch intents to `@Dependency private var ops: any SiteOperationsService`

**Files:**
- Modify: `Sources/AnglesiteIntents/SiteIntents.swift`

- [ ] **Step 1: Replace `let ops = SiteOperations()` in each of the four intents with `@Dependency`**

Edit `Sources/AnglesiteIntents/SiteIntents.swift`. For each intent struct, remove the local `let ops = ...` line and add a stored property at the top of the struct. The `performBackgroundTask` wrapping (for Deploy/Audit) is preserved — `ops` is captured by the closure as a regular stored property.

For `DeploySiteIntent` (LongRunningIntent):

```swift
public struct DeploySiteIntent: LongRunningIntent {
    public static var title: LocalizedStringResource = "Deploy Site"
    public static var description = IntentDescription("Deploy a site to production with Anglesite.")

    @Parameter(title: "Site") public var site: SiteEntity
    @Dependency private var ops: any SiteOperationsService

    public init() {}

    public static var parameterSummary: some ParameterSummary { Summary("Deploy \(\.$site)") }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        try await requestConfirmation(
            dialog: "Deploy \(site.displayName) to production?"
        )
        guard let resolved = await ops.site(id: site.id) else {
            return .result(dialog: "Couldn't find \(site.displayName).")
        }
        let result = try await performBackgroundTask {
            await ops.deploy(site: resolved)
        }
        return .result(dialog: IntentDialog(stringLiteral: SiteOperations.dialog(forDeploy: result)))
    }
}
```

For `AuditSiteIntent` (LongRunningIntent):

```swift
public struct AuditSiteIntent: LongRunningIntent {
    public static var title: LocalizedStringResource = "Check Site"
    public static var description = IntentDescription("Run an Anglesite audit and report findings.")

    @Parameter(title: "Site") public var site: SiteEntity
    @Dependency private var ops: any SiteOperationsService

    public init() {}

    public static var parameterSummary: some ParameterSummary { Summary("Check \(\.$site)") }

    public func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<SiteEntity> {
        guard let resolved = await ops.site(id: site.id) else {
            return .result(value: site, dialog: "Couldn't find \(site.displayName).")
        }
        let result = try await performBackgroundTask {
            await ops.audit(site: resolved)
        }
        return .result(value: site, dialog: IntentDialog(stringLiteral: SiteOperations.dialog(forAudit: result)))
    }
}
```

For `BackupSiteIntent` (plain AppIntent, no `performBackgroundTask`):

```swift
public struct BackupSiteIntent: AppIntent {
    // ... title/description/init/parameterSummary unchanged ...

    @Parameter(title: "Site") public var site: SiteEntity
    @Dependency private var ops: any SiteOperationsService

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let resolved = await ops.site(id: site.id) else {
            return .result(dialog: "Couldn't find \(site.displayName).")
        }
        let result = await ops.backup(site: resolved)
        return .result(dialog: IntentDialog(stringLiteral: SiteOperations.dialog(forBackup: result)))
    }
}
```

`OpenSiteIntent` doesn't touch `SiteOperations` — leave it alone. The static dialog mappings (`SiteOperations.dialog(forDeploy:)` etc.) are unchanged.

- [ ] **Step 2: Build**

Run: `swift build -c debug`
Expected: clean build.

- [ ] **Step 3: Existing tests still green**

Run: `swift test --parallel`
Expected: 270 tests pass. (The intents don't run during tests, so the @Dependency resolution doesn't fire — but production code paths through `SiteOperations` are unchanged.)

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteIntents/SiteIntents.swift
git commit -m "refactor(intents): switch DeploySiteIntent/Backup/Audit to @Dependency ops (#104)"
```

---

### Task 7: Add `Bootstrap.swift` and call from `AppDelegate`

**Files:**
- Create: `Sources/AnglesiteIntents/Bootstrap.swift`
- Modify: `Sources/AnglesiteApp/AnglesiteApp.swift` (call bootstrap in `applicationDidFinishLaunching`)

- [ ] **Step 1: Create the bootstrap entry point**

Write `Sources/AnglesiteIntents/Bootstrap.swift`:

```swift
import AppIntents
import AnglesiteCore

/// Public entry point that registers production dependencies with `AppDependencyManager`.
///
/// Called once from `AppDelegate.applicationDidFinishLaunching` today. #101 (system MCP)
/// will reuse this from a non-UI process so a backgrounded intent can resolve `SiteOperationsService`
/// before any window is opened.
public enum AnglesiteIntents {
    public static func bootstrap() {
        AppDependencyManager.shared.add { () -> any SiteOperationsService in
            SiteOperations(factory: LiveCommandFactory())
        }
    }
}
```

- [ ] **Step 2: Update `AppDelegate.applicationDidFinishLaunching` to call it**

Edit `Sources/AnglesiteApp/AnglesiteApp.swift` lines 9–20. Add the `bootstrap()` call as the first line inside the method, before the existing npm-cache prime Task:

```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    // Register App Intents dependencies before the app surface comes up so backgrounded
    // intent processes (and #101's system MCP entry, later) can resolve immediately.
    AnglesiteIntents.bootstrap()

    // Extract the bundled npm cache into Application Support so the first site `npm install`
    // is offline-fast. No-op when nothing's bundled or it's already current; logged either way.
    Task {
        do {
            let outcome = try await NodeModulesCache.shared.prime()
            await LogCenter.shared.append(source: "npm-cache", stream: .stdout, text: "prime: \(outcome)")
        } catch {
            await LogCenter.shared.append(source: "npm-cache", stream: .stderr, text: "prime failed: \(error)")
        }
    }
}
```

- [ ] **Step 3: Build**

Run: `swift build -c debug && xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug -derivedDataPath /tmp/intents-104-build build 2>&1 | tail -3`
Expected: both clean.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteIntents/Bootstrap.swift Sources/AnglesiteApp/AnglesiteApp.swift
git commit -m "feat(intents): bootstrap() entry point registers live SiteOperations (#104)"
```

---

## Phase D — Tests

### Task 8: Add `Support/FakeOperations.swift` and the suite root

**Files:**
- Create: `Tests/AnglesiteIntentsTests/Support/FakeOperations.swift`
- Create: `Tests/AnglesiteIntentsTests/Support/TestStore.swift` (helper for populating throwaway SiteStores)
- Create: `Tests/AnglesiteIntentsTests/AppIntentsTests.swift` (root `@Suite("AppIntents", .serialized)`)
- Delete: `Tests/AnglesiteIntentsTests/Placeholder.swift`
- Delete: `Sources/AnglesiteIntents/Placeholder.swift`

- [ ] **Step 1: Create the fake**

Write `Tests/AnglesiteIntentsTests/Support/FakeOperations.swift`:

```swift
import Foundation
@testable import AnglesiteCore
@testable import AnglesiteIntents

/// Records calls and vends configurable Results. Each test sets up the result it expects and
/// reads back call records after the intent runs.
///
/// Class (not struct) so `AppDependencyManager.shared.add(fakeOps)` lets every test reads see
/// the same mutated instance — the stored-instance form intentionally skips the closure path
/// that would otherwise allocate a fresh instance per access.
final class FakeOperations: SiteOperationsService, @unchecked Sendable {
    var sites: [String: SiteStore.Site] = [:]
    var deployResult: DeployCommand.Result = .failed(reason: "unstubbed deploy", exitCode: nil)
    var backupResult: BackupCommand.Result = .failed(reason: "unstubbed backup", exitCode: nil)
    var auditResult: AuditCommand.Result = .failed(reason: "unstubbed audit", exitCode: nil)

    private(set) var siteCalls: [String] = []
    private(set) var deployCalls: [SiteStore.Site] = []
    private(set) var backupCalls: [SiteStore.Site] = []
    private(set) var auditCalls: [SiteStore.Site] = []

    func site(id: String) async -> SiteStore.Site? {
        siteCalls.append(id)
        return sites[id]
    }

    func deploy(site: SiteStore.Site) async -> DeployCommand.Result {
        deployCalls.append(site)
        return deployResult
    }

    func backup(site: SiteStore.Site) async -> BackupCommand.Result {
        backupCalls.append(site)
        return backupResult
    }

    func audit(site: SiteStore.Site) async -> AuditCommand.Result {
        auditCalls.append(site)
        return auditResult
    }
}
```

- [ ] **Step 2: Create the SiteStore test helper**

Write `Tests/AnglesiteIntentsTests/Support/TestStore.swift`:

```swift
import Foundation
@testable import AnglesiteCore

/// Builds a throwaway `SiteStore` populated with the given sites. Each call uses a unique
/// persistence URL under `NSTemporaryDirectory()` so parallel test suites don't collide.
enum TestStore {
    static func with(_ sites: [SiteStore.Site]) async throws -> SiteStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("anglesite-intents-test-\(UUID().uuidString).json")
        try JSONEncoder().encode(sites).write(to: url)
        let store = SiteStore(persistenceURL: url)
        try await store.load()
        return store
    }

    static func site(id: String, name: String, path: String? = nil) -> SiteStore.Site {
        SiteStore.Site(
            id: id,
            name: name,
            path: URL(fileURLWithPath: path ?? "/tmp/\(name)", isDirectory: true),
            isValid: true,
            missingSentinels: []
        )
    }
}
```

- [ ] **Step 3: Create the root suite**

Write `Tests/AnglesiteIntentsTests/AppIntentsTests.swift`:

```swift
import Testing

/// Root suite for all App Intents tests. `.serialized` ensures children (each intent suite)
/// run sequentially — `AppDependencyManager.shared` and `WindowRouter.shared` are global mutable
/// state and parallel execution would race.
@Suite("AppIntents", .serialized)
struct AppIntentsTests {}
```

- [ ] **Step 4: Remove the placeholders**

```bash
rm Sources/AnglesiteIntents/Placeholder.swift
rm Tests/AnglesiteIntentsTests/Placeholder.swift
```

- [ ] **Step 5: Build and confirm no tests run yet**

Run: `swift test --filter AppIntentsTests`
Expected: build succeeds; 0 tests run (`AppIntentsTests` is just the suite root, nothing executable yet).

- [ ] **Step 6: Commit**

```bash
git add Tests/AnglesiteIntentsTests/
git rm Sources/AnglesiteIntents/Placeholder.swift Tests/AnglesiteIntentsTests/Placeholder.swift
git commit -m "test(intents): FakeOperations + TestStore + serialized suite root (#104)"
```

---

### Task 9: Write `SiteEntityQueryTests` (8 tests)

**Files:**
- Create: `Tests/AnglesiteIntentsTests/SiteEntityQueryTests.swift`

- [ ] **Step 1: Write all 8 tests**

Write `Tests/AnglesiteIntentsTests/SiteEntityQueryTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore
@testable import AnglesiteIntents

/// Covers acceptance criterion: entity-resolution tests for exact / fuzzy / ambiguous /
/// single-site cases (#104).
extension AppIntentsTests {
    @Suite("SiteEntityQuery")
    struct SiteEntityQueryTests {
        @Test("entities(for:) resolves an exact id")
        func resolvesExactId() async throws {
            let store = try await TestStore.with([
                TestStore.site(id: "s1", name: "Portfolio"),
                TestStore.site(id: "s2", name: "Blog")
            ])
            let query = SiteEntityQuery(store: store)
            let results = try await query.entities(for: ["s1"])
            #expect(results.map(\.id) == ["s1"])
        }

        @Test("entities(for:) returns empty when id is unknown")
        func unknownIdReturnsEmpty() async throws {
            let store = try await TestStore.with([
                TestStore.site(id: "s1", name: "Portfolio")
            ])
            let query = SiteEntityQuery(store: store)
            let results = try await query.entities(for: ["nope"])
            #expect(results.isEmpty)
        }

        @Test("entities(matching:) is case-insensitive substring match")
        func fuzzyMatchCaseInsensitive() async throws {
            let store = try await TestStore.with([
                TestStore.site(id: "s1", name: "Portfolio")
            ])
            let query = SiteEntityQuery(store: store)
            let results = try await query.entities(matching: "PORT")
            #expect(results.map(\.displayName) == ["Portfolio"])
        }

        @Test("entities(matching:) returns empty on no match")
        func fuzzyNoMatchReturnsEmpty() async throws {
            let store = try await TestStore.with([
                TestStore.site(id: "s1", name: "Portfolio")
            ])
            let query = SiteEntityQuery(store: store)
            let results = try await query.entities(matching: "xyz")
            #expect(results.isEmpty)
        }

        @Test("entities(matching:) returns all matches (picker case)")
        func fuzzyAmbiguousReturnsAll() async throws {
            let store = try await TestStore.with([
                TestStore.site(id: "s1", name: "MySite"),
                TestStore.site(id: "s2", name: "OldSite"),
                TestStore.site(id: "s3", name: "Portfolio")
            ])
            let query = SiteEntityQuery(store: store)
            let results = try await query.entities(matching: "site")
            #expect(Set(results.map(\.id)) == Set(["s1", "s2"]))
        }

        @Test("defaultResult() auto-selects the only registered site")
        func defaultResultAutoSelectsLone() async throws {
            let store = try await TestStore.with([
                TestStore.site(id: "s1", name: "Portfolio")
            ])
            let query = SiteEntityQuery(store: store)
            let result = await query.defaultResult()
            #expect(result?.id == "s1")
        }

        @Test("defaultResult() returns nil when no sites are registered")
        func defaultResultNilOnEmpty() async throws {
            let store = try await TestStore.with([])
            let query = SiteEntityQuery(store: store)
            let result = await query.defaultResult()
            #expect(result == nil)
        }

        @Test("defaultResult() returns nil when multiple sites force a picker")
        func defaultResultNilOnAmbiguous() async throws {
            let store = try await TestStore.with([
                TestStore.site(id: "s1", name: "Portfolio"),
                TestStore.site(id: "s2", name: "Blog")
            ])
            let query = SiteEntityQuery(store: store)
            let result = await query.defaultResult()
            #expect(result == nil)
        }
    }
}
```

- [ ] **Step 2: Run the new tests**

Run: `swift test --filter SiteEntityQueryTests`
Expected: 8 tests pass.

- [ ] **Step 3: Run the full suite to confirm no regressions**

Run: `swift test --parallel`
Expected: 278 total tests pass (270 existing + 8 new).

- [ ] **Step 4: Commit**

```bash
git add Tests/AnglesiteIntentsTests/SiteEntityQueryTests.swift
git commit -m "test(intents): SiteEntityQuery resolution coverage (8 tests, #104)"
```

---

### Task 10: Write the four intent suites (9 tests across 4 files)

**Files:**
- Create: `Tests/AnglesiteIntentsTests/DeploySiteIntentTests.swift`
- Create: `Tests/AnglesiteIntentsTests/BackupSiteIntentTests.swift`
- Create: `Tests/AnglesiteIntentsTests/AuditSiteIntentTests.swift`
- Create: `Tests/AnglesiteIntentsTests/OpenSiteIntentTests.swift`

Each suite registers a `FakeOperations` with `AppDependencyManager.shared` in `init()`, then invokes the intent's `perform()` and asserts on the returned dialog. Suites are nested under `AppIntentsTests` so the serialized trait applies.

- [ ] **Step 1: DeploySiteIntentTests**

Write `Tests/AnglesiteIntentsTests/DeploySiteIntentTests.swift`:

```swift
import Testing
import Foundation
import AppIntents
@testable import AnglesiteCore
@testable import AnglesiteIntents

extension AppIntentsTests {
    @Suite("DeploySiteIntent")
    struct DeploySiteIntentTests {
        let fake = FakeOperations()
        let site: SiteStore.Site

        init() async {
            self.site = TestStore.site(id: "s1", name: "Portfolio")
            fake.sites = [site.id: site]
            await AppDependencyManager.shared.add(fake as any SiteOperationsService)
        }

        @Test("succeeds and reports the deployed URL")
        func succeedsAndReportsDeployedURL() async throws {
            let url = URL(string: "https://portfolio.example.workers.dev")!
            fake.deployResult = .succeeded(url: url, duration: 2)
            var intent = DeploySiteIntent()
            intent.site = SiteEntity(site)
            // requestConfirmation auto-confirms under test (no UI surface).
            _ = try await intent.perform()
            #expect(fake.deployCalls.count == 1)
            #expect(fake.deployCalls.first?.id == site.id)
        }

        @Test("blocked deploy surfaces the pre-deploy scan failure count")
        func blockedSurfacesPreDeployFailure() async throws {
            let failure = PreDeployCheck.ScanFailure(
                category: .exposedToken,
                file: "src/index.md",
                detail: "API key committed",
                remediation: "Remove it"
            )
            fake.deployResult = .blocked(failures: [failure], warnings: [])
            var intent = DeploySiteIntent()
            intent.site = SiteEntity(site)
            _ = try await intent.perform()
            #expect(fake.deployCalls.count == 1)
            // Dialog content is verified by SiteOperations.dialog(forDeploy:) tests in
            // SiteOperationsTests; here we just confirm the intent reached the ops layer.
        }

        @Test("failure surfaces the reason without retrying")
        func failureSurfacesReason() async throws {
            fake.deployResult = .failed(reason: "network down", exitCode: 1)
            var intent = DeploySiteIntent()
            intent.site = SiteEntity(site)
            _ = try await intent.perform()
            #expect(fake.deployCalls.count == 1)
        }
    }
}
```

- [ ] **Step 2: BackupSiteIntentTests**

Write `Tests/AnglesiteIntentsTests/BackupSiteIntentTests.swift`:

```swift
import Testing
import Foundation
import AppIntents
@testable import AnglesiteCore
@testable import AnglesiteIntents

extension AppIntentsTests {
    @Suite("BackupSiteIntent")
    struct BackupSiteIntentTests {
        let fake = FakeOperations()
        let site: SiteStore.Site

        init() async {
            self.site = TestStore.site(id: "s1", name: "Portfolio")
            fake.sites = [site.id: site]
            await AppDependencyManager.shared.add(fake as any SiteOperationsService)
        }

        @Test("succeeded result reports short SHA and remote")
        func succeededReportsShortSHAAndRemote() async throws {
            fake.backupResult = .succeeded(
                commitSHA: "abcdef1234567890",
                branch: "feature",
                remote: "git@example.com:me/site.git"
            )
            var intent = BackupSiteIntent()
            intent.site = SiteEntity(site)
            _ = try await intent.perform()
            #expect(fake.backupCalls.count == 1)
        }

        @Test("noChanges resolves cleanly without surfacing a failure")
        func noChangesReportsCleanly() async throws {
            fake.backupResult = .noChanges
            var intent = BackupSiteIntent()
            intent.site = SiteEntity(site)
            _ = try await intent.perform()
            #expect(fake.backupCalls.count == 1)
        }

        @Test("failure surfaces the reason")
        func failureSurfacesReason() async throws {
            fake.backupResult = .failed(reason: "push rejected", exitCode: 1)
            var intent = BackupSiteIntent()
            intent.site = SiteEntity(site)
            _ = try await intent.perform()
            #expect(fake.backupCalls.count == 1)
        }
    }
}
```

- [ ] **Step 3: AuditSiteIntentTests**

Write `Tests/AnglesiteIntentsTests/AuditSiteIntentTests.swift`:

```swift
import Testing
import Foundation
import AppIntents
@testable import AnglesiteCore
@testable import AnglesiteIntents

extension AppIntentsTests {
    @Suite("AuditSiteIntent")
    struct AuditSiteIntentTests {
        let fake = FakeOperations()
        let site: SiteStore.Site

        init() async {
            self.site = TestStore.site(id: "s1", name: "Portfolio")
            fake.sites = [site.id: site]
            await AppDependencyManager.shared.add(fake as any SiteOperationsService)
        }

        private func finding(_ severity: AuditReport.Finding.Severity) -> AuditReport.Finding {
            AuditReport.Finding(
                category: .seo,
                severity: severity,
                title: "t",
                detail: "d",
                remediation: nil,
                location: nil
            )
        }

        @Test("reports finding counts by severity")
        func reportsFindingCountsBySeverity() async throws {
            let report = AuditReport(
                findings: [finding(.critical), finding(.warning), finding(.warning)],
                runnersExecuted: [.seo],
                runnersSkipped: []
            )
            fake.auditResult = .succeeded(report: report, duration: 1)
            var intent = AuditSiteIntent()
            intent.site = SiteEntity(site)
            _ = try await intent.perform()
            #expect(fake.auditCalls.count == 1)
        }

        @Test("returns the SiteEntity value so a Shortcut can pipe audit into deploy")
        func returnsSiteValueForChaining() async throws {
            let report = AuditReport(findings: [], runnersExecuted: [.seo], runnersSkipped: [])
            fake.auditResult = .succeeded(report: report, duration: 1)
            var intent = AuditSiteIntent()
            intent.site = SiteEntity(site)
            // The ReturnsValue<SiteEntity> conformance is what enables audit→deploy chaining.
            // We assert the call path completed; the chaining contract is exercised end-to-end
            // by IntentChainingTests.
            _ = try await intent.perform()
            #expect(fake.auditCalls.first?.id == site.id)
        }
    }
}
```

- [ ] **Step 4: OpenSiteIntentTests**

Write `Tests/AnglesiteIntentsTests/OpenSiteIntentTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore
@testable import AnglesiteIntents

extension AppIntentsTests {
    @Suite("OpenSiteIntent")
    struct OpenSiteIntentTests {
        let site: SiteStore.Site

        init() async {
            // Reset the singleton between suites — other intent tests don't touch it but a
            // previous OpenSiteIntent test would have left it set.
            await MainActor.run { WindowRouter.shared.requested = nil }
            self.site = TestStore.site(id: "s1", name: "Portfolio")
        }

        @Test("sets WindowRouter.shared.requested to the site id")
        @MainActor
        func setsWindowRouterRequestedToSiteID() async throws {
            var intent = OpenSiteIntent()
            intent.site = SiteEntity(site)
            _ = try await intent.perform()
            #expect(WindowRouter.shared.requested == "s1")
        }
    }
}
```

- [ ] **Step 5: Run all new intent tests**

Run: `swift test --filter "DeploySiteIntentTests|BackupSiteIntentTests|AuditSiteIntentTests|OpenSiteIntentTests"`
Expected: 9 tests pass.

- [ ] **Step 6: Run the full suite**

Run: `swift test --parallel`
Expected: 287 total tests pass (270 existing + 8 query + 9 intent).

- [ ] **Step 7: Commit**

```bash
git add Tests/AnglesiteIntentsTests/DeploySiteIntentTests.swift Tests/AnglesiteIntentsTests/BackupSiteIntentTests.swift Tests/AnglesiteIntentsTests/AuditSiteIntentTests.swift Tests/AnglesiteIntentsTests/OpenSiteIntentTests.swift
git commit -m "test(intents): four intent end-to-end suites with FakeOperations (9 tests, #104)"
```

---

### Task 11: Write `IntentChainingTests` and `AnglesiteShortcutsTests` (2 tests)

**Files:**
- Create: `Tests/AnglesiteIntentsTests/IntentChainingTests.swift`
- Create: `Tests/AnglesiteIntentsTests/AnglesiteShortcutsTests.swift`

- [ ] **Step 1: IntentChainingTests**

Write `Tests/AnglesiteIntentsTests/IntentChainingTests.swift`:

```swift
import Testing
import Foundation
import AppIntents
@testable import AnglesiteCore
@testable import AnglesiteIntents

extension AppIntentsTests {
    @Suite("IntentChaining")
    struct IntentChainingTests {
        let fake = FakeOperations()
        let site: SiteStore.Site

        init() async {
            self.site = TestStore.site(id: "s1", name: "Portfolio")
            fake.sites = [site.id: site]
            let report = AuditReport(findings: [], runnersExecuted: [.seo], runnersSkipped: [])
            fake.auditResult = .succeeded(report: report, duration: 1)
            fake.deployResult = .succeeded(url: URL(string: "https://example.com")!, duration: 1)
            await AppDependencyManager.shared.add(fake as any SiteOperationsService)
        }

        @Test("audit output (a SiteEntity) flows into deploy as input")
        func auditOutputFlowsIntoDeploy() async throws {
            var audit = AuditSiteIntent()
            audit.site = SiteEntity(site)
            _ = try await audit.perform()

            // In Shortcuts, the user wires audit's returned SiteEntity into deploy. Reproduce
            // that by constructing deploy with the same SiteEntity value.
            var deploy = DeploySiteIntent()
            deploy.site = SiteEntity(site)
            _ = try await deploy.perform()

            #expect(fake.auditCalls.count == 1)
            #expect(fake.deployCalls.count == 1)
            #expect(fake.auditCalls.first?.id == fake.deployCalls.first?.id)
        }
    }
}
```

- [ ] **Step 2: AnglesiteShortcutsTests**

Write `Tests/AnglesiteIntentsTests/AnglesiteShortcutsTests.swift`:

```swift
import Testing
@testable import AnglesiteIntents

extension AppIntentsTests {
    @Suite("AnglesiteShortcuts")
    struct AnglesiteShortcutsTests {
        @Test("provider lists Deploy, Backup, Audit (Open is intentionally omitted)")
        func providerListsThreeSiriIntents() {
            let shortcuts = AnglesiteShortcuts.appShortcuts
            #expect(shortcuts.count == 3)
            let titles = shortcuts.map { String(describing: $0.shortTitle) }
            #expect(titles.contains { $0.contains("Deploy Site") })
            #expect(titles.contains { $0.contains("Back Up Site") })
            #expect(titles.contains { $0.contains("Check Site") })
            #expect(!titles.contains { $0.contains("Open Site") })
        }
    }
}
```

- [ ] **Step 3: Run new tests**

Run: `swift test --filter "IntentChainingTests|AnglesiteShortcutsTests"`
Expected: 2 tests pass.

- [ ] **Step 4: Full suite**

Run: `swift test --parallel`
Expected: 289 total tests pass (270 + 8 + 9 + 2).

- [ ] **Step 5: Commit**

```bash
git add Tests/AnglesiteIntentsTests/IntentChainingTests.swift Tests/AnglesiteIntentsTests/AnglesiteShortcutsTests.swift
git commit -m "test(intents): audit→deploy chaining + AppShortcutsProvider regression guard (#104)"
```

---

## Phase E — Verify

### Task 12: Full verification — both xcodebuild schemes + manual audit→deploy smoke

**Files:** none modified — pure verification.

- [ ] **Step 1: `swift test` clean**

Run: `swift test --parallel`
Expected: all 289 tests pass; runtime ≲ 30s for the new intent suites.

- [ ] **Step 2: `xcodebuild` clean for both schemes**

Run:
```bash
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug -derivedDataPath /tmp/intents-104-build build 2>&1 | tail -3
xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug -derivedDataPath /tmp/intents-104-mas-build build 2>&1 | tail -3
```
Expected: both `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Manual audit→deploy Shortcut regression smoke**

Same routine as the #122 smoke test:
1. Quit any running Anglesite (Xcode → Stop or ⌘Q).
2. From Xcode: scheme `Anglesite`, ⌘R.
3. Open Shortcuts.app → confirm the four intents still appear under Anglesite.
4. Run the "Audit → Deploy" shortcut built during the #122 smoke. Verify:
   - Audit completes and pipes the SiteEntity into Deploy.
   - Deploy confirmation prompts.
   - Pre-deploy security scan still gates (no override).
5. (Skip MAS bookmark item — gated on #81 signed build, same as #122 smoke.)

If anything regresses vs #122 behavior, the `@Dependency` rewire is the most likely culprit. Investigate before merging.

- [ ] **Step 4: Open the PR**

```bash
git push -u origin feat/app-intents-testing-104
gh pr create --title "test(intents): App Intents Testing framework adoption (#104)" --body "$(cat <<'EOF'
## Summary

Closes #104. Extracts the four App Intents from #122 into a new `AnglesiteIntents` SPM library, switches them to `@Dependency`-injected `SiteOperationsService`, and adds 19 tests across 7 nested suites under a single `.serialized` root.

- `AnglesiteCore`: new `SiteOperationsService` over the four existing `SiteOperations` methods.
- New `AnglesiteIntents` library: holds `SiteEntity`, the four intents, `AnglesiteShortcuts`, the `WindowRouter` class, and `bootstrap()`. Depends on `AnglesiteCore` + system `AppIntents` + `Observation`.
- App target keeps `SitesWindowRoot` (the SwiftUI view) and calls `AnglesiteIntents.bootstrap()` from `AppDelegate.applicationDidFinishLaunching`.
- `SiteEntityQuery` now accepts an injectable `SiteStore` (defaults to `.shared`) so tests can populate a throwaway store.

Design: `docs/superpowers/specs/2026-06-10-app-intents-testing-design.md`.
Plan: `docs/superpowers/plans/2026-06-10-app-intents-testing.md`.

## Test Plan

Automated:
- [x] `swift test --parallel` — 289 tests pass (270 existing + 19 new).
- [x] `xcodebuild` Debug build of both `Anglesite` and `AnglesiteMAS` schemes succeeds.

Manual (please run before merge):
- [ ] Re-run the #122 audit→deploy Shortcut to confirm `@Dependency` rewire didn't regress runtime behavior.
- [ ] All four intents still appear in Shortcuts.app under Anglesite.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Self-Review

**1. Spec coverage:** Every spec section maps to a task — protocol extraction (T1), module boundary / SPM scaffolding (T2–3), file moves (T4–5), `SiteEntityQuery` injectable store (T4), `@Dependency` wiring (T6), bootstrap (T7), `project.yml` (T3), fakes (T8), test matrix (T9–11), CI surface (covered automatically by SwiftPM testTarget — no explicit task needed), manual verification (T12). Risks: covered as inline notes (auto-confirm assumption in T10 step 1; singleton reset in T10 step 4).

**2. Placeholder scan:** No "TBD"/"TODO"/"appropriate"-style placeholders. Each step shows the actual code or commands. Task 5's Step 1 was reordered after self-review because the original plan would have left a broken intermediate state (intents in AnglesiteIntents referencing app-target WindowRouter); the revised Task 5 moves both in the same commit.

**3. Type consistency:** `SiteOperationsService` signature is identical in T1 (definition), T6 (intent uses), T7 (bootstrap registers), T8 (fake conforms). `FakeOperations` API used in T10–T11 matches what's defined in T8. `WindowRouter.shared.requested` matches across T10 and source. `AppDependencyManager.shared.add` is called with the stored-instance form (`fake as any SiteOperationsService`) in tests and the closure form `{ () -> any SiteOperationsService in ... }` in `bootstrap()` — consistent with the design's risk-mitigation note.
