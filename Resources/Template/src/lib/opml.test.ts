import { test } from "node:test";
import assert from "node:assert/strict";
import { renderOpml } from "./opml.ts";

test("renders a valid OPML 2.0 document with one outline per entry", async () => {
  const response = renderOpml("My Blogroll", [
    {
      text: "Friend's Blog",
      title: "Friend's Blog",
      xmlUrl: "https://friend.example/feed.xml",
      htmlUrl: "https://friend.example",
    },
  ]);
  const xml = await response.text();
  assert.match(xml, /<opml version="2.0">/);
  assert.match(xml, /<title>My Blogroll<\/title>/);
  assert.match(
    xml,
    /<outline type="rss" text="Friend's Blog" title="Friend's Blog" xmlUrl="https:\/\/friend\.example\/feed\.xml" htmlUrl="https:\/\/friend\.example"\s*\/>/,
  );
});

test("escapes XML-special characters in text/title", async () => {
  const response = renderOpml("Blogroll", [
    {
      text: "A & B",
      title: "A & B",
      xmlUrl: "https://x.example/feed.xml",
      htmlUrl: "https://x.example",
    },
  ]);
  const xml = await response.text();
  assert.match(xml, /text="A &amp; B"/);
});

test("renders an empty <body> for no entries", async () => {
  const response = renderOpml("Blogroll", []);
  const xml = await response.text();
  assert.match(xml, /<body>\s*<\/body>/);
});

test("sets the OPML content type", async () => {
  const response = renderOpml("Blogroll", []);
  assert.equal(response.headers.get("Content-Type"), "text/x-opml; charset=utf-8");
});
