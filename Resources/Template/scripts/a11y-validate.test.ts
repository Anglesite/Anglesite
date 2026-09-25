import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import {
  contrastRatio,
  parseOpaqueColor,
  validateContrast,
  validateHeadingHierarchy,
  validateLinkText,
  validateImageAlt,
  validateHtml,
} from "./a11y-validate";

// ---------------------------------------------------------------------------
// validateHeadingHierarchy
// ---------------------------------------------------------------------------

test("validateHeadingHierarchy: returns no issues for correct hierarchy", () => {
  const html = "<h1>Title</h1><h2>Section</h2><h3>Sub</h3>";
  assert.deepEqual(validateHeadingHierarchy(html), []);
});

test("validateHeadingHierarchy: flags skipped heading levels", () => {
  const html = "<h1>Title</h1><h3>Skipped h2</h3>";
  const issues = validateHeadingHierarchy(html);
  assert.equal(issues.length, 1);
  assert.equal(issues[0].rule, "heading-skip");
  assert.match(issues[0].message, /h3/);
});

test("validateHeadingHierarchy: flags multiple h1 elements", () => {
  const html = "<h1>First</h1><h1>Second</h1>";
  const issues = validateHeadingHierarchy(html);
  assert.equal(issues.length, 1);
  assert.equal(issues[0].rule, "heading-multiple-h1");
});

test("validateHeadingHierarchy: allows heading level to go back up (h3 -> h2 is fine)", () => {
  const html = "<h1>Title</h1><h2>A</h2><h3>A1</h3><h2>B</h2>";
  assert.deepEqual(validateHeadingHierarchy(html), []);
});

test("validateHeadingHierarchy: flags when first heading is not h1", () => {
  const html = "<h2>Starts at h2</h2><h3>Sub</h3>";
  const issues = validateHeadingHierarchy(html);
  assert.ok(issues.some((i) => i.rule === "heading-skip"));
});

test("validateHeadingHierarchy: returns no issues for empty content", () => {
  assert.deepEqual(validateHeadingHierarchy(""), []);
  assert.deepEqual(validateHeadingHierarchy("<p>No headings</p>"), []);
});

test("validateHeadingHierarchy: handles multiple skip violations", () => {
  const html = "<h1>Title</h1><h3>Skip</h3><h6>Big skip</h6>";
  const issues = validateHeadingHierarchy(html);
  assert.equal(issues.filter((i) => i.rule === "heading-skip").length, 2);
});

// ---------------------------------------------------------------------------
// validateLinkText
// ---------------------------------------------------------------------------

test("validateLinkText: returns no issues for descriptive link text", () => {
  const html = '<a href="/about">Learn about our services</a>';
  assert.deepEqual(validateLinkText(html), []);
});

test("validateLinkText: flags 'click here'", () => {
  const html = '<a href="/about">click here</a>';
  const issues = validateLinkText(html);
  assert.equal(issues.length, 1);
  assert.equal(issues[0].rule, "link-text-generic");
  assert.match(issues[0].message, /click here/);
});

test("validateLinkText: decodes entities before matching generic patterns", () => {
  const html = '<a href="/about">click&nbsp;here</a>';
  const issues = validateLinkText(html);
  assert.equal(issues.length, 1);
  assert.equal(issues[0].rule, "link-text-generic");
});

test("validateLinkText: flags 'read more'", () => {
  const html = '<a href="/post">Read More</a>';
  const issues = validateLinkText(html);
  assert.equal(issues.length, 1);
  assert.equal(issues[0].rule, "link-text-generic");
});

test("validateLinkText: flags 'here' as link text", () => {
  const html = '<a href="/page">here</a>';
  assert.equal(validateLinkText(html).length, 1);
});

test("validateLinkText: flags 'learn more'", () => {
  const html = '<a href="/page">Learn more</a>';
  assert.equal(validateLinkText(html).length, 1);
});

test("validateLinkText: flags 'more info'", () => {
  const html = '<a href="/page">more info</a>';
  assert.equal(validateLinkText(html).length, 1);
});

test("validateLinkText: flags multiple bad links", () => {
  const html = '<a href="/a">click here</a> and <a href="/b">read more</a>';
  assert.equal(validateLinkText(html).length, 2);
});

test("validateLinkText: ignores links with aria-label", () => {
  const html = '<a href="/page" aria-label="View our pricing">here</a>';
  assert.deepEqual(validateLinkText(html), []);
});

