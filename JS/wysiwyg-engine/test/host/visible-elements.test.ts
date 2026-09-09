// @vitest-environment jsdom
import { describe, it, expect, beforeAll, beforeEach } from "vitest";
import {
  collectVisibleElements,
  installVisibleElementsReporter,
  type VisibleElement,
  type VisibleElementReport,
} from "../../src/host/visible-elements.js";

interface WebKit {
  messageHandlers: { wysiwyg: { postMessage: (body: unknown) => void } };
}

let sent: unknown[] = [];

function stubWebKit(): void {
  (window as unknown as { webkit: WebKit }).webkit = {
    messageHandlers: { wysiwyg: { postMessage: (body) => { sent.push(body); } } },
  };
}

function clearBody(): void {
  while (document.body.firstChild) document.body.removeChild(document.body.firstChild);
}

function makeEl<K extends keyof HTMLElementTagNameMap>(
  parent: Element,
  tag: K,
  attrs: Record<string, string> = {},
  text?: string,
): HTMLElementTagNameMap[K] {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, v);
  if (text !== undefined) el.textContent = text;
  parent.appendChild(el);
  return el;
}

function stubRect(el: Element, x = 0, y = 0, w = 100, h = 50): void {
  el.getBoundingClientRect = () => ({
    x, y, width: w, height: h,
    top: y, left: x, right: x + w, bottom: y + h,
    toJSON() { return {}; },
  });
}

beforeEach(() => {
  clearBody();
  sent = [];
  stubWebKit();
});

describe("collectVisibleElements (pure shape)", () => {
  it("returns the documented schema for a heading", () => {
    const h1 = makeEl(document.body, "h1", {}, "Hello");
    stubRect(h1, 10, 20, 200, 40);
    const r = collectVisibleElements([h1], "/about/")[0]!;
    expect(r.tag).toBe("H1");
    expect(r.text).toBe("Hello");
    expect(r.rect).toEqual({ x: 10, y: 20, width: 200, height: 40 });
    expect(r.pagePath).toBe("/about/");
    expect(typeof r.id).toBe("string");
    // selector is structured ElementInfo (see element-info.ts).
    expect(r.selector.tag).toBe("H1");
  });

  it("reuses data-anglesite-id when present", () => {
    const h1 = makeEl(document.body, "h1", { "data-anglesite-id": "hero" }, "Hi");
    stubRect(h1);
    const r = collectVisibleElements([h1], "/")[0]!;
    expect(r.id).toBe("hero");
  });

  it("generates a stable id and reuses it across calls for the same element", () => {
    const h1 = makeEl(document.body, "h1", {}, "Hi");
    stubRect(h1);
    const r1 = collectVisibleElements([h1], "/")[0]!;
    const r2 = collectVisibleElements([h1], "/")[0]!;
    expect(r1.id).toBe(r2.id);
    expect(r1.id).toMatch(/^v-/); // generated ids are prefixed
  });

  it("captures src for images", () => {
    const img = makeEl(document.body, "img", { src: "/a.png" });
    stubRect(img);
    const r = collectVisibleElements([img], "/")[0]!;
    expect(r.tag).toBe("IMG");
    expect(r.src).toBe("/a.png");
  });

  it("truncates text to 120 chars", () => {
    const long = "x".repeat(300);
    // <p> isn't a priority category, so route through a heading instead.
    const h2 = makeEl(document.body, "h2", {}, long);
    stubRect(h2);
    const r = collectVisibleElements([h2], "/")[0]!;
    expect(r.text!.length).toBeLessThanOrEqual(120);
  });

  it("captures ARIA role", () => {
    const btn = makeEl(document.body, "div", { role: "button" }, "Go");
    stubRect(btn);
    const r = collectVisibleElements([btn], "/")[0]!;
    expect(r.role).toBe("button");
  });

  it("captures alt for images", () => {
    const img = makeEl(document.body, "img", { src: "/a.png", alt: "beach sunset" });
    stubRect(img);
    const r = collectVisibleElements([img], "/")[0]!;
    expect(r.alt).toBe("beach sunset");
  });

  it("does not set alt for non-image elements", () => {
    const h1 = makeEl(document.body, "h1", { alt: "ignored" }, "Hi");
    stubRect(h1);
    const r = collectVisibleElements([h1], "/")[0]!;
    expect(r.alt).toBeUndefined();
  });

  it("captures aria-label on any element", () => {
    const btn = makeEl(document.body, "button", { "aria-label": "Close dialog" }, "✕");
    stubRect(btn);
    const r = collectVisibleElements([btn], "/")[0]!;
    expect(r.ariaLabel).toBe("Close dialog");
  });

  it("orders heading > image > nav-item > interactive", () => {
    const nav = makeEl(document.body, "nav");
    const navLink = makeEl(nav, "a", { href: "/x" }, "Link");
    const img = makeEl(document.body, "img", { src: "/i.png" });
    const h2 = makeEl(document.body, "h2", {}, "Title");
    const btn = makeEl(document.body, "button", {}, "Go");
    for (const el of [navLink, img, h2, btn]) stubRect(el);
    const out = collectVisibleElements([navLink, img, h2, btn], "/");
    expect(out.map((x) => x.tag)).toEqual(["H2", "IMG", "A", "BUTTON"]);
  });

  it("caps the report at 50 elements", () => {
    const items: Element[] = [];
    for (let i = 0; i < 60; i++) {
      const h = makeEl(document.body, "h2", {}, `H${i}`);
      stubRect(h);
      items.push(h);
    }
    const out = collectVisibleElements(items, "/");
    expect(out.length).toBe(50);
  });

  it("drops elements outside any priority category", () => {
    const div = makeEl(document.body, "div", {}, "structural");
    stubRect(div);
    expect(collectVisibleElements([div], "/")).toEqual([]);
  });

  it("classifies <a> outside nav as interactive (after nav items)", () => {
    const nav = makeEl(document.body, "nav");
    const navLink = makeEl(nav, "a", { href: "/x" }, "Nav");
    const bodyLink = makeEl(document.body, "a", { href: "/y" }, "Body");
    stubRect(navLink);
    stubRect(bodyLink);
    const out = collectVisibleElements([navLink, bodyLink], "/");
    expect(out.map((x) => x.text)).toEqual(["Nav", "Body"]);
  });
});

