import type { FeedLink } from "../types";

const FEED_MIME_TYPES: Record<string, FeedLink["type"]> = {
  "application/rss+xml": "rss",
  "application/atom+xml": "atom",
  "application/feed+json": "json",
};

export function detectFeeds(doc: Document): FeedLink[] {
  const links = doc.querySelectorAll<HTMLLinkElement>('link[rel~="alternate"][href]');
  const feeds: FeedLink[] = [];
  for (const link of links) {
    const mimeType = (link.getAttribute("type") ?? "").toLowerCase();
    const feedType = FEED_MIME_TYPES[mimeType];
    if (!feedType) continue;
    const href = link.getAttribute("href");
    if (!href) continue;
    feeds.push({
      title: link.getAttribute("title"),
      url: new URL(href, doc.baseURI).href,
      type: feedType,
    });
  }
  return feeds;
}