test("validateLinkText: flags empty link text", () => {
  const html = '<a href="/page"></a>';
  const issues = validateLinkText(html);
  assert.equal(issues.length, 1);
  assert.equal(issues[0].rule, "link-text-empty");
});

test("validateLinkText: does not flag empty links with aria-label", () => {
  const html = '<a href="/page" aria-label="Home"></a>';
  assert.deepEqual(validateLinkText(html), []);
});

// ---------------------------------------------------------------------------
// validateImageAlt
// ---------------------------------------------------------------------------

test("validateImageAlt: returns no issues for images with alt text", () => {
  const html = '<img src="photo.jpg" alt="A sunset over the mountains" />';
  assert.deepEqual(validateImageAlt(html), []);
});

test("validateImageAlt: allows decorative images with empty alt", () => {
  const html = '<img src="divider.svg" alt="" />';
  assert.deepEqual(validateImageAlt(html), []);
});

test("validateImageAlt: flags images with no alt attribute at all", () => {
  const html = '<img src="photo.jpg" />';
  const issues = validateImageAlt(html);
  assert.equal(issues.length, 1);
  assert.equal(issues[0].rule, "img-alt-missing");
});

test("validateImageAlt: flags images with placeholder alt text", () => {
  const html = '<img src="photo.jpg" alt="image" />';
  const issues = validateImageAlt(html);
  assert.equal(issues.length, 1);
  assert.equal(issues[0].rule, "img-alt-placeholder");
});

test("validateImageAlt: flags 'photo' as placeholder alt text", () => {
  const html = '<img src="team.jpg" alt="photo" />';
  assert.equal(validateImageAlt(html).length, 1);
});

test("validateImageAlt: flags 'untitled' as placeholder alt text", () => {
  const html = '<img src="hero.jpg" alt="untitled" />';
  assert.equal(validateImageAlt(html).length, 1);
});

test("validateImageAlt: flags multiple images with issues", () => {
  const html = '<img src="a.jpg" /><img src="b.jpg" alt="image" /><img src="c.jpg" alt="A dog" />';
  const issues = validateImageAlt(html);
  assert.equal(issues.length, 2); // missing + placeholder
});

test("validateImageAlt: handles self-closing and non-self-closing img tags", () => {
  const html1 = '<img src="a.jpg" alt="Good alt">';
  const html2 = '<img src="a.jpg" alt="Good alt" />';
  assert.deepEqual(validateImageAlt(html1), []);
  assert.deepEqual(validateImageAlt(html2), []);
});

// ---------------------------------------------------------------------------
// A11yIssue shape
// ---------------------------------------------------------------------------

test("A11yIssue shape: has rule, message, and severity fields", () => {
  const html = '<img src="x.jpg" />';
  const issues = validateImageAlt(html);
  assert.ok("rule" in issues[0]);
  assert.ok("message" in issues[0]);
  assert.ok("severity" in issues[0]);
  assert.ok(["error", "warning"].includes(issues[0].severity));
});

// ---------------------------------------------------------------------------
// validateHtml -- unified validator
// ---------------------------------------------------------------------------

test("validateHtml: returns all issues from all validators", () => {
  const html = '<h1>Title</h1><h3>Skip</h3><a href="/x">click here</a><img src="y.jpg" />';
  const issues = validateHtml(html);
  const rules = issues.map((i) => i.rule);
  assert.ok(rules.includes("heading-skip"));
  assert.ok(rules.includes("link-text-generic"));
  assert.ok(rules.includes("img-alt-missing"));
});

test("validateHtml: sorts errors before warnings", () => {
  const html = '<h1>Title</h1><a href="/x">click here</a><img src="y.jpg" />';
  const issues = validateHtml(html);
  // img-alt-missing is error, link-text-generic is warning
  const errorIdx = issues.findIndex((i) => i.rule === "img-alt-missing");
  const warnIdx = issues.findIndex((i) => i.rule === "link-text-generic");
  assert.ok(errorIdx < warnIdx);
});

test("validateHtml: returns empty array for clean HTML", () => {
  const html =
    '<h1>Title</h1><h2>Sub</h2><a href="/about">About us</a><img src="x.jpg" alt="A photo of the team" />';
  assert.deepEqual(validateHtml(html), []);
});

// ---------------------------------------------------------------------------
// html-validate edge cases (things regex would miss)
// ---------------------------------------------------------------------------

test("html-validate integration: handles nested tags inside links", () => {
  // Regex-based parsers struggle with nested HTML in link text
  const html = '<a href="/x"><span>click here</span></a>';
  const issues = validateLinkText(html);
  assert.equal(issues.length, 1);
  assert.equal(issues[0].rule, "link-text-generic");
});

