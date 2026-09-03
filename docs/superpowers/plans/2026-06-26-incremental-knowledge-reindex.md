# Incremental Knowledge Reindex Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the `SiteKnowledgeIndex` fresh while a site is open by watching the package's `Source/` directory and feeding changed files to the index's existing `upsertFile`/`removeFile` seams.

**Architecture:** A host-side FSEvents watcher (`SiteFileWatcher.swift`) on `Source/` delivers debounced change batches. A runtime-agnostic free function `KnowledgeReindex.apply` translates each batch into index calls (upsert existing files, remove deleted ones, full-rebuild on coalesced bulk events). Both `LocalSiteRuntime` and `LocalContainerSiteRuntime` own a watcher, starting it after the open-time `rebuild` and stopping it on teardown, behind a `SiteFileWatching` protocol seam so tests drive synthetic batches without touching the filesystem.

**Tech Stack:** Swift 6.4, Swift Testing (`@Test`/`@Suite`), `CoreServices` FSEvents C API, `AnglesiteCore` actors.

## Global Constraints

- ES/Swift: targets macOS 27+; Swift 6 strict concurrency — all shared types are `Sendable` (reference types wrapping C state are `@unchecked Sendable` with explicit locking).
- No third-party dependencies — Apple frameworks only (`Foundation`, `CoreServices`).
- Tests are Swift Testing (`import Testing`, `@Suite`, `@Test`), not XCTest.
- Process spawning stays in `ProcessSupervisor` — this feature spawns no processes (FSEvents is in-process).
- FSEvents start failure must be non-fatal: log via `LogCenter`, leave the runtime `.ready`.
- The index is unchanged except for sharing its skip-dir set; do not alter `SiteKnowledgeIndex`'s public API.
- `swift test` requires `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` (default CommandLineTools swift is too old). Prefix every `swift test` command with it.

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/AnglesiteCore/SiteFileWatcher.swift` | **new** — `SiteIndexPaths` (shared skip-dir set + path helpers), `FileChangeBatch`, `SiteFileWatching` protocol, `KnowledgeReindex.apply` free function, `FSEventsFileWatcher` real impl |
| `Sources/AnglesiteCore/SiteKnowledgeIndex.swift` | **modify** — reference `SiteIndexPaths.skippedDirectoryNames` instead of the private set |
| `Sources/AnglesiteCore/LocalSiteRuntime.swift` | **modify** — own/start/stop a watcher; apply batches under the generation guard |
| `Sources/AnglesiteCore/LocalContainerSiteRuntime.swift` | **modify** — identical watcher wiring |
| `Tests/AnglesiteCoreTests/IncrementalReindexTests.swift` | **new** — `KnowledgeReindex.apply` + `SiteIndexPaths` unit tests (deterministic, no real FS) |
| `Tests/AnglesiteCoreTests/SiteFileWatcherTests.swift` | **new** — tolerant real-`FSEventsFileWatcher` integration test |
| `Tests/AnglesiteCoreTests/LocalSiteRuntimeReindexTests.swift` | **new** — runtime starts the watcher after rebuild and routes batches to the index |

---

## Task 1: Shared path helpers, change batch, protocol, and the reindex applier

The deterministic core. No FSEvents yet — this is the translation logic plus shared helpers, fully unit-testable against a real `SiteKnowledgeIndex` and temp files.

**Files:**
- Create: `Sources/AnglesiteCore/SiteFileWatcher.swift`
- Modify: `Sources/AnglesiteCore/SiteKnowledgeIndex.swift:191-193` (skip set), `:201` (use shared predicate)
- Test: `Tests/AnglesiteCoreTests/IncrementalReindexTests.swift`

**Interfaces:**
- Produces:
  - `enum SiteIndexPaths { static let skippedDirectoryNames: Set<String>; static func isSkipped(relativePath: String) -> Bool; static func relativePOSIXPath(of url: URL, under root: URL) -> String? }`
  - `struct FileChangeBatch: Sendable, Equatable { let paths: [URL]; let needsFullRescan: Bool; init(paths:[URL], needsFullRescan:Bool) }`
  - `protocol SiteFileWatching: Sendable { func start(root: URL, onBatch: @escaping @Sendable (FileChangeBatch) -> Void) throws; func stop() }`
  - `enum KnowledgeReindex { static func apply(_ batch: FileChangeBatch, to index: SiteKnowledgeIndex, siteID: String, projectRoot: URL, fileExists: @Sendable (URL) -> Bool) async }`

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/IncrementalReindexTests.swift`:

```swift
import Foundation
import Testing
@testable import AnglesiteCore

@Suite("IncrementalReindex")
struct IncrementalReindexTests {
    /// Create a temp site `Source/` dir; `files` maps relative path → contents.
    private func makeSite(_ files: [String: String] = [:]) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("reindex-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (rel, contents) in files {
            let url = root.appendingPathComponent(rel)
            try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! Data(contents.utf8).write(to: url)
        }
        return root
    }

    private let exists: @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }

    @Test("relativePOSIXPath returns nil for paths outside the root")
    func relativePathOutsideRoot() {
        let root = URL(fileURLWithPath: "/tmp/site", isDirectory: true)
        #expect(SiteIndexPaths.relativePOSIXPath(of: URL(fileURLWithPath: "/tmp/site/src/x.astro"), under: root) == "src/x.astro")
        #expect(SiteIndexPaths.relativePOSIXPath(of: URL(fileURLWithPath: "/etc/passwd"), under: root) == nil)
    }

    @Test("isSkipped matches build/dependency directories")
    func skippedDirs() {
        #expect(SiteIndexPaths.isSkipped(relativePath: "node_modules/pkg/index.js"))
        #expect(SiteIndexPaths.isSkipped(relativePath: "dist/index.html"))
        #expect(SiteIndexPaths.isSkipped(relativePath: ".git/HEAD"))
        #expect(!SiteIndexPaths.isSkipped(relativePath: "src/pages/index.astro"))
    }

    @Test("apply upserts a newly created file into the index")
    func applyUpsertsNewFile() async {
        let root = makeSite(["src/pages/index.astro": "---\ntitle: Home\n---\n# Home"])
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "s", projectRoot: root)
        #expect(await index.documents(siteID: "s").contains { $0.path == "src/pages/about.astro" } == false)

        let added = root.appendingPathComponent("src/pages/about.astro")
        try! Data("---\ntitle: About\n---\n# About".utf8).write(to: added)
        await KnowledgeReindex.apply(.init(paths: [added], needsFullRescan: false),
                                     to: index, siteID: "s", projectRoot: root, fileExists: exists)

        #expect(await index.documents(siteID: "s").contains { $0.path == "src/pages/about.astro" })
    }

    @Test("apply removes a deleted file from the index")
    func applyRemovesDeletedFile() async {
        let root = makeSite(["src/pages/gone.astro": "---\ntitle: Gone\n---\nbody"])
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "s", projectRoot: root)
        #expect(await index.documents(siteID: "s").contains { $0.path == "src/pages/gone.astro" })

        let gone = root.appendingPathComponent("src/pages/gone.astro")
        await KnowledgeReindex.apply(.init(paths: [gone], needsFullRescan: false),
                                     to: index, siteID: "s", projectRoot: root, fileExists: { _ in false })

        #expect(await index.documents(siteID: "s").contains { $0.path == "src/pages/gone.astro" } == false)
    }

    @Test("apply ignores skipped-directory paths")
    func applyIgnoresSkippedDirs() async {
        let root = makeSite(["src/pages/index.astro": "---\ntitle: Home\n---\n# Home"])
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "s", projectRoot: root)
        let before = await index.documents(siteID: "s").count

        let noise = root.appendingPathComponent("node_modules/pkg/index.js")
        try! FileManager.default.createDirectory(at: noise.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data("module.exports = {}".utf8).write(to: noise)
        await KnowledgeReindex.apply(.init(paths: [noise], needsFullRescan: false),
                                     to: index, siteID: "s", projectRoot: root, fileExists: exists)

        #expect(await index.documents(siteID: "s").count == before)
    }

    @Test("apply with needsFullRescan rebuilds and picks up files absent from the batch")
    func applyFullRescan() async {
        let root = makeSite(["src/pages/index.astro": "---\ntitle: Home\n---\n# Home"])
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "s", projectRoot: root)

        // A file added on disk but NOT named in the batch — only a full rebuild finds it.
        let surprise = root.appendingPathComponent("src/pages/surprise.astro")
        try! Data("---\ntitle: Surprise\n---\nbody".utf8).write(to: surprise)
        await KnowledgeReindex.apply(.init(paths: [], needsFullRescan: true),
                                     to: index, siteID: "s", projectRoot: root, fileExists: exists)

        #expect(await index.documents(siteID: "s").contains { $0.path == "src/pages/surprise.astro" })
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter IncrementalReindex`
Expected: FAIL to compile — `SiteIndexPaths`, `FileChangeBatch`, `KnowledgeReindex` are not defined.

