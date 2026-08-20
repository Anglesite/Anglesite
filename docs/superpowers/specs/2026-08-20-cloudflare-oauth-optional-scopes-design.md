# Cloudflare OAuth — optional (task-based) scopes — design

**Date:** 2026-08-20
**Issue:** none yet — needs a tracking issue before implementation, per `CONTRIBUTING.md` ▸ "Discuss
big changes first."
**Status:** Sketch, not yet approved.
**Amends:** [`2026-08-03-macos-cloudflare-oauth-design.md`](2026-08-03-macos-cloudflare-oauth-design.md)'s
locked "OAuth scope" decision (§ Locked decisions, row 2), which shipped as #1204/#1211/#1296 (all
closed) — `signInWithCloudflare()` in `DeployModel.swift` and `CloudflareAPICredentials.resolve()`
are both live today, requesting `AnglesiteTokenTemplate.oauthScope` (all 18 permission groups) as
one fixed, non-negotiable scope string on every sign-in.

## Problem

Today's sign-in asks Cloudflare's consent screen to grant the app's *entire* possible permission
surface — deploy, DNS, WAF, Zaraz, Email Routing, Page Shield, Registrar edit — in one shot, even
for a user who only ever clicks Deploy. That mirrors the old pasted-token flow's one-template
design (reasonable when the alternative was hand-picking permission checkboxes in the dashboard),
but OAuth doesn't have that excuse: Cloudflare's self-managed OAuth supports **task-based consent**
— an OAuth client can mark some requested scopes as optional so the user can decline individual
ones on Cloudflare's own consent screen without denying the whole sign-in
(blog.cloudflare.com/task-based-oauth-consent/). This is worth adopting: it shrinks the blast radius
of a compromised or over-broadly-granted credential down to what a user actually opted into, and it
matches this codebase's existing degrade-gracefully posture (`AnglesiteTokenTemplate`'s header
comment, `CloudflareCapabilityProber`'s per-wizard capability gating) rather than fighting it.

I could not fetch the blog post from this environment (egress to `blog.cloudflare.com` is blocked
by the network proxy), so the exact wire mechanism below is my best understanding of Cloudflare's
documented feature, **not verified against the live authorize endpoint** — flagged explicitly in
Open items, same as the original design doc did for "does Cloudflare accept an 18-key scope list at
all."

## Locked decisions (proposed)

| Decision | Choice | Rationale |
|---|---|---|
| Required vs. optional split | `AnglesiteTokenTemplate.permissionGroups`' existing "Deploy" comment group (`workers_routes`, `workers_scripts`, `workers_kv_storage`, `workers_tail`, `workers_r2`, `d1`) becomes the **required** scope; everything else ("Harden + zone state", "Integration wizards") becomes **optional** | Deploy is why sign-in exists — an account that can't deploy gets nothing from connecting at all. Every other feature already assumes it might not have a capability and degrades (`CloudflareCapabilityProber`'s whole reason to exist) |
| Authorize request shape | Send required groups in the existing `scope` param; add the optional groups in a new param (`optional_scope`, space-joined, same convention as `scope`) | Matches Cloudflare's documented mechanism as best understood; **exact param name unverified** — see Open items |
| Granted-scope tracking | Decode the token response's `scope` field into a new `OAuthToken.grantedScope: String?`; when absent, treat as "everything requested was granted" | Standard OAuth2 behavior (RFC 6749 §5.1): a server only has to echo `scope` back when the grant differs from the request, so an absent field means no narrowing happened — this is also what makes an unsupportive Cloudflare deployment degrade to today's all-or-nothing behavior automatically, not break |
| Capability model | Map granted scope keys onto the existing `TokenCapability` enum (`TokenCapabilities.swift`) rather than a second OAuth-only capability type; extend `TokenCapability` with the couple of cases it's currently missing (`d1`, `workersR2`, `responseCompression`, `aiSearch`) so the mapping can be total | `CloudflareCapabilityProber` already solved "what can this credential actually do" for the legacy-paste path and one call site (`PlistEditorModel`'s inbox-capture gate) already consumes `TokenCapabilities`; OAuth should report into the same currency instead of wizards learning two capability vocabularies |
| Missing-optional-scope UX | Same shape as `PlistEditorModel`'s existing pattern (`capabilities.contains(.kv)` → inline message pointing at where to fix it), not a silent auto-reauthorize | That's the one real precedent in this codebase today (§ Precedent below) — a message + explicit user action beats a background browser popup the user didn't ask for |

## Precedent already in the codebase

`CloudflareCapabilityProber` + `TokenCapabilities` (both `AnglesiteCore`) already exist for exactly
this problem on the legacy-paste side: a pasted token might not carry every permission group, so
wizards probe live (`prober.probe(token:zoneID:)`, one cheap GET per group) and gate on the result.
Today the only wired consumer is `PlistEditorModel.swift:1217`'s inbox-capture toggle:

```swift
let capabilities = await capabilityProber.probe(token: token, zoneID: nil)
guard capabilities.contains(.kv) else {
    inboxCaptureError = String(localized: "Your Cloudflare token can't manage KV namespaces — recreate it from Settings → Tokens.")
    return
}
```

