/**
 * The read gate itself (#1568): which asset-404'd paths might be a restricted post, the
 * session→allowlist check, and the hand-rolled microformats2 rendering for a gated permalink and
 * the private h-feed.
 *
 * @see docs/superpowers/specs/2026-08-18-worker-read-gate-design.md §6, §7, §8
 */

import { createMicropubStore, type PostRecord } from "@dwk/micropub";
import { escapeHTML, extractMf2ContentString, extractMf2Photos } from "./render-utils.ts";
import { readReaderSessionCookie, verifyReaderSessionToken } from "./reader-session.ts";

/** Bindings this module needs. */
export interface GatedContentEnv {
  readonly TOKEN_SIGNING_KEY: string;
  readonly MICROPUB_DB?: D1Database;
}

const SLUG = /^[a-z0-9-]{1,80}$/;
const KNOWN_COLLECTIONS = new Set([
  "notes", "articles", "photos", "albums",
  "bookmarks", "likes", "replies", "events", "reviews",
]);

/**
 * Whether `pathname` is shaped like a post permalink `generatePostUrl` (`worker.ts`) could have
 * produced — either `/<slug>` or `/<known-collection>/<slug>`. Scopes the read gate to exactly the
 * URL space real posts occupy, so an unrelated 404 (an asset, a typo, a deep path) is untouched.
 */
export function looksLikePostPermalink(pathname: string): boolean {
  const segments = pathname.split("/").filter((segment) => segment.length > 0);
  if (segments.length === 1) return SLUG.test(segments[0] as string);
  if (segments.length === 2) {
    return KNOWN_COLLECTIONS.has(segments[0] as string) && SLUG.test(segments[1] as string);
  }
  return false;
}

/** The verified, allowlisted reader's normalized identity, or `null` if there is no valid session. */
export async function requireReaderSession(
  request: Request,
  env: Pick<GatedContentEnv, "TOKEN_SIGNING_KEY">,
): Promise<string | null> {
  const cookie = readReaderSessionCookie(request);
  if (cookie === null) return null;
  const session = await verifyReaderSessionToken(cookie, env.TOKEN_SIGNING_KEY);
  return session === null ? null : session.me;
}

const GATED_HEADERS = {
  "content-type": "text/html; charset=utf-8",
  "cache-control": "private, no-store",
  "content-security-policy": "default-src 'none'; img-src https: data:; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'",
  "referrer-policy": "no-referrer",
  "x-content-type-options": "nosniff",
} as const;

/**
 * A static 403 for any GET/HEAD on a plausible post-permalink path without a valid, allowlisted
 * reader session — identical regardless of whether a real restricted post lives at that path, so
 * an anonymous/unauthorized visitor can't use response differences to enumerate what exists.
 *
 * The one exception isn't a leak: the sign-in link echoes back the *requester's own* path (via
 * `?redirect=`) so a real person has a way to actually sign in and land back where they started —
 * that's the visitor's own input reflected to them, not new information about the site.
 */
export function forbidden(request: Request): Response {
  const url = new URL(request.url);
  const redirect = encodeURIComponent(url.pathname + url.search);
  const body = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Sign in required</title></head><body><main>
<h1>Sign in required</h1>
<p>This content is only available to the site owner's contacts.</p>
<p><a href="/contacts/signin?redirect=${redirect}">Sign in with your site</a></p>
</main></body></html>`;
  return new Response(request.method === "HEAD" ? null : body, { status: 403, headers: GATED_HEADERS });
}

function mf2String(values: readonly unknown[] | undefined): string | undefined {
  const first = values?.[0];
  return typeof first === "string" ? first : undefined;
}

function mf2Strings(values: readonly unknown[] | undefined): string[] {
  return (values ?? []).filter((value): value is string => typeof value === "string");
}

/**
 * Renders one restricted post's core h-entry markup — the same class names the public Astro
 * rendering uses, so a contact's feed reader parses it identically. Deliberately minimal
 * compared to `Hentry.astro`: no JSON-LD, cited-embed cards, licensing, syndication links, or
 * webmention interactions (§8 of the design doc) — none of that is renderable outside the Astro
 * build, and none of it is required for a private, non-indexed read.
 */
export function renderGatedPermalink(record: PostRecord, method: string): Response {
  const props = record.properties;
  const name = mf2String(props.name);
  const content = extractMf2ContentString(props.content?.[0]);
  const photos = extractMf2Photos(props.photo);
  const published = mf2String(props.published);
  const categories = mf2Strings(props.category);

  const body = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>${name ? escapeHTML(name) : "Post"}</title></head><body><main>
<article class="h-entry">
${name ? `<h1 class="p-name">${escapeHTML(name)}</h1>` : ""}
${photos.map((photo) => `<img class="u-photo" src="${escapeHTML(photo.url)}" alt="${escapeHTML(photo.alt ?? "")}">`).join("\n")}
<div class="e-content">${content}</div>
<a class="u-url" href="${escapeHTML(record.url)}">${published ? `<time class="dt-published" datetime="${escapeHTML(published)}">${escapeHTML(published)}</time>` : "Permalink"}</a>
${categories.length > 0 ? `<ul class="tags">${categories.map((category) => `<li><a class="p-category">${escapeHTML(category)}</a></li>`).join("")}</ul>` : ""}
</article>
</main></body></html>`;
  return new Response(method === "HEAD" ? null : body, { status: 200, headers: GATED_HEADERS });
}

