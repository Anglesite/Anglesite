# `.anglesite` Package Model — Phase 2 (Open / Create + Runtime) Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `.anglesite` packages the unit the app opens, creates, and runs: convert `SiteStore` from a `~/Sites` scanner into a recents registry keyed by the package's stable marker UUID, route Finder/`Open With` opens of a package to a site window, scaffold new sites into the package's `Source/`, retarget every subprocess working directory to `Source/`, and (MAS) hold the security-scoped grant on the package.

**Architecture:** P1 gave us `AnglesitePackage` (layout + marker + UUID identity). P2 reinterprets a "site" as a package: `SiteStore.Site.packageURL` is the `.anglesite` dir, `Site.id` is the marker UUID, and `Site.sourceDirectory` (computed via `AnglesitePackage`) is what subprocesses use as cwd. Discovery becomes an explicit recents registry (create / open / `onOpenURL`), not a directory scan. New testable logic lives in `AnglesiteCore`; the SwiftUI scene + window rewiring is thin glue verified by build.

**Tech Stack:** Swift 5.10 / SwiftPM, Swift Testing, SwiftUI (`WindowGroup(for:)`, `onOpenURL`), `AnglesiteCore` actors.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-06-19-anglesite-package-model-design.md` (this is P2: §3 recents registry, §5 new-site scaffold-into-Source, §6 runtime cwd, §7 MAS bookmark, plus §1 UUID identity wiring).
- **Depends on P1** (merged or on the same branch `feat/242-anglesite-package-model`): `AnglesitePackage` with `sourceURL`/`configURL`/`createSkeleton`/`readMarker`/`isPackage`/`Marker.siteID`.
- **Toolchain:** prefix `swift test` / `xcodegen` / `xcodebuild` with `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`.
- **CI reality (from CLAUDE.md):** hosted app-target tests do NOT run on CI. Therefore: put all decision logic in `AnglesiteCore` with Swift Testing coverage; keep `Sources/AnglesiteApp` changes to thin glue. App-target tasks are verified by `xcodebuild ... -scheme Anglesite build` succeeding, not by unit tests.
- **Testing framework:** new tests use Swift Testing (`@Test`, `#expect`/`#require`), inject temp dirs/`FileManager`, never touch real user dirs.
- **Identity:** a site's id is the package `Marker.siteID.uuidString`. It MUST be stable across a package move (no path-derived ids).
- **Runtime cwd:** scaffold, dev server, build, deploy, and pre-deploy check all run with cwd = `<package>/Source/`.
- **MAS:** one security-scoped bookmark per **package URL**; `Source/` and `Config/` are inside it, so one grant covers both. Gate MAS-only code with `#if ANGLESITE_MAS`.
- **Commit style:** Conventional Commits, scope `(#242)`, body ends with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

## File Structure

- `Sources/AnglesiteCore/SiteStore.swift` — **rework**: `Site` gains `packageURL` + UUID `id` + computed `sourceDirectory`; `refresh()` scan replaced by a recents registry (`record`, `touch`, `load`, `remove`, `find`, bookmark accessors, change streams retained). Persisted file renamed concept (`recents.json`), back-comp read of legacy `sites.json` is out of scope (P3 Import is the migration path).
- `Sources/AnglesiteCore/SiteScaffolder.swift` — **modify**: create a package skeleton and scaffold into `Source/`; register the package.
- `Sources/AnglesiteApp/AnglesiteApp.swift` — **modify**: add `onOpenURL` package routing; "Open Site…" opens a package; recents menu unchanged in shape.
- `Sources/AnglesiteApp/SiteActions.swift` — **modify**: `pickAndRegisterSite()` chooses an `.anglesite` package; bookmark on the package URL.
- `Sources/AnglesiteApp/SiteWindow.swift` — **modify**: resolve site → use `site.sourceDirectory` for preview/deploy/graph; grant on `site.packageURL`.
- `Tests/AnglesiteCoreTests/SiteStoreRecentsTests.swift` — **create**.
- `Tests/AnglesiteCoreTests/AnglesitePackageMoveTests.swift` — **create** (identity-survives-move, per the P1 final-review note).

---

### Task 1: Identity survives a package move (regression lock)

Per the P1 final review, prove the headline guarantee of the UUID redesign before building on it.

**Files:**
- Test: `Tests/AnglesiteCoreTests/AnglesitePackageMoveTests.swift` (create)

