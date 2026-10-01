import { describe, it, expect } from "vitest";
import worker, { type Env } from "../src/worker.js";
import { secretMatches } from "../src/secret.js";
import { analyzePayload } from "../src/analyze.js";

const ORIGIN = "https://anglesite-issues-spike.example.workers.dev";
const SECRET = "spike-secret";

/** Minimal in-memory stand-in for the KV surface the spike uses (put/get/list). */
function memoryKV(): KVNamespace {
  const store = new Map<string, string>();
  return {
    async put(key: string, value: string) {
      store.set(key, value);
    },
    async get(key: string) {
      return store.get(key) ?? null;
    },
    async list({ prefix = "" }: { prefix?: string } = {}) {
      return { keys: [...store.keys()].filter((k) => k.startsWith(prefix)).map((name) => ({ name })) };
    },
  } as unknown as KVNamespace;
}

function env(): Env {
  return { CAPTURES: memoryKV(), WEBHOOK_SECRET: SECRET };
}

function call(e: Env, path: string, init?: RequestInit): Promise<Response> {
  return worker.fetch(new Request(`${ORIGIN}${path}`, init), e);
}

describe("secretMatches", () => {
  it("accepts the configured secret and rejects anything else", async () => {
    expect(await secretMatches(SECRET, SECRET)).toBe(true);
    expect(await secretMatches("wrong", SECRET)).toBe(false);
    expect(await secretMatches(`${SECRET}x`, SECRET)).toBe(false);
  });

  it("never matches when either side is missing", async () => {
    expect(await secretMatches(null, SECRET)).toBe(false);
    expect(await secretMatches(SECRET, undefined)).toBe(false);
    expect(await secretMatches("", "")).toBe(false);
  });
});

describe("GET /boom", () => {
  it("throws from the stand-in package so Workers Issues records it", async () => {
    await expect(call(env(), "/boom")).rejects.toThrow("spike failure (default)");
  });
});

describe("POST /hook → GET /captures", () => {
  it("rejects a delivery without the webhook secret", async () => {
    const response = await call(env(), "/hook", { method: "POST", body: "{}" });
    expect(response.status).toBe(401);
  });

  it("stores an authorized delivery without its auth header and returns it analyzed", async () => {
    const e = env();
    const delivery = await call(e, "/hook", {
      method: "POST",
      headers: { "cf-webhook-auth": SECRET, "content-type": "application/json" },
      body: JSON.stringify({ name: "Issue", text: "boom", data: { fingerprint: "abc" }, ts: 1 }),
    });
    expect(delivery.status).toBe(200);

    expect((await call(e, "/captures")).status).toBe(401);
    const response = await call(e, "/captures", { headers: { authorization: `Bearer ${SECRET}` } });
    expect(response.status).toBe(200);
    const captures = (await response.json()) as Array<{
      headers: Record<string, string>;
      analysis: { verdict: string; fingerprintPaths: string[] };
    }>;
    expect(captures).toHaveLength(1);
    expect(captures[0]!.headers).toEqual({ "content-type": "application/json" });
    expect(captures[0]!.analysis.fingerprintPaths).toEqual(["data.fingerprint"]);
    expect(captures[0]!.analysis.verdict).toBe("no-stack");
  });
});

describe("analyzePayload", () => {
  it("a summary-only Notifications envelope is no-stack: nothing would be filed", () => {
    const analysis = analyzePayload({
      name: "Workers Issues",
      text: "New issue on anglesite-issues-spike: SpikePackageError",
      data: { alert_type: "workers_observability_alert", episode: { summary: "1 occurrence" } },
      ts: 1759250000,
    });
    expect(analysis.frames).toEqual([]);
    expect(analysis.verdict).toBe("no-stack");
    expect(analysis.hasExceptionClass).toBe(true);
  });

  it("finds source-mapped package frames in stack-trace text", () => {
    const analysis = analyzePayload({
      data: {
        issue_id: "iss_1",
        stack:
          "SpikePackageError: spike failure (default)\n" +
          "    at parseSpikeInput (src/vendor/dwk-spike-pkg/index.ts:14:9)\n" +
          "    at handleSpikeRequest (src/vendor/dwk-spike-pkg/index.ts:10:10)\n" +
          "    at Object.fetch (src/worker.ts:31:7)",
      },
    });
    expect(analysis.frames.map((f) => [f.fn, f.file, f.line])).toEqual([
      ["parseSpikeInput", "src/vendor/dwk-spike-pkg/index.ts", 14],
      ["handleSpikeRequest", "src/vendor/dwk-spike-pkg/index.ts", 10],
      ["Object.fetch", "src/worker.ts", 31],
    ]);
    expect(analysis.sourceMapped).toBe(true);
    expect(analysis.hasPackageFrame).toBe(true);
    expect(analysis.verdict).toBe("viable");
  });

  it("finds structured frame objects and flags an unmapped bundle", () => {
    const analysis = analyzePayload({
      data: {
        fingerprint: "fp",
        frames: [{ filename: "worker.js", lineno: 812, colno: 11, function: "parseSpikeInput" }],
      },
    });
    expect(analysis.frames).toEqual([
      { path: "data.frames[0]", file: "worker.js", line: 812, column: 11, fn: "parseSpikeInput" },
    ]);
    expect(analysis.sourceMapped).toBe(false);
    expect(analysis.hasPackageFrame).toBe(false);
  });

  it("frames without any grouping id are no-fingerprint", () => {
    const analysis = analyzePayload({ text: "at f (src/worker.ts:1:1)" });
    expect(analysis.verdict).toBe("no-fingerprint");
  });

  it("flags visitor-data key paths the relay must drop", () => {
    const analysis = analyzePayload({
      data: { request: { url: "https://x", headers: { cookie: "c" } }, user: { email: "a@b" } },
    });
    expect(analysis.sensitivePaths).toEqual([
      "data.request.headers",
      "data.request.headers.cookie",
      "data.request.url",
      "data.user.email",
    ]);
  });
});
