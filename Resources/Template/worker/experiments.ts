/**
 * Edge A/B testing runtime (#1270 slices 1-2): variant assignment/serving and D1 event counting
 * for `worker.ts`'s experiments middleware. `matchesGoal` only ever matches "pageview"/"route" —
 * "scroll"/"visible" are never observed by pathname/method at this layer; they're reported by the
 * first-party goal beacon (`public/x/goal-beacon.js`) via `handleGoalBeaconRequest`'s dedicated
 * `/x/goal` endpoint instead (see `GOAL_ENDPOINT_PATH` in `../scripts/experiments-paths.ts`).
 */

export type ExperimentGoalKind = "pageview" | "route" | "scroll" | "visible";

export interface RunningExperimentGoal {
  kind: ExperimentGoalKind;
  path?: string;
  depth?: number;
  selector?: string;
}

export interface RunningExperimentVariant {
  id: string;
  page: string;
}

export interface RunningExperiment {
  id: string;
  page: string;
  variant: RunningExperimentVariant;
  split: number;
  goal: RunningExperimentGoal;
}

export interface ExperimentsArtifact {
  experiment: RunningExperiment | null;
}

/** The subset of `WorkerEnv` this module needs — kept local rather than importing `WorkerEnv`
 *  from `./worker.ts` so this module has no dependency on that file; `worker.ts` depends on this
 *  module, never the reverse. */
export interface ExperimentsEnv {
  ASSETS?: Fetcher;
  EXPERIMENTS_DB?: D1Database;
}

const ASSIGNMENT_COOKIE_MAX_AGE = 60 * 60 * 24 * 30; // 30 days — matches the experiment-duration rule of thumb.

export function assignmentCookieName(experimentId: string): string {
  return `exp_${experimentId}`;
}

export function conversionCookieName(experimentId: string): string {
  return `exp_${experimentId}_c`;
}

/** Draws an arm by `controlShare` (control's probability). Injectable `random` for deterministic
 *  tests; defaults to `Math.random` for real traffic. */
export function assignVariant(controlShare: number, random: () => number = Math.random): "control" | "variant" {
  return random() < controlShare ? "control" : "variant";
}

/** Minimal `Cookie` header parser — the experiment assignment cookie is the first cookie-handling
 *  code in this codebase, so there's no existing helper to reuse. Tolerant of extra whitespace and
 *  malformed segments; doesn't URL-decode values, matching this module's own cookie values
 *  (opaque ids that never contain reserved characters). */
export function parseCookieHeader(header: string | null): Map<string, string> {
  const cookies = new Map<string, string>();
  if (!header) return cookies;
  for (const part of header.split(";")) {
    const eq = part.indexOf("=");
    if (eq === -1) continue;
    const name = part.slice(0, eq).trim();
    const value = part.slice(eq + 1).trim();
    if (name) cookies.set(name, value);
  }
  return cookies;
}

function serializeCookie(name: string, value: string): string {
  return `${name}=${value}; Path=/; Max-Age=${ASSIGNMENT_COOKIE_MAX_AGE}; SameSite=Lax; HttpOnly; Secure`;
}

/** Today's UTC date as `YYYY-MM-DD` — the `day` bucket every counter aggregates into. */
export function currentDay(): string {
  return new Date().toISOString().slice(0, 10);
}

export async function initExperimentsSchema(db: D1Database): Promise<void> {
  await db.exec(
    "CREATE TABLE IF NOT EXISTS experiment_counters (" +
      "experiment_id TEXT NOT NULL, variant_id TEXT NOT NULL, metric TEXT NOT NULL, day TEXT NOT NULL, " +
      "n INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (experiment_id, variant_id, metric, day))",
  );
}

/** Upserts one counter. A missing `db` (experiments configured but `EXPERIMENTS_DB` not yet
 *  provisioned — the third-enabler wiring is slice 3) no-ops rather than throwing, matching every
 *  other optional-binding feature in `worker.ts`. */
export async function incrementExperimentCounter(
  db: D1Database | undefined,
  experimentId: string,
  variantId: string,
  metric: "impression" | "conversion",
  day: string,
): Promise<void> {
  if (!db) return;
  await db
    .prepare(
      "INSERT INTO experiment_counters (experiment_id, variant_id, metric, day, n) VALUES (?, ?, ?, ?, 1) " +
        "ON CONFLICT (experiment_id, variant_id, metric, day) DO UPDATE SET n = n + 1",
    )
    .bind(experimentId, variantId, metric, day)
    .run();
}

/** True when `pathname`/`method` is this experiment's goal signal. Only "pageview" (any method,
 *  matched by path) and "route" (POST, matched by path) are edge-observable here — "scroll"/
 *  "visible" are observed client-side by the goal beacon (`handleGoalBeaconRequest` below), never
 *  by pathname/method matching. */
export function matchesGoal(experiment: RunningExperiment, pathname: string, method: string): boolean {
  const { goal } = experiment;
  if (goal.path === undefined) return false;
  if (goal.kind === "pageview") return pathname === goal.path;
  if (goal.kind === "route") return pathname === goal.path && method === "POST";
  return false;
}

function buildVariantAssetRequest(request: Request, variantPage: string): Request {
  const url = new URL(request.url);
  url.pathname = variantPage;
  return new Request(url.toString(), request);
}

