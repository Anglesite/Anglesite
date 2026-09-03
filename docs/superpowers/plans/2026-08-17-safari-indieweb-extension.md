# IndieWeb Safari Extension Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a standalone Safari Web Extension, embedded in `Anglesite.app`, that detects h-cards, feeds, webmentions, ActivityPub links, and general microformats2 on the page the user is viewing in Safari and shows them in a popup toolbar.

**Architecture:** A new `AnglesiteSafariExtension` app-extension Xcode target (embedded in `Anglesite.app`, same pattern as `AnglesiteShareExtension`) hosts a Manifest V3 web extension. All detection/UI logic is TypeScript in a new `JS/safari-extension/` package (mirrors `JS/edit-overlay/`'s toolchain), bundled by esbuild into `Resources/SafariExtension/`. The Swift side is a single boilerplate `SafariWebExtensionHandler` — no native messaging, no dependency on a running `Anglesite.app`.

**Tech Stack:** TypeScript (ES2022, strict), esbuild (IIFE bundles), vitest + jsdom (tests), oxlint, vendored `microformat-shiv` 2.0.3 (MIT) for microformats2 parsing, Manifest V3 Safari Web Extension APIs (`chrome.*` namespace, `chrome.storage.session`).

**Spec:** [`docs/superpowers/specs/2026-08-17-safari-indieweb-extension-design.md`](../specs/2026-08-17-safari-indieweb-extension-design.md)

## Global Constraints

- macOS 27+ / Xcode 27+ / Swift 6.4, matching every other target in `project.yml`.
- Node 22+ (repo pins `24.15.0` in `scripts/node-version.txt`) for the JS package.
- No new Swift dependencies. No native messaging to `Anglesite.app` in v1 (standalone extension).
- `microformat-shiv` is the only new third-party code; it is **vendored** (source committed under REUSE annotation), not installed as an npm runtime dependency.
- Read `CONTRIBUTING.md` in this worktree before starting — commit subject ≤72 chars, PR body uses `.github/PULL_REQUEST_TEMPLATE.md`'s exact headings, `Closes #1098`.
- Every JS package task follows `JS/edit-overlay/`'s existing conventions (TypeScript strict, ES modules, vanilla APIs, oxlint + `tsc --noEmit` + vitest) — do not introduce a different toolchain.

---

### Task 1: `JS/safari-extension` scaffold + feed detection

**Files:**
- Create: `JS/safari-extension/package.json`
- Create: `JS/safari-extension/tsconfig.json`
- Create: `JS/safari-extension/vitest.config.ts`
- Create: `JS/safari-extension/src/types.ts`
- Create: `JS/safari-extension/src/detect/feeds.ts`
- Test: `JS/safari-extension/test/detect/feeds.test.ts`

**Interfaces:**
- Produces: `FeedLink { title: string | null; url: string; type: "rss" | "atom" | "json" }` (types.ts), `detectFeeds(doc: Document): FeedLink[]` (detect/feeds.ts) — consumed by Task 4's `collectFindings`.

- [ ] **Step 1: Scaffold the package**

Create `JS/safari-extension/package.json`:

```json
{
  "name": "@anglesite/safari-extension",
  "version": "0.1.0",
  "private": true,
  "description": "Content script, background worker, and popup for the Anglesite IndieWeb Safari Web Extension (detects h-cards, feeds, webmentions, ActivityPub, and microformats2). Spec: docs/superpowers/specs/2026-08-17-safari-indieweb-extension-design.md",
  "type": "module",
  "scripts": {
    "build": "npm run build:content-script && npm run build:background && npm run build:popup",
    "build:content-script": "esbuild src/content-script.ts --bundle --format=iife --target=safari18 --outfile=../../Resources/SafariExtension/content-script.js",
    "build:background": "esbuild src/background.ts --bundle --format=iife --target=safari18 --outfile=../../Resources/SafariExtension/background.js",
    "build:popup": "esbuild src/popup.ts --bundle --format=iife --target=safari18 --outfile=../../Resources/SafariExtension/popup.js",
    "typecheck": "tsc --noEmit",
    "lint": "oxlint src test",
    "test": "vitest run",
    "test:watch": "vitest"
  },
  "devDependencies": {
    "@types/node": "^26.2.0",
    "esbuild": "^0.28.1",
    "jsdom": "^30.0.1",
    "oxlint": "^1.77.0",
    "typescript": "^7.0.2",
    "vitest": "^4.1.10"
  },
  "engines": {
    "node": ">=22"
  }
}
```

Create `JS/safari-extension/tsconfig.json`:

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "lib": ["ES2022", "DOM", "DOM.Iterable"],
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "noImplicitOverride": true,
    "esModuleInterop": true,
    "isolatedModules": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,
    "verbatimModuleSyntax": true,
    "noEmit": true
  },
  "include": ["src/**/*.ts", "test/**/*.ts", "vendor/**/*.d.ts"]
}
```

Create `JS/safari-extension/vitest.config.ts`:

```typescript
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // `environment` is set per-file via `// @vitest-environment` so pure-logic tests can stay
    // on Node and DOM-behavior tests can opt in to jsdom. Default to node for speed.
    environment: "node",
    include: ["test/**/*.test.ts"],
  },
});
```

Run: `cd JS/safari-extension && npm install`
Expected: `package-lock.json` created, `node_modules/` populated, no errors.

- [ ] **Step 2: Write shared types**

Create `JS/safari-extension/src/types.ts`:

```typescript
export interface FeedLink {
  title: string | null;
  url: string;
  type: "rss" | "atom" | "json";
}
```

- [ ] **Step 3: Write the failing test for feed detection**

Create `JS/safari-extension/test/detect/feeds.test.ts`:

```typescript
// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
import { detectFeeds } from "../../src/detect/feeds";

function parse(html: string): Document {
  return new DOMParser().parseFromString(html, "text/html");
}

describe("detectFeeds", () => {
  it("finds RSS, Atom, and JSON feed links", () => {
    const doc = parse(`
      <html><head>
        <link rel="alternate" type="application/rss+xml" title="RSS" href="/feed.rss">
        <link rel="alternate" type="application/atom+xml" title="Atom" href="/feed.atom">
        <link rel="alternate" type="application/feed+json" href="/feed.json">
      </head><body></body></html>
    `);
    const feeds = detectFeeds(doc);
    expect(feeds).toEqual([
      { title: "RSS", url: "https://example.com/feed.rss", type: "rss" },
      { title: "Atom", url: "https://example.com/feed.atom", type: "atom" },
      { title: null, url: "https://example.com/feed.json", type: "json" },
    ]);
  });

  it("ignores unrelated alternate links and links with no href", () => {
    const doc = parse(`
      <html><head>
        <link rel="alternate" type="text/html" href="/print">
        <link rel="alternate" type="application/rss+xml">
      </head><body></body></html>
    `);
    expect(detectFeeds(doc)).toEqual([]);
  });
});
```

- [ ] **Step 4: Run test to verify it fails**

Run: `cd JS/safari-extension && npx vitest run test/detect/feeds.test.ts`
Expected: FAIL — `Cannot find module '../../src/detect/feeds'`

- [ ] **Step 5: Implement feed detection**

Create `JS/safari-extension/src/detect/feeds.ts`:

```typescript
import type { FeedLink } from "../types";

const FEED_MIME_TYPES: Record<string, FeedLink["type"]> = {
  "application/rss+xml": "rss",
  "application/atom+xml": "atom",
  "application/feed+json": "json",
};

export function detectFeeds(doc: Document): FeedLink[] {
  const links = doc.querySelectorAll<HTMLLinkElement>('link[rel~="alternate"][href]');
  const feeds: FeedLink[] = [];
  for (const link of links) {
    const mimeType = (link.getAttribute("type") ?? "").toLowerCase();
    const feedType = FEED_MIME_TYPES[mimeType];
    if (!feedType) continue;
    const href = link.getAttribute("href");
    if (!href) continue;
    feeds.push({
      title: link.getAttribute("title"),
      url: new URL(href, doc.baseURI).href,
      type: feedType,
    });
  }
  return feeds;
}
```

Note: `doc.baseURI` for a document parsed via `DOMParser` in jsdom's default environment resolves against `https://example.com/` unless the test sets `document.location` — the test above relies on jsdom's default test URL. If jsdom's default origin differs, adjust the expected URLs to match `doc.baseURI` rather than hardcoding `https://example.com/` blindly — confirm the actual value the test run prints on first failure.

- [ ] **Step 6: Run test to verify it passes**

Run: `cd JS/safari-extension && npx vitest run test/detect/feeds.test.ts`
Expected: PASS (2 tests). If the URLs don't match due to jsdom's default base URL, fix the test's expected strings to match the actual `doc.baseURI` jsdom uses, not the implementation.

