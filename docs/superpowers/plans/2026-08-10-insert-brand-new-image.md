# Insert a brand-new image Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an owner add a brand-new image to a page that has none — via drag-and-drop and via `Insert ▸ Image` — by adding one new sidecar op (`insert-image`) and wiring both app-side entry points to it.

**Architecture:** A new MCP `apply_edit` op, `insert-image`, reuses the existing `processImageDrop` asset-write/optimize pipeline (already tolerant of "no prior image") and a new AST-based insertion resolver (reusing `component-structure-edit.mjs`'s span-resolution helpers) that appends a new `<img>` inside the page's content — descending one level into a sole wrapping Layout component when present, so the image lands inside the rendered page instead of floating outside it. Both app-side entry points (overlay drop, `Insert ▸ Image` menu) send the same op through the existing, already-live `MCPApplyEditRouter`.

**Tech Stack:** Node/Zod/`@astrojs/compiler` (sidecar), Swift/SwiftUI (macOS app), TypeScript (WKWebView overlay), Vitest, Swift Testing.

## Global Constraints

- Repo 1 — sidecar: `Anglesite/anglesite-skills`, checked out locally at `~/Developer/github.com/Anglesite/anglesite`. Ships and tags first (`CONTRIBUTING.md` ▸ "Paired PRs"); this repo has no `CONTRIBUTING.md` of its own yet (tracked separately, `project_sidecar_repo_missing_commit_pr_guidance` memory) — match this app repo's conventional-commit style anyway.
- Repo 2 — app: this repo (`Anglesite/Anglesite`), current worktree. Its PR cannot merge until the sidecar tag is vendored (`scripts/vendor-container-image.sh`).
- Conventional commits, subject ≤72 chars, reference `#1408` where relevant.
- Design source of truth: `docs/superpowers/specs/2026-08-10-insert-brand-new-image-design.md` (this repo). **Three refinements found while writing this plan, not yet reflected in that doc** — Task 0 amends it before any code changes:
  1. **No `selector`-anchored variant for v1.** Both entry points always insert at the page's content root — dropping anywhere on an empty page behaves the same as `Insert ▸ Image`. A selector-anchored "insert into a specific container" variant is deferred; matching an arbitrary DOM container against raw `.astro` source turned out to be the highest-risk, most speculative part of the original design, and the issue's own scope note treats it as an example, not a requirement.
  2. **Root-append means "inside the page's Layout wrapper," not literally the file's top-level nodes.** Every template page wraps its content in exactly one Layout component (e.g. `<BaseLayout>...</BaseLayout>` in `Resources/Template/src/pages/index.astro`) — appending at the literal AST fragment root would insert the `<img>` as a *sibling* of `<BaseLayout>`, outside the rendered page content entirely. The resolver descends one level into a sole wrapping component child before appending.
  3. **Pages only for v1, not component files.** `insert-image` addresses its target via a URL page path (`location.pathname` semantics, resolved through the existing `pathToAstroCandidates` helper), matching `replace-image-src`/`replace-text`'s existing shape — not a project-relative file path, which is what `src/components/*.astro` addressing would need. `Insert ▸ Image` is enabled whenever a page is loaded in the focused window's preview, not gated on `EditorKind`.

---

## Part A — Sidecar (`Anglesite/anglesite-skills`)

All commands in this part run with cwd `~/Developer/github.com/Anglesite/anglesite`.

### Task A0: Amend the design spec with the three refinements above

**Files:**
- Modify: `docs/superpowers/specs/2026-08-10-insert-brand-new-image-design.md` (this repo, not the sidecar)

- [ ] **Step 1: Add an amendment note**

Add a new `## 8. Amendments (found while writing the plan)` section at the end of the file containing the three numbered points from this plan's Global Constraints section above (copy verbatim), each with a one-line reason.

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/specs/2026-08-10-insert-brand-new-image-design.md
git commit -m "docs(#1408): amend insert-image spec with plan-time refinements"
```

### Task A1: Add `insert-image` to the closed op enum

**Files:**
- Modify: `server/apply-edit-schema.mjs:44` (`editOps` array), `server/apply-edit-schema.mjs:181` (`op` field description), `server/apply-edit-schema.mjs:187` (`value` field description)
- Test: `test/apply-edit-schema.test.js`

**Interfaces:**
- Produces: `"insert-image"` as a valid member of `editOps` / the `op` field's `z.enum(editOps)`.

- [ ] **Step 1: Write the failing test**

Open `test/apply-edit-schema.test.js`, find the existing test that asserts `editOps` contains `"replace-image-src"` (or the schema's `op` enum validates it) and add a sibling assertion:

```js
it("accepts insert-image as a valid op", () => {
  const result = applyEditInputSchema.safeParse({
    id: "e-1",
    path: "/",
    op: "insert-image",
    value: { filename: "photo.jpg", mimeType: "image/jpeg", dataURL: "data:image/jpeg;base64,AA==" },
  });
  expect(result.success).toBe(true);
});
```

(Match the actual exported schema name/import already used at the top of that test file — it may be `applyEditSchema` or similar; use whatever the file's existing tests import.)

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- apply-edit-schema.test.js` (from `~/Developer/github.com/Anglesite/anglesite`)
Expected: FAIL — `"insert-image"` not in the `op` enum, `safeParse` returns `success: false`.

- [ ] **Step 3: Add the op to the schema**

In `server/apply-edit-schema.mjs`, edit the `editOps` array (currently starts `"replace-text", "replace-attr", "replace-image-src", "edit-style", ...`):

```js
export const editOps = [
  "replace-text",
  "replace-attr",
  "replace-image-src",
  "insert-image",
  "edit-style",
  "apply-instruction",
  "set-style-property",
  "remove-style-property",
  "add-style-rule",
  "set-rule-selector",
  "insert-node",
  "move-node",
  "remove-node",
  "set-attr",
  "set-props-interface",
  "set-script-zone",
  "extract-component",
];
```

Update the `op` field's `.describe(...)` string (in the main schema object) to add `insert-image` right after the `replace-image-src` mention:

```
"Edit operation: replace-text (innerText), replace-attr (value is {name, value}), replace-image-src (value is {filename, mimeType, dataURL}), insert-image (value is {filename, mimeType, dataURL, alt?}; inserts a brand-new <img> into the page identified by path — no selector, no existing image required), edit-style (value is {property, value}; merges a rule into the owning component's scoped <style>), apply-instruction (reserved: sent only by the Anglesite-app Foundation Models chat path; always returns edit-failed/needs-agent — do not use from external callers), set-style-property/remove-style-property/add-style-rule/set-rule-selector (component-style ops), insert-node/move-node/remove-node/set-attr (component-structure ops), set-props-interface/set-script-zone (component-frontmatter ops), extract-component (nodeId + newName — writes a new src/components/<newName>.astro from the selected subtree, hoists obvious literal props, and replaces the selection in the source file with an instance + import — see componentEditSchema)",
```

Update the `value` field's `.describe(...)` string similarly, adding `, {filename, mimeType, dataURL, alt?} for insert-image` after the `replace-image-src` mention.

Do **not** add `"insert-image"` to `COMPONENT_STYLE_OPS`, `COMPONENT_STRUCTURE_OPS`, `COMPONENT_FRONTMATTER_OPS`, `COMPONENT_EXTRACT_OPS`, or the `COMPONENT_OPS` union — it addresses its target via `path` like `replace-image-src`, not via a `component` payload.

- [ ] **Step 4: Run test to verify it passes**

Run: `npm test -- apply-edit-schema.test.js`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add server/apply-edit-schema.mjs test/apply-edit-schema.test.js
git commit -m "feat: add insert-image to the apply_edit op enum"
```

### Task A2: Export the two helpers `insert-image`'s resolver needs

**Files:**
- Modify: `server/patcher.mjs:207` (`pathToAstroCandidates`), `server/component-structure-edit.mjs:541` (`resolveInsertionOffset`)
- Test: none new — existing `test/patcher.test.js` and `tests/component-structure-edit.test.ts` must stay green (adding `export` doesn't change behavior).

**Interfaces:**
- Produces: `export function pathToAstroCandidates(projectRoot, pagePath)` from `patcher.mjs`; `export function resolveInsertionOffset(byId, rootId, spans, source, parent, index, excludeChildId)` from `component-structure-edit.mjs`. Both keep their existing signatures — this task only adds the `export` keyword.

- [ ] **Step 1: Add `export` to both function declarations**

In `server/patcher.mjs`, change:
```js
function pathToAstroCandidates(projectRoot, pagePath) {
```
to:
```js
export function pathToAstroCandidates(projectRoot, pagePath) {
```

In `server/component-structure-edit.mjs`, change:
```js
function resolveInsertionOffset(byId, rootId, spans, source, parent, index, excludeChildId) {
```
to:
```js
export function resolveInsertionOffset(byId, rootId, spans, source, parent, index, excludeChildId) {
```

- [ ] **Step 2: Run the existing suites to confirm nothing broke**

Run: `npm test -- patcher.test.js component-structure-edit.test.ts`
Expected: PASS (same results as before — pure additive export).

- [ ] **Step 3: Commit**

```bash
git add server/patcher.mjs server/component-structure-edit.mjs
git commit -m "refactor: export pathToAstroCandidates and resolveInsertionOffset for reuse"
```

### Task A3: New resolver — `server/insert-image-edit.mjs`

**Files:**
- Create: `server/insert-image-edit.mjs`
- Test: `test/apply-edit-dispatcher.test.js` (new `describe("insert-image", ...)` block — written in Task A5, once the dispatcher is wired; this task's own step 2 exercises the resolver directly through a small standalone script since `resolve()` isn't wired to it until Task A4)

**Interfaces:**
- Consumes: `buildTemplateNodeIndex(ast, source)` from `./component-node-index.mjs` (returns `{byId: Map, rootId: string}`, each `byId` entry `{id, kind, tag, attrs, span, loc, parentId, childIds}`); `resolveAllSpans(byId, rootId, source)` and `escapeAttr(s)` and `resolveInsertionOffset(byId, rootId, spans, source, parent, index, excludeChildId)` from `./component-structure-edit.mjs`; `pathToAstroCandidates(projectRoot, pagePath)` from `./patcher.mjs`; `parse` from `@astrojs/compiler`.
- Produces: `export async function resolveInsertImage(projectRoot, edit)` returning `{file, range: {start, end}, replacement}` on success or `{refused: true, reason, detail}` on failure — the same `ResolveResult`/`ResolveRefusal` shape every other resolver in `patcher.mjs` returns. `edit` is expected to already have `edit.value = {src, srcset?, alt?}` (the dispatcher rewrites the raw `{filename, mimeType, dataURL}` payload before calling this — see Task A5).

- [ ] **Step 1: Write the file**

```js
import { readFileSync } from "node:fs";
import { relative } from "node:path";
import { parse } from "@astrojs/compiler";
import { buildTemplateNodeIndex } from "./component-node-index.mjs";
import { resolveAllSpans, resolveInsertionOffset, escapeAttr } from "./component-structure-edit.mjs";
import { pathToAstroCandidates } from "./patcher.mjs";

function refuse(reason, detail) {
  return { refused: true, reason, detail };
}

/**
 * Picks where a brand-new image should land inside a page's template: as the last child of the
 * page's sole wrapping Layout component when there is exactly one (every template page wraps its
 * content in one Layout, e.g. `<BaseLayout>...</BaseLayout>` — appending at the literal AST
 * fragment root would insert the <img> as a SIBLING of that wrapper, outside the rendered page
 * content), falling back to the fragment root itself for anything else (zero or multiple
 * top-level nodes, or a single non-component top-level node).
 */
function resolveImageParent(byId, rootId) {
  const root = byId.get(rootId);
  if (root.childIds.length === 1) {
    const only = byId.get(root.childIds[0]);
    if (only && only.kind === "component") return only;
  }
  return root;
}

/**
 * Resolves `insert-image` to a single-file patch that appends a new `<img>` inside the target
 * page's content. Unlike `insert-node`/`resolveComponentStructure`, this is NOT a component-payload
 * op — it addresses its target via `edit.path` (a URL page path, like `replace-image-src`), has no
 * `baseVersion` staleness guard (there is no prior `get_component_model` fetch to go stale against
 * — the file is always read fresh here), and takes no `component.parentId`/`index` — the insertion
 * point is always "append inside this page's content," resolved fresh from the current file.
 *
 * @param {string} projectRoot
 * @param {{ path: string, value: { src: string, srcset?: string, alt?: string } }} edit
 */
export async function resolveInsertImage(projectRoot, edit) {
  const candidates = pathToAstroCandidates(projectRoot, edit.path);
  if (candidates.length === 0) {
    return refuse("no-match", `no .astro file found for path ${edit.path}`);
  }
  if (candidates.length > 1) {
    return refuse("ambiguous", `${candidates.length} .astro files match path ${edit.path}`);
  }
  const absPath = candidates[0];

  let source;
  try {
    source = readFileSync(absPath, "utf-8");
  } catch (err) {
    return refuse("write-failed", `read ${edit.path}: ${err.message}`);
  }

  let ast;
  try {
    ({ ast } = await parse(source, { position: true }));
  } catch (err) {
    return refuse("parse-failed", `parse ${edit.path}: ${err.message}`);
  }

  const { byId, rootId } = buildTemplateNodeIndex(ast, source);
  const parent = resolveImageParent(byId, rootId);

  let spans;
  try {
    spans = resolveAllSpans(byId, rootId, source);
  } catch {
    return refuse(
      "no-match",
      "could not lexically re-locate the page's structure without trusting compiler offsets — refusing rather than risking corruption",
    );
  }

  const insertAt = resolveInsertionOffset(byId, rootId, spans, source, parent, parent.childIds.length, undefined);
  if (insertAt == null) {
    return refuse("no-match", "could not resolve an insertion point in the page");
  }

  const { src, srcset, alt } = edit.value;
  const attrs = [`src="${escapeAttr(src)}"`];
  if (srcset) attrs.push(`srcset="${escapeAttr(srcset)}"`);
  attrs.push(`alt="${escapeAttr(alt ?? "")}"`);
  const markup = `\n  <img ${attrs.join(" ")} />`;
  const replacement = source.slice(0, insertAt) + markup + source.slice(insertAt);

  return { file: relative(projectRoot, absPath), range: { start: 0, end: source.length }, replacement };
}
```

- [ ] **Step 2: Sanity-check it directly (no test framework yet — the real test lands in Task A5)**

Run from `~/Developer/github.com/Anglesite/anglesite`:

```bash
node -e '
import("./server/insert-image-edit.mjs").then(async ({ resolveInsertImage }) => {
  const { mkdtempSync, mkdirSync, writeFileSync, rmSync } = await import("node:fs");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const root = mkdtempSync(join(tmpdir(), "insert-image-"));
  mkdirSync(join(root, "src/pages"), { recursive: true });
  writeFileSync(join(root, "src/pages/index.astro"), "---\nimport BaseLayout from \"../layouts/BaseLayout.astro\";\n---\n\n<BaseLayout title=\"Home\">\n  <h1>Welcome</h1>\n</BaseLayout>\n");
  const result = await resolveInsertImage(root, { path: "/", value: { src: "/images/hero.webp", srcset: "/images/hero-480w.webp 480w", alt: "" } });
  console.log(JSON.stringify(result, null, 2));
  rmSync(root, { recursive: true, force: true });
});
'
```

Expected: prints `{file: "src/pages/index.astro", range: {...}, replacement: "...<img src=\"/images/hero.webp\" srcset=\"/images/hero-480w.webp 480w\" alt=\"\" />\n</BaseLayout>\n"}` — the `<img>` lands **inside** `<BaseLayout>`, immediately after `<h1>Welcome</h1>` and before `</BaseLayout>`, not after it.

- [ ] **Step 3: Commit**

```bash
git add server/insert-image-edit.mjs
git commit -m "feat: add resolveInsertImage — appends a new <img> inside a page's content"
```

### Task A4: Wire `patcher.mjs`'s `resolve()` to the new resolver

**Files:**
- Modify: `server/patcher.mjs:42-68` (`resolve()`)
- Test: covered by Task A5's dispatcher-level test (the dispatcher is the only realistic caller of `resolve()` for this op — `applyEdit()` always rewrites `edit.value` before calling `resolve()`, so a unit test at this layer would need to duplicate that rewrite).

**Interfaces:**
- Consumes: `resolveInsertImage` from `./insert-image-edit.mjs` (Task A3).

- [ ] **Step 1: Add the branch and import**

In `server/patcher.mjs`, add the import near the other resolver imports at the top:

```js
import { resolveInsertImage } from "./insert-image-edit.mjs";
```

In `resolve()`, add a branch before the `resolvers = [resolveMdoc, resolveKeystatic, resolveAstro]` fallback chain (right after the `COMPONENT_EXTRACT_OPS` branch):

```js
  if (COMPONENT_EXTRACT_OPS.has(edit.op)) {
    return resolveComponentExtract(projectRoot, edit);
  }
  if (edit.op === "insert-image") {
    return resolveInsertImage(projectRoot, edit);
  }
  const resolvers = [resolveMdoc, resolveKeystatic, resolveAstro];
```

- [ ] **Step 2: Commit**

```bash
git add server/patcher.mjs
git commit -m "feat: route insert-image to resolveInsertImage"
```

### Task A5: Dispatcher — reuse `processImageDrop`, thread `alt`, add tests

**Files:**
- Modify: `server/apply-edit-dispatcher.mjs:123-184` (`processImageDrop`), `server/apply-edit-dispatcher.mjs:310-320` (the `replace-image-src` branch in `applyEdit`)
- Test: `test/apply-edit-dispatcher.test.js` (new `describe("insert-image", ...)` block)

**Interfaces:**
- Consumes: `resolveInsertImage` transitively via `resolve()` (Task A4) — no direct import needed in this file.

- [ ] **Step 1: Write the failing tests**

In `test/apply-edit-dispatcher.test.js`, add a new `describe` block (mirroring the existing `describe("replace-image-src", ...)` block's fixture setup, but without git init — these tests don't assert on `commit`):

```js
describe("insert-image", () => {
  let projectRoot;

  beforeEach(() => {
    projectRoot = mkdtempSync(join(tmpdir(), "anglesite-img-insert-"));
    mkdirSync(join(projectRoot, "src/pages"), { recursive: true });
    mkdirSync(join(projectRoot, "src/layouts"), { recursive: true });
    writeFileSync(
      join(projectRoot, "src/layouts/BaseLayout.astro"),
      `---\ninterface Props { title: string }\nconst { title } = Astro.props;\n---\n<html><head><title>{title}</title></head><body><slot /></body></html>\n`,
    );
  });

  afterEach(() => {
    rmSync(projectRoot, { recursive: true, force: true });
  });

  it("writes bytes, optimizes, inserts a new <img> inside the page's Layout, and returns result.src+srcset", async () => {
    writeFileSync(
      join(projectRoot, "src/pages/index.astro"),
      `---\nimport BaseLayout from "../layouts/BaseLayout.astro";\n---\n\n<BaseLayout title="Home">\n  <h1>Welcome</h1>\n</BaseLayout>\n`,
    );

    const dropped = await sharp({ create: { width: 2000, height: 1500, channels: 3, background: { r: 10, g: 200, b: 10 } } })
      .jpeg()
      .toBuffer();
    const dataURL = `data:image/jpeg;base64,${dropped.toString("base64")}`;

    const result = await applyEdit(projectRoot, {
      id: "e-1",
      path: "/",
      op: "insert-image",
      value: { filename: "garden.jpg", mimeType: "image/jpeg", dataURL },
    });

    expect(result.isError).toBeUndefined();
    const reply = JSON.parse(result.content[0].text);
    expect(reply.type).toBe("anglesite:edit-applied");
    expect(reply.result.src).toBe("/images/garden.webp");
    expect(reply.result.srcset).toContain("480w");

    const astro = readFileSync(join(projectRoot, "src/pages/index.astro"), "utf-8");
    expect(astro).toContain('<img src="/images/garden.webp"');
    // Lands inside BaseLayout, after the existing <h1>, not after </BaseLayout>.
    const h1End = astro.indexOf("</h1>");
    const imgStart = astro.indexOf("<img");
    const layoutEnd = astro.indexOf("</BaseLayout>");
    expect(imgStart).toBeGreaterThan(h1End);
    expect(imgStart).toBeLessThan(layoutEnd);

    expect(existsSync(join(projectRoot, "public/images/garden.webp"))).toBe(true);
  });

  it("uses the dropped filename's stem — there is no existing image to derive one from", async () => {
    writeFileSync(
      join(projectRoot, "src/pages/index.astro"),
      `---\nimport BaseLayout from "../layouts/BaseLayout.astro";\n---\n\n<BaseLayout title="Home">\n  <h1>Welcome</h1>\n</BaseLayout>\n`,
    );
    const dropped = await sharp({ create: { width: 800, height: 600, channels: 3, background: { r: 0, g: 0, b: 0 } } })
      .png()
      .toBuffer();
    const dataURL = `data:image/png;base64,${dropped.toString("base64")}`;

    const result = await applyEdit(projectRoot, {
      id: "e-2",
      path: "/",
      op: "insert-image",
      value: { filename: "team-photo.png", mimeType: "image/png", dataURL },
    });

    const reply = JSON.parse(result.content[0].text);
    expect(reply.result.src).toBe("/images/team-photo.webp");
  });

  it("refuses with no-match when no .astro file exists for the path", async () => {
    const result = await applyEdit(projectRoot, {
      id: "e-3",
      path: "/nowhere/",
      op: "insert-image",
      value: { filename: "x.jpg", mimeType: "image/jpeg", dataURL: "data:image/jpeg;base64,AA==" },
    });

    expect(result.isError).toBe(true);
    const reply = JSON.parse(result.content[0].text);
    expect(reply.type).toBe("anglesite:edit-failed");
    expect(reply.reason).toBe("no-match");
  });

  it("returns image-optimize-failed when the dataURL bytes are corrupt", async () => {
    writeFileSync(
      join(projectRoot, "src/pages/index.astro"),
      `---\nimport BaseLayout from "../layouts/BaseLayout.astro";\n---\n\n<BaseLayout title="Home">\n  <h1>Welcome</h1>\n</BaseLayout>\n`,
    );

    const result = await applyEdit(projectRoot, {
      id: "e-4",
      path: "/",
      op: "insert-image",
      value: { filename: "x.jpg", mimeType: "image/jpeg", dataURL: "data:image/jpeg;base64,not-valid-base64!!!" },
    });

    expect(result.isError).toBe(true);
    const reply = JSON.parse(result.content[0].text);
    expect(reply.reason).toBe("image-optimize-failed");
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npm test -- apply-edit-dispatcher.test.js`
Expected: FAIL — `insert-image` isn't handled in `applyEdit()` yet (`processImageDrop` never runs for it, so `resolveInsertImage` never receives a rewritten `{src, srcset}` value; also `processImageDrop` would throw on `selector.textContent` since `edit.selector` is `undefined`).

- [ ] **Step 3: Fix `processImageDrop` and extend the `applyEdit` branch**

In `server/apply-edit-dispatcher.mjs`, change the `currentSrc` line inside `processImageDrop` (around line 129) from:

```js
  const currentSrc = selector.textContent ?? "";
```

to:

```js
  const currentSrc = selector?.textContent ?? "";
```

(`insert-image` never sends a `selector`, so `edit.selector` is `undefined` there — `processImageDrop` already falls back to the dropped filename's stem when the src can't be parsed, which is exactly what happens once this is a safe optional read instead of a crash.)

Change the op check and the value rewrite inside `applyEdit()` (around line 310) from:

```js
  if (edit.op === "replace-image-src") {
    try {
      imageResult = await processImageDrop(projectRoot, edit);
    } catch (err) {
      return failed(edit.id, "image-optimize-failed", String(err.message || err));
    }
    effectiveEdit = {
      ...edit,
      value: { src: imageResult.src, srcset: imageResult.srcset },
    };
  }
```

to:

```js
  if (edit.op === "replace-image-src" || edit.op === "insert-image") {
    try {
      imageResult = await processImageDrop(projectRoot, edit);
    } catch (err) {
      return failed(edit.id, "image-optimize-failed", String(err.message || err));
    }
    effectiveEdit = {
      ...edit,
      value: { src: imageResult.src, srcset: imageResult.srcset, alt: edit.value?.alt },
    };
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm test -- apply-edit-dispatcher.test.js`
Expected: PASS — all four new tests, and the existing `replace-image-src` tests unaffected (the `alt: edit.value?.alt` addition is `undefined` for those, same as before).

- [ ] **Step 5: Run the full sidecar test suite**

Run: `npm test`
Expected: PASS (no regressions in `patcher.test.js`, `component-structure-edit.test.ts`, or any other suite).

- [ ] **Step 6: Commit**

```bash
git add server/apply-edit-dispatcher.mjs test/apply-edit-dispatcher.test.js
git commit -m "feat(#1408): wire insert-image through processImageDrop"
```

### Task A6: Version bump, changelog, tag

**Files:**
- Modify: whatever this repo's release process touches (check `package.json` version + any `CHANGELOG.md`) — follow the existing release pattern used by the most recent tag (`v1.9.0` per `git log -1` at the start of this work).

- [ ] **Step 1: Confirm the release process**

Run: `git log --oneline -5` and `cat package.json | grep version` to see the current version and the commit style of the last release bump.

- [ ] **Step 2: Bump, tag, push**

Follow whatever the last release commit did (version bump commit + `git tag vX.Y.Z` + push commit and tag). **Do this only after Part A's PR is reviewed and merged to `main`** — do not tag a feature branch.

- [ ] **Step 3: Confirm the tag is visible**

Run: `git ls-remote --tags origin | tail -5` to confirm the new tag pushed.

---

## Part B — App (`Anglesite/Anglesite`, this repo)

Blocked on Part A's tag existing and being vendored. Do not start Part B's code changes until:

```bash
ANGLESITE_SIDECAR_SRC=~/Developer/github.com/Anglesite/anglesite scripts/vendor-container-image.sh
```
(or the equivalent podman/container build script this repo uses) has been re-run against the new tag, per `AGENTS.md` ▸ "Worktrees" and #1407's protocol-stamp guard (`project_1407_mcp_protocol_stamp_guard` memory) — that guard will fail the build if the vendored image is stale, which is the intended signal that Part A hasn't landed yet.

### Task B1: `EditMessage.Op.insertImage`

**Files:**
- Modify: `Sources/AnglesiteCore/EditMessage.swift:25-74` (`Op` enum)
- Test: `Tests/AnglesiteCoreTests/EditMessageTests.swift`

**Interfaces:**
- Produces: `EditMessage.Op.insertImage: String = "insert-image"`.

- [ ] **Step 1: Write the failing test**

In `Tests/AnglesiteCoreTests/EditMessageTests.swift`, add:

```swift
@Test("Op.insertImage matches the sidecar's wire string") func opInsertImageMatchesWireString() {
    #expect(EditMessage.Op.insertImage == "insert-image")
}

@Test("Decodes a valid insert-image message with no selector") func decodesInsertImageWithoutSelector() {
    let body: [String: Any] = [
        "id": "edit-2",
        "type": "anglesite:apply-edit",
        "path": "/",
        "op": "insert-image",
        "value": ["filename": "photo.jpg", "mimeType": "image/jpeg", "dataURL": "data:image/jpeg;base64,AA=="],
    ]
    let result = EditMessage.decode(from: body)
    guard case .success(let msg) = result else {
        Issue.record("expected success, got \(result)")
        return
    }
    #expect(msg.op == "insert-image")
    #expect(msg.selector == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter EditMessageTests`
Expected: FAIL — `EditMessage.Op` has no `insertImage` member.

- [ ] **Step 3: Add the constant**

In `Sources/AnglesiteCore/EditMessage.swift`, inside `enum Op`, add right after `replaceImageSrc`:

```swift
        /// `"replace-image-src"` — overlay image-drop replacement.
        public static let replaceImageSrc = "replace-image-src"
        /// `"insert-image"` — overlay drop-to-insert / Insert ▸ Image: writes a brand-new
        /// optimized asset and inserts a new `<img>` into the page, no existing image required.
        /// No `selector` — always targets the page's content root (server-resolved).
        public static let insertImage = "insert-image"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter EditMessageTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/EditMessage.swift Tests/AnglesiteCoreTests/EditMessageTests.swift
git commit -m "feat(#1408): add EditMessage.Op.insertImage"
```

### Task B2: `InsertImageEditBuilder` — pure, testable message construction

**Files:**
- Create: `Sources/AnglesiteCore/InsertImageEditBuilder.swift`
- Test: `Tests/AnglesiteCoreTests/InsertImageEditBuilderTests.swift`

**Interfaces:**
- Consumes: `EditMessage`, `EditMessage.Op.insertImage`, `JSONValue` (all in `AnglesiteCore`, already available).
- Produces: `InsertImageEditBuilder.dataURL(bytes: Data, mimeType: String) -> String`; `InsertImageEditBuilder.message(id: String = UUID().uuidString, path: String, filename: String, mimeType: String, dataURL: String) -> EditMessage`. Task B3 (the menu wiring) calls both.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import AnglesiteCore

struct InsertImageEditBuilderTests {
    @Test("dataURL base64-encodes bytes with the given mime type") func dataURLEncodesBytes() {
        let bytes = Data([0xFF, 0xD8, 0xFF])
        let url = InsertImageEditBuilder.dataURL(bytes: bytes, mimeType: "image/jpeg")
        #expect(url == "data:image/jpeg;base64,\(bytes.base64EncodedString())")
    }

    @Test("message builds an insert-image EditMessage with no selector") func messageBuildsInsertImageEdit() {
        let msg = InsertImageEditBuilder.message(
            id: "fixed-id",
            path: "/about/",
            filename: "team.jpg",
            mimeType: "image/jpeg",
            dataURL: "data:image/jpeg;base64,AA=="
        )
        #expect(msg.id == "fixed-id")
        #expect(msg.path == "/about/")
        #expect(msg.op == EditMessage.Op.insertImage)
        #expect(msg.selector == nil)
        guard case .object(let value) = msg.value else {
            Issue.record("expected .object value, got \(String(describing: msg.value))")
            return
        }
        guard case .string(let filename) = value["filename"] else {
            Issue.record("expected filename string")
            return
        }
        #expect(filename == "team.jpg")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter InsertImageEditBuilderTests`
Expected: FAIL — `InsertImageEditBuilder` doesn't exist yet.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Builds the `insert-image` `EditMessage` for a picked-file (not dropped-file) image insert —
/// `Insert ▸ Image`'s native counterpart to the overlay's own `FileReader.readAsDataURL` +
/// `postEdit` call. Pure and testable, mirroring `ComponentStructureEditBuilder`'s shape: the
/// menu command (`InsertCommands.swift`, AnglesiteApp) stays thin glue around this.
public enum InsertImageEditBuilder {
    /// Base64 data-URL for `bytes`, matching the wire format the sidecar's `processImageDrop`
    /// decodes (`data:<mimeType>;base64,<...>`).
    public static func dataURL(bytes: Data, mimeType: String) -> String {
        "data:\(mimeType);base64,\(bytes.base64EncodedString())"
    }

    /// Builds the `insert-image` message. No `selector` — the op always targets the page's
    /// content root, resolved server-side (see `EditMessage.Op.insertImage`'s doc comment).
    public static func message(
        id: String = UUID().uuidString,
        path: String,
        filename: String,
        mimeType: String,
        dataURL: String
    ) -> EditMessage {
        EditMessage(
            id: id,
            path: path,
            op: EditMessage.Op.insertImage,
            value: .object([
                "filename": .string(filename),
                "mimeType": .string(mimeType),
                "dataURL": .string(dataURL),
            ])
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter InsertImageEditBuilderTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/InsertImageEditBuilder.swift Tests/AnglesiteCoreTests/InsertImageEditBuilderTests.swift
git commit -m "feat(#1408): add InsertImageEditBuilder"
```

### Task B3: Wire `Insert ▸ Image` in `InsertCommands.swift`

**Files:**
- Modify: `Sources/AnglesiteApp/InsertCommands.swift:68` (replace the `PlannedItem("Image")` line)
- Test: manual (SwiftUI `Commands`/`NSOpenPanel` aren't unit-testable — `InsertImageEditBuilder`, the pure logic this leans on, already has coverage from Task B2). Verify per Task B5's manual checklist.

**Interfaces:**
- Consumes: `PreviewModel.activeRoute: String?` (`Sources/AnglesiteApp/PreviewModel.swift:39`), `PreviewModel.editRouter: EditRouter` (`Sources/AnglesiteApp/PreviewModel.swift:85`), `EditRouter.apply(_:) async -> EditReply` (`Sources/AnglesiteCore/EditRouter.swift:119`), `InsertImageEditBuilder.dataURL(bytes:mimeType:)` / `.message(...)` (Task B2). `@FocusedValue(\.preview) private var preview: PreviewModel?` is already declared in this file.

- [ ] **Step 1: Replace the disabled placeholder**

In `Sources/AnglesiteApp/InsertCommands.swift`, change:

```swift
            PlannedItem("Table")
            PlannedItem("Image")
            PlannedItem("Video")
```

to:

```swift
            PlannedItem("Table")
            Button("Image…") {
                guard let preview else { return }
                Task { await InsertCommands.insertImage(into: preview) }
            }
            .disabled(preview == nil)
            PlannedItem("Video")
```

- [ ] **Step 2: Add the picker/insert action**

Add these imports at the top of the file (after `import SwiftUI`):

```swift
import AppKit
import UniformTypeIdentifiers
import AnglesiteCore
```

Add this static function to `InsertCommands` (below `var body`):

```swift
    /// `Insert ▸ Image…`'s action: pick a file, write it through the same `insert-image` op the
    /// overlay's empty-page drop branch uses, via the focused window's real `MCPApplyEditRouter`
    /// (`preview.editRouter` — shared with the overlay and the Component Editor, per
    /// `SiteWindowModel.makeComponentEditorContext`'s doc comment).
    @MainActor
    private static func insertImage(into preview: PreviewModel) async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = String(localized: "Insert")
        panel.message = String(localized: "Choose an image to insert into this page.")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let bytes: Data
        do {
            bytes = try Data(contentsOf: url)
        } catch {
            presentFailureAlert(detail: error.localizedDescription)
            return
        }

        let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let dataURL = InsertImageEditBuilder.dataURL(bytes: bytes, mimeType: mimeType)
        let message = InsertImageEditBuilder.message(
            path: preview.activeRoute ?? "/",
            filename: url.lastPathComponent,
            mimeType: mimeType,
            dataURL: dataURL
        )

        let reply = await preview.editRouter.apply(message)
        if reply.status != .applied {
            presentFailureAlert(detail: reply.message ?? "Unknown error")
        }
    }

    @MainActor
    private static func presentFailureAlert(detail: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Couldn't insert that image")
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.runModal()
    }
```

- [ ] **Step 3: Build**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: builds clean (regenerate the Xcode project first if this worktree is fresh: `xcodegen generate`).

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteApp/InsertCommands.swift
git commit -m "feat(#1408): wire Insert > Image to the insert-image op"
```

### Task B4: Overlay — empty-page insert branch

**Files:**
- Modify: `JS/edit-overlay/src/messages.ts:16` (`EditMessage.selector` → optional), `JS/edit-overlay/src/overlay.ts:118-306` (`attachImageDrop`)
- Test: `JS/edit-overlay/test/overlay.test.ts`

**Interfaces:**
- Consumes: `nextEditID`, `postEdit`, `EditReply` from `./messages.js` (already imported); `showToast` from `./toast.js` (already imported); `elementInfoFor` from `./selector.js` (already imported, still used by the unchanged replace path).
- Produces: no new exports — `attachImageDrop`'s existing behavior for pages that already have images is unchanged; adds an insert path for pages with none.

- [ ] **Step 1: Make `selector` optional on the wire type**

In `JS/edit-overlay/src/messages.ts`, change:

```ts
  selector: ElementInfo;
```

to:

```ts
  /** Absent for `insert-image` — it always targets the page's content root, resolved
   *  server-side; every other op still sets it. */
  selector?: ElementInfo;
```

- [ ] **Step 2: Write the failing tests**

In `JS/edit-overlay/test/overlay.test.ts`, inside `describe("image drop", ...)`, add:

```ts
  it("shows an insert hint instead of a replace hint when the page has no images", () => {
    const file = new File([new Uint8Array([0xff, 0xd8])], "vacation.jpg", { type: "image/jpeg" });

    const event = dragOn("dragenter", document.body, file);

    expect(event.defaultPrevented).toBe(true);
    expect(document.querySelector(`[${IMAGE_DROP_HINT_ATTRIBUTE}]`)?.textContent).toMatch(/add this page's first image/i);
  });

  it("inserts a new image when dropped anywhere on a page with no images", async () => {
    const file = new File([new Uint8Array([0xff, 0xd8])], "vacation.jpg", { type: "image/jpeg" });

    dropOn(document.body, file);
    await flushFileReader();

    expect(sent.length).toBe(1);
    const msg = sent[0] as { op: string; selector?: unknown; value: { filename: string } };
    expect(msg.op).toBe("insert-image");
    expect(msg.selector).toBeUndefined();
    expect(msg.value.filename).toBe("vacation.jpg");
    // Optimistic insert: a new <img> is in the DOM immediately, pointing at a blob URL.
    const inserted = document.querySelector("img");
    expect(inserted).not.toBeNull();
    expect(inserted?.src).toMatch(/^blob:/);
  });

  it("explains a non-image file dropped on a page with no images without implying insert", () => {
    const file = new File(["notes"], "notes.txt", { type: "text/plain" });

    dropOn(document.body, file);

    expect(sent.length).toBe(0);
    expect(document.querySelector(".anglesite-toast")?.textContent).toMatch(/image file/i);
    expect(document.querySelector("img")).toBeNull();
  });
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `npm test -- overlay.test.ts` (from `JS/edit-overlay/`)
Expected: FAIL — the hint still says "no images to replace," the insert test sees `sent.length === 0` (falls into the existing "no images to replace" toast branch instead of posting `insert-image`).

- [ ] **Step 4: Update `showTargets()`'s hint text**

In `JS/edit-overlay/src/overlay.ts`, inside `attachImageDrop`'s `showTargets`, change:

```ts
    hint.textContent = targets.length > 0
      ? "Drop onto a highlighted image to replace it"
      : "This page has no images to replace";
```

to:

```ts
    hint.textContent = targets.length > 0
      ? "Drop onto a highlighted image to replace it"
      : "Drop anywhere to add this page's first image";
```

- [ ] **Step 5: Factor the existing replace logic into `replaceImage`, add `insertNewImage`**

Still in `attachImageDrop`, replace the whole `document.addEventListener("drop", (ev) => { ... });` block (the one starting right after `imageAtEvent`'s definition) with:

```ts
  const replaceImage = (target: HTMLImageElement, file: File): void => {
    // Save originals before the optimistic swap so we can revert on failure.
    const savedSrc = target.src;
    const savedSrcset = target.getAttribute("srcset");
    const blobURL = URL.createObjectURL(file);
    target.src = blobURL;
    target.removeAttribute("srcset");

    const id = nextEditID();
    let settled = false;

    const revertWithToast = (text: string): void => {
      if (settled) return;
      settled = true;
      target.src = savedSrc;
      if (savedSrcset !== null) target.setAttribute("srcset", savedSrcset);
      else target.removeAttribute("srcset");
      URL.revokeObjectURL(blobURL);
      showToast(text);
    };

    const settleOnReply = (reply: EditReply): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timeoutHandle);
      if (reply.status === "applied" && reply.result) {
        target.src = reply.result.src;
        if (reply.result.srcset !== undefined) {
          target.setAttribute("srcset", reply.result.srcset);
        } else {
          target.removeAttribute("srcset");
        }
        URL.revokeObjectURL(blobURL);
      } else {
        target.src = savedSrc;
        if (savedSrcset !== null) target.setAttribute("srcset", savedSrcset);
        else target.removeAttribute("srcset");
        URL.revokeObjectURL(blobURL);
        showToast(reply.detail ?? reply.message ?? reply.reason ?? "Image edit failed");
      }
    };

    const timeoutHandle = setTimeout(() => {
      revertWithToast("Image edit timed out");
    }, 30_000);

    awaitReply(id, settleOnReply);

    const reader = new FileReader();
    reader.onload = () => {
      const dataURL = reader.result;
      if (typeof dataURL !== "string") {
        revertWithToast("Couldn't read the dropped file");
        return;
      }
      const msg: EditMessage = {
        id,
        type: "anglesite:apply-edit",
        path: location.pathname,
        selector: elementInfoFor(target),
        op: "replace-image-src",
        value: { filename: file.name, mimeType: file.type, dataURL },
      };
      const ok = postEdit(msg);
      if (!ok) {
        clearTimeout(timeoutHandle);
        revertWithToast("Not running inside the Anglesite app");
      }
    };
    reader.onerror = () => revertWithToast("Couldn't read the dropped file");
    reader.readAsDataURL(file);
  };

  const insertNewImage = (file: File): void => {
    const element = document.createElement("img");
    const blobURL = URL.createObjectURL(file);
    element.src = blobURL;
    document.body.appendChild(element);

    const id = nextEditID();
    let settled = false;

    const revertWithToast = (text: string): void => {
      if (settled) return;
      settled = true;
      element.remove();
      URL.revokeObjectURL(blobURL);
      showToast(text);
    };

    const settleOnReply = (reply: EditReply): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timeoutHandle);
      if (reply.status === "applied" && reply.result) {
        element.src = reply.result.src;
        if (reply.result.srcset !== undefined) element.setAttribute("srcset", reply.result.srcset);
        URL.revokeObjectURL(blobURL);
      } else {
        element.remove();
        URL.revokeObjectURL(blobURL);
        showToast(reply.detail ?? reply.message ?? reply.reason ?? "Image insert failed");
      }
    };

    const timeoutHandle = setTimeout(() => {
      revertWithToast("Image insert timed out");
    }, 30_000);

    awaitReply(id, settleOnReply);

    const reader = new FileReader();
    reader.onload = () => {
      const dataURL = reader.result;
      if (typeof dataURL !== "string") {
        revertWithToast("Couldn't read the dropped file");
        return;
      }
      const msg: EditMessage = {
        id,
        type: "anglesite:apply-edit",
        path: location.pathname,
        op: "insert-image",
        value: { filename: file.name, mimeType: file.type, dataURL },
      };
      const ok = postEdit(msg);
      if (!ok) {
        clearTimeout(timeoutHandle);
        revertWithToast("Not running inside the Anglesite app");
      }
    };
    reader.onerror = () => revertWithToast("Couldn't read the dropped file");
    reader.readAsDataURL(file);
  };

  document.addEventListener("drop", (ev) => {
    const file = (ev as DragEvent).dataTransfer?.files[0];
    if (!file) {
      // dragover already recognized this as a file drag (dragIsFile true) using the always-
      // available types/items — but dataTransfer.files can still come back empty at drop time
      // for some promise-backed/multi-item drag sources. Still prevent WKWebView's default file
      // navigation and clear the stuck highlight state instead of silently discarding the drop.
      if (dragIsFile) {
        ev.preventDefault();
        clearTargets();
        showToast("Couldn't read the dropped file");
      }
      return;
    }
    ev.preventDefault();
    const target = imageAtEvent(ev as DragEvent);
    const hadTargets = imageTargets().length > 0;
    const isImageFile = file.type.startsWith("image/");
    clearTargets();

    if (!target) {
      if (!hadTargets && isImageFile) {
        insertNewImage(file);
        return;
      }
      showToast(!hadTargets
        ? "Drop an image file anywhere to add this page's first image"
        : isImageFile
          ? "Drop onto a highlighted image to replace it"
          : "Drop an image file onto a highlighted image to replace it");
      return;
    }
    if (!isImageFile) {
      showToast("Choose an image file to replace this image");
      return;
    }

    replaceImage(target, file);
  });
```

This is a pure refactor of the existing block (extracted into `replaceImage`) plus one new sibling function (`insertNewImage`) and a small branch in the `drop` handler — no behavior change for pages that already have images.

- [ ] **Step 6: Run tests to verify they pass**

Run: `npm test -- overlay.test.ts` (from `JS/edit-overlay/`)
Expected: PASS — new tests pass, and every existing `describe("image drop", ...)` test still passes unchanged (the `hadTargets === true` paths are untouched).

- [ ] **Step 7: Lint and typecheck**

Run: `npm run lint && npm run typecheck` (from `JS/edit-overlay/`)
Expected: clean — no new lint/type errors.

- [ ] **Step 8: Commit**

```bash
git add JS/edit-overlay/src/messages.ts JS/edit-overlay/src/overlay.ts JS/edit-overlay/test/overlay.test.ts
git commit -m "feat(#1408): insert a new image when dropped on a page with none"
```

### Task B5: End-to-end manual verification

**Files:** none — verification only.

- [ ] **Step 1: Run the full test suites**

```bash
swift test --package-path .
scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
(cd JS/edit-overlay && npm run lint && npm run typecheck && npm test)
```

Expected: all green.

- [ ] **Step 2: Manual — overlay drop-insert, on a freshly scaffolded site**

Create (or reuse) a scaffolded site whose `src/pages/index.astro` has no `<img>` tags (`Resources/Template/src/pages/index.astro` ships this way by default). Open it in Anglesite, enter edit mode, drag a Finder image file onto the page anywhere. Confirm: the hint reads "Drop anywhere to add this page's first image" while dragging; on drop, a new image appears on the page; `Source/public/images/` gains the optimized asset; re-opening the page after a reload still shows it (confirms the write landed in source, not just the optimistic DOM update).

- [ ] **Step 3: Manual — Insert ▸ Image menu**

On the same page, use `Insert ▸ Image…`, pick a Finder image file. Confirm: the file picker restricts to images, a new image appears on the page after the op applies, and the source file shows the new `<img>` tag inside the page's Layout wrapper (not floating outside it).

- [ ] **Step 4: Manual — failure path**

Temporarily stop the site's dev server / MCP connection (or pick an extremely large/corrupt file) and confirm both entry points show a clear failure message rather than silently doing nothing.

- [ ] **Step 5: Update #81's checklist**

Re-read #81's App Store container smoke test checklist row about the "Example photo" image-drop target. With this change, exercise that row using the flow from Step 2 above (a real freshly scaffolded site, not a pre-seeded fixture) and check it off / comment on #81 with the result.

- [ ] **Step 6: Commit any fixups found during manual verification**

If manual verification surfaces a bug, fix it, re-run the relevant automated test(s) from Steps 1, and commit as a normal TDD cycle (test first if the bug is coverable, then fix).
