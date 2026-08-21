// @vitest-environment jsdom
import { describe, it, expect } from "vitest";
import { WysiwygEngine } from "../src/engine.js";
import { AccessibilityAnnotator } from "../src/accessibility.js";
import type { BlockModel, HostTransport } from "../src/types.js";

function fixtureModel(): BlockModel {
  return {
    path: "src/pages/index.astro",
    version: "v0",
    rootIds: ["b1", "b2"],
    blocks: {
      b1: { id: "b1", kind: "text", componentName: "h2", props: {}, slots: {}, sourceSpan: [0, 0], richText: [] },
      b2: { id: "b2", kind: "astro", componentName: "Testimonial", props: {}, slots: {}, sourceSpan: [0, 0] },
    },
  };
}

function fixtureTransport(): HostTransport {
  return { sendOp: async () => ({ status: "applied", model: fixtureModel() }), onModelUpdate: () => () => {} };
}

describe("AccessibilityAnnotator (#1589)", () => {
  it("labels each block with its palette display name, falling back to componentName", () => {
    document.body.innerHTML = `<h2 data-anglesite-block-id="b1"></h2><div data-anglesite-block-id="b2"></div>`;
    const engine = new WysiwygEngine(fixtureModel(), fixtureTransport());
    new AccessibilityAnnotator(engine, { h2: "Heading" });

    const b1 = document.querySelector('[data-anglesite-block-id="b1"]')!;
    const b2 = document.querySelector('[data-anglesite-block-id="b2"]')!;
    expect(b1.getAttribute("aria-label")).toBe("Heading");
    expect(b1.tagName).toBe("H2"); // native role/tag is left untouched
    expect(b2.getAttribute("aria-label")).toBe("Testimonial"); // no palette entry — falls back to componentName
  });

  it("sets aria-current and roving tabindex, and moves focus, when selection changes", () => {
    document.body.innerHTML = `<h2 data-anglesite-block-id="b1"></h2><div data-anglesite-block-id="b2"></div>`;
    const engine = new WysiwygEngine(fixtureModel(), fixtureTransport());
    new AccessibilityAnnotator(engine, {});

    engine.selection.select("b1");

    const b1 = document.querySelector('[data-anglesite-block-id="b1"]') as HTMLElement;
    const b2 = document.querySelector('[data-anglesite-block-id="b2"]') as HTMLElement;
    expect(b1.getAttribute("aria-current")).toBe("true");
    expect(b1.tabIndex).toBe(0);
    expect(b2.getAttribute("aria-current")).toBe("false");
    expect(b2.tabIndex).toBe(-1);
    expect(document.activeElement).toBe(b1);
  });

  it("re-annotates after a model update (e.g. a new block inserted)", async () => {
    document.body.innerHTML = `<h2 data-anglesite-block-id="b1"></h2>`;
    const engine = new WysiwygEngine({ ...fixtureModel(), rootIds: ["b1"], blocks: { b1: fixtureModel().blocks.b1! } }, fixtureTransport());
    new AccessibilityAnnotator(engine, { h2: "Heading" });

    document.body.innerHTML += `<div data-anglesite-block-id="b2"></div>`;
    await engine.submit({ kind: "setDesignToken", tokenName: "x", value: "1", previousValue: "0" });

    const b2 = document.querySelector('[data-anglesite-block-id="b2"]')!;
    // fixtureTransport's sendOp always resolves with fixtureModel(), which includes b2 — proves
    // the annotator re-ran after the applied event, not just once at construction.
    expect(b2.getAttribute("aria-label")).toBe("Testimonial");
  });
});
