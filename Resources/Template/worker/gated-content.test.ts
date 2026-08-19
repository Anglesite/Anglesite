import { env } from "cloudflare:workers";
import { createMicropubStore, type PostRecord } from "@dwk/micropub";
import { beforeEach, describe, expect, it } from "vitest";
import {
  forbidden,
  handleGatedFallback,
  handlePrivateFeed,
  looksLikePostPermalink,
  renderGatedPermalink,
  renderPrivateFeed,
  requireReaderSession,
  type GatedContentEnv,
} from "./gated-content.ts";
import { READER_SESSION_COOKIE, createReaderSessionToken } from "./reader-session.ts";
import { normalizeReaderIdentity } from "./reader-identity.ts";

const testEnv = env as unknown as GatedContentEnv;

beforeEach(async () => {
  await createMicropubStore({ MICROPUB_DB: testEnv.MICROPUB_DB! }).init();
});

describe("looksLikePostPermalink", () => {
  it("matches a bare top-level slug", () => {
    expect(looksLikePostPermalink("/hello-world")).toBe(true);
  });

  it("matches a known-collection + slug", () => {
    expect(looksLikePostPermalink("/notes/hello-world")).toBe(true);
    expect(looksLikePostPermalink("/photos/abc123")).toBe(true);
  });

  it("rejects an unknown collection", () => {
    expect(looksLikePostPermalink("/blog/hello-world")).toBe(false);
  });

  it("rejects paths deeper than two segments", () => {
    expect(looksLikePostPermalink("/notes/2026/hello-world")).toBe(false);
  });

  it("rejects a slug with disallowed characters (e.g. a file extension)", () => {
    expect(looksLikePostPermalink("/styles.css")).toBe(false);
    expect(looksLikePostPermalink("/notes/hello_world")).toBe(false);
  });

  it("rejects the bare root", () => {
    expect(looksLikePostPermalink("/")).toBe(false);
  });
});

async function sessionCookieFor(me: string): Promise<string> {
  const token = await createReaderSessionToken(normalizeReaderIdentity(me), testEnv.TOKEN_SIGNING_KEY);
  return `${READER_SESSION_COOKIE}=${token}`;
}

describe("requireReaderSession", () => {
  it("returns the normalized identity for a valid session cookie", async () => {
    const cookie = await sessionCookieFor("https://alice.example/");
    const request = new Request("https://site.example/notes/hello", { headers: { Cookie: cookie } });
    expect(await requireReaderSession(request, testEnv)).toBe("alice.example");
  });

  it("returns null when there is no cookie", async () => {
    const request = new Request("https://site.example/notes/hello");
    expect(await requireReaderSession(request, testEnv)).toBeNull();
  });

  it("returns null for a tampered cookie", async () => {
    const request = new Request("https://site.example/notes/hello", {
      headers: { Cookie: `${READER_SESSION_COOKIE}=garbage` },
    });
    expect(await requireReaderSession(request, testEnv)).toBeNull();
  });
});

describe("forbidden", () => {
  it("returns a 403 with a sign-in link echoing the requester's own path", async () => {
    const request = new Request("https://site.example/notes/secret?x=1");
    const response = forbidden(request);
    expect(response.status).toBe(403);
    const body = await response.text();
    expect(body).toContain(`/contacts/signin?redirect=${encodeURIComponent("/notes/secret?x=1")}`);
  });

  it("returns no body for a HEAD request", async () => {
    const request = new Request("https://site.example/notes/secret", { method: "HEAD" });
    const response = forbidden(request);
    expect(response.status).toBe(403);
    expect(await response.text()).toBe("");
  });
});

interface MakeRecordOptions {
  url?: string;
  deleted?: boolean;
  name?: unknown[];
  content?: unknown[];
  published?: unknown[];
  category?: unknown[];
  photo?: unknown[];
  visibility?: unknown[];
}

function makeRecord(overrides: MakeRecordOptions = {}): PostRecord {
  const { url, deleted, ...properties } = overrides;
  return {
    url: url ?? "https://site.example/notes/hello",
    type: "h-entry",
    properties: {
      name: ["Hello"],
      content: [{ html: "<p>Hi there</p>" }],
      published: ["2026-08-18T12:00:00Z"],
      category: ["indieweb"],
      visibility: ["contacts"],
      ...properties,
    },
    deleted: deleted ?? false,
    createdAt: 1_000,
    updatedAt: 1_000,
  };
}

describe("renderGatedPermalink", () => {
  it("renders h-entry markup with name, content, permalink, and categories", async () => {
    const response = renderGatedPermalink(makeRecord(), "GET");
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("private, no-store");
    const body = await response.text();
    expect(body).toContain('<article class="h-entry">');
    expect(body).toContain('<h1 class="p-name">Hello</h1>');
    expect(body).toContain('<div class="e-content"><p>Hi there</p></div>');
    expect(body).toContain('<a class="u-url" href="https://site.example/notes/hello">');
    expect(body).toContain('class="dt-published" datetime="2026-08-18T12:00:00Z"');
    expect(body).toContain('<a class="p-category">indieweb</a>');
  });

  it("renders photos as u-photo images", async () => {
    const response = renderGatedPermalink(
      makeRecord({ photo: [{ value: "https://site.example/media/1.jpg", alt: "a cat" }] }),
      "GET",
    );
    const body = await response.text();
    expect(body).toContain('<img class="u-photo" src="https://site.example/media/1.jpg" alt="a cat">');
  });

  it("omits the body for a HEAD request", async () => {
    const response = renderGatedPermalink(makeRecord(), "HEAD");
    expect(await response.text()).toBe("");
  });
});

