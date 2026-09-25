/**
 * Content accessibility validators.
 *
 * Uses html-validate for structural WCAG checks (heading hierarchy, missing
 * alt text, empty links) and adds heuristic checks for issues html-validate
 * doesn't cover (generic link text like "click here", placeholder alt text
 * like "image").
 */

import { HtmlValidate } from "html-validate";

export interface A11yIssue {
  rule: string;
  message: string;
  severity: "error" | "warning";
}

// ---------------------------------------------------------------------------
// html-validate instance — configured once, reused across calls
// ---------------------------------------------------------------------------

const htmlValidate = new HtmlValidate({
  rules: {
    "heading-level": "error",
    "wcag/h30": "error",
    "wcag/h37": "error",
  },
});

/** Map html-validate rule IDs to our A11yIssue rule names. */
const RULE_MAP: Record<string, string> = {
  "heading-level": "heading-level",
  "wcag/h30": "link-text-empty",
  "wcag/h37": "img-alt-missing",
};

function runHtmlValidate(html: string): A11yIssue[] {
  const report = htmlValidate.validateStringSync(html);
  return report.results.flatMap((result) =>
    result.messages.map((msg) => ({
      rule: RULE_MAP[msg.ruleId] ?? msg.ruleId,
      message: msg.message,
      severity: msg.severity === 2 ? ("error" as const) : ("warning" as const),
    })),
  );
}

// ---------------------------------------------------------------------------
// Heading hierarchy — delegates to html-validate heading-level rule
// ---------------------------------------------------------------------------

/**
 * Validate heading hierarchy: no skipped levels, single h1 per page.
 * Powered by html-validate's heading-level rule.
 */
export function validateHeadingHierarchy(html: string): A11yIssue[] {
  const all = runHtmlValidate(html);
  return all
    .filter((i) => i.rule === "heading-level")
    .map((i) => ({
      ...i,
      // Normalize rule names to match our API
      rule: i.message.toLowerCase().includes("multiple")
        ? "heading-multiple-h1"
        : "heading-skip",
    }));
}

// ---------------------------------------------------------------------------
// Link text quality — html-validate for empty + heuristic for generic
// ---------------------------------------------------------------------------

const GENERIC_LINK_PATTERNS = [
  /^click\s*here$/i,
  /^here$/i,
  /^read\s*more$/i,
  /^learn\s*more$/i,
  /^more\s*info$/i,
  /^more$/i,
  /^link$/i,
  /^this$/i,
];

/**
 * Strip HTML tags, repeating until the string stabilizes so that
 * overlapping/nested tag-like sequences (e.g. "<<script>script>") can't
 * survive a single removal pass.
 */
function stripTags(html: string): string {
  let previous: string;
  let current = html;
  do {
    previous = current;
    current = current.replace(/<[^>]*>/g, "");
  } while (current !== previous);
  return current;
}

const NAMED_ENTITIES: Record<string, string> = {
  amp: "&",
  lt: "<",
  gt: ">",
  quot: '"',
  apos: "'",
  nbsp: " ",
};

/**
 * Decode the small set of HTML entities that commonly appear in authored
 * link text (mirrors what a DOM parser's textContent would have resolved).
 */
function decodeEntities(text: string): string {
  return text.replace(/&(#x?[0-9a-f]+|[a-z]+);/gi, (match, entity: string) => {
    if (entity[0] === "#") {
      const codePoint =
        entity[1]?.toLowerCase() === "x"
          ? parseInt(entity.slice(2), 16)
          : parseInt(entity.slice(1), 10);
      return Number.isNaN(codePoint) ? match : String.fromCodePoint(codePoint);
    }
    const replacement = NAMED_ENTITIES[entity.toLowerCase()];
    return replacement ?? match;
  });
}

/**
 * Validate link text quality.
 * html-validate catches empty links (wcag/h30).
 * Heuristic catches generic phrases ("click here", "read more").
 */
