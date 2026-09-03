# Content Entities Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land issue [#137](https://github.com/Anglesite/Anglesite-app/issues/137) — three `AppEntity` types (`PageEntity`, `PostEntity`, `ImageEntity`) and their `EntityStringQuery` companions in `AnglesiteIntents`, plus the `ContentGraphOverride` test seam and the `AnglesiteIntents.bootstrap` signature change that threads a single `SiteContentGraph` instance through `AppDependencyManager`.

**Architecture:** Three thin entity structs in `Sources/AnglesiteIntents/ContentEntities.swift` (each `AppEntity, IndexedEntity, Identifiable, Sendable`) initialize from the corresponding `SiteContentGraph` value type. Their query companions read live from the graph: `@Dependency` in production, `ContentGraphOverride.$scoped` `@TaskLocal` in tests — mirrors the `SiteOperationsOverride` precedent at `Sources/AnglesiteIntents/SiteOperationsOverride.swift`. `Bootstrap.swift` gains a `contentGraph:` parameter; `AnglesiteApp.AppDelegate` constructs the single graph instance and passes it in.

**Tech Stack:** Swift 6.4 (strict concurrency), AppIntents framework, Foundation, Swift Testing. Targets `AnglesiteIntents` library + `AnglesiteIntentsTests` test target as defined in `Package.swift`.

**Spec:** [`docs/superpowers/specs/2026-06-11-content-entities-design.md`](../specs/2026-06-11-content-entities-design.md)

**Branch:** `feat/content-entities` (already checked out; design doc committed as `edfb7a2`).

---

## Conventions

Each task follows the TDD cycle:
1. Write the failing test.
2. Run only the new test, confirm it fails for the expected reason.
3. Write the minimal implementation.
4. Run the new test, confirm it passes.
5. Run the full `AnglesiteIntentsTests` (and `AnglesiteCoreTests` for the bootstrap signature task) target to confirm no regressions.
6. Commit.

Tests are Swift Testing (`import Testing`, `@Test`, `#expect`). They live in `Tests/AnglesiteIntentsTests/` and **must be nested** under the existing `AppIntentsTests` umbrella suite for `.serialized` execution — see `Tests/AnglesiteIntentsTests/AppIntentsTests.swift` for the parent declaration. The shape is:

```swift
extension AppIntentsTests {
    @Suite("NameOfThing")
    struct NameOfThingTests {
        @Test("description") func name() async throws { ... }
    }
}
```

Each test constructs a fresh `SiteContentGraph`, seeds it with `await graph.load(...)`, then binds the override and calls the query:

```swift
try await ContentGraphOverride.$scoped.withValue(graph) {
    let query = PageEntityQuery()
    let results = try await query.entities(matching: "about")
    #expect(results.map(\.route) == ["/about"])
}
```

Commits follow the repo's conventional style (`feat(intents):` / `test(intents):` / `refactor(intents):`). Each task lands as a **single commit** pairing test + implementation.

**Pre-existing baseline:** Running `swift test --package-path .` shows 2 failures unrelated to this branch: `MCPClientHTTPEndToEndTests` (`.sessionLost`) and `AppliesEditEndToEndTests` (`.reconnecting`). Both are MCP-transport e2e tests gated on plugin/node infra. Do not investigate them — they fail identically on `main`. Use `--filter AnglesiteIntentsTests` for per-task verification.

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
On branch feat/content-entities
nothing to commit, working tree clean
```

- [ ] **Step 2: Confirm `AnglesiteIntentsTests` is green at baseline**

```bash
swift test --package-path . --filter AnglesiteIntentsTests 2>&1 | tail -5
```

Expected: `Test run with N tests in M suites passed` (27 tests across 10 suites baseline per the `AppIntents` umbrella).

If `swift test` hangs with no output, check for a stale SwiftPM lockholder per CLAUDE.md: `pgrep -fl swift-test` → kill the orphan, retry.

---

## Task 2: `ContentGraphOverride` test seam

**Files:**
- Create: `Sources/AnglesiteIntents/ContentGraphOverride.swift`

This is a tiny test-seam file with no implementation logic — no test of its own is needed (it's exercised by every subsequent task's tests via `$scoped.withValue(...)`).

- [ ] **Step 1: Create the file**

```swift
import AnglesiteCore

/// Test-only escape hatch around `@Dependency` resolution of `SiteContentGraph`.
///
/// `@Dependency` is gated by the AppIntents runtime to its "intent perform flow" and to the
/// query-resolution flow it drives. Direct unit-test invocations (where there's no `intentsd`
/// / registered-app context) crash with a fatal error from `AppDependencyManager`. Tests bind
/// this `@TaskLocal` to a throwaway graph before invoking a query method; queries read
/// `ContentGraphOverride.scoped ?? graph` so the override takes precedence when set. In
/// production the override is always `nil` and resolution flows through `@Dependency` as designed.
///
/// Mirrors `SiteOperationsOverride.scoped` (see #104, #127).
public enum ContentGraphOverride {
    @TaskLocal public static var scoped: SiteContentGraph?
}
```

- [ ] **Step 2: Confirm the package builds**

```bash
swift build --package-path . 2>&1 | tail -5
```

Expected: `Build complete!` (no test runs needed for this commit).

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteIntents/ContentGraphOverride.swift
git commit -m "$(cat <<'EOF'
feat(intents): ContentGraphOverride test seam (#137)

@TaskLocal escape hatch around @Dependency resolution of
SiteContentGraph for unit tests. Mirrors SiteOperationsOverride.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `PageEntity` + `PageEntityQuery` + tests

**Files:**
- Create: `Sources/AnglesiteIntents/ContentEntities.swift`
- Create: `Tests/AnglesiteIntentsTests/ContentEntitiesTests.swift`

This task introduces both files. Subsequent tasks (Post/Image) append to them.

- [ ] **Step 1: Write the failing test file**

Create `Tests/AnglesiteIntentsTests/ContentEntitiesTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore
@testable import AnglesiteIntents

