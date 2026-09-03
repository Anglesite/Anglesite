# ESI Astro Components + Local Fallback Preview — Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship three Astro template components (`EsiInclude`, `EsiComment`, `EsiRemove`) that let a site owner author Edge Side Includes markup, plus a global Live/Unprocessed preview toggle in the app's Debug Pane so the fallback state can be previewed on demand.

**Architecture:** Three `.astro` components under `Resources/Template/src/components/esi/` build their literal `esi:*` markup via `<Fragment set:html={...}>` from small, unit-tested pure TS helpers (`esi-markup.ts`), sidestepping any risk in Astro's compiler handling colon-containing tag names. `EsiInclude` also carries a dev-only client-side fetch shim (`esi-dev-shim.ts`) that approximates edge resolution in local preview. A new global `AppSettings` key drives a Live/Unprocessed picker in the existing Debug Pane; `PreviewNavigation` (already `AnglesiteCore`-pure and unit-tested) grows one function to translate that setting into a query parameter on the preview URL, which the dev shim reads to skip its fetch when in Unprocessed mode.

**Tech Stack:** Astro 6 (`.astro` components, template-level conditionals), plain TypeScript (`node:test` + `tsx`, this repo's existing template-test convention — no vitest/jsdom in this part of the codebase), Swift 6 / SwiftUI (`AnglesiteCore` pure logic + `AppSettings`/`UserDefaults`, `AnglesiteApp` SwiftUI view), Swift Testing for the Swift-side test.

## Global Constraints

- Every new `SiteSettings`-style field must stay optional — **not applicable here**: this plan does not touch `SiteConfigStore`/`SiteSettings` (see spec §4a's correction — the toggle is global via `AppSettings`, not per-site).
- Template `.test.ts` files run via `cd Resources/Template && npx tsx --test <file>.test.ts` — this repo's established convention (no vitest/jsdom for template code); match it exactly, do not introduce a new template test runner.
- New `AnglesiteCore` logic must stay platform-pure and unit-tested there; `AnglesiteApp`-target SwiftUI view code has no CI coverage in this repo today (per CLAUDE.md) — don't invent a test harness for `DebugPaneView` that doesn't already exist.
- `esi:include`/`esi:comment`/`esi:remove` markup must be emitted via `set:html` with hand-escaped attribute values, never via literal `<esi:include src={src} />` template syntax (spec §3 — unverified compiler round-trip risk for colon tag names).
- No Component Editor Swift code in this plan — `EsiRemove`'s `<slot />` and the other two components' props are picked up for free once #493/#494 ship; the refinement comments those two issues needed were already posted during brainstorming (not implementation work).
- **Task ordering note:** `esi-dev-shim.ts` (Task 2) must exist before the three components (Task 3), because `EsiInclude.astro` imports from it — and the build-fixture spike (Task 4) runs a real `astro build`, which would fail on a missing module if the shim didn't exist yet. Do not reorder Tasks 2–4.

---

## Task 1: `esi-markup.ts` — pure ESI tag-string builders

**Files:**
- Create: `Resources/Template/src/components/esi/esi-markup.ts`
- Create: `Resources/Template/src/components/esi/esi-markup.test.ts`

**Interfaces:**
- Produces: `escapeAttribute(value: string): string`, `buildEsiIncludeTag(props: { src: string; alt?: string; onerror?: "continue" }): string`, `buildEsiCommentTag(text: string): string` — consumed by Task 3's `.astro` components.

- [ ] **Step 1: Write the failing tests**

```ts
// Resources/Template/src/components/esi/esi-markup.test.ts
import test from "node:test";
import assert from "node:assert/strict";
import { escapeAttribute, buildEsiIncludeTag, buildEsiCommentTag } from "./esi-markup";

test("escapeAttribute escapes & and \"", () => {
  assert.equal(escapeAttribute(`a & b "c"`), `a &amp; b &quot;c&quot;`);
});

test("escapeAttribute leaves plain text untouched", () => {
  assert.equal(escapeAttribute("/fragments/count"), "/fragments/count");
});

test("buildEsiIncludeTag: src only", () => {
  assert.equal(
    buildEsiIncludeTag({ src: "/fragments/count" }),
    `<esi:include src="/fragments/count"></esi:include>`
  );
});

test("buildEsiIncludeTag: src + alt + onerror", () => {
  assert.equal(
    buildEsiIncludeTag({ src: "/a", alt: "/b", onerror: "continue" }),
    `<esi:include src="/a" alt="/b" onerror="continue"></esi:include>`
  );
});

test("buildEsiIncludeTag: escapes quotes and ampersands in attribute values", () => {
  assert.equal(
    buildEsiIncludeTag({ src: '/a?x="y"&z=1' }),
    `<esi:include src="/a?x=&quot;y&quot;&amp;z=1"></esi:include>`
  );
});

test("buildEsiCommentTag", () => {
  assert.equal(
    buildEsiCommentTag(`hello & "world"`),
    `<esi:comment text="hello &amp; &quot;world&quot;"/>`
  );
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Resources/Template && npx tsx --test src/components/esi/esi-markup.test.ts`
Expected: FAIL — `Cannot find module './esi-markup'`.

- [ ] **Step 3: Write the minimal implementation**

```ts
// Resources/Template/src/components/esi/esi-markup.ts

/** Escapes the two characters that matter inside a double-quoted HTML attribute value. */
export function escapeAttribute(value: string): string {
  return value.replace(/&/g, "&amp;").replace(/"/g, "&quot;");
}

export interface EsiIncludeProps {
  src: string;
  alt?: string;
  onerror?: "continue";
}

/** Builds the literal `<esi:include ...></esi:include>` tag `@dwk/esi`'s tokenizer expects. */
export function buildEsiIncludeTag(props: EsiIncludeProps): string {
  let tag = `<esi:include src="${escapeAttribute(props.src)}"`;
  if (props.alt) tag += ` alt="${escapeAttribute(props.alt)}"`;
  if (props.onerror) tag += ` onerror="${escapeAttribute(props.onerror)}"`;
  tag += "></esi:include>";
  return tag;
}

/** Builds the literal `<esi:comment text="…"/>` tag. */
export function buildEsiCommentTag(text: string): string {
  return `<esi:comment text="${escapeAttribute(text)}"/>`;
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Resources/Template && npx tsx --test src/components/esi/esi-markup.test.ts`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Resources/Template/src/components/esi/esi-markup.ts Resources/Template/src/components/esi/esi-markup.test.ts
git commit -m "feat(template): add ESI tag-string builders"
```

---

## Task 2: `esi-dev-shim.ts` — dev-preview fetch logic

Written before the components (Task 3) because `EsiInclude.astro` imports from this module — see the Global Constraints ordering note.

**Files:**
- Create: `Resources/Template/src/components/esi/esi-dev-shim.ts`
- Create: `Resources/Template/src/components/esi/esi-dev-shim.test.ts`

**Interfaces:**
- Produces: `resolveEsiFragments(doc: EsiFragmentDocument, fetchImpl: (url: string) => Promise<Response>): Promise<void>`, `esiPreviewIsUnprocessed(search: string): boolean` — both imported by `EsiInclude.astro` (Task 3).

- [ ] **Step 1: Write the failing tests**

```ts
// Resources/Template/src/components/esi/esi-dev-shim.test.ts
import test from "node:test";
import assert from "node:assert/strict";
import { resolveEsiFragments, esiPreviewIsUnprocessed, type EsiFragmentElement, type EsiFragmentDocument } from "./esi-dev-shim";

function makeElement(attrs: Record<string, string>): EsiFragmentElement & { innerHTML: string } {
  const attributes = { ...attrs };
  return {
    getAttribute: (name) => attributes[name] ?? null,
    setAttribute: (name, value) => { attributes[name] = value; },
    hasAttribute: (name) => name in attributes,
    innerHTML: "",
  };
}

test("resolveEsiFragments: fetches src and fills innerHTML on success", async () => {
  const el = makeElement({ src: "/fragments/count" });
  const doc: EsiFragmentDocument = { querySelectorAll: () => [el] };
  await resolveEsiFragments(doc, async () => new Response("42", { status: 200 }));
  assert.equal(el.innerHTML, "42");
  assert.equal(el.hasAttribute("data-esi-dev-resolved"), true);
});

test("resolveEsiFragments: falls back to alt once when src fails and no onerror is set", async () => {
  const el = makeElement({ src: "/fragments/count", alt: "/fragments/fallback" });
  const doc: EsiFragmentDocument = { querySelectorAll: () => [el] };
  await resolveEsiFragments(doc, async (url) =>
    url === "/fragments/count" ? new Response("", { status: 500 }) : new Response("fallback-text", { status: 200 })
  );
  assert.equal(el.innerHTML, "fallback-text");
});

test("resolveEsiFragments: onerror=continue drops silently, never tries alt", async () => {
  const el = makeElement({ src: "/fragments/count", alt: "/fragments/fallback", onerror: "continue" });
  const doc: EsiFragmentDocument = { querySelectorAll: () => [el] };
  let altCalled = false;
  await resolveEsiFragments(doc, async (url) => {
    if (url === "/fragments/fallback") altCalled = true;
    return new Response("", { status: 500 });
  });
  assert.equal(el.innerHTML, "");
  assert.equal(altCalled, false);
});

test("resolveEsiFragments: no alt and src fails leaves the element empty", async () => {
  const el = makeElement({ src: "/fragments/count" });
  const doc: EsiFragmentDocument = { querySelectorAll: () => [el] };
  await resolveEsiFragments(doc, async () => new Response("", { status: 500 }));
  assert.equal(el.innerHTML, "");
  assert.equal(el.hasAttribute("data-esi-dev-resolved"), true);
});

test("resolveEsiFragments: skips elements already marked resolved", async () => {
  const el = makeElement({ src: "/fragments/count", "data-esi-dev-resolved": "true" });
  el.innerHTML = "cached";
  const doc: EsiFragmentDocument = { querySelectorAll: () => [el] };
  let called = false;
  await resolveEsiFragments(doc, async () => {
    called = true;
    return new Response("42");
  });
  assert.equal(called, false);
  assert.equal(el.innerHTML, "cached");
});

test("esiPreviewIsUnprocessed: true only for ?esiPreview=unprocessed", () => {
  assert.equal(esiPreviewIsUnprocessed("?esiPreview=unprocessed"), true);
  assert.equal(esiPreviewIsUnprocessed(""), false);
  assert.equal(esiPreviewIsUnprocessed("?esiPreview=live"), false);
  assert.equal(esiPreviewIsUnprocessed("?other=1&esiPreview=unprocessed"), true);
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Resources/Template && npx tsx --test src/components/esi/esi-dev-shim.test.ts`
Expected: FAIL — `Cannot find module './esi-dev-shim'`.

- [ ] **Step 3: Write the minimal implementation**

```ts
// Resources/Template/src/components/esi/esi-dev-shim.ts

/** Structural subset of `Element` this module needs — lets tests pass a hand-rolled fake
 *  instead of pulling in a DOM-emulation dependency this template toolchain doesn't otherwise use. */
export interface EsiFragmentElement {
  getAttribute(name: string): string | null;
  setAttribute(name: string, value: string): void;
  hasAttribute(name: string): boolean;
  innerHTML: string;
}

/** Structural subset of `Document` this module needs. */
export interface EsiFragmentDocument {
  querySelectorAll(selector: string): ArrayLike<EsiFragmentElement>;
}

const RESOLVED_ATTR = "data-esi-dev-resolved";

/**
 * Dev-preview approximation of `@dwk/esi`'s fragment resolution: fetches each unresolved
 * `<esi:include>` element's `src`, applying the same onerror/alt rules the real processor uses
 * (`docs/superpowers/specs/2026-07-13-esi-astro-component-design.md` §4), so local preview shows
 * something close to what production will. Dev-only — never bundled into a production build
 * (see `EsiInclude.astro`'s `{import.meta.env.DEV && (...)}` guard).
 */
export async function resolveEsiFragments(
  doc: EsiFragmentDocument,
  fetchImpl: (url: string) => Promise<Response>
): Promise<void> {
  const elements = Array.from(doc.querySelectorAll("esi\\:include"));
  await Promise.all(
    elements.map(async (el) => {
      if (el.hasAttribute(RESOLVED_ATTR)) return;
      const src = el.getAttribute("src");
      if (!src) {
        el.setAttribute(RESOLVED_ATTR, "true");
        return;
      }
      const onerror = el.getAttribute("onerror");
      const alt = el.getAttribute("alt");

      let body = await fetchFragmentBody(src, fetchImpl);
      if (body === null && onerror !== "continue" && alt) {
        body = await fetchFragmentBody(alt, fetchImpl);
      }
      if (body !== null) el.innerHTML = body;
      el.setAttribute(RESOLVED_ATTR, "true");
    })
  );
}

async function fetchFragmentBody(
  url: string,
  fetchImpl: (url: string) => Promise<Response>
): Promise<string | null> {
  try {
    const res = await fetchImpl(url);
    if (!res.ok) return null;
    return await res.text();
  } catch {
    return null;
  }
}

/** Reads the query-parameter toggle the app's Debug Pane Server section appends to the preview
 *  URL when "Unprocessed" mode is selected (spec §4a). */
export function esiPreviewIsUnprocessed(search: string): boolean {
  return new URLSearchParams(search).get("esiPreview") === "unprocessed";
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Resources/Template && npx tsx --test src/components/esi/esi-dev-shim.test.ts`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Resources/Template/src/components/esi/esi-dev-shim.ts Resources/Template/src/components/esi/esi-dev-shim.test.ts
git commit -m "feat(template): add EsiInclude dev-preview fetch shim"
```

---

## Task 3: The three ESI components

**Files:**
- Create: `Resources/Template/src/components/esi/EsiInclude.astro`
- Create: `Resources/Template/src/components/esi/EsiComment.astro`
- Create: `Resources/Template/src/components/esi/EsiRemove.astro`

**Interfaces:**
- Consumes: `buildEsiIncludeTag`, `buildEsiCommentTag` (Task 1); `resolveEsiFragments`, `esiPreviewIsUnprocessed` (Task 2).
- Produces: three importable Astro components, exercised by Task 4's build-fixture spike.

- [ ] **Step 1: Write `EsiComment.astro`** (simplest — no children, no dev shim)

```astro
---
import { buildEsiCommentTag } from "./esi-markup";

export interface Props {
  /** Authoring note dropped by the `@dwk/esi` processor — never reaches a client, in dev or prod. */
  text: string;
}

const { text } = Astro.props;
const tag = buildEsiCommentTag(text);
---
<Fragment set:html={tag} />
```

- [ ] **Step 2: Write `EsiRemove.astro`** (children via `<slot />`, no props)

```astro
---
---
{/* Fallback markup shown only when nothing ESI-aware processes this page — see EsiInclude's
    doc comment for the idiomatic EsiInclude/EsiRemove sibling pairing. */}
<Fragment set:html="<esi:remove>" />
<slot />
<Fragment set:html="</esi:remove>" />
```

- [ ] **Step 3: Write `EsiInclude.astro`**

```astro
---
import { buildEsiIncludeTag } from "./esi-markup";

export interface Props {
  /**
   * URL to fetch and splice in place of this tag at the edge. Routed through `@dwk/esi`'s
   * safeFetch-backed resolver in production, so an attacker- or user-supplied URL is safe here.
   * In local dev preview, fetched client-side instead — a cross-origin `src` needs that origin's
   * own CORS headers to resolve in preview (production has no such restriction). Pair with
   * `EsiRemove` for fallback markup shown when nothing ESI-aware processes this page:
   *
   * ```astro
   * <EsiInclude src="/fragments/count" onerror="continue" />
   * <EsiRemove><span class="count-fallback">—</span></EsiRemove>
   * ```
   */
  src: string;
  /** Fallback URL retried once if `src` fails (only when `onerror` is unset). */
  alt?: string;
  /** `"continue"`: drop this fragment silently on failure instead of retrying `alt`. */
  onerror?: "continue";
}

const { src, alt, onerror } = Astro.props;
const tag = buildEsiIncludeTag({ src, alt, onerror });
---
<Fragment set:html={tag} />
{import.meta.env.DEV && (
  <script>
    import { resolveEsiFragments, esiPreviewIsUnprocessed } from "./esi-dev-shim";
    if (!esiPreviewIsUnprocessed(location.search)) {
      resolveEsiFragments(document, (url) => fetch(url));
    }
  </script>
)}
```

- [ ] **Step 4: Commit**

```bash
git add Resources/Template/src/components/esi/EsiInclude.astro Resources/Template/src/components/esi/EsiComment.astro Resources/Template/src/components/esi/EsiRemove.astro
git commit -m "feat(template): add EsiInclude/EsiComment/EsiRemove components"
```

---

## Task 4: Astro build fixture test — the empirical spike

This is the empirical check the design doc calls out (spec §3/§7): confirm Astro's static build emits the `set:html`-injected literal `esi:*` markup byte-for-byte unchanged, and that the dev-only shim script is entirely absent from a production build's output. No existing test in this repo runs a real `astro build` (checked: no CI job or npm script does this for `Resources/Template`) — this is new, heavier ground, expected to take **30–90 seconds** (a real `npm install` + `astro build` in a temp directory) and needs network access for the install. It is not wired into CI (matching the existing, unwired state of every other `Resources/Template/**/*.test.ts` file in this repo) — run it manually during this task and again before opening the PR.

This is the gate before starting the Swift-side tasks (5–8): if the literal-markup assertions fail here, stop and reconsider the `set:html` approach (spec §3) rather than continuing to build on it.

**Files:**
- Create: `Resources/Template/src/components/esi/esi-components.build.test.ts`

**Interfaces:**
- Consumes: the three components (Task 3), which in turn pull in Task 1 and Task 2's modules.
- Produces: nothing consumed by later tasks — this is a standalone validation gate.

- [ ] **Step 1: Write the test**

```ts
// Resources/Template/src/components/esi/esi-components.build.test.ts
import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, cp, writeFile, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

// Resources/Template/ — three `..` up from src/components/esi/
const TEMPLATE_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..");

const EXCLUDED = /(^|\/)(node_modules|dist|\.astro|\.wrangler)(\/|$)/;

test("EsiInclude/EsiComment/EsiRemove survive an astro build byte-for-byte", async () => {
  const fixtureDir = await mkdtemp(join(tmpdir(), "anglesite-esi-fixture-"));
  try {
    await cp(TEMPLATE_ROOT, fixtureDir, {
      recursive: true,
      filter: (src) => !EXCLUDED.test(src.slice(TEMPLATE_ROOT.length)),
    });

    const fixturePage = `---
import EsiInclude from "../components/esi/EsiInclude.astro";
import EsiComment from "../components/esi/EsiComment.astro";
import EsiRemove from "../components/esi/EsiRemove.astro";
---
<EsiInclude src="/fragments/count" alt="/fragments/count-fallback" onerror="continue" />
<EsiComment text="build fixture" />
<EsiRemove><span class="fallback">—</span></EsiRemove>
`;
    await writeFile(join(fixtureDir, "src/pages/esi-build-fixture.astro"), fixturePage, "utf8");

    execFileSync("npm", ["install", "--no-audit", "--no-fund", "--prefer-offline"], {
      cwd: fixtureDir,
      stdio: "inherit",
    });
    execFileSync("npx", ["astro", "build"], { cwd: fixtureDir, stdio: "inherit" });

    const html = await readFile(join(fixtureDir, "dist/esi-build-fixture/index.html"), "utf8");

    assert.match(
      html,
      /<esi:include src="\/fragments\/count" alt="\/fragments\/count-fallback" onerror="continue"><\/esi:include>/
    );
    assert.match(html, /<esi:comment text="build fixture"\/>/);
    assert.match(html, /<esi:remove><span class="fallback">—<\/span><\/esi:remove>/);

    // The dev-only fetch shim must not ship to production at all — not just be inert.
    assert.ok(!html.includes("resolveEsiFragments"), "dev shim script leaked into production build");
  } finally {
    await rm(fixtureDir, { recursive: true, force: true });
  }
});
```

- [ ] **Step 2: Run the test**

Run: `cd Resources/Template && npx tsx --test src/components/esi/esi-components.build.test.ts`
Expected: PASS after ~30-90s. If it fails specifically on the `<esi:include>`/`<esi:comment>`/`<esi:remove>` assertions (not a build/install error), that's the spec §3 risk materializing — stop and re-open the design, do not patch around it here.

- [ ] **Step 3: Commit**

```bash
git add Resources/Template/src/components/esi/esi-components.build.test.ts
git commit -m "test(template): verify ESI markup survives a real astro build"
```

---

## Task 5: `AppSettings` — global ESI preview mode key

**Files:**
- Modify: `Sources/AnglesiteCore/AppSettings.swift`

**Interfaces:**
- Produces: `AppSettings.Key.esiPreviewUnprocessed: String`, `AppSettings.esiPreviewUnprocessed: Bool` (get/set) — consumed by Task 7 (`PreviewModel`) and Task 8 (`DebugPaneView`).

- [ ] **Step 1: Add the key**

In `Sources/AnglesiteCore/AppSettings.swift`, inside `public enum Key`, add directly below the existing `debugPaneEnabled` line (`Sources/AnglesiteCore/AppSettings.swift:21`):

```swift
        public static let esiPreviewUnprocessed = "anglesite.esiPreviewUnprocessed"
```

- [ ] **Step 2: Add the computed property**

Directly below the existing `debugPaneEnabled` computed property (`Sources/AnglesiteCore/AppSettings.swift:127-130`), add:

```swift
    /// Forces local preview to skip `EsiInclude`'s dev-only fetch shim, so `EsiRemove`'s fallback
    /// content can be previewed on demand instead of only by sabotaging the fragment URL
    /// (docs/superpowers/specs/2026-07-13-esi-astro-component-design.md §4a). Global rather than
    /// per-site: the Debug Pane this control lives in has no per-site scoping today. Defaults to
    /// `false` (live/resolved preview, today's existing behavior).
    public var esiPreviewUnprocessed: Bool {
        get { defaults.bool(forKey: Key.esiPreviewUnprocessed) }
        set { defaults.set(newValue, forKey: Key.esiPreviewUnprocessed) }
    }
```

- [ ] **Step 3: Build**

Run: `swift build --target AnglesiteCore`
Expected: builds cleanly.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteCore/AppSettings.swift
git commit -m "feat(core): add global ESI preview mode setting"
```

---

## Task 6: `PreviewNavigation.applyingEsiPreviewMode`

**Files:**
- Modify: `Sources/AnglesiteCore/PreviewNavigation.swift`
- Modify: `Tests/AnglesiteCoreTests/PreviewNavigationTests.swift`

**Interfaces:**
- Consumes: nothing new (pure `URL`/`Bool` in, `URL` out).
- Produces: `PreviewNavigation.applyingEsiPreviewMode(_ url: URL, unprocessed: Bool) -> URL` — consumed by Task 7 (`PreviewModel.displayURL`).

- [ ] **Step 1: Write the failing tests**

Append to `Tests/AnglesiteCoreTests/PreviewNavigationTests.swift`, inside `struct PreviewNavigationTests`:

```swift
    @Test("applyingEsiPreviewMode: unprocessed=false leaves the URL untouched")
    func esiPreviewModeOffIsNoop() {
        #expect(PreviewNavigation.applyingEsiPreviewMode(Self.base, unprocessed: false) == Self.base)
    }

    @Test("applyingEsiPreviewMode: unprocessed=true appends the query parameter")
    func esiPreviewModeOnAppendsQuery() {
        #expect(PreviewNavigation.applyingEsiPreviewMode(Self.base, unprocessed: true)
                == URL(string: "http://localhost:4321/?esiPreview=unprocessed")!)
    }

    @Test("applyingEsiPreviewMode: preserves an existing query item")
    func esiPreviewModePreservesExistingQuery() {
        let withQuery = URL(string: "http://localhost:4321/about?preview=1")!
        let result = PreviewNavigation.applyingEsiPreviewMode(withQuery, unprocessed: true)
        let comps = URLComponents(url: result, resolvingAgainstBaseURL: false)!
        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value) })
        #expect(items["preview"] == "1")
        #expect(items["esiPreview"] == "unprocessed")
    }

    @Test("applyingEsiPreviewMode: replaces a stale esiPreview value rather than duplicating it")
    func esiPreviewModeReplacesStaleValue() {
        let stale = URL(string: "http://localhost:4321/?esiPreview=live")!
        let result = PreviewNavigation.applyingEsiPreviewMode(stale, unprocessed: true)
        let comps = URLComponents(url: result, resolvingAgainstBaseURL: false)!
        let matches = (comps.queryItems ?? []).filter { $0.name == "esiPreview" }
        #expect(matches.count == 1)
        #expect(matches.first?.value == "unprocessed")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter PreviewNavigationTests`
Expected: FAIL to compile — `applyingEsiPreviewMode` doesn't exist yet.

- [ ] **Step 3: Write the minimal implementation**

In `Sources/AnglesiteCore/PreviewNavigation.swift`, inside `public enum PreviewNavigation`, add:

```swift
    /// Query-parameter key the app appends to force `EsiInclude`'s dev-preview shim into the
    /// "unprocessed" state (spec §4a) — must match `esi-dev-shim.ts`'s `esiPreviewIsUnprocessed`.
    public static let esiPreviewQueryKey = "esiPreview"
    public static let esiPreviewUnprocessedValue = "unprocessed"

    /// Appends (or replaces) the `esiPreview=unprocessed` query item on `url` when `unprocessed`
    /// is `true`; returns `url` unchanged when `false`. Existing query items are preserved.
    public static func applyingEsiPreviewMode(_ url: URL, unprocessed: Bool) -> URL {
        guard unprocessed else { return url }
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = (comps.queryItems ?? []).filter { $0.name != esiPreviewQueryKey }
        items.append(URLQueryItem(name: esiPreviewQueryKey, value: esiPreviewUnprocessedValue))
        comps.queryItems = items
        return comps.url ?? url
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter PreviewNavigationTests`
Expected: PASS (all `PreviewNavigationTests` cases, including the 4 new ones).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/PreviewNavigation.swift Tests/AnglesiteCoreTests/PreviewNavigationTests.swift
git commit -m "feat(core): add PreviewNavigation.applyingEsiPreviewMode"
```

---

## Task 7: Wire the setting into `PreviewModel.displayURL`

**Files:**
- Modify: `Sources/AnglesiteApp/PreviewModel.swift:308-314`

**Interfaces:**
- Consumes: `AppSettings.shared.esiPreviewUnprocessed` (Task 5), `PreviewNavigation.applyingEsiPreviewMode` (Task 6).
- Produces: no change to `displayURL`'s public signature (`URL?`) — callers (`PreviewView` via `SiteWindow`) need no changes.

- [ ] **Step 1: Edit `displayURL`**

Replace (`Sources/AnglesiteApp/PreviewModel.swift:308-314`):

```swift
    /// The URL the preview WKWebView should load: the active page route against the ready base
    /// URL, or the base URL itself when no route is active. `nil` until the runtime is `.ready`.
    var displayURL: URL? {
        guard let base = readyURL else { return nil }
        guard let route = activeRoute else { return base }
        return PreviewNavigation.targetURL(base: base, route: route)
    }
```

with:

```swift
    /// The URL the preview WKWebView should load: the active page route against the ready base
    /// URL, or the base URL itself when no route is active. `nil` until the runtime is `.ready`.
    /// Also carries the Debug Pane's global ESI preview mode (spec §4a) as a query parameter, so
    /// `EsiInclude`'s dev shim can read it.
    var displayURL: URL? {
        guard let base = readyURL else { return nil }
        let target = activeRoute.map { PreviewNavigation.targetURL(base: base, route: $0) } ?? base
        return PreviewNavigation.applyingEsiPreviewMode(target, unprocessed: AppSettings.shared.esiPreviewUnprocessed)
    }
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`

(Run `xcodegen generate` first if `Anglesite.xcodeproj` is missing or stale in this worktree.)

Expected: builds cleanly. (No dedicated test — `AnglesiteApp`-target code, consistent with this repo's existing lack of hosted-app-target CI coverage; the logic it delegates to is already tested in Task 6.)

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteApp/PreviewModel.swift
git commit -m "feat(app): apply ESI preview mode to the preview URL"
```

---

## Task 8: Debug Pane "Server" section

**Files:**
- Modify: `Sources/AnglesiteApp/DebugPaneView.swift`

**Interfaces:**
- Consumes: `AppSettings.Key.esiPreviewUnprocessed` (Task 5) via `@AppStorage`, matching the existing pattern in `Sources/AnglesiteApp/SettingsView.swift:63`.
- Produces: no new public API — purely additive UI.

- [ ] **Step 1: Add the `@AppStorage` property**

In `Sources/AnglesiteApp/DebugPaneView.swift`, add to the top of `struct DebugPaneView` (alongside the existing `@State` properties, `DebugPaneView.swift:12-19`):

```swift
    @AppStorage(AppSettings.Key.esiPreviewUnprocessed) private var esiPreviewUnprocessed: Bool = false
```

- [ ] **Step 2: Add the "Server" section to `body`**

Replace (`Sources/AnglesiteApp/DebugPaneView.swift:30-34`):

```swift
        VStack(alignment: .leading, spacing: 0) {
            toolbar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
```

with:

```swift
        VStack(alignment: .leading, spacing: 0) {
            toolbar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            serverSection
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
```

- [ ] **Step 3: Add the `serverSection` view**

Directly below the existing `toolbar` computed property (after `Sources/AnglesiteApp/DebugPaneView.swift:101`, i.e. right after the closing `}` of `private var toolbar: some View { ... }`), add:

```swift
    /// Production-behavior controls, distinct from the log-filtering toolbar above. ESI's
    /// Live/Unprocessed toggle is the first control here — see
    /// docs/superpowers/specs/2026-07-13-esi-astro-component-design.md §4a; broader controls
    /// (running a composed Worker locally, viewing worker/analytics logs) are tracked in #699.
    private var serverSection: some View {
        HStack(spacing: 12) {
            Text("Server").font(.headline)
            Picker("ESI Fragments", selection: $esiPreviewUnprocessed) {
                Text("Live").tag(false)
                Text("Unprocessed (show fallbacks)").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)
            Spacer()
        }
    }
```

- [ ] **Step 4: Manual verification**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`, then launch the app, open a site, open the Debug Pane (View menu → Show Debug Pane, ⌥⌘D), and confirm the new "Server" row appears between the existing toolbar and the log list, with a working Live/Unprocessed segmented control.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/DebugPaneView.swift
git commit -m "feat(app): add ESI Live/Unprocessed control to the Debug Pane"
```

---

## Task 9: Final verification pass

**Files:** none (verification only).

- [ ] **Step 1: Re-run every new/changed test**

```bash
cd Resources/Template && npx tsx --test src/components/esi/esi-markup.test.ts src/components/esi/esi-dev-shim.test.ts
cd Resources/Template && npx tsx --test src/components/esi/esi-components.build.test.ts
```

Then, from the repo root:

```bash
swift test --filter PreviewNavigationTests
```

Expected: all PASS.

- [ ] **Step 2: Full Swift test suite (per this repo's template-change guard)**

Run: `swift test --package-path .`
Expected: PASS — in particular, confirm `IntegrationTemplateAssetsTests` and `BlogTemplateAssetsTests` still pass (memory note: template changes can trip these guards; the new `src/components/esi/` files aren't in either test's on-demand/staged-asset lists, so no update to those tests is expected, but re-run to be sure).

- [ ] **Step 3: Manual GUI smoke**

Open the app against a real or fixture site (e.g. `~/Sites/anglesite-smoke` via `scripts/create-smoke-fixture.sh` if not already present), add `<EsiInclude src="/some/path" onerror="continue" /><EsiRemove><span>fallback</span></EsiRemove>` to a page, confirm: (a) in Live mode the dev shim attempts a fetch (visible in the Debug Pane's log or Safari Web Inspector's Network tab), (b) toggling the Debug Pane to Unprocessed and reloading the preview shows the `EsiRemove` fallback content instead.

- [ ] **Step 4: Confirm no unintended diffs**

```bash
git status --short
git log --oneline -10
```

Expected: only the commits from Tasks 1–8, clean working tree.
