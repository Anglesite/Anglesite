// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
import { findFirstHCard, parseMicroformats, summarizeTypes } from "../../src/detect/microformats";

function parse(html: string): Document {
  return new DOMParser().parseFromString(html, "text/html");
}

describe("parseMicroformats", () => {
  it("parses an h-card with explicit properties", () => {
    const doc = parse(`
      <body>
        <div class="h-card">
          <a class="p-name u-url" href="https://example.com/glenn">Glenn Jones</a>
          <p class="p-org">Example Org</p>
        </div>
      </body>
    `);
    const mf2 = parseMicroformats(doc);
    const hCard = findFirstHCard(mf2);
    expect(hCard?.type).toEqual(["h-card"]);
    expect(hCard?.properties.name).toEqual(["Glenn Jones"]);
    expect(hCard?.properties.org).toEqual(["Example Org"]);
  });

  it("returns null when there is no h-card", () => {
    const doc = parse(`<body><p>Nothing here.</p></body>`);
    expect(findFirstHCard(parseMicroformats(doc))).toBeNull();
  });

  it("collects rel=me links", () => {
    const doc = parse(`<body><a rel="me" href="https://fosstodon.org/@example">Mastodon</a></body>`);
    const mf2 = parseMicroformats(doc);
    expect(mf2.rels.me).toEqual(["https://fosstodon.org/@example"]);
  });

  it("summarizes root and nested mf2 type counts", () => {
    const doc = parse(`
      <body>
        <div class="h-feed">
          <div class="h-entry"><p class="p-name">One</p></div>
          <div class="h-entry"><p class="p-name">Two</p></div>
        </div>
      </body>
    `);
    const counts = summarizeTypes(parseMicroformats(doc));
    expect(counts["h-feed"]).toBe(1);
    expect(counts["h-entry"]).toBe(2);
  });
});
