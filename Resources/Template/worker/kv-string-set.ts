/**
 * Shared read-side logic for `reader-identity.ts`'s `contacts:allowlist` and
 * `vouch-trust.ts`'s `vouch:trusted-domains` — both push a bare JSON array of strings to
 * `SOCIAL_KV` under their own key and read it back as a set. Factored out once the two call
 * sites turned out identical, so a future fix to this parsing (validation, size cap, logging
 * on malformed JSON) only has to land once.
 */

/** Minimal KV read surface this module needs. */
export interface StringSetKVEnv {
  readonly SOCIAL_KV?: { get(key: string): Promise<string | null> };
}

/**
 * Parses the bare JSON array of strings stored at `key` in `SOCIAL_KV`. Returns an empty set
 * for a missing binding, missing key, or malformed JSON — never throws, so a KV outage or an
 * unexpected value degrades to "nothing is in the set" rather than crashing the caller.
 */
export async function readStringSetFromKV(env: StringSetKVEnv, key: string): Promise<ReadonlySet<string>> {
  if (!env.SOCIAL_KV) return new Set();
  const raw = await env.SOCIAL_KV.get(key);
  if (raw === null) return new Set();
  try {
    const parsed: unknown = JSON.parse(raw);
    if (!Array.isArray(parsed)) return new Set();
    return new Set(parsed.filter((value): value is string => typeof value === "string"));
  } catch {
    return new Set();
  }
}
