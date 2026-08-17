// Resources/Template/src/pages/_markdown-mirror.build.test.ts
//
// Build-level test for the WebMCP markdown-mirror routes (#1279): a real `astro build` must
// emit a `.md` sibling for the blog's seed post and for one representative ENTRY_COLLECTIONS
// entry of each distinct title/date-field shape (events: name/start, reviews: itemReviewed,
// notes: titleless with tags) — pure unit coverage of the field mapping already lives in
// markdown-mirror.test.ts; this only proves the two route files actually wire it in.
import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, cp, readFile, rm, access } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

// Resources/Template/ — two `..` up from src/pages/
const TEMPLATE_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

const EXCLUDED = /(^|\/)(node_modules|dist|\.astro|\.wrangler)(\/|$)/;

test("markdown-mirror routes emit .md siblings for blog and entry-collection pages", async () => {
  const fixtureDir = await mkdtemp(join(tmpdir(), "anglesite-markdown-mirror-fixture-"));
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

    // blog
    {
      const md = await readFile(join(fixtureDir, "dist/blog/welcome-to-your-blog.md"), "utf8");
      assert.match(md, /^---\ntitle: "Welcome to your blog"\ndate: 2026-01-01T00:00:00\.000Z\n---\n\n/);
      assert.match(md, /This is your blog's first post\./);
      assert.equal((await readFile(join(fixtureDir, "dist/blog/welcome-to-your-blog.md"))).length > 0, true);
    }

    // events: name -> title, start -> date (seed content's actual name is "Hello, event" —
    // verified against src/content/events/hello-event.md, not a guessed value)
    {
      const md = await readFile(join(fixtureDir, "dist/events/hello-event.md"), "utf8");
      assert.match(md, /^---\ntitle: "Hello, event"\n/);
    }

    // reviews: itemReviewed -> title
    {
      const md = await readFile(join(fixtureDir, "dist/reviews/hello-review.md"), "utf8");
      assert.match(md, /^---\ntitle: /);
    }

    // notes: no title field, has tags
    {
      const md = await readFile(join(fixtureDir, "dist/notes/hello-note.md"), "utf8");
      assert.doesNotMatch(md, /^---\ntitle:/);
      assert.match(md, /tags: \["hello", "hello world"\]/);
    }

    // Content-Type is asserted indirectly: the response headers aren't captured by a static
    // build (there's no server to observe), so this build-fixture test only proves the *body*
    // is correct; markdown-mirror.test.ts's MARKDOWN_MIRROR_CONTENT_TYPE assertion plus a code
    // read of the two route files (blog/[...slug].md.ts, [collection]/[...slug].md.ts) cover the
    // header itself.

    // A page must not exist for a route these endpoints don't cover.
    await assert.rejects(access(join(fixtureDir, "dist/blog/nonexistent-post.md")));
  } finally {
    await rm(fixtureDir, { recursive: true, force: true });
  }
});
