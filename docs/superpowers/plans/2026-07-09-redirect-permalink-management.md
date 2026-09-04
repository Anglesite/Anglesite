# Redirect/Permalink Management Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every site a git-tracked redirects store, a minimal delete action that offers to cover a removed page's URL, and a pre-deploy scan that flags any published route that vanished with no redirect covering it.

**Architecture:** A new `RedirectsStore` (AnglesiteCore) owns `Source/redirects.json`; a small Astro integration in the template turns it into both live dev-server redirects and a `dist/_redirects` file Cloudflare Pages serves directly. A new `DeployedRoutesSnapshot` (Config/, app-owned) records the route set after every successful deploy; `RouteCoverageScanner` (pure function) diffs the current route set against that snapshot and produces `PreDeployCheck.ScanWarning`s that flow through the existing health-badge pipeline untouched. A minimal git-tracked delete action lands in the navigator (mirroring the existing Cleanup-section delete), offering to open a small "add a redirect" sheet pre-filled with the route that was just removed.

**Tech Stack:** Swift 6.4 / SwiftUI (AnglesiteCore, AnglesiteApp), Swift Testing, TypeScript + Astro integrations (Resources/Template), `node:test`.

## Global Constraints

- Swift Testing (`import Testing`, `@Test`, `#expect`) for all new Swift tests — this repo's convention (not XCTest) for new code.
- `redirects.json` lives at `Source/redirects.json` (git-tracked); `last-deployed-routes.json` lives at `Config/` (app-owned, never git).
- `RedirectsStore.init(sourceDirectory:fileManager:)` — deliberately not `configDirectory:`, since this store is NOT rooted at `Config/` like its siblings.
- `DeployCommand.deploy`'s two new parameters (`configDirectory`, `currentRoutes`) get defaults (`nil` / `[]`) so its ~20 existing test call sites and the two other production call sites (`SocialWorkerProvisionCommand.swift`, `SiteOperations.swift`) are unaffected and simply skip route-coverage scanning. Only `DeployModel`'s single call site threads real values through.
- The redirect-offer trigger is delete only (not rename) — the navigator's existing Rename never changes a route (see spec §"Scope revision").
- Only `Page` rows have a route (`SiteContentGraph.Page.route`); `Post` has no `route` field, so the redirect-offer flow only applies when deleting a page.

---

## Task 1: `RedirectsStore` (AnglesiteCore)

**Files:**
- Create: `Sources/AnglesiteCore/RedirectsStore.swift`
- Test: `Tests/AnglesiteCoreTests/RedirectsStoreTests.swift`

**Interfaces:**
- Produces: `RedirectsStore.RedirectEntry { source: String, destination: String, code: RedirectsStore.RedirectEntry.Code }`, `RedirectsStore(sourceDirectory: URL, fileManager: FileManager = .default)`, `func load() throws -> [RedirectEntry]`, `func save(_ entries: [RedirectEntry]) throws`, `RedirectsStore.ValidationError`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/AnglesiteCoreTests/RedirectsStoreTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("RedirectsStore")
struct RedirectsStoreTests {
    private func tempSourceDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RedirectsStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("load on a missing file returns an empty array, not a throw")
    func loadMissingReturnsEmpty() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RedirectsStore(sourceDirectory: dir)
        #expect(try store.load() == [])
    }

    @Test("save then load round-trips entries through redirects.json")
    func saveLoadRoundTrips() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RedirectsStore(sourceDirectory: dir)
        let entries = [RedirectsStore.RedirectEntry(source: "/old", destination: "/new", code: .permanent)]
        try store.save(entries)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("redirects.json").path))
        #expect(try store.load() == entries)
    }

    @Test("save rejects a source that doesn't start with /")
    func rejectsMissingLeadingSlash() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RedirectsStore(sourceDirectory: dir)
        let entries = [RedirectsStore.RedirectEntry(source: "old", destination: "/new", code: .permanent)]
        #expect(throws: RedirectsStore.ValidationError.sourceMustStartWithSlash("old")) {
            try store.save(entries)
        }
    }

    @Test("save rejects a duplicate source")
    func rejectsDuplicateSource() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RedirectsStore(sourceDirectory: dir)
        let entries = [
            RedirectsStore.RedirectEntry(source: "/a", destination: "/b", code: .permanent),
            RedirectsStore.RedirectEntry(source: "/a", destination: "/c", code: .permanent),
        ]
        #expect(throws: RedirectsStore.ValidationError.duplicateSource("/a")) {
            try store.save(entries)
        }
    }

    @Test("save rejects a source equal to its own destination")
    func rejectsSelfCycle() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RedirectsStore(sourceDirectory: dir)
        let entries = [RedirectsStore.RedirectEntry(source: "/a", destination: "/a", code: .permanent)]
        #expect(throws: RedirectsStore.ValidationError.cycle("/a", "/a")) {
            try store.save(entries)
        }
    }

    @Test("save rejects a two-hop A→B, B→A cycle")
    func rejectsTwoHopCycle() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RedirectsStore(sourceDirectory: dir)
        let entries = [
            RedirectsStore.RedirectEntry(source: "/a", destination: "/b", code: .permanent),
            RedirectsStore.RedirectEntry(source: "/b", destination: "/a", code: .permanent),
        ]
        #expect(throws: RedirectsStore.ValidationError.cycle("/a", "/b")) {
            try store.save(entries)
        }
    }

    @Test("a rejected save leaves the previously-saved file untouched")
    func rejectedSaveDoesNotOverwrite() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RedirectsStore(sourceDirectory: dir)
        let good = [RedirectsStore.RedirectEntry(source: "/a", destination: "/b", code: .permanent)]
        try store.save(good)
        let bad = [RedirectsStore.RedirectEntry(source: "/a", destination: "/a", code: .permanent)]
        #expect(throws: (any Error).self) { try store.save(bad) }
        #expect(try store.load() == good)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter RedirectsStoreTests`
Expected: FAIL to compile — `RedirectsStore` does not exist.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/AnglesiteCore/RedirectsStore.swift
import Foundation

/// Reads/writes `Source/redirects.json` — a git-tracked, ordered list of source→destination
/// path redirects for a site. Unlike `SiteConfigStore`/`ProjectConventionsStore`, this is rooted
/// at `sourceDirectory` (the `Source/` git repo), not `Config/`: redirects are site content, not
/// app-owned state, so they travel with the repo (see the design spec's §1).
///
/// A template-side Astro integration (`scripts/redirects.ts`) is the sole consumer at build time;
/// this type only owns the read/write/validate contract the app's Redirects UI and the delete
/// flow use to produce that file.
public struct RedirectsStore: Sendable {
    public struct RedirectEntry: Sendable, Equatable, Codable, Identifiable {
        public enum Code: Int, Sendable, Codable, CaseIterable {
            case permanent = 301
            case temporary = 302
        }

        public var id: String { source }
        public var source: String
        public var destination: String
        public var code: Code

        public init(source: String, destination: String, code: Code = .permanent) {
            self.source = source
            self.destination = destination
            self.code = code
        }
    }

    public enum ValidationError: Error, Equatable {
        case sourceMustStartWithSlash(String)
        case duplicateSource(String)
        /// A direct cycle: either `source == destination`, or an existing entry's destination is
        /// this entry's source and vice versa. Deep chains (A→B→C) are not resolved or rejected —
        /// matches Cloudflare's own behavior of following each hop independently.
        case cycle(String, String)
    }

    private let fileURL: URL
    private let fileManager: FileManager

    public init(sourceDirectory: URL, fileManager: FileManager = .default) {
        self.fileURL = sourceDirectory.appendingPathComponent("redirects.json")
        self.fileManager = fileManager
    }

