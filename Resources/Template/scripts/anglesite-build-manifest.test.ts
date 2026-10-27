import test from "node:test";
import assert from "node:assert/strict";
import { gateModulesIn, isVendoredChunk, registersGate, REQUIRED_GATE_MODULES } from "./anglesite-build-manifest";

test("a chunk is vendored only when every module is dependency code", () => {
  assert.equal(isVendoredChunk(["/site/node_modules/emdash/dist/a.js", "\0virtual:emdash/admin-registry"]), true);
  assert.equal(isVendoredChunk(["/site/node_modules/emdash/dist/a.js", "\0virtual:emdash/auth-providers"]), true);
  assert.equal(isVendoredChunk(["/site/node_modules/emdash/dist/a.js", "/site/src/pages/index.astro"]), false);
  // Only EmDash's two admin-UI registries count. Its other generated modules come from the site's
  // config and seed, and any other virtual module may carry site content.
  assert.equal(isVendoredChunk(["/site/node_modules/emdash/dist/a.js", "\0virtual:emdash/config"]), false);
  assert.equal(isVendoredChunk(["/site/node_modules/emdash/dist/a.js", "\0virtual:astro:content"]), false);
  assert.equal(isVendoredChunk([]), false);
});

test("gate sources are found by site-relative path, query strings dropped", () => {
  const ids = [
    "/site/scripts/gate-checks.ts",
    "/site/scripts/emdash-gate/policy.ts?v=1",
    "/site/scripts/emdash-gate/plugin.ts",
    "/site/scripts/emdash-gate/render-backstop.ts",
    "/site/scripts/config.ts",
    "/site/node_modules/emdash/scripts/gate-checks.ts",
    "\0virtual:emdash/plugins",
  ];
  assert.deepEqual(gateModulesIn(ids, "/site").sort(), [...REQUIRED_GATE_MODULES].sort());
});

test("registration is read from EmDash's compiled plugin list, not from the plugin module", () => {
  // As emitted by EmDash 1.0.1 for `plugins: [anglesiteGate]`.
  const registered = `var plugins = [adaptSandboxEntry({ hooks: {} }, {\n\t"id": "anglesite-gate",\n\t"version": "0.1.0"\n})];`;
  assert.equal(registersGate(registered), true);
  assert.equal(registersGate("var plugins = [];"), false);
  // The id appearing elsewhere in the list (a comment, another plugin's option) isn't a registration.
  assert.equal(registersGate(`var plugins = [x({ note: "anglesite-gate" })];`), false);
});

