#!/usr/bin/env npx tsx
/**
 * Broken-link check over the built site in `dist/` (Anglesite #1996).
 *
 * Walks every `.html` and `.css` file the build produced and reports internal references that
 * point at nothing — a link, image, stylesheet, script, font, or `#anchor` whose target isn't in
 * the output. An *output* scan, not a source scan: a page renamed outside the editor, a post
 * deleted while others still link to it, or a pack swap that moved an image path all surface
 * here even though every individual source file is well-formed.
 *
 * "Nothing serves it" means no file in `dist/`, no redirect (`redirects.json` / `dist/_redirects`),
 * and no runtime route — the site's Worker answers paths like `/webmention` or
 * `/.well-known/oauth-authorization-server` with no static file behind them, and every page links
 * to some of them, so the Worker's `ROUTES` table (`worker/worker.ts`) is read as the list of
 * dynamically-served paths.
 *
 * Scope is internal references only. `mailto:`, `tel:`, `javascript:`, `data:` and every other
 * non-HTTP scheme are skipped; `http(s)://` references are checked only when their host is the
 * site's own `DOMAIN` (so an absolute self-link still counts). Off-site links are counted but
 * never fetched — no network, no bot-challenge false positives, and the scan stays fast enough
 * to run on every audit. The opt-in external check is Anglesite #2001.
 *
 * Known limitations: references are extracted with regexes over tags, not a full HTML tokenizer,
 * so a literal `>` inside a quoted attribute value truncates that tag (the same accepted
 * won't-fix as `microformats.ts`'s scanners). `<script>` blocks and HTML comments are stripped
 * first, so hydration payloads and commented-out markup can't produce phantom references.
 * Anything JavaScript builds at runtime is invisible — accepted, since the template renders
 * statically.
 *
 * Usage:
 *   tsx scripts/broken-links.ts          # human-readable report
 *   tsx scripts/broken-links.ts --json   # machine-readable report (what the app's audit consumes)
 *
 * Exit codes: 0 — no problems; 1 — at least one problem; 2 — the scan couldn't run (no `dist/`
 * or no built pages in it — reported as an error rather than an empty pass, the same fail-closed
 * stance as `markup-validate.ts`'s vacuous-pass guard).
 */

import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { readConfig } from "./config";
import { readRedirects } from "./redirects";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export type ProblemKind = "missing-target" | "missing-anchor";

/** One reference that didn't resolve, deduplicated per `(kind, page, resolvedPath)`. */
export interface BrokenLinkProblem {
  kind: ProblemKind;
  /** Route of the page (or CSS file) holding the reference, e.g. `/blog/hello/`. */
  page: string;
  /** The reference exactly as written in the markup, so the owner can search their source for it. */
  reference: string;
  /** The site-absolute path the reference resolved to (fragment included for `missing-anchor`). */
  resolvedPath: string;
}

export interface BrokenLinkReport {
  version: 1;
  pagesScanned: number;
  referencesChecked: number;
  /** Off-site `http(s)` references seen and deliberately not checked. */
  externalReferencesSkipped: number;
  /** Sorted by page, then resolved path, then reference — deterministic across runs. */
  problems: BrokenLinkProblem[];
}

/** A path the site's Worker serves at request time with no file behind it in `dist/`. */
export interface RuntimeRoute {
  path: string;
  /** `true` also covers every descendant (`/pod/anything`) — the Worker table's `match: "prefix"`. */
  prefix: boolean;
}

export interface ScanOptions {
  /** Lowercased hostnames that count as this site (e.g. `example.com`, `www.example.com`). */
  siteHosts?: Set<string>;
  /** Site-absolute redirect sources; a trailing `*` makes an entry a prefix match (Cloudflare splat). */
  redirectSources?: Set<string>;
  runtimeRoutes?: RuntimeRoute[];
}

/** Thrown when `dist/` holds no HTML at all — the scan couldn't run, as opposed to "ran and found nothing". */
export class NoBuiltPagesError extends Error {
  constructor(public readonly distDir: string) {
    super(`no built pages found under ${distDir} — run \`npm run build\` first`);
    this.name = "NoBuiltPagesError";
  }
}

