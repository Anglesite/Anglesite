import { detectActivityPubLink } from "./detect/activitypub";
import { detectFeeds } from "./detect/feeds";
import { findFirstHCard, parseMicroformats, summarizeTypes } from "./detect/microformats";
import { detectWebmentionLinkTag } from "./detect/webmention";
import type { Findings } from "./types";

export function collectFindings(doc: Document): Findings {
  const mf2 = parseMicroformats(doc);
  return {
    pageUrl: doc.location?.href ?? doc.baseURI,
    pageTitle: doc.title,
    feeds: detectFeeds(doc),
    webmentionUrl: detectWebmentionLinkTag(doc),
    activityPubUrl: detectActivityPubLink(doc),
    relMeLinks: mf2.rels.me ?? [],
    mf2,
    mf2TypeCounts: summarizeTypes(mf2),
    hCard: findFirstHCard(mf2),
  };
}

// Entry-point wiring: reports this page's findings to the background script. Guarded so this
// module stays importable (and `collectFindings` testable) outside a real extension context —
// `chrome` only exists when this bundle is actually running as the content script.
declare const chrome: { runtime: { sendMessage(message: unknown): void } } | undefined;

if (typeof document !== "undefined" && typeof chrome !== "undefined") {
  chrome.runtime.sendMessage({ type: "FINDINGS", findings: collectFindings(document) });
}
