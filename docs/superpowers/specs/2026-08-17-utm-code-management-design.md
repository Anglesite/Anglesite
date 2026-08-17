# UTM Code Management UI — design

**Issue:** [#1092](https://github.com/Anglesite/Anglesite/issues/1092)
**Repo:** Anglesite only (app + template). No sidecar/paired PR needed.

## Problem

Blogs that earn affiliate/referral commissions need to attribute traffic to the
channel it came from. RSS feed readers and Fediverse followers both click
through to permalinks that currently carry no attribution — a site owner
looking at analytics can't tell "this visit came from someone's RSS reader" or
"this visit came from a Fediverse follower" from organic/direct traffic.

**Owner decision (2026-08-15, on the issue):** UTM params apply to **both**
RSS and Fediverse/POSSE links. "Tracking" means a **local per-site registry of
active codes** — self-contained, no dependency on #1114 (richer analytics
attribution can layer on once that lands).

## Scope

A UTM campaign registry, managed from **Website Settings → Analytics**, that:

- lets the owner define named UTM campaigns (the standard five parameters:
  source, medium, campaign, term, content),
- assigns at most one campaign per RSS collection (blog, notes, articles,
  photos, albums, bookmarks, replies, likes) and at most one campaign to the
  Fediverse outbox,
- automatically tags the corresponding permalinks at build/runtime with no
  further owner action once assigned.

A campaign can be defined without being assigned anywhere yet (a draft), and
the same campaign can be assigned to any number of collections plus
Fediverse simultaneously — "at most one per target" is a target-side
constraint, not a campaign-side one.

Out of scope: click tracking/analytics of the UTM codes themselves (that's
what "no dependency on #1114" rules out), and a general-purpose ad-hoc link
shortener/builder for pasting into arbitrary channels — this only wires into
RSS and Fediverse, the two channels the issue names, though the campaign
registry's shape does not preclude adding more consumers later.

## Data model

New Swift type in `AnglesiteCore`, following `RedirectsStore`'s shape and
conventions exactly:

```swift
public struct UTMCodesStore: Sendable {
    public struct Campaign: Sendable, Equatable, Codable, Identifiable {
        public var id: UUID
        public var source: String       // utm_source
        public var medium: String       // utm_medium
        public var campaign: String     // utm_campaign
        public var term: String?        // utm_term
        public var content: String?     // utm_content
        public var appliesTo: Set<Target>
    }

    public enum Target: String, Sendable, Codable, CaseIterable, Hashable {
        case blog, notes, articles, photos, albums, bookmarks, replies, likes
        case fediverse
    }

    public enum ValidationError: Error, Equatable {
        case duplicateTarget(UTMCodesStore.Target)
        case missingRequiredField(UUID, field: String) // source/medium/campaign empty on an assigned campaign
    }

    public init(sourceDirectory: URL, fileManager: FileManager = .default)
    public func load() throws -> [Campaign]           // [] when file absent
    public func save(_ campaigns: [Campaign]) throws   // validates, then atomic pretty-printed write
    public static func validate(_ campaigns: [Campaign]) throws
}
```

The `blog`/`notes`/… target cases match `FEED_COLLECTIONS`'s keys in
`Resources/Template/src/lib/feeds.ts` — the Swift and TS sides must stay in
lockstep on these string values since they round-trip through the same JSON.

## Storage

`Source/utm-codes.json` — git-tracked, rooted at `sourceDirectory` like
`redirects.json`, for the same reason: this is site content that must be
readable both by the Astro build (RSS/Atom/JSON Feed generation) and by the
Cloudflare Worker at runtime (Fediverse fan-out), and it should travel with
the repo like other site content, not live in app-owned `Config/`.

Example:

```json
[
  {
    "id": "6E4E2B0A-....",
    "source": "rss",
    "medium": "feed",
    "campaign": "affiliate-2026",
    "appliesTo": ["blog", "notes"]
  },
  {
    "id": "9C1A....",
    "source": "fediverse",
    "medium": "social",
    "campaign": "affiliate-2026",
    "appliesTo": ["fediverse"]
  }
]
```

## Template consumers

### RSS / Atom / JSON Feed

New `Resources/Template/src/lib/utm-codes.ts`, mirroring
`scripts/redirects.ts`'s `readRedirects`:

```ts
export interface UTMCampaign {
  source: string;
  medium: string;
  campaign: string;
  term?: string;
  content?: string;
  appliesTo: string[];
}

export function readUTMCodes(siteRoot: string): UTMCampaign[];
// Missing file -> []. Malformed JSON/entries -> console.warn + best-effort
// filtered result, same tolerance as readRedirects — a build must never fail
// because utm-codes.json was hand-edited into a bad state.

export function activeCampaignFor(campaigns: UTMCampaign[], target: string): UTMCampaign | undefined;

export function tagUrl(url: string, campaign: UTMCampaign | undefined): string;
// Appends utm_source/utm_medium/utm_campaign/utm_term/utm_content via
// URLSearchParams. Returns `url` unchanged when campaign is undefined.
```

`feed-data.ts`'s `mapCollection` calls `tagUrl` once when it builds each
`FeedItem.link` (`toFeedItem` in `feeds.ts`), keyed by the collection name
being mapped. Because `FeedItem.link` is the single value reused across that
collection's RSS, Atom, and JSON Feed output, and the combined root feeds
reuse each item's already-built `FeedItem`, tagging happens once per entry
and is inherited everywhere that entry's link appears — no separate
"combined feed" target needed.

### Fediverse

`worker/worker.ts` gains a static import, same pattern as the existing
`experiments.json` import:

```ts
import utmCodesArtifact from "../utm-codes.json";
```

In `fanOutMicropubCreateToActivityPub`, before `location` is assigned to
`note.url`, look up the campaign whose `appliesTo` includes `"fediverse"`
(if any) and tag it with the same `tagUrl` helper (hoisted into
`utm-codes.ts` so both the Astro lib code and the Worker import the same
pure function — the Worker bundle already pulls from `src/lib` elsewhere, so
this isn't a new cross-boundary import pattern).

## Swift UI

**Analytics tab (`PlistEditorView`):** a new subsection below the existing
Cloudflare/custom-analytics box — a summary line ("3 UTM codes configured,
applied to Blog, Notes, Fediverse" / "No UTM codes configured") and a
**"Manage UTM Codes…"** button opening a new `UTMCodesSheet` (the issue's
"popup UI").

**`UTMCodesSheet`:** a `List` of campaigns — each row shows
`source/medium/campaign` plus target chips — with add/delete, and each row
editable inline or via a disclosed edit form: text fields for source,
medium, campaign, term, content, and a checkbox per RSS collection plus a
Fediverse toggle for `appliesTo`. Saving runs `UTMCodesStore.validate()`
first and surfaces the first validation error inline (duplicate target,
missing required field on an assigned campaign), the same inline-error
convention `RedirectsStore`'s consumer uses today.

**`PlistEditorModel`:** a `utmCampaigns: [UTMCodesStore.Campaign]` array plus
`isUTMCodesDirty`/`saveUTMCodes()`, registered as a `DirtyFacet` exactly like
`redirectEntries`/`saveRedirects()` is today (see the `DirtyFacet` array
around line 1296 of `PlistEditorModel.swift`).

## Testing

- **Swift** (`AnglesiteCoreTests`): `UTMCodesStoreTests` — round-trip
  load/save, missing-file → `[]`, `validate` catching a duplicate target and
  a missing required field on an assigned campaign. Mirrors
  `RedirectsStoreTests`' existing shape.
- **TS** (`npx tsx --test`, per this repo's lib-test convention — pure logic
  only, no `import.meta.glob`): `utm-codes.test.ts` covering `readUTMCodes`
  (missing file, malformed JSON, malformed entries — mirrors
  `redirects.test.ts`) and `tagUrl` (tagged vs. untagged, existing query
  string preserved). A `feeds.test.ts`/`feed-data` case asserting a
  collection with an active campaign produces a tagged `FeedItem.link` and
  one without does not.
- **Worker** (`worker.test.ts`): extend the existing
  `fanOutMicropubCreateToActivityPub` coverage with a case asserting
  `note.url` carries the UTM params when a campaign targets `"fediverse"`,
  and is untouched when none does.

## Non-goals

- No click-through analytics for the UTM codes themselves (registry only —
  matches the owner's #1114-independent decision).
- No arbitrary/ad-hoc UTM link builder for pasting into channels outside
  RSS/Fediverse (the two channels the issue names).
- No paired sidecar PR — this is app + template only, no MCP schema change.
