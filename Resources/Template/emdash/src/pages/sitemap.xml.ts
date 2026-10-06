// The sitemap on an EmDash site (#2133): an index of two sitemaps, since the pages and the
// articles come from different places. The pages are prerendered (`sitemap-pages.xml`, the
// template's own sitemap); the articles render on request from EmDash (`sitemap-articles.xml`).
// `robots.txt` points at this file on every site, so it stays at `/sitemap.xml`.
import type { APIContext } from "astro";
import { siteFrom } from "../lib/feeds.ts";
import { renderSitemapIndex } from "../lib/sitemap.ts";

export async function GET(context: APIContext) {
  const site = siteFrom(context);
  return renderSitemapIndex([
    { loc: new URL("/sitemap-pages.xml", site).href },
    { loc: new URL("/sitemap-articles.xml", site).href },
  ]);
}
