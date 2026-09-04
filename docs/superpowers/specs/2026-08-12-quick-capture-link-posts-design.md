# Quick-capture link posts — design (#531)

**Status:** approved 2026-08-12 (interactive design session with owner)
**Issue:** [#531](https://github.com/Anglesite/Anglesite/issues/531) — Quick-capture posting flow: link posts in seconds
**Depends on:** #516 (New Post… / typed-content creation path) — shipped 2026-07-10

## 1. Goal and scope

For link bloggers the unit of work is "see interesting thing → paste URL → two
sentences → publish," many times a day. Today that requires opening the app, a
site window, and a sheet. This design makes a pasted or dragged URL become a
published link post in seconds.

Of the issue's four ambition tiers, this design covers:

- **Tier 1** — link-post template pre-filled from fetched page metadata.
- **Tier 2** — paste or drag a URL into the app (site window or launcher).
- **Tier 4** — an App Intent so Shortcuts/Siri can capture.

**Out of scope (follow-up issues):**

- **Tier 3, Safari share extension** — needs its own design: a new extension
  target, an app group, and security-scoped-bookmark sharing across the MAS
  sandbox boundary. Split into a dedicated issue rather than blocking tiers
  1/2/4 on it. (Until then, the App Intent gives share-sheet capture via a
  user-built Shortcut.)
- **og:image download** into site assets — v1 pre-fills text metadata only.
- **JS-rendered-page metadata** — the fetcher parses server-rendered HTML;
  pages whose `og:` tags exist only after script execution fall back to the
  empty-title path (rare for article pages).
- **Drafts/scheduling workflow** beyond the existing `draft` frontmatter flag.

## 2. Content model: reuse the `bookmark` type

A captured link becomes an entry in the template's existing IndieWeb
**`bookmarks` collection**, via the existing app-side **`bookmark`** content
type (`ContentTypeRegistry.bookmark`):

```yaml
---
bookmarkOf: "https://example.com/interesting-thing"   # required URL
title: "Interesting Thing"                             # optional, from page metadata
publishDate: 2026-08-12T20:00:00.000Z
tags: []
draft: true                                            # Save Draft only
---
Two sentences of commentary.
```

**Why not a `link:` field on blog posts:** the template's Zod schemas are
`.strict()`, and the bookmark model — `bookmarkOf` URL, optional title,
commentary body, `u-bookmark-of` microformat rendering — already *is* the
classic link post. Adding a parallel `link:` mechanism to `blog` would
duplicate it for no benefit. Trade-off accepted by the owner: link posts live
in the bookmarks stream, not the main blog feed. **No template schema changes
are needed.**

## 3. Core layer (AnglesiteCore)

All new logic lives in AnglesiteCore so it is unit-testable without a hosted
app target (per the repo's CI constraint).

### 3.1 New: `LinkMetadataFetcher` + `LinkMetadataParser`

- `LinkMetadataParser` — a **pure** function from HTML text to
  `LinkMetadata { title: String?, description: String?, siteName: String? }`.
  Scans the document head for `og:title`, `og:description`, `og:site_name`,
  falling back to `<title>`. Handles attribute-order variance, single/double
  quotes, and HTML entity decoding. Fixture-testable.
- `LinkMetadataFetcher` — an actor wrapping `URLSession`: GET with a ~10 s
  timeout and a ~2 MB read cap (link metadata lives in the head; cap bounds
  memory on hostile/huge pages), charset detection from the response, then
  `LinkMetadataParser`. Injectable `URLSession` (ephemeral configuration; no
  cookies/credentials) so tests stub transport via `URLProtocol`.
- Fetch failure is **never fatal** — callers get an empty `LinkMetadata` plus
  a logged error; the compose flow continues with the bare URL.
- The app sandbox already has `com.apple.security.network.client`; no
  entitlement changes.
- Chosen over `LPMetadataProvider` (LinkPresentation): the public API does not
  expose `og:description`, it spins up WebKit per fetch, and it cannot be
  tested offline. Chosen over fetching via the MCP sidecar: capture must work
  with **no site runtime running** (launcher flow), and a sidecar route would
  need a paired schema PR.

### 3.2 Extend: commentary body + draft flag through the typed-create path

`NativeContentOperations.createTyped(…fieldValues:)` today carries values only
for scalar-string field kinds (`.string`, `.text`, `.url`, `.image`);
`.markdown` renders a placeholder body and `.bool` renders its default. Two
small, backward-compatible extensions:

- `ContentScaffold.renderEntry` accepts caller-supplied values for a
  descriptor's `.markdown` field (the commentary body, replacing the
  placeholder) and `.bool` fields (`draft`).
- `createTyped` forwards them. Empty `fieldValues` renders **byte-identical**
  output to today (the #916 purity contract holds).

Everything else — `bookmarkOf` URL validation via
`ContentFieldValidation.isAbsoluteURL`, slug-from-URL, refuse-overwrite,
schema-valid frontmatter rendering, best-effort git commit — comes free from
the existing `createTyped` path. The `ContentOperationsService` protocol
witness stays title-only, as documented there; quick capture is native-only,
matching the New Collection sheet's precedent.

### 3.3 Publish semantics

- **Save Draft** → writes `draft: true`. Done.
- **Publish** → writes `draft: false` (the schema default), then triggers the
  **existing** build+deploy path if the site's runtime is available.
  - Runtime not running (e.g. captured from the launcher, site never opened
    this session): the entry is still written published (`draft: false`) and
    the UI says the post will go live on the next deploy — the issue's
    "draft now, deploy on next open" fallback. Capture **never boots a
    container**; no new deploy machinery is invented.
  - The pre-deploy security gate applies unchanged: publish goes through the
    same deploy path as everything else, `pre-deploy-check.ts` included.

## 4. App layer (AnglesiteApp)

### 4.1 `QuickCaptureModel` (@Observable, @MainActor)

Thin per repo convention — logic stays in Core. Holds: the URL, fetch state,
editable title, commentary text, target site, and create/publish state. On
sheet open it immediately starts `LinkMetadataFetcher.fetch`; the title field
fills when metadata lands (spinner while loading, never blocks typing
commentary). Save Draft / Publish run through
`ContentCreationWorkflow.createTyped` with
`fieldValues = ["bookmarkOf": url, "body": commentary, "draft": …]`, then the
same post-create wiring as New Post…: content-graph refresh and
`registerContentUndo`.

### 4.2 `QuickCaptureSheet`

- **URL field** — editable, validated with `ContentFieldValidation
  .isAbsoluteURL`; invalid ⇒ create buttons disabled, inline hint.
- **Title field** — pre-filled from metadata, always editable; small progress
  indicator while the fetch is in flight; quiet "Couldn't fetch page info"
  note on failure (URL and manual title still work).
- **Commentary** — multi-line text editor; the body of the post.
- **Site picker** — shown **only** when the sheet is invoked without a site
  context (launcher, menu with no site window focused); defaults to the
  last-opened site.
- **Buttons** — Cancel / Save Draft / **Publish** (default button, ↩).
- Error copy follows the house rule: phrased as consequences to the owner's
  site ("A bookmark for this page already exists"), never git/diff/file-layout
  jargon.

### 4.3 Entry points

| Entry | Where | Behavior |
|---|---|---|
| Drag a URL | Site window content | `.dropDestination(for: URL.self)` → sheet for that window's site |
| Paste a URL | Site window (navigator/preview focus) | `.onPasteCommand(of: [.url])`, scoped so paste inside text editors is untouched → sheet for that site |
| Drag a URL | Launcher | Launcher already accepts `.anglesite` package drops; additionally accept URL drops → sheet with site picker |
| Paste a URL | Launcher | `.onPasteCommand` → sheet with site picker |
| **File ▸ New ▸ Link Post…** (⇧⌘L) | Menu bar, focused site window only | Pre-fills URL from the clipboard when it holds one, for the focused site window's site |

Mac-conventions coverage per `docs/mac-assed-app-spec.md`: a real menu command
with a keyboard shortcut (discoverable, Shortcuts-recordable), drag-and-drop,
paste, and Undo after create.

> **Amendment (#1860, 2026-09-04):** the menu command is gated on the same
> focused-value as its New Page/Post/Component/Collection siblings, matching
> the acceptance rule that no site-scoped command may be enabled with no site
> window focused — it no longer falls back to the launcher's site picker when
> nothing is focused. That windowless path is still reachable via drag/paste
> of a URL into the launcher (rows above) and the `AddLinkPostIntent`.

### 4.4 Windowless writes (launcher flow)

Creating an entry for a site with no open window resolves the site's
security-scoped bookmark through the existing `SiteAccess` machinery — the
same way deploy/backup/audit already run windowlessly. If the grant cannot be
resolved (stale bookmark), the sheet surfaces the same site-access error those
flows use.

## 5. App Intent (AnglesiteIntents)

New **`AddLinkPostIntent`** — a new intent rather than new parameters on
`AddPostIntent`, because bookmark is a different content type and existing
shortcuts must not change shape:

- **Parameters:** Site (existing `SiteEntity` fuzzy resolution), URL
  (required), Title (optional), Commentary (optional), Publish (Bool, default
  false).
- **Behavior:** when Title is absent, fetch metadata to fill it (same
  fetcher); create via the same typed path; return the created entity and a
  success/failure dialog. `LongRunningIntent`/`CancellableIntent` gating as in
  `AddPostIntent`.
- **Testing:** through the existing `ContentOperationsOverride` seam in
  `AnglesiteIntentsTests`.
- This is also the interim share-sheet story: "Post link to <site>" works from
  Shortcuts/Siri (and an iOS Shortcut once the shared codebase lands) ahead of
  the real share extension.

The AppIntents schema-check CI lane covers the new intent.

## 6. Error handling

| Failure | Behavior |
|---|---|
| Metadata fetch fails / times out / non-HTML | Sheet proceeds with empty title; quiet inline note; error logged to the debug pane |
| Invalid URL | Inline validation, create disabled |
| Duplicate slug (`createTyped` refuse-overwrite) | Failure reason shown in the sheet; user can tweak the title/slug source |
| Site access grant unresolvable | Existing site-access error surface |
| Deploy fails after Publish | Existing deploy error surface (debug pane, window UI); the entry itself is already safely written and committed |

## 7. Testing

- **Core (bulk of coverage):**
  - `LinkMetadataParser` against HTML fixtures: og: tags present / missing /
    malformed / entity-encoded / attribute-order and quote variants / `<title>`
    fallback / non-UTF-8 charset.
  - `LinkMetadataFetcher` with a stubbed `URLProtocol`: success, timeout,
    over-cap response, non-HTML content type.
  - `renderEntry`/`createTyped`: body + draft plumbing; empty `fieldValues`
    stays byte-identical (purity regression); `bookmarkOf` validation and
    slug-from-URL already covered, extended for the new params.
- **Intents:** `AddLinkPostIntent` via `ContentOperationsOverride` — with and
  without Title, Publish flag, failure dialogs.
- **App target:** stays thin (no hosted app tests on CI); `QuickCaptureModel`
  state transitions covered where they can live in SwiftPM-testable code.
- The template is untouched (no schema change), so no template-coupled Swift
  test churn is expected; run `swift test` regardless per CONTRIBUTING.

## 8. Follow-ups to file

1. **Share extension (tier 3):** Safari share-sheet capture without the app
   frontmost — extension target, app group, MAS bookmark-sharing design.
2. ~~**og:image capture:** download the page's image into site assets and
   reference it from the bookmark entry.~~ — **shipped** as
   [#1451](https://github.com/Anglesite/Anglesite/issues/1451):
   `LinkMetadataParser` reads `og:image`, `LinkMetadataFetcher` resolves it
   against the page URL and narrows it to http(s), and `LinkPostImageCapture`
   downloads it into `public/images/link-<slug>.<ext>` **after** the entry is
   written — then adds `image:` to the entry's frontmatter and commits both in
   one commit. Best-effort throughout (§6's rule): any refusal leaves the link
   post exactly as created. `AddLinkPostIntent` still captures text metadata
   only; wiring the intent through the same path is a further follow-up.
3. **(If demand appears) link posts in the main feed:** a theme option to
   surface bookmarks in the blog stream, rather than a schema change.