// ---------------------------------------------------------------------------
// Output index
// ---------------------------------------------------------------------------

/**
 * The set of files a build produced plus the lookup rules Cloudflare's asset serving (and Astro's
 * `build.format: "directory"` default) apply to a request path. Built once per scan so each
 * reference costs a set lookup, not a `stat`.
 */
export class OutputIndex {
  private readonly files: Set<string>;
  private readonly exactRedirects = new Set<string>();
  private readonly prefixRedirects: string[] = [];
  private readonly runtimeRoutes: RuntimeRoute[];

  constructor(files: Iterable<string>, redirectSources: Iterable<string> = [], runtimeRoutes: RuntimeRoute[] = []) {
    this.files = new Set(files);
    this.runtimeRoutes = runtimeRoutes;
    for (const source of redirectSources) {
      if (source.endsWith("*")) {
        this.prefixRedirects.push(source.slice(0, -1));
      } else {
        this.exactRedirects.add(source);
        this.exactRedirects.add(source.endsWith("/") ? source.slice(0, -1) : `${source}/`);
      }
    }
  }

  /**
   * The `dist`-relative file that would serve `path` (site-absolute, no query/fragment), or `null`.
   * `/about/` → `about/index.html`; `/about` → `about/index.html` or `about.html`;
   * `/hero.png` → `hero.png`; `/` → `index.html`.
   */
  servedFile(path: string): string | null {
    const trimmed = stripLeadingSlash(safeDecode(path));
    let candidates: string[];
    if (trimmed === "") {
      candidates = ["index.html"];
    } else if (trimmed.endsWith("/")) {
      candidates = [`${trimmed}index.html`, `${trimmed.slice(0, -1)}.html`];
    } else {
      candidates = [trimmed, `${trimmed}/index.html`, `${trimmed}.html`];
    }
    return candidates.find((c) => this.files.has(c)) ?? null;
  }

  /** Whether a redirect rule covers `path`, so its lack of a served file is intentional. */
  isRedirected(path: string): boolean {
    const decoded = safeDecode(path);
    if (this.exactRedirects.has(decoded)) return true;
    return this.prefixRedirects.some((prefix) => decoded.startsWith(prefix));
  }

  /**
   * Whether the Worker answers `path` at request time. An exact route also matches its
   * trailing-slash spelling; a prefix route matches the path itself and anything under it — the
   * same rule as `matchRoute` in `worker/worker.ts`.
   */
  isRuntimeServed(path: string): boolean {
    const decoded = safeDecode(path);
    const bare = decoded.length > 1 && decoded.endsWith("/") ? decoded.slice(0, -1) : decoded;
    return this.runtimeRoutes.some((route) => bare === route.path || (route.prefix && bare.startsWith(`${route.path}/`)));
  }
}

function stripLeadingSlash(path: string): string {
  return path.startsWith("/") ? path.slice(1) : path;
}

function safeDecode(path: string): string {
  try {
    return decodeURIComponent(path);
  } catch {
    return path;
  }
}

// ---------------------------------------------------------------------------
// Reference extraction
// ---------------------------------------------------------------------------