test("html-validate integration: recognizes img role=presentation as not needing alt", () => {
  const html = '<img src="spacer.gif" role="presentation" />';
  assert.deepEqual(validateImageAlt(html), []);
});

// ---------------------------------------------------------------------------
// validateContrast (#2022)
// ---------------------------------------------------------------------------

const TEMPLATE_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

/** The rules through which the chassis draws each token pair (global.css): body text on the
 * page, a link, a surface card, and the skip link's label on its primary fill. */
const USAGE = `
html { color: var(--color-text); background-color: var(--color-background); }
a { color: var(--color-primary); }
.muted { color: var(--color-text-muted); }
.card { background-color: var(--color-surface); }
.skip-link { background-color: var(--color-primary); color: var(--color-background); }
`;

/** A passing light palette (the shipped one). */
const LIGHT = `
:root {
  --color-primary: #2563eb;
  --color-background: #ffffff;
  --color-surface: #f8fafc;
  --color-text: #1e293b;
  --color-text-muted: #64748b;
}`;

test("validateContrast: the shipped global.css passes in both the light and dark palettes", () => {
  const css = readFileSync(join(TEMPLATE_ROOT, "src/styles/global.css"), "utf8");
  assert.match(css, /prefers-color-scheme: dark/, "fixture must include the dark block");
  assert.deepEqual(validateContrast(css), []);
});

test("validateContrast: every shipped theme pack's global.css passes too", () => {
  for (const pack of ["astropaper", "astroplate", "astrowind", "cactus", "starfolio"]) {
    const css = readFileSync(join(TEMPLATE_ROOT, "packs", pack, "src/styles/global.css"), "utf8");
    assert.deepEqual(validateContrast(css), [], pack);
  }
});

test("validateContrast: failing body text is an error naming both properties and the ratio", () => {
  const css = LIGHT.replace("--color-text: #1e293b;", "--color-text: #999999;") + USAGE;
  const issues = validateContrast(css).filter((i) => i.message.startsWith("--color-text on --color-background"));
  assert.equal(issues.length, 1);
  assert.equal(issues[0].rule, "color-contrast");
  assert.equal(issues[0].severity, "error");
  assert.match(issues[0].message, /--color-text on --color-background has a contrast ratio of 2\.8:1 in the light palette/);
  assert.match(issues[0].message, /at least 4\.5:1/);
});

test("validateContrast: a failing dark @media palette is reported as the dark block, not the light one", () => {
  const css = `${LIGHT}
@media (prefers-color-scheme: dark) {
  :root { --color-background: #475569; }
}${USAGE}`;
  const issues = validateContrast(css);
  assert.ok(issues.length > 0);
  for (const issue of issues) {
    assert.match(issue.message, /in the @media \(prefers-color-scheme: dark\) palette/);
    assert.doesNotMatch(issue.message, /light palette/);
  }
  assert.ok(issues.some((i) => i.message.startsWith("--color-text on --color-background")));
});

test("validateContrast: a @media block overriding only one token inherits the rest from the base", () => {
  // #767676 on the inherited #ffffff background is 4.54:1 (passes); on #f8fafc surface, 4.34:1.
  const css = `${LIGHT}
@media (prefers-color-scheme: dark) {
  :root { --color-text-muted: #767676; }
}${USAGE}`;
  const issues = validateContrast(css);
  assert.deepEqual(
    issues.map((i) => i.message.split(" has ")[0]),
    ["--color-text-muted on --color-surface"],
  );
  assert.match(issues[0].message, /prefers-color-scheme: dark/);
});

test("validateContrast: a media block that overrides none of a pair's tokens doesn't re-report it", () => {
  const css = LIGHT.replace("--color-text: #1e293b;", "--color-text: #999999;") +
    "@media (min-width: 48rem) { :root { --spacing-unit: 0.3rem; } }" + USAGE;
  assert.ok(validateContrast(css).every((i) => i.message.includes("light palette")));
});

test("validateContrast: var() chains resolve within the effective block", () => {
  const css = LIGHT.replace("--color-text: #1e293b;", "--ink: #999999; --color-text: var(--ink);") + USAGE;
  assert.ok(validateContrast(css).some((i) => i.message.startsWith("--color-text on --color-background")));
});

