import {
  createIndieAuth,
  type AuthorizationRequest,
  type IndieAuthEnv,
} from "@dwk/indieauth";
import {
  createWebmention,
  createWebmentionQueueConsumer,
  createD1Inbox,
  type WebmentionEnv,
  type WebmentionJob,
} from "@dwk/webmention";
import {
  createMicropub,
  type MicropubEnv,
} from "@dwk/micropub";
import { discoverCollection, generateSlug } from "./post-type-discovery.ts";
import {
  createActivityPub,
  ActivityPubObject,
  type ActivityPubConfig,
  type ActivityPubEnv,
} from "@dwk/activitypub";
import {
  createWebSub,
  createWebSubQueueConsumer,
  type WebSubConfig,
  type WebSubEnv,
  type WebSubJob,
} from "@dwk/websub";
import {
  createMicrosub,
  createMicrosubPoller,
  createMicrosubQueueConsumer,
  type MicrosubEnv,
  type MicrosubJob,
} from "@dwk/microsub";
import { createWebfinger } from "@dwk/webfinger";
import {
  createSolidOidc,
  type SolidOidcConfig,
  type SolidOidcEnv,
  type SolidOidcAuthorizationRequest,
  type Jwk,
} from "@dwk/solid-oidc";
import {
  createSolidPod,
  createSolidPodGc,
  createSolidPodWebdav,
  createSolidPodWebdavCredentials,
  SolidPodObject,
  type SolidPodConfig,
  type SolidPodEnv,
  type SolidPodGcEnv,
} from "@dwk/solid-pod";
import {
  handleExperimentPageRequest,
  applyGoalConversion,
  handleGoalBeaconRequest,
  matchesGoal,
  type ExperimentsArtifact,
} from "./experiments.ts";
import experimentsArtifact from "./experiments.json";
import utmCodesArtifact from "../utm-codes.json";
import { tagFediverseUrl } from "./utm-codes.ts";
import { GOAL_ENDPOINT_PATH } from "../scripts/experiments-paths.ts";
import { base64url, decodeBase64url, deriveKey } from "./token-signing.ts";
import {
  escapeHTML,
  extractMf2ContentString,
  extractMf2Photos,
  extractMf2StringList,
  type ExtractedPhoto,
} from "./render-utils.ts";
import { handleReaderCallback, handleReaderSignin } from "./reader-auth.ts";
import { handleGatedFallback, handlePrivateFeed } from "./gated-content.ts";
import { handleMcp } from "./mcp-server.ts";
import { isTrustedVouchDomain } from "./vouch-trust.ts";
import { EmailMessage } from "cloudflare:email";

/**
 * Per-site Cloudflare Worker entry point.
 *
 * Composes @dwk/* social endpoints (IndieAuth, inbound Webmention, Micropub) behind the site's
 * static assets, plus a runtime inbox-capture
 * endpoint (#587) that does NOT depend on any @dwk/* package — Webmention's link-verification
 * shape and Micropub's IndieAuth-gated shape don't fit a public "visitor sends us a message"
 * form, so this route is bespoke. It stages submissions into the `INBOX_KV` namespace for the
 * app to pull and commit into the site's git working copy the next time it opens
 * (Sources/AnglesiteCore/InboxSubmissionSync.swift).
 *
 * Static assets are served by the [assets] binding in wrangler.toml; this Worker handles the
 * social + inbox endpoint paths, a running A/B experiment's routes, and (#1576) the read-only
 * MCP server. When none of those are enabled, this file is not referenced (wrangler.toml has no
 * `main` entry and deploys static-only).
 *
 * Routing (#746): `ROUTES` below is a declarative table mirroring the generic HTTP route claims
 * the app's Worker catalog declares for the active workers; Anglesite generates matching
 * selective `[assets].run_worker_first` entries so only these routes bypass asset-first serving.
 * The dispatcher is generic: exact/prefix matching, `405` + `Allow` for undeclared methods, HEAD
 * mirroring GET where declared, queries passed through untouched, and a true (plain-text) 404 —
 * never an HTML page — for unclaimed `/.well-known/` names, the bare directory, malformed
 * encodings, and case/trailing-slash variants (RFC 8615: the namespace has no index and no
 * fallback representation). Every other unmatched path falls through to static assets.
 */

/** Minimal Workers KV surface shared by inbox capture and consent throttling. */
export interface InboxKV {
  get(key: string): Promise<string | null>;
  put(key: string, value: string, options?: { expirationTtl?: number }): Promise<void>;
}

export interface WorkerEnv extends IndieAuthEnv {
  ASSETS?: Fetcher;
  INBOX_KV?: InboxKV;
  SOCIAL_KV?: InboxKV;
  /**
   * Owner-email forwarding for `/inbox` submissions (#1570, reconciling #587 with the
   * email-as-DM decision) — additive to the `INBOX_KV` capture above, which stays the
   * structured record. Both optional: a site whose owner hasn't run email setup
   * (`EmailSetupPlanner`/`EmailSetupExecutor`) has neither bound, and `handleInbox` degrades to
   * KV-only capture rather than throwing. `SEND_EMAIL`'s `destination_address` (see
   * `WorkerComposition.generateWranglerToml`, Swift) restricts the binding to `INBOX_FORWARD_EMAIL`
   * specifically — the Worker can't be made to send anywhere else even if this env were
   * otherwise compromised.
   */
  SEND_EMAIL?: SendEmail;
  INBOX_FORWARD_EMAIL?: string;
  INDIEAUTH_OWNER_PASSWORD: string;
  /**
   * Inbound-Webmention bindings (V-3.1, #359). All optional: a site that hasn't provisioned
   * inbound Webmention has none of them bound, and the `/webmention` route + `queue` consumer
   * degrade gracefully (503 / ack-without-work) rather than throwing. Provisioning wires them —
   * a Cloudflare Queue for async verification, a D1 database for the verified-mention inbox, and
   * the site's canonical origin (the `queue` consumer has no request to derive it from).
   * See `WorkerComposition.generateWranglerToml` (Swift) for the binding generation.
   */
  WEBMENTION_QUEUE?: Queue<WebmentionJob>;
  WEBMENTION_INBOX?: D1Database;
  SITE_URL?: string;
  /**
   * Micropub bindings (V-3.2, #360). Both optional: a site that hasn't provisioned Micropub has
   * neither bound, and `/micropub`/`/media` degrade gracefully (503) rather than throwing.
   * `AUTH_DB`/`TOKEN_SIGNING_KEY` are already required by `IndieAuthEnv` above — Micropub's
   * catalog entry `requires: ["indieauth"]` (resolved by `WorkerActivation`) guarantees both are
   * provisioned together, so this handler still explicitly checks all four before dispatching,
   * matching `handleWebmentionReceive`'s defense-in-depth pattern rather than trusting reachability
   * alone. See `WorkerComposition.generateWranglerToml` (Swift) for the binding generation.
   */
  MICROPUB_DB?: D1Database;
  MEDIA?: R2Bucket;
  /**
   * ActivityPub actor bindings (V-4.1, #363). All optional: a site that hasn't provisioned
   * ActivityPub has none of them bound, and every actor route degrades to 503 rather than
   * letting @dwk/activitypub throw its own loud startup error. `ACTOR` is the per-actor Durable
   * Object namespace the package ships (`ActivityPubObject`, re-exported below so wrangler can
   * bind it). `AP_PRIVATE_KEY`/`AP_PUBLIC_KEY` are the actor's signing keypair (PKCS#8/SPKI PEM,
   * app-generated — see `ActivityPubKeyProvisioning.swift`). `AP_PUBLISH_TOKEN` gates the
   * owner-only publish endpoint the Micropub fan-out below calls internally.
   * `AP_DISPLAY_NAME` is the actor's `Person.name`, threaded from `SiteSettings.displayName`;
   * falls back to a generic name when unset. `AP_ACTOR_TYPE` selects the AS2 actor type
   * (V-5.1b, #907): `"Group"` hosts a community (member posts wrapped in `Announce` and fanned
   * out, moderation activities honored from `AP_MODERATORS`); anything else — including unset —
   * is an ordinary `Person`. `AP_MODERATORS` is a comma-joined list of moderator actor IRIs
   * (`SiteSettings.moderators`), ignored for a `Person` actor; comma-joined because Wrangler vars
   * have no native list type — a moderator IRI containing a literal comma is excluded entirely on
   * the Swift side (`WorkerComposition.generateWranglerToml`) rather than corrupting the join.
   * `AP_USERNAME` overrides the WebFinger-visible handle (#1239, design doc
   * `2026-08-04-fediverse-handle-design.md`) — see `resolvePreferredUsername` below; it never
   * changes the actor **IRI**, which stays `ACTIVITYPUB_USERNAME` (`/users/site`) permanently.
   * `AP_ICON` is the actor's avatar (#1771) — an absolute `http(s)` URL or a root-relative path
   * resolved against the serving origin at request time (`resolveApIcon` below), surfaced as
   * the actor document's `icon`; the app defaults it to the site's `apple-touch-icon.png`.
   * Unset (or unusable) means no `icon`, and every platform shows its placeholder avatar.
   * See `WorkerComposition.generateWranglerToml` (Swift) for the binding generation.
   */
  ACTOR?: DurableObjectNamespace<ActivityPubObject>;
  AP_PRIVATE_KEY?: string;
  AP_PUBLIC_KEY?: string;
  AP_PUBLISH_TOKEN?: string;
  AP_DISPLAY_NAME?: string;
  AP_ACTOR_TYPE?: string;
  AP_MODERATORS?: string;
  AP_USERNAME?: string;
  AP_ICON?: string;
  /**
   * Solid-OIDC signing key (V-storage, identity layer for `@dwk/solid-pod`). Optional: a site
   * that hasn't provisioned Solid-OIDC has none of it bound, and every `/oidc/*` route degrades
   * to 503 rather than letting `@dwk/solid-oidc` throw its own loud startup error. A JSON-
   * serialized private EC P-256 JWK (RFC 7518 §6.2.2) — see
   * `SolidOidcKeyProvisioning.signingKeyJWK` (Swift) for generation, and
   * `WorkerComposition.generateWranglerToml` for the binding.
   */
  OIDC_SIGNING_KEY?: string;
  /**
   * Solid Pod bindings (V-storage). All optional: a site that hasn't provisioned solid-pod has
   * none of them bound, and every `/pod`/`/dav`/`/dav-credentials` route degrades to 503 rather
   * than letting `@dwk/solid-pod` throw its own loud startup error. `POD` is the per-pod Durable
   * Object namespace the package ships (`SolidPodObject`, re-exported below so wrangler can bind
   * it); `BLOBS` is its R2 bucket for oversized/binary bodies. See
   * `WorkerComposition.generateWranglerToml` (Swift) for the binding generation.
   */
  POD?: DurableObjectNamespace<SolidPodObject>;
  BLOBS?: R2Bucket;
  /**
   * `@dwk/webdav`'s app-password hashing pepper. Optional: a site with solid-pod active but not
   * webdav has this unbound, and `/dav`/`/dav-credentials` degrade to 503.
   */
  WEBDAV_PEPPER?: string;
  /**
   * D1 database tracking orphaned R2 blob keys for solid-pod's out-of-band garbage-collection
   * cron (`@dwk/solid-pod`'s `SolidPodGcEnv.GC_DB`). That package's own `createSolidPodGc`
   * handler declares this binding *required*, not optional, and throws the moment it runs
   * without it — but `WorkerComposition.generateWranglerToml` (Swift) does not currently
   * provision a GC_DB binding for solid-pod (only `POD`/`BLOBS`/`WEBDAV_PEPPER` are wired today).
   * Kept optional here so `handleSolidPodGcScheduled` below can guard on its absence and no-op
   * on every five-minute GC cron tick until that provisioning gap is closed, instead of throwing
   * an unhandled exception in every site with solid-pod active.
   */
  GC_DB?: D1Database;
  /**
   * WebSub hub bindings (V-3.3, #361). Optional like the Webmention set above: a site that
   * hasn't provisioned the hub has none of them bound, and the `/websub` route + queue
   * consumer degrade gracefully (503 / ack-without-work). Provisioning wires a D1 database
   * for the strongly-consistent subscription store and a dedicated Cloudflare Queue for
   * intent verification + per-subscriber delivery fan-out. `WEBSUB_CONTENT` (R2 staging for
   * snapshots too large to inline in a queue message) is deliberately not provisioned yet —
   * a feed that outgrows the ~64 KB inline limit fails the fan-out loudly rather than
   * truncating, and wiring the staging bucket (with its lifecycle expiration rule) is the
   * documented follow-up.
   */
  WEBSUB_DB?: D1Database;
  WEBSUB_QUEUE?: Queue<WebSubJob>;
  /**
   * Microsub reader bindings (V-4.3, #365). Both optional: a site that hasn't provisioned
   * Microsub has neither bound, and `/microsub` plus its scheduled poller/queue consumer degrade
   * gracefully (503 / no-op) rather than throwing. `AUTH_DB`/`TOKEN_SIGNING_KEY` are already
   * required by `IndieAuthEnv` above — Microsub's catalog entry `requires: ["indieauth"]`
   * (resolved by `WorkerActivation`) guarantees both are provisioned together, so this handler
   * still explicitly checks all four before dispatching, matching `handleMicropub`'s
   * defense-in-depth pattern rather than trusting reachability alone. See
   * `WorkerComposition.generateWranglerToml` (Swift) for the binding generation.
   */
  MICROSUB_DB?: D1Database;
  MICROSUB_QUEUE?: Queue<MicrosubJob>;
  /**
   * Edge A/B testing event counters (#1270 slice 1). Optional: an experiment can be configured
   * and served without this binding provisioned (assignment/serving still works), but impressions
   * and conversions silently don't count until it's bound — see `incrementExperimentCounter` in
   * `./experiments.ts`. Provisioning this alongside the other social D1 bindings is slice 3.
   */
  EXPERIMENTS_DB?: D1Database;
}

