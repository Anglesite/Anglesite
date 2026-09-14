// @vitest-environment jsdom
import { describe, it, expect, beforeEach } from "vitest";
import { WysiwygEngine } from "../../src/engine.js";
import type { BlockModel, HostTransport, OpResult } from "../../src/types.js";
import { HOVER_CLASS, renderHoverOutline } from "../../src/host/hover-outline.js";
import "../../src/host/mount.js";

function stubTransport(): HostTransport {
  return { sendOp: async (): Promise<OpResult> => ({ status: "applied", model: emptyModel() }), onModelUpdate: () => () => {} };
}
function emptyModel(): BlockModel {
  return { path: "src/pages/index.astro", version: "v0", rootIds: [], blocks: {} };
}

/** Two root blocks, the first with a nested child element — the shape a rendered page has. */
function renderTwoBlocks(): { first: HTMLElement; child: HTMLElement; second: HTMLElement } {
  document.body.innerHTML =
    `<section data-anglesite-block-id="b1"><p id="child">Hello</p></section>` +
    `<section data-anglesite-block-id="b2">World</section>`;
  return {
    first: document.querySelector('[data-anglesite-block-id="b1"]') as HTMLElement,
    child: document.getElementById("child") as HTMLElement,
    second: document.querySelector('[data-anglesite-block-id="b2"]') as HTMLElement,
  };
}

function mouseOver(target: Element): void {
  target.dispatchEvent(new MouseEvent("mouseover", { bubbles: true }));
}
function mouseOut(target: Element, relatedTarget: Element | null): void {
  target.dispatchEvent(new MouseEvent("mouseout", { bubbles: true, relatedTarget }));
}

/**
 * #1957 parity item 1: the retired click-to-edit overlay outlined the text element under the
 * pointer (`JS/edit-overlay`'s `attachHover`); the block editor outlines the *block* under it.
 * These mirror that suite's hover cases — class on mouseover, cleared on mouseout, nothing for a
 * non-candidate — at block granularity.
 */
describe("hover outline (#1957)", () => {
  beforeEach(() => {
    document.head.innerHTML = "";
    document.body.innerHTML = "";
  });

  it("outlines the block under the pointer, walking up from a nested descendant", () => {
    const { first, child } = renderTwoBlocks();
    const engine = new WysiwygEngine(emptyModel(), stubTransport());
    const dispose = renderHoverOutline(engine);

    mouseOver(child);
    expect(first.classList.contains(HOVER_CLASS)).toBe(true);
    expect(child.classList.contains(HOVER_CLASS)).toBe(false);
    dispose();
  });

  it("moves the outline when the pointer crosses into another block", () => {
    const { first, second } = renderTwoBlocks();
    const engine = new WysiwygEngine(emptyModel(), stubTransport());
    const dispose = renderHoverOutline(engine);

    mouseOver(first);
    mouseOver(second);
    expect(first.classList.contains(HOVER_CLASS)).toBe(false);
    expect(second.classList.contains(HOVER_CLASS)).toBe(true);
    dispose();
  });

  it("keeps the outline while the pointer moves between two descendants of the same block", () => {
    const { first, child } = renderTwoBlocks();
    const engine = new WysiwygEngine(emptyModel(), stubTransport());
    const dispose = renderHoverOutline(engine);

    mouseOver(child);
    mouseOut(child, first);
    expect(first.classList.contains(HOVER_CLASS)).toBe(true);
    dispose();
  });

  it("clears the outline when the pointer leaves the block (or the document)", () => {
    const { first } = renderTwoBlocks();
    const engine = new WysiwygEngine(emptyModel(), stubTransport());
    const dispose = renderHoverOutline(engine);

    mouseOver(first);
    mouseOut(first, document.body);
    expect(first.classList.contains(HOVER_CLASS)).toBe(false);

    mouseOver(first);
    mouseOut(first, null);
    expect(first.classList.contains(HOVER_CLASS)).toBe(false);
    dispose();
  });

  it("does not outline chrome or page margin that belongs to no block", () => {
    const { first } = renderTwoBlocks();
    const stray = document.createElement("div");
    document.body.appendChild(stray);
    const engine = new WysiwygEngine(emptyModel(), stubTransport());
    const dispose = renderHoverOutline(engine);

    mouseOver(first);
    mouseOver(stray);
    expect(first.classList.contains(HOVER_CLASS)).toBe(false);
    expect(stray.classList.contains(HOVER_CLASS)).toBe(false);
    dispose();
  });

  it("never outlines the selected block, and clears the ring when the hovered block gets selected", () => {
    const { first, second } = renderTwoBlocks();
    const engine = new WysiwygEngine(emptyModel(), stubTransport());
    const dispose = renderHoverOutline(engine);

    engine.selection.select("b1");
    mouseOver(first);
    expect(first.classList.contains(HOVER_CLASS)).toBe(false);

    mouseOver(second);
    expect(second.classList.contains(HOVER_CLASS)).toBe(true);
    engine.selection.select("b2");
    expect(second.classList.contains(HOVER_CLASS)).toBe(false);
    dispose();
  });

  it("injects its stylesheet once and removes it (and the class) on dispose", () => {
    const { first } = renderTwoBlocks();
    const engine = new WysiwygEngine(emptyModel(), stubTransport());
    const dispose = renderHoverOutline(engine);
    const secondDispose = renderHoverOutline(engine);
    expect(document.head.querySelectorAll("style").length).toBe(1);

    mouseOver(first);
    secondDispose();
    dispose();
    expect(first.classList.contains(HOVER_CLASS)).toBe(false);
    expect(document.head.querySelectorAll("style").length).toBe(0);

    mouseOver(first);
    expect(first.classList.contains(HOVER_CLASS)).toBe(false);
  });

  it("is wired by mount() and torn down by unmount()", () => {
    const { first } = renderTwoBlocks();
    window.__anglesiteWysiwygMount!.mount(emptyModel());

    mouseOver(first);
    expect(first.classList.contains(HOVER_CLASS)).toBe(true);

    window.__anglesiteWysiwygMount!.unmount();
    expect(first.classList.contains(HOVER_CLASS)).toBe(false);
    mouseOver(first);
    expect(first.classList.contains(HOVER_CLASS)).toBe(false);
  });
});