- [ ] **Step 7: Lint and typecheck**

Run: `cd JS/safari-extension && npm run lint && npm run typecheck`
Expected: both exit 0.

- [ ] **Step 8: Commit**

```bash
git add JS/safari-extension/package.json JS/safari-extension/package-lock.json \
  JS/safari-extension/tsconfig.json JS/safari-extension/vitest.config.ts \
  JS/safari-extension/src/types.ts JS/safari-extension/src/detect/feeds.ts \
  JS/safari-extension/test/detect/feeds.test.ts
git commit -m "feat(#1098): scaffold safari-extension package, add feed detection"
```

---

### Task 2: Webmention and ActivityPub link detection

**Files:**
- Create: `JS/safari-extension/src/detect/webmention.ts`
- Create: `JS/safari-extension/src/detect/activitypub.ts`
- Test: `JS/safari-extension/test/detect/webmention.test.ts`
- Test: `JS/safari-extension/test/detect/activitypub.test.ts`

**Interfaces:**
- Consumes: nothing new.
- Produces: `detectWebmentionLinkTag(doc: Document): string | null`, `detectActivityPubLink(doc: Document): string | null` — both consumed by Task 4's `collectFindings`.

- [ ] **Step 1: Write the failing tests**

Create `JS/safari-extension/test/detect/webmention.test.ts`:

```typescript
// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
import { detectWebmentionLinkTag } from "../../src/detect/webmention";

function parse(html: string): Document {
  return new DOMParser().parseFromString(html, "text/html");
}

describe("detectWebmentionLinkTag", () => {
  it("finds a link[rel=webmention]", () => {
    const doc = parse(`<html><head><link rel="webmention" href="/webmention"></head></html>`);
    expect(detectWebmentionLinkTag(doc)).toBe("https://example.com/webmention");
  });

  it("finds an a[rel=webmention] in the body", () => {
    const doc = parse(`<html><body><a rel="webmention" href="/wm">webmention</a></body></html>`);
    expect(detectWebmentionLinkTag(doc)).toBe("https://example.com/wm");
  });

  it("returns null when absent", () => {
    const doc = parse(`<html><head></head><body></body></html>`);
    expect(detectWebmentionLinkTag(doc)).toBeNull();
  });
});
```

Create `JS/safari-extension/test/detect/activitypub.test.ts`:

```typescript
// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
import { detectActivityPubLink } from "../../src/detect/activitypub";

function parse(html: string): Document {
  return new DOMParser().parseFromString(html, "text/html");
}

describe("detectActivityPubLink", () => {
  it("finds an activity+json alternate link", () => {
    const doc = parse(
      `<html><head><link rel="alternate" type="application/activity+json" href="/actor"></head></html>`
    );
    expect(detectActivityPubLink(doc)).toBe("https://example.com/actor");
  });

  it("returns null when absent", () => {
    const doc = parse(`<html><head></head></html>`);
    expect(detectActivityPubLink(doc)).toBeNull();
  });

  it("ignores activity+json links that aren't rel=alternate", () => {
    const doc = parse(`<html><head><link rel="me" type="application/activity+json" href="/x"></head></html>`);
    expect(detectActivityPubLink(doc)).toBeNull();
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd JS/safari-extension && npx vitest run test/detect/webmention.test.ts test/detect/activitypub.test.ts`
Expected: FAIL — modules not found.

- [ ] **Step 3: Implement both detectors**

Create `JS/safari-extension/src/detect/webmention.ts`:

```typescript
export function detectWebmentionLinkTag(doc: Document): string | null {
  const link = doc.querySelector<HTMLLinkElement | HTMLAnchorElement>(
    'link[rel~="webmention"][href], a[rel~="webmention"][href]'
  );
  const href = link?.getAttribute("href");
  return href ? new URL(href, doc.baseURI).href : null;
}
```

Create `JS/safari-extension/src/detect/activitypub.ts`:

```typescript
export function detectActivityPubLink(doc: Document): string | null {
  const link = doc.querySelector<HTMLLinkElement>(
    'link[rel~="alternate"][type="application/activity+json"][href]'
  );
  const href = link?.getAttribute("href");
  return href ? new URL(href, doc.baseURI).href : null;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd JS/safari-extension && npx vitest run test/detect/webmention.test.ts test/detect/activitypub.test.ts`
Expected: PASS (6 tests total).

- [ ] **Step 5: Lint and typecheck**

Run: `cd JS/safari-extension && npm run lint && npm run typecheck`
Expected: both exit 0.

- [ ] **Step 6: Commit**

```bash
git add JS/safari-extension/src/detect/webmention.ts JS/safari-extension/src/detect/activitypub.ts \
  JS/safari-extension/test/detect/webmention.test.ts JS/safari-extension/test/detect/activitypub.test.ts
git commit -m "feat(#1098): add webmention and ActivityPub link detection"
```

---

### Task 3: Vendor microformat-shiv and add the mf2 wrapper

**Files:**
- Create: `JS/safari-extension/vendor/microformat-shiv/microformat-shiv.cjs`
- Create: `JS/safari-extension/vendor/microformat-shiv/microformat-shiv.d.ts`
- Create: `JS/safari-extension/src/detect/microformats.ts`
- Test: `JS/safari-extension/test/detect/microformats.test.ts`
- Modify: `REUSE.toml`
- Create: `LICENSES/MIT.txt` (via `reuse download`)

**Interfaces:**
- Produces: `MF2Item { type: string[]; properties: Record<string, unknown[]>; children?: MF2Item[] }`, `MF2Document { items: MF2Item[]; rels: Record<string, string[]>; "rel-urls": Record<string, { rels: string[]; text?: string }> }`, `parseMicroformats(doc: Document): MF2Document`, `findFirstHCard(mf2: MF2Document): MF2Item | null`, `summarizeTypes(mf2: MF2Document): Record<string, number>` — consumed by Task 4 (`collectFindings`), Task 6 (`buildVCard`), Task 7 (popup render).

- [ ] **Step 1: Vendor the library**

Download the pinned release and rename its extension to `.cjs` — the file is written as a UMD module whose non-CommonJS fallback branch (`root.Microformats = factory()`) assigns to `this`, which is `undefined` at module top level under real ES module evaluation (Node's `"type": "module"` in `package.json`, or esbuild's ESM output). Under a `.cjs` extension, Node and esbuild both force CommonJS evaluation regardless of the package's `"type"` field, so the file's `typeof exports === 'object'` branch — the CommonJS branch that does `module.exports = factory()` — runs correctly instead.

```bash
mkdir -p JS/safari-extension/vendor/microformat-shiv
curl -sL "https://raw.githubusercontent.com/glennjones/microformat-shiv/v2.0.3/microformat-shiv.js" \
  -o JS/safari-extension/vendor/microformat-shiv/microformat-shiv.cjs
```

Run: `head -8 JS/safari-extension/vendor/microformat-shiv/microformat-shiv.cjs`
Expected: the file's header comment block (`microformat-shiv - v2.0.2 ... Licensed MIT`) — the internal version-string comment lags the npm/git tag (says "v2.0.2" even at the `v2.0.3` git tag); that is a known upstream inconsistency in the library itself, not a mistake in this step.

- [ ] **Step 2: Add TypeScript ambient types for the vendored file**

Create `JS/safari-extension/vendor/microformat-shiv/microformat-shiv.d.ts`:

```typescript
declare module "*microformat-shiv.cjs" {
  interface MicroformatShivOptions {
    node?: Node;
    html?: string;
    baseUrl?: string;
    filters?: string[];
  }

  interface MicroformatShivItem {
    type: string[];
    properties: Record<string, unknown[]>;
    children?: MicroformatShivItem[];
  }

  interface MicroformatShivDocument {
    items: MicroformatShivItem[];
    rels: Record<string, string[]>;
    "rel-urls": Record<string, { rels: string[]; text?: string }>;
  }

  interface MicroformatShivAPI {
    get(options?: MicroformatShivOptions): MicroformatShivDocument;
  }

  const Microformats: MicroformatShivAPI;
  export default Microformats;
}
```

- [ ] **Step 3: Write the failing test**

Create `JS/safari-extension/test/detect/microformats.test.ts`:

