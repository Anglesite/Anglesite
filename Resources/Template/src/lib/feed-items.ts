/**
 * The parts of feed building that don't render markdown (#2133): mapping entries to feed items
 * with the collection's license and UTM campaign, and the feed-level author and RSL context.
 * Split from `feed-data.ts`, which reads git collections and renders their markdown bodies, so an
 * EmDash site's feeds can run in its Worker without that pipeline in the bundle.
 */
import { toFeedItem, type FeedEntry, type FeedItem, type FeedAuthor, type FeedRsl } from "./feeds.ts";
import { siteProfile, ownerName } from "./profile.ts";
import { readConfig } from "../../scripts/config";
import { assertsNothingExplicitly, type LicensableCollection } from "./licensing.ts";
import { licensingPolicy, licenseFor } from "./licensing-data.ts";
import { rslActive } from "./rsl.ts";
import { readUTMCodes, activeCampaignFor } from "./utm-codes.ts";

/// The feed items for a collection's entries, whatever they were read from, with the
/// collection's license and active UTM campaign applied the same way for every source. Unsorted,
/// like `feed-data.ts`'s `mapCollection`. An EmDash site (#2133) passes its published articles,
/// rendered from Portable Text, so its feeds carry the same fields as a git-backed site's.
export function feedItemsFor(
  collection: string,
  site: string,
  entries: Array<{ entry: FeedEntry; contentHtml: string }>,
): FeedItem[] {
  const policy = licensingPolicy();
  const licensable = collection as LicensableCollection;
  const licenseInfo = {
    license: licenseFor(licensable),
    assertsNothingExplicitly: assertsNothingExplicitly(policy, licensable),
  };
  const utmCampaign = activeCampaignFor(readUTMCodes(), collection);
  return entries.map(({ entry, contentHtml }) =>
    toFeedItem(collection, entry, site, contentHtml, licenseInfo, utmCampaign),
  );
}

/// Feed-level (channel/feed) author, derived from `siteProfile()` (`src/data/profile.json`).
/// `siteProfile()` reads via `import.meta.glob`, which only resolves under Astro/Vite — this
/// lookup belongs here (consumed by the 36 feed routes) rather than in `feeds.ts`, whose
/// renderers take `author` as a plain parameter so pure node:test unit tests can inject it
/// directly. Returns `undefined` when no name is configured (the default, unconfigured site),
/// so every renderer omits author markup cleanly.
export function feedAuthor(): FeedAuthor | undefined {
  const profile = siteProfile();
  const name = typeof profile.name === "string" && profile.name.length > 0 ? profile.name : undefined;
  if (!name) return undefined;
  const url = typeof profile.url === "string" && profile.url.length > 0 ? profile.url : undefined;
  return url ? { name, url } : { name };
}

/// The site-wide RSL context to pass as `renderRss`/`renderAtom`'s `rsl` option (#992), or
/// undefined when RSL isn't active for this build (`rslActive` in `rsl.ts` — the same gate
/// `scripts/edge-artifacts.ts`, `scripts/csp.ts`, and `BaseLayout.astro` all use). `holder` uses
/// the same `COPYRIGHT_HOLDER`/h-card fallback as `Rights.astro`'s footer statement, unlike
/// `edge-artifacts.ts`'s `main()` (which has no Vite context to read `ownerName()` from).
export function feedRsl(site: string): FeedRsl | undefined {
  const policy = licensingPolicy();
  if (!rslActive(policy, site)) return undefined;
  const holder = readConfig("COPYRIGHT_HOLDER") ?? ownerName();
  return { usage: policy.usage, holder };
}
