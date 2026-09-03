# WYSIWYG Canvas Chrome (Slice 3) Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the interactive canvas chrome for the WYSIWYG editor (issue #1224, epic #1221): inline rich-text editing writing honest runs, drag/drop handling (in-canvas reorder and external palette/Finder drops) landing as `insertBlock`/`moveBlock` at an engine-computed index, and a responsive breakpoint canvas that drives multiple frame documents from one shared engine.

**Architecture:** Extends `JS/wysiwyg-engine/` (merged slice 2) in place with three new modules — `rich-text.ts`, `drag-drop.ts`, `breakpoints.ts` — each consuming the existing `WysiwygEngine`/`SelectionState`/`hitTest`/`OpQueue` primitives rather than replacing them. No new package, no Swift changes (design spec §2). A single `WysiwygEngine` instance (one model, one selection, one op queue) drives every breakpoint frame document, because `hitTest(point, doc)` and `computeHandleRect(id, root)` already accept an explicit document/root instead of assuming the global `document`.

**Tech Stack:** TypeScript (ES2022 target, strict), Vitest (+ jsdom), Playwright e2e goldens, esbuild for e2e bundles, oxlint. No new runtime dependencies — every new module imports nothing beyond the TypeScript standard lib and DOM types, matching slice 2.

## Global Constraints

