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

   The key is `AnglesiteSiteKind` (`anglesite` | `emdash`), modelled by
   `AnglesitePackage.SiteKind`. A marker with no key is an Anglesite site, which covers every
   package made before site kinds existed. EmDash markers are stamped `AnglesiteFormatVersion` 2,
   and Anglesite markers stay at 1. A build that predates site kinds (and ignores unknown keys)
   therefore keeps opening Anglesite sites normally. It opens an EmDash site read-only, through
   the existing too-new path, instead of treating its content as git-backed and deploying a
   static build over it. A kind this build doesn't recognise also opens read-only. The app's
   `Info.plist` editor exposes only the site title, so the kind can't be edited in-app.

   New Site asks the question once, as **Writers: Me, in Anglesite / A team, in EmDash**
   (`NewSiteDraft.siteKind`). An EmDash site is scaffolded without the template's starter
   entries (`EmDashScaffold`), per decision 2. Until the server-rendered template and
   provisioning land, `DeployCommand` refuses the static deploy for it
   (`SiteEditingSurfaces.staticDeploy`). A static build would replace the live site with one
   that has none of its articles.
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

   The template's EmDash overlay ([`Resources/Template/emdash/`](../../Resources/Template/emdash/))
   is how a new EmDash site gets this. `EmDashScaffold.applyTemplateOverlay` renames the
   template's `astro.config.ts` to `astro.anglesite.config.ts` and copies the overlay on top. The
   overlay's config adds the Cloudflare adapter and the EmDash integration (D1 `DB`, R2 `MEDIA`)
   and keeps Astro's default static output, so only routes that opt out render on request: the
   article index and article pages, rendered from EmDash's `articles` collection with the
   template's h-entry markup, and EmDash's own admin and API. `seed/seed.json` maps that
   collection's fields onto Anglesite's `articles` type. The overlay brings its own
   `package.json` and lockfile (the extra packages are approved for EmDash sites only), and
   dependency sync tracks it for EmDash sites. The Worker config stays out of `Source/`:
   provisioning writes it into `Config/`.
5. **Portability comes from EmDash, not a git mirror.** EmDash is MIT-licensed and open source,
   and its content lives in the owner's own D1/R2. Leaving EmDash means reading that store
   through EmDash's API or a database dump via the Portable Text rung (#2051), into a new
   Anglesite site. Nothing about portability relies on a continuously growing mirror.
6. **App editing surfaces.** An EmDash site hides the app's typed-content editors entirely and
   offers "Open EmDash" instead. Writers and editors work in EmDash's admin. The block editor
   (decision D4) stays the owner's surface for what git still holds: pages, layout and theme.

   `SiteEditingSurfaces` (AnglesiteCore) maps the site kind to these surfaces. The app reads it
   to disable or hide New Post, New Link Post, collection entries, the typed inspector form,
   Publish Post, Move to Drafts and link capture. `ContentCreationWorkflow` re-checks the
   package marker on every typed-content write, so Shortcuts and AppleScript are refused too.
   Pages, components and the site's h-card are not gated. Website ▸ Open EmDash opens
   `SiteSettings.emdashAdminURL` (https only), which provisioning or connecting EmDash writes.
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
| **2. Publish** (`anglesite-gate` EmDash plugin) | `content:beforePublish` and `content:beforeSchedule`, re-run when a scheduled post comes due | The draft's fields: text (Portable Text spans, link targets) and the URLs a page would load | Content checks: secrets, PII, embed-media hotlinks, mixed content, restricted-visibility content. Same severity policy as `build:ci --strict` | Publish cancelled via `{ cancel: true, reason }`, with the reason in writer terms in EmDash's editor |
| **3. Render backstop** (SSR Worker) | Before a rendered page enters the cache | The rendered HTML response | Error-severity checks only: secrets, restricted content, blocked admin routes | Page withheld (not cached, served as unavailable) and the owner is alerted. It fails closed |

