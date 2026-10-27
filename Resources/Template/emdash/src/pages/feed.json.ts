// The site's JSON Feed on an EmDash site (#2133): the template's `src/pages/feed.json.ts` with EmDash's published articles as
// its items, rendered on request (EmDash keeps the articles, so a build has none to list). Where the
// Worker caches (#2116) it carries EmDash's cache tags, so a publish purges it with the pages.
import type { APIContext } from "astro";
import { readConfig } from "../../scripts/config";
import { feedAuthor } from "../lib/feed-items.ts";
import { renderJsonFeed, siteFrom, websubHub } from "../lib/feeds.ts";
import { articleFeedItems } from "../lib/article-sources.ts";
import { articleCacheOptions } from "../lib/worker-cache.ts";

export const prerender = false;

export async function GET(context: APIContext) {
  const site = siteFrom(context);
  const { items, cacheHint } = await articleFeedItems(site);
  if (context.cache?.enabled) context.cache.set(articleCacheOptions(cacheHint));
  return renderJsonFeed({
    title: "All posts",
    site,
    feedUrl: new URL("/feed.json", site).href,
    items,
    hubUrl: websubHub(site, "/feed.json", readConfig("WEBSUB_ENABLED") === "true")?.hubUrl,
    author: feedAuthor(),
  });
}
