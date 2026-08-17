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
