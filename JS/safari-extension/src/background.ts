import type { Findings } from "./types";

export interface FindingsMessage {
  type: "FINDINGS";
  findings: Findings;
}

export function isFindingsMessage(message: unknown): message is FindingsMessage {
  return (
    typeof message === "object" &&
    message !== null &&
    (message as { type?: unknown }).type === "FINDINGS" &&
    "findings" in message
  );
}

export function countFindings(findings: Findings): number {
  let count = findings.feeds.length + findings.relMeLinks.length;
  if (findings.webmentionUrl) count += 1;
  if (findings.activityPubUrl) count += 1;
  if (findings.hCard) count += 1;
  return count;
}

export function badgeTextFor(count: number): string {
  return count > 0 ? String(count) : "";
}

const WEBMENTION_LINK = /<([^>]+)>\s*;\s*rel="webmention"/i;

export function parseWebmentionHeader(headerValue: string, baseUrl: string): string | null {
  const match = WEBMENTION_LINK.exec(headerValue);
  const url = match?.[1];
  return url ? new URL(url, baseUrl).href : null;
}

/**
 * Scans every `Link` response header (a server may send several separate header lines rather
 * than one comma-joined value) for a `rel="webmention"` target, returning the first match.
 */
export function findWebmentionHeaderUrl(
  headers: { name: string; value?: string }[] | undefined,
  baseUrl: string
): string | null {
  if (!headers) return null;
  for (const header of headers) {
    if (header.name.toLowerCase() !== "link" || !header.value) continue;
    const url = parseWebmentionHeader(header.value, baseUrl);
    if (url) return url;
  }
  return null;
}

// Service-worker wiring below. Guarded so the pure helpers above stay unit-testable outside a
// real extension context (no `chrome` global under vitest).
interface ChromeLike {
  runtime: { onMessage: { addListener(cb: (message: unknown, sender: { tab?: { id?: number } }) => void): void } };
  storage: {
    session: {
      set(items: Record<string, unknown>): Promise<void>;
      get(key: string): Promise<Record<string, unknown>>;
    };
  };
  action: { setBadgeText(details: { tabId: number; text: string }): void };
  tabs: { onRemoved: { addListener(cb: (tabId: number) => void): void } };
  webRequest: {
    onHeadersReceived: {
      addListener(
        cb: (details: {
          tabId: number;
          url: string;
          responseHeaders?: { name: string; value?: string }[];
        }) => void,
        filter: { urls: string[]; types: string[] },
        extraInfoSpec: string[]
      ): void;
    };
  };
}

declare const chrome: ChromeLike | undefined;

if (typeof chrome !== "undefined") {
  // `onHeadersReceived` fires as response headers arrive — before the page's DOM is parsed —
  // while the content script's FINDINGS message arrives much later (after `document_idle`). So
  // a header-detected webmention URL usually has no stored Findings to merge into yet. Stash it
  // here, keyed by tab, until the FINDINGS message for that same navigation shows up. Cleared on
  // consumption and on tab removal so it never carries over onto an unrelated later navigation.
  const pendingWebmentionHeaders = new Map<number, string>();

  chrome.runtime.onMessage.addListener((message, sender) => {
    const tabId = sender.tab?.id;
    if (tabId === undefined || !isFindingsMessage(message)) return;
    const pendingWebmentionUrl = pendingWebmentionHeaders.get(tabId);
    pendingWebmentionHeaders.delete(tabId);
    const findings =
      pendingWebmentionUrl && !message.findings.webmentionUrl
        ? { ...message.findings, webmentionUrl: pendingWebmentionUrl }
        : message.findings;
    void chrome.storage.session.set({ [String(tabId)]: findings });
    chrome.action.setBadgeText({ tabId, text: badgeTextFor(countFindings(findings)) });
  });

  chrome.tabs.onRemoved.addListener((tabId) => {
    pendingWebmentionHeaders.delete(tabId);
    void chrome.storage.session.set({ [String(tabId)]: null });
  });

  chrome.webRequest.onHeadersReceived.addListener(
    (details) => {
      if (details.tabId < 0) return;
      const webmentionUrl = findWebmentionHeaderUrl(details.responseHeaders, details.url);
      if (!webmentionUrl) return;
      void chrome.storage.session.get(String(details.tabId)).then((stored) => {
        const existing = stored[String(details.tabId)] as Findings | undefined;
        if (!existing) {
          // FINDINGS hasn't arrived yet for this tab (the common case) — stash for the message
          // handler above to pick up once it does.
          pendingWebmentionHeaders.set(details.tabId, webmentionUrl);
          return;
        }
        if (existing.webmentionUrl) return;
        const merged: Findings = { ...existing, webmentionUrl };
        void chrome.storage.session.set({ [String(details.tabId)]: merged });
        chrome.action.setBadgeText({ tabId: details.tabId, text: badgeTextFor(countFindings(merged)) });
      });
    },
    { urls: ["<all_urls>"], types: ["main_frame"] },
    ["responseHeaders"]
  );
}
