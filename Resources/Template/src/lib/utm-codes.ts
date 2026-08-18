import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

export interface UTMCampaign {
  source: string;
  medium: string;
  campaign: string;
  term?: string;
  content?: string;
  appliesTo: string[];
}

/// Returns `true` if `entry` has the shape `readUTMCodes` requires: `source`/`medium`/`campaign`
/// are strings, `term`/`content` are absent or strings, and `appliesTo` is an array of strings.
export function isValidUTMCampaign(entry: unknown): entry is UTMCampaign {
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

/// Reads `utm-codes.json` from the site root. Returns `[]` if the file is missing entirely — a
/// site with no UTM codes yet is the normal, silent case. If the file is present but fails to
/// parse, or parses but individual entries are malformed, this warns via `console.warn`
/// (surfaced in Astro's build/dev logs) and drops the bad parts, mirroring `readRedirects` in
/// `scripts/redirects.ts` — a build must never fail because `utm-codes.json` was hand-edited into
/// a bad state.
export function readUTMCodes(siteRoot: string = process.cwd()): UTMCampaign[] {
  const path = resolve(siteRoot, "utm-codes.json");
  if (!existsSync(path)) return [];

  let raw: string;
  try {
    raw = readFileSync(path, "utf-8");
  } catch {
    return [];
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    console.warn(`[anglesite-utm] utm-codes.json exists but is not valid JSON: ${err}`);
    return [];
  }

  if (!Array.isArray(parsed)) {
    console.warn("[anglesite-utm] utm-codes.json must contain a JSON array; ignoring its contents.");
    return [];
  }

  const valid = parsed.filter(isValidUTMCampaign);
  const droppedCount = parsed.length - valid.length;
  if (droppedCount > 0) {
    console.warn(
      `[anglesite-utm] dropped ${droppedCount} malformed UTM ${droppedCount === 1 ? "entry" : "entries"} from utm-codes.json.`,
    );
  }
  return valid;
}

/// The campaign (if any) whose `appliesTo` names `target` — an RSS collection key or
/// `"fediverse"`. At most one campaign should claim a given target (`UTMCodesStore.validate`
/// enforces this on the Swift side before it ever reaches disk); the first match wins if that
/// invariant is ever violated by a hand-edited file.
export function activeCampaignFor(campaigns: UTMCampaign[], target: string): UTMCampaign | undefined {
  return campaigns.find((c) => c.appliesTo.includes(target));
}

/// Appends `utm_source`/`utm_medium`/`utm_campaign` (plus `utm_term`/`utm_content` when set) to
/// `url` via `URLSearchParams`, safe against an existing query string. Returns `url` unchanged
/// when `campaign` is `undefined` — the "no active campaign for this target" case.
export function tagUrl(url: string, campaign: UTMCampaign | undefined): string {
  if (!campaign) return url;
  const u = new URL(url);
  u.searchParams.set("utm_source", campaign.source);
  u.searchParams.set("utm_medium", campaign.medium);
  u.searchParams.set("utm_campaign", campaign.campaign);
  if (campaign.term) u.searchParams.set("utm_term", campaign.term);
  if (campaign.content) u.searchParams.set("utm_content", campaign.content);
  return u.href;
}
