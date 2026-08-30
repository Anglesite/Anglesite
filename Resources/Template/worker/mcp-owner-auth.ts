/**
 * Auth bridge for the MCP owner tools (#1578, phase 2 of the #1576 site MCP server): resolves an
 * incoming `/mcp` request's bearer token into `@dwk/mcp`'s `McpAuthContext` (granted scopes +
 * subject), reusing exactly the same verification `@dwk/micropub`'s own HTTP endpoint trusts —
 * `@dwk/indieauth`'s `verifyAccessToken` (signature/`iss`/time window) plus its issued-token
 * store's revocation check (`isTokenActive`). DPoP proof-of-possession binding and replay
 * rejection are `@dwk/mcp`'s `createDpopBearerAuthenticator`'s job, not this file's — see
 * `optionalDpopAuthenticator` below for why a thin wrapper around it is still needed.
 *
 * @see docs/superpowers/specs/2026-08-30-mcp-owner-tools-design.md
 */
import { createIndieAuthStore, verifyAccessToken } from "@dwk/indieauth";
import {
  createDpopBearerAuthenticator,
  tokenFromAuthHeader,
  type DpopReplayStore,
  type IntrospectedToken,
  type McpAuthContext,
} from "@dwk/mcp";
import type { WorkerEnv } from "./worker.ts";

/**
 * `TokenIntrospector` for `createDpopBearerAuthenticator`: verify the token's HS256 signature,
 * issuer, and time window, then check it hasn't been revoked. Mirrors `@dwk/micropub`'s own
 * `authorize()` internals exactly (same two library calls, same `AUTH_DB`-backed store) so an MCP
 * caller and an HTTP Micropub client get identical token-acceptance behavior.
 */
export async function introspectMcpToken(
  token: string,
  env: Pick<WorkerEnv, "TOKEN_SIGNING_KEY" | "AUTH_DB">,
  baseUrl: string,
): Promise<IntrospectedToken | null> {
  const result = await verifyAccessToken(token, env.TOKEN_SIGNING_KEY, { issuer: baseUrl });
  if (!result.valid) return null;
  const store = createIndieAuthStore({ AUTH_DB: env.AUTH_DB });
  const now = Math.floor(Date.now() / 1000);
  if (!(await store.isTokenActive(result.claims.jti, now))) return null;
  return { active: true, scope: result.claims.scope, sub: result.claims.sub, cnf: result.claims.cnf };
}

/**
 * D1-backed `DpopReplayStore` for `/mcp`'s own DPoP proofs — a separate table
 * (`mcp_dpop_proofs`, `worker/migrations/0003_mcp_dpop_replay.sql`) from `@dwk/micropub`'s own
 * replay tracking in `MICROPUB_DB`: `/mcp` and `/micropub`/`/media` are different `htu`s, so a
 * proof accepted for one must never satisfy the other. The `CREATE TABLE IF NOT EXISTS` runs
 * before every insert — a cheap no-op once the migration has applied in production, and what
 * makes the table exist at all under the Miniflare test pool, which never runs
 * `worker/migrations/*.sql` (only `wrangler d1 migrations apply` does, in
 * `SocialWorkerProvisionCommand`) — `AUTH_DB`'s own schema in tests is likewise created
 * programmatically, via `createIndieAuthStore(...).init()` in `worker.test.ts`'s `beforeEach`.
 */
export function createD1McpDpopReplayStore(db: D1Database): DpopReplayStore {
  return {
    async recordProof(jti: string, expiresAt: number, _now: number): Promise<boolean> {
      await db.exec(
        "CREATE TABLE IF NOT EXISTS mcp_dpop_proofs (jti TEXT PRIMARY KEY, expires_at INTEGER NOT NULL)",
      );
      const result = await db
        .prepare("INSERT OR IGNORE INTO mcp_dpop_proofs (jti, expires_at) VALUES (?, ?)")
        .bind(jti, expiresAt)
        .run();
      return (result.meta.changes ?? 0) > 0;
    },
  };
}

/**
 * Wraps `createDpopBearerAuthenticator`'s authenticator so a request carrying *no* bearer token
 * resolves to zero granted scopes instead of throwing `McpAuthError`. The library's authenticator
 * throws unconditionally on a missing token (verified by reading `auth.js` directly — the `.d.ts`
 * alone doesn't show this), and `createMcp` maps any thrown `McpAuthError` to a blanket `401` for
 * the *whole* request before it ever reaches `tools/list`/`tools/call`. Setting `authenticate` to
 * the library's authenticator unwrapped would 401 every unauthenticated call, including the public
 * read-only tools — a regression from phase 1. A *present-but-invalid* token still throws through
 * to a real 401 unchanged: only an actual auth attempt can fail.
 */
export function optionalDpopAuthenticator(
  bearer: (request: Request) => Promise<McpAuthContext>,
): (request: Request) => Promise<McpAuthContext> {
  return async (request: Request): Promise<McpAuthContext> =>
    tokenFromAuthHeader(request) ? bearer(request) : { scopes: [] };
}

/** Builds the full `authenticate` hook for `createMcp`, wiring this file's introspector + replay
 *  store through `createDpopBearerAuthenticator` and the optional-token wrapper above. */
export function createMcpAuthenticator(
  env: Pick<WorkerEnv, "TOKEN_SIGNING_KEY" | "AUTH_DB">,
  baseUrl: string,
): (request: Request) => Promise<McpAuthContext> {
  const bearer = createDpopBearerAuthenticator({
    introspectToken: (token) => introspectMcpToken(token, env, baseUrl),
    replayStore: createD1McpDpopReplayStore(env.AUTH_DB),
  });
  return optionalDpopAuthenticator(bearer);
}
