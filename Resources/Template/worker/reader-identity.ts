/**
 * Reader identity normalization + allowlist membership (#1568), reading the
 * `contacts:allowlist` key #1567 pushes to `SOCIAL_KV`.
 *
 * @see docs/superpowers/specs/2026-08-18-worker-read-gate-design.md §5
 * @see docs/superpowers/specs/2026-08-18-contacts-allowlist-push-design.md
 */

const ALLOWLIST_KEY = "contacts:allowlist";

/** Minimal KV read surface this module needs (mirrors `worker.ts`'s `InboxKV`). */
export interface ReaderIdentityEnv {
  readonly SOCIAL_KV?: { get(key: string): Promise<string | null> };
}

/**
 * Normalizes an absolute `me` URL to the same scheme-less `host + path` key
 * `Contact.swift`'s `normalizedIdentityKey(for:)` produces — lowercased host,
 * trailing slash trimmed off the path, scheme dropped entirely. Two me-URLs
 * that only differ by `http`/`https` or a trailing slash must compare equal,
 * matching how contacts are deduplicated app-side.
 */
export function normalizeReaderIdentity(me: string): string {
  const url = new URL(me);
  const host = url.hostname.toLowerCase();
  let path = url.pathname;
  if (path.endsWith("/")) path = path.slice(0, -1);
  return host + path;
}

/**
 * Parses the bare JSON array of normalized me-URL strings #1567 pushes to
 * `contacts:allowlist`. Returns an empty set for a missing key or malformed
 * JSON — never throws, so a KV outage or an unexpected value degrades to
 * "nobody is allowed" rather than crashing the request.
 */
async function readAllowlist(env: ReaderIdentityEnv): Promise<ReadonlySet<string>> {
  if (!env.SOCIAL_KV) return new Set();
  const raw = await env.SOCIAL_KV.get(ALLOWLIST_KEY);
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
 * Whether `me` (an absolute, already-canonicalized profile URL) is a known
 * contact per the pushed allowlist. Normalizes `me` the same way the
 * allowlist entries are normalized before comparing.
 */
export async function isAllowedReader(env: ReaderIdentityEnv, me: string): Promise<boolean> {
  const allowlist = await readAllowlist(env);
  return allowlist.has(normalizeReaderIdentity(me));
}
