# Audience-limited posting — epic decision record (#963)

**Status:** owner-approved decision set, 2026-08-18. Pre-implementation.
**Issue:** [#963](https://github.com/Anglesite/Anglesite/issues/963).
Related: #966 (contacts, shipped), #965 (follow approval, shipped), #72
(git as source of truth), #369 (audience field), #365 (Microsub reader),
#587 (inbox capture, shipped).

This document records the architectural decisions for the epic. It is not an
implementation plan; each sub-issue gets its own design/plan as it is picked
up.

## 1. Context

Anglesite is a public-broadcast publisher; the secondary product goal —
replace Facebook and LinkedIn for known contacts — needs content addressed to
a bounded set of known people. The prerequisites shipped: #966 gives the app a
per-site private contact store (`ContactStore`, with the `knownMeURLs()`
hook), and #965 gives the owner an approval gate over who becomes a follower.
This epic adds the restricted-content tier itself.

Two decisions were already made by the owner on 2026-08-15 (recorded on the
issue):

- **Restricted content is Worker-canonical.** It lives in D1/KV/R2 behind the
  site's Worker, an explicit, accepted departure from #72 *for restricted
  posts only*. Public content stays git-canonical.
- **Standards posture:** there is no W3C Recommendation for private social
  content, so this ships as a **documented extension with honest framing**,
  outside the site's W3C-conformance claim.

The remaining six decisions were settled 2026-08-18 and are recorded below.

## 2. Decisions

### 2.1 Authoring: composer-only, straight to the Worker

A restricted post is created with a **visibility toggle in the post
composer** and publishes via the Micropub path directly into the D1 post
store. It is never written to `Source/`, so it is never in git and never in
the static build.

Consequences:

- The epic's "`visibility` field on post-family content types" sub-item is
  **re-scoped**: `visibility` is a field on the Micropub wire format and the
  D1 store, not frontmatter on content-type files in `Source/`.
- The build exclusion and `PreDeployCheck` assertion are a **backstop**, not
  the primary mechanism: they assert that nothing carrying restricted
  visibility ever appears in `Source/` or `dist/`. Defense in depth against
  a future regression, sync bug, or manual mistake.
- The "restricted-content storage spike" sub-item is **moot** — the
  Worker-canonical decision plus this authoring model answer it.

### 2.2 Audience: a single `contacts` tier

`visibility: public | contacts`. Every contact in the site's `ContactStore`
can read every restricted post. No groups, circles, or per-post audiences in
v1. The wire format keeps `visibility` extensible (a string enum, not a
boolean) so finer tiers can layer on later without breaking stored posts.

### 2.3 Allowlist: push me-URLs to the Worker store

The Worker's gate check is membership: the IndieAuth-authenticated `me` must
be in the site's contact set. That set lives in `Config/contacts.json` on the
owner's Mac, so the app **pushes the normalized me-URL set to the Worker
store (KV/D1) on contact add/remove**, with a **deploy-time reconcile** as
the consistency backstop. Revocation takes effect on the next push.

Privacy framing (to be documented honestly): only the URLs are pushed — no
display names, no `linkedActor`/`linkedFeed` data, nothing else from the
contact record. `me` URLs are public identities; what this stores on
Cloudflare is the *membership* of the contact list, minimally. Salted hashing
was considered and rejected: me-URLs are public and low-entropy, so a hash
set is trivially reversible by hashing candidate URLs — it would add
normalization and debugging pain for near-zero real privacy gain.

### 2.4 Read surface: gated web + `bto` federated delivery, both in v1

The Worker serves an authenticated read surface behind the site's existing
IndieAuth endpoints:

- **Gated permalinks** for restricted posts.
- A **private h-feed** of restricted posts, so contacts have a friends-only
  feed to subscribe to.
- A visitor signs in with their own site (IndieAuth); the Worker verifies the
  token and checks the authenticated `me` against the pushed allowlist.

**`bto` federated delivery ships in v1**, not as a follow-up: restricted
posts are delivered to the ActivityPub inboxes of contacts with a
`linkedActor`, using `bto` addressing. This requires upstream
`@dwk/activitypub` support in `davidwkeith/workers`, so the epic's release
train includes the paired-repo sequencing (upstream ships first in a tagged
release; the app consumes it), as #965 did.

Honest framing carried into all UX and docs: **`bto` delivery is best-effort,
honor-system distribution** — once a copy lands on a federated server we do
not control, its handling is that server's policy. The Worker-gated read is
the enforced, canonical copy. ActivityPub addressing is a delivery hint, not
access control, and the product never claims otherwise.

### 2.5 Reader side: authenticated outbound fetch is deferred

Making *our* Microsub reader authenticate to fetch a friend's gated site
(AutoAuth-style flows, still experimental in IndieWeb practice) is **deferred
to its own follow-up issue**. This does not leave the reader blind in v1:
because `bto` delivery ships (§2.4), a contact's restricted posts still reach
us inbound via the fediverse inbox when they federate.

### 2.6 `/inbox` submissions: email the owner, keep the git capture

Reconciling #587 with the email-as-DM decision: the Worker **additionally
forwards each anonymous `/inbox` submission to the owner's email address**
(Cloudflare Email Routing, already in the stack via `EmailSetupPlanner`),
while the existing `INBOX_KV` → git commit-back pipeline stays as the
structured record. A stranger's message reaches the owner's actual mailbox —
consistent with email being the DM protocol — without removing a shipped
pipeline.

## 3. Work slices

Replacing the epic's original unscoped sub-items:

1. **Upstream (`davidwkeith/workers` / `@dwk/activitypub`):** `bto`-addressed
   restricted delivery from the outbox. Ships first in a tagged release.
2. **App:** composer visibility toggle; restricted posts publish via Micropub
   into the D1 store with `visibility: contacts`.
3. **App:** allowlist push on contact change + deploy-time reconcile
   (builds on `ContactStore.knownMeURLs()`).
4. **Template/Worker:** IndieAuth read gate — gated permalinks, private
   h-feed, allowlist check.
5. **Template:** build exclusion + `PreDeployCheck` assertion that no
   restricted content reaches `dist/` (backstop, non-overridable like the
   rest of the gate).
6. **App/Worker:** `/inbox` → owner email forwarding (#587 follow-up).
7. **Docs:** the documented-extension standards framing (§2.4's honesty
   requirements included).
8. **Deferred follow-ups:** authenticated-fetch Microsub reader (§2.5);
   groups/circles (§2.2).

Slices 2–5 depend on slice 1 only where federation is involved (slice 2's
publish path triggers delivery); the read gate (4) and backstop (5) are
app/template-only and can land in parallel with the upstream work.

## 4. Explicitly out of scope

- 1:1 private messaging — **email is the IndieWeb DM protocol** (decided on
  the epic). The app publishes `u-email` in the h-card and delegates to the
  user's mail client.
- Groups/circles or per-post audiences (§2.2).
- Authenticated outbound reader fetch (§2.5).
- Any claim of W3C conformance for the restricted tier (2026-08-15
  decision).
