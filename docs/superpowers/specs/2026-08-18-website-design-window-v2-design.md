# Website Design Window v2 (#714) — Design

**Date:** 2026-08-18
**Issue:** [#714](https://github.com/Anglesite/Anglesite-app/issues/714)
**Status:** Approved by DWK 2026-08-18.
**Supersedes:** the unshipped parts of
[`2026-07-13-website-design-window-cleanup-design.md`](2026-07-13-website-design-window-cleanup-design.md)
— its slice 2 (§7 Website Settings main-pane surface) and slice 4 (§5 toolbar
re-curation) are replaced by this document. Its shipped slices (URL-tree
navigator, unified inspector, collection context) stay as built and are the
baseline this design amends.

## Context

The 2026-07-13 spec was written before the WYSIWYG block-editor epic
([#1221](https://github.com/Anglesite/Anglesite-app/issues/1221)) had a design.
That epic makes the rendered page the editing surface ("block editor on the
true render") and adds a native component palette and block-props inspector
([#1225](https://github.com/Anglesite/Anglesite-app/issues/1225), the Mac host
chrome design). Two of the old spec's unshipped commitments no longer fit:

- The §7 three-section Website Settings surface duplicated component/style
  browsing that the palette and selection-driven entry now own.
- The §5 toolbar defaults kept the Preview / Editor / Graph mode switch, which
  a single always-editable canvas obsoletes.

This v2 re-opens the whole window design and lands the Pages model completely:
one canvas, a visitor-only sidebar, and two inspectors.

## Decisions (2026-08-18)

1. **One canvas, no mode switch.** The rendered page is the main pane; the
   Preview / Editor / Graph segmented control is removed.
2. **Two inspectors, Pages-style.** The selection inspector (Format analog)
   and a new Website inspector (Document analog) share one trailing panel with
   mutually exclusive toolbar toggles. Deep site config stays a main-pane
   surface.
3. **The navigator's website-title row is removed.** The sidebar is purely
   the visitor's URL tree.
4. **Component/style editing is selection-driven.** Canvas selection and the
   WYSIWYG palette are the entry points; the §7 browse lists are dropped.
5. **One `plus` toolbar menu** covers content creation and, once the palette
   ships, block insertion.

## 1. Navigator

The shipped URL tree (old spec §1–2) stays as built, with one change: the
pinned website-title row is **removed**. Home, pages, collection directories
(feed badge), and entries render exactly as today, with the existing rename,
context-menu, drag, and live-refresh behavior.

- `buildSiteURLTree` no longer emits the `"website"` node; `websiteTitle`
  leaves its signature.
- `NavigatorTarget.websiteSettings` remains as a routing value (menus and the
  Website inspector's "More Settings…" still open that surface) but no sidebar
  row produces it.
- The `globe` icon moves to the Website inspector's toolbar toggle.
- The art brief for the feed-folder symbol
  (`docs/art-briefs/2026-07-13-folder-rss-symbol.md`) is unchanged.

## 2. Canvas and drill-in surfaces

The main pane's default and primary state is the rendered page — today's live
preview, which becomes the always-editable WYSIWYG canvas as #1221 lands. The
window chrome work here does **not** block on that epic: until the block
editor ships, the canvas is simply the preview.

`MainPaneMode` survives as routing, but the non-canvas modes become **drill-in
takeovers**, not peer modes:

- **Editor** (`.editor(FileRef)`: component editor, source editors, the
  deep-config surface) opens only by drilling in — opening a file, "Edit
  Component" from the inspector, or a menu command. Every takeover gets a
  standard header with a **Done** control that returns to the canvas.
  Selecting any page row in the navigator also returns to the canvas
  (unchanged `.route` behavior).
- **Graph** and **Cleanup** become menu-invoked takeovers (Site ▸ Graph…,
  Site ▸ Cleanup…) with the same Done chrome. Cleanup's menu move was already
  specified in the old spec and carries forward.
- Reader / Followers / Communities / Moderation / Contacts modes are
  unaffected; they were never in the segmented control.
- View menu: ⌘1 returns to the canvas; the old ⌘2/⌘3 pane toggles retire with
  the control.

## 3. Two inspectors

Both inspectors share the Metadata | Style tab shape and the single trailing
`.inspector` container. Which one occupies it is a single enum (not two
booleans): `.none`, `.selection`, `.website` — two toolbar toggles and their
View-menu items arbitrate, and activating one deactivates the other, matching
Pages' Format/Document behavior.

### 3.1 Selection inspector (Format analog)

Today's `SiteInspectorView`, unchanged in shape:

- Selection kinds stay **element / page / collection** with the shipped
  per-kind content (old spec §4/§6 table).
- The empty `(page, .style)` gap is filled by the WYSIWYG epic: canvas block
  selection feeds the **element** context. #1225's block-props inspector lands
  *here* — it is this inspector, not a new panel (that spec already models its
  forms on `PageInspectorView` / `ComponentStyleInspectorPane`).
- The #968/#969 presentation-gate discipline carries over verbatim: every
  selection transition lands as one synchronous transaction after its awaits.

### 3.2 Website inspector (Document analog) — new

Always available; its toggle is never disabled.

- **Metadata tab** — site identity basics: display name (the package
  `Info.plist` title entry) and language (`.site-config` via
  `SiteLanguageAsset`), directly editable with commit-on-submit/focus-loss;
  domain shown read-only (`.site-config` `DOMAIN` via
  `WebsiteAnalyticsAsset.bestHost` — editing stays with the Connect Domain
  flow). *(Amended 2026-08-18 while planning: description and social/OG
  defaults have no template/config backing yet, so they join this tab when
  that backing exists rather than in v1.)* A **"More Settings…"** button at
  the bottom opens the deep-config surface in the main pane.
- **Style tab** — the site-wide styles scope: the `src/styles` stylesheets
  listed with open-in-editor (the retained `.file` → editor pipeline); theme
  identity and theme tokens follow as Component Editor slice 2 (#492)
  deepens.

### 3.3 Deep config (main pane)

The existing `PlistEditorView` surface (Website, Analytics, Redirects,
Licensing, Email Security, Security Reports, Social, Workers) stays exactly
as built, entered via **Site ▸ Website Settings…** and the Website inspector's
"More Settings…" — no longer via a navigator row. The old spec §7's styles and
installed-components list sections are dropped entirely: browsing is
superseded by selection-driven entry and the palette.

### 3.4 Component/style entry

- **Primary:** select a block on the canvas → selection inspector shows its
  props/styles → an **Edit Component** affordance drills into the Component
  Editor takeover.
- **Palette:** the WYSIWYG palette (#1224/#1225) lists installed components
  with insert and edit affordances.
- **Site-wide styles:** the Website inspector's Style tab (§3.2).
- No flat browse lists anywhere in settings.

## 4. Toolbar

All changes via `.toolbar(id: "site")`; frozen-ID rules apply (IDs are
append/retire-only, items render unconditionally).

- **Retired:** `panes`. Its frozen raw value is removed; SwiftUI drops unknown
  IDs from saved customization sets without error, and
  `SiteToolbarItemIDTests` documents the retirement (first retired ID).
- **New frozen ID `insert`** — a `plus` menu: **New Page…, New Post…, New
  Collection Entry…** (reusing the navigator content-command actions), then a
  **Blocks** section listing the theme's insertable components, inserting at
  the canvas insertion point with the same actions as the palette. The Blocks
  section appears once #1224's palette actions exist; the menu ships
  content-only before that. *New Component…* is developer-facing and lives in
  File ▸ New only.
- **New frozen ID `websiteInspector`** — the `globe` toggle for §3.2.
- **Defaults:** `insert` · `openInBrowser` · `deploy` · `chat` ·
  `websiteInspector` · `inspector`, plus the self-hiding status items
  (`sync`, `securityReports`). The two inspector toggles sit last on the
  trailing edge, matching Pages.
- **Demoted to the hidden palette:** `graph`, `backup`, `audit` — each keeps
  its Site-menu equivalent per #518's "menu is the durable path" convention.
- The `.searchable` field and all already-hidden palette items are unchanged.

## 5. Menus

- **Site** gains **Website Settings…** and **Graph…** (Cleanup… carries over
  from the old spec).
- **View** replaces the pane toggles with **Show Website Inspector**; ⌥⌘I
  stays on the selection inspector, and the Website inspector binds ⌥⌘J
  (adjacent to ⌥⌘I; no existing binding uses it).
- Focused-value plumbing follows the established `.focusedSceneValue` pattern
  (`InspectorPanelActions` grows the website case).

## Slices

Each independently shippable; none blocked on #1221.

1. **Website inspector + row removal** — the §3.2 inspector content, the
   mutually-exclusive activation enum, the navigator row removal, and
   Site ▸ Website Settings….
2. **Mode-switch removal** — retire `panes`, drill-in Done chrome for
   editor/graph/cleanup takeovers, View/Site menu updates.
3. **Toolbar re-curation** — `insert` (content-only v1), `websiteInspector`,
   new default set, demotions.
4. **Blocks in the + menu** — after #1224's palette actions exist; a shared
   action layer keeps palette and menu from drifting.

## Testing

- `SiteToolbarItemIDTests`: new IDs, retired `panes`, new default set.
- `SiteWindowModel` tests: inspector exclusivity enum (activating website
  deactivates selection and vice versa), website context editability gate,
  drill-in Done routing back to canvas, `.route` selection restoring the
  canvas from a takeover.
- `SiteNavigatorModel` / `buildSiteURLTree` tests updated for website-row
  removal.
- Full `swift test` before push (suites string-match template markup), plus a
  local Xcode 27 run for `AnglesiteAppTests` per CONTRIBUTING (CI cannot
  execute them).

## Risks

- **Inspector exclusivity joins the #968/#969-sensitive gate.** Mitigated by
  modeling activation as one enum and keeping every transition a single
  synchronous transaction; new lifecycle tests cover the toggle interplay.
- **First frozen-ID retirement.** SwiftUI ignores unknown IDs in saved
  customizations, so stale sets degrade silently; the test suite documents the
  precedent so future retirements follow the same path.
- **Discoverability of site settings drops one notch** (no sidebar row). The
  Website inspector toggle is always visible in the default toolbar and the
  Site menu carries the durable path; acceptable per the visitor-only sidebar
  goal.
- **Blocks-in-menu depends on palette actions** (#1224). The + menu ships
  content-only first, so slice 4 can trail the epic without blocking slices
  1–3.
- **Done-chrome regressions:** drill-in surfaces (component editor, plist
  editor, graph, cleanup) each currently assume mode-switch exit paths;
  the takeover header must not break their internal navigation (e.g. the
  plist editor's own tab rail). Covered by the routing tests above.
