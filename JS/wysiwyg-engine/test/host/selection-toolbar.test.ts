// @vitest-environment jsdom
import { describe, it, expect, vi, afterEach } from "vitest";
import { instructionForAction, SelectionToolbar } from "../../src/host/selection-toolbar.js";
import type { WritingHelpTransport } from "../../src/host/selection-toolbar.js";
import { RichTextEditor } from "../../src/rich-text.js";
import { WysiwygEngine } from "../../src/engine.js";
import { FixtureHost } from "../../src/testing/fixture-host.js";
import type { BlockModel, OpResult, WritingHelpReply } from "../../src/types.js";

describe("instructionForAction", () => {
  it("builds a canned instruction for rewrite", () => {
    expect(instructionForAction("rewrite")).toContain("clearer");
  });

  it("builds a canned instruction for tighten", () => {
    expect(instructionForAction("tighten")).toMatch(/shorter/i);
  });

  it("builds a canned instruction for a tone preset", () => {
    const friendlier = instructionForAction("tone", "friendlier");
    const formal = instructionForAction("tone", "more formal");
    expect(friendlier).toContain("friendlier");
    expect(formal).toContain("more formal");
    expect(friendlier).not.toBe(formal);
  });
});

function makeModel(): BlockModel {
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
        richText: [{ kind: "text", text: "Range A Range B" }],
      },
    },
  };
}

function makeRichTextEditor(): RichTextEditor {
  const model = makeModel();
  const engine = new WysiwygEngine(model, new FixtureHost(model));
  return new RichTextEditor(engine);
}

/** Detached from any block element on purpose: these tests drive `SelectionToolbar` entirely
 *  through a `currentSelectionContext()` spy (real `RichTextEditor.currentSelectionContext`'s own
 *  DOM/Selection wiring is already covered in `test/rich-text.test.ts`), so the range's content
 *  only needs to be distinguishable text, not a real editable block.
 *
 *  Unlike `Element.prototype.getBoundingClientRect` (which jsdom implements, always returning
 *  zeros — see e.g. test/selection.test.ts), jsdom's `Range` doesn't implement
 *  `getBoundingClientRect` at all, so `#showButtons`'s positioning call throws without this stub —
 *  same per-object-stub technique test/host/mount-drag.test.ts already uses for elements. */
function makeRange(text: string): Range {
  const node = document.createTextNode(text);
  document.body.appendChild(node);
  const range = document.createRange();
  range.selectNodeContents(node);
  Object.defineProperty(range, "getBoundingClientRect", {
    value: () => ({ x: 0, y: 0, width: 0, height: 0, top: 0, left: 0, right: 0, bottom: 0 }),
  });
  return range;
}

/** Controllable `WritingHelpTransport` fake: `requestWritingHelp()` doesn't settle until the test
 *  calls back the resolver/rejecter it hands out, so a request/selection-change interleaving (or a
 *  transport failure) can be driven deterministically instead of racing real async timing. */
class FakeWritingHelpTransport implements WritingHelpTransport {
  #pending: Array<{ resolve: (reply: WritingHelpReply) => void; reject: (err: unknown) => void }> = [];

  sendOp(): Promise<OpResult> {
    return Promise.resolve({ status: "applied", model: makeModel() });
  }

  onModelUpdate(): () => void {
    return () => {};
  }

  requestWritingHelp(): Promise<WritingHelpReply> {
    return new Promise((resolve, reject) => {
      this.#pending.push({ resolve, reject });
    });
  }

  resolveOldest(reply: WritingHelpReply): void {
    const next = this.#pending.shift();
    if (!next) throw new Error("no pending requestWritingHelp() call to resolve");
    next.resolve(reply);
  }

  rejectOldest(err: unknown): void {
    const next = this.#pending.shift();
    if (!next) throw new Error("no pending requestWritingHelp() call to reject");
    next.reject(err);
  }
}

describe("SelectionToolbar", () => {
  afterEach(() => {
    document.body.innerHTML = "";
  });

  // Reviewer finding (task-6 fix round 1): `#pendingRange` was only ever set in `#request()` and
  // cleared in `#hide()` — `#showButtons()` never touched it. So reselecting to a different,
  // still-non-collapsed range while an earlier request was in flight left `#pendingRange` pointing
  // at the *old* range, and the old request's eventual reply would pass the staleness guard
  // (`pendingRange !== range` compared the old range to itself) and overwrite the fresh button bar
  // with a preview bound to the old, no-longer-visible selection.
  it("a stale reply for an earlier selection does not clobber the button bar rendered for a newer selection", async () => {
    const rangeA = makeRange("Range A");
    const rangeB = makeRange("Range B");
    const editor = makeRichTextEditor();
    const contextSpy = vi.spyOn(editor, "currentSelectionContext");
    contextSpy.mockReturnValue({ blockId: "t1", range: rangeA, text: "Range A" });

    const transport = new FakeWritingHelpTransport();
    const toolbar = new SelectionToolbar(editor, transport, document);

    document.dispatchEvent(new Event("selectionchange")); // renders the button bar for A
    const rewriteButton = document.querySelector("[data-selection-toolbar] button") as HTMLButtonElement;
    expect(rewriteButton.textContent).toBe("Rewrite");
    rewriteButton.click(); // in-flight request for A

    // The visible selection moves on to a different, still non-collapsed range before A's reply
    // arrives — this must re-render the button bar for B and invalidate A's pending request.
    contextSpy.mockReturnValue({ blockId: "t1", range: rangeB, text: "Range B" });
    document.dispatchEvent(new Event("selectionchange"));

    transport.resolveOldest({ status: "rewritten", text: "Stale rewrite of A" });
    await Promise.resolve();
    await Promise.resolve();

    const toolbarEl = document.querySelector("[data-selection-toolbar]");
    expect(toolbarEl?.textContent).not.toContain("Stale rewrite of A");
    // Still showing B's (unchanged) button bar, not a preview bound to A's now-stale range.
    expect(toolbarEl?.querySelector("button")?.textContent).toBe("Rewrite");

    toolbar.dispose();
  });

  // Reviewer finding (task-6 fix round 1): `#request()` had no try/catch around the
  // `requestWritingHelp()` await, so a rejected promise (as opposed to a `{status:"unavailable"}`
  // reply) left the toolbar stuck on "Rewriting…" forever with an unhandled rejection.
  it("a rejected requestWritingHelp() shows an error instead of hanging on Rewriting… forever", async () => {
    const range = makeRange("Some text");
    const editor = makeRichTextEditor();
    vi.spyOn(editor, "currentSelectionContext").mockReturnValue({ blockId: "t1", range, text: "Some text" });

    const transport = new FakeWritingHelpTransport();
    const toolbar = new SelectionToolbar(editor, transport, document);

    document.dispatchEvent(new Event("selectionchange"));
    const rewriteButton = document.querySelector("[data-selection-toolbar] button") as HTMLButtonElement;
    rewriteButton.click();
    expect(document.querySelector("[data-selection-toolbar]")?.textContent).toContain("Rewriting");

    transport.rejectOldest(new Error("network fell over"));
    await Promise.resolve();
    await Promise.resolve();

    const toolbarEl = document.querySelector("[data-selection-toolbar]");
    expect(toolbarEl?.textContent).not.toContain("Rewriting");
    expect(toolbarEl?.textContent).toContain("try again");

    toolbar.dispose();
  });
});
