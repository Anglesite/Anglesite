# URL-Tree Navigator (#714 slice 1) Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the grouped site-navigator sidebar with a visitor-facing URL tree (website-settings row, pinned home, HTML pages, feed-badged collection directories), and relocate the Cleanup section to the Site menu.

**Architecture:** A pure `buildSiteURLTree` function in AnglesiteCore turns `SiteContentGraph` routes + a feed probe into recursive `URLTreeNode`s; `SiteNavigatorModel`/`SiteNavigatorView` swap from sections to the tree; `SiteWindowModel.applyNavigatorSelection` learns two new targets. Spec: `docs/superpowers/specs/2026-07-13-website-design-window-cleanup-design.md`.

**Tech Stack:** Swift 6.4 / SwiftUI (macOS 27), Swift Testing (`@Test`/`#expect`), SwiftPM tests.

## Global Constraints

- Worktree: run `xcodegen generate` before any `xcodebuild`; `Anglesite.xcodeproj` is gitignored.
- `swift test` needs `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` (default CLT swift is broken).
- Run the FULL `swift test --package-path .` before push — several suites string-match template markup.
- No frameworks beyond Apple's. No `Process()` outside ProcessSupervisor.
- Conventional commits. Skill note: consult `swiftui-pro` when writing the SwiftUI in Tasks 3–4.
- Selection/rename machinery resolves rows via `graph.page(id:)`/`graph.post(id:)` — leaf node IDs MUST be graph entity IDs.

---

### Task 1: `URLTreeNode` + `buildSiteURLTree` in AnglesiteCore

**Files:**
- Create: `Sources/AnglesiteCore/SiteURLTree.swift`
- Modify: `Sources/AnglesiteCore/NavigatorTree.swift` (add `NavigatorTarget` cases only — do NOT remove `buildNavigatorTree` yet; Task 5 deletes it)
- Create: `Tests/AnglesiteCoreTests/SiteURLTreeTests.swift`

**Interfaces:**
- Consumes: `SiteContentGraph.Page` (`id`, `route`, `title`), `SiteContentGraph.Post` (`id`, `collection`, `slug`, `title`, `publishDate`), `postRoute(for:)`, `ContentTypeRegistry.descriptor(forCollection:)`.
- Produces (later tasks rely on these exact shapes):

```swift
public enum NavigatorTarget: Sendable, Equatable {
    case route(String)
    case file(FileRef)
    case directory(collection: String?, route: String)   // NEW
    case websiteSettings                                   // NEW
}

public struct URLTreeNode: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case website
        case home
        case page
        case directory(collection: String?, hasFeed: Bool)
    }
    public let id: String        // graph id for leaves; "dir:<route>" for dirs; "website"
    public let title: String
    public let route: String
    public let kind: Kind
    public let children: [URLTreeNode]?   // nil for leaves (hides List disclosure)
    public init(id: String, title: String, route: String, kind: Kind, children: [URLTreeNode]?)
    public var target: NavigatorTarget { get }  // website→.websiteSettings, directory→.directory, else .route(route)
}

public func buildSiteURLTree(
    websiteTitle: String?,
    pages: [SiteContentGraph.Page],
    posts: [SiteContentGraph.Post],
    feedCollections: Set<String>,
    contentTypes: ContentTypeRegistry = .default
) -> [URLTreeNode]
```

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/SiteURLTreeTests.swift` (reuse the fixture-helper style of `NavigatorTreeTests.swift`):

```swift
import Testing
import Foundation
@testable import AnglesiteCore

struct SiteURLTreeTests {
    private func page(_ route: String, title: String?) -> SiteContentGraph.Page {
        SiteContentGraph.Page(id: "s:page:\(route)", siteID: "s", route: route,
            filePath: "src/pages\(route == "/" ? "/index" : route).astro",
            title: title, lastModified: Date(timeIntervalSince1970: 0))
    }
    private func post(_ collection: String, _ slug: String, _ title: String,
                      date: Date? = nil) -> SiteContentGraph.Post {
        SiteContentGraph.Post(id: "s:post:\(slug)", siteID: "s", collection: collection,
            slug: slug, title: title, draft: false, publishDate: date, tags: [],
            filePath: "src/content/\(collection)/\(slug).md",
            lastModified: Date(timeIntervalSince1970: 0))
    }
    private func build(pages: [SiteContentGraph.Page] = [],
                       posts: [SiteContentGraph.Post] = [],
                       feeds: Set<String> = [],
                       title: String? = "My Site") -> [URLTreeNode] {
        buildSiteURLTree(websiteTitle: title, pages: pages, posts: posts, feedCollections: feeds)
    }

    @Test("empty site produces an empty tree (sidebar shows its empty state)")
    func emptySite() {
        #expect(build() == [])
    }

    @Test("website row is first, uses the site title, and targets website settings")
    func websiteRow() throws {
        let nodes = build(pages: [page("/", title: "Home")])
        let first = try #require(nodes.first)
        #expect(first.id == "website")
        #expect(first.title == "My Site")
        #expect(first.kind == .website)
        #expect(first.target == .websiteSettings)
        #expect(first.children == nil)
    }

