# V-1.7 microformats2 markup + validation Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete h-entry / h-review / h-event microformats2 markup in the entry-layer templates and add a parser-based validator that proves the built output is valid mf2.

**Architecture:** Additive class/markup edits to four Astro layouts (no data-model changes), plus a pure validator module (`scripts/microformats.ts`) unit-tested with HTML fixtures on the existing `node:test` runner, exposed as a post-build CLI (`scripts/check-microformats.ts`) wired into the `build` script to validate the real `dist/` output.

**Tech Stack:** Astro 5, TypeScript (ES modules), `node:test` + `tsx`, `microformats-parser`.

## Global Constraints

- **Work in the worktree:** `.claude/worktrees/349-microformats2` (repo-relative). All paths below are relative to its `Resources/Template/` directory; run commands from there.
- **Run `npm install` once** in `Resources/Template/` before starting (the worktree has no `node_modules`). It is folded into Task 1, Step 1.
- **ES modules only** — `import/export`, explicit `.ts` extensions on local imports (matches `astro.config.ts` importing `./scripts/config.ts`).
- **Test runner is `node:test` via `tsx`** — no Vitest, no new test runner.
- **Only new dependency:** `microformats-parser` (devDependency). Nothing else.
- **Out of scope (→ #388):** author `p-author` h-card and the site-wide h-card. They appear in this plan only as `{ skip: ... }` placeholder tests.
- **Determinism:** date formatting pins `"en-US"` + `timeZone: "UTC"` (existing convention).
- Spec: `docs/superpowers/specs/2026-06-27-v1-7-microformats2-markup-design.md`.

---

### Task 1: Validator module, CLI, and unit tests

**Files:**
- Modify: `Resources/Template/package.json` (add `microformats-parser` devDependency)
- Create: `Resources/Template/scripts/microformats.ts`
- Create: `Resources/Template/scripts/check-microformats.ts`
- Test: `Resources/Template/scripts/microformats.test.ts`

**Interfaces:**
- Produces:
  - `ENTRY_TYPES: readonly ["h-entry","h-review","h-event"]`
  - `ENTRY_DIRS: string[]` — routed collection dir names under `dist/`
  - `findRoots(html: string, baseUrl?: string): Mf2Item[]`
  - `validateEntryHtml(html: string, label: string, baseUrl?: string): string[]` — empty array means valid
  - `validateDist(distDir: string): string[]`
- Consumes: nothing (first task).

- [ ] **Step 1: Install deps and add the parser**

Run (from `Resources/Template/`):

```bash
npm install
npm install --save-dev microformats-parser
```

Expected: `package.json` `devDependencies` now lists `microformats-parser`; `node_modules` populated.

- [ ] **Step 2: Write the failing unit test**

Create `scripts/microformats.test.ts`:

```ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { validateEntryHtml, findRoots } from "./microformats.ts";

const GOOD_ENTRY = `<!doctype html><html><body>
<article class="h-entry">
  <h1 class="p-name">My Article</h1>
  <p class="p-summary">Article summary text</p>
  <a class="u-url" href="/articles/my-article/"><time class="dt-published" datetime="2026-06-27T12:00:00.000Z">Jun 27, 2026</time></a>
  <div class="e-content"><p>Article body.</p></div>
  <ul><li><a class="p-category" href="/tags/indieweb">indieweb</a></li></ul>
</article></body></html>`;

const GOOD_REVIEW = `<!doctype html><html><body>
<article class="h-review">
  <h1 class="p-name">Review of The Widget</h1>
  <p>Reviewed: <span class="p-item">The Widget</span></p>
  <data class="p-rating" value="4">4</data>
  <a class="u-url" href="/reviews/the-widget/"><time class="dt-published" datetime="2026-06-27T12:00:00.000Z">Jun 27, 2026</time></a>
  <div class="e-content"><p>Solid widget.</p></div>
</article></body></html>`;

const GOOD_EVENT = `<!doctype html><html><body>
<article class="h-event">
  <h1 class="p-name">Launch Party</h1>
  <a class="u-url" href="/events/launch-party/"><time class="dt-start" datetime="2026-07-01T18:00:00.000Z">Jul 1, 2026</time></a>
  <p class="p-location">Online</p>
  <div class="e-content"><p>Join us.</p></div>
</article></body></html>`;

const NO_URL = `<!doctype html><html><body>
<article class="h-entry">
  <h1 class="p-name">No Permalink</h1>
  <time class="dt-published" datetime="2026-06-27T12:00:00.000Z">Jun 27, 2026</time>
  <div class="e-content"><p>Body.</p></div>
</article></body></html>`;

// h-review with NO explicit p-name: the parser implies a name from the full text,
// smashing item/rating/body together — the pitfall Hreview.astro documents.
const IMPLIED_REVIEW = `<!doctype html><html><body>
<article class="h-review">
  <p>Reviewed: <span class="p-item">The Widget</span></p>
  <data class="p-rating" value="4">4</data>
  <a class="u-url" href="/reviews/the-widget/"><time class="dt-published" datetime="2026-06-27T12:00:00.000Z">d</time></a>
  <div class="e-content"><p>Solid widget.</p></div>
</article></body></html>`;

test("valid h-entry passes and exposes expected properties", () => {
  assert.deepEqual(validateEntryHtml(GOOD_ENTRY, "good-entry"), []);
  const [item] = findRoots(GOOD_ENTRY);
  assert.deepEqual(item.properties.name, ["My Article"]);
  assert.deepEqual(item.properties.summary, ["Article summary text"]);
  assert.deepEqual(item.properties.category, ["indieweb"]);
  assert.equal(item.properties.url[0], "https://example.com/articles/my-article/");
  assert.ok(String(item.properties.published[0]).startsWith("2026-06-27"));
});

test("valid h-review passes with explicit name, item and rating", () => {
  assert.deepEqual(validateEntryHtml(GOOD_REVIEW, "good-review"), []);
  const [item] = findRoots(GOOD_REVIEW);
  assert.deepEqual(item.properties.name, ["Review of The Widget"]);
  assert.deepEqual(item.properties.item, ["The Widget"]);
  assert.deepEqual(item.properties.rating, ["4"]);
});

test("valid h-event passes", () => {
  assert.deepEqual(validateEntryHtml(GOOD_EVENT, "good-event"), []);
  const [item] = findRoots(GOOD_EVENT);
  assert.deepEqual(item.properties.name, ["Launch Party"]);
  assert.deepEqual(item.properties.location, ["Online"]);
  assert.ok(String(item.properties.start[0]).startsWith("2026-07-01"));
});

test("h-entry without u-url is flagged", () => {
  const problems = validateEntryHtml(NO_URL, "no-url");
  assert.ok(problems.some((p) => p.includes("missing u-url")), problems.join("; "));
});

test("h-review with implied (non-explicit) name is flagged", () => {
  const problems = validateEntryHtml(IMPLIED_REVIEW, "implied-review");
  assert.ok(problems.some((p) => p.includes("implied")), problems.join("; "));
});

// --- Deferred to #388 (site identity model) -------------------------------
test("entries carry a p-author h-card", { skip: "#388 — site identity model" }, () => {
  // When #388 lands the businessProfile h-card, assert the nested p-author here.
});
test("site-wide h-card is present", { skip: "#388 — site identity model" }, () => {
  // #388 emits the businessProfile h-card in BaseLayout; assert a root h-card then.
});
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `npx tsx --test scripts/microformats.test.ts`
Expected: FAIL — `Cannot find module './microformats.ts'` (the module does not exist yet).

- [ ] **Step 4: Implement the validator module**

Create `scripts/microformats.ts`:

```ts
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, extname } from "node:path";
import { mf2 } from "microformats-parser";

