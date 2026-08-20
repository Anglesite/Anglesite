# IndieMark Self-Assessment Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a `/indiemark/` page on every Anglesite-built site that reports, per IndieMark axis, what the site actually has (h-card, post types, webmention/micropub/websub, POSSE syndication, home-page indexability) versus what Anglesite the platform supports but can't verify from a static build (IndieAuth, Microsub, ActivityPub, HTTPS, on-site search, microformats2 markup).

**Architecture:** A pure, unit-testable assessment function (`src/lib/indiemark.ts`) takes a plain data object and returns a fixed list of axis results (no astro imports, so it runs under plain `node:test`). A thin astro-content-dependent gatherer (`src/lib/indiemark-astro.ts`) collects that data object from the site's real content collections, `.site-config`, and `robots-config.json` — mirroring the existing `collection-index.ts` / `collection-index-astro.ts` split used elsewhere in this template. The page (`src/pages/indiemark.astro`) wires the two together and renders the result as plain text-labeled sections (no emoji-only status, no numeric score) inside `BaseLayout`.

**Tech Stack:** Astro (content collections, `astro:content`), TypeScript, `node:test` via `tsx --test`, existing template libs (`scripts/config.ts`, `src/lib/robots-config.ts`, `src/lib/feeds.ts`).

## Global Constraints

