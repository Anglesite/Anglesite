# Worker read gate: IndieAuth-gated permalinks + private h-feed — design (#1568)

**Status:** approved design, pre-implementation.
**Issue:** [#1568](https://github.com/Anglesite/Anglesite/issues/1568), slice 4
of epic #963. Related: decision record
`docs/superpowers/specs/2026-08-18-audience-limited-posting-decisions.md` §2.4,
`docs/superpowers/specs/2026-08-18-contacts-allowlist-push-design.md` (#1567,
slice 3 — defines the allowlist store this design reads from).

## 1. Context and goal

Restricted posts (`visibility: contacts`) live only in the Worker's
`MICROPUB_DB` D1 store — never in `Source/` or the static build (§2.1 of the
decision record). This issue makes them readable by the site owner's known
contacts: a gated permalink per post, and a private h-feed listing all of
them, both behind an IndieAuth identity check against the allowlist #1567
pushes to `SOCIAL_KV`.

**The open question this design resolves:** how does a *visitor* prove "I am
`https://alice.example/`" to this site? The decision record says "a visitor
signs in with their own site (IndieAuth)". The site's already-shipped
`/authorize` + `/token` endpoints (`worker.ts`'s `indieAuthHandler`) cannot do
this — `approveAuthorization` unconditionally mints `me: `${baseUrl}/``
gated on the *owner's* password (`worker.ts:904-914`); they are a
single-tenant authorization server for the site's own owner (used today by
Micropub/Microsub clients), not an identity provider for arbitrary visitors.
Authenticating a visitor as themselves requires this Worker to act as an
IndieAuth **relying party (client)** toward *the visitor's own site*:
discover their authorization endpoint, redirect them there, handle the
callback, verify the returned `me`. Nothing like this exists in the codebase
today. This design specifies it, scoped as tightly as the protocol allows.

## 2. Identity flow: scope-less "profile exchange", not an access token

IndieAuth supports two shapes of code redemption:

- **Access-token grant** (`scope` non-empty): redeemed at the `token_endpoint`,
  DPoP-bound (mandatory in `@dwk/indieauth`'s own implementation,
  `handler.ts:447-458`). This site never needs an access token for a
  visitor's site — it only needs to know *who they are*, once, to start a
  session.
- **Profile-only exchange** (no `scope` requested): redeemed at the
  `authorization_endpoint` itself, no DPoP, returns `{ me, profile? }`. This
  is exactly `@dwk/indieauth`'s own `handleProfileExchange`
  (`handler.ts:519-528`) — proof this flow is real and already supported
  reciprocally by any site (including this one) built on `@dwk/indieauth`.

This design always requests **no scope** and redeems at the
**authorization endpoint**. This avoids building a DPoP proof *generator*
(this codebase only ever verifies DPoP, never creates it) and avoids ever
holding a token for another site — the only thing carried forward is a
verified `me` string, immediately turned into our own session.

Consequence: discovery only needs to find `authorization_endpoint` (not
`token_endpoint`).

## 3. Discovery: reuse `safeFetch`, hand-roll rel-link parsing

`@dwk/webmention`'s `discoverEndpoint` (`discovery.ts`) is the exact template
— fetch a user-supplied URL through the SSRF-safe wrapper, check the `Link`
header, fall back to scanning `<link>`/`<a>` elements — but its `rel`
matching, `parseLinkHeader`, and `scanElements` helpers live in
`@dwk/webmention/src/html.ts`, which is not part of the package's public
`exports` map (only `./dist/index.js` is), and the package's own
`findWebmentionEndpoint` hardcodes the `webmention` rel. `@dwk/safe-fetch`'s
`safeFetch` **is** public and is reused directly — no SSRF logic is
reimplemented. The small (~60-line) rel-link/Link-header scanner is
duplicated locally in `reader-discovery.ts`, the same call this repo already
made for `post-type-discovery.ts`'s `slugify`/`randomSlug` (comment there:
*"reimplemented here (not imported) because the package doesn't export its
internal helpers"*). A follow-up to promote this scanner into `@dwk/safe-fetch`
or a new shared package (it is genuinely generic, not Webmention-specific) is
worth raising upstream separately — out of scope for this app-side issue.

Only `rel="authorization_endpoint"` is discovered (§2). RFC 8414
`/.well-known/oauth-authorization-server` metadata discovery (the modern
alternative to rel-links) is not implemented in v1 — rel-link discovery has
the widest existing IndieAuth ecosystem support and keeps this module small;
metadata-based discovery is a reasonable follow-up if a real contact's site
turns out to need it.

## 4. Stateless flow: no new D1 table

Both the in-flight "signing in" state and the finished session are carried as
HMAC-signed, `base64url(payload).base64url(signature)` tokens — the exact
pattern `worker.ts` already uses three times over (`ConsentGrant`,
`SolidOidcConsentGrant`, and their `createXToken`/`verifyXToken` pairs), keyed
off the same `TOKEN_SIGNING_KEY` via `deriveKey(secret, purpose)` (HKDF, one
independent subkey per purpose). `base64url`/`decodeBase64url`/`deriveKey`
are extracted from `worker.ts` into a new shared `token-signing.ts` (pure
refactor, §6 Task 2) so the reader-auth modules can reuse them without
duplicating security-sensitive crypto code.

**Sign-in state token** (`reader-session.ts`, purpose
`"reader-signin-state"`, 10-minute TTL) — round-trips through the visitor's
authorization server as the OAuth `state` parameter, so no server-side
pending-request storage is needed:

```ts
interface SigninState {
  readonly v: 1;
  readonly exp: number; // unix seconds
  readonly me: string; // canonicalized claimed identity (input, unverified)
  readonly redirectTo: string; // site-relative path to return to on success
  readonly authorizationEndpoint: string; // discovered once; callback reuses it, no re-fetch
  readonly verifier: string; // PKCE code_verifier
}
```

**Reader session cookie** (`reader-session.ts`, purpose `"reader-session"`,
30-day TTL, cookie name `__Host-anglesite_reader`):

```ts
interface ReaderSession {
  readonly v: 1;
  readonly exp: number;
  readonly me: string; // normalized identity (reader-identity.ts's scheme-less form)
}
```

`Set-Cookie: __Host-anglesite_reader=<token>; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=2592000`.
The `__Host-` prefix requires exactly this shape (`Secure`, `Path=/`, no
`Domain`) and is a meaningful hardening: the browser refuses to honor the
cookie from anywhere but this exact origin over HTTPS.

**Known v1 limitation** (documented, not fixed here): a cookie is a fine
credential for a browser but most feed readers cannot attach a custom cookie
to a subscribed URL. A contact's browser session works immediately; getting
their feed reader onto the private h-feed (§7) may need a follow-up (e.g. a
per-contact bearer token/URL) if that turns out to matter in practice.

## 5. Identity normalization: match `ContactStore.knownMeURLs()` exactly

Per `docs/superpowers/specs/2026-08-18-contacts-allowlist-push-design.md`,
`SOCIAL_KV` key `contacts:allowlist` holds a bare JSON array of
`Contact.swift`'s `normalizedIdentityKey(for:)` output: lowercased host, path
with any trailing slash trimmed, **scheme dropped entirely**:

```swift
func normalizedIdentityKey(for url: URL) -> String {
    let host = (url.host ?? "").lowercased()
    var path = url.path
    if path.hasSuffix("/") { path.removeLast() }
    return host + path
}
```

`reader-identity.ts` ports this verbatim to TypeScript:

```ts
export function normalizeReaderIdentity(me: string): string {
  const url = new URL(me);
  const host = (url.hostname ?? "").toLowerCase();
  let path = url.pathname;
  if (path.endsWith("/")) path = path.slice(0, -1);
  return host + path;
}
```

(`url.hostname` — not `url.host`, which would include a non-default port;
Swift's `URL.host` also excludes the port, so this keeps the two languages'
outputs identical for a port-bearing `me`, an edge case neither side special-
cases beyond matching each other.)

The token/callback's verified `me` is always run through
`canonicalizeProfileUrl` (from `@dwk/indieauth`, already imported elsewhere
in `worker.ts`) first — guaranteeing a well-formed absolute URL with a
non-empty path — before `normalizeReaderIdentity` reduces it to the
allowlist-comparable key.

## 6. The gate: 403 uniformly, scoped to plausible post URLs

The Worker's `fetch()` already falls through to `env.ASSETS.fetch(request)`
for anything not in `ROUTES` (`worker.ts:1944-1949` today). This is the first
feature to serve post content dynamically (no existing precedent — confirmed
by grep, `ROUTES` is exhaustively protocol endpoints). The gate hooks in
exactly there: when the asset fetch 404s, `gated-content.ts`'s
`handleGatedFallback` gets a chance to serve a restricted post instead of the
asset 404.

**No-existence-leak requirement** (from the issue): an unauthenticated or
unauthorized visitor must not be able to tell "this restricted post exists"
apart from "this URL is nothing at all". The gate resolves this by checking
the session **before** ever touching the post store: any GET/HEAD request
without a valid, allowlisted reader session gets an identical, static 403 —
regardless of whether a post lives at that URL. Only a verified, allowlisted
session proceeds to the D1 lookup, where a genuine miss still falls through
to the ordinary plain-text 404 (safe, because the requester is already inside
the trust boundary).

To avoid turning *every* unrelated 404 on the site into a 403 for anonymous
visitors (a real UX regression and its own faint signal — "this site has a
private area" on every stray typo), the fallback only engages for paths
**shaped like a post permalink**, matching exactly the two shapes
`generatePostUrl` produces (`worker.ts:1063-1067`):

```ts
const SLUG = /^[a-z0-9-]{1,80}$/;
const KNOWN_COLLECTIONS = new Set([
  "notes", "articles", "photos", "albums",
  "bookmarks", "likes", "replies", "events", "reviews",
]);

export function looksLikePostPermalink(pathname: string): boolean {
  const segments = pathname.split("/").filter((s) => s.length > 0);
  if (segments.length === 1) return SLUG.test(segments[0]!);
  if (segments.length === 2) {
    return KNOWN_COLLECTIONS.has(segments[0]!) && SLUG.test(segments[1]!);
  }
  return false;
}
```

Any other 404'd path (asset extensions, deeper paths, uppercase, etc.) is
untouched — `handleGatedFallback` returns `null` and the caller keeps the
plain 404 exactly as today.

```ts
export async function handleGatedFallback(
  request: Request,
  env: Pick<WorkerEnv, "SOCIAL_KV" | "MICROPUB_DB" | "TOKEN_SIGNING_KEY">,
  pathname: string,
): Promise<Response | null> {
  if (request.method !== "GET" && request.method !== "HEAD") return null;
  if (!looksLikePostPermalink(pathname)) return null;
  if (!env.MICROPUB_DB || !env.TOKEN_SIGNING_KEY) return null;

  const me = await requireReaderSession(request, env);
  if (me === null) return forbidden(request.method);

  const store = createMicropubStore({ MICROPUB_DB: env.MICROPUB_DB });
  const url = new URL(request.url);
  const record = await store.getPost(`${url.origin}${pathname}`);
  if (!record || record.deleted) return null;
  if ((record.properties.visibility?.[0] ?? "public") !== "contacts") return null;

  return renderGatedPermalink(record, url.origin, request.method);
}
```

`forbidden()` is a static 403 (mirrors `notFound()`, `worker.ts:1867-1872`),
plus one safe, non-leaking addition: a link to `/contacts/signin?redirect=<this
request's own path>` — echoing the requester's *own* input back to them
carries no information they don't already have, and gives a real person a way
to actually sign in instead of a dead end.

## 7. Private h-feed

`GET /contacts/feed` — same gate (`requireReaderSession`, 403 uniformly on
failure — a feed reader needs a stable non-interactive failure, so this route
never redirects, only 200s or 403s). On success, lists all live posts with
`visibility: contacts` via `MicropubStore.listPosts` with
`filters.visibilities: ["contacts"]`, `order: "desc"`, and a fixed page size
(50 — no pagination in v1; the decision record doesn't call for it and a
contacts-only feed is not expected to need it soon), rendered as an h-feed.

## 8. Rendering: minimal hand-rolled markup, not Astro parity

`Hentry.astro`/`CollectionIndex.astro`/`Hcard.astro` are full Astro
components (JSON-LD schema, cited-embed cards, licensing links, syndication
links, webmention interactions UI) that cannot run outside the Astro build —
there is no SSR adapter configured (confirmed: `env.ASSETS` serves a purely
static build). Reproducing all of that from raw mf2 JSON inside the Worker is
out of scope for this issue. `gated-content.ts` renders the **microformats2
markup only** — the same class names, so a contact's feed reader parses it
identically — reusing `worker.ts`'s existing `extractMf2ContentString` /
`extractMf2Photos` (exported, not duplicated) and `escapeHTML`:

- Permalink: `<article class="h-entry">` with `p-name` (from
  `properties.name`), `e-content` (from `extractMf2ContentString`), `u-photo`
  images (from `extractMf2Photos`), `u-url`/`dt-published`
  (`properties.published`), `p-category` tags — mirroring `Hentry.astro`'s
  structure (`layouts/Hentry.astro:83-118`) minus JSON-LD/embeds/licensing/
  syndication/interactions.
- Feed: `<div class="h-feed"><h1 class="p-name">...</h1><ul>...</ul></div>`
  wrapping one abbreviated `h-entry` per post — mirroring
  `CollectionIndex.astro:25-39`.

Both responses set `cache-control: private, no-store` (contact-specific
content must never be shared-cached) and the same restrictive
`content-security-policy`/`referrer-policy`/`x-content-type-options` headers
`consentPage()` already sets (`worker.ts:504-513`).

## 9. New routes

| Path | Methods | Purpose |
|---|---|---|
| `/contacts/signin` | GET | Render the sign-in form (no `me`), or start discovery + redirect (`me` present) |
| `/contacts/callback` | GET | OAuth redirect target: redeem code, verify identity, check allowlist, set session cookie |
| `/contacts/feed` | GET, HEAD | Private h-feed of all live `visibility: contacts` posts |

No new `WorkerEnv` bindings — `SOCIAL_KV`, `MICROPUB_DB`, `AUTH_DB` (unused
here), `TOKEN_SIGNING_KEY` all already exist. No `wrangler.toml`/
`WorkerComposition.swift` changes. No `vitest.config.ts` binding changes —
`MICROPUB_DB` and `SOCIAL_KV` are already in the Miniflare test bindings.

## 10. Explicitly out of scope (this issue)

- RFC 8414 metadata-based endpoint discovery (§3).
- Non-cookie (e.g. bearer-token) access for feed-reader clients (§4).
- Pagination on the private feed (§7).
- JSON-LD / embeds / licensing / syndication / webmention-interactions parity
  with the public Astro rendering (§8).
- The allowlist push itself (#1567) and the composer visibility toggle
  (#1566) — this issue only *reads* `contacts:allowlist` and `MICROPUB_DB`,
  both already specified by their own issues.

## 11. Files

New, under `Resources/Template/worker/`: `token-signing.ts` (extracted from
`worker.ts`), `reader-identity.ts`, `reader-discovery.ts`,
`reader-session.ts`, `reader-auth.ts`, `gated-content.ts`, plus a `.test.ts`
beside each. Modified: `worker.ts` (import the new modules, export
`extractMf2ContentString`/`extractMf2Photos`, three new `ROUTES` entries, the
asset-404 fallback hook), `worker.test.ts` (integration coverage for the new
routes and fallback).
