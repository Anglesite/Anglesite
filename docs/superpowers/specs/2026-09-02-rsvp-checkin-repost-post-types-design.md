# RSVP, check-in, and repost as publishable post types

- **Issue:** [#1598](https://github.com/Anglesite/Anglesite/issues/1598)
- **Status:** Approved, ready for implementation plan
- **Scope:** One bundled PR (owner decision, superseding the `🏭 Blocked: human` triage note asking whether to split)

## Problem

Anglesite already recognizes RSVP and check-in posts on the *receiving* side —
`Resources/Template/worker/post-type-discovery.ts` implements [Post Type
Discovery](https://www.w3.org/TR/post-type-discovery/) and classifies incoming
mentions/Micropub payloads as `rsvp`/`checkin`, but three of its branches are
deliberate `return null` guards with a comment explaining they're
"Unsupported post types — these should be skipped, not miscategorized." There
is no way to *author* an RSVP, check-in, or repost from Anglesite itself:
`Sources/AnglesiteCore/ContentTypeRegistry.swift` (the list of types an owner
can create in the app) only covers note, article, photo, album, bookmark,
reply, like, announcement, event, review, member, blogroll.

Repost is the same gap from a different angle: received reposts already
render as facepiles in `src/components/Interactions.astro`, but reposting
*someone else's* post is not a publishable type either.

## Non-goals

- Changing how *received* interactions (facepiles, comments, mentions) render
  in `Interactions.astro` — that pipeline is untouched; this spec is entirely
  about outbound/authored posts.
- Any change to `@dwk/micropub` or the `davidwkeith/workers` monorepo.
  Confirmed by reading `packages/micropub/src/mf2.ts`: it's a generic mf2
  pass-through with no type whitelist (it only strips `mp-*` command keys),
  so `rsvp`/`checkin`/`repost-of` properties already flow through it
  untouched. The only gate is this repo's own `discoverCollection`.
- A picker/autocomplete UI for choosing the target event (RSVP) or reposted
  entry (repost). Existing relationship fields (`reply.inReplyTo`,
  `like.likeOf`, `bookmark.bookmarkOf`) are plain validated-URL text fields
  with no lookup UI, and RSVP/repost follow the same precedent.

## Design

### Overview

Add three content types the same way every recent post type has been added
(most recently h-resume, #964/#1117): a `ContentTypeDescriptor` in
`ContentTypeRegistry.swift`, a matching Zod schema in `content.config.ts`,
collection-list wiring, `Hentry.astro` rendering branches, a `feeds.ts`
entry, and — new for these three — flipping three `return null` branches in
`post-type-discovery.ts` to real collection names.

All three are h-entry-shaped, like reply/like/bookmark, not richer types like
event/review — no new Astro layout files.

### New field kind: `ContentTypeField.Kind.enum`

Today every `ContentTypeField.Kind` case is free-form (`.string`, `.number`,
`.url`, etc.) — there is no bounded-choice kind. `review.rating` (`.number`)
is the closest analog to RSVP's status and is *not* a picker today, just a
numeric `TextField`.

RSVP's status is a real closed vocabulary (yes/no/maybe/interested per the
IndieWeb RSVP convention), so add:

```swift
enum Kind {
    // ...existing cases...
    case `enum`(cases: [String])
}
```

`TypedEntryEditorView`'s per-field switch gains a `.enum(let cases)` branch
rendering a `Picker` over `cases`. This is the one piece of genuinely new
registry surface area; everything else below reuses existing machinery.

### The three descriptors

All three follow the titleless, URL-identified shape `reply`/`like` already
use (no `title` field; `requiredURLFields` surfaces the relationship URL in
`NewCollectionEntrySheet`'s create flow automatically, no sheet-level code
change needed).

**`rsvp`** → `ContentStorage.collection("rsvps")`

| field | kind | required | mf2 property |
|---|---|---|---|
| `inReplyTo` | `.url` | yes | `u-in-reply-to` (target h-event) |
| `rsvp` | `.enum(["yes","no","maybe","interested"])` | yes | `p-rsvp` |
| `content` | `.markdown` | no | `e-content` |

`microformat: "h-entry"`, `schemaType: nil` (matches `like`/`reply` — a
terse interaction, not a rich result).

**`checkin`** → `ContentStorage.collection("checkins")`

| field | kind | required | mf2 property |
|---|---|---|---|
| `location` | `.string` | yes | `p-location` |
| `venueUrl` | `.url` | no | `u-in-reply-to` (venue permalink, Foursquare/Swarm-style) |
| `content` | `.markdown` | no | `e-content` |

`microformat: "h-entry"`, `schemaType: nil`.

**`repost`** → `ContentStorage.collection("reposts")`

| field | kind | required | mf2 property |
|---|---|---|---|
| `repostOf` | `.url` | yes | `u-repost-of` |
| `content` | `.markdown` | no | `e-content` (repost commentary) |

`microformat: "h-entry"`, `schemaType: nil`.

Note: `SocialPublishPlan.swift`'s `webmentionTargets(in:frontmatter:)`
already iterates `["inReplyTo", "bookmarkOf", "likeOf", "repostOf"]` — a
dangling hook from earlier scaffolding with no descriptor to feed it. This
`repost` descriptor is what finally makes that reachable.

### Composer UI

No new sheet. `NewCollectionEntrySheet` already surfaces required `.url`
fields generically via `ContentTypeDescriptor.requiredURLFields`, so
`inReplyTo` (rsvp) and `repostOf` (repost) appear in the create flow exactly
like `reply.inReplyTo`/`like.likeOf` do today.

Open implementation-time question (not blocking, resolved while coding):
whether RSVP's required `.enum` status field also needs quick-create
surfacing, or can default (e.g. to `"yes"`) and be adjusted afterward in the
full `TypedEntryForm` editor. Precedent (`review.rating`, a required
`.number`) is *not* specially surfaced in the create sheet today, so
defaulting-then-editing is the likely answer, but implementation should
confirm this doesn't produce a confusing initial state.

### Astro rendering (`Hentry.astro`)

- Add a fourth relationship branch alongside the existing reply/bookmark/like
  branches (lines ~61–96) for `u-repost-of`, using the same
  `EmbedCard`-with-snapshot-or-bare-link pattern.
- RSVP reuses the existing `u-in-reply-to` branch unchanged for its event
  reference, and adds `<data class="p-rsvp" value={d.rsvp}>{label}</data>`,
  mirroring `Hreview.astro`'s `<data class="p-rating" value={d.rating}>`
  pattern.
- Check-in renders `<span class="p-location h-card">{d.location}</span>`,
  plus the existing `u-in-reply-to` branch conditionally when `d.venueUrl` is
  set.

`src/lib/schema.ts`'s `hentrySchema()` switch returns `null` for all three
collections, matching `likes` — no JSON-LD rich result, consistent with them
being terse interactions rather than structured content like event/review.

### Collection wiring (`content.config.ts`, `collections.ts`)

- `content.config.ts`: add `defineCollection` blocks for `rsvps`, `checkins`,
  `reposts`, each spreading `socialFields` (same as every other collection —
  this is what makes `posse`/`syndicateTo` frontmatter settable, see POSSE
  below) plus the fields from the table above.
- `collections.ts`: add all three to `HENTRY_COLLECTIONS` (and therefore
  `ENTRY_COLLECTIONS`, so they route through `[collection]/[...slug].astro`
  without a 404). Not added to `TAGGED_COLLECTIONS` — matching
  likes/bookmarks/replies, which aren't tagged either.

### Feeds (`feeds.ts`)

Per owner decision: include all three in `FEED_COLLECTIONS`, the same
treatment as likes/bookmarks/replies (not the events/reviews/announcements
exclusion). Add entries with `deriveTitle`:

- rsvp: `"RSVP'd {status} to {event title}"` (falling back to the raw
  `inReplyTo` URL if no cached event title, matching the existing
  reply/bookmark/like fallback pattern)
- checkin: `"Checked in at {location}"`
- repost: `"Reposted {title or repostOf URL}"`

Extend `interactionContentFallback()`'s ternary chain with matching branches
for empty-body entries of these three collections.

### Worker / Post Type Discovery (`post-type-discovery.ts`)

Replace the three `return null` guards with real classification, **in the
same priority position they already occupy** (checked before
`in-reply-to`/`bookmark-of`/`like-of`, preserving the documented rule that
RSVP+in-reply-to must classify as RSVP, not reply):

```ts
if (hasProperty(mf2, "repost-of")) return "reposts";
if (hasProperty(mf2, "rsvp")) return "rsvps";
if (hasProperty(mf2, "checkin")) return "checkins";
if (hasProperty(mf2, "video")) return null; // still unsupported
```

No `worker.ts` changes: `handleMicropub`'s `generatePostUrl` already
delegates entirely to `discoverCollection`, so it benefits automatically
once PTD returns real collection names instead of `null`.

### POSSE eligibility (repost)

No new code. `POSSEClients.swift`'s pipeline
(`SocialPublishPlan.posseTargets(in:)`) is frontmatter-driven (`posse`/
`syndicateTo` keys), not collection-gated, and `reposts` is not added to
`excludedCollections` (`["blogroll"]`). Reposts become POSSE-eligible the
moment the `reposts` Zod schema spreads `socialFields`, covered above.

## Testing

- **Swift:** `ContentTypeRegistryTests` — new descriptors resolve correctly
  (`descriptor(id:)`, `descriptor(forCollection:)`, `requiredURLFields`,
  `titleField` is nil for all three). A `TypedEntryEditorView` test for the
  new `.enum` Kind rendering as a Picker with the right cases.
- **TS/Vitest:** `post-type-discovery.test.ts` — flip the three existing
  `toBeNull()` assertions to `toBe("reposts")`/`toBe("rsvps")`/
  `toBe("checkins")`; add/keep the RSVP+in-reply-to priority case, now
  asserting `"rsvps"` instead of `null`. Extend any `feeds.ts` tests for the
  three new `FEED_COLLECTIONS` entries.
- **Astro:** extend existing `Hentry.astro`/`schema.ts` rendering tests (if
  present) to cover the `u-repost-of`, `p-rsvp`, and `p-location` branches.
- Per `AGENTS.md`: touching `Resources/Template/` means running `swift test`
  too, since some Swift tests couple to template markup.

## Open questions resolved during brainstorming

1. **RSVP status representation** — new `Kind.enum` case (owner chose this
   over a one-off `.string` + UI hack), since it's reusable and correct.
2. **Feed inclusion** — include all three, treating them as interaction
   posts (like likes/bookmarks/replies) rather than structured content (like
   events/reviews).
