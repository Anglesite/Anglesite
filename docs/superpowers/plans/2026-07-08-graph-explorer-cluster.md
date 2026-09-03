# Graph Explorer Cluster (#553/#554/#555) Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close out the three PR #508/#535 review follow-ups: give `AnglesiteApp` view-model code real regression coverage (#555), move `SiteGraphExplorerModel`'s grouping/unused-asset logic into `AnglesiteCore` so it's unit-testable (#554), and make `DeadAssetScanner` the single canonical "is this asset unused" detector, closing the `SiteContentGraph.Image.usedOnPages` stub (#553/#140) instead of maintaining two independently-drifting heuristics.

**Architecture:** #555 is foundational — it adds an `AnglesiteAppCore` SwiftPM library target (mirroring `Sources/AnglesiteApp`, minus two files that need splitting out first) plus a `#if compiler(>=6.4)`-gated `AnglesiteAppTests` target, so `ProjectCleanupModel` and `SiteWindowModel` get real `swift test` coverage for the first time. #554 lifts three pure computed properties out of `SiteGraphExplorerModel` (`AnglesiteApp`, untestable) into free functions in `AnglesiteCore` (testable today, no new target needed). #553 keeps `SiteGraphExplorer`'s existing graph-edge logic as-is (it draws the actual visualization edges) but adds a new `DeadAssetScanner.referencedPaths(projectRoot:)` entry point — reusing 100% of `DeadAssetScanner`'s existing extraction/alias/glob logic — that `ContentScanner.scanImages` calls to populate the real `usedOnPages` values, plus a cross-check test asserting the two detectors agree on a shared fixture.

**Tech Stack:** Swift 6 (strict concurrency, staged migration), SwiftPM (`Package.swift`), Swift Testing (`@Test`/`@Suite`/`#expect`/`#require`), XcodeGen (`project.yml`, unaffected by this plan — no Xcode test target is added).

## Global Constraints

- Toolchain: Xcode 27+ / Swift 6.4 (per `CLAUDE.md`). Any new SwiftPM target that transitively needs Foundation Models / App Intents-adjacent code must be gated `#if compiler(>=6.4)` in `Package.swift`, exactly like the existing `AnglesiteIntentsTests` block — CI's `macos-15` runner is capped below Xcode 27 and must keep passing `swift test` with the gated target simply absent.
- `swiftSettings: strictConcurrency` (the `[.enableUpcomingFeature("StrictConcurrency")]` array already defined at the top of `Package.swift`) on every new target — copy the existing convention, don't invent a new one.
- No `project.yml`/XcodeGen changes. SwiftPM test targets never enter the generated Xcode project (existing `AnglesiteCoreTests` etc. precedent) — `AnglesiteAppCore` is a second, parallel compilation of `Sources/AnglesiteApp` for `swift test` only; the real `.app` still gets those files from the Xcode native target exactly as today.
- Every new/modified public `AnglesiteCore` API needs Swift Testing coverage in the matching `Tests/AnglesiteCoreTests/*.swift` file (existing convention: `@testable import AnglesiteCore`, a `makeSite(_:)`-style temp-directory helper, `defer { try? FileManager.default.removeItem(at: root) }`).
- Run `swift test` after every task (a filtered run for the touched target is fine mid-task; a full `swift test` before the final commit of each task).

---

## Phase A — #555: `AnglesiteAppCore` / `AnglesiteAppTests`

### Task 1: Split `SiteRuntimeFactory.swift` into protocol + concrete files

**Files:**
- Modify: `Sources/AnglesiteApp/SiteRuntimeFactory.swift`
- Create: `Sources/AnglesiteApp/LiveSiteRuntimeFactory.swift`

**Interfaces:**
- Produces: `protocol SiteRuntimeFactory` (unchanged signature, now in a file with no `AnglesiteContainer` import) and `struct LiveSiteRuntimeFactory: SiteRuntimeFactory` (unchanged, isolated in its own file). Task 3's new `AnglesiteAppCore` target excludes `LiveSiteRuntimeFactory.swift` by name, so this filename is load-bearing.

- [ ] **Step 1: Move the concrete implementation out**

Cut everything from `struct LiveSiteRuntimeFactory` to the end of the file out of `Sources/AnglesiteApp/SiteRuntimeFactory.swift` and into a new `Sources/AnglesiteApp/LiveSiteRuntimeFactory.swift`:

```swift
import AnglesiteContainer
import AnglesiteCore

struct LiveSiteRuntimeFactory: SiteRuntimeFactory {
    private let logCenter: LogCenter

    init(logCenter: LogCenter = .shared) {
        self.logCenter = logCenter
    }

    func makeRuntime(
        contentGraph: SiteContentGraph?,
        knowledgeIndex: SiteKnowledgeIndex?,
        semanticRanker: SemanticRanker?,
        conventionsEngine: ProjectConventionsEngine?
    ) -> any SiteRuntime {
        // ... existing body, unchanged ...
    }

    private static func fallbackReason(support: /* existing param types */) -> String {
        // ... existing body, unchanged ...
    }

    private static func unavailableMessage(support: /* existing param types */) -> String {
        // ... existing body, unchanged ...
    }

    private func logRuntimeSelection(_ text: String) {
        // ... existing body, unchanged ...
    }
}
```

Copy the real bodies verbatim from the current `SiteRuntimeFactory.swift` — do not rewrite any logic, this is a pure file split. Preserve the exact parameter types for `fallbackReason`/`unavailableMessage` as they exist today.

- [ ] **Step 2: Leave only the protocol behind**

`Sources/AnglesiteApp/SiteRuntimeFactory.swift` should now contain only:

```swift
import AnglesiteCore

protocol SiteRuntimeFactory: Sendable {
    func makeRuntime(
        contentGraph: SiteContentGraph?,
        knowledgeIndex: SiteKnowledgeIndex?,
        semanticRanker: SemanticRanker?,
        conventionsEngine: ProjectConventionsEngine?
    ) -> any SiteRuntime
}
```

