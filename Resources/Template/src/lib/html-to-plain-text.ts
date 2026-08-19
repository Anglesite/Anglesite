/**
 * Deliberately simple HTML→plain-text extraction for the MCP `fetch_page_content` tool's
 * static-page fallback (#1576) — not a markdown-negotiation-conformant conversion, which is
 * #1247's separate job. Strips `<script>`/`<style>`/`<nav>`/`<header>`/`<footer>` elements
 * (including their content), HTML comments, then every remaining tag, decodes a small set of
 * named/numeric HTML entities, and collapses whitespace.
 */
export function htmlToPlainText(html: string): string {
  let text = html;
  for (const tag of ["script", "style", "nav", "header", "footer"]) {
    text = text.replace(new RegExp(`<${tag}\\b[^>]*>[\\s\\S]*?<\\/${tag}>`, "gi"), " ");
  }
  text = text.replace(/<!--[\s\S]*?-->/g, " ");
  text = text.replace(/<[^>]+>/g, " ");
  text = decodeEntities(text);
  return text
    .replace(/[ \t\f\v]+/g, " ")
    .replace(/\n\s*\n+/g, "\n\n")
    .trim();
}

const NAMED_ENTITIES: Record<string, string> = {
  "&amp;": "&",
  "&lt;": "<",
  "&gt;": ">",
  "&quot;": '"',
  "&#39;": "'",
  "&apos;": "'",
  "&nbsp;": " ",
  "&mdash;": "—",
  "&ndash;": "–",
};

function decodeEntities(text: string): string {
  return text
    .replace(/&(amp|lt|gt|quot|#39|apos|nbsp|mdash|ndash);/g, (m) => NAMED_ENTITIES[m] ?? m)
    .replace(/&#(\d+);/g, (_m, code: string) => String.fromCodePoint(Number(code)))
    .replace(/&#x([0-9a-fA-F]+);/g, (_m, code: string) => String.fromCodePoint(Number.parseInt(code, 16)));
}