**Interfaces:**
- Consumes: `AnglesitePackage.createSkeleton`, `readMarker`, `Marker.siteID` (P1).

- [ ] **Step 1: Write the test**

```swift
import Testing
import Foundation
@testable import AnglesiteCore

/// Locks the core promise of the UUID-identity redesign (#242): a package's `siteID` is stored
/// in its `Info.plist`, not derived from its path, so moving/renaming the package keeps identity.
struct AnglesitePackageMoveTests {
    private func tempDir() throws -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pkg-move-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test("siteID is unchanged after the package directory is moved/renamed")
    func identitySurvivesMove() throws {
        let fm = FileManager.default
        let root = try tempDir()
        defer { try? fm.removeItem(at: root) }

        let original = root.appendingPathComponent("Acme.anglesite", isDirectory: true)
        let (_, marker) = try AnglesitePackage.createSkeleton(at: original, displayName: "Acme")

        let moved = root.appendingPathComponent("Renamed.anglesite", isDirectory: true)
        try fm.moveItem(at: original, to: moved)

        let readAfterMove = try AnglesitePackage(url: moved).readMarker()
        #expect(readAfterMove.siteID == marker.siteID)
    }
}
```

- [ ] **Step 2: Run — expect PASS** (the format already supports this; this is a regression lock, not new behavior)

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter AnglesitePackageMoveTests`
Expected: PASS (1 test). If it FAILS, stop — P1's identity model is broken and P2 must not proceed.

- [ ] **Step 3: Commit**

```bash
git add Tests/AnglesiteCoreTests/AnglesitePackageMoveTests.swift
git commit -m "$(cat <<'EOF'
test(#242): lock package siteID stability across directory move

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `SiteStore.Site` becomes package-shaped

Reshape the `Site` value type so identity is the marker UUID and the package URL + source dir are first-class. Keep the type `Codable` for the recents file.

**Files:**
- Modify: `Sources/AnglesiteCore/SiteStore.swift:17-48` (the `Site` struct)
- Test: `Tests/AnglesiteCoreTests/SiteStoreRecentsTests.swift` (create)

**Interfaces:**
- Produces:
  - `SiteStore.Site` with: `id: String` (UUID string), `name: String`, `packageURL: URL`, `isValid: Bool`, `missingSentinels: [String]`, `lastSeen: Date`, `bookmarkData: Data?`
  - computed `var sourceDirectory: URL { AnglesitePackage(url: packageURL).sourceURL }`
  - computed `var configDirectory: URL { AnglesitePackage(url: packageURL).configURL }`
  - `static func make(package: AnglesitePackage, fileManager: FileManager) throws -> Site` — reads the marker, validates `Source/`, builds a `Site` (id = marker UUID, name = marker.displayName).

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import AnglesiteCore

struct SiteStoreRecentsTests {
    private func tempDir() throws -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("recents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Build a valid package (Source/ has the required sentinels).
    private func makeValidPackage(in root: URL, name: String) throws -> AnglesitePackage {
        let (pkg, _) = try AnglesitePackage.createSkeleton(
            at: root.appendingPathComponent("\(name).anglesite", isDirectory: true), displayName: name)
        for sentinel in ProjectValidator.requiredSentinels {
            try Data("{}".utf8).write(to: pkg.sourceURL.appendingPathComponent(sentinel))
        }
        return pkg
    }

    @Test("Site.make derives id from the marker UUID and source/config dirs from the package")
    func siteMakeDerivesFields() throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let pkg = try makeValidPackage(in: root, name: "Acme")
        let marker = try pkg.readMarker()

        let site = try SiteStore.Site.make(package: pkg, fileManager: .default)
        #expect(site.id == marker.siteID.uuidString)
        #expect(site.name == "Acme")
        #expect(site.packageURL == pkg.url)
        #expect(site.sourceDirectory == pkg.sourceURL)
        #expect(site.configDirectory == pkg.configURL)
        #expect(site.isValid)
        #expect(site.missingSentinels.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SiteStoreRecentsTests`
Expected: FAIL — `Site` has no `packageURL`/`make`.

- [ ] **Step 3: Implement — replace the `Site` struct in `SiteStore.swift`**

Replace lines 17–48 (the current `Site` struct) with:

```swift
    public struct Site: Sendable, Codable, Equatable, Identifiable {
        /// The package's stable marker UUID (string). Path-independent — survives moves (#242).
        public let id: String
        /// Display name (from the package marker).
        public let name: String
        /// The `.anglesite` package directory.
        public let packageURL: URL
        public var isValid: Bool
        public var missingSentinels: [String]
        public var lastSeen: Date
        /// Security-scoped bookmark for `packageURL` (MAS). `nil` on DevID. One grant covers
        /// the whole package, so Source/ and Config/ are both reachable under it.
        public var bookmarkData: Data?

        /// The Astro project tree — every subprocess (scaffold, dev server, build, deploy,
        /// pre-deploy check) runs with this as its working directory.
        public var sourceDirectory: URL { AnglesitePackage(url: packageURL).sourceURL }
        /// App-owned per-site config dir (settings, chat history, cache).
        public var configDirectory: URL { AnglesitePackage(url: packageURL).configURL }

        public init(
            id: String,
            name: String,
            packageURL: URL,
            isValid: Bool,
            missingSentinels: [String],
            lastSeen: Date = Date(),
            bookmarkData: Data? = nil
        ) {
            self.id = id
            self.name = name
            self.packageURL = packageURL
            self.isValid = isValid
            self.missingSentinels = missingSentinels
            self.lastSeen = lastSeen
            self.bookmarkData = bookmarkData
        }

        /// Build a `Site` from a package on disk: id = marker UUID, name = marker displayName,
        /// validity = whether `Source/` passes the project sentinels.
        public static func make(package: AnglesitePackage, fileManager: FileManager = .default) throws -> Site {
            let marker = try package.readMarker(fileManager: fileManager)
            let validation = package.sourceValidation(fileManager: fileManager)
            return Site(
                id: marker.siteID.uuidString,
                name: marker.displayName,
                packageURL: AnglesiteCore.canonicalizePackageURL(package.url),
                isValid: validation.isValid,
                missingSentinels: validation.missing
            )
        }
    }
```

Add a small free helper near the bottom of the file (the old `canonicalize` was a private static on the actor; expose a package-URL canonicalizer the `Site.make` static can call):

```swift
/// Canonical (standardized, symlink-resolved) form of a package URL, so the same package
/// reached via a symlinked path collapses to one recents entry.
func canonicalizePackageURL(_ url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath()
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SiteStoreRecentsTests`
Expected: PASS. (The actor body still references removed/renamed members — it will not COMPILE yet; that is fixed in Task 3. If `swift test` fails to build `SiteStore.swift`, that's expected here only if Task 3 hasn't run. To keep this task independently green, also apply Task 3 before running the full build. See note.)

> **Sequencing note:** Tasks 2 and 3 together form one compilable unit (the `Site` reshape forces the actor-body changes). Implement Task 2's struct + Task 3's actor body, then run both test files. Commit them separately for review legibility, but run the build once after Task 3.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SiteStore.swift Tests/AnglesiteCoreTests/SiteStoreRecentsTests.swift
git commit -m "$(cat <<'EOF'
feat(#242): reshape SiteStore.Site around the package (UUID id + source/config dirs)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `SiteStore` becomes a recents registry

Replace the `~/Sites` scan (`refresh()`) with an explicit recents registry: `record(package:)` adds/updates an entry; `touch(id:)` bumps `lastSeen`. Persist to `recents.json`. Keep `load`, `remove`, `find`, bookmark accessors, and change streams.

**Files:**
- Modify: `Sources/AnglesiteCore/SiteStore.swift` (actor body: replace `refresh()`/`add(_ url:)`; update persistence URL + docs)
- Test: `Tests/AnglesiteCoreTests/SiteStoreRecentsTests.swift` (append)

**Interfaces:**
- Produces:
  - `@discardableResult func record(_ package: AnglesitePackage) async throws -> Site` — reads marker, builds `Site.make`, upserts by id (carrying forward any existing bookmark), persists, emits change.
  - `func touch(id: String) async throws` — bump `lastSeen`, re-sort, persist, emit.
  - retained: `load()`, `remove(id:)`, `find(id:)`, `bookmarkData(for:)`, `setBookmark(_:for:)`, `changeStream()`, `setChangeHandler(_:)`.
  - removed: `refresh()`, `add(_ url: URL)` (replaced by `record`). The default persistence file is now `recents.json`.

- [ ] **Step 1: Write the failing tests** (append to `SiteStoreRecentsTests.swift`, inside the struct)

```swift
    @Test("record upserts a package by id and persists; load restores it")
    func recordAndLoadRoundTrip() async throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let pkg = try makeValidPackage(in: root, name: "Acme")
        let persistence = root.appendingPathComponent("recents.json")

        let store = SiteStore(persistenceURL: persistence)
        let recorded = try await store.record(pkg)
        #expect(recorded.name == "Acme")
        #expect(await store.find(id: recorded.id) != nil)

        // A second store reading the same file sees the entry.
        let store2 = SiteStore(persistenceURL: persistence)
        try await store2.load()
        #expect(await store2.find(id: recorded.id)?.packageURL == pkg.url)
    }

    @Test("record is idempotent by id and carries a previously-set bookmark forward")
    func recordIdempotentCarriesBookmark() async throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let pkg = try makeValidPackage(in: root, name: "Acme")
        let store = SiteStore(persistenceURL: root.appendingPathComponent("recents.json"))
        let site = try await store.record(pkg)
        try await store.setBookmark(Data("bm".utf8), for: site.id)

        let again = try await store.record(pkg)   // same package, second open
        #expect(again.id == site.id)
        #expect(await store.bookmarkData(for: site.id) == Data("bm".utf8))
        #expect(await store.sites.filter { $0.id == site.id }.count == 1)
    }

    @Test("touch bumps lastSeen so the entry sorts first")
    func touchBumpsRecency() async throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let a = try makeValidPackage(in: root, name: "Alpha")
        let b = try makeValidPackage(in: root, name: "Beta")
        let store = SiteStore(persistenceURL: root.appendingPathComponent("recents.json"))
        let siteA = try await store.record(a)
        _ = try await store.record(b)
        try await store.touch(id: siteA.id)
        let mostRecent = RecentSites.select(from: await store.sites, limit: 1).first
        #expect(mostRecent?.id == siteA.id)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SiteStoreRecentsTests`
Expected: FAIL — no `record`/`touch`; build errors from the Task 2 reshape.

- [ ] **Step 3: Implement the actor body changes in `SiteStore.swift`**

3a. Update the type doc comment (lines 3–11) to describe a recents registry rather than a `~/Sites` scanner.

3b. Remove the `settings` dependency usage for scanning. Replace the entire `refresh()` method (lines 110–167) and `add(_ url:)` method (lines 169–198) with:

```swift
    /// Add or update a recents entry for `package`. Reads its marker for identity + name and
    /// validates `Source/`. Upsert is by `id` (the marker UUID): re-opening a moved package
    /// updates its `packageURL` in place and carries any existing bookmark forward. Persists
    /// and emits a change.
    @discardableResult
    public func record(_ package: AnglesitePackage) async throws -> Site {
        var site = try Site.make(package: package, fileManager: fileManager)
        if let existing = sites.first(where: { $0.id == site.id }) {
            site.bookmarkData = existing.bookmarkData ?? site.bookmarkData
        }
        site.lastSeen = Date()
        sites.removeAll { $0.id == site.id }
        sites.append(site)
        sites.sort { $0.lastSeen > $1.lastSeen }
        try persist()
        await emitChange()
        return site
    }

    /// Bump `lastSeen` for the entry with `id` (most-recently-used ordering). No-op if unknown.
    public func touch(id: String) async throws {
        guard let index = sites.firstIndex(where: { $0.id == id }) else { return }
        sites[index].lastSeen = Date()
        sites.sort { $0.lastSeen > $1.lastSeen }
        try persist()
        await emitChange()
    }
```

3c. In `load()` (lines 98–106) the decode is unchanged (still `[Site]`), but it now decodes the new `Site` shape from `recents.json`. Leave the logic; only the persisted shape changed.

3d. Update `defaultPersistenceURL` (lines 307–318) to use `recents.json` instead of `sites.json`:

```swift
            .appendingPathComponent("Anglesite", isDirectory: true)
            .appendingPathComponent("recents.json")
```

3e. Remove the now-unused `settings` stored property and its `init` parameter usage **only if** nothing else references it. (Search the file: if `settings` is unused after removing `refresh()`, drop the property at line 62 and the `settings:` init parameter at lines 78–86. If anything still uses it, leave it.)

3f. Remove the now-unused private statics `canonicalize`/`identifier` (lines 295–305) if `record`/`Site.make` no longer call them (they use the free `canonicalizePackageURL`). Keep whatever is still referenced.

- [ ] **Step 4: Run to verify it passes + Core suite builds**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SiteStoreRecentsTests`
Expected: PASS (4 tests total in the file).

Then confirm the wider Core library still compiles (other call sites of removed `refresh`/`add` are fixed in later tasks — if the *test build* fails on App-only symbols that's fine, but `AnglesiteCore` itself must build):

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build --package-path . --target AnglesiteCore`
Expected: build succeeds. If `SiteScaffolder` references `add`, that's Task 4 — note it and proceed (do not leave AnglesiteCore uncompilable at commit; if needed, land Task 4 before this commit's build claim).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SiteStore.swift Tests/AnglesiteCoreTests/SiteStoreRecentsTests.swift
git commit -m "$(cat <<'EOF'
feat(#242): SiteStore becomes a recents registry (record/touch, recents.json)

Replaces the ~/Sites scan with explicit create/open/import recording, keyed by
the package marker UUID. Discovery is now recents-based per spec §3.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Scaffold new sites into a package's `Source/`

Rework `SiteScaffolder` to create an `.anglesite` package skeleton, run the template scaffold with cwd = `Source/`, `git init` in `Source/`, write owner answers, and register the package.

**Files:**
- Modify: `Sources/AnglesiteCore/SiteScaffolder.swift`
- Test: `Tests/AnglesiteCoreTests/SiteScaffolderPackageTests.swift` (create)

**Interfaces:**
- Consumes: `AnglesitePackage.createSkeleton` (P1), `SiteStore.record` (Task 3).
- Produces: `SiteScaffolder` with `Register = @Sendable (_ package: AnglesitePackage) async throws -> SiteStore.Site` (changed from `siteDirectory: URL`); pipeline computes `siteDir = package.sourceURL`. A new `GitInit = @Sendable (_ sourceDir: URL) async throws -> Void` injected closure (production: `git init` via ProcessSupervisor) so the scaffolder stays testable without spawning git.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import AnglesiteCore

struct SiteScaffolderPackageTests {
    private func tempDir() throws -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("scaffold-pkg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test("scaffold creates a package and runs the template + git init inside Source/")
    func scaffoldsIntoSource() async throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let template = root.appendingPathComponent("Template", isDirectory: true)
        try FileManager.default.createDirectory(at: template.appendingPathComponent("scripts"), withIntermediateDirectories: true)

        // Record the cwd each injected command was run in, and which dir got `git init`.
        actor Spy { var cwds: [URL] = []; var gitInits: [URL] = []
            func cwd(_ u: URL?) { if let u { cwds.append(u) } }
            func git(_ u: URL) { gitInits.append(u) }
        }
        let spy = Spy()

        let scaffolder = SiteScaffolder(
            sitesRoot: root,
            templateURL: template,
            catalog: ThemeCatalog(themes: []),
            run: { _, _, cwd in await spy.cwd(cwd); return .init(stdout: "", stderr: "", exitCode: 0) },
            gitInit: { src in await spy.git(src) },
            register: { pkg in try SiteStore.Site.make(package: pkg) }
        )

        var doneID: String?
        for await step in scaffolder.scaffold(.init(siteType: .business, name: "Acme")) {
            if case .done(let id) = step { doneID = id }
            if case .failed(let s, let m) = step { Issue.record("scaffold failed at \(s): \(m)") }
        }

        let pkg = AnglesitePackage(url: root.appendingPathComponent("acme.anglesite", isDirectory: true))
        #expect(FileManager.default.fileExists(atPath: pkg.sourceURL.path))
        #expect(FileManager.default.fileExists(atPath: pkg.infoPlistURL.path))
        #expect(doneID == (try pkg.readMarker().siteID.uuidString))
        // Template scaffold + npm install ran with cwd == Source/, and git init targeted Source/.
        #expect(await spy.cwds.allSatisfy { $0 == pkg.sourceURL })
        #expect(await spy.gitInits == [pkg.sourceURL])
    }
}
```

(Adjust the `NewSiteDraft(...)` initializer call to the real memberwise init — see `NewSiteDraft.swift:32-56`; pass the minimum required fields.)

- [ ] **Step 2: Run to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SiteScaffolderPackageTests`
Expected: FAIL — `SiteScaffolder` has no `gitInit:` param; `Register` signature mismatch.

- [ ] **Step 3: Implement the changes in `SiteScaffolder.swift`**

3a. Change the `Register` typealias (line 17) and add a `GitInit` typealias:

```swift
    /// Register a freshly-scaffolded package and return the Site (production: SiteStore.shared.record).
    public typealias Register = @Sendable (_ package: AnglesitePackage) async throws -> SiteStore.Site
    /// Initialize a git repo in the source dir (production: `git init` via ProcessSupervisor).
    public typealias GitInit = @Sendable (_ sourceDirectory: URL) async throws -> Void
```

3b. Add `private let gitInit: GitInit` and thread it through `init` (after `register`).

3c. Rewrite `runPipeline` (lines 48–109) so the unit of work is a package:

```swift
    private func runPipeline(_ draft: NewSiteDraft, emit: @Sendable (ScaffoldStep) -> Void) async {
        let slug = SiteSlug.derive(from: draft.name)
        let packageURL = sitesRoot.appendingPathComponent("\(slug).anglesite", isDirectory: true)

        // 1. Package skeleton (dir + Source/ + Config/ + Info.plist marker).
        emit(.creatingFolder)
        let package: AnglesitePackage
        do {
            (package, _) = try AnglesitePackage.createSkeleton(at: packageURL, displayName: draft.name, fileManager: fileManager)
        } catch { return emit(.failed(step: "creatingFolder", message: humanize(error))) }
        let siteDir = package.sourceURL   // everything below runs in Source/

        // 2. scaffold.sh (cwd = Source/)
        emit(.copyingTemplate)
        let scaffoldScript = templateURL.appendingPathComponent("scripts/scaffold.sh")
        do {
            let r = try await run(URL(fileURLWithPath: "/bin/zsh"),
                                  [scaffoldScript.path, "--yes", siteDir.path], siteDir)
            if r.exitCode != 0 {
                return emit(.failed(step: "copyingTemplate", message: "Couldn't create the site files.\n\(r.stderr)"))
            }
        } catch { return emit(.failed(step: "copyingTemplate", message: humanize(error))) }

        // 2b. Owner answers into .site-config (in Source/).
        do { try appendSiteConfig(draft, siteDir: siteDir) }
        catch { emit(.warning(step: "copyingTemplate", message: humanize(error))) }

        // 2c. git init in Source/ (non-fatal — coordinates with #68).
        do { try await gitInit(siteDir) }
        catch { emit(.warning(step: "copyingTemplate", message: "git init skipped: \(humanize(error))")) }

        // 3. Theme (non-fatal)
        emit(.applyingTheme)
        if let theme = catalog.theme(id: draft.themeID) ?? catalog.themes.first {
            do { try ThemeApplier.apply(theme, siteDirectory: siteDir, fileManager: fileManager) }
            catch { emit(.warning(step: "applyingTheme", message: humanize(error))) }
        } else {
            emit(.warning(step: "applyingTheme", message: "No themes available; left default look."))
        }

        // 4. Homepage (non-fatal)
        emit(.writingContent)
        do { try HomepageWriter.write(headline: draft.headline, blurb: draft.blurb,
                                      tagline: draft.tagline, siteDirectory: siteDir, fileManager: fileManager) }
        catch { emit(.warning(step: "writingContent", message: humanize(error))) }

        // 5. npm install (cwd = Source/, non-fatal)
        emit(.installing)
        if let node = NodeRuntime.bundledExecutableURL {
            let npm = node.deletingLastPathComponent().appendingPathComponent("npm")
            do {
                let r = try await run(node, [npm.path] + NodeModulesCache.shared.npmInstallArguments(), siteDir)
                if r.exitCode != 0 {
                    emit(.warning(step: "installing", message: "Dependencies didn't install — you can retry from the site window.\n\(r.stderr)"))
                }
            } catch { emit(.warning(step: "installing", message: humanize(error))) }
        } else {
            emit(.warning(step: "installing", message: "Bundled Node not found; skipped install."))
        }

        // 6. Register the package
        emit(.registering)
        do {
            let site = try await register(package)
            emit(.done(siteID: site.id))
        } catch { emit(.failed(step: "registering", message: humanize(error))) }
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SiteScaffolderPackageTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SiteScaffolder.swift Tests/AnglesiteCoreTests/SiteScaffolderPackageTests.swift
git commit -m "$(cat <<'EOF'
feat(#242): scaffold new sites into an .anglesite package Source/ (+ git init)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Wire the App target — open/create packages + Source/ cwd + MAS grant

Thin SwiftUI glue: `SiteActions` picks a package; the scaffolder is constructed with the new `register`/`gitInit`; `SiteWindow` uses `site.sourceDirectory` for runtime and grants on `site.packageURL`; `AnglesiteApp` gains `onOpenURL` package routing. No unit tests (CI can't host them) — verified by build.

**Files:**
- Modify: `Sources/AnglesiteApp/SiteActions.swift:26-47`
- Modify: `Sources/AnglesiteApp/SiteWindow.swift` (loadAndStart resolve + grant + the preview/deploy/graph site-dir calls)
- Modify: `Sources/AnglesiteApp/AnglesiteApp.swift` (onOpenURL; openSiteFromMenu)
- Modify: the new-site wizard construction site of `SiteScaffolder` (in the launcher view — find via `SiteScaffolder(`)

**Interfaces:**
- Consumes: `SiteStore.record`/`touch`, `Site.sourceDirectory`/`packageURL`, `AnglesitePackage.isPackage`, `SiteScaffolder` new closures.

- [ ] **Step 1: `SiteActions.pickAndRegisterSite()` chooses a package**

Replace the panel config + registration (lines 27–42) so it accepts `.anglesite` packages and records via `record`:

```swift
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.anglesiteSite]   // UTType.anglesiteSite (AnglesiteCore) — non-failable, CI-safe
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose an Anglesite site package."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        do {
            let package = AnglesitePackage(url: url)
            let site = try await SiteStore.shared.record(package)
            #if ANGLESITE_MAS
            let bookmark = try SecurityScopedBookmark.create(for: url)   // url == package
            try await SiteStore.shared.setBookmark(bookmark, for: site.id)
            #endif
            return site
        } catch {
            throw ImportError(folderName: url.lastPathComponent, underlying: error)
        }
```

Add `import UniformTypeIdentifiers` at the top if not present.

- [ ] **Step 2: `SiteWindow` uses Source/ for runtime and grants on the package**

In `loadAndStart()` (around line 401), resolution is unchanged (`store.find(id:)`), but:
- Replace `preview.open(siteID: resolved.id, siteDirectory: resolved.path)` (line ~428) with `siteDirectory: resolved.sourceDirectory`.
- Replace any `deploy.deploy(siteID: site.id, siteDirectory: site.path)` (line ~238) with `siteDirectory: site.sourceDirectory`.
- Replace the ChatModel construction's `siteDirectory: resolved.path` (lines ~462-502) with `resolved.sourceDirectory` for content/graph, but the chat history store path uses `resolved.configDirectory` (P4 changes ChatHistoryStore; until then, pass `sourceDirectory`). **For P2, use `sourceDirectory` everywhere `path` was used for runtime/content; P4 moves chat history to Config/.**
- In `acquireGrant(for:in:)` (lines 548-579), no logic change is needed — it already grants on the bookmark for `site.id`; ensure the bookmark was minted on `site.packageURL` (it is, from Task 5 Step 1 / SiteActions). The `resolved.url` it activates is the package; subprocess cwd (`sourceDirectory`) is inside it. Add `_ = AnglesitePackage(url: resolved.url)` is NOT needed.
- Call `try? await store.touch(id: resolved.id)` right after `AppSettings.shared.lastOpenedSiteID = resolved.id` (line 407) so opening bumps recency.

- [ ] **Step 3: `AnglesiteApp` routes `onOpenURL` to a site window**

Add to the `Window("Sites", id: "sites")` scene content (or the top-level scene) an `.onOpenURL` handler that records the package and opens its window:

```swift
        .onOpenURL { url in
            guard AnglesitePackage.isPackage(at: url) else { return }
            Task { @MainActor in
                do {
                    let site = try await SiteStore.shared.record(AnglesitePackage(url: url))
                    #if ANGLESITE_MAS
                    if let bm = try? SecurityScopedBookmark.create(for: url) {
                        try? await SiteStore.shared.setBookmark(bm, for: site.id)
                    }
                    #endif
                    openWindow(value: site.id)
                } catch {
                    await LogCenter.shared.append(source: "open-url", stream: .stderr, text: "open \(url.lastPathComponent) failed: \(error)")
                }
            }
        }
```

`openSiteFromMenu()` (lines 96–111) needs no change beyond already calling `SiteActions.pickAndRegisterSite()` (now package-aware) then `openWindow(value: site.id)`.

- [ ] **Step 4: Update the wizard's `SiteScaffolder` construction**

At the `SiteScaffolder(` call site (launcher view), update `register:` and add `gitInit:`:

```swift
        let scaffolder = SiteScaffolder(
            sitesRoot: sitesRoot,
            templateURL: templateURL,
            catalog: catalog,
            run: { exe, args, cwd in
                try await ProcessSupervisor.shared.run(executable: exe, arguments: args, currentDirectoryURL: cwd)
            },
            gitInit: { sourceDir in
                let git = URL(fileURLWithPath: "/usr/bin/git")
                _ = try await ProcessSupervisor.shared.run(executable: git, arguments: ["init"], currentDirectoryURL: sourceDir)
            },
            register: { package in
                let site = try await SiteStore.shared.record(package)
                #if ANGLESITE_MAS
                if let bm = try? SecurityScopedBookmark.create(for: package.url) {
                    try? await SiteStore.shared.setBookmark(bm, for: site.id)
                }
                #endif
                return site
            }
        )
```

- [ ] **Step 5: Build both targets**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodegen generate && DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED. Then the MAS scheme:
Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Run the full Core suite to confirm no regressions**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .`
Expected: all suites pass (the MCP/apply-edit e2e tests need `ANGLESITE_PLUGIN_PATH`; if unset they fail-not-skip — set it or note their pre-existing status).

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteApp
git commit -m "$(cat <<'EOF'
feat(#242): open/create .anglesite packages; runtime cwd = Source/; grant on package

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Retarget SiteEntity identity + directory to the package

`SiteEntity` (Siri) is built from `SiteStore.Site`. Its `id` already comes from `site.id` (now the UUID) and `directory` from `site.path` — update to `site.packageURL` for "reveal in Finder" semantics, and index content from `sourceDirectory`.

**Files:**
- Modify: `Sources/AnglesiteIntents/SiteEntity.swift:40-52` (the `init(_ site:)`)

**Interfaces:**
- Consumes: `SiteStore.Site.packageURL`, `.sourceDirectory`.

- [ ] **Step 1: Update `init(_ site:)`**

```swift
    public init(_ site: SiteStore.Site) {
        // Directory mtime misses in-file edits; revisit with git timestamps after #68.
        let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey]
        let values = try? site.sourceDirectory.resourceValues(forKeys: keys)
        self.init(
            id: site.id,                 // package marker UUID — stable across moves (#242)
            name: site.name,
            creationDate: values?.creationDate,
            modificationDate: values?.contentModificationDate,
            directory: site.packageURL   // the package; Finder opens it in Anglesite
        )
    }
```

- [ ] **Step 2: Build the Intents target via the app build**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Run the Intents suite**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter AnglesiteIntentsTests`
Expected: PASS (fix any test that constructed a `Site` with the old `path:` label — update to `packageURL:`).

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteIntents
git commit -m "$(cat <<'EOF'
feat(#242): SiteEntity identity = package UUID; directory = package URL

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage:** §3 recents registry → Tasks 2–3, 5. §5 scaffold-into-Source + git init → Task 4. §6 runtime cwd = Source/ → Tasks 4 (scaffold) + 5 (preview/deploy/graph). §7 MAS bookmark on package → Tasks 5. §1 UUID identity wiring → Tasks 1–2, 6. Open routing (Finder/onOpenURL/Open Site…) → Task 5.

**Known follow-ons (not P2):** chat-history path move to `Config/` is **P4** (Task 5 step 2 keeps it on `sourceDirectory` until then); legacy `sites.json` migration is **P3 Import**; the `SiriReadiness` per-site persistence is **P4**.

**Risk flags for the implementer:**
- Tasks 2+3 are one compilable unit — apply both before the build claim.
- Removing `refresh()`/`add` will break any caller not updated here — grep `\.refresh()` and `SiteStore.shared.add(` across `Sources/` and fix each (RecentSitesModel.start() calls `refresh()` at `RecentSitesModel.swift:30` — change it to `load()` only, since recents no longer scans).
- Use `UTType.anglesiteSite` (declared in `AnglesiteCore/UTType+Anglesite.swift`, P1) for panel content types — it's non-failable, so it stays valid in CI/test processes where the bundle UTI isn't registered. Do not use the failable `UTType("dev.anglesite.site")`.

## Handoff to P3

P3 (Import/Export) consumes: `AnglesitePackage.createSkeleton`, `SiteStore.record`, and the File menu `CommandGroup` (AnglesiteApp.swift:121-143). Import copies a chosen plain directory into a new package's `Source/` (preserving `.git`), then `record`s it; Export copies `Source/` out.
