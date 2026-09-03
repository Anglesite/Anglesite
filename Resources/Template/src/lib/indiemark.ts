/**
 * Pure per-site assessment against indieweb.org/IndieMark's current axis list (Level 0–6,
 * explicitly "rough and in-progress" upstream — there is no numbered "3.0" version). Kept free
 * of `astro:content` so it stays unit-testable with plain `node:test`, same rationale as
 * `collection-index.ts` / `tags.ts` / `content-schemas.ts`. The `astro:content`-importing half
 * that gathers `IndieMarkInputs` for a real build lives in `indiemark-astro.ts`.
 *
 * `basis: "detected"` axes have a real build-time signal for this specific site (content
 * collections, `.site-config`, `robots-config.json`) and set `present`. `basis: "supported"`
 * axes are implemented by Anglesite's sidecar worker but gated by Worker secrets/bindings that
 * aren't visible to an Astro build, so they're described as platform capability rather than
 * falsely verified per-site — `present` stays unset for those.
 */

export type AxisBasis = "detected" | "supported";

export interface AxisResult {
  axis: string;
  basis: AxisBasis;
  /** Set only when basis === "detected": whether this site's build actually has the
   * feature active right now. */
  present?: boolean;
  label: string;
  detail: string;
}

export interface IndieMarkInputs {
  hasProfile: boolean;
  postTypeCounts: Record<string, number>;
  homeIndexable: boolean;
  webmentionReceiveEnabled: boolean;
  micropubEnabled: boolean;
  websubEnabled: boolean;
  hasSyndicatedPosts: boolean;
}

/**
 * Human-readable label per routed post-type collection. Must cover every member of
 * `ENTRY_COLLECTIONS` (`./collections.ts`) plus `"blog"` — see
 * `indiemark.test.ts`'s coverage test, which guards this against drifting out of sync.
 */
export const POST_TYPE_LABELS: Record<string, string> = {
  blog: "blog posts",
  notes: "notes",
  articles: "articles",
  photos: "photos",
  albums: "albums",
  bookmarks: "bookmarks",
  replies: "replies",
  likes: "likes",
  rsvps: "RSVPs",
  announcements: "announcements",
  events: "events",
  reviews: "reviews",
};

function detected(axis: string, present: boolean, detail: string): AxisResult {
  return { axis, basis: "detected", present, label: present ? "Detected on this site" : "Not set up on this site yet", detail };
}

function supported(axis: string, detail: string): AxisResult {
  return { axis, basis: "supported", label: "Supported by Anglesite", detail };
}

function postsAxis(postTypeCounts: Record<string, number>): AxisResult {
  const known = Object.keys(postTypeCounts).map((key) => POST_TYPE_LABELS[key] ?? key);
  const active = Object.entries(postTypeCounts)
    .filter(([, count]) => count > 0)
    .map(([key]) => POST_TYPE_LABELS[key] ?? key);
  if (active.length === 0) {
    // `known` can be empty in unit tests that pass an unpopulated postTypeCounts ({}) — fall back
    // to a plain "No posts yet." rather than an empty/malformed parenthetical in that case.
    const detail =
      known.length === 0
        ? "No posts yet."
        : `No posts yet in any post-type collection (${known.join(", ")}).`;
    return detected("Posts", false, detail);
  }
  const noun = active.length === 1 ? "post type" : "post types";
  return detected("Posts", true, `Publishing ${active.length} ${noun}: ${active.join(", ")}.`);
}

export function assessIndieMark(inputs: IndieMarkInputs): AxisResult[] {
  return [
    detected(
      "Identity",
      inputs.hasProfile,
      inputs.hasProfile
        ? "This site publishes an h-card — name, photo, and contact info — on every page, from src/data/profile.json."
        : "No src/data/profile.json yet, so this site doesn't publish an h-card. Add one in Anglesite to identify yourself in machine-readable form.",
    ),
    postsAxis(inputs.postTypeCounts),
    detected(
      "Search discoverability",
      inputs.homeIndexable,
      inputs.homeIndexable
        ? "The home page is indexable — no noindex directive blocks search engines from crawling it."
        : 'The home page is marked noindex, so search engines won\'t index it — site-specific search (e.g. "site:yourdomain.com") won\'t surface your posts until this changes.',
    ),
    detected(
      "Webmention (receiving)",
      inputs.webmentionReceiveEnabled,
      inputs.webmentionReceiveEnabled
        ? "Webmention receiving is enabled (.site-config WEBMENTION_RECEIVE_ENABLED) — other sites' mentions of your posts can show up as comments."
        : "Webmention receiving isn't enabled yet (.site-config WEBMENTION_RECEIVE_ENABLED) — turn it on to start collecting mentions from other IndieWeb sites.",
    ),
    detected(
      "Micropub",
      inputs.micropubEnabled,
      inputs.micropubEnabled
        ? "Micropub is enabled (.site-config MICROPUB_ENABLED) — you can post to this site from any Micropub client."
        : "Micropub isn't enabled yet (.site-config MICROPUB_ENABLED).",
    ),
    detected(
      "WebSub",
      inputs.websubEnabled,
      inputs.websubEnabled
        ? "WebSub is enabled (.site-config WEBSUB_ENABLED) — subscribers get near-real-time updates instead of polling your feeds."
        : "WebSub isn't enabled yet (.site-config WEBSUB_ENABLED).",
    ),
    detected(
      "Syndication (POSSE)",
      inputs.hasSyndicatedPosts,
      inputs.hasSyndicatedPosts
        ? "At least one post on this site has been POSSEd — it carries a recorded syndication copy elsewhere."
        : "No posts have recorded POSSE syndication copies yet. Syndicate a post with the syndicate skill to start.",
    ),
    supported(
      "Authentication (IndieAuth)",
      "Anglesite's sidecar implements an IndieAuth provider, gated by Worker secrets (INDIEAUTH_OWNER_PASSWORD, TOKEN_SIGNING_KEY, SOCIAL_KV) set outside this build — check your Cloudflare Worker's configuration to confirm it's provisioned for this site.",
    ),
    supported(
      "Aggregation (Microsub)",
      "Anglesite's sidecar implements a Microsub server, gated by Worker bindings (MICROSUB_DB, MICROSUB_QUEUE) set outside this build — check your Worker's configuration to confirm it's provisioned.",
    ),
    supported(
      "Handling responses (ActivityPub)",
      "Anglesite's sidecar implements ActivityPub federation, gated by Worker bindings set outside this build — check your Worker's configuration to confirm it's provisioned.",
    ),
    supported("Security (HTTPS)", "Every Anglesite site is served over HTTPS by Cloudflare — there's no per-site toggle to check."),
    supported(
      "Own-site search backend",
      "Every Anglesite site ships a Pagefind-powered search index at /search/, built from your own content — no third-party service involved. The index only exists after a production build, so this page can't probe it directly.",
    ),
    supported(
      "Microformats2 markup",
      "Anglesite's templates emit h-entry, h-card, h-feed, and related microformats2 markup automatically. This page doesn't re-validate it — use the IndieWeb h-entry/h-card testing tools to check a specific page.",
    ),
  ];
}
