# Site MCP server (read-only tools) + MCP server card — design

- **Date:** 2026-08-19
- **Issue:** [#1576](https://github.com/Anglesite/Anglesite/issues/1576) — Template: site MCP server (read-only tools) + MCP server card
- **Epic:** [#1326](https://github.com/Anglesite/Anglesite/issues/1326) — Agent Readiness score gaps (slice 1 of the ladder; owner decision 2026-08-18: prioritize real agent value, server first, manifests describe reality)
- **Related:** [`2026-07-14-well-known-support-design.md`](2026-07-14-well-known-support-design.md) (claim seam this reuses), [`2026-08-16-webmcp-tool-pack-design.md`](2026-08-16-webmcp-tool-pack-design.md) (sibling in-browser feature, precedent for the `experimental.*` opt-in gate and the `.md` mirror endpoints this reuses)

## Context

Cloudflare's Agent Readiness scanner (`isitagentready.com`) grades `mcpServerCard` — whether a
site publishes a discoverable MCP server description — under its Protocol Discovery category.
Anglesite sites don't run one today. This is the largest slice in the #1326 ladder and the first
to add real unauthenticated request-handling surface (as opposed to a static file), so per the
issue this document is the required first deliverable before any implementation.

The MCP Server Card itself (`/.well-known/mcp/server-card.json`) is a **draft** upstream proposal
(SEP-1649/SEP-2127, "MCP Server Cards — HTTP Server Discovery via `.well-known`"), not yet in the
core MCP specification. Anglesite is building against a moving target; the design below keeps the
footprint small and the schema isolated so a future spec revision is a localized change.

## Scope reality check

The issue frames this as "Template + worker + one-line app catalog flip." That undersells the
actual surface: a site with `experimental.mcp` on and **no** other social feature active (a plain
blog) needs `worker/worker.ts` to be deployed at all, and today `WorkerComposition
.generateWranglerToml`'s `composesWorker` check (`Sources/AnglesiteCore/WorkerComposition.swift`)
only looks at active social-feature workers (`WorkerActivation`-derived), inbox-capture, and
running A/B experiments (`DeployCoordinator.resolveRunningExperiments`, itself reading
`anglesite.json`'s **`experiments`** block — a different, unrelated A/B-testing concept from the
**`experimental.*`** flags block this feature adds to). `DomainConfig.swift` does not decode
`experimental` at all today.

This slice therefore touches, beyond `Resources/Template/`:

- `Sources/AnglesiteCore/DomainConfig.swift` — decode `experimental.mcp` (new `experimental` case).
- `Sources/AnglesiteCore/DeployCoordinator.swift` — a `resolveMcpEnabled(sourceDirectory:)` reader,
  mirroring `resolveRunningExperiments`.
- `Sources/AnglesiteCore/WorkerComposition.swift` — fold the new enabler into `composesWorker`,
  generate the `/mcp` `run_worker_first` entry.
- `Sources/AnglesiteCore/WorkerRouteClaims.swift` — a claim for `/mcp`.
- `Sources/AnglesiteApp/DeployModel.swift` and `Sources/AnglesiteCore/SiteOperations.swift` — thread
  the new resolved flag into both `generateWranglerToml` call sites.
- `Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift` — provision `SOCIAL_KV` when
  `experimental.mcp` is on, even absent any social feature (see "Rate limiting" below).
- `Sources/AnglesiteCore/PreDeployCheck.swift` — validation parity for the new config field,
  matching how other `experimental`/config fields are already checked.

None of this touches the MCP *sidecar* (`Anglesite/anglesite-skills`) or its message schema, so the
issue's "no paired PR needed" holds — the extra surface is entirely within this repo.

## Goals

- A real, spec-following MCP server at `/mcp` (Streamable HTTP transport) exposing three read-only
  tools backed entirely by build-time-derivable data.
- A generated MCP Server Card at `/.well-known/mcp/server-card.json`, delivered through the
  existing `.well-known` claim seam, present only when the feature is enabled.
- `experimental.mcp` opt-in flag, default off, matching the `webmcp` precedent — inert (no route
  registered, no card generated, no indexed content) when absent/false. One caveat, accepted
  during implementation rather than worked around: Astro always materializes a file for a matched
  endpoint route, so a disabled site still ships a 0-byte `dist/mcp-search-index.json` (the
  endpoint's 404 body) alongside the enabled build's real index. Build output is therefore
  *inert*, not literally byte-identical, when the flag is off.
- Abuse-resistant: a fail-closed rate limiter in front of the unauthenticated endpoint.

## Non-goals

- Any authenticated/mutating tool (owner actions land later, dependent on RFC 9728 OAuth Protected
  Resource Metadata — a follow-up issue in the epic ladder, not this slice).
- Full markdown-negotiation content conversion (`markdownNegotiation` check, tracked separately as
  #1247) — the static-page content tool here does plain-text extraction, not conformant Markdown.
- Any change to the MCP sidecar/app↔sidecar transport (unrelated surface, #1277-adjacent).
- Reusing or detecting Cloudflare's edge-injected MCP/WebMCP packs (same "no documented API exists"
  situation the WebMCP design already ran into).
- A settings UI toggle for `experimental.mcp` — config-file opt-in only, matching `webmcp`.

## Architecture

### 1. Config flag

`Resources/Template/scripts/anglesite-config.ts`'s `AnglesiteExperimentalConfig` gains:

```ts
export interface AnglesiteExperimentalConfig {
  webmcp?: boolean;
  mcp?: boolean;
}
```

Default/missing is `false` — identical contract to `webmcp`: absent or `false` means zero behavior
change (no route, no generated card, no new build artifact).

A new build step (mirroring `experiments-artifact.ts`'s pattern of baking `anglesite.json` state
into a Worker-importable JSON artifact) writes `worker/mcp-flag.json` — `{ "enabled": boolean }` —
read at build time from `readAnglesiteConfig(...).experimental?.mcp`. `worker.ts` imports this
artifact the same way it imports `experimentsArtifact`, so the flag is available synchronously at
Worker cold start with no request-time config parsing.

### 2. Worker activation (Swift)

`DomainConfig.swift` adds a minimal `Experimental` struct (`mcp: Bool?`) and an `experimental` field
+ `CodingKeys` case. `DeployCoordinator` adds `resolveMcpEnabled(sourceDirectory:) -> Bool`,
reading the same `Source/anglesite.json` the TypeScript side reads, mirroring
`resolveRunningExperiments`'s shape exactly (parse, default false on missing/malformed).

`WorkerComposition.generateWranglerToml` gains an `mcpEnabled: Bool` parameter, folded into
`composesWorker`:

```swift
let composesWorker = hasSocialFeatures || inboxCaptureEnabled || hasRunningExperiment || mcpEnabled
```

When `mcpEnabled`, the `/mcp` route is added to the generated `[assets].run_worker_first` list
(alongside the existing per-feature route generation) and `WorkerRouteClaims` carries a
corresponding claim entry (`exact`, `/mcp`, methods `GET, POST, HEAD`) — the same validated-claim
shape every other dynamic route already uses. Both deploy call sites
(`DeployModel.swift`, `SiteOperations.swift`) call `resolveMcpEnabled` alongside the existing
`resolveRunningExperiments` call and pass it through.

### 3. MCP endpoint

New dependencies: `agents`, `@modelcontextprotocol/server` (`2.0.0`), `zod` — Cloudflare's official
stateless handler (`createMcpHandler` from `agents/mcp/server`). Rationale: this follows the current
draft MCP protocol model (server identity/capabilities travel per-request, not through a Durable
Object–backed session), needs no new storage binding, and Cloudflare maintains the JSON-RPC/
Streamable-HTTP framing, Origin validation, and CORS handling rather than this repo hand-rolling and
re-verifying spec compliance itself.

New `ROUTES` entry:

```ts
{
  path: "/mcp",
  match: "exact",
  methods: ["GET", "POST", "HEAD"],
  handler: (request, env, ctx) => handleMcp(request, env, ctx),
}
```

`handleMcp` checks the baked-in `mcp-flag.json` `enabled` value first and returns the file's
`notFound()` helper (plain-text 404, no HTML) when off — an unclaimed route must never behave
differently from a route that was never registered. When on, it delegates to
`createMcpHandler(createSiteServer, { route: "/mcp" })(request, env, ctx)`, where
`createSiteServer` is a small factory (per `createMcpHandler`'s contract: pass the factory, not a
constructed server) registering the three tools below via `server.registerTool(...)`.

### 4. Tools

| Tool | Input | Behavior |
|---|---|---|
| `search_posts` | `{ query: string, limit?: number }` | Fetches the build-time search index (§5) via `env.ASSETS.fetch()`, does case-insensitive substring matching over title/excerpt/tags, returns up to `limit` (default 5) as formatted text. Empty matches → a plain "no results" text response, not a thrown error — matching the WebMCP design's existing error-shape convention. |
| `fetch_page_content` | `{ path: string }` | For a path matching a collection entry (`/blog/<slug>`, `/<collection>/<slug>`), proxies the already-shipped `.md` mirror (`[...slug].md.ts`) via `env.ASSETS.fetch()` — no new extraction code. For any other path, fetches the built HTML via `env.ASSETS.fetch()` and runs a new, deliberately simple `htmlToPlainText` helper (`src/lib/`, pure/`node:test`-testable): strips `<script>`/`<style>`/`<nav>`/`<header>`/`<footer>` content, decodes entities, collapses whitespace. Explicitly documented as "good enough for an agent to read," not a markdown-negotiation-conformant conversion (#1247's job). A 404 from `ASSETS.fetch()` → a plain "not found" text response, not a thrown error. |
| `list_feeds` | `{}` | Returns the static list of feed URLs the template unconditionally generates (`/rss.xml`, `/atom.xml`, `/feed.json`, plus the per-collection variants under `/blog/`, `/notes/`, etc.) — no fetch needed, this is a fixed list derived from `src/lib/collections.ts`'s `ENTRY_COLLECTIONS` at build time into the same `mcp-flag.json`-style artifact (extended to also carry `feedPaths: string[]`, or a small sibling artifact — implementation plan decides which). |

### 5. Search index

New build step, same shape/precedent as `sitemap.xml.ts`/`feeds.ts`, emits `dist/mcp-search-
index.json`: an array of `{ title, url, excerpt, collection, tags, date }` for every published
(non-draft-in-production) entry across `[...ENTRY_COLLECTIONS, "blog"]` — the same idiom
`licensing.ts`'s `LICENSABLE_COLLECTIONS` uses, because `ENTRY_COLLECTIONS` is
`HENTRY_COLLECTIONS` plus `events`/`reviews` and therefore *excludes* the template's default
`blog` collection. Indexing `ENTRY_COLLECTIONS` alone would make `search_posts` blind to the
content type a scaffolded site actually ships, while `list_feeds` still advertised `/blog/rss.xml`.
The list is exported once as `SEARCH_INDEX_COLLECTIONS` (`src/lib/mcp-search-entries.ts`) and
iterated by the endpoint, so the two can't drift. Pure logic lives in `src/lib/` (
`node:test`-testable, no `import.meta.glob`), matching this repo's established "pure logic in
`src/lib`, `import.meta.glob`/DOM stays in `.astro`-or-endpoint-file" convention. Only emitted when
`experimental.mcp` is on — same inertness contract as everything else in this feature.

### 6. Rate limiting

Reuses the existing KV-counter *shape* from `isConsentRateLimited`/`consentRateLimitKey`
(hash `CF-Connecting-IP`, count in `SOCIAL_KV` with a TTL window, fail closed — reject — when
`SOCIAL_KV` is unbound) but **not** its constants or key prefix: a new `mcpRateLimitKey`/
`isMcpRateLimited` pair with its own `mcp-tool-call:` key prefix and a window/threshold sized for
agent tool-call traffic rather than login attempts (the existing 5/hour is tuned for consent-form
submission, not for a client that might legitimately call 3 tools in one session). Exact numbers are
an implementation-plan detail, not a design commitment here.

The counter meters **`tools/call` traffic only**, matching its `mcp-tool-call:` prefix. `/mcp`
accepts `GET`/`HEAD` (the dispatcher mirrors `HEAD` into `GET`) and the
`initialize`/`tools/list` handshake, none of which fetch an asset; counting them would let an
unauthenticated caller turn one request into one KV write against a namespace shared with
IndieAuth, and at 60/hour that exceeds the free plan's 1,000 writes/day. A KV read or write that
throws (quota exhaustion being the likely cause) is caught and treated as rate-limited — the
dispatcher has no `try`/`catch` around route handlers, so an uncaught error would surface as a
Worker exception rather than a 429.

Because a plain blog with only `experimental.mcp` on may have **no** other social feature active,
`SOCIAL_KV` provisioning currently tied to social-feature activation must also trigger on
`experimental.mcp` (`SocialWorkerProvisionCommand`) — otherwise the limiter's fail-closed behavior
means every `/mcp` request is rejected on such a site, silently defeating the feature. This is a
concrete requirement, not an edge case to defer.

### 7. MCP Server Card

Delivered as a **generated static file**, not a dynamic route — its content (server name, version,
transport endpoint, capability flags) is fully determined at build time from `anglesite.json` +
`SITE_URL`, same "generated" delivery class `security.txt` already uses per the `.well-known` claim
seam design. Registered through `scripts/well-known.ts`'s claim/generation machinery (owner id
`"mcp"`, `delivery: "generated"`), with its own content marker so regeneration/ownership rules match
`security.txt`'s (refuse to overwrite an unmarked hand-authored file; delete only marker-owned
output when the flag turns off).

Path: `/.well-known/mcp/server-card.json`. Shape (SEP-1649/2127 draft):

```json
{
  "serverInfo": { "name": "<site display name>", "version": "1.0.0" },
  "transport": { "type": "streamable-http", "endpoint": "/mcp" },
  "capabilities": { "tools": true, "resources": false, "prompts": false }
}
```

Only generated when `experimental.mcp` is on — absent (not an empty/false placeholder) when off, so
the claim seam's prebuild `check` never sees a stale card for a disabled feature.

### 8. Auth seam (phase 2, not built now)

The card above carries no `auth`/`securitySchemes` field this slice — all three tools are public and
read-only, so there's nothing to gate. The follow-up issue (RFC 9728 OAuth Protected Resource
Metadata, referenced in the epic ladder) will add that field and the actual protected-resource
endpoint when owner-action tools land; this slice deliberately does not stub it out, per this
project's "no half-finished implementations" convention — an unused placeholder field would just be
dead surface until the real follow-up defines its shape.

### 9. `AgentReadinessReport.swift`

**Stays `anglesiteProvides: false`**, deviating from the issue's literal "flip to `true`"
instruction. Rationale: `webMcp` — the one other opt-in-by-default Agent Readiness feature this
template has — stayed `false` after shipping, because `anglesiteProvides: true` means "a failing
scan means a stale/misconfigured deploy, not a missing feature," and that's not true for a flag that
defaults off; most sites that fail this check simply haven't opted in, and "redeploy to pick this
up" would be actively misleading copy for them. This deviation is called out explicitly in the PR
description.

## Testing

- `node:test`: the search-index builder, `htmlToPlainText`, `mcpRateLimitKey`/window logic, the new
  `mcp-flag.json`/feed-list build artifact.
- Miniflare (`worker.test.ts` conventions): `/mcp` tool-listing, each tool's happy path + error path
  (empty search, 404 fetch), the flag-off 404 behavior, and the rate limiter's reject-when-unbound
  and reject-over-threshold cases.
- `well-known.test.ts`: the new generated-claim card — present when enabled, absent when disabled,
  marker-owned regeneration/removal semantics matching `security.txt`'s existing test shape.
- `swift test`: `DomainConfig` decode of `experimental.mcp`, `WorkerComposition.generateWranglerToml`
  folding `mcpEnabled` into `composesWorker` and the `/mcp` route-claim generation,
  `DeployCoordinator.resolveMcpEnabled`.
- Real build + Agent Readiness scan verification, matching how #1481/#1489 verified `linkHeaders` —
  deploy a test site with `experimental.mcp: true` and confirm `mcpServerCard` passes.

## Out of scope (deferred)

- Authenticated/mutating tools and the RFC 9728 protected-resource endpoint (follow-up issue).
- `markdownNegotiation` conformant content conversion (#1247).
- A Settings UI toggle for `experimental.mcp`.
- Verified Cloudflare edge-injection/pack collision detection (no API exists, same situation as the
  WebMCP design's "Dedupe strategy" — not revisited here either).