/// Covers issue #137 acceptance criteria for PageEntity / PostEntity / ImageEntity and their
/// queries. All tests bind `ContentGraphOverride.$scoped` so `@Dependency` is bypassed.
extension AppIntentsTests {
    // MARK: - Fixtures

    static let aSite = "/Users/x/Sites/alpha"
    static let bSite = "/Users/x/Sites/bravo"
    static let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    static func gPage(
        site: String = aSite,
        route: String = "/about",
        title: String? = "About",
        modified: Date = t0
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

    static func gPost(
        site: String = aSite,
        slug: String = "hello-world",
        title: String = "Hello World",
        draft: Bool = false,
        tags: [String] = ["intro"],
        collection: String = "blog",
        modified: Date = t0
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

    static func gImage(
        site: String = aSite,
        relativePath: String = "public/images/hero.jpg",
        fileName: String = "hero.jpg",
        byteSize: Int64? = 1024,
        modified: Date = t0
    ) -> SiteContentGraph.Image {
        SiteContentGraph.Image(
            id: "\(site):image:\(relativePath)",
            siteID: site,
            relativePath: relativePath,
            fileName: fileName,
            byteSize: byteSize,
            usedOnPages: [],
            lastModified: modified
        )
    }

    @Suite("PageEntityQuery")
    struct PageEntityQueryTests {

        @Test("PageEntity displayRepresentation uses title when present")
        func displayRepresentation_usesTitleWhenPresent() {
            let entity = PageEntity(AppIntentsTests.gPage(title: "About"))
            #expect(entity.displayName == "About")
            #expect(entity.route == "/about")
            #expect(entity.siteID == AppIntentsTests.aSite)
        }

        @Test("PageEntity displayName falls back to route when title is nil")
        func displayRepresentation_fallsBackToRoute_whenTitleNil() {
            let entity = PageEntity(AppIntentsTests.gPage(title: nil))
            #expect(entity.displayName == "/about")
        }

        @Test("entities(for:) returns matching ids")
        func entitiesForIds_returnsMatching() async throws {
            let graph = SiteContentGraph()
            let p = AppIntentsTests.gPage()
            await graph.upsertPage(p)

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await PageEntityQuery().entities(for: [p.id])
                #expect(results.map(\.id) == [p.id])
            }
        }

        @Test("entities(for:) silently skips unknown ids")
        func entitiesForIds_skipsUnknown() async throws {
            let graph = SiteContentGraph()
            let p = AppIntentsTests.gPage()
            await graph.upsertPage(p)

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await PageEntityQuery().entities(for: [p.id, "nonexistent:page:/zzz"])
                #expect(results.map(\.id) == [p.id])
            }
        }

        @Test("entities(for:) with empty array returns empty")
        func entitiesForIds_emptyArrayReturnsEmpty() async throws {
            let graph = SiteContentGraph()
            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await PageEntityQuery().entities(for: [])
                #expect(results.isEmpty)
            }
        }

        @Test("entities(matching:) matches title case-insensitively")
        func entitiesMatching_byTitleCaseInsensitive() async throws {
            let graph = SiteContentGraph()
            await graph.upsertPage(AppIntentsTests.gPage(route: "/about", title: "About Us"))
            await graph.upsertPage(AppIntentsTests.gPage(route: "/contact", title: "Contact"))

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await PageEntityQuery().entities(matching: "ABOUT")
                #expect(results.map(\.route) == ["/about"])
            }
        }

        @Test("entities(matching:) matches route case-insensitively")
        func entitiesMatching_byRoute() async throws {
            let graph = SiteContentGraph()
            await graph.upsertPage(AppIntentsTests.gPage(route: "/contact", title: "Contact"))
            await graph.upsertPage(AppIntentsTests.gPage(route: "/about", title: "About"))

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await PageEntityQuery().entities(matching: "tact")
                #expect(results.map(\.route) == ["/contact"])
            }
        }

        @Test("entities(matching:) sorts results by lastModified DESC")
        func entitiesMatching_sortedByLastModifiedDesc() async throws {
            let graph = SiteContentGraph()
            let older = AppIntentsTests.gPage(route: "/about-old", title: "About Old", modified: AppIntentsTests.t0)
            let newer = AppIntentsTests.gPage(route: "/about-new", title: "About New", modified: AppIntentsTests.t0.addingTimeInterval(60))
            await graph.upsertPage(older)
            await graph.upsertPage(newer)

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await PageEntityQuery().entities(matching: "about")
                #expect(results.map(\.route) == ["/about-new", "/about-old"])
            }
        }

        @Test("suggestedEntities() returns all pages across sites, sorted by lastModified DESC")
        func suggestedEntities_returnsAllAcrossSites() async throws {
            let graph = SiteContentGraph()
            let oldA = AppIntentsTests.gPage(site: AppIntentsTests.aSite, route: "/a-home", modified: AppIntentsTests.t0)
            let newB = AppIntentsTests.gPage(site: AppIntentsTests.bSite, route: "/b-home", modified: AppIntentsTests.t0.addingTimeInterval(60))
            await graph.upsertPage(oldA)
            await graph.upsertPage(newB)

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await PageEntityQuery().suggestedEntities()
                #expect(results.map(\.route) == ["/b-home", "/a-home"])
            }
        }

        @Test("suggestedEntities() on empty graph returns empty")
        func suggestedEntities_emptyGraphReturnsEmpty() async throws {
            let graph = SiteContentGraph()
            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await PageEntityQuery().suggestedEntities()
                #expect(results.isEmpty)
            }
        }

        @Test("defaultResult() returns nil for v0")
        func defaultResult_returnsNil() async {
            let graph = SiteContentGraph()
            await ContentGraphOverride.$scoped.withValue(graph) {
                let result = await PageEntityQuery().defaultResult()
                #expect(result == nil)
            }
        }
    }
}
```

- [ ] **Step 2: Run, confirm compile failure**

```bash
swift test --package-path . --filter AnglesiteIntentsTests 2>&1 | tail -15
```

Expected: errors like `cannot find 'PageEntity' in scope`, `cannot find 'PageEntityQuery' in scope`.

- [ ] **Step 3: Create the implementation file**

Create `Sources/AnglesiteIntents/ContentEntities.swift`:

```swift
import AppIntents
import AnglesiteCore
import Foundation

