# Site MCP Server (Read-Only Tools) + MCP Server Card Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a read-only MCP server at `/mcp` (Streamable HTTP) plus a generated MCP Server Card at `/.well-known/mcp/server-card.json`, gated behind a new opt-in `experimental.mcp` flag, per [#1576](https://github.com/Anglesite/Anglesite/issues/1576) and the approved design at [`docs/superpowers/specs/2026-08-19-site-mcp-server-design.md`](../specs/2026-08-19-site-mcp-server-design.md).

**Architecture:** Cloudflare's stateless `createMcpHandler` (from `agents`/`@modelcontextprotocol/server`) backs three read-only tools fed by build-time-derived artifacts (a search index, feed-path list, `.md` mirror endpoints). A new `experimental.mcp` flag flows through both the TypeScript template (build-time inertness) and Swift Worker-composition/provisioning (so a plain-blog site with only this flag on still gets `worker/worker.ts` deployed and `SOCIAL_KV` provisioned for rate limiting).

**Tech Stack:** Astro + Cloudflare Workers (TypeScript, `node:test`/`vitest`), Swift 6.4 (Swift Testing).

## Global Constraints

- New template npm dependencies: `agents`, `@modelcontextprotocol/server@2.0.0`, `zod` (per approved design — `zod` is not currently a dependency of anything in `Resources/Template/package.json`).
- `experimental.mcp` defaults to `false`/absent; every artifact this feature adds (search index, server card, `/mcp` route) must be inert (404/absent) when it is off.
- `AgentReadinessReport.swift`'s `mcpServerCard.anglesiteProvides` stays `false` — do **not** flip it (deliberate deviation from the issue's literal instruction, following the `webMcp` precedent; see design doc §9). No task in this plan touches `AgentReadinessReport.swift`.
- Rate limiting: KV-counter shape mirrors `isConsentRateLimited`/`consentRateLimitKey` in `worker/worker.ts` (hash `CF-Connecting-IP`, TTL-windowed count in `SOCIAL_KV`, fail closed when unbound) but with its own key prefix (`mcp-tool-call:`) and its own window/threshold (`3600`s / `60` calls) — not shared counters with the consent-form limiter.
- `fetch_page_content` for non-collection pages does plain-text extraction only, not markdown-negotiation-conformant conversion (#1247 is a separate, later feature).
- Swift tests: Swift Testing (`import Testing`, `@Test(...)`, `#expect`), not XCTest. TS template tests: `node:test`/`assert/strict` for `scripts/**/*.test.ts` and `src/lib/*.test.ts`; Vitest (`cloudflare:test`/`cloudflare:workers`) for `worker/*.test.ts`.
- No paired PR to `Anglesite/anglesite-skills` — everything in this plan is within `Anglesite/Anglesite`.

---

## Task 1: `experimental.mcp` config flag

**Files:**
- Modify: `Resources/Template/scripts/anglesite-config.ts:55-57`
- Modify: `Resources/Template/scripts/anglesite-config.test.ts`

**Interfaces:**
- Produces: `AnglesiteExperimentalConfig.mcp?: boolean`, consumed by every later TS task via `readAnglesiteConfig(...).experimental?.mcp`.

- [ ] **Step 1: Write the failing test**

Add to `Resources/Template/scripts/anglesite-config.test.ts` (after the existing `"readAnglesiteConfig: experimental section absent by default"` test, around line 128):

```typescript
test("readAnglesiteConfig: passes through experimental.mcp", () => {
  const siteRoot = makeTempSiteRoot();
  writeFileSync(
    join(siteRoot, "anglesite.json"),
    JSON.stringify({ version: 1, experimental: { mcp: true } }),
  );
  try {
    const result = readAnglesiteConfig(siteRoot);
    assert.deepEqual(result.experimental, { mcp: true });
  } finally {
    rmSync(siteRoot, { recursive: true, force: true });
  }
});

test("readAnglesiteConfig: passes through both experimental flags together", () => {
  const siteRoot = makeTempSiteRoot();
  writeFileSync(
    join(siteRoot, "anglesite.json"),
    JSON.stringify({ version: 1, experimental: { webmcp: true, mcp: false } }),
  );
  try {
    const result = readAnglesiteConfig(siteRoot);
    assert.deepEqual(result.experimental, { webmcp: true, mcp: false });
  } finally {
    rmSync(siteRoot, { recursive: true, force: true });
  }
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Resources/Template && npx tsx --test scripts/anglesite-config.test.ts`
Expected: FAIL — `AnglesiteExperimentalConfig` has no `mcp` property, but since this is a structural (not type-checked at test-runtime) JS test it will actually fail on `assert.deepEqual` seeing `experimental` still contain `mcp: true`/`mcp: false` passed through unchanged — wait, since `readAnglesiteConfig` passes sections through as-is (untyped at runtime), this specific test may actually PASS even before the interface change, because nothing in the reader validates section shape. Confirm this by running it first; if it already passes, the interface field is still required for **type-checking** (`astro check`, `tsc`) elsewhere (Step 3 is still required for `astro.config.ts`/callers that will read `.experimental.mcp` with proper types in later tasks). Note the actual result before proceeding.

- [ ] **Step 3: Add the field**

In `Resources/Template/scripts/anglesite-config.ts`, change:

```typescript
export interface AnglesiteExperimentalConfig {
  webmcp?: boolean;
}
```

to:

```typescript
export interface AnglesiteExperimentalConfig {
  webmcp?: boolean;
  mcp?: boolean;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Resources/Template && npx tsx --test scripts/anglesite-config.test.ts`
Expected: PASS (all tests in the file, including the two new ones)

- [ ] **Step 5: Type-check**

Run: `cd Resources/Template && npx astro check`
Expected: no new errors

- [ ] **Step 6: Commit**

```bash
cd Resources/Template
git add scripts/anglesite-config.ts scripts/anglesite-config.test.ts
git commit -m "feat(#1576): add experimental.mcp config flag"
```

---

## Task 2: `worker/mcp-config.json` build artifact

**Files:**
- Create: `Resources/Template/worker/mcp-config.ts`
- Create: `Resources/Template/scripts/mcp-artifact.ts`
- Create: `Resources/Template/scripts/mcp-artifact.test.ts`

**Interfaces:**
- Consumes: `AnglesiteConfig` (Task 1), `FEED_COLLECTIONS` from `Resources/Template/src/lib/feeds.ts`, `readAnglesiteConfig` from `scripts/anglesite-config.ts`.
- Produces: `McpConfigArtifact { enabled: boolean; feedPaths: string[] }` (type, in `worker/mcp-config.ts`), `worker/mcp-config.json` (generated file, gitignored), `buildFeedPaths()`, `buildMcpConfigArtifact(config)` (exported, pure, consumed by Task 7).

- [ ] **Step 1: Write the type file**

Create `Resources/Template/worker/mcp-config.ts`:

```typescript
/** Runtime shape of `worker/mcp-config.json` (#1576) — generated by
 *  `scripts/mcp-artifact.ts` from `anglesite.json`'s `experimental.mcp` flag, mirroring how
 *  `worker/experiments.ts` defines the shape `scripts/experiments-artifact.ts` writes. */
export interface McpConfigArtifact {
  enabled: boolean;
  feedPaths: string[];
}
```

- [ ] **Step 2: Write the failing test**

Create `Resources/Template/scripts/mcp-artifact.test.ts`:

```typescript
import test from "node:test";
import assert from "node:assert/strict";
import { buildFeedPaths, buildMcpConfigArtifact } from "./mcp-artifact.ts";

test("buildFeedPaths: includes root-level and per-collection feed formats", () => {
  const paths = buildFeedPaths();
  assert.ok(paths.includes("/rss.xml"));
  assert.ok(paths.includes("/atom.xml"));
  assert.ok(paths.includes("/feed.json"));
  assert.ok(paths.includes("/blog/rss.xml"));
  assert.ok(paths.includes("/blog/atom.xml"));
  assert.ok(paths.includes("/blog/feed.json"));
  assert.ok(paths.includes("/likes/feed.json"));
});

test("buildFeedPaths: exactly 3 root paths plus 3 per FEED_COLLECTIONS entry", () => {
  const paths = buildFeedPaths();
  // FEED_COLLECTIONS has 8 entries (blog, notes, articles, photos, albums, bookmarks, replies, likes).
  assert.equal(paths.length, 3 + 8 * 3);
});

test("buildMcpConfigArtifact: enabled is true only when experimental.mcp === true", () => {
  assert.equal(buildMcpConfigArtifact({ version: 1 }).enabled, false);
  assert.equal(buildMcpConfigArtifact({ version: 1, experimental: { mcp: false } }).enabled, false);
  assert.equal(buildMcpConfigArtifact({ version: 1, experimental: { mcp: true } }).enabled, true);
});

test("buildMcpConfigArtifact: feedPaths matches buildFeedPaths()", () => {
  assert.deepEqual(buildMcpConfigArtifact({ version: 1 }).feedPaths, buildFeedPaths());
});
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd Resources/Template && npx tsx --test scripts/mcp-artifact.test.ts`
Expected: FAIL with a module-not-found error for `./mcp-artifact.ts`

- [ ] **Step 4: Write the generator**

Create `Resources/Template/scripts/mcp-artifact.ts`:

```typescript
#!/usr/bin/env npx tsx
/**
 * Build-time generator for `worker/mcp-config.json` (#1576): the MCP feature's runtime-relevant
 * config, derived from `anglesite.json`'s `experimental.mcp` flag. Gitignored, derived, never
 * hand-edited — regenerated at `prebuild` (and before `npm run test:worker`, via the
 * `pretest:worker` script) the same way `scripts/experiments-artifact.ts` regenerates
 * `worker/experiments.json`. `worker/mcp-server.ts` statically imports the written file, so it
 * must exist before that file is bundled by Astro/Wrangler/Vitest.
 */
import { mkdirSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { readAnglesiteConfig, type AnglesiteConfig } from "./anglesite-config.ts";
import { FEED_COLLECTIONS } from "../src/lib/feeds.ts";
import type { McpConfigArtifact } from "../worker/mcp-config.ts";

/** The static list of feed URLs this template unconditionally generates: three root-level
 *  formats (the site's primary feed, unprefixed) plus three formats per `FEED_COLLECTIONS`
 *  entry — matches the file layout under `src/pages/` byte-for-byte. */
export function buildFeedPaths(): string[] {
  const root = ["/rss.xml", "/atom.xml", "/feed.json"];
  const perCollection = Object.keys(FEED_COLLECTIONS).flatMap((collection) => [
    `/${collection}/rss.xml`,
    `/${collection}/atom.xml`,
    `/${collection}/feed.json`,
  ]);
  return [...root, ...perCollection];
}

export function buildMcpConfigArtifact(config: AnglesiteConfig): McpConfigArtifact {
  return {
    enabled: config.experimental?.mcp === true,
    feedPaths: buildFeedPaths(),
  };
}

function writeMcpConfigArtifact(siteRoot: string): void {
  const artifact = buildMcpConfigArtifact(readAnglesiteConfig(siteRoot));
  const outDir = resolve(siteRoot, "worker");
  mkdirSync(outDir, { recursive: true });
  writeFileSync(resolve(outDir, "mcp-config.json"), JSON.stringify(artifact, null, 2) + "\n", "utf-8");
}

function main(): void {
  writeMcpConfigArtifact(process.cwd());
  console.log("Wrote worker/mcp-config.json");
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main();
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd Resources/Template && npx tsx --test scripts/mcp-artifact.test.ts`
Expected: PASS (4 tests)

- [ ] **Step 6: Generate the artifact once and gitignore it**

```bash
cd Resources/Template
npx tsx scripts/mcp-artifact.ts
```

Add to `Resources/Template/.gitignore` (near the existing `worker/experiments.json` line):

```
worker/mcp-config.json
```

- [ ] **Step 7: Commit**

```bash
cd Resources/Template
git add worker/mcp-config.ts scripts/mcp-artifact.ts scripts/mcp-artifact.test.ts .gitignore
git commit -m "feat(#1576): generate worker/mcp-config.json build artifact"
```

---

## Task 3: Wire the artifact and new SDK deps into `package.json`

**Files:**
- Modify: `Resources/Template/package.json`

**Interfaces:**
- Consumes: `scripts/mcp-artifact.ts` (Task 2).
- Produces: `agents`, `@modelcontextprotocol/server`, `zod` available as imports for Task 7; `worker/mcp-config.json` regenerated before every prebuild and before `test:worker`.

- [ ] **Step 1: Add the new dependencies**

Run:

```bash
cd Resources/Template
npm install agents @modelcontextprotocol/server@2.0.0 zod
```

Verify `package.json`'s `dependencies` now includes all three (Astro/Cloudflare SDKs commonly land in `dependencies` since the Worker bundles them at deploy time, matching where `@dwk/*` packages already live).

- [ ] **Step 2: Wire `mcp-artifact.ts` into `prebuild` and `pretest:worker`**

In `Resources/Template/package.json`, change:

```json
"prebuild": "npx tsx scripts/well-known.ts check && npx tsx scripts/csp.ts && npx tsx scripts/edge-artifacts.ts && npx tsx scripts/experiments-artifact.ts",
```

to:

```json
"prebuild": "npx tsx scripts/well-known.ts check && npx tsx scripts/csp.ts && npx tsx scripts/edge-artifacts.ts && npx tsx scripts/experiments-artifact.ts && npx tsx scripts/mcp-artifact.ts",
```

and change:

```json
"pretest:worker": "npx tsx scripts/experiments-artifact.ts",
```

to:

```json
"pretest:worker": "npx tsx scripts/experiments-artifact.ts && npx tsx scripts/mcp-artifact.ts",
```

- [ ] **Step 3: Verify the prebuild chain runs clean**

Run: `cd Resources/Template && npm run prebuild`
Expected: exits 0, `worker/mcp-config.json` is (re)written, no errors

- [ ] **Step 4: Commit**

```bash
cd Resources/Template
git add package.json package-lock.json
git commit -m "feat(#1576): add MCP SDK deps, wire mcp-artifact.ts into prebuild"
```

---

## Task 4: HTML-to-plain-text extractor

**Files:**
- Create: `Resources/Template/src/lib/html-to-plain-text.ts`
- Create: `Resources/Template/src/lib/html-to-plain-text.test.ts`

**Interfaces:**
- Produces: `htmlToPlainText(html: string): string`, consumed by Task 7's `fetch_page_content` tool.

- [ ] **Step 1: Write the failing tests**

Create `Resources/Template/src/lib/html-to-plain-text.test.ts`:

```typescript
import test from "node:test";
import assert from "node:assert/strict";
import { htmlToPlainText } from "./html-to-plain-text.ts";

test("htmlToPlainText: strips tags and collapses whitespace", () => {
  const html = "<html><body><h1>Hello</h1><p>World   there</p></body></html>";
  assert.equal(htmlToPlainText(html), "Hello World there");
});

test("htmlToPlainText: drops script, style, nav, header, footer content entirely", () => {
  const html =
    "<header>Site Nav</header><nav>Menu</nav><main><p>Real content</p></main>" +
    "<script>doStuff();</script><style>.x{color:red}</style><footer>Copyright</footer>";
  assert.equal(htmlToPlainText(html), "Real content");
});

test("htmlToPlainText: decodes common named and numeric entities", () => {
  const html = "<p>Fish &amp; Chips &mdash;&#8212; &quot;quoted&quot; &#39;single&#39;</p>";
  const result = htmlToPlainText(html);
  assert.ok(result.includes("Fish & Chips"));
  assert.ok(result.includes('"quoted"'));
  assert.ok(result.includes("'single'"));
});

test("htmlToPlainText: strips HTML comments", () => {
  assert.equal(htmlToPlainText("<p>Before<!-- hidden --> After</p>"), "Before After");
});

test("htmlToPlainText: empty input yields empty string", () => {
  assert.equal(htmlToPlainText(""), "");
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Resources/Template && npx tsx --test src/lib/html-to-plain-text.test.ts`
Expected: FAIL with a module-not-found error

- [ ] **Step 3: Write the implementation**

Create `Resources/Template/src/lib/html-to-plain-text.ts`:

```typescript
/**
 * Deliberately simple HTML→plain-text extraction for the MCP `fetch_page_content` tool's
 * static-page fallback (#1576) — not a markdown-negotiation-conformant conversion, which is
 * #1247's separate job. Strips `<script>`/`<style>`/`<nav>`/`<header>`/`<footer>` elements
 * (including their content), HTML comments, then every remaining tag, decodes a small set of
 * named/numeric HTML entities, and collapses whitespace.
 */
export function htmlToPlainText(html: string): string {
  let text = html;
  for (const tag of ["script", "style", "nav", "header", "footer"]) {
    text = text.replace(new RegExp(`<${tag}\\b[^>]*>[\\s\\S]*?<\\/${tag}>`, "gi"), " ");
  }
  text = text.replace(/<!--[\s\S]*?-->/g, " ");
  text = text.replace(/<[^>]+>/g, " ");
  text = decodeEntities(text);
  return text
    .replace(/[ \t\f\v]+/g, " ")
    .replace(/\n\s*\n+/g, "\n\n")
    .trim();
}

const NAMED_ENTITIES: Record<string, string> = {
  "&amp;": "&",
  "&lt;": "<",
  "&gt;": ">",
  "&quot;": '"',
  "&#39;": "'",
  "&apos;": "'",
  "&nbsp;": " ",
  "&mdash;": "—",
  "&ndash;": "–",
};

function decodeEntities(text: string): string {
  return text
    .replace(/&(amp|lt|gt|quot|#39|apos|nbsp|mdash|ndash);/g, (m) => NAMED_ENTITIES[m] ?? m)
    .replace(/&#(\d+);/g, (_m, code: string) => String.fromCodePoint(Number(code)))
    .replace(/&#x([0-9a-fA-F]+);/g, (_m, code: string) => String.fromCodePoint(Number.parseInt(code, 16)));
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Resources/Template && npx tsx --test src/lib/html-to-plain-text.test.ts`
Expected: PASS (5 tests)

- [ ] **Step 5: Commit**

```bash
cd Resources/Template
git add src/lib/html-to-plain-text.ts src/lib/html-to-plain-text.test.ts
git commit -m "feat(#1576): add htmlToPlainText for MCP fetch_page_content fallback"
```

---

## Task 5: Search-index shaping (`src/lib/mcp-search-entries.ts`)

**Files:**
- Create: `Resources/Template/src/lib/mcp-search-entries.ts`
- Create: `Resources/Template/src/lib/mcp-search-entries.test.ts`

**Interfaces:**
- Produces: `McpSearchEntry { title: string; url: string; excerpt: string; collection: string; tags: string[]; date: string }`, `SearchableEntry { collection: string; id: string; data: Record<string, unknown>; body?: string }`, `buildSearchIndex(entries: SearchableEntry[]): McpSearchEntry[]`, `searchEntries(index: McpSearchEntry[], query: string, limit?: number): McpSearchEntry[]`. Consumed by Task 6 (build) and Task 7 (runtime filtering).

- [ ] **Step 1: Write the failing tests**

Create `Resources/Template/src/lib/mcp-search-entries.test.ts`:

```typescript
import test from "node:test";
import assert from "node:assert/strict";
import { buildSearchEntry, buildSearchIndex, searchEntries, type SearchableEntry } from "./mcp-search-entries.ts";

test("buildSearchEntry: blog entry uses title and pubDate, url is /blog/<id>", () => {
  const entry: SearchableEntry = {
    collection: "blog",
    id: "hello-world",
    data: { title: "Hello World", pubDate: "2026-01-01T00:00:00.000Z", tags: ["intro"] },
    body: "This is the body of the post, quite a bit longer than the excerpt cutoff will allow.",
  };
  const result = buildSearchEntry(entry);
  assert.ok(result);
  assert.equal(result?.title, "Hello World");
  assert.equal(result?.url, "/blog/hello-world");
  assert.equal(result?.collection, "blog");
  assert.deepEqual(result?.tags, ["intro"]);
  assert.equal(result?.date, "2026-01-01T00:00:00.000Z");
});

test("buildSearchEntry: title-less collection (notes) falls back to a body excerpt as title", () => {
  const entry: SearchableEntry = {
    collection: "notes",
    id: "note-1",
    data: { publishDate: "2026-02-01T00:00:00.000Z" },
    body: "A short note with no title field at all.",
  };
  const result = buildSearchEntry(entry);
  assert.ok(result);
  assert.equal(result?.title, "A short note with no title field at all.");
  assert.equal(result?.url, "/notes/note-1");
});

test("buildSearchEntry: unknown collection returns null", () => {
  const result = buildSearchEntry({ collection: "members", id: "x", data: {} });
  assert.equal(result, null);
});

test("buildSearchEntry: missing/invalid date returns null", () => {
  assert.equal(buildSearchEntry({ collection: "blog", id: "x", data: { title: "X" } }), null);
  assert.equal(buildSearchEntry({ collection: "blog", id: "x", data: { title: "X", pubDate: "not-a-date" } }), null);
});

test("buildSearchIndex: filters out entries with no mapping or no date", () => {
  const index = buildSearchIndex([
    { collection: "blog", id: "a", data: { title: "A", pubDate: "2026-01-01T00:00:00.000Z" } },
    { collection: "members", id: "b", data: {} },
  ]);
  assert.equal(index.length, 1);
  assert.equal(index[0].url, "/blog/a");
});

test("searchEntries: case-insensitive substring match over title/excerpt/tags", () => {
  const index = buildSearchIndex([
    { collection: "blog", id: "cats", data: { title: "All About Cats", pubDate: "2026-01-01T00:00:00.000Z" } },
    { collection: "blog", id: "dogs", data: { title: "All About Dogs", pubDate: "2026-01-02T00:00:00.000Z" } },
  ]);
  const results = searchEntries(index, "cats");
  assert.equal(results.length, 1);
  assert.equal(results[0].url, "/blog/cats");
});

test("searchEntries: empty query returns no results", () => {
  const index = buildSearchIndex([
    { collection: "blog", id: "a", data: { title: "A", pubDate: "2026-01-01T00:00:00.000Z" } },
  ]);
  assert.deepEqual(searchEntries(index, "   "), []);
});

test("searchEntries: newest first, capped at limit", () => {
  const index = buildSearchIndex([
    { collection: "blog", id: "old", data: { title: "match one", pubDate: "2026-01-01T00:00:00.000Z" } },
    { collection: "blog", id: "new", data: { title: "match two", pubDate: "2026-06-01T00:00:00.000Z" } },
  ]);
  const results = searchEntries(index, "match", 1);
  assert.equal(results.length, 1);
  assert.equal(results[0].url, "/blog/new");
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Resources/Template && npx tsx --test src/lib/mcp-search-entries.test.ts`
Expected: FAIL with a module-not-found error

- [ ] **Step 3: Write the implementation**

Create `Resources/Template/src/lib/mcp-search-entries.ts`:

```typescript
/**
 * Pure shaping logic for the MCP `search_posts` tool's build-time index (#1576) — kept free of
 * `astro:content` so it's unit-testable with plain `node:test`, matching this repo's "pure logic
 * in src/lib, import.meta.glob/astro:content stays in the endpoint" convention. The Astro
 * endpoint (`src/pages/mcp-search-index.json.ts`) calls `getCollection` and hands the results in
 * as plain `SearchableEntry` objects.
 */

export interface McpSearchEntry {
  title: string;
  url: string;
  excerpt: string;
  collection: string;
  tags: string[];
  date: string;
}

export interface SearchableEntry {
  collection: string;
  id: string;
  data: Record<string, unknown>;
  body?: string;
}

interface SearchFieldMapping {
  dateField: string;
  title(data: Record<string, unknown>): string | undefined;
}

/** Field mapping per routed collection — mirrors `markdown-mirror.ts`'s `MIRROR_FIELDS`, kept as
 *  its own copy since this module must stay free of that file's frontmatter-rendering concerns. */
const SEARCH_FIELDS: Record<string, SearchFieldMapping> = {
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

function asString(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function excerptOf(body: string | undefined, max = 160): string {
  const text = (body ?? "").replace(/\s+/g, " ").trim();
  return text.length <= max ? text : text.slice(0, max).trimEnd() + "…";
}

function urlFor(collection: string, id: string): string {
  return `/${collection}/${id}`;
}

/** Builds one search-index entry, or `null` when the collection has no known field mapping or
 *  the entry has no usable date (both treated as "not indexable" rather than an error). */
export function buildSearchEntry(entry: SearchableEntry): McpSearchEntry | null {
  const mapping = SEARCH_FIELDS[entry.collection];
  if (!mapping) return null;

  const raw = entry.data[mapping.dateField];
  const date = raw instanceof Date ? raw : typeof raw === "string" ? new Date(raw) : undefined;
  if (!date || Number.isNaN(date.getTime())) return null;

  const rawTags = entry.data.tags;
  const tags = Array.isArray(rawTags) ? rawTags.filter((t): t is string => typeof t === "string") : [];
  const title = mapping.title(entry.data) ?? excerptOf(entry.body, 60);

  return {
    title,
    url: urlFor(entry.collection, entry.id),
    excerpt: excerptOf(entry.body),
    collection: entry.collection,
    tags,
    date: date.toISOString(),
  };
}

export function buildSearchIndex(entries: SearchableEntry[]): McpSearchEntry[] {
  return entries.map(buildSearchEntry).filter((e): e is McpSearchEntry => e !== null);
}

/** Case-insensitive substring match over title/excerpt/tags, newest first, capped at `limit`
 *  (default 5). An empty/whitespace-only query returns no results rather than the whole index. */
export function searchEntries(index: McpSearchEntry[], query: string, limit = 5): McpSearchEntry[] {
  const q = query.trim().toLowerCase();
  if (!q) return [];
  return index
    .filter(
      (e) =>
        e.title.toLowerCase().includes(q) ||
        e.excerpt.toLowerCase().includes(q) ||
        e.tags.some((t) => t.toLowerCase().includes(q)),
    )
    .sort((a, b) => b.date.localeCompare(a.date))
    .slice(0, limit);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Resources/Template && npx tsx --test src/lib/mcp-search-entries.test.ts`
Expected: PASS (8 tests)

- [ ] **Step 5: Commit**

```bash
cd Resources/Template
git add src/lib/mcp-search-entries.ts src/lib/mcp-search-entries.test.ts
git commit -m "feat(#1576): add pure search-index shaping for MCP search_posts"
```

---

## Task 6: Search-index Astro endpoint

**Files:**
- Create: `Resources/Template/src/pages/mcp-search-index.json.ts`

**Interfaces:**
- Consumes: `buildSearchIndex`, `SearchableEntry` (Task 5); `ENTRY_COLLECTIONS` (`src/lib/collections.ts`); `readAnglesiteConfig` (Task 1).
- Produces: `GET` endpoint at `/mcp-search-index.json`, static JSON array of `McpSearchEntry`, consumed at request time by Task 7's `search_posts` tool via `env.ASSETS.fetch`.

- [ ] **Step 1: Write the endpoint**

Create `Resources/Template/src/pages/mcp-search-index.json.ts`:

```typescript
import type { APIContext } from "astro";
import { getCollection } from "astro:content";
import { readAnglesiteConfig } from "../../scripts/anglesite-config.ts";
import { ENTRY_COLLECTIONS } from "../lib/collections.ts";
import { buildSearchIndex, type SearchableEntry } from "../lib/mcp-search-entries.ts";

/**
 * Build-time JSON search index for the MCP `search_posts` tool (#1576) — same shape/precedent as
 * `sitemap.xml.ts`, fetched at request time by `worker/mcp-server.ts` via the `ASSETS` binding
 * and filtered server-side. Returns a plain 404 when `experimental.mcp` is off, matching every
 * other inert-when-disabled artifact this feature adds.
 */
export async function GET(_context: APIContext) {
  const enabled = readAnglesiteConfig(process.cwd()).experimental?.mcp === true;
  if (!enabled) {
    return new Response(null, { status: 404 });
  }

  const entries: SearchableEntry[] = [];
  for (const collection of ENTRY_COLLECTIONS) {
    const posts = await getCollection(collection, ({ data }) =>
      import.meta.env.PROD ? !(data as { draft?: boolean }).draft : true,
    );
    for (const post of posts) {
      entries.push({ collection, id: post.id, data: post.data as Record<string, unknown>, body: post.body });
    }
  }

  return new Response(JSON.stringify(buildSearchIndex(entries)), {
    headers: { "Content-Type": "application/json" },
  });
}
```

- [ ] **Step 2: Build and verify the endpoint is inert by default**

```bash
cd Resources/Template
npm run build
```

Then inspect: `test -f dist/mcp-search-index.json && echo EXISTS || echo ABSENT`. Since `output: "static"` Astro still materializes a response for every endpoint route, expect a file to exist containing a 404's empty body — confirm with:

```bash
cat dist/mcp-search-index.json 2>/dev/null | wc -c
```

Expected: `0` (empty body — a real 404, byte-inert) when `experimental.mcp` is unset in the test site's `anglesite.json`.

- [ ] **Step 3: Verify it serves the index when enabled**

Temporarily set `experimental.mcp: true` in the test fixture's `anglesite.json` (or a scratch site under `/tmp`), rebuild, and confirm `dist/mcp-search-index.json` now contains a JSON array. Revert the temporary config change afterward — do not commit a test site's `anglesite.json` change.

- [ ] **Step 4: Commit**

```bash
cd Resources/Template
git add src/pages/mcp-search-index.json.ts
git commit -m "feat(#1576): add build-time search index endpoint for MCP search_posts"
```

---

## Task 7: MCP server module (`worker/mcp-server.ts`)

**Files:**
- Create: `Resources/Template/worker/mcp-server.ts`

**Interfaces:**
- Consumes: `WorkerEnv`, `InboxKV` (types, `worker/worker.ts`), `McpConfigArtifact` (`worker/mcp-config.ts`), `worker/mcp-config.json` (generated artifact), `htmlToPlainText` (Task 4), `searchEntries`, `McpSearchEntry` (Task 5), `base64url` (`worker/token-signing.ts`, existing).
- Produces: `createHandleMcp(config: McpConfigArtifact)` (factory, for tests), `handleMcp` (default-config-bound handler, consumed by Task 8's `ROUTES` entry), `mcpRateLimitKey(request): Promise<string>`, `isMcpRateLimited(request, env): Promise<boolean>` (both exported for Task 9's tests).

- [ ] **Step 1: Write the module**

Create `Resources/Template/worker/mcp-server.ts`:

```typescript
/**
 * Read-only MCP server (#1576): a stateless Streamable HTTP endpoint at `/mcp`, backed by
 * Cloudflare's `createMcpHandler` (no Durable Objects — every tool here is derivable from
 * build-time-generated static artifacts). Gated behind `experimental.mcp`
 * (`worker/mcp-config.json`, generated by `scripts/mcp-artifact.ts`); returns a plain 404 when
 * off, exactly like an unclaimed route. See
 * docs/superpowers/specs/2026-08-19-site-mcp-server-design.md for the full design.
 */
import { McpServer } from "@modelcontextprotocol/server";
import { createMcpHandler } from "agents/mcp/server";
import { z } from "zod";
import { base64url } from "./token-signing.ts";
import type { WorkerEnv } from "./worker.ts";
import mcpConfigArtifact from "./mcp-config.json";
import type { McpConfigArtifact } from "./mcp-config.ts";
import { htmlToPlainText } from "../src/lib/html-to-plain-text.ts";
import { searchEntries, type McpSearchEntry } from "../src/lib/mcp-search-entries.ts";

const MCP_RATE_LIMIT_WINDOW_SECONDS = 3600;
const MCP_RATE_LIMIT_MAX_PER_WINDOW = 60;

/** Same shape as `worker.ts`'s `consentRateLimitKey`, but its own prefix — MCP tool-call traffic
 *  and IndieAuth consent-form submissions must not share a counter or a threshold. */
export async function mcpRateLimitKey(request: Request): Promise<string> {
  const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(ip));
  return `mcp-tool-call:${base64url(new Uint8Array(digest)).slice(0, 32)}`;
}

/** Same fail-closed shape as `worker.ts`'s `isConsentRateLimited`: an unbound `SOCIAL_KV` must
 *  never silently disable the limiter. A site with `experimental.mcp` on but no other social
 *  feature active still needs `SOCIAL_KV` provisioned — see `SocialWorkerProvisionCommand`. */
export async function isMcpRateLimited(request: Request, env: WorkerEnv): Promise<boolean> {
  if (!env.SOCIAL_KV) {
    console.warn(JSON.stringify({ event: "mcp.rate_limit_unavailable" }));
    return true;
  }
  const key = await mcpRateLimitKey(request);
  const raw = await env.SOCIAL_KV.get(key);
  const count = raw ? Number.parseInt(raw, 10) : 0;
  if (count >= MCP_RATE_LIMIT_MAX_PER_WINDOW) return true;
  await env.SOCIAL_KV.put(key, String(count + 1), { expirationTtl: MCP_RATE_LIMIT_WINDOW_SECONDS });
  return false;
}

/** Strips a trailing slash (except the bare root) and ensures a leading slash, so `"blog/x/"`,
 *  `"/blog/x"`, and `"/blog/x/"` all resolve to the same asset lookup. */
function normalizePagePath(path: string): string {
  const withLeadingSlash = path.startsWith("/") ? path : `/${path}`;
  return withLeadingSlash.length > 1 && withLeadingSlash.endsWith("/")
    ? withLeadingSlash.slice(0, -1)
    : withLeadingSlash;
}

async function fetchSearchIndex(env: WorkerEnv): Promise<McpSearchEntry[]> {
  if (!env.ASSETS) return [];
  const response = await env.ASSETS.fetch(new Request("https://internal.invalid/mcp-search-index.json"));
  if (!response.ok) return [];
  return (await response.json()) as McpSearchEntry[];
}

/** For a collection entry, the already-shipped `.md` mirror (`renderMarkdownMirror`,
 *  `[...slug].md.ts`) is tried first; anything else falls back to fetching the built HTML page
 *  and running `htmlToPlainText` on it. Both branches degrade to a plain "not found" string
 *  rather than throwing, matching the WebMCP tools' existing error-shape convention. */
async function fetchPageContent(path: string, env: WorkerEnv): Promise<string> {
  if (!env.ASSETS) return `Not found: ${path}`;
  const normalized = normalizePagePath(path);

  const mdResponse = await env.ASSETS.fetch(new Request(`https://internal.invalid${normalized}.md`));
  if (mdResponse.ok) return mdResponse.text();

  const htmlResponse = await env.ASSETS.fetch(new Request(`https://internal.invalid${normalized}`));
  if (!htmlResponse.ok) return `Not found: ${path}`;
  return htmlToPlainText(await htmlResponse.text());
}

