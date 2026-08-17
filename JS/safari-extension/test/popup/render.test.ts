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

  it("renders an h-card section with a copy-vCard button", () => {
    const container = document.createElement("div");
    renderPopup(
      container,
      emptyFindings({ hCard: { type: ["h-card"], properties: { name: ["Glenn Jones"] } } })
    );
    expect(container.querySelector(".h-card-section h2")?.textContent).toBe("Glenn Jones");
    const button = container.querySelector<HTMLButtonElement>(".h-card-section button");
    expect(button?.dataset.vcard).toContain("FN:Glenn Jones");
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

  it("renders webmention and ActivityPub as endpoint badges with no action buttons", () => {
    const container = document.createElement("div");
    renderPopup(
      container,
      emptyFindings({
        webmentionUrl: "https://example.com/webmention",
        activityPubUrl: "https://example.com/actor",
      })
    );
    expect(container.querySelectorAll(".endpoint-badge")).toHaveLength(2);
    expect(container.querySelectorAll(".endpoint-badge button")).toHaveLength(0);
  });

  it("renders the mf2 type-count tree", () => {
    const container = document.createElement("div");
    renderPopup(container, emptyFindings({ mf2TypeCounts: { "h-entry": 2 }, feeds: [], hCard: null }));
    expect(container.textContent).toContain("h-entry: 2");
  });
});
