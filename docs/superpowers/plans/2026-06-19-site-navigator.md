# Site Navigator Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an Xcode-Project-Navigator-style sidebar to each site window that lists the site as curated groups (Pages/Posts/Components/Styles/Metadata); selecting a page navigates the preview, selecting a non-page file opens it in an inline text editor.

**Architecture:** All decision/IO logic lands in `AnglesiteCore` as small, CI-testable units (a content-graph broadcast stream, a filesystem scanner, file IO + external-change reconcile, a navigator-tree builder, an editor-routing seam). The App target adds thin SwiftUI glue: a `@Observable` navigator model, the sidebar view, a text-editor pane, and a `NavigationSplitView` wrap of `SiteWindow` with a `MainPaneMode` (preview vs. editor).

**Tech Stack:** Swift 6.4 / SwiftUI (macOS 27+), Swift Testing (`import Testing`, `@Test`, `#expect`), `AnglesitePackage` (#242) for layout resolution.

## Global Constraints

- **ES/Swift module style:** `AnglesiteCore` is a library; no SwiftUI imports in Core files. Use `import Foundation` (+ `import Testing` in tests).
- **Swift toolchain:** `swift test` / `swift build` require `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` (the default CommandLineTools swift is too old). Prefix every `swift` command with it.
- **Test framework:** Swift Testing only for new tests (`struct …Tests { @Test … }`), matching `Tests/AnglesiteCoreTests/AnglesitePackageTests.swift`.
- **Source of truth is the filesystem.** The editor must never become the only writer: explicit save (⌘S), and an external-change guard that never silently clobbers on-disk edits made by chat/overlay/CLI.
- **Logs are sacred:** App-side failures (save errors) surface to the user and may also log, but never get swallowed silently.
- **Branch:** Work is on `feat/site-navigator` (based on `feat/242-anglesite-package-model`). Do not merge to `main` until #242 merges.
- **App-target logic is not CI-tested** (hosted app tests can't launch a macOS-27 `.app` on CI runners). Keep App glue thin; all testable logic lives in Core. App tasks verify via `xcodebuild … build` and a final manual smoke.

---

### Task 1: `SiteContentGraph.changeStream()` broadcast

The navigator needs live page/post updates, but `SiteContentGraph`'s single `changeHandler` is already taken by the Spotlight indexer. Add an additive multi-subscriber `AsyncStream<String>` (siteID per change), mirroring `SiteStore.changeStream()`. The existing handler is untouched.

**Files:**
- Modify: `Sources/AnglesiteCore/SiteContentGraph.swift`
- Test: `Tests/AnglesiteCoreTests/SiteContentGraphStreamTests.swift` (create)

**Interfaces:**
- Consumes: existing `SiteContentGraph` actor, `emitChange(_:)`.
- Produces: `func changeStream() -> AsyncStream<String>` (actor-isolated — callers `await`) — yields the affected `siteID` on every real mutation; no subscribe-time yield (a change is an event, not a snapshot).

> **Why actor-isolated (not `nonisolated` like `SiteStore.changeStream()`):** `SiteStore` yields a subscribe-time snapshot, so a caller that subscribes then mutates always gets *something* and never hangs. This stream deliberately has **no** subscribe-time yield, so registering the continuation in a detached `Task {}` (as a `nonisolated` factory must) races the caller's next mutation — if the emit lands before registration, `next()` suspends forever. Making `changeStream()` actor-isolated and registering the continuation **synchronously** (via `AsyncStream.makeStream`) before returning closes the race. Consumers (Task 6) therefore `await graph.changeStream()`.

- [ ] **Step 1: Write the failing test**

Create `Tests/AnglesiteCoreTests/SiteContentGraphStreamTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

struct SiteContentGraphStreamTests {
    private func makePage(_ siteID: String, route: String) -> SiteContentGraph.Page {
        SiteContentGraph.Page(
            id: "\(siteID):page:\(route)", siteID: siteID, route: route,
            filePath: "/tmp/\(route).astro", title: route, lastModified: Date(timeIntervalSince1970: 0))
    }

    @Test("changeStream yields the siteID on a real mutation")
    func yieldsOnMutation() async throws {
        let graph = SiteContentGraph()
        var iterator = (await graph.changeStream()).makeAsyncIterator()
        await graph.upsertPage(makePage("siteA", route: "/about/"))
        let received = await iterator.next()
        #expect(received == "siteA")
    }

    @Test("two independent subscribers both receive the change")
    func broadcastsToAll() async throws {
        let graph = SiteContentGraph()
        var it1 = (await graph.changeStream()).makeAsyncIterator()
        var it2 = (await graph.changeStream()).makeAsyncIterator()
        await graph.upsertPage(makePage("siteB", route: "/x/"))
        let a = await it1.next()
        let b = await it2.next()
        #expect(a == "siteB")
        #expect(b == "siteB")
    }

    @Test("an equal upsert does not emit (real-mutation only)")
    func noEmitOnEqualUpsert() async throws {
        let graph = SiteContentGraph()
        let page = makePage("siteC", route: "/y/")
        await graph.upsertPage(page)              // first insert emits
        var it = (await graph.changeStream()).makeAsyncIterator()
        await graph.upsertPage(page)              // equal → no emit
        await graph.upsertPage(makePage("siteC", route: "/z/")) // emits
        let received = await it.next()
        #expect(received == "siteC")              // the /z/ emit, not a phantom /y/ emit
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SiteContentGraphStreamTests`
Expected: FAIL — `value of type 'SiteContentGraph' has no member 'changeStream'`.

- [ ] **Step 3: Add the broadcast to `SiteContentGraph`**

In `Sources/AnglesiteCore/SiteContentGraph.swift`, add a continuations dictionary next to `changeHandler`:

```swift
    private var changeHandler: ChangeHandler?

    /// Additive multi-subscriber broadcast for UI observers (the Site Navigator), keyed by a
    /// per-subscription `UUID`. Distinct from `changeHandler` (the indexer's single awaited hook):
    /// these are fire-and-forget siteID feeds. Pruned via the stream's `onTermination`.
    private var changeStreamContinuations: [UUID: AsyncStream<String>.Continuation] = [:]
```

Extend `emitChange` to fan out to both (replace the existing `emitChange`):

```swift
    private func emitChange(_ siteID: String) async {
        if let handler = changeHandler { await handler(siteID) }
        for continuation in changeStreamContinuations.values {
            continuation.yield(siteID)
        }
    }
```

Add the stream factory + prune helper. Unlike `SiteStore.changeStream()` this is **actor-isolated**, so the continuation is registered synchronously before the call returns — no detached registration `Task`, no race (see the Interfaces note above):

```swift
    /// A multi-subscriber stream of affected siteIDs, one per real mutation. Actor-isolated so the
    /// continuation registers synchronously before this returns: there is no subscribe-time snapshot
    /// to mask a registration race, so a caller that subscribes then mutates must not miss the emit.
    /// (A content change is an event — the navigator reads the graph back itself on first load.)
    /// Callers `await` it.
    public func changeStream() -> AsyncStream<String> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: String.self, bufferingPolicy: .bufferingNewest(8))
        let id = UUID()
        changeStreamContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            // onTermination runs off-actor at an arbitrary time; hop back to prune.
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    private func removeContinuation(_ id: UUID) {
        changeStreamContinuations[id] = nil
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SiteContentGraphStreamTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SiteContentGraph.swift Tests/AnglesiteCoreTests/SiteContentGraphStreamTests.swift
git commit -m "feat(navigator): add multi-subscriber changeStream to SiteContentGraph"
```

---

### Task 2: `SiteFileTree` — layout resolution + filesystem scan

Scan the three filesystem-backed groups (Components/Styles/Metadata). Resolve roots adaptively: if the site is an `.anglesite` package use `Source/`+`Config/`; otherwise treat the site path itself as the project root (current pre-package reality).

**Files:**
- Create: `Sources/AnglesiteCore/SiteFileTree.swift`
- Test: `Tests/AnglesiteCoreTests/SiteFileTreeTests.swift`

**Interfaces:**
- Consumes: `AnglesitePackage.isPackage(at:fileManager:)`, `AnglesitePackage(url:).sourceURL/configURL/infoPlistURL`.
- Produces:
  - `enum FileGroup: String, Sendable, CaseIterable { case pages, posts, components, styles, metadata }`
  - `struct FileRef: Sendable, Equatable, Identifiable { var id: String; let url: URL; let group: FileGroup; let name: String }`
  - `enum SiteFileTree` with `static func layout(for:fileManager:) -> Layout` and `static func scan(siteRoot:fileManager:) -> [FileGroup: [FileRef]]`
  - `struct SiteFileTree.Layout: Sendable, Equatable { let sourceDir: URL; let configDir: URL?; let infoPlist: URL? }`

- [ ] **Step 1: Write the failing test**

Create `Tests/AnglesiteCoreTests/SiteFileTreeTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

struct SiteFileTreeTests {
    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("anglesite-filetree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ relative: String, under root: URL) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    @Test("plain (non-package) site resolves layout to the site root, no config")
    func plainLayout() throws {
        let root = try makeTempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let layout = SiteFileTree.layout(for: root)
        #expect(layout.sourceDir == root)
        #expect(layout.configDir == nil)
        #expect(layout.infoPlist == nil)
    }

    @Test("package site resolves layout to Source/ and Config/")
    func packageLayout() throws {
        let parent = try makeTempDir(); defer { try? FileManager.default.removeItem(at: parent) }
        let pkgURL = parent.appendingPathComponent("Acme.anglesite", isDirectory: true)
        let pkg = AnglesitePackage(url: pkgURL)
        try FileManager.default.createDirectory(at: pkg.sourceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pkg.configURL, withIntermediateDirectories: true)
        try pkg.writeMarker(AnglesitePackage.Marker(siteID: UUID(), displayName: "Acme", createdDate: Date(timeIntervalSince1970: 0)))

        let layout = SiteFileTree.layout(for: pkgURL)
        #expect(layout.sourceDir == pkg.sourceURL)
        #expect(layout.configDir == pkg.configURL)
        #expect(layout.infoPlist == pkg.infoPlistURL)
    }

    @Test("scan groups components, styles, and metadata; excludes plumbing")
    func scanGroups() throws {
        let root = try makeTempDir(); defer { try? FileManager.default.removeItem(at: root) }
        try write("src/layouts/BaseLayout.astro", under: root)
        try write("src/components/Card.astro", under: root)
        try write("src/styles/global.css", under: root)
        try write("src/pages/index.astro", under: root)        // pages handled elsewhere — NOT in scan
        try write("node_modules/pkg/index.js", under: root)    // plumbing — excluded
        try write("dist/index.html", under: root)              // build output — excluded

        let groups = SiteFileTree.scan(siteRoot: root)
        let componentNames = (groups[.components] ?? []).map(\.name).sorted()
        let styleNames = (groups[.styles] ?? []).map(\.name).sorted()
        #expect(componentNames == ["BaseLayout.astro", "Card.astro"])
        #expect(styleNames == ["global.css"])
        #expect(groups[.pages] == nil)   // pages are content-graph sourced, never filesystem-scanned
        let allURLs = groups.values.flatMap { $0 }.map(\.url.path)
        #expect(!allURLs.contains { $0.contains("node_modules") })
        #expect(!allURLs.contains { $0.contains("/dist/") })
    }

    @Test("empty groups are absent from the result")
    func emptyGroupsAbsent() throws {
        let root = try makeTempDir(); defer { try? FileManager.default.removeItem(at: root) }
        try write("src/styles/only.css", under: root)
        let groups = SiteFileTree.scan(siteRoot: root)
        #expect(groups[.styles]?.count == 1)
        #expect(groups[.components] == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SiteFileTreeTests`
Expected: FAIL — `cannot find 'SiteFileTree' in scope`.

- [ ] **Step 3: Implement `SiteFileTree`**

Create `Sources/AnglesiteCore/SiteFileTree.swift`:

```swift
import Foundation

/// Curated, group-oriented view of a site's filesystem-backed parts for the Site Navigator.
/// Pages/Posts are sourced from `SiteContentGraph`, not here — this scanner covers only the
/// Components, Styles, and Metadata groups.
///
/// Roots are resolved adaptively: an `.anglesite` package (#242) exposes `Source/` and `Config/`;
/// a plain directory (the current pre-package layout) is treated as the project root directly.
public enum FileGroup: String, Sendable, CaseIterable {
    case pages, posts, components, styles, metadata
}

public struct FileRef: Sendable, Equatable, Identifiable {
    public var id: String { url.path }
    public let url: URL
    public let group: FileGroup
    public let name: String

    public init(url: URL, group: FileGroup, name: String) {
        self.url = url
        self.group = group
        self.name = name
    }
}

public enum SiteFileTree {
    public struct Layout: Sendable, Equatable {
        public let sourceDir: URL
        public let configDir: URL?
        public let infoPlist: URL?
    }

    /// Directory names never descended into or listed.
    private static let excludedDirNames: Set<String> = ["node_modules", "dist", ".astro", ".git"]
    private static let excludedFileNames: Set<String> = [".DS_Store"]

    public static func layout(for siteRoot: URL, fileManager: FileManager = .default) -> Layout {
        if AnglesitePackage.isPackage(at: siteRoot, fileManager: fileManager) {
            let pkg = AnglesitePackage(url: siteRoot)
            return Layout(sourceDir: pkg.sourceURL, configDir: pkg.configURL, infoPlist: pkg.infoPlistURL)
        }
        return Layout(sourceDir: siteRoot, configDir: nil, infoPlist: nil)
    }

    public static func scan(siteRoot: URL, fileManager: FileManager = .default) -> [FileGroup: [FileRef]] {
        let layout = layout(for: siteRoot, fileManager: fileManager)
        var result: [FileGroup: [FileRef]] = [:]

        // Components: layouts + components dirs under src/.
        let componentDirs = ["src/layouts", "src/components"].map { layout.sourceDir.appendingPathComponent($0) }
        let components = componentDirs.flatMap { files(in: $0, group: .components, fileManager: fileManager) }
        if !components.isEmpty { result[.components] = components.sorted { $0.name < $1.name } }

        // Styles: src/styles.
        let styles = files(in: layout.sourceDir.appendingPathComponent("src/styles"),
                           group: .styles, fileManager: fileManager)
        if !styles.isEmpty { result[.styles] = styles.sorted { $0.name < $1.name } }

        // Metadata: everything in Config/ plus the package Info.plist marker.
        var metadata: [FileRef] = []
        if let configDir = layout.configDir {
            metadata += files(in: configDir, group: .metadata, fileManager: fileManager)
        }
        if let infoPlist = layout.infoPlist, fileManager.fileExists(atPath: infoPlist.path) {
            metadata.append(FileRef(url: infoPlist, group: .metadata, name: infoPlist.lastPathComponent))
        }
        if !metadata.isEmpty { result[.metadata] = metadata.sorted { $0.name < $1.name } }

        return result
    }

    /// Recursively lists files under `dir`, skipping excluded dirs/files. Returns [] if `dir` is absent.
    private static func files(in dir: URL, group: FileGroup, fileManager: FileManager) -> [FileRef] {
        guard let enumerator = fileManager.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var refs: [FileRef] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                if excludedDirNames.contains(name) { enumerator.skipDescendants() }
                continue
            }
            if excludedFileNames.contains(name) { continue }
            refs.append(FileRef(url: url, group: group, name: name))
        }
        return refs
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SiteFileTreeTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SiteFileTree.swift Tests/AnglesiteCoreTests/SiteFileTreeTests.swift
git commit -m "feat(navigator): SiteFileTree layout resolution + grouped filesystem scan"
```

---

### Task 3: `FileDocumentIO` — load / save / external-change reconcile

Pure file IO + the external-change decision the editor needs. Statics so they're trivially testable; the App view owns the buffer state.

**Files:**
- Create: `Sources/AnglesiteCore/FileDocumentIO.swift`
- Test: `Tests/AnglesiteCoreTests/FileDocumentIOTests.swift`

**Interfaces:**
- Produces:
  - `struct FileDocumentIO.Loaded: Sendable, Equatable { let contents: String; let modificationDate: Date? }`
  - `enum FileDocumentIO.ExternalChange: Sendable, Equatable { case none; case reloadable(String); case conflict(String) }`
  - `static func load(_ url:fileManager:) throws -> Loaded`
  - `static func save(_ contents:to:fileManager:) throws -> Date?`  (returns the post-write mtime)
  - `static func externalChange(at:lastKnownModificationDate:bufferIsDirty:fileManager:) throws -> ExternalChange`

- [ ] **Step 1: Write the failing test**

Create `Tests/AnglesiteCoreTests/FileDocumentIOTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

struct FileDocumentIOTests {
    private func tempFile(_ contents: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("doc-\(UUID().uuidString).txt")
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test("load reads contents and a modification date")
    func loadReads() throws {
        let url = try tempFile("hello"); defer { try? FileManager.default.removeItem(at: url) }
        let loaded = try FileDocumentIO.load(url)
        #expect(loaded.contents == "hello")
        #expect(loaded.modificationDate != nil)
    }

    @Test("save writes the bytes and returns a fresh mtime")
    func saveWrites() throws {
        let url = try tempFile("old"); defer { try? FileManager.default.removeItem(at: url) }
        let mtime = try FileDocumentIO.save("new contents", to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "new contents")
        #expect(mtime != nil)
    }

    @Test("externalChange returns .none when disk mtime is unchanged")
    func noChange() throws {
        let url = try tempFile("a"); defer { try? FileManager.default.removeItem(at: url) }
        let loaded = try FileDocumentIO.load(url)
        let change = try FileDocumentIO.externalChange(
            at: url, lastKnownModificationDate: loaded.modificationDate, bufferIsDirty: false)
        #expect(change == .none)
    }

    @Test("clean buffer + external write → .reloadable(newContents)")
    func reloadableWhenClean() throws {
        let url = try tempFile("a"); defer { try? FileManager.default.removeItem(at: url) }
        let loaded = try FileDocumentIO.load(url)
        // Simulate another tool writing the file with a strictly newer mtime.
        let newer = (loaded.modificationDate ?? Date()).addingTimeInterval(2)
        try Data("b".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: newer], ofItemAtPath: url.path)
        let change = try FileDocumentIO.externalChange(
            at: url, lastKnownModificationDate: loaded.modificationDate, bufferIsDirty: false)
        #expect(change == .reloadable("b"))
    }

    @Test("dirty buffer + external write → .conflict(newContents)")
    func conflictWhenDirty() throws {
        let url = try tempFile("a"); defer { try? FileManager.default.removeItem(at: url) }
        let loaded = try FileDocumentIO.load(url)
        let newer = (loaded.modificationDate ?? Date()).addingTimeInterval(2)
        try Data("b".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: newer], ofItemAtPath: url.path)
        let change = try FileDocumentIO.externalChange(
            at: url, lastKnownModificationDate: loaded.modificationDate, bufferIsDirty: true)
        #expect(change == .conflict("b"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter FileDocumentIOTests`
Expected: FAIL — `cannot find 'FileDocumentIO' in scope`.

- [ ] **Step 3: Implement `FileDocumentIO`**

Create `Sources/AnglesiteCore/FileDocumentIO.swift`:

```swift
import Foundation

/// Stateless file IO for the navigator's inline editor, plus the external-change decision.
/// The App view owns the text buffer + dirty flag; this type only touches disk and reports
/// what changed. Keeping it stateless makes the reconcile rules unit-testable without UI.
public enum FileDocumentIO {
    public struct Loaded: Sendable, Equatable {
        public let contents: String
        public let modificationDate: Date?
    }

    /// What the editor should do when the on-disk file no longer matches what we last saw.
    public enum ExternalChange: Sendable, Equatable {
        case none
        /// Disk changed and the buffer is clean — safe to swap in `contents` silently.
        case reloadable(String)
        /// Disk changed and the buffer is dirty — must ask the user; `contents` is the disk copy.
        case conflict(String)
    }

    public static func load(_ url: URL, fileManager: FileManager = .default) throws -> Loaded {
        let contents = try String(contentsOf: url, encoding: .utf8)
        let mtime = try modificationDate(of: url, fileManager: fileManager)
        return Loaded(contents: contents, modificationDate: mtime)
    }

    @discardableResult
    public static func save(_ contents: String, to url: URL, fileManager: FileManager = .default) throws -> Date? {
        try Data(contents.utf8).write(to: url, options: [.atomic])
        return try modificationDate(of: url, fileManager: fileManager)
    }

    public static func externalChange(
        at url: URL,
        lastKnownModificationDate: Date?,
        bufferIsDirty: Bool,
        fileManager: FileManager = .default
    ) throws -> ExternalChange {
        let current = try modificationDate(of: url, fileManager: fileManager)
        // Treat a strictly-newer disk mtime as an external write. Equal/nil → no change.
        guard let current, let last = lastKnownModificationDate, current > last else {
            return .none
        }
        let diskContents = try String(contentsOf: url, encoding: .utf8)
        return bufferIsDirty ? .conflict(diskContents) : .reloadable(diskContents)
    }

    private static func modificationDate(of url: URL, fileManager: FileManager) throws -> Date? {
        try fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter FileDocumentIOTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/FileDocumentIO.swift Tests/AnglesiteCoreTests/FileDocumentIOTests.swift
git commit -m "feat(navigator): FileDocumentIO load/save + external-change reconcile"
```

---

### Task 4: `EditorKind` routing seam

A one-function seam so file-specific editors (metadata form, etc.) can replace the generic text editor later without touching call sites. v1 returns `.text` for everything.

**Files:**
- Create: `Sources/AnglesiteCore/EditorKind.swift`
- Test: `Tests/AnglesiteCoreTests/EditorKindTests.swift`

**Interfaces:**
- Consumes: `FileRef` (Task 2).
- Produces: `enum EditorKind: Sendable, Equatable { case text }` and `func editorKind(for file: FileRef) -> EditorKind`.

- [ ] **Step 1: Write the failing test**

Create `Tests/AnglesiteCoreTests/EditorKindTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

struct EditorKindTests {
    @Test("v1 routes every file group to the text editor")
    func everythingIsText() {
        for group in FileGroup.allCases {
            let ref = FileRef(url: URL(fileURLWithPath: "/tmp/x"), group: group, name: "x")
            #expect(editorKind(for: ref) == .text)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter EditorKindTests`
Expected: FAIL — `cannot find 'editorKind' in scope`.

- [ ] **Step 3: Implement the seam**

Create `Sources/AnglesiteCore/EditorKind.swift`:

```swift
import Foundation

/// Which editor surface a navigator file opens in. v1 ships only `.text`; future cases
/// (`.metadataForm`, etc.) slot in by extending this enum and the `editorKind(for:)` mapping —
/// call sites switch on the kind and need no change beyond adding the new view.
public enum EditorKind: Sendable, Equatable {
    case text
    // future: case metadataForm
}

/// Resolves the editor for a file. Intentionally a free function with a single decision point so
/// the routing rule lives in one tested place.
public func editorKind(for file: FileRef) -> EditorKind {
    .text
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter EditorKindTests`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/EditorKind.swift Tests/AnglesiteCoreTests/EditorKindTests.swift
git commit -m "feat(navigator): EditorKind routing seam (text only for v1)"
```

---

### Task 5: `buildNavigatorTree` — merge content graph + file scan into sections

Pure builder that combines content-graph pages/posts with the filesystem scan into ordered sidebar sections. Keeps the App model thin.

**Files:**
- Create: `Sources/AnglesiteCore/NavigatorTree.swift`
- Test: `Tests/AnglesiteCoreTests/NavigatorTreeTests.swift`

**Interfaces:**
- Consumes: `SiteContentGraph.Page`, `SiteContentGraph.Post`, `[FileGroup: [FileRef]]` (Task 2).
- Produces:
  - `enum NavigatorTarget: Sendable, Equatable { case route(String); case file(FileRef) }`
  - `struct NavigatorItem: Sendable, Equatable, Identifiable { let id: String; let title: String; let target: NavigatorTarget }`
  - `struct NavigatorSection: Sendable, Equatable, Identifiable { let id: FileGroup; let title: String; let items: [NavigatorItem] }`
  - `func postRoute(for post: SiteContentGraph.Post) -> String`
  - `func buildNavigatorTree(pages:posts:fileGroups:) -> [NavigatorSection]`

> **Assumption (documented):** a post's preview route is derived as `/{collection}/{slug}/`. `SiteContentGraph.Post` has no stored route; this matches the common Astro content-collection URL shape. If the dev server 404s, the user sees the dev server's own 404 — acceptable for v1. A stored post route is a follow-up.

- [ ] **Step 1: Write the failing test**

Create `Tests/AnglesiteCoreTests/NavigatorTreeTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

struct NavigatorTreeTests {
    private func page(_ route: String, title: String?) -> SiteContentGraph.Page {
        SiteContentGraph.Page(id: "s:page:\(route)", siteID: "s", route: route,
            filePath: "/tmp\(route).astro", title: title, lastModified: Date(timeIntervalSince1970: 0))
    }
    private func post(_ collection: String, _ slug: String, _ title: String) -> SiteContentGraph.Post {
        SiteContentGraph.Post(id: "s:post:\(slug)", siteID: "s", collection: collection, slug: slug,
            title: title, draft: false, publishDate: nil, tags: [],
            filePath: "/tmp/\(slug).md", lastModified: Date(timeIntervalSince1970: 0))
    }

    @Test("post route derives /collection/slug/")
    func postRouteDerivation() {
        #expect(postRoute(for: post("blog", "hello-world", "Hello")) == "/blog/hello-world/")
    }

    @Test("sections appear in canonical order and only when non-empty")
    func sectionOrderAndEmpties() {
        let sections = buildNavigatorTree(
            pages: [page("/about/", title: "About")],
            posts: [],
            fileGroups: [.styles: [FileRef(url: URL(fileURLWithPath: "/tmp/g.css"), group: .styles, name: "g.css")]]
        )
        #expect(sections.map(\.id) == [.pages, .styles])   // posts/components/metadata empty → omitted
    }

    @Test("page item uses title when present and route as fallback; target is the route")
    func pageItems() {
        let sections = buildNavigatorTree(
            pages: [page("/about/", title: "About"), page("/contact/", title: nil)],
            posts: [], fileGroups: [:])
        let pages = sections.first { $0.id == .pages }!
        #expect(pages.items.map(\.title) == ["About", "/contact/"])
        #expect(pages.items.first?.target == .route("/about/"))
    }

    @Test("file item target carries the FileRef")
    func fileItems() {
        let ref = FileRef(url: URL(fileURLWithPath: "/tmp/Base.astro"), group: .components, name: "Base.astro")
        let sections = buildNavigatorTree(pages: [], posts: [], fileGroups: [.components: [ref]])
        let item = sections.first { $0.id == .components }!.items.first!
        #expect(item.title == "Base.astro")
        #expect(item.target == .file(ref))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter NavigatorTreeTests`
Expected: FAIL — `cannot find 'buildNavigatorTree' in scope`.

- [ ] **Step 3: Implement the builder**

Create `Sources/AnglesiteCore/NavigatorTree.swift`:

```swift
import Foundation

/// What selecting a navigator row does: navigate the preview to a route, or open a file in the editor.
public enum NavigatorTarget: Sendable, Equatable {
    case route(String)
    case file(FileRef)
}

public struct NavigatorItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let target: NavigatorTarget
    public init(id: String, title: String, target: NavigatorTarget) {
        self.id = id; self.title = title; self.target = target
    }
}

public struct NavigatorSection: Sendable, Equatable, Identifiable {
    public let id: FileGroup
    public let title: String
    public let items: [NavigatorItem]
    public init(id: FileGroup, title: String, items: [NavigatorItem]) {
        self.id = id; self.title = title; self.items = items
    }
}

/// Derived preview route for a post. See the plan's documented assumption.
public func postRoute(for post: SiteContentGraph.Post) -> String {
    "/\(post.collection)/\(post.slug)/"
}

/// Display titles for the five groups, in canonical sidebar order.
private let groupTitles: [(FileGroup, String)] = [
    (.pages, "Pages"), (.posts, "Posts"),
    (.components, "Components"), (.styles, "Styles"), (.metadata, "Metadata"),
]

/// Merges content-graph pages/posts with the filesystem scan into ordered, non-empty sections.
public func buildNavigatorTree(
    pages: [SiteContentGraph.Page],
    posts: [SiteContentGraph.Post],
    fileGroups: [FileGroup: [FileRef]]
) -> [NavigatorSection] {
    let pageItems = pages
        .sorted { $0.route < $1.route }
        .map { NavigatorItem(id: $0.id, title: $0.title ?? $0.route, target: .route($0.route)) }
    let postItems = posts
        .sorted { $0.title < $1.title }
        .map { NavigatorItem(id: $0.id, title: $0.title, target: .route(postRoute(for: $0))) }

    var sections: [NavigatorSection] = []
    for (group, title) in groupTitles {
        let items: [NavigatorItem]
        switch group {
        case .pages: items = pageItems
        case .posts: items = postItems
        default:
            items = (fileGroups[group] ?? []).map {
                NavigatorItem(id: $0.id, title: $0.name, target: .file($0))
            }
        }
        if !items.isEmpty { sections.append(NavigatorSection(id: group, title: title, items: items)) }
    }
    return sections
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter NavigatorTreeTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/NavigatorTree.swift Tests/AnglesiteCoreTests/NavigatorTreeTests.swift
git commit -m "feat(navigator): buildNavigatorTree merges content graph + file scan into sections"
```

---

### Task 6: `SiteNavigatorModel` (App glue)

Thin `@Observable @MainActor` model: loads the tree (graph snapshot + `SiteFileTree.scan`), refreshes on `SiteContentGraph.changeStream()`, and exposes `sections` + the resolved `NavigatorTarget` for a selected item id.

**Files:**
- Create: `Sources/AnglesiteApp/SiteNavigatorModel.swift`
- Verify: build only (App-target; not CI unit-tested per Global Constraints).

**Interfaces:**
- Consumes: `SiteContentGraph` (actor), `buildNavigatorTree`, `SiteFileTree.scan`, `NavigatorTarget`, `NavigatorSection`.
- Produces: `@MainActor @Observable final class SiteNavigatorModel` with `var sections: [NavigatorSection]`, `var selection: String?`, `func start(siteID:siteRoot:)`, `func stop()`, `func target(for id: String) -> NavigatorTarget?`.

- [ ] **Step 1: Implement the model**

Create `Sources/AnglesiteApp/SiteNavigatorModel.swift`:

```swift
import Foundation
import Observation
import AnglesiteCore

/// Drives the Site Navigator sidebar for one window. Reads pages/posts from the shared
/// `SiteContentGraph` and the filesystem-backed groups from `SiteFileTree`, then merges them via
/// `buildNavigatorTree`. Refreshes when the content graph emits for this site. App glue only —
/// all logic under test lives in AnglesiteCore.
@MainActor
@Observable
final class SiteNavigatorModel {
    private(set) var sections: [NavigatorSection] = []
    var selection: String?

    private let graph: SiteContentGraph
    private var siteID: String?
    private var siteRoot: URL?
    private var observeTask: Task<Void, Never>?

    init(graph: SiteContentGraph) {
        self.graph = graph
    }

    func start(siteID: String, siteRoot: URL) {
        self.siteID = siteID
        self.siteRoot = siteRoot
        Task { await refresh() }
        observeTask?.cancel()
        observeTask = Task { [graph, siteID] in
            // `changeStream()` is actor-isolated (Task 1) — await it to subscribe before iterating.
            for await changedSiteID in await graph.changeStream() {
                if Task.isCancelled { break }
                if changedSiteID == siteID { await refresh() }
            }
        }
    }

    func stop() {
        observeTask?.cancel()
        observeTask = nil
    }

    func target(for id: String) -> NavigatorTarget? {
        for section in sections {
            if let item = section.items.first(where: { $0.id == id }) { return item.target }
        }
        return nil
    }

    private func refresh() async {
        guard let siteID, let siteRoot else { return }
        let pages = await graph.pages(for: siteID)
        let posts = await graph.posts(for: siteID)
        // Filesystem scan is synchronous + cheap; run off the main actor to avoid stutter.
        let fileGroups = await Task.detached { SiteFileTree.scan(siteRoot: siteRoot) }.value
        sections = buildNavigatorTree(pages: pages, posts: posts, fileGroups: fileGroups)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteApp/SiteNavigatorModel.swift
git commit -m "feat(navigator): SiteNavigatorModel (graph + file scan, live refresh)"
```

---

### Task 7: `SiteNavigatorView` sidebar

The sidebar List: sections as `Section`s, items as selectable rows with SF Symbols per group.

**Files:**
- Create: `Sources/AnglesiteApp/SiteNavigatorView.swift`
- Verify: build only.

**Interfaces:**
- Consumes: `SiteNavigatorModel`, `NavigatorSection`, `FileGroup`.
- Produces: `struct SiteNavigatorView: View` taking `@Bindable var model: SiteNavigatorModel`.

- [ ] **Step 1: Implement the view**

Create `Sources/AnglesiteApp/SiteNavigatorView.swift`:

```swift
import SwiftUI
import AnglesiteCore

/// Xcode-Project-Navigator-style sidebar. Selection is bound to the model; `SiteWindow` reacts to
/// changes and either navigates the preview or opens the editor.
struct SiteNavigatorView: View {
    @Bindable var model: SiteNavigatorModel

    var body: some View {
        List(selection: $model.selection) {
            ForEach(model.sections) { section in
                Section(section.title) {
                    ForEach(section.items) { item in
                        Label(item.title, systemImage: icon(for: section.id))
                            .tag(item.id)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.sections.isEmpty {
                ContentUnavailableView("No content yet", systemImage: "sidebar.left")
            }
        }
    }

    private func icon(for group: FileGroup) -> String {
        switch group {
        case .pages: return "doc.richtext"
        case .posts: return "text.document"
        case .components: return "square.stack.3d.up"
        case .styles: return "paintbrush"
        case .metadata: return "gearshape"
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteApp/SiteNavigatorView.swift
git commit -m "feat(navigator): SiteNavigatorView sidebar list"
```

---

### Task 8: `MainPaneEditorView` text editor + conflict handling

Inline text editor for a `FileRef`: load on appear, ⌘S to save, dirty indicator, external-change detection on window focus with a conflict dialog (Keep mine / Reload).

**Files:**
- Create: `Sources/AnglesiteApp/MainPaneEditorView.swift`
- Verify: build only.

**Interfaces:**
- Consumes: `FileRef`, `FileDocumentIO`, `editorKind(for:)`.
- Produces: `struct MainPaneEditorView: View` taking `let file: FileRef`.

- [ ] **Step 1: Implement the view**

Create `Sources/AnglesiteApp/MainPaneEditorView.swift`:

```swift
import SwiftUI
import AnglesiteCore

/// Inline editor for a navigator-selected file. v1 is a plain text editor (`editorKind` always
/// `.text`); the `switch` is where future file-specific editors attach. Honors the source-of-truth
/// rule: explicit ⌘S save and a non-clobbering external-change guard.
struct MainPaneEditorView: View {
    let file: FileRef

    @State private var text: String = ""
    @State private var savedText: String = ""
    @State private var lastModified: Date?
    @State private var loadError: String?
    @State private var conflictDiskContents: String?

    @Environment(\.controlActiveState) private var controlActiveState

    private var isDirty: Bool { text != savedText }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if let loadError {
                    ContentUnavailableView {
                        Label("Can't open \(file.name)", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                    }
                } else {
                    switch editorKind(for: file) {
                    case .text:
                        TextEditor(text: $text)
                            .font(.system(.body, design: .monospaced))
                            .scrollContentBackground(.hidden)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: file.id) { load() }
        // Re-check the file when the window regains focus — chat/overlay/CLI may have written it.
        .onChange(of: controlActiveState) { _, new in
            if new == .key { checkExternalChange() }
        }
        .background(
            Button("") { save() }.keyboardShortcut("s", modifiers: [.command]).hidden()
        )
        .alert("\(file.name) changed on disk", isPresented: conflictBinding) {
            Button("Keep My Changes", role: .cancel) { conflictDiskContents = nil }
            Button("Reload from Disk") {
                if let disk = conflictDiskContents {
                    text = disk; savedText = disk
                    lastModified = try? FileDocumentIO.load(file.url).modificationDate
                }
                conflictDiskContents = nil
            }
        } message: {
            Text("Another tool edited this file while you had unsaved changes.")
        }
    }

    private var header: some View {
        HStack {
            Label(file.name, systemImage: "doc.text")
                .font(.headline)
            if isDirty {
                Circle().fill(.secondary).frame(width: 7, height: 7)
                    .help("Unsaved changes")
            }
            Spacer()
            Button("Save") { save() }
                .disabled(!isDirty || loadError != nil)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var conflictBinding: Binding<Bool> {
        Binding(get: { conflictDiskContents != nil }, set: { if !$0 { conflictDiskContents = nil } })
    }

    private func load() {
        do {
            let loaded = try FileDocumentIO.load(file.url)
            text = loaded.contents
            savedText = loaded.contents
            lastModified = loaded.modificationDate
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func save() {
        guard isDirty, loadError == nil else { return }
        do {
            lastModified = try FileDocumentIO.save(text, to: file.url)
            savedText = text
        } catch {
            loadError = "Save failed: \(error.localizedDescription)"
        }
    }

    private func checkExternalChange() {
        guard loadError == nil else { return }
        guard let change = try? FileDocumentIO.externalChange(
            at: file.url, lastKnownModificationDate: lastModified, bufferIsDirty: isDirty
        ) else { return }
        switch change {
        case .none:
            break
        case .reloadable(let disk):
            text = disk; savedText = disk
            lastModified = try? FileDocumentIO.load(file.url).modificationDate
        case .conflict(let disk):
            conflictDiskContents = disk
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteApp/MainPaneEditorView.swift
git commit -m "feat(navigator): MainPaneEditorView inline text editor with external-change guard"
```

---

### Task 9: Integrate into `SiteWindow` — split view + main-pane mode

Wrap `siteUI` in a `NavigationSplitView` with the navigator as sidebar; add `MainPaneMode` (preview vs. editor) with a `Preview | Editor` segmented control; route selection to either `preview.navigate`/`clearRoute` or the editor.

**Files:**
- Modify: `Sources/AnglesiteApp/SiteWindow.swift`
- Verify: build + manual smoke.

**Interfaces:**
- Consumes: `SiteNavigatorModel`, `SiteNavigatorView`, `MainPaneEditorView`, `NavigatorTarget`, `FileRef`, `contentGraph` (already a `SiteWindow` property), `preview.navigate(toRoute:)`, `preview.clearRoute()`.
- Produces: navigator wired into the window; no new public API.

- [ ] **Step 1: Add mode + navigator state**

In `SiteWindow.swift`, add a private mode enum above the struct (or in the same file):

```swift
private enum MainPaneMode: Equatable {
    case preview
    case editor(FileRef)
}
```

Add `@State` to `SiteWindow` near the other models (after `siriReadinessModel`):

```swift
    @State private var navigator: SiteNavigatorModel?
    @State private var mainPaneMode: MainPaneMode = .preview
```

- [ ] **Step 2: Create the navigator in `loadAndStart`**

In `loadAndStart()`, right after `preview.open(siteID: resolved.id, siteDirectory: resolved.path)`:

```swift
        let navModel = SiteNavigatorModel(graph: contentGraph)
        navModel.start(siteID: resolved.id, siteRoot: resolved.path)
        navigator = navModel
```

And in `.onDisappear` (in `body`), after `chat = nil`:

```swift
            navigator?.stop()
            navigator = nil
```

- [ ] **Step 3: Wrap `siteUI` content in a `NavigationSplitView`**

In `siteUI(for:)`, wrap the existing `ZStack(alignment: .bottom) { … }` so the navigator is the sidebar and the existing content is the detail. Replace the outer `ZStack(alignment: .bottom) {` … matching `}` (the one carrying `.navigationTitle`/`.toolbar`/`.sheet`s) with:

```swift
        NavigationSplitView {
            if let navigator {
                SiteNavigatorView(model: navigator)
                    .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
                    .onChange(of: navigator.selection) { _, newID in
                        applyNavigatorSelection(newID)
                    }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } detail {
            ZStack(alignment: .bottom) {
                // … the existing VStack + drawers, UNCHANGED …
            }
            // … the existing .animation/.navigationTitle/.toolbar/.sheet modifiers, UNCHANGED …
        }
```

> Keep all existing modifiers (`.navigationTitle`, `.navigationSubtitle`, `.toolbar`, every `.sheet`, `.annotatedAsSite`) attached to the **detail** `ZStack` exactly as they are today. Only the `NavigationSplitView { … } detail { … }` wrapper is new.

- [ ] **Step 4: Make the main pane honor the mode**

Replace the `mainPane(for:)` body's preview branch so the segmented control + editor are shown. Change `mainPane(for:)` to:

```swift
    @ViewBuilder
    private func mainPane(for site: SiteStore.Site) -> some View {
        VStack(spacing: 0) {
            if case .editor = mainPaneMode {
                Picker("", selection: Binding(
                    get: { paneSelection },
                    set: { setPaneSelection($0, for: site) }
                )) {
                    Text("Preview").tag(0)
                    Text("Editor").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                .padding(6)
                Divider()
            }
            mainPaneContent(for: site)
        }
    }

    private var paneSelection: Int {
        if case .editor = mainPaneMode { return 1 }
        return 0
    }

    private func setPaneSelection(_ value: Int, for site: SiteStore.Site) {
        if value == 0 { mainPaneMode = .preview }
        // value == 1 keeps the current .editor(file); no-op when already editing.
    }

    @ViewBuilder
    private func mainPaneContent(for site: SiteStore.Site) -> some View {
        switch mainPaneMode {
        case .editor(let file):
            MainPaneEditorView(file: file)
        case .preview:
            previewPane(for: site)   // the existing switch on preview.state, renamed
        }
    }
```

Rename the current `mainPane(for:)` switch body to `previewPane(for:)` (same `switch preview.state { … }` content, unchanged).

- [ ] **Step 5: Add the selection router**

Add to `SiteWindow`:

```swift
    /// Route a navigator selection: pages/posts switch to preview and navigate; files open the editor.
    @MainActor
    private func applyNavigatorSelection(_ id: String?) {
        guard let id, let target = navigator?.target(for: id) else { return }
        switch target {
        case .route(let route):
            mainPaneMode = .preview
            if route.isEmpty || route == "/" {
                preview.clearRoute()
            } else {
                preview.navigate(toRoute: route)
            }
        case .file(let file):
            mainPaneMode = .editor(file)
        }
    }
```

- [ ] **Step 6: Build to verify it compiles**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Verify the full Core suite still passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .`
Expected: all tests pass (existing suite + the new navigator tests from Tasks 1–5).

- [ ] **Step 8: Manual smoke**

Run the app (Xcode ⌘R or the built product). Open a site and confirm:
1. The sidebar shows Pages plus any Components/Styles/Metadata present.
2. Clicking a page navigates the preview to that route.
3. Clicking a component/style/metadata file opens it in the editor; the `Preview | Editor` toggle appears and switches back to the live preview.
4. Edit + ⌘S writes the file (dirty dot clears); the dev server rebuilds.
5. Edit the same file externally (e.g. `echo` from a terminal) while the buffer is dirty, refocus the window → the conflict dialog appears with Keep/Reload.

- [ ] **Step 9: Commit**

```bash
git add Sources/AnglesiteApp/SiteWindow.swift
git commit -m "feat(navigator): wire Site Navigator sidebar + editor mode into SiteWindow"
```

---

## Self-Review

**Spec coverage:**
- Left sidebar / NavigationSplitView → Task 9. ✓
- Five curated groups → Task 2 (scan) + Task 5 (sections) + Task 7 (view). ✓
- Pages/Posts from content graph → Task 5 builder reads graph pages/posts; Task 6 loads them. ✓
- Page→preview navigation → Task 9 `applyNavigatorSelection`. ✓
- Non-page→inline text editor replacing preview (option A) → Task 8 + Task 9 `MainPaneMode`. ✓
- Explicit save + dirty + external-change guard (option C) → Task 3 (logic) + Task 8 (UI/dialog). ✓
- EditorKind routing seam → Task 4, consumed in Task 8. ✓
- `SiteContentGraph` broadcast stream decision → Task 1. ✓
- Testable logic in AnglesiteCore → Tasks 1–5 all CI-tested. ✓
- MAS: reads/writes inside the existing security-scoped grant → no new file access introduced; editor uses `site.path` URLs already covered by `scopedURL`. ✓ (No new entitlement; confirm during Task 9 smoke if testing MAS.)

**Deferred (per spec non-goals), intentionally not in any task:** file create/rename/delete, metadata form editor, multi-file tabs, split editor+preview. ✓

**Placeholder scan:** No TBD/TODO/"handle edge cases"; every code step shows complete code. The one assumption (post route derivation) is documented in Task 5 with rationale and a code implementation. ✓

**Type consistency:** `FileGroup`, `FileRef`, `NavigatorTarget`, `NavigatorItem`, `NavigatorSection`, `EditorKind`/`editorKind(for:)`, `FileDocumentIO.{Loaded,ExternalChange,load,save,externalChange}`, `buildNavigatorTree`, `postRoute(for:)`, `SiteNavigatorModel.{sections,selection,start,stop,target}`, `MainPaneMode` — names are used identically across the tasks that define and consume them. ✓
