# WebMCP Tool Pack Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship two read-only WebMCP tools (`anglesite_search_posts`, `anglesite_fetch_post_markdown`) in the site template, gated behind a new `experimental.webmcp` flag in `anglesite.json`, per [issue #1279](https://github.com/Anglesite/Anglesite/issues/1279).

**Architecture:** Three independent pieces, in dependency order: (1) a config-flag field on `AnglesiteConfig`, (2) static `.md` mirror endpoints for blog posts and entry-collection pages (Astro `getStaticPaths` + `GET`, same pattern as the existing `atom.xml.ts`/`rss.xml.ts`), (3) a pure tool-definition module plus a thin browser-glue script that registers both tools on `document.modelContext` when the flag is on. `BaseLayout.astro` wires the flag to the script last, once the script exists.

**Tech Stack:** Astro 7 (content collections via the `glob()` content-layer loader), TypeScript, `node:test` for pure-logic unit tests, `astro build` fixture tests (via `node:test` + `execFileSync`) for build-level integration checks — following the existing conventions in `Resources/Template/src/lib/licensing.build.test.ts` and `Resources/Template/src/components/esi/esi-components.build.test.ts`.

## Global Constraints

- Template-only work in `Resources/Template/` — no `worker/worker.ts` changes, no Swift changes beyond what `swift test` catches (per `CONTRIBUTING.md`: "If you touch `Resources/Template/`, run `swift test` too"), no paired sidecar PR.
- Default is **off**: `experimental.webmcp` absent or `false` must leave every build byte-identical in rendered HTML to a build before this feature existed (no `<script>` tag emitted anywhere).
- Both tools must degrade to a plain text "not found"/"no results" response on failure, never throw out of `execute`.
- Tool names are prefixed `anglesite_` (dedupe mitigation — no verified way to detect Cloudflare's edge-injected WebMCP bridge exists, per the design spec).
- Pure logic lives in `src/lib/*.ts`, unit-tested with `node:test` (`npx tsx --test`); DOM-only glue stays thin and is verified via build-fixture tests instead, matching this repo's established split.
- Commit subject ≤72 characters, conventional commit format with `(#1279)` scope, per `CONTRIBUTING.md`.
- All commands below run from `Resources/Template/` unless stated otherwise.

---

### Task 1: `experimental.webmcp` config flag

**Files:**
- Modify: `Resources/Template/scripts/anglesite-config.ts`
- Test: `Resources/Template/scripts/anglesite-config.test.ts`

**Interfaces:**
- Produces: `AnglesiteExperimentalConfig` interface (`{ webmcp?: boolean }`), and `AnglesiteConfig.experimental?: AnglesiteExperimentalConfig`. Later tasks read this via `readAnglesiteConfig(process.cwd()).experimental?.webmcp === true`.

- [ ] **Step 1: Write the failing test**

Add to `Resources/Template/scripts/anglesite-config.test.ts`, after the existing `"readAnglesiteConfig: returns declared sections as-is"` test:

```ts
test("readAnglesiteConfig: passes through experimental.webmcp", () => {
  const siteRoot = makeTempSiteRoot();
  writeFileSync(
    join(siteRoot, "anglesite.json"),
    JSON.stringify({ version: 1, experimental: { webmcp: true } }),
  );
  try {
    const result = readAnglesiteConfig(siteRoot);
    assert.deepEqual(result.experimental, { webmcp: true });
  } finally {
    rmSync(siteRoot, { recursive: true, force: true });
  }
});

test("readAnglesiteConfig: experimental section absent by default", () => {
  const siteRoot = makeTempSiteRoot();
  try {
    const result = readAnglesiteConfig(siteRoot);
    assert.equal(result.experimental, undefined);
  } finally {
    rmSync(siteRoot, { recursive: true, force: true });
  }
});
```

- [ ] **Step 2: Run the test to verify it fails to typecheck/compile as expected**

Run (from `Resources/Template/`): `npx tsx --test scripts/anglesite-config.test.ts`

Expected: both new tests actually PASS already, because `readAnglesiteConfig` spreads `...config` verbatim (untyped passthrough) — the only thing missing is the TypeScript *type* declaring `experimental` as a known field. Confirm this by running `npx tsc --noEmit -p .` (or `astro check` if faster) from `Resources/Template/` and observing a type error on `result.experimental` ("Property 'experimental' does not exist on type 'AnglesiteConfig'") in the test file, or on the object literal in Step 1's fixture write if strict elsewhere. If neither the runtime test nor a type-check step fails, skip straight to Step 3 — the point of this step is only to confirm the *type* is what's missing, not runtime behavior.

- [ ] **Step 3: Add the type**

In `Resources/Template/scripts/anglesite-config.ts`, add after `AnglesiteWorkersConfig`:

```ts
export interface AnglesiteExperimentalConfig {
  webmcp?: boolean;
}
```

And add the field to `AnglesiteConfig`:

```ts
export interface AnglesiteConfig {
  version: number;
  domain?: AnglesiteDomainConfig;
  dns?: AnglesiteDNSConfig;
  edge?: AnglesiteEdgeConfig;
  email?: AnglesiteEmailConfig;
  workers?: AnglesiteWorkersConfig;
  experimental?: AnglesiteExperimentalConfig;
}
```

- [ ] **Step 4: Run the tests and the type check**

Run: `npx tsx --test scripts/anglesite-config.test.ts`
Expected: PASS (all tests, including the two new ones).

Run: `npx astro check` (from `Resources/Template/`)
Expected: no new type errors.

- [ ] **Step 5: Commit**

```bash
git add Resources/Template/scripts/anglesite-config.ts Resources/Template/scripts/anglesite-config.test.ts
git commit -m "feat(#1279): add experimental.webmcp config flag"
```

---

### Task 2: Markdown-mirror rendering (pure logic)

**Files:**
- Create: `Resources/Template/src/lib/markdown-mirror.ts`
- Test: `Resources/Template/src/lib/markdown-mirror.test.ts`

**Interfaces:**
- Consumes: nothing from other tasks (pure module, only reads plain objects).
- Produces: `renderMarkdownMirror(entry: MarkdownMirrorEntry): string`, `MARKDOWN_MIRROR_CONTENT_TYPE: string`, `MarkdownMirrorEntry` type (`{ collection: string; id: string; data: Record<string, unknown>; body: string }`). Task 3's endpoint files call `renderMarkdownMirror` and set the `Content-Type` header to `MARKDOWN_MIRROR_CONTENT_TYPE`.

This module maps each of the 11 routed collections (`blog` plus the 10 in `ENTRY_COLLECTIONS`) to its title field and date field, matching each collection's actual zod schema in `Resources/Template/src/content.config.ts`:

| collection | title source | date field |
|---|---|---|
| blog | `data.title` | `pubDate` |
| notes | *(none)* | `publishDate` |
| articles | `data.title` | `publishDate` |
| photos | *(none)* | `publishDate` |
| albums | `data.title` | `publishDate` |
| bookmarks | `data.title` (optional) | `publishDate` |
| replies | *(none)* | `publishDate` |
| likes | *(none)* | `publishDate` |
| announcements | `data.title` | `publishDate` |
| events | `data.name` | `start` |
| reviews | `data.itemReviewed` | `publishDate` |

`tags` is included whenever `data.tags` is a non-empty array of strings, regardless of collection (the zod schemas are `.strict()`, so an entry from a collection whose schema has no `tags` field simply never has that key in `data`).

- [ ] **Step 1: Write the failing test**

Create `Resources/Template/src/lib/markdown-mirror.test.ts`:

```ts
import test from "node:test";
import assert from "node:assert/strict";
import { renderMarkdownMirror, MARKDOWN_MIRROR_CONTENT_TYPE } from "./markdown-mirror.ts";

test("renderMarkdownMirror: blog entry gets title + date frontmatter, no tags", () => {
  const out = renderMarkdownMirror({
    collection: "blog",
    id: "welcome-to-your-blog",
    data: { title: "Welcome to your blog", pubDate: new Date("2026-01-01T00:00:00.000Z"), draft: false },
    body: "This is your blog's first post.",
  });
  assert.equal(
    out,
    '---\ntitle: "Welcome to your blog"\ndate: 2026-01-01T00:00:00.000Z\n---\n\n' +
      "This is your blog's first post.",
  );
});

test("renderMarkdownMirror: notes entry has no title field, includes tags", () => {
  const out = renderMarkdownMirror({
    collection: "notes",
    id: "hello-note",
    data: { publishDate: new Date("2026-06-26T12:00:00.000Z"), tags: ["hello", "hello world"] },
    body: "This is your first note.",
  });
  assert.equal(
    out,
    '---\ndate: 2026-06-26T12:00:00.000Z\ntags: ["hello", "hello world"]\n---\n\n' +
      "This is your first note.",
  );
});

test("renderMarkdownMirror: events entry uses name as title and start as date", () => {
  const out = renderMarkdownMirror({
    collection: "events",
    id: "hello-event",
    data: { name: "Hello Event", start: new Date("2026-03-01T18:00:00.000Z") },
    body: "Join us!",
  });
  assert.equal(
    out,
    '---\ntitle: "Hello Event"\ndate: 2026-03-01T18:00:00.000Z\n---\n\nJoin us!',
  );
});

test("renderMarkdownMirror: reviews entry uses itemReviewed as title", () => {
  const out = renderMarkdownMirror({
    collection: "reviews",
    id: "hello-review",
    data: { itemReviewed: "The Widget 3000", rating: 4, publishDate: new Date("2026-02-01T00:00:00.000Z") },
    body: "Pretty good widget.",
  });
  assert.equal(
    out,
    '---\ntitle: "The Widget 3000"\ndate: 2026-02-01T00:00:00.000Z\n---\n\nPretty good widget.',
  );
});

test("renderMarkdownMirror: likes entry has no title and no tags field, still renders", () => {
  const out = renderMarkdownMirror({
    collection: "likes",
    id: "hello-like",
    data: { likeOf: "https://example.com/post", publishDate: new Date("2026-04-01T00:00:00.000Z") },
    body: "",
  });
  assert.equal(out, "---\ndate: 2026-04-01T00:00:00.000Z\n---\n\n");
});

test("renderMarkdownMirror: an entry with no title, no date, and no tags renders body only", () => {
  const out = renderMarkdownMirror({ collection: "notes", id: "bare", data: {}, body: "Just text." });
  assert.equal(out, "Just text.");
});

test("renderMarkdownMirror: a title containing a colon and quotes is JSON-quoted safely", () => {
  const out = renderMarkdownMirror({
    collection: "articles",
    id: "quoted",
    data: { title: 'A "Quoted" Title: With Colon', publishDate: new Date("2026-05-01T00:00:00.000Z") },
    body: "Body.",
  });
  assert.equal(
    out,
    '---\ntitle: "A \\"Quoted\\" Title: With Colon"\ndate: 2026-05-01T00:00:00.000Z\n---\n\nBody.',
  );
});

test("renderMarkdownMirror: throws for an unrouted collection name", () => {
  assert.throws(
    () => renderMarkdownMirror({ collection: "members", id: "x", data: {}, body: "" }),
    /no mirror field mapping for collection "members"/,
  );
});

test("MARKDOWN_MIRROR_CONTENT_TYPE is text/markdown with a UTF-8 charset", () => {
  assert.equal(MARKDOWN_MIRROR_CONTENT_TYPE, "text/markdown; charset=utf-8");
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npx tsx --test src/lib/markdown-mirror.test.ts`
Expected: FAIL — `Cannot find module './markdown-mirror.ts'`.

- [ ] **Step 3: Write the implementation**

Create `Resources/Template/src/lib/markdown-mirror.ts`:

```ts
/**
 * Renders a content-collection entry as a standalone Markdown document — a raw-source `.md`
 * sibling for each collection page (`[collection]/[...slug].md.ts`, `blog/[...slug].md.ts`),
 * consumed by the WebMCP `anglesite_fetch_post_markdown` tool (issue #1279) and by anything else
 * that wants an agent-readable plain-text copy of a post.
 */

export const MARKDOWN_MIRROR_CONTENT_TYPE = "text/markdown; charset=utf-8";

export interface MarkdownMirrorEntry {
  collection: string;
  id: string;
  data: Record<string, unknown>;
  body: string;
}

interface MirrorFieldMapping {
  dateField: string;
  title(data: Record<string, unknown>): string | undefined;
}

function asString(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

/** Field mapping per routed collection — see content.config.ts for the source-of-truth schemas
 * this mirrors. `members` is deliberately absent: it's not in ENTRY_COLLECTIONS and has no route
 * that would ever call this with `collection: "members"`. */
const MIRROR_FIELDS: Record<string, MirrorFieldMapping> = {
  blog: { dateField: "pubDate", title: (d) => asString(d.title) },
  notes: { dateField: "publishDate", title: () => undefined },
  articles: { dateField: "publishDate", title: (d) => asString(d.title) },
  photos: { dateField: "publishDate", title: () => undefined },
  albums: { dateField: "publishDate", title: (d) => asString(d.title) },
  bookmarks: { dateField: "publishDate", title: (d) => asString(d.title) },
  replies: { dateField: "publishDate", title: () => undefined },
  likes: { dateField: "publishDate", title: () => undefined },
  announcements: { dateField: "publishDate", title: (d) => asString(d.title) },
  events: { dateField: "start", title: (d) => asString(d.name) },
  reviews: { dateField: "publishDate", title: (d) => asString(d.itemReviewed) },
};

/** JSON string syntax is a valid YAML double-quoted scalar, so this doubles as safe YAML
 * quoting without a YAML library — same trick this template's XML writers (escapeXml) use for
 * their own format. */
function yamlString(value: string): string {
  return JSON.stringify(value);
}

export function renderMarkdownMirror(entry: MarkdownMirrorEntry): string {
  const mapping = MIRROR_FIELDS[entry.collection];
  if (!mapping) {
    throw new Error(`renderMarkdownMirror: no mirror field mapping for collection "${entry.collection}"`);
  }

  const title = mapping.title(entry.data);

  const rawDate = entry.data[mapping.dateField];
  const date = rawDate instanceof Date ? rawDate : typeof rawDate === "string" ? new Date(rawDate) : undefined;
  const validDate = date && !Number.isNaN(date.getTime()) ? date : undefined;

  const rawTags = entry.data.tags;
  const tags = Array.isArray(rawTags) ? rawTags.filter((t): t is string => typeof t === "string") : undefined;

  const lines: string[] = [];
  if (title) lines.push(`title: ${yamlString(title)}`);
  if (validDate) lines.push(`date: ${validDate.toISOString()}`);
  if (tags && tags.length > 0) lines.push(`tags: [${tags.map(yamlString).join(", ")}]`);

  const frontmatter = lines.length > 0 ? `---\n${lines.join("\n")}\n---\n\n` : "";
  return `${frontmatter}${entry.body}`;
}
```

- [ ] **Step 4: Run the tests**

Run: `npx tsx --test src/lib/markdown-mirror.test.ts`
Expected: PASS (all 9 tests).

- [ ] **Step 5: Commit**

```bash
git add Resources/Template/src/lib/markdown-mirror.ts Resources/Template/src/lib/markdown-mirror.test.ts
git commit -m "feat(#1279): add markdown-mirror rendering for post entries"
```

---

### Task 3: Markdown-mirror endpoints (`.md` routes)

**Files:**
- Create: `Resources/Template/src/pages/blog/[...slug].md.ts`
- Create: `Resources/Template/src/pages/[collection]/[...slug].md.ts`
- Test: `Resources/Template/src/pages/markdown-mirror.build.test.ts`

**Interfaces:**
- Consumes: `renderMarkdownMirror`, `MARKDOWN_MIRROR_CONTENT_TYPE` from Task 2's `src/lib/markdown-mirror.ts`; `ENTRY_COLLECTIONS` from `src/lib/collections.ts` (existing).
- Produces: the `/blog/<slug>.md` and `/<collection>/<slug>.md` routes that Task 5's browser script fetches (via `buildMarkdownURL`).

These mirror `src/pages/blog/[...slug].astro` and `src/pages/[collection]/[...slug].astro`'s `getStaticPaths` exactly (including the draft-visibility rule), swapping the HTML render for a `GET` handler that calls `renderMarkdownMirror`.

- [ ] **Step 1: Write the failing build-fixture test**

Create `Resources/Template/src/pages/markdown-mirror.build.test.ts`:

```ts
// Resources/Template/src/pages/markdown-mirror.build.test.ts
//
// Build-level test for the WebMCP markdown-mirror routes (#1279): a real `astro build` must
// emit a `.md` sibling for the blog's seed post and for one representative ENTRY_COLLECTIONS
// entry of each distinct title/date-field shape (events: name/start, reviews: itemReviewed,
// notes: titleless with tags) — pure unit coverage of the field mapping already lives in
// markdown-mirror.test.ts; this only proves the two route files actually wire it in.
import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, cp, readFile, rm, access } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

// Resources/Template/ — two `..` up from src/pages/
const TEMPLATE_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

const EXCLUDED = /(^|\/)(node_modules|dist|\.astro|\.wrangler)(\/|$)/;

test("markdown-mirror routes emit .md siblings for blog and entry-collection pages", async () => {
  const fixtureDir = await mkdtemp(join(tmpdir(), "anglesite-markdown-mirror-fixture-"));
  try {
    await cp(TEMPLATE_ROOT, fixtureDir, {
      recursive: true,
      filter: (src) => !EXCLUDED.test(src.slice(TEMPLATE_ROOT.length)),
    });

    execFileSync("npm", ["install", "--no-audit", "--no-fund", "--prefer-offline"], {
      cwd: fixtureDir,
      stdio: "inherit",
    });
    execFileSync("npx", ["astro", "build"], { cwd: fixtureDir, stdio: "inherit" });

    // blog
    {
      const md = await readFile(join(fixtureDir, "dist/blog/welcome-to-your-blog.md"), "utf8");
      assert.match(md, /^---\ntitle: "Welcome to your blog"\ndate: 2026-01-01T00:00:00\.000Z\n---\n\n/);
      assert.match(md, /This is your blog's first post\./);
      assert.equal((await readFile(join(fixtureDir, "dist/blog/welcome-to-your-blog.md"))).length > 0, true);
    }

    // events: name -> title, start -> date (seed content's actual name is "Hello, event" —
    // verified against src/content/events/hello-event.md, not a guessed value)
    {
      const md = await readFile(join(fixtureDir, "dist/events/hello-event.md"), "utf8");
      assert.match(md, /^---\ntitle: "Hello, event"\n/);
    }

    // reviews: itemReviewed -> title
    {
      const md = await readFile(join(fixtureDir, "dist/reviews/hello-review.md"), "utf8");
      assert.match(md, /^---\ntitle: /);
    }

    // notes: no title field, has tags
    {
      const md = await readFile(join(fixtureDir, "dist/notes/hello-note.md"), "utf8");
      assert.doesNotMatch(md, /^---\ntitle:/);
      assert.match(md, /tags: \["hello", "hello world"\]/);
    }

    // Content-Type is asserted indirectly: the response headers aren't captured by a static
    // build (there's no server to observe), so this build-fixture test only proves the *body*
    // is correct; markdown-mirror.test.ts's MARKDOWN_MIRROR_CONTENT_TYPE assertion plus a code
    // read of the two route files (Step 3 below) cover the header itself.

    // A page must not exist for a route these endpoints don't cover.
    await assert.rejects(access(join(fixtureDir, "dist/blog/nonexistent-post.md")));
  } finally {
    await rm(fixtureDir, { recursive: true, force: true });
  }
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npx tsx --test src/pages/markdown-mirror.build.test.ts`
Expected: FAIL — the build succeeds (nothing yet references the missing routes), but `readFile(.../dist/blog/welcome-to-your-blog.md)` rejects with `ENOENT` since the route doesn't exist yet.

- [ ] **Step 3: Write the implementation**

Create `Resources/Template/src/pages/blog/[...slug].md.ts`:

```ts
import type { APIContext } from "astro";
import { getCollection, type CollectionEntry } from "astro:content";
import { renderMarkdownMirror, MARKDOWN_MIRROR_CONTENT_TYPE } from "../../lib/markdown-mirror.ts";

export async function getStaticPaths() {
  const posts = await getCollection("blog", ({ data }) => (import.meta.env.PROD ? !data.draft : true));
  return posts.map((post) => ({ params: { slug: post.id }, props: { post } }));
}

export function GET(context: APIContext) {
  const { post } = context.props as { post: CollectionEntry<"blog"> };
  const markdown = renderMarkdownMirror({
    collection: "blog",
    id: post.id,
    data: post.data,
    body: post.body ?? "",
  });
  return new Response(markdown, { headers: { "Content-Type": MARKDOWN_MIRROR_CONTENT_TYPE } });
}
```

Create `Resources/Template/src/pages/[collection]/[...slug].md.ts`:

```ts
import type { APIContext } from "astro";
import { getCollection, type CollectionEntry } from "astro:content";
import { ENTRY_COLLECTIONS, type EntryCollection } from "../../lib/collections.ts";
import { renderMarkdownMirror, MARKDOWN_MIRROR_CONTENT_TYPE } from "../../lib/markdown-mirror.ts";

export async function getStaticPaths() {
  const paths: Array<{
    params: { collection: string; slug: string };
    props: { entry: CollectionEntry<EntryCollection> };
  }> = [];
  for (const collection of ENTRY_COLLECTIONS) {
    const entries = await getCollection(collection);
    // Business types (events/reviews/announcements) have no `draft` key — see the identical
    // comment in `[collection]/[...slug].astro`, which this route mirrors exactly.
    const visible = entries.filter((entry) => (import.meta.env.PROD ? !(entry.data as any).draft : true));
    for (const entry of visible) {
      paths.push({ params: { collection, slug: entry.id }, props: { entry } });
    }
  }
  return paths;
}

export function GET(context: APIContext) {
  const { entry } = context.props as { entry: CollectionEntry<EntryCollection> };
  const collection = context.params.collection as string;
  const markdown = renderMarkdownMirror({
    collection,
    id: entry.id,
    data: entry.data,
    body: entry.body ?? "",
  });
  return new Response(markdown, { headers: { "Content-Type": MARKDOWN_MIRROR_CONTENT_TYPE } });
}
```

- [ ] **Step 4: Run the build-fixture test and the full template test suite**

Run: `npx tsx --test src/pages/markdown-mirror.build.test.ts`
Expected: PASS.

Run: `npx astro check`
Expected: no new type errors.

- [ ] **Step 5: Commit**

```bash
git add Resources/Template/src/pages/blog/\[...slug\].md.ts Resources/Template/src/pages/\[collection\]/\[...slug\].md.ts Resources/Template/src/pages/markdown-mirror.build.test.ts
git commit -m "feat(#1279): add .md mirror routes for blog and entry pages"
```

---

### Task 4: WebMCP tool definitions (pure logic)

**Files:**
- Create: `Resources/Template/src/lib/webmcp-tools.ts`
- Test: `Resources/Template/src/lib/webmcp-tools.test.ts`

**Interfaces:**
- Consumes: nothing from other tasks (pure module).
- Produces: `SEARCH_POSTS_TOOL`, `FETCH_POST_MARKDOWN_TOOL` (both `WebmcpToolDefinition`), `buildMarkdownURL(path: string): string`, `formatSearchResults(results: PagefindResultData[]): WebmcpToolResult`, and the `WebmcpToolDefinition`/`WebmcpToolResult`/`PagefindResultData` types. Task 5's browser script imports all of these.

- [ ] **Step 1: Write the failing test**

Create `Resources/Template/src/lib/webmcp-tools.test.ts`:

```ts
import test from "node:test";
import assert from "node:assert/strict";
import {
  SEARCH_POSTS_TOOL,
  FETCH_POST_MARKDOWN_TOOL,
  buildMarkdownURL,
  formatSearchResults,
} from "./webmcp-tools.ts";

test("SEARCH_POSTS_TOOL has the anglesite_ prefix and a query-required input schema", () => {
  assert.equal(SEARCH_POSTS_TOOL.name, "anglesite_search_posts");
  assert.equal(SEARCH_POSTS_TOOL.inputSchema.type, "object");
  assert.deepEqual((SEARCH_POSTS_TOOL.inputSchema as any).required, ["query"]);
});

test("FETCH_POST_MARKDOWN_TOOL has the anglesite_ prefix and a path-required input schema", () => {
  assert.equal(FETCH_POST_MARKDOWN_TOOL.name, "anglesite_fetch_post_markdown");
  assert.deepEqual((FETCH_POST_MARKDOWN_TOOL.inputSchema as any).required, ["path"]);
});

test("buildMarkdownURL: strips a trailing slash and appends .md", () => {
  assert.equal(buildMarkdownURL("/blog/hello-world/"), "/blog/hello-world.md");
});

test("buildMarkdownURL: a path with no trailing slash still gets .md appended", () => {
  assert.equal(buildMarkdownURL("/blog/hello-world"), "/blog/hello-world.md");
});

test("buildMarkdownURL: root path", () => {
  assert.equal(buildMarkdownURL("/"), ".md");
});

test("formatSearchResults: empty results returns a plain 'no results' text response", () => {
  const result = formatSearchResults([]);
  assert.deepEqual(result, { content: [{ type: "text", text: "No results found." }] });
});

test("formatSearchResults: formats title, url, and a stripped-HTML excerpt", () => {
  const result = formatSearchResults([
    { url: "/blog/hello-world/", meta: { title: "Hello World" }, excerpt: "This is <mark>hello</mark> world." },
  ]);
  assert.deepEqual(result, {
    content: [{ type: "text", text: "1. Hello World — /blog/hello-world/\n   This is hello world." }],
  });
});

test("formatSearchResults: falls back to the URL when no title is present", () => {
  const result = formatSearchResults([{ url: "/notes/hello-note/" }]);
  assert.deepEqual(result, {
    content: [{ type: "text", text: "1. /notes/hello-note/ — /notes/hello-note/" }],
  });
});

test("formatSearchResults: numbers multiple results in order", () => {
  const result = formatSearchResults([
    { url: "/a/", meta: { title: "A" } },
    { url: "/b/", meta: { title: "B" } },
  ]);
  assert.deepEqual(result, {
    content: [{ type: "text", text: "1. A — /a/\n2. B — /b/" }],
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npx tsx --test src/lib/webmcp-tools.test.ts`
Expected: FAIL — `Cannot find module './webmcp-tools.ts'`.

- [ ] **Step 3: Write the implementation**

Create `Resources/Template/src/lib/webmcp-tools.ts`:

```ts
/**
 * Pure tool metadata and helpers for the site's WebMCP tool pack (issue #1279). No `document`,
 * `fetch`, or Pagefind imports here — the browser-only wiring lives in `src/scripts/webmcp.ts`,
 * kept separate so this module stays plain-data-in/plain-data-out and unit-testable with
 * `node:test`, matching this template's "pure logic in src/lib" convention.
 */

export interface WebmcpToolDefinition {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
}

export interface WebmcpToolResult {
  content: Array<{ type: "text"; text: string }>;
}

export const SEARCH_POSTS_TOOL: WebmcpToolDefinition = {
  name: "anglesite_search_posts",
  description: "Search this site's published posts and pages. Returns matching titles, URLs, and excerpts.",
  inputSchema: {
    type: "object",
    properties: {
      query: { type: "string", description: "The search query text." },
      limit: { type: "number", description: "Maximum number of results to return (default 5)." },
    },
    required: ["query"],
  },
};

export const FETCH_POST_MARKDOWN_TOOL: WebmcpToolDefinition = {
  name: "anglesite_fetch_post_markdown",
  description: "Fetch the raw Markdown source of a page on this site, given its site-relative path.",
  inputSchema: {
    type: "object",
    properties: {
      path: { type: "string", description: 'A site-relative path, e.g. "/blog/hello-world/".' },
    },
    required: ["path"],
  },
};

/** Derives a post's `.md` mirror URL (see `src/lib/markdown-mirror.ts` and the
 * `[...slug].md.ts` routes) from its site-relative page path. */
export function buildMarkdownURL(path: string): string {
  const trimmed = path.endsWith("/") ? path.slice(0, -1) : path;
  return `${trimmed}.md`;
}

/** The subset of Pagefind's `PagefindSearchFragment` (the resolved shape of a search result's
 * `.data()`) this tool actually reads — kept narrow and dependency-free rather than importing
 * Pagefind's own types, since this module must stay usable outside a browser/Vite context. */
export interface PagefindResultData {
  url: string;
  excerpt?: string;
  meta?: { title?: string };
}

function stripHtml(html: string): string {
  return html.replace(/<[^>]+>/g, "");
}

export function formatSearchResults(results: PagefindResultData[]): WebmcpToolResult {
  if (results.length === 0) {
    return { content: [{ type: "text", text: "No results found." }] };
  }
  const text = results
    .map((r, i) => {
      const title = r.meta?.title || r.url;
      const excerpt = r.excerpt ? stripHtml(r.excerpt) : "";
      return `${i + 1}. ${title} — ${r.url}${excerpt ? `\n   ${excerpt}` : ""}`;
    })
    .join("\n");
  return { content: [{ type: "text", text }] };
}
```

- [ ] **Step 4: Run the tests**

Run: `npx tsx --test src/lib/webmcp-tools.test.ts`
Expected: PASS (all 9 tests).

- [ ] **Step 5: Commit**

```bash
git add Resources/Template/src/lib/webmcp-tools.ts Resources/Template/src/lib/webmcp-tools.test.ts
git commit -m "feat(#1279): add pure WebMCP tool definitions and helpers"
```

---

### Task 5: Browser-side tool registration script

**Files:**
- Create: `Resources/Template/src/scripts/webmcp.ts`

**Interfaces:**
- Consumes: `SEARCH_POSTS_TOOL`, `FETCH_POST_MARKDOWN_TOOL`, `buildMarkdownURL`, `formatSearchResults`, `PagefindResultData` from Task 4's `src/lib/webmcp-tools.ts`.
- Produces: a browser entry module with no exports (side-effecting on load). Task 6's `BaseLayout.astro` references it as `<script type="module" src="../scripts/webmcp.ts">`.

This file is DOM/global-only glue with no pure logic of its own, so per this repo's testing convention (thin `.astro`/browser wiring verified at the build level, not unit-tested directly) it has no dedicated `node:test` file — Task 6's build-fixture test verifies its compiled output.

- [ ] **Step 1: Write the implementation**

Create `Resources/Template/src/scripts/webmcp.ts`:

```ts
import {
  SEARCH_POSTS_TOOL,
  FETCH_POST_MARKDOWN_TOOL,
  buildMarkdownURL,
  formatSearchResults,
  type PagefindResultData,
  type WebmcpToolDefinition,
  type WebmcpToolResult,
} from "../lib/webmcp-tools.ts";

interface ModelContextTool extends WebmcpToolDefinition {
  execute(args: any): Promise<WebmcpToolResult>;
}

interface ModelContext {
  registerTool(def: ModelContextTool, options?: { signal?: AbortSignal }): Promise<void>;
}

declare global {
  interface Document {
    modelContext?: ModelContext;
  }
}

/** Pagefind's low-level search API module, built by this project's `postbuild` step
 * (`npx pagefind --site dist`) alongside `pagefind-component-ui.js`. Dynamically imported —
 * it doesn't exist at Astro/Vite build time, only after `postbuild` runs against `dist/`. */
interface PagefindModule {
  search(term: string): Promise<{ results: Array<{ data(): Promise<PagefindResultData> }> }>;
}

if ("modelContext" in document && document.modelContext) {
  const modelContext = document.modelContext;
  // Held for the page's lifetime — this script never unregisters its own tools, so the
  // controller is never aborted; it exists only because registerTool's options accept one.
  const controller = new AbortController();

  async function registerSafely(
    def: WebmcpToolDefinition,
    execute: (args: any) => Promise<WebmcpToolResult>,
  ): Promise<void> {
    try {
      await modelContext.registerTool({ ...def, execute }, { signal: controller.signal });
    } catch (err) {
      // No verified way exists to detect Cloudflare's edge-injected WebMCP bridge ahead of
      // time (see the design spec's "Dedupe strategy") — if the platform or another pack
      // throws on a duplicate tool name, log and move on rather than breaking the page.
      console.warn(`[webmcp] failed to register tool "${def.name}":`, err);
    }
  }

  void registerSafely(SEARCH_POSTS_TOOL, async ({ query, limit }: { query: string; limit?: number }) => {
    const pagefind = (await import(/* @vite-ignore */ "/pagefind/pagefind.js")) as unknown as PagefindModule;
    const { results } = await pagefind.search(query);
    const top = results.slice(0, limit ?? 5);
    const data = await Promise.all(top.map((r) => r.data()));
    return formatSearchResults(data);
  });

  void registerSafely(FETCH_POST_MARKDOWN_TOOL, async ({ path }: { path: string }) => {
    const res = await fetch(buildMarkdownURL(path));
    if (!res.ok) {
      return { content: [{ type: "text", text: `Not found: ${path}` }] };
    }
    return { content: [{ type: "text", text: await res.text() }] };
  });
}
```

The `/* @vite-ignore */` comment stops Astro/Vite from trying to statically resolve
`/pagefind/pagefind.js` at build time — that file doesn't exist until the `postbuild` step runs
against `dist/`, exactly like `search.astro`'s existing `pagefind-component-ui.js` reference,
which sidesteps the same problem by being a plain `is:inline` script instead. A dynamic
`import()` needs the Vite-ignore comment because this file **is** bundled (unlike
`search.astro`'s script).

- [ ] **Step 2: Type-check**

Run (from `Resources/Template/`): `npx astro check`
Expected: no new type errors. (This file isn't imported by any page yet, so `astro check` may not
type-check it in isolation — if so, this step is a no-op until Task 6 wires it in; re-run
`npx astro check` again at the end of Task 6's Step 4 to confirm.)

- [ ] **Step 3: Commit**

```bash
git add Resources/Template/src/scripts/webmcp.ts
git commit -m "feat(#1279): add browser-side WebMCP tool registration script"
```

---

### Task 6: Wire the config flag to the script in `BaseLayout.astro`

**Files:**
- Modify: `Resources/Template/src/layouts/BaseLayout.astro`
- Test: `Resources/Template/src/layouts/webmcp.build.test.ts`

**Interfaces:**
- Consumes: `readAnglesiteConfig` from Task 1's `Resources/Template/scripts/anglesite-config.ts`; `Resources/Template/src/scripts/webmcp.ts` from Task 5 (referenced by path, not imported as a JS value).
- Produces: the end-to-end feature — a site with `experimental.webmcp: true` in `anglesite.json` ships the script on every page; a site without it ships nothing.

- [ ] **Step 1: Write the failing build-fixture test**

Create `Resources/Template/src/layouts/webmcp.build.test.ts`:

```ts
// Resources/Template/src/layouts/webmcp.build.test.ts
//
// Build-level test for the experimental.webmcp flag (#1279): with the flag on, every page must
// carry a bundled <script type="module"> that registers the two anglesite_ tools; with the flag
// off (the default), no page may reference any such script at all — the feature must be
// completely inert for a site that hasn't opted in.
import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, cp, writeFile, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

// Resources/Template/ — two `..` up from src/layouts/
const TEMPLATE_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

const EXCLUDED = /(^|\/)(node_modules|dist|\.astro|\.wrangler)(\/|$)/;

/** Every `src` attribute of a `type="module"` `<script>` tag in an HTML document — attribute
 * order and any extra attributes Astro adds (e.g. crossorigin) are deliberately not assumed. */
function scriptSrcs(html: string): string[] {
  return [...html.matchAll(/<script[^>]*\btype="module"[^>]*\bsrc="([^"]+)"[^>]*>/g)].map((m) => m[1]);
}

test("experimental.webmcp: off by default, no script emitted anywhere", async () => {
  const fixtureDir = await mkdtemp(join(tmpdir(), "anglesite-webmcp-off-fixture-"));
  try {
    await cp(TEMPLATE_ROOT, fixtureDir, {
      recursive: true,
      filter: (src) => !EXCLUDED.test(src.slice(TEMPLATE_ROOT.length)),
    });

    execFileSync("npm", ["install", "--no-audit", "--no-fund", "--prefer-offline"], {
      cwd: fixtureDir,
      stdio: "inherit",
    });
    execFileSync("npx", ["astro", "build"], { cwd: fixtureDir, stdio: "inherit" });

    const html = await readFile(join(fixtureDir, "dist/notes/hello-note/index.html"), "utf8");
    assert.doesNotMatch(html, /modelContext/, "no page may reference modelContext when the flag is off");
    for (const src of scriptSrcs(html)) {
      const chunk = await readFile(join(fixtureDir, "dist", src.replace(/^\//, "")), "utf8").catch(() => "");
      assert.doesNotMatch(
        chunk,
        /anglesite_search_posts/,
        `bundled script ${src} must not be the webmcp tool script when the flag is off`,
      );
    }
  } finally {
    await rm(fixtureDir, { recursive: true, force: true });
  }
});

test("experimental.webmcp: true emits a script registering both anglesite_ tools", async () => {
  const fixtureDir = await mkdtemp(join(tmpdir(), "anglesite-webmcp-on-fixture-"));
  try {
    await cp(TEMPLATE_ROOT, fixtureDir, {
      recursive: true,
      filter: (src) => !EXCLUDED.test(src.slice(TEMPLATE_ROOT.length)),
    });
    await writeFile(
      join(fixtureDir, "anglesite.json"),
      JSON.stringify({ version: 1, experimental: { webmcp: true } }),
      "utf8",
    );

    execFileSync("npm", ["install", "--no-audit", "--no-fund", "--prefer-offline"], {
      cwd: fixtureDir,
      stdio: "inherit",
    });
    execFileSync("npx", ["astro", "build"], { cwd: fixtureDir, stdio: "inherit" });

    const html = await readFile(join(fixtureDir, "dist/notes/hello-note/index.html"), "utf8");
    const srcs = scriptSrcs(html);
    assert.ok(srcs.length > 0, "the page must carry at least one bundled <script type=\"module\">");

    let found = false;
    for (const src of srcs) {
      const chunk = await readFile(join(fixtureDir, "dist", src.replace(/^\//, "")), "utf8").catch(() => "");
      if (chunk.includes("anglesite_search_posts") && chunk.includes("anglesite_fetch_post_markdown")) {
        found = true;
        assert.match(chunk, /modelContext/, "the bundled script must reference document.modelContext");
      }
    }
    assert.ok(found, "no bundled script chunk contained both anglesite_ tool names");
  } finally {
    await rm(fixtureDir, { recursive: true, force: true });
  }
});
```

- [ ] **Step 2: Run the tests to verify the second one fails**

Run: `npx tsx --test src/layouts/webmcp.build.test.ts`
Expected: the first test (`off by default`) PASSes already (no code emits `modelContext`
anywhere yet). The second test (`true emits a script...`) FAILs — `srcs.length > 0` is false, or
no chunk contains both tool names, since nothing wires the flag to the script yet.

- [ ] **Step 3: Write the implementation**

In `Resources/Template/src/layouts/BaseLayout.astro`, add the import alongside the existing ones
near the top of the frontmatter:

```astro
import { readAnglesiteConfig } from "../../scripts/anglesite-config";
```

Add the flag read next to the existing `noindex`/`rsl` consts:

```astro
// #1279: experimental.webmcp — off by default, so an un-opted-in site's build stays byte-
// identical (no <script> anywhere) to a build before this feature existed.
const webmcpEnabled = readAnglesiteConfig(process.cwd()).experimental?.webmcp === true;
```

Add the conditional script tag just before the `<!-- anglesite:body-end -->` marker:

```astro
    {webmcpEnabled && <script type="module" src="../scripts/webmcp.ts"></script>}
    <!-- anglesite:body-end -->
```

- [ ] **Step 4: Run the tests**

Run: `npx tsx --test src/layouts/webmcp.build.test.ts`
Expected: PASS (both tests).

Run: `npx astro check`
Expected: no new type errors (this also confirms Task 5's `webmcp.ts` type-checks now that it's
referenced by a page).

Run the full template test suite: `npm test`
Expected: PASS — no regressions in any other `*.test.ts` file.

- [ ] **Step 5: Commit**

```bash
git add Resources/Template/src/layouts/BaseLayout.astro Resources/Template/src/layouts/webmcp.build.test.ts
git commit -m "feat(#1279): wire experimental.webmcp flag to the tool script"
```

---

## After all tasks

- [ ] Run `swift test --package-path .` from the repo root (`CONTRIBUTING.md`: touching `Resources/Template/` can affect Swift tests coupled to template markup).
- [ ] Run `npm run test:astro` from `Resources/Template/` (the `vitest.astro.config.ts` suite) to confirm no regression there.
- [ ] Open the PR using `.github/PULL_REQUEST_TEMPLATE.md`'s exact headings (Summary, Paired PR check, Test plan), with `Closes #1279` per `CONTRIBUTING.md`. Paired PR check: **not applicable** — this is template-only, no MCP message schema change.
