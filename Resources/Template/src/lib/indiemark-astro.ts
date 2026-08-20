/**
 * Gathers this specific site's `IndieMarkInputs` (astro:content, `.site-config`,
 * `robots-config.json`) for `indiemark.ts`'s pure `assessIndieMark`. Kept separate from
 * `indiemark.ts` so the assessment logic itself stays unit-testable with plain `node:test` —
 * same split as `collection-index.ts` / `collection-index-astro.ts`.
 */
import { getCollection } from "astro:content";
import { readConfig } from "../../scripts/config.ts";
import { readRobotsConfig, isNoindexed } from "./robots-config.ts";
import { FEED_COLLECTIONS } from "./feeds.ts";
import { profileExists } from "./profile.ts";
import type { IndieMarkInputs } from "./indiemark.ts";

export async function gatherIndieMarkInputs(): Promise<IndieMarkInputs> {
  const hasProfile = profileExists();

  const postTypeCounts: Record<string, number> = {};
  let hasSyndicatedPosts = false;
  for (const collection of Object.keys(FEED_COLLECTIONS)) {
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
