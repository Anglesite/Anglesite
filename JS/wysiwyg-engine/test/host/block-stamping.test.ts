// @vitest-environment jsdom
import { describe, it, expect, beforeEach } from "vitest";
import { clearBlockIds, sameSourceFile, snapshotSourceAnnotations, stampBlockIds } from "../../src/host/block-stamping.js";
import { BLOCK_ID_ATTR } from "../../src/hit-test.js";
import type { BlockModel, BlockNode } from "../../src/types.js";

const PAGE = "/work/site/src/pages/index.astro";
const HERO = "/work/site/src/components/Hero.astro";
const LAYOUT = "/work/site/src/layouts/BaseLayout.astro";

function node(id: string, componentName: string, line: number, column: number, extra: Partial<BlockNode> = {}): BlockNode {
  return {
    id,
    kind: "element",
    componentName,
    props: {},
    slots: {},
    sourceSpan: [0, 0],
    sourceLoc: { line, column },
    ...extra,
  };
}

function model(nodes: BlockNode[]): BlockModel {
  return { path: "src/pages/index.astro", version: "v", rootIds: nodes.map((n) => n.id), blocks: Object.fromEntries(nodes.map((n) => [n.id, n])) };
}

/** `loc` is where the opening tag ENDS, the way `astro dev` stamps it. */
function el(tag: string, file: string, loc: string, inner = ""): string {
  return `<${tag} data-astro-source-file="${file}" data-astro-source-loc="${loc}">${inner}</${tag}>`;
}

const idOf = (selector: string) => document.querySelector(selector)?.getAttribute(BLOCK_ID_ATTR) ?? null;

