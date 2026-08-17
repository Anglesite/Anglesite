import type { Findings } from "../types";
import { buildVCard } from "./vcard";

export function renderPopup(container: HTMLElement, findings: Findings | null): void {
  container.innerHTML = "";

  if (!findings) {
    container.appendChild(emptyState("No page selected."));
    return;
  }

  const total = countTotal(findings);
  const header = document.createElement("h1");
  header.textContent = total > 0 ? `${total} IndieWeb feature${total === 1 ? "" : "s"} found` : "Nothing found";
  container.appendChild(header);

  if (total === 0) {
    container.appendChild(emptyState("This page has no detected IndieWeb features."));
    return;
  }

  if (findings.hCard) container.appendChild(renderHCard(findings.hCard));
  if (findings.feeds.length) container.appendChild(renderFeeds(findings.feeds));
  if (findings.webmentionUrl) container.appendChild(renderEndpointBadge("Webmention", findings.webmentionUrl));
  if (findings.activityPubUrl) container.appendChild(renderEndpointBadge("ActivityPub", findings.activityPubUrl));
  if (Object.keys(findings.mf2TypeCounts).length) container.appendChild(renderMf2Tree(findings.mf2TypeCounts));
}

function countTotal(findings: Findings): number {
  const mf2Count = Object.values(findings.mf2TypeCounts).reduce((a, b) => a + b, 0);
  return (
    findings.feeds.length +
    findings.relMeLinks.length +
    (findings.webmentionUrl ? 1 : 0) +
    (findings.activityPubUrl ? 1 : 0) +
    (findings.hCard ? 1 : 0) +
    mf2Count
  );
}

function emptyState(text: string): HTMLElement {
  const p = document.createElement("p");
  p.className = "empty-state";
  p.textContent = text;
  return p;
}

function renderHCard(hCard: NonNullable<Findings["hCard"]>): HTMLElement {
  const section = document.createElement("section");
  section.className = "h-card-section";

  const name = typeof hCard.properties.name?.[0] === "string" ? (hCard.properties.name[0] as string) : "Unknown";
  const heading = document.createElement("h2");
  heading.textContent = name;
  section.appendChild(heading);

  const copyButton = document.createElement("button");
  copyButton.textContent = "Copy vCard";
  copyButton.dataset.vcard = buildVCard(hCard);
  section.appendChild(copyButton);

  return section;
}

function renderFeeds(feeds: Findings["feeds"]): HTMLElement {
  const section = document.createElement("section");
  section.className = "feeds-section";
  const list = document.createElement("ul");
  for (const feed of feeds) {
    const item = document.createElement("li");
    const link = document.createElement("a");
    link.href = feed.url;
    link.target = "_blank";
    link.rel = "noopener noreferrer";
    link.textContent = feed.title ?? feed.url;
    item.appendChild(link);
    list.appendChild(item);
  }
  section.appendChild(list);
  return section;
}

function renderEndpointBadge(label: string, url: string): HTMLElement {
  const p = document.createElement("p");
  p.className = "endpoint-badge";
  const link = document.createElement("a");
  link.href = url;
  link.target = "_blank";
  link.rel = "noopener noreferrer";
  link.textContent = `${label}: view endpoint`;
  p.appendChild(link);
  return p;
}

function renderMf2Tree(counts: Record<string, number>): HTMLElement {
  const details = document.createElement("details");
  const summary = document.createElement("summary");
  summary.textContent = "microformats2 detail";
  details.appendChild(summary);
  const list = document.createElement("ul");
  for (const [type, count] of Object.entries(counts)) {
    const item = document.createElement("li");
    item.textContent = `${type}: ${count}`;
    list.appendChild(item);
  }
  details.appendChild(list);
  return details;
}
