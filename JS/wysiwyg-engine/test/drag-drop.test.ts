// @vitest-environment jsdom

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