export function validateLinkText(html: string): A11yIssue[] {
  // html-validate handles empty links (including aria-label awareness)
  const issues = runHtmlValidate(html).filter(
    (i) => i.rule === "link-text-empty",
  );

  // Heuristic: flag generic link text that html-validate doesn't catch
  const linkRegex = /<a\s([^>]*)>([\s\S]*?)<\/a>/gi;
  let match;

  while ((match = linkRegex.exec(html)) !== null) {
    const attrs = match[1];
    const text = decodeEntities(stripTags(match[2])).trim();
    if (!text || /aria-label\s*=/.test(attrs)) continue;

    for (const pattern of GENERIC_LINK_PATTERNS) {
      if (pattern.test(text)) {
        issues.push({
          rule: "link-text-generic",
          message: `Link text "${text}" is not descriptive — screen reader users won't know where it leads.`,
          severity: "warning",
        });
        break;
      }
    }
  }

  return issues;
}

// ---------------------------------------------------------------------------
// Image alt text — html-validate for missing + heuristic for placeholder
// ---------------------------------------------------------------------------

const PLACEHOLDER_ALT_PATTERNS = [
  /^image$/i,
  /^photo$/i,
  /^picture$/i,
  /^img$/i,
  /^untitled$/i,
  /^placeholder$/i,
  /^screenshot$/i,
  /^banner$/i,
  /^hero$/i,
];

/**
 * Validate image alt text.
 * html-validate catches missing alt attributes (wcag/h37).
 * Heuristic catches placeholder text ("image", "photo", "untitled").
 */
export function validateImageAlt(html: string): A11yIssue[] {
  // html-validate handles missing alt (including role=presentation awareness)
  const issues = runHtmlValidate(html).filter(
    (i) => i.rule === "img-alt-missing",
  );

  // Heuristic: flag placeholder alt text
  const imgRegex = /<img\s([^>]*?)\/?>/gi;
  let match;

  while ((match = imgRegex.exec(html)) !== null) {
    const attrs = match[1];
    const altMatch =
      attrs.match(/alt\s*=\s*"([^"]*)"/i) ??
      attrs.match(/alt\s*=\s*'([^']*)'/i);

    if (!altMatch) continue; // html-validate already flagged this
    const alt = altMatch[1].trim();
    if (alt === "") continue; // Decorative — intentionally empty

    for (const pattern of PLACEHOLDER_ALT_PATTERNS) {
      if (pattern.test(alt)) {
        issues.push({
          rule: "img-alt-placeholder",
          message: `Image alt text "${alt}" is a placeholder — describe what the image shows.`,
          severity: "warning",
        });
        break;
      }
    }
  }

  return issues;
}

// ---------------------------------------------------------------------------
// Unified validator — runs all checks at once
// ---------------------------------------------------------------------------

/**
 * Run all accessibility checks on an HTML string.
 * Returns a deduplicated array of issues sorted by severity (errors first).
 */
export function validateHtml(html: string): A11yIssue[] {
  const issues = [
    ...validateHeadingHierarchy(html),
    ...validateLinkText(html),
    ...validateImageAlt(html),
  ];

  return issues.sort((a, b) => {
    if (a.severity === "error" && b.severity !== "error") return -1;
    if (a.severity !== "error" && b.severity === "error") return 1;
    return 0;
  });
}

// ---------------------------------------------------------------------------
// Colour contrast of :root token pairs (#2022)
// ---------------------------------------------------------------------------
//
// The always-on tier can't compute per-element colours (that needs a browser — tiers 2–3), but it
// can check the design tokens the template renders everything with. This reads every `:root`
// block in a stylesheet — the top-level ones and those nested in `@media`, where the dark palette
// lives — resolves each against the top-level block the way the cascade does, and checks the
// token pairs `global.css` actually renders. Anything it can't resolve to an opaque colour is
// skipped, never guessed: a skipped pair is correct, a false alarm is a bug.