function createSiteServer(env: WorkerEnv, config: McpConfigArtifact) {
  return () => {
    const server = new McpServer({ name: "anglesite-site", version: "1.0.0" });

    server.registerTool(
      "search_posts",
      {
        description: "Search this site's published posts by keyword",
        inputSchema: { query: z.string(), limit: z.number().int().min(1).max(20).optional() },
      },
      async ({ query, limit }: { query: string; limit?: number }) => {
        const index = await fetchSearchIndex(env);
        const results = searchEntries(index, query, limit ?? 5);
        if (results.length === 0) {
          return { content: [{ type: "text" as const, text: `No results for "${query}".` }] };
        }
        const text = results.map((r) => `${r.title} — ${r.url}\n${r.excerpt}`).join("\n\n");
        return { content: [{ type: "text" as const, text }] };
      },
    );

    server.registerTool(
      "fetch_page_content",
      {
        description: "Fetch the readable content of one page on this site by its path",
        inputSchema: { path: z.string() },
      },
      async ({ path }: { path: string }) => ({
        content: [{ type: "text" as const, text: await fetchPageContent(path, env) }],
      }),
    );

    server.registerTool(
      "list_feeds",
      { description: "List this site's syndication feed URLs", inputSchema: {} },
      async () => ({ content: [{ type: "text" as const, text: config.feedPaths.join("\n") }] }),
    );

    return server;
  };
}

