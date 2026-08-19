/**
 * PKCE, sign-in state token, and reader session cookie for the Worker read gate (#1568).
 *
 * @see docs/superpowers/specs/2026-08-18-worker-read-gate-design.md §4
 */

import { base64url, signPayload, verifyPayload } from "./token-signing.ts";

const SIGNIN_STATE_PURPOSE = "reader-signin-state";
const SIGNIN_STATE_TTL_SECONDS = 600;
const READER_SESSION_PURPOSE = "reader-session";
const READER_SESSION_TTL_SECONDS = 2_592_000; // 30 days

/** The reader session cookie's name. `__Host-` requires exactly `Path=/`, `Secure`, no `Domain`. */
export const READER_SESSION_COOKIE = "__Host-anglesite_reader";

/** A PKCE (RFC 7636) verifier/challenge pair, `S256` method. */
export interface PkcePair {
  readonly verifier: string;
  readonly challenge: string;
}

/** Generates a random `code_verifier` (RFC 7636 §4.1, unreserved-character alphabet) and its `S256` challenge. */
export async function createPkcePair(): Promise<PkcePair> {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  const verifier = base64url(bytes);
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  return { verifier, challenge: base64url(new Uint8Array(digest)) };
}

/** The in-flight sign-in request, round-tripped through the visited site as the OAuth `state`. */
export interface SigninState {
  readonly v: 1;
  readonly exp: number;
  /** Canonicalized, claimed (not yet verified) identity. */
  readonly me: string;
  /** Site-relative path to return the browser to on success. */
  readonly redirectTo: string;
  /** Discovered once at sign-in start; the callback reuses it rather than re-discovering. */
  readonly authorizationEndpoint: string;
  readonly verifier: string;
}

function isSigninState(value: unknown): value is SigninState {
  if (typeof value !== "object" || value === null) return false;
  const state = value as Record<string, unknown>;
  return (
    state.v === 1 &&
    typeof state.exp === "number" &&
    typeof state.me === "string" &&
    typeof state.redirectTo === "string" &&
    typeof state.authorizationEndpoint === "string" &&
    typeof state.verifier === "string"
  );
}

/** Sign a {@link SigninState}, valid for {@link SIGNIN_STATE_TTL_SECONDS}. */
export async function createSigninState(
  fields: Omit<SigninState, "v" | "exp">,
  signingKey: string,
  now = Math.floor(Date.now() / 1000),
): Promise<string> {
  const state: SigninState = { v: 1, exp: now + SIGNIN_STATE_TTL_SECONDS, ...fields };
  return signPayload(new TextEncoder().encode(JSON.stringify(state)), signingKey, SIGNIN_STATE_PURPOSE);
}

/** Verify a sign-in state token, returning its payload or `null` if invalid/expired/tampered. */
export async function verifySigninState(
  token: string,
  signingKey: string,
  now = Math.floor(Date.now() / 1000),
): Promise<SigninState | null> {
  const decoded = await verifyPayload(token, signingKey, SIGNIN_STATE_PURPOSE);
  if (!isSigninState(decoded) || decoded.exp <= now) return null;
  return decoded;
}

/** A signed-in reader's session. `me` is already in `reader-identity.ts`'s normalized form. */
export interface ReaderSession {
  readonly v: 1;
  readonly exp: number;
  readonly me: string;
}

function isReaderSession(value: unknown): value is ReaderSession {
  if (typeof value !== "object" || value === null) return false;
  const session = value as Record<string, unknown>;
  return session.v === 1 && typeof session.exp === "number" && typeof session.me === "string";
}

/** Sign a {@link ReaderSession} token for `me` (already normalized), valid for {@link READER_SESSION_TTL_SECONDS}. */
export async function createReaderSessionToken(
  me: string,
  signingKey: string,
  now = Math.floor(Date.now() / 1000),
): Promise<string> {
  const session: ReaderSession = { v: 1, exp: now + READER_SESSION_TTL_SECONDS, me };
  return signPayload(new TextEncoder().encode(JSON.stringify(session)), signingKey, READER_SESSION_PURPOSE);
}

/** Verify a reader session token, returning its payload or `null` if invalid/expired/tampered. */
export async function verifyReaderSessionToken(
  token: string,
  signingKey: string,
  now = Math.floor(Date.now() / 1000),
): Promise<ReaderSession | null> {
  const decoded = await verifyPayload(token, signingKey, READER_SESSION_PURPOSE);
  if (!isReaderSession(decoded) || decoded.exp <= now) return null;
  return decoded;
}

/** Build the `Set-Cookie` header value that starts a reader session. */
export function readerSessionSetCookie(token: string): string {
  return `${READER_SESSION_COOKIE}=${token}; Path=/; Max-Age=${READER_SESSION_TTL_SECONDS}; Secure; HttpOnly; SameSite=Lax`;
}

/** Build the `Set-Cookie` header value that clears a reader session (used nowhere yet, kept for symmetry with future sign-out). */
export function readerSessionClearCookie(): string {
  return `${READER_SESSION_COOKIE}=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Lax`;
}

/** Extract the reader session cookie's raw token value from a request's `Cookie` header, if present. */
export function readReaderSessionCookie(request: Request): string | null {
  const header = request.headers.get("Cookie");
  if (!header) return null;
  for (const part of header.split(";")) {
    const separator = part.indexOf("=");
    if (separator === -1) continue;
    const name = part.slice(0, separator).trim();
    if (name === READER_SESSION_COOKIE) return part.slice(separator + 1).trim();
  }
  return null;
}
