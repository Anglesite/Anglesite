// The site's RSS feed on an EmDash site (#2133): the template's `src/pages/rss.xml.ts` with EmDash's published articles as
// its items, rendered on request (EmDash keeps the articles, so a build has none to list). Where the
// Worker caches (#2116) it carries EmDash's cache tags, so a publish purges it with the pages.
import type { APIContext } from "astro";
import { readConfig } from "../../scripts/config";
import { feedAuthor, feedRsl } from "../lib/feed-items.ts";
import { renderRss, siteFrom, websubHub } from "../lib/feeds.ts";
import { articleFeedItems } from "../lib/article-sources.ts";
import { articleCacheOptions } from "../lib/worker-cache.ts";

export const prerender = false;

export async function GET(context: APIContext) {
  const site = siteFrom(context);
  const { items, cacheHint } = await articleFeedItems(site);
  if (context.cache?.enabled) context.cache.set(articleCacheOptions(cacheHint));
  return renderRss({
    title: "All posts",
    description: "Everything published on this site.",
    site,
    items,
    hub: websubHub(site, "/rss.xml", readConfig("WEBSUB_ENABLED") === "true"),
    author: feedAuthor(),
    rsl: feedRsl(site),
  });
}
