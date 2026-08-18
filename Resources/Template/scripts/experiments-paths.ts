/**
 * Fixed system paths for edge A/B testing's client-side goal beacon (#1270 slice 2): the
 * first-party static script `BaseLayout.astro` conditionally injects, and the POST endpoint it
 * reports to (`worker/experiments.ts`'s `handleGoalBeaconRequest`, dispatched by `worker.ts`).
 *
 * Kept in their own zero-dependency module — rather than alongside the rest of the config reader
 * in `anglesite-config.ts`, which imports `node:fs` — so the Cloudflare Worker bundle can import
 * the endpoint path without dragging a Node-only module into it.
 */
export const GOAL_BEACON_SCRIPT_PATH = "/x/goal-beacon.js";
export const GOAL_ENDPOINT_PATH = "/x/goal";