function notFound(): Response {
  return new Response("Not Found", {
    status: 404,
    headers: { "content-type": "text/plain; charset=utf-8", "x-content-type-options": "nosniff" },
  });
}

/** Factory so tests can inject a config independent of the real build-time artifact — see
 *  `worker/worker.test.ts`. `handleMcp` below is the production handler, bound to the real
 *  generated `mcp-config.json`. */
export function createHandleMcp(config: McpConfigArtifact) {
  return async function handleMcp(request: Request, env: WorkerEnv, ctx: ExecutionContext): Promise<Response> {
    if (!config.enabled) return notFound();
    if (await isMcpRateLimited(request, env)) {
      return new Response("Too Many Requests", { status: 429 });
    }
    return createMcpHandler(createSiteServer(env, config), { route: "/mcp" })(request, env, ctx);
  };
}

export const handleMcp = createHandleMcp(mcpConfigArtifact as McpConfigArtifact);
```

- [ ] **Step 2: Type-check**

Run: `cd Resources/Template && npx astro check`
Expected: no new errors (fix any signature mismatches against the installed `@modelcontextprotocol/server@2.0.0`/`agents` versions if `registerTool`'s exact type differs from the Cloudflare docs example used here — check `node_modules/@modelcontextprotocol/server`'s `.d.ts` if so)

- [ ] **Step 3: Commit**

```bash
cd Resources/Template
git add worker/mcp-server.ts
git commit -m "feat(#1576): add MCP server module with search_posts/fetch_page_content/list_feeds"
```

---

## Task 8: Wire `/mcp` into `worker/worker.ts`

**Files:**
- Modify: `Resources/Template/worker/worker.ts`

**Interfaces:**
- Consumes: `handleMcp` (Task 7).

- [ ] **Step 1: Add the import**

In `Resources/Template/worker/worker.ts`, add near the other local imports (after `import { handleGatedFallback, handlePrivateFeed } from "./gated-content.ts";` at line 70):

```typescript
import { handleMcp } from "./mcp-server.ts";
```

- [ ] **Step 2: Add the `/mcp` route**

In the `ROUTES` array (`worker/worker.ts`, ends around line 1775 with the `/contacts/feed` entry), add a new entry right before the closing `];`:

```typescript
  {
    // Read-only MCP server (#1576): gated behind experimental.mcp, degrades to a plain 404
    // when off — see worker/mcp-server.ts.
    path: "/mcp",
    match: "exact",
    methods: ["GET", "POST", "HEAD"],
    handler: (request, env, ctx) => handleMcp(request, env, ctx),
  },
