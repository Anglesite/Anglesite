import { fileURLToPath } from "node:url";
import type { AstroIntegration } from "astro";
import { editorWriteReloadGuard } from "./editor-write-reload.ts";

/**
 * Copies each element's `data-astro-source-file`/`-loc` into a page-global map
 * (`window.__anglesiteSourceAnnotations`) on `DOMContentLoaded`, for the block
 * editor to find blocks by (#2239). Astro's dev toolbar removes both
 * attributes from the DOM in its own `DOMContentLoaded` handler (its Audit app),
 * and Astro only emits them while the toolbar is enabled, so turning the
 * toolbar off isn't an option. This runs inline in `<head>`, so its listener is
 * registered before the toolbar's module script adds its own, and listeners
 * run in registration order. Plain ES2015 and self-contained: it's inserted
 * verbatim, unprocessed by Vite.
 */
export const SOURCE_ANNOTATION_CAPTURE = `(() => {
  const map = window.__anglesiteSourceAnnotations || (window.__anglesiteSourceAnnotations = new WeakMap());
  document.addEventListener("DOMContentLoaded", () => {
    for (const el of document.querySelectorAll("[data-astro-source-file][data-astro-source-loc]")) {
      map.set(el, { file: el.getAttribute("data-astro-source-file"), loc: el.getAttribute("data-astro-source-loc") });
    }
  }, { once: true });
})();`;

/**
 * Dev-only Anglesite hooks: the Component Editor's component harness
 * (/_anglesite/component/[...name]), the block editor's reload guard
 * (`editor-write-reload.ts`) and its source-annotation capture (above).
 * Nothing in builds, so deployed sites carry no trace of any of them.
 * Registered here, not in astro.config.ts, because this file is app-owned and
 * reaches existing sites on their next open.
 */
export default function anglesiteHarness(): AstroIntegration {
  return {
    name: "anglesite-harness",
    hooks: {
      "astro:config:setup": ({ command, injectRoute, injectScript, updateConfig }) => {
        if (command !== "dev") return;
        updateConfig({ vite: { plugins: [editorWriteReloadGuard()] } });
        injectScript("head-inline", SOURCE_ANNOTATION_CAPTURE);
        injectRoute({
          pattern: "/_anglesite/component/[...name]",
          entrypoint: fileURLToPath(new URL("./harness/component.astro", import.meta.url)),
          prerender: false,
        });
      },
    },
  };
}
