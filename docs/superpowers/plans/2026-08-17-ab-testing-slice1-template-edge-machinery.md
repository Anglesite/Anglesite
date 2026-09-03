# A/B Testing Slice 1: Template Edge Machinery — Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first slice of edge A/B testing (#1270, tracked as #1513): a site owner (or a
CLI user hand-editing `anglesite.json` + `wrangler.toml`, no app release needed) can declare one
running experiment, have the composed Worker assign visitors to control/variant via a first-party
cookie, serve the correct built page with zero flicker, count impressions and conversions in D1,
and have the pre-deploy gate catch the misconfigurations that would otherwise burn traffic
silently. Edge-visible goals only (`pageview`/`route`) — the client-side goal beacon
(`scroll`/`visible`) is slice 2.

**Architecture:** All template-side (`Resources/Template/`), no Swift changes (verified: nothing
in `Sources/AnglesiteCore` parses or would be destabilized by an un-mirrored `experiments` key in
`anglesite.json`). A new `worker/experiments.ts` module holds the runtime logic (cookie
read/write, arm assignment, D1 counters) with no dependency on `worker.ts`; `worker.ts` wires it
into `fetch()` ahead of and around the existing `ROUTES` dispatch. A new `scripts/
experiments-artifact.ts` prebuild script reads `anglesite.json`'s running experiment (via the
existing `readAnglesiteConfig`) and writes the gitignored, statically-imported `worker/
experiments.json` build artifact — mirroring how `scripts/edge-artifacts.ts` already generates
other gitignored, config-derived edge files. A new `checkExperiments` function extends
`scripts/pre-deploy-check.ts`'s existing versioned scan envelope.

**Tech Stack:** TypeScript, Astro (static output), Cloudflare Workers + D1, `node:test` for
config/gate scripts, Vitest + `@cloudflare/vitest-pool-workers` for the Worker.

## Global Constraints

- Every task ends with the relevant test suite green before moving on (TDD: failing test → pass →
  commit).
- Conventional commits, subject line ≤72 characters, referencing `#1513` (see `CONTRIBUTING.md` ▸
  "Commits and pull requests").
- No new npm dependencies — this slice only touches existing template code.
- Because this plan touches `Resources/Template/`, run `swift test --package-path .` (from the
  repo root, not `Resources/Template/`) before opening the PR — some Swift tests couple to the
  template markup (`CONTRIBUTING.md` ▸ "Testing").
- All template commands below run from `Resources/Template/` unless stated otherwise.
- Match existing conventions exactly: `node:test` + `node:assert/strict` for `scripts/*.test.ts`
  (see `scripts/anglesite-config.test.ts`), Vitest + `@cloudflare/vitest-pool-workers` for
  `worker/*.test.ts` (see `worker/worker.test.ts`).
- Optional bindings degrade gracefully (no throw) when absent — every existing feature in
  `worker.ts` follows this; experiments code must too (`EXPERIMENTS_DB`/`ASSETS` unbound → no-op
  or a 500 sentinel, never an unhandled exception).

---

## File Structure

| File | Responsibility |
|---|---|
| `scripts/anglesite-config.ts` | **Modify.** Add `experiments` section types to the existing config schema. |
| `scripts/anglesite-config.test.ts` | **Modify.** One new pass-through test for the `experiments` section. |
| `worker/migrations/0002_experiments.sql` | **Create.** D1 migration for the counters table. |
| `worker/experiments.ts` | **Create.** Runtime module: types, cookie helpers, arm assignment, D1 counter read/write, the two request-handling entry points `worker.ts` calls. Self-contained — no dependency on `worker.ts`. |
| `worker/experiments.test.ts` | **Create.** Vitest coverage for every export above, using a fake `Fetcher` and the real (test-pool) D1 binding. |
| `vitest.config.ts` | **Modify.** Register the new `EXPERIMENTS_DB` D1 binding. |
| `scripts/experiments-artifact.ts` | **Create.** Prebuild generator: `anglesite.json`'s running experiment → `worker/experiments.json`. |
| `scripts/experiments-artifact.test.ts` | **Create.** `node:test` coverage for the pure projection function. |
| `package.json` | **Modify.** Wire the generator into `prebuild` and a new `pretest:worker` script. |
| `.gitignore` | **Modify.** Ignore the generated `worker/experiments.json`. |
| `worker/worker.ts` | **Modify.** Add the `EXPERIMENTS_DB` binding, import the generated artifact, wire `experiments.ts`'s two entry points into `fetch()`. |
| `worker/worker.test.ts` | **Modify.** One regression test proving existing routing is unaffected when no experiment is running. |
| `scripts/pre-deploy-check.ts` | **Modify.** New `checkExperiments` check family, wired into `scan()`. |
| `scripts/pre-deploy-check.test.ts` | **Modify.** Coverage for every `checkExperiments` branch. |

**Interfaces produced, for reference across tasks** (exact names/types every later task relies on):

```ts
// worker/experiments.ts
export type ExperimentGoalKind = "pageview" | "route" | "scroll" | "visible";
export interface RunningExperimentGoal { kind: ExperimentGoalKind; path?: string; depth?: number; selector?: string; }
export interface RunningExperimentVariant { id: string; page: string; }
export interface RunningExperiment { id: string; page: string; variant: RunningExperimentVariant; split: number; goal: RunningExperimentGoal; }
export interface ExperimentsArtifact { experiment: RunningExperiment | null; }
export interface ExperimentsEnv { ASSETS?: Fetcher; EXPERIMENTS_DB?: D1Database; }

export function assignmentCookieName(experimentId: string): string;
export function conversionCookieName(experimentId: string): string;
export function assignVariant(controlShare: number, random?: () => number): "control" | "variant";
export function parseCookieHeader(header: string | null): Map<string, string>;
export function currentDay(): string;
export function initExperimentsSchema(db: D1Database): Promise<void>;
export function incrementExperimentCounter(db: D1Database | undefined, experimentId: string, variantId: string, metric: "impression" | "conversion", day: string): Promise<void>;
export function matchesGoal(experiment: RunningExperiment, pathname: string, method: string): boolean;
export function handleExperimentPageRequest(request: Request, env: ExperimentsEnv, ctx: ExecutionContext, experiment: RunningExperiment): Promise<Response>;
export function applyGoalConversion(request: Request, env: ExperimentsEnv, ctx: ExecutionContext, experiment: RunningExperiment, response: Response): Promise<Response>;
```

```ts
// scripts/anglesite-config.ts (additions)
export type AnglesiteExperimentGoalKind = "pageview" | "route" | "scroll" | "visible";
export interface AnglesiteExperimentGoal { kind: AnglesiteExperimentGoalKind; path?: string; depth?: number; selector?: string; }
export interface AnglesiteExperimentVariant { id: string; name: string; page: string; }
export interface AnglesiteExperiment { id: string; name: string; page: string; variant: AnglesiteExperimentVariant; split: number; goal: AnglesiteExperimentGoal; status: "draft" | "running"; startedAt?: string; }
export interface AnglesiteExperimentsConfig { active?: AnglesiteExperiment[]; }
// AnglesiteConfig gains: experiments?: AnglesiteExperimentsConfig;
```

```ts
// scripts/experiments-artifact.ts
export function buildExperimentsArtifact(config: AnglesiteConfig): ExperimentsArtifact;
```

