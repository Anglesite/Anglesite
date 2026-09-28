#!/usr/bin/env npx tsx
/**
 * Page-weight check over the built site in `dist/` (Anglesite #2020) — the first `.performance`
 * audit. Measures what a first-time visitor downloads per page and flags the things owners
 * actually get wrong: heavy pages, oversized images, image formats browsers can't show, and
 * images without dimensions (which make the page jump as it loads).
 *
 * A page's weight is its own HTML plus the on-disk size of every same-site asset it references
 * through `<img>`, `<link rel="stylesheet">`, `<script src>` and `<source srcset>`. Shared assets
 * count toward every page that uses them — a stylesheet on 40 pages is downloaded by a first
 * visit to any one of them. Responsive-image candidates are alternatives, not additions: the
 * candidates of one `srcset`, and every source inside one `<picture>`, count once, as the largest
 * of them (the worst single download), so a responsive image isn't charged for every width and
 * format it's offered in. Off-site references count as 0 and are reported as skipped — this
 * script does no network I/O.
 *
 * Reference resolution (same-site vs off-site, relative paths, directory-style URLs) is
 * `broken-links.ts`'s, so the two audits agree on what a reference points at. A reference whose
 * file doesn't exist counts as 0 here; the broken-link audit reports it.
 *
 * Usage:
 *   tsx scripts/page-weight.ts          # human-readable report
 *   tsx scripts/page-weight.ts --json   # machine-readable report (what the app's audit consumes)
 *
 * Exit codes mirror `broken-links.ts`: 0 — no problems; 1 — at least one problem; 2 — the scan
 * couldn't run (no `dist/` or no built pages in it).
 */

import { existsSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import {
  OutputIndex,
  classify,
  collectSiteInputs,
  parseAttributes,
  resolvePath,
  routeForDistPath,
  urlPathForDistPath,
  walkFiles,
} from "./broken-links";

// ---------------------------------------------------------------------------
// Thresholds
// ---------------------------------------------------------------------------

const KB = 1024;
const MB = 1024 * KB;
/** A page's total weight above this is a warning… */
export const HEAVY_PAGE_BYTES = 1.5 * MB;
/** …and above this, critical. */
export const VERY_HEAVY_PAGE_BYTES = 4 * MB;
/** Any single image above this is a warning. */
export const OVERSIZED_IMAGE_BYTES = 500 * KB;
/** Formats browsers can't display (or display only in Safari) — critical wherever they appear in `dist/`. */
export const NON_WEB_IMAGE_EXTENSIONS = new Set([".bmp", ".tif", ".tiff", ".heic", ".heif"]);
const IMAGE_EXTENSIONS = new Set([
  ".jpg", ".jpeg", ".png", ".gif", ".webp", ".avif", ".svg", ".ico", ...NON_WEB_IMAGE_EXTENSIONS,
]);

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export type ProblemKind =
  | "heavy-page"
  | "very-heavy-page"
  | "oversized-image"
  | "non-web-image-format"
  | "img-missing-dimensions";

/**
 * One problem. Page-level kinds (`heavy-page`, `very-heavy-page`, `img-missing-dimensions`) set
 * `page`; asset-level kinds (`oversized-image`, `non-web-image-format`) set `asset` and list the
 * `pages` that reference it — grouped by asset, since one image used site-wide is one fix.
 */
export interface PageWeightProblem {
  kind: ProblemKind;
  /** Route of the page, for page-level kinds. */
  page?: string;
  /** Site-absolute URL path of the asset, for asset-level kinds. */
  asset?: string;
  /** The page's total weight, or the asset's size. */
  bytes?: number;
  /** Pages referencing the asset (sorted), for asset-level kinds. May be empty for an unreferenced file. */
  pages?: string[];
  /** How many `<img>` on the page lack dimensions, for `img-missing-dimensions`. */
  count?: number;
  /** Up to three `src` values of those images, for `img-missing-dimensions`. */
  examples?: string[];
}

export interface PageWeightReport {
  version: 1;
  pagesScanned: number;
  /** The heaviest page's total, so the summary can say how close a clean site is to the limit. */
  heaviestPageBytes: number;
  /** Off-site references seen and counted as 0 — never fetched. */
  externalReferencesSkipped: number;
  /** Sorted: page-level problems by page, then asset-level ones by asset — deterministic across runs. */
  problems: PageWeightProblem[];
}

export class NoBuiltPagesError extends Error {
  constructor(public readonly distDir: string) {
    super(`no built pages found under ${distDir} — run \`npm run build\` first`);
    this.name = "NoBuiltPagesError";
  }
}

export interface ScanOptions {
  /** Hosts treated as this site (from `.site-config` `DOMAIN`), so absolute self-links still count. */
  siteHosts?: Set<string>;
}

// ---------------------------------------------------------------------------
// Reference extraction
// ---------------------------------------------------------------------------

const COMMENT_PATTERN = /<!--[\s\S]*?-->/g;
/** A `<script>` block, capturing its opening tag's attributes. Same end-tag leniency as `broken-links.ts`. */
const SCRIPT_BLOCK_PATTERN = /<script\b([^>]*)>[\s\S]*?<\/script\b[^>]*>/gi;
const PICTURE_BLOCK_PATTERN = /<picture\b[^>]*>([\s\S]*?)<\/picture\b[^>]*>/gi;
const TAG_PATTERN = /<([a-zA-Z][a-zA-Z0-9-]*)\b([^>]*)>/g;

/** The references one page makes that carry weight, plus its `<img>` elements for the dimensions check. */
export interface PageReferences {
  /** Stylesheets and scripts: each is downloaded. */
  single: string[];
  /** Alternative sets — a `<picture>`, or an `<img>` with `srcset` — each downloaded once, as one of its members. */
  groups: string[][];
  /** Every `<img>`: its `src` and whether it declares `width` and/or `height`. */
  images: Array<{ src: string; hasDimension: boolean }>;
}

function attributes(source: string): Map<string, string | null> {
  return new Map(parseAttributes(source));
}

function srcsetCandidates(srcset: string | null | undefined): string[] {
  if (!srcset) return [];
  return srcset
    .split(",")
    .map((candidate) => candidate.trim().split(/\s+/)[0])
    .filter((url): url is string => Boolean(url));
}

/** Collects the `<img>` in `html` into `refs`: an image with `srcset` is one group of alternatives. */
function collectImages(html: string, refs: PageReferences, into?: string[]): void {
  for (const tag of html.matchAll(TAG_PATTERN)) {
    const name = tag[1].toLowerCase();
    const attrs = attributes(tag[2]);
    if (name === "source" && into) {
      into.push(...srcsetCandidates(attrs.get("srcset")));
      const src = attrs.get("src");
      if (src) into.push(src);
    }
    if (name !== "img") continue;
    const src = attrs.get("src") ?? "";
    refs.images.push({ src, hasDimension: attrs.has("width") || attrs.has("height") });
    const candidates = [...(src ? [src] : []), ...srcsetCandidates(attrs.get("srcset"))];
    if (into) into.push(...candidates);
    else if (candidates.length > 0) refs.groups.push(candidates);
  }
}

export function extractPageReferences(html: string): PageReferences {
  const refs: PageReferences = { single: [], groups: [], images: [] };
  let rest = html.replace(COMMENT_PATTERN, " ");
  // Scripts: keep the `src`, then drop the block so inline code can't produce phantom tags.
  for (const block of rest.matchAll(SCRIPT_BLOCK_PATTERN)) {
    const src = attributes(block[1]).get("src");
    if (src) refs.single.push(src);
  }
  rest = rest.replace(SCRIPT_BLOCK_PATTERN, " ");
  // A <picture> is one image, whichever of its sources the browser picks.
  for (const block of rest.matchAll(PICTURE_BLOCK_PATTERN)) {
    const members: string[] = [];
    collectImages(block[1], refs, members);
    if (members.length > 0) refs.groups.push(members);
  }
  rest = rest.replace(PICTURE_BLOCK_PATTERN, " ");
  collectImages(rest, refs);
  for (const tag of rest.matchAll(TAG_PATTERN)) {
    if (tag[1].toLowerCase() !== "link") continue;
    const attrs = attributes(tag[2]);
    const rel = (attrs.get("rel") ?? "").toLowerCase().split(/\s+/);
    const href = attrs.get("href");
    if (rel.includes("stylesheet") && href) refs.single.push(href);
  }
  return refs;
}

// ---------------------------------------------------------------------------
// Scanning
// ---------------------------------------------------------------------------

function extensionOf(path: string): string {
  const dot = path.lastIndexOf(".");
  return dot > path.lastIndexOf("/") ? path.slice(dot).toLowerCase() : "";
}

function compare(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

export function scan(distDir: string, options: ScanOptions = {}): PageWeightReport {
  const siteHosts = options.siteHosts ?? new Set<string>();
  const files = walkFiles(distDir);
  const htmlPaths = files.filter((f) => f.endsWith(".html")).sort();
  if (htmlPaths.length === 0) throw new NoBuiltPagesError(distDir);
  const index = new OutputIndex(files);
  const sizes = new Map<string, number>();
  const sizeOf = (file: string): number => {
    let size = sizes.get(file);
    if (size === undefined) {
      size = statSync(join(distDir, file)).size;
      sizes.set(file, size);
    }
    return size;
  };

  let externalSkipped = 0;
  let heaviest = 0;
  const problems: PageWeightProblem[] = [];
  /** dist-relative image file → pages referencing it. */
  const imagePages = new Map<string, Set<string>>();

  for (const htmlPath of htmlPaths) {
    const html = readFileSync(join(distDir, htmlPath), "utf-8");
    const page = routeForDistPath(htmlPath);
    const base = urlPathForDistPath(htmlPath);
    const refs = extractPageReferences(html);

    /** The dist file `reference` resolves to, or `null` (off-site, non-HTTP, or missing). */
    const resolve = (reference: string): string | null => {
      const classification = classify(reference, siteHosts);
      if (classification.kind === "external") {
        externalSkipped += 1;
        return null;
      }
      if (classification.kind !== "internal" || classification.path === "") return null;
      return index.servedFile(resolvePath(classification.path, base));
    };
    const noteImage = (file: string) => {
      if (!IMAGE_EXTENSIONS.has(extensionOf(file))) return;
      if (!imagePages.has(file)) imagePages.set(file, new Set());
      imagePages.get(file)!.add(page);
    };

    const counted = new Set<string>();
    let bytes = sizeOf(htmlPath);
    for (const reference of refs.single) {
      const file = resolve(reference);
      if (file && !counted.has(file)) {
        counted.add(file);
        bytes += sizeOf(file);
      }
    }
    for (const group of refs.groups) {
      const members = group.map(resolve).filter((file): file is string => file !== null);
      members.forEach(noteImage);
      const largest = members.reduce<string | null>((best, file) => (best === null || sizeOf(file) > sizeOf(best) ? file : best), null);
      if (largest && !counted.has(largest)) {
        counted.add(largest);
        bytes += sizeOf(largest);
      }
    }
    heaviest = Math.max(heaviest, bytes);
    if (bytes > VERY_HEAVY_PAGE_BYTES) problems.push({ kind: "very-heavy-page", page, bytes });
    else if (bytes > HEAVY_PAGE_BYTES) problems.push({ kind: "heavy-page", page, bytes });

    const undimensioned = refs.images.filter((image) => !image.hasDimension);
    if (undimensioned.length > 0) {
      problems.push({
        kind: "img-missing-dimensions",
        page,
        count: undimensioned.length,
        examples: undimensioned.slice(0, 3).map((image) => image.src),
      });
    }
  }

  const assetProblems: PageWeightProblem[] = [];
  for (const [file, pages] of imagePages) {
    if (NON_WEB_IMAGE_EXTENSIONS.has(extensionOf(file))) continue; // reported below, once
    const bytes = sizeOf(file);
    if (bytes > OVERSIZED_IMAGE_BYTES) {
      assetProblems.push({ kind: "oversized-image", asset: `/${file}`, bytes, pages: [...pages].sort(compare) });
    }
  }
  // Non-web formats count wherever they sit in dist/, referenced or not — they ship either way.
  for (const file of files) {
    if (!NON_WEB_IMAGE_EXTENSIONS.has(extensionOf(file))) continue;
    assetProblems.push({
      kind: "non-web-image-format",
      asset: `/${file}`,
      bytes: sizeOf(file),
      pages: [...(imagePages.get(file) ?? [])].sort(compare),
    });
  }

  problems.sort((a, b) => compare(a.page ?? "", b.page ?? "") || compare(a.kind, b.kind));
  assetProblems.sort((a, b) => compare(a.asset ?? "", b.asset ?? "") || compare(a.kind, b.kind));
  return {
    version: 1,
    pagesScanned: htmlPaths.length,
    heaviestPageBytes: heaviest,
    externalReferencesSkipped: externalSkipped,
    problems: [...problems, ...assetProblems],
  };
}

// ---------------------------------------------------------------------------
// Reporting
// ---------------------------------------------------------------------------

export function formatBytes(bytes: number): string {
  return bytes >= MB ? `${(bytes / MB).toFixed(1)} MB` : `${Math.round(bytes / KB)} KB`;
}

export function formatReport(report: PageWeightReport): string {
  const lines = [
    `Page-weight check: ${report.pagesScanned} page(s), heaviest ${formatBytes(report.heaviestPageBytes)}, ${report.problems.length} problem(s)` +
      (report.externalReferencesSkipped > 0 ? `; ${report.externalReferencesSkipped} off-site reference(s) not counted` : ""),
  ];
  for (const p of report.problems) {
    switch (p.kind) {
      case "very-heavy-page":
      case "heavy-page":
        lines.push(`  ✗ ${p.page}: ${formatBytes(p.bytes ?? 0)} total (${p.kind})`);
        break;
      case "oversized-image":
      case "non-web-image-format":
        lines.push(`  ✗ ${p.asset}: ${formatBytes(p.bytes ?? 0)} (${p.kind}), used on ${p.pages?.length ?? 0} page(s)`);
        break;
      case "img-missing-dimensions":
        lines.push(`  ✗ ${p.page}: ${p.count} image(s) without width/height`);
        break;
    }
  }
  if (report.problems.length === 0) lines.push("  ✓ every page is within its weight budget");
  return lines.join("\n");
}

export function exitCodeFor(report: PageWeightReport): number {
  return report.problems.length === 0 ? 0 : 1;
}

// ---------------------------------------------------------------------------
// Script entry — executed when run directly (not when imported by tests)
// ---------------------------------------------------------------------------

if (process.argv[1]?.endsWith("page-weight.ts")) {
  const wantJson = process.argv.slice(2).includes("--json");
  const siteRoot = process.cwd();
  const distDir = join(siteRoot, "dist");
  try {
    if (!existsSync(distDir)) throw new NoBuiltPagesError(distDir);
    const report = scan(distDir, { siteHosts: collectSiteInputs(siteRoot, distDir).siteHosts });
    console.log(wantJson ? JSON.stringify(report, null, 2) : formatReport(report));
    process.exit(exitCodeFor(report));
  } catch (err) {
    if (err instanceof NoBuiltPagesError) {
      console.error(`Page-weight check couldn't run: ${err.message}`);
      process.exit(2);
    }
    console.error("Page-weight check failed:", err);
    process.exit(2);
  }
}
