import test from "node:test";
import assert from "node:assert/strict";
import {
  SEARCH_POSTS_TOOL,
  FETCH_POST_MARKDOWN_TOOL,
  buildMarkdownURL,
  formatSearchResults,
  searchPosts,
  fetchPostMarkdown,
  type PagefindModule,
} from "./webmcp-tools.ts";

test("SEARCH_POSTS_TOOL has the anglesite_ prefix and a query-required input schema", () => {
  assert.equal(SEARCH_POSTS_TOOL.name, "anglesite_search_posts");
  assert.equal(SEARCH_POSTS_TOOL.inputSchema.type, "object");
  assert.deepEqual((SEARCH_POSTS_TOOL.inputSchema as any).required, ["query"]);
});

test("FETCH_POST_MARKDOWN_TOOL has the anglesite_ prefix and a path-required input schema", () => {
  assert.equal(FETCH_POST_MARKDOWN_TOOL.name, "anglesite_fetch_post_markdown");
  assert.deepEqual((FETCH_POST_MARKDOWN_TOOL.inputSchema as any).required, ["path"]);
});

test("buildMarkdownURL: strips a trailing slash and appends .md", () => {
  assert.equal(buildMarkdownURL("/blog/hello-world/"), "/blog/hello-world.md");
});

test("buildMarkdownURL: a path with no trailing slash still gets .md appended", () => {
  assert.equal(buildMarkdownURL("/blog/hello-world"), "/blog/hello-world.md");
});

test("buildMarkdownURL: root path", () => {
  assert.equal(buildMarkdownURL("/"), ".md");
});

test("buildMarkdownURL: rejects a protocol-relative path", () => {
  assert.throws(() => buildMarkdownURL("//evil.com/x"), /not a site-relative path/);
});

test("buildMarkdownURL: rejects an absolute URL", () => {
  assert.throws(() => buildMarkdownURL("https://evil.com/x"), /not a site-relative path/);
});

test("formatSearchResults: empty results returns a plain 'no results' text response", () => {
  const result = formatSearchResults([]);
  assert.deepEqual(result, { content: [{ type: "text", text: "No results found." }] });
});

test("formatSearchResults: formats title, url, and a stripped-HTML excerpt", () => {
  const result = formatSearchResults([
    { url: "/blog/hello-world/", meta: { title: "Hello World" }, excerpt: "This is <mark>hello</mark> world." },
  ]);
  assert.deepEqual(result, {
    content: [{ type: "text", text: "1. Hello World — /blog/hello-world/\n   This is hello world." }],
  });
});

test("formatSearchResults: falls back to the URL when no title is present", () => {
  const result = formatSearchResults([{ url: "/notes/hello-note/" }]);
  assert.deepEqual(result, {
    content: [{ type: "text", text: "1. /notes/hello-note/ — /notes/hello-note/" }],
  });
});

test("formatSearchResults: numbers multiple results in order", () => {
  const result = formatSearchResults([
    { url: "/a/", meta: { title: "A" } },
    { url: "/b/", meta: { title: "B" } },
  ]);
  assert.deepEqual(result, {
    content: [{ type: "text", text: "1. A — /a/\n2. B — /b/" }],
  });
});

// Fake Pagefind module — enough of the shape searchPosts() consumes to drive it without a real
// Pagefind build (which only exists after postbuild runs against dist/).
function fakePagefind(urls: string[]): PagefindModule {
  return {
    async search() {
      return {
        results: urls.map((url) => ({ data: async () => ({ url }) })),
      };
    },
  };
}

test("searchPosts: a successful search returns formatted results", async () => {
  const result = await searchPosts({ query: "hello" }, async () => fakePagefind(["/blog/hello-world/"]));
  assert.deepEqual(result, {
    content: [{ type: "text", text: "1. /blog/hello-world/ — /blog/hello-world/" }],
  });
});

test("searchPosts: a loadPagefind rejection degrades to 'Search failed.' text", async () => {
  const result = await searchPosts({ query: "hello" }, async () => {
    throw new Error("network error");
  });
  assert.deepEqual(result, { content: [{ type: "text", text: "Search failed." }] });
});

test("searchPosts: missing args default to an empty query rather than throwing", async () => {
  const result = await searchPosts(undefined, async () => fakePagefind([]));
  assert.deepEqual(result, { content: [{ type: "text", text: "No results found." }] });
});

test("searchPosts: clamps a negative or huge limit into the 1-20 range", async () => {
  const urls = Array.from({ length: 30 }, (_, i) => `/post-${i}/`);

  const negative = await searchPosts({ query: "x", limit: -5 }, async () => fakePagefind(urls));
  assert.equal(negative.content[0].text.split("\n").length, 1, "limit clamps up to at least 1 result");

  const huge = await searchPosts({ query: "x", limit: 1000 }, async () => fakePagefind(urls));
  assert.equal(huge.content[0].text.split("\n").length, 20, "limit clamps down to at most 20 results");
});

function fakeResponse(ok: boolean, text: string): Response {
  return { ok, text: async () => text } as Response;
}

test("fetchPostMarkdown: a non-OK response returns 'Not found: ...' text", async () => {
  const result = await fetchPostMarkdown({ path: "/blog/missing/" }, async () => fakeResponse(false, ""));
  assert.deepEqual(result, { content: [{ type: "text", text: "Not found: /blog/missing/" }] });
});

test("fetchPostMarkdown: an OK response returns the fetched body text", async () => {
  const result = await fetchPostMarkdown({ path: "/blog/hello-world/" }, async () =>
    fakeResponse(true, "# Hello World"),
  );
  assert.deepEqual(result, { content: [{ type: "text", text: "# Hello World" }] });
});

test("fetchPostMarkdown: a doFetch rejection returns 'Failed to fetch: ...' text", async () => {
  const result = await fetchPostMarkdown({ path: "/blog/hello-world/" }, async () => {
    throw new Error("offline");
  });
  assert.deepEqual(result, { content: [{ type: "text", text: "Failed to fetch: /blog/hello-world/" }] });
});

test("fetchPostMarkdown: a non-site-relative path degrades to 'Failed to fetch: ...' text", async () => {
  const result = await fetchPostMarkdown({ path: "https://evil.com/x" }, async () => fakeResponse(true, "nope"));
  assert.deepEqual(result, { content: [{ type: "text", text: "Failed to fetch: https://evil.com/x" }] });
});

test("fetchPostMarkdown: missing args default gracefully (no throw out of execute)", async () => {
  // The default path "" isn't site-relative per buildMarkdownURL's guard, so this degrades to
  // the same "Failed to fetch" text response as any other invalid path — the point being that
  // calling fetchPostMarkdown(undefined, ...) never throws synchronously at destructuring.
  const result = await fetchPostMarkdown(undefined, async () => fakeResponse(true, "root"));
  assert.deepEqual(result, { content: [{ type: "text", text: "Failed to fetch: " }] });
});
