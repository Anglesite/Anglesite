// The site's pages on an EmDash site (#2133): the template's own sitemap, prerendered, under the
// sitemap index at `/sitemap.xml`. The deploy gate checks this file for an experiment's variant
// page, as it checks `sitemap.xml` on an Anglesite site.
import type { APIContext } from "astro";
import { siteFrom } from "../lib/feeds.ts";
import { getSitemapUrls } from "../lib/sitemap-data.ts";
import { renderSitemap } from "../lib/sitemap.ts";

export const prerender = true;

export async function GET(context: APIContext) {
  const site = siteFrom(context);
  return renderSitemap(await getSitemapUrls(site));
}
