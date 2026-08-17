import type { Findings } from "../types";
import type { MF2Item } from "../detect/microformats";
import { buildVCard } from "./vcard";
import { countFindings } from "../count";

export function renderPopup(container: HTMLElement, findings: Findings | null): void {
  container.innerHTML = "";

  if (!findings) {
    container.appendChild(emptyState("No page selected."));
    return;
  }

  const total = countFindings(findings);
  const header = document.createElement("h1");
  if (total > 0) {
    header.textContent = `${findings.pageTitle} — ${total} IndieWeb feature${total === 1 ? "" : "s"} found`;
  } else {
    header.textContent = "Nothing found";
  }
  container.appendChild(header);

  if (total === 0) {
    container.appendChild(emptyState("This page has no detected IndieWeb features."));
    return;
  }

  if (findings.hCard) container.appendChild(renderHCard(findings.hCard));
  if (findings.feeds.length) container.appendChild(renderFeeds(findings.feeds));
  if (findings.relMeLinks.length) container.appendChild(renderRelMeLinks(findings.relMeLinks));
  if (findings.webmentionUrl) container.appendChild(renderEndpointBadge("Webmention", findings.webmentionUrl));
  if (findings.activityPubUrl) container.appendChild(renderEndpointBadge("ActivityPub", findings.activityPubUrl));
  if (findings.mf2.items.length) container.appendChild(renderMf2Tree(findings.mf2.items));
}

function isSafeHttpUrl(url: string): boolean {
  try {
    const parsed = new URL(url);
    return parsed.protocol === "http:" || parsed.protocol === "https:";
  } catch {
    return false;
  }
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

  // Photo — rendered as a link, not an `<img>`: an `<img src>` pointed at a page-controlled URL
  // would both fetch it (violating the no-extra-network-fetches rule) and give the visited site a
  // timing signal for exactly when the visitor opened the extension popup.
  const photo = hCard.properties.photo?.[0];
  if (typeof photo === "string" && isSafeHttpUrl(photo)) {
    const photoPara = document.createElement("p");
    photoPara.className = "h-card-photo";
    const link = document.createElement("a");
    link.href = photo;
    link.target = "_blank";
    link.rel = "noopener noreferrer";
    link.textContent = "Photo";
    photoPara.appendChild(link);
    section.appendChild(photoPara);
  }

  // Org
  const org = hCard.properties.org?.[0];
  if (typeof org === "string") {
    const orgPara = document.createElement("p");
    orgPara.className = "h-card-org";
    orgPara.textContent = org;
    section.appendChild(orgPara);
  }

  // URLs/links
  const urls = hCard.properties.url;
  if (Array.isArray(urls) && urls.length > 0) {
    const urlsContainer = document.createElement("div");
    urlsContainer.className = "h-card-urls";
    const urlsList = document.createElement("ul");
    for (const url of urls) {
      if (typeof url === "string" && isSafeHttpUrl(url)) {
        const item = document.createElement("li");
        const link = document.createElement("a");
        link.href = url;
        link.target = "_blank";
        link.rel = "noopener noreferrer";
        link.textContent = url;
        item.appendChild(link);
        urlsList.appendChild(item);
      }
    }
    if (urlsList.children.length > 0) {
      urlsContainer.appendChild(urlsList);
      section.appendChild(urlsContainer);
    }
  }

  // Copy vCard button
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
    if (!isSafeHttpUrl(feed.url)) continue;
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

function renderRelMeLinks(relMeLinks: Findings["relMeLinks"]): HTMLElement {
  const section = document.createElement("section");
  section.className = "rel-me-section";
  const heading = document.createElement("h2");
  heading.textContent = "Elsewhere";
  section.appendChild(heading);
  const list = document.createElement("ul");
  for (const url of relMeLinks) {
    if (!isSafeHttpUrl(url)) continue;
    const item = document.createElement("li");
    const link = document.createElement("a");
    link.href = url;
    link.target = "_blank";
    link.rel = "noopener noreferrer";
    link.textContent = url;
    item.appendChild(link);
    list.appendChild(item);
  }
  section.appendChild(list);
  return section;
}

function renderEndpointBadge(label: string, url: string): HTMLElement {
  const p = document.createElement("p");
  p.className = "endpoint-badge";
  if (isSafeHttpUrl(url)) {
    const link = document.createElement("a");
    link.href = url;
    link.target = "_blank";
    link.rel = "noopener noreferrer";
    link.textContent = `${label}: view endpoint`;
    p.appendChild(link);
  } else {
    p.textContent = `${label}: endpoint (invalid URL)`;
  }
  return p;
}

function renderMf2Tree(items: MF2Item[]): HTMLElement {
  const container = document.createElement("div");
  container.className = "mf2-tree";

  const renderItem = (item: MF2Item): HTMLElement => {
    const details = document.createElement("details");
    const summary = document.createElement("summary");
    summary.textContent = item.type.join(", ");
    details.appendChild(summary);

    const propList = document.createElement("ul");
    propList.className = "mf2-properties";
    for (const [key, values] of Object.entries(item.properties)) {
      const propItem = document.createElement("li");
      const propLabel = document.createElement("strong");
      propLabel.textContent = `${key}: `;
      propItem.appendChild(propLabel);

      for (let i = 0; i < values.length; i++) {
        const value = values[i];
        const span = document.createElement("span");
        if (typeof value === "string") {
          span.textContent = value;
        } else if (typeof value === "object" && value !== null) {
          span.textContent = "[nested object]";
        } else {
          span.textContent = String(value);
        }
        propItem.appendChild(span);
        if (i < values.length - 1) {
          propItem.appendChild(document.createTextNode("; "));
        }
      }
      propList.appendChild(propItem);
    }
    details.appendChild(propList);

    if (item.children && item.children.length > 0) {
      const childrenContainer = document.createElement("div");
      childrenContainer.className = "mf2-children";
      for (const child of item.children) {
        childrenContainer.appendChild(renderItem(child));
      }
      details.appendChild(childrenContainer);
    }

    return details;
  };

  for (const item of items) {
    container.appendChild(renderItem(item));
  }

  return container;
}
