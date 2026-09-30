/**
 * The build manifest for a server-rendered (EmDash) site — #2055 slice 2, the deploy layer of the
 * re-scoped D5 gate (docs/specs/2026-09-28-external-cms-content-source-decision.md § Gate).
 *
 * A static site's gate reads everything it needs from `dist/`. A server-rendered site's articles
 * never exist at deploy time, and its server bundle is minified code, so `pre-deploy-check.ts`
 * needs two facts it can't read back out of the output by itself:
 *
 * - **Which gate sources went into the server bundle, and what they were.** The publish gate
 *   (`anglesite-gate`) must be compiled from the site's own pinned copies of
 *   `scripts/gate-checks.ts` and `scripts/emdash-gate/`. This records every such module the
 *   server bundle contains, with the SHA-256 of the file as it was built.
 * - **Which public scripts are entirely a dependency's code.** EmDash's admin UI ships as chunks
 *   under `_astro/` carrying placeholder addresses and numeric constants. A chunk whose every
 *   module comes from `node_modules/` (or is one of EmDash's own generated `virtual:emdash/`
 *   modules) is listed, so the deploy scan treats it like Pagefind's vendored files.
 *
 * Written to `dist/anglesite-build.json`, beside `dist/client/` and `dist/server/` and never
 * inside either, so it is neither served nor uploaded with the Worker. It lives under `scripts/`,
 * so the D5 hash pin covers it; the overlay's `astro.config.ts` registers it, and the deploy scan
 * refuses a server build without it.
 */
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";

/** The manifest's path, relative to the site root. */
export const BUILD_MANIFEST_PATH = "dist/anglesite-build.json";

/** The gate sources a server bundle must contain, relative to the site root. */
export const REQUIRED_GATE_MODULES = [
  "scripts/gate-checks.ts",
  "scripts/emdash-gate/policy.ts",
  "scripts/emdash-gate/plugin.ts",
] as const;

export interface BuildManifest {
  version: 1;
  /** SHA-256 (hex) of each gate source compiled into the server bundle, keyed by site-relative path. */
  gateModules: Record<string, string>;
  /** Public chunk paths (relative to the public root, e.g. `_astro/lib.abc.js`) that are wholly dependency code. */
  vendoredClientChunks: string[];
}

/** Module ids a dependency generates rather than the site owner writing them. */
const VENDOR_VIRTUAL_PREFIX = "\0virtual:emdash/";

/** True when every module in the chunk is dependency code. */
export function isVendoredChunk(moduleIds: string[]): boolean {
  return moduleIds.length > 0 && moduleIds.every((id) => id.includes("/node_modules/") || id.startsWith(VENDOR_VIRTUAL_PREFIX));
}

/** The site-relative gate paths among a chunk's module ids. */
export function gateModulesIn(moduleIds: string[], root: string): string[] {
  const required = new Set<string>(REQUIRED_GATE_MODULES);
  return moduleIds
    .filter((id) => !id.startsWith("\0"))
    .map((id) => relative(root, id.split("?")[0]).replace(/\\/g, "/"))
    .filter((path) => required.has(path) || path.startsWith("scripts/emdash-gate/"));
}

export function sha256(content: string | Buffer): string {
  return createHash("sha256").update(content).digest("hex");
}

interface Chunk { type: string; moduleIds?: string[] }

/** The Astro integration. */
export default function anglesiteBuildManifest() {
  let root = process.cwd();
  const gateModules = new Set<string>();
  const vendoredClientChunks = new Set<string>();
  return {
    name: "anglesite-build-manifest",
    hooks: {
      "astro:config:setup": ({ config, updateConfig }: { config: { root: URL }; updateConfig: (c: object) => void }) => {
        root = fileURLToPath(config.root);
        updateConfig({
          vite: {
            plugins: [{
              name: "anglesite-build-manifest",
              generateBundle(this: { environment?: { name?: string } }, _options: unknown, bundle: Record<string, Chunk>) {
                const environment = this.environment?.name;
                for (const [fileName, chunk] of Object.entries(bundle)) {
                  if (chunk.type !== "chunk") continue;
                  const ids = chunk.moduleIds ?? [];
                  if (environment === "client" && isVendoredChunk(ids)) vendoredClientChunks.add(fileName);
                  if (environment === "ssr") for (const path of gateModulesIn(ids, root)) gateModules.add(path);
                }
              },
            }],
          },
        });
      },
      "astro:build:done": () => {
        const manifest: BuildManifest = {
          version: 1,
          gateModules: Object.fromEntries(
            [...gateModules].sort().map((path) => [path, sha256(readFileSync(join(root, path)))]),
          ),
          vendoredClientChunks: [...vendoredClientChunks].sort(),
        };
        writeFileSync(join(root, BUILD_MANIFEST_PATH), JSON.stringify(manifest, null, 2) + "\n");
      },
    },
  };
}
