# Site MCP server phase 2: authenticated owner tools — design

- **Date:** 2026-08-30
- **Issue:** [#1578](https://github.com/Anglesite/Anglesite/issues/1578) — Template: MCP server phase 2 — authenticated owner tools (Micropub, media)
- **Epic:** [#1326](https://github.com/Anglesite/Anglesite/issues/1326) — Agent Readiness score gaps (slice 3 of the ladder)
- **Related:** [`2026-08-19-site-mcp-server-design.md`](2026-08-19-site-mcp-server-design.md) (phase 1: read-only tools, the server this slice extends), #1577 (RFC 9728 protected-resource metadata, already shipped and reused unchanged here)

## Context

Phase 1 (#1576) shipped a read-only `/mcp` endpoint built on Cloudflare's `agents` package
(`createMcpHandler` from `agents/mcp/server`, wrapping `@modelcontextprotocol/server`). Its design
doc explicitly deferred owner-action tools to a follow-up, "dependent on RFC 9728 OAuth Protected
Resource Metadata" (#1577, shipped since).

Since phase 1 shipped, the `@dwk/*` sidecar package family gained two new pieces built
specifically for this slice:

- **`@dwk/micropub`** now exports `createMicropubMcpTools(options): ToolDefinition[]` — an
  adapter over the existing `publishPost` HTTP create-action logic. Its doc comment is explicit:
  `publishPost` is "shared by the HTTP `create` action and `@dwk/mcp`'s `micropub_publish` tool
  (`mcp-tools.ts`)."
- **`@dwk/mcp`** is a new, dependency-free MCP protocol-core package (own JSON-RPC dispatch, own
  Streamable HTTP shell `createMcp`, a `ToolRegistry` that intersects a caller's granted scopes
  against each tool's `requiredScope`, and `createDpopBearerAuthenticator` — a DPoP-bound
  bearer-token auth bridge built from a caller-supplied token introspector + replay store).

`@dwk/micropub`'s own documentation names `@dwk/mcp` as the tool's intended host, i.e. the
ecosystem was built assuming owner-action tools run on `@dwk/mcp`'s engine, not Cloudflare's
`agents` package that phase 1 used for the public read-only tools.

**Decision (owner, 2026-08-30, this issue's implementation session): migrate `/mcp` fully to
`@dwk/mcp`.** This reverses phase 1's engine choice (see that doc's Architecture §3 for why
`agents` was picked) — accepted explicitly, because building auth-gated owner tools by hand-rolling
a second scope-check layer on top of the `agents` package's static `authContext` would diverge
from how the ecosystem's own libraries are documented to compose, and would leave the read-only and
owner tool sets on two different protocol implementations under variously one `/mcp` route. One
dispatcher, one `tools/list`, one auth bridge.

## Goals

- Replace `mcp-server.ts`'s Cloudflare-`agents`-based dispatch with `@dwk/mcp`'s `createMcp`.
- Port the three phase-1 read-only tools (`search_posts`, `fetch_page_content`, `list_feeds`) to
  `@dwk/mcp`'s plain-data `ToolDefinition` shape, `requiredScope: ""` (no auth required — matches
  today's public behavior exactly).
- Add `micropub_publish` via `@dwk/micropub`'s `createMicropubMcpTools`, gated on the `create`
  scope (matching the HTTP endpoint's own requirement for the same action).
- Add minimal media tools — `micropub_media_list` (list uploaded media) and `micropub_media_upload`
  (base64 upload) — gated on the `media` scope, built directly on `@dwk/micropub`'s exported
  `createMicropubMediaStore`/`MEDIA_EXTENSIONS` plus the `MEDIA` R2 binding. No MCP tool wrapper
  ships for these in `@dwk/micropub` yet, so this is hand-rolled, deliberately minimal.
- Wire `createDpopBearerAuthenticator` using `@dwk/indieauth`'s existing `verifyAccessToken` (token
  signature/`iss`/time-window check) + `IndieAuthStore.isTokenActive` (revocation) as the
  `TokenIntrospector`, and a new D1-backed `DpopReplayStore` (new migration, §"Replay store"
  below) — reusing `AUTH_DB`, the same physical D1 database `MICROPUB_DB`/`WEBMENTION_INBOX` already
  share (see `WorkerComposition.swift`'s binding comments).
- Preserve the existing abuse-resistant rate limiter (`isMcpRateLimited`/`mcpRateLimitKey`) and the
  `experimental.mcp` flag/404-when-off contract unchanged.

## Non-goals

- Update/delete Micropub actions as MCP tools (only `create` — matches the issue's explicit
  "publish" framing; a follow-up can add these once a `@dwk/micropub` MCP adapter exists for them).
- Media delete/undelete tools (the HTTP media endpoint's soft-delete/trash semantics) — deferred;
  `micropub_media_list`/`_upload` cover the "manage media" phrase's minimum useful slice without
  growing this PR into the whole media-endpoint surface.
- Any change to the MCP Server Card's `capabilities`/`transport` shape (still `/mcp`,
  streamable-http) — only its (currently absent) `auth` field gains a value, per phase 1's own
  "Auth seam" section.
- Any change to `@dwk/micropub`'s own HTTP `/micropub`/`/media` endpoints, or to RFC 9728 metadata
  (#1577) — both are reused unchanged.

## Architecture

### 1. Auth bridge

**Important correction found while implementing:** `createMcp`'s `authenticate` hook, when set at
all, runs unconditionally on *every* request and maps any thrown `McpAuthError` to a blanket `401`
before the body is even dispatched to `tools/list`/`tools/call` — and `createDpopBearerAuthenticator`
itself throws `McpAuthError` the moment no bearer token is present at all (`handler.js`/`auth.js`,
read directly since the `.d.ts` alone doesn't show this). Setting `authenticate` to the library's
authenticator as-is would 401 *every* unauthenticated call, including the three public read-only
tools — a regression from phase 1's public behavior. `ToolRegistry`'s own doc comment ("per-tool
least-privilege scope checks... never a perimeter check") implies a mixed public/private tool
server is an anticipated shape, but the bearer authenticator alone doesn't support it. Fix: wrap it
so a *missing* token resolves to zero granted scopes (public tools remain callable, `tools/list`
still enumerates everything) while a *present-but-invalid* token still throws through to a real
401 — only an actual auth attempt can fail:

```ts
function optionalAuthenticator(bearer: ReturnType<typeof createDpopBearerAuthenticator>) {
  return async (request: Request): Promise<McpAuthContext> =>
    tokenFromAuthHeader(request) ? bearer(request) : { scopes: [] };
}
```

`authenticate` is always set (this wrapper), never omitted — omitting it entirely would make
`request.headers` unavailable to `NO_SCOPES`'s fallback and is equivalent to "no owner tools ever
reachable," which is also wrong once Micropub is configured.

```ts
async function introspectMcpToken(token: string, env: WorkerEnv, baseUrl: string): Promise<IntrospectedToken | null> {
  const result = await verifyAccessToken(token, env.TOKEN_SIGNING_KEY, { issuer: baseUrl });
  if (!result.valid) return null;
  const store = createIndieAuthStore({ AUTH_DB: env.AUTH_DB });
  const now = Math.floor(Date.now() / 1000);
  if (!(await store.isTokenActive(result.claims.jti, now))) return null;
  return { active: true, scope: result.claims.scope, sub: result.claims.sub, cnf: result.claims.cnf };
}
```

This mirrors exactly what `@dwk/micropub`'s own `authorize()` does internally (signature + issuer +
time window, then revocation against the same `AUTH_DB`-backed store) — no new verification logic,
just the same two calls wired as a `TokenIntrospector`. DPoP proof-of-possession binding itself
(matching the request's `DPoP` header against the token's `cnf.jkt`) is handled inside
`createDpopBearerAuthenticator`, not here.

### 2. Replay store

A new migration, `worker/migrations/0003_mcp_dpop_replay.sql`, adds one table to the shared
per-site D1 database (bound as `AUTH_DB` here, same physical database `0001_indieauth.sql` and
`0002_experiments.sql` already migrate):

```sql
CREATE TABLE IF NOT EXISTS mcp_dpop_proofs (
  jti TEXT PRIMARY KEY,
  expires_at INTEGER NOT NULL
);
```

`recordProof(jti, expiresAt, now)` does an `INSERT OR IGNORE` and checks `changes()` to report
whether the row was new (matching the "atomically record, return whether unseen" contract). A
separate table from `@dwk/micropub`'s own DPoP-replay tracking in `MICROPUB_DB` (mentioned in its
`config.d.ts`) — `/mcp`'s proofs are bound to a different `htu` (`/mcp`, not `/micropub`/`/media`)
and are a distinct trust boundary from Micropub's own HTTP endpoint.

### 3. `/mcp` handler

`createHandleMcp` changes from constructing a Cloudflare `agents` handler to:

```ts
function createHandleMcp(config: McpConfigArtifact) {
  return async function handleMcp(request, env, ctx) {
    if (!config.enabled) return notFound();
    if ((await isMcpToolCallRequest(request)) && (await isMcpRateLimited(request, env))) {
      return new Response("Too Many Requests", { status: 429 });
    }
    const baseUrl = new URL(request.url).origin;
    const tools = buildToolDefinitions(env, config, baseUrl); // read-only + owner tools, see below
    const handler = createMcp({
      serverInfo: { name: "anglesite-site", version: "1.0.0" },
      tools,
      authenticate: ownerToolsConfigured(env)
        ? createDpopBearerAuthenticator({
            introspectToken: (token) => introspectMcpToken(token, env, baseUrl),
            replayStore: createD1DpopReplayStore(env.AUTH_DB),
          })
        : undefined,
      protectedResourceMetadataUrl: `${baseUrl}/.well-known/oauth-protected-resource`,
    });
    return handler(request);
  };
}
```

`ownerToolsConfigured(env)` mirrors `handleMicropub`'s own guard (`MICROPUB_DB`/`MEDIA`/`AUTH_DB`/
`TOKEN_SIGNING_KEY` all bound) — when false, `buildToolDefinitions` omits the owner tools entirely
(not just hides them behind a scope check that can never pass), so `tools/list` on a site with
`experimental.mcp` on but Micropub not provisioned advertises only the three read-only tools,
identical to today.

### 4. Read-only tools as `ToolDefinition`s

Each of the three existing tools becomes a plain `ToolDefinition` (`requiredScope: ""`) whose
`handler` body is the same logic phase 1 already wrote (`fetchSearchIndex`/`searchEntries`,
`fetchPageContent`, the static `feedPaths` list) — only the wrapping shape changes, from
`server.registerTool(name, {description, inputSchema: zodSchema}, asyncFn)` to
`{name, description, inputSchema: jsonSchema, requiredScope: "", handler: asyncFn}`. Input
validation moves from zod (which `@modelcontextprotocol/server` ran automatically) to a small
manual check at the top of each handler, since `@dwk/mcp` takes a raw JSON Schema for
documentation/`tools/list` purposes only and does not itself validate `args` against it (confirmed
by `ToolRegistry.call(name, args, auth)`'s signature — no schema library in `@dwk/mcp`'s dependency
list, `dependency-free` per its own module doc).

### 5. Owner tools

- **`micropub_publish`**: `createMicropubMcpTools({ config: resolveConfig({baseUrl, me: `${baseUrl}/`, generatePostUrl: ...}), store: createMicropubStore({MICROPUB_DB: env.MICROPUB_DB}) })` — reuses the exact same `generatePostUrl` policy `handleMicropub` already passes (collection-aware slug URLs, #912), so a post created via MCP lands at the same URL shape as one created via the HTTP endpoint.
- **`micropub_media_list`** (`requiredScope: "media"`): lists live media via `createMicropubMediaStore(env).list(page)`, returning `{key, contentType, sizeBytes, uploadedAt}` rows as JSON text content. `page` (`limit`/`offset`) parsed from tool args with the same defaults `parseMediaSourceParams` uses (limit 10, max 100).
- **`micropub_media_upload`** (`requiredScope: "media"`): input `{ contentBase64: string, contentType: string }`. Validates `contentType` against `MEDIA_EXTENSIONS`' keys (the same allowlist the HTTP media endpoint uses for inline-servable types), decodes the base64 payload, enforces `resolvedConfig.maxMediaBytes`, writes to `env.MEDIA` under a random UUID key (matching the HTTP endpoint's key-naming convention), records the row via `MicropubMediaStore.record`, and returns the resulting `${mediaEndpoint}/${key}` URL as `resource_link` content.

### 6. MCP Server Card — deferred

**Not implemented in this slice.** The card generator (`buildMcpServerCard`, actually in
`scripts/edge-artifacts.ts`, not `well-known.ts` as originally assumed above before reading the
real file) builds purely from `experimental.mcp` + `SITE_URL`. Whether owner tools are actually
present depends on Micropub being provisioned (`workers.active` in `anglesite.json`, a Swift-side
`WorkerActivation` concept with, today, zero TypeScript consumers of the equivalent
`anglesite.json` field) — wiring that check correctly is new plumbing this slice's core goal
(the tools themselves, tested and working) doesn't need, and guessing at the field's semantics
under time pressure risks a wrong/misleading card rather than an absent one. Follow-up: add
`workers.active.includes("micropub")` (or the correct equivalent, confirmed against
`WorkerComposition.swift`) as a build-time signal, then gain the card's `auth` field:

```json
"auth": { "type": "oauth2", "protectedResourceMetadata": "/.well-known/oauth-protected-resource" }
```

Leaving the card without an `auth` field is not incorrect today — SEP-1649/2127 is still a draft
and `auth` is optional — just less complete than it could be.

## Testing

- `node:test`: `introspectMcpToken` (valid/expired/revoked/wrong-issuer), the D1 `DpopReplayStore`
  (first-seen vs. replay), `micropub_media_upload`'s base64/size/content-type validation as pure
  functions where practical.
- Miniflare (`worker.test.ts` conventions, matching the existing MCP section): `tools/list`
  advertises only the 3 read-only tools when Micropub isn't configured, all 5 when it is; a missing
  token or a present-but-wrong-scope token both get the *same* `InsufficientScope` JSON-RPC error
  (HTTP 200) from `micropub_publish`/`micropub_media_*` — per `ToolRegistry`'s "scope check, never
  a perimeter check" design, only a genuine auth failure (invalid, expired, or replayed token)
  gets the RFC 9728 `WWW-Authenticate` `401` challenge; a valid DPoP-bound `create`-scoped token
  successfully publishes a post at the same URL the HTTP endpoint would generate; a replayed DPoP
  proof is rejected (401) on the second call.
- Existing phase-1 tests (rate limiting, 404-when-disabled, the three read-only tools' happy/error
  paths) must keep passing unchanged — they assert on `handleMcp`'s external behavior, not its
  internal engine, so no test-body changes are expected beyond re-pointing imports if any moved.

## Deferred (follow-up issues)

- Micropub update/delete as MCP tools.
- Media delete/undelete as MCP tools.
- Any tool for Microsub (Microsub scopes exist in `INDIEAUTH_SCOPES_SUPPORTED` but no
  `@dwk/microsub` MCP adapter exists yet).
