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

describe("mount.ts drag chrome", () => {
  beforeEach(() => { document.body.innerHTML = ""; });

  it("renderSelectionHandle appends a handle element hidden until a block is selected", () => {
    const engine = new WysiwygEngine(emptyModel(), stubTransport());
    const dragReorder = { startDrag: vi.fn() } as any;
    const dispose = __testables.renderSelectionHandle(engine, dragReorder);

    const handle = document.getElementById("__anglesite-wysiwyg-drag-handle");
    expect(handle).not.toBeNull();
    expect(handle?.style.display).toBe("none");
    dispose();
  });

  it("pointerdown on the handle starts a drag of the currently selected block", () => {
    const el = document.createElement("div");
    el.setAttribute("data-anglesite-block-id", "b1");
    document.body.appendChild(el);
    Object.defineProperty(el, "getBoundingClientRect", { value: () => ({ x: 5, y: 5, width: 10, height: 10, top: 5, left: 5, right: 15, bottom: 15 }) });

    const engine = new WysiwygEngine(emptyModel(), stubTransport());
    engine.selection.select("b1");
    const dragReorder = { startDrag: vi.fn() } as any;
    const dispose = __testables.renderSelectionHandle(engine, dragReorder);

    const handle = document.getElementById("__anglesite-wysiwyg-drag-handle")!;
    handle.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true }));
    expect(dragReorder.startDrag).toHaveBeenCalledWith("b1");
    dispose();
  });

  it("dispose removes the handle element", () => {
    const engine = new WysiwygEngine(emptyModel(), stubTransport());
    const dragReorder = { startDrag: vi.fn() } as any;
    const dispose = __testables.renderSelectionHandle(engine, dragReorder);
    dispose();
    expect(document.getElementById("__anglesite-wysiwyg-drag-handle")).toBeNull();
  });
});
