// Resources/Template/src/layouts/goal-beacon.build.test.ts
//
// Build-level test for the client-side goal beacon injection (#1270 slice 2): a running
// experiment with a "scroll"/"visible" goal must carry the beacon <script> on both its control
// and variant pages (and nowhere else); with no running client-side-goal experiment, the feature
// must stay completely inert — mirrors webmcp.build.test.ts's off/on shape for the same class of
// config-driven conditional <script> injection.
import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, cp, writeFile, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

// Resources/Template/ — two `..` up from src/layouts/
const TEMPLATE_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

const EXCLUDED = /(^|\/)(node_modules|dist|\.astro|\.wrangler)(\/|$)/;

const VARIANT_FIXTURE_PAGE = `---
import BaseLayout from "../layouts/BaseLayout.astro";
---
<BaseLayout title="Variant fixture">
  <p>Variant fixture page for the goal-beacon injection test.</p>
</BaseLayout>
`;

async function buildFixture(anglesiteConfig: Record<string, unknown> | null): Promise<string> {
  const fixtureDir = await mkdtemp(join(tmpdir(), "anglesite-goal-beacon-fixture-"));
  await cp(TEMPLATE_ROOT, fixtureDir, {
    recursive: true,
    filter: (src) => !EXCLUDED.test(src.slice(TEMPLATE_ROOT.length)),
  });
  await writeFile(join(fixtureDir, "src", "pages", "variant-fixture.astro"), VARIANT_FIXTURE_PAGE, "utf8");
  if (anglesiteConfig) {
    await writeFile(join(fixtureDir, "anglesite.json"), JSON.stringify(anglesiteConfig), "utf8");
  }
  execFileSync("npm", ["install", "--no-audit", "--no-fund", "--prefer-offline"], { cwd: fixtureDir, stdio: "inherit" });
  execFileSync("npx", ["astro", "build"], { cwd: fixtureDir, stdio: "inherit" });
  return fixtureDir;
}

test("goal beacon: no running client-side-goal experiment emits no beacon script anywhere", async () => {
  const fixtureDir = await buildFixture(null);
  try {
    const home = await readFile(join(fixtureDir, "dist/index.html"), "utf8");
    assert.doesNotMatch(home, /goal-beacon\.js/, "the homepage must not reference the beacon script when no experiment runs");
  } finally {
    await rm(fixtureDir, { recursive: true, force: true });
  }
});

test("goal beacon: a running scroll-goal experiment injects the beacon on both control and variant pages", async () => {
  const fixtureDir = await buildFixture({
    version: 1,
    experiments: {
      active: [
        {
          id: "goal-beacon-fixture",
          name: "Goal beacon fixture",
          page: "/",
          variant: { id: "b", name: "B", page: "/variant-fixture/" },
          split: 0.5,
          goal: { kind: "scroll", depth: 75 },
          status: "running",
          startedAt: "2026-08-17",
        },
      ],
    },
  });
  try {
    const control = await readFile(join(fixtureDir, "dist/index.html"), "utf8");
    const variant = await readFile(join(fixtureDir, "dist/variant-fixture/index.html"), "utf8");
    const scriptPattern =
      /<script[^>]*\bsrc="\/x\/goal-beacon\.js"[^>]*\bdata-experiment="goal-beacon-fixture"[^>]*\bdata-kind="scroll"[^>]*\bdata-depth="75"[^>]*>/;

    assert.match(control, scriptPattern, "the control page must carry the beacon script with the right data attributes");
    assert.match(variant, scriptPattern, "the variant page must carry the beacon script with the right data attributes");
    assert.doesNotMatch(control, /data-selector/, "a scroll goal must not render a data-selector attribute");

    // An unrelated page must stay untouched — the beacon is only injected on the experiment's own
    // two pages, not site-wide.
    const rss = await readFile(join(fixtureDir, "dist/notes/hello-note/index.html"), "utf8").catch(() => null);
    if (rss !== null) {
      assert.doesNotMatch(rss, /goal-beacon\.js/, "an unrelated page must not carry the beacon script");
    }
  } finally {
    await rm(fixtureDir, { recursive: true, force: true });
  }
});