    @Test("website row falls back to \"Website\" for a missing or blank title")
    func websiteTitleFallback() {
        #expect(build(pages: [page("/", title: nil)], title: nil).first?.title == "Website")
        #expect(build(pages: [page("/", title: nil)], title: "  ").first?.title == "Website")
    }

    @Test("home is pinned after the website row, before other pages, before directories")
    func topLevelOrder() {
        let nodes = build(
            pages: [page("/zebra", title: "Zebra"), page("/", title: "Home"),
                    page("/about", title: "About")],
            posts: [post("notes", "n1", "First note")])
        #expect(nodes.map(\.id) ==
            ["website", "s:page:/", "s:page:/about", "s:page:/zebra", "dir:/notes/"])
        #expect(nodes[1].kind == .home)
        #expect(nodes[1].target == .route("/"))
    }

    @Test("collection directory carries hasFeed from the probe set and its collection name")
    func feedBadge() throws {
        let nodes = build(posts: [post("notes", "n1", "A"), post("photos", "p1", "B")],
                          feeds: ["notes"])
        let notes = try #require(nodes.first { $0.id == "dir:/notes/" })
        let photos = try #require(nodes.first { $0.id == "dir:/photos/" })
        #expect(notes.kind == .directory(collection: "notes", hasFeed: true))
        #expect(photos.kind == .directory(collection: "photos", hasFeed: false))
        #expect(notes.target == .directory(collection: "notes", route: "/notes/"))
    }

    @Test("directory titles use the registry displayName, else the capitalized segment")
    func directoryTitles() {
        let nodes = build(posts: [post("notes", "n1", "A"), post("mixtapes", "m1", "B")])
        // "notes" is a registered content type (Note); "mixtapes" is not.
        #expect(nodes.first { $0.id == "dir:/notes/" }?.title == "Notes")
        #expect(nodes.first { $0.id == "dir:/mixtapes/" }?.title == "Mixtapes")
    }

    @Test("entries sort reverse-chronologically; undated entries follow, sorted by title")
    func entryOrder() throws {
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        let nodes = build(posts: [
            post("notes", "b-undated", "Bravo"),
            post("notes", "old", "Old", date: old),
            post("notes", "a-undated", "Alpha"),
            post("notes", "new", "New", date: new),
        ])
        let dir = try #require(nodes.first { $0.id == "dir:/notes/" })
        #expect(dir.children?.map(\.title) == ["New", "Old", "Alpha", "Bravo"])
    }

    @Test("a directory's own index page is pinned before its entries")
    func directoryIndexPinned() throws {
        let nodes = build(
            pages: [page("/", title: "Home"), page("/notes", title: "All Notes")],
            posts: [post("notes", "n1", "First", date: Date(timeIntervalSince1970: 1))])
        let dir = try #require(nodes.first { $0.id == "dir:/notes/" })
        #expect(dir.children?.map(\.title) == ["All Notes", "First"])
        // The merged /notes page is a child, not a top-level sibling.
        #expect(!nodes.contains { $0.id == "s:page:/notes" })
    }

    @Test("nested src/pages folders form directory chains")
    func nestedPageFolders() throws {
        let nodes = build(pages: [
            page("/", title: "Home"),
            page("/docs/guides/setup", title: "Setup"),
        ])
        let docs = try #require(nodes.first { $0.id == "dir:/docs/" })
        #expect(docs.kind == .directory(collection: nil, hasFeed: false))
        let guides = try #require(docs.children?.first { $0.id == "dir:/docs/guides/" })
        #expect(guides.children?.map(\.title) == ["Setup"])
    }

    @Test("entry leaf routes are the percent-encoded postRoute")
    func entryRoutes() throws {
        let nodes = build(posts: [post("notes", "héllo wörld", "Hello")])
        let dir = try #require(nodes.first { $0.id == "dir:/notes/" })
        #expect(dir.children?.first?.target == .route(postRoute(for: post("notes", "héllo wörld", "Hello"))))
    }

    @Test("leaf ids are graph entity ids")
    func leafIDs() throws {
        let nodes = build(pages: [page("/", title: "Home")],
                          posts: [post("notes", "n1", "First")])
        #expect(nodes.contains { $0.id == "s:page:/" })
        let dir = try #require(nodes.first { $0.id == "dir:/notes/" })
        #expect(dir.children?.first?.id == "s:post:n1")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SiteURLTreeTests`
Expected: compile FAILURE — `URLTreeNode` / `buildSiteURLTree` not defined.

- [ ] **Step 3: Add the new `NavigatorTarget` cases**

In `Sources/AnglesiteCore/NavigatorTree.swift`, replace the enum body:

```swift
/// What selecting a navigator row does: navigate the preview to a route, open a file in the
/// editor, open a directory's settings, or open the site-wide Website Settings (#714).
public enum NavigatorTarget: Sendable, Equatable {
    case route(String)
    case file(FileRef)
    case directory(collection: String?, route: String)
    case websiteSettings
}
```

- [ ] **Step 4: Implement `SiteURLTree.swift`**

Create `Sources/AnglesiteCore/SiteURLTree.swift`:

```swift
import Foundation

/// One node of the visitor-facing sidebar URL tree (#714): the site as its built, human-visible
/// pages — never source files. Images, CSS, JS, components, and feed routes are excluded by
/// construction because only page/entry routes enter the builder.
public struct URLTreeNode: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case website
        case home
        case page
        case directory(collection: String?, hasFeed: Bool)
    }
    // Graph entity id for leaves — the rename/context-menu machinery resolves rows via
    // graph.page(id:)/post(id:), so routes can't serve as leaf ids.
    public let id: String
    public let title: String
    public let route: String
    public let kind: Kind
    /// nil for leaves so `List`/`OutlineGroup` hides the disclosure chevron.
    public let children: [URLTreeNode]?

    public init(id: String, title: String, route: String, kind: Kind, children: [URLTreeNode]?) {
        self.id = id; self.title = title; self.route = route; self.kind = kind
        self.children = children
    }

    public var target: NavigatorTarget {
        switch kind {
        case .website: return .websiteSettings
        case .directory(let collection, _): return .directory(collection: collection, route: route)
        case .home, .page: return .route(route)
        }
    }
}

/// Builds the sidebar tree: website-settings row pinned first, then home (`/`), then other
/// top-level pages by title, then directories by title. Inside a directory: its own index page
/// pinned, then entries newest-first (undated after dated, by title), then subdirectories.
/// Returns [] for a site with no content so the sidebar keeps its "No content yet" empty state.
public func buildSiteURLTree(
    websiteTitle: String?,
    pages: [SiteContentGraph.Page],
    posts: [SiteContentGraph.Post],
    feedCollections: Set<String>,
    contentTypes: ContentTypeRegistry = .default
) -> [URLTreeNode] {
    guard !pages.isEmpty || !posts.isEmpty else { return [] }

    let trimmed = websiteTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
    let websiteNode = URLTreeNode(
        id: "website",
        title: (trimmed?.isEmpty == false ? trimmed! : "Website"),
        route: "/", kind: .website, children: nil)

    var root = DirectoryBuilder(route: "/", collection: nil)
    for page in pages {
        let segments = pathSegments(of: page.route)
        root.insert(page: page, remainingSegments: segments)
    }
    for post in posts {
        // Entries live one level deep: /<collection>/<slug>/.
        root.child(for: post.collection).entries.append(post)
    }

    var nodes = [websiteNode]
    nodes.append(contentsOf: root.buildTopLevel(feedCollections: feedCollections, contentTypes: contentTypes))
    return nodes
}

/// "/docs/guides/setup" → ["docs", "guides", "setup"]; "/" → [].
private func pathSegments(of route: String) -> [String] {
    route.split(separator: "/").map(String.init)
}

/// Mutable accumulation node; `build*` converts to immutable `URLTreeNode`s.
private final class DirectoryBuilder {
    let route: String
    let collection: String?
    var indexPage: SiteContentGraph.Page?
    var pages: [SiteContentGraph.Page] = []
    var entries: [SiteContentGraph.Post] = []
    var subdirectories: [String: DirectoryBuilder] = [:]

    init(route: String, collection: String?) {
        self.route = route; self.collection = collection
    }

    func child(for segment: String) -> DirectoryBuilder {
        if let existing = subdirectories[segment] { return existing }
        let encoded = segment.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? segment
        let child = DirectoryBuilder(
            route: route + encoded + "/",
            // A first-level directory that receives entries is a collection; the name is set
            // lazily when the first entry arrives (see `collectionName`).
            collection: nil)
        subdirectories[segment] = child
        return child
    }

    func insert(page: SiteContentGraph.Page, remainingSegments: [String]) {
        if remainingSegments.isEmpty {
            indexPage = page
        } else if remainingSegments.count == 1 {
            pages.append(page)
        } else {
            child(for: remainingSegments[0])
                .insert(page: page, remainingSegments: Array(remainingSegments.dropFirst()))
        }
    }

    /// Top level: home first, then pages by title, then directories by title.
    func buildTopLevel(feedCollections: Set<String>, contentTypes: ContentTypeRegistry) -> [URLTreeNode] {
        var nodes: [URLTreeNode] = []
        if let index = indexPage {
            nodes.append(leaf(for: index, kind: .home, route: "/"))
        }
        nodes.append(contentsOf: pages
            .map { leaf(for: $0, kind: .page, route: $0.route) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
        nodes.append(contentsOf: directoryNodes(feedCollections: feedCollections, contentTypes: contentTypes))
        return nodes
    }

    private func directoryNodes(feedCollections: Set<String>, contentTypes: ContentTypeRegistry) -> [URLTreeNode] {
        subdirectories
            .map { segment, builder in
                builder.buildDirectory(segment: segment, feedCollections: feedCollections,
                                       contentTypes: contentTypes)
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func buildDirectory(segment: String, feedCollections: Set<String>,
                                contentTypes: ContentTypeRegistry) -> URLTreeNode {
        let collectionName = entries.first?.collection
        var children: [URLTreeNode] = []
        if let index = indexPage {
            children.append(leaf(for: index, kind: .page, route: index.route))
        }
        // Entries newest-first; undated entries follow the dated ones, sorted by title.
        // Plain nested pages sort within the same list by the same rule (all undated).
        let dated = entries.filter { $0.publishDate != nil }
            .sorted { $0.publishDate! > $1.publishDate! }
        let undatedEntries = entries.filter { $0.publishDate == nil }
        let undatedLeaves = (undatedEntries.map { entryLeaf(for: $0) }
            + pages.map { leaf(for: $0, kind: .page, route: $0.route) })
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        children.append(contentsOf: dated.map { entryLeaf(for: $0) })
        children.append(contentsOf: undatedLeaves)
        children.append(contentsOf: directoryNodes(feedCollections: feedCollections,
                                                   contentTypes: contentTypes))
        return URLTreeNode(
            id: "dir:\(route)",
            title: directoryTitle(segment: segment, collection: collectionName, contentTypes: contentTypes),
            route: route,
            kind: .directory(collection: collectionName,
                             hasFeed: collectionName.map(feedCollections.contains) ?? false),
            children: children)
    }

    private func leaf(for page: SiteContentGraph.Page, kind: URLTreeNode.Kind, route: String) -> URLTreeNode {
        URLTreeNode(id: page.id, title: page.title ?? page.route, route: route, kind: kind, children: nil)
    }

    private func entryLeaf(for post: SiteContentGraph.Post) -> URLTreeNode {
        URLTreeNode(id: post.id, title: post.title, route: postRoute(for: post), kind: .page, children: nil)
    }
}

/// A collection's registered content-type display name (e.g. "Notes" for `notes`), falling back
/// to the capitalized URL segment.
private func directoryTitle(segment: String, collection: String?, contentTypes: ContentTypeRegistry) -> String {
    if let collection, let descriptor = contentTypes.descriptor(forCollection: collection) {
        return descriptor.displayName
    }
    guard let first = segment.first else { return segment }
    return first.uppercased() + segment.dropFirst()
}
```

Implementation notes for the engineer:
- The `route` inside `DirectoryBuilder.child(for:)` percent-encodes each segment, so a directory chain matches what `postRoute` produces for entries. The builder tree is keyed by the *raw* segment.
- `insert` treats a directory route that has an index page (a page whose route equals the directory route, e.g. `/notes`) as `remainingSegments == [last]` reaching that dir? **No** — trace it: `/notes` → segments `["notes"]` → `remainingSegments.count == 1` puts it in the ROOT's `pages`, not in the `notes` directory. That fails `directoryIndexPinned`. Fix: after all inserts, run a merge pass — for each root (and recursively, each directory's) page whose route (minus trailing slash) equals an existing subdirectory's route (minus trailing slash), move it to that subdirectory's `indexPage`. Implement as a `mergeIndexPages()` method on `DirectoryBuilder` called once before `buildTopLevel`:

