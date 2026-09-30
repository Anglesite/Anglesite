/**
 * The render backstop (#2055 slice 4): every page this Worker renders on request is checked
 * again, as HTML, before a reader or a cache gets it. The check itself is the pinned
 * `scripts/emdash-gate/render-backstop.ts`; this file only wires it in. The deploy gate refuses a
 * server build that doesn't contain it.
 *
 * A withheld page is logged and recorded in the site's D1 database (EmDash's `DB` binding) so the
 * app can tell the owner which page and why (#2097).
 *
 * Prerendered pages are skipped here because they are files the deploy gate already scanned
 * (ADR § Gate, layer 1), and a build-time 503 would otherwise be baked into `dist/`.
 */
import { defineMiddleware } from "astro:middleware";
import { env } from "cloudflare:workers";
import { applyRenderBackstop, d1WithheldReporter, type D1Like } from "../scripts/emdash-gate/render-backstop.ts";

export const onRequest = defineMiddleware(async (context, next) => {
  const response = await next();
  if (context.isPrerendered) return response;
  const db = (env as { DB?: D1Like }).DB;
  // The adapter's ExecutionContext: a withheld page's D1 record is written after the 503 is sent.
  const cfContext = (context.locals as { cfContext?: { waitUntil(promise: Promise<unknown>): void } }).cfContext;
  return applyRenderBackstop(
    context.url.pathname,
    response,
    d1WithheldReporter(db),
    cfContext ? (promise) => cfContext.waitUntil(promise) : undefined,
  );
});