describe("installVisibleElementsReporter", () => {
  type IOEntry = { target: Element; isIntersecting: boolean };
  type IOCallback = (entries: IOEntry[]) => void;
  let observed: Element[] = [];
  let lastCallback: IOCallback | undefined;

  beforeAll(() => {
    class FakeIntersectionObserver {
      constructor(cb: IOCallback) { lastCallback = cb; }
      observe(el: Element): void { observed.push(el); }
      unobserve(_el: Element): void { /* no-op */ }
      disconnect(): void { /* no-op */ }
      takeRecords(): IOEntry[] { return []; }
    }
    (globalThis as unknown as { IntersectionObserver: unknown }).IntersectionObserver =
      FakeIntersectionObserver;
  });

  beforeEach(() => {
    observed = [];
    lastCallback = undefined;
    // The reporter's install flag lives on `window` for production idempotence; reset it
    // here so each test exercises a fresh install. Idempotence itself is asserted below.
    delete (window as unknown as Record<string, unknown>).__anglesiteVisibleElementsInstalled;
  });

  it("observes priority-category elements at install time", () => {
    makeEl(document.body, "h1", {}, "Title");
    makeEl(document.body, "img", { src: "/x.png" });
    makeEl(document.body, "div", {}, "skip me");
    installVisibleElementsReporter();
    expect(observed.map((e) => e.tagName).sort()).toEqual(["H1", "IMG"]);
  });

  it("posts a report when elements become visible", () => {
    const h1 = makeEl(document.body, "h1", {}, "Title");
    stubRect(h1);
    installVisibleElementsReporter();
    lastCallback?.([{ target: h1, isIntersecting: true }]);
    // Initial scan is sync; debounced triggers aren't tested here.
    const reports = sent.filter(
      (m): m is VisibleElementReport =>
        typeof m === "object" && m !== null && (m as { type?: string }).type === "anglesite:visible-elements",
    );
    expect(reports.length).toBeGreaterThanOrEqual(1);
    expect(reports[0]!.elements[0]!.tag).toBe("H1");
  });

  it("does not post when no elements are visible", () => {
    makeEl(document.body, "h1", {}, "Title");
    installVisibleElementsReporter();
    // No callback fired -> nothing visible.
    const reports = sent.filter(
      (m): m is { type: string } =>
        typeof m === "object" && m !== null && (m as { type?: string }).type === "anglesite:visible-elements",
    );
    expect(reports).toEqual([]);
  });

  it("is idempotent: calling install twice does not double-observe", () => {
    makeEl(document.body, "h1", {}, "Title");
    installVisibleElementsReporter();
    const after1 = observed.length;
    installVisibleElementsReporter();
    expect(observed.length).toBe(after1);
  });

  it("dedupes identical reports — same visible set fires once", () => {
    const h1 = makeEl(document.body, "h1", {}, "Title");
    stubRect(h1);
    installVisibleElementsReporter();
    // Same element, two IO callbacks (e.g. the user scrolls but the visible set is stable).
    lastCallback?.([{ target: h1, isIntersecting: true }]);
    lastCallback?.([{ target: h1, isIntersecting: true }]);
    const reports = sent.filter(
      (m): m is VisibleElementReport =>
        typeof m === "object" && m !== null && (m as { type?: string }).type === "anglesite:visible-elements",
    );
    // First fire emits; second is a no-op because the id key matches.
    expect(reports.length).toBe(1);
  });

  it("emits a new report when the visible set changes", () => {
    const h1 = makeEl(document.body, "h1", {}, "A");
    const h2 = makeEl(document.body, "h2", {}, "B");
    stubRect(h1);
    stubRect(h2);
    installVisibleElementsReporter();
    lastCallback?.([{ target: h1, isIntersecting: true }]);
    lastCallback?.([{ target: h2, isIntersecting: true }]);
    const reports = sent.filter(
      (m): m is VisibleElementReport =>
        typeof m === "object" && m !== null && (m as { type?: string }).type === "anglesite:visible-elements",
    );
    // First report: just h1. Second: h1 + h2 — different id key, emits.
    expect(reports.length).toBe(2);
    expect(reports[1]!.elements.map((e) => e.tag).sort()).toEqual(["H1", "H2"]);
  });
});

describe("VisibleElement type contract", () => {
  it("permits all documented optional fields", () => {
    // Compile-only — fails the typecheck if the public surface drifts.
    const _r: VisibleElement = {
      id: "x",
      tag: "IMG",
      selector: { tag: "IMG", classes: [], nthChild: 1 },
      rect: { x: 0, y: 0, width: 1, height: 1 },
      text: "alt text fallback",
      src: "/a.png",
      alt: "alt",
      ariaLabel: "label",
      role: "img",
      pagePath: "/",
    };
    expect(_r.tag).toBe("IMG");
  });
});
