// @vitest-environment jsdom
import { describe, it, expect, beforeEach, vi } from "vitest";
import { WysiwygEngine } from "../../src/engine.js";
import type { BlockModel, HostTransport, OpResult } from "../../src/types.js";
import { __testables } from "../../src/host/mount.js";
import { DragReorderController } from "../../src/drag-drop.js";
import { ROOT_PARENT_ID } from "../../src/types.js";

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

  it("renders a visible handle, not a transparent hit target", () => {
    const engine = new WysiwygEngine(emptyModel(), stubTransport());
    const dragReorder = { startDrag: vi.fn() } as any;
    const dispose = __testables.renderSelectionHandle(engine, dragReorder);

    const handle = document.getElementById("__anglesite-wysiwyg-drag-handle")!;
    expect(handle.style.background).not.toBe("transparent");
    expect(handle.style.border).not.toBe("");
    expect(handle.textContent).not.toBe("");
    dispose();
  });

  it("repositions the handle on scroll and resize so it does not go stale", () => {
    const el = document.createElement("div");
    el.setAttribute("data-anglesite-block-id", "b1");
    document.body.appendChild(el);
    let top = 100;
    Object.defineProperty(el, "getBoundingClientRect", {
      value: () => ({ x: 5, y: top, width: 10, height: 10, top, left: 5, right: 15, bottom: top + 10 }),
    });

    const engine = new WysiwygEngine(emptyModel(), stubTransport());
    engine.selection.select("b1");
    const dispose = __testables.renderSelectionHandle(engine, { startDrag: vi.fn() } as any);
    const handle = document.getElementById("__anglesite-wysiwyg-drag-handle")!;
    const atSelection = handle.style.top;
    expect(atSelection).not.toBe("");

    top = 40;
    window.dispatchEvent(new Event("scroll"));
    const afterScroll = handle.style.top;
    expect(afterScroll).not.toBe(atSelection);

    top = 220;
    window.dispatchEvent(new Event("resize"));
    expect(handle.style.top).not.toBe(afterScroll);

    // Cleanup has to take the viewport listeners with it, or a disposed handle keeps reacting.
    dispose();
    top = 999;
    expect(() => window.dispatchEvent(new Event("scroll"))).not.toThrow();
    expect(document.getElementById("__anglesite-wysiwyg-drag-handle")).toBeNull();
  });

  it("clicking the handle does not clear the selection it belongs to", () => {
    const el = document.createElement("div");
    el.setAttribute("data-anglesite-block-id", "b1");
    document.body.appendChild(el);
    Object.defineProperty(el, "getBoundingClientRect", {
      value: () => ({ x: 5, y: 5, width: 10, height: 10, top: 5, left: 5, right: 15, bottom: 15 }),
    });

    const engine = new WysiwygEngine(emptyModel(), stubTransport());
    const disposeSelection = __testables.wireSelection(engine);
    engine.selection.select("b1");
    const disposeHandle = __testables.renderSelectionHandle(engine, { startDrag: vi.fn() } as any);

    const handle = document.getElementById("__anglesite-wysiwyg-drag-handle")!;
    // What `hitTest` would really see for a click on the handle: jsdom has no layout engine, so
    // stub the lookup the way mount-selection.test.ts does. Walking up from the handle finds no
    // block id, so an unstopped click would select `null` and hide the handle mid-gesture.
    Object.defineProperty(document, "elementFromPoint", {
      value: vi.fn().mockReturnValue(handle),
      configurable: true,
    });
    handle.dispatchEvent(new MouseEvent("click", { bubbles: true }));

    expect(engine.selection.current).toBe("b1");
    disposeHandle();
    disposeSelection();
  });

  it("renderDropIndicator shows a line at the drop target and hides it on null", () => {
    const first = document.createElement("div");
    first.setAttribute("data-anglesite-block-id", "b1");
    const second = document.createElement("div");
    second.setAttribute("data-anglesite-block-id", "b2");
    document.body.append(first, second);
    Object.defineProperty(first, "getBoundingClientRect", {
      value: () => ({ x: 0, y: 0, width: 200, height: 50, top: 0, left: 0, right: 200, bottom: 50 }),
    });
    Object.defineProperty(second, "getBoundingClientRect", {
      value: () => ({ x: 0, y: 50, width: 200, height: 50, top: 50, left: 0, right: 200, bottom: 100 }),
    });

    const indicator = __testables.renderDropIndicator();
    const line = document.getElementById("__anglesite-wysiwyg-drop-indicator")!;
    expect(line.style.display).toBe("none");

    indicator.update({ parentId: "__root__", slot: "main", index: 1 });
    expect(line.style.display).toBe("block");
    expect(line.style.top).toBe("49px");
    expect(line.style.width).toBe("200px");

    // Past the last block = append: the line pins to the last block's bottom edge instead.
    indicator.update({ parentId: "__root__", slot: "main", index: 2 });
    expect(line.style.top).toBe("99px");

    indicator.update(null);
    expect(line.style.display).toBe("none");

    indicator.dispose();
    expect(document.getElementById("__anglesite-wysiwyg-drop-indicator")).toBeNull();
  });

  it("mount wires a real onIndicator callback, so a drag renders the drop indicator", () => {
    const el = document.createElement("div");
    el.setAttribute("data-anglesite-block-id", "b1");
    document.body.appendChild(el);
    Object.defineProperty(el, "getBoundingClientRect", {
      value: () => ({ x: 0, y: 10, width: 120, height: 40, top: 10, left: 0, right: 120, bottom: 50 }),
    });

    const engine = window.__anglesiteWysiwygMount!.mount(emptyModel());
    try {
      engine.selection.select("b1");
      const handle = document.getElementById("__anglesite-wysiwyg-drag-handle")!;
      handle.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true }));
      document.dispatchEvent(new PointerEvent("pointermove", { bubbles: true, clientX: 5, clientY: 12 }));

      const line = document.getElementById("__anglesite-wysiwyg-drop-indicator")!;
      expect(line.style.display).toBe("block");
    } finally {
      window.__anglesiteWysiwygMount!.unmount();
    }
    expect(document.getElementById("__anglesite-wysiwyg-drop-indicator")).toBeNull();
  });

  it("dropTargetAt reports the native root slot name, not the JS-side default", () => {
    window.__anglesiteWysiwygMount!.mount(emptyModel());
    try {
      const target = window.__anglesiteWysiwygMount!.dropTargetAt(10, 10);
      expect(target.slot).toBe("main");
      expect(target.slot).not.toBe("default");
      expect(target.parentId).toBe(ROOT_PARENT_ID);
    } finally {
      window.__anglesiteWysiwygMount!.unmount();
    }
  });

  it("dispose removes the handle element", () => {
    const engine = new WysiwygEngine(emptyModel(), stubTransport());
    const dragReorder = { startDrag: vi.fn() } as any;
    const dispose = __testables.renderSelectionHandle(engine, dragReorder);
    dispose();
    expect(document.getElementById("__anglesite-wysiwyg-drag-handle")).toBeNull();
  });

  it("unmount disposes the DragReorderController built by mount, not just the selection/handle wiring", () => {
    const disposeSpy = vi.spyOn(DragReorderController.prototype, "dispose");
    try {
      window.__anglesiteWysiwygMount!.mount(emptyModel());
      window.__anglesiteWysiwygMount!.unmount();
      expect(disposeSpy).toHaveBeenCalledTimes(1);
    } finally {
      disposeSpy.mockRestore();
    }
  });
});
