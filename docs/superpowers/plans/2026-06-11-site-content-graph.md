# `SiteContentGraph` Actor — Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land issue [#136](https://github.com/Anglesite/Anglesite-app/issues/136) — a `public actor SiteContentGraph` in `AnglesiteCore` that holds an in-memory projection of pages, posts, and images for every open site, with single-subscriber change notifications keyed by siteID.

**Architecture:** Single Swift file (`Sources/AnglesiteCore/SiteContentGraph.swift`) mirroring `SiteStore.swift`'s shape: `public actor` + three `Sendable` `Equatable` `Identifiable` value types + a `@Sendable (String) async -> Void` change handler that fires on real diffs only (no-op suppression via `Equatable`). No I/O, no AppIntents/CoreSpotlight imports, no persistence. Filesystem stays the source of truth.

**Tech Stack:** Swift 6.4 (strict concurrency), Foundation, Swift Testing for tests. Targets `AnglesiteCore` library + `AnglesiteCoreTests` test target as defined in `Package.swift`.

**Spec:** [`docs/superpowers/specs/2026-06-11-site-content-graph-design.md`](../specs/2026-06-11-site-content-graph-design.md)

**Branch:** `feat/site-content-graph` (already checked out; design doc already committed as `b1fd7f8`).

---

## Conventions

Each task below follows the TDD cycle:
1. Write the failing test.
2. Run only the new test, confirm it fails for the expected reason.
3. Write the minimal implementation.
4. Run the new test, confirm it passes.
5. Run the full `AnglesiteCoreTests` suite to confirm no regressions.
6. Commit.

