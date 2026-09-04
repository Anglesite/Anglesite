# Component Editor Slice 1 (Read-Only) Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the read-only Component Editor: plugin `get_component_model` MCP tool, dev-only harness route in the template, `component-canvas.ts` overlay module, and the Swift three-pane editor (outline + canvas + selection sync + computed styles + Source fallback).

**Architecture:** The plugin parses `.astro` files with `@astrojs/compiler` (+ `css-tree` for style rules) and returns a versioned JSON model over MCP. The app renders one component in an isolated dev-only harness route inside the existing WKWebView bridge; a new overlay module maps canvas clicks to `data-astro-source-loc` and reports computed styles. Swift decodes the model into `ComponentModel`, builds the outline, and syncs selection both ways. No writes in this slice.

**Tech Stack:** Node ≥22 ESM (`.mjs`), zod, vitest, `@astrojs/compiler`, `css-tree` (plugin); TypeScript + esbuild + vitest/jsdom (overlay); Swift 6.4 / Swift Testing, SwiftUI, WKWebView (app). **No new Swift package dependencies in this slice** (STTextView et al. arrive in Slice 4).

**Spec:** `docs/superpowers/specs/2026-07-05-component-editor-design.md`

## Global Constraints

- **Two repos.** Part A (Tasks 1–5) runs in the plugin repo `/Users/dwk/Developer/github.com/Anglesite/anglesite` on a new branch `feat/component-model`. Part B (Tasks 6–13) runs in an app-repo worktree (create via `superpowers:using-git-worktrees` at execution time). Every task states its working directory — `cd` there first; dispatched subagents get a hard `cd` guard.
- **App worktree setup:** run `xcodegen generate` first (xcodeproj is gitignored), and `ANGLESITE_PLUGIN_SRC=/Users/dwk/Developer/github.com/Anglesite/anglesite scripts/copy-plugin.sh` before any `xcodebuild`.
- **Swift toolchain:** run tests as `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .` (default CommandLineTools swift is broken/too old).
- Plugin server code is ESM `.mjs`, Node ≥22, zod input schemas, tool replies `{ content: [{type:"text", text: JSON.stringify(...)}] }` with `isError: true` on failure.
- Swift: Swift Testing (`@Test`, `#expect`), `@testable import`; app-target logic stays thin — testable types go in `AnglesiteCore`.
- Overlay: `npm run typecheck && npm run lint && npm test` must pass in `JS/edit-overlay` before commit.
- Template changes can break Swift string-match tests — run `swift test` before pushing template edits, not just the JS build.
- Conventional commits. Do not push tags or cut releases without the user's go-ahead (Task 5 checkpoint).
- macOS 27 / SwiftUI 27; no LLM/Claude paths anywhere (deterministic Swift/TS only, per #459).

## File Structure

**Part A — plugin repo (`…/Anglesite/anglesite`):**

| File | Responsibility |
|---|---|
| `server/component-model.mjs` (create) | Parse one `.astro` file → model JSON (template tree, styles, frontmatter, client script, version) |
| `server/props-interface.mjs` (create) | Heuristic `interface Props` / `Astro.props` default extraction from frontmatter TS |
| `server/index-tools.mjs` (modify) | Register `get_component_model` tool |
| `tests/component-model.test.ts` (create) | Direct module unit tests |
| `tests/mcp-server.test.ts` (modify) | One stdio round-trip test for the new tool |
| `package.json` (modify) | Add `@astrojs/compiler`, `css-tree` |
| `CHANGELOG.md` (modify) | Note the new tool |

**Part B — app repo worktree:**

| File | Responsibility |
|---|---|
| `Resources/Template/scripts/anglesite-harness.ts` (create) | Dev-only Astro integration injecting the harness route |
| `Resources/Template/scripts/harness/component.astro` (create) | Harness page: render one component with query-string props + slot sample |
| `Resources/Template/astro.config.ts` (modify) | Wire the integration |
| `Sources/AnglesiteCore/ComponentModel.swift` (create) | Codable model mirroring the tool JSON |
| `Sources/AnglesiteCore/ComponentModelClient.swift` (create) | MCP fetch + decode |
| `Sources/AnglesiteCore/ComponentCanvasMessages.swift` (create) | `CanvasSelectionMessage`, `ComputedStylesReport` decode |
| `Sources/AnglesiteCore/ComponentOutline.swift` (create) | Outline rows, loc→node matching, harness URL, knob defaults |
| `Sources/AnglesiteCore/EditorKind.swift` (modify) | Add `.component` |
| `Sources/AnglesiteBridge/AnglesiteScriptHandler.swift` (modify) | Dispatch the two new message types |
| `JS/edit-overlay/src/component-canvas.ts` (create) | Harness-page selection/computed-styles module |
| `JS/edit-overlay/src/index.ts` (modify) | Route harness pages to the new module |
| `Sources/AnglesiteApp/ComponentEditorModel.swift` (create) | `@Observable` editor state (thin) |
| `Sources/AnglesiteApp/ComponentEditorView.swift` (create) | Three-pane SwiftUI editor + canvas NSViewRepresentable |
| `Sources/AnglesiteApp/MainPaneEditorView.swift` (modify) | `.component` case |
| `Tests/AnglesiteCoreTests/…` (create) | Model decode, client, outline, message tests + plugin-gated e2e |
| `Tests/AnglesiteBridgeTests/AnglesiteScriptHandlerTests.swift` (modify) | New dispatch cases |
| `JS/edit-overlay/test/component-canvas.test.ts` (create) | jsdom tests |

---

# Part A — Plugin repo

All Part A tasks: `cd /Users/dwk/Developer/github.com/Anglesite/anglesite`. First task creates branch `feat/component-model` from `main`.

### Task 1: Component model builder — template tree

**Files:**
- Modify: `package.json` (deps)
- Create: `server/component-model.mjs`
- Create: `tests/component-model.test.ts`

**Interfaces:**
- Produces: `buildComponentModel(projectRoot: string, relPath: string) → Promise<Model>` where `Model = { version, path, template, frontmatter, styles, clientScript }`. Template nodes: `{ id, kind: "fragment"|"element"|"component"|"expression"|"slot"|"text", tag: string|null, attrs: [{name, value}], span: [start|null, end|null], loc: {line, column}|null, text?: string, children: [] }`. Root is a synthetic `fragment` (a `.astro` file can have several top-level elements).
- Throws `ComponentModelError` with `.reason` (`"invalid-input" | "read-failed" | "parse-failed"`).

- [ ] **Step 1: Branch + install deps**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/anglesite
git checkout main && git pull && git checkout -b feat/component-model
npm install @astrojs/compiler css-tree
```

- [ ] **Step 2: Write the failing test**

Create `tests/component-model.test.ts`:

```typescript
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { buildComponentModel } from "../server/component-model.mjs";

const CARD = `---
interface Props {
  title: string;
  count?: number;
}
const { title, count = 1 } = Astro.props;
---
<article class="card">
  <h2>{title}</h2>
  <slot />
</article>

<style>
  .card { padding: 1rem; }
  @media (max-width: 600px) {
    .card { padding: 0.5rem; }
  }
</style>

<script>
  console.log("card mounted");
</script>
`;

describe("buildComponentModel", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "anglesite-cm-"));
    mkdirSync(join(tmpDir, "src", "components"), { recursive: true });
    writeFileSync(join(tmpDir, "src", "components", "Card.astro"), CARD);
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("builds the template tree with kinds, spans, and locs", async () => {
    const model = await buildComponentModel(tmpDir, "src/components/Card.astro");
    expect(model.path).toBe("src/components/Card.astro");
    expect(model.version).toMatch(/^(sha256:[0-9a-f]{12}|[0-9a-f]{40})$/);

    expect(model.template.kind).toBe("fragment");
    const article = model.template.children[0];
    expect(article.kind).toBe("element");
    expect(article.tag).toBe("article");
    expect(article.attrs).toEqual([{ name: "class", value: "card" }]);
    expect(article.span[0]).toBeGreaterThan(0);
    expect(article.loc?.line).toBeGreaterThan(0);

    const [h2, slot] = article.children;
    expect(h2.tag).toBe("h2");
    expect(h2.children[0].kind).toBe("expression");
    expect(slot.kind).toBe("slot");

    // ids unique across the tree
    const ids = new Set<string>();
    const visit = (n: { id: string; children: { id: string }[] }) => {
      expect(ids.has(n.id)).toBe(false);
      ids.add(n.id);
      (n.children as any[]).forEach(visit);
    };
    visit(model.template as any);
  });

  it("classifies component instances", async () => {
    writeFileSync(
      join(tmpDir, "src", "components", "Page.astro"),
      `<div>\n  <Card title="hi" />\n</div>\n`,
    );
    const model = await buildComponentModel(tmpDir, "src/components/Page.astro");
    const card = model.template.children[0].children[0];
    expect(card.kind).toBe("component");
    expect(card.tag).toBe("Card");
    expect(card.attrs).toEqual([{ name: "title", value: "hi" }]);
  });

  it("rejects traversal and non-astro paths", async () => {
    await expect(buildComponentModel(tmpDir, "../etc/passwd")).rejects.toMatchObject({
      reason: "invalid-input",
    });
    await expect(buildComponentModel(tmpDir, "src/components/Card.css")).rejects.toMatchObject({
      reason: "invalid-input",
    });
  });

  it("reports read failures", async () => {
    await expect(buildComponentModel(tmpDir, "src/components/Missing.astro")).rejects.toMatchObject({
      reason: "read-failed",
    });
  });
});
```

- [ ] **Step 3: Run test to verify it fails**

Run: `npm test -- tests/component-model.test.ts`
Expected: FAIL — cannot resolve `../server/component-model.mjs`.

- [ ] **Step 4: Implement `server/component-model.mjs` (template tree only)**

```javascript
// Builds a structured, read-only model of one .astro component for the
// Component Editor (spec: Anglesite-app docs/superpowers/specs/
// 2026-07-05-component-editor-design.md §2.2).
import { readFileSync } from "node:fs";
import { join, normalize } from "node:path";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { parse } from "@astrojs/compiler";

export class ComponentModelError extends Error {
  constructor(reason, message) {
    super(message);
    this.reason = reason;
  }
}

export async function buildComponentModel(projectRoot, relPath) {
  if (
    typeof relPath !== "string" ||
    !relPath.endsWith(".astro") ||
    normalize(relPath).startsWith("..") ||
    relPath.startsWith("/")
  ) {
    throw new ComponentModelError("invalid-input", `not a project-relative .astro path: ${relPath}`);
  }
  const absPath = join(projectRoot, relPath);
  let source;
  try {
    source = readFileSync(absPath, "utf-8");
  } catch (err) {
    throw new ComponentModelError("read-failed", `read ${relPath}: ${err.message}`);
  }
  let ast;
  try {
    ({ ast } = await parse(source, { position: true }));
  } catch (err) {
    throw new ComponentModelError("parse-failed", `parse ${relPath}: ${err.message}`);
  }

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

  return {
    version: fileVersion(projectRoot, source),
    path: relPath,
    template,
    frontmatter: null, // Task 3
    styles: [],        // Task 2
    clientScript: null, // Task 3
  };
}

