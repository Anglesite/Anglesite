import test from "node:test";
import assert from "node:assert/strict";
import { applyRenderBackstop, d1WithheldReporter, renderIssues, shouldCheck, WITHHELD_LOG_EVENT, WITHHELD_REFRESH_SECONDS, WITHHELD_TABLE, withheldRecordStatements, type D1Like } from "./render-backstop";

const page = (body: string, headers: Record<string, string> = { "content-type": "text/html; charset=utf-8" }) =>
  new Response(`<!doctype html><html><body>${body}</body></html>`, { status: 200, headers: { "x-cache-hint": "articles", ...headers } });

const AWS_KEY = "AKIA" + "ABCDEFGHIJKLMNOP";

test("only public HTML pages, feeds and sitemaps are checked", () => {
  assert.equal(shouldCheck("/articles/vote/", "text/html; charset=utf-8"), true);
  assert.equal(shouldCheck("/articles/vote/", "TEXT/HTML"), true);
  // Feeds carry whole article bodies (#2133), and the sitemap renders on request too.
  assert.equal(shouldCheck("/articles/rss.xml", "application/rss+xml"), true);
  assert.equal(shouldCheck("/rss.xml", "application/xml"), true);
  assert.equal(shouldCheck("/atom.xml", "application/atom+xml; charset=utf-8"), true);
  assert.equal(shouldCheck("/feed.json", "application/feed+json; charset=utf-8"), true);
  assert.equal(shouldCheck("/sitemap-articles.xml", "text/xml"), true);
  // Anything else passes through: images, scripts, plain JSON.
  assert.equal(shouldCheck("/logo.png", "image/png"), false);
  assert.equal(shouldCheck("/x.js", "text/javascript"), false);
  assert.equal(shouldCheck("/data.json", "application/json"), false);
  assert.equal(shouldCheck("/articles/vote/", "text/htmlx"), false);
  assert.equal(shouldCheck("/articles/vote/", null), false);
  // EmDash's own admin and API are authenticated and not the owner's pages.
  assert.equal(shouldCheck("/_emdash/admin", "text/html"), false);
  assert.equal(shouldCheck("/_emdash", "text/html"), false);
  // Only the exact prefix: an owner page whose slug merely starts with "_emdash" is checked.
  assert.equal(shouldCheck("/_emdashboard/", "text/html"), true);
});

test("only error-severity checks run: secrets, restricted content, blocked admin routes", () => {
  assert.deepEqual(renderIssues(`<p>${AWS_KEY}</p>`, "/a/").map((i) => i.category), ["exposed-token"]);
  assert.deepEqual(renderIssues('<script type="application/json">{"visibility":"contacts"}</script>', "/a/").map((i) => i.category), [
    "restricted-content-in-dist",
  ]);
  assert.deepEqual(renderIssues('<a href="/keystatic/">edit</a>', "/a/").map((i) => i.category), ["keystatic-route"]);
  // PII is a publish-time (and deploy-time) check, not a render-time one: a reporter's byline
  // address on a page is not withheld.
  assert.deepEqual(renderIssues("<p>Call 415-555-0123 or write news@example.org</p>", "/a/"), []);
});

test("a clean page passes through with its status, headers and body", async () => {
  const reports: unknown[] = [];
  const out = await applyRenderBackstop("/articles/vote/", page("<h1>Council vote</h1>"), (r) => { reports.push(r); });
  assert.equal(out.status, 200);
  assert.equal(out.headers.get("x-cache-hint"), "articles");
  assert.match(await out.text(), /Council vote/);
  assert.deepEqual(reports, []);
});

test("a failing page is withheld as an uncacheable 503 and reported, without saying why to the reader", async () => {
  const reports: Array<{ event: string; path: string; categories: string[]; messages: string[] }> = [];
  const out = await applyRenderBackstop("/articles/leak/", page(`<p>${AWS_KEY}</p><a href="/keystatic/">x</a>`), (r) => { reports.push(r); });
  assert.equal(out.status, 503);
  assert.equal(out.headers.get("cache-control"), "no-store");
  assert.equal(out.headers.get("cloudflare-cdn-cache-control"), "no-store");
  assert.equal(out.headers.get("cdn-cache-control"), "no-store");
  assert.equal(out.headers.get("x-cache-hint"), null);
  const body = await out.text();
  assert.doesNotMatch(body, /AKIA|keystatic/);
  assert.deepEqual(reports.map(({ event, path, categories }) => ({ event, path, categories })), [
    { event: WITHHELD_LOG_EVENT, path: "/articles/leak/", categories: ["exposed-token", "keystatic-route"] },
  ]);
  // The report says what was found, never the secret itself.
  assert.deepEqual(reports[0].messages, ["Keystatic admin route found in production output", "Possible AWS key exposed"]);
  assert.doesNotMatch(JSON.stringify(reports), /AKIA/);
});

