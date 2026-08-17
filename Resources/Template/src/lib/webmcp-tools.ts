/**
 * Pure tool metadata and helpers for the site's WebMCP tool pack (issue #1279). No `document`,
 * `fetch`, or Pagefind imports here — the browser-only wiring lives in `src/scripts/webmcp.ts`,
 * kept separate so this module stays plain-data-in/plain-data-out and unit-testable with
 * `node:test`, matching this template's "pure logic in src/lib" convention.
 */

export interface WebmcpToolDefinition {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
}

export interface WebmcpToolResult {
  content: Array<{ type: "text"; text: string }>;
}

export const SEARCH_POSTS_TOOL: WebmcpToolDefinition = {
  name: "anglesite_search_posts",
  description: "Search this site's published posts and pages. Returns matching titles, URLs, and excerpts.",
  inputSchema: {
    type: "object",
    properties: {
      query: { type: "string", description: "The search query text." },
      limit: {
        type: "number",
        description: "Maximum number of results to return (default 5, clamped 1-20).",
        minimum: 1,
        maximum: 20,
      },
    },
    required: ["query"],
  },
};

export const FETCH_POST_MARKDOWN_TOOL: WebmcpToolDefinition = {
  name: "anglesite_fetch_post_markdown",
  description: "Fetch the raw Markdown source of a page on this site, given its site-relative path.",
  inputSchema: {
    type: "object",
    properties: {
      path: { type: "string", description: 'A site-relative path, e.g. "/blog/hello-world/".' },
    },
    required: ["path"],
  },
};

/** Derives a post's `.md` mirror URL (see `src/lib/markdown-mirror.ts` and the
 * `[...slug].md.ts` routes) from its site-relative page path.
 *
 * Throws for anything that isn't strictly site-relative — a protocol-relative path
 * (`"//evil.com/x"`) or an absolute URL (`"https://evil.com/x"`) would otherwise produce a
 * cross-origin fetch target for an agent-supplied `path` argument. `fetchPostMarkdown` below
 * is the only caller, and its try/catch turns this throw into the existing "Failed to fetch"
 * text response — no separate error path needed. */
export function buildMarkdownURL(path: string): string {
  if (!/^\/(?!\/)/.test(path)) {
    throw new Error(`buildMarkdownURL: "${path}" is not a site-relative path`);
  }
  const trimmed = path.endsWith("/") ? path.slice(0, -1) : path;
  return `${trimmed}.md`;
}

/** The subset of Pagefind's `PagefindSearchFragment` (the resolved shape of a search result's
 * `.data()`) this tool actually reads — kept narrow and dependency-free rather than importing
 * Pagefind's own types, since this module must stay usable outside a browser/Vite context. */
export interface PagefindResultData {
  url: string;
  excerpt?: string;
  meta?: { title?: string };
}

function stripHtml(html: string): string {
  return html.replace(/<[^>]+>/g, "");
}

export function formatSearchResults(results: PagefindResultData[]): WebmcpToolResult {
  if (results.length === 0) {
    return { content: [{ type: "text", text: "No results found." }] };
  }
  const text = results
    .map((r, i) => {
      const title = r.meta?.title || r.url;
      const excerpt = r.excerpt ? stripHtml(r.excerpt) : "";
      return `${i + 1}. ${title} — ${r.url}${excerpt ? `\n   ${excerpt}` : ""}`;
    })
    .join("\n");
  return { content: [{ type: "text", text }] };
}

/** The subset of Pagefind's low-level search module `anglesite_search_posts` actually calls —
 * kept narrow so `searchPosts` stays injectable/testable without a real Pagefind build. */
export interface PagefindModule {
  search(term: string): Promise<{ results: Array<{ data(): Promise<PagefindResultData> }> }>;
}

/**
 * The `anglesite_search_posts` tool's `execute` body, extracted out of `src/scripts/webmcp.ts`
 * so it's unit-testable with `node:test` (final-review fix, #1279): the tool's real logic — the
 * `limit` default/clamp, result-slicing, and the failure-to-text mapping — had no coverage
 * because the browser-glue file that originally held it imports a dynamic Pagefind module and
 * can't run under `node:test`. `loadPagefind` is dependency-injected so this module still has no
 * `document`/`fetch`/Pagefind import of its own at the top level.
 */
export async function searchPosts(
  args: { query: string; limit?: number } = { query: "" },
  loadPagefind: () => Promise<PagefindModule>,
): Promise<WebmcpToolResult> {
  try {
    const pagefind = await loadPagefind();
    const { results } = await pagefind.search(args.query);
    const limit = Math.min(Math.max(1, args.limit ?? 5), 20);
    const top = results.slice(0, limit);
    const data = await Promise.all(top.map((r) => r.data()));
    return formatSearchResults(data);
  } catch (err) {
    // Covers a rejected pagefind.js import, a pagefind.search()/data() failure, or any other
    // unexpected throw — the tool must degrade to plain text, never reject execute()'s promise.
    console.warn("[webmcp] search failed:", err);
    return { content: [{ type: "text", text: "Search failed." }] };
  }
}

/**
 * The `anglesite_fetch_post_markdown` tool's `execute` body, extracted for the same reason as
 * `searchPosts` above. `doFetch` is dependency-injected (the browser glue passes the global
 * `fetch`) so this module stays free of a top-level `fetch` reference.
 */
export async function fetchPostMarkdown(
  args: { path: string } = { path: "" },
  doFetch: (url: string) => Promise<Response>,
): Promise<WebmcpToolResult> {
  try {
    const res = await doFetch(buildMarkdownURL(args.path));
    if (!res.ok) {
      return { content: [{ type: "text", text: `Not found: ${args.path}` }] };
    }
    return { content: [{ type: "text", text: await res.text() }] };
  } catch (err) {
    // Covers fetch() rejecting outright (offline, DNS, CORS, etc.), buildMarkdownURL rejecting a
    // non-site-relative path, or any other unexpected throw.
    console.warn(`[webmcp] fetch failed for ${args.path}:`, err);
    return { content: [{ type: "text", text: `Failed to fetch: ${args.path}` }] };
  }
}