```ts
// scripts/pre-deploy-check.ts (addition)
export function checkExperiments(anglesiteConfigRaw: string | null, distFiles: Set<string>, distFileContent: Map<string, string>, sitemapContent: string | null): Issue[];
```

---

### Task 1: `experiments` config schema

**Files:**
- Modify: `Resources/Template/scripts/anglesite-config.ts:51-66`
- Test: `Resources/Template/scripts/anglesite-config.test.ts`

**Interfaces:**
- Produces: `AnglesiteExperimentGoalKind`, `AnglesiteExperimentGoal`, `AnglesiteExperimentVariant`, `AnglesiteExperiment`, `AnglesiteExperimentsConfig` (see File Structure block above), and `AnglesiteConfig.experiments?: AnglesiteExperimentsConfig`.

- [ ] **Step 1: Write the failing test**

Add to `Resources/Template/scripts/anglesite-config.test.ts` (after the existing "returns declared
sections as-is" test):

```ts
test("readAnglesiteConfig: passes through a declared experiments section as-is", () => {
  const siteRoot = makeTempSiteRoot();
  const raw = JSON.stringify({
    version: 1,
    experiments: {
      active: [
        {
          id: "homepage-hero",
          name: "Homepage headline",
          page: "/",
          variant: { id: "b", name: "Fresh eggs headline", page: "/x/homepage-hero/b/" },
          split: 0.5,
          goal: { kind: "pageview", path: "/contact/thanks/" },
          status: "running",
          startedAt: "2026-08-16",
        },
      ],
    },
  });
  writeFileSync(join(siteRoot, "anglesite.json"), raw);
  try {
    const result = readAnglesiteConfig(siteRoot);
    assert.deepEqual(result.experiments, {
      active: [
        {
          id: "homepage-hero",
          name: "Homepage headline",
          page: "/",
          variant: { id: "b", name: "Fresh eggs headline", page: "/x/homepage-hero/b/" },
          split: 0.5,
          goal: { kind: "pageview", path: "/contact/thanks/" },
          status: "running",
          startedAt: "2026-08-16",
        },
      ],
    });
  } finally {
    rmSync(siteRoot, { recursive: true, force: true });
  }
});
```

- [ ] **Step 2: Run test to verify it fails**

Run (from `Resources/Template/`): `npx tsx --test scripts/anglesite-config.test.ts`
Expected: TypeScript error — `experiments` doesn't exist on the inferred config type — or a
runtime `assert.deepEqual` failure if it type-checks loosely. Either way, `AnglesiteConfig` has no
`experiments` field yet.

- [ ] **Step 3: Add the types**

In `Resources/Template/scripts/anglesite-config.ts`, insert after the `AnglesiteWorkersConfig`
interface (currently lines 51-53) and before the `AnglesiteConfig` doc comment:

```ts
export type AnglesiteExperimentGoalKind = "pageview" | "route" | "scroll" | "visible";

export interface AnglesiteExperimentGoal {
  kind: AnglesiteExperimentGoalKind;
  /** Required for "pageview" and "route" goals; absent for "scroll"/"visible" (observed on the
   *  tested page itself by the client-side beacon, slice 2). */
  path?: string;
  /** Required for "scroll" goals: 1-100, percent of page scrolled. */
  depth?: number;
  /** Required for "visible" goals: CSS selector of the element to observe. */
  selector?: string;
}

export interface AnglesiteExperimentVariant {
  id: string;
  name: string;
  page: string;
}

export interface AnglesiteExperiment {
  id: string;
  name: string;
  page: string;
  variant: AnglesiteExperimentVariant;
  split: number;
  goal: AnglesiteExperimentGoal;
  status: "draft" | "running";
  startedAt?: string;
}

export interface AnglesiteExperimentsConfig {
  active?: AnglesiteExperiment[];
}
```

Then modify the `AnglesiteConfig` interface (currently lines 59-66) to add the new field:

```ts
export interface AnglesiteConfig {
  version: number;
  domain?: AnglesiteDomainConfig;
  dns?: AnglesiteDNSConfig;
  edge?: AnglesiteEdgeConfig;
  email?: AnglesiteEmailConfig;
  workers?: AnglesiteWorkersConfig;
  experiments?: AnglesiteExperimentsConfig;
}
```

No change to `readAnglesiteConfig` itself — its `{ ...config, version: ... }` spread already
passes any declared section through untouched.

- [ ] **Step 4: Run test to verify it passes**

Run: `npx tsx --test scripts/anglesite-config.test.ts`
Expected: PASS, all tests including the new one.

- [ ] **Step 5: Commit**

```bash
git add scripts/anglesite-config.ts scripts/anglesite-config.test.ts
git commit -m "feat(#1513): add experiments section to anglesite.json schema"
```

---

### Task 2: D1 migration for experiment counters

**Files:**
- Create: `Resources/Template/worker/migrations/0002_experiments.sql`

**Interfaces:**
- Produces: the `experiment_counters` table shape that `worker/experiments.ts` (Task 3) reads and
  writes via raw SQL, and that `worker/experiments.test.ts` recreates via `initExperimentsSchema`
  (this migration is a production/Wrangler-D1-migration artifact; the test pool has no migration
  runner, matching how `0001_indieauth.sql` is mirrored by `@dwk/indieauth`'s own `init()`).

- [ ] **Step 1: Write the migration**

```sql
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
```

- [ ] **Step 2: Commit**

```bash
git add worker/migrations/0002_experiments.sql
git commit -m "feat(#1513): add D1 migration for experiment counters"
```

---

### Task 3: `worker/experiments.ts` — runtime module

**Files:**
- Create: `Resources/Template/worker/experiments.ts`
- Modify: `Resources/Template/vitest.config.ts:88` (register `EXPERIMENTS_DB`)
- Test: `Resources/Template/worker/experiments.test.ts`

**Interfaces:**
- Consumes: nothing from earlier tasks (self-contained; deliberately does not import `WorkerEnv`
  from `worker.ts` — `ExperimentsEnv` is a local, minimal subset, so `worker.ts` can depend on this
  module without a cycle).
- Produces: every export listed in the "Interfaces produced" block above.

- [ ] **Step 1: Register the D1 binding tests will need**

In `Resources/Template/vitest.config.ts:88`, change:

```ts
        d1Databases: ["AUTH_DB", "WEBMENTION_INBOX", "MICROPUB_DB", "WEBSUB_DB", "MICROSUB_DB"],
```
to:
```ts
        d1Databases: ["AUTH_DB", "WEBMENTION_INBOX", "MICROPUB_DB", "WEBSUB_DB", "MICROSUB_DB", "EXPERIMENTS_DB"],
```

- [ ] **Step 2: Write the failing test file**

Create `Resources/Template/worker/experiments.test.ts`:

```ts
import { env } from "cloudflare:workers";
import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { beforeEach, expect, test } from "vitest";
import {
  assignVariant,
  parseCookieHeader,
  assignmentCookieName,
  conversionCookieName,
  matchesGoal,
  currentDay,
  initExperimentsSchema,
  incrementExperimentCounter,
  handleExperimentPageRequest,
  applyGoalConversion,
  type RunningExperiment,
  type ExperimentsEnv,
} from "./experiments";

const testDb = (env as unknown as { EXPERIMENTS_DB: D1Database }).EXPERIMENTS_DB;

beforeEach(async () => {
  await initExperimentsSchema(testDb);
});

function makeFakeAssets(handler: (request: Request) => Response | Promise<Response>): Fetcher {
  return {
    fetch: (input: RequestInfo, init?: RequestInit) => Promise.resolve(handler(new Request(input, init))),
  } as unknown as Fetcher;
}

const EXPERIMENT: RunningExperiment = {
  id: "homepage-hero",
  page: "/",
  variant: { id: "b", page: "/x/homepage-hero/b/" },
  split: 0.5,
  goal: { kind: "pageview", path: "/contact/thanks/" },
};

test("assignVariant: draws control when random() is below the control share", () => {
  expect(assignVariant(0.5, () => 0.1)).toBe("control");
});

test("assignVariant: draws variant when random() is at/above the control share", () => {
  expect(assignVariant(0.5, () => 0.9)).toBe("variant");
});

test("parseCookieHeader: parses multiple cookies and ignores malformed segments", () => {
  const cookies = parseCookieHeader("exp_homepage-hero=b; exp_homepage-hero_c=1; malformed");
  expect(cookies.get("exp_homepage-hero")).toBe("b");
  expect(cookies.get("exp_homepage-hero_c")).toBe("1");
  expect(cookies.has("malformed")).toBe(false);
});

test("parseCookieHeader: returns an empty map for a null header", () => {
  expect(parseCookieHeader(null).size).toBe(0);
});

test("assignmentCookieName/conversionCookieName: namespaced by experiment id", () => {
  expect(assignmentCookieName("homepage-hero")).toBe("exp_homepage-hero");
  expect(conversionCookieName("homepage-hero")).toBe("exp_homepage-hero_c");
});

test("matchesGoal: pageview goal matches any method on its path", () => {
  expect(matchesGoal(EXPERIMENT, "/contact/thanks/", "GET")).toBe(true);
  expect(matchesGoal(EXPERIMENT, "/contact/thanks/", "POST")).toBe(true);
  expect(matchesGoal(EXPERIMENT, "/somewhere-else/", "GET")).toBe(false);
});

test("matchesGoal: route goal only matches POST on its path", () => {
  const routeExperiment: RunningExperiment = { ...EXPERIMENT, goal: { kind: "route", path: "/inbox" } };
  expect(matchesGoal(routeExperiment, "/inbox", "POST")).toBe(true);
  expect(matchesGoal(routeExperiment, "/inbox", "GET")).toBe(false);
});

test("matchesGoal: scroll/visible goals never match at the edge in this slice", () => {
  const scrollExperiment: RunningExperiment = { ...EXPERIMENT, goal: { kind: "scroll", depth: 75 } };
  expect(matchesGoal(scrollExperiment, "/", "GET")).toBe(false);
});

test("currentDay: returns an ISO date (YYYY-MM-DD)", () => {
  expect(currentDay()).toMatch(/^\d{4}-\d{2}-\d{2}$/);
});

test("incrementExperimentCounter: no-ops when db is undefined", async () => {
  await expect(
    incrementExperimentCounter(undefined, "x", "control", "impression", "2026-08-17"),
  ).resolves.toBeUndefined();
});

test("incrementExperimentCounter: upserts and accumulates n", async () => {
  await incrementExperimentCounter(testDb, "homepage-hero", "control", "impression", "2026-08-17");
  await incrementExperimentCounter(testDb, "homepage-hero", "control", "impression", "2026-08-17");
  const row = await testDb
    .prepare("SELECT n FROM experiment_counters WHERE experiment_id = ? AND variant_id = ? AND metric = ? AND day = ?")
    .bind("homepage-hero", "control", "impression", "2026-08-17")
    .first<{ n: number }>();
  expect(row?.n).toBe(2);
});

test("handleExperimentPageRequest: first visit draws an arm, counts an impression, and sets the assignment cookie", async () => {
  const assets = makeFakeAssets((request) => new Response(`served:${new URL(request.url).pathname}`));
  const env: ExperimentsEnv = { ASSETS: assets, EXPERIMENTS_DB: testDb };
  const ctx = createExecutionContext();
  const request = new Request("https://owner.example/");

  const response = await handleExperimentPageRequest(request, env, ctx, { ...EXPERIMENT, split: 0 });
  await waitOnExecutionContext(ctx);

  expect(await response.text()).toBe("served:/x/homepage-hero/b/");
  expect(response.headers.get("Set-Cookie")).toContain("exp_homepage-hero=b");

  const row = await testDb
    .prepare("SELECT n FROM experiment_counters WHERE experiment_id = ? AND variant_id = ? AND metric = 'impression'")
    .bind("homepage-hero", "b")
    .first<{ n: number }>();
  expect(row?.n).toBe(1);
});

test("handleExperimentPageRequest: returning visitor with a recognized cookie keeps their arm and doesn't re-count", async () => {
  const assets = makeFakeAssets((request) => new Response(`served:${new URL(request.url).pathname}`));
  const env: ExperimentsEnv = { ASSETS: assets, EXPERIMENTS_DB: testDb };
  const ctx = createExecutionContext();
  const request = new Request("https://owner.example/", { headers: { Cookie: "exp_homepage-hero=control" } });

  const response = await handleExperimentPageRequest(request, env, ctx, EXPERIMENT);
  await waitOnExecutionContext(ctx);

  expect(await response.text()).toBe("served:/");
  expect(response.headers.get("Set-Cookie")).toBeNull();
});

test("handleExperimentPageRequest: 500s when ASSETS isn't bound", async () => {
  const ctx = createExecutionContext();
  const response = await handleExperimentPageRequest(new Request("https://owner.example/"), {}, ctx, EXPERIMENT);
  expect(response.status).toBe(500);
});

test("applyGoalConversion: counts a conversion for an assigned, not-yet-converted visitor and sets the dedupe cookie", async () => {
  const env: ExperimentsEnv = { EXPERIMENTS_DB: testDb };
  const ctx = createExecutionContext();
  const request = new Request("https://owner.example/contact/thanks/", { headers: { Cookie: "exp_homepage-hero=b" } });

  const response = await applyGoalConversion(request, env, ctx, EXPERIMENT, new Response("thanks"));
  await waitOnExecutionContext(ctx);

  expect(response.headers.get("Set-Cookie")).toContain("exp_homepage-hero_c=1");
  const row = await testDb
    .prepare("SELECT n FROM experiment_counters WHERE experiment_id = ? AND variant_id = ? AND metric = 'conversion'")
    .bind("homepage-hero", "b")
    .first<{ n: number }>();
  expect(row?.n).toBe(1);
});

test("applyGoalConversion: no-ops for an unassigned visitor", async () => {
  const env: ExperimentsEnv = { EXPERIMENTS_DB: testDb };
  const ctx = createExecutionContext();
  const response = await applyGoalConversion(
    new Request("https://owner.example/contact/thanks/"),
    env,
    ctx,
    EXPERIMENT,
    new Response("thanks"),
  );
  await waitOnExecutionContext(ctx);
  expect(response.headers.get("Set-Cookie")).toBeNull();
});

test("applyGoalConversion: no-ops for an already-converted visitor", async () => {
  const env: ExperimentsEnv = { EXPERIMENTS_DB: testDb };
  const ctx = createExecutionContext();
  const request = new Request("https://owner.example/contact/thanks/", {
    headers: { Cookie: "exp_homepage-hero=b; exp_homepage-hero_c=1" },
  });
  const response = await applyGoalConversion(request, env, ctx, EXPERIMENT, new Response("thanks"));
  await waitOnExecutionContext(ctx);
  expect(response.headers.get("Set-Cookie")).toBeNull();
});

test("applyGoalConversion: no-ops for a failed response", async () => {
  const env: ExperimentsEnv = { EXPERIMENTS_DB: testDb };
  const ctx = createExecutionContext();
  const request = new Request("https://owner.example/contact/thanks/", { headers: { Cookie: "exp_homepage-hero=b" } });
  const response = await applyGoalConversion(request, env, ctx, EXPERIMENT, new Response("error", { status: 500 }));
  await waitOnExecutionContext(ctx);
  expect(response.headers.get("Set-Cookie")).toBeNull();
});
```

- [ ] **Step 3: Run test to verify it fails**

Run: `npm run test:worker`
Expected: FAIL — `./experiments` module not found.

- [ ] **Step 4: Write `worker/experiments.ts`**

Create `Resources/Template/worker/experiments.ts`:

```ts
/**
 * Edge A/B testing runtime (#1270 slice 1): variant assignment/serving and D1 event counting for
 * `worker.ts`'s experiments middleware. Edge-visible goal kinds only ("pageview"/"route") —
 * "scroll"/"visible" ship with the goal beacon in slice 2; `matchesGoal` never matches those kinds
 * here, so a misconfigured client-side-goal experiment is caught by `checkExperiments` (the
 * pre-deploy gate) rather than silently never converting at the edge.
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
 *  matched by path) and "route" (POST, matched by path) are edge-observable in this slice —
 *  "scroll"/"visible" are observed client-side by the slice-2 beacon, never at this layer. */
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
  const arm = cookies.get(assignmentCookieName(experiment.id));
  if (arm === undefined) return response;

  const conversionCookie = conversionCookieName(experiment.id);
  if (cookies.has(conversionCookie)) return response;

  ctx.waitUntil(incrementExperimentCounter(env.EXPERIMENTS_DB, experiment.id, arm, "conversion", currentDay()));
  return withSetCookie(response, serializeCookie(conversionCookie, "1"));
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `npm run test:worker`
Expected: PASS, all new tests plus every pre-existing `worker/*.test.ts` test (unaffected).

- [ ] **Step 6: Commit**

```bash
git add worker/experiments.ts worker/experiments.test.ts vitest.config.ts
git commit -m "feat(#1513): add experiments edge runtime module"
```

---

### Task 4: prebuild artifact generator

**Files:**
- Create: `Resources/Template/scripts/experiments-artifact.ts`
- Test: `Resources/Template/scripts/experiments-artifact.test.ts`
- Modify: `Resources/Template/package.json:7` (prebuild), add `pretest:worker` script
- Modify: `Resources/Template/.gitignore`

**Interfaces:**
- Consumes: `readAnglesiteConfig`, `AnglesiteConfig`, `AnglesiteExperiment` (Task 1);
  `ExperimentsArtifact`, `RunningExperiment` types (Task 3, type-only import).
- Produces: `buildExperimentsArtifact(config: AnglesiteConfig): ExperimentsArtifact` (pure,
  tested); a `worker/experiments.json` file on disk once run.

- [ ] **Step 1: Write the failing test file**

Create `Resources/Template/scripts/experiments-artifact.test.ts`:

```ts
import test from "node:test";
import assert from "node:assert/strict";
import { buildExperimentsArtifact } from "./experiments-artifact";
import type { AnglesiteConfig } from "./anglesite-config";

test("buildExperimentsArtifact: no experiments section returns null", () => {
  const config: AnglesiteConfig = { version: 1 };
  assert.deepEqual(buildExperimentsArtifact(config), { experiment: null });
});

test("buildExperimentsArtifact: only draft experiments returns null", () => {
  const config: AnglesiteConfig = {
    version: 1,
    experiments: {
      active: [
        {
          id: "homepage-hero",
          name: "Homepage headline",
          page: "/",
          variant: { id: "b", name: "Fresh eggs headline", page: "/x/homepage-hero/b/" },
          split: 0.5,
          goal: { kind: "pageview", path: "/contact/thanks/" },
          status: "draft",
        },
      ],
    },
  };
  assert.deepEqual(buildExperimentsArtifact(config), { experiment: null });
});

test("buildExperimentsArtifact: a running experiment is projected to its runtime shape", () => {
  const config: AnglesiteConfig = {
    version: 1,
    experiments: {
      active: [
        {
          id: "homepage-hero",
          name: "Homepage headline",
          page: "/",
          variant: { id: "b", name: "Fresh eggs headline", page: "/x/homepage-hero/b/" },
          split: 0.5,
          goal: { kind: "pageview", path: "/contact/thanks/" },
          status: "running",
          startedAt: "2026-08-16",
        },
      ],
    },
  };
  assert.deepEqual(buildExperimentsArtifact(config), {
    experiment: {
      id: "homepage-hero",
      page: "/",
      variant: { id: "b", page: "/x/homepage-hero/b/" },
      split: 0.5,
      goal: { kind: "pageview", path: "/contact/thanks/" },
    },
  });
});

test("buildExperimentsArtifact: picks the first running experiment when multiple are (invalidly) running", () => {
  const makeExperiment = (id: string, status: "draft" | "running") => ({
    id,
    name: id,
    page: `/${id}/`,
    variant: { id: "b", name: "b", page: `/x/${id}/b/` },
    split: 0.5,
    goal: { kind: "pageview" as const, path: "/thanks/" },
    status,
  });
  const config: AnglesiteConfig = {
    version: 1,
    experiments: { active: [makeExperiment("first", "running"), makeExperiment("second", "running")] },
  };
  assert.equal(buildExperimentsArtifact(config).experiment?.id, "first");
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx tsx --test scripts/experiments-artifact.test.ts`
Expected: FAIL — `./experiments-artifact` module not found.

- [ ] **Step 3: Write `scripts/experiments-artifact.ts`**

Create `Resources/Template/scripts/experiments-artifact.ts`:

```ts
#!/usr/bin/env npx tsx
/**
 * Build-time generator for `worker/experiments.json` (#1270 slice 1): the single running
 * experiment's runtime-relevant config, derived from `anglesite.json`'s `experiments.active`
 * list. Gitignored, derived, never hand-edited — regenerated at `prebuild` (and before
 * `npm run test:worker`, via the `pretest:worker` script) the same way `scripts/edge-artifacts.ts`
 * regenerates `public/.well-known/*`. `worker/worker.ts` statically imports the written file, so
 * it must exist before that file is bundled by Astro/Wrangler/Vitest — every entry point above
 * runs this first for exactly that reason.
 */
import { mkdirSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { readAnglesiteConfig, type AnglesiteConfig, type AnglesiteExperiment } from "./anglesite-config.ts";
import type { ExperimentsArtifact, RunningExperiment } from "../worker/experiments.ts";

/** Picks the one "running" experiment (v1: one at a time) out of `active`, or `null`. Multiple
 *  running entries would be a `checkExperiments` gate failure before deploy — this generator
 *  stays defensive rather than throwing, so a mid-edit config still produces a buildable (if
 *  soon-to-be-gate-rejected) artifact. */
export function buildExperimentsArtifact(config: AnglesiteConfig): ExperimentsArtifact {
  const active = config.experiments?.active ?? [];
  const running = active.find((experiment) => experiment.status === "running");
  return { experiment: running ? toRunningExperiment(running) : null };
}

function toRunningExperiment(experiment: AnglesiteExperiment): RunningExperiment {
  return {
    id: experiment.id,
    page: experiment.page,
    variant: { id: experiment.variant.id, page: experiment.variant.page },
    split: experiment.split,
    goal: {
      kind: experiment.goal.kind,
      ...(experiment.goal.path !== undefined ? { path: experiment.goal.path } : {}),
      ...(experiment.goal.depth !== undefined ? { depth: experiment.goal.depth } : {}),
      ...(experiment.goal.selector !== undefined ? { selector: experiment.goal.selector } : {}),
    },
  };
}

function writeExperimentsArtifact(siteRoot: string): void {
  const artifact = buildExperimentsArtifact(readAnglesiteConfig(siteRoot));
  const outDir = resolve(siteRoot, "worker");
  mkdirSync(outDir, { recursive: true });
  writeFileSync(resolve(outDir, "experiments.json"), JSON.stringify(artifact, null, 2) + "\n", "utf-8");
}

function main(): void {
  writeExperimentsArtifact(process.cwd());
  console.log("Wrote worker/experiments.json");
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main();
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx tsx --test scripts/experiments-artifact.test.ts`
Expected: PASS.

- [ ] **Step 5: Wire into `package.json`**

In `Resources/Template/package.json:7`, change:

```json
    "prebuild": "npx tsx scripts/well-known.ts check && npx tsx scripts/csp.ts && npx tsx scripts/edge-artifacts.ts",
```
to:
```json
    "prebuild": "npx tsx scripts/well-known.ts check && npx tsx scripts/csp.ts && npx tsx scripts/edge-artifacts.ts && npx tsx scripts/experiments-artifact.ts",
```

And add a new script (near `"test:worker"`):
```json
    "pretest:worker": "npx tsx scripts/experiments-artifact.ts",
```

- [ ] **Step 6: Add the generated file to `.gitignore`**

In `Resources/Template/.gitignore`, append:

```
# Generated at prebuild by scripts/experiments-artifact.ts from anglesite.json's running
# experiment (#1270 slice 1); regenerated before `npm run test:worker` too (see
# "pretest:worker" in package.json) so the file worker.ts statically imports always exists.
worker/experiments.json
```

- [ ] **Step 7: Generate the initial artifact on disk**

Run (from `Resources/Template/`): `npx tsx scripts/experiments-artifact.ts`
Expected: prints `Wrote worker/experiments.json`; the file now exists locally with
`{"experiment": null}\n` (this template checkout has no `anglesite.json`). Confirm it's ignored:
`git status --short` should show nothing for it.

- [ ] **Step 8: Commit**

```bash
git add scripts/experiments-artifact.ts scripts/experiments-artifact.test.ts package.json .gitignore
git commit -m "feat(#1513): generate worker/experiments.json at prebuild"
```

---

### Task 5: Wire experiments into `worker.ts`

**Files:**
- Modify: `Resources/Template/worker/worker.ts:1-56` (imports), `:88-204` (`WorkerEnv`),
  `:1864-1919` (`fetch()`)
- Modify: `Resources/Template/worker/worker.test.ts`

**Interfaces:**
- Consumes: `handleExperimentPageRequest`, `applyGoalConversion`, `matchesGoal`,
  `ExperimentsArtifact` (Task 3); the generated `worker/experiments.json` (Task 4, must exist on
  disk — confirm Task 4 Step 7 ran in this same checkout before starting).

- [ ] **Step 1: Write the failing test**

Add to `Resources/Template/worker/worker.test.ts` (anywhere near the other `routing:` tests):

```ts
test("routing: with no running experiment configured, existing routes are unaffected", async () => {
  const postResponse = await fetchWorker(
    new Request("https://owner.example/inbox", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ subject: "Hi", from: "a@example.com", message: "hello" }),
    }),
  );
  expect(postResponse.status).toBe(202);

  const assetResponse = await fetchWorker(new Request("https://owner.example/about"));
  expect(assetResponse.status).toBe(500);
  expect(await assetResponse.text()).toBe("No assets binding configured");
});
```

(This uses the existing `fetchWorker` helper already defined at `worker.test.ts:261-263` —
`async function fetchWorker(request: Request): Promise<Response> { return worker.fetch(request, testEnv, createExecutionContext()); }`
— the same helper every other `routing:` test in the file calls. No new helper needed.)

- [ ] **Step 2: Run test to verify it fails**

Run: `npm run test:worker`
Expected: currently PASSES already (nothing's wired in yet, so behavior is unchanged) — this step
just confirms the fixture/assertions are correct before the refactor. Proceed to the implementation
regardless; this test is regression insurance for Step 3's refactor, not new behavior.

- [ ] **Step 3: Wire `worker.ts`**

At the top of `Resources/Template/worker/worker.ts`, after the existing `@dwk/solid-pod` import
block (ends line 55) and before the file's doc comment (currently line 57), add:

```ts
import {
  handleExperimentPageRequest,
  applyGoalConversion,
  matchesGoal,
  type ExperimentsArtifact,
} from "./experiments.ts";
import experimentsArtifact from "./experiments.json";
```

In the `WorkerEnv` interface, after the `MICROSUB_QUEUE?: Queue<MicrosubJob>;` line (currently
line 203) and before the closing `}` (currently line 204), add:

```ts
  /**
   * Edge A/B testing event counters (#1270 slice 1). Optional: an experiment can be configured
   * and served without this binding provisioned (assignment/serving still works), but impressions
   * and conversions silently don't count until it's bound — see `incrementExperimentCounter` in
   * `./experiments.ts`. Provisioning this alongside the other social D1 bindings is slice 3.
   */
  EXPERIMENTS_DB?: D1Database;
