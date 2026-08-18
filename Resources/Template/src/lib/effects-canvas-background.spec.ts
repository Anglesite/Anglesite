import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { experimental_AstroContainer as AstroContainer } from "astro/container";
import { loadEffectsCatalog } from "../../scripts/effects-catalog";
import ParticleField from "../components/effects/ParticleField.astro";
import AuroraGradient from "../components/effects/AuroraGradient.astro";
import GrainOverlay from "../components/effects/GrainOverlay.astro";

// This slice's three components only. The other three effect categories (cursor-reactive,
// scroll-driven, generative-art) each ship their own per-slice spec, so this file stays green
// regardless of which slices have landed — a single shared spec asserting all 12 entries
// could not, and would collide between slices landing concurrently.
const COMPONENTS: Record<string, unknown> = {
  ParticleField,
  AuroraGradient,
  GrainOverlay,
};

const catalog = loadEffectsCatalog();
const entries = catalog.components.filter((entry) => entry.component in COMPONENTS);

describe("effects catalog (canvas backgrounds)", () => {
  it("catalogs all three canvas-background components", () => {
    expect(entries.map((entry) => entry.component).sort()).toEqual(
      Object.keys(COMPONENTS).sort(),
    );
  });

  it("declares every one as a placeable background layer", () => {
    for (const entry of entries) {
      expect(entry.category, entry.component).toBe("canvasBackground");
      expect(entry.placement?.kind, entry.component).toBe("background");
      expect(entry.placement?.allowedParents, entry.component).toBeNull();
    }
  });

  it("registers every one in blocks.manifest.json", () => {
    const manifest = JSON.parse(readFileSync("blocks.manifest.json", "utf8")) as {
      modules: { path: string; name: string }[];
    };
    for (const entry of entries) {
      const module = manifest.modules.find(
        (candidate) => candidate.path === `src/components/effects/${entry.component}.astro`,
      );
      expect(module, entry.component).toBeDefined();
      expect(module?.name, entry.component).toBe(entry.title);
    }
  });

  it("resolves ParticleField's currentColor default before it reaches the canvas", () => {
    // Canvas 2D silently ignores `currentColor` and keeps its default black, so the component
    // has to resolve the keyword itself for the catalog's documented default to mean anything.
    const source = readFileSync("src/components/effects/ParticleField.astro", "utf8");
    expect(source).toContain("getComputedStyle(root).color");
  });

  for (const entry of entries) {
    describe(entry.component, () => {
      const source = readFileSync(
        `src/components/effects/${entry.component}.astro`,
        "utf8",
      );

      it("renders non-empty markup", async () => {
        const container = await AstroContainer.create();
        const html = await container.renderToString(
          COMPONENTS[entry.component] as Parameters<typeof container.renderToString>[0],
          { props: entry.props },
        );
        expect(html.length).toBeGreaterThan(0);
      });

      it("guards motion behind prefers-reduced-motion and IntersectionObserver", () => {
        expect(source).toContain("prefers-reduced-motion");
        expect(source).toContain("IntersectionObserver");
      });

      it("uses a plain <script>, never is:inline (CSP: script-src 'self')", () => {
        expect(source).not.toContain("is:inline");
      });

      it("demo snapshot is fresh", async () => {
        const container = await AstroContainer.create();
        const inner = await container.renderToString(
          COMPONENTS[entry.component] as Parameters<typeof container.renderToString>[0],
          { props: entry.props },
        );
        // Same shape as the legacy `effects-catalog.spec.ts` demos, and for the same reason:
        // AstroContainer#renderToString returns only the component's own markup, so the scoped
        // <style> block has to be lifted out of the source by hand for the demo to look right
        // offline in the gallery's WKWebView.
        const componentCss = [...source.matchAll(/<style[^>]*>([\s\S]*?)<\/style>/g)]
          .map((match) => match[1])
          .join("\n");
        // Drop the hoisted <script> reference the container emits. Two reasons, either one
        // sufficient: `EffectDemoWebView` documents demo pages as self-contained markup with
        // inline <style> only and no <script>, and the emitted src is an absolute
        // dev-server path into *this machine's* checkout, which would make the committed
        // snapshot unreproducible anywhere else. A canvas effect's demo is therefore a still
        // frame of its background layer, not a running animation.
        const markup = inner.replace(/<script\b[^>]*>[\s\S]*?<\/script>/g, "");
        const page = [
          "<!doctype html>",
          `<html lang="en"><head><meta charset="utf-8"><title>${entry.title}</title>`,
          "<style>body{margin:0;display:grid;place-items:center;min-height:100vh;",
          "font-family:-apple-system,system-ui,sans-serif;background:Canvas;color:CanvasText;color-scheme:light dark}</style>",
          // Canvas backgrounds position themselves `absolute; inset: 0; z-index: -1`, so the demo
          // needs the positioned ancestor every component's doc comment asks for — without it the
          // layer would size itself against the viewport instead of a card-shaped preview.
          "<style>.effect-demo-stage{position:relative;isolation:isolate;width:min(90vw,480px);height:min(60vh,300px)}</style>",
          `<style>${componentCss}</style>`,
          "</head><body>",
          '<div class="effect-demo-stage">',
          markup,
          "</div>",
          "</body></html>",
          "",
        ].join("\n").replace(/\r\n/g, "\n");
        expect(page).not.toContain("<script");
        await expect(page).toMatchFileSnapshot(
          `../../integrations/effects-demos/${entry.component}.html`,
        );
      });
    });
  }
});
