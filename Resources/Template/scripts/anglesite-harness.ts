import { fileURLToPath } from "node:url";
import type { AstroIntegration } from "astro";
import { editorWriteReloadGuard } from "./editor-write-reload.ts";

/**
 * Dev-only Anglesite hooks: the Component Editor's component harness
 * (/_anglesite/component/[...name]) and the block editor's reload guard
 * (`editor-write-reload.ts`). Nothing in builds, so deployed sites carry no
 * trace of either. Registered here, not in astro.config.ts, because this file
 * is app-owned and reaches existing sites on their next open.
 */
export default function anglesiteHarness(): AstroIntegration {
  return {
    name: "anglesite-harness",
    hooks: {
      "astro:config:setup": ({ command, injectRoute, updateConfig }) => {
        if (command !== "dev") return;
        updateConfig({ vite: { plugins: [editorWriteReloadGuard()] } });
        injectRoute({
          pattern: "/_anglesite/component/[...name]",
          entrypoint: fileURLToPath(new URL("./harness/component.astro", import.meta.url)),
          prerender: false,
        });
      },
    },
  };
}