```swift
    func mergeIndexPages() {
        pages.removeAll { page in
            let normalized = page.route.hasSuffix("/") ? String(page.route.dropLast()) : page.route
            for (segment, builder) in subdirectories {
                let dirNormalized = String(builder.route.dropLast())
                _ = segment
                if normalized == dirNormalized || page.route == builder.route {
                    builder.indexPage = page
                    return true
                }
            }
            return false
        }
        for builder in subdirectories.values { builder.mergeIndexPages() }
    }
```

  and in `buildSiteURLTree`, call `root.mergeIndexPages()` after the insert loops. Also compare percent-DEcoded forms if the tests reveal a mismatch (ContentScanner emits raw routes; keep both sides raw by comparing against a raw-segment-joined route if needed — the test suite will tell you).
- If the registry test (`directoryTitles`) fails because `notes` is not a registered collection in `ContentTypeRegistry.default`, check `ContentTypeRegistry` for the real collection-backed IDs and adjust the fixture collection name (use one that IS registered, and keep `mixtapes` as the unregistered case). The behavior under test is registry-name-vs-capitalized-fallback, not the specific word.

- [ ] **Step 5: Run the new tests until green**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SiteURLTreeTests`
Expected: all SiteURLTreeTests PASS.

- [ ] **Step 6: Run the whole AnglesiteCore suite (the enum gained cases; exhaustive switches elsewhere may break)**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . 2>&1 | tail -20`
Expected: compile errors, if any, are non-exhaustive `switch`es over `NavigatorTarget` (e.g. `SiteNavigatorModel.isContentRow` uses `if case`, which is fine). Fix any real exhaustive switch by adding the new cases with a no-op/`return false` arm *for now* (Tasks 3–4 give them real behavior). All tests PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteCore/SiteURLTree.swift Sources/AnglesiteCore/NavigatorTree.swift Tests/AnglesiteCoreTests/SiteURLTreeTests.swift
git commit -m "feat(core): URL-tree model for the visitor-facing navigator (#714)"
```

---

### Task 2: Feed probe — `SiteFileTree.feedCollections(siteRoot:)`

**Files:**
- Modify: `Sources/AnglesiteCore/SiteFileTree.swift`
- Test: `Tests/AnglesiteCoreTests/SiteFileTreeTests.swift` (append tests)

**Interfaces:**
- Produces: `SiteFileTree.feedCollections(siteRoot: URL, fileManager: FileManager = .default) -> Set<String>` — collection names that have a per-collection RSS route.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/AnglesiteCoreTests/SiteFileTreeTests.swift` (match the file's existing temp-dir fixture style — read the file first and reuse its helper if one exists):

```swift
@Test("feedCollections finds collections with an rss.xml.ts route and ignores everything else")
func feedCollections() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("feed-probe-\(UUID().uuidString)")
    let fm = FileManager.default
    // notes has a feed; photos has a directory but no rss route; the root rss.xml.ts is site-wide.
    try fm.createDirectory(at: root.appendingPathComponent("src/pages/notes"), withIntermediateDirectories: true)
    try fm.createDirectory(at: root.appendingPathComponent("src/pages/photos"), withIntermediateDirectories: true)
    try Data().write(to: root.appendingPathComponent("src/pages/notes/rss.xml.ts"))
    try Data().write(to: root.appendingPathComponent("src/pages/rss.xml.ts"))
    defer { try? fm.removeItem(at: root) }

    #expect(SiteFileTree.feedCollections(siteRoot: root) == ["notes"])
}

@Test("feedCollections is empty for a missing src/pages")
func feedCollectionsMissingDir() {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("feed-probe-absent-\(UUID().uuidString)")
    #expect(SiteFileTree.feedCollections(siteRoot: root) == [])
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SiteFileTreeTests`
Expected: compile FAIL — `feedCollections` not defined.

- [ ] **Step 3: Implement the probe**

Add to `SiteFileTree` (in `Sources/AnglesiteCore/SiteFileTree.swift`, after `scan`):

```swift
/// Collections that ship a per-collection RSS route. The template materializes
/// `src/pages/<collection>/rss.xml.ts` for every feed-bearing collection (its
/// `FEED_COLLECTIONS` map in src/lib/feeds.ts), so a shallow one-level probe is the cheapest
/// reliable "this directory has a feed" signal (#714). The root-level site-wide feed is not a
/// collection and is ignored.
public static func feedCollections(siteRoot: URL, fileManager: FileManager = .default) -> Set<String> {
    let pagesDir = layout(for: siteRoot, fileManager: fileManager)
        .sourceDir.appendingPathComponent("src/pages")
    guard let children = try? fileManager.contentsOfDirectory(
        at: pagesDir, includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]) else { return [] }
    var result: Set<String> = []
    for dir in children where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
        let rss = dir.appendingPathComponent("rss.xml.ts")
        if fileManager.fileExists(atPath: rss.path(percentEncoded: false)) {
            result.insert(dir.lastPathComponent)
        }
    }
    return result
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SiteFileTreeTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SiteFileTree.swift Tests/AnglesiteCoreTests/SiteFileTreeTests.swift
git commit -m "feat(core): probe per-collection RSS routes for feed-badged directories (#714)"
```

---

### Task 3: Swap `SiteNavigatorModel` + `SiteNavigatorView` to the tree; wire new targets in `SiteWindowModel`

This is one compile/review unit: the model, view, and window-model selection handling interlock.

**Files:**
- Modify: `Sources/AnglesiteApp/SiteNavigatorModel.swift`
- Modify: `Sources/AnglesiteApp/SiteNavigatorView.swift`
- Modify: `Sources/AnglesiteApp/SiteWindowModel.swift:671-700` (`applyNavigatorSelection`)
- Modify: `Sources/AnglesiteApp/SiteWindow.swift:162-185` (navigator wiring — cleanup props removed)
- Test: `Tests/AnglesiteAppTests/SiteWindowModelTests.swift` (fix compile fallout only)

**Interfaces:**
- Consumes: `URLTreeNode`, `buildSiteURLTree`, `SiteFileTree.feedCollections`, `NavigatorTarget.{directory,websiteSettings}` (Tasks 1–2).
- Produces: `SiteNavigatorModel.nodes: [URLTreeNode]` (replaces `sections`), `SiteNavigatorModel.item(for id: String) -> NavigatorItem?` (view/window callbacks keep passing `NavigatorItem`). `target(for:)`, `canRename/canDelete/canDuplicate/canRepurpose`, editing API, `refreshNow`, `saveRedirect` keep their exact signatures.

- [ ] **Step 1: Rework `SiteNavigatorModel`**

In `Sources/AnglesiteApp/SiteNavigatorModel.swift`:

1. Replace `private(set) var sections: [NavigatorSection] = []` with:

```swift
    private(set) var nodes: [URLTreeNode] = []
    /// Flattened id → node lookup, rebuilt with `nodes` (selection, targets, titles).
    private var nodesByID: [String: URLTreeNode] = [:]
```

2. Replace `target(for:)` and add `item(for:)`:

```swift
    func target(for id: String) -> NavigatorTarget? { nodesByID[id]?.target }

    /// Bridge for callbacks that still traffic in `NavigatorItem` (delete/duplicate/repurpose
    /// plumbing in SiteWindow/SiteWindowModel predates the tree).
    func item(for id: String) -> NavigatorItem? {
        guard let node = nodesByID[id] else { return nil }
        return NavigatorItem(id: node.id, title: node.title, target: node.target)
    }
```

3. In `refresh(siteID:siteRoot:)`, replace the `SiteFileTree.scan` block and the
   `buildNavigatorTree` call:

```swift
        let feeds = await Task.detached(priority: .userInitiated) {
            SiteFileTree.feedCollections(siteRoot: siteRoot)
        }.value
        if Task.isCancelled { return }
        postIDs = Set(posts.map(\.id))
        let tree = buildSiteURLTree(
            websiteTitle: websiteTitle, pages: pages, posts: posts, feedCollections: feeds)
        nodes = tree
        nodesByID = Self.index(tree)
```

   with a helper:

```swift
    private static func index(_ nodes: [URLTreeNode]) -> [String: URLTreeNode] {
        var map: [String: URLTreeNode] = [:]
        func walk(_ node: URLTreeNode) {
            map[node.id] = node
            node.children?.forEach(walk)
        }
        nodes.forEach(walk)
        return map
    }
```

4. Replace `updateWebsiteTitle(_:)`:

```swift
    func updateWebsiteTitle(_ title: String) {
        websiteTitle = title
        guard let first = nodes.first, first.kind == .website else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = URLTreeNode(id: first.id, title: trimmed.isEmpty ? "Website" : trimmed,
                                  route: first.route, kind: .website, children: nil)
        nodes[0] = updated
        nodesByID[updated.id] = updated
    }
```

5. In `beginEditing(_:)`, replace the `sections.flatMap(\.items)` title lookup with
   `nodesByID[id]?.title ?? ""`. Everything else (`isContentRow` — it already gates on
   `if case .route` so directory/website rows are automatically not renamable/deletable —
   `commitEditing`, `saveRedirect`, `start/stop/refreshNow`) is unchanged.

- [ ] **Step 2: Rework `SiteNavigatorView`**

Replace the body's section `ForEach` and the cleanup section (`SiteNavigatorView.swift:22-49`) with an outline list; delete the `cleanup`/`onOpenCleanupCandidate`/`onDeleteCleanupCandidate` properties, the `cleanupContent` builder, `cleanupIcon(for:)`, `deleteConfirmationTitle(for:)`, and the two cleanup `@State` vars + the cleanup `confirmationDialog` and delete-failed `alert` (Task 4 rehomes all of that):

```swift
    var body: some View {
        List(selection: $model.selection) {
            OutlineGroup(model.nodes, children: \.children) { node in
                row(for: node)
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.nodes.isEmpty {
                ContentUnavailableView("No content yet", systemImage: "sidebar.left")
            }
        }
        // …the existing .background rename-shortcut button and the "Rename failed" alert stay…
    }

    @ViewBuilder
    private func row(for node: URLTreeNode) -> some View {
        if model.editingItemID == node.id {
            TextField("Title", text: $model.draftTitle)
                // …identical editing TextField modifiers as today (focus, onSubmit, onExitCommand,
                // onChange-of-focus, .task, .tag(node.id)) — keep the existing comments…
        } else {
            Label { Text(node.title) } icon: { icon(for: node) }
                .tag(node.id)
                .lineLimit(1)
                .truncationMode(.middle)
                .contextMenu {
                    if model.canRename(node.id) {
                        Button("Rename") { model.beginEditing(node.id) }
                    }
                    if model.canDuplicate(node.id), let item = model.item(for: node.id) {
                        Button("Duplicate") { onDuplicateRequested(item) }
                    }
                    if model.canRepurpose(node.id), let item = model.item(for: node.id) {
                        Button("Repurpose Post…") { onRepurposeRequested(item) }
                    }
                    if model.canDelete(node.id), let item = model.item(for: node.id) {
                        Button("Delete", role: .destructive) { onDeleteRequested(item) }
                    }
                }
        }
    }

    /// #714 icon table: globe (website settings) / house (home) / doc.richtext (pages, entries) /
    /// folder (directory) — with a radio-waves badge composed on feed-bearing directories until
    /// the custom symbol from docs/art-briefs/2026-07-13-folder-rss-symbol.md ships.
    @ViewBuilder
    private func icon(for node: URLTreeNode) -> some View {
        switch node.kind {
        case .website:
            Image(systemName: "globe")
        case .home:
            Image(systemName: "house")
        case .page:
            Image(systemName: "doc.richtext")
        case .directory(_, hasFeed: false):
            Image(systemName: "folder")
        case .directory(_, hasFeed: true):
            Image(systemName: "folder")
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "dot.radiowaves.up.forward")
                        .font(.system(size: 7, weight: .bold))
                        .symbolRenderingMode(.monochrome)
                        .padding(1)
                        .background(.background, in: .circle)
                        .accessibilityLabel("Has RSS feed")
                }
        }
    }
```

Note: `OutlineGroup` + inline-editing TextField + `.tag` selection is the risky SwiftUI surface here (see the memory about `onSubmit` in sidebar Lists — the focus-loss commit pattern MUST be preserved verbatim). Consult the `swiftui-pro` skill while writing this file.

- [ ] **Step 3: Extend `applyNavigatorSelection` and fix the `SiteWindow` call site**

In `Sources/AnglesiteApp/SiteWindowModel.swift` (`applyNavigatorSelection`, line ~671), add
two cases to the `switch target`:

```swift
        case .websiteSettings:
            // Slice-1 interim: the website row opens the package Info.plist — exactly what the
            // old sidebar Metadata row opened. The full Website Settings surface is slice 2
            // (spec §7, docs/superpowers/specs/2026-07-13-website-design-window-cleanup-design.md).
            guard let site else { return }
            let layout = SiteFileTree.layout(for: site.packageURL)
            guard let infoPlist = layout.infoPlist else { return }
            openFile(FileRef(url: infoPlist, group: .metadata, name: "Info.plist"))
        case .directory(_, let route):
            // Slice-1 interim: show the directory in the preview (its index page if one exists).
            // Slice 2 replaces this with the Collection Settings surface (spec §6).
            Task {
                guard await leaveCurrentEditor(), await leaveCurrentInspector() else { return }
                activeEditor = nil
                inspectorContext = nil
                mainPaneMode = .preview
                preview.navigate(toRoute: route)
            }
```

Check `site.packageURL` is the right property (`SiteStore.Site` carries `packageURL` +
computed `sourceDirectory`/`configDirectory`); if the navigator's `start` received a
different `siteRoot`, mirror whatever `SiteWindow` passes there.

In `Sources/AnglesiteApp/SiteWindow.swift` (sidebar, ~line 162), delete the
`cleanup:`/`onOpenCleanupCandidate:`/`onDeleteCleanupCandidate:` arguments from the
`SiteNavigatorView(...)` call (Task 4 rehomes the model), keeping
`onDeleteRequested`/`onDuplicateRequested`/`onRepurposeRequested` as-is.

- [ ] **Step 4: Build and fix compile fallout**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build --package-path . 2>&1 | grep -E "error" | head`
Expected after fixes: no errors. Known fallout: `Tests/AnglesiteAppTests/SiteWindowModelTests.swift` may construct `NavigatorSection`s or stub `sections` — update those tests to build `URLTreeNode`s / use `nodes` instead, preserving each test's intent (do not delete assertions). Note `swift build` does not compile the app target (`SiteWindow.swift` etc. are in the xcodeproj); ALSO run:

```bash
xcodegen generate
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -5
```

(Run `scripts/copy-plugin.sh` first if `Resources/plugin` is empty in this worktree, with `ANGLESITE_PLUGIN_SRC` pointing at the real plugin checkout.)
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Run the full test suite**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . 2>&1 | tail -10`
Expected: PASS (NavigatorTreeTests still passes — `buildNavigatorTree` still exists until Task 5).

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteApp/SiteNavigatorModel.swift Sources/AnglesiteApp/SiteNavigatorView.swift Sources/AnglesiteApp/SiteWindowModel.swift Sources/AnglesiteApp/SiteWindow.swift Tests/AnglesiteAppTests/SiteWindowModelTests.swift
git commit -m "feat(app): visitor-facing URL-tree sidebar with feed-badged directories (#714)"
```

---

### Task 4: Relocate Cleanup to Site ▸ Cleanup… (main pane)

**Files:**
- Modify: `Sources/AnglesiteApp/SiteWindowModel.swift` (`MainPaneMode` + a `presentCleanup()` method)
- Create: `Sources/AnglesiteApp/ProjectCleanupView.swift`
- Modify: `Sources/AnglesiteApp/SiteWindow.swift:690+` (`mainPaneContent` switch)
- Modify: `Sources/AnglesiteApp/SiteMenuCommands.swift` (menu item after "Audit")

**Interfaces:**
- Consumes: the existing `ProjectCleanupModel` (`hasScanned`, `isScanning`, `isBusy`, `candidates`, `scan()`, `ignore(_:)`, `deleteError`) and the `openCleanupCandidate`/delete-candidate handlers currently passed into `SiteNavigatorView` from `SiteWindow` (find their closures in the pre-Task-3 git history: `git show HEAD~1:Sources/AnglesiteApp/SiteWindow.swift`).
- Produces: `MainPaneMode.cleanup`, `SiteWindowModel.presentCleanup()`, `ProjectCleanupView(cleanup:onOpen:onDelete:)`.

- [ ] **Step 1: Add the pane mode and presenter**

In `Sources/AnglesiteApp/SiteWindowModel.swift`:

```swift
enum MainPaneMode: Equatable {
    case preview
    case editor(FileRef)
    case graph
    case cleanup        // Site ▸ Cleanup… (#714 moved it out of the sidebar)
}
```

and on the model:

```swift
    @MainActor
    func presentCleanup() {
        Task {
            guard await leaveCurrentEditor(), await leaveCurrentInspector() else { return }
            activeEditor = nil
            inspectorContext = nil
            mainPaneMode = .cleanup
        }
    }
```

Fix the two `paneSelection` guards at `SiteWindowModel.swift:209-221` if they switch exhaustively (`.cleanup` should behave like `.preview` for the segmented picker: `paneSelection` returns 0 only for explicit modes it knows — mirror how `.graph`/`.editor` are handled and leave `.cleanup` mapping to the preview segment index 0, and `setPaneSelection(0)` already resets to `.preview`).

- [ ] **Step 2: Create `ProjectCleanupView`**

Create `Sources/AnglesiteApp/ProjectCleanupView.swift` by moving the deleted Task-3 sidebar code (`cleanupContent`, `cleanupIcon(for:)`, `deleteConfirmationTitle(for:)`, the `candidateToDelete`/`candidateToDeleteTitle` state, the delete `confirmationDialog`, and the "Delete failed" alert — recover them from `git show HEAD~1:Sources/AnglesiteApp/SiteNavigatorView.swift`) into a standalone main-pane view:

```swift
import SwiftUI
import AnglesiteCore

/// Main-pane Cleanup surface (Site ▸ Cleanup…). Same rows and actions the sidebar Cleanup
/// section had before #714 moved it out of the visitor-facing navigator.
struct ProjectCleanupView: View {
    @Bindable var cleanup: ProjectCleanupModel
    var onOpen: (DeadAssetScanner.CleanupCandidate) -> Void
    var onDelete: (DeadAssetScanner.CleanupCandidate) async -> Void
    @State private var candidateToDelete: DeadAssetScanner.CleanupCandidate?
    @State private var candidateToDeleteTitle: String = ""

    var body: some View {
        List {
            // …the moved cleanupContent body, verbatim, with the same scan/rescan buttons,
            // candidate rows, context menus, and empty/no-results states…
        }
        .navigationSubtitle("Cleanup")
        // …the moved confirmationDialog + "Delete failed" alert, verbatim…
        .task {
            if !cleanup.hasScanned && !cleanup.isBusy { await cleanup.scan() }
        }
    }
}
```

(The `.task` auto-scan replaces the sidebar's manual "Scan" first-run button being the only
content — opening the pane should just scan. Keep the manual Rescan button.)

- [ ] **Step 3: Wire the pane and the menu**

In `Sources/AnglesiteApp/SiteWindow.swift` `mainPaneContent` (~line 690), add the case, passing the same closures the sidebar used pre-Task-3:

```swift
        case .cleanup:
            ProjectCleanupView(
                cleanup: model.cleanup,
                onOpen: { model.openCleanupCandidate($0) },
                onDelete: { candidate in
                    await model.deleteCleanupCandidate(candidate)
                })
```

(Adapt names to the real closures recovered from `git show HEAD~1:Sources/AnglesiteApp/SiteWindow.swift` — whatever `SiteWindow` previously passed as `onOpenCleanupCandidate`/`onDeleteCleanupCandidate` is what this pane receives; if those were inline closures over `model`, reuse their bodies.)

In `Sources/AnglesiteApp/SiteMenuCommands.swift`, after the "Audit" button:

```swift
            Button("Cleanup…") { model?.presentCleanup() }
                .disabled(model == nil)
```

(Match the surrounding buttons' exact `.disabled` idiom.)

- [ ] **Step 4: Build both targets and run tests**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . 2>&1 | tail -5
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -3
```
Expected: tests PASS, `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/ProjectCleanupView.swift Sources/AnglesiteApp/SiteWindowModel.swift Sources/AnglesiteApp/SiteWindow.swift Sources/AnglesiteApp/SiteMenuCommands.swift
git commit -m "feat(app): move Cleanup from the sidebar to Site ▸ Cleanup… in the main pane (#714)"
```

---

### Task 5: Delete the retired sections builder

**Files:**
- Modify: `Sources/AnglesiteCore/NavigatorTree.swift`
- Modify: `Tests/AnglesiteCoreTests/NavigatorTreeTests.swift`

**Interfaces:**
- Consumes: nothing new. After Tasks 3–4 nothing references `buildNavigatorTree`, `NavigatorSection`, `groupTitles`, `blogCollectionName`, `collectionLabel`, or `siteMetadataItems`. `NavigatorItem`, `NavigatorTarget`, and `postRoute` stay (used by `SiteWindowModel`, `FileItemCommands`, and the tree builder).

- [ ] **Step 1: Verify nothing references the dead code**

Run: `grep -rn "buildNavigatorTree\|NavigatorSection" Sources/ Tests/ --include="*.swift" | grep -v NavigatorTreeTests`
Expected: only `Sources/AnglesiteCore/NavigatorTree.swift` itself. If anything else appears, fix that reference first — do not delete under it.

- [ ] **Step 2: Delete**

From `Sources/AnglesiteCore/NavigatorTree.swift` remove: `NavigatorSection`, `groupTitles`, `blogCollectionName`, `buildNavigatorTree`, `collectionLabel`, `siteMetadataItems`. Keep `NavigatorTarget`, `NavigatorItem`, `postRoute`.

From `Tests/AnglesiteCoreTests/NavigatorTreeTests.swift` remove every test that calls `buildNavigatorTree`; keep `postRouteDerivation` (and any other `postRoute` tests). If that leaves fixtures unused, trim them too.

- [ ] **Step 3: Run the full suite**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteCore/NavigatorTree.swift Tests/AnglesiteCoreTests/NavigatorTreeTests.swift
git commit -m "refactor(core): retire the grouped navigator-sections builder (#714)"
```

---

### Task 6: Full verification + live smoke

**Files:** none (verification only).

- [ ] **Step 1: Full test suite + app build**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . 2>&1 | tail -10
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -3
```
Expected: all PASS, `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Live smoke (use the `verify` skill's spirit — drive the real app)**

Launch the built app against a real test site and confirm: website-titled row first (opens the plist editor); home pinned; a feed-bearing collection folder shows the badge; expanding it lists entries newest-first; rename via Return still commits on focus loss; Site ▸ Cleanup… opens the cleanup pane. Record what was checked in the PR description. If a GUI smoke can't run in this environment, say so explicitly in the PR and file the manual-smoke follow-up rather than claiming it verified.

- [ ] **Step 3: Push and open the PR**

```bash
git push -u origin claude/website-design-window-cleanup-d2010b
gh pr create --title "feat: visitor-facing URL-tree navigator (#714 slice 1)" --body "…summary, spec link, test evidence…

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
gh issue edit 714 --remove-label status:in-progress
```
