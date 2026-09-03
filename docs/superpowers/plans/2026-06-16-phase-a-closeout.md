# Phase A Closeout Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish Phase A by adding the missing A.9 end-to-end integration test (#143) and wiring `PreviewSiteIntent`'s page-route navigation through to the live preview, then close #139 and #143.

**Architecture:** The content intents already shipped; this plan adds (1) a deterministic in-memory e2e test of the `list_content → SiteContentGraph → entity query → Spotlight diff` pipeline, and (2) page navigation: `PreviewSiteIntent` carries `page?.route` through `WindowRouter` to the opened `SiteWindow`, which tells its `PreviewModel` to show that route. The only non-trivial logic — composing a target URL from the dev-server base URL and a route — lives in a pure, CI-tested `AnglesiteCore` helper; the SwiftUI/App glue stays mechanical and is build-verified only (App-target tests can't run on CI per CLAUDE.md).

**Tech Stack:** Swift 6.4 / Xcode 27, Swift Testing (`@Test`/`#expect`), SwiftUI + `@Observable`, AppIntents, CoreSpotlight, SwiftPM (`swift test`) + `xcodebuild`.

## Global Constraints

- Swift Testing for new unit tests (`@Test` / `#expect`), not XCTest. Match the existing `AppIntentsTests` suite style.
- New e2e + unit tests must run **always-on** under `swift test` — no `pythonAvailable`/node gating (Decision 1).
- App-target types (`PreviewModel`, `SiteWindow`, `PreviewView`) are NOT CI-testable (hosted app tests blocked on macOS-15 runners) — push testable logic into `AnglesiteCore`/`AnglesiteIntents`; verify App glue with `xcodebuild` builds of both schemes.
- Module dependency direction: `AnglesiteApp → AnglesiteIntents → AnglesiteCore`. Never import App into Intents/Core.
- Worktree builds: run `xcodegen generate` first and set `ANGLESITE_PLUGIN_SRC=/Users/dwk/Developer/github.com/Anglesite/anglesite` before `xcodebuild` (the default `../anglesite` resolves wrong from a worktree).
- New-type id format is fixed by the parser: page `"<siteID>:page:<route>"`, post `"<siteID>:post:<slug>"`, image `"<siteID>:image:<relativePath>"`.
- Commit message trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

## File Structure

- **Create** `Sources/AnglesiteCore/PreviewNavigation.swift` — pure `route + base → URL` composer (Task 1).
- **Create** `Tests/AnglesiteCoreTests/PreviewNavigationTests.swift` — Task 1 tests.
- **Modify** `Sources/AnglesiteIntents/WindowRouter.swift` — carry + consume a per-site route (Task 2).
- **Create** `Tests/AnglesiteIntentsTests/WindowRouterTests.swift` — Task 2 tests.
- **Modify** `Sources/AnglesiteIntents/ContentIntents.swift` — page-aware `ContentDialogs.preview`, `PreviewSiteIntent` wiring (Task 3).
- **Modify** `Tests/AnglesiteIntentsTests/ContentIntentsTests.swift` — Task 3 dialog test.
- **Modify** `Sources/AnglesiteApp/PreviewModel.swift` — `navigate(toRoute:)` + `displayURL` (Task 4).
- **Modify** `Sources/AnglesiteApp/SiteWindow.swift` — consume route, render `displayURL` (Task 4).
- **Create** `Tests/AnglesiteIntentsTests/ContentPipelineE2ETests.swift` — A.9 e2e test (Task 5).

---

## Task 1: `PreviewNavigation` URL composer (AnglesiteCore)

**Files:**
- Create: `Sources/AnglesiteCore/PreviewNavigation.swift`
- Test: `Tests/AnglesiteCoreTests/PreviewNavigationTests.swift`

**Interfaces:**
- Produces: `public enum PreviewNavigation { public static func targetURL(base: URL, route: String) -> URL }` — consumed by `PreviewModel.displayURL` (Task 4). `base` is the dev-server root URL (e.g. `http://localhost:4321/`); `route` is a site-absolute path (e.g. `/about`). Empty route or `"/"` returns `base` unchanged; a route without a leading slash is normalized to have one; the base's scheme/host/port are preserved with no double slash.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/PreviewNavigationTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

struct PreviewNavigationTests {
    static let base = URL(string: "http://localhost:4321/")!

    @Test("absolute route is composed onto the base host/port")
    func absoluteRoute() {
        #expect(PreviewNavigation.targetURL(base: Self.base, route: "/about")
                == URL(string: "http://localhost:4321/about")!)
    }

    @Test("route without a leading slash is normalized")
    func normalizesLeadingSlash() {
        #expect(PreviewNavigation.targetURL(base: Self.base, route: "about")
                == URL(string: "http://localhost:4321/about")!)
    }

    @Test("nested route is preserved")
    func nestedRoute() {
        #expect(PreviewNavigation.targetURL(base: Self.base, route: "/blog/post-1")
                == URL(string: "http://localhost:4321/blog/post-1")!)
    }

    @Test("root route returns the base")
    func rootRoute() {
        #expect(PreviewNavigation.targetURL(base: Self.base, route: "/") == Self.base)
    }

    @Test("empty / whitespace route returns the base")
    func emptyRoute() {
        #expect(PreviewNavigation.targetURL(base: Self.base, route: "") == Self.base)
        #expect(PreviewNavigation.targetURL(base: Self.base, route: "   ") == Self.base)
    }

    @Test("base without a trailing slash does not double up")
    func baseNoTrailingSlash() {
        let base = URL(string: "http://localhost:4321")!
        #expect(PreviewNavigation.targetURL(base: base, route: "/about")
                == URL(string: "http://localhost:4321/about")!)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter PreviewNavigationTests`
Expected: FAIL — `cannot find 'PreviewNavigation' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/AnglesiteCore/PreviewNavigation.swift`:

```swift
import Foundation

