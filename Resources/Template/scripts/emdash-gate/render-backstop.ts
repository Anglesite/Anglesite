/**
 * The render backstop: layer 3 of the re-scoped pre-deploy gate for EmDash sites (#2055 slice 4,
 * docs/specs/2026-09-28-external-cms-content-source-decision.md § Gate).
 *
 * The publish gate (`plugin.ts`) stops a problem before an article goes live, but content can
 * reach a rendered page without passing through a publish hook: a direct API or database write,
 * a template change that starts rendering a field nobody checked, or a plugin misconfiguration.
 * So every page the Worker renders on request is checked again, as rendered HTML, before it is
 * served or cached. Only the error-severity checks run here (secrets, restricted-audience
 * content, blocked admin routes), which keeps the per-render cost small.
 *
 * A failing page is withheld: the reader gets a plain 503 that no cache may store, and the page
 * and the reasons are logged, and recorded in the site's D1 database for the app to show the owner
 * (#2097). It fails closed: if the check itself throws, or the
 * body arrives content-encoded so its text can't be read, the page is withheld too.
 *
 * Checking a page means reading all of it first, so a server-rendered page is no longer streamed
 * to the reader as it renders. That is a deliberate cost: nothing may reach a reader or a cache
 * before the whole page has been checked.
 *
 * Pure and runtime-neutral (no Node built-ins), like the checks it runs, because it runs in the
 * Worker. It lives under `scripts/`, so decision D5's hash pin covers it, and the deploy gate
 * refuses a server bundle that doesn't contain it (`REQUIRED_GATE_MODULES`). The overlay's
 * `src/middleware.ts` wires it in.
 */

import { checkBlockedRoutes, checkNoRestrictedContentInDist, checkSecrets, type Issue } from "../gate-checks";

/** EmDash's own admin and API routes: authenticated, not public pages, and not the owner's markup. */
const EMDASH_ROUTE_PREFIX = "/_emdash/";

/** The log line's marker, so the owner's alerting can find withheld pages in the Worker's logs. */
export const WITHHELD_LOG_EVENT = "anglesite.render-backstop.withheld";

/** Whether a response is a public HTML page the backstop must check. */
export function shouldCheck(pathname: string, contentType: string | null): boolean {
  if (pathname === "/_emdash" || pathname.startsWith(EMDASH_ROUTE_PREFIX)) return false;
  return (contentType ?? "").toLowerCase().startsWith("text/html");
}

/** The error-severity gate findings for one rendered page. */
export function renderIssues(html: string, pathname: string): Issue[] {
  return [
    ...checkSecrets(html, pathname),
    ...checkNoRestrictedContentInDist(pathname, html),
    ...checkBlockedRoutes(html, pathname),
  ].filter((issue) => issue.severity === "error");
}

/** Statuses whose response can't carry a body (Fetch spec "null body status"). */
const NULL_BODY_STATUSES = new Set([101, 103, 204, 205, 304]);

/** What a reader gets instead of a withheld page. Says nothing about why. */
export function withheldResponse(): Response {
  return new Response(
    '<!doctype html><html lang="en"><meta charset="utf-8"><title>Temporarily unavailable</title>' +
      "<p>This page is temporarily unavailable. Please try again later.</p></html>",
    {
      status: 503,
      headers: {
        "Content-Type": "text/html; charset=utf-8",
        "Cache-Control": "no-store",
        "Retry-After": "300",
      },
    },
  );
}

/**
 * How a withheld page is reported. Defaults to the Worker's log. The report carries the checks'
 * messages ("Possible AWS key exposed"), which name what was found but never quote it, so the
 * log never holds the secret the page was withheld for.
 */
export type WithheldReport = { event: string; path: string; categories: string[]; messages: string[] };
export type WithheldReporter = (report: WithheldReport) => void | Promise<void>;

const logWithheld: WithheldReporter = (report) => console.error(JSON.stringify(report));

/**
 * The table in the site's D1 database (EmDash's `DB`) that lists withheld pages for the app
 * (#2097). One row per path. Written only when a page is withheld, never on a clean render, so a
 * healthy page costs no database write. The app clears a row once it has confirmed the page
 * renders again, or is gone.
 */
export const WITHHELD_TABLE = "anglesite_withheld_pages";

/** A withheld page's row is refreshed at most this often, so a busy failing page isn't a write per request. */
export const WITHHELD_REFRESH_SECONDS = 300;

