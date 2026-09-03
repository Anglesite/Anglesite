# V-1.2 Personal Content Types Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the personal IndieWeb post types (Note, Article, Photo, Album, Bookmark, Reply, Like) end-to-end so each scaffolds, `astro build`s green, and renders correct microformats2.

**Architecture:** Three layers, each consuming the one before. (1) `ContentTypeRegistry` gains an `imageArray` field kind plus Album + Like descriptors. (2) `ContentScaffold.renderEntry` turns any descriptor into a frontmatter file; `NativeContentOperations.createTyped` writes + commits it. (3) `Resources/Template/` gains minimal Astro collections, one shared `h-entry` layout, per-collection entry routes, and seeded sample entries so the types build and render with mf2 classes.

**Tech Stack:** Swift 6 (Swift Testing), Astro 5 (content collections + `astro:content` `render` API), Node for the build smoke.

## Global Constraints

- **App-only.** No plugin PR, no `Resources/plugin` change. (Spec decision 2.)
- **One schema, registry-named.** Astro collection schemas and scaffolded frontmatter use the registry field names verbatim (`publishDate`, `body`, `likeOf`, …) — never the legacy `pubDate`.
- **ES Modules**, vanilla — no new frameworks. Astro 5 only.
- **Swift Testing** (`@Test`/`#expect`), not XCTest, for new tests.
- **Conventional commits**, each ending with the trailer:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- All `.collection`-stored types only; page-stored types (`businessProfile`) are out of scope (#345).
- Run Swift tests with `swift test --package-path .` (set `DEVELOPER_DIR` to the Xcode-beta toolchain if the default `swift` is too old).

---

### Task 1: Registry — `imageArray` kind + Album + Like descriptors

**Files:**
- Modify: `Sources/AnglesiteCore/ContentTypeRegistry.swift`
- Test: `Tests/AnglesiteCoreTests/ContentTypeRegistryTests.swift`

**Interfaces:**
- Consumes: existing `ContentTypeField`, `ContentTypeDescriptor`, `ContentTypeProjections`, `ContentTypeRegistry`, `ContentStorage` from `ContentTypeRegistry.swift`.
- Produces: `ContentTypeField.Kind.imageArray`; `ContentTypeRegistry.album` and `.like` static descriptors; `personalTypes == [note, article, photo, album, bookmark, reply, like]`.

- [ ] **Step 1: Write the failing tests**

Add to `ContentTypeRegistryTests.swift` (inside the `ContentTypeRegistry` suite):

```swift
@Test("personalTypes include album and like in canonical order")
func personalTypeOrder() {
    #expect(ContentTypeRegistry.personalTypes.map(\.id)
        == ["note", "article", "photo", "album", "bookmark", "reply", "like"])
}

@Test("album is an h-entry image gallery with an imageArray field")
func albumDescriptor() {
    let album = try! #require(ContentTypeRegistry().descriptor(id: "album"))
    #expect(album.displayName == "Album")
    #expect(album.collection == "albums")
    #expect(album.projections.microformat == "h-entry")
    #expect(album.projections.schemaType == "ImageGallery")
    let images = try! #require(album.fields.first { $0.name == "images" })
    #expect(images.kind == .imageArray)
    #expect(images.required)
    #expect(album.projections.microformatProperties["images"] == "u-photo")
    #expect(album.projections.microformatProperties["title"] == "p-name")
    #expect(album.projections.microformatProperties["publishDate"] == "dt-published")
}

@Test("like is an h-entry with u-like-of and no schema.org type")
func likeDescriptor() {
    let like = try! #require(ContentTypeRegistry().descriptor(id: "like"))
    #expect(like.displayName == "Like")
    #expect(like.collection == "likes")
    #expect(like.projections.microformat == "h-entry")
    #expect(like.projections.schemaType == nil)
    let likeOf = try! #require(like.fields.first { $0.name == "likeOf" })
    #expect(likeOf.kind == .url)
    #expect(likeOf.required)
    #expect(like.projections.microformatProperties["likeOf"] == "u-like-of")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter ContentTypeRegistry`
Expected: FAIL — `imageArray` is not a member of `Kind`; `descriptor(id: "album"/"like")` returns nil.

- [ ] **Step 3: Add the `imageArray` kind**

In `ContentTypeRegistry.swift`, add to `ContentTypeField.Kind` (after `stringArray`):

```swift
        case stringArray   // e.g. tags
        case imageArray    // an ordered list of site-relative media paths (e.g. album photos)
```

- [ ] **Step 4: Add the two descriptors and extend `personalTypes`**

Change the `personalTypes` line:

```swift
    static let personalTypes: [ContentTypeDescriptor] = [note, article, photo, album, bookmark, reply, like]
```

Add these two descriptors in the `// MARK: Personal (h-entry family)` section (after `photo`, before `bookmark` is fine — declaration order doesn't affect `personalTypes` order):

```swift
    static let album = ContentTypeDescriptor(
        id: "album",
        displayName: "Album",
        storage: .collection("albums"),
        fields: [
            ContentTypeField("title", .string, required: true),
            ContentTypeField("images", .imageArray, required: true),
            ContentTypeField("body", .markdown),
            ContentTypeField("publishDate", .datetime, required: true),
            ContentTypeField("tags", .stringArray),
        ],
        projections: ContentTypeProjections(
            microformat: "h-entry",
            microformatProperties: [
                "title": "p-name",
                "images": "u-photo",
                "body": "e-content",
                "publishDate": "dt-published",
                "tags": "p-category",
            ],
            schemaType: "ImageGallery"
        )
    )

    static let like = ContentTypeDescriptor(
        id: "like",
        displayName: "Like",
        storage: .collection("likes"),
        fields: [
            ContentTypeField("likeOf", .url, required: true),
            ContentTypeField("publishDate", .datetime, required: true),
        ],
        projections: ContentTypeProjections(
            microformat: "h-entry",
            microformatProperties: [
                "likeOf": "u-like-of",
                "publishDate": "dt-published",
            ],
            schemaType: nil
        )
    )
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --package-path . --filter ContentTypeRegistry`
Expected: PASS (new + existing registry tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/ContentTypeRegistry.swift Tests/AnglesiteCoreTests/ContentTypeRegistryTests.swift
git commit -m "feat(#344): registry — add Album, Like, and imageArray kind

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `ContentScaffold.renderEntry`

**Files:**
- Modify: `Sources/AnglesiteCore/ContentScaffold.swift`
- Test: `Tests/AnglesiteCoreTests/ContentScaffoldTests.swift`

**Interfaces:**
- Consumes: `ContentTypeDescriptor`, `ContentTypeField.Kind` from Task 1; existing `ContentScaffold.escapeYAML`.
- Produces: `static func renderEntry(descriptor: ContentTypeDescriptor, title: String?, now: Date) -> String`.

**Behavior contract** (drives the test): emits a `---` frontmatter block with one line per field in declaration order, except `markdown` fields, which become a placeholder body **below** the closing `---`. Per-kind defaults: `datetime` → ISO8601 (internet date-time + fractional seconds); `date` → first 10 chars of that ISO string; `bool` → `false`; `number` → `0`; `stringArray`/`imageArray` → `[]`; `string`/`text`/`url`/`image` → `"..."` (a `title` or `name` field gets `title` when supplied, else empty). Output ends with a trailing newline.

- [ ] **Step 1: Write the failing tests**

Add to `ContentScaffoldTests.swift` (inside the `ContentScaffold` suite):

```swift
@Test("renderEntry emits frontmatter for a note with body below the block")
func renderEntryNote() {
    let note = try! #require(ContentTypeRegistry().descriptor(id: "note"))
    let out = ContentScaffold.renderEntry(
        descriptor: note, title: nil, now: Date(timeIntervalSince1970: 1_750_000_000))
    #expect(out == """
    ---
    publishDate: 2025-06-15T15:06:40.000Z
    tags: []
    ---

    Write your note here.

    """)
}

@Test("renderEntry fills the title field and uses imageArray/url defaults")
func renderEntryAlbumAndLike() {
    let registry = ContentTypeRegistry()
    let album = try! #require(registry.descriptor(id: "album"))
    let albumOut = ContentScaffold.renderEntry(
        descriptor: album, title: "Trip", now: Date(timeIntervalSince1970: 1_750_000_000))
    #expect(albumOut.contains("title: \"Trip\""))
    #expect(albumOut.contains("images: []"))
    #expect(albumOut.contains("publishDate: 2025-06-15T15:06:40.000Z"))
    #expect(albumOut.contains("Write your album here."))

    let like = try! #require(registry.descriptor(id: "like"))
    let likeOut = ContentScaffold.renderEntry(
        descriptor: like, title: nil, now: Date(timeIntervalSince1970: 1_750_000_000))
    #expect(likeOut.contains("likeOf: \"\""))
    #expect(likeOut.contains("publishDate: 2025-06-15T15:06:40.000Z"))
    // No markdown field on a like → no body placeholder.
    #expect(!likeOut.contains("Write your"))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter ContentScaffold`
Expected: FAIL — `renderEntry` is not a member of `ContentScaffold`.

- [ ] **Step 3: Implement `renderEntry`**

Add to `ContentScaffold` (after `renderPost`):

```swift
    /// Render a new content entry's file contents from its descriptor: a YAML frontmatter block
    /// (one line per non-markdown field, in declaration order) followed by a placeholder body for
    /// the type's `markdown` field, if any. Pure; mirrors `renderPost`'s ISO8601 date format.
    public static func renderEntry(descriptor: ContentTypeDescriptor, title: String?, now: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dateTime = formatter.string(from: now)

        var lines: [String] = ["---"]
        var bodyPlaceholder: String?
        for field in descriptor.fields {
            switch field.kind {
            case .markdown:
                bodyPlaceholder = "Write your \(descriptor.displayName.lowercased()) here."
            case .datetime:
                lines.append("\(field.name): \(dateTime)")
            case .date:
                lines.append("\(field.name): \(String(dateTime.prefix(10)))")
            case .bool:
                lines.append("\(field.name): false")
            case .number:
                lines.append("\(field.name): 0")
            case .stringArray, .imageArray:
                lines.append("\(field.name): []")
            case .string, .text, .url, .image:
                let value = (field.name == "title" || field.name == "name") ? (title ?? "") : ""
                lines.append("\(field.name): \"\(escapeYAML(value))\"")
            }
        }
        lines.append("---")

        var output = lines.joined(separator: "\n") + "\n"
        if let bodyPlaceholder {
            output += "\n\(bodyPlaceholder)\n"
        }
        return output
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter ContentScaffold`
Expected: PASS.

> If the `renderEntryNote` exact-match fails on the date string, print the actual `out` once and align the literal — the formatter output is deterministic for a fixed `now`, so update the expected string to match (do not loosen the assertion to `contains`).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/ContentScaffold.swift Tests/AnglesiteCoreTests/ContentScaffoldTests.swift
git commit -m "feat(#344): descriptor-driven ContentScaffold.renderEntry

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `NativeContentOperations.createTyped`

**Files:**
- Modify: `Sources/AnglesiteCore/NativeContentOperations.swift`
- Test: `Tests/AnglesiteCoreTests/NativeContentOperationsTests.swift`

**Interfaces:**
- Consumes: `ContentScaffold.renderEntry` (Task 2); `ContentTypeRegistry` + descriptors (Task 1); existing `write(_:to:)`, `now`, `gitCommit`, `siteDirectory`, `ContentCreateResult`, `ContentScaffold.postRelativePath`, `ContentScaffold.slugify`.
- Produces: `func createTyped(siteID: String, typeID: String, title: String, registry: ContentTypeRegistry = ContentTypeRegistry(), onProgress: ProgressHandler? = nil) async -> ContentCreateResult`.

- [ ] **Step 1: Write the failing tests**

Add to `NativeContentOperationsTests.swift` (inside the suite; reuse the existing `makeOps()` helper):

```swift
@Test("createTyped writes a like to its collection and commits")
func createTypedLike() async throws {
    let (ops, root, spy) = makeOps()
    let result = await ops.createTyped(siteID: "s1", typeID: "like", title: "Cool post")
    #expect(result == .created(filePath: "src/content/likes/cool-post.md", identifier: "cool-post"))
    let written = try String(
        contentsOf: root.appendingPathComponent("src/content/likes/cool-post.md"), encoding: .utf8)
    #expect(written.contains("likeOf: \"\""))
    #expect(written.contains("publishDate:"))
    let calls = await spy.calls
    #expect(calls.count == 1)
    #expect(calls.first?.1 == "src/content/likes/cool-post.md")
    #expect(calls.first?.2 == "anglesite: add likes cool-post")
}

@Test("createTyped rejects an unknown type")
func createTypedUnknown() async {
    let (ops, _, _) = makeOps()
    let result = await ops.createTyped(siteID: "s1", typeID: "nope", title: "x")
    #expect(result == .failed(reason: "Unknown content type: nope"))
}

@Test("createTyped refuses page-stored types")
func createTypedPageStored() async {
    let (ops, _, _) = makeOps()
    let result = await ops.createTyped(siteID: "s1", typeID: "businessProfile", title: "x")
    #expect(result == .failed(reason: "Page-stored type businessProfile is not supported by createTyped yet"))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter NativeContentOperations`
Expected: FAIL — `createTyped` is not a member.

- [ ] **Step 3: Implement `createTyped`**

Add to `NativeContentOperations` (after `createPost`):

```swift
    /// Create a typed content entry (V-1.2). Looks the type up in `registry`, derives a slug from
    /// `title`, renders frontmatter via `ContentScaffold.renderEntry`, writes it, and commits —
    /// the same write/commit path as `createPost`. Collection-stored types only; page-stored types
    /// (e.g. `businessProfile`) are #345.
    public func createTyped(
        siteID: String,
        typeID: String,
        title: String,
        registry: ContentTypeRegistry = ContentTypeRegistry(),
        onProgress: ProgressHandler? = nil
    ) async -> ContentCreateResult {
        onProgress?(.createResolvingRuntime)
        guard let root = await siteDirectory(siteID) else { return .siteNotFound }
        guard let descriptor = registry.descriptor(id: typeID) else {
            return .failed(reason: "Unknown content type: \(typeID)")
        }
        guard let collection = descriptor.collection else {
            return .failed(reason: "Page-stored type \(typeID) is not supported by createTyped yet")
        }

        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalSlug = ContentScaffold.slugify(cleanTitle.isEmpty ? descriptor.id : cleanTitle)
        guard !finalSlug.isEmpty else { return .failed(reason: "createTyped could not derive a slug") }

        let relPath = ContentScaffold.postRelativePath(collection: collection, slug: finalSlug)
        let abs = root.appendingPathComponent(relPath)
        if fileManager.fileExists(atPath: abs.path) {
            return .failed(reason: "A \(collection) entry already exists at \(relPath)")
        }

        onProgress?(.createCallingPlugin)
        let contents = ContentScaffold.renderEntry(
            descriptor: descriptor, title: cleanTitle.isEmpty ? nil : cleanTitle, now: now())
        do { try write(contents, to: abs) }
        catch { return .failed(reason: "\(error)") }

        onProgress?(.createFinalizing)
        _ = await gitCommit(root, relPath, "anglesite: add \(collection) \(finalSlug)")
        return .created(filePath: relPath, identifier: finalSlug)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter NativeContentOperations`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/NativeContentOperations.swift Tests/AnglesiteCoreTests/NativeContentOperationsTests.swift
git commit -m "feat(#344): NativeContentOperations.createTyped for collection types

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Astro template — collections, shared layout, routes, seed content

**Files:**
- Modify: `Resources/Template/src/content.config.ts`
- Create: `Resources/Template/src/layouts/Hentry.astro`
- Create: `Resources/Template/src/pages/[collection]/[...slug].astro` (1 dynamic route covering all collections)
- Create: `Resources/Template/src/content/{notes,articles,photos,albums,bookmarks,replies,likes}/hello-*.md` (7 seed files)

**Interfaces:**
- Consumes: existing `BaseLayout.astro` (`title`, `description?` props); Astro 5 `astro:content` (`defineCollection`, `glob`, `getCollection`, `render`).
- Produces: collections `notes, articles, photos, albums, bookmarks, replies, likes` (added to the `collections` export alongside `blog`); rendered pages at `/<collection>/<slug>/` carrying mf2 classes. No code consumes these from Swift — Task 5 asserts the build output.

> This task has no Swift unit test; its verification is the Task 5 build smoke. Build the template locally to confirm before committing. Prerequisite (one-time, local): `cd Resources/Template && npm install`.

- [ ] **Step 1: Add the collections**

Replace the `export const collections` line in `content.config.ts` and add the new collections above it (keep the existing `blog` definition and imports untouched). Schemas use registry field names and stay loose (full Zod is #347):

```ts
const notes = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/notes" }),
  schema: z.object({
    publishDate: z.coerce.date(),
    tags: z.array(z.string()).optional(),
  }),
});

const articles = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/articles" }),
  schema: z.object({
    title: z.string(),
    summary: z.string().optional(),
    publishDate: z.coerce.date(),
    updated: z.coerce.date().optional(),
    tags: z.array(z.string()).optional(),
  }),
});

const photos = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/photos" }),
  schema: z.object({
    image: z.string(),
    caption: z.string().optional(),
    publishDate: z.coerce.date(),
    tags: z.array(z.string()).optional(),
  }),
});

const albums = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/albums" }),
  schema: z.object({
    title: z.string(),
    images: z.array(z.string()),
    publishDate: z.coerce.date(),
    tags: z.array(z.string()).optional(),
  }),
});

const bookmarks = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/bookmarks" }),
  schema: z.object({
    bookmarkOf: z.string().url(),
    title: z.string().optional(),
    publishDate: z.coerce.date(),
    tags: z.array(z.string()).optional(),
  }),
});

const replies = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/replies" }),
  schema: z.object({
    inReplyTo: z.string().url(),
    publishDate: z.coerce.date(),
  }),
});

const likes = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/likes" }),
  schema: z.object({
    likeOf: z.string().url(),
    publishDate: z.coerce.date(),
  }),
});

export const collections = { blog, notes, articles, photos, albums, bookmarks, replies, likes };
```

- [ ] **Step 2: Create the shared `h-entry` layout**

`Resources/Template/src/layouts/Hentry.astro`:

```astro
---
import BaseLayout from "./BaseLayout.astro";

interface Props {
  entry: { data: Record<string, any> };
}

const { entry } = Astro.props;
const d = entry.data;
const title = d.title ?? d.name;
const iso = d.publishDate ? new Date(d.publishDate).toISOString() : undefined;
const human = d.publishDate ? new Date(d.publishDate).toLocaleDateString() : undefined;
const images: string[] = Array.isArray(d.images) ? d.images : [];
const tags: string[] = Array.isArray(d.tags) ? d.tags : [];
---

<BaseLayout title={title ?? "Post"} description={d.summary}>
  <article class="h-entry">
    {title && <h1 class="p-name">{title}</h1>}
    {d.image && <img class="u-photo" src={d.image} alt={d.caption ?? ""} />}
    {images.map((src) => <img class="u-photo" src={src} alt="" />)}
    {d.bookmarkOf && <a class="u-bookmark-of" href={d.bookmarkOf}>{d.bookmarkOf}</a>}
    {d.inReplyTo && <a class="u-in-reply-to" href={d.inReplyTo}>In reply to</a>}
    {d.likeOf && <a class="u-like-of" href={d.likeOf}>Liked this</a>}
    {d.caption && <p class="p-summary">{d.caption}</p>}
    <div class="e-content"><slot /></div>
    {iso && <time class="dt-published" datetime={iso}>{human}</time>}
    {tags.length > 0 && (
      <ul class="tags">
        {tags.map((t) => <li><a class="p-category" href={`/tags/${t}`}>{t}</a></li>)}
      </ul>
    )}
  </article>
</BaseLayout>
```

- [ ] **Step 3: Create one dynamic entry route for all collections**

A single route renders every personal-type collection at `/<collection>/<slug>/`. `Resources/Template/src/pages/[collection]/[...slug].astro`:

```astro
---
import { getCollection, render } from "astro:content";
import Hentry from "../../layouts/Hentry.astro";

const collections = ["notes", "articles", "photos", "albums", "bookmarks", "replies", "likes"];

export async function getStaticPaths() {
  const paths = [];
  for (const collection of collections) {
    const entries = await getCollection(collection);
    for (const entry of entries) {
      paths.push({ params: { collection, slug: entry.id }, props: { entry } });
    }
  }
  return paths;
}

const { entry } = Astro.props;
const { Content } = await render(entry);
---

<Hentry entry={entry}><Content /></Hentry>
```

This keeps the URL structure (`/notes/hello-note/`, `/likes/hello-like/`, …) the Task 5 smoke test asserts, with one file instead of seven. The `collections` array must list exactly the seven personal collections (not `blog`, which keeps its own `src/pages/blog/[...slug].astro`).

- [ ] **Step 4: Create one seed entry per collection**

`src/content/notes/hello-note.md`:
```md
---
publishDate: 2026-06-26T12:00:00.000Z
tags: ["hello"]
---
This is your first note.
```

`src/content/articles/hello-article.md`:
```md
---
title: "Hello, Article"
summary: "An example article."
publishDate: 2026-06-26T12:00:00.000Z
tags: ["hello"]
---
This is your first article.
```

`src/content/photos/hello-photo.md`:
```md
---
image: "/images/hello.jpg"
caption: "An example photo."
publishDate: 2026-06-26T12:00:00.000Z
tags: ["hello"]
---
```

`src/content/albums/hello-album.md`:
```md
---
title: "Hello, Album"
images: ["/images/one.jpg", "/images/two.jpg"]
publishDate: 2026-06-26T12:00:00.000Z
tags: ["hello"]
---
An example album.
```

`src/content/bookmarks/hello-bookmark.md`:
```md
---
bookmarkOf: "https://example.com/"
title: "Example"
publishDate: 2026-06-26T12:00:00.000Z
tags: ["hello"]
---
Why this is worth bookmarking.
```

`src/content/replies/hello-reply.md`:
```md
---
inReplyTo: "https://example.com/post"
publishDate: 2026-06-26T12:00:00.000Z
---
A thoughtful reply.
```

`src/content/likes/hello-like.md`:
```md
---
likeOf: "https://example.com/liked-post"
publishDate: 2026-06-26T12:00:00.000Z
---
```

- [ ] **Step 5: Build the template to verify it compiles and renders mf2**

Run (image `src` values are plain attribute strings, so the referenced files need not exist for the build):
```bash
cd Resources/Template && node node_modules/astro/astro.js build
```
Expected: build succeeds; `dist/` contains `notes/hello-note/index.html`, `likes/hello-like/index.html`, etc. Spot-check:
```bash
grep -l 'class="h-entry"' dist/notes/hello-note/index.html
grep -o 'u-like-of' dist/likes/hello-like/index.html
grep -o 'u-photo' dist/albums/hello-album/index.html
```
Expected: each prints the class. Then clean: `rm -rf dist && cd ../..`

- [ ] **Step 6: Commit**

```bash
git add Resources/Template/src/content.config.ts \
        Resources/Template/src/layouts/Hentry.astro \
        Resources/Template/src/pages \
        Resources/Template/src/content
git commit -m "feat(#344): personal-type collections, h-entry layout, routes, seeds

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: mf2 render smoke test (node-gated)

**Files:**
- Create: `Tests/AnglesiteCoreTests/PersonalTypeRenderSmokeTests.swift`

**Interfaces:**
- Consumes: `E2EPrerequisites.locateNode()` (`Tests/AnglesiteTestSupport/E2EPrerequisites.swift`); the template at `Resources/Template/`; `ProcessSupervisor.shared.run(executable:arguments:currentDirectoryURL:)` (see `NativeContentOperations.processGitCommit` for the call shape).
- Produces: a single gated `@Test` that builds the template and asserts mf2 classes per type. No production code.

**Gating:** the test is `.enabled(if:)` on the template being buildable — node located **and** `Resources/Template/node_modules/astro/astro.js` present — so it *skips* (never fails) when deps aren't installed, matching the e2e-skip pattern.

- [ ] **Step 1: Write the gated smoke test**

`Tests/AnglesiteCoreTests/PersonalTypeRenderSmokeTests.swift`:

```swift
import Testing
import Foundation
import AnglesiteTestSupport
@testable import AnglesiteCore

@Suite("Personal type render smoke")
struct PersonalTypeRenderSmokeTests {

    /// Repo-root-relative path to the committed template. `swift test` runs with CWD = package root.
    static var templateDir: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Resources/Template", isDirectory: true)
    }

    /// True when the template can actually be built: a Node binary plus an installed Astro.
    static var buildable: Bool {
        guard E2EPrerequisites.locateNode() != nil else { return false }
        return FileManager.default.isReadableFile(
            atPath: templateDir.appendingPathComponent("node_modules/astro/astro.js").path)
    }

    @Test("seeded personal types build and render their mf2 classes",
          .enabled(if: PersonalTypeRenderSmokeTests.buildable))
    func rendersMicroformats() async throws {
        let node = try #require(E2EPrerequisites.locateNode())
        let dist = Self.templateDir.appendingPathComponent("dist", isDirectory: true)
        try? FileManager.default.removeItem(at: dist)
        defer { try? FileManager.default.removeItem(at: dist) }

        let result = try await ProcessSupervisor.shared.run(
            executable: node,
            arguments: ["node_modules/astro/astro.js", "build"],
            currentDirectoryURL: Self.templateDir)
        #expect(result.exitCode == 0, "astro build failed: \(result.stdout)\n\(result.stderr)")

        func html(_ rel: String) throws -> String {
            try String(contentsOf: dist.appendingPathComponent(rel), encoding: .utf8)
        }
        #expect(try html("notes/hello-note/index.html").contains("h-entry"))
        #expect(try html("notes/hello-note/index.html").contains("dt-published"))
        #expect(try html("articles/hello-article/index.html").contains("p-name"))
        #expect(try html("photos/hello-photo/index.html").contains("u-photo"))
        #expect(try html("albums/hello-album/index.html").contains("u-photo"))
        #expect(try html("bookmarks/hello-bookmark/index.html").contains("u-bookmark-of"))
        #expect(try html("replies/hello-reply/index.html").contains("u-in-reply-to"))
        #expect(try html("likes/hello-like/index.html").contains("u-like-of"))
    }
}
```

- [ ] **Step 2: Run the test**

Prerequisite (local): `cd Resources/Template && npm install && cd ../..`
Run: `swift test --package-path . --filter PersonalTypeRenderSmokeTests`
Expected: PASS where the template deps are installed; SKIPPED (not failed) where they aren't.

> If `ProcessSupervisor.RunResult` field names differ from `.exitCode`/`.stdout`/`.stderr`, match them to `processGitCommit`'s usage in `NativeContentOperations.swift` (it reads `result.exitCode` and `head.stdout`).

- [ ] **Step 3: Commit**

```bash
git add Tests/AnglesiteCoreTests/PersonalTypeRenderSmokeTests.swift
git commit -m "test(#344): node-gated mf2 render smoke for personal types

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Full-suite verification + follow-up issue

**Files:** none (verification + issue filing).

- [ ] **Step 1: Run the full AnglesiteCore suite**

Run: `swift test --package-path . --filter AnglesiteCoreTests`
Expected: PASS (the registry/scaffold/native tests green; the render smoke passes or skips). No regressions in existing suites.

- [ ] **Step 2: Confirm the template still passes pre-deploy-check**

Run: `cd Resources/Template && npm run check && cd ../..`
Expected: pre-deploy-check passes with the new collections/routes/seed content.

- [ ] **Step 3: File the plugin-parity follow-up issue**

```bash
gh issue create \
  --title "Mirror typed-content scaffolding in plugin create-content.mjs (V-1.2 follow-up)" \
  --body "V-1.2 (#344) added native descriptor-driven scaffolding (\`ContentScaffold.renderEntry\` / \`NativeContentOperations.createTyped\`) for the personal types, app-only. The Node sidecar \`create-content.mjs\` still only knows page/post. If the MCP create backend (\`ContentOperations\`) needs typed parity, mirror \`renderEntry\` there byte-for-byte (paired plugin PR + tagged release + bundled-plugin bump). Until then the MCP path can't create typed entries; the native path is the one wired into App Intents."
```

- [ ] **Step 4: Push the branch**

```bash
git push -u origin feat/344-personal-content-types
```

---

## Self-Review

**Spec coverage:**
- imageArray kind + Album/Like descriptors → Task 1 ✓
- Descriptor-driven native scaffolding (`renderEntry`) → Task 2 ✓
- Typed create seam (`createTyped`, collection-only, page deferred) → Task 3 ✓
- Minimal Astro collections (registry-named, loose) → Task 4 Step 1 ✓
- Shared `h-entry` layout with per-type mf2 (u-photo/u-bookmark-of/u-in-reply-to/u-like-of, p-name/e-content/dt-published/p-category) → Task 4 Step 2 ✓
- Per-collection entry routes → Task 4 Step 3 ✓
- Template-seeded sample content → Task 4 Step 4 ✓
- Registry/scaffold/native unit tests → Tasks 1–3 ✓
- Node-gated mf2 build smoke, skips when deps absent → Task 5 ✓
- Acceptance: scaffolds + builds green + mf2 + blog still builds → Tasks 4 Step 5, 5, 6 ✓
- Plugin-parity follow-up filed → Task 6 Step 3 ✓
- Out-of-scope items (full Zod #347, mf2 audit/h-card #349, feeds #348, editors #346, intents #351, business #345) → untouched ✓

**Placeholder scan:** No TBD/TODO; every code step shows full code; commands have expected output.

**Type consistency:** `renderEntry(descriptor:title:now:)` defined in Task 2, consumed identically in Task 3. `createTyped(siteID:typeID:title:registry:onProgress:)` defined and tested with matching signature. `ContentTypeField.Kind.imageArray` added in Task 1, used in Tasks 2/4. `ContentCreateResult` cases (`.created`, `.siteNotFound`, `.failed`) match the enum. Collection names consistent across registry descriptors, content.config.ts, routes, seed dirs, and smoke assertions.
