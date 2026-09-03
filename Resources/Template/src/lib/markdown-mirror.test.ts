import test from "node:test";
import assert from "node:assert/strict";
import { renderMarkdownMirror, MARKDOWN_MIRROR_CONTENT_TYPE } from "./markdown-mirror.ts";
import { ENTRY_COLLECTIONS } from "./collections.ts";

test("every ENTRY_COLLECTIONS member has a mirror field mapping", () => {
  for (const c of ENTRY_COLLECTIONS) {
    // renderMarkdownMirror throws for an unmapped collection — this call succeeding for every
    // member is the assertion.
    renderMarkdownMirror({ collection: c, id: "probe", data: {}, body: "b" });
  }
});

test("renderMarkdownMirror: blog entry gets title + date frontmatter, no tags", () => {
  const out = renderMarkdownMirror({
    collection: "blog",
    id: "welcome-to-your-blog",
    data: { title: "Welcome to your blog", pubDate: new Date("2026-01-01T00:00:00.000Z"), draft: false },
    body: "This is your blog's first post.",
  });
  assert.equal(
    out,
    '---\ntitle: "Welcome to your blog"\ndate: 2026-01-01T00:00:00.000Z\n---\n\n' +
      "This is your blog's first post.",
  );
});

test("renderMarkdownMirror: notes entry has no title field, includes tags", () => {
  const out = renderMarkdownMirror({
    collection: "notes",
    id: "hello-note",
    data: { publishDate: new Date("2026-06-26T12:00:00.000Z"), tags: ["hello", "hello world"] },
    body: "This is your first note.",
  });
  assert.equal(
    out,
    '---\ndate: 2026-06-26T12:00:00.000Z\ntags: ["hello", "hello world"]\n---\n\n' +
      "This is your first note.",
  );
});

test("renderMarkdownMirror: events entry uses name as title and start as date", () => {
  const out = renderMarkdownMirror({
    collection: "events",
    id: "hello-event",
    data: { name: "Hello Event", start: new Date("2026-03-01T18:00:00.000Z") },
    body: "Join us!",
  });
  assert.equal(
    out,
    '---\ntitle: "Hello Event"\ndate: 2026-03-01T18:00:00.000Z\n---\n\nJoin us!',
  );
});

test("renderMarkdownMirror: reviews entry uses itemReviewed as title", () => {
  const out = renderMarkdownMirror({
    collection: "reviews",
    id: "hello-review",
    data: { itemReviewed: "The Widget 3000", rating: 4, publishDate: new Date("2026-02-01T00:00:00.000Z") },
    body: "Pretty good widget.",
  });
  assert.equal(
    out,
    '---\ntitle: "The Widget 3000"\ndate: 2026-02-01T00:00:00.000Z\n---\n\nPretty good widget.',
  );
});

test("renderMarkdownMirror: likes entry has no title and no tags field, still renders", () => {
  const out = renderMarkdownMirror({
    collection: "likes",
    id: "hello-like",
    data: { likeOf: "https://example.com/post", publishDate: new Date("2026-04-01T00:00:00.000Z") },
    body: "",
  });
  assert.equal(out, "---\ndate: 2026-04-01T00:00:00.000Z\n---\n\n");
});

test("renderMarkdownMirror: an entry with no title, no date, and no tags renders body only", () => {
  const out = renderMarkdownMirror({ collection: "notes", id: "bare", data: {}, body: "Just text." });
  assert.equal(out, "Just text.");
});

test("renderMarkdownMirror: a title containing a colon and quotes is JSON-quoted safely", () => {
  const out = renderMarkdownMirror({
    collection: "articles",
    id: "quoted",
    data: { title: 'A "Quoted" Title: With Colon', publishDate: new Date("2026-05-01T00:00:00.000Z") },
    body: "Body.",
  });
  assert.equal(
    out,
    '---\ntitle: "A \\"Quoted\\" Title: With Colon"\ndate: 2026-05-01T00:00:00.000Z\n---\n\nBody.',
  );
});

test("renderMarkdownMirror: non-string entries in tags are filtered out", () => {
  const out = renderMarkdownMirror({
    collection: "notes",
    id: "mixed-tags",
    data: { publishDate: new Date("2026-06-26T12:00:00.000Z"), tags: ["hello", 42, null, "world"] },
    body: "Body.",
  });
  assert.equal(
    out,
    '---\ndate: 2026-06-26T12:00:00.000Z\ntags: ["hello", "world"]\n---\n\nBody.',
  );
});

test("renderMarkdownMirror: an empty tags array omits the tags line", () => {
  const out = renderMarkdownMirror({
    collection: "notes",
    id: "empty-tags",
    data: { publishDate: new Date("2026-06-26T12:00:00.000Z"), tags: [] },
    body: "Body.",
  });
  assert.equal(out, "---\ndate: 2026-06-26T12:00:00.000Z\n---\n\nBody.");
});

test("renderMarkdownMirror: an unparseable date string omits the date line", () => {
  const out = renderMarkdownMirror({
    collection: "notes",
    id: "bad-date",
    data: { publishDate: "not a date" },
    body: "Body.",
  });
  assert.equal(out, "Body.");
});

test("renderMarkdownMirror: throws for an unrouted collection name", () => {
  assert.throws(
    () => renderMarkdownMirror({ collection: "members", id: "x", data: {}, body: "" }),
    /no mirror field mapping for collection "members"/,
  );
});

test("MARKDOWN_MIRROR_CONTENT_TYPE is text/markdown with a UTF-8 charset", () => {
  assert.equal(MARKDOWN_MIRROR_CONTENT_TYPE, "text/markdown; charset=utf-8");
});