- [ ] **Step 3: Create `SiteFileWatcher.swift` with the core types (no FSEvents impl yet)**

Create `Sources/AnglesiteCore/SiteFileWatcher.swift`:

```swift
import Foundation

/// Shared rules for which project paths the knowledge index cares about. Lifted out of
/// `SiteKnowledgeIndex` so the file watcher and the index agree on what to skip.
public enum SiteIndexPaths {
    /// Build artifacts and dependency directories the index never reads.
    public static let skippedDirectoryNames: Set<String> = [
        ".astro", ".git", ".netlify", ".vercel", "dist", "node_modules",
    ]

    /// True when any path component is a skipped directory (e.g. `node_modules/...`, `dist/...`).
    public static func isSkipped(relativePath: String) -> Bool {
        relativePath.split(separator: "/").contains { skippedDirectoryNames.contains(String($0)) }
    }

    /// POSIX path of `url` relative to `root`, or `nil` if `url` is not under `root`. Unlike the
    /// index's internal helper, an out-of-tree path yields `nil` (the watcher drops it) rather
    /// than falling back to the absolute path.
    public static func relativePOSIXPath(of url: URL, under root: URL) -> String? {
        let urlComponents = url.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        guard urlComponents.starts(with: rootComponents), urlComponents.count > rootComponents.count else { return nil }
        return urlComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }
}

/// A debounced batch of filesystem changes under a watched root.
public struct FileChangeBatch: Sendable, Equatable {
    /// Absolute URLs the watcher reported as changed in this batch.
    public let paths: [URL]
    /// The watcher dropped per-file granularity (coalesced bulk event, root moved, or
    /// mount/unmount). Consumers should fall back to a full rebuild rather than per-file updates.
    public let needsFullRescan: Bool

    public init(paths: [URL], needsFullRescan: Bool) {
        self.paths = paths
        self.needsFullRescan = needsFullRescan
    }
}

/// Watches a directory tree and delivers debounced change batches. The seam tests inject against.
public protocol SiteFileWatching: Sendable {
    /// Begin watching `root`, delivering batches to `onBatch` until `stop()`. Throws if the
    /// underlying watch cannot be established.
    func start(root: URL, onBatch: @escaping @Sendable (FileChangeBatch) -> Void) throws
    func stop()
}

/// Translates a `FileChangeBatch` into `SiteKnowledgeIndex` mutations. Kept free-standing (not on
/// the runtime actor) so it is unit-testable without spinning a runtime.
public enum KnowledgeReindex {
    public static func apply(
        _ batch: FileChangeBatch,
        to index: SiteKnowledgeIndex,
        siteID: String,
        projectRoot: URL,
        fileExists: @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) async {
        if batch.needsFullRescan {
            await index.rebuild(siteID: siteID, projectRoot: projectRoot)
            return
        }
        for url in batch.paths {
            guard let relativePath = SiteIndexPaths.relativePOSIXPath(of: url, under: projectRoot),
                  !SiteIndexPaths.isSkipped(relativePath: relativePath)
            else { continue }
            if fileExists(url) {
                await index.upsertFile(siteID: siteID, projectRoot: projectRoot, relativePath: relativePath)
            } else {
                await index.removeFile(siteID: siteID, relativePath: relativePath)
            }
        }
    }
}
```