/** Renders the private h-feed of live restricted posts, newest first. */
export function renderPrivateFeed(records: readonly PostRecord[], method: string): Response {
  const items = records
    .map((record) => {
      const props = record.properties;
      const name = mf2String(props.name);
      const content = extractMf2ContentString(props.content?.[0]);
      const published = mf2String(props.published);
      return `<li class="h-entry">
${name ? `<h2 class="p-name">${escapeHTML(name)}</h2>` : ""}
<div class="e-content">${content}</div>
<a class="u-url" href="${escapeHTML(record.url)}">${published ? `<time class="dt-published" datetime="${escapeHTML(published)}">${escapeHTML(published)}</time>` : "Permalink"}</a>
</li>`;
    })
    .join("\n");

  const body = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Private feed</title></head><body><main>
<div class="h-feed">
<h1 class="p-name">Private feed</h1>
<ul>
${items || "<li>No restricted posts yet.</li>"}
</ul>
</div>
</main></body></html>`;
  return new Response(method === "HEAD" ? null : body, { status: 200, headers: GATED_HEADERS });
}

/**
 * The Worker's asset-404 fallback hook: given a path that fell through static-asset serving,
 * decide whether it's a gated restricted-post permalink. Returns `null` to leave the original
 * 404 untouched (path doesn't look like a post URL, the feature isn't provisioned, the requester
 * is authorized but no such post exists) — the caller keeps the plain 404 in every `null` case.
 */
export async function handleGatedFallback(
  request: Request,
  env: GatedContentEnv,
  pathname: string,
): Promise<Response | null> {
  if (request.method !== "GET" && request.method !== "HEAD") return null;
  if (!looksLikePostPermalink(pathname)) return null;
  if (!env.MICROPUB_DB) return null;

  const me = await requireReaderSession(request, env);
  if (me === null) return forbidden(request);

  const store = createMicropubStore({ MICROPUB_DB: env.MICROPUB_DB });
  const origin = new URL(request.url).origin;
  const record = await store.getPost(`${origin}${pathname}`);
  if (!record || record.deleted) return null;
  if (record.properties.visibility?.[0] !== "contacts") return null;

  return renderGatedPermalink(record, request.method);
}

/** `GET /contacts/feed`: the private h-feed, gated the same way as a permalink. */
export async function handlePrivateFeed(request: Request, env: GatedContentEnv): Promise<Response> {
  if (!env.MICROPUB_DB) {
    return new Response("Private feed is not configured", { status: 503 });
  }
  const me = await requireReaderSession(request, env);
  if (me === null) return forbidden(request);

  const store = createMicropubStore({ MICROPUB_DB: env.MICROPUB_DB });
  const records = await store.listPosts(
    { limit: 50, offset: 0 },
    {
      filters: {
        order: "desc",
        postTypes: [],
        postStatuses: [],
        visibilities: ["contacts"],
        propertyExists: [],
        propertyValues: [],
      },
    },
  );
  return renderPrivateFeed(records, request.method);
}
