# Blogroll via standard.site graph lexicons — Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a site owner maintain a blogroll (sites they follow) as typed content, publish each entry as a `site.standard.graph.subscription` atproto record, and render a `/blogroll/` page with a CSS-only OPML subscribe badge and a `/blogroll.opml` feed.

**Architecture:** A new `blogroll` content type (Swift registry + Astro Content Collection) is the owner-authored source of truth, git-tracked like every other typed content object. A new post-deploy Swift actor (`StandardSiteGraphPublishCommand`) resolves each entry's target `.well-known/site.standard.publication`, best-effort-publishes a `site.standard.graph.subscription` record, discovers the target's RSS/Atom feed via a refactored HTML-link scanner shared with `WebmentionEndpointDiscovery`, and writes the discovered feed URL back into the entry's own frontmatter. The Astro template renders `/blogroll/` statically from the collection (no build-time network calls) and a `/blogroll.opml` endpoint from whichever entries have a `feedURL`.

**Tech Stack:** Swift 6.4 (`AnglesiteCore`, Swift Testing), Astro Content Collections + Zod (TypeScript), `tsx --test`/`node:test` for template `src/lib` code.

## Global Constraints

- Design source of truth: [`docs/superpowers/specs/2026-08-15-blogroll-standard-site-graph-design.md`](../specs/2026-08-15-blogroll-standard-site-graph-design.md) — read it before starting; this plan implements it, with two corrections made during planning (documented in Task 1: `blogroll` is an `h-card`-projected identity/directory type, not a `projections: nil` type — `ContentTypeProjections.microformat` is non-optional in the real registry — and it has no `draft` field, matching the `member`/`announcement`/`event`/`review` directory-type precedent rather than the h-entry post-family one).
- Every post-deploy pass in this family is best-effort and must never throw into the deploy result — match `StandardSitePublishCommand`'s existing posture exactly.
- No network calls at Astro build time — the graph-publish pass's resolved/discovered data must already be committed to `Source/` (frontmatter or content) by the time a build reads it.
- `CONTRIBUTING.md`: conventional commits, subject ≤72 chars; run `swift test --package-path .` and (for template-touching tasks) `npm test` from `JS/edit-overlay/`-equivalent template test runner (`Resources/Template`'s own `npm test`) before each commit that changes those trees; reference `#1483` in commit subjects.
- Follow existing file organization: new Swift files go in `Sources/AnglesiteCore/`, new Swift tests in `Tests/AnglesiteCoreTests/`, new template library code in `Resources/Template/src/lib/` with a co-located `*.test.ts`, new template routes in `Resources/Template/src/pages/`.

---

## Part A — Content type and static rendering (independently shippable)

### Task 1: Register the `blogroll` content type

**Files:**
- Modify: `Sources/AnglesiteCore/ContentTypeRegistry.swift` (add `blogroll` descriptor + add it to `identityAndDirectoryTypes`, near `member` at line 666-693)
- Modify: `Tests/AnglesiteCoreTests/ContentTypeRegistryTests.swift` (update the `collectionBackedIDs` literal at line 280-286; add a new descriptor test)

**Interfaces:**
- Produces: `ContentTypeRegistry.blogroll: ContentTypeDescriptor` with `id: "blogroll"`, `collection: "blogroll"`, fields `name` (`.string`, required), `url` (`.url`, required), `feedURL` (`.url`, optional), `addedDate` (`.date`, required), and a `.markdown` body (owner's note — content types express their body as the file's markdown content, not a frontmatter field, matching `member`'s `bio: .markdown`).

- [ ] **Step 1: Add the descriptor and register it**

In `Sources/AnglesiteCore/ContentTypeRegistry.swift`, change line 668 from:

```swift
    static let identityAndDirectoryTypes: [ContentTypeDescriptor] = [member]
```

to:

```swift
    static let identityAndDirectoryTypes: [ContentTypeDescriptor] = [member, blogroll]
```

Then add a new descriptor after `member`'s closing `)` (after line 693), before the closing `}` of the enum (line 694):

```swift

    static let blogroll = ContentTypeDescriptor(
        id: "blogroll",
        displayName: "Blogroll entry",
        storage: .collection("blogroll"),
        fields: [
            ContentTypeField("name", .string, required: true),
            ContentTypeField("url", .url, required: true),
            ContentTypeField("feedURL", .url),
            ContentTypeField("addedDate", .date, required: true),
            ContentTypeField("note", .markdown),
        ],
        projections: ContentTypeProjections(
            microformat: "h-card",
            microformatProperties: [
                "name": "p-name",
                "url": "u-url",
                "note": "p-note",
            ],
            schemaType: nil
        )
    )
```

- [ ] **Step 2: Write the failing tests**

In `Tests/AnglesiteCoreTests/ContentTypeRegistryTests.swift`, change the `collectionBackedIDs` test (line 280-286) from:

```swift
    @Test("collectionBackedTypeIDs lists exactly the .collection-stored built-ins, in order")
    func collectionBackedIDs() {
        #expect(ContentTypeRegistry.default.collectionBackedTypeIDs == [
            "note", "article", "photo", "album", "bookmark", "reply", "like",
            "announcement", "event", "review", "member",
        ])
    }
```

to:

```swift
    @Test("collectionBackedTypeIDs lists exactly the .collection-stored built-ins, in order")
    func collectionBackedIDs() {
        #expect(ContentTypeRegistry.default.collectionBackedTypeIDs == [
            "note", "article", "photo", "album", "bookmark", "reply", "like",
            "announcement", "event", "review", "member", "blogroll",
        ])
    }
```

Then add a new test after `likeDescriptor()` (after line 236):

```swift

    @Test("blogroll is an h-card directory entry with no draft field and no schema.org type")
    func blogrollDescriptor() {
        let blogroll = try! #require(ContentTypeRegistry().descriptor(id: "blogroll"))
        #expect(blogroll.displayName == "Blogroll entry")
        #expect(blogroll.collection == "blogroll")
        #expect(blogroll.projections.microformat == "h-card")
        #expect(blogroll.projections.schemaType == nil)
        #expect(blogroll.fields.last?.name != "draft")

        let name = try! #require(blogroll.fields.first { $0.name == "name" })
        #expect(name.kind == .string)
        #expect(name.required)
        #expect(blogroll.projections.microformatProperties["name"] == "p-name")

        let url = try! #require(blogroll.fields.first { $0.name == "url" })
        #expect(url.kind == .url)
        #expect(url.required)
        #expect(blogroll.projections.microformatProperties["url"] == "u-url")

        let feedURL = try! #require(blogroll.fields.first { $0.name == "feedURL" })
        #expect(feedURL.kind == .url)
        #expect(!feedURL.required)
        #expect(blogroll.projections.microformatProperties["feedURL"] == nil)

        let addedDate = try! #require(blogroll.fields.first { $0.name == "addedDate" })
        #expect(addedDate.kind == .date)
        #expect(addedDate.required)
        #expect(blogroll.projections.microformatProperties["addedDate"] == nil)

        let note = try! #require(blogroll.fields.first { $0.name == "note" })
        #expect(note.kind == .markdown)
        #expect(!note.required)
        #expect(blogroll.projections.microformatProperties["note"] == "p-note")
    }
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --package-path . --filter ContentTypeRegistryTests`
Expected: FAIL — `blogrollDescriptor` fails to find a `blogroll` descriptor, `collectionBackedIDs` fails on the array mismatch, since the descriptor doesn't exist yet.

- [ ] **Step 4: Implement Step 1's change if not already applied, then re-run**

Run: `swift test --package-path . --filter ContentTypeRegistryTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/ContentTypeRegistry.swift Tests/AnglesiteCoreTests/ContentTypeRegistryTests.swift
git commit -m "feat(#1483): register blogroll content type"
```

---

### Task 2: Add the `blogroll` Astro Content Collection

**Files:**
- Modify: `Resources/Template/src/content.config.ts` (add `blogroll` collection + register in `collections` export, lines 142-154)

**Interfaces:**
- Consumes: nothing new (standalone Zod schema).
- Produces: a `blogroll` Astro collection queryable via `getCollection("blogroll")`, each entry's `data` shaped `{ name: string, url: string, feedURL?: string, addedDate: Date }`, `body` is the entry's note markdown.

- [ ] **Step 1: Add the collection definition**

In `Resources/Template/src/content.config.ts`, insert after the `members` collection (after line 152, before line 153's blank line / line 154's export):

```ts
const blogroll = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/blogroll" }),
  schema: z.object({
    name: z.string(),
    url: z.string().url(),
    feedURL: z.string().url().optional(),
    addedDate: z.coerce.date(),
  }).strict(),
});
```

Then change line 154 from:

```ts
export const collections = { blog, notes, articles, photos, albums, bookmarks, replies, likes, announcements, events, reviews, members };
```

to:

```ts
export const collections = { blog, notes, articles, photos, albums, bookmarks, replies, likes, announcements, events, reviews, members, blogroll };
```

- [ ] **Step 2: Verify the schema is valid with no seed content**

No fixture or placeholder file is needed: `members` (`Resources/Template/src/content.config.ts` line 142-152, the same `identityAndDirectoryTypes` family `blogroll` joins per Task 1) has no `src/content/members/` directory at all today, and Astro's `glob()` loader tolerates a missing base directory as an empty collection — confirmed by `find Resources/Template/src/content -maxdepth 1 -type d` listing no `members` entry while `members` is still a registered, working collection. `blogroll` should follow the same precedent: no seed/example entry, unlike the eleven post-like collections (`notes`, `bookmarks`, etc.) that each ship a `hello-<type>.md` starter — those are h-entry post types meant to show format-by-example on a fresh scaffold; `blogroll`, like `members`, is a directory-style collection the owner populates with their own real entries, so a fake placeholder blogroll link isn't warranted.

Run: `cd Resources/Template && npx astro sync && npx astro check` (or the project's existing type-check script — check `package.json`'s `scripts` for the right command, e.g. `npm run typecheck`)
Expected: no schema errors; `astro sync` regenerates `.astro/content.d.ts` including the new `blogroll` collection, with zero entries (same as `members` today).

- [ ] **Step 3: Commit**

```bash
git add Resources/Template/src/content.config.ts
git commit -m "feat(#1483): add blogroll Astro content collection"
```

---

### Task 3: Render the `/blogroll/` page

**Files:**
- Create: `Resources/Template/src/pages/blogroll/index.astro`
- Test: covered by the template's build (Task 2's `astro check`); add a scaffold content fixture for manual verification during Task 16 (badge wiring) rather than here, since there's no existing per-page Astro component test convention in this template (pages are verified via `astro build`/`astro check`, not `node:test` — confirmed by `Resources/Template/src/pages/bookmarks/index.astro` having no sibling test file).

**Interfaces:**
- Consumes: `getCollection`/`render` from `astro:content` (the `render(entry)` → `{ Content }` pattern `Resources/Template/src/lib/collection-index-astro.ts` lines 74-78 and `Resources/Template/src/components/IndexEntry.astro` line 18/49 already use to inline an entry's markdown body — needed here since the spec requires rendering each entry's `note`, not just its frontmatter), `BaseLayout` from `../../layouts/BaseLayout.astro`.
- Produces: the `/blogroll/` route, listing every entry sorted by `addedDate` descending, each with its `name`/`url`/rendered `note` body.

- [ ] **Step 1: Write the page**

`blogroll` isn't an h-feed of dated posts like `bookmarks`/`notes` — it doesn't fit `CollectionIndex.astro`'s `FEED_COLLECTIONS`-driven `IndexEntry` rendering (Task 2 deliberately did not register `blogroll` in `FEED_COLLECTIONS`, so `CollectionIndex` would throw its `"no feed config"` error). Write a bespoke page instead, calling `render()` directly per entry the same way `collection-index-astro.ts`'s `withContent` does, so each entry's `note` (markdown body, per Task 1 — `note` is the file's body, not a frontmatter field) actually renders, matching the spec's "name, url, note" requirement:

```astro
---
import { getCollection, render } from "astro:content";
import BaseLayout from "../../layouts/BaseLayout.astro";

const sorted = (await getCollection("blogroll")).sort(
  (a, b) => b.data.addedDate.valueOf() - a.data.addedDate.valueOf()
);
const entries = await Promise.all(
  sorted.map(async (entry) => {
    const { Content } = await render(entry);
    return { data: entry.data, Content };
  }),
);
---

<BaseLayout title="Blogroll" description="Sites I follow and recommend.">
  <h1>Blogroll</h1>
  {
    entries.length === 0 ? (
      <p>
        No blogroll entries yet. Add a Markdown file in <code>src/content/blogroll/</code> to get started.
      </p>
    ) : (
      <ul>
        {entries.map(({ data, Content }) => (
          <li class="h-card">
            <a class="p-name u-url" href={data.url}>{data.name}</a>
            <div class="p-note">
              <Content />
            </div>
          </li>
        ))}
      </ul>
    )
  }
</BaseLayout>
```

Each `<li>` carries the `h-card`/`p-name`/`u-url`/`p-note` microformat classes declared in Task 1's `ContentTypeProjections` — one card per blogroll entry, not one card for the page as a whole. There's no per-entry permalink page in v1 (see Task 5's exclusion rationale — a `/blogroll/<slug>/` route doesn't exist), so this index page is the only place these classes appear.

- [ ] **Step 2: Verify it builds**

Add a fixture entry temporarily: `Resources/Template/src/content/blogroll/example.md`:

```markdown
---
name: Example Blog
url: https://example.com
addedDate: 2026-08-01
---
A great blog about examples.
```

