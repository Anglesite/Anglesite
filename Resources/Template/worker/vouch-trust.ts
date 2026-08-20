/**
 * Vouch trust-list membership (#1597), reading the `vouch:trusted-domains` key
 * `BlogrollTrustSync` pushes to `SOCIAL_KV` from the site's blogroll.
 *
 * @see docs/superpowers/specs/2026-08-20-vouch-webmention-design.md
 */

const TRUST_LIST_KEY = "vouch:trusted-domains";

/** Minimal KV read surface this module needs (mirrors `reader-identity.ts`'s `ReaderIdentityEnv`). */
export interface VouchTrustEnv {
  readonly SOCIAL_KV?: { get(key: string): Promise<string | null> };
}

/**
 * Parses the bare JSON array of hostname strings `BlogrollTrustSync` pushes to
 * `vouch:trusted-domains`. Returns an empty set for a missing binding, missing key, or
 * malformed JSON — never throws, so a KV outage or an unexpected value degrades to "nothing is
 * trusted yet" rather than crashing the queue consumer.
 */
async function readTrustedDomains(env: VouchTrustEnv): Promise<ReadonlySet<string>> {
  if (!env.SOCIAL_KV) return new Set();
  const raw = await env.SOCIAL_KV.get(TRUST_LIST_KEY);
  if (raw === null) return new Set();
  try {
    const parsed: unknown = JSON.parse(raw);
    if (!Array.isArray(parsed)) return new Set();
    return new Set(parsed.filter((value): value is string => typeof value === "string"));
  } catch {
    return new Set();
  }
}

/**
 * Whether `hostname` (already lowercased by `verifyVouch`) is in the pushed Vouch trust list.
 */
export async function isTrustedVouchDomain(env: VouchTrustEnv, hostname: string): Promise<boolean> {
  const trusted = await readTrustedDomains(env);
  return trusted.has(hostname);
}
