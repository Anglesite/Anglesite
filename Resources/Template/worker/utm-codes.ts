/// Worker-local UTM tagging (#1092). Deliberately self-contained rather than importing from
/// `src/lib/utm-codes.ts`: `worker.ts` has no existing precedent for importing across the
/// `worker/` <-> `src/lib/`/`scripts/` boundary, and this logic is small enough that duplicating
/// it is the lower-risk choice. `campaignsArtifact` comes from a static `../utm-codes.json`
/// import (see `worker.ts`), so its shape is `unknown` at the type level — validated defensively
/// here, the same tolerance principle `readUTMCodes` uses on the Astro side.
interface UTMCampaign {
  source: string;
  medium: string;
  campaign: string;
  term?: string;
  content?: string;
  appliesTo: string[];
}

function isValidUTMCampaign(entry: unknown): entry is UTMCampaign {
  if (typeof entry !== "object" || entry === null) return false;
  const e = entry as Record<string, unknown>;
  return (
    typeof e.source === "string" &&
    typeof e.medium === "string" &&
    typeof e.campaign === "string" &&
    (e.term === undefined || typeof e.term === "string") &&
    (e.content === undefined || typeof e.content === "string") &&
    Array.isArray(e.appliesTo) &&
    e.appliesTo.every((t) => typeof t === "string")
  );
}

/// Tags `url` with the campaign (if any) whose `appliesTo` includes `"fediverse"`, found within
/// `campaignsArtifact` (the raw `utm-codes.json` module). Returns `url` unchanged when the
/// artifact is malformed or no campaign targets Fediverse.
export function tagFediverseUrl(url: string, campaignsArtifact: unknown): string {
  const campaigns = Array.isArray(campaignsArtifact) ? campaignsArtifact.filter(isValidUTMCampaign) : [];
  const campaign = campaigns.find((c) => c.appliesTo.includes("fediverse"));
  if (!campaign) return url;
  try {
    const u = new URL(url);
    u.searchParams.set("utm_source", campaign.source);
    u.searchParams.set("utm_medium", campaign.medium);
    u.searchParams.set("utm_campaign", campaign.campaign);
    if (campaign.term) u.searchParams.set("utm_term", campaign.term);
    if (campaign.content) u.searchParams.set("utm_content", campaign.content);
    return u.href;
  } catch {
    // Never fails the fan-out (see doc comment above and `fanOutMicropubCreateToActivityPub` in
    // worker.ts): an unparseable `location` should silently skip tagging, not throw inside a
    // `ctx.waitUntil(...)` promise where nothing catches it.
    return url;
  }
}