```

Replace the `export default { async fetch(...) { ... }, ...}` block's `fetch` method (currently
lines 1864-1919 — everything from `async fetch(request: Request, env: WorkerEnv, ctx:
ExecutionContext): Promise<Response> {` through its closing `},` right before `async queue(`) with:

```ts
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
    }

    // Goal-signal conversion counting (#1270 slice 1): applied to whatever response the branches
    // above produced, so a pageview goal still renders its page normally and a route goal still
    // returns its handler's real response — this only ever adds a Set-Cookie header.
    if (RUNNING_EXPERIMENT && matchesGoal(RUNNING_EXPERIMENT, pathname, request.method)) {
      response = await applyGoalConversion(request, env, ctx, RUNNING_EXPERIMENT, response);
    }
    return response;
  },
```

Leave `queue()` and `scheduled()` (and the closing `} satisfies ExportedHandler<...>;`) exactly as
they are — only `fetch()` changes.

**Note on test coverage of the running-experiment path through `fetch()` itself:** the Vitest
Worker test pool deliberately has no `ASSETS` binding configured anywhere in this suite (see the
existing comment at `worker.test.ts:338`), and `RUNNING_EXPERIMENT` is resolved once from the
static import at module-bundle time — so a true end-to-end `fetchWorker()` test of "assignment
actually happens through the real dispatcher" isn't practical without either faking a global
`ASSETS` binding for the whole suite (risking every other test's "no ASSETS bound" assumption) or
a fragile file-swap-before-bundle setup. `handleExperimentPageRequest`/`applyGoalConversion`'s
actual behavior is already fully covered at the unit level in Task 3's `experiments.test.ts`
(real `ExecutionContext`, real D1); this task's job is only the two-line wiring
(`RUNNING_EXPERIMENT && pathname === ... → handleExperimentPageRequest(...)` and
`RUNNING_EXPERIMENT && matchesGoal(...) → applyGoalConversion(...)`), which the regression test
plus a careful read of the diff against Task 3's exported signatures covers honestly.

- [ ] **Step 4: Run tests to verify everything still passes**

Run: `npm run test:worker`
Expected: PASS — the new regression test, and every pre-existing test in the file, unaffected by
the `fetch()` refactor.

- [ ] **Step 5: Commit**

```bash
git add worker/worker.ts worker/worker.test.ts
git commit -m "feat(#1513): wire experiments assignment and goal tracking into worker.ts"
```

---

### Task 6: `checkExperiments` pre-deploy gate check

**Files:**
- Modify: `Resources/Template/scripts/pre-deploy-check.ts:701-810` (`scan()`), add new exported
  `checkExperiments` function near `checkAnglesiteConfig` (currently ends line 699)
- Modify: `Resources/Template/scripts/pre-deploy-check.test.ts`

**Interfaces:**
- Produces: `checkExperiments(anglesiteConfigRaw: string | null, distFiles: Set<string>,
  distFileContent: Map<string, string>, sitemapContent: string | null): Issue[]`

- [ ] **Step 1: Write the failing tests**

In `Resources/Template/scripts/pre-deploy-check.test.ts:3-14`, add `checkExperiments` to the
existing named import from `./pre-deploy-check`:

```ts
import {
  checkHeaders,
  checkMixedContent,
  checkSRI,
  checkExternalLinkRel,
  checkArtifactPresence,
  checkPII,
  checkMTAStsPolicy,
  checkSecurityTxt,
  checkEmbedMedia,
  checkAnglesiteConfig,
  checkExperiments,
  checkRSL,
} from "./pre-deploy-check";
```

Then add the following (anywhere in the file, e.g. near the `checkAnglesiteConfig` tests):

```ts
const VALID_ACTIVE = [
  {
    id: "homepage-hero",
    name: "Homepage headline",
    page: "/",
    variant: { id: "b", name: "Fresh eggs headline", page: "/x/homepage-hero/b/" },
    split: 0.5,
    goal: { kind: "pageview", path: "/contact/thanks/" },
    status: "running",
    startedAt: "2026-08-16",
  },
];

