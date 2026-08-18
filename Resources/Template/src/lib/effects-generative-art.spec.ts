import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { experimental_AstroContainer as AstroContainer } from "astro/container";
import { loadEffectsCatalog, placeableEntries } from "../../scripts/effects-catalog";

const catalog = loadEffectsCatalog();
const entries = placeableEntries(catalog).filter((e) => e.category === "generativeArt");

describe("effects library (generative art)", () => {
  it("has exactly 3 generative-art entries, all inline placement", () => {
    expect(entries.length).toBe(3);
    for (const entry of entries) {
      expect(entry.placement?.kind, entry.component).toBe("inline");
    }
  });

  it("every entry has a matching blocks.manifest.json module", () => {
    const manifest = JSON.parse(readFileSync("blocks.manifest.json", "utf8")) as {
      modules: { path: string; name: string }[];
    };
    for (const entry of entries) {
      const expectedPath = `src/components/effects/${entry.component}.astro`;
      const module = manifest.modules.find((m) => m.path === expectedPath);
      expect(module, `${entry.component} missing from blocks.manifest.json`).toBeDefined();
      expect(module?.name).toBe(entry.title);
    }
  });

  it("never emits a <script> tag", () => {
    for (const entry of entries) {
      const source = readFileSync(`src/components/effects/${entry.component}.astro`, "utf8");
      // Strip HTML comments first so comment prose mentioning the tag can't
      // trip this check (mirrors effects-catalog.spec.ts's approach), then
      // check the raw source for a literal opening tag.
      let sourceWithoutComments = source;
      for (let previous = ""; previous !== sourceWithoutComments; ) {
        previous = sourceWithoutComments;
        sourceWithoutComments = sourceWithoutComments.replace(/<!--[\s\S]*?-->/g, "");
      }
      expect(sourceWithoutComments, entry.component).not.toContain("<script");
    }
  });

  for (const entry of entries) {
    describe(entry.component, () => {
      it("renders and guards reduced motion", async () => {
        const container = await AstroContainer.create();
        const mod = await import(/* @vite-ignore */ `../components/effects/${entry.component}.astro`);
        const html = await container.renderToString(mod.default, { props: entry.props });
        expect(html.length).toBeGreaterThan(0);
        const source = readFileSync(`src/components/effects/${entry.component}.astro`, "utf8");
        expect(source, entry.component).toContain("@media (prefers-reduced-motion: reduce)");
      });

      it("demo snapshot is fresh", async () => {
        const container = await AstroContainer.create();
        const mod = await import(/* @vite-ignore */ `../components/effects/${entry.component}.astro`);
        const inner = await container.renderToString(mod.default, { props: entry.props });
        const source = readFileSync(`src/components/effects/${entry.component}.astro`, "utf8");
        const css = [...source.matchAll(/<style[^>]*>([\s\S]*?)<\/style>/g)].map((m) => m[1]).join("\n");
        const page = [
          "<!doctype html>",
          `<html lang="en"><head><meta charset="utf-8"><title>${entry.title}</title>`,
          "<style>body{margin:0;position:relative;min-height:100vh;display:grid;place-items:center;",
          "font-family:-apple-system,system-ui,sans-serif;background:Canvas;color:CanvasText;color-scheme:light dark}</style>",
          `<style>${css}</style>`,
          "</head><body>",
          inner,
          "</body></html>",
          "",
        ].join("\n").replace(/\r\n/g, "\n");
        await expect(page).toMatchFileSnapshot(`../../integrations/effects-demos/${entry.component}.html`);
      });
    });
  }
});
