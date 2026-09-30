import { describe, it, expect, beforeEach } from "vitest";
import { createWorker, hostAllowed, type Env } from "../src/worker.js";
import { FakeGitHub, memoryKV, packageDelivery } from "./support.js";

const ORIGIN = "https://issues.anglesite.dwk.io";
const REGISTRATION_TOKEN = "reg-token";
const SITE = "0f8fad5b-d9cb-469f-a165-70867728950e";
const OTHER_SITE = "7c9e6679-7425-40de-944b-e07fc1f90ae7";
const DAY = 24 * 60 * 60 * 1000;

let env: Env;
let github: FakeGitHub;
let clock: number;
let worker: ReturnType<typeof createWorker>;

beforeEach(() => {
  github = new FakeGitHub();
  clock = Date.parse("2026-09-30T12:00:00Z");
  worker = createWorker({ github, now: () => clock });
  env = {
    SITES: memoryKV(),
    STATE: memoryKV(),
    TARGET_REPO: "davidwkeith/workers",
    ALLOWED_HOST_SUFFIXES: "dwk.io",
    DAILY_NEW_ISSUE_CAP: "10",
    DAILY_SITE_DELIVERY_CAP: "50",
    REGISTRATION_TOKEN,
    GITHUB_APP_ID: "unused",
    GITHUB_INSTALLATION_ID: "unused",
    GITHUB_APP_PRIVATE_KEY: "unused",
  };
});

function call(path: string, init?: RequestInit): Promise<Response> {
  return worker.fetch(new Request(`${ORIGIN}${path}`, init), env);
}

async function register(siteID = SITE, extra: Record<string, unknown> = {}, headers: Record<string, string> = {}) {
  return call("/sites", {
    method: "POST",
    headers: { authorization: `Bearer ${REGISTRATION_TOKEN}`, ...headers },
    body: JSON.stringify({ siteID, hostname: "blog.dwk.io", catalogCommit: "bd0ad3f", ...extra }),
  });
}

async function secretFor(siteID = SITE): Promise<string> {
  return ((await (await register(siteID)).json()) as { secret: string }).secret;
}

function deliver(secret: string, payload: unknown, siteID = SITE) {
  return call(`/hook/${siteID}`, { method: "POST", headers: { "cf-webhook-auth": secret }, body: JSON.stringify(payload) });
}

describe("registration", () => {
  it("needs the pre-shared token", async () => {
    const response = await call("/sites", { method: "POST", body: JSON.stringify({ siteID: SITE, hostname: "a.dwk.io" }) });
    expect(response.status).toBe(401);
  });

  it("only accepts allowlisted hostnames, and never stores the hostname", async () => {
    expect((await register(SITE, { hostname: "evil.example.com" })).status).toBe(403);
    expect((await register(SITE, { hostname: "dwk.io.evil.com" })).status).toBe(403);
    const response = await register();
    expect(response.status).toBe(200);
    const stored = [...(env.SITES as ReturnType<typeof memoryKV>).dump().values()].join();
    expect(stored).not.toContain("dwk.io");
    expect(stored).toContain("bd0ad3f");
  });

  it("returns a secret and hook path, and stores only the secret's hash", async () => {
    const body = (await (await register()).json()) as { secret: string; hookPath: string };
    expect(body.hookPath).toBe(`/hook/${SITE}`);
    expect(body.secret).toMatch(/^[0-9a-f]{64}$/);
    expect([...(env.SITES as ReturnType<typeof memoryKV>).dump().values()].join()).not.toContain(body.secret);
  });

  it("renewal with the current secret keeps it; a bare re-registration rotates it", async () => {
    const secret = await secretFor();
    const renewed = (await (await register(SITE, {}, { "x-site-secret": secret })).json()) as { renewed?: boolean; secret?: string };
    expect(renewed).toMatchObject({ renewed: true });
    expect(renewed.secret).toBeUndefined();
    expect((await deliver(secret, {})).status).toBe(202);

    const rotated = (await (await register()).json()) as { secret: string };
    expect(rotated.secret).not.toBe(secret);
    expect((await deliver(secret, {})).status).toBe(401);
  });

  it("revocation needs the site's own secret", async () => {
    const secret = await secretFor();
    expect((await call(`/sites/${SITE}`, { method: "DELETE", headers: { authorization: "Bearer nope" } })).status).toBe(401);
    expect((await call(`/sites/${SITE}`, { method: "DELETE", headers: { authorization: `Bearer ${secret}` } })).status).toBe(204);
    expect((await deliver(secret, packageDelivery())).status).toBe(401);
  });

  it.each([
    ["blog.dwk.io", true],
    ["dwk.io", true],
    ["notdwk.io", false],
    ["dwk.io.example.com", false],
    ["bad host.dwk.io", false],
  ])("hostAllowed(%s) = %s", (host, allowed) => {
    expect(hostAllowed(host, "dwk.io")).toBe(allowed);
  });
});

