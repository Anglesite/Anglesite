import type { Findings } from "./types";
import { badgeTextFor, countFindings } from "./count";

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
  // here, keyed by tab, until the FINDINGS message for that same navigation shows up.
  //
  // A `main_frame` response is also the only reliable navigation boundary this listener sees, so
  // it doubles as the point where per-tab state gets reset: every `main_frame` response clears
  // any pending header URL and any previously stored findings for that tab FIRST, before looking
  // at this response's own headers. Without that reset, `pendingWebmentionHeaders` and storage
  // both keep whatever the *previous* page on this tab left behind, so a header-detected
  // webmention URL from page N could get merged onto page (N-1)'s stale findings, and only a
  // tab's very first page ever hit the "nothing stored yet" case. Resetting unconditionally on
  // every main_frame response also means storage is always empty when this listener stashes a
  // URL, so "stash and wait for FINDINGS" is the only path needed — no more conditional merge
  // into storage, and no more async storage read here.
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

      // Navigation boundary: reset this tab's state before considering the new response's
      // headers, so nothing from the page being replaced can leak into the page arriving now.
      pendingWebmentionHeaders.delete(details.tabId);
      void chrome.storage.session.set({ [String(details.tabId)]: null });
      chrome.action.setBadgeText({ tabId: details.tabId, text: "" });

      const webmentionUrl = findWebmentionHeaderUrl(details.responseHeaders, details.url);
      if (webmentionUrl) {
        pendingWebmentionHeaders.set(details.tabId, webmentionUrl);
      }
    },
    { urls: ["<all_urls>"], types: ["main_frame"] },
    ["responseHeaders"]
  );
}
