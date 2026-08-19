import test from "node:test";
import assert from "node:assert/strict";
import { buildSearchEntry, buildSearchIndex, searchEntries, type SearchableEntry } from "./mcp-search-entries.ts";

test("buildSearchEntry: blog entry uses title and pubDate, url is /blog/<id>", () => {
  const entry: SearchableEntry = {
    collection: "blog",
    id: "hello-world",
    data: { title: "Hello World", pubDate: "2026-01-01T00:00:00.000Z", tags: ["intro"] },
    body: "This is the body of the post, quite a bit longer than the excerpt cutoff will allow.",
  };
  const result = buildSearchEntry(entry);
  assert.ok(result);
  assert.equal(result?.title, "Hello World");
  assert.equal(result?.url, "/blog/hello-world");
  assert.equal(result?.collection, "blog");
  assert.deepEqual(result?.tags, ["intro"]);
  assert.equal(result?.date, "2026-01-01T00:00:00.000Z");
});

test("buildSearchEntry: title-less collection (notes) falls back to a body excerpt as title", () => {
  const entry: SearchableEntry = {
    collection: "notes",
    id: "note-1",
    data: { publishDate: "2026-02-01T00:00:00.000Z" },
    body: "A short note with no title field at all.",
  };
  const result = buildSearchEntry(entry);
  assert.ok(result);
  assert.equal(result?.title, "A short note with no title field at all.");
  assert.equal(result?.url, "/notes/note-1");
});

test("buildSearchEntry: title-less collection with no body falls back to url as title", () => {
  const entry: SearchableEntry = {
    collection: "photos",
    id: "photo-123",
    data: { publishDate: "2026-02-01T00:00:00.000Z" },
  };
  const result = buildSearchEntry(entry);
  assert.ok(result);
  assert.equal(result?.title, "/photos/photo-123");
  assert.equal(result?.url, "/photos/photo-123");
});

test("buildSearchEntry: unknown collection returns null", () => {
  const result = buildSearchEntry({ collection: "members", id: "x", data: {} });
  assert.equal(result, null);
});

test("buildSearchEntry: missing/invalid date returns null", () => {
  assert.equal(buildSearchEntry({ collection: "blog", id: "x", data: { title: "X" } }), null);
  assert.equal(buildSearchEntry({ collection: "blog", id: "x", data: { title: "X", pubDate: "not-a-date" } }), null);
});

test("buildSearchIndex: filters out entries with no mapping or no date", () => {
  const index = buildSearchIndex([
    { collection: "blog", id: "a", data: { title: "A", pubDate: "2026-01-01T00:00:00.000Z" } },
    { collection: "members", id: "b", data: {} },
  ]);
  assert.equal(index.length, 1);
  assert.equal(index[0].url, "/blog/a");
});

test("searchEntries: case-insensitive substring match over title/excerpt/tags", () => {
  const index = buildSearchIndex([
    { collection: "blog", id: "cats", data: { title: "All About Cats", pubDate: "2026-01-01T00:00:00.000Z" } },
    { collection: "blog", id: "dogs", data: { title: "All About Dogs", pubDate: "2026-01-02T00:00:00.000Z" } },
  ]);
  const results = searchEntries(index, "cats");
  assert.equal(results.length, 1);
  assert.equal(results[0].url, "/blog/cats");
});

test("searchEntries: empty query returns no results", () => {
  const index = buildSearchIndex([
    { collection: "blog", id: "a", data: { title: "A", pubDate: "2026-01-01T00:00:00.000Z" } },
  ]);
  assert.deepEqual(searchEntries(index, "   "), []);
});

test("searchEntries: newest first, capped at limit", () => {
  const index = buildSearchIndex([
    { collection: "blog", id: "old", data: { title: "match one", pubDate: "2026-01-01T00:00:00.000Z" } },
    { collection: "blog", id: "new", data: { title: "match two", pubDate: "2026-06-01T00:00:00.000Z" } },
  ]);
  const results = searchEntries(index, "match", 1);
  assert.equal(results.length, 1);
  assert.equal(results[0].url, "/blog/new");
});
