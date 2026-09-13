// @vitest-environment jsdom
import { describe, it, expect, beforeEach } from "vitest";
import { elementInfoFor } from "../../src/host/element-info.js";

function $append<K extends keyof HTMLElementTagNameMap>(
  parent: Element,
  tag: K,
  opts: { id?: string; class?: string; text?: string; attrs?: Record<string, string> } = {},
): HTMLElementTagNameMap[K] {
  const el = document.createElement(tag);
  if (opts.id) el.id = opts.id;
  if (opts.class) el.className = opts.class;
  if (opts.text) el.textContent = opts.text;
  if (opts.attrs) for (const [k, v] of Object.entries(opts.attrs)) el.setAttribute(k, v);
  parent.appendChild(el);
  return el;
}

describe("elementInfoFor", () => {
  beforeEach(() => {
    while (document.body.firstChild) document.body.removeChild(document.body.firstChild);
  });

  it("captures tag, classes, nthChild, textContent, and ancestors for a leaf element", () => {
    const main = $append(document.body, "main");
    const section = $append(main, "section");
    $append(section, "h1", { text: "Skip" });
    const p = $append(section, "p", { text: "Hello, world." });

    const info = elementInfoFor(p);
    expect(info.tag).toBe("P");
    expect(info.classes).toEqual([]);
    expect(info.nthChild).toBe(2); // <h1> is first, <p> is second
    expect(info.textContent).toBe("Hello, world.");
    // ancestors ordered root-first so the plugin's buildSelector can join with `>` directly
    expect(info.ancestors?.map((a) => a.tag)).toEqual(["BODY", "MAIN", "SECTION"]);
  });

  it("captures id, classes (raw), role, ariaLabel, data-anglesite-id, and data-testid", () => {
    const el = $append(document.body, "div", {
      id: "hero",
      class: "card primary astro-abc123",
      attrs: {
        "data-anglesite-id": "home:hero",
        "data-testid": "hero-card",
        role: "region",
        "aria-label": "Hero section",
      },
    });
    const info = elementInfoFor(el);
    expect(info.id).toBe("hero");
    expect(info.classes).toEqual(["card", "primary", "astro-abc123"]); // overlay forwards raw; server filters astro-*
    expect(info.dataAnglesiteId).toBe("home:hero");
    expect(info.dataTestId).toBe("hero-card");
    expect(info.role).toBe("region");
    expect(info.ariaLabel).toBe("Hero section");
  });

  it("omits optional fields when not present", () => {
    const el = $append(document.body, "p");
    const info = elementInfoFor(el);
    expect(info.id).toBeUndefined();
    expect(info.dataAnglesiteId).toBeUndefined();
    expect(info.dataTestId).toBeUndefined();
    expect(info.role).toBeUndefined();
    expect(info.ariaLabel).toBeUndefined();
  });

  it("truncates very long textContent to 80 chars with an ellipsis", () => {
    const long = "x".repeat(200);
    const el = $append(document.body, "p", { text: long });
    const info = elementInfoFor(el);
    expect(info.textContent?.length).toBe(81);
    expect(info.textContent?.endsWith("…")).toBe(true);
  });

  it("collapses whitespace in textContent", () => {
    const el = $append(document.body, "p", { text: "  hello   \n  world  " });
    const info = elementInfoFor(el);
    expect(info.textContent).toBe("hello world");
  });

  it("returns an empty ancestors array for a detached element", () => {
    const detached = document.createElement("p");
    const info = elementInfoFor(detached);
    expect(info.ancestors).toEqual([]);
    expect(info.tag).toBe("P");
    expect(info.nthChild).toBe(1);
  });

  it("ancestors include id and stable selector-fragment fields", () => {
    const wrapper = $append(document.body, "section", { id: "intro", class: "lead" });
    const p = $append(wrapper, "p", { text: "hi" });
    const info = elementInfoFor(p);
    const intro = info.ancestors?.find((a) => a.id === "intro");
    expect(intro).toBeDefined();
    expect(intro?.tag).toBe("SECTION");
    expect(intro?.classes).toEqual(["lead"]);
    expect(intro?.nthChild).toBe(1);
  });
});
