# Phase B — App Intents Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose Anglesite's deploy/backup/audit/open-site operations to Siri and Shortcuts via App Intents, wrapping the existing deterministic command actors with no LLM involvement.

**Architecture:** A `SiteEntity` + `EntityStringQuery` backed by `SiteStore.shared` lets Siri/Shortcuts pick a site. A target-gated `SiteAccess` helper grants folder access (no-op on DevID, security-scoped bookmark resolution on MAS). A `CommandFactory` + pure `SiteOperations` core makes the Result→dialog logic unit-testable; thin `AppIntent` structs adapt that core to the App Intents runtime. An `AppShortcutsProvider` registers curated phrases.

**Tech Stack:** Swift 6.4 / SwiftUI (macOS 27), App Intents framework, Swift Testing (`@Test`), xcodegen project (directory-globbed sources — no project.yml edits needed for new files).

---

## File Structure

New files (all auto-discovered: `AnglesiteApp` is directory-globbed in `project.yml`; `AnglesiteCore` is SPM-globbed):

- `Sources/AnglesiteCore/SiteAccess.swift` — security-scoped access wrapper (Core; both targets).
- `Sources/AnglesiteApp/Intents/SiteEntity.swift` — `SiteEntity` + `SiteEntityQuery`.
- `Sources/AnglesiteApp/Intents/CommandFactory.swift` — factory protocol + live impl.
- `Sources/AnglesiteApp/Intents/SiteOperations.swift` — testable Result core + dialog mapping.
- `Sources/AnglesiteApp/Intents/SiteIntents.swift` — the four `AppIntent` structs.
- `Sources/AnglesiteApp/Intents/WindowRouter.swift` — `@MainActor @Observable` open-site router.
- `Sources/AnglesiteApp/Intents/AnglesiteShortcuts.swift` — `AppShortcutsProvider`.
- `Tests/AnglesiteCoreTests/SiteAccessTests.swift`
- `Tests/AnglesiteCoreTests/SiteOperationsTests.swift` — uses `@testable import AnglesiteApp`? No — see note.

> **Note on test target:** `SiteOperations`, `CommandFactory`, and `SiteEntity` live in the **app target** (`AnglesiteApp`), which has no unit-test bundle wired for SwiftPM (`swift test` covers `AnglesiteCore`/`AnglesiteBridge` only). To keep `SiteOperations` and dialog mapping unit-testable under `swift test`, **put `SiteOperations`, `CommandFactory`, the dialog mapping, and `SiteAccess` in `AnglesiteCore`** (they have no App Intents dependency). Only `SiteEntity`, the `AppIntent` structs, `WindowRouter`, and `AnglesiteShortcuts` (which `import AppIntents` / need the app scene) stay in `AnglesiteApp`. Revised placement is reflected per-task below.

Revised final placement:
- **Core (testable under `swift test`):** `SiteAccess.swift`, `CommandFactory.swift`, `SiteOperations.swift` (incl. dialog strings).
- **App (App Intents runtime, manual smoke):** `Intents/SiteEntity.swift`, `Intents/SiteIntents.swift`, `Intents/WindowRouter.swift`, `Intents/AnglesiteShortcuts.swift`.

---

## Task 1: `SiteAccess` security-scoped wrapper

**Files:**
- Create: `Sources/AnglesiteCore/SiteAccess.swift`
- Test: `Tests/AnglesiteCoreTests/SiteAccessTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import AnglesiteCore

struct SiteAccessTests {
    private func makeSite(path: URL, bookmark: Data? = nil) -> SiteStore.Site {
        SiteStore.Site(id: "id-\(path.lastPathComponent)", name: path.lastPathComponent,
                       path: path, isValid: true, missingSentinels: [], bookmarkData: bookmark)
    }

    @Test("DevID: passes the site path straight through and returns the body value")
    func devIDPassThrough() async throws {
        let dir = URL(fileURLWithPath: "/tmp/example-site", isDirectory: true)
        let site = makeSite(path: dir)
        let store = SiteStore(fileManager: .default, settings: .shared)
        let received = await SiteAccess.capturedURL(for: site) // helper defined in impl for the test
        #expect(received == nil) // not yet run
        let value = try await SiteAccess.withScopedAccess(to: site, in: store) { url -> String in
            #expect(url == dir)
            return "ran:\(url.lastPathComponent)"
        }
        #expect(value == "ran:example-site")
    }
}
```

