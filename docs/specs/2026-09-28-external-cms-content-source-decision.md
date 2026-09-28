# External CMS as a content source: build from the API, export to git

**Date:** 2026-09-28
**Status:** draft
**Issue:** #2050 (related: #2051, #2052, #2053; precedent: #72, #799, #912)

## Context

A writer-heavy team (the motivating case is a local news outlet) needs browser logins, roles,
drafts, review and scheduling for a dozen writers, none of whom should need a Mac, the app, or
git. [EmDash 1.0](https://blog.cloudflare.com/emdash-cms-plugin-registry/) (MIT, Astro-based,
Workers + D1 + R2, runs the Cloudflare Blog) provides that. #2050 proposes letting a site hand
some of its collections to an external CMS. EmDash is the first adapter. Anglesite keeps the
design, the social/protocol Worker, provisioning, the pre-deploy gate and deploy.

#2050 posed two options:

- **A — Git mirror.** An EmDash publish triggers an export (Portable Text → Markdown +
  frontmatter). The export is committed to `Source/`, and the site builds from `glob()` as today.
- **B — Live source.** The build reads EmDash's API through an Astro content-layer loader.

#2050 recommended A, because A appeared to keep git canonical (#72). That framing missed two
things already in the tree:

1. **The owner has already decided canonicality for provisioned sites.** The 2026-07-17
   publishing design, [§C.1](../superpowers/specs/2026-07-17-blog-markdown-editor-publishing-design.md#c1-invariant),
   records owner decisions: *typed content is canonical in the owner's Cloudflare account once a
   site's publishing features are provisioned, git remains canonical for code/theme, and content
   is continuously exported to git*. [§C.4](../superpowers/specs/2026-07-17-blog-markdown-editor-publishing-design.md#c4-the-cms-data-path-per-site-worker-users-cloudflare-account)
   builds that model: a Worker-triggered bake, a content-layer loader, and one-way export to git.
2. **The loader seam from option B exists.** [`content.config.ts`](../../Resources/Template/src/content.config.ts)
   picks [`createContentAPILoader`](../../Resources/Template/src/lib/content-loader.ts) when
   `.site-config`'s `CMS_CONTENT_API_URL` is set (#799), and uses `glob()` otherwise. The loader
   already fails the build loudly when the CMS is unreachable, instead of shipping empty
   collections.

With an external CMS, the CMS is where writers write, in either option. Git cannot be the write
path for those collections unless git edits sync back into EmDash, and §C.4 rules out a two-way
mirror. So the real question is narrower than "is git canonical?": **what does the build read,
and which copy wins when they disagree?**

## Decision (proposed)

**Option B, with §C.4's continuous export.** For each collection a site assigns to an external
CMS:

1. **EmDash is canonical** for that collection's entries and media. This is the §C.1 rule, with
   EmDash in the role `@dwk/micropub` plays for self-hosted CMS mode. Every collection has
   exactly one content source. There are no mixed collections.
2. **The build reads EmDash** through a template loader (`createEmDashLoader`) beside
   `createContentAPILoader`, selected per collection from `.site-config`. It inherits the
   existing contracts: server-side draft filtering, the same zod `.strict()` schema, and a build
   that fails loudly when EmDash is unreachable. When a bake fails, the last good deploy stays
   live.
3. **The export to git is one-way and continuous.** It reuses the #587/#912 committer shape
   ([Micropub content sync](../superpowers/specs/2026-07-24-micropub-content-sync-design.md)):
   reconcile the full current set into `src/content/<collection>/`, write changed files, delete
   stale ones, make one batched commit, and do nothing when nothing changed. Exported files use
   the exact layout `glob()` reads. Unsetting the collection's content source therefore turns the
   export into the build input with no conversion. That is the "the site outlives the vendor"
   guarantee (#72, §C.4.3), and it makes the guarantee something you can test, not just a promise.
4. **The gate is unchanged.** The pre-deploy check scans `dist/`, so EmDash content goes through
   the same `build:ci` gate as everything else (D5). Nothing here adds a bypass.
5. **App editing surfaces:** collections owned by an external source are read-only in the app's
   editors, with an "Edit in EmDash" action. The block editor remains the only in-app editing
   surface for pages, layout and every app-owned collection (D4).

## Why B over A

| | A — build from git mirror | B — build from API + export |
|---|---|---|
| Consistent with the §C.1 owner decision | ✗ adds a second, contradictory canonicality rule | ✓ same rule as self-hosted CMS mode |
| Corrections and retractions | Wait for export → commit → build. A stale checkout can rebuild retracted copy | Next bake reads current state. The export's delete-stale step keeps git in step |
| Credentials | Webhook receiver needs **push** access to the site repo | Bake needs a **read** token for EmDash, and export uses the existing sync path |
| Git history | Every typo fix from every writer becomes a commit | Batched export commits |
| New code | Webhook receiver + exporter + commit path | EmDash loader + exporter. The seam, fail-loud behaviour and committer shape exist |
| Build without EmDash | ✓ always | ✓ after switching the collection to `glob()` over the export |
| Offline or cloned builds | ✓ | Only against the export, which may lag (open question 3) |

Retractions are the deciding row for the motivating audience. A newsroom's corrections and legal
takedowns must reach the live site without depending on a git round-trip, and a rebuild from a
stale copy must never be able to republish retracted content.

## Consequences

- **#2050 changes from A to B.** The Portable Text → Markdown converter from #2051 becomes shared
  by the export and the loader, which renders Portable Text to the body shape the templates expect.
- **Where EmDash runs.** Anglesite can provision EmDash as a separate Worker + D1 + R2 in the
  owner's Cloudflare account, with its admin on a subdomain such as `cms.<domain>`. The owner
  never configures it (D1). Alternatively the site can point at an existing EmDash install. Both
  expose the same API to the loader. The public site stays Anglesite's static build plus the
  per-site social Worker. EmDash's server-rendered frontend is not used.
- **Schema mapping is explicit.** Each EmDash collection maps to a `ContentTypeRegistry` type.
  Because the zod schemas are `.strict()`, an unmapped EmDash field fails the build instead of
  silently dropping, so the mapping is a checked artifact, not a best guess. mf2 and JSON-LD
  projection follow [C.1](2026-06-29-c1-indieweb-content-model-decision.md) unchanged.
- **Bakes are Worker-triggered** (§C.4 step 2): an EmDash publish webhook goes to the control
  Worker, which starts a debounced bake. This inherits the Workers paid-plan requirement, surfaced
  in onboarding.
- **EmDash plugins are EmDash's concern.** They run in EmDash's own sandbox. #2052 and #2053
  cover Anglesite's Worker integrations, not EmDash's.
- **Wording to reconcile on acceptance.** `AGENTS.md` ▸ "Git is the source of truth" still reads
  as unconditional, while §C.1 already made provisioned typed content Cloudflare-canonical, and
  the Micropub sync design still calls git canonical. Accepting this record should amend those to
  one sentence: *git is canonical for code/theme and for content no external or provisioned
  source owns; every other collection is exported to git continuously.*

## Alternatives rejected

- **A — Git mirror as build input.** See the table above.
- **Two-way sync between EmDash and git.** Two writers with a merge in between is exactly the
  adjudication D1 says the owner must never face. §C.4 already rejects it.
- **EmDash as the whole site runtime** (its server-rendered Astro frontend replaces the static
  template). This gives up the static build, the template, the block editor and the Worker
  composition for every site to serve the team case. It was evaluated and rejected before #2050
  was filed.

## Open questions for the owner

1. Accept B as the model for external content sources?
2. Should v1 support provisioned EmDash, bring-your-own EmDash, or both?
3. **Export cadence.** Today exports sync to `Source/` when the Mac app opens a site (the #587
   pattern, desktop-only per the 2026-07-17 decision). A team that rarely opens the Mac app would
   let the git copy drift for weeks. Should the bake also write the export to R2 (the bake already
   holds the content), so any desktop open, or a server-side commit to the site's remote, catches
   up from one artifact?
4. **Media.** Should the build hotlink EmDash's R2 media, or localize it into the build (the
   export localizes it into `Source/` in either case)?
