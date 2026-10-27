// Delivery pipeline (design §4): extract → attribute → replay check → rate limits → file or bump.
// Every early exit returns a machine-readable reason instead of logging payload content.

import { attribute } from "./attribute.js";
import { extractIssue } from "./extract.js";
import type { GitHubClient } from "./github.js";
import {
  MARKER_PREFIX,
  SOURCE_LABEL,
  crossSiteFingerprint,
  issueBody,
  issueTitle,
  occurrenceComment,
  packageLabel,
  type ReportInput,
} from "./report.js";

export interface RelayContext {
  state: KVNamespace;
  github: Pick<GitHubClient, "createIssue" | "getIssue" | "comment" | "findByMarker">;
  targetRepo: string;
  dailyNewIssueCap: number;
  dailySiteDeliveryCap: number;
  now: () => number;
}

export interface SiteRecord {
  secretHash: string;
  catalogCommit?: string;
  registeredAt: string;
}

export type Outcome =
  | { filed: true; action: "created" | "commented"; issue: number }
  | { filed: false; reason: string };

interface FingerprintState {
  issue: number;
  /** UTC day (YYYY-MM-DD) of the last occurrence comment — at most one per day. */
  lastCommentDay?: string;
  /** Closed by a maintainer as `config` (owner misconfiguration): never filed again. */
  suppressed?: boolean;
}

interface SeenState {
  lastSeen?: string;
  count?: number;
}

const DAY_TTL = 2 * 24 * 60 * 60;
const SEEN_TTL = 30 * 24 * 60 * 60;
export const SUPPRESS_LABEL = "config";

export async function handleDelivery(ctx: RelayContext, siteID: string, site: SiteRecord, payload: unknown): Promise<Outcome> {
  const extracted = extractIssue(payload);
  const attribution = attribute(extracted.frames);
  if (attribution.kind !== "package") return { filed: false, reason: attribution.reason };

  const report: ReportInput = {
    packageName: attribution.packageName,
    exceptionClass: extracted.exceptionClass,
    frames: attribution.frames,
    fingerprint: "",
    count: extracted.count,
    firstSeen: extracted.firstSeen,
    lastSeen: extracted.lastSeen,
    catalogCommit: site.catalogCommit,
  };
  report.fingerprint = await crossSiteFingerprint(report);

  // Replay protection: counts/timestamps are absolute snapshots, so a delivery that isn't newer
  // than what this site already reported for this issue changes nothing.
  const seenKey = `seen:${siteID}:${extracted.fingerprint ?? report.fingerprint}`;
  const seen = await ctx.state.get<SeenState>(seenKey, "json");
  if (seen && !isNewer(extracted, seen)) return { filed: false, reason: "replay" };

  const today = utcDay(ctx.now());
  const siteCapKey = `cap:site:${siteID}:${today}`;
  const siteDeliveries = await counter(ctx.state, siteCapKey);
  if (siteDeliveries >= ctx.dailySiteDeliveryCap) return { filed: false, reason: "site-rate-limit" };
  await ctx.state.put(siteCapKey, String(siteDeliveries + 1), { expirationTtl: DAY_TTL });

  // Record the snapshot only once the delivery has been handled: if GitHub fails, the thrown
  // error becomes a 5xx, Cloudflare retries, and the retry must not look like a replay.
  const outcome = await fileOrBump(ctx, report, today);
  await ctx.state.put(seenKey, JSON.stringify({ lastSeen: extracted.lastSeen, count: extracted.count }), {
    expirationTtl: SEEN_TTL,
  });
  return outcome;
}

async function fileOrBump(ctx: RelayContext, report: ReportInput, today: string): Promise<Outcome> {

  const fpKey = `fp:${report.fingerprint}`;
  let known = await ctx.state.get<FingerprintState>(fpKey, "json");
  if (!known) {
    const found = await ctx.github.findByMarker(ctx.targetRepo, `${MARKER_PREFIX}${report.fingerprint}`);
    if (found) known = { issue: found.number };
  }

  if (known?.suppressed) return { filed: false, reason: "suppressed" };
  if (known) {
    const issue = await ctx.github.getIssue(ctx.targetRepo, known.issue);
    if (issue.state === "closed" && issue.labels.includes(SUPPRESS_LABEL)) {
      await ctx.state.put(fpKey, JSON.stringify({ ...known, suppressed: true }));
      return { filed: false, reason: "suppressed" };
    }
    if (issue.state === "open") {
      if (known.lastCommentDay === today) return { filed: false, reason: "already-commented-today" };
      await ctx.github.comment(ctx.targetRepo, known.issue, occurrenceComment(report));
      await ctx.state.put(fpKey, JSON.stringify({ ...known, lastCommentDay: today }));
      return { filed: true, action: "commented", issue: known.issue };
    }
    // Closed as fixed but happening again: a regression gets a fresh issue (below), which
    // links back to the old one.
  }

  const newCapKey = `cap:new:${today}`;
  const newIssues = await counter(ctx.state, newCapKey);
  if (newIssues >= ctx.dailyNewIssueCap) return { filed: false, reason: "global-rate-limit" };
  await ctx.state.put(newCapKey, String(newIssues + 1), { expirationTtl: DAY_TTL });

  const body = known ? `${issueBody(report)}\n\nRegression of #${known.issue}.` : issueBody(report);
  const created = await ctx.github.createIssue(ctx.targetRepo, {
    title: issueTitle(report),
    body,
    labels: [SOURCE_LABEL, packageLabel(report.packageName)],
  });
  await ctx.state.put(fpKey, JSON.stringify({ issue: created.number, lastCommentDay: today } satisfies FingerprintState));
  return { filed: true, action: "created", issue: created.number };
}

function isNewer(extracted: { lastSeen?: string; count?: number }, seen: SeenState): boolean {
  if (extracted.lastSeen && seen.lastSeen) return Date.parse(extracted.lastSeen) > Date.parse(seen.lastSeen);
  if (extracted.count !== undefined && seen.count !== undefined) return extracted.count > seen.count;
  // No ordering signal at all: accept, and let the one-comment-per-day rule bound the effect.
  return true;
}

/** KV counters aren't atomic; concurrent deliveries can overshoot a cap slightly, which is fine. */
async function counter(kv: KVNamespace, key: string): Promise<number> {
  return Number((await kv.get(key)) ?? "0");
}

export function utcDay(ms: number): string {
  return new Date(ms).toISOString().slice(0, 10);
}