> Remove the `capturedURL` line — it's illustrative. Final test keeps only the `withScopedAccess` call + assertions. (Adjusted in Step 3 if the `SiteStore(fileManager:settings:)` init differs; confirm signature against `SiteStore.swift:65`.)

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter SiteAccessTests`
Expected: FAIL — `SiteAccess` is not defined.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Grants folder access around a single unit of work for a site, then releases it.
///
/// - DevID (non-sandboxed): passes `site.path` straight through.
/// - MAS (`ANGLESITE_MAS`): resolves the site's persisted security-scoped bookmark
///   (`SiteStore.bookmarkData`), holds the grant for the duration of `body`, then stops.
///   Mirrors `SiteWindow.acquireGrant` but short-lived, so background intents work with no
///   window open. Throws `Error.noGrant` if the site has no bookmark.
public enum SiteAccess {
    public enum AccessError: Error, Sendable, Equatable {
        /// No security-scoped bookmark for this site (MAS only). Carries a user-facing message.
        case noGrant(String)
    }

    public static func withScopedAccess<T: Sendable>(
        to site: SiteStore.Site,
        in store: SiteStore = .shared,
        _ body: (URL) async -> T
    ) async throws -> T {
        #if ANGLESITE_MAS
        guard let data = await store.bookmarkData(for: site.id) else {
            throw AccessError.noGrant(
                "\(site.name) has no folder grant. Open it once via Open Folder… in Anglesite, then try again."
            )
        }
        let resolved = try SecurityScopedBookmark.resolve(data)
        guard resolved.url.startAccessingSecurityScopedResource() else {
            throw AccessError.noGrant("Couldn't access \(site.name)'s folder. Re-add it via Open Folder… in Anglesite.")
        }
        defer { resolved.url.stopAccessingSecurityScopedResource() }
        if resolved.isStale, let fresh = try? SecurityScopedBookmark.create(for: resolved.url) {
            try? await store.setBookmark(fresh, for: site.id)
        }
        return await body(resolved.url)
        #else
        return await body(site.path)
        #endif
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter SiteAccessTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SiteAccess.swift Tests/AnglesiteCoreTests/SiteAccessTests.swift
git commit -m "feat(intents): SiteAccess security-scoped wrapper for headless site ops"
```

---

## Task 2: `CommandFactory` protocol + live implementation

