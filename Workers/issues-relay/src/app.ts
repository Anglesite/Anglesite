// Workers Issues relay (#2095 slice 2), served at issues.anglesite.dwk.io. `worker.ts` is the
// entry module; everything lives here because workerd treats every named export of the entry
// module as an entrypoint and refuses to start on a non-handler one.
// Design: docs/superpowers/specs/2026-09-30-worker-issues-autofix-design.md §4–§5.
//
//   POST   /sites              register or renew a site (Bearer REGISTRATION_TOKEN)
//   DELETE /sites/:uuid        revoke a site (Bearer <the site's webhook secret>)
//   POST   /hook/:uuid         a site's Workers Issues automation delivery (cf-webhook-auth)
//
// The relay never stores or logs a hostname, account id, or payload content: a site is its UUID
// plus the SHA-256 of its webhook secret, and the KV TTL on that record is its 30-day expiry.

import { bearer, matchesHash, newSecret, secretsEqual, sha256Hex } from "./auth.js";
import { GitHubClient } from "./github.js";
import { handleDelivery, type RelayContext, type SiteRecord } from "./relay.js";

export interface Env {
  SITES: KVNamespace;
  STATE: KVNamespace;
  TARGET_REPO: string;
  ALLOWED_HOST_SUFFIXES: string;
  DAILY_NEW_ISSUE_CAP: string;
  DAILY_SITE_DELIVERY_CAP: string;
  REGISTRATION_TOKEN: string;
  GITHUB_APP_ID: string;
  GITHUB_INSTALLATION_ID: string;
  GITHUB_APP_PRIVATE_KEY: string;
}

export const REGISTRATION_TTL_SECONDS = 30 * 24 * 60 * 60;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const COMMIT = /^[0-9a-f]{7,40}$/i;
/** A delivery bigger than this isn't an issue summary; refuse it before parsing. */
const MAX_BODY_BYTES = 256 * 1024;

/** Test seam: the GitHub client and clock the relay uses. */
export interface Dependencies {
  github?: RelayContext["github"];
  now?: () => number;
}

export function createWorker(deps: Dependencies = {}) {
  return {
    async fetch(request: Request, env: Env): Promise<Response> {
      const { pathname } = new URL(request.url);
      const segments = pathname.split("/").filter(Boolean);

      if (segments[0] === "sites" && segments.length === 1 && request.method === "POST") {
        return register(request, env);
      }
      if (segments[0] === "sites" && segments.length === 2 && request.method === "DELETE") {
        return revoke(request, env, segments[1]!);
      }
      if (segments[0] === "hook" && segments.length === 2 && request.method === "POST") {
        return deliver(request, env, segments[1]!, deps);
      }
      return new Response("not found", { status: 404 });
    },
  } satisfies ExportedHandler<Env>;
}

/**
 * Registers or renews a site. The hostname is checked against the allowlist here and then
 * discarded (design §4). Renewal — the same site presenting its current secret in
 * `x-site-secret` — slides the 30-day expiry without rotating the secret, so the Cloudflare
 * automation keeps working; any other call issues a fresh secret.
 */
async function register(request: Request, env: Env): Promise<Response> {
  if (!(await secretsEqual(bearer(request), env.REGISTRATION_TOKEN))) return json({ error: "unauthorized" }, 401);
  const body = (await request.json().catch(() => null)) as {
    siteID?: unknown;
    hostname?: unknown;
    catalogCommit?: unknown;
  } | null;
  const siteID = typeof body?.siteID === "string" && UUID.test(body.siteID) ? body.siteID.toLowerCase() : null;
  const hostname = typeof body?.hostname === "string" ? body.hostname.toLowerCase() : null;
  if (!siteID || !hostname) return json({ error: "siteID (UUID) and hostname are required" }, 400);
  if (!hostAllowed(hostname, env.ALLOWED_HOST_SUFFIXES)) return json({ error: "hostname not allowed" }, 403);
  const catalogCommit =
    typeof body?.catalogCommit === "string" && COMMIT.test(body.catalogCommit) ? body.catalogCommit.toLowerCase() : undefined;

  const existing = await env.SITES.get<SiteRecord>(siteID, "json");
  const renewing = existing !== null && (await matchesHash(request.headers.get("x-site-secret"), existing.secretHash));
  const secret = renewing ? undefined : newSecret();
  const record: SiteRecord = {
    secretHash: renewing ? existing.secretHash : await sha256Hex(secret!),
    catalogCommit,
    registeredAt: new Date().toISOString(),
  };
  await env.SITES.put(siteID, JSON.stringify(record), { expirationTtl: REGISTRATION_TTL_SECONDS });
  const expiresAt = new Date(Date.now() + REGISTRATION_TTL_SECONDS * 1000).toISOString();
  return json({ siteID, hookPath: `/hook/${siteID}`, expiresAt, ...(secret ? { secret } : { renewed: true }) });
}

async function revoke(request: Request, env: Env, siteID: string): Promise<Response> {
  const site = UUID.test(siteID) ? await env.SITES.get<SiteRecord>(siteID.toLowerCase(), "json") : null;
  if (!site || !(await matchesHash(bearer(request), site.secretHash))) return json({ error: "unauthorized" }, 401);
  await env.SITES.delete(siteID.toLowerCase());
  return new Response(null, { status: 204 });
}

async function deliver(request: Request, env: Env, siteID: string, deps: Dependencies): Promise<Response> {
  const site = UUID.test(siteID) ? await env.SITES.get<SiteRecord>(siteID.toLowerCase(), "json") : null;
  // Unknown, expired (KV TTL) and wrong-secret all look the same to the caller.
  if (!site || !(await matchesHash(request.headers.get("cf-webhook-auth"), site.secretHash))) {
    return json({ error: "unauthorized" }, 401);
  }
  if (Number(request.headers.get("content-length") ?? "0") > MAX_BODY_BYTES) {
    return json({ filed: false, reason: "too-large" }, 413);
  }
  const text = await request.text();
  if (text.length > MAX_BODY_BYTES) return json({ filed: false, reason: "too-large" }, 413);
  let payload: unknown;
  try {
    payload = JSON.parse(text);
  } catch {
    return json({ filed: false, reason: "not-json" }, 400);
  }

  const outcome = await handleDelivery(
    {
      state: env.STATE,
      github:
        deps.github ??
        new GitHubClient({
          appId: env.GITHUB_APP_ID,
          installationId: env.GITHUB_INSTALLATION_ID,
          privateKeyPem: env.GITHUB_APP_PRIVATE_KEY,
        }),
      targetRepo: env.TARGET_REPO,
      dailyNewIssueCap: Number(env.DAILY_NEW_ISSUE_CAP),
      dailySiteDeliveryCap: Number(env.DAILY_SITE_DELIVERY_CAP),
      now: deps.now ?? Date.now,
    },
    siteID.toLowerCase(),
    site,
    payload,
  );
  // 202 for "accepted, not filed": Cloudflare only needs a 2xx to stop retrying.
  return json(outcome, outcome.filed ? 200 : 202);
}

export function hostAllowed(hostname: string, suffixes: string): boolean {
  if (!/^[a-z0-9.-]{1,253}$/.test(hostname)) return false;
  return suffixes
    .split(",")
    .map((s) => s.trim().toLowerCase())
    .filter(Boolean)
    .some((suffix) => hostname === suffix || hostname.endsWith(`.${suffix}`));
}

function json(value: unknown, status = 200): Response {
  return Response.json(value, { status });
}
