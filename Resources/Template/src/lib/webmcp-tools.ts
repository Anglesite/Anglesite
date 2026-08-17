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
      limit: { type: "number", description: "Maximum number of results to return (default 5)." },
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
 * `[...slug].md.ts` routes) from its site-relative page path. */
export function buildMarkdownURL(path: string): string {
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
