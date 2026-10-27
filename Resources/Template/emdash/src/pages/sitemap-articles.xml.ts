// The published articles on an EmDash site (#2133), newest first, rendered on request from EmDash
// and listed in the sitemap index at `/sitemap.xml`. Where the Worker caches (#2116) it carries
// EmDash's cache tags, so a publish or unpublish purges it with the article pages.
import type { APIContext } from "astro";
import { siteFrom } from "../lib/feeds.ts";
import { buildSitemapUrls, renderSitemap } from "../lib/sitemap.ts";
import { articleSitemapEntries } from "../lib/article-sources.ts";
import { articleCacheOptions } from "../lib/worker-cache.ts";

export const prerender = false;

export async function GET(context: APIContext) {
  const site = siteFrom(context);
  const { entries, cacheHint } = await articleSitemapEntries();
  if (context.cache?.enabled) context.cache.set(articleCacheOptions(cacheHint));
  return renderSitemap(buildSitemapUrls(site, [], entries));
}
