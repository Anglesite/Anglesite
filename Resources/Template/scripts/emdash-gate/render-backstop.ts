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
 * and the reasons are logged for the owner. It fails closed: if the check itself throws, the page
 * is withheld too.
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

/** How a withheld page is reported. Defaults to the Worker's log. */
export type WithheldReporter = (report: { event: string; path: string; categories: string[] }) => void;

const logWithheld: WithheldReporter = (report) => console.error(JSON.stringify(report));

/**
 * Checks one rendered response. Returns it unchanged when it isn't a public HTML page, a copy of
 * it when the page passes, or `withheldResponse()` when it fails or can't be checked.
 */
export async function applyRenderBackstop(
  pathname: string,
  response: Response,
  report: WithheldReporter = logWithheld,
): Promise<Response> {
  if (!shouldCheck(pathname, response.headers.get("content-type"))) return response;
  let issues: Issue[];
  let body: string;
  try {
    body = await response.text();
    issues = renderIssues(body, pathname);
  } catch {
    issues = [{ severity: "error", category: "render-backstop-failed", message: "The page could not be checked.", file: pathname }];
    body = "";
  }
  if (issues.length > 0) {
    report({ event: WITHHELD_LOG_EVENT, path: pathname, categories: [...new Set(issues.map((i) => i.category))].sort() });
    return withheldResponse();
  }
  return new Response(body, { status: response.status, statusText: response.statusText, headers: response.headers });
}
