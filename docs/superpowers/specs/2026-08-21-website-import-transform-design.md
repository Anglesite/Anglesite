# Website Import — Transform Stage Design

**Date:** 2026-08-21
**Issue:** [#1615](https://github.com/Anglesite/Anglesite/issues/1615) — File ▸ Import from URL
**Scope:** the transform stage — turning a crawled snapshot of an external website into an
editable `.anglesite` package. The crawl stage (WKWebView capture) is covered only as far as
its output contract; its own design (session handling, discovery order, limits UX) is a
follow-up spec.

## Decisions (brainstorm 2026-08-21, owner-approved)

1. **v1 outcome: content moves, look changes.** Posts/pages are extracted into the
   template's Markdown content collections and rendered by Anglesite layouts with a theme
   the owner picks at import. No frozen-HTML mode in v1 — foreign markup never ships
   through the CSP or the pre-deploy gate.
2. **Structured-first source ladder.** WP REST → RSS/Atom/JSON Feed → microformats2 →
   readability fallback on crawled HTML.
3. **Extraction engine: JS in the capture WKWebView.** Vendored Readability + Turndown +
   microformats parser as a new `JS/import-engine/` bundle; no Node, no host runtime.
4. **Review UX: one summary screen.** Automatic classification; a Migration-Assistant-style
   summary plus theme picker before anything is written; imperfections land in a
   post-import checklist, never a blocking dialog.
5. **No Apple Intelligence in v1.** Fully deterministic; FM-assisted classification and
   frontmatter enrichment are follow-up slices with deterministic fallbacks.

## Architecture

```
File ▸ Import from URL…
  → crawl (offscreen WKWebView)
      → per-page extraction (JS/import-engine, injected)   ┐ produces
      → asset download                                     ┘ ImportSnapshot
  → ImportSourceResolver (ladder probes, recorded per item)
  → ContentClassifier (deterministic rules)
  → ImportPlan → summary screen (counts, theme picker, unconverted list)
  → SiteScaffolder (existing flow, fresh package)
  → ImportWriter (content, assets, redirects, .site-config seeds)
  → git commit → register → open site; ImportReport → Config/
```

The load-bearing structural choice: extraction happens **during capture**, inside the
crawl's WKWebView. The Swift transform never parses HTML — it consumes structured
per-page records. `SiteImport/` in `AnglesiteCore` is therefore pure Swift over
JSON-decodable values and fully SwiftPM-testable.

## Components

### ImportSnapshot (crawl → transform contract)

Per site: probe results (WP REST responses, discovered feed documents, robots/sitemap
inventory). Per page: final URL, canonical URL, extraction record (below), and the set of
downloaded assets keyed by source URL. Snapshots are `Codable` and serializable to disk —
they are the fixture format for golden tests and the retry boundary if a transform fails.

### JS/import-engine (new JS subproject)

Follows the `JS/safari-extension/` / `JS/wysiwyg-engine/` pattern: source in
`JS/import-engine/`, built by `scripts/build-import-engine.sh` into
`Resources/ImportEngine/`, existing oxlint/tsc/vitest toolchain.

Vendored dependencies (**new-dependency approval granted in #1615's brainstorm; record in
the PR**): `@mozilla/readability` (Apache-2.0), `turndown` (MIT), `microformats-parser`
(MIT).

Per-page output record:

```
{ title, byline?, publishedISO?, lang?, canonical?,
  markdown, excerpt?, images: [url], mf2Items, feedLinks: [url] }
```

HTML that arrives as strings (WP REST bodies, full-content feed entries) is converted by
loading it into the same offscreen WKWebView via `loadHTMLString` and running the same
engine — one converter for every ladder rung.

### ImportSourceResolver (the ladder)

Probes in order; each imported item records which rung produced it (surfaced in the
report):

1. **WP REST** — `/wp-json/wp/v2/posts` + `/pages` (paginated): clean titles, dates,
   bodies, post-vs-page typing.
2. **Feeds** — RSS/Atom/JSON Feed. Excerpt-only feeds are detected (body length vs the
   crawled page); an excerpt feed supplies metadata while the body comes from the crawled
   page's readability record.
3. **microformats2** — h-feed/h-entry from the engine's mf2 output.
4. **Fallback** — readability record of each crawled page.

Network access reuses the app's existing gating patterns: scheme gate as in
`LinkMetadataFetcher`, plus a Swift port of the blocked-address logic from the template's
`scripts/embeds/net-guard.ts` (private ranges, link-local, etc.).

### ContentClassifier (deterministic)

Item → one of the template's 13 collections (`src/content.config.ts`) or a standalone
page. Rule order:

1. Source-declared type: WP `post` → `blog`, WP `page` → standalone page.
2. mf2 properties: `u-bookmark-of` → `bookmarks`; `u-like-of` → `likes`;
   `u-in-reply-to` → `replies`; photo-primary h-entry → `photos`; title-less h-entry →
   `notes`; titled h-entry → `blog`.
3. URL heuristics: `/blog/`, `/posts/`, date-in-path → `blog`.
4. Default: standalone `.md` page under `src/pages/` with `layout: BaseLayout`.

Homepage special case: it never becomes a page — detected tagline/site name/language seed
`.site-config` (`TAGLINE`, `SITE_NAME`, `LANG`) and `HomepageWriter`'s placeholder flow.

Collections not listed above (`albums`, `events`, `reviews`, `members`, `blogroll`,
`announcements`, `articles`) receive nothing in v1; the classifier has no rules that emit
into them.

### ImportWriter

- **Frontmatter** built per collection against the strict `.strict()` zod schemas — emit
  exactly the declared fields (e.g. `blog`: `{title, pubDate, description?, draft, lang?}`).
  Paths via `ContentScaffold.postRelativePath` / `slugify`.
- **Assets**: images downloaded during crawl land in `public/images/` under
  `LinkImageAsset` conventions (magic-byte sniffing, SVG refused, per-file size cap);
  Markdown image URLs are rewritten to the local paths. Assets that fail the sniff/cap are
  left as absolute remote URLs and listed in the report (the default CSP will block them —
  the checklist entry says so in owner language).
- **URL preservation**: source slugs are kept where the route shape allows; changed routes
  (e.g. dated WordPress permalinks → `/blog/<slug>/`) emit 301 entries into the template's
  `redirects.json`.
- Runs after the normal `SiteScaffolder` sequence on a fresh package; one git commit for
  the imported content. An imported site is a standard site plus content — nothing
  bespoke in its layout.

### Flow, review, and failure handling

- Progress streams via the existing `ScaffoldStep`-style step model.
- `ImportPlan` drives the single summary screen: counts per kind in owner language
  ("42 blog posts, 6 pages, 310 images"), the theme picker (existing
  `ThemeCatalog`/wizard), and the list of pages that couldn't be converted cleanly.
- Per-item failures never abort the import; they accumulate into an `ImportReport`
  persisted in the package's `Config/` and surfaced as a post-import checklist.
- Hard caps (page count, total asset bytes, per-asset bytes) are reported, never silent —
  per the "no silent truncation" house rule.

## v1 non-goals

- Frozen/HTML-passthrough mode.
- Apple Intelligence anywhere in the pipeline.
- Comment/webmention migration.
- Platform adapters beyond the WP REST rung (no Squarespace/Wix/etc. specials).
- Per-item mapping UI.
- Importing sites the crawl cannot reach (auth flows belong to the crawl-stage spec).

## Testing

- **JS engine**: vitest unit tests over messy-markup fixtures in `JS/import-engine/`.
- **Transform**: golden-file tests in `AnglesiteCoreTests` — recorded `ImportSnapshot`
  fixtures (WP site, excerpt-feed site, mf2 IndieWeb site, plain HTML site) → expected
  `Source/` trees. The snapshot `Codable` format is the fixture format.
- **Classifier**: table-driven Swift Testing cases per rule.
- **E2E**: opt-in live crawl of a fixture site, gated with `.enabled(if:)` like the
  existing sidecar-dependent suites.

## Follow-ups (out of this spec)

- Crawl-stage design: discovery, session/auth handling, limits UX, robots posture,
  not-your-site guardrail (issue #1615's open questions cover these).
- FM-assisted classification + frontmatter enrichment slices.
- ZIM export (separate idea; file independently if wanted).
