import test from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createRequire } from "node:module";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import * as gate from "./gate-checks";
import * as preDeploy from "./pre-deploy-check";

const here = dirname(fileURLToPath(import.meta.url));
// Resolved from this file, not the temp site the scan runs in (which has no node_modules).
const tsxCli = createRequire(import.meta.url).resolve("tsx/cli");

test("gate-checks.ts stays runtime-neutral: no imports, no Node globals", async () => {
  // The Workers-side consumers (#2055 slices 3–4) run this module outside Node, so it must not
  // reach for anything a Worker lacks. Checked against the source rather than trusted.
  const source = await readFile(join(here, "gate-checks.ts"), "utf-8");
  const code = source.replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/.*$/gm, "");
  assert.doesNotMatch(code, /^\s*import\b/m);
  assert.doesNotMatch(code, /\brequire\s*\(/);
  assert.doesNotMatch(code, /\bprocess\./);
  assert.doesNotMatch(code, /["']node:/);
});

test("pre-deploy-check re-exports the gate module's checks, not copies", () => {
  for (const name of [
    "checkSecrets",
    "checkBlockedScripts",
    "checkBlockedRoutes",
    "checkPII",
    "checkEmbedMedia",
    "checkMixedContent",
    "checkSRI",
    "checkExternalLinkRel",
    "checkNoRestrictedContentInSource",
    "checkNoRestrictedContentInDist",
  ] as const) {
    assert.equal(preDeploy[name], gate[name], name);
  }
});

test("checkBlockedScripts: warns once per matching tracker, passes clean HTML", () => {
  const html = '<script src="https://static.hotjar.com/c/hotjar-1.js"></script>'
    + '<script src="https://connect.facebook.net/en_US/fbevents.js"></script>';
  const issues = gate.checkBlockedScripts(html, "dist/index.html");
  assert.equal(issues.length, 2);
  for (const issue of issues) {
    assert.equal(issue.severity, "warning");
    assert.equal(issue.category, "third-party-script");
    assert.equal(issue.file, "dist/index.html");
  }
  assert.deepEqual(gate.checkBlockedScripts('<script src="/app.js"></script>', "dist/index.html"), []);
});

test("checkBlockedRoutes: a Keystatic admin route is an error; unrelated paths pass", () => {
  const issues = gate.checkBlockedRoutes('<a href="/keystatic/">Admin</a>', "dist/index.html");
  assert.equal(issues.length, 1);
  assert.equal(issues[0].severity, "error");
  assert.equal(issues[0].category, "keystatic-route");
  assert.equal(issues[0].message, "Keystatic admin route found in production output");
  // `/api/keystatic/` matches both patterns — one issue per matching pattern, as before extraction.
  assert.equal(gate.checkBlockedRoutes('<script src="/api/keystatic/config"></script>', "f").length, 2);
  assert.deepEqual(gate.checkBlockedRoutes('<a href="/keystatic-notes/">Notes</a>', "f"), []);
});

test("the deploy scan still reports blocked scripts and routes after the extraction", async () => {
  const site = await mkdtemp(join(tmpdir(), "gate-checks-"));
  try {
    await mkdir(join(site, "dist"), { recursive: true });
    await writeFile(
      join(site, "dist", "index.html"),
      '<!doctype html><script src="https://static.hotjar.com/c/hotjar-1.js"></script><a href="/keystatic/">x</a>',
    );
    const run = promisify(execFile);
    const result = await run(process.execPath, [tsxCli, join(here, "pre-deploy-check.ts"), "--json"], { cwd: site })
      .catch((error: { stdout?: string }) => ({ stdout: error.stdout ?? "" }));
    const report = JSON.parse(result.stdout) as {
      failures: Array<{ category: string; file?: string }>;
      warnings: Array<{ category: string; file?: string }>;
    };
    assert.ok(report.failures.some((i) => i.category === "keystatic-route" && i.file === "dist/index.html"));
    assert.ok(report.warnings.some((i) => i.category === "third-party-script" && i.file === "dist/index.html"));
  } finally {
    await rm(site, { recursive: true, force: true });
  }
});
