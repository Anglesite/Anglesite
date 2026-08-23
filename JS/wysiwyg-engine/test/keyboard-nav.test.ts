// @vitest-environment jsdom
import { describe, it, expect } from "vitest";
import { WysiwygEngine } from "../src/engine.js";
import { RichTextEditor } from "../src/rich-text.js";
import { KeyboardNavigation } from "../src/keyboard-nav.js";
import type { BlockModel, HostTransport } from "../src/types.js";

function fixtureModel(): BlockModel {
  return {
    path: "src/pages/index.astro",
    version: "v0",
    rootIds: ["b1", "b2", "b3"],
    blocks: {
      b1: { id: "b1", kind: "text", componentName: "p", props: {}, slots: {}, sourceSpan: [0, 0], richText: [{ kind: "text", text: "one" }] },
      b2: { id: "b2", kind: "astro", componentName: "Testimonial", props: {}, slots: {}, sourceSpan: [0, 0] },
      b3: { id: "b3", kind: "text", componentName: "p", props: {}, slots: {}, sourceSpan: [0, 0], richText: [{ kind: "text", text: "three" }] },
    },
  };
}

function fixtureTransport(): HostTransport {
  return { sendOp: async () => ({ status: "applied", model: fixtureModel() }), onModelUpdate: () => () => {} };
}

function dispatchKey(target: EventTarget, key: string): void {
  target.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
}

describe("KeyboardNavigation (#1589)", () => {
  it("ArrowDown selects the first block when nothing is selected", () => {
    const engine = new WysiwygEngine(fixtureModel(), fixtureTransport());
    const richText = new RichTextEditor(engine);
    new KeyboardNavigation(engine, richText, document);

    dispatchKey(document, "ArrowDown");

    expect(engine.selection.current).toBe("b1");
  });

  it("ArrowDown/ArrowUp move selection forward/backward through rootIds, clamped at the ends", () => {
    const engine = new WysiwygEngine(fixtureModel(), fixtureTransport());
    const richText = new RichTextEditor(engine);
    new KeyboardNavigation(engine, richText, document);

    dispatchKey(document, "ArrowDown");
    dispatchKey(document, "ArrowDown");
    expect(engine.selection.current).toBe("b2");

    dispatchKey(document, "ArrowDown");
    dispatchKey(document, "ArrowDown"); // already at the last block — stays clamped
    expect(engine.selection.current).toBe("b3");

    dispatchKey(document, "ArrowUp");
    expect(engine.selection.current).toBe("b2");
  });

  it("Return enters text editing on a selected text-kind block", () => {
    document.body.innerHTML = `<p data-anglesite-block-id="b1"></p>`;
    const engine = new WysiwygEngine(fixtureModel(), fixtureTransport());
    const richText = new RichTextEditor(engine);
    new KeyboardNavigation(engine, richText, document);
    engine.selection.select("b1");

    dispatchKey(document, "Enter");

    expect(richText.activeBlockId).toBe("b1");
  });

  it("Return no-ops on a non-text-kind selected block", () => {
    const engine = new WysiwygEngine(fixtureModel(), fixtureTransport());
    const richText = new RichTextEditor(engine);
    new KeyboardNavigation(engine, richText, document);
    engine.selection.select("b2");

    dispatchKey(document, "Enter");

    expect(richText.activeBlockId).toBeNull();
  });

  it("Escape clears block selection when not editing", () => {
    const engine = new WysiwygEngine(fixtureModel(), fixtureTransport());
    const richText = new RichTextEditor(engine);
    new KeyboardNavigation(engine, richText, document);
    engine.selection.select("b1");

    dispatchKey(document, "Escape");

    expect(engine.selection.current).toBeNull();
  });

  it("arrows/Return/Escape are no-ops while a text-editing session is active", () => {
    document.body.innerHTML = `<p data-anglesite-block-id="b1"></p>`;
    const engine = new WysiwygEngine(fixtureModel(), fixtureTransport());
    const richText = new RichTextEditor(engine);
    new KeyboardNavigation(engine, richText, document);
    engine.selection.select("b1");
    richText.enter("b1");

    dispatchKey(document, "ArrowDown");

    expect(engine.selection.current).toBe("b1"); // unchanged — the caret moves, not block selection
  });

  it("dispose() removes the keydown listener", () => {
    const engine = new WysiwygEngine(fixtureModel(), fixtureTransport());
    const richText = new RichTextEditor(engine);
    const nav = new KeyboardNavigation(engine, richText, document);
    nav.dispose();

    dispatchKey(document, "ArrowDown");

    expect(engine.selection.current).toBeNull();
  });

  it("Tab requests forward focus into the inspector for the currently selected block (#1616)", () => {
    const engine = new WysiwygEngine(fixtureModel(), fixtureTransport());
    const richText = new RichTextEditor(engine);
    const requests: Array<{ direction: "forward" | "backward"; blockId: string }> = [];
    new KeyboardNavigation(engine, richText, document, (direction, blockId) => requests.push({ direction, blockId }));
    engine.selection.select("b1");

    dispatchKey(document, "Tab");

    expect(requests).toEqual([{ direction: "forward", blockId: "b1" }]);
  });

  it("Shift+Tab requests backward focus for the currently selected block (#1616)", () => {
    const engine = new WysiwygEngine(fixtureModel(), fixtureTransport());
    const richText = new RichTextEditor(engine);
    const requests: Array<{ direction: "forward" | "backward"; blockId: string }> = [];
    new KeyboardNavigation(engine, richText, document, (direction, blockId) => requests.push({ direction, blockId }));
    engine.selection.select("b1");

    document.dispatchEvent(new KeyboardEvent("keydown", { key: "Tab", shiftKey: true, bubbles: true, cancelable: true }));

    expect(requests).toEqual([{ direction: "backward", blockId: "b1" }]);
  });

  it("Tab does nothing when no block is selected (#1616)", () => {
    const engine = new WysiwygEngine(fixtureModel(), fixtureTransport());
    const richText = new RichTextEditor(engine);
    const requests: Array<{ direction: "forward" | "backward"; blockId: string }> = [];
    new KeyboardNavigation(engine, richText, document, (direction, blockId) => requests.push({ direction, blockId }));

    dispatchKey(document, "Tab");

    expect(requests).toEqual([]);
  });

  it("Tab is a no-op while a text-editing session is active (#1616)", () => {
    document.body.innerHTML = `<p data-anglesite-block-id="b1"></p>`;
    const engine = new WysiwygEngine(fixtureModel(), fixtureTransport());
    const richText = new RichTextEditor(engine);
    const requests: Array<{ direction: "forward" | "backward"; blockId: string }> = [];
    new KeyboardNavigation(engine, richText, document, (direction, blockId) => requests.push({ direction, blockId }));
    engine.selection.select("b1");
    richText.enter("b1");

    dispatchKey(document, "Tab");

    expect(requests).toEqual([]);
  });
});
