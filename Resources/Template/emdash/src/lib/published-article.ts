/**
 * Maps the entry EmDash hands its `content:afterPublish` hook onto what the Worker's
 * syndication needs (#2168): `PublishedPost` in `worker/worker.ts`. The hook's entry is EmDash's
 * stored record (`{ id, slug, data, publishedAt, … }`), not the flattened shape
 * `getEmDashCollection` returns, so the article's fields are read from `data` here and then
 * mapped by `articleView`, the same mapping the article page renders.
 *
 * Dependency-free on purpose: the template's `npm test` runs this with no EmDash install.
 */
import { articleView, type EmDashArticleData } from "./emdash-articles.ts";
import { portableTextToHtml } from "./portable-text-html.ts";

/** `PublishedPost` in `worker/worker.ts`, restated so this module stays dependency-free. */
export interface SyndicatedArticle {
  url: string;
  type: "Article";
  name?: string;
  summary?: string;
  contentHtml: string;
  published: string;
  image?: { url: string; name?: string };
}

/** The entry EmDash passes `content:afterPublish`. */
export interface PublishedRecord {
  id?: unknown;
  slug?: unknown;
  status?: unknown;
  data?: unknown;
  publishedAt?: unknown;
}

/**
 * The site's canonical origin: `SITE_URL` (the Worker's var, then `.site-config`), else the URL
 * EmDash knows the site by. `null` when none is an http(s) URL, and then nothing is syndicated:
 * an actor IRI or a Webmention source on the wrong host would be worse than none.
 */
export function syndicationOrigin(...candidates: Array<string | undefined>): string | null {
  for (const candidate of candidates) {
    if (!candidate) continue;
    try {
      const url = new URL(candidate);
      if (url.protocol === "https:" || url.protocol === "http:") return url.origin;
    } catch {
      // Try the next one.
    }
  }
  return null;
}

/** The article's public path, as the overlay's `articles/[slug].astro` serves it. */
export function articlePath(slug: string): string {
  return `/articles/${encodeURIComponent(slug)}/`;
}

/**
 * The published article, or `null` for one that has no public URL (no slug), isn't live, or has
 * no publication time. A relative image (EmDash's media route) is made absolute on `origin`; one
 * that isn't a URL is left off rather than holding the article back.
 */
export function publishedArticle(record: PublishedRecord, origin: string): SyndicatedArticle | null {
  if (record.status !== undefined && record.status !== "published") return null;
  const fields = record.data && typeof record.data === "object" ? (record.data as Record<string, unknown>) : {};
  const published = parseDate(record.publishedAt);
  if (!published) return null;
  const view = articleView({
    ...fields,
    id: typeof record.id === "string" ? record.id : "",
    slug: typeof record.slug === "string" && record.slug !== "" ? record.slug : null,
    publishedAt: published,
  } as EmDashArticleData);
  if (!view) return null;
  return {
    url: `${origin}${articlePath(view.slug)}`,
    type: "Article",
    ...(view.title ? { name: view.title } : {}),
    ...(view.summary ? { summary: view.summary } : {}),
    contentHtml: portableTextToHtml(fields.content),
    published: published.toISOString(),
    ...imageAttachment(view.image, view.imageAlt, origin),
  };
}

/** The image as an absolute URL on `origin`; a value that isn't a URL drops only the image. */
function imageAttachment(image: string | undefined, alt: string, origin: string): { image?: SyndicatedArticle["image"] } {
  if (!image) return {};
  try {
    return { image: { url: new URL(image, origin).href, ...(alt ? { name: alt } : {}) } };
  } catch {
    return {};
  }
}

function parseDate(value: unknown): Date | null {
  if (value instanceof Date) return Number.isNaN(value.getTime()) ? null : value;
  if (typeof value !== "string" || value === "") return null;
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? null : date;
}

/**
 * The plugin-KV key recording that the entry was posted to followers, once per entry: keyed on
 * EmDash's id, so a later edit, a slug change or an unpublish-and-republish isn't posted again.
 * `null` for an entry without an id.
 */
export function federatedKey(record: PublishedRecord): string | null {
  return typeof record.id === "string" && record.id !== "" ? `federated:${record.id}` : null;
}
