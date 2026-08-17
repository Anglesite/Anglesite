import test from "node:test";
import assert from "node:assert/strict";
import { buildExperimentsArtifact } from "./experiments-artifact";
import type { AnglesiteConfig } from "./anglesite-config";

test("buildExperimentsArtifact: no experiments section returns null", () => {
  const config: AnglesiteConfig = { version: 1 };
  assert.deepEqual(buildExperimentsArtifact(config), { experiment: null });
});

test("buildExperimentsArtifact: only draft experiments returns null", () => {
  const config: AnglesiteConfig = {
    version: 1,
    experiments: {
      active: [
        {
          id: "homepage-hero",
          name: "Homepage headline",
          page: "/",
          variant: { id: "b", name: "Fresh eggs headline", page: "/x/homepage-hero/b/" },
          split: 0.5,
          goal: { kind: "pageview", path: "/contact/thanks/" },
          status: "draft",
        },
      ],
    },
  };
  assert.deepEqual(buildExperimentsArtifact(config), { experiment: null });
});

test("buildExperimentsArtifact: a running experiment is projected to its runtime shape", () => {
  const config: AnglesiteConfig = {
    version: 1,
    experiments: {
      active: [
        {
          id: "homepage-hero",
          name: "Homepage headline",
          page: "/",
          variant: { id: "b", name: "Fresh eggs headline", page: "/x/homepage-hero/b/" },
          split: 0.5,
          goal: { kind: "pageview", path: "/contact/thanks/" },
          status: "running",
          startedAt: "2026-08-16",
        },
      ],
    },
  };
  assert.deepEqual(buildExperimentsArtifact(config), {
    experiment: {
      id: "homepage-hero",
      page: "/",
      variant: { id: "b", page: "/x/homepage-hero/b/" },
      split: 0.5,
      goal: { kind: "pageview", path: "/contact/thanks/" },
    },
  });
});

test("buildExperimentsArtifact: picks the first running experiment when multiple are (invalidly) running", () => {
  const makeExperiment = (id: string, status: "draft" | "running") => ({
    id,
    name: id,
    page: `/${id}/`,
    variant: { id: "b", name: "b", page: `/x/${id}/b/` },
    split: 0.5,
    goal: { kind: "pageview" as const, path: "/thanks/" },
    status,
  });
  const config: AnglesiteConfig = {
    version: 1,
    experiments: { active: [makeExperiment("first", "running"), makeExperiment("second", "running")] },
  };
  assert.equal(buildExperimentsArtifact(config).experiment?.id, "first");
});