Optional scopes give OAuth a *cheaper* version of the same check: no live probe needed, since the
token response already says what was granted. The design below plugs into this existing model
rather than inventing a parallel one.

## Components

### 1. `AnglesiteTokenTemplate` (AnglesiteCore, extend)

- `permissionGroups` gains a `required: Bool` field (or splits into
  `requiredPermissionGroups`/`optionalPermissionGroups` — implementation detail, not locked here).
- `oauthScope` (existing) narrows to just the required groups.
- New `oauthOptionalScope: String` — the optional groups, same space-join convention.
- `createTokenURL` (the classic API-token dashboard deep link) is **unchanged** — a hand-created API
  token has no "optional" concept; the paste flow still pre-fills the full list.

### 2. `CloudflareOAuthClient` (AnglesiteCore, extend)

- `init` gains `optionalScope: String? = nil`.
- `makeAuthorizationRequest()` adds the `optional_scope` query item only when non-nil, so every
  existing call site (including iOS's narrower, non-optional scope from #890) is unaffected by
  omission.
- `refresh(refreshToken:tokenEndpoint:)` is unchanged — a refresh grant carries whatever was
  originally approved; it doesn't renegotiate scope.

### 3. `OAuthToken` (AnglesiteCore, extend)

- New `grantedScope: String?`, decoded from the token response's `scope` field (`CodingKeys.scope =
  "scope"`). Optional because RFC 6749 doesn't require the server to echo it back when nothing
  narrowed.

### 4. `CloudflareOAuthCredential` (AnglesiteCore, extend)

- New `grantedScope: String?`, persisted as a fifth non-secret slot alongside `expiresAt`/
  `tokenEndpoint` (same split rationale the original design doc used: non-secret metadata doesn't
  need a Keychain entry of its own, just a plain settings slot `PlatformSecretStore`/`KeychainStore`
  already has room for).
- `writeCloudflareOAuthCredential`/`readCloudflareOAuthCredential`/`clearCloudflareOAuthCredential`
  (`Platform/SecretStore.swift`) extend to carry the fifth field through, same shape as the existing
  four-slot read/write/clear trio.

### 5. New: scope → capability mapping (AnglesiteCore)

A pure function, e.g. `TokenCapabilities.granted(fromOAuthScope: String?) -> TokenCapabilities`,
splitting a space-joined granted-scope string into permission-group keys and mapping each to its
`TokenCapability` case via a small dictionary shared with (not duplicated from)
`AnglesiteTokenTemplate.permissionGroups`'s key list. A `nil` input (no `grantedScope` recorded —
either an old credential from before this feature, or a server that granted everything and didn't
echo `scope`) maps to **all** capabilities, matching the "absent = ungated" default above.

### 6. `CloudflareAPICredentials` (AnglesiteCore, extend)

`resolve()` currently returns just the bearer token string. Add a sibling
`resolveWithCapabilities()` (or widen the return type — implementation detail) that also surfaces
`TokenCapabilities` when the resolved credential is OAuth-sourced (read straight off the stored
`grantedScope`, no network call) — for the legacy pasted-token path, capabilities stay `nil`/unknown
here, since a pasted token still needs `CloudflareCapabilityProber`'s live probe (it never went
through an OAuth grant at all).

### 7. `DeployModel.signInWithCloudflare()` (AnglesiteApp, extend)

- `oauthSignIn`'s injected `CloudflareOAuthClient` gains `optionalScope:
  AnglesiteTokenTemplate.oauthOptionalScope`.
- On a successful exchange, `grantedScope` (from `OAuthToken`) is persisted into
  `CloudflareOAuthCredential` alongside the existing four fields.

### 8. Wizard call sites (AnglesiteApp/AnglesiteCore, extend as needed)

Each site that currently either (a) assumes the stored token can do everything (most of #1211's
eight migrated call sites) or (b) live-probes via `CloudflareCapabilityProber` (`PlistEditorModel`'s
inbox-capture gate) adds a capability check sourced from §6 first, falling back to a live probe only
for the legacy-token case. A missing optional capability surfaces the same way
`PlistEditorModel:1219` already does today — an inline message — but pointed at reconnecting via
OAuth rather than "recreate it from Settings → Tokens": something like *"Connect additional
Cloudflare access to use this — click Sign in with Cloudflare again."* Re-running
`signInWithCloudflare()`'s existing flow with the same required+optional scope request is sufficient;
Cloudflare's consent screen is expected (see Open items) to only re-prompt for what wasn't already
granted, not force the user through the full list again.

## Data flow

- **Sign-in:** unchanged happy path, plus: authorize URL now carries both `scope` (required) and
  `optional_scope` (optional) params → user can deselect individual optional items on Cloudflare's
  consent screen → token response's `scope` field reflects the actual grant → `OAuthToken
  .grantedScope` → persisted into `CloudflareOAuthCredential.grantedScope` → mapped to
  `TokenCapabilities` on demand (§5), no extra network round trip.
- **Feature gated on an ungranted optional scope:** inline message, no automatic browser popup (§
  Locked decisions, last row) → user re-triggers sign-in → (expected, unverified) Cloudflare only
  asks about the still-missing scopes → wider `grantedScope` persisted, replacing the narrower one.
- **Legacy pasted token, or an OAuth credential predating this feature:** unchanged — `grantedScope`
  absent maps to "everything," same behavior as today, no forced re-auth wave (mirrors the original
  design doc's Migration philosophy).

## Error handling & edge cases

- Cloudflare's authorize endpoint doesn't recognize `optional_scope` at all: two plausible failure
  modes — (a) it's ignored and the full `scope`-equivalent set is granted (harmless: `grantedScope`
  comes back full or absent, identical to pre-this-change behavior), or (b) it 400s the whole
  request (would break sign-in outright — must be caught by a live test against the real endpoint
  before shipping, not assumed safe).
- A user declines *every* optional scope: still succeeds — deploy is the one required group, and
  every other feature already degrades to an inline message rather than a hard failure.
- A stored `grantedScope` narrower than what a feature needs, but the feature has no capability
  check wired yet (i.e. one of the not-yet-migrated call sites): falls through to today's
  behavior — an API call that 401s/403s, surfaced however that call site already surfaces API
  errors. Not a regression, but also not improved by this change until that site adds a check; not
  every call site needs to migrate in the same PR (see Open items).
- Refresh (`grant_type=refresh_token`) is assumed to preserve the originally granted scope exactly
  — if Cloudflare's refresh endpoint ever narrows or widens it unprompted, `OAuthToken.grantedScope`
  from the refresh response should still be re-persisted (not discarded), so this stays correct
  automatically without special-casing refresh.

## Testing

- `CloudflareOAuthClientTests` — extend for `optional_scope` param presence when set / absence when
  `nil`, against the existing injected `Transport` seam.
- New capability-mapping tests (pure function, §5) — table-driven over
  `AnglesiteTokenTemplate.permissionGroups`' keys, plus the `nil`-input-means-everything case.
- `KeychainStore`/`SecretStore` tests — extend the existing four-slot OAuth credential round-trip
  tests for the fifth `grantedScope` field, including a credential written before this feature
  (field absent) reading back as "everything granted."
- `CloudflareAPICredentialsTests` — extend for the OAuth-sourced-capabilities path returning the
  mapped set without an added network call (assert on the fake transport's call count, not just the
  result).
- **Not covered by automated tests:** the live consent-screen behavior (does declining an optional
  scope actually produce a narrowed `scope` in the token response; does re-authorizing after a
  partial grant show only the delta) — needs a manual pass against a real Cloudflare OAuth flow
  during implementation, same category of gap the original design doc flagged for Associated
  Domains.

## Open items (verify during implementation; non-blocking for this sketch)

- **Exact wire mechanism.** Confirm the real parameter name/shape Cloudflare's self-managed OAuth
  uses for optional/task-based scopes (`optional_scope` is this doc's best guess) against Cloudflare's
  own OAuth docs or a live authorize call — this doc's author could not reach
  `blog.cloudflare.com` from this session to confirm. Also confirm whether optional scopes need to
  be pre-declared against the registered client (`e6705eb5f46254ecae0641b2e4da0ee2`) in the
  dashboard before a request can mark them optional, the way the original design doc's client-widen
  follow-up already required for the full scope list.
- **Re-consent behavior.** Whether re-running the authorize flow after an initial partial grant
  prompts the user only for the newly-added scopes, or forces a full re-consent screen every time —
  changes how pushy the "connect additional access" messaging in §8 should be.
- **Scope-key parity.** Whether `grantedScope`'s returned keys match `permissionGroups`' keys
  exactly (same open item the original doc flagged for whether the full list is even accepted) —
  needed for §5's mapping to be correct rather than silently under- or over-reporting capabilities.
- **Migration granularity.** Whether all eight #1211 call sites get capability checks in this same
  effort or a follow-up — likely a follow-up, to keep this PR reviewable; flag explicitly rather than
  silently leaving some ungated.

## Non-goals

- Changing the legacy pasted-token path (`CloudflareTokenPromptView`'s replacement, `Cloudflare
  CapabilityProber`) — it has no OAuth grant to read a scope from; it keeps live-probing.
- Per-zone or per-account scope narrowing — this is about *which permission groups*, not narrowing
  the `accountId`/`zoneId: all` breadth the original design's `createTokenURL` also grants; that's a
  separate, larger change or the dashboard's own account/zone picker on the consent screen.
- iOS — its OAuth scope (#890) is already minimal (one "User Details (Read)" group, authenticating
  to its own Sandbox Control Worker rather than Cloudflare's management API directly), so optional
  scopes have nothing to narrow there.

## Epic touchpoints

- Amends #1204 (macOS Cloudflare OAuth onboarding, closed) — same client, same scope source
  (`AnglesiteTokenTemplate`), narrower request.
- Builds on #1211 (`CloudflareAPICredentials`, shared OAuth resolution across 8+ call sites, closed)
  and #1296 (serialized refresh, closed) — both stay compatible; §6/§8 extend rather than replace
  what they built.
- Needs its own tracking issue before implementation, per `CONTRIBUTING.md`.
