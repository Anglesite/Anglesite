# Component Editor Slice 2 (Styles Panel) Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the first write path for the Component Editor: four CSS ops (`set-style-property`, `remove-style-property`, `add-style-rule`, `set-rule-selector`) routed through the existing `apply_edit` MCP tool with content-hash staleness checking, plus the Swift-side editable Styles panel (declaration rows with native controls, add/remove/rename, media-query grouping) and scrub injection for 60fps continuous drags.

**Architecture:** A new plugin resolver (`server/component-style-edit.mjs`) re-parses the target `.astro` file's `<style>` blocks with `css-tree` on every write, identifies the target rule by its exact byte **span** (never by selector string — selectors come back `generate()`-normalized and are not a reliable identity key), and produces a precise `{file, range, replacement}` splice that flows through the *existing* `apply_edit` → `spliceSource` → `atomicWrite` → git-commit pipeline unchanged. A `baseVersion` (sha256 content hash) sent by the client is checked against the file's current hash before every write; a mismatch is refused as `stale`, not silently applied. On success, the reply piggybacks a freshly rebuilt component model so the app never needs a second round-trip. On the app side, the harness canvas — which currently has **zero write capability** (`LoggingEditRouter()` is hardcoded) — gets wired to the real `MCPApplyEditRouter`, and the read-only "Styles" `GroupBox` becomes an editable panel.

**Tech Stack:** Node ≥22 ESM (`.mjs`), zod, vitest, `@astrojs/compiler`, `css-tree` (plugin); Swift 6.4 / Swift Testing, SwiftUI, WKWebView (app); TypeScript overlay (`JS/edit-overlay`).

**Spec:** `docs/superpowers/specs/2026-07-05-component-editor-design.md` §2.3 (write ops), §4.3 (Styles panel), §5 (edit lifecycle — scrub injection, conflicts).

## Global Constraints

