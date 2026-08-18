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
  handleGoalBeaconRequest,
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

// A distinct id from EXPERIMENT's "homepage-hero" — kept separate so these tests' counter rows
// can never collide with (or be polluted by) the applyGoalConversion tests above, which write
// real rows under "homepage-hero"/"b"/"conversion".
const SCROLL_EXPERIMENT: RunningExperiment = {
  ...EXPERIMENT,
  id: "beacon-test",
  goal: { kind: "scroll", depth: 75 },
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

test("matchesGoal: scroll/visible goals never match by pathname/method — the beacon reports them", () => {
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

test("applyGoalConversion: no-ops for a garbage/attacker-supplied cookie value", async () => {
  const env: ExperimentsEnv = { EXPERIMENTS_DB: testDb };
  const ctx = createExecutionContext();
  const request = new Request("https://owner.example/contact/thanks/", {
    headers: { Cookie: "exp_homepage-hero=anything" },
  });
  const response = await applyGoalConversion(request, env, ctx, EXPERIMENT, new Response("thanks"));
  await waitOnExecutionContext(ctx);
  expect(response.headers.get("Set-Cookie")).toBeNull();
  const row = await testDb
    .prepare("SELECT n FROM experiment_counters WHERE experiment_id = ? AND variant_id = ? AND metric = 'conversion'")
    .bind("homepage-hero", "anything")
    .first<{ n: number }>();
  expect(row).toBeNull();
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

test("handleGoalBeaconRequest: 405s for a non-POST method", async () => {
  const ctx = createExecutionContext();
  const response = await handleGoalBeaconRequest(
    new Request("https://owner.example/x/goal?e=beacon-test", { method: "GET" }),
    {},
    ctx,
    SCROLL_EXPERIMENT,
  );
  expect(response.status).toBe(405);
  expect(response.headers.get("allow")).toBe("POST");
});

test("handleGoalBeaconRequest: 204 no-ops when no experiment is running", async () => {
  const ctx = createExecutionContext();
  const response = await handleGoalBeaconRequest(
    new Request("https://owner.example/x/goal?e=beacon-test", { method: "POST" }),
    {},
    ctx,
    null,
  );
  expect(response.status).toBe(204);
});

test("handleGoalBeaconRequest: 204 no-ops for a running experiment with an edge-visible goal", async () => {
  const pageviewGoalExperiment: RunningExperiment = { ...SCROLL_EXPERIMENT, id: "beacon-pageview-noop-test", goal: { kind: "pageview", path: "/contact/thanks/" } };
  const ctx = createExecutionContext();
  const request = new Request("https://owner.example/x/goal?e=beacon-pageview-noop-test", {
    method: "POST",
    headers: { Cookie: "exp_beacon-pageview-noop-test=b" },
  });
  const response = await handleGoalBeaconRequest(request, { EXPERIMENTS_DB: testDb }, ctx, pageviewGoalExperiment);
  await waitOnExecutionContext(ctx);
  expect(response.status).toBe(204);
  const row = await testDb
    .prepare("SELECT n FROM experiment_counters WHERE experiment_id = ? AND metric = 'conversion'")
    .bind("beacon-pageview-noop-test")
    .first<{ n: number }>();
  expect(row).toBeNull();
});

test("handleGoalBeaconRequest: 204 no-ops when the `e` param doesn't match the running experiment's id", async () => {
  const ctx = createExecutionContext();
  const request = new Request("https://owner.example/x/goal?e=some-other-experiment", {
    method: "POST",
    headers: { Cookie: "exp_beacon-test=b" },
  });
  const response = await handleGoalBeaconRequest(request, { EXPERIMENTS_DB: testDb }, ctx, SCROLL_EXPERIMENT);
  await waitOnExecutionContext(ctx);
  expect(response.status).toBe(204);
  const row = await testDb
    .prepare("SELECT n FROM experiment_counters WHERE experiment_id = ? AND metric = 'conversion'")
    .bind("beacon-test")
    .first<{ n: number }>();
  expect(row).toBeNull();
});

test("handleGoalBeaconRequest: counts a conversion for an assigned visitor and sets the dedupe cookie", async () => {
  const ctx = createExecutionContext();
  const request = new Request("https://owner.example/x/goal?e=beacon-test", {
    method: "POST",
    headers: { Cookie: "exp_beacon-test=b" },
  });
  const response = await handleGoalBeaconRequest(request, { EXPERIMENTS_DB: testDb }, ctx, SCROLL_EXPERIMENT);
  await waitOnExecutionContext(ctx);
  expect(response.status).toBe(204);
  expect(response.headers.get("Set-Cookie")).toContain("exp_beacon-test_c=1");
  const row = await testDb
    .prepare("SELECT n FROM experiment_counters WHERE experiment_id = ? AND variant_id = ? AND metric = 'conversion'")
    .bind("beacon-test", "b")
    .first<{ n: number }>();
  expect(row?.n).toBe(1);
});

test("handleGoalBeaconRequest: 204 no-ops for an unassigned visitor (no assignment cookie)", async () => {
  const ctx = createExecutionContext();
  const request = new Request("https://owner.example/x/goal?e=beacon-test", { method: "POST" });
  const response = await handleGoalBeaconRequest(request, { EXPERIMENTS_DB: testDb }, ctx, SCROLL_EXPERIMENT);
  await waitOnExecutionContext(ctx);
  expect(response.status).toBe(204);
  expect(response.headers.get("Set-Cookie")).toBeNull();
});

test("handleGoalBeaconRequest: 204 no-ops (dedupes) for an already-converted visitor", async () => {
  const ctx = createExecutionContext();
  const request = new Request("https://owner.example/x/goal?e=beacon-test", {
    method: "POST",
    headers: { Cookie: "exp_beacon-test=b; exp_beacon-test_c=1" },
  });
  const response = await handleGoalBeaconRequest(request, { EXPERIMENTS_DB: testDb }, ctx, SCROLL_EXPERIMENT);
  await waitOnExecutionContext(ctx);
  expect(response.headers.get("Set-Cookie")).toBeNull();
});
