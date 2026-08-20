// @vitest-environment jsdom
import { describe, it, expect, beforeEach, vi } from "vitest";
import { WysiwygEngine } from "../../src/engine.js";
import type { BlockModel, HostTransport, OpResult } from "../../src/types.js";

// Re-implements just enough of mount.ts's selection wiring to unit-test in isolation — mount.ts
// itself is exercised end-to-end by the existing native-host-transport tests plus this file once
// wireSelection is exported. Importing the real wireSelection keeps this from drifting.
import { __testables } from "../../src/host/mount.js";

function stubTransport(): HostTransport {
  return {
    sendOp: async (): Promise<OpResult> => ({ status: "applied", model: emptyModel() }),
    onModelUpdate: () => () => {},
  };
}

function emptyModel(): BlockModel {
  return { path: "src/pages/index.astro", version: "v0", rootIds: [], blocks: {} };
}

describe("mount.ts selection wiring", () => {
  beforeEach(() => {
    (window as any).webkit = { messageHandlers: { wysiwyg: { postMessage: vi.fn() } } };
    document.body.innerHTML = "";
  });

  it("selecting a block posts a selection-changed message to native", () => {
    const engine = new WysiwygEngine(emptyModel(), stubTransport());
    const dispose = __testables.wireSelection(engine);
    engine.selection.select("b1");
    expect((window as any).webkit.messageHandlers.wysiwyg.postMessage).toHaveBeenCalledWith({
      type: "selection-changed",
      blockId: "b1",
    });
    dispose();
  });

  it("clicking a block element hit-tests and selects it", () => {
    const el = document.createElement("div");
    el.setAttribute("data-anglesite-block-id", "b1");
    Object.defineProperty(el, "getBoundingClientRect", { value: () => ({ x: 0, y: 0, width: 10, height: 10, top: 0, left: 0, right: 10, bottom: 10 }) });
    document.body.appendChild(el);
    Object.defineProperty(document, "elementFromPoint", { value: vi.fn().mockReturnValue(el), configurable: true });

    const engine = new WysiwygEngine(emptyModel(), stubTransport());
    const dispose = __testables.wireSelection(engine);
    document.dispatchEvent(new MouseEvent("click", { clientX: 5, clientY: 5, bubbles: true }));
    expect(engine.selection.current).toBe("b1");
    dispose();
  });

  it("dispose stops forwarding further selection changes", () => {
    const engine = new WysiwygEngine(emptyModel(), stubTransport());
    const dispose = __testables.wireSelection(engine);
    dispose();
    const postMessage = (window as any).webkit.messageHandlers.wysiwyg.postMessage as ReturnType<typeof vi.fn>;
    postMessage.mockClear();
    engine.selection.select("b2");
    expect(postMessage).not.toHaveBeenCalled();
  });
});