// style/script/frontmatter are zones, not template nodes.
function isZoneNode(n) {
  return n.type === "frontmatter" || (n.type === "element" && (n.name === "style" || n.name === "script"));
}

class NodeBuilder {
  #next = 0;
  nextId() {
    return `n${this.#next++}`;
  }
  toNode(n) {
    switch (n.type) {
      case "element":
        return this.#make(n, n.name === "slot" ? "slot" : "element", n.name);
      case "component":
      case "custom-element":
        return this.#make(n, "component", n.name);
      case "expression":
        return { ...this.#base(n), kind: "expression", tag: null, attrs: [], children: [] };
      case "text": {
        const value = (n.value ?? "").trim();
        if (!value) return null;
        return { ...this.#base(n), kind: "text", tag: null, attrs: [], text: value.slice(0, 80), children: [] };
      }
      default:
        return null; // comment, doctype, fragment wrappers
    }
  }
  #make(n, kind, tag) {
    return {
      ...this.#base(n),
      kind,
      tag,
      attrs: (n.attributes ?? []).map((a) => ({ name: a.name, value: a.value ?? null })),
      children: (n.children ?? [])
        .filter((c) => !isZoneNode(c))
        .map((c) => this.toNode(c))
        .filter(Boolean),
    };
  }
  #base(n) {
    const start = n.position?.start;
    const end = n.position?.end;
    return {
      id: this.nextId(),
      span: [start?.offset ?? null, end?.offset ?? null],
      loc: start ? { line: start.line, column: start.column } : null,
    };
  }
}