- **Two repos.** Part A (Tasks 1–8) runs in the plugin repo `/Users/dwk/Developer/github.com/Anglesite/anglesite`. Part B (Tasks 9–15) runs in an app-repo worktree. Every task states its working directory — `cd` there first; dispatched subagents get a hard `cd` guard.
- **Prerequisite dependency (Task 1):** issue Anglesite/anglesite#411 (component-model parser gaps) is fixed on commit `a07bbc4` but **not yet merged to `main`** — it sits on branch `claude/amazing-pascal-37bd1b`. That commit's own message ties its nested-zone-filtering fix explicitly to slice 2. Land it first; do not build slice 2 on the pre-fix `component-model.mjs`.
- **Rule identity is span-based, never selector-string-based.** `styles[].selector` in the model is `css-tree`'s `generate()` output — normalized, not guaranteed byte-identical to the source. All four new ops identify a rule by `component.ruleSpan` (the exact `[start, end]` from a previously-fetched model's `styles[].span`), never by re-matching `selector` text.
- **`version` is a content hash, not a git SHA.** `apply_edit` commits land on the hidden `anglesite/edits` branch without moving `HEAD`, so a repo-level SHA never changes across edits. `fileVersion(source)` (`"sha256:" + sha256(source).slice(0,12)`) is the only valid staleness token — extract it to a shared module so both the model builder and the new resolver hash identically.
- **The existing `edit-style` op is not reusable.** It is a whole-file, regex/text-anchor-based, page-path-scoped mechanism (`style-edit.mjs` + `patcher.mjs`'s `resolveStyle`) with no relationship to `component-model.mjs`'s span-precise rule objects. The four new ops get their own resolver, not an extension of `resolveStyle`.
- **App worktree setup:** run `xcodegen generate` first (xcodeproj is gitignored), and `ANGLESITE_PLUGIN_SRC=/Users/dwk/Developer/github.com/Anglesite/anglesite scripts/copy-plugin.sh` before any `xcodebuild`.
- **Swift toolchain:** run tests as `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .` (default CommandLineTools swift is broken/too old).
- Plugin server code is ESM `.mjs`, Node ≥22, zod input schemas, tool replies `{ content: [{type:"text", text: JSON.stringify(...)}] }` with `isError: true` on failure.
- Swift: Swift Testing (`@Test`, `#expect`), `@testable import`; app-target logic stays thin — testable types go in `AnglesiteCore`.
- Overlay: `npm run typecheck && npm run lint && npm test` must pass in `JS/edit-overlay` before commit.
- Template changes can break Swift string-match tests — run `swift test` before pushing template edits, not just the JS build.
- Conventional commits. Do not push tags, cut a plugin release, or merge the #411 prerequisite to `main` without the user's go-ahead (checkpoints called out below).
- macOS 27 / SwiftUI 27; no LLM/Claude paths anywhere (deterministic Swift/TS only, per #459).

## File Structure

**Part A — plugin repo (`…/Anglesite/anglesite`):**

| File | Responsibility |
|---|---|
| `server/file-version.mjs` (create) | Shared `fileVersion(source)` content-hash helper |
| `server/css-rule-index.mjs` (create) | Shared `indexCssRules(styleElement)` — span-precise rule/declaration walk (prelude span, block-inner span, declarations), used by both the read model and the write resolver |
| `server/component-model.mjs` (modify) | Delegate to the two shared helpers above instead of inlining them; public JSON shape unchanged |
| `server/component-style-edit.mjs` (create) | `resolveComponentStyle(projectRoot, edit)` — implements all 4 ops as byte-precise splices; stale/no-match/invalid-input refusals |
| `server/apply-edit-schema.mjs` (modify) | New op names, `component` payload schema, `selector` becomes optional |
| `server/patcher.mjs` (modify) | Dispatch the 4 new ops to `resolveComponentStyle` |
| `server/apply-edit-dispatcher.mjs` (modify) | Reject component-style ops missing a `component` payload; piggyback a fresh model onto success replies for those ops |
| `tests/file-version.test.ts` (create) | Hash determinism/format tests |
| `tests/css-rule-index.test.ts` (create) | Span/prelude/blockInner correctness fixtures |
| `tests/component-style-edit.test.ts` (create) | Direct resolver unit tests — all 4 ops, stale, no-match |
| `tests/apply-edit-dispatcher-component-style.test.ts` (create) | Dispatcher-level round trip (fixture dir, real `applyEdit()` calls) |
| `tests/component-model.test.ts` (modify) | Confirm refactor didn't change the public model shape |
| `package.json`, `CHANGELOG.md` (modify) | Version bump for release |

**Part B — app repo worktree:**

| File | Responsibility |
|---|---|
| `Sources/AnglesiteCore/EditMessage.swift` (modify) | New `Op` constants, optional `component: JSONValue?` field, `selector` becomes optional |
| `Sources/AnglesiteCore/EditRouter.swift` (modify) | `EditReply` gains `model: ComponentModel?`; `MCPApplyEditRouter.parseStructured` decodes it |
| `Sources/AnglesiteApp/ComponentEditorModel.swift` (modify) | `ComponentEditorContext.editRouter` field; four write methods (`setStyleProperty`, `removeStyleProperty`, `addStyleRule`, `setRuleSelector`); stale handling |
| `Sources/AnglesiteApp/ComponentEditorView.swift` (modify) | Replace `LoggingEditRouter()` with the real router; Styles `GroupBox` becomes editable declaration rows + native controls + add-rule + media grouping |
| `JS/edit-overlay/src/component-canvas.ts` (modify) | `window.anglesiteCanvas.scrub(selector, property, value)` / `.clearScrub()` |
| `JS/edit-overlay/test/component-canvas.test.ts` (modify) | Scrub injection tests |
| `Tests/AnglesiteCoreTests/EditMessageTests.swift` (modify) | New op constants, `component` field encode/decode |
| `Tests/AnglesiteCoreTests/EditReplyAndRouterTests.swift` (modify) | `model` decode from a piggybacked reply |
| `Tests/AnglesiteCoreTests/ComponentEditorModelStyleEditTests.swift` (create) | Write-method tests against a fake `EditRouter` |
| `scripts/copy-plugin.sh` / `MIN_PLUGIN_VERSION` guard (modify) | Bump floor to the new plugin release |

---

# Part A — Plugin repo

All Part A tasks: `cd /Users/dwk/Developer/github.com/Anglesite/anglesite`.

### Task 1: Land the #411 prerequisite fix

**Files:** none new — this lands an existing commit.

- [ ] **Step 1: Check out main and confirm the fix commit exists**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/anglesite
git checkout main && git pull
git log --oneline -1 a07bbc4
```

Expected: `a07bbc4 fix(mcp): close component-model parser gaps from slice 1 review (#411)`

- [ ] **Step 2: Bring the fix onto a short-lived branch and test**

```bash
git checkout -b fix/411-component-model-zone-gaps
git cherry-pick a07bbc4
npm test -- tests/component-model.test.ts
```

Expected: all tests in `component-model.test.ts` pass, including the new nested-zone-filtering and comma-containing-default cases the commit adds.

- [ ] **Step 3: Push and open a PR**

```bash
git push -u origin fix/411-component-model-zone-gaps
gh pr create --title "fix(mcp): close component-model parser gaps from slice 1 review (#411)" --body "Cherry-picks a07bbc4 from claude/amazing-pascal-37bd1b onto main. Prerequisite for Component Editor slice 2 (styles panel), which relies on correct zone-filtering."
```

- [ ] **Step 4: Checkpoint — get user go-ahead before merging**

Stop and confirm with the user before merging this PR to `main`. Once merged, pull `main` before starting Task 2.

### Task 2: Extract shared `fileVersion` and `indexCssRules` helpers

**Files:**
- Create: `server/file-version.mjs`
- Create: `server/css-rule-index.mjs`
- Create: `tests/file-version.test.ts`
- Create: `tests/css-rule-index.test.ts`
- Modify: `server/component-model.mjs`
- Modify: `tests/component-model.test.ts` (no behavior change expected — this step just confirms it)

**Interfaces:**
- Produces: `fileVersion(source: string) → string` (format `"sha256:" + <12 hex chars>`).
- Produces: `indexCssRules(styleElement: AstroStyleElementNode) → Rule[]` where `Rule = { selector, preludeSpan: [start,end], media: string|null, span: [start,end], blockInner: [start,end], declarations: [{property, value, span: [start,end]}] }`. `span` is the whole rule (selector + block); `blockInner` is the byte range strictly between `{` and `}` (used by the write resolver to know where to insert a new declaration); `preludeSpan` covers only the selector text (used by `set-rule-selector`).
- Consumes (in `component-model.mjs`): replaces the inline `extractRules`/`cssSpan` with a thin wrapper that maps `indexCssRules`'s richer shape down to the model's public `{selector, media, span, declarations}` (dropping `preludeSpan`/`blockInner` — the read-only model's public JSON shape is unchanged).

- [ ] **Step 1: Branch**

```bash
git checkout main && git pull
git checkout -b feat/component-style-ops
```

- [ ] **Step 2: Write the failing tests**

Create `tests/file-version.test.ts`:

```typescript
import { describe, it, expect } from "vitest";
import { fileVersion } from "../server/file-version.mjs";

describe("fileVersion", () => {
  it("is deterministic for identical content", () => {
    expect(fileVersion("a")).toBe(fileVersion("a"));
  });

  it("changes when content changes", () => {
    expect(fileVersion("a")).not.toBe(fileVersion("b"));
  });

  it("matches the sha256:<12 hex> format", () => {
    expect(fileVersion("hello")).toMatch(/^sha256:[0-9a-f]{12}$/);
  });
});
```

Create `tests/css-rule-index.test.ts`:

```typescript
import { describe, it, expect } from "vitest";
import { parse } from "@astrojs/compiler";
import { indexCssRules } from "../server/css-rule-index.mjs";

const SOURCE = `<style>
  .card { padding: 1rem; color: red; }
  @media (max-width: 600px) {
    .card { padding: 0.5rem; }
  }
</style>
`;

async function styleElement() {
  const { ast } = await parse(SOURCE, { position: true });
  return ast.children.find((n: any) => n.type === "element" && n.name === "style");
}

describe("indexCssRules", () => {
  it("captures selector, media, span, preludeSpan, blockInner, and declarations", async () => {
    const el = await styleElement();
    const rules = indexCssRules(el);
    expect(rules).toHaveLength(2);

    const [card, media] = rules;
    expect(card.selector).toBe(".card");
    expect(card.media).toBeNull();
    expect(SOURCE.slice(card.preludeSpan[0], card.preludeSpan[1])).toBe(".card");
    expect(SOURCE.slice(card.span[0], card.span[1])).toContain("padding: 1rem");
    expect(card.declarations).toEqual([
      { property: "padding", value: "1rem", span: card.declarations[0].span },
      { property: "color", value: "red", span: card.declarations[1].span },
    ]);
    expect(SOURCE.slice(card.declarations[0].span[0], card.declarations[0].span[1])).toBe("padding: 1rem");
    // blockInner sits strictly inside the braces
    expect(SOURCE[card.blockInner[0] - 1]).toBe("{");
    expect(SOURCE[card.blockInner[1]]).toBe("}");

    expect(media.media).toBe("(max-width: 600px)");
    expect(media.selector).toBe(".card");
  });

  it("returns [] for a non-CSS lang attribute", async () => {
    const src = `<style lang="scss">.x { &:hover { color: blue; } }</style>`;
    const { ast } = await parse(src, { position: true });
    const el = ast.children.find((n: any) => n.type === "element" && n.name === "style");
    expect(indexCssRules(el)).toEqual([]);
  });
});
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
npm test -- tests/file-version.test.ts tests/css-rule-index.test.ts
```

Expected: FAIL — modules don't exist yet.

- [ ] **Step 4: Implement `server/file-version.mjs`**

```javascript
import { createHash } from "node:crypto";

/**
 * Content hash, not a git SHA: apply_edit commits land on the hidden
 * anglesite/edits branch without moving HEAD, so a repo-level SHA would stay
 * constant across edits — useless as a staleness token. Hashing the file
 * content means the version changes exactly when the model's source does.
 */
export function fileVersion(source) {
  return "sha256:" + createHash("sha256").update(source).digest("hex").slice(0, 12);
}
```

- [ ] **Step 5: Implement `server/css-rule-index.mjs`**

```javascript
import { parse as parseCss, generate, walk } from "css-tree";

/**
 * Span-precise CSS rule index for one <style> element. Shared by the
 * read-only component model (component-model.mjs) and the write-side
 * resolver (component-style-edit.mjs) so both agree byte-for-byte on rule
 * identity — selector text alone is not reliable (css-tree's generate()
 * re-serializes and can normalize whitespace/quoting away from the source).
 */
export function indexCssRules(styleElement) {
  const lang = (styleElement.attributes ?? []).find((a) => a.name === "lang")?.value;
  if (lang && lang.toLowerCase() !== "css") return [];
  const textChild = (styleElement.children ?? []).find((c) => c.type === "text");
  if (!textChild?.value) return [];
  const baseOffset = textChild.position?.start?.offset ?? 0;

  let cssAst;
  try {
    cssAst = parseCss(textChild.value, { positions: true, parseValue: false, parseAtrulePrelude: false });
  } catch {
    return [];
  }

  const rules = [];
  walk(cssAst, {
    visit: "Rule",
    enter(node) {
      const media =
        this.atrule && this.atrule.name === "media" && this.atrule.prelude
          ? generate(this.atrule.prelude).trim()
          : null;
      const declarations = [];
      node.block.children.forEach((decl) => {
        if (decl.type !== "Declaration") return;
        declarations.push({
          property: decl.property,
          value: generate(decl.value).trim(),
          span: span(decl.loc, baseOffset),
        });
      });
      const blockSpan = span(node.block.loc, baseOffset);
      rules.push({
        selector: generate(node.prelude),
        preludeSpan: span(node.prelude.loc, baseOffset),
        media,
        span: span(node.loc, baseOffset),
        blockInner: [blockSpan[0] + 1, blockSpan[1] - 1],
        declarations,
      });
    },
  });
  return rules;
}

function span(loc, baseOffset) {
  if (!loc) return [null, null];
  return [baseOffset + loc.start.offset, baseOffset + loc.end.offset];
}
```

- [ ] **Step 6: Run the new tests to verify they pass**

```bash
npm test -- tests/file-version.test.ts tests/css-rule-index.test.ts
```

Expected: PASS.

- [ ] **Step 7: Refactor `component-model.mjs` to delegate, keeping its public shape identical**

In `server/component-model.mjs`, replace the `createHash` import and inline `fileVersion` function with:

```javascript
import { fileVersion } from "./file-version.mjs";
```

(remove the local `fileVersion` definition and the now-unused `createHash` import).

Replace the inline `extractRules`/`cssSpan` functions and the `import { parse as parseCss, generate, walk } from "css-tree";` line with:

```javascript
import { indexCssRules } from "./css-rule-index.mjs";
```

```javascript
function extractRules(styleElement) {
  return indexCssRules(styleElement).map(({ selector, media, span, declarations }) => ({
    selector,
    media,
    span,
    declarations,
  }));
}
```

- [ ] **Step 8: Run the full existing model test suite to confirm no regression**

```bash
npm test -- tests/component-model.test.ts
```

Expected: PASS, unchanged — this refactor must not alter `component-model.mjs`'s public JSON output.

- [ ] **Step 9: Commit**

```bash
git add server/file-version.mjs server/css-rule-index.mjs server/component-model.mjs tests/file-version.test.ts tests/css-rule-index.test.ts
git commit -m "refactor(mcp): extract fileVersion and indexCssRules for reuse by the style-edit resolver"
```

### Task 3: Schema — new ops and component payload

**Files:**
- Modify: `server/apply-edit-schema.mjs`

**Interfaces:**
- Produces: `editOps` gains four new string values. New exported `componentEditSchema` (zod). `applyEditInputShape.selector` becomes `.optional()`; new `applyEditInputShape.component` field.
- Produces: exported `COMPONENT_STYLE_OPS: Set<string>` (the four new op names) for reuse by `patcher.mjs` and `apply-edit-dispatcher.mjs`.

- [ ] **Step 1: Write the failing test**

Create `tests/apply-edit-schema-component.test.ts`:

```typescript
import { describe, it, expect } from "vitest";
import { z } from "zod";
import { editOps, componentEditSchema, applyEditInputShape, COMPONENT_STYLE_OPS } from "../server/apply-edit-schema.mjs";

describe("component-style op schema", () => {
  it("registers the four new op names", () => {
    for (const op of ["set-style-property", "remove-style-property", "add-style-rule", "set-rule-selector"]) {
      expect(editOps).toContain(op);
      expect(COMPONENT_STYLE_OPS.has(op)).toBe(true);
    }
  });

  it("accepts a set-style-property component payload", () => {
    const schema = z.object(applyEditInputShape);
    const result = schema.safeParse({
      id: "1",
      path: "src/components/Card.astro",
      op: "set-style-property",
      component: { path: "src/components/Card.astro", baseVersion: "sha256:abc123456789", ruleSpan: [10, 40], property: "color", value: "red" },
    });
    expect(result.success).toBe(true);
  });

  it("rejects a component payload missing baseVersion", () => {
    const result = componentEditSchema.safeParse({ path: "src/components/Card.astro", property: "color", value: "red" });
    expect(result.success).toBe(false);
  });

  it("still accepts a legacy replace-attr edit with selector and no component", () => {
    const schema = z.object(applyEditInputShape);
    const result = schema.safeParse({
      id: "1",
      path: "/about/",
      op: "replace-attr",
      selector: { tag: "h1", classes: [], nthChild: 1 },
      value: { name: "class", value: "big" },
    });
    expect(result.success).toBe(true);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

```bash
npm test -- tests/apply-edit-schema-component.test.ts
```

Expected: FAIL — `componentEditSchema`/`COMPONENT_STYLE_OPS` don't exist yet.

- [ ] **Step 3: Implement the schema additions**

In `server/apply-edit-schema.mjs`, change:

```javascript
export const editOps = ["replace-text", "replace-attr", "replace-image-src", "edit-style", "apply-instruction"];
```

to:

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
];

export const COMPONENT_STYLE_OPS = new Set([
  "set-style-property",
  "remove-style-property",
  "add-style-rule",
  "set-rule-selector",
]);
```

Add, near `elementInfoSchema`:

```javascript
export const componentEditSchema = z.object({
  path: z.string().describe("Component path relative to the project root, e.g. src/components/Card.astro"),
  baseVersion: z.string().describe("Content-hash version (sha256:...) the edit was computed against; a mismatch is refused as stale"),
  ruleSpan: z
    .tuple([z.number().int().nullable(), z.number().int().nullable()])
    .optional()
    .describe("Identifies an existing rule by its exact byte span from get_component_model's styles[].span. Required for set-style-property, remove-style-property, set-rule-selector. Omitted for add-style-rule."),
  property: z.string().optional().describe("Declaration property name; required for set-style-property and remove-style-property"),
  value: z.string().optional().describe("Declaration value; required for set-style-property"),
  selector: z.string().optional().describe("New rule's selector for add-style-rule, or the renamed selector for set-rule-selector"),
  media: z.string().nullable().optional().describe("@media condition for add-style-rule; absent/null means no wrapping media query"),
  declarations: z
    .array(z.object({ property: z.string(), value: z.string() }))
    .optional()
    .describe("Initial declarations for add-style-rule"),
});
```

Change `selector` in `applyEditInputShape` from required to optional, and add `component`:

```javascript
export const applyEditInputShape = {
  id: z.string().describe("Correlation ID echoed back in edit-applied/edit-failed"),
  type: z.string().optional().describe("Boundary tag from the WKWebView side ... — accepted and ignored"),
  path: z.string().describe("Page or component path"),
  selector: elementInfoSchema.optional().describe("Structured element metadata for page-level ops; resolved server-side via selector.mjs.buildSelector"),
  component: componentEditSchema.optional().describe("Structured component-style edit payload for set-style-property/remove-style-property/add-style-rule/set-rule-selector"),
  op: z.enum(editOps).describe("Edit operation — see componentEditSchema for the four component-style ops"),
  value: z.unknown().describe("Operation payload; varies by op ..."),
  dry_run: z.boolean().optional().describe("When true, compute the would-be change and return an edit-preview {before, after} WITHOUT writing to disk or recording history"),
};
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
npm test -- tests/apply-edit-schema-component.test.ts
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add server/apply-edit-schema.mjs tests/apply-edit-schema-component.test.ts
git commit -m "feat(mcp): add component-style op names and payload schema to apply_edit"
```

### Task 4: The write resolver — `component-style-edit.mjs`

**Files:**
- Create: `server/component-style-edit.mjs`
- Create: `tests/component-style-edit.test.ts`

**Interfaces:**
- Consumes: `indexCssRules` (Task 2), `fileVersion` (Task 2).
- Produces: `async function resolveComponentStyle(projectRoot, edit) → { file, range: {start,end}, replacement } | { refused: true, reason, detail }`. Same result shape `patcher.mjs`'s `resolve()` already expects from every other resolver.

- [ ] **Step 1: Write the failing tests**

Create `tests/component-style-edit.test.ts`:

```typescript
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, mkdirSync, writeFileSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { resolveComponentStyle } from "../server/component-style-edit.mjs";
import { fileVersion } from "../server/file-version.mjs";

const CARD = `---
interface Props { title: string; }
---
<article class="card">
  <h2>{title}</h2>
</article>

<style>
  .card { padding: 1rem; color: red; }
  @media (max-width: 600px) {
    .card { padding: 0.5rem; }
  }
</style>
`;

describe("resolveComponentStyle", () => {
  let tmpDir;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "anglesite-cse-"));
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

  it("refuses with stale when baseVersion does not match", async () => {
    const edit = { op: "set-style-property", component: { path: "src/components/Card.astro", baseVersion: "sha256:000000000000", ruleSpan: [0, 1], property: "color", value: "blue" } };
    const result = await resolveComponentStyle(tmpDir, edit);
    expect(result.refused).toBe(true);
    expect(result.reason).toBe("stale");
  });

  it("set-style-property updates an existing declaration in place", async () => {
    const baseVersion = fileVersion(CARD);
    const ruleSpan = [CARD.indexOf(".card {"), CARD.indexOf("@media") - 3]; // the .card rule's span — recomputed precisely below
    // Recompute the real span via the resolver's own indexing to avoid hand-counting offsets:
    const { indexCssRules } = await import("../server/css-rule-index.mjs");
    const { parse } = await import("@astrojs/compiler");
    const { ast } = await parse(CARD, { position: true });
    const styleEl = ast.children.find((n) => n.type === "element" && n.name === "style");
    const [cardRule] = indexCssRules(styleEl);

    const edit = { op: "set-style-property", component: { path: "src/components/Card.astro", baseVersion, ruleSpan: cardRule.span, property: "color", value: "blue" } };
    const result = await resolveComponentStyle(tmpDir, edit);
    expect(result.refused).toBeFalsy();
    expect(apply(result)).toContain("color: blue");
    expect(apply(result)).not.toContain("color: red");
  });

  it("set-style-property inserts a new declaration when the property is absent", async () => {
    const baseVersion = fileVersion(CARD);
    const { indexCssRules } = await import("../server/css-rule-index.mjs");
    const { parse } = await import("@astrojs/compiler");
    const { ast } = await parse(CARD, { position: true });
    const styleEl = ast.children.find((n) => n.type === "element" && n.name === "style");
    const [cardRule] = indexCssRules(styleEl);

    const edit = { op: "set-style-property", component: { path: "src/components/Card.astro", baseVersion, ruleSpan: cardRule.span, property: "margin", value: "0" } };
    const result = await resolveComponentStyle(tmpDir, edit);
    expect(apply(result)).toMatch(/margin: 0;\s*}/);
  });

  it("remove-style-property deletes the declaration and its semicolon", async () => {
    const baseVersion = fileVersion(CARD);
    const { indexCssRules } = await import("../server/css-rule-index.mjs");
    const { parse } = await import("@astrojs/compiler");
    const { ast } = await parse(CARD, { position: true });
    const styleEl = ast.children.find((n) => n.type === "element" && n.name === "style");
    const [cardRule] = indexCssRules(styleEl);

    const edit = { op: "remove-style-property", component: { path: "src/components/Card.astro", baseVersion, ruleSpan: cardRule.span, property: "color" } };
    const result = await resolveComponentStyle(tmpDir, edit);
    expect(apply(result)).not.toContain("color");
    expect(apply(result)).toContain("padding: 1rem");
  });

  it("set-rule-selector renames only the prelude", async () => {
    const baseVersion = fileVersion(CARD);
    const { indexCssRules } = await import("../server/css-rule-index.mjs");
    const { parse } = await import("@astrojs/compiler");
    const { ast } = await parse(CARD, { position: true });
    const styleEl = ast.children.find((n) => n.type === "element" && n.name === "style");
    const [cardRule] = indexCssRules(styleEl);

    const edit = { op: "set-rule-selector", component: { path: "src/components/Card.astro", baseVersion, ruleSpan: cardRule.span, selector: ".card--big" } };
    const result = await resolveComponentStyle(tmpDir, edit);
    expect(apply(result)).toContain(".card--big {");
    expect(apply(result)).toContain("padding: 1rem");
  });

  it("add-style-rule appends a new rule before the closing </style>", async () => {
    const baseVersion = fileVersion(CARD);
    const edit = { op: "add-style-rule", component: { path: "src/components/Card.astro", baseVersion, selector: "h2", declarations: [{ property: "font-weight", value: "bold" }] } };
    const result = await resolveComponentStyle(tmpDir, edit);
    const next = apply(result);
    expect(next).toMatch(/h2\s*{\s*font-weight: bold;\s*}/);
    expect(next.indexOf("h2 {")).toBeGreaterThan(next.indexOf(".card {"));
  });

  it("add-style-rule creates a <style> block when none exists", async () => {
    const noStyle = `---\n---\n<article class="card"><slot /></article>\n`;
    writeFileSync(join(tmpDir, "src", "components", "Card.astro"), noStyle);
    const baseVersion = fileVersion(noStyle);
    const edit = { op: "add-style-rule", component: { path: "src/components/Card.astro", baseVersion, selector: ".card", declarations: [{ property: "padding", value: "1rem" }] } };
    const result = await resolveComponentStyle(tmpDir, edit);
    const next = apply(result);
    expect(next).toContain("<style>");
    expect(next).toMatch(/\.card\s*{\s*padding: 1rem;\s*}/);
  });

  it("refuses no-match when the rule span no longer exists", async () => {
    const baseVersion = fileVersion(CARD);
    const edit = { op: "set-style-property", component: { path: "src/components/Card.astro", baseVersion, ruleSpan: [9999, 10010], property: "color", value: "blue" } };
    const result = await resolveComponentStyle(tmpDir, edit);
    expect(result.refused).toBe(true);
    expect(result.reason).toBe("no-match");
  });
});
```

- [ ] **Step 2: Run to verify it fails**

```bash
npm test -- tests/component-style-edit.test.ts
```

Expected: FAIL — module doesn't exist.

- [ ] **Step 3: Implement `server/component-style-edit.mjs`**

```javascript
import { readFileSync } from "node:fs";
import { join, normalize } from "node:path";
import { parse } from "@astrojs/compiler";
import { fileVersion } from "./file-version.mjs";
import { indexCssRules } from "./css-rule-index.mjs";

function refuse(reason, detail) {
  return { refused: true, reason, detail };
}

export async function resolveComponentStyle(projectRoot, edit) {
  const { component } = edit;
  if (!component || typeof component !== "object") {
    return refuse("invalid-input", "component payload is required for this op");
  }
  const { path: relPath, baseVersion, ruleSpan, property, value, selector, media, declarations } = component;

  if (typeof relPath !== "string" || !relPath.endsWith(".astro") || normalize(relPath).startsWith("..") || relPath.startsWith("/")) {
    return refuse("invalid-input", `not a project-relative .astro path: ${relPath}`);
  }

  const absPath = join(projectRoot, relPath);
  let source;
  try {
    source = readFileSync(absPath, "utf-8");
  } catch (err) {
    return refuse("no-match", `read ${relPath}: ${err.message}`);
  }

  if (fileVersion(source) !== baseVersion) {
    return refuse("stale", `${relPath} changed since the model was fetched`);
  }

  let ast;
  try {
    ({ ast } = await parse(source, { position: true }));
  } catch (err) {
    return refuse("invalid-input", `parse ${relPath}: ${err.message}`);
  }

  const styleElements = [];
  collectStyleElements(ast, styleElements);
  const rules = styleElements.flatMap((el) => indexCssRules(el));

  switch (edit.op) {
    case "set-style-property":
      return applySetStyleProperty(relPath, rules, ruleSpan, property, value);
    case "remove-style-property":
      return applyRemoveStyleProperty(relPath, source, rules, ruleSpan, property);
    case "set-rule-selector":
      return applySetRuleSelector(relPath, rules, ruleSpan, selector);
    case "add-style-rule":
      return applyAddStyleRule(relPath, source, styleElements, selector, media, declarations);
    default:
      return refuse("invalid-input", `unsupported component-style op: ${edit.op}`);
  }
}

function collectStyleElements(node, out) {
  if (node.type === "element" && node.name === "style") out.push(node);
  for (const child of node.children ?? []) collectStyleElements(child, out);
}

function findRule(rules, ruleSpan) {
  if (!Array.isArray(ruleSpan) || ruleSpan.length !== 2) return undefined;
  return rules.find((r) => r.span[0] === ruleSpan[0] && r.span[1] === ruleSpan[1]);
}

function applySetStyleProperty(file, rules, ruleSpan, property, value) {
  if (typeof property !== "string" || typeof value !== "string") {
    return refuse("invalid-input", "set-style-property requires component.property and component.value");
  }
  const rule = findRule(rules, ruleSpan);
  if (!rule) return refuse("no-match", "no rule found at the given span — the file may have changed");

  const existing = rule.declarations.find((d) => d.property === property);
  if (existing) {
    return { file, range: { start: existing.span[0], end: existing.span[1] }, replacement: `${property}: ${value}` };
  }
  const insertAt = rule.blockInner[1];
  return { file, range: { start: insertAt, end: insertAt }, replacement: `\n  ${property}: ${value};` };
}

function applyRemoveStyleProperty(file, source, rules, ruleSpan, property) {
  if (typeof property !== "string") {
    return refuse("invalid-input", "remove-style-property requires component.property");
  }
  const rule = findRule(rules, ruleSpan);
  if (!rule) return refuse("no-match", "no rule found at the given span — the file may have changed");

  const decl = rule.declarations.find((d) => d.property === property);
  if (!decl) return refuse("no-match", `no declaration for property "${property}" on this rule`);

  let end = decl.span[1];
  while (end < source.length && source[end] !== ";" && source[end] !== "}") end++;
  if (source[end] === ";") end++;

  let start = decl.span[0];
  while (start > 0 && (source[start - 1] === " " || source[start - 1] === "\t")) start--;
  if (start > 0 && source[start - 1] === "\n") start--;

  return { file, range: { start, end }, replacement: "" };
}

function applySetRuleSelector(file, rules, ruleSpan, selector) {
  if (typeof selector !== "string" || selector.trim() === "") {
    return refuse("invalid-input", "set-rule-selector requires a non-empty component.selector");
  }
  const rule = findRule(rules, ruleSpan);
  if (!rule) return refuse("no-match", "no rule found at the given span — the file may have changed");

  return { file, range: { start: rule.preludeSpan[0], end: rule.preludeSpan[1] }, replacement: selector };
}

function applyAddStyleRule(file, source, styleElements, selector, media, declarations) {
  if (typeof selector !== "string" || selector.trim() === "") {
    return refuse("invalid-input", "add-style-rule requires a non-empty component.selector");
  }
  const decls = Array.isArray(declarations) ? declarations : [];
  const body = decls.map((d) => `  ${d.property}: ${d.value};`).join("\n");
  const rule = media
    ? `@media ${media} {\n  ${selector} {\n${body ? body.split("\n").map((l) => "  " + l).join("\n") + "\n" : ""}  }\n}`
    : `${selector} {\n${body ? body + "\n" : ""}}`;

  const lastStyle = styleElements[styleElements.length - 1];
  if (!lastStyle) {
    return { file, range: { start: source.length, end: source.length }, replacement: `\n<style>\n${rule}\n</style>\n` };
  }
  const textChild = (lastStyle.children ?? []).find((c) => c.type === "text");
  const insertAt = textChild?.position?.end?.offset ?? lastStyle.position.end.offset;
  return { file, range: { start: insertAt, end: insertAt }, replacement: `\n\n${rule}` };
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
npm test -- tests/component-style-edit.test.ts
```

Expected: PASS, all 8 cases.

- [ ] **Step 5: Commit**

```bash
git add server/component-style-edit.mjs tests/component-style-edit.test.ts
git commit -m "feat(mcp): add span-based CSS write resolver for the four component-style ops"
```

### Task 5: Wire the dispatcher

**Files:**
- Modify: `server/patcher.mjs`
- Modify: `server/apply-edit-dispatcher.mjs`

**Interfaces:**
- Consumes: `resolveComponentStyle` (Task 4), `COMPONENT_STYLE_OPS` (Task 3), `buildComponentModel` (existing, `component-model.mjs`).
- Produces: component-style ops missing a `component` payload fail fast with `invalid-input`; successful component-style edits piggyback `model` on the `edit-applied` reply.

- [ ] **Step 1: Write the failing test**

Create `tests/apply-edit-dispatcher-component-style.test.ts`:

```typescript
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { applyEdit } from "../server/apply-edit-dispatcher.mjs";
import { fileVersion } from "../server/file-version.mjs";

const CARD = `---\n---\n<article class="card"><slot /></article>\n\n<style>\n  .card { padding: 1rem; }\n</style>\n`;

function parseContent(response) {
  return JSON.parse(response.content[0].text);
}

describe("applyEdit — component-style ops", () => {
  let tmpDir;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "anglesite-aed-"));
    mkdirSync(join(tmpDir, "src", "components"), { recursive: true });
    writeFileSync(join(tmpDir, "src", "components", "Card.astro"), CARD);
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("rejects a component-style op with no component payload", async () => {
    const response = await applyEdit(tmpDir, { id: "1", path: "x", op: "set-style-property", value: {} });
    expect(response.isError).toBe(true);
    const body = parseContent(response);
    expect(body.reason).toBe("invalid-input");
  });

  it("applies set-style-property and piggybacks a fresh model", async () => {
    const baseVersion = fileVersion(CARD);
    const { indexCssRules } = await import("../server/css-rule-index.mjs");
    const { parse } = await import("@astrojs/compiler");
    const { ast } = await parse(CARD, { position: true });
    const styleEl = ast.children.find((n) => n.type === "element" && n.name === "style");
    const [cardRule] = indexCssRules(styleEl);

    const response = await applyEdit(tmpDir, {
      id: "1",
      path: "src/components/Card.astro",
      op: "set-style-property",
      component: { path: "src/components/Card.astro", baseVersion, ruleSpan: cardRule.span, property: "color", value: "blue" },
    });
    expect(response.isError).toBeFalsy();
    const body = parseContent(response);
    expect(body.type).toBe("anglesite:edit-applied");
    expect(body.model).toBeDefined();
    expect(body.model.styles[0].declarations.some((d) => d.property === "color" && d.value === "blue")).toBe(true);
  });

  it("surfaces stale as a failed reply", async () => {
    const response = await applyEdit(tmpDir, {
      id: "1",
      path: "src/components/Card.astro",
      op: "set-style-property",
      component: { path: "src/components/Card.astro", baseVersion: "sha256:000000000000", ruleSpan: [0, 1], property: "color", value: "blue" },
    });
    expect(response.isError).toBe(true);
    const body = parseContent(response);
    expect(body.reason).toBe("stale");
  });
});
```

- [ ] **Step 2: Run to verify it fails**

```bash
npm test -- tests/apply-edit-dispatcher-component-style.test.ts
```

Expected: FAIL — `set-style-property` isn't dispatched yet, and `model` isn't piggybacked.

- [ ] **Step 3: Wire `patcher.mjs`**

In `server/patcher.mjs`, add the import and a dispatch branch ahead of the fallback resolver chain:

```javascript
import { resolveComponentStyle } from "./component-style-edit.mjs";
import { COMPONENT_STYLE_OPS } from "./apply-edit-schema.mjs";
```

```javascript
export function resolve(projectRoot, edit) {
  if (edit.op === "edit-style") {
    return resolveStyle(projectRoot, edit);
  }
  if (COMPONENT_STYLE_OPS.has(edit.op)) {
    return resolveComponentStyle(projectRoot, edit);
  }
  // ... existing fallback chain (resolveMdoc, resolveKeystatic, resolveAstro) unchanged
}
```

Note `resolveComponentStyle` is `async` — confirm the caller (`apply-edit-dispatcher.mjs`'s `applyEdit`) already `await`s `resolve(...)` (it must, since the result feeds `resolution.refused`/`resolution.file` synchronously after). If the existing call site does not await, add `await`.

- [ ] **Step 4: Reject missing `component` payload early, and piggyback the model, in `apply-edit-dispatcher.mjs`**

Add near the top of the file:

```javascript
import { COMPONENT_STYLE_OPS } from "./apply-edit-schema.mjs";
import { buildComponentModel } from "./component-model.mjs";
```

In `applyEdit(projectRoot, edit, opts = {})`, add this check immediately after the existing `apply-instruction` early return:

```javascript
if (COMPONENT_STYLE_OPS.has(edit.op) && !edit.component) {
  return failed(edit.id, "invalid-input", `op ${edit.op} requires a component payload`);
}
```

Change the success path so component-style ops fetch a fresh model. Find where `commit` is computed and `applied(...)` is returned; thread a `model` through:

```javascript
let model;
if (COMPONENT_STYLE_OPS.has(edit.op)) {
  try {
    model = await buildComponentModel(projectRoot, edit.component.path);
  } catch {
    model = undefined; // best-effort — a failed refetch shouldn't fail an already-applied edit
  }
}

return applied(edit.id, file, range, commit, imageResult ? { src: imageResult.src, srcset: imageResult.srcset } : undefined, model);
```

Update the local `applied` helper and `createEditAppliedContent` (in `apply-edit-schema.mjs`) to accept and forward the optional `model`:

```javascript
// apply-edit-dispatcher.mjs
function applied(id, file, range, commit, result, model) {
  return { content: [createEditAppliedContent(id, file, range, commit, result, model)] };
}
```

```javascript
// apply-edit-schema.mjs
export function createEditAppliedContent(id, file, range, commit, result, model) {
  const body = { type: "anglesite:edit-applied", id, file, range };
  if (commit !== undefined) body.commit = commit;
  if (result !== undefined) body.result = result;
  if (model !== undefined) body.model = model;
  return { type: "text", text: JSON.stringify(body) };
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
npm test -- tests/apply-edit-dispatcher-component-style.test.ts
```

Expected: PASS, all 3 cases.

- [ ] **Step 6: Run the full plugin test suite to check for regressions**

```bash
npm test
```

Expected: all existing tests still pass (in particular `apply-edit-dispatcher.test.js` and `patcher.test.js` — the `model` param is additive/optional everywhere).

- [ ] **Step 7: Commit**

```bash
git add server/patcher.mjs server/apply-edit-dispatcher.mjs server/apply-edit-schema.mjs tests/apply-edit-dispatcher-component-style.test.ts
git commit -m "feat(mcp): dispatch component-style ops and piggyback a fresh model on success"
```

### Task 6: `mcp-server.test.ts` round trip + CHANGELOG

**Files:**
- Modify: `tests/mcp-server.test.ts`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: the live stdio MCP server (existing test harness pattern already used for `get_component_model`'s round trip — follow the same setup).

- [ ] **Step 1: Write the failing test**

In `tests/mcp-server.test.ts`, find the existing `get_component_model` stdio round-trip test and add a sibling test after it (reusing whatever fixture-project helper that test already sets up):

```typescript
it("apply_edit set-style-property round trip returns a piggybacked model", async () => {
  // Reuse this file's existing fixture-project setup (same tmp project used by the
  // get_component_model round-trip test above) and its existing `client.callTool` helper.
  const modelResult = await client.callTool({ name: "get_component_model", arguments: { path: "src/components/Card.astro" } });
  const model = JSON.parse(modelResult.content[0].text);
  const rule = model.styles[0];

  const editResult = await client.callTool({
    name: "apply_edit",
    arguments: {
      id: "rt-1",
      path: "src/components/Card.astro",
      op: "set-style-property",
      component: { path: "src/components/Card.astro", baseVersion: model.version, ruleSpan: rule.span, property: "color", value: "blue" },
    },
  });
  const body = JSON.parse(editResult.content[0].text);
  expect(body.type).toBe("anglesite:edit-applied");
  expect(body.model.styles[0].declarations.some((d) => d.property === "color" && d.value === "blue")).toBe(true);
});
```

- [ ] **Step 2: Run to verify it fails, then passes**

```bash
npm test -- tests/mcp-server.test.ts
```

Expected: FAIL first (no such round trip wired), then re-run after nothing further needs to change here (Tasks 3–5 already implement the server side) — PASS. If it still fails, re-check the fixture project used by this test file actually contains a `<style>` block on `Card.astro`; add one if not.

- [ ] **Step 3: Update `CHANGELOG.md`**

Add an entry under `Unreleased` (or create it if the top entry is already a released version):

```markdown
## Unreleased

### Added
- `apply_edit` gains four component-style ops — `set-style-property`, `remove-style-property`, `add-style-rule`, `set-rule-selector` — with content-hash (`baseVersion`) staleness checking. Successful component-style edits piggyback a freshly rebuilt `get_component_model` result on the reply.
```

- [ ] **Step 4: Commit**

```bash
git add tests/mcp-server.test.ts CHANGELOG.md
git commit -m "test(mcp): add apply_edit component-style round trip; update changelog"
```

### Task 7: Full plugin regression pass

**Files:** none new.

- [ ] **Step 1: Run the entire plugin test suite**

```bash
npm test
```

Expected: 100% pass, no regressions from Tasks 1–6.

- [ ] **Step 2: Lint/typecheck if configured**

```bash
npm run lint --if-present
npm run typecheck --if-present
```

Expected: clean.

- [ ] **Step 3: Push the branch**

```bash
git push -u origin feat/component-style-ops
```

### Task 8: Version bump, release, PR checkpoint

**Files:**
- Modify: `package.json` (version bump — minor, per semver: new backward-compatible tool capability)
- Modify: `CHANGELOG.md` (move `Unreleased` entry under the new version heading)

- [ ] **Step 1: Bump version**

```bash
npm version minor --no-git-tag-version
```

- [ ] **Step 2: Finalize CHANGELOG heading**

Move the Task 6 `## Unreleased` entry's content under the new version number and date, matching the format of the existing `1.3.0` entry above it.

- [ ] **Step 3: Commit**

```bash
git add package.json package-lock.json CHANGELOG.md
git commit -m "chore: release v<new-version>"
```

- [ ] **Step 4: Open the PR**

```bash
gh pr create --title "feat: component-style write ops (Component Editor slice 2)" --body "Adds set-style-property, remove-style-property, add-style-rule, set-rule-selector to apply_edit, with content-hash staleness checking and a piggybacked model on success. Prerequisite for Anglesite-app's Styles panel (issue #492)."
```

- [ ] **Step 5: Checkpoint — get user go-ahead before merging and tagging**

Stop here. Do not merge to `main`, tag, or publish the release without explicit confirmation. Once approved and merged, note the new version number — Part B's Task 15 bumps the app's `MIN_PLUGIN_VERSION` to it.

---

# Part B — App repo

All Part B tasks run in an app-repo worktree. This plan assumes the worktree already used for exploration (`/Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/focused-shaw-9f716a`) is reused; if starting fresh, create one via `superpowers:using-git-worktrees`, then:

```bash
cd <worktree>
xcodegen generate
ANGLESITE_PLUGIN_SRC=/Users/dwk/Developer/github.com/Anglesite/anglesite scripts/copy-plugin.sh
```

Re-run `copy-plugin.sh` after Part A's PR merges, so `Resources/plugin` picks up the new ops.

### Task 9: Wire the real `EditRouter` into the Component Editor

**Files:**
- Modify: `Sources/AnglesiteApp/ComponentEditorModel.swift` (`ComponentEditorContext` gains `editRouter`)
- Modify: `Sources/AnglesiteApp/ComponentEditorView.swift` (`ComponentCanvasView` uses it instead of `LoggingEditRouter()`)
- Modify: whichever call site constructs `ComponentEditorContext` today (the `MainPaneEditorView`/site-window `.component` case) to populate `editRouter` the same way `PreviewModel.editRouter` is populated — search for `PreviewModel.editRouter =` to find the exact pattern and mirror it: `MCPApplyEditRouter(mcpClient: { [weak runtime] in await runtime?.mcpClient })`.
- Test: `Tests/AnglesiteCoreTests/ComponentEditorContextTests.swift` (create, if `ComponentEditorContext` lives in `AnglesiteCore`; otherwise add to wherever `ComponentEditorModel`'s existing tests live)

**Interfaces:**
- Produces: `ComponentEditorContext.editRouter: EditRouter?` (mirrors the existing `modelClient: ComponentModelClient?` field exactly — same optionality, same "nil until wired" pattern).

- [ ] **Step 1: Read the current files first**

```bash
cd <worktree>
grep -n "editRouter" Sources/AnglesiteApp/PreviewModel.swift
grep -n "struct ComponentEditorContext" -A 10 Sources/AnglesiteApp/ComponentEditorModel.swift
grep -n "LoggingEditRouter" Sources/AnglesiteApp/ComponentEditorView.swift
```

Confirm the exact `PreviewModel.editRouter` construction line and the exact current `ComponentEditorContext` struct body before editing — this task's diff must match the surrounding code's existing style precisely (open both files with Read before editing).

- [ ] **Step 2: Write the failing test**

Add to whichever test file already covers `ComponentEditorContext`/`ComponentEditorModel` construction (find via `grep -rn "ComponentEditorContext(" Tests/`):

```swift
@Test("ComponentEditorContext carries an EditRouter for write ops")
func contextCarriesEditRouter() {
    var applied: EditMessage?
    let router = RecordingEditRouter { message in
        applied = message
        return EditReply(id: message.id, status: .applied, message: nil)
    }
    let context = ComponentEditorContext(baseURL: nil, modelClient: nil, sourceRoot: URL(fileURLWithPath: "/tmp"), editRouter: router)
    #expect(context.editRouter != nil)
}

/// Test-only EditRouter that records the last message and replies with a fixed EditReply.
private struct RecordingEditRouter: EditRouter {
    let reply: (EditMessage) -> EditReply
    func apply(_ message: EditMessage) async -> EditReply { reply(message) }
}
```

(If `EditRouter`'s protocol requirement is `func apply(_ message: EditMessage) async -> EditReply` with a different exact signature, adjust to match — confirm via `grep -n "protocol EditRouter" -A 5 Sources/AnglesiteCore/EditRouter.swift` before writing this step for real.)

- [ ] **Step 3: Run to verify it fails**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ComponentEditorContext
```

Expected: FAIL — `ComponentEditorContext` has no `editRouter` parameter yet.

- [ ] **Step 4: Add the field**

In `Sources/AnglesiteApp/ComponentEditorModel.swift`, add `editRouter` to `ComponentEditorContext`:

```swift
struct ComponentEditorContext {
    let baseURL: URL?
    let modelClient: ComponentModelClient?
    let sourceRoot: URL
    let editRouter: EditRouter?
}
```

Update every existing call site that constructs `ComponentEditorContext(...)` (both production and test) to pass `editRouter:` — production call sites get the real `MCPApplyEditRouter` (Step 6 below); existing tests that don't care about writes pass `editRouter: nil`.

- [ ] **Step 5: Replace `LoggingEditRouter()` in the canvas**

In `Sources/AnglesiteApp/ComponentEditorView.swift`, in `ComponentCanvasView.makeNSView`, change:

```swift
let handler = AnglesiteScriptHandler(
    router: LoggingEditRouter(),
    ...
)
```

to route through the context's real router, falling back to `LoggingEditRouter()` only when none is configured (keeps existing previews/tests that pass `editRouter: nil` working without a crash):

```swift
let handler = AnglesiteScriptHandler(
    router: context.editRouter ?? LoggingEditRouter(),
    ...
)
```

(Adjust to however `context`/`editRouter` is actually threaded into `ComponentCanvasView` — it may need a new parameter on the view itself if it isn't already passed down from `ComponentEditorView`; check how `modelClient` currently reaches this view and mirror that exact plumbing.)

- [ ] **Step 6: Populate the real router at the construction call site**

Find where `ComponentEditorContext(...)` is built for real use (search `grep -rn "ComponentEditorContext(" Sources/AnglesiteApp/` for the non-test call site — likely in `MainPaneEditorView.swift` or wherever the `.component` `EditorKind` case is handled). Add, mirroring `PreviewModel`'s exact pattern found in Step 1:

```swift
editRouter: MCPApplyEditRouter(mcpClient: { [weak runtime] in
    await runtime?.mcpClient
})
```

- [ ] **Step 7: Run tests to verify they pass**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .
```

Expected: full suite passes, including the new test and all previously-passing `ComponentEditorModel`/`ComponentEditorView`-adjacent tests (which now need `editRouter: nil` added to their `ComponentEditorContext(...)` calls — fix any compile errors this surfaces).

- [ ] **Step 8: Commit**

```bash
git add Sources/AnglesiteApp/ComponentEditorModel.swift Sources/AnglesiteApp/ComponentEditorView.swift Tests/
git commit -m "feat(app): wire a real MCPApplyEditRouter into the Component Editor harness canvas"
```

### Task 10: `EditMessage`/`EditReply` — component payload and piggybacked model

**Files:**
- Modify: `Sources/AnglesiteCore/EditMessage.swift`
- Modify: `Sources/AnglesiteCore/EditRouter.swift`
- Modify: `Tests/AnglesiteCoreTests/EditMessageTests.swift`
- Modify: `Tests/AnglesiteCoreTests/EditReplyAndRouterTests.swift`

**Interfaces:**
- Produces: `EditMessage.Op` gains `setStyleProperty`, `removeStyleProperty`, `addStyleRule`, `setRuleSelector` string constants. `EditMessage` gains `component: JSONValue?`; `selector` becomes `JSONValue?` (optional). `EditMessage.jsonValue` emits `selector`/`component` only when present.
- Produces: `EditReply` gains `model: ComponentModel?`. `MCPApplyEditRouter.parseStructured`'s `Parsed` struct gains a `model` field, decoded via `JSONDecoder` from the `model` key of the raw JSON when present.

- [ ] **Step 1: Read the current files first**

```bash
cat Sources/AnglesiteCore/EditMessage.swift
cat Sources/AnglesiteCore/EditRouter.swift
```

Confirm the exact current `EditMessage.Op` enum, `EditMessage.decode(from:)` implementation, `EditMessage.jsonValue`, `EditReply` struct, and `MCPApplyEditRouter.parseStructured`/`Parsed` before editing — this task's diffs below describe the target end-state; adapt field ordering/style to match what's actually there.

- [ ] **Step 2: Write the failing tests**

Add to `Tests/AnglesiteCoreTests/EditMessageTests.swift`:

```swift
@Test("New component-style op constants exist")
func componentStyleOpConstants() {
    #expect(EditMessage.Op.setStyleProperty == "set-style-property")
    #expect(EditMessage.Op.removeStyleProperty == "remove-style-property")
    #expect(EditMessage.Op.addStyleRule == "add-style-rule")
    #expect(EditMessage.Op.setRuleSelector == "set-rule-selector")
}

@Test("A component-style message encodes component and omits selector")
func componentMessageEncoding() {
    let message = EditMessage(
        id: "1",
        path: "src/components/Card.astro",
        selector: nil,
        op: EditMessage.Op.setStyleProperty,
        component: .object([
            "path": .string("src/components/Card.astro"),
            "baseVersion": .string("sha256:abc123456789"),
            "ruleSpan": .array([.number(10), .number(40)]),
            "property": .string("color"),
            "value": .string("red"),
        ]),
        value: nil
    )
    let wire = message.jsonValue
    guard case .object(let dict) = wire else { Issue.record("expected object"); return }
    #expect(dict["selector"] == nil)
    #expect(dict["component"] != nil)
}

@Test("A legacy replace-attr message still decodes with selector and no component")
func legacyMessageStillDecodes() {
    let body: [String: Any] = [
        "id": "1", "type": "anglesite:apply-edit", "path": "/about/",
        "selector": ["tag": "h1", "classes": [], "nthChild": 1],
        "op": "replace-attr", "value": ["name": "class", "value": "big"],
    ]
    switch EditMessage.decode(from: body) {
    case .success(let message):
        #expect(message.component == nil)
    case .failure(let error):
        Issue.record("expected decode success, got \(error)")
    }
}
```

Add to `Tests/AnglesiteCoreTests/EditReplyAndRouterTests.swift`:

```swift
@Test("parseStructured decodes a piggybacked model")
func parseStructuredDecodesModel() {
    let json = """
    {"type":"anglesite:edit-applied","id":"1","file":"src/components/Card.astro","range":{"start":0,"end":1},"model":\(ComponentModelTests.fixture)}
    """
    let parsed = MCPApplyEditRouter.parseStructured(json)
    #expect(parsed?.model?.path == "src/components/Card.astro")
}
```

(`ComponentModelTests.fixture` already exists per slice 1 — reuse it rather than inlining a new JSON blob.)

- [ ] **Step 3: Run to verify they fail**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter "EditMessageTests|EditReplyAndRouterTests"
```

Expected: FAIL — compile errors (`component` param/property doesn't exist yet).

- [ ] **Step 4: Add the `Op` constants**

In `Sources/AnglesiteCore/EditMessage.swift`, extend the `Op` namespace:

```swift
public enum Op {
    public static let replaceText = "replace-text"
    public static let replaceImageSrc = "replace-image-src"
    public static let replaceAttr = "replace-attr"
    public static let applyInstruction = "apply-instruction"
    public static let setStyleProperty = "set-style-property"
    public static let removeStyleProperty = "remove-style-property"
    public static let addStyleRule = "add-style-rule"
    public static let setRuleSelector = "set-rule-selector"
}
```

- [ ] **Step 5: Add the `component` field, make `selector` optional**

Change `EditMessage`'s stored properties so `selector` is optional and a new `component` field exists:

```swift
public var selector: JSONValue?
public var component: JSONValue?
```

Update the memberwise initializer to add `component: JSONValue? = nil` with `selector: JSONValue? = nil` (both defaulting to nil so every existing call site that only sets `selector` keeps compiling).

Update `decode(from:)`: change the `guard let rawSelector = dict["selector"] ...` block from a hard failure to an optional decode (selector present → decode it; absent → nil), and add a symmetric optional decode for `component`:

```swift
let selector: JSONValue?
if let rawSelector = dict["selector"] {
    guard let jv = JSONValue.from(rawSelector), case .object = jv else {
        return .failure(.invalidField("selector"))
    }
    selector = jv
} else {
    selector = nil
}

let component: JSONValue?
if let rawComponent = dict["component"] {
    guard let jv = JSONValue.from(rawComponent), case .object = jv else {
        return .failure(.invalidField("component"))
    }
    component = jv
} else {
    component = nil
}
```

Wire both into the constructed `EditMessage(...)` at the end of `decode(from:)`.

Update `jsonValue` to emit each key only when non-nil (matching the existing conditional pattern already used for `value`/`dryRun` in this same computed property — mirror that exact style):

```swift
var dict: [String: JSONValue] = ["id": .string(id), "type": .string(type), "path": .string(path), "op": .string(op)]
if let selector { dict["selector"] = selector }
if let component { dict["component"] = component }
// ... existing value/dry_run conditional inserts unchanged
return .object(dict)
```

- [ ] **Step 6: Add `model` to `EditReply` and decode it in `parseStructured`**

In `Sources/AnglesiteCore/EditRouter.swift`, add to `EditReply`:

```swift
public var model: ComponentModel?
```

with a default of `nil` in its initializer so every existing call site keeps compiling.

In `MCPApplyEditRouter.parseStructured`'s `Parsed` struct, add `let model: ComponentModel?`, and in the function body, after pulling `file`/`commit`/`result` out of the `JSONSerialization`-parsed dictionary, add:

```swift
var model: ComponentModel?
if let modelDict = json["model"] {
    if let modelData = try? JSONSerialization.data(withJSONObject: modelDict) {
        model = try? JSONDecoder().decode(ComponentModel.self, from: modelData)
    }
}
```

Thread `parsed?.model` into the `EditReply(...)` constructions in `apply(_:)` (both the `.applied` and `.failed` branches, matching how `parsed?.file`/`parsed?.commit`/`parsed?.result` are already threaded).

- [ ] **Step 7: Run tests to verify they pass**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .
```

Expected: full suite passes. Fix any other call sites broken by `selector` becoming optional (the compiler will point to them).

- [ ] **Step 8: Commit**

```bash
git add Sources/AnglesiteCore/EditMessage.swift Sources/AnglesiteCore/EditRouter.swift Tests/AnglesiteCoreTests/EditMessageTests.swift Tests/AnglesiteCoreTests/EditReplyAndRouterTests.swift
git commit -m "feat(app): add component-style op constants, component payload, and piggybacked model decode"
```

### Task 11: `ComponentEditorModel` write methods

**Files:**
- Modify: `Sources/AnglesiteApp/ComponentEditorModel.swift`
- Create: `Tests/AnglesiteCoreTests/ComponentEditorModelStyleEditTests.swift` (or alongside wherever `ComponentEditorModel`'s existing tests live if it's not in `AnglesiteCoreTests` — check first; if the type is `AnglesiteApp`-only and untestable in the hosted-CI sense per this repo's constraint, put the logic under test in a small `AnglesiteCore` helper type instead, e.g. `ComponentStyleEditBuilder`, and have `ComponentEditorModel` call it)

**Interfaces:**
- Produces: `ComponentEditorModel.setStyleProperty(ruleSpan:property:value:) async`, `.removeStyleProperty(ruleSpan:property:) async`, `.addStyleRule(selector:media:declarations:) async`, `.setRuleSelector(ruleSpan:newSelector:) async`. Each builds an `EditMessage`, calls `context.editRouter?.apply(_:)`, and on `.applied` with a non-nil `reply.model` adopts it directly (no second fetch); on `.failed` with a stale-looking message, calls `load()` to refetch and surfaces a conflict flag.
- Consumes: `EditMessage`/`EditReply.model` (Task 10), `context.editRouter` (Task 9).

- [ ] **Step 1: Read the current file and decide the testable-core split**

```bash
grep -n "final class ComponentEditorModel" -A 40 Sources/AnglesiteApp/ComponentEditorModel.swift
```

Per this repo's CI constraint (app-target logic must stay thin — testable types live in `AnglesiteCore`), factor the pure "build the wire payload" logic into a small `AnglesiteCore` type so it's testable without a hosted app target:

Create `Sources/AnglesiteCore/ComponentStyleEditBuilder.swift`:

```swift
import Foundation

/// Builds the wire-format EditMessage payloads for the four component-style ops.
/// Pure and testable — no MCP/router dependency. ComponentEditorModel (AnglesiteApp)
/// calls this to construct the message, then hands it to `context.editRouter`.
public enum ComponentStyleEditBuilder {
    public static func setStyleProperty(id: String, path: String, baseVersion: String, ruleSpan: [Int?], property: String, value: String) -> EditMessage {
        EditMessage(
            id: id,
            path: path,
            selector: nil,
            op: EditMessage.Op.setStyleProperty,
            component: .object([
                "path": .string(path),
                "baseVersion": .string(baseVersion),
                "ruleSpan": .array(ruleSpan.map { $0.map(JSONValue.number(_:)) ?? .null }),
                "property": .string(property),
                "value": .string(value),
            ]),
            value: nil
        )
    }

    public static func removeStyleProperty(id: String, path: String, baseVersion: String, ruleSpan: [Int?], property: String) -> EditMessage {
        EditMessage(
            id: id,
            path: path,
            selector: nil,
            op: EditMessage.Op.removeStyleProperty,
            component: .object([
                "path": .string(path),
                "baseVersion": .string(baseVersion),
                "ruleSpan": .array(ruleSpan.map { $0.map(JSONValue.number(_:)) ?? .null }),
                "property": .string(property),
            ]),
            value: nil
        )
    }

    public static func setRuleSelector(id: String, path: String, baseVersion: String, ruleSpan: [Int?], newSelector: String) -> EditMessage {
        EditMessage(
            id: id,
            path: path,
            selector: nil,
            op: EditMessage.Op.setRuleSelector,
            component: .object([
                "path": .string(path),
                "baseVersion": .string(baseVersion),
                "ruleSpan": .array(ruleSpan.map { $0.map(JSONValue.number(_:)) ?? .null }),
                "selector": .string(newSelector),
            ]),
            value: nil
        )
    }

    public static func addStyleRule(id: String, path: String, baseVersion: String, selector: String, media: String?, declarations: [(property: String, value: String)]) -> EditMessage {
        var payload: [String: JSONValue] = [
            "path": .string(path),
            "baseVersion": .string(baseVersion),
            "selector": .string(selector),
            "declarations": .array(declarations.map { .object(["property": .string($0.property), "value": .string($0.value)]) }),
        ]
        if let media { payload["media"] = .string(media) }
        return EditMessage(id: id, path: path, selector: nil, op: EditMessage.Op.addStyleRule, component: .object(payload), value: nil)
    }
}
```

(Adjust `JSONValue.number`/`.null` case names to whatever `JSONValue`'s actual enum cases are — check `Sources/AnglesiteCore/JSONValue.swift` first; the shape above assumes cases named `.string`, `.number(Double)`, `.array`, `.object`, `.null`, matching the encodings already used elsewhere in this exploration's quoted code, e.g. `.object(["path": .string(path)])`.)

- [ ] **Step 2: Write the failing tests**

Create `Tests/AnglesiteCoreTests/ComponentStyleEditBuilderTests.swift`:

```swift
import Testing
@testable import AnglesiteCore

struct ComponentStyleEditBuilderTests {
    @Test("setStyleProperty builds a component payload with no selector")
    func setStyleProperty() {
        let message = ComponentStyleEditBuilder.setStyleProperty(id: "1", path: "src/components/Card.astro", baseVersion: "sha256:abc123456789", ruleSpan: [10, 40], property: "color", value: "red")
        #expect(message.op == "set-style-property")
        #expect(message.selector == nil)
        guard case .object(let component)? = message.component else { Issue.record("expected component object"); return }
        #expect(component["property"] == .string("color"))
        #expect(component["value"] == .string("red"))
    }

    @Test("addStyleRule includes declarations and omits media when nil")
    func addStyleRuleNoMedia() {
        let message = ComponentStyleEditBuilder.addStyleRule(id: "1", path: "src/components/Card.astro", baseVersion: "sha256:abc123456789", selector: "h2", media: nil, declarations: [("font-weight", "bold")])
        guard case .object(let component)? = message.component else { Issue.record("expected component object"); return }
        #expect(component["media"] == nil)
        #expect(component["declarations"] != nil)
    }
}
```

- [ ] **Step 3: Run to verify they fail**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ComponentStyleEditBuilderTests
```

Expected: FAIL — type doesn't exist.

- [ ] **Step 4: Implement `ComponentStyleEditBuilder`** (code above) and run to verify PASS.

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ComponentStyleEditBuilderTests
```

- [ ] **Step 5: Add the write methods to `ComponentEditorModel`**

In `Sources/AnglesiteApp/ComponentEditorModel.swift`, add:

```swift
func setStyleProperty(ruleSpan: [Int?], property: String, value: String) async {
    await applyComponentStyleEdit(
        ComponentStyleEditBuilder.setStyleProperty(id: UUID().uuidString, path: context.modelClient == nil ? "" : (model?.path ?? ""), baseVersion: model?.version ?? "", ruleSpan: ruleSpan, property: property, value: value)
    )
}

func removeStyleProperty(ruleSpan: [Int?], property: String) async {
    await applyComponentStyleEdit(
        ComponentStyleEditBuilder.removeStyleProperty(id: UUID().uuidString, path: model?.path ?? "", baseVersion: model?.version ?? "", ruleSpan: ruleSpan, property: property)
    )
}

func setRuleSelector(ruleSpan: [Int?], newSelector: String) async {
    await applyComponentStyleEdit(
        ComponentStyleEditBuilder.setRuleSelector(id: UUID().uuidString, path: model?.path ?? "", baseVersion: model?.version ?? "", ruleSpan: ruleSpan, newSelector: newSelector)
    )
}

func addStyleRule(selector: String, media: String?, declarations: [(property: String, value: String)]) async {
    await applyComponentStyleEdit(
        ComponentStyleEditBuilder.addStyleRule(id: UUID().uuidString, path: model?.path ?? "", baseVersion: model?.version ?? "", selector: selector, media: media, declarations: declarations)
    )
}

private func applyComponentStyleEdit(_ message: EditMessage) async {
    guard let editRouter = context.editRouter else { return }
    let reply = await editRouter.apply(message)
    switch reply.status {
    case .applied:
        if let freshModel = reply.model {
            model = freshModel
        } else {
            await load()
        }
        conflict = false
    case .failed where (reply.message ?? "").contains("stale"):
        conflict = true
        await load()
    default:
        loadErrorReason = reply.message
    }
}
```

Add a `conflict: Bool = false` published property to `ComponentEditorModel` for the "changed outside Anglesite — Reload" banner the design doc calls for (§5), if one doesn't already exist under a different name — check first (`grep -n "conflict\|external.*edit\|stale" Sources/AnglesiteApp/ComponentEditorModel.swift`).

(This step's exact field names — `model?.path`, `model?.version`, `loadErrorReason` — must match whatever `ComponentEditorModel` actually calls its properties; re-read the file per Task 9 Step 1's instruction before finalizing this diff.)

- [ ] **Step 6: Run the full test suite**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteCore/ComponentStyleEditBuilder.swift Sources/AnglesiteApp/ComponentEditorModel.swift Tests/AnglesiteCoreTests/ComponentStyleEditBuilderTests.swift
git commit -m "feat(app): add ComponentEditorModel write methods for the four component-style ops"
```

### Task 12: Editable Styles panel — declaration rows

**Files:**
- Modify: `Sources/AnglesiteApp/ComponentEditorView.swift`

**Interfaces:**
- Consumes: `ComponentEditorModel.setStyleProperty`/`.removeStyleProperty`/`.setRuleSelector` (Task 11), `ComponentModel.StyleRule`/`.Declaration` (existing, slice 1).
- Produces: the "Styles" `GroupBox` becomes an editable list — each declaration is a property/value text-field row with a delete button; each rule has an editable selector field and a "delete rule" affordance is deferred (no `remove-style-rule` op exists — out of scope; only declaration-level remove and selector rename ship this slice, matching the four ops actually implemented).

- [ ] **Step 1: Read the current inspector code**

```bash
grep -n 'GroupBox("Styles")' -A 20 Sources/AnglesiteApp/ComponentEditorView.swift
```

- [ ] **Step 2: Replace the read-only rendering with editable rows**

Replace the `GroupBox("Styles") { ... }` block (quoted in full during exploration) with:

```swift
GroupBox("Styles") {
    if let styles = model.model?.styles, !styles.isEmpty {
        ForEach(Array(styles.enumerated()), id: \.offset) { ruleIndex, rule in
            VStack(alignment: .leading, spacing: 4) {
                if let media = rule.media {
                    Text("@media \(media)").font(.caption2).foregroundStyle(.secondary)
                }
                TextField("selector", text: selectorBinding(for: rule))
                    .font(.system(.caption, design: .monospaced))
                    .textFieldStyle(.plain)
                    .bold()
                    .onSubmit {
                        Task { await model.setRuleSelector(ruleSpan: rule.span, newSelector: selectorDrafts[rule.span.description] ?? rule.selector) }
                    }
                ForEach(Array(rule.declarations.enumerated()), id: \.offset) { declIndex, decl in
                    HStack(spacing: 4) {
                        TextField("property", text: propertyBinding(for: rule, decl: decl))
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 110)
                        Text(":")
                        declarationValueField(for: rule, decl: decl)
                        Button(role: .destructive) {
                            Task { await model.removeStyleProperty(ruleSpan: rule.span, property: decl.property) }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button("Add declaration") {
                    Task { await model.setStyleProperty(ruleSpan: rule.span, property: "new-property", value: "") }
                }
                .font(.caption2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            Divider()
        }
    } else {
        Text("No scoped styles").foregroundStyle(.secondary)
    }
}
```

Add supporting state and bindings to `ComponentEditorView` (or wherever its `@State` lives):

```swift
@State private var selectorDrafts: [String: String] = [:]
@State private var propertyDrafts: [String: String] = [:]
@State private var valueDrafts: [String: String] = [:]

private func selectorBinding(for rule: ComponentModel.StyleRule) -> Binding<String> {
    let key = rule.span.description
    return Binding(
        get: { selectorDrafts[key] ?? rule.selector },
        set: { selectorDrafts[key] = $0 }
    )
}

private func propertyBinding(for rule: ComponentModel.StyleRule, decl: ComponentModel.Declaration) -> Binding<String> {
    let key = decl.span.description
    return Binding(
        get: { propertyDrafts[key] ?? decl.property },
        set: { propertyDrafts[key] = $0 }
    )
}

@ViewBuilder
private func declarationValueField(for rule: ComponentModel.StyleRule, decl: ComponentModel.Declaration) -> some View {
    let key = decl.span.description
    TextField("value", text: Binding(
        get: { valueDrafts[key] ?? decl.value },
        set: { valueDrafts[key] = $0 }
    ))
    .font(.system(.caption, design: .monospaced))
    .onSubmit {
        Task { await model.setStyleProperty(ruleSpan: rule.span, property: propertyDrafts[key] ?? decl.property, value: valueDrafts[key] ?? decl.value) }
    }
}
```

(`ComponentModel.Span`'s `description` must produce a stable, unique-enough string for dictionary keying — if `Span` isn't `CustomStringConvertible`, use `"\(rule.span.start ?? -1)-\(rule.span.end ?? -1)"` instead; check the actual `Span` type first.)

- [ ] **Step 3: Build and smoke-check compile**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Run the full test suite**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/ComponentEditorView.swift
git commit -m "feat(app): editable Styles panel declaration rows"
```

### Task 13: Native controls — ColorPicker and unit-aware numeric fields

**Files:**
- Modify: `Sources/AnglesiteApp/ComponentEditorView.swift`

**Interfaces:**
- Produces: `declarationValueField(for:decl:)` (Task 12) grows a property-name heuristic: color-ish properties (`color`, `background-color`, `border-color`, `outline-color`, `fill`, `stroke`) get a `ColorPicker` alongside the text field; the free-form `TextField` remains available for every property (escape hatch — matches the design doc's "free-form text entry always available, plus type-appropriate native controls").

- [ ] **Step 1: Write a small, testable CSS-color parse/format helper**

Create `Sources/AnglesiteCore/CSSColor.swift`:

```swift
import SwiftUI

/// Best-effort CSS <color> <-> SwiftUI Color bridge for the Styles panel's ColorPicker.
/// Only handles #rgb/#rrggbb/#rrggbbaa hex forms — named colors and rgb()/hsl() fall back
/// to the free-text field, which always remains available.
public enum CSSColor {
    public static func parse(_ value: String) -> Color? {
        var hex = value.trimmingCharacters(in: .whitespaces)
        guard hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        guard hex.count == 3 || hex.count == 6 || hex.count == 8 else { return nil }
        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard let value = UInt64(hex, radix: 16) else { return nil }
        let hasAlpha = hex.count == 8
        let r = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(value & 0xFF) / 255 : 1
        return Color(red: r, green: g, blue: b, opacity: a)
    }

    public static func format(_ color: Color) -> String {
        guard let components = color.cgColor?.components, components.count >= 3 else { return "#000000" }
        let r = Int((components[0] * 255).rounded())
        let g = Int((components[1] * 255).rounded())
        let b = Int((components[2] * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }

    public static let colorProperties: Set<String> = [
        "color", "background-color", "border-color", "outline-color", "fill", "stroke",
        "border-top-color", "border-right-color", "border-bottom-color", "border-left-color",
    ]
}
```

- [ ] **Step 2: Write the failing tests**

Create `Tests/AnglesiteCoreTests/CSSColorTests.swift`:

```swift
import Testing
@testable import AnglesiteCore

struct CSSColorTests {
    @Test("parses 6-digit hex") func sixDigit() {
        #expect(CSSColor.parse("#ff0000") != nil)
    }

    @Test("parses 3-digit hex") func threeDigit() {
        #expect(CSSColor.parse("#f00") != nil)
    }

    @Test("returns nil for named colors") func namedColorFallsBack() {
        #expect(CSSColor.parse("red") == nil)
    }

    @Test("format round-trips a parsed hex color") func roundTrip() {
        let color = CSSColor.parse("#3366ff")!
        #expect(CSSColor.format(color) == "#3366ff")
    }

    @Test("color property set includes the common properties") func propertySet() {
        #expect(CSSColor.colorProperties.contains("background-color"))
        #expect(!CSSColor.colorProperties.contains("padding"))
    }
}
```

- [ ] **Step 3: Run to verify they fail, then implement and verify they pass**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter CSSColorTests
```

- [ ] **Step 4: Wire the ColorPicker into `declarationValueField`**

Extend the view built in Task 12:

```swift
@ViewBuilder
private func declarationValueField(for rule: ComponentModel.StyleRule, decl: ComponentModel.Declaration) -> some View {
    let key = decl.span.description
    let binding = Binding(
        get: { valueDrafts[key] ?? decl.value },
        set: { valueDrafts[key] = $0 }
    )
    HStack(spacing: 4) {
        TextField("value", text: binding)
            .font(.system(.caption, design: .monospaced))
            .onSubmit {
                Task { await model.setStyleProperty(ruleSpan: rule.span, property: propertyDrafts[key] ?? decl.property, value: valueDrafts[key] ?? decl.value) }
            }
        if CSSColor.colorProperties.contains(decl.property), let color = CSSColor.parse(binding.wrappedValue) {
            ColorPicker("", selection: Binding(
                get: { color },
                set: { newColor in
                    let formatted = CSSColor.format(newColor)
                    valueDrafts[key] = formatted
                    Task { await model.setStyleProperty(ruleSpan: rule.span, property: propertyDrafts[key] ?? decl.property, value: formatted) }
                }
            ))
            .labelsHidden()
        }
    }
}
```

- [ ] **Step 5: Build and run full test suite**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .
```

Expected: `BUILD SUCCEEDED`, all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/CSSColor.swift Sources/AnglesiteApp/ComponentEditorView.swift Tests/AnglesiteCoreTests/CSSColorTests.swift
git commit -m "feat(app): ColorPicker for color-valued CSS declarations in the Styles panel"
```

### Task 14: Add-rule affordance

**Files:**
- Modify: `Sources/AnglesiteApp/ComponentEditorView.swift`

**Interfaces:**
- Consumes: `ComponentEditorModel.addStyleRule(selector:media:declarations:)` (Task 11).
- Produces: an "Add rule…" button below the Styles list that prompts for a selector (a simple `TextField` + confirm in a small inline form — no new dependency, no sheet) and calls `addStyleRule` with an empty declaration list; the new empty rule then gets its first declaration via the existing "Add declaration" flow (Task 12).

- [ ] **Step 1: Add the inline add-rule form**

Below the `ForEach(Array(styles.enumerated())...)` block from Task 12, inside the same `GroupBox("Styles")`:

```swift
Divider()
HStack {
    TextField("New selector, e.g. .card-footer", text: $newRuleSelector)
        .font(.system(.caption, design: .monospaced))
    Button("Add rule") {
        let selector = newRuleSelector.trimmingCharacters(in: .whitespaces)
        guard !selector.isEmpty else { return }
        Task {
            await model.addStyleRule(selector: selector, media: nil, declarations: [])
            newRuleSelector = ""
        }
    }
    .disabled(newRuleSelector.trimmingCharacters(in: .whitespaces).isEmpty)
}
```

Add the backing state:

```swift
@State private var newRuleSelector: String = ""
```

- [ ] **Step 2: Build and run tests**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .
```

Expected: `BUILD SUCCEEDED`, all tests pass.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteApp/ComponentEditorView.swift
git commit -m "feat(app): add-rule affordance in the Styles panel"
```

### Task 15: Scrub injection

**Files:**
- Modify: `JS/edit-overlay/src/component-canvas.ts`
- Modify: `JS/edit-overlay/test/component-canvas.test.ts`
- Modify: `Sources/AnglesiteApp/ComponentEditorView.swift` (call `evaluateJavaScript` on drag tick + fire one op on gesture end)

**Interfaces:**
- Produces (overlay): `window.anglesiteCanvas.scrub(selector: string, property: string, value: string): void` (idempotently creates/updates `<style id="anglesite-scrub">`) and `.clearScrub(): void` (removes it). Mirrors the existing `.highlight`/`.clear` pair's install pattern exactly.
- Consumes (Swift): the color-picker drag from Task 13 is the first real scrub consumer — while the `ColorPicker`'s selection is actively changing (SwiftUI reports this via the binding's `set` firing repeatedly during a drag), inject the scrub style on every tick and fire exactly one `setStyleProperty` op when the picker closes/commits.

- [ ] **Step 1: Write the failing overlay test**

Add to `JS/edit-overlay/test/component-canvas.test.ts`, following the file's existing `installComponentCanvas()`/DOM-seeding conventions:

```typescript
it("scrub creates a single #anglesite-scrub style tag and updates its content on repeated calls", () => {
  setPath("/_anglesite/component/Card");
  document.body.innerHTML = `<article class="card">hi</article>`;
  installComponentCanvas();

  (window as any).anglesiteCanvas.scrub(".card", "color", "red");
  expect(document.querySelectorAll("#anglesite-scrub")).toHaveLength(1);
  expect(document.getElementById("anglesite-scrub")?.textContent).toContain(".card { color: red; }");

  (window as any).anglesiteCanvas.scrub(".card", "color", "blue");
  expect(document.querySelectorAll("#anglesite-scrub")).toHaveLength(1);
  expect(document.getElementById("anglesite-scrub")?.textContent).toContain(".card { color: blue; }");

  (window as any).anglesiteCanvas.clearScrub();
  expect(document.getElementById("anglesite-scrub")).toBeNull();
});

it("clearScrub is safe to call when no scrub tag exists", () => {
  setPath("/_anglesite/component/Card");
  installComponentCanvas();
  expect(() => (window as any).anglesiteCanvas.clearScrub()).not.toThrow();
});
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd JS/edit-overlay
npm test -- test/component-canvas.test.ts
```

Expected: FAIL — `scrub`/`clearScrub` don't exist on `window.anglesiteCanvas`.

- [ ] **Step 3: Implement in `component-canvas.ts`**

Find the `installComponentCanvas` function's `window.anglesiteCanvas = { highlight(...) {...}, clear: clearRing }` assignment and extend it:

```typescript
const SCRUB_STYLE_ID = "anglesite-scrub";

function scrub(selector: string, property: string, value: string): void {
  let style = document.getElementById(SCRUB_STYLE_ID) as HTMLStyleElement | null;
  if (!style) {
    style = document.createElement("style");
    style.id = SCRUB_STYLE_ID;
    document.head.appendChild(style);
  }
  style.textContent = `${selector} { ${property}: ${value}; }`;
}

function clearScrub(): void {
  document.getElementById(SCRUB_STYLE_ID)?.remove();
}
```

```typescript
(window as unknown as Record<string, unknown>).anglesiteCanvas = {
  highlight(line: number, column: number): void {
    clearRing();
    const el = findByLoc(line, column);
    if (el) drawRing(el);
  },
  clear: clearRing,
  scrub,
  clearScrub,
};
```

- [ ] **Step 4: Run overlay tests to verify they pass**

```bash
npm test -- test/component-canvas.test.ts
npm run typecheck && npm run lint
```

Expected: PASS, clean.

- [ ] **Step 5: Commit the overlay change**

```bash
git add JS/edit-overlay/src/component-canvas.ts JS/edit-overlay/test/component-canvas.test.ts
git commit -m "feat(overlay): add scrub/clearScrub live-preview hooks to the component canvas"
```

- [ ] **Step 6: Wire the Swift side — inject on drag tick, commit once on gesture end**

`cd` back to the app repo root. In `Sources/AnglesiteApp/ComponentEditorView.swift`, extend Task 13's `ColorPicker` binding so every intermediate value pushes a scrub injection (not a real op), and only the *final* value (on the picker closing) fires `setStyleProperty`. SwiftUI's `ColorPicker` binding setter fires continuously during the system color panel drag and does not itself distinguish "still dragging" from "done" — use `.onChange` for the scrub injection (cheap, every tick) and keep the real op behind the existing `Binding`'s `set` (which already fires once per *user-committed* change in practice for `ColorPicker`, unlike a custom slider):

```swift
ColorPicker("", selection: Binding(
    get: { color },
    set: { newColor in
        let formatted = CSSColor.format(newColor)
        valueDrafts[key] = formatted
        webView?.evaluateJavaScript("window.anglesiteCanvas?.scrub?.(\(jsStringLiteral(rule.selector)), \(jsStringLiteral(decl.property)), \(jsStringLiteral(formatted)))")
    }
))
.labelsHidden()
.onChange(of: valueDrafts[key]) { _, newValue in
    guard let newValue else { return }
    Task {
        await model.setStyleProperty(ruleSpan: rule.span, property: propertyDrafts[key] ?? decl.property, value: newValue)
        webView?.evaluateJavaScript("window.anglesiteCanvas?.clearScrub?.()")
    }
}
```

Add a small JS-string-escaping helper next to the other view-model helpers in this file (reuse one if it already exists — check with `grep -n "jsStringLiteral\|escapeJS" Sources/AnglesiteApp/*.swift` first):

```swift
private func jsStringLiteral(_ value: String) -> String {
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
}
```

This design deliberately debounces via `.onChange`'s coalescing (SwiftUI only delivers the latest value per render pass) rather than firing one op per pixel of drag — matching the design doc's "one `set-style-property` op fires on gesture end" intent closely enough for a `ColorPicker` (which doesn't expose a separate "drag ended" event); a future slice with a custom numeric-stepper drag gesture can distinguish "in-progress" vs. "committed" more precisely if needed.

- [ ] **Step 7: Build and run the full app test suite**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .
```

Expected: `BUILD SUCCEEDED`, all tests pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/AnglesiteApp/ComponentEditorView.swift
git commit -m "feat(app): scrub injection for live color-picker feedback in the Styles panel"
```

### Task 16: Bump `MIN_PLUGIN_VERSION`, whole-branch smoke, PR

**Files:**
- Modify: wherever `MIN_PLUGIN_VERSION` (or equivalent) is asserted — search first: `grep -rn "MIN_PLUGIN_VERSION" Sources/ scripts/`

- [ ] **Step 1: Confirm the merged plugin version**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/anglesite && git checkout main && git pull && cat package.json | grep '"version"'
```

- [ ] **Step 2: Bump the floor in the app repo**

```bash
cd <app worktree>
grep -rn "MIN_PLUGIN_VERSION" Sources/ scripts/
```

Update the found constant/comparison to the new version string (following the exact pattern PR #488 used to bump the floor to `1.3.0`).

- [ ] **Step 3: Re-copy the plugin and do a whole-branch smoke**

```bash
ANGLESITE_PLUGIN_SRC=/Users/dwk/Developer/github.com/Anglesite/anglesite scripts/copy-plugin.sh
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
```

Expected: version guard passes, full suite green, build succeeds.

- [ ] **Step 4: Commit and open the PR**

```bash
git add -A
git commit -m "chore: require plugin >= <new-version> (component-style write ops)"
git push -u origin <branch-name>
gh pr create --title "feat: Component Editor slice 2 — Styles panel write ops" --body "$(cat <<'EOF'
## Summary
- Wires the harness canvas to a real MCPApplyEditRouter (previously LoggingEditRouter stub)
- Editable Styles panel: declaration rows, ColorPicker for color properties, add-rule/add-declaration, scrub injection for live drag feedback
- Consumes Anglesite/anglesite's new set-style-property/remove-style-property/add-style-rule/set-rule-selector ops (content-hash staleness checked, span-identified rules)

Closes #492. Part of #496.
EOF
)"
```

## Self-Review Notes (for the implementer to re-check before starting)

- **Spec coverage:** §2.3's four write ops (plugin), §4.3's Styles panel (declaration rows, native controls incl. ColorPicker, media queries, computed disclosure — computed already shipped in slice 1, unchanged here), §5's scrub injection and stale-conflict handling are all covered above. Attributes/Props tab and Code tab are explicitly **out of scope** (slices 3–4 per §9) — this plan does not restructure the inspector into a full `TabView`; it only makes the existing "Styles" `GroupBox` editable, deferring tab infrastructure until Attributes/Code have real content (YAGNI).
- **Deferred by design, not forgotten:** box-model spacing widget and font controls (design doc mentions these as "type-appropriate native controls" alongside ColorPicker) are not built in this slice — only ColorPicker ships. The free-text field remains the fallback for every property, so no functionality gap, only a polish gap. Note this explicitly to the user before starting Task 13 in case they want it expanded.
- **No rule-deletion op:** the design doc's op table (§2.3) does not include a `remove-style-rule` op — only property-level add/remove and selector rename. This plan does not invent one; a rule, once added, can only be emptied of declarations and renamed, not deleted, until a later slice adds that op.