/** Every tag, capturing its name and attribute string. Same literal-`>`-in-attribute limitation as noted above. */
const TAG_PATTERN = /<([a-zA-Z][a-zA-Z0-9-]*)\b([^>]*)>/g;
/** One attribute: name, then an optional quoted or bare value. */
const ATTRIBUTE_PATTERN = /([^\s=/"'<>]+)(\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+)))?/g;
/** `<script …>…</script>` blocks and `<!-- … -->` comments — removed before tag scanning. */
const STRIPPED_BLOCKS_PATTERN = /<script\b[^>]*>[\s\S]*?<\/script\s*>|<!--[\s\S]*?-->/gi;
const STYLE_BLOCK_PATTERN = /<style\b[^>]*>([\s\S]*?)<\/style\s*>/gi;
/** CSS `url(...)` — bare, single- or double-quoted. */
const CSS_URL_PATTERN = /url\(\s*(?:"([^"]*)"|'([^']*)'|([^\s"')]+))\s*\)/gi;
const SCHEME_PATTERN = /^[a-zA-Z][a-zA-Z0-9+.-]*:/;
/**
 * Attributes whose value is a single URL. `<form action>` is excluded on purpose: the template's
 * forms post to Worker routes that exist only at runtime.
 */
const URL_ATTRIBUTES = new Set(["href", "src", "poster", "data"]);

/** `(name, value)` pairs from one tag's attribute string; names lowercased, value `null` for a bare boolean attribute. */
export function parseAttributes(source: string): Array<[string, string | null]> {
  const out: Array<[string, string | null]> = [];
  for (const m of source.matchAll(ATTRIBUTE_PATTERN)) {
    const name = m[1].toLowerCase();
    const value = m[3] ?? m[4] ?? m[5] ?? (m[2] === undefined ? null : "");
    out.push([name, value]);
  }
  return out;
}

/** Every `url(...)` reference in `css`, in order. */
export function extractCssReferences(css: string): string[] {
  const out: string[] = [];
  for (const m of css.matchAll(CSS_URL_PATTERN)) out.push(m[1] ?? m[2] ?? m[3] ?? "");
  return out;
}

/**
 * Every reference string in `html`, in document order, duplicates included: `href`, `src`,
 * `poster`, `<object data>`, each candidate URL in `srcset`, plus `url()` inside `<style>` blocks
 * and `style=""` attributes.
 */
export function extractReferences(html: string): string[] {
  const stripped = html.replace(STRIPPED_BLOCKS_PATTERN, " ");
  const references: string[] = [];
  for (const tag of stripped.matchAll(TAG_PATTERN)) {
    const tagName = tag[1].toLowerCase();
    for (const [name, value] of parseAttributes(tag[2])) {
      if (value === null) continue;
      if (URL_ATTRIBUTES.has(name)) {
        // `<object data>` is a URL; `data` on anything else isn't.
        if (name === "data" && tagName !== "object") continue;
        references.push(value);
      } else if (name === "srcset") {
        for (const candidate of value.split(",")) {
          const url = candidate.trim().split(/\s+/)[0];
          if (url) references.push(url);
        }
      } else if (name === "style") {
        references.push(...extractCssReferences(value));
      }
    }
  }
  for (const block of stripped.matchAll(STYLE_BLOCK_PATTERN)) {
    references.push(...extractCssReferences(block[1]));
  }
  return references;
}

/** `id="…"` on any element plus `name="…"` on `<a>` — everything a `#fragment` can target. */
export function anchorIds(html: string): Set<string> {
  const stripped = html.replace(STRIPPED_BLOCKS_PATTERN, " ");
  const ids = new Set<string>();
  for (const tag of stripped.matchAll(TAG_PATTERN)) {
    const tagName = tag[1].toLowerCase();
    for (const [name, value] of parseAttributes(tag[2])) {
      if (!value) continue;
      if (name === "id" || (name === "name" && tagName === "a")) ids.add(value);
    }
  }
  return ids;
}

// ---------------------------------------------------------------------------
// Classification and resolution
// ---------------------------------------------------------------------------

export type Classification =
  /** Non-HTTP scheme, empty, or otherwise not something the output can answer for. */
  | { kind: "skip" }
  /** An `http(s)` reference to a host that isn't this site. */
  | { kind: "external" }
  /** A path to look up (empty for a fragment-only reference) plus the fragment. Query strings are dropped. */
  | { kind: "internal"; path: string; fragment: string | null };

export function classify(rawReference: string, siteHosts: Set<string>): Classification {
  const reference = rawReference.trim();
  if (reference === "") return { kind: "skip" };

  // Protocol-relative `//host/path` behaves like an absolute URL.
  let remainder = reference.startsWith("//") ? `https:${reference}` : reference;
  const scheme = SCHEME_PATTERN.exec(remainder);
  if (scheme) {
    const name = scheme[0].slice(0, -1).toLowerCase();
    if (name !== "http" && name !== "https") return { kind: "skip" };
    const afterScheme = remainder.slice(scheme[0].length);
    if (!afterScheme.startsWith("//")) return { kind: "skip" };
    const authorityAndRest = afterScheme.slice(2);
    const end = authorityAndRest.search(/[/?#]/);
    const authority = (end === -1 ? authorityAndRest : authorityAndRest.slice(0, end)).toLowerCase();
    let host = authority.includes("@") ? authority.slice(authority.lastIndexOf("@") + 1) : authority;
    if (host.includes(":")) host = host.slice(0, host.lastIndexOf(":"));
    if (!siteHosts.has(host)) return { kind: "external" };
    const rest = end === -1 ? "" : authorityAndRest.slice(end);
    remainder = rest === "" ? "/" : rest;
  }

  let fragment: string | null = null;
  const hash = remainder.indexOf("#");
  if (hash !== -1) {
    fragment = remainder.slice(hash + 1);
    remainder = remainder.slice(0, hash);
  }
  const query = remainder.indexOf("?");
  if (query !== -1) remainder = remainder.slice(0, query);
  return { kind: "internal", path: remainder, fragment };
}

/**
 * Resolves `path` (possibly relative, possibly empty) against `base`, a site-absolute URL path
 * that ends in `/` for directory-style pages. Collapses `.`/`..` the way a browser would; `..`
 * above the root stays at the root.
 */
export function resolvePath(path: string, base: string): string {
  if (path === "") return base;
  let combined: string;
  if (path.startsWith("/")) {
    combined = path;
  } else {
    const directory = base.endsWith("/") ? base : base.slice(0, base.lastIndexOf("/") + 1);
    combined = directory + path;
  }
  const segments = combined.split("/");
  const stack: string[] = [];
  segments.forEach((segment, index) => {
    if (segment === ".") return;
    if (segment === "..") {
      stack.pop();
      return;
    }
    if (segment === "" && index !== segments.length - 1) return;
    stack.push(segment);
  });
  const joined = `/${stack.join("/")}`;
  const wantsSlash = combined.endsWith("/") || combined.endsWith("/.") || combined.endsWith("/..");
  return wantsSlash && !joined.endsWith("/") ? `${joined}/` : joined;
}

/** `blog/x/index.html` → `/blog/x/`; `about.html` → `/about`; `_astro/a.css` → `/_astro/a.css`. */
export function routeForDistPath(relativePath: string): string {
  const urlPath = urlPathForDistPath(relativePath);
  return urlPath.endsWith(".html") ? urlPath.slice(0, -".html".length) : urlPath;
}

/** The URL path a browser resolves relative references against: `blog/x/index.html` → `/blog/x/`; `about.html` → `/about.html`. */
export function urlPathForDistPath(relativePath: string): string {
  if (relativePath === "index.html") return "/";
  if (relativePath.endsWith("/index.html")) return `/${relativePath.slice(0, -"index.html".length)}`;
  return `/${relativePath}`;
}

/** Text fragments (`#:~:text=`) and the browser-special `#top` aren't element ids. */
function isCheckableFragment(fragment: string): boolean {
  return !(fragment.startsWith(":~:") || fragment === "top");
}

// ---------------------------------------------------------------------------
// Walking and scanning
// ---------------------------------------------------------------------------

/** Every regular file under `root`, as `/`-joined paths relative to it. Hidden entries included: `dist/.well-known/` is real, linkable output. */
export function walkFiles(root: string): string[] {
  const out: string[] = [];
  const visit = (dir: string, prefix: string) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const rel = prefix ? `${prefix}/${entry.name}` : entry.name;
      if (entry.isDirectory()) visit(join(dir, entry.name), rel);
      else if (entry.isFile()) out.push(rel);
    }
  };
  if (existsSync(root)) visit(root, "");
  return out;
}

export function scan(distDir: string, options: ScanOptions = {}): BrokenLinkReport {
  const siteHosts = options.siteHosts ?? new Set<string>();
  const files = walkFiles(distDir);
  const htmlPaths = files.filter((f) => f.endsWith(".html")).sort();
  if (htmlPaths.length === 0) throw new NoBuiltPagesError(distDir);
  const cssPaths = files.filter((f) => f.endsWith(".css")).sort();
  const index = new OutputIndex(files, options.redirectSources ?? [], options.runtimeRoutes ?? []);

  const problems = new Map<string, BrokenLinkProblem>();
  const anchorCache = new Map<string, Set<string>>();
  let referencesChecked = 0;
  let externalSkipped = 0;

  for (const relativePath of [...htmlPaths, ...cssPaths]) {
    const contents = readFileSync(join(distDir, relativePath), "utf-8");
    const isHtml = relativePath.endsWith(".html");
    const page = routeForDistPath(relativePath);
    const base = urlPathForDistPath(relativePath);
    const references = isHtml ? extractReferences(contents) : extractCssReferences(contents);
    const seen = new Set<string>();

    for (const reference of references) {
      const classification = classify(reference, siteHosts);
      if (classification.kind === "skip") continue;
      if (classification.kind === "external") {
        externalSkipped += 1;
        continue;
      }
      const { path, fragment } = classification;
      const resolved = resolvePath(path, base);
      const key = fragment !== null ? `${resolved}#${fragment}` : resolved;
      if (seen.has(key)) continue;
      seen.add(key);
      referencesChecked += 1;

      // Fragment-only reference (`#team`): the target is this very page.
      const targetPath = path === "" ? base : resolved;
      const served = index.servedFile(targetPath);
      if (served === null) {
        if (!index.isRedirected(targetPath) && !index.isRuntimeServed(targetPath)) {
          addProblem(problems, { kind: "missing-target", page, reference, resolvedPath: resolved });
        }
        continue;
      }
      if (fragment === null || fragment === "" || !isCheckableFragment(fragment) || !served.endsWith(".html")) continue;
      let anchors = anchorCache.get(served);
      if (anchors === undefined) {
        anchors = anchorIds(readFileSync(join(distDir, served), "utf-8"));
        anchorCache.set(served, anchors);
      }
      if (!anchors.has(safeDecode(fragment))) {
        addProblem(problems, { kind: "missing-anchor", page, reference, resolvedPath: key });
      }
    }
  }

  const sorted = [...problems.values()].sort(
    (a, b) => compare(a.page, b.page) || compare(a.resolvedPath, b.resolvedPath) || compare(a.reference, b.reference),
  );
  return {
    version: 1,
    pagesScanned: htmlPaths.length,
    referencesChecked,
    externalReferencesSkipped: externalSkipped,
    problems: sorted,
  };
}

function addProblem(problems: Map<string, BrokenLinkProblem>, problem: BrokenLinkProblem): void {
  const key = `${problem.kind}\n${problem.page}\n${problem.resolvedPath}`;
  if (!problems.has(key)) problems.set(key, problem);
}

function compare(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

// ---------------------------------------------------------------------------
// Site inputs — what counts as "served" beyond the files in dist/
// ---------------------------------------------------------------------------

/**
 * The hostnames that count as this site for absolute self-links: `DOMAIN` plus its `www.`
 * counterpart (either way round), lowercased. Empty when the site has no domain yet — then every
 * absolute `http(s)` link is external, which is right.
 */
export function siteHostsFromDomain(domain: string | undefined): Set<string> {
  let host = (domain ?? "").trim().toLowerCase();
  const schemeEnd = host.indexOf("://");
  if (schemeEnd !== -1) host = host.slice(schemeEnd + 3);
  const slash = host.indexOf("/");
  if (slash !== -1) host = host.slice(0, slash);
  if (host === "") return new Set();
  return new Set([host, host.startsWith("www.") ? host.slice(4) : `www.${host}`]);
}

/**
 * Source paths from a Cloudflare `_redirects` file (`source destination [code]` per line, `#`
 * comments). Blank and malformed lines are ignored — this only widens what counts as "covered",
 * so a bad line can't produce a false positive.
 */
export function redirectSourcesFromCloudflareFile(contents: string): Set<string> {
  const sources = new Set<string>();
  for (const line of contents.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (trimmed === "" || trimmed.startsWith("#")) continue;
    const fields = trimmed.split(/\s+/);
    if (fields.length >= 2 && fields[0].startsWith("/")) sources.add(fields[0]);
  }
  return sources;
}

/**
 * `path: "…"` / `match: "exact" | "prefix"` pairs from one object literal of the Worker's `ROUTES`
 * table. `[^{}]*?` keeps a `path` from pairing with the *next* entry's `match` when its own is
 * missing, and lets comment lines sit between the two fields as they do in the template.
 */
const WORKER_ROUTE_PATTERN = /\bpath:\s*["']([^"']+)["'][^{}]*?\bmatch:\s*["'](exact|prefix)["']/g;

/**
 * Extracts the runtime route table from `worker/worker.ts` source. A regex over the data-shaped
 * `ROUTES` literal rather than importing the module — the Worker entry pulls in `cloudflare:`
 * bindings that don't load under plain Node. `broken-links.test.ts` pins the pairing against the
 * real file, so a template change that breaks it fails CI instead of silently un-covering the
 * dynamic layer. Only site-absolute paths are kept.
 */
export function runtimeRoutesFromWorkerSource(source: string): RuntimeRoute[] {
  const routes: RuntimeRoute[] = [];
  const seen = new Set<string>();
  for (const m of source.matchAll(WORKER_ROUTE_PATTERN)) {
    const path = m[1];
    if (!path.startsWith("/")) continue;
    const route = { path, prefix: m[2] === "prefix" };
    const key = `${route.prefix ? "prefix" : "exact"} ${path}`;
    if (seen.has(key)) continue;
    seen.add(key);
    routes.push(route);
  }
  return routes;
}

/** Reads `.site-config`, `redirects.json`, `dist/_redirects`, and `worker/worker.ts` from a site root. */
export function collectSiteInputs(siteRoot: string, distDir: string): ScanOptions {
  const redirectSources = new Set<string>();
  for (const entry of readRedirects(siteRoot)) redirectSources.add(entry.source);
  const cloudflareRedirects = join(distDir, "_redirects");
  if (existsSync(cloudflareRedirects)) {
    for (const source of redirectSourcesFromCloudflareFile(readFileSync(cloudflareRedirects, "utf-8"))) {
      redirectSources.add(source);
    }
  }
  const workerSource = join(siteRoot, "worker", "worker.ts");
  const runtimeRoutes = existsSync(workerSource) ? runtimeRoutesFromWorkerSource(readFileSync(workerSource, "utf-8")) : [];
  return {
    siteHosts: siteHostsFromDomain(readConfig("DOMAIN", join(siteRoot, ".site-config"))),
    redirectSources,
    runtimeRoutes,
  };
}

// ---------------------------------------------------------------------------
// Reporting
// ---------------------------------------------------------------------------

export function formatReport(report: BrokenLinkReport): string {
  const lines = [
    `Broken-link check: ${report.pagesScanned} page(s), ${report.referencesChecked} internal reference(s), ${report.problems.length} problem(s)` +
      (report.externalReferencesSkipped > 0 ? `; ${report.externalReferencesSkipped} off-site link(s) not checked` : ""),
  ];
  for (const p of report.problems) {
    const what = p.kind === "missing-target" ? "missing target" : "missing anchor";
    lines.push(`  ✗ ${p.page}: ${what} ${p.resolvedPath} (written as "${p.reference}")`);
  }
  if (report.problems.length === 0) lines.push("  ✓ every internal reference resolves");
  return lines.join("\n");
}

export function exitCodeFor(report: BrokenLinkReport): number {
  return report.problems.length === 0 ? 0 : 1;
}

// ---------------------------------------------------------------------------
// Script entry — executed when run directly (not when imported by tests)
// ---------------------------------------------------------------------------

if (process.argv[1]?.endsWith("broken-links.ts")) {
  const wantJson = process.argv.slice(2).includes("--json");
  const siteRoot = process.cwd();
  const distDir = join(siteRoot, "dist");
  try {
    const report = scan(distDir, collectSiteInputs(siteRoot, distDir));
    console.log(wantJson ? JSON.stringify(report, null, 2) : formatReport(report));
    process.exit(exitCodeFor(report));
  } catch (err) {
    if (err instanceof NoBuiltPagesError) {
      console.error(`Broken-link check couldn't run: ${err.message}`);
      process.exit(2);
    }
    console.error("Broken-link check failed:", err);
    process.exit(2);
  }
}
