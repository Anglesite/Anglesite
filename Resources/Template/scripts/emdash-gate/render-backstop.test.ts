import test from "node:test";
import assert from "node:assert/strict";
import { applyRenderBackstop, renderIssues, shouldCheck, WITHHELD_LOG_EVENT } from "./render-backstop";

const page = (body: string, headers: Record<string, string> = { "content-type": "text/html; charset=utf-8" }) =>
  new Response(`<!doctype html><html><body>${body}</body></html>`, { status: 200, headers: { "x-cache-hint": "articles", ...headers } });

const AWS_KEY = "AKIA" + "ABCDEFGHIJKLMNOP";

test("only public HTML pages are checked", () => {
  assert.equal(shouldCheck("/articles/vote/", "text/html; charset=utf-8"), true);
  assert.equal(shouldCheck("/articles/vote/", "TEXT/HTML"), true);
  assert.equal(shouldCheck("/articles/rss.xml", "application/rss+xml"), false);
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
  const out = await applyRenderBackstop("/articles/vote/", page("<h1>Council vote</h1>"), (r) => reports.push(r));
  assert.equal(out.status, 200);
  assert.equal(out.headers.get("x-cache-hint"), "articles");
  assert.match(await out.text(), /Council vote/);
  assert.deepEqual(reports, []);
});

test("a failing page is withheld as an uncacheable 503 and reported, without saying why to the reader", async () => {
  const reports: Array<{ event: string; path: string; categories: string[]; messages: string[] }> = [];
  const out = await applyRenderBackstop("/articles/leak/", page(`<p>${AWS_KEY}</p><a href="/keystatic/">x</a>`), (r) => reports.push(r));
  assert.equal(out.status, 503);
  assert.equal(out.headers.get("cache-control"), "no-store");
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
  const out = await applyRenderBackstop("/articles/x/", gz, (r) => reports.push(r));
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
  const out = await applyRenderBackstop("/articles/x/", broken, (r) => reports.push(r));
  assert.equal(out.status, 503);
  assert.deepEqual(reports.map((r) => r.categories), [["render-backstop-failed"]]);
});

test("non-HTML and admin responses are returned untouched, unread", async () => {
  const feed = new Response("<rss/>", { headers: { "content-type": "application/rss+xml" } });
  assert.equal(await applyRenderBackstop("/articles/rss.xml", feed), feed);
  const admin = page(`<p>${AWS_KEY}</p>`);
  assert.equal(await applyRenderBackstop("/_emdash/admin", admin), admin);
});
