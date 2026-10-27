/**
 * Maps an EmDash `articles` entry onto the fields the template's h-entry markup renders
 * (#2050). The mapping is explicit (ADR § Consequences, "Schema mapping is explicit"): a field
 * EmDash adds that isn't named here isn't rendered. `unmappedFields` names such fields; the
 * article page logs them to the Worker's log on every render, and the tests hold the seed's
 * schema to `ARTICLE_FIELDS`, so neither a field added in EmDash's admin nor one added to the
 * seed goes missing silently.
 *
 * Dependency-free on purpose: the template's `npm test` runs this with no EmDash install.
 */

/** The EmDash fields of an `articles` entry this template renders (see `seed/seed.json`). */
export const ARTICLE_FIELDS = ["title", "summary", "content", "image"] as const;

/** Fields every EmDash entry carries that aren't authored content. */
const SYSTEM_FIELDS = new Set([
  "id", "slug", "status", "locale", "createdAt", "updatedAt", "publishedAt", "scheduledAt",
  "byline", "bylines", "terms", "translationGroup", "primaryBylineId", "authorId", "version",
]);

/** An EmDash image field value: a URL for external media, or a storage key for R2 media. */
export interface EmDashImage {
  id?: string;
  src?: string;
  alt?: string;
  meta?: Record<string, unknown>;
}

/** The subset of an EmDash entry's `data` this module reads. */
export interface EmDashArticleData {
  id: string;
  slug: string | null;
  title?: string;
  summary?: string;
  image?: EmDashImage;
  publishedAt?: Date | null;
  updatedAt?: Date;
  bylines?: Array<{ byline?: { displayName?: string } }>;
  terms?: Record<string, Array<{ label?: string }>>;
  [field: string]: unknown;
}

/** What `Hentry`-style markup needs for one article. */
export interface ArticleView {
  slug: string;
  title?: string;
  summary?: string;
  publishDate?: Date;
  updated?: Date;
  /** Absolute URL, or a site-relative path to EmDash's media route. Media stays in R2. */
  image?: string;
  imageAlt: string;
  tags: string[];
  authors: string[];
}

/** How many articles one page of the article index lists. */
export const ARTICLES_PER_PAGE = 50;

/** EmDash serves R2 media from this route (media is never copied into the build, decision 3). */
export const EMDASH_MEDIA_ROUTE = "/_emdash/api/media/file/";

/**
 * The article's image URL: an external `src` if it is `https:` or site-relative, else EmDash's
 * media route for its key. Any other `src` (`http:`, `data:`, `javascript:`, protocol-relative)
 * is dropped rather than rendered into `<img src>` and the JSON-LD.
 */
export function imageURL(image: EmDashImage | undefined): string | undefined {
  if (!image) return undefined;
  if (typeof image.src === "string" && image.src !== "") return safeImageSource(image.src);
  const key = typeof image.meta?.storageKey === "string" ? image.meta.storageKey : image.id;
  return key ? `${EMDASH_MEDIA_ROUTE}${encodeURIComponent(key)}` : undefined;
}

/** Maps one entry. Returns `null` for an entry with no slug, which has no public URL. */
export function articleView(data: EmDashArticleData): ArticleView | null {
  if (!data.slug) return null;
  return {
    slug: data.slug,
    title: data.title || undefined,
    summary: data.summary || undefined,
    publishDate: data.publishedAt ?? undefined,
    updated: data.updatedAt,
    image: imageURL(data.image),
    imageAlt: data.image?.alt ?? "",
    tags: (data.terms?.tag ?? []).map((t) => t.label ?? "").filter((t) => t !== ""),
    authors: (data.bylines ?? []).map((b) => b.byline?.displayName ?? "").filter((n) => n !== ""),
  };
}

/** Authored fields on the entry that this module doesn't map (and so the page wouldn't show). */
export function unmappedFields(data: EmDashArticleData): string[] {
  const known = new Set<string>(ARTICLE_FIELDS);
  return Object.keys(data).filter((k) => !known.has(k) && !SYSTEM_FIELDS.has(k)).sort();
}

function safeImageSource(src: string): string | undefined {
  if (src.startsWith("/") && !src.startsWith("//")) return src;
  try {
    return new URL(src).protocol === "https:" ? src : undefined;
  } catch {
    return undefined;
  }
}
