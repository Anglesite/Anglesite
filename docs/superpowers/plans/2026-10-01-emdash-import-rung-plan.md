# EmDash import rung (Portable Text → Markdown) — plan

**Date:** 2026-10-01
**Status:** current
**Issue:** #2051 (parent #2050)
**Design:** [`../../specs/2026-09-28-external-cms-content-source-decision.md`](../../specs/2026-09-28-external-cms-content-source-decision.md) decision 5 ("Portability comes from EmDash, not a git mirror"), [`../../specs/2026-06-29-c1-indieweb-content-model-decision.md`](../../specs/2026-06-29-c1-indieweb-content-model-decision.md)

---

## Why a rung of its own

An EmDash site keeps its content as Portable Text in schema-builder collections (D1/SQLite)
and its media in R2/S3. The only existing way out was WordPress's WXR through `WXRRung`,
which flattens every post to HTML and drops the block structure, custom blocks, and every
field the schema builder added. Decision 5 of the external-CMS ADR names this rung as the way
an owner leaves EmDash (or tries Anglesite beside it), so it reads EmDash's own export and
converts Portable Text directly.

## Source: EmDash's table dump, two ways

EmDash exposes the same table dump twice — `GET /_emdash/api/snapshot` (Bearer API token,
`content:read` + `schema:read`, published content only) and the `emdash-backup` JSON file its
Backups page downloads — and `EmDashSnapshotDocument` parses both into one `EmDashExport`:

| Table | Read as |
|---|---|
| `_emdash_collections`, `_emdash_fields` | collections with ordered fields (slug, label, type, required), `url_pattern`, `title_field`, `date_field` |
| `ec_<slug>` | entries: system columns (`status`, `deleted_at`, `published_at`, `locale`, `translation_group`, …) plus authored columns, with JSON-typed columns decoded the way EmDash's `deserializeValue` does |
| `taxonomies`, `content_taxonomies` | terms and assignments (matched by id *or* translation group, since EmDash writes either depending on schema version) |
| `media` | media id → storage key, for `/_emdash/api/media/file/<key>` |
| `options` | `site:title`, `site:tagline`, `emdash:locale` for `.site-config` seeds |

The paginated `/_emdash/api/content/{collection}` listing is deliberately not used: it carries
neither the schema nor the terms nor the media table, each of which would be further requests
per entry. A raw SQLite/D1 file is out of scope — EmDash's admin turns one into the backup JSON,
and parsing SQLite in-app would be a new dependency.

`EmDashContentAPI` makes the one request behind an injectable `EmDashHTTPClient` seam
(ephemeral `URLSession` by default, per `WXRAssetDownloader`), so tests answer it with a fake.

## Converter: `PortableTextMarkdownConverter`

Pure Swift, standalone (no import types, no networking), so the #2050 git-mirror option can
reuse it. Its input is the decoded block array (`JSONValue`), its output Markdown plus an image
inventory and the list of block types it had no rendering for. The dialect is the one EmDash's
editor writes (`src/content/converters/types.ts` in `emdash` 1.0.1):

- `block`: `normal`/`h1`–`h6`/`blockquote`; `listItem` `bullet`/`number` with `level`
  (four spaces per level, so nested ordered items stay nested under CommonMark) and
  `listStart`; span marks `strong`/`em`/`code`/`underline`/`strike-through`/`subscript`/
  `superscript` and `markDefs` links.
- `image` (with `caption`, `title`, `link`), `gallery`, `code` (fence grows past inner
  backtick runs; `filename` as a comment), `break` → `---`, `table` → GFM, `htmlBlock` →
  raw HTML unless the caller supplies a Markdown conversion for that exact HTML string
  (how an injected `ImportHTMLConverter`, which is async and platform-specific, plugs into a
  synchronous converter — the same hash-keyed lookup `ImportSnapshot.conversions` uses).
