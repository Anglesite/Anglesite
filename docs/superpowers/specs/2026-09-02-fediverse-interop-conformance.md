# Fediverse interop conformance — static pass and live runbook (#1241)

- **Date:** 2026-09-02
- **Status:** Static pass complete; live pass pending (needs accounts on the target platforms)
- **Issue:** [#1241 — Fediverse interop conformance pass](https://github.com/Anglesite/Anglesite/issues/1241)
- **Related:** the [Fediverse handle design](2026-08-04-fediverse-handle-design.md) (#1097,
  whose Decision 2 table this corrects), [#1239](https://github.com/Anglesite/Anglesite/issues/1239)
  (handle scheme), [#1240](https://github.com/Anglesite/Anglesite/issues/1240) (attachment fan-out),
  [#1242](https://github.com/Anglesite/Anglesite/issues/1242) (host-meta, closed: not required by
  any maintained server), defects filed from this pass: [#1770](https://github.com/Anglesite/Anglesite/issues/1770),
  [#1771](https://github.com/Anglesite/Anglesite/issues/1771)

## Results up front

The "arbitrary ActivityPub networks" story in the handle design rests on one conformant actor.
This pass checked that actor — as `worker.ts` + `@dwk/activitypub` 1.0.0-beta.4 actually serve
it — against the current default-branch **ingestion code** of Mastodon, Misskey, Sharkey,
Pixelfed, Friendica, and Akkoma (Pleroma's forge was unreachable; see §Method). Nothing here is a
live observation yet; §Live runbook is the checklist for that half.

1. **The dotted handle is safe everywhere checked.** `preferredUsername: "example.com"` passes
   every remote-username validator: Mastodon, Misskey and every *key fork sharing its
   `ApPersonService`, Pixelfed, Friendica (no grammar at all), and Akkoma/Pleroma (email-shaped
   nickname). Only Misskey imposes a length cap (128 characters) — no registrable hostname
   approaches it.
2. **Follow → Accept is sound on paper for all of them.** Every platform delivers to the
   actor-specific inbox when `endpoints.sharedInbox` is absent; the package auto-accepts and
   answers with an `Accept` embedding the full `Follow`, which is the shape Pixelfed's strictest
   validator and Misskey's resolver both want.
3. **Text `Note`s render on Mastodon, Misskey, Friendica.** Pixelfed ignores text-only Notes by
   design (expected, per the design's Decision 2).
4. **Photo `Note`s are broken on Pixelfed — the #1240 fix does not reach it.** The fan-out emits
   `Image` attachments with no `mediaType`; Pixelfed's inbox validator makes `mediaType` required
   and drops the whole Note. Mastodon, Misskey, and Friendica tolerate the omission. Filed as
   [#1770](https://github.com/Anglesite/Anglesite/issues/1770).
5. **The actor has no `icon` and no `url`** — every platform shows a placeholder avatar and links
   "original profile" to the AS2 document. Filed as
   [#1771](https://github.com/Anglesite/Anglesite/issues/1771).

## What the actor actually serves

Reconstructed from `Resources/Template/worker/worker.ts` (`activityPubConfig`,
`withPreferredUsername`, `handleWebFinger`, `fanOutMicropubCreateToActivityPub`) and the pinned
package's `dist/as2.js` / `dist/object.js` / `dist/signature.js`. No deployed Anglesite actor was
reachable from this session (the only Anglesite-adjacent domain probed, `dwk.io`, forwards its
WebFinger to a Mastodon 4.7.1 instance), so this is the shape the code produces, not a capture.

**WebFinger** — `GET /.well-known/webfinger?resource=acct:example.com@example.com` →
`200 application/jrd+json`, `access-control-allow-origin: *`:

```json
{
  "subject": "acct:example.com@example.com",
  "links": [
    { "rel": "self", "type": "application/activity+json", "href": "https://example.com/users/site" }
  ]
}
```

The legacy `acct:site@example.com` (and, with an `AP_USERNAME` override, the hostname default)
resolve too, with `subject` set to the canonical handle. There is no `aliases` array and no
`profile-page` link; neither is required by any consumer checked. The composed worker does
**not** serve `/.well-known/host-meta`; #1242 established that no maintained server needs it
(Pleroma/Akkoma try the lrdd template first but fall back to the canonical WebFinger URL), and
the optional XRD lives in a separate catalog Worker, `@dwk/host-meta`, a site can activate.

**Actor** — `GET /users/site` with an AS2 `Accept`:

```json
{
  "@context": ["https://www.w3.org/ns/activitystreams", "https://w3id.org/security/v1",
    { "manuallyApprovesFollowers": "as:manuallyApprovesFollowers", "toot": "http://joinmastodon.org/ns#",
      "discoverable": "toot:discoverable",
      "webfinger": "https://purl.archive.org/socialweb/webfinger#webfinger",
      "showFeatured": "toot:showFeatured", "showMedia": "toot:showMedia", "showRepliesInMedia": "toot:showRepliesInMedia" }],
  "id": "https://example.com/users/site",
  "type": "Person",
  "preferredUsername": "example.com",
  "name": "<AP_DISPLAY_NAME, else the hostname>",
  "summary": "Posts from example.com",
  "inbox": "https://example.com/users/site/inbox",
  "outbox": "https://example.com/users/site/outbox",
  "followers": "https://example.com/users/site/followers",
  "following": "https://example.com/users/site/following",
  "manuallyApprovesFollowers": false,
  "discoverable": true,
  "publicKey": { "id": "https://example.com/users/site#main-key", "owner": "https://example.com/users/site", "publicKeyPem": "…" },
  "webfinger": "acct:example.com@example.com"
}
```

Notable absences, each checked against the consumers below: **no `endpoints`** (the worker sets
`sharedInbox: false` because `POST /inbox` is the visitor inbox-capture feature, #587); **no
`url`**; **no `icon`**; no `alsoKnownAs`, `featured`, or `attachment` (profile fields).
`type` is `Group` when `AP_ACTOR_TYPE=Group` (#907) — the Group path is outside this pass.

**A published post** — a Micropub create becomes, via the package's `#asOutboxActivity`:

```json
{
  "@context": "https://www.w3.org/ns/activitystreams",
  "id": "https://example.com/users/site/outbox/<uuid>",
  "type": "Create",
  "actor": "https://example.com/users/site",
  "published": "<ISO-8601>",
  "to": ["https://www.w3.org/ns/activitystreams#Public"],
  "cc": ["https://example.com/users/site/followers"],
  "object": {
    "type": "Note",
    "id": "https://example.com/users/site/outbox/<uuid>/object",
    "attributedTo": "https://example.com/users/site",
    "published": "<ISO-8601>",
    "to": ["https://www.w3.org/ns/activitystreams#Public"],
    "content": "<caption, may be empty for a photo-only post>",
    "url": "https://example.com/posts/<slug>?utm_…",
    "attachment": [ { "type": "Image", "url": "https://example.com/media/photo.jpg", "name": "<alt>" } ]
  }
}
```

`content` is the Micropub `content` as-is (plain text or HTML); there is no `summary`/`sensitive`,
no `tag` array, and — the defect — no `mediaType` on attachments.

**Delivery** — one signed `POST` per follower inbox (`(request-target) host date digest
content-type` covered, SHA-256 `Digest`, `content-type: application/activity+json`), which is the
header set every checked verifier requires (Mastodon and Misskey both insist on `digest` for
`POST`). Inbound `Follow`s are stored, auto-accepted (`manuallyApprovesFollowers: false`), and
answered with `{ "type": "Accept", "actor": <actor>, "object": <the Follow, verbatim> }`.

## Method

Static reading of each platform's remote-actor and inbox code on its default branch as of
2026-09-02, chosen for being what the platform's own follow/search path executes — not its docs:

| Platform | Code read (default branch) |
|---|---|
| Mastodon | `app/models/account.rb` (`USERNAME_RE`), `app/services/activitypub/process_account_service.rb`, `app/lib/activitypub/activity/create.rb`, `app/lib/activitypub/parser/media_attachment_parser.rb` |
| Misskey | `packages/backend/src/core/activitypub/models/ApPersonService.ts` (`validateActor`), `ApNoteService.ts`, `ApImageService.ts`, `ApInboxService.ts`, `RemoteUserResolveService.ts`, `WebfingerService.ts` |
| Sharkey | `…/models/ApPersonService.ts` (same `validateActor` regex) |
| Pixelfed | `app/Util/ActivityPub/Helpers.php`, `Inbox.php`, `Inbox/HandlesCreates.php`, `Inbox/HandlesFollows.php`, `Validator/{Follow,Accept}.php`, `config/pixelfed.php` |
| Friendica | `src/Model/APContact.php`, `src/Network/Probe.php`, `src/Core/Search.php`, `src/Protocol/ActivityPub/{Receiver,Processor}.php`, `src/Model/Post/Media.php` |
| Akkoma | `lib/pleroma/user.ex` (`remote_user_changeset`), `lib/pleroma/web/activity_pub/object_validators/user_validator.ex` |
| Pleroma | **not fetched** — `git.pleroma.social` returned 404 for raw files and its API from this network. Akkoma's two files above are Pleroma's, forked; treat the Pleroma row as inferred from that lineage until the live sweep confirms it. |

"Static" in the matrix means "the code path would accept this input"; it says nothing about
instance configuration (blocklists, media limits) or about rendering beyond what the ingestion
code stores.

## Platform × behavior matrix

This corrects and extends the handle design's Decision 2 table. The **Verified** column is the
whole point of #1241: "static" rows become "live" only by running §Live runbook.

| Platform | `@example.com@example.com` resolves | Follow → Accept | Text `Note` | Photo `Note` (as emitted today) | Verified |
|---|---|---|---|---|---|
| Mastodon | yes — `USERNAME_RE` allows interior `.`/`-`; hard limit 2048; `webfinger` back-link accepted with `acct:` prefix (`split_acct` strips it) and **supersedes** `preferredUsername`, so the worker's patched value must stay in sync (it does) | yes; auto-accept | renders | renders — `MediaAttachmentParser` infers the type from the URL and downloads the file | live (prior, per design doc) |
| Threads | yes (per design doc) | — | — | — | live (prior, per design doc) |
| Misskey | yes — `validateActor` requires `/^\w([\w-.]*\w)?$/`, ≤128 chars; search parses `user@host` on the first `@` | yes; `Accept` resolves the embedded `Follow` | renders (HTML → MFM) | renders — `ApImageService` needs only an `https` `url`; `name` becomes alt text | **static** |
| Sharkey / *key forks sharing `ApPersonService` | as Misskey (identical regex) | as Misskey | as Misskey | as Misskey | **static** |
| Pixelfed | yes — `extractUsername` accepts `[A-Za-z0-9_.-]`; actor needs `inbox`, `publicKey.{id,publicKeyPem}`, and `manuallyApprovesFollowers` (absent ⇒ treated as **private**; ours is `false`) | yes; `Accept` validator wants `object.{id,type,actor,object}` — satisfied by the verbatim embedded `Follow` | ignored by design (no attachment) | **dropped** — `verifyAttachments` requires `mediaType` (#1770); after the fix, only `image/jpeg`, `image/jpg`, `image/png`, `image/gif` pass a default-config instance (**no WebP**) | **static** |
| Friendica | yes — no username grammar; `Search` strips the leading `@`, `APContact::getByURL` accepts any `FILTER_VALIDATE_EMAIL`-shaped address, `nick` = `preferredUsername` | yes; per-actor inbox used when `sharedinbox` is empty | renders (HTML → BBCode) | renders — `Image` with null `mediaType` is stored as `TYPE_UNKNOWN`, then `Post\Media::fetchAdditionalData` HEAD-fetches the URL and upgrades it to an image | **static** |
| Akkoma | yes — `UserValidator` checks `preferredUsername` is valid UTF-8 only; `remote_user_changeset` validates `nickname` (`example.com@example.com`) against an email regex that allows `.` | yes | renders | renders (not traced further; Pleroma-lineage media handling needs only `url`) | **static** |
| Pleroma | inferred as Akkoma (same validator lineage; upstream source not fetched) | inferred | inferred | inferred | **unverified** |
| PeerTube | n/a — follows a `Person` but renders `Video` only | — | not rendered | not rendered | out of scope (design doc) |
| Lemmy / PieFed / Mbin | n/a — group-only; v5 Communities path | — | — | — | out of scope (#1241 non-goal) |

### Per-platform notes

**Mastodon.** The FEP-2c59 `webfinger` property matters more than it looks: `ProcessAccountService`
reads it *before* `preferredUsername`, and if it names a handle whose WebFinger lookup does not
loop back to the actor IRI, account processing fails. The worker rewrites it to
`acct:<handle>@<host>` alongside `preferredUsername`, and the alias entries keep the legacy
`acct:site@<host>` resolving, so both forms loop back. Keep `withPreferredUsername` and
`handleWebFinger` deriving from the same `resolvePreferredUsername` — that invariant is what
`worker.test.ts`'s handle tests pin.

**Misskey.** Strictest validator of the set. Besides the username regex it requires `inbox`,
`outbox`, `followers`, `following` to share the actor's host (they do), silently *drops* a
`sharedInbox` on a different host (we send none), and rejects a `Note` whose `id` or
`attributedTo` host differs from the sender's (both are `/users/site/...`). It stores
`preferredUsername` verbatim, so the displayed handle is `@example.com@example.com`.

**Pixelfed.** Three gates in `HandlesCreates`: the object must carry `to` (ours does), must not
be a `Question`, and — for a non-reply `Note` — must pass `verifyNoteAttachment`. Only the last
fails today. Pixelfed also treats a missing `manuallyApprovesFollowers` as *private*; the package
always emits it, so follows show as following, not requested.

**Friendica.** The most forgiving reader and the only one that actively repairs a missing
`mediaType` by fetching the URL. It reads the FEP-2c59 back-link under the *older*
`https://webfinger.net/#` term, not the `purl.archive.org` one the package advertises, so it
falls back to `nick@host` — which is the same handle, so nothing is lost.

**Akkoma / Pleroma.** `preferredUsername` is only checked for UTF-8 validity at ingest; the real
constraint is the changeset's email-regex on `preferredUsername@host`, which a dotted local part
satisfies. Pleroma's own copy could not be fetched (its GitLab 404s raw/API requests from this
network); confirm on a live instance — it is the one row in this table with no primary source.

## Interop caveats for the handle design

Fold these into the design doc's Decision 2 (done in the same change as this document):

- **Pixelfed needs `mediaType`, and its default allow-list excludes WebP** — see #1770.
  Until fixed, "Pixelfed reach" (#1240) is not delivered.
- **No avatar, no profile link** on any platform — see #1771.
- **Misskey caps `preferredUsername` at 128 characters.** Not reachable by a real hostname
  (a registrable hostname is ≤253 characters but practically far shorter); noted for completeness.
- **`www.` hosts.** The username strips `www.` but the handle's domain half is the serving host,
  so a site served at `www.example.com` federates as `@example.com@www.example.com`. Cosmetic, but
  it means the apex should be the canonical origin when both answer.

## Live runbook (the remaining #1241 checkboxes)

Needs: a deployed Anglesite site with ActivityPub active on its production domain, and one
account each on a Pixelfed, Friendica, and Misskey (or Sharkey) instance, plus a Pleroma or Akkoma
instance for the username sweep. Record outcomes by editing the **Verified** column above from
"static" to "live YYYY-MM-DD" and noting any deviation inline.

For each platform:

1. **Resolve.** Search `@example.com@example.com`. Confirm the profile appears with the handle
   shown as `@example.com` (truncated) / `@example.com@example.com` (full). Note the avatar
   (expected: placeholder, #1771) and what the profile link opens.
2. **Follow.** Follow the actor. On the site, confirm the follower appears in the Followers pane
   (`ActivityPubFollowersClient`). On the platform, confirm the state is *following*, not
   *requested* (an `Accept` reached the platform's per-actor inbox — `sharedInbox: false`).
3. **Text Note.** Publish a text-only post from the app. Record whether and how it renders
   (Pixelfed: expected absent). Note HTML handling (links, paragraphs) and whether the post's
   `url` is linked.
4. **Photo Note.** Publish a post with one JPEG photo and alt text, and one with a WebP photo.
   Record rendering, alt text, and — on Pixelfed — whether the JPEG appears only after
   #1770 ships and whether the WebP ever does.
5. **Unfollow.** Unfollow and confirm the site's follower count drops (the `Undo(Follow)` path).

Pleroma/Akkoma sweep: steps 1–2 only; the question is whether the dotted handle resolves and
displays. Record it in the Pleroma row, which is otherwise inferred.

Any deviation from the static prediction becomes its own issue against the actor/worker
composition (#1241 non-goals) — do not add platform-specific code here.

## Sources

- [W3C ActivityPub](https://www.w3.org/TR/activitypub/), [RFC 7033 WebFinger](https://www.rfc-editor.org/rfc/rfc7033.html),
  [FEP-2c59 Discovery of a Webfinger address from an ActivityPub actor](https://codeberg.org/fediverse/fep/src/branch/main/fep/2c59/fep-2c59.md)
- Mastodon: [`account.rb`](https://github.com/mastodon/mastodon/blob/main/app/models/account.rb),
  [`process_account_service.rb`](https://github.com/mastodon/mastodon/blob/main/app/services/activitypub/process_account_service.rb),
  [`media_attachment_parser.rb`](https://github.com/mastodon/mastodon/blob/main/app/lib/activitypub/parser/media_attachment_parser.rb)
- Misskey: [`ApPersonService.ts`](https://github.com/misskey-dev/misskey/blob/develop/packages/backend/src/core/activitypub/models/ApPersonService.ts),
  [`ApNoteService.ts`](https://github.com/misskey-dev/misskey/blob/develop/packages/backend/src/core/activitypub/models/ApNoteService.ts),
  [`ApImageService.ts`](https://github.com/misskey-dev/misskey/blob/develop/packages/backend/src/core/activitypub/models/ApImageService.ts)
- Sharkey: [`ApPersonService.ts`](https://activitypub.software/TransFem-org/Sharkey/-/blob/develop/packages/backend/src/core/activitypub/models/ApPersonService.ts)
- Pixelfed: [`Helpers.php`](https://github.com/pixelfed/pixelfed/blob/dev/app/Util/ActivityPub/Helpers.php),
  [`HandlesCreates.php`](https://github.com/pixelfed/pixelfed/blob/dev/app/Util/ActivityPub/Inbox/HandlesCreates.php),
  [`HandlesFollows.php`](https://github.com/pixelfed/pixelfed/blob/dev/app/Util/ActivityPub/Inbox/HandlesFollows.php),
  [`config/pixelfed.php`](https://github.com/pixelfed/pixelfed/blob/dev/config/pixelfed.php)
- Friendica: [`APContact.php`](https://github.com/friendica/friendica/blob/develop/src/Model/APContact.php),
  [`Receiver.php`](https://github.com/friendica/friendica/blob/develop/src/Protocol/ActivityPub/Receiver.php),
  [`Post/Media.php`](https://github.com/friendica/friendica/blob/develop/src/Model/Post/Media.php)
- Akkoma: [`user.ex`](https://akkoma.dev/AkkomaGang/akkoma/src/branch/develop/lib/pleroma/user.ex),
  [`user_validator.ex`](https://akkoma.dev/AkkomaGang/akkoma/src/branch/develop/lib/pleroma/web/activity_pub/object_validators/user_validator.ex)
- `@dwk/activitypub` 1.0.0-beta.4 and `@dwk/webfinger` 1.0.0-beta.2 as published on npm
  (`dist/as2.js`, `dist/object.js`, `dist/signature.js`, `dist/jrd.js`, `dist/handler.js`)
