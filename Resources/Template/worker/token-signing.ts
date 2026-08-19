/**
 * Shared HMAC token-signing primitives for this Worker's hand-rolled, self-contained
 * `base64url(payload).base64url(signature)` tokens (consent grants, reader sign-in state,
 * reader sessions) — extracted from `worker.ts` (which originated `ConsentGrant`/
 * `SolidOidcConsentGrant`'s identical shape) so new token kinds don't duplicate this
 * security-sensitive encode/sign/verify code.
 */

export function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function decodeBase64url(value: string): Uint8Array<ArrayBuffer> | null {
  try {
    const padded = value.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(value.length / 4) * 4, "=");
    const binary = atob(padded);
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1) {
      bytes[index] = binary.charCodeAt(index);
    }
    return bytes;
  } catch {
    return null;
  }
}

/**
 * Derives a purpose-specific HMAC key from `secret` via HKDF, so that `TOKEN_SIGNING_KEY` — the
 * one secret provisioned for consent-token signing, owner-password comparison, and (as of #1568)
 * reader sign-in/session tokens — yields independent subkeys per purpose. A weakness or misuse in
 * one purpose's key can't cross over into another's.
 */
export async function deriveKey(secret: string, purpose: string): Promise<CryptoKey> {
  const baseKey = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    "HKDF",
    false,
    ["deriveKey"],
  );
  return crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt: new Uint8Array(0), info: new TextEncoder().encode(purpose) },
    baseKey,
    { name: "HMAC", hash: "SHA-256", length: 256 },
    false,
    ["sign", "verify"],
  );
}

/** Sign `payload` (already-serialized JSON bytes) with the purpose-derived key. */
export async function signPayload(payload: Uint8Array<ArrayBuffer>, signingKey: string, purpose: string): Promise<string> {
  const signature = await crypto.subtle.sign("HMAC", await deriveKey(signingKey, purpose), payload);
  return `${base64url(payload)}.${base64url(new Uint8Array(signature))}`;
}

/**
 * Verify a `signPayload` token and return its decoded JSON payload, or `null` when the token is
 * malformed, oversized, or its signature doesn't verify. Callers still owe their own shape/expiry
 * checks on the returned value — this only proves the bytes are what `signPayload` produced.
 */
export async function verifyPayload(
  token: string,
  signingKey: string,
  purpose: string,
  maxLength = 8_192,
): Promise<unknown> {
  if (token.length > maxLength) return null;
  const [payloadPart, signaturePart, extra] = token.split(".");
  if (!payloadPart || !signaturePart || extra !== undefined) return null;
  const payload = decodeBase64url(payloadPart);
  const signature = decodeBase64url(signaturePart);
  if (!payload || !signature) return null;
  if (!(await crypto.subtle.verify("HMAC", await deriveKey(signingKey, purpose), signature, payload))) return null;
  try {
    return JSON.parse(new TextDecoder().decode(payload));
  } catch {
    return null;
  }
}