/// Composes the URL the live-preview WKWebView should load when a page route is requested
/// (e.g. by `PreviewSiteIntent`). Pure and `AnglesiteCore`-scoped so it's unit-testable on CI —
/// the App-target glue that calls it (`PreviewModel`) is not.
public enum PreviewNavigation {
    /// The absolute preview URL for `route` against the dev-server `base`.
    /// `route` is treated as a site-absolute path; `base`'s scheme/host/port are preserved.
    /// An empty route or `"/"` returns `base` (the site root).
    public static func targetURL(base: URL, route: String) -> URL {
        let trimmed = route.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "/" else { return base }
        let path = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
        comps.path = path
        return comps.url ?? base
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter PreviewNavigationTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/PreviewNavigation.swift Tests/AnglesiteCoreTests/PreviewNavigationTests.swift
git commit -m "feat(core): PreviewNavigation route→URL composer for preview navigation

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `WindowRouter` per-site route plumbing (AnglesiteIntents)

**Files:**
- Modify: `Sources/AnglesiteIntents/WindowRouter.swift`
- Test: `Tests/AnglesiteIntentsTests/WindowRouterTests.swift` (create)

**Interfaces:**
- Consumes: nothing new.
- Produces: `func requestOpen(siteID: String, route: String? = nil)` (route-carrying overload of the existing method) and `func consumeRoute(for siteID: String) -> String?` (consume-once, per-site). The existing `requested` open-trigger and its clearing by `SitesWindowRoot` are unchanged. `PreviewSiteIntent` (Task 3) calls `requestOpen(siteID:route:)`; `SiteWindow` (Task 4) calls `consumeRoute(for:)`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteIntentsTests/WindowRouterTests.swift`:

```swift
import Testing
@testable import AnglesiteIntents

@MainActor
struct WindowRouterTests {
    @Test("requestOpen with a route sets the open trigger and stores the route once")
    func requestOpenWithRoute() {
        let router = WindowRouter.shared
        router.requested = nil
        _ = router.consumeRoute(for: "siteA")   // clear any prior state

        router.requestOpen(siteID: "siteA", route: "/about")
        #expect(router.requested == "siteA")
        #expect(router.consumeRoute(for: "siteA") == "/about")
        // Consume-once: a second read is nil.
        #expect(router.consumeRoute(for: "siteA") == nil)
    }

    @Test("requestOpen without a route stores no route")
    func requestOpenNoRoute() {
        let router = WindowRouter.shared
        _ = router.consumeRoute(for: "siteB")
        router.requestOpen(siteID: "siteB")
        #expect(router.requested == "siteB")
        #expect(router.consumeRoute(for: "siteB") == nil)
    }

    @Test("a route requested for one site is not consumed by another")
    func routeIsPerSite() {
        let router = WindowRouter.shared
        _ = router.consumeRoute(for: "siteA")
        _ = router.consumeRoute(for: "siteB")
        router.requestOpen(siteID: "siteA", route: "/contact")
        #expect(router.consumeRoute(for: "siteB") == nil)
        #expect(router.consumeRoute(for: "siteA") == "/contact")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter WindowRouterTests`
Expected: FAIL — `value of type 'WindowRouter' has no member 'consumeRoute'` / extra argument `route`.

- [ ] **Step 3: Write the implementation**

Replace the body of `Sources/AnglesiteIntents/WindowRouter.swift` (keep the imports and the `@MainActor @Observable public final class WindowRouter` declaration; replace from `public static let shared` through the end of the class):

```swift
@MainActor
@Observable
public final class WindowRouter {
    public static let shared = WindowRouter()
    private init() {}

    /// The site id the intent asked to open; the scene clears it after handling.
    public var requested: String?

    /// Pending page route per site, set alongside an open request and consumed once by the
    /// site's window. Keyed by siteID so one site's window can't pick up another's route.
    private var pendingRoute: [String: String] = [:]

    public func requestOpen(siteID: String, route: String? = nil) {
        requested = siteID
        if let route { pendingRoute[siteID] = route }
    }

    /// Take (and clear) the route requested for `siteID`, if any. Returns `nil` after the first
    /// read or when no route was requested.
    public func consumeRoute(for siteID: String) -> String? {
        pendingRoute.removeValue(forKey: siteID)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter WindowRouterTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteIntents/WindowRouter.swift Tests/AnglesiteIntentsTests/WindowRouterTests.swift
git commit -m "feat(intents): WindowRouter carries a per-site preview route

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Page-aware preview dialog + `PreviewSiteIntent` wiring (AnglesiteIntents)

**Files:**
- Modify: `Sources/AnglesiteIntents/ContentIntents.swift` (the `PreviewSiteIntent` struct ~lines 85-108 and `ContentDialogs.preview` ~lines 214-216)
- Test: `Tests/AnglesiteIntentsTests/ContentIntentsTests.swift` (add one test)

**Interfaces:**
- Consumes: `WindowRouter.requestOpen(siteID:route:)` (Task 2), `PageEntity.route` / `PageEntity.displayName` (existing).
- Produces: `ContentDialogs.preview(siteName: String, pageName: String? = nil) -> String` — the default-`nil` parameter preserves existing call sites.

- [ ] **Step 1: Write the failing test**

Add to `Tests/AnglesiteIntentsTests/ContentIntentsTests.swift` (inside the existing test type for `ContentDialogs`; if unsure, add a new `@Suite` extension mirroring the file's style):

```swift
@Test("preview dialog names the page when one is supplied")
func previewDialogWithPage() {
    #expect(ContentDialogs.preview(siteName: "Alpha") == "Opening Alpha.")
    #expect(ContentDialogs.preview(siteName: "Alpha", pageName: "About")
            == "Opening the About page of Alpha.")
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter previewDialogWithPage`
Expected: FAIL — extra argument `pageName` in call.

- [ ] **Step 3: Update `ContentDialogs.preview`**

In `Sources/AnglesiteIntents/ContentIntents.swift`, replace:

```swift
    public static func preview(siteName: String) -> String {
        "Opening \(siteName)."
    }
```

with:

```swift
    public static func preview(siteName: String, pageName: String? = nil) -> String {
        if let pageName { return "Opening the \(pageName) page of \(siteName)." }
        return "Opening \(siteName)."
    }
```

- [ ] **Step 4: Wire the route + page-aware dialog into `PreviewSiteIntent`**

In the same file, replace the `PreviewSiteIntent` doc comment + `perform()` (the block at ~lines 85-108). Replace:

```swift
/// Opens the site window. `openAppWhenRun` brings Anglesite forward; the actual window open
/// happens via `WindowRouter`, which the "Sites" scene observes.
///
/// The `page` parameter is accepted (per the A.5 spec) but does not yet drive in-preview
/// navigation to that page — delivering the route to the right `SiteWindow`'s WKWebView is a
/// follow-up. Today the intent opens the site; the dialog deliberately doesn't claim more.
public struct PreviewSiteIntent: AppIntent {
```

with:

```swift
/// Opens the site window. `openAppWhenRun` brings Anglesite forward; the actual window open
/// happens via `WindowRouter`, which the "Sites" scene observes. When a `page` is supplied, its
/// route rides along on the open request; `SiteWindow` consumes it and navigates the preview's
/// WKWebView to that page once the dev server is ready (cold-open included).
public struct PreviewSiteIntent: AppIntent {
```

And replace the `perform()` body:

```swift
    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        WindowRouter.shared.requestOpen(siteID: site.id)
        return .result(dialog: IntentDialog(stringLiteral: ContentDialogs.preview(siteName: site.displayName)))
    }
```

with:

```swift
    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        WindowRouter.shared.requestOpen(siteID: site.id, route: page?.route)
        return .result(dialog: IntentDialog(stringLiteral: ContentDialogs.preview(siteName: site.displayName, pageName: page?.displayName)))
    }
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --filter previewDialogWithPage`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteIntents/ContentIntents.swift Tests/AnglesiteIntentsTests/ContentIntentsTests.swift
git commit -m "feat(intents): PreviewSiteIntent carries page route + names the page

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: `PreviewModel` navigation + `SiteWindow` glue (AnglesiteApp, build-verified)

**Files:**
- Modify: `Sources/AnglesiteApp/PreviewModel.swift` (add after `openSiteID` ~line 16, and after `readyURL` ~line 101)
- Modify: `Sources/AnglesiteApp/SiteWindow.swift` (the `PreviewView(url:...)` call ~line 237 and after `preview.open(...)` ~line 337)

**Interfaces:**
- Consumes: `PreviewNavigation.targetURL(base:route:)` (Task 1), `WindowRouter.consumeRoute(for:)` (Task 2).
- Produces: `PreviewModel.navigate(toRoute:)` and `PreviewModel.displayURL` — used by `SiteWindow`.

**Note:** No unit test — `PreviewModel`/`SiteWindow` are App-target and not CI-testable (Global Constraints). The testable logic (URL composition) was covered in Task 1. This task is verified by the `xcodebuild` builds in Task 6. Still, write the exact code below.

- [ ] **Step 1: Add navigation state to `PreviewModel`**

In `Sources/AnglesiteApp/PreviewModel.swift`, immediately after the `openSiteID` property (the line `private(set) var openSiteID: String?`), add:

```swift

    /// The page route the preview should show, set by `navigate(toRoute:)` (e.g. from
    /// `PreviewSiteIntent`). `nil` means the site root. Persisted, not consumed, so a dev-server
    /// restart that rebinds the port re-derives the target against the new base URL.
    private(set) var activeRoute: String?
```

- [ ] **Step 2: Add `navigate(toRoute:)` and `displayURL`**

In the same file, immediately after the `readyURL` computed property (the closing `}` of `var readyURL`), add:

```swift

    /// Show `route` in the preview. Safe to call before the runtime is `.ready` — `displayURL`
    /// derives the target lazily once a base URL exists (the cold-open Siri case).
    func navigate(toRoute route: String) { activeRoute = route }

    /// The URL the preview WKWebView should load: the active page route against the ready base
    /// URL, or the base URL itself when no route is active. `nil` until the runtime is `.ready`.
    var displayURL: URL? {
        guard let base = readyURL else { return nil }
        guard let route = activeRoute else { return base }
        return PreviewNavigation.targetURL(base: base, route: route)
    }
```

- [ ] **Step 3: Render `displayURL` and consume the route in `SiteWindow`**

In `Sources/AnglesiteApp/SiteWindow.swift`, find the ready-state `PreviewView` call (~line 237):

```swift
                PreviewView(url: url, router: preview.editRouter, annotationProvider: annotationProvider)
```

replace with:

```swift
                PreviewView(url: preview.displayURL ?? url, router: preview.editRouter, annotationProvider: annotationProvider)
```

Then find, in `loadAndStart()`, the line (~337):

```swift
        preview.open(siteID: resolved.id, siteDirectory: resolved.path)
```

and add immediately after it:

```swift
        // A page route from `PreviewSiteIntent` (#139): navigate once the dev server is ready.
        if let route = WindowRouter.shared.consumeRoute(for: resolved.id) {
            preview.navigate(toRoute: route)
        }
```

- [ ] **Step 4: Build the App target to verify it compiles**

Run:
```bash
xcodegen generate
ANGLESITE_PLUGIN_SRC=/Users/dwk/Developer/github.com/Anglesite/anglesite \
  xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/PreviewModel.swift Sources/AnglesiteApp/SiteWindow.swift
git commit -m "feat(app): navigate the preview to a PreviewSiteIntent page route

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: A.9 end-to-end integration test (#143)

**Files:**
- Create: `Tests/AnglesiteIntentsTests/ContentPipelineE2ETests.swift`

**Interfaces:**
- Consumes (all existing, merged): `ContentListing.parse(jsonText:siteID:)`, `SiteContentGraph.load/pages(for:)/upsertPage/removePost`, `ContentGraphOverride.$scoped`, `PageEntityQuery/PostEntityQuery/ImageEntityQuery.entities`, `ContentSpotlightIndexer(graph:backend:)`/`reindex(siteID:)`/`Outcome`, `ContentSpotlightBackend`.
- Produces: nothing (the test IS the deliverable).

This is the missing seam: every segment is unit-tested in isolation, but no test runs the whole chain. The test is the deliverable, so steps 1–2 are write-then-run; there is no implementation step.

- [ ] **Step 1: Write the e2e test**

Create `Tests/AnglesiteIntentsTests/ContentPipelineE2ETests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore
@testable import AnglesiteIntents

/// A.9 (#143). The one test that runs the full content pipeline end to end:
/// `list_content` JSON → parser → `SiteContentGraph` → entity queries → `ContentSpotlightIndexer`
/// diff, then a graph mutation → re-index diff. The individual segments are covered by
/// `ContentListingTests`, `ContentEntitiesTests`, and `ContentSpotlightIndexerTests`; this stitches
/// them together. Pure in-memory and always-on (no node/python): the real parser runs on a real
/// `list_content`-shaped payload, but no subprocess is spawned (the MCP round-trip is covered by
/// `LocalSiteRuntimeGraphTests`).
extension AppIntentsTests {
    @Suite("ContentPipelineE2E", .serialized)
    struct ContentPipelineE2ETests {
        /// Records backend calls so we can assert the index/delete diff. Mirrors the established
        /// `RecordingBackend` pattern from `ContentSpotlightIndexerTests`.
        actor RecordingBackend: ContentSpotlightBackend {
            private(set) var indexedPages: [[PageEntity]] = []
            private(set) var indexedPosts: [[PostEntity]] = []
            private(set) var indexedImages: [[ImageEntity]] = []
            private(set) var deletedPages: [[String]] = []
            private(set) var deletedPosts: [[String]] = []
            private(set) var deletedImages: [[String]] = []
            func indexPages(_ e: [PageEntity]) async throws { indexedPages.append(e) }
            func indexPosts(_ e: [PostEntity]) async throws { indexedPosts.append(e) }
            func indexImages(_ e: [ImageEntity]) async throws { indexedImages.append(e) }
            func deletePages(identifiers: [String]) async throws { deletedPages.append(identifiers) }
            func deletePosts(identifiers: [String]) async throws { deletedPosts.append(identifiers) }
            func deleteImages(identifiers: [String]) async throws { deletedImages.append(identifiers) }
        }

        /// Realistic `list_content` payload: 2 pages, 2 posts (one draft), 1 image.
        static let payload = """
        {
          "pages": [
            {"route": "/about", "filePath": "src/pages/about.astro", "title": "About", "lastModified": "2026-06-11T12:00:00Z"},
            {"route": "/contact", "filePath": "src/pages/contact.astro", "title": "Contact", "lastModified": "2026-06-11T12:00:00Z"}
          ],
          "posts": [
            {"collection": "blog", "slug": "hello", "title": "Hello World", "draft": false,
             "publishDate": "2026-06-11T12:00:00Z", "tags": ["intro"],
             "filePath": "src/content/blog/hello.md", "lastModified": "2026-06-11T12:00:00Z"},
            {"collection": "blog", "slug": "draft-news", "title": "Draft News", "draft": true,
             "tags": ["news"], "filePath": "src/content/blog/draft-news.md", "lastModified": "2026-06-11T12:00:00Z"}
          ],
          "images": [
            {"relativePath": "public/images/hero.jpg", "fileName": "hero.jpg", "byteSize": 12345,
             "usedOnPages": ["/about"], "lastModified": "2026-06-11T12:00:00Z"}
          ]
        }
        """

        @Test("list_content → graph → entity queries → Spotlight index → mutation diff")
        func fullPipeline() async throws {
            let site = AppIntentsTests.aSite

            // 1. Parse the MCP list_content payload.
            let listing = try ContentListing.parse(jsonText: Self.payload, siteID: site)
            #expect(listing.pages.count == 2)
            #expect(listing.posts.count == 2)
            #expect(listing.posts.contains { $0.draft })
            #expect(listing.images.count == 1)

            // 2. Populate the graph.
            let graph = SiteContentGraph()
            await graph.load(siteID: site, pages: listing.pages, posts: listing.posts, images: listing.images)
            #expect(await graph.pages(for: site).count == 2)
            #expect(await graph.posts(for: site).count == 2)

            // 3. Entity queries resolve from the graph.
            try await ContentGraphOverride.$scoped.withValue(graph) {
                let pages = try await PageEntityQuery().entities(for: ["\(site):page:/about"])
                #expect(pages.first?.route == "/about")
                let posts = try await PostEntityQuery().entities(matching: "hello")
                #expect(posts.map(\.slug) == ["hello"])
                let images = try await ImageEntityQuery().entities(matching: "hero")
                #expect(images.count == 1)
            }

            // 4. Index into Spotlight (recording backend). 2 pages + 2 posts + 1 image = 5.
            let backend = RecordingBackend()
            let indexer = ContentSpotlightIndexer(graph: graph, backend: backend)
            let first = try await indexer.reindex(siteID: site)
            #expect(first == .init(indexed: 5, removed: 0))
            #expect(await Set(backend.indexedPages.first?.map(\.route) ?? []) == ["/about", "/contact"])
            #expect(await Set(backend.indexedPosts.first?.map(\.slug) ?? []) == ["hello", "draft-news"])
            #expect(await backend.deletedPosts.isEmpty)

            // 5. Mutate: remove the draft post, edit the about page. Re-index → correct diff.
            await graph.removePost(id: "\(site):post:draft-news")
            await graph.upsertPage(SiteContentGraph.Page(
                id: "\(site):page:/about", siteID: site, route: "/about",
                filePath: "src/pages/about.astro", title: "About Us",
                lastModified: AppIntentsTests.t0
            ))
            let second = try await indexer.reindex(siteID: site)
            #expect(second == .init(indexed: 4, removed: 1))            // 2 pages + 1 post + 1 image; 1 post removed
            #expect(await backend.deletedPosts.last == ["\(site):post:draft-news"])
            #expect(await backend.indexedPages.last?.contains { $0.displayName == "About Us" } == true)
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it passes**

Run: `swift test --filter ContentPipelineE2E`
Expected: PASS (1 test). If it fails on the indexed/removed counts, re-derive from the payload (5 entities initially; after removing 1 post and editing 1 page: 4 indexed, 1 removed) — do not weaken assertions to force a pass.

- [ ] **Step 3: Commit**

```bash
git add Tests/AnglesiteIntentsTests/ContentPipelineE2ETests.swift
git commit -m "test(intents): A.9 end-to-end content pipeline integration test (#143)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Closeout — build both schemes, full suite, close issues

**Files:** none (verification + issue housekeeping).

- [ ] **Step 1: Run the full SwiftPM test suite**

Run: `swift test 2>&1 | tail -20`
Expected: all tests pass (existing 270 + the new `PreviewNavigation` (6), `WindowRouter` (3), `previewDialogWithPage` (1), and `ContentPipelineE2E` (1)). If a stale lock hangs it, check `pgrep -fl swift-test` and kill the orphan.

- [ ] **Step 2: Build the DevID scheme**

Run:
```bash
xcodegen generate
ANGLESITE_PLUGIN_SRC=/Users/dwk/Developer/github.com/Anglesite/anglesite \
  xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Build the MAS scheme**

Run:
```bash
ANGLESITE_PLUGIN_SRC=/Users/dwk/Developer/github.com/Anglesite/anglesite \
  xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Verify #139's intents are present and tested (no code change expected)**

Run: `swift test --filter ContentIntents 2>&1 | tail -5`
Expected: PASS. This confirms the already-shipped A.5 intents compile and pass on this branch — the basis for closing #139.

- [ ] **Step 5: Push the branch and open the PR**

```bash
git push -u origin worktree-phase-a-closeout
gh pr create --title "Close out Phase A: A.9 e2e test (#143) + PreviewSite navigation (#139)" \
  --body "$(cat <<'EOF'
Finishes Phase A.

- **#143 (A.9):** adds the end-to-end content-pipeline integration test (list_content → graph → entity queries → Spotlight diff → mutation diff), always-on under `swift test`.
- **#139 (A.5):** the content intents already shipped (#136–#142); this wires the previously-unused `PreviewSiteIntent.page` route through `WindowRouter` → `SiteWindow` → `PreviewModel` so Siri "preview my about page" navigates the live preview (cold-open included). URL composition is a CI-tested `AnglesiteCore` helper.

Both schemes build; full `swift test` green.

Closes #143
Closes #139

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 6: Confirm the issues will close**

The `Closes #143` / `Closes #139` lines close both on merge. Remove the `status:in-progress` label is automatic on close. Report the PR URL to the user.

---

## Self-Review

**Spec coverage:**
- #143 (A.9 e2e test) → Task 5. ✅
- `PreviewSiteIntent` page navigation (incl. cold-open) → Tasks 1 (URL helper), 2 (route plumbing), 3 (intent wiring + dialog), 4 (App glue). ✅
- In-memory always-on test substrate (Decision 1) → Task 5 (no python gating). ✅
- Full cold-open navigation (Decision 2) → Task 4 `displayURL` derives lazily once `.ready`. ✅
- CI-testable core / build-verified glue (CLAUDE.md) → Task 1 tested; Task 4 build-only; Task 6 builds both schemes. ✅
- Verify #139 + close both (Part C) → Task 6 steps 4–6. ✅

**Type consistency:** `PreviewNavigation.targetURL(base:route:)` defined in Task 1 is called identically in Task 4. `WindowRouter.requestOpen(siteID:route:)`/`consumeRoute(for:)` defined in Task 2 are called identically in Tasks 3/4. `ContentDialogs.preview(siteName:pageName:)` defined in Task 3 matches its test. `ContentSpotlightIndexer`/`Outcome`/`ContentSpotlightBackend` and `ContentListing.parse` signatures in Task 5 match the merged source. Graph id formats (`<site>:post:draft-news`, `<site>:page:/about`) match the parser. ✅

**Placeholder scan:** No TBD/TODO/"handle edge cases"/"similar to" — every code step has complete code. ✅

**Note on spec refinement:** The spec sketched `pendingRoute` + `navigationTarget` on `PreviewModel`; this plan uses a computed `displayURL` + persisted `activeRoute` instead — same observable behavior (cold-open handled), but it also survives a dev-server port change and needs no `PreviewView` change. Consistent with the approved design's intent.
