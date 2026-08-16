import type { APIContext } from "astro";
import { getCollection } from "astro:content";
import { renderOpml } from "../lib/opml.ts";

export async function GET(_context: APIContext) {
  const entries = await getCollection("blogroll");
  const outlines = entries
    .filter((e) => e.data.feedURL)
    .map((e) => ({
      text: e.data.name,
      title: e.data.name,
      xmlUrl: e.data.feedURL as string,
      htmlUrl: e.data.url,
    }));
  return renderOpml("Blogroll", outlines);
}
