# Vouch protocol for webmention spam mitigation (#1597)

Status: **known bug found in PR review, fix in progress** — see "Known issue" below
Repos touched: `davidwkeith/workers` (`@dwk/webmention`), `Anglesite/Anglesite` (this repo)

## Known issue (found in review of Anglesite/Anglesite#1604, 2026-08-20)

The `verifyVouch` design below (and the shipped implementation in
[davidwkeith/workers#505](https://github.com/davidwkeith/workers/pull/505), already merged)
checks that the vouch page links to the **target's** domain. Per
[indieweb.org/Vouch](https://indieweb.org/Vouch) and this issue's own "Gap" wording ("a URL
that the target already links to"), the receiver should instead check that the vouch page
links to the **source's** domain, *and* that the vouch domain is one the receiver already
trusts (a list, not an open-ended link check) — the trust chain is "someone I already trust
vouches for this stranger." As designed and shipped, the check is backwards and has no trust
list, so `vouch=<the source URL itself>` verifies unconditionally once `verifySource` has
already proven that link exists — a spammer gets a "Vouched" badge for free. The rest of this
document (and the implementation plan) is being corrected; sections below marked with the
original (buggy) semantics are being updated in place, not left as historical record, since
that would leave a live design doc describing a real vulnerability as intended behavior.

## Problem

Anglesite receives and verifies inbound Webmentions (`Resources/Template/worker/worker.ts`
→ `@dwk/webmention`), but link-verification (source really links to target) is the only
trust signal. There's no [Vouch](https://indieweb.org/Vouch) support: an optional sender-supplied
URL that, when it also links to the target's domain, raises confidence the mention isn't spam.

## Where the logic belongs

The fetch-and-verify pipeline — receive → enqueue → `verifySource` → inbox store — lives
entirely in `@dwk/webmention` (published from the sibling `davidwkeith/workers` monorepo).
`Resources/Template/worker/worker.ts` only composes it (`createWebmention`,
`createWebmentionQueueConsumer`, `createD1Inbox`). Vouch verification (fetch a URL, check it
links to a domain) is structurally identical to the existing `verifySource` check, so it
belongs in the same package, following the same pattern already used for RSVP
(`rsvp.ts`) and mf2 enrichment (`enrich.ts`): an optional signal added to the job → checked
in the queue consumer → stored on `VerifiedMention` → additive D1 column.

This ships as a paired change across both repos — the same shape as the existing
anglesite-skills MCP pairing documented in `AGENTS.md` ▸ "Two-repo coordination": sidecar
ships first in a tagged release, then the app PR consumes it.

Current pinned version in `Resources/Template/package.json` is `@dwk/webmention@1.0.0-beta.1`
(confirmed against `origin/main` of `davidwkeith/workers`, which is 5 commits ahead of the
locally checked-out branch). The sidecar change shipped in
[davidwkeith/workers#505](https://github.com/davidwkeith/workers/pull/505) without a manual
version bump (review feedback: version bumps come only from a dedicated `pnpm changeset
version` run per `RELEASING.md`, never hand-edited alongside feature work) — the actual next
published version is whatever that run produces, not a number this doc can predict.

## Sidecar: `@dwk/webmention` (davidwkeith/workers)

### `WebmentionJob`

Add `readonly vouch?: string` — the raw vouch URL from the form POST. Optional field on a
Queue message body is backward-compatible (older/newer consumers both tolerate its absence).

### Receive handler (`index.ts` — `createWebmention`)

Read the `vouch` form field alongside `source`/`target`. If present but not a syntactically
valid `http(s)` URL (same check `validateWebmentionParams` already applies to
`source`/`target`), **drop it silently** — proceed as if no vouch was supplied. Vouch is a
supplementary trust signal per spec, not a hard requirement; a malformed vouch parameter must
never turn into a whole-mention rejection. This mirrors the issue's own framing ("flag it...
rather than rejecting outright").

### `verifyVouch` (new, `verify.ts`)

```ts
export interface VouchResult {
  readonly verified: boolean;
}

export async function verifyVouch(
  vouchUrl: string,
  target: string,
  options?: VerifyOptions,
): Promise<VouchResult>
```

Fetches `vouchUrl` through the same `safeFetch` wrapper `verifySource` uses (SSRF-safe host
checks, capped redirects, timeout). Extracts links the same way `extractLinks`/`sourceLinksTo`
already do, but the match is **hostname equality** against `new URL(target).hostname`, not
full-URL equality — i.e. any link on the vouch page pointing anywhere under the target's host
counts ("links to the domain of the target," per the Vouch spec). Any fetch failure, non-2xx
status, or oversized/unreadable body yields `{ verified: false }`; the function never throws.

### Queue consumer (`index.ts` — `createWebmentionQueueConsumer`)

Vouch verification only runs when the *primary* `verifySource` check already succeeded — vouch
never overrides or substitutes for the source→target link check, which remains the hard gate.
When `job.vouch` is present and the mention verifies, call `verifyVouch(job.vouch, target, …)`
and store the outcome as `vouch: { url: job.vouch, verified }` on the mention passed to
`inbox.store()`.

Three resulting states on a stored mention:

- `vouch` absent — no signal sent (today's behavior, unchanged).
- `vouch.verified === true` — vouched: the vouch URL really does link to the target's domain.
- `vouch.verified === false` — vouch attempted but didn't check out (unreachable, or doesn't
  link to the domain). Arguably a *stronger* spam signal than no vouch at all — a forged vouch
  attempt — so it's tracked distinctly rather than collapsed into "absent."

### `VerifiedMention` / `inbox.ts`

```ts
readonly vouch?: { readonly url: string; readonly verified: boolean };
```

Two new D1 columns via the existing `ADDED_COLUMNS` additive-migration list (same mechanism
already used for `rsvp`, `id`, the mf2 columns): `vouch_url TEXT`, `vouch_verified INTEGER`
(0/1, nullable). `store()`/`list()` extended to round-trip the nested shape to/from the two flat
columns. `vouch` is a property of the *latest delivery* like every other enrichment column here
(`rsvp`, `interactionType`, `author`, `content`) — the upsert's `ON CONFLICT DO UPDATE`
unconditionally overwrites it, so a re-sent mention without a vouch clears a previously-verified
one. Consistent with existing precedent, not a new gap.

### Observability

Add `VouchVerified` to `WebmentionLogEvent`, logged/counted the same way
`VerifyCompleted` is today (sanitized host fields only).

### Testing (sidecar)

- `verify.test.ts`: `verifyVouch` — verified true/false cases, unreachable URL, non-HTML body,
  hostname-vs-exact-URL matching (subdomain/path variations under the target host all count).
- `inbox.test.ts`: additive migration creates the two columns on a pre-existing table; round-trip
  of `vouch` through `store()`/`list()`; absence of `vouch` on `store()` leaves both columns null.
- `index.test.ts`: queue consumer only calls `verifyVouch` when `verifySource` succeeded; a
  vouch-verification failure does not affect whether the mention itself is stored/removed;
  malformed `vouch` form field is dropped, not rejected (still enqueues without `vouch`).

Release via the existing `.changeset/` flow (`pnpm changeset` → later, a dedicated `pnpm
changeset version` release run) — see the version note above.

## App side (Anglesite)

### `WebmentionInboxD1Client.swift`

Extend the `SELECT` (`WebmentionInboxD1Client.swift:81`) and `Mention` struct with
`vouch_url`/`vouch_verified`, following the existing pattern for the mf2-enrichment columns
(nullable, tolerated on rows written by older `@dwk/webmention` versions that predate these
columns).

### `ReceivedInteraction.swift`

```swift
public struct Vouch: Codable, Sendable, Equatable {
    public let url: URL
    public let verified: Bool
}
public let vouch: Vouch?
```

Threaded through `init`; no change to the sanitisation/validation contract (`id` regex,
`gitPath`).

### `ReceivedInteractionSync.swift`

`makeInteraction(from:)` maps `mention.vouchURL`/`mention.vouchVerified` into
`ReceivedInteraction.vouch` (both present → `Vouch`; either absent → `nil`).

### `interactions.ts` (Zod schema)

```ts
vouch: z.object({ url: httpUrl, verified: z.boolean() }).optional(),
```

added to `interactionSchema`. `httpUrl` (the existing http(s)-only scheme guard) reused as-is.

### `Interactions.astro`

A small trust badge next to the author byline in comments (`.comments li`) and in the
"Mentioned by" list — text, not an icon, consistent with the component's current no-emoji
style:

- `vouch.verified === true` → `Vouched` badge (with a `title` gloss, since "Vouched" is
  IndieWeb jargon a visitor has never heard of).
- `vouch` absent, or `vouch.verified === false` → no badge. A failed vouch attempt is still
  stored (§ inbox schema above) for the owner to see in the raw data, just not rendered as a
  trust claim on the page — a spammer who omits the vouch parameter entirely renders exactly as
  clean as one whose vouch failed, so a visible "Unverified vouch" badge would only ever land
  on an honest sender whose vouch page moved or errored, which is the wrong party to flag.

Badge styling uses only CSS custom properties that already exist in
`src/styles/global.css` (`--color-primary`, `--color-surface`) — no new tokens, so it follows
the site's light/dark theme automatically.

Not added to the facepile (likes/reposts render as bare avatars with no room for accompanying
text; the `title` tooltip already carries author name and isn't extended for this).

### No moderation queue

The mention still flows through the exact same pipeline it does today — vouch state is a
rendered signal only, not a gate. This matches the issue's own proposal and the existing
`interactions.ts` doc comment ("moderation = delete the file"): an owner who sees an
`Unverified vouch` badge (or wants to distrust unvouched mentions generally) moderates by
deleting the snapshot file, same as any other unwanted interaction today.

### Testing (app side)

- `interactions.test.ts`: `parseInteractions` accepts/round-trips the optional `vouch` field;
  rejects a non-http(s) `vouch.url` (same `httpUrl` guard as `source`/`target`).
- Swift: extend `ReceivedInteractionSync` test coverage (wherever `makeInteraction(from:)` is
  currently exercised) with vouched / unverified-vouch / no-vouch D1 rows.
- Manual: build the template locally, confirm the badge renders correctly for all three states
  and that existing snapshots (no `vouch` key) still render unchanged.

## Sequencing

1. Sidecar PR in `davidwkeith/workers`: `verifyVouch`, `WebmentionJob.vouch`, queue-consumer
   wiring, `inbox.ts` columns, tests. **Done:**
   [davidwkeith/workers#505](https://github.com/davidwkeith/workers/pull/505), merged. A
   correctness follow-up is pending — see "Known issue" above — before step 2 starts.
2. Anglesite PR: bump `@dwk/webmention` to whatever version the sidecar's release run actually
   publishes in `Resources/Template/package.json`, then the five app-side changes above (D1
   client, Swift model, sync, Zod schema, Astro render) with their tests. `Closes #1597`.

## Non-goals

- No change to how `source`/`target` verification works — vouch is additive only.
- No moderation queue / hold state — out of scope, see "No moderation queue" above.
- No interaction with #963's audience-limited posting — that controls who can *see* restricted
  posts; Vouch is about trust-scoring *inbound* mentions on otherwise-public content (per the
  issue's own "Not in scope" note).
