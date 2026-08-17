export function detectActivityPubLink(doc: Document): string | null {
  const link = doc.querySelector<HTMLLinkElement>(
    'link[rel~="alternate"][type="application/activity+json"][href]'
  );
  const href = link?.getAttribute("href");
  return href ? new URL(href, doc.baseURI).href : null;
}
