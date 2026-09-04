# RelevantEntities — Most-Recent-Site Suggestions Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Push the top-N most-recently-used Anglesite sites to the macOS 27 Siri/Spotlight *relevant entities* suggestion surface, kept fresh as sites are opened/recorded/removed.

**Architecture:** A new `RelevantEntitiesUpdater` actor in `AnglesiteIntents` (mirroring the existing `SpotlightIndexer`) transforms an MRU-sorted `[SiteStore.Site]` snapshot into the top-N `SiteEntity` set and pushes it through a `RelevantEntitiesBackend` seam, diffing against the last published id list to skip redundant pushes. `Bootstrap.swift` drives it by consuming the existing `SiteStore.changeStream()` — which already yields on data changes *and* MRU reorders — so no `SiteStore` change is needed. The live backend wraps the system `RelevantEntities` API and is the only place that touches the SDK symbol.

**Tech Stack:** Swift 6.4 / Xcode 27, AppIntents framework, Swift Testing (`@Test`), SwiftPM (`swift test`).

## Global Constraints

- **Toolchain:** Run all SwiftPM commands with Xcode 27: `export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` then `xcrun swift ...`. The default CommandLineTools `swift` is broken and too old.
- **ES-module / vanilla rules** do not apply — this is Swift.
- **Process spawning** is irrelevant here (no subprocesses).
- **Test framework:** Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`). New intent suites nest in `extension AppIntentsTests { ... }` (the `.serialized` root suite) — see `Tests/AnglesiteIntentsTests/SpotlightIndexerTests.swift`.
- **No `@available` gating** needed for macOS-27 symbols when building locally on Xcode 27 (package floor is `.macOS("27.0")`). CI-toolchain portability is handled per-symbol with `#if compiler(>=6.4)` only where a symbol is absent from the older SDK (Task 2).
- **Default N (most-recent count): 3.**
- **Commit message trailer:** end every commit body with
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- All new code lives in `Sources/AnglesiteIntents/`; tests in `Tests/AnglesiteIntentsTests/`.

---

## File Structure

- **Create** `Sources/AnglesiteIntents/RelevantEntitiesUpdater.swift` — the `RelevantEntitiesBackend` protocol, the `RelevantEntitiesUpdater` actor (`refresh(_:)` + `Outcome` + dedup), and the `LiveRelevantEntitiesBackend` production backend. Single responsibility: maintain the relevant-entities suggestion set. Mirrors `SpotlightIndexer.swift`.
- **Create** `Tests/AnglesiteIntentsTests/RelevantEntitiesUpdaterTests.swift` — unit tests against a recording fake backend. Mirrors `SpotlightIndexerTests.swift`.
- **Modify** `Sources/AnglesiteIntents/Bootstrap.swift` — add a logger and an app-lifetime `Task` consuming `SiteStore.shared.changeStream()` that calls `RelevantEntitiesUpdater.shared.refresh(_:)`.

---

## Task 1: `RelevantEntitiesUpdater` core (logic + tests)

The pure, fully-testable unit: the backend seam, the actor, top-N truncation, and order-sensitive dedup. No SDK calls, no bootstrap wiring. Reviewable and runnable in CI on its own.

**Files:**
- Create: `Sources/AnglesiteIntents/RelevantEntitiesUpdater.swift`
- Test: `Tests/AnglesiteIntentsTests/RelevantEntitiesUpdaterTests.swift`

**Interfaces:**
- Consumes: `SiteStore.Site` (from `AnglesiteCore`), `SiteEntity` + `SiteEntity.init(_ site:)` (from `Sources/AnglesiteIntents/SiteEntity.swift`).
- Produces (relied on by Task 2):
  - `protocol RelevantEntitiesBackend: Sendable { func update(_ entities: [SiteEntity]) async throws }`
  - `actor RelevantEntitiesUpdater` with `init(backend:maxCount:)` (`maxCount` defaults to 3) and `@discardableResult func refresh(_ sites: [SiteStore.Site]) async throws -> Outcome`
  - `struct RelevantEntitiesUpdater.Outcome: Sendable, Equatable { let published: Int; let skipped: Bool }`

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteIntentsTests/RelevantEntitiesUpdaterTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore
@testable import AnglesiteIntents