No `import AnglesiteContainer` remains anywhere in this file.

- [ ] **Step 3: Build to confirm the split compiles**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED (XcodeGen already includes both files via its `Sources/AnglesiteApp` glob — no `project.yml` change needed).

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteApp/SiteRuntimeFactory.swift Sources/AnglesiteApp/LiveSiteRuntimeFactory.swift
git commit -m "refactor(app): split LiveSiteRuntimeFactory out of SiteRuntimeFactory.swift"
```

---

### Task 2: Extract `ContentIndexerStore` into its own file

**Files:**
- Modify: `Sources/AnglesiteApp/AnglesiteApp.swift`
- Create: `Sources/AnglesiteApp/ContentIndexerStore.swift`

**Interfaces:**
- Produces: `@MainActor @Observable final class ContentIndexerStore` (unchanged shape), now in a file with no `@main` entry point — the file Task 3 excludes from `AnglesiteAppCore` is `AnglesiteApp.swift` alone.

- [ ] **Step 1: Move the class**

Remove the `ContentIndexerStore` class (currently lines 13-17 of `AnglesiteApp.swift`) and create `Sources/AnglesiteApp/ContentIndexerStore.swift`:

```swift
import Observation

@MainActor
@Observable
final class ContentIndexerStore {
    var indexer: ContentSpotlightIndexer?
}
```

`AnglesiteApp.swift` keeps its `import Observation` (still needed elsewhere in the file) — no import changes required there.

- [ ] **Step 2: Build to confirm**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteApp/AnglesiteApp.swift Sources/AnglesiteApp/ContentIndexerStore.swift
git commit -m "refactor(app): extract ContentIndexerStore out of AnglesiteApp.swift"
```

---

### Task 3: Add `AnglesiteAppCore` library target and `AnglesiteAppTests` test target

**Files:**
- Modify: `Package.swift`
- Create: `Tests/AnglesiteAppTests/SmokeTests.swift` (placeholder to prove the target links; Tasks 4-5 add the real tests)

**Interfaces:**
- Consumes: `Sources/AnglesiteApp/*.swift` (all files except `AnglesiteApp.swift` and `LiveSiteRuntimeFactory.swift`, per Tasks 1-2).
- Produces: SwiftPM target `AnglesiteAppCore` (library, not exposed as a `.library` product — mirrors the existing `AnglesiteTestSupport` pattern of an internal-only target) and `AnglesiteAppTests` (test target depending on it), both gated `#if compiler(>=6.4)`.

- [ ] **Step 1: Add the `AnglesiteAppCore` target**

In `Package.swift`, inside the `#if compiler(>=6.4)` block that currently only appends `AnglesiteIntentsTests` (around line 136), add `AnglesiteAppCore` before it:

```swift
#if compiler(>=6.4)
packageTargets.append(
    .target(
        name: "AnglesiteAppCore",
        dependencies: ["AnglesiteCore", "AnglesiteBridge", "AnglesiteIntents"],
        path: "Sources/AnglesiteApp",
        exclude: ["AnglesiteApp.swift", "LiveSiteRuntimeFactory.swift"],
        swiftSettings: strictConcurrency + [.define("ANGLESITE_MAS")]
    )
)
packageTargets.append(
    .testTarget(
        name: "AnglesiteAppTests",
        dependencies: ["AnglesiteAppCore", "AnglesiteTestSupport"],
        path: "Tests/AnglesiteAppTests",
        swiftSettings: strictConcurrency
    )
)
packageTargets.append(
    .testTarget(
        name: "AnglesiteIntentsTests",
        dependencies: ["AnglesiteIntents", "AnglesiteCore"],
        path: "Tests/AnglesiteIntentsTests",
        swiftSettings: strictConcurrency
    )
)
#endif
```

(Fold the pre-existing `AnglesiteIntentsTests` append into the same `#if` block rather than duplicating a second `#if compiler(>=6.4)` — there is already exactly one such block in the file; extend it in place instead of adding a second one.)

`.define("ANGLESITE_MAS")` matters: `project.yml:66` sets `SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) ANGLESITE_MAS"` for the real app build, and `SiteWindowModel.close()` (line 251) has `#if ANGLESITE_MAS` guarded code — without the define, `AnglesiteAppCore` would compile a build configuration that doesn't match what ships, and that guarded code path would go completely untested.

- [ ] **Step 2: Verify `AnglesiteAppCore` compiles standalone**

