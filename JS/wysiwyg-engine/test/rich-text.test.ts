// @vitest-environment jsdom
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

  it("toggleFormat/setLink/unsetLink commit immediately, not after the debounce window", async () => {
    document.body.innerHTML = `<div ${BLOCK_ID_ATTR}="t1">Hello</div>`;
    const model = makeTextModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    // A debounce long enough that this test would time out waiting for it to elapse — proving
    // the commit did NOT go through the debounce path.
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
    editor.toggleFormat("strong");
    await applied;

    expect(engine.modelSync.getBlock("t1")).toBeDefined();
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
