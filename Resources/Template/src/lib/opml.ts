export interface OpmlOutline {
  text: string;
  title: string;
  xmlUrl: string;
  htmlUrl: string;
}

function escapeXmlAttr(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/** Renders an OPML 2.0 document for the blogroll's subscribable feed list (#1483). */
export function renderOpml(title: string, outlines: OpmlOutline[]): Response {
  const body = outlines
    .map(
      (o) =>
        `    <outline type="rss" text="${escapeXmlAttr(o.text)}" title="${escapeXmlAttr(o.title)}" xmlUrl="${escapeXmlAttr(o.xmlUrl)}" htmlUrl="${escapeXmlAttr(o.htmlUrl)}"/>`,
    )
    .join("\n");
  const xml = `<?xml version="1.0" encoding="UTF-8"?>
<opml version="2.0">
  <head>
    <title>${escapeXmlAttr(title)}</title>
  </head>
  <body>
${body}
  </body>
</opml>
`;
  return new Response(xml, {
    headers: { "Content-Type": "text/x-opml; charset=utf-8" },
  });
}
