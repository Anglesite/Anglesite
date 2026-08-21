# Cloudflare OAuth — optional (task-based) scopes — design

**Date:** 2026-08-20
**Issue:** [#1608](https://github.com/Anglesite/Anglesite/issues/1608)
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
| Required vs. optional split | Required = `workers_routes`, `workers_scripts`, `workers_tail` only (the minimum to deploy and tail-log a Worker with no bindings). `workers_kv_storage`, `workers_r2`, `d1` move to **optional** alongside "Harden + zone state" and "Integration wizards" | A plain deploy with no KV/R2/D1 bindings doesn't need storage-edit at all — putting storage groups in "required" would make the app's own blast-radius goal (§Problem) untestable via its own worked example (`.kv`, §Precedent), since every OAuth user would have `.kv` unconditionally. Storage groups become the first real optional-scope example a wizard (inbox capture, #764) can gate on |
| Authorize request shape | Send required groups in the existing `scope` param; add the optional groups in a new param (`optional_scope`, space-joined, same convention as `scope`) | Matches Cloudflare's documented mechanism as best understood; **exact param name unverified** — see Open items |
| Granted-scope tracking | Decode the token response's `scope` field into a new `OAuthToken.grantedScope: String?`. Two distinct "absent" cases, not one: (a) a credential from *before* this feature shipped (no `optional_scope` was ever sent) — absence means "nothing narrowed," fail open to all capabilities; (b) a credential from a request that *did* send `optional_scope`, where the response nonetheless omitted `scope` — treat as "can't tell," not "granted everything," and fall back to `CloudflareCapabilityProber`'s live probe instead | Standard OAuth2 (RFC 6749 §5.1) only requires the server to echo `scope` when the grant differs from the request, so (a) is a safe, standard default. But collapsing (b) into the same default would make it silently fail open in exactly the case this feature exists to close — an omitted `scope` on a request that *asked* for optional scopes is ambiguous, not reassuring. See Component 6 for how the two cases are told apart at resolve time |
| Capability model | Map granted scope keys onto the existing `TokenCapability` enum (`TokenCapabilities.swift`) rather than a second OAuth-only capability type; extend `TokenCapability` with the cases it's missing (`workersTail`, `workersR2`, `d1`, `responseCompression`, `analytics`, `aiSearch` — six, not four; see Component 5) so the mapping covers all 18 `permissionGroups` keys, and add matching probes to `CloudflareCapabilityProber` in the same effort so the six new cases don't read as unconditionally denied for every legacy pasted-token user | `CloudflareCapabilityProber` already solved "what can this credential actually do" for the legacy-paste path and one call site (`PlistEditorModel`'s inbox-capture gate) already consumes `TokenCapabilities`; OAuth should report into the same currency instead of wizards learning two capability vocabularies. Adding cases the prober can't populate would silently regress that existing path (§Non-goals says it stays unchanged) — so the probes ship alongside the cases, not as a follow-up |
| Absence semantics stay call-site-defined, not type-enforced | `TokenCapabilities` remains a plain `Set<TokenCapability>` for both sources. Prober-sourced sets: absence means "not proven" (re-probe once more context, e.g. a zoneID, is available — unchanged from today). OAuth-sourced sets: absence means "declined" (deterministic, per the granted scope). No shared type distinguishes the two | Each call site already knows which resolver it called (§6's OAuth-capabilities path vs. `CloudflareCapabilityProber` directly), so it isn't blind to which semantics apply — but this is a real sharp edge for a future maintainer, flagged rather than fixed: a `probed`/`granted`-tagged wrapper type is the natural next step if a call site ever needs to combine both, deliberately left as an Open item rather than built speculatively into this sketch |
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
- `oauthScope` (existing) narrows to just the required groups (§Locked decisions row 1).
- New `oauthOptionalScope: String` — the optional groups, same space-join convention.
- `createTokenURL` (the classic API-token dashboard deep link) is **unchanged** — a hand-created API
  token has no "optional" concept; the paste flow still pre-fills the full list.
- `artifactsPermissionGroup`'s doc comment (#1266, `AnglesiteTokenTemplate.swift:51-55`) currently
  promises that appending it to `permissionGroups` "extends `oauthScope` and `createTokenURL`
  automatically." That stops being true once `oauthScope` is required-only — slice 3 needs to say
  which bucket it joins (optional, presumably: Artifacts isn't needed to deploy) and the comment
  needs rewording to match.
- `CloudflareAPICredentials.swift:60` constructs `CloudflareOAuthClient(scope:
  AnglesiteTokenTemplate.oauthScope)` purely to call `refresh(refreshToken:tokenEndpoint:)`, where
  `scope` is inert (refresh doesn't send it). That stays as-is — refresh doesn't renegotiate scope
  (Component 2) — but is worth a one-line comment there so nobody "helpfully" widens it to
  `oauthScope + oauthOptionalScope` and re-broadens every refreshed token.

### 2. `CloudflareOAuthClient` (AnglesiteCore, extend)

- `init` gains `optionalScope: String? = nil`.
- `makeAuthorizationRequest()` adds the `optional_scope` query item only when non-nil, so every
  existing call site (including iOS's narrower, non-optional scope from #890) is unaffected by
  omission.
- `refresh(refreshToken:tokenEndpoint:)` **itself** is unchanged — a refresh grant carries whatever
  was originally approved; it doesn't renegotiate scope. (The type that *persists* a refresh's
  result is not unchanged — see Component 4a.)

### 3. `OAuthToken` (AnglesiteCore, extend)

- New `grantedScope: String?`, decoded from the token response's `scope` field (`CodingKeys.scope =
  "scope"`). Optional because RFC 6749 doesn't require the server to echo it back when nothing
  narrowed.

### 4. `CloudflareOAuthCredential` (AnglesiteCore, extend)

- New `grantedScope: String?`, persisted as a **fifth Keychain slot** — a new
  `SecretAccounts.cloudflareOAuthGrantedScope` account, written/read/cleared alongside the existing
  four (`Platform/SecretStore.swift:84-87` for the account-key constants, `:290-322` for
  read/write/clear). All four existing slots are Keychain entries already (there is no non-secret
  settings split to piggyback on — the original design doc didn't create one, and inventing one here
  would mean `clearCloudflareOAuthCredential()` no longer clears it, leaking a stale grant across
  sign-out into the next account's credential).
- `readCloudflareOAuthCredential()`'s partial-credential guard keeps treating a missing
  `grantedScope` as a *valid* credential, not a partial one — so pre-feature credentials (written
  before this slot existed) still resolve, only without a recorded grant (§Locked decisions row 3's
  first "absent" case).
- `clearCloudflareOAuthCredential()`'s doc comment ("four slots together") and
  `writeCloudflareOAuthCredential`/`readCloudflareOAuthCredential` extend to carry the fifth field
  through, same shape as the existing four-slot round trip.

### 4a. `CloudflareOAuthTokenSource` / `CloudflareOAuthRefreshCoordinator` (AnglesiteCore, extend)

`CloudflareOAuthRefreshCoordinator.refresh` (`CloudflareOAuthTokenSource.swift:92-97`) is the type
that actually persists a refreshed credential, and today rebuilds `CloudflareOAuthCredential` from
exactly four fields:

```swift
let updated = CloudflareOAuthCredential(
    accessToken: refreshed.accessToken,
    refreshToken: refreshed.refreshToken ?? refreshToken,
    expiresAt: refreshed.expiresIn.map { now().addingTimeInterval(TimeInterval($0)) },
    tokenEndpoint: tokenEndpoint)
```

Add a fifth field to `CloudflareOAuthCredential` (Component 4) without touching this call site and
it drops silently: a narrow `grantedScope` persisted at sign-in becomes `nil` on the very first
refresh (~1 hour later, per `refreshLeeway`), and Component 5's mapping treats `nil` as "everything
granted" — so declining an optional scope would quietly stop meaning anything within about an hour.
This must change in the same effort as Component 4, not as a follow-up:

- Read the *current* stored credential's `grantedScope` before overwriting it (the coordinator
  already reads the stored credential's refresh token via its caller, `CloudflareOAuthTokenSource
  .resolve()` — a `grantedScope` param threads through the same way).
- Carry it forward when `refreshed.grantedScope` (the refresh response's own `scope`, if
  `OAuthToken.grantedScope` decodes one) is absent — the same `refreshed.refreshToken ?? refreshToken`
  fallback shape already used one line above for refresh-token rotation, applied to
  `refreshed.grantedScope ?? existingGrantedScope`.
- If the refresh response *does* echo a `scope`, that value wins and replaces the stored one — a
  refresh is exactly where Cloudflare would report a narrowed grant if one happened server-side.

### 5. New: scope → capability mapping (AnglesiteCore)

A pure function, e.g. `TokenCapabilities.granted(fromOAuthScope: String?) -> TokenCapabilities`,
splitting a space-joined granted-scope string into permission-group keys and mapping each to its
`TokenCapability` case via a small dictionary shared with (not duplicated from)
`AnglesiteTokenTemplate.permissionGroups`'s key list. For the mapping to be total over all 18
`permissionGroups` keys, `TokenCapability` needs **six** new cases, not the four this doc originally
named — `workersTail`, `workersR2`, `d1`, `responseCompression`, `analytics`, `aiSearch` (`analytics`
and `workers_tail` had no case at all; the original four-case list missed both):

| `permissionGroups` key | `TokenCapability` case |
|---|---|
| `workers_routes`, `workers_scripts` | `.workers` (existing) |
| `workers_kv_storage` | `.kv` (existing) |
| `workers_tail` | `.workersTail` (**new**) |
| `workers_r2` | `.workersR2` (**new**) |
| `d1` | `.d1` (**new**) |
| `zone_settings` | `.zoneSettings` (existing) |
| `dns` | `.dns` (existing) |
| `zone_waf` | `.rulesets` (existing) |
| `response_compression` | `.responseCompression` (**new**) — a distinct permission group from `zone_waf` per `AnglesiteTokenTemplate`'s own header comment, so it needs its own case rather than folding into `.rulesets` |
| `page_shield` | `.pageShield` (existing) |
| `analytics` | `.analytics` (**new**) |
| `challenge_widgets` | `.turnstile` (existing) |
| `email_routing_rules`, `email_routing_addresses` | `.emailRouting` (existing) |
| `zaraz` | `.zaraz` (existing) |
| `registrar` | `.registrar` (existing) |
| `ai_search` | `.aiSearch` (**new**) |

`CloudflareCapabilityProber.probe(token:zoneID:)` (`CloudflareCapabilityProber.swift:37-56`) gets a
matching probe added for each of the six new cases in this same effort — not deferred — so a legacy
pasted-token user gating on `.d1`/`.workersR2`/`.responseCompression`/`.aiSearch`/`.workersTail`/
`.analytics` sees "not proven yet," the prober's existing semantics, rather than every wizard reading
those cases as unconditionally denied (which is what adding the enum cases without matching probes
would silently produce today, since `CaseIterable` enum growth doesn't of its own accord get probed).

A `nil` scope-string input (§Locked decisions row 3's first "absent" case — no `optional_scope` was
ever sent for this credential) maps to **all** capabilities. A non-`nil` request that nonetheless
decoded no `grantedScope` (row 3's second case) is **not** handled by this function at all — the
caller (Component 6) routes to `CloudflareCapabilityProber` instead, since this function only ever
sees a scope string, never the ambiguous "we don't know" state.

### 6. `CloudflareAPICredentials` (AnglesiteCore, extend)

`resolve()` currently returns just the bearer token string. Add a sibling
`resolveWithCapabilities()` (or widen the return type — implementation detail) that also surfaces
`TokenCapabilities`:

- OAuth-sourced, `grantedScope` recorded (narrowed or full): map via Component 5, no network call.
- OAuth-sourced, credential predates this feature (`grantedScope` slot never written): Component 5's
  `nil` path, all capabilities, no network call.
- OAuth-sourced, credential's sign-in *did* send `optional_scope` but the token response omitted
  `scope` (an explicit flag or the raw requested-scope string persisted alongside the credential
  distinguishes this from the previous case — exact shape not locked here): falls back to
  `CloudflareCapabilityProber`'s live probe rather than assuming a full grant.
- Legacy pasted-token path: unchanged, still `CloudflareCapabilityProber`'s live probe — it never
  went through an OAuth grant at all.

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
- **An OAuth credential whose sign-in requested optional scopes but whose token response omitted
  `scope`:** not the same as the previous case — Component 6 routes this to a live
  `CloudflareCapabilityProber` probe instead of assuming a full grant (§Locked decisions row 3).
- **Refresh of a credential with a narrowed `grantedScope`:** Component 4a carries the stored grant
  forward unless the refresh response echoes its own `scope`, so a declined optional scope stays
  declined across the token's lifetime rather than reverting to "everything" on the next refresh.

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
- Refresh (`grant_type=refresh_token`) is expected to preserve the originally granted scope, but
  this can't be left implicit — see Component 4a, which the refresh coordinator must implement
  explicitly (carry-forward, not re-derive) or a narrowed grant silently reverts to "everything"
  within about one token lifetime.

## Testing

- `CloudflareOAuthClientTests` — extend for `optional_scope` param presence when set / absence when
  `nil`, against the existing injected `Transport` seam.
- `AnglesiteTokenTemplateTests.oauthScopeMatchesPermissionGroups`
  (`Tests/AnglesiteCoreTests/AnglesiteTokenTemplateTests.swift:37-42`) breaks immediately once
  `oauthScope` narrows to the required groups — it currently asserts `oauthScope`'s keys equal *all*
  of `permissionGroups`. Its replacement should assert the split is lossless instead: required ∪
  optional == every `permissionGroups` key, required ∩ optional == ∅ — so the split can't silently
  drop a group on the floor.
- New capability-mapping tests (pure function, §5) — table-driven over all 18
  `AnglesiteTokenTemplate.permissionGroups` keys against the table above, plus the
  `nil`-input-means-everything case.
- `CloudflareCapabilityProberTests` — extend for the six new probes (§5), same shape as the existing
  per-capability probe tests.
- `KeychainStore`/`SecretStore` tests — extend the existing four-slot OAuth credential round-trip
  tests for the fifth `grantedScope` field, including a credential written before this feature
  (field absent) reading back as "everything granted."
- A `CloudflareOAuthRefreshCoordinator` round-trip test (Component 4a) — a narrow `grantedScope`
  persisted before refresh must still be present after a refresh whose stubbed response omits
  `scope`; a second case where the stubbed response echoes a *different* `scope` must overwrite it.
- `CloudflareAPICredentialsTests` — extend for the OAuth-sourced-capabilities path returning the
  mapped set without an added network call (assert on the fake transport's call count, not just the
  result), and for the "optional scope requested but response omitted `scope`" case routing to the
  prober fallback.
- `DeployModelTests`' existing sign-in coverage (`Tests/AnglesiteAppTests/DeployModelTests.swift`,
  around lines 870 and 929) extends for the persisted `grantedScope` — note per `CONTRIBUTING.md`
  that CI never executes `AnglesiteAppTests`, so this specifically needs a local `swift test` on
  Xcode 27 before merge, not just a green CI run.
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

- Changing the legacy pasted-token path (`CloudflareTokenPromptView`'s replacement,
  `CloudflareCapabilityProber`) — it has no OAuth grant to read a scope from; it keeps live-probing.
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
  what they built. Component 4a specifically extends #1296's `CloudflareOAuthRefreshCoordinator`.
- Tracked at #1608.