function withSetCookie(response: Response, cookieValue: string): Response {
  const next = new Response(response.body, response);
  next.headers.append("Set-Cookie", cookieValue);
  return next;
}

/**
 * Assignment + serving for a request on the experiment's own `page` (design doc §3). Reads/
 * validates the `exp_<id>` cookie; an unset or unrecognized value draws a fresh arm and counts one
 * impression. Serves control by passing the request through to `ASSETS` untouched, or the variant
 * by fetching `variant.page`'s built asset and returning it under the original URL — no redirect,
 * no flicker.
 */
export async function handleExperimentPageRequest(
  request: Request,
  env: ExperimentsEnv,
  ctx: ExecutionContext,
  experiment: RunningExperiment,
): Promise<Response> {
  const assets = env.ASSETS;
  if (!assets) return new Response("No assets binding configured", { status: 500 });

  const cookies = parseCookieHeader(request.headers.get("Cookie"));
  const cookieName = assignmentCookieName(experiment.id);
  const existing = cookies.get(cookieName);
  const isFirstAssignment = existing !== "control" && existing !== experiment.variant.id;
  const arm: "control" | "variant" =
    existing === "control" ? "control" : existing === experiment.variant.id ? "variant" : assignVariant(experiment.split);

  if (isFirstAssignment) {
    const variantId = arm === "control" ? "control" : experiment.variant.id;
    ctx.waitUntil(incrementExperimentCounter(env.EXPERIMENTS_DB, experiment.id, variantId, "impression", currentDay()));
  }

  const response =
    arm === "control" ? await assets.fetch(request) : await assets.fetch(buildVariantAssetRequest(request, experiment.variant.page));

  if (!isFirstAssignment) return response;
  const cookieValue = arm === "control" ? "control" : experiment.variant.id;
  return withSetCookie(response, serializeCookie(cookieName, cookieValue));
}

/**
 * Applied to a response already produced for a goal-matching request (`matchesGoal` true). Counts
 * one conversion — only for an already-assigned visitor (`exp_<id>` cookie present), only once
 * (`exp_<id>_c` not yet set), and only for a successful response, so a failed contact-form POST
 * doesn't count as a conversion.
 */
export async function applyGoalConversion(
  request: Request,
  env: ExperimentsEnv,
  ctx: ExecutionContext,
  experiment: RunningExperiment,
  response: Response,
): Promise<Response> {
  if (!response.ok) return response;

  const cookies = parseCookieHeader(request.headers.get("Cookie"));
  const rawArm = cookies.get(assignmentCookieName(experiment.id));
  // The cookie is client-supplied and HttpOnly only stops JS from *reading* it — a client can
  // still send an arbitrary value. Only count a conversion for exactly the two arms this
  // experiment can actually assign; anything else (garbage, or a stale value from before
  // variant.id changed) is treated the same as no cookie at all — a no-op, not a fresh
  // assignment (this isn't the assignment moment, see the doc comment above).
  const arm = rawArm === "control" || rawArm === experiment.variant.id ? rawArm : undefined;
  if (arm === undefined) return response;

  const conversionCookie = conversionCookieName(experiment.id);
  if (cookies.has(conversionCookie)) return response;

  ctx.waitUntil(incrementExperimentCounter(env.EXPERIMENTS_DB, experiment.id, arm, "conversion", currentDay()));
  return withSetCookie(response, serializeCookie(conversionCookie, "1"));
}

const CLIENT_GOAL_KINDS: ReadonlySet<ExperimentGoalKind> = new Set(["scroll", "visible"]);

/**
 * The `/x/goal` endpoint (#1270 slice 2): `worker.ts` dispatches every request on
 * `GOAL_ENDPOINT_PATH` here, running experiment or not. `sendBeacon`/`fetch(keepalive)` bodies are
 * always empty (no request body is ever read) — the experiment id travels as the `e` query
 * parameter instead (`public/x/goal-beacon.js`'s `send()`).
 *
 * A `204` no-op — never a conversion — for: any non-POST method (`405` instead), no experiment
 * running, a running experiment whose goal isn't client-side (`scroll`/`visible` — a forged hit
 * against a `pageview`/`route` experiment must not count, since only the beacon script for a
 * client-side goal is ever supposed to call this), an `e` that doesn't match the running
 * experiment's id, or (inside `applyGoalConversion`) a visitor with no assignment cookie or one
 * that's already converted. Reuses `applyGoalConversion`'s cookie/dedupe logic against a bare
 * `204` response, which is `response.ok`, so it's still eligible to count.
 */
export async function handleGoalBeaconRequest(
  request: Request,
  env: ExperimentsEnv,
  ctx: ExecutionContext,
  experiment: RunningExperiment | null,
): Promise<Response> {
  if (request.method !== "POST") {
    return new Response("Method Not Allowed", { status: 405, headers: { allow: "POST" } });
  }

  const emptyResponse = new Response(null, { status: 204 });
  if (!experiment || !CLIENT_GOAL_KINDS.has(experiment.goal.kind)) return emptyResponse;

  const requestedId = new URL(request.url).searchParams.get("e");
  if (requestedId !== experiment.id) return emptyResponse;

  return applyGoalConversion(request, env, ctx, experiment, emptyResponse);
}