export { ActivityPubObject };
export { SolidPodObject };

const RATE_LIMIT_WINDOW_SECONDS = 3600;
const RATE_LIMIT_MAX_PER_WINDOW = 5;
const MAX_SUBJECT_LENGTH = 200;
const MAX_FROM_LENGTH = 200;
const MAX_MESSAGE_LENGTH = 10_000;
const MAX_CONSENT_BODY_BYTES = 16_384;
const CONSENT_TTL_SECONDS = 300;
const CONSENT_VERSION = 1;

interface ConsentGrant {
  v: 1;
  exp: number;
  clientId: string;
  redirectUri: string;
  state: string;
  codeChallenge: string;
  scope: string;
  resources: string[];
}

function grantFor(request: AuthorizationRequest, expiresAt: number): ConsentGrant {
  return {
    v: CONSENT_VERSION,
    exp: expiresAt,
    clientId: request.clientId,
    redirectUri: request.redirectUri,
    state: request.state,
    codeChallenge: request.codeChallenge,
    scope: request.scope,
    resources: [...(request.resources ?? [])],
  };
}

function isConsentGrant(value: unknown): value is ConsentGrant {
  if (typeof value !== "object" || value === null) return false;
  const grant = value as Record<string, unknown>;
  return grant.v === CONSENT_VERSION
    && typeof grant.exp === "number"
    && typeof grant.clientId === "string"
    && typeof grant.redirectUri === "string"
    && typeof grant.state === "string"
    && typeof grant.codeChallenge === "string"
    && typeof grant.scope === "string"
    && Array.isArray(grant.resources)
    && grant.resources.every((resource) => typeof resource === "string");
}

export async function createConsentToken(
  request: AuthorizationRequest,
  signingKey: string,
  now = Math.floor(Date.now() / 1000),
): Promise<string> {
  const payload = new TextEncoder().encode(JSON.stringify(grantFor(request, now + CONSENT_TTL_SECONDS)));
  const signature = await crypto.subtle.sign("HMAC", await deriveKey(signingKey, "consent-token"), payload);
  return `${base64url(payload)}.${base64url(new Uint8Array(signature))}`;
}

export async function verifyConsentToken(
  token: string,
  request: AuthorizationRequest,
  signingKey: string,
  now = Math.floor(Date.now() / 1000),
): Promise<boolean> {
  if (token.length > 8_192) return false;
  const [payloadPart, signaturePart, extra] = token.split(".");
  if (!payloadPart || !signaturePart || extra !== undefined) return false;
  const payload = decodeBase64url(payloadPart);
  const signature = decodeBase64url(signaturePart);
  if (!payload || !signature) return false;
  if (!(await crypto.subtle.verify("HMAC", await deriveKey(signingKey, "consent-token"), signature, payload))) return false;

  let decoded: unknown;
  try {
    decoded = JSON.parse(new TextDecoder().decode(payload));
  } catch {
    return false;
  }
  if (!isConsentGrant(decoded) || decoded.exp <= now) return false;
  const expected = grantFor(request, decoded.exp);
  return JSON.stringify(decoded) === JSON.stringify(expected);
}

/**
 * Mirrors `ConsentGrant` above: binds the approved `webid` to the *entire* authorization request
 * (client, redirect target, PKCE challenge, scope, state, nonce), not just the webid. Without
 * this, a consent token minted for one `client_id`/`redirect_uri` could be replayed against a
 * different `client_id`/`redirect_uri` in the live query string — the pod owner only ever sees
 * and approves one authorization request, so the token must not be honorable for any other.
 */
interface SolidOidcConsentGrant {
  v: 1;
  exp: number;
  webid: string;
  clientId: string;
  redirectUri: string;
  scope: string;
  codeChallenge: string;
  state: string;
  nonce: string;
}

function isSolidOidcConsentGrant(value: unknown): value is SolidOidcConsentGrant {
  if (typeof value !== "object" || value === null) return false;
  const grant = value as Record<string, unknown>;
  return grant.v === 1
    && typeof grant.exp === "number"
    && typeof grant.webid === "string"
    && typeof grant.clientId === "string"
    && typeof grant.redirectUri === "string"
    && typeof grant.scope === "string"
    && typeof grant.codeChallenge === "string"
    && typeof grant.state === "string"
    && typeof grant.nonce === "string";
}

function solidOidcGrantFor(
  request: SolidOidcAuthorizationRequest,
  webid: string,
  expiresAt: number,
): SolidOidcConsentGrant {
  return {
    v: 1,
    exp: expiresAt,
    webid,
    clientId: request.clientId,
    redirectUri: request.redirectUri,
    scope: request.scope,
    codeChallenge: request.codeChallenge,
    state: request.state ?? "",
    nonce: request.nonce ?? "",
  };
}

/**
 * Signs a short-lived proof that the site owner approved a specific Solid-OIDC authorization
 * request (client, redirect target, PKCE challenge, scope, state, nonce) as `webid` — the same
 * "owner password gates this" bridge `@dwk/indieauth`'s consent flow uses (`createConsentToken`
 * above), adapted for Solid-OIDC's own (differently-shaped) `approveAuthorization` hook. Reuses
 * this file's `deriveKey`/HKDF pattern with its own purpose string so the two consent tokens'
 * derived keys are independent even though both start from `TOKEN_SIGNING_KEY`.
 */
export async function createSolidOidcConsentToken(
  request: SolidOidcAuthorizationRequest,
  webid: string,
  signingKey: string,
  now = Math.floor(Date.now() / 1000),
): Promise<string> {
  const payload = new TextEncoder().encode(
    JSON.stringify(solidOidcGrantFor(request, webid, now + CONSENT_TTL_SECONDS)),
  );
  const signature = await crypto.subtle.sign("HMAC", await deriveKey(signingKey, "solid-oidc-consent-token"), payload);
  return `${base64url(payload)}.${base64url(new Uint8Array(signature))}`;
}

/**
 * Verifies a token from `createSolidOidcConsentToken` against the *current* `request`, returning
 * the full verified grant (never just the webid) — mirroring `verifyConsentToken`'s whole-grant
 * comparison above. Returns `null` when the signature doesn't verify, the token is expired, or
 * any field of the live `request` (client, redirect, scope, PKCE challenge, state, nonce) doesn't
 * match what was actually approved, so a token can't be replayed against a different request.
 */
export async function verifySolidOidcConsentToken(
  token: string,
  request: SolidOidcAuthorizationRequest,
  signingKey: string,
  now = Math.floor(Date.now() / 1000),
): Promise<SolidOidcConsentGrant | null> {
  if (token.length > 8_192) return null;
  const [payloadSegment, signatureSegment, extra] = token.split(".");
  if (!payloadSegment || !signatureSegment || extra !== undefined) return null;
  const payloadBytes = decodeBase64url(payloadSegment);
  const signatureBytes = decodeBase64url(signatureSegment);
  if (!payloadBytes || !signatureBytes) return null;
  const valid = await crypto.subtle.verify(
    "HMAC",
    await deriveKey(signingKey, "solid-oidc-consent-token"),
    signatureBytes,
    payloadBytes,
  );
  if (!valid) return null;
  let parsed: unknown;
  try {
    parsed = JSON.parse(new TextDecoder().decode(payloadBytes));
  } catch {
    return null;
  }
  if (!isSolidOidcConsentGrant(parsed) || parsed.exp <= now) return null;
  const expected = solidOidcGrantFor(request, parsed.webid, parsed.exp);
  return JSON.stringify(parsed) === JSON.stringify(expected) ? parsed : null;
}

async function secretsMatch(provided: string, expected: string, comparisonSecret: string): Promise<boolean> {
  const key = await deriveKey(comparisonSecret, "owner-password-compare");
  const encoder = new TextEncoder();
  const expectedMAC = await crypto.subtle.sign("HMAC", key, encoder.encode(expected));
  // Keep both passwords as message data under one server-controlled key and delegate the MAC
  // comparison to WebCrypto instead of comparing attacker-influenced bytes in JavaScript.
  return crypto.subtle.verify("HMAC", key, expectedMAC, encoder.encode(provided));
}

function consentPage(request: AuthorizationRequest): Response {
  const hidden = [
    ["client_id", request.clientId],
    ["redirect_uri", request.redirectUri],
    ["state", request.state],
    ["response_type", "code"],
    ["code_challenge", request.codeChallenge],
    ["code_challenge_method", request.codeChallengeMethod],
    ["scope", request.scope],
    ...(request.me ? [["me", request.me]] : []),
    ...(request.resources ?? []).map((resource) => ["resource", resource]),
  ].map(([name, value]) => `<input type="hidden" name="${escapeHTML(name)}" value="${escapeHTML(value)}">`).join("\n");
  const scopes = request.scopes.length > 0 ? request.scopes.map(escapeHTML).join(", ") : "identity only";
  const body = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Approve sign-in</title></head><body><main>
<h1>Approve sign-in</h1>
<p><strong>${escapeHTML(request.clientId)}</strong> wants to sign in as this site.</p>
<p>Requested access: ${scopes}</p>
<form method="post" action="/indieauth/consent">
${hidden}
<label>Site owner password <input name="password" type="password" required autocomplete="current-password" maxlength="512"></label>
<button type="submit">Approve</button>
</form></main></body></html>`;
  return new Response(body, {
    status: 200,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
      "referrer-policy": "no-referrer",
      "x-content-type-options": "nosniff",
    },
  });
}

async function readBoundedForm(request: Request): Promise<URLSearchParams | null> {
  if (!(request.headers.get("content-type") ?? "").includes("application/x-www-form-urlencoded")) return null;
  if (!request.body) return new URLSearchParams();
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > MAX_CONSENT_BODY_BYTES) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  const body = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new URLSearchParams(new TextDecoder().decode(body));
}

async function consentRateLimitKey(request: Request): Promise<string> {
  const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(ip));
  return `indieauth-login:${base64url(new Uint8Array(digest)).slice(0, 32)}`;
}

async function isConsentRateLimited(request: Request, env: WorkerEnv): Promise<boolean> {
  if (!env.SOCIAL_KV) {
    // Fail closed: an unbound KV must never silently disable the limiter.
    console.warn(JSON.stringify({ event: "indieauth.consent_rate_limit_unavailable" }));
    return true;
  }
  const key = await consentRateLimitKey(request);
  const raw = await env.SOCIAL_KV.get(key);
  const count = raw ? Number.parseInt(raw, 10) : 0;
  if (count >= RATE_LIMIT_MAX_PER_WINDOW) return true;
  await env.SOCIAL_KV.put(key, String(count + 1), { expirationTtl: RATE_LIMIT_WINDOW_SECONDS });
  return false;
}

export async function handleIndieAuthConsent(request: Request, env: WorkerEnv): Promise<Response> {
  if (request.method !== "POST") return new Response("Method Not Allowed", { status: 405, headers: { allow: "POST" } });
  if (!env.INDIEAUTH_OWNER_PASSWORD || !env.TOKEN_SIGNING_KEY || !env.SOCIAL_KV) {
    return new Response("IndieAuth secrets are not configured", { status: 503 });
  }
  if (await isConsentRateLimited(request, env)) return new Response("Too Many Requests", { status: 429 });
  const form = await readBoundedForm(request);
  if (!form) return new Response("Invalid consent form", { status: 400 });
  if (!(await secretsMatch(
    form.get("password") ?? "",
    env.INDIEAUTH_OWNER_PASSWORD,
    env.TOKEN_SIGNING_KEY,
  ))) {
    console.warn(JSON.stringify({ event: "indieauth.consent_rejected", reason: "password_invalid" }));
    return new Response("Invalid site owner password", { status: 401 });
  }

  const origin = new URL(request.url).origin;
  const authorize = new URL("/authorize", origin);
  for (const name of ["client_id", "redirect_uri", "state", "response_type", "code_challenge", "code_challenge_method", "scope", "me"]) {
    const value = form.get(name);
    if (value !== null) authorize.searchParams.set(name, value);
  }
  for (const resource of form.getAll("resource")) authorize.searchParams.append("resource", resource);
  const grant: AuthorizationRequest = {
    clientId: form.get("client_id") ?? "",
    redirectUri: form.get("redirect_uri") ?? "",
    state: form.get("state") ?? "",
    codeChallenge: form.get("code_challenge") ?? "",
    codeChallengeMethod: form.get("code_challenge_method") ?? "",
    scope: form.get("scope") ?? "",
    scopes: (form.get("scope") ?? "").split(/\s+/).filter(Boolean),
    ...(form.get("me") ? { me: form.get("me") as string } : {}),
    ...(form.getAll("resource").length > 0 ? { resources: form.getAll("resource") } : {}),
  };
  authorize.searchParams.set("consent", await createConsentToken(grant, env.TOKEN_SIGNING_KEY));
  return Response.redirect(authorize.toString(), 303);
}

/**
 * The Anglesite app's IndieAuth callback bridge (#868). `ASWebAuthenticationSession` can only
 * capture a custom-scheme (or Associated-Domains https) redirect, while `@dwk/indieauth` only
 * accepts an https (or http-loopback) `redirect_uri` that shares the client_id's origin — so the
 * app signs in with `redirect_uri` pointing here, and this route immediately re-issues the
 * redirect into the app's custom scheme. The query string passes through byte-for-byte: the app
 * re-validates `state` and redeems `code` itself (PKCE makes an intercepted code useless without
 * the app's verifier, per RFC 8252 §8.1), and re-encoding could corrupt a percent-encoded code.
 */
export function handleIndieAuthAppCallback(request: Request): Response {
  const { search } = new URL(request.url);
  return new Response(null, {
    status: 302,
    headers: {
      location: `io.dwk.anglesite://indieauth-callback${search}`,
      // The query carries a one-time authorization code — never cacheable anywhere.
      "cache-control": "no-store",
    },
  });
}