**Files:**
- Create: `Sources/AnglesiteCore/CommandFactory.swift`
- Test: covered indirectly by Task 4 (no standalone test — it's a trivial factory).

- [ ] **Step 1: Write the implementation**

```swift
import Foundation

/// Constructs the deterministic command actors the intents wrap. The live implementation
/// returns the real zero-arg actors; tests inject a fake whose actors are built with the
/// actors' existing closure seams to return canned `Result`s (see `SiteOperationsTests`).
public protocol CommandFactory: Sendable {
    func deploy() -> DeployCommand
    func backup() -> BackupCommand
    func audit() -> AuditCommand
}

public struct LiveCommandFactory: CommandFactory {
    public init() {}
    public func deploy() -> DeployCommand { DeployCommand() }
    public func backup() -> BackupCommand { BackupCommand() }
    public func audit() -> AuditCommand { AuditCommand() }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build --package-path .`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteCore/CommandFactory.swift
git commit -m "feat(intents): CommandFactory seam over the deploy/backup/audit actors"
```

---

## Task 3: `SiteOperations` core + dialog mapping

`SiteOperations` resolves a site id against `SiteStore`, runs the chosen command inside
`SiteAccess.withScopedAccess`, and maps `noGrant`/not-found to the command's own `.failed`
case so callers see one uniform Result type. Pure dialog functions turn each Result into a
user-facing string.

**Files:**
- Create: `Sources/AnglesiteCore/SiteOperations.swift`
- Test: `Tests/AnglesiteCoreTests/SiteOperationsTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import AnglesiteCore

struct SiteOperationsTests {
    // A factory whose actors are built with fake closure seams returning canned outputs.
    private struct FakeFactory: CommandFactory {
        let backupResult: ProcessSupervisor.RunResult
        func deploy() -> DeployCommand { DeployCommand() }
        func backup() -> BackupCommand {
            BackupCommand(
                runner: { _, args in
                    // Drive backup to .noChanges: work-tree ok, branch feature, remote set, clean status.
                    switch args.first {
                    case "rev-parse": return .init(stdout: "feature\n", stderr: "", exitCode: 0)
                    case "remote": return .init(stdout: "git@example.com:me/site.git\n", stderr: "", exitCode: 0)
                    case "status": return .init(stdout: "", stderr: "", exitCode: 0) // clean → noChanges
                    default: return .init(stdout: "", stderr: "unmocked", exitCode: 1)
                    }
                },
                streamer: { _, _, _ in (0, "") },
                clock: { Date(timeIntervalSince1970: 1_780_000_000) }
            )
        }
        func audit() -> AuditCommand { AuditCommand() }
    }

    private func storeWith(_ site: SiteStore.Site) -> SiteStore {
        let store = SiteStore(fileManager: .default, settings: .shared)
        // Seed via the test seam; if SiteStore has no public seeding API, use `add`/inject.
        return store
    }

    @Test("backup on a clean feature branch maps to a 'no changes' dialog")
    func backupNoChanges() async {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let site = SiteStore.Site(id: "s1", name: "Portfolio", path: dir, isValid: true, missingSentinels: [])
        let ops = SiteOperations(factory: FakeFactory(backupResult: .init(stdout: "", stderr: "", exitCode: 0)),
                                 store: storeWith(site))
        let result = await ops.backup(site: site)
        #expect(result == .noChanges)
        #expect(SiteOperations.dialog(forBackup: result) == "No changes to back up.")
    }

    @Test("audit dialog summarizes findings by severity")
    func auditDialog() {
        let findings = [
            AuditReport.Finding(category: .seo, severity: .critical, title: "t", detail: "d"),
            AuditReport.Finding(category: .seo, severity: .warning, title: "t", detail: "d"),
            AuditReport.Finding(category: .seo, severity: .warning, title: "t", detail: "d"),
        ]
        let report = AuditReport(findings: findings, runnersExecuted: [.seo], runnersSkipped: [])
        let dialog = SiteOperations.dialog(forAudit: .succeeded(report: report, duration: 1))
        #expect(dialog == "Audit complete: 1 critical, 2 warning, 0 info.")
    }
}
```

> Confirm `AuditReport.Finding.init` and `AuditReport.init` parameter labels against `Sources/AnglesiteCore/AuditReport.swift` (Finding has `category, severity, title, detail` + optional `remediation`/`location`; adjust the fixture if labels differ). Confirm `SiteStore` seeding — if there is no in-memory seed seam, add a test-only convenience in `SiteOperations` that accepts the `Site` directly (see Step 3: `backup(site:)` takes the `Site`, so the store is only needed for `SiteAccess` on MAS; on DevID the store is unused and the fixture store can stay empty).

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter SiteOperationsTests`
Expected: FAIL — `SiteOperations` not defined.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Resolves a site, runs a command inside `SiteAccess`, and provides user-facing dialog
/// strings. The App Intent structs are thin adapters over this; this type is fully
/// unit-testable with a fake `CommandFactory`.
public struct SiteOperations: Sendable {
    private let factory: CommandFactory
    private let store: SiteStore

    public init(factory: CommandFactory = LiveCommandFactory(), store: SiteStore = .shared) {
        self.factory = factory
        self.store = store
    }

    // MARK: Operations

    public func deploy(site: SiteStore.Site) async -> DeployCommand.Result {
        do {
            return try await SiteAccess.withScopedAccess(to: site, in: store) { url in
                await factory.deploy().deploy(siteID: site.id, siteDirectory: url)
            }
        } catch let SiteAccess.AccessError.noGrant(message) {
            return .failed(reason: message, exitCode: nil)
        } catch {
            return .failed(reason: error.localizedDescription, exitCode: nil)
        }
    }

    public func backup(site: SiteStore.Site) async -> BackupCommand.Result {
        do {
            return try await SiteAccess.withScopedAccess(to: site, in: store) { url in
                await factory.backup().backup(siteID: site.id, siteDirectory: url)
            }
        } catch let SiteAccess.AccessError.noGrant(message) {
            return .failed(reason: message, exitCode: nil)
        } catch {
            return .failed(reason: error.localizedDescription, exitCode: nil)
        }
    }

    public func audit(site: SiteStore.Site) async -> AuditCommand.Result {
        do {
            return try await SiteAccess.withScopedAccess(to: site, in: store) { url in
                await factory.audit().audit(siteID: site.id, siteDirectory: url)
            }
        } catch let SiteAccess.AccessError.noGrant(message) {
            return .failed(reason: message, exitCode: nil)
        } catch {
            return .failed(reason: error.localizedDescription, exitCode: nil)
        }
    }

    // MARK: Dialog mapping (pure)

    public static func dialog(forDeploy result: DeployCommand.Result) -> String {
        switch result {
        case .succeeded(let url, _): return "Deployed to \(url.absoluteString)."
        case .blocked(let failures, _):
            let names = failures.map(\.id).joined(separator: ", ")
            return "Deploy blocked by the pre-deploy security scan: \(names). Resolve these in Anglesite first."
        case .failed(let reason, _): return "Deploy failed: \(reason)"
        }
    }

    public static func dialog(forBackup result: BackupCommand.Result) -> String {
        switch result {
        case .succeeded(let sha, _, let remote): return "Backed up \(sha.prefix(7)) to \(remote)."
        case .noChanges: return "No changes to back up."
        case .failed(let reason, _): return "Backup failed: \(reason)"
        }
    }

    public static func dialog(forAudit result: AuditCommand.Result) -> String {
        switch result {
        case .succeeded(let report, _):
            let c = report.findings.filter { $0.severity == .critical }.count
            let w = report.findings.filter { $0.severity == .warning }.count
            let i = report.findings.filter { $0.severity == .info }.count
            return "Audit complete: \(c) critical, \(w) warning, \(i) info."
        case .failed(let reason, _): return "Audit failed: \(reason)"
        }
    }
}
```

> `PreDeployCheck.ScanFailure` is referenced via `\.id` for the blocked message — confirm `ScanFailure` has a usable `id`/`name` string in `PreDeployCheck.swift`; if it's a different label, use the actual short identifier. Keep the message non-overridable (no "force deploy" path).

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter SiteOperationsTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SiteOperations.swift Tests/AnglesiteCoreTests/SiteOperationsTests.swift
git commit -m "feat(intents): SiteOperations core + Result→dialog mapping"
```

---

## Task 4: `SiteEntity` + `SiteEntityQuery`

**Files:**
- Create: `Sources/AnglesiteApp/Intents/SiteEntity.swift`
- Test: manual (App Intents types build into the app target only; `swift test` does not cover `AnglesiteApp`). Verified by the build + Shortcuts smoke in Task 8.

- [ ] **Step 1: Write the implementation**

```swift
import AppIntents
import AnglesiteCore
import Foundation

/// An Anglesite site, addressable by Siri/Shortcuts. Backed live by `SiteStore.shared`.
struct SiteEntity: AppEntity, Identifiable {
    let id: String
    let displayName: String
    let directory: URL

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Site" }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)", subtitle: "\(directory.path)")
    }

    static var defaultQuery = SiteEntityQuery()

    init(_ site: SiteStore.Site) {
        self.id = site.id
        self.displayName = site.name
        self.directory = site.path
    }
}

/// Resolves sites by id (Shortcuts re-resolution) and by name (Siri "my portfolio site").
struct SiteEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [SiteEntity] {
        let sites = await SiteStore.shared.sites
        return sites.filter { identifiers.contains($0.id) }.map(SiteEntity.init)
    }

    func entities(matching string: String) async throws -> [SiteEntity] {
        let sites = await SiteStore.shared.sites
        let needle = string.lowercased()
        return sites.filter { $0.name.lowercased().contains(needle) }.map(SiteEntity.init)
    }

    func suggestedEntities() async throws -> [SiteEntity] {
        await SiteStore.shared.sites.map(SiteEntity.init)
    }

    func defaultResult() async -> SiteEntity? {
        let sites = await SiteStore.shared.sites
        return sites.count == 1 ? sites.first.map(SiteEntity.init) : nil
    }
}
```

> `await SiteStore.shared.sites` reads the actor's `private(set) public var sites`. If the registry isn't loaded yet in a background intent process, call `try? await SiteStore.shared.load()` first inside each query method (cheap, idempotent). Add that line if the smoke test shows an empty list from a cold intent launch.

- [ ] **Step 2: Build the app target to verify it compiles**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteApp/Intents/SiteEntity.swift
git commit -m "feat(intents): SiteEntity + EntityStringQuery backed by SiteStore (#89)"
```

---

## Task 5: The four `AppIntent` structs

**Files:**
- Create: `Sources/AnglesiteApp/Intents/SiteIntents.swift`
- Test: manual (app target). Logic is already unit-tested via `SiteOperations` (Task 3).

- [ ] **Step 1: Write the implementation**

```swift
import AppIntents
import AnglesiteCore

private let ops = SiteOperations()

private func site(from entity: SiteEntity) async -> SiteStore.Site? {
    await SiteStore.shared.find(id: entity.id)
}

struct DeploySiteIntent: AppIntent {
    static var title: LocalizedStringResource = "Deploy Site"
    static var description = IntentDescription("Deploy a site to production with Anglesite.")

    @Parameter(title: "Site") var site: SiteEntity

    static var parameterSummary: some ParameterSummary { Summary("Deploy \(\.$site)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await requestConfirmation(
            result: .result(dialog: "Deploy \(site.displayName) to production?")
        )
        guard let resolved = await SiteOperations().resolvedSite(for: site) else {
            return .result(dialog: "Couldn't find \(site.displayName).")
        }
        let result = await SiteOperations().deploy(site: resolved)
        return .result(dialog: IntentDialog(stringLiteral: SiteOperations.dialog(forDeploy: result)))
    }
}

struct BackupSiteIntent: AppIntent {
    static var title: LocalizedStringResource = "Back Up Site"
    static var description = IntentDescription("Commit and push a site backup with Anglesite.")

    @Parameter(title: "Site") var site: SiteEntity
    static var parameterSummary: some ParameterSummary { Summary("Back up \(\.$site)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let resolved = await SiteOperations().resolvedSite(for: site) else {
            return .result(dialog: "Couldn't find \(site.displayName).")
        }
        let result = await SiteOperations().backup(site: resolved)
        return .result(dialog: IntentDialog(stringLiteral: SiteOperations.dialog(forBackup: result)))
    }
}

struct AuditSiteIntent: AppIntent {
    static var title: LocalizedStringResource = "Check Site"
    static var description = IntentDescription("Run an Anglesite audit and report findings.")

    @Parameter(title: "Site") var site: SiteEntity
    static var parameterSummary: some ParameterSummary { Summary("Check \(\.$site)") }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<SiteEntity> {
        guard let resolved = await SiteOperations().resolvedSite(for: site) else {
            return .result(value: site, dialog: "Couldn't find \(site.displayName).")
        }
        let result = await SiteOperations().audit(site: resolved)
        // Return the site as the value so a Shortcut can pipe it into Deploy.
        return .result(value: site, dialog: IntentDialog(stringLiteral: SiteOperations.dialog(forAudit: result)))
    }
}

struct OpenSiteIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Site"
    static var description = IntentDescription("Open a site window in Anglesite.")
    static var openAppWhenRun = true

    @Parameter(title: "Site") var site: SiteEntity
    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$site)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        WindowRouter.shared.requestOpen(siteID: site.id)
        return .result(dialog: "Opening \(site.displayName).")
    }
}
```

> Add `func resolvedSite(for entity: SiteEntity) async -> SiteStore.Site?` to `SiteOperations` (Task 3) — it just calls `await store.find(id: entity.id)`. Add it in this task if not already present, with a one-line follow-up commit folded in. Confirm App Intents on macOS 27 still uses `requestConfirmation(result:)`; if the SDK signature changed, use the current `requestConfirmation` overload (the intent must pause for user confirmation before the deploy call — that behavior is the requirement).

- [ ] **Step 2: Build the app target**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteApp/Intents/SiteIntents.swift Sources/AnglesiteCore/SiteOperations.swift
git commit -m "feat(intents): Deploy/Backup/Audit/OpenSite App Intents (#88)"
```

