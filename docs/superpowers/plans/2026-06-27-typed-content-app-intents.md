# Typed-content App-Intent entities (#351) Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the ten collection-backed typed content objects matchable by Siri/Spotlight and add a typed filter intent (`FindContentByTypeIntent`).

**Architecture:** Content-type identity is a pure function of `SiteContentGraph.Post.collection` via `ContentTypeRegistry` (no graph/scanner changes). Add a reverse lookup to the registry, surface a derived `contentType` `@Property` on `PostEntity` (auto-indexed by Spotlight), and add a typed `AppEnum` + filter intent in `AnglesiteIntents`.

**Tech Stack:** Swift 6.4 / SwiftUI 27, AppIntents framework, Swift Testing (`@Test`/`#expect`), SwiftPM (`swift test`).

## Global Constraints

- ES modules / vanilla — N/A (Swift project).
- **Worktree:** all work in `.claude/worktrees/351-typed-content-intents` (branch `feat/351-typed-content-intents`). `cd` there before any git/build op. The absolute `/Users/dwk/…` paths in the per-step commands below are machine-specific — substitute your own worktree root.
- **Swift toolchain:** `swift test` needs `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` (default CommandLineTools swift is too old).
- **No new third-party deps** — Apple frameworks only.
- **Scope:** the ten `.collection(...)`-backed built-in types only. `businessProfile` / page singletons are OUT (→ #388). No `SiteContentGraph` / `ContentScanner` / MCP `list_content` changes. No new curated Siri `AppShortcut` phrases (the last of the 10 slots is reserved for the queued Bucket-3 intents; `AnglesiteShortcuts` lists 9 today).
- **`FindContentByTypeIntent` returns `[PostEntity]`** (homogeneous), not `ContentMatchEntity`.
- **Test invocation:** `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter <SuiteOrTest>` per commit; final task builds both Xcode schemes.
- **Conventional commits**, footer `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

### Task 1: Registry reverse lookup (`AnglesiteCore`)

**Files:**
- Modify: `Sources/AnglesiteCore/ContentTypeRegistry.swift` (add to `ContentTypeRegistry` struct + a shared default)
- Test: `Tests/AnglesiteCoreTests/ContentTypeRegistryTests.swift`

**Interfaces:**
- Consumes: existing `ContentTypeDescriptor`, `ContentStorage`, `ContentTypeRegistry`.
- Produces:
  - `ContentTypeRegistry.descriptor(forCollection: String) -> ContentTypeDescriptor?`
  - `static let ContentTypeRegistry.default: ContentTypeRegistry` (built-ins; O(1) reverse map)
  - `ContentTypeRegistry.collectionBackedTypeIDs: [String]` (ordered ids of `.collection`-stored types)

- [ ] **Step 1: Write the failing test**

Add to `Tests/AnglesiteCoreTests/ContentTypeRegistryTests.swift` (inside the existing suite/struct; match its `@Test` style):

```swift
@Test("descriptor(forCollection:) maps a collection name back to its type")
func reverseLookupByCollection() {
    let r = ContentTypeRegistry.default
    #expect(r.descriptor(forCollection: "events")?.id == "event")
    #expect(r.descriptor(forCollection: "reviews")?.id == "review")
    #expect(r.descriptor(forCollection: "notes")?.id == "note")
    // Unknown / custom collection has no descriptor.
    #expect(r.descriptor(forCollection: "blog") == nil)
    // Page-stored businessProfile has no collection, so it is never reverse-matched.
    #expect(r.descriptor(forCollection: "") == nil)
}

@Test("collectionBackedTypeIDs lists exactly the .collection-stored built-ins, in order")
func collectionBackedIDs() {
    #expect(ContentTypeRegistry.default.collectionBackedTypeIDs == [
        "note", "article", "photo", "album", "bookmark", "reply", "like",
        "announcement", "event", "review",
    ])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ContentTypeRegistryTests`
Expected: FAIL — `value of type 'ContentTypeRegistry' has no member 'descriptor(forCollection:)'` / no member `default` / `collectionBackedTypeIDs`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/AnglesiteCore/ContentTypeRegistry.swift`, add a stored reverse map to the struct and the accessors. Replace the struct's stored properties + `init` region so the reverse map is built alongside `byID`:

```swift
public struct ContentTypeRegistry: Sendable, Equatable {
    private var byID: [String: ContentTypeDescriptor]
    private var order: [String]
    /// collection name → type id, for `.collection`-stored types only. Built at insert time
    /// so reverse lookups are O(1) and stay in sync with `byID`.
    private var collectionToID: [String: String]

    public init(types: [ContentTypeDescriptor] = ContentTypeRegistry.builtIns) {
        byID = [:]
        order = []
        collectionToID = [:]
        for descriptor in types { insert(descriptor) }
    }

    private mutating func insert(_ descriptor: ContentTypeDescriptor) {
        if byID[descriptor.id] == nil { order.append(descriptor.id) }
        // A replaced descriptor may have changed collection; drop any stale reverse entry first.
        if let old = byID[descriptor.id]?.collection { collectionToID[old] = nil }
        byID[descriptor.id] = descriptor
        if let collection = descriptor.collection { collectionToID[collection] = descriptor.id }
    }
```

Keep the existing `register`, `descriptor(id:)`, `all`, `ids`. Then add (after `descriptor(id:)`):

```swift
    /// Reverse of `descriptor(id:)`: the `.collection`-stored type whose collection is `collection`.
    public func descriptor(forCollection collection: String) -> ContentTypeDescriptor? {
        guard let id = collectionToID[collection] else { return nil }
        return byID[id]
    }

    /// Ids of the `.collection`-stored types, in registration order. Page-stored types are excluded.
    public var collectionBackedTypeIDs: [String] {
        order.compactMap { byID[$0] }.filter { $0.collection != nil }.map(\.id)
    }

    /// Shared built-in registry. Lets value-type consumers resolve types without rebuilding it.
    public static let `default` = ContentTypeRegistry()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ContentTypeRegistryTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/351-typed-content-intents
git add Sources/AnglesiteCore/ContentTypeRegistry.swift Tests/AnglesiteCoreTests/ContentTypeRegistryTests.swift
git commit -m "feat(#351): registry reverse lookup (collection→type)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `PostEntity.contentType` derived property

**Files:**
- Modify: `Sources/AnglesiteIntents/ContentEntities.swift` (the `PostEntity` struct, ~lines 96–136)
- Test: `Tests/AnglesiteIntentsTests/ContentEntitiesTests.swift`

**Interfaces:**
- Consumes: `ContentTypeRegistry.default.descriptor(forCollection:)` (Task 1); `SiteContentGraph.Post`.
- Produces: `PostEntity.contentType: String` (`@Property(title: "Type")`); secondary `init` gains `contentType: String = ""` param. `init(_ post:)` derives it.

- [ ] **Step 1: Write the failing test**

Add to `Tests/AnglesiteIntentsTests/ContentEntitiesTests.swift` (inside the existing `PostEntityQuery` suite or a new `@Suite` next to it — match the file's style):

```swift
@Test("PostEntity derives contentType display name from a known collection")
func postEntity_contentTypeFromKnownCollection() {
    let entity = PostEntity(AppIntentsTests.gPost(collection: "events"))
    #expect(entity.contentType == "Event")
}

