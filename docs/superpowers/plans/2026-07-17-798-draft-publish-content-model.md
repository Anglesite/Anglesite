# Draft → Publish Content Model Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the seven typed post-family content types (`notes`, `articles`, `photos`, `albums`, `bookmarks`, `replies`, `likes`) a `draft` field so new posts are drafts by default, with explicit desktop Publish/Unpublish verbs, matching what `blog` already has.

**Architecture:** One vocabulary end to end: a `draft: z.boolean().default(false)` frontmatter key, filtered out of list/detail routes and feeds at the template layer (dev preview still shows drafts with a badge; production builds never emit them), a `ContentTypeField("draft", .bool)` on each post-family `ContentTypeDescriptor` so the registry/scaffold/editor see it, and a `NativeContentOperations.publish`/`unpublish` pair that flips the flag, conditionally re-stamps `publishDate`, and commits — wired up through `ContentCreationWorkflow` → `SiteWindowModel` → the Navigator's Edit-menu and context-menu commands (matching the existing Delete/Duplicate pattern exactly).

**Tech Stack:** Swift 6.4 (AnglesiteCore, AnglesiteApp), Astro 5 + Zod (Resources/Template), Swift Testing, `node:test`.

## Global Constraints

- Issue: [#798](https://github.com/Anglesite/Anglesite-app/issues/798), spec: `docs/superpowers/specs/2026-07-17-blog-markdown-editor-publishing-design.md` Part B.
- **Scope is the seven registry-backed post-family types only** (`note`, `article`, `photo`, `album`, `bookmark`, `reply`, `like`). `blog` already has `draft` and its own scaffold path (`ContentScaffold.renderPost`/`createPost`) that predates the registry — it is **not** touched by this plan. Business types (`announcements`, `events`, `reviews`, `members`) are explicitly out of scope per the issue text ("can follow later").
- **Publish/Unpublish ships as Edit-menu + Navigator context-menu commands only, no toolbar button.** Every comparable existing per-selection verb (Delete, Duplicate, Rename, Repurpose) is menu + context-menu only; none has a toolbar button, and `docs/mac-assed-app-spec.md` has no toolbar-specific guidance for this class of action. Matching that precedent avoids inventing a new toolbar-customization pattern (`SiteToolbarItemIDTests` freezes item identity) for a single-item verb no sibling command uses.
- **"Never published before" is detected via git commit history**, not a new frontmatter field (owner decision during planning, see conversation log) — no persisted "everPublished" flag; `NativeContentOperations` gets a new injectable `GitHasCommit` closure mirroring the existing `GitCommit`/`GitDelete` seam.
- Dev-server preview shows drafts with a "Draft" badge; production builds filter them from every list route, detail route, and feed, per the issue's explicit checklist.
- Every step that changes committed template markup must be verified by running the affected `swift test` suite (template-coupled tests couple to `Resources/Template/` byte-for-byte in places, e.g. `ContentConfigDriftTests`).
- Follow `CONTRIBUTING.md`: conventional commits (`feat(scope): …`), reference `#798` in each subject.

---

### Task 1: Template — `draft` on the seven post-family collection schemas

**Files:**
- Modify: `Resources/Template/src/content.config.ts`
- Test: `Tests/AnglesiteCoreTests/ContentConfigDriftTests.swift` (byte-parity guard against the registry — updated in Task 3, but this task's edit must match what Task 3 will assert)

**Interfaces:**
- Produces: seven collections (`notes`, `articles`, `photos`, `albums`, `bookmarks`, `replies`, `likes`) each gain a trailing `draft: z.boolean().default(false),` schema line, mirroring `blog`'s existing one (`content.config.ts:26`).

- [ ] **Step 1: Edit `content.config.ts` — add `draft` to all seven collections**

Replace lines 30–100 of `Resources/Template/src/content.config.ts` (the `notes` through `likes` `defineCollection` blocks) with:

```ts
const notes = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/notes" }),
  schema: z.object({
    ...socialFields,
    publishDate: z.coerce.date(),
    tags: z.array(z.string()).optional(),
    draft: z.boolean().default(false),
  }).strict(),
});

const articles = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/articles" }),
  schema: z.object({
    ...socialFields,
    title: z.string(),
    summary: z.string().optional(),
    publishDate: z.coerce.date(),
    updated: z.coerce.date().optional(),
    tags: z.array(z.string()).optional(),
    draft: z.boolean().default(false),
  }).strict(),
});

const photos = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/photos" }),
  schema: z.object({
    ...socialFields,
    image: z.string(),
    caption: z.string().optional(),
    publishDate: z.coerce.date(),
    tags: z.array(z.string()).optional(),
    draft: z.boolean().default(false),
  }).strict(),
});

const albums = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/albums" }),
  schema: z.object({
    ...socialFields,
    title: z.string(),
    images: z.array(z.string()),
    publishDate: z.coerce.date(),
    tags: z.array(z.string()).optional(),
    draft: z.boolean().default(false),
  }).strict(),
});

const bookmarks = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/bookmarks" }),
  schema: z.object({
    ...socialFields,
    bookmarkOf: z.string().url(),
    title: z.string().optional(),
    publishDate: z.coerce.date(),
    tags: z.array(z.string()).optional(),
    draft: z.boolean().default(false),
  }).strict(),
});

const replies = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/replies" }),
  schema: z.object({
    ...socialFields,
    inReplyTo: z.string().url(),
    publishDate: z.coerce.date(),
    draft: z.boolean().default(false),
  }).strict(),
});

const likes = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/likes" }),
  schema: z.object({
    ...socialFields,
    likeOf: z.string().url(),
    publishDate: z.coerce.date(),
    draft: z.boolean().default(false),
  }).strict(),
});
```

`announcements`, `events`, `reviews`, `members` (lines 102–142) are unchanged.

- [ ] **Step 2: Commit**

```bash
git add Resources/Template/src/content.config.ts
git commit -m "feat(template): add draft field to post-family collection schemas (#798)"
```

(This commit will fail `ContentConfigDriftTests` and `PersonalTypeRenderSmokeTests` field-order expectations until Tasks 3/4 land — that's expected; Task 12 runs the full suite once every task is in.)

---

### Task 2: Drift-test parity — `.bool` fields always emit `.default(false)`

**Files:**
- Modify: `Tests/AnglesiteCoreTests/ContentConfigDriftTests.swift:28-45`

**Interfaces:**
- Consumes: `ContentTypeField.Kind.bool` (existing, `Sources/AnglesiteCore/ContentTypeRegistry.swift:25`).
- Produces: `ContentConfigDriftTests.canonicalBlock(_:)` now emits `z.boolean().default(false)` for any `.bool` field regardless of `required`, matching the literal text every `.bool` field gets in `content.config.ts` (Task 1's `draft` lines, and `blog`'s pre-existing one).

`draft`'s `required` flag doesn't matter for this schema shape: a field with a Zod default is never `.optional()` and never bare — it's always `.default(false)`. Rather than add a new concept to `ContentTypeField`, special-case `.bool` the same way the committed template already does for `blog`.

- [ ] **Step 1: Update `canonicalBlock` to special-case bool fields**

In `Tests/AnglesiteCoreTests/ContentConfigDriftTests.swift`, replace the `canonicalBlock` function body:

```swift
    /// The single canonical `defineCollection` block for a collection-backed descriptor.
    static func canonicalBlock(_ d: ContentTypeDescriptor) -> String? {
        guard let collection = d.collection else { return nil }
        var schemaLines: [String] = []
        for field in d.fields {
            guard let zod = zod(for: field.kind) else { continue }
            // Every `.bool` field ships with `.default(false)` (matching `blog`'s pre-existing
            // `draft` line) rather than `.optional()` — a defaulted field is never bare either way,
            // so `required` doesn't affect this branch.
            let expr = field.kind == .bool ? "\(zod).default(false)" : (field.required ? zod : "\(zod).optional()")
            schemaLines.append("    \(field.name): \(expr),")
        }
        return """
        const \(collection) = defineCollection({
          loader: glob({ pattern: "**/*.md", base: "./src/content/\(collection)" }),
          schema: z.object({
            ...socialFields,
        \(schemaLines.joined(separator: "\n"))
          }).strict(),
        });
        """
    }
```

- [ ] **Step 2: Run the drift suite to confirm it still fails for the expected reason (registry has no `draft` fields yet)**

Run: `swift test --package-path . --filter ContentConfigDriftTests`
Expected: FAIL — `configMatchesRegistry` reports every post-family collection's canonical block is missing from `content.config.ts` (it now expects a trailing `draft: z.boolean().default(false),` line the registry descriptors don't declare yet).

- [ ] **Step 3: Commit**

```bash
git add Tests/AnglesiteCoreTests/ContentConfigDriftTests.swift
git commit -m "test(core): drift guard emits .default(false) for bool fields (#798)"
```

---

### Task 3: Registry — `draft` field on the seven post-family descriptors

**Files:**
- Modify: `Sources/AnglesiteCore/ContentTypeRegistry.swift:204-356`
- Modify: `Tests/AnglesiteCoreTests/ContentTypeRegistryTests.swift`

**Interfaces:**
- Consumes: `ContentTypeField(_:_:required:)` (existing, `ContentTypeRegistry.swift:37`).
- Produces: `ContentTypeRegistry.note/.article/.photo/.album/.bookmark/.reply/.like` each have a trailing `ContentTypeField("draft", .bool)` in their `fields:` array. No change to `microformatProperties` or `schemaType` — a draft has no mf2/schema.org projection.

- [ ] **Step 1: Add the field to each descriptor**

In `Sources/AnglesiteCore/ContentTypeRegistry.swift`, add `ContentTypeField("draft", .bool),` as the last entry in each of these seven `fields:` arrays:

```swift
    static let note = ContentTypeDescriptor(
        id: "note",
        displayName: "Note",
        storage: .collection("notes"),
        fields: [
            ContentTypeField("body", .markdown, required: true),
            ContentTypeField("publishDate", .datetime, required: true),
            ContentTypeField("tags", .stringArray),
            ContentTypeField("draft", .bool),
        ],
        projections: ContentTypeProjections(
            microformat: "h-entry",
            microformatProperties: [
                "body": "e-content",
                "publishDate": "dt-published",
                "tags": "p-category",
            ],
            schemaType: "SocialMediaPosting"
        )
    )

    static let article = ContentTypeDescriptor(
        id: "article",
        displayName: "Article",
        storage: .collection("articles"),
        fields: [
            ContentTypeField("title", .string, required: true),
            ContentTypeField("summary", .text),
            ContentTypeField("body", .markdown, required: true),
            ContentTypeField("publishDate", .datetime, required: true),
            ContentTypeField("updated", .datetime),
            ContentTypeField("tags", .stringArray),
            ContentTypeField("draft", .bool),
        ],
        projections: ContentTypeProjections(
            microformat: "h-entry",
            microformatProperties: [
                "title": "p-name",
                "summary": "p-summary",
                "body": "e-content",
                "publishDate": "dt-published",
                "updated": "dt-updated",
                "tags": "p-category",
            ],
            schemaType: "Article"
        )
    )

    static let photo = ContentTypeDescriptor(
        id: "photo",
        displayName: "Photo",
        storage: .collection("photos"),
        fields: [
            ContentTypeField("image", .image, required: true),
            ContentTypeField("caption", .text),
            ContentTypeField("publishDate", .datetime, required: true),
            ContentTypeField("tags", .stringArray),
            ContentTypeField("draft", .bool),
        ],
        projections: ContentTypeProjections(
            microformat: "h-entry",
            microformatProperties: [
                "image": "u-photo",
                "caption": "p-summary",
                "publishDate": "dt-published",
                "tags": "p-category",
            ],
            schemaType: "Photograph"
        )
    )

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
            ContentTypeField("draft", .bool),
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

    static let bookmark = ContentTypeDescriptor(
        id: "bookmark",
        displayName: "Bookmark",
        storage: .collection("bookmarks"),
        fields: [
            ContentTypeField("bookmarkOf", .url, required: true),
            ContentTypeField("title", .string),
            ContentTypeField("body", .markdown),
            ContentTypeField("publishDate", .datetime, required: true),
            ContentTypeField("tags", .stringArray),
            ContentTypeField("draft", .bool),
        ],
        projections: ContentTypeProjections(
            microformat: "h-entry",
            microformatProperties: [
                "bookmarkOf": "u-bookmark-of",
                "title": "p-name",
                "body": "e-content",
                "publishDate": "dt-published",
                "tags": "p-category",
            ],
            schemaType: nil
        )
    )

    static let reply = ContentTypeDescriptor(
        id: "reply",
        displayName: "Reply",
        storage: .collection("replies"),
        fields: [
            ContentTypeField("inReplyTo", .url, required: true),
            ContentTypeField("body", .markdown, required: true),
            ContentTypeField("publishDate", .datetime, required: true),
            ContentTypeField("draft", .bool),
        ],
        projections: ContentTypeProjections(
            microformat: "h-entry",
            microformatProperties: [
                "inReplyTo": "u-in-reply-to",
                "body": "e-content",
                "publishDate": "dt-published",
            ],
            schemaType: "Comment"
        )
    )

    static let like = ContentTypeDescriptor(
        id: "like",
        displayName: "Like",
        storage: .collection("likes"),
        fields: [
            ContentTypeField("likeOf", .url, required: true),
            ContentTypeField("publishDate", .datetime, required: true),
            ContentTypeField("draft", .bool),
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

- [ ] **Step 2: Write the failing registry test**

Add to `Tests/AnglesiteCoreTests/ContentTypeRegistryTests.swift`:

```swift
    @Test("every post-family descriptor has a trailing draft field")
    func postFamilyHasDraft() {
        let registry = ContentTypeRegistry()
        for id in ["note", "article", "photo", "album", "bookmark", "reply", "like"] {
            let descriptor = try! #require(registry.descriptor(id: id))
            #expect(descriptor.fields.last?.name == "draft", "\(id): draft should be the last field")
            #expect(descriptor.fields.last?.kind == .bool, "\(id): draft should be .bool")
            #expect(descriptor.projections.microformatProperties["draft"] == nil,
                    "\(id): draft has no mf2 projection")
        }
    }
```

- [ ] **Step 3: Run to verify it passes and the drift guard now agrees**

Run: `swift test --package-path . --filter ContentTypeRegistryTests`
Expected: PASS

Run: `swift test --package-path . --filter ContentConfigDriftTests`
Expected: PASS (Task 1's template edit and this task's registry edit now match byte-for-byte through Task 2's updated `canonicalBlock`)

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteCore/ContentTypeRegistry.swift Tests/AnglesiteCoreTests/ContentTypeRegistryTests.swift
git commit -m "feat(core): register draft field on post-family content types (#798)"
```

---

### Task 4: `ContentScaffold.renderEntry` — new posts are drafts by default

**Files:**
- Modify: `Sources/AnglesiteCore/ContentScaffold.swift:159-160`
- Modify: `Tests/AnglesiteCoreTests/ContentScaffoldTests.swift:86-101`

**Interfaces:**
- Produces: `ContentScaffold.renderEntry` writes `draft: true` (not `false`) specifically for the field named `"draft"`; every other `.bool` field (none exist yet) keeps rendering `false`.

- [ ] **Step 1: Update the failing test first**

In `Tests/AnglesiteCoreTests/ContentScaffoldTests.swift`, replace the `renderEntryNote` test:

```swift
    @Test("renderEntry emits frontmatter for a note with body below the block, as a draft")
    func renderEntryNote() {
        let note = try! #require(ContentTypeRegistry().descriptor(id: "note"))
        let out = ContentScaffold.renderEntry(
            descriptor: note, title: nil, now: Date(timeIntervalSince1970: 1_750_000_000))
        #expect(out == """
        ---
        publishDate: 2025-06-15T15:06:40.000Z
        tags: []
        draft: true
        ---

        Write your note here.

        """)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path . --filter ContentScaffoldTests/renderEntryNote`
Expected: FAIL — actual output ends `draft: false` (current unconditional `.bool` branch).

- [ ] **Step 3: Make `.bool` field rendering draft-aware**

In `Sources/AnglesiteCore/ContentScaffold.swift`, in `renderEntry`, replace:

```swift
            case .bool:
                lines.append("\(field.name): false")
```

with:

```swift
            // New entries are drafts by default (#798) — every other .bool field (none exist
            // yet) keeps its false default.
            case .bool:
                lines.append("\(field.name): \(field.name == "draft" ? "true" : "false")")
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path . --filter ContentScaffoldTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/ContentScaffold.swift Tests/AnglesiteCoreTests/ContentScaffoldTests.swift
git commit -m "feat(core): scaffold new post-family entries as drafts (#798)"
```

---

### Task 5: Template — filter drafts from pages/feeds, show a "Draft" badge in dev

**Files:**
- Modify: `Resources/Template/src/pages/blog/index.astro`
- Modify: `Resources/Template/src/pages/blog/[...slug].astro`
- Modify: `Resources/Template/src/layouts/BlogPost.astro`
- Modify: `Resources/Template/src/pages/[collection]/[...slug].astro`
- Modify: `Resources/Template/src/layouts/Hentry.astro`
- Modify: `Resources/Template/src/lib/feed-data.ts`
- Create: `Resources/Template/src/components/DraftBadge.astro`

**Interfaces:**
- Produces: `DraftBadge.astro` — a `{ draft?: boolean }` prop component that renders a visible "Draft" marker only when `import.meta.env.DEV && draft`, nothing otherwise (including in every production build).

Two different filtering rules, both already implied by the issue text and verified against current behavior rather than assumed:
- **Pages** (list + detail): drafts are visible in `astro dev`, hidden from `astro build` output — `import.meta.env.PROD ? !draft : true`.
- **Feeds** (RSS/Atom/JSON): always filtered, unconditionally — a feed is syndication data, not a live preview, and the issue's "exactly as `/blog/` already does" language matches `/blog/`'s pre-existing *unconditional* feed omission (feeds never filtered drafts in *or* out of dev before this change, and the fix below makes that filtering happen every time, dev or prod).

- [ ] **Step 1: Create the `DraftBadge` component**

```astro
---
// src/components/DraftBadge.astro — dev-only marker for an unpublished entry (#798). Renders
// nothing in a production build: draft entries never reach `astro build` output at all (their
// routes are filtered out before this component would ever be reached), so the `import.meta.env.DEV`
// check here is a belt-and-suspenders guard, not the only thing keeping drafts out of `dist/`.
interface Props {
  draft?: boolean;
}
const { draft } = Astro.props;
---

{import.meta.env.DEV && draft && (
  <p class="draft-badge" role="status">Draft — not included in the published build</p>
)}

<style>
  .draft-badge {
    display: inline-block;
    margin: 0 0 1rem;
    padding: 0.25rem 0.6rem;
    border-radius: 0.3rem;
    background: #fff3cd;
    color: #664d03;
    font-size: 0.85rem;
    font-weight: 600;
  }
</style>
```

- [ ] **Step 2: `blog/index.astro` — dev-aware filter + badge**

Replace `Resources/Template/src/pages/blog/index.astro`:

```astro
---
import { getCollection } from "astro:content";
import BaseLayout from "../../layouts/BaseLayout.astro";
import DraftBadge from "../../components/DraftBadge.astro";

const posts = (
  await getCollection("blog", ({ data }) => (import.meta.env.PROD ? !data.draft : true))
).sort((a, b) => b.data.pubDate.valueOf() - a.data.pubDate.valueOf());
---

<BaseLayout title="Blog" description="Read the latest posts and updates.">
  <main>
    <h1>Blog</h1>
    <p><a href="/blog/rss.xml">Subscribe (RSS)</a></p>
    {
      posts.length === 0 ? (
        <p>No posts yet. Add a Markdown file in <code>src/content/blog/</code> to get started.</p>
      ) : (
        <ul>
          {posts.map((post) => (
            <li>
              <DraftBadge draft={post.data.draft} />
              <a href={`/blog/${post.id}/`}>{post.data.title}</a>
              <time datetime={post.data.pubDate.toISOString()}>
                {post.data.pubDate.toLocaleDateString("en-US", { year: "numeric", month: "long", day: "numeric", timeZone: "UTC" })}
              </time>
              {post.data.description && <p>{post.data.description}</p>}
            </li>
          ))}
        </ul>
      )
    }
  </main>
</BaseLayout>
```

- [ ] **Step 3: `blog/[...slug].astro` — dev-aware filter, pass `draft` through**

Replace `Resources/Template/src/pages/blog/[...slug].astro`:

```astro
---
import { getCollection, render } from "astro:content";
import BlogPost from "../../layouts/BlogPost.astro";

export async function getStaticPaths() {
  const posts = await getCollection("blog", ({ data }) => (import.meta.env.PROD ? !data.draft : true));
  return posts.map((post) => ({ params: { slug: post.id }, props: { post } }));
}

const { post } = Astro.props;
const { Content } = await render(post);
---

<BlogPost
  title={post.data.title}
  description={post.data.description}
  pubDate={post.data.pubDate}
  draft={post.data.draft}
  syndication={post.data.syndication}
>
  <Content />
</BlogPost>
```

- [ ] **Step 4: `BlogPost.astro` — accept and render `draft`**

In `Resources/Template/src/layouts/BlogPost.astro`, add the import and prop, and render the badge. Replace the top of the file through the `<article>` open tag:

```astro
---
// BlogPost.astro — layout for an individual blog post. The post route
// src/pages/blog/[...slug].astro renders through this layout; the Markdown body
// fills the <slot/>, the share anchor is where the share integration injects its
// buttons, and the comments anchor is where the giscus integration injects its
// widget when comments are set up.
import { Schema } from "astro-seo-schema";
import { blogPostingSchema } from "../lib/schema.ts";
import { ownerName } from "../lib/profile.ts";
import BaseLayout from "./BaseLayout.astro";
import SyndicationLinks from "../components/SyndicationLinks.astro";
import DraftBadge from "../components/DraftBadge.astro";

interface Props {
  title: string;
  description?: string;
  pubDate?: Date;
  draft?: boolean;
  syndication?: string[];
}

const { title, description, pubDate, draft, syndication } = Astro.props;
// pubDate is already a Date; pin the locale + UTC so static output is deterministic.
const iso = pubDate ? pubDate.toISOString() : undefined;
const human = pubDate
  ? pubDate.toLocaleDateString("en-US", { year: "numeric", month: "long", day: "numeric", timeZone: "UTC" })
  : undefined;
const canonical = new URL(Astro.url.pathname, Astro.site ?? Astro.url).href;
const jsonLd = blogPostingSchema(
  { title, description, pubDate },
  { url: canonical, site: Astro.site, authorName: ownerName() },
);
// anglesite:imports — integration component imports are injected here on setup
---

<BaseLayout title={title} description={description}>
  <Schema slot="head" item={jsonLd} />
  <p><a href="/blog/">← All posts</a></p>
  <article class="h-entry">
    <DraftBadge draft={draft} />
    <h1 class="p-name">{title}</h1>
```

(The rest of the file — `description`, permalink, `e-content`, syndication links, `anglesite:share`/`anglesite:comments` anchors, closing tags — is unchanged.)

- [ ] **Step 5: Shared post-family detail route — filter + badge**

Replace `Resources/Template/src/pages/[collection]/[...slug].astro`:

```astro
---
import { getCollection, render } from "astro:content";
import Hentry from "../../layouts/Hentry.astro";
import Hevent from "../../layouts/Hevent.astro";
import Hreview from "../../layouts/Hreview.astro";
import { ENTRY_COLLECTIONS } from "../../lib/collections.ts";

export async function getStaticPaths() {
  const paths = [];
  for (const collection of ENTRY_COLLECTIONS) {
    const entries = await getCollection(collection);
    // Business types (events/reviews/announcements) have no `draft` key — `.draft` is
    // `undefined` there, and `!undefined` is `true`, so they pass through unfiltered exactly as
    // before. Only the post-family types this issue adds `draft` to are actually gated, and only
    // in a production build; `astro dev` shows drafts (with a badge inside Hentry) for preview.
    const visible = entries.filter((entry) =>
      import.meta.env.PROD ? !(entry.data as any).draft : true,
    );
    for (const entry of visible) {
      paths.push({ params: { collection, slug: entry.id }, props: { entry } });
    }
  }
  return paths;
}

const { entry } = Astro.props;
const { Content } = await render(entry);
// Per-collection layout. Only non-h-entry vocabularies need their own; the `collection`
// discriminant narrows `entry` to each layout's exact CollectionEntry type, so everything
// else (notes, articles, photos, albums, bookmarks, replies, likes, announcements) is h-entry.
---

{
  entry.collection === "events" ? (
    <Hevent entry={entry}><Content /></Hevent>
  ) : entry.collection === "reviews" ? (
    <Hreview entry={entry}><Content /></Hreview>
  ) : (
    <Hentry entry={entry}><Content /></Hentry>
  )
}
```

- [ ] **Step 6: `Hentry.astro` — render the badge**

In `Resources/Template/src/layouts/Hentry.astro`, add `draft` to `HentryFields`, import `DraftBadge`, and render it. Replace the top of the file through the `interface HentryFields` block:

```astro
---
import type { CollectionEntry } from "astro:content";
import { Schema } from "astro-seo-schema";
import type { HentryCollection } from "../lib/collections.ts";
import { entrySchema, type HentryData } from "../lib/schema.ts";
import { ownerName } from "../lib/profile.ts";
import BaseLayout from "./BaseLayout.astro";
import SyndicationLinks from "../components/SyndicationLinks.astro";
import DraftBadge from "../components/DraftBadge.astro";

interface Props {
  entry: CollectionEntry<HentryCollection>;
}

// Flattened view of the eight-collection h-entry union — all fields optional; `entry` stays strictly typed above.
interface HentryFields {
  title?: string;
  summary?: string;
  caption?: string;
  publishDate?: Date;
  image?: string;
  images?: string[];
  tags?: string[];
  bookmarkOf?: string;
  inReplyTo?: string;
  likeOf?: string;
  syndication?: string[];
  draft?: boolean;
}
```

Then, in the same file's markup, add the badge as the first child of `<article class="h-entry">`:

```astro
  <article class="h-entry">
    <DraftBadge draft={d.draft} />
    {title && <h1 class="p-name">{title}</h1>}
```

(Everything else in `Hentry.astro` — `jsonLd`, image/bookmark/reply/like markup, tags, syndication — is unchanged.)

- [ ] **Step 7: Feeds — always filter drafts**

In `Resources/Template/src/lib/feed-data.ts`, replace `mapCollection`:

```ts
/// Map a collection's entries to feed items *without* sorting — callers that immediately re-sort
/// (the combined feed) skip the wasted per-collection sort. Drafts are always excluded (#798): a
/// feed is syndication data consumed by external readers, not a live dev preview, so unlike the
/// page routes above this filter is unconditional — dev or prod, a draft never appears in a feed.
async function mapCollection(collection: string, site: string): Promise<FeedItem[]> {
  const entries = await getCollection(collection as any, (entry: any) => !entry.data.draft);
  return entries.map((e: any) =>
    toFeedItem(collection, { id: e.id, collection, data: e.data, body: e.body }, site),
  );
}
```

- [ ] **Step 8: Run the template's existing JS checks**

Run (from `Resources/Template/`): `npm run lint && npm run typecheck && npm test`
Expected: PASS. (`npm test` here is the plain `node:test` suite including `src/lib/feeds.test.ts`, which doesn't exercise `feed-data.ts`'s `getCollection` call directly — Task 6 covers that with a real build.)

- [ ] **Step 9: Commit**

```bash
git add Resources/Template/src/pages/blog/index.astro Resources/Template/src/pages/blog/\[...slug\].astro \
        Resources/Template/src/layouts/BlogPost.astro Resources/Template/src/pages/\[collection\]/\[...slug\].astro \
        Resources/Template/src/layouts/Hentry.astro Resources/Template/src/lib/feed-data.ts \
        Resources/Template/src/components/DraftBadge.astro
git commit -m "feat(template): filter drafts from pages/feeds, show Draft badge in dev (#798)"
```

---

### Task 6: Template fixture test — drafts never reach `dist/`

**Files:**
- Create: `Tests/AnglesiteCoreTests/DraftContentRenderSmokeTests.swift`

**Interfaces:**
- Consumes: `TemplateBuildSerializer.shared.serialize` (existing, `Tests/AnglesiteTestSupport/TemplateBuildSerializer.swift`), `E2EPrerequisites.locateNode()` (existing), `ProcessSupervisor.shared.run` (existing).

This is the "Template fixture tests: a draft entry emits no `dist/` page, no index/feed entry, per collection" bullet from the issue. It follows `PersonalTypeRenderSmokeTests`'/`FeedsRenderSmokeTests`' exact pattern (real `astro build` against the committed template, serialized against the other render-smoke suites) but additionally writes one temporary draft `.md` file into each of the eight draft-bearing collections (`blog` + the seven post-family types) before the build, and removes them afterward regardless of outcome.

- [ ] **Step 1: Write the test**

```swift
// Tests/AnglesiteCoreTests/DraftContentRenderSmokeTests.swift
import Testing
import Foundation
import AnglesiteTestSupport
@testable import AnglesiteCore

@Suite("Draft content render smoke")
struct DraftContentRenderSmokeTests {

    static var templateDir: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Resources/Template", isDirectory: true)
    }

    static var buildable: Bool {
        guard E2EPrerequisites.locateNode() != nil else { return false }
        return FileManager.default.isReadableFile(
            atPath: templateDir.appendingPathComponent("node_modules/astro/astro.js").path)
    }

    /// One temporary draft entry per draft-bearing collection, with distinguishable slugs/titles
    /// so a leak into `dist/` is unambiguous. `blog` uses `pubDate`; every post-family type uses
    /// `publishDate` — both accept the same ISO8601 literal.
    private static let draftFixtures: [(collection: String, slug: String, frontmatter: String)] = [
        ("blog", "draft-smoke-blog", "title: \"Draft Smoke Blog\"\npubDate: 2026-01-01T00:00:00.000Z\ndraft: true"),
        ("notes", "draft-smoke-note", "publishDate: 2026-01-01T00:00:00.000Z\ndraft: true"),
        ("articles", "draft-smoke-article", "title: \"Draft Smoke Article\"\npublishDate: 2026-01-01T00:00:00.000Z\ndraft: true"),
        ("photos", "draft-smoke-photo", "image: \"/images/hello.svg\"\npublishDate: 2026-01-01T00:00:00.000Z\ndraft: true"),
        ("albums", "draft-smoke-album", "title: \"Draft Smoke Album\"\nimages: [\"/images/one.jpg\"]\npublishDate: 2026-01-01T00:00:00.000Z\ndraft: true"),
        ("bookmarks", "draft-smoke-bookmark", "bookmarkOf: \"https://example.com/\"\npublishDate: 2026-01-01T00:00:00.000Z\ndraft: true"),
        ("replies", "draft-smoke-reply", "inReplyTo: \"https://example.com/post\"\npublishDate: 2026-01-01T00:00:00.000Z\ndraft: true"),
        ("likes", "draft-smoke-like", "likeOf: \"https://example.com/liked\"\npublishDate: 2026-01-01T00:00:00.000Z\ndraft: true"),
    ]

    @Test("a draft entry in every collection emits no dist/ page and no feed entry",
          .enabled(if: DraftContentRenderSmokeTests.buildable))
    func draftsNeverBuild() async throws {
        let node = try #require(E2EPrerequisites.locateNode())
        let dist = Self.templateDir.appendingPathComponent("dist", isDirectory: true)
        let fm = FileManager.default

        var writtenFiles: [URL] = []
        for fixture in Self.draftFixtures {
            let dir = Self.templateDir.appendingPathComponent("src/content/\(fixture.collection)", isDirectory: true)
            let file = dir.appendingPathComponent("\(fixture.slug).md")
            let contents = "---\n\(fixture.frontmatter)\n---\n\nDraft smoke fixture; must not build.\n"
            try contents.write(to: file, atomically: true, encoding: .utf8)
            writtenFiles.append(file)
        }
        defer { for file in writtenFiles { try? fm.removeItem(at: file) } }

        try await TemplateBuildSerializer.shared.serialize {
            try? fm.removeItem(at: dist)
            defer { try? fm.removeItem(at: dist) }

            let result = try await ProcessSupervisor.shared.run(
                executable: node,
                arguments: ["node_modules/astro/astro.js", "build"],
                currentDirectoryURL: Self.templateDir)
            try #require(result.exitCode == 0, "astro build failed: \(result.stdout)\n\(result.stderr)")

            for fixture in Self.draftFixtures {
                let pagePath = fixture.collection == "blog"
                    ? "blog/\(fixture.slug)/index.html"
                    : "\(fixture.collection)/\(fixture.slug)/index.html"
                #expect(!fm.fileExists(atPath: dist.appendingPathComponent(pagePath).path),
                        "\(fixture.collection): draft entry leaked into \(pagePath)")

                let feedPath = "\(fixture.collection)/feed.json"
                let feedJSON = try String(contentsOf: dist.appendingPathComponent(feedPath), encoding: .utf8)
                #expect(!feedJSON.contains(fixture.slug), "\(fixture.collection): draft slug leaked into \(feedPath)")
            }

            let blogIndex = try String(
                contentsOf: dist.appendingPathComponent("blog/index.html"), encoding: .utf8)
            #expect(!blogIndex.contains("Draft Smoke Blog"), "draft blog post leaked into the /blog/ index")

            let combinedFeed = try String(
                contentsOf: dist.appendingPathComponent("feed.json"), encoding: .utf8)
            for fixture in Self.draftFixtures where fixture.collection != "blog" {
                #expect(!combinedFeed.contains(fixture.slug), "\(fixture.slug) leaked into the combined feed")
            }
        }
    }
}
```

- [ ] **Step 2: Run it**

Run: `swift test --package-path . --filter DraftContentRenderSmokeTests`
Expected: PASS if Task 5 is complete and correct; if it fails, re-check Task 5 Steps 2/3/5/7 rather than adjusting this test — this test is the source of truth for "drafts never build," not the other suites.

- [ ] **Step 3: Commit**

```bash
git add Tests/AnglesiteCoreTests/DraftContentRenderSmokeTests.swift
git commit -m "test(template): draft entries never reach dist/ or feeds (#798)"
```

---

### Task 7: `NativeContentOperations.publish`/`unpublish`

**Files:**
- Modify: `Sources/AnglesiteCore/NativeContentOperations.swift`
- Modify: `Tests/AnglesiteCoreTests/NativeContentOperationsTests.swift`

**Interfaces:**
- Consumes: `TypedContentEditor.read(_:descriptor:)` / `.write(_:into:descriptor:)` (existing, `Sources/AnglesiteCore/TypedContentEditor.swift`), `ContentTypeRegistry.descriptor(forCollection:)` (existing, `ContentTypeRegistry.swift:171`), `ContentCreateResult` (existing, reused rather than adding a new result type — `restoreContent` already sets this precedent for "write + commit, report the path back" operations that aren't literally a first-time create).
- Produces:
  - `public typealias GitHasCommit = @Sendable (_ projectRoot: URL, _ message: String) async -> Bool`
  - `public func publish(siteID: String, relativePath: String, collection: String, registry: ContentTypeRegistry = ContentTypeRegistry()) async -> ContentCreateResult`
  - `public func unpublish(siteID: String, relativePath: String, collection: String, registry: ContentTypeRegistry = ContentTypeRegistry()) async -> ContentCreateResult`
  - `public static func hasCommit(_ projectRoot: URL, _ message: String) async -> Bool` (default `GitHasCommit` implementation, Darwin via SwiftGit2 / non-Darwin via subprocess `git log`, mirroring `processGitCommit`/`processGitDelete`'s existing split).

- [ ] **Step 1: Add the `GitHasCommit` seam to the struct**

In `Sources/AnglesiteCore/NativeContentOperations.swift`, add the typealias next to the existing two:

```swift
    public typealias GitCommit = @Sendable (_ projectRoot: URL, _ relPath: String, _ message: String) async -> String?
    public typealias GitDelete = @Sendable (_ projectRoot: URL, _ relPath: String, _ message: String) async -> String?
    /// Whether `projectRoot`'s commit history already contains a commit whose message is exactly
    /// `message` — used by `publish` to tell a first-time publish from a republish (#798), without
    /// a persisted "everPublished" flag. Injectable for the same reason `GitCommit`/`GitDelete` are:
    /// tests supply a fake in-memory history instead of a real git repo.
    public typealias GitHasCommit = @Sendable (_ projectRoot: URL, _ message: String) async -> Bool
```

Add the stored property next to `gitDelete`:

```swift
    private let gitHasCommit: GitHasCommit
```

Update the initializer:

```swift
    public init(
        siteDirectory: @escaping @Sendable (_ siteID: String) async -> URL?,
        gitCommit: @escaping GitCommit = NativeContentOperations.processGitCommit,
        gitDelete: @escaping GitDelete = NativeContentOperations.processGitDelete,
        gitHasCommit: @escaping GitHasCommit = NativeContentOperations.hasCommit,
        now: @escaping @Sendable () -> Date = { Date() },
        copyGenerator: any PageCopyGenerating = NoopPageCopyGenerator(),
        fileManager: FileManager = .default
    ) {
        self.siteDirectory = siteDirectory
        self.gitCommit = gitCommit
        self.gitDelete = gitDelete
        self.gitHasCommit = gitHasCommit
        self.now = now
        self.copyGenerator = copyGenerator
        self.fileManager = fileManager
    }
```

- [ ] **Step 2: Add the default `hasCommit` implementation next to `processGitCommit`**

In the `#if canImport(Darwin)` branch (right after `processGitCommit`'s closing `}` and before `#else`):

```swift
    /// Default `GitHasCommit`: walks history from HEAD looking for an exact message match.
    /// Best-effort like `processGitCommit` — an unreadable repo or unresolvable HEAD (e.g. zero
    /// commits) reports `false`, which `publish` treats as "never published," the safe default.
    @Sendable public static func hasCommit(_ projectRoot: URL, _ message: String) async -> Bool {
        SwiftGit2Bootstrap.ensureInitialized
        guard case .success(let repo) = Repository.at(projectRoot) else { return false }
        guard case .success(let head) = repo.HEAD() else { return false }
        for result in repo.commits(from: head.oid) {
            guard case .success(let commit) = result else { continue }
            if commit.message.trimmingCharacters(in: .whitespacesAndNewlines) == message { return true }
        }
        return false
    }
```

In the `#else` branch (right after `processGitCommit`'s closing `}`, matching the `#else` half):

```swift
    /// Default `GitHasCommit` off-Darwin: `git log --grep` narrows to candidates, then each is
    /// confirmed for an exact match (the message shell-metacharacter-escaped via -F/--fixed-strings
    /// wouldn't itself need this, but this avoids depending on --grep's own exact-match semantics).
    @Sendable public static func hasCommit(_ projectRoot: URL, _ message: String) async -> Bool {
        let git = URL(fileURLWithPath: "/usr/bin/git")
        guard let result = try? await ProcessSupervisor.shared.run(
            executable: git,
            arguments: ["log", "--format=%s", "--fixed-strings", "--grep=\(message)"],
            currentDirectoryURL: projectRoot), result.exitCode == 0 else { return false }
        return result.stdout.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == message }
    }
```

- [ ] **Step 3: Write the failing tests**

Add to `Tests/AnglesiteCoreTests/NativeContentOperationsTests.swift`:

```swift
    private func makePublishOps(
        publishedBefore: Bool = false,
        now: Date = Date(timeIntervalSince1970: 1_750_000_000)
    ) -> (ops: NativeContentOperations, root: URL, calls: Spy) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-content-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let spy = Spy()
        let ops = NativeContentOperations(
            siteDirectory: { _ in root },
            gitCommit: { proj, rel, msg in await spy.record(proj, rel, msg); return "deadbeef" },
            gitHasCommit: { _, _ in publishedBefore },
            now: { now }
        )
        return (ops, root, spy)
    }

    @Test("publish sets draft: false and re-stamps publishDate on a first publish")
    func publishFirstTime() async throws {
        let (ops, root, spy) = makePublishOps(publishedBefore: false)
        let dir = root.appendingPathComponent("src/content/notes", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("my-note.md")
        try """
        ---
        publishDate: 2020-01-01T00:00:00.000Z
        tags: []
        draft: true
        ---

        Hello.
        """.write(to: file, atomically: true, encoding: .utf8)

        let result = await ops.publish(siteID: "s1", relativePath: "src/content/notes/my-note.md", collection: "notes")
        #expect(result == .created(filePath: "src/content/notes/my-note.md", identifier: "my-note"))

        let written = try String(contentsOf: file, encoding: .utf8)
        #expect(written.contains("draft: false"))
        #expect(written.contains("publishDate: 2025-06-15T15:06:40.000Z")) // re-stamped to `now`
        #expect(!written.contains("2020-01-01"))

        let calls = await spy.calls
        #expect(calls.count == 1)
        #expect(calls.first?.2 == "anglesite: publish note my-note")
    }

    @Test("publish keeps the original publishDate on a republish")
    func publishRepublish() async throws {
        let (ops, root, spy) = makePublishOps(publishedBefore: true)
        let dir = root.appendingPathComponent("src/content/notes", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("my-note.md")
        try """
        ---
        publishDate: 2020-01-01T00:00:00.000Z
        tags: []
        draft: true
        ---

        Hello.
        """.write(to: file, atomically: true, encoding: .utf8)

        let result = await ops.publish(siteID: "s1", relativePath: "src/content/notes/my-note.md", collection: "notes")
        #expect(result == .created(filePath: "src/content/notes/my-note.md", identifier: "my-note"))

        let written = try String(contentsOf: file, encoding: .utf8)
        #expect(written.contains("draft: false"))
        #expect(written.contains("publishDate: 2020-01-01T00:00:00.000Z")) // untouched

        let calls = await spy.calls
        #expect(calls.first?.2 == "anglesite: publish note my-note")
    }

    @Test("unpublish sets draft: true and leaves publishDate untouched")
    func unpublish() async throws {
        let (ops, root, spy) = makePublishOps()
        let dir = root.appendingPathComponent("src/content/notes", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("my-note.md")
        try """
        ---
        publishDate: 2025-06-15T15:06:40.000Z
        tags: []
        draft: false
        ---

        Hello.
        """.write(to: file, atomically: true, encoding: .utf8)

        let result = await ops.unpublish(siteID: "s1", relativePath: "src/content/notes/my-note.md", collection: "notes")
        #expect(result == .created(filePath: "src/content/notes/my-note.md", identifier: "my-note"))

        let written = try String(contentsOf: file, encoding: .utf8)
        #expect(written.contains("draft: true"))
        #expect(written.contains("publishDate: 2025-06-15T15:06:40.000Z"))

        let calls = await spy.calls
        #expect(calls.first?.2 == "anglesite: unpublish note my-note")
    }

    @Test("publish reports .failed for an unregistered collection")
    func publishUnknownCollection() async {
        let (ops, _, _) = makePublishOps()
        let result = await ops.publish(siteID: "s1", relativePath: "src/content/blog/hello.md", collection: "blog")
        guard case let .failed(reason) = result else { Issue.record("expected .failed"); return }
        #expect(reason.contains("blog"))
    }
```

- [ ] **Step 4: Run to verify these fail**

Run: `swift test --package-path . --filter NativeContentOperationsTests`
Expected: FAIL to compile — `publish`/`unpublish` don't exist yet.

- [ ] **Step 5: Implement `publish`/`unpublish`**

Add to `Sources/AnglesiteCore/NativeContentOperations.swift`, near `restoreContent` (they share its "rewrite + commit, report `ContentCreateResult`" shape):

```swift
    /// "Publish" (#798): flip `draft: false`, re-stamping `publishDate` to now only when this
    /// entry has never been published before — a fresh draft's `publishDate` is already stamped
    /// to its creation time by `ContentScaffold.renderEntry`, and `unpublish` doesn't clear it, so
    /// "never published" is detected via `gitHasCommit` rather than the frontmatter itself: this
    /// exact commit message has never appeared in history. A republish (published → unpublished →
    /// published again) keeps its original date, per the design doc's "an explicitly user-edited
    /// date is respected" rule — a previously-published date counts as user-visible, not provisional.
    public func publish(
        siteID: String,
        relativePath: String,
        collection: String,
        registry: ContentTypeRegistry = ContentTypeRegistry()
    ) async -> ContentCreateResult {
        guard let root = await siteDirectory(siteID) else { return .siteNotFound }
        guard let descriptor = registry.descriptor(forCollection: collection) else {
            return .failed(reason: "\(collection) is not a registered content type")
        }
        let abs = root.appendingPathComponent(relativePath)
        guard let raw = try? String(contentsOf: abs, encoding: .utf8) else {
            return .failed(reason: "Couldn't read \(relativePath)")
        }
        let slug = abs.deletingPathExtension().lastPathComponent
        let message = "anglesite: publish \(descriptor.id) \(slug)"

        var values = TypedContentEditor.read(raw, descriptor: descriptor)
        values["draft"] = .flag(false)
        let publishedBefore = await gitHasCommit(root, message)
        if !publishedBefore {
            values["publishDate"] = .date(now())
        }
        let newContents = TypedContentEditor.write(values, into: raw, descriptor: descriptor)
        do { try write(newContents, to: abs) }
        catch { return .failed(reason: "\(error)") }

        guard await gitCommit(root, relativePath, message) != nil else {
            return .failed(reason: "Published \(relativePath), but couldn't save it to your site's history. Try again in a moment.")
        }
        return .created(filePath: relativePath, identifier: slug)
    }

    /// "Unpublish": the inverse of `publish` — flip `draft: true`, leave `publishDate` untouched
    /// so a later `publish` can still tell (via `gitHasCommit`) that this entry was public once.
    public func unpublish(
        siteID: String,
        relativePath: String,
        collection: String,
        registry: ContentTypeRegistry = ContentTypeRegistry()
    ) async -> ContentCreateResult {
        guard let root = await siteDirectory(siteID) else { return .siteNotFound }
        guard let descriptor = registry.descriptor(forCollection: collection) else {
            return .failed(reason: "\(collection) is not a registered content type")
        }
        let abs = root.appendingPathComponent(relativePath)
        guard let raw = try? String(contentsOf: abs, encoding: .utf8) else {
            return .failed(reason: "Couldn't read \(relativePath)")
        }
        var values = TypedContentEditor.read(raw, descriptor: descriptor)
        values["draft"] = .flag(true)
        let newContents = TypedContentEditor.write(values, into: raw, descriptor: descriptor)
        do { try write(newContents, to: abs) }
        catch { return .failed(reason: "\(error)") }

        let slug = abs.deletingPathExtension().lastPathComponent
        guard await gitCommit(root, relativePath, "anglesite: unpublish \(descriptor.id) \(slug)") != nil else {
            return .failed(reason: "Unpublished \(relativePath), but couldn't save it to your site's history. Try again in a moment.")
        }
        return .created(filePath: relativePath, identifier: slug)
    }
```

- [ ] **Step 6: Run to verify the tests pass**

Run: `swift test --package-path . --filter NativeContentOperationsTests`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteCore/NativeContentOperations.swift Tests/AnglesiteCoreTests/NativeContentOperationsTests.swift
git commit -m "feat(core): NativeContentOperations.publish/unpublish (#798)"
```

---

### Task 8: `ContentCreationWorkflow` — wire publish/unpublish through the graph refresh

**Files:**
- Modify: `Sources/AnglesiteCore/ContentCreationWorkflow.swift`
- Modify: `Tests/AnglesiteCoreTests/ContentCreationWorkflowTests.swift` (already exists — `@testable import AnglesiteCore`, `@Suite("ContentCreationWorkflow")`; append a new suite rather than editing the existing one)

**Interfaces:**
- Consumes: `NativeContentOperations.publish`/`.unpublish` (Task 7), `ContentCreationWorkflow.refreshContentGraphIfCreated` (existing, private).
- Produces: `ContentCreationWorkflow.publish(siteID:relativePath:collection:) async -> ContentCreateResult` and `.unpublish(...)`, both rescanning `SiteContentGraph` on success exactly like `duplicatePost`.

- [ ] **Step 1: Add the closures and stored properties**

In `Sources/AnglesiteCore/ContentCreationWorkflow.swift`, add typealiases next to `PostDuplicator`:

```swift
    public typealias PostPublisher = @Sendable (_ siteID: String, _ relativePath: String, _ collection: String) async -> ContentCreateResult
    public typealias PostUnpublisher = @Sendable (_ siteID: String, _ relativePath: String, _ collection: String) async -> ContentCreateResult
```

Add stored properties next to `postDuplicator`:

```swift
    private let postPublisher: PostPublisher?
    private let postUnpublisher: PostUnpublisher?
```

Add parameters to `init` (after `postDuplicator`) and assign them:

```swift
        postDuplicator: PostDuplicator? = nil,
        postPublisher: PostPublisher? = nil,
        postUnpublisher: PostUnpublisher? = nil,
        componentCreator: ComponentCreator? = nil,
```

```swift
        self.postDuplicator = postDuplicator
        self.postPublisher = postPublisher
        self.postUnpublisher = postUnpublisher
        self.componentCreator = componentCreator
```

- [ ] **Step 2: Wire the `.native(...)` factory**

In `.native(...)`, after `postDuplicator:`:

```swift
            postDuplicator: { siteID, relativePath, collection, title in
                await native.duplicatePost(siteID: siteID, relativePath: relativePath, collection: collection, title: title)
            },
            postPublisher: { siteID, relativePath, collection in
                await native.publish(siteID: siteID, relativePath: relativePath, collection: collection)
            },
            postUnpublisher: { siteID, relativePath, collection in
                await native.unpublish(siteID: siteID, relativePath: relativePath, collection: collection)
            },
```

- [ ] **Step 3: Add the public methods**

After `duplicatePost`:

```swift
    public func publish(siteID: String, relativePath: String, collection: String) async -> ContentCreateResult {
        guard let postPublisher else { return .failed(reason: "Publish is not configured for this workflow") }
        let result = await postPublisher(siteID, relativePath, collection)
        await refreshContentGraphIfCreated(result, siteID: siteID)
        return result
    }

    public func unpublish(siteID: String, relativePath: String, collection: String) async -> ContentCreateResult {
        guard let postUnpublisher else { return .failed(reason: "Unpublish is not configured for this workflow") }
        let result = await postUnpublisher(siteID, relativePath, collection)
        await refreshContentGraphIfCreated(result, siteID: siteID)
        return result
    }
```

- [ ] **Step 4: Confirm existing coverage still compiles/passes**

Run: `grep -rl "ContentCreationWorkflow(" Tests/` to find what already constructs this type directly (rather than via `.native`), and check whether any of those call sites use positional/full-argument-label init calls that the two new optional parameters would break. Swift's memberwise-style label-based calls are unaffected by adding new *optional, defaulted* parameters in the middle of a signature, but confirm by running:

Run: `swift test --package-path . --filter ContentCreationWorkflow 2>&1 | tail -40`
Expected: PASS (existing tests, if any, are source-compatible since the new params default to `nil`).

- [ ] **Step 5: Write a focused new test**

Append to `Tests/AnglesiteCoreTests/ContentCreationWorkflowTests.swift` (a new `@Suite` in the same file, matching this file's existing single-suite-per-concern style):

```swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("ContentCreationWorkflow publish/unpublish")
struct ContentCreationWorkflowPublishTests {
    @Test("publish rescans the content graph on success")
    func publishRescans() async {
        let graph = SiteContentGraph()
        // No `generation:` here — it's guarded against `beginScan` tokens this test never claims;
        // omitting it (nil default) applies unconditionally, per `SiteContentGraph.load`'s own doc
        // comment and every other test in this file.
        await graph.load(siteID: "s1", pages: [], posts: [], images: [])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var publishCalls = 0
        let workflow = ContentCreationWorkflow(
            operations: NativeContentOperations(siteDirectory: { _ in root }),
            contentGraph: graph,
            siteDirectory: { _ in root },
            postPublisher: { _, relativePath, _ in
                publishCalls += 1
                return .created(filePath: relativePath, identifier: "my-note")
            }
        )

        let result = await workflow.publish(siteID: "s1", relativePath: "src/content/notes/my-note.md", collection: "notes")
        #expect(result == .created(filePath: "src/content/notes/my-note.md", identifier: "my-note"))
        #expect(publishCalls == 1)
    }

    @Test("publish reports .failed when the workflow has no publisher configured")
    func publishUnconfigured() async {
        let workflow = ContentCreationWorkflow(
            operations: NativeContentOperations(siteDirectory: { _ in nil }),
            contentGraph: nil,
            siteDirectory: { _ in nil }
        )
        let result = await workflow.publish(siteID: "s1", relativePath: "x.md", collection: "notes")
        #expect(result == .failed(reason: "Publish is not configured for this workflow"))
    }
}
```

- [ ] **Step 6: Run**

Run: `swift test --package-path . --filter ContentCreationWorkflowPublishTests`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteCore/ContentCreationWorkflow.swift Tests/AnglesiteCoreTests/ContentCreationWorkflowTests.swift
git commit -m "feat(core): thread publish/unpublish through ContentCreationWorkflow (#798)"
```

---

### Task 9: `SiteNavigatorModel` — `canPublish`/`canUnpublish` gating

**Files:**
- Modify: `Sources/AnglesiteApp/SiteNavigatorModel.swift`
- Modify: `Tests/AnglesiteAppTests/SiteNavigatorModelTests.swift` (already exists — `@testable import AnglesiteAppCore`, `@Suite("SiteNavigatorModel")`; append a new suite)

**Interfaces:**
- Consumes: `SiteContentGraph.Post` (existing, `.collection`, `.draft`), `ContentTypeRegistry.descriptor(forCollection:)` (existing).
- Produces: `SiteNavigatorModel.canPublish(_ id: String) -> Bool`, `.canUnpublish(_ id: String) -> Bool` — both `false` for pages, business-type posts, and `blog` posts (no registered descriptor); for a registry-backed post-family entry, mutually exclusive on its current `draft` value.

- [ ] **Step 1: Add a registry instance and a posts-by-id cache**

In `Sources/AnglesiteApp/SiteNavigatorModel.swift`, add near the existing `postIDs` property:

```swift
    /// Post ids seen in the last `refresh()`, so `canRepurpose` can distinguish post rows from
    /// page rows without an extra actor hop — both are `.route` targets and `isContentRow` alone
    /// can't tell them apart (Task 16, #465).
    private var postIDs: Set<String> = []
    /// Full post records from the last `refresh()`, so `canPublish`/`canUnpublish` (#798) can read
    /// a row's collection and current draft state without an extra actor hop.
    private var postsByID: [String: SiteContentGraph.Post] = [:]
    private let contentTypeRegistry = ContentTypeRegistry()
```

- [ ] **Step 2: Populate it in `refresh()`**

Replace the `postIDs = Set(posts.map(\.id))` line in `refresh(siteID:siteRoot:)`:

```swift
        // Assigned together with `nodes` below so `canRepurpose`/`canPublish`/`canUnpublish` never
        // gate against a post set that's out of sync with what's actually shown in the sidebar.
        postIDs = Set(posts.map(\.id))
        postsByID = Dictionary(uniqueKeysWithValues: posts.map { ($0.id, $0) })
```

- [ ] **Step 3: Add the gating methods**

Near `canRepurpose`:

```swift
    /// Publish/Unpublish (#798) apply only to registry-backed typed post-family entries — `blog`
    /// posts have no `ContentTypeDescriptor` (they predate the registry, per `content.config.ts`'s
    /// hand-authored `blog` block) and keep their existing verb-less draft workflow.
    private func publishableDescriptor(_ id: String) -> ContentTypeDescriptor? {
        guard let post = postsByID[id] else { return nil }
        return contentTypeRegistry.descriptor(forCollection: post.collection)
    }

    func canPublish(_ id: String) -> Bool {
        guard let post = postsByID[id], publishableDescriptor(id) != nil else { return false }
        return post.draft
    }

    func canUnpublish(_ id: String) -> Bool {
        guard let post = postsByID[id], publishableDescriptor(id) != nil else { return false }
        return !post.draft
    }
```

- [ ] **Step 4: Verify against the existing suite for this model**

Run: `find Tests -iname "SiteNavigatorModelTests.swift"`

The file exists (`Tests/AnglesiteAppTests/SiteNavigatorModelTests.swift`) — note it imports `@testable import AnglesiteAppCore`, **not** `AnglesiteApp` (the app-internal types under `Sources/AnglesiteApp/` build into a module named `AnglesiteAppCore`, split out for testability), and its existing tests wait for the first async refresh with `while model.nodes.isEmpty { await Task.yield() }` rather than a sleep — match that idiom exactly (this repo's convention is event-driven waits, not tuned timeouts). Add a new suite to the file:

```swift
@Suite("SiteNavigatorModel publish/unpublish gating (#798)")
@MainActor
struct SiteNavigatorModelPublishGatingTests {
    @Test("canPublish/canUnpublish are mutually exclusive for a typed post, false for pages and blog posts")
    func publishGating() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let graph = SiteContentGraph()
        // No `generation:` — nil (the default) applies unconditionally, matching every other
        // test-caller of `load` in this codebase; a non-nil value is guarded against a
        // `beginScan` token this test never claims and would silently discard the load.
        await graph.load(
            siteID: "site-1",
            pages: [],
            posts: [
                SiteContentGraph.Post(
                    id: "site-1:post:draft-note", siteID: "site-1", collection: "notes", slug: "draft-note",
                    title: "Draft note", draft: true, publishDate: nil, tags: [],
                    filePath: "src/content/notes/draft-note.md", lastModified: Date()),
                SiteContentGraph.Post(
                    id: "site-1:post:live-note", siteID: "site-1", collection: "notes", slug: "live-note",
                    title: "Live note", draft: false, publishDate: Date(), tags: [],
                    filePath: "src/content/notes/live-note.md", lastModified: Date()),
                SiteContentGraph.Post(
                    id: "site-1:post:blog-post", siteID: "site-1", collection: "blog", slug: "blog-post",
                    title: "Blog post", draft: true, publishDate: nil, tags: [],
                    filePath: "src/content/blog/blog-post.md", lastModified: Date()),
            ],
            images: []
        )

        let model = SiteNavigatorModel(graph: graph)
        model.start(siteID: "site-1", siteRoot: root, sourceDirectory: root, websiteTitle: "Test")
        while model.nodes.isEmpty { await Task.yield() }

        #expect(model.canPublish("site-1:post:draft-note") == true)
        #expect(model.canUnpublish("site-1:post:draft-note") == false)
        #expect(model.canPublish("site-1:post:live-note") == false)
        #expect(model.canUnpublish("site-1:post:live-note") == true)
        #expect(model.canPublish("site-1:post:blog-post") == false)
        #expect(model.canUnpublish("site-1:post:blog-post") == false)
        model.stop()
    }
}
```

Run: `swift test --package-path . --filter SiteNavigatorModelPublishGatingTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/SiteNavigatorModel.swift Tests/AnglesiteAppTests/SiteNavigatorModelTests.swift
git commit -m "feat(app): SiteNavigatorModel publish/unpublish gating (#798)"
```

---

### Task 10: `SiteWindowModel.publish(id:)` / `.unpublish(id:)`

**Files:**
- Modify: `Sources/AnglesiteApp/SiteWindowModel.swift`

**Interfaces:**
- Consumes: `ContentCreationWorkflow.publish`/`.unpublish` (Task 8), `SiteContentGraph.post(id:)` (existing), `navigator?.refreshNow()` (existing), `contentActionError` (existing, used by `duplicate(id:)`).
- Produces: `SiteWindowModel.publish(id: String) async`, `.unpublish(id: String) async` — same shape as `duplicate(id:)`: resolve the post, call the workflow, refresh the Navigator on success, surface `.failed` via `contentActionError`.

- [ ] **Step 1: Add the methods next to `duplicate(id:)`**

```swift
    /// Publishes the post at `id` (#798): sets `draft: false`, re-stamping `publishDate` only on
    /// a first publish. Non-destructive (Unpublish reverses it), so no confirmation — same
    /// no-confirmation precedent as `duplicate(id:)`.
    @MainActor
    func publish(id: String) async {
        guard let site, let post = await contentGraph.post(id: id) else { return }
        let result = await contentCreation.publish(
            siteID: site.id, relativePath: post.filePath, collection: post.collection)
        switch result {
        case .created:
            await navigator?.refreshNow()
        case .failed(let reason):
            contentActionError = reason
        case .siteNotFound:
            break
        }
    }

    /// Unpublishes the post at `id` (#798): sets `draft: true`, leaving `publishDate` untouched.
    @MainActor
    func unpublish(id: String) async {
        guard let site, let post = await contentGraph.post(id: id) else { return }
        let result = await contentCreation.unpublish(
            siteID: site.id, relativePath: post.filePath, collection: post.collection)
        switch result {
        case .created:
            await navigator?.refreshNow()
        case .failed(let reason):
            contentActionError = reason
        case .siteNotFound:
            break
        }
    }
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -40`
Expected: BUILD SUCCEEDED. (Run `xcodegen generate` first if the project file predates Task 7/8's new source files — new files under `Sources/` are picked up automatically by XcodeGen's glob-based `project.yml` sources entry, but regenerate if the build reports missing symbols that Task 7/8 clearly added.)

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteApp/SiteWindowModel.swift
git commit -m "feat(app): SiteWindowModel.publish/unpublish (#798)"
```

---

### Task 11: UI wiring — Edit menu + Navigator context menu

**Files:**
- Modify: `Sources/AnglesiteApp/FocusedSite.swift`
- Modify: `Sources/AnglesiteApp/SiteNavigatorView.swift`
- Modify: `Sources/AnglesiteApp/SiteWindow.swift`

**Interfaces:**
- Consumes: `SiteNavigatorModel.canPublish`/`.canUnpublish` (Task 9), `SiteWindowModel.publish(id:)`/`.unpublish(id:)` (Task 10).
- Produces: "Publish"/"Unpublish" in the Edit menu (next to Delete/Duplicate) and in the Navigator row context menu, both disabled/hidden per the same gating.

- [ ] **Step 1: Extend `NavigatorSelectionActions` and its Edit-menu commands**

In `Sources/AnglesiteApp/FocusedSite.swift`, replace the struct:

```swift
/// Delete/Duplicate/Publish/Unpublish acting on the Navigator's current selection (#516, #798).
/// Each action is `nil` when there is no selection, or the selection doesn't support that verb
/// (`SiteNavigatorModel.canDelete`/`canDuplicate`/`canPublish`/`canUnpublish`) — that's what lets
/// the Edit-menu items enable/disable correctly without the menu needing to know Navigator internals.
struct NavigatorSelectionActions {
    let delete: (@MainActor () -> Void)?
    let duplicate: (@MainActor () -> Void)?
    let publish: (@MainActor () -> Void)?
    let unpublish: (@MainActor () -> Void)?
}
```

In `NavigatorEditCommands`, add after the Duplicate button:

```swift
            Button("Duplicate") {
                actions?.duplicate?()
            }
            .keyboardShortcut("d", modifiers: [.command])
            .disabled(actions?.duplicate == nil)

            Divider()

            Button("Publish") {
                actions?.publish?()
            }
            .disabled(actions?.publish == nil)

            Button("Unpublish") {
                actions?.unpublish?()
            }
            .disabled(actions?.unpublish == nil)
```

- [ ] **Step 2: Extend the Navigator context menu**

In `Sources/AnglesiteApp/SiteNavigatorView.swift`, add two new closure parameters:

```swift
struct SiteNavigatorView: View {
    @Bindable var model: SiteNavigatorModel
    var onDeleteRequested: (NavigatorItem) -> Void
    var onDuplicateRequested: (NavigatorItem) -> Void
    var onRepurposeRequested: (NavigatorItem) -> Void
    var onPublishRequested: (NavigatorItem) -> Void
    var onUnpublishRequested: (NavigatorItem) -> Void
    @FocusState private var editingFocused: Bool
```

In the row's `.contextMenu`, add after the Repurpose button and before Delete:

```swift
                    if model.canRepurpose(node.id), let item = model.item(for: node.id) {
                        Button("Repurpose Post…") { onRepurposeRequested(item) }
                    }
                    if model.canPublish(node.id), let item = model.item(for: node.id) {
                        Button("Publish") { onPublishRequested(item) }
                    }
                    if model.canUnpublish(node.id), let item = model.item(for: node.id) {
                        Button("Unpublish") { onUnpublishRequested(item) }
                    }
                    if model.canDelete(node.id), let item = model.item(for: node.id) {
                        Button("Delete", role: .destructive) { onDeleteRequested(item) }
                    }
```

- [ ] **Step 3: Wire both call sites in `SiteWindow.swift`**

At the `SiteNavigatorView(...)` construction (around line 178), add the two new arguments:

```swift
                SiteNavigatorView(
                    model: navigator,
                    onDeleteRequested: { item in
                        contentDeleteTitle = "Delete “\(item.title)”?"
                        model.deleteConfirmation = item
                    },
                    onDuplicateRequested: { item in
                        Task { await model.duplicate(id: item.id) }
                    },
                    onRepurposeRequested: { item in
                        Task { await model.presentRepurpose(postRowID: item.id) }
                    },
                    onPublishRequested: { item in
                        Task { await model.publish(id: item.id) }
                    },
                    onUnpublishRequested: { item in
                        Task { await model.unpublish(id: item.id) }
                    }
                )
```

In `navigatorSelectionActions(for:)`, extend the returned value:

```swift
    private func navigatorSelectionActions(for model: SiteWindowModel) -> NavigatorSelectionActions? {
        guard model.site != nil, let navigator = model.navigator, let id = navigator.selection else {
            return nil
        }
        let deleteAction: (() -> Void)?
        if navigator.canDelete(id) {
            deleteAction = {
                guard let item = navigator.item(for: id) else { return }
                contentDeleteTitle = "Delete “\(item.title)”?"
                model.deleteConfirmation = item
            }
        } else {
            deleteAction = nil
        }
        let duplicateAction: (() -> Void)?
        if navigator.canDuplicate(id) {
            duplicateAction = {
                Task { await model.duplicate(id: id) }
            }
        } else {
            duplicateAction = nil
        }
        let publishAction: (() -> Void)?
        if navigator.canPublish(id) {
            publishAction = {
                Task { await model.publish(id: id) }
            }
        } else {
            publishAction = nil
        }
        let unpublishAction: (() -> Void)?
        if navigator.canUnpublish(id) {
            unpublishAction = {
                Task { await model.unpublish(id: id) }
            }
        } else {
            unpublishAction = nil
        }
        return NavigatorSelectionActions(
            delete: deleteAction, duplicate: duplicateAction, publish: publishAction, unpublish: unpublishAction)
    }
```

- [ ] **Step 4: Build**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -40`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/FocusedSite.swift Sources/AnglesiteApp/SiteNavigatorView.swift Sources/AnglesiteApp/SiteWindow.swift
git commit -m "feat(app): Publish/Unpublish in the Edit menu and Navigator context menu (#798)"
```

---

### Task 12: Full verification pass

**Files:** none (verification only).

- [ ] **Step 1: Full Swift suite**

Run: `swift test --package-path . 2>&1 | tail -80`
Expected: all suites PASS, including `ContentConfigDriftTests`, `ContentTypeRegistryTests`, `ContentScaffoldTests`, `NativeContentOperationsTests`, `ContentCreationWorkflowPublishTests`, `PersonalTypeRenderSmokeTests`, `FeedsRenderSmokeTests`, `DraftContentRenderSmokeTests`.

- [ ] **Step 2: App target build**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -40`
Expected: BUILD SUCCEEDED — confirms the app target links (per this repo's convention that `swift test` alone doesn't prove that).

- [ ] **Step 3: Template JS checks**

Run (from `Resources/Template/`): `npm run lint && npm run typecheck && npm test`
Expected: PASS.

- [ ] **Step 4: Manual GUI smoke (not automatable in this session)**

Note in the PR description that the following need a human/GUI pass, since none of this repo's CI lanes launch the hosted app (`docs/build-plan.md`'s CI-runner constraint):
- Create a new note/article/etc. → confirm it scaffolds as a draft and the Navigator shows Publish (not Unpublish) enabled for it.
- Run the site's dev server → confirm the draft renders with the "Draft" badge, and doesn't appear in a from-scratch production `astro build` of the same site.
- Publish it from the Edit menu and from the context menu → confirm `draft: false` is written, `publishDate` updates, and the commit message matches `anglesite: publish <type> <slug>`.
- Unpublish → confirm `draft: true`, `publishDate` unchanged, commit message `anglesite: unpublish <type> <slug>`.
- Publish the same entry again → confirm `publishDate` is **not** re-stamped a second time (git-history check working).

- [ ] **Step 5: Update the issue**

```bash
gh issue edit 798 --remove-label "🛠️ In Progress"
```

(Per `CONTRIBUTING.md`: remove the in-progress claim once a PR opens — Task 13, below, is that PR.)

---

### Task 13: Open the pull request

**Files:** none.

- [ ] **Step 1: Push and open the PR**

```bash
git push -u origin HEAD
gh pr create --title "feat: draft → publish content model for posts (#798)" --body "$(cat <<'EOF'
## Summary
- Post-family collections (notes, articles, photos, albums, bookmarks, replies, likes) gain a `draft: z.boolean().default(false)` field, matching `blog`'s existing one.
- New typed posts scaffold as drafts by default; list/detail routes and feeds filter them out of production builds (dev preview still shows them, with a "Draft" badge).
- Desktop Publish/Unpublish verbs in the Edit menu and Navigator context menu: Publish sets `draft: false` and re-stamps `publishDate` only on a first publish (detected via git history, not a new field); Unpublish is the inverse.

Closes #798. Spec: docs/superpowers/specs/2026-07-17-blog-markdown-editor-publishing-design.md Part B.

## Test plan
- [x] `swift test --package-path .` — all suites, including new `DraftContentRenderSmokeTests` (real `astro build` proving drafts never reach `dist/` or feeds)
- [x] `xcodebuild … build` — app target links
- [x] Template `npm run lint && npm run typecheck && npm test`
- [ ] Manual GUI smoke (see Task 12 Step 4 in the implementation plan) — needs a human pass, not automatable in this session

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 2: Report the PR URL to the user.**