---

## Task 6: `WindowRouter` + scene wiring (OpenSite routing)

Decision (deferred from the spec): use a `@MainActor @Observable` router singleton that the
"Sites" window observes — simplest, no new deps, and `openWindow(value:)` already exists in
`AnglesiteApp.body`.

**Files:**
- Create: `Sources/AnglesiteApp/Intents/WindowRouter.swift`
- Modify: `Sources/AnglesiteApp/AnglesiteApp.swift` (observe the router in the "Sites" Window)

- [ ] **Step 1: Write the router**

```swift
import Foundation
import Observation

/// Lets `OpenSiteIntent` (which can't call SwiftUI's `openWindow`) request a site window.
/// The "Sites" scene observes `requested` and opens/focuses the window.
@MainActor
@Observable
final class WindowRouter {
    static let shared = WindowRouter()
    private init() {}

    /// The site id the intent asked to open; cleared by the scene after handling.
    var requested: String?

    func requestOpen(siteID: String) { requested = siteID }
}
```

- [ ] **Step 2: Wire the scene** — in `AnglesiteApp.swift`, add an observer to the "Sites" `Window` content view that opens the requested site and clears the request.

```swift
// Inside the `Window("Sites", id: "sites") { ... }` content closure, add the modifier:
.onChange(of: WindowRouter.shared.requested) { _, newValue in
    if let id = newValue {
        openWindow(value: id)            // WindowGroup(for: String.self) already exists below
        WindowRouter.shared.requested = nil
    }
}
```