test("a withheld page is taken out of the route cache; a passing page keeps its cache options", async () => {
  // Astro applies the route's cache headers after middleware, so only `cache.set(false)` keeps a
  // page that had set a cache hint from reaching Cloudflare's cache as `public` (#2116).
  const calls: Array<false> = [];
  const routeCache = { set: (options: false) => { calls.push(options); } };
  const withheld = await applyRenderBackstop("/articles/leak/", page(`<p>${AWS_KEY}</p>`), () => {}, undefined, routeCache);
  assert.equal(withheld.status, 503);
  assert.deepEqual(calls, [false]);

  const passed = await applyRenderBackstop("/articles/vote/", page("<p>Passed.</p>"), () => {}, undefined, routeCache);
  assert.equal(passed.status, 200);
  assert.deepEqual(calls, [false], "a passing page leaves the route cache alone");

  // A cache that throws can't let the page through.
  const throwing = { set: () => { throw new Error("cache unavailable"); } };
  assert.equal((await applyRenderBackstop("/articles/leak/", page(`<p>${AWS_KEY}</p>`), () => {}, undefined, throwing)).status, 503);
});

test("a response with no body (304 revalidation, HEAD) passes through untouched", async () => {
  const notModified = new Response(null, { status: 304, headers: { "content-type": "text/html", etag: '"v1"' } });
  assert.equal(await applyRenderBackstop("/articles/vote/", notModified), notModified);
  const noContent = new Response(null, { status: 204, headers: { "content-type": "text/html" } });
  assert.equal(await applyRenderBackstop("/articles/vote/", noContent), noContent);
  const head = new Response(null, { status: 200, headers: { "content-type": "text/html", "content-length": "1234" } });
  assert.equal(await applyRenderBackstop("/articles/vote/", head), head);
});

test("a passing page is re-sent without the upstream's now-stale length", async () => {
  const out = await applyRenderBackstop("/articles/vote/", page("<h1>ok</h1>", { "content-type": "text/html", "content-length": "9999" }));
  assert.equal(out.status, 200);
  assert.equal(out.headers.get("content-length"), null);
  assert.match(await out.text(), /<h1>ok<\/h1>/);
});

test("an encoded page can't be read as text, so it is withheld (fails closed)", async () => {
  const reports: Array<{ categories: string[] }> = [];
  const gz = page("\u001f\u008b...", { "content-type": "text/html", "content-encoding": "gzip" });
  const out = await applyRenderBackstop("/articles/x/", gz, (r) => { reports.push(r); });
  assert.equal(out.status, 503);
  assert.deepEqual(reports.map((r) => r.categories), [["render-backstop-failed"]]);
  const identity = page("<p>fine</p>", { "content-type": "text/html", "content-encoding": "identity" });
  assert.equal((await applyRenderBackstop("/articles/y/", identity)).status, 200);
});

test("a page that can't be read is withheld (fails closed)", async () => {
  const broken = new Response(new ReadableStream({ start: (c) => c.error(new Error("stream broke")) }), {
    headers: { "content-type": "text/html" },
  });
  const reports: Array<{ categories: string[] }> = [];
  const out = await applyRenderBackstop("/articles/x/", broken, (r) => { reports.push(r); });
  assert.equal(out.status, 503);
  assert.deepEqual(reports.map((r) => r.categories), [["render-backstop-failed"]]);
});

test("responses it doesn't check, and admin responses, are returned untouched, unread", async () => {
  const image = new Response("png-bytes", { headers: { "content-type": "image/png" } });
  assert.equal(await applyRenderBackstop("/logo.png", image), image);
  const admin = page(`<p>${AWS_KEY}</p>`);
  assert.equal(await applyRenderBackstop("/_emdash/admin", admin), admin);
});

// #2097: withheld pages are recorded in the site's D1 database for the app.

const REPORT = { event: WITHHELD_LOG_EVENT, path: "/articles/leak/", categories: ["exposed-token"], messages: ["Possible AWS key exposed"] };

