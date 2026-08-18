// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
import { renderPopup } from "../../src/popup/render";
import type { Findings } from "../../src/types";

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

describe("renderPopup", () => {
  it("shows an empty state when there is no active tab", () => {
    const container = document.createElement("div");
    renderPopup(container, null);
    expect(container.textContent).toContain("No page selected");
  });

  it("shows a nothing-found state when findings has nothing detected", () => {
    const container = document.createElement("div");
    renderPopup(container, emptyFindings());
    expect(container.textContent).toContain("Nothing found");
  });

  it("includes the page title in the header", () => {
    const container = document.createElement("div");
    renderPopup(
      container,
      emptyFindings({
        pageTitle: "My Awesome Blog",
        feeds: [{ title: "Feed", url: "https://example.com/feed.xml", type: "rss" }],
      })
    );
    expect(container.querySelector("h1")?.textContent).toContain("My Awesome Blog");
  });

  it("renders an h-card section with a copy-vCard button", () => {
    const container = document.createElement("div");
    renderPopup(
      container,
      emptyFindings({
        hCard: { type: ["h-card"], properties: { name: ["Glenn Jones"] } },
        mf2: {
          items: [{ type: ["h-card"], properties: { name: ["Glenn Jones"] } }],
          rels: {},
          "rel-urls": {},
        },
        mf2TypeCounts: { "h-card": 1 },
      })
    );
    expect(container.querySelector(".h-card-section h2")?.textContent).toBe("Glenn Jones");
    const button = container.querySelector<HTMLButtonElement>(".h-card-section button");
    expect(button?.dataset.vcard).toContain("FN:Glenn Jones");
  });

  it("renders h-card photo as a link, plus org and links, when present", () => {
    const container = document.createElement("div");
    renderPopup(
      container,
      emptyFindings({
        hCard: {
          type: ["h-card"],
          properties: {
            name: ["Glenn Jones"],
            photo: ["https://example.com/photo.jpg"],
            org: ["Acme Corp"],
            url: ["https://glennjonesnet.com", "https://twitter.com/glennjones"],
          },
        },
        mf2: {
          items: [{ type: ["h-card"], properties: { name: ["Glenn Jones"] } }],
          rels: {},
          "rel-urls": {},
        },
        mf2TypeCounts: { "h-card": 1 },
      })
    );
    const section = container.querySelector(".h-card-section");
    // The photo is never fetched — it's a plain link, not an <img>.
    expect(section?.querySelector("img")).toBe(null);
    const photoLink = section?.querySelector<HTMLAnchorElement>(".h-card-photo a");
    expect(photoLink?.href).toBe("https://example.com/photo.jpg");
    expect(photoLink?.textContent).toBe("Photo");
    expect(section?.textContent).toContain("Acme Corp");
    const links = section?.querySelectorAll("a");
    expect(links).toHaveLength(3); // photo link + two URLs in the h-card section
  });

  it("does not render unsafe URLs in h-card", () => {
    const container = document.createElement("div");
    renderPopup(
      container,
      emptyFindings({
        hCard: {
          type: ["h-card"],
          properties: {
            name: ["Evil Person"],
            url: ["javascript:alert(1)"],
            photo: ["javascript:alert(2)"],
          },
        },
        mf2: {
          items: [{ type: ["h-card"], properties: { name: ["Evil Person"] } }],
          rels: {},
          "rel-urls": {},
        },
        mf2TypeCounts: { "h-card": 1 },
      })
    );
    const section = container.querySelector(".h-card-section");
    const link = section?.querySelector("a[href*='javascript']");
    expect(link).toBe(null);
    expect(section?.querySelector(".h-card-photo")).toBe(null);
  });

  it("renders feed links", () => {
    const container = document.createElement("div");
    renderPopup(
      container,
      emptyFindings({ feeds: [{ title: "RSS", url: "https://example.com/feed.rss", type: "rss" }] })
    );
    const link = container.querySelector<HTMLAnchorElement>(".feeds-section a");
    expect(link?.textContent).toBe("RSS");
    expect(link?.href).toBe("https://example.com/feed.rss");
  });

  it("does not render feeds with unsafe URLs", () => {
    const container = document.createElement("div");
    renderPopup(
      container,
      emptyFindings({
        feeds: [
          { title: "Safe Feed", url: "https://example.com/feed.rss", type: "rss" },
          { title: "Evil Feed", url: "javascript:alert(1)", type: "rss" },
        ],
      })
    );
    const links = container.querySelectorAll<HTMLAnchorElement>(".feeds-section a");
    expect(links).toHaveLength(1);
    expect(links[0]?.href).not.toContain("javascript");
  });

  it("renders rel=me links", () => {
    const container = document.createElement("div");
    renderPopup(
      container,
      emptyFindings({
        relMeLinks: ["https://fosstodon.org/@example", "https://github.com/example"],
      })
    );
    const links = container.querySelectorAll<HTMLAnchorElement>(".rel-me-section a");
    expect(links).toHaveLength(2);
    expect(links[0]?.href).toBe("https://fosstodon.org/@example");
    expect(links[1]?.href).toBe("https://github.com/example");
  });

  it("does not render rel=me links with unsafe URLs", () => {
    const container = document.createElement("div");
    renderPopup(
      container,
      emptyFindings({
        relMeLinks: ["https://example.com/safe", "javascript:alert(1)"],
      })
    );
    const links = container.querySelectorAll<HTMLAnchorElement>(".rel-me-section a");
    expect(links).toHaveLength(1);
    expect(links[0]?.href).not.toContain("javascript");
  });

  it("renders webmention and ActivityPub as endpoint badges", () => {
    const container = document.createElement("div");
    renderPopup(
      container,
      emptyFindings({
        webmentionUrl: "https://example.com/webmention",
        activityPubUrl: "https://example.com/actor",
      })
    );
    expect(container.querySelectorAll(".endpoint-badge")).toHaveLength(2);
  });

  it("does not render endpoint badges with unsafe URLs", () => {
    const container = document.createElement("div");
    renderPopup(
      container,
      emptyFindings({
        webmentionUrl: "javascript:alert(1)",
        activityPubUrl: "https://example.com/actor",
      })
    );
    const badges = container.querySelectorAll(".endpoint-badge");
    expect(badges).toHaveLength(2); // both badges render, but one has no link
    const unsafeLink = container.querySelector<HTMLAnchorElement>("a[href*='javascript']");
    expect(unsafeLink).toBe(null);
  });

  it("renders mf2 items with their properties", () => {
    const container = document.createElement("div");
    renderPopup(
      container,
      emptyFindings({
        mf2: {
          items: [
            {
              type: ["h-entry"],
              properties: { "p-name": ["Hello World"], "e-content": ["This is my first post"] },
            },
          ],
          rels: {},
          "rel-urls": {},
        },
        mf2TypeCounts: { "h-entry": 1 },
      })
    );
    expect(container.textContent).toContain("h-entry");
    expect(container.textContent).toContain("p-name");
    expect(container.textContent).toContain("Hello World");
  });

  it("does not double-count h-card when present in both hCard and mf2TypeCounts", () => {
    const container = document.createElement("div");
    renderPopup(
      container,
      emptyFindings({
        hCard: { type: ["h-card"], properties: { name: ["Glenn Jones"] } },
        mf2: {
          items: [{ type: ["h-card"], properties: { name: ["Glenn Jones"] } }],
          rels: {},
          "rel-urls": {},
        },
        mf2TypeCounts: { "h-card": 1 },
      })
    );
    const header = container.querySelector("h1");
    // Should say "1 IndieWeb feature found", not "2"
    expect(header?.textContent).toContain("1 IndieWeb feature found");
  });
});
