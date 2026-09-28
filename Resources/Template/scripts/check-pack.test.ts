// Run: npx tsx --test scripts/check-pack.test.ts
//
// Port-contract lint (spec §2, docs/superpowers/specs/2026-07-31-curated-theme-ports-design.md):
// markers, HomepageWriter sentinels, flat component dirs, the 12 base tokens, LICENSE,
// thumbnail, a complete catalog entry, and (#2038) <head>/Props lockstep with the chassis
// BaseLayout.
import test from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { layoutParityErrors, validatePack, REQUIRED_ROOT_VARS } from "./check-pack";
import type { ThemeRecord } from "./themes";

const ENTRY: ThemeRecord = {
  id: "paper",
  displayName: "Paper",
  description: "Ported blog theme",
  bestFor: ["blog"],
  vars: { "color-primary": "#111111", "color-accent": "#ff5500" },
  category: "blog",
  pack: "paper",
  thumbnail: "packs/paper/thumbnail.png",
  credit: { name: "AstroPaper", url: "https://example.com", license: "MIT" },
};

const BASE_LAYOUT = `---
// anglesite:imports
---
<head><!-- anglesite:head-end --></head>
<body><!-- anglesite:nav --><main id="main"><slot /></main><!-- anglesite:body-end --></body>`;

const INDEX_PAGE = `---
// anglesite:imports
---
<BaseLayout title="Welcome — Your New Anglesite Business Website"
  description="Your business website is ready to set up in Anglesite.">
  <h1>Welcome</h1>
  <p>This site is ready to customize in Anglesite. Open the app to edit your pages, add content, and publish when you're ready.</p>
  <!-- anglesite:hero-cta -->
</BaseLayout>`;

const GLOBAL_CSS = `:root {
${REQUIRED_ROOT_VARS.map((name) => `  ${name}: initial;`).join("\n")}
}`;

function makePack(mutate?: (dir: string) => void): string {
  const dir = mkdtempSync(join(tmpdir(), "anglesite-pack-"));
  mkdirSync(join(dir, "src", "layouts"), { recursive: true });
  mkdirSync(join(dir, "src", "pages"), { recursive: true });
  mkdirSync(join(dir, "src", "components"), { recursive: true });
  mkdirSync(join(dir, "src", "styles"), { recursive: true });
  writeFileSync(join(dir, "LICENSE"), "MIT License");
  writeFileSync(join(dir, "thumbnail.png"), "png");
  writeFileSync(join(dir, "src", "layouts", "BaseLayout.astro"), BASE_LAYOUT);
  writeFileSync(join(dir, "src", "pages", "index.astro"), INDEX_PAGE);
  writeFileSync(join(dir, "src", "styles", "global.css"), GLOBAL_CSS);
  writeFileSync(join(dir, "src", "components", "PaperNav.astro"), "<nav><slot /></nav>");
  mutate?.(dir);
  return dir;
}

test("a compliant pack passes", () => {
  const dir = makePack();
  try { assert.deepEqual(validatePack(dir, ENTRY), []); }
  finally { rmSync(dir, { recursive: true, force: true }); }
});

test("missing catalog entry is reported", () => {
  const dir = makePack();
  try { assert.ok(validatePack(dir, undefined).some((e) => e.includes("catalog"))); }
  finally { rmSync(dir, { recursive: true, force: true }); }
});

test("a missing marker in an overridden BaseLayout is reported", () => {
  const dir = makePack((d) =>
    writeFileSync(join(d, "src", "layouts", "BaseLayout.astro"),
      BASE_LAYOUT.replace("<!-- anglesite:nav -->", "")));
  try { assert.ok(validatePack(dir, ENTRY).some((e) => e.includes("anglesite:nav"))); }
  finally { rmSync(dir, { recursive: true, force: true }); }
});

test("a missing HomepageWriter sentinel in an overridden index is reported", () => {
  const dir = makePack((d) =>
    writeFileSync(join(d, "src", "pages", "index.astro"),
      INDEX_PAGE.replace("<h1>Welcome</h1>", "<h1>Hello</h1>")));
  try { assert.ok(validatePack(dir, ENTRY).some((e) => e.includes("<h1>Welcome</h1>"))); }
  finally { rmSync(dir, { recursive: true, force: true }); }
});

test("nested component directories are reported", () => {
  const dir = makePack((d) => {
    mkdirSync(join(d, "src", "components", "hero"), { recursive: true });
    writeFileSync(join(d, "src", "components", "hero", "Hero.astro"), "<div/>");
  });
  try { assert.ok(validatePack(dir, ENTRY).some((e) => e.includes("subdirector"))); }
  finally { rmSync(dir, { recursive: true, force: true }); }
});

test("a global.css missing a base token is reported", () => {
  const dir = makePack((d) =>
    writeFileSync(join(d, "src", "styles", "global.css"),
      GLOBAL_CSS.replace("--radius-lg: initial;", "")));
  try { assert.ok(validatePack(dir, ENTRY).some((e) => e.includes("--radius-lg"))); }
  finally { rmSync(dir, { recursive: true, force: true }); }
});

