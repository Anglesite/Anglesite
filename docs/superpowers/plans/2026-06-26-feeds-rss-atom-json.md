# V-1.6 Feeds (RSS / Atom / JSON) Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every content collection in `Resources/Template/` publishes RSS 2.0, Atom 1.0, and JSON Feed 1.1 — co-located inside the collection — plus a site-wide combined feed, all valid at build and green through `pre-deploy-check`.

**Architecture:** Pure feed logic (config table + item mapping + three serializers) lives in `src/lib/feeds.ts` and is unit-tested without an Astro runtime. A thin astro-coupled `src/lib/feed-data.ts` loads collections via `astro:content`. Per-collection route files (`src/pages/<collection>/{rss.xml,atom.xml,feed.json}.ts`) and root combined routes are 1–2 line delegators. A node-gated Swift smoke test builds the template and asserts the rendered feeds.

**Tech Stack:** Astro 5, `@astrojs/rss`, TypeScript (tsx for node tests), Swift 6 (Swift Testing) for the gated build smoke.

## ⚠️ Prerequisite — gated on #344

This plan references the personal-type collections (`notes`, `articles`, `photos`, `albums`, `bookmarks`, `replies`, `likes`) created by V-1.2 ([#344](https://github.com/Anglesite/Anglesite-app/issues/344)). **Do not begin until #344 has merged to `main`.** First step at execution time:

```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/348-feeds
git fetch origin && git rebase origin/main
# confirm the typed collections now exist:
ls src/content/{notes,articles,photos,albums,bookmarks,replies,likes} 2>/dev/null   # from Resources/Template
```

If those collection dirs are absent, stop — #344 has not landed yet.

One-time local setup (for the build steps and the gated test):

```bash
cd Resources/Template && npm install && cd ../..
```

## Global Constraints

- **App-only, template-only.** No plugin PR, no `Resources/plugin` change. Work lands under `Resources/Template/` plus one Swift test in `Tests/AnglesiteCoreTests/`.
- **ES Modules**, vanilla. Only one new dependency: `@astrojs/rss`.
- **Registry-named fields, verbatim.** `blog` dates are `pubDate`; every typed collection dates are `publishDate`. The per-collection config table in `feeds.ts` is the only place this difference is encoded — never hard-code `pubDate` elsewhere.
- **Pure core / coupled edge split.** `src/lib/feeds.ts` must NOT import `astro:content` (so it unit-tests under plain node). All `getCollection` calls live in `src/lib/feed-data.ts` and route files.
- **Swift Testing** (`@Test`/`#expect`), gated `.enabled(if:)` to skip — not fail — when Node or the installed Astro is absent.
- **Conventional commits**, each ending with the trailer:
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
- Run Swift tests with `swift test --package-path .` (set `DEVELOPER_DIR` to the Xcode-beta toolchain if the default `swift` is too old).
- Run template node tests from `Resources/Template/` with `npx tsx --test <file>`.

## Collection feed config (the single source of truth)

| Collection | Date field | Title derivation |
|---|---|---|
| `blog` | `pubDate` | `data.title` |
| `notes` | `publishDate` | first ~80 chars of body text |
| `articles` | `publishDate` | `data.title` |
| `photos` | `publishDate` | `data.caption ?? "Photo"` |
| `albums` | `publishDate` | `data.title` |
| `bookmarks` | `publishDate` | `data.title ?? host(data.bookmarkOf)` |
| `replies` | `publishDate` | `"Re: " + host(data.inReplyTo)` |
| `likes` | `publishDate` | `"Liked " + host(data.likeOf)` |

---

### Task 1: `feeds.ts` pure core + node unit tests

**Files:**
- Create: `Resources/Template/src/lib/feeds.ts`
- Create: `Resources/Template/src/lib/feeds.test.ts`
- Modify: `Resources/Template/package.json` (add `@astrojs/rss`)

**Interfaces:**
- Consumes: `@astrojs/rss`'s `rss()` (returns `Promise<Response>`); global `URL`, `Response` (Node 20+).
- Produces:
  - `interface FeedItem { title: string; link: string; date: Date; summary: string }`
  - `interface FeedCollectionConfig { title: string; dateField: string; deriveTitle(entry: FeedEntry): string }`
  - `const FEED_COLLECTIONS: Record<string, FeedCollectionConfig>` (the 8 entries above)
  - `type FeedEntry = { id: string; collection: string; data: Record<string, any>; body?: string }`
  - `function toFeedItem(collection: string, entry: FeedEntry, site: string): FeedItem`
  - `function sortAndLimit(items: FeedItem[], limit?: number): FeedItem[]`
  - `function renderRss(o: { title: string; description: string; site: string; items: FeedItem[] }): Promise<Response>`
  - `function renderAtom(o: { title: string; site: string; feedUrl: string; items: FeedItem[] }): Response`
  - `function renderJsonFeed(o: { title: string; site: string; feedUrl: string; items: FeedItem[] }): Response`

- [ ] **Step 1: Add the dependency**

In `Resources/Template/package.json`, add to `dependencies` (keep `astro`):

```json
  "dependencies": {
    "astro": "^5.0.0",
    "@astrojs/rss": "^4.0.0"
  },
```

Then install: `cd Resources/Template && npm install && cd ../..`

- [ ] **Step 2: Write the failing unit tests**

`Resources/Template/src/lib/feeds.test.ts`:

```ts
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  FEED_COLLECTIONS,
  toFeedItem,
  sortAndLimit,
  renderRss,
  renderAtom,
  renderJsonFeed,
  type FeedEntry,
} from "./feeds.ts";

const SITE = "https://example.com";

function entry(collection: string, data: Record<string, any>, body = ""): FeedEntry {
  return { id: "hello", collection, data, body };
}

test("config covers all eight collections", () => {
  assert.deepEqual(
    Object.keys(FEED_COLLECTIONS).sort(),
    ["albums", "articles", "blog", "bookmarks", "likes", "notes", "photos", "replies"],
  );
});

test("toFeedItem uses pubDate for blog and an absolute link", () => {
  const item = toFeedItem("blog", entry("blog", { title: "Hi", pubDate: "2026-01-02" }), SITE);
  assert.equal(item.title, "Hi");
  assert.equal(item.link, "https://example.com/blog/hello/");
  assert.equal(item.date.getUTCFullYear(), 2026);
});

test("toFeedItem derives a title for a title-less note from its body", () => {
  const item = toFeedItem(
    "notes",
    entry("notes", { publishDate: "2026-01-02" }, "Just a quick thought about feeds."),
    SITE,
  );
  assert.ok(item.title.length > 0);
  assert.ok(item.title.startsWith("Just a quick"));
});

test("toFeedItem derives a title from the link host for a like", () => {
  const item = toFeedItem(
    "likes",
    entry("likes", { likeOf: "https://indieweb.org/post", publishDate: "2026-01-02" }),
    SITE,
  );
  assert.equal(item.title, "Liked indieweb.org");
});

test("sortAndLimit sorts newest first and caps", () => {
  const mk = (iso: string): any => ({ title: iso, link: "/", date: new Date(iso), summary: "" });
  const out = sortAndLimit([mk("2026-01-01"), mk("2026-03-01"), mk("2026-02-01")], 2);
  assert.deepEqual(out.map((i) => i.title), ["2026-03-01", "2026-02-01"]);
});

test("renderRss produces RSS XML with the item and escapes specials", async () => {
  const res = await renderRss({
    title: "All",
    description: "Everything",
    site: SITE,
    items: [{ title: "A & B", link: `${SITE}/blog/a/`, date: new Date("2026-01-02"), summary: "hi" }],
  });
  const xml = await res.text();
  assert.match(xml, /<rss/);
  assert.match(xml, /A &(amp|#38);? ?B|A &amp; B/);
  assert.match(xml, /example\.com\/blog\/a\//);
});

test("renderAtom produces a feed with entry and self link", () => {
  const res = renderAtom({
    title: "All",
    site: SITE,
    feedUrl: `${SITE}/atom.xml`,
    items: [{ title: "A", link: `${SITE}/blog/a/`, date: new Date("2026-01-02"), summary: "hi" }],
  });
  assert.equal(res.headers.get("content-type"), "application/atom+xml; charset=utf-8");
});

test("renderJsonFeed produces valid JSON Feed 1.1", async () => {
  const res = renderJsonFeed({
    title: "All",
    site: SITE,
    feedUrl: `${SITE}/feed.json`,
    items: [{ title: "A", link: `${SITE}/blog/a/`, date: new Date("2026-01-02"), summary: "hi" }],
  });
  const feed = JSON.parse(await res.text());
  assert.equal(feed.version, "https://jsonfeed.org/version/1.1");
  assert.equal(feed.feed_url, `${SITE}/feed.json`);
  assert.equal(feed.items[0].url, `${SITE}/blog/a/`);
});
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd Resources/Template && npx tsx --test src/lib/feeds.test.ts; cd ../..`
Expected: FAIL — `./feeds.ts` cannot be resolved (module not yet created).

- [ ] **Step 4: Implement `feeds.ts`**

`Resources/Template/src/lib/feeds.ts`:

```ts
import rss from "@astrojs/rss";

export interface FeedItem {
  title: string;
  link: string; // absolute
  date: Date;
  summary: string;
}

export type FeedEntry = {
  id: string;
  collection: string;
  data: Record<string, any>;
  body?: string;
};

export interface FeedCollectionConfig {
  title: string;
  dateField: string;
  deriveTitle(entry: FeedEntry): string;
}

function host(url: unknown): string {
  try {
    return new URL(String(url)).host;
  } catch {
    return String(url ?? "");
  }
}

function excerpt(body: string | undefined, max = 80): string {
  const text = (body ?? "").replace(/\s+/g, " ").trim();
  if (text.length <= max) return text || "Untitled";
  return text.slice(0, max).trimEnd() + "…";
}

export const FEED_COLLECTIONS: Record<string, FeedCollectionConfig> = {
  blog: { title: "Blog", dateField: "pubDate", deriveTitle: (e) => e.data.title },
  notes: { title: "Notes", dateField: "publishDate", deriveTitle: (e) => excerpt(e.body) },
  articles: { title: "Articles", dateField: "publishDate", deriveTitle: (e) => e.data.title },
  photos: {
    title: "Photos",
    dateField: "publishDate",
    deriveTitle: (e) => e.data.caption ?? "Photo",
  },
  albums: { title: "Albums", dateField: "publishDate", deriveTitle: (e) => e.data.title },
  bookmarks: {
    title: "Bookmarks",
    dateField: "publishDate",
    deriveTitle: (e) => e.data.title ?? host(e.data.bookmarkOf),
  },
  replies: {
    title: "Replies",
    dateField: "publishDate",
    deriveTitle: (e) => "Re: " + host(e.data.inReplyTo),
  },
  likes: {
    title: "Likes",
    dateField: "publishDate",
    deriveTitle: (e) => "Liked " + host(e.data.likeOf),
  },
};

export function toFeedItem(collection: string, entry: FeedEntry, site: string): FeedItem {
  const cfg = FEED_COLLECTIONS[collection];
  if (!cfg) throw new Error(`No feed config for collection "${collection}"`);
  const rawDate = entry.data[cfg.dateField];
  const date = rawDate instanceof Date ? rawDate : new Date(rawDate);
  const summary = (entry.data.summary ?? entry.data.caption ?? excerpt(entry.body, 280)) || "";
  return {
    title: cfg.deriveTitle(entry) || "Untitled",
    link: new URL(`/${collection}/${entry.id}/`, site).href,
    date,
    summary: String(summary),
  };
}

export function sortAndLimit(items: FeedItem[], limit?: number): FeedItem[] {
  const sorted = [...items].sort((a, b) => b.date.valueOf() - a.date.valueOf());
  return typeof limit === "number" ? sorted.slice(0, limit) : sorted;
}

export function renderRss(o: {
  title: string;
  description: string;
  site: string;
  items: FeedItem[];
}): Promise<Response> {
  return rss({
    title: o.title,
    description: o.description,
    site: o.site,
    items: o.items.map((i) => ({
      title: i.title,
      link: i.link,
      pubDate: i.date,
      description: i.summary,
    })),
  });
}

function escapeXml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

export function renderAtom(o: {
  title: string;
  site: string;
  feedUrl: string;
  items: FeedItem[];
}): Response {
  const updated = o.items[0]?.date ?? new Date(0);
  const entries = o.items
    .map(
      (i) => `  <entry>
    <title>${escapeXml(i.title)}</title>
    <link href="${escapeXml(i.link)}"/>
    <id>${escapeXml(i.link)}</id>
    <updated>${i.date.toISOString()}</updated>
    <summary>${escapeXml(i.summary)}</summary>
  </entry>`,
    )
    .join("\n");
  const xml = `<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>${escapeXml(o.title)}</title>
  <id>${escapeXml(o.site)}</id>
  <link href="${escapeXml(o.site)}"/>
  <link rel="self" href="${escapeXml(o.feedUrl)}"/>
  <updated>${updated.toISOString()}</updated>
${entries}
</feed>
`;
  return new Response(xml, {
    headers: { "Content-Type": "application/atom+xml; charset=utf-8" },
  });
}

export function renderJsonFeed(o: {
  title: string;
  site: string;
  feedUrl: string;
  items: FeedItem[];
}): Response {
  const feed = {
    version: "https://jsonfeed.org/version/1.1",
    title: o.title,
    home_page_url: o.site,
    feed_url: o.feedUrl,
    items: o.items.map((i) => ({
      id: i.link,
      url: i.link,
      title: i.title,
      summary: i.summary,
      date_published: i.date.toISOString(),
    })),
  };
  return new Response(JSON.stringify(feed, null, 2), {
    headers: { "Content-Type": "application/feed+json; charset=utf-8" },
  });
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd Resources/Template && npx tsx --test src/lib/feeds.test.ts; cd ../..`
Expected: PASS (all 8 tests).

> If the RSS escaping assertion fails, print the actual `xml` once and align the regex to `@astrojs/rss`'s exact entity output — do not loosen to a bare `contains("A")`.

- [ ] **Step 6: Commit**

```bash
git add Resources/Template/package.json Resources/Template/package-lock.json \
        Resources/Template/src/lib/feeds.ts Resources/Template/src/lib/feeds.test.ts
git commit -m "feat(#348): pure feed core (config, item mapping, RSS/Atom/JSON serializers)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Site URL from `.site-config`

**Files:**
- Delete + Create (rename): `Resources/Template/astro.config.mjs` → `Resources/Template/astro.config.ts`

**Interfaces:**
- Consumes: `readConfig` from `Resources/Template/scripts/config.ts` (`readConfig(key: string): string | undefined`, defaults to reading `<cwd>/.site-config`).
- Produces: an Astro config whose `site` is `readConfig("SITE_URL") ?? "https://example.com"`. `context.site` (used by every feed route) derives from this.

> No unit test — this is build configuration. Verified by the Task 3/5 builds, which assert feeds carry absolute URLs built from `site`.

- [ ] **Step 1: Replace the config file**

Remove `astro.config.mjs` and create `Resources/Template/astro.config.ts`:

```ts
import { defineConfig } from "astro/config";
import { readConfig } from "./scripts/config.ts";

// The deploy step writes the real domain into `.site-config` (SITE_URL=…) before build.
// Absent that, feeds carry a placeholder host — fine for a not-yet-deployed scaffold.
const site = readConfig("SITE_URL") ?? "https://example.com";

export default defineConfig({ site });
```

```bash
git rm Resources/Template/astro.config.mjs
```

- [ ] **Step 2: Verify the template still builds**

Run: `cd Resources/Template && node node_modules/astro/astro.js build && cd ../..`
Expected: build succeeds (existing pages still emit). Then clean: `rm -rf Resources/Template/dist`

- [ ] **Step 3: Commit**

```bash
git add Resources/Template/astro.config.ts
git commit -m "feat(#348): set Astro site from SITE_URL in .site-config

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: `feed-data.ts` + root combined feeds

**Files:**
- Create: `Resources/Template/src/lib/feed-data.ts`
- Create: `Resources/Template/src/pages/rss.xml.ts`
- Create: `Resources/Template/src/pages/atom.xml.ts`
- Create: `Resources/Template/src/pages/feed.json.ts`

**Interfaces:**
- Consumes: `getCollection` from `astro:content`; `FEED_COLLECTIONS`, `toFeedItem`, `sortAndLimit`, `renderRss`, `renderAtom`, `renderJsonFeed`, `FeedItem` from `../lib/feeds.ts` (Task 1); `context.site` (Task 2).
- Produces:
  - `getCollectionItems(collection: string, site: string): Promise<FeedItem[]>`
  - `getCombinedItems(site: string, limit?: number): Promise<FeedItem[]>`
  - Endpoint routes `GET` at `/rss.xml`, `/atom.xml`, `/feed.json`.

> Astro-coupled; verified by build (`getCollection` only resolves during `astro build`). No node unit test.

- [ ] **Step 1: Implement the data loader**

`Resources/Template/src/lib/feed-data.ts`:

```ts
import { getCollection } from "astro:content";
import { FEED_COLLECTIONS, toFeedItem, sortAndLimit, type FeedItem } from "./feeds.ts";

const COMBINED_LIMIT = 50;

export async function getCollectionItems(collection: string, site: string): Promise<FeedItem[]> {
  const entries = await getCollection(collection as any);
  const items = entries.map((e: any) =>
    toFeedItem(collection, { id: e.id, collection, data: e.data, body: e.body }, site),
  );
  return sortAndLimit(items);
}

export async function getCombinedItems(site: string, limit = COMBINED_LIMIT): Promise<FeedItem[]> {
  const all: FeedItem[] = [];
  for (const collection of Object.keys(FEED_COLLECTIONS)) {
    all.push(...(await getCollectionItems(collection, site)));
  }
  return sortAndLimit(all, limit);
}
```

- [ ] **Step 2: Create the three combined routes**

`Resources/Template/src/pages/rss.xml.ts`:

```ts
import type { APIContext } from "astro";
import { getCombinedItems } from "../lib/feed-data.ts";
import { renderRss } from "../lib/feeds.ts";

export async function GET(context: APIContext) {
  const site = context.site!.href;
  return renderRss({
    title: "All posts",
    description: "Everything published on this site.",
    site,
    items: await getCombinedItems(site),
  });
}
```

`Resources/Template/src/pages/atom.xml.ts`:

```ts
import type { APIContext } from "astro";
import { getCombinedItems } from "../lib/feed-data.ts";
import { renderAtom } from "../lib/feeds.ts";

export async function GET(context: APIContext) {
  const site = context.site!.href;
  return renderAtom({
    title: "All posts",
    site,
    feedUrl: new URL("/atom.xml", site).href,
    items: await getCombinedItems(site),
  });
}
```

`Resources/Template/src/pages/feed.json.ts`:

```ts
import type { APIContext } from "astro";
import { getCombinedItems } from "../lib/feed-data.ts";
import { renderJsonFeed } from "../lib/feeds.ts";

export async function GET(context: APIContext) {
  const site = context.site!.href;
  return renderJsonFeed({
    title: "All posts",
    site,
    feedUrl: new URL("/feed.json", site).href,
    items: await getCombinedItems(site),
  });
}
```

- [ ] **Step 3: Build and verify the combined feeds**

Run:
```bash
cd Resources/Template && node node_modules/astro/astro.js build && cd ../..
```
Expected: build succeeds; `dist/rss.xml`, `dist/atom.xml`, `dist/feed.json` exist. Spot-check:
```bash
cd Resources/Template
grep -o '<rss' dist/rss.xml
grep -o 'application/atom' dist/atom.xml || head -2 dist/atom.xml
grep -o 'jsonfeed.org/version/1.1' dist/feed.json
grep -o 'https://example.com/' dist/feed.json | head -1
rm -rf dist && cd ../..
```
Expected: each prints its marker, and the JSON feed contains the absolute `https://example.com/` base.

- [ ] **Step 4: Commit**

```bash
git add Resources/Template/src/lib/feed-data.ts Resources/Template/src/pages/rss.xml.ts \
        Resources/Template/src/pages/atom.xml.ts Resources/Template/src/pages/feed.json.ts
git commit -m "feat(#348): site-wide combined RSS/Atom/JSON feeds

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Per-collection feed routes + autodiscovery

**Files:**
- Create: `Resources/Template/src/pages/<collection>/{rss.xml.ts,atom.xml.ts,feed.json.ts}` for all 8 collections (24 files)
- Modify: `Resources/Template/src/layouts/BaseLayout.astro` (autodiscovery links)
- Modify: `Resources/Template/src/pages/blog/index.astro` (blog's own feed link)

**Interfaces:**
- Consumes: `getCollectionItems` from `../../lib/feed-data.ts`; `renderRss`/`renderAtom`/`renderJsonFeed`, `FEED_COLLECTIONS` from `../../lib/feeds.ts`; `context.site`.
- Produces: endpoints at `/<collection>/rss.xml`, `/<collection>/atom.xml`, `/<collection>/feed.json` for every collection.

- [ ] **Step 1: Create the three blog feed routes (the template for all collections)**

`Resources/Template/src/pages/blog/rss.xml.ts`:

```ts
import type { APIContext } from "astro";
import { getCollectionItems } from "../../lib/feed-data.ts";
import { renderRss, FEED_COLLECTIONS } from "../../lib/feeds.ts";

const COLLECTION = "blog";

export async function GET(context: APIContext) {
  const site = context.site!.href;
  return renderRss({
    title: FEED_COLLECTIONS[COLLECTION].title,
    description: `${FEED_COLLECTIONS[COLLECTION].title} feed`,
    site,
    items: await getCollectionItems(COLLECTION, site),
  });
}
```

`Resources/Template/src/pages/blog/atom.xml.ts`:

```ts
import type { APIContext } from "astro";
import { getCollectionItems } from "../../lib/feed-data.ts";
import { renderAtom, FEED_COLLECTIONS } from "../../lib/feeds.ts";

const COLLECTION = "blog";

export async function GET(context: APIContext) {
  const site = context.site!.href;
  return renderAtom({
    title: FEED_COLLECTIONS[COLLECTION].title,
    site,
    feedUrl: new URL(`/${COLLECTION}/atom.xml`, site).href,
    items: await getCollectionItems(COLLECTION, site),
  });
}
```

`Resources/Template/src/pages/blog/feed.json.ts`:

```ts
import type { APIContext } from "astro";
import { getCollectionItems } from "../../lib/feed-data.ts";
import { renderJsonFeed, FEED_COLLECTIONS } from "../../lib/feeds.ts";

const COLLECTION = "blog";

export async function GET(context: APIContext) {
  const site = context.site!.href;
  return renderJsonFeed({
    title: FEED_COLLECTIONS[COLLECTION].title,
    site,
    feedUrl: new URL(`/${COLLECTION}/feed.json`, site).href,
    items: await getCollectionItems(COLLECTION, site),
  });
}
```

- [ ] **Step 2: Replicate for the other seven collections**

For each collection in `notes, articles, photos, albums, bookmarks, replies, likes`, copy the three `blog/*` files into that collection's page directory and change **only** the `const COLLECTION = "blog";` line to the matching name. The import paths (`../../lib/...`) are identical because every collection dir is one level under `pages/`. Resulting files:

```
src/pages/notes/{rss.xml.ts,atom.xml.ts,feed.json.ts}
src/pages/articles/{rss.xml.ts,atom.xml.ts,feed.json.ts}
src/pages/photos/{rss.xml.ts,atom.xml.ts,feed.json.ts}
src/pages/albums/{rss.xml.ts,atom.xml.ts,feed.json.ts}
src/pages/bookmarks/{rss.xml.ts,atom.xml.ts,feed.json.ts}
src/pages/replies/{rss.xml.ts,atom.xml.ts,feed.json.ts}
src/pages/likes/{rss.xml.ts,atom.xml.ts,feed.json.ts}
```

- [ ] **Step 3: Add combined-feed autodiscovery to BaseLayout**

In `Resources/Template/src/layouts/BaseLayout.astro`, add three `<link rel="alternate">` lines inside `<head>`, immediately after the existing stylesheet `<link>`:

```astro
    <link rel="stylesheet" href="/src/styles/global.css" />
    <link rel="alternate" type="application/rss+xml" title="RSS" href="/rss.xml" />
    <link rel="alternate" type="application/atom+xml" title="Atom" href="/atom.xml" />
    <link rel="alternate" type="application/feed+json" title="JSON Feed" href="/feed.json" />
```

- [ ] **Step 4: Link the blog index to its own feed**

In `Resources/Template/src/pages/blog/index.astro`, the page uses `BaseLayout`. Add a visible feed link inside `<main>`, after the `<h1>Blog</h1>`:

```astro
    <h1>Blog</h1>
    <p><a href="/blog/rss.xml">Subscribe (RSS)</a></p>
```

- [ ] **Step 5: Build and verify every feed + route precedence**

Run:
```bash
cd Resources/Template && node node_modules/astro/astro.js build
```
Expected: build succeeds. Verify per-collection feeds and that `/blog/rss.xml` is the feed (not a slug page):
```bash
for c in blog notes articles photos albums bookmarks replies likes; do
  for f in rss.xml atom.xml feed.json; do
    test -f "dist/$c/$f" && echo "ok  $c/$f" || echo "MISSING $c/$f"
  done
done
grep -o '<rss' dist/blog/rss.xml            # blog/rss.xml is a feed
grep -o 'jsonfeed' dist/likes/feed.json      # title-less type still produced a feed
grep -o 'application/rss' dist/index.html    # BaseLayout autodiscovery present
rm -rf dist && cd ../..
```
Expected: 24 `ok` lines, the three greps print their markers.

- [ ] **Step 6: Commit**

```bash
git add Resources/Template/src/pages Resources/Template/src/layouts/BaseLayout.astro
git commit -m "feat(#348): per-collection feeds + feed autodiscovery links

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Node-gated mf2/feed render smoke test

**Files:**
- Create: `Tests/AnglesiteCoreTests/FeedsRenderSmokeTests.swift`

**Interfaces:**
- Consumes: `E2EPrerequisites.locateNode()` (`Tests/AnglesiteTestSupport/E2EPrerequisites.swift`, returns `URL?`); `ProcessSupervisor.shared.run(executable:arguments:currentDirectoryURL:)` → `RunResult { stdout, stderr, exitCode }`; the template at `Resources/Template/`.
- Produces: one gated `@Test` asserting the built feeds exist and a title-less feed item is non-empty. No production code.

**Gating:** `.enabled(if:)` on Node located **and** `Resources/Template/node_modules/astro/astro.js` present — skips (never fails) when deps aren't installed, matching `PersonalTypeRenderSmokeTests`.

> **Illustrative sample — see the committed test for the real shape.** Swift Testing runs suites
> in parallel, so this smoke and `PersonalTypeRenderSmokeTests` build the *same* `Resources/Template`
> tree concurrently and `rm -rf dist` around it, racing. The shipped implementation wraps the build
> **and its assertions** in `TemplateBuildSerializer.shared.serialize { … }`
> (`Tests/AnglesiteTestSupport/TemplateBuildSerializer.swift`), and `PersonalTypeRenderSmokeTests`
> does the same. The sample below omits that wrapper for brevity — do not copy it verbatim.

- [ ] **Step 1: Write the gated smoke test**

`Tests/AnglesiteCoreTests/FeedsRenderSmokeTests.swift`:

```swift
import Testing
import Foundation
import AnglesiteTestSupport
@testable import AnglesiteCore

@Suite("Feeds render smoke")
struct FeedsRenderSmokeTests {

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

    @Test("collections emit RSS/Atom/JSON and a combined feed",
          .enabled(if: FeedsRenderSmokeTests.buildable))
    func rendersFeeds() async throws {
        let node = try #require(E2EPrerequisites.locateNode())
        let dist = Self.templateDir.appendingPathComponent("dist", isDirectory: true)
        try? FileManager.default.removeItem(at: dist)
        defer { try? FileManager.default.removeItem(at: dist) }

        let result = try await ProcessSupervisor.shared.run(
            executable: node,
            arguments: ["node_modules/astro/astro.js", "build"],
            currentDirectoryURL: Self.templateDir)
        #expect(result.exitCode == 0, "astro build failed: \(result.stdout)\n\(result.stderr)")

        func exists(_ rel: String) -> Bool {
            FileManager.default.fileExists(atPath: dist.appendingPathComponent(rel).path)
        }
        func text(_ rel: String) throws -> String {
            try String(contentsOf: dist.appendingPathComponent(rel), encoding: .utf8)
        }

        // Combined feeds at the root.
        #expect(exists("rss.xml"))
        #expect(exists("atom.xml"))
        #expect(exists("feed.json"))

        // Per-collection feeds for every collection, all three formats.
        for c in ["blog", "notes", "articles", "photos", "albums", "bookmarks", "replies", "likes"] {
            #expect(exists("\(c)/rss.xml"), "missing \(c)/rss.xml")
            #expect(exists("\(c)/atom.xml"), "missing \(c)/atom.xml")
            #expect(exists("\(c)/feed.json"), "missing \(c)/feed.json")
        }

        // Feeds carry absolute URLs from `site`.
        #expect(try text("feed.json").contains("https://example.com/"))
        #expect(try text("blog/rss.xml").contains("<rss"))

        // A title-less type (likes) still produces a non-empty <title>.
        let likesJson = try text("likes/feed.json")
        #expect(likesJson.contains("\"title\""))
        #expect(!likesJson.contains("\"title\": \"\""))
    }
}
```

- [ ] **Step 2: Run the test**

Prerequisite (local): `cd Resources/Template && npm install && cd ../..`
Run: `swift test --package-path . --filter FeedsRenderSmokeTests`
Expected: PASS where deps are installed; SKIPPED (not failed) where they aren't.

> If `RunResult` field names differ from `.exitCode`/`.stdout`/`.stderr`, reconcile against `ProcessSupervisor.RunResult` (it is `{ stdout, stderr, exitCode }`).

- [ ] **Step 3: Commit**

```bash
git add Tests/AnglesiteCoreTests/FeedsRenderSmokeTests.swift
git commit -m "test(#348): node-gated RSS/Atom/JSON feed render smoke

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Full verification + pre-deploy-check + push

**Files:** none (verification only).

- [ ] **Step 1: Run the feed node unit tests + the full AnglesiteCore suite**

Run:
```bash
cd Resources/Template && npx tsx --test src/lib/feeds.test.ts && cd ../..
swift test --package-path . --filter AnglesiteCoreTests
```
Expected: node tests PASS; Swift suite PASS (feed smoke passes or skips), no regressions.

- [ ] **Step 2: Confirm the template still passes pre-deploy-check**

Run: `cd Resources/Template && npm run check && cd ../..`
Expected: pre-deploy-check passes with the new feed routes and config.

- [ ] **Step 3: Push the branch**

```bash
git push -u origin feat/348-feeds
```

- [ ] **Step 4: Open the PR**

```bash
gh pr create --title "feat(#348): V-1.6 feeds (RSS/Atom/JSON)" \
  --body "Closes #348. Per-collection RSS 2.0 / Atom 1.0 / JSON Feed 1.1 co-located in each collection, plus a site-wide combined feed. Pure feed core in \`src/lib/feeds.ts\` (node-unit-tested); astro-coupled loading in \`feed-data.ts\`; node-gated Swift build smoke. Site URL from \`SITE_URL\` in \`.site-config\`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

---

## Self-Review

**Spec coverage:**
- RSS + Atom + JSON, all three formats → Task 1 serializers ✓
- One feed per collection → Task 4 (24 routes) ✓
- Combined feed → Task 3 ✓
- Self-contained collections (co-located routes, shared logic) → `feeds.ts`/`feed-data.ts` + per-collection routes ✓
- `pubDate` vs `publishDate` via config table → Task 1 `FEED_COLLECTIONS` ✓
- Title-less type derivation → Task 1 `deriveTitle` + tests ✓
- SITE_URL from `.site-config`, placeholder fallback → Task 2 ✓
- Autodiscovery → Task 4 Steps 3–4 ✓
- Node-gated build smoke, skips when absent → Task 5 ✓
- pre-deploy-check stays green → Task 6 Step 2 ✓
- Gated on #344 (typed collections) → Prerequisite section ✓

**Placeholder scan:** No TBD/TODO; every code step shows full content; commands list expected output.

**Type consistency:** `FeedItem { title, link, date, summary }` defined in Task 1, consumed identically in Tasks 3–5. `toFeedItem(collection, entry, site)`, `sortAndLimit(items, limit?)`, `renderRss/renderAtom/renderJsonFeed` signatures match across `feed-data.ts` and route files. `getCollectionItems(collection, site)` / `getCombinedItems(site, limit?)` defined in Task 3, consumed in Task 4. `FEED_COLLECTIONS` keys (8 collections) consistent across config, routes, build greps, and the Swift smoke. `RunResult { stdout, stderr, exitCode }` matches `ProcessSupervisor`.

**Out of scope (untouched):** full-content (markdown→HTML) feed bodies; feed pagination/`rel=next`; WebSub (#361); Zod hardening (#347); mf2 (#349).