> If `AnglesiteApp` is not already observing `WindowRouter.shared` (an `@Observable`), read it once in the view body (e.g. `let _ = WindowRouter.shared.requested`) so `.onChange` tracks it, or hold it as `@State private var router = WindowRouter.shared`. Confirm the exact content view inside the "Sites" Window (around `AnglesiteApp.swift:63`) and attach the modifier there.

- [ ] **Step 3: Build the app target**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteApp/Intents/WindowRouter.swift Sources/AnglesiteApp/AnglesiteApp.swift
git commit -m "feat(intents): WindowRouter wiring for OpenSiteIntent"
```

---

## Task 7: `AppShortcutsProvider` + curated phrases (#90)

**Files:**
- Create: `Sources/AnglesiteApp/Intents/AnglesiteShortcuts.swift`

- [ ] **Step 1: Write the provider**

```swift
import AppIntents

/// Curated Siri phrases. Appear in Spotlight + Siri suggestions. ${applicationName} resolves
/// to the app's display name ("Anglesite") on both targets.
struct AnglesiteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
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

> The audit→deploy chain is composed in the Shortcuts editor: `AuditSiteIntent` returns a
> `SiteEntity` value (Task 5) that the user pipes into `DeploySiteIntent`, whose
> `requestConfirmation` still gates the deploy. No extra `opensIntent` plumbing is required for
> v0; if richer "audit passes → auto-offer deploy" UX is wanted later, add `opensIntent` then.

