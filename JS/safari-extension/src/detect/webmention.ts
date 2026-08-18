export function detectWebmentionLinkTag(doc: Document): string | null {
  const link = doc.querySelector<HTMLLinkElement | HTMLAnchorElement>(
    'link[rel~="webmention"][href], a[rel~="webmention"][href]'
  );
  const href = link?.getAttribute("href");
  return href ? new URL(href, doc.baseURI).href : null;
}
