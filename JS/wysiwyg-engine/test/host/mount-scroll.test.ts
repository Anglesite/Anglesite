// @vitest-environment jsdom
import { describe, it, expect, beforeEach, vi } from "vitest";
import { WysiwygEngine } from "../../src/engine.js";
import type { BlockModel, HostTransport, OpResult } from "../../src/types.js";
import { __testables } from "../../src/host/mount.js";

function stubTransport(): HostTransport {
  return { sendOp: async (): Promise<OpResult> => ({ status: "applied", model: emptyModel() }), onModelUpdate: () => () => {} };
}
function emptyModel(): BlockModel {
  return { path: "src/pages/index.astro", version: "v0", rootIds: [], blocks: {} };
}

// jsdom has no layout engine and doesn't implement `Element.scrollIntoView` at all (confirmed:
// `typeof document.createElement("div").scrollIntoView === "undefined"`), so every test here stubs
// it directly on the fixture element, the same way mount-drag.test.ts stubs `getBoundingClientRect`.
describe("mount.ts wireScrollIntoView (#1700)", () => {
  beforeEach(() => {
    document.body.innerHTML = "";
  });

  it("scrolls the newly-selected block's element into view", () => {
    const el = document.createElement("div");
    el.setAttribute("data-anglesite-block-id", "b1");
    const scrollIntoView = vi.fn();
    Object.defineProperty(el, "scrollIntoView", { value: scrollIntoView });
    document.body.appendChild(el);

    const engine = new WysiwygEngine(emptyModel(), stubTransport());
    const dispose = __testables.wireScrollIntoView(engine);

    engine.selection.select("b1");

    expect(scrollIntoView).toHaveBeenCalledWith({ block: "nearest", inline: "nearest" });
    dispose();
  });

  it("does nothing when selection clears", () => {
    const el = document.createElement("div");
    el.setAttribute("data-anglesite-block-id", "b1");
    const scrollIntoView = vi.fn();
    Object.defineProperty(el, "scrollIntoView", { value: scrollIntoView });
    document.body.appendChild(el);

    const engine = new WysiwygEngine(emptyModel(), stubTransport());
    const dispose = __testables.wireScrollIntoView(engine);
    engine.selection.select("b1");
    scrollIntoView.mockClear();

    engine.selection.select(null);

    expect(scrollIntoView).not.toHaveBeenCalled();
    dispose();
  });

  it("no-ops when the selected block has no element in the DOM yet", () => {
    const engine = new WysiwygEngine(emptyModel(), stubTransport());
    const dispose = __testables.wireScrollIntoView(engine);

    expect(() => engine.selection.select("missing")).not.toThrow();
    dispose();
  });

  it("dispose stops reacting to further selection changes", () => {
    const el = document.createElement("div");
    el.setAttribute("data-anglesite-block-id", "b1");
    const scrollIntoView = vi.fn();
    Object.defineProperty(el, "scrollIntoView", { value: scrollIntoView });
    document.body.appendChild(el);

    const engine = new WysiwygEngine(emptyModel(), stubTransport());
    const dispose = __testables.wireScrollIntoView(engine);
    dispose();

    engine.selection.select("b1");

    expect(scrollIntoView).not.toHaveBeenCalled();
  });
});
