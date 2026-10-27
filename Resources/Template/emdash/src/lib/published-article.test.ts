import { test } from "node:test";
import assert from "node:assert/strict";
import { articlePath, federatedKey, publishedArticle, syndicationOrigin } from "./published-article.ts";

const record = {
  id: "01JCOUNCIL",
  slug: "council-vote",
  status: "published",
  publishedAt: "2026-10-27T09:00:00.000Z",
  data: {
    title: "Council approves budget",
    summary: "The vote was 5–2.",
    content: [{ _type: "block", _key: "b1", style: "normal", markDefs: [], children: [{ _type: "span", _key: "s1", text: "It passed.", marks: [] }] }],
    image: { id: "k1", alt: "The chamber", meta: { storageKey: "2026/10/vote.jpg" } },
  },
};

test("an article EmDash just published maps onto what syndication sends", () => {
  assert.deepEqual(publishedArticle(record, "https://news.example"), {
    url: "https://news.example/articles/council-vote/",
    type: "Article",
    name: "Council approves budget",
    summary: "The vote was 5–2.",
    contentHtml: "<p>It passed.</p>",
    published: "2026-10-27T09:00:00.000Z",
    image: { url: "https://news.example/_emdash/api/media/file/2026%2F10%2Fvote.jpg", name: "The chamber" },
  });
});

test("an entry with no public URL, no publication time, or not live, isn't sent out", () => {
  assert.equal(publishedArticle({ ...record, slug: "" }, "https://news.example"), null);
  assert.equal(publishedArticle({ ...record, publishedAt: null }, "https://news.example"), null);
  assert.equal(publishedArticle({ ...record, publishedAt: "not a date" }, "https://news.example"), null);
  assert.equal(publishedArticle({ ...record, status: "draft" }, "https://news.example"), null);
});

test("the canonical origin is the first http(s) candidate", () => {
  assert.equal(syndicationOrigin(undefined, "https://news.example/some/path", "https://x.workers.dev"), "https://news.example");
  assert.equal(syndicationOrigin("", "not a url", "https://x.workers.dev/"), "https://x.workers.dev");
  assert.equal(syndicationOrigin("javascript:alert(1)", undefined), null);
});

test("an entry is posted to followers once, keyed on EmDash's id", () => {
  assert.equal(federatedKey(record), "federated:01JCOUNCIL");
  assert.equal(federatedKey({ ...record, slug: "renamed" }), "federated:01JCOUNCIL");
  assert.equal(federatedKey({ ...record, id: undefined }), null);
  assert.equal(articlePath("a b"), "/articles/a%20b/");
});

test("an image that isn't a URL is left off, and the article still goes out", () => {
  const article = publishedArticle({ ...record, data: { ...record.data, image: { src: "https://" } } }, "https://news.example");
  assert.ok(article);
  assert.equal(article.image, undefined);
  assert.equal(article.url, "https://news.example/articles/council-vote/");
});