// MARK: - PageEntity

/// An Anglesite page, addressable by Siri/Shortcuts. Backed live by `SiteContentGraph` —
/// no cache, so the entity never goes stale relative to the graph state.
public struct PageEntity: AppEntity, IndexedEntity, Identifiable, Sendable {
    public let id: String            // "{siteID}:page:{route}" — same as SiteContentGraph.Page.id
    public let displayName: String   // title ?? route
    public let route: String
    public let siteID: String

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Page" }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)", subtitle: "\(route)")
    }

    public static var defaultQuery = PageEntityQuery()

    public init(_ page: SiteContentGraph.Page) {
        self.id = page.id
        self.displayName = page.title ?? page.route
        self.route = page.route
        self.siteID = page.siteID
    }
}

public struct PageEntityQuery: EntityStringQuery {
    @Dependency private var graph: SiteContentGraph

    public init() {}

    private var resolved: SiteContentGraph {
        // Tests bind ContentGraphOverride.scoped; production goes through @Dependency.
        // The `??` short-circuits, so `graph` is only touched when no override is bound.
        ContentGraphOverride.scoped ?? graph
    }

    public func entities(for identifiers: [String]) async throws -> [PageEntity] {
        let g = resolved
        var found: [PageEntity] = []
        for id in identifiers {
            if let page = await g.page(id: id) {
                found.append(PageEntity(page))
            }
        }
        return found
    }

    public func entities(matching string: String) async throws -> [PageEntity] {
        let g = resolved
        var matches: [SiteContentGraph.Page] = []
        for siteID in await g.knownSiteIDs() {
            matches.append(contentsOf: await g.searchPages(siteID: siteID, matching: string))
        }
        return matches
            .sorted { $0.lastModified > $1.lastModified }
            .map(PageEntity.init)
    }

    public func suggestedEntities() async throws -> [PageEntity] {
        let g = resolved
        var all: [SiteContentGraph.Page] = []
        for siteID in await g.knownSiteIDs() {
            all.append(contentsOf: await g.pages(for: siteID))
        }
        return all
            .sorted { $0.lastModified > $1.lastModified }
            .map(PageEntity.init)
    }

