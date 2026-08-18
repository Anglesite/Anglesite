import { describe, expect, it } from "vitest";
import { badgeTextFor, countFindings } from "../src/count";
import type { Findings } from "../src/types";

function emptyFindings(overrides: Partial<Findings> = {}): Findings {
  return {
    pageUrl: "https://example.com/",
    pageTitle: "Example",
    feeds: [],
    webmentionUrl: null,
    activityPubUrl: null,
    relMeLinks: [],
    mf2: { items: [], rels: {}, "rel-urls": {} },
    mf2TypeCounts: {},
    hCard: null,
    ...overrides,
  };
}

describe("countFindings", () => {
  it("counts feeds, webmention, ActivityPub, rel=me links, and top-level mf2 items", () => {
    const findings = emptyFindings({
      feeds: [{ title: "RSS", url: "https://example.com/feed.rss", type: "rss" }],
      webmentionUrl: "https://example.com/webmention",
      activityPubUrl: "https://example.com/actor",
      relMeLinks: ["https://fosstodon.org/@example"],
      mf2: {
        items: [{ type: ["h-card"], properties: {} }],
        rels: {},
        "rel-urls": {},
      },
    });
    expect(countFindings(findings)).toBe(5);
  });

  it("returns 0 for empty findings", () => {
    expect(countFindings(emptyFindings())).toBe(0);
  });

  it("counts an h-feed with many h-entry children as one top-level item, not one per child", () => {
    const findings = emptyFindings({
      mf2: {
        items: [
          {
            type: ["h-feed"],
            properties: {},
            children: Array.from({ length: 10 }, () => ({
              type: ["h-entry"],
              properties: {},
            })),
          },
        ],
        rels: {},
        "rel-urls": {},
      },
    });
    expect(countFindings(findings)).toBe(1);
  });

  it("does not double-count an h-card present in both hCard and mf2.items", () => {
    const hCardItem = { type: ["h-card"], properties: { name: ["Glenn Jones"] } };
    const findings = emptyFindings({
      hCard: hCardItem,
      mf2: { items: [hCardItem], rels: {}, "rel-urls": {} },
    });
    expect(countFindings(findings)).toBe(1);
  });
});

describe("badgeTextFor", () => {
  it("is empty for zero", () => {
    expect(badgeTextFor(0)).toBe("");
  });

  it("stringifies a positive count", () => {
    expect(badgeTextFor(3)).toBe("3");
  });
});
