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

  it("preserves nested recognized formats via children, instead of flattening them away", () => {
    // The ordinary composition gesture: toggling italic on a sub-selection already inside a bold
    // run nests <em> inside <strong>. Before this test's fix, runFromNode() read el.textContent on
    // the outer <strong> and discarded the inner <em> entirely.
    const root = setBody("<strong>Ed<em>i</em>t</strong>");
    expect(runsFromElement(root)).toEqual([
      {
        kind: "strong",
        text: "Edit",
        children: [
          { kind: "text", text: "Ed" },
          { kind: "em", text: "i" },
          { kind: "text", text: "t" },
        ],
      },
    ]);
  });

  it("does not add a children field to a plain (non-composed) recognized run", () => {
    // children is populated only when genuine composition is present — a plain <strong> stays
    // exactly as flat as it was before nesting support existed.
    const root = setBody("<strong>bold</strong>");
    expect(runsFromElement(root)).toEqual([{ kind: "strong", text: "bold" }]);
  });

  it("preserves nesting inside a link run alongside its href", () => {
    const root = setBody('<a href="/x">see <strong>this</strong></a>');
    expect(runsFromElement(root)).toEqual([
      {
        kind: "link",
        text: "see this",
        href: "/x",
        children: [
          { kind: "text", text: "see " },
          { kind: "strong", text: "this" },
        ],
      },
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
    const el = document.querySelector(`[${BLOCK_ID_ATTR}="t1"]`) as HTMLElement;
    // A real content change, independent of jsdom's unreliable Selection support — jsdom has no
    // live Selection, so toggleFormat()'s own DOM wrapping no-ops here (that path is e2e-covered),
    // but the already-changed content must still flush immediately when toggleFormat is called.
    el.textContent = "Hello world";
    editor.toggleFormat("strong");
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

  it("re-entering the same blockId in a different frame switches to that frame's element", () => {
    // BreakpointCanvas renders the identical blockId into every frame simultaneously — re-entering
    // "the same block" can still mean switching frames, not a no-op.
    const phoneDoc = document.implementation.createHTMLDocument("phone");
    phoneDoc.body.innerHTML = `<div ${BLOCK_ID_ATTR}="t1">Hello</div>`;
    const tabletDoc = document.implementation.createHTMLDocument("tablet");
    tabletDoc.body.innerHTML = `<div ${BLOCK_ID_ATTR}="t1">Hello</div>`;

    const model = makeTextModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const editor = new RichTextEditor(engine);

    editor.enter("t1", phoneDoc);
    const phoneEl = phoneDoc.querySelector(`[${BLOCK_ID_ATTR}="t1"]`) as HTMLElement;
    expect(phoneEl.contentEditable).toBe("true");

    editor.enter("t1", tabletDoc);
    const tabletEl = tabletDoc.querySelector(`[${BLOCK_ID_ATTR}="t1"]`) as HTMLElement;

    expect(phoneEl.contentEditable).toBe("false");
    expect(tabletEl.contentEditable).toBe("true");
  });

  it("re-entering the exact same element is a true no-op (doesn't reset the baseline)", () => {
    document.body.innerHTML = `<div ${BLOCK_ID_ATTR}="t1">Hello</div>`;
    const model = makeTextModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const editor = new RichTextEditor(engine);

    editor.enter("t1");
    const el = document.querySelector(`[${BLOCK_ID_ATTR}="t1"]`) as HTMLElement;
    el.textContent = "Hello world"; // an in-progress, uncommitted edit
    editor.enter("t1"); // redundant re-entry of the same element

    // If this had gone through exit()+enter() again, the baseline would have been re-snapshotted
    // from the (still "Hello") model and the in-progress DOM edit would have been silently
    // discarded via exit()'s contentEditable=false toggle.
    expect(el.textContent).toBe("Hello world");
    expect(el.contentEditable).toBe("true");
  });

  it("a fully reverted edit (touch-and-revert) does not submit a spurious no-op commit", async () => {
    document.body.innerHTML = `<div ${BLOCK_ID_ATTR}="t1">Hello</div>`;
    const model = makeTextModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const applied: unknown[] = [];
    engine.onEvent((event) => {
      if (event.type === "applied") applied.push(event.op);
    });
    const editor = new RichTextEditor(engine);

    editor.enter("t1");
    const el = document.querySelector(`[${BLOCK_ID_ATTR}="t1"]`) as HTMLElement;
    el.textContent = "Hello world";
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.textContent = "Hello"; // revert back to the exact enter()-time baseline before exiting
    el.dispatchEvent(new Event("input", { bubbles: true }));

    editor.exit();
    // Nothing to await: a genuinely no-op flush resolves synchronously with no engine.submit() call
    // at all, so there's no "applied" event to wait for — give any errant async submit one beat.
    await Promise.resolve();
    await Promise.resolve();

    expect(applied).toEqual([]);
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

  it("applyFormat delegates 'strong'/'em' to toggleFormat and 'link' to setLink (#1225 Task 10)", () => {
    // The native Format menu (Swift `WYSIWYGCanvasController.applyFormat`) calls one JS method
    // name regardless of which command was requested — this is the dispatcher it calls into.
    // toggleFormat/setLink's own DOM-selection behavior is already covered above (and by the
    // e2e goldens for real Selection support); this only proves the dispatch mapping.
    document.body.innerHTML = `<div ${BLOCK_ID_ATTR}="t1">Hello</div>`;
    const model = makeTextModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const editor = new RichTextEditor(engine);
    const toggleSpy = vi.spyOn(editor, "toggleFormat");
    const setLinkSpy = vi.spyOn(editor, "setLink");

    editor.enter("t1");
    editor.applyFormat("strong");
    editor.applyFormat("em");
    editor.applyFormat("link", "/about");
    editor.applyFormat("link"); // no href: passes "" through, same as Markdown's empty-URL link

    expect(toggleSpy.mock.calls).toEqual([["strong"], ["em"]]);
    expect(setLinkSpy.mock.calls).toEqual([["/about"], [""]]);
  });

  it("reattaches to the replaced DOM node after an applied op re-renders the block (#1225 Task 14)", async () => {
    // The exact failure mode breakpoints.ts's #render triggers: a whole-subtree re-render replaces
    // the block's element with a fresh node carrying the same block-id attribute, disconnecting the
    // element RichTextEditor holds as its active element (design doc §7a's known limitation).
    document.body.innerHTML = `<div ${BLOCK_ID_ATTR}="t1">Hello</div>`;
    const model = makeTextModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const editor = new RichTextEditor(engine);

    editor.enter("t1");
    const original = editor.activeElementForTesting;
    if (!original) throw new Error("expected an active element after enter()");

    const replacement = document.createElement("p");
    replacement.setAttribute(BLOCK_ID_ATTR, "t1");
    replacement.textContent = "hi";
    original.replaceWith(replacement);

    await engine.submit({ kind: "setProp", blockId: "t1", propName: "x", value: "y", previousValue: "z" });

    expect(editor.activeElementForTesting).toBe(replacement);
    // The pointer moving isn't enough on its own — the replacement arrives from a fresh render as
    // plain, non-editable DOM. Without making it editable (and focusing it), the owner's
    // in-progress edit still effectively dies even though RichTextEditor's internal state is
    // correct (#1225 final-review fix wave, Finding 4).
    expect(replacement.contentEditable).toBe("true");
  });

  it("input on the reattached element still schedules a debounced commit (proves listeners moved, not just the pointer)", async () => {
    vi.useFakeTimers();
    document.body.innerHTML = `<div ${BLOCK_ID_ATTR}="t1">Hello</div>`;
    const model = makeTextModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const editor = new RichTextEditor(engine, { debounceMs: 400 });

    editor.enter("t1");
    const original = editor.activeElementForTesting;
    if (!original) throw new Error("expected an active element after enter()");

    const replacement = document.createElement("p");
    replacement.setAttribute(BLOCK_ID_ATTR, "t1");
    replacement.textContent = "Hello";
    original.replaceWith(replacement);

    await engine.submit({ kind: "setProp", blockId: "t1", propName: "x", value: "y", previousValue: "z" });

    // The old node no longer has a listener wired to it; typing on the new node must still commit.
    replacement.textContent = "Hello world";
    replacement.dispatchEvent(new Event("input", { bubbles: true }));
    await vi.advanceTimersByTimeAsync(400);

    expect(engine.modelSync.getBlock("t1")?.richText).toEqual([{ kind: "text", text: "Hello world" }]);
    vi.useRealTimers();
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

  it("exiting via Escape stops the event from reaching a document-level listener", () => {
    const engine = new WysiwygEngine(
      { path: "src/pages/index.astro", version: "v0", rootIds: ["b1"], blocks: { b1: { id: "b1", kind: "text", componentName: "p", props: {}, slots: {}, sourceSpan: [0, 0], richText: [] } } },
      { sendOp: async () => ({ status: "applied", model: { path: "src/pages/index.astro", version: "v1", rootIds: ["b1"], blocks: {} } }), onModelUpdate: () => () => {} },
    );
    document.body.innerHTML = `<p data-anglesite-block-id="b1"></p>`;
    const editor = new RichTextEditor(engine);
    editor.enter("b1");

    const documentListener = vi.fn();
    document.addEventListener("keydown", documentListener);

    const el = document.querySelector('[data-anglesite-block-id="b1"]') as HTMLElement;
    el.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));

    expect(editor.activeBlockId).toBeNull();
    expect(documentListener).not.toHaveBeenCalled();
    document.removeEventListener("keydown", documentListener);
  });
});
