/**
 * Reader identity normalization + allowlist membership (#1568), reading the
 * `contacts:allowlist` key #1567 pushes to `SOCIAL_KV`.
 *
 * @see docs/superpowers/specs/2026-08-18-worker-read-gate-design.md §5
 * @see docs/superpowers/specs/2026-08-18-contacts-allowlist-push-design.md
 */
import { readStringSetFromKV, type StringSetKVEnv } from "./kv-string-set.ts";

const ALLOWLIST_KEY = "contacts:allowlist";

/** Minimal KV read surface this module needs (mirrors `worker.ts`'s `InboxKV`). */
export type ReaderIdentityEnv = StringSetKVEnv;

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
 * Whether `me` (an absolute, already-canonicalized profile URL) is a known
 * contact per the pushed allowlist. Normalizes `me` the same way the
 * allowlist entries are normalized before comparing.
 */
export async function isAllowedReader(env: ReaderIdentityEnv, me: string): Promise<boolean> {
  const allowlist = await readStringSetFromKV(env, ALLOWLIST_KEY);
  return allowlist.has(normalizeReaderIdentity(me));
}
