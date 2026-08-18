import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { experimental_AstroContainer as AstroContainer } from "astro/container";
import { loadEffectsCatalog } from "../../scripts/effects-catalog";

const SLICE_COMPONENTS = ["ParallaxLayers", "RevealMask", "ScrollProgressTrace"];
const catalog = loadEffectsCatalog();
const entries = catalog.components.filter((entry) => SLICE_COMPONENTS.includes(entry.component));

describe("effects library (scroll-driven)", () => {
  it("has exactly the three scroll-driven entries", () => {
    expect(entries.map((entry) => entry.component).sort()).toEqual([...SLICE_COMPONENTS].sort());
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

  it("no component uses is:inline with a literal script body (CSP: script-src 'self')", () => {
    for (const entry of entries) {
      const source = readFileSync(`src/components/effects/${entry.component}.astro`, "utf8");
      expect(source, entry.component).not.toMatch(/<script[^>]*\bis:inline\b/);
    }
  });

  for (const entry of entries) {
    describe(entry.component, () => {
      it("renders and is gated by IntersectionObserver + prefers-reduced-motion", async () => {
        const container = await AstroContainer.create();
        const mod = await import(/* @vite-ignore */ `../components/effects/${entry.component}.astro`);
        const html = await container.renderToString(mod.default, {
          props: entry.props,
          slots: { default: `${entry.title} demo` },
        });
        expect(html.length).toBeGreaterThan(0);
        const source = readFileSync(`src/components/effects/${entry.component}.astro`, "utf8");
        expect(source, entry.component).toContain("prefers-reduced-motion");
        expect(source, entry.component).toContain("IntersectionObserver");
      });

      it("demo snapshot is fresh", async () => {
        const container = await AstroContainer.create();
        const mod = await import(/* @vite-ignore */ `../components/effects/${entry.component}.astro`);
        const inner = await container.renderToString(mod.default, {
          props: entry.props,
          slots: { default: `${entry.title} demo` },
        });
        // AstroContainer#renderToString only returns the component's own markup — it does not
        // bundle the component's scoped <style> block (that extraction is normally a
        // Vite/build-time asset step the container API doesn't run), so pull the raw CSS
        // straight from the component source instead. It also renders each component's
        // non-inline <script> as a module reference pointing at the *absolute filesystem path*
        // of the .astro source (`<script type="module" src="/Users/.../Foo.astro?astro&...">`),
        // which is real for the machine that ran the container but not portable — a fresh
        // checkout on another machine (or CI) resolves to a different absolute path, making the
        // snapshot spuriously mismatch. Strip that reference entirely: it wouldn't execute in a
        // static demo page anyway (no dev server to serve the `?astro&type=script` transform),
        // so the demo is a static, non-interactive preview of the component's markup and
        // styling, matching the existing legacy `effects-catalog.spec.ts` demos.
        const componentSource = readFileSync(`src/components/effects/${entry.component}.astro`, "utf8");
        const componentCss = [...componentSource.matchAll(/<style[^>]*>([\s\S]*?)<\/style>/g)]
          .map((match) => match[1])
          .join("\n");
        let innerWithoutScriptRefs = inner;
        for (let previous = ""; previous !== innerWithoutScriptRefs; ) {
          previous = innerWithoutScriptRefs;
          innerWithoutScriptRefs = innerWithoutScriptRefs.replace(/<script\b[^>]*>[\s\S]*?<\/script\b[^>]*>/gi, "");
        }
        const page = [
          "<!doctype html>",
          `<html lang="en"><head><meta charset="utf-8"><title>${entry.title}</title>`,
          "<style>body{margin:0;display:grid;place-items:center;min-height:100vh;",
          "font-family:-apple-system,system-ui,sans-serif;background:Canvas;color:CanvasText;color-scheme:light dark}</style>",
          `<style>${componentCss}</style>`,
          "</head><body>",
          innerWithoutScriptRefs,
          "</body></html>",
          "",
        ]
          .join("\n")
          .replace(/\r\n/g, "\n");
        await expect(page).toMatchFileSnapshot(`../../integrations/effects-demos/${entry.component}.html`);
      });
    });
  }
});
