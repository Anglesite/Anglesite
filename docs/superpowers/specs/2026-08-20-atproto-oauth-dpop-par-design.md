# atproto OAuth (DPoP/PAR) client — design

**Date:** 2026-08-20
**Issue:** [#1485](https://github.com/Anglesite/Anglesite/issues/1485), follow-up from epic #1230
(closed; owner approved filing its candidate follow-ups, 2026-08-15).
**Status:** current — hold lifted by the owner (2026-09-04, on #1485) and split into two
independently landable children, both shipped: [#1889](https://github.com/Anglesite/Anglesite/issues/1889)
(client-metadata document hosting — this spec's "Client-metadata hosting" and "Redirect mechanism"
rows) and [#1890](https://github.com/Anglesite/Anglesite/issues/1890) (this doc's components 3/4/6:
PAR, token exchange/refresh, and Keychain storage — the "DPoP/PAR client mechanics" slice —
implemented in `ATProtoOAuthClient.swift`). Components 1/2 (`ATProtoIdentityResolver`,
`ATProtoAuthServerMetadata`) remain unbuilt: #1890's client takes the PAR/authorize/token endpoints
as already-resolved parameters rather than discovering them itself, so identity resolution and
auth-server metadata discovery are still a separate, not-yet-filed follow-up. Onboarding UI and
app-password migration/coexistence remain out of scope, tracked on the parent #1485.

## Scope

Today, `POSSECredentialResolver` resolves a Bluesky identity + app password out-of-band (Keychain
or env var — there is no in-app onboarding UI for it at all), and `BlueskyPOSSEClient` exchanges
that pair for a session (`com.atproto.server.createSession`) whose bearer JWT authenticates every
subsequent XRPC call. This design replaces that credential mechanism with atproto's native OAuth
(DPoP-bound tokens via Pushed Authorization Requests), mirroring how the Cloudflare OAuth migration
(#1204, `docs/superpowers/specs/2026-08-03-macos-cloudflare-oauth-design.md`) replaced a pasted API
token with a browser sign-in.

**This spec is deliberately scoped to the OAuth/DPoP/PAR client mechanics only** — a new
`ATProtoOAuthClient` in `AnglesiteCore` that turns a handle/DID into a persisted, refreshable,
DPoP-bound session. It does **not** cover:

- The settings/onboarding UI that would collect the handle and drive this flow (analogous to
  `CloudflareOAuthSignInView`) — left for whoever picks this up, once routed.
- Migrating existing app-password users, or any coexistence/fallback behavior between the two
  credential types.
- Hosting the client-metadata document (see Open items) — left as a placeholder.
- Updating `BlueskyPOSSEClient`/`BlueskyThreadClient`/`BlueskyBackfeedSync` call sites to consume
  the new session type instead of the app-password Bearer JWT — a follow-up once this client
  exists and the UI/migration questions above are answered.

## Why atproto OAuth differs from the Cloudflare mirror

Cloudflare has one fixed OAuth issuer; `CloudflareOAuthClient` is authorize → PKCE → exchange
against a static, pre-registered client. atproto has neither:

- **No fixed authorization server.** Every user's handle or DID resolves to their own PDS
  (Personal Data Server), which advertises its own OAuth authorization server. Identity resolution
  is a real, independently-failing step *before* any OAuth request can be built.
- **PAR is mandatory**, not optional — the authorize request body is pushed to the authorization
  server first (DPoP-proofed), and the browser step only ever carries a `request_uri` reference.
  Nothing like this exists in `CloudflareOAuthClient` today.
- **DPoP is mandatory** on every token-bearing request (PAR, token exchange, refresh). This *is*
  already a mature primitive in this codebase (`DPoPKeyPair`, built for IndieAuth/Micropub), just
  not yet used outside that call path.
- **`client_id` is a URL**, not an opaque registered string — it must resolve to a public JSON
  client-metadata document that lists the app's `redirect_uris`, matching what atproto's spec calls
  a "native" OAuth client.

## Locked decisions

| Decision | Choice | Rationale |
|---|---|---|
| Abstraction level | New standalone `ATProtoOAuthClient`, no shared `OAuthEngine` across Cloudflare/IndieAuth/atproto | This codebase has already rejected a generalized token-onboarding abstraction once (`GitHubTokenOnboarding`, out of scope for #654); the three flows differ enough (PAR/DPoP required or not, identity resolution or not) that a shared engine would mostly be conditionals |
| DPoP implementation | Reuse `DPoPKeyPair`/`DPoPNonceChallenge` unchanged | Already RFC 9449-compliant and provider-agnostic despite currently only being used by IndieAuth/Micropub; no reason to fork it |
| PAR implementation | New, small, standalone type — not folded into `DPoPKeyPair` | PAR is a distinct spec concept (request pushing) from proof-of-possession; keeping it separate matches "one clear purpose per unit" |
| Redirect mechanism | `https://auth.anglesite.dwk.io/atproto-callback` (owner decision, 2026-09-04, on #1485; shipped in #1889), superseding the custom-URI-scheme choice below | The owner's infra decision routed redirect handling through the same host as the client-metadata document, mirroring Cloudflare's universal-link callback shape instead of a custom scheme |
| ~~Redirect mechanism (superseded)~~ | ~~Custom URI scheme (e.g. `io.dwk.anglesite:/oauth-callback`), not Associated Domains/universal link~~ | ~~Simpler, no domain-verification dependency, and the more typical shape for atproto native OAuth clients; deliberately diverges from Cloudflare's universal-link choice~~ |
| Client-metadata hosting | `https://auth.anglesite.dwk.io/atproto/client-metadata.json`, served statically by `Workers/anglesite-oauth-callback/` alongside its existing Cloudflare OAuth callback (owner decision, 2026-09-04, on #1485; shipped in #1889) | Reuses the Worker that already serves `/oauth-callback` and the Apple App Site Association document, rather than standing up a second host |
| Session storage scope | Per-site, mirroring `posse:<siteID>:bluesky-app-password` and `indieAuthDPoPKey`'s two-key shape | A site's Bluesky identity is already modeled as site-scoped credential state; no reason to diverge for OAuth |
| Refresh token rotation | New refresh token overwrites the stored one immediately on every use | atproto rotates refresh tokens per use (unlike Cloudflare); treating the old one as still valid after a refresh would break the next refresh |

## Components

### 1. `ATProtoIdentityResolver` (AnglesiteCore, new)

Handle or DID in → DID document out. Two paths depending on input:

- **Handle** (e.g. `alice.bsky.social`): resolve via DNS TXT record (`_atproto.<handle>`) or the
  `.well-known/atproto-did` HTTP fallback, per atproto's handle resolution spec, to get a DID.
- **DID** (already known): skip straight to DID document resolution — `plc.directory` for
  `did:plc:*`, or the `did:web:*` document's own host for `did:web:*`.

From the resolved DID document, extracts the PDS service endpoint (`#atproto_pds` service entry).
Throws a distinct `.identityResolutionFailed(String)` for any step failing — this is the most
likely real-world failure (typo'd handle) and needs its own message for whatever UI eventually
surfaces it.

### 2. `ATProtoAuthServerMetadata` (AnglesiteCore, new)

Given the PDS URL: fetch `/.well-known/oauth-protected-resource` to get the authorization server's
issuer URL, then fetch that issuer's `/.well-known/oauth-authorization-server` (RFC 8414) for the
`pushed_authorization_request_endpoint`, `authorization_endpoint`, and `token_endpoint`. Missing or
malformed metadata (a PDS that doesn't support atproto OAuth yet) throws `.oauthUnsupported` —
distinct from resolution failure, so a future caller can tell "bad handle" from "this account can't
use this sign-in method yet" apart.

### 3. `ATProtoPushedAuthorizationRequest` (AnglesiteCore, new)

POSTs to the PAR endpoint with a DPoP proof (`DPoPKeyPair.proof(htm:htu:accessToken:nonce:)`, no
access token at this stage), PKCE `code_challenge`, `state`, `redirect_uri`, `scope`, and the
placeholder `client_id`. Handles the DPoP nonce challenge the same way IndieAuth/Micropub already
do: first attempt with no nonce, a `use_dpop_nonce` 400 supplies one via `DPoPNonceChallenge.nonce(in:response:)`,
retry once with it, fail otherwise. Returns `request_uri` + `expires_in`.

### 4. `ATProtoOAuthClient` (AnglesiteCore, new)

Orchestrates the full flow:

```
resolve(identifier) -> DID document
  -> discover(pdsURL) -> auth server metadata
  -> pushAuthorizationRequest(...) -> request_uri
  -> authorizeURL(clientID:, requestURI:) -> caller presents via ASWebAuthenticationSession
  -> authorizationCode(from:matching:) -> validates state before parsing anything else
  -> exchange(code:for:) -> DPoP-bound token response
  -> ATProtoOAuthSession
```

The `authorize` URL carries only `client_id` and `request_uri` (per the PAR spec — no repeated
params), unlike Cloudflare's authorize URL which carries the full parameter set directly.
`exchange`/a later `refresh(refreshToken:tokenEndpoint:)` both DPoP-proof the token endpoint call
the same nonce-retry way as PAR.

### 5. `ATProtoOAuthSession` (AnglesiteCore, new)

Result/storage struct: `accessToken`, `refreshToken`, `expiresAt`, `authServerIssuer`, `pdsURL`,
`did`. `pdsURL` and `did` are what any future XRPC caller (`BlueskyPOSSEClient` etc.) would need to
actually make authenticated calls — the access token alone isn't enough since DPoP-bound tokens
must be presented with a matching proof on every request, not just as a bearer header.

### 6. `SecretStore` / `SecretAccounts` (AnglesiteCore, new keys)

New site-scoped account keys, mirroring the existing `indieAuthAccessToken`/`indieAuthDPoPKey`
two-key pattern rather than Cloudflare's un-scoped keys:

- `atprotoOAuthDPoPKey(siteID:)` — the keypair itself (base64 raw key bytes, same encoding as
  `indieAuthDPoPKey`).
- `atprotoOAuthAccessToken(siteID:)`, `atprotoOAuthRefreshToken(siteID:)` — secrets.
- Non-secret session fields (`expiresAt`, `authServerIssuer`, `pdsURL`, `did`) stored outside
  Keychain per-site, same split `SiteConfigStore` uses for Cloudflare's token endpoint.

## Data flow

- **Sign-in attempt** (triggered by a future UI, out of scope here): identifier in →
  `ATProtoIdentityResolver.resolve(_:)` → `ATProtoAuthServerMetadata.discover(pdsURL:)` →
  generate/load `DPoPKeyPair` for this site → `ATProtoPushedAuthorizationRequest.push(...)` →
  `request_uri` → build `authorize` URL → `ASWebAuthenticationSession` (custom-scheme redirect) →
  `authorizationCode(from:matching:)` validates `state` → `ATProtoOAuthClient.exchange(code:for:)` →
  `ATProtoOAuthSession` → persisted via the new `SecretAccounts` entries.
- **Refresh** (called by a future consumer before an XRPC request, when `expiresAt` has passed):
  `ATProtoOAuthClient.refresh(refreshToken:tokenEndpoint:)` with a fresh DPoP proof → new access
  *and* refresh tokens → both overwrite the stored pair immediately (rotation, see Locked
  decisions).
- **Refresh failure** (revoked/expired refresh token): surfaces as `.sessionExpired`; caller must
  re-run the full sign-in flow from identity resolution. No fallback to the app password — that
  coexistence behavior is explicitly out of scope for this spec.

## Error handling & edge cases

- `.identityResolutionFailed(String)` — bad handle, no DID document, no PDS service entry.
- `.oauthUnsupported` — PDS/auth server doesn't advertise PAR/token/authorize endpoints.
- DPoP nonce challenge on PAR or token exchange → single retry via `DPoPNonceChallenge`, matching
  existing IndieAuth/Micropub behavior exactly; no new retry logic needed.
- `state` mismatch on the redirect callback → hard fail before parsing anything else, same ordering
  `CloudflareOAuthClient.authorizationCode(from:matching:)` already uses.
- Refresh token rotation: the new refresh token must be persisted **before** the new access token is
  handed back to any caller — a crash or cancellation between "got new tokens" and "persisted them"
  must not leave the old (now-invalid, already-consumed) refresh token as the stored one. Mitigate
  by persisting the full new pair atomically in one Keychain write.
- A cancelled sign-in mid-flow must not persist a partial session (no access token without a
  refresh token, no DPoP key without a session, etc.) — verify happens before persist, same
  guarantee `TokenOnboarding` already provides for Cloudflare/GitHub.

## Testing

- `ATProtoIdentityResolverTests` — handle → DID happy path (both DNS-TXT and `.well-known` HTTP
  fallback), DID → DID document happy path (`did:plc:*` and `did:web:*`), and each failure mode
  (`.identityResolutionFailed`). Injected `Transport` seam, no live network — same style as
  `CloudflareOAuthClientTests`.
- `ATProtoAuthServerMetadataTests` — well-formed metadata happy path, missing/malformed metadata →
  `.oauthUnsupported`.
- `ATProtoPushedAuthorizationRequestTests` — request shape (DPoP proof header present and correctly
  formed, PKCE challenge, client_id placeholder), nonce-retry-once-then-fail.
- `ATProtoOAuthClientTests` — authorize URL shape (`client_id` + `request_uri` only), `state`
  mismatch aborts before parsing, token exchange DPoP proof asserted (`htm`/`htu`/`iat` claims,
  matching the existing IndieAuth DPoP proof tests' assertion style), refresh rotation (assert the
  *new* refresh token is what gets persisted, not the old one).
- `SecretStore`/`PlatformSecretStore` tests — extend for the new site-scoped key set, mirroring the
  existing IndieAuth pair tests.
- **Not covered by automated tests:** the live custom-URI-scheme redirect handoff against a real
  signed build (needs a manual verification pass once implementation starts), and whether any real
  PDS's PAR/token endpoints behave exactly as RFC 9449/atproto's OAuth profile describes (both
  Bluesky's own PDS and third-party PDSes should be checked — atproto is a federated protocol, and
  it can't be assumed every implementation is equally spec-compliant).

## Open items (for whoever routes this issue)

- ~~**Client-metadata document hosting.**~~ Resolved by the owner's 2026-09-04 decision on #1485
  and shipped in #1889: served from `https://auth.anglesite.dwk.io/atproto/client-metadata.json`
  by `Workers/anglesite-oauth-callback/`. `ATProtoOAuthConfiguration.clientMetadataURL` (Child B,
  #1890) should point at that URL rather than carry a placeholder.
- **Onboarding UI.** No `ATProtoOAuthSignInView` or equivalent is designed here — deliberately, per
  scoping decision above. Would follow the `TokenOnboarding` verify → persist → flash → proceed
  shape once built.
- **Migration/coexistence with app passwords.** Whether existing app-password credentials keep
  working after this ships (matching Cloudflare's "legacy pasted token still honored" precedent) or
  are forced to migrate is not decided here.
- **Call-site migration.** `BlueskyPOSSEClient`, `BlueskyThreadClient`, `BlueskyBackfeedSync` all
  currently authenticate via `createSession` + Bearer JWT from the app password; wiring them to
  consume `ATProtoOAuthSession` (DPoP-proofed requests instead of a plain Bearer header) is a
  separate follow-up.
- **Scope string.** atproto OAuth scopes (`atproto`, `transition:generic`, etc.) aren't finalized
  here — should be verified against whatever XRPC methods `BlueskyPOSSEClient`/`BlueskyThreadClient`
  actually call before implementation.

## Epic touchpoints

- **#1485** — this design.
- **#1230** — the epic this was filed as a follow-up from (closed).
- **#1204** / `docs/superpowers/specs/2026-08-03-macos-cloudflare-oauth-design.md` — the OAuth
  migration this design mirrors in shape, and diverges from in the ways detailed above.
- `Sources/AnglesiteCore/DPoPKeyPair.swift`, `SiteIndieAuthClient.swift`, `MicropubClient.swift` —
  the existing DPoP/PKCE primitives this design reuses.
- `Sources/AnglesiteCore/POSSECredentials.swift`, `POSSEClients.swift`,
  `BlueskyThreadClient.swift`, `BlueskyBackfeedSync.swift` — current app-password call sites that a
  future follow-up would migrate onto this client.
