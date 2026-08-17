import test from "node:test";
import assert from "node:assert/strict";
import {
  SEARCH_POSTS_TOOL,
  FETCH_POST_MARKDOWN_TOOL,
  buildMarkdownURL,
  formatSearchResults,
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