/** The two statements that record one withheld page: create the table if needed, then upsert its row. */
export function withheldRecordStatements(report: WithheldReport, now: Date): Array<{ sql: string; params: Array<string | number> }> {
  const at = now.toISOString();
  const refreshBefore = new Date(now.getTime() - WITHHELD_REFRESH_SECONDS * 1000).toISOString();
  return [
    {
      sql:
        `CREATE TABLE IF NOT EXISTS ${WITHHELD_TABLE} (path TEXT PRIMARY KEY, categories TEXT NOT NULL, ` +
        "messages TEXT NOT NULL, first_seen TEXT NOT NULL, last_seen TEXT NOT NULL, count INTEGER NOT NULL DEFAULT 1)",
      params: [],
    },
    {
      sql:
        `INSERT INTO ${WITHHELD_TABLE} (path, categories, messages, first_seen, last_seen, count) VALUES (?, ?, ?, ?, ?, 1) ` +
        "ON CONFLICT(path) DO UPDATE SET categories = excluded.categories, messages = excluded.messages, " +
        `last_seen = excluded.last_seen, count = ${WITHHELD_TABLE}.count + 1 WHERE ${WITHHELD_TABLE}.last_seen < ?`,
      params: [report.path, JSON.stringify(report.categories), JSON.stringify(report.messages), at, at, refreshBefore],
    },
  ];
}

/** The slice of Cloudflare's `D1Database` the recorder uses, declared here to stay dependency-free. */
export interface D1Like {
  prepare(sql: string): { bind(...values: Array<string | number>): { run(): Promise<unknown> } };
}

/**
 * A reporter that logs the withheld page and records it in the site's D1 database for the app. A
 * database failure is logged and swallowed: the page is withheld either way, and the log line
 * still reaches the owner's Worker logs.
 */
export function d1WithheldReporter(db: D1Like | undefined, now: () => Date = () => new Date()): WithheldReporter {
  return async (report) => {
    logWithheld(report);
    if (!db) return;
    try {
      for (const { sql, params } of withheldRecordStatements(report, now())) {
        await db.prepare(sql).bind(...params).run();
      }
    } catch (error) {
      console.error(JSON.stringify({ event: "anglesite.render-backstop.record-failed", path: report.path, error: String(error) }));
    }
  };
}

/**
 * Checks one rendered response. Returns it unchanged when it isn't a public HTML page, a copy of
 * it when the page passes, or `withheldResponse()` when it fails or can't be checked.
 *
 * `waitUntil` is the Worker's `ExecutionContext.waitUntil`. With it, a withheld page's report
 * (a D1 write) runs after the 503 is sent instead of delaying it; without it, the report is
 * awaited first.
 */
export async function applyRenderBackstop(
  pathname: string,
  response: Response,
  report: WithheldReporter = logWithheld,
  waitUntil?: (promise: Promise<unknown>) => void,
): Promise<Response> {
  if (!shouldCheck(pathname, response.headers.get("content-type"))) return response;
  // No body to check: a 304 revalidation or a HEAD request carries none, and must not be given one.
  if (response.body === null || NULL_BODY_STATUSES.has(response.status)) return response;
  let issues: Issue[];
  let body = "";
  const encoding = (response.headers.get("content-encoding") ?? "identity").trim().toLowerCase();
  if (encoding !== "identity") {
    // Astro's server renders uncompressed (Cloudflare compresses later, at the edge), so an
    // encoded body means something unexpected sits in front of the backstop. Its bytes can't be
    // read as the page's text, so the page can't be checked.
    issues = [{ severity: "error", category: "render-backstop-failed", message: `The page arrived ${encoding}-encoded and could not be checked.`, file: pathname }];
  } else {
    try {
      body = await response.text();
      issues = renderIssues(body, pathname);
    } catch {
      issues = [{ severity: "error", category: "render-backstop-failed", message: "The page could not be checked.", file: pathname }];
    }
  }
  if (issues.length > 0) {
    // Reporting never changes the outcome: the page is withheld whether or not the report lands.
    const withheld: WithheldReport = {
      event: WITHHELD_LOG_EVENT,
      path: pathname,
      categories: [...new Set(issues.map((i) => i.category))].sort(),
      messages: [...new Set(issues.map((i) => i.message))].sort(),
    };
    const reported = (async () => report(withheld))().catch(() => undefined);
    if (waitUntil) {
      try {
        waitUntil(reported);
      } catch {
        await reported;
      }
    } else {
      await reported;
    }
    return withheldResponse();
  }
  // The body was read as text and is re-sent as text, so any length the upstream set no longer
  // applies; the runtime recomputes it.
  const headers = new Headers(response.headers);
  headers.delete("content-length");
  return new Response(body, { status: response.status, statusText: response.statusText, headers });
}
