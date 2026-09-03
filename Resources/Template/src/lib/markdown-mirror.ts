/**
 * Renders a content-collection entry as a standalone Markdown document — a raw-source `.md`
 * sibling for each collection page (`[collection]/[...slug].md.ts`, `blog/[...slug].md.ts`),
 * consumed by the WebMCP `anglesite_fetch_post_markdown` tool (issue #1279) and by anything else
 * that wants an agent-readable plain-text copy of a post.
 */

export const MARKDOWN_MIRROR_CONTENT_TYPE = "text/markdown; charset=utf-8";

export interface MarkdownMirrorEntry {
  collection: string;
  id: string;
  data: Record<string, unknown>;
  body: string;
}

interface MirrorFieldMapping {
  dateField: string;
  title(data: Record<string, unknown>): string | undefined;
}

function asString(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

/** Field mapping per routed collection — see content.config.ts for the source-of-truth schemas
 * this mirrors. `members` is deliberately absent: it's not in ENTRY_COLLECTIONS and has no route
 * that would ever call this with `collection: "members"`. */
const MIRROR_FIELDS: Record<string, MirrorFieldMapping> = {
  blog: { dateField: "pubDate", title: (d) => asString(d.title) },
  notes: { dateField: "publishDate", title: () => undefined },
  articles: { dateField: "publishDate", title: (d) => asString(d.title) },
  photos: { dateField: "publishDate", title: () => undefined },
  albums: { dateField: "publishDate", title: (d) => asString(d.title) },
  bookmarks: { dateField: "publishDate", title: (d) => asString(d.title) },
  replies: { dateField: "publishDate", title: () => undefined },
  likes: { dateField: "publishDate", title: () => undefined },
  rsvps: { dateField: "publishDate", title: (d) => (typeof d.rsvp === "string" ? `RSVP: ${d.rsvp}` : undefined) },
  checkins: {
    dateField: "publishDate",
    title: (d) => (typeof d.location === "string" ? `Checked in at ${d.location}` : undefined),
  },
  reposts: { dateField: "publishDate", title: () => undefined },
  announcements: { dateField: "publishDate", title: (d) => asString(d.title) },
  events: { dateField: "start", title: (d) => asString(d.name) },
  reviews: { dateField: "publishDate", title: (d) => asString(d.itemReviewed) },
};

/** JSON string syntax is a valid YAML double-quoted scalar, so this doubles as safe YAML
 * quoting without a YAML library — same trick this template's XML writers (escapeXml) use for
 * their own format. */
function yamlString(value: string): string {
  return JSON.stringify(value);
}

export function renderMarkdownMirror(entry: MarkdownMirrorEntry): string {
  const mapping = MIRROR_FIELDS[entry.collection];
  if (!mapping) {
    throw new Error(`renderMarkdownMirror: no mirror field mapping for collection "${entry.collection}"`);
  }

  const title = mapping.title(entry.data);

  const rawDate = entry.data[mapping.dateField];
  const date = rawDate instanceof Date ? rawDate : typeof rawDate === "string" ? new Date(rawDate) : undefined;
  const validDate = date && !Number.isNaN(date.getTime()) ? date : undefined;

  const rawTags = entry.data.tags;
  const tags = Array.isArray(rawTags) ? rawTags.filter((t): t is string => typeof t === "string") : undefined;

  const lines: string[] = [];
  if (title) lines.push(`title: ${yamlString(title)}`);
  if (validDate) lines.push(`date: ${validDate.toISOString()}`);
  if (tags && tags.length > 0) lines.push(`tags: [${tags.map(yamlString).join(", ")}]`);

  const frontmatter = lines.length > 0 ? `---\n${lines.join("\n")}\n---\n\n` : "";
  return `${frontmatter}${entry.body}`;
}
