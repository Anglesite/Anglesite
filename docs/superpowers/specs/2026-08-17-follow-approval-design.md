# Follow approval: pending requests + Accept/Reject

Design for [#965](https://github.com/Anglesite/Anglesite/issues/965).

## Problem

`FollowersModel`/`FollowersView`/`ActivityPubFollowers` are entirely read-only. Inbound
`Follow` activities are (presumably) auto-accepted by `@dwk/activitypub`, so an owner never
sees or decides who follows their site. Facebook and LinkedIn — the product's secondary
comparison point ("replace Facebook and LinkedIn for known contacts") — are both
approval-gated. A follower list the owner cannot curate is a broadcast audience, not a
contact graph, and is a prerequisite for #963's contact list (the gate that decides who is a
"known contact" is this approval step).

## Scope

This repo (`Anglesite/Anglesite`) only. **Revised after verifying upstream state directly**
(see below) — most of the "upstream" half the issue describes turns out to already be merged:

- **`davidwkeith/workers` `main`** (commit `096d04b`, #476, closing #473) already ships
  `manuallyApprovesFollowers`, pending-follower tracking (`followers.accepted_at`), and
  owner-triggered `Accept` of a pending follower via the outbox. Owner `Reject` of a pending
  follow has been a recognized outbox control activity since the earlier #447 — it already
  works upstream today, `CommunityMembershipClient` (below) just never grew a Swift method
  for it. **Not implemented in this session** (still a separate repo) because none of it
  needs to be — it already shipped.
- **Still genuinely missing upstream**: an *externally* bearer-gated `GET <actor>/follow_requests`
  listing route. Only an internal, `@dwk/mastodon-api`-only variant
  (`__client/follow_requests`, gated on a stricter internal-only header) exists on `main`
  today. This matches what `CommunityMembershipClient.listFollowRequests()` already assumes
  in its own doc comments (citing a not-yet-landed PR #488) — the app was already written
  ahead of this one piece, and this plan doesn't change that. A 404 here continues to mean
  "not available yet," not a failure.
- **App** (this repo): everything below.

Per `CONTRIBUTING.md` ▸ "`@dwk/workers` catalog coordination," the app side stays
backward-compatible with that one still-missing route (404 degrades to "feature inert," not
an error) — no other part of this feature is speculative.

Detection of *new* pending requests polls only while a site's window is open (no
always-on/background-when-closed daemon — that's `AnglesiteRemote`/#1208 territory) and does
not persist "last seen count" across app launches (a relaunch re-baselines silently).

## Wire contract (already implemented upstream, reused as-is)

`Sources/AnglesiteCore/CommunityMembershipClient.swift` already implements this exact
contract, for the same reason: it operates on this site's own personal actor
(`ActivityPubActor.actorURL`), not a separate Group actor — `ModerationModel` already uses it
against the same actor URL `FollowersModel` resolves. Confirmed against the current
`davidwkeith/workers` `main` checkout, not just the Anglesite-side comments.

**`GET <actor>/follow_requests`** — owner-only, `Authorization: Bearer <token>`. Unpaged flat
JSON (mirrors `GET <actor>/blocked`): `{"items": [{"actor": "<IRI>", "addedAt": "<ISO 8601>"}], "total": <n>}`.
Decoded by `CommunityMembershipClient.listFollowRequests() -> [PendingFollower]`
(`PendingFollower.id` is the actor IRI itself — there is no separate Follow-activity id to
track; Accept/Reject target the actor, not the Follow).

**`POST <actor>/outbox`** (the same endpoint `ActivityPubOutboxBackfill` already POSTs to,
same `Authorization: Bearer <token>`):

```json
{
  "@context": "https://www.w3.org/ns/activitystreams",
  "type": "Accept",
  "actor": "<site actor IRI>",
  "object": "<follower actor IRI>"
}
```

`"type": "Reject"` for reject, same shape. `CommunityMembershipClient.acceptFollow(target:)`
already sends the `Accept` form; this plan adds the symmetric `rejectFollow(target:)`.

**Auth**: the existing `SecretAccounts.activityPubPublishToken(siteID:)` Keychain secret —
already provisioned when ActivityPub is activated for a site (see
`ActivityPubKeyProvisioning`), already used for outbox backfill and by `ModerationModel`. No
new secret/token type.

**Backward compatibility**: a 404 from `listFollowRequests()` (the one upstream piece not yet
externally reachable — see Scope) means "not available yet," not a failure — the pending
section stays hidden rather than showing an error. Exactly `ModerationModel.loadPendingFollowers()`'s
existing rule, reused verbatim.

## App-side components

### `AnglesiteCore`: `CommunityMembershipClient` (extend, don't duplicate)

No new client type. `CommunityMembershipClient` already has `listFollowRequests()` and
`acceptFollow(target:)` against exactly this actor; adding a parallel type would mean two
Swift clients hitting the same endpoints. This plan adds one method:

- `func rejectFollow(target: URL) async throws` — mirrors `acceptFollow(target:)` exactly,
  `"type": "Reject"` instead of `"type": "Accept"`, same `post(_:)` helper.

### `FollowersModel`

- New `pendingRows: [PendingRequestRow]` — `PendingRequestRow { let request: PendingFollower;
  var profile: ActorProfile? }`, mirroring how `FollowerRow` pairs `actor` with enrichment.
  Reuses `PendingFollower` (`Sources/AnglesiteCore/PendingFollower.swift`) as-is rather than a
  new DTO — `id`/`actor` are the same value (there's no separate Follow-activity id to carry).
- `pendingState` — a state machine **separate** from the existing `State`, with cases
  `.unknown / .loading / .loaded / .unavailable / .unreachable(String)`. `.unavailable` is set
  by catching `CommunityMembershipError.requestFailed(status: 404, body: _)`, the same guard
  `ModerationModel.loadPendingFollowers()` already uses.

  This deliberately departs from the issue's own sketch ("`State` grows a pending case"):
  pending-list availability is orthogonal to whether the main follower list loaded
  successfully, and folding it into the top-level `State` would make the pane's primary
  list-loading state depend on an unrelated fetch (e.g. the main list could be `.loaded`
  while pending is still `.loading`, or vice versa after a mid-session upstream deploy).

- `func accept(_ row: PendingRequestRow) async` / `func reject(_ row: PendingRequestRow)
  async`: optimistically removes the row from `pendingRows`; on failure, restores it and sets
  a `pendingActionFailure: String?` (same additive-not-replacing pattern as
  `loadMoreFailure` — a failed accept/reject shouldn't blank the whole pending section).
  `reject(_:)` is only ever called from `confirmReject()`, gated by a `rejectConfirmation:
  PendingRequestRow?` property — the exact `banConfirmation`/`confirmBan()` shape
  `ModerationModel` already establishes, reused for consistency rather than inventing a new
  confirmation idiom.
- A dedicated `CommunityMembershipClient` instance, built the same way
  `ModerationModel`/`CommunitiesModel` build theirs: `ownActorURL` from
  `ActivityPubActor.actorURL(siteURL:)` (already resolved for the existing
  `ActivityPubFollowersClient`) plus `publishToken` read via `SecretStore` +
  `SecretAccounts.activityPubPublishToken(siteID:)`. `FollowersModel` gains a `secretStore:
  any SecretStore = PlatformSecretStore.make()` init parameter, matching `ModerationModel`'s.
- Pending rows reuse the existing enrichment pipeline (`ActorProfileCache`,
  `enrichIfNeeded`, `AvatarLoader`) — a pending row's `actor` enriches exactly like a
  follower row's.
- A poll `Task`, started from `configure(site:)` once `pendingState` first resolves to
  something other than `.unavailable`, re-checking every 5 minutes. Stopped from
  `SiteWindowModel.close()` alongside the existing `preview.close()`/`sync.stop()` teardown
  (and restarted implicitly the next time `loadAndStart(...)` calls `configure(site:)` —
  covering both a fresh window open and a window replayed onto a different site).
- `onNewPendingRequests: ((Int) -> Void)?` — fired with the current total `pendingRows.count`
  whenever it exceeds the last-notified count (tracked in a private `lastNotifiedPendingCount`),
  not on every poll and not on the initial load. Using the running total (not a per-poll delta)
  means a later notice always reflects the true current count rather than losing an earlier,
  unread arrival when Notification Center replaces the stable-identifier banner.

### `FollowersView`

- New "Pending Requests" section above the existing follower list. Hidden entirely when
  `pendingState` is `.unavailable` or `pendingRows` is empty — no error noise for a
  capability that hasn't shipped upstream yet, no dead space for a site with nothing pending.
- Each row: avatar + name/handle (existing row UI) + **Accept** and **Reject** buttons.
- **Reject** is confirmed via `.confirmationDialog` ("Reject follow request from *name*?",
  destructive role) before calling `reject(_:)` — mac-assed-app-spec §5 ("make destructive
  actions explicit... proportionate to their consequences") and §9 ("alert for consequential
  confirmation"). **Accept** has no confirmation — it's not destructive.
- Both buttons keyboard-reachable (standard `Button`, no custom hit-testing) and carry
  explicit `.accessibilityLabel`s ("Accept follow request from *name*" /
  "Reject follow request from *name*") rather than bare "Accept"/"Reject" — VoiceOver
  navigating row-to-row needs the per-row context that sighted users get from layout
  (mac-assed-app-spec §6).

### Notifications

- `CompletionNotificationHub.wire(...)` gains a `followers: FollowersModel` parameter,
  wiring `onNewPendingRequests` to a new `CompletionNoticeBuilder.followRequest(siteName:
  siteID: count:)` ("1 new follow request" / "N new follow requests"). Follows the existing
  per-operation-builder pattern (`deploy`/`backup`/`audit`). Clicking the notice focuses the
  site's window via `WindowRouter.shared.requested`, exactly what `CompletionNotifier`
  already does for every existing notice — it does not deep-link to a specific pane; no
  existing notice does, and adding that would be new routing infrastructure this issue
  doesn't need.
- Justified under mac-assed-app-spec §7 ("notifications sparingly, only for timely
  information that warrants interruption") — a stranger asking to follow is exactly the kind
  of thing an owner curating a contact graph wants to know about promptly, unlike routine
  follower-count churn (which stays silent, as today).

## Testing

- `CommunityMembershipClientTests` addition: `rejectFollow(target:)` POSTs a `Reject`
  activity with the right `actor`/`object`, mirroring the existing `acceptFollow`/`follow`
  request-shape tests in that file.
- `FollowersModelTests` additions: pending load into `.loaded`/`.unavailable` (404 → empty,
  not an error), accept/reject optimistic update + failure rollback, `rejectConfirmation`
  gating (`reject(_:)` never called directly by the view — only `confirmReject()`), polling
  fires `onNewPendingRequests` once per genuinely-new arrival (not on every poll, not on
  first load).
- `CompletionNoticeBuilder` wording test for the new follow-request notice (singular vs.
  plural, identifier stability so repeated notices replace rather than stack).

## Non-goals

- No upstream (`davidwkeith/workers`) implementation in this session — the one piece still
  missing there (the externally bearer-gated `follow_requests` listing route) is a pending
  dependency to note in the PR body, per the catalog-coordination convention. Everything else
  the issue describes upstream has already shipped.
- No always-on/background-when-app-closed polling.
- No persistence of "last seen pending count" across app launches.