- [ ] **Step 4: Point `SiteKnowledgeIndex` at the shared skip set**

In `Sources/AnglesiteCore/SiteKnowledgeIndex.swift`, replace the private set (lines 191-193):

```swift
    private static let skippedDirectoryNames: Set<String> = [
        ".astro", ".git", ".netlify", ".vercel", "dist", "node_modules"
    ]
```

with a reference to the shared one:

```swift
    private static let skippedDirectoryNames = SiteIndexPaths.skippedDirectoryNames
```

Leave `shouldIndex` and `walk` as-is — they keep reading `Self.skippedDirectoryNames`, now sourced from `SiteIndexPaths`.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter IncrementalReindex`
Expected: PASS (6 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/SiteFileWatcher.swift Sources/AnglesiteCore/SiteKnowledgeIndex.swift Tests/AnglesiteCoreTests/IncrementalReindexTests.swift
git commit -m "feat(#307): reindex applier + shared site-path helpers"
```

---

## Task 2: Real `FSEventsFileWatcher`

The production `SiteFileWatching` impl wrapping the CoreServices FSEvents C API.

**Files:**
- Modify: `Sources/AnglesiteCore/SiteFileWatcher.swift` (append the class)
- Test: `Tests/AnglesiteCoreTests/SiteFileWatcherTests.swift`

**Interfaces:**
- Consumes: `SiteFileWatching`, `FileChangeBatch` (Task 1).
- Produces: `final class FSEventsFileWatcher: SiteFileWatching, @unchecked Sendable { public init() }`.

- [ ] **Step 1: Write the failing test**

Create `Tests/AnglesiteCoreTests/SiteFileWatcherTests.swift`:

```swift
import Foundation
import Testing
@testable import AnglesiteCore

@Suite("FSEventsFileWatcher")
struct SiteFileWatcherTests {
    /// Poll `condition` until true or `timeout` elapses. FSEvents is asynchronous, so we wait
    /// rather than assert immediately. Returns whether the condition was met.
    private func poll(timeout: TimeInterval, _ condition: @Sendable () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
        return condition()
    }

    @Test("watcher reports a file write under the watched root", .timeLimit(.minutes(1)))
    func reportsFileWrite() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fswatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Collect changed paths the watcher reports, guarded by a lock (callback runs off-thread).
        final class Box: @unchecked Sendable { let lock = NSLock(); var seen: Set<String> = [] }
        let box = Box()
        let watcher = FSEventsFileWatcher()
        try watcher.start(root: root) { batch in
            box.lock.lock(); defer { box.lock.unlock() }
            for url in batch.paths { box.seen.insert(url.standardizedFileURL.lastPathComponent) }
        }
        defer { watcher.stop() }

        // Give the stream a beat to arm, then write a file.
        try? await Task.sleep(nanoseconds: 300_000_000)
        let target = root.appendingPathComponent("hello.astro")
        try Data("hi".utf8).write(to: target)

        let saw = await poll(timeout: 10) {
            box.lock.lock(); defer { box.lock.unlock() }
            return box.seen.contains("hello.astro")
        }
        #expect(saw)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter FSEventsFileWatcher`
Expected: FAIL to compile — `FSEventsFileWatcher` is not defined.

- [ ] **Step 3: Implement `FSEventsFileWatcher`**

Append to `Sources/AnglesiteCore/SiteFileWatcher.swift`. Add `import CoreServices` at the top of the file (below `import Foundation`):

