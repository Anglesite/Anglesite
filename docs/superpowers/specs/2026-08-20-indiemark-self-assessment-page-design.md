# IndieMark self-assessment page — design

**Issue:** [#1599](https://github.com/Anglesite/Anglesite/issues/1599)
**Date:** 2026-08-20

## Problem

Anglesite already implements a large slice of the IndieWeb protocol surface (webmention,
micropub, IndieAuth, microformats2, microsub, websub, ActivityPub, POSSE — see epic #334/#963
and `Resources/Template/worker/worker.ts`), but nothing in the app or template tells an owner
or contributor how that maps to [IndieMark](https://indieweb.org/IndieMark), the IndieWeb
community's own self-assessment guide.

### Correction to the issue's premise

The issue asks for "IndieMark 3.0" coverage. That version does not exist. The current live wiki
page is simply **IndieMark** — an explicitly "rough and in-progress" guide organized as
**Level 0–6**, each level built from several **axes** (identity, authentication, posts,
syndication, posting UI, navigation, search, aggregation, interactivity, security, handling
responses). The page itself warns: "please do not use it to determine if your site 'is a member
of the IndieWeb'", and levels 3+ are marked TBD/needs-updating upstream. This design targets the
current axis/level structure, not a nonexistent 3.0 rubric, and carries that caveat onto the
page itself.

## Goals

- Give any Anglesite-built site a `/indiemark/` page that walks the current IndieMark axes and
  states, per axis, whether the feature is present.
- Where a real build-time signal exists, compute it from *this site's* actual state (not just
  "the platform supports it in general").
- Be honest about the limits: some axes (IndieAuth, Microsub, ActivityPub, HTTPS, on-site
  search) depend on Worker secrets/bindings that aren't visible to an Astro build, so those are
  described as platform-provided rather than falsely claimed as "verified for this site." POSSE
  has no per-site config surface today, so it's called out as manual.

## Non-goals

- Numeric point scoring / "Level N achieved" badges. The upstream rubric itself is inconsistent
  and TBD past Level 2 — assigning a score would overclaim precision the source material doesn't
  support.
- New `.site-config` keys or worker changes to make additional axes computable. This is a
  documentation/reporting page over data that already exists.
- Auto-linking the page from a global nav/footer — the template has no such shared component
  today; new utility pages (`/search`, `/resume`) are standalone routes an owner links to if
  they want.

## Design

### Route

`Resources/Template/src/pages/indiemark.astro` → `/indiemark/`, using `BaseLayout` the same way
`search.astro` and `resume.astro` do. Not injected into any nav.

### Signal computation — `src/lib/indiemark.ts`

A pure function, following the repo's existing convention (pure logic in `src/lib`, tested with
`npx tsx --test`/`node:test`, keeping `import.meta.glob` and other Astro-only APIs in the
`.astro` file). Shape:

```ts
export type AxisStatus = "detected" | "supported" | "manual";

export interface AxisResult {
  axis: string;          // e.g. "posts"
  status: AxisStatus;
  detail: string;        // one-sentence explanation for the page
}

export interface IndieMarkInputs {
  hasProfile: boolean;                    // src/data/profile.json exists
  collectionCounts: Record<string, number>; // non-draft entry count per collection
  webmentionReceiveEnabled: boolean;      // .site-config WEBMENTION_RECEIVE_ENABLED
  micropubEnabled: boolean;               // .site-config MICROPUB_ENABLED
  websubEnabled: boolean;                 // .site-config WEBSUB_ENABLED
  homeIndexable: boolean;                 // "/" not in robots-config.json noindex

}

export function assessIndieMark(inputs: IndieMarkInputs): AxisResult[];
```

`indiemark.astro` gathers the inputs the same way existing pages already do (the
`import.meta.glob("../data/profile.json")` pattern from `Hcard.astro`, `getCollection()` per
content type, `readConfig()` from `scripts/config.ts`, `readRobotsConfig()` from
`src/lib/robots-config.ts`), calls `assessIndieMark`, and renders the result.

### Per-axis classification

| Axis | Status | Basis |
|---|---|---|
| Identity (h-card) | **detected** | `src/data/profile.json` exists |
| Posts (post types) | **detected** | which of `notes`/`articles`/`replies`/`bookmarks`/`likes`/`photos`/`albums`/`events`/`reviews`/`blog` have ≥1 non-draft entry |
| Search discoverability | **detected** | home page absent from `robots-config.json`'s `noindex` |
| Webmention (receiving) | **detected** | `.site-config` `WEBMENTION_RECEIVE_ENABLED` |
| Micropub | **detected** | `.site-config` `MICROPUB_ENABLED` |
| WebSub | **detected** | `.site-config` `WEBSUB_ENABLED` |
| Authentication (IndieAuth) | **supported** | worker implements it; gated by `INDIEAUTH_OWNER_PASSWORD`/`TOKEN_SIGNING_KEY`/`SOCIAL_KV` Worker secrets, invisible to the Astro build |
| Aggregation (Microsub) | **supported** | worker implements it; gated by Worker bindings, same reason |
| Handling responses (ActivityPub) | **supported** | worker implements it; gated by Worker bindings, same reason |
| Security (HTTPS) | **supported** | Cloudflare Workers hosting always serves HTTPS; not a per-site toggle |
| Own-site search backend | **supported** | Pagefind ships in every site's `postbuild`; only real after a production build, so can't be probed from the page's own build |
| Microformats2 markup | **supported** | template components emit it (h-entry, h-card, h-adr, etc.); not independently re-validated by this page |
| Syndication (POSSE) | **manual** | no `.site-config` surface for configured silo targets today; done via the `syndicate` skill |

### Page content

- Intro paragraph: what IndieMark is, link to `https://indieweb.org/IndieMark`, and the
  upstream caveat carried forward verbatim in spirit — this is an informal, in-progress
  community guide, not a certification, and shouldn't be read as a checklist to "pass."
- One section per axis in the table above: axis name, a status indicator (✅ detected / ℹ️
  platform-supported / — manual), and the one-sentence `detail` from `AxisResult`.
- No aggregate score or "Level N" badge.

### Testing

- `node:test` (`npx tsx --test`) unit tests for `assessIndieMark()` covering: profile present/
  absent, a collection with/without non-draft entries, each `.site-config` flag on/off, home
  page indexable/noindexed.
- No new build-time test needed — this doesn't add a build step, so the existing template
  build/typecheck/lint gates (`npm run lint && npm run typecheck && npm test`, per
  `CONTRIBUTING.md`) cover the `.astro` page compiling correctly. `swift test` also gets run per
  `CONTRIBUTING.md` ▸ Testing since this touches `Resources/Template/`.

## Open questions

None — all resolved during brainstorming (see conversation for the three confirmed decisions:
target the current IndieMark rubric and note the "3.0" correction in the PR; ship as a
per-site template page rather than app-repo-only docs; compute real per-site signals where a
build-time source exists, and be explicit where it doesn't).
