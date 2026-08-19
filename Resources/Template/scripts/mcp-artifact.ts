#!/usr/bin/env npx tsx
/**
 * Build-time generator for `worker/mcp-config.json` (#1576): the MCP feature's runtime-relevant
 * config, derived from `anglesite.json`'s `experimental.mcp` flag. Gitignored, derived, never
 * hand-edited — regenerated at `prebuild` (and before `npm run test:worker`, via the
 * `pretest:worker` script) the same way `scripts/experiments-artifact.ts` regenerates
 * `worker/experiments.json`. `worker/mcp-server.ts` statically imports the written file, so it
 * must exist before that file is bundled by Astro/Wrangler/Vitest.
 */
import { mkdirSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { readAnglesiteConfig, type AnglesiteConfig } from "./anglesite-config.ts";
import { FEED_COLLECTIONS } from "../src/lib/feeds.ts";
import type { McpConfigArtifact } from "../worker/mcp-config.ts";

/** The static list of feed URLs this template unconditionally generates: three root-level
 *  formats (the site's primary feed, unprefixed) plus three formats per `FEED_COLLECTIONS`
 *  entry — matches the file layout under `src/pages/` byte-for-byte. */
export function buildFeedPaths(): string[] {
  const root = ["/rss.xml", "/atom.xml", "/feed.json"];
  const perCollection = Object.keys(FEED_COLLECTIONS).flatMap((collection) => [
    `/${collection}/rss.xml`,
    `/${collection}/atom.xml`,
    `/${collection}/feed.json`,
  ]);
  return [...root, ...perCollection];
}

export function buildMcpConfigArtifact(config: AnglesiteConfig): McpConfigArtifact {
  return {
    enabled: config.experimental?.mcp === true,
    feedPaths: buildFeedPaths(),
  };
}

function writeMcpConfigArtifact(siteRoot: string): void {
  const artifact = buildMcpConfigArtifact(readAnglesiteConfig(siteRoot));
  const outDir = resolve(siteRoot, "worker");
  mkdirSync(outDir, { recursive: true });
  writeFileSync(resolve(outDir, "mcp-config.json"), JSON.stringify(artifact, null, 2) + "\n", "utf-8");
}

function main(): void {
  writeMcpConfigArtifact(process.cwd());
  console.log("Wrote worker/mcp-config.json");
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main();
}