```swift
/// Production `SiteFileWatching` backed by the CoreServices FSEvents API. Coalescing latency
/// (0.3s) doubles as the debounce, so no separate timer is needed. State (`stream`, `onBatch`)
/// is guarded by `lock` because the FSEvents callback fires on `queue` while `start`/`stop` are
/// called from the owning actor.
public final class FSEventsFileWatcher: SiteFileWatching, @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.dwk.anglesite.fswatcher")
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var onBatch: (@Sendable (FileChangeBatch) -> Void)?

    public init() {}

    public enum WatchError: Error { case streamCreationFailed }

    public func start(root: URL, onBatch: @escaping @Sendable (FileChangeBatch) -> Void) throws {
        lock.lock()
        self.onBatch = onBatch
        lock.unlock()

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagUseCFTypes
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSEventsFileWatcher>.fromOpaque(info).takeUnretainedValue()
            // UseCFTypes => eventPaths is a CFArray of CFString.
            let paths = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
            var urls: [URL] = []
            var needsRescan = false
            let rescanMask = FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagRootChanged
                | kFSEventStreamEventFlagMount
                | kFSEventStreamEventFlagUnmount
            )
            for i in 0..<count {
                if eventFlags[i] & rescanMask != 0 { needsRescan = true }
                if i < paths.count { urls.append(URL(fileURLWithPath: paths[i])) }
            }
            watcher.lock.lock()
            let handler = watcher.onBatch
            watcher.lock.unlock()
            handler?(FileChangeBatch(paths: urls, needsFullRescan: needsRescan))
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3, flags
        ) else {
            lock.lock(); onBatch = nil; lock.unlock()
            throw WatchError.streamCreationFailed
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        lock.lock(); self.stream = stream; lock.unlock()
    }

    public func stop() {
        lock.lock()
        let s = stream
        stream = nil
        onBatch = nil
        lock.unlock()
        if let s {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter FSEventsFileWatcher`
Expected: PASS (1 test). If it is flaky under load, the 10s poll is the knob — but it should pass comfortably locally.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SiteFileWatcher.swift Tests/AnglesiteCoreTests/SiteFileWatcherTests.swift
git commit -m "feat(#307): FSEvents-backed SiteFileWatcher"
```

---

## Task 3: Wire the watcher into `LocalSiteRuntime`

Start the watcher after the open-time index rebuild; stop it on teardown; route batches through `KnowledgeReindex.apply` under the generation guard.

**Files:**
- Modify: `Sources/AnglesiteCore/LocalSiteRuntime.swift` (init param, stored props, `populateSharedIndexes`, `stopSubprocesses`, new `applyFileChanges`)
- Test: `Tests/AnglesiteCoreTests/LocalSiteRuntimeReindexTests.swift`

**Interfaces:**
- Consumes: `SiteFileWatching`, `FileChangeBatch`, `KnowledgeReindex` (Tasks 1-2).
- Produces: `LocalSiteRuntime.init(..., makeFileWatcher: @escaping @Sendable () -> any SiteFileWatching = { FSEventsFileWatcher() })`.

- [ ] **Step 1: Write the failing test**

Create `Tests/AnglesiteCoreTests/LocalSiteRuntimeReindexTests.swift`. It uses a controllable mock watcher and an `sh` fixture dev server (mirroring `LocalSiteRuntimeGraphTests`), drives a full `start()`, then delivers a synthetic batch and asserts the index updates.

```swift
import Testing
import Foundation
@testable import AnglesiteCore

/// A `SiteFileWatching` the test can poke: it captures the batch handler and the watched root,
/// and records start/stop so the runtime wiring can be asserted.
final class ControllableWatcher: SiteFileWatching, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (FileChangeBatch) -> Void)?
    private(set) var startedRoot: URL?
    private(set) var stopCount = 0

    func start(root: URL, onBatch: @escaping @Sendable (FileChangeBatch) -> Void) throws {
        lock.lock(); startedRoot = root; handler = onBatch; lock.unlock()
    }
    func stop() { lock.lock(); stopCount += 1; handler = nil; lock.unlock() }
    var didStart: Bool { lock.lock(); defer { lock.unlock() }; return startedRoot != nil }
    func deliver(_ batch: FileChangeBatch) {
        lock.lock(); let h = handler; lock.unlock(); h?(batch)
    }
}

