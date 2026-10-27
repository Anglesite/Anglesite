/**
 * An EmDash site's Astro config (#2050). It is the template's own config
 * (`astro.anglesite.config.ts`, the template's `astro.config.ts` renamed when the site was
 * created) plus what server rendering against EmDash needs
 * (docs/specs/2026-09-28-external-cms-content-source-decision.md, decisions 4 and 7):
 *
 * - The Cloudflare adapter. Astro's default `output: "static"` is kept, so every page is still
 *   prerendered unless it opts out. Only the article routes (`src/pages/articles/`) and EmDash's
 *   own admin and API routes render on request, and the prerendered pages stay files the
 *   deploy gate scans.
 * - The EmDash integration, with its content in the site's D1 database (binding `DB`) and its
 *   media in R2 (binding `MEDIA`). Anglesite writes those bindings into the Worker config when
 *   it provisions or connects EmDash.
 * - `anglesite-gate`, registered here in code rather than installed from EmDash's admin, so an
 *   EmDash administrator can't remove it; removing it is a code change the deploy gate refuses.
 *   It runs in-process from its pinned source (`scripts/emdash-gate/`), so the code the D5 hash
 *   pin covers is exactly the code that runs. EmDash still enforces its declared capabilities.
 *
 * - `anglesite-build-manifest` (pinned, under `scripts/`), which records the gate sources the
 *   server bundle was built from. The deploy gate refuses a server build without it.
 * - EmDash's sandbox runner, for marketplace plugins, when the Worker has a `LOADER` binding.
 * - Cloudflare's route-cache provider, only when the Worker config Anglesite stages beside this
 *   file turns Workers Caching on (`src/lib/worker-cache.ts`, #2116). EmDash then purges cached
 *   pages on every publish; without it nothing is cached.
 *
 * Keystatic edits git-backed content, which an EmDash site has none of, so it is left out.
 */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { defineConfig } from "astro/config";
import type { AstroIntegration, AstroUserConfig } from "astro";
import cloudflare from "@astrojs/cloudflare";
import { cacheCloudflare } from "@astrojs/cloudflare/cache";
import react from "@astrojs/react";
import emdash from "emdash/astro";
import { d1, r2, sandbox } from "@emdash-cms/cloudflare";
import anglesiteBuildManifest from "./scripts/anglesite-build-manifest.ts";
import templateConfig from "./astro.anglesite.config.ts";
import { workerCacheEnabled } from "./src/lib/worker-cache.ts";

const anglesite: AstroUserConfig = templateConfig;

/** Integrations the template adds only for its git-backed content editor. */
const GIT_CONTENT_ONLY = new Set(["@keystatic/astro", "@astrojs/react"]);

/** The Worker bindings EmDash reads. Provisioning writes the same names into the Worker config. */
export const EMDASH_BINDINGS = { database: "DB", media: "MEDIA" } as const;

/** `anglesite-gate`: the publish-time layer of the pre-deploy gate (ADR § Gate, layer 2). */
export const anglesiteGate = {
  id: "anglesite-gate",
  version: "0.1.0",
  format: "standard" as const,
  entrypoint: fileURLToPath(new URL("./scripts/emdash-gate/plugin.ts", import.meta.url)),
  capabilities: ["hooks.content-policy:register"],
  allowedHosts: [],
  storage: {},
  hooks: ["content:beforePublish", "content:beforeSchedule"],
};

/** The Worker config Anglesite stages before the build, or `undefined` (local development). */
function stagedWorkerConfig(): string | undefined {
  try {
    return readFileSync(new URL("./wrangler.toml", import.meta.url), "utf-8");
  } catch {
    return undefined;
  }
}

/** A file at the site root as text, or `undefined` when there is none. */
function siteFile(name: string): string | undefined {
  try {
    return readFileSync(new URL(`./${name}`, import.meta.url), "utf-8");
  } catch {
    return undefined;
  }
}

/**
 * The site files the template reads while rendering, captured into the server bundle (#2133).
 * Pages and feeds that render on request run in a Worker, which has no site files, so
 * `readConfig` (`.site-config`) and `readUTMCodes` (`utm-codes.json`) fall back to these. Vite
 * treats a `define` value as an expression, hence the string literal. The deploy gate scans the
 * server bundle, so a secret pasted into either file is refused like any other.
 *
 * The copy is taken when this config loads, so it is only a fallback: a dev server, and the
 * `astro build` prerender, still read the files themselves, and a Worker sees an edit after the
 * next build and deploy. Each module that reads a value declares its global (`declare const` in
 * `scripts/config.ts` and `src/lib/utm-codes.ts`), so `astro check` passes in the site too.
 */
function bundledSiteFiles(): Record<string, string> {
  const files = { __ANGLESITE_SITE_CONFIG__: siteFile(".site-config"), __ANGLESITE_UTM_CODES__: siteFile("utm-codes.json") };
  return Object.fromEntries(
    Object.entries(files).map(([name, text]) => [name, text === undefined ? "undefined" : JSON.stringify(text)]),
  );
}

/** The template's own integrations, flattened, minus the git-backed content editor. */
const templateIntegrations = [anglesite.integrations ?? []]
  .flat(2)
  .filter((i): i is AstroIntegration => Boolean(i) && !GIT_CONTENT_ONLY.has((i as AstroIntegration).name));

// Typed up front: passing the spread straight to `defineConfig` makes it infer its locale
// generics from the template's config and reject the result.
const config: AstroUserConfig = {
  ...anglesite,
  adapter: cloudflare(),
  vite: { ...anglesite.vite, define: { ...anglesite.vite?.define, ...bundledSiteFiles() } },
  ...(workerCacheEnabled(stagedWorkerConfig()) ? { cache: { provider: cacheCloudflare() } } : {}),
  integrations: [
    ...templateIntegrations,
    react(),
    emdash({
      database: d1({ binding: EMDASH_BINDINGS.database }),
      storage: r2({ binding: EMDASH_BINDINGS.media }),
      plugins: [anglesiteGate],
      // Marketplace plugins run sandboxed, in their own isolates, when the Worker config has a
      // `LOADER` Worker Loader binding (a paid-plan feature); `sandbox()` returns nothing without
      // one, and they stay off. Plugins in `plugins` above always run in-process, so
      // `anglesite-gate` is never sandboxed. Anglesite writes `LOADER` for a connected install
      // that already had it (#2106).
      sandboxRunner: sandbox(),
    }),
    anglesiteBuildManifest(),
  ],
};

export default defineConfig(config);