    public func defaultResult() async -> PageEntity? { nil }
}
```

- [ ] **Step 4: Run the new tests + full target**

```bash
swift test --package-path . --filter PageEntityQuery 2>&1 | tail -15
swift test --package-path . --filter AnglesiteIntentsTests 2>&1 | tail -5
```

Expected: 11 PageEntityQuery tests pass; full `AnglesiteIntentsTests` target green (baseline 27 + 11 = 38).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteIntents/ContentEntities.swift \
        Tests/AnglesiteIntentsTests/ContentEntitiesTests.swift
git commit -m "$(cat <<'EOF'
feat(intents): PageEntity + PageEntityQuery (#137)

AppEntity + IndexedEntity projection over SiteContentGraph.Page.
EntityStringQuery reads live from the graph via @Dependency in
production and ContentGraphOverride.scoped in tests. 11 tests cover
display representation, id lookup (incl. silent skip on unknown),
case-insensitive title/route match, lastModified-DESC ordering, and
the empty-graph / empty-array edge cases.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `PostEntity` + `PostEntityQuery` + tests

**Files:**
- Modify: `Sources/AnglesiteIntents/ContentEntities.swift`
- Modify: `Tests/AnglesiteIntentsTests/ContentEntitiesTests.swift`

- [ ] **Step 1: Append failing tests**

In `Tests/AnglesiteIntentsTests/ContentEntitiesTests.swift`, immediately after the `PageEntityQuery` `@Suite`'s closing brace but BEFORE the outer `extension AppIntentsTests {` closing brace, append:

```swift
    @Suite("PostEntityQuery")
    struct PostEntityQueryTests {

        @Test("PostEntity displayName is the post title")
        func displayRepresentation_title() {
            let entity = PostEntity(AppIntentsTests.gPost(title: "Hello World"))
            #expect(entity.displayName == "Hello World")
            #expect(entity.slug == "hello-world")
            #expect(entity.collection == "blog")
            #expect(entity.isDraft == false)
            #expect(entity.tags == ["intro"])
        }

        @Test("PostEntity displayRepresentation subtitle includes (draft) when draft")
        func displayRepresentation_includesDraftSuffix() {
            let draft = PostEntity(AppIntentsTests.gPost(draft: true))
            let published = PostEntity(AppIntentsTests.gPost(draft: false))
            #expect(draft.isDraft == true)
            #expect(published.isDraft == false)
            // Subtitle is rendered by AppIntents from the DisplayRepresentation we returned.
            // Verify our struct still carries the boolean — Siri's rendering layer is what
            // turns it into "(draft)" via the format string we declared.
        }

        @Test("entities(for:) returns matching ids")
        func entitiesForIds_returnsMatching() async throws {
            let graph = SiteContentGraph()
            let p = AppIntentsTests.gPost()
            await graph.upsertPost(p)

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await PostEntityQuery().entities(for: [p.id])
                #expect(results.map(\.id) == [p.id])
            }
        }

        @Test("entities(for:) silently skips unknown ids")
        func entitiesForIds_skipsUnknown() async throws {
            let graph = SiteContentGraph()
            let p = AppIntentsTests.gPost()
            await graph.upsertPost(p)

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await PostEntityQuery().entities(for: [p.id, "nonexistent:post:zzz"])
                #expect(results.map(\.id) == [p.id])
            }
        }

        @Test("entities(for:) with empty array returns empty")
        func entitiesForIds_emptyArrayReturnsEmpty() async throws {
            let graph = SiteContentGraph()
            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await PostEntityQuery().entities(for: [])
                #expect(results.isEmpty)
            }
        }

        @Test("entities(matching:) matches title case-insensitively")
        func entitiesMatching_byTitleCaseInsensitive() async throws {
            let graph = SiteContentGraph()
            await graph.upsertPost(AppIntentsTests.gPost(slug: "hello-world", title: "Hello World"))
            await graph.upsertPost(AppIntentsTests.gPost(slug: "swift-actors", title: "Swift Actors"))

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await PostEntityQuery().entities(matching: "HELLO")
                #expect(results.map(\.slug) == ["hello-world"])
            }
        }

        @Test("entities(matching:) matches slug case-insensitively")
        func entitiesMatching_bySlug() async throws {
            let graph = SiteContentGraph()
            await graph.upsertPost(AppIntentsTests.gPost(slug: "swift-actors", title: "Swift Actors"))
            await graph.upsertPost(AppIntentsTests.gPost(slug: "hello-world", title: "Hello World"))

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await PostEntityQuery().entities(matching: "swift-actors")
                #expect(results.map(\.slug) == ["swift-actors"])
            }
        }

        @Test("entities(matching:) matches a tag")
        func entitiesMatching_byTag() async throws {
            let graph = SiteContentGraph()
            await graph.upsertPost(AppIntentsTests.gPost(slug: "swift-actors", title: "Swift Actors", tags: ["swift", "concurrency"]))
            await graph.upsertPost(AppIntentsTests.gPost(slug: "hello-world", title: "Hello World", tags: ["intro"]))

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await PostEntityQuery().entities(matching: "concurrency")
                #expect(results.map(\.slug) == ["swift-actors"])
            }
        }

        @Test("entities(matching:) matches collection name")
        func entitiesMatching_byCollection() async throws {
            let graph = SiteContentGraph()
            await graph.upsertPost(AppIntentsTests.gPost(slug: "first-post", title: "Day One", tags: [], collection: "diary"))
            await graph.upsertPost(AppIntentsTests.gPost(slug: "hello-world", title: "Hello World", tags: ["intro"], collection: "blog"))

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await PostEntityQuery().entities(matching: "diary")
                #expect(results.map(\.slug) == ["first-post"])
            }
        }

        @Test("entities(matching:) sorts results by lastModified DESC")
        func entitiesMatching_sortedByLastModifiedDesc() async throws {
            let graph = SiteContentGraph()
            let older = AppIntentsTests.gPost(slug: "swift-old", title: "Swift Old", modified: AppIntentsTests.t0)
            let newer = AppIntentsTests.gPost(slug: "swift-new", title: "Swift New", modified: AppIntentsTests.t0.addingTimeInterval(60))
            await graph.upsertPost(older)
            await graph.upsertPost(newer)

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await PostEntityQuery().entities(matching: "swift")
                #expect(results.map(\.slug) == ["swift-new", "swift-old"])
            }
        }

        @Test("suggestedEntities() returns all posts across sites, sorted by lastModified DESC")
        func suggestedEntities_returnsAllAcrossSites() async throws {
            let graph = SiteContentGraph()
            let oldA = AppIntentsTests.gPost(site: AppIntentsTests.aSite, slug: "a-post", modified: AppIntentsTests.t0)
            let newB = AppIntentsTests.gPost(site: AppIntentsTests.bSite, slug: "b-post", modified: AppIntentsTests.t0.addingTimeInterval(60))
            await graph.upsertPost(oldA)
            await graph.upsertPost(newB)

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await PostEntityQuery().suggestedEntities()
                #expect(results.map(\.slug) == ["b-post", "a-post"])
            }
        }

        @Test("suggestedEntities() on empty graph returns empty")
        func suggestedEntities_emptyGraphReturnsEmpty() async throws {
            let graph = SiteContentGraph()
            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await PostEntityQuery().suggestedEntities()
                #expect(results.isEmpty)
            }
        }

        @Test("defaultResult() returns nil for v0")
        func defaultResult_returnsNil() async {
            let graph = SiteContentGraph()
            await ContentGraphOverride.$scoped.withValue(graph) {
                let result = await PostEntityQuery().defaultResult()
                #expect(result == nil)
            }
        }
    }
```

- [ ] **Step 2: Run, confirm compile failure**

```bash
swift test --package-path . --filter PostEntityQuery 2>&1 | tail -15
```

Expected: compile errors on `PostEntity` and `PostEntityQuery`.

- [ ] **Step 3: Append the implementation**

In `Sources/AnglesiteIntents/ContentEntities.swift`, append AFTER the `PageEntityQuery` struct:

```swift

// MARK: - PostEntity

/// An Anglesite blog post / content-collection entry, addressable by Siri/Shortcuts.
public struct PostEntity: AppEntity, IndexedEntity, Identifiable, Sendable {
    public let id: String            // "{siteID}:post:{slug}"
    public let displayName: String   // title
    public let slug: String
    public let collection: String
    public let siteID: String
    public let isDraft: Bool
    public let tags: [String]

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Post" }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(displayName)",
            subtitle: "\(collection)/\(slug)\(isDraft ? " (draft)" : "")"
        )
    }

    public static var defaultQuery = PostEntityQuery()

    public init(_ post: SiteContentGraph.Post) {
        self.id = post.id
        self.displayName = post.title
        self.slug = post.slug
        self.collection = post.collection
        self.siteID = post.siteID
        self.isDraft = post.draft
        self.tags = post.tags
    }
}