    /// `[]` (not a throw) when the file is absent — the normal "no redirects yet" case for a
    /// freshly scaffolded site.
    public func load() throws -> [RedirectEntry] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([RedirectEntry].self, from: data)
    }

    public func save(_ entries: [RedirectEntry]) throws {
        try Self.validate(entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        try data.write(to: fileURL, options: .atomic)
    }

    public static func validate(_ entries: [RedirectEntry]) throws {
        var seenSources = Set<String>()
        var destinationBySource: [String: String] = [:]
        for entry in entries {
            guard entry.source.hasPrefix("/") else {
                throw ValidationError.sourceMustStartWithSlash(entry.source)
            }
            guard !seenSources.contains(entry.source) else {
                throw ValidationError.duplicateSource(entry.source)
            }
            seenSources.insert(entry.source)
            destinationBySource[entry.source] = entry.destination
        }
        for entry in entries {
            if entry.source == entry.destination {
                throw ValidationError.cycle(entry.source, entry.destination)
            }
            if destinationBySource[entry.destination] == entry.source {
                throw ValidationError.cycle(entry.source, entry.destination)
            }
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter RedirectsStoreTests`
Expected: PASS (7 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/RedirectsStore.swift Tests/AnglesiteCoreTests/RedirectsStoreTests.swift
git commit -m "feat(app): add RedirectsStore for Source/redirects.json (#530)"
```

---

## Task 2: `DeployedRoutesSnapshot` (AnglesiteCore)

**Files:**
- Create: `Sources/AnglesiteCore/DeployedRoutesSnapshot.swift`
- Test: `Tests/AnglesiteCoreTests/DeployedRoutesSnapshotTests.swift`

**Interfaces:**
- Produces: `DeployedRoutesSnapshot.load(from: URL) -> [String]?`, `DeployedRoutesSnapshot.save(_:to:) throws`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/AnglesiteCoreTests/DeployedRoutesSnapshotTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("DeployedRoutesSnapshot")
struct DeployedRoutesSnapshotTests {
    private func tempConfigDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeployedRoutesSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("load on a missing file returns nil")
    func loadMissingReturnsNil() throws {
        let dir = try tempConfigDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(DeployedRoutesSnapshot.load(from: dir) == nil)
    }

    @Test("save then load round-trips the route list")
    func saveLoadRoundTrips() throws {
        let dir = try tempConfigDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try DeployedRoutesSnapshot.save(["/about", "/blog/post-1"], to: dir)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("last-deployed-routes.json").path))
        #expect(DeployedRoutesSnapshot.load(from: dir) == ["/about", "/blog/post-1"])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter DeployedRoutesSnapshotTests`
Expected: FAIL to compile — `DeployedRoutesSnapshot` does not exist.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/AnglesiteCore/DeployedRoutesSnapshot.swift
import Foundation

/// Reads/writes `Config/last-deployed-routes.json` — the route set published by the most recent
/// successful deploy. App-owned state (never committed to the site's git repo, matching
/// `DependencyBaseline`'s precedent), used solely as the "previous" side of
/// `RouteCoverageScanner`'s diff.
public enum DeployedRoutesSnapshot {
    public static let filename = "last-deployed-routes.json"

    /// `nil` (not a throw) when the file is absent or unreadable — the normal "no prior deploy
    /// yet" case, which `RouteCoverageScanner` treats as "nothing to diff against."
    public static func load(from configDirectory: URL) -> [String]? {
        let url = configDirectory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    public static func save(_ routes: [String], to configDirectory: URL) throws {
        let url = configDirectory.appendingPathComponent(filename)
        let data = try JSONEncoder().encode(routes.sorted())
        try data.write(to: url, options: .atomic)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter DeployedRoutesSnapshotTests`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/DeployedRoutesSnapshot.swift Tests/AnglesiteCoreTests/DeployedRoutesSnapshotTests.swift
git commit -m "feat(app): add DeployedRoutesSnapshot for Config/last-deployed-routes.json (#530)"
```

---

## Task 3: `RouteCoverageScanner` + `PreDeployCheck.ScanWarning.Category.orphanedRoute`

**Files:**
- Create: `Sources/AnglesiteCore/RouteCoverageScanner.swift`
- Modify: `Sources/AnglesiteCore/PreDeployCheck.swift:26-31` (add `.orphanedRoute` case)
- Test: `Tests/AnglesiteCoreTests/RouteCoverageScannerTests.swift`

**Interfaces:**
- Consumes: `PreDeployCheck.ScanWarning(category:detail:remediation:)` (Task-independent, already exists).
- Produces: `RouteCoverageScanner.scan(currentRoutes: [String], previousRoutes: [String]?, redirectSources: Set<String>) -> [PreDeployCheck.ScanWarning]`, `PreDeployCheck.ScanWarning.Category.orphanedRoute`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/AnglesiteCoreTests/RouteCoverageScannerTests.swift
import Testing
@testable import AnglesiteCore

@Suite("RouteCoverageScanner")
struct RouteCoverageScannerTests {
    @Test("no previous snapshot: no warnings (first deploy)")
    func noPreviousSnapshot() {
        let warnings = RouteCoverageScanner.scan(
            currentRoutes: ["/about"], previousRoutes: nil, redirectSources: [])
        #expect(warnings.isEmpty)
    }

    @Test("no routes vanished: no warnings")
    func nothingVanished() {
        let warnings = RouteCoverageScanner.scan(
            currentRoutes: ["/about", "/blog"], previousRoutes: ["/about", "/blog"], redirectSources: [])
        #expect(warnings.isEmpty)
    }

    @Test("a vanished route with no covering redirect produces one warning")
    func vanishedRouteNoRedirect() {
        let warnings = RouteCoverageScanner.scan(
            currentRoutes: ["/about"], previousRoutes: ["/about", "/old-page"], redirectSources: [])
        #expect(warnings.count == 1)
        #expect(warnings[0].category == .orphanedRoute)
        #expect(warnings[0].detail.contains("/old-page"))
    }

    @Test("a vanished route covered by a redirect produces no warning")
    func vanishedRouteCoveredByRedirect() {
        let warnings = RouteCoverageScanner.scan(
            currentRoutes: ["/about"], previousRoutes: ["/about", "/old-page"], redirectSources: ["/old-page"])
        #expect(warnings.isEmpty)
    }

    @Test("multiple vanished routes produce one warning each")
    func multipleVanishedRoutes() {
        let warnings = RouteCoverageScanner.scan(
            currentRoutes: [], previousRoutes: ["/a", "/b"], redirectSources: [])
        #expect(warnings.count == 2)
        #expect(Set(warnings.map(\.category)) == [.orphanedRoute])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter RouteCoverageScannerTests`
Expected: FAIL to compile — `RouteCoverageScanner` and `.orphanedRoute` do not exist.

- [ ] **Step 3: Add the `.orphanedRoute` category**

In `Sources/AnglesiteCore/PreDeployCheck.swift`, change:

```swift
    public struct ScanWarning: Sendable, Equatable, Codable {
        public enum Category: String, Sendable, Codable {
            case missingOgImage = "missing-og-image"
            case maintenanceOverdue = "maintenance-overdue"
            case seoCritical = "seo-critical"
            case seoWarning = "seo-warning"
        }
```

to:

```swift
    public struct ScanWarning: Sendable, Equatable, Codable {
        public enum Category: String, Sendable, Codable {
            case missingOgImage = "missing-og-image"
            case maintenanceOverdue = "maintenance-overdue"
            case seoCritical = "seo-critical"
            case seoWarning = "seo-warning"
            /// A route published by the previous deploy is no longer published and has no
            /// `redirects.json` entry covering it. Computed by `RouteCoverageScanner`, not the
            /// JS-side scan script — merged into the `Outcome` by `DeployCommand.deploy`.
            case orphanedRoute = "orphaned-route"
        }
```

- [ ] **Step 4: Write the implementation**

```swift
// Sources/AnglesiteCore/RouteCoverageScanner.swift
import Foundation

/// Diffs the current published route set against the snapshot from the previous deploy
/// (`DeployedRoutesSnapshot`), flagging any route that vanished with no `redirects.json` entry
/// covering it. Pure `SiteContentGraph`/`RedirectsStore` diffing — no JS/plugin involvement,
/// unlike the rest of `PreDeployCheck`'s checks.
public enum RouteCoverageScanner {
    public static func scan(
        currentRoutes: [String],
        previousRoutes: [String]?,
        redirectSources: Set<String>
    ) -> [PreDeployCheck.ScanWarning] {
        guard let previousRoutes else { return [] }
        let current = Set(currentRoutes)
        let vanished = previousRoutes.filter { !current.contains($0) && !redirectSources.contains($0) }
        return vanished.map { route in
            PreDeployCheck.ScanWarning(
                category: .orphanedRoute,
                detail: "\(route) is no longer published and has no redirect covering it.",
                remediation: "Add a redirect for \(route) in Site Settings → Redirects, or ignore if the removal is intentional."
            )
        }
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter RouteCoverageScannerTests`
Expected: PASS (5 tests)

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/RouteCoverageScanner.swift Sources/AnglesiteCore/PreDeployCheck.swift Tests/AnglesiteCoreTests/RouteCoverageScannerTests.swift
git commit -m "feat(app): add RouteCoverageScanner and orphaned-route scan warning (#530)"
```

---

## Task 4: Wire route-coverage scanning + snapshot-write into `DeployCommand`

**Files:**
- Modify: `Sources/AnglesiteCore/DeployCommand.swift:74-172` (`deploy` signature + body)
- Test: `Tests/AnglesiteCoreTests/DeployCommandTests.swift` (append new tests; existing tests are unaffected since the new params default)

**Interfaces:**
- Consumes: `RedirectsStore(sourceDirectory:).load() throws -> [RedirectEntry]` (Task 1), `DeployedRoutesSnapshot.load(from:) -> [String]?` / `.save(_:to:) throws` (Task 2), `RouteCoverageScanner.scan(currentRoutes:previousRoutes:redirectSources:)` (Task 3).
- Produces: `DeployCommand.deploy(siteID:siteDirectory:configDirectory:currentRoutes:onPreflight:onProgress:)` — two new parameters, both defaulted so every existing call site compiles unchanged.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/AnglesiteCoreTests/DeployCommandTests.swift` (inside `struct DeployCommandTests`, using the existing `FakeExecutor` and `tmpDir` already defined in that file):

```swift
    // MARK: Route coverage (#530)

    @Test("configDirectory nil: no route-coverage warnings, no snapshot write")
    func routeCoverageSkippedWhenNoConfigDirectory() async {
        let exec = FakeExecutor()
            .set(.build, exitCode: 0, output: "building…")
            .set(.preflight, exitCode: 0, output: scanJSON(ok: true))
            .set(.wrangler, exitCode: 0, output: "Published s (1.0 sec)\n  https://s.example.workers.dev")
        let cmd = DeployCommand(tokenSource: { "tok" }, executor: exec)
        let outcomes = Locked<[PreDeployCheck.Outcome]>([])
        _ = await cmd.deploy(
            siteID: "s", siteDirectory: tmpDir,
            onPreflight: { outcomes.append($0) })
        guard case .passed(let warnings) = outcomes.get().first else {
            Issue.record("expected .passed"); return
        }
        #expect(warnings.isEmpty)
    }

    @Test("orphaned route with no redirect adds a warning to the preflight outcome")
    func orphanedRouteAddsWarning() async {
        let configDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeployCommandTests-config-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: configDir) }
        try? DeployedRoutesSnapshot.save(["/about", "/old-page"], to: configDir)

        let exec = FakeExecutor()
            .set(.build, exitCode: 0, output: "building…")
            .set(.preflight, exitCode: 0, output: scanJSON(ok: true))
            .set(.wrangler, exitCode: 0, output: "Published s (1.0 sec)\n  https://s.example.workers.dev")
        let cmd = DeployCommand(tokenSource: { "tok" }, executor: exec)
        let outcomes = Locked<[PreDeployCheck.Outcome]>([])
        let result = await cmd.deploy(
            siteID: "s", siteDirectory: tmpDir,
            configDirectory: configDir, currentRoutes: ["/about"],
            onPreflight: { outcomes.append($0) })

        guard case .passed(let warnings) = outcomes.get().first else {
            Issue.record("expected .passed"); return
        }
        #expect(warnings.contains { $0.category == .orphanedRoute && $0.detail.contains("/old-page") })
        guard case .succeeded = result else { Issue.record("expected .succeeded, got \(result)"); return }
        #expect(DeployedRoutesSnapshot.load(from: configDir) == ["/about"])
    }

    @Test("a route covered by redirects.json does not warn")
    func coveredRouteDoesNotWarn() async {
        let configDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeployCommandTests-config-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: configDir) }
        try? DeployedRoutesSnapshot.save(["/about", "/old-page"], to: configDir)
        try? RedirectsStore(sourceDirectory: tmpDir).save(
            [RedirectsStore.RedirectEntry(source: "/old-page", destination: "/about", code: .permanent)])
        defer { try? FileManager.default.removeItem(at: tmpDir.appendingPathComponent("redirects.json")) }

        let exec = FakeExecutor()
            .set(.build, exitCode: 0, output: "building…")
            .set(.preflight, exitCode: 0, output: scanJSON(ok: true))
            .set(.wrangler, exitCode: 0, output: "Published s (1.0 sec)\n  https://s.example.workers.dev")
        let cmd = DeployCommand(tokenSource: { "tok" }, executor: exec)
        let outcomes = Locked<[PreDeployCheck.Outcome]>([])
        _ = await cmd.deploy(
            siteID: "s", siteDirectory: tmpDir,
            configDirectory: configDir, currentRoutes: ["/about"],
            onPreflight: { outcomes.append($0) })

        guard case .passed(let warnings) = outcomes.get().first else {
            Issue.record("expected .passed"); return
        }
        #expect(!warnings.contains { $0.category == .orphanedRoute })
    }

    /// Minimal thread-safe box for recording values appended from `@Sendable` closures.
    private final class Locked<T>: @unchecked Sendable {
        private let lock = NSLock(); private var value: T
        init(_ v: T) { value = v }
        func append<E>(_ e: E) where T == [E] { lock.lock(); value.append(e); lock.unlock() }
        func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter DeployCommandTests`
Expected: FAIL to compile — `deploy(...)` has no `configDirectory`/`currentRoutes` parameters yet.

- [ ] **Step 3: Update `DeployCommand.deploy`**

In `Sources/AnglesiteCore/DeployCommand.swift`, change the signature at line 74:

```swift
    public func deploy(
        siteID: String,
        siteDirectory: URL,
        onPreflight: PreflightObserver? = nil,
        onProgress: ProgressHandler? = nil
    ) async -> Result {
```

to:

```swift
    public func deploy(
        siteID: String,
        siteDirectory: URL,
        /// The site's `Config/` directory. `nil` skips route-coverage scanning and the
        /// deployed-routes snapshot write entirely — callers that don't pass it (tests, and the
        /// two non-primary deploy paths in `SocialWorkerProvisionCommand`/`SiteOperations`) are
        /// unaffected (#530).
        configDirectory: URL? = nil,
        /// The site's currently published route set (from `SiteContentGraph`), used only when
        /// `configDirectory` is non-nil.
        currentRoutes: [String] = [],
        onPreflight: PreflightObserver? = nil,
        onProgress: ProgressHandler? = nil
    ) async -> Result {
```

then change lines 129-138 from:

```swift
        let preflightOutcome = Self.parseScanReport(output: preflightResult.output, exitCode: preflightResult.exitCode)
        onPreflight?(preflightOutcome)
        switch preflightOutcome {
        case .passed:
            break
        case .blocked(let failures, let warnings):
            return .blocked(failures: failures, warnings: warnings)
        case .error(let reason):
            return .failed(reason: "pre-deploy scan could not run: \(reason)", exitCode: nil)
        }
```

to:

```swift
        var preflightOutcome = Self.parseScanReport(output: preflightResult.output, exitCode: preflightResult.exitCode)
        if let configDirectory {
            let previousRoutes = DeployedRoutesSnapshot.load(from: configDirectory)
            let redirects = (try? RedirectsStore(sourceDirectory: siteDirectory).load()) ?? []
            let coverageWarnings = RouteCoverageScanner.scan(
                currentRoutes: currentRoutes,
                previousRoutes: previousRoutes,
                redirectSources: Set(redirects.map(\.source))
            )
            if !coverageWarnings.isEmpty {
                switch preflightOutcome {
                case .passed(let warnings):
                    preflightOutcome = .passed(warnings: warnings + coverageWarnings)
                case .blocked(let failures, let warnings):
                    preflightOutcome = .blocked(failures: failures, warnings: warnings + coverageWarnings)
                case .error:
                    break
                }
            }
        }
        onPreflight?(preflightOutcome)
        switch preflightOutcome {
        case .passed:
            break
        case .blocked(let failures, let warnings):
            return .blocked(failures: failures, warnings: warnings)
        case .error(let reason):
            return .failed(reason: "pre-deploy scan could not run: \(reason)", exitCode: nil)
        }
```

then change the success path at lines 165-169 from:

```swift
        if code == 0 {
            if let url = Self.extractDeployedURL(from: wranglerResult.output) {
                return .succeeded(url: url, duration: duration)
            }
            return .failed(reason: "wrangler exited cleanly but no deployed URL was found in its output", exitCode: 0)
        }
```

to:

```swift
        if code == 0 {
            if let url = Self.extractDeployedURL(from: wranglerResult.output) {
                if let configDirectory {
                    try? DeployedRoutesSnapshot.save(currentRoutes, to: configDirectory)
                }
                return .succeeded(url: url, duration: duration)
            }
            return .failed(reason: "wrangler exited cleanly but no deployed URL was found in its output", exitCode: 0)
        }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter DeployCommandTests`
Expected: PASS, including all pre-existing `DeployCommandTests` (unaffected by the defaulted params) plus the 3 new tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/DeployCommand.swift Tests/AnglesiteCoreTests/DeployCommandTests.swift
git commit -m "feat(app): merge route-coverage warnings into DeployCommand preflight (#530)"
```

---

## Task 5: Thread `configDirectory`/`currentRoutes` through `DeployModel` and its call site

**Files:**
- Modify: `Sources/AnglesiteApp/DeployModel.swift:85-89, 126-145, 152-185, 268-286`
- Modify: `Sources/AnglesiteApp/SiteWindowModel.swift:284-290`
- Test: none new — confirmed via `grep -rl "DeployModel" Tests/` that no `DeployModelTests.swift` exists (the one hit, `DeployExecutorSelectionTests.swift:8`, is an incidental doc comment, not a test of `DeployModel`). This task is thin plumbing covered end-to-end by `DeployCommandTests` from Task 4 plus manual verification in the Verification section below.

**Interfaces:**
- Consumes: `DeployCommand.deploy(siteID:siteDirectory:configDirectory:currentRoutes:onPreflight:onProgress:)` (Task 4).
- Produces: `DeployModel.deploy(siteID:siteDirectory:configDirectory:currentRoutes:containerControl:)` — two new **required** parameters (only 2 call sites in this file, plus 1 in `SiteWindowModel`, so no default needed).

- [ ] **Step 1: Update `pendingDeploy`'s tuple type**

In `Sources/AnglesiteApp/DeployModel.swift`, change lines 85-89 from:

```swift
    private var pendingDeploy: (
        siteID: String,
        siteDirectory: URL,
        containerControl: (siteID: String, control: any LocalContainerControl)?
    )?
```

to:

```swift
    private var pendingDeploy: (
        siteID: String,
        siteDirectory: URL,
        configDirectory: URL,
        currentRoutes: [String],
        containerControl: (siteID: String, control: any LocalContainerControl)?
    )?
```

- [ ] **Step 2: Update `deploy(...)`, `verifyAndSaveToken(...)`, and `runDeploy(...)`**

Change the `deploy` signature and body (lines 126-145) from:

```swift
    func deploy(
        siteID: String,
        siteDirectory: URL,
        containerControl: (siteID: String, control: any LocalContainerControl)? = nil
    ) {
        guard !isRunning else { return }
        if !hasUsableToken() {
            pendingDeploy = (siteID, siteDirectory, containerControl)
            tokenVerification = .idle
            tokenPromptPresented = true
            return
        }
```

to:

```swift
    func deploy(
        siteID: String,
        siteDirectory: URL,
        configDirectory: URL,
        currentRoutes: [String],
        containerControl: (siteID: String, control: any LocalContainerControl)? = nil
    ) {
        guard !isRunning else { return }
        if !hasUsableToken() {
            pendingDeploy = (siteID, siteDirectory, configDirectory, currentRoutes, containerControl)
            tokenVerification = .idle
            tokenPromptPresented = true
            return
        }
```

(the rest of `deploy(...)`'s body, including its `runDeploy(...)` call around line 143, is updated in the next edit below).

Update the `runDeploy` call inside `deploy(...)` (around line 143) from:

```swift
        inFlight = Task { @MainActor [weak self] in
            await self?.runDeploy(siteID: siteID, siteDirectory: siteDirectory, containerControl: containerControl)
        }
```

to:

```swift
        inFlight = Task { @MainActor [weak self] in
            await self?.runDeploy(
                siteID: siteID, siteDirectory: siteDirectory,
                configDirectory: configDirectory, currentRoutes: currentRoutes,
                containerControl: containerControl)
        }
```

Update `verifyAndSaveToken`'s retry call (around line 178) from:

```swift
        case .proceed:
            pendingDeploy = nil
            tokenPromptPresented = false
            tokenVerification = .idle
            deploy(siteID: pending.siteID, siteDirectory: pending.siteDirectory, containerControl: pending.containerControl)
```

to:

```swift
        case .proceed:
            pendingDeploy = nil
            tokenPromptPresented = false
            tokenVerification = .idle
            deploy(
                siteID: pending.siteID, siteDirectory: pending.siteDirectory,
                configDirectory: pending.configDirectory, currentRoutes: pending.currentRoutes,
                containerControl: pending.containerControl)
```

Update `runDeploy`'s signature and its call into `activeCommand.deploy` (lines 222-226 and 268-278) from:

```swift
    private func runDeploy(
        siteID: String,
        siteDirectory: URL,
        containerControl: (siteID: String, control: any LocalContainerControl)? = nil
    ) async {
```

to:

```swift
    private func runDeploy(
        siteID: String,
        siteDirectory: URL,
        configDirectory: URL,
        currentRoutes: [String],
        containerControl: (siteID: String, control: any LocalContainerControl)? = nil
    ) async {
```

and:

```swift
        let result = await activeCommand.deploy(
            siteID: siteID,
            siteDirectory: siteDirectory,
            onPreflight: { [weak self] outcome in
```

to:

```swift
        let result = await activeCommand.deploy(
            siteID: siteID,
            siteDirectory: siteDirectory,
            configDirectory: configDirectory,
            currentRoutes: currentRoutes,
            onPreflight: { [weak self] outcome in
```

- [ ] **Step 3: Update the call site in `SiteWindowModel`**

In `Sources/AnglesiteApp/SiteWindowModel.swift`, change `deploySite()` (lines 284-290) from:

```swift
    func deploySite() {
        guard let site, canRunDeploy else { return }
        Task { @MainActor in
            let containerControl = await preview.activeContainerControl()
            deploy.deploy(siteID: site.id, siteDirectory: site.sourceDirectory, containerControl: containerControl)
        }
    }
```

to:

```swift
    func deploySite() {
        guard let site, canRunDeploy else { return }
        Task { @MainActor in
            let containerControl = await preview.activeContainerControl()
            let currentRoutes = await contentGraph.pages(for: site.id).map(\.route)
            deploy.deploy(
                siteID: site.id, siteDirectory: site.sourceDirectory,
                configDirectory: site.configDirectory, currentRoutes: currentRoutes,
                containerControl: containerControl)
        }
    }
```

- [ ] **Step 4: Build and run the full app-target test suite**

Run: `swift build && swift test --parallel`
Expected: PASS — this task adds no new tests of its own; it must not break any existing ones (in particular anything under `Tests/AnglesiteAppTests` that constructs `DeployModel`, per Step 1's check).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/DeployModel.swift Sources/AnglesiteApp/SiteWindowModel.swift
git commit -m "feat(app): thread configDirectory/currentRoutes through DeployModel (#530)"
```

---

## Task 6: `SiteNavigatorModel` — minimal delete + redirect offer

**Files:**
- Modify: `Sources/AnglesiteApp/SiteNavigatorModel.swift`
- Test: `Tests/AnglesiteAppTests/SiteNavigatorModelTests.swift` — check with `grep -rl "SiteNavigatorModel" Tests/` first; if it exists, add tests there following its existing style; if not, create it following `NavigatorRenameServiceTests.swift`'s `Locked<T>` + injected-closure idiom, adapted to `@MainActor`.

**Interfaces:**
- Consumes: `NativeContentOperations.GitDelete` typealias + `NativeContentOperations.processGitDelete` (existing), `SiteContentGraph.removePage(id:) async` / `.removePost(id:) async` (existing), `RedirectsStore` (Task 1).
- Produces: `SiteNavigatorModel.DeleteCandidate { id: String, filePath: String, route: String?, displayTitle: String }`, `canDelete(_:) -> Bool`, `requestDelete(_:) async`, `cancelDelete()`, `confirmDelete() async -> String?` (returns the removed route, or nil), `saveRedirect(source:destination:code:) async -> Bool`.

- [ ] **Step 1: Write the failing tests**

Confirmed via `grep -rl "SiteNavigatorModel" Tests/` that no test file exists yet — this creates `Tests/AnglesiteAppTests/SiteNavigatorModelTests.swift` fresh, following `NavigatorRenameServiceTests.swift`'s injected-closure + `Locked<T>` idiom, adapted to `@MainActor` and to `SiteContentGraph.upsertPage` for fixture setup.

```swift
// Tests/AnglesiteAppTests/SiteNavigatorModelTests.swift (new file, or appended per Step 1)
import Testing
import Foundation
@testable import AnglesiteApp
@testable import AnglesiteCore

@Suite("SiteNavigatorModel delete (#530)")
@MainActor
struct SiteNavigatorModelDeleteTests {
    private func makeModel(gitDelete: @escaping NativeContentOperations.GitDelete) async -> (SiteNavigatorModel, SiteContentGraph, String) {
        let graph = SiteContentGraph()
        let page = SiteContentGraph.Page(
            id: "site1:page:/old-page", siteID: "site1", route: "/old-page",
            filePath: "src/content/pages/old.astro", title: "Old Page", lastModified: Date())
        await graph.upsertPage(page)
        let model = SiteNavigatorModel(graph: graph, gitDelete: gitDelete)
        model.start(siteID: "site1", siteRoot: URL(fileURLWithPath: "/site"),
                     sourceDirectory: URL(fileURLWithPath: "/site"), websiteTitle: "Test")
        await model.refreshNow()
        return (model, graph, page.id)
    }

    @Test("canDelete is true for a page row, mirroring canRename")
    func canDeletePage() async {
        let (model, _, pageID) = await makeModel(gitDelete: { _, _, _ in "sha" })
        #expect(model.canDelete(pageID) == true)
    }

    @Test("confirmDelete on success commits via git, removes the page from the graph, returns its route")
    func confirmDeleteSuccess() async {
        let committed = Locked<(String, String)?>(nil)
        let (model, graph, pageID) = await makeModel(gitDelete: { _, rel, msg in
            committed.set((rel, msg)); return "deadbeef"
        })
        await model.requestDelete(pageID)
        #expect(model.pendingDelete?.route == "/old-page")
        let route = await model.confirmDelete()
        #expect(route == "/old-page")
        #expect(committed.get()?.0 == "src/content/pages/old.astro")
        #expect(await graph.page(id: pageID) == nil)
        #expect(model.pendingDelete == nil)
    }

    @Test("confirmDelete on git failure sets deleteError and does not touch the graph")
    func confirmDeleteGitFailure() async {
        let (model, graph, pageID) = await makeModel(gitDelete: { _, _, _ in nil })
        await model.requestDelete(pageID)
        let route = await model.confirmDelete()
        #expect(route == nil)
        #expect(model.deleteError != nil)
        #expect(await graph.page(id: pageID) != nil)
    }

    @Test("cancelDelete clears the pending candidate without deleting anything")
    func cancelDelete() async {
        let (model, graph, pageID) = await makeModel(gitDelete: { _, _, _ in
            Issue.record("gitDelete must not be called after cancel"); return "sha"
        })
        await model.requestDelete(pageID)
        model.cancelDelete()
        #expect(model.pendingDelete == nil)
        #expect(await graph.page(id: pageID) != nil)
    }
}

/// Minimal thread-safe box so the @Sendable injection closures can record calls.
private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock(); private var value: T
    init(_ v: T) { value = v }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter SiteNavigatorModelDeleteTests`
Expected: FAIL to compile — `SiteNavigatorModel` has no `gitDelete` init parameter, `DeleteCandidate`, `canDelete`, `requestDelete`, `pendingDelete`, `confirmDelete`, `cancelDelete`, or `deleteError` for delete (only `renameError` exists).

- [ ] **Step 3: Write the implementation**

In `Sources/AnglesiteApp/SiteNavigatorModel.swift`, add after the existing `var renameError: String?` (line 18):

```swift
    var renameError: String?

    // Minimal delete (#530): removes a page/post's file via git and, for pages (which carry a
    // route — posts don't), returns the route so the caller can offer to cover it with a
    // redirect. `NavigatorRenameService`'s title-rewrite never changes a route, so this is the
    // only in-app action that can actually break an inbound URL.
    struct DeleteCandidate: Equatable {
        enum Kind: Equatable { case page, post }
        let id: String
        let filePath: String
        let route: String?
        let displayTitle: String
        let kind: Kind
    }
    var pendingDelete: DeleteCandidate?
    var deleteError: String?
```

Add a `gitDelete` field alongside `renameService` (line 24) and thread it through `init`:

```swift
    private let renameService = NavigatorRenameService()
    private let gitDelete: NativeContentOperations.GitDelete
```

Change the `init` (lines 29-31) from:

```swift
    init(graph: SiteContentGraph) {
        self.graph = graph
    }
```

to:

```swift
    init(graph: SiteContentGraph, gitDelete: @escaping NativeContentOperations.GitDelete = NativeContentOperations.processGitDelete) {
        self.graph = graph
        self.gitDelete = gitDelete
    }
```

Add the delete methods after `canRename(_:)` (after line 100):

```swift
    /// Same eligibility as `canRename` — pages and posts (route targets) are deletable; file rows
    /// (components/styles/metadata) are not.
    func canDelete(_ id: String) -> Bool { canRename(id) }

    /// Resolves `id` to a page or post and stages it as `pendingDelete` for the confirmation
    /// dialog. No-ops if `id` isn't deletable.
    func requestDelete(_ id: String) async {
        guard canDelete(id) else { return }
        if let page = await graph.page(id: id) {
            pendingDelete = DeleteCandidate(
                id: id, filePath: page.filePath, route: page.route,
                displayTitle: page.title ?? page.route, kind: .page)
        } else if let post = await graph.post(id: id) {
            pendingDelete = DeleteCandidate(
                id: id, filePath: post.filePath, route: nil,
                displayTitle: post.title ?? post.slug, kind: .post)
        }
    }

    func cancelDelete() {
        pendingDelete = nil
    }

    /// Stage-delete + commit the pending candidate's file via git, then remove it from the
    /// content graph. Returns the removed page's route (for the caller to offer a redirect for),
    /// or `nil` on failure or when deleting a post (posts carry no route). Always clears
    /// `pendingDelete`.
    @discardableResult
    func confirmDelete() async -> String? {
        guard let candidate = pendingDelete, let sourceDirectory else { pendingDelete = nil; return nil }
        pendingDelete = nil
        let message = "anglesite: delete \(candidate.filePath)"
        guard await gitDelete(sourceDirectory, candidate.filePath, message) != nil else {
            deleteError = "Couldn't delete \(candidate.filePath). Check for uncommitted changes and try again."
            return nil
        }
        switch candidate.kind {
        case .page: await graph.removePage(id: candidate.id)
        case .post: await graph.removePost(id: candidate.id)
        }
        return candidate.route
    }

    /// Appends a redirect for `source` → `destination` to `Source/redirects.json`, used by the
    /// "Add Redirect" button in the delete-confirmation flow. Returns whether the save succeeded;
    /// on failure sets `deleteError` (reused as the general navigator-action error surface) so the
    /// existing "Delete failed" alert can show it.
    @discardableResult
    func saveRedirect(source: String, destination: String, code: RedirectsStore.RedirectEntry.Code) async -> Bool {
        guard let sourceDirectory else { return false }
        let store = RedirectsStore(sourceDirectory: sourceDirectory)
        do {
            var entries = try store.load()
            entries.append(RedirectsStore.RedirectEntry(source: source, destination: destination, code: code))
            try store.save(entries)
            return true
        } catch {
            deleteError = "Couldn't save the redirect: \(error.localizedDescription)"
            return false
        }
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter SiteNavigatorModelDeleteTests`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/SiteNavigatorModel.swift Tests/AnglesiteAppTests/SiteNavigatorModelTests.swift
git commit -m "feat(app): minimal navigator delete + redirect offer (#530)"
```

---

## Task 7: `SiteNavigatorView` — Delete menu item, confirmation dialog, Add-Redirect sheet

**Files:**
- Modify: `Sources/AnglesiteApp/SiteNavigatorView.swift`

**Interfaces:**
- Consumes: `SiteNavigatorModel.canDelete/requestDelete/pendingDelete/cancelDelete/confirmDelete/saveRedirect/deleteError` (Task 6).

- [ ] **Step 1: Add the "Delete" context-menu item**

In `Sources/AnglesiteApp/SiteNavigatorView.swift`, change the row's `contextMenu` (lines 127-131) from:

```swift
                .contextMenu {
                    if model.canRename(item.id) {
                        Button("Rename") { model.beginEditing(item.id) }
                    }
                }
```

to:

```swift
                .contextMenu {
                    if model.canRename(item.id) {
                        Button("Rename") { model.beginEditing(item.id) }
                    }
                    if model.canDelete(item.id) {
                        Button("Delete", role: .destructive) {
                            Task { await model.requestDelete(item.id) }
                        }
                    }
                }
```

- [ ] **Step 2: Add the three-button delete confirmation dialog and the Add-Redirect sheet**

Add local `@State` for the redirect sheet, alongside the existing `candidateToDeleteTitle` (line 16):

```swift
    @State private var candidateToDeleteTitle: String = ""
    @State private var redirectSheetSource: String?
    @State private var redirectDestination: String = ""
    @State private var redirectCode: RedirectsStore.RedirectEntry.Code = .permanent
```

Add a new `.confirmationDialog` and `.sheet` right after the existing Cleanup-candidate confirmation dialog block (after line 89, before the `.alert("Delete failed", ...)` at line 90):

```swift
        .confirmationDialog(
            "Delete “\(model.pendingDelete?.displayTitle ?? "")”?",
            isPresented: Binding(
                get: { model.pendingDelete != nil },
                set: { if !$0 { model.cancelDelete() } }),
            titleVisibility: .visible,
            presenting: model.pendingDelete
        ) { candidate in
            if let route = candidate.route {
                Button("Add Redirect") {
                    Task {
                        if let removedRoute = await model.confirmDelete() {
                            redirectSheetSource = removedRoute
                        }
                    }
                }
                Button("Delete Without Redirect", role: .destructive) {
                    Task { await model.confirmDelete() }
                }
            } else {
                Button("Delete", role: .destructive) {
                    Task { await model.confirmDelete() }
                }
            }
            Button("Cancel", role: .cancel) { model.cancelDelete() }
        } message: { candidate in
            Text(candidate.route.map { "Deleting this page removes \($0). Create a redirect so old links still work?" }
                ?? "This will be removed from the working tree. This can be undone via git.")
        }
        .sheet(item: Binding(
            get: { redirectSheetSource.map { IdentifiableString($0) } },
            set: { redirectSheetSource = $0?.value }
        )) { source in
            VStack(alignment: .leading, spacing: 12) {
                Text("Add Redirect").font(.headline)
                Text("From \(source.value)")
                    .foregroundStyle(.secondary)
                TextField("Destination path (e.g. /new-page)", text: $redirectDestination)
                    .textFieldStyle(.roundedBorder)
                Picker("Type", selection: $redirectCode) {
                    Text("Permanent (301)").tag(RedirectsStore.RedirectEntry.Code.permanent)
                    Text("Temporary (302)").tag(RedirectsStore.RedirectEntry.Code.temporary)
                }
                .pickerStyle(.segmented)
                HStack {
                    Spacer()
                    Button("Cancel") { redirectSheetSource = nil; redirectDestination = "" }
                    Button("Save") {
                        Task {
                            if await model.saveRedirect(source: source.value, destination: redirectDestination, code: redirectCode) {
                                redirectSheetSource = nil
                                redirectDestination = ""
                            }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(redirectDestination.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding()
            .frame(minWidth: 360)
        }
```

Add the small `Identifiable` wrapper (SwiftUI's `.sheet(item:)` needs an `Identifiable`, and a bare `String` isn't) as a private type at the bottom of the file, after `deleteConfirmationTitle(for:)`:

```swift
private struct IdentifiableString: Identifiable {
    let value: String
    var id: String { value }
    init(_ value: String) { self.value = value }
}
```

Also extend the existing "Delete failed" alert (lines 90-100) to cover `model.deleteError` too — change:

```swift
        .alert(
            "Delete failed",
            isPresented: Binding(
                get: { cleanup.deleteError != nil },
                set: { if !$0 { cleanup.deleteError = nil } }),
            presenting: cleanup.deleteError
        ) { _ in
            Button("OK", role: .cancel) { cleanup.deleteError = nil }
        } message: { msg in
            Text(msg)
        }
```

to add a second alert right after it (kept separate since the two error sources — `cleanup.deleteError` and `model.deleteError` — are independent state on different models):

```swift
        .alert(
            "Delete failed",
            isPresented: Binding(
                get: { cleanup.deleteError != nil },
                set: { if !$0 { cleanup.deleteError = nil } }),
            presenting: cleanup.deleteError
        ) { _ in
            Button("OK", role: .cancel) { cleanup.deleteError = nil }
        } message: { msg in
            Text(msg)
        }
        .alert(
            "Delete failed",
            isPresented: Binding(
                get: { model.deleteError != nil },
                set: { if !$0 { model.deleteError = nil } }),
            presenting: model.deleteError
        ) { _ in
            Button("OK", role: .cancel) { model.deleteError = nil }
        } message: { msg in
            Text(msg)
        }
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: builds cleanly (this task is view-only; there is no dedicated SwiftUI view test target in this repo — verify visually per the Verification section at the end of this plan).

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteApp/SiteNavigatorView.swift
git commit -m "feat(app): navigator Delete action with redirect-offer dialog + sheet (#530)"
```

---

## Task 8: `PlistEditorModel` — Redirects dirty-tracking slice

**Files:**
- Modify: `Sources/AnglesiteApp/PlistEditorModel.swift`
- Create: `Tests/AnglesiteAppTests/PlistEditorModelRedirectsTests.swift` (no `PlistEditorModelTests.swift` exists in this repo today — confirmed via `grep -rl "PlistEditorModel" Tests/`, which returns nothing).

**Interfaces:**
- Consumes: `RedirectsStore` (Task 1).
- Produces: `PlistEditorModel.redirectEntries: [RedirectsStore.RedirectEntry]`, `isRedirectsDirty: Bool`, `redirectsError: String?`, `isSavingRedirects: Bool`, `saveRedirects() async -> Bool`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/AnglesiteAppTests/PlistEditorModelRedirectsTests.swift
import Testing
import Foundation
@testable import AnglesiteApp
@testable import AnglesiteCore

@Suite("PlistEditorModel redirects (#530)")
@MainActor
struct PlistEditorModelRedirectsTests {
    private static let emptyPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict/></plist>
        """

    /// Builds a `PlistEditorModel` against a fresh temp `sourceDirectory` with a minimal
    /// `Info.plist` at `file.url` — `PlistEditorModel.load()` reads both the plist and (via this
    /// task) `redirects.json` from that same directory.
    private func makeModel() throws -> PlistEditorModel {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlistEditorModelRedirectsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let plistURL = dir.appendingPathComponent("Info.plist")
        try Self.emptyPlist.write(to: plistURL, atomically: true, encoding: .utf8)
        let file = FileRef(url: plistURL, group: .metadata, name: "Info.plist")
        return PlistEditorModel(file: file, websiteTitle: "Test Site", sourceDirectory: dir)
    }

    @Test("load() populates redirectEntries from redirects.json, empty when absent")
    func loadPopulatesEmpty() async throws {
        let model = try makeModel()
        await model.load()
        #expect(model.redirectEntries.isEmpty)
        #expect(model.isRedirectsDirty == false)
    }

    @Test("isRedirectsDirty flips true after appending an entry, false after saveRedirects")
    func dirtyTrackingAndSave() async throws {
        let model = try makeModel()
        await model.load()
        model.redirectEntries.append(RedirectsStore.RedirectEntry(source: "/old", destination: "/new", code: .permanent))
        #expect(model.isRedirectsDirty == true)
        let saved = await model.saveRedirects()
        #expect(saved == true)
        #expect(model.isRedirectsDirty == false)
        #expect(try RedirectsStore(sourceDirectory: model.sourceDirectory).load() == model.redirectEntries)
    }

    @Test("saveRedirects surfaces a validation failure via redirectsError and leaves isRedirectsDirty true")
    func saveValidationFailureSurfacesError() async throws {
        let model = try makeModel()
        await model.load()
        model.redirectEntries.append(RedirectsStore.RedirectEntry(source: "/a", destination: "/a", code: .permanent))
        let saved = await model.saveRedirects()
        #expect(saved == false)
        #expect(model.redirectsError != nil)
        #expect(model.isRedirectsDirty == true)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter PlistEditorModelRedirectsTests`
Expected: FAIL to compile — `redirectEntries`, `isRedirectsDirty`, `redirectsError`, `saveRedirects` don't exist yet.

- [ ] **Step 3: Write the implementation**

In `Sources/AnglesiteApp/PlistEditorModel.swift`, add stored properties after `savedAnalyticsSettings` (line 33):

```swift
    private(set) var savedAnalyticsSettings = WebsiteAnalyticsAsset.Settings()
    var redirectEntries: [RedirectsStore.RedirectEntry] = []
    private(set) var savedRedirectEntries: [RedirectsStore.RedirectEntry] = []
    private(set) var redirectsError: String?
    private(set) var isSavingRedirects = false
```

Add the computed dirty flag alongside `isAnalyticsDirty` (line 37):

```swift
    var isAnalyticsDirty: Bool { analyticsSettings != savedAnalyticsSettings && loadError == nil && !isLoading }
    var isRedirectsDirty: Bool { redirectEntries != savedRedirectEntries && loadError == nil && !isLoading }
```

In `load()` (after line 97, `analyticsError = nil`), add:

```swift
            analyticsError = nil
            let redirects = (try? RedirectsStore(sourceDirectory: sourceDirectory).load()) ?? []
            redirectEntries = redirects
            savedRedirectEntries = redirects
            redirectsError = nil
```

In `flushBeforeLeaving()` (lines 129-146), after the existing `isAnalyticsDirty` branch, add a third branch — change:

```swift
        if isAnalyticsDirty {
            return await saveAnalytics()
        }
        return true
    }
```

to:

```swift
        if isAnalyticsDirty {
            guard await saveAnalytics() else { return false }
        }
        if isRedirectsDirty {
            return await saveRedirects()
        }
        return true
    }
```

Add `saveRedirects()` after `saveAnalytics()` (after line 221):

```swift
    @discardableResult
    func saveRedirects() async -> Bool {
        guard isRedirectsDirty else { return true }
        guard !isSavingRedirects else { return false }
        isSavingRedirects = true
        redirectsError = nil
        defer { isSavingRedirects = false }
        let sourceDirectory = sourceDirectory
        let entries = redirectEntries
        do {
            try await Task.detached(priority: .userInitiated) {
                try RedirectsStore(sourceDirectory: sourceDirectory).save(entries)
            }.value
            savedRedirectEntries = entries
            return true
        } catch {
            redirectsError = "Couldn't save redirects: \(error.localizedDescription)"
            return false
        }
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter PlistEditorModelRedirectsTests`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/PlistEditorModel.swift Tests/AnglesiteAppTests/PlistEditorModelRedirectsTests.swift
git commit -m "feat(app): PlistEditorModel redirects dirty-tracking slice (#530)"
```

---

## Task 9: `PlistEditorView` — "Redirects" tab

**Files:**
- Modify: `Sources/AnglesiteApp/PlistEditorView.swift`

**Interfaces:**
- Consumes: `PlistEditorModel.redirectEntries/isRedirectsDirty/redirectsError/isSavingRedirects/saveRedirects()` (Task 8).

- [ ] **Step 1: Add the tab case**

Change the `SettingsTab` enum (lines 9-13) from:

```swift
    private enum SettingsTab: String, CaseIterable, Identifiable {
        case website = "Website"
        case analytics = "Analytics"
        var id: Self { self }
    }
```

to:

```swift
    private enum SettingsTab: String, CaseIterable, Identifiable {
        case website = "Website"
        case analytics = "Analytics"
        case redirects = "Redirects"
        var id: Self { self }
    }
```

- [ ] **Step 2: Save on tab-leave and route the error banner**

Change the `onChange(of: selectedTab)` autosave (lines 32-36) from:

```swift
        .onChange(of: selectedTab) { oldValue, _ in
            if oldValue == .analytics {
                Task { await model.saveAnalytics() }
            }
        }
```

to:

```swift
        .onChange(of: selectedTab) { oldValue, _ in
            if oldValue == .analytics {
                Task { await model.saveAnalytics() }
            } else if oldValue == .redirects {
                Task { await model.saveRedirects() }
            }
        }
```

Change the header's dirty-dot condition (line 52) from:

```swift
            if model.isDirty || model.isAnalyticsDirty {
```

to:

```swift
            if model.isDirty || model.isAnalyticsDirty || model.isRedirectsDirty {
```

Change the cross-tab error banner (lines 96-100) from:

```swift
                    if selectedTab != .analytics, let analyticsError = model.analyticsError {
                        Label(analyticsError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
```

to:

```swift
                    if selectedTab != .analytics, let analyticsError = model.analyticsError {
                        Label(analyticsError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                    if selectedTab != .redirects, let redirectsError = model.redirectsError {
                        Label(redirectsError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
```

Add the render-dispatch case (lines 102-107) — change:

```swift
                    switch selectedTab {
                    case .website:
                        websiteTab
                    case .analytics:
                        analyticsTab
                    }
```

to:

```swift
                    switch selectedTab {
                    case .website:
                        websiteTab
                    case .analytics:
                        analyticsTab
                    case .redirects:
                        redirectsTab
                    }
```

- [ ] **Step 3: Add the `redirectsTab` view**

Add after `analyticsTab` (after line 229, before `private var conflictBinding`):

```swift
    private var redirectsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.redirectEntries.isEmpty {
                Text("No redirects yet. Add one below.")
                    .foregroundStyle(.secondary)
            } else {
                Table(model.redirectEntries) {
                    TableColumn("Source") { entry in
                        TextField("/old-path", text: sourceBinding(for: entry))
                    }
                    TableColumn("Destination") { entry in
                        TextField("/new-path", text: destinationBinding(for: entry))
                    }
                    TableColumn("Type") { entry in
                        Picker("Type", selection: codeBinding(for: entry)) {
                            Text("301").tag(RedirectsStore.RedirectEntry.Code.permanent)
                            Text("302").tag(RedirectsStore.RedirectEntry.Code.temporary)
                        }
                        .labelsHidden()
                    }
                    TableColumn("") { entry in
                        Button(role: .destructive) {
                            model.redirectEntries.removeAll { $0.id == entry.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(minHeight: 120)
            }
            HStack(spacing: 8) {
                Button {
                    model.redirectEntries.append(RedirectsStore.RedirectEntry(source: "", destination: "", code: .permanent))
                } label: {
                    Label("Add Redirect", systemImage: "plus")
                }
                if model.isSavingRedirects {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    private func sourceBinding(for entry: RedirectsStore.RedirectEntry) -> Binding<String> {
        Binding(
            get: { model.redirectEntries.first { $0.id == entry.id }?.source ?? entry.source },
            set: { newValue in
                if let idx = model.redirectEntries.firstIndex(where: { $0.id == entry.id }) {
                    model.redirectEntries[idx].source = newValue
                }
            })
    }

    private func destinationBinding(for entry: RedirectsStore.RedirectEntry) -> Binding<String> {
        Binding(
            get: { model.redirectEntries.first { $0.id == entry.id }?.destination ?? entry.destination },
            set: { newValue in
                if let idx = model.redirectEntries.firstIndex(where: { $0.id == entry.id }) {
                    model.redirectEntries[idx].destination = newValue
                }
            })
    }

    private func codeBinding(for entry: RedirectsStore.RedirectEntry) -> Binding<RedirectsStore.RedirectEntry.Code> {
        Binding(
            get: { model.redirectEntries.first { $0.id == entry.id }?.code ?? entry.code },
            set: { newValue in
                if let idx = model.redirectEntries.firstIndex(where: { $0.id == entry.id }) {
                    model.redirectEntries[idx].code = newValue
                }
            })
    }
```

> Note: `RedirectEntry.id` is its `source`, which is also the field being edited in-place — editing `source` in the table changes what `entry.id` matches on the *next* re-render, which is fine for `Table`'s row identity (SwiftUI re-diffs by the current array's `id`s each render) but means two rows can transiently collide if a user edits one `source` to equal another's. This is caught by `RedirectsStore.validate`'s `duplicateSource` check at save time (surfaced via `redirectsError`), so it's a save-time rejection, not a crash — acceptable for a v0 editor.

- [ ] **Step 4: Build**

Run: `swift build`
Expected: builds cleanly.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/PlistEditorView.swift
git commit -m "feat(app): Redirects tab in Site Settings (#530)"
```

---

## Task 10: Astro integration — `scripts/redirects.ts` + scaffolded `redirects.json`

**Files:**
- Create: `Resources/Template/scripts/redirects.ts`
- Create: `Resources/Template/scripts/redirects.test.ts`
- Create: `Resources/Template/redirects.json` (committed, `[]`)

**Interfaces:**
- Produces (TypeScript): `readRedirects(templateRoot: string): RedirectEntry[]`, `buildCloudflareRedirectsFile(entries: RedirectEntry[]): string`, `redirects(): AstroIntegration` (default export).

- [ ] **Step 1: Write the failing test**

```ts
// Resources/Template/scripts/redirects.test.ts
import test from "node:test";
import assert from "node:assert/strict";
import { buildCloudflareRedirectsFile, toAstroRedirectsConfig } from "./redirects";
import type { RedirectEntry } from "./redirects";

test("buildCloudflareRedirectsFile: formats one line per entry as 'source destination code'", () => {
  const entries: RedirectEntry[] = [
    { source: "/old", destination: "/new", code: 301 },
    { source: "/temp", destination: "/dest", code: 302 },
  ];
  const out = buildCloudflareRedirectsFile(entries);
  assert.equal(out, "/old /new 301\n/temp /dest 302\n");
});

test("buildCloudflareRedirectsFile: empty entries produce an empty string", () => {
  assert.equal(buildCloudflareRedirectsFile([]), "");
});

test("toAstroRedirectsConfig: maps entries to Astro's { source: { destination, status } } shape", () => {
  const entries: RedirectEntry[] = [{ source: "/old", destination: "/new", code: 301 }];
  assert.deepEqual(toAstroRedirectsConfig(entries), {
    "/old": { status: 301, destination: "/new" },
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Resources/Template && npx tsx --test scripts/redirects.test.ts`
Expected: FAIL — `./redirects` module does not exist.

- [ ] **Step 3: Write the implementation**

```ts
// Resources/Template/scripts/redirects.ts
import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import type { AstroIntegration } from "astro";

export interface RedirectEntry {
  source: string;
  destination: string;
  code: 301 | 302;
}

/// Reads `redirects.json` from the site root. Returns `[]` if the file is missing or malformed —
/// a site with no redirects yet, or one mid-edit, should never fail the build.
export function readRedirects(siteRoot: string): RedirectEntry[] {
  try {
    const raw = readFileSync(resolve(siteRoot, "redirects.json"), "utf-8");
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    return parsed;
  } catch {
    return [];
  }
}

/// Cloudflare Pages' `_redirects` plain-text format: one `source destination code` line per
/// entry, trailing newline. See https://developers.cloudflare.com/pages/configuration/redirects/
export function buildCloudflareRedirectsFile(entries: RedirectEntry[]): string {
  if (entries.length === 0) return "";
  return entries.map((e) => `${e.source} ${e.destination} ${e.code}`).join("\n") + "\n";
}

/// Astro's `redirects` config shape: a map of source path to `{ status, destination }`.
export function toAstroRedirectsConfig(entries: RedirectEntry[]): Record<string, { status: 301 | 302; destination: string }> {
  const config: Record<string, { status: 301 | 302; destination: string }> = {};
  for (const e of entries) {
    config[e.source] = { status: e.code, destination: e.destination };
  }
  return config;
}

/// Wires `redirects.json` into both the dev-server preview (Astro's own `redirects` config, via
/// `astro:config:setup`) and the production Cloudflare Pages output (a generated `dist/_redirects`
/// file, via `astro:build:done` — Astro's static output has no adapter here, so its own
/// `redirects` config only emits HTML meta-refresh pages, not real HTTP redirects; `_redirects`
/// is what Cloudflare Pages actually serves).
export default function redirects(): AstroIntegration {
  return {
    name: "anglesite-redirects",
    hooks: {
      "astro:config:setup": ({ config, updateConfig }) => {
        const entries = readRedirects(fileURLToPathSafe(config.root));
        if (Object.keys(entries).length === 0) return;
        updateConfig({ redirects: toAstroRedirectsConfig(entries) });
      },
      "astro:build:done": ({ dir }) => {
        const siteRoot = fileURLToPathSafe(dir).replace(/dist\/?$/, "");
        const entries = readRedirects(siteRoot);
        if (entries.length === 0) return;
        writeFileSync(resolve(fileURLToPathSafe(dir), "_redirects"), buildCloudflareRedirectsFile(entries));
      },
    },
  };
}

function fileURLToPathSafe(url: URL): string {
  return url.pathname;
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd Resources/Template && npx tsx --test scripts/redirects.test.ts`
Expected: PASS (3 tests)

- [ ] **Step 5: Create the scaffolded `redirects.json`**

```json
[]
```

Write this exact content (empty JSON array, no trailing newline needed but harmless if present) to `Resources/Template/redirects.json`. `scaffold.sh`'s `rsync` copies it into every new site's `Source/redirects.json` unchanged — no `scaffold.sh` edit needed (it isn't in the `--exclude` list).

- [ ] **Step 6: Commit**

```bash
git add Resources/Template/scripts/redirects.ts Resources/Template/scripts/redirects.test.ts Resources/Template/redirects.json
git commit -m "feat(template): Astro integration wiring redirects.json to dev + _redirects (#530)"
```

---

## Task 11: Register the integration in `astro.config.ts`

**Files:**
- Modify: `Resources/Template/astro.config.ts`
- Modify: `Tests/AnglesiteCoreTests/IntegrationTemplateAssetsTests.swift` (add a coverage test)

**Interfaces:**
- Consumes: `redirects()` default export from `./scripts/redirects.ts` (Task 10).

- [ ] **Step 1: Write the failing Swift test**

Add to `Tests/AnglesiteCoreTests/IntegrationTemplateAssetsTests.swift` (using its existing `templateRoot()` helper, see the file's lines 13-29):

```swift
    @Test func astroConfigRegistersRedirectsIntegration() throws {
        let configURL = templateRoot().appendingPathComponent("astro.config.ts")
        let source = try String(contentsOf: configURL, encoding: .utf8)
        #expect(source.contains("import redirects from \"./scripts/redirects.ts\""))
        #expect(source.contains("redirects()"))
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter astroConfigRegistersRedirectsIntegration`
Expected: FAIL — `astro.config.ts` doesn't reference `redirects.ts` yet.

- [ ] **Step 3: Update `astro.config.ts`**

Change `Resources/Template/astro.config.ts` from:

```ts
import { defineConfig } from "astro/config";
import { readConfig } from "./scripts/config.ts";
import anglesiteHarness from "./scripts/anglesite-harness.ts";

// The deploy step writes the real domain into `.site-config` (SITE_URL=…) before build.
// Absent that, feeds carry a placeholder host — fine for a not-yet-deployed scaffold.
const site = readConfig("SITE_URL") ?? "https://example.com";

export default defineConfig({ site, integrations: [anglesiteHarness()] });
```

to:

```ts
import { defineConfig } from "astro/config";
import { readConfig } from "./scripts/config.ts";
import anglesiteHarness from "./scripts/anglesite-harness.ts";
import redirects from "./scripts/redirects.ts";

// The deploy step writes the real domain into `.site-config` (SITE_URL=…) before build.
// Absent that, feeds carry a placeholder host — fine for a not-yet-deployed scaffold.
const site = readConfig("SITE_URL") ?? "https://example.com";

export default defineConfig({ site, integrations: [anglesiteHarness(), redirects()] });
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter astroConfigRegistersRedirectsIntegration`
Expected: PASS

- [ ] **Step 5: Run the full `IntegrationTemplateAssetsTests` suite (regression check)**

Run: `swift test --filter IntegrationTemplateAssetsTests`
Expected: PASS — in particular `scaffoldDoesNotExcludeConfigTs` (unaffected: no new `--exclude` was added) and `scaffoldExcludesIntegrationsDir` (unaffected).

- [ ] **Step 6: Commit**

```bash
git add Resources/Template/astro.config.ts Tests/AnglesiteCoreTests/IntegrationTemplateAssetsTests.swift
git commit -m "feat(template): register the redirects Astro integration (#530)"
```

---

## Verification (after all tasks)

- [ ] **Full Swift suite**: `swift build && swift test --parallel` — everything from Tasks 1-9 plus every pre-existing test (in particular `DeployCommandTests`, `DeployExecutorSelectionTests`, `IntegrationTemplateAssetsTests`) passes unchanged.
- [ ] **Template TS tests**: `cd Resources/Template && npx tsx --test scripts/redirects.test.ts` passes (matches this repo's existing, CI-unwired convention for `*.test.ts` files — see `scripts/edge-artifacts.test.ts`).
- [ ] **Manual smoke** (per this repo's UI-change convention — type checking doesn't verify feature behavior):
  1. `xcodegen generate`, build and run `Anglesite`, open (or scaffold) a test site.
  2. In the navigator, right-click a page → **Delete** → confirm the three-button dialog appears with the route named in its message.
  3. Choose **Add Redirect**: the page is deleted (check `git log` in `Source/` shows a `anglesite: delete …` commit) and the Add-Redirect sheet appears pre-filled with the deleted route as the source; fill in a destination, Save, and confirm `Source/redirects.json` now contains the entry.
  4. Open **Site Settings → Redirects**: confirm the same entry is listed and editable; add a second entry, switch tabs, and confirm it autosaves (`redirects.json` updates).
  5. Run `npm run dev` (or use the in-app preview) and hit the old route in a browser — confirm it redirects.
  6. Run a deploy once with routes A+B present, then delete route B *without* adding a redirect and deploy again — confirm the deploy proceeds (warning, not blocker) and the health badge shows the new `.orphanedRoute` warning.