```typescript
// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
import { findFirstHCard, parseMicroformats, summarizeTypes } from "../../src/detect/microformats";

function parse(html: string): Document {
  return new DOMParser().parseFromString(html, "text/html");
}

describe("parseMicroformats", () => {
  it("parses an h-card with explicit properties", () => {
    const doc = parse(`
      <body>
        <div class="h-card">
          <a class="p-name u-url" href="https://example.com/glenn">Glenn Jones</a>
          <p class="p-org">Example Org</p>
        </div>
      </body>
    `);
    const mf2 = parseMicroformats(doc);
    const hCard = findFirstHCard(mf2);
    expect(hCard?.type).toEqual(["h-card"]);
    expect(hCard?.properties.name).toEqual(["Glenn Jones"]);
    expect(hCard?.properties.org).toEqual(["Example Org"]);
  });

  it("returns null when there is no h-card", () => {
    const doc = parse(`<body><p>Nothing here.</p></body>`);
    expect(findFirstHCard(parseMicroformats(doc))).toBeNull();
  });

  it("collects rel=me links", () => {
    const doc = parse(`<body><a rel="me" href="https://fosstodon.org/@example">Mastodon</a></body>`);
    const mf2 = parseMicroformats(doc);
    expect(mf2.rels.me).toEqual(["https://fosstodon.org/@example"]);
  });

  it("summarizes root and nested mf2 type counts", () => {
    const doc = parse(`
      <body>
        <div class="h-feed">
          <div class="h-entry"><p class="p-name">One</p></div>
          <div class="h-entry"><p class="p-name">Two</p></div>
        </div>
      </body>
    `);
    const counts = summarizeTypes(parseMicroformats(doc));
    expect(counts["h-feed"]).toBe(1);
    expect(counts["h-entry"]).toBe(2);
  });
});
```

- [ ] **Step 4: Run test to verify it fails**

Run: `cd JS/safari-extension && npx vitest run test/detect/microformats.test.ts`
Expected: FAIL — `Cannot find module '../../src/detect/microformats'`

- [ ] **Step 5: Implement the mf2 wrapper**

Create `JS/safari-extension/src/detect/microformats.ts`:

```typescript
import Microformats from "../../vendor/microformat-shiv/microformat-shiv.cjs";

export interface MF2Item {
  type: string[];
  properties: Record<string, unknown[]>;
  children?: MF2Item[];
}

export interface MF2Document {
  items: MF2Item[];
  rels: Record<string, string[]>;
  "rel-urls": Record<string, { rels: string[]; text?: string }>;
}

export function parseMicroformats(doc: Document): MF2Document {
  return Microformats.get({ node: doc.body }) as MF2Document;
}

export function findFirstHCard(mf2: MF2Document): MF2Item | null {
  return mf2.items.find((item) => item.type.includes("h-card")) ?? null;
}

export function summarizeTypes(mf2: MF2Document): Record<string, number> {
  const counts: Record<string, number> = {};
  const visit = (item: MF2Item): void => {
    for (const type of item.type) {
      counts[type] = (counts[type] ?? 0) + 1;
    }
    for (const child of item.children ?? []) {
      visit(child);
    }
  };
  for (const item of mf2.items) {
    visit(item);
  }
  return counts;
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `cd JS/safari-extension && npx vitest run test/detect/microformats.test.ts`
Expected: PASS (4 tests). If `parseMicroformats` throws because `microformat-shiv` expects browser globals (`DOMParser`, `document`) that jsdom's test environment doesn't fully provide, the `// @vitest-environment jsdom` pragma at the top of the test file is what supplies them — confirm it's present before debugging further.

- [ ] **Step 7: Lint and typecheck**

Run: `cd JS/safari-extension && npm run lint && npm run typecheck`
Expected: both exit 0. `microformat-shiv.cjs` itself is untyped vendored code and is not linted (oxlint's default target is `src test`, which doesn't include `vendor/`).

- [ ] **Step 8: License the vendored file under REUSE**

Add the canonical MIT text (matches how `LICENSES/ISC.txt` was obtained per `CONTRIBUTING.md` ▸ "License"):

```bash
uvx reuse download MIT
```

Expected: creates `LICENSES/MIT.txt`.

