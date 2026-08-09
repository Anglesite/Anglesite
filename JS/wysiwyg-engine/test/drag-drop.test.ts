// @vitest-environment jsdom

import { describe, it, expect } from "vitest";
import { nearestIndexInSlot, computeDropTarget, generateBlockId, submitDrop, DragReorderController } from "../src/drag-drop.js";
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

  function makeThreeBlockModel(): BlockModel {
    const model = makeTwoBlockModel();
    return {
      ...model,
      rootIds: [...model.rootIds, "b3"],
      blocks: {
        ...model.blocks,
        b3: { id: "b3", kind: "astro", componentName: "Newsletter", props: {}, slots: {}, sourceSpan: [2, 3] },
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

    // This test never releases the pointer, so the document-level listeners startDrag() attached
    // would outlive it and see the *next* test's synthetic events. Clean up explicitly rather than
    // relying on test ordering to absorb them.
    controller.dispose();
  });

  it("submits a downward same-slot move against post-removal indices", async () => {
    // computeDropTarget measures with the dragged element still in the DOM; moveBlock.toIndex is
    // post-removal (types.ts). jsdom reports all-zero rects, so stub the geometry directly — this
    // is the unit-tier guard for the off-by-one the e2e downward-drag golden covers end to end.
    // Three blocks are the minimum that can tell the bug apart: with two, an unadjusted index 2 and
    // a correct index 1 both land at the end of the post-removal list.
    document.body.innerHTML = `
      <div id="canvas">
        <div ${BLOCK_ID_ATTR}="b1"></div>
        <div ${BLOCK_ID_ATTR}="b2"></div>
        <div ${BLOCK_ID_ATTR}="b3"></div>
      </div>
    `;
    const container = document.getElementById("canvas");
    if (!container) throw new Error("fixture missing");
    const bounds = [
      { top: 0, bottom: 20 },
      { top: 20, bottom: 40 },
      { top: 40, bottom: 60 },
    ];
    Array.from(container.children).forEach((child, i) => {
      const b = bounds[i];
      if (!b) return;
      child.getBoundingClientRect = () => ({ ...b, left: 0, right: 10, x: 0, y: b.top, width: 10, height: 20, toJSON: () => ({}) });
    });

    const model = makeThreeBlockModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const indicators: { index: number }[] = [];
    const controller = new DragReorderController(engine, (t) => t && indicators.push(t), container);

    const applied = new Promise<void>((resolve) => {
      const unsubscribe = engine.onEvent((event) => {
        if (event.type === "applied") {
          unsubscribe();
          resolve();
        }
      });
    });

    controller.startDrag("b1");
    // Below b2's midpoint (30) but above b3's (50) — the indicator reads "between b2 and b3", i.e.
    // pre-removal index 2.
    document.dispatchEvent(new PointerEvent("pointermove", { clientX: 5, clientY: 35 }));
    expect(indicators.map((t) => t.index)).toEqual([2]);
    document.dispatchEvent(new PointerEvent("pointerup"));
    await applied;

    expect(engine.modelSync.current.rootIds).toEqual(["b2", "b1", "b3"]);
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