- [ ] **Step 2: Build the app target**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteApp/Intents/AnglesiteShortcuts.swift
git commit -m "feat(intents): AppShortcutsProvider with curated phrases (#90)"
```

---

## Task 8: Both-target build + manual smoke + docs

**Files:**
- Modify: `docs/build-plan.md` (mark Phase B started/done)

- [ ] **Step 1: Build both targets**

```bash
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build
```
Expected: both BUILD SUCCEEDED.

- [ ] **Step 2: Run the full test suite**

Run: `swift test --package-path .`
Expected: all pass (existing 270 + the new `SiteAccessTests`/`SiteOperationsTests`).

- [ ] **Step 3: Manual smoke (record results in the PR description)**

  - Launch the DevID app; open Shortcuts.app → confirm Deploy/Back Up/Check/Open actions appear under Anglesite with a site picker.
  - Build a "Check my Portfolio then Deploy" shortcut; run it; confirm the deploy confirmation prompt appears and the pre-deploy scan still gates.
  - Single-site case: confirm no picker prompt (auto-select).
  - Siri: "Check my site with Anglesite" → confirm voice invocation.
  - (MAS, when a signed build is available per #81) Background-run a backup shortcut with no window open → confirm `SiteAccess` resolves the bookmark and the backup completes; with a site that has no grant, confirm the friendly "Open Folder…" dialog.

- [ ] **Step 4: Update build-plan.md**

Add a "Phase B — App Intents integration" entry noting #89/#88/#90 landed (entity, four intents, shortcuts provider, `SiteAccess` headless grant), with the MAS background-backup smoke gated on the #81 signed build.

- [ ] **Step 5: Commit**

```bash
git add docs/build-plan.md
git commit -m "docs: mark Phase B App Intents complete (#88, #89, #90)"
```

---

## Self-Review

**Spec coverage:** SiteEntity+query (Task 4 ✓ #89), four intents with deploy confirmation (Task 5 ✓ #88), SiteAccess MAS recommendation (Task 1 ✓), CommandFactory test seam (Task 2 ✓), SiteOperations Result→dialog tests (Task 3 ✓), AppShortcutsProvider + chaining (Task 7 ✓ #90), OpenSite routing decided (Task 6 ✓), both-target build + smoke + docs (Task 8 ✓). All spec sections mapped.

**Placeholder scan:** The deferred spec items (OpenSite routing, chaining surface) are now concretely decided in Tasks 6 and 7. The `>` notes flag signatures to confirm against real source (AuditReport labels, ScanFailure.id, SiteStore init, requestConfirmation overload) — these are verification steps, not placeholders; each task still ships complete code.

**Type consistency:** `SiteOperations` (factory+store init), `dialog(forDeploy:/forBackup:/forAudit:)`, `SiteAccess.withScopedAccess(to:in:_:)`, `SiteAccess.AccessError.noGrant`, `WindowRouter.shared.requestOpen(siteID:)`/`requested`, `CommandFactory.deploy()/backup()/audit()` are used consistently across tasks. `SiteEntity.id == SiteStore.Site.id` (String) threads through query → intent → `find(id:)`.