/** Minimum contrast ratio for body text (WCAG 2.2 SC 1.4.3, AA). */
export const CONTRAST_AA = 4.5;
/** Below this, a link or button pair is an error rather than a warning. */
const CONTRAST_FLOOR = 3;
/** How many `var()` hops are followed before a value is treated as unresolvable. */
const VAR_DEPTH = 4;

/** The foreground/background token pairs the template renders, and how strictly each is held. */
const CONTRAST_PAIRS: ReadonlyArray<{ fg: string; bg: string; kind: "text" | "link" }> = [
  { fg: "--color-text", bg: "--color-background", kind: "text" },
  { fg: "--color-text", bg: "--color-surface", kind: "text" },
  { fg: "--color-text-muted", bg: "--color-background", kind: "text" },
  { fg: "--color-text-muted", bg: "--color-surface", kind: "text" },
  { fg: "--color-primary", bg: "--color-background", kind: "link" },
  { fg: "--color-primary", bg: "--color-surface", kind: "link" },
  { fg: "--color-background", bg: "--color-primary", kind: "link" }, // button label on fill
];

/** One `:root` declaration block: `media` is `undefined` for a top-level block. */
interface RootBlock {
  media?: string;
  tokens: Map<string, string>;
}

/** Index of the `}` matching the `{` at `open`, or -1. */
function matchingBrace(css: string, open: number): number {
  let depth = 0;
  for (let i = open; i < css.length; i++) {
    if (css[i] === "{") depth++;
    else if (css[i] === "}" && --depth === 0) return i;
  }
  return -1;
}

/** Custom-property declarations in a rule body, in source order (later wins). */
function customProperties(body: string): Map<string, string> {
  const tokens = new Map<string, string>();
  let depth = 0;
  let start = 0;
  const declarations: string[] = [];
  for (let i = 0; i <= body.length; i++) {
    const ch = body[i];
    if (ch === "(") depth++;
    else if (ch === ")") depth--;
    else if ((ch === ";" && depth === 0) || i === body.length) {
      declarations.push(body.slice(start, i));
      start = i + 1;
    }
  }
  for (const declaration of declarations) {
    const colon = declaration.indexOf(":");
    if (colon < 0) continue;
    const name = declaration.slice(0, colon).trim();
    if (!name.startsWith("--")) continue;
    tokens.set(name, declaration.slice(colon + 1).replace(/!important\s*$/i, "").trim());
  }
  return tokens;
}

/** Every `:root` block in `css`, recursing into `@media` (nested conditions are joined with "and"). */
function rootBlocks(css: string, media?: string): RootBlock[] {
  const blocks: RootBlock[] = [];
  let i = 0;
  while (i < css.length) {
    const open = css.indexOf("{", i);
    if (open < 0) break;
    // A statement at-rule (`@import …;`, `@charset …;`) before the next block ends at its `;`.
    const prelude = css.slice(i, open).split(";").pop()!.trim();
    const close = matchingBrace(css, open);
    if (close < 0) break;
    const body = css.slice(open + 1, close);
    if (/^@media\b/i.test(prelude)) {
      const condition = prelude.replace(/^@media\s*/i, "").trim();
      blocks.push(...rootBlocks(body, media ? `${media} and ${condition}` : condition));
    } else if (prelude.split(",").some((selector) => selector.trim() === ":root")) {
      blocks.push({ media, tokens: customProperties(body) });
    }
    i = close + 1;
  }
  return blocks;
}

/** An opaque sRGB colour, 0–255 per channel. */
type RGB = [number, number, number];

/** Parses `#rgb`/`#rrggbb` (and opaque `#rgba`/`#rrggbbaa`), `rgb()`/`rgba()` and `hsl()`/`hsla()`
 * in comma or space syntax. `undefined` for anything else, and for any alpha below 1. */