test("validateContrast: a var() chain deeper than four hops is skipped, not guessed", () => {
  const css = LIGHT.replace(
    "--color-text: #1e293b;",
    "--a: #999999; --b: var(--a); --c: var(--b); --d: var(--c); --e: var(--d); --color-text: var(--e);",
  ) + USAGE;
  assert.ok(!validateContrast(css).some((i) => i.message.startsWith("--color-text on")));
});

for (const [name, value] of [
  ["color-mix()", "color-mix(in srgb, #999 50%, #fff)"],
  ["a gradient", "linear-gradient(#999, #aaa)"],
  ["currentColor", "currentColor"],
  ["an 8-digit hex with alpha", "#99999980"],
  ["rgba() with alpha", "rgba(153, 153, 153, 0.5)"],
  ["hsla() with alpha", "hsla(0, 0%, 60%, 0.5)"],
  ["space-syntax alpha", "rgb(153 153 153 / 50%)"],
  ["a named colour", "gray"],
  ["garbage", "not-a-colour"],
  ["an unresolvable var()", "var(--nowhere)"],
] as const) {
  test(`validateContrast: ${name} is skipped without an issue or a throw`, () => {
    const css = LIGHT.replace("--color-text: #1e293b;", `--color-text: ${value};`) + USAGE;
    assert.ok(!validateContrast(css).some((i) => i.message.startsWith("--color-text on")));
  });
}

test("validateContrast: a link pair is a warning at 3.5:1 and an error at 2.5:1", () => {
  // Both on a white background: #3a8ed6 is 3.49:1, #6aa5ee is 2.55:1.
  const at = (primary: string) =>
    validateContrast(LIGHT.replace("--color-primary: #2563eb;", `--color-primary: ${primary};`) + USAGE)
      .find((i) => i.message.startsWith("--color-primary on --color-background"));
  const warning = at("#3a8ed6");
  assert.equal(warning?.severity, "warning");
  assert.match(warning!.message, /3\.[45]:1/);
  const error = at("#6aa5ee");
  assert.equal(error?.severity, "error");
  assert.match(error!.message, /2\.[45]:1/);
});

test("validateContrast: a pair the stylesheet never draws is not checked", () => {
  // No rule sets `color: var(--color-primary)` on the page background, and the one that uses it
  // paints its own literal white fill — a different pair.
  const css = LIGHT.replace("--color-primary: #2563eb;", "--color-primary: #62a3ea;") + `
html { color: var(--color-text); background-color: var(--color-background); }
.card { background-color: var(--color-surface); }
.button { background-color: #ffffff; color: var(--color-primary); }`;
  assert.ok(!validateContrast(css).some((i) => i.message.includes("--color-primary")));
});

test("validateContrast: minified CSS is handled", () => {
  const css = ":root{--color-primary:#2563eb;--color-background:#fff;--color-surface:#f8fafc;--color-text:#999;--color-text-muted:#64748b}" +
    "html{color:var(--color-text);background-color:var(--color-background)}";
  assert.ok(validateContrast(css).some((i) => i.message.startsWith("--color-text on --color-background")));
});

test("validateContrast: CSS with no :root tokens produces nothing", () => {
  assert.deepEqual(validateContrast("body { color: #999; }"), []);
  assert.deepEqual(validateContrast(""), []);
});

test("parseOpaqueColor: accepts hex, rgb() and hsl() in comma and space syntax", () => {
  assert.deepEqual(parseOpaqueColor("#fff"), [255, 255, 255]);
  assert.deepEqual(parseOpaqueColor("#1e293b"), [30, 41, 59]);
  assert.deepEqual(parseOpaqueColor("#1e293bff"), [30, 41, 59]);
  assert.deepEqual(parseOpaqueColor("rgb(30, 41, 59)"), [30, 41, 59]);
  assert.deepEqual(parseOpaqueColor("rgb(30 41 59)"), [30, 41, 59]);
  assert.deepEqual(parseOpaqueColor("rgba(30, 41, 59, 1)"), [30, 41, 59]);
  assert.deepEqual(parseOpaqueColor("hsl(0, 0%, 100%)"), [255, 255, 255]);
  assert.deepEqual(parseOpaqueColor("hsl(0deg 0% 0%)"), [0, 0, 0]);
  assert.equal(parseOpaqueColor("hsl(0.5turn 50% 50%)"), undefined);
});

test("contrastRatio: matches WCAG reference values", () => {
  assert.equal(contrastRatio([0, 0, 0], [255, 255, 255]).toFixed(1), "21.0");
  assert.equal(contrastRatio([118, 118, 118], [255, 255, 255]).toFixed(2), "4.54");
});
