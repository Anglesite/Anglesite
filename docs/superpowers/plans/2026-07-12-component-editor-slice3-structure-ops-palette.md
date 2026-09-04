# Component Editor Slice 3 (Structure Ops + Palette) Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the second write path for the Component Editor: four structure ops (`insert-node`, `move-node`, `remove-node`, `set-attr`) routed through the existing `apply_edit` MCP tool, plus the Swift-side palette (project components + curated HTML elements + `<slot>`), drag-and-drop into the outline and onto the canvas, drag-reorder/reparent in the outline, sealed component instances, and double-click-to-open for nested components.

**Architecture:** A new plugin resolver (`server/component-structure-edit.mjs`) re-parses the target `.astro` file on every write and re-derives node identity via a *shared* node index (`server/component-node-index.mjs`, extracted from `component-model.mjs`'s existing `NodeBuilder` so the read model and every write op agree on `nodeId` assignment by construction — the same shared-module discipline slice 2 established for CSS rule spans via `css-rule-index.mjs`). `insert-node`/`move-node`/`remove-node` return **whole-file rewrites** (`{file, range: {start: 0, end: source.length}, replacement}`), mirroring the existing `edit-style` op's precedent in `patcher.mjs`'s `resolveStyle` — a single op can need two textual edits at once (e.g. remove markup from one place *and* prune an unused import from the frontmatter), which a single byte-range splice can't express. `set-attr` is a single-range splice, like the style ops. A new frontmatter-import helper (`server/frontmatter-imports.mjs`) adds/removes `import X from "...";` lines via the same deliberately-regex-based approach `props-interface.mjs` already uses for frontmatter TS (no TS compiler in the container). On the app side, `ComponentEditorModel` gains four write methods reusing the existing `applyComponentStyleEdit` plumbing (stale/conflict/write-error handling is op-agnostic), a new `ComponentPalette` (AnglesiteCore, testable) lists project components + curated elements + `<slot>`, and `ComponentEditorView` gains a palette pane, SwiftUI `.draggable`/`.dropDestination` wiring for outline reorder/reparent and palette→outline drops, a canvas-drop-target overlay message (`component-canvas.ts`) for palette→canvas drops, sealed rendering for component-instance outline rows, and double-click navigation via the existing `SiteWindowModel.openFile(_:)` path.

**Tech Stack:** Node ≥22 ESM (`.mjs`), zod, vitest, `@astrojs/compiler` (plugin); Swift 6.4 / Swift Testing, SwiftUI `.draggable`/`.dropDestination`/`Transferable`, WKWebView (app); TypeScript overlay (`JS/edit-overlay`).

**Spec:** `docs/superpowers/specs/2026-07-05-component-editor-design.md` §2.2 (node ids), §2.3 (write ops), §3 (harness drop targets), §4.1 (outline + palette), §6 (composability).

## Global Constraints

- **Two repos.** Part A (Tasks 1–11) runs in the plugin repo `/Users/dwk/Developer/github.com/Anglesite/anglesite`. Part B (Tasks 12–21) runs in an app-repo worktree. Every task states its working directory — `cd` there first; dispatched subagents get a hard `cd` guard.
- **Node identity is id-based, not span-based.** Unlike CSS rules (`ruleSpan`), template nodes are identified by their model `id` (`n0`, `n1`, …) — an index-path-derived sequence assigned by a deterministic depth-first walk. Ids are stable **only within one model version**; every write op re-derives the current file's node index fresh from disk (never trusts client-supplied spans) and looks up the requested `nodeId` in that fresh index. If the id isn't found (file changed shape since the client's last fetch — a *shape* change, not just a `baseVersion` mismatch, though the two normally coincide), refuse `no-match`.
- **`insert-node`/`move-node`/`remove-node` are whole-file rewrites; `set-attr` is a single-range splice.** Follow `resolveStyle`'s existing precedent in `server/patcher.mjs` (`{file, range: {start: 0, end: source.length}, replacement: next}`) for the three ops that may touch two disjoint regions of the file (template markup + frontmatter imports) in one op.
- **`version` is a content hash, not a git SHA** — reuse `server/file-version.mjs`'s existing `fileVersion(source)` (`"sha256:" + <12 hex>`) unchanged; every resolver checks it twice (once inside the resolver, once again in `apply-edit-dispatcher.mjs` after its own independent re-read — the resolver's own `await parse(...)` opens a yield point a concurrent write could land in, exactly as slice 2's `component-style-edit.mjs`/`apply-edit-dispatcher.mjs` pair already does — see `tests/apply-edit-dispatcher-component-style.test.ts`'s race test for the pattern to replicate).
- **No TS/AST-based frontmatter rewriting.** `props-interface.mjs`'s doc comment is explicit: "Deliberately regex-based (no TS compiler in the container)." The new import add/remove helper follows the same discipline — line-oriented regex over `frontmatter.source`, never a JS/TS parser.
- **No `serialize()`/AST-node construction for markup.** `@astrojs/compiler`'s `utils` subpath exports a `serialize()`/`walk()` API, but it has zero existing usages in this codebase — every existing write op (including slice 2's `add-style-rule`) hand-builds replacement text and splices it in. `insert-node` follows the same pattern: hand-build the new element/component/slot markup as a string.
- **Reuse `ComponentModel.Node`'s existing Swift shape** (`Sources/AnglesiteCore/ComponentModel.swift`) — no wire-format changes to the read model in this slice; ids/spans/attrs already round-trip correctly per slice 1.
- **App worktree setup:** run `xcodegen generate` first (xcodeproj is gitignored), and `ANGLESITE_PLUGIN_SRC=/Users/dwk/Developer/github.com/Anglesite/anglesite scripts/copy-plugin.sh` before any `xcodebuild`/`swift test`. Re-run `copy-plugin.sh` after Part A's PR merges so `Resources/plugin` picks up the new ops.
- **Swift toolchain:** run tests as `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .` (default CommandLineTools swift is broken/too old).
- Plugin server code is ESM `.mjs`, Node ≥22, zod input schemas, tool replies `{ content: [{type:"text", text: JSON.stringify(...)}] }` with `isError: true` on failure.
- Swift: Swift Testing (`@Test`, `#expect`), `@testable import`; app-target logic stays thin — testable types go in `AnglesiteCore`.
- Overlay: `npm run typecheck && npm run lint && npm test` must pass in `JS/edit-overlay` before commit.
- Template changes can break Swift string-match tests — run `swift test` before pushing template edits, not just the JS build.
- **Known scope cut (document, don't silently drop):** "sealed component instances" in this slice means the outline does not recurse into a component-instance node's children (matching the spec's "children hidden" requirement) and any drop onto that row inserts as an unnamed child of the instance (today's slot-fill mechanism is positional/default-slot only). Detecting the *target* component's own named `<slot>`s (to show labeled slot-fill drop areas) requires resolving and parsing that component's own file and is deferred — not built in this slice. Double-click-to-open-that-component's-editor (the other sealed-instance affordance) **is** fully built.
- Conventional commits. Do not push tags, cut a plugin release, or merge to `main` in either repo without the user's go-ahead (checkpoints called out below).
- macOS 27 / SwiftUI 27; no LLM/Claude paths anywhere (deterministic Swift/TS only, per #459).

## File Structure

**Part A — plugin repo (`…/Anglesite/anglesite`):**

| File | Responsibility |
|---|---|
| `server/component-node-index.mjs` (create) | Shared `buildTemplateNodeIndex(ast, source)` — id-assigning depth-first walk, extracted from `component-model.mjs`'s `NodeBuilder` so read model and write ops agree on ids by construction |
| `server/component-model.mjs` (modify) | Delegate template-tree construction to the shared index; public JSON shape unchanged |
| `server/frontmatter-imports.mjs` (create) | `parseImports`, `ensureImport`, `pruneImportIfUnused` — regex-based frontmatter import add/remove |
| `server/component-structure-edit.mjs` (create) | `resolveComponentStructure(projectRoot, edit)` — `insert-node`/`move-node`/`remove-node`/`set-attr` |
| `server/apply-edit-schema.mjs` (modify) | New op names, `COMPONENT_STRUCTURE_OPS`/`COMPONENT_OPS` sets, extended `componentEditSchema` fields |
| `server/patcher.mjs` (modify) | Dispatch the 4 new ops to `resolveComponentStructure` |
| `server/apply-edit-dispatcher.mjs` (modify) | Widen the payload-required / model-piggyback checks from `COMPONENT_STYLE_OPS` to `COMPONENT_OPS` |
| `tests/component-node-index.test.ts` (create) | Id/span/parent/attr-span correctness fixtures |
| `tests/frontmatter-imports.test.ts` (create) | Import parse/add/prune fixtures |
| `tests/component-structure-edit.test.ts` (create) | Direct resolver unit tests — all 4 ops, stale, no-match, invalid-input |
| `tests/apply-edit-dispatcher-component-structure.test.ts` (create) | Dispatcher-level round trip + concurrent-write race test |
| `tests/component-model.test.ts` (modify) | Confirm the `NodeBuilder` extraction didn't change the public model shape |
| `tests/mcp-server.test.ts` (modify) | End-to-end stdio round trip for `insert-node` |
| `package.json`, `.claude-plugin/plugin.json`, `template/package.json`, `CHANGELOG.md` (modify) | Version bump for release |

**Part B — app repo worktree:**

| File | Responsibility |
|---|---|
| `Sources/AnglesiteCore/EditMessage.swift` (modify) | New `Op` constants: `insertNode`, `moveNode`, `removeNode`, `setAttr` |
| `Sources/AnglesiteCore/ComponentStructureEditBuilder.swift` (create) | Builds the 4 new `EditMessage` payloads, mirrors `ComponentStyleEditBuilder` |
| `Sources/AnglesiteCore/ComponentPalette.swift` (create) | Curated HTML elements + project components (via `SiteFileTree`) + `<slot>`, pure/testable |
| `Sources/AnglesiteCore/ComponentOutline.swift` (modify) | Sealed-instance row filtering; `ComponentDragItem`/`PaletteDragPayload` `Transferable` types |
| `Sources/AnglesiteApp/ComponentEditorModel.swift` (modify) | Four write methods (`insertNode`, `moveNode`, `removeNode`, `setAttr`); `onOpenComponent` callback |
| `Sources/AnglesiteApp/ComponentEditorView.swift` (modify) | Palette pane; outline drag-reorder/reparent; palette→outline drop; canvas drop-target wiring; sealed rows; double-click nav; editable Attributes section |
| `JS/edit-overlay/src/component-canvas.ts` (modify) | `window.anglesiteCanvas.dropTargetAt(x, y)` — nearest droppable node + position |
| `JS/edit-overlay/test/component-canvas.test.ts` (modify) | Drop-target resolution tests |
| `Tests/AnglesiteCoreTests/EditMessageTests.swift` (modify) | New op constants |
| `Tests/AnglesiteCoreTests/ComponentStructureEditBuilderTests.swift` (create) | Payload-shape tests for the 4 builders |
| `Tests/AnglesiteCoreTests/ComponentPaletteTests.swift` (create) | Curated list + project-component scan tests |
| `Tests/AnglesiteCoreTests/ComponentOutlineTests.swift` (modify) | Sealed-row filtering tests |
| `Tests/AnglesiteCoreTests/ComponentEditorModelStructureEditTests.swift` (create) | Write-method tests against a fake `EditRouter` |
| `scripts/copy-plugin.sh` (modify) | Bump `MIN_PLUGIN_VERSION` to the new plugin release |

---

# Part A — Plugin repo

All Part A tasks: `cd /Users/dwk/Developer/github.com/Anglesite/anglesite`.

### Task 1: Branch, and extract the shared node index

**Files:**
- Create: `server/component-node-index.mjs`
- Create: `tests/component-node-index.test.ts`
- Modify: `server/component-model.mjs`
- Modify: `tests/component-model.test.ts` (no behavior change expected — this step just confirms it)

**Interfaces:**
- Produces: `buildTemplateNodeIndex(ast, source) → { byId: Map<string, NodeRecord>, rootId: string }` where `NodeRecord = { id, kind, tag, attrs: [{name, value, span:[start,end]}], span:[start,end], loc:{line,column}|null, text?: string, parentId: string|null, childIds: string[] }`. `rootId` is the synthetic fragment root's id (always `"n0"`, matching `component-model.mjs`'s existing convention of assigning the root id *before* walking children).
- Consumes (in `component-model.mjs`): replaces the inline `NodeBuilder` class with a thin mapper from `NodeRecord` down to the model's public `{id, kind, tag, attrs, span, loc, text, children}` shape (dropping `attrs[].span` and `parentId`/`childIds` — the read-only model's public JSON is unchanged).

- [ ] **Step 1: Branch**

```bash
git checkout main && git pull
git checkout -b feat/component-structure-ops
```

- [ ] **Step 2: Write the failing test**

Create `tests/component-node-index.test.ts`:

```typescript
import { describe, it, expect } from "vitest";
import { parse } from "@astrojs/compiler";
import { buildTemplateNodeIndex } from "../server/component-node-index.mjs";

const CARD = `---
interface Props { title: string; }
---
<article class="card" data-size="lg">
  <h2>{title}</h2>
  <Badge label="new" />
</article>
`;

describe("buildTemplateNodeIndex", () => {
  it("assigns the synthetic root id n0, then depth-first ids to real nodes", async () => {
    const { ast } = await parse(CARD, { position: true });
    const { byId, rootId } = buildTemplateNodeIndex(ast, CARD);
    expect(rootId).toBe("n0");
    const root = byId.get("n0");
    expect(root.kind).toBe("fragment");
    expect(root.parentId).toBeNull();
    expect(root.childIds).toHaveLength(1); // <article>

    const article = byId.get(root.childIds[0]);
    expect(article.kind).toBe("element");
    expect(article.tag).toBe("article");
    expect(article.parentId).toBe("n0");
  });

  it("captures attribute name/value/span", async () => {
    const { ast } = await parse(CARD, { position: true });
    const { byId, rootId } = buildTemplateNodeIndex(ast, CARD);
    const article = byId.get(byId.get(rootId).childIds[0]);
    const classAttr = article.attrs.find((a) => a.name === "class");
    expect(classAttr.value).toBe("card");
    expect(CARD.slice(classAttr.span[0], classAttr.span[1])).toBe('class="card"');
  });

  it("classifies a capitalized tag as kind=component and indexes it as a child", async () => {
    const { ast } = await parse(CARD, { position: true });
    const { byId, rootId } = buildTemplateNodeIndex(ast, CARD);
    const article = byId.get(byId.get(rootId).childIds[0]);
    const badgeId = article.childIds.find((id) => byId.get(id).kind === "component");
    expect(byId.get(badgeId).tag).toBe("Badge");
    expect(byId.get(badgeId).parentId).toBe(article.id);
  });

  it("gives the same ids across two independent parses of identical source (determinism)", async () => {
    const { ast: ast1 } = await parse(CARD, { position: true });
    const { ast: ast2 } = await parse(CARD, { position: true });
    const idx1 = buildTemplateNodeIndex(ast1, CARD);
    const idx2 = buildTemplateNodeIndex(ast2, CARD);
    expect([...idx1.byId.keys()]).toEqual([...idx2.byId.keys()]);
  });

  it("skips style/script zones and filters non-JSX text out of expression children", async () => {
    const src = `---\n---\n<div>{items.map((i) => (<li>{i}</li>))}</div>\n<style>.x{color:red;}</style>\n<script>console.log(1)</script>\n`;
    const { ast } = await parse(src, { position: true });
    const { byId, rootId } = buildTemplateNodeIndex(ast, src);
    const div = byId.get(byId.get(rootId).childIds[0]);
    expect(div.tag).toBe("div");
    const expr = byId.get(div.childIds[0]);
    expect(expr.kind).toBe("expression");
    const li = byId.get(expr.childIds[0]);
    expect(li.tag).toBe("li");
    // style/script never appear as template children anywhere in the tree.
    for (const rec of byId.values()) {
      expect(rec.kind).not.toBe("style");
      expect(rec.kind).not.toBe("script");
    }
  });
});
```

- [ ] **Step 3: Run to verify it fails**

```bash
npm test -- tests/component-node-index.test.ts
```

Expected: FAIL — module doesn't exist yet.

- [ ] **Step 4: Implement `server/component-node-index.mjs`**