Run: `cd Resources/Template && npm run build` (or the project's dev-server preview command)
Expected: build succeeds; `/blogroll/` output lists "Example Blog" linking to `https://example.com`, with "A great blog about examples." rendered as its note.

Remove the fixture afterward (`rm Resources/Template/src/content/blogroll/example.md`) — it was only for manual verification, not a committed fixture.

- [ ] **Step 3: Commit**

```bash
git add Resources/Template/src/pages/blogroll/index.astro
git commit -m "feat(#1483): render the /blogroll/ page"
```

---

## Part B — atproto subscription publishing

### Task 4: `BlogrollPlan` — network-free planning for blogroll entries

**Files:**
- Create: `Sources/AnglesiteCore/BlogrollPlan.swift`
- Test: `Tests/AnglesiteCoreTests/BlogrollPlanTests.swift`

**Interfaces:**
- Consumes: `Frontmatter.parse(_:)` / `Frontmatter.body(_:)` (`Sources/AnglesiteCore/Frontmatter.swift`), same file-reading pattern as `StandardSiteDocumentPlan.build`.
- Produces:
  ```swift
  public enum BlogrollPlan {
      public struct Entry: Equatable, Sendable {
          public let sourceFile: String   // project-relative POSIX path, e.g. "src/content/blogroll/example.md"
          public let name: String
          public let url: URL
          public let feedURL: URL?
      }
      public struct Plan: Equatable, Sendable {
          public let entries: [Entry]
      }
      public static func build(projectRoot: URL) -> Plan
  }
  ```
  `entries` sorted by `sourceFile` for stable output (matches `StandardSiteDocumentPlan`'s convention). An entry with a missing/invalid `name` or `url` is skipped (never partially constructed) — mirrors `StandardSiteDocumentPlan.build`'s `compactMap` pattern.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
import AnglesiteTestSupport
@testable import AnglesiteCore

@Suite("Blogroll plan")
struct BlogrollPlanTests {
    @Test("builds one entry per blogroll file, skipping malformed entries")
    func buildsEntries() throws {
        let root = try writeSiteTree(prefix: "blogroll-plan", [
            "src/content/blogroll/friend.md": """
            ---
            name: Friend's Blog
            url: https://friend.example
            addedDate: 2026-08-01
            ---
            A friend's blog.
            """,
            "src/content/blogroll/with-feed.md": """
            ---
            name: Has A Feed
            url: https://hasafeed.example
            feedURL: https://hasafeed.example/feed.xml
            addedDate: 2026-08-02
            ---
            """,
            "src/content/blogroll/malformed.md": """
            ---
            addedDate: 2026-08-03
            ---
            Missing name and url.
            """,
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let plan = BlogrollPlan.build(projectRoot: root)
        #expect(plan.entries.count == 2)

        let friend = try #require(plan.entries.first { $0.sourceFile.contains("friend.md") })
        #expect(friend.name == "Friend's Blog")
        #expect(friend.url == URL(string: "https://friend.example"))
        #expect(friend.feedURL == nil)

        let withFeed = try #require(plan.entries.first { $0.sourceFile.contains("with-feed.md") })
        #expect(withFeed.feedURL == URL(string: "https://hasafeed.example/feed.xml"))
    }

    @Test("entries are sorted by source file for stable output")
    func sortedOutput() throws {
        let root = try writeSiteTree(prefix: "blogroll-plan", [
            "src/content/blogroll/zzz.md": "---\nname: Z\nurl: https://z.example\naddedDate: 2026-08-01\n---\n",
            "src/content/blogroll/aaa.md": "---\nname: A\nurl: https://a.example\naddedDate: 2026-08-01\n---\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let plan = BlogrollPlan.build(projectRoot: root)
        #expect(plan.entries.map(\.sourceFile).first?.contains("aaa.md") == true)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path . --filter BlogrollPlanTests`
Expected: FAIL — `BlogrollPlan` doesn't exist.

- [ ] **Step 3: Implement `BlogrollPlan`**

```swift
import Foundation

/// Network-free planning for blogroll entries: enumerates `src/content/blogroll/` (only —
/// unlike ``StandardSiteDocumentPlan``, this never walks the whole content tree, since blogroll
/// entries are not documents; see that type's exclusion of this same collection).
public enum BlogrollPlan {
    /// One blogroll entry ready for graph-record resolution.
    public struct Entry: Equatable, Sendable {
        /// Project-relative POSIX path of the source markdown file.
        public let sourceFile: String
        public let name: String
        public let url: URL
        /// Already-set `feedURL` frontmatter, if the owner supplied one or a prior deploy's
        /// discovery pass wrote one back. `nil` means discovery should still be attempted.
        public let feedURL: URL?

        public init(sourceFile: String, name: String, url: URL, feedURL: URL?) {
            self.sourceFile = sourceFile
            self.name = name
            self.url = url
            self.feedURL = feedURL
        }
    }

    public struct Plan: Equatable, Sendable {
        public let entries: [Entry]
        public init(entries: [Entry]) { self.entries = entries }
    }

    /// Builds the blogroll plan for a site's Astro project root (`Source/`).
    public static func build(projectRoot: URL) -> Plan {
        let blogrollRoot = projectRoot.appendingPathComponent("src/content/blogroll", isDirectory: true)
        let files = SocialPublishPlan.walk(blogrollRoot)
            .filter { SocialPublishPlan.entryExtensions.contains($0.pathExtension.lowercased()) }
        let entries = files.compactMap { file -> Entry? in
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            let frontmatter = Frontmatter.parse(source)
            guard let name = SocialPublishPlan.string(frontmatter["name"]), !name.isEmpty else { return nil }
            guard let urlString = SocialPublishPlan.string(frontmatter["url"]), let url = URL(string: urlString) else {
                return nil
            }
            let feedURL = SocialPublishPlan.string(frontmatter["feedURL"]).flatMap(URL.init(string:))
            let relPath = SocialPublishPlan.relativePosix(file, from: projectRoot)
            return Entry(sourceFile: relPath, name: name, url: url, feedURL: feedURL)
        }
        return Plan(entries: entries.sorted { $0.sourceFile < $1.sourceFile })
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path . --filter BlogrollPlanTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/BlogrollPlan.swift Tests/AnglesiteCoreTests/BlogrollPlanTests.swift
git commit -m "feat(#1483): add BlogrollPlan for network-free blogroll planning"
```

---

### Task 5: Exclude `blogroll` from `StandardSiteDocumentPlan`

**Why this task exists:** `StandardSiteDocumentPlan.build` (`Sources/AnglesiteCore/StandardSiteDocumentPlan.swift`) walks *all* of `src/content` with no collection allowlist. Without this fix, adding the `blogroll` collection (Task 2) would make the existing increment-1 pass publish a spurious `site.standard.document` record for every blogroll entry, claiming a canonical URL (`/blogroll/<slug>/`) that doesn't resolve to a real page (Task 3 only builds one `/blogroll/` index page, not per-entry permalinks). This is a required correctness fix for this feature, not a drive-by refactor.

**Files:**
- Modify: `Sources/AnglesiteCore/StandardSiteDocumentPlan.swift` (`documentPath(for:frontmatter:)`, lines 112-122)
- Modify: `Tests/AnglesiteCoreTests/StandardSitePublishTests.swift` (`StandardSiteDocumentPlanTests`, add a regression test after line 149)

**Interfaces:**
- No public signature changes — `StandardSiteDocumentPlan.build` and `documentPath` keep their existing shapes; only the filtering logic changes.

- [ ] **Step 1: Write the failing regression test**

In `Tests/AnglesiteCoreTests/StandardSitePublishTests.swift`, insert after `buildsEligibleEntries()` (after line 149, before `fallbackTitle`):

```swift

    @Test("excludes the blogroll collection — those entries aren't documents")
    func excludesBlogroll() throws {
        let root = try writeSiteTree(prefix: "standardsite-plan", [
            "src/content/notes/hello.md": """
            ---
            title: Hello World
            publishDate: 2026-06-29
            ---
            Body text.
            """,
            "src/content/blogroll/friend.md": """
            ---
            name: Friend's Blog
            url: https://friend.example
            addedDate: 2026-06-29
            ---
            A friend's blog.
            """,
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let plan = StandardSiteDocumentPlan.build(projectRoot: root, referenceDate: referenceDate)
        #expect(plan.entries.count == 1)
        #expect(plan.entries.first?.path == "/notes/hello/")
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path . --filter StandardSiteDocumentPlanTests`
Expected: FAIL — `plan.entries.count == 2` (the blogroll entry is currently included).

- [ ] **Step 3: Add the exclusion**

In `Sources/AnglesiteCore/StandardSiteDocumentPlan.swift`, change `documentPath(for:frontmatter:)` (lines 112-122) from:

```swift
    private static func documentPath(for relPath: String, frontmatter: [String: FrontmatterValue]) -> String? {
        let parts = relPath.split(separator: "/").map(String.init)
        guard parts.count >= 4, parts[0] == "src", parts[1] == "content" else { return nil }
        let collection = parts[2]
        let collectionRelParts = Array(parts.dropFirst(3))
        guard let lastPart = collectionRelParts.last else { return nil }
        let fallbackSlug = (collectionRelParts.dropLast() + [basenameWithoutExtension(lastPart)])
            .joined(separator: "/")
        let slug = SocialPublishPlan.string(frontmatter["slug"]) ?? fallbackSlug
        return "/\(collection)/\(slug)/"
    }
```

to:

```swift
    /// Collections whose entries are never Standard.site documents. `blogroll` (#1483) entries
    /// describe sites the owner follows, not content the owner authored at a canonical path —
    /// they're published as `site.standard.graph.subscription` records instead, by
    /// `StandardSiteGraphPublishCommand`.
    private static let nonDocumentCollections: Set<String> = ["blogroll"]

    private static func documentPath(for relPath: String, frontmatter: [String: FrontmatterValue]) -> String? {
        let parts = relPath.split(separator: "/").map(String.init)
        guard parts.count >= 4, parts[0] == "src", parts[1] == "content" else { return nil }
        let collection = parts[2]
        guard !nonDocumentCollections.contains(collection) else { return nil }
        let collectionRelParts = Array(parts.dropFirst(3))
        guard let lastPart = collectionRelParts.last else { return nil }
        let fallbackSlug = (collectionRelParts.dropLast() + [basenameWithoutExtension(lastPart)])
            .joined(separator: "/")
        let slug = SocialPublishPlan.string(frontmatter["slug"]) ?? fallbackSlug
        return "/\(collection)/\(slug)/"
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path . --filter StandardSiteDocumentPlanTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/StandardSiteDocumentPlan.swift Tests/AnglesiteCoreTests/StandardSitePublishTests.swift
git commit -m "fix(#1483): exclude blogroll entries from Standard.site document plan"
```

---

### Task 6: `StandardSiteGraphRecords` — the subscription record type

**Files:**
- Create: `Sources/AnglesiteCore/StandardSiteGraphRecords.swift`
- Test: `Tests/AnglesiteCoreTests/StandardSiteGraphPublishTests.swift` (new file — will also hold Tasks 7-9's tests)

**Interfaces:**
- Produces:
  ```swift
  public struct StandardSiteGraphSubscriptionRecord: Encodable, Equatable, Sendable {
      public let publication: String  // at-URI of the followed site.standard.publication
      public let createdAt: String    // ISO 8601
      public init(publication: String, createdAt: String)
  }
  ```

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import AnglesiteCore

@Suite("Standard.site graph records")
struct StandardSiteGraphRecordsTests {
    @Test("subscription record carries the lexicon's $type and fields")
    func recordShape() throws {
        let record = StandardSiteGraphSubscriptionRecord(
            publication: "at://did:plc:friend/site.standard.publication/anglesite-abc",
            createdAt: "2026-08-15T00:00:00Z"
        )
        let data = try JSONEncoder().encode(record)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["$type"] as? String == "site.standard.graph.subscription")
        #expect(object["publication"] as? String == "at://did:plc:friend/site.standard.publication/anglesite-abc")
        #expect(object["createdAt"] as? String == "2026-08-15T00:00:00Z")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path . --filter StandardSiteGraphRecordsTests`
Expected: FAIL — type doesn't exist.

- [ ] **Step 3: Implement the record type**

```swift
import Foundation

/// `site.standard.graph.subscription` record — one per followed publication, written into the
/// owner's own PDS repo. See https://standard.site/docs/lexicons/subscription/.
///
/// Unlike ``StandardSitePublicationRecord``/``StandardSiteDocumentRecord``, this lexicon has no
/// grapheme-limited text fields — `publication` is an at-URI, `createdAt` a timestamp — so there
/// is no truncation-at-construction step here.
public struct StandardSiteGraphSubscriptionRecord: Encodable, Equatable, Sendable {
    let type = "site.standard.graph.subscription"
    /// The followed site's `site.standard.publication` at-URI, resolved from its
    /// `/.well-known/site.standard.publication` (``StandardSitePublicationResolver``).
    public let publication: String
    /// ISO 8601 timestamp string.
    public let createdAt: String

    enum CodingKeys: String, CodingKey {
        case type = "$type"
        case publication, createdAt
    }

    public init(publication: String, createdAt: String) {
        self.publication = publication
        self.createdAt = createdAt
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path . --filter StandardSiteGraphRecordsTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/StandardSiteGraphRecords.swift Tests/AnglesiteCoreTests/StandardSiteGraphPublishTests.swift
git commit -m "feat(#1483): add site.standard.graph.subscription record type"
```

---

### Task 7: `StandardSitePublicationResolver` — resolve a target's publication at-URI

**Files:**
- Create: `Sources/AnglesiteCore/StandardSitePublicationResolver.swift`
- Test: append to `Tests/AnglesiteCoreTests/StandardSiteGraphPublishTests.swift`

**Interfaces:**
- Consumes: `POSSEHTTPTransport` (`Sources/AnglesiteCore/POSSEClients.swift` line 10 — `@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)`, already transport-agnostic despite its name).
- Produces:
  ```swift
  public enum StandardSitePublicationResolver {
      /// `nil` means the target has no (or a malformed) site.standard.publication well-known file
      /// — not an error, matching WebmentionEndpointDiscovery's "no endpoint" convention.
      public static func resolve(homepage: URL, transport: POSSEHTTPTransport) async -> String?
  }
  ```

- [ ] **Step 1: Write the failing tests**

Append to `Tests/AnglesiteCoreTests/StandardSiteGraphPublishTests.swift`:

```swift

@Suite("Standard.site publication resolver")
struct StandardSitePublicationResolverTests {
    private func transport(status: Int, body: String) -> POSSEHTTPTransport {
        { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            return (Data(body.utf8), response)
        }
    }

    @Test("resolves a well-formed at-URI from the target's well-known file")
    func resolves() async throws {
        let uri = "at://did:plc:friend/site.standard.publication/anglesite-abc"
        let resolved = await StandardSitePublicationResolver.resolve(
            homepage: URL(string: "https://friend.example")!,
            transport: transport(status: 200, body: "\(uri)\n")
        )
        #expect(resolved == uri)
    }

    @Test("requests the well-known path at the homepage's host")
    func requestsCorrectPath() async throws {
        actor Capture { var url: URL?; func set(_ u: URL?) { url = u } }
        let capture = Capture()
        _ = await StandardSitePublicationResolver.resolve(
            homepage: URL(string: "https://friend.example/some/path")!,
            transport: { request in
                await capture.set(request.url)
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            }
        )
        let requested = await capture.url
        #expect(requested?.absoluteString == "https://friend.example/.well-known/site.standard.publication")
    }

    @Test("returns nil on 404 — target doesn't run standard.site")
    func returnsNilOn404() async throws {
        let resolved = await StandardSitePublicationResolver.resolve(
            homepage: URL(string: "https://plain.example")!,
            transport: transport(status: 404, body: "")
        )
        #expect(resolved == nil)
    }

    @Test("returns nil for a malformed body")
    func returnsNilForMalformedBody() async throws {
        let resolved = await StandardSitePublicationResolver.resolve(
            homepage: URL(string: "https://weird.example")!,
            transport: transport(status: 200, body: "not-an-at-uri\n")
        )
        #expect(resolved == nil)
    }

    @Test("returns nil when the transport throws")
    func returnsNilOnTransportError() async throws {
        struct Boom: Error {}
        let resolved = await StandardSitePublicationResolver.resolve(
            homepage: URL(string: "https://unreachable.example")!,
            transport: { _ in throw Boom() }
        )
        #expect(resolved == nil)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path . --filter StandardSitePublicationResolverTests`
Expected: FAIL — type doesn't exist.

- [ ] **Step 3: Implement the resolver**

```swift
import Foundation

/// Resolves a blogroll target's `site.standard.publication` at-URI by fetching *their*
/// `/.well-known/site.standard.publication` — the reverse direction of the verification
/// `Resources/Template/scripts/edge-artifacts.ts`'s `applyStandardSitePublicationPlan` emits for
/// this app's own site. `nil` is the expected, common outcome (most blogroll targets don't run
/// standard.site) — never thrown as an error.
public enum StandardSitePublicationResolver {
    /// Matches `at://<did>/site.standard.publication/<rkey>` — same shape check as the
    /// template's `isStandardSitePublicationURI`.
    private static let publicationURIPattern: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: #"^at://[^/]+/site\.standard\.publication/[^/\s]+$"#)
        } catch {
            fatalError("Invalid standard.site publication URI regex: \(error)")
        }
    }()

    public static func resolve(homepage: URL, transport: POSSEHTTPTransport) async -> String? {
        guard let host = homepage.host else { return nil }
        var components = URLComponents()
        components.scheme = homepage.scheme ?? "https"
        components.host = host
        components.port = homepage.port
        components.path = "/.well-known/site.standard.publication"
        guard let wellKnownURL = components.url else { return nil }

        let request = URLRequest(url: wellKnownURL)
        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await transport(request)
        } catch {
            return nil
        }
        guard (200..<300).contains(http.statusCode) else { return nil }
        let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        guard publicationURIPattern.firstMatch(in: body, range: range) != nil else { return nil }
        return body
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path . --filter StandardSitePublicationResolverTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/StandardSitePublicationResolver.swift Tests/AnglesiteCoreTests/StandardSiteGraphPublishTests.swift
git commit -m "feat(#1483): resolve blogroll targets' publication at-URI"
```

---

### Task 8: `StandardSiteGraphPublishLog` — the ledger

**Files:**
- Create: `Sources/AnglesiteCore/StandardSiteGraphPublishLog.swift`
- Test: append to `Tests/AnglesiteCoreTests/StandardSiteGraphPublishTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct StandardSiteGraphPublishLog: Equatable, Sendable {
      public struct Entry: Codable, Equatable, Sendable {
          public let sourceFile: String  // BlogrollPlan.Entry.sourceFile — the dedup/diff key
          public let uri: String         // published subscription record's at-URI
          public let lastPublishedAt: Date
          public init(sourceFile: String, uri: String, lastPublishedAt: Date)
      }
      public static let filename = "standard-site-graph-publish.json"
      public var entries: [Entry]
      public init(entries: [Entry] = [])
      public static func load(from configDirectory: URL) -> StandardSiteGraphPublishLog?
      public func save(to configDirectory: URL) throws
      public mutating func record(_ entry: Entry)  // dedups on sourceFile
  }
  ```

- [ ] **Step 1: Write the failing tests**

Append to `Tests/AnglesiteCoreTests/StandardSiteGraphPublishTests.swift`:

```swift

@Suite("Standard.site graph publish log")
struct StandardSiteGraphPublishLogTests {
    @Test("round-trips through save/load")
    func roundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }

        var log = StandardSiteGraphPublishLog()
        log.record(.init(
            sourceFile: "src/content/blogroll/friend.md",
            uri: "at://did:plc:owner/site.standard.graph.subscription/anglesite-xyz",
            lastPublishedAt: Date(timeIntervalSince1970: 1_755_000_000)
        ))
        try log.save(to: dir)

        let loaded = try #require(StandardSiteGraphPublishLog.load(from: dir))
        #expect(loaded.entries.count == 1)
        #expect(loaded.entries.first?.sourceFile == "src/content/blogroll/friend.md")
    }

    @Test("record(_:) replaces an existing entry with the same sourceFile")
    func recordDedupsBySourceFile() {
        var log = StandardSiteGraphPublishLog()
        log.record(.init(sourceFile: "a.md", uri: "at://one", lastPublishedAt: Date()))
        log.record(.init(sourceFile: "a.md", uri: "at://two", lastPublishedAt: Date()))
        #expect(log.entries.count == 1)
        #expect(log.entries.first?.uri == "at://two")
    }

    @Test("load returns nil when no file exists yet")
    func loadReturnsNilWhenMissing() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(StandardSiteGraphPublishLog.load(from: dir) == nil)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path . --filter StandardSiteGraphPublishLogTests`
Expected: FAIL — type doesn't exist.

- [ ] **Step 3: Implement the ledger**

```swift
import Foundation

/// Ledger for ``StandardSiteGraphPublishCommand``, mirroring ``StandardSitePublishLog``'s shape.
/// Lives in the site's `Config/` directory (app-owned state, not the site's git repo). Keyed on
/// `sourceFile` (a blogroll entry's content-file path), not `path`, since blogroll entries have
/// no routed canonical page the way a post's `path` does.
public struct StandardSiteGraphPublishLog: Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let sourceFile: String
        public let uri: String
        public let lastPublishedAt: Date

        public init(sourceFile: String, uri: String, lastPublishedAt: Date) {
            self.sourceFile = sourceFile
            self.uri = uri
            self.lastPublishedAt = lastPublishedAt
        }
    }

    public static let filename = "standard-site-graph-publish.json"
    public var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    private struct Envelope: Codable { let entries: [Entry] }

    public static func load(from configDirectory: URL) -> StandardSiteGraphPublishLog? {
        guard let data = try? Data(contentsOf: configDirectory.appendingPathComponent(filename)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else { return nil }
        return StandardSiteGraphPublishLog(entries: envelope.entries)
    }

    public func save(to configDirectory: URL) throws {
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Envelope(entries: entries))
        try data.write(to: configDirectory.appendingPathComponent(Self.filename), options: .atomic)
    }

    public mutating func record(_ entry: Entry) {
        if let index = entries.firstIndex(where: { $0.sourceFile == entry.sourceFile }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path . --filter StandardSiteGraphPublishLogTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/StandardSiteGraphPublishLog.swift Tests/AnglesiteCoreTests/StandardSiteGraphPublishTests.swift
git commit -m "feat(#1483): add StandardSiteGraphPublishLog ledger"
```

---

### Task 9: `StandardSiteGraphPublishCommand` — the post-deploy pass

**Files:**
- Create: `Sources/AnglesiteCore/StandardSiteGraphPublishCommand.swift`
- Test: append to `Tests/AnglesiteCoreTests/StandardSiteGraphPublishTests.swift`

**Interfaces:**
- Consumes: `BlogrollPlan.build` (Task 4), `StandardSitePublicationResolver.resolve` (Task 7), `StandardSiteGraphSubscriptionRecord` (Task 6), `StandardSiteGraphPublishLog` (Task 8), `AtprotoPutRecordClient.{createSession,putRecord,deleteRecord}` (`Sources/AnglesiteCore/POSSEClients.swift` lines 295-398), `POSSEStableKey.make` (`POSSEClients.swift` line ~484), `SiteConfigStore`, `POSSECredentialResolver.Provider`, `LogCenter`.
- Produces:
  ```swift
  public actor StandardSiteGraphPublishCommand {
      public init(
          credentials: @escaping POSSECredentialResolver.Provider = POSSECredentialResolver.provider(),
          transport: @escaping POSSEHTTPTransport = POSSESyndicationCommand.defaultTransport,
          logCenter: LogCenter = .shared,
          now: @escaping @Sendable () -> Date = { Date.now }
      )
      public func publish(siteID: String, siteDirectory: URL, configDirectory: URL) async
  }
  ```

**Note on scope:** this task publishes subscription records only. Feed discovery and frontmatter write-back (the reason `BlogrollPlan.Entry.feedURL` matters beyond "already set") are added in Task 14, once Tasks 11-13 build the discovery/write-back pieces this command will call into. For this task, an entry's `feedURL` is read but not yet discovered — it's simply unused until Task 14.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/AnglesiteCoreTests/StandardSiteGraphPublishTests.swift`. This reuses the `APIStub` pattern from `StandardSitePublishCommandTests` (`Tests/AnglesiteCoreTests/StandardSitePublishTests.swift` lines 189-250) — since that `APIStub` is `private` to its own suite, declare a small local equivalent scoped to this suite rather than trying to share it across files:

```swift

@Suite("Standard.site graph publish pass")
struct StandardSiteGraphPublishCommandTests {
    private actor APIStub {
        var requests: [URLRequest] = []
        let did: String
        var wellKnownResponses: [String: (status: Int, body: String)] = [:]
        var deleteRecordStatus: Int = 200

        init(did: String = "did:plc:owner") { self.did = did }

        func respond(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            let url = request.url ?? URL(string: "https://invalid.example")!
            if url.path == "/.well-known/site.standard.publication" {
                let match = wellKnownResponses[url.host ?? ""] ?? (404, "")
                return (Data(match.body.utf8), HTTPURLResponse(url: url, statusCode: match.status, httpVersion: nil, headerFields: nil)!)
            }
            switch url.path {
            case "/xrpc/com.atproto.server.createSession":
                return json(#"{"accessJwt":"jwt","did":"\#(did)"}"#, url: url)
            case "/xrpc/com.atproto.repo.putRecord":
                let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
                let collection = body?["collection"] as? String ?? "unknown"
                let rkey = body?["rkey"] as? String ?? "unknown"
                return json(#"{"uri":"at://\#(did)/\#(collection)/\#(rkey)","cid":"bafycid"}"#, url: url)
            case "/xrpc/com.atproto.repo.deleteRecord":
                return json("{}", url: url, statusCode: deleteRecordStatus)
            default:
                return json("{}", url: url)
            }
        }

        private func json(_ body: String, url: URL, statusCode: Int = 200) -> (Data, HTTPURLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
        }

        func set(wellKnown host: String, status: Int, body: String) { wellKnownResponses[host] = (status, body) }
        func count(path: String) -> Int { requests.count { $0.url?.path == path } }
        func bodies(path: String) -> [[String: Any]] {
            requests.filter { $0.url?.path == path }.compactMap {
                guard let data = $0.httpBody else { return nil }
                return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
        }
    }

    private var credentials: POSSECredentials {
        POSSECredentials(bluesky: .init(pdsURL: URL(string: "https://pds.example")!, identifier: "owner.test", appPassword: "secret-b"))
    }

    private func makeSite(siteURL: String? = "https://owner.example", blogroll: [String: String] = [:]) throws -> (root: URL, source: URL, config: URL) {
        var files: [String: String] = [:]
        for (name, content) in blogroll { files["Source/src/content/blogroll/\(name)"] = content }
        if let siteURL { files["Source/.site-config"] = "SITE_NAME=Owner Site\nSITE_URL=\(siteURL)\n" }
        let root = try writeSiteTree(prefix: "standardsitegraph-command", files)
        return (root, root.appendingPathComponent("Source"), root.appendingPathComponent("Config"))
    }

    @Test("no-ops without a Bluesky credential")
    func noopWithoutCredential() async throws {
        let site = try makeSite(blogroll: ["friend.md": "---\nname: Friend\nurl: https://friend.example\naddedDate: 2026-08-01\n---\n"])
        defer { try? FileManager.default.removeItem(at: site.root) }
        let stub = APIStub()
        let command = StandardSiteGraphPublishCommand(
            credentials: { _, _ in POSSECredentials() },
            transport: { try await stub.respond($0) }
        )
        await command.publish(siteID: "site-1", siteDirectory: site.source, configDirectory: site.config)
        #expect(await stub.count(path: "/xrpc/com.atproto.server.createSession") == 0)
    }

    @Test("publishes a subscription record when the target resolves")
    func publishesResolvedEntry() async throws {
        let site = try makeSite(blogroll: ["friend.md": "---\nname: Friend\nurl: https://friend.example\naddedDate: 2026-08-01\n---\n"])
        defer { try? FileManager.default.removeItem(at: site.root) }
        let stub = APIStub()
        await stub.set(wellKnown: "friend.example", status: 200, body: "at://did:plc:friend/site.standard.publication/anglesite-abc\n")
        let command = StandardSiteGraphPublishCommand(credentials: { _, _ in credentials }, transport: { try await stub.respond($0) })

        await command.publish(siteID: "site-1", siteDirectory: site.source, configDirectory: site.config)

        let putBodies = await stub.bodies(path: "/xrpc/com.atproto.repo.putRecord")
        let graphPuts = putBodies.filter { ($0["collection"] as? String) == "site.standard.graph.subscription" }
        #expect(graphPuts.count == 1)
        let record = graphPuts.first?["record"] as? [String: Any]
        #expect(record?["publication"] as? String == "at://did:plc:friend/site.standard.publication/anglesite-abc")

        let log = try #require(StandardSiteGraphPublishLog.load(from: site.config))
        #expect(log.entries.count == 1)
    }

    @Test("skips, without failing the pass, when the target has no standard.site well-known file")
    func skipsUnresolvedEntry() async throws {
        let site = try makeSite(blogroll: ["plain.md": "---\nname: Plain Site\nurl: https://plain.example\naddedDate: 2026-08-01\n---\n"])
        defer { try? FileManager.default.removeItem(at: site.root) }
        let stub = APIStub()
        let logCenter = LogCenter()
        let command = StandardSiteGraphPublishCommand(credentials: { _, _ in credentials }, transport: { try await stub.respond($0) }, logCenter: logCenter)

        await command.publish(siteID: "site-1", siteDirectory: site.source, configDirectory: site.config)

        let graphPuts = (await stub.bodies(path: "/xrpc/com.atproto.repo.putRecord"))
            .filter { ($0["collection"] as? String) == "site.standard.graph.subscription" }
        #expect(graphPuts.isEmpty)
        let lines = await logCenter.snapshot()
        #expect(lines.contains { $0.text.contains("skipped") && $0.text.contains("plain.example") })
    }

    @Test("unpublishes a removed entry's subscription record")
    func unpublishesRemovedEntry() async throws {
        let site = try makeSite(blogroll: [:])
        defer { try? FileManager.default.removeItem(at: site.root) }
        var log = StandardSiteGraphPublishLog()
        log.record(.init(
            sourceFile: "src/content/blogroll/gone.md",
            uri: "at://did:plc:owner/site.standard.graph.subscription/anglesite-old",
            lastPublishedAt: Date()
        ))
        try log.save(to: site.config)
        let stub = APIStub()
        let command = StandardSiteGraphPublishCommand(credentials: { _, _ in credentials }, transport: { try await stub.respond($0) })

        await command.publish(siteID: "site-1", siteDirectory: site.source, configDirectory: site.config)

        #expect(await stub.count(path: "/xrpc/com.atproto.repo.deleteRecord") == 1)
        let reloaded = try #require(StandardSiteGraphPublishLog.load(from: site.config))
        #expect(reloaded.entries.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path . --filter StandardSiteGraphPublishCommandTests`
Expected: FAIL — type doesn't exist.

- [ ] **Step 3: Implement the command**

```swift
import Foundation

/// Best-effort post-deploy pass that publishes `site.standard.graph.subscription` records for
/// the site's blogroll (#1483) — see
/// `docs/superpowers/specs/2026-08-15-blogroll-standard-site-graph-design.md`. Modeled directly
/// on ``StandardSitePublishCommand``: never throws into the deploy result, ledgers in `Config/`,
/// logs to the debug pane, per-site serialized.
///
/// Reuses the site's Bluesky POSSE credential — no credential, or no real deployed `SITE_URL`
/// yet, and the pass silently no-ops, matching ``StandardSitePublishCommand``.
public actor StandardSiteGraphPublishCommand {
    private struct InFlight {
        let id: UUID
        let task: Task<Void, Never>
    }

    private let credentials: POSSECredentialResolver.Provider
    private let transport: POSSEHTTPTransport
    private let logCenter: LogCenter
    private let now: @Sendable () -> Date
    private var inFlight: [String: InFlight] = [:]

    public init(
        credentials: @escaping POSSECredentialResolver.Provider = POSSECredentialResolver.provider(),
        transport: @escaping POSSEHTTPTransport = POSSESyndicationCommand.defaultTransport,
        logCenter: LogCenter = .shared,
        now: @escaping @Sendable () -> Date = { Date.now }
    ) {
        self.credentials = credentials
        self.transport = transport
        self.logCenter = logCenter
        self.now = now
    }

    public func publish(siteID: String, siteDirectory: URL, configDirectory: URL) async {
        let previous = inFlight[siteID]?.task
        let id = UUID()
        let task = Task<Void, Never> { [weak self] in
            _ = await previous?.value
            await self?.perform(siteID: siteID, siteDirectory: siteDirectory, configDirectory: configDirectory)
        }
        inFlight[siteID] = InFlight(id: id, task: task)
        await task.value
        if inFlight[siteID]?.id == id {
            inFlight[siteID] = nil
        }
    }

    private func perform(siteID: String, siteDirectory: URL, configDirectory: URL) async {
        let source = "standardsitegraph:\(siteID)"
        guard let bluesky = credentials(siteID, configDirectory).bluesky else { return }
        guard let siteURLString = DeployCoordinator.resolveSiteURL(siteDirectory: siteDirectory),
              siteURLString != "https://example.com"
        else { return }

        let settings = (try? SiteConfigStore.read(from: configDirectory)) ?? SiteSettings()
        guard settings.publishToAtmosphere ?? true else { return }

        let plan = BlogrollPlan.build(projectRoot: siteDirectory)
        var ledger = StandardSiteGraphPublishLog.load(from: configDirectory) ?? StandardSiteGraphPublishLog()

        // No early return on an empty plan: the owner may have just deleted their *last*
        // blogroll entry, in which case `plan.entries` is empty but the ledger still holds one
        // stale entry that the unpublish diff below must still clean up. An empty plan with an
        // empty ledger still pays for one `createSession` call it didn't strictly need — a minor
        // cost, not worth the risk of silently skipping unpublish on the last-entry-removed path
        // (this exact scenario is covered by the `unpublishesRemovedEntry` test in Step 1, which
        // calls `makeSite(blogroll: [:])` — an early return here would make that test fail).

        let session: AtprotoPutRecordClient.Session
        do {
            session = try await AtprotoPutRecordClient.createSession(credentials: bluesky, transport: transport)
        } catch {
            await logError("couldn't sign in to publish blogroll: \(error.localizedDescription)", source: source)
            return
        }

        var publishedCount = 0
        var skippedCount = 0
        var failedCount = 0

        for entry in plan.entries {
            guard let publicationURI = await StandardSitePublicationResolver.resolve(homepage: entry.url, transport: transport) else {
                skippedCount += 1
                await logCenter.append(
                    source: source, stream: .stdout,
                    text: "standardsitegraph: skipped \(entry.url.absoluteString) — no site.standard.publication found"
                )
                continue
            }

            let rkey = "anglesite-\(POSSEStableKey.make("\(siteID)\n\(entry.sourceFile)"))"
            let record = StandardSiteGraphSubscriptionRecord(publication: publicationURI, createdAt: iso8601(now()))
            do {
                let result = try await AtprotoPutRecordClient.putRecord(
                    collection: "site.standard.graph.subscription", rkey: rkey, record: record,
                    pdsURL: bluesky.pdsURL, session: session, transport: transport
                )
                ledger.record(.init(sourceFile: entry.sourceFile, uri: result.uri, lastPublishedAt: now()))
                try ledger.save(to: configDirectory)
                publishedCount += 1
                await logCenter.append(source: source, stream: .stdout, text: "standardsitegraph: published \(entry.sourceFile) as \(result.uri)")
            } catch {
                failedCount += 1
                await logError("couldn't publish \(entry.sourceFile): \(error.localizedDescription)", source: source)
            }
        }

        let currentSourceFiles = Set(plan.entries.map(\.sourceFile))
        let staleEntries = ledger.entries.filter { !currentSourceFiles.contains($0.sourceFile) }
        var unpublishedCount = 0
        for staleEntry in staleEntries {
            guard let rkey = staleEntry.uri.split(separator: "/").last else { continue }
            do {
                try await AtprotoPutRecordClient.deleteRecord(
                    collection: "site.standard.graph.subscription", rkey: String(rkey),
                    pdsURL: bluesky.pdsURL, session: session, transport: transport
                )
                ledger.entries.removeAll { $0.sourceFile == staleEntry.sourceFile }
                try ledger.save(to: configDirectory)
                unpublishedCount += 1
                await logCenter.append(source: source, stream: .stdout, text: "standardsitegraph: unpublished \(staleEntry.sourceFile)")
            } catch {
                failedCount += 1
                await logError("couldn't unpublish \(staleEntry.sourceFile): \(error.localizedDescription)", source: source)
            }
        }

        await logCenter.append(
            source: source, stream: .stdout,
            text: "standardsitegraph: done — published \(publishedCount), skipped \(skippedCount), "
                + "unpublished \(unpublishedCount), failed \(failedCount)"
        )
    }

    private func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func logError(_ message: String, source: String) async {
        await logCenter.append(source: source, stream: .stderr, text: "standardsitegraph: \(message)")
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path . --filter StandardSiteGraphPublishCommandTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/StandardSiteGraphPublishCommand.swift Tests/AnglesiteCoreTests/StandardSiteGraphPublishTests.swift
git commit -m "feat(#1483): add StandardSiteGraphPublishCommand post-deploy pass"
```

---

### Task 10: Wire the pass into `DeployCoordinator` and `DeployModel`

**Files:**
- Modify: `Sources/AnglesiteCore/OperationProgress.swift` (add a milestone constant, after line 68's `deployStandardSitePublishing`)
- Modify: `Sources/AnglesiteCore/DeployCoordinator.swift` (`runPostDeploySequencing`, lines 430-461)
- Modify: `Sources/AnglesiteCore/DeployCoordinatorTests.swift`'s `runPostDeploySequencing` suite (`Tests/AnglesiteCoreTests/DeployCoordinatorTests.swift`, lines 597-705 — six existing tests, all asserting an exact `recorder.calls` array that changes once a new milestone is unconditionally emitted)
- Modify: `Sources/AnglesiteApp/DeployModel.swift` (property at line 156, init default at line 200, call site at lines 1018-1059)

**Interfaces:**
- Produces: `OperationProgress.deployStandardSiteGraphPublishing`; `DeployCoordinator.runPostDeploySequencing` gains a `publishStandardSiteGraph: () async -> Void = {}` parameter, called immediately after `publishStandardSite()`.

- [ ] **Step 1: Update the six existing sequencing tests**

`Tests/AnglesiteCoreTests/DeployCoordinatorTests.swift` lines 597-705 contain six `@Test`s against `runPostDeploySequencing`, all using a `CallRecorder` (line 603-606) and asserting an exact `recorder.calls` array. Every test whose `onMilestone` records phase names (i.e. `{ progress in recorder.record("milestone:\(progress.phase)") }`, not the bare `{ _ in }` ones) must gain a new `"milestone:standardSiteGraphPublishing"` entry right after `"milestone:standardSitePublishing"`/its pass call. Update each:

`postDeploySequencingRunsInOrder` (line 608-625) — add `publishStandardSiteGraph: { recorder.record("standardsitegraph") }` to the call (after the `publishStandardSite:` argument, line 614), and change the expected array (line 618-624) to:
```swift
        #expect(recorder.calls == [
            "milestone:webmentions", "send",
            "milestone:standardSitePublishing", "standardsite",
            "milestone:standardSiteGraphPublishing", "standardsitegraph",
            "milestone:syndicating", "syndicate",
            "milestone:websubPing", "notify",
            "milestone:activityPubBackfill",
        ])
```

`postDeploySequencingRunsBothPassesRegardless` (line 627-638) — this one uses `onMilestone: { _ in }`, so no milestone strings appear in its array; just add `publishStandardSiteGraph: { recorder.record("standardsitegraph") }` to the call and update line 637's expected array to `["send", "standardsite", "standardsitegraph", "syndicate", "notify"]`.

`postDeploySequencingDefaultsStandardSiteToNoOp` (line 640-656) — doesn't pass `publishStandardSite` or `publishStandardSiteGraph` at all (both default to no-op); only the milestone array (line 649-655) changes, inserting `"milestone:standardSiteGraphPublishing"` after `"milestone:standardSitePublishing"`:
```swift
        #expect(recorder.calls == [
            "milestone:webmentions", "send",
            "milestone:standardSitePublishing",
            "milestone:standardSiteGraphPublishing",
            "milestone:syndicating", "syndicate",
            "milestone:websubPing", "notify",
            "milestone:activityPubBackfill",
        ])
```
Consider renaming this test to reflect it now also covers `publishStandardSiteGraph`'s default (e.g. `postDeploySequencingDefaultsStandardSitePassesToNoOp`) — optional, but keep the doc string accurate if you do.

`postDeploySequencingDefaultsNotifyToNoOp` (line 658-673) — same milestone-array insertion as above, after `"milestone:standardSitePublishing"` on line 668.

`postDeploySequencingRunsBackfillLast` (line 675-693) — add `publishStandardSiteGraph: { recorder.record("standardsitegraph") }` to the call (line 681-ish) and insert `"milestone:standardSiteGraphPublishing", "standardsitegraph",` into the expected array (line 686-692) after `"milestone:standardSitePublishing", "standardsite",`.

`postDeploySequencingDefaultsBackfillToNoOp` (line 695-704) — uses `onMilestone: { _ in }` and doesn't pass `publishStandardSite`/`publishStandardSiteGraph`; expected array (line 703) stays `["send", "syndicate"]` — no change needed here, since neither pass records anything observable.

- [ ] **Step 2: Run to verify the updated tests fail**

Run: `swift test --package-path . --filter DeployCoordinatorTests`
Expected: FAIL — `publishStandardSiteGraph` isn't a parameter of `runPostDeploySequencing` yet, so these edits won't even compile until Step 4/5 land. (This is the one case in this plan where "write the failing test" and "make it compile" happen together — the signature change is small enough that splitting it further would be artificial.)

- [ ] **Step 3: Add the milestone constant**

In `Sources/AnglesiteCore/OperationProgress.swift`, insert after `deployStandardSitePublishing`'s closing `)` (after line 68):

```swift
    /// Post-deploy: blogroll graph-record publish pass (see ``StandardSiteGraphPublishCommand``,
    /// #1483). Ordered immediately after the Standard.site document pass.
    static let deployStandardSiteGraphPublishing = OperationProgress(
        kind: .deploy, phase: "standardSiteGraphPublishing", label: "Publishing blogroll to the Atmosphere…"
    )
```

- [ ] **Step 4: Update `runPostDeploySequencing`**

In `Sources/AnglesiteCore/DeployCoordinator.swift`, change the signature (lines 430-449) by inserting a new parameter right after `publishStandardSite`:

```swift
        publishStandardSite: () async -> Void = {},
        /// Blogroll graph-record publish pass (#1483, see ``StandardSiteGraphPublishCommand``).
        /// Ordered immediately after the Standard.site document pass — both publish into the
        /// same PDS repo under the same session lifecycle family, and neither depends on the
        /// other's output. Callers without a blogroll pass configured pass a no-op; the command
        /// itself gates on credentials/`SITE_URL`/Settings the same way ``StandardSitePublishCommand``
        /// does, but always checks for stale ledger entries to unpublish even when the current
        /// blogroll is empty (deleting the *last* entry must still clean up its record).
        publishStandardSiteGraph: () async -> Void = {},
        syndicate: () async -> Void,
```

Then in the body (lines 450-461), insert after `await publishStandardSite()`:

```swift
        onMilestone(.deployStandardSitePublishing)
        await publishStandardSite()
        onMilestone(.deployStandardSiteGraphPublishing)
        await publishStandardSiteGraph()
        onMilestone(.deploySyndicating)
        await syndicate()
```

- [ ] **Step 5: Run to verify the DeployCoordinator tests pass**

Run: `swift test --package-path . --filter DeployCoordinatorTests`
Expected: PASS — all six updated tests from Step 1.

- [ ] **Step 6: Wire `DeployModel`**

In `Sources/AnglesiteApp/DeployModel.swift`:

Add a property after line 156 (`private let standardSitePublishCommand: StandardSitePublishCommand`):

```swift
    private let standardSiteGraphPublishCommand: StandardSiteGraphPublishCommand
```

Add an init parameter after line 200 (`standardSitePublishCommand: StandardSitePublishCommand = StandardSitePublishCommand(),`):

```swift
        standardSiteGraphPublishCommand: StandardSiteGraphPublishCommand = StandardSiteGraphPublishCommand(),
```

Assign it in the init body alongside the existing `self.standardSitePublishCommand = standardSitePublishCommand` line (find it near the other property assignments in the same initializer).

At the `runPostDeploySequencing` call site (lines 1018-1059), add a new argument right after the existing `publishStandardSite:` closure (lines 1026-1031):

```swift
                publishStandardSiteGraph: { [weak self] in
                    guard let self else { return }
                    await self.standardSiteGraphPublishCommand.publish(
                        siteID: siteID, siteDirectory: siteDirectory, configDirectory: configDirectory
                    )
                },
```

- [ ] **Step 7: Build the app target to verify it compiles**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: builds cleanly — this is the only task touching `AnglesiteApp`, which `swift test` alone doesn't compile.

- [ ] **Step 8: Commit**

```bash
git add Sources/AnglesiteCore/OperationProgress.swift Sources/AnglesiteCore/DeployCoordinator.swift Sources/AnglesiteApp/DeployModel.swift Tests/AnglesiteCoreTests/
git commit -m "feat(#1483): wire StandardSiteGraphPublishCommand into deploy sequencing"
```

---

## Part C — Feed discovery, frontmatter write-back, OPML, badge

### Task 11: Extract shared HTML link-scanning from `WebmentionEndpointDiscovery`

**Why this task exists:** `WebmentionEndpointDiscovery` (`Sources/AnglesiteCore/WebmentionEndpointDiscovery.swift`) already implements exactly the HTML-tag/attribute scanning `FeedEndpointDiscovery` (Task 12) needs, just matching a different `rel`. This extracts the reusable ~40% (tag-scan loop + attribute regex/value helpers) into a shared internal type, with zero behavior change to `WebmentionEndpointDiscovery` — its 13 existing tests must pass unmodified.

**Files:**
- Create: `Sources/AnglesiteCore/HTMLLinkAttributeScanning.swift`
- Modify: `Sources/AnglesiteCore/WebmentionEndpointDiscovery.swift` (replace its private tag/attribute helpers with calls into the new shared type)
- Test: `Tests/AnglesiteCoreTests/WebmentionEndpointDiscoveryTests.swift` must pass unchanged (regression, not new tests)

**Interfaces:**
- Produces:
  ```swift
  enum HTMLLinkAttributeScanning {
      /// Matches `<link ...>` and `<a ...>` tags in document order, returning each tag's raw
      /// attribute string (the part between the tag name and `>`).
      static func tagAttributeStrings(in html: String) -> [String]
      /// Extracts `name="value"`/`name='value'`/`name=value` from an HTML tag's attribute string
      /// or an HTTP Link-header parameter string.
      static func attributeValue(_ name: String, in source: String) -> String?
  }
  ```
  (internal, no access modifier — same visibility `Frontmatter`'s helpers use, since both call sites live in `AnglesiteCore`.)

- [ ] **Step 1: Extract the shared type**

Create `Sources/AnglesiteCore/HTMLLinkAttributeScanning.swift`:

```swift
import Foundation

/// Shared HTML `<link>`/`<a>` tag and attribute scanning, factored out of
/// `WebmentionEndpointDiscovery` (webmention.org endpoint discovery) so `FeedEndpointDiscovery`
/// (#1483, RSS/Atom feed discovery for the blogroll's OPML export) can reuse the same
/// subtle regex/attribute-parsing logic instead of duplicating it. Neither caller's `rel`/`type`
/// matching predicate lives here — only the generic "find tags, read an attribute" machinery.
enum HTMLLinkAttributeScanning {
    /// Matches `<link ...>` and `<a ...>` tags in document order.
    ///
    /// Known, accepted limitation: `[^>]*` truncates the tag at the first literal `>`, including
    /// one embedded inside a quoted attribute value (e.g. `href="/x?a=1>2"`). A correct HTML
    /// tokenizer would track quote state to know that `>` isn't a tag terminator there. This is a
    /// conscious won't-fix, not an oversight — a literal, unencoded `>` inside an attribute value
    /// is invalid per the URL spec (it must be percent-encoded as `%3E`) and vanishingly rare in
    /// real-world markup; handling it would mean replacing this regex scan with a full tokenizer
    /// for a case that essentially never occurs.
    private static let tagPattern: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: #"<(?:link|a)\b([^>]*)>"#, options: [.caseInsensitive])
        } catch {
            fatalError("Invalid HTML link-tag scan regex: \(error)")
        }
    }()

    /// Returns each matched tag's raw attribute string, in document order.
    static func tagAttributeStrings(in html: String) -> [String] {
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return tagPattern.matches(in: html, range: range).compactMap { match in
            guard let attrsRange = Range(match.range(at: 1), in: html) else { return nil }
            return String(html[attrsRange])
        }
    }

    /// Extracts `name="value"` / `name='value'` / `name=value` from an HTML tag's attribute
    /// string or an HTTP Link-header parameter string. The lookahead-free anchor
    /// `(?:^|[\s;<])` before `name` requires the name to start at the beginning of the source,
    /// or be preceded by whitespace, a `;` (Link-header parameter separator), or `<` — so a
    /// lookup for `rel` does not match inside a longer attribute name like `data-rel=`. (A
    /// plain `\b` word-boundary anchor does *not* achieve this: `-` is a non-word character, so
    /// `\brel\b` still matches the `rel` inside `data-rel=`.)
    static func attributeValue(_ name: String, in source: String) -> String? {
        let regex = attributeRegex(for: name)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = regex.firstMatch(in: source, range: range) else { return nil }
        for groupIndex in [2, 3, 4] {
            let group = match.range(at: groupIndex)
            if group.location != NSNotFound, let r = Range(group, in: source) {
                return String(source[r])
            }
        }
        return nil
    }

    private static func attributeRegex(for name: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(
                pattern: "(?:^|[\\s;<])\(name)\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+))",
                options: [.caseInsensitive]
            )
        } catch {
            fatalError("Invalid HTML attribute scan regex for \(name): \(error)")
        }
    }
}
```

- [ ] **Step 2: Rewrite `WebmentionEndpointDiscovery` to use it**

In `Sources/AnglesiteCore/WebmentionEndpointDiscovery.swift`, replace the `// MARK: HTML` section (lines 85-117, from `private static let tagPattern` through the end of `endpoint(fromHTML:relativeTo:)`) with:

```swift
    // MARK: HTML

    static func endpoint(fromHTML html: String, relativeTo baseURL: URL) -> URL? {
        for attrs in HTMLLinkAttributeScanning.tagAttributeStrings(in: html) {
            guard let rel = attributeValue("rel", in: attrs), isWebmentionRel(rel) else { continue }
            guard let href = attributeValue("href", in: attrs) else { continue }
            if let url = URL(string: href, relativeTo: baseURL)?.absoluteURL {
                return url
            }
        }
        return nil
    }
```

Then replace the `// MARK: Shared attribute/rel helpers` section's attribute-parsing plumbing (lines 133-170: `relRegex`, `hrefRegex`, `attributeRegex(for:)`, `attributeValue(_:in:)`) — keep `legacyWebmentionRels` and `isWebmentionRel(_:)` (lines 121-131) as-is, since those are webmention-specific — with a single forwarding helper:

```swift
    private static func attributeValue(_ name: String, in source: String) -> String? {
        HTMLLinkAttributeScanning.attributeValue(name, in: source)
    }
```

(The Link-header path, `endpoint(fromLinkHeader:relativeTo:)` at lines 46-58, already calls `attributeValue("rel", in: params)` — that call site is unchanged; only the helper's implementation now forwards to the shared type.)

- [ ] **Step 3: Run the existing webmention discovery tests — must pass unmodified**

Run: `swift test --package-path . --filter WebmentionEndpointDiscoveryTests`
Expected: PASS — all 13 existing tests, with zero test-file changes. This is the regression check: the refactor must be behavior-preserving.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteCore/HTMLLinkAttributeScanning.swift Sources/AnglesiteCore/WebmentionEndpointDiscovery.swift
git commit -m "refactor(#1483): extract shared HTML link scanning from webmention discovery"
```

---

### Task 12: `FeedEndpointDiscovery` — discover a target's RSS/Atom feed

**Files:**
- Create: `Sources/AnglesiteCore/FeedEndpointDiscovery.swift`
- Test: `Tests/AnglesiteCoreTests/FeedEndpointDiscoveryTests.swift`

**Interfaces:**
- Consumes: `HTMLLinkAttributeScanning` (Task 11), `POSSEHTTPTransport`.
- Produces:
  ```swift
  enum FeedEndpointDiscovery {
      /// `nil` means the target declares no RSS/Atom feed — not an error.
      static func discover(target: URL, transport: POSSEHTTPTransport) async throws -> URL?
  }
  ```
  (internal — only `StandardSiteGraphPublishCommand`, same module, calls it.)

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import AnglesiteCore

@Suite("Feed endpoint discovery")
struct FeedEndpointDiscoveryTests {
    private func transport(status: Int = 200, body: String, url: URL = URL(string: "https://target.example")!) -> POSSEHTTPTransport {
        { _ in (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!) }
    }

    @Test("discovers an RSS <link rel=alternate type=application/rss+xml>")
    func discoversRSS() async throws {
        let html = #"<html><head><link rel="alternate" type="application/rss+xml" href="/feed.xml"></head></html>"#
        let discovered = try await FeedEndpointDiscovery.discover(
            target: URL(string: "https://target.example")!, transport: transport(body: html)
        )
        #expect(discovered == URL(string: "https://target.example/feed.xml"))
    }

    @Test("discovers an Atom <link rel=alternate type=application/atom+xml>")
    func discoversAtom() async throws {
        let html = #"<link rel="alternate" type="application/atom+xml" href="https://target.example/atom.xml">"#
        let discovered = try await FeedEndpointDiscovery.discover(
            target: URL(string: "https://target.example")!, transport: transport(body: html)
        )
        #expect(discovered == URL(string: "https://target.example/atom.xml"))
    }

    @Test("first matching link in document order wins")
    func firstMatchWins() async throws {
        let html = """
        <link rel="alternate" type="application/rss+xml" href="/first.xml">
        <link rel="alternate" type="application/rss+xml" href="/second.xml">
        """
        let discovered = try await FeedEndpointDiscovery.discover(
            target: URL(string: "https://target.example")!, transport: transport(body: html)
        )
        #expect(discovered == URL(string: "https://target.example/first.xml"))
    }

    @Test("a non-feed alternate link is ignored")
    func ignoresNonFeedAlternate() async throws {
        let html = #"<link rel="alternate" type="text/html" href="/amp.html">"#
        let discovered = try await FeedEndpointDiscovery.discover(
            target: URL(string: "https://target.example")!, transport: transport(body: html)
        )
        #expect(discovered == nil)
    }

    @Test("no <link> at all returns nil, not an error")
    func returnsNilWhenAbsent() async throws {
        let discovered = try await FeedEndpointDiscovery.discover(
            target: URL(string: "https://target.example")!, transport: transport(body: "<html></html>")
        )
        #expect(discovered == nil)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path . --filter FeedEndpointDiscoveryTests`
Expected: FAIL — type doesn't exist.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Discovers a target URL's declared RSS/Atom feed for the blogroll's OPML export (#1483):
/// fetch the target once, scan its `<link>` elements in document order for the first
/// `rel="alternate"` with an RSS or Atom `type`. Shares its tag/attribute scanning with
/// `WebmentionEndpointDiscovery` via ``HTMLLinkAttributeScanning``.
enum FeedEndpointDiscovery {
    private static let feedTypes: Set<String> = ["application/rss+xml", "application/atom+xml"]

    static func discover(target: URL, transport: POSSEHTTPTransport) async throws -> URL? {
        var request = URLRequest(url: target)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (data, http) = try await transport(request)
        let finalURL = http.url ?? target
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }

        for attrs in HTMLLinkAttributeScanning.tagAttributeStrings(in: html) {
            guard let rel = HTMLLinkAttributeScanning.attributeValue("rel", in: attrs),
                  isAlternateRel(rel),
                  let type = HTMLLinkAttributeScanning.attributeValue("type", in: attrs),
                  feedTypes.contains(type.lowercased()),
                  let href = HTMLLinkAttributeScanning.attributeValue("href", in: attrs)
            else { continue }
            if let url = URL(string: href, relativeTo: finalURL)?.absoluteURL {
                return url
            }
        }
        return nil
    }

    private static func isAlternateRel(_ rel: String) -> Bool {
        rel.split(whereSeparator: { $0.isWhitespace }).contains { $0.caseInsensitiveCompare("alternate") == .orderedSame }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path . --filter FeedEndpointDiscoveryTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/FeedEndpointDiscovery.swift Tests/AnglesiteCoreTests/FeedEndpointDiscoveryTests.swift
git commit -m "feat(#1483): add FeedEndpointDiscovery for blogroll OPML export"
```

---

### Task 13: `BlogrollFeedFrontmatter` — write the discovered feed URL back

**Files:**
- Create: `Sources/AnglesiteCore/BlogrollFeedFrontmatter.swift`
- Test: `Tests/AnglesiteCoreTests/BlogrollFeedFrontmatterTests.swift`

**Interfaces:**
- Consumes: `Frontmatter.closingFenceIndex(of:)`, `Frontmatter.splitKeyValue(_:)`, `Frontmatter.doubleQuoted(_:)` (all `Sources/AnglesiteCore/Frontmatter.swift`, internal — same-module access from `BlogrollFeedFrontmatter.swift`).
- Produces:
  ```swift
  enum BlogrollFeedFrontmatter {
      /// Sets `feedURL:` in `contents`' frontmatter, only if the key is currently absent or its
      /// value is blank. Returns `contents` unchanged (no write, no diff) otherwise. Preserves
      /// CRLF line endings if present, mirroring `SyndicationFrontmatter`.
      static func setting(feedURL: String, in contents: String) -> String
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import AnglesiteCore

@Suite("Blogroll feed frontmatter")
struct BlogrollFeedFrontmatterTests {
    @Test("sets feedURL when the key is absent, inside an existing fence")
    func setsWhenAbsent() {
        let contents = """
        ---
        name: Friend's Blog
        url: https://friend.example
        addedDate: 2026-08-01
        ---
        A friend's blog.
        """
        let result = BlogrollFeedFrontmatter.setting(feedURL: "https://friend.example/feed.xml", in: contents)
        #expect(result.contains("feedURL: \"https://friend.example/feed.xml\""))
        #expect(result.contains("name: Friend's Blog"))
        #expect(result.contains("A friend's blog."))
    }

    @Test("synthesizes a fence when the file has none")
    func synthesizesFence() {
        let contents = "No frontmatter here."
        let result = BlogrollFeedFrontmatter.setting(feedURL: "https://x.example/feed.xml", in: contents)
        #expect(result.hasPrefix("---\n"))
        #expect(result.contains("feedURL: \"https://x.example/feed.xml\""))
        #expect(result.contains("No frontmatter here."))
    }

    @Test("is a no-op when feedURL is already set")
    func noopWhenAlreadySet() {
        let contents = """
        ---
        name: Friend's Blog
        url: https://friend.example
        feedURL: https://friend.example/already-set.xml
        addedDate: 2026-08-01
        ---
        Body.
        """
        let result = BlogrollFeedFrontmatter.setting(feedURL: "https://different.example/feed.xml", in: contents)
        #expect(result == contents)
    }

    @Test("replaces a blank feedURL value")
    func replacesBlankValue() {
        let contents = """
        ---
        name: Friend's Blog
        url: https://friend.example
        feedURL:
        addedDate: 2026-08-01
        ---
        Body.
        """
        let result = BlogrollFeedFrontmatter.setting(feedURL: "https://friend.example/feed.xml", in: contents)
        #expect(result.contains("feedURL: \"https://friend.example/feed.xml\""))
        #expect(!result.contains("feedURL:\n"))
    }

    @Test("preserves CRLF line endings")
    func preservesCRLF() {
        let contents = "---\r\nname: Friend\r\nurl: https://friend.example\r\naddedDate: 2026-08-01\r\n---\r\nBody.\r\n"
        let result = BlogrollFeedFrontmatter.setting(feedURL: "https://friend.example/feed.xml", in: contents)
        #expect(result.contains("\r\n"))
        #expect(!result.contains("feedURL: \"https://friend.example/feed.xml\"\n\n"))  // no stray LF introduced
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path . --filter BlogrollFeedFrontmatterTests`
Expected: FAIL — type doesn't exist.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Writes a discovered feed URL back into a blogroll entry's own `feedURL:` frontmatter
/// (#1483) — the single-scalar counterpart to `SyndicationFrontmatter.adding(urls:to:)`'s
/// list-splice, reusing the same `Frontmatter` primitives. Never overwrites a value the owner
/// (or a prior discovery pass) already set.
enum BlogrollFeedFrontmatter {
    static func setting(feedURL: String, in contents: String) -> String {
        let usesCRLF = contents.contains("\r\n")
        let normalized = usesCRLF ? contents.replacingOccurrences(of: "\r\n", with: "\n") : contents
        func finish(_ s: String) -> String {
            usesCRLF ? s.replacingOccurrences(of: "\n", with: "\r\n") : s
        }

        var lines = normalized.components(separatedBy: "\n")
        let newLine = "feedURL: \(Frontmatter.doubleQuoted(feedURL))"

        guard let closing = Frontmatter.closingFenceIndex(of: lines) else {
            let block = ["---", newLine, "---"]
            return finish((block + [normalized]).joined(separator: "\n"))
        }

        if let keyIndex = lines[..<closing].firstIndex(where: { Frontmatter.splitKeyValue($0)?.key == "feedURL" }) {
            let existingValue = Frontmatter.splitKeyValue(lines[keyIndex])?.value.trimmingCharacters(in: .whitespaces) ?? ""
            guard existingValue.isEmpty else { return contents }
            lines[keyIndex] = newLine
            return finish(lines.joined(separator: "\n"))
        }

        lines.insert(newLine, at: closing)
        return finish(lines.joined(separator: "\n"))
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path . --filter BlogrollFeedFrontmatterTests`
Expected: PASS. `Frontmatter.doubleQuoted` (`Sources/AnglesiteCore/Frontmatter.swift` lines 215-221) only escapes `\`, `"`, `\n`, `\r` — a plain `https://…` URL contains none of those, so it renders as exactly `"https://friend.example/feed.xml"` with no additional escaping, matching the test assertions above verbatim.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/BlogrollFeedFrontmatter.swift Tests/AnglesiteCoreTests/BlogrollFeedFrontmatterTests.swift
git commit -m "feat(#1483): write discovered blogroll feed URLs back to frontmatter"
```

---

### Task 14: Wire feed discovery and write-back into the graph publish pass

**Files:**
- Modify: `Sources/AnglesiteCore/StandardSiteGraphPublishCommand.swift` (Task 9's `perform`, per-entry loop)
- Modify: `Tests/AnglesiteCoreTests/StandardSiteGraphPublishTests.swift` (`StandardSiteGraphPublishCommandTests`, new tests)

**Interfaces:**
- Consumes: `FeedEndpointDiscovery.discover` (Task 12), `BlogrollFeedFrontmatter.setting(feedURL:in:)` (Task 13).
- No new public signatures — this extends `StandardSiteGraphPublishCommand.perform`'s existing per-entry loop.

- [ ] **Step 1: Write the failing tests**

Append to `StandardSiteGraphPublishCommandTests` in `Tests/AnglesiteCoreTests/StandardSiteGraphPublishTests.swift`. This needs the `APIStub` to also serve the entry's homepage GET (for feed discovery) — extend the stub's `respond` to return canned HTML for any non-well-known, non-XRPC path:

```swift

    @Test("discovers and writes back a feed URL when the entry has none")
    func discoversAndWritesBackFeedURL() async throws {
        let site = try makeSite(blogroll: ["friend.md": "---\nname: Friend\nurl: https://friend.example\naddedDate: 2026-08-01\n---\n"])
        defer { try? FileManager.default.removeItem(at: site.root) }
        let stub = APIStub()
        await stub.set(wellKnown: "friend.example", status: 200, body: "at://did:plc:friend/site.standard.publication/anglesite-abc\n")
        await stub.set(
            homepage: "https://friend.example",
            body: #"<link rel="alternate" type="application/rss+xml" href="/feed.xml">"#
        )
        let command = StandardSiteGraphPublishCommand(credentials: { _, _ in credentials }, transport: { try await stub.respond($0) })

        await command.publish(siteID: "site-1", siteDirectory: site.source, configDirectory: site.config)

        let written = try String(
            contentsOf: site.source.appendingPathComponent("src/content/blogroll/friend.md"), encoding: .utf8
        )
        #expect(written.contains("feedURL: \"https://friend.example/feed.xml\""))
    }

    @Test("never overwrites an owner-supplied feedURL")
    func neverOverwritesOwnerFeedURL() async throws {
        let site = try makeSite(blogroll: [
            "friend.md": "---\nname: Friend\nurl: https://friend.example\nfeedURL: https://friend.example/manual.xml\naddedDate: 2026-08-01\n---\n",
        ])
        defer { try? FileManager.default.removeItem(at: site.root) }
        let stub = APIStub()
        await stub.set(wellKnown: "friend.example", status: 200, body: "at://did:plc:friend/site.standard.publication/anglesite-abc\n")
        await stub.set(
            homepage: "https://friend.example",
            body: #"<link rel="alternate" type="application/rss+xml" href="/different-feed.xml">"#
        )
        let command = StandardSiteGraphPublishCommand(credentials: { _, _ in credentials }, transport: { try await stub.respond($0) })

        await command.publish(siteID: "site-1", siteDirectory: site.source, configDirectory: site.config)

        let written = try String(
            contentsOf: site.source.appendingPathComponent("src/content/blogroll/friend.md"), encoding: .utf8
        )
        #expect(written.contains("feedURL: https://friend.example/manual.xml"))
        #expect(!written.contains("different-feed.xml"))
    }
```

Add the `set(homepage:body:)` helper and homepage-serving branch to the `APIStub` (both in this test file's `StandardSiteGraphPublishCommandTests.APIStub`):

```swift
        var homepageResponses: [String: String] = [:]
        func set(homepage: String, body: String) { homepageResponses[homepage] = body }
```

and in `respond(_:)`, before the `switch url.path` for XRPC paths, add:

```swift
            if let body = homepageResponses[url.absoluteString] {
                return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path . --filter StandardSiteGraphPublishCommandTests`
Expected: FAIL — no discovery/write-back happens yet.

- [ ] **Step 3: Wire discovery + write-back into the per-entry loop**

In `Sources/AnglesiteCore/StandardSiteGraphPublishCommand.swift`'s `perform`, inside the `for entry in plan.entries` loop (Task 9's implementation), after a successful `publicationURI` resolution and before constructing `record`, insert:

```swift
            if entry.feedURL == nil {
                if let discovered = try? await FeedEndpointDiscovery.discover(target: entry.url, transport: transport) {
                    writeBackFeedURL(discovered, entry: entry, siteDirectory: siteDirectory, source: source)
                }
            }
```

Add the write-back helper as a new private method on the actor:

```swift
    /// Writes a discovered feed URL back into `entry`'s own content file (#1483). Best-effort:
    /// a read/write failure here is a local-file problem, not a publish failure, so it's logged
    /// and skipped rather than aborting the entry's record publish.
    private func writeBackFeedURL(_ feedURL: URL, entry: BlogrollPlan.Entry, siteDirectory: URL, source: String) {
        let fileURL = siteDirectory.appendingPathComponent(entry.sourceFile)
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let updated = BlogrollFeedFrontmatter.setting(feedURL: feedURL.absoluteString, in: contents)
        guard updated != contents else { return }
        do {
            try updated.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            // Best-effort; no log line — matches how `persistIdentity` in
            // `StandardSitePublishCommand` treats a write-through failure as silent, since it
            // never turns a successful publish into a failed one and will simply retry next pass.
        }
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path . --filter StandardSiteGraphPublishCommandTests`
Expected: PASS

- [ ] **Step 5: Run the full AnglesiteCore suite to check for regressions**

Run: `swift test --package-path . --filter AnglesiteCoreTests`
Expected: PASS (all suites, including Tasks 1-13's).

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/StandardSiteGraphPublishCommand.swift Tests/AnglesiteCoreTests/StandardSiteGraphPublishTests.swift
git commit -m "feat(#1483): discover and write back blogroll feed URLs during publish"
```

---

### Task 15: OPML export

**Files:**
- Create: `Resources/Template/src/lib/opml.ts`
- Create: `Resources/Template/src/lib/opml.test.ts`
- Create: `Resources/Template/src/pages/blogroll.opml.ts`

**Interfaces:**
- Produces:
  ```ts
  // opml.ts
  export interface OpmlOutline { text: string; title: string; xmlUrl: string; htmlUrl: string }
  export function renderOpml(title: string, outlines: OpmlOutline[]): Response
  ```
  Modeled on `Resources/Template/src/lib/sitemap.ts`'s `renderSitemap` (pure XML-string builder returning a `Response`).

- [ ] **Step 1: Write the failing test**

`Resources/Template/src/lib/opml.test.ts`:

```ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { renderOpml } from "./opml.ts";

test("renders a valid OPML 2.0 document with one outline per entry", async () => {
  const response = renderOpml("My Blogroll", [
    { text: "Friend's Blog", title: "Friend's Blog", xmlUrl: "https://friend.example/feed.xml", htmlUrl: "https://friend.example" },
  ]);
  const xml = await response.text();
  assert.match(xml, /<opml version="2.0">/);
  assert.match(xml, /<title>My Blogroll<\/title>/);
  assert.match(xml, /<outline type="rss" text="Friend's Blog" title="Friend's Blog" xmlUrl="https:\/\/friend\.example\/feed\.xml" htmlUrl="https:\/\/friend\.example"\s*\/>/);
});

test("escapes XML-special characters in text/title", async () => {
  const response = renderOpml("Blogroll", [
    { text: "A & B", title: "A & B", xmlUrl: "https://x.example/feed.xml", htmlUrl: "https://x.example" },
  ]);
  const xml = await response.text();
  assert.match(xml, /text="A &amp; B"/);
});

test("renders an empty <body> for no entries", async () => {
  const response = renderOpml("Blogroll", []);
  const xml = await response.text();
  assert.match(xml, /<body>\s*<\/body>/);
});

test("sets the OPML content type", async () => {
  const response = renderOpml("Blogroll", []);
  assert.equal(response.headers.get("Content-Type"), "text/x-opml; charset=utf-8");
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd Resources/Template && npx tsx --test src/lib/opml.test.ts`
Expected: FAIL — `./opml.ts` doesn't exist.

- [ ] **Step 3: Implement**

`Resources/Template/src/lib/opml.ts`:

```ts
export interface OpmlOutline {
  text: string;
  title: string;
  xmlUrl: string;
  htmlUrl: string;
}

function escapeXmlAttr(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/** Renders an OPML 2.0 document for the blogroll's subscribable feed list (#1483). */
export function renderOpml(title: string, outlines: OpmlOutline[]): Response {
  const body = outlines
    .map(
      (o) =>
        `    <outline type="rss" text="${escapeXmlAttr(o.text)}" title="${escapeXmlAttr(o.title)}" xmlUrl="${escapeXmlAttr(o.xmlUrl)}" htmlUrl="${escapeXmlAttr(o.htmlUrl)}"/>`,
    )
    .join("\n");
  const xml = `<?xml version="1.0" encoding="UTF-8"?>
<opml version="2.0">
  <head>
    <title>${escapeXmlAttr(title)}</title>
  </head>
  <body>
${body}
  </body>
</opml>
`;
  return new Response(xml, { headers: { "Content-Type": "text/x-opml; charset=utf-8" } });
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd Resources/Template && npx tsx --test src/lib/opml.test.ts`
Expected: PASS

- [ ] **Step 5: Add the route**

`Resources/Template/src/pages/blogroll.opml.ts`:

```ts
import type { APIContext } from "astro";
import { getCollection } from "astro:content";
import { renderOpml } from "../lib/opml.ts";

export async function GET(_context: APIContext) {
  const entries = await getCollection("blogroll");
  const outlines = entries
    .filter((e) => e.data.feedURL)
    .map((e) => ({
      text: e.data.name,
      title: e.data.name,
      xmlUrl: e.data.feedURL as string,
      htmlUrl: e.data.url,
    }));
  return renderOpml("Blogroll", outlines);
}
```

- [ ] **Step 6: Verify the route builds**

Run: `cd Resources/Template && npm run build`
Expected: succeeds; `/blogroll.opml` is generated in the build output.

- [ ] **Step 7: Commit**

```bash
git add Resources/Template/src/lib/opml.ts Resources/Template/src/lib/opml.test.ts Resources/Template/src/pages/blogroll.opml.ts
git commit -m "feat(#1483): add /blogroll.opml export"
```

---

### Task 16: CSS-only OPML badge

**Files:**
- Create: `Resources/Template/src/components/OpmlBadge.astro`
- Modify: `Resources/Template/src/pages/blogroll/index.astro` (Task 3's page)

**Interfaces:**
- Consumes: nothing external — pure presentational component.
- Produces: `<OpmlBadge />` renders a small linked badge to `/blogroll.opml`; renders nothing when passed no entries with a feed.

- [ ] **Step 1: Write the component**

`Resources/Template/src/components/OpmlBadge.astro`:

```astro
---
// src/components/OpmlBadge.astro — CSS-only "subscribe via OPML" badge for the blogroll page
// (#1483). Most RSS readers only subscribe to a single feed URL, not an OPML file of many, so
// this is a visible affordance rather than a bare link. No <img>, no external asset, no inline
// SVG: the badge shape (rounded rect, dot + broadcast-wave arcs) is drawn with layered
// border-radius/box-shadow, the same family of technique long used for CSS-only RSS icons. Shown
// only when there's at least one entry with a feed — an empty OPML file isn't worth advertising.
interface Props {
  hasFeeds: boolean;
}
const { hasFeeds } = Astro.props;
---

{hasFeeds && (
  <a class="opml-badge" href="/blogroll.opml" title="Subscribe to this blogroll via OPML">
    <span class="opml-badge-icon" aria-hidden="true"></span>
    <span class="opml-badge-text">OPML</span>
  </a>
)}

<style>
  .opml-badge {
    display: inline-flex;
    align-items: center;
    gap: 0.35rem;
    padding: 0.2rem 0.5rem 0.2rem 0.35rem;
    border-radius: 0.2rem;
    background: #ee802f;
    color: #fff;
    font-size: 0.8rem;
    font-weight: 700;
    line-height: 1;
    text-decoration: none;
  }

  .opml-badge:hover {
    background: #d97227;
  }

  /* The classic feed-icon mark: a dot plus two concentric quarter-circle "broadcast" arcs,
     drawn with three stacked circles clipped to their bottom-left quadrant via border-radius,
     each with a transparent center punched out by box-shadow (spread + inset) so only the
     ring — not a filled disc — shows for the two outer arcs. */
  .opml-badge-icon {
    position: relative;
    display: inline-block;
    width: 0.85rem;
    height: 0.85rem;
  }

  .opml-badge-icon::before,
  .opml-badge-icon::after {
    content: "";
    position: absolute;
    left: 0;
    bottom: 0;
    border: 0.14rem solid #fff;
    border-color: #fff transparent transparent #fff;
    border-radius: 100% 0 0 0;
  }

  .opml-badge-icon::before {
    width: 0.85rem;
    height: 0.85rem;
  }

  .opml-badge-icon::after {
    width: 0.5rem;
    height: 0.5rem;
  }

  .opml-badge-icon {
    /* The dot itself, via the element's own background — a filled circle in the bottom-left
       corner, underneath the two arc rings drawn by ::before/::after above. */
    background: transparent;
  }

  .opml-badge-icon {
    background-image: radial-gradient(circle at 0.14rem calc(100% - 0.14rem), #fff 0.1rem, transparent 0.11rem);
  }
</style>
```

- [ ] **Step 2: Wire it into the blogroll page**

In `Resources/Template/src/pages/blogroll/index.astro` (Task 3), change the frontmatter block from:

```astro
---
import { getCollection, render } from "astro:content";
import BaseLayout from "../../layouts/BaseLayout.astro";

const sorted = (await getCollection("blogroll")).sort(
  (a, b) => b.data.addedDate.valueOf() - a.data.addedDate.valueOf()
);
const entries = await Promise.all(
  sorted.map(async (entry) => {
    const { Content } = await render(entry);
    return { data: entry.data, Content };
  }),
);
---
```

to:

```astro
---
import { getCollection, render } from "astro:content";
import BaseLayout from "../../layouts/BaseLayout.astro";
import OpmlBadge from "../../components/OpmlBadge.astro";

const sorted = (await getCollection("blogroll")).sort(
  (a, b) => b.data.addedDate.valueOf() - a.data.addedDate.valueOf()
);
const entries = await Promise.all(
  sorted.map(async (entry) => {
    const { Content } = await render(entry);
    return { data: entry.data, Content };
  }),
);
const hasFeeds = sorted.some((e) => e.data.feedURL);
---
```

and add `<OpmlBadge hasFeeds={hasFeeds} />` right after the `<h1>Blogroll</h1>` line.

- [ ] **Step 3: Verify visually**

Re-add the Task 3 fixture entry, this time with a `feedURL`:

`Resources/Template/src/content/blogroll/example.md`:
```markdown
---
name: Example Blog
url: https://example.com
feedURL: https://example.com/feed.xml
addedDate: 2026-08-01
---
A great blog about examples.
```

Run: `cd Resources/Template && npm run dev` (or the project's preview command), open `/blogroll/` in a browser, confirm the OPML badge renders with an orange rounded background, a white dot-and-arcs mark, and "OPML" text, linking to `/blogroll.opml`. Also verify it does **not** render when the fixture's `feedURL` is removed (empty-OPML case).

Remove the fixture afterward (`rm Resources/Template/src/content/blogroll/example.md`).

- [ ] **Step 4: Run the full template test suite**

Run: `cd Resources/Template && npm test`
Expected: PASS — no regressions in `src/lib/*.test.ts` or the Astro build.

- [ ] **Step 5: Commit**

```bash
git add Resources/Template/src/components/OpmlBadge.astro Resources/Template/src/pages/blogroll/index.astro
git commit -m "feat(#1483): add CSS-only OPML subscribe badge to the blogroll page"
```

---

## Final verification (after all tasks)

- [ ] `swift test --package-path .` — full suite, no regressions
- [ ] `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build` — app target builds
- [ ] `cd Resources/Template && npm test` — full template suite
- [ ] `cd Resources/Template && npm run build` — production build succeeds with the new `blogroll` collection, `/blogroll/` page, and `/blogroll.opml` route
- [ ] Re-read `CONTRIBUTING.md` ▸ "Commits and pull requests" before opening the PR — use the PR template's exact headings (Summary, Paired PR check, Test plan), note "no paired PR needed — no MCP schema change, template changes are app-only," and close with `Closes #1483`.