const VALID_VARIANT_HTML =
  '<html><head><link rel="canonical" href="https://example.com/"><meta name="robots" content="noindex"></head><body></body></html>';

function distFilesFor(paths: string[]): Set<string> {
  return new Set(paths);
}

test("checkExperiments: null config returns no issues", () => {
  assert.deepEqual(checkExperiments(null, new Set(), new Map(), null), []);
});

test("checkExperiments: no experiments section returns no issues", () => {
  assert.deepEqual(checkExperiments(JSON.stringify({ version: 1 }), new Set(), new Map(), null), []);
});

test("checkExperiments: experiments.active must be an array", () => {
  const issues = checkExperiments(JSON.stringify({ version: 1, experiments: { active: "nope" } }), new Set(), new Map(), null);
  assert.equal(issues.length, 1);
  assert.equal(issues[0].category, "experiments-invalid");
});

test("checkExperiments: rejects a malformed id", () => {
  const active = [{ ...VALID_ACTIVE[0], id: "not valid!" }];
  const issues = checkExperiments(JSON.stringify({ version: 1, experiments: { active } }), new Set(), new Map(), null);
  assert.ok(issues.some((i) => i.message.includes(".id must match")));
});

test("checkExperiments: rejects split outside (0,1)", () => {
  const active = [{ ...VALID_ACTIVE[0], split: 1.5 }];
  const issues = checkExperiments(JSON.stringify({ version: 1, experiments: { active } }), new Set(), new Map(), null);
  assert.ok(issues.some((i) => i.message.includes(".split must be")));
});

