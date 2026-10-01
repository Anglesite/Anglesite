# EmDash site overlay

Files here replace the template's own when Anglesite creates an **EmDash site** (#2050).
`EmDashScaffold.applyTemplateOverlay` copies this tree over the new site's `Source/`, file by
file, after `scripts/scaffold.sh` has copied the template. `scaffold.sh` leaves this directory
out, so an Anglesite site never gets it.

The overlay turns the template into a server-rendered Astro site on Cloudflare Workers, with
EmDash as the source of every article
([ADR](../../../docs/specs/2026-09-28-external-cms-content-source-decision.md), decisions 2
and 4):

- `astro.config.ts`: the template's config plus the Cloudflare adapter and the EmDash
  integration (D1 `DB`, R2 `MEDIA`). Every page that doesn't read EmDash stays prerendered.
  `anglesite-gate` is registered here, in code, so an EmDash administrator can't remove it, and
  so is `scripts/anglesite-build-manifest.ts`. The pre-deploy gate uses its
  `dist/anglesite-build.json` to confirm the Worker was built with the gate (#2055 slice 2).
- `src/live.config.ts`: EmDash's live content collection.
- `src/pages/articles/`: the article index and article pages, rendered on request from the
  EmDash `articles` collection with the template's h-entry markup.
- `src/middleware.ts`: wires in the render backstop (`scripts/emdash-gate/render-backstop.ts`,
  #2055 slice 4). Every page rendered on request is checked for secrets, restricted-audience
  content and admin routes before it is served, and withheld with a `503` if it fails. The
  whole page is read before it is sent, so these pages aren't streamed.
- `src/worker.ts`: the Worker entry. It adds EmDash's cron handler, which publishes scheduled
  articles when they come due.
- `seed/seed.json`: the EmDash schema a new site starts with. It maps the `articles` collection
  onto Anglesite's `articles` content type.
- `package.json` / `package-lock.json`: the template's dependencies plus EmDash's. The owner
  approved the additional packages for EmDash sites only. This lockfile is also the input to
  `Resources/Attributions/emdash-site.json`, the set an EmDash site's `THIRD-PARTY-NOTICES.md`
  is written from (#2088): regenerate it with `scripts/generate-attributions.sh` after a
  dependency change here, or CI's manifest check fails.

The Worker's `wrangler` configuration is not here. Anglesite writes it from its own
provisioning state into the site's `Config/` and stages it next to the build.
