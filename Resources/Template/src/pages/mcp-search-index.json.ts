import type { APIContext } from "astro";
import { getCollection } from "astro:content";
import { readAnglesiteConfig } from "../../scripts/anglesite-config.ts";
import {
  SEARCH_INDEX_COLLECTIONS,
  buildSearchIndex,
  type SearchableEntry,
} from "../lib/mcp-search-entries.ts";

/**
 * Build-time JSON search index for the MCP `search_posts` tool (#1576) — same shape/precedent as
 * `sitemap.xml.ts`, fetched at request time by `worker/mcp-server.ts` via the `ASSETS` binding
 * and filtered server-side. Returns a plain 404 when `experimental.mcp` is off, matching every
 * other inert-when-disabled artifact this feature adds.
 */
export async function GET(_context: APIContext) {
  const enabled = readAnglesiteConfig(process.cwd()).experimental?.mcp === true;
  if (!enabled) {
    return new Response(null, { status: 404 });
  }

  const entries: SearchableEntry[] = [];
  for (const collection of SEARCH_INDEX_COLLECTIONS) {
    const posts = await getCollection(collection, ({ data }) =>
      import.meta.env.PROD ? !(data as { draft?: boolean }).draft : true,
    );
    for (const post of posts) {
      entries.push({ collection, id: post.id, data: post.data as Record<string, unknown>, body: post.body });
    }
  }

  return new Response(JSON.stringify(buildSearchIndex(entries)), {
    headers: { "Content-Type": "application/json" },
  });
}
