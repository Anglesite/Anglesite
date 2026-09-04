# Blog System for the Base Template — Implementation Plan (#288)

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `BlogPost.astro` a real, rendered route by adding an Astro content collection, a `/blog/` index, a `/blog/<slug>/` post route, one starter post, and a homepage link — so every site has a working blog and giscus (shipped in #287) gets a host page.

**Architecture:** Pure Astro 5 content-collection wiring under `Resources/Template/src/`. Nothing in Swift/the engine changes — `BlogPost.astro` keeps its existing `// anglesite:imports` and `<!-- anglesite:comments -->` anchors, so the giscus descriptor's `injectAtAnchor` keeps working against a route that now actually renders. Automated regression guards are hermetic Swift tests that mirror `IntegrationTemplateAssetsTests`; the real build is proven by a scripted Astro build smoke.

**Tech Stack:** Astro `^5.0.0`, TypeScript, Swift Testing (`@Test`). Spec: `docs/superpowers/specs/2026-06-21-blog-system-design.md`.

## Global Constraints

- **Worktree:** `/Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/288-blog-system`, branch `feat/288-blog-system`. `cd` here before any git op.
- **Template-side only.** No Swift/engine source changes (only a new test file). Do **not** touch the giscus descriptor, `MarkerInjector`, or `IntegrationScaffolder`.
- **Classic Foundation/Darwin APIs only in test bundles** — `URL(fileURLWithPath:)`, `appendingPathComponent(_:)`, `.path`. Never `URL(filePath:)`, `.appending(path:)`, `.path(percentEncoded:)`, `SIG_IGN`, `EPIPE` (they link `libswift_DarwinFoundation3.dylib`, absent on macOS-26 CI runners → whole bundle won't load).
- **`tsconfig` extends `astro/tsconfigs/strict` (`noUnusedLocals`)** — every imported symbol must be used.
- **Swift tests run with:** `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer ANGLESITE_PLUGIN_PATH=/Users/dwk/Developer/github.com/Anglesite/anglesite swift test --package-path .` (default toolchain is too old).
- **Minimal schema only:** `title`, `pubDate`, optional `description`, optional `draft`. No tags/author/hero-image (YAGNI; out of scope).
- **Commit trailer on every commit:** `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

## File structure

**`Resources/Template/` (create):**
- `src/content.config.ts` — Astro 5 content collection `blog` (glob loader + Zod schema).
- `src/content/blog/welcome-to-your-blog.md` — one starter post.
- `src/pages/blog/[...slug].astro` — post route, renders through `BlogPost.astro`.
- `src/pages/blog/index.astro` — blog index listing.

**`Resources/Template/` (modify):**
- `src/pages/index.astro` — add a `/blog/` nav link.

**Tests (create):**
- `Tests/AnglesiteCoreTests/BlogTemplateAssetsTests.swift` — hermetic structural guards.

No `scaffold.sh` change is needed: all new files live in `src/`, which is copied verbatim into every scaffold (only `scripts/scaffold.sh`, `scripts/themes.ts`, `integrations/`, `node_modules/`, `.DS_Store` are excluded).

---

## Task 1: Content collection + starter post

**Files:**
- Create: `Resources/Template/src/content.config.ts`
- Create: `Resources/Template/src/content/blog/welcome-to-your-blog.md`
- Test: `Tests/AnglesiteCoreTests/BlogTemplateAssetsTests.swift`

**Interfaces:**
- Produces: a `blog` collection (consumed by Task 2's routes via `getCollection("blog")`), with entry data shape `{ title: string; pubDate: Date; description?: string; draft: boolean }` and entry `id` derived from the Markdown filename (`welcome-to-your-blog`).

- [ ] **Step 1: Write the failing test** (create `Tests/AnglesiteCoreTests/BlogTemplateAssetsTests.swift`)

```swift
// Tests/AnglesiteCoreTests/BlogTemplateAssetsTests.swift
// Hermetic test — no app bundle or TemplateRuntime needed. Resolves the template
// by walking up from #filePath (Tests/AnglesiteCoreTests/ -> Tests/ -> repo root).
// Classic URL APIs only (see IntegrationTemplateAssetsTests / PR #283 CI notes).
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct BlogTemplateAssetsTests {

    private func templateRoot() -> URL {
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("Package.swift").path), "repo-root detection drifted")
        return repoRoot.appendingPathComponent("Resources/Template")
    }

    @Test func contentConfigDefinesBlogCollection() throws {
        let root = templateRoot()
        let cfg = root.appendingPathComponent("src/content.config.ts")
        #expect(FileManager.default.fileExists(atPath: cfg.path), "missing src/content.config.ts")
        let s = try String(contentsOf: cfg, encoding: .utf8)
        #expect(s.contains("defineCollection"))
        #expect(s.contains("glob("))
        #expect(s.contains("collections = { blog }"))
        // minimal schema fields
        for field in ["title:", "pubDate:", "description:", "draft:"] {
            #expect(s.contains(field), "schema missing \(field)")
        }
    }

    @Test func starterPostExistsWithRequiredFrontmatter() throws {
        let root = templateRoot()
        let post = root.appendingPathComponent("src/content/blog/welcome-to-your-blog.md")
        #expect(FileManager.default.fileExists(atPath: post.path), "missing starter post")
        let s = try String(contentsOf: post, encoding: .utf8)
        #expect(s.hasPrefix("---"), "post must start with frontmatter")
        #expect(s.contains("title:"))
        #expect(s.contains("pubDate:"))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter BlogTemplateAssetsTests`
Expected: FAIL — `missing src/content.config.ts` (and missing starter post).

- [ ] **Step 3: Create the content collection config** (`Resources/Template/src/content.config.ts`)

```ts
import { defineCollection, z } from "astro:content";
import { glob } from "astro/loaders";

// Blog posts live as Markdown in src/content/blog/. The glob loader derives each
// entry's `id` from its filename (e.g. welcome-to-your-blog.md -> "welcome-to-your-blog"),
// which becomes the /blog/<id>/ URL.
const blog = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/blog" }),
  schema: z.object({
    title: z.string(),
    pubDate: z.coerce.date(),
    description: z.string().optional(),
    draft: z.boolean().default(false),
  }),
});

export const collections = { blog };
```

- [ ] **Step 4: Create the starter post** (`Resources/Template/src/content/blog/welcome-to-your-blog.md`)

```markdown
---
title: "Welcome to your blog"
pubDate: 2026-01-01
description: "How to add and edit posts on your new Anglesite blog."
---

This is your blog's first post. Every Anglesite site comes with a blog ready to go.

## Adding a post

Create a new Markdown file in `src/content/blog/`. The file name becomes the
post's URL — `my-first-update.md` is published at `/blog/my-first-update/`.

Each post starts with frontmatter between `---` fences:

- **title** — shown as the heading and in the post list (required)
- **pubDate** — the publication date, e.g. `2026-01-15` (required)
- **description** — a one-line summary for search engines and previews (optional)
- **draft** — set to `true` to keep a post out of the build while you work on it (optional)

Write the post body in Markdown below the frontmatter. Delete this starter post
whenever you're ready to publish your own.
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter BlogTemplateAssetsTests`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/288-blog-system
git add Resources/Template/src/content.config.ts \
        Resources/Template/src/content/blog/welcome-to-your-blog.md \
        Tests/AnglesiteCoreTests/BlogTemplateAssetsTests.swift
git commit -m "feat(#288): blog content collection + starter post

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Blog routes (post page + index)

**Files:**
- Create: `Resources/Template/src/pages/blog/[...slug].astro`
- Create: `Resources/Template/src/pages/blog/index.astro`
- Test: `Tests/AnglesiteCoreTests/BlogTemplateAssetsTests.swift` (append two tests)

**Interfaces:**
- Consumes: the `blog` collection from Task 1 via `getCollection("blog")`; `BlogPost.astro` (`Props { title: string; description?: string }`, default slot inside `<article>` above `<!-- anglesite:comments -->`); `BaseLayout.astro` (same Props).
- Produces: built routes `/blog/` and `/blog/<id>/`. The post route is giscus's host page.

- [ ] **Step 1: Write the failing tests** (append to `BlogTemplateAssetsTests.swift`, inside the `@Suite struct`)

```swift
    @Test func postRouteRendersThroughBlogPostLayout() throws {
        let root = templateRoot()
        let route = root.appendingPathComponent("src/pages/blog/[...slug].astro")
        #expect(FileManager.default.fileExists(atPath: route.path), "missing post route")
        let s = try String(contentsOf: route, encoding: .utf8)
        // renders through BlogPost (the giscus host layout)
        #expect(s.contains("import BlogPost from \"../../layouts/BlogPost.astro\""))
        #expect(s.contains("getStaticPaths"))
        #expect(s.contains("getCollection(\"blog\""))
        // drafts excluded from the generated paths
        #expect(s.contains("draft"))
        // post body rendered into the layout slot
        #expect(s.contains("<Content />"))
        #expect(s.contains("<BlogPost"))
    }

    @Test func blogIndexListsCollection() throws {
        let root = templateRoot()
        let index = root.appendingPathComponent("src/pages/blog/index.astro")
        #expect(FileManager.default.fileExists(atPath: index.path), "missing blog index")
        let s = try String(contentsOf: index, encoding: .utf8)
        #expect(s.contains("import BaseLayout from \"../../layouts/BaseLayout.astro\""))
        #expect(s.contains("getCollection(\"blog\""))
        #expect(s.contains("/blog/"))
        #expect(s.contains("draft"))   // drafts filtered from the listing
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter BlogTemplateAssetsTests`
Expected: FAIL — `missing post route`, `missing blog index`.

- [ ] **Step 3: Create the post route** (`Resources/Template/src/pages/blog/[...slug].astro`)

```astro
---
import { getCollection, render } from "astro:content";
import BlogPost from "../../layouts/BlogPost.astro";

export async function getStaticPaths() {
  const posts = await getCollection("blog", ({ data }) => !data.draft);
  return posts.map((post) => ({ params: { slug: post.id }, props: { post } }));
}

const { post } = Astro.props;
const { Content } = await render(post);
---

<BlogPost title={post.data.title} description={post.data.description}>
  <Content />
</BlogPost>
```

- [ ] **Step 4: Create the blog index** (`Resources/Template/src/pages/blog/index.astro`)

```astro
---
import { getCollection } from "astro:content";
import BaseLayout from "../../layouts/BaseLayout.astro";

const posts = (await getCollection("blog", ({ data }) => !data.draft)).sort(
  (a, b) => b.data.pubDate.valueOf() - a.data.pubDate.valueOf(),
);
---

<BaseLayout title="Blog" description="Latest posts">
  <main>
    <h1>Blog</h1>
    {
      posts.length === 0 ? (
        <p>No posts yet. Add a Markdown file in <code>src/content/blog/</code> to get started.</p>
      ) : (
        <ul>
          {posts.map((post) => (
            <li>
              <a href={`/blog/${post.id}/`}>{post.data.title}</a>
              {post.data.description && <p>{post.data.description}</p>}
            </li>
          ))}
        </ul>
      )
    }
  </main>
</BaseLayout>
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter BlogTemplateAssetsTests`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/288-blog-system
git add Resources/Template/src/pages/blog/ Tests/AnglesiteCoreTests/BlogTemplateAssetsTests.swift
git commit -m "feat(#288): blog post route + index listing

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Homepage link + full build acceptance

**Files:**
- Modify: `Resources/Template/src/pages/index.astro`
- Test: `Tests/AnglesiteCoreTests/BlogTemplateAssetsTests.swift` (append one test)

**Interfaces:**
- Consumes: the `/blog/` route from Task 2.
- Produces: a homepage link to the blog; no new exported interface.

- [ ] **Step 1: Write the failing test** (append to `BlogTemplateAssetsTests.swift`)

```swift
    @Test func homepageLinksToBlog() throws {
        let root = templateRoot()
        let s = try String(contentsOf: root.appendingPathComponent("src/pages/index.astro"), encoding: .utf8)
        #expect(s.contains("href=\"/blog/\""), "homepage should link to /blog/")
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter BlogTemplateAssetsTests`
Expected: FAIL — `homepage should link to /blog/`.

- [ ] **Step 3: Add the nav link** (`Resources/Template/src/pages/index.astro`)

Replace the `<section class="hero">` block so it reads exactly:

```astro
    <section class="hero">
      <h1>Welcome</h1>
      <p>This site is ready to set up. Type <code>/start</code> in Claude Desktop to get started.</p>
      <p><a href="/blog/">Read the blog</a></p>
    </section>
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter BlogTemplateAssetsTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Astro build smoke acceptance** (scripted — scaffold a temp site, build, assert blog output + draft exclusion)

Run:

```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/288-blog-system/Resources/Template
SMOKE=$(mktemp -d)
zsh scripts/scaffold.sh --yes "$SMOKE"
cd "$SMOKE"
npm install --silent
# add a draft post that must NOT appear in the build
cat > src/content/blog/draft-post.md <<'MD'
---
title: "Hidden draft"
pubDate: 2026-02-01
draft: true
---
This should not be built.
MD
npm run build
echo "--- assertions ---"
test -f dist/blog/index.html && echo "OK index" || { echo "FAIL: no /blog/ index"; exit 1; }
test -f dist/blog/welcome-to-your-blog/index.html && echo "OK post" || { echo "FAIL: no post page"; exit 1; }
test ! -e dist/blog/draft-post/index.html && echo "OK draft excluded" || { echo "FAIL: draft was built"; exit 1; }
grep -q "/blog/welcome-to-your-blog/" dist/blog/index.html && echo "OK index links post" || { echo "FAIL: index missing post link"; exit 1; }
```

Expected: `OK index`, `OK post`, `OK draft excluded`, `OK index links post`. Clean up: `rm -rf "$SMOKE"`.

- [ ] **Step 6: Giscus end-to-end acceptance** (proves the #287 gap is closed — giscus now has a host page)

Run (continues conceptually from a fresh scaffold; the giscus injection is performed by the app's `IntegrationScaffolder`, so simulate its two writes — the import into `BlogPost.astro`'s `// anglesite:imports` anchor and the gated render at `<!-- anglesite:comments -->` — then build):

```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/288-blog-system/Resources/Template
GZ=$(mktemp -d)
zsh scripts/scaffold.sh --yes "$GZ"
cd "$GZ"
npm install --silent
# giscus config the app would write to .site-config
cat >> .site-config <<'CFG'
GISCUS_REPO=acme/site
GISCUS_REPO_ID=R_test
GISCUS_CATEGORY=Comments
GISCUS_CATEGORY_ID=DIC_test
GISCUS_MAPPING=pathname
CFG
# copy the staged Comments component (the app does this on-demand)
mkdir -p src/components
cp "$OLDPWD/integrations/components/Comments.astro" src/components/Comments.astro
# inject import + gated render into BlogPost.astro (mirrors IntegrationScaffolder)
perl -0pi -e 's{// anglesite:imports[^\n]*\n}{$&import Comments from "../components/Comments.astro";\nconst giscusRepo = readConfig("GISCUS_REPO");\n}' src/layouts/BlogPost.astro
perl -0pi -e 's{<!-- anglesite:comments -->}{{giscusRepo && <Comments repo={giscusRepo} repoId={readConfig("GISCUS_REPO_ID")} category={readConfig("GISCUS_CATEGORY")} categoryId={readConfig("GISCUS_CATEGORY_ID")} mapping={readConfig("GISCUS_MAPPING")} />}}' src/layouts/BlogPost.astro
# BlogPost.astro now imports readConfig — add the import alongside BaseLayout
perl -0pi -e 's{import BaseLayout from "./BaseLayout.astro";}{$&\nimport { readConfig } from "../../scripts/config.ts";}' src/layouts/BlogPost.astro
npm run build
grep -q "giscus.app/client.js" dist/blog/welcome-to-your-blog/index.html \
  && echo "OK giscus rendered on post page" \
  || { echo "FAIL: giscus not on post page"; exit 1; }
```

Expected: `OK giscus rendered on post page`. Clean up: `rm -rf "$GZ"`.

> **Note for the implementer:** Step 6 *simulates* the app-side injection to prove the host page works end-to-end; the exact `perl` rewrites approximate `IntegrationScaffolder`. If the real injected markup differs, the goal of the step is only to confirm that **a giscus-configured `BlogPost.astro` emits `giscus.app/client.js` into a built `/blog/<slug>/` page**. Adjust the injection lines to match the real descriptor output if needed; do not change `BlogPost.astro` in the committed template to make this pass.

- [ ] **Step 7: Full Swift suite green** (catch any template-fixture regressions in scaffolder/scanner/graph suites)

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer ANGLESITE_PLUGIN_PATH=/Users/dwk/Developer/github.com/Anglesite/anglesite swift test --package-path .`
Expected: all green. If `SiteScaffolderTests`, `SiteScaffolderPackageTests`, `IntegrationTemplateAssetsTests`, `TemplateRuntimeTests`, or any content-graph/scanner suite fails on the added `src/content/` + `src/pages/blog/` files, update that test's structural expectation to include the new blog files (do not remove the blog files).

- [ ] **Step 8: Commit**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/288-blog-system
git add Resources/Template/src/pages/index.astro Tests/AnglesiteCoreTests/BlogTemplateAssetsTests.swift
git commit -m "feat(#288): link homepage to blog; build + giscus acceptance

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Acceptance (maps to spec)

1. **Fresh scaffold builds the blog** — Task 3 Step 5 (`OK index`, `OK post`).
2. **giscus end-to-end (closes #287 gap)** — Task 3 Step 6 (`OK giscus rendered on post page`).
3. **Draft exclusion** — Task 3 Step 5 (`OK draft excluded`).
4. **Swift suite stays green** — Task 3 Step 7.

## Out of scope (do not implement)

- Richer frontmatter (tags + tag pages, author, hero image, `updatedDate`).
- RSS feed, pagination, reading-time.
- Any change to the giscus descriptor, `MarkerInjector`, `IntegrationScaffolder`, or other Swift/engine source.

---

## Task 4: Fix duplicate giscus anchor in `BlogPost.astro` (added post-review)

**Why:** Discovered during Task 3 review. The giscus descriptor (`IntegrationCatalog.swift:145`) injects at anchor `<!-- anglesite:comments -->` into `src/layouts/BlogPost.astro`, and `MarkerInjector.inject` finds the anchor with `content.range(of: anchor)` — the **first** occurrence. `BlogPost.astro` contains that exact string **twice**: once in the frontmatter `//` doc-comment (line 5) and once as the real HTML body anchor (line 21). So real giscus setup injects into the **frontmatter**, not the body — giscus never renders. This is a pre-existing latent bug (from #287) that #288 makes live, and it defeats the feature's purpose. The same doc-comment is now factually wrong (it says the blog is "follow-up work… Tracked separately" — that work is this branch). This task is a deliberate, reviewed exception to the "do not touch `BlogPost.astro`" constraint.

**Files:**
- Modify: `Resources/Template/src/layouts/BlogPost.astro` (frontmatter doc-comment only — anchors and code untouched)
- Test: `Tests/AnglesiteCoreTests/BlogTemplateAssetsTests.swift` (append one behavioral test)

**Interfaces:**
- Consumes: `MarkerInjector.inject(snippet:withID:atAnchor:into:style:)` (real AnglesiteCore symbol; `@testable import AnglesiteCore` already present in the test file).

- [ ] **Step 1: Write the failing test** (append to `BlogTemplateAssetsTests.swift`)

This is behavioral: it runs the real injector against the real layout and asserts the giscus block lands in the body (after the Astro frontmatter fence), not in the frontmatter.

```swift
    @Test func giscusInjectsIntoBodyNotFrontmatter() throws {
        // MarkerInjector matches the FIRST occurrence of the anchor. If the anchor text
        // also appears in BlogPost.astro's frontmatter doc-comment, giscus injects into
        // the frontmatter and never renders. Guard the real layout against that regression.
        let root = templateRoot()
        let src = try String(contentsOf: root.appendingPathComponent("src/layouts/BlogPost.astro"), encoding: .utf8)
        let out = try MarkerInjector.inject(
            snippet: "<Comments />", withID: "comments",
            atAnchor: "<!-- anglesite:comments -->", into: src, style: .html).get()
        let frontmatterClose = out.range(of: "\n---\n")  // closing fence of Astro frontmatter
        let injected = out.range(of: "<Comments />")
        #expect(frontmatterClose != nil, "BlogPost.astro should have an Astro frontmatter fence")
        #expect(injected != nil, "injected giscus snippet should be present")
        #expect(injected!.lowerBound > frontmatterClose!.upperBound,
                "giscus must inject into the <article> body, not the frontmatter — a duplicate anchor in a frontmatter comment makes the first-match injector target the wrong spot")
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter BlogTemplateAssetsTests`
Expected: FAIL on `giscusInjectsIntoBodyNotFrontmatter` — the injected `<Comments />` lands before the frontmatter close (first anchor match is the line-5 doc-comment).

- [ ] **Step 3: Rewrite the frontmatter doc-comment** (`Resources/Template/src/layouts/BlogPost.astro`)

Replace the comment block at the top of the frontmatter (the six `//` lines from `// BlogPost.astro — giscus injection target.` through `// and the asset test passes. Tracked separately.`) with this — note it must **not** contain the literal string `<!-- anglesite:comments -->`:

```astro
---
// BlogPost.astro — layout for an individual blog post. The post route
// src/pages/blog/[...slug].astro renders through this layout; the Markdown body
// fills the <slot/>, and the comments anchor in the <article> below is where the
// giscus integration injects its widget when comments are set up.
import BaseLayout from "./BaseLayout.astro";
```

Leave everything else unchanged — the `// anglesite:imports` anchor (frontmatter), the `Props` interface, `const { title, description }`, and the real `<!-- anglesite:comments -->` body anchor inside `<article>` all stay exactly as they are.

- [ ] **Step 4: Run the test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter BlogTemplateAssetsTests`
Expected: PASS (6 tests). The anchor now appears once, so the injector targets the body.

- [ ] **Step 5: Full Swift suite green** (the `IntegrationTemplateAssetsTests.layoutsHaveImportAndBodyAnchors` test asserts BlogPost.astro still contains `// anglesite:imports` and `<!-- anglesite:comments -->` — both remain, so it must still pass)

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer ANGLESITE_PLUGIN_PATH=/Users/dwk/Developer/github.com/Anglesite/anglesite swift test --package-path .`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/288-blog-system
git add Resources/Template/src/layouts/BlogPost.astro Tests/AnglesiteCoreTests/BlogTemplateAssetsTests.swift
git commit -m "fix(#288): remove duplicate giscus anchor from BlogPost.astro frontmatter comment

The anchor text appeared in both the doc-comment and the body, so MarkerInjector
(first-match) injected giscus into the frontmatter. Rewrite the now-stale comment
so the anchor occurs once and giscus lands in the post body.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```