@Suite(.serialized)  // serial subprocess spawns — see MCPClientTests rationale
struct LocalSiteRuntimeReindexTests {
    private let alwaysReady: AstroDevServer.ReadinessProbe = { _ in true }

    private func makeSite(_ files: [String: String]) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-reindex-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (rel, contents) in files {
            let url = root.appendingPathComponent(rel)
            try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! Data(contents.utf8).write(to: url)
        }
        return root
    }

    /// Wait until `condition` holds or `timeout` elapses (state settles across actor hops).
    private func poll(_ timeout: TimeInterval, _ condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await condition()
    }

    @Test("runtime starts the watcher after rebuild and routes a batch to the index")
    func routesBatchToIndex() async {
        let root = makeSite(["src/pages/index.astro": "---\ntitle: Home\n---\n# Home"])
        let index = SiteKnowledgeIndex()
        let watcher = ControllableWatcher()
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let devServer = AstroDevServer(supervisor: supervisor, logCenter: center, readinessProbe: alwaysReady)
        let runtime = LocalSiteRuntime(
            devServer: devServer,
            knowledgeIndex: index,
            logCenter: center,
            resolveCommand: { _ in .run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 30"]) },
            resolveMCPCommand: { .unavailable(reason: "test: no MCP") },
            makeFileWatcher: { watcher }
        )

        await runtime.start(siteID: "s", siteDirectory: root)
        #expect(await poll(5) { @Sendable in watcher.didStart })
        #expect(watcher.startedRoot?.standardizedFileURL == root.standardizedFileURL)

        // Add a file on disk, then deliver the change through the watcher seam.
        let added = root.appendingPathComponent("src/pages/about.astro")
        try! Data("---\ntitle: About\n---\n# About".utf8).write(to: added)
        watcher.deliver(.init(paths: [added], needsFullRescan: false))

        #expect(await poll(5) { await index.documents(siteID: "s").contains { $0.path == "src/pages/about.astro" } })

        await runtime.stop()
        #expect(watcher.stopCount >= 1)
    }
}
```

> Note: confirm the `LocalSiteRuntime.init` argument order against the source when wiring this call; the test names every argument so order changes won't silently break it.

- [ ] **Step 2: Run the test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter LocalSiteRuntimeReindex`
Expected: FAIL to compile — `LocalSiteRuntime.init` has no `makeFileWatcher:` parameter.

- [ ] **Step 3: Add the watcher to `LocalSiteRuntime`**

In `Sources/AnglesiteCore/LocalSiteRuntime.swift`:

(a) Add stored properties next to `knowledgeIndex` (~line 41):

```swift
    /// Factory for the per-site filesystem watcher that keeps the knowledge index fresh while the
    /// site is open (#307). Injectable so tests drive synthetic change batches.
    private let makeFileWatcher: @Sendable () -> any SiteFileWatching
    /// The active watcher for the currently-loaded site, or `nil` when none is loaded.
    private var fileWatcher: (any SiteFileWatching)?
```

(b) Add the init parameter (with a default so existing callers are unaffected) and assign it. Add to the parameter list, e.g. after `knowledgeIndex`:

```swift
        makeFileWatcher: @escaping @Sendable () -> any SiteFileWatching = { FSEventsFileWatcher() },
```

and in the body:

```swift
        self.makeFileWatcher = makeFileWatcher
```

(c) At the end of `populateSharedIndexes`, after `loadedSharedIndexSiteID = siteID`, start the watcher:

```swift
        loadedSharedIndexSiteID = siteID
        startFileWatcher(siteID: siteID, projectRoot: siteDirectory, generation: gen)
```

(d) Add the watcher lifecycle + batch application methods (place near `populateSharedIndexes`):