/** Base URL used to resolve relative u-* URLs during parsing. */
const BASE_URL = "https://example.com";

/** The mf2 root types our entry layouts may emit. */
export const ENTRY_TYPES = ["h-entry", "h-review", "h-event"] as const;
export type EntryType = (typeof ENTRY_TYPES)[number];

/** Routed collection dirs whose built pages carry an entry microformat. */
export const ENTRY_DIRS = [
  "blog", "notes", "articles", "photos", "albums",
  "bookmarks", "replies", "likes", "announcements", "events", "reviews",
];

type Mf2Item = { type: string[]; properties: Record<string, unknown[]> };

const isEntryType = (t: string): t is EntryType =>
  (ENTRY_TYPES as readonly string[]).includes(t);

/** Parse HTML and return its root microformat items. */
export function findRoots(html: string, baseUrl = BASE_URL): Mf2Item[] {
  return mf2(html, { baseUrl }).items as Mf2Item[];
}

function has(item: Mf2Item, prop: string): boolean {
  const v = item.properties[prop];
  return Array.isArray(v) && v.length > 0;
}

/**
 * Validate a single built entry page's microformats. Returns a list of human-readable
 * problems; an empty list means the page is valid mf2 for our purposes.
 */
export function validateEntryHtml(html: string, label: string, baseUrl = BASE_URL): string[] {
  const problems: string[] = [];
  const roots = findRoots(html, baseUrl).filter((i) => i.type.some(isEntryType));

  if (roots.length === 0) {
    problems.push(`${label}: no h-entry/h-review/h-event root item found`);
    return problems;
  }
  if (roots.length > 1) {
    problems.push(`${label}: expected exactly one entry root, found ${roots.length}`);
  }

  const item = roots[0];
  const type = item.type.find(isEntryType) as EntryType;

  if (!has(item, "name")) problems.push(`${label}: ${type} missing p-name`);
  if (!has(item, "url")) problems.push(`${label}: ${type} missing u-url`);
  if (type === "h-event") {
    if (!has(item, "start")) problems.push(`${label}: h-event missing dt-start`);
  } else if (!has(item, "published")) {
    problems.push(`${label}: ${type} missing dt-published`);
  }
  if (type === "h-review" && !has(item, "rating")) {
    problems.push(`${label}: h-review missing p-rating`);
  }

  // Guard the implied-name pitfall: a valid entry's p-name is the explicit title, not the
  // concatenation of all text (which the parser implies when no explicit p-name exists).
  const name = String(item.properties.name?.[0] ?? "");
  const content = String(
    (item.properties.content?.[0] as { value?: string } | undefined)?.value ?? "",
  ).trim();
  if (name && content && name.includes(content)) {
    problems.push(`${label}: ${type} p-name looks implied (contains the full content) — add an explicit p-name`);
  }

  return problems;
}

