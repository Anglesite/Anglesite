// Domain-control proof for relay registration (#2095 slice 5, design §4 ▸ "Registration and
// webhook authentication"). It replaces the pre-shared registration token for owners outside the
// first `*.dwk.io` rollout.
//
// The app keeps a random per-site proof key in the owner's keychain. The site's Worker serves
// sha256("anglesite-issues-proof:<siteID>:<key>") at PROOF_PATH. Registration presents the key,
// and the relay fetches the hash from the claimed hostname over HTTPS. Only whoever controls
// both the site and the key can produce a matching pair. The served value is a one-way hash that
// is useless on its own, and it binds the site UUID, so it can't be replayed for another site.

import { sha256Hex } from "./auth.js";

export const PROOF_PATH = "/.well-known/anglesite-issues-proof";
export const PROOF_KEY = /^[0-9a-f]{64}$/;
/** The proof is one 64-character hex line; anything bigger isn't one. */
const MAX_PROOF_BYTES = 1024;
const FETCH_TIMEOUT_MS = 5000;

export type ProofResult = "ok" | "mismatch" | "unreachable";

export function proofValue(siteID: string, key: string): Promise<string> {
  return sha256Hex(`anglesite-issues-proof:${siteID}:${key}`);
}

/**
 * A hostname the relay is willing to fetch: a public DNS name, never an IP literal, `localhost`
 * or a single-label name. This is SSRF hygiene. Workers can't reach private networks anyway, but
 * nothing here should become an open fetch proxy.
 */
export function fetchableHostname(hostname: string): boolean {
  if (!/^[a-z0-9.-]{1,253}$/.test(hostname)) return false;
  const labels = hostname.split(".");
  if (labels.length < 2 || labels.some((l) => l.length === 0 || l.length > 63 || l.startsWith("-") || l.endsWith("-"))) {
    return false;
  }
  // A numeric last label means an IPv4 literal (or no real TLD), never a DNS name.
  if (/^[0-9]+$/.test(labels[labels.length - 1]!)) return false;
  return hostname !== "localhost" && !hostname.endsWith(".localhost");
}

/**
 * Fetches `https://<hostname>/.well-known/anglesite-issues-proof` and compares it with the
 * expected hash in constant time. The request follows no redirects (a redirect could point
 * anywhere), times out after 5 s, and reads at most 1 KiB.
 */
export async function verifyDomainProof(
  hostname: string,
  siteID: string,
  key: string,
  fetchImpl: typeof fetch = fetch,
): Promise<ProofResult> {
  if (!fetchableHostname(hostname) || !PROOF_KEY.test(key)) return "mismatch";
  let response: Response;
  try {
    response = await fetchImpl(`https://${hostname}${PROOF_PATH}`, {
      redirect: "manual",
      headers: { accept: "text/plain" },
      signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    });
  } catch {
    return "unreachable";
  }
  if (response.status !== 200) return response.status >= 500 ? "unreachable" : "mismatch";
  if (Number(response.headers.get("content-length") ?? "0") > MAX_PROOF_BYTES) return "mismatch";
  const served = (await response.text()).slice(0, MAX_PROOF_BYTES).trim().toLowerCase();
  const expected = await proofValue(siteID, key);
  if (served.length !== expected.length) return "mismatch";
  let difference = 0;
  for (let i = 0; i < expected.length; i++) difference |= served.charCodeAt(i) ^ expected.charCodeAt(i);
  return difference === 0 ? "ok" : "mismatch";
}