describe("stampBlockIds (#2239)", () => {
  beforeEach(() => {
    clearBlockIds(document);
    document.body.innerHTML = "";
  });

  it("marks page elements by matching each block's start to the tag end that follows it", () => {
    // The template's index.astro, with the exact locs `astro dev` and the sidecar's page model
    // report for it. Note <p> at 13:5 reports 13:9, one column past its child <a>'s start (13:8).
    document.body.innerHTML = el(
      "section",
      PAGE,
      "10:25",
      el("h1", PAGE, "11:9", "Welcome") + el("p", PAGE, "12:8", "Ready") + el("p", PAGE, "13:9", el("a", PAGE, "13:25", "Blog")),
    );
    const blocks = [
      node("n2", "section", 10, 3, { slots: { default: ["n3", "n5", "n7"] } }),
      node("n3", "h1", 11, 5, { slots: { default: ["n4"] } }),
      node("n4", "", 11, 9, { kind: "text" }),
      node("n5", "p", 12, 5),
      node("n7", "p", 13, 5, { slots: { default: ["n8"] } }),
      node("n8", "a", 13, 8, { slots: { default: ["n9"] } }),
      node("n9", "", 13, 25, { kind: "text" }),
    ];

    const stamped = stampBlockIds(model(blocks), document);

    expect(stamped.sort()).toEqual(["n2", "n3", "n5", "n7", "n8"]);
    expect(idOf("section")).toBe("n2");
    expect(idOf("h1")).toBe("n3");
    expect(document.querySelectorAll("p")[0]?.getAttribute(BLOCK_ID_ATTR)).toBe("n5");
    expect(document.querySelectorAll("p")[1]?.getAttribute(BLOCK_ID_ATTR)).toBe("n7");
    expect(idOf("a")).toBe("n8");
  });

  it("leaves a block that didn't render unmarked instead of giving it its neighbour's element", () => {
    // Two <p>s in the source; the first sits in a false conditional and never rendered.
    document.body.innerHTML = el("p", PAGE, "6:8", "Second");
    const stamped = stampBlockIds(model([node("n1", "p", 5, 5), node("n2", "p", 6, 5)]), document);

    expect(stamped).toEqual(["n2"]);
    expect(idOf("p")).toBe("n2");
  });

  it("ignores elements from other files and requires the tag name to match", () => {
    document.body.innerHTML = el("header", LAYOUT, "3:9") + el("div", PAGE, "4:10");
    const stamped = stampBlockIds(model([node("n1", "header", 3, 1), node("n2", "section", 4, 5)]), document);

    expect(stamped).toEqual([]);
    expect(document.querySelectorAll(`[${BLOCK_ID_ATTR}]`)).toHaveLength(0);
  });

  it("pairs manifest component instances with the component's root elements, in order", () => {
    document.body.innerHTML =
      el("section", HERO, "1:10", el("h2", HERO, "2:8", "One")) + el("section", HERO, "1:10", el("h2", HERO, "2:8", "Two"));
    const hero = { componentPath: "src/components/Hero.astro" };
    const stamped = stampBlockIds(model([node("n9", "Hero", 20, 3, hero), node("n4", "Hero", 8, 3, hero)]), document);

    expect(stamped.sort()).toEqual(["n4", "n9"]);
    const sections = document.querySelectorAll("section");
    expect(sections[0]?.getAttribute(BLOCK_ID_ATTR)).toBe("n4");
    expect(sections[1]?.getAttribute(BLOCK_ID_ATTR)).toBe("n9");
    expect(idOf("h2")).toBeNull(); // only roots
  });

  it("leaves a component unmarked when its roots don't pair one-to-one with its uses", () => {
    // One use in the page, but the component also renders inside the layout.
    document.body.innerHTML = el("section", HERO, "1:10") + el("section", HERO, "1:10");
    const stamped = stampBlockIds(model([node("n4", "Hero", 8, 3, { componentPath: "src/components/Hero.astro" })]), document);
    expect(stamped).toEqual([]);
  });

  it("never touches a block id the page rendered itself", () => {
    document.body.innerHTML = `<p data-anglesite-block-id="fixture" data-astro-source-file="${PAGE}" data-astro-source-loc="5:8">x</p>`;
    expect(stampBlockIds(model([node("n1", "p", 5, 5)]), document)).toEqual([]);
    clearBlockIds(document);
    expect(idOf("p")).toBe("fixture");
  });

  it("still finds elements after Astro's dev toolbar strips their source attributes", () => {
    document.body.innerHTML = el("section", PAGE, "10:25", el("h1", PAGE, "11:9", "Welcome"));
    snapshotSourceAnnotations(document);
    // What the toolbar's Audit app does on DOMContentLoaded.
    for (const e of Array.from(document.querySelectorAll("[data-astro-source-file]"))) {
      e.removeAttribute("data-astro-source-file");
      e.removeAttribute("data-astro-source-loc");
    }

    const stamped = stampBlockIds(
      model([node("n2", "section", 10, 3, { slots: { default: ["n3"] } }), node("n3", "h1", 11, 5)]),
      document,
    );
    expect(stamped.sort()).toEqual(["n2", "n3"]);
  });

  it("re-stamping replaces its own earlier marks", () => {
    document.body.innerHTML = el("h1", PAGE, "11:9", "Welcome");
    stampBlockIds(model([node("old", "h1", 11, 5)]), document);
    stampBlockIds(model([node("new", "h1", 11, 5)]), document);
    expect(idOf("h1")).toBe("new");

    clearBlockIds(document);
    expect(idOf("h1")).toBeNull();
  });
});

describe("sameSourceFile", () => {
  it("matches Astro's absolute path against the page model's project-relative one", () => {
    expect(sameSourceFile("/work/site/src/pages/index.astro", "src/pages/index.astro")).toBe(true);
    expect(sameSourceFile("C:\\site\\src\\pages\\index.astro", "src/pages/index.astro")).toBe(true);
    expect(sameSourceFile("/work/site/src/pages/blog/index.astro", "src/pages/index.astro")).toBe(false);
    expect(sameSourceFile("/work/site/src/pages/myindex.astro", "src/pages/index.astro")).toBe(false);
  });
});
