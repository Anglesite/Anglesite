// Secret handling shared by registration and webhook verification (design §4).

const encoder = new TextEncoder();

export async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(value));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * Constant-time check of a presented secret against a stored SHA-256 hex hash: hash the
 * presented value, then XOR every byte of the equal-length digests rather than stopping at the
 * first mismatch. Portable stand-in for the Workers-only `crypto.subtle.timingSafeEqual`, so the
 * plain-Node test suite exercises the same code. A missing value never matches.
 */
export async function matchesHash(presented: string | null | undefined, storedHash: string | undefined): Promise<boolean> {
  if (!presented || !storedHash) return false;
  const presentedHash = await sha256Hex(presented);
  if (presentedHash.length !== storedHash.length) return false;
  let difference = 0;
  for (let i = 0; i < presentedHash.length; i++) {
    difference |= presentedHash.charCodeAt(i) ^ storedHash.charCodeAt(i);
  }
  return difference === 0;
}

/** Constant-time comparison of two plain secrets (the pre-shared registration token). */
export async function secretsEqual(presented: string | null | undefined, expected: string | undefined): Promise<boolean> {
  if (!expected) return false;
  return matchesHash(presented, await sha256Hex(expected));
}

/** 256-bit random secret, hex-encoded. */
export function newSecret(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function bearer(request: Request): string | null {
  return request.headers.get("authorization")?.match(/^Bearer\s+(.+)$/i)?.[1] ?? null;
}