/**
 * Solid-OIDC's login/consent bridge — reuses the exact same owner-password check
 * `handleIndieAuthConsent` gates on (`secretsMatch` against `INDIEAUTH_OWNER_PASSWORD`), so the
 * pod's owner authenticates with the same one credential IndieAuth already uses. On success,
 * redirects back to `/oidc/authorize` with a signed consent token `approveAuthorization` (below)
 * verifies — mirroring `handleIndieAuthConsent`'s redirect-with-a-signed-token shape, adapted for
 * Solid-OIDC's simpler (webid-only) grant.
 */
export async function handleSolidOidcConsent(request: Request, env: WorkerEnv): Promise<Response> {
  if (request.method !== "POST") return new Response("Method Not Allowed", { status: 405, headers: { allow: "POST" } });
  if (!env.INDIEAUTH_OWNER_PASSWORD || !env.TOKEN_SIGNING_KEY || !env.SOCIAL_KV) {
    return new Response("Solid-OIDC secrets are not configured", { status: 503 });
  }
  if (await isConsentRateLimited(request, env)) return new Response("Too Many Requests", { status: 429 });
  const form = await readBoundedForm(request);
  if (!form) return new Response("Invalid consent form", { status: 400 });
  if (!(await secretsMatch(form.get("password") ?? "", env.INDIEAUTH_OWNER_PASSWORD, env.TOKEN_SIGNING_KEY))) {
    console.warn(JSON.stringify({ event: "solid_oidc.consent_rejected", reason: "password_invalid" }));
    return new Response("Invalid site owner password", { status: 401 });
  }
  const webid = form.get("webid") ?? "";
  const authorizationRequest: SolidOidcAuthorizationRequest = {
    clientId: form.get("client_id") ?? "",
    redirectUri: form.get("redirect_uri") ?? "",
    scope: form.get("scope") ?? "",
    codeChallenge: form.get("code_challenge") ?? "",
    ...(form.get("state") !== null ? { state: form.get("state") as string } : {}),
    ...(form.get("nonce") !== null ? { nonce: form.get("nonce") as string } : {}),
  };
  const origin = new URL(request.url).origin;
  const authorize = new URL("/oidc/authorize", origin);
  for (const name of ["client_id", "redirect_uri", "state", "response_type", "code_challenge", "code_challenge_method", "scope", "nonce"]) {
    const value = form.get(name);
    if (value !== null) authorize.searchParams.set(name, value);
  }
  authorize.searchParams.set(
    "consent",
    await createSolidOidcConsentToken(authorizationRequest, webid, env.TOKEN_SIGNING_KEY),
  );
  return Response.redirect(authorize.toString(), 303);
}

/**
 * Builds `@dwk/solid-oidc`'s config from `env`, or `null` when Solid-OIDC isn't fully
 * provisioned — `OIDC_SIGNING_KEY` unbound, the shared `INDIEAUTH_OWNER_PASSWORD`/
 * `TOKEN_SIGNING_KEY` secrets absent, `AUTH_DB` unbound (required by `SolidOidcEnv`, but checked
 * explicitly here too — `createSolidOidc`'s returned handler throws if it's missing, matching
 * `handleMicropub`'s defense-in-depth pattern rather than trusting the type alone), or
 * `OIDC_SIGNING_KEY` not parseable as JSON or not shaped like a usable EC P-256 private JWK.
 */