```swift
    /// Begin watching the site's `Source/` directory; route changes into the knowledge index.
    /// Best-effort: a watcher that fails to start is logged and the runtime stays `.ready`.
    private func startFileWatcher(siteID: String, projectRoot: URL, generation gen: Int) {
        guard knowledgeIndex != nil else { return }
        let watcher = makeFileWatcher()
        do {
            try watcher.start(root: projectRoot) { [weak self] batch in
                Task { await self?.applyFileChanges(batch, siteID: siteID, projectRoot: projectRoot, generation: gen) }
            }
            fileWatcher = watcher
        } catch {
            Task { await logCenter.append(source: "reindex:\(siteID)", stream: .stderr,
                                          text: "file watcher unavailable: \(error)") }
        }
    }

    private func stopFileWatcher() {
        fileWatcher?.stop()
        fileWatcher = nil
    }

    /// Apply a debounced change batch to the knowledge index, unless a newer `start()`/`stop()`
    /// has superseded the watcher that produced it.
    private func applyFileChanges(_ batch: FileChangeBatch, siteID: String, projectRoot: URL, generation gen: Int) async {
        guard gen == generation, let knowledgeIndex else { return }
        await KnowledgeReindex.apply(batch, to: knowledgeIndex, siteID: siteID, projectRoot: projectRoot)
    }
```

(e) In `stopSubprocesses`, stop the watcher alongside the unload:

```swift
    private func stopSubprocesses() async {
        await devServer.stop()
        await mcpClient.stop()
        stopFileWatcher()
        if let siteID = loadedSharedIndexSiteID {
            await contentGraph?.unload(siteID: siteID)
            await knowledgeIndex?.unload(siteID: siteID)
            loadedSharedIndexSiteID = nil
        }
    }
```

> `LogCenter.append(source:stream:text:timestamp:)` is actor-isolated — call it `await` inside a `Task` as shown. `startMCPClient` nearby uses the same call.

- [ ] **Step 4: Run the test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter LocalSiteRuntimeReindex`
Expected: PASS (1 test).

- [ ] **Step 5: Run the existing runtime suites to confirm no regression**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter LocalSiteRuntime`
Expected: PASS (existing `LocalSiteRuntimeTests` + `LocalSiteRuntimeGraphTests` + new suite).

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/LocalSiteRuntime.swift Tests/AnglesiteCoreTests/LocalSiteRuntimeReindexTests.swift
git commit -m "feat(#307): wire incremental reindex into LocalSiteRuntime"
```

---

## Task 4: Wire the watcher into `LocalContainerSiteRuntime`

Identical lifecycle against the container runtime, which also indexes the host `Source/` directory.

**Files:**
- Modify: `Sources/AnglesiteCore/LocalContainerSiteRuntime.swift` (init param, stored props, `start`, `teardown`, `applyFileChanges`)

**Interfaces:**
- Consumes: `SiteFileWatching`, `KnowledgeReindex` (Tasks 1-2), the `LocalSiteRuntime` wiring shape (Task 3).
- Produces: `LocalContainerSiteRuntime.init(..., makeFileWatcher: @escaping @Sendable () -> any SiteFileWatching = { FSEventsFileWatcher() })`.

- [ ] **Step 1: Add the watcher to `LocalContainerSiteRuntime`**

In `Sources/AnglesiteCore/LocalContainerSiteRuntime.swift`:

(a) Stored properties next to `knowledgeIndex` (~line 12):

```swift
    private let makeFileWatcher: @Sendable () -> any SiteFileWatching
    private var fileWatcher: (any SiteFileWatching)?
```

(b) Init parameter (default-valued) + assignment, mirroring Task 3(b).

```swift
        makeFileWatcher: @escaping @Sendable () -> any SiteFileWatching = { FSEventsFileWatcher() },
```
```swift
        self.makeFileWatcher = makeFileWatcher
```

(c) In `start(siteID:siteDirectory:)`, after `loadedKnowledgeSiteID = siteID`, start the watcher (the local `gen` is already in scope):

```swift
            loadedKnowledgeSiteID = siteID
            startFileWatcher(siteID: siteID, projectRoot: siteDirectory, generation: gen)
