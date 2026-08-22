import { Readability } from "@mozilla/readability";
import { mf2 } from "microformats-parser";
import TurndownService from "turndown";

export interface ExtractionRecord {
  title: string | null;
  byline: string | null;
  publishedISO: string | null;
  lang: string | null;
  canonical: string | null;
  markdown: string;
  excerpt: string | null;
  images: string[];
  mf2JSON: string | null;
  feedLinks: string[];
}

const FEED_TYPES = new Set([
  "application/rss+xml", "application/atom+xml", "application/feed+json", "application/json",
]);

export function extractPage(doc: Document, url: string): ExtractionRecord {
  const html = doc.documentElement.outerHTML;
  const canonical =
    doc.querySelector<HTMLLinkElement>('link[rel="canonical"]')?.href ?? null;
  const feedLinks = [...doc.querySelectorAll<HTMLLinkElement>('link[rel="alternate"]')]
    .filter((l) => FEED_TYPES.has(l.type))
    .map((l) => l.href);
  const publishedISO =
    doc.querySelector<HTMLTimeElement>("time[datetime]")?.dateTime ??
    doc.querySelector<HTMLMetaElement>('meta[property="article:published_time"]')?.content ?? null;

  // Readability mutates its input — parse a clone.
  const article = new Readability(doc.cloneNode(true) as Document).parse();
  const turndown = new TurndownService({ headingStyle: "atx", codeBlockStyle: "fenced" });
  const bodyHTML = article?.content ?? doc.body.innerHTML;
  const markdown = turndown.turndown(bodyHTML);

  const container = doc.createElement("div");
  container.innerHTML = bodyHTML;
  const images = [...container.querySelectorAll<HTMLImageElement>("img[src]")].map((i) => i.src);

  let mf2JSON: string | null = null;
  try {
    mf2JSON = JSON.stringify(mf2(html, { baseUrl: url }));
  } catch {
    mf2JSON = null; // malformed markup: mf2 is an enhancement, not a requirement
  }

  return {
    title: article?.title || doc.title.split(/\s+[—|–-]\s+/)[0] || null,
    byline: article?.byline ?? null,
    publishedISO,
    lang: doc.documentElement.lang || null,
    canonical,
    markdown,
    excerpt: article?.excerpt ?? null,
    images,
    mf2JSON,
    feedLinks,
  };
}
