/**
 * Gathers this specific site's `IndieMarkInputs` (astro:content, `.site-config`,
 * `robots-config.json`) for `indiemark.ts`'s pure `assessIndieMark`. Kept separate from
 * `indiemark.ts` so the assessment logic itself stays unit-testable with plain `node:test` —
 * same split as `collection-index.ts` / `collection-index-astro.ts`.
 */
import { getCollection } from "astro:content";
import { readConfig } from "../../scripts/config.ts";
import { readRobotsConfig, isNoindexed } from "./robots-config.ts";
import { ENTRY_COLLECTIONS } from "./collections.ts";
import { profileExists } from "./profile.ts";
import type { IndieMarkInputs } from "./indiemark.ts";

// Every routed post-type collection: ENTRY_COLLECTIONS excludes `blog` by construction (see
// collections.ts), so it's added back here — same [...ENTRY_COLLECTIONS, "blog"] idiom as
// licensing.ts's LICENSABLE_COLLECTIONS, mcp-search-entries.ts's SEARCH_INDEX_COLLECTIONS, and
// sitemap-data.ts's SITEMAP_COLLECTIONS. Using FEED_COLLECTIONS here (an earlier version of this
// file did) under-counted: it only has the 8 collections with a feed, missing
// announcements/events/reviews.
const POST_TYPE_COLLECTIONS = [...ENTRY_COLLECTIONS, "blog"] as const;

export async function gatherIndieMarkInputs(): Promise<IndieMarkInputs> {
  const hasProfile = profileExists();

  const postTypeCounts: Record<string, number> = {};
  let hasSyndicatedPosts = false;
  for (const collection of POST_TYPE_COLLECTIONS) {
    const entries = await getCollection(collection as any, ({ data }: any) =>
      import.meta.env.PROD ? !data.draft : true,
    );
    postTypeCounts[collection] = entries.length;
    if (entries.some((entry: any) => Array.isArray(entry.data.syndication) && entry.data.syndication.length > 0)) {
      hasSyndicatedPosts = true;
    }
  }

  return {
    hasProfile,
    postTypeCounts,
    homeIndexable: !isNoindexed("/", readRobotsConfig(process.cwd())),
    webmentionReceiveEnabled: readConfig("WEBMENTION_RECEIVE_ENABLED") === "true",
    micropubEnabled: readConfig("MICROPUB_ENABLED") === "true",
    websubEnabled: readConfig("WEBSUB_ENABLED") === "true",
    hasSyndicatedPosts,
  };
}
