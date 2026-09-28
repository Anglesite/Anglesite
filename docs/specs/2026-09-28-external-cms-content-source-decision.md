# EmDash sites: a separate, server-rendered site kind

**Date:** 2026-09-28
**Status:** current
**Issue:** #2050 (related: #2051, #2052, #2053; precedent: #72, #799)

## Context

"Decision D1/D4/D5" below refers to the owner decisions in the
[2026-09-08 product direction review](2026-09-08-product-direction-review-decisions.md): D1
(Anglesite manages infrastructure; the owner never adjudicates git or infra), D4 (the block editor
is the only editing surface) and D5 (the pre-deploy gate is pinned and cannot be bypassed).
Unprefixed "D1" and "R2" are Cloudflare's database and object storage.

A writer-heavy team (the motivating case is a local news outlet) needs browser logins, roles,
drafts, review and scheduling for a dozen writers, none of whom should need a Mac, the app, or
git. [EmDash 1.0](https://blog.cloudflare.com/emdash-cms-plugin-registry/) (MIT, Astro-based,
Workers + D1 + R2, runs the Cloudflare Blog) provides that. #2050 proposed letting a site hand
some of its collections to EmDash, and posed two options:

- **A — Git mirror.** An EmDash publish triggers an export (Portable Text → Markdown +
  frontmatter). The export is committed to `Source/`, and the site builds from `glob()` as today.
- **B — Live source.** The build reads EmDash's API through an Astro content-layer loader.

The owner decided four things on 2026-09-28:

1. **No hybrid sites.** A site is either an Anglesite site or an EmDash site. A news site
   publishing dozens of illustrated articles a day quickly grows too large for the git-backed
   model. Per-collection mixing, and any continuous content export into `Source/`
   ([§C.1](../superpowers/specs/2026-07-17-blog-markdown-editor-publishing-design.md#c1-invariant),
   [§C.4](../superpowers/specs/2026-07-17-blog-markdown-editor-publishing-design.md#c4-the-cms-data-path-per-site-worker-users-cloudflare-account)),
   would carry that volume into the repo.
2. **EmDash sites are server-rendered.** A static bake that rebuilds every page per publish only
   moves the growth problem from repo size to build minutes.
3. **Decision D5's gate is re-scoped** to fit a site with no complete build output (§ Gate below).
4. **Both provisioned and bring-your-own EmDash are supported** (decision 7 below).

Option A is rejected (git as the build input is the growth problem), and so is the static-bake
form of option B.

## Decision

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
4. **EmDash sites are server-rendered.** The site runs as Astro SSR on Workers against EmDash,
   using KV / Workers Cache (how the Cloudflare Blog runs). Pages that don't depend on content
   (`/.well-known/*`, `robots.txt`, `rsl.xml`, static pages) stay **prerendered**, so they remain
   files the deploy gate can scan. Corrections and retractions take effect when the cache is
   purged on publish or unpublish.
5. **Portability comes from EmDash, not a git mirror.** EmDash is MIT-licensed and open source,
   and its content lives in the owner's own D1/R2. Leaving EmDash means reading that store
   through EmDash's API or a database dump via the Portable Text rung (#2051), into a new
   Anglesite site. Nothing about portability relies on a continuously growing mirror.
6. **App editing surfaces.** An EmDash site hides the app's typed-content editors entirely and
   offers "Open EmDash" instead. Writers and editors work in EmDash's admin. The block editor
   (decision D4) stays the owner's surface for what git still holds: pages, layout and theme.
7. **Two ways to get an EmDash site, one runtime.** Both end in the same shape: an EmDash Worker
   in the owner's Cloudflare account, serving Anglesite's template server-side, with
   `anglesite-gate` registered.
   - **Provisioned.** Anglesite creates EmDash (Worker + D1 + R2) in the owner's account and deploys
     it with the template. The owner never configures it (decision D1). This is the default for a
     new EmDash site.
   - **Bring your own.** The owner connects an existing EmDash install that runs in a Cloudflare
     account they control, through the same token onboarding Anglesite already uses for
     deploys. Anglesite then takes over the site's frontend deploy and registers `anglesite-gate`.
     The install's content, users, roles and other plugins are kept. Before connecting, the app
     says in plain terms that the site's design will switch to the Anglesite theme.
   - **Refused:** installs Anglesite can't deploy to, such as EmDash hosted by a third-party
     platform. Anglesite can't guarantee the gate there, so it offers #2051's import into a new
     site instead.

## Gate: decision D5 re-scoped for server rendering

Today [`pre-deploy-check.ts`](../../Resources/Template/scripts/pre-deploy-check.ts) runs one
scan over the full `dist/` before every deploy. On an EmDash site, articles don't exist at deploy
time, so the gate moves to **wherever content becomes public**. D5's properties are unchanged
across all three layers:
- It is deterministic and has no LLM.
- The check code is pinned by hash.
- The owner cannot override it.
- Failures are shown to the person who can fix them.

**One pinned check module.** The per-document checks are already pure functions of
`(content, file)`: `checkSecrets`, `checkPII`, `checkEmbedMedia`, `checkMixedContent`,
`checkSRI`, `checkExternalLinkRel`, `checkNoRestrictedContentIn*`, and the blocked-script and
blocked-route patterns. Move them into a runtime-neutral module under `scripts/` (no `node:`
imports) so Node and Workers run the *same* code. The module is part of the app-owned
`scripts/` set, so decision D5's hash pin covers it.

| Layer | When | What it scans | Checks | On failure |
|---|---|---|---|---|
| **1. Deploy** (`build:ci`, unchanged entry point) | Before every deploy of code/theme | `Source/` (the existing `--source` sweep), prerendered `dist/` files, and the **server bundle** | Everything today, except that per-article checks apply only to what exists (templates, prerendered pages, bundle). Additionally: the bundle's check module matches the pin, and the publish-gate plugin is registered | Deploy refused (as today) |
| **2. Publish** (`anglesite-gate` EmDash plugin) | `content:beforePublish` and `content:beforeSchedule`, re-run when a scheduled post comes due | The entry's fields, with Portable Text rendered to HTML | Content checks: secrets, PII, embed-media hotlinks, mixed content, restricted-visibility content. Same severity policy as `build:ci --strict` | Publish cancelled via `{ cancel: true, reason }`, with the reason in writer terms in EmDash's editor |
| **3. Render backstop** (SSR Worker) | Before a rendered page enters the cache | The rendered HTML response | Error-severity checks only: secrets, restricted content, blocked admin routes | Page withheld (not cached, served as unavailable) and the owner is alerted. It fails closed |

Why three layers:
- **Publish** is the real gate. It stops the problem before a reader can see it, and it tells the
  writer, not the owner, what to fix.
- **Render** covers what bypasses publish hooks: API or database writes, a template change that
  exposes a field, or a plugin misconfiguration. It is limited to error-severity checks so that
  its per-render cost, amortized by the cache, stays small.
- **Deploy** still guards the code, the part of the site git holds.

**The plugin is not optional.** `anglesite-gate` is registered in the site's configuration (code),
not installed through EmDash's admin, so an EmDash administrator can't remove it. Removing it is a
code change, and layer 1 refuses to deploy one. Its manifest requests only
`hooks.content-policy:register`, `content:read` and `schema:read`, with no network access
([EmDash plugin capabilities](https://github.com/emdash-cms/emdash/blob/main/skills/creating-plugins/SKILL.md)).
It is a sandboxed EmDash plugin like any other.

## Rationale for server rendering

| | Static bake (loader seam, Worker-triggered builds) | **Server rendering (chosen)** |
|---|---|---|
| Fits the growth constraint | ✗ full rebuild per publish grows with the archive | ✓ per-request render + cache |
| Retractions and corrections | Wait for the next bake | Take effect on cache purge |
| Reuses Anglesite's template | ✓ as-is | Mostly: the template runs under an SSR adapter, with content-free routes prerendered |
| Pre-deploy gate (decision D5) | ✓ unchanged | Re-scoped to three layers (above) |
| mf2 / JSON-LD / feeds ([C.1 content-model decision](2026-06-29-c1-indieweb-content-model-decision.md)) | ✓ unchanged | Rendered server-side from the same schemas |
| Hosting | Static assets + social Worker | EmDash Worker + D1 + R2 + cache, provisioned by Anglesite (decision D1) |

## Consequences

- **#2050** narrows from "external CMS per collection" to "EmDash as a server-rendered site
  kind". The `CMS_CONTENT_API_URL` loader seam remains §C.4 CMS mode's path and is not used by
  EmDash sites.
- **#2051** (the Portable Text import rung) becomes the main way out of an EmDash site. Its
  Portable Text → HTML renderer is shared with the publish gate.
- **Gate work.** Extract the check module, add bundle and prerender scanning to layer 1, build
  `anglesite-gate` (layer 2), and add the render backstop (layer 3). This lands as its own issue
  before any EmDash site can deploy.
- **Composition.** The EmDash Worker *is* the public site. The per-site social Worker
  (Webmention, ActivityPub, IndieAuth) is composed alongside it or routed in front of it.
- **Audience-limited posts** (#1568) aren't offered on EmDash sites until the render backstop and
  an IndieAuth read gate exist on the SSR path. The restricted-content check is what enforces
  that.
- **Schema mapping is explicit.** EmDash collections map to `ContentTypeRegistry` types.
  Unmapped fields fail loudly rather than silently dropping.
- **Other EmDash plugins are EmDash's concern**, running in its own sandbox. #2052 and #2053
  cover Anglesite's Worker integrations.
- **Wording.** `CLAUDE.md`/`AGENTS.md` and `CONTRIBUTING.md` are amended in the same change:
  - Git is canonical for code/theme on every site, and for content on Anglesite sites.
  - The gate is enforced at deploy, and on EmDash sites also at publish and render.

## Alternatives rejected

- **A — Git mirror as build input.** Carries the full content and artwork volume into the repo,
  which is what the owner constraint forbids.
- **Hybrid sites and continuous export of EmDash content to git.** Ruled out by the owner
  constraint for the same reason.
- **Static bake for EmDash sites.** Build time grows with the archive (owner decision above).
- **Deploy-only gate with a scheduled crawler.** Detects problems after readers have seen them.
  Decision D5 requires the gate to stand in front of publication.
- **Two-way sync between EmDash and git.** Two writers with a merge in between is exactly the
  adjudication decision D1 says the owner must never face.