```

(d) Add the same three private methods as Task 3(d) — `startFileWatcher`, `stopFileWatcher`, `applyFileChanges` — adapted to this type's `generation` property and `logCenter` (use the same logging the file already uses; if this type has no `logCenter`, drop the `catch` log to a silent best-effort `try?` start instead):

```swift
    private func startFileWatcher(siteID: String, projectRoot: URL, generation gen: Int) {
        guard knowledgeIndex != nil else { return }
        let watcher = makeFileWatcher()
        do {
            try watcher.start(root: projectRoot) { [weak self] batch in
                Task { await self?.applyFileChanges(batch, siteID: siteID, projectRoot: projectRoot, generation: gen) }
            }
            fileWatcher = watcher
        } catch {
            // Best-effort: stale index is acceptable; the container reindexes on next open.
        }
    }

    private func stopFileWatcher() {
        fileWatcher?.stop()
        fileWatcher = nil
    }

    private func applyFileChanges(_ batch: FileChangeBatch, siteID: String, projectRoot: URL, generation gen: Int) async {
        guard gen == generation, let knowledgeIndex else { return }
        await KnowledgeReindex.apply(batch, to: knowledgeIndex, siteID: siteID, projectRoot: projectRoot)
    }
```

(e) In `teardown()`, stop the watcher before the unload:

```swift
    private func teardown() async {
        await mcpClient.stop()
        stopFileWatcher()
        if let siteID = loadedKnowledgeSiteID {
            await knowledgeIndex?.unload(siteID: siteID)
            loadedKnowledgeSiteID = nil
        }
        if let id = activeSiteID {
            try? await control.stop(siteID: id)
            activeSiteID = nil
        }
    }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build --package-path .`
Expected: builds clean.

- [ ] **Step 3: Run the container runtime suite**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter LocalContainerSiteRuntime`
Expected: PASS (existing `LocalContainerSiteRuntimeTests`, unaffected by the default-valued new parameter).

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteCore/LocalContainerSiteRuntime.swift
git commit -m "feat(#307): wire incremental reindex into LocalContainerSiteRuntime"
```

---

## Task 5: Full-suite verification

**Files:** none (verification only).

- [ ] **Step 1: Run the full `AnglesiteCore` test suite**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .`
Expected: all suites PASS, including the three new suites (`IncrementalReindex`, `FSEventsFileWatcher`, `LocalSiteRuntimeReindex`) and the unchanged `SiteKnowledgeIndex`/runtime suites.

- [ ] **Step 2: Confirm no stray diff**

Run: `git status --short` and `git --no-pager diff --stat main...HEAD`
Expected: only the files listed in the File Structure table changed.

---

## Self-Review notes

- **Spec coverage:** FS-watcher trigger (Task 2), host `Source/` for both runtimes (Tasks 3-4), `upsertFile`/`removeFile`/`needsFullRescan→rebuild` translation (Task 1), skip-dir pre-filter via shared predicate (Task 1), generation guard (Tasks 3-4), best-effort start with `LogCenter` (Task 3), MAS sandbox (no extra entitlement — no code), mock + tolerant-real + runtime-wiring tests (Tasks 1-3). `SiteContentGraph` freshness and semantic retrieval remain non-goals (untouched).
- **Type consistency:** `makeFileWatcher: @Sendable () -> any SiteFileWatching`, `applyFileChanges(_:siteID:projectRoot:generation:)`, `KnowledgeReindex.apply(_:to:siteID:projectRoot:fileExists:)`, and `FileChangeBatch(paths:needsFullRescan:)` are used identically across Tasks 1, 3, and 4.
- **Verified against source:** `LogCenter.append(source:stream:text:timestamp:)` (actor-isolated, `await`); `LocalContainerSiteRuntime` holds no `LogCenter`, so Task 4's watcher-start catch is a silent best-effort (no log). `LocalSiteRuntime.init` params are all default-valued and named at the call site, so adding `makeFileWatcher` last is non-breaking.
