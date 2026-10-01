/**
 * Workers Caching for an EmDash site (#2116, ADR decision 4 in
 * docs/specs/2026-09-28-external-cms-content-source-decision.md).
 *
 * Anglesite turns the Worker's cache on only for an account on the Workers Paid plan: caching
 * bills every request, static files included, so on the Free plan it would spend the daily
 * request limit faster. Publish Site records the owner's answer in the Worker config it writes
 * (`[cache] enabled = true|false` in `wrangler.toml`), and `astro.config.ts` reads it here: with
 * the cache on, Astro gets Cloudflare's cache provider, and EmDash purges the cached pages on
 * every publish, unpublish and edit. With it off there is no provider, so EmDash never purges a
 * cache the Worker doesn't have.
 */

/**
 * How long a cached article page or article index may be served before it is rendered again.
 * EmDash purges a page as soon as one of its articles changes, so this only bounds the changes
 * it doesn't tag a page with (an author's display name, say).
 */
export const ARTICLE_CACHE_MAX_AGE_SECONDS = 3600;

/**
 * Whether `toml` (the Worker config, or `undefined` when there is none, as in local
 * development) turns Workers Caching on. Only `enabled = true` under a `[cache]` table counts;
 * anything else leaves it off.
 *
 * Not a TOML parser: it reads only the plain `[cache]` table `EmDashWorkerConfig` writes, so a
 * `#` always starts a comment here, even inside a quoted string.
 */
export function workerCacheEnabled(toml: string | undefined): boolean {
  if (!toml) return false;
  let inCacheTable = false;
  for (const raw of toml.split(/\r?\n/)) {
    const line = raw.replace(/#.*$/, "").trim();
    if (line === "") continue;
    if (line.startsWith("[")) {
      inCacheTable = line === "[cache]";
      continue;
    }
    if (!inCacheTable) continue;
    const enabled = /^enabled\s*=\s*(true|false)$/.exec(line);
    if (enabled) return enabled[1] === "true";
  }
  return false;
}

/** What EmDash attaches to an entry or collection it returned, for the route cache. */
export type CacheHint = { tags?: string[]; lastModified?: Date };

/**
 * The cache options for an article page or the article index: EmDash's tags, which its publish
 * purges, plus an explicit max-age. Without one, Cloudflare would guess how long to keep the page.
 */
export function articleCacheOptions(hint: CacheHint | undefined): CacheHint & { maxAge: number } {
  return { ...hint, maxAge: ARTICLE_CACHE_MAX_AGE_SECONDS };
}