public struct PostEntityQuery: EntityStringQuery {
    @Dependency private var graph: SiteContentGraph

    public init() {}

    private var resolved: SiteContentGraph {
        ContentGraphOverride.scoped ?? graph
    }

    public func entities(for identifiers: [String]) async throws -> [PostEntity] {
        let g = resolved
        var found: [PostEntity] = []
        for id in identifiers {
            if let post = await g.post(id: id) {
                found.append(PostEntity(post))
            }
        }
        return found
    }

    public func entities(matching string: String) async throws -> [PostEntity] {
        let g = resolved
        var matches: [SiteContentGraph.Post] = []
        for siteID in await g.knownSiteIDs() {
            matches.append(contentsOf: await g.searchPosts(siteID: siteID, matching: string))
        }
        return matches
            .sorted { $0.lastModified > $1.lastModified }
            .map(PostEntity.init)
    }

    public func suggestedEntities() async throws -> [PostEntity] {
        let g = resolved
        var all: [SiteContentGraph.Post] = []
        for siteID in await g.knownSiteIDs() {
            all.append(contentsOf: await g.posts(for: siteID))
        }
        return all
            .sorted { $0.lastModified > $1.lastModified }
            .map(PostEntity.init)
    }

    public func defaultResult() async -> PostEntity? { nil }
}
```

- [ ] **Step 4: Run the new tests + full target**

```bash
swift test --package-path . --filter PostEntityQuery 2>&1 | tail -15
swift test --package-path . --filter AnglesiteIntentsTests 2>&1 | tail -5
```

Expected: 13 PostEntityQuery tests pass; full target green (38 + 13 = 51).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteIntents/ContentEntities.swift \
        Tests/AnglesiteIntentsTests/ContentEntitiesTests.swift
git commit -m "$(cat <<'EOF'
feat(intents): PostEntity + PostEntityQuery (#137)

Mirrors PageEntityQuery's shape. Search covers title, slug, tags,
and collection name (delegated to SiteContentGraph.searchPosts). 13
tests cover the four-field search semantics, draft suffix carrying,
and the standard id-lookup / empty-graph / ordering invariants.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: `ImageEntity` + `ImageEntityQuery` + tests

**Files:**
- Modify: `Sources/AnglesiteIntents/ContentEntities.swift`
- Modify: `Tests/AnglesiteIntentsTests/ContentEntitiesTests.swift`

`ImageEntityQuery.entities(matching:)` does its substring scan locally — the graph doesn't expose `searchImages` and adding it is out of scope (per the spec's deferred follow-ups).

- [ ] **Step 1: Append failing tests**

Append inside `extension AppIntentsTests` after the `PostEntityQueryTests` `@Suite`:

```swift
    @Suite("ImageEntityQuery")
    struct ImageEntityQueryTests {

        @Test("ImageEntity displayName is the file name")
        func displayRepresentation_fileName() {
            let entity = ImageEntity(AppIntentsTests.gImage(relativePath: "public/images/hero.jpg", fileName: "hero.jpg"))
            #expect(entity.displayName == "hero.jpg")
            #expect(entity.relativePath == "public/images/hero.jpg")
            #expect(entity.siteID == AppIntentsTests.aSite)
        }

        @Test("entities(for:) returns matching ids")
        func entitiesForIds_returnsMatching() async throws {
            let graph = SiteContentGraph()
            let img = AppIntentsTests.gImage()
            await graph.upsertImage(img)

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await ImageEntityQuery().entities(for: [img.id])
                #expect(results.map(\.id) == [img.id])
            }
        }

        @Test("entities(for:) silently skips unknown ids")
        func entitiesForIds_skipsUnknown() async throws {
            let graph = SiteContentGraph()
            let img = AppIntentsTests.gImage()
            await graph.upsertImage(img)

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await ImageEntityQuery().entities(for: [img.id, "nonexistent:image:nope.png"])
                #expect(results.map(\.id) == [img.id])
            }
        }

        @Test("entities(for:) with empty array returns empty")
        func entitiesForIds_emptyArrayReturnsEmpty() async throws {
            let graph = SiteContentGraph()
            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await ImageEntityQuery().entities(for: [])
                #expect(results.isEmpty)
            }
        }

        @Test("entities(matching:) matches fileName case-insensitively")
        func entitiesMatching_byFileName() async throws {
            let graph = SiteContentGraph()
            await graph.upsertImage(AppIntentsTests.gImage(relativePath: "public/images/hero.jpg", fileName: "hero.jpg"))
            await graph.upsertImage(AppIntentsTests.gImage(relativePath: "public/images/avatar.png", fileName: "avatar.png"))

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await ImageEntityQuery().entities(matching: "HERO")
                #expect(results.map(\.relativePath) == ["public/images/hero.jpg"])
            }
        }

        @Test("entities(matching:) matches relativePath case-insensitively")
        func entitiesMatching_byRelativePath() async throws {
            let graph = SiteContentGraph()
            await graph.upsertImage(AppIntentsTests.gImage(relativePath: "public/images/hero.jpg", fileName: "hero.jpg"))
            await graph.upsertImage(AppIntentsTests.gImage(relativePath: "public/icons/star.svg", fileName: "star.svg"))

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await ImageEntityQuery().entities(matching: "icons")
                #expect(results.map(\.relativePath) == ["public/icons/star.svg"])
            }
        }

        @Test("entities(matching:) sorts results by lastModified DESC")
        func entitiesMatching_sortedByLastModifiedDesc() async throws {
            let graph = SiteContentGraph()
            let older = AppIntentsTests.gImage(relativePath: "public/images/old.jpg", fileName: "old.jpg", modified: AppIntentsTests.t0)
            let newer = AppIntentsTests.gImage(relativePath: "public/images/new.jpg", fileName: "new.jpg", modified: AppIntentsTests.t0.addingTimeInterval(60))
            await graph.upsertImage(older)
            await graph.upsertImage(newer)

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await ImageEntityQuery().entities(matching: ".jpg")
                #expect(results.map(\.relativePath) == ["public/images/new.jpg", "public/images/old.jpg"])
            }
        }

        @Test("suggestedEntities() returns all images across sites, sorted by lastModified DESC")
        func suggestedEntities_returnsAllAcrossSites() async throws {
            let graph = SiteContentGraph()
            let oldA = AppIntentsTests.gImage(site: AppIntentsTests.aSite, relativePath: "public/images/a.jpg", fileName: "a.jpg", modified: AppIntentsTests.t0)
            let newB = AppIntentsTests.gImage(site: AppIntentsTests.bSite, relativePath: "public/images/b.jpg", fileName: "b.jpg", modified: AppIntentsTests.t0.addingTimeInterval(60))
            await graph.upsertImage(oldA)
            await graph.upsertImage(newB)

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await ImageEntityQuery().suggestedEntities()
                #expect(results.map(\.relativePath) == ["public/images/b.jpg", "public/images/a.jpg"])
            }
        }

        @Test("suggestedEntities() on empty graph returns empty")
        func suggestedEntities_emptyGraphReturnsEmpty() async throws {
            let graph = SiteContentGraph()
            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await ImageEntityQuery().suggestedEntities()
                #expect(results.isEmpty)
            }
        }

        @Test("defaultResult() returns nil for v0")
        func defaultResult_returnsNil() async {
            let graph = SiteContentGraph()
            await ContentGraphOverride.$scoped.withValue(graph) {
                let result = await ImageEntityQuery().defaultResult()
                #expect(result == nil)
            }
        }
    }
