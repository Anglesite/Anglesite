/**
 * Reads an EmDash site's published articles for the routes that list them besides the article
 * index (#2133): the feeds, the article sitemap and the tag pages. Each loader returns the
 * template's own shapes (through `article-listings.ts`) plus EmDash's merged cache hint, so a
 * route can set the same cache the article pages set (#2116) and be purged with them.
 *
 * Only published entries reach these routes: EmDash returns drafts only to a signed-in editor
 * previewing them, and feeds and sitemaps are never previewed.
 */

import { getEmDashCollection, getTaxonomyTermsWithCacheHint } from "emdash";
import { feedItemsFor } from "./feed-items.ts";
import { sortAndLimit, type FeedItem } from "./feeds.ts";
import type { SitemapEntry } from "./sitemap.ts";
import type { TaggedEntry } from "./tags.ts";
import { tagSlug } from "./tags.ts";
import type { EmDashArticleData } from "./emdash-articles.ts";
import {
  ARTICLE_FEED_LIMIT,
  SITEMAP_ARTICLE_LIMIT,
  articleFeedSource,
  articleSitemapEntry,
  articleTaggedEntry,
  mergeCacheHints,
  tagTermGroups,
  type ArticleFeedSource,
  type CacheHint,
  type TagTermGroup,
} from "./article-listings.ts";

/** How many articles each EmDash query asks for when a route walks the whole collection. */
const PAGE_SIZE = 500;

const NEWEST_FIRST = { published_at: "desc" } as const;

function present<T>(value: T | null): value is T {
  return value !== null;
}

/** The newest published articles as feed items, newest first. */
export async function articleFeedItems(site: string): Promise<{ items: FeedItem[]; cacheHint: CacheHint }> {
  const { entries, cacheHint } = await getEmDashCollection("articles", {
    orderBy: NEWEST_FIRST,
    limit: ARTICLE_FEED_LIMIT,
  });
  const sources: ArticleFeedSource[] = entries
    .map((e) => articleFeedSource(e.data as unknown as EmDashArticleData))
    .filter(present);
  return { items: sortAndLimit(feedItemsFor("articles", site, sources), ARTICLE_FEED_LIMIT), cacheHint };
}

/**
 * Walks the published articles newest first, page by page through EmDash's keyset cursor, up to
 * `limit` entries. Stops early on an empty page, so a cursor that never ends can't loop forever.
 */
async function eachArticle(
  limit: number,
  where?: Record<string, string>,
): Promise<{ articles: EmDashArticleData[]; cacheHint: CacheHint }> {
  const articles: EmDashArticleData[] = [];
  const hints: CacheHint[] = [];
  let cursor: string | undefined;
  while (articles.length < limit) {
    const page = await getEmDashCollection("articles", {
      orderBy: NEWEST_FIRST,
      limit: Math.min(PAGE_SIZE, limit - articles.length),
      ...(where ? { where } : {}),
      ...(cursor ? { cursor } : {}),
    });
    hints.push(page.cacheHint);
    articles.push(...page.entries.map((e) => e.data as unknown as EmDashArticleData));
    if (!page.nextCursor || page.entries.length === 0) break;
    cursor = page.nextCursor;
  }
  return { articles, cacheHint: mergeCacheHints(hints) };
}

/** Every published article's sitemap entry, newest first, up to the sitemaps.org limit. */
export async function articleSitemapEntries(): Promise<{ entries: SitemapEntry[]; cacheHint: CacheHint }> {
  const { articles, cacheHint } = await eachArticle(SITEMAP_ARTICLE_LIMIT);
  return { entries: articles.map(articleSitemapEntry).filter(present), cacheHint };
}

/** The `tag` terms that have published articles, grouped by the slug the site links them at. */
export async function tagGroups(): Promise<{ groups: TagTermGroup[]; cacheHint: CacheHint }> {
  const { data, cacheHint } = await getTaxonomyTermsWithCacheHint("tag");
  return { groups: tagTermGroups(data, tagSlug), cacheHint };
}

/**
 * One tag page's articles: every published article carrying any of the group's terms, newest
 * first, each listed once. Usually one term; several (spellings sharing a slug) are walked in
 * parallel. A tag page is a listing of links, so it has no page size; a tag with more articles
 * than the sitemap limit lists the newest that many.
 */
export async function taggedArticles(group: TagTermGroup): Promise<{ entries: TaggedEntry[]; cacheHint: CacheHint }> {
  const walks = await Promise.all(group.termSlugs.map((termSlug) => eachArticle(SITEMAP_ARTICLE_LIMIT, { tag: termSlug })));
  const seen = new Set<string>();
  const entries: TaggedEntry[] = [];
  for (const { articles } of walks) {
    for (const entry of articles.map(articleTaggedEntry).filter(present)) {
      if (seen.has(entry.id)) continue;
      seen.add(entry.id);
      entries.push(entry);
    }
  }
  const hints: CacheHint[] = walks.map((w) => w.cacheHint);
  entries.sort((a, b) => b.publishDate.valueOf() - a.publishDate.valueOf());
  return { entries, cacheHint: mergeCacheHints(hints) };
}
