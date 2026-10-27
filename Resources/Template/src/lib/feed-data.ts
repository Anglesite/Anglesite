import { getCollection } from "astro:content";
import { createMarkdownProcessor, type MarkdownRenderer } from "@astrojs/markdown-remark";
import {
  FEED_COLLECTIONS,
  sortAndLimit,
  escapeXml,
  type FeedEntry,
  type FeedItem,
} from "./feeds.ts";
import { feedItemsFor } from "./feed-items.ts";

// Split into `feed-items.ts` (#2133) so an EmDash site's feeds, rendered in its Worker, can map
// their entries without bundling this module's markdown pipeline. Re-exported here unchanged.
export { feedItemsFor, feedAuthor, feedRsl } from "./feed-items.ts";

const PER_COLLECTION_LIMIT = 50;
const COMBINED_LIMIT = 50;

// Constructing a processor loads the remark/rehype plugin pipeline, so build it once and reuse
// the same promise for every entry across every collection in a build rather than per-entry.
let processorPromise: Promise<MarkdownRenderer> | undefined;
function getProcessor(): Promise<MarkdownRenderer> {
  if (!processorPromise) processorPromise = createMarkdownProcessor();
  return processorPromise;
}

/// Render an entry's markdown body to full HTML for the feed's `contentHtml`. Photos with no
/// body (caption-only) fall back to the caption text, HTML-escaped and wrapped as a paragraph
/// (the caption is plain text, but `contentHtml` is consumed as HTML everywhere it's rendered —
/// JSON Feed `content_html`, Atom `<content type="html">`, RSS description — so a caption
/// containing `&`/`<`/etc. must not be promoted into HTML unescaped), so an entry with *some*
/// text to syndicate never ends up with empty content.
async function renderContentHtml(entry: FeedEntry): Promise<string> {
  const body = entry.body?.trim();
  if (!body) {
    const caption = entry.data.caption;
    return caption ? `<p>${escapeXml(String(caption))}</p>` : "";
  }
  const renderer = await getProcessor();
  const { code } = await renderer.render(body);
  return code;
}

/// Map a collection's entries to feed items *without* sorting — callers that immediately re-sort
/// (the combined feed) skip the wasted per-collection sort. Drafts are always excluded (#798): a
/// feed is syndication data consumed by external readers, not a live dev preview, so unlike the
/// page routes above this filter is unconditional — dev or prod, a draft never appears in a feed.
async function mapCollection(collection: string, site: string): Promise<FeedItem[]> {
  const entries = await getCollection(collection as any, (entry: any) => !entry.data.draft);
  return feedItemsFor(
    collection,
    site,
    await Promise.all(
      entries.map(async (e: any) => {
        const entry: FeedEntry = { id: e.id, collection, data: e.data, body: e.body };
        return { entry, contentHtml: await renderContentHtml(entry) };
      }),
    ),
  );
}

export async function getCollectionItems(
  collection: string,
  site: string,
  limit = PER_COLLECTION_LIMIT,
): Promise<FeedItem[]> {
  return sortAndLimit(await mapCollection(collection, site), limit);
}

export async function getCombinedItems(site: string, limit = COMBINED_LIMIT): Promise<FeedItem[]> {
  const all: FeedItem[] = [];
  for (const collection of Object.keys(FEED_COLLECTIONS)) {
    all.push(...(await mapCollection(collection, site)));
  }
  return sortAndLimit(all, limit);
}