extension AppIntentsTests {
    /// Verifies the top-N truncation and order-sensitive dedup of `RelevantEntitiesUpdater`
    /// against a recording fake backend. The live `RelevantEntities` system surface isn't
    /// exercised here — it has no usable test seam (mirrors `SpotlightIndexerTests`).
    @Suite("RelevantEntitiesUpdater")
    struct RelevantEntitiesUpdaterTests {
        actor RecordingBackend: RelevantEntitiesBackend {
            private(set) var updatedBatches: [[SiteEntity]] = []
            func update(_ entities: [SiteEntity]) async throws {
                updatedBatches.append(entities)
            }
        }

        private func site(_ id: String, _ name: String) -> SiteStore.Site {
            SiteStore.Site(
                id: id,
                name: name,
                packageURL: URL(fileURLWithPath: "/tmp/\(name).anglesite", isDirectory: true),
                isValid: true,
                missingSentinels: []
            )
        }

        @Test("first refresh publishes the top-N in MRU order, dropping the rest")
        func firstRefreshPublishesTopN() async throws {
            let backend = RecordingBackend()
            let updater = RelevantEntitiesUpdater(backend: backend, maxCount: 3)
            let outcome = try await updater.refresh([
                site("a", "A"), site("b", "B"), site("c", "C"), site("d", "D"),
            ])

            #expect(outcome == .init(published: 3, skipped: false))
            let batches = await backend.updatedBatches
            #expect(batches.count == 1)
            #expect(batches[0].map(\.id) == ["a", "b", "c"])
        }

        @Test("an unchanged top-N id list skips the backend call")
        func unchangedTopNSkips() async throws {
            let backend = RecordingBackend()
            let updater = RelevantEntitiesUpdater(backend: backend, maxCount: 3)
            _ = try await updater.refresh([site("a", "A"), site("b", "B"), site("c", "C")])
            let outcome = try await updater.refresh([site("a", "A"), site("b", "B"), site("c", "C")])

            #expect(outcome == .init(published: 3, skipped: true))
            let batches = await backend.updatedBatches
            #expect(batches.count == 1) // second refresh did not call the backend
        }

        @Test("a reorder of the lead sites re-publishes")
        func reorderOfLeadRepublishes() async throws {
            let backend = RecordingBackend()
            let updater = RelevantEntitiesUpdater(backend: backend, maxCount: 3)
            _ = try await updater.refresh([site("a", "A"), site("b", "B"), site("c", "C")])
            let outcome = try await updater.refresh([site("b", "B"), site("a", "A"), site("c", "C")])

            #expect(outcome == .init(published: 3, skipped: false))
            let batches = await backend.updatedBatches
            #expect(batches.count == 2)
            #expect(batches[1].map(\.id) == ["b", "a", "c"])
        }

        @Test("a reorder below the top-N is skipped")
        func reorderBelowTopNSkips() async throws {
            let backend = RecordingBackend()
            let updater = RelevantEntitiesUpdater(backend: backend, maxCount: 3)
            _ = try await updater.refresh([site("a", "A"), site("b", "B"), site("c", "C"), site("d", "D")])
            // d and e swap below the top-3 — top-3 id list (a,b,c) is unchanged.
            let outcome = try await updater.refresh([site("a", "A"), site("b", "B"), site("c", "C"), site("e", "E")])

            #expect(outcome == .init(published: 3, skipped: true))
            let batches = await backend.updatedBatches
            #expect(batches.count == 1)
        }

        @Test("an empty snapshot clears once, then dedups")
        func emptyClearsOnceThenDedups() async throws {
            let backend = RecordingBackend()
            let updater = RelevantEntitiesUpdater(backend: backend, maxCount: 3)
            _ = try await updater.refresh([site("a", "A")])
            let cleared = try await updater.refresh([])
            let again = try await updater.refresh([])

            #expect(cleared == .init(published: 0, skipped: false))
            #expect(again == .init(published: 0, skipped: true))
            let batches = await backend.updatedBatches
            #expect(batches.count == 2)          // initial push + one clear
            #expect(batches[1].isEmpty)
        }