test("checkExperiments: rejects an unrecognized goal kind", () => {
  const active = [{ ...VALID_ACTIVE[0], goal: { kind: "bogus", path: "/x/" } }];
  const issues = checkExperiments(JSON.stringify({ version: 1, experiments: { active } }), new Set(), new Map(), null);
  assert.ok(issues.some((i) => i.message.includes("goal.kind must be one of")));
});

test("checkExperiments: flags scroll/visible goal kinds as not yet supported", () => {
  const active = [{ ...VALID_ACTIVE[0], goal: { kind: "scroll", depth: 75 } }];
  const issues = checkExperiments(JSON.stringify({ version: 1, experiments: { active } }), new Set(), new Map(), null);
  assert.ok(issues.some((i) => i.category === "experiments-unsupported"));
});

test("checkExperiments: rejects more than one running experiment", () => {
  const active = [VALID_ACTIVE[0], { ...VALID_ACTIVE[0], id: "second-test" }];
  const issues = checkExperiments(JSON.stringify({ version: 1, experiments: { active } }), new Set(), new Map(), null);
  assert.ok(issues.some((i) => i.message.includes("Only one experiment may be")));
});

test("checkExperiments: a well-formed draft-only config (nothing running) has no dist-dependent issues", () => {
  const active = [{ ...VALID_ACTIVE[0], status: "draft" }];
  const issues = checkExperiments(JSON.stringify({ version: 1, experiments: { active } }), new Set(), new Map(), null);
  assert.deepEqual(issues, []);
});

