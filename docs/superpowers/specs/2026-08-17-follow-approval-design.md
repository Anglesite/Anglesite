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

This repo (`Anglesite/Anglesite`) only. The full feature spans two repos:

- **Upstream** (`davidwkeith/workers`, `@dwk/activitypub`): hold inbound `Follow` in a
  pending state instead of auto-accepting; owner-only endpoints to list pending requests and
  send Accept/Reject. **Not implemented in this session** — a separate repo, separate PR.
- **App** (this repo): everything below.

Per `CONTRIBUTING.md` ▸ "`@dwk/workers` catalog coordination," the app side is built against
an assumed wire contract, kept backward-compatible (a 404/missing capability degrades to
"feature inert," not an error), so this PR can merge before the upstream capability ships.
The assumed contract is documented below and must be noted in the PR body as a pending
upstream dependency.

Detection of *new* pending requests polls only while a site's window is open (no
always-on/background-when-closed daemon — that's `AnglesiteRemote`/#1208 territory) and does
not persist "last seen count" across app launches (a relaunch re-baselines silently).

## Assumed wire contract

Documented here as the contract the upstream PR needs to implement; the app decodes exactly
this shape.

**`GET /users/site/followers/pending`** — owner-only, `Authorization: Bearer <token>`. Same
`OrderedCollection`/`OrderedCollectionPage` shape as the existing public
`/users/site/followers` endpoint (`totalItems`/`first`, `orderedItems`/`next`), except each
page item is an object, not a bare actor IRI string:

```json
{ "id": "<Follow activity IRI>", "actor": "<follower actor IRI>", "published": "<ISO 8601>" }
```

The `Follow` activity's `id` is required (not just the actor IRI) because Accept/Reject
reference it.

**`POST /users/site/outbox`** (the endpoint `ActivityPubOutboxBackfill` already POSTs to,
same `Authorization: Bearer <token>`):

```json
{
  "@context": "https://www.w3.org/ns/activitystreams",
  "type": "Accept",
  "actor": "<site actor IRI>",
  "object": "<Follow activity id>"
}
```

`"type": "Reject"` for reject. This is standard AS2 (Accept/Reject wrapping the Follow) and
reuses the existing outbox-POST wire shape rather than inventing a bespoke endpoint — the
worker fans the activity out to the follower's inbox and, on Accept, folds the actor into the
public followers collection.

**Auth**: reuses the existing `SecretAccounts.activityPubPublishToken(siteID:)` Keychain
secret — already provisioned when ActivityPub is activated for a site (see
`ActivityPubKeyProvisioning`), already used for outbox backfill. No new secret/token type.

**Backward compatibility**: a 404 (or any non-2xx before the upstream capability ships) on
the pending endpoint means "not available yet," not a failure — the pending section stays
hidden rather than showing an error.

## App-side components

### `AnglesiteCore`: `ActivityPubFollowRequestsClient` (new)

Parallel to `ActivityPubFollowersClient`, but *authenticated* — that type's doc comment is
explicit that it "deliberately carries no auth layer at all" for the public collection, so
this is a new type rather than an extension of it. Shape:

- `pending() async throws -> FollowersCollection`-equivalent head, `page(at:)` for paging —
  same decode pattern as `ActivityPubFollowersClient`, but items decode to a new
  `PendingFollowRequest { id, actor, publishedAt }` rather than a bare `URL`.
- `accept(_ request: PendingFollowRequest) async throws` / `reject(_:)` — POST to the outbox
  per the contract above.
- Injectable `Transport` (same typealias shape as the other two clients), so it unit-tests
  without real networking.
- A dedicated `unavailable` signal (e.g. treat 404 as a typed case, not lumped into the
  generic `requestFailed`) so `FollowersModel` can distinguish "not shipped yet" from a real
  error without string-matching status codes at the call site.

### `FollowersModel`

- New `pendingRows: [PendingRequestRow]` (mirrors `FollowerRow`: `actor`, `profile`, plus the
  `Follow` activity `id`) and `pendingState` — a state machine **separate** from the existing
  `State`, with cases `.unknown / .loading / .loaded / .unavailable / .unreachable(String)`.

  This deliberately departs from the issue's own sketch ("`State` grows a pending case"):
  pending-list availability is orthogonal to whether the main follower list loaded
  successfully, and folding it into the top-level `State` would make the pane's primary
  list-loading state depend on an unrelated fetch (e.g. the main list could be `.loaded`
  while pending is still `.loading`, or vice versa after a mid-session upstream deploy).

- `func accept(_ row: PendingRequestRow) async` / `func reject(_ row: PendingRequestRow)
  async`: optimistically removes the row from `pendingRows`; on failure, restores it and sets
  a `pendingActionFailure: String?` (same additive-not-replacing pattern as
  `loadMoreFailure` — a failed accept/reject shouldn't blank the whole pending section).
- Pending rows reuse the existing enrichment pipeline (`ActorProfileCache`,
  `enrichIfNeeded`, `AvatarLoader`) — a pending row's `actor` enriches exactly like a
  follower row's.
- A poll `Task`, started from `configure(site:)` once `pendingState` first resolves to
  something other than `.unavailable`, re-checking every 5 minutes. Stopped from
  `SiteWindowModel.close()` alongside the existing `preview.close()`/`sync.stop()` teardown
  (and restarted implicitly the next time `loadAndStart(...)` calls `configure(site:)` —
  covering both a fresh window open and a window replayed onto a different site).
- `onNewPendingRequests: ((Int) -> Void)?` — fired only when a poll's pending count is
  *greater* than the previous in-memory count (not on every poll, and not on the initial
  load — only genuinely new arrivals warrant an interruption).

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
  per-operation-builder pattern (`deploy`/`backup`/`audit`); clicking the notice routes
  through `WindowRouter` to the site's Followers pane, same as the existing notices.
- Justified under mac-assed-app-spec §7 ("notifications sparingly, only for timely
  information that warrants interruption") — a stranger asking to follow is exactly the kind
  of thing an owner curating a contact graph wants to know about promptly, unlike routine
  follower-count churn (which stays silent, as today).

## Testing

- `ActivityPubFollowRequestsClientTests` (new, `Tests/AnglesiteCoreTests`) — mirrors
  `ActivityPubFollowersClientTests`: injected transport, decode success/failure, the
  `.unavailable` (404) signal, accept/reject request shape.
- `FollowersModelTests` additions: pending load into `.loaded`/`.unavailable`, accept/reject
  optimistic update + failure rollback, polling fires `onNewPendingRequests` once per
  genuinely-new arrival (not on every poll, not on first load).
- `CompletionNoticeBuilder` wording test for the new follow-request notice (singular vs.
  plural, identifier stability so repeated notices replace rather than stack).

## Non-goals

- No upstream (`davidwkeith/workers`) implementation in this session — tracked as a pending
  dependency to note in the PR body, per the catalog-coordination convention.
- No always-on/background-when-app-closed polling.
- No persistence of "last seen pending count" across app launches.