export function parseOpaqueColor(value: string): RGB | undefined {
  const v = value.trim().toLowerCase();
  const hex = v.match(/^#([0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})$/);
  if (hex) {
    const digits = hex[1].length <= 4 ? [...hex[1]].map((d) => d + d).join("") : hex[1];
    if (digits.length === 8 && digits.slice(6) !== "ff") return undefined;
    return [0, 2, 4].map((at) => parseInt(digits.slice(at, at + 2), 16)) as RGB;
  }
  const fn = v.match(/^(rgba?|hsla?)\(([^()]*)\)$/);
  if (!fn) return undefined;
  const [channels, alpha] = splitColorArgs(fn[2]);
  if (!channels || channels.length !== 3) return undefined;
  if (alpha !== undefined) {
    const a = alpha.endsWith("%") ? parseFloat(alpha) / 100 : parseFloat(alpha);
    if (!Number.isFinite(a) || a < 1) return undefined;
  }
  if (fn[1].startsWith("rgb")) {
    const rgb = channels.map((c) => (c.endsWith("%") ? (parseFloat(c) / 100) * 255 : parseFloat(c)));
    if (rgb.some((c) => !Number.isFinite(c) || c < 0 || c > 255)) return undefined;
    return rgb as RGB;
  }
  const hue = channels[0].match(/^(-?[\d.]+)(deg)?$/);
  if (!hue || !channels[1].endsWith("%") || !channels[2].endsWith("%")) return undefined;
  const h = (((parseFloat(hue[1]) % 360) + 360) % 360) / 360;
  const s = parseFloat(channels[1]) / 100;
  const l = parseFloat(channels[2]) / 100;
  if (![h, s, l].every(Number.isFinite) || s < 0 || s > 1 || l < 0 || l > 1) return undefined;
  return hslToRgb(h, s, l);
}

/** `[channels, alpha?]` from a colour function's argument list, comma or space/slash syntax. */
function splitColorArgs(args: string): [string[] | undefined, string | undefined] {
  const trimmed = args.trim();
  if (trimmed.includes(",")) {
    const parts = trimmed.split(",").map((p) => p.trim());
    if (parts.length === 3) return [parts, undefined];
    if (parts.length === 4) return [parts.slice(0, 3), parts[3]];
    return [undefined, undefined];
  }
  const [main, alpha, extra] = trimmed.split("/").map((p) => p.trim());
  if (extra !== undefined) return [undefined, undefined];
  return [main.split(/\s+/).filter(Boolean), alpha];
}

function hslToRgb(h: number, s: number, l: number): RGB {
  const q = l < 0.5 ? l * (1 + s) : l + s - l * s;
  const p = 2 * l - q;
  const channel = (t: number) => {
    const u = t < 0 ? t + 1 : t > 1 ? t - 1 : t;
    const c = u < 1 / 6 ? p + (q - p) * 6 * u : u < 1 / 2 ? q : u < 2 / 3 ? p + (q - p) * (2 / 3 - u) * 6 : p;
    return c * 255;
  };
  return [channel(h + 1 / 3), channel(h), channel(h - 1 / 3)];
}

/** WCAG 2.x relative luminance. */
function luminance([r, g, b]: RGB): number {
  const linear = (c: number) => {
    const s = c / 255;
    return s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b);
}

/** WCAG 2.x contrast ratio between two opaque colours (1–21). */
export function contrastRatio(a: RGB, b: RGB): number {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}

/** Follows `var(--x[, fallback])` up to {@link VAR_DEPTH} hops within `tokens`; `undefined` when
 * the chain doesn't end in a plain value. */
function resolveToken(tokens: Map<string, string>, name: string): string | undefined {
  let value = tokens.get(name);
  for (let hop = 0; value !== undefined && hop <= VAR_DEPTH; hop++) {
    const ref = value.match(/^var\(\s*(--[\w-]+)\s*(?:,\s*([\s\S]*))?\)$/);
    if (!ref) return value;
    if (hop === VAR_DEPTH) return undefined;
    value = tokens.get(ref[1]) ?? ref[2]?.trim();
  }
  return undefined;
}

/** The token a declaration value is exactly `var(<token>[, …])` of, if any. */
function varToken(value: string | undefined): string | undefined {
  return value?.trim().match(/^var\(\s*(--[\w-]+)\s*[,)]/)?.[1];
}

/** Whether `css` actually draws `fg` text on a `bg` fill somewhere: some rule sets
 * `color: var(fg)` and either leaves its background to the page's (no background declaration of
 * its own) or sets it to `var(bg)`, and some rule fills with `var(bg)`. A rule painting `fg` on
 * its own literal background (`background-color: #fff`) is drawing a different pair. */
function drawsPair(css: string, fg: string, bg: string): boolean {
  let fgOnBg = false;
  let bgFill = false;
  // Innermost `{ … }` bodies are exactly the declaration blocks, at any at-rule depth.
  for (const [, body] of css.matchAll(/\{([^{}]*)\}/g)) {
    const declarations = new Map<string, string>();
    for (const declaration of body.split(";")) {
      const colon = declaration.indexOf(":");
      if (colon > 0) declarations.set(declaration.slice(0, colon).trim().toLowerCase(), declaration.slice(colon + 1));
    }
    const fill = declarations.get("background-color") ?? declarations.get("background");
    if (varToken(fill) === bg) bgFill = true;
    if (varToken(declarations.get("color")) === fg && (fill === undefined || varToken(fill) === bg)) fgOnBg = true;
  }
  return fgOnBg && bgFill;
}

/**
 * Checks the template's token pairs in every `:root` block of `css` (#2022). Top-level `:root`
 * blocks merge into the "light" palette; each `@media` `:root` is checked against that palette
 * with its own overrides applied, and only for pairs it actually overrides, so a light-mode
 * failure isn't reported again under every unrelated media query.
 *
 * A pair is checked only when `css` actually draws it ({@link drawsPair}). A theme pack that
 * draws its dark-mode links with its own token (`--ap-link`) instead of `--color-primary`, or
 * puts `--color-primary` text on a literal white button, would otherwise be flagged for a pair no
 * page ever shows. Pass everything a page loads, so those rules are visible.
 */
export function validateContrast(css: string): A11yIssue[] {
  const uncommented = css.replace(/\/\*[\s\S]*?\*\//g, "");
  const blocks = rootBlocks(uncommented);
  const rendered = CONTRAST_PAIRS.filter(({ fg, bg }) => drawsPair(uncommented, fg, bg));
  const base = new Map<string, string>();
  for (const block of blocks) {
    if (block.media === undefined) for (const [k, v] of block.tokens) base.set(k, v);
  }
  const issues: A11yIssue[] = [];
  const seen = new Set<string>();
  const check = (tokens: Map<string, string>, label: string, overridden?: Map<string, string>) => {
    for (const { fg, bg, kind } of rendered) {
      if (overridden && !overridden.has(fg) && !overridden.has(bg)) continue;
      const fgValue = resolveToken(tokens, fg);
      const bgValue = resolveToken(tokens, bg);
      const fgColor = fgValue === undefined ? undefined : parseOpaqueColor(fgValue);
      const bgColor = bgValue === undefined ? undefined : parseOpaqueColor(bgValue);
      if (!fgColor || !bgColor) continue;
      const ratio = contrastRatio(fgColor, bgColor);
      if (ratio >= CONTRAST_AA) continue;
      const severity = kind === "text" || ratio < CONTRAST_FLOOR ? "error" : "warning";
      // Floored, so a failing 4.46:1 never displays as a passing-looking "4.5:1".
      const shown = (Math.floor(ratio * 10) / 10).toFixed(1);
      const message =
        `${fg} on ${bg} has a contrast ratio of ${shown}:1 in the ${label} palette; ` +
        `WCAG AA needs at least ${CONTRAST_AA}:1.`;
      if (seen.has(message)) continue;
      seen.add(message);
      issues.push({ rule: "color-contrast", message, severity });
    }
  };
  check(base, "light");
  for (const block of blocks) {
    if (block.media === undefined) continue;
    check(new Map([...base, ...block.tokens]), `@media ${block.media}`, block.tokens);
  }
  return issues;
}
