/**
 * Vouch trust-list membership (#1597), reading the `vouch:trusted-domains` key
 * `BlogrollTrustSync` pushes to `SOCIAL_KV` from the site's blogroll.
 *
 * @see docs/superpowers/specs/2026-08-20-vouch-webmention-design.md
 */
import { readStringSetFromKV, type StringSetKVEnv } from "./kv-string-set.ts";

const TRUST_LIST_KEY = "vouch:trusted-domains";

/** Minimal KV read surface this module needs. */
export type VouchTrustEnv = StringSetKVEnv;

/**
 * Whether `hostname` (already lowercased by `verifyVouch`) is in the pushed Vouch trust list.
 */
export async function isTrustedVouchDomain(env: VouchTrustEnv, hostname: string): Promise<boolean> {
  const trusted = await readStringSetFromKV(env, TRUST_LIST_KEY);
  return trusted.has(hostname);
}