test("checkExperiments: flags a running experiment's page missing from dist/", () => {
  const issues = checkExperiments(
    JSON.stringify({ version: 1, experiments: { active: VALID_ACTIVE } }),
    distFilesFor(["dist/x/homepage-hero/b/index.html"]),
    new Map([["dist/x/homepage-hero/b/index.html", VALID_VARIANT_HTML]]),
    "<urlset></urlset>",
  );
  assert.ok(issues.some((i) => i.category === "experiments-not-built" && i.message.includes('"/")')));
});

test("checkExperiments: flags a running experiment's pageview goal path missing from dist/", () => {
  const issues = checkExperiments(
    JSON.stringify({ version: 1, experiments: { active: VALID_ACTIVE } }),
    distFilesFor(["dist/index.html", "dist/x/homepage-hero/b/index.html"]),
    new Map([["dist/x/homepage-hero/b/index.html", VALID_VARIANT_HTML]]),
    "<urlset></urlset>",
  );
  assert.ok(issues.some((i) => i.category === "experiments-not-built" && i.message.includes("pageview goal")));
});

test("checkExperiments: flags a variant page missing rel=canonical to the control page", () => {
  const html = '<html><head><meta name="robots" content="noindex"></head></html>';
  const issues = checkExperiments(
    JSON.stringify({ version: 1, experiments: { active: VALID_ACTIVE } }),
    distFilesFor(["dist/index.html", "dist/x/homepage-hero/b/index.html", "dist/contact/thanks/index.html"]),
    new Map([["dist/x/homepage-hero/b/index.html", html]]),
    "<urlset></urlset>",
  );
  assert.ok(issues.some((i) => i.category === "experiments-variant-seo" && i.message.includes("canonical")));
});

test("checkExperiments: flags a variant page missing noindex", () => {
  const html = '<html><head><link rel="canonical" href="https://example.com/"></head></html>';
  const issues = checkExperiments(
    JSON.stringify({ version: 1, experiments: { active: VALID_ACTIVE } }),
    distFilesFor(["dist/index.html", "dist/x/homepage-hero/b/index.html", "dist/contact/thanks/index.html"]),
    new Map([["dist/x/homepage-hero/b/index.html", html]]),
    "<urlset></urlset>",
  );
  assert.ok(issues.some((i) => i.category === "experiments-variant-seo" && i.message.includes("noindex")));
});

