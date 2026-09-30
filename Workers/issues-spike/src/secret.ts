/**
 * Constant-time secret check (design §4): hash both sides so the comparison runs over equal-length
 * digests, then XOR every byte instead of returning at the first mismatch. A portable stand-in for
 * the Workers-only `crypto.subtle.timingSafeEqual`, so plain-Node vitest exercises the same code.
 * An unset secret never matches.
 */
export async function secretMatches(presented: string | null, expected: string | undefined): Promise<boolean> {
  if (!presented || !expected) return false;
  const encoder = new TextEncoder();
  const [a, b] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(presented)),
    crypto.subtle.digest("SHA-256", encoder.encode(expected)),
  ]);
  const left = new Uint8Array(a);
  const right = new Uint8Array(b);
  let difference = 0;
  for (let i = 0; i < left.length; i++) difference |= left[i]! ^ right[i]!;
  return difference === 0;
}
