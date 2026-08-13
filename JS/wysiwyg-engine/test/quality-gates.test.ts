// @vitest-environment jsdom
import { describe, it, expect, beforeEach, vi } from "vitest";
import { QualityGateChips, CHIP_ATTR } from "../src/quality-gates.js";
import type { Finding, QualityGateTransport } from "../src/quality-gates.js";
import { WysiwygEngine } from "../src/engine.js";
import { FixtureHost } from "../src/testing/fixture-host.js";
import { BLOCK_ID_ATTR } from "../src/hit-test.js";
import type { BlockModel } from "../src/types.js";

class FakeQualityGateTransport implements QualityGateTransport {
  #listeners = new Set<(findings: Finding[]) => void>();
  onFindings(listener: (findings: Finding[]) => void): () => void {
    this.#listeners.add(listener);
    return () => this.#listeners.delete(listener);
  }
  push(findings: Finding[]): void {
    for (const listener of this.#listeners) listener(findings);
  }
}

function makeModel(): BlockModel {
  return {
    path: "src/pages/index.astro",
    version: "v1",
    rootIds: ["b1"],
    blocks: { b1: { id: "b1", kind: "astro", componentName: "Image", props: {}, slots: {}, sourceSpan: [0, 1] } },
  };
}

describe("QualityGateChips", () => {
  beforeEach(() => {
    document.body.innerHTML = `<div ${BLOCK_ID_ATTR}="b1"></div>`;
  });

  it("renders one chip per pushed finding, anchored near its block", () => {
    const model = makeModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const transport = new FakeQualityGateTransport();
    new QualityGateChips(engine, transport);
    const finding: Finding = { id: "b1::imageWeight", blockId: "b1", category: "imageWeight", severity: "warning", message: "big photo" };

    transport.push([finding]);

    const chips = document.querySelectorAll(`[${CHIP_ATTR}]`);
    expect(chips).toHaveLength(1);
    expect(chips[0]?.getAttribute(CHIP_ATTR)).toBe("b1::imageWeight");
    expect(chips[0]?.textContent).toContain("big photo");
  });

  it("gives the chip live-region semantics and an aria-label naming its category and message", () => {
    const model = makeModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const transport = new FakeQualityGateTransport();
    new QualityGateChips(engine, transport);
    const finding: Finding = { id: "b1::altText", blockId: "b1", category: "altText", severity: "warning", message: "missing alt text" };

    transport.push([finding]);

    const chip = document.querySelector(`[${CHIP_ATTR}]`) as HTMLElement;
    expect(chip.getAttribute("role")).toBe("status");
    expect(chip.getAttribute("aria-live")).toBe("polite");
    expect(chip.getAttribute("aria-label")).toBe("Alt text issue: missing alt text");
  });

  it("updates the chip's aria-label when a later push changes its message", () => {
    const model = makeModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const transport = new FakeQualityGateTransport();
    new QualityGateChips(engine, transport);
    const finding: Finding = { id: "b1::imageWeight", blockId: "b1", category: "imageWeight", severity: "warning", message: "600 KB" };
    transport.push([finding]);

    transport.push([{ ...finding, message: "700 KB" }]);

    const chip = document.querySelector(`[${CHIP_ATTR}]`) as HTMLElement;
    expect(chip.getAttribute("aria-label")).toBe("Image size issue: 700 KB");
  });

  it("gives the Apply button a category-specific label so multiple simultaneous buttons aren't ambiguous", () => {
    const model = makeModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const transport = new FakeQualityGateTransport();
    new QualityGateChips(engine, transport);
    const fix = { kind: "setProp", blockId: "b1", propName: "level", value: 3, previousValue: 4 } as const;
    const finding: Finding = { id: "b1::headingOrder", blockId: "b1", category: "headingOrder", severity: "warning", message: "heading skip", fix };

    transport.push([finding]);

    const button = document.querySelector(`[${CHIP_ATTR}] button`) as HTMLButtonElement;
    expect(button.textContent).toBe("Apply");
    expect(button.getAttribute("aria-label")).toBe("Apply fix for heading order issue");
  });

  it("stacks a second finding on the same block below the first instead of overlapping it", () => {
    const model = makeModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const transport = new FakeQualityGateTransport();
    new QualityGateChips(engine, transport);
    const first: Finding = { id: "b1::altText", blockId: "b1", category: "altText", severity: "warning", message: "missing alt" };
    const second: Finding = { id: "b1::imageWeight", blockId: "b1", category: "imageWeight", severity: "warning", message: "big photo" };

    transport.push([first, second]);

    const firstChip = document.querySelector('[data-quality-chip-id="b1::altText"]') as HTMLElement;
    const secondChip = document.querySelector('[data-quality-chip-id="b1::imageWeight"]') as HTMLElement;
    expect(parseInt(secondChip.style.top, 10)).toBeGreaterThan(parseInt(firstChip.style.top, 10));
  });

  it("removes a chip once it's no longer in a later push (keyed diff)", () => {
    const model = makeModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const transport = new FakeQualityGateTransport();
    new QualityGateChips(engine, transport);
    const finding: Finding = { id: "b1::imageWeight", blockId: "b1", category: "imageWeight", severity: "warning", message: "big photo" };

    transport.push([finding]);
    expect(document.querySelectorAll(`[${CHIP_ATTR}]`)).toHaveLength(1);

    transport.push([]);
    expect(document.querySelectorAll(`[${CHIP_ATTR}]`)).toHaveLength(0);
  });

  it("updates an existing chip's message in place rather than replacing the element", () => {
    const model = makeModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const transport = new FakeQualityGateTransport();
    new QualityGateChips(engine, transport);
    const finding: Finding = { id: "b1::imageWeight", blockId: "b1", category: "imageWeight", severity: "warning", message: "600 KB" };

    transport.push([finding]);
    const firstElement = document.querySelector(`[${CHIP_ATTR}]`);

    transport.push([{ ...finding, message: "700 KB" }]);
    const secondElement = document.querySelector(`[${CHIP_ATTR}]`);

    expect(secondElement).toBe(firstElement);
    expect(secondElement?.textContent).toContain("700 KB");
  });

  it("falls back to a fixed page-level position when the finding's block has no on-screen element (e.g. the root sentinel)", () => {
    const model = makeModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const transport = new FakeQualityGateTransport();
    new QualityGateChips(engine, transport);
    const finding: Finding = { id: "__root__::contrast::color-text", blockId: "__root__", category: "contrast", severity: "warning", message: "low contrast" };

    transport.push([finding]);

    const chip = document.querySelector(`[${CHIP_ATTR}]`) as HTMLElement;
    expect(chip.style.top).toBe("8px");
    expect(chip.style.right).toBe("8px");
  });

  it("shows no Apply button when the finding has no fix", () => {
    const model = makeModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const transport = new FakeQualityGateTransport();
    new QualityGateChips(engine, transport);
    const finding: Finding = { id: "b1::imageWeight", blockId: "b1", category: "imageWeight", severity: "warning", message: "big photo" };

    transport.push([finding]);

    expect(document.querySelector(`[${CHIP_ATTR}] button`)).toBeNull();
  });

  it("clicking Apply submits the fix op and removes the chip on success", async () => {
    const model = makeModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const transport = new FakeQualityGateTransport();
    new QualityGateChips(engine, transport);
    const fix = { kind: "setProp", blockId: "b1", propName: "level", value: 3, previousValue: 4 } as const;
    const finding: Finding = { id: "b1::headingOrder", blockId: "b1", category: "headingOrder", severity: "warning", message: "heading skip", fix };
    transport.push([finding]);
    const button = document.querySelector(`[${CHIP_ATTR}] button`) as HTMLButtonElement;

    button.click();
    await Promise.resolve();
    await Promise.resolve();

    expect(document.querySelectorAll(`[${CHIP_ATTR}]`)).toHaveLength(0);
  });

  it("clicking Apply re-enables the button instead of removing the chip when the fix is rejected", async () => {
    const model = makeModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    vi.spyOn(engine, "submit").mockResolvedValue({ status: "rejected", reason: "version-mismatch" });
    const transport = new FakeQualityGateTransport();
    new QualityGateChips(engine, transport);
    const fix = { kind: "setProp", blockId: "b1", propName: "level", value: 3, previousValue: 4 } as const;
    const finding: Finding = { id: "b1::headingOrder", blockId: "b1", category: "headingOrder", severity: "warning", message: "heading skip", fix };
    transport.push([finding]);
    const button = document.querySelector(`[${CHIP_ATTR}] button`) as HTMLButtonElement;

    button.click();
    await Promise.resolve();
    await Promise.resolve();

    expect(document.querySelectorAll(`[${CHIP_ATTR}]`)).toHaveLength(1);
    expect(button.disabled).toBe(false);
  });

  it("styles the chip so it reads as a chip and sits above page content", () => {
    const model = makeModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const transport = new FakeQualityGateTransport();
    new QualityGateChips(engine, transport);

    transport.push([{ id: "b1::imageWeight", blockId: "b1", category: "imageWeight", severity: "warning", message: "big photo" }]);

    const chip = document.querySelector(`[${CHIP_ATTR}]`) as HTMLElement;
    expect(chip.style.background).not.toBe("");
    expect(chip.style.padding).not.toBe("");
    expect(chip.style.borderRadius).not.toBe("");
    expect(chip.style.font).not.toBe("");
    expect(parseInt(chip.style.zIndex, 10)).toBeGreaterThan(1000);
  });

  it("re-positions rendered chips on scroll and resize, with no new findings push", () => {
    const model = makeModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const transport = new FakeQualityGateTransport();
    new QualityGateChips(engine, transport);
    const block = document.querySelector(`[${BLOCK_ID_ATTR}="b1"]`) as HTMLElement;
    // jsdom's own getBoundingClientRect is all zeros, so the anchor has to be faked to make a
    // *change* in geometry observable at all.
    block.getBoundingClientRect = () => ({ x: 10, y: 100, width: 50, height: 20 }) as DOMRect;
    transport.push([{ id: "b1::imageWeight", blockId: "b1", category: "imageWeight", severity: "warning", message: "big photo" }]);
    const chip = document.querySelector(`[${CHIP_ATTR}]`) as HTMLElement;
    expect(chip.style.top).toBe("100px");

    block.getBoundingClientRect = () => ({ x: 10, y: 40, width: 50, height: 20 }) as DOMRect;
    window.dispatchEvent(new Event("scroll"));
    expect(chip.style.top).toBe("40px");

    block.getBoundingClientRect = () => ({ x: 30, y: 40, width: 50, height: 20 }) as DOMRect;
    window.dispatchEvent(new Event("resize"));
    expect(chip.style.left).toBe("80px");
  });

  it("re-attaches a chip whose container the host cleared out from under it", () => {
    const container = document.createElement("div");
    document.body.appendChild(container);
    const model = makeModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const transport = new FakeQualityGateTransport();
    new QualityGateChips(engine, transport, container);
    const finding: Finding = { id: "b1::imageWeight", blockId: "b1", category: "imageWeight", severity: "warning", message: "big photo" };
    transport.push([finding]);
    expect(container.querySelectorAll(`[${CHIP_ATTR}]`)).toHaveLength(1);

    // What the host's own re-render does (e2e/fixture-page.ts's render(): `root.innerHTML = ""`).
    container.replaceChildren();
    expect(container.querySelectorAll(`[${CHIP_ATTR}]`)).toHaveLength(0);

    transport.push([finding]);

    expect(container.querySelectorAll(`[${CHIP_ATTR}]`)).toHaveLength(1);
    expect(container.querySelector(`[${CHIP_ATTR}]`)?.textContent).toContain("big photo");
  });

  it("dispose() unsubscribes from the transport and removes all rendered chips", () => {
    const model = makeModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const transport = new FakeQualityGateTransport();
    const chips = new QualityGateChips(engine, transport);
    transport.push([{ id: "b1::imageWeight", blockId: "b1", category: "imageWeight", severity: "warning", message: "big" }]);
    expect(document.querySelectorAll(`[${CHIP_ATTR}]`)).toHaveLength(1);

    chips.dispose();

    expect(document.querySelectorAll(`[${CHIP_ATTR}]`)).toHaveLength(0);
    transport.push([{ id: "b1::altText", blockId: "b1", category: "altText", severity: "warning", message: "missing alt" }]);
    expect(document.querySelectorAll(`[${CHIP_ATTR}]`)).toHaveLength(0);
  });
});