**Layer 1 on a server-rendered build (#2055 slice 2).** `pre-deploy-check.ts` recognises the
server layout by any file only a server build writes: the Worker entry
(`dist/server/entry.mjs`), the adapter's `dist/server/wrangler.json`, or the build manifest. A
server build without the Worker entry fails rather than falling back to the static checks. On a
server-rendered build it does the following:
- It reads the public files from `dist/client/` and runs every existing check on them, reported
  under the `dist/…` paths they are served at.
- It runs the secrets check on the server bundle. The PII checks don't run there: the bundle mixes
  the owner's templates with library code, so a match says nothing about the owner's data.
  Owner-authored rendered pages are covered at render time (layer 3).
- It refuses the deploy unless the server bundle was built from the site's pinned
  `scripts/gate-checks.ts` and `scripts/emdash-gate/`, unchanged since the build, and registers
  `anglesite-gate`. Those facts come from `dist/anglesite-build.json`, which the pinned
  `scripts/anglesite-build-manifest.ts` integration writes from the bundler. Each gate source is
  hashed as Vite loads it for the server build. Registration is read from EmDash's compiled
  `virtual:emdash/plugins` module, which carries a descriptor only for each registered plugin.
  The manifest sits outside both `dist/client/` and `dist/server/`, so it is neither served nor
  uploaded.
- It lists public chunks made entirely of EmDash's own code (its admin UI) in the same manifest:
  every module is under `node_modules/` or is one of EmDash's two admin-UI registries
  (`virtual:emdash/admin-registry`, `virtual:emdash/auth-providers`). The deploy scan skips only
  the email and phone patterns for those chunks, which match their placeholder addresses and
  minified constants. It does the same for Pagefind's vendored files. EmDash's other generated
  modules are built from the site's config and seed, so a chunk containing one is never treated
  as vendored.

**Layer 3 on an EmDash site (#2055 slice 4).** The pinned
`scripts/emdash-gate/render-backstop.ts` checks every page the Worker renders on request, before
a reader or a cache gets it. The overlay's `src/middleware.ts` wires it in.
- It runs the error-severity checks from the shared module: secrets, restricted-audience
  content and blocked admin routes. PII stays a publish-time and deploy-time check, so a
  reporter's published contact line doesn't take a page down.
- A failing page is replaced by a plain `503` with `Cache-Control: no-store` that says nothing
  about why. If the page can't be read or checked, it is withheld too, so the backstop fails
  closed.
- EmDash's own authenticated routes (`/_emdash/…`) and non-HTML responses are skipped.
  Prerendered pages are skipped too: the deploy layer already scanned them as files.
- The deploy layer lists the backstop in `REQUIRED_GATE_MODULES`, so a server build without it
  is refused.
- The owner is alerted in two places. The Worker's log gets one
  `anglesite.render-backstop.withheld` line per withheld page, naming the path, the check
  categories and their messages; the messages say what was found but never quote it. The site's
  D1 database (EmDash's `DB`) gets one row per withheld path in `anglesite_withheld_pages`
  (#2097). It is written only when a page is withheld, and refreshed at most every five minutes.
  The app reads that table (`EmDashWithheldPages`, via `SiteSettings.emdashD1DatabaseID`) and
  shows a banner in the site window: which pages, why in owner terms, and Open EmDash. When a
  listed page answers `200` again, the app clears its row, so a fixed article's notice goes away
  on its own. This matters because a false positive (a token-shaped string in an article about
  security, say) takes a page down with a 503 the writer can't see.
- Checking a page means reading all of it first, so server-rendered pages are no longer
  streamed as they render. That is deliberate: nothing reaches a reader or a cache before the
  whole page has been checked.
- A response with no body (a `304` revalidation, a `HEAD` request) passes through unchanged.
  A content-encoded body can't be read as the page's text, so it is withheld. Astro renders
  uncompressed; Cloudflare compresses later, at the edge.

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
`hooks.content-policy:register`, with no content, schema or network access: the policy hooks hand
it the draft being published
([EmDash plugin capabilities](https://github.com/emdash-cms/emdash/blob/main/skills/creating-plugins/SKILL.md),
[hooks](https://github.com/emdash-cms/emdash/blob/main/skills/creating-plugins/references/hooks.md)).
On an EmDash site Anglesite scaffolds, it is registered in `plugins: []` from its pinned
source (`scripts/emdash-gate/plugin.ts`) rather than in `sandboxed: []`. A sandboxed entry must
be a prebuilt bundle, which would put an unpinned build step between the code the D5 hash pin
covers and the code that runs. EmDash still limits it to the capabilities it declares. The
packaged bundle (`JS/anglesite-gate/`) is for registering it on installs Anglesite doesn't
scaffold. It never registers `content:beforeUnpublish`: a
correction, retraction or takedown must never be blocked by the gate.

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
