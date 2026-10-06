/**
 * EmDash articles in the shapes the template's own listings read (#2133): the feeds
 * (`FeedEntry`, `feeds.ts`), the sitemap (`SitemapEntry`, `sitemap.ts`) and the tag pages
 * (`TaggedEntry`, `tags.ts`). An EmDash site keeps its articles in EmDash rather than in git
 * collections, so its feeds, sitemap and tag pages render on request from these instead of the
 * template's `astro:content` loaders, and come out in the same shapes as an Anglesite site's.
 *
 * The types are restated structurally rather than imported: the template's `npm test` runs this
 * module from the overlay's own folder, where the template's `src/lib` isn't next to it.
 * Dependency-free on purpose, like `emdash-articles.ts`.
 */

import { articleView, type EmDashArticleData } from "./emdash-articles.ts";
import { portableTextPlainText, portableTextToHtml } from "./portable-text-html.ts";

/** How many articles a feed carries: the template's `PER_COLLECTION_LIMIT`/`COMBINED_LIMIT`. */
export const ARTICLE_FEED_LIMIT = 50;

/**
 * The most article URLs one sitemap may list (sitemaps.org's limit). A site with more lists its
 * newest that many; crawlers still reach the rest through the article index's pages.
 */
export const SITEMAP_ARTICLE_LIMIT = 50_000;

/** The template's `FeedEntry` for one article, plus its body rendered for the feed. */
export interface ArticleFeedSource {
  entry: { id: string; collection: "articles"; data: Record<string, unknown>; body?: string };
  contentHtml: string;
}

/**
 * One article as a feed entry, or `null` for one a feed can't carry: no slug (no public URL) or
 * no publish date (a feed item is dated; the template's `toFeedItem` refuses an undated one).
 * `data` carries the fields `toFeedItem` reads for `articles` (`title`, `summary`, `publishDate`,
 * `tags`); `body` is the plain text it excerpts when there is no summary.
 */
export function articleFeedSource(data: EmDashArticleData): ArticleFeedSource | null {
  const view = articleView(data);
  if (!view || !view.publishDate) return null;
  return {
    entry: {
      id: view.slug,
      collection: "articles",
      data: {
        title: view.title,
        summary: view.summary,
        publishDate: view.publishDate,
        ...(view.tags.length > 0 ? { tags: view.tags } : {}),
      },
      body: portableTextPlainText(data.content),
    },
    contentHtml: portableTextToHtml(data.content),
  };
}

/** One article as the template's `SitemapEntry`; its `lastmod` is its last update. */
export function articleSitemapEntry(
  data: EmDashArticleData,
): { collection: "articles"; id: string; data: Record<string, unknown> } | null {
  const view = articleView(data);
  if (!view) return null;
  return {
    collection: "articles",
    id: view.slug,
    data: { updatedDate: view.updated, publishDate: view.publishDate },
  };
}

/** One article as the template's `TaggedEntry`, or `null` without tags or a publish date. */
export function articleTaggedEntry(data: EmDashArticleData): {
  id: string;
  collection: "articles";
  tags: string[];
  title?: string;
  summary?: string;
  body?: string;
  publishDate: Date;
} | null {
  const view = articleView(data);
  if (!view || !view.publishDate || view.tags.length === 0) return null;
  return {
    id: view.slug,
    collection: "articles",
    tags: view.tags,
    title: view.title,
    summary: view.summary,
    body: portableTextPlainText(data.content),
    publishDate: view.publishDate,
  };
}

/** The part of an EmDash taxonomy term the tag pages read. */
export interface TagTerm {
  slug: string;
  label: string;
  count?: number;
}

/** One `/tags/<slug>/` page: every EmDash term whose label maps to that slug. */
export interface TagTermGroup {
  slug: string;
  /** The terms' labels, the verbatim tag text, alphabetical. */
  labels: string[];
  /** The terms' own EmDash slugs, to query their articles by. */
  termSlugs: string[];
  /** Published articles across the terms. An article carrying two of them counts twice. */
  count: number;
}

/**
 * Groups EmDash `tag` terms by the template's tag slug (`tagSlug` in `tags.ts`, passed in), the
 * slug an article page's tag links use, so `/tags/<slug>/` answers for exactly the links the
 * site renders. Terms with no published article (`count === 0`) are left out. Sorted by slug.
 */
export function tagTermGroups(terms: TagTerm[], tagSlug: (label: string) => string): TagTermGroup[] {
  const groups = new Map<string, TagTermGroup>();
  for (const term of terms) {
    if (!term.label || term.count === 0) continue;
    const slug = tagSlug(term.label);
    let group = groups.get(slug);
    if (!group) {
      group = { slug, labels: [], termSlugs: [], count: 0 };
      groups.set(slug, group);
    }
    if (!group.labels.includes(term.label)) group.labels.push(term.label);
    group.termSlugs.push(term.slug);
    group.count += term.count ?? 0;
  }
  return [...groups.values()]
    .map((g) => ({ ...g, labels: g.labels.sort((a, b) => a.localeCompare(b)) }))
    .sort((a, b) => a.slug.localeCompare(b.slug));
}

/** EmDash's route-cache hint for a query's results (`CacheHint`, from the `emdash` package). */
export interface CacheHint {
  tags?: string[];
  lastModified?: Date;
}

/**
 * The union of several queries' cache hints, for a page built from more than one EmDash query:
 * every query's tags, so a change to any of them purges the page, and the latest `lastModified`.
 */
export function mergeCacheHints(hints: CacheHint[]): CacheHint {
  const tags = [...new Set(hints.flatMap((h) => h.tags ?? []))].sort();
  const dates = hints.map((h) => h.lastModified).filter((d): d is Date => d instanceof Date);
  const lastModified = dates.length > 0 ? new Date(Math.max(...dates.map((d) => d.getTime()))) : undefined;
  return { ...(tags.length > 0 ? { tags } : {}), ...(lastModified ? { lastModified } : {}) };
}
