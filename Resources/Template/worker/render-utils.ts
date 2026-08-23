/**
 * Small, dependency-free rendering helpers shared across the Worker's hand-rolled HTML responses
 * and mf2-JSON extraction. Extracted from `worker.ts` (rather than left there and imported back)
 * so modules like `reader-auth.ts`/`gated-content.ts` that `worker.ts` itself composes into
 * `ROUTES` can use them without an import cycle.
 */

export function escapeHTML(value: string): string {
  return value.replace(/[&<>"']/g, (character) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    "\"": "&quot;",
    "'": "&#39;",
  })[character] ?? character);
}

/**
 * Extracts a plain-text value from an mf2 `content` property entry. Microformats2-JSON — and
 * `@dwk/micropub`'s own accepted input shape — allows `content` to be either a plain string or a
 * rich-text object (`{ html, value }`); naively coercing the object form with `String(...)`
 * produces the literal `"[object Object]"`.
 */
export function extractMf2ContentString(raw: unknown): string {
  if (typeof raw === "string") return raw;
  if (raw && typeof raw === "object") {
    const obj = raw as { value?: unknown; html?: unknown };
    if (typeof obj.value === "string") return obj.value;
    // Standard Micropub JSON *create* shape for HTML content: { html } with no `value` key at
    // all — `value` only appears in mf2 read back off a rendered page, not in what a client
    // posts — so `html` is checked as a fallback, not just `value`.
    if (typeof obj.html === "string") return obj.html;
  }
  return "";
}

/** A photo attachment extracted from an mf2 `photo` property entry. */
export interface ExtractedPhoto {
  readonly url: string;
  readonly alt?: string;
}

/**
 * Extracts `{ url, alt? }` pairs from an mf2 `photo` property array — each entry is either a
 * plain URL string or the mf2 alt-text object shape `{ value, alt }`, mirroring
 * {@link extractMf2ContentString}'s tolerance for `content`'s two accepted shapes.
 */
export function extractMf2Photos(raw: unknown): ExtractedPhoto[] {
  if (!Array.isArray(raw)) return [];
  const photos: ExtractedPhoto[] = [];
  for (const entry of raw) {
    if (typeof entry === "string" && entry.length > 0) {
      photos.push({ url: entry });
      continue;
    }
    if (entry && typeof entry === "object") {
      const obj = entry as { value?: unknown; alt?: unknown };
      if (typeof obj.value === "string" && obj.value.length > 0) {
        photos.push(
          typeof obj.alt === "string" && obj.alt.length > 0
            ? { url: obj.value, alt: obj.alt }
            : { url: obj.value },
        );
      }
    }
  }
  return photos;
}

/**
 * Extracts the non-empty plain-string entries of an mf2 property array, dropping anything else
 * (rich-value objects, numbers, blanks). Used for flat IRI lists such as the restricted-post
 * fan-out's blind-recipient actor addresses, which — unlike `content`/`photo` — have no rich
 * object shape to accommodate.
 */
export function extractMf2StringList(raw: unknown): string[] {
  if (!Array.isArray(raw)) return [];
  return raw.filter((entry): entry is string => typeof entry === "string" && entry.length > 0);
}