describe("deliveries", () => {
  it("rejects an unknown site or wrong secret identically", async () => {
    await secretFor();
    expect((await deliver("wrong", packageDelivery())).status).toBe(401);
    expect((await deliver("wrong", packageDelivery(), OTHER_SITE)).status).toBe(401);
  });

  it("no stack, no filing", async () => {
    const secret = await secretFor();
    const response = await deliver(secret, { name: "Workers Issues", text: "summary only", data: {} });
    expect(response.status).toBe(202);
    expect(await response.json()).toEqual({ filed: false, reason: "no-stack" });
    expect(github.issues.size).toBe(0);
  });

  it("files a redacted issue for a package error", async () => {
    const secret = await secretFor();
    const response = await deliver(secret, packageDelivery());
    expect(await response.json()).toEqual({ filed: true, action: "created", issue: 1 });

    const issue = github.issues.get(1)!;
    expect(issue.title).toBe("[@dwk/webmention] TypeError in verifySource (verify.ts:42)");
    expect(issue.labels).toEqual(["source:anglesite-issues", "pkg:webmention"]);
    expect(issue.body).toContain("at verifySource (@dwk/webmention/src/verify.ts:42:17)");
    expect(issue.body).toContain("at handle (worker/worker.ts:88:12)");
    expect(issue.body).toContain("… 1 frame omitted");
    expect(issue.body).not.toContain("linkedom");
    expect(issue.body).not.toContain("undefined");
    expect(issue.body).toContain("`bd0ad3f`");
    expect(issue.body).toMatch(/<!-- anglesite-issues fingerprint=[0-9a-f]{24} -->/);
    for (const leaked of ["jane", "secret=1", "session=abc", "reading 'source'", SITE, "cf-fp-1"]) {
      expect(issue.body).not.toContain(leaked);
      expect(issue.title).not.toContain(leaked);
    }
  });

  it("ignores a replayed or stale delivery", async () => {
    const secret = await secretFor();
    await deliver(secret, packageDelivery());
    expect(await (await deliver(secret, packageDelivery())).json()).toEqual({ filed: false, reason: "replay" });
    expect(
      await (await deliver(secret, packageDelivery({ lastSeen: "2026-09-30T09:00:00Z" }))).json(),
    ).toEqual({ filed: false, reason: "replay" });
  });

  it("de-duplicates across sites and package versions, commenting at most once a day", async () => {
    const secret = await secretFor();
    const otherSecret = await secretFor(OTHER_SITE);
    await deliver(secret, packageDelivery());

    // Same bug on another site, a different line (newer package version), a different CF id.
    const sameDay = await deliver(otherSecret, packageDelivery({ line: 57, fingerprint: "cf-fp-other" }), OTHER_SITE);
    expect(await sameDay.json()).toEqual({ filed: false, reason: "already-commented-today" });

    clock += DAY;
    const nextDay = await deliver(secret, packageDelivery({ lastSeen: "2026-10-01T11:00:00Z", count: 9 }));
    expect(await nextDay.json()).toEqual({ filed: true, action: "commented", issue: 1 });
    expect(github.issues.size).toBe(1);
    expect(github.comments[0]!.body).toBe("Reported again: 9 occurrences on one site, last seen 2026-10-01T11:00:00Z (catalog `bd0ad3f`).");
  });

  it("a GitHub failure surfaces as an error and the retry is not mistaken for a replay", async () => {
    const secret = await secretFor();
    const createIssue = github.createIssue.bind(github);
    github.createIssue = async () => {
      throw new Error("GitHub POST → 502");
    };
    await expect(deliver(secret, packageDelivery())).rejects.toThrow("502");
    github.createIssue = createIssue;
    expect(await (await deliver(secret, packageDelivery())).json()).toEqual({ filed: true, action: "created", issue: 1 });
  });

  it("stops filing a fingerprint a maintainer closed as `config`", async () => {
    const secret = await secretFor();
    await deliver(secret, packageDelivery());
    Object.assign(github.issues.get(1)!, { state: "closed", labels: ["config"] });
    clock += DAY;
    const response = await deliver(secret, packageDelivery({ lastSeen: "2026-10-01T11:00:00Z" }));
    expect(await response.json()).toEqual({ filed: false, reason: "suppressed" });
  });

  it("opens a regression issue when a fixed fingerprint comes back", async () => {
    const secret = await secretFor();
    await deliver(secret, packageDelivery());
    Object.assign(github.issues.get(1)!, { state: "closed", labels: [] });
    clock += DAY;
    const response = await deliver(secret, packageDelivery({ lastSeen: "2026-10-01T11:00:00Z" }));
    expect(await response.json()).toEqual({ filed: true, action: "created", issue: 2 });
    expect(github.issues.get(2)!.body).toContain("Regression of #1.");
  });

  it("recovers the issue mapping from the body marker when state is lost", async () => {
    const secret = await secretFor();
    await deliver(secret, packageDelivery());
    for (const key of [...(env.STATE as ReturnType<typeof memoryKV>).dump().keys()]) {
      if (key.startsWith("fp:")) await env.STATE.delete(key);
    }
    clock += DAY;
    const response = await deliver(secret, packageDelivery({ lastSeen: "2026-10-01T11:00:00Z" }));
    expect(await response.json()).toEqual({ filed: true, action: "commented", issue: 1 });
  });

  it("enforces the global new-issue cap and the per-site delivery cap", async () => {
    env.DAILY_NEW_ISSUE_CAP = "1";
    env.DAILY_SITE_DELIVERY_CAP = "2";
    const secret = await secretFor();
    await deliver(secret, packageDelivery());
    const different = packageDelivery({ lastSeen: "2026-09-30T11:30:00Z", fingerprint: "cf-fp-2" });
    different.data.stack = different.data.stack.replace("verifySource", "otherFunction");
    expect(await (await deliver(secret, different)).json()).toEqual({ filed: false, reason: "global-rate-limit" });
    const third = packageDelivery({ lastSeen: "2026-09-30T11:45:00Z", fingerprint: "cf-fp-3" });
    expect(await (await deliver(secret, third)).json()).toEqual({ filed: false, reason: "site-rate-limit" });
  });

  it("refuses non-JSON and oversized bodies", async () => {
    const secret = await secretFor();
    const notJSON = await call(`/hook/${SITE}`, { method: "POST", headers: { "cf-webhook-auth": secret }, body: "<xml/>" });
    expect(notJSON.status).toBe(400);
    const huge = await call(`/hook/${SITE}`, {
      method: "POST",
      headers: { "cf-webhook-auth": secret },
      body: JSON.stringify({ pad: "x".repeat(300 * 1024) }),
    });
    expect(huge.status).toBe(413);
  });
});
