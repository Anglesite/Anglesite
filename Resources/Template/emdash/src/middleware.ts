/**
 * The render backstop (#2055 slice 4): every page this Worker renders on request is checked
 * again, as HTML, before a reader or a cache gets it. The check itself is the pinned
 * `scripts/emdash-gate/render-backstop.ts`; this file only wires it in. The deploy gate refuses a
 * server build that doesn't contain it.
 *
 * Prerendered pages are skipped here because they are files the deploy gate already scanned
 * (ADR § Gate, layer 1), and a build-time 503 would otherwise be baked into `dist/`.
 */
import { defineMiddleware } from "astro:middleware";
import { applyRenderBackstop } from "../scripts/emdash-gate/render-backstop.ts";

export const onRequest = defineMiddleware(async (context, next) => {
  const response = await next();
  if (context.isPrerendered) return response;
  return applyRenderBackstop(context.url.pathname, response);
});