describe("renderPrivateFeed", () => {
  it("renders an h-feed wrapping each post", async () => {
    const response = renderPrivateFeed([makeRecord(), makeRecord({ url: "https://site.example/notes/second", name: ["Second"] })], "GET");
    const body = await response.text();
    expect(body).toContain('<div class="h-feed">');
    expect(body).toContain('<h1 class="p-name">Private feed</h1>');
    expect(body).toContain('<h2 class="p-name">Hello</h2>');
    expect(body).toContain('<h2 class="p-name">Second</h2>');
  });

  it("renders an empty-state message with no posts", async () => {
    const response = renderPrivateFeed([], "GET");
    expect(await response.text()).toContain("No restricted posts yet.");
  });
});

describe("handleGatedFallback", () => {
  it("returns null for a non-GET/HEAD method", async () => {
    const request = new Request("https://site.example/notes/hello", { method: "POST" });
    expect(await handleGatedFallback(request, testEnv, "/notes/hello")).toBeNull();
  });

  it("returns null for a path that doesn't look like a post permalink", async () => {
    const request = new Request("https://site.example/favicon.ico");
    expect(await handleGatedFallback(request, testEnv, "/favicon.ico")).toBeNull();
  });

  it("returns null when MICROPUB_DB isn't bound", async () => {
    const request = new Request("https://site.example/notes/hello");
    const { MICROPUB_DB: _unused, ...envWithoutDB } = testEnv;
    expect(await handleGatedFallback(request, envWithoutDB, "/notes/hello")).toBeNull();
  });

  it("returns 403 with no session, without ever touching the store", async () => {
    const request = new Request("https://site.example/notes/does-not-exist");
    const response = await handleGatedFallback(request, testEnv, "/notes/does-not-exist");
    expect(response?.status).toBe(403);
  });

  it("returns null when the session is valid but no such post exists", async () => {
    const cookie = await sessionCookieFor("https://alice.example/");
    const request = new Request("https://site.example/notes/does-not-exist", { headers: { Cookie: cookie } });
    expect(await handleGatedFallback(request, testEnv, "/notes/does-not-exist")).toBeNull();
  });

  it("returns null when the session is valid but the post is public (not contacts)", async () => {
    const store = createMicropubStore({ MICROPUB_DB: testEnv.MICROPUB_DB! });
    await store.insertPost({
      url: "https://site.example/notes/public-post",
      type: "h-entry",
      properties: { name: ["Public"], visibility: ["public"] },
      now: 1_000,
    });
    const cookie = await sessionCookieFor("https://alice.example/");
    const request = new Request("https://site.example/notes/public-post", { headers: { Cookie: cookie } });
    expect(await handleGatedFallback(request, testEnv, "/notes/public-post")).toBeNull();
  });

  it("returns null when the post is soft-deleted", async () => {
    const store = createMicropubStore({ MICROPUB_DB: testEnv.MICROPUB_DB! });
    await store.insertPost({
      url: "https://site.example/notes/deleted-post",
      type: "h-entry",
      properties: { name: ["Gone"], visibility: ["contacts"] },
      now: 1_000,
    });
    await store.setDeleted("https://site.example/notes/deleted-post", true, 2_000);
    const cookie = await sessionCookieFor("https://alice.example/");
    const request = new Request("https://site.example/notes/deleted-post", { headers: { Cookie: cookie } });
    expect(await handleGatedFallback(request, testEnv, "/notes/deleted-post")).toBeNull();
  });

  it("renders the post for an authorized, allowlisted reader", async () => {
    const store = createMicropubStore({ MICROPUB_DB: testEnv.MICROPUB_DB! });
    await store.insertPost({
      url: "https://site.example/notes/restricted-post",
      type: "h-entry",
      properties: { name: ["Restricted"], visibility: ["contacts"] },
      now: 1_000,
    });
    const cookie = await sessionCookieFor("https://alice.example/");
    const request = new Request("https://site.example/notes/restricted-post", { headers: { Cookie: cookie } });
    const response = await handleGatedFallback(request, testEnv, "/notes/restricted-post");
    expect(response?.status).toBe(200);
    expect(await response!.text()).toContain('<h1 class="p-name">Restricted</h1>');
  });
});

describe("handlePrivateFeed", () => {
  it("returns 503 when MICROPUB_DB isn't bound", async () => {
    const request = new Request("https://site.example/contacts/feed");
    const { MICROPUB_DB: _unused, ...envWithoutDB } = testEnv;
    const response = await handlePrivateFeed(request, envWithoutDB);
    expect(response.status).toBe(503);
  });

  it("returns 403 with no session", async () => {
    const request = new Request("https://site.example/contacts/feed");
    const response = await handlePrivateFeed(request, testEnv);
    expect(response.status).toBe(403);
  });

  it("lists only contacts-visibility posts for an authorized reader", async () => {
    const store = createMicropubStore({ MICROPUB_DB: testEnv.MICROPUB_DB! });
    await store.insertPost({
      url: "https://site.example/notes/feed-public",
      type: "h-entry",
      properties: { name: ["Feed Public"], visibility: ["public"] },
      now: 1_000,
    });
    await store.insertPost({
      url: "https://site.example/notes/feed-restricted",
      type: "h-entry",
      properties: { name: ["Feed Restricted"], visibility: ["contacts"] },
      now: 2_000,
    });
    const cookie = await sessionCookieFor("https://alice.example/");
    const request = new Request("https://site.example/contacts/feed", { headers: { Cookie: cookie } });
    const response = await handlePrivateFeed(request, testEnv);
    expect(response.status).toBe(200);
    const body = await response.text();
    expect(body).toContain("Feed Restricted");
    expect(body).not.toContain("Feed Public");
  });
});