Add a new annotation block to `REUSE.toml`, directly after the existing `path = "**"` block (this repo's first real vendored-code annotation — see the comment above that block explaining why narrower blocks are needed for vendored paths):

```toml
[[annotations]]
path = "JS/safari-extension/vendor/microformat-shiv/**"
precedence = "override"
SPDX-FileCopyrightText = "2016 Glenn Jones"
SPDX-License-Identifier = "MIT"
```

- [ ] **Step 9: Verify REUSE compliance**

Run: `uvx reuse lint`
Expected: exits 0 (or informs REUSE.toml is already valid — the tool should report the vendored path is now correctly licensed as MIT rather than falling under the repo-wide ISC override).

- [ ] **Step 10: Commit**

```bash
git add JS/safari-extension/vendor JS/safari-extension/src/detect/microformats.ts \
  JS/safari-extension/test/detect/microformats.test.ts REUSE.toml LICENSES/MIT.txt
git commit -m "feat(#1098): vendor microformat-shiv, add mf2 parsing wrapper"
```

---

### Task 4: Content script — findings orchestration

**Files:**
- Modify: `JS/safari-extension/src/types.ts`
- Create: `JS/safari-extension/src/content-script.ts`
- Test: `JS/safari-extension/test/content-script.test.ts`

**Interfaces:**
- Consumes: `detectFeeds` (Task 1), `detectWebmentionLinkTag`, `detectActivityPubLink` (Task 2), `parseMicroformats`, `findFirstHCard`, `summarizeTypes`, `MF2Document`, `MF2Item` (Task 3).
- Produces: `Findings { pageUrl: string; pageTitle: string; feeds: FeedLink[]; webmentionUrl: string | null; activityPubUrl: string | null; relMeLinks: string[]; mf2: MF2Document; mf2TypeCounts: Record<string, number>; hCard: MF2Item | null }` (types.ts), `collectFindings(doc: Document): Findings` (content-script.ts) — consumed by Task 5 (background message shape), Task 6/7/8 (popup).

- [ ] **Step 1: Extend the shared types**

Modify `JS/safari-extension/src/types.ts` to add the `Findings` type below the existing `FeedLink`:

```typescript
import type { MF2Document, MF2Item } from "./detect/microformats";

export interface Findings {
  pageUrl: string;
  pageTitle: string;
  feeds: FeedLink[];
  webmentionUrl: string | null;
  activityPubUrl: string | null;
  relMeLinks: string[];
  mf2: MF2Document;
  mf2TypeCounts: Record<string, number>;
  hCard: MF2Item | null;
}
```

- [ ] **Step 2: Write the failing test**

Create `JS/safari-extension/test/content-script.test.ts`:

```typescript
// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
import { collectFindings } from "../src/content-script";

function parse(html: string): Document {
  return new DOMParser().parseFromString(html, "text/html");
}

describe("collectFindings", () => {
  it("assembles feeds, webmention, ActivityPub, rel=me, and h-card into one Findings object", () => {
    const doc = parse(`
      <html><head>
        <title>Example</title>
        <link rel="alternate" type="application/rss+xml" href="/feed.rss">
        <link rel="webmention" href="/webmention">
        <link rel="alternate" type="application/activity+json" href="/actor">
      </head><body>
        <a rel="me" href="https://fosstodon.org/@example">Mastodon</a>
        <div class="h-card"><span class="p-name">Example Person</span></div>
      </body></html>
    `);
    const findings = collectFindings(doc);
    expect(findings.pageTitle).toBe("Example");
    expect(findings.feeds).toHaveLength(1);
    expect(findings.webmentionUrl).toBe("https://example.com/webmention");
    expect(findings.activityPubUrl).toBe("https://example.com/actor");
    expect(findings.relMeLinks).toEqual(["https://fosstodon.org/@example"]);
    expect(findings.hCard?.properties.name).toEqual(["Example Person"]);
    expect(findings.mf2TypeCounts["h-card"]).toBe(1);
  });

  it("returns empty/null fields for a page with nothing detectable", () => {
    const doc = parse(`<html><head><title>Blank</title></head><body></body></html>`);
    const findings = collectFindings(doc);
    expect(findings.feeds).toEqual([]);
    expect(findings.webmentionUrl).toBeNull();
    expect(findings.activityPubUrl).toBeNull();
    expect(findings.relMeLinks).toEqual([]);
    expect(findings.hCard).toBeNull();
  });
});
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd JS/safari-extension && npx vitest run test/content-script.test.ts`
Expected: FAIL — `Cannot find module '../src/content-script'`

- [ ] **Step 4: Implement `collectFindings` and the content-script entry point**

Create `JS/safari-extension/src/content-script.ts`:

```typescript
import { detectActivityPubLink } from "./detect/activitypub";
import { detectFeeds } from "./detect/feeds";
import { findFirstHCard, parseMicroformats, summarizeTypes } from "./detect/microformats";
import { detectWebmentionLinkTag } from "./detect/webmention";
import type { Findings } from "./types";

export function collectFindings(doc: Document): Findings {
  const mf2 = parseMicroformats(doc);
  return {
    pageUrl: doc.location?.href ?? doc.baseURI,
    pageTitle: doc.title,
    feeds: detectFeeds(doc),
    webmentionUrl: detectWebmentionLinkTag(doc),
    activityPubUrl: detectActivityPubLink(doc),
    relMeLinks: mf2.rels.me ?? [],
    mf2,
    mf2TypeCounts: summarizeTypes(mf2),
    hCard: findFirstHCard(mf2),
  };
}

// Entry-point wiring: reports this page's findings to the background script. Guarded so this
// module stays importable (and `collectFindings` testable) outside a real extension context —
// `chrome` only exists when this bundle is actually running as the content script.
declare const chrome: { runtime: { sendMessage(message: unknown): void } } | undefined;

if (typeof document !== "undefined" && typeof chrome !== "undefined") {
  chrome.runtime.sendMessage({ type: "FINDINGS", findings: collectFindings(document) });
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd JS/safari-extension && npx vitest run test/content-script.test.ts`
Expected: PASS (2 tests).

- [ ] **Step 6: Lint and typecheck**

Run: `cd JS/safari-extension && npm run lint && npm run typecheck`
Expected: both exit 0.

- [ ] **Step 7: Commit**

```bash
git add JS/safari-extension/src/types.ts JS/safari-extension/src/content-script.ts \
  JS/safari-extension/test/content-script.test.ts
git commit -m "feat(#1098): assemble page findings in the content script"
```

---

### Task 5: Background service worker

**Files:**
- Create: `JS/safari-extension/src/background.ts`
- Test: `JS/safari-extension/test/background.test.ts`

**Interfaces:**
- Consumes: `Findings` (Task 4).
- Produces: `countFindings(findings: Findings): number`, `badgeTextFor(count: number): string`, `isFindingsMessage(message: unknown): message is { type: "FINDINGS"; findings: Findings }`, `parseWebmentionHeader(headerValue: string, baseUrl: string): string | null` — the first two are consumed by Task 8's manifest/popup expectations (badge display) conceptually; none are consumed directly by later *code* tasks, but this task's wiring is what makes the popup's stored findings (read in Task 8) exist at runtime.

- [ ] **Step 1: Write the failing tests**

Create `JS/safari-extension/test/background.test.ts`:

```typescript
import { describe, expect, it } from "vitest";
import { badgeTextFor, countFindings, isFindingsMessage, parseWebmentionHeader } from "../src/background";
import type { Findings } from "../src/types";

function emptyFindings(overrides: Partial<Findings> = {}): Findings {
  return {
    pageUrl: "https://example.com/",
    pageTitle: "Example",
    feeds: [],
    webmentionUrl: null,
    activityPubUrl: null,
    relMeLinks: [],
    mf2: { items: [], rels: {}, "rel-urls": {} },
    mf2TypeCounts: {},
    hCard: null,
    ...overrides,
  };
}

describe("countFindings", () => {
  it("counts feeds, webmention, ActivityPub, h-card, and rel=me links", () => {
    const findings = emptyFindings({
      feeds: [{ title: "RSS", url: "https://example.com/feed.rss", type: "rss" }],
      webmentionUrl: "https://example.com/webmention",
      activityPubUrl: "https://example.com/actor",
      relMeLinks: ["https://fosstodon.org/@example"],
      hCard: { type: ["h-card"], properties: {} },
    });
    expect(countFindings(findings)).toBe(5);
  });

  it("returns 0 for empty findings", () => {
    expect(countFindings(emptyFindings())).toBe(0);
  });
});

describe("badgeTextFor", () => {
  it("is empty for zero", () => {
    expect(badgeTextFor(0)).toBe("");
  });

  it("stringifies a positive count", () => {
    expect(badgeTextFor(3)).toBe("3");
  });
});

describe("isFindingsMessage", () => {
  it("accepts a well-formed FINDINGS message", () => {
    expect(isFindingsMessage({ type: "FINDINGS", findings: emptyFindings() })).toBe(true);
  });

  it("rejects other shapes", () => {
    expect(isFindingsMessage(null)).toBe(false);
    expect(isFindingsMessage({ type: "OTHER" })).toBe(false);
    expect(isFindingsMessage("FINDINGS")).toBe(false);
  });
});

describe("parseWebmentionHeader", () => {
  it("extracts the URL from a Link header advertising rel=webmention", () => {
    const header = '<https://example.com/webmention>; rel="webmention"';
    expect(parseWebmentionHeader(header, "https://example.com/post")).toBe("https://example.com/webmention");
  });

  it("resolves a relative URL against the response URL", () => {
    const header = '</wm>; rel="webmention"';
    expect(parseWebmentionHeader(header, "https://example.com/post")).toBe("https://example.com/wm");
  });

  it("returns null when the header has no webmention rel", () => {
    expect(parseWebmentionHeader('<https://example.com/x>; rel="next"', "https://example.com/")).toBeNull();
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd JS/safari-extension && npx vitest run test/background.test.ts`
Expected: FAIL — `Cannot find module '../src/background'`

- [ ] **Step 3: Implement the pure helpers and the service-worker wiring**

Create `JS/safari-extension/src/background.ts`:

```typescript
import type { Findings } from "./types";

export interface FindingsMessage {
  type: "FINDINGS";
  findings: Findings;
}

export function isFindingsMessage(message: unknown): message is FindingsMessage {
  return (
    typeof message === "object" &&
    message !== null &&
    (message as { type?: unknown }).type === "FINDINGS" &&
    "findings" in message
  );
}

export function countFindings(findings: Findings): number {
  let count = findings.feeds.length + findings.relMeLinks.length;
  if (findings.webmentionUrl) count += 1;
  if (findings.activityPubUrl) count += 1;
  if (findings.hCard) count += 1;
  return count;
}

export function badgeTextFor(count: number): string {
  return count > 0 ? String(count) : "";
}

const WEBMENTION_LINK = /<([^>]+)>\s*;\s*rel="webmention"/i;

export function parseWebmentionHeader(headerValue: string, baseUrl: string): string | null {
  const match = WEBMENTION_LINK.exec(headerValue);
  return match ? new URL(match[1], baseUrl).href : null;
}

// Service-worker wiring below. Guarded so the pure helpers above stay unit-testable outside a
// real extension context (no `chrome` global under vitest).
interface ChromeLike {
  runtime: { onMessage: { addListener(cb: (message: unknown, sender: { tab?: { id?: number } }) => void): void } };
  storage: {
    session: {
      set(items: Record<string, unknown>): Promise<void>;
      get(key: string): Promise<Record<string, unknown>>;
    };
  };
  action: { setBadgeText(details: { tabId: number; text: string }): void };
  tabs: { onRemoved: { addListener(cb: (tabId: number) => void): void } };
  webRequest: {
    onHeadersReceived: {
      addListener(
        cb: (details: {
          tabId: number;
          url: string;
          responseHeaders?: { name: string; value?: string }[];
        }) => void,
        filter: { urls: string[]; types: string[] },
        extraInfoSpec: string[]
      ): void;
    };
  };
}

declare const chrome: ChromeLike | undefined;

if (typeof chrome !== "undefined") {
  chrome.runtime.onMessage.addListener((message, sender) => {
    const tabId = sender.tab?.id;
    if (tabId === undefined || !isFindingsMessage(message)) return;
    void chrome.storage.session.set({ [String(tabId)]: message.findings });
    chrome.action.setBadgeText({ tabId, text: badgeTextFor(countFindings(message.findings)) });
  });

  chrome.tabs.onRemoved.addListener((tabId) => {
    void chrome.storage.session.set({ [String(tabId)]: null });
  });

  chrome.webRequest.onHeadersReceived.addListener(
    (details) => {
      if (details.tabId < 0) return;
      const linkHeader = details.responseHeaders?.find((h) => h.name.toLowerCase() === "link");
      const webmentionUrl = linkHeader?.value ? parseWebmentionHeader(linkHeader.value, details.url) : null;
      if (!webmentionUrl) return;
      void chrome.storage.session.get(String(details.tabId)).then((stored) => {
        const existing = stored[String(details.tabId)] as Findings | undefined;
        if (!existing || existing.webmentionUrl) return;
        const merged: Findings = { ...existing, webmentionUrl };
        void chrome.storage.session.set({ [String(details.tabId)]: merged });
        chrome.action.setBadgeText({ tabId: details.tabId, text: badgeTextFor(countFindings(merged)) });
      });
    },
    { urls: ["<all_urls>"], types: ["main_frame"] },
    ["responseHeaders"]
  );
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd JS/safari-extension && npx vitest run test/background.test.ts`
Expected: PASS (9 tests).

- [ ] **Step 5: Lint and typecheck**

Run: `cd JS/safari-extension && npm run lint && npm run typecheck`
Expected: both exit 0.

- [ ] **Step 6: Commit**

```bash
git add JS/safari-extension/src/background.ts JS/safari-extension/test/background.test.ts
git commit -m "feat(#1098): add background service worker (badge, tab state, webmention headers)"
```

---

### Task 6: vCard export

**Files:**
- Create: `JS/safari-extension/src/popup/vcard.ts`
- Test: `JS/safari-extension/test/popup/vcard.test.ts`

**Interfaces:**
- Consumes: `MF2Item` (Task 3).
- Produces: `buildVCard(hCard: MF2Item): string` — consumed by Task 7 (popup render).

- [ ] **Step 1: Write the failing test**

Create `JS/safari-extension/test/popup/vcard.test.ts`:

```typescript
import { describe, expect, it } from "vitest";
import { buildVCard } from "../../src/popup/vcard";
import type { MF2Item } from "../../src/detect/microformats";

describe("buildVCard", () => {
  it("renders a vCard from h-card properties", () => {
    const hCard: MF2Item = {
      type: ["h-card"],
      properties: {
        name: ["Glenn Jones"],
        org: ["Example Org"],
        url: ["https://example.com/glenn"],
        email: ["mailto:glenn@example.com"],
      },
    };
    const vcard = buildVCard(hCard);
    expect(vcard).toContain("BEGIN:VCARD");
    expect(vcard).toContain("FN:Glenn Jones");
    expect(vcard).toContain("ORG:Example Org");
    expect(vcard).toContain("URL:https://example.com/glenn");
    expect(vcard).toContain("EMAIL:glenn@example.com");
    expect(vcard).toContain("END:VCARD");
  });

  it("omits optional lines that have no value and falls back to Unknown for a missing name", () => {
    const hCard: MF2Item = { type: ["h-card"], properties: {} };
    const vcard = buildVCard(hCard);
    expect(vcard).toContain("FN:Unknown");
    expect(vcard).not.toContain("ORG:");
    expect(vcard).not.toContain("URL:");
    expect(vcard).not.toContain("EMAIL:");
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd JS/safari-extension && npx vitest run test/popup/vcard.test.ts`
Expected: FAIL — `Cannot find module '../../src/popup/vcard'`

- [ ] **Step 3: Implement `buildVCard`**

Create `JS/safari-extension/src/popup/vcard.ts`:

```typescript
import type { MF2Item } from "../detect/microformats";

function firstValue(properties: Record<string, unknown[]>, key: string): string | null {
  const value = properties[key]?.[0];
  return typeof value === "string" ? value : null;
}

export function buildVCard(hCard: MF2Item): string {
  const name = firstValue(hCard.properties, "name") ?? "Unknown";
  const org = firstValue(hCard.properties, "org");
  const url = firstValue(hCard.properties, "url");
  const email = firstValue(hCard.properties, "email");

  const lines = ["BEGIN:VCARD", "VERSION:3.0", `FN:${name}`];
  if (org) lines.push(`ORG:${org}`);
  if (url) lines.push(`URL:${url}`);
  if (email) lines.push(`EMAIL:${email.replace(/^mailto:/i, "")}`);
  lines.push("END:VCARD");
  return lines.join("\r\n");
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd JS/safari-extension && npx vitest run test/popup/vcard.test.ts`
Expected: PASS (2 tests).

- [ ] **Step 5: Lint and typecheck**

Run: `cd JS/safari-extension && npm run lint && npm run typecheck`
Expected: both exit 0.

- [ ] **Step 6: Commit**

```bash
git add JS/safari-extension/src/popup/vcard.ts JS/safari-extension/test/popup/vcard.test.ts
git commit -m "feat(#1098): add vCard export for detected h-cards"
```

---

### Task 7: Popup render logic

**Files:**
- Create: `JS/safari-extension/src/popup/render.ts`
- Test: `JS/safari-extension/test/popup/render.test.ts`

**Interfaces:**
- Consumes: `Findings` (Task 4), `buildVCard` (Task 6).
- Produces: `renderPopup(container: HTMLElement, findings: Findings | null): void` — consumed by Task 8's `popup.ts`.

- [ ] **Step 1: Write the failing test**

Create `JS/safari-extension/test/popup/render.test.ts`:

```typescript
// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
import { renderPopup } from "../../src/popup/render";
import type { Findings } from "../../src/types";

function emptyFindings(overrides: Partial<Findings> = {}): Findings {
  return {
    pageUrl: "https://example.com/",
    pageTitle: "Example",
    feeds: [],
    webmentionUrl: null,
    activityPubUrl: null,
    relMeLinks: [],
    mf2: { items: [], rels: {}, "rel-urls": {} },
    mf2TypeCounts: {},
    hCard: null,
    ...overrides,
  };
}

describe("renderPopup", () => {
  it("shows an empty state when there is no active tab", () => {
    const container = document.createElement("div");
    renderPopup(container, null);
    expect(container.textContent).toContain("No page selected");
  });

  it("shows a nothing-found state when findings has nothing detected", () => {
    const container = document.createElement("div");
    renderPopup(container, emptyFindings());
    expect(container.textContent).toContain("Nothing found");
  });

  it("renders an h-card section with a copy-vCard button", () => {
    const container = document.createElement("div");
    renderPopup(
      container,
      emptyFindings({ hCard: { type: ["h-card"], properties: { name: ["Glenn Jones"] } } })
    );
    expect(container.querySelector(".h-card-section h2")?.textContent).toBe("Glenn Jones");
    const button = container.querySelector<HTMLButtonElement>(".h-card-section button");
    expect(button?.dataset.vcard).toContain("FN:Glenn Jones");
  });

  it("renders feed links", () => {
    const container = document.createElement("div");
    renderPopup(
      container,
      emptyFindings({ feeds: [{ title: "RSS", url: "https://example.com/feed.rss", type: "rss" }] })
    );
    const link = container.querySelector<HTMLAnchorElement>(".feeds-section a");
    expect(link?.textContent).toBe("RSS");
    expect(link?.href).toBe("https://example.com/feed.rss");
  });

  it("renders webmention and ActivityPub as endpoint badges with no action buttons", () => {
    const container = document.createElement("div");
    renderPopup(
      container,
      emptyFindings({
        webmentionUrl: "https://example.com/webmention",
        activityPubUrl: "https://example.com/actor",
      })
    );
    expect(container.querySelectorAll(".endpoint-badge")).toHaveLength(2);
    expect(container.querySelectorAll(".endpoint-badge button")).toHaveLength(0);
  });

  it("renders the mf2 type-count tree", () => {
    const container = document.createElement("div");
    renderPopup(container, emptyFindings({ mf2TypeCounts: { "h-entry": 2 }, feeds: [], hCard: null }));
    expect(container.textContent).toContain("h-entry: 2");
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd JS/safari-extension && npx vitest run test/popup/render.test.ts`
Expected: FAIL — `Cannot find module '../../src/popup/render'`

- [ ] **Step 3: Implement `renderPopup`**

Create `JS/safari-extension/src/popup/render.ts`:

```typescript
import type { Findings } from "../types";
import { buildVCard } from "./vcard";

export function renderPopup(container: HTMLElement, findings: Findings | null): void {
  container.innerHTML = "";

  if (!findings) {
    container.appendChild(emptyState("No page selected."));
    return;
  }

  const total = countTotal(findings);
  const header = document.createElement("h1");
  header.textContent = total > 0 ? `${total} IndieWeb feature${total === 1 ? "" : "s"} found` : "Nothing found";
  container.appendChild(header);

  if (total === 0) {
    container.appendChild(emptyState("This page has no detected IndieWeb features."));
    return;
  }

  if (findings.hCard) container.appendChild(renderHCard(findings.hCard));
  if (findings.feeds.length) container.appendChild(renderFeeds(findings.feeds));
  if (findings.webmentionUrl) container.appendChild(renderEndpointBadge("Webmention", findings.webmentionUrl));
  if (findings.activityPubUrl) container.appendChild(renderEndpointBadge("ActivityPub", findings.activityPubUrl));
  if (Object.keys(findings.mf2TypeCounts).length) container.appendChild(renderMf2Tree(findings.mf2TypeCounts));
}

function countTotal(findings: Findings): number {
  return (
    findings.feeds.length +
    findings.relMeLinks.length +
    (findings.webmentionUrl ? 1 : 0) +
    (findings.activityPubUrl ? 1 : 0) +
    (findings.hCard ? 1 : 0)
  );
}

function emptyState(text: string): HTMLElement {
  const p = document.createElement("p");
  p.className = "empty-state";
  p.textContent = text;
  return p;
}

function renderHCard(hCard: NonNullable<Findings["hCard"]>): HTMLElement {
  const section = document.createElement("section");
  section.className = "h-card-section";

  const name = typeof hCard.properties.name?.[0] === "string" ? (hCard.properties.name[0] as string) : "Unknown";
  const heading = document.createElement("h2");
  heading.textContent = name;
  section.appendChild(heading);

  const copyButton = document.createElement("button");
  copyButton.textContent = "Copy vCard";
  copyButton.dataset.vcard = buildVCard(hCard);
  section.appendChild(copyButton);

  return section;
}

function renderFeeds(feeds: Findings["feeds"]): HTMLElement {
  const section = document.createElement("section");
  section.className = "feeds-section";
  const list = document.createElement("ul");
  for (const feed of feeds) {
    const item = document.createElement("li");
    const link = document.createElement("a");
    link.href = feed.url;
    link.target = "_blank";
    link.rel = "noopener noreferrer";
    link.textContent = feed.title ?? feed.url;
    item.appendChild(link);
    list.appendChild(item);
  }
  section.appendChild(list);
  return section;
}

function renderEndpointBadge(label: string, url: string): HTMLElement {
  const p = document.createElement("p");
  p.className = "endpoint-badge";
  const link = document.createElement("a");
  link.href = url;
  link.target = "_blank";
  link.rel = "noopener noreferrer";
  link.textContent = `${label}: view endpoint`;
  p.appendChild(link);
  return p;
}

function renderMf2Tree(counts: Record<string, number>): HTMLElement {
  const details = document.createElement("details");
  const summary = document.createElement("summary");
  summary.textContent = "microformats2 detail";
  details.appendChild(summary);
  const list = document.createElement("ul");
  for (const [type, count] of Object.entries(counts)) {
    const item = document.createElement("li");
    item.textContent = `${type}: ${count}`;
    list.appendChild(item);
  }
  details.appendChild(list);
  return details;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd JS/safari-extension && npx vitest run test/popup/render.test.ts`
Expected: PASS (6 tests).

- [ ] **Step 5: Lint and typecheck**

Run: `cd JS/safari-extension && npm run lint && npm run typecheck`
Expected: both exit 0.

- [ ] **Step 6: Commit**

```bash
git add JS/safari-extension/src/popup/render.ts JS/safari-extension/test/popup/render.test.ts
git commit -m "feat(#1098): render popup detail sections from findings"
```

---

### Task 8: Popup entry point, manifest, static assets, and icons

**Files:**
- Create: `JS/safari-extension/src/popup.ts`
- Create: `Resources/SafariExtension/popup.html`
- Create: `Resources/SafariExtension/popup.css`
- Create: `Resources/SafariExtension/manifest.json`
- Create: `Resources/SafariExtension/images/icon-{48,96,128,256,512}.png` (generated, not hand-authored)

**Interfaces:**
- Consumes: `renderPopup` (Task 7).
- Produces: nothing further code consumes; this is the popup's runtime entry point and the extension's static web resources.

- [ ] **Step 1: Write `popup.ts`**

Create `JS/safari-extension/src/popup.ts`:

```typescript
import { renderPopup } from "./popup/render";
import type { Findings } from "./types";

declare const chrome: {
  tabs: { query(info: { active: boolean; currentWindow: boolean }): Promise<{ id?: number }[]> };
  storage: { session: { get(key: string): Promise<Record<string, unknown>> } };
};

async function main(): Promise<void> {
  const container = document.getElementById("app");
  if (!container) return;

  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (tab?.id === undefined) {
    renderPopup(container, null);
    return;
  }

  const stored = await chrome.storage.session.get(String(tab.id));
  const findings = (stored[String(tab.id)] as Findings | null | undefined) ?? null;
  renderPopup(container, findings);
}

document.addEventListener("click", (event) => {
  const target = event.target;
  if (target instanceof HTMLElement && target.dataset.vcard) {
    void navigator.clipboard.writeText(target.dataset.vcard);
  }
});

void main();
```

This file has no dedicated unit test: it's pure DOM/`chrome` API wiring around the already-tested `renderPopup` (Task 7), matching how `content-script.ts`'s bottom stanza (Task 4) is also wiring rather than logic.

- [ ] **Step 2: Write the static popup markup and styles**

Create `Resources/SafariExtension/popup.html`:

```html
<!doctype html>
<html>
  <head>
    <meta charset="utf-8" />
    <link rel="stylesheet" href="popup.css" />
  </head>
  <body>
    <div id="app"></div>
    <script src="popup.js"></script>
  </body>
</html>
```

Create `Resources/SafariExtension/popup.css`:

```css
body {
  width: 320px;
  margin: 0;
  padding: 12px;
  font: 13px -apple-system, system-ui, sans-serif;
  color: #1c1c1e;
}

h1 {
  font-size: 14px;
  margin: 0 0 8px;
}

h2 {
  font-size: 13px;
  margin: 0 0 4px;
}

section {
  margin-bottom: 12px;
}

ul {
  margin: 0;
  padding-left: 18px;
}

.empty-state {
  color: #6e6e73;
}

.endpoint-badge a {
  color: #0066cc;
}

button {
  font: inherit;
  padding: 4px 8px;
}

@media (prefers-color-scheme: dark) {
  body {
    background: #1c1c1e;
    color: #f2f2f7;
  }

  .empty-state {
    color: #8e8e93;
  }

  .endpoint-badge a {
    color: #409cff;
  }
}
```

- [ ] **Step 3: Generate the toolbar/extension icons from the app icon**

```bash
mkdir -p Resources/SafariExtension/images
SRC=Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png
for size in 48 96 128 256 512; do
  sips -z "$size" "$size" "$SRC" --out "Resources/SafariExtension/images/icon-$size.png"
done
```

Run: `file Resources/SafariExtension/images/icon-*.png`
Expected: five PNG files reporting the matching pixel dimensions (`icon-48.png` → 48 x 48, etc.).

- [ ] **Step 4: Write the manifest**

Create `Resources/SafariExtension/manifest.json`:

```json
{
  "manifest_version": 3,
  "name": "Anglesite IndieWeb",
  "version": "1.0",
  "description": "Detects IndieWeb features on the page you're viewing: h-cards, feeds, webmentions, ActivityPub, and general microformats2.",
  "icons": {
    "48": "images/icon-48.png",
    "96": "images/icon-96.png",
    "128": "images/icon-128.png",
    "256": "images/icon-256.png",
    "512": "images/icon-512.png"
  },
  "background": {
    "service_worker": "background.js",
    "type": "module"
  },
  "action": {
    "default_popup": "popup.html",
    "default_icon": {
      "48": "images/icon-48.png",
      "96": "images/icon-96.png"
    }
  },
  "content_scripts": [
    {
      "matches": ["<all_urls>"],
      "js": ["content-script.js"],
      "run_at": "document_idle"
    }
  ],
  "permissions": ["storage", "webRequest"],
  "host_permissions": ["<all_urls>"]
}
```

- [ ] **Step 5: Lint and typecheck the new TS file**

Run: `cd JS/safari-extension && npm run lint && npm run typecheck`
Expected: both exit 0.

- [ ] **Step 6: Commit**

```bash
git add JS/safari-extension/src/popup.ts Resources/SafariExtension/popup.html \
  Resources/SafariExtension/popup.css Resources/SafariExtension/manifest.json \
  Resources/SafariExtension/images
git commit -m "feat(#1098): add popup entry point, manifest, and extension icons"
```

---

### Task 9: Build script wiring

**Files:**
- Create: `scripts/build-safari-extension.sh`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: `JS/safari-extension`'s `npm run build` (Task 1's `package.json` scripts, which bundle Task 4/5/8's `content-script.ts`/`background.ts`/`popup.ts`).
- Produces: `Resources/SafariExtension/{content-script,background,popup}.js` (build output, gitignored) — consumed by Task 10's Xcode target as bundle resources.

- [ ] **Step 1: Write the build script**

Create `scripts/build-safari-extension.sh` (mirrors `scripts/build-overlay.sh`):

```bash
#!/usr/bin/env bash
#
# Builds the Safari Web Extension's content script, background worker, and popup script from
# JS/safari-extension/ into Resources/SafariExtension/. Unlike Resources/edit-overlay/ (entirely
# generated), Resources/SafariExtension/ mixes tracked static files (manifest.json, popup.html,
# popup.css, images/) with these three generated .js files — only the generated files are
# gitignored (see .gitignore), so this script never needs to `mkdir -p` a destination that
# doesn't already exist in git.
#
# Best-effort like the other build scripts: if Node isn't available or the install fails, warn
# and exit 0 so the Xcode build keeps going.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
EXT_DIR="$REPO_ROOT/JS/safari-extension"
DEST_DIR="$REPO_ROOT/Resources/SafariExtension"

if [[ ! -d "$EXT_DIR" ]]; then
    echo "warning: $EXT_DIR missing — skipping Safari extension build." >&2
    exit 0
fi

NPM=""
if command -v npm >/dev/null 2>&1; then
    NPM="$(command -v npm)"
else
    echo "warning: no npm found on PATH. Skipping Safari extension build." >&2
    exit 0
fi

cd "$EXT_DIR"

if [[ ! -x "$EXT_DIR/node_modules/.bin/esbuild" ]]; then
    echo "==> Installing JS/safari-extension dependencies"
    if ! "$NPM" ci --prefer-offline --no-audit --no-fund 2>&1; then
        echo "warning: npm ci failed — skipping Safari extension build." >&2
        exit 0
    fi
fi

echo "==> Type-checking JS/safari-extension"
"$NPM" run typecheck

echo "==> Building Safari extension → ${DEST_DIR#"$REPO_ROOT"/}/{content-script,background,popup}.js"
"$NPM" run build

for name in content-script background popup; do
    bytes=$(wc -c < "$DEST_DIR/$name.js" | tr -d '[:space:]')
    echo "  $name.js (${bytes} bytes)"
done
```

Run: `chmod +x scripts/build-safari-extension.sh`

- [ ] **Step 2: Ignore the generated bundles**

Modify `.gitignore` — add these three lines directly under the existing `Resources/wysiwyg-engine/` line (in the "Bundled resources populated at build time, not committed" block):

```
Resources/SafariExtension/content-script.js
Resources/SafariExtension/background.js
Resources/SafariExtension/popup.js
```

- [ ] **Step 3: Run the build script and verify output**

Run: `scripts/build-safari-extension.sh`
Expected: installs `JS/safari-extension` deps if needed, type-checks clean, and reports three non-zero byte counts for `content-script.js`, `background.js`, `popup.js` under `Resources/SafariExtension/`.

- [ ] **Step 4: Confirm the generated files are actually ignored**

Run: `git status --short Resources/SafariExtension/`
Expected: shows only newly-tracked static files from Task 8 as staged/untracked-if-not-yet-added — `content-script.js`, `background.js`, and `popup.js` must NOT appear (confirming `.gitignore` is working). If they appear, the `.gitignore` entries from Step 2 are wrong — fix them before continuing.

- [ ] **Step 5: Commit**

```bash
git add scripts/build-safari-extension.sh .gitignore
git commit -m "feat(#1098): add Safari extension JS build script"
```

---

### Task 10: Xcode target — embed the extension in Anglesite.app

**Files:**
- Create: `Sources/AnglesiteSafariExtension/SafariWebExtensionHandler.swift`
- Create: `Resources/SafariExtension/Info.plist`
- Create: `Resources/SafariExtension/AnglesiteSafariExtension.entitlements`
- Modify: `project.yml`
- Modify: `CLAUDE.md` (and its mirror `AGENTS.md`, if the two are kept in sync per the repo's existing convention — check whether `AGENTS.md` is a symlink to `CLAUDE.md` or a separate file before editing both)

**Interfaces:**
- Consumes: the built `Resources/SafariExtension/*.js` (Task 9) and static web resources (Task 8) as bundle resources; no Swift-level interfaces.
- Produces: the `AnglesiteSafariExtension.appex` embedded in `Anglesite.app`.

- [ ] **Step 1: Write the native extension handler**

Create `Sources/AnglesiteSafariExtension/SafariWebExtensionHandler.swift`:

```swift
import SafariServices
import os.log

/// Required principal class for a Manifest V3 Safari Web Extension (`NSExtensionPrincipalClass`
/// in Info.plist). This extension does no native messaging in v1 — detection, badge state, and
/// the popup UI are entirely the web extension's own JS (`Resources/SafariExtension/`) — so this
/// handler only needs to satisfy Safari's requirement that an app-extension bundle has a
/// principal class conforming to `NSExtensionRequestHandling`. It logs and echoes any message
/// it's asked to handle rather than silently dropping it (see `AGENTS.md` ▸ "Logs are sacred").
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private let log = OSLog(subsystem: "io.dwk.anglesite.SafariExtension", category: "native-messaging")

    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey]

        os_log(.info, log: log, "Received unexpected native message: %{public}@", String(describing: message))

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: ["received": true]]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}
```

- [ ] **Step 2: Write Info.plist**

Create `Resources/SafariExtension/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>Anglesite IndieWeb</string>
	<key>CFBundleExecutable</key>
	<string>$(EXECUTABLE_NAME)</string>
	<key>CFBundleIdentifier</key>
	<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$(PRODUCT_NAME)</string>
	<key>CFBundlePackageType</key>
	<string>XPC!</string>
	<key>CFBundleShortVersionString</key>
	<string>$(MARKETING_VERSION)</string>
	<key>CFBundleVersion</key>
	<string>$(CURRENT_PROJECT_VERSION)</string>
	<key>NSExtension</key>
	<dict>
		<key>NSExtensionPointIdentifier</key>
		<string>com.apple.Safari.web-extension</string>
		<key>NSExtensionPrincipalClass</key>
		<string>$(PRODUCT_MODULE_NAME).SafariWebExtensionHandler</string>
	</dict>
</dict>
</plist>
```

- [ ] **Step 3: Write entitlements**

Create `Resources/SafariExtension/AnglesiteSafariExtension.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
</dict>
</plist>
```

No network/file/app-group entitlements: the extension is standalone (per the design spec's "fully standalone" decision) and makes no native-side network or file-system calls — its detection and any web requests it inspects run entirely inside Safari's own web-extension sandbox, governed by `manifest.json`'s `host_permissions`, not by this file.

- [ ] **Step 4: Add the Xcode target to `project.yml`**

Modify `project.yml`: add a new top-level target block, placed directly after the existing `AnglesiteShareExtension:` block (before the `AnglesiteRemote:` block's comment) — follow that target's structure exactly, adjusted for this extension:

```yaml
  # IndieWeb Safari Extension (#1098): standalone Manifest V3 Safari Web Extension embedded in
  # Anglesite.app. Detects h-cards, feeds, webmentions, ActivityPub, and general microformats2 on
  # the page the user is viewing in Safari. No native messaging, no dependency on a running
  # Anglesite.app — all detection/UI logic is the JS/safari-extension bundle built into
  # Resources/SafariExtension/ by scripts/build-safari-extension.sh. Spec:
  # docs/superpowers/specs/2026-08-17-safari-indieweb-extension-design.md.
  AnglesiteSafariExtension:
    type: app-extension
    platform: macOS
    sources:
      - path: Sources/AnglesiteSafariExtension
      - path: Resources/SafariExtension/manifest.json
      - path: Resources/SafariExtension/popup.html
      - path: Resources/SafariExtension/popup.css
      - path: Resources/SafariExtension/content-script.js
        optional: true
      - path: Resources/SafariExtension/background.js
        optional: true
      - path: Resources/SafariExtension/popup.js
        optional: true
      - path: Resources/SafariExtension/images
        type: folder
        buildPhase: resources
    # See the Anglesite target's matching comment on configFiles above. Extensions embedded in
    # the host app need matching signing style/team for automatic signing to resolve.
    configFiles:
      Debug: xcconfig/Signing-Debug.xcconfig
      Release: xcconfig/Signing-Release.xcconfig
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: io.dwk.anglesite.SafariExtension
        PRODUCT_NAME: AnglesiteSafariExtension
        INFOPLIST_FILE: Resources/SafariExtension/Info.plist
        GENERATE_INFOPLIST_FILE: NO
        CODE_SIGN_ENTITLEMENTS: Resources/SafariExtension/AnglesiteSafariExtension.entitlements
        ENABLE_HARDENED_RUNTIME: YES
        MACOSX_DEPLOYMENT_TARGET: "27.0"
        SWIFT_VERSION: "5.10"
        CURRENT_PROJECT_VERSION: 1
        MARKETING_VERSION: "0.1.0"
        SKIP_INSTALL: YES
        SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) ANGLESITE_MAS"
    preBuildScripts:
      # Same backstop as the Anglesite target's matching phase (#123) — a stale gitignored
      # xcodeproj must regenerate before this target's own build can trust its file list.
      - name: Regenerate Xcode project
        script: |
          if command -v xcodegen >/dev/null 2>&1; then
            xcodegen generate --quiet
          else
            echo "warning: xcodegen not found on PATH — skipping project regeneration (brew install xcodegen)." >&2
          fi
        basedOnDependencyAnalysis: false
      - name: Build Safari extension
        script: "\"${PROJECT_DIR}/scripts/build-safari-extension.sh\""
        basedOnDependencyAnalysis: false
```

Then, in the existing `Anglesite:` target's `dependencies:` list, add this entry alongside the other `embed: true` extension targets (next to `AnglesiteShareExtension`):

```yaml
      - target: AnglesiteSafariExtension
        embed: true
```

- [ ] **Step 5: Regenerate the Xcode project**

Run: `xcodegen generate`
Expected: exits 0, `Anglesite.xcodeproj` is regenerated (it's gitignored, so this is expected to run before every build per `AGENTS.md` ▸ "Worktrees").

- [ ] **Step 6: Build**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: succeeds. This is the first build after adding the target, so per the caveat in the "Regenerate Xcode project" comment (also documented for the `Anglesite`/edit-overlay case, #123), the very first build may not embed `content-script.js`/`background.js`/`popup.js` if they weren't already present as file references when this build's Xcode invocation resolved its file list. If the build succeeds but you want to confirm the extension bundle actually contains the three JS files and manifest.json, run:

```bash
find ~/Library/Developer/Xcode/DerivedData/Anglesite-*/Build/Products/Debug/Anglesite.app/Contents/PlugIns/AnglesiteSafariExtension.appex/Contents/Resources -maxdepth 1
```

Expected: lists `manifest.json`, `popup.html`, `popup.css`, `content-script.js`, `background.js`, `popup.js`, `images/`. If any `.js` file is missing, re-run `xcodegen generate` and rebuild — the second build picks them up (same known limitation as the edit-overlay pattern, not a new bug).

- [ ] **Step 7: Update CLAUDE.md's target documentation**

Check whether `AGENTS.md` is a symlink to `CLAUDE.md` in this worktree:

```bash
ls -la AGENTS.md
```

If it's a symlink (the file's own header says "mirrored as CLAUDE.md" for Claude Code users, implying they're kept in sync — confirm which one is the real file and which is the symlink/copy before editing), edit only the real file. Add one sentence to `CLAUDE.md`'s "Build target" section, after the `AnglesiteRemote` paragraph, describing the new target:

```markdown
A third embedded target, `AnglesiteSafariExtension` (#1098), is a standalone Manifest V3 Safari
Web Extension that detects IndieWeb features (h-cards, feeds, webmentions, ActivityPub,
microformats2) on the page open in Safari. It does not talk to `Anglesite.app` or link
`AnglesiteCore` — all logic lives in `JS/safari-extension/`, built by
`scripts/build-safari-extension.sh` into `Resources/SafariExtension/`.
```

- [ ] **Step 8: Commit**

```bash
git add Sources/AnglesiteSafariExtension Resources/SafariExtension/Info.plist \
  Resources/SafariExtension/AnglesiteSafariExtension.entitlements project.yml CLAUDE.md
git commit -m "feat(#1098): embed AnglesiteSafariExtension target in Anglesite.app"
```

---

### Task 11: CI coverage

**Files:**
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `JS/safari-extension`'s `lint`/`typecheck`/`test` scripts (Task 1).
- Produces: a required `safari-extension` CI job.

- [ ] **Step 1: Add path-change detection**

Modify `.github/workflows/ci.yml`: in the `changes` job's script (the block starting `swift=false; js=false; wysiwyg=false; ...`), add a new flag next to the existing `wysiwyg` one:

```
swift=false; js=false; wysiwyg=false; safariExt=false; template=false; helpBook=false; workers=false
matches 'Package.swift' 'Package.resolved' 'project.yml' 'Sources/**' 'Tests/**' 'Resources/Template/**' 'Resources/Attributions/**' 'scripts/**' 'packaging/flatpak/**' '.github/workflows/ci.yml' && swift=true
matches 'JS/edit-overlay/**' 'scripts/node-version.txt' '.github/workflows/ci.yml' && js=true
matches 'JS/wysiwyg-engine/**' 'scripts/node-version.txt' '.github/workflows/ci.yml' && wysiwyg=true
matches 'JS/safari-extension/**' 'scripts/node-version.txt' '.github/workflows/ci.yml' && safariExt=true
matches 'Resources/Template/**' 'scripts/node-version.txt' 'scripts/generate-npm-attributions.mjs' 'scripts/attributions-overrides.json' '.github/workflows/ci.yml' && template=true
matches 'Resources/Anglesite.help/**' 'scripts/check-help-links.sh' '.github/workflows/ci.yml' && helpBook=true
matches 'Workers/**' 'scripts/node-version.txt' '.github/workflows/ci.yml' && workers=true

echo "swift=$swift" >> "$GITHUB_OUTPUT"
echo "js=$js" >> "$GITHUB_OUTPUT"
echo "wysiwyg=$wysiwyg" >> "$GITHUB_OUTPUT"
echo "safariExt=$safariExt" >> "$GITHUB_OUTPUT"
echo "template=$template" >> "$GITHUB_OUTPUT"
echo "helpBook=$helpBook" >> "$GITHUB_OUTPUT"
echo "workers=$workers" >> "$GITHUB_OUTPUT"
```

Note: `Sources/**` and `project.yml` are already in the `swift` glob, so a change to `Sources/AnglesiteSafariExtension/` or the new `project.yml` target already triggers the Swift/`build-test` lane correctly — this step only adds the dedicated JS lane for `JS/safari-extension/`.

- [ ] **Step 2: Add the `safari-extension` job**

Modify `.github/workflows/ci.yml`: add a new job directly after the `edit-overlay:` job block (before `wysiwyg-engine:`), copying its structure:

```yaml
  safari-extension:
    name: JS safari-extension (lint/typecheck/test)
    needs: changes
    if: needs.changes.outputs.safariExt == 'true'
    runs-on: ubuntu-latest
    timeout-minutes: 5
    defaults:
      run:
        working-directory: JS/safari-extension
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - uses: actions/setup-node@820762786026740c76f36085b0efc47a31fe5020 # v7.0.0
        with:
          node-version-file: scripts/node-version.txt
          cache: npm
          cache-dependency-path: JS/safari-extension/package-lock.json
      - run: npm ci --no-audit --no-fund
      - run: npm run lint
      - run: npm run typecheck
      - run: npm test
```

Use the exact same pinned `actions/checkout` and `actions/setup-node` SHA/version comments already used by the `edit-overlay` job — do not bump them independently.

- [ ] **Step 3: Add the job to the required-checks gate**

Modify `.github/workflows/ci.yml`: in the final `ci:` job's `needs:` list, add `safari-extension` next to `wysiwyg-engine`:

```yaml
    needs:
      - changes
      - edit-overlay
      - wysiwyg-engine
      - safari-extension
      - help-book-links
      - workers-tests
      - linux-build-test
      - linux-flatpak-build
      - build-test
      - timing-sensitive-tests
      - ios-build
      - concurrency-tsan
      - docs-docc
      - xcodeproj-sync
      - localization-catalog
      - appintents-schema
      - reuse-lint
```

- [ ] **Step 4: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))"`
Expected: no output (valid YAML). If `pyyaml` isn't available, use `ruby -ryaml -e "YAML.load_file('.github/workflows/ci.yml')"` instead — either interpreter is fine, this step just needs a YAML parser that will raise on a syntax error.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci(#1098): add JS safari-extension lint/typecheck/test lane"
```

---

## Manual verification (not automatable from this environment)

After all tasks land, this still needs a real-Safari pass before the feature can be considered done — call this out explicitly rather than claiming it as verified:

1. Open `Anglesite.app` (built via Task 10), open Safari ▸ Settings ▸ Extensions, enable "Anglesite IndieWeb", grant it permission ("Always Allow on Every Website" or per-site).
2. Visit a page with a known h-card (e.g., an IndieWeb homepage), confirm the toolbar badge shows a count and the popup renders the name + a working "Copy vCard" button (paste somewhere and confirm valid vCard text).
3. Visit a page with an RSS/Atom `<link>`, confirm the popup lists it and "Open feed" opens the feed URL in a new tab.
4. Visit a page that sends a `Link: <...>; rel="webmention"` HTTP header (not just a `<link>` tag), confirm the badge/popup still pick it up (this path can't be exercised by DOM-only test fixtures).
5. Visit a plain page with none of the above, confirm the popup shows the empty state and the badge is blank.
6. Confirm the extension continues to work with `Anglesite.app` fully quit (standalone claim).

## Follow-up issues (explicitly out of scope here)

- Webmention send / ActivityPub follow from the extension (needs an identity/account decision).
- Any native messaging integration with `Anglesite.app`.