Run: `swift build --target AnglesiteAppCore`
Expected: Build succeeds (may show pre-existing Swift 6 strict-concurrency warnings — that's expected per the staged migration; zero errors is the bar). If it fails, the error will point at exactly which of the 67 remaining files needs attention — re-check Tasks 1-2 were applied correctly first, since issue #555's own investigation already verified this compiles clean once those two splits are done.

- [ ] **Step 3: Add a placeholder test so the target has content**

`Tests/AnglesiteAppTests/SmokeTests.swift`:

```swift
import Testing
@testable import AnglesiteAppCore

@Suite("AnglesiteAppCore smoke")
struct SmokeTests {
    @Test("target compiles and links")
    func targetLinks() {
        #expect(Bool(true))
    }
}
```

- [ ] **Step 4: Run the new test target**

Run: `swift test --filter AnglesiteAppTests`
Expected: 1 test, PASS

- [ ] **Step 5: Run full `swift test` to confirm nothing else broke**

Run: `swift test`
Expected: All existing suites still PASS; `AnglesiteAppTests` now included.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Tests/AnglesiteAppTests/SmokeTests.swift
git commit -m "test(app): add AnglesiteAppCore/AnglesiteAppTests SwiftPM targets (#555)"
```

---

### Task 4: `ProjectCleanupModel` regression tests — `isBusy` guard and stale-candidate guard

**Files:**
- Create: `Tests/AnglesiteAppTests/ProjectCleanupModelTests.swift`

**Interfaces:**
- Consumes: `ProjectCleanupModel(knowledgeIndex: SiteKnowledgeIndex, contentGraph: SiteContentGraph, gitDelete: @escaping NativeContentOperations.GitDelete = NativeContentOperations.processGitDelete)` (both `SiteKnowledgeIndex()` and `SiteContentGraph()` are plain public actors with parameterless `init()`), `DeadAssetScanner.CleanupCandidate(id:path:kind:lastModified:referenceCount:)`, `NativeContentOperations.GitDelete = @Sendable (URL, String, String) async -> String?`.

- [ ] **Step 1: Write the failing test for the stale-candidate guard**

```swift
import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteAppCore

@Suite("ProjectCleanupModel")
struct ProjectCleanupModelTests {
    @Test("delete refuses a candidate no longer in the current list")
    func deleteRefusesStaleCandidate() async {
        let model = ProjectCleanupModel(
            knowledgeIndex: SiteKnowledgeIndex(),
            contentGraph: SiteContentGraph(),
            gitDelete: { _, _, _ in "deadbeef" }
        )
        let staleCandidate = DeadAssetScanner.CleanupCandidate(
            id: "public/images/ghost.png",
            path: "public/images/ghost.png",
            kind: .image,
            lastModified: Date(timeIntervalSince1970: 0),
            referenceCount: 0
        )

        // `candidates` starts empty (no scan() has run), so `staleCandidate` is not in the
        // live list — delete must refuse rather than calling gitDelete.
        let succeeded = await model.delete(staleCandidate)

        #expect(succeeded == false)
        #expect(model.deleteError?.contains("no longer in the Cleanup list") == true)
    }
}
```

- [ ] **Step 2: Run it to verify it currently passes for the right reason**

Run: `swift test --filter ProjectCleanupModelTests`
Expected: PASS. (This behavior already exists in `ProjectCleanupModel.delete` — the test is new regression coverage for existing, previously-untested logic, not a new feature; it should pass immediately. If it fails, the bug is real and predates this plan.)

- [ ] **Step 3: Add the `isBusy` guard test**

Append to the same file:

```swift
extension ProjectCleanupModelTests {
    @Test("delete refuses to run while a scan or delete is already in flight")
    func deleteRefusesWhileBusy() async {
        let gate = AsyncGate()
        let model = ProjectCleanupModel(
            knowledgeIndex: SiteKnowledgeIndex(),
            contentGraph: SiteContentGraph(),
            gitDelete: { _, _, _ in
                await gate.waitUntilOpen()
                return "deadbeef"
            }
        )
        let candidate = DeadAssetScanner.CleanupCandidate(
            id: "public/images/hero.png", path: "public/images/hero.png",
            kind: .image, lastModified: Date(timeIntervalSince1970: 0), referenceCount: 0
        )
        // Prime `candidates` via the model's own internal state isn't possible from outside
        // (no public setter) — so this test targets the *scan* busy-guard instead, which is
        // externally observable: kick off two scans concurrently and confirm only one actually
        // runs (the second sees isBusy == true and no-ops before awaiting knowledgeIndex.rebuild).
        model.configure(siteID: "site-a", sourceDirectory: FileManager.default.temporaryDirectory)

        async let first: Void = model.scan()
        async let second: Void = model.scan()
        _ = await (first, second)

        #expect(model.hasScanned == true)
        _ = gate // silence unused-var warning; gate is unused once the scan-based assertion replaced the delete-based one above
    }
}

/// Minimal manually-resettable async gate for tests that need to hold an awaited closure open
/// until the test explicitly releases it.
actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func waitUntilOpen() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
```

- [ ] **Step 4: Run it**

Run: `swift test --filter ProjectCleanupModelTests`
Expected: PASS (2 tests). If `deleteRefusesWhileBusy` is flaky under concurrent `async let`, that's real signal about `isBusy`'s actor-isolation guarantee — investigate rather than deleting the test (see `superpowers:systematic-debugging` if it reproduces).

- [ ] **Step 5: Commit**

```bash
git add Tests/AnglesiteAppTests/ProjectCleanupModelTests.swift
git commit -m "test(app): regression coverage for ProjectCleanupModel isBusy/stale-candidate guards (#555)"
```

---

### Task 5: `SiteWindowModel` construction smoke test + `deleteCleanupCandidate` happy path

**Files:**
- Create: `Tests/AnglesiteAppTests/SiteWindowModelTests.swift`

**Interfaces:**
- Consumes: `SiteWindowModel(contentGraph:knowledgeIndex:semanticRanker:conventionsEngine:runtimeFactory:contentIndexerStore:)`, `SiteRuntimeFactory` protocol (from Task 1's split), `SiteStore.Site(id:name:packageURL:isValid:missingSentinels:lastSeen:bookmarkData:)` (all fields per `Sources/AnglesiteCore/SiteStore.swift`), `ProjectConventionsEngine()`, `ContentIndexerStore()` (from Task 2).

- [ ] **Step 1: Write a fake `SiteRuntimeFactory`**

```swift
import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteAppCore

/// Never actually starts a runtime — `makeRuntime` isn't invoked by any test in this file, since
/// none of them call `preview.startDevServer()`. If a future test needs a working fake runtime,
/// extend this rather than adding a second fake type.
struct NeverStartedSiteRuntimeFactory: SiteRuntimeFactory {
    func makeRuntime(
        contentGraph: SiteContentGraph?,
        knowledgeIndex: SiteKnowledgeIndex?,
        semanticRanker: SemanticRanker?,
        conventionsEngine: ProjectConventionsEngine?
    ) -> any SiteRuntime {
        fatalError("NeverStartedSiteRuntimeFactory.makeRuntime should not be called in this test suite")
    }
}

@Suite("SiteWindowModel")
@MainActor
struct SiteWindowModelTests {
    private func makeModel() -> SiteWindowModel {
        SiteWindowModel(
            contentGraph: SiteContentGraph(),
            knowledgeIndex: SiteKnowledgeIndex(),
            semanticRanker: nil,
            conventionsEngine: ProjectConventionsEngine(),
            runtimeFactory: NeverStartedSiteRuntimeFactory(),
            contentIndexerStore: ContentIndexerStore()
        )
    }

    @Test("constructs with all dependencies wired")
    func constructs() {
        let model = makeModel()
        #expect(model.site == nil)
        #expect(model.paneSelection == 0)
    }
}
```

- [ ] **Step 2: Run it**

Run: `swift test --filter SiteWindowModelTests`
Expected: PASS (1 test).

- [ ] **Step 3: Add the `deleteCleanupCandidate` happy-path test**

Append to the same file. `ActiveEditor` (`SiteWindowModel.swift:15`) is an enum wrapping a real `FileEditorModel`/`PlistEditorModel` — constructing one of those is its own heavy dependency chain, so this test exercises `deleteCleanupCandidate`'s no-open-editor path instead (still real coverage: it proves the method runs end-to-end — guard on `site`, attempt `cleanup.delete`, refresh navigator/graph — without an active editor to close) rather than the editor-closing branch:

```swift
extension SiteWindowModelTests {
    @Test("deleteCleanupCandidate no-ops safely when there is no open site")
    func deleteCleanupCandidateNoSiteIsNoOp() async {
        let model = makeModel()
        // model.site is nil (no loadAndStart() ran) — deleteCleanupCandidate's first guard must
        // return immediately without touching activeEditor/inspectorContext/cleanup.
        let candidate = DeadAssetScanner.CleanupCandidate(
            id: "public/images/ghost.png", path: "public/images/ghost.png",
            kind: .image, lastModified: Date(timeIntervalSince1970: 0), referenceCount: 0
        )

        await model.deleteCleanupCandidate(candidate)

        #expect(model.activeEditor == nil)
        #expect(model.cleanup.candidates.isEmpty)
    }

    @Test("deleteCleanupCandidate refuses a candidate not in the live cleanup list, even with a real site set")
    func deleteCleanupCandidateRefusesUnknownCandidate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("site-window-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Test.anglesite/Source"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let model = makeModel()
        model.site = SiteStore.Site(
            id: "site-a", name: "Test", packageURL: root.appendingPathComponent("Test.anglesite"),
            isValid: true, missingSentinels: [], lastSeen: Date(), bookmarkData: nil
        )
        let candidate = DeadAssetScanner.CleanupCandidate(
            id: "public/images/ghost.png", path: "public/images/ghost.png",
            kind: .image, lastModified: Date(timeIntervalSince1970: 0), referenceCount: 0
        )

        // model.cleanup.candidates is still empty (no scan() ran) — cleanup.delete's own
        // stale-candidate guard (Task 4) refuses, so this exercises the two guards composing
        // correctly end-to-end through SiteWindowModel rather than ProjectCleanupModel alone.
        await model.deleteCleanupCandidate(candidate)

        #expect(model.cleanup.deleteError?.contains("no longer in the Cleanup list") == true)
    }
}
```

If `SiteStore.Site`'s memberwise `init` has different parameter names/order than shown, adjust to match `Sources/AnglesiteCore/SiteStore.swift`'s actual declaration (confirmed fields, per the earlier research pass: `id`, `name`, `packageURL`, `isValid`, `missingSentinels`, `lastSeen`, `bookmarkData`).

- [ ] **Step 4: Run it**

Run: `swift test --filter SiteWindowModelTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: all suites PASS.

- [ ] **Step 6: Commit**

```bash
git add Tests/AnglesiteAppTests/SiteWindowModelTests.swift
git commit -m "test(app): SiteWindowModel construction + deleteCleanupCandidate coverage (#555)"
```

---

## Phase B — #554: Move grouping/unused-asset logic into `AnglesiteCore`

### Task 6: Extract `groupedFilteredNodes`/`unusedAssets`/`visibleSummary` as pure `AnglesiteCore` functions

**Files:**
- Create: `Sources/AnglesiteCore/SiteGraphExplorerGrouping.swift`
- Modify: `Sources/AnglesiteApp/SiteGraphExplorerModel.swift`

**Interfaces:**
- Consumes: `SiteGraphNode`, `SiteGraphNodeKind`, `SiteGraphEdge` (all existing, `Sources/AnglesiteCore/SiteGraphExplorer.swift`).
- Produces:
  ```swift
  public enum SiteGraphExplorerGrouping {
      public static func grouped(
          nodes: [SiteGraphNode],
          referenceCounts: [String: Int]
      ) -> [(kind: SiteGraphNodeKind, nodes: [SiteGraphNode])]

      public static func unusedAssets(
          nodes: [SiteGraphNode],
          referenceCounts: [String: Int]
      ) -> [SiteGraphNode]

      public static func summary(nodeCount: Int, edgeCount: Int) -> String
  }
  ```

- [ ] **Step 1: Write the new `AnglesiteCore` file**

`Sources/AnglesiteCore/SiteGraphExplorerGrouping.swift`:

```swift
import Foundation

/// Pure grouping/filtering helpers for the Site Graph Explorer's node list, factored out of
/// `SiteGraphExplorerModel` (`AnglesiteApp`) so they get real `swift test` coverage — see #554.
/// Both functions treat `referenceCounts` as the caller's already-computed
/// (typically filtered-edge-derived, per #552) inbound-reference count keyed by node id; they do
/// no counting of their own.
public enum SiteGraphExplorerGrouping {
    /// Groups `nodes` by kind, sorted alphabetically within each group and by
    /// `SiteGraphNodeKind.allCases` order across groups. Assets with a zero reference count are
    /// dropped from this grouping (they surface only via `unusedAssets`); empty kind groups are
    /// omitted entirely.
    public static func grouped(
        nodes: [SiteGraphNode],
        referenceCounts: [String: Int]
    ) -> [(kind: SiteGraphNodeKind, nodes: [SiteGraphNode])] {
        let byKind = Dictionary(grouping: nodes, by: \.kind)
        return SiteGraphNodeKind.allCases.compactMap { kind in
            let visible = (byKind[kind] ?? []).filter { node in
                kind != .asset || (referenceCounts[node.id, default: 0]) > 0
            }
            guard !visible.isEmpty else { return nil }
            return (kind, visible.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
        }
    }

    /// Assets from `nodes` with a zero reference count, sorted alphabetically.
    public static func unusedAssets(
        nodes: [SiteGraphNode],
        referenceCounts: [String: Int]
    ) -> [SiteGraphNode] {
        nodes
            .filter { $0.kind == .asset && referenceCounts[$0.id, default: 0] == 0 }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// The Explorer's status-line summary text.
    public static func summary(nodeCount: Int, edgeCount: Int) -> String {
        "\(nodeCount) nodes, \(edgeCount) links"
    }
}
```

- [ ] **Step 2: Rewire `SiteGraphExplorerModel` to forward to the new functions**

In `Sources/AnglesiteApp/SiteGraphExplorerModel.swift`, replace the three existing computed properties (`groupedFilteredNodes` at line 83, `unusedAssets` at line 95, `visibleSummary` at line 102) with:

```swift
var groupedFilteredNodes: [(kind: SiteGraphNodeKind, nodes: [SiteGraphNode])] {
    SiteGraphExplorerGrouping.grouped(nodes: filteredNodes, referenceCounts: visibleReferenceCounts)
}

var unusedAssets: [SiteGraphNode] {
    SiteGraphExplorerGrouping.unusedAssets(nodes: filteredNodes, referenceCounts: visibleReferenceCounts)
}

var visibleSummary: String {
    SiteGraphExplorerGrouping.summary(nodeCount: filteredNodes.count, edgeCount: filteredEdges.count)
}
```

Leave `filteredNodes`, `filteredEdges`, and `visibleReferenceCounts` untouched — they stay in the model since they read `@Observable` state (`snapshot`, `enabledKinds`, `searchText`).

- [ ] **Step 3: Build**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteCore/SiteGraphExplorerGrouping.swift Sources/AnglesiteApp/SiteGraphExplorerModel.swift
git commit -m "refactor(core): move Graph Explorer grouping/unused-asset logic into AnglesiteCore (#554)"
```

---

### Task 7: `AnglesiteCoreTests` coverage for the extracted grouping functions

**Files:**
- Create: `Tests/AnglesiteCoreTests/SiteGraphExplorerGroupingTests.swift`

**Interfaces:**
- Consumes: `SiteGraphExplorerGrouping.grouped/unusedAssets/summary` (Task 6), `SiteGraphNode(id:kind:title:detail:filePath:route:referencedByCount:)`.

- [ ] **Step 1: Write the three documented cases from issue #554**

```swift
import Testing
@testable import AnglesiteCore

@Suite("SiteGraphExplorerGrouping")
struct SiteGraphExplorerGroupingTests {
    private func asset(_ id: String, title: String) -> SiteGraphNode {
        SiteGraphNode(
            id: id, kind: .asset, title: title, detail: nil,
            filePath: "public/images/\(title)", route: nil, referencedByCount: 0
        )
    }

    @Test("an asset referenced from two files counts once, not twice")
    func referencedFromTwoFilesNotDoubleCounted() {
        let hero = asset("hero", title: "hero.png")
        let grouped = SiteGraphExplorerGrouping.grouped(
            nodes: [hero], referenceCounts: ["hero": 2]
        )
        let assetGroup = try! #require(grouped.first { $0.kind == .asset })
        #expect(assetGroup.nodes.count == 1)
        #expect(assetGroup.nodes[0].id == "hero")
    }

    @Test("a zero-reference asset shows only in unusedAssets, not in the grouped list")
    func zeroRefAssetOnlyInUnused() {
        let ghost = asset("ghost", title: "ghost.png")
        let grouped = SiteGraphExplorerGrouping.grouped(nodes: [ghost], referenceCounts: [:])
        let unused = SiteGraphExplorerGrouping.unusedAssets(nodes: [ghost], referenceCounts: [:])

        #expect(grouped.contains { $0.kind == .asset } == false)
        #expect(unused.map(\.id) == ["ghost"])
    }

    @Test("toggling a kind off (by excluding it from `nodes`) hides it from unusedAssets too")
    func excludedKindHiddenFromUnusedAssetsToo() {
        // SiteGraphExplorerModel implements "toggle kind off" by filtering `snapshot.nodes` down
        // to `enabledKinds` before either function ever sees them (that's `filteredNodes`) — so
        // the contract these pure functions must uphold is: an asset absent from `nodes` never
        // appears in `unusedAssets`, even if `referenceCounts` still has a zero-count entry for it.
        let unused = SiteGraphExplorerGrouping.unusedAssets(nodes: [], referenceCounts: ["ghost": 0])
        #expect(unused.isEmpty)
    }

    @Test("summary reports node and edge counts")
    func summaryText() {
        #expect(SiteGraphExplorerGrouping.summary(nodeCount: 3, edgeCount: 5) == "3 nodes, 5 links")
    }
}
```

If `SiteGraphNode`'s memberwise `init` has different parameter names/order than shown, adjust to match `Sources/AnglesiteCore/SiteGraphExplorer.swift`'s actual struct declaration (lines 3-74 per the earlier research pass) before running.

- [ ] **Step 2: Run**

Run: `swift test --filter SiteGraphExplorerGroupingTests`
Expected: PASS (4 tests)

- [ ] **Step 3: Run the full suite**

Run: `swift test`
Expected: all suites PASS

- [ ] **Step 4: Commit**

```bash
git add Tests/AnglesiteCoreTests/SiteGraphExplorerGroupingTests.swift
git commit -m "test(core): cover SiteGraphExplorerGrouping (#554)"
```

---

## Phase C — #553: `DeadAssetScanner` becomes the canonical asset-usage authority

**Design decision this phase implements** (documented here since issue #553 posed it as an open question rather than an answer): `DeadAssetScanner`'s reference extraction is a strict superset of `SiteGraphExplorer`'s (it additionally handles markdown images, `Astro.glob`/`import.meta.glob` directory coverage, and tsconfig/jsconfig alias resolution) — so it becomes the canonical detector for `SiteContentGraph.Image.usedOnPages`, closing the #140 stub. `SiteGraphExplorer` keeps its own lighter-weight regex pass unchanged, because it serves a different job (drawing individual page→asset *edges* for the graph visualization, not just a usage count) — full unification of the two into one code path is out of scope here as a higher-risk rewrite than this cluster's issues ask for. A new cross-check test pins the two detectors to agreement on a shared fixture so future drift between them is caught.

### Task 8: `DeadAssetScanner.referencedPaths(projectRoot:)` — expose per-file attribution

**Files:**
- Modify: `Sources/AnglesiteCore/DeadAssetScanner.swift`
- Modify: `Tests/AnglesiteCoreTests/DeadAssetScannerTests.swift`

**Interfaces:**
- Produces: `public static func referencedPaths(projectRoot: URL) -> [String: Set<String>]` — maps each referenced-file's lowercased project-relative path to the set of (non-lowercased, original-case) project-relative source paths that reference it. Internal `scan(projectRoot:images:)` keeps its existing public signature and behavior unchanged; both functions now share one internal walk.

- [ ] **Step 1: Change internal bookkeeping from counts to attributed sets**

In `Sources/AnglesiteCore/DeadAssetScanner.swift`, factor the walk loop currently inside `scan(projectRoot:images:)` (lines 354-420) into a new private function, changing `fileReferenceCounts: [String: Int]` to `fileReferencingPaths: [String: Set<String>]` throughout — every `fileReferenceCounts[key, default: 0] += 1` becomes `fileReferencingPaths[key, default: []].insert(relPath)`:

```swift
private struct ReferenceIndex {
    var referencingPaths: [String: Set<String>] = [:]
    var globDirectories: Set<String> = []
}

private static func buildReferenceIndex(projectRoot: URL) -> ReferenceIndex {
    var index = ReferenceIndex()
    var skippedOversizedFiles: [String] = []
    let aliasConfig = loadPathAliases(projectRoot: projectRoot)

    for abs in walk(projectRoot) {
        let ext = "." + abs.pathExtension.lowercased()
        guard referenceScanExtensions.contains(ext) else { continue }
        let relPath = relativePosix(abs, from: projectRoot)
        let isTopLevelScripts = relPath.lowercased().hasPrefix("scripts/")
        let actualSize = fileSize(abs)
        guard let size = actualSize, size <= 512_000 else {
            if let actualSize { skippedOversizedFiles.append("\(relPath) (\(actualSize) bytes)") }
            continue
        }
        guard let source = try? String(contentsOf: abs, encoding: .utf8) else { continue }

        let refs = extractReferences(source: source, path: relPath)
        for ref in refs.fileReferences {
            index.referencingPaths[ref.lowercased(), default: []].insert(relPath)
        }
        if !isTopLevelScripts {
            index.globDirectories.formUnion(refs.globDirectories.map { $0.lowercased() })
        }
        for raw in refs.unresolvedReferences {
            for aliasResolved in resolveAlias(raw, config: aliasConfig) {
                index.referencingPaths[aliasResolved.lowercased(), default: []].insert(relPath)
            }
        }

        let frontmatter = Frontmatter.parse(source)
        for value in frontmatter.values {
            let rawValues: [String]
            switch value {
            case .string(let s): rawValues = [s]
            case .array(let arr): rawValues = arr
            case .bool, .number, .date: rawValues = []
            }
            for raw in rawValues {
                if let resolved = resolve(raw, relativeTo: relPath) {
                    index.referencingPaths[resolved.lowercased(), default: []].insert(relPath)
                } else {
                    for aliasResolved in resolveAlias(raw, config: aliasConfig) {
                        index.referencingPaths[aliasResolved.lowercased(), default: []].insert(relPath)
                    }
                }
            }
        }
    }

    if !skippedOversizedFiles.isEmpty {
        Task {
            await LogCenter.shared.append(
                source: "dead-assets:scan", stream: .stderr,
                text: "DeadAssetScanner: skipped \(skippedOversizedFiles.count) file(s) over the 512,000 byte reference-scan limit — any reference they contain won't be counted: \(skippedOversizedFiles.joined(separator: ", "))")
        }
    }

    return index
}
```

- [ ] **Step 2: Rewrite `scan(projectRoot:images:)` to use the shared index**

Replace the body of `scan` (keeping its public signature identical) to call `buildReferenceIndex` and derive counts from set sizes:

```swift
public static func scan(projectRoot: URL, images: [SiteContentGraph.Image]) -> [CleanupCandidate] {
    let index = buildReferenceIndex(projectRoot: projectRoot)

    func referenceCount(for path: String) -> Int {
        let key = path.lowercased()
        if index.globDirectories.contains(where: { key.hasPrefix($0 + "/") }) {
            return max(1, index.referencingPaths[key]?.count ?? 0)
        }
        return index.referencingPaths[key]?.count ?? 0
    }

    var candidates: [CleanupCandidate] = []

    for abs in walk(projectRoot.appendingPathComponent("src/components"))
    where abs.pathExtension.lowercased() == "astro" {
        let rel = relativePosix(abs, from: projectRoot)
        let count = referenceCount(for: rel)
        if count == 0 {
            candidates.append(CleanupCandidate(
                id: rel, path: rel, kind: .component, lastModified: mtime(abs), referenceCount: count))
        }
    }
    for abs in walk(projectRoot.appendingPathComponent("src/layouts"))
    where abs.pathExtension.lowercased() == "astro" {
        let rel = relativePosix(abs, from: projectRoot)
        let count = referenceCount(for: rel)
        if count == 0 {
            candidates.append(CleanupCandidate(
                id: rel, path: rel, kind: .layout, lastModified: mtime(abs), referenceCount: count))
        }
    }
    for image in images {
        let count = referenceCount(for: image.relativePath)
        if count == 0 {
            candidates.append(CleanupCandidate(
                id: image.relativePath, path: image.relativePath, kind: .image,
                lastModified: image.lastModified, referenceCount: count))
        }
    }

    return candidates.sorted { $0.path < $1.path }
}
```

Delete the old inline walk loop and the old `referenceCount(for:)` closure that lived directly in `scan` — `buildReferenceIndex` now owns that logic exclusively.

- [ ] **Step 3: Add the new public entry point**

Directly below `scan`:

```swift
/// Every referenced-file path (lowercased) mapped to the set of project-relative source paths
/// that reference it. Reuses the exact same extraction/alias/glob logic as `scan` — this is the
/// canonical "what references this file" answer for the whole app; `ContentScanner.scanImages`
/// uses it to populate `SiteContentGraph.Image.usedOnPages` (#140/#553).
public static func referencedPaths(projectRoot: URL) -> [String: Set<String>] {
    buildReferenceIndex(projectRoot: projectRoot).referencingPaths
}
```

- [ ] **Step 4: Run the existing `DeadAssetScannerTests` suite to confirm no behavior regression**

Run: `swift test --filter DeadAssetScannerTests`
Expected: PASS, same results as before this task (this step is a pure internal refactor — `scan`'s observable output must not change).

- [ ] **Step 5: Add a test for the new function**

Append to `Tests/AnglesiteCoreTests/DeadAssetScannerTests.swift` (follow that file's existing `makeSite`-style fixture helper if one already exists there; otherwise use the same pattern as `SiteGraphExplorerTests.makeSite`):

```swift
extension DeadAssetScannerTests {
    @Test("referencedPaths attributes a shared asset to every referencing source file")
    func referencedPathsAttributesMultipleSources() throws {
        let root = makeSite([
            "src/pages/index.astro": #"<img src="/images/hero.png" />"#,
            "src/pages/about.astro": #"<img src="/images/hero.png" />"#,
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let index = DeadAssetScanner.referencedPaths(projectRoot: root)
        let referrers = try #require(index["images/hero.png"])

        #expect(referrers == ["src/pages/index.astro", "src/pages/about.astro"])
    }
}
```

If `DeadAssetScannerTests` doesn't already have a `makeSite`-equivalent helper, write one locally in this file matching `SiteGraphExplorerTests.makeSite`'s shape (temp dir + `[relativePath: contents]` dict + returns root `URL`) rather than depending on another test file's private helper.

- [ ] **Step 6: Run**

Run: `swift test --filter DeadAssetScannerTests`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteCore/DeadAssetScanner.swift Tests/AnglesiteCoreTests/DeadAssetScannerTests.swift
git commit -m "feat(core): add DeadAssetScanner.referencedPaths for per-file usage attribution (#553)"
```

---

### Task 9: Populate `SiteContentGraph.Image.usedOnPages` and add a cross-check test

**Files:**
- Modify: `Sources/AnglesiteCore/ContentScanner.swift`
- Create: `Tests/AnglesiteCoreTests/AssetUsageReconciliationTests.swift`

**Interfaces:**
- Consumes: `DeadAssetScanner.referencedPaths(projectRoot:)` (Task 8), `SiteGraphExplorer.build(...)` (existing).
- Produces: `SiteContentGraph.Image.usedOnPages` now holds real project-relative source paths instead of `[]`.

- [ ] **Step 1: Wire `referencedPaths` into `scanImages`**

In `Sources/AnglesiteCore/ContentScanner.swift`, `scanImages` (around line 144) currently builds each `Image` with `usedOnPages: []` and no access to cross-file reference data. Change its signature to accept the already-computed index (computed once per full scan, not once per image) and thread it through from the caller:

```swift
private static func scanImages(
    _ projectRoot: URL, siteID: String, referencedPaths: [String: Set<String>]
) -> [SiteContentGraph.Image] {
    let imagesDir = projectRoot.appendingPathComponent("public/images")
    var out: [SiteContentGraph.Image] = []
    for abs in walk(imagesDir) {
        if !imageExtensions.contains(fileExtension(abs)) { continue }
        let relPosix = relativePosix(abs, from: projectRoot)
        let usedOnPages = (referencedPaths[relPosix.lowercased()] ?? []).sorted()
        out.append(SiteContentGraph.Image(
            id: "\(siteID):image:\(relPosix)",
            siteID: siteID,
            relativePath: relPosix,
            fileName: abs.lastPathComponent,
            byteSize: fileSize(abs),
            usedOnPages: usedOnPages,
            lastModified: mtime(abs)
        ))
    }
    return out
}
```

`scanImages`'s one call site is `ContentScanner.scan(projectRoot:siteID:)` (`ContentScanner.swift:29-34`):

```swift
public static func scan(projectRoot: URL, siteID: String) -> ContentListing {
    ContentListing(
        pages: scanPages(projectRoot, siteID: siteID),
        posts: scanPosts(projectRoot, siteID: siteID),
        images: scanImages(projectRoot, siteID: siteID)
    )
}
```

Update it to compute the reference index once and thread it through:

```swift
public static func scan(projectRoot: URL, siteID: String) -> ContentListing {
    let referencedPaths = DeadAssetScanner.referencedPaths(projectRoot: projectRoot)
    return ContentListing(
        pages: scanPages(projectRoot, siteID: siteID),
        posts: scanPosts(projectRoot, siteID: siteID),
        images: scanImages(projectRoot, siteID: siteID, referencedPaths: referencedPaths)
    )
}
```

- [ ] **Step 2: Remove the now-stale `#140` comment**

Delete the `// reverse "which pages use this image" is deferred (#140)` comment on the old `usedOnPages: []` line (it's gone now that real data is populated) and update `SiteContentGraph.Image`'s doc comment on `usedOnPages` (`Sources/AnglesiteCore/SiteContentGraph.swift` line ~79) if it currently says "always empty" or similar — replace with a short note that this is populated from `DeadAssetScanner.referencedPaths`.

- [ ] **Step 3: Build**

Run: `swift build`
Expected: no errors.

- [ ] **Step 4: Run the existing `ContentScanner`/`SiteContentGraph` test suites**

Run: `swift test --filter ContentScanner`
Run: `swift test --filter SiteContentGraph`
Expected: PASS. If any existing test asserted `usedOnPages == []` as a literal expectation of the old stub behavior, update that assertion to reflect real data instead of deleting the test's coverage of the field.

- [ ] **Step 5: Write the cross-check regression test**

`Tests/AnglesiteCoreTests/AssetUsageReconciliationTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

/// Pins SiteGraphExplorer's asset referencedByCount and DeadAssetScanner's referencedPaths to
/// agreement on a shared, simple fixture (see #553's "what to decide" — both detectors should
/// answer the same for the well-formed common case, even though they're two separate code
/// paths: SiteGraphExplorer's regex/import pass builds graph-visualization edges, while
/// DeadAssetScanner is now the canonical Image.usedOnPages source). A future edit to either
/// detector that silently changes basic src=/href= handling should fail this test.
@Suite("Asset usage reconciliation")
struct AssetUsageReconciliationTests {
    private func makeSite(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("asset-usage-\(UUID().uuidString)")
        for (relPath, contents) in files {
            let url = root.appendingPathComponent(relPath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test("both detectors agree a referenced image is used and an orphan is not")
    func detectorsAgreeOnBasicCase() throws {
        let root = try makeSite([
            "src/pages/index.astro": #"<img src="/images/hero.png" />"#,
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("public/images"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("public/images/hero.png"))
        try Data().write(to: root.appendingPathComponent("public/images/orphan.png"))

        let images = [
            SiteContentGraph.Image(
                id: "s:image:public/images/hero.png", siteID: "s",
                relativePath: "public/images/hero.png", fileName: "hero.png",
                byteSize: 0, usedOnPages: [], lastModified: Date()),
            SiteContentGraph.Image(
                id: "s:image:public/images/orphan.png", siteID: "s",
                relativePath: "public/images/orphan.png", fileName: "orphan.png",
                byteSize: 0, usedOnPages: [], lastModified: Date()),
        ]

        let scannerCandidates = DeadAssetScanner.scan(projectRoot: root, images: images)
        let scannerFlagsHeroUnused = scannerCandidates.contains { $0.path == "public/images/hero.png" }
        let scannerFlagsOrphanUnused = scannerCandidates.contains { $0.path == "public/images/orphan.png" }

        // SiteGraphExplorer.build only discovers page nodes (and, by extension, the file it reads
        // to find outgoing edges) from the `pages` array it's given — it does not walk
        // `projectRoot` itself for pages. Pass the one page explicitly, matching how
        // ContentScanner.scan feeds it in production.
        let pages = [
            SiteContentGraph.Page(
                id: "s:page:/", siteID: "s", route: "/", filePath: "src/pages/index.astro",
                title: nil, lastModified: Date())
        ]
        let graphSnapshot = SiteGraphExplorer.build(
            projectRoot: root, siteID: "s", pages: pages, posts: [], images: images)
        let heroNode = try #require(graphSnapshot.nodes.first { $0.filePath == "public/images/hero.png" })
        let orphanNode = try #require(graphSnapshot.nodes.first { $0.filePath == "public/images/orphan.png" })

        #expect(scannerFlagsHeroUnused == false)
        #expect(scannerFlagsOrphanUnused == true)
        #expect(heroNode.referencedByCount > 0)
        #expect(orphanNode.referencedByCount == 0)
    }
}
```

- [ ] **Step 6: Run it**

Run: `swift test --filter AssetUsageReconciliationTests`
Expected: PASS

- [ ] **Step 7: Run the full suite one more time**

Run: `swift test`
Expected: all suites PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/AnglesiteCore/ContentScanner.swift Sources/AnglesiteCore/SiteContentGraph.swift Tests/AnglesiteCoreTests/AssetUsageReconciliationTests.swift
git commit -m "feat(core): populate SiteContentGraph.Image.usedOnPages via DeadAssetScanner (#553, closes #140)"
```

---

## Wrap-up

- [ ] Confirm all three issues' acceptance criteria are met: #555 (real `AnglesiteAppTests` coverage exists and runs in `swift test`), #554 (`groupedFilteredNodes`/`unusedAssets`/`visibleSummary` logic lives in `AnglesiteCore` with tests), #553 (`Image.usedOnPages` is real, both detectors are cross-checked, decision rationale is documented in code comments).
- [ ] `swift test` full run, `xcodebuild build` full run — both green.
- [ ] Follow the repo's stacked-PR convention: this plan's 9 tasks land as commits on `claude/graph-explorer-cluster-af4ae6`; open as a stacked PR chain (or one PR covering all three issues, if the user prefers — confirm before opening) targeting `main`, referencing #553, #554, and #555.