test("missing LICENSE and thumbnail are reported", () => {
  const dir = makePack((d) => {
    rmSync(join(d, "LICENSE"));
    rmSync(join(d, "thumbnail.png"));
  });
  try {
    const errors = validatePack(dir, ENTRY);
    assert.ok(errors.some((e) => e.includes("LICENSE")));
    assert.ok(errors.some((e) => e.includes("thumbnail")));
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("a pack that overrides nothing structural still needs LICENSE + entry only", () => {
  // Styles-only pack: no layouts/pages overridden → no marker/sentinel requirements.
  const dir = mkdtempSync(join(tmpdir(), "anglesite-pack-"));
  mkdirSync(join(dir, "src", "styles"), { recursive: true });
  writeFileSync(join(dir, "LICENSE"), "MIT License");
  writeFileSync(join(dir, "thumbnail.png"), "png");
  writeFileSync(join(dir, "src", "styles", "global.css"), GLOBAL_CSS);
  try { assert.deepEqual(validatePack(dir, ENTRY), []); }
  finally { rmSync(dir, { recursive: true, force: true }); }
});

// #2038: a forked BaseLayout must keep the chassis <head> and Props in lockstep. The chassis
// fixture carries a doc comment mentioning <head> in its frontmatter, like the real one does.
const CHASSIS_LAYOUT = `---
// anglesite:imports
interface Props {
  title: string;
  /** Advertised in <head>. */
  description?: string;
}
---
<html>
  <head>
    <title>{title}</title>
    <meta property="og:title" content={title} />
    <!-- anglesite:head-end -->
  </head>
  <body><!-- anglesite:nav --><main id="main"><slot /></main><!-- anglesite:body-end --></body>
</html>`;

function makeChassis(layout = CHASSIS_LAYOUT): string {
  const dir = mkdtempSync(join(tmpdir(), "anglesite-chassis-"));
  mkdirSync(join(dir, "src", "layouts"), { recursive: true });
  writeFileSync(join(dir, "src", "layouts", "BaseLayout.astro"), layout);
  return dir;
}

test("a forked BaseLayout matching the chassis head and Props passes, whatever its body chrome", () => {
  const pack = CHASSIS_LAYOUT.replace("<!-- anglesite:nav -->", "<PaperNav><!-- anglesite:nav --></PaperNav>");
  assert.deepEqual(layoutParityErrors(CHASSIS_LAYOUT, pack), []);
  const chassis = makeChassis();
  const dir = makePack((d) => writeFileSync(join(d, "src", "layouts", "BaseLayout.astro"), pack));
  try { assert.deepEqual(validatePack(dir, ENTRY, chassis), []); }
  finally {
    rmSync(dir, { recursive: true, force: true });
    rmSync(chassis, { recursive: true, force: true });
  }
});

test("a forked BaseLayout missing a chassis <head> line is reported", () => {
  const pack = CHASSIS_LAYOUT.replace('    <meta property="og:title" content={title} />\n', "");
  const errors = layoutParityErrors(CHASSIS_LAYOUT, pack);
  assert.equal(errors.length, 1);
  assert.match(errors[0], /<head> is missing chassis line <meta property="og:title"/);
});

test("a forked BaseLayout with an extra or reordered <head> line is reported", () => {
  const extra = CHASSIS_LAYOUT.replace("<!-- anglesite:head-end -->", '<meta name="x" content="y" />\n    <!-- anglesite:head-end -->');
  assert.ok(layoutParityErrors(CHASSIS_LAYOUT, extra).some((e) => e.includes("a line the chassis doesn't")));
  const reordered = CHASSIS_LAYOUT.replace(
    '    <title>{title}</title>\n    <meta property="og:title" content={title} />',
    '    <meta property="og:title" content={title} />\n    <title>{title}</title>',
  );
  assert.ok(layoutParityErrors(CHASSIS_LAYOUT, reordered).some((e) => e.includes("out of order")));
});

test("a forked BaseLayout missing a chassis prop is reported", () => {
  const pack = CHASSIS_LAYOUT.replace("  /** Advertised in <head>. */\n  description?: string;\n", "");
  assert.deepEqual(layoutParityErrors(CHASSIS_LAYOUT, pack), [
    "src/layouts/BaseLayout.astro: Props is missing chassis prop description",
  ]);
});

test("validatePack checks parity only when given a chassis directory", () => {
  const chassis = makeChassis();
  const dir = makePack(); // BASE_LAYOUT has none of the chassis head lines
  try {
    assert.deepEqual(validatePack(dir, ENTRY), []);
    assert.ok(validatePack(dir, ENTRY, chassis).some((e) => e.includes("missing chassis line")));
  } finally {
    rmSync(dir, { recursive: true, force: true });
    rmSync(chassis, { recursive: true, force: true });
  }
});
