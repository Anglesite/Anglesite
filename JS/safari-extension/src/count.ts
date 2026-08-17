import type { Findings } from "./types";

/**
 * Single source of truth for "how many IndieWeb features did we find on this page" — shared by
 * the background service worker (toolbar badge) and the popup (header count), which must always
 * agree.
 *
 * `findings.mf2.items.length` counts each *top-level* mf2 item once: an h-card is one top-level
 * item, and an h-feed containing 10 h-entries is also just one top-level item (its children
 * aren't separately summed). A page with just an h-card counts as 1; a page with one h-feed of 10
 * entries counts as 1 (the feed), not 11 — a deliberate choice over summing every nested type,
 * which produced noisy/wrong-feeling totals.
 */
export function countFindings(findings: Findings): number {
  return (
    findings.feeds.length +
    findings.relMeLinks.length +
    (findings.webmentionUrl ? 1 : 0) +
    (findings.activityPubUrl ? 1 : 0) +
    findings.mf2.items.length
  );
}

export function badgeTextFor(count: number): string {
  return count > 0 ? String(count) : "";
}
