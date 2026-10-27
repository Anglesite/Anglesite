import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import {
  articleFeedSource,
  articleSitemapEntry,
  articleTaggedEntry,
  mergeCacheHints,
  tagTermGroups,
} from "./article-listings.ts";
import type { EmDashArticleData } from "./emdash-articles.ts";

// The template's own pure helpers, which these shapes feed on an EmDash site. In the template
// repository they sit in `src/lib/` beside the overlay; in a scaffolded EmDash site this file is
// copied into `src/lib/` next to them. Imported dynamically from whichever exists, so the file
// type-checks (`astro check`) and runs in both places.
const templateLib = existsSync(new URL("./feeds.ts", import.meta.url)) ? "./" : "../../../src/lib/";
const { toFeedItem } = await import(`${templateLib}feeds.ts`);
const { buildSitemapUrls } = await import(`${templateLib}sitemap.ts`);
const { groupBySlug, tagSlug } = await import(`${templateLib}tags.ts`);

const SITE = "https://news.example/";
const published = new Date("2026-10-01T09:00:00Z");
const updated = new Date("2026-10-02T10:00:00Z");

function article(overrides: Partial<EmDashArticleData> = {}): EmDashArticleData {
  return {
    id: "01J",
    slug: "council-vote",
    title: "Council vote",
    summary: "It passed.",
    publishedAt: published,
    updatedAt: updated,
    terms: { tag: [{ label: "Local Politics" }] },
    content: [
      { _type: "block", _key: "a", style: "normal", markDefs: [], children: [{ _type: "span", _key: "s", text: "Five to two.", marks: [] }] },
    ],
    ...overrides,
  };
}

test("an article becomes the feed item the template's toFeedItem builds for articles", () => {
  const source = articleFeedSource(article());
  assert.ok(source);
  assert.equal(source.contentHtml, "<p>Five to two.</p>");
  assert.equal(source.entry.body, "Five to two.");
  const item = toFeedItem("articles", source.entry, SITE, source.contentHtml);
  assert.equal(item.title, "Council vote");
  assert.equal(item.link, "https://news.example/articles/council-vote/");
  assert.equal(item.date.toISOString(), published.toISOString());
  assert.equal(item.summary, "It passed.");
  assert.deepEqual(item.tags, ["Local Politics"]);
  assert.equal(item.contentHtml, "<p>Five to two.</p>");
});

test("without a summary, the feed item excerpts the article's text", () => {
  const source = articleFeedSource(article({ summary: undefined }));
  assert.ok(source);
  assert.equal(toFeedItem("articles", source.entry, SITE, source.contentHtml).summary, "Five to two.");
});

test("a feed leaves out an article with no slug or no publish date", () => {
  assert.equal(articleFeedSource(article({ slug: null })), null);
  assert.equal(articleFeedSource(article({ publishedAt: null })), null);
  assert.equal(articleFeedSource(article({ terms: {} }))?.entry.data.tags, undefined);
});

test("an article's sitemap URL is its page, last modified when it was last updated", () => {
  const entry = articleSitemapEntry(article());
  assert.ok(entry);
  const [url] = buildSitemapUrls(SITE, [], [entry]);
  assert.equal(url.loc, "https://news.example/articles/council-vote/");
  assert.equal(url.lastmod?.toISOString(), updated.toISOString());
  assert.equal(articleSitemapEntry(article({ slug: null })), null);
});

test("tagged articles group under the same slug an article page links to", () => {
  const a = articleTaggedEntry(article());
  const b = articleTaggedEntry(article({ slug: "budget", title: "Budget", terms: { tag: [{ label: "local politics" }] } }));
  assert.ok(a && b);
  assert.equal(articleTaggedEntry(article({ terms: {} })), null);
  const groups = groupBySlug([a, b]);
  assert.deepEqual([...groups.keys()], [tagSlug("Local Politics")]);
  assert.equal(groups.get("local-politics")?.entries.length, 2);
});

test("tag terms group by the template's tag slug, skipping terms with no published article", () => {
  const groups = tagTermGroups(
    [
      { slug: "local-politics", label: "Local Politics", count: 3 },
      { slug: "local-politics-2", label: "local politics", count: 1 },
      { slug: "weather", label: "Weather", count: 2 },
      { slug: "empty", label: "Empty", count: 0 },
    ],
    tagSlug,
  );
  assert.deepEqual(groups, [
    // Two terms share the slug: EmDash's per-term counts can't be summed (an article may carry
    // both), so the merged group has no count.
    { slug: "local-politics", labels: ["local politics", "Local Politics"], termSlugs: ["local-politics", "local-politics-2"] },
    { slug: "weather", labels: ["Weather"], termSlugs: ["weather"], count: 2 },
  ]);
});

test("merged cache hints carry every query's tags and the latest lastModified", () => {
  assert.deepEqual(
    mergeCacheHints([
      { tags: ["articles", "a1"], lastModified: published },
      { tags: ["taxonomy:tag", "articles"], lastModified: updated },
      {},
    ]),
    { tags: ["a1", "articles", "taxonomy:tag"], lastModified: updated },
  );
  assert.deepEqual(mergeCacheHints([{}, {}]), {});
});
