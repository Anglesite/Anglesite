# iCloud Sync P1: Split-Repo Layout + RepoRelocator Migration — Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split a `.anglesite` package's live git repository out of the iCloud-synced `Source/` tree into a `*.nosync` directory under `Config/`, replacing it with a relative gitfile — the entry-point slice of the iCloud git-sync epic (#876), tracked as issue #877.

**Architecture:** A new `RepoRelocator` enum (AnglesiteCore) does the actual filesystem relocation: `Source/.git` (a directory) moves to `Config/repo.nosync/`, and `Source/.git` becomes a plain-text gitfile (`gitdir: ../Config/repo.nosync`) — the same mechanism git itself uses for submodules, which both stock git and libgit2 already follow transparently. `AnglesitePackage.liveRepositoryURL` (AnglesiteSiteModel) names the new location. Migration runs automatically at the single existing package-open chokepoint (`SiteActions.registerPackage`), so opening any package heals it, and it's idempotent so an already-split package is a no-op. `PackageTransfer.exportSource` re-embeds a real `.git` directory on export so exported/cloned copies stay plain, Anglesite-free repos.

**Tech Stack:** Swift 6.4, Foundation (`FileManager`, `NSFileCoordinator`), SwiftGit2 (Anglesite's libgit2 fork) for the interop-verifying tests, Swift Testing.

## Global Constraints

- iCloud Drive never uploads a path whose last component matches `*.nosync` — this is the mechanism the whole design leans on; there is no official per-item exclusion API. (design doc, external facts)
- The gitfile content is exactly `gitdir: ../Config/repo.nosync\n` — a **relative** path, so the package stays movable as a unit (AirDrop/USB copies, renames).
- `RepoRelocator` itself must not be Darwin-gated (`#if canImport(Darwin)`) at the type level — only its `NSFileCoordinator`-touching internals are, mirroring `BundleSync.coordinatedReplace`'s exact platform split — because the split-repo layout is meant to apply uniformly, including on the cross-platform port (#571).
- Migration must be idempotent and resumable: re-running after an interrupted migration (crash between the directory move and the gitfile write) must heal, not error or duplicate work.
- Follow existing repo conventions exactly: `@Suite(.serialized)` on any Swift Testing suite that touches libgit2 directly (matches `InProcessGitTests`); `.enabled(if:)` gating for tests that shell out to system git, matching the `E2EPrerequisites`/`buildable`-static-property pattern; real subprocess `git` for test fixture setup only, never as the thing under test.
- `swift test --package-path .` and `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build` must both pass before opening the PR (CONTRIBUTING.md).
- Commit subjects ≤72 characters; PR body uses the exact `.github/PULL_REQUEST_TEMPLATE.md` headings (Summary, Paired PR check, Test plan) — this change is self-contained to `Anglesite-app`, no paired sidecar PR.

---

## File Structure

- **Modify** `Sources/AnglesiteSiteModel/AnglesitePackage.swift` — add `liveRepositoryURL`.
- **Modify** `Tests/AnglesiteSiteModelTests/AnglesitePackageTests.swift` — layout test for it.
- **Create** `Sources/AnglesiteCore/RepoRelocator.swift` — the migrator: `migrate(package:)`, `MigrationResult`, `RelocationError`.
- **Create** `Tests/AnglesiteCoreTests/RepoRelocatorTests.swift` — unit suite over the on-disk state machine.
- **Create** `Tests/AnglesiteCoreTests/RepoRelocatorInteropTests.swift` — system-git interop gate.
- **Modify** `Sources/AnglesiteApp/SiteActions.swift` — heal-on-open wiring in `registerPackage`.
- **Create** `Tests/AnglesiteAppTests/SiteActionsRegisterHealTests.swift` — proves the wiring.
- **Modify** `Sources/AnglesiteCore/PackageTransfer.swift` — re-embed `.git` on export.
- **Modify** `Tests/AnglesiteCoreTests/PackageTransferTests.swift` — re-embed + export→import round-trip tests.

---

## Task 1: `AnglesitePackage.liveRepositoryURL`

**Files:**
- Modify: `Sources/AnglesiteSiteModel/AnglesitePackage.swift`
- Test: `Tests/AnglesiteSiteModelTests/AnglesitePackageTests.swift`

**Interfaces:**
- Produces: `AnglesitePackage.liveRepositoryURL: URL` — `Config/repo.nosync/`, used by every later task.

- [ ] **Step 1: Write the failing test**

Open `Tests/AnglesiteSiteModelTests/AnglesitePackageTests.swift` and add (near the other layout tests, e.g. next to whatever test covers `syncDirectoryURL`/`quickLookThumbnailURL`):

```swift
    @Test("liveRepositoryURL is Config/repo.nosync — never uploaded by iCloud, never inside Source/")
    func liveRepositoryURLLayout() {
        let pkg = AnglesitePackage(url: URL(fileURLWithPath: "/tmp/Foo.anglesite"))
        #expect(pkg.liveRepositoryURL.path == "/tmp/Foo.anglesite/Config/repo.nosync")
        #expect(pkg.liveRepositoryURL.path.hasPrefix(pkg.configURL.path))
        #expect(!pkg.liveRepositoryURL.path.hasPrefix(pkg.sourceURL.path))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter AnglesitePackageTests`
Expected: FAIL — `value of type 'AnglesitePackage' has no member 'liveRepositoryURL'`

- [ ] **Step 3: Write minimal implementation**

In `Sources/AnglesiteSiteModel/AnglesitePackage.swift`, add next to `syncDirectoryURL` (after its doc comment block, before `syncBundleURL`):

```swift
    /// The live git repository, out of the iCloud-synced `Source/` tree (#875/#877). iCloud Drive
    /// never uploads a path whose last component matches `*.nosync`, so this is where the real
    /// `.git` directory lives once a package is migrated to the split-repo layout — `Source/.git`
    /// becomes a relative gitfile (`RepoRelocator`) pointing here, which `cd`/git/VS Code/libgit2
    /// all follow transparently (the same mechanism git uses for submodules).
    public var liveRepositoryURL: URL { configURL.appendingPathComponent("repo.nosync", isDirectory: true) }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter AnglesitePackageTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteSiteModel/AnglesitePackage.swift Tests/AnglesiteSiteModelTests/AnglesitePackageTests.swift
git commit -m "feat(#877): add AnglesitePackage.liveRepositoryURL"
```

---

## Task 2: `RepoRelocator` — migration state machine + unit suite

**Files:**
- Create: `Sources/AnglesiteCore/RepoRelocator.swift`
- Create: `Tests/AnglesiteCoreTests/RepoRelocatorTests.swift`

**Interfaces:**
- Consumes: `AnglesitePackage.sourceURL`, `.configURL`, `.liveRepositoryURL` (Task 1).
- Produces:
  - `RepoRelocator.migrate(package: AnglesitePackage, fileManager: FileManager = .default) throws -> RepoRelocator.MigrationResult` — used by Task 4.
  - `RepoRelocator.MigrationResult`: `.migrated`, `.alreadySplit`, `.noRepository`.
  - `RepoRelocator.RelocationError`: `.danglingGitfile(URL)`, `.conflictingRepositories(embedded: URL, live: URL)`.
  - `RepoRelocator.gitfileContents: String` (internal `static let`, used by tests to assert exact content) — value `"gitdir: ../Config/repo.nosync\n"`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/RepoRelocatorTests.swift`:

```swift
#if canImport(Darwin)
import Testing
import Foundation
import AnglesiteSiteModel
import AnglesiteTestSupport
@testable import AnglesiteCore

/// `RepoRelocator` moves an embedded `Source/.git` directory to `Config/repo.nosync/` and
/// replaces it with a relative gitfile (#875/#877). Fixtures use real subprocess `git` (tests run
/// unsandboxed) to build embedded repos; the subject under test is `RepoRelocator` itself, and
/// `Repository.at` (SwiftGit2/libgit2) verifies the resulting gitfile actually resolves — matching
/// the cross-check style established by `InProcessGitTests`.
///
/// .serialized: libgit2 isn't safe for uncoordinated concurrent use (see the fork's specs).
@Suite("RepoRelocator", .serialized) struct RepoRelocatorTests {

    // MARK: - Fixtures

    private func makePackageSkeleton() throws -> AnglesitePackage {
        let root = try makeTempDir(prefix: "repo-relocator")
        let pkgURL = root.appendingPathComponent("Test.anglesite", isDirectory: true)
        let (pkg, _) = try AnglesitePackage.createSkeleton(at: pkgURL, displayName: "Test")
        return pkg
    }

    @discardableResult
    private func git(_ arguments: [String], in dir: URL) async throws -> ProcessSupervisor.RunResult {
        let result = try await ProcessSupervisor.shared.run(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["git"] + arguments,
            currentDirectoryURL: dir
        )
        #expect(result.exitCode == 0, "fixture git \(arguments.joined(separator: " ")) exited \(result.exitCode): \(result.stderr)")
        return result
    }

    /// A package whose `Source/` is a real, embedded (unmigrated) git repo with one commit.
    private func makeEmbeddedRepoPackage() async throws -> AnglesitePackage {
        let pkg = try makePackageSkeleton()
        try await git(["init"], in: pkg.sourceURL)
        try await git(["config", "user.email", "t@t.io"], in: pkg.sourceURL)
        try await git(["config", "user.name", "t"], in: pkg.sourceURL)
        try "seed".write(to: pkg.sourceURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await git(["add", "-A"], in: pkg.sourceURL)
        try await git(["commit", "-m", "seed"], in: pkg.sourceURL)
        return pkg
    }

    // MARK: - migrate: embedded -> split

    @Test("migrates an embedded Source/.git directory to Config/repo.nosync and writes the gitfile")
    func migratesEmbeddedRepo() async throws {
        let pkg = try await makeEmbeddedRepoPackage()
        let fm = FileManager.default
        let gitPath = pkg.sourceURL.appendingPathComponent(".git")

        let result = try RepoRelocator.migrate(package: pkg)

        #expect(result == .migrated)
        var isDir: ObjCBool = false
        #expect(fm.fileExists(atPath: gitPath.path, isDirectory: &isDir) && !isDir.boolValue, "Source/.git is now a gitfile, not a directory")
        let gitfile = try String(contentsOf: gitPath, encoding: .utf8)
        #expect(gitfile == "gitdir: ../Config/repo.nosync\n")
        #expect(fm.fileExists(atPath: pkg.liveRepositoryURL.appendingPathComponent("HEAD").path), "the real repo now lives in Config/repo.nosync")

        // libgit2 must resolve the gitfile transparently.
        SwiftGit2Bootstrap.ensureInitialized
        guard case .success(let repo) = Repository.at(pkg.sourceURL) else {
            Issue.record("Repository.at(sourceURL) failed to follow the migrated gitfile")
            return
        }
        #expect((try? repo.HEAD().get())?.oid != nil)
    }

    @Test("migrate is idempotent: a second call on an already-split package is a no-op")
    func idempotentOnAlreadySplit() async throws {
        let pkg = try await makeEmbeddedRepoPackage()
        #expect(try RepoRelocator.migrate(package: pkg) == .migrated)

        let gitPath = pkg.sourceURL.appendingPathComponent(".git")
        let contentsBefore = try String(contentsOf: gitPath, encoding: .utf8)

        let second = try RepoRelocator.migrate(package: pkg)

        #expect(second == .alreadySplit)
        #expect(try String(contentsOf: gitPath, encoding: .utf8) == contentsBefore)
    }

    @Test("migrate heals an interrupted migration: repo already moved, gitfile never written")
    func healsInterruptedMigration() async throws {
        let pkg = try await makeEmbeddedRepoPackage()
        let fm = FileManager.default
        let gitPath = pkg.sourceURL.appendingPathComponent(".git")

        // Simulate a crash between the directory move and the gitfile write: do the move by hand,
        // leave no gitfile behind.
        try fm.moveItem(at: gitPath, to: pkg.liveRepositoryURL)
        #expect(!fm.fileExists(atPath: gitPath.path))

        let result = try RepoRelocator.migrate(package: pkg)

        #expect(result == .migrated)
        #expect(try String(contentsOf: gitPath, encoding: .utf8) == "gitdir: ../Config/repo.nosync\n")
    }

    @Test("migrate heals a corrupted or foreign gitfile when the live repo is present")
    func healsCorruptedGitfile() async throws {
        let pkg = try await makeEmbeddedRepoPackage()
        try RepoRelocator.migrate(package: pkg)
        let gitPath = pkg.sourceURL.appendingPathComponent(".git")
        try "gitdir: /somewhere/else\n".write(to: gitPath, atomically: true, encoding: .utf8)

        let result = try RepoRelocator.migrate(package: pkg)

        #expect(result == .migrated)
        #expect(try String(contentsOf: gitPath, encoding: .utf8) == "gitdir: ../Config/repo.nosync\n")
    }

    @Test("migrate is a no-op on a fresh skeleton with no repository at all")
    func noRepositoryIsNoOp() throws {
        let pkg = try makePackageSkeleton()
        let result = try RepoRelocator.migrate(package: pkg)
        #expect(result == .noRepository)
        #expect(!FileManager.default.fileExists(atPath: pkg.sourceURL.appendingPathComponent(".git").path))
        #expect(!FileManager.default.fileExists(atPath: pkg.liveRepositoryURL.path))
    }

    @Test("migrate throws danglingGitfile when the gitfile's target repo doesn't exist locally")
    func throwsOnDanglingGitfile() throws {
        let pkg = try makePackageSkeleton()
        try "gitdir: ../Config/repo.nosync\n".write(
            to: pkg.sourceURL.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        #expect(throws: RepoRelocator.RelocationError.self) {
            try RepoRelocator.migrate(package: pkg)
        }
    }

    @Test("migrate throws conflictingRepositories when both an embedded dir and a live repo exist")
    func throwsOnConflictingRepositories() async throws {
        let pkg = try await makeEmbeddedRepoPackage()
        // Fabricate the conflict: a second repo already sitting at Config/repo.nosync.
        try FileManager.default.createDirectory(at: pkg.liveRepositoryURL, withIntermediateDirectories: true)
        try await git(["init"], in: pkg.liveRepositoryURL)

        #expect(throws: RepoRelocator.RelocationError.self) {
            try RepoRelocator.migrate(package: pkg)
        }
    }
}
#endif
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter RepoRelocatorTests`
Expected: FAIL to build — `cannot find 'RepoRelocator' in scope`

- [ ] **Step 3: Write the implementation**

Create `Sources/AnglesiteCore/RepoRelocator.swift`:

```swift
import Foundation
import AnglesiteSiteModel

/// Moves a `.anglesite` package's embedded `Source/.git` directory to `Config/repo.nosync/`,
/// replacing it with a relative gitfile — the local half of the iCloud git-sync design (#863/#875).
/// iCloud Drive never uploads a `*.nosync` path, so the live repository stays off iCloud while
/// `Source/` keeps working as an ordinary git working tree for `cd`/git/VS Code/`git clone` — the
/// gitfile's relative `gitdir:` pointer is git's own submodule mechanism, followed transparently
/// by both stock git and libgit2.
///
/// Idempotent and resumable: `migrate` inspects the current on-disk state rather than assuming a
/// fresh embedded repo, so re-running after an interrupted migration (a crash between the
/// directory move and the gitfile write) completes it instead of erroring or duplicating work.
/// Deliberately not Darwin-gated at the type level (only the `NSFileCoordinator`-touching
/// internals are, matching `BundleSync.coordinatedReplace`) — the split-repo layout is meant to
/// apply uniformly, including on the cross-platform port (#571).
public enum RepoRelocator {
    /// `gitdir:` pointer content, relative from `Source/` to `Config/repo.nosync/`.
    static let gitfileContents = "gitdir: ../Config/repo.nosync\n"

    public enum MigrationResult: Sendable, Equatable {
        /// Moved an embedded `Source/.git` directory to `Config/repo.nosync/` and wrote the
        /// gitfile, or completed an interrupted prior migration (repo already relocated, gitfile
        /// missing or corrupted).
        case migrated
        /// Already in split-repo layout: `Source/.git` is the gitfile, `Config/repo.nosync/`
        /// exists, and the gitfile already carries the correct content.
        case alreadySplit
        /// Neither an embedded nor a split repository exists yet — nothing to migrate (e.g. a
        /// freshly-scaffolded skeleton).
        case noRepository
    }

    public enum RelocationError: Error, Equatable, Sendable, LocalizedError {
        /// `Source/.git` is a gitfile, but its target `Config/repo.nosync/` doesn't exist on this
        /// Mac. This is the "fresh peer" case — a package synced in from iCloud before its live
        /// repo history arrived. `RepoRelocator` only relocates a repo that already exists
        /// locally; bootstrapping one from the sync bundle is a separate, later phase (#879).
        case danglingGitfile(URL)
        /// Both `Source/.git` (a directory) and `Config/repo.nosync/` exist — an ambiguous state
        /// `RepoRelocator` refuses to resolve automatically rather than risk discarding history.
        case conflictingRepositories(embedded: URL, live: URL)

        public var errorDescription: String? {
            switch self {
            case .danglingGitfile(let url):
                return "This site's local git history hasn't arrived yet (gitfile at \(url.path) has no target). Wait for iCloud to sync, or open it on the Mac that has the history."
            case .conflictingRepositories(let embedded, let live):
                return "Found two git histories for this site (\(embedded.path) and \(live.path)) — resolve this manually before continuing."
            }
        }
    }

    /// Migrates `package` to the split-repo layout if needed. Safe to call on every package open
    /// (heal-on-open): an already-split package is a no-op, and a package with no repository yet
    /// is also a no-op.
    @discardableResult
    public static func migrate(
        package: AnglesitePackage,
        fileManager: FileManager = .default
    ) throws -> MigrationResult {
        let gitPath = package.sourceURL.appendingPathComponent(".git", isDirectory: false)
        let liveRepoURL = package.liveRepositoryURL

        var gitPathIsDirectory: ObjCBool = false
        let gitPathExists = fileManager.fileExists(atPath: gitPath.path, isDirectory: &gitPathIsDirectory)
        let liveRepoExists = fileManager.fileExists(atPath: liveRepoURL.path)

        switch (gitPathExists, gitPathIsDirectory.boolValue, liveRepoExists) {
        case (false, _, false):
            return .noRepository

        case (true, true, false):
            // Embedded, unmigrated: move Source/.git -> Config/repo.nosync/, write the gitfile.
            try fileManager.createDirectory(at: package.configURL, withIntermediateDirectories: true)
            try coordinatedMove(from: gitPath, to: liveRepoURL)
            try writeGitfile(at: gitPath)
            return .migrated

        case (true, true, true):
            throw RelocationError.conflictingRepositories(embedded: gitPath, live: liveRepoURL)

        case (false, _, true):
            // Interrupted mid-migration (moved, gitfile never written) — heal by writing it.
            try writeGitfile(at: gitPath)
            return .migrated

        case (true, false, true):
            // Gitfile already present with a target — heal it only if its content is wrong
            // (corrupted, foreign, or stale), rather than trusting it blindly.
            let contents = try? String(contentsOf: gitPath, encoding: .utf8)
            if contents == Self.gitfileContents {
                return .alreadySplit
            }
            try writeGitfile(at: gitPath)
            return .migrated

        case (true, false, false):
            throw RelocationError.danglingGitfile(gitPath)
        }
    }

    // MARK: - Coordinated filesystem operations

    #if canImport(Darwin)
    /// Coordinated directory move — the documented way to relocate an item that may be under an
    /// iCloud/file-presenter's watch, matching `BundleSync.coordinatedReplace`'s pattern.
    private static func coordinatedMove(from source: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var ioError: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: source, options: .forMoving,
            writingItemAt: destination, options: [],
            error: &coordinationError
        ) { movingURL, destinationURL in
            do {
                try FileManager.default.moveItem(at: movingURL, to: destinationURL)
            } catch {
                ioError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let ioError { throw ioError }
    }

    private static func writeGitfile(at gitfileURL: URL) throws {
        var coordinationError: NSError?
        var ioError: Error?
        NSFileCoordinator().coordinate(writingItemAt: gitfileURL, options: [], error: &coordinationError) { url in
            do {
                try Self.gitfileContents.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                ioError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let ioError { throw ioError }
    }
    #else
    /// `NSFileCoordinator` (and the iCloud Drive sync it coordinates with) doesn't exist off
    /// Darwin, so there's no peer to race against — a direct move/write is equivalent.
    private static func coordinatedMove(from source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }

    private static func writeGitfile(at gitfileURL: URL) throws {
        try Self.gitfileContents.write(to: gitfileURL, atomically: true, encoding: .utf8)
    }
    #endif
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter RepoRelocatorTests`
Expected: PASS (all 7 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/RepoRelocator.swift Tests/AnglesiteCoreTests/RepoRelocatorTests.swift
git commit -m "feat(#877): add RepoRelocator split-repo migration"
```

---

## Task 3: Gitfile interop test against system git

**Files:**
- Create: `Tests/AnglesiteCoreTests/RepoRelocatorInteropTests.swift`

**Interfaces:**
- Consumes: `RepoRelocator.migrate` (Task 2), `AnglesitePackage.createSkeleton` (existing).

- [ ] **Step 1: Write the failing test**

Create `Tests/AnglesiteCoreTests/RepoRelocatorInteropTests.swift`:

```swift
#if canImport(Darwin)
import Testing
import Foundation
import AnglesiteSiteModel
import AnglesiteTestSupport
@testable import AnglesiteCore

/// Proves the migrated gitfile isn't just a libgit2-specific trick: real system `git` must follow
/// it too, and a real `git clone` of the migrated `Source/` must succeed — the acceptance bar from
/// issue #877 ("git status/git log in Source/ work via system git, git clone … succeeds").
@Suite("RepoRelocator system-git interop")
struct RepoRelocatorInteropTests {
    static var gitAvailable: Bool { FileManager.default.isExecutableFile(atPath: "/usr/bin/git") }

    @discardableResult
    private func git(_ arguments: [String], in dir: URL) async throws -> ProcessSupervisor.RunResult {
        try await ProcessSupervisor.shared.run(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["git"] + arguments,
            currentDirectoryURL: dir
        )
    }

    @Test(
        "system git status/log/clone all work against a migrated Source/",
        .enabled(if: RepoRelocatorInteropTests.gitAvailable, "requires /usr/bin/git")
    )
    func systemGitFollowsTheGitfile() async throws {
        let root = try makeTempDir(prefix: "repo-relocator-interop")
        let pkgURL = root.appendingPathComponent("Test.anglesite", isDirectory: true)
        let (pkg, _) = try AnglesitePackage.createSkeleton(at: pkgURL, displayName: "Test")

        try await git(["init"], in: pkg.sourceURL)
        try await git(["config", "user.email", "t@t.io"], in: pkg.sourceURL)
        try await git(["config", "user.name", "t"], in: pkg.sourceURL)
        try "seed".write(to: pkg.sourceURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await git(["add", "-A"], in: pkg.sourceURL)
        try await git(["commit", "-m", "seed"], in: pkg.sourceURL)

        #expect(try RepoRelocator.migrate(package: pkg) == .migrated)

        let status = try await git(["status", "--porcelain"], in: pkg.sourceURL)
        #expect(status.exitCode == 0)

        let log = try await git(["log", "--oneline"], in: pkg.sourceURL)
        #expect(log.exitCode == 0)
        #expect(log.stdout.contains("seed"))

        let cloneDest = root.appendingPathComponent("cloned", isDirectory: true)
        let clone = try await git(["clone", pkg.sourceURL.path, cloneDest.path], in: root)
        #expect(clone.exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: cloneDest.appendingPathComponent("README.md").path))
        // The clone must be a fully independent, real repo — not another gitfile pointing back
        // into the original package.
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: cloneDest.appendingPathComponent(".git").path, isDirectory: &isDir) && isDir.boolValue)
    }
}
#endif
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter RepoRelocatorInteropTests`
Expected: FAIL to build (references `RepoRelocator` — should actually already build fine after Task 2; if Task 2 landed first this should instead run and PASS immediately). If it fails to build, re-check Task 2 landed on this branch first.

- [ ] **Step 3: N/A — no new production code**

This task only adds a test; `RepoRelocator.migrate` from Task 2 is the implementation under test.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter RepoRelocatorInteropTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Tests/AnglesiteCoreTests/RepoRelocatorInteropTests.swift
git commit -m "test(#877): system-git interop check for the migrated gitfile"
```

---

## Task 4: Heal-on-open wiring in `SiteActions.registerPackage`

**Files:**
- Modify: `Sources/AnglesiteApp/SiteActions.swift`
- Create: `Tests/AnglesiteAppTests/SiteActionsRegisterHealTests.swift`

**Interfaces:**
- Consumes: `RepoRelocator.migrate` (Task 2), `SiteStore.init(persistenceURL:fileManager:)` (existing — the non-shared constructor already used for test isolation elsewhere).
- Produces: `SiteActions.registerPackage(_ package: AnglesitePackage, siteStore: SiteStore = .shared) async throws -> SiteStore.Site` — the `siteStore` parameter is additive (defaulted), so every existing call site (`registerPackage(at:)`, `importDirectory`'s default `register` closure, `pickAndRegisterSite`, `reauthorize`) keeps compiling unchanged.

- [ ] **Step 1: Write the failing test**

Create `Tests/AnglesiteAppTests/SiteActionsRegisterHealTests.swift`:

```swift
import Testing
import Foundation
import AnglesiteCore
import AnglesiteSiteModel
@testable import AnglesiteAppCore

/// `registerPackage` is the single chokepoint every open path shares (Finder-open, launcher
/// drag-drop, Dock menu, File ▸ Open Site…, Import) — so it's where heal-on-open belongs (#877).
/// Uses a throwaway `SiteStore` (its own `persistenceURL`), never `.shared`, so this test can't
/// pollute or race a developer's real recents.json.
@Suite("SiteActions register heal-on-open")
@MainActor
struct SiteActionsRegisterHealTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("site-actions-heal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func git(_ arguments: [String], in dir: URL) async throws -> ProcessSupervisor.RunResult {
        try await ProcessSupervisor.shared.run(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["git"] + arguments,
            currentDirectoryURL: dir
        )
    }

    @Test("registering a package with an embedded Source/.git migrates it to the split layout")
    func registerHealsEmbeddedRepo() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let pkgURL = root.appendingPathComponent("Test.anglesite", isDirectory: true)
        let (pkg, _) = try AnglesitePackage.createSkeleton(at: pkgURL, displayName: "Test")
        try await git(["init"], in: pkg.sourceURL)
        try await git(["config", "user.email", "t@t.io"], in: pkg.sourceURL)
        try await git(["config", "user.name", "t"], in: pkg.sourceURL)
        try "seed".write(to: pkg.sourceURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await git(["add", "-A"], in: pkg.sourceURL)
        try await git(["commit", "-m", "seed"], in: pkg.sourceURL)

        let store = SiteStore(persistenceURL: root.appendingPathComponent("recents.json"))
        let site = try await SiteActions.registerPackage(pkg, siteStore: store)

        var isDir: ObjCBool = false
        let gitPath = pkg.sourceURL.appendingPathComponent(".git")
        #expect(FileManager.default.fileExists(atPath: gitPath.path, isDirectory: &isDir) && !isDir.boolValue, "Source/.git is now a gitfile")
        #expect(FileManager.default.fileExists(atPath: pkg.liveRepositoryURL.appendingPathComponent("HEAD").path))
        #expect(await store.find(id: site.id) != nil, "the site was still recorded after healing")
    }

    @Test("registering an already-split package is a no-op for the repository layout")
    func registerNoOpOnAlreadySplit() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let pkgURL = root.appendingPathComponent("Test.anglesite", isDirectory: true)
        let (pkg, _) = try AnglesitePackage.createSkeleton(at: pkgURL, displayName: "Test")
        try await git(["init"], in: pkg.sourceURL)
        try await git(["config", "user.email", "t@t.io"], in: pkg.sourceURL)
        try await git(["config", "user.name", "t"], in: pkg.sourceURL)
        try "seed".write(to: pkg.sourceURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await git(["add", "-A"], in: pkg.sourceURL)
        try await git(["commit", "-m", "seed"], in: pkg.sourceURL)

        let store = SiteStore(persistenceURL: root.appendingPathComponent("recents.json"))
        _ = try await SiteActions.registerPackage(pkg, siteStore: store)
        let gitPath = pkg.sourceURL.appendingPathComponent(".git")
        let contentsAfterFirstOpen = try String(contentsOf: gitPath, encoding: .utf8)

        // Re-open (e.g. Open Recent on a second launch).
        _ = try await SiteActions.registerPackage(pkg, siteStore: store)
        #expect(try String(contentsOf: gitPath, encoding: .utf8) == contentsAfterFirstOpen)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter SiteActionsRegisterHealTests`
Expected: FAIL to build — `extra argument 'siteStore' in call`

- [ ] **Step 3: Write the implementation**

In `Sources/AnglesiteApp/SiteActions.swift`, replace the `registerPackage` overloads (lines 27–45):

```swift
    /// Register an existing `.anglesite` package and (on MAS) mint its security-scoped bookmark —
    /// the ONLY mint call site, shared by every open path: Finder-open (`onOpenURL`), launcher
    /// drag-drop (#524), the Dock menu, File ▸ Open Site… (`pickAndRegisterSite`), and Import
    /// (`importPackage`). `record` reads and validates the marker, throwing a legible error for
    /// non-packages.
    static func registerPackage(at url: URL) async throws -> SiteStore.Site {
        try await registerPackage(AnglesitePackage(url: url))
    }

    /// Variant for callers that already hold a constructed package (Import creates one via
    /// `PackageTransfer` before registering). Every open path funnels through here, which makes
    /// this the natural heal-on-open point (#877): before recording, migrate the package to the
    /// split-repo layout if it still has an embedded `Source/.git` — already-split packages are a
    /// no-op. `siteStore` is an injection seam for tests; production always uses `.shared`.
    static func registerPackage(_ package: AnglesitePackage, siteStore: SiteStore = .shared) async throws -> SiteStore.Site {
        try RepoRelocator.migrate(package: package)
        let site = try await siteStore.record(package)
        #if ANGLESITE_MAS
        // The current access grant (open panel, drag, or LaunchServices open) is the only chance
        // to mint a scoped bookmark — persist it now so the grant survives relaunch. Mint from
        // `site.packageURL` (the canonicalized path the store recorded) so the bookmark's path
        // matches what subprocesses are spawned against. Propagate failures (never `try?`): a
        // grantless site silently fails to preview at open.
        let bookmark = try SecurityScopedBookmark.create(for: site.packageURL)
        try await siteStore.setBookmark(bookmark, for: site.id)
        #endif
        return site
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter SiteActionsRegisterHealTests`
Expected: PASS

Then run the full existing `SiteActions` coverage to confirm the additive parameter didn't disturb the import path:

Run: `swift test --package-path . --filter SiteActionsImportTests`
Expected: PASS (unchanged — `importDirectory`'s default `register` closure still resolves to `registerPackage(package)`, `siteStore` defaulting to `.shared`)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/SiteActions.swift Tests/AnglesiteAppTests/SiteActionsRegisterHealTests.swift
git commit -m "feat(#877): heal-on-open — migrate embedded repos in registerPackage"
```

---

## Task 5: `PackageTransfer.exportSource` re-embeds a real `.git` directory

**Files:**
- Modify: `Sources/AnglesiteCore/PackageTransfer.swift`
- Modify: `Tests/AnglesiteCoreTests/PackageTransferTests.swift`

**Interfaces:**
- Consumes: `AnglesitePackage.liveRepositoryURL` (Task 1), `RepoRelocator.migrate` (Task 2, used only in the test fixture to produce a migrated package).
- Produces: `PackageTransfer.exportSource(of:to:includeGit:fileManager:)` behavior change only — signature unchanged.

- [ ] **Step 1: Write the failing tests**

In `Tests/AnglesiteCoreTests/PackageTransferTests.swift`, add (the file already has a `tempDir()` helper and `import AnglesiteCore` — add `import AnglesiteSiteModel` at the top if not already present):

```swift
    @Test("export re-embeds a real .git directory when Source/.git has been migrated to a gitfile")
    func exportReembedsMigratedRepo() async throws {
        let fm = FileManager.default
        let root = try tempDir(); defer { try? fm.removeItem(at: root) }

        let pkgURL = root.appendingPathComponent("Migrated.anglesite", isDirectory: true)
        let (pkg, _) = try AnglesitePackage.createSkeleton(at: pkgURL, displayName: "Migrated")
        try await gitFixture(["init"], in: pkg.sourceURL)
        try await gitFixture(["config", "user.email", "t@t.io"], in: pkg.sourceURL)
        try await gitFixture(["config", "user.name", "t"], in: pkg.sourceURL)
        try "seed".write(to: pkg.sourceURL.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)
        try await gitFixture(["add", "-A"], in: pkg.sourceURL)
        try await gitFixture(["commit", "-m", "seed"], in: pkg.sourceURL)
        #if canImport(Darwin)
        _ = try RepoRelocator.migrate(package: pkg)
        #endif

        let dest = root.appendingPathComponent("exported", isDirectory: true)
        try PackageTransfer.exportSource(of: pkg, to: dest, includeGit: true, fileManager: fm)

        var isDir: ObjCBool = false
        #expect(fm.fileExists(atPath: dest.appendingPathComponent(".git").path, isDirectory: &isDir) && isDir.boolValue,
                "the exported .git is a real directory, not the package's gitfile")
        #expect(fm.fileExists(atPath: dest.appendingPathComponent(".git/HEAD").path))
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("index.md").path))
    }

    @Test("export -> re-import round-trips: the re-imported package has a real embedded .git again")
    func exportThenReimportRoundTrips() async throws {
        let fm = FileManager.default
        let root = try tempDir(); defer { try? fm.removeItem(at: root) }

        let pkgURL = root.appendingPathComponent("Migrated.anglesite", isDirectory: true)
        let (pkg, _) = try AnglesitePackage.createSkeleton(at: pkgURL, displayName: "Migrated")
        try await gitFixture(["init"], in: pkg.sourceURL)
        try await gitFixture(["config", "user.email", "t@t.io"], in: pkg.sourceURL)
        try await gitFixture(["config", "user.name", "t"], in: pkg.sourceURL)
        try "seed".write(to: pkg.sourceURL.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)
        try await gitFixture(["add", "-A"], in: pkg.sourceURL)
        try await gitFixture(["commit", "-m", "seed"], in: pkg.sourceURL)
        #if canImport(Darwin)
        _ = try RepoRelocator.migrate(package: pkg)
        #endif

        let exported = root.appendingPathComponent("exported", isDirectory: true)
        try PackageTransfer.exportSource(of: pkg, to: exported, includeGit: true, fileManager: fm)

        let reimportedURL = root.appendingPathComponent("Reimported.anglesite", isDirectory: true)
        let reimported = try PackageTransfer.importDirectory(exported, toPackageAt: reimportedURL, displayName: "Reimported", fileManager: fm)

        var isDir: ObjCBool = false
        #expect(fm.fileExists(atPath: reimported.sourceURL.appendingPathComponent(".git").path, isDirectory: &isDir) && isDir.boolValue)
        #expect(fm.fileExists(atPath: reimported.sourceURL.appendingPathComponent("index.md").path))
    }

    @discardableResult
    private func gitFixture(_ arguments: [String], in dir: URL) async throws -> ProcessSupervisor.RunResult {
        try await ProcessSupervisor.shared.run(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["git"] + arguments,
            currentDirectoryURL: dir
        )
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter PackageTransferTests`
Expected: `exportReembedsMigratedRepo` FAILs — the exported `.git` is copied as the tiny gitfile, not a real directory, so `isDir` is false.

- [ ] **Step 3: Write the implementation**

In `Sources/AnglesiteCore/PackageTransfer.swift`, replace `exportSource` (lines 77–99):

```swift
    /// Copy `package`'s `Source/` working tree to `destinationDir`. Always omits `node_modules/`;
    /// omits `.git` unless `includeGit`. `destinationDir` must not already exist.
    ///
    /// If the package has been migrated to the split-repo layout (#875/#877) — `Source/.git` is a
    /// relative gitfile pointing at `Config/repo.nosync/` — a naive copy of that gitfile would
    /// produce a dangling pointer outside the package. So when `includeGit` is true and the
    /// package is split, the real repository is re-embedded as an ordinary `.git` directory
    /// instead: exported/cloned copies always stay plain, self-contained repos with no
    /// Anglesite-isms, matching what a package with an embedded (unmigrated) repo already does.
    public static func exportSource(
        of package: AnglesitePackage,
        to destinationDir: URL,
        includeGit: Bool,
        fileManager: FileManager = .default
    ) throws {
        guard !fileManager.fileExists(atPath: destinationDir.path) else {
            throw TransferError.destinationExists(destinationDir)
        }
        // Copy the excluded directories' *siblings* rather than copy-all-then-prune: copying the
        // whole tree first would temporarily double disk usage and waste time on a multi-GB
        // node_modules we immediately delete. The excluded dirs are always top-level in an Astro
        // project, so a top-level filtered copy is sufficient (and preserves hidden files like
        // .gitignore / .site-config that aren't excluded).
        var excluded: Set<String> = ["node_modules"]
        var reembedGitFrom: URL?
        if includeGit {
            let gitPath = package.sourceURL.appendingPathComponent(".git", isDirectory: false)
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: gitPath.path, isDirectory: &isDir), !isDir.boolValue {
                excluded.insert(".git")
                reembedGitFrom = package.liveRepositoryURL
            }
        } else {
            excluded.insert(".git")
        }
        try fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        let entries = try fileManager.contentsOfDirectory(
            at: package.sourceURL, includingPropertiesForKeys: nil, options: [])
        for entry in entries where !excluded.contains(entry.lastPathComponent) {
            try fileManager.copyItem(at: entry, to: destinationDir.appendingPathComponent(entry.lastPathComponent))
        }
        if let reembedGitFrom {
            try fileManager.copyItem(at: reembedGitFrom, to: destinationDir.appendingPathComponent(".git"))
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter PackageTransferTests`
Expected: PASS (all tests in the file, including the pre-existing `importCopiesIntoSource`)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/PackageTransfer.swift Tests/AnglesiteCoreTests/PackageTransferTests.swift
git commit -m "feat(#877): export re-embeds a real .git for migrated packages"
```

---

## Task 6: Full verification + PR

**Files:** none (verification only)

- [ ] **Step 1: Run the full Swift test suite**

Run: `swift test --package-path .`
Expected: PASS (or only pre-existing, unrelated failures/flakes — cross-check against any you see with recent `main` CI before assuming this work caused them)

- [ ] **Step 2: Run the app build**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Re-read `CONTRIBUTING.md` ▸ "Commits and pull requests" and open the PR**

Use `.github/PULL_REQUEST_TEMPLATE.md`'s exact headings (Summary, Paired PR check, Test plan). This change is self-contained to `Anglesite-app` — no paired sidecar PR. Reference #877 in the PR body ("Part of #876. Closes #877" or similar) and in commit subjects already used above.

- [ ] **Step 4: Remove the in-progress label**

```bash
gh issue edit 877 --remove-label "🛠️ In Progress"
```