```

- [ ] **Step 2: Run, confirm compile failure**

```bash
swift test --package-path . --filter ImageEntityQuery 2>&1 | tail -15
```

Expected: compile errors on `ImageEntity` and `ImageEntityQuery`.

- [ ] **Step 3: Append implementation**

In `Sources/AnglesiteIntents/ContentEntities.swift`, append AFTER `PostEntityQuery`:

```swift

// MARK: - ImageEntity

/// An image asset under `public/images/` (or anywhere referenced), addressable by Siri/Shortcuts.
public struct ImageEntity: AppEntity, IndexedEntity, Identifiable, Sendable {
    public let id: String            // "{siteID}:image:{relativePath}"
    public let displayName: String   // fileName
    public let relativePath: String
    public let siteID: String

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Image" }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)", subtitle: "\(relativePath)")
    }

    public static var defaultQuery = ImageEntityQuery()

    public init(_ image: SiteContentGraph.Image) {
        self.id = image.id
        self.displayName = image.fileName
        self.relativePath = image.relativePath
        self.siteID = image.siteID
    }
}

public struct ImageEntityQuery: EntityStringQuery {
    @Dependency private var graph: SiteContentGraph

    public init() {}

    private var resolved: SiteContentGraph {
        ContentGraphOverride.scoped ?? graph
    }

    public func entities(for identifiers: [String]) async throws -> [ImageEntity] {
        let g = resolved
        var found: [ImageEntity] = []
        for id in identifiers {
            if let image = await g.image(id: id) {
                found.append(ImageEntity(image))
            }
        }
        return found
    }

    /// Case-insensitive substring scan on `fileName` and `relativePath`. Done locally rather
    /// than via the graph: A.1 only shipped `searchPages` / `searchPosts`, and adding
    /// `searchImages` to the graph is out of scope for A.2 (see spec follow-ups).
    public func entities(matching string: String) async throws -> [ImageEntity] {
        let g = resolved
        let needle = string.lowercased()
        var matches: [SiteContentGraph.Image] = []
        for siteID in await g.knownSiteIDs() {
            let scoped = await g.images(for: siteID)
            matches.append(contentsOf: scoped.filter { image in
                if image.fileName.lowercased().contains(needle) { return true }
                if image.relativePath.lowercased().contains(needle) { return true }
                return false
            })
        }
        return matches
            .sorted { $0.lastModified > $1.lastModified }
            .map(ImageEntity.init)
    }

    public func suggestedEntities() async throws -> [ImageEntity] {
        let g = resolved
        var all: [SiteContentGraph.Image] = []
        for siteID in await g.knownSiteIDs() {
            all.append(contentsOf: await g.images(for: siteID))
        }
        return all
            .sorted { $0.lastModified > $1.lastModified }
            .map(ImageEntity.init)
    }

    public func defaultResult() async -> ImageEntity? { nil }
}
```

- [ ] **Step 4: Run the new tests + full target**

```bash
swift test --package-path . --filter ImageEntityQuery 2>&1 | tail -15
swift test --package-path . --filter AnglesiteIntentsTests 2>&1 | tail -5
```

Expected: 11 ImageEntityQuery tests pass; full target green (51 + 11 = 62).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteIntents/ContentEntities.swift \
        Tests/AnglesiteIntentsTests/ContentEntitiesTests.swift
git commit -m "$(cat <<'EOF'
feat(intents): ImageEntity + ImageEntityQuery (#137)

Substring search runs locally over fileName + relativePath since the
graph doesn't expose searchImages (deferred per spec). 11 tests
cover the standard id-lookup, two-field fuzzy match, and ordering
invariants.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Bootstrap signature change — register `SiteContentGraph` as a dependency

**Files:**
- Modify: `Sources/AnglesiteIntents/Bootstrap.swift`

This task changes the public API of `AnglesiteIntents.bootstrap`. The `AnglesiteApp` callsite update lives in Task 7 so the breaking change is bisectable.

`AnglesiteIntentsTests` has no existing test that calls `bootstrap()`, so no existing test needs updating (verified by `grep -rn "AnglesiteIntents.bootstrap" Sources/ Tests/` returning only `Sources/AnglesiteApp/AnglesiteApp.swift:16`).

- [ ] **Step 1: Update `Bootstrap.swift`**

Replace the entire body of `Sources/AnglesiteIntents/Bootstrap.swift` with:

```swift
import AppIntents
import AnglesiteCore
import OSLog

