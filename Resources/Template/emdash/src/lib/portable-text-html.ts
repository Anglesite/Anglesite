/**
 * Portable Text → HTML for an EmDash site's feeds (#2133). An article page renders its body with
 * EmDash's own `PortableText` component; a feed is built in an endpoint, where no Astro component
 * can run, so this renders the same blocks to an HTML string.
 *
 * It renders what EmDash's editor writes into an article: text blocks (paragraphs, headings,
 * block quotes, bullet and numbered lists), the standard marks (bold, italic, underline,
 * strike-through, code, links), images and galleries, and code blocks. Everything else is left
 * out rather than guessed at: raw-HTML blocks (`htmlBlock`), tables and any block type a plugin
 * adds. Every value is escaped, and links keep only `http:`, `https:`, `mailto:`, `tel:`, `#`
 * and site-relative targets, so a feed body never carries markup the writer didn't type.
 *
 * Dependency-free on purpose, like `emdash-articles.ts`: the template's `npm test` runs it with no
 * EmDash install.
 */

import { imageURL } from "./emdash-articles.ts";

interface Span {
  _type?: string;
  text?: unknown;
  marks?: unknown;
}

interface MarkDef {
  _type?: string;
  _key?: string;
  href?: unknown;
}

interface Block {
  _type?: string;
  [field: string]: unknown;
}

/** Marks EmDash's editor applies directly (not through a `markDefs` entry), and their tags. */
const DECORATOR_TAGS: Record<string, string> = {
  strong: "strong",
  em: "em",
  underline: "u",
  "strike-through": "s",
  code: "code",
};

const HEADING_STYLES = new Set(["h1", "h2", "h3", "h4", "h5", "h6"]);

/** Escapes text for an HTML text node or a double-quoted attribute value. */
export function escapeHtml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

/**
 * A link target a feed may carry, or `undefined`. Only `http:`, `https:`, `mailto:` and `tel:`
 * URLs, fragments and site-relative paths pass; `javascript:`, `data:` and protocol-relative
 * (`//host`) targets don't.
 */
export function safeHref(href: unknown): string | undefined {
  if (typeof href !== "string") return undefined;
  const trimmed = href.trim();
  if (trimmed === "") return undefined;
  if (trimmed.startsWith("#")) return trimmed;
  if (trimmed.startsWith("/")) return trimmed.startsWith("//") ? undefined : trimmed;
  try {
    const protocol = new URL(trimmed).protocol;
    return ["http:", "https:", "mailto:", "tel:"].includes(protocol) ? trimmed : undefined;
  } catch {
    return undefined;
  }
}

function asArray(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function renderSpans(children: unknown, markDefs: unknown): string {
  const defs = new Map<string, MarkDef>();
  for (const def of asArray(markDefs) as MarkDef[]) {
    if (def && typeof def._key === "string") defs.set(def._key, def);
  }
  return (asArray(children) as Span[])
    .map((span) => {
      if (!span || typeof span.text !== "string") return "";
      let html = escapeHtml(span.text).replace(/\n/g, "<br>");
      for (const mark of asArray(span.marks)) {
        if (typeof mark !== "string") continue;
        const tag = DECORATOR_TAGS[mark];
        if (tag) {
          html = `<${tag}>${html}</${tag}>`;
          continue;
        }
        const def = defs.get(mark);
        if (def?._type === "link") {
          const href = safeHref(def.href);
          if (href) html = `<a href="${escapeHtml(href)}">${html}</a>`;
        }
      }
      return html;
    })
    .join("");
}

function renderTextBlock(block: Block): string {
  const inner = renderSpans(block.children, block.markDefs);
  const style = typeof block.style === "string" ? block.style : "normal";
  if (HEADING_STYLES.has(style)) return `<${style}>${inner}</${style}>`;
  if (style === "blockquote") return `<blockquote><p>${inner}</p></blockquote>`;
  return `<p>${inner}</p>`;
}

function renderImage(image: Block): string {
  const asset = (image.asset ?? {}) as { _ref?: unknown; url?: unknown };
  const src = imageURL({
    id: typeof asset._ref === "string" ? asset._ref : undefined,
    src: typeof asset.url === "string" ? asset.url : undefined,
  });
  if (!src) return "";
  const alt = typeof image.alt === "string" ? image.alt : "";
  const img = `<img src="${escapeHtml(src)}" alt="${escapeHtml(alt)}">`;
  const caption = typeof image.caption === "string" && image.caption !== "" ? image.caption : undefined;
  return caption
    ? `<figure>${img}<figcaption>${escapeHtml(caption)}</figcaption></figure>`
    : `<figure>${img}</figure>`;
}

function renderBlock(block: Block): string {
  switch (block._type) {
    case "block":
      return renderTextBlock(block);
    case "image":
      return renderImage(block);
    case "gallery":
      return (asArray(block.images) as Block[]).map(renderImage).join("");
    case "code":
      return typeof block.code === "string" ? `<pre><code>${escapeHtml(block.code)}</code></pre>` : "";
    default:
      // `htmlBlock`, tables and plugin block types: left out of the feed (see the header).
      return "";
  }
}

/**
 * Renders Portable Text to HTML. Consecutive list items become `<ul>`/`<ol>` lists, with a
 * deeper `level` nested inside the item before it. A value that isn't Portable Text (a plain
 * string, `null`) renders as escaped paragraphs, or nothing.
 */
export function portableTextToHtml(value: unknown): string {
  if (typeof value === "string") {
    return value
      .split(/\n{2,}/)
      .map((p) => p.trim())
      .filter((p) => p !== "")
      .map((p) => `<p>${escapeHtml(p).replace(/\n/g, "<br>")}</p>`)
      .join("");
  }
  const out: string[] = [];
  // The open lists, outermost first: each one's tag and the level it sits at.
  const open: Array<{ tag: "ul" | "ol"; level: number }> = [];
  const closeTo = (level: number) => {
    while (open.length > 0 && open[open.length - 1].level > level) {
      out.push(`</li></${open.pop()!.tag}>`);
    }
  };
  for (const block of asArray(value) as Block[]) {
    if (!block || typeof block !== "object") continue;
    const listItem = block._type === "block" ? block.listItem : undefined;
    if (listItem !== "bullet" && listItem !== "number") {
      closeTo(0);
      out.push(renderBlock(block));
      continue;
    }
    const tag = listItem === "number" ? "ol" : "ul";
    const level = typeof block.level === "number" && block.level >= 1 ? Math.floor(block.level) : 1;
    closeTo(level);
    const top = open[open.length - 1];
    if (top && top.level === level && top.tag !== tag) {
      // Same depth, other kind of list: end this one and start the other.
      out.push(`</li></${open.pop()!.tag}>`);
    }
    const current = open[open.length - 1];
    if (current && current.level === level) {
      out.push("</li>");
    } else {
      open.push({ tag, level });
      out.push(`<${tag}>`);
    }
    out.push(`<li>${renderSpans(block.children, block.markDefs)}`);
  }
  closeTo(0);
  return out.join("");
}

/** The plain text of Portable Text: each text block's spans, one block per line. */
export function portableTextPlainText(value: unknown): string {
  if (typeof value === "string") return value;
  return (asArray(value) as Block[])
    .filter((block) => block && block._type === "block")
    .map((block) =>
      (asArray(block.children) as Span[]).map((s) => (typeof s?.text === "string" ? s.text : "")).join(""),
    )
    .filter((line) => line !== "")
    .join("\n");
}
