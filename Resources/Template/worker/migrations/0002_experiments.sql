-- Edge A/B testing event counters (#1270 slice 1). One row per
-- (experiment_id, variant_id, metric, day); worker/experiments.ts's incrementExperimentCounter
-- upserts with `ON CONFLICT ... DO UPDATE SET n = n + 1` so only first-visit and
-- first-conversion events ever write. Kept as a Wrangler D1 migration, matching
-- 0001_indieauth.sql, because the request handler intentionally does not mutate its schema at
-- startup — SocialWorkerProvisionCommand (Swift, slice 3) applies migrations before deploying.

CREATE TABLE IF NOT EXISTS experiment_counters (
  experiment_id TEXT NOT NULL,
  variant_id TEXT NOT NULL,
  metric TEXT NOT NULL,
  day TEXT NOT NULL,
  n INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (experiment_id, variant_id, metric, day)
);