```javascript
// Shared depth-first node index for one .astro component's template — the
// single source of truth for node `id` assignment, consumed by BOTH the
// read-only component-model.mjs and the structural write resolver
// (component-structure-edit.mjs), so the two always agree on identity for
// the same source (same deterministic walk over the same parsed AST).

const JSX_CHILD_TYPES = new Set(["element", "component", "custom-element", "fragment"]);

export function isZoneNode(n) {
  return n.type === "frontmatter" || (n.type === "element" && (n.name === "style" || n.name === "script"));
}

function attrSpan(a) {
  if (!a.position?.start) return [null, null];
  return [a.position.start.offset, a.position.end?.offset ?? null];
}

function attrsOf(n) {
  return (n.attributes ?? []).map((a) => ({
    name: a.name,
    value: a.kind === "empty" ? null : a.value,
    span: attrSpan(a),
  }));
}

function baseSpanLoc(n) {
  const start = n.position?.start;
  const end = n.position?.end;
  return {
    span: [start?.offset ?? null, end?.offset ?? null],
    loc: start ? { line: start.line, column: start.column } : null,
  };
}

export function buildTemplateNodeIndex(ast, source) {
  const byId = new Map();
  let next = 0;
  const nextId = () => `n${next++}`;

  const rootId = nextId();
  const rootChildIds = [];
  byId.set(rootId, {
    id: rootId,
    kind: "fragment",
    tag: null,
    attrs: [],
    span: [0, source.length],
    loc: null,
    parentId: null,
    childIds: rootChildIds,
  });

  function visit(n, parentId) {
    let record;
    switch (n.type) {
      case "element":
        record = {
          id: nextId(),
          kind: n.name === "slot" ? "slot" : "element",
          tag: n.name,
          attrs: attrsOf(n),
          ...baseSpanLoc(n),
          parentId,
          childIds: [],
        };
        break;
      case "component":
      case "custom-element":
        record = { id: nextId(), kind: "component", tag: n.name, attrs: attrsOf(n), ...baseSpanLoc(n), parentId, childIds: [] };
        break;
      case "fragment":
        record = { id: nextId(), kind: "fragment", tag: null, attrs: attrsOf(n), ...baseSpanLoc(n), parentId, childIds: [] };
        break;
      case "expression": {
        record = { id: nextId(), kind: "expression", tag: null, attrs: [], ...baseSpanLoc(n), parentId, childIds: [] };
        byId.set(record.id, record);
        for (const c of n.children ?? []) {
          if (!JSX_CHILD_TYPES.has(c.type)) continue;
          const child = visit(c, record.id);
          if (child) record.childIds.push(child.id);
        }
        return record;
      }
      case "text": {
        const value = (n.value ?? "").trim();
        if (!value) return null;
        record = { id: nextId(), kind: "text", tag: null, attrs: [], text: value.slice(0, 80), ...baseSpanLoc(n), parentId, childIds: [] };
        byId.set(record.id, record);
        return record;
      }
      default:
        return null; // comment, doctype
    }
    byId.set(record.id, record);
    for (const c of n.children ?? []) {
      if (isZoneNode(c)) continue;
      const child = visit(c, record.id);
      if (child) record.childIds.push(child.id);
    }
    return record;
  }

  const topLevel = (ast.children ?? []).filter((n) => !isZoneNode(n));
  for (const n of topLevel) {
    const child = visit(n, rootId);
    if (child) rootChildIds.push(child.id);
  }

  return { byId, rootId };
}
```

- [ ] **Step 5: Run the new tests to verify they pass**

```bash
npm test -- tests/component-node-index.test.ts
```

Expected: PASS. If the attribute-span test fails because `a.position` covers only the attribute *name* (not `name="value"`), adjust `attrSpan` to compute the end offset as `a.position.start.offset + \`${a.name}${a.kind === "empty" ? "" : \`="${a.value}"\`}\`.length` instead, and re-run.

- [ ] **Step 6: Refactor `component-model.mjs` to delegate**