test("recording a withheld page creates the table and upserts one row per path, at most once per refresh window", () => {
  const now = new Date("2026-09-30T18:00:00.000Z");
  const [create, upsert] = withheldRecordStatements(REPORT, now);
  assert.match(create.sql, new RegExp(`^CREATE TABLE IF NOT EXISTS ${WITHHELD_TABLE} \\(path TEXT PRIMARY KEY`));
  assert.deepEqual(create.params, []);
  assert.match(upsert.sql, /ON CONFLICT\(path\) DO UPDATE/);
  assert.match(upsert.sql, /WHERE anglesite_withheld_pages\.last_seen < \?$/);
  const refreshBefore = new Date(now.getTime() - WITHHELD_REFRESH_SECONDS * 1000).toISOString();
  assert.deepEqual(upsert.params, [
    "/articles/leak/", '["exposed-token"]', '["Possible AWS key exposed"]', now.toISOString(), now.toISOString(), refreshBefore,
  ]);
});

/** A fake D1 that records what was run, optionally failing. */
function fakeD1(fail = false): D1Like & { runs: Array<{ sql: string; params: Array<string | number> }> } {
  const runs: Array<{ sql: string; params: Array<string | number> }> = [];
  return {
    runs,
    prepare: (sql) => ({
      bind: (...params) => ({
        run: async () => {
          if (fail) throw new Error("D1 unavailable");
          runs.push({ sql, params });
        },
      }),
    }),
  };
}

test("the D1 reporter records a withheld page, and the page is withheld", async () => {
  const db = fakeD1();
  const out = await applyRenderBackstop("/articles/leak/", page(`<p>${AWS_KEY}</p>`), d1WithheldReporter(db));
  assert.equal(out.status, 503);
  assert.equal(db.runs.length, 2);
  assert.equal(db.runs[1].params[0], "/articles/leak/");
  // The recorded row never holds the secret either.
  assert.doesNotMatch(JSON.stringify(db.runs), /AKIA/);
});

test("a clean page writes nothing to the database", async () => {
  const db = fakeD1();
  const out = await applyRenderBackstop("/articles/ok/", page("<p>fine</p>"), d1WithheldReporter(db));
  assert.equal(out.status, 200);
  assert.deepEqual(db.runs, []);
});

test("a database or reporter failure never lets a withheld page through", async () => {
  const out = await applyRenderBackstop("/articles/leak/", page(`<p>${AWS_KEY}</p>`), d1WithheldReporter(fakeD1(true)));
  assert.equal(out.status, 503);
  const throwing = await applyRenderBackstop("/articles/leak/", page(`<p>${AWS_KEY}</p>`), () => {
    throw new Error("reporter broke");
  });
  assert.equal(throwing.status, 503);
  // No database binding (a site not yet provisioned): still withheld, still logged.
  assert.equal((await applyRenderBackstop("/articles/leak/", page(`<p>${AWS_KEY}</p>`), d1WithheldReporter(undefined))).status, 503);
});


test("with waitUntil, the withheld 503 is sent without waiting on the report", async () => {
  let release!: () => void;
  const slow = new Promise<void>((resolve) => { release = resolve; });
  const deferred: Promise<unknown>[] = [];
  let reported = false;
  const response = await applyRenderBackstop(
    "/articles/leak/",
    page(`<p>${AWS_KEY}</p>`),
    async () => { await slow; reported = true; },
    (promise) => { deferred.push(promise); },
  );
  assert.equal(response.status, 503);
  assert.equal(reported, false);
  assert.equal(deferred.length, 1);
  release();
  await deferred[0];
  assert.equal(reported, true);
});

test("a waitUntil that throws falls back to awaiting the report, and the page is still withheld", async () => {
  let reported = false;
  const response = await applyRenderBackstop(
    "/articles/leak/",
    page(`<p>${AWS_KEY}</p>`),
    () => { reported = true; },
    () => { throw new Error("no context"); },
  );
  assert.equal(response.status, 503);
  assert.equal(reported, true);
});

test("a feed carrying a secret is withheld like a page (#2133)", async () => {
  const feed = new Response(`<?xml version="1.0"?><rss><channel><item><description>&lt;p&gt;${AWS_KEY}&lt;/p&gt;</description></item></channel></rss>`, {
    status: 200,
    headers: { "content-type": "application/xml" },
  });
  const reports: unknown[] = [];
  const response = await applyRenderBackstop("/rss.xml", feed, (r) => { reports.push(r); });
  assert.equal(response.status, 503);
  assert.equal(reports.length, 1);
  assert.ok(!(await response.text()).includes(AWS_KEY));

  const clean = await applyRenderBackstop("/feed.json", new Response(JSON.stringify({ items: [{ content_html: "<p>ok</p>" }] }), {
    headers: { "content-type": "application/feed+json; charset=utf-8" },
  }), () => { throw new Error("not withheld"); });
  assert.equal(clean.status, 200);
  assert.equal(clean.headers.get("content-type"), "application/feed+json; charset=utf-8");
});
