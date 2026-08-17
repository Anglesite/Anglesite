import { describe, expect, it } from "vitest";
import {
  badgeTextFor,
  countFindings,
  findWebmentionHeaderUrl,
  isFindingsMessage,
  parseWebmentionHeader,
} from "../src/background";
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
  it("counts feeds, webmention, ActivityPub, h-card, and rel=me links", () => {
    const findings = emptyFindings({
      feeds: [{ title: "RSS", url: "https://example.com/feed.rss", type: "rss" }],
      webmentionUrl: "https://example.com/webmention",
      activityPubUrl: "https://example.com/actor",
      relMeLinks: ["https://fosstodon.org/@example"],
      hCard: { type: ["h-card"], properties: {} },
    });
    expect(countFindings(findings)).toBe(5);
  });

  it("returns 0 for empty findings", () => {
    expect(countFindings(emptyFindings())).toBe(0);
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

describe("isFindingsMessage", () => {
  it("accepts a well-formed FINDINGS message", () => {
    expect(isFindingsMessage({ type: "FINDINGS", findings: emptyFindings() })).toBe(true);
  });

  it("rejects other shapes", () => {
    expect(isFindingsMessage(null)).toBe(false);
    expect(isFindingsMessage({ type: "OTHER" })).toBe(false);
    expect(isFindingsMessage("FINDINGS")).toBe(false);
  });
});

describe("parseWebmentionHeader", () => {
  it("extracts the URL from a Link header advertising rel=webmention", () => {
    const header = '<https://example.com/webmention>; rel="webmention"';
    expect(parseWebmentionHeader(header, "https://example.com/post")).toBe("https://example.com/webmention");
  });

  it("resolves a relative URL against the response URL", () => {
    const header = '</wm>; rel="webmention"';
    expect(parseWebmentionHeader(header, "https://example.com/post")).toBe("https://example.com/wm");
  });

  it("returns null when the header has no webmention rel", () => {
    expect(parseWebmentionHeader('<https://example.com/x>; rel="next"', "https://example.com/")).toBeNull();
  });
});

describe("findWebmentionHeaderUrl", () => {
  it("returns null when there are no headers", () => {
    expect(findWebmentionHeaderUrl(undefined, "https://example.com/")).toBeNull();
  });

  it("returns null when no header is named link", () => {
    const headers = [{ name: "Content-Type", value: "text/html" }];
    expect(findWebmentionHeaderUrl(headers, "https://example.com/")).toBeNull();
  });

  it("finds the webmention URL when it is the only link header", () => {
    const headers = [{ name: "Link", value: '<https://example.com/webmention>; rel="webmention"' }];
    expect(findWebmentionHeaderUrl(headers, "https://example.com/post")).toBe("https://example.com/webmention");
  });

  it("checks every separate Link header line, not just the first", () => {
    const headers = [
      { name: "Link", value: '<https://example.com/next>; rel="next"' },
      { name: "Link", value: '<https://example.com/webmention>; rel="webmention"' },
    ];
    expect(findWebmentionHeaderUrl(headers, "https://example.com/post")).toBe("https://example.com/webmention");
  });

  it("returns null when none of the link headers advertise rel=webmention", () => {
    const headers = [
      { name: "Link", value: '<https://example.com/next>; rel="next"' },
      { name: "Link", value: '<https://example.com/prev>; rel="prev"' },
    ];
    expect(findWebmentionHeaderUrl(headers, "https://example.com/post")).toBeNull();
  });
});