```

- [ ] **Step 3: Update the file's header doc comment**

The header comment (`worker/worker.ts:72-95`) currently says static assets are served unless "neither [social nor inbox]" is enabled. Update the relevant sentence to reflect the third/fourth enabler now composing the Worker (this mirrors the existing #1270 running-experiment enabler already noted elsewhere in Swift, not in this specific comment — just correct the "neither is enabled" framing):

Find:
```
 * Static assets are served by the [assets] binding in wrangler.toml; this Worker handles only
 * the social + inbox endpoint paths. When neither is enabled, this file is not referenced
 * (wrangler.toml has no `main` entry and deploys static-only).
```

Replace with:
```
 * Static assets are served by the [assets] binding in wrangler.toml; this Worker handles the
 * social + inbox endpoint paths, a running A/B experiment's routes, and (#1576) the read-only
 * MCP server. When none of those are enabled, this file is not referenced (wrangler.toml has no
 * `main` entry and deploys static-only).
```

- [ ] **Step 4: Regenerate the mcp-config.json artifact and build**

```bash
cd Resources/Template
npx tsx scripts/mcp-artifact.ts
npx astro check
```

Expected: no errors.

- [ ] **Step 5: Commit**

```bash
cd Resources/Template
git add worker/worker.ts
git commit -m "feat(#1576): wire /mcp route into worker.ts"
```

---

## Task 9: `worker/worker.test.ts` — MCP endpoint tests

**Files:**
- Modify: `Resources/Template/worker/worker.test.ts`

**Interfaces:**
- Consumes: `createHandleMcp`, `isMcpRateLimited`, `mcpRateLimitKey` (Task 7); `makeFakeKV`-style helper (existing convention in `worker.test.ts`).

- [ ] **Step 1: Add imports and a fake-ASSETS helper**

Add to the import block at the top of `Resources/Template/worker/worker.test.ts`:

```typescript
import { createHandleMcp, isMcpRateLimited, mcpRateLimitKey } from "./mcp-server.ts";
import type { McpConfigArtifact } from "./mcp-config.ts";
```

Add a fixture helper near the existing `makeFakeKV` (after its definition, ~line 47):

```typescript
/** A minimal `Fetcher`-shaped stub for `env.ASSETS`: maps exact request URLs (pathname only) to
 *  canned responses, everything else 404s. */
function makeFakeAssets(responses: Record<string, { status: number; body?: string }>): { fetch(request: Request): Promise<Response> } {
  return {
    async fetch(request: Request) {
      const pathname = new URL(request.url).pathname;
      const canned = responses[pathname];
      if (!canned) return new Response(null, { status: 404 });
      return new Response(canned.body ?? null, { status: canned.status });
    },
  };
}
```

- [ ] **Step 2: Write the failing tests**

Add to `Resources/Template/worker/worker.test.ts`:

```typescript
test("handleMcp: 404 when experimental.mcp is disabled", async () => {
  const handleMcp = createHandleMcp({ enabled: false, feedPaths: [] });
  const kv = makeFakeKV();
  const request = new Request("https://example.com/mcp", { method: "POST" });
  const response = await handleMcp(request, { ...testEnv, SOCIAL_KV: kv }, createExecutionContext());
  expect(response.status).toBe(404);
});

test("handleMcp: 429 when the rate limit is exceeded", async () => {
  const config: McpConfigArtifact = { enabled: true, feedPaths: ["/rss.xml"] };
  const handleMcp = createHandleMcp(config);
  const kv = makeFakeKV();
  const env = { ...testEnv, SOCIAL_KV: kv, ASSETS: makeFakeAssets({}) };
  const ip = "203.0.113.7";
  for (let i = 0; i < 60; i++) {
    const response = await handleMcp(
      new Request("https://example.com/mcp", { method: "POST", headers: { "CF-Connecting-IP": ip } }),
      env,
      createExecutionContext(),
    );
    expect(response.status).not.toBe(429);
  }
  const limited = await handleMcp(
    new Request("https://example.com/mcp", { method: "POST", headers: { "CF-Connecting-IP": ip } }),
    env,
    createExecutionContext(),
  );
  expect(limited.status).toBe(429);
});

test("isMcpRateLimited: fails closed (rate-limited) when SOCIAL_KV is unbound", async () => {
  const request = new Request("https://example.com/mcp");
  const limited = await isMcpRateLimited(request, { ...testEnv, SOCIAL_KV: undefined });
  expect(limited).toBe(true);
});

test("mcpRateLimitKey: distinct IPs produce distinct keys with the mcp-tool-call: prefix", async () => {
  const a = await mcpRateLimitKey(new Request("https://example.com/mcp", { headers: { "CF-Connecting-IP": "1.1.1.1" } }));
  const b = await mcpRateLimitKey(new Request("https://example.com/mcp", { headers: { "CF-Connecting-IP": "2.2.2.2" } }));
  expect(a).not.toBe(b);
  expect(a.startsWith("mcp-tool-call:")).toBe(true);
});

