# Siri AI Integration — Full Refactor Spec

**Status:** Design — draft
**Note (2026-09-08, #1957):** the visible-elements reporter in §B.1 shipped in the edit overlay and moved to `JS/wysiwyg-engine/src/host/visible-elements.ts` when the click-to-edit overlay was removed; it now posts over the `wysiwyg` bridge (`WYSIWYGOpsDispatcher`) and is installed whether or not a block canvas is mounted.
**Date:** 2026-06-11
**Issues:** #101 (system-wide MCP), #103 (View Annotations), #105 (Foundation Models native chat)
**Depends on:** Phase B — App Intents (#88/#89/#90) — shipped
**Tracking:** macOS 27 platform features; builds on the SiteEntity + four-intent foundation

## Goal

Make Siri AI a first-class co-pilot for Anglesite. A user looking at their site preview
can say "make that heading bigger" and Siri resolves the on-screen element, routes through
the existing edit pipeline, and the change lands in git — no mouse, no overlay click.

This spec covers four phases that together turn Anglesite from "Siri can trigger four
actions" into "Siri understands your site":

| Phase | Deliverable | Key API |
|---|---|---|
| A | Entity model expansion + intent coverage | `AppEntity`, `IndexedEntity`, `EntityStringQuery` |
| B | View Annotations on the preview pane | `appEntityUIElementProvider`, custom canvas annotations |
| C | Foundation Models for on-device intelligence | `LanguageModel`, `@Generable`, `PrivateCloudComputeLanguageModel` |
| D | System-wide MCP exposure | Platform MCP via XPC / `mcpbridge` |

## Non-goals

- No new business logic in intents — they remain thin wrappers over command actors and
  the `EditRouter` pipeline.
- No bypass of plugin security hooks. `pre-deploy-check.sh` runs before every deploy and
  the app surfaces failures rather than allowing override. Siri is another edit initiator,
  not a backdoor.
- No third-party frameworks. Foundation Models is Apple's SDK; MCP bridge is Apple's
  system service.
- No replacement of the existing edit overlay — the JS overlay remains the primary visual
  editing surface. View Annotations add Siri awareness alongside it, not instead of it.
- No migration of DevID chat from Claude to Foundation Models — Claude remains the default
  on DevID. Foundation Models is additive (user can choose) and is the primary path for MAS.

---

## Phase A — Entity Model Expansion + Intent Coverage

### Problem

`SiteEntity` is the only entity. Siri can deploy, backup, audit, and open a site, but
cannot reference or act on anything inside a site — pages, posts, images, components.
The semantic index has site-level granularity only.

### Approach

Introduce a `SiteContentGraph` actor in `AnglesiteCore` that the MCP server populates on
startup and incrementally updates via file-watch events. New entities (`PageEntity`,
`PostEntity`, `ImageEntity`) are thin projections over this graph. New intents delegate
mutations through the existing `EditRouter` pipeline.

The content graph is a read cache — the filesystem is the source of truth. If the user
edits in VS Code and returns to Anglesite, the graph picks up changes on the next MCP
file-watch event or manual refresh.

#### A.1 — `SiteContentGraph` actor

Location: `Sources/AnglesiteCore/SiteContentGraph.swift`

```swift
public actor SiteContentGraph {
    public struct Page: Sendable, Equatable, Identifiable {
        public let id: String          // site-scoped: "{siteID}:page:{route}"
        public let siteID: String
        public let route: String       // e.g. "/about", "/blog/hello-world"
        public let filePath: String    // relative to site root, e.g. "src/pages/about.astro"
        public let title: String?      // extracted from frontmatter or <title>
        public let lastModified: Date
    }

    public struct Post: Sendable, Equatable, Identifiable {
        public let id: String          // "{siteID}:post:{slug}"
        public let siteID: String
        public let collection: String  // Astro content collection name
        public let slug: String
        public let title: String
        public let draft: Bool
        public let publishDate: Date?
        public let tags: [String]
        public let filePath: String
        public let lastModified: Date
    }

    public struct Image: Sendable, Equatable, Identifiable {
        public let id: String          // "{siteID}:image:{relativePath}"
        public let siteID: String
        public let relativePath: String // e.g. "public/images/hero.jpg"
        public let fileName: String
        public let byteSize: Int64?
        public let usedOnPages: [String] // page routes referencing this image
        public let lastModified: Date
    }

    public typealias ChangeHandler = @Sendable (String) async -> Void  // siteID

    private var pages: [String: Page] = [:]     // keyed by Page.id
    private var posts: [String: Post] = [:]
    private var images: [String: Image] = [:]
    private var changeHandler: ChangeHandler?

    public func setChangeHandler(_ handler: ChangeHandler?)

    // --- Bulk load (MCP server startup) ---
    public func load(siteID: String, pages: [Page], posts: [Post], images: [Image])

    // --- Incremental update (MCP file-watch) ---
    public func upsertPage(_ page: Page)
    public func upsertPost(_ post: Post)
    public func upsertImage(_ image: Image)
    public func removePage(id: String)
    public func removePost(id: String)
    public func removeImage(id: String)

    // --- Queries ---
    public func pages(for siteID: String) -> [Page]
    public func posts(for siteID: String) -> [Post]
    public func images(for siteID: String) -> [Image]
    public func page(id: String) -> Page?
    public func post(id: String) -> Post?
    public func image(id: String) -> Image?

    // --- Search ---
    public func searchPages(siteID: String, matching query: String) -> [Page]
    public func searchPosts(siteID: String, matching query: String) -> [Post]

    // --- Teardown (site window closed) ---
    public func unload(siteID: String)
}
```

**Population strategy:** When `LocalSiteRuntime.start()` completes and the MCP client
initializes, it calls a new MCP tool `list_content` (added to the plugin in a paired PR)
that returns pages, posts, and images as structured JSON. The runtime feeds the response
into `SiteContentGraph.load()`. Subsequent file-watch notifications from the MCP server
call `upsertPage` / `removePage` etc.

**Fallback:** If the plugin doesn't support `list_content` (older version), the content
graph stays empty and the new entities return no results. The existing four intents
continue to work.

#### A.2 — New entities

Location: `Sources/AnglesiteIntents/ContentEntities.swift`

**`PageEntity`:**
```swift
public struct PageEntity: AppEntity, IndexedEntity, Identifiable, Sendable {
    public let id: String
    public let displayName: String      // title ?? route
    public let route: String
    public let siteID: String

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Page" }
    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)", subtitle: "\(route)")
    }
    public static var defaultQuery = PageEntityQuery()
}
```

`PageEntityQuery: EntityStringQuery` — reads from `SiteContentGraph`, case-insensitive
substring match on title and route. `suggestedEntities()` returns pages for the
most-recently-used site (from `SiteStore`).

**`PostEntity`:**
```swift
public struct PostEntity: AppEntity, IndexedEntity, Identifiable, Sendable {
    public let id: String
    public let displayName: String     // title
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
}
```

`PostEntityQuery: EntityStringQuery` — searches title, slug, tags, collection name.

**`ImageEntity`:**
```swift
public struct ImageEntity: AppEntity, IndexedEntity, Identifiable, Sendable {
    public let id: String
    public let displayName: String     // fileName
    public let relativePath: String
    public let siteID: String

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Image" }
    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)", subtitle: "\(relativePath)")
    }
    public static var defaultQuery = ImageEntityQuery()
}
```

**Spotlight indexing:** Wire `SiteContentGraph.setChangeHandler` to a new
`ContentSpotlightIndexer` actor (same diff-based pattern as `SpotlightIndexer`) that
indexes pages, posts, and images. Registered in `AnglesiteIntents.bootstrap()` alongside
the existing site-level indexer.

#### A.3 — New intents

Location: `Sources/AnglesiteIntents/ContentIntents.swift`

All new intents follow the same pattern as the existing four: thin wrappers, `@Parameter`
entity resolution, `ProvidesDialog` return.

**`EditContentIntent`:**
```swift
public struct EditContentIntent: AppIntent {
    public static var title: LocalizedStringResource = "Edit Content"
    public static var description = IntentDescription(
        "Edit a page or post in an Anglesite site."
    )

    @Parameter(title: "Site") public var site: SiteEntity
    @Parameter(title: "Content") public var content: String   // natural-language description
    @Parameter(title: "Page") public var page: PageEntity?
    @Parameter(title: "Post") public var post: PostEntity?

    public func perform() async throws -> some IntentResult & ProvidesDialog
}
```

Siri resolves the entity from context ("edit the about page" → `PageEntity`), constructs
an `EditMessage` via the new `IntentEditBridge`, and routes through `EditRouter.apply()`.
The response dialog reports the `EditReply` status.

**`SearchContentIntent`:**
```swift
public struct SearchContentIntent: AppIntent {
    public static var title: LocalizedStringResource = "Search Content"
    public static var description = IntentDescription(
        "Search pages, posts, and images in an Anglesite site."
    )

    @Parameter(title: "Site") public var site: SiteEntity
    @Parameter(title: "Query") public var query: String

    public func perform() async throws -> some IntentResult & ProvidesDialog
}
```

Searches `SiteContentGraph` and returns a dialog listing matching pages, posts, and images
with titles and routes.

**`SiteStatusIntent`:**
```swift
public struct SiteStatusIntent: AppIntent {
    public static var title: LocalizedStringResource = "Site Status"
    public static var description = IntentDescription(
        "Check the current status of an Anglesite site — dev server, health, content counts."
    )

    @Parameter(title: "Site") public var site: SiteEntity

    public func perform() async throws -> some IntentResult & ProvidesDialog
}
```

Returns: dev server state (idle/starting/ready/failed), health badge
(clean/warnings/failures), page count, post count, last deploy time if available.

**`PreviewSiteIntent`:**
```swift
public struct PreviewSiteIntent: AppIntent {
    public static var title: LocalizedStringResource = "Preview Site"
    public static var description = IntentDescription(
        "Open a site preview in Anglesite and show the current state."
    )
    public static var openAppWhenRun = true

    @Parameter(title: "Site") public var site: SiteEntity
    @Parameter(title: "Page") public var page: PageEntity?

    public func perform() async throws -> some IntentResult & ProvidesDialog
}
```

Opens the site window (via `WindowRouter`), optionally navigates the WKWebView to a
specific page route. Returns a dialog confirming which page is being previewed.

**`AddPageIntent` / `AddPostIntent`:**
```swift
public struct AddPageIntent: AppIntent {
    public static var title: LocalizedStringResource = "Add Page"
    public static var description = IntentDescription(
        "Add a new page to an Anglesite site."
    )

    @Parameter(title: "Site") public var site: SiteEntity
    @Parameter(title: "Page Name") public var name: String
    @Parameter(title: "Route") public var route: String?

    public func perform() async throws -> some IntentResult & ProvidesDialog
}
```

Routes through MCP tool `create_page` / `create_post` (plugin paired PR). Returns dialog
with the created file path and route.

**Updated `AnglesiteShortcuts`:**

Add curated phrases for the new intents:
- "What's on my site with \(.applicationName)" → `SearchContentIntent`
- "How is my site doing with \(.applicationName)" → `SiteStatusIntent`
- "Add a page to my site with \(.applicationName)" → `AddPageIntent`

#### A.4 — `IntentEditBridge`

Location: `Sources/AnglesiteCore/IntentEditBridge.swift`

Translates high-level intent parameters into `EditMessage` payloads and routes them
through the existing `EditRouter` pipeline:

```swift
public struct IntentEditBridge: Sendable {
    public typealias RouterProvider = @Sendable (_ siteID: String) async -> EditRouter?

    private let routerProvider: RouterProvider

    public init(routerProvider: @escaping RouterProvider)

    public func applyEdit(
        siteID: String,
        filePath: String,
        selector: JSONValue,
        op: String,
        value: JSONValue?
    ) async -> EditReply
}
```

The `RouterProvider` closure looks up the active `PreviewModel`'s edit router for the
given site. If no site window is open (headless Siri invocation), it starts a headless
`LocalSiteRuntime` (MCP client only, no dev server UI) to service the edit, then tears
it down.

**Headless runtime management:** A new `HeadlessRuntimePool` actor manages ephemeral
`LocalSiteRuntime` instances for intent-driven edits when no window is open. It caches
runtimes for a configurable TTL (default 60s) so rapid successive Siri edits don't
repeatedly spawn/teardown Node processes.

#### A.5 — Plugin paired PR (sibling repo `anglesite`)

The plugin adds two new MCP tools:
- **`list_content`** — returns structured JSON of pages, posts, images for the current
  project. Scans `src/pages/`, content collections, and `public/images/`.
- **`create_page`** / **`create_post`** — scaffolds a new file from template, commits.

These are server-side additions following the existing MCP tool pattern (`server/*.mjs`).
The app PR bumps the bundled plugin pointer after the plugin PR ships.

#### A.6 — Testing

- **`SiteContentGraphTests`** (Swift Testing): load, upsert, remove, unload, search.
  ~15 tests.
- **Entity query tests**: resolution by id, fuzzy match by title/route/slug/tag,
  `suggestedEntities` for MRU site, empty graph returns empty. ~12 tests per entity type.
- **Intent tests**: `Result → dialog` mapping via `SiteOperationsOverride.scoped` and
  a fake `IntentEditBridge`. ~3–5 tests per intent.
- **Integration**: `list_content` response parsing → `SiteContentGraph.load()` round-trip.
  `XCTSkip` when plugin/node not present (same pattern as apply-edit e2e).

---

## Phase B — View Annotations on the Preview Pane

### Problem

Siri's onscreen awareness lets users reference what they see — "make that heading bigger",
"change the hero image". For this to work, Siri needs a mapping from screen regions to
entities and actions.

The preview pane is a `WKWebView`. Standard SwiftUI view annotations (`.appEntityIdentifier()`)
don't apply. We need the **custom canvas view annotation** API.

### Approach

The edit overlay JS already knows every visible element's bounding rect, tag, and CSS
selector (this powers the click-to-edit hover/click flow). We extend this to report
element metadata to Swift, where a `PreviewAnnotationProvider` maps rects to entities
for Siri's onscreen awareness system.

#### B.1 — Overlay element reporting

Extend the existing overlay JS (`JS/edit-overlay/overlay.ts`) with a new message type:

```typescript
interface VisibleElementReport {
    type: "anglesite:visible-elements"
    elements: Array<{
        id: string           // stable element id (data-anglesite-id or generated)
        tag: string
        selector: string     // CSS selector (same engine as click-to-edit)
        rect: { x: number, y: number, width: number, height: number }
        text?: string        // innerText truncated to 120 chars
        src?: string         // for images
        role?: string        // ARIA role
        pagePath?: string    // current page route
    }>
}
```

**Trigger:** The overlay posts this report on:
1. Initial page load (after DOM settles — `MutationObserver` idle callback).
2. Scroll events (debounced 200ms).
3. DOM mutations (debounced 500ms via existing `MutationObserver`).
4. Window resize.

**Performance:** Only report elements within the visible viewport
(`IntersectionObserver`). Cap at 50 elements per report (priority: headings, images,
nav items, interactive elements). This keeps the bridge traffic bounded.

#### B.2 — `PreviewAnnotationProvider`

Location: `Sources/AnglesiteBridge/PreviewAnnotationProvider.swift`

Receives `VisibleElementReport` via the existing `WKScriptMessageHandler` pipeline in
`AnglesiteScriptHandler`, and maps elements to entities:

```swift
@MainActor
public final class PreviewAnnotationProvider {
    private var currentElements: [VisibleElement] = []
    private let contentGraph: SiteContentGraph

    public struct VisibleElement: Sendable, Equatable {
        public let elementID: String
        public let tag: String
        public let selector: String
        public let rect: CGRect
        public let text: String?
        public let src: String?
        public let pagePath: String?
    }

    public func update(_ elements: [VisibleElement])

    /// Maps a visible element to its corresponding AppEntity for Siri resolution.
    public func entity(for elementID: String) -> (any AppEntity)?

    /// Returns all annotated regions for the current viewport.
    public func annotations() -> [(rect: CGRect, entity: any AppEntity)]
}
```

**Entity mapping rules:**
1. If the element is an `<img>` and `src` matches an `ImageEntity` in the content graph →
   return that `ImageEntity`.
2. If the element's `pagePath` matches a `PageEntity` → return that `PageEntity`.
3. If the element has a `data-anglesite-id` that encodes a post slug → return that
   `PostEntity`.
4. Otherwise → return a transient `ElementEntity` (not indexed, but actionable via
   `EditContentIntent`).

#### B.3 — `ElementEntity` (transient, non-indexed)

```swift
public struct ElementEntity: AppEntity, Sendable {
    public let id: String           // "{siteID}:element:{elementID}"
    public let displayName: String  // tag + truncated text
    public let siteID: String
    public let selector: String     // CSS selector for EditMessage routing
    public let pagePath: String

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Element" }
    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)")
    }
    public static var defaultQuery = ElementEntityQuery()
}
```

`ElementEntity` does **not** conform to `IndexedEntity` — it exists only for onscreen
resolution and is not persisted to Spotlight. `ElementEntityQuery` resolves from the
live `PreviewAnnotationProvider` state.

#### B.4 — AppKit integration

The `WKWebView` is hosted in an `NSViewRepresentable` (`WebPreviewView`). To register
the custom canvas annotation provider:

```swift
// In WebPreviewView's NSView coordinator or makeNSView:
webView.appEntityUIElementProvider = { [weak annotationProvider] point in
    guard let provider = annotationProvider else { return nil }
    // Find the element whose rect contains the point
    for (rect, entity) in provider.annotations() {
        if rect.contains(point) {
            return entity
        }
    }
    return nil
}
```

This lets Siri resolve "that heading" or "the image on the right" to a specific entity
when the user points or speaks about something visible in the preview.

#### B.5 — `EditContentIntent` onscreen flow

When Siri resolves an `ElementEntity` via onscreen awareness and the user says "make it
bigger" or "change the color to blue":

1. Siri resolves the `ElementEntity` → has `selector` and `pagePath`.
2. Siri invokes `EditContentIntent` with the entity + natural-language instruction.
3. `EditContentIntent` constructs an `EditMessage` using the entity's selector.
4. Routes through `IntentEditBridge` → `EditRouter` → MCP `apply_edit`.
5. Plugin interprets the edit (CSS property change, text replacement, etc.) and commits.
6. `EditReply` flows back; dialog reports success/failure.

For complex edits ("make it bigger" → which CSS property?), the plugin's `apply_edit`
tool handles interpretation. The app does not run an LLM to disambiguate — the plugin
owns that logic.

#### B.6 — Testing

- **`PreviewAnnotationProviderTests`**: element→entity mapping for each rule (image,
  page, post, element fallback). ~10 tests.
- **Overlay integration**: mock `WKScriptMessage` with `VisibleElementReport` payload →
  verify `PreviewAnnotationProvider` state update. ~5 tests.
- **Manual smoke**: with a site preview open, invoke Siri and reference an on-screen
  element; verify entity resolution and edit routing.

---

## Phase C — Foundation Models for On-Device Intelligence

### Problem

The MAS build compiles out chat entirely (`#if !ANGLESITE_MAS`). Users on the App Store
have no AI assistance. Foundation Models (shipped macOS 26, updated macOS 27) provides
free on-device inference with no API keys, no network for the base tier, and PCC for
heavier tasks — perfect for the sandboxed MAS build.

On the DevID build, Foundation Models provides a complementary tier: instant on-device
responses for simple tasks (summaries, classification, alt-text) while Claude handles
complex multi-step edits.

### Approach

Extract a `ContentAssistant` protocol from `ChatModel`'s LLM-interaction surface. Add a
`FoundationModelAssistant` conformance that uses the `LanguageModel` protocol + guided
generation. The MAS build uses it as the primary (and only) assistant; the DevID build
lets users choose.

#### C.1 — `ContentAssistant` protocol

Location: `Sources/AnglesiteCore/ContentAssistant.swift`

```swift
public protocol ContentAssistant: Sendable {
    func generate(
        prompt: String,
        context: AssistantContext
    ) async throws -> AsyncThrowingStream<String, Error>

    func generateStructured<T: Generable>(
        prompt: String,
        context: AssistantContext,
        resultType: T.Type
    ) async throws -> T

    var capabilities: AssistantCapabilities { get }
}

public struct AssistantContext: Sendable {
    public let siteID: String
    public let siteDirectory: URL
    public let currentPageRoute: String?
    public let currentPageContent: String?
    public let selectedElementSelector: String?
    public let conversationHistory: [AssistantMessage]
}

public struct AssistantMessage: Sendable, Equatable {
    public let role: AssistantRole
    public let content: String
    public enum AssistantRole: Sendable, Equatable {
        case user, assistant, system
    }
}

public struct AssistantCapabilities: Sendable {
    public let supportsStreaming: Bool
    public let supportsStructuredOutput: Bool
    public let supportsVision: Bool
    public let supportsTools: Bool
    public let maxContextTokens: Int?
    public let providerName: String        // "On-Device", "Private Cloud Compute", "Claude"
}
```

#### C.2 — `FoundationModelAssistant`

Location: `Sources/AnglesiteCore/FoundationModelAssistant.swift`

```swift
import FoundationModels

public actor FoundationModelAssistant: ContentAssistant {
    public enum Tier: Sendable {
        case onDevice                        // 3B parameter, free, no network
        case privateCloudCompute             // 32K context, reasoning, iCloud+ required
    }

    private let tier: Tier

    public init(tier: Tier = .onDevice)

    public func generate(
        prompt: String,
        context: AssistantContext
    ) async throws -> AsyncThrowingStream<String, Error>

    public func generateStructured<T: Generable>(
        prompt: String,
        context: AssistantContext,
        resultType: T.Type
    ) async throws -> T

    public var capabilities: AssistantCapabilities {
        switch tier {
        case .onDevice:
            AssistantCapabilities(
                supportsStreaming: true,
                supportsStructuredOutput: true,
                supportsVision: true,        // macOS 27 on-device Vision
                supportsTools: true,
                maxContextTokens: 4096,
                providerName: "On-Device"
            )
        case .privateCloudCompute:
            AssistantCapabilities(
                supportsStreaming: true,
                supportsStructuredOutput: true,
                supportsVision: true,
                supportsTools: true,
                maxContextTokens: 32768,
                providerName: "Private Cloud Compute"
            )
        }
    }
}
```

#### C.3 — `@Generable` structs for guided generation

Location: `Sources/AnglesiteCore/GenerableTypes.swift`

Guided generation ensures the on-device model returns structured data the app can act on
reliably. These structs map directly to edit operations:

```swift
import FoundationModels

@Generable
public struct GeneratedEditCommand: Sendable {
    public let filePath: String
    public let selector: String       // CSS selector targeting the element
    public let operation: String      // "replace-text", "replace-attribute", "replace-image-src"
    public let value: String          // the new content
    public let explanation: String    // human-readable summary of the change
}

@Generable
public struct GeneratedPageMeta: Sendable {
    public let title: String
    public let description: String
    public let slug: String
    public let tags: [String]
}

@Generable
public struct GeneratedAltText: Sendable {
    public let altText: String
    public let isDecorative: Bool
}

@Generable
public struct ContentSummary: Sendable {
    public let summary: String
    public let wordCount: Int
    public let readingTimeMinutes: Int
    public let topics: [String]
}

@Generable
public enum ContentClassification: Sendable {
    case blogPost
    case landingPage
    case documentation
    case portfolio
    case other(description: String)
}
```

These are used by both the `FoundationModelAssistant` (for structured responses) and by
intents (for type-safe Siri→edit bridging).

#### C.4 — On-device tools

Register Foundation Models tools that call back into the app:

```swift
import FoundationModels

struct ApplyEditTool: Tool {
    let bridge: IntentEditBridge
    let siteID: String

    var description: String { "Apply an edit to a page element" }

    struct Input: Sendable {
        let filePath: String
        let selector: String
        let operation: String
        let value: String
    }

    struct Output: Sendable {
        let status: String
        let message: String?
    }

    func call(_ input: Input) async throws -> Output {
        let reply = await bridge.applyEdit(
            siteID: siteID,
            filePath: input.filePath,
            selector: .string(input.selector),
            op: input.operation,
            value: .string(input.value)
        )
        return Output(status: reply.status.rawValue, message: reply.message)
    }
}

struct SearchContentTool: Tool {
    let contentGraph: SiteContentGraph
    let siteID: String

    var description: String { "Search pages, posts, and images in the site" }

    struct Input: Sendable { let query: String }
    struct Output: Sendable { let results: String }

    func call(_ input: Input) async throws -> Output {
        let pages = await contentGraph.searchPages(siteID: siteID, matching: input.query)
        let posts = await contentGraph.searchPosts(siteID: siteID, matching: input.query)
        let formatted = (pages.map { "Page: \($0.title ?? $0.route)" }
                       + posts.map { "Post: \($0.title)" })
                       .joined(separator: "\n")
        return Output(results: formatted)
    }
}
```

These tools give the on-device model the ability to search the site and apply edits,
creating a local agentic loop without network calls.

#### C.5 — Vision capabilities

The macOS 27 on-device model gains Vision. Use cases for Anglesite:

1. **Alt-text generation**: User drops an image → model generates `GeneratedAltText` via
   guided generation → applied as the `alt` attribute.
2. **Screenshot analysis**: Capture the WKWebView preview via `takeSnapshot()` → send to
   model → get `ContentSummary` or layout feedback.
3. **OCR via `OCRTool`**: Extract text from uploaded images (e.g., a design mockup) for
   content scaffolding.

Integration point: `MCPApplyEditRouter` already handles image drops and returns
`ImageResult` with `src`/`srcset`. Alt-text generation slots in as a post-processing step
after the plugin processes the image.

#### C.6 — Local RAG via Spotlight search tool

Foundation Models ships a Spotlight-powered search tool. Wire it up so the on-device model
can search the user's indexed site content (pages, posts, images from Phase A's Spotlight
indexing) without any custom retrieval code:

```swift
let session = LanguageModelSession(tools: [
    .spotlight,    // Apple's built-in Spotlight search tool
    ApplyEditTool(bridge: bridge, siteID: siteID),
    SearchContentTool(contentGraph: graph, siteID: siteID)
])
```

The Spotlight tool gives the model access to the user's indexed entities (pages, posts)
for RAG. Combined with the `SiteContentGraph`-backed `SearchContentTool`, the model can
answer "what did I write about SwiftUI last month?" entirely on-device.

#### C.7 — `ChatModel` refactor

`ChatModel` currently depends directly on `ClaudeAgent`. Refactor to depend on
`ContentAssistant`:

```swift
// Before
private let agent: ClaudeAgent

// After
private let assistant: any ContentAssistant
```

The `ClaudeAgent` gets a `ClaudeAssistant: ContentAssistant` wrapper that preserves the
existing streaming, tool-calling, and undo behavior.

**Target gating:**
```swift
#if ANGLESITE_MAS
    // MAS: Foundation Models only
    let assistant: any ContentAssistant = FoundationModelAssistant(tier: .onDevice)
#else
    // DevID: user chooses in Settings; Claude is default
    let assistant: any ContentAssistant = settings.preferFoundationModels
        ? FoundationModelAssistant(tier: settings.foundationModelTier)
        : ClaudeAssistant(agent: ClaudeAgent(...))
#endif
```

The MAS build gets a chat pane for the first time. The `#if !ANGLESITE_MAS` guard on
`ChatModel` is removed; only `ClaudeAssistant` is behind `#if !ANGLESITE_MAS`.

#### C.8 — Testing

- **`FoundationModelAssistantTests`**: generate, generateStructured, streaming. Uses
  mock `LanguageModel` session (Apple's testing framework from #104). ~8 tests.
- **`@Generable` round-trip tests**: each struct generates and parses correctly. ~5 tests.
- **Tool tests**: `ApplyEditTool` and `SearchContentTool` with fake `IntentEditBridge`
  and `SiteContentGraph`. ~6 tests.
- **`ChatModel` protocol migration**: existing `ChatModelTests` continue to pass with
  `ClaudeAssistant` wrapper. No behavior change.

---

## Phase D — System-Wide MCP Exposure

### Problem

macOS 27 has platform-wide MCP via XPC (`mcpbridge`). External agents (Claude Code CLI,
Xcode agents, other MCP-aware apps) should be able to invoke Anglesite's tools without
Anglesite being frontmost — deploy from the terminal, edit from Xcode, audit from a CI
agent.

### Approach

Apple's system-wide MCP translates App Intents into MCP tool schemas automatically. With
a rich entity and intent model (Phase A), most of the work is done. This phase focuses
on ensuring the intents are well-structured for MCP consumption and adding any
MCP-specific metadata.

#### D.1 — Intent MCP readiness audit

Review all intents and ensure:
1. Every intent parameter has a clear `title` and type annotation.
2. Entity properties surfaced in `displayRepresentation` are sufficient for an agent to
   disambiguate (e.g., a CLI agent needs `route` or `filePath`, not just `displayName`).
3. Return values are structured enough for programmatic consumption (not just dialog
   strings). Where possible, use `ReturnsValue<T>` to return the entity.

#### D.2 — MCP tool descriptors for rich operations

Some Anglesite operations are richer than what a single App Intent naturally expresses.
For these, register custom MCP tool descriptors:

```swift
public struct AnglesiteMCPRegistration {
    public static func register() {
        // The system bridge picks up App Intents automatically.
        // Custom descriptors extend the surface for agent-specific flows:
        MCPToolRegistry.register(
            name: "anglesite_apply_edit",
            description: "Apply a structured edit to a site file",
            inputSchema: EditMessage.mcpSchema,
            handler: { input in
                // Route through IntentEditBridge
            }
        )

        MCPToolRegistry.register(
            name: "anglesite_list_content",
            description: "List pages, posts, and images for a site",
            inputSchema: SiteContentQuery.mcpSchema,
            handler: { input in
                // Query SiteContentGraph
            }
        )
    }
}
```

> **Note:** The exact registration API depends on Apple's shipping `mcpbridge` developer
> surface. If Apple auto-derives MCP tools from App Intents (likely based on WWDC signals),
> custom registration may be unnecessary — the audit in D.1 ensures intents are
> MCP-friendly either way.

#### D.3 — Bootstrap wiring

`AnglesiteIntents.bootstrap()` gains a call to `AnglesiteMCPRegistration.register()`:

```swift
public static func bootstrap() async {
    // ... existing dependency and Spotlight setup ...

    // System-wide MCP (#101)
    AnglesiteMCPRegistration.register()
}
```

#### D.4 — Security considerations

- **Edit intents via system MCP respect the same security hooks.** An external agent
  calling `anglesite_apply_edit` goes through `IntentEditBridge` → `EditRouter` →
  MCP `apply_edit` → plugin hooks. No bypass.
- **Deploy via system MCP still requires confirmation.** `DeploySiteIntent` calls
  `requestConfirmation`; the system MCP bridge surfaces this as a user-approval step
  in the agent's UI.
- **Sandbox (MAS):** Security-scoped bookmark access applies. An MCP call for a site
  the user hasn't granted access to returns an error, not a silent failure.

#### D.5 — Testing

- **Manual smoke:** Invoke Anglesite tools from Claude Code CLI via system MCP. Verify
  deploy confirmation prompt, edit routing, content listing.
- **Unit:** `AnglesiteMCPRegistration` registers the expected tool names and schemas.
  ~3 tests.

---

## Cross-Cutting Concerns

### Concurrency model

All new actors (`SiteContentGraph`, `HeadlessRuntimePool`, `ContentSpotlightIndexer`)
follow the existing pattern: Swift actors with `Sendable` public types. No new
`@MainActor` types except view-layer code (`PreviewAnnotationProvider` is `@MainActor`
because it bridges into AppKit's annotation API).

### Module boundaries

| Module | New types |
|---|---|
| `AnglesiteCore` | `SiteContentGraph`, `IntentEditBridge`, `HeadlessRuntimePool`, `ContentAssistant`, `FoundationModelAssistant`, `GenerableTypes`, `ClaudeAssistant` |
| `AnglesiteBridge` | `PreviewAnnotationProvider`, overlay JS changes |
| `AnglesiteIntents` | `PageEntity`, `PostEntity`, `ImageEntity`, `ElementEntity`, `ContentIntents`, `ContentSpotlightIndexer`, `AnglesiteMCPRegistration` |
| `AnglesiteApp` | `ChatModel` refactored to use `ContentAssistant`; Settings UI for model tier selection |

### Plugin coordination

Phase A requires a plugin paired PR adding `list_content`, `create_page`, `create_post`
MCP tools. Phase B requires no plugin changes (the overlay is app-side). Phases C and D
are app-only.

### MAS / DevID gating

| Feature | DevID | MAS |
|---|---|---|
| All entities + intents | Yes | Yes |
| View Annotations | Yes | Yes |
| `ClaudeAssistant` (chat) | Yes | No (`#if !ANGLESITE_MAS`) |
| `FoundationModelAssistant` | Yes (opt-in) | Yes (default, only option) |
| System-wide MCP | Yes | Yes (sandbox-gated) |

### Error handling

- **Content graph empty:** New entity queries return empty results; existing site-level
  intents unaffected. No crash, no degraded UX — Siri just doesn't surface sub-site
  entities until the plugin populates the graph.
- **Foundation Models unavailable:** Apple Intelligence must be enabled. If not,
  `FoundationModelAssistant` throws a clear error; `ChatModel` shows a dialog directing
  the user to System Settings → Apple Intelligence.
- **MCP tool not found in plugin:** `IntentEditBridge` returns `.failed` with
  "Plugin does not support this operation. Update Anglesite plugin to the latest version."
- **Headless runtime spawn failure:** `HeadlessRuntimePool` returns `.failed` with the
  spawn error; intent surfaces it as a dialog. No zombie processes — the pool has a
  supervised teardown matching `LocalSiteRuntime.stop()`.

---

## Build Sequence

```
Phase A (foundation) ─────────────────────────────────────
  A.1  SiteContentGraph actor + tests
  A.2  PageEntity + PostEntity + ImageEntity + queries + tests
  A.3  ContentSpotlightIndexer + bootstrap wiring
  A.4  IntentEditBridge + HeadlessRuntimePool
  A.5  New intents (EditContent, Search, Status, Preview, AddPage) + tests
  A.6  Plugin paired PR: list_content, create_page, create_post
  A.7  Updated AnglesiteShortcuts phrases
  A.8  Wire LocalSiteRuntime → SiteContentGraph population
  A.9  Integration test: MCP list_content → graph → entity query → Spotlight

Phase B (onscreen awareness) ──── depends on A.2 ────────
  B.1  Overlay JS: VisibleElementReport message type
  B.2  PreviewAnnotationProvider + element→entity mapping
  B.3  ElementEntity (transient)
  B.4  AppKit appEntityUIElementProvider registration
  B.5  EditContentIntent onscreen flow integration
  B.6  Manual smoke: Siri + preview pane

Phase C (Foundation Models) ──── independent of A/B ──────
  C.1  ContentAssistant protocol extraction
  C.2  ClaudeAssistant wrapper (preserves existing behavior)
  C.3  ChatModel refactor: ClaudeAgent → ContentAssistant
  C.4  @Generable types
  C.5  FoundationModelAssistant implementation
  C.6  On-device tools (ApplyEditTool, SearchContentTool)
  C.7  Vision: alt-text generation pipeline
  C.8  Local RAG: Spotlight search tool wiring
  C.9  MAS chat pane enablement (remove #if !ANGLESITE_MAS from ChatModel)
  C.10 DevID Settings: model tier picker
  C.11 Tests

Phase D (system-wide MCP) ──── depends on A.5 ───────────
  D.1  Intent MCP readiness audit
  D.2  Custom MCP tool descriptors (if needed post-audit)
  D.3  Bootstrap wiring
  D.4  Security smoke: confirm gates, sandbox grants
  D.5  Manual smoke: Claude Code CLI → Anglesite tools
```

**Parallelism:** Phases A and C are independent and can be developed concurrently.
Phase B depends on A (needs entities). Phase D depends on A (needs intents). B and D
are independent of each other and of C.

## Acceptance Criteria

### Phase A
- [ ] `SiteContentGraph` populates from MCP `list_content` on site open.
- [ ] `PageEntity`, `PostEntity`, `ImageEntity` discoverable in Spotlight.
- [ ] New intents (edit, search, status, preview, add page) work from Siri and Shortcuts.
- [ ] Edits from intents route through `EditRouter` → MCP `apply_edit` → plugin hooks.
- [ ] Headless edits (no window open) spawn and teardown cleanly.
- [ ] Builds clean on both targets.

### Phase B
- [ ] Preview overlay reports visible elements to Swift.
- [ ] `PreviewAnnotationProvider` maps elements to correct entity types.
- [ ] Siri can resolve "that heading" / "the hero image" to an entity via onscreen awareness.
- [ ] Resolved entity routes through `EditContentIntent` to apply the edit.

### Phase C
- [ ] `ContentAssistant` protocol extracted; `ChatModel` uses it.
- [ ] `FoundationModelAssistant` produces streamed and structured responses.
- [ ] `@Generable` types round-trip correctly.
- [ ] On-device tools call back into `IntentEditBridge` and `SiteContentGraph`.
- [ ] MAS build has a working chat pane using Foundation Models.
- [ ] DevID Settings allows choosing between Claude and Foundation Models.
- [ ] Alt-text generation works on image drop.

### Phase D
- [ ] All intents are MCP-consumable by external agents.
- [ ] Deploy confirmation surfaces in agent UI.
- [ ] Security hooks (pre-deploy scan, sandbox grants) enforced via MCP path.
- [ ] Claude Code CLI can invoke Anglesite deploy/edit/audit via system MCP.