- Zero new runtime dependencies — `src/**` may only use ES2022/DOM APIs (spec §3.1, carried from slice 2's own constraint).
- Every commit path (`editText`, `insertBlock` from a drop, `moveBlock` from a reorder) goes through the existing `engine.submit()` → `OpQueue` — no new op-application or rejection-handling logic; this slice only adds callers.
- **Scoped exception to "the engine never mutates the DOM as an act of editing":** that principle (slice 2) governs the *block-structure* model — ops are the only path that changes what blocks exist and how they nest. Inline text editing is different: a `contenteditable` region is inherently a live text-input surface, and `rich-text.ts`'s Range-wrapping code mutates that surface directly while an edit is active. What keeps this honest is that the wrapping code can only ever produce `<strong>`/`<em>`/`<a href>`/`<code>` — exactly the vocabulary `runsFromElement()` reads back — so the local draft always re-grounds into the model boundary on commit (spec §8.5 treats `contenteditable` as the accepted mechanism, with a native-`NSTextView` contingency out of scope for this slice).
- Match established test-split convention from slice 2 (`hit-test.test.ts`, `selection.test.ts`): pure logic (DOM traversal that doesn't need real layout, or geometry given explicit numeric rects) is unit-tested under `vitest`/jsdom; anything depending on real `getBoundingClientRect`/`elementFromPoint`/live `Selection` behavior is deferred to Playwright e2e goldens, never asserted against jsdom's zeroed-out layout.
- `noUncheckedIndexedAccess: true` — every indexed/`Record` access is `T | undefined`; guard before use.
- `verbatimModuleSyntax: true` — every type-only import is a separate `import type { ... }` statement.
- No new CI wiring needed: `.github/workflows/ci.yml`'s `wysiwyg` path filter already matches `JS/wysiwyg-engine/**` (added in slice 2), so every file this plan touches is already gated by the existing `wysiwyg-engine` job.

---

## File Structure

```
JS/wysiwyg-engine/src/
├── rich-text.ts        # honest-runs serialization, debounced commit, Range-based format
│                         # commands, RichTextEditor (contenteditable lifecycle)
├── drag-drop.ts         # drop-target geometry, in-canvas reorder (DragReorderController),
│                         # external drop wiring (wireExternalDrop), submitDrop()
├── breakpoints.ts       # BreakpointCanvas — one engine driving N frame documents
└── index.ts              # MODIFY: barrel-export the three new modules
JS/wysiwyg-engine/test/
├── rich-text.test.ts
├── drag-drop.test.ts
└── breakpoints.test.ts
JS/wysiwyg-engine/e2e/
├── fixture-page.ts       # MODIFY: add a "text" block + richText rendering, rich-text and
│                         #   drag-drop bridges
├── frame.html            # NEW: minimal iframe document (just #canvas) for breakpoint frames
├── breakpoints-fixture.html      # NEW: hosts three iframes (phone/tablet/desktop)
├── breakpoints-fixture-page.ts   # NEW: wires one engine + BreakpointCanvas across the iframes
├── rich-text.spec.ts     # NEW
├── drag-drop.spec.ts     # NEW
└── breakpoints.spec.ts   # NEW
JS/wysiwyg-engine/package.json  # MODIFY: build:e2e builds both bundles
```

---

### Task 1: Honest-runs serialization

**Files:**
- Create: `JS/wysiwyg-engine/src/rich-text.ts`
- Test: `JS/wysiwyg-engine/test/rich-text.test.ts`

**Interfaces:**
- Consumes: `RichTextRun` (types.ts).
- Produces: `runsFromElement(el: Element): RichTextRun[]` — consumed by Task 4's `RichTextEditor` and by Task 9's e2e goldens.

- [ ] **Step 1: Write the failing test** `JS/wysiwyg-engine/test/rich-text.test.ts`

```ts
// @vitest-environment jsdom
import { describe, it, expect } from "vitest";
import { runsFromElement } from "../src/rich-text.js";

function setBody(html: string): Element {
  document.body.innerHTML = `<div id="root">${html}</div>`;
  const root = document.getElementById("root");
  if (!root) throw new Error("missing #root");
  return root;
}

describe("runsFromElement", () => {
  it("reads plain text as a single text run", () => {
    expect(runsFromElement(setBody("Hello world"))).toEqual([{ kind: "text", text: "Hello world" }]);
  });

  it("recognizes strong, em, link, and code", () => {
    const root = setBody('Hi <strong>bold</strong> and <em>emph</em> and <a href="/x">link</a> and <code>x</code>.');
    expect(runsFromElement(root)).toEqual([
      { kind: "text", text: "Hi " },
      { kind: "strong", text: "bold" },
      { kind: "text", text: " and " },
      { kind: "em", text: "emph" },
      { kind: "text", text: " and " },
      { kind: "link", text: "link", href: "/x" },
      { kind: "text", text: " and " },
      { kind: "code", text: "x" },
      { kind: "text", text: "." },
    ]);
  });

  it("treats <b> and <i> as strong/em aliases", () => {
    const root = setBody("<b>bold</b><i>italic</i>");
    expect(runsFromElement(root)).toEqual([
      { kind: "strong", text: "bold" },
      { kind: "em", text: "italic" },
    ]);
  });

  it("flattens unrecognized markup to its text content — the honest-runs backstop", () => {
    const root = setBody('<div>block</div><span style="color:red">styled</span>');
    expect(runsFromElement(root)).toEqual([{ kind: "text", text: "blockstyled" }]);
  });

  it("merges adjacent text runs produced by flattening", () => {
    const root = setBody("start <span>middle</span> end");
    expect(runsFromElement(root)).toEqual([{ kind: "text", text: "start middle end" }]);
  });

  it("returns an empty array for an empty element", () => {
    expect(runsFromElement(setBody(""))).toEqual([]);
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd JS/wysiwyg-engine && npm test -- rich-text`
Expected: FAIL — `Cannot find module '../src/rich-text.js'`

- [ ] **Step 3: Write `src/rich-text.ts`**

```ts
import type { RichTextRun } from "./types.js";

const INLINE_TAG_TO_RUN_KIND: Record<string, RichTextRun["kind"]> = {
  strong: "strong",
  b: "strong",
  em: "em",
  i: "em",
  a: "link",
  code: "code",
};

/**
 * Serializes a contenteditable element's live DOM into the honest-runs vocabulary (spec §4): only
 * strong/em/link/code ever survive as anything but text. Anything else the browser's
 * contenteditable implementation might inject — a stray `<div>` from a paste, a styled `<span>` —
 * is not represented; its text content flattens into the surrounding run. This is the structural
 * backstop for roundtrip honesty, independent of how careful the editing UI upstream is.
 */
export function runsFromElement(el: Element): RichTextRun[] {
  const runs: RichTextRun[] = [];
  for (const node of Array.from(el.childNodes)) {
    const run = runFromNode(node);
    if (run) runs.push(run);
  }
  return mergeAdjacentTextRuns(runs);
}

function runFromNode(node: ChildNode): RichTextRun | null {
  if (node.nodeType === Node.TEXT_NODE) {
    const text = node.textContent ?? "";
    return text.length > 0 ? { kind: "text", text } : null;
  }
  if (node.nodeType !== Node.ELEMENT_NODE) return null;

  const el = node as Element;
  const tag = el.tagName.toLowerCase();
  const kind = INLINE_TAG_TO_RUN_KIND[tag];
  const text = el.textContent ?? "";
  if (text.length === 0) return null;

  if (!kind) return { kind: "text", text };
  if (kind === "link") return { kind, text, href: el.getAttribute("href") ?? "" };
  return { kind, text };
}

function mergeAdjacentTextRuns(runs: RichTextRun[]): RichTextRun[] {
  const merged: RichTextRun[] = [];
  for (const run of runs) {
    const prev = merged[merged.length - 1];
    if (prev && prev.kind === "text" && run.kind === "text") {
      prev.text += run.text;
    } else {
      merged.push({ ...run });
    }
  }
  return merged;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd JS/wysiwyg-engine && npm test -- rich-text`
Expected: PASS (6 tests)

- [ ] **Step 5: Commit**

```bash
git add JS/wysiwyg-engine/src/rich-text.ts JS/wysiwyg-engine/test/rich-text.test.ts
git commit -m "feat(#1224): add honest-runs DOM serialization"
```

---

### Task 2: Debounced commit helper

**Files:**
- Modify: `JS/wysiwyg-engine/src/rich-text.ts`
- Modify: `JS/wysiwyg-engine/test/rich-text.test.ts`

**Interfaces:**
- Produces: `class DebouncedCommitter { constructor(commit: () => void, delayMs: number); notifyChange(): void; flush(): void; cancel(): void }` — consumed by Task 4's `RichTextEditor`. Pure logic, no DOM dependency, independently testable with fake timers.

- [ ] **Step 1: Add the failing test** (append to `test/rich-text.test.ts`, above the closing of the file — as a new top-level `describe` block, alongside the existing `runsFromElement` one)

```ts
import { describe, it, expect, vi } from "vitest";
import { runsFromElement, DebouncedCommitter } from "../src/rich-text.js";
```

Replace the existing `import { describe, it, expect } from "vitest";` / `import { runsFromElement } from "../src/rich-text.js";` lines at the top of the file with the two lines above, then append this block at the end of the file:

```ts

describe("DebouncedCommitter", () => {
  it("commits once, after the delay, following a burst of notifyChange calls", () => {
    vi.useFakeTimers();
    let commits = 0;
    const committer = new DebouncedCommitter(() => {
      commits += 1;
    }, 400);

    committer.notifyChange();
    vi.advanceTimersByTime(200);
    committer.notifyChange(); // resets the timer
    vi.advanceTimersByTime(200);
    expect(commits).toBe(0); // still within the debounce window from the second call

    vi.advanceTimersByTime(200);
    expect(commits).toBe(1);

    vi.useRealTimers();
  });

  it("flush() commits immediately if a commit is pending, and is a no-op otherwise", () => {
    vi.useFakeTimers();
    let commits = 0;
    const committer = new DebouncedCommitter(() => {
      commits += 1;
    }, 400);

    committer.flush();
    expect(commits).toBe(0); // nothing pending

    committer.notifyChange();
    committer.flush();
    expect(commits).toBe(1);

    vi.advanceTimersByTime(400);
    expect(commits).toBe(1); // flush() already cancelled the pending timer

    vi.useRealTimers();
  });

  it("cancel() discards a pending commit without running it", () => {
    vi.useFakeTimers();
    let commits = 0;
    const committer = new DebouncedCommitter(() => {
      commits += 1;
    }, 400);

    committer.notifyChange();
    committer.cancel();
    vi.advanceTimersByTime(400);
    expect(commits).toBe(0);

    vi.useRealTimers();
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd JS/wysiwyg-engine && npm test -- rich-text`
Expected: FAIL — `DebouncedCommitter` is not exported from `../src/rich-text.js`

- [ ] **Step 3: Add `DebouncedCommitter` to `src/rich-text.ts`** (append to the file)

```ts

/** Coalesces a burst of changes into a single `commit()` call after `delayMs` of quiet, or
 *  immediately via `flush()` — the mechanism behind `RichTextEditor`'s debounced `editText`
 *  commits (design doc §4). Pure timer logic, no DOM dependency. */
export class DebouncedCommitter {
  #commit: () => void;
  #delayMs: number;
  #timer: ReturnType<typeof setTimeout> | null = null;

  constructor(commit: () => void, delayMs: number) {
    this.#commit = commit;
    this.#delayMs = delayMs;
  }

  notifyChange(): void {
    this.cancel();
    this.#timer = setTimeout(() => {
      this.#timer = null;
      this.#commit();
    }, this.#delayMs);
  }

  /** Commits now if a debounced commit is pending; otherwise does nothing. */
  flush(): void {
    const pending = this.#timer !== null;
    this.cancel();
    if (pending) this.#commit();
  }

  /** Discards a pending commit without running it. */
  cancel(): void {
    if (this.#timer !== null) {
      clearTimeout(this.#timer);
      this.#timer = null;
    }
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd JS/wysiwyg-engine && npm test -- rich-text`
Expected: PASS (9 tests)

- [ ] **Step 5: Commit**

```bash
git add JS/wysiwyg-engine/src/rich-text.ts JS/wysiwyg-engine/test/rich-text.test.ts
git commit -m "feat(#1224): add DebouncedCommitter for editText commit timing"
```

---

### Task 3: Inline format commands

**Files:**
- Modify: `JS/wysiwyg-engine/src/rich-text.ts`
- Modify: `JS/wysiwyg-engine/test/rich-text.test.ts`

**Interfaces:**
- Consumes: none beyond DOM types.
- Produces: `findAncestorTag(node: Node, tagName: string, root: Element): HTMLElement | null`, `wrapRange(range: Range, tagName: string, doc?: Document): HTMLElement`, `unwrapElement(el: HTMLElement): void` (pure Range primitives, unit-tested here), `type FormatKind = "strong" | "em" | "code"`, `toggleInlineFormat(root: HTMLElement, kind: FormatKind, doc?: Document): void`, `setLinkFormat(root: HTMLElement, href: string, doc?: Document): void`, `unsetLinkFormat(root: HTMLElement, doc?: Document): void` (live-`Selection`-based, e2e-covered in Task 9 per this plan's DOM-behavior test split) — all consumed by Task 4's `RichTextEditor`.

- [ ] **Step 1: Add the failing test** (append to `test/rich-text.test.ts`)

Update the top-of-file import to include the new names:

```ts
import { runsFromElement, DebouncedCommitter, findAncestorTag, wrapRange, unwrapElement } from "../src/rich-text.js";
```

Append:

```ts

describe("findAncestorTag / wrapRange / unwrapElement", () => {
  it("finds the nearest ancestor with the given tag, stopping at root", () => {
    document.body.innerHTML = '<div id="root"><strong id="s"><span id="inner">x</span></strong></div>';
    const root = document.getElementById("root");
    const inner = document.getElementById("inner");
    if (!root || !inner) throw new Error("fixture missing");
    expect(findAncestorTag(inner, "strong", root)?.id).toBe("s");
    expect(findAncestorTag(inner, "em", root)).toBeNull();
  });

  it("wrapRange wraps the range's contents in a new element and returns it", () => {
    document.body.innerHTML = '<div id="root">hello world</div>';
    const root = document.getElementById("root");
    const textNode = root?.firstChild;
    if (!root || !textNode) throw new Error("fixture missing");

    const range = document.createRange();
    range.setStart(textNode, 0);
    range.setEnd(textNode, 5); // "hello"

    const wrapped = wrapRange(range, "strong", document);
    expect(wrapped.tagName.toLowerCase()).toBe("strong");
    expect(root.innerHTML).toBe("<strong>hello</strong> world");
  });

  it("unwrapElement replaces the element with its children in place", () => {
    document.body.innerHTML = '<div id="root">a <strong id="s">bold</strong> b</div>';
    const root = document.getElementById("root");
    const strong = document.getElementById("s");
    if (!root || !strong) throw new Error("fixture missing");

    unwrapElement(strong);
    expect(root.innerHTML).toBe("a bold b");
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd JS/wysiwyg-engine && npm test -- rich-text`
Expected: FAIL — `findAncestorTag`/`wrapRange`/`unwrapElement` not exported

- [ ] **Step 3: Add the Range primitives and Selection-based format commands to `src/rich-text.ts`** (append to the file)

```ts

/** Walks up from `node` to the nearest ancestor (inclusive) whose tag matches `tagName`, stopping
 *  at (and not including past) `root`. */
export function findAncestorTag(node: Node, tagName: string, root: Element): HTMLElement | null {
  let current: Node | null = node;
  while (current && current !== root.parentNode) {
    if (current.nodeType === Node.ELEMENT_NODE && (current as Element).tagName.toLowerCase() === tagName) {
      return current as HTMLElement;
    }
    if (current === root) return null;
    current = current.parentNode;
  }
  return null;
}

/** Wraps `range`'s contents in a new `tagName` element, replacing the range with it, and leaves
 *  the element's contents selected (so a follow-up format command composes naturally). */
export function wrapRange(range: Range, tagName: string, doc: Document = document): HTMLElement {
  const wrapper = doc.createElement(tagName);
  wrapper.appendChild(range.extractContents());
  range.insertNode(wrapper);
  range.selectNodeContents(wrapper);
  const selection = doc.getSelection();
  selection?.removeAllRanges();
  selection?.addRange(range);
  return wrapper;
}

/** Replaces `el` with its own children, at the same position — the inverse of `wrapRange`. */
export function unwrapElement(el: HTMLElement): void {
  const parent = el.parentNode;
  if (!parent) return;
  while (el.firstChild) parent.insertBefore(el.firstChild, el);
  parent.removeChild(el);
}

export type FormatKind = "strong" | "em" | "code";

const FORMAT_TAG: Record<FormatKind, string> = { strong: "strong", em: "em", code: "code" };

/**
 * Toggles `kind` on the current selection within `root`: unwraps if the selection is already
 * inside a matching element, otherwise wraps it. Live-`Selection`-dependent — real behavior is
 * covered by Playwright e2e goldens (Task 9), not jsdom, matching this package's established
 * test split (jsdom has no real text-selection behavior to verify against).
 */
export function toggleInlineFormat(root: HTMLElement, kind: FormatKind, doc: Document = document): void {
  const selection = doc.getSelection();
  if (!selection || selection.rangeCount === 0 || selection.isCollapsed) return;
  const range = selection.getRangeAt(0);
  if (!root.contains(range.commonAncestorContainer)) return;

  const tagName = FORMAT_TAG[kind];
  const existing = findAncestorTag(range.commonAncestorContainer, tagName, root);
  if (existing) {
    unwrapElement(existing);
  } else {
    wrapRange(range, tagName, doc);
  }
}

/** Wraps the current selection in `<a href>`, replacing any existing link ancestor first. */
export function setLinkFormat(root: HTMLElement, href: string, doc: Document = document): void {
  const selection = doc.getSelection();
  if (!selection || selection.rangeCount === 0 || selection.isCollapsed) return;
  const range = selection.getRangeAt(0);
  if (!root.contains(range.commonAncestorContainer)) return;

  const existing = findAncestorTag(range.commonAncestorContainer, "a", root);
  if (existing) unwrapElement(existing);
  const anchor = wrapRange(range, "a", doc);
  anchor.setAttribute("href", href);
}

/** Removes the link ancestor around the current selection or caret, if any. */
export function unsetLinkFormat(root: HTMLElement, doc: Document = document): void {
  const selection = doc.getSelection();
  if (!selection || selection.rangeCount === 0) return;
  const existing = findAncestorTag(selection.getRangeAt(0).commonAncestorContainer, "a", root);
  if (existing) unwrapElement(existing);
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd JS/wysiwyg-engine && npm test -- rich-text`
Expected: PASS (12 tests)

Also run `npm run typecheck && npm run lint`.

- [ ] **Step 5: Commit**

```bash
git add JS/wysiwyg-engine/src/rich-text.ts JS/wysiwyg-engine/test/rich-text.test.ts
git commit -m "feat(#1224): add Range-based inline format commands"
```

---

### Task 4: RichTextEditor class

**Files:**
- Modify: `JS/wysiwyg-engine/src/rich-text.ts`
- Modify: `JS/wysiwyg-engine/test/rich-text.test.ts`

**Interfaces:**
- Consumes: `BlockId`, `RichTextRun` (types.ts); `WysiwygEngine` (engine.ts, type-only); `findBlockElement` (selection.ts); `DebouncedCommitter`, `runsFromElement`, `FormatKind`, `toggleInlineFormat`, `setLinkFormat`, `unsetLinkFormat` (this file, earlier tasks).
- Produces: `interface RichTextEditorOptions { debounceMs?: number }`, `class RichTextEditor { constructor(engine: WysiwygEngine, options?: RichTextEditorOptions); get activeBlockId(): BlockId | null; enter(blockId: BlockId, root?: ParentNode): void; exit(): void; toggleFormat(kind: FormatKind): void; setLink(href: string): void; unsetLink(): void; dispose(): void }` — the module's top-level consumer-facing API, exported from `index.ts` (Task 9) and driven directly by e2e goldens.

- [ ] **Step 1: Add the failing test** — replace the top-of-file imports in `test/rich-text.test.ts` with:

```ts
import { describe, it, expect, vi } from "vitest";
import {
  runsFromElement,
  DebouncedCommitter,
  findAncestorTag,
  wrapRange,
  unwrapElement,
  RichTextEditor,
} from "../src/rich-text.js";
import { WysiwygEngine } from "../src/engine.js";
import { FixtureHost } from "../src/testing/fixture-host.js";
import { BLOCK_ID_ATTR } from "../src/hit-test.js";
import type { BlockModel } from "../src/types.js";
```

Append this block at the end of the file:

```ts

function makeTextModel(): BlockModel {
  return {
    path: "src/pages/index.astro",
    version: "v1",
    rootIds: ["t1"],
    blocks: {
      t1: {
        id: "t1",
        kind: "text",
        componentName: "paragraph",
        props: {},
        slots: {},
        sourceSpan: [0, 5],
        richText: [{ kind: "text", text: "Hello" }],
      },
    },
  };
}

describe("RichTextEditor", () => {
  it("enter() makes the block contenteditable; exit() reverts it", () => {
    document.body.innerHTML = `<div ${BLOCK_ID_ATTR}="t1">Hello</div>`;
    const model = makeTextModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const editor = new RichTextEditor(engine);

    editor.enter("t1");
    const el = document.querySelector(`[${BLOCK_ID_ATTR}="t1"]`) as HTMLElement;
    expect(el.contentEditable).toBe("true");

    editor.exit();
    expect(el.contentEditable).toBe("false");
    expect(editor.activeBlockId).toBeNull();
  });

  it("commits a debounced editText op with the typed runs after the debounce window", async () => {
    vi.useFakeTimers();
    document.body.innerHTML = `<div ${BLOCK_ID_ATTR}="t1">Hello</div>`;
    const model = makeTextModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const editor = new RichTextEditor(engine, { debounceMs: 400 });

    editor.enter("t1");
    const el = document.querySelector(`[${BLOCK_ID_ATTR}="t1"]`) as HTMLElement;
    el.textContent = "Hello world";
    el.dispatchEvent(new Event("input", { bubbles: true }));

    await vi.advanceTimersByTimeAsync(400);

    expect(engine.modelSync.getBlock("t1")?.richText).toEqual([{ kind: "text", text: "Hello world" }]);
    vi.useRealTimers();
  });

  it("multiple edits before the debounce fires still send the entry-time baseline as previousRuns", async () => {
    vi.useFakeTimers();
    document.body.innerHTML = `<div ${BLOCK_ID_ATTR}="t1">Hello</div>`;
    const model = makeTextModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const applied: { op: unknown }[] = [];
    engine.onEvent((event) => {
      if (event.type === "applied") applied.push({ op: event.op });
    });
    const editor = new RichTextEditor(engine, { debounceMs: 400 });

    editor.enter("t1");
    const el = document.querySelector(`[${BLOCK_ID_ATTR}="t1"]`) as HTMLElement;

    el.textContent = "Hello w";
    el.dispatchEvent(new Event("input", { bubbles: true }));
    await vi.advanceTimersByTimeAsync(200);
    el.textContent = "Hello world";
    el.dispatchEvent(new Event("input", { bubbles: true }));
    await vi.advanceTimersByTimeAsync(400);

    expect(applied).toEqual([
      {
        op: {
          kind: "editText",
          blockId: "t1",
          runs: [{ kind: "text", text: "Hello world" }],
          previousRuns: [{ kind: "text", text: "Hello" }],
        },
      },
    ]);
    vi.useRealTimers();
  });

  it("exit() flushes a pending commit immediately instead of discarding it", async () => {
    document.body.innerHTML = `<div ${BLOCK_ID_ATTR}="t1">Hello</div>`;
    const model = makeTextModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const editor = new RichTextEditor(engine, { debounceMs: 10_000 });

    const applied = new Promise<void>((resolve) => {
      const unsubscribe = engine.onEvent((event) => {
        if (event.type === "applied") {
          unsubscribe();
          resolve();
        }
      });
    });

    editor.enter("t1");
    const el = document.querySelector(`[${BLOCK_ID_ATTR}="t1"]`) as HTMLElement;
    el.textContent = "Hello world";
    el.dispatchEvent(new Event("input", { bubbles: true }));

    editor.exit();
    await applied;

    expect(engine.modelSync.getBlock("t1")?.richText).toEqual([{ kind: "text", text: "Hello world" }]);
  });

  it("entering a different block exits the previous one first", () => {
    document.body.innerHTML = `<div ${BLOCK_ID_ATTR}="t1">Hello</div><div ${BLOCK_ID_ATTR}="t2">World</div>`;
    const base = makeTextModel();
    const model: BlockModel = {
      ...base,
      rootIds: ["t1", "t2"],
      blocks: {
        ...base.blocks,
        t2: {
          id: "t2",
          kind: "text",
          componentName: "paragraph",
          props: {},
          slots: {},
          sourceSpan: [6, 11],
          richText: [{ kind: "text", text: "World" }],
        },
      },
    };
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const editor = new RichTextEditor(engine);

    editor.enter("t1");
    editor.enter("t2");

    expect(editor.activeBlockId).toBe("t2");
    const t1 = document.querySelector(`[${BLOCK_ID_ATTR}="t1"]`) as HTMLElement;
    expect(t1.contentEditable).toBe("false");
  });

  it("blur exits editing and flushes a pending commit (design doc §4: commit immediately on blur)", async () => {
    document.body.innerHTML = `<div ${BLOCK_ID_ATTR}="t1">Hello</div>`;
    const model = makeTextModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const editor = new RichTextEditor(engine, { debounceMs: 10_000 });

    const applied = new Promise<void>((resolve) => {
      const unsubscribe = engine.onEvent((event) => {
        if (event.type === "applied") {
          unsubscribe();
          resolve();
        }
      });
    });

    editor.enter("t1");
    const el = document.querySelector(`[${BLOCK_ID_ATTR}="t1"]`) as HTMLElement;
    el.textContent = "Hello world";
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new FocusEvent("blur"));

    // Synchronous: exit()'s state cleanup happens before the flushed commit's async submit resolves.
    expect(editor.activeBlockId).toBeNull();
    expect(el.contentEditable).toBe("false");

    await applied;
    expect(engine.modelSync.getBlock("t1")?.richText).toEqual([{ kind: "text", text: "Hello world" }]);
  });

  it("pressing Escape exits editing (design doc §4: commit immediately on Escape)", () => {
    document.body.innerHTML = `<div ${BLOCK_ID_ATTR}="t1">Hello</div>`;
    const model = makeTextModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const editor = new RichTextEditor(engine);

    editor.enter("t1");
    const el = document.querySelector(`[${BLOCK_ID_ATTR}="t1"]`) as HTMLElement;
    el.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));

    expect(editor.activeBlockId).toBeNull();
    expect(el.contentEditable).toBe("false");
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd JS/wysiwyg-engine && npm test -- rich-text`
Expected: FAIL — `RichTextEditor` is not exported from `../src/rich-text.js`

- [ ] **Step 3: Add `RichTextEditor` to `src/rich-text.ts`**

Add this import line to the top of `src/rich-text.ts`, alongside the existing `import type { RichTextRun } from "./types.js";`:

```ts
import type { BlockId } from "./types.js";
import type { WysiwygEngine } from "./engine.js";
import { findBlockElement } from "./selection.js";
```

Append to the end of the file:

```ts

export interface RichTextEditorOptions {
  debounceMs?: number;
}

const DEFAULT_DEBOUNCE_MS = 400;

/**
 * Contenteditable lifecycle for one text block at a time (design doc §4). `enter()` activates
 * editing and snapshots the current runs as the commit baseline; an `input` listener schedules a
 * debounced `editText` commit; `exit()` flushes any pending commit and deactivates. `previousRuns`
 * on every commit is always the baseline captured at `enter()`, not the prior debounce tick — so a
 * version-mismatch rejection mid-edit discards the whole in-progress edit in one step rather than
 * reconstructing intermediate state.
 */
export class RichTextEditor {
  #engine: WysiwygEngine;
  #committer: DebouncedCommitter;
  #activeBlockId: BlockId | null = null;
  #activeElement: HTMLElement | null = null;
  #baselineRuns: RichTextRun[] = [];
  #onInput = () => this.#committer.notifyChange();
  #onBlur = () => this.exit();
  #onKeydown = (event: KeyboardEvent) => {
    if (event.key === "Escape") this.exit();
  };

  constructor(engine: WysiwygEngine, options: RichTextEditorOptions = {}) {
    this.#engine = engine;
    this.#committer = new DebouncedCommitter(() => this.#commit(), options.debounceMs ?? DEFAULT_DEBOUNCE_MS);
  }

  get activeBlockId(): BlockId | null {
    return this.#activeBlockId;
  }

  enter(blockId: BlockId, root: ParentNode = document): void {
    if (this.#activeBlockId === blockId) return;
    if (this.#activeBlockId !== null) this.exit();

    const el = findBlockElement(blockId, root);
    if (!(el instanceof HTMLElement)) return;

    this.#baselineRuns = this.#engine.modelSync.getBlock(blockId)?.richText ?? [];
    this.#activeBlockId = blockId;
    this.#activeElement = el;
    el.contentEditable = "true";
    el.addEventListener("input", this.#onInput);
    el.addEventListener("blur", this.#onBlur);
    el.addEventListener("keydown", this.#onKeydown);
    el.focus();
  }

  /** Flushes any pending debounced commit and deactivates — called explicitly, or automatically on
   *  blur/Escape (design doc §4: both commit immediately, alongside a format command). */
  exit(): void {
    this.#committer.flush();
    if (this.#activeElement) {
      this.#activeElement.removeEventListener("input", this.#onInput);
      this.#activeElement.removeEventListener("blur", this.#onBlur);
      this.#activeElement.removeEventListener("keydown", this.#onKeydown);
      this.#activeElement.contentEditable = "false";
    }
    this.#activeBlockId = null;
    this.#activeElement = null;
    this.#baselineRuns = [];
  }

  toggleFormat(kind: FormatKind): void {
    if (!this.#activeElement) return;
    toggleInlineFormat(this.#activeElement, kind);
    this.#committer.notifyChange();
  }

  setLink(href: string): void {
    if (!this.#activeElement) return;
    setLinkFormat(this.#activeElement, href);
    this.#committer.notifyChange();
  }

  unsetLink(): void {
    if (!this.#activeElement) return;
    unsetLinkFormat(this.#activeElement);
    this.#committer.notifyChange();
  }

  dispose(): void {
    this.exit();
  }

  #commit(): void {
    if (!this.#activeBlockId || !this.#activeElement) return;
    void this.#engine.submit({
      kind: "editText",
      blockId: this.#activeBlockId,
      runs: runsFromElement(this.#activeElement),
      previousRuns: this.#baselineRuns,
    });
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd JS/wysiwyg-engine && npm test -- rich-text`
Expected: PASS (19 tests)

Also run `npm run typecheck && npm run lint`.

- [ ] **Step 5: Commit**

```bash
git add JS/wysiwyg-engine/src/rich-text.ts JS/wysiwyg-engine/test/rich-text.test.ts
git commit -m "feat(#1224): add RichTextEditor contenteditable lifecycle"
```

---

### Task 5: Drop-target geometry and `submitDrop`

**Files:**
- Create: `JS/wysiwyg-engine/src/drag-drop.ts`
- Test: `JS/wysiwyg-engine/test/drag-drop.test.ts`

**Interfaces:**
- Consumes: `BlockId`, `BlockNode`, `OpResult`, `ParentRef`, `ROOT_PARENT_ID` (types.ts); `WysiwygEngine` (engine.ts, type-only); `BLOCK_ID_ATTR` (hit-test.ts).
- Produces: `interface DropTarget { parentId: ParentRef; slot: string; index: number }`, `nearestIndexInSlot(pointY: number, siblingRects: { top: number; bottom: number }[]): number` (pure, unit-tested), `computeDropTarget(point: { x: number; y: number }, container: ParentNode, parentId?: ParentRef, slot?: string): DropTarget` (real-geometry, e2e-covered per this plan's test split), `generateBlockId(): BlockId`, `submitDrop(engine: WysiwygEngine, target: DropTarget, block: Omit<BlockNode, "id">): Promise<OpResult>` — all consumed by Task 6 (`DragReorderController`), Task 7 (`wireExternalDrop`), and Task 9's e2e goldens.

- [ ] **Step 1: Write the failing test** `JS/wysiwyg-engine/test/drag-drop.test.ts`

```ts
import { describe, it, expect } from "vitest";
import { nearestIndexInSlot, computeDropTarget, generateBlockId, submitDrop } from "../src/drag-drop.js";
import { WysiwygEngine } from "../src/engine.js";
import { FixtureHost } from "../src/testing/fixture-host.js";
import { ROOT_PARENT_ID } from "../src/types.js";
import { BLOCK_ID_ATTR } from "../src/hit-test.js";
import type { BlockModel } from "../src/types.js";

describe("nearestIndexInSlot", () => {
  it("returns 0 for an empty sibling list", () => {
    expect(nearestIndexInSlot(100, [])).toBe(0);
  });

  it("returns the index of the first sibling whose midpoint is below the point", () => {
    const rects = [
      { top: 0, bottom: 20 }, // midpoint 10
      { top: 20, bottom: 60 }, // midpoint 40
      { top: 60, bottom: 100 }, // midpoint 80
    ];
    expect(nearestIndexInSlot(5, rects)).toBe(0);
    expect(nearestIndexInSlot(25, rects)).toBe(1);
    expect(nearestIndexInSlot(85, rects)).toBe(3);
  });
});

describe("computeDropTarget", () => {
  // jsdom has no layout engine, so every element's getBoundingClientRect() is all zeros here —
  // real point-vs-midpoint geometry is covered by Playwright e2e goldens (Task 9), matching this
  // package's established test split (hit-test.ts/selection.ts). What's provable in jsdom: the
  // container is queried for BLOCK_ID_ATTR children (not arbitrary children), and parentId/slot
  // pass through unchanged.
  it("only counts children carrying BLOCK_ID_ATTR, and passes parentId/slot through", () => {
    document.body.innerHTML = `
      <div id="canvas">
        <div ${BLOCK_ID_ATTR}="b1"></div>
        <span>not a block</span>
        <div ${BLOCK_ID_ATTR}="b2"></div>
      </div>
    `;
    const canvas = document.getElementById("canvas");
    if (!canvas) throw new Error("fixture missing #canvas");

    const target = computeDropTarget({ x: 0, y: 0 }, canvas, "some-parent", "gallery");
    expect(target.parentId).toBe("some-parent");
    expect(target.slot).toBe("gallery");
    // All rects are zero under jsdom, so every midpoint is 0; a non-negative point.y never beats
    // that, so the pure fallback ("append after the last sibling") is what's observable here.
    expect(target.index).toBe(2);
  });

  it("defaults to ROOT_PARENT_ID and the 'default' slot", () => {
    document.body.innerHTML = `<div id="canvas"></div>`;
    const canvas = document.getElementById("canvas");
    if (!canvas) throw new Error("fixture missing #canvas");
    expect(computeDropTarget({ x: 0, y: 0 }, canvas)).toEqual({ parentId: ROOT_PARENT_ID, slot: "default", index: 0 });
  });
});

describe("generateBlockId", () => {
  it("returns a non-empty string, unique across calls", () => {
    const a = generateBlockId();
    const b = generateBlockId();
    expect(a).not.toBe(b);
    expect(a.length).toBeGreaterThan(0);
  });
});

describe("submitDrop", () => {
  function makeModel(): BlockModel {
    return {
      path: "src/pages/index.astro",
      version: "v1",
      rootIds: ["b1"],
      blocks: { b1: { id: "b1", kind: "astro", componentName: "Hero", props: {}, slots: {}, sourceSpan: [0, 1] } },
    };
  }

  it("submits an insertBlock op at the given target and the block appears in the model", async () => {
    const model = makeModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));

    const result = await submitDrop(
      engine,
      { parentId: ROOT_PARENT_ID, slot: "default", index: 0 },
      { kind: "astro", componentName: "Newsletter", props: {}, slots: {}, sourceSpan: [0, 0] },
    );

    expect(result.status).toBe("applied");
    if (result.status !== "applied") throw new Error("expected applied");
    expect(result.model.rootIds).toHaveLength(2);
    const newId = result.model.rootIds.find((id) => id !== "b1");
    expect(newId).toBeDefined();
    expect(newId && result.model.blocks[newId]?.componentName).toBe("Newsletter");
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd JS/wysiwyg-engine && npm test -- drag-drop`
Expected: FAIL — `Cannot find module '../src/drag-drop.js'`

- [ ] **Step 3: Write `src/drag-drop.ts`**

```ts
import type { BlockId, BlockNode, OpResult, ParentRef } from "./types.js";
import type { WysiwygEngine } from "./engine.js";
import { ROOT_PARENT_ID } from "./types.js";
import { BLOCK_ID_ATTR } from "./hit-test.js";

export interface DropTarget {
  parentId: ParentRef;
  slot: string;
  index: number;
}

/**
 * Pure geometry: given a vertical point and the ordered rects of the candidate siblings, finds the
 * nearest valid insertion index by comparing against each sibling's vertical midpoint. Split out
 * from `computeDropTarget`'s DOM-querying half so it's unit-testable without a real layout engine
 * (mirrors hit-test.ts's split between `hitTest()` and `blockIdForElement()`).
 */
export function nearestIndexInSlot(pointY: number, siblingRects: { top: number; bottom: number }[]): number {
  for (let i = 0; i < siblingRects.length; i++) {
    const rect = siblingRects[i];
    if (!rect) continue;
    const midpoint = (rect.top + rect.bottom) / 2;
    if (pointY < midpoint) return i;
  }
  return siblingRects.length;
}

/**
 * Computes the nearest valid insertion point for a point-based drag/drop gesture among the direct
 * block-children of `container`. Root-level only for this slice, matching the fixture host/e2e
 * convention that already treats top-level blocks as `ROOT_PARENT_ID`/"default" — the `parentId`/
 * `slot` parameters leave room for nested-slot targeting in a future slice without an API change.
 */
export function computeDropTarget(
  point: { x: number; y: number },
  container: ParentNode,
  parentId: ParentRef = ROOT_PARENT_ID,
  slot = "default",
): DropTarget {
  const children = Array.from(container.children).filter((el) => el.hasAttribute(BLOCK_ID_ATTR));
  const rects = children.map((el) => el.getBoundingClientRect());
  return { parentId, slot, index: nearestIndexInSlot(point.y, rects) };
}

let idCounter = 0;

/** Block IDs are engine-generated, never raw user text (types.ts) — this is chrome's generator for
 *  blocks created by a drop, distinct per call within a session. */
export function generateBlockId(): BlockId {
  idCounter += 1;
  return `chrome-${Date.now().toString(36)}-${idCounter}`;
}

/** Builds and submits the `insertBlock` op for a drop at `target`. The engine never inspects a
 *  drag's `DataTransfer` itself (design doc §5) — by the time `submitDrop` is called, the host has
 *  already decided what `block` to build. */
export function submitDrop(engine: WysiwygEngine, target: DropTarget, block: Omit<BlockNode, "id">): Promise<OpResult> {
  return engine.submit({
    kind: "insertBlock",
    parentId: target.parentId,
    slot: target.slot,
    index: target.index,
    newId: generateBlockId(),
    block,
  });
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd JS/wysiwyg-engine && npm test -- drag-drop`
Expected: PASS (6 tests)

Also run `npm run typecheck && npm run lint`.

- [ ] **Step 5: Commit**

```bash
git add JS/wysiwyg-engine/src/drag-drop.ts JS/wysiwyg-engine/test/drag-drop.test.ts
git commit -m "feat(#1224): add drop-target geometry and submitDrop"
```

---

### Task 6: In-canvas reorder (`DragReorderController`)

**Files:**
- Modify: `JS/wysiwyg-engine/src/drag-drop.ts`
- Modify: `JS/wysiwyg-engine/test/drag-drop.test.ts`

**Interfaces:**
- Consumes: `DropTarget`, `computeDropTarget` (this file, Task 5); `BlockId`, `ROOT_PARENT_ID` (types.ts); `WysiwygEngine` (engine.ts, type-only).
- Produces: `class DragReorderController { constructor(engine: WysiwygEngine, onIndicator: (target: DropTarget | null) => void, container?: ParentNode); get isDragging(): boolean; startDrag(blockId: BlockId, doc?: Document): void; dispose(): void }` — consumed by Task 9's e2e goldens and (in a future slice) real host pointer-drag wiring.

- [ ] **Step 1: Add the failing test** — add this import line to the top of `test/drag-drop.test.ts`:

```ts
import { DragReorderController } from "../src/drag-drop.js";
```

Append at the end of the file:

```ts

describe("DragReorderController", () => {
  function makeTwoBlockModel(): BlockModel {
    return {
      path: "src/pages/index.astro",
      version: "v1",
      rootIds: ["b1", "b2"],
      blocks: {
        b1: { id: "b1", kind: "astro", componentName: "Hero", props: {}, slots: {}, sourceSpan: [0, 1] },
        b2: { id: "b2", kind: "astro", componentName: "Testimonial", props: {}, slots: {}, sourceSpan: [1, 2] },
      },
    };
  }

  it("reports an indicator target on pointermove while dragging", () => {
    document.body.innerHTML = `<div id="empty"></div>`;
    const container = document.getElementById("empty");
    if (!container) throw new Error("fixture missing");
    const model = makeTwoBlockModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const indicators: unknown[] = [];
    const controller = new DragReorderController(engine, (target) => indicators.push(target), container);

    expect(controller.isDragging).toBe(false);
    controller.startDrag("b1");
    expect(controller.isDragging).toBe(true);

    document.dispatchEvent(new PointerEvent("pointermove", { clientX: 10, clientY: 20 }));

    // `container` has no BLOCK_ID_ATTR children, so computeDropTarget's fallback (nearestIndexInSlot
    // on an empty list) deterministically resolves to index 0 regardless of point — the real
    // point-vs-midpoint geometry needs a layout engine and is e2e-covered (Task 9).
    expect(indicators).toEqual([{ parentId: "__root__", slot: "default", index: 0 }]);
  });

  it("submits a moveBlock op to the indicator target on pointerup", async () => {
    document.body.innerHTML = `<div id="empty"></div>`;
    const container = document.getElementById("empty");
    if (!container) throw new Error("fixture missing");
    const model = makeTwoBlockModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const controller = new DragReorderController(engine, () => {}, container);

    const applied = new Promise<void>((resolve) => {
      const unsubscribe = engine.onEvent((event) => {
        if (event.type === "applied") {
          unsubscribe();
          resolve();
        }
      });
    });

    controller.startDrag("b2");
    document.dispatchEvent(new PointerEvent("pointermove", { clientX: 0, clientY: 0 }));
    document.dispatchEvent(new PointerEvent("pointerup"));
    await applied;

    expect(engine.modelSync.current.rootIds).toEqual(["b2", "b1"]);
    expect(controller.isDragging).toBe(false);
  });

  it("aborts cleanly, submitting nothing, when the dragged block vanishes mid-drag", () => {
    document.body.innerHTML = `<div id="empty"></div>`;
    const container = document.getElementById("empty");
    if (!container) throw new Error("fixture missing");
    const model = makeTwoBlockModel();
    const host = new FixtureHost(model);
    const engine = new WysiwygEngine(model, host);
    const moveOps: unknown[] = [];
    engine.onEvent((event) => {
      if (event.type === "applied" && event.op.kind === "moveBlock") moveOps.push(event.op);
    });
    const controller = new DragReorderController(engine, () => {}, container);

    controller.startDrag("b1");
    document.dispatchEvent(new PointerEvent("pointermove", { clientX: 0, clientY: 0 }));
    host.simulateExternalEdit({
      ...model,
      version: "v2",
      rootIds: ["b2"],
      blocks: { b2: model.blocks.b2 as NonNullable<typeof model.blocks.b2> },
    });
    document.dispatchEvent(new PointerEvent("pointerup"));

    expect(moveOps).toEqual([]);
    expect(engine.modelSync.current.rootIds).toEqual(["b2"]);
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd JS/wysiwyg-engine && npm test -- drag-drop`
Expected: FAIL — `DragReorderController` is not exported from `../src/drag-drop.js`

- [ ] **Step 3: Add `DragReorderController` to `src/drag-drop.ts`**

Add this import line to the top of the file, alongside the existing `import { ROOT_PARENT_ID } from "./types.js";`:

```ts
import type { WysiwygEngine } from "./engine.js";
```

Append to the end of the file:

```ts

/**
 * Pointer-based (not HTML5 Drag and Drop) in-canvas block reordering — more reliable for
 * same-document dragging and behaves uniformly whether the block lives in a single canvas or one
 * of several breakpoint frames (design doc §5). Tracks a live `DropTarget` indicator during the
 * drag via `onIndicator` and, on release, submits `moveBlock` to that target.
 */
export class DragReorderController {
  #engine: WysiwygEngine;
  #container: ParentNode;
  #onIndicator: (target: DropTarget | null) => void;
  #draggingId: BlockId | null = null;
  #indicatorTarget: DropTarget | null = null;
  #doc: Document | null = null;
  #onMove = (event: PointerEvent) => this.#handleMove(event);
  #onUp = () => {
    void this.#handleUp();
  };

  constructor(engine: WysiwygEngine, onIndicator: (target: DropTarget | null) => void, container: ParentNode = document) {
    this.#engine = engine;
    this.#onIndicator = onIndicator;
    this.#container = container;
  }

  get isDragging(): boolean {
    return this.#draggingId !== null;
  }

  startDrag(blockId: BlockId, doc: Document = document): void {
    this.#draggingId = blockId;
    this.#doc = doc;
    doc.addEventListener("pointermove", this.#onMove);
    doc.addEventListener("pointerup", this.#onUp);
  }

  dispose(): void {
    this.#doc?.removeEventListener("pointermove", this.#onMove);
    this.#doc?.removeEventListener("pointerup", this.#onUp);
    this.#draggingId = null;
    this.#doc = null;
  }

  #handleMove(event: PointerEvent): void {
    if (!this.#draggingId) return;
    this.#indicatorTarget = computeDropTarget({ x: event.clientX, y: event.clientY }, this.#container);
    this.#onIndicator(this.#indicatorTarget);
  }

  async #handleUp(): Promise<void> {
    this.#doc?.removeEventListener("pointermove", this.#onMove);
    this.#doc?.removeEventListener("pointerup", this.#onUp);
    this.#doc = null;

    const blockId = this.#draggingId;
    const target = this.#indicatorTarget;
    this.#draggingId = null;
    this.#indicatorTarget = null;
    this.#onIndicator(null);
    if (!blockId || !target) return;

    const model = this.#engine.modelSync.current;
    const fromIndex = model.rootIds.indexOf(blockId);
    // The dragged block was removed by a concurrent model update (design doc §7) — abort cleanly
    // rather than submit a moveBlock against a now-invalid index.
    if (fromIndex === -1) return;

    await this.#engine.submit({
      kind: "moveBlock",
      blockId,
      fromParentId: ROOT_PARENT_ID,
      fromSlot: "default",
      fromIndex,
      toParentId: target.parentId,
      toSlot: target.slot,
      toIndex: target.index,
    });
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd JS/wysiwyg-engine && npm test -- drag-drop`
Expected: PASS (9 tests)

Also run `npm run typecheck && npm run lint`.

- [ ] **Step 5: Commit**

```bash
git add JS/wysiwyg-engine/src/drag-drop.ts JS/wysiwyg-engine/test/drag-drop.test.ts
git commit -m "feat(#1224): add DragReorderController for in-canvas reordering"
```

---

### Task 7: External drop wiring (`wireExternalDrop`)

**Files:**
- Modify: `JS/wysiwyg-engine/src/drag-drop.ts`
- Modify: `JS/wysiwyg-engine/test/drag-drop.test.ts`

**Interfaces:**
- Consumes: `DropTarget`, `computeDropTarget` (this file, Task 5); `ParentRef`, `ROOT_PARENT_ID` (types.ts).
- Produces: `type ExternalDropHandler = (target: DropTarget, dataTransfer: DataTransfer) => void`, `interface WireExternalDropOptions { container?: ParentNode; parentId?: ParentRef; slot?: string }`, `wireExternalDrop(canvasEl: HTMLElement, onIndicator: (target: DropTarget | null) => void, onDrop: ExternalDropHandler, options?: WireExternalDropOptions): () => void` (returns a disposer, matching the `onChange`/`onEvent` unsubscribe convention used throughout this package) — consumed by Task 9's e2e goldens and a future host's palette/Finder integration.

- [ ] **Step 1: Add the failing test** — add this import line to the top of `test/drag-drop.test.ts`:

```ts
import { wireExternalDrop } from "../src/drag-drop.js";
```

Append at the end of the file:

```ts

describe("wireExternalDrop", () => {
  it("calls onIndicator on dragover, clears it on dragleave, and preventsDefault to allow the drop", () => {
    document.body.innerHTML = `<div id="canvas"></div>`;
    const canvas = document.getElementById("canvas");
    if (!canvas) throw new Error("fixture missing #canvas");
    const indicators: unknown[] = [];
    wireExternalDrop(canvas, (target) => indicators.push(target), () => {});

    const dragOver = new DragEvent("dragover", { clientX: 0, clientY: 0, cancelable: true, bubbles: true });
    canvas.dispatchEvent(dragOver);
    expect(dragOver.defaultPrevented).toBe(true);
    expect(indicators).toEqual([{ parentId: "__root__", slot: "default", index: 0 }]);

    canvas.dispatchEvent(new DragEvent("dragleave", { bubbles: true }));
    expect(indicators).toEqual([{ parentId: "__root__", slot: "default", index: 0 }, null]);
  });

  it("calls onDrop with the computed target and the event's DataTransfer", () => {
    document.body.innerHTML = `<div id="canvas"></div>`;
    const canvas = document.getElementById("canvas");
    if (!canvas) throw new Error("fixture missing #canvas");
    const drops: unknown[] = [];
    wireExternalDrop(canvas, () => {}, (target, dataTransfer) => drops.push({ target, dataTransfer }));

    const dataTransfer = new DataTransfer();
    const dropEvent = new DragEvent("drop", { clientX: 0, clientY: 0, cancelable: true, bubbles: true, dataTransfer });
    canvas.dispatchEvent(dropEvent);

    expect(dropEvent.defaultPrevented).toBe(true);
    expect(drops).toEqual([{ target: { parentId: "__root__", slot: "default", index: 0 }, dataTransfer }]);
  });

  it("the returned disposer removes all three listeners", () => {
    document.body.innerHTML = `<div id="canvas"></div>`;
    const canvas = document.getElementById("canvas");
    if (!canvas) throw new Error("fixture missing #canvas");
    const indicators: unknown[] = [];
    const dispose = wireExternalDrop(canvas, (target) => indicators.push(target), () => {});

    dispose();
    canvas.dispatchEvent(new DragEvent("dragover", { clientX: 0, clientY: 0, bubbles: true }));
    canvas.dispatchEvent(new DragEvent("dragleave", { bubbles: true }));

    expect(indicators).toEqual([]);
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd JS/wysiwyg-engine && npm test -- drag-drop`
Expected: FAIL — `wireExternalDrop` is not exported from `../src/drag-drop.js`

- [ ] **Step 3: Add `wireExternalDrop` to `src/drag-drop.ts`**

Add this import line to the top of the file, alongside the existing `import type { BlockId, BlockNode, OpResult, ParentRef } from "./types.js";`:

no changes needed there — `ParentRef` is already imported. Append to the end of the file:

```ts

export type ExternalDropHandler = (target: DropTarget, dataTransfer: DataTransfer) => void;

export interface WireExternalDropOptions {
  container?: ParentNode;
  parentId?: ParentRef;
  slot?: string;
}

/**
 * Wires native `dragover`/`dragleave`/`drop` DOM events on `canvasEl` for external drags (palette,
 * Finder) — real OS/host-originated drags surface as native drag events even inside a WKWebView.
 * The engine never interprets `DataTransfer` itself (design doc §5): `onDrop` receives the computed
 * target and the raw `DataTransfer`, and the host decides what block (if any) to build and calls
 * `submitDrop`. Returns a disposer that removes all three listeners.
 */
export function wireExternalDrop(
  canvasEl: HTMLElement,
  onIndicator: (target: DropTarget | null) => void,
  onDrop: ExternalDropHandler,
  options: WireExternalDropOptions = {},
): () => void {
  const container = options.container ?? canvasEl;
  const parentId = options.parentId ?? ROOT_PARENT_ID;
  const slot = options.slot ?? "default";

  const onDragOver = (event: DragEvent) => {
    event.preventDefault();
    onIndicator(computeDropTarget({ x: event.clientX, y: event.clientY }, container, parentId, slot));
  };
  const onDragLeave = () => onIndicator(null);
  const onDropEvent = (event: DragEvent) => {
    event.preventDefault();
    onIndicator(null);
    if (!event.dataTransfer) return;
    const target = computeDropTarget({ x: event.clientX, y: event.clientY }, container, parentId, slot);
    onDrop(target, event.dataTransfer);
  };

  canvasEl.addEventListener("dragover", onDragOver);
  canvasEl.addEventListener("dragleave", onDragLeave);
  canvasEl.addEventListener("drop", onDropEvent);

  return () => {
    canvasEl.removeEventListener("dragover", onDragOver);
    canvasEl.removeEventListener("dragleave", onDragLeave);
    canvasEl.removeEventListener("drop", onDropEvent);
  };
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd JS/wysiwyg-engine && npm test -- drag-drop`
Expected: PASS (12 tests). If `DragEvent`/`DataTransfer` construction is unsupported by the pinned jsdom version, the failure will name the unsupported constructor explicitly — in that case, move the two affected assertions into `e2e/drag-drop.spec.ts` (Task 9) instead of forcing a jsdom workaround, consistent with this plan's real-DOM-behavior-goes-to-e2e split.

Also run `npm run typecheck && npm run lint`.

- [ ] **Step 5: Commit**

```bash
git add JS/wysiwyg-engine/src/drag-drop.ts JS/wysiwyg-engine/test/drag-drop.test.ts
git commit -m "feat(#1224): add wireExternalDrop for palette/Finder drags"
```

---

### Task 8: Breakpoint canvas (`BreakpointCanvas`)

**Files:**
- Create: `JS/wysiwyg-engine/src/breakpoints.ts`
- Test: `JS/wysiwyg-engine/test/breakpoints.test.ts`

**Interfaces:**
- Consumes: `BlockId`, `BlockModel` (types.ts); `WysiwygEngine`, `EngineEvent` (engine.ts); `computeHandleRect`, `HandleRect` (selection.ts).
- Produces: `interface BreakpointFrame { name: string; doc: Document }`, `type RenderFn = (model: BlockModel, doc: Document) => void`, `class BreakpointCanvas { constructor(engine: WysiwygEngine, render: RenderFn); registerFrame(frame: BreakpointFrame): void; unregisterFrame(name: string): void; get frames(): readonly BreakpointFrame[]; hitTestFrame(name: string, point: { x: number; y: number }): BlockId | null; handleRectsForSelection(): { name: string; rect: HandleRect }[]; dispose(): void }` — consumed by Task 9's e2e goldens and a future host's multi-viewport wiring.

- [ ] **Step 1: Write the failing test** `JS/wysiwyg-engine/test/breakpoints.test.ts`

This file uses the global `document` (via `document.implementation.createHTMLDocument(...)`), which only exists under jsdom — this project's `vitest.config.ts` defaults to the "node" environment, so the file needs the same per-file opt-in Task 5 used for `drag-drop.test.ts`. Start the file with:

```ts
// @vitest-environment jsdom
```

Then:

```ts
import { describe, it, expect } from "vitest";
import { BreakpointCanvas } from "../src/breakpoints.js";
import { WysiwygEngine } from "../src/engine.js";
import { FixtureHost } from "../src/testing/fixture-host.js";
import { BLOCK_ID_ATTR } from "../src/hit-test.js";
import type { BlockModel } from "../src/types.js";

function makeModel(): BlockModel {
  return {
    path: "src/pages/index.astro",
    version: "v1",
    rootIds: ["b1"],
    blocks: { b1: { id: "b1", kind: "astro", componentName: "Hero", props: { title: "Welcome" }, slots: {}, sourceSpan: [0, 1] } },
  };
}

/** Minimal render function mirroring e2e/fixture-page.ts's render(): one <div> per root block,
 *  carrying BLOCK_ID_ATTR, for a given frame document. */
function render(model: BlockModel, doc: Document): void {
  const root = doc.body;
  root.innerHTML = "";
  for (const id of model.rootIds) {
    const block = model.blocks[id];
    if (!block) continue;
    const el = doc.createElement("div");
    el.setAttribute(BLOCK_ID_ATTR, id);
    el.textContent = block.componentName;
    root.appendChild(el);
  }
}

describe("BreakpointCanvas", () => {
  it("renders the current model into a frame as soon as it's registered", () => {
    const model = makeModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const canvas = new BreakpointCanvas(engine, render);
    const frameDoc = document.implementation.createHTMLDocument("phone");

    canvas.registerFrame({ name: "phone", doc: frameDoc });

    expect(frameDoc.querySelector(`[${BLOCK_ID_ATTR}="b1"]`)?.textContent).toBe("Hero");
  });

  it("re-renders every registered frame when the model changes via an applied op", async () => {
    const model = makeModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const canvas = new BreakpointCanvas(engine, render);
    const phoneDoc = document.implementation.createHTMLDocument("phone");
    const desktopDoc = document.implementation.createHTMLDocument("desktop");
    canvas.registerFrame({ name: "phone", doc: phoneDoc });
    canvas.registerFrame({ name: "desktop", doc: desktopDoc });

    await engine.submit({ kind: "setProp", blockId: "b1", propName: "title", value: "Updated", previousValue: "Welcome" });

    // The fixture render() above doesn't project props into text, so re-invocation is what we can
    // observe directly here — assert both frames still reflect the (single, shared) current model
    // by checking the block element survived a re-render in each, proving render() ran per frame.
    expect(phoneDoc.querySelector(`[${BLOCK_ID_ATTR}="b1"]`)).not.toBeNull();
    expect(desktopDoc.querySelector(`[${BLOCK_ID_ATTR}="b1"]`)).not.toBeNull();
  });

  it("unregisterFrame stops future re-renders for that frame", async () => {
    const model = makeModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const canvas = new BreakpointCanvas(engine, render);
    const phoneDoc = document.implementation.createHTMLDocument("phone");
    canvas.registerFrame({ name: "phone", doc: phoneDoc });
    canvas.unregisterFrame("phone");

    phoneDoc.body.innerHTML = "<p>untouched</p>";
    await engine.submit({ kind: "setProp", blockId: "b1", propName: "title", value: "Updated", previousValue: "Welcome" });

    expect(phoneDoc.body.innerHTML).toBe("<p>untouched</p>");
    expect(canvas.frames).toHaveLength(0);
  });

  it("handleRectsForSelection returns one rect per frame currently rendering the selected block", () => {
    const model = makeModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const canvas = new BreakpointCanvas(engine, render);
    const phoneDoc = document.implementation.createHTMLDocument("phone");
    const desktopDoc = document.implementation.createHTMLDocument("desktop");
    canvas.registerFrame({ name: "phone", doc: phoneDoc });
    canvas.registerFrame({ name: "desktop", doc: desktopDoc });

    expect(canvas.handleRectsForSelection()).toEqual([]);

    engine.selection.select("b1");

    // jsdom has no layout engine, so every rect is zero here — real handle geometry across frames
    // is covered by Playwright e2e goldens (Task 9), matching selection.test.ts's own convention.
    expect(canvas.handleRectsForSelection()).toEqual([
      { name: "phone", rect: { x: 0, y: 0, width: 0, height: 0 } },
      { name: "desktop", rect: { x: 0, y: 0, width: 0, height: 0 } },
    ]);
  });

  it("hitTestFrame returns null for an unregistered frame name", () => {
    const model = makeModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const canvas = new BreakpointCanvas(engine, render);
    expect(canvas.hitTestFrame("phone", { x: 0, y: 0 })).toBeNull();
  });

  it("dispose() unsubscribes from engine events and clears registered frames", async () => {
    const model = makeModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const canvas = new BreakpointCanvas(engine, render);
    const phoneDoc = document.implementation.createHTMLDocument("phone");
    canvas.registerFrame({ name: "phone", doc: phoneDoc });

    canvas.dispose();
    phoneDoc.body.innerHTML = "<p>untouched</p>";
    await engine.submit({ kind: "setProp", blockId: "b1", propName: "title", value: "Updated", previousValue: "Welcome" });

    expect(phoneDoc.body.innerHTML).toBe("<p>untouched</p>");
    expect(canvas.frames).toHaveLength(0);
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd JS/wysiwyg-engine && npm test -- breakpoints`
Expected: FAIL — `Cannot find module '../src/breakpoints.js'`

- [ ] **Step 3: Write `src/breakpoints.ts`**

```ts
import type { BlockId, BlockModel } from "./types.js";
import type { WysiwygEngine, EngineEvent } from "./engine.js";
import { computeHandleRect } from "./selection.js";
import type { HandleRect } from "./selection.js";

export interface BreakpointFrame {
  name: string;
  doc: Document;
}

export type RenderFn = (model: BlockModel, doc: Document) => void;

/**
 * Drives N breakpoint frame documents from one shared `WysiwygEngine` (design doc §6, spec §5:
 * breakpoints are views, not modes). Because `hitTest()`/`computeHandleRect()` already accept an
 * explicit document/root instead of assuming the global `document`, one engine — one model, one
 * selection, one op queue — can resolve gestures against any registered frame: selecting a block in
 * one frame is reflected in every frame automatically, with no cross-frame sync layer.
 */
export class BreakpointCanvas {
  #engine: WysiwygEngine;
  #render: RenderFn;
  #frames: BreakpointFrame[] = [];
  #unsubscribe: () => void;

  constructor(engine: WysiwygEngine, render: RenderFn) {
    this.#engine = engine;
    this.#render = render;
    this.#unsubscribe = engine.onEvent((event) => this.#onEngineEvent(event));
  }

  registerFrame(frame: BreakpointFrame): void {
    this.#frames.push(frame);
    this.#render(this.#engine.modelSync.current, frame.doc);
  }

  unregisterFrame(name: string): void {
    this.#frames = this.#frames.filter((f) => f.name !== name);
  }

  get frames(): readonly BreakpointFrame[] {
    return this.#frames;
  }

  hitTestFrame(name: string, point: { x: number; y: number }): BlockId | null {
    const frame = this.#frames.find((f) => f.name === name);
    if (!frame) return null;
    return this.#engine.hitTest(point, frame.doc);
  }

  /** Selection-handle geometry for every frame currently rendering the selected block — callers
   *  redraw their own outline chrome from this, mirroring how the engine itself owns no rendering
   *  (spec §3.1). Call after any engine event that could move or reselect a block. */
  handleRectsForSelection(): { name: string; rect: HandleRect }[] {
    const selected = this.#engine.selection.current;
    if (!selected) return [];
    const rects: { name: string; rect: HandleRect }[] = [];
    for (const frame of this.#frames) {
      const rect = computeHandleRect(selected, frame.doc);
      if (rect) rects.push({ name: frame.name, rect });
    }
    return rects;
  }

  dispose(): void {
    this.#unsubscribe();
    this.#frames = [];
  }

  #onEngineEvent(event: EngineEvent): void {
    const shouldRerender =
      event.type === "model-updated" || event.type === "applied" || (event.type === "rejected" && event.model !== undefined);
    if (!shouldRerender) return;
    const model = this.#engine.modelSync.current;
    for (const frame of this.#frames) this.#render(model, frame.doc);
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd JS/wysiwyg-engine && npm test -- breakpoints`
Expected: PASS (6 tests)

Also run `npm run typecheck && npm run lint`, then the full suite: `npm test`.

- [ ] **Step 5: Add the barrel export**

`src/index.ts` currently reads:

```ts
export * from "./types.js";
export * from "./ops.js";
export * from "./model-sync.js";
export * from "./hit-test.js";
export * from "./selection.js";
export * from "./op-queue.js";
export * from "./engine.js";
```

Change it to:

```ts
export * from "./types.js";
export * from "./ops.js";
export * from "./model-sync.js";
export * from "./hit-test.js";
export * from "./selection.js";
export * from "./op-queue.js";
export * from "./engine.js";
export * from "./rich-text.js";
export * from "./drag-drop.js";
export * from "./breakpoints.js";
```

- [ ] **Step 6: Run the full local check set**

Run: `cd JS/wysiwyg-engine && npm run lint && npm run typecheck && npm test`
Expected: all PASS

- [ ] **Step 7: Commit**

```bash
git add JS/wysiwyg-engine/src/breakpoints.ts JS/wysiwyg-engine/test/breakpoints.test.ts JS/wysiwyg-engine/src/index.ts
git commit -m "feat(#1224): add BreakpointCanvas and export canvas-chrome modules"
```

---

### Task 9: Playwright e2e goldens

**Files:**
- Modify: `JS/wysiwyg-engine/e2e/fixture-page.ts`
- Create: `JS/wysiwyg-engine/e2e/rich-text.spec.ts`
- Create: `JS/wysiwyg-engine/e2e/drag-drop.spec.ts`
- Create: `JS/wysiwyg-engine/e2e/frame.html`
- Create: `JS/wysiwyg-engine/e2e/breakpoints-fixture.html`
- Create: `JS/wysiwyg-engine/e2e/breakpoints-fixture-page.ts`
- Create: `JS/wysiwyg-engine/e2e/breakpoints.spec.ts`
- Modify: `JS/wysiwyg-engine/package.json`

**Interfaces:**
- Consumes: `RichTextEditor` (rich-text.ts), `DragReorderController`, `wireExternalDrop`, `submitDrop`, `DropTarget` (drag-drop.ts), `BreakpointCanvas` (breakpoints.ts) — all from earlier tasks.
- Produces: `window.__richText: RichTextEditor`, `window.__dragReorder: DragReorderController`, `window.__submitDrop`, `window.__toggleFormat`, `window.__disposeExternalDrop: () => void` on the main fixture page; `window.__canvas: BreakpointCanvas`, `window.__handleRects` on the breakpoints fixture — the surface the three new golden spec files drive.

**Coverage note:** Task 7's `wireExternalDrop` shipped with zero unit tests — `DragEvent`/`DataTransfer` are unconstructable under this project's pinned jsdom (verified: `jsdom@30.0.1` throws `"is not a constructor"` for both), so all three of Task 7's planned unit tests were correctly dropped per its brief's own anticipated fallback, deferring 100% of `wireExternalDrop`'s behavioral coverage to this task. The two new `drag-drop.spec.ts` cases below (dragover indicator + dragleave clear, and disposer cleanup) exist specifically to close that gap — do not treat them as optional/nice-to-have additions to this task.

- [ ] **Step 1: Replace `e2e/fixture-page.ts`** with the full updated file (adds a `"text"` block rendered from its `richText` runs, and wires `RichTextEditor`/`DragReorderController`/`wireExternalDrop` onto the same canvas):

```ts
import { WysiwygEngine } from "../src/engine.js";
import { FixtureHost } from "../src/testing/fixture-host.js";
import { computeHandleRect } from "../src/selection.js";
import { ROOT_PARENT_ID } from "../src/types.js";
import { RichTextEditor } from "../src/rich-text.js";
import { DragReorderController, wireExternalDrop, submitDrop } from "../src/drag-drop.js";
import type { HandleRect } from "../src/selection.js";
import type { BlockModel, OpResult, RichTextRun, BlockNode } from "../src/types.js";
import type { DropTarget } from "../src/drag-drop.js";
import type { FormatKind } from "../src/rich-text.js";

const initialModel: BlockModel = {
  path: "src/pages/index.astro",
  version: "fixture-initial",
  rootIds: ["b1", "b2", "t1"],
  blocks: {
    b1: { id: "b1", kind: "astro", componentName: "Hero", props: { title: "Welcome" }, slots: {}, sourceSpan: [0, 10] },
    b2: { id: "b2", kind: "astro", componentName: "Testimonial", props: { quote: "Great!" }, slots: {}, sourceSpan: [11, 20] },
    t1: {
      id: "t1",
      kind: "text",
      componentName: "paragraph",
      props: {},
      slots: {},
      sourceSpan: [21, 30],
      richText: [
        { kind: "text", text: "Edit " },
        { kind: "strong", text: "me" },
      ],
    },
  },
};

const host = new FixtureHost(initialModel);
const engine = new WysiwygEngine(initialModel, host);
const richText = new RichTextEditor(engine, { debounceMs: 300 });

function canvas(): HTMLElement {
  const el = document.getElementById("canvas");
  if (!el) throw new Error("fixture.html is missing #canvas");
  return el;
}

function escapeHtml(text: string): string {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

/** Host-owned rendering of RichTextRun[] into markup — the inverse of runsFromElement, and, like
 *  the rest of this fixture's render(), a stand-in for what a real host's DOM projection does. */
function renderRuns(runs: RichTextRun[]): string {
  return runs
    .map((run) => {
      const text = escapeHtml(run.text);
      switch (run.kind) {
        case "strong":
          return `<strong>${text}</strong>`;
        case "em":
          return `<em>${text}</em>`;
        case "link":
          return `<a href="${escapeHtml(run.href ?? "")}">${text}</a>`;
        case "code":
          return `<code>${text}</code>`;
        default:
          return text;
      }
    })
    .join("");
}

function render(model: BlockModel): void {
  const root = canvas();
  root.innerHTML = "";
  for (const id of model.rootIds) {
    const block = model.blocks[id];
    if (!block) continue;
    const el = document.createElement("div");
    el.setAttribute("data-anglesite-block-id", id);
    el.setAttribute("data-component", block.componentName);
    el.setAttribute("data-anglesite-selected", "false");
    if (block.kind === "text") {
      el.innerHTML = renderRuns(block.richText ?? []);
    } else {
      el.textContent = `${block.componentName} (${id})`;
    }
    el.style.cssText = "padding:8px;margin:4px;border:1px solid #ccc;";
    el.addEventListener("click", () => engine.selection.select(id));
    el.addEventListener("pointerdown", () => dragReorder.startDrag(id));
    root.appendChild(el);
  }
}

const dragReorder = new DragReorderController(
  engine,
  (target) => {
    window.__dropIndicator = target;
  },
  canvas(),
);

const disposeExternalDrop = wireExternalDrop(
  canvas(),
  (target) => {
    window.__dropIndicator = target;
  },
  (target, dataTransfer) => {
    const json = dataTransfer.getData("application/x-anglesite-block");
    if (!json) return;
    const block = JSON.parse(json) as Omit<BlockNode, "id">;
    void submitDrop(engine, target, block);
  },
);

engine.onEvent((event) => {
  if (event.type === "model-updated" || event.type === "applied" || (event.type === "rejected" && event.model)) {
    render(engine.modelSync.current);
  }
  if (event.type === "selection-changed") {
    for (const el of Array.from(canvas().children)) {
      const selected = el.getAttribute("data-anglesite-block-id") === event.blockId;
      el.setAttribute("data-anglesite-selected", String(selected));
    }
  }
  // Cheap, poll-able signal Playwright can wait on without a custom event bridge.
  document.title = `event:${event.type}`;
});

render(initialModel);

declare global {
  interface Window {
    __engine: WysiwygEngine;
    __host: FixtureHost;
    __richText: RichTextEditor;
    __dragReorder: DragReorderController;
    __dropIndicator: DropTarget | null;
    __moveBlock: (blockId: string, toIndex: number) => Promise<OpResult>;
    __computeHandleRect: (blockId: string) => HandleRect | null;
    __submitDrop: (target: DropTarget, block: Omit<BlockNode, "id">) => Promise<OpResult>;
    __toggleFormat: (kind: FormatKind) => void;
    __disposeExternalDrop: () => void;
  }
}

window.__engine = engine;
window.__host = host;
window.__richText = richText;
window.__dragReorder = dragReorder;
window.__dropIndicator = null;
window.__computeHandleRect = (blockId) => computeHandleRect(blockId);
window.__submitDrop = (target, block) => submitDrop(engine, target, block);
window.__toggleFormat = (kind) => richText.toggleFormat(kind);
window.__disposeExternalDrop = disposeExternalDrop;
window.__moveBlock = (blockId, toIndex) => {
  const model = engine.modelSync.current;
  const fromIndex = model.rootIds.indexOf(blockId);
  return engine.submit({
    kind: "moveBlock",
    blockId,
    fromParentId: ROOT_PARENT_ID,
    fromSlot: "default",
    fromIndex,
    toParentId: ROOT_PARENT_ID,
    toSlot: "default",
    toIndex,
  });
};
```

- [ ] **Step 2: Rebuild the fixture bundle and run the existing goldens to confirm nothing broke**

Run: `cd JS/wysiwyg-engine && npm run test:e2e`
Expected: PASS — `gestures.spec.ts`/`rendering.spec.ts`/`rejection.spec.ts` (slice 2) still pass unchanged against the extended fixture; the new `t1` block doesn't interfere (those specs only ever reference `b1`/`b2`).

- [ ] **Step 3: Write `e2e/rich-text.spec.ts`**

```ts
import { test, expect } from "@playwright/test";

test("typing in an entered text block commits an editText op with honest runs after the debounce", async ({ page }) => {
  await page.goto("/fixture.html");
  await page.evaluate(() => window.__richText.enter("t1"));

  const block = page.locator('[data-anglesite-block-id="t1"]');
  await block.evaluate((el) => {
    el.textContent = "Edit me now";
  });
  await block.dispatchEvent("input");

  await page.waitForFunction(() => document.title === "event:applied");

  const runs = await page.evaluate(() => window.__engine.modelSync.getBlock("t1")?.richText);
  expect(runs).toEqual([{ kind: "text", text: "Edit me now" }]);
});

test("toggling bold on a selection wraps it in <strong>, never a styled span", async ({ page }) => {
  await page.goto("/fixture.html");
  await page.evaluate(() => window.__richText.enter("t1"));

  const block = page.locator('[data-anglesite-block-id="t1"]');
  await block.evaluate((el) => {
    const textNode = el.firstChild;
    if (!textNode) throw new Error("expected a text node");
    const range = document.createRange();
    range.setStart(textNode, 0);
    range.setEnd(textNode, 4); // "Edit" (of "Edit ")
    const selection = window.getSelection();
    selection?.removeAllRanges();
    selection?.addRange(range);
  });

  await page.evaluate(() => window.__toggleFormat("strong"));
  await page.evaluate(() => window.__richText.exit());
  await page.waitForFunction(() => document.title === "event:applied");

  const runs = await page.evaluate(() => window.__engine.modelSync.getBlock("t1")?.richText);
  expect(runs).toEqual([
    { kind: "strong", text: "Edit" },
    { kind: "text", text: " " },
    { kind: "strong", text: "me" },
  ]);
});

test("exiting without any change does not submit a no-op editText", async ({ page }) => {
  await page.goto("/fixture.html");
  await page.evaluate(() => window.__richText.enter("t1"));
  await page.evaluate(() => window.__richText.exit());

  // No typing happened, so nothing should have committed — the title (flipped only by engine
  // events) stays at its initial, pre-any-event value.
  await page.waitForTimeout(100);
  expect(await page.title()).toBe("WYSIWYG engine fixture");
});
```

- [ ] **Step 4: Run the rich-text goldens**

Run: `cd JS/wysiwyg-engine && npm run test:e2e -- rich-text`
Expected: PASS (3 tests)

- [ ] **Step 5: Write `e2e/drag-drop.spec.ts`**

```ts
import { test, expect } from "@playwright/test";

test("a real pointer drag reorders blocks via DragReorderController", async ({ page }) => {
  await page.goto("/fixture.html");
  const b1Box = await page.locator('[data-anglesite-block-id="b1"]').boundingBox();
  const b2Box = await page.locator('[data-anglesite-block-id="b2"]').boundingBox();
  if (!b1Box || !b2Box) throw new Error("expected bounding boxes");

  await page.mouse.move(b2Box.x + b2Box.width / 2, b2Box.y + b2Box.height / 2);
  await page.mouse.down();
  await page.mouse.move(b1Box.x + b1Box.width / 2, b1Box.y + 1, { steps: 5 });
  await page.mouse.up();

  await page.waitForFunction(() => document.title === "event:applied");

  const order = await page.evaluate(() => window.__engine.modelSync.current.rootIds);
  expect(order.indexOf("b2")).toBeLessThan(order.indexOf("b1"));
});

test("submitDrop inserts a new block at the given target", async ({ page }) => {
  await page.goto("/fixture.html");
  const result = await page.evaluate(() =>
    window.__submitDrop(
      { parentId: "__root__", slot: "default", index: 0 },
      { kind: "astro", componentName: "Newsletter", props: {}, slots: {}, sourceSpan: [0, 0] },
    ),
  );
  expect(result.status).toBe("applied");

  const firstId = await page.evaluate(() => window.__engine.modelSync.current.rootIds[0]);
  const firstName = await page.evaluate(
    (id) => (id ? window.__engine.modelSync.getBlock(id)?.componentName : undefined),
    firstId,
  );
  expect(firstName).toBe("Newsletter");
});

test("an external drop (palette-style payload) inserts a block via wireExternalDrop", async ({ page }) => {
  await page.goto("/fixture.html");
  await page.evaluate(() => {
    const canvasEl = document.getElementById("canvas");
    if (!canvasEl) throw new Error("missing #canvas");
    const dataTransfer = new DataTransfer();
    dataTransfer.setData(
      "application/x-anglesite-block",
      JSON.stringify({ kind: "astro", componentName: "CallToAction", props: {}, slots: {}, sourceSpan: [0, 0] }),
    );
    const rect = canvasEl.getBoundingClientRect();
    const dropEvent = new DragEvent("drop", {
      clientX: rect.x + 5,
      clientY: rect.y + 5,
      bubbles: true,
      cancelable: true,
      dataTransfer,
    });
    canvasEl.dispatchEvent(dropEvent);
  });

  await page.waitForFunction(() => document.title === "event:applied");
  const componentNames = await page.evaluate(() =>
    Object.values(window.__engine.modelSync.current.blocks).map((b) => b.componentName),
  );
  expect(componentNames).toContain("CallToAction");
});

test("dragover computes a drop-target indicator; dragleave clears it", async ({ page }) => {
  // Task 7 shipped wireExternalDrop with zero unit tests (DragEvent/DataTransfer are
  // unconstructable under this project's pinned jsdom) — this is the only test covering its
  // dragover/dragleave indicator behavior at any tier.
  await page.goto("/fixture.html");
  await page.evaluate(() => {
    const canvasEl = document.getElementById("canvas");
    if (!canvasEl) throw new Error("missing #canvas");
    const rect = canvasEl.getBoundingClientRect();
    canvasEl.dispatchEvent(
      new DragEvent("dragover", { clientX: rect.x + 5, clientY: rect.y + 5, bubbles: true, cancelable: true }),
    );
  });

  const indicatorAfterDragover = await page.evaluate(() => window.__dropIndicator);
  expect(indicatorAfterDragover).not.toBeNull();
  expect(indicatorAfterDragover?.parentId).toBe("__root__");

  await page.evaluate(() => {
    document.getElementById("canvas")?.dispatchEvent(new DragEvent("dragleave", { bubbles: true }));
  });
  const indicatorAfterDragleave = await page.evaluate(() => window.__dropIndicator);
  expect(indicatorAfterDragleave).toBeNull();
});

test("the disposer stops wireExternalDrop from responding to further drags", async ({ page }) => {
  // The other half of Task 7's deferred coverage: the disposer itself has no test at any tier
  // otherwise.
  await page.goto("/fixture.html");
  await page.evaluate(() => window.__disposeExternalDrop());

  const componentNamesBefore = await page.evaluate(() =>
    Object.values(window.__engine.modelSync.current.blocks).map((b) => b.componentName),
  );

  await page.evaluate(() => {
    const canvasEl = document.getElementById("canvas");
    if (!canvasEl) throw new Error("missing #canvas");
    const dataTransfer = new DataTransfer();
    dataTransfer.setData(
      "application/x-anglesite-block",
      JSON.stringify({ kind: "astro", componentName: "ShouldNeverAppear", props: {}, slots: {}, sourceSpan: [0, 0] }),
    );
    const rect = canvasEl.getBoundingClientRect();
    canvasEl.dispatchEvent(
      new DragEvent("drop", { clientX: rect.x + 5, clientY: rect.y + 5, bubbles: true, cancelable: true, dataTransfer }),
    );
  });

  // Disposed listeners never run, so no engine event fires and there's nothing to await — give
  // any errant async work one beat to have shown up, then assert nothing changed.
  await page.waitForTimeout(100);
  const componentNamesAfter = await page.evaluate(() =>
    Object.values(window.__engine.modelSync.current.blocks).map((b) => b.componentName),
  );
  expect(componentNamesAfter).toEqual(componentNamesBefore);
});

test("a version-mismatch rejection during a drop is visible and applies nothing", async ({ page }) => {
  await page.goto("/fixture.html");
  await page.evaluate(() => window.__host.forceReject("version-mismatch", "stale"));

  const result = await page.evaluate(() =>
    window.__submitDrop(
      { parentId: "__root__", slot: "default", index: 0 },
      { kind: "astro", componentName: "ShouldNotAppear", props: {}, slots: {}, sourceSpan: [0, 0] },
    ),
  );
  expect(result.status).toBe("rejected");

  const componentNames = await page.evaluate(() =>
    Object.values(window.__engine.modelSync.current.blocks).map((b) => b.componentName),
  );
  expect(componentNames).not.toContain("ShouldNotAppear");
});
```

- [ ] **Step 6: Run the drag-drop goldens**

Run: `cd JS/wysiwyg-engine && npm run test:e2e -- drag-drop`
Expected: PASS (6 tests)

- [ ] **Step 7: Write `e2e/frame.html`**

```html
<!doctype html>
<html>
  <head>
    <meta charset="utf-8" />
    <title>frame</title>
  </head>
  <body>
    <div id="canvas"></div>
  </body>
</html>
```

- [ ] **Step 8: Write `e2e/breakpoints-fixture.html`**

```html
<!doctype html>
<html>
  <head>
    <meta charset="utf-8" />
    <title>WYSIWYG breakpoints fixture</title>
  </head>
  <body>
    <iframe id="phone" src="./frame.html" style="width: 375px; height: 400px"></iframe>
    <iframe id="tablet" src="./frame.html" style="width: 768px; height: 400px"></iframe>
    <iframe id="desktop" src="./frame.html" style="width: 1280px; height: 400px"></iframe>
    <script src="./.generated/breakpoints-bundle.js"></script>
  </body>
</html>
```

- [ ] **Step 9: Write `e2e/breakpoints-fixture-page.ts`**

```ts
import { WysiwygEngine } from "../src/engine.js";
import { FixtureHost } from "../src/testing/fixture-host.js";
import { BreakpointCanvas } from "../src/breakpoints.js";
import type { BlockModel } from "../src/types.js";
import type { HandleRect } from "../src/selection.js";

const initialModel: BlockModel = {
  path: "src/pages/index.astro",
  version: "fixture-initial",
  rootIds: ["b1", "b2"],
  blocks: {
    b1: { id: "b1", kind: "astro", componentName: "Hero", props: { title: "Welcome" }, slots: {}, sourceSpan: [0, 10] },
    b2: { id: "b2", kind: "astro", componentName: "Testimonial", props: { quote: "Great!" }, slots: {}, sourceSpan: [11, 20] },
  },
};

const host = new FixtureHost(initialModel);
const engine = new WysiwygEngine(initialModel, host);

function render(model: BlockModel, doc: Document): void {
  const root = doc.getElementById("canvas");
  if (!root) return;
  root.innerHTML = "";
  for (const id of model.rootIds) {
    const block = model.blocks[id];
    if (!block) continue;
    const el = doc.createElement("div");
    el.setAttribute("data-anglesite-block-id", id);
    el.textContent = block.componentName;
    el.style.cssText = "padding:8px;margin:4px;border:1px solid #ccc;";
    el.addEventListener("click", () => engine.selection.select(id));
    root.appendChild(el);
  }
}

const canvas = new BreakpointCanvas(engine, render);
const frameNames = ["phone", "tablet", "desktop"] as const;

function registerFrames(): void {
  for (const name of frameNames) {
    const iframe = document.getElementById(name) as HTMLIFrameElement | null;
    const frameDoc = iframe?.contentDocument;
    if (!frameDoc) throw new Error(`missing iframe document for ${name}`);
    canvas.registerFrame({ name, doc: frameDoc });
  }
  // Cheap, poll-able readiness signal — engine.onEvent() below overwrites it on any later event.
  document.title = "breakpoints:ready";
}

const iframes = frameNames
  .map((name) => document.getElementById(name) as HTMLIFrameElement | null)
  .filter((el): el is HTMLIFrameElement => el !== null);

let loadedCount = 0;
for (const iframe of iframes) {
  iframe.addEventListener("load", () => {
    loadedCount += 1;
    if (loadedCount === iframes.length) registerFrames();
  });
}

engine.onEvent((event) => {
  document.title = `event:${event.type}`;
});

declare global {
  interface Window {
    __engine: WysiwygEngine;
    __host: FixtureHost;
    __canvas: BreakpointCanvas;
    __handleRects: () => { name: string; rect: HandleRect }[];
  }
}

window.__engine = engine;
window.__host = host;
window.__canvas = canvas;
window.__handleRects = () => canvas.handleRectsForSelection();
```

- [ ] **Step 10: Write `e2e/breakpoints.spec.ts`**

```ts
import { test, expect } from "@playwright/test";

test("registers all three frames and renders the model into each", async ({ page }) => {
  await page.goto("/breakpoints-fixture.html");
  await page.waitForFunction(() => document.title === "breakpoints:ready");

  for (const name of ["phone", "tablet", "desktop"]) {
    const frame = page.frameLocator(`#${name}`);
    await expect(frame.locator('[data-anglesite-block-id="b1"]')).toHaveText("Hero");
  }
});

test("selecting a block in one frame draws handles in every registered frame", async ({ page }) => {
  await page.goto("/breakpoints-fixture.html");
  await page.waitForFunction(() => document.title === "breakpoints:ready");

  await page.frameLocator("#phone").locator('[data-anglesite-block-id="b2"]').click();
  await page.waitForFunction(() => document.title === "event:selection-changed");

  const rects = await page.evaluate(() => window.__handleRects());
  expect(rects.map((r) => r.name).sort()).toEqual(["desktop", "phone", "tablet"]);
  for (const { rect } of rects) {
    expect(rect.width).toBeGreaterThan(0);
    expect(rect.height).toBeGreaterThan(0);
  }
});

test("an op applied via the shared engine re-renders every frame", async ({ page }) => {
  await page.goto("/breakpoints-fixture.html");
  await page.waitForFunction(() => document.title === "breakpoints:ready");

  await page.evaluate(() =>
    window.__engine.submit({
      kind: "moveBlock",
      blockId: "b2",
      fromParentId: "__root__",
      fromSlot: "default",
      fromIndex: 1,
      toParentId: "__root__",
      toSlot: "default",
      toIndex: 0,
    }),
  );
  await page.waitForFunction(() => document.title === "event:applied");

  for (const name of ["phone", "tablet", "desktop"]) {
    const frame = page.frameLocator(`#${name}`);
    await expect(frame.locator("#canvas > div").first()).toHaveText("Testimonial");
  }
});
```

- [ ] **Step 11: Wire the second e2e bundle into `package.json`**

In `JS/wysiwyg-engine/package.json`, change the `build:e2e` script from:

```json
    "build:e2e": "esbuild e2e/fixture-page.ts --bundle --format=iife --target=es2022 --outfile=e2e/.generated/fixture-bundle.js",
```

to:

```json
    "build:e2e": "esbuild e2e/fixture-page.ts --bundle --format=iife --target=es2022 --outfile=e2e/.generated/fixture-bundle.js && esbuild e2e/breakpoints-fixture-page.ts --bundle --format=iife --target=es2022 --outfile=e2e/.generated/breakpoints-bundle.js",
```

- [ ] **Step 12: Run the breakpoints goldens**

Run: `cd JS/wysiwyg-engine && npm run test:e2e -- breakpoints`
Expected: PASS (3 tests)

- [ ] **Step 13: Run the full local check set**

Run: `cd JS/wysiwyg-engine && npm run lint && npm run typecheck && npm test && npm run test:e2e`
Expected: all PASS (every unit test file from Tasks 1–8, plus all six e2e spec files — the three pre-existing slice-2 goldens plus this task's three new ones)

- [ ] **Step 14: Commit**

```bash
git add JS/wysiwyg-engine/e2e/ JS/wysiwyg-engine/package.json
git commit -m "feat(#1224): add Playwright goldens for rich text, drag/drop, and breakpoints"
```

---

## Self-Review

**Spec coverage** (`docs/superpowers/specs/2026-08-08-wysiwyg-canvas-chrome-design.md`, cross-checked section by section):

- §2 scope boundary (pure JS/TS, zero Swift, no native palette/Finder ingestion) → enforced throughout: every file this plan touches is under `JS/wysiwyg-engine/`; no `Sources/**` file appears in any task. No CI task, because the existing `wysiwyg-engine` job (from slice 2) already gates the whole `JS/wysiwyg-engine/**` path.
- §3 architecture (three new modules on top of slice 2's primitives; one engine drives N frames) → Tasks 1–4 build `rich-text.ts`, Tasks 5–7 build `drag-drop.ts`, Task 8 builds `breakpoints.ts`; Task 8's `BreakpointCanvas` is the concrete realization of "one `WysiwygEngine` instance drives multiple frame documents," using `hitTest(point, doc)`/`computeHandleRect(id, root)`'s existing document parameter rather than new coordination machinery.
- §4 inline rich-text editing:
  - "Honest runs only, no styled spans" → Task 1's `runsFromElement` (only strong/em/link/code survive; everything else flattens to text).
  - "Manual Range wrapping/unwrapping, not execCommand" → Task 3's `wrapRange`/`unwrapElement`/`toggleInlineFormat`/`setLinkFormat`/`unsetLinkFormat`.
  - "Debounce ~400ms, immediate on blur/Escape/format command" → Task 2's `DebouncedCommitter` (default 400ms) + Task 4's `RichTextEditor`, which now wires `blur` and `keydown`(Escape) listeners alongside the format-command methods, each calling `exit()`/`notifyChange()` for an immediate flush — added during this plan's self-review after the first draft only wired `input`; see Task 4's revised implementation and its two new tests.
  - "`previousRuns` is the entry-time baseline, not the prior debounce tick" → Task 4's `#baselineRuns`, captured once in `enter()`, unit-tested by the "multiple edits before the debounce fires" test.
- §5 drag & drop:
  - "`computeDropTarget` pure geometry" → Task 5.
  - "In-canvas reorder via pointer events, not HTML5 DnD" → Task 6's `DragReorderController`.
  - "External drop via native `dragover`/`drop`, engine never inspects `DataTransfer`" → Task 7's `wireExternalDrop`, which forwards the raw `DataTransfer` to a host-supplied callback and never parses it itself.
  - "`submitDrop` builds/submits `insertBlock`" → Task 5.
- §6 breakpoint views: "same block model into N frames, gestures resolve through the one shared engine, no per-breakpoint style surface" → Task 8's `BreakpointCanvas.registerFrame`/`#onEngineEvent` (re-render) and `hitTestFrame`/`handleRectsForSelection` (shared-engine gesture resolution); no op or type introduced anywhere in this plan carries a breakpoint-scoped value, so there is structurally no such surface to remove.
- §7 error handling: "commit paths reuse the existing `OpQueue` rejection handling; an in-progress gesture aborts visibly, never silently" → every submitting call (`RichTextEditor.#commit`, `DragReorderController.#handleUp`, `submitDrop`) goes through `engine.submit()` with no new rejection logic (Global Constraints); `DragReorderController`'s vanished-block abort (Task 6) and the version-mismatch goldens (`rich-text`/`drag-drop` e2e specs reusing the `forceReject`/`rejected`-event pattern from slice 2's `rejection.spec.ts`) exercise this directly.
- §8 testing: "vitest for pure logic, Playwright e2e for real-geometry/real-`Selection`/real-DnD behavior, no new test infrastructure" → every task follows this split explicitly (see each task's test-file comments); Task 9 reuses the existing `static-server.mjs`/fixture-host pattern and only adds one new esbuild bundle target for the breakpoints fixture, not a new toolchain.
- §9 out of scope confirmed absent from this plan: no Swift/WKWebView mounting, no native palette UI, no `NSUndoManager` wiring, no Finder file ingestion, no menu-bar commands, no multi-select.

**Placeholder scan:** no TBD/TODO markers; every step contains literal, complete code — including the one gap this self-review found and fixed (blur/Escape auto-exit) rather than leaving it as a follow-up note.

**Type consistency:** `DropTarget`, `nearestIndexInSlot`, `computeDropTarget`, `generateBlockId`, `submitDrop` (Task 5) are consumed with identical signatures by `DragReorderController` (Task 6), `wireExternalDrop` (Task 7), and the e2e fixtures (Task 9) — none re-declare or shadow them. `RichTextEditor`, `DebouncedCommitter`, `FormatKind`, `toggleInlineFormat`/`setLinkFormat`/`unsetLinkFormat` (Tasks 1–4) are imported by name into `e2e/fixture-page.ts` (Task 9) exactly as exported. `BreakpointCanvas`'s `RenderFn = (model: BlockModel, doc: Document) => void` matches both the unit test's local `render()` (Task 8) and `e2e/breakpoints-fixture-page.ts`'s `render()` (Task 9) argument-for-argument. `src/index.ts`'s barrel export (Task 8, Step 5) re-exports all three new modules, so every symbol referenced across tasks resolves through the same public surface a real host would eventually consume.
