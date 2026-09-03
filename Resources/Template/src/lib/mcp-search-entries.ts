/**
 * Pure shaping logic for the MCP `search_posts` tool's build-time index (#1576) — kept free of
 * `astro:content` so it's unit-testable with plain `node:test`, matching this repo's "pure logic
 * in src/lib, import.meta.glob/astro:content stays in the endpoint" convention. The Astro
 * endpoint (`src/pages/mcp-search-index.json.ts`) calls `getCollection` and hands the results in
 * as plain `SearchableEntry` objects.
 */

import { ENTRY_COLLECTIONS, type EntryCollection } from "./collections.ts";

/**
 * Every collection the `search_posts` index covers. `ENTRY_COLLECTIONS` by construction excludes
 * `blog` (it's `HENTRY_COLLECTIONS` plus `events`/`reviews`), so indexing it alone made the
 * template's flagship content type invisible to `search_posts` while `list_feeds` still advertised
 * `/blog/rss.xml`. Same `[...ENTRY_COLLECTIONS, "blog"]` idiom as `licensing.ts`'s
 * `LICENSABLE_COLLECTIONS`; the endpoint (`src/pages/mcp-search-index.json.ts`) iterates this
 * rather than re-deriving the list, so the two can't drift.
 */
export const SEARCH_INDEX_COLLECTIONS: readonly SearchIndexCollection[] = [...ENTRY_COLLECTIONS, "blog"];
export type SearchIndexCollection = EntryCollection | "blog";

export interface McpSearchEntry {
  title: string;
  url: string;
  excerpt: string;
  collection: string;
  tags: string[];
  date: string;
}

export interface SearchableEntry {
  collection: string;
  id: string;
  data: Record<string, unknown>;
  body?: string;
}

interface SearchFieldMapping {
  dateField: string;
  title(data: Record<string, unknown>): string | undefined;
}

/** Field mapping per routed collection — mirrors `markdown-mirror.ts`'s `MIRROR_FIELDS`, kept as
 *  its own copy since this module must stay free of that file's frontmatter-rendering concerns. */
const SEARCH_FIELDS: Record<string, SearchFieldMapping> = {
  blog: { dateField: "pubDate", title: (d) => asString(d.title) },
  notes: { dateField: "publishDate", title: () => undefined },
  articles: { dateField: "publishDate", title: (d) => asString(d.title) },
  photos: { dateField: "publishDate", title: () => undefined },
  albums: { dateField: "publishDate", title: (d) => asString(d.title) },
  bookmarks: { dateField: "publishDate", title: (d) => asString(d.title) },
  replies: { dateField: "publishDate", title: () => undefined },
  likes: { dateField: "publishDate", title: () => undefined },
  rsvps: { dateField: "publishDate", title: (d) => (typeof d.rsvp === "string" ? `RSVP: ${d.rsvp}` : undefined) },
  checkins: { dateField: "publishDate", title: (d) => (typeof d.location === "string" ? `Checked in at ${d.location}` : undefined) },
  announcements: { dateField: "publishDate", title: (d) => asString(d.title) },
  events: { dateField: "start", title: (d) => asString(d.name) },
  reviews: { dateField: "publishDate", title: (d) => asString(d.itemReviewed) },
};

function asString(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function excerptOf(body: string | undefined, max = 160): string {
  const text = (body ?? "").replace(/\s+/g, " ").trim();
  return text.length <= max ? text : text.slice(0, max).trimEnd() + "…";
}

function urlFor(collection: string, id: string): string {
  return `/${collection}/${id}`;
}

/** Builds one search-index entry, or `null` when the collection has no known field mapping or
 *  the entry has no usable date (both treated as "not indexable" rather than an error). */
export function buildSearchEntry(entry: SearchableEntry): McpSearchEntry | null {
  const mapping = SEARCH_FIELDS[entry.collection];
  if (!mapping) return null;

  const raw = entry.data[mapping.dateField];
  const date = raw instanceof Date ? raw : typeof raw === "string" ? new Date(raw) : undefined;
  if (!date || Number.isNaN(date.getTime())) return null;

  const rawTags = entry.data.tags;
  const tags = Array.isArray(rawTags) ? rawTags.filter((t): t is string => typeof t === "string") : [];
  const url = urlFor(entry.collection, entry.id);
  const excerptTitle = mapping.title(entry.data) ?? excerptOf(entry.body, 60);
  const title = excerptTitle.length > 0 ? excerptTitle : url;

  return {
    title,
    url,
    excerpt: excerptOf(entry.body),
    collection: entry.collection,
    tags,
    date: date.toISOString(),
  };
}

export function buildSearchIndex(entries: SearchableEntry[]): McpSearchEntry[] {
  return entries.map(buildSearchEntry).filter((e): e is McpSearchEntry => e !== null);
}

/** Case-insensitive substring match over title/excerpt/tags, newest first, capped at `limit`
 *  (default 5). An empty/whitespace-only query returns no results rather than the whole index. */
export function searchEntries(index: McpSearchEntry[], query: string, limit = 5): McpSearchEntry[] {
  const q = query.trim().toLowerCase();
  if (!q) return [];
  return index
    .filter(
      (e) =>
        e.title.toLowerCase().includes(q) ||
        e.excerpt.toLowerCase().includes(q) ||
        e.tags.some((t) => t.toLowerCase().includes(q)),
    )
    .sort((a, b) => b.date.localeCompare(a.date))
    .slice(0, limit);
}
