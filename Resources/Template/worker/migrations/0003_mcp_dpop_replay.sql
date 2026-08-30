-- MCP owner-tools DPoP proof replay tracking (#1578). Separate from @dwk/micropub's own
-- replay tracking in MICROPUB_DB: /mcp and /micropub/media are different `htu`s, so a proof
-- accepted for one endpoint must never satisfy the other. Kept as a Wrangler D1 migration,
-- matching 0001_indieauth.sql/0002_experiments.sql, because the request handler intentionally
-- does not mutate its schema at startup; SocialWorkerProvisionCommand applies this (via the
-- existing AUTH_DB migrations-apply call, since Micropub requires indieauth) before deploying
-- the endpoint.

CREATE TABLE IF NOT EXISTS mcp_dpop_proofs (
  jti TEXT PRIMARY KEY,
  expires_at INTEGER NOT NULL
);
