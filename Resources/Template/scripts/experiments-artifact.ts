#!/usr/bin/env npx tsx
/**
 * Build-time generator for `worker/experiments.json` (#1270 slice 1): the single running
 * experiment's runtime-relevant config, derived from `anglesite.json`'s `experiments.active`
 * list. Gitignored, derived, never hand-edited — regenerated at `prebuild` (and before
 * `npm run test:worker`, via the `pretest:worker` script) the same way `scripts/edge-artifacts.ts`
 * regenerates `public/.well-known/*`. `worker/worker.ts` statically imports the written file, so
 * it must exist before that file is bundled by Astro/Wrangler/Vitest — every entry point above
 * runs this first for exactly that reason.
 */
import { mkdirSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { readAnglesiteConfig, type AnglesiteConfig, type AnglesiteExperiment } from "./anglesite-config.ts";
import type { ExperimentsArtifact, RunningExperiment } from "../worker/experiments.ts";

/** Picks the one "running" experiment (v1: one at a time) out of `active`, or `null`. Multiple
 *  running entries would be a `checkExperiments` gate failure before deploy — this generator
 *  stays defensive rather than throwing, so a mid-edit config still produces a buildable (if
 *  soon-to-be-gate-rejected) artifact. */
export function buildExperimentsArtifact(config: AnglesiteConfig): ExperimentsArtifact {
  const active = config.experiments?.active ?? [];
  const running = active.find((experiment) => experiment.status === "running");
  return { experiment: running ? toRunningExperiment(running) : null };
}

function toRunningExperiment(experiment: AnglesiteExperiment): RunningExperiment {
  return {
    id: experiment.id,
    page: experiment.page,
    variant: { id: experiment.variant.id, page: experiment.variant.page },
    split: experiment.split,
    goal: {
      kind: experiment.goal.kind,
      ...(experiment.goal.path !== undefined ? { path: experiment.goal.path } : {}),
      ...(experiment.goal.depth !== undefined ? { depth: experiment.goal.depth } : {}),
      ...(experiment.goal.selector !== undefined ? { selector: experiment.goal.selector } : {}),
    },
  };
}

function writeExperimentsArtifact(siteRoot: string): void {
  const artifact = buildExperimentsArtifact(readAnglesiteConfig(siteRoot));
  const outDir = resolve(siteRoot, "worker");
  mkdirSync(outDir, { recursive: true });
  writeFileSync(resolve(outDir, "experiments.json"), JSON.stringify(artifact, null, 2) + "\n", "utf-8");
}

function main(): void {
  writeExperimentsArtifact(process.cwd());
  console.log("Wrote worker/experiments.json");
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main();
}
