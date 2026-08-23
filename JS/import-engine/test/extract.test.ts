import { describe, expect, it } from "vitest";
import { JSDOM } from "jsdom";
import { extractPage } from "../src/extract.ts";

const ARTICLE = `<!doctype html><html lang="en"><head><title>Hello — My Site</title>
<link rel="canonical" href="https://example.com/blog/hello">
<link rel="alternate" type="application/rss+xml" href="/feed.xml"></head>
<body><article class="h-entry"><h1 class="p-name">Hello</h1>
<time class="dt-published" datetime="2024-05-01T10:00:00Z">May 1</time>
<div class="e-content"><p>First <strong>post</strong>.</p>
<img src="https://example.com/images/cat.jpg" alt="a cat"></div></article>
<footer>© nav cruft that Readability should drop</footer></body></html>`;

describe("extractPage", () => {
  it("extracts title, markdown, images, mf2, and feed links", () => {
    const dom = new JSDOM(ARTICLE, { url: "https://example.com/blog/hello/" });
    const record = extractPage(dom.window.document, "https://example.com/blog/hello/");
    // Readability returns its own title verbatim from <title> here (the short fixture body
    // doesn't out-rank the doc title as a "better" H1 candidate); the split-on-dash cleanup in
    // extractPage only kicks in for the doc.title fallback path, not Readability's own title.
    expect(record.title).toBe("Hello — My Site");
    expect(record.lang).toBe("en");
    expect(record.canonical).toBe("https://example.com/blog/hello");
    expect(record.markdown).toContain("First **post**.");
    expect(record.images).toContain("https://example.com/images/cat.jpg");
    expect(record.feedLinks).toEqual(["https://example.com/feed.xml"]);
    const mf2 = JSON.parse(record.mf2JSON ?? "{}");
    expect(mf2.items[0].type).toContain("h-entry");
    expect(record.publishedISO).toBe("2024-05-01T10:00:00Z");
  });
});
