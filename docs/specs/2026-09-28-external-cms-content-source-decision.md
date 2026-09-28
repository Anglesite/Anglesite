# EmDash sites: a separate site kind, never a hybrid

**Date:** 2026-09-28
**Status:** draft
**Issue:** #2050 (related: #2051, #2052, #2053; precedent: #72, #799)

## Context

A writer-heavy team (the motivating case is a local news outlet) needs browser logins, roles,
drafts, review and scheduling for a dozen writers, none of whom should need a Mac, the app, or
git. [EmDash 1.0](https://blog.cloudflare.com/emdash-cms-plugin-registry/) (MIT, Astro-based,
Workers + D1 + R2, runs the Cloudflare Blog) provides that. #2050 proposed letting a site hand
some of its collections to EmDash, and posed two options:

- **A — Git mirror.** An EmDash publish triggers an export (Portable Text → Markdown +
  frontmatter). The export is committed to `Source/`, and the site builds from `glob()` as today.
- **B — Live source.** The build reads EmDash's API through an Astro content-layer loader.

The first draft of this record recommended B for EmDash-owned collections, plus the
2026-07-17 design's continuous export to git
([§C.1](../superpowers/specs/2026-07-17-blog-markdown-editor-publishing-design.md#c1-invariant),
[§C.4](../superpowers/specs/2026-07-17-blog-markdown-editor-publishing-design.md#c4-the-cms-data-path-per-site-worker-users-cloudflare-account)).

**Owner constraint (2026-09-28): a site is either an Anglesite CMS site or an EmDash site, never
a hybrid.** A news site publishing dozens of illustrated articles a day quickly grows too large
for the git-backed model. Per-collection mixing, and any continuous content export into
`Source/`, would carry that volume into the repo.

That rules out option A outright: git as the build input is exactly the growth problem. It also
removes the export half of the first draft's recommendation.

## Decision (proposed)

1. **Site kind is chosen once, for the whole site.** When a site is created, it is either an
   **Anglesite site** or an **EmDash site**:
   - An **Anglesite site** is today's model: git-backed files, or the self-hosted §C.4 CMS mode.
   - An **EmDash site** takes *all* of its authored content and media from EmDash.

   Collections are never split between sources. The kind is identity-level, recorded in the
   package marker (`Info.plist`) rather than `Config/settings.plist`, so a clone or import reads
   it back unambiguously. Changing kind is a migration (export from one, import into the other),
   not a toggle.
2. **In an EmDash site, EmDash is canonical for content and media.** The app never copies
   articles or artwork into `Source/`. Git holds only what the site *is* (theme, templates,
   configuration the template reads). By the
   [file-ownership test](2026-09-08-site-file-ownership-classification-decision.md), it stays a
   correct description of the site whatever the content volume.
3. **Media stays in EmDash's R2.** The site references it by URL. It is never localized into
   `Source/` or into the build output.
4. **Portability comes from EmDash, not a git mirror.** EmDash is MIT-licensed and open source,
   and its content lives in the owner's own D1/R2. Leaving EmDash means reading that store
   through EmDash's API or a database dump via the Portable Text rung (#2051), into a new
   Anglesite site. Nothing about portability relies on a continuously growing mirror.
5. **App editing surfaces.** An EmDash site hides the app's typed-content editors entirely and
   offers "Open EmDash" instead. Writers and editors work in EmDash's admin. The block editor
   (D4) stays the owner's surface for what git still holds: pages, layout and theme.
6. **The gate still runs on every deploy (D5).** How it applies depends on the rendering question
   below. Nothing here adds a bypass.

## Open question: how an EmDash site renders

The kind split moves the problem the owner raised from the repo to the build. A static bake
(§C.4 step 2, via the existing loader seam
[`createContentAPILoader`](../../Resources/Template/src/lib/content-loader.ts)) rebuilds every
page on every publish. At dozens of articles a day, the archive and the build time grow without
limit.

| | **R1 — Static bake** (loader seam, Worker-triggered builds) | **R2 — EmDash server rendering** (Astro SSR on Workers, KV / Workers Cache) |
|---|---|---|
| Fits the growth constraint | ✗ full rebuild per publish grows with the archive | ✓ per-request render + cache, which is how the Cloudflare Blog runs |
| Retractions and corrections | Wait for the next bake | Take effect on cache purge |
| Reuses Anglesite's template and static output | ✓ | Partly: the template must run under an SSR adapter |
| Pre-deploy gate (D5) | ✓ unchanged: scans `dist/` | Must be re-scoped. There is no full `dist/`, so the gate scans the code/theme bundle at deploy, and restricted content needs a runtime check |
| mf2 / JSON-LD / feeds ([C.1](2026-06-29-c1-indieweb-content-model-decision.md)) | ✓ unchanged | Must be rendered server-side from the same schemas |
| Hosting | Static assets + social Worker | EmDash Worker + D1 + R2 + cache, all provisioned by Anglesite (D1) |

**Leaning R2** for EmDash sites, because R1 recreates the growth problem in build minutes
instead of repo size. R2's cost is a real change to D5's gate model, which needs its own owner
sign-off. The earlier rejection of "EmDash as the whole site runtime" was about imposing it on
*every* site. With site kinds, it applies only to sites that chose EmDash.

## Consequences

- **#2050** narrows from "external CMS per collection" to "EmDash as a site kind". The loader
  seam stays the path for R1 and for §C.4 CMS mode.
- **#2051** (the Portable Text import rung) becomes the main way out of an EmDash site, not a
  shared export converter.
- **Where EmDash runs.** Either Anglesite provisions it in the owner's Cloudflare account (the
  owner never configures it, D1), or the site points at an existing install. Under R2, the
  EmDash Worker *is* the public site, and the per-site social Worker (Webmention, ActivityPub,
  IndieAuth) must be composed alongside it or routed in front of it.
- **Schema mapping is explicit.** EmDash collections map to `ContentTypeRegistry` types.
  Unmapped fields fail loudly rather than silently dropping.
- **EmDash plugins are EmDash's concern**, running in its own sandbox. #2052 and #2053 cover
  Anglesite's Worker integrations.
- **Wording to reconcile on acceptance.** `AGENTS.md` ▸ "Git is the source of truth" should say
  git is canonical for code/theme on every site and for content on Anglesite sites, while an
  EmDash site's content is canonical in EmDash. §C.1's continuous-export guarantee should be
  scoped to Anglesite CMS-mode sites.

## Alternatives rejected

- **A — Git mirror as build input.** Carries the full content and artwork volume into the repo.
  This is what the owner constraint forbids.
- **Hybrid sites** (per-collection EmDash plus Anglesite-owned collections), and **continuous
  export of EmDash content to git.** Both are ruled out by the owner constraint for the same
  reason.
- **Two-way sync between EmDash and git.** Two writers with a merge in between is exactly the
  adjudication D1 says the owner must never face.

## Open questions for the owner

1. Accept site kinds (Anglesite | EmDash) as the model?
2. Should EmDash sites use rendering **R1 (static bake)** or **R2 (EmDash server rendering)**,
   and if R2, how should the D5 gate be re-scoped?
3. Should v1 support provisioned EmDash, bring-your-own EmDash, or both?