test("handleMcp: enabled with a bound ASSETS responds to a tools/list JSON-RPC request", async () => {
  const config: McpConfigArtifact = { enabled: true, feedPaths: ["/rss.xml", "/atom.xml"] };
  const handleMcp = createHandleMcp(config);
  const env = { ...testEnv, SOCIAL_KV: makeFakeKV(), ASSETS: makeFakeAssets({}) };
  const request = new Request("https://example.com/mcp", {
    method: "POST",
    headers: { "content-type": "application/json", accept: "application/json, text/event-stream" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list", params: {} }),
  });
  const response = await handleMcp(request, env, createExecutionContext());
  expect(response.status).toBe(200);
  const body = (await response.json()) as { result?: { tools?: Array<{ name: string }> } };
  const names = (body.result?.tools ?? []).map((t) => t.name);
  expect(names).toEqual(expect.arrayContaining(["search_posts", "fetch_page_content", "list_feeds"]));
});
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd Resources/Template && npm run test:worker -- worker.test.ts`
Expected: FAIL (module not found for `./mcp-server.ts` if Task 7/8 aren't merged into this run yet, or specific assertion failures if they are — since Tasks 7-8 precede this task, expect these five new tests specifically to inform whether the wiring is correct; if `Task 7/8` are already complete going into this task per plan order, run this step *before* trusting the implementation, i.e. treat any failure here as informative, not as "still expected to fail because nothing exists")

- [ ] **Step 4: Fix any failures**

If the `tools/list` test fails on response shape, inspect the actual JSON-RPC response body (log it) and adjust either the test's expectations or, if `@modelcontextprotocol/server@2.0.0`'s stateless mode requires `Accept: text/event-stream` handling differently (`responseMode` option), pass `responseMode: "json"` to `createMcpHandler` in `worker/mcp-server.ts` (Task 7, `createHandleMcp`'s `createMcpHandler(..., { route: "/mcp" })` call) to force JSON responses and simplify the test:

```typescript
return createMcpHandler(createSiteServer(env, config), { route: "/mcp", responseMode: "json" })(request, env, ctx);
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd Resources/Template && npm run test:worker -- worker.test.ts`
Expected: PASS (all tests in the file, including the 5 new ones)

- [ ] **Step 6: Commit**

```bash
cd Resources/Template
git add worker/worker.test.ts worker/mcp-server.ts
git commit -m "test(#1576): cover /mcp route, rate limiting, and tool listing"
```

---

## Task 10: MCP Server Card generation (`scripts/edge-artifacts.ts`)

**Files:**
- Modify: `Resources/Template/scripts/edge-artifacts.ts`
- Modify: `Resources/Template/scripts/edge-artifacts.test.ts`

**Interfaces:**
- Consumes: `readAnglesiteConfig` (Task 1), `readConfig` (existing, `./config`), `httpsOrigin` (existing, already used by `buildSecurityTxt`).
- Produces: `/.well-known/mcp/server-card.json` generated static file, present only when `experimental.mcp` is on.

- [ ] **Step 1: Write the failing tests**

Add to `Resources/Template/scripts/edge-artifacts.test.ts`:

```typescript
import { planMcpServerCard, buildMcpServerCard, isMcpServerCardMarkerOwned, MCP_SERVER_CARD_MARKER } from "./edge-artifacts.ts";

test("buildMcpServerCard: emits the SEP-1649/2127 shape with the /mcp transport endpoint", () => {
  const card = JSON.parse(buildMcpServerCard("https://example.com"));
  assert.equal(card.__marker, MCP_SERVER_CARD_MARKER);
  assert.equal(card.serverInfo.name, "example.com");
  assert.equal(card.transport.type, "streamable-http");
  assert.equal(card.transport.endpoint, "https://example.com/mcp");
  assert.deepEqual(card.capabilities, { tools: true, resources: false, prompts: false });
});

test("buildMcpServerCard: falls back to a generic name with no siteUrl", () => {
  const card = JSON.parse(buildMcpServerCard(undefined));
  assert.equal(card.serverInfo.name, "Anglesite site");
  assert.equal(card.transport.endpoint, "/mcp");
});

test("isMcpServerCardMarkerOwned: true for its own generated output, false otherwise", () => {
  assert.equal(isMcpServerCardMarkerOwned(buildMcpServerCard("https://example.com")), true);
  assert.equal(isMcpServerCardMarkerOwned('{"hand":"authored"}'), false);
  assert.equal(isMcpServerCardMarkerOwned(null), false);
});

test("planMcpServerCard: writes when enabled and nothing exists yet", () => {
  const plan = planMcpServerCard({ enabled: true, siteUrl: "https://example.com", existingContent: null });
  assert.equal(plan.action.kind, "write");
});

test("planMcpServerCard: no-ops when disabled and nothing exists", () => {
  const plan = planMcpServerCard({ enabled: false, siteUrl: undefined, existingContent: null });
  assert.deepEqual(plan.action, { kind: "none" });
});

test("planMcpServerCard: deletes stale marker-owned output when turned off", () => {
  const existing = buildMcpServerCard(undefined);
  const plan = planMcpServerCard({ enabled: false, siteUrl: undefined, existingContent: existing });
  assert.equal(plan.action.kind, "delete-stale");
});

test("planMcpServerCard: refuses to overwrite an unmarked hand-authored file", () => {
  const plan = planMcpServerCard({
    enabled: true,
    siteUrl: "https://example.com",
    existingContent: '{"hand":"authored"}',
  });
  assert.deepEqual(plan.action, { kind: "none" });
  assert.match(plan.note ?? "", /refusing to overwrite/);
});

test("planMcpServerCard: regenerating over its own prior marker-owned output writes again", () => {
  const previous = buildMcpServerCard("https://old.example.com");
  const plan = planMcpServerCard({ enabled: true, siteUrl: "https://new.example.com", existingContent: previous });
  assert.equal(plan.action.kind, "write");
});
```

(If `scripts/edge-artifacts.test.ts` uses `node:test`'s `test`/`node:assert/strict`'s `assert` under different local import names than shown, match whatever names the file's existing `import test from "node:test"` / `import assert from "node:assert/strict"` lines already use — this file follows the same convention as `scripts/well-known.test.ts` and `scripts/anglesite-config.test.ts`, both confirmed to use exactly those two imports.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Resources/Template && npx tsx --test scripts/edge-artifacts.test.ts`
Expected: FAIL — `planMcpServerCard`/`buildMcpServerCard`/`isMcpServerCardMarkerOwned`/`MCP_SERVER_CARD_MARKER` don't exist yet

- [ ] **Step 3: Add the import**

In `Resources/Template/scripts/edge-artifacts.ts`, add to the imports (after `import { readConfig } from "./config";` at line 20):

```typescript
import { readAnglesiteConfig } from "./anglesite-config.ts";
```

- [ ] **Step 4: Write the pure plan/build functions**

Add to `Resources/Template/scripts/edge-artifacts.ts` (a natural location is right after the `security.txt` block ends, before the `MTA-STS` block begins — keeping the file's existing per-artifact grouping):

```typescript
/**
 * MCP Server Card lifecycle (#1576) — SEP-1649/2127 draft `.well-known/mcp/server-card.json`.
 * Unlike security.txt this has no manual/disabled *mode*: it's fully derived from
 * `experimental.mcp` and `SITE_URL`, so there's nothing for an owner to hand-author — the only
 * states are "on" (write/keep) and "off" (absent, or delete stale marker-owned output).
 */
export const MCP_SERVER_CARD_MARKER = "__anglesite_generated_mcp_server_card__";

/** True when `content` parses as JSON and carries Anglesite's generated-output marker field —
 *  same ownership-detection role as `isSecurityTxtMarkerOwned`, adapted for a JSON (not
 *  first-line-comment) format. */
export function isMcpServerCardMarkerOwned(content: string | null): boolean {
  if (content === null) return false;
  try {
    const parsed = JSON.parse(content) as Record<string, unknown>;
    return parsed.__marker === MCP_SERVER_CARD_MARKER;
  } catch {
    return false;
  }
}

function mcpServerName(siteUrl: string | undefined): string {
  const origin = httpsOrigin(siteUrl);
  if (!origin) return "Anglesite site";
  try {
    return new URL(origin).hostname;
  } catch {
    return "Anglesite site";
  }
}

export function buildMcpServerCard(siteUrl: string | undefined): string {
  const origin = httpsOrigin(siteUrl);
  return (
    JSON.stringify(
      {
        __marker: MCP_SERVER_CARD_MARKER,
        serverInfo: { name: mcpServerName(siteUrl), version: "1.0.0" },
        transport: { type: "streamable-http", endpoint: `${origin ?? ""}/mcp` },
        capabilities: { tools: true, resources: false, prompts: false },
      },
      null,
      2,
    ) + "\n"
  );
}

export type McpServerCardAction = { kind: "write"; content: string } | { kind: "delete-stale" } | { kind: "none" };

export interface McpServerCardPlan {
  action: McpServerCardAction;
  note?: string;
}

export function planMcpServerCard(params: {
  enabled: boolean;
  siteUrl: string | undefined;
  existingContent: string | null;
}): McpServerCardPlan {
  const { enabled, siteUrl, existingContent } = params;
  const markerOwned = isMcpServerCardMarkerOwned(existingContent);

  if (!enabled) {
    if (markerOwned) {
      return {
        action: { kind: "delete-stale" },
        note: "experimental.mcp is off — removed the previously generated public/.well-known/mcp/server-card.json.",
      };
    }
    return { action: { kind: "none" } };
  }

  if (existingContent !== null && !markerOwned) {
    return {
      action: { kind: "none" },
      note:
        "experimental.mcp is on but public/.well-known/mcp/server-card.json already exists and wasn't " +
        "generated by Anglesite — refusing to overwrite it. Delete the file to let Anglesite generate it.",
    };
  }

  return { action: { kind: "write", content: buildMcpServerCard(siteUrl) } };
}
```

- [ ] **Step 5: Write the apply (I/O) function and wire it into `main()`**

Add, near `applySecurityTxtPlan` (~line 505-529):

```typescript
function applyMcpServerCardPlan(publicDir: string): void {
  const mcpDir = resolve(publicDir, ".well-known", "mcp");
  const filePath = resolve(mcpDir, "server-card.json");
  const existingContent = existsSync(filePath) ? readFileSync(filePath, "utf-8") : null;
  const plan = planMcpServerCard({
    enabled: readAnglesiteConfig(process.cwd()).experimental?.mcp === true,
    siteUrl: readConfig("SITE_URL"),
    existingContent,
  });
  if (plan.note) console.log(plan.note);
  switch (plan.action.kind) {
    case "write":
      mkdirSync(mcpDir, { recursive: true });
      writeFileSync(filePath, plan.action.content, "utf-8");
      console.log("Wrote public/.well-known/mcp/server-card.json");
      break;
    case "delete-stale":
      rmSync(filePath);
      break;
    case "none":
      break;
  }
}
```

In `main()` (~line 705-745), add a call right after `applyStandardSitePublicationPlan(publicDir);`:

```typescript
  applyStandardSitePublicationPlan(publicDir);
  applyMcpServerCardPlan(publicDir);
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd Resources/Template && npx tsx --test scripts/edge-artifacts.test.ts`
Expected: PASS (all tests in the file, including the 7 new ones)

- [ ] **Step 7: Verify end-to-end via `npm run prebuild`**

```bash
cd Resources/Template
npx tsx scripts/edge-artifacts.ts
test -f public/.well-known/mcp/server-card.json && echo "unexpected: card written with mcp disabled" || echo "OK: absent when disabled"
```

- [ ] **Step 8: Commit**

```bash
cd Resources/Template
git add scripts/edge-artifacts.ts scripts/edge-artifacts.test.ts
git commit -m "feat(#1576): generate MCP Server Card through the well-known claim seam"
```

---

## Task 11: Swift — `DomainConfig.experimental`

**Files:**
- Modify: `Sources/AnglesiteCore/DomainConfig.swift`
- Modify: `Tests/AnglesiteCoreTests/DomainConfigStoreTests.swift`

**Interfaces:**
- Produces: `DomainConfig.Experimental { mcp: Bool? }`, `DomainConfig.experimental: Experimental?`, consumed by Task 12.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/AnglesiteCoreTests/DomainConfigStoreTests.swift` (after the existing `"save preserves an unrecognized key nested inside the experiments section"` test, ~line 280):

```swift
@Test("save then load round-trips a config with experimental.mcp")
func saveLoadRoundTripsExperimentalMcp() throws {
    let dir = try tempSourceDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = DomainConfigStore(sourceDirectory: dir)
    let config = DomainConfig(experimental: .init(mcp: true))
    try store.save(config)
    #expect(try store.load() == config)
}

@Test("experimental section is nil by default")
func experimentalNilByDefault() throws {
    let dir = try tempSourceDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = DomainConfigStore(sourceDirectory: dir)
    #expect(try store.load().experimental == nil)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter DomainConfigStoreTests`
Expected: FAIL — build error, `DomainConfig` has no `experimental` parameter

- [ ] **Step 3: Add the `Experimental` nested struct**

In `Sources/AnglesiteCore/DomainConfig.swift`, right after the `Workers` struct (`DomainConfig.swift:194-200`), add:

```swift
    /// Template-level opt-in feature flags read from `anglesite.json`'s `experimental` section
    /// (#1576) — mirrors the TypeScript `AnglesiteExperimentalConfig`
    /// (`Resources/Template/scripts/anglesite-config.ts`) field-for-field. `mcp` gates the
    /// site's read-only MCP server (`worker/mcp-server.ts`) and its generated server card.
    public struct Experimental: Codable, Equatable, Sendable {
        public var mcp: Bool?

        public init(mcp: Bool? = nil) {
            self.mcp = mcp
        }
    }
```

- [ ] **Step 4: Add the field to `DomainConfig`**

In the top-level `DomainConfig` struct (`DomainConfig.swift:15-57`), add `experimental` after `githubPages` in both the property list and the memberwise `init`:

```swift
public struct DomainConfig: Equatable, Sendable {
    public var version: Int
    public var domain: Domain?
    public var dns: DNS?
    public var edge: Edge?
    public var email: Email?
    public var workers: Workers?
    public var experiments: Experiments?
    public var deployTarget: String?
    public var githubPages: GitHubPages?
    public var experimental: Experimental?

    public init(
        version: Int = 1,
        domain: Domain? = nil,
        dns: DNS? = nil,
        edge: Edge? = nil,
        email: Email? = nil,
        workers: Workers? = nil,
        experiments: Experiments? = nil,
        deployTarget: String? = nil,
        githubPages: GitHubPages? = nil,
        experimental: Experimental? = nil
    ) {
        self.version = version
        self.domain = domain
        self.dns = dns
        self.edge = edge
        self.email = email
        self.workers = workers
        self.experiments = experiments
        self.deployTarget = deployTarget
        self.githubPages = githubPages
        self.experimental = experimental
    }
    ...
```

(Keep every other member of the struct — this only adds the one new property/parameter at the end.)

- [ ] **Step 5: Wire it through `Codable`**

In the `extension DomainConfig: Codable` block (`DomainConfig.swift:286-316`), add `case experimental` to `CodingKeys`, a decode line, and an encode line:

```swift
extension DomainConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case version, domain, dns, edge, email, workers, experiments, deployTarget, githubPages, experimental
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        domain = try container.decodeIfPresent(Domain.self, forKey: .domain)
        dns = try container.decodeIfPresent(DNS.self, forKey: .dns)
        edge = try container.decodeIfPresent(Edge.self, forKey: .edge)
        email = try container.decodeIfPresent(Email.self, forKey: .email)
        workers = try container.decodeIfPresent(Workers.self, forKey: .workers)
        experiments = try container.decodeIfPresent(Experiments.self, forKey: .experiments)
        deployTarget = try container.decodeIfPresent(String.self, forKey: .deployTarget)
        githubPages = try container.decodeIfPresent(GitHubPages.self, forKey: .githubPages)
        experimental = try container.decodeIfPresent(Experimental.self, forKey: .experimental)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(domain, forKey: .domain)
        try container.encodeIfPresent(dns, forKey: .dns)
        try container.encodeIfPresent(edge, forKey: .edge)
        try container.encodeIfPresent(email, forKey: .email)
        try container.encodeIfPresent(workers, forKey: .workers)
        try container.encodeIfPresent(experiments, forKey: .experiments)
        try container.encodeIfPresent(deployTarget, forKey: .deployTarget)
        try container.encodeIfPresent(githubPages, forKey: .githubPages)
        try container.encodeIfPresent(experimental, forKey: .experimental)
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --package-path . --filter DomainConfigStoreTests`
Expected: PASS (all tests in the suite, including the 2 new ones)

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteCore/DomainConfig.swift Tests/AnglesiteCoreTests/DomainConfigStoreTests.swift
git commit -m "feat(#1576): decode experimental.mcp in DomainConfig"
```

---

## Task 12: Swift — `DeployCoordinator.resolveMCPEnabled`

**Files:**
- Modify: `Sources/AnglesiteCore/DeployCoordinator.swift`
- Modify: `Tests/AnglesiteCoreTests/DeployCoordinatorTests.swift`

**Interfaces:**
- Consumes: `DomainConfig.experimental` (Task 11).
- Produces: `DeployCoordinator.resolveMCPEnabled(sourceDirectory: URL) -> Bool`, consumed by Tasks 15-16.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/AnglesiteCoreTests/DeployCoordinatorTests.swift` (after the existing `resolveRunningExperiments` tests, ~line 188):

```swift
// MARK: - resolveMCPEnabled (#1576)

@Test("resolveMCPEnabled is true only when anglesite.json declares experimental.mcp: true")
func resolveMCPEnabledReadsFlag() throws {
    let dir = try temporaryDirectory()
    #expect(!DeployCoordinator.resolveMCPEnabled(sourceDirectory: dir))
    let store = DomainConfigStore(sourceDirectory: dir)
    try store.save(DomainConfig(experimental: .init(mcp: true)))
    #expect(DeployCoordinator.resolveMCPEnabled(sourceDirectory: dir))
}

@Test("resolveMCPEnabled is false with no anglesite.json at all")
func resolveMCPEnabledEmptyByDefault() throws {
    let dir = try temporaryDirectory()
    #expect(!DeployCoordinator.resolveMCPEnabled(sourceDirectory: dir))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter DeployCoordinatorTests`
Expected: FAIL — build error, `resolveMCPEnabled` doesn't exist

- [ ] **Step 3: Implement it**

In `Sources/AnglesiteCore/DeployCoordinator.swift`, right after `resolveRunningExperiments` (~line 250-260), add:

```swift
    /// Whether `Source/anglesite.json` declares `experimental.mcp: true` (#1576) — a fourth,
    /// independent enabler of Worker composition alongside an active catalog worker, inbox
    /// capture, and a running experiment (see `WorkerComposition.generateWranglerToml`'s
    /// `composesWorker`). Mirrors `resolveRunningExperiments`'s "read the declared config,
    /// default to the inert case on any failure" shape.
    public static func resolveMCPEnabled(sourceDirectory: URL) -> Bool {
        let domainConfig = (try? DomainConfigStore(sourceDirectory: sourceDirectory).load()) ?? DomainConfig()
        return domainConfig.experimental?.mcp ?? false
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter DeployCoordinatorTests`
Expected: PASS (all tests in the suite, including the 2 new ones)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/DeployCoordinator.swift Tests/AnglesiteCoreTests/DeployCoordinatorTests.swift
git commit -m "feat(#1576): add DeployCoordinator.resolveMCPEnabled"
```

---

## Task 13: Swift — `WorkerComposition` `mcpEnabled` wiring

**Files:**
- Modify: `Sources/AnglesiteCore/WorkerComposition.swift`
- Modify: `Tests/AnglesiteCoreTests/WorkerCompositionTests.swift`

**Interfaces:**
- Produces: `WorkerComposition.generateWranglerToml(..., mcpEnabled: Bool = false)`, `WorkerComposition.mcpRouteClaim: WorkerRouteClaim`, consumed by Task 14.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/AnglesiteCoreTests/WorkerCompositionTests.swift` (after `staticOnly()`, ~line 53):

```swift
    @Test("mcpEnabled alone composes a Worker on an otherwise static-only site and claims /mcp")
    func mcpEnabledComposesWorker() throws {
        let toml = try WorkerComposition.generateWranglerToml(
            siteName: "my-site",
            workers: [],
            mcpEnabled: true
        )
        #expect(toml.contains("main = \"worker/worker.ts\""))
        #expect(toml.contains("binding = \"ASSETS\""))
        #expect(toml.contains("run_worker_first = [\"/mcp\"]"))
    }

    @Test("mcpEnabled false on an otherwise static-only site composes no Worker")
    func mcpDisabledStaysStatic() throws {
        let toml = try WorkerComposition.generateWranglerToml(siteName: "my-site", workers: [])
        #expect(!toml.contains("main = \"worker/worker.ts\""))
        #expect(!toml.contains("run_worker_first"))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter WorkerCompositionTests`
Expected: FAIL — build error, `generateWranglerToml` has no `mcpEnabled` parameter

- [ ] **Step 3: Add the route claim constant**

In `Sources/AnglesiteCore/WorkerComposition.swift`, right after `inboxCaptureRouteClaim` (`WorkerComposition.swift:87-92`), add:

```swift
    /// Route claim for the read-only MCP server (#1576) — same static-let pattern as
    /// `inboxCaptureRouteClaim` above, since `/mcp` is app-owned (not sourced from the
    /// `@dwk/workers` catalog).
    public static let mcpRouteClaim = WorkerRouteClaim(
        path: "/mcp",
        match: .exact,
        methods: ["GET", "POST", "HEAD"],
        handler: "mcp"
    )
```

- [ ] **Step 4: Add the `mcpEnabled` parameter**

Change the `generateWranglerToml` signature (`WorkerComposition.swift:219-232`) from:

```swift
    public static func generateWranglerToml(
        siteName: String,
        workers: [WorkerDescriptor],
        routeClaims: [WorkerRouteClaim] = [],
        resources: ProvisionedResources = .init(),
        inboxCaptureEnabled: Bool = false,
        inboxKVNamespaceID: String? = nil,
        siteURL: String? = nil,
        displayName: String? = nil,
        activityPubActorType: String? = nil,
        moderators: [String]? = nil,
        apUsername: String? = nil,
        experiments: [DomainConfig.Experiments.Experiment] = []
    ) throws -> String {
```

to:

```swift
    public static func generateWranglerToml(
        siteName: String,
        workers: [WorkerDescriptor],
        routeClaims: [WorkerRouteClaim] = [],
        resources: ProvisionedResources = .init(),
        inboxCaptureEnabled: Bool = false,
        inboxKVNamespaceID: String? = nil,
        siteURL: String? = nil,
        displayName: String? = nil,
        activityPubActorType: String? = nil,
        moderators: [String]? = nil,
        apUsername: String? = nil,
        experiments: [DomainConfig.Experiments.Experiment] = [],
        mcpEnabled: Bool = false
    ) throws -> String {
```

- [ ] **Step 5: Fold `mcpEnabled` into `effectiveClaims` and `composesWorker`**

Find the `effectiveClaims` block (`WorkerComposition.swift:236-239`):

```swift
        var effectiveClaims = routeClaims
        if inboxCaptureEnabled {
            effectiveClaims.append(inboxCaptureRouteClaim)
        }
```

Change to:

```swift
        var effectiveClaims = routeClaims
        if inboxCaptureEnabled {
            effectiveClaims.append(inboxCaptureRouteClaim)
        }
        if mcpEnabled {
            effectiveClaims.append(mcpRouteClaim)
        }
```

Find the `composesWorker` line (`WorkerComposition.swift:317`):

```swift
        let composesWorker = hasSocialFeatures || inboxCaptureEnabled || hasRunningExperiment
```

Change to:

```swift
        let composesWorker = hasSocialFeatures || inboxCaptureEnabled || hasRunningExperiment || mcpEnabled
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --package-path . --filter WorkerCompositionTests`
Expected: PASS (all tests in the suite, including the 2 new ones)

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteCore/WorkerComposition.swift Tests/AnglesiteCoreTests/WorkerCompositionTests.swift
git commit -m "feat(#1576): compose Worker + claim /mcp when mcpEnabled"
```

---

## Task 14: Swift — `SocialWorkerProvisionCommand` `mcpEnabled` threading + `SOCIAL_KV` gate

**Files:**
- Modify: `Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift`
- Modify: `Tests/AnglesiteCoreTests/SocialWorkerProvisionCommandTests.swift`

**Interfaces:**
- Consumes: `WorkerComposition.generateWranglerToml(..., mcpEnabled:)` (Task 13).
- Produces: `SocialWorkerProvisionCommand.provision(..., mcpEnabled: Bool = false)`, consumed by Tasks 15-16.

- [ ] **Step 1: Write the failing test**

Add to `Tests/AnglesiteCoreTests/SocialWorkerProvisionCommandTests.swift`, mirroring `provisionsV2Worker()` (~line 67) and the running-experiment-on-a-static-site test (~line 111) — a static-only site (`workers: []`) that provisions `SOCIAL_KV` purely because `mcpEnabled: true`:

```swift
    @Test("mcpEnabled alone (no active workers) provisions SOCIAL_KV and composes the Worker")
    func mcpEnabledProvisionsSocialKV() async throws {
        let site = try temporaryDirectory()
        let recorder = WranglerRecorder([
            ["kv", "namespace", "create", "my-site-social", "--json"]: .init(stdout: #"{"result":{"id":"kv-id"}}"#, stderr: "", exitCode: 0),
        ])
        let deployer = DeployRecorder(result: .succeeded(url: URL(string: "https://my-site.example.workers.dev")!, duration: 1))
        let command = SocialWorkerProvisionCommand(tokenSource: { "token" }, runner: recorder.runner, deployer: deployer.deployer)

        let result = await command.provision(
            siteID: "site-1", siteDirectory: site, siteName: "my-site", workers: [],
            mcpEnabled: true
        )

        guard case .succeeded(_, let resources, _) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(resources.kvNamespaceID == "kv-id")
        let toml = try String(contentsOf: site.appendingPathComponent("wrangler.toml"), encoding: .utf8)
        #expect(toml.contains("main = \"worker/worker.ts\""))
        #expect(toml.contains("binding = \"SOCIAL_KV\""))
        #expect(toml.contains("run_worker_first = [\"/mcp\"]"))
    }

    @Test("mcpEnabled false with no workers provisions nothing")
    func mcpDisabledProvisionsNothing() async throws {
        let site = try temporaryDirectory()
        let recorder = WranglerRecorder([:])
        let deployer = DeployRecorder(result: .succeeded(url: URL(string: "https://my-site.example.workers.dev")!, duration: 1))
        let command = SocialWorkerProvisionCommand(tokenSource: { "token" }, runner: recorder.runner, deployer: deployer.deployer)

        let result = await command.provision(siteID: "site-1", siteDirectory: site, siteName: "my-site", workers: [])

        guard case .succeeded = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(await recorder.arguments.isEmpty)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter SocialWorkerProvisionCommandTests`
Expected: FAIL — build error, `provision` has no `mcpEnabled` parameter

- [ ] **Step 3: Add the `mcpEnabled` parameter to `provision`**

In `Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift`, change the `provision` signature (`SocialWorkerProvisionCommand.swift:153-218`) by appending after `experiments`:

```swift
    public func provision(
        siteID: String,
        siteDirectory: URL,
        siteName: String,
        workers: [WorkerDescriptor],
        routeClaims: [WorkerRouteClaim] = [],
        knownResources: WorkerComposition.ProvisionedResources = .init(),
        siteURL: String? = nil,
        displayName: String? = nil,
        apUsername: String? = nil,
        acknowledgesPaidPlan: Bool = false,
        wellKnownDynamicClaims: [WorkerRouteClaims.OwnedClaim] = [],
        inboxCaptureEnabled: Bool = false,
        activityPubActorType: String? = nil,
        moderators: [String]? = nil,
        experiments: [DomainConfig.Experiments.Experiment] = [],
        mcpEnabled: Bool = false
    ) async -> Result {
```

- [ ] **Step 4: Gate `SOCIAL_KV` provisioning on `mcpEnabled` too**

Find the KV-provisioning gate (`SocialWorkerProvisionCommand.swift:290`):

```swift
        if workers.contains(where: { $0.resources.needsKV }) {
```

Change to:

```swift
        if workers.contains(where: { $0.resources.needsKV }) || mcpEnabled {
```

- [ ] **Step 5: Thread `mcpEnabled` through `persistConfig`**

Add `mcpEnabled: Bool = false` to `persistConfig`'s signature (`SocialWorkerProvisionCommand.swift:641-654`):

```swift
    private func persistConfig(
        siteDirectory: URL,
        siteName: String,
        workers: [WorkerDescriptor],
        routeClaims: [WorkerRouteClaim],
        resources: WorkerComposition.ProvisionedResources,
        siteURL: String? = nil,
        displayName: String? = nil,
        apUsername: String? = nil,
        inboxCaptureEnabled: Bool = false,
        activityPubActorType: String? = nil,
        moderators: [String]? = nil,
        experiments: [DomainConfig.Experiments.Experiment] = [],
        mcpEnabled: Bool = false
    ) -> Result? {
```

and add `mcpEnabled: mcpEnabled` to its internal `generateWranglerToml(...)` call (`SocialWorkerProvisionCommand.swift:655-668`):

```swift
            let toml = try WorkerComposition.generateWranglerToml(
                siteName: siteName,
                workers: workers,
                routeClaims: routeClaims,
                resources: resources,
                inboxCaptureEnabled: inboxCaptureEnabled,
                inboxKVNamespaceID: resources.inboxKVNamespaceID,
                siteURL: siteURL,
                displayName: displayName,
                activityPubActorType: activityPubActorType,
                moderators: moderators,
                apUsername: apUsername,
                experiments: experiments,
                mcpEnabled: mcpEnabled
            )
```

Then, at every call site of `persistConfig(...)` inside `provision(...)` (each one currently ends its argument list with `experiments: experiments`, per the ~7 call sites spanning the D1/KV/R2/inboxCapture/ActivityPub-key provisioning branches), add `mcpEnabled: mcpEnabled` immediately after `experiments: experiments,`. Do this with a scoped `replace_all` since the pattern is identical at every site:

```bash
grep -c "experiments: experiments" Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift
```

Note the count `N` this prints, then use the Edit tool with `replace_all: true` to change every occurrence of:

```
experiments: experiments
```

to:

```
experiments: experiments, mcpEnabled: mcpEnabled
```

in `Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift` **only within `persistConfig` call sites** — after editing, re-run the same `grep -c` command against `"mcpEnabled: mcpEnabled"` and confirm the count matches `N` exactly (this also touches `persistConfig`'s own signature default and its internal `generateWranglerToml` call from Step 5 above if those also contain the literal substring `experiments: experiments` — inspect the diff and revert/adjust any unintended match, e.g. the signature line itself reads `experiments: [DomainConfig.Experiments.Experiment] = []` which does **not** contain the exact substring `experiments: experiments`, so it's safe, but verify with `git diff` before committing).

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --package-path . --filter SocialWorkerProvisionCommandTests`
Expected: PASS (all tests in the suite, including the 2 new ones, and no regressions in the ~30 pre-existing tests)

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift Tests/AnglesiteCoreTests/SocialWorkerProvisionCommandTests.swift
git commit -m "feat(#1576): thread mcpEnabled through provisioning, gate SOCIAL_KV on it"
```

---

## Task 15: Swift — `DeployModel.swift` call site

**Files:**
- Modify: `Sources/AnglesiteApp/DeployModel.swift`

**Interfaces:**
- Consumes: `DeployCoordinator.resolveMCPEnabled` (Task 12), `SocialWorkerProvisionCommand.provision(..., mcpEnabled:)` (Task 14).

- [ ] **Step 1: Add the resolve + pass-through**

In `Sources/AnglesiteApp/DeployModel.swift` (~line 949-969), change:

```swift
        let runningExperiments = DeployCoordinator.resolveRunningExperiments(sourceDirectory: siteDirectory)
        let provisionResult = await socialCommand.provision(
            siteID: siteID,
            siteDirectory: siteDirectory,
            siteName: workerSiteName,
            workers: workers,
            routeClaims: routeClaims.map(\.claim),
            knownResources: settings.provisionedWorkerResources ?? .init(),
            siteURL: siteURL,
            displayName: settings.displayName,
            apUsername: apUsername,
            acknowledgesPaidPlan: acknowledgesPaidPlan,
            inboxCaptureEnabled: settings.inboxCaptureEnabled ?? false,
            activityPubActorType: isHostedCommunity ? "Group" : nil,
            moderators: isHostedCommunity ? settings.moderators : nil,
            experiments: runningExperiments
        )
```

to:

```swift
        let runningExperiments = DeployCoordinator.resolveRunningExperiments(sourceDirectory: siteDirectory)
        let mcpEnabled = DeployCoordinator.resolveMCPEnabled(sourceDirectory: siteDirectory)
        let provisionResult = await socialCommand.provision(
            siteID: siteID,
            siteDirectory: siteDirectory,
            siteName: workerSiteName,
            workers: workers,
            routeClaims: routeClaims.map(\.claim),
            knownResources: settings.provisionedWorkerResources ?? .init(),
            siteURL: siteURL,
            displayName: settings.displayName,
            apUsername: apUsername,
            acknowledgesPaidPlan: acknowledgesPaidPlan,
            inboxCaptureEnabled: settings.inboxCaptureEnabled ?? false,
            activityPubActorType: isHostedCommunity ? "Group" : nil,
            moderators: isHostedCommunity ? settings.moderators : nil,
            experiments: runningExperiments,
            mcpEnabled: mcpEnabled
        )
```

- [ ] **Step 2: Build**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: builds clean

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteApp/DeployModel.swift
git commit -m "feat(#1576): resolve and thread mcpEnabled in DeployModel"
```

---

## Task 16: Swift — `SiteOperations.swift` call site

**Files:**
- Modify: `Sources/AnglesiteCore/SiteOperations.swift`

**Interfaces:**
- Consumes: `DeployCoordinator.resolveMCPEnabled` (Task 12), `SocialWorkerProvisionCommand.provision(..., mcpEnabled:)` (Task 14).

- [ ] **Step 1: Add the resolve + pass-through**

In `Sources/AnglesiteCore/SiteOperations.swift` (~line 155-176), change:

```swift
        let runningExperiments = DeployCoordinator.resolveRunningExperiments(sourceDirectory: siteDirectory)
        let provisionResult = await factory.socialWorkerProvision().provision(
            siteID: site.id,
            siteDirectory: siteDirectory,
            siteName: workerSiteName,
            workers: workers,
            routeClaims: routeClaims.map(\.claim),
            knownResources: settings.provisionedWorkerResources ?? .init(),
            wellKnownDynamicClaims: WorkerRouteClaims.wellKnownClaims(routeClaims),
            activityPubActorType: isHostedCommunity ? "Group" : nil,
            moderators: isHostedCommunity ? settings.moderators : nil,
            experiments: runningExperiments
        )
```

to:

```swift
        let runningExperiments = DeployCoordinator.resolveRunningExperiments(sourceDirectory: siteDirectory)
        let mcpEnabled = DeployCoordinator.resolveMCPEnabled(sourceDirectory: siteDirectory)
        let provisionResult = await factory.socialWorkerProvision().provision(
            siteID: site.id,
            siteDirectory: siteDirectory,
            siteName: workerSiteName,
            workers: workers,
            routeClaims: routeClaims.map(\.claim),
            knownResources: settings.provisionedWorkerResources ?? .init(),
            wellKnownDynamicClaims: WorkerRouteClaims.wellKnownClaims(routeClaims),
            activityPubActorType: isHostedCommunity ? "Group" : nil,
            moderators: isHostedCommunity ? settings.moderators : nil,
            experiments: runningExperiments,
            mcpEnabled: mcpEnabled
        )
```

- [ ] **Step 2: Build and run the core test suite**

Run: `swift build --package-path . && swift test --package-path . --filter AnglesiteCoreTests`
Expected: builds and tests pass clean

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteCore/SiteOperations.swift
git commit -m "feat(#1576): resolve and thread mcpEnabled in SiteOperations"
```

---

## Task 17: `pre-deploy-check.ts` — `experimental.mcp` validation

**Files:**
- Modify: `Resources/Template/scripts/pre-deploy-check.ts`
- Modify: `Resources/Template/scripts/pre-deploy-check.test.ts`

**Interfaces:**
- Produces: `checkExperimentalSection(raw: string | null): Issue[]`, wired into the same scan orchestration `checkAnglesiteConfig` and `checkExperimentsSection` are already called from.

- [ ] **Step 1: Locate the `Issue`/category type**

Run: `grep -n "category:\|type IssueCategory\|interface Issue" Resources/Template/scripts/pre-deploy-check.ts | head -20`

Find the union type backing `Issue["category"]` (it must currently include `"anglesite-config-invalid"` and `"experiments-invalid"`, per the existing `checkAnglesiteConfig`/experiments-section validator). Note its exact declaration location for Step 3.

- [ ] **Step 2: Write the failing tests**

Add to `Resources/Template/scripts/pre-deploy-check.test.ts` (matching whatever `test`/`assert` import names the file already uses — confirm at the top of the file before writing):

```typescript
import { checkExperimentalSection } from "./pre-deploy-check.ts";

test("checkExperimentalSection: no issues when anglesite.json is absent", () => {
  assert.deepEqual(checkExperimentalSection(null), []);
});

test("checkExperimentalSection: no issues when experimental is absent", () => {
  assert.deepEqual(checkExperimentalSection(JSON.stringify({ version: 1 })), []);
});

test("checkExperimentalSection: no issues when experimental.mcp is a boolean", () => {
  assert.deepEqual(checkExperimentalSection(JSON.stringify({ version: 1, experimental: { mcp: true } })), []);
  assert.deepEqual(checkExperimentalSection(JSON.stringify({ version: 1, experimental: { mcp: false } })), []);
});

test("checkExperimentalSection: reports experimental.mcp not a boolean", () => {
  const issues = checkExperimentalSection(JSON.stringify({ version: 1, experimental: { mcp: "yes" } }));
  assert.equal(issues.length, 1);
  assert.equal(issues[0].severity, "error");
  assert.match(issues[0].message, /"experimental\.mcp" must be a boolean/);
});

test("checkExperimentalSection: reports experimental not an object", () => {
  const issues = checkExperimentalSection(JSON.stringify({ version: 1, experimental: "nope" }));
  assert.equal(issues.length, 1);
  assert.match(issues[0].message, /"experimental" must be an object/);
});

test("checkExperimentalSection: malformed JSON yields no issues (checkAnglesiteConfig's job)", () => {
  assert.deepEqual(checkExperimentalSection("not json {"), []);
});
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd Resources/Template && npx tsx --test scripts/pre-deploy-check.test.ts`
Expected: FAIL — `checkExperimentalSection` doesn't exist

- [ ] **Step 4: Extend the category union type (if it exists as a standalone declaration)**

Using the location found in Step 1, add `"experimental-invalid"` to whatever union backs `Issue["category"]` (e.g. `type IssueCategory = "anglesite-config-invalid" | "experiments-invalid" | ... | "experimental-invalid"`). If `category` is instead typed as a plain `string` with no union restriction, skip this step — no type change needed.

- [ ] **Step 5: Implement `checkExperimentalSection`**

Add to `Resources/Template/scripts/pre-deploy-check.ts`, near the existing `experiments`-section validator:

```typescript
/**
 * Validates `anglesite.json`'s `experimental.mcp` field when present (#1576): the flag gates a
 * real unauthenticated request-handling surface (the site's MCP server), so a malformed value
 * should fail loudly rather than the tolerant reader silently treating it as falsy. Mirrors
 * `checkAnglesiteConfig`'s shallow-validation shape; only runs meaningfully once that check has
 * already confirmed the document is well-formed JSON.
 */
export function checkExperimentalSection(raw: string | null): Issue[] {
  if (raw === null) return [];

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return []; // checkAnglesiteConfig already reports invalid JSON.
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) return [];

  const experimental = (parsed as Record<string, unknown>).experimental;
  if (experimental === undefined) return [];
  if (typeof experimental !== "object" || experimental === null || Array.isArray(experimental)) {
    return [
      {
        severity: "error",
        category: "experimental-invalid",
        message: 'anglesite.json\'s "experimental" must be an object.',
        file: "anglesite.json",
        remediation: 'Wrap experimental flags in an object, e.g. "experimental": { "mcp": true }.',
      },
    ];
  }

  const mcp = (experimental as Record<string, unknown>).mcp;
  if (mcp !== undefined && typeof mcp !== "boolean") {
    return [
      {
        severity: "error",
        category: "experimental-invalid",
        message: `anglesite.json's "experimental.mcp" must be a boolean (found ${typeof mcp}).`,
        file: "anglesite.json",
        remediation: 'Set "experimental.mcp" to true or false, or remove it to leave the feature off.',
      },
    ];
  }

  return [];
}
```

- [ ] **Step 6: Wire it into the scan orchestration**

Find where `checkAnglesiteConfig(anglesiteConfigContent)` is called in the main scan function (near `pre-deploy-check.ts:1120` per prior research) and add a call to `checkExperimentalSection` alongside it, pushing its results into the same accumulated issues array the existing calls use. Match the exact accumulation pattern already used for `checkAnglesiteConfig`'s and the experiments-section validator's results (e.g. `issues.push(...checkAnglesiteConfig(...))`).

- [ ] **Step 7: Run tests to verify they pass**

Run: `cd Resources/Template && npx tsx --test scripts/pre-deploy-check.test.ts`
Expected: PASS (all tests in the file, including the 6 new ones)

- [ ] **Step 8: Commit**

```bash
cd Resources/Template
git add scripts/pre-deploy-check.ts scripts/pre-deploy-check.test.ts
git commit -m "feat(#1576): validate experimental.mcp shape in pre-deploy check"
```

---

## Task 18: Full-suite verification

**Files:** none (verification only)

- [ ] **Step 1: Full template test suite**

```bash
cd Resources/Template
npm run build:ci
npm test
npm run test:worker
```

Expected: all pass, `build:ci`'s strict pre-deploy check reports no new failures.

- [ ] **Step 2: Full Swift test suite**

```bash
swift test --package-path .
```

Expected: all suites pass (note: per `docs/testing-macos-app.md`, run this with the correct `DEVELOPER_DIR` for Xcode 27 if the default toolchain resolves elsewhere).

- [ ] **Step 3: App build**

```bash
scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
```

Expected: builds clean.

- [ ] **Step 4: Manual Agent Readiness verification**

Deploy a test site with `experimental.mcp: true` set in its `anglesite.json`, then run Cloudflare's Agent Readiness scan (`isitagentready.com` or the equivalent API) against the deployed URL and confirm `mcpServerCard` now passes — matching how #1481/#1489 verified `linkHeaders` (design doc's Testing section). Also manually connect an MCP client (or `curl` a `tools/list` JSON-RPC request) to `https://<test-site>/mcp` and confirm all three tools are listed and callable. This step is not automatable in CI and should be done once before opening the PR, and noted as done (or not run, with reason) in the PR's Test plan section per `CONTRIBUTING.md`.

- [ ] **Step 5: Re-read `CONTRIBUTING.md`'s "Commits and pull requests" section**

Before opening the PR, re-check the PR body against `.github/PULL_REQUEST_TEMPLATE.md`'s actual headings (Summary, Paired PR check, Test plan) — this repo's `CLAUDE.md` explicitly warns against falling back to a generic Summary/Test-plan shape. Note in the PR body the deliberate deviation from #1576's literal "flip `anglesiteProvides` to `true`" instruction (see Global Constraints above and design doc §9).
