import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { ARTICLE_FIELDS, articleView, imageURL, unmappedFields } from "./emdash-articles.ts";

const seed = JSON.parse(readFileSync(new URL("../../seed/seed.json", import.meta.url), "utf-8"));

test("the seed's articles collection declares exactly the fields the page maps", () => {
  const articles = seed.collections.find((c: { slug: string }) => c.slug === "articles");
  assert.ok(articles, "seed.json has an articles collection");
  assert.deepEqual(articles.fields.map((f: { slug: string }) => f.slug).sort(), [...ARTICLE_FIELDS].sort());
  assert.equal(articles.urlPattern, "/articles/{slug}");
});

test("the seed defines no collection besides articles", () => {
  // Pages, layout and theme stay in git (decision 6); only articles come from EmDash so far.
  assert.deepEqual(seed.collections.map((c: { slug: string }) => c.slug), ["articles"]);
});

test("maps an entry to the h-entry fields", () => {
  const published = new Date("2026-09-01T12:00:00Z");
  const view = articleView({
    id: "01J", slug: "council-vote", title: "Council vote", summary: "It passed.",
    image: { id: "k1", alt: "The council chamber", meta: { storageKey: "2026/09/vote.jpg" } },
    publishedAt: published,
    bylines: [{ byline: { displayName: "Ana Ruiz" } }, { byline: {} }],
    terms: { tag: [{ label: "Politics" }, { label: "" }] },
  });
  assert.deepEqual(view, {
    slug: "council-vote", title: "Council vote", summary: "It passed.", publishDate: published,
    updated: undefined, image: "/_emdash/api/media/file/2026%2F09%2Fvote.jpg",
    imageAlt: "The council chamber", tags: ["Politics"], authors: ["Ana Ruiz"],
  });
});

test("an entry without a slug has no page", () => {
  assert.equal(articleView({ id: "01J", slug: null, title: "Draft" }), null);
});

test("an external image src must be https or site-relative", () => {
  assert.equal(imageURL({ src: "/images/a.jpg" }), "/images/a.jpg");
  for (const src of ["http://cdn.example/a.jpg", "//cdn.example/a.jpg", "javascript:alert(1)", "data:image/png;base64,AA", "not a url"]) {
    assert.equal(imageURL({ src }), undefined, src);
  }
});

test("image URLs: external src wins, then storage key, then id", () => {
  assert.equal(imageURL({ src: "https://cdn.example/a.jpg", id: "x" }), "https://cdn.example/a.jpg");
  assert.equal(imageURL({ id: "abc" }), "/_emdash/api/media/file/abc");
  assert.equal(imageURL({}), undefined);
  assert.equal(imageURL(undefined), undefined);
});

test("reports authored fields the page doesn't render", () => {
  assert.deepEqual(unmappedFields({ id: "1", slug: "a", title: "t", updatedAt: new Date(), pullquote: "x" }), ["pullquote"]);
});

test("tags come from the seed's tag taxonomy on articles", () => {
  assert.deepEqual(seed.taxonomies, [
    { name: "tag", label: "Tags", labelSingular: "Tag", hierarchical: false, collections: ["articles"] },
  ]);
});

test("a real EmDash 1.0.1 article entry has no unmapped fields", () => {
  // The keys of `entry.data` for a seeded article, read from a running EmDash 1.0.1 site. The
  // article page logs unmapped fields on every render, so a system field missing from the
  // allowlist would log a false warning for every article.
  const keys = ["authorId", "byline", "bylines", "content", "createdAt", "id", "image", "locale",
    "primaryBylineId", "publishedAt", "scheduledAt", "slug", "status", "summary", "terms", "title",
    "translationGroup", "updatedAt"];
  const data = Object.fromEntries(keys.map((k) => [k, k === "slug" ? "a" : k === "id" ? "1" : null]));
  assert.deepEqual(unmappedFields(data as never), []);
});

