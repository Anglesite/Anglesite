// Resources/Template/src/pages/_mcp-search-index.build.test.ts
//
// Build-level test for the MCP `search_posts` index endpoint (#1576). Unit coverage of the
// shaping logic already lives in src/lib/mcp-search-entries.test.ts — including a `blog` case
// that passed even while the endpoint iterated `ENTRY_COLLECTIONS` (which excludes `blog` by
// construction) and therefore never handed a blog entry in. This runs a real `astro build` with
// `experimental.mcp` on and asserts the seed blog post actually lands in the emitted index, plus
// one representative ENTRY_COLLECTIONS entry so the fix didn't trade one collection for another.
import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, cp, readFile, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";
import type { McpSearchEntry } from "../lib/mcp-search-entries.ts";

// Resources/Template/ — two `..` up from src/pages/
const TEMPLATE_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

const EXCLUDED = /(^|\/)(node_modules|dist|\.astro|\.wrangler)(\/|$)/;

test("mcp-search-index.json includes the seed blog post when experimental.mcp is on", async () => {
  const fixtureDir = await mkdtemp(join(tmpdir(), "anglesite-mcp-search-index-fixture-"));
  try {
    await cp(TEMPLATE_ROOT, fixtureDir, {
      recursive: true,
      filter: (src) => !EXCLUDED.test(src.slice(TEMPLATE_ROOT.length)),
    });
    // The endpoint gates on anglesite.json's experimental.mcp, read from process.cwd() at build.
    await writeFile(
      join(fixtureDir, "anglesite.json"),
      JSON.stringify({ version: 1, experimental: { mcp: true } }, null, 2) + "\n",
      "utf8",
    );

    execFileSync("npm", ["install", "--no-audit", "--no-fund", "--prefer-offline"], {
      cwd: fixtureDir,
      stdio: "inherit",
    });
    execFileSync("npx", ["astro", "build"], { cwd: fixtureDir, stdio: "inherit" });

    const raw = await readFile(join(fixtureDir, "dist/mcp-search-index.json"), "utf8");
    const index = JSON.parse(raw) as McpSearchEntry[];
    assert.ok(Array.isArray(index));

    // The regression this file exists for: blog must be represented.
    const blog = index.filter((e) => e.collection === "blog");
    assert.ok(blog.length > 0, "no blog entries in the built search index");
    const welcome = blog.find((e) => e.url === "/blog/welcome-to-your-blog");
    assert.ok(welcome, `seed blog post missing; got ${JSON.stringify(blog.map((e) => e.url))}`);
    assert.equal(welcome?.title, "Welcome to your blog");

    // …and the previously-indexed collections must still be there.
    assert.ok(
      index.some((e) => e.collection === "notes"),
      "ENTRY_COLLECTIONS coverage regressed — no notes entries in the built search index",
    );
  } finally {
    await rm(fixtureDir, { recursive: true, force: true });
  }
});
