# Bluesky replies as the site's comment section (+ interaction backfeed)

**Date:** 2026-08-17
**Status:** Approved, ready for implementation planning
**Tracks:** #1236
**Builds on:** #362/V-3.4 (received-interaction canonicality, `docs/specs/2026-06-29-c3-received-interaction-canonicality.md`), #1234 (POSSE `bskyPostRef`/cover images), #1230

## Problem

`POSSESyndicationCommand` cross-posts each opted-in entry to Bluesky and sends a webmention
backfeed from the canonical post to the Bluesky copy, but nothing flows the other way: replies,
likes, and reposts an owner receives on Bluesky never appear back on their own site. The
AT Protocol blog's `bsky-conversation` pattern shows this is cheap to do well — Bluesky's public
AppView (`app.bsky.feed.getPostThread`, `getLikes`, `getRepostedBy`) is unauthenticated, permissive
CORS, and requires no comment-hosting or moderation database of our own: the owner moderates by
moderating their Bluesky thread.

## Decision: store-canonically, reusing C3 exactly

The issue's central open question — render-live (client-side fetch at page view) vs.
store-canonically (build-time snapshot into git, matching #362's received-interaction model) — is
decided in favor of **store-canonically**, for the same reasons #362 already gives: portability
across hosting providers, pure-static-friendly (no Worker required, no client-side network call on
every page view), and moderation-by-file-deletion consistent with how webmention/ActivityPub
interactions already work.

This is not a new rendering path. `Resources/Template/src/components/Interactions.astro` and
`Resources/Template/src/lib/interactions.ts` already render `data/interactions/*.json` generically
by `interactionType` (`reply` → threaded comment, `like`/`repost` → facepile, `mention`/`bookmark`
→ "mentioned by" line) with no branch on protocol source. **The render side needs no changes** —
only the write side (a new snapshot producer) and one schema widening (the `type` enum accepting
`"bluesky"` alongside `"webmention"`/`"activitypub"`/`"micropub"`).

## Where the thread URI comes from

No new linkage is needed. `POSSESyndicationLog` (`Sources/AnglesiteCore/POSSESyndicationLog.swift`,
`Config/posse-syndication.json`) already records, per successfully-syndicated entry:

- `canonicalURL` — the site's own post URL (the `target` for its received interactions)
- `syndicationURL` — the Bluesky permalink `https://bsky.app/profile/<handle>/post/<rkey>`
  (`BlueskyPOSSEClient.publicURL`, `Sources/AnglesiteCore/POSSEClients.swift`)

`<handle>/<rkey>` from `syndicationURL` is exactly the `at://<handle>/app.bsky.feed.post/<rkey>`
URI `getPostThread`/`getLikes`/`getRepostedBy` need — the same construction
`Resources/Template/scripts/embeds/adapters.ts`'s `resolveAdapter` already uses for inline Bluesky
embeds. This sync does **not** touch `bskyPostRef`/`site.standard.document` at all; it is
independent of the Standard Site publish pass.

## Components

### 1. `ReceivedInteraction.ProtocolType` — add `.bluesky`

`Sources/AnglesiteCore/ReceivedInteraction.swift`. Purely additive; no change to the type's
validation/serialization contract.

### 2. `BlueskyThreadClient` (new)

`Sources/AnglesiteCore/BlueskyThreadClient.swift`. Unauthenticated reader for
`public.api.bsky.app/xrpc/`:

- `app.bsky.feed.getPostThread?uri=<at-uri>&depth=100&parentHeight=0` — replies. `depth=100` is
  comfortably beyond any realistic personal-blog comment thread; deeper nesting is a documented
  limitation, not silently pretended-away (the API gives no truncation marker to detect and log
  against).
- `app.bsky.feed.getLikes?uri=<at-uri>&limit=100&cursor=…` — likes, cursor-paginated up to a hard
  cap of 20 pages (2000 likes) — no `cid` is passed, since `POSSESyndicationLog` never records one
  and the parameter is optional. The cap is silent (matches `AnnouncedPostSync.OutboxClient`'s own
  50-page outbox cap, also silent) rather than logged: these sync types have no established
  logging convention to hook into (unlike `MicropubContentSync`/`InboxSubmissionSync`, which do
  log), so this follows its closer sibling (`ReceivedInteractionSync`, `AnnouncedPostSync`) rather
  than inventing one.
- `app.bsky.feed.getRepostedBy` — same shape as `getLikes`, for reposts. Its items are bare actor
  profiles with no per-item timestamp (unlike `getLikes`'s `{actor, createdAt}` wrapping) — the
  mapping treats a missing `createdAt` as "fall back to sync time" so it degrades correctly
  whichever shape a given AppView response actually has, rather than asserting one.

Uses the same `POSSEHTTPTransport` typealias (`@Sendable (URLRequest) async throws -> (Data,
HTTPURLResponse)`) as `POSSEClients.swift` for injectable, mockable transport in tests.

### 3. `BlueskyBackfeedSync` (new)

`Sources/AnglesiteCore/BlueskyBackfeedSync.swift`, mirroring `ReceivedInteractionSync`'s
"`pullAndCommitIfConfigured` gated on site state, called once per site-open" shape — but the gate
is "`POSSESyndicationLog` has at least one `platform == "bluesky"` entry," not a provisioned D1
database, and no Cloudflare token is resolved (matches `AnnouncedPostSync`'s "no token needed"
precedent).

Per site-open:

1. Load `POSSESyndicationLog` from `configDirectory`; no-op (return 0) if there are no `"bluesky"`
   entries.
2. For each such entry, derive the `at://` URI from `syndicationURL`, then fetch its thread, likes,
   and reposts via `BlueskyThreadClient`.
3. Map each into `ReceivedInteraction` (mapping rules below), with `target` = that entry's
   `canonicalURL`.
4. If **any** entry's fetch hits a hard failure (network error, non-2xx, undecodable body — as
   opposed to a clean "not found" response), the whole pass skips its commit and returns 0. This
   mirrors `ReceivedInteractionSync.pullAndCommit`'s existing behavior for a failed D1 query:
   previously-synced snapshots are left untouched and the pass retries on the next site-open,
   rather than a transient failure on one post being misread as "this post now has zero replies"
   and deleting its real, previously-fetched snapshots.
5. Otherwise, call `ReceivedInteractionCommitter.commit(interactions:, scopedTo: [.bluesky],
   into: siteDirectory)` once with the full unioned set across every tracked post.

### 4. `ReceivedInteractionCommitter.commit` — add `scopedTo`

`Sources/AnglesiteCore/ReceivedInteractionCommitter.swift`. New parameter:

```swift
public static func commit(
    interactions: [ReceivedInteraction],
    scopedTo protocolTypes: Set<ReceivedInteraction.ProtocolType>? = nil,
    into siteDirectory: URL,
    ...
) async -> [String]
```

**Why this is needed:** `data/interactions/` is about to gain a second independent writer.
Today's reconcile ("delete any existing file whose id isn't in the set I just computed") assumes
it owns the whole directory — correct when there is one source, wrong the moment there are two,
since each source's reconcile pass would delete the other's files as "stale." `scopedTo` restricts
staleness deletion to existing files whose own decoded `type` is in `protocolTypes`; files of any
other (or unrecognized) type are left untouched, regardless of whether their id appears in the
passed-in `interactions`.

`nil` (the default) preserves exactly today's directory-wide behavior — every existing call site
(the committer's own unit tests, all single-source) is unaffected. The two real per-source
producers pass their own scope explicitly:

- `ReceivedInteractionSync`'s production call: `scopedTo: [.webmention]`
- `BlueskyBackfeedSync`'s call: `scopedTo: [.bluesky]`

### 5. `PreviewModel.open(site:)` — wire in the new sync

`Sources/AnglesiteApp/PreviewModel.swift`, alongside the existing pull-on-open sequence (currently
`InboxSubmissionSync` → `ReceivedInteractionSync` → `MicropubContentSync` → `AnnouncedPostSync` →
`CommunityMembersSync`). Add `BlueskyBackfeedSync.pullAndCommitIfConfigured(siteDirectory:,
configDirectory:)` to that list.

### 6. `interactions.ts` — schema widening only

`Resources/Template/src/lib/interactions.ts`: `type: z.enum([...])` gains `"bluesky"`. No other
change — `interactionsFor`, `parseInteractions`, and `Interactions.astro` are already generic
across `type`.

## Mapping rules

### Replies → `ReceivedInteraction(interactionType: .reply)`

Walk `thread.replies[]` recursively (both first-level and nested replies-to-replies), skipping any
node whose `$type` is `app.bsky.feed.defs#blockedPost` or `#notFoundPost` (moderation/deletion —
see below), and skipping any post carrying a self-label or AppView label in
`{porn, sexual, nudity, graphic-media}` (there is no content-warning UI in `Interactions.astro` to
gate display on, so exclusion is the safe default). Every surviving reply — at any depth — flattens
into the **same** chronological comment list the target page already renders; there is no nested-
reply UI today and this does not add one.

- `id`: `"bsky-\(rkey)"` — the reply post's own `at://` rkey. AT-proto TIDs are lowercase
  base32-sortable strings, already a subset of `ReceivedInteraction`'s `[A-Za-z0-9_-]+` id
  validation.
- `type`: `.bluesky`
- `source`: `https://bsky.app/profile/<handle-or-did>/post/<rkey>` (the reply's own permalink)
- `target`: the tracked entry's `canonicalURL`
- `author`: `name` = `displayName ?? handle`, `url` = `https://bsky.app/profile/<handle>`,
  `photo` = `avatar`
- `content`: `record.text`, truncated to ~500 chars per the existing convention
- `published`: `record.createdAt`
- `verified`: sync time (the AppView response itself is the verification — there is no separate
  handshake to record a distinct verification instant)
- `verificationStatus`: `.verified`

### Likes/reposts → `ReceivedInteraction(interactionType: .like / .repost)`

Bluesky has no distinct per-like/-repost resource URL (unlike a webmention `like-of`/`repost-of`
post) — the interaction *is* an actor's relationship to the target post. Both fields fall back to
the actor's own identity:

- `id`: `"bsky-like-" + POSSEStableKey.make("\(targetRkey)\n\(actorDID)")` (reposts: `"bsky-repost-"`
  prefix). Reuses the existing FNV-1a hex hash helper (`Sources/AnglesiteCore/POSSEClients.swift`)
  — already produces a `[0-9a-f]+` string, a safe subset of the id charset. Includes the target
  post's rkey so the same actor liking two different tracked posts doesn't collide.
- `source` / `author.url`: `https://bsky.app/profile/<handle>` (same value in both fields for this
  interaction kind, which is fine — the facepile in `Interactions.astro` already prefers
  `author.url` and only falls back to `source`)
- `author.name`/`photo`: from the like/repost actor
- `content`: `nil`
- `published`: the like/repost record's `createdAt`
- `verified`/`verificationStatus`: same as replies (sync time, `.verified`)

## Moderation semantics

Deliberately **identical** to today's webmention/ActivityPub interactions, not a new mechanism:

- A reply/like/repost removed on Bluesky's side (post deleted, actor blocks the site's account,
  etc.) simply stops appearing in the next `getPostThread`/`getLikes`/`getRepostedBy` response, so
  the next full-set reconcile deletes its snapshot file — the same "sender-side delete" behavior
  #362 already documents for webmention.
- Owner-side moderation (deleting the local JSON file to hide something the owner disagrees with
  but that's still live upstream) has the **same pre-existing limitation** #362 already notes for
  webmention/AP: since every site-open re-derives the *full current* upstream set, a manually
  deleted file for a still-live upstream interaction reappears on the next resync. This is a known
  gap tracked by a future moderation UI (V-5.3, #370) — this feature does not attempt to solve it,
  only to match existing behavior exactly, per the issue's "must disappear from the site the same
  way" framing (parity, not a new guarantee).

## Explicitly out of scope

- A real moderation/hide field (`moderation` in the schema) — pre-existing follow-up (#370/V-5.3).
- Unbounded pagination beyond the documented caps (thread depth 100, 20 pages of likes/reposts
  each) — both caps are silent (see "Components" ▸ "BlueskyThreadClient" above), matching
  `AnnouncedPostSync.OutboxClient`'s own precedent; neither is logged.
- Nested/threaded comment UI — replies flatten into the existing chronological list.
- Any change to `POSSESyndicationCommand`, `bskyPostRef`, or `site.standard.document` — this sync
  is fully independent of the Standard Site publish pass.

## Testing

- Swift: `BlueskyThreadClientTests` — decode a synthetic `getPostThread` response with nested
  replies, a `#blockedPost` branch, a `#notFoundPost` branch, and a self-labeled adult-content
  reply; decode `getLikes`/`getRepostedBy` responses including cursor pagination and the cap.
- Swift: `BlueskyBackfeedSyncTests` — no-ops with an empty/missing ledger; happy path produces the
  expected `ReceivedInteraction`s and commits once; a hard fetch failure on one tracked post skips
  the commit for the whole pass (previously-synced files untouched).
- Swift: `ReceivedInteractionCommitterTests` — new case(s) proving `scopedTo` isolation: committing
  `.bluesky` interactions does not delete existing `.webmention` files and vice versa; existing
  (nil-scope) tests continue to pass unchanged.
- Template: `interactions.test.ts` — extend fixtures/assertions to cover `type: "bluesky"`.
- No changes needed to the `scripts/embeds/` test suite — that pipeline (inline post embeds) is
  unrelated to this feature.

## Repo scope

Anglesite-app only — no MCP schema change, so no paired `anglesite-skills` PR. Template changes
(`Resources/Template/src/lib/interactions.ts`) are app-only per `AGENTS.md` ▸ "Two-repo
coordination."