        @Test("a backend throw leaves lastPushedIDs unchanged so the next refresh retries")
        func backendThrowRetries() async throws {
            actor ThrowOnceBackend: RelevantEntitiesBackend {
                private var calls = 0
                private(set) var succeededBatches: [[SiteEntity]] = []
                func update(_ entities: [SiteEntity]) async throws {
                    calls += 1
                    if calls == 1 { throw CancellationError() }
                    succeededBatches.append(entities)
                }
            }
            let backend = ThrowOnceBackend()
            let updater = RelevantEntitiesUpdater(backend: backend, maxCount: 3)

            await #expect(throws: CancellationError.self) {
                _ = try await updater.refresh([site("a", "A"), site("b", "B")])
            }
            // Same snapshot: because the first push threw, the id list was not recorded,
            // so this is NOT deduped — it retries and succeeds.
            let outcome = try await updater.refresh([site("a", "A"), site("b", "B")])
            #expect(outcome == .init(published: 2, skipped: false))
            let batches = await backend.succeededBatches
            #expect(batches.count == 1)
            #expect(batches[0].map(\.id) == ["a", "b"])
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer && xcrun swift test --package-path . --filter RelevantEntitiesUpdaterTests`
Expected: FAIL — compile error, `cannot find 'RelevantEntitiesUpdater' / 'RelevantEntitiesBackend' in scope`.

- [ ] **Step 3: Write the minimal implementation**

Create `Sources/AnglesiteIntents/RelevantEntitiesUpdater.swift` (include only the protocol + actor in this step; the live backend is added in Task 2):

```swift
import AppIntents
import Foundation
import AnglesiteCore

/// Pluggable seam over the system `RelevantEntities` suggestion surface, so
/// `RelevantEntitiesUpdaterTests` can verify the top-N/dedup behavior without touching the
/// live App Intents relevance API. Mirrors `SpotlightIndexBackend`.
public protocol RelevantEntitiesBackend: Sendable {
    func update(_ entities: [SiteEntity]) async throws
}

/// Publishes the top-N most-recently-used sites to macOS 27's "relevant entities" suggestion
/// surface (distinct from the searchable index `SpotlightIndexer` maintains). Single entry
/// point: `refresh(_:)`, driven by `SiteStore.changeStream()` (see `AnglesiteIntents.bootstrap`).
///
/// `refresh` is diff-based on an **ordered** id list: it records the top-N ids published on the
/// last successful call and skips the backend when the new top-N ids match in the same order — so
/// a reorder of the lead sites re-publishes, while churn below the top-N (or an identical
/// snapshot) is a no-op. `lastPushedIDs` advances only on success, so a thrown backend error
/// replays on the next snapshot.
public actor RelevantEntitiesUpdater {
    public static let shared = RelevantEntitiesUpdater(backend: LiveRelevantEntitiesBackend())

    /// Result returned to callers (today: tests only) so they can assert the diff outcome.
    public struct Outcome: Sendable, Equatable {
        public let published: Int
        public let skipped: Bool

        public init(published: Int, skipped: Bool) {
            self.published = published
            self.skipped = skipped
        }
    }

    private let backend: any RelevantEntitiesBackend
    private let maxCount: Int
    private var lastPushedIDs: [String] = []

    public init(backend: any RelevantEntitiesBackend, maxCount: Int = 3) {
        self.backend = backend
        self.maxCount = maxCount
    }

    @discardableResult
    public func refresh(_ sites: [SiteStore.Site]) async throws -> Outcome {
        let top = Array(sites.prefix(maxCount))
        let ids = top.map(\.id)
        guard ids != lastPushedIDs else {
            return Outcome(published: top.count, skipped: true)
        }
        try await backend.update(top.map(SiteEntity.init))
        lastPushedIDs = ids
        return Outcome(published: top.count, skipped: false)
    }
}
```

Note: the `LiveRelevantEntitiesBackend` referenced by `.shared` does not exist yet — it is added in Task 2. **Until then the package will not compile**, so verify Task 1 with the test filter only is impossible. To keep Task 1 independently green, add a temporary minimal stub at the bottom of the file in this step, then replace its body in Task 2:

```swift
/// Production backend — real `RelevantEntities` call wired in Task 2.
struct LiveRelevantEntitiesBackend: RelevantEntitiesBackend {
    func update(_ entities: [SiteEntity]) async throws {}
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer && xcrun swift test --package-path . --filter RelevantEntitiesUpdaterTests`
Expected: PASS — 6 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteIntents/RelevantEntitiesUpdater.swift Tests/AnglesiteIntentsTests/RelevantEntitiesUpdaterTests.swift
git commit -m "$(cat <<'EOF'
feat(#124): RelevantEntitiesUpdater core for most-recent-site suggestions

Top-N (default 3) MRU transform with order-sensitive dedup, behind a
RelevantEntitiesBackend seam. Live backend is a stub here; the real
RelevantEntities call lands next.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Live backend + bootstrap wiring

Replace the stub with the real `RelevantEntities` call (CI-portability gated), then drive the updater from `SiteStore.changeStream()` in `bootstrap`. The system surface has no unit-test seam, so this task's gate is a clean package build plus the unchanged Task 1 suite.

**Files:**
- Modify: `Sources/AnglesiteIntents/RelevantEntitiesUpdater.swift` (replace the `LiveRelevantEntitiesBackend.update` body)
- Modify: `Sources/AnglesiteIntents/Bootstrap.swift` (add logger + change-stream consumer)

**Interfaces:**
- Consumes: `RelevantEntitiesUpdater.shared` (Task 1), `SiteStore.shared.changeStream() -> AsyncStream<[SiteStore.Site]>` (`Sources/AnglesiteCore/SiteStore.swift:237`).
- Produces: no new public API; wires existing pieces together.

- [ ] **Step 1: Confirm the real `RelevantEntities` API signature against the Xcode 27 SDK**

This is a genuine SDK-discovery step (the exact `updateEntities(_:for:)` shape is unverified). Locate the symbol:

Run:
```bash
SDK=$(xcrun --sdk macosx --show-sdk-path)
grep -rn "struct RelevantEntities\|func updateEntities" \
  "$(dirname "$SDK")"/../../../Library/Frameworks/AppIntents.framework 2>/dev/null
# Fallback — search the module interface across the toolchain:
find /Applications/Xcode-beta.app -name "AppIntents.swiftinterface" 2>/dev/null \
  -exec grep -l "RelevantEntities" {} \;
```
Expected: the declaration of `RelevantEntities` and its `updateEntities` method, revealing the `for:` parameter type (e.g. a context/`Date`/collection argument). Record the exact signature; the Step 2 call must match it.

If the symbol is **not found** (older/locally-unavailable SDK), keep the call inside the `#if compiler(>=6.4)` block from Step 2 — on toolchains without the symbol the body compiles out to a no-op, which is acceptable (CI never exercises the live surface).

- [ ] **Step 2: Implement the live backend**

In `Sources/AnglesiteIntents/RelevantEntitiesUpdater.swift`, replace the temporary stub body. Use the signature confirmed in Step 1; the form below is the expected shape from #124's verified inventory (`RelevantEntities.shared.updateEntities(_:for:)`) — adjust the `for:` argument to match what Step 1 found:

```swift
/// Production backend. The only place the live App Intents relevance API is called. Gated with
/// `#if compiler(>=6.4)` so `AnglesiteIntents` still builds on CI's older toolchain (#128); on
/// that path it is a no-op, which is fine — CI never drives the system suggestion surface. The
/// type stays defined unconditionally because `RelevantEntitiesUpdater.shared` and `bootstrap`
/// reference it on every toolchain.
struct LiveRelevantEntitiesBackend: RelevantEntitiesBackend {
    func update(_ entities: [SiteEntity]) async throws {
        #if compiler(>=6.4)
        try await RelevantEntities.shared.updateEntities(entities, for: SiteEntity.self)
        #endif
    }
}
```

If Step 1 revealed a different `for:` argument (e.g. a relevance context object rather than the entity type), substitute it here verbatim. Keep the `#if compiler(>=6.4)` guard regardless.

- [ ] **Step 3: Wire the change-stream consumer into `bootstrap`**

In `Sources/AnglesiteIntents/Bootstrap.swift`:

Add a logger alongside the existing two (near line 6):

```swift
private let relevantLog = Logger(subsystem: "dev.anglesite.app", category: "relevant-entities")
```

Then, inside `AnglesiteIntents.bootstrap(contentGraph:)`, after the content-graph change handler block (the `await contentGraph.setChangeHandler { ... }` closure, around line 95) and **before** the `do { try await SiteStore.shared.load() }` block, insert:

```swift
        // Surface the top-N most-recently-used sites to macOS 27's Siri/Spotlight "relevant
        // entities" suggestions (B.1 / #124). Driven off `changeStream()` rather than the
        // Spotlight `changeHandler` because relevance must track MRU *reordering* (site opens
        // bump order via `touch()`, which the data-only `changeHandler` deliberately skips —
        // SiteStore.swift). `changeStream()` yields the current snapshot on subscribe, on data
        // changes, and on reorders, so the initial set publishes without a separate kick.
        let relevant = RelevantEntitiesUpdater.shared
        Task {
            for await sites in SiteStore.shared.changeStream() {
                do {
                    let outcome = try await relevant.refresh(sites)
                    relevantLog.info("relevant published=\(outcome.published, privacy: .public) skipped=\(outcome.skipped, privacy: .public)")
                } catch {
                    relevantLog.error("relevant refresh failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
```

- [ ] **Step 4: Build the package and re-run the Task 1 suite**

Run:
```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcrun swift build --package-path .
xcrun swift test --package-path . --filter RelevantEntitiesUpdaterTests
```
Expected: build succeeds; 6 tests pass, 0 failures. (The bootstrap wiring has no unit test — the system relevance surface has no seam, exactly like the live Spotlight path.)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteIntents/RelevantEntitiesUpdater.swift Sources/AnglesiteIntents/Bootstrap.swift
git commit -m "$(cat <<'EOF'
feat(#124): publish most-recent sites to RelevantEntities suggestions

Wire LiveRelevantEntitiesBackend to the real App Intents relevance API
(compiler-gated for CI) and drive RelevantEntitiesUpdater from
SiteStore.changeStream() in bootstrap, so MRU reorders refresh the
Siri/Spotlight suggestion set.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Full-suite regression + issue note

Confirm the change doesn't break the wider intents suite, and leave a trail on #124.

**Files:** none (verification + issue comment).

- [ ] **Step 1: Run the full AnglesiteIntents test target**

Run:
```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcrun swift test --package-path . --filter AnglesiteIntentsTests
```
Expected: all `AppIntents` suites pass (the prior baseline was 145 `@Test`; this adds 6 → 151), 0 failures.

- [ ] **Step 2: Verify the relevance code path is reachable from bootstrap**

Run: `grep -n "RelevantEntitiesUpdater\|changeStream" Sources/AnglesiteIntents/Bootstrap.swift`
Expected: the `RelevantEntitiesUpdater.shared` + `SiteStore.shared.changeStream()` consumer block is present.

- [ ] **Step 3: Push the branch and note progress on the issue**

```bash
git push -u origin worktree-124-relevant-entities
gh issue comment 124 --body "RelevantEntities item implemented on branch \`worktree-124-relevant-entities\`: RelevantEntitiesUpdater publishes the top-3 MRU sites to the macOS 27 relevant-entities suggestion surface, driven off SiteStore.changeStream() (covers data changes + MRU reorders). Remaining #124 items unchanged: SyncableEntity (#71-gated) and the WWDC publishing/dev-tooling schema re-scan."
```

---

## Self-Review

**Spec coverage:**
- Top-N MRU signal (default 3) → Task 1 (`maxCount: Int = 3`, `prefix(maxCount)`).
- Drive off `changeStream()`, no `SiteStore` change → Task 2 Step 3.
- New code isolated in `AnglesiteIntents`, mirrors `SpotlightIndexer` → Tasks 1–2, file structure.
- Order-sensitive dedup / retry-on-throw posture → Task 1 (`lastPushedIDs` ordered compare, advance-on-success) + tests `reorderOfLeadRepublishes`, `reorderBelowTopNSkips`, `backendThrowRetries`.
- Empty-set clears stale suggestions then dedups → Task 1 test `emptyClearsOnceThenDedups`.
- Backend seam isolates the SDK call → Task 1 protocol + Task 2 `LiveRelevantEntitiesBackend`.
- Risk 1 (exact API) → Task 2 Step 1 discovery step.
- Risk 2 (CI toolchain gating) → Task 2 Step 2 `#if compiler(>=6.4)`.
- Error logging, swallow-in-loop → Task 2 Step 3 consumer.
- Scope: #124 stays open for SyncableEntity + schema re-scan → Task 3 Step 3 comment.

**Placeholder scan:** none — all code blocks complete. The one discovery step (Task 2 Step 1) is a genuine external-SDK confirmation with concrete commands and a defined fallback, not a deferred decision.

**Type consistency:** `RelevantEntitiesBackend.update(_:)`, `RelevantEntitiesUpdater.refresh(_:)`, `Outcome(published:skipped:)`, `lastPushedIDs`, `maxCount`, `LiveRelevantEntitiesBackend` used identically across Tasks 1–2. `SiteStore.Site` init and `SiteEntity.init(_ site:)` match the current source. `changeStream()` returns `AsyncStream<[SiteStore.Site]>` per `SiteStore.swift:237`.
