import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { ENTRY_COLLECTIONS } from "./collections.ts";
import {
  SEARCH_INDEX_COLLECTIONS,
  buildSearchEntry,
  buildSearchIndex,
  searchEntries,
  type SearchableEntry,
} from "./mcp-search-entries.ts";

test("SEARCH_INDEX_COLLECTIONS covers blog as well as every ENTRY_COLLECTIONS member", () => {
  // ENTRY_COLLECTIONS is HENTRY_COLLECTIONS + events/reviews — it excludes `blog` by
  // construction, which is what made search_posts blind to the template's default content type.
  assert.equal(ENTRY_COLLECTIONS.includes("blog" as never), false);
  assert.ok(SEARCH_INDEX_COLLECTIONS.includes("blog"));
  for (const collection of ENTRY_COLLECTIONS) {
    assert.ok(SEARCH_INDEX_COLLECTIONS.includes(collection), `missing ${collection}`);
  }
});

test("every SEARCH_INDEX_COLLECTIONS member has a usable search field mapping", () => {
  for (const collection of SEARCH_INDEX_COLLECTIONS) {
    const entry: SearchableEntry = {
      collection,
      id: "probe",
      // Every mapped date field the table uses, so one probe satisfies all collections.
      data: { pubDate: "2026-01-01T00:00:00.000Z", publishDate: "2026-01-01T00:00:00.000Z", start: "2026-01-01T00:00:00.000Z" },
      body: "probe body",
    };
    assert.ok(buildSearchEntry(entry), `${collection} has no SEARCH_FIELDS mapping`);
  }
});

test("the search-index endpoint iterates SEARCH_INDEX_COLLECTIONS, not bare ENTRY_COLLECTIONS", () => {
  // Drift guard for the actual wiring: a unit test of buildSearchEntry("blog") passes even when
  // the endpoint never hands blog entries in (which is exactly how #1576's bug shipped).
  const endpoint = readFileSync(
    join(dirname(fileURLToPath(import.meta.url)), "..", "pages", "mcp-search-index.json.ts"),
    "utf8",
  );
  assert.match(endpoint, /for \(const collection of SEARCH_INDEX_COLLECTIONS\)/);
});

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
