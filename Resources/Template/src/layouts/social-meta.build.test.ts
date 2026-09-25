// Resources/Template/src/layouts/social-meta.build.test.ts
//
// Build-level test for BaseLayout's Open Graph / Twitter Card tags (#2003): a page shared to
// Mastodon, Bluesky, Slack, iMessage or LinkedIn must carry a title, description and card type
// that match the page's own <title> and <meta name="description">, and must never carry an
// empty `content=""` tag for a value the page doesn't have.
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

/** The `content` of the first `<meta>` whose `property` or `name` is `key`, or `undefined` when
 * the page has no such tag. Attribute order is deliberately not assumed. */
function meta(html: string, key: string): string | undefined {
  for (const [tag] of html.matchAll(/<meta\b[^>]*>/g)) {
    const attr = tag.match(/\b(?:property|name)="([^"]+)"/)?.[1];
    if (attr === key) return tag.match(/\bcontent="([^"]*)"/)?.[1];
  }
  return undefined;
}

/** Decodes the handful of HTML entities Astro emits in attribute and text content. */
function decode(value: string): string {
  return value
    .replace(/&#39;|&#x27;/g, "'")
    .replace(/&quot;/g, '"')
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&");
}

// Fixture pages: one with no description, one with a social image. The default scaffold has
// neither (every shipped page sets a description; no BaseLayout page passes `image`).
const NO_DESCRIPTION_PAGE = `---
import BaseLayout from "../layouts/BaseLayout.astro";
---
<BaseLayout title="No Description"><p>Nothing to describe.</p></BaseLayout>
`;
const WITH_IMAGE_PAGE = `---
import BaseLayout from "../layouts/BaseLayout.astro";
---
<BaseLayout title="With Image" description="A page with a picture." image="/images/share.jpg"><p>Picture.</p></BaseLayout>
`;

function build(fixtureDir: string): void {
  execFileSync("npx", ["astro", "build"], { cwd: fixtureDir, stdio: "inherit" });
}

async function page(fixtureDir: string, path: string): Promise<string> {
  return readFile(join(fixtureDir, "dist", path, "index.html"), "utf8");
}

test("BaseLayout emits Open Graph and Twitter Card tags", async (t) => {
  const fixtureDir = await mkdtemp(join(tmpdir(), "anglesite-social-meta-fixture-"));
  try {
    await cp(TEMPLATE_ROOT, fixtureDir, {
      recursive: true,
      filter: (src) => !EXCLUDED.test(src.slice(TEMPLATE_ROOT.length)),
    });
    await writeFile(join(fixtureDir, "src/pages/social-no-description.astro"), NO_DESCRIPTION_PAGE, "utf8");
    await writeFile(join(fixtureDir, "src/pages/social-with-image.astro"), WITH_IMAGE_PAGE, "utf8");
    await writeFile(join(fixtureDir, ".site-config"), "SITE_NAME=Fixture Bakery\nLANG=en-US\n", "utf8");

    execFileSync("npm", ["install", "--no-audit", "--no-fund", "--prefer-offline"], {
      cwd: fixtureDir,
      stdio: "inherit",
    });
    build(fixtureDir);

    await t.test("the home page's tags match its <title> and description", async () => {
      const html = await page(fixtureDir, "");
      const title = decode(html.match(/<title>([^<]*)<\/title>/)?.[1] ?? "");
      const description = meta(html, "description");
      assert.ok(title, "the home page must have a <title>");
      assert.ok(description, "the home page must have a description");
      assert.equal(decode(meta(html, "og:title") ?? ""), title);
      assert.equal(meta(html, "og:description"), description);
      assert.equal(decode(meta(html, "twitter:title") ?? ""), title);
      assert.equal(meta(html, "twitter:description"), description);
      assert.equal(meta(html, "og:locale"), "en-US", "og:locale is the BCP-47 tag verbatim");
      assert.equal(meta(html, "twitter:card"), "summary");
    });

    await t.test("a page with no description emits no description tags at all", async () => {
      const html = await page(fixtureDir, "social-no-description");
      assert.equal(meta(html, "og:title"), "No Description");
      assert.equal(meta(html, "og:description"), undefined);
      assert.equal(meta(html, "twitter:description"), undefined);
      assert.doesNotMatch(html, /content=""/, "no tag may carry an empty content attribute");
    });

    await t.test("a page with an image gets a large-image card", async () => {
      const html = await page(fixtureDir, "social-with-image");
      assert.match(meta(html, "og:image") ?? "", /\/images\/share\.jpg$/);
      assert.equal(meta(html, "twitter:card"), "summary_large_image");
    });

    await t.test("a blog post carries article:published_time; other pages carry no article: tag", async () => {
      const post = await page(fixtureDir, "blog/welcome-to-your-blog");
      assert.equal(meta(post, "article:published_time"), "2026-01-01T00:00:00.000Z");
      const home = await page(fixtureDir, "");
      assert.doesNotMatch(home, /property="article:/);
    });

    await t.test("og:site_name is SITE_NAME when set", async () => {
      assert.equal(meta(await page(fixtureDir, ""), "og:site_name"), "Fixture Bakery");
    });

    await t.test("og:site_name is absent when SITE_NAME is unset", async () => {
      await writeFile(join(fixtureDir, ".site-config"), "LANG=en-US\n", "utf8");
      build(fixtureDir);
      const html = await page(fixtureDir, "");
      assert.equal(meta(html, "og:site_name"), undefined);
      assert.doesNotMatch(html, /og:site_name/);
    });
  } finally {
    await rm(fixtureDir, { recursive: true, force: true });
  }
});
