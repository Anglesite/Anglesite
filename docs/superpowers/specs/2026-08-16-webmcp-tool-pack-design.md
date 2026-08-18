# WebMCP tool pack in the site template

Date: 2026-08-16
Issue: [#1279](https://github.com/Anglesite/Anglesite/issues/1279)
Epic: #1251 (agent-ready-sites)

## Context

[WebMCP](https://blog.cloudflare.com/webmcp/) is a browser standard, shipping experimentally in
Chrome 146, that exposes `document.modelContext` so a page can register MCP tools an agent invokes
client-side. Anglesite sites deploy behind Cloudflare, which offers a dashboard-toggle "edge pack"
version — but the template can do better than generic packs, since the template Worker already
exposes site-specific actions worth declaring as tools.

**Owner decision (2026-08-15, issue comment):** first slice ships **read-only tools only**, gated
behind a template config flag until the standard stabilizes. Must avoid double-registering
against Cloudflare's edge-injected packs when the dashboard toggle is also on. Subscribe/webmention
actions (mutating, needing consent framing) are deferred to a follow-up.

## Goals

- Ship two read-only WebMCP tools, backed entirely by static/client-side mechanisms already in
  the template (Pagefind's search index, a new static markdown mirror) — no worker involvement.
- Gate the feature behind an explicit opt-in flag in `anglesite.json`, defaulting off.
- Ship as progressive enhancement: completely inert (no script emitted, no behavior change) on
  sites that don't opt in, and a no-op on browsers without `document.modelContext`.

## Non-goals

- Subscribe/webmention/any mutating tool (follow-up issue, needs consent framing).
- Verified detection of Cloudflare's edge-injected WebMCP bridge — no such API is documented (see
  "Dedupe strategy" below). This ships a best-effort mitigation only.
- Any change to `worker/worker.ts` or the MCP sidecar transport (unrelated to this in-browser
  surface — see #1277 for that).

## Architecture

Three independent pieces:

1. **Config flag** — `experimental.webmcp` in `anglesite.json`, read at build time.
2. **Markdown mirror endpoints** — static `.md` siblings for blog posts and entry-collection pages.
3. **Client-side registration script** — feature-detects and registers two tools, only emitted
   when the flag is on.

No worker changes; this is 100% static output + client-side JS, consistent with the issue's
framing (app-only, no MCP-sidecar schema change, no paired PR).

### 1. Config flag

`Resources/Template/scripts/anglesite-config.ts` gains:

```ts
export interface AnglesiteExperimentalConfig {
  webmcp?: boolean;
}
```

...added as `experimental?: AnglesiteExperimentalConfig` on `AnglesiteConfig`. Default/missing
value is `false`/absent — a site owner opts in with:

```json
{ "experimental": { "webmcp": true } }
```

`BaseLayout.astro` calls `readAnglesiteConfig(process.cwd())` (the same access pattern
`readConfig()` already uses for `.site-config`) and, when `experimental.webmcp === true`, emits
the client script tag described in §3. When absent or `false`, nothing is emitted — the page is
byte-identical to a build before this feature existed, matching the precedent set by
`readAnglesiteConfig`'s own doc comment ("this slice ships inert").

### 2. Markdown mirror endpoints

Two new Astro endpoint files, following the existing non-HTML output pattern already used by
`blog/atom.xml.ts` / `blog/rss.xml.ts` (a `getStaticPaths` + `GET` handler returning a `Response`,
sitting alongside the equivalent `.astro` HTML page):

- `src/pages/blog/[...slug].md.ts` → `/blog/<slug>.md`, mirroring `blog/[...slug].astro`'s
  `getStaticPaths`.
- `src/pages/[collection]/[slug].md.ts` → `/<collection>/<slug>.md`, mirroring
  `[collection]/[...slug].astro`'s `getStaticPaths` (iterates `ENTRY_COLLECTIONS` from
  `src/lib/collections.ts`, applies the same production draft filter: `!entry.data.draft` in
  `import.meta.env.PROD`, else unfiltered for dev preview).

Response body:

```
---
title: <entry.data.title>
<other frontmatter fields the collection's schema actually declares — see content-schemas.ts;
 the implementation plan enumerates the exact per-collection field set rather than assuming a
 uniform shape across blog/notes/articles/photos/albums/bookmarks/replies/likes/announcements/
 events/reviews>
---
<entry.body>
```

`entry.body` is the raw markdown source the `glob()` content-layer loader stores (unrendered —
no `render(entry)` call needed, unlike the HTML page). `Content-Type: text/markdown; charset=utf-8`.
A draft post gets no `.md` file in production, matching its HTML counterpart's absence.

### 3. Client-side registration script

New `src/scripts/` directory (first template-authored browser entry point — the existing
`search.astro` script is Pagefind's own generated bundle, not template code) containing:

- **`src/lib/webmcp-tools.ts`** — pure, `node:test`-testable. Exports:
  - The two tool definitions' static metadata (`name`, `description`, `inputSchema`).
  - `buildMarkdownURL(path: string): string` — derives `/<path>.md` from a site-relative path.
  - `formatSearchResults(pagefindResults): ToolResult` — shapes Pagefind's raw result objects into
    the `{content: [{type: "text", text}]}` shape WebMCP's `execute` return value expects.
  - No `document`, `fetch`, or `pagefind` imports — data in, data out, matching the repo's
    "pure logic in `src/lib`, `import.meta.glob`/DOM stays in `.astro`" test convention.

- **`src/scripts/webmcp.ts`** — thin browser glue, not unit-tested:
  ```ts
  if (!("modelContext" in document)) return; // feature-detect, inert everywhere else

  const controller = new AbortController();

  async function registerSafely(def, execute) {
    try {
      await document.modelContext.registerTool({ ...def, execute }, { signal: controller.signal });
    } catch (err) {
      console.warn(`[webmcp] failed to register ${def.name}:`, err);
    }
  }

  registerSafely(SEARCH_TOOL_DEF, async ({ query, limit }) => {
    const { search } = await import("/pagefind/pagefind.js");
    const { results } = await search(query);
    const top = await Promise.all(results.slice(0, limit ?? 5).map((r) => r.data()));
    return formatSearchResults(top);
  });

  registerSafely(FETCH_TOOL_DEF, async ({ path }) => {
    const res = await fetch(buildMarkdownURL(path));
    if (!res.ok) return { content: [{ type: "text", text: `Not found: ${path}` }] };
    return { content: [{ type: "text", text: await res.text() }] };
  });
  ```
  (Illustrative — exact wiring, bundling mechanics, and how the script tag reaches the client
  from `BaseLayout.astro` are for the implementation plan to pin down.)

**Tools:**

| name | input | behavior |
|---|---|---|
| `anglesite_search_posts` | `{query: string, limit?: number}` | Dynamic-imports Pagefind's JS API module (already built by the existing `postbuild` step), runs the query, returns up to `limit` (default 5) results as formatted text. Empty results → a plain "no results" text response, not a thrown error. |
| `anglesite_fetch_post_markdown` | `{path: string}` | Fetches the `.md` sibling for a site-relative path (via `buildMarkdownURL`). A 404 → a plain "not found" text response, not a thrown error. |

Tool names are prefixed `anglesite_` to minimize accidental collision with any other pack that
might register tools on the same page (see "Dedupe strategy").

### Dedupe strategy

No documented API exists for a page to detect Cloudflare's edge-injected WebMCP bridge — their
blog post describes only "if the browser doesn't support `document.modelContext`, it does
nothing," with no global marker, DOM attribute, or naming convention disclosed. Their "Site MCP
Server" pack proxies to a site's own backend MCP server (discovered at boot); Anglesite sites
don't expose such a discovery endpoint today, so an actual collision is unlikely in practice —
but not verifiably impossible.

Mitigation, given no real detection mechanism exists:

- Distinct `anglesite_`-prefixed tool names, to avoid an accidental identical-name collision.
- Each `registerTool` call wrapped in try/catch (`registerSafely` above) — if the platform (or
  another pack) throws on a duplicate name, it's logged and skipped rather than breaking the page.

This is explicitly a best-effort mitigation, not a guarantee, and is documented as such rather
than claiming a verified solution.

## Testing

- `src/lib/webmcp-tools.test.ts` (`node:test`) — covers `buildMarkdownURL` and
  `formatSearchResults`.
- `scripts/anglesite-config.test.ts` — add a case for `experimental.webmcp` (parse, default
  false/absent).
- New `.md.ts` endpoints — covered the same way the existing `atom.xml.ts`/`rss.xml.ts` /
  `[...slug].astro` routes are today; the implementation plan confirms the exact harness (build
  fixture + assert on generated output, matching whatever pattern those already use).
- `swift test` still runs per `CONTRIBUTING.md` — touching `Resources/Template/` can affect Swift
  tests coupled to template markup.
- No worker tests, no paired PR — this doesn't touch `worker/worker.ts` or the MCP sidecar.

## Out of scope (deferred)

- Subscribe / webmention tools (mutating; need consent framing — follow-up issue).
- Verified Cloudflare edge-injection detection (no API exists; revisit if Cloudflare documents one
  or a real collision is reported).
- Any change to the app↔sidecar MCP transport (#1277) — unrelated surface.
