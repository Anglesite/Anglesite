import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import ts from "typescript";
import { experimental_AstroContainer as AstroContainer } from "astro/container";
import { loadEffectsCatalog, placeableEntries } from "../../scripts/effects-catalog";

const catalog = loadEffectsCatalog();
const entries = placeableEntries(catalog);
const NO_SCRIPT_CATEGORIES = new Set(["generativeArt"]);

describe("effects library (new, placeable components)", () => {
  it("has exactly 12 placeable entries", () => {
    expect(entries.length).toBe(12);
  });

  it("every placeable entry has a matching blocks.manifest.json module", () => {
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

  it("generative-art components never emit a <script> tag", () => {
    for (const entry of entries.filter((e) => e.category === "generativeArt")) {
      const source = readFileSync(`src/components/effects/${entry.component}.astro`, "utf8");
      expect(source, entry.component).not.toContain("<script");
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
      it("renders and, when animated, guards reduced motion", async () => {
        const container = await AstroContainer.create();
        const mod = await import(/* @vite-ignore */ `../components/effects/${entry.component}.astro`);
        const html = await container.renderToString(mod.default, { props: entry.props });
        expect(html.length).toBeGreaterThan(0);
        const source = readFileSync(`src/components/effects/${entry.component}.astro`, "utf8");
        if (!NO_SCRIPT_CATEGORIES.has(entry.category)) {
          expect(source, entry.component).toContain("prefers-reduced-motion");
        } else {
          expect(source, entry.component).toContain("@media (prefers-reduced-motion: reduce)");
        }
      });

      it("demo snapshot is fresh", async () => {
        const container = await AstroContainer.create();
        const mod = await import(/* @vite-ignore */ `../components/effects/${entry.component}.astro`);
        const inner = await container.renderToString(mod.default, { props: entry.props });
        const source = readFileSync(`src/components/effects/${entry.component}.astro`, "utf8");
        const css = [...source.matchAll(/<style[^>]*>([\s\S]*?)<\/style>/g)].map((m) => m[1]).join("\n");
        // Astro's own <script> blocks are authored in TypeScript (generics, `as` casts,
        // parameter types) — Astro's real build pipeline strips that via esbuild before it
        // ever reaches a browser. Pulling the raw source text verbatim (as the container CSS
        // extraction above does for <style>) would embed TS-only syntax — e.g.
        // `querySelectorAll<HTMLElement>(...)` — directly into a plain, non-module <script>
        // tag, which is a SyntaxError at runtime. Transpile it the same way Astro does so the
        // standalone demo file's script actually runs.
        const scriptBlocks = [...source.matchAll(/<script(?![^>]*is:inline)[^>]*>([\s\S]*?)<\/script>/g)]
          .map((m) =>
            ts.transpileModule(m[1], {
              compilerOptions: { module: ts.ModuleKind.None, target: ts.ScriptTarget.ES2020 },
            }).outputText,
          )
          .join("\n");
        // AstroContainer#renderToString hoists a component's client <script> into a
        // `<script type="module" src="…?astro&type=script…">` reference pointing at the
        // absolute filesystem path of the .astro file on *this* machine (dev-server
        // module resolution). That reference is neither portable across checkouts nor
        // runnable in a static demo file, and it duplicates the actual script body we
        // already spliced in above from the raw source — strip it.
        const innerWithoutHoistedScriptRef = inner.replace(
          /<script type="module" src="[^"]*\?astro&type=script[^"]*"><\/script>/g,
          "",
        );
        const page = [
          "<!doctype html>",
          `<html lang="en"><head><meta charset="utf-8"><title>${entry.title}</title>`,
          "<style>body{margin:0;position:relative;min-height:100vh;display:grid;place-items:center;",
          "font-family:-apple-system,system-ui,sans-serif;background:Canvas;color:CanvasText;color-scheme:light dark}</style>",
          `<style>${css}</style>`,
          "</head><body>",
          innerWithoutHoistedScriptRef,
          scriptBlocks ? `<script>${scriptBlocks}</script>` : "",
          "</body></html>",
          "",
        ].join("\n").replace(/\r\n/g, "\n");
        await expect(page).toMatchFileSnapshot(`../../integrations/effects-demos/${entry.component}.html`);
      });
    });
  }

  it("every placeable component is documented", () => {
    const docs = readFileSync("integrations/docs/effects.md", "utf8");
    for (const entry of entries) {
      expect(docs, entry.component).toContain(`## ${entry.component}`);
    }
  });
});