private let log = Logger(subsystem: "dev.anglesite.app", category: "spotlight-indexer")

/// Public entry point that registers production dependencies with `AppDependencyManager` and
/// hooks the Spotlight indexer to `SiteStore.shared`.
///
/// Async so the call site can await handler installation before driving any `SiteStore`
/// mutations — that way a caller in an async context (e.g. #101's system MCP entry from a
/// non-UI process) gets the indexer reliably set up before they touch the store.
///
/// `contentGraph` is the single, app-lifetime `SiteContentGraph` instance the app owns and
/// passes in. We register it with `AppDependencyManager` so `@Dependency private var graph:
/// SiteContentGraph` resolves to the same instance in every `PageEntityQuery` /
/// `PostEntityQuery` / `ImageEntityQuery` instantiation by the AppIntents runtime. A.1's
/// design explicitly rules out a process-wide `SiteContentGraph.shared` — ownership stays
/// with the app, threaded through here.
///
/// The kicker `try await SiteStore.shared.load()` inside is belt-and-suspenders for the
/// SwiftUI case: `AppDelegate.applicationDidFinishLaunching` can only fire-and-forget us in a
/// `Task`, which races with the launcher view's own `task` modifier. The handler is registered
/// before the load here, so the load *will* emit even if the launcher already raced ahead and
/// missed it — emission is idempotent (the indexer dedups by id set).
public enum AnglesiteIntents {
    public static func bootstrap(contentGraph: SiteContentGraph) async {
        AppDependencyManager.shared.add { () -> SiteContentGraph in contentGraph }
        AppDependencyManager.shared.add { () -> any SiteOperationsService in
            SiteOperations(factory: LiveCommandFactory())
        }

        await SiteStore.shared.setChangeHandler { sites in
            do {
                let outcome = try await SpotlightIndexer.shared.reindex(sites)
                log.info("indexed=\(outcome.indexed, privacy: .public) removed=\(outcome.removed, privacy: .public)")
            } catch {
                log.error("reindex failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        do {
            try await SiteStore.shared.load()
        } catch {
            log.error("initial load failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
```

- [ ] **Step 2: Confirm `AnglesiteIntents` library still compiles**

```bash
swift build --package-path . --target AnglesiteIntents 2>&1 | tail -5
```

Expected: `Build complete!`. Note: the `Anglesite` and `AnglesiteMAS` Xcode schemes will FAIL until Task 7 — that's expected.

- [ ] **Step 3: Confirm `AnglesiteIntentsTests` still pass**

```bash
swift test --package-path . --filter AnglesiteIntentsTests 2>&1 | tail -5
```

Expected: 62 tests pass (no behavioral change for tests — they use `ContentGraphOverride`, never `@Dependency`).

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteIntents/Bootstrap.swift
git commit -m "$(cat <<'EOF'
feat(intents)!: bootstrap(contentGraph:) — register graph dependency (#137)

API change: AnglesiteIntents.bootstrap now requires a SiteContentGraph
instance, registered with AppDependencyManager so PageEntityQuery /
PostEntityQuery / ImageEntityQuery's @Dependency resolves it. App
callers updated in the following commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Update `AnglesiteApp.AppDelegate` to own + pass the graph

**Files:**
- Modify: `Sources/AnglesiteApp/AnglesiteApp.swift:9-37` (the `AppDelegate` class)

- [ ] **Step 1: Apply the edit**

In `Sources/AnglesiteApp/AnglesiteApp.swift`, replace the `AppDelegate` class with:

```swift
/// Owns process-level lifecycle that SwiftUI's `App` value type can't: prime the npm cache on
/// launch, and drain every supervised child on quit so nothing outlives the app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Single shared `SiteContentGraph` for the app's lifetime. Passed into
    /// `AnglesiteIntents.bootstrap` so it can be registered with `AppDependencyManager`;
    /// will also be threaded into `LocalSiteRuntime` in A.8 (#142).
    let contentGraph = SiteContentGraph()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register App Intents dependencies before the app surface comes up so backgrounded
        // intent processes (and #101's system MCP entry, later) can resolve immediately.
        // `bootstrap()` is async (it awaits the Spotlight handler installation on `SiteStore`);
        // we kick it off here without waiting — the launcher view's `task` modifier doesn't
        // block on it, and bootstrap's own defensive `load()` closes any race.
        Task { [contentGraph] in
            await AnglesiteIntents.bootstrap(contentGraph: contentGraph)
        }

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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await ProcessSupervisor.shared.shutdownAll(timeout: 5)
            await MainActor.run { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
}
```

The two key edits are: (a) adding the `let contentGraph = SiteContentGraph()` property, and (b) changing `Task { await AnglesiteIntents.bootstrap() }` to `Task { [contentGraph] in await AnglesiteIntents.bootstrap(contentGraph: contentGraph) }`. The `[contentGraph]` capture list keeps the closure `@Sendable`-clean by passing the actor reference explicitly rather than capturing `self`.

- [ ] **Step 2: Build the package**

```bash
swift build --package-path . 2>&1 | tail -5
```

Expected: `Build complete!`.

- [ ] **Step 3: Verify both Xcode schemes build clean**

```bash
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -5
xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **` for both. This is the bisect point after Task 6's API change — both schemes must succeed here.

- [ ] **Step 4: Full test suite**

```bash
swift test --package-path . 2>&1 | grep -E "Test run with .* tests"
```

Expected: 62 `AnglesiteIntentsTests`; rest unchanged from baseline. The 2 pre-existing e2e failures (`MCPClientHTTPEndToEndTests`, `AppliesEditEndToEndTests`) remain — they predate this branch.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/AnglesiteApp.swift
git commit -m "$(cat <<'EOF'
feat(app): AppDelegate owns SiteContentGraph + threads it into bootstrap (#137)

Pairs with the previous commit's bootstrap signature change.
contentGraph is constructed once at AppDelegate init and survives
for the app's lifetime; A.8 (#142) will read the same instance from
AppDelegate to wire LocalSiteRuntime.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Push branch + open PR

**Files:** none (push + gh actions).

- [ ] **Step 1: Mark issue in-progress + comment**

Per memory `feedback_mark_gh_issues_in_progress.md`:

```bash
gh issue edit 137 --add-assignee @me
gh issue comment 137 --body "In progress on branch \`feat/content-entities\` — PR up shortly."
```

- [ ] **Step 2: Push branch**

```bash
git push -u origin feat/content-entities
```

Expected: branch pushed; `set up to track 'origin/feat/content-entities'`.

- [ ] **Step 3: Open PR**

```bash
gh pr create \
  --title "feat(intents): PageEntity / PostEntity / ImageEntity (#137)" \
  --body "$(cat <<'EOF'
## Summary

- Lands issue #137 — three `AppEntity` types (`PageEntity`, `PostEntity`, `ImageEntity`) and their `EntityStringQuery` companions in `AnglesiteIntents`.
- Reads live from the just-shipped `SiteContentGraph` (#136) — no cache. `@Dependency` in production, `ContentGraphOverride.$scoped` `@TaskLocal` in tests (mirrors `SiteOperationsOverride`).
- `AnglesiteIntents.bootstrap` gains a `contentGraph:` parameter; `AppDelegate` constructs the single graph instance and passes it in.
- 35 Swift Testing cases (11 Page + 13 Post + 11 Image) covering display representation, id lookup with silent skip on unknown, case-insensitive fuzzy match across the spec'd fields, `lastModified`-DESC ordering, and empty-graph / empty-array edge cases.

Design: [`docs/superpowers/specs/2026-06-11-content-entities-design.md`](docs/superpowers/specs/2026-06-11-content-entities-design.md) · Plan: [`docs/superpowers/plans/2026-06-11-content-entities.md`](docs/superpowers/plans/2026-06-11-content-entities.md)

## Test plan

- [x] `swift test --package-path .` — 35 new `ContentEntitiesTests` pass. Two pre-existing baseline failures (`MCPClientHTTPEndToEndTests`, `AppliesEditEndToEndTests`) are unrelated — both are MCP-transport e2e tests gated on plugin/node infra that fail identically on `main`.
- [x] `xcodebuild -scheme Anglesite -configuration Debug build` — **BUILD SUCCEEDED**
- [x] `xcodebuild -scheme AnglesiteMAS -configuration Debug build` — **BUILD SUCCEEDED**

## What this PR does NOT do

Per the spec's scope boundaries:
- No `ContentSpotlightIndexer` (A.3, #144).
- No new intents that take these entities as parameters (A.5, #139).
- No MCP wiring / graph population (A.8, #142).
- No `searchImages` addition to `SiteContentGraph` (deferred — `ImageEntityQuery` handles substring scan locally).
- No icons / thumbnails in `DisplayRepresentation`.
- No MRU-site tracking — `suggestedEntities()` returns all entries sorted by `lastModified` DESC.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: the `gh pr create` invocation prints the new PR URL. Return that URL.

---

## Self-review

Checking the plan against the spec.

**Spec coverage:**

| Spec section | Plan task |
|---|---|
| `PageEntity` struct + init | Task 3 |
| `PostEntity` struct + init | Task 4 |
| `ImageEntity` struct + init | Task 5 |
| `PageEntityQuery` (all 4 methods) | Task 3 |
| `PostEntityQuery` (all 4 methods) | Task 4 |
| `ImageEntityQuery` (all 4 methods, local substring scan) | Task 5 |
| `ContentGraphOverride.scoped` `@TaskLocal` | Task 2 |
| `AnglesiteIntents.bootstrap(contentGraph:)` | Task 6 |
| `AnglesiteApp.AppDelegate` owns + passes graph | Task 7 |

Invariants 1–6 each have at least one test (Tasks 3–5). Acceptance criteria 1–6 all covered (Tasks 1–8).

**Placeholder scan:** no "TBD", no "TODO", no "similar to Task N" — each task carries the full code. Test file paths exact. ✓

**Type consistency:**

- `SiteContentGraph.Page` / `.Post` / `.Image` used identically across fixture helpers and queries.
- `PageEntity` / `PostEntity` / `ImageEntity` consistent across tasks.
- `PageEntityQuery` / `PostEntityQuery` / `ImageEntityQuery` consistent across tasks.
- `ContentGraphOverride.scoped` / `.$scoped.withValue` consistent.
- `AnglesiteIntents.bootstrap(contentGraph:)` consistent across Tasks 6 and 7.

**Test count math:** Page (11) + Post (13) + Image (11) = 35 new tests. Existing `AnglesiteIntentsTests` baseline is 27. Final target count = 62. Matches expected pass count in Task 6 step 3 and Task 7 step 4. ✓

Plan complete.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-11-content-entities.md`. Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task with two-stage review between tasks. Best when you want quality gating between commits.
2. **Inline Execution** — execute tasks in this session with batch checkpoints. Faster end-to-end but less review surface.

Which approach?
