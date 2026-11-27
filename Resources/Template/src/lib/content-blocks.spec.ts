import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { experimental_AstroContainer as AstroContainer } from "astro/container";
import { validateMarkupHtml } from "../../scripts/markup-validate";
import { validateHtml } from "../../scripts/a11y-validate";

// First-party content blocks (#2219): plain-HTML components the block editor inserts from
// blocks.manifest.json. These tests hold each one to the manifest entry that registers it, and
// render it through the same markup and accessibility validators the build runs on dist/.

interface ManifestModule {
  path: string;
  export: string;
  kind: string;
  name: string;
  propEditors: { prop: string; editor: string; options?: string[] }[];
  slots: string[];
}

const manifest = JSON.parse(readFileSync("blocks.manifest.json", "utf8")) as { modules: ManifestModule[] };

const BLOCKS = ["Callout", "Accordion", "Steps"] as const;
type Block = (typeof BLOCKS)[number];

const source = (block: Block) => readFileSync(`src/components/${block}.astro`, "utf8");

async function render(block: Block, props: Record<string, unknown>, body: string): Promise<string> {
  const container = await AstroContainer.create();
  const mod = await import(/* @vite-ignore */ `../components/${block}.astro`);
  return container.renderToString(mod.default, { props, slots: { default: body } });
}

/** The markup and accessibility findings for `html` placed in a minimal valid page. */
function findings(html: string): string[] {
  const page = `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>Blocks</title></head><body><main><h1>Blocks</h1>${html}</main></body></html>`;
  return [...validateMarkupHtml(page, "block"), ...validateHtml(page).map((issue) => issue.message)];
}

describe("content blocks: manifest registration", () => {
  for (const block of BLOCKS) {
    describe(block, () => {
      const module = manifest.modules.find((m) => m.path === `src/components/${block}.astro`);

      it("has a blocks.manifest.json module named and exported as the component", () => {
        expect(module, `${block} missing from blocks.manifest.json`).toBeDefined();
        expect(module?.export).toBe(block);
        expect(module?.name).toBe(block);
        expect(module?.kind).toBe("astro");
        expect(module?.slots).toEqual(["default"]);
        expect(source(block)).toContain("<slot />");
      });

      it("only offers editors for props the component declares", () => {
        const props = source(block).match(/interface Props \{([\s\S]*?)\n\}/)?.[1] ?? "";
        for (const editor of module?.propEditors ?? []) {
          expect(props, `${block}.${editor.prop}`).toMatch(new RegExp(`\\b${editor.prop}\\??:`));
        }
      });

      it("ships no JavaScript", () => {
        expect(source(block)).not.toContain("<script");
      });
    });
  }

  it("Callout's variant editor offers exactly the variants the component knows", () => {
    const options = manifest.modules.find((m) => m.name === "Callout")?.propEditors.find((e) => e.prop === "variant")?.options;
    const union = source("Callout").match(/type CalloutVariant = ([^;]+);/)?.[1].match(/"([a-z]+)"/g)?.map((v) => v.slice(1, -1));
    expect(options).toEqual(union);
  });
});

describe("Callout", () => {
  it("is a note labelled with its variant, holding the slotted text", async () => {
    for (const [variant, label] of [["note", "Note"], ["tip", "Tip"], ["warning", "Warning"], ["danger", "Danger"]]) {
      const html = await render("Callout", { variant }, "<p>Check the oven.</p>");
      expect(html).toContain('role="note"');
      expect(html).toContain(`callout--${variant}`);
      expect(html).toMatch(new RegExp(`class="callout-title"[^>]*>${label}</p>`));
      expect(html).toContain("<p>Check the oven.</p>");
      expect(findings(html), variant).toEqual([]);
    }
  });

  it("uses a given title, and treats an unknown variant as a note", async () => {
    const titled = await render("Callout", { variant: "tip", title: "Before you start" }, "x");
    expect(titled).toMatch(/class="callout-title"[^>]*>Before you start<\/p>/);
    const unknown = await render("Callout", { variant: "warn" }, "x");
    expect(unknown).toContain("callout--note");
    expect(unknown).toMatch(/class="callout-title"[^>]*>Note<\/p>/);
  });
});

describe("Accordion", () => {
  it("is a native <details> with its summary, closed and ungrouped by default", async () => {
    const html = await render("Accordion", { summary: "Do you deliver?" }, "<p>Within 5 miles.</p>");
    expect(html).toMatch(/<details class="accordion[^"]*"[^>]*>\s*<summary[^>]*>Do you deliver\?<\/summary>/);
    expect(html).not.toMatch(/<details[^>]*\sopen/);
    expect(html).not.toMatch(/<details[^>]*\sname=/);
    expect(html).toContain("<p>Within 5 miles.</p>");
    expect(findings(html)).toEqual([]);
  });

  it("starts open, and joins a group through the name attribute", async () => {
    const html = await render("Accordion", { summary: "Hours", open: true, group: "faq" }, "9–5");
    expect(html).toMatch(/<details[^>]*\sopen/);
    expect(html).toMatch(/<details[^>]*\sname="faq"/);
    expect(findings(html)).toEqual([]);
  });
});

describe("Steps", () => {
  const items = "<li><p>Preheat the oven.</p></li><li><p>Mix the batter.</p></li>";

  it("is an ordered list that keeps its list role, holding the slotted steps", async () => {
    const html = await render("Steps", {}, items);
    expect(html).toMatch(/<ol class="steps[^"]*"[^>]*role="list"/);
    expect(html).not.toMatch(/<ol[^>]*\sstart=/);
    expect(html).toContain(items);
    expect(findings(html)).toEqual([]);
  });

  it("continues from a later number only when start is a whole number above 1", async () => {
    expect(await render("Steps", { start: 4 }, items)).toMatch(/<ol[^>]*\sstart="4"/);
    for (const start of [1, 0, -2, 2.5]) {
      expect(await render("Steps", { start }, items), String(start)).not.toMatch(/<ol[^>]*\sstart=/);
    }
  });
});