function fileVersion(projectRoot, source) {
  try {
    return execFileSync("git", ["rev-parse", "HEAD"], { cwd: projectRoot, encoding: "utf-8" }).trim();
  } catch {
    return "sha256:" + createHash("sha256").update(source).digest("hex").slice(0, 12);
  }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `npm test -- tests/component-model.test.ts`
Expected: PASS (4 tests). If the `expression`/`slot` assertions fail, dump the AST (`console.log(JSON.stringify(ast, null, 2))` temporarily) and adjust the `toNode` switch to the actual `@astrojs/compiler` node type names — do not weaken the assertions.

- [ ] **Step 6: Commit**

```bash
git add package.json package-lock.json server/component-model.mjs tests/component-model.test.ts
git commit -m "feat(component-model): parse .astro template tree via @astrojs/compiler"
```

### Task 2: Style rules via css-tree

**Files:**
- Modify: `server/component-model.mjs`
- Modify: `tests/component-model.test.ts`

**Interfaces:**
- Produces: `model.styles: [{ selector: string, media: string|null, span: [s,e], declarations: [{ property, value, span }] }]`. Spans are **file-absolute** offsets (style-content offset added).

- [ ] **Step 1: Write the failing test**

Append to the `describe` block in `tests/component-model.test.ts`:

```typescript
  it("extracts style rules with media context and file-absolute spans", async () => {
    const model = await buildComponentModel(tmpDir, "src/components/Card.astro");
    expect(model.styles).toHaveLength(2);

    const [plain, mobile] = model.styles;
    expect(plain.selector).toBe(".card");
    expect(plain.media).toBeNull();
    expect(plain.declarations).toEqual([
      expect.objectContaining({ property: "padding", value: "1rem" }),
    ]);

    expect(mobile.selector).toBe(".card");
    expect(mobile.media).toContain("max-width");
    expect(mobile.declarations[0].value).toBe("0.5rem");

    // file-absolute span: the source slice at the declaration span mentions the property
    const [s, e] = plain.declarations[0].span;
    expect(CARD.slice(s, e)).toContain("padding");
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- tests/component-model.test.ts`
Expected: FAIL — `model.styles` is `[]`.

- [ ] **Step 3: Implement style extraction**

In `server/component-model.mjs`, add the import and helpers, and populate `styles`:

```javascript
import { parse as parseCss, generate, walk } from "css-tree";
```

In `buildComponentModel`, before the `return`, collect style elements from the raw AST (they may sit at top level or nested):

```javascript
  const styleElements = [];
  collectElements(ast, "style", styleElements);
  const styles = styleElements.flatMap((el) => extractRules(el));
```

and set `styles` in the returned model. Add at module scope:

```javascript
function collectElements(node, name, out) {
  if (node.type === "element" && node.name === name) out.push(node);
  for (const child of node.children ?? []) collectElements(child, name, out);
}

function extractRules(styleElement) {
  const textChild = (styleElement.children ?? []).find((c) => c.type === "text");
  if (!textChild?.value) return [];
  const baseOffset = textChild.position?.start?.offset ?? 0;
  let cssAst;
  try {
    cssAst = parseCss(textChild.value, {
      positions: true,
      parseValue: false,
      parseAtrulePrelude: false,
    });
  } catch {
    return []; // unparseable CSS: styles stay empty; template/props still usable
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
          span: cssSpan(decl.loc, baseOffset),
        });
      });
      rules.push({
        selector: generate(node.prelude),
        media,
        span: cssSpan(node.loc, baseOffset),
        declarations,
      });
    },
  });
  return rules;
}

function cssSpan(loc, baseOffset) {
  if (!loc) return [null, null];
  return [baseOffset + loc.start.offset, baseOffset + loc.end.offset];
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm test -- tests/component-model.test.ts`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add server/component-model.mjs tests/component-model.test.ts
git commit -m "feat(component-model): extract scoped style rules via css-tree"
```

### Task 3: Frontmatter props, client script, and zones

**Files:**
- Create: `server/props-interface.mjs`
- Modify: `server/component-model.mjs`
- Modify: `tests/component-model.test.ts`

**Interfaces:**
- Produces: `parseProps(frontmatterSource: string) → [{ name, type, optional, default: string|null }]` (heuristic; supported subset: `interface Props {…}` or `type Props = {…}` with one `name?: type;` per line, defaults from `const { a = 1 } = Astro.props`). Returns `[]` when nothing matches.
- Produces: `model.frontmatter: { source, span, props } | null`, `model.clientScript: { source, span } | null`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/component-model.test.ts`:

```typescript
  it("extracts frontmatter with a parsed Props interface", async () => {
    const model = await buildComponentModel(tmpDir, "src/components/Card.astro");
    expect(model.frontmatter?.source).toContain("interface Props");
    expect(model.frontmatter?.props).toEqual([
      { name: "title", type: "string", optional: false, default: null },
      { name: "count", type: "number", optional: true, default: "1" },
    ]);
  });

  it("extracts the client script zone", async () => {
    const model = await buildComponentModel(tmpDir, "src/components/Card.astro");
    expect(model.clientScript?.source).toContain("card mounted");
    const [s, e] = model.clientScript!.span;
    expect(CARD.slice(s!, e!)).toContain("card mounted");
  });

  it("returns null zones and empty props when absent", async () => {
    writeFileSync(join(tmpDir, "src", "components", "Bare.astro"), `<p>hello</p>\n`);
    const model = await buildComponentModel(tmpDir, "src/components/Bare.astro");
    expect(model.frontmatter).toBeNull();
    expect(model.clientScript).toBeNull();
    expect(model.styles).toEqual([]);
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npm test -- tests/component-model.test.ts`
Expected: FAIL — `frontmatter` and `clientScript` are `null`.

- [ ] **Step 3: Implement `server/props-interface.mjs`**

```javascript
// Heuristic Props extraction from Astro frontmatter TypeScript. Deliberately
// regex-based (no TS compiler in the container): supports `interface Props`
// or `type Props = { ... }` with one `name?: type;` member per line, and
// defaults from `const { name = value } = Astro.props`. Anything fancier
// yields [] — the editor treats that as "no knobs", never an error.
export function parseProps(frontmatterSource) {
  const block = frontmatterSource.match(/(?:interface\s+Props|type\s+Props\s*=)\s*\{([\s\S]*?)\n\}/);
  if (!block) return [];
  const props = [];
  for (const line of block[1].split("\n")) {
    const m = line.match(/^\s*(\w+)(\?)?\s*:\s*([^;]+);?\s*(?:\/\/.*)?$/);
    if (m) props.push({ name: m[1], type: m[3].trim(), optional: Boolean(m[2]), default: null });
  }
  const destructure = frontmatterSource.match(/const\s*\{([\s\S]*?)\}\s*=\s*Astro\.props/);
  if (destructure) {
    for (const part of destructure[1].split(",")) {
      const dm = part.match(/^\s*(\w+)\s*=\s*(.+?)\s*$/s);
      if (!dm) continue;
      const prop = props.find((p) => p.name === dm[1]);
      if (prop) prop.default = dm[2].trim();
    }
  }
  return props;
}
```

- [ ] **Step 4: Wire zones into `buildComponentModel`**

Add the import:

```javascript
import { parseProps } from "./props-interface.mjs";
```

Before the `return`, extract both zones:

```javascript
  const fmNode = topLevel.find((n) => n.type === "frontmatter");
  const frontmatter = fmNode
    ? {
        source: fmNode.value ?? "",
        span: [fmNode.position?.start?.offset ?? null, fmNode.position?.end?.offset ?? null],
        props: parseProps(fmNode.value ?? ""),
      }
    : null;

  const scriptElements = [];
  collectElements(ast, "script", scriptElements);
  const scriptText = scriptElements
    .map((el) => (el.children ?? []).find((c) => c.type === "text"))
    .find((t) => t?.value);
  const clientScript = scriptText
    ? {
        source: scriptText.value,
        span: [scriptText.position?.start?.offset ?? null, scriptText.position?.end?.offset ?? null],
      }
    : null;
```

Replace the placeholder `frontmatter: null` / `clientScript: null` in the return with these values.

- [ ] **Step 5: Run the whole plugin suite**

Run: `npm test`
Expected: PASS, including all 8 `component-model` tests. (Frontmatter `span` note: the compiler's frontmatter node covers the fenced content; if the span assertion in Step 1 fails by the `---` fence width, assert on `source` content only — the span stays whatever the compiler reports.)

- [ ] **Step 6: Commit**

```bash
git add server/props-interface.mjs server/component-model.mjs tests/component-model.test.ts
git commit -m "feat(component-model): frontmatter props interface and client script zones"
```

### Task 4: Register the `get_component_model` MCP tool

**Files:**
- Modify: `server/index-tools.mjs`
- Modify: `tests/mcp-server.test.ts`

**Interfaces:**
- Produces MCP tool `get_component_model` with input `{ path: string }`. Success: model JSON as text content. Failure: `{ type: "anglesite:component-model-failed", reason, detail }` with `isError: true`. This is the wire contract Part B's Swift client consumes.

- [ ] **Step 1: Write the failing stdio round-trip test**

Append to the main `describe` in `tests/mcp-server.test.ts` (uses the file's existing `startServer` / `sendMessage` / `sendNotification` helpers and `tmpDir` fixture):

```typescript
  it("get_component_model returns a structured model over stdio", async () => {
    mkdirSync(join(tmpDir, "src", "components"), { recursive: true });
    writeFileSync(
      join(tmpDir, "src", "components", "Card.astro"),
      `---\ninterface Props {\n  title: string;\n}\nconst { title } = Astro.props;\n---\n<article class="card"><h2>{title}</h2></article>\n<style>.card { padding: 1rem; }</style>\n`,
    );
    const proc = startServer(tmpDir);
    try {
      await sendMessage(proc, {
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: {
          protocolVersion: "2024-11-05",
          capabilities: {},
          clientInfo: { name: "test", version: "1.0.0" },
        },
      });
      sendNotification(proc, { jsonrpc: "2.0", method: "notifications/initialized" });

      const response = await sendMessage(proc, {
        jsonrpc: "2.0",
        id: 2,
        method: "tools/call",
        params: { name: "get_component_model", arguments: { path: "src/components/Card.astro" } },
      });
      const result = response.result as { content: { text: string }[]; isError?: boolean };
      expect(result.isError).toBeFalsy();
      const model = JSON.parse(result.content[0].text);
      expect(model.path).toBe("src/components/Card.astro");
      expect(model.template.children[0].tag).toBe("article");
      expect(model.frontmatter.props[0].name).toBe("title");
      expect(model.styles[0].selector).toBe(".card");

      const failure = await sendMessage(proc, {
        jsonrpc: "2.0",
        id: 3,
        method: "tools/call",
        params: { name: "get_component_model", arguments: { path: "src/components/Nope.astro" } },
      });
      const failResult = failure.result as { content: { text: string }[]; isError?: boolean };
      expect(failResult.isError).toBe(true);
      expect(JSON.parse(failResult.content[0].text).reason).toBe("read-failed");
    } finally {
      proc.kill();
    }
  });
```

(Add `mkdirSync` to the file's `node:fs` import if not already there.)

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- tests/mcp-server.test.ts`
Expected: FAIL — MCP error: unknown tool `get_component_model`.

- [ ] **Step 3: Register the tool**

In `server/index-tools.mjs`, add the import at the top with the other server-module imports:

```javascript
import { buildComponentModel, ComponentModelError } from "./component-model.mjs";
```

Inside `buildServer(projectRoot)`, next to the `apply_edit` registration:

```javascript
  server.tool(
    "get_component_model",
    "Parse an .astro component into a structured, read-only model: template node tree with source spans, frontmatter Props interface, scoped style rules, and client script zone. Used by the app's Component Editor.",
    {
      path: z.string().describe("Component path relative to the project root, e.g. src/components/Card.astro"),
    },
    async ({ path }) => {
      try {
        const model = await buildComponentModel(projectRoot, path);
        return { content: [{ type: "text", text: JSON.stringify(model) }] };
      } catch (err) {
        const reason = err instanceof ComponentModelError ? err.reason : "parse-failed";
        return {
          content: [
            {
              type: "text",
              text: JSON.stringify({
                type: "anglesite:component-model-failed",
                reason,
                detail: String(err?.message ?? err),
              }),
            },
          ],
          isError: true,
        };
      }
    },
  );
```

- [ ] **Step 4: Run the full suite**

Run: `npm test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add server/index-tools.mjs tests/mcp-server.test.ts
git commit -m "feat(mcp): get_component_model tool for the Component Editor"
```

### Task 5: Plugin PR + release (USER CHECKPOINT)

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Changelog entry**

Add under an `## Unreleased` heading (create it if absent), following the file's existing entry style:

```markdown
### Added
- `get_component_model` MCP tool: structured read-only model of an `.astro`
  component (template tree, Props interface, style rules, client script) for
  the app's Component Editor (Slice 1).
```

- [ ] **Step 2: Verify, push branch, open PR**

```bash
npm test
git add CHANGELOG.md
git commit -m "docs: changelog for get_component_model"
git push -u origin feat/component-model
gh pr create --title "feat(mcp): get_component_model tool (Component Editor slice 1)" \
  --body "Adds a read-only component-model service: @astrojs/compiler template tree + css-tree style rules + heuristic Props extraction, exposed as the get_component_model MCP tool. App-side consumer: Anglesite-app Component Editor (spec 2026-07-05). No behavior change to existing tools."
```

- [ ] **Step 3: STOP — user checkpoint**

Report the PR URL and stop. Merging and cutting the tagged release (`npx tsx bin/release.ts minor`) is the user's call. Part B development proceeds against the local checkout via `ANGLESITE_PLUGIN_SRC`; only the final app release needs the tagged plugin.

---

# Part B — App repo

All Part B tasks run in the app worktree (create one via `superpowers:using-git-worktrees`; then `xcodegen generate`). `swift test` commands mean:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .
```

### Task 6: Template harness route (dev-only)

**Files:**
- Create: `Resources/Template/scripts/anglesite-harness.ts`
- Create: `Resources/Template/scripts/harness/component.astro`
- Modify: `Resources/Template/astro.config.ts`

**Interfaces:**
- Produces: dev-server route `GET /_anglesite/component/<Name>?props=<url-encoded JSON>` rendering one component from `src/components/**` or `src/layouts/**` with a default-slot sample. Absent from production builds. Part B's Swift `HarnessURL` (Task 11) builds these URLs; the overlay (Task 9) activates on this path prefix.

- [ ] **Step 1: Write the integration**

Create `Resources/Template/scripts/anglesite-harness.ts`:

```typescript
import { fileURLToPath } from "node:url";
import type { AstroIntegration } from "astro";

/**
 * Dev-only component harness for the Anglesite Component Editor.
 * Injects /_anglesite/component/[...name] in `astro dev` and nothing in
 * builds, so deployed sites carry no trace of it.
 */
export default function anglesiteHarness(): AstroIntegration {
  return {
    name: "anglesite-harness",
    hooks: {
      "astro:config:setup": ({ command, injectRoute }) => {
        if (command !== "dev") return;
        injectRoute({
          pattern: "/_anglesite/component/[...name]",
          entrypoint: fileURLToPath(new URL("./harness/component.astro", import.meta.url)),
          prerender: false,
        });
      },
    },
  };
}
```

- [ ] **Step 2: Write the harness page**

Create `Resources/Template/scripts/harness/component.astro`:

```astro
---
// Renders exactly one project component for the Component Editor canvas.
// Dev-only (injected by anglesite-harness.ts); never part of a build.
export const prerender = false;

const modules = import.meta.glob(["/src/components/**/*.astro", "/src/layouts/**/*.astro"]);
const name = Astro.params.name ?? "";
const key = [`/src/components/${name}.astro`, `/src/layouts/${name}.astro`].find((k) => k in modules);

let Component: any = null;
let error: string | null = null;
if (key) {
  try {
    Component = ((await modules[key]()) as { default: unknown }).default;
  } catch (err) {
    error = String(err);
  }
} else {
  error = `No component named "${name}" under src/components/ or src/layouts/.`;
}

let props: Record<string, unknown> = {};
const raw = Astro.url.searchParams.get("props");
if (raw) {
  try {
    props = JSON.parse(raw);
  } catch {
    /* malformed props param: render with defaults */
  }
}
---

<!doctype html>
<html>
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Anglesite Component Harness</title>
    <style>
      body { margin: 0; padding: 16px; background: #fff; }
      .anglesite-harness-error { font: 13px ui-monospace, monospace; color: #b00020; white-space: pre-wrap; }
      .anglesite-harness-slot-sample { outline: 1px dashed #b0b0b0; padding: 2px 6px; color: #666; }
    </style>
  </head>
  <body>
    {
      error ? (
        <pre class="anglesite-harness-error">{error}</pre>
      ) : (
        <Component {...props}>
          <span class="anglesite-harness-slot-sample">Slot content</span>
        </Component>
      )
    }
  </body>
</html>
```

- [ ] **Step 3: Wire into `astro.config.ts`**

Modify `Resources/Template/astro.config.ts` (current contents per repo: `defineConfig({ site })` with `readConfig`):

```typescript
import { defineConfig } from "astro/config";
import { readConfig } from "./scripts/config.ts";
import anglesiteHarness from "./scripts/anglesite-harness.ts";

const site = readConfig("SITE_URL") ?? "https://example.com";

export default defineConfig({ site, integrations: [anglesiteHarness()] });
```

If the file has drifted (e.g. already has `integrations`), append `anglesiteHarness()` to the existing array instead of replacing the config.

- [ ] **Step 4: Verify against a scaffolded site**

Scaffold a throwaway site from the template and check both dev and build behavior:

```bash
SCRATCH=$(mktemp -d)
cp -R Resources/Template/ "$SCRATCH/site"
cd "$SCRATCH/site" && npm install
# dev: harness route renders the template's Hcard component
npx astro dev --port 4399 &
DEV_PID=$!; sleep 8
curl -s "http://localhost:4399/_anglesite/component/Hcard" | grep -c "h-card" \
  && curl -s "http://localhost:4399/_anglesite/component/Nope" | grep -c "No component named"
kill $DEV_PID
# build: no trace of the harness
npx astro build
{ ! grep -R "_anglesite" dist/ ; } && echo "BUILD CLEAN"
cd - && rm -rf "$SCRATCH"
```

Expected: both `grep -c` print ≥1, then `BUILD CLEAN`. (If `Hcard` renders nothing grep-able without required props, use any component in the template's `src/components/`; the error-path check is the load-bearing one.)

- [ ] **Step 5: Run Swift tests (template coupling guard) and commit**

```bash
cd <worktree-root>
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .
git add Resources/Template/scripts/anglesite-harness.ts Resources/Template/scripts/harness/component.astro Resources/Template/astro.config.ts
git commit -m "feat(template): dev-only component harness route for the Component Editor"
```

### Task 7: Swift `ComponentModel` Codable types

**Files:**
- Create: `Sources/AnglesiteCore/ComponentModel.swift`
- Create: `Tests/AnglesiteCoreTests/ComponentModelTests.swift`

**Interfaces:**
- Produces: `public struct ComponentModel: Sendable, Equatable, Codable` with nested `Node` (recursive, `Identifiable`), `Attr`, `Span` (decodes the JSON two-element array `[start, end]` with nulls), `Loc`, `Frontmatter`, `Prop` (JSON key `default` → Swift `defaultValue`), `StyleRule`, `Declaration`, `ScriptZone`. Consumed by Tasks 8, 11, 12.

- [ ] **Step 1: Write the failing test**

Create `Tests/AnglesiteCoreTests/ComponentModelTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

struct ComponentModelTests {
    static let fixture = """
    {
      "version": "sha256:abc123def456",
      "path": "src/components/Card.astro",
      "template": {
        "id": "n0", "kind": "fragment", "tag": null, "attrs": [],
        "span": [0, 120], "loc": null,
        "children": [
          {
            "id": "n1", "kind": "element", "tag": "article",
            "attrs": [{"name": "class", "value": "card"}],
            "span": [80, 118], "loc": {"line": 7, "column": 1},
            "children": [
              {"id": "n2", "kind": "expression", "tag": null, "attrs": [], "span": [95, 102], "loc": {"line": 8, "column": 7}, "children": []},
              {"id": "n3", "kind": "slot", "tag": "slot", "attrs": [], "span": [null, null], "loc": {"line": 9, "column": 3}, "children": []}
            ]
          }
        ]
      },
      "frontmatter": {
        "source": "interface Props { title: string; }",
        "span": [4, 40],
        "props": [{"name": "title", "type": "string", "optional": false, "default": null}]
      },
      "styles": [
        {"selector": ".card", "media": null, "span": [130, 155],
         "declarations": [{"property": "padding", "value": "1rem", "span": [138, 152]}]}
      ],
      "clientScript": {"source": "console.log(1)", "span": [160, 175]}
    }
    """

    @Test("Decodes the full tool JSON") func decodesFixture() throws {
        let model = try JSONDecoder().decode(ComponentModel.self, from: Data(Self.fixture.utf8))
        #expect(model.version == "sha256:abc123def456")
        #expect(model.template.kind == .fragment)
        let article = model.template.children[0]
        #expect(article.tag == "article")
        #expect(article.attrs == [ComponentModel.Attr(name: "class", value: "card")])
        #expect(article.span == ComponentModel.Span(start: 80, end: 118))
        #expect(article.children[1].kind == .slot)
        #expect(article.children[1].span == ComponentModel.Span(start: nil, end: nil))
        #expect(model.frontmatter?.props == [
            ComponentModel.Prop(name: "title", type: "string", optional: false, defaultValue: nil)
        ])
        #expect(model.styles[0].declarations[0].property == "padding")
        #expect(model.clientScript?.source == "console.log(1)")
    }

    @Test("Round-trips through encode/decode") func roundTrips() throws {
        let model = try JSONDecoder().decode(ComponentModel.self, from: Data(Self.fixture.utf8))
        let data = try JSONEncoder().encode(model)
        let again = try JSONDecoder().decode(ComponentModel.self, from: data)
        #expect(again == model)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ComponentModelTests`
Expected: FAIL to compile — `ComponentModel` not found.

- [ ] **Step 3: Implement `Sources/AnglesiteCore/ComponentModel.swift`**

```swift
import Foundation

/// Decoded result of the plugin's `get_component_model` MCP tool — a
/// read-only structured view of one `.astro` component (spec §2.2).
public struct ComponentModel: Sendable, Equatable, Codable {
    public let version: String
    public let path: String
    public let template: Node
    public let frontmatter: Frontmatter?
    public let styles: [StyleRule]
    public let clientScript: ScriptZone?

    public struct Node: Sendable, Equatable, Codable, Identifiable {
        public let id: String
        public let kind: Kind
        public let tag: String?
        public let attrs: [Attr]
        public let span: Span
        public let loc: Loc?
        public let text: String?
        public let children: [Node]

        public enum Kind: String, Sendable, Codable {
            case fragment, element, component, expression, slot, text
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            kind = try c.decode(Kind.self, forKey: .kind)
            tag = try c.decodeIfPresent(String.self, forKey: .tag)
            attrs = try c.decodeIfPresent([Attr].self, forKey: .attrs) ?? []
            span = try c.decodeIfPresent(Span.self, forKey: .span) ?? Span(start: nil, end: nil)
            loc = try c.decodeIfPresent(Loc.self, forKey: .loc)
            text = try c.decodeIfPresent(String.self, forKey: .text)
            children = try c.decodeIfPresent([Node].self, forKey: .children) ?? []
        }
    }

    public struct Attr: Sendable, Equatable, Codable {
        public let name: String
        public let value: String?
        public init(name: String, value: String?) {
            self.name = name
            self.value = value
        }
    }

    /// Wire format is a two-element array `[start, end]`, either may be null.
    public struct Span: Sendable, Equatable, Codable {
        public let start: Int?
        public let end: Int?

        public init(start: Int?, end: Int?) {
            self.start = start
            self.end = end
        }

        public init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            start = try c.decodeIfPresent(Int.self) ?? nil
            end = try c.decodeIfPresent(Int.self) ?? nil
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.unkeyedContainer()
            try c.encode(start)
            try c.encode(end)
        }
    }

    public struct Loc: Sendable, Equatable, Codable {
        public let line: Int
        public let column: Int
        public init(line: Int, column: Int) {
            self.line = line
            self.column = column
        }
    }

    public struct Frontmatter: Sendable, Equatable, Codable {
        public let source: String
        public let span: Span
        public let props: [Prop]
    }

    public struct Prop: Sendable, Equatable, Codable {
        public let name: String
        public let type: String
        public let optional: Bool
        public let defaultValue: String?

        enum CodingKeys: String, CodingKey {
            case name, type, optional
            case defaultValue = "default"
        }

        public init(name: String, type: String, optional: Bool, defaultValue: String?) {
            self.name = name
            self.type = type
            self.optional = optional
            self.defaultValue = defaultValue
        }
    }

    public struct StyleRule: Sendable, Equatable, Codable {
        public let selector: String
        public let media: String?
        public let span: Span
        public let declarations: [Declaration]
    }

    public struct Declaration: Sendable, Equatable, Codable {
        public let property: String
        public let value: String
        public let span: Span
    }

    public struct ScriptZone: Sendable, Equatable, Codable {
        public let source: String
        public let span: Span
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ComponentModelTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/ComponentModel.swift Tests/AnglesiteCoreTests/ComponentModelTests.swift
git commit -m "feat(core): ComponentModel Codable types for get_component_model"
```

### Task 8: `ComponentModelClient`

**Files:**
- Create: `Sources/AnglesiteCore/ComponentModelClient.swift`
- Create: `Tests/AnglesiteCoreTests/ComponentModelClientTests.swift`

**Interfaces:**
- Consumes: `ComponentModel` (Task 7); `MCPClient.ToolCallResult`, `JSONValue` (existing).
- Produces: `public struct ComponentModelClient: Sendable` with `init(mcpClient: @escaping @Sendable () async -> MCPClient?)`, test seam `init(toolCaller:)`, and `func fetch(path: String) async throws -> ComponentModel`. Error type `ModelError: Error, Equatable` with `.toolFailed(String)`, `.decodeFailed(String)`, `.notConnected`.

- [ ] **Step 1: Write the failing test**

Create `Tests/AnglesiteCoreTests/ComponentModelClientTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

struct ComponentModelClientTests {
    private func result(text: String, isError: Bool = false) -> MCPClient.ToolCallResult {
        MCPClient.ToolCallResult(content: [.init(type: "text", text: text)], isError: isError)
    }

    @Test("Fetch calls get_component_model and decodes the model") func fetchDecodes() async throws {
        let client = ComponentModelClient { name, args in
            #expect(name == "get_component_model")
            #expect(args == .object(["path": .string("src/components/Card.astro")]))
            return self.result(text: ComponentModelTests.fixture)
        }
        let model = try await client.fetch(path: "src/components/Card.astro")
        #expect(model.path == "src/components/Card.astro")
    }

    @Test("Tool errors surface as toolFailed") func toolErrors() async {
        let client = ComponentModelClient { _, _ in
            self.result(text: #"{"type":"anglesite:component-model-failed","reason":"read-failed"}"#, isError: true)
        }
        await #expect(throws: ComponentModelClient.ModelError.self) {
            _ = try await client.fetch(path: "src/components/Nope.astro")
        }
    }

    @Test("Garbage payloads surface as decodeFailed") func garbageFails() async {
        let client = ComponentModelClient { _, _ in self.result(text: "not json") }
        do {
            _ = try await client.fetch(path: "x.astro")
            Issue.record("expected throw")
        } catch let error as ComponentModelClient.ModelError {
            guard case .decodeFailed = error else {
                Issue.record("expected decodeFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error type \(error)")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ComponentModelClientTests`
Expected: FAIL to compile — `ComponentModelClient` not found. (If `ComponentModelTests.fixture` is inaccessible, mark it `static let` — it already is per Task 7.)

- [ ] **Step 3: Implement `Sources/AnglesiteCore/ComponentModelClient.swift`**

Mirrors `MCPApplyEditRouter`'s tool-caller seam:

```swift
import Foundation

/// Fetches a component's structured model from the plugin's
/// `get_component_model` MCP tool.
public struct ComponentModelClient: Sendable {
    public typealias ToolCaller = @Sendable (_ name: String, _ arguments: JSONValue) async throws -> MCPClient.ToolCallResult

    private let toolCaller: ToolCaller

    public init(mcpClient: @escaping @Sendable () async -> MCPClient?) {
        self.toolCaller = { name, args in
            guard let client = await mcpClient() else { throw ModelError.notConnected }
            return try await client.callTool(name: name, arguments: args)
        }
    }

    /// Test seam.
    public init(toolCaller: @escaping ToolCaller) {
        self.toolCaller = toolCaller
    }

    public enum ModelError: Error, Equatable {
        case notConnected
        case toolFailed(String)
        case decodeFailed(String)
    }

    public func fetch(path: String) async throws -> ComponentModel {
        let result = try await toolCaller("get_component_model", .object(["path": .string(path)]))
        let text = result.content.compactMap(\.text).joined(separator: "\n")
        guard !result.isError else { throw ModelError.toolFailed(text) }
        guard let data = text.data(using: .utf8) else { throw ModelError.decodeFailed("non-utf8 payload") }
        do {
            return try JSONDecoder().decode(ComponentModel.self, from: data)
        } catch {
            throw ModelError.decodeFailed(String(describing: error))
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ComponentModelClientTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/ComponentModelClient.swift Tests/AnglesiteCoreTests/ComponentModelClientTests.swift
git commit -m "feat(core): ComponentModelClient MCP fetch + decode"
```

### Task 9: Overlay `component-canvas.ts`

**Files:**
- Create: `JS/edit-overlay/src/component-canvas.ts`
- Modify: `JS/edit-overlay/src/index.ts`
- Create: `JS/edit-overlay/test/component-canvas.test.ts`

Working directory: `<worktree>/JS/edit-overlay`.

**Interfaces:**
- Produces (JS→native): `{ type: "anglesite:canvas-selection", file: string|null, line: number|null, column: number|null }` and `{ type: "anglesite:computed-styles", styles: Record<string,string> }` — decoded by Task 10's Swift structs.
- Produces (native→JS): `window.anglesiteCanvas.highlight(line, column)` selects/outlines the element whose `data-astro-source-loc` is `` `${line}:${column}` ``; `window.anglesiteCanvas.clear()` removes the highlight. Called by Task 12's canvas view.
- `isHarnessPage()` gates activation on `location.pathname.startsWith("/_anglesite/component/")`.

- [ ] **Step 1: Write the failing tests**

Create `test/component-canvas.test.ts`:

```typescript
// @vitest-environment jsdom
import { describe, it, expect, beforeEach, vi } from "vitest";
import { installComponentCanvas, isHarnessPage, sourceLoc } from "../src/component-canvas.js";

function setPath(path: string) {
  window.history.replaceState({}, "", path);
}

function capturePosts(): unknown[] {
  const posts: unknown[] = [];
  (window as any).webkit = {
    messageHandlers: { anglesite: { postMessage: (m: unknown) => posts.push(m) } },
  };
  return posts;
}

describe("component canvas", () => {
  beforeEach(() => {
    document.body.innerHTML = "";
    delete (window as any).anglesiteCanvas;
  });

  it("isHarnessPage gates on the harness path prefix", () => {
    setPath("/_anglesite/component/Card");
    expect(isHarnessPage()).toBe(true);
    setPath("/about/");
    expect(isHarnessPage()).toBe(false);
  });

  it("sourceLoc walks up to the nearest annotated ancestor", () => {
    document.body.innerHTML =
      `<article data-astro-source-file="/site/src/components/Card.astro" data-astro-source-loc="7:1">` +
      `<h2><em id="inner">x</em></h2></article>`;
    const loc = sourceLoc(document.getElementById("inner")!);
    expect(loc).toEqual({ file: "/site/src/components/Card.astro", line: 7, column: 1 });
    expect(sourceLoc(document.body)).toBeNull();
  });

  it("click posts canvas-selection and computed-styles", () => {
    setPath("/_anglesite/component/Card");
    const posts = capturePosts();
    document.body.innerHTML =
      `<article data-astro-source-file="/site/src/components/Card.astro" data-astro-source-loc="7:1">hi</article>`;
    installComponentCanvas();
    (document.querySelector("article") as HTMLElement).dispatchEvent(
      new MouseEvent("click", { bubbles: true }),
    );
    const types = posts.map((p: any) => p.type);
    expect(types).toContain("anglesite:canvas-selection");
    expect(types).toContain("anglesite:computed-styles");
    const selection: any = posts.find((p: any) => p.type === "anglesite:canvas-selection");
    expect(selection.line).toBe(7);
    const styles: any = posts.find((p: any) => p.type === "anglesite:computed-styles");
    expect(typeof styles.styles.display).toBe("string");
  });

  it("exposes highlight/clear hooks for native", () => {
    setPath("/_anglesite/component/Card");
    capturePosts();
    document.body.innerHTML =
      `<article data-astro-source-file="/f.astro" data-astro-source-loc="7:1">hi</article>`;
    installComponentCanvas();
    (window as any).anglesiteCanvas.highlight(7, 1);
    expect(document.querySelector(".anglesite-canvas-ring")).not.toBeNull();
    (window as any).anglesiteCanvas.clear();
    expect(document.querySelector(".anglesite-canvas-ring")).toBeNull();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- test/component-canvas.test.ts`
Expected: FAIL — module `../src/component-canvas.js` not found.

- [ ] **Step 3: Implement `src/component-canvas.ts`**

```typescript
/**
 * Component-harness canvas module. Active only on /_anglesite/component/*
 * pages (the Component Editor's isolated canvas). Read-only in slice 1:
 * reports clicks as structured selections + computed styles to native, and
 * exposes highlight hooks so the native outline can drive the canvas.
 */

const HARNESS_PREFIX = "/_anglesite/component/";
const RING_CLASS = "anglesite-canvas-ring";

// Curated list shown in the inspector's Computed section.
const REPORTED_PROPERTIES = [
  "display", "position", "width", "height",
  "margin-top", "margin-right", "margin-bottom", "margin-left",
  "padding-top", "padding-right", "padding-bottom", "padding-left",
  "font-family", "font-size", "font-weight", "line-height",
  "color", "background-color", "border-radius",
] as const;

export interface SourceLoc {
  file: string;
  line: number;
  column: number;
}

export function isHarnessPage(): boolean {
  return location.pathname.startsWith(HARNESS_PREFIX);
}

export function sourceLoc(el: Element): SourceLoc | null {
  let node: Element | null = el;
  while (node && node !== document.body) {
    const loc = node.getAttribute("data-astro-source-loc");
    const file = node.getAttribute("data-astro-source-file");
    if (loc && file) {
      const [line, column] = loc.split(":").map(Number);
      return { file, line: line ?? 0, column: column ?? 0 };
    }
    node = node.parentElement;
  }
  return null;
}

export function installComponentCanvas(): void {
  if (!isHarnessPage()) return;
  document.addEventListener("click", onClick, true);
  (window as unknown as Record<string, unknown>).anglesiteCanvas = {
    highlight(line: number, column: number): void {
      clearRing();
      const el = document.querySelector(`[data-astro-source-loc="${line}:${column}"]`);
      if (el) drawRing(el);
    },
    clear: clearRing,
  };
}

function onClick(event: MouseEvent): void {
  const target = event.target instanceof Element ? event.target : null;
  if (!target) return;
  event.preventDefault();
  event.stopPropagation();
  const loc = sourceLoc(target);
  post({
    type: "anglesite:canvas-selection",
    file: loc?.file ?? null,
    line: loc?.line ?? null,
    column: loc?.column ?? null,
  });
  reportComputedStyles(target);
  clearRing();
  drawRing(target);
}

function reportComputedStyles(el: Element): void {
  const computed = getComputedStyle(el);
  const styles: Record<string, string> = {};
  for (const property of REPORTED_PROPERTIES) {
    styles[property] = computed.getPropertyValue(property);
  }
  post({ type: "anglesite:computed-styles", styles });
}

function drawRing(el: Element): void {
  const rect = el.getBoundingClientRect();
  const ring = document.createElement("div");
  ring.className = RING_CLASS;
  ring.style.cssText =
    `position:absolute;pointer-events:none;z-index:2147483646;` +
    `border:2px solid #0a84ff;border-radius:2px;` +
    `left:${rect.left + scrollX - 2}px;top:${rect.top + scrollY - 2}px;` +
    `width:${rect.width}px;height:${rect.height}px;`;
  document.body.appendChild(ring);
}

function clearRing(): void {
  document.querySelectorAll(`.${RING_CLASS}`).forEach((n) => n.remove());
}

interface WebKitHost {
  webkit?: { messageHandlers?: { anglesite?: { postMessage(msg: unknown): void } } };
}

function post(msg: unknown): void {
  (window as WebKitHost).webkit?.messageHandlers?.anglesite?.postMessage(msg);
}
```

- [ ] **Step 4: Route harness pages in `src/index.ts`**

Replace the file's boot logic (currently `install` on DOMContentLoaded) with:

```typescript
import { install } from "./overlay.js";
import { installComponentCanvas, isHarnessPage } from "./component-canvas.js";

function boot(): void {
  if (isHarnessPage()) {
    installComponentCanvas(); // harness canvas replaces click-to-edit
  } else {
    install();
  }
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", boot, { once: true });
} else {
  boot();
}
```

- [ ] **Step 5: Verify the overlay package**

Run: `npm run typecheck && npm run lint && npm test && npm run build`
Expected: all PASS; build emits `Resources/edit-overlay/overlay.js`.

- [ ] **Step 6: Commit**

```bash
cd <worktree-root>
git add JS/edit-overlay/src/component-canvas.ts JS/edit-overlay/src/index.ts JS/edit-overlay/test/component-canvas.test.ts
git commit -m "feat(overlay): component-canvas module for harness selection + computed styles"
```

### Task 10: Bridge message types + dispatch

**Files:**
- Create: `Sources/AnglesiteCore/ComponentCanvasMessages.swift`
- Modify: `Sources/AnglesiteBridge/AnglesiteScriptHandler.swift`
- Create: `Tests/AnglesiteCoreTests/ComponentCanvasMessagesTests.swift`
- Modify: `Tests/AnglesiteBridgeTests/AnglesiteScriptHandlerTests.swift`

**Interfaces:**
- Consumes: overlay wire shapes (Task 9).
- Produces: `CanvasSelectionMessage` / `ComputedStylesReport` (`static let messageType`, `static func decode(from: Any) -> Result<Self, DecodeError>`); `AnglesiteScriptHandler` gains optional `onCanvasSelection: @Sendable (CanvasSelectionMessage) async -> Void` and `onComputedStyles: @Sendable (ComputedStylesReport) async -> Void` (init parameters defaulting to nil, mirrored as `dispatch` parameters), with new `DispatchResult` cases `canvasSelectionHandled/Dropped` and `computedStylesHandled/Dropped`, plus `RejectionReason` cases `canvasSelectionDecode`/`computedStylesDecode`. Consumed by Task 12's canvas view.

- [ ] **Step 1: Write the failing message-decode tests**

Create `Tests/AnglesiteCoreTests/ComponentCanvasMessagesTests.swift`:

```swift
import Testing
@testable import AnglesiteCore

struct ComponentCanvasMessagesTests {
    @Test("Decodes a canvas selection") func decodesSelection() {
        let body: [String: Any] = [
            "type": "anglesite:canvas-selection",
            "file": "/site/src/components/Card.astro",
            "line": 7,
            "column": 1,
        ]
        guard case .success(let msg) = CanvasSelectionMessage.decode(from: body) else {
            Issue.record("expected success")
            return
        }
        #expect(msg.file == "/site/src/components/Card.astro")
        #expect(msg.line == 7)
        #expect(msg.column == 1)
    }

    @Test("Selection tolerates null loc (click on unannotated chrome)") func decodesNullLoc() {
        let body: [String: Any] = ["type": "anglesite:canvas-selection", "file": NSNull(), "line": NSNull(), "column": NSNull()]
        guard case .success(let msg) = CanvasSelectionMessage.decode(from: body) else {
            Issue.record("expected success")
            return
        }
        #expect(msg.file == nil)
        #expect(msg.line == nil)
    }

    @Test("Rejects wrong type tags") func rejectsWrongType() {
        let result = CanvasSelectionMessage.decode(from: ["type": "anglesite:apply-edit"])
        guard case .failure(.wrongType) = result else {
            Issue.record("expected wrongType")
            return
        }
    }

    @Test("Decodes computed styles") func decodesStyles() {
        let body: [String: Any] = [
            "type": "anglesite:computed-styles",
            "styles": ["display": "block", "color": "rgb(0, 0, 0)"],
        ]
        guard case .success(let report) = ComputedStylesReport.decode(from: body) else {
            Issue.record("expected success")
            return
        }
        #expect(report.styles["display"] == "block")
    }

    @Test("Computed styles reject a non-dictionary payload") func rejectsBadStyles() {
        let result = ComputedStylesReport.decode(from: ["type": "anglesite:computed-styles", "styles": "nope"])
        guard case .failure(.malformed) = result else {
            Issue.record("expected malformed")
            return
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ComponentCanvasMessagesTests`
Expected: FAIL to compile — types not found.

- [ ] **Step 3: Implement `Sources/AnglesiteCore/ComponentCanvasMessages.swift`**

```swift
import Foundation

/// JS → native messages from the component-harness canvas overlay module.
/// Wire shapes are defined in JS/edit-overlay/src/component-canvas.ts.
public enum ComponentCanvasDecodeError: Error, Equatable {
    case wrongType
    case malformed
}

public struct CanvasSelectionMessage: Sendable, Equatable {
    public static let messageType = "anglesite:canvas-selection"

    public let file: String?
    public let line: Int?
    public let column: Int?

    public init(file: String?, line: Int?, column: Int?) {
        self.file = file
        self.line = line
        self.column = column
    }

    public static func decode(from body: Any) -> Result<CanvasSelectionMessage, ComponentCanvasDecodeError> {
        guard let dict = body as? [String: Any], dict["type"] as? String == messageType else {
            return .failure(.wrongType)
        }
        return .success(CanvasSelectionMessage(
            file: dict["file"] as? String,
            line: dict["line"] as? Int,
            column: dict["column"] as? Int
        ))
    }
}

public struct ComputedStylesReport: Sendable, Equatable {
    public static let messageType = "anglesite:computed-styles"

    public let styles: [String: String]

    public init(styles: [String: String]) {
        self.styles = styles
    }

    public static func decode(from body: Any) -> Result<ComputedStylesReport, ComponentCanvasDecodeError> {
        guard let dict = body as? [String: Any], dict["type"] as? String == messageType else {
            return .failure(.wrongType)
        }
        guard let styles = dict["styles"] as? [String: String] else {
            return .failure(.malformed)
        }
        return .success(ComputedStylesReport(styles: styles))
    }
}
```

- [ ] **Step 4: Write the failing dispatch tests**

Append to `Tests/AnglesiteBridgeTests/AnglesiteScriptHandlerTests.swift` (reuse the file's existing `RecordingRouter`):

```swift
    @Test("Dispatch routes canvas-selection to its handler") func dispatchRoutesCanvasSelection() async {
        let router = RecordingRouter(reply: EditReply(id: "-", status: .failed, message: "unused"))
        let received = LockIsolated<CanvasSelectionMessage?>(nil)
        let result = await AnglesiteScriptHandler.dispatch(
            body: ["type": "anglesite:canvas-selection", "file": "/f.astro", "line": 7, "column": 1],
            via: router,
            onCanvasSelection: { msg in received.setValue(msg) }
        )
        guard case .canvasSelectionHandled = result else {
            Issue.record("expected .canvasSelectionHandled, got \(result)")
            return
        }
        #expect(received.value?.line == 7)
    }

    @Test("Canvas messages without a handler are dropped, not rejected") func dispatchDropsUnhandledCanvas() async {
        let router = RecordingRouter(reply: EditReply(id: "-", status: .failed, message: "unused"))
        let result = await AnglesiteScriptHandler.dispatch(
            body: ["type": "anglesite:computed-styles", "styles": ["display": "block"]],
            via: router
        )
        guard case .computedStylesDropped = result else {
            Issue.record("expected .computedStylesDropped, got \(result)")
            return
        }
    }
```

If the test file has no `LockIsolated` helper, add this minimal one at the bottom of the file:

```swift
final class LockIsolated<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { self._value = value }
    var value: Value {
        lock.withLock { _value }
    }
    func setValue(_ new: Value) {
        lock.withLock { _value = new }
    }
}
```

- [ ] **Step 5: Run to verify compile failure, then extend the handler**

Run: `swift test --filter AnglesiteScriptHandlerTests` → FAIL to compile (no such parameter/cases).

In `Sources/AnglesiteBridge/AnglesiteScriptHandler.swift`, mirroring the `onVisibleElements` pattern exactly:

1. Add typealiases beside `VisibleElementsHandler`:

```swift
public typealias CanvasSelectionHandler = @Sendable (CanvasSelectionMessage) async -> Void
public typealias ComputedStylesHandler = @Sendable (ComputedStylesReport) async -> Void
```

2. Add stored properties + init parameters (defaulting to `nil`, after `onVisibleElements`), assigning them in `init`.

3. Add `DispatchResult` cases: `canvasSelectionHandled`, `canvasSelectionDropped`, `computedStylesHandled`, `computedStylesDropped`; add `RejectionReason` cases `canvasSelectionDecode(ComponentCanvasDecodeError)` and `computedStylesDecode(ComponentCanvasDecodeError)`.

4. Add parameters `onCanvasSelection: CanvasSelectionHandler? = nil, onComputedStyles: ComputedStylesHandler? = nil` to the static `dispatch` signature, and two switch cases before `default:`:

```swift
    case CanvasSelectionMessage.messageType:
        switch CanvasSelectionMessage.decode(from: body) {
        case .success(let message):
            guard let handler = onCanvasSelection else { return .canvasSelectionDropped }
            await handler(message)
            return .canvasSelectionHandled
        case .failure(let error):
            return .rejected(.canvasSelectionDecode(error))
        }

    case ComputedStylesReport.messageType:
        switch ComputedStylesReport.decode(from: body) {
        case .success(let report):
            guard let handler = onComputedStyles else { return .computedStylesDropped }
            await handler(report)
            return .computedStylesHandled
        case .failure(let error):
            return .rejected(.computedStylesDecode(error))
        }
```

5. In `userContentController(_:didReceive:)`, pass the stored handlers through to `dispatch` and add the four new cases to its result switch (no webView reply needed — log-only, matching the visible-elements cases).

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter "ComponentCanvasMessagesTests|AnglesiteScriptHandlerTests"`
Expected: PASS (all, including pre-existing handler tests).

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteCore/ComponentCanvasMessages.swift Sources/AnglesiteBridge/AnglesiteScriptHandler.swift Tests/AnglesiteCoreTests/ComponentCanvasMessagesTests.swift Tests/AnglesiteBridgeTests/AnglesiteScriptHandlerTests.swift
git commit -m "feat(bridge): canvas-selection and computed-styles message dispatch"
```

### Task 11: Outline, harness URL, and knob defaults (Core logic)

**Files:**
- Create: `Sources/AnglesiteCore/ComponentOutline.swift`
- Modify: `Sources/AnglesiteCore/EditorKind.swift`
- Create: `Tests/AnglesiteCoreTests/ComponentOutlineTests.swift`

**Interfaces:**
- Consumes: `ComponentModel` (Task 7), `FileRef`/`FileGroup` (existing).
- Produces:
  - `ComponentOutline.rows(from: ComponentModel.Node) -> [ComponentOutline.Row]` where `Row: Identifiable { let node: ComponentModel.Node; let depth: Int; var id: String }` (DFS, skips the fragment root, depth 0 = top-level).
  - `ComponentOutline.node(atLine: Int, column: Int, in: ComponentModel.Node) -> ComponentModel.Node?` (exact `loc` match).
  - `HarnessURL.build(base: URL, componentPath: String, props: [String: String]) -> URL?` — `componentPath` like `src/components/nav/Item.astro` → `<base>/_anglesite/component/nav/Item?props=<json>`; empty props omit the query.
  - `KnobDefaults.value(for: ComponentModel.Prop) -> String` — declared default (quotes stripped) else type-based sample (`string`→`"Sample"`, `number`→`"1"`, `boolean`→`"false"`, other→`""`).
  - `EditorKind.component` for `FileGroup.components` files with the `.astro` extension (non-astro component-group files stay `.text`).

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/ComponentOutlineTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

struct ComponentOutlineTests {
    private func model() throws -> ComponentModel {
        try JSONDecoder().decode(ComponentModel.self, from: Data(ComponentModelTests.fixture.utf8))
    }

    @Test("Rows flatten the tree DFS with depths, skipping the fragment root") func rowsFlatten() throws {
        let rows = ComponentOutline.rows(from: try model().template)
        #expect(rows.map(\.node.id) == ["n1", "n2", "n3"])
        #expect(rows.map(\.depth) == [0, 1, 1])
    }

    @Test("Loc lookup finds the matching node") func locLookup() throws {
        let root = try model().template
        #expect(ComponentOutline.node(atLine: 7, column: 1, in: root)?.id == "n1")
        #expect(ComponentOutline.node(atLine: 99, column: 1, in: root) == nil)
    }

    @Test("Harness URL for nested components with props") func harnessURL() throws {
        let base = URL(string: "http://localhost:4321")!
        let url = HarnessURL.build(base: base, componentPath: "src/components/nav/Item.astro", props: ["title": "Hi"])
        #expect(url?.path == "/_anglesite/component/nav/Item")
        #expect(url?.query?.contains("props=") == true)

        let layout = HarnessURL.build(base: base, componentPath: "src/layouts/BaseLayout.astro", props: [:])
        #expect(layout?.path == "/_anglesite/component/BaseLayout")
        #expect(layout?.query == nil)

        #expect(HarnessURL.build(base: base, componentPath: "src/pages/index.astro", props: [:]) == nil)
    }

    @Test("Knob defaults prefer declared defaults, else type samples") func knobDefaults() {
        #expect(KnobDefaults.value(for: .init(name: "n", type: "number", optional: true, defaultValue: "1")) == "1")
        #expect(KnobDefaults.value(for: .init(name: "t", type: "string", optional: false, defaultValue: "\"Hello\"")) == "Hello")
        #expect(KnobDefaults.value(for: .init(name: "t", type: "string", optional: false, defaultValue: nil)) == "Sample")
        #expect(KnobDefaults.value(for: .init(name: "b", type: "boolean", optional: false, defaultValue: nil)) == "false")
    }

    @Test("Astro component files resolve to the component editor") func editorKind() {
        let astro = FileRef(url: URL(fileURLWithPath: "/s/src/components/Card.astro"), group: .components, name: "Card.astro")
        #expect(EditorKind.resolve(for: astro) == .component)
        let css = FileRef(url: URL(fileURLWithPath: "/s/src/components/card.css"), group: .components, name: "card.css")
        #expect(EditorKind.resolve(for: css) == .text)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ComponentOutlineTests`
Expected: FAIL to compile.

- [ ] **Step 3: Implement `Sources/AnglesiteCore/ComponentOutline.swift`**

```swift
import Foundation

/// Pure presentation logic for the Component Editor, kept in Core so it is
/// testable without the app target (hosted app tests don't run on CI).
public enum ComponentOutline {
    public struct Row: Sendable, Equatable, Identifiable {
        public let node: ComponentModel.Node
        public let depth: Int
        public var id: String { node.id }

        public init(node: ComponentModel.Node, depth: Int) {
            self.node = node
            self.depth = depth
        }
    }

    /// Depth-first rows for a flat SwiftUI List; the synthetic fragment root
    /// is skipped so depth 0 is the component's top-level markup.
    public static func rows(from root: ComponentModel.Node) -> [Row] {
        var rows: [Row] = []
        func visit(_ node: ComponentModel.Node, depth: Int) {
            rows.append(Row(node: node, depth: depth))
            for child in node.children { visit(child, depth: depth + 1) }
        }
        let topLevel = root.kind == .fragment ? root.children : [root]
        for node in topLevel { visit(node, depth: 0) }
        return rows
    }

    /// Exact source-loc match — the canvas reports the loc Astro stamped on
    /// the rendered element, which is the node's start position.
    public static func node(atLine line: Int, column: Int, in root: ComponentModel.Node) -> ComponentModel.Node? {
        if root.loc?.line == line, root.loc?.column == column { return root }
        for child in root.children {
            if let match = node(atLine: line, column: column, in: child) { return match }
        }
        return nil
    }
}

/// Builds harness-route URLs for the component canvas (route injected by the
/// template's anglesite-harness integration).
public enum HarnessURL {
    public static func build(base: URL, componentPath: String, props: [String: String]) -> URL? {
        let prefixes = ["src/components/", "src/layouts/"]
        guard let prefix = prefixes.first(where: { componentPath.hasPrefix($0) }),
              componentPath.hasSuffix(".astro")
        else { return nil }
        let name = String(componentPath.dropFirst(prefix.count).dropLast(".astro".count))
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/_anglesite/component/" + name
        if !props.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: props, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            components.queryItems = [URLQueryItem(name: "props", value: json)]
        }
        return components.url
    }
}

/// Sample prop values that make any component render standalone.
public enum KnobDefaults {
    public static func value(for prop: ComponentModel.Prop) -> String {
        if let declared = prop.defaultValue {
            return declared.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        }
        switch prop.type {
        case "string": return "Sample"
        case "number": return "1"
        case "boolean": return "false"
        default: return ""
        }
    }
}
```

- [ ] **Step 4: Add `.component` to `EditorKind`**

In `Sources/AnglesiteCore/EditorKind.swift`, add the case and resolution branch:

```swift
public enum EditorKind: Sendable, Equatable {
    case text
    case plist
    case component

    public static func resolve(for file: FileRef) -> EditorKind {
        if file.group == .metadata, file.url.pathExtension.lowercased() == "plist" {
            return .plist
        }
        if file.group == .components, file.url.pathExtension.lowercased() == "astro" {
            return .component
        }
        return .text
    }
}
```

- [ ] **Step 5: Run the full Swift suite**

Run: `swift test`
Expected: PASS. If an existing test asserts `EditorKind.resolve` returns `.text` for component files, update that expectation to `.component` in the same commit — it is the intended behavior change.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/ComponentOutline.swift Sources/AnglesiteCore/EditorKind.swift Tests/AnglesiteCoreTests/ComponentOutlineTests.swift
git commit -m "feat(core): outline rows, harness URLs, knob defaults, EditorKind.component"
```

### Task 12: Component Editor UI (app target)

**Files:**
- Create: `Sources/AnglesiteApp/ComponentEditorModel.swift`
- Create: `Sources/AnglesiteApp/ComponentEditorView.swift`
- Modify: `Sources/AnglesiteApp/MainPaneEditorView.swift`
- Modify: the `MainPaneEditorView(...)` call site (locate with `grep -rn "MainPaneEditorView(" Sources/AnglesiteApp/`)

**Interfaces:**
- Consumes: `ComponentModelClient`, `ComponentOutline`, `HarnessURL`, `KnobDefaults`, `CanvasSelectionMessage`, `ComputedStylesReport`, `EditorKind.component` (Tasks 7–11); `PreviewModel.readyURL` and `PreviewModel`'s runtime `mcpClient` getter (existing); `LoggingEditRouter` (existing stub — canvas sends no edits in this slice).
- Produces: `ComponentEditorContext { baseURL: URL?, modelClient: ComponentModelClient?, sourceRoot: URL }` handed to `MainPaneEditorView` as `var componentContext: ComponentEditorContext? = nil`.

- [ ] **Step 1: Implement `ComponentEditorModel`**

Create `Sources/AnglesiteApp/ComponentEditorModel.swift`:

```swift
import Foundation
import AnglesiteCore
import Observation

/// Everything MainPaneEditorView needs to host a component editor; built by
/// the site window from PreviewModel state.
struct ComponentEditorContext {
    let baseURL: URL?
    let modelClient: ComponentModelClient?
    let sourceRoot: URL
}

@MainActor
@Observable
final class ComponentEditorModel {
    let file: FileRef
    let context: ComponentEditorContext

    private(set) var model: ComponentModel?
    private(set) var loadError: String?
    private(set) var isLoading = false
    var selectedNodeID: String?
    var computedStyles: [String: String] = [:]
    var knobValues: [String: String] = [:]

    init(file: FileRef, context: ComponentEditorContext) {
        self.file = file
        self.context = context
    }

    /// Path of this component relative to the site's Source/ root.
    var relativePath: String {
        let root = context.sourceRoot.path(percentEncoded: false)
        let full = file.url.path(percentEncoded: false)
        guard full.hasPrefix(root) else { return file.name }
        return String(full.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var outlineRows: [ComponentOutline.Row] {
        guard let model else { return [] }
        return ComponentOutline.rows(from: model.template)
    }

    var harnessURL: URL? {
        guard let base = context.baseURL else { return nil }
        return HarnessURL.build(base: base, componentPath: relativePath, props: knobValues)
    }

    var selectedNode: ComponentModel.Node? {
        guard let id = selectedNodeID else { return nil }
        return outlineRows.first(where: { $0.node.id == id })?.node
    }

    func load() async {
        guard let client = context.modelClient else {
            loadError = "Site is not running yet."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await client.fetch(path: relativePath)
            model = fetched
            loadError = nil
            knobValues = Dictionary(
                uniqueKeysWithValues: (fetched.frontmatter?.props ?? []).map {
                    ($0.name, KnobDefaults.value(for: $0))
                }
            )
        } catch {
            loadError = String(describing: error)
        }
    }

    func canvasSelected(_ message: CanvasSelectionMessage) {
        guard let model, let line = message.line, let column = message.column else {
            selectedNodeID = nil
            return
        }
        selectedNodeID = ComponentOutline.node(atLine: line, column: column, in: model.template)?.id
    }
}
```

- [ ] **Step 2: Implement `ComponentEditorView` (+ canvas representable)**

Create `Sources/AnglesiteApp/ComponentEditorView.swift`:

```swift
import SwiftUI
import WebKit
import AnglesiteCore
import AnglesiteBridge

/// Read-only Component Editor (slice 1): outline + harness canvas + inspector.
struct ComponentEditorView: View {
    @State private var model: ComponentEditorModel
    /// Design (three-pane) vs Source (existing text editor) — the escape hatch.
    @State private var mode: Mode = .design
    @State private var webView: WKWebView?

    enum Mode: String, CaseIterable { case design = "Design", source = "Source" }

    let fileEditor: FileEditorModel

    init(file: FileRef, context: ComponentEditorContext, fileEditor: FileEditorModel) {
        _model = State(initialValue: ComponentEditorModel(file: file, context: context))
        self.fileEditor = fileEditor
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            switch mode {
            case .design: designPane
            case .source:
                TextEditor(text: .constant(fileEditor.text))
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
            }
        }
        .task { await model.load() }
        .onChange(of: model.selectedNodeID) { _, newValue in
            highlightInCanvas(nodeID: newValue)
        }
    }

    @ViewBuilder private var designPane: some View {
        if let error = model.loadError {
            ContentUnavailableView("Can't Open Component", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if model.isLoading || model.model == nil {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HSplitView {
                outline.frame(minWidth: 180, idealWidth: 220)
                canvas.frame(minWidth: 320).layoutPriority(1)
                inspector.frame(minWidth: 220, idealWidth: 260)
            }
        }
    }

    private var outline: some View {
        List(model.outlineRows, selection: $model.selectedNodeID) { row in
            HStack(spacing: 4) {
                Image(systemName: icon(for: row.node.kind))
                    .foregroundStyle(.secondary)
                Text(label(for: row.node))
            }
            .padding(.leading, CGFloat(row.depth) * 14)
            .tag(row.node.id)
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder private var canvas: some View {
        VStack(spacing: 0) {
            if let props = model.model?.frontmatter?.props, !props.isEmpty {
                knobsBar(props: props)
                Divider()
            }
            if let url = model.harnessURL {
                ComponentCanvasView(
                    url: url,
                    onSelection: { model.canvasSelected($0) },
                    onComputedStyles: { model.computedStyles = $0.styles },
                    onWebView: { webView = $0 }
                )
            } else {
                ContentUnavailableView("Dev Server Starting…", systemImage: "hourglass")
            }
        }
    }

    private func knobsBar(props: [ComponentModel.Prop]) -> some View {
        ScrollView(.horizontal) {
            HStack {
                ForEach(props, id: \.name) { prop in
                    LabeledContent(prop.name) {
                        TextField(prop.type, text: knobBinding(prop.name))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }
                }
            }
            .padding(8)
        }
    }

    private func knobBinding(_ name: String) -> Binding<String> {
        Binding(
            get: { model.knobValues[name] ?? "" },
            set: { model.knobValues[name] = $0 }
        )
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let node = model.selectedNode {
                    GroupBox("Selection") {
                        LabeledContent("Kind", value: node.kind.rawValue)
                        if let tag = node.tag { LabeledContent("Tag", value: tag) }
                        ForEach(node.attrs, id: \.name) { attr in
                            LabeledContent(attr.name, value: attr.value ?? "—")
                        }
                    }
                }
                GroupBox("Styles") {
                    if let styles = model.model?.styles, !styles.isEmpty {
                        ForEach(Array(styles.enumerated()), id: \.offset) { _, rule in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.media.map { "@media \($0)" } ?? "")
                                    .font(.caption2).foregroundStyle(.secondary)
                                Text(rule.selector).font(.system(.caption, design: .monospaced)).bold()
                                ForEach(rule.declarations, id: \.property) { decl in
                                    Text("\(decl.property): \(decl.value);")
                                        .font(.system(.caption, design: .monospaced))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 2)
                        }
                    } else {
                        Text("No scoped styles").foregroundStyle(.secondary)
                    }
                }
                GroupBox("Computed") {
                    if model.computedStyles.isEmpty {
                        Text("Select an element in the canvas").foregroundStyle(.secondary)
                    } else {
                        ForEach(model.computedStyles.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                            LabeledContent(key, value: value)
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                }
            }
            .padding(10)
        }
    }

    private func highlightInCanvas(nodeID: String?) {
        guard let webView else { return }
        guard let nodeID,
              let node = model.outlineRows.first(where: { $0.node.id == nodeID })?.node,
              let loc = node.loc
        else {
            webView.evaluateJavaScript("window.anglesiteCanvas?.clear?.()")
            return
        }
        webView.evaluateJavaScript("window.anglesiteCanvas?.highlight?.(\(loc.line), \(loc.column))")
    }

    private func icon(for kind: ComponentModel.Node.Kind) -> String {
        switch kind {
        case .fragment: "square.dashed"
        case .element: "chevron.left.forwardslash.chevron.right"
        case .component: "puzzlepiece.extension"
        case .expression: "curlybraces"
        case .slot: "tray"
        case .text: "text.alignleft"
        }
    }

    private func label(for node: ComponentModel.Node) -> String {
        switch node.kind {
        case .text: node.text ?? "text"
        case .expression: "{…}"
        default: node.tag ?? node.kind.rawValue
        }
    }
}

/// Harness-page WKWebView: same bridge as the preview, wired to the
/// component-canvas handlers. No edit routing in slice 1.
private struct ComponentCanvasView: NSViewRepresentable {
    let url: URL
    let onSelection: @MainActor (CanvasSelectionMessage) -> Void
    let onComputedStyles: @MainActor (ComputedStylesReport) -> Void
    var onWebView: (WKWebView) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var loadedURL: URL?
    }

    func makeNSView(context: Context) -> WKWebView {
        let onSelection = self.onSelection
        let onComputedStyles = self.onComputedStyles
        let handler = AnglesiteScriptHandler(
            router: LoggingEditRouter(),
            onCanvasSelection: { message in await MainActor.run { onSelection(message) } },
            onComputedStyles: { report in await MainActor.run { onComputedStyles(report) } }
        )
        let configuration = WebViewBridge.localDevConfiguration(handler: handler)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        WebViewBridge.applyPreviewDefaults(to: webView)
        webView.load(URLRequest(url: url))
        context.coordinator.loadedURL = url
        onWebView(webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        webView.load(URLRequest(url: url))
    }
}
```

Adjust `AnglesiteScriptHandler(router:onCanvasSelection:onComputedStyles:)` argument labels/order to the actual init extended in Task 10 (it also has `onVisibleElements` — pass nothing for it).

- [ ] **Step 3: Wire into `MainPaneEditorView`**

In `Sources/AnglesiteApp/MainPaneEditorView.swift`:

1. Add a property: `var componentContext: ComponentEditorContext? = nil`
2. Extend the editor switch:

```swift
                switch EditorKind.resolve(for: model.file) {
                case .text, .plist:
                    TextEditor(text: $model.text)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                case .component:
                    if let componentContext {
                        ComponentEditorView(file: model.file, context: componentContext, fileEditor: model)
                    } else {
                        TextEditor(text: $model.text)
                            .font(.system(.body, design: .monospaced))
                            .scrollContentBackground(.hidden)
                    }
                }
```

3. At the call site (find with `grep -rn "MainPaneEditorView(" Sources/AnglesiteApp/`), build the context from the site window's `PreviewModel` (`previewModel.readyURL`; the model client uses the same runtime getter PreviewModel's router uses) and the site's source directory (`site.sourceDirectory` from the surrounding `SiteStore.Site` / window state):

```swift
MainPaneEditorView(
    model: fileEditorModel,
    componentContext: ComponentEditorContext(
        baseURL: previewModel.readyURL,
        modelClient: ComponentModelClient(mcpClient: { [weak previewModel] in
            await previewModel?.runtime.mcpClient
        }),
        sourceRoot: site.sourceDirectory
    )
)
```

Match the existing parameter order/labels at that call site; if `previewModel.runtime` is not accessible there, add a `var componentModelClient: ComponentModelClient` computed property on `PreviewModel` (built exactly like its `editRouter`'s `mcpClient` closure) and use it.

- [ ] **Step 4: Build the app and run the suite**

```bash
ANGLESITE_PLUGIN_SRC=/Users/dwk/Developer/github.com/Anglesite/anglesite scripts/copy-plugin.sh
xcodegen generate
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .
```

Expected: BUILD SUCCEEDED; tests PASS.

- [ ] **Step 5: Manual smoke (launch the app)**

Launch the built app, open a site that has a component (the template ships `Hcard.astro`), select it in the navigator's Components group, and verify: outline lists the markup; canvas renders the harness; clicking the canvas selects the outline row and fills Computed; selecting an outline row draws the blue ring in the canvas; knob edits re-render; Source mode shows the raw file. Record any deviation as a bug before proceeding.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteApp/ComponentEditorModel.swift Sources/AnglesiteApp/ComponentEditorView.swift Sources/AnglesiteApp/MainPaneEditorView.swift <call-site file>
git commit -m "feat(app): read-only Component Editor (outline + harness canvas + inspector)"
```

### Task 13: Plugin-gated end-to-end test

**Files:**
- Create: `Tests/AnglesiteCoreTests/ComponentModelEndToEndTests.swift`

**Interfaces:**
- Consumes: `ComponentModelClient` (Task 8), plugin `get_component_model` (Task 4), and the server-boot helper pattern from the existing `Tests/AnglesiteCoreTests/AppliesEditEndToEndTests.swift`.

- [ ] **Step 1: Read the existing e2e harness**

Read `Tests/AnglesiteCoreTests/AppliesEditEndToEndTests.swift` and reuse its exact mechanism for: the `.enabled(if:)` trait on `ANGLESITE_PLUGIN_PATH`, booting `MCPClient` against `<plugin>/server/index.mjs` with a temp `ANGLESITE_PROJECT_ROOT`, and teardown. The new file mirrors that scaffolding with this test body:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite(
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["ANGLESITE_PLUGIN_PATH"] != nil,
             "Set ANGLESITE_PLUGIN_PATH to the plugin checkout to run")
)
struct ComponentModelEndToEndTests {
    @Test("get_component_model round-trips into ComponentModel") func roundTrips() async throws {
        // 1. Temp project root with a fixture component (mirror AppliesEditEndToEndTests' setup).
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("anglesite-cm-e2e-\(UUID().uuidString)")
        let componentsDir = projectRoot.appendingPathComponent("src/components")
        try FileManager.default.createDirectory(at: componentsDir, withIntermediateDirectories: true)
        try """
        ---
        interface Props {
          title: string;
        }
        const { title } = Astro.props;
        ---
        <article class="card"><h2>{title}</h2><slot /></article>
        <style>.card { padding: 1rem; }</style>
        """.write(to: componentsDir.appendingPathComponent("Card.astro"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: projectRoot) }

        // 2. Boot the plugin MCP server exactly as AppliesEditEndToEndTests does.
        let client = try await Self.startPluginServer(projectRoot: projectRoot)

        // 3. Fetch + decode via the production client.
        let modelClient = ComponentModelClient(toolCaller: { name, args in
            try await client.callTool(name: name, arguments: args)
        })
        let model = try await modelClient.fetch(path: "src/components/Card.astro")

        #expect(model.path == "src/components/Card.astro")
        #expect(model.template.children.first?.tag == "article")
        #expect(model.frontmatter?.props.first?.name == "title")
        #expect(model.styles.first?.selector == ".card")
        #expect(model.clientScript == nil)
    }
}
```

Implement `startPluginServer(projectRoot:)` as a copy of the boot helper in `AppliesEditEndToEndTests` (same `ProcessSupervisor`/`MCPClient` startup, `ANGLESITE_PLUGIN_PATH`-derived server path, initialize handshake, and shutdown handling). Keep the helper `private static` in this file.

- [ ] **Step 2: Run gated-off, then gated-on**

```bash
swift test --filter ComponentModelEndToEndTests            # expect: SKIPPED (trait)
ANGLESITE_PLUGIN_PATH=/Users/dwk/Developer/github.com/Anglesite/anglesite \
  swift test --filter ComponentModelEndToEndTests          # expect: PASS
```

(The second run requires Part A's branch checked out in the plugin repo with `npm install` done there.)

- [ ] **Step 3: Run the full suite and commit**

```bash
swift test
git add Tests/AnglesiteCoreTests/ComponentModelEndToEndTests.swift
git commit -m "test(core): plugin-gated e2e for get_component_model"
```

### Task 14: Finish the branch

- [ ] **Step 1: Full verification pass**

```bash
cd JS/edit-overlay && npm run typecheck && npm run lint && npm test && cd -
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
```

All green, plus the Task 12 manual smoke done.

- [ ] **Step 2: Push and open the app PR**

Use the `superpowers:finishing-a-development-branch` skill. PR title: `feat: read-only Component Editor (slice 1 of #<epic-issue>)`. Body: link the spec, note the paired plugin PR from Task 5, and list the follow-up slices. **Push before citing the PR.**

---

## Self-Review Notes (resolved inline)

- **Spec coverage:** §2.1–2.2 → Tasks 1–4; §3 harness → Task 6; §4 UI (read-only subset) → Tasks 11–12; canvas messages → Tasks 9–10; §8 testing → per-task tests + Task 13; §9 slice 1 scope respected (no write ops, no STTextView).
- **Deliberate slice-1 simplifications** (per spec phasing): inspector is read-only lists (full editable panel is Slice 2); knobs are plain text fields (typed controls arrive with the props form in Slice 4); `matched vs all rules` split needs canvas `Element.matches()` support — deferred to Slice 2 with the styles panel.
- **Type consistency check:** `ComponentModel.Span(start:end:)`, `ComponentOutline.rows/node`, `HarnessURL.build(base:componentPath:props:)`, `KnobDefaults.value(for:)`, `CanvasSelectionMessage`/`ComputedStylesReport` names match across Tasks 7–13. Overlay message `type` strings match the Swift `messageType` constants and the plugin is untouched by them (bridge-only).
- **Known risk:** `@astrojs/compiler` AST node-type names (Task 1 Step 5) and the exact `AnglesiteScriptHandler` init shape (Task 12 Step 2) are verified against reality at execution time; both tasks say how to adapt without weakening tests.