@Test("PostEntity falls back to the raw collection for an unknown collection")
func postEntity_contentTypeUnknownCollectionFallsBack() {
    let entity = PostEntity(AppIntentsTests.gPost(collection: "blog"))
    #expect(entity.contentType == "blog")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ContentEntitiesTests`
Expected: FAIL — `value of type 'PostEntity' has no member 'contentType'`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/AnglesiteIntents/ContentEntities.swift`, in `struct PostEntity`, add the property after `collection`:

```swift
    @Property(title: "Type") public var contentType: String
```

Update `init(_ post:)` to derive it (add this line alongside the other assignments):

```swift
        // Typed dimension (#351): map the post's collection back to its content type's display
        // name via the registry; fall back to the raw collection for custom/unknown collections.
        self.contentType = ContentTypeRegistry.default.descriptor(forCollection: post.collection)?.displayName
            ?? post.collection
```

Update the secondary memberwise `init(id:displayName:slug:collection:siteID:isDraft:tags:)` to accept and assign `contentType`, defaulting so existing call sites are unaffected:

```swift
    public init(id: String, displayName: String, slug: String, collection: String,
                siteID: String, isDraft: Bool = true, tags: [String] = [],
                contentType: String = "") {
        self.id = id
        self.displayName = displayName
        self.isDraft = isDraft
        self.tags = tags
        self.slug = slug
        self.collection = collection
        self.siteID = siteID
        self.contentType = contentType
    }
```

(`AnglesiteIntents` already `import AnglesiteCore`, so `ContentTypeRegistry` is in scope.)

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ContentEntitiesTests`
Expected: PASS. (The existing `AddPostIntent.createdPost` call site still compiles — `contentType` defaults to `""`.)

- [ ] **Step 5: Commit**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/351-typed-content-intents
git add Sources/AnglesiteIntents/ContentEntities.swift Tests/AnglesiteIntentsTests/ContentEntitiesTests.swift
git commit -m "feat(#351): derive PostEntity.contentType for Spotlight/Siri matching

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: `ContentTypeAppEnum` + drift guard

**Files:**
- Create: `Sources/AnglesiteIntents/ContentTypeAppEnum.swift`
- Test: `Tests/AnglesiteIntentsTests/ContentTypeAppEnumTests.swift`

**Interfaces:**
- Consumes: `ContentTypeRegistry.default` / `collectionBackedTypeIDs` (Task 1).
- Produces:
  - `enum ContentTypeAppEnum: String, AppEnum, Sendable` — one case per collection-backed type id; `rawValue == registry id`.
  - `var collection: String?` — the type's collection name via the registry.

- [ ] **Step 1: Write the failing test**

Create `Tests/AnglesiteIntentsTests/ContentTypeAppEnumTests.swift`:

```swift
import Testing
import AppIntents
@testable import AnglesiteCore
@testable import AnglesiteIntents

extension AppIntentsTests {
    @Suite("ContentTypeAppEnum")
    struct ContentTypeAppEnumTests {

        @Test("enum cases match the registry's collection-backed type ids exactly (drift guard)")
        func driftGuard() {
            let enumIDs = Set(ContentTypeAppEnum.allCases.map(\.rawValue))
            let registryIDs = Set(ContentTypeRegistry.default.collectionBackedTypeIDs)
            #expect(enumIDs == registryIDs)
        }

        @Test("every case has a non-empty display representation and resolves its collection")
        func displayAndCollection() {
            for kind in ContentTypeAppEnum.allCases {
                let title = ContentTypeAppEnum.caseDisplayRepresentations[kind]?.title
                #expect(title != nil)
                #expect(kind.collection != nil)
            }
            #expect(ContentTypeAppEnum.event.collection == "events")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ContentTypeAppEnumTests`
Expected: FAIL — `cannot find 'ContentTypeAppEnum' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/AnglesiteIntents/ContentTypeAppEnum.swift`:

```swift
import AppIntents
import AnglesiteCore

/// The typed content kinds a user can filter by (the `.collection`-stored built-ins from
/// `ContentTypeRegistry`). An `AppEnum` so it appears as a typed picker in Shortcuts and in the
/// auto-derived MCP schema. `rawValue` is the registry id; kept in sync by a drift-guard test
/// (`ContentTypeAppEnumTests`) — adding a built-in collection type fails that test until a case
/// is added here. `businessProfile` (page singleton) is intentionally absent (#351 scope).
public enum ContentTypeAppEnum: String, AppEnum, Sendable, CaseIterable {
    case note, article, photo, album, bookmark, reply, like
    case announcement, event, review

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Content Type" }

    public static var caseDisplayRepresentations: [ContentTypeAppEnum: DisplayRepresentation] {
        [
            .note: "Note", .article: "Article", .photo: "Photo", .album: "Album",
            .bookmark: "Bookmark", .reply: "Reply", .like: "Like",
            .announcement: "Announcement", .event: "Event", .review: "Review",
        ]
    }

    /// The Astro content collection backing this type (e.g. `.event` → "events"), via the registry.
    public var collection: String? {
        ContentTypeRegistry.default.descriptor(id: rawValue)?.collection
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ContentTypeAppEnumTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/351-typed-content-intents
git add Sources/AnglesiteIntents/ContentTypeAppEnum.swift Tests/AnglesiteIntentsTests/ContentTypeAppEnumTests.swift
git commit -m "feat(#351): ContentTypeAppEnum with registry drift guard

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: `FindContentByTypeIntent` + dialog

**Files:**
- Modify: `Sources/AnglesiteIntents/ContentIntents.swift` (add the intent; add a `findByType` dialog to `ContentDialogs`)
- Test: `Tests/AnglesiteIntentsTests/ContentIntentsTests.swift`

**Interfaces:**
- Consumes: `ContentTypeAppEnum` (Task 3) + `.collection`; `PostEntity` (Task 2); `SiteContentGraph.posts(for:)`; `ContentGraphOverride.scoped`; `SiteEntity`.
- Produces:
  - `FindContentByTypeIntent` (params `site: SiteEntity`, `contentType: ContentTypeAppEnum`; returns `[PostEntity]`).
  - `static FindContentByTypeIntent.matches(graph:siteID:type:) async -> [PostEntity]`.
  - `ContentDialogs.findByType(typeName:count:) -> String`.

- [ ] **Step 1: Write the failing test**

Add to `Tests/AnglesiteIntentsTests/ContentIntentsTests.swift` (inside the `ContentIntentsTests` struct):

```swift
@Test("findByType dialog: singular/plural and empty")
func findByTypeDialog() {
    #expect(ContentDialogs.findByType(typeName: "Event", count: 0) == "No events found.")
    #expect(ContentDialogs.findByType(typeName: "Event", count: 1) == "Found 1 event.")
    #expect(ContentDialogs.findByType(typeName: "Review", count: 3) == "Found 3 reviews.")
}

@Test("FindContentByTypeIntent.matches filters by type's collection, sorted, scoped to site")
func findByTypeMatches() async {
    let graph = SiteContentGraph()
    await graph.load(
        siteID: AppIntentsTests.aSite,
        pages: [],
        posts: [
            AppIntentsTests.gPost(slug: "older", title: "Older", collection: "events",
                                  modified: AppIntentsTests.t0),
            AppIntentsTests.gPost(slug: "newer", title: "Newer", collection: "events",
                                  modified: AppIntentsTests.t0.addingTimeInterval(60)),
            AppIntentsTests.gPost(slug: "a-review", title: "A Review", collection: "reviews"),
        ],
        images: []
    )
    // A post of the same type on another site must not leak in.
    await graph.upsertPost(AppIntentsTests.gPost(site: AppIntentsTests.bSite, slug: "b-evt",
                                                 collection: "events"))

    let results = await FindContentByTypeIntent.matches(
        graph: graph, siteID: AppIntentsTests.aSite, type: .event)
    // Only this site's events, newest first.
    #expect(results.map(\.slug) == ["newer", "older"])
    #expect(results.allSatisfy { $0.contentType == "Event" })
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ContentIntentsTests`
Expected: FAIL — no `ContentDialogs.findByType` / no `FindContentByTypeIntent`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/AnglesiteIntents/ContentIntents.swift`, add the intent (after `SearchContentIntent`, before `SiteStatusIntent`):

```swift
// MARK: - Find by type

/// Lists a site's content of one type (#351). The typed counterpart to `SearchContentIntent`:
/// resolves the type's collection from the registry and filters the graph's posts by it.
public struct FindContentByTypeIntent: AppIntent {
    public static let title: LocalizedStringResource = "Find Content by Type"
    public static let description = IntentDescription("List a site's content of a given type, e.g. events or reviews.")

    @Parameter(title: "Site") public var site: SiteEntity
    @Parameter(title: "Type") public var contentType: ContentTypeAppEnum
    @Dependency private var graph: SiteContentGraph

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Find \(\.$contentType) in \(\.$site)")
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[PostEntity]> {
        let g = ContentGraphOverride.scoped ?? graph
        let results = await Self.matches(graph: g, siteID: site.id, type: contentType)
        let typeName = ContentTypeAppEnum.caseDisplayRepresentations[contentType]?.title ?? "content"
        return .result(
            value: results,
            dialog: IntentDialog(stringLiteral: ContentDialogs.findByType(
                typeName: String(localized: typeName), count: results.count))
        )
    }

    /// Filter the site's posts to the type's collection, sorted (lastModified desc, id asc) — the
    /// same comparator the entity queries use. Static + graph-injected for unit testability.
    static func matches(graph: SiteContentGraph, siteID: String, type: ContentTypeAppEnum) async -> [PostEntity] {
        guard let collection = type.collection else { return [] }
        return await graph.posts(for: siteID)
            .filter { $0.collection == collection }
            .sorted { $0.lastModified != $1.lastModified ? $0.lastModified > $1.lastModified : $0.id < $1.id }
            .map(PostEntity.init)
    }
}
```

Add to the `ContentDialogs` enum (next to `search`):

```swift
    public static func findByType(typeName: String, count: Int) -> String {
        let plural = pluralize(typeName, count)
        guard count > 0 else { return "No \(plural) found." }
        return "Found \(count) \(plural)."
    }

    /// Naive English pluralization sufficient for the built-in type display names
    /// (Note, Article, Photo, Album, Bookmark, Reply, Like, Announcement, Event, Review).
    private static func pluralize(_ noun: String, _ n: Int) -> String {
        let lower = noun.lowercased()
        if n == 1 { return lower }
        if lower.hasSuffix("y") { return lower.dropLast() + "ies" }  // reply → replies
        return lower + "s"
    }
```

(`String(localized:)` converts the `DisplayRepresentation.title` `LocalizedStringResource` to a `String` for the dialog. `DisplayRepresentation.title` is a `LocalizedStringResource`.)

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ContentIntentsTests`
Expected: PASS — `findByTypeDialog` (note "reply"→"replies", "review"→"reviews") and `findByTypeMatches`.

- [ ] **Step 5: Commit**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/351-typed-content-intents
git add Sources/AnglesiteIntents/ContentIntents.swift Tests/AnglesiteIntentsTests/ContentIntentsTests.swift
git commit -m "feat(#351): FindContentByTypeIntent + typed dialog

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Schema/smoke sweep + full verification

**Files:**
- Inspect: `Tests/AnglesiteIntentsTests/SchemaConformanceTests.swift`, `Tests/AnglesiteIntentsTests/SmokeMatrixTests.swift`, `Tests/AnglesiteIntentsTests/AnglesiteShortcutsTests.swift`
- Modify: whichever of the above enumerate the intent/entity/enum surface (only if they do).

**Interfaces:**
- Consumes: everything from Tasks 1–4.
- Produces: no new API — closes coverage and proves the whole suite + both app schemes build.

- [ ] **Step 1: Check whether the sweep tests enumerate the surface**

Run:
```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/351-typed-content-intents
grep -n "Intent\|AppEnum\|PostEntity\|allCases\|expectedIntents\|\.self" \
  Tests/AnglesiteIntentsTests/SchemaConformanceTests.swift \
  Tests/AnglesiteIntentsTests/SmokeMatrixTests.swift \
  Tests/AnglesiteIntentsTests/AnglesiteShortcutsTests.swift
```
Expected: shows whether any test hard-codes a list of intents/entities. If a test asserts an exhaustive set (e.g. an `expectedIntents` array or an `AppShortcut` count), `FindContentByTypeIntent` / `ContentTypeAppEnum` must be added there. If they only conformance-check individual named types, no change is needed.

- [ ] **Step 2: Apply the minimal additions the grep reveals**

If (and only if) a test enumerates the surface, add `FindContentByTypeIntent` / `ContentTypeAppEnum` to that list in the same style the file already uses. If a schema-conformance test instantiates each intent, add:

```swift
_ = FindContentByTypeIntent()
```

in the same place the others are instantiated. If `AnglesiteShortcutsTests` asserts an exact curated-phrase count, **leave it unchanged** — the new intent is deliberately not a curated `AppShortcut` (10-phrase budget; see plan constraints). If nothing enumerates the surface, record that in the commit body and skip to Step 3.

- [ ] **Step 3: Run the full intents + core suites**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  swift test --package-path . --filter AnglesiteIntentsTests
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  swift test --package-path . --filter ContentTypeRegistryTests
```
Expected: PASS, no regressions.

- [ ] **Step 4: Build both app schemes (proves the `.app` targets link the new types)**

`Anglesite.xcodeproj` is gitignored — generate it, populate the gitignored plugin resources, then build. Run:
```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/351-typed-content-intents
xcodegen generate
ANGLESITE_PLUGIN_SRC=/Users/dwk/Developer/github.com/Anglesite/anglesite ./scripts/copy-plugin.sh
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build
```
Expected: both `BUILD SUCCEEDED`. (If `copy-plugin.sh` fails on a self-symlink under `Resources/plugin`, `rm` it and re-run — see project memory.)

- [ ] **Step 5: Commit (only if Step 2 changed files)**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/351-typed-content-intents
git add Tests/AnglesiteIntentsTests/
git commit -m "test(#351): register typed-content intent/enum in schema/smoke sweep

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- Registry reverse lookup → Task 1. ✓
- `PostEntity.contentType` derived + Spotlight auto-index (no indexer change) → Task 2. ✓
- `ContentTypeAppEnum` + drift guard → Task 3. ✓
- `FindContentByTypeIntent` returns `[PostEntity]`, static testable helper, `ContentDialogs` entry, not a curated AppShortcut → Task 4. ✓
- Schema/smoke sweep + both-scheme build → Task 5. ✓
- Out-of-scope (businessProfile, per-type entities, graph/scanner changes) → enforced by constraints; no task touches them. ✓
- Tests named in spec: `ContentEntitiesTests` (T2), `FindContentByTypeIntentTests`→folded into `ContentIntentsTests` (T4), `ContentTypeAppEnumTests` (T3), `ContentDialogsTests`→folded into `ContentIntentsTests`' dialog tests (T4). ✓ (Dialog/intent tests live in `ContentIntentsTests`, the established home for `ContentDialogs` + intent-helper tests.)

**Placeholder scan:** No TBD/TODO; every code step shows complete code; commands have expected output. ✓

**Type consistency:** `descriptor(forCollection:)`, `collectionBackedTypeIDs`, `ContentTypeRegistry.default`, `ContentTypeAppEnum` (rawValue == id) + `.collection`, `PostEntity.contentType: String`, `FindContentByTypeIntent.matches(graph:siteID:type:) -> [PostEntity]`, `ContentDialogs.findByType(typeName:count:)` — names identical across tasks. ✓
