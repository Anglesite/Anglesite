// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
import { detectFeeds } from "../../src/detect/feeds";

function parse(html: string): Document {
  return new DOMParser().parseFromString(html, "text/html");
}

describe("detectFeeds", () => {
  it("finds RSS, Atom, and JSON feed links", () => {
    const doc = parse(`
      <html><head>
        <link rel="alternate" type="application/rss+xml" title="RSS" href="/feed.rss">
        <link rel="alternate" type="application/atom+xml" title="Atom" href="/feed.atom">
        <link rel="alternate" type="application/feed+json" href="/feed.json">
      </head><body></body></html>
    `);
    const feeds = detectFeeds(doc);
    expect(feeds).toEqual([
      { title: "RSS", url: "http://localhost:3000/feed.rss", type: "rss" },
      { title: "Atom", url: "http://localhost:3000/feed.atom", type: "atom" },
      { title: null, url: "http://localhost:3000/feed.json", type: "json" },
    ]);
  });

  it("ignores unrelated alternate links and links with no href", () => {
    const doc = parse(`
      <html><head>
        <link rel="alternate" type="text/html" href="/print">
        <link rel="alternate" type="application/rss+xml">
      </head><body></body></html>
    `);
    expect(detectFeeds(doc)).toEqual([]);
  });
});