- Anything else is kept verbatim as a ```` ```json emdash-block=<type> ```` fence and its type
  reported, so nothing the owner wrote is dropped and the summary says which posts to look at.
- Span text is escaped (`*`, `_`, backticks, brackets, `<`, and a leading `#`/`>`/`-`/`1.`),
  which EmDash's own serializer doesn't do — it only ever round-trips its own output.

Images: `asset.url` is resolved against the site origin by the rung; a bare `asset._ref` goes
through the media table. The inventory carries the exact spelling the Markdown does, so
`AssetLocalizer`'s rewrite finds it.

## Rung: `EmDashRung`

Shapes match `WXRRung`: `items(from:siteURL:htmlConversions:)` for a one-shot export feeding
`ImportTransform.run(resolved:…)`, an async overload taking an `ImportHTMLConverter`, and
`items(from: ImportSnapshot)` over a new `SiteProbes.emdashSnapshotJSON` probe, which
`ImportSourceResolver` runs ahead of the WordPress rungs (an EmDash site's pages are rendered
from exactly that data). `homepage(from:siteURL:)` is a stand-in `CapturedPage` so the
`.site-config` seeds work on the one-shot path too.

Only `published`, untrashed entries are imported (what EmDash serves publicly). Mapping, decided
once per collection by slug, onto the C.1 post types:

| Collection slug | Hint | Destination |
|---|---|---|
| `articles`/`posts`/`blog` | `.article` | `blog` |
| `notes`/`statuses` | `.note` | `notes` |
| `photos` | `.photo(image:)` from the image field | `photos` |
| `bookmarks`/`links`, `likes`, `replies` | `.bookmark(of:)`/`.like(of:)`/`.reply(to:)` from a `url`-typed or url-named field | the matching collection |
| `pages` | `.page` (new hint, classified like `.wpPage`) | page route |
| anything else | `.article` if it has a title field, else `.note`, plus one `ImportProblem` per collection naming the guess | |

Fields: title from `title_field` (or `title`), excerpt from `summary`/`excerpt`/`description`,
hero image from the first `image` field (leads the body for every type but photos, whose
`image:` the emitter writes from the hint), body from the first `portableText` field. Every other
authored field goes into the body rather than being lost — frontmatter schemas are `.strict()`:
further `portableText`/`text` fields under a `## Label` heading, scalars as a trailing
`**Label:** value` list, and `blocks`/`repeater`/`json` as a `json emdash-field=<slug>` fence.
An entry that needed any fence gets one `ImportProblem` ("Kept as code for review: …"), which is
what `ImportSummaryModel` turns into the attention line. The entry's source URL is the
collection's `url_pattern` with `{slug}` filled, so `RedirectsEmitter` maps `/articles/hello/`
to `/blog/hello/`; tags are the labels of every assigned term; `lang` is the entry locale.

## Tests

`Tests/AnglesiteCorePortableTests/` (the only AnglesiteCore test target the Linux leg runs; same
placement as the #2050 EmDash suites), with fixtures under `Fixtures/EmDash/`:

- `portable-text-kitchen-sink.json` + golden `.md`: every block type and mark above, escaping,
  list numbering, both image reference forms, custom blocks.
- `emdash-backup.json`: a backup dump in EmDash 1.0.1's real table shapes (four collections,
  drafts/trashed/empty entries, terms by id and by translation group, media, options). One test
  holds its `articles` schema to the template's `Resources/Template/emdash/seed/seed.json`.
- The rung's mapping, the resolver's precedence, the API client (fake HTTP), and a full
  `ImportTransform.run(resolved:)` through classification, emission, redirects and summary.

## Out of scope

- The app-side journey (picking "Import from EmDash", asking for URL + token or a backup file,
  downloading the inventoried images with `WXRAssetDownloader`, scaffolding) — the pieces exist
  (`SiteActions.importWXR` is the model), but `Sources/AnglesiteApp` isn't touched here.
- Populating `SiteProbes.emdashSnapshotJSON` from the crawler (`JS/import-engine`).
- A raw SQLite/D1 dump, and EmDash's paginated content listing (see above).
