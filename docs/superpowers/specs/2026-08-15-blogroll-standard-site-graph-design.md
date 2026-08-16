# Blogroll via standard.site graph lexicons — design

## Problem / motivation

Issue #1483, filed as a candidate follow-up when epic #1230 (Standard.site/Atmosphere
publishing) closed: publish the owner's blogroll as `site.standard.graph` records and render a
blogroll page. The epic's own note was that this would be "cheap now that increment 1's record
plumbing exists" — and increment 1 (plus the rest of #1230's increments, all shipped) does
supply nearly everything needed: `AtprotoPutRecordClient`, deterministic rkeys
(`POSSEStableKey`), the post-deploy pass shape (`StandardSitePublishCommand`), and DID/site-ID
persistence in `.site-config`.

What's missing, confirmed by a full codebase search: there is no existing "blogroll" data model
anywhere. A prior, unrelated design doc
([`2026-07-13-menubar-ia-design.md`](2026-07-13-menubar-ia-design.md) §4.6) describes a planned
**local RSS feed directory** ("Page ▸ Collections ▸ Add/Remove RSS Feed... a typed content
object rendering as a directory page + OPML") and parenthetically calls it "(blogroll)" — but
it's unimplemented (a single disabled menu placeholder in `PageCommands.swift`) and is a
different mechanism (locally authored OPML/RSS subscriptions) from this issue's atproto graph
records. See the naming note below.

## Key finding: `recommend` and `subscription` are not interchangeable

Fetched directly from standard.site's docs:

- **`site.standard.graph.recommend`** — `{ document: at-uri, createdAt }`. Points at a
  *`site.standard.document`* record — i.e. it endorses one specific **post**, not a site. Closer
  to a "liked articles" or "recommended reading" feature than a blogroll.
- **`site.standard.graph.subscription`** — `{ publication: at-uri, createdAt? }`. Points at a
  *`site.standard.publication`* record — i.e. it follows a whole **site**. This is the
  traditional blogroll semantic: "here are the sites I follow."

Decision (confirmed with the owner): the blogroll is **subscription-only**. `graph.recommend`
(endorsing individual articles) is a different feature with a different shape and is out of
scope here.

## Design

### 1. New content type: `blogroll`

Joins `ContentTypeRegistry`'s personal types alongside `bookmark`, `note`, etc. — git-tracked
entries authored through the existing generic per-type SwiftUI editor (#346), stored as an Astro
Content Collection (`storage: .collection("blogroll")`), same as every other typed content
object.

Fields:

| Field | Type | Required | Notes |
|---|---|---|---|
| `url` | `.url` | yes | The recommended site's homepage. |
| `name` | `.string` | yes | Owner-authored display name (see §2 — rendering never fetches the target's own name). |
| `note` | `.markdown` | no | Optional short blurb, e.g. why the owner recommends it. |

No `microformat`/`schemaType` projection: there's no h-entry-shaped or schema.org vocabulary
that fits "a site I follow" the way `h-entry`/`u-bookmark-of` fits a single bookmarked URL, and
inventing one is unnecessary — `projections: nil` (or empty), matching how not every content type
needs both projections today.

### 2. Rendering: owner's own text, static, no PDS fetch

A new Astro page (`/blogroll/`, following whatever route convention the other typed-content
index pages use) statically renders the `blogroll` collection at build time: `name`, `url`,
`note` — nothing else. This deliberately does **not** fetch each target's own
`site.standard.publication` record (name/description/icon) to enrich the page. Two reasons:

- Consistency with this app's established "no network calls at build time" rule (the same reason
  increment 2's well-known/`<link>` emission is derived purely from `.site-config`, per the
  original design doc's §"Build-time verifiable links").
- Simplicity: the owner already typed a name when adding the entry; a second, possibly
  conflicting name from the network is unnecessary surface area for v1.

The page renders regardless of whether any entry successfully resolves to an atproto
subscription record (§3) — it's a normal content listing, independent of publish success, same
as how a post's page exists whether or not its `site.standard.document` publish succeeded.

### 3. New post-deploy pass: `StandardSiteGraphPublishCommand`

Modeled directly on `StandardSitePublishCommand` (`Sources/AnglesiteCore/StandardSitePublishCommand.swift`):
an actor, injectable credentials/transport/log-center/clock, per-site serialized via the same
in-flight-task pattern, best-effort and never throws into the deploy result, ledgers to
`Config/` (new `StandardSiteGraphPublishLog`, mirroring `StandardSitePublishLog`), logs under the
same `standardsite:` debug-pane source prefix (reusing the existing source naming rather than
inventing a new one, since it's the same feature family).

**Gating** — identical to `StandardSitePublishCommand`: no-op without a Bluesky POSSE credential,
without a real deployed `SITE_URL` (not the `https://example.com` scaffold default), or when
`settings.publishToAtmosphere == false`. No new Settings toggle — this rides the existing
"Publish posts to the Atmosphere" switch; a second toggle for what is, to the owner, the same
feature ("post my stuff to the Atmosphere") would be UI clutter for a distinction (documents vs.
graph records) that's an implementation detail, not an owner decision.

**Sequencing** — in `DeployCoordinator.runPostDeploySequencing`, immediately after
`publishStandardSite`, before `syndicate`. Same rationale family as the existing ordering
(records should exist before anything downstream might reference them), and it keeps the two
Standard.site passes adjacent.

**Per-entry resolution.** The lexicon's `subscription.publication` field needs the *target's*
publication at-URI, which this app doesn't know a priori — the owner only typed a URL. Resolution
mirrors the verification mechanism increment 2 already established for our own site, run in
reverse against someone else's:

1. GET `https://<entry.url host>/.well-known/site.standard.publication` over the existing
   `POSSEHTTPTransport` seam (it's already a plain `(URLRequest) async throws -> (Data,
   HTTPURLResponse)` closure with no atproto-specific behavior baked in — reused as-is, not
   atproto client code).
2. A 2xx response whose trimmed body matches `at://…/site.standard.publication/…` (same shape
   `Resources/Template/scripts/standard-site.ts`'s `isStandardSitePublicationURI` checks
   client-side) is a resolved target.
3. Anything else — 404, timeout, malformed body, non-standard.site site — is an **expected,
   non-error outcome**, not a failure: most blogroll targets won't run standard.site. Logged as a
   single `standardsite:` stdout line (e.g. `skipped <url> — no site.standard.publication
   found`), not `stderr`. The entry still renders on `/blogroll/` (§2); it just gets no
   atproto record this pass.
4. A resolved entry is `putRecord`'d to `site.standard.graph.subscription` with a deterministic
   rkey `anglesite-<POSSEStableKey.make(siteID + "\n" + entry.path)>` (same derivation shape as
   `StandardSitePublishCommand`'s document rkey, keyed on the *owner's* site + this entry's
   content-collection path — not on the target — so a rename of the target's own site doesn't
   orphan the record; re-resolution just updates the same rkey's `publication` value).
5. Resolution is attempted on every pass, not cached — "updates are free" applies here too:
   re-checking a handful of blogroll URLs per deploy is cheap, and it means a target who adopts
   standard.site later gets picked up automatically on the owner's next deploy with no manual
   retry.

**Unpublish.** Same diff-based approach as `StandardSitePublishCommand`: an entry present in the
ledger but no longer in the current `blogroll` collection has its `site.standard.graph.subscription`
record deleted via `AtprotoPutRecordClient.deleteRecord`.

### 4. Naming note (not solved here)

The unimplemented "Collections ▸ Add RSS Feed to Directory" feature from the menubar IA doc also
uses "blogroll" informally, for a different, feed-URL-based mechanism. This design claims the
`blogroll` content-type id for the atproto-subscription meaning, since it's the better semantic
fit and ships first. Whoever eventually builds the RSS/OPML feed directory should reconcile the
naming (e.g. call that one "feed directory" in UI copy, reserving "blogroll" for this) rather than
introduce a second, conflicting `blogroll` concept.

## Error handling

Same posture as every other post-deploy pass in this family: every per-entry failure (a resolve
attempt, a `putRecord`, a ledger write) is caught, logged, and skipped — never aborts the whole
pass or throws into the deploy result. The pass-level no-op gates (§3) are logged distinctly from
per-entry outcomes, matching `StandardSitePublishCommand`'s existing convention of a single
"skipped — reason" line for a whole-pass no-op versus per-item accounting for a pass that ran.

## Testing

- `BlogrollGraphRecordsTests` (new, mirrors `StandardSiteRecordsTests`): record `$type`/field
  shape, deterministic rkey derivation.
- `BlogrollGraphPublishTests` (new, mirrors `StandardSitePublishTests`): resolve/skip/publish/
  unpublish behavior against the injectable transport, no real network — a stubbed transport
  returns a canned `.well-known` body for "resolves" cases and a 404/timeout for "skip" cases.
- `ContentTypeRegistryTests`: the new `blogroll` type decodes/encodes and round-trips like the
  other personal types.
- Template-coupled test (per `CONTRIBUTING.md`'s "if you touch `Resources/Template/`, run `swift
  test` too") if the `/blogroll/` page or content collection schema needs a matching Zod schema
  addition.

## Alternatives considered

- **Support `graph.recommend` too, for individual articles.** Rejected for v1 (owner's call): a
  "recommend this specific post" feature is a different UI (needs picking a specific document,
  not just a site) and a different mental model from a blogroll; can be a separate future issue.
- **Settings-list input** instead of a new content type. Rejected: no list-editor widget exists
  anywhere in the app today, and building one is strictly more work than reusing the content-type
  registry's existing per-type editor, which was built for exactly this shape of owner-authored
  structured content.
- **Fetch the target's own publication record to enrich the rendered page.** Rejected for v1:
  adds a build-time (or pre-build) network dependency this app has deliberately avoided
  elsewhere, for marginal benefit over the owner's own typed name/note.

## Open questions

- Exact route/path for the blogroll page and whether it's auto-linked in site navigation, or left
  for the owner to link manually (like other optional content-type index pages) — resolved during
  implementation by matching whatever convention the codebase already uses for similar optional
  collection pages.
