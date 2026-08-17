// Resources/Template/src/layouts/webmcp.build.test.ts
//
// Build-level test for the experimental.webmcp flag (#1279): with the flag on, every page must
// carry a bundled <script type="module"> that registers the two anglesite_ tools; with the flag
// off (the default), no page may reference any such script at all — the feature must be
// completely inert for a site that hasn't opted in.
import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, cp, writeFile, readFile, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

// Resources/Template/ — two `..` up from src/layouts/
const TEMPLATE_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

const EXCLUDED = /(^|\/)(node_modules|dist|\.astro|\.wrangler)(\/|$)/;

/** Every `src` attribute of a `type="module"` `<script>` tag in an HTML document — attribute
 * order and any extra attributes Astro adds (e.g. crossorigin) are deliberately not assumed. */
function scriptSrcs(html: string): string[] {
  return [...html.matchAll(/<script[^>]*\btype="module"[^>]*\bsrc="([^"]+)"[^>]*>/g)].map((m) => m[1]);
}

/** Recursively lists every file under `dirPath` — used to check the *entire* build output (not
 * just the one HTML page's own <script> references) for a leaked, unreferenced chunk: Astro
 * bundles every <script> it finds in a component's template regardless of a surrounding runtime
 * conditional, so a chunk can end up physically present in `dist/` without any page's HTML ever
 * linking to it. */
async function listFilesRecursively(dirPath: string): Promise<string[]> {
  const entries = await readdir(dirPath, { withFileTypes: true });
  const files: string[] = [];
  for (const entry of entries) {
    const full = join(dirPath, entry.name);
    if (entry.isDirectory()) {
      files.push(...(await listFilesRecursively(full)));
    } else if (entry.isFile()) {
      files.push(full);
    }
  }
  return files;
}

test("experimental.webmcp: off by default, no script emitted anywhere", async () => {
  const fixtureDir = await mkdtemp(join(tmpdir(), "anglesite-webmcp-off-fixture-"));
  try {
    await cp(TEMPLATE_ROOT, fixtureDir, {
      recursive: true,
      filter: (src) => !EXCLUDED.test(src.slice(TEMPLATE_ROOT.length)),
    });

    execFileSync("npm", ["install", "--no-audit", "--no-fund", "--prefer-offline"], {
      cwd: fixtureDir,
      stdio: "inherit",
    });
    execFileSync("npx", ["astro", "build"], { cwd: fixtureDir, stdio: "inherit" });

    const html = await readFile(join(fixtureDir, "dist/notes/hello-note/index.html"), "utf8");
    assert.doesNotMatch(html, /modelContext/, "no page may reference modelContext when the flag is off");
    for (const src of scriptSrcs(html)) {
      const chunk = await readFile(join(fixtureDir, "dist", src.replace(/^\//, "")), "utf8").catch(() => "");
      assert.doesNotMatch(
        chunk,
        /anglesite_search_posts/,
        `bundled script ${src} must not be the webmcp tool script when the flag is off`,
      );
    }

    // Astro bundles every <script> it finds in a component's template regardless of a
    // surrounding runtime conditional — it can't know the flag's value at its own compile step.
    // The HTML-only checks above only catch a *referenced* leak; this walks the entire dist/
    // tree so an orphan chunk (compiled but linked from no page) can't slip through unnoticed.
    const distDir = join(fixtureDir, "dist");
    for (const file of await listFilesRecursively(distDir)) {
      const content = await readFile(file, "utf8").catch(() => "");
      assert.doesNotMatch(
        content,
        /anglesite_search_posts/,
        `${file.slice(distDir.length)} must not contain the webmcp tool script when the flag is off, even unreferenced`,
      );
    }
  } finally {
    await rm(fixtureDir, { recursive: true, force: true });
  }
});

test("experimental.webmcp: true emits a script registering both anglesite_ tools", async () => {
  const fixtureDir = await mkdtemp(join(tmpdir(), "anglesite-webmcp-on-fixture-"));
  try {
    await cp(TEMPLATE_ROOT, fixtureDir, {
      recursive: true,
      filter: (src) => !EXCLUDED.test(src.slice(TEMPLATE_ROOT.length)),
    });
    await writeFile(
      join(fixtureDir, "anglesite.json"),
      JSON.stringify({ version: 1, experimental: { webmcp: true } }),
      "utf8",
    );

    execFileSync("npm", ["install", "--no-audit", "--no-fund", "--prefer-offline"], {
      cwd: fixtureDir,
      stdio: "inherit",
    });
    execFileSync("npx", ["astro", "build"], { cwd: fixtureDir, stdio: "inherit" });

    const html = await readFile(join(fixtureDir, "dist/notes/hello-note/index.html"), "utf8");
    const srcs = scriptSrcs(html);
    assert.ok(srcs.length > 0, "the page must carry at least one bundled <script type=\"module\">");

    let found = false;
    for (const src of srcs) {
      const chunk = await readFile(join(fixtureDir, "dist", src.replace(/^\//, "")), "utf8").catch(() => "");
      if (chunk.includes("anglesite_search_posts") && chunk.includes("anglesite_fetch_post_markdown")) {
        found = true;
        assert.match(chunk, /modelContext/, "the bundled script must reference document.modelContext");
      }
    }
    assert.ok(found, "no bundled script chunk contained both anglesite_ tool names");
  } finally {
    await rm(fixtureDir, { recursive: true, force: true });
  }
});
