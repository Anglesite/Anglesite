import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { findWebmentionHeaderUrl, isFindingsMessage, parseWebmentionHeader } from "../src/background";
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

// The `chrome.*` wiring in background.ts (message/tabs/webRequest listener registration) has no
// coverage anywhere else — only the pure helpers above are tested elsewhere. Two prior fix rounds
// on this file both regressed exactly this untested layer, so it gets a minimal fake `chrome`
// implementing just the listener-registration surface the module needs, letting tests invoke the
// registered callbacks directly and assert on what got stored/badged.
type MessageListener = (message: unknown, sender: { tab?: { id?: number } }) => void;
type HeadersListener = (details: {
  tabId: number;
  url: string;
  responseHeaders?: { name: string; value?: string }[];
}) => void;
type RemovedListener = (tabId: number) => void;

function createFakeChrome() {
  const messageListeners: MessageListener[] = [];
  const removedListeners: RemovedListener[] = [];
  const headersListeners: HeadersListener[] = [];
  const storage = new Map<string, unknown>();
  const badges = new Map<number, string>();

  const chrome = {
    runtime: {
      onMessage: {
        addListener: (cb: MessageListener) => {
          messageListeners.push(cb);
        },
      },
    },
    storage: {
      session: {
        set: (items: Record<string, unknown>) => {
          for (const [key, value] of Object.entries(items)) storage.set(key, value);
          return Promise.resolve();
        },
      },
    },
    action: {
      setBadgeText: ({ tabId, text }: { tabId: number; text: string }) => {
        badges.set(tabId, text);
      },
    },
    tabs: {
      onRemoved: {
        addListener: (cb: RemovedListener) => {
          removedListeners.push(cb);
        },
      },
    },
    webRequest: {
      onHeadersReceived: {
        addListener: (cb: HeadersListener) => {
          headersListeners.push(cb);
        },
      },
    },
  };

  return {
    chrome,
    emitMessage: (message: unknown, sender: { tab?: { id?: number } }) => {
      for (const cb of messageListeners) cb(message, sender);
    },
    emitHeaders: (details: {
      tabId: number;
      url: string;
      responseHeaders?: { name: string; value?: string }[];
    }) => {
      for (const cb of headersListeners) cb(details);
    },
    emitTabRemoved: (tabId: number) => {
      for (const cb of removedListeners) cb(tabId);
    },
    storageGet: (tabId: number) => storage.get(String(tabId)),
    badgeFor: (tabId: number) => badges.get(tabId),
  };
}

describe("chrome wiring", () => {
  const originalChrome = (globalThis as { chrome?: unknown }).chrome;

  beforeEach(() => {
    vi.resetModules();
  });

  afterEach(() => {
    (globalThis as { chrome?: unknown }).chrome = originalChrome;
  });

  it("resets a tab's pending header and stored findings on every main_frame navigation, so a first page's state can't leak into a second", async () => {
    const fake = createFakeChrome();
    (globalThis as { chrome?: unknown }).chrome = fake.chrome;
    await import("../src/background");

    const tabId = 5;

    // Page 1's response advertises a webmention Link header; FINDINGS hasn't arrived yet.
    fake.emitHeaders({
      tabId,
      url: "https://example.com/page1",
      responseHeaders: [{ name: "Link", value: '<https://example.com/wm>; rel="webmention"' }],
    });
    expect(fake.storageGet(tabId)).toBeNull();
    expect(fake.badgeFor(tabId)).toBe("");

    // Page 1's FINDINGS arrives without its own webmentionUrl — the stashed header URL merges in.
    fake.emitMessage({ type: "FINDINGS", findings: emptyFindings({ pageTitle: "Page 1" }) }, { tab: { id: tabId } });
    const page1Stored = fake.storageGet(tabId) as Findings;
    expect(page1Stored.pageTitle).toBe("Page 1");
    expect(page1Stored.webmentionUrl).toBe("https://example.com/wm");
    expect(fake.badgeFor(tabId)).toBe("1");

    // Page 2 loads in the same tab with no webmention header this time. The main_frame response
    // is the navigation boundary: it must clear page 1's stored findings and pending header URL
    // before page 2's own FINDINGS message arrives.
    fake.emitHeaders({ tabId, url: "https://example.com/page2", responseHeaders: [] });
    expect(fake.storageGet(tabId)).toBeNull();
    expect(fake.badgeFor(tabId)).toBe("");

    fake.emitMessage({ type: "FINDINGS", findings: emptyFindings({ pageTitle: "Page 2" }) }, { tab: { id: tabId } });
    const page2Stored = fake.storageGet(tabId) as Findings;
    expect(page2Stored.pageTitle).toBe("Page 2");
    // Page 1's stashed webmention URL must not leak onto page 2's findings.
    expect(page2Stored.webmentionUrl).toBeNull();
    expect(fake.badgeFor(tabId)).toBe("");
  });

  it("clears pending header state and storage when a tab is removed", async () => {
    const fake = createFakeChrome();
    (globalThis as { chrome?: unknown }).chrome = fake.chrome;
    await import("../src/background");

    const tabId = 9;
    fake.emitMessage({ type: "FINDINGS", findings: emptyFindings() }, { tab: { id: tabId } });
    expect(fake.storageGet(tabId)).toEqual(emptyFindings());

    fake.emitTabRemoved(tabId);
    expect(fake.storageGet(tabId)).toBeNull();
  });
});