- No numeric point score or "Level N" badge — the upstream IndieMark rubric is inconsistent/TBD past Level 2; only qualitative per-axis status is shown.
- No new `.site-config` keys and no worker changes — this reads data that already exists.
- The page is a standalone route, not injected into any nav/footer component (there isn't one in this template today — `/search` and `/resume` follow the same standalone convention).
- Follow the existing pure-lib / astro-companion split: `src/lib/indiemark.ts` (plain, testable with `node:test`) and `src/lib/indiemark-astro.ts` (the `astro:content`-importing half), matching `collection-index.ts` / `collection-index-astro.ts`.
- Reuse `FEED_COLLECTIONS` from `src/lib/feeds.ts` as the canonical set of post-type collections — do not hand-roll a second list.
- `.site-config` boolean flags are read as `readConfig("KEY") === "true"`, matching every other call site in this template (`BaseLayout.astro`, `feed.json.ts`, `rss.xml.ts`, `atom.xml.ts`, `scripts/edge-artifacts.ts`).

**Deviation from the approved spec, discovered during file-structure research:** the spec classified POSSE/syndication as "manual, not detectable." While mapping `src/content.config.ts`, `socialFields` (`src/lib/content-schemas.ts`) turned out to include a `syndication: z.array(z.string().url()).optional()` field that Anglesite writes back onto a post's frontmatter once a POSSE copy actually publishes. That means POSSE *is* detectable per-site: "has at least one post with a non-empty `syndication` array." This plan promotes that axis from `manual` to `detected` accordingly (Task 1, axis 7). Flagged here for visibility since it changes the spec's classification table by one row; everything else matches the approved spec.

**Deviation found during final review:** Task 2's implementation iterated `FEED_COLLECTIONS` (`src/lib/feeds.ts`) as the canonical post-type collection list for the Posts axis. That turned out to be the wrong list — it only has the 8 collections with a feed, missing `announcements`/`events`/`reviews`, which under-counted the Posts axis on the default scaffold. `ENTRY_COLLECTIONS` (`src/lib/collections.ts`) plus `"blog"` — the same `[...ENTRY_COLLECTIONS, "blog"]` idiom already used by `licensing.ts`/`mcp-search-entries.ts`/`sitemap-data.ts` — is the correct "every routed post-type collection" list, and `indiemark-astro.ts` was fixed to use it.

---

## Task 1: Pure assessment logic — `src/lib/indiemark.ts`

**Files:**
- Create: `Resources/Template/src/lib/indiemark.ts`
- Test: `Resources/Template/src/lib/indiemark.test.ts`

**Interfaces:**
- Produces (consumed by Task 2 and Task 3):
  ```ts
  export type AxisBasis = "detected" | "supported";

  export interface AxisResult {
    axis: string;
    basis: AxisBasis;
    /** Set only when basis === "detected": whether this site's build actually has the
     * feature active right now. */
    present?: boolean;
    label: string;
    detail: string;
  }

  export interface IndieMarkInputs {
    hasProfile: boolean;
    /** Non-draft entry count per `FEED_COLLECTIONS` key (blog, notes, articles, photos,
     * albums, bookmarks, replies, likes). */
    postTypeCounts: Record<string, number>;
    homeIndexable: boolean;
    webmentionReceiveEnabled: boolean;
    micropubEnabled: boolean;
    websubEnabled: boolean;
    hasSyndicatedPosts: boolean;
  }

  export function assessIndieMark(inputs: IndieMarkInputs): AxisResult[];
  ```

- [ ] **Step 1: Write the failing tests**

Create `Resources/Template/src/lib/indiemark.test.ts`:

```ts
import test from "node:test";
import assert from "node:assert/strict";
import { assessIndieMark, type IndieMarkInputs } from "./indiemark.ts";

const baseInputs: IndieMarkInputs = {
  hasProfile: false,
  postTypeCounts: {},
  homeIndexable: false,
  webmentionReceiveEnabled: false,
  micropubEnabled: false,
  websubEnabled: false,
  hasSyndicatedPosts: false,
};

test("assessIndieMark: returns exactly 13 axes in a fixed order", () => {
  const results = assessIndieMark(baseInputs);
  assert.equal(results.length, 13);
  assert.deepEqual(
    results.map((r) => r.axis),
    [
      "Identity",
      "Posts",
      "Search discoverability",
      "Webmention (receiving)",
      "Micropub",
      "WebSub",
      "Syndication (POSSE)",
      "Authentication (IndieAuth)",
      "Aggregation (Microsub)",
      "Handling responses (ActivityPub)",
      "Security (HTTPS)",
      "Own-site search backend",
      "Microformats2 markup",
    ],
  );
});

test("assessIndieMark: identity — no profile.json", () => {
  const [identity] = assessIndieMark(baseInputs);
  assert.equal(identity.basis, "detected");
  assert.equal(identity.present, false);
  assert.equal(identity.label, "Not set up on this site yet");
  assert.match(identity.detail, /No src\/data\/profile\.json/);
});

test("assessIndieMark: identity — profile.json present", () => {
  const [identity] = assessIndieMark({ ...baseInputs, hasProfile: true });
  assert.equal(identity.present, true);
  assert.equal(identity.label, "Detected on this site");
  assert.match(identity.detail, /publishes an h-card/);
});

test("assessIndieMark: posts — no post-type collections have entries", () => {
  const [, posts] = assessIndieMark(baseInputs);
  assert.equal(posts.basis, "detected");
  assert.equal(posts.present, false);
  assert.match(posts.detail, /No posts yet/);
});

test("assessIndieMark: posts — lists each active post type by name, in collection order", () => {
  const [, posts] = assessIndieMark({
    ...baseInputs,
    postTypeCounts: { blog: 0, notes: 3, articles: 0, photos: 1, albums: 0, bookmarks: 0, replies: 0, likes: 0 },
  });
  assert.equal(posts.present, true);
  assert.equal(posts.detail, "Publishing 2 post types: notes, photos.");
});

test("assessIndieMark: posts — singular wording for exactly one active type", () => {
  const [, posts] = assessIndieMark({
    ...baseInputs,
    postTypeCounts: { blog: 1, notes: 0, articles: 0, photos: 0, albums: 0, bookmarks: 0, replies: 0, likes: 0 },
  });
  assert.equal(posts.detail, "Publishing 1 post type: blog posts.");
});

test("assessIndieMark: search discoverability — noindexed home page", () => {
  const [, , search] = assessIndieMark(baseInputs);
  assert.equal(search.present, false);
  assert.match(search.detail, /marked noindex/);
});

test("assessIndieMark: search discoverability — indexable home page", () => {
  const [, , search] = assessIndieMark({ ...baseInputs, homeIndexable: true });
  assert.equal(search.present, true);
  assert.match(search.detail, /is indexable/);
});

test("assessIndieMark: webmention receiving reflects the input flag", () => {
  const off = assessIndieMark(baseInputs)[3];
  const on = assessIndieMark({ ...baseInputs, webmentionReceiveEnabled: true })[3];
  assert.equal(off.present, false);
  assert.equal(on.present, true);
  assert.match(off.detail, /WEBMENTION_RECEIVE_ENABLED/);
  assert.match(on.detail, /WEBMENTION_RECEIVE_ENABLED/);
});

test("assessIndieMark: micropub reflects the input flag", () => {
  const off = assessIndieMark(baseInputs)[4];
  const on = assessIndieMark({ ...baseInputs, micropubEnabled: true })[4];
  assert.equal(off.present, false);
  assert.equal(on.present, true);
  assert.match(on.detail, /MICROPUB_ENABLED/);
});

test("assessIndieMark: websub reflects the input flag", () => {
  const off = assessIndieMark(baseInputs)[5];
  const on = assessIndieMark({ ...baseInputs, websubEnabled: true })[5];
  assert.equal(off.present, false);
  assert.equal(on.present, true);
  assert.match(on.detail, /WEBSUB_ENABLED/);
});

test("assessIndieMark: syndication (POSSE) reflects hasSyndicatedPosts", () => {
  const off = assessIndieMark(baseInputs)[6];
  const on = assessIndieMark({ ...baseInputs, hasSyndicatedPosts: true })[6];
  assert.equal(off.basis, "detected");
  assert.equal(off.present, false);
  assert.match(off.detail, /No posts have recorded POSSE/);
  assert.equal(on.present, true);
  assert.match(on.detail, /has been POSSEd/);
});

test("assessIndieMark: the six platform-supported axes are fixed regardless of inputs", () => {
  const withNothing = assessIndieMark(baseInputs).slice(7);
  const withEverything = assessIndieMark({
    hasProfile: true,
    postTypeCounts: { blog: 5, notes: 5, articles: 5, photos: 5, albums: 5, bookmarks: 5, replies: 5, likes: 5 },
    homeIndexable: true,
    webmentionReceiveEnabled: true,
    micropubEnabled: true,
    websubEnabled: true,
    hasSyndicatedPosts: true,
  }).slice(7);
  assert.deepEqual(withNothing, withEverything);
  for (const axis of withNothing) {
    assert.equal(axis.basis, "supported");
    assert.equal(axis.present, undefined);
  }
});

test("assessIndieMark: platform-supported axes name the gating mechanism", () => {
  const supported = assessIndieMark(baseInputs).slice(7);
  assert.match(supported[0].detail, /IndieAuth/);
  assert.match(supported[0].detail, /Worker secrets/);
  assert.match(supported[1].detail, /Microsub/);
  assert.match(supported[2].detail, /ActivityPub/);
  assert.match(supported[3].detail, /HTTPS/);
  assert.match(supported[4].detail, /Pagefind/);
  assert.match(supported[5].detail, /microformats2/i);
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Resources/Template && npx tsx --test src/lib/indiemark.test.ts`
Expected: FAIL — `Cannot find module './indiemark.ts'` (the file doesn't exist yet).

- [ ] **Step 3: Write the implementation**

Create `Resources/Template/src/lib/indiemark.ts`:

```ts
/**
 * Pure per-site assessment against indieweb.org/IndieMark's current axis list (Level 0–6,
 * explicitly "rough and in-progress" upstream — there is no numbered "3.0" version). Kept free
 * of `astro:content` so it stays unit-testable with plain `node:test`, same rationale as
 * `collection-index.ts` / `tags.ts` / `content-schemas.ts`. The `astro:content`-importing half
 * that gathers `IndieMarkInputs` for a real build lives in `indiemark-astro.ts`.
 *
 * `basis: "detected"` axes have a real build-time signal for this specific site (content
 * collections, `.site-config`, `robots-config.json`) and set `present`. `basis: "supported"`
 * axes are implemented by Anglesite's sidecar worker but gated by Worker secrets/bindings that
 * aren't visible to an Astro build, so they're described as platform capability rather than
 * falsely verified per-site — `present` stays unset for those.
 */

export type AxisBasis = "detected" | "supported";

export interface AxisResult {
  axis: string;
  basis: AxisBasis;
  present?: boolean;
  label: string;
  detail: string;
}

export interface IndieMarkInputs {
  hasProfile: boolean;
  postTypeCounts: Record<string, number>;
  homeIndexable: boolean;
  webmentionReceiveEnabled: boolean;
  micropubEnabled: boolean;
  websubEnabled: boolean;
  hasSyndicatedPosts: boolean;
}

const POST_TYPE_LABELS: Record<string, string> = {
  blog: "blog posts",
  notes: "notes",
  articles: "articles",
  photos: "photos",
  albums: "albums",
  bookmarks: "bookmarks",
  replies: "replies",
  likes: "likes",
};

function detected(axis: string, present: boolean, detail: string): AxisResult {
  return { axis, basis: "detected", present, label: present ? "Detected on this site" : "Not set up on this site yet", detail };
}

function supported(axis: string, detail: string): AxisResult {
  return { axis, basis: "supported", label: "Supported by Anglesite", detail };
}

function postsAxis(postTypeCounts: Record<string, number>): AxisResult {
  const active = Object.entries(postTypeCounts)
    .filter(([, count]) => count > 0)
    .map(([key]) => POST_TYPE_LABELS[key] ?? key);
  if (active.length === 0) {
    return detected(
      "Posts",
      false,
      "No posts yet in any post-type collection (notes, articles, photos, albums, bookmarks, replies, likes, blog).",
    );
  }
  const noun = active.length === 1 ? "post type" : "post types";
  return detected("Posts", true, `Publishing ${active.length} ${noun}: ${active.join(", ")}.`);
}

export function assessIndieMark(inputs: IndieMarkInputs): AxisResult[] {
  return [
    detected(
      "Identity",
      inputs.hasProfile,
      inputs.hasProfile
        ? "This site publishes an h-card — name, photo, and contact info — on every page, from src/data/profile.json."
        : "No src/data/profile.json yet, so this site doesn't publish an h-card. Add one in Anglesite to identify yourself in machine-readable form.",
    ),
    postsAxis(inputs.postTypeCounts),
    detected(
      "Search discoverability",
      inputs.homeIndexable,
      inputs.homeIndexable
        ? "The home page is indexable — no noindex directive blocks search engines from crawling it."
        : 'The home page is marked noindex, so search engines won\'t index it — site-specific search (e.g. "site:yourdomain.com") won\'t surface your posts until this changes.',
    ),
    detected(
      "Webmention (receiving)",
      inputs.webmentionReceiveEnabled,
      inputs.webmentionReceiveEnabled
        ? "Webmention receiving is enabled (.site-config WEBMENTION_RECEIVE_ENABLED) — other sites' mentions of your posts can show up as comments."
        : "Webmention receiving isn't enabled yet (.site-config WEBMENTION_RECEIVE_ENABLED) — turn it on to start collecting mentions from other IndieWeb sites.",
    ),
    detected(
      "Micropub",
      inputs.micropubEnabled,
      inputs.micropubEnabled
        ? "Micropub is enabled (.site-config MICROPUB_ENABLED) — you can post to this site from any Micropub client."
        : "Micropub isn't enabled yet (.site-config MICROPUB_ENABLED).",
    ),
    detected(
      "WebSub",
      inputs.websubEnabled,
      inputs.websubEnabled
        ? "WebSub is enabled (.site-config WEBSUB_ENABLED) — subscribers get near-real-time updates instead of polling your feeds."
        : "WebSub isn't enabled yet (.site-config WEBSUB_ENABLED).",
    ),
    detected(
      "Syndication (POSSE)",
      inputs.hasSyndicatedPosts,
      inputs.hasSyndicatedPosts
        ? "At least one post on this site has been POSSEd — it carries a recorded syndication copy elsewhere."
        : "No posts have recorded POSSE syndication copies yet. Syndicate a post with the syndicate skill to start.",
    ),
    supported(
      "Authentication (IndieAuth)",
      "Anglesite's sidecar implements an IndieAuth provider, gated by Worker secrets (INDIEAUTH_OWNER_PASSWORD, TOKEN_SIGNING_KEY, SOCIAL_KV) set outside this build — check your Cloudflare Worker's configuration to confirm it's provisioned for this site.",
    ),
    supported(
      "Aggregation (Microsub)",
      "Anglesite's sidecar implements a Microsub server, gated by Worker bindings (MICROSUB_DB, MICROSUB_QUEUE) set outside this build — check your Worker's configuration to confirm it's provisioned.",
    ),
    supported(
      "Handling responses (ActivityPub)",
      "Anglesite's sidecar implements ActivityPub federation, gated by Worker bindings set outside this build — check your Worker's configuration to confirm it's provisioned.",
    ),
    supported("Security (HTTPS)", "Every Anglesite site is served over HTTPS by Cloudflare — there's no per-site toggle to check."),
    supported(
      "Own-site search backend",
      "Every Anglesite site ships a Pagefind-powered search index at /search/, built from your own content — no third-party service involved. The index only exists after a production build, so this page can't probe it directly.",
    ),
    supported(
      "Microformats2 markup",
      "Anglesite's templates emit h-entry, h-card, h-feed, and related microformats2 markup automatically. This page doesn't re-validate it — use the IndieWeb h-entry/h-card testing tools to check a specific page.",
    ),
  ];
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Resources/Template && npx tsx --test src/lib/indiemark.test.ts`
Expected: PASS — all tests green.

- [ ] **Step 5: Commit**

```bash
git add Resources/Template/src/lib/indiemark.ts Resources/Template/src/lib/indiemark.test.ts
git commit -m "feat(#1599): add IndieMark axis assessment logic"
```

---

## Task 2: Astro-side input gathering — `src/lib/indiemark-astro.ts`

**Files:**
- Create: `Resources/Template/src/lib/indiemark-astro.ts`

**Interfaces:**
- Consumes: `IndieMarkInputs` (Task 1, `./indiemark.ts`); `FEED_COLLECTIONS` from `./feeds.ts` (existing, keys: `blog, notes, articles, photos, albums, bookmarks, replies, likes`); `readConfig` from `../../scripts/config.ts` (existing); `readRobotsConfig`, `isNoindexed` from `./robots-config.ts` (existing).
- Produces (consumed by Task 3): `export async function gatherIndieMarkInputs(): Promise<IndieMarkInputs>`

No `.test.ts` for this file — matching `collection-index-astro.ts`, which also has no test file, because it imports `astro:content`, a virtual module `tsx --test` can't resolve outside Astro's Vite pipeline (this is exactly why Task 1's logic was split out in the first place). It's exercised by `astro check`/`astro build` type-checking and by manually loading the page in Task 3.

- [ ] **Step 1: Write the implementation**

Create `Resources/Template/src/lib/indiemark-astro.ts`:

```ts
/**
 * Gathers this specific site's `IndieMarkInputs` (astro:content, `.site-config`,
 * `robots-config.json`) for `indiemark.ts`'s pure `assessIndieMark`. Kept separate from
 * `indiemark.ts` so the assessment logic itself stays unit-testable with plain `node:test` —
 * same split as `collection-index.ts` / `collection-index-astro.ts`.
 */
import { getCollection } from "astro:content";
import { readConfig } from "../../scripts/config.ts";
import { readRobotsConfig, isNoindexed } from "./robots-config.ts";
import { FEED_COLLECTIONS } from "./feeds.ts";
import type { IndieMarkInputs } from "./indiemark.ts";

export async function gatherIndieMarkInputs(): Promise<IndieMarkInputs> {
  const profileMods = import.meta.glob<{ default: Record<string, unknown> }>("../data/profile.json", {
    eager: true,
  });
  const hasProfile = Object.values(profileMods)[0]?.default !== undefined;

  const postTypeCounts: Record<string, number> = {};
  let hasSyndicatedPosts = false;
  for (const collection of Object.keys(FEED_COLLECTIONS)) {
    const entries = await getCollection(collection as any, ({ data }: any) =>
      import.meta.env.PROD ? !data.draft : true,
    );
    postTypeCounts[collection] = entries.length;
    if (entries.some((entry: any) => Array.isArray(entry.data.syndication) && entry.data.syndication.length > 0)) {
      hasSyndicatedPosts = true;
    }
  }

  return {
    hasProfile,
    postTypeCounts,
    homeIndexable: !isNoindexed("/", readRobotsConfig(process.cwd())),
    webmentionReceiveEnabled: readConfig("WEBMENTION_RECEIVE_ENABLED") === "true",
    micropubEnabled: readConfig("MICROPUB_ENABLED") === "true",
    websubEnabled: readConfig("WEBSUB_ENABLED") === "true",
    hasSyndicatedPosts,
  };
}
```

- [ ] **Step 2: Type-check it**

Run: `cd Resources/Template && npx astro check`
Expected: No new errors attributable to `indiemark-astro.ts`. (This file has no page importing it yet, so `astro check` may not deeply analyze it in isolation — Task 3's page import is the real check. If `astro check` reports an unused-file warning, ignore it; Task 3 resolves that.)

- [ ] **Step 3: Commit**

```bash
git add Resources/Template/src/lib/indiemark-astro.ts
git commit -m "feat(#1599): gather per-site IndieMark inputs from content and config"
```

---

## Task 3: The page — `src/pages/indiemark.astro`

**Files:**
- Create: `Resources/Template/src/pages/indiemark.astro`

**Interfaces:**
- Consumes: `gatherIndieMarkInputs` (Task 2), `assessIndieMark` and `AxisResult` (Task 1), `BaseLayout` (`../layouts/BaseLayout.astro`, existing — props `title: string`, `description?: string`).

- [ ] **Step 1: Write the page**

Create `Resources/Template/src/pages/indiemark.astro`:

```astro
---
import BaseLayout from "../layouts/BaseLayout.astro";
import { assessIndieMark } from "../lib/indiemark.ts";
import { gatherIndieMarkInputs } from "../lib/indiemark-astro.ts";

const results = assessIndieMark(await gatherIndieMarkInputs());
---

<BaseLayout
  title="IndieMark self-assessment"
  description="How this site measures up against the IndieWeb community's IndieMark self-assessment guide."
>
  <h1>IndieMark self-assessment</h1>

  <p>
    <a href="https://indieweb.org/IndieMark">IndieMark</a> is the IndieWeb community's own guide
    to independent-web features, organized into axes like identity, posting, and syndication. It's
    explicitly informal and still in progress — the wiki itself asks that it not be used to decide
    whether a site "is a member of the IndieWeb." Treat what follows as a snapshot of where this
    site and the Anglesite platform stand today, not a certification.
  </p>

  {
    results.map((result) => (
      <section>
        <h2>{result.axis}</h2>
        <p>
          <strong>{result.label}.</strong> {result.detail}
        </p>
      </section>
    ))
  }
</BaseLayout>
```

- [ ] **Step 2: Run the template's full check suite**

Run: `cd Resources/Template && npx astro check && npm test`
Expected: All PASS. `npm test` re-runs Task 1's `indiemark.test.ts` alongside the rest of the suite. (This
template's `package.json` has no `lint`/`typecheck` scripts — `npx astro check` plus `npm test` is
what actually exists and was used, confirmed during implementation.)

- [ ] **Step 3: Build the site and verify the page renders**

Run: `cd Resources/Template && npm run build`
Expected: Build succeeds; `dist/indiemark/index.html` exists.

Run: `grep -o "<h2>" Resources/Template/dist/indiemark/index.html | wc -l`
Expected: `13` (one `<h2>` per axis). Note: `grep -c` counts matching *lines*, not
occurrences — Astro's build output is minified to essentially one line, so `grep -c` here
returns `1` regardless of how many `<h2>` tags are actually present; `grep -o | wc -l` counts
occurrences and is the correct check.

- [ ] **Step 4: Manually preview the page**

Run: `cd Resources/Template && npm run preview` and open `http://localhost:4321/indiemark/` in a browser (or use the Browser tool). Confirm:
- The intro paragraph and IndieMark link render.
- All 13 axis sections render with a label and detail sentence.
- On this template's default (unconfigured) fixture content, "Identity" and "Search discoverability" should read as either detected-present or detected-absent sensibly given whatever `src/data/profile.json` and `robots-config.json` exist in the checkout — spot-check that the wording matches actual state rather than assuming.

- [ ] **Step 5: Commit**

```bash
git add Resources/Template/src/pages/indiemark.astro
git commit -m "feat(#1599): add /indiemark/ self-assessment page"
```

---

## Task 4: Finalize — swift test and PR prep

**Files:** none new; verification only.

- [ ] **Step 1: Run `swift test`**

Per `CONTRIBUTING.md` ▸ Testing: "If you touch `Resources/Template/`, run `swift test` too — some Swift tests couple to the template markup."

Run: `swift test --package-path .`
Expected: PASS. If a template-markup-coupled test fails because of the new page, fix the test (not the page) unless the failure reveals a real defect in the page.

- [ ] **Step 2: Re-check CONTRIBUTING.md commit/PR requirements**

Before committing or opening the PR, re-read `CONTRIBUTING.md` ▸ "Commits and pull requests" (already read once during planning) to confirm: conventional-commit subjects ≤72 chars referencing `#1599`; PR body built from `.github/PULL_REQUEST_TEMPLATE.md`'s exact headings (Summary, Paired PR check, Test plan); PR body says `Closes #1599`. This is template-only (`Resources/Template/`), so the Paired PR check section should state no sidecar PR is needed.

- [ ] **Step 3: Open the PR**

Include in the PR body's Summary a note correcting the issue's "IndieMark 3.0" premise (see the Global Constraints deviation note above) so reviewers aren't confused when the page doesn't match a "3.0" they might search for.