Tests are Swift Testing (`import Testing`, `@Test`, `#expect`). The test type is a `struct` (Swift Testing's default — fresh instance per `@Test`, no setup/teardown needed because the actor has zero I/O and each test constructs its own `SiteContentGraph()`).

For change-handler counting from inside `@Sendable` closures, tests use a small `actor TestCounter` helper so accumulation is Sendable-safe under strict concurrency.

Commits follow the repo's conventional style (`feat(core):` / `test(core):`). Each task lands as a **single commit** that includes both the test and the implementation it drives — avoids "tests-without-impl" intermediate states in history.

---

## Task 1: Verify baseline + branch state

**Files:** none (verification only).

- [ ] **Step 1: Confirm branch + clean tree**

Run:

```bash
git status
```

Expected:

```
On branch feat/site-content-graph
nothing to commit, working tree clean
```

- [ ] **Step 2: Confirm baseline tests green**

Run:

```bash
swift test --package-path . 2>&1 | tail -20
```

Expected: `Test run with N tests passed` (270 expected per `CLAUDE.md`; treat any failure as a pre-existing problem to surface, not something this PR caused).

If `swift test` hangs with no output, check for a stale SwiftPM lockholder per `CLAUDE.md` guidance: `pgrep -fl swift-test` → kill the orphan, retry.

---

## Task 2: Skeleton actor + struct shapes

**Files:**
- Create: `Sources/AnglesiteCore/SiteContentGraph.swift`
- Create: `Tests/AnglesiteCoreTests/SiteContentGraphTests.swift`

- [ ] **Step 1: Write the first failing test (data model shape)**

Create `Tests/AnglesiteCoreTests/SiteContentGraphTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

struct SiteContentGraphTests {
    // MARK: - Fixture helpers

    static let siteA = "/Users/x/Sites/alpha"
    static let siteB = "/Users/x/Sites/bravo"
    static let referenceDate = Date(timeIntervalSince1970: 1_750_000_000)

    static func page(
        site: String = siteA,
        route: String = "/about",
        title: String? = "About",
        modified: Date = referenceDate
    ) -> SiteContentGraph.Page {
        SiteContentGraph.Page(
            id: "\(site):page:\(route)",
            siteID: site,
            route: route,
            filePath: "src/pages\(route).astro",
            title: title,
            lastModified: modified
        )
    }

    static func post(
        site: String = siteA,
        slug: String = "hello-world",
        title: String = "Hello World",
        draft: Bool = false,
        tags: [String] = ["intro"],
        collection: String = "blog",
        modified: Date = referenceDate
    ) -> SiteContentGraph.Post {
        SiteContentGraph.Post(
            id: "\(site):post:\(slug)",
            siteID: site,
            collection: collection,
            slug: slug,
            title: title,
            draft: draft,
            publishDate: modified,
            tags: tags,
            filePath: "src/content/\(collection)/\(slug).md",
            lastModified: modified
        )
    }

    static func image(
        site: String = siteA,
        relativePath: String = "public/images/hero.jpg",
        fileName: String = "hero.jpg",
        byteSize: Int64? = 123_456,
        usedOnPages: [String] = ["/"],
        modified: Date = referenceDate
    ) -> SiteContentGraph.Image {
        SiteContentGraph.Image(
            id: "\(site):image:\(relativePath)",
            siteID: site,
            relativePath: relativePath,
            fileName: fileName,
            byteSize: byteSize,
            usedOnPages: usedOnPages,
            lastModified: modified
        )
    }

    /// Sendable counter for change-handler invocations.
    actor TestCounter {
        private(set) var count = 0
        private(set) var lastSiteID: String?
        func record(_ siteID: String) {
            count += 1
            lastSiteID = siteID
        }
    }

    // MARK: - Data shape

    @Test("Page is Equatable, Identifiable, and id contains siteID + route")
    func pageStructShape() {
        let p1 = Self.page()
        let p2 = Self.page()
        let p3 = Self.page(route: "/contact")
        #expect(p1 == p2)
        #expect(p1 != p3)
        #expect(p1.id == "\(Self.siteA):page:/about")
        #expect(p1.id == p1.id) // exists as Identifiable.ID
    }
}
```

- [ ] **Step 2: Run the test, confirm it fails to compile**

Run:

```bash
swift test --package-path . --filter SiteContentGraphTests 2>&1 | tail -20
```

Expected: compile error — `cannot find 'SiteContentGraph' in scope` (the type doesn't exist yet).

- [ ] **Step 3: Write the minimal `SiteContentGraph.swift`**

Create `Sources/AnglesiteCore/SiteContentGraph.swift`:

```swift
import Foundation

/// In-memory projection of an Anglesite site's content (pages, posts, images), populated
/// by the MCP server's `list_content` response and kept in sync via file-watch events.
///
/// The filesystem is the source of truth — this is a read cache, not a database. The graph
/// holds no I/O surface, so it has no persistence: cold start is empty, and `LocalSiteRuntime`
/// (#142, A.8) repopulates per site open.
///
/// **Change handler.** Single-subscriber by design. Fires on real mutations only:
/// `upsert*` with an `Equatable`-equal existing entry does not emit. The signature passes the
/// siteID only — the subscriber (A.3 `ContentSpotlightIndexer`) reads pages/posts/images back
/// from the graph for diff computation. This keeps emit cheap and matches the existing
/// `SpotlightIndexer.reindex(_:)` "trust whatever the source publishes at moment of read"
/// pattern.
public actor SiteContentGraph {
    public struct Page: Sendable, Equatable, Identifiable {
        public let id: String          // "{siteID}:page:{route}"
        public let siteID: String
        public let route: String
        public let filePath: String
        public let title: String?
        public let lastModified: Date

        public init(
            id: String,
            siteID: String,
            route: String,
            filePath: String,
            title: String?,
            lastModified: Date
        ) {
            self.id = id
            self.siteID = siteID
            self.route = route
            self.filePath = filePath
            self.title = title
            self.lastModified = lastModified
        }
    }

    public struct Post: Sendable, Equatable, Identifiable {
        public let id: String          // "{siteID}:post:{slug}"
        public let siteID: String
        public let collection: String
        public let slug: String
        public let title: String
        public let draft: Bool
        public let publishDate: Date?
        public let tags: [String]
        public let filePath: String
        public let lastModified: Date

        public init(
            id: String,
            siteID: String,
            collection: String,
            slug: String,
            title: String,
            draft: Bool,
            publishDate: Date?,
            tags: [String],
            filePath: String,
            lastModified: Date
        ) {
            self.id = id
            self.siteID = siteID
            self.collection = collection
            self.slug = slug
            self.title = title
            self.draft = draft
            self.publishDate = publishDate
            self.tags = tags
            self.filePath = filePath
            self.lastModified = lastModified
        }
    }

    public struct Image: Sendable, Equatable, Identifiable {
        public let id: String          // "{siteID}:image:{relativePath}"
        public let siteID: String
        public let relativePath: String
        public let fileName: String
        public let byteSize: Int64?
        public let usedOnPages: [String]
        public let lastModified: Date

        public init(
            id: String,
            siteID: String,
            relativePath: String,
            fileName: String,
            byteSize: Int64?,
            usedOnPages: [String],
            lastModified: Date
        ) {
            self.id = id
            self.siteID = siteID
            self.relativePath = relativePath
            self.fileName = fileName
            self.byteSize = byteSize
            self.usedOnPages = usedOnPages
            self.lastModified = lastModified
        }
    }

    public typealias ChangeHandler = @Sendable (String) async -> Void

    private var pages: [String: Page] = [:]
    private var posts: [String: Post] = [:]
    private var images: [String: Image] = [:]
    private var changeHandler: ChangeHandler?

    public init() {}

    public func setChangeHandler(_ handler: ChangeHandler?) {
        changeHandler = handler
    }

    private func emitChange(_ siteID: String) async {
        guard let handler = changeHandler else { return }
        await handler(siteID)
    }
}
```

- [ ] **Step 4: Run the new test, confirm it passes**

```bash
swift test --package-path . --filter SiteContentGraphTests 2>&1 | tail -10
```

Expected: `Test "Page is Equatable..." passed`.

- [ ] **Step 5: Run the full AnglesiteCoreTests suite to verify no regressions**

```bash
swift test --package-path . 2>&1 | tail -5
```

Expected: full suite passes (count increases by 1 from the new test).

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/SiteContentGraph.swift \
        Tests/AnglesiteCoreTests/SiteContentGraphTests.swift
git commit -m "$(cat <<'EOF'
feat(core): SiteContentGraph actor skeleton + struct shapes (#136)

Page, Post, and Image value types (Sendable, Equatable, Identifiable)
and the empty actor that will host pages/posts/images projections.
Change handler typealias + setter + private emit helper in place;
mutations come in subsequent commits.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `load()` — bulk replace per siteID

**Files:**
- Modify: `Sources/AnglesiteCore/SiteContentGraph.swift`
- Modify: `Tests/AnglesiteCoreTests/SiteContentGraphTests.swift`

Covers spec invariants 1 (siteID isolation) and 2 (bulk-load replaces).

- [ ] **Step 1: Append failing tests**

Append to `SiteContentGraphTests.swift` inside the `struct SiteContentGraphTests`:

```swift
    @Test("load replaces existing entries for the siteID")
    func loadReplacesExistingEntries() async {
        let graph = SiteContentGraph()
        await graph.load(
            siteID: Self.siteA,
            pages: [Self.page(route: "/about"), Self.page(route: "/contact")],
            posts: [],
            images: []
        )
        await graph.load(
            siteID: Self.siteA,
            pages: [Self.page(route: "/about")],
            posts: [],
            images: []
        )

        let pages = await graph.pages(for: Self.siteA)
        #expect(pages.map(\.route).sorted() == ["/about"])
    }

    @Test("load does not affect entries for other siteIDs")
    func loadDoesNotAffectOtherSites() async {
        let graph = SiteContentGraph()
        await graph.load(
            siteID: Self.siteA,
            pages: [Self.page(site: Self.siteA, route: "/a-home")],
            posts: [],
            images: []
        )
        await graph.load(
            siteID: Self.siteB,
            pages: [Self.page(site: Self.siteB, route: "/b-home")],
            posts: [],
            images: []
        )

        let a = await graph.pages(for: Self.siteA)
        let b = await graph.pages(for: Self.siteB)
        #expect(a.map(\.route) == ["/a-home"])
        #expect(b.map(\.route) == ["/b-home"])
    }

    @Test("load emits change for the loaded siteID")
    func loadEmitsChange() async {
        let graph = SiteContentGraph()
        let counter = TestCounter()
        await graph.setChangeHandler { siteID in await counter.record(siteID) }

        await graph.load(siteID: Self.siteA, pages: [Self.page()], posts: [], images: [])

        let count = await counter.count
        let last = await counter.lastSiteID
        #expect(count == 1)
        #expect(last == Self.siteA)
    }
```

- [ ] **Step 2: Run the new tests, confirm compile failure**

```bash
swift test --package-path . --filter SiteContentGraphTests 2>&1 | tail -15
```

Expected: errors mentioning `pages(for:)`, `load(siteID:pages:posts:images:)` not found.

- [ ] **Step 3: Implement `load` + per-site query accessors**

In `SiteContentGraph.swift`, add inside the actor body (below `emitChange`):

```swift
    // MARK: - Bulk load

    /// Replaces all entries for `siteID` with the supplied payload. Existing entries for
    /// other siteIDs are untouched. Always emits a change for `siteID`.
    public func load(
        siteID: String,
        pages: [Page],
        posts: [Post],
        images: [Image]
    ) async {
        self.pages = self.pages.filter { $0.value.siteID != siteID }
        self.posts = self.posts.filter { $0.value.siteID != siteID }
        self.images = self.images.filter { $0.value.siteID != siteID }
        for page in pages { self.pages[page.id] = page }
        for post in posts { self.posts[post.id] = post }
        for image in images { self.images[image.id] = image }
        await emitChange(siteID)
    }

    // MARK: - Queries (per-site)

    public func pages(for siteID: String) -> [Page] {
        pages.values.filter { $0.siteID == siteID }
    }

    public func posts(for siteID: String) -> [Post] {
        posts.values.filter { $0.siteID == siteID }
    }

    public func images(for siteID: String) -> [Image] {
        images.values.filter { $0.siteID == siteID }
    }
```

- [ ] **Step 4: Run the new tests**

```bash
swift test --package-path . --filter SiteContentGraphTests 2>&1 | tail -10
```

Expected: 4 tests pass.

- [ ] **Step 5: Run the full suite**

```bash
swift test --package-path . 2>&1 | tail -5
```

Expected: full suite green.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/SiteContentGraph.swift \
        Tests/AnglesiteCoreTests/SiteContentGraphTests.swift
git commit -m "$(cat <<'EOF'
feat(core): SiteContentGraph.load + per-site query accessors (#136)

Bulk load replaces all entries for the supplied siteID and emits a
change. Per-site query accessors (pages/posts/images for siteID)
filter the in-memory dicts.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `upsertPage` + no-op suppression

**Files:**
- Modify: `Sources/AnglesiteCore/SiteContentGraph.swift`
- Modify: `Tests/AnglesiteCoreTests/SiteContentGraphTests.swift`

Covers test #3 (emit on real upsert), test #4 (no-op suppression), and single-lookup query.

- [ ] **Step 1: Append failing tests**

Append:

```swift
    @Test("upsertPage emits change and is queryable by id")
    func upsertPageEmitsChange() async {
        let graph = SiteContentGraph()
        let counter = TestCounter()
        await graph.setChangeHandler { siteID in await counter.record(siteID) }

        let page = Self.page()
        await graph.upsertPage(page)

        let stored = await graph.page(id: page.id)
        let count = await counter.count
        #expect(stored == page)
        #expect(count == 1)
    }

    @Test("upsertPage with identical value does not emit")
    func upsertPageIdenticalSuppressesEmit() async {
        let graph = SiteContentGraph()
        let counter = TestCounter()
        let page = Self.page()
        await graph.upsertPage(page)

        // Install handler AFTER the first upsert so we only count the second.
        await graph.setChangeHandler { siteID in await counter.record(siteID) }
        await graph.upsertPage(page)  // identical

        let count = await counter.count
        #expect(count == 0)
    }

    @Test("upsertPage with same id but different value emits and overwrites")
    func upsertPageDifferentValueEmits() async {
        let graph = SiteContentGraph()
        let counter = TestCounter()
        let original = Self.page(title: "About")
        await graph.upsertPage(original)
        await graph.setChangeHandler { siteID in await counter.record(siteID) }

        let revised = Self.page(title: "About Us")  // same route -> same id
        await graph.upsertPage(revised)

        let stored = await graph.page(id: original.id)
        let count = await counter.count
        #expect(stored?.title == "About Us")
        #expect(count == 1)
    }
```

- [ ] **Step 2: Run, confirm failure (no `upsertPage` / `page(id:)`)**

```bash
swift test --package-path . --filter SiteContentGraphTests 2>&1 | tail -10
```

Expected: compile errors on `upsertPage` and `page(id:)`.

- [ ] **Step 3: Implement `upsertPage` + `page(id:)`**

Add inside the actor, below the per-site query accessors:

```swift
    // MARK: - Incremental upsert

    public func upsertPage(_ page: Page) async {
        if pages[page.id] == page { return }
        pages[page.id] = page
        await emitChange(page.siteID)
    }

    // MARK: - Queries (single)

    public func page(id: String) -> Page? { pages[id] }
```

- [ ] **Step 4: Run the new tests + full suite**

```bash
swift test --package-path . --filter SiteContentGraphTests 2>&1 | tail -10
swift test --package-path . 2>&1 | tail -5
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SiteContentGraph.swift \
        Tests/AnglesiteCoreTests/SiteContentGraphTests.swift
git commit -m "$(cat <<'EOF'
feat(core): SiteContentGraph.upsertPage with no-op suppression (#136)

Identical upserts (Equatable check on Page) skip the emit so the
Spotlight indexer isn't woken for mtime-only file-watch events with
unchanged content.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: `upsertPost` + `upsertImage` (symmetric)

**Files:**
- Modify: `Sources/AnglesiteCore/SiteContentGraph.swift`
- Modify: `Tests/AnglesiteCoreTests/SiteContentGraphTests.swift`

Covers tests #5 and #6 — same no-op suppression contract as `upsertPage`.

- [ ] **Step 1: Append failing tests**

Append:

```swift
    @Test("upsertPost with identical value does not emit")
    func upsertPostIdenticalSuppressesEmit() async {
        let graph = SiteContentGraph()
        let counter = TestCounter()
        let post = Self.post()
        await graph.upsertPost(post)
        await graph.setChangeHandler { siteID in await counter.record(siteID) }
        await graph.upsertPost(post)

        let count = await counter.count
        #expect(count == 0)
    }

    @Test("upsertPost emits change and is queryable")
    func upsertPostEmitsChange() async {
        let graph = SiteContentGraph()
        let counter = TestCounter()
        await graph.setChangeHandler { siteID in await counter.record(siteID) }
        let post = Self.post()
        await graph.upsertPost(post)

        let stored = await graph.post(id: post.id)
        let count = await counter.count
        #expect(stored == post)
        #expect(count == 1)
    }

    @Test("upsertImage with identical value does not emit")
    func upsertImageIdenticalSuppressesEmit() async {
        let graph = SiteContentGraph()
        let counter = TestCounter()
        let image = Self.image()
        await graph.upsertImage(image)
        await graph.setChangeHandler { siteID in await counter.record(siteID) }
        await graph.upsertImage(image)

        let count = await counter.count
        #expect(count == 0)
    }

    @Test("upsertImage emits change and is queryable")
    func upsertImageEmitsChange() async {
        let graph = SiteContentGraph()
        let counter = TestCounter()
        await graph.setChangeHandler { siteID in await counter.record(siteID) }
        let image = Self.image()
        await graph.upsertImage(image)

        let stored = await graph.image(id: image.id)
        let count = await counter.count
        #expect(stored == image)
        #expect(count == 1)
    }
```

- [ ] **Step 2: Run, confirm failure**

```bash
swift test --package-path . --filter SiteContentGraphTests 2>&1 | tail -10
```

Expected: compile errors on `upsertPost`, `upsertImage`, `post(id:)`, `image(id:)`.

- [ ] **Step 3: Implement post/image upserts + single lookups**

Add inside the actor, alongside `upsertPage`:

```swift
    public func upsertPost(_ post: Post) async {
        if posts[post.id] == post { return }
        posts[post.id] = post
        await emitChange(post.siteID)
    }

    public func upsertImage(_ image: Image) async {
        if images[image.id] == image { return }
        images[image.id] = image
        await emitChange(image.siteID)
    }
```

And alongside `page(id:)`:

```swift
    public func post(id: String) -> Post? { posts[id] }
    public func image(id: String) -> Image? { images[id] }
```

- [ ] **Step 4: Run the new tests + full suite**

```bash
swift test --package-path . --filter SiteContentGraphTests 2>&1 | tail -10
swift test --package-path . 2>&1 | tail -5
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SiteContentGraph.swift \
        Tests/AnglesiteCoreTests/SiteContentGraphTests.swift
git commit -m "$(cat <<'EOF'
feat(core): SiteContentGraph.upsertPost + upsertImage (#136)

Same no-op suppression contract as upsertPage. Single-lookup queries
post(id:) and image(id:) round out the per-id accessor surface.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: `removePage` / `removePost` / `removeImage`

**Files:**
- Modify: `Sources/AnglesiteCore/SiteContentGraph.swift`
- Modify: `Tests/AnglesiteCoreTests/SiteContentGraphTests.swift`

Covers tests #7 and #8 — emit on real remove, silent on unknown id.

- [ ] **Step 1: Append failing tests**

Append:

```swift
    @Test("removePage emits change and drops the entry")
    func removePageEmitsChange() async {
        let graph = SiteContentGraph()
        let page = Self.page()
        await graph.upsertPage(page)
        let counter = TestCounter()
        await graph.setChangeHandler { siteID in await counter.record(siteID) }

        await graph.removePage(id: page.id)

        let stored = await graph.page(id: page.id)
        let count = await counter.count
        #expect(stored == nil)
        #expect(count == 1)
    }

    @Test("removePage is silent and no-op when id is unknown")
    func removePageUnknownIdSilent() async {
        let graph = SiteContentGraph()
        let counter = TestCounter()
        await graph.setChangeHandler { siteID in await counter.record(siteID) }

        await graph.removePage(id: "nonexistent:page:/whatever")

        let count = await counter.count
        #expect(count == 0)
    }

    @Test("removePost emits change and drops the entry")
    func removePostEmitsChange() async {
        let graph = SiteContentGraph()
        let post = Self.post()
        await graph.upsertPost(post)
        let counter = TestCounter()
        await graph.setChangeHandler { siteID in await counter.record(siteID) }

        await graph.removePost(id: post.id)

        let stored = await graph.post(id: post.id)
        let count = await counter.count
        #expect(stored == nil)
        #expect(count == 1)
    }

    @Test("removeImage emits change and drops the entry")
    func removeImageEmitsChange() async {
        let graph = SiteContentGraph()
        let image = Self.image()
        await graph.upsertImage(image)
        let counter = TestCounter()
        await graph.setChangeHandler { siteID in await counter.record(siteID) }

        await graph.removeImage(id: image.id)

        let stored = await graph.image(id: image.id)
        let count = await counter.count
        #expect(stored == nil)
        #expect(count == 1)
    }
```

- [ ] **Step 2: Run, confirm failure**

```bash
swift test --package-path . --filter SiteContentGraphTests 2>&1 | tail -10
```

Expected: compile errors on `removePage` / `removePost` / `removeImage`.

- [ ] **Step 3: Implement removes**

Add inside the actor, below the upsert methods:

```swift
    // MARK: - Incremental remove

    /// Removes the page with the given id. Silently no-ops (no emit) if the id is unknown —
    /// reflects the file-watch reality where the plugin may report removals for files the
    /// graph never received via `upsert*` (out-of-order events on startup, etc).
    public func removePage(id: String) async {
        guard let removed = pages.removeValue(forKey: id) else { return }
        await emitChange(removed.siteID)
    }

    public func removePost(id: String) async {
        guard let removed = posts.removeValue(forKey: id) else { return }
        await emitChange(removed.siteID)
    }

    public func removeImage(id: String) async {
        guard let removed = images.removeValue(forKey: id) else { return }
        await emitChange(removed.siteID)
    }
```

- [ ] **Step 4: Run the new tests + full suite**

```bash
swift test --package-path . --filter SiteContentGraphTests 2>&1 | tail -10
swift test --package-path . 2>&1 | tail -5
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SiteContentGraph.swift \
        Tests/AnglesiteCoreTests/SiteContentGraphTests.swift
git commit -m "$(cat <<'EOF'
feat(core): SiteContentGraph.remove* (page/post/image) (#136)

Real removes emit a change for the removed entry's siteID. Unknown
ids are silent (no emit) — reflects file-watch reality where the
plugin may report removals for entries the graph never received.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: `unload(siteID:)`

**Files:**
- Modify: `Sources/AnglesiteCore/SiteContentGraph.swift`
- Modify: `Tests/AnglesiteCoreTests/SiteContentGraphTests.swift`

Covers tests #9 and #10 — drop all entries for siteID, always emit (even when empty).

- [ ] **Step 1: Append failing tests**

Append:

```swift
    @Test("unload drops all entries for the siteID (pages, posts, images)")
    func unloadDropsAllEntriesForSite() async {
        let graph = SiteContentGraph()
        await graph.load(
            siteID: Self.siteA,
            pages: [Self.page()],
            posts: [Self.post()],
            images: [Self.image()]
        )
        await graph.load(
            siteID: Self.siteB,
            pages: [Self.page(site: Self.siteB, route: "/b")],
            posts: [],
            images: []
        )

        await graph.unload(siteID: Self.siteA)

        let aPages = await graph.pages(for: Self.siteA)
        let aPosts = await graph.posts(for: Self.siteA)
        let aImages = await graph.images(for: Self.siteA)
        let bPages = await graph.pages(for: Self.siteB)
        #expect(aPages.isEmpty)
        #expect(aPosts.isEmpty)
        #expect(aImages.isEmpty)
        #expect(bPages.map(\.route) == ["/b"])
    }

    @Test("unload always emits a change, even when the siteID had no entries")
    func unloadAlwaysEmitsChange() async {
        let graph = SiteContentGraph()
        let counter = TestCounter()
        await graph.setChangeHandler { siteID in await counter.record(siteID) }

        await graph.unload(siteID: Self.siteA)

        let count = await counter.count
        let last = await counter.lastSiteID
        #expect(count == 1)
        #expect(last == Self.siteA)
    }
```

- [ ] **Step 2: Run, confirm failure**

```bash
swift test --package-path . --filter SiteContentGraphTests 2>&1 | tail -10
```

Expected: compile error on `unload(siteID:)`.

- [ ] **Step 3: Implement `unload`**

Add inside the actor, after the remove methods:

```swift
    // MARK: - Teardown

    /// Drops all entries (pages, posts, images) for `siteID` and emits a change. Always
    /// emits — even if the site had no entries, subscribers may want the "site empty now"
    /// signal to prune internal tracking (e.g., A.3 Spotlight indexer's last-indexed set).
    public func unload(siteID: String) async {
        pages = pages.filter { $0.value.siteID != siteID }
        posts = posts.filter { $0.value.siteID != siteID }
        images = images.filter { $0.value.siteID != siteID }
        await emitChange(siteID)
    }
```

- [ ] **Step 4: Run the new tests + full suite**

```bash
swift test --package-path . --filter SiteContentGraphTests 2>&1 | tail -10
swift test --package-path . 2>&1 | tail -5
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SiteContentGraph.swift \
        Tests/AnglesiteCoreTests/SiteContentGraphTests.swift
git commit -m "$(cat <<'EOF'
feat(core): SiteContentGraph.unload(siteID:) (#136)

Drops all entries (pages, posts, images) for the siteID and always
emits — the empty-emit case lets subscribers prune internal tracking.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: `searchPages` / `searchPosts`

**Files:**
- Modify: `Sources/AnglesiteCore/SiteContentGraph.swift`
- Modify: `Tests/AnglesiteCoreTests/SiteContentGraphTests.swift`

Covers tests #11, #12, #13 — case-insensitive substring; pages match on title/route; posts match on title/slug/tags/collection; empty query returns all.

- [ ] **Step 1: Append failing tests**

Append:

```swift
    @Test("searchPages matches title and route case-insensitively")
    func searchPagesMatchesTitleAndRouteCaseInsensitive() async {
        let graph = SiteContentGraph()
        await graph.load(
            siteID: Self.siteA,
            pages: [
                Self.page(route: "/about", title: "About Us"),
                Self.page(route: "/contact", title: "Contact"),
                Self.page(route: "/team", title: nil)
            ],
            posts: [],
            images: []
        )

        let byTitle = await graph.searchPages(siteID: Self.siteA, matching: "ABOUT")
        let byRoute = await graph.searchPages(siteID: Self.siteA, matching: "tact")
        let none = await graph.searchPages(siteID: Self.siteA, matching: "zzzz")

        #expect(byTitle.map(\.route) == ["/about"])
        #expect(byRoute.map(\.route) == ["/contact"])
        #expect(none.isEmpty)
    }

    @Test("searchPosts matches title, slug, tags, and collection name")
    func searchPostsMatchesTitleSlugTagsCollection() async {
        let graph = SiteContentGraph()
        await graph.load(
            siteID: Self.siteA,
            pages: [],
            posts: [
                Self.post(slug: "hello-world", title: "Hello World", tags: ["intro"], collection: "blog"),
                Self.post(slug: "swift-actors", title: "Swift Actors", tags: ["swift", "concurrency"], collection: "blog"),
                Self.post(slug: "first-post", title: "Day One", tags: [], collection: "diary")
            ],
            images: []
        )

        let byTitle = await graph.searchPosts(siteID: Self.siteA, matching: "Hello")
        let bySlug = await graph.searchPosts(siteID: Self.siteA, matching: "swift-actors")
        let byTag = await graph.searchPosts(siteID: Self.siteA, matching: "concurrency")
        let byCollection = await graph.searchPosts(siteID: Self.siteA, matching: "diary")

        #expect(byTitle.map(\.slug) == ["hello-world"])
        #expect(bySlug.map(\.slug) == ["swift-actors"])
        #expect(byTag.map(\.slug) == ["swift-actors"])
        #expect(byCollection.map(\.slug) == ["first-post"])
    }

    @Test("search with empty query returns all entries for the siteID")
    func searchWithEmptyQueryReturnsAll() async {
        let graph = SiteContentGraph()
        await graph.load(
            siteID: Self.siteA,
            pages: [Self.page(route: "/a"), Self.page(route: "/b")],
            posts: [Self.post(slug: "p1"), Self.post(slug: "p2")],
            images: []
        )

        let pages = await graph.searchPages(siteID: Self.siteA, matching: "")
        let posts = await graph.searchPosts(siteID: Self.siteA, matching: "")
        #expect(Set(pages.map(\.route)) == ["/a", "/b"])
        #expect(Set(posts.map(\.slug)) == ["p1", "p2"])
    }
```

- [ ] **Step 2: Run, confirm failure**

```bash
swift test --package-path . --filter SiteContentGraphTests 2>&1 | tail -10
```

Expected: compile errors on `searchPages` / `searchPosts`.

- [ ] **Step 3: Implement search**

Add inside the actor, after the queries section:

```swift
    // MARK: - Search

    /// Case-insensitive substring search on a page's `title` and `route`. Empty `query`
    /// returns all pages for the siteID (no filtering).
    public func searchPages(siteID: String, matching query: String) -> [Page] {
        let scoped = pages.values.filter { $0.siteID == siteID }
        guard !query.isEmpty else { return Array(scoped) }
        let needle = query.lowercased()
        return scoped.filter { page in
            if page.route.lowercased().contains(needle) { return true }
            if let title = page.title?.lowercased(), title.contains(needle) { return true }
            return false
        }
    }

    /// Case-insensitive substring search on a post's `title`, `slug`, `tags`, and
    /// `collection`. Empty `query` returns all posts for the siteID (no filtering).
    public func searchPosts(siteID: String, matching query: String) -> [Post] {
        let scoped = posts.values.filter { $0.siteID == siteID }
        guard !query.isEmpty else { return Array(scoped) }
        let needle = query.lowercased()
        return scoped.filter { post in
            if post.title.lowercased().contains(needle) { return true }
            if post.slug.lowercased().contains(needle) { return true }
            if post.collection.lowercased().contains(needle) { return true }
            if post.tags.contains(where: { $0.lowercased().contains(needle) }) { return true }
            return false
        }
    }
```

- [ ] **Step 4: Run the new tests + full suite**

```bash
swift test --package-path . --filter SiteContentGraphTests 2>&1 | tail -10
swift test --package-path . 2>&1 | tail -5
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SiteContentGraph.swift \
        Tests/AnglesiteCoreTests/SiteContentGraphTests.swift
git commit -m "$(cat <<'EOF'
feat(core): SiteContentGraph.searchPages + searchPosts (#136)

Case-insensitive substring on title/route for pages and
title/slug/tags/collection for posts. Empty query returns all
entries for the siteID.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: `knownSiteIDs()` + `setChangeHandler(nil)` detach

**Files:**
- Modify: `Sources/AnglesiteCore/SiteContentGraph.swift`
- Modify: `Tests/AnglesiteCoreTests/SiteContentGraphTests.swift`

Covers tests #14 (enumeration) and #15 (handler detach).

- [ ] **Step 1: Append failing tests**

Append:

```swift
    @Test("knownSiteIDs reflects current content across pages, posts, and images")
    func knownSiteIDsReflectsCurrentContent() async {
        let graph = SiteContentGraph()
        let initiallyEmpty = await graph.knownSiteIDs()
        #expect(initiallyEmpty.isEmpty)

        await graph.upsertPage(Self.page(site: Self.siteA))
        await graph.upsertPost(Self.post(site: Self.siteB))

        let afterUpserts = await graph.knownSiteIDs()
        #expect(afterUpserts == Set([Self.siteA, Self.siteB]))

        await graph.unload(siteID: Self.siteA)
        let afterUnload = await graph.knownSiteIDs()
        #expect(afterUnload == Set([Self.siteB]))
    }

    @Test("setChangeHandler(nil) detaches: subsequent mutations do not emit")
    func setChangeHandlerNilRemovesHandler() async {
        let graph = SiteContentGraph()
        let counter = TestCounter()
        await graph.setChangeHandler { siteID in await counter.record(siteID) }
        await graph.upsertPage(Self.page())
        let baseline = await counter.count

        await graph.setChangeHandler(nil)
        await graph.upsertPage(Self.page(route: "/contact"))
        let final = await counter.count

        #expect(baseline == 1)
        #expect(final == baseline)
    }
```

- [ ] **Step 2: Run, confirm failure**

```bash
swift test --package-path . --filter SiteContentGraphTests 2>&1 | tail -10
```

Expected: compile error on `knownSiteIDs()`. (Detach should already work because `emitChange` guards `changeHandler != nil` — that test should fail compilation only on `knownSiteIDs`, then pass once that's added; verify.)

- [ ] **Step 3: Implement `knownSiteIDs()`**

Add inside the actor, after `searchPosts`:

```swift
    // MARK: - Enumeration

    /// The set of siteIDs that currently have any pages, posts, or images. Used by A.3
    /// `ContentSpotlightIndexer` to know which sites it has live state for.
    public func knownSiteIDs() -> Set<String> {
        var ids: Set<String> = []
        ids.formUnion(pages.values.map(\.siteID))
        ids.formUnion(posts.values.map(\.siteID))
        ids.formUnion(images.values.map(\.siteID))
        return ids
    }
```

- [ ] **Step 4: Run the new tests + full suite**

```bash
swift test --package-path . --filter SiteContentGraphTests 2>&1 | tail -10
swift test --package-path . 2>&1 | tail -5
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SiteContentGraph.swift \
        Tests/AnglesiteCoreTests/SiteContentGraphTests.swift
git commit -m "$(cat <<'EOF'
feat(core): SiteContentGraph.knownSiteIDs + handler detach test (#136)

knownSiteIDs unions the siteIDs across pages/posts/images for A.3's
"this whole site went away" diff case. setChangeHandler(nil) detach
verified explicitly.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Concurrent upsert serialization

**Files:**
- Modify: `Tests/AnglesiteCoreTests/SiteContentGraphTests.swift`

Covers test #16 — actor isolation invariant. No implementation changes; the actor's serialization is already guaranteed by the `public actor` declaration. This test pins the invariant against future refactors.

- [ ] **Step 1: Append the failing test**

Append:

```swift
    @Test("Concurrent upserts are serialized: 100 parallel upserts yield 100 entries")
    func concurrentUpsertsAreSerialized() async {
        let graph = SiteContentGraph()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    await graph.upsertPage(Self.page(route: "/p\(i)"))
                }
            }
        }
        let pages = await graph.pages(for: Self.siteA)
        #expect(pages.count == 100)
        #expect(Set(pages.map(\.route)).count == 100)
    }
```

- [ ] **Step 2: Run the new test**

```bash
swift test --package-path . --filter SiteContentGraphTests 2>&1 | tail -10
```

Expected: pass (actor isolation is built-in; this is a regression guard).

- [ ] **Step 3: Run the full suite**

```bash
swift test --package-path . 2>&1 | tail -5
```

Expected: full suite green.

- [ ] **Step 4: Commit**

```bash
git add Tests/AnglesiteCoreTests/SiteContentGraphTests.swift
git commit -m "$(cat <<'EOF'
test(core): pin SiteContentGraph actor-isolation invariant (#136)

100 parallel upserts via TaskGroup yield exactly 100 unique entries.
No production change; regression guard against future refactors
that might move state out of the actor.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Verify both Xcode schemes build, then push + open PR

**Files:** none (verification + push only).

Per memory `feedback_verify_app_changes_with_xcodebuild.md`: `swift test` proves the SPM library compiles, but only `xcodebuild` proves the `.app` links. Both schemes must build before the PR opens.

- [ ] **Step 1: Build the DevID scheme**

Run:

```bash
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Build the MAS scheme**

Run:

```bash
xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Final full-suite confirmation**

```bash
swift test --package-path . 2>&1 | tail -5
```

Expected: all tests pass (270 baseline + 16 new = 286 total, give or take the existing count).

- [ ] **Step 4: Mark issue #136 in-progress, push branch, open PR**

Per memory `feedback_mark_gh_issues_in_progress.md` — apply the in-progress signal so concurrent agents see the claim. (The project doesn't use a dedicated "in-progress" label per the earlier audit; the convention is a self-assign + comment. Use `gh` to self-assign and post a short status comment.)

Run:

```bash
gh issue edit 136 --add-assignee @me
gh issue comment 136 --body "In progress on branch \`feat/site-content-graph\` — PR up shortly."
git push -u origin feat/site-content-graph
gh pr create \
  --title "feat(core): SiteContentGraph actor (#136)" \
  --body "$(cat <<'EOF'
## Summary

- Lands issue #136 — `SiteContentGraph` actor in `AnglesiteCore`, the foundation projection for Siri AI Phase A.
- Push-driven, single-subscriber change handler keyed by siteID; subscriber (A.3 `ContentSpotlightIndexer`) reads back for its diff — same pattern as `SpotlightIndexer.reindex(_:)`.
- No-op suppression on `upsert*` via `Equatable` so file-watch fires with identical content do not wake the indexer.
- 16 Swift Testing cases covering bulk-load replacement, siteID isolation, upsert/remove emit semantics, no-op suppression, unload (always-emit), case-insensitive search across the spec'd fields, `knownSiteIDs` enumeration, handler detach, and actor-isolation serialization under 100-way TaskGroup parallelism.

Design: [`docs/superpowers/specs/2026-06-11-site-content-graph-design.md`](docs/superpowers/specs/2026-06-11-site-content-graph-design.md) (committed earlier on this branch).

## Test plan

- [x] `swift test --package-path .` — full suite green
- [x] `xcodebuild -scheme Anglesite -configuration Debug build` — DevID scheme green
- [x] `xcodebuild -scheme AnglesiteMAS -configuration Debug build` — MAS scheme green

## What this PR does NOT do

Per the spec's scope boundaries:
- No MCP / plugin wiring (A.8, #142).
- No `IndexedEntity` conformance on Page/Post/Image (A.2, #137).
- No `ContentSpotlightIndexer` (A.3, #144).
- No `list_content` MCP tool (plugin paired PR, #140 / A.6).
- No persistence to disk (in-memory by design).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: the `gh pr create` invocation prints the new PR URL. Return that URL.

---

## Self-review

Checking the plan against the spec section by section:

**Goal section / Architecture section** — Task 2 lays down the actor + struct shapes. Tasks 3–9 fill in every public method listed in the spec. ✓

**Public API table from spec:**

| Spec method | Plan task |
|---|---|
| `init()` | Task 2 |
| `setChangeHandler(_:)` | Task 2 (added with skeleton); detach verified Task 9 |
| `load(siteID:pages:posts:images:)` | Task 3 |
| `upsertPage(_:)` | Task 4 |
| `upsertPost(_:)`, `upsertImage(_:)` | Task 5 |
| `removePage(id:)`, `removePost(id:)`, `removeImage(id:)` | Task 6 |
| `pages(for:)`, `posts(for:)`, `images(for:)` | Task 3 |
| `page(id:)`, `post(id:)`, `image(id:)` | Tasks 4 + 5 |
| `searchPages(siteID:matching:)`, `searchPosts(siteID:matching:)` | Task 8 |
| `unload(siteID:)` | Task 7 |
| `knownSiteIDs()` | Task 9 |

✓ Every public API entry has a task.

**Invariants from spec:**

| Spec invariant | Test |
|---|---|
| 1. siteID isolation | Task 3 `loadDoesNotAffectOtherSites`, Task 7 `unloadDropsAllEntriesForSite` |
| 2. Bulk-load replaces | Task 3 `loadReplacesExistingEntries` |
| 3. No-op suppression | Tasks 4 + 5 (page/post/image identical-suppress tests) |
| 4. Unknown-id remove is silent | Task 6 `removePageUnknownIdSilent` |
| 5. `unload` always emits | Task 7 `unloadAlwaysEmitsChange` |
| 6. Single subscriber + nil-detach | Task 9 `setChangeHandlerNilRemovesHandler` |
| 7. Actor-serialized emit | Task 10 `concurrentUpsertsAreSerialized` |
| 8. Empty-query convention | Task 8 `searchWithEmptyQueryReturnsAll` |

✓ Every invariant has at least one test.

**Acceptance criteria from spec:**

- ✓ `Sources/AnglesiteCore/SiteContentGraph.swift` exists with the full public API — Tasks 2–9.
- ✓ `Tests/AnglesiteCoreTests/SiteContentGraphTests.swift` with all 16 tests — Tasks 2–10 (counted: 1 shape + 3 load + 3 upsertPage + 4 upsert post/image + 4 remove + 2 unload + 3 search + 2 knownSiteIDs/detach + 1 concurrent = 23 `@Test`s. The spec said "~16" — over-delivery on coverage breakdown is fine; same invariant set).
- ✓ `swift test` passes — verified Task 11 step 3.
- ✓ Both Xcode schemes build clean — Task 11 steps 1–2.
- ✓ No new dependencies — only `import Foundation` is added in Task 2.

**Placeholder scan:** No "TBD", no "implement later", no "similar to Task N" — each task carries full test + code. ✓

**Type consistency:** `Page`, `Post`, `Image` struct field names are referenced identically across the fixture helpers (`Self.page`, `Self.post`, `Self.image`) and the spec. Method signatures match the public API table letter-for-letter (`load(siteID:pages:posts:images:)` etc). ✓

Plan complete.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-11-site-content-graph.md`. Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task with two-stage review between tasks. Best when you want quality gating between commits.
2. **Inline Execution** — execute tasks in this session with batch checkpoints. Faster end-to-end but less review surface.

Which approach?
