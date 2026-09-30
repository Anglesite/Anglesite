// Slice 0 spike Worker for #2095 — see
// docs/specs/2026-09-30-workers-issues-payload-spike-notes.md for the runbook.
//
//   GET  /boom       throws from a stand-in `@dwk` package, so Workers Issues records an issue
//   POST /hook       the Issues automation's generic-webhook destination; stores the raw body
//   GET  /captures   (Bearer WEBHOOK_SECRET) every capture plus analyzePayload()'s verdict
//
// Throwaway: deployed by hand to the maintainer's account and deleted once the payload shape is
// recorded in the spike notes.

import { analyzePayload } from "./analyze.js";
import { secretMatches } from "./secret.js";
import { handleSpikeRequest } from "./vendor/dwk-spike-pkg/index.js";

// Only the default handler is exported: workerd treats every named export of the entry module
// as an entrypoint. (`Env` is a type and erased at build time.)
export interface Env {
  CAPTURES: KVNamespace;
  WEBHOOK_SECRET: string;
}

const CAPTURE_PREFIX = "capture:";
/** Captures may hold the owner's own request data; keep them only as long as the spike needs. */
const CAPTURE_TTL_SECONDS = 7 * 24 * 60 * 60;
/** Headers worth recording to learn the delivery shape. `cf-webhook-auth` is never stored. */
const RECORDED_HEADERS = ["content-type", "user-agent", "cf-webhook-id", "cf-webhook-timestamp"];

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const { pathname } = new URL(request.url);

    if (pathname === "/boom") {
      handleSpikeRequest(new URL(request.url).searchParams.get("kind") ?? "default");
    }

    if (pathname === "/hook" && request.method === "POST") {
      if (!(await secretMatches(request.headers.get("cf-webhook-auth"), env.WEBHOOK_SECRET))) {
        return new Response("unauthorized", { status: 401 });
      }
      const body = await request.text();
      const headers = Object.fromEntries(
        RECORDED_HEADERS.flatMap((name) => {
          const value = request.headers.get(name);
          return value === null ? [] : [[name, value]];
        }),
      );
      const key = `${CAPTURE_PREFIX}${new Date().toISOString()}:${crypto.randomUUID()}`;
      await env.CAPTURES.put(key, JSON.stringify({ headers, body }), {
        expirationTtl: CAPTURE_TTL_SECONDS,
      });
      return new Response("captured", { status: 200 });
    }

    if (pathname === "/captures" && request.method === "GET") {
      const bearer = request.headers.get("authorization")?.replace(/^Bearer\s+/i, "") ?? null;
      if (!(await secretMatches(bearer, env.WEBHOOK_SECRET))) {
        return new Response("unauthorized", { status: 401 });
      }
      const { keys } = await env.CAPTURES.list({ prefix: CAPTURE_PREFIX });
      const captures = await Promise.all(
        keys.map(async ({ name }) => {
          const stored = JSON.parse((await env.CAPTURES.get(name)) ?? "{}") as {
            headers?: Record<string, string>;
            body?: string;
          };
          let parsed: unknown = null;
          try {
            parsed = JSON.parse(stored.body ?? "");
          } catch {
            // Not JSON — the analysis below reports no frames, which is itself an answer.
          }
          return { key: name, headers: stored.headers, payload: parsed ?? stored.body, analysis: analyzePayload(parsed) };
        }),
      );
      return Response.json(captures);
    }

    return new Response("not found", { status: 404 });
  },
} satisfies ExportedHandler<Env>;