Read the current file first (`Sources` here means the plugin's `server/component-model.mjs`, not the app):

```bash
cat server/component-model.mjs
```

Replace the `NodeBuilder` class and the `template` construction in `buildComponentModel` with:

```javascript
import { buildTemplateNodeIndex, isZoneNode } from "./component-node-index.mjs";
```

```javascript
function toPublicNode(byId, id) {
  const r = byId.get(id);
  const node = {
    id: r.id,
    kind: r.kind,
    tag: r.tag,
    attrs: r.attrs.map(({ name, value }) => ({ name, value })),
    span: r.span,
    loc: r.loc,
    children: r.childIds.map((cid) => toPublicNode(byId, cid)),
  };
  if (r.text !== undefined) node.text = r.text;
  return node;
}
```

In `buildComponentModel`, replace:

```javascript
const builder = new NodeBuilder();
const topLevel = ast.children ?? [];
const template = {
  id: builder.nextId(),
  kind: "fragment",
  tag: null,
  attrs: [],
  span: [0, source.length],
  loc: null,
  children: topLevel
    .filter((n) => !isZoneNode(n))
    .map((n) => builder.toNode(n))
    .filter(Boolean),
};
```

with:

```javascript
const { byId, rootId } = buildTemplateNodeIndex(ast, source);
const template = toPublicNode(byId, rootId);
```

Remove the now-unused `NodeBuilder` class, `JSX_CHILD_TYPES` constant, and the local `isZoneNode` function (imported above instead) from `component-model.mjs`. Leave `collectElements`/`extractRules`/`ComponentModelError` and everything else untouched.

- [ ] **Step 7: Run the full existing model test suite to confirm no regression**

```bash
npm test -- tests/component-model.test.ts
```

Expected: PASS, unchanged — every existing fixture (fragments, scss, nested zones, expressions) must produce byte-identical JSON to before this refactor.

- [ ] **Step 8: Commit**

```bash
git add server/component-node-index.mjs server/component-model.mjs tests/component-node-index.test.ts
git commit -m "refactor(mcp): extract buildTemplateNodeIndex for reuse by the structure-edit resolver"
```

### Task 2: Frontmatter import helpers

**Files:**
- Create: `server/frontmatter-imports.mjs`
- Create: `tests/frontmatter-imports.test.ts`

**Interfaces:**
- Produces: `parseImports(frontmatterSource) → [{ localName, specifier, span: [start, end] }]` (span covers the whole `import X from "...";` line including its trailing newline, so removal never leaves a blank line).
- Produces: `ensureImport(frontmatterSource, { localName, specifier }) → { source, added: boolean }` — appends a new import line after the last existing import (or right after the frontmatter's opening, if none) unless one with the same `specifier` already exists, in which case `source` is unchanged and `added` is `false`.
- Produces: `pruneImportIfUnused(frontmatterSource, templateSourceAfterEdit, localName) → { source, removed: boolean }` — removes the import line for `localName` if `templateSourceAfterEdit` no longer contains `<localName` (word-boundary), else leaves `frontmatterSource` unchanged.

- [ ] **Step 1: Write the failing test**

Create `tests/frontmatter-imports.test.ts`:

```typescript
import { describe, it, expect } from "vitest";
import { parseImports, ensureImport, pruneImportIfUnused } from "../server/frontmatter-imports.mjs";

const FM_WITH_IMPORTS = `
import Badge from "./Badge.astro";
import { formatDate } from "../lib/dates";
interface Props { title: string; }
`;

describe("parseImports", () => {
  it("finds default-import lines with local name, specifier, and line span", () => {
    const imports = parseImports(FM_WITH_IMPORTS);
    const badge = imports.find((i) => i.localName === "Badge");
    expect(badge.specifier).toBe("./Badge.astro");
    expect(FM_WITH_IMPORTS.slice(badge.span[0], badge.span[1])).toBe('import Badge from "./Badge.astro";\n');
  });

  it("ignores named imports (not component-shaped)", () => {
    const imports = parseImports(FM_WITH_IMPORTS);
    expect(imports.some((i) => i.specifier === "../lib/dates")).toBe(false);
  });

  it("returns [] for frontmatter with no imports", () => {
    expect(parseImports("interface Props {}\n")).toEqual([]);
  });
});

describe("ensureImport", () => {
  it("appends a new import after the last existing import", () => {
    const { source, added } = ensureImport(FM_WITH_IMPORTS, { localName: "Callout", specifier: "./Callout.astro" });
    expect(added).toBe(true);
    expect(source).toContain('import Callout from "./Callout.astro";');
    expect(source.indexOf('import Callout')).toBeGreaterThan(source.indexOf('import Badge'));
    expect(source.indexOf('import Callout')).toBeLessThan(source.indexOf('interface Props'));
  });

  it("inserts at the very start when there are no existing imports", () => {
    const { source, added } = ensureImport("interface Props {}\n", { localName: "Callout", specifier: "./Callout.astro" });
    expect(added).toBe(true);
    expect(source.indexOf('import Callout')).toBeLessThan(source.indexOf('interface Props'));
  });

  it("is a no-op when an import for the same specifier already exists", () => {
    const { source, added } = ensureImport(FM_WITH_IMPORTS, { localName: "Badge", specifier: "./Badge.astro" });
    expect(added).toBe(false);
    expect(source).toBe(FM_WITH_IMPORTS);
  });
});

describe("pruneImportIfUnused", () => {
  it("removes the import line when the tag no longer appears in the template", () => {
    const { source, removed } = pruneImportIfUnused(FM_WITH_IMPORTS, "<article><h2>gone</h2></article>", "Badge");
    expect(removed).toBe(true);
    expect(source).not.toContain("Badge");
  });

  it("keeps the import when the tag is still used", () => {
    const { source, removed } = pruneImportIfUnused(FM_WITH_IMPORTS, "<article><Badge label=\"x\" /></article>", "Badge");
    expect(removed).toBe(false);
    expect(source).toBe(FM_WITH_IMPORTS);
  });

  it("is a no-op when there is no import for that name", () => {
    const { source, removed } = pruneImportIfUnused(FM_WITH_IMPORTS, "<article></article>", "Nope");
    expect(removed).toBe(false);
    expect(source).toBe(FM_WITH_IMPORTS);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

```bash
npm test -- tests/frontmatter-imports.test.ts
```

Expected: FAIL — module doesn't exist.

- [ ] **Step 3: Implement `server/frontmatter-imports.mjs`**

```javascript
// Regex-based frontmatter import add/remove — deliberately no TS parser in
// the container, same discipline as props-interface.mjs's parseProps.
// Only default imports (`import X from "...";`) are modeled: that's the only
// shape Astro component usage generates (`import Badge from "./Badge.astro"`).

const IMPORT_LINE_RE = /^import\s+(\w+)\s+from\s+["']([^"']+)["'];?\r?\n?/gm;

/** Default-import lines only — named/namespace imports are left alone (never a component). */
export function parseImports(frontmatterSource) {
  const imports = [];
  let m;
  IMPORT_LINE_RE.lastIndex = 0;
  while ((m = IMPORT_LINE_RE.exec(frontmatterSource)) !== null) {
    imports.push({ localName: m[1], specifier: m[2], span: [m.index, m.index + m[0].length] });
  }
  return imports;
}

export function ensureImport(frontmatterSource, { localName, specifier }) {
  const imports = parseImports(frontmatterSource);
  if (imports.some((i) => i.specifier === specifier)) {
    return { source: frontmatterSource, added: false };
  }
  const line = `import ${localName} from "${specifier}";\n`;
  if (imports.length > 0) {
    const insertAt = imports[imports.length - 1].span[1];
    return {
      source: frontmatterSource.slice(0, insertAt) + line + frontmatterSource.slice(insertAt),
      added: true,
    };
  }
  // No existing imports: insert right after the frontmatter's leading newline (or at the very
  // start if the frontmatter source doesn't begin with one), so it lands as the first statement.
  const insertAt = frontmatterSource.startsWith("\n") ? 1 : 0;
  return {
    source: frontmatterSource.slice(0, insertAt) + line + frontmatterSource.slice(insertAt),
    added: true,
  };
}

export function pruneImportIfUnused(frontmatterSource, templateSourceAfterEdit, localName) {
  const imports = parseImports(frontmatterSource);
  const target = imports.find((i) => i.localName === localName);
  if (!target) return { source: frontmatterSource, removed: false };
  const stillUsed = new RegExp(`<${localName}\\b`).test(templateSourceAfterEdit);
  if (stillUsed) return { source: frontmatterSource, removed: false };
  return {
    source: frontmatterSource.slice(0, target.span[0]) + frontmatterSource.slice(target.span[1]),
    removed: true,
  };
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
npm test -- tests/frontmatter-imports.test.ts
```

Expected: PASS, all 9 cases.

- [ ] **Step 5: Commit**

```bash
git add server/frontmatter-imports.mjs tests/frontmatter-imports.test.ts
git commit -m "feat(mcp): add regex-based frontmatter import add/prune helpers"
```

### Task 3: Schema — new ops and extended component payload

**Files:**
- Modify: `server/apply-edit-schema.mjs`
- Create: `tests/apply-edit-schema-structure.test.ts`

**Interfaces:**
- Produces: `editOps` gains `insert-node`, `move-node`, `remove-node`, `set-attr`. New exported `COMPONENT_STRUCTURE_OPS: Set<string>` and `COMPONENT_OPS: Set<string>` (union of style + structure ops, for the dispatcher's shared checks).
- Produces: `componentEditSchema` gains `nodeId`, `name` (attribute name for `set-attr`), `parentId`, `index`, `newParentId`, `newIndex`, `node` (insert spec: `{kind, tag?, componentPath?, slotName?}`). `value` becomes `.nullable()` (an explicit `null` means "remove the attribute" for `set-attr`; style ops still reject non-string values in their own resolver-level checks, so this widening is behavior-neutral for them).

- [ ] **Step 1: Write the failing test**

Create `tests/apply-edit-schema-structure.test.ts`:

```typescript
import { describe, it, expect } from "vitest";
import { z } from "zod";
import { editOps, componentEditSchema, applyEditInputShape, COMPONENT_STRUCTURE_OPS, COMPONENT_OPS } from "../server/apply-edit-schema.mjs";

describe("component-structure op schema", () => {
  it("registers the four new op names in both sets", () => {
    for (const op of ["insert-node", "move-node", "remove-node", "set-attr"]) {
      expect(editOps).toContain(op);
      expect(COMPONENT_STRUCTURE_OPS.has(op)).toBe(true);
      expect(COMPONENT_OPS.has(op)).toBe(true);
    }
    // style ops still in the union too
    expect(COMPONENT_OPS.has("set-style-property")).toBe(true);
  });

  it("accepts a set-attr payload with a null value (removal)", () => {
    const schema = z.object(applyEditInputShape);
    const result = schema.safeParse({
      id: "1",
      path: "src/components/Card.astro",
      op: "set-attr",
      component: { path: "src/components/Card.astro", baseVersion: "sha256:abc123456789", nodeId: "n1", name: "class", value: null },
    });
    expect(result.success).toBe(true);
  });

  it("accepts an insert-node payload with a component node spec", () => {
    const result = componentEditSchema.safeParse({
      path: "src/components/Card.astro",
      baseVersion: "sha256:abc123456789",
      parentId: "n0",
      index: 0,
      node: { kind: "component", tag: "Badge", componentPath: "src/components/Badge.astro" },
    });
    expect(result.success).toBe(true);
  });

  it("accepts a move-node payload", () => {
    const result = componentEditSchema.safeParse({
      path: "src/components/Card.astro",
      baseVersion: "sha256:abc123456789",
      nodeId: "n2",
      newParentId: "n0",
      newIndex: 1,
    });
    expect(result.success).toBe(true);
  });

  it("still accepts a legacy set-style-property payload (value stays a plain string there)", () => {
    const result = componentEditSchema.safeParse({
      path: "src/components/Card.astro",
      baseVersion: "sha256:abc123456789",
      ruleSpan: [1, 2],
      property: "color",
      value: "red",
    });
    expect(result.success).toBe(true);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

```bash
npm test -- tests/apply-edit-schema-structure.test.ts
```

Expected: FAIL — new exports/fields don't exist yet.

- [ ] **Step 3: Implement the schema additions**

In `server/apply-edit-schema.mjs`, change `editOps` to:

```javascript
export const editOps = [
  "replace-text",
  "replace-attr",
  "replace-image-src",
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
];

export const COMPONENT_STRUCTURE_OPS = new Set(["insert-node", "move-node", "remove-node", "set-attr"]);

export const COMPONENT_OPS = new Set([...COMPONENT_STYLE_OPS, ...COMPONENT_STRUCTURE_OPS]);
```

(`COMPONENT_STYLE_OPS` is already defined above this point in the file — leave it as-is.)

Extend `componentEditSchema` — add these fields to the existing `z.object({...})`:

```javascript
  nodeId: z.string().optional().describe("Identifies an existing template node by its get_component_model id. Required for set-attr, remove-node, move-node's source node."),
  name: z.string().optional().describe("Attribute name for set-attr"),
  parentId: z.string().optional().describe("Parent node id for insert-node (the fragment root's id for a top-level insert)"),
  index: z.number().int().optional().describe("Child index to insert at, for insert-node"),
  newParentId: z.string().optional().describe("Destination parent node id for move-node"),
  newIndex: z.number().int().optional().describe("Destination child index for move-node"),
  node: z
    .object({
      kind: z.enum(["element", "component", "slot"]),
      tag: z.string().optional().describe("HTML tag name (element) or component name (component); omitted for slot"),
      componentPath: z.string().optional().describe("Project-relative .astro path to import, required when kind=component"),
      slotName: z.string().optional().describe("Named slot, for kind=slot; omitted means the default slot"),
    })
    .optional()
    .describe("New node spec for insert-node"),
```

Change `value: z.string().optional()` to `value: z.string().nullable().optional()` in the same object (a `null` value means "remove", used by `set-attr`; existing style-op resolvers already validate `typeof value === "string"` before using it, so this widening doesn't change their behavior).

Update the `op` field's `.describe(...)` text in `applyEditInputShape` to mention the four new ops (cosmetic; append to the existing description string): `"... set-style-property/remove-style-property/add-style-rule/set-rule-selector (component-style ops), insert-node/move-node/remove-node/set-attr (component-structure ops — see componentEditSchema)"`.

- [ ] **Step 4: Run tests to verify they pass**

```bash
npm test -- tests/apply-edit-schema-structure.test.ts tests/apply-edit-schema-component.test.ts
```

Expected: PASS — both the new tests and the existing slice-2 schema tests (regression check on the `value` widening).

- [ ] **Step 5: Commit**

```bash
git add server/apply-edit-schema.mjs tests/apply-edit-schema-structure.test.ts
git commit -m "feat(mcp): add component-structure op names and payload schema to apply_edit"
```

### Task 4: The write resolver — `set-attr`

**Files:**
- Create: `server/component-structure-edit.mjs`
- Create: `tests/component-structure-edit.test.ts`

**Interfaces:**
- Produces: `async function resolveComponentStructure(projectRoot, edit) → {file, range: {start,end}, replacement} | {refused: true, reason, detail}` — same result shape every other resolver in `patcher.mjs` produces. This task implements the `set-attr` branch only; Tasks 5–7 add the other three.
- Consumes: `buildTemplateNodeIndex` (Task 1), `fileVersion` (existing `file-version.mjs`).

- [ ] **Step 1: Write the failing tests**

Create `tests/component-structure-edit.test.ts`:

```typescript
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, mkdirSync, writeFileSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { parse } from "@astrojs/compiler";
import { resolveComponentStructure } from "../server/component-structure-edit.mjs";
import { buildTemplateNodeIndex } from "../server/component-node-index.mjs";
import { fileVersion } from "../server/file-version.mjs";

const CARD = `---
interface Props { title: string; }
---
<article class="card" data-size="lg">
  <h2>{title}</h2>
</article>
`;

async function nodeIndex(source) {
  const { ast } = await parse(source, { position: true });
  return buildTemplateNodeIndex(ast, source);
}

describe("resolveComponentStructure — set-attr", () => {
  let tmpDir;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "anglesite-cse2-"));
    mkdirSync(join(tmpDir, "src", "components"), { recursive: true });
    writeFileSync(join(tmpDir, "src", "components", "Card.astro"), CARD);
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  function apply(resolution) {
    const source = readFileSync(join(tmpDir, "src", "components", "Card.astro"), "utf-8");
    return source.slice(0, resolution.range.start) + resolution.replacement + source.slice(resolution.range.end);
  }

  it("refuses invalid-input with no component payload", async () => {
    const result = await resolveComponentStructure(tmpDir, { op: "set-attr" });
    expect(result.refused).toBe(true);
    expect(result.reason).toBe("invalid-input");
  });

  it("refuses stale when baseVersion does not match", async () => {
    const edit = { op: "set-attr", component: { path: "src/components/Card.astro", baseVersion: "sha256:000000000000", nodeId: "n1", name: "class", value: "x" } };
    const result = await resolveComponentStructure(tmpDir, edit);
    expect(result.refused).toBe(true);
    expect(result.reason).toBe("stale");
  });

  it("replaces an existing attribute's value in place", async () => {
    const baseVersion = fileVersion(CARD);
    const { byId, rootId } = await nodeIndex(CARD);
    const article = byId.get(byId.get(rootId).childIds[0]);
    const edit = { op: "set-attr", component: { path: "src/components/Card.astro", baseVersion, nodeId: article.id, name: "class", value: "card--big" } };
    const result = await resolveComponentStructure(tmpDir, edit);
    expect(result.refused).toBeFalsy();
    expect(apply(result)).toContain('class="card--big"');
    expect(apply(result)).toContain('data-size="lg"');
  });

  it("adds a new attribute when absent", async () => {
    const baseVersion = fileVersion(CARD);
    const { byId, rootId } = await nodeIndex(CARD);
    const article = byId.get(byId.get(rootId).childIds[0]);
    const edit = { op: "set-attr", component: { path: "src/components/Card.astro", baseVersion, nodeId: article.id, name: "id", value: "hero-card" } };
    const result = await resolveComponentStructure(tmpDir, edit);
    expect(apply(result)).toMatch(/<article class="card" data-size="lg" id="hero-card">/);
  });

  it("removes an attribute when value is null", async () => {
    const baseVersion = fileVersion(CARD);
    const { byId, rootId } = await nodeIndex(CARD);
    const article = byId.get(byId.get(rootId).childIds[0]);
    const edit = { op: "set-attr", component: { path: "src/components/Card.astro", baseVersion, nodeId: article.id, name: "data-size", value: null } };
    const result = await resolveComponentStructure(tmpDir, edit);
    expect(apply(result)).not.toContain("data-size");
    expect(apply(result)).toContain('class="card"');
  });

  it("refuses no-match when the nodeId no longer exists", async () => {
    const baseVersion = fileVersion(CARD);
    const edit = { op: "set-attr", component: { path: "src/components/Card.astro", baseVersion, nodeId: "n999", name: "class", value: "x" } };
    const result = await resolveComponentStructure(tmpDir, edit);
    expect(result.refused).toBe(true);
    expect(result.reason).toBe("no-match");
  });

  it("adds an attribute to an element with no existing attributes", async () => {
    const bare = `---\n---\n<article><p></p></article>\n`;
    writeFileSync(join(tmpDir, "src", "components", "Card.astro"), bare);
    const baseVersion = fileVersion(bare);
    const { byId, rootId } = await nodeIndex(bare);
    const article = byId.get(byId.get(rootId).childIds[0]);
    const p = byId.get(article.childIds[0]);

    const edit = { op: "set-attr", component: { path: "src/components/Card.astro", baseVersion, nodeId: p.id, name: "class", value: "lead" } };
    const result = await resolveComponentStructure(tmpDir, edit);
    const source = readFileSync(join(tmpDir, "src", "components", "Card.astro"), "utf-8");
    const next = source.slice(0, result.range.start) + result.replacement + source.slice(result.range.end);
    expect(next).toContain('<p class="lead"></p>');
  });
});
```

- [ ] **Step 2: Run to verify it fails**

```bash
npm test -- tests/component-structure-edit.test.ts
```

Expected: FAIL — module doesn't exist.

- [ ] **Step 3: Implement `server/component-structure-edit.mjs` (set-attr only for now)**

```javascript
import { readFileSync } from "node:fs";
import { join, normalize, dirname, relative } from "node:path";
import { parse } from "@astrojs/compiler";
import { fileVersion } from "./file-version.mjs";
import { buildTemplateNodeIndex } from "./component-node-index.mjs";
import { ensureImport, pruneImportIfUnused } from "./frontmatter-imports.mjs";

function refuse(reason, detail) {
  return { refused: true, reason, detail };
}

function validPath(relPath) {
  return typeof relPath === "string" && relPath.endsWith(".astro") && !normalize(relPath).startsWith("..") && !relPath.startsWith("/");
}

async function loadFresh(projectRoot, relPath, baseVersion) {
  const absPath = join(projectRoot, relPath);
  let source;
  try {
    source = readFileSync(absPath, "utf-8");
  } catch (err) {
    return { error: refuse("read-failed", `read ${relPath}: ${err.message}`) };
  }
  if (fileVersion(source) !== baseVersion) {
    return { error: refuse("stale", `${relPath} changed since the model was fetched`) };
  }
  let ast;
  try {
    ({ ast } = await parse(source, { position: true }));
  } catch (err) {
    return { error: refuse("invalid-input", `parse ${relPath}: ${err.message}`) };
  }
  const { byId, rootId } = buildTemplateNodeIndex(ast, source);
  return { source, ast, byId, rootId };
}

export async function resolveComponentStructure(projectRoot, edit) {
  const { component } = edit;
  if (!component || typeof component !== "object") {
    return refuse("invalid-input", "component payload is required for this op");
  }
  const { path: relPath, baseVersion } = component;
  if (!validPath(relPath)) {
    return refuse("invalid-input", `not a project-relative .astro path: ${relPath}`);
  }

  const loaded = await loadFresh(projectRoot, relPath, baseVersion);
  if (loaded.error) return loaded.error;
  const { source, byId } = loaded;

  switch (edit.op) {
    case "set-attr":
      return applySetAttr(relPath, byId, component);
    default:
      return refuse("invalid-input", `unsupported component-structure op: ${edit.op}`);
  }
}

function applySetAttr(file, byId, component) {
  const { nodeId, name, value } = component;
  if (typeof nodeId !== "string" || typeof name !== "string") {
    return refuse("invalid-input", "set-attr requires component.nodeId and component.name");
  }
  const node = byId.get(nodeId);
  if (!node || node.span[0] == null || node.span[1] == null) {
    return refuse("no-match", "no node found at the given id — the file may have changed");
  }
  const existing = node.attrs.find((a) => a.name === name);

  if (value === null || value === undefined) {
    if (!existing) return refuse("no-match", `node has no attribute "${name}" to remove`);
    // Trim exactly the one leading space that separated this attribute from the previous
    // token (tag name or prior attribute) so removal doesn't leave a double space.
    const start = existing.span[0] - 1 >= 0 ? existing.span[0] - 1 : existing.span[0];
    return { file, range: { start, end: existing.span[1] }, replacement: "" };
  }

  if (existing) {
    return { file, range: { start: existing.span[0], end: existing.span[1] }, replacement: `${name}="${value}"` };
  }
  // Insert right after the opening tag name / last attribute — i.e. at the end of the node's
  // own attribute list. `node.span[0]` is the start of `<tag`; the tag-name end is the offset
  // right before the first attribute (or before `>`/`/>` if there are none). Reuse the last
  // attribute's end when present; otherwise fall back to just after the tag name.
  const lastAttr = node.attrs[node.attrs.length - 1];
  const insertAt = lastAttr ? lastAttr.span[1] : node.span[0] + 1 + (node.tag?.length ?? 0);
  return { file, range: { start: insertAt, end: insertAt }, replacement: ` ${name}="${value}"` };
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
npm test -- tests/component-structure-edit.test.ts
```

Expected: PASS, all 7 cases. If the "adds an attribute to an element with no existing attributes" case fails because the fallback offset (`node.span[0] + 1 + tag.length`) lands in the wrong place, adjust it to search forward from `node.span[0]` for the first `>` or whitespace instead, and re-run.

- [ ] **Step 5: Commit**

```bash
git add server/component-structure-edit.mjs tests/component-structure-edit.test.ts
git commit -m "feat(mcp): add set-attr to the component-structure resolver"
```

### Task 5: The write resolver — `remove-node` (with import pruning)

**Files:**
- Modify: `server/component-structure-edit.mjs`
- Modify: `tests/component-structure-edit.test.ts`

**Interfaces:**
- Produces: `remove-node` branch returning a **whole-file** replacement (`range: {start: 0, end: source.length}`).

- [ ] **Step 1: Write the failing tests**

Append to `tests/component-structure-edit.test.ts` (inside a new `describe` block, same file):

```typescript
describe("resolveComponentStructure — remove-node", () => {
  let tmpDir;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "anglesite-cse3-"));
    mkdirSync(join(tmpDir, "src", "components"), { recursive: true });
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  function apply(resolution, before) {
    return before.slice(0, resolution.range.start) + resolution.replacement + before.slice(resolution.range.end);
  }

  it("removes a plain element subtree", async () => {
    const src = `---\n---\n<article><h2>Title</h2><p>Body</p></article>\n`;
    writeFileSync(join(tmpDir, "src", "components", "Card.astro"), src);
    const baseVersion = fileVersion(src);
    const { byId, rootId } = await nodeIndex(src);
    const article = byId.get(byId.get(rootId).childIds[0]);
    const p = byId.get(article.childIds[1]);

    const edit = { op: "remove-node", component: { path: "src/components/Card.astro", baseVersion, nodeId: p.id } };
    const result = await resolveComponentStructure(tmpDir, edit);
    const next = apply(result, src);
    expect(next).not.toContain("Body");
    expect(next).toContain("<h2>Title</h2>");
  });

  it("removing the last usage of a component prunes its import", async () => {
    const src = `---\nimport Badge from "./Badge.astro";\n---\n<article><Badge label="new" /></article>\n`;
    writeFileSync(join(tmpDir, "src", "components", "Card.astro"), src);
    const baseVersion = fileVersion(src);
    const { byId, rootId } = await nodeIndex(src);
    const article = byId.get(byId.get(rootId).childIds[0]);
    const badge = byId.get(article.childIds[0]);

    const edit = { op: "remove-node", component: { path: "src/components/Card.astro", baseVersion, nodeId: badge.id } };
    const result = await resolveComponentStructure(tmpDir, edit);
    const next = apply(result, src);
    expect(next).not.toContain("Badge");
    expect(next).not.toContain("import Badge");
  });

  it("keeps the import when another usage remains", async () => {
    const src = `---\nimport Badge from "./Badge.astro";\n---\n<article><Badge label="a" /><Badge label="b" /></article>\n`;
    writeFileSync(join(tmpDir, "src", "components", "Card.astro"), src);
    const baseVersion = fileVersion(src);
    const { byId, rootId } = await nodeIndex(src);
    const article = byId.get(byId.get(rootId).childIds[0]);
    const firstBadge = byId.get(article.childIds[0]);

    const edit = { op: "remove-node", component: { path: "src/components/Card.astro", baseVersion, nodeId: firstBadge.id } };
    const result = await resolveComponentStructure(tmpDir, edit);
    const next = apply(result, src);
    expect(next).toContain("import Badge");
    expect(next).toContain('label="b"');
    expect(next).not.toContain('label="a"');
  });

  it("refuses no-match for an unknown nodeId", async () => {
    const src = `---\n---\n<article></article>\n`;
    writeFileSync(join(tmpDir, "src", "components", "Card.astro"), src);
    const baseVersion = fileVersion(src);
    const edit = { op: "remove-node", component: { path: "src/components/Card.astro", baseVersion, nodeId: "n999" } };
    const result = await resolveComponentStructure(tmpDir, edit);
    expect(result.refused).toBe(true);
    expect(result.reason).toBe("no-match");
  });

  it("refuses invalid-input when trying to remove the fragment root", async () => {
    const src = `---\n---\n<article></article>\n`;
    writeFileSync(join(tmpDir, "src", "components", "Card.astro"), src);
    const baseVersion = fileVersion(src);
    const edit = { op: "remove-node", component: { path: "src/components/Card.astro", baseVersion, nodeId: "n0" } };
    const result = await resolveComponentStructure(tmpDir, edit);
    expect(result.refused).toBe(true);
    expect(result.reason).toBe("invalid-input");
  });

  it("removes an expression node as a single opaque unit (spec §2.2: move/remove as a unit only)", async () => {
    const src = `---\n---\n<ul>{items.map((i) => (<li>{i}</li>))}</ul>\n`;
    writeFileSync(join(tmpDir, "src", "components", "Card.astro"), src);
    const baseVersion = fileVersion(src);
    const { byId, rootId } = await nodeIndex(src);
    const ul = byId.get(byId.get(rootId).childIds[0]);
    const expr = byId.get(ul.childIds[0]);
    expect(expr.kind).toBe("expression");

    const edit = { op: "remove-node", component: { path: "src/components/Card.astro", baseVersion, nodeId: expr.id } };
    const result = await resolveComponentStructure(tmpDir, edit);
    const next = apply(result, src);
    // The whole {items.map(...)} block is gone in one piece — not just the <li> JSX inside it.
    expect(next).not.toContain("items.map");
    expect(next).not.toContain("<li>");
    expect(next).toContain("<ul></ul>");
  });
});
```

- [ ] **Step 2: Run to verify the new cases fail**

```bash
npm test -- tests/component-structure-edit.test.ts
```

Expected: FAIL on the `remove-node` cases (op not dispatched yet); the `set-attr` cases from Task 4 still pass.

- [ ] **Step 3: Implement the `remove-node` branch**

Add to the `switch` in `resolveComponentStructure`:

```javascript
    case "remove-node":
      return applyRemoveNode(relPath, source, byId, component);
```

Add the implementation function:

```javascript
function applyRemoveNode(file, source, byId, component) {
  const { nodeId } = component;
  if (typeof nodeId !== "string") {
    return refuse("invalid-input", "remove-node requires component.nodeId");
  }
  const node = byId.get(nodeId);
  if (!node) return refuse("no-match", "no node found at the given id — the file may have changed");
  if (node.parentId === null) return refuse("invalid-input", "cannot remove the component's root");
  if (node.span[0] == null || node.span[1] == null) {
    return refuse("no-match", "node has no removable span (likely the synthetic root)");
  }

  // Trim a single leading run of horizontal whitespace back to (but not past) a preceding
  // newline, then swallow that newline too — mirrors remove-style-property's cleanup so
  // removing a node doesn't leave a blank line in its place.
  let start = node.span[0];
  while (start > 0 && (source[start - 1] === " " || source[start - 1] === "\t")) start--;
  if (start > 0 && source[start - 1] === "\n") start--;

  const withoutNode = source.slice(0, start) + source.slice(node.span[1]);

  // Prune now-unused component imports. Only meaningful for `component`-kind nodes (and any
  // component-kind descendants the removed subtree also carried away); walk the removed
  // subtree collecting component tag names, then check each against the frontmatter's import
  // list against the POST-removal template text.
  const removedComponentNames = collectComponentTags(byId, nodeId);
  if (removedComponentNames.length === 0) {
    return { file, range: { start: 0, end: source.length }, replacement: withoutNode };
  }

  const fmMatch = withoutNode.match(/^(---\r?\n)([\s\S]*?)(\r?\n---)/);
  if (!fmMatch) {
    return { file, range: { start: 0, end: source.length }, replacement: withoutNode };
  }
  const [whole, open, fmBody, close] = fmMatch;
  const fmStart = fmMatch.index;
  const fmBodyStart = fmStart + open.length;
  let newFmBody = fmBody;
  for (const name of removedComponentNames) {
    newFmBody = pruneImportIfUnused(newFmBody, withoutNode.slice(fmStart + whole.length), name).source;
  }
  const rewritten = withoutNode.slice(0, fmBodyStart) + newFmBody + withoutNode.slice(fmBodyStart + fmBody.length);
  return { file, range: { start: 0, end: source.length }, replacement: rewritten };
}

function collectComponentTags(byId, nodeId) {
  const names = [];
  function walk(id) {
    const n = byId.get(id);
    if (!n) return;
    if (n.kind === "component" && n.tag) names.push(n.tag);
    for (const c of n.childIds) walk(c);
  }
  walk(nodeId);
  return names;
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
npm test -- tests/component-structure-edit.test.ts
```

Expected: PASS, all cases including Task 4's.

- [ ] **Step 5: Commit**

```bash
git add server/component-structure-edit.mjs tests/component-structure-edit.test.ts
git commit -m "feat(mcp): add remove-node with unused-import pruning"
```

### Task 6: The write resolver — `insert-node` (with import add)

**Files:**
- Modify: `server/component-structure-edit.mjs`
- Modify: `tests/component-structure-edit.test.ts`

**Interfaces:**
- Produces: `insert-node` branch returning a **whole-file** replacement.

- [ ] **Step 1: Write the failing tests**

Append a new `describe` block to `tests/component-structure-edit.test.ts`:

```typescript
describe("resolveComponentStructure — insert-node", () => {
  let tmpDir;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "anglesite-cse4-"));
    mkdirSync(join(tmpDir, "src", "components"), { recursive: true });
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  function apply(resolution, before) {
    return before.slice(0, resolution.range.start) + resolution.replacement + before.slice(resolution.range.end);
  }

  it("inserts a plain element as the last child of a parent with existing children", async () => {
    const src = `---\n---\n<article><h2>Title</h2></article>\n`;
    writeFileSync(join(tmpDir, "src", "components", "Card.astro"), src);
    const baseVersion = fileVersion(src);
    const { byId, rootId } = await nodeIndex(src);
    const article = byId.get(byId.get(rootId).childIds[0]);

    const edit = {
      op: "insert-node",
      component: { path: "src/components/Card.astro", baseVersion, parentId: article.id, index: 1, node: { kind: "element", tag: "p" } },
    };
    const result = await resolveComponentStructure(tmpDir, edit);
    const next = apply(result, src);
    expect(next).toContain("<h2>Title</h2><p></p>");

    // Re-parses cleanly.
    const { ast } = await parse(next, { position: true });
    expect(ast).toBeDefined();
  });

  it("inserts a top-level element when parentId is the fragment root", async () => {
    const src = `---\n---\n<article></article>\n`;
    writeFileSync(join(tmpDir, "src", "components", "Card.astro"), src);
    const baseVersion = fileVersion(src);
    const { rootId } = await nodeIndex(src);

    const edit = {
      op: "insert-node",
      component: { path: "src/components/Card.astro", baseVersion, parentId: rootId, index: 1, node: { kind: "element", tag: "footer" } },
    };
    const result = await resolveComponentStructure(tmpDir, edit);
    const next = apply(result, src);
    expect(next).toContain("<article></article>\n<footer></footer>");
  });

  it("inserts a slot", async () => {
    const src = `---\n---\n<article></article>\n`;
    writeFileSync(join(tmpDir, "src", "components", "Card.astro"), src);
    const baseVersion = fileVersion(src);
    const { byId, rootId } = await nodeIndex(src);
    const article = byId.get(byId.get(rootId).childIds[0]);

    const edit = {
      op: "insert-node",
      component: { path: "src/components/Card.astro", baseVersion, parentId: article.id, index: 0, node: { kind: "slot", slotName: "footer" } },
    };
    const result = await resolveComponentStructure(tmpDir, edit);
    const next = apply(result, src);
    expect(next).toContain('<slot name="footer" />');
  });

  it("inserts a component instance and adds its import", async () => {
    const src = `---\n---\n<article></article>\n`;
    writeFileSync(join(tmpDir, "src", "components", "Card.astro"), src);
    mkdirSync(join(tmpDir, "src", "components"), { recursive: true });
    writeFileSync(join(tmpDir, "src", "components", "Badge.astro"), `---\n---\n<span>Badge</span>\n`);
    const baseVersion = fileVersion(src);
    const { byId, rootId } = await nodeIndex(src);
    const article = byId.get(byId.get(rootId).childIds[0]);

    const edit = {
      op: "insert-node",
      component: {
        path: "src/components/Card.astro",
        baseVersion,
        parentId: article.id,
        index: 0,
        node: { kind: "component", tag: "Badge", componentPath: "src/components/Badge.astro" },
      },
    };
    const result = await resolveComponentStructure(tmpDir, edit);
    const next = apply(result, src);
    expect(next).toContain('import Badge from "./Badge.astro";');
    expect(next).toContain("<Badge />");

    const { ast } = await parse(next, { position: true });
    expect(ast).toBeDefined();
  });

  it("reuses an existing import instead of duplicating it", async () => {
    const src = `---\nimport Badge from "./Badge.astro";\n---\n<article><Badge label="a" /></article>\n`;
    writeFileSync(join(tmpDir, "src", "components", "Card.astro"), src);
    const baseVersion = fileVersion(src);
    const { byId, rootId } = await nodeIndex(src);
    const article = byId.get(byId.get(rootId).childIds[0]);

    const edit = {
      op: "insert-node",
      component: {
        path: "src/components/Card.astro",
        baseVersion,
        parentId: article.id,
        index: 1,
        node: { kind: "component", tag: "Badge", componentPath: "src/components/Badge.astro" },
      },
    };
    const result = await resolveComponentStructure(tmpDir, edit);
    const next = apply(result, src);
    expect(next.match(/import Badge/g)).toHaveLength(1);
  });

  it("refuses invalid-input when a component node has no componentPath", async () => {
    const src = `---\n---\n<article></article>\n`;
    writeFileSync(join(tmpDir, "src", "components", "Card.astro"), src);
    const baseVersion = fileVersion(src);
    const { byId, rootId } = await nodeIndex(src);
    const article = byId.get(byId.get(rootId).childIds[0]);

    const edit = {
      op: "insert-node",
      component: { path: "src/components/Card.astro", baseVersion, parentId: article.id, index: 0, node: { kind: "component", tag: "Badge" } },
    };
    const result = await resolveComponentStructure(tmpDir, edit);
    expect(result.refused).toBe(true);
    expect(result.reason).toBe("invalid-input");
  });

  it("refuses no-match when parentId doesn't exist", async () => {
    const src = `---\n---\n<article></article>\n`;
    writeFileSync(join(tmpDir, "src", "components", "Card.astro"), src);
    const baseVersion = fileVersion(src);
    const edit = {
      op: "insert-node",
      component: { path: "src/components/Card.astro", baseVersion, parentId: "n999", index: 0, node: { kind: "element", tag: "p" } },
    };
    const result = await resolveComponentStructure(tmpDir, edit);
    expect(result.refused).toBe(true);
    expect(result.reason).toBe("no-match");
  });
});
```

- [ ] **Step 2: Run to verify the new cases fail**

```bash
npm test -- tests/component-structure-edit.test.ts
```

Expected: FAIL on `insert-node` cases.

- [ ] **Step 3: Implement the `insert-node` branch**

Add to the `switch`:

```javascript
    case "insert-node":
      return applyInsertNode(relPath, source, byId, component);
```

Add the implementation, plus a markup-builder and an insertion-point helper:

```javascript
function buildMarkup(nodeSpec) {
  if (nodeSpec.kind === "slot") {
    return nodeSpec.slotName ? `<slot name="${nodeSpec.slotName}" />` : `<slot />`;
  }
  if (nodeSpec.kind === "component") {
    return `<${nodeSpec.tag} />`;
  }
  return `<${nodeSpec.tag}></${nodeSpec.tag}>`;
}

/** Offset just inside `parent`'s content — before its first child (index 0) or after its
 *  last child / any prior sibling at `index - 1` (append). `parent` must have a real
 *  closing tag (not self-closing); insert-node only ever targets parents already known to
 *  have (or be able to have) children per the model — a leaf like <img/> never appears as a
 *  valid `parentId` because it has no children to select in the outline in the first place. */
function insertionOffset(parent, byId, index) {
  const children = parent.childIds.map((id) => byId.get(id)).filter((c) => c.span[0] != null);
  if (children.length === 0 || index <= 0) {
    // Before the first child, or the parent has none yet: right after the opening tag.
    if (children.length > 0) return children[0].span[0];
    // parent.span covers the WHOLE element including its closing tag for a childless
    // element; approximate "just inside" as immediately before the closing tag by
    // scanning backward for '</'. Falls back to the parent's end if not found (defensive;
    // every parentId this resolver accepts has a matching close tag by construction).
    const closeIdx = parent.tag ? parent.__sourceSlice?.lastIndexOf(`</${parent.tag}>`) : -1;
    return parent.span[1]; // overwritten below once source is threaded in — see applyInsertNode
  }
  const clampedIndex = Math.min(index, children.length);
  return clampedIndex === children.length ? children[children.length - 1].span[1] : children[clampedIndex].span[0];
}

function applyInsertNode(file, source, byId, component) {
  const { parentId, index, node: nodeSpec } = component;
  if (typeof parentId !== "string" || typeof index !== "number" || !nodeSpec || typeof nodeSpec !== "object") {
    return refuse("invalid-input", "insert-node requires component.parentId, component.index, and component.node");
  }
  if (!["element", "component", "slot"].includes(nodeSpec.kind)) {
    return refuse("invalid-input", `unsupported node.kind: ${nodeSpec.kind}`);
  }
  if ((nodeSpec.kind === "element" || nodeSpec.kind === "component") && typeof nodeSpec.tag !== "string") {
    return refuse("invalid-input", "node.tag is required for element/component inserts");
  }
  if (nodeSpec.kind === "component" && typeof nodeSpec.componentPath !== "string") {
    return refuse("invalid-input", "node.componentPath is required for component inserts");
  }
  const parent = byId.get(parentId);
  if (!parent) return refuse("no-match", "no parent node found at the given id — the file may have changed");

  const children = parent.childIds.map((id) => byId.get(id)).filter((c) => c.span[0] != null);
  let insertAt;
  if (children.length === 0) {
    if (parent.parentId === null) {
      // Top-level insert with no existing template content: append at end of file.
      insertAt = source.length;
    } else {
      // Insert just before the parent's own closing tag.
      const closeTag = `</${parent.tag}>`;
      const candidate = parent.span[1] - closeTag.length;
      insertAt = source.slice(candidate, parent.span[1]) === closeTag ? candidate : parent.span[1];
    }
  } else {
    const clampedIndex = Math.max(0, Math.min(index, children.length));
    insertAt = clampedIndex === children.length ? children[children.length - 1].span[1] : children[clampedIndex].span[0];
  }

  const markup = buildMarkup(nodeSpec);
  const withNode = source.slice(0, insertAt) + markup + source.slice(insertAt);

  if (nodeSpec.kind !== "component") {
    return { file, range: { start: 0, end: source.length }, replacement: withNode };
  }

  const fmMatch = withNode.match(/^(---\r?\n)([\s\S]*?)(\r?\n---)/);
  if (!fmMatch) {
    // No frontmatter at all yet — synthesize one carrying just the import.
    const importLine = `import ${nodeSpec.tag} from "${importSpecifier(file, nodeSpec.componentPath)}";\n`;
    return { file, range: { start: 0, end: source.length }, replacement: `---\n${importLine}---\n${withNode}` };
  }
  const [, open, fmBody] = fmMatch;
  const fmBodyStart = fmMatch.index + open.length;
  const { source: newFmBody } = ensureImport(fmBody, { localName: nodeSpec.tag, specifier: importSpecifier(file, nodeSpec.componentPath) });
  const rewritten = withNode.slice(0, fmBodyStart) + newFmBody + withNode.slice(fmBodyStart + fmBody.length);
  return { file, range: { start: 0, end: source.length }, replacement: rewritten };
}

/** Relative import specifier from the target component's own directory to the component
 *  being inserted, Astro-style (keeps the .astro extension, always POSIX-separated, always
 *  prefixed with ./ or ../ so it never gets mistaken for a bare-specifier package import). */
function importSpecifier(targetRelPath, componentRelPath) {
  const rel = relative(dirname(targetRelPath), componentRelPath).split(sep).join("/");
  return rel.startsWith(".") ? rel : `./${rel}`;
}
```

Remove the unused `insertionOffset` helper stub (it was superseded by the inline logic in `applyInsertNode` — delete that function entirely; it was scaffolding while drafting, not real code). Add `import { sep } from "node:path";` to the existing `node:path` import line at the top of the file (alongside `join, normalize, dirname, relative`).

- [ ] **Step 4: Run tests to verify they pass**

```bash
npm test -- tests/component-structure-edit.test.ts
```

Expected: PASS, all cases. If the "top-level insert" test's exact whitespace doesn't match (e.g. `withNode` lands with different spacing than `"<article></article>\n<footer></footer>"`), adjust the assertion to `toMatch(/<article><\/article>\s*<footer><\/footer>/)` instead of an exact `toContain` — whitespace-insensitive matching is fine here since the model's `span`-based diffing doesn't depend on exact inter-node whitespace.

- [ ] **Step 5: Commit**

```bash
git add server/component-structure-edit.mjs tests/component-structure-edit.test.ts
git commit -m "feat(mcp): add insert-node with auto-import-on-insert"
```

### Task 7: The write resolver — `move-node`

**Files:**
- Modify: `server/component-structure-edit.mjs`
- Modify: `tests/component-structure-edit.test.ts`

**Interfaces:**
- Produces: `move-node` branch — implemented as an in-source remove-then-reinsert against a single mutable string, returning a whole-file replacement. Does **not** touch imports (a move never changes which components are used, only where their instances sit). Like `remove-node` (Task 5), this operates purely on `node.span` regardless of `kind` — an expression node's span already covers its entire `{...}` block, so moving one relocates it as a single opaque unit for free, satisfying spec §2.2's "movable/removable as a unit only" without a kind-specific branch. Not separately tested here since Task 5's equivalent `remove-node` test already proves the shared span-extraction mechanism is expression-safe.

- [ ] **Step 1: Write the failing tests**

Append a new `describe` block:

```typescript
describe("resolveComponentStructure — move-node", () => {
  let tmpDir;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "anglesite-cse5-"));
    mkdirSync(join(tmpDir, "src", "components"), { recursive: true });
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  function apply(resolution, before) {
    return before.slice(0, resolution.range.start) + resolution.replacement + before.slice(resolution.range.end);
  }

  it("reorders two siblings under the same parent", async () => {
    const src = `---\n---\n<article><h2>A</h2><h3>B</h3></article>\n`;
    writeFileSync(join(tmpDir, "src", "components", "Card.astro"), src);
    const baseVersion = fileVersion(src);
    const { byId, rootId } = await nodeIndex(src);
    const article = byId.get(byId.get(rootId).childIds[0]);
    const [h2, h3] = article.childIds.map((id) => byId.get(id));

    const edit = { op: "move-node", component: { path: "src/components/Card.astro", baseVersion, nodeId: h2.id, newParentId: article.id, newIndex: 1 } };
    const result = await resolveComponentStructure(tmpDir, edit);
    const next = apply(result, src);
    expect(next.indexOf("<h3>B</h3>")).toBeLessThan(next.indexOf("<h2>A</h2>"));

    const { ast } = await parse(next, { position: true });
    expect(ast).toBeDefined();
  });

  it("reparents a node into a different element", async () => {
    const src = `---\n---\n<article><h2>Title</h2></article><footer></footer>\n`;
    writeFileSync(join(tmpDir, "src", "components", "Card.astro"), src);
    const baseVersion = fileVersion(src);
    const { byId, rootId } = await nodeIndex(src);
    const [article, footer] = byId.get(rootId).childIds.map((id) => byId.get(id));
    const h2 = byId.get(article.childIds[0]);

    const edit = { op: "move-node", component: { path: "src/components/Card.astro", baseVersion, nodeId: h2.id, newParentId: footer.id, newIndex: 0 } };
    const result = await resolveComponentStructure(tmpDir, edit);
    const next = apply(result, src);
    expect(next).toContain("<footer><h2>Title</h2></footer>");
    expect(next).not.toContain("<article><h2>Title</h2></article>");
  });

  it("refuses invalid-input when moving a node into its own subtree", async () => {
    const src = `---\n---\n<article><section><h2>Title</h2></section></article>\n`;
    writeFileSync(join(tmpDir, "src", "components", "Card.astro"), src);
    const baseVersion = fileVersion(src);
    const { byId, rootId } = await nodeIndex(src);
    const article = byId.get(byId.get(rootId).childIds[0]);
    const section = byId.get(article.childIds[0]);

    const edit = { op: "move-node", component: { path: "src/components/Card.astro", baseVersion, nodeId: article.id, newParentId: section.id, newIndex: 0 } };
    const result = await resolveComponentStructure(tmpDir, edit);
    expect(result.refused).toBe(true);
    expect(result.reason).toBe("invalid-input");
  });

  it("refuses no-match when nodeId doesn't exist", async () => {
    const src = `---\n---\n<article></article>\n`;
    writeFileSync(join(tmpDir, "src", "components", "Card.astro"), src);
    const baseVersion = fileVersion(src);
    const { rootId } = await nodeIndex(src);
    const edit = { op: "move-node", component: { path: "src/components/Card.astro", baseVersion, nodeId: "n999", newParentId: rootId, newIndex: 0 } };
    const result = await resolveComponentStructure(tmpDir, edit);
    expect(result.refused).toBe(true);
    expect(result.reason).toBe("no-match");
  });
});
```

- [ ] **Step 2: Run to verify the new cases fail**

```bash
npm test -- tests/component-structure-edit.test.ts
```

Expected: FAIL on `move-node` cases.

- [ ] **Step 3: Implement the `move-node` branch**

Add to the `switch`:

```javascript
    case "move-node":
      return applyMoveNode(relPath, source, byId, component);
```

Add the implementation:

```javascript
function isDescendant(byId, ancestorId, nodeId) {
  const node = byId.get(nodeId);
  let cur = node?.parentId ?? null;
  while (cur !== null) {
    if (cur === ancestorId) return true;
    cur = byId.get(cur)?.parentId ?? null;
  }
  return false;
}

function applyMoveNode(file, source, byId, component) {
  const { nodeId, newParentId, newIndex } = component;
  if (typeof nodeId !== "string" || typeof newParentId !== "string" || typeof newIndex !== "number") {
    return refuse("invalid-input", "move-node requires component.nodeId, component.newParentId, and component.newIndex");
  }
  const node = byId.get(nodeId);
  const newParent = byId.get(newParentId);
  if (!node || !newParent) return refuse("no-match", "nodeId or newParentId not found — the file may have changed");
  if (node.parentId === null) return refuse("invalid-input", "cannot move the component's root");
  if (nodeId === newParentId || isDescendant(byId, nodeId, newParentId)) {
    return refuse("invalid-input", "cannot move a node into its own subtree");
  }
  if (node.span[0] == null || node.span[1] == null) {
    return refuse("no-match", "node has no movable span");
  }

  const nodeText = source.slice(node.span[0], node.span[1]);

  // Remove the node from its old position first (with the same whitespace/newline cleanup
  // as remove-node), tracking how the removal shifts any offset that comes after it.
  let removeStart = node.span[0];
  while (removeStart > 0 && (source[removeStart - 1] === " " || source[removeStart - 1] === "\t")) removeStart--;
  if (removeStart > 0 && source[removeStart - 1] === "\n") removeStart--;
  const removeEnd = node.span[1];
  const withoutNode = source.slice(0, removeStart) + source.slice(removeEnd);
  const shift = (offset) => (offset > removeEnd ? offset - (removeEnd - removeStart) : offset > removeStart ? removeStart : offset);

  const siblings = newParent.childIds.filter((id) => id !== nodeId).map((id) => byId.get(id)).filter((c) => c.span[0] != null);
  let insertAt;
  if (siblings.length === 0) {
    if (newParent.parentId === null) {
      insertAt = withoutNode.length;
    } else {
      const closeTag = `</${newParent.tag}>`;
      const parentEnd = shift(newParent.span[1]);
      const candidate = parentEnd - closeTag.length;
      insertAt = withoutNode.slice(candidate, parentEnd) === closeTag ? candidate : parentEnd;
    }
  } else {
    const clampedIndex = Math.max(0, Math.min(newIndex, siblings.length));
    insertAt = clampedIndex === siblings.length ? shift(siblings[siblings.length - 1].span[1]) : shift(siblings[clampedIndex].span[0]);
  }

  const rewritten = withoutNode.slice(0, insertAt) + nodeText + withoutNode.slice(insertAt);
  return { file, range: { start: 0, end: source.length }, replacement: rewritten };
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
npm test -- tests/component-structure-edit.test.ts
```

Expected: PASS, all cases including Tasks 4–6's.

- [ ] **Step 5: Commit**

```bash
git add server/component-structure-edit.mjs tests/component-structure-edit.test.ts
git commit -m "feat(mcp): add move-node (reorder/reparent) to the component-structure resolver"
```

### Task 8: Wire the dispatcher

**Files:**
- Modify: `server/patcher.mjs`
- Modify: `server/apply-edit-dispatcher.mjs`
- Create: `tests/apply-edit-dispatcher-component-structure.test.ts`

**Interfaces:**
- Consumes: `resolveComponentStructure` (Tasks 4–7), `COMPONENT_STRUCTURE_OPS`/`COMPONENT_OPS` (Task 3), `buildComponentModel` (existing).
- Produces: structure ops missing a `component` payload fail fast with `invalid-input`; successful structure edits piggyback `model`; a second `baseVersion` check runs after the dispatcher's own independent re-read (closing the same async-gap race slice 2 already closed for style ops).

- [ ] **Step 1: Write the failing test**

Create `tests/apply-edit-dispatcher-component-structure.test.ts`:

```typescript
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, mkdirSync, writeFileSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { parse } from "@astrojs/compiler";
import { applyEdit } from "../server/apply-edit-dispatcher.mjs";
import { buildTemplateNodeIndex } from "../server/component-node-index.mjs";
import { fileVersion } from "../server/file-version.mjs";

const CARD = `---\n---\n<article><h2>Title</h2></article>\n`;

function parseContent(response) {
  return JSON.parse(response.content[0].text);
}

async function nodeIndex(source) {
  const { ast } = await parse(source, { position: true });
  return buildTemplateNodeIndex(ast, source);
}

describe("applyEdit — component-structure ops", () => {
  let tmpDir;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "anglesite-aed2-"));
    mkdirSync(join(tmpDir, "src", "components"), { recursive: true });
    writeFileSync(join(tmpDir, "src", "components", "Card.astro"), CARD);
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("rejects a component-structure op with no component payload", async () => {
    const response = await applyEdit(tmpDir, { id: "1", path: "x", op: "insert-node", value: {} });
    expect(response.isError).toBe(true);
    expect(parseContent(response).reason).toBe("invalid-input");
  });

  it("applies insert-node and piggybacks a fresh model", async () => {
    const baseVersion = fileVersion(CARD);
    const { rootId } = await nodeIndex(CARD);

    const response = await applyEdit(tmpDir, {
      id: "1",
      path: "src/components/Card.astro",
      op: "insert-node",
      component: { path: "src/components/Card.astro", baseVersion, parentId: rootId, index: 1, node: { kind: "element", tag: "footer" } },
    });
    expect(response.isError).toBeFalsy();
    const body = parseContent(response);
    expect(body.type).toBe("anglesite:edit-applied");
    expect(body.model).toBeDefined();
    expect(body.model.template.children.some((c) => c.tag === "footer")).toBe(true);
  });

  it("surfaces stale as a failed reply", async () => {
    const response = await applyEdit(tmpDir, {
      id: "1",
      path: "src/components/Card.astro",
      op: "insert-node",
      component: { path: "src/components/Card.astro", baseVersion: "sha256:000000000000", parentId: "n0", index: 0, node: { kind: "element", tag: "p" } },
    });
    expect(response.isError).toBe(true);
    expect(parseContent(response).reason).toBe("stale");
  });

  it("re-checks staleness after the resolver's async gap, refusing a concurrent write race", async () => {
    const baseVersion = fileVersion(CARD);
    const { rootId } = await nodeIndex(CARD);

    const editPromise = applyEdit(tmpDir, {
      id: "1",
      path: "src/components/Card.astro",
      op: "insert-node",
      component: { path: "src/components/Card.astro", baseVersion, parentId: rootId, index: 1, node: { kind: "element", tag: "footer" } },
    });

    writeFileSync(join(tmpDir, "src", "components", "Card.astro"), CARD.replace("Title", "Renamed"));

    const response = await editPromise;
    expect(response.isError).toBe(true);
    expect(parseContent(response).reason).toBe("stale");

    const onDisk = readFileSync(join(tmpDir, "src", "components", "Card.astro"), "utf-8");
    expect(onDisk).toContain("Renamed");
  });
});
```

- [ ] **Step 2: Run to verify it fails**

```bash
npm test -- tests/apply-edit-dispatcher-component-structure.test.ts
```

Expected: FAIL — `insert-node` isn't dispatched yet, and `model` isn't piggybacked.

- [ ] **Step 3: Wire `patcher.mjs`**

Add the import and a dispatch branch ahead of the fallback resolver chain:

```javascript
import { resolveComponentStructure } from "./component-structure-edit.mjs";
import { COMPONENT_STRUCTURE_OPS } from "./apply-edit-schema.mjs";
```

```javascript
export async function resolve(projectRoot, edit) {
  if (edit.op === "edit-style") {
    return resolveStyle(projectRoot, edit);
  }
  if (COMPONENT_STYLE_OPS.has(edit.op)) {
    return resolveComponentStyle(projectRoot, edit);
  }
  if (COMPONENT_STRUCTURE_OPS.has(edit.op)) {
    return resolveComponentStructure(projectRoot, edit);
  }
  // ... existing fallback chain (resolveMdoc, resolveKeystatic, resolveAstro) unchanged
}
```

- [ ] **Step 4: Widen the dispatcher's component-op checks**

In `server/apply-edit-dispatcher.mjs`, change the import:

```javascript
import { createEditAppliedContent, createEditFailedContent, createEditPreviewContent, COMPONENT_OPS } from "./apply-edit-schema.mjs";
```

(replaces the existing `COMPONENT_STYLE_OPS` import with `COMPONENT_OPS`.)

Replace both existing `COMPONENT_STYLE_OPS.has(edit.op)` occurrences in `applyEdit` — the missing-payload guard and the model-piggyback condition — with `COMPONENT_OPS.has(edit.op)`. Also widen the second `baseVersion` re-check (currently gated the same way) from `COMPONENT_STYLE_OPS.has(edit.op)` to `COMPONENT_OPS.has(edit.op)`, since structure ops need the identical concurrent-write protection style ops already have.

- [ ] **Step 5: Run tests to verify they pass**

```bash
npm test -- tests/apply-edit-dispatcher-component-structure.test.ts
```

Expected: PASS, all 4 cases.

- [ ] **Step 6: Run the full plugin test suite to check for regressions**

```bash
npm test
```

Expected: all existing tests still pass, in particular `tests/apply-edit-dispatcher-component-style.test.ts` — the `COMPONENT_STYLE_OPS` → `COMPONENT_OPS` rename must not change style-op behavior (the union still contains every style op).

- [ ] **Step 7: Commit**

```bash
git add server/patcher.mjs server/apply-edit-dispatcher.mjs tests/apply-edit-dispatcher-component-structure.test.ts
git commit -m "feat(mcp): dispatch component-structure ops and widen the component-op checks"
```

### Task 9: MCP round-trip test + CHANGELOG

**Files:**
- Modify: `tests/mcp-server.test.ts`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Write the failing test**

In `tests/mcp-server.test.ts`, find the existing `get_component_model`/`apply_edit` stdio round-trip tests (added in slice 2) and add a sibling test reusing the same fixture-project setup and `client.callTool` helper:

```typescript
it("apply_edit insert-node round trip returns a piggybacked model", async () => {
  const modelResult = await client.callTool({ name: "get_component_model", arguments: { path: "src/components/Card.astro" } });
  const model = JSON.parse(modelResult.content[0].text);

  const editResult = await client.callTool({
    name: "apply_edit",
    arguments: {
      id: "rt-2",
      path: "src/components/Card.astro",
      op: "insert-node",
      component: { path: "src/components/Card.astro", baseVersion: model.version, parentId: model.template.id, index: model.template.children.length, node: { kind: "element", tag: "footer" } },
    },
  });
  const body = JSON.parse(editResult.content[0].text);
  expect(body.type).toBe("anglesite:edit-applied");
  expect(body.model.template.children.some((c) => c.tag === "footer")).toBe(true);
});
```

- [ ] **Step 2: Run to verify it passes**

```bash
npm test -- tests/mcp-server.test.ts
```

Expected: PASS (Tasks 3–8 already implement the server side; if it fails, re-check the fixture project this test file uses actually has a component under `src/components/Card.astro` with `<article>` markup — add one matching this test's expectations if not).

- [ ] **Step 3: Update `CHANGELOG.md`**

Add to the `## Unreleased` → `### Added` section (create it above the top version heading if the prior entry was already released):

```markdown
- `apply_edit` gains four component-structure ops — `insert-node`, `move-node`,
  `remove-node`, `set-attr` — with the same content-hash (`baseVersion`)
  staleness checking as the style ops. `insert-node` auto-adds a component
  import to frontmatter when needed; `remove-node` prunes now-unused imports.
  Successful structure edits piggyback a freshly rebuilt
  `get_component_model` result on the reply, same as the style ops.
```

- [ ] **Step 4: Commit**

```bash
git add tests/mcp-server.test.ts CHANGELOG.md
git commit -m "test(mcp): add apply_edit insert-node round trip; update changelog"
```

### Task 10: Full plugin regression pass

**Files:** none new.

- [ ] **Step 1: Run the entire plugin test suite**

```bash
npm test
```

Expected: 100% pass, no regressions from Tasks 1–9.

- [ ] **Step 2: Lint/typecheck if configured**

```bash
npm run lint --if-present
npm run typecheck --if-present
```

Expected: clean.

- [ ] **Step 3: Push the branch**

```bash
git push -u origin feat/component-structure-ops
```

### Task 11: Version bump, PR, checkpoint

**Files:**
- Modify: `package.json`, `.claude-plugin/plugin.json`, `template/package.json` (version bump — minor, per semver: new backward-compatible tool capability)
- Modify: `CHANGELOG.md` (move the `Unreleased` entry under the new version heading)

- [ ] **Step 1: Bump version across all three manifests**

```bash
npx tsx bin/release.ts minor
```

This bumps `package.json`, `.claude-plugin/plugin.json`, `template/package.json`, and `CLAUDE.md`'s version line — but **stop before it pushes the tag**: read `bin/release.ts`'s header comment first to confirm whether it tags/pushes automatically, and if so, run its commit-only portion manually instead (`npm version minor --no-git-tag-version` in each of the three manifest directories, or the equivalent flag `bin/release.ts` exposes) so this task only commits the version bump, not a tag push. Confirm the resulting version number (expected: `1.5.0`, since the current released version is `1.4.0`).

- [ ] **Step 2: Finalize the CHANGELOG heading**

Move Task 9's `## Unreleased` entry content under a new `## [1.5.0] — <today's date>` heading, matching the format of the existing `1.4.0`/`1.3.0` entries above it.

- [ ] **Step 3: Commit**

```bash
git add package.json package-lock.json .claude-plugin/plugin.json template/package.json CHANGELOG.md CLAUDE.md
git commit -m "chore: release v1.5.0"
git push
```

- [ ] **Step 4: Open the PR**

```bash
gh pr create --title "feat: component-structure write ops (Component Editor slice 3)" --body "Adds insert-node, move-node, remove-node, set-attr to apply_edit, with the same content-hash staleness checking as slice 2's style ops. insert-node auto-adds a component import when needed; remove-node prunes now-unused imports. Prerequisite for Anglesite-app's palette + drag-and-drop (issue #493)."
```

- [ ] **Step 5: Checkpoint — get user go-ahead before merging and tagging**

Stop here. Do not merge to `main` or push the `v1.5.0` tag without explicit confirmation. Once approved and merged, note the new version number — Part B's Task 21 bumps the app's `MIN_PLUGIN_VERSION` to it.

---

# Part B — App repo

All Part B tasks run in an app-repo worktree.

```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/project-style-guide-ai-4f8df2
xcodegen generate
ANGLESITE_PLUGIN_SRC=/Users/dwk/Developer/github.com/Anglesite/anglesite scripts/copy-plugin.sh
```

Re-run `copy-plugin.sh` after Part A's PR merges, so `Resources/plugin` picks up the new ops.

### Task 12: `EditMessage.Op` constants + `ComponentStructureEditBuilder`

**Files:**
- Modify: `Sources/AnglesiteCore/EditMessage.swift`
- Create: `Sources/AnglesiteCore/ComponentStructureEditBuilder.swift`
- Modify: `Tests/AnglesiteCoreTests/EditMessageTests.swift`
- Create: `Tests/AnglesiteCoreTests/ComponentStructureEditBuilderTests.swift`

**Interfaces:**
- Produces: `EditMessage.Op.insertNode/.moveNode/.removeNode/.setAttr` string constants (mirrors the existing `setStyleProperty` etc. block).
- Produces: `ComponentStructureEditBuilder.insertNode/.moveNode/.removeNode/.setAttr(...) → EditMessage`, mirroring `ComponentStyleEditBuilder`'s static-function shape exactly.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/AnglesiteCoreTests/EditMessageTests.swift` (find the existing test asserting `EditMessage.Op.setStyleProperty == "set-style-property"` and add siblings next to it):

```swift
@Test("New component-structure op constants match the plugin's op names")
func componentStructureOpConstants() {
    #expect(EditMessage.Op.insertNode == "insert-node")
    #expect(EditMessage.Op.moveNode == "move-node")
    #expect(EditMessage.Op.removeNode == "remove-node")
    #expect(EditMessage.Op.setAttr == "set-attr")
}
```

Create `Tests/AnglesiteCoreTests/ComponentStructureEditBuilderTests.swift`:

```swift
import Testing
@testable import AnglesiteCore

@Suite struct ComponentStructureEditBuilderTests {
    @Test("insertNode carries parentId, index, and node spec")
    func insertNodeShape() {
        let message = ComponentStructureEditBuilder.insertNode(
            id: "id-1",
            path: "src/components/Card.astro",
            baseVersion: "sha256:abc",
            parentId: "n0",
            index: 1,
            node: .element(tag: "p")
        )
        #expect(message.op == EditMessage.Op.insertNode)
        guard case .object(let obj)? = message.component else { Issue.record("expected object component payload"); return }
        #expect(obj["parentId"] == .string("n0"))
        #expect(obj["index"] == .int(1))
        guard case .object(let node)? = obj["node"] else { Issue.record("expected node object"); return }
        #expect(node["kind"] == .string("element"))
        #expect(node["tag"] == .string("p"))
    }

    @Test("insertNode component spec carries componentPath")
    func insertNodeComponentSpec() {
        let message = ComponentStructureEditBuilder.insertNode(
            id: "id-2",
            path: "src/components/Card.astro",
            baseVersion: "sha256:abc",
            parentId: "n0",
            index: 0,
            node: .component(tag: "Badge", componentPath: "src/components/Badge.astro")
        )
        guard case .object(let obj)? = message.component, case .object(let node)? = obj["node"] else {
            Issue.record("expected component node payload"); return
        }
        #expect(node["kind"] == .string("component"))
        #expect(node["componentPath"] == .string("src/components/Badge.astro"))
    }

    @Test("moveNode carries nodeId, newParentId, newIndex")
    func moveNodeShape() {
        let message = ComponentStructureEditBuilder.moveNode(
            id: "id-3", path: "src/components/Card.astro", baseVersion: "sha256:abc",
            nodeId: "n2", newParentId: "n0", newIndex: 1
        )
        guard case .object(let obj)? = message.component else { Issue.record("expected object component payload"); return }
        #expect(obj["nodeId"] == .string("n2"))
        #expect(obj["newParentId"] == .string("n0"))
        #expect(obj["newIndex"] == .int(1))
    }

    @Test("removeNode carries nodeId")
    func removeNodeShape() {
        let message = ComponentStructureEditBuilder.removeNode(id: "id-4", path: "src/components/Card.astro", baseVersion: "sha256:abc", nodeId: "n2")
        guard case .object(let obj)? = message.component else { Issue.record("expected object component payload"); return }
        #expect(obj["nodeId"] == .string("n2"))
    }

    @Test("setAttr with a value sets it")
    func setAttrValue() {
        let message = ComponentStructureEditBuilder.setAttr(id: "id-5", path: "src/components/Card.astro", baseVersion: "sha256:abc", nodeId: "n1", name: "class", value: "big")
        guard case .object(let obj)? = message.component else { Issue.record("expected object component payload"); return }
        #expect(obj["name"] == .string("class"))
        #expect(obj["value"] == .string("big"))
    }

    @Test("setAttr with nil value encodes explicit null (removal)")
    func setAttrRemoval() {
        let message = ComponentStructureEditBuilder.setAttr(id: "id-6", path: "src/components/Card.astro", baseVersion: "sha256:abc", nodeId: "n1", name: "class", value: nil)
        guard case .object(let obj)? = message.component else { Issue.record("expected object component payload"); return }
        #expect(obj["value"] == .null)
    }
}
```

(Confirm `JSONValue`'s exact case names — `.object`, `.string`, `.int`, `.null` — via `grep -n "enum JSONValue" -A 15 Sources/AnglesiteCore/*.swift` before writing this step for real; adjust case names if they differ.)

- [ ] **Step 2: Run to verify they fail**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ComponentStructureEditBuilderTests
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter EditMessageTests
```

Expected: FAIL — new symbols don't exist.

- [ ] **Step 3: Add the op constants**

In `Sources/AnglesiteCore/EditMessage.swift`, inside `EditMessage.Op`, add after the existing `setRuleSelector` constant:

```swift
        /// `"insert-node"` — Component Editor: insert a new element/component/slot node.
        /// Carries a `component` payload.
        public static let insertNode = "insert-node"
        /// `"move-node"` — Component Editor: reorder/reparent an existing node. Carries a
        /// `component` payload.
        public static let moveNode = "move-node"
        /// `"remove-node"` — Component Editor: delete a node (and prune now-unused imports).
        /// Carries a `component` payload.
        public static let removeNode = "remove-node"
        /// `"set-attr"` — Component Editor: set or remove (nil value) an attribute/prop at
        /// the use-site. Carries a `component` payload.
        public static let setAttr = "set-attr"
```

- [ ] **Step 4: Implement `ComponentStructureEditBuilder`**

Create `Sources/AnglesiteCore/ComponentStructureEditBuilder.swift`:

```swift
import Foundation

/// Builds the wire-format `EditMessage` payloads for the four Component Editor structure write
/// ops (`insert-node`, `move-node`, `remove-node`, `set-attr`). Pure and testable — no MCP/router
/// dependency, mirrors `ComponentStyleEditBuilder`'s shape exactly.
public enum ComponentStructureEditBuilder {
    /// New-node spec for `insertNode` — mirrors the plugin's `component.node` schema.
    public enum NodeSpec {
        case element(tag: String)
        case component(tag: String, componentPath: String)
        case slot(name: String? = nil)

        var jsonValue: JSONValue {
            switch self {
            case .element(let tag):
                return .object(["kind": .string("element"), "tag": .string(tag)])
            case .component(let tag, let componentPath):
                return .object(["kind": .string("component"), "tag": .string(tag), "componentPath": .string(componentPath)])
            case .slot(let name):
                var obj: [String: JSONValue] = ["kind": .string("slot")]
                if let name { obj["slotName"] = .string(name) }
                return .object(obj)
            }
        }
    }

    public static func insertNode(
        id: String,
        path: String,
        baseVersion: String,
        parentId: String,
        index: Int,
        node: NodeSpec
    ) -> EditMessage {
        EditMessage(
            id: id,
            path: path,
            selector: nil,
            op: EditMessage.Op.insertNode,
            component: .object([
                "path": .string(path),
                "baseVersion": .string(baseVersion),
                "parentId": .string(parentId),
                "index": .int(index),
                "node": node.jsonValue,
            ]),
            value: nil
        )
    }

    public static func moveNode(
        id: String,
        path: String,
        baseVersion: String,
        nodeId: String,
        newParentId: String,
        newIndex: Int
    ) -> EditMessage {
        EditMessage(
            id: id,
            path: path,
            selector: nil,
            op: EditMessage.Op.moveNode,
            component: .object([
                "path": .string(path),
                "baseVersion": .string(baseVersion),
                "nodeId": .string(nodeId),
                "newParentId": .string(newParentId),
                "newIndex": .int(newIndex),
            ]),
            value: nil
        )
    }

    public static func removeNode(
        id: String,
        path: String,
        baseVersion: String,
        nodeId: String
    ) -> EditMessage {
        EditMessage(
            id: id,
            path: path,
            selector: nil,
            op: EditMessage.Op.removeNode,
            component: .object([
                "path": .string(path),
                "baseVersion": .string(baseVersion),
                "nodeId": .string(nodeId),
            ]),
            value: nil
        )
    }

    /// `value: nil` removes the attribute (encodes as an explicit JSON `null`, distinct from
    /// omitting the field — the plugin schema treats `value === null` as "remove").
    public static func setAttr(
        id: String,
        path: String,
        baseVersion: String,
        nodeId: String,
        name: String,
        value: String?
    ) -> EditMessage {
        EditMessage(
            id: id,
            path: path,
            selector: nil,
            op: EditMessage.Op.setAttr,
            component: .object([
                "path": .string(path),
                "baseVersion": .string(baseVersion),
                "nodeId": .string(nodeId),
                "name": .string(name),
                "value": value.map(JSONValue.string) ?? .null,
            ]),
            value: nil
        )
    }
}
```

(Confirm `JSONValue`'s exact case names again here before finalizing — if `.int` doesn't exist and integers instead encode via `.number(Double)` or similar, adjust `index`/`newIndex`/`newParentId`'s encoding accordingly, and update Step 1's tests to match.)

- [ ] **Step 5: Run tests to verify they pass**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ComponentStructureEditBuilderTests
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter EditMessageTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/EditMessage.swift Sources/AnglesiteCore/ComponentStructureEditBuilder.swift Tests/AnglesiteCoreTests/EditMessageTests.swift Tests/AnglesiteCoreTests/ComponentStructureEditBuilderTests.swift
git commit -m "feat(core): add component-structure op constants and EditMessage builder"
```

### Task 13: `ComponentEditorModel` write methods

**Files:**
- Modify: `Sources/AnglesiteApp/ComponentEditorModel.swift`
- Create: `Tests/AnglesiteCoreTests/ComponentEditorModelStructureEditTests.swift` (or alongside wherever the existing style-edit model tests for `ComponentEditorModel` live — grep first: `grep -rln "ComponentEditorModel" Tests/`)

**Interfaces:**
- Produces: `ComponentEditorModel.insertNode(parentId:index:node:) async -> Bool`, `.moveNode(nodeId:newParentId:newIndex:) async -> Bool`, `.removeNode(nodeId:) async -> Bool`, `.setAttr(nodeId:name:value:) async -> Bool` — each builds the corresponding `EditMessage` via `ComponentStructureEditBuilder` and routes it through the **existing** `applyComponentStyleEdit(_:)` private method (it's already op-agnostic: it just applies whatever `EditMessage` it's given and reconciles `.applied`/`.failed(stale)`/`.failed(other)`; only its name is style-specific from when it was written in slice 2).

- [ ] **Step 1: Confirm the existing plumbing before adding call sites**

```bash
grep -n "private func applyComponentStyleEdit" -A 25 Sources/AnglesiteApp/ComponentEditorModel.swift
grep -rln "ComponentEditorModel" Tests/
```

Confirm the exact signature of `applyComponentStyleEdit(_ message: EditMessage) async -> Bool` (it should match what's shown in this plan's research above) before writing Step 2's tests against it.

- [ ] **Step 2: Write the failing tests**

Find the existing test file that constructs a `ComponentEditorModel` against a fake `EditRouter` for the style-write tests (from the `grep` above) and add a sibling file, or append to it if the existing one isn't style-specifically named. Create `Tests/AnglesiteCoreTests/ComponentEditorModelStructureEditTests.swift` (adjust the target — `AnglesiteApp` types typically can't be `@testable import`ed from `AnglesiteCoreTests`; if `ComponentEditorModel` lives in `AnglesiteApp`, this test file must live under a test target that can see `AnglesiteApp`, e.g. alongside the existing style-edit tests found by the grep above — mirror that target exactly):

```swift
import Testing
@testable import AnglesiteApp
@testable import AnglesiteCore

@Suite @MainActor struct ComponentEditorModelStructureEditTests {
    final class RecordingRouter: EditRouter {
        var lastMessage: EditMessage?
        var reply: EditReply
        init(reply: EditReply) { self.reply = reply }
        func apply(_ message: EditMessage) async -> EditReply {
            lastMessage = message
            return reply
        }
    }

    func makeModel(router: EditRouter) -> ComponentEditorModel {
        let context = ComponentEditorContext(baseURL: nil, modelClient: nil, sourceRoot: URL(fileURLWithPath: "/tmp/site"), editRouter: router)
        let file = FileRef(url: URL(fileURLWithPath: "/tmp/site/src/components/Card.astro"), group: .components, name: "Card.astro")
        return ComponentEditorModel(file: file, context: context)
    }

    @Test("insertNode sends the built EditMessage and applies success")
    func insertNodeApplies() async {
        let router = RecordingRouter(reply: EditReply(id: "x", status: .applied, message: nil))
        let model = makeModel(router: router)
        let applied = await model.insertNode(parentId: "n0", index: 0, node: .element(tag: "p"))
        #expect(applied)
        #expect(router.lastMessage?.op == EditMessage.Op.insertNode)
    }

    @Test("moveNode sends the built EditMessage")
    func moveNodeApplies() async {
        let router = RecordingRouter(reply: EditReply(id: "x", status: .applied, message: nil))
        let model = makeModel(router: router)
        let applied = await model.moveNode(nodeId: "n2", newParentId: "n0", newIndex: 1)
        #expect(applied)
        #expect(router.lastMessage?.op == EditMessage.Op.moveNode)
    }

    @Test("removeNode sends the built EditMessage")
    func removeNodeApplies() async {
        let router = RecordingRouter(reply: EditReply(id: "x", status: .applied, message: nil))
        let model = makeModel(router: router)
        let applied = await model.removeNode(nodeId: "n2")
        #expect(applied)
        #expect(router.lastMessage?.op == EditMessage.Op.removeNode)
    }

    @Test("setAttr sends the built EditMessage")
    func setAttrApplies() async {
        let router = RecordingRouter(reply: EditReply(id: "x", status: .applied, message: nil))
        let model = makeModel(router: router)
        let applied = await model.setAttr(nodeId: "n1", name: "class", value: "big")
        #expect(applied)
        #expect(router.lastMessage?.op == EditMessage.Op.setAttr)
    }

    @Test("a stale reply flips conflict, same as the style-write path")
    func staleFlipsConflict() async {
        let router = RecordingRouter(reply: EditReply(id: "x", status: .failed, message: "stale", reason: "stale"))
        let model = makeModel(router: router)
        let applied = await model.setAttr(nodeId: "n1", name: "class", value: "big")
        #expect(!applied)
        #expect(model.conflict)
    }
}
```

- [ ] **Step 3: Run to verify they fail**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ComponentEditorModelStructureEditTests
```

Expected: FAIL — the four methods don't exist yet.

- [ ] **Step 4: Add the write methods**

In `Sources/AnglesiteApp/ComponentEditorModel.swift`, add after the existing `addStyleRule(...)` method (before `ruleSpan(atIndex:)`):

```swift
    // MARK: - Structure writes

    /// Insert a new node as the child at `index` under `parentId` (the fragment root's id for
    /// a top-level insert). Returns whether the write actually applied.
    @discardableResult
    func insertNode(parentId: String, index: Int, node: ComponentStructureEditBuilder.NodeSpec) async -> Bool {
        await applyComponentStyleEdit(
            ComponentStructureEditBuilder.insertNode(
                id: UUID().uuidString,
                path: relativePath,
                baseVersion: model?.version ?? "",
                parentId: parentId,
                index: index,
                node: node
            )
        )
    }

    /// Reorder/reparent an existing node. Returns whether the write actually applied.
    @discardableResult
    func moveNode(nodeId: String, newParentId: String, newIndex: Int) async -> Bool {
        await applyComponentStyleEdit(
            ComponentStructureEditBuilder.moveNode(
                id: UUID().uuidString,
                path: relativePath,
                baseVersion: model?.version ?? "",
                nodeId: nodeId,
                newParentId: newParentId,
                newIndex: newIndex
            )
        )
    }

    /// Delete a node (the plugin prunes any now-unused component imports). Returns whether the
    /// write actually applied.
    @discardableResult
    func removeNode(nodeId: String) async -> Bool {
        await applyComponentStyleEdit(
            ComponentStructureEditBuilder.removeNode(
                id: UUID().uuidString,
                path: relativePath,
                baseVersion: model?.version ?? "",
                nodeId: nodeId
            )
        )
    }

    /// Set (`value` non-nil) or remove (`value == nil`) an attribute/prop at the use-site.
    /// Returns whether the write actually applied.
    @discardableResult
    func setAttr(nodeId: String, name: String, value: String?) async -> Bool {
        await applyComponentStyleEdit(
            ComponentStructureEditBuilder.setAttr(
                id: UUID().uuidString,
                path: relativePath,
                baseVersion: model?.version ?? "",
                nodeId: nodeId,
                name: name,
                value: value
            )
        )
    }
```

Update `applyComponentStyleEdit`'s doc comment to note it's shared by both style and structure writes (one-line addition, not a rename — a rename would touch every existing call site for no behavioral gain and bloat this task's diff).

- [ ] **Step 5: Run tests to verify they pass**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ComponentEditorModelStructureEditTests
```

Expected: PASS, all 5 cases.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteApp/ComponentEditorModel.swift Tests/AnglesiteCoreTests/ComponentEditorModelStructureEditTests.swift
git commit -m "feat(app): add insertNode/moveNode/removeNode/setAttr to ComponentEditorModel"
```

### Task 14: `ComponentPalette` model

**Files:**
- Create: `Sources/AnglesiteCore/ComponentPalette.swift`
- Create: `Tests/AnglesiteCoreTests/ComponentPaletteTests.swift`

**Interfaces:**
- Produces: `ComponentPalette.Item` (`{ id: String, label: String, kind: ComponentStructureEditBuilder.NodeSpec, systemImage: String }`) and `ComponentPalette.items(projectComponents: [FileRef]) -> [Item]` — curated HTML elements + `<slot>` + one item per project component (from `SiteFileTree`'s `.components` group, name-sorted, excluding the component currently being edited).

- [ ] **Step 1: Write the failing test**

Create `Tests/AnglesiteCoreTests/ComponentPaletteTests.swift`:

```swift
import Testing
@testable import AnglesiteCore

@Suite struct ComponentPaletteTests {
    @Test("curated HTML elements are present")
    func curatedElements() {
        let items = ComponentPalette.items(projectComponents: [], excluding: nil)
        let tags = items.compactMap { item -> String? in
            if case .element(let tag) = item.kind { return tag }
            return nil
        }
        #expect(tags.contains("h1"))
        #expect(tags.contains("p"))
        #expect(tags.contains("img"))
        #expect(tags.contains("a"))
        #expect(tags.contains("div"))
        #expect(tags.contains("section"))
        #expect(tags.contains("ul"))
    }

    @Test("slot is present")
    func slotItem() {
        let items = ComponentPalette.items(projectComponents: [], excluding: nil)
        #expect(items.contains { if case .slot = $0.kind { return true }; return false })
    }

    @Test("project components become component items, name-sorted")
    func projectComponents() {
        let badge = FileRef(url: URL(fileURLWithPath: "/site/src/components/Badge.astro"), group: .components, name: "Badge.astro")
        let card = FileRef(url: URL(fileURLWithPath: "/site/src/components/Card.astro"), group: .components, name: "Card.astro")
        let items = ComponentPalette.items(projectComponents: [card, badge], excluding: nil)
        let componentItems = items.compactMap { item -> (String, String)? in
            if case .component(let tag, let path) = item.kind { return (tag, path) }
            return nil
        }
        #expect(componentItems.map(\.0) == ["Badge", "Card"])
        #expect(componentItems.first?.1.hasSuffix("Badge.astro") == true)
    }

    @Test("the component currently being edited is excluded from its own palette")
    func excludesSelf() {
        let badge = FileRef(url: URL(fileURLWithPath: "/site/src/components/Badge.astro"), group: .components, name: "Badge.astro")
        let card = FileRef(url: URL(fileURLWithPath: "/site/src/components/Card.astro"), group: .components, name: "Card.astro")
        let items = ComponentPalette.items(projectComponents: [card, badge], excluding: card)
        let names = items.compactMap { item -> String? in
            if case .component(let tag, _) = item.kind { return tag }
            return nil
        }
        #expect(names == ["Badge"])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ComponentPaletteTests
```

Expected: FAIL — module doesn't exist.

- [ ] **Step 3: Implement `Sources/AnglesiteCore/ComponentPalette.swift`**

```swift
import Foundation

/// Palette contents for the Component Editor's outline pane (spec §4.1): curated HTML
/// elements, `<slot>`, and the site's own project components. Pure/testable — no SwiftUI.
public enum ComponentPalette {
    public struct Item: Sendable, Equatable, Identifiable {
        public let id: String
        public let label: String
        public let kind: ComponentStructureEditBuilder.NodeSpec
        public let systemImage: String

        public init(id: String, label: String, kind: ComponentStructureEditBuilder.NodeSpec, systemImage: String) {
            self.id = id
            self.label = label
            self.kind = kind
            self.systemImage = systemImage
        }
    }

    /// Curated set, deliberately small: common structural/text/media elements, not the full
    /// HTML vocabulary. Order matches how they're grouped in the outline (headings, text,
    /// media, links/lists, layout).
    private static let curated: [(tag: String, label: String, systemImage: String)] = [
        ("h1", "Heading 1", "textformat.size.larger"),
        ("h2", "Heading 2", "textformat.size.larger"),
        ("h3", "Heading 3", "textformat.size"),
        ("p", "Paragraph", "text.alignleft"),
        ("img", "Image", "photo"),
        ("a", "Link", "link"),
        ("ul", "List", "list.bullet"),
        ("section", "Section", "square.split.bottomrightquarter"),
        ("div", "Div", "square.dashed"),
    ]

    public static func items(projectComponents: [FileRef], excluding current: FileRef?) -> [Item] {
        var result = curated.map { Item(id: "element:\($0.tag)", label: $0.label, kind: .element(tag: $0.tag), systemImage: $0.systemImage) }
        result.append(Item(id: "slot", label: "Slot", kind: .slot(), systemImage: "tray"))

        let components = projectComponents
            .filter { $0.id != current?.id }
            .sorted { $0.name < $1.name }
        for component in components {
            let tag = String(component.name.dropLast(".astro".count))
            result.append(Item(id: "component:\(component.id)", label: tag, kind: .component(tag: tag, componentPath: componentPath(for: component)), systemImage: "puzzlepiece.extension"))
        }
        return result
    }

    /// Best-effort project-relative path derivation for use as `NodeSpec.componentPath` — the
    /// palette only has the component's absolute `FileRef.url`; the plugin resolves the actual
    /// import specifier relative to the *edited* component's own path, so an approximate
    /// project-relative path (from the last `src/` segment onward) is sufficient here. Falls
    /// back to the full path if `src/` isn't found (defensive; every project component's URL
    /// contains `src/components/` or `src/layouts/` by construction — see `SiteFileTree`).
    private static func componentPath(for file: FileRef) -> String {
        let full = file.url.path(percentEncoded: false)
        if let range = full.range(of: "src/") {
            return String(full[range.lowerBound...])
        }
        return full
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ComponentPaletteTests
```

Expected: PASS, all 4 cases.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/ComponentPalette.swift Tests/AnglesiteCoreTests/ComponentPaletteTests.swift
git commit -m "feat(core): add ComponentPalette — curated elements + project components + slot"
```

### Task 15: Sealed-instance outline filtering + drag payload types

**Files:**
- Modify: `Sources/AnglesiteCore/ComponentOutline.swift`
- Modify: `Tests/AnglesiteCoreTests/ComponentOutlineTests.swift`

**Interfaces:**
- Produces: `ComponentOutline.rows(from:)` no longer descends into a `kind == .component` node's children (sealed instances — spec §4.1). A new `ComponentOutline.Row.isSealed: Bool` flags such rows so the view can render a "contains hidden content" affordance without a disclosure triangle.
- Produces: `ComponentDragItem` (`Transferable`, `Codable`) — `.existingNode(fileID: String, nodeID: String)` for outline-row drags; `PaletteDragPayload` (`Transferable`, `Codable`) — wraps a `ComponentPalette.Item`'s `kind` + `label` for palette-row drags. Both live in `ComponentOutline.swift` since they're outline/palette-adjacent, not `ComponentModel`-adjacent.

- [ ] **Step 1: Confirm current behavior, then write the failing tests**

```bash
grep -n "static func rows" -A 10 Sources/AnglesiteCore/ComponentOutline.swift
```

Add to `Tests/AnglesiteCoreTests/ComponentOutlineTests.swift` (find the existing `@Suite`/`describe`-equivalent and add sibling `@Test`s):

```swift
@Test("a component-instance node's children are not expanded into rows")
func sealedInstanceHidesChildren() {
    let slotFill = ComponentModel.Node(id: "n3", kind: .text, tag: nil, attrs: [], span: .init(start: nil, end: nil), loc: nil, text: "fill", children: [])
    let badge = ComponentModel.Node(id: "n2", kind: .component, tag: "Badge", attrs: [], span: .init(start: nil, end: nil), loc: nil, text: nil, children: [slotFill])
    let root = ComponentModel.Node(id: "n0", kind: .fragment, tag: nil, attrs: [], span: .init(start: nil, end: nil), loc: nil, text: nil, children: [badge])

    let rows = ComponentOutline.rows(from: root)
    #expect(rows.map(\.node.id) == ["n2"]) // n3 (the slot-fill text) never appears as a row
    #expect(rows.first?.isSealed == true)
}

@Test("a plain element's children still expand normally")
func plainElementExpands() {
    let child = ComponentModel.Node(id: "n2", kind: .text, tag: nil, attrs: [], span: .init(start: nil, end: nil), loc: nil, text: "hi", children: [])
    let article = ComponentModel.Node(id: "n1", kind: .element, tag: "article", attrs: [], span: .init(start: nil, end: nil), loc: nil, text: nil, children: [child])
    let root = ComponentModel.Node(id: "n0", kind: .fragment, tag: nil, attrs: [], span: .init(start: nil, end: nil), loc: nil, text: nil, children: [article])

    let rows = ComponentOutline.rows(from: root)
    #expect(rows.map(\.node.id) == ["n1", "n2"])
    #expect(rows.first?.isSealed == false)
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ComponentOutlineTests
```

Expected: FAIL — `isSealed` doesn't exist, and component children currently DO expand.

- [ ] **Step 3: Update `ComponentOutline.rows(from:)`**

In `Sources/AnglesiteCore/ComponentOutline.swift`, change `Row` and `rows(from:)`:

```swift
    public struct Row: Sendable, Equatable, Identifiable {
        public let node: ComponentModel.Node
        public let depth: Int
        /// True for a `kind == .component` node — its children are real markup (slot-fill
        /// content authored at the use site), but the outline treats the instance as opaque
        /// (spec §4.1): configure it via its attrs/props, or double-click to edit the
        /// component's own definition.
        public let isSealed: Bool
        public var id: String { node.id }

        public init(node: ComponentModel.Node, depth: Int, isSealed: Bool = false) {
            self.node = node
            self.depth = depth
            self.isSealed = isSealed
        }
    }

    public static func rows(from root: ComponentModel.Node) -> [Row] {
        var rows: [Row] = []
        func visit(_ node: ComponentModel.Node, depth: Int) {
            let sealed = node.kind == .component
            rows.append(Row(node: node, depth: depth, isSealed: sealed))
            guard !sealed else { return }
            for child in node.children { visit(child, depth: depth + 1) }
        }
        let topLevel = root.kind == .fragment ? root.children : [root]
        for node in topLevel { visit(node, depth: 0) }
        return rows
    }
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ComponentOutlineTests
```

Expected: PASS.

- [ ] **Step 5: Add the drag payload types (no test — pure data types, exercised by Task 16/17's UI tests instead)**

Append to `Sources/AnglesiteCore/ComponentOutline.swift`:

```swift
import CoreTransferable

/// Drag payload for an outline row being reordered/reparented (Task 16) — identifies the
/// component file being edited (guards against a cross-editor drop landing on the wrong
/// component's tree) and the node being moved.
public struct ComponentDragItem: Codable, Sendable, Transferable {
    public let fileID: String
    public let nodeID: String

    public init(fileID: String, nodeID: String) {
        self.fileID = fileID
        self.nodeID = nodeID
    }

    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .anglesiteComponentDragItem)
    }
}

/// Drag payload for a palette row being dropped into the outline or onto the canvas (Task 17/18).
public struct PaletteDragPayload: Codable, Sendable, Transferable {
    public let label: String
    public let kind: ComponentStructureEditBuilder.NodeSpec

    public init(label: String, kind: ComponentStructureEditBuilder.NodeSpec) {
        self.label = label
        self.kind = kind
    }

    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .anglesitePaletteDragPayload)
    }
}
```

`ComponentStructureEditBuilder.NodeSpec` needs `Codable` conformance for this — add it to the enum declaration in `Sources/AnglesiteCore/ComponentStructureEditBuilder.swift` from Task 12 (`public enum NodeSpec: Codable { ... }`; the associated-value cases already Codable-conform automatically since `String` is `Codable`).

Declare the two custom `UTType`s. Add to `Sources/AnglesiteCore/ComponentOutline.swift` (or a shared `UTType+Anglesite.swift` if one already exists — `grep -rn "extension UTType" Sources/AnglesiteCore/` first and add alongside any existing custom-UTType extension rather than creating a duplicate one):

```swift
import UniformTypeIdentifiers

extension UTType {
    static let anglesiteComponentDragItem = UTType(exportedAs: "io.dwk.anglesite.component-drag-item")
    static let anglesitePaletteDragPayload = UTType(exportedAs: "io.dwk.anglesite.palette-drag-payload")
}
```

If an existing `UTType+Anglesite.swift`-style file already declares custom exported types (check the app's `Info.plist`/entitlements for an `UTExportedTypeDeclarations` array, since `exportedAs:` types need a matching Info.plist entry to resolve at runtime), add these two alongside the existing ones in both the Swift extension and the Info.plist array — search `grep -rn "UTExportedTypeDeclarations" -A 20 **/*.plist` (or `Anglesite.entitlements`/`Info.plist` under `Sources/AnglesiteApp/Resources`) to find the right file before adding.

- [ ] **Step 6: Full core test pass**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter AnglesiteCoreTests
```

Expected: PASS, no regressions.

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteCore/ComponentOutline.swift Sources/AnglesiteCore/ComponentStructureEditBuilder.swift Tests/AnglesiteCoreTests/ComponentOutlineTests.swift
git commit -m "feat(core): seal component-instance outline rows; add drag payload Transferables"
```

### Task 16: Outline drag-reorder/reparent + palette pane + palette→outline drop

**Files:**
- Modify: `Sources/AnglesiteApp/ComponentEditorView.swift`

**Interfaces:**
- Produces: the outline `List` gains `.draggable`/`.dropDestination` — dropping an existing outline row onto another row's top half inserts before it (same parent), bottom half inserts after it (same parent), and dropping onto the row's icon/label area (the middle) reparents as its last child. Dropping a `PaletteDragPayload` anywhere on a row inserts a new node the same way. A palette pane renders below the outline (spec §4.1 "Palette below the tree"), its rows draggable.

This task is UI-only (`NSViewRepresentable`-free SwiftUI, uses the app's existing `ComponentEditorModel.insertNode`/`.moveNode` from Task 13 and `ComponentPalette.items` from Task 14) — no new Swift Testing coverage is added here (the app target's UI code isn't hosted-testable per this repo's CI constraint; the underlying `insertNode`/`moveNode` calls are already tested at the model layer in Task 13). Verify manually per Task 20's smoke pass instead.

- [ ] **Step 1: Read the current outline implementation**

```bash
grep -n "private func outline" -A 20 Sources/AnglesiteApp/ComponentEditorView.swift
```

- [ ] **Step 2: Replace the outline `List` with drag/drop-enabled rows**

In `Sources/AnglesiteApp/ComponentEditorView.swift`, replace the `outline(_:)` method body:

```swift
    private enum DropZone { case before, into, after }

    private func outline(_ model: ComponentEditorModel) -> some View {
        VStack(spacing: 0) {
            List(model.outlineRows, selection: Binding(
                get: { model.selectedNodeID },
                set: { model.selectedNodeID = $0 }
            )) { row in
                outlineRow(model, row: row)
                    .tag(row.node.id)
            }
            .listStyle(.sidebar)
            Divider()
            paletteView(model)
                .frame(height: 160)
        }
    }

    private func outlineRow(_ model: ComponentEditorModel, row: ComponentOutline.Row) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon(for: row.node.kind))
                .foregroundStyle(.secondary)
            Text(label(for: row.node))
            if row.isSealed {
                Spacer()
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.tertiary)
                    .help("Contains slot-fill content — double-click to edit \(row.node.tag ?? "this component")")
            }
        }
        .padding(.leading, CGFloat(row.depth) * 14)
        .contentShape(Rectangle())
        .draggable(ComponentDragItem(fileID: model.relativePath, nodeID: row.node.id))
        .dropDestination(for: ComponentDragItem.self) { items, location in
            guard let item = items.first, item.fileID == model.relativePath, item.nodeID != row.node.id else { return false }
            Task { await performMove(model, draggedNodeID: item.nodeID, targetRow: row, location: location) }
            return true
        }
        .dropDestination(for: PaletteDragPayload.self) { items, location in
            guard let item = items.first else { return false }
            Task { await performInsert(model, payload: item, targetRow: row, location: location) }
            return true
        }
        .onTapGesture(count: 2) {
            guard row.isSealed else { return }
            openSealedComponent(model, row: row)
        }
    }

    /// Top third of the row = insert before (same parent as the target); bottom third =
    /// insert after (same parent); middle third = reparent as the target's last child.
    /// `location` is row-local per SwiftUI's `dropDestination` contract; row height isn't
    /// known exactly here, so this uses a fixed 22pt reference band (the sidebar row's
    /// approximate rendered height) rather than a measured GeometryReader — acceptable
    /// imprecision for a coarse three-way split.
    private func dropZone(at location: CGPoint) -> DropZone {
        let rowHeight: CGFloat = 22
        if location.y < rowHeight / 3 { return .before }
        if location.y > rowHeight * 2 / 3 { return .after }
        return .into
    }

    private func performMove(_ model: ComponentEditorModel, draggedNodeID: String, targetRow: ComponentOutline.Row, location: CGPoint) async {
        guard let dragged = model.outlineRows.first(where: { $0.node.id == draggedNodeID }) else { return }
        switch dropZone(at: location) {
        case .into:
            let targetChildCount = targetRow.node.children.count
            await model.moveNode(nodeId: dragged.node.id, newParentId: targetRow.node.id, newIndex: targetChildCount)
        case .before, .after:
            guard let parentID = parentID(of: targetRow.node.id, in: model), let siblingIndex = childIndex(of: targetRow.node.id, underParent: parentID, in: model) else { return }
            let newIndex = dropZone(at: location) == .before ? siblingIndex : siblingIndex + 1
            await model.moveNode(nodeId: dragged.node.id, newParentId: parentID, newIndex: newIndex)
        }
    }

    private func performInsert(_ model: ComponentEditorModel, payload: PaletteDragPayload, targetRow: ComponentOutline.Row, location: CGPoint) async {
        switch dropZone(at: location) {
        case .into:
            await model.insertNode(parentId: targetRow.node.id, index: targetRow.node.children.count, node: payload.kind)
        case .before, .after:
            guard let parentID = parentID(of: targetRow.node.id, in: model), let siblingIndex = childIndex(of: targetRow.node.id, underParent: parentID, in: model) else { return }
            let index = dropZone(at: location) == .before ? siblingIndex : siblingIndex + 1
            await model.insertNode(parentId: parentID, index: index, node: payload.kind)
        }
    }

    /// Finds `nodeID`'s parent id by walking `model.model?.template` — the outline's flat `Row`
    /// list doesn't carry parent links (per `ComponentOutline.Row`'s shape), so this walks the
    /// tree directly. Returns the synthetic fragment root's id for a top-level node.
    private func parentID(of nodeID: String, in model: ComponentEditorModel) -> String? {
        guard let root = model.model?.template else { return nil }
        func search(_ node: ComponentModel.Node) -> String? {
            if node.children.contains(where: { $0.id == nodeID }) { return node.id }
            for child in node.children {
                if let found = search(child) { return found }
            }
            return nil
        }
        return search(root)
    }

    private func childIndex(of nodeID: String, underParent parentID: String, in model: ComponentEditorModel) -> Int? {
        guard let root = model.model?.template else { return nil }
        func find(_ node: ComponentModel.Node) -> ComponentModel.Node? {
            if node.id == parentID { return node }
            for child in node.children {
                if let found = find(child) { return found }
            }
            return nil
        }
        guard let parent = find(root) else { return nil }
        return parent.children.firstIndex { $0.id == nodeID }
    }

    private func openSealedComponent(_ model: ComponentEditorModel, row: ComponentOutline.Row) {
        model.openReferencedComponent(tag: row.node.tag)
    }

    private func paletteView(_ model: ComponentEditorModel) -> some View {
        let items = ComponentPalette.items(projectComponents: model.projectComponents, excluding: model.file)
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: 8) {
                ForEach(items) { item in
                    VStack(spacing: 2) {
                        Image(systemName: item.systemImage)
                        Text(item.label).font(.caption2).lineLimit(1)
                    }
                    .frame(width: 84, height: 44)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    .draggable(PaletteDragPayload(label: item.label, kind: item.kind))
                }
            }
            .padding(8)
        }
    }
```

`.tag` on the row's outer view (previously applied via `.tag(row.node.id)` inside `List(..., selection:)`'s trailing closure) still needs to stay on the `List`'s row-building closure return value — confirm the `.tag(row.node.id)` call chained after `outlineRow(model, row: row)` in the `List` initializer above is syntactically valid (it modifies the row view, same as the original code); if SwiftUI's type-checker rejects chaining `.tag` after a function call returning `some View`, wrap it as `outlineRow(model, row: row).tag(row.node.id)` explicitly (already written that way above — no change needed, just confirming during implementation).

- [ ] **Step 3: Add `ComponentEditorModel.projectComponents` and `.openReferencedComponent(tag:)`**

Task 14/16 reference `model.projectComponents` and `model.openReferencedComponent(tag:)`, neither of which exist yet. Add to `Sources/AnglesiteApp/ComponentEditorModel.swift`:

```swift
    /// Sibling project components for the palette — scanned once per `load()`, not per render.
    private(set) var projectComponents: [FileRef] = []
```

In `load()`, after the existing `knobValues` assignment, add:

```swift
        projectComponents = SiteFileTree.scan(siteRoot: context.sourceRoot)[.components] ?? []
```

(`SiteFileTree.scan` takes a site *root*, not the `Source/` dir directly — confirm via `grep -n "static func scan" -A 5 Sources/AnglesiteCore/SiteFileTree.swift`; if `context.sourceRoot` in `ComponentEditorContext` is already the `Source/` directory rather than the package root, pass it through `SiteFileTree.layout`'s inverse or adjust — read the exact `ComponentEditorContext.sourceRoot` doc comment and how it's constructed at the `SiteWindow` call site first, since `SiteFileTree.scan` internally calls `SiteFileTree.layout(for:)` expecting a package/project root.)

For `openReferencedComponent(tag:)`, this needs a way to call back out to `SiteWindowModel.openFile(_:)`. Add a callback to `ComponentEditorContext`:

```swift
struct ComponentEditorContext {
    let baseURL: URL?
    let modelClient: ComponentModelClient?
    let sourceRoot: URL
    let editRouter: EditRouter?
    /// Opens a different file in the main pane — used to implement "double-click a sealed
    /// component instance to edit its own definition" (spec §4.1). `nil` in
    /// tests/previews that don't need navigation.
    var onOpenFile: ((FileRef) -> Void)? = nil
}
```

And in `ComponentEditorModel`:

```swift
    /// Resolves `tag` (a component instance's tag name, e.g. "Badge") against `projectComponents`
    /// and asks the host to open it. No-op if the tag can't be resolved or navigation isn't wired.
    func openReferencedComponent(tag: String?) {
        guard let tag, let match = projectComponents.first(where: { $0.name == "\(tag).astro" }) else { return }
        context.onOpenFile?(match)
    }
```

Find where `ComponentEditorContext` is actually constructed (`grep -rn "ComponentEditorContext(" Sources/AnglesiteApp/`) and wire `onOpenFile: { file in siteWindowModel.openFile(file) }` (or whatever the local variable is named at that call site) alongside the existing `editRouter:`/`modelClient:` arguments — read that call site first and match its exact style before editing.

- [ ] **Step 4: Build and fix type errors**

```bash
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -80
```

Expected: eventually clean (iterate on any signature mismatches this step's speculative code introduces — `.draggable`/`.dropDestination` availability requires macOS 14+, already satisfied by this project's macOS 27 floor).

- [ ] **Step 5: Full core + app test pass**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .
```

Expected: PASS, no regressions.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteApp/ComponentEditorView.swift Sources/AnglesiteApp/ComponentEditorModel.swift
git commit -m "feat(app): outline drag-reorder/reparent, palette pane, palette-to-outline drop"
```

### Task 17: Canvas drop-target overlay support

**Files:**
- Modify: `JS/edit-overlay/src/component-canvas.ts`
- Modify: `JS/edit-overlay/test/component-canvas.test.ts`
- Modify: `Sources/AnglesiteCore/ComponentCanvasMessages.swift`
- Modify: `Tests/AnglesiteCoreTests/ComponentCanvasMessagesTests.swift`

**Interfaces:**
- Produces: `window.anglesiteCanvas.dropTargetAt(x, y) → { file, line, column, zone: "before"|"after"|"into" } | null` — a synchronous JS function the Swift side calls via `evaluateJavaScript` during a canvas drag, returning the nearest droppable element's source location plus which side of it the point falls on (reusing `findByLoc`'s existing line-matching approach, generalized to also work by point instead of by stamped loc lookup).

- [ ] **Step 1: Write the failing overlay test**

Add to `JS/edit-overlay/test/component-canvas.test.ts` (find the existing `describe("installComponentCanvas"...)`-equivalent block and add sibling `it`s in the same file, reusing whatever DOM-fixture helper the existing selection tests already use):

```typescript
describe("dropTargetAt", () => {
  it("resolves the element under a point and reports zone=into for its middle band", () => {
    document.body.innerHTML = `<article data-astro-source-file="/src/components/Card.astro" data-astro-source-loc="1:1" style="position:absolute;left:0;top:0;width:100px;height:90px;"></article>`;
    installComponentCanvas();
    const target = (window as any).anglesiteCanvas.dropTargetAt(50, 45);
    expect(target).toEqual({ file: "/src/components/Card.astro", line: 1, column: 1, zone: "into" });
  });

  it("reports zone=before near the top edge and zone=after near the bottom edge", () => {
    document.body.innerHTML = `<article data-astro-source-file="/src/components/Card.astro" data-astro-source-loc="1:1" style="position:absolute;left:0;top:0;width:100px;height:90px;"></article>`;
    installComponentCanvas();
    expect((window as any).anglesiteCanvas.dropTargetAt(50, 5).zone).toBe("before");
    expect((window as any).anglesiteCanvas.dropTargetAt(50, 85).zone).toBe("after");
  });

  it("returns null when no annotated ancestor exists at the point", () => {
    document.body.innerHTML = `<div style="position:absolute;left:0;top:0;width:10px;height:10px;"></div>`;
    installComponentCanvas();
    expect((window as any).anglesiteCanvas.dropTargetAt(500, 500)).toBeNull();
  });
});
```

(Confirm the exact DOM/jsdom test setup pattern — e.g. whether `location.pathname` needs stubbing to satisfy `isHarnessPage()` before `installComponentCanvas()` no-ops — by reading the existing `describe("installComponentCanvas"...)` tests' `beforeEach` in this same file before writing this step for real.)

- [ ] **Step 2: Run to verify it fails**

```bash
cd JS/edit-overlay && npm test -- component-canvas.test.ts
```

Expected: FAIL — `dropTargetAt` doesn't exist.

- [ ] **Step 3: Implement `dropTargetAt` in `component-canvas.ts`**

Add near `findByLoc`:

```typescript
export interface DropTarget extends SourceLoc {
  zone: "before" | "after" | "into";
}

/**
 * Nearest droppable element at a canvas-local point, plus which third of its bounding box the
 * point falls in — top third = "before" (insert as a preceding sibling), bottom third =
 * "after" (following sibling), middle third = "into" (append as the last child). Used during
 * a native drag-over to drive drop-target highlighting and, on drop, to resolve the insertion
 * point for a palette→canvas insert-node.
 */
function dropTargetAt(x: number, y: number): DropTarget | null {
  const el = document.elementFromPoint(x, y);
  if (!el) return null;
  const loc = sourceLoc(el);
  if (!loc) return null;
  const rect = (sourceLocElement(el) ?? el).getBoundingClientRect();
  const relativeY = y - rect.top;
  const zone: DropTarget["zone"] = relativeY < rect.height / 3 ? "before" : relativeY > (rect.height * 2) / 3 ? "after" : "into";
  return { ...loc, zone };
}

/** Walks up from `el` to the nearest ancestor (inclusive) actually carrying the
 *  `data-astro-source-loc` attribute `sourceLoc` resolved from — needed because `sourceLoc`
 *  itself only returns the loc value, not which element it was found on, and drop-zone
 *  geometry must be measured against THAT element's box, not the original event target's. */
function sourceLocElement(el: Element): Element | null {
  let node: Element | null = el;
  while (node && node !== document.body) {
    if (node.hasAttribute("data-astro-source-loc")) return node;
    node = node.parentElement;
  }
  return null;
}
```

Register it on `window.anglesiteCanvas` inside `installComponentCanvas()`, alongside the existing `highlight`/`clear`/`scrub`/`clearScrub`:

```typescript
    dropTargetAt,
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd JS/edit-overlay && npm test -- component-canvas.test.ts
```

Expected: PASS, all 3 new cases plus existing ones.

- [ ] **Step 5: Full overlay test/lint/typecheck pass**

```bash
cd JS/edit-overlay
npm run typecheck && npm run lint && npm test
```

Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add JS/edit-overlay/src/component-canvas.ts JS/edit-overlay/test/component-canvas.test.ts
git commit -m "feat(overlay): add dropTargetAt for palette-to-canvas drop resolution"
```

### Task 18: Swift wiring — palette→canvas drop

**Files:**
- Modify: `Sources/AnglesiteApp/ComponentEditorView.swift`

**Interfaces:**
- Produces: the canvas pane (the `ComponentCanvasView` wrapper) accepts `.dropDestination(for: PaletteDragPayload.self)`, calling `window.anglesiteCanvas.dropTargetAt(x, y)` via `evaluateJavaScript`, decoding the JS result, resolving it to a `nodeId` via the existing `ComponentOutline.node(atLine:column:in:)`, and calling `model.insertNode`.

- [ ] **Step 1: Read the current canvas wiring**

```bash
grep -n "private func canvas" -A 25 Sources/AnglesiteApp/ComponentEditorView.swift
```

- [ ] **Step 2: Add the drop handler**

In `canvas(_:)`, wrap the `ComponentCanvasView(...)` call with a drop destination:

```swift
                ComponentCanvasView(
                    url: url,
                    editRouter: context.editRouter,
                    onSelection: { model.canvasSelected($0) },
                    onComputedStyles: { model.computedStyles = $0.styles },
                    onWebView: { webView = $0 }
                )
                .dropDestination(for: PaletteDragPayload.self) { items, location in
                    guard let item = items.first, let webView else { return false }
                    Task { await performCanvasDrop(model, payload: item, location: location, webView: webView) }
                    return true
                }
```

Add the handler as a new method on `ComponentEditorView`:

```swift
    /// Resolves a canvas drop point to an insertion target via the overlay's `dropTargetAt`,
    /// then maps that source location back to a node id the same way `canvasSelected` does
    /// (`ComponentOutline.node(atLine:column:)`), and issues an `insert-node` at the resolved
    /// parent/index.
    private func performCanvasDrop(_ model: ComponentEditorModel, payload: PaletteDragPayload, location: CGPoint, webView: WKWebView) async {
        let script = "JSON.stringify(window.anglesiteCanvas?.dropTargetAt?.(\(location.x), \(location.y)) ?? null)"
        guard let raw = try? await webView.evaluateJavaScript(script) as? String,
              let data = raw.data(using: .utf8),
              let target = try? JSONDecoder().decode(DropTargetPayload.self, from: data),
              let modelRoot = model.model?.template,
              let node = ComponentOutline.node(atLine: target.line, column: target.column, in: modelRoot)
        else { return }

        switch target.zone {
        case "into":
            await model.insertNode(parentId: node.id, index: node.children.count, node: payload.kind)
        case "before", "after":
            guard let parentID = parentID(of: node.id, in: model), let siblingIndex = childIndex(of: node.id, underParent: parentID, in: model) else { return }
            let index = target.zone == "before" ? siblingIndex : siblingIndex + 1
            await model.insertNode(parentId: parentID, index: index, node: payload.kind)
        default:
            break
        }
    }

    private struct DropTargetPayload: Decodable {
        let file: String?
        let line: Int
        let column: Int
        let zone: String
    }
```

`parentID(of:in:)`/`childIndex(of:underParent:in:)` already exist from Task 16 — reused as-is.

- [ ] **Step 3: Build**

```bash
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -80
```

Expected: clean (fix any signature drift from Task 16/17's speculative code).

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteApp/ComponentEditorView.swift
git commit -m "feat(app): wire palette-to-canvas drop via the overlay's dropTargetAt"
```

### Task 19: Editable Attributes inspector tab

**Files:**
- Modify: `Sources/AnglesiteApp/ComponentEditorView.swift`

**Interfaces:**
- Produces: the existing read-only "Selection" `GroupBox` (attrs shown via `LabeledContent`) becomes editable — a text field per attribute plus "Add attribute" / remove buttons, wired to `model.setAttr`. This is the minimal Attrs/Props surface needed to exercise `set-attr` in this slice; the full structured Props form (spec §4.3) is slice 4's `set-props-interface` work, not this one.

- [ ] **Step 1: Read the current Selection GroupBox**

```bash
grep -n 'GroupBox("Selection")' -A 10 Sources/AnglesiteApp/ComponentEditorView.swift
```

- [ ] **Step 2: Replace it with an editable version**

Replace the block:

```swift
                if let node = model.selectedNode {
                    GroupBox("Selection") {
                        LabeledContent("Kind", value: node.kind.rawValue)
                        if let tag = node.tag { LabeledContent("Tag", value: tag) }
                        ForEach(node.attrs, id: \.name) { attr in
                            LabeledContent(attr.name, value: attr.value ?? "—")
                        }
                    }
                }
```

with:

```swift
                if let node = model.selectedNode {
                    GroupBox("Selection") {
                        LabeledContent("Kind", value: node.kind.rawValue)
                        if let tag = node.tag { LabeledContent("Tag", value: tag) }
                        ForEach(node.attrs, id: \.name) { attr in
                            HStack(spacing: 4) {
                                Text(attr.name).font(.system(.caption, design: .monospaced)).frame(width: 90, alignment: .leading)
                                TextField("value", text: attrValueBinding(model, node: node, name: attr.name))
                                    .font(.system(.caption, design: .monospaced))
                                    .textFieldStyle(.plain)
                                    .onSubmit { commitAttr(model, node: node, name: attr.name) }
                                Button(role: .destructive) {
                                    Task { await model.setAttr(nodeId: node.id, name: attr.name, value: nil) }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        HStack {
                            TextField("New attribute name", text: $newAttrName)
                                .font(.system(.caption, design: .monospaced))
                            TextField("value", text: $newAttrValue)
                                .font(.system(.caption, design: .monospaced))
                            Button("Add") {
                                let name = newAttrName.trimmingCharacters(in: .whitespaces)
                                guard !name.isEmpty else { return }
                                Task {
                                    await model.setAttr(nodeId: node.id, name: name, value: newAttrValue)
                                    newAttrName = ""
                                    newAttrValue = ""
                                }
                            }
                            .disabled(newAttrName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
```

Add the new `@State` drafts and helper methods, alongside the existing `selectorDrafts`/`propertyDrafts`/`valueDrafts` declarations:

```swift
    /// In-progress edits to an attribute value, keyed by `"<nodeID>:<attrName>"`, pending
    /// commit (on submit) to `ComponentEditorModel.setAttr`.
    @State private var attrValueDrafts: [String: String] = [:]
    @State private var newAttrName: String = ""
    @State private var newAttrValue: String = ""
```

```swift
    private func attrValueBinding(_ model: ComponentEditorModel, node: ComponentModel.Node, name: String) -> Binding<String> {
        let key = "\(node.id):\(name)"
        let current = node.attrs.first(where: { $0.name == name })?.value ?? ""
        return Binding(
            get: { attrValueDrafts[key] ?? current },
            set: { attrValueDrafts[key] = $0 }
        )
    }

    private func commitAttr(_ model: ComponentEditorModel, node: ComponentModel.Node, name: String) {
        let key = "\(node.id):\(name)"
        guard let draft = attrValueDrafts[key] else { return }
        let current = node.attrs.first(where: { $0.name == name })?.value ?? ""
        guard draft != current else { return }
        Task { await model.setAttr(nodeId: node.id, name: name, value: draft) }
    }
```

- [ ] **Step 3: Build**

```bash
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -80
```

Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteApp/ComponentEditorView.swift
git commit -m "feat(app): editable Attributes rows in the Component Editor inspector"
```

### Task 20: Manual GUI smoke pass

**Files:** none — verification only.

- [ ] **Step 1: Launch the app against a site with at least two components**

Open a `.anglesite` package whose `Source/src/components/` has ≥2 `.astro` files (one importable into the other), open one in the Component Editor.

- [ ] **Step 2: Exercise each new capability**

- Drag a curated element (e.g. "Paragraph") from the palette onto an outline row's middle band → a new `<p></p>` appears as that row's last child in the outline and canvas (after HMR repaint).
- Drag a project component from the palette onto the canvas, over an existing element → the component's markup + a frontmatter import both appear in Source mode; canvas HMR-repaints showing it rendered (with its default-slot sample content, per the harness route's existing prop-knob/slot-sample behavior from slice 1).
- Drag an existing outline row onto another row's top band → it reorders as a preceding sibling; onto the middle band of a *different* element → it reparents.
- Select a component-instance row → confirm it shows no expand triangle / children in the outline (sealed), and double-click it → the main pane switches to that component's own Component Editor.
- Edit an attribute value in the Attributes section and press Return → canvas HMR-repaints reflecting the change; remove an attribute via the minus button → it disappears from both the inspector and the rendered element.
- Remove a component instance that was the last user of its import → reopen Source mode and confirm the `import` line for that component is gone.
- Trigger a conflict: edit the file externally (e.g. in a text editor) while the Component Editor is open, then attempt any structure write → confirm the existing "changed outside Anglesite — Reload" banner (from slice 2) still fires correctly for structure ops too.

- [ ] **Step 3: Record results**

If everything above works, note it in the PR description (Task 21). If something doesn't, fix it as an amendment to the relevant earlier task before proceeding — do not silently ship a broken interaction.

### Task 21: `MIN_PLUGIN_VERSION` bump, full regression, PR

**Files:**
- Modify: `scripts/copy-plugin.sh`

**Prerequisite:** Part A's PR (Task 11) is merged and tagged as `v1.5.0` — confirm with the user before starting this task if it hasn't already been confirmed merged.

- [ ] **Step 1: Bump the floor**

In `scripts/copy-plugin.sh`, change:

```bash
MIN_PLUGIN_VERSION="1.4.0"
```

to:

```bash
MIN_PLUGIN_VERSION="1.5.0"
```

Update the comment above it (currently describing the 1.4.0 requirement) to also mention the structure ops: `"...(set-style-property/.../set-rule-selector, used by slice 2's Styles panel; insert-node/move-node/remove-node/set-attr, used by slice 3's palette and structure edits)."`

- [ ] **Step 2: Re-sync the bundled plugin and rebuild**

```bash
ANGLESITE_PLUGIN_SRC=/Users/dwk/Developer/github.com/Anglesite/anglesite scripts/copy-plugin.sh
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -40
```

Expected: the guard passes (plugin repo is now at `1.5.0`), build succeeds.

- [ ] **Step 3: Full Swift test suite**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .
```

Expected: 100% pass.

- [ ] **Step 4: Commit and push**

```bash
git add scripts/copy-plugin.sh
git commit -m "chore: bump MIN_PLUGIN_VERSION to 1.5.0 for Component Editor slice 3"
git push -u origin <branch-name>
```

- [ ] **Step 5: Open the PR**

```bash
gh pr create --title "feat(app): Component Editor slice 3 — structure ops + palette (#493)" --body "$(cat <<'EOF'
## What
Closes #493. Adds the palette (project components + curated HTML elements + <slot>), drag-and-drop into the outline and onto the canvas, drag-reorder/reparent in the outline, sealed component-instance rows with double-click-to-open, and an editable Attributes inspector — wired to the plugin's new insert-node/move-node/remove-node/set-attr ops (paired plugin PR, v1.5.0).

## Known scope cut
Sealed component instances hide their children in the outline (per spec) but this slice doesn't resolve a target component's own named `<slot>`s to show labeled slot-fill drop areas — any drop on a sealed row inserts as an unnamed child. Full named-slot targeting is deferred.

## Test plan
- [ ] Manual GUI smoke pass (see plan Task 20) completed
- [ ] `swift test` passes
- [ ] JS/edit-overlay lint/typecheck/test passes
EOF
)"
```

- [ ] **Step 6: Checkpoint**

Report the PR URL to the user and stop — do not merge without explicit confirmation.
