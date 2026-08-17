import { existsSync, readdirSync, readFileSync, unlinkSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig } from "astro/config";
import { unified } from "@astrojs/markdown-remark";
import keystatic from "@keystatic/astro";
import react from "@astrojs/react";
import { readConfig } from "./scripts/config.ts";
import { readAnglesiteConfig } from "./scripts/anglesite-config.ts";
import anglesiteHarness from "./scripts/anglesite-harness.ts";
import redirects from "./scripts/redirects.ts";
import remarkEmbeds from "./scripts/remark-embeds.ts";
import co2Badge from "./scripts/co2-badge.ts";
import { isKeystaticDev } from "./scripts/keystatic-gate.ts";

// The deploy step writes the real domain into `.site-config` (SITE_URL=…) before build.
// Absent that, feeds carry a placeholder host — fine for a not-yet-deployed scaffold.
const site = readConfig("SITE_URL") ?? "https://example.com";

// Keystatic's /keystatic admin UI is dev-only (see scripts/keystatic-gate.ts, unit-tested):
// gated on the `astro dev` CLI subcommand via process.argv (Astro's own defineConfig doesn't
// support a function-form config in this version — see git history for why that approach was
// tried and reverted). This keeps production builds pure static output with no server adapter:
// `react()`/`keystatic()` are never registered outside `astro dev`, so `astro build` (with any
// --mode) never sees their routes at all.
const isDev = isKeystaticDev(process.argv);

// #1279: mirrors BaseLayout.astro's own read of the same flag — needed here too because
// webmcpChunkPrune (below) has to decide, at the end of every real build, whether to delete the
// webmcp tool script's compiled chunk.
const webmcpEnabled = readAnglesiteConfig(process.cwd()).experimental?.webmcp === true;

/**
 * #1279: Astro bundles every <script> it finds in a component's template regardless of a
 * surrounding runtime conditional — it can't know `webmcpEnabled`'s value at its own compile
 * step, so the webmcp tool script still gets written to dist/_astro/ even when no page's HTML
 * ever references it. This integration deletes that orphan chunk after the build when the
 * feature is off, so an opted-out site ships nothing at all, not just an unlinked file.
 */
function webmcpChunkPrune(enabled: boolean) {
  return {
    name: "webmcp-chunk-prune",
    hooks: {
      "astro:build:done": async ({ dir }: { dir: URL }) => {
        if (enabled) return;
        // Scoped to dist/_astro/ — where Astro actually places hoisted script chunks — rather
        // than the whole dist/ tree, so this can never touch an unrelated .js file an owner
        // placed under public/ that happens to contain the marker string.
        const astroDir = join(fileURLToPath(dir), "_astro");
        if (existsSync(astroDir)) pruneMarkedFiles(astroDir, "anglesite_search_posts");
      },
    },
  };
}

function pruneMarkedFiles(dirPath: string, marker: string): void {
  for (const entry of readdirSync(dirPath, { withFileTypes: true })) {
    const full = join(dirPath, entry.name);
    if (entry.isDirectory()) {
      pruneMarkedFiles(full, marker);
    } else if (entry.isFile() && full.endsWith(".js")) {
      const content = readFileSync(full, "utf-8");
      if (content.includes(marker)) unlinkSync(full);
    }
  }
}

export default defineConfig({
  site,
  integrations: [
    anglesiteHarness(),
    redirects(),
    co2Badge(),
    webmcpChunkPrune(webmcpEnabled),
    ...(isDev ? [react(), keystatic()] : []),
  ],
  // Astro 7's default markdown processor (Sätteri) no longer carries remark itself, so custom
  // remark plugins go through `unified()` from `@astrojs/markdown-remark`, an explicit
  // dependency (#682) — the top-level `markdown.remarkPlugins` shorthand is deprecated (#1079).
  markdown: {
    processor: unified({ remarkPlugins: [remarkEmbeds] }),
  },
  vite: {
    build: {
      // #1279: keep hoisted <script> chunks (Astro names them after their originating .astro
      // file, not the script's own filename — e.g. `BaseLayout.astro_astro_type_script_…js` for
      // the webmcp tool-registration script referenced from every page via BaseLayout) as
      // external, browser-cacheable files rather than letting Astro's default < 4KB inlining
      // duplicate their compiled output into every page's HTML. This isn't just a caching/
      // duplication nicety: the webmcp script chunk (~3.1KB) is *under* Astro's 4KB default
      // inline threshold, and this template's generated CSP (`script-src 'self'`, no
      // `'unsafe-inline'`, no hashes — see scripts/csp.ts) would silently block an inlined
      // `<script>` at runtime, with no build error and no test failure to catch it. Don't revert
      // this override as a stray perf tweak — it's load-bearing for CSP compliance. Matches on
      // the `_astro_type_script_` token Astro/Vite give every such chunk, so this doesn't regress
      // (or need updating) if a script's compiled size later drifts across the 4KB threshold, or
      // a future script is added elsewhere. Other small assets (images, etc.) keep Vite's
      // default inlining — this returns `undefined` for anything that isn't a script chunk.
      assetsInlineLimit: (filePath) => (filePath.includes("_astro_type_script_") ? false : undefined),
    },
  },
});
