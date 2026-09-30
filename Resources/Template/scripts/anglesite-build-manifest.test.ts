import test from "node:test";
import assert from "node:assert/strict";
import { gateModulesIn, isVendoredChunk, REQUIRED_GATE_MODULES } from "./anglesite-build-manifest";

test("a chunk is vendored only when every module is dependency code", () => {
  assert.equal(isVendoredChunk(["/site/node_modules/emdash/dist/a.js", "\0virtual:emdash/admin-registry"]), true);
  assert.equal(isVendoredChunk(["/site/node_modules/emdash/dist/a.js", "/site/src/pages/index.astro"]), false);
  // Only EmDash's own generated modules count; any other virtual module may carry site content.
  assert.equal(isVendoredChunk(["/site/node_modules/emdash/dist/a.js", "\0virtual:astro:content"]), false);
  assert.equal(isVendoredChunk([]), false);
});

test("gate sources are found by site-relative path, query strings dropped", () => {
  const ids = [
    "/site/scripts/gate-checks.ts",
    "/site/scripts/emdash-gate/policy.ts?v=1",
    "/site/scripts/emdash-gate/plugin.ts",
    "/site/scripts/config.ts",
    "/site/node_modules/emdash/scripts/gate-checks.ts",
    "\0virtual:emdash/plugins",
  ];
  assert.deepEqual(gateModulesIn(ids, "/site").sort(), [...REQUIRED_GATE_MODULES].sort());
});