function walkHtml(dir: string): string[] {
  const out: string[] = [];
  let names: string[];
  try {
    names = readdirSync(dir);
  } catch {
    return out; // dir absent (collection had no built pages) — not an error here
  }
  for (const name of names) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) out.push(...walkHtml(full));
    else if (extname(full) === ".html") out.push(full);
  }
  return out;
}

/**
 * Validate every built entry page under `distDir` and assert vocabulary coverage:
 * each of h-entry / h-review / h-event appears in at least one valid page.
 */
export function validateDist(distDir: string): string[] {
  const problems: string[] = [];
  const seen = new Set<string>();

  for (const sub of ENTRY_DIRS) {
    const base = join(distDir, sub);
    for (const file of walkHtml(base)) {
      const rel = file.slice(base.length + 1); // "welcome/index.html" or "index.html"
      if (!rel.includes("/")) continue; // skip the collection's own list page (index.html)
      const html = readFileSync(file, "utf8");
      const label = file.slice(distDir.length + 1);
      const pageProblems = validateEntryHtml(html, label);
      problems.push(...pageProblems);
      if (pageProblems.length === 0) {
        for (const r of findRoots(html)) for (const t of r.type) if (isEntryType(t)) seen.add(t);
      }
    }
  }

  for (const t of ENTRY_TYPES) {
    if (!seen.has(t)) problems.push(`coverage: no valid ${t} page found in ${distDir}`);
  }
  return problems;
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `npx tsx --test scripts/microformats.test.ts`
Expected: PASS — 5 passing tests, 2 skipped (`# pass 5`, `# skipped 2`, `# fail 0`).

- [ ] **Step 6: Add the post-build CLI**

Create `scripts/check-microformats.ts`:

```ts
import { validateDist } from "./microformats.ts";

const distDir = process.argv[2] ?? "dist";
const problems = validateDist(distDir);

if (problems.length > 0) {
  console.error(`✗ microformats validation failed (${problems.length} problem(s)):`);
  for (const p of problems) console.error(`  - ${p}`);
  process.exit(1);
}
console.log("✓ microformats validation passed");
```

- [ ] **Step 7: Manually confirm the CLI flags the current (pre-fix) gaps**

Run: `npx astro build && npx tsx scripts/check-microformats.ts`
Expected: NON-ZERO exit — problems listed, including the blog page missing an entry root (BlogPost has no mf2 yet) and `missing u-url` on entry/review/event pages. This proves the guard detects real gaps before we fix the markup. (Do not wire it into `build` yet — that happens in Task 6.)

- [ ] **Step 8: Commit**

```bash
git add Resources/Template/package.json Resources/Template/package-lock.json \
  Resources/Template/scripts/microformats.ts \
  Resources/Template/scripts/check-microformats.ts \
  Resources/Template/scripts/microformats.test.ts
git commit -m "feat(#349): mf2 validator module + post-build CLI"
```

---

### Task 2: BlogPost.astro — add h-entry markup

**Files:**
- Modify: `Resources/Template/src/layouts/BlogPost.astro`

**Interfaces:**
- Consumes: `validateEntryHtml` / CLI from Task 1 (for verification).
- Produces: a valid `h-entry` page at `dist/blog/<slug>/index.html`.

- [ ] **Step 1: Replace the layout with h-entry markup**

Replace the entire contents of `src/layouts/BlogPost.astro` with:

```astro
---
// BlogPost.astro — layout for an individual blog post. The post route
// src/pages/blog/[...slug].astro renders through this layout; the Markdown body
// fills the <slot/>, and the comments anchor in the <article> below is where the
// giscus integration injects its widget when comments are set up.
import BaseLayout from "./BaseLayout.astro";

interface Props {
  title: string;
  description?: string;
  pubDate?: Date;
}

const { title, description, pubDate } = Astro.props;
// Compute the Date once; pin the locale + UTC so static output is deterministic.
const iso = pubDate ? new Date(pubDate).toISOString() : undefined;
const human = pubDate
  ? new Date(pubDate).toLocaleDateString("en-US", { year: "numeric", month: "long", day: "numeric", timeZone: "UTC" })
  : undefined;
// anglesite:imports — integration component imports are injected here on setup
---

<BaseLayout title={title} description={description}>
  <p><a href="/blog/">← All posts</a></p>
  <article class="h-entry">
    <h1 class="p-name">{title}</h1>
    {description && <p class="p-summary">{description}</p>}
    {iso && (
      <a class="u-url" href={Astro.url.pathname}>
        <time class="dt-published" datetime={iso}>{human}</time>
      </a>
    )}
    <div class="e-content"><slot /></div>
    <!-- anglesite:comments -->
  </article>
</BaseLayout>
```

Note: the `← All posts` nav stays **outside** `h-entry`; the `<!-- anglesite:comments -->` anchor stays **outside** `e-content`.

- [ ] **Step 2: Build and validate the blog page**

Run: `npx astro build && npx tsx scripts/check-microformats.ts`
Expected: NON-ZERO exit still (other layouts not yet fixed), BUT the problem list no longer contains any `blog/...: no h-entry/h-review/h-event root` entry — the blog page is now a valid h-entry. Remaining problems are `missing u-url` on `notes/articles/photos/albums/bookmarks/replies/likes/announcements`, `reviews`, and `events`.

- [ ] **Step 3: Commit**

```bash
git add Resources/Template/src/layouts/BlogPost.astro
git commit -m "feat(#349): h-entry markup for BlogPost layout"
```

---

### Task 3: Hentry.astro — emit article p-summary and u-url

**Files:**
- Modify: `Resources/Template/src/layouts/Hentry.astro`

**Interfaces:**
- Consumes: CLI from Task 1.
- Produces: valid h-entry pages for the eight h-entry collections, with `p-summary` for articles and `u-url` permalinks.

- [ ] **Step 1: Update the article body markup**

In `src/layouts/Hentry.astro`, replace this block (the TODO comment, the caption-only summary, and the bare published `<time>`):

```astro
    {/* TODO(#349): article `summary` (registry p-summary) is not emitted here yet — only photo caption is. */}
    {d.caption && <p class="p-summary">{d.caption}</p>}
    <div class="e-content"><slot /></div>
    {iso && <time class="dt-published" datetime={iso}>{human}</time>}
```

with:

```astro
    {(d.summary ?? d.caption) && <p class="p-summary">{d.summary ?? d.caption}</p>}
    <div class="e-content"><slot /></div>
    {iso && (
      <a class="u-url" href={Astro.url.pathname}>
        <time class="dt-published" datetime={iso}>{human}</time>
      </a>
    )}
```

(An entry carries either a photo `caption` or an article `summary`, never both, so a single `p-summary` covers both.)

- [ ] **Step 2: Build and validate**

Run: `npx astro build && npx tsx scripts/check-microformats.ts`
Expected: NON-ZERO exit still (reviews/events not yet fixed), BUT no remaining `missing u-url` problems for the h-entry collections (`notes/articles/photos/albums/bookmarks/replies/likes/announcements`). Remaining: `reviews` and `events` `missing u-url`.

- [ ] **Step 3: Commit**

```bash
git add Resources/Template/src/layouts/Hentry.astro
git commit -m "feat(#349): emit article p-summary and u-url in Hentry"
```

---

### Task 4: Hreview.astro — add u-url

**Files:**
- Modify: `Resources/Template/src/layouts/Hreview.astro`

**Interfaces:**
- Consumes: CLI from Task 1.
- Produces: valid h-review pages with `u-url`.

- [ ] **Step 1: Wrap the published time in a u-url permalink**

In `src/layouts/Hreview.astro`, replace:

```astro
    {iso && <time class="dt-published" datetime={iso}>{human}</time>}
```

with:

```astro
    {iso && (
      <a class="u-url" href={Astro.url.pathname}>
        <time class="dt-published" datetime={iso}>{human}</time>
      </a>
    )}
```

- [ ] **Step 2: Build and validate**

Run: `npx astro build && npx tsx scripts/check-microformats.ts`
Expected: NON-ZERO exit still (events not yet fixed), BUT no remaining `reviews/...: h-review missing u-url`. Only `events` `missing u-url` remains.

- [ ] **Step 3: Commit**

```bash
git add Resources/Template/src/layouts/Hreview.astro
git commit -m "feat(#349): add u-url permalink to Hreview"
```

---

### Task 5: Hevent.astro — add u-url

**Files:**
- Modify: `Resources/Template/src/layouts/Hevent.astro`

**Interfaces:**
- Consumes: CLI from Task 1.
- Produces: valid h-event pages with `u-url`. After this task, `validateDist` returns zero problems.

- [ ] **Step 1: Wrap the start time in a u-url permalink**

In `src/layouts/Hevent.astro`, replace:

```astro
    {startISO && <time class="dt-start" datetime={startISO}>{startHuman}</time>}
```

with:

```astro
    {startISO && (
      <a class="u-url" href={Astro.url.pathname}>
        <time class="dt-start" datetime={startISO}>{startHuman}</time>
      </a>
    )}
```

(Leave the `dt-end` `<time>` unchanged — it is not the permalink.)

- [ ] **Step 2: Build and validate — expect a clean pass now**

Run: `npx astro build && npx tsx scripts/check-microformats.ts`
Expected: ZERO exit — `✓ microformats validation passed`. All entry pages valid; h-entry/h-review/h-event coverage all satisfied.

- [ ] **Step 3: Commit**

```bash
git add Resources/Template/src/layouts/Hevent.astro
git commit -m "feat(#349): add u-url permalink to Hevent"
```

---

### Task 6: Wire the validator into the build and verify end-to-end

**Files:**
- Modify: `Resources/Template/package.json` (`build` script)

**Interfaces:**
- Consumes: `scripts/check-microformats.ts` (Task 1), all layout fixes (Tasks 2–5).
- Produces: a `build` that fails if mf2 output regresses.

- [ ] **Step 1: Add the post-build validation step**

In `Resources/Template/package.json`, change the `build` script from:

```json
"build": "astro check && astro build",
```

to:

```json
"build": "astro check && astro build && npx tsx scripts/check-microformats.ts",
```

- [ ] **Step 2: Run the full build (gate must be green)**

Run: `npm run build`
Expected: PASS — `astro check` clean, `astro build` succeeds, and the final line is `✓ microformats validation passed`. Exit code 0.

- [ ] **Step 3: Run the validator unit tests once more**

Run: `npx tsx --test scripts/microformats.test.ts`
Expected: PASS — `# pass 5`, `# skipped 2`, `# fail 0`.

- [ ] **Step 4: Commit**

```bash
git add Resources/Template/package.json
git commit -m "feat(#349): gate build on microformats validation"
```

---

## Self-Review

**Spec coverage:**
- "Complete h-entry/h-review/h-event coverage in entry layouts" → Tasks 2–5 (BlogPost h-entry; Hentry p-summary + u-url; Hreview u-url; Hevent u-url). ✓
- "Resolve the `TODO(#349)` p-summary" → Task 3. ✓
- "u-url permalink on all entry layouts" → Tasks 2–5. ✓
- "Validator module + CLI + unit tests on node:test" → Task 1. ✓
- "Post-build dist validation wired into build" → Task 6. ✓
- "site-wide h-card / p-author deferred to #388 with skipped placeholders" → Task 1, Step 2 (`{ skip }` tests). ✓
- "Only new dep microformats-parser; no Vitest" → Task 1, Step 1; Global Constraints. ✓

**Placeholder scan:** No TBD/TODO/"handle edge cases" — every code step shows complete code. (The `TODO(#349)` string appears only as the text being *deleted* in Task 3.) ✓

**Type consistency:** `findRoots`, `validateEntryHtml`, `validateDist`, `ENTRY_TYPES`, `ENTRY_DIRS`, `isEntryType` are defined in Task 1 and consumed consistently by the CLI and tests. Property names (`name`, `url`, `published`, `start`, `rating`, `item`, `summary`, `category`, `content`) match microformats-parser's output shape. ✓

**Risk note for the implementer:** the implied-name guard in `validateEntryHtml` relies on `microformats-parser` populating `properties.name` with the concatenated text when no explicit `p-name` exists. If the parser version behaves differently for the `IMPLIED_REVIEW` fixture, keep the `missing u-url` assertion (deterministic) and adjust the implied-name heuristic to match observed parser output — do not weaken the explicit-`p-name` requirement in the real layouts.