test("checkExperiments: flags a variant page present in the sitemap", () => {
  const issues = checkExperiments(
    JSON.stringify({ version: 1, experiments: { active: VALID_ACTIVE } }),
    distFilesFor(["dist/index.html", "dist/x/homepage-hero/b/index.html", "dist/contact/thanks/index.html"]),
    new Map([["dist/x/homepage-hero/b/index.html", VALID_VARIANT_HTML]]),
    "<urlset><url><loc>https://example.com/x/homepage-hero/b/</loc></url></urlset>",
  );
  assert.ok(issues.some((i) => i.category === "experiments-variant-seo" && i.message.includes("sitemap")));
});

test("checkExperiments: a fully well-formed, fully built running experiment has no issues", () => {
  const issues = checkExperiments(
    JSON.stringify({ version: 1, experiments: { active: VALID_ACTIVE } }),
    distFilesFor(["dist/index.html", "dist/x/homepage-hero/b/index.html", "dist/contact/thanks/index.html"]),
    new Map([["dist/x/homepage-hero/b/index.html", VALID_VARIANT_HTML]]),
    "<urlset></urlset>",
  );
  assert.deepEqual(issues, []);
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npx tsx --test scripts/pre-deploy-check.test.ts`
Expected: FAIL — `checkExperiments` is not exported yet.

- [ ] **Step 3: Implement `checkExperiments`**

In `Resources/Template/scripts/pre-deploy-check.ts`, add after `checkAnglesiteConfig` (currently
ends at line 699, right before `async function scan()`):

```ts
const EXPERIMENT_ID_PATTERN = /^[A-Za-z0-9-]+$/;
const EDGE_VISIBLE_GOAL_KINDS = new Set(["pageview", "route"]);
const KNOWN_GOAL_KINDS = new Set(["pageview", "route", "scroll", "visible"]);

function experimentPathProblem(path: unknown): string | null {
  if (typeof path !== "string" || path.length === 0) return "must be a non-empty string";
  if (!path.startsWith("/")) return 'must start with "/"';
  if (path.includes("..")) return 'must not contain ".."';
  if (path.includes("%")) return "must not contain percent-encoding";
  return null;
}

function distPathFor(routePath: string): string {
  const withTrailingSlash = routePath.endsWith("/") ? routePath : `${routePath}/`;
  return withTrailingSlash === "/" ? "dist/index.html" : `dist${withTrailingSlash}index.html`;
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function tryParsePathname(href: string): string | null {
  try {
    return new URL(href, "https://experiments.invalid").pathname;
  } catch {
    return null;
  }
}

/**
 * Validates the `experiments` section of `anglesite.json` (#1270 slice 1) and, for the one
 * running experiment (if any), that its edge machinery is actually built and wired — a page,
 * variant, or pageview-goal path that doesn't exist in `dist/`, or a variant missing its
 * canonical/noindex/sitemap-exclusion, is exactly the class of misconfiguration that burns real
 * traffic silently for a week before anyone notices (design doc §6). Runs after
 * `checkAnglesiteConfig` has already confirmed the document parses as a JSON object with a
 * recognized version — this function re-parses defensively but returns no issues of its own for a
 * document `checkAnglesiteConfig` already flagged, so the two never double-report the same root
 * cause.
 */
export function checkExperiments(
  anglesiteConfigRaw: string | null,
  distFiles: Set<string>,
  distFileContent: Map<string, string>,
  sitemapContent: string | null,
): Issue[] {
  if (anglesiteConfigRaw === null) return [];

  let parsed: unknown;
  try {
    parsed = JSON.parse(anglesiteConfigRaw);
  } catch {
    return []; // checkAnglesiteConfig already reports invalid JSON.
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) return [];

  const config = parsed as Record<string, unknown>;
  const experimentsSection = config.experiments;
  if (typeof experimentsSection !== "object" || experimentsSection === null) return [];

  const active = (experimentsSection as Record<string, unknown>).active;
  if (active === undefined) return [];
  if (!Array.isArray(active)) {
    return [
      {
        severity: "error",
        category: "experiments-invalid",
        message: 'anglesite.json\'s "experiments.active" must be an array.',
        file: "anglesite.json",
        remediation: 'Wrap the experiment entries in an array, or remove "experiments" to disable A/B testing.',
      },
    ];
  }

  const issues: Issue[] = [];
  const runningExperiments: Record<string, unknown>[] = [];

  active.forEach((rawEntry, index) => {
    const label = `experiments.active[${index}]`;
    if (typeof rawEntry !== "object" || rawEntry === null || Array.isArray(rawEntry)) {
      issues.push({ severity: "error", category: "experiments-invalid", message: `${label} must be an object.`, file: "anglesite.json" });
      return;
    }
    const entry = rawEntry as Record<string, unknown>;

    if (typeof entry.id !== "string" || !EXPERIMENT_ID_PATTERN.test(entry.id)) {
      issues.push({
        severity: "error",
        category: "experiments-invalid",
        message: `${label}.id must match ${EXPERIMENT_ID_PATTERN} (found ${JSON.stringify(entry.id)}).`,
        file: "anglesite.json",
      });
    }

    const pageProblem = experimentPathProblem(entry.page);
    if (pageProblem) {
      issues.push({ severity: "error", category: "experiments-invalid", message: `${label}.page ${pageProblem}.`, file: "anglesite.json" });
    }

    const variant = entry.variant as Record<string, unknown> | undefined;
    if (typeof variant !== "object" || variant === null) {
      issues.push({ severity: "error", category: "experiments-invalid", message: `${label}.variant must be an object.`, file: "anglesite.json" });
    } else {
      if (typeof variant.id !== "string" || variant.id.length === 0) {
        issues.push({
          severity: "error",
          category: "experiments-invalid",
          message: `${label}.variant.id must be a non-empty string.`,
          file: "anglesite.json",
        });
      }
      const variantPageProblem = experimentPathProblem(variant.page);
      if (variantPageProblem) {
        issues.push({
          severity: "error",
          category: "experiments-invalid",
          message: `${label}.variant.page ${variantPageProblem}.`,
          file: "anglesite.json",
        });
      }
    }

    if (typeof entry.split !== "number" || entry.split <= 0 || entry.split >= 1) {
      issues.push({
        severity: "error",
        category: "experiments-invalid",
        message: `${label}.split must be a number strictly between 0 and 1 (found ${JSON.stringify(entry.split)}).`,
        file: "anglesite.json",
      });
    }

    if (entry.status !== "draft" && entry.status !== "running") {
      issues.push({
        severity: "error",
        category: "experiments-invalid",
        message: `${label}.status must be "draft" or "running" (found ${JSON.stringify(entry.status)}).`,
        file: "anglesite.json",
      });
    }

    const goal = entry.goal as Record<string, unknown> | undefined;
    if (typeof goal !== "object" || goal === null) {
      issues.push({ severity: "error", category: "experiments-invalid", message: `${label}.goal must be an object.`, file: "anglesite.json" });
    } else if (!KNOWN_GOAL_KINDS.has(goal.kind as string)) {
      issues.push({
        severity: "error",
        category: "experiments-invalid",
        message: `${label}.goal.kind must be one of pageview, route, scroll, visible (found ${JSON.stringify(goal.kind)}).`,
        file: "anglesite.json",
      });
    } else if (!EDGE_VISIBLE_GOAL_KINDS.has(goal.kind as string)) {
      issues.push({
        severity: "error",
        category: "experiments-unsupported",
        message: `${label}.goal.kind "${goal.kind}" is not supported yet — client-side goals ship in a later slice.`,
        file: "anglesite.json",
        remediation: 'Use goal.kind "pageview" or "route" for now.',
      });
    } else {
      const goalPathProblem = experimentPathProblem(goal.path);
      if (goalPathProblem) {
        issues.push({ severity: "error", category: "experiments-invalid", message: `${label}.goal.path ${goalPathProblem}.`, file: "anglesite.json" });
      }
    }

    if (entry.status === "running") runningExperiments.push(entry);
  });

  if (runningExperiments.length > 1) {
    issues.push({
      severity: "error",
      category: "experiments-invalid",
      message: `Only one experiment may be "running" at a time (found ${runningExperiments.length}).`,
      file: "anglesite.json",
      remediation: "Conclude or pause the other running experiments before starting a new one.",
    });
  }

  const running = runningExperiments[0];
  if (!running || issues.some((issue) => issue.severity === "error")) return issues;

  // Below here, `running`'s own fields are already known well-formed (no error pushed for it
  // above), so it's safe to build dist-file checks against them.
  const page = running.page as string;
  const variant = running.variant as Record<string, unknown>;
  const variantPage = variant.page as string;
  const goal = running.goal as Record<string, unknown>;

  for (const [routePath, roleLabel] of [
    [page, "page"],
    [variantPage, "variant.page"],
  ] as const) {
    const distPath = distPathFor(routePath);
    if (!distFiles.has(distPath)) {
      issues.push({
        severity: "error",
        category: "experiments-not-built",
        message: `Running experiment's ${roleLabel} ("${routePath}") has no built page at ${distPath}.`,
        file: distPath,
        remediation: "Build the site before deploying, or check the route matches an actual page.",
      });
    }
  }

  if (goal.kind === "pageview") {
    const goalPath = goal.path as string;
    const goalDistPath = distPathFor(goalPath);
    if (!distFiles.has(goalDistPath)) {
      issues.push({
        severity: "error",
        category: "experiments-not-built",
        message: `Running experiment's pageview goal ("${goalPath}") has no built page at ${goalDistPath}.`,
        file: goalDistPath,
        remediation: "Build the site before deploying, or check the goal path matches an actual page.",
      });
    }
  }

  const variantHtml = distFileContent.get(distPathFor(variantPage));
  if (variantHtml !== undefined) {
    const canonicalMatch = variantHtml.match(/<link[^>]*rel=["']canonical["'][^>]*href=["']([^"']+)["'][^>]*>/i);
    const canonicalPath = canonicalMatch ? tryParsePathname(canonicalMatch[1]) : null;
    if (canonicalPath !== page) {
      issues.push({
        severity: "error",
        category: "experiments-variant-seo",
        message: `Variant page ("${variantPage}") must carry rel="canonical" pointing at the control page ("${page}").`,
        file: distPathFor(variantPage),
        remediation: 'Add <link rel="canonical"> to the variant page pointing at the control page.',
      });
    }
    if (!/<meta[^>]*name=["']robots["'][^>]*content=["'][^"']*noindex[^"']*["'][^>]*>/i.test(variantHtml)) {
      issues.push({
        severity: "error",
        category: "experiments-variant-seo",
        message: `Variant page ("${variantPage}") must carry a noindex robots meta tag.`,
        file: distPathFor(variantPage),
        remediation: 'Add <meta name="robots" content="noindex"> to the variant page.',
      });
    }
  }

  if (sitemapContent !== null && new RegExp(escapeRegExp(variantPage)).test(sitemapContent)) {
    issues.push({
      severity: "error",
      category: "experiments-variant-seo",
      message: `Variant page ("${variantPage}") must be excluded from the sitemap.`,
      file: "dist/sitemap.xml",
      remediation: "Exclude the variant route from sitemap generation.",
    });
  }

  return issues;
}
```

- [ ] **Step 4: Wire `checkExperiments` into `scan()`**

In `scan()` (currently `Resources/Template/scripts/pre-deploy-check.ts:701-810`):

1. Before the `for await (const file of walk(DIST_DIR)) {` loop (currently line 755), add a
   sitemap read and a content map, next to the other per-file reads already there:

```ts
  const sitemapContent = await readFile(join(DIST_DIR, "sitemap.xml"), "utf-8").catch(
    (e: NodeJS.ErrnoException) => (e.code === "ENOENT" ? null : Promise.reject(e)),
  );
  const htmlContent = new Map<string, string>();

  const relPaths: string[] = [];
```

   (This replaces the existing bare `const relPaths: string[] = [];` line — keep that line, just
   add the two new declarations directly above it.)

2. Inside the walk loop, where `isHtmlOrCss` is computed (currently line 763), add one line right
   after it:

```ts
    const isHtmlOrCss = /\.(html?|css)$/i.test(file);
    if (/\.html?$/i.test(file)) htmlContent.set(rel, content);
```

3. After the existing `issues.push(...checkArtifactPresence(relPaths));` line (currently line
   807), add:

```ts
  issues.push(...checkExperiments(anglesiteConfigContent, new Set(relPaths), htmlContent, sitemapContent));
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `npx tsx --test scripts/pre-deploy-check.test.ts`
Expected: PASS, all new tests plus every pre-existing test in the file.

- [ ] **Step 6: Commit**

```bash
git add scripts/pre-deploy-check.ts scripts/pre-deploy-check.test.ts
git commit -m "feat(#1513): add checkExperiments to the pre-deploy gate"
```

---

### Task 7: Full verification

**Files:** none (verification only).

- [ ] **Step 1: Run the full template test suite**

From `Resources/Template/`:
```bash
npm run lint 2>/dev/null; npm test && npm run test:worker && npm run test:scripts
```
(`lint` may not exist as a script — check `package.json`; if absent, skip it and note that in the
PR body rather than silently claiming it ran.)
Expected: all green.

- [ ] **Step 2: Type-check**

From `Resources/Template/`: `npx astro check`
Expected: no errors (in particular, confirms the `worker/experiments.json` static import and the
new `WorkerEnv.EXPERIMENTS_DB` field type-check cleanly).

- [ ] **Step 3: Run the Swift suite**

From the repo root (`CONTRIBUTING.md`: "If you touch `Resources/Template/`, run `swift test`
too"):
```bash
swift test --package-path .
```
Expected: all green — this slice makes no Swift changes, so this is a pure regression check.

- [ ] **Step 4: Exercise the pre-deploy check end to end (optional but recommended)**

From `Resources/Template/`: `npm run build && npm run check`
Expected: passes on the template's own scaffold content (no `anglesite.json`, so `checkExperiments`
short-circuits to `[]` immediately).

- [ ] **Step 5: Final review pass**

Re-read the diff against `docs/superpowers/specs/2026-08-16-edge-ab-testing-design.md` §10.1's
slice-1 bullet one more time: types + reader ✓, prebuild artifact generation ✓, `worker.ts`
middleware (assignment, serving, D1 counting) ✓, D1 migration ✓, `checkExperiments` in the gate ✓,
template tests ✓, edge-visible goals only ✓, no Swift/MCP changes ✓.
