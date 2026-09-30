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
 *
 * Keystatic edits git-backed content, which an EmDash site has none of, so it is left out.
 */
import { fileURLToPath } from "node:url";
import { defineConfig } from "astro/config";
import type { AstroIntegration, AstroUserConfig } from "astro";
import cloudflare from "@astrojs/cloudflare";
import react from "@astrojs/react";
import emdash from "emdash/astro";
import { d1, r2 } from "@emdash-cms/cloudflare";
import anglesiteBuildManifest from "./scripts/anglesite-build-manifest.ts";
import templateConfig from "./astro.anglesite.config.ts";

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

/** The template's own integrations, flattened, minus the git-backed content editor. */
const templateIntegrations = [anglesite.integrations ?? []]
  .flat(2)
  .filter((i): i is AstroIntegration => Boolean(i) && !GIT_CONTENT_ONLY.has((i as AstroIntegration).name));

// Typed up front: passing the spread straight to `defineConfig` makes it infer its locale
// generics from the template's config and reject the result.
const config: AstroUserConfig = {
  ...anglesite,
  adapter: cloudflare(),
  integrations: [
    ...templateIntegrations,
    react(),
    emdash({
      database: d1({ binding: EMDASH_BINDINGS.database }),
      storage: r2({ binding: EMDASH_BINDINGS.media }),
      plugins: [anglesiteGate],
    }),
    anglesiteBuildManifest(),
  ],
};

export default defineConfig(config);