function solidOidcConfig(request: Request, env: WorkerEnv): SolidOidcConfig | null {
  if (!env.OIDC_SIGNING_KEY || !env.INDIEAUTH_OWNER_PASSWORD || !env.TOKEN_SIGNING_KEY || !env.AUTH_DB) return null;
  let signingKey: Jwk;
  try {
    const parsed: unknown = JSON.parse(env.OIDC_SIGNING_KEY);
    // `JSON.parse` succeeds on any valid JSON value, not just objects — `"null"`, `"3"`, and
    // `"\"x\""` all parse without throwing but aren't a usable JWK. A bare object check isn't
    // enough either: `{}` and `{"kty":"nonsense"}` both pass `typeof === "object"` but would
    // still reach `@dwk/solid-oidc`'s `importSigningKey` and throw uncaught there (it requires
    // `kty: "EC"`, `crv: "P-256"`, and a private `d`, plus the public `x`/`y` coordinates). This
    // mirrors those same checks so a malformed/incomplete key degrades to 503 here, never a 500
    // inside the library.
    if (typeof parsed !== "object" || parsed === null) return null;
    const candidate = parsed as Record<string, unknown>;
    if (
      candidate.kty !== "EC"
      || candidate.crv !== "P-256"
      || typeof candidate.d !== "string"
      || typeof candidate.x !== "string"
      || typeof candidate.y !== "string"
    ) {
      return null;
    }
    signingKey = candidate as Jwk;
  } catch {
    return null;
  }
  const baseUrl = new URL(request.url).origin;
  const webid = `${baseUrl}/profile/card#me`;
  return {
    issuer: baseUrl,
    signingKey,
    mountPath: "/oidc",
    audience: ["solid", baseUrl],
    async approveAuthorization(authorizationRequest: SolidOidcAuthorizationRequest, httpRequest: Request) {
      const consent = new URL(httpRequest.url).searchParams.get("consent");
      if (consent) {
        // Verified against the *live* `authorizationRequest` — a token minted for one
        // client_id/redirect_uri/scope/PKCE-challenge/state/nonce combination is rejected here
        // if replayed against a request with any field changed (Solid-OIDC consent-binding fix).
        const grant = await verifySolidOidcConsentToken(consent, authorizationRequest, env.TOKEN_SIGNING_KEY!);
        if (grant && grant.webid === webid) {
          return { webid: grant.webid, scope: grant.scope };
        }
      }
      // No (or invalid/expired/mismatched) consent proof yet — render the same owner-password
      // prompt `handleIndieAuthConsent`'s form posts to, targeting `/oidc/consent` instead. The
      // client_id/redirect_uri are shown as visible text (not just hidden inputs) so the owner
      // can actually see what they're approving before submitting.
      //
      // The hidden fields are rendered from `authorizationRequest` — the library's own parsed
      // object — rather than from the raw query string. `@dwk/solid-oidc`'s `handleAuthorize`
      // normalizes `redirectUri` (`new URL(...).toString()`, which e.g. adds a trailing slash to
      // a bare origin) and defaults `scope` when absent (`"openid webid"`) before calling this
      // hook; `handleSolidOidcConsent` mints the consent grant from whatever comes back in these
      // form fields, and `verifySolidOidcConsentToken` checks it against the *next* request's
      // freshly-normalized `authorizationRequest`. If the hidden fields echoed the raw query
      // values instead, mint time and verify time would build the grant from different
      // `redirectUri`/`scope` strings and never match — bouncing the owner back to this page
      // forever for any bare-origin `redirect_uri` or request that omits `scope`. Sourcing both
      // from `authorizationRequest` keeps mint and verify derived from the same normalization by
      // construction. `response_type`/`code_challenge_method` are hardcoded rather than echoed:
      // by the time this hook runs, `@dwk/solid-oidc` has already required them to be exactly
      // `"code"`/`"S256"`, so there's no raw value left to disagree with.
      const fields = [
        ["client_id", authorizationRequest.clientId],
        ["redirect_uri", authorizationRequest.redirectUri],
        ["response_type", "code"],
        ["code_challenge", authorizationRequest.codeChallenge],
        ["code_challenge_method", "S256"],
        ["scope", authorizationRequest.scope],
        ...(authorizationRequest.state !== undefined ? [["state", authorizationRequest.state]] : []),
        ...(authorizationRequest.nonce !== undefined ? [["nonce", authorizationRequest.nonce]] : []),
      ]
        .map(([name, value]) => `<input type="hidden" name="${escapeHTML(name)}" value="${escapeHTML(value)}">`)
        .join("\n");
      const body = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Approve sign-in</title></head><body><main>
<h1>Approve sign-in</h1>
<p><strong>${escapeHTML(authorizationRequest.clientId)}</strong> wants to sign in as this pod's owner.</p>
<p>Redirect target: <strong>${escapeHTML(authorizationRequest.redirectUri)}</strong></p>
<form method="post" action="/oidc/consent">
${fields}
<input type="hidden" name="webid" value="${escapeHTML(webid)}">
<label>Site owner password <input name="password" type="password" required autocomplete="current-password" maxlength="512"></label>
<button type="submit">Approve</button>
</form></main></body></html>`;
      return new Response(body, {
        status: 200,
        headers: {
          "content-type": "text/html; charset=utf-8",
          "cache-control": "no-store",
          "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
          "referrer-policy": "no-referrer",
          "x-content-type-options": "nosniff",
        },
      });
    },
  };
}

/**
 * Solid-OIDC OpenID Provider (identity layer for `@dwk/solid-pod`). Returns 503 when it isn't
 * fully provisioned (`OIDC_SIGNING_KEY` unbound, or the shared `INDIEAUTH_OWNER_PASSWORD`/
 * `TOKEN_SIGNING_KEY`/`AUTH_DB` bindings absent) rather than letting `@dwk/solid-oidc` throw its
 * own loud startup error, matching every other composed handler in this file.
 */
export function handleSolidOidc(
  request: Request,
  env: WorkerEnv,
  ctx: ExecutionContext,
): Promise<Response> {
  const config = solidOidcConfig(request, env);
  if (!config) {
    return Promise.resolve(new Response("Solid-OIDC is not configured", { status: 503 }));
  }
  const solidOidc = createSolidOidc(config);
  return solidOidc(request, env as unknown as SolidOidcEnv, ctx);
}

/**
 * Builds `@dwk/solid-pod`'s config from `env`, or `null` when solid-pod isn't fully provisioned
 * (`POD`/`BLOBS` unbound). `issuer`/`jwksUri` trust this same origin's Solid-OIDC identity
 * endpoint (`handleSolidOidc` above, Task 5's `/oidc/jwks`) — no separate cross-service secret,
 * just a URL string pointing back at this same Worker.
 */
function solidPodConfig(request: Request, env: WorkerEnv): SolidPodConfig | null {
  if (!env.POD || !env.BLOBS) return null;
  const baseUrl = new URL(request.url).origin;
  return {
    baseUrl,
    issuer: baseUrl,
    jwksUri: `${baseUrl}/oidc/jwks`,
    owner: `${baseUrl}/profile/card#me`,
  };
}

/**
 * Solid Pod (identity storage layer). Returns 503 when it isn't fully provisioned (`POD`/`BLOBS`
 * unbound) rather than letting `@dwk/solid-pod` throw its own loud startup error, matching every
 * other composed handler in this file.
 */
export function handleSolidPod(
  request: Request,
  env: WorkerEnv,
  ctx: ExecutionContext,
): Promise<Response> {
  const config = solidPodConfig(request, env);
  if (!config) {
    return Promise.resolve(new Response("Solid Pod is not configured", { status: 503 }));
  }
  const pod = createSolidPod(config);
  return pod(request, env as unknown as SolidPodEnv, ctx);
}

/**
 * WebDAV façade over the same Solid Pod (RFC 4918 Class 2 — mount as a network drive). Returns
 * 503 when solid-pod isn't provisioned or `WEBDAV_PEPPER` is unbound, matching every other
 * composed handler in this file.
 *
 * `@dwk/solid-pod`'s `SolidPodConfig` has no `pepper` field — unlike the app-password hashing
 * pepper's env-secret shape you might expect from other composed handlers, `WEBDAV_PEPPER` is
 * read directly by the per-pod Durable Object from its own bound `env` (a plain Cloudflare
 * Worker secret binding, visible to the DO regardless of what this front door passes through),
 * not threaded through `createSolidPodWebdav`'s config object. The check below still gates the
 * route on it being set: leaving it unbound is a valid (if weaker) runtime configuration for the
 * package itself, but this composition requires it before exposing `/dav` at all.
 */
export function handleWebdav(
  request: Request,
  env: WorkerEnv,
  ctx: ExecutionContext,
): Promise<Response> {
  const config = solidPodConfig(request, env);
  if (!config || !env.WEBDAV_PEPPER) {
    return Promise.resolve(new Response("WebDAV is not configured", { status: 503 }));
  }
  const webdav = createSolidPodWebdav(config);
  return webdav(request, env as unknown as SolidPodEnv, ctx);
}

/**
 * Owner-gated WebDAV app-password mint/list/revoke endpoint (`/dav-credentials`). Same 503
 * contract as `handleWebdav` above.
 */
export function handleWebdavCredentials(
  request: Request,
  env: WorkerEnv,
  ctx: ExecutionContext,
): Promise<Response> {
  const config = solidPodConfig(request, env);
  if (!config || !env.WEBDAV_PEPPER) {
    return Promise.resolve(new Response("WebDAV is not configured", { status: 503 }));
  }
  const credentials = createSolidPodWebdavCredentials(config);
  return credentials(request, env as unknown as SolidPodEnv, ctx);
}

/**
 * Solid Pod's R2 garbage-collection Cron Trigger — reclaims blobs orphaned by copy-on-write.
 * No-ops (rather than letting `@dwk/solid-pod`'s handler throw) when `BLOBS` or `GC_DB` is
 * unbound — see the `GC_DB` doc comment on `WorkerEnv` above for why the latter check exists
 * even though it isn't provisioned by anything yet.
 */
function handleSolidPodGcScheduled(
  controller: ScheduledController,
  env: WorkerEnv,
  ctx: ExecutionContext,
): Promise<void> {
  if (!env.BLOBS || !env.GC_DB) return Promise.resolve();
  const baseUrl = env.SITE_URL ?? "https://example.invalid";
  const gc = createSolidPodGc({ baseUrl, gcSafetyWindowMs: 300_000 });
  return gc(controller, env as unknown as SolidPodGcEnv, ctx);
}

/**
 * Micropub's scopes ("create"/"update"/"delete"/"media") plus Microsub's ("follow"/"channels"/
 * "read", V-4.3 #365) — @dwk/indieauth's constrainScopes drops any requested scope absent from
 * this list, so a client authorizing for Microsub without "follow"/"channels" listed here would
 * silently be granted an empty scope and then fail every Microsub action with
 * `insufficient_scope`. Shared with the RFC 9728 protected-resource metadata (#1577) below so the
 * two documents can't silently drift.
 */
const INDIEAUTH_SCOPES_SUPPORTED = ["create", "update", "delete", "media", "follow", "channels", "read"] as const;

function indieAuthHandler(request: Request, env: WorkerEnv) {
  const baseUrl = new URL(request.url).origin;
  return createIndieAuth({
    baseUrl,
    scopesSupported: INDIEAUTH_SCOPES_SUPPORTED,
    resourceIndicatorPolicy(resource) {
      try {
        return new URL(resource).origin === baseUrl;
      } catch {
        return false;
      }
    },
    async approveAuthorization(authorization) {
      const consent = new URL(request.url).searchParams.get("consent");
      if (consent && await verifyConsentToken(consent, authorization, env.TOKEN_SIGNING_KEY)) {
        return {
          me: `${baseUrl}/`,
          scopes: authorization.scopes,
          profile: { url: `${baseUrl}/` },
        };
      }
      return consentPage(authorization);
    },
  });
}

/**
 * RFC 9728 OAuth 2.0 Protected Resource Metadata (#1577, slice 2 of the #1326 Agent Readiness
 * ladder) — the resource-side counterpart to the RFC 8414 `/.well-known/oauth-authorization-server`
 * document `indieAuthHandler` already serves. Points an agent at this site's own IndieAuth
 * authorization server before it calls the IndieAuth-gated endpoints (Micropub, Microsub, the
 * media endpoint).
 *
 * IndieAuth's endpoints are always live for every site (`AUTH_DB`/`TOKEN_SIGNING_KEY` are
 * required, not optional, on `WorkerEnv`), so — like that document — this one is unconditional and
 * needs no binding checks.
 */
function handleOAuthProtectedResourceMetadata(request: Request): Response {
  const baseUrl = new URL(request.url).origin;
  const metadata = {
    resource: baseUrl,
    authorization_servers: [baseUrl],
    scopes_supported: INDIEAUTH_SCOPES_SUPPORTED,
    // `@dwk/indieauth` always issues DPoP-bound tokens (`token_type: "DPoP"`, never plain
    // Bearer — see its metadata.ts), so bearer_methods_supported is omitted and these two fields
    // mirror the algorithm list the authorization-server metadata document advertises.
    dpop_bound_access_tokens_required: true,
    dpop_signing_alg_values_supported: ["ES256", "ES384", "RS256", "PS256"],
  };
  return new Response(JSON.stringify(metadata), {
    headers: { "content-type": "application/json" },
  });
}

/**
 * RFC 9728 §5.1: a protected resource returning `401` should point back at its own
 * protected-resource metadata via `WWW-Authenticate`'s `resource_metadata` parameter — the
 * mechanism an agent uses to find `/.well-known/oauth-protected-resource` straight from a failed
 * request, without already knowing the URL. `@dwk/micropub`/`@dwk/microsub`'s own 401s don't set
 * this header, so `handleMicropub`/`handleMicrosub` wrap their responses through this instead of
 * patching the upstream library. Scheme is `DPoP`, not `Bearer` — matching
 * `handleOAuthProtectedResourceMetadata`'s `dpop_bound_access_tokens_required`, since
 * `@dwk/indieauth` never issues plain Bearer tokens. A non-401 response, or one that already
 * carries its own `WWW-Authenticate`, passes through unchanged.
 */
function withResourceMetadataChallenge(response: Response, baseUrl: string): Response {
  if (response.status !== 401 || response.headers.has("www-authenticate")) {
    return response;
  }
  const headers = new Headers(response.headers);
  headers.set("www-authenticate", `DPoP resource_metadata="${baseUrl}/.well-known/oauth-protected-resource"`);
  return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
}

/**
 * Inbound-Webmention receive endpoint (V-3.1, #359).
 *
 * Composes `@dwk/webmention`'s receiver: a form-encoded `POST` of `source` + `target` is
 * validated synchronously (both `http(s)` URLs, distinct, `target` under this origin) and, on
 * success, enqueued to `WEBMENTION_QUEUE` for asynchronous link-verification before a `202`.
 * The heavy work — fetching the source through an SSRF-safe wrapper and confirming it links to
 * the target — happens in the `queue` consumer, keeping the request path cheap and spam-resistant.
 *
 * Returns `503` when inbound Webmention isn't provisioned for this site (no `WEBMENTION_QUEUE`),
 * so a stray request to an un-provisioned site gets a clean "not configured" rather than the
 * library's loud throw. The `/webmention` route is only advertised (`<link rel="webmention">`)
 * once provisioning is on — that discovery wiring is the paired template/Swift follow-up.
 */
function handleWebmentionReceive(
  request: Request,
  env: WorkerEnv,
  ctx: ExecutionContext,
): Promise<Response> {
  if (!env.WEBMENTION_QUEUE) {
    return Promise.resolve(new Response("Webmention receiving is not configured", { status: 503 }));
  }
  const baseUrl = new URL(request.url).origin;
  const receiver = createWebmention({ baseUrl });
  const webmentionEnv: WebmentionEnv = {
    WEBMENTION_QUEUE: env.WEBMENTION_QUEUE,
    WEBMENTION_INBOX: env.WEBMENTION_INBOX,
  };
  return receiver(request, webmentionEnv, ctx);
}

/**
 * Queue consumer for asynchronous Webmention verification (V-3.1, #359).
 *
 * For each queued `(source, target)` job, `@dwk/webmention` fetches the source through its
 * SSRF-safe wrapper and upserts a verified mention into the D1 inbox — or removes it when the
 * source no longer links. Acks-without-work (rather than throwing) when the inbox or the site
 * origin isn't provisioned, so an un-provisioned site's stray queue delivery can't wedge the
 * consumer. `SITE_URL` scopes which targets verification accepts; the consumer has no request to
 * derive the origin from, so provisioning supplies it as a plain var.
 */
function handleWebmentionQueue(
  batch: MessageBatch<WebmentionJob>,
  env: WorkerEnv,
  ctx: ExecutionContext,
): Promise<void> {
  if (!env.WEBMENTION_QUEUE || !env.WEBMENTION_INBOX || !env.SITE_URL) {
    return Promise.resolve();
  }
  const consumer = createWebmentionQueueConsumer({
    baseUrl: env.SITE_URL,
    inbox: createD1Inbox(env.WEBMENTION_INBOX),
    isTrustedVouchDomain: (hostname) => isTrustedVouchDomain(env, hostname),
  });
  const webmentionEnv: WebmentionEnv = {
    WEBMENTION_QUEUE: env.WEBMENTION_QUEUE,
    WEBMENTION_INBOX: env.WEBMENTION_INBOX,
  };
  return consumer(batch, webmentionEnv, ctx);
}

/**
 * Micropub server (V-3.2, #360).
 *
 * Composes `@dwk/micropub`'s create/update/delete endpoint and its R2-backed media endpoint.
 * Requires `@dwk/indieauth` to be active on the same site (catalog `requires`, resolved by
 * `WorkerActivation`) — Micropub authorizes every request against `AUTH_DB`'s issued-token store
 * using the same `TOKEN_SIGNING_KEY` IndieAuth signs tokens with.
 *
 * Returns `503` when Micropub isn't fully provisioned (`MICROPUB_DB`/`MEDIA` unbound, or
 * IndieAuth's `AUTH_DB`/`TOKEN_SIGNING_KEY` unbound) rather than letting `@dwk/micropub` throw
 * its own loud startup error.
 */
function handleMicropub(
  request: Request,
  env: WorkerEnv,
  ctx: ExecutionContext,
): Promise<Response> {
  if (!env.MICROPUB_DB || !env.MEDIA || !env.AUTH_DB || !env.TOKEN_SIGNING_KEY) {
    return Promise.resolve(new Response("Micropub is not configured", { status: 503 }));
  }
  const baseUrl = new URL(request.url).origin;
  const micropub = createMicropub({
    baseUrl,
    me: `${baseUrl}/`,
    // #912: assign a type-aware URL at create time so a synced git file (written under
    // src/content/{collection}/, per MicropubContentSync) renders at the same URL this
    // response's Location header already promised — see post-type-discovery.ts and
    // docs/superpowers/specs/2026-07-24-micropub-content-sync-design.md §1.
    generatePostUrl: (post, commands) => {
      const slug = generateSlug(post, commands);
      const collection = discoverCollection(post);
      return collection ? `${baseUrl}/${collection}/${slug}` : `${baseUrl}/${slug}`;
    },
  });
  const micropubEnv: MicropubEnv = {
    MEDIA: env.MEDIA,
    MICROPUB_DB: env.MICROPUB_DB,
    AUTH_DB: env.AUTH_DB,
    TOKEN_SIGNING_KEY: env.TOKEN_SIGNING_KEY,
  };
  // Extract the post content from a *clone taken before* `micropub()` ever reads the original
  // request's body (V-4.1, #363). Cloning an unconsumed Request is always spec-safe; cloning
  // one whose body a library has already read is not a documented-safe operation (workerd
  // happens to tolerate it today, but a future `@dwk/micropub` release that reads the body via
  // a locked stream reader could silently break the fan-out with no visible failure). Doing the
  // extraction up front — before `micropub(request, ...)` is called — sidesteps that hazard
  // entirely rather than relying on it.
  const contentPromise: Promise<{
    content: string;
    photos: ExtractedPhoto[];
    visibility: string | undefined;
    btoTargets: string[];
  }> = (async () => {
    const empty = { content: "", photos: [], visibility: undefined, btoTargets: [] };
    if (!env.AP_PUBLISH_TOKEN || request.method !== "POST") return empty;
    const cloned = request.clone();
    try {
      const contentType = cloned.headers.get("content-type") ?? "";
      if (contentType.includes("application/json")) {
        const body = (await cloned.json()) as {
          properties?: { content?: unknown[]; photo?: unknown[]; visibility?: unknown[]; "mp-bto"?: unknown[] };
        };
        return {
          content: extractMf2ContentString(body.properties?.content?.[0]),
          photos: extractMf2Photos(body.properties?.photo),
          visibility: typeof body.properties?.visibility?.[0] === "string" ? body.properties.visibility[0] : undefined,
          btoTargets: extractMf2StringList(body.properties?.["mp-bto"]),
        };
      }
      const form = await cloned.formData();
      const content = String(form.get("content") ?? form.get("properties[content]") ?? "");
      const visibilityRaw = form.get("visibility") ?? form.get("properties[visibility]");
      const visibility = typeof visibilityRaw === "string" && visibilityRaw.length > 0 ? visibilityRaw : undefined;
      // Form-encoded `photo`/`photo[]`/`properties[photo][]` fields carry a bare URL string per
      // entry — the mf2 `{ value, alt }` alt-text shape has no flat-form equivalent (per
      // `@dwk/micropub`'s own `parseFormBody`, only one `photo[sub]` nested object can round-trip
      // per request), so form-encoded photos never carry alt text — same fidelity Micropub form
      // clients get today. `properties[photo][]` mirrors `content`'s `properties[content]`
      // fallback two lines up — a client using that nesting convention for `content` would
      // otherwise have its photos silently dropped from the fan-out (#1325 review). Walking
      // `form.entries()` once (rather than concatenating separate `getAll()` calls) preserves
      // submission order across mixed field names (#1325 review). `mp-bto`/`mp-bto[]` mirrors the
      // same two-name convention for the restricted-post blind-recipient list (#1565).
      const photoFieldNames = new Set(["photo", "photo[]", "properties[photo][]"]);
      const btoFieldNames = new Set(["mp-bto", "mp-bto[]"]);
      const rawPhotos: string[] = [];
      const rawBtoTargets: string[] = [];
      for (const [key, value] of form.entries()) {
        if (typeof value !== "string" || value.length === 0) continue;
        if (photoFieldNames.has(key)) rawPhotos.push(value);
        else if (btoFieldNames.has(key)) rawBtoTargets.push(value);
      }
      return { content, photos: extractMf2Photos(rawPhotos), visibility, btoTargets: rawBtoTargets };
    } catch {
      // Can't recover the post content — skip the fan-out rather than publish an empty Note.
      return empty;
    }
  })();
  return micropub(request, micropubEnv, ctx).then(async (response) => {
    if (request.method === "POST" && response.status === 201) {
      const { content, photos, visibility, btoTargets } = await contentPromise;
      ctx.waitUntil(
        fanOutMicropubCreateToActivityPub(content, photos, visibility, btoTargets, baseUrl, response, env, ctx),
      );
    }
    return withResourceMetadataChallenge(response, baseUrl);
  });
}

/** The AS2 Public collection IRI — addressing a `to` value every server treats as "everyone". */
const AS2_PUBLIC = "https://www.w3.org/ns/activitystreams#Public";

/**
 * The `to`/`bto` addressing for a Micropub-originated fan-out Note (#1565, §2.4). A restricted
 * post (`visibility: contacts`) must never fall back to public `to` addressing — not even when
 * there is nobody to deliver it to. `@dwk/activitypub`'s outbox handler (`#asOutboxActivity`)
 * only withholds its own public-addressing default when the posted object already carries a
 * `bto` key at all (`input.bto !== undefined`); an *empty* `bto: []` would still satisfy that
 * check but produce an activity with no visible addressing, which the store then treats as
 * unrestricted (`blindRecipients` is empty, so `restricted` comes out `false`) — quietly
 * exposing the restricted post's content in the public outbox collection. So a restricted post
 * with zero linkable targets gets no `bto` key at all: the caller must skip the fan-out entirely
 * (`null`) rather than post an object this package would treat as public.
 */
export function resolveFanOutAddressing(
  visibility: string | undefined,
  btoTargets: readonly string[],
): { to: string[] } | { bto: string[] } | null {
  if (visibility === "contacts") {
    return btoTargets.length > 0 ? { bto: [...btoTargets] } : null;
  }
  return { to: [AS2_PUBLIC] };
}

/**
 * Micropub-to-ActivityPub fan-out (V-4.1, #363): a successful Micropub create becomes a `Note`
 * activity, published through `@dwk/activitypub`'s owner-only publish endpoint
 * (`POST <actor>/outbox`) so it lands in the outbox and fans out to followers. In-process —
 * same Worker script, same invocation this request is already inside, no real network
 * round-trip. Only runs when ActivityPub is provisioned (`AP_PUBLISH_TOKEN` set); activating
 * Micropub alone never attempts to federate. Failure here must never fail the Micropub create
 * response (the post is already saved) — logged and swallowed.
 *
 * `photos` becomes AS2 `attachment` (#1240): media-only Fediverse clients such as Pixelfed
 * render only posts carrying an attachment, so a bare `Note` from `content` alone is invisible
 * to a Pixelfed follower. `@dwk/activitypub`'s outbox wraps the posted object with `{ ...input }`
 * (see its `#asOutboxActivity`), so `attachment` passes through to delivery unmodified — no
 * package-side change needed.
 *
 * `visibility`/`btoTargets` drive restricted (`visibility: contacts`) delivery (#1565, §2.4):
 * `btoTargets` are meant to be the actor IRIs of contacts with a linked ActivityPub actor — the
 * Worker has no access to the owner's private `ContactStore` itself (§2.3's deliberate privacy
 * boundary: linked-actor data is never pushed to Worker storage), so a caller resolves that list
 * client-side and carries it on the originating Micropub POST as the ephemeral `mp-bto` command
 * property (see `handleMicropub`'s extraction) — never persisted, since `mp-*` keys are stripped
 * before storage. No caller populates `mp-bto` yet, so restricted posts currently fan out to
 * nobody (see `resolveFanOutAddressing`'s null case) rather than leaking publicly; wiring an
 * actual source for it is follow-up work. Best-effort, honor-system distribution either way:
 * `bto` addressing is a delivery hint, not access control — the Worker's IndieAuth-gated read
 * stays the enforced, canonical copy.
 */
async function fanOutMicropubCreateToActivityPub(
  content: string,
  photos: readonly ExtractedPhoto[],
  visibility: string | undefined,
  btoTargets: readonly string[],
  baseUrl: string,
  micropubResponse: Response,
  env: WorkerEnv,
  ctx: ExecutionContext,
): Promise<void> {
  if (!env.AP_PUBLISH_TOKEN) return;
  // A photo-only create (no caption) must still fan out (#1240, #1325 review) — requiring
  // `content` alone would drop exactly the case this issue exists to fix: a bare photo post
  // with no text is a normal, common shape, and Pixelfed only needs the `attachment` to render.
  if (!content && photos.length === 0) return;
  const addressing = resolveFanOutAddressing(visibility, btoTargets);
  // Restricted with nobody to deliver to (#1565): never federate this Note at all, rather than
  // let it fall through to any public-addressing default — see `resolveFanOutAddressing`.
  if (!addressing) return;
  const location = micropubResponse.headers.get("location");
  if (!location) return;

  const actorIRI = `${baseUrl}/users/${ACTIVITYPUB_USERNAME}`;
  const note = {
    "@context": "https://www.w3.org/ns/activitystreams",
    type: "Note",
    attributedTo: actorIRI,
    content,
    url: tagFediverseUrl(location, utmCodesArtifact),
    ...(photos.length > 0
      ? {
          attachment: photos.map((photo) => ({
            type: "Image",
            url: photo.url,
            ...(photo.alt !== undefined ? { name: photo.alt } : {}),
          })),
        }
      : {}),
    // No `cc` naming the followers collection: unlike the convention some AP implementations
    // use for "public post, also cc followers" addressing, @dwk/activitypub's owner-publish
    // outbox handler (`#publish` in its Durable Object) fans out to every current follower's
    // inbox for a *publicly* addressed activity — it never inspects `to`/`cc` beyond that to
    // decide delivery. A `bto`-only activity (no `to` at all, the restricted case above) is
    // delivered individually to its blind recipients instead, with no follower fan-out (#496).
    ...addressing,
  };
  const publishRequest = new Request(`${actorIRI}/outbox`, {
    method: "POST",
    headers: {
      "content-type": "application/activity+json",
      authorization: `Bearer ${env.AP_PUBLISH_TOKEN}`,
    },
    body: JSON.stringify(note),
  });
  try {
    await handleActivityPub(publishRequest, env, ctx);
  } catch {
    // Swallow: the Micropub post is already saved; a federation hiccup must not surface as a
    // failure to the Micropub client.
  }
}

/**
 * The actor **IRI** (`/users/site`) for this app's single-actor-per-site model (V-4.1, #363).
 * Fixed forever, independent of the WebFinger-visible handle (#1239, design doc
 * `2026-08-04-fediverse-handle-design.md` §"Actor IRI stays /users/site — permanently"):
 * follows, signatures, and caches bind to the IRI, so it must never change even as the owner
 * renames their handle. `@dwk/activitypub` ties one `actor.username` to *both* the IRI and the
 * displayed `preferredUsername` (`resolveConfig`/`deriveIris`), so `activityPubConfig` below
 * always passes this fixed constant and `resolvePreferredUsername`'s (possibly different) value
 * is patched onto the served actor document and WebFinger map separately, rather than handed to
 * the package at all. WebFinger (`.well-known/webfinger`, so `@<handle>@domain` search resolves)
 * is composed by `handleWebFinger` below (V-4.4, #366); Mastodon can still follow this actor by
 * pasting its URL directly into search even where WebFinger isn't active.
 */
const ACTIVITYPUB_USERNAME = "site";

/**
 * RFC 7565 `acct:` userpart ∩ Mastodon remote-username grammar (#1239, design doc §"Owner-chosen
 * username"): case-insensitive `[a-z0-9_]` at both ends, `[a-z0-9_.-]` interior. No length cap
 * beyond WebFinger practicality.
 */
const AP_USERNAME_PATTERN = /^[a-z0-9_](?:[a-z0-9_.-]*[a-z0-9_])?$/i;

/** Whether `value` is a syntactically valid WebFinger local-part per {@link AP_USERNAME_PATTERN}. */
export function isValidApUsername(value: string): boolean {
  return AP_USERNAME_PATTERN.test(value);
}

/**
 * The default `preferredUsername`: the serving origin's hostname with a leading `www.` stripped
 * (design doc §"The default: domain as username"). Needs no configuration — the caller already
 * has `baseUrl`'s host from the request origin.
 */
export function defaultApUsername(host: string): string {
  return host.startsWith("www.") ? host.slice(4) : host;
}

/**
 * Resolve the WebFinger-visible `preferredUsername`: `env.AP_USERNAME`, re-validated at request
 * time — because `.site-config` is hand-editable, a stray edit must degrade to the default handle
 * rather than produce a malformed `acct:` resource or actor document (design doc §"Validation") —
 * falling back to {@link defaultApUsername} when unset, blank, or invalid. Never affects the actor
 * IRI; see {@link ACTIVITYPUB_USERNAME}.
 *
 * Lowercased before returning: the grammar is explicitly case-insensitive (design doc
 * §"Validation"), but the WebFinger resource map below is a plain object keyed by the exact
 * `acct:` string, and `@dwk/webfinger`'s own resource normalization only lowercases the *host*
 * half of a queried `acct:` resource, deliberately leaving the local part case-sensitive per RFC
 * 7565 (`resource.ts`'s doc comment). Left un-normalized, a mixed-case override (`AP_USERNAME=Alice`)
 * would only resolve at that exact casing — undiscoverable via the lowercase `acct:` lookup
 * conventional Fediverse clients (and this file's own alias entries) use.
 */
export function resolvePreferredUsername(env: WorkerEnv, host: string): string {
  const fallback = defaultApUsername(host);
  const override = env.AP_USERNAME?.trim();
  if (!override || !isValidApUsername(override)) return fallback;
  return override.toLowerCase();
}

/**
 * Resolve the actor's avatar URL from `env.AP_ICON` (#1771): an absolute `http(s)` URL is passed
 * through, a root-relative path (the app's default, `/apple-touch-icon.png`) is resolved
 * against the serving origin — so the federated avatar always points at the host the actor is
 * being fetched from, even before the app has ever learned the site's public URL. Unset, blank,
 * unparseable, or any non-`http(s)` scheme yields `undefined` (no `icon` at all): `.site-config`
 * is hand-editable, so a stray `javascript:`/`data:` value must degrade to "no avatar" rather
 * than land in a document every peer fetches — the same request-time defense-in-depth posture
 * `resolvePreferredUsername` takes for `AP_USERNAME`.
 */
export function resolveApIcon(env: WorkerEnv, baseUrl: string): string | undefined {
  const raw = env.AP_ICON?.trim();
  if (!raw) return undefined;
  let url: URL;
  try {
    url = new URL(raw, baseUrl);
  } catch {
    return undefined;
  }
  if (url.protocol !== "https:" && url.protocol !== "http:") return undefined;
  return url.href;
}

/**
 * Exported for `worker.test.ts` — a pure, synchronous mapping from `env` to
 * `@dwk/activitypub`'s config shape, so the `AP_ACTOR_TYPE`/`AP_MODERATORS` wiring (V-5.1b, #907)
 * and the `AP_ICON` avatar (#1771) are testable without standing up a real Durable Object.
 */
export function activityPubConfig(request: Request, env: WorkerEnv): ActivityPubConfig | null {
  if (!env.ACTOR || !env.AP_PRIVATE_KEY || !env.AP_PUBLIC_KEY) return null;
  const baseUrl = new URL(request.url).origin;
  const isGroup = env.AP_ACTOR_TYPE === "Group";
  return {
    baseUrl,
    actor: {
      username: ACTIVITYPUB_USERNAME,
      name: env.AP_DISPLAY_NAME ?? new URL(baseUrl).hostname,
      summary: `Posts from ${new URL(baseUrl).hostname}`,
      type: isGroup ? "Group" : undefined,
      // @dwk/activitypub renders this as `icon: { type: "Image", url }` and omits `icon`
      // entirely when undefined.
      icon: resolveApIcon(env, baseUrl),
    },
    // Only meaningful for a Group actor — @dwk/activitypub ignores this for a Person, but the
    // check here also guards against a stray AP_MODERATORS on an otherwise-Person site.
    moderators: isGroup && env.AP_MODERATORS
      ? env.AP_MODERATORS.split(",").filter((iri) => iri.length > 0)
      : undefined,
    publicKeyPem: env.AP_PUBLIC_KEY,
    privateKeyPem: env.AP_PRIVATE_KEY,
    publishToken: env.AP_PUBLISH_TOKEN,
    // The package's shared-inbox route (POST /inbox at the origin root) collides with this
    // app's existing inbox-capture feature (#587, a public "visitor sends a message" form —
    // an unrelated concept already serving that exact path). Disabling it means inbound
    // federated deliveries go to the actor-specific /users/site/inbox instead, which is
    // equally valid ActivityPub — just without an optional batching optimization for
    // high-volume peers, irrelevant for a single-actor personal site.
    sharedInbox: false,
  };
}

/**
 * Rewrites the served actor document's `preferredUsername` (and FEP-2c59 `webfinger` back-link)
 * from `ACTIVITYPUB_USERNAME` to the resolved, possibly-overridden handle (#1239). Necessary
 * because `@dwk/activitypub` derives both the actor IRI and these two fields from one
 * `actor.username` (see {@link ACTIVITYPUB_USERNAME}'s doc comment) — this package has no seam to
 * decouple them, so the one JSON field pair is patched on the response rather than the package's
 * routing forked. A no-op for every other route (inbox, outbox, collections, NodeInfo, …), for a
 * non-`GET`/`HEAD` request, and for a non-2xx response.
 */
async function withPreferredUsername(
  request: Request,
  response: Response,
  actorPath: string,
  preferredUsername: string,
  host: string,
): Promise<Response> {
  const method = request.method.toUpperCase();
  if (
    new URL(request.url).pathname !== actorPath ||
    (method !== "GET" && method !== "HEAD") ||
    !response.ok
  ) {
    return response;
  }
  if (method === "HEAD") return response;
  const doc = (await response.json()) as Record<string, unknown>;
  doc.preferredUsername = preferredUsername;
  if (typeof doc.webfinger === "string") {
    doc.webfinger = `acct:${preferredUsername}@${host}`;
  }
  const headers = new Headers(response.headers);
  headers.delete("content-length");
  return new Response(JSON.stringify(doc), { status: response.status, headers });
}

/**
 * ActivityPub actor (V-4.1, #363).
 *
 * Composes `@dwk/activitypub`'s actor document, follower/following/outbox collections, and
 * signed server-to-server inbox — the Fediverse-facing half of this site. Returns 503 when
 * ActivityPub isn't fully provisioned (`ACTOR`/`AP_PRIVATE_KEY`/`AP_PUBLIC_KEY` unbound) rather
 * than letting `@dwk/activitypub` throw its own loud startup error, matching every other
 * composed handler in this file. The served actor document's `preferredUsername` is patched to
 * the resolved handle post hoc — see {@link withPreferredUsername}.
 */
function handleActivityPub(
  request: Request,
  env: WorkerEnv,
  ctx: ExecutionContext,
): Promise<Response> {
  const config = activityPubConfig(request, env);
  if (!config) {
    return Promise.resolve(new Response("ActivityPub is not configured", { status: 503 }));
  }
  const baseUrl = new URL(request.url).origin;
  const host = new URL(baseUrl).hostname;
  const preferredUsername = resolvePreferredUsername(env, host);
  const actorPath = `/users/${ACTIVITYPUB_USERNAME}`;
  const activitypub = createActivityPub(config);
  return activitypub(request, env as unknown as ActivityPubEnv, ctx).then((response) =>
    withPreferredUsername(request, response, actorPath, preferredUsername, host),
  );
}

/**
 * WebFinger discovery (V-4.4, #366): resolves `acct:<username>@<host>` to this site's
 * ActivityPub actor, so `@<handle>@domain` search works in Mastodon and other fediverse clients.
 * `@dwk/webfinger`'s handler is RFC 7033-conformant on its own (query validation, CORS, JRD
 * body, 400/404); this function only supplies the resource map. The actor is WebFinger's only
 * controlled resource today, so — like every other composed handler in this file — this
 * returns 503 when ActivityPub isn't provisioned rather than constructing an always-empty
 * endpoint.
 *
 * Serves the canonical `acct:<preferredUsername>@<host>` plus aliases (#1239, design doc
 * §"Migration for already-federated sites"): the legacy fixed `acct:site@<host>` handle (so an
 * already-federated actor's old handle keeps resolving after this site adopts the new default)
 * and, when an override is active, the hostname-derived default (so a stale reference to the
 * pre-override handle also resolves). Each alias's JRD `subject` is the canonical handle, not the
 * alias itself, so a client that follows the alias still learns the actor's real handle.
 */
function handleWebFinger(
  request: Request,
  env: WorkerEnv,
  ctx: ExecutionContext,
): Promise<Response> {
  const config = activityPubConfig(request, env);
  if (!config) {
    return Promise.resolve(new Response("WebFinger is not configured", { status: 503 }));
  }
  const baseUrl = new URL(request.url).origin;
  const host = new URL(baseUrl).hostname;
  const preferredUsername = resolvePreferredUsername(env, host);
  const actorHref = `${baseUrl}/users/${ACTIVITYPUB_USERNAME}`;
  const canonicalAcct = `acct:${preferredUsername}@${host}`;
  const selfLink = {
    rel: "self",
    type: "application/activity+json",
    href: actorHref,
  };
  const resources: Record<string, { subject?: string; links: (typeof selfLink)[] }> = {
    [canonicalAcct]: { links: [selfLink] },
  };
  const aliasLocals = new Set<string>();
  if (ACTIVITYPUB_USERNAME !== preferredUsername) aliasLocals.add(ACTIVITYPUB_USERNAME);
  const hostDefault = defaultApUsername(host);
  if (hostDefault !== preferredUsername) aliasLocals.add(hostDefault);
  for (const local of aliasLocals) {
    resources[`acct:${local}@${host}`] = { subject: canonicalAcct, links: [selfLink] };
  }
  const webfinger = createWebfinger({ resources });
  return webfinger(request, {}, ctx);
}

/**
 * Microsub reader (V-4.3, #365).
 *
 * Composes `@dwk/microsub`'s single endpoint: channel/feed subscriptions, following (with
 * immediate timeline population from the discovery fetch), and the normalised JF2 timeline
 * (mark read/unread, remove, per-channel unread counts). Requires `@dwk/indieauth` to be active
 * on the same site (catalog `requires`, resolved by `WorkerActivation`) — Microsub authorizes
 * every request against `AUTH_DB`'s issued-token store with a DPoP-bound access token, the same
 * as `@dwk/micropub`.
 *
 * Returns `503` when Microsub isn't fully provisioned (`MICROSUB_DB`/`MICROSUB_QUEUE` unbound,
 * or IndieAuth's `AUTH_DB`/`TOKEN_SIGNING_KEY` unbound) rather than letting `@dwk/microsub` throw
 * its own loud startup error.
 */
function handleMicrosub(
  request: Request,
  env: WorkerEnv,
  ctx: ExecutionContext,
): Promise<Response> {
  if (!env.MICROSUB_DB || !env.MICROSUB_QUEUE || !env.AUTH_DB || !env.TOKEN_SIGNING_KEY) {
    return Promise.resolve(new Response("Microsub is not configured", { status: 503 }));
  }
  const baseUrl = new URL(request.url).origin;
  const microsub = createMicrosub({ baseUrl, me: `${baseUrl}/` });
  const microsubEnv: MicrosubEnv = {
    MICROSUB_DB: env.MICROSUB_DB,
    MICROSUB_QUEUE: env.MICROSUB_QUEUE,
    AUTH_DB: env.AUTH_DB,
    TOKEN_SIGNING_KEY: env.TOKEN_SIGNING_KEY,
  };
  return microsub(request, microsubEnv, ctx).then((response) => withResourceMetadataChallenge(response, baseUrl));
}

/**
 * Cron-triggered feed poller for Microsub (V-4.3, #365): enqueues one poll job per followed
 * feed onto `MICROSUB_QUEUE`. Runs off the read path — `handleMicrosub`'s timeline action only
 * ever serves stored entries. No-ops when Microsub isn't provisioned.
 */
function handleMicrosubScheduled(
  controller: ScheduledController,
  env: WorkerEnv,
  ctx: ExecutionContext,
): Promise<void> {
  if (!env.MICROSUB_DB || !env.MICROSUB_QUEUE || !env.AUTH_DB || !env.TOKEN_SIGNING_KEY) {
    return Promise.resolve();
  }
  const baseUrl = env.SITE_URL ?? "";
  if (!baseUrl) return Promise.resolve();
  const poll = createMicrosubPoller({ baseUrl, me: `${baseUrl}/` });
  const microsubEnv: MicrosubEnv = {
    MICROSUB_DB: env.MICROSUB_DB,
    MICROSUB_QUEUE: env.MICROSUB_QUEUE,
    AUTH_DB: env.AUTH_DB,
    TOKEN_SIGNING_KEY: env.TOKEN_SIGNING_KEY,
  };
  return poll(controller, microsubEnv, ctx);
}

/**
 * Queue consumer for Microsub's feed-poll fan-out (V-4.3, #365): fetches + parses each polled
 * feed and appends new entries to the following channel's timeline. Acks-without-work when
 * Microsub isn't provisioned — same contract as `handleWebmentionQueue`/`handleWebSubQueue`.
 */
function handleMicrosubQueue(
  batch: MessageBatch<MicrosubJob>,
  env: WorkerEnv,
  ctx: ExecutionContext,
): Promise<void> {
  if (!env.MICROSUB_DB || !env.MICROSUB_QUEUE || !env.AUTH_DB || !env.TOKEN_SIGNING_KEY || !env.SITE_URL) {
    return Promise.resolve();
  }
  const consume = createMicrosubQueueConsumer({ baseUrl: env.SITE_URL, me: `${env.SITE_URL}/` });
  const microsubEnv: MicrosubEnv = {
    MICROSUB_DB: env.MICROSUB_DB,
    MICROSUB_QUEUE: env.MICROSUB_QUEUE,
    AUTH_DB: env.AUTH_DB,
    TOKEN_SIGNING_KEY: env.TOKEN_SIGNING_KEY,
  };
  return consume(batch, microsubEnv, ctx);
}

/**
 * The site's feed paths — the only topics the WebSub hub serves. These are the template's
 * static root feeds (src/pages/{rss.xml,atom.xml,feed.json}.ts); they cover everything the
 * site publishes, so a subscriber to any of them sees every update. The same list drives the
 * `rel="hub"` advertisement in the generated feeds (src/lib/feeds.ts) and Anglesite's
 * publish ping after a deploy — all three must agree or a discoverable topic would 400 on
 * subscribe or never receive a push.
 */
export const WEBSUB_TOPIC_PATHS = ["/rss.xml", "/atom.xml", "/feed.json"] as const;

/**
 * WebSub hub configuration for a given canonical site origin. Topics are the root feeds on
 * that origin; the hub endpoint itself is `/websub` on the same origin.
 */
function websubConfig(origin: string): WebSubConfig {
  return {
    baseUrl: origin,
    hubUrl: `${origin}/websub`,
    allowedTopics: WEBSUB_TOPIC_PATHS.map((path) => `${origin}${path}`),
  };
}

/**
 * The canonical origin WebSub topics are keyed on, or `null` when `SITE_URL` isn't provisioned
 * or isn't a valid URL. Both the hub route and the queue consumer require this — subscriptions
 * are keyed on exact topic URLs, and a hub that fell back to the request's origin could accept
 * a subscription the queue consumer (which has no request to derive an origin from, and always
 * requires `SITE_URL`) would then silently never fan out to. Failing the hub route closed here
 * keeps both sides of the same feature agreeing on what "provisioned" means.
 */
function websubOrigin(env: WorkerEnv): string | null {
  if (!env.SITE_URL) return null;
  try {
    return new URL(env.SITE_URL).origin;
  } catch {
    return null;
  }
}

/**
 * WebSub hub endpoint (V-3.3, #361).
 *
 * Composes `@dwk/websub`'s hub: a form-encoded `POST` of `hub.mode=subscribe|unsubscribe`
 * is validated synchronously and a verification-of-intent job enqueued (202);
 * `hub.mode=publish` for one of this site's feeds enqueues a distribution job (202) — the
 * consumer fetches the feed once and POSTs it to every verified subscriber, HMAC-signing
 * the body (`X-Hub-Signature`) for subscribers that registered a secret. Returns 503 when
 * the hub isn't provisioned for this site (no queue/store binding, or no canonical `SITE_URL`
 * — see `websubOrigin`), mirroring `handleWebmentionReceive`'s degrade-gracefully contract.
 */
function handleWebSubHub(request: Request, env: WorkerEnv, ctx: ExecutionContext): Promise<Response> {
  const origin = websubOrigin(env);
  if (!env.WEBSUB_QUEUE || !env.WEBSUB_DB || !origin) {
    return Promise.resolve(new Response("WebSub hub is not configured", { status: 503 }));
  }
  const hub = createWebSub(websubConfig(origin));
  const websubEnv: WebSubEnv = {
    WEBSUB_DB: env.WEBSUB_DB,
    WEBSUB_QUEUE: env.WEBSUB_QUEUE,
  };
  return hub(request, websubEnv, ctx);
}

/**
 * Queue consumer for WebSub verification + distribution + per-subscriber delivery (V-3.3,
 * #361). Acks-without-work when the hub or the canonical site origin isn't provisioned —
 * same contract as `handleWebmentionQueue`.
 */
function handleWebSubQueue(
  batch: MessageBatch<WebSubJob>,
  env: WorkerEnv,
  ctx: ExecutionContext,
): Promise<void> {
  const origin = websubOrigin(env);
  if (!env.WEBSUB_QUEUE || !env.WEBSUB_DB || !origin) {
    return Promise.resolve();
  }
  const consumer = createWebSubQueueConsumer(websubConfig(origin));
  const websubEnv: WebSubEnv = {
    WEBSUB_DB: env.WEBSUB_DB,
    WEBSUB_QUEUE: env.WEBSUB_QUEUE,
  };
  return consumer(batch, websubEnv, ctx);
}

export interface InboxFields {
  subject: string;
  from: string;
  message: string;
}

/** Validates and trims the three required fields; null if any is missing or too long. */
export function validateInboxFields(fields: Record<string, string>): InboxFields | null {
  const subject = (fields.subject ?? "").trim();
  const from = (fields.from ?? "").trim();
  const message = (fields.message ?? "").trim();
  if (!subject || !from || !message) return null;
  if (
    subject.length > MAX_SUBJECT_LENGTH ||
    from.length > MAX_FROM_LENGTH ||
    message.length > MAX_MESSAGE_LENGTH
  ) {
    return null;
  }
  return { subject, from, message };
}

/** True (and records the hit) once `ip` has submitted `RATE_LIMIT_MAX_PER_WINDOW` times within
 *  the current hour-long window. A simple KV counter, not a sliding window — good enough for a
 *  single-owner-site abuse gate; Cloudflare's own Rate Limiting Rules remain the escalation path
 *  for anything more sophisticated.
 *
 *  The get-then-put below is NOT atomic: two concurrent requests from the same IP can both read
 *  the same stale count before either write lands, so both get admitted, and Workers KV's
 *  eventual consistency (writes can take up to ~60s to propagate globally) makes this worse under
 *  a distributed burst. This makes the cap soft/best-effort — enough to deter casual abuse — not
 *  a hard guarantee; a true hard limit would need an atomic counter (e.g. a Durable Object). */
export async function isRateLimited(kv: InboxKV, ip: string): Promise<boolean> {
  const key = `ratelimit:${ip}`;
  const raw = await kv.get(key);
  const count = raw ? Number.parseInt(raw, 10) : 0;
  if (count >= RATE_LIMIT_MAX_PER_WINDOW) return true;
  await kv.put(key, String(count + 1), { expirationTtl: RATE_LIMIT_WINDOW_SECONDS });
  return false;
}

async function parseRequestFields(request: Request): Promise<Record<string, string> | null> {
  const contentType = request.headers.get("content-type") ?? "";
  if (contentType.includes("application/json")) {
    const body = (await request.json()) as Record<string, unknown>;
    return Object.fromEntries(Object.entries(body).map(([k, v]) => [k, String(v)]));
  }
  if (
    contentType.includes("application/x-www-form-urlencoded") ||
    contentType.includes("multipart/form-data")
  ) {
    const form = await request.formData();
    return Object.fromEntries([...form.entries()].map(([k, v]) => [k, String(v)]));
  }
  return null;
}

/** Max payload bytes per RFC 2047 "B" encoded-word: the spec caps a whole encoded-word
 *  (`=?UTF-8?B?...?=`) at 75 characters. `"=?UTF-8?B?"` (10) + `"?="` (2) leaves 63 for the
 *  base64 portion; 60 of those (a multiple of 4, so no padding) decode to exactly 45 bytes —
 *  keeping each word at 72 characters, under the cap with room to spare. */
const MAX_ENCODED_WORD_PAYLOAD_BYTES = 45;

/** RFC 2047 "B" (base64) encoded-word(s), folded per RFC 2047 §2's 75-char-per-word cap (a
 *  near-`MAX_SUBJECT_LENGTH` subject would otherwise produce one oversized word some strict
 *  MTAs reject or mangle) — consecutive words separated only by folding whitespace (`\r\n `),
 *  which RFC 2047 defines as insignificant between adjacent encoded-words, so decoders
 *  reconstruct the original value across the fold. Every byte of `value` round-trips through
 *  the base64 alphabet only, so an anonymous submitter's raw subject can never inject a CR/LF —
 *  or anything else — into the header it's placed in, regardless of content (#1570). Each word's
 *  payload ends on a UTF-8 character boundary so no chunk decodes to invalid UTF-8. */
function encodeMimeHeaderValue(value: string): string {
  const bytes = new TextEncoder().encode(value);
  const words: string[] = [];
  let start = 0;
  do {
    let end = Math.min(start + MAX_ENCODED_WORD_PAYLOAD_BYTES, bytes.length);
    // Back off while the next byte is a UTF-8 continuation byte (10xxxxxx) so a multi-byte
    // character never splits across two encoded-words.
    while (end < bytes.length && (bytes[end]! & 0xc0) === 0x80) end--;
    let binary = "";
    for (const byte of bytes.slice(start, end)) binary += String.fromCharCode(byte);
    words.push(`=?UTF-8?B?${btoa(binary)}?=`);
    start = end;
  } while (start < bytes.length);
  return words.join("\r\n ");
}

/** Builds the raw RFC 5322 message `forwardInboxSubmissionByEmail` hands to `EmailMessage`.
 *  `submission.from`/`.message` are anonymous, unvalidated user input — they appear only in the
 *  body (after the blank line separating headers from body), never in a header, so unlike
 *  `.subject` they need no encoding: there's no header-injection surface for body content
 *  regardless of what it contains. Exported for direct unit testing of that injection-safety
 *  property. */
export function buildInboxForwardRaw(
  fromAddress: string,
  toAddress: string,
  submission: InboxFields & { id: string; receivedAt: string },
): string {
  const headers = [
    `From: "Site Inbox" <${fromAddress}>`,
    `To: <${toAddress}>`,
    `Subject: ${encodeMimeHeaderValue(`[Inbox] ${submission.subject}`)}`,
    "MIME-Version: 1.0",
    'Content-Type: text/plain; charset="utf-8"',
    "Content-Transfer-Encoding: 8bit",
  ];
  const body = [
    "New /inbox submission — replies go directly to the sender, this address doesn't relay them.",
    "",
    `From: ${submission.from}`,
    `Subject: ${submission.subject}`,
    "",
    submission.message,
    "",
    "—",
    `Submission ID: ${submission.id}`,
    `Received: ${submission.receivedAt}`,
  ];
  return `${headers.join("\r\n")}\r\n\r\n${body.join("\r\n")}\r\n`;
}

/** Best-effort — callers must swallow rejections; see `handleInbox`'s comment on why an email
 *  failure must never affect the KV/git capture path. */
async function forwardInboxSubmissionByEmail(
  sendEmail: SendEmail,
  toAddress: string,
  siteHostname: string,
  submission: InboxFields & { id: string; receivedAt: string },
): Promise<void> {
  const fromAddress = `inbox@${siteHostname}`;
  const raw = buildInboxForwardRaw(fromAddress, toAddress, submission);
  await sendEmail.send(new EmailMessage(fromAddress, toAddress, raw));
}

export async function handleInbox(
  request: Request,
  env: Pick<WorkerEnv, "INBOX_KV" | "SEND_EMAIL" | "INBOX_FORWARD_EMAIL">,
): Promise<Response> {
  if (request.method !== "POST") return new Response("Method Not Allowed", { status: 405 });
  if (!env.INBOX_KV) return new Response("Inbox capture not configured", { status: 500 });

  const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
  if (await isRateLimited(env.INBOX_KV, ip)) {
    return new Response(null, { status: 429 });
  }

  const fields = await parseRequestFields(request);
  if (!fields) return new Response("Unsupported Content-Type", { status: 400 });

  // Honeypot: a hidden form field real visitors never fill in. Silently accept-and-drop so bots
  // get no signal they were caught, rather than a 4xx they could learn from.
  if ((fields.website ?? "").trim() !== "") {
    return new Response(null, { status: 202 });
  }

  const validated = validateInboxFields(fields);
  if (!validated) {
    return new Response("Missing or invalid field: subject, from, message", { status: 400 });
  }

  const id = crypto.randomUUID();
  const submission = { id, ...validated, receivedAt: new Date().toISOString() };
  await env.INBOX_KV.put(`inbox:${id}`, JSON.stringify(submission));

  // #1570: additionally forwards to the owner's email, reconciling #587 with the email-as-DM
  // decision — KV above (→ git commit-back via `InboxSubmissionSync`) stays the structured
  // record regardless of whether this succeeds. Best-effort only: a bounced/misconfigured
  // destination address or an Email Routing binding that isn't fully verified yet must never
  // roll back the KV write or turn a successfully captured submission into an error response.
  if (env.SEND_EMAIL && env.INBOX_FORWARD_EMAIL) {
    try {
      await forwardInboxSubmissionByEmail(
        env.SEND_EMAIL, env.INBOX_FORWARD_EMAIL, new URL(request.url).hostname, submission,
      );
    } catch (error) {
      console.error("inbox: failed to forward submission by email", error);
    }
  }

  return new Response(null, { status: 202 });
}

/**
 * RFC 9727 API Catalog (#1659) — one of Cloudflare's Agent Readiness checks (#1278/#1326).
 * Advertises whichever of this site's agent-usable APIs are actually live as a
 * `linkset+json` document at `/.well-known/api-catalog`. Each entry's gate mirrors the exact
 * "actually live" binding check its own handler already performs (`handleWebmentionReceive`,
 * `handleMicropub`, `handleWebSubHub`, `activityPubConfig`), so an un-provisioned protocol never
 * appears here — the catalog can never advertise capability this Worker doesn't actually serve.
 * IndieAuth is unconditional, mirroring `handleOAuthProtectedResourceMetadata`'s own reasoning:
 * its endpoints are always live for every site.
 */
function handleApiCatalog(request: Request, env: WorkerEnv): Response {
  const baseUrl = new URL(request.url).origin;
  const serviceDesc = (href: string) => [{ href }];
  const linkset: Record<string, unknown>[] = [
    {
      anchor: `${baseUrl}/.well-known/oauth-authorization-server`,
      "service-desc": serviceDesc("https://indieauth.spec.indieweb.org/"),
    },
  ];
  if (env.WEBMENTION_QUEUE) {
    linkset.push({
      anchor: `${baseUrl}/webmention`,
      "service-desc": serviceDesc("https://www.w3.org/TR/webmention/"),
    });
  }
  if (env.MICROPUB_DB && env.MEDIA && env.AUTH_DB && env.TOKEN_SIGNING_KEY) {
    linkset.push({
      anchor: `${baseUrl}/micropub`,
      "service-desc": serviceDesc("https://www.w3.org/TR/micropub/"),
    });
  }
  if (env.WEBSUB_QUEUE && env.WEBSUB_DB && websubOrigin(env)) {
    linkset.push({
      anchor: `${baseUrl}/websub`,
      "service-desc": serviceDesc("https://www.w3.org/TR/websub/"),
    });
  }
  if (activityPubConfig(request, env)) {
    linkset.push(
      {
        anchor: `${baseUrl}/users/${ACTIVITYPUB_USERNAME}`,
        "service-desc": serviceDesc("https://www.w3.org/TR/activitypub/"),
      },
      {
        anchor: `${baseUrl}/.well-known/webfinger`,
        "service-desc": serviceDesc("https://www.rfc-editor.org/rfc/rfc7033"),
      },
      {
        anchor: `${baseUrl}/.well-known/nodeinfo`,
        "service-desc": serviceDesc("https://nodeinfo.diaspora.software/"),
      },
    );
  }
  return new Response(JSON.stringify({ linkset }), {
    headers: { "content-type": "application/linkset+json" },
  });
}

/** One dynamic route this Worker serves — the handler-side mirror of a catalog route claim. */
export interface WorkerRoute {
  /** Absolute claimed path, e.g. `"/.well-known/oauth-authorization-server"`. */
  path: string;
  /** `exact` matches only `path`; `prefix` additionally matches `path` + `/…` descendants. */
  match: "exact" | "prefix";
  /** Declared methods. HEAD is served only when listed alongside GET — the dispatcher mirrors
   *  GET's status/headers without a body and never hands handlers a raw HEAD request (catalog
   *  claims enforce the same GET pairing app-side). */
  methods: readonly string[];
  handler: (request: Request, env: WorkerEnv, ctx: ExecutionContext) => Promise<Response> | Response;
}

export const ROUTES: readonly WorkerRoute[] = [
  {
    // RFC 8414 authorization-server metadata (linked via rel=indieauth-metadata in BaseLayout).
    path: "/.well-known/oauth-authorization-server",
    match: "exact",
    methods: ["GET", "HEAD"],
    handler: (request, env, ctx) => indieAuthHandler(request, env)(request, env, ctx),
  },
  {
    // RFC 9728 protected-resource metadata (#1577) — see handleOAuthProtectedResourceMetadata.
    path: "/.well-known/oauth-protected-resource",
    match: "exact",
    methods: ["GET", "HEAD"],
    handler: (request) => handleOAuthProtectedResourceMetadata(request),
  },
  {
    // RFC 9727 API Catalog (#1659) — see handleApiCatalog.
    path: "/.well-known/api-catalog",
    match: "exact",
    methods: ["GET", "HEAD"],
    handler: (request, env) => handleApiCatalog(request, env),
  },
  {
    // GET renders/redirects the authorization request; POST redeems an authorization code for
    // profile information (IndieAuth authorization-endpoint code exchange).
    path: "/authorize",
    match: "exact",
    methods: ["GET", "POST"],
    handler: (request, env, ctx) => indieAuthHandler(request, env)(request, env, ctx),
  },
  {
    // POST is the token grant; GET is IndieAuth token-endpoint access-token verification.
    path: "/token",
    match: "exact",
    methods: ["GET", "POST"],
    handler: (request, env, ctx) => indieAuthHandler(request, env)(request, env, ctx),
  },
  {
    path: "/revocation",
    match: "exact",
    methods: ["POST"],
    handler: (request, env, ctx) => indieAuthHandler(request, env)(request, env, ctx),
  },
  {
    path: "/indieauth/consent",
    match: "exact",
    methods: ["POST"],
    handler: (request, env) => handleIndieAuthConsent(request, env),
  },
  {
    // Bridges the IndieAuth redirect into the Anglesite app's custom scheme (#868) — see
    // `handleIndieAuthAppCallback`.
    path: "/indieauth/app-callback",
    match: "exact",
    methods: ["GET"],
    handler: (request) => handleIndieAuthAppCallback(request),
  },
  {
    // Solid-OIDC discovery (identity layer for `@dwk/solid-pod`). Authority-bound to this fixed
    // path regardless of `mountPath` — see `resolveConfig` in `@dwk/solid-oidc`.
    path: "/.well-known/openid-configuration",
    match: "exact",
    methods: ["GET", "HEAD"],
    handler: (request, env, ctx) => handleSolidOidc(request, env, ctx),
  },
  {
    path: "/oidc/jwks",
    match: "exact",
    methods: ["GET", "HEAD"],
    handler: (request, env, ctx) => handleSolidOidc(request, env, ctx),
  },
  {
    path: "/oidc/authorize",
    match: "exact",
    methods: ["GET"],
    handler: (request, env, ctx) => handleSolidOidc(request, env, ctx),
  },
  {
    path: "/oidc/token",
    match: "exact",
    methods: ["POST"],
    handler: (request, env, ctx) => handleSolidOidc(request, env, ctx),
  },
  {
    path: "/oidc/consent",
    match: "exact",
    methods: ["POST"],
    handler: (request, env) => handleSolidOidcConsent(request, env),
  },
  {
    // Solid Pod LDP storage (identity storage layer). No separate exact entry — a single
    // `prefix` entry already matches the bare path too, per `matchRoute`'s
    // `pathname === route.path` check.
    path: "/pod",
    match: "prefix",
    methods: ["GET", "PUT", "POST", "PATCH", "DELETE", "OPTIONS", "HEAD"],
    handler: (request, env, ctx) => handleSolidPod(request, env, ctx),
  },
  {
    // WebDAV façade over the same pod (RFC 4918 Class 2 — mount as a network drive).
    path: "/dav",
    match: "prefix",
    methods: ["GET", "PUT", "DELETE", "PROPFIND", "PROPPATCH", "MKCOL", "COPY", "MOVE", "LOCK", "UNLOCK", "OPTIONS", "HEAD"],
    handler: (request, env, ctx) => handleWebdav(request, env, ctx),
  },
  {
    // Owner-gated WebDAV app-password mint/list/revoke endpoint.
    path: "/dav-credentials",
    match: "exact",
    methods: ["GET", "POST", "DELETE"],
    handler: (request, env, ctx) => handleWebdavCredentials(request, env, ctx),
  },
  {
    path: "/inbox",
    match: "exact",
    methods: ["POST"],
    handler: (request, env) => handleInbox(request, env),
  },
  {
    // Inbound Webmention receiver (V-3.1, #359): POST source+target, validate, enqueue, 202.
    path: "/webmention",
    match: "exact",
    methods: ["POST"],
    handler: (request, env, ctx) => handleWebmentionReceive(request, env, ctx),
  },
  {
    // Micropub create/update/delete + q=config/q=source/q=syndicate-to queries (V-3.2, #360).
    path: "/micropub",
    match: "exact",
    methods: ["GET", "POST"],
    handler: (request, env, ctx) => handleMicropub(request, env, ctx),
  },
  {
    // Media endpoint upload (V-3.2, #360). GET-on-bare-/media is not served (matches
    // @dwk/micropub's default extensions.proposed: false — GET is only the media *retrieval*
    // path below, under /media/<key>, not the collection root).
    path: "/media",
    match: "exact",
    methods: ["POST"],
    handler: (request, env, ctx) => handleMicropub(request, env, ctx),
  },
  {
    // Media retrieval by key (V-3.2, #360).
    path: "/media",
    match: "prefix",
    methods: ["GET", "HEAD"],
    handler: (request, env, ctx) => handleMicropub(request, env, ctx),
  },
  {
    // Actor document + outbox/followers/following collections (V-4.1, #363). No trailing slash:
    // `matchRoute`'s prefix check appends its own `/` to `path` before comparing, so a `path` that
    // already ends in `/` would build a double-slash prefix ("/users//") that never matches
    // "/users/site" — see the other prefix entries above (e.g. "/media") for the same convention.
    path: "/users",
    match: "prefix",
    methods: ["GET", "POST", "HEAD"],
    handler: (request, env, ctx) => handleActivityPub(request, env, ctx),
  },
  {
    path: "/.well-known/nodeinfo",
    match: "exact",
    methods: ["GET", "HEAD"],
    handler: (request, env, ctx) => handleActivityPub(request, env, ctx),
  },
  {
    // No trailing slash — see the "/users" comment above for why.
    path: "/nodeinfo",
    match: "prefix",
    methods: ["GET", "HEAD"],
    handler: (request, env, ctx) => handleActivityPub(request, env, ctx),
  },
  {
    // WebSub hub (V-3.3, #361): POST hub.mode=subscribe|unsubscribe|publish, validate, enqueue, 202.
    path: "/websub",
    match: "exact",
    methods: ["POST"],
    handler: (request, env, ctx) => handleWebSubHub(request, env, ctx),
  },
  {
    // Microsub reader (V-4.3, #365): action=channels|follow|unfollow|timeline|search|preview.
    path: "/microsub",
    match: "exact",
    methods: ["GET", "POST"],
    handler: (request, env, ctx) => handleMicrosub(request, env, ctx),
  },
  {
    // WebFinger discovery (V-4.4, #366): resolve acct:site@<host> to the ActivityPub actor.
    path: "/.well-known/webfinger",
    match: "exact",
    methods: ["GET", "HEAD"],
    handler: (request, env, ctx) => handleWebFinger(request, env, ctx),
  },
  {
    // IndieAuth relying-party sign-in for a visitor proving their own site's identity (#1568):
    // no `me` renders the form, `me` present discovers that site's authorization_endpoint and
    // redirects there. See gated-content.ts's design doc for the full flow.
    path: "/contacts/signin",
    match: "exact",
    methods: ["GET"],
    handler: (request, env) => handleReaderSignin(request, env),
  },
  {
    // OAuth redirect target for the sign-in above: redeems the code, verifies identity, checks
    // the pushed allowlist, and starts a reader session (#1568).
    path: "/contacts/callback",
    match: "exact",
    methods: ["GET"],
    handler: (request, env) => handleReaderCallback(request, env),
  },
  {
    // Private h-feed of restricted (`visibility: contacts`) posts, gated the same way as a
    // restricted permalink (#1568).
    path: "/contacts/feed",
    match: "exact",
    methods: ["GET", "HEAD"],
    handler: (request, env) => handlePrivateFeed(request, env),
  },
  {
    // Read-only MCP server (#1576): gated behind experimental.mcp, degrades to a plain 404
    // when off — see worker/mcp-server.ts.
    path: "/mcp",
    match: "exact",
    methods: ["GET", "POST", "HEAD"],
    handler: (request, env, ctx) => handleMcp(request, env, ctx),
  },
];

export function matchRoute(pathname: string, routes: readonly WorkerRoute[] = ROUTES): WorkerRoute | null {
  for (const route of routes) {
    if (pathname === route.path) return route;
    if (route.match === "prefix" && pathname.startsWith(`${route.path}/`)) return route;
  }
  return null;
}

/** A protocol-grade 404: correct status, no HTML error page, nothing for a client to mis-parse. */
function notFound(): Response {
  return new Response("Not Found", {
    status: 404,
    headers: { "content-type": "text/plain; charset=utf-8", "x-content-type-options": "nosniff" },
  });
}

/** True for the bare `/.well-known` directory and anything under it, case-insensitively — the
 *  case fold exists so `/.Well-Known/...` variants get the namespace's true-404 policy instead
 *  of leaking to an HTML asset 404 (claimed routes themselves match case-sensitively). */
function isWellKnownNamespace(pathname: string): boolean {
  const lower = pathname.toLowerCase();
  return lower === "/.well-known" || lower === "/.well-known/" || lower.startsWith("/.well-known/");
}

const RUNNING_EXPERIMENT = (experimentsArtifact as ExperimentsArtifact).experiment;

export default {
  async fetch(request: Request, env: WorkerEnv, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    const pathname = url.pathname;

    // Malformed percent-encoding can't name any claimed route or asset; answer plainly instead
    // of handing it to an HTML 404 page.
    let decoded: string | null;
    try {
      decoded = decodeURIComponent(pathname);
    } catch {
      decoded = null;
    }
    if (decoded === null) {
      return notFound();
    }

    // Experiment assignment + serving (#1270 slice 1): a request on the running experiment's own
    // page is fully owned by this branch — it never reaches ROUTES or asset-first serving.
    if (RUNNING_EXPERIMENT && pathname === RUNNING_EXPERIMENT.page) {
      return handleExperimentPageRequest(request, env, ctx, RUNNING_EXPERIMENT);
    }

    // Client-side goal beacon endpoint (#1270 slice 2): a fixed system path, not derived from
    // config, so it's checked unconditionally — `handleGoalBeaconRequest` itself no-ops when
    // there's no running experiment or its goal isn't client-side.
    if (pathname === GOAL_ENDPOINT_PATH) {
      return handleGoalBeaconRequest(request, env, ctx, RUNNING_EXPERIMENT);
    }

    let response: Response;
    const route = matchRoute(pathname);
    if (route) {
      const mirrorsGet = request.method === "HEAD" && route.methods.includes("HEAD") && route.methods.includes("GET");
      if (mirrorsGet) {
        // Query string rides along in `request.url`; only the method changes.
        const getResponse = await route.handler(
          new Request(request.url, { method: "GET", headers: request.headers }),
          env,
          ctx,
        );
        response = new Response(null, {
          status: getResponse.status,
          statusText: getResponse.statusText,
          headers: getResponse.headers,
        });
      } else if (!route.methods.includes(request.method)) {
        response = new Response("Method Not Allowed", {
          status: 405,
          headers: { allow: route.methods.join(", "), "content-type": "text/plain; charset=utf-8" },
        });
      } else {
        response = await route.handler(request, env, ctx);
      }
    } else if (isWellKnownNamespace(pathname) || isWellKnownNamespace(decoded)) {
      // Unclaimed well-known names, the bare directory, and case/trailing-slash or encoded
      // variants (checked post-decode so `/%2Ewell-known/...` can't slip past) return a true 404
      // rather than falling through to an HTML asset 404. Genuinely static well-known files (e.g.
      // security.txt) are served asset-first and never reach this Worker.
      return notFound();
    } else {
      const assets = env.ASSETS;
      if (!assets) {
        return new Response("No assets binding configured", { status: 500 });
      }
      response = await assets.fetch(request);
      // A restricted (`visibility: contacts`) post is never in the static build (#1568), so its
      // permalink always misses here — give the read gate a chance to serve it (or a uniform 403
      // for an unauthenticated/unauthorized visitor) before falling back to the plain asset 404.
      if (response.status === 404) {
        const gated = await handleGatedFallback(request, env, pathname);
        if (gated !== null) response = gated;
      }
    }

    // Goal-signal conversion counting (#1270 slice 1): applied to whatever response the branches
    // above produced, so a pageview goal still renders its page normally and a route goal still
    // returns its handler's real response — this only ever adds a Set-Cookie header.
    if (RUNNING_EXPERIMENT && matchesGoal(RUNNING_EXPERIMENT, pathname, request.method)) {
      response = await applyGoalConversion(request, env, ctx, RUNNING_EXPERIMENT, response);
    }
    return response;
  },

  // Async queue work, present unconditionally; no-ops for sites without the matching feature
  // provisioned. Three queues deliver here — Webmention verification (V-3.1, #359), WebSub
  // verification/distribution/delivery (V-3.3, #361), and Microsub feed-poll fan-out (V-4.3,
  // #365) — dispatched on the queue's name: Anglesite provisions deterministic names
  // (`<site>-webmention`, `<site>-websub`, `<site>-microsub`). All matches are positive (rather
  // than "webmention = anything that isn't -websub") so a future queue-backed feature can't get
  // silently misrouted into another's consumer.
  async queue(
    batch: MessageBatch<WebmentionJob | WebSubJob | MicrosubJob>,
    env: WorkerEnv,
    ctx: ExecutionContext,
  ): Promise<void> {
    if (batch.queue.endsWith("-websub")) {
      return handleWebSubQueue(batch as MessageBatch<WebSubJob>, env, ctx);
    }
    if (batch.queue.endsWith("-webmention")) {
      return handleWebmentionQueue(batch as MessageBatch<WebmentionJob>, env, ctx);
    }
    if (batch.queue.endsWith("-microsub")) {
      return handleMicrosubQueue(batch as MessageBatch<MicrosubJob>, env, ctx);
    }
    return Promise.resolve();
  },

  // Cron Trigger, present unconditionally; dispatched by `controller.cron`, mirroring how
  // `queue()` above dispatches on the queue-name suffix. Two schedules land here today:
  // Microsub's feed poller (V-4.3, #365, "*/15 * * * *") and solid-pod's R2 garbage-collection
  // cron ("*/5 * * * *"). Both no-op for a site without the matching feature provisioned.
  async scheduled(
    controller: ScheduledController,
    env: WorkerEnv,
    ctx: ExecutionContext,
  ): Promise<void> {
    if (controller.cron === "*/5 * * * *") {
      return handleSolidPodGcScheduled(controller, env, ctx);
    }
    return handleMicrosubScheduled(controller, env, ctx);
  },
} satisfies ExportedHandler<WorkerEnv, WebmentionJob | WebSubJob | MicrosubJob>;
