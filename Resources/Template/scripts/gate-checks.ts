/**
 * The pre-deploy gate's per-document checks (#2055 slice 1): pure `(content, file) => Issue[]`
 * functions with no imports at all, so the exact same code runs in Node (`pre-deploy-check.ts`'s
 * deploy scan) and, for EmDash sites, in the Workers runtime (the `anglesite-gate` publish plugin
 * and the SSR render backstop — docs/specs/2026-09-28-external-cms-content-source-decision.md,
 * § Gate). Everything that walks `dist/`, reads `.site-config`, or otherwise touches the
 * filesystem stays in `pre-deploy-check.ts`.
 *
 * App-owned like the rest of `scripts/`, so owner decision D5's hash pin covers it
 * (`TemplateScriptsManifest` picks it up with no manifest change). Keep it import-free:
 * `gate-checks.test.ts` fails the moment it gains one.
 */

export interface Issue {
  severity: "error" | "warning";
  category: string;
  message: string;
  file?: string;
  /// The scan's suggested fix, when it has one — mirrors `PreDeployCheck.ScanFailure`/
  /// `ScanWarning`'s optional `remediation` field on the Swift side (#742/#1173). No existing
  /// check populates this yet; `checkAnglesiteConfig` is the first producer.
  remediation?: string;
}

// The restricted-posting epic's audience tier (#963 §2.2): a `visibility: contacts` value on
// Micropub's `visibility` mf2 property. Matches whether the value shows up YAML-style (Source/
// frontmatter), JSON-string-style, or as a JSON mf2 property array (`"visibility":["contacts"]`,
// the exact shape `MicropubPost.entry` stamps and `dist/` could echo back if a post-family JSON
// export ever serialized raw properties).
const RESTRICTED_VISIBILITY_PATTERN = /"?visibility"?\s*:\s*(\[\s*)?"?contacts"?/i;

const EMAIL_LOCAL_CHAR = /[a-zA-Z0-9._%+-]/;
const EMAIL_DOMAIN_AT = /[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/y;

/**
 * Whether `content` contains a match for `/[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/`,
 * decided in linear time. The regex itself is quadratic on a long run of address characters with
 * no valid address in it (a pasted base64 blob, a long slug): every start position rescans the run
 * looking for an `@`. A match exists exactly when some `@` has at least one local-part character
 * right before it and the domain part matching right after it, so this checks each `@` once.
 * Domain runs end at the next `@`, so the per-`@` checks never overlap.
 */
function containsEmail(content: string): boolean {
  for (let at = content.indexOf("@"); at !== -1; at = content.indexOf("@", at + 1)) {
    if (at === 0 || !EMAIL_LOCAL_CHAR.test(content[at - 1])) continue;
    EMAIL_DOMAIN_AT.lastIndex = at + 1;
    if (EMAIL_DOMAIN_AT.test(content)) return true;
  }
  return false;
}

const PII_PATTERNS: Array<{ name: string; matches: (content: string) => boolean }> = [
  { name: "email", matches: containsEmail },
  { name: "phone", matches: (content) => /\b\d{3}[-.]?\d{3}[-.]?\d{4}\b/.test(content) },
  { name: "SSN", matches: (content) => /\b\d{3}-\d{2}-\d{4}\b/.test(content) },
];

// Directories whose every byte is emitted by a dependency, never authored by the site owner.
// Only the email pattern is relaxed for these, and only because shipped library bundles carry
// their contributors' addresses as attribution (Pagefind's `thanks_to` translator credits,
// #974) — a match there says nothing about the owner's own data, which is what this scan exists
// to catch. Every other check still runs on these files: phone/SSN, secrets and tokens, blocked
// trackers, mixed content, and admin routes.
//
// Anchored at the start of the relative path, so an owner-authored page that merely has
// "pagefind" somewhere in its route is scanned normally.
const VENDORED_EMAIL_EXEMPT = [/^dist\/pagefind\//];

const SECRET_PATTERNS = [
  { name: "API key", pattern: /(?:api[_-]?key|apikey)\s*[:=]\s*["']?[a-zA-Z0-9_-]{20,}/gi },
  { name: "AWS key", pattern: /AKIA[0-9A-Z]{16}/g },
  { name: "private key", pattern: /-----BEGIN (?:RSA |EC )?PRIVATE KEY-----/g },
];

// Trackers with no first-party integration in this catalog. Google Analytics/Tag
// Manager are deliberately absent — the `tracking` integration (ga4 provider) makes
// them a supported, owner-opted-in choice, the same way Plausible/Fathom always were.
const BLOCKED_SCRIPTS: Array<{ pattern: RegExp; matches: (content: string) => boolean }> = [
  { pattern: /facebook\.net.*fbevents/i, matches: containsFacebookPixel },
  { pattern: /hotjar\.com/i, matches: (content) => /hotjar\.com/i.test(content) },
];

const BLOCKED_ROUTES = [/\/keystatic(?:\/|$)/i, /\/api\/keystatic/i];

/**
 * Whether `content` matches `/facebook\.net.*fbevents/i`, decided in linear time. The regex is
 * quadratic when `facebook.net` recurs with no `fbevents` after it on the same line: each
 * occurrence scans to the end of the line. `.` stops at line terminators, so a match is a line
 * holding `facebook.net` with `fbevents` somewhere after it; the first `facebook.net` on a line is
 * the best candidate, and the next `fbevents` is looked up at most once per position.
 */
function containsFacebookPixel(content: string): boolean {
  const host = /facebook\.net/gi;
  const pixel = /fbevents/gi;
  const lineBreak = /[\n\r\u2028\u2029]/g;
  // Where the next `fbevents` starts; -1 until the first lookup. Only looked up again once a
  // `facebook.net` ends past it, so each stretch of the input is searched for `fbevents` once.
  let pixelAt = -1;
  for (let h = host.exec(content); h !== null; h = host.exec(content)) {
    const afterHost = h.index + h[0].length;
    if (pixelAt < afterHost) {
      pixel.lastIndex = afterHost;
      const found = pixel.exec(content);
      if (found === null) return false; // no `fbevents` after here, so none after any later host
      pixelAt = found.index;
    }
    lineBreak.lastIndex = h.index;
    const lineEnd = lineBreak.exec(content)?.index ?? content.length;
    if (pixelAt < lineEnd) return true;
    host.lastIndex = lineEnd;
  }
  return false;
}

/**
 * The tags `/<name\b[^>]*>/gi` would match — each opener through the first `>` after it — found
 * in linear time. `opener` is a global regex for just the opening (`/<(script|link)\b/gi`); its
 * first capture group, if any, is yielded as `name`. The `[^>]*>` form is quadratic on openers
 * with no `>` after them (every later opener rescans to the end); once no `>` follows one opener,
 * none follows any later one, so the scan stops there.
 */
function* tagsOpenedBy(content: string, opener: RegExp): Generator<{ tag: string; name: string }> {
  opener.lastIndex = 0;
  for (let m = opener.exec(content); m !== null; m = opener.exec(content)) {
    const end = content.indexOf(">", m.index);
    if (end === -1) return;
    yield { tag: content.slice(m.index, end + 1), name: m[1] ?? "" };
    opener.lastIndex = end + 1;
  }
}

/**
 * Media hosts belonging to the platforms the embed snapshotter supports (#682). A reference to
 * one of these in built output means an embed is hotlinking rather than serving its snapshotted
 * copy, which leaks every visitor's IP and Referer to the platform — the tracking ADR-0008
 * exists to prevent. Anchor hrefs are excluded: a permalink back to the original post is the
 * point of a citation.
 *
 * Invariant: no entry may be a domain suffix of another entry here (e.g. don't add back
 * "scontent.cdninstagram.com" alongside "cdninstagram.com"). Matching is substring-based, and a
 * generic host already substring-matches every subdomain of it — a redundant, more-specific pair
 * doesn't catch anything extra, and previously caused a single hotlinked URL to be double-reported
 * once per matching entry (see the checkEmbedMedia doc comment for how that's guarded against now).
 *
 * Invariant: every entry must stay lower-case — checkEmbedMedia lower-cases the matched URL
 * value before comparing against this list (hostnames are case-insensitive by DNS definition,
 * but JS string `includes` is not), so an upper-case entry here would never match.
 */
const EMBED_MEDIA_HOSTS = [
  "pbs.twimg.com",
  "video.twimg.com",
  "abs.twimg.com",
  "cdninstagram.com",
  "cdn.bsky.app",
  "i.ytimg.com",
  "img.youtube.com",
  /** Mastodon media is per-instance; files.* covers the common CDN shape. */
  "files.mastodon.social",
];

/** One `exposed-token` error per secret pattern that matches `content`. Shared by the `dist/`
 * walk and the `--source` sweep so both scan for exactly the same shapes. */
export function checkSecrets(content: string, file: string): Issue[] {
  const issues: Issue[] = [];
  for (const { name, pattern } of SECRET_PATTERNS) {
    pattern.lastIndex = 0;
    if (pattern.test(content)) {
      issues.push({ severity: "error", category: "exposed-token", message: `Possible ${name} exposed`, file });
    }
  }
  return issues;
}

/** One `third-party-script` warning per `BLOCKED_SCRIPTS` pattern that matches built HTML. */
export function checkBlockedScripts(content: string, file: string): Issue[] {
  const issues: Issue[] = [];
  for (const { pattern, matches } of BLOCKED_SCRIPTS) {
    if (matches(content)) {
      issues.push({
        severity: "warning",
        category: "third-party-script",
        message: `Third-party tracking script detected: ${pattern.source}`,
        file,
      });
    }
  }
  return issues;
}

/** One `keystatic-route` error per `BLOCKED_ROUTES` pattern that matches built HTML: the
 * Keystatic admin UI is dev-only and must never reach production output. */
export function checkBlockedRoutes(content: string, file: string): Issue[] {
  const issues: Issue[] = [];
  for (const pattern of BLOCKED_ROUTES) {
    if (pattern.test(content)) {
      issues.push({
        severity: "error",
        category: "keystatic-route",
        message: "Keystatic admin route found in production output",
        file,
      });
    }
  }
  return issues;
}

/**
 * Scan built content for likely PII (email, phone, SSN). An email that appears only as a
 * `mailto:` link target is published intent — e.g. a contact-form fallback the site owner
 * deliberately configured — not accidental exposure, so it's stripped before the email check.
 * Files under a `VENDORED_EMAIL_EXEMPT` directory skip the email check entirely, for the same
 * reason at directory scale. Phone/SSN patterns are unaffected by either. One issue per pattern
 * per file, matching the prior inline scan's behavior.
 */
export function checkPII(content: string, file: string): Issue[] {
  const issues: Issue[] = [];
  const withoutMailtoLinks = content.replace(
    /mailto:[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/g,
    "",
  );
  const normalized = file.replace(/\\/g, "/");
  const emailExempt = VENDORED_EMAIL_EXEMPT.some((dir) => dir.test(normalized));
  for (const { name, matches } of PII_PATTERNS) {
    if (name === "email" && emailExempt) continue;
    const haystack = name === "email" ? withoutMailtoLinks : content;
    if (matches(haystack)) {
      issues.push({
        severity: "error",
        category: `pii-${name.toLowerCase()}`,
        message: `Possible ${name} found`,
        file,
      });
    }
  }
  return issues;
}

/**
 * Hotlinked platform media in built output. Scans the resource-loading contexts a browser
 * actually fetches from — `src`/`srcset` attributes (double-quoted, single-quoted, or unquoted,
 * so hand-authored or pasted embed HTML is caught too, not just Astro's always-quoted compiled
 * output; `\bsrc` also matches `data-src`, which is desirable — a lazy-loaded image still
 * describes a real fetch) and CSS `url(...)` — for a value naming one of the
 * `EMBED_MEDIA_HOSTS`. `href` is never matched, so a citation permalink to the original post
 * passes even when it points at a listed host.
 *
 * Matching is per-occurrence, not per-host: each `src`/`srcset`/`url()` match is checked and
 * reported independently, so two distinct hotlinks in the same file are two issues even when
 * both happen to match the same generic host entry (e.g. two different `*.cdninstagram.com`
 * subdomains) — a file-wide "did this host appear anywhere" pass would only catch one of them.
 */
export function checkEmbedMedia(content: string, file: string): Issue[] {
  const issues: Issue[] = [];
  // The unquoted `url(...)` value excludes `(` as well as `)`: CSS doesn't allow an unescaped
  // paren there, and without the exclusion a failed match could run on into the next `url(`,
  // so every later start rescanned to the end of the input — quadratic time on writer-supplied
  // drafts (`url(` + `url(!` × n; CodeQL js/polynomial-redos). Bounded, each attempt stops at
  // the next paren and the scan stays linear.
  const urlContextPattern =
    /\b(?:src|srcset)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))|url\(\s*(?:"([^"]*)"|'([^']*)'|([^()\s]+))\s*\)/gi;
  let m: RegExpExecArray | null;
  while ((m = urlContextPattern.exec(content)) !== null) {
    const value = m[1] ?? m[2] ?? m[3] ?? m[4] ?? m[5] ?? m[6] ?? "";
    const host = EMBED_MEDIA_HOSTS.find((h) => value.toLowerCase().includes(h));
    if (host) {
      issues.push({
        severity: "error",
        category: "embed-media-hotlink",
        message: `Embed media hotlinked from ${host} — run "npm run embed -- <url>" to snapshot it first-party.`,
        file,
      });
    }
  }
  return issues;
}

/**
 * Insecure (http://) subresource references in built HTML/CSS. Targets resource
 * attributes (`src`) and CSS `url(...)` only — NOT `href` — so anchor links and
 * `xmlns="http://..."` declarations do not false-positive. Advisory: slice A's
 * `upgrade-insecure-requests` auto-upgrades these at runtime. One issue per file.
 */
export function checkMixedContent(content: string, file: string): Issue[] {
  const patterns = [/\bsrc\s*=\s*["']http:\/\//i, /url\(\s*["']?http:\/\//i];
  for (const pattern of patterns) {
    if (pattern.test(content)) {
      return [{ severity: "warning", category: "mixed-content", message: "Mixed content: insecure http:// resource reference", file }];
    }
  }
  return [];
}

/**
 * External (absolute or protocol-relative) <script> and stylesheet <link> tags
 * with a subresource-integrity problem: either missing `integrity`, or carrying
 * `integrity` without the `crossorigin` attribute it requires — the browser
 * blocks the response on CORS before integrity is evaluated, so the resource
 * silently fails to load. Heuristic tag-level regex match; multi-line tag
 * attributes are not matched. One issue per offending tag.
 *
 * No allowlist: this intentionally also warns on auto-updating, unversioned CDN
 * scripts (e.g. the Cloudflare Web Analytics beacon, legacy Google gtag.js) that
 * can't carry a stable `integrity` hash without breaking on the vendor's next
 * content rotation — for those, the warning firing is the expected, disposed
 * outcome (Cloudflare beacon: #1165), not a gap to fix. Advisory only
 * (`severity: "warning"`); doesn't block deploys unless `--strict` is passed.
 */
export function checkSRI(content: string, file: string): Issue[] {
  const issues: Issue[] = [];
  for (const { tag, name } of tagsOpenedBy(content, /<(script|link)\b/gi)) {
    const isScript = name.toLowerCase() === "script";
    const urlAttr = isScript
      ? /\bsrc\s*=\s*["'](?:https?:)?\/\//i
      : /\bhref\s*=\s*["'](?:https?:)?\/\//i;
    if (!urlAttr.test(tag)) continue;
    if (!isScript && !/\brel\s*=\s*["'][^"']*stylesheet/i.test(tag)) continue;
    const kind = isScript ? "script" : "stylesheet";
    if (!/\bintegrity\s*=/i.test(tag)) {
      issues.push({ severity: "warning", category: "sri-missing", message: `External ${kind} without subresource integrity (SRI)`, file });
    } else if (!/\scrossorigin\b/i.test(tag)) {
      issues.push({
        severity: "warning",
        category: "sri-missing",
        message: `External ${kind} has integrity but is missing crossorigin (will fail CORS)`,
        file,
      });
    }
  }
  return issues;
}

/**
 * Anchors that open a new tab (`target="_blank"`) without `rel="noopener"`,
 * which can expose `window.opener`. `rel="noreferrer"` also implies noopener
 * (per the HTML spec and all modern browsers), so either token is accepted.
 * Advisory — modern browsers imply noopener, but explicit is safer. One issue
 * per offending anchor.
 */
export function checkExternalLinkRel(content: string, file: string): Issue[] {
  const issues: Issue[] = [];
  for (const { tag } of tagsOpenedBy(content, /<a\b/gi)) {
    if (!/\btarget\s*=\s*["']_blank["']/i.test(tag)) continue;
    const relMatch = tag.match(/\brel\s*=\s*["']([^"']*)["']/i);
    const rel = relMatch ? relMatch[1].toLowerCase() : "";
    if (!/\bnoopener\b|\bnoreferrer\b/.test(rel)) {
      issues.push({ severity: "warning", category: "external-link-rel", message: 'Link with target="_blank" missing rel="noopener"', file });
    }
  }
  return issues;
}

/**
 * Defense-in-depth backstop for the composer-only restricted-posting design (#963 §2.1, #1569): a
 * `visibility: contacts` post publishes straight into the Worker's D1 store via Micropub and must
 * never be written to `Source/` as content-collection frontmatter. This isn't the enforcement
 * mechanism — the composer never offers to write it there — it's a check that fires if a future
 * regression, sync bug, or manual edit did.
 */
export function checkNoRestrictedContentInSource(relPath: string, content: string): Issue[] {
  if (!RESTRICTED_VISIBILITY_PATTERN.test(content)) return [];
  return [{
    severity: "error",
    category: "restricted-content-in-source",
    message: 'Restricted (visibility: contacts) content found in Source/ — restricted posts must publish via Micropub straight to the Worker, never as Source/ content.',
    file: relPath,
    remediation: "Remove the restricted content from Source/; it belongs in the Worker's D1 post store, not the git-canonical site.",
  }];
}

/**
 * Same backstop as `checkNoRestrictedContentInSource`, for the built `dist/` output: restricted
 * content must never reach the static build, since it's served exclusively through the Worker's
 * IndieAuth read gate (#1568), never the CDN-served static site.
 */
export function checkNoRestrictedContentInDist(relPath: string, content: string): Issue[] {
  if (!RESTRICTED_VISIBILITY_PATTERN.test(content)) return [];
  return [{
    severity: "error",
    category: "restricted-content-in-dist",
    message: 'Restricted (visibility: contacts) content found in the built dist/ output — it must be served only through the Worker\'s read gate, never the static build.',
    file: relPath,
    remediation: "Rebuild after removing the restricted content from Source/, and check for a regression in the composer/Micropub-to-D1 publish path.",
  }];
}

/**
 * What a Content-Security-Policy lets through as inline `<script>` — the part of the policy
 * `checkInlineScripts` needs. Built by `inlineScriptPolicy` from the CSP header value.
 */
export interface InlineScriptPolicy {
  /** `'unsafe-inline'` is in effect: every inline script runs. */
  allowsAll: boolean;
  /** `'sha256-…'` / `'sha384-…'` / `'sha512-…'` source expressions, as `"<alg>-<base64>"`. */
  hashes: ReadonlySet<string>;
  /** `'inline-speculation-rules'` is present: inline `type="speculationrules"` is allowed. */
  allowsSpeculationRules: boolean;
}

/** The policy for a missing CSP: nothing is checked against it, every inline script is allowed. */
const NO_CSP: InlineScriptPolicy = { allowsAll: true, hashes: new Set(), allowsSpeculationRules: true };

/**
 * Reads the directive that governs `<script>` elements out of a CSP header value: `script-src-elem`,
 * else `script-src`, else `default-src` (CSP3 §6.1.1's fallback list). `null` (no CSP) yields a
 * policy that allows everything — `checkHeaders` already reports the missing policy, and the
 * browser enforces nothing without one, so an inline script isn't broken there.
 *
 * `'unsafe-inline'` is ignored by the browser once the same directive has a hash, a nonce or
 * `'strict-dynamic'` (CSP3 §6.7.3.3), so it only counts when none of those is present.
 */
export function inlineScriptPolicy(csp: string | null): InlineScriptPolicy {
  if (csp === null) return NO_CSP;
  const sources = effectiveSources(cspDirectives(csp), "script-src-elem");
  // No directive governs scripts at all: CSP places no restriction on them.
  if (sources === undefined) return NO_CSP;
  const { allowsAll, hashes } = sourceList(sources);
  return {
    allowsAll,
    hashes,
    allowsSpeculationRules: sources.some((s) => s.toLowerCase() === "'inline-speculation-rules'"),
  };
}

/** A CSP header value's directives by lower-cased name, each with its source list (the first
 * occurrence of a directive wins, as in CSP3 §2.2.1's parser). */
function cspDirectives(csp: string): Map<string, string[]> {
  const directives = new Map<string, string[]>();
  for (const part of csp.split(";")) {
    const [name, ...values] = part.trim().split(/\s+/);
    if (name && !directives.has(name.toLowerCase())) directives.set(name.toLowerCase(), values);
  }
  return directives;
}

/** The source list CSP3 consults for an inline check (its effective-directive fallback): `specific` (`script-src-elem` or
 * `script-src-attr`), else `script-src`, else `default-src`; `undefined` when none is present. */
function effectiveSources(directives: Map<string, string[]>, specific: string): string[] | undefined {
  return directives.get(specific) ?? directives.get("script-src") ?? directives.get("default-src");
}

/**
 * The inline-relevant parts of one source list: its hash sources, whether it has
 * `'unsafe-hashes'`, and whether it allows all inline behavior. `'unsafe-inline'` is ignored by
 * the browser once the same list has a hash, a nonce or `'strict-dynamic'` (CSP3 §6.7.3.3), so it
 * only counts when none of those is present.
 */
function sourceList(sources: string[]): { allowsAll: boolean; hashes: Set<string>; unsafeHashes: boolean } {
  const lower = sources.map((s) => s.toLowerCase());
  const hashes = new Set<string>();
  for (const source of sources) {
    const m = /^'(sha(?:256|384|512))-([A-Za-z0-9+/_-]+={0,2})'$/i.exec(source);
    if (m) hashes.add(`${m[1].toLowerCase()}-${m[2]}`);
  }
  const overridesUnsafeInline =
    hashes.size > 0 || lower.some((s) => s.startsWith("'nonce-")) || lower.includes("'strict-dynamic'");
  return {
    allowsAll: lower.includes("'unsafe-inline'") && !overridesUnsafeInline,
    hashes,
    unsafeHashes: lower.includes("'unsafe-hashes'"),
  };
}

/** `type` values the browser runs as script (HTML §4.12.1 — a JavaScript MIME type essence, or
 * `module`) or treats as inline script for CSP (`importmap`, `speculationrules`). The whole
 * trimmed value must match, so any other type — JSON-LD, a template, or a MIME type with
 * parameters such as `text/javascript; charset=utf-8` — is a data block, which the browser never
 * runs and CSP never checks. */
const JS_MIME_ESSENCES = new Set([
  "application/ecmascript", "application/javascript", "application/x-ecmascript",
  "application/x-javascript", "text/ecmascript", "text/javascript", "text/javascript1.0",
  "text/javascript1.1", "text/javascript1.2", "text/javascript1.3", "text/javascript1.4",
  "text/javascript1.5", "text/jscript", "text/livescript", "text/x-ecmascript", "text/x-javascript",
]);

type ScriptKind = "script" | "speculationrules" | "data";

/**
 * The attributes of an opening tag, by lower-cased name (first occurrence wins, as in the HTML
 * tokenizer), with quoted values unwrapped. Reads names and values in one left-to-right pass, so
 * an `src=` inside another attribute's quoted value is never mistaken for an `src` attribute.
 */
function tagAttributes(openTag: string): Map<string, string> {
  const attributes = new Map<string, string>();
  const attribute = /([^\s"'>\/=]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]*)))?/g;
  // Skip the `<script` tag name itself.
  attribute.lastIndex = openTag.search(/[\s/>]/);
  for (let m = attribute.exec(openTag); m !== null; m = attribute.exec(openTag)) {
    const name = m[1].toLowerCase();
    if (!attributes.has(name)) attributes.set(name, m[2] ?? m[3] ?? m[4] ?? "");
  }
  return attributes;
}

/**
 * Per HTML's "prepare the script element" (§4.12.1), the whole trimmed `type` value has to be a
 * JavaScript MIME type essence match (or `module`, `importmap`, `speculationrules`); anything
 * else, parameters included (`text/javascript; charset=utf-8`), is a data block the browser never
 * runs. With no `type`, a legacy `language` attribute that isn't a JavaScript language makes it a
 * data block too.
 */
function scriptKind(attributes: Map<string, string>): ScriptKind {
  const typeValue = attributes.get("type");
  if (typeValue === undefined) {
    const language = attributes.get("language");
    if (language === undefined || language === "") return "script";
    return /^(?:java|ecma|j|live)script(?:1\.[0-5])?$/i.test(language.trim()) ? "script" : "data";
  }
  const type = typeValue.trim().toLowerCase();
  if (type === "" || type === "module" || type === "importmap") return "script";
  if (type === "speculationrules") return "speculationrules";
  return JS_MIME_ESSENCES.has(type) ? "script" : "data";
}

/**
 * Index of the `>` that ends the tag opened at `start`, skipping any `>` inside a quoted attribute
 * value, or -1 when the tag never ends. An unterminated quote runs to the end of the content, so
 * the caller stops scanning there and the overall scan stays linear.
 */
function tagEnd(content: string, start: number): number {
  let quote: string | null = null;
  for (let i = start; i < content.length; i++) {
    const c = content[i];
    if (quote !== null) {
      if (c === quote) quote = null;
    } else if (c === '"' || c === "'") {
      // Quotes only open an attribute value right after `=` (optionally spaced); elsewhere they
      // are just characters in the tag, as the tokenizer treats them.
      if (/=\s*$/.test(content.slice(Math.max(start, i - 16), i))) quote = c;
    } else if (c === ">") {
      return i;
    }
  }
  return -1;
}

/**
 * Inline `<script>` bodies in built HTML that the site's own CSP would block (#2228). The
 * template's policy is `script-src 'self'` with no `'unsafe-inline'`, so all of a site's
 * JavaScript has to ship as files (`public/scripts/*.js`, or Astro's bundled `<script>`s). An
 * inline body that reaches `dist/` some other way — an integration, an imported page, an `is:inline`
 * in a component — would deploy and then silently not run in visitors' browsers (#1527, #1528).
 *
 * Skips scripts with a `src` (the body is ignored), data blocks (JSON-LD and other non-script
 * types), empty bodies, commented-out scripts, and anything `policy` allows. A script is allowed
 * by hash when `hash` is given and its digest of the body text (newlines normalized to LF, as the
 * browser does) is in `policy.hashes`; `hash` is injected so this
 * module stays import-free (pass Node's `createHash`, or Web Crypto's result, from the caller).
 * Nonces are not honored: a nonce baked into static HTML is the same for every visitor, which
 * defeats it.
 *
 * One error per file, naming how many scripts are affected and quoting the first, so a layout
 * that inlines a script on every page doesn't bury the rest of the report.
 */
export function checkInlineScripts(
  content: string,
  file: string,
  policy: InlineScriptPolicy,
  hash?: (algorithm: "sha256" | "sha384" | "sha512", body: string) => string,
): Issue[] {
  if (policy.allowsAll) return [];
  const blocked: string[] = [];
  // `<script` followed by whitespace, `/` or `>` — not `<script-loader>` or another custom element
  // whose name merely starts with "script".
  const opener = /<script(?=[\s/>])/gi;
  const closer = /<\/script(?=[\s/>])/gi;
  let position = 0;
  // Where the next `<!--` at or after `position` starts (-1: none left). Cached, and searched
  // again only once `position` has moved past it, so a page with many scripts and one late
  // comment isn't rescanned to that comment once per script.
  let nextComment = content.indexOf("<!--");
  while (position < content.length) {
    opener.lastIndex = position;
    const m = opener.exec(content);
    if (m === null) break;
    if (nextComment !== -1 && nextComment < position) nextComment = content.indexOf("<!--", position);
    // An HTML comment that starts before this `<script` hides everything up to its `-->`,
    // including any commented-out script; jump past it and look again.
    if (nextComment !== -1 && nextComment < m.index) {
      const commentEnd = content.indexOf("-->", nextComment + 4);
      if (commentEnd === -1) break;
      position = commentEnd + 3;
      continue;
    }
    const openEnd = tagEnd(content, m.index);
    if (openEnd === -1) break;
    const openTag = content.slice(m.index, openEnd + 1);
    closer.lastIndex = openEnd + 1;
    const close = closer.exec(content);
    const body = content.slice(openEnd + 1, close === null ? content.length : close.index);
    // Resume after this element, so a "<script" inside a script's own string literal isn't
    // mistaken for a second element.
    if (close === null) {
      position = content.length;
    } else {
      const closeEnd = content.indexOf(">", close.index);
      position = closeEnd === -1 ? content.length : closeEnd + 1;
    }

    const attributes = tagAttributes(openTag);
    if (attributes.has("src") || body.trim() === "") continue;
    const kind = scriptKind(attributes);
    if (kind === "data") continue;
    if (kind === "speculationrules" && policy.allowsSpeculationRules) continue;
    if (hash !== undefined && policy.hashes.size > 0) {
      // The tokenizer normalizes CRLF and lone CR to LF before the browser hashes the script
      // text, so a file with Windows line endings must be hashed the same way.
      const hashedText = body.replace(/\r\n?/g, "\n");
      const algorithms = new Set([...policy.hashes].map((h) => h.slice(0, h.indexOf("-")) as "sha256" | "sha384" | "sha512"));
      if ([...algorithms].some((alg) => policy.hashes.has(`${alg}-${hash(alg, hashedText)}`))) continue;
    }
    blocked.push(body);
  }
  if (blocked.length === 0) return [];
  const first = blocked[0].replace(/\s+/g, " ").trim();
  const snippet = first.length > 80 ? `${first.slice(0, 80)}…` : first;
  const count = blocked.length === 1 ? "A script" : `${blocked.length} scripts`;
  return [{
    severity: "error",
    category: "csp-misconfigured",
    message: `${count} on this page won't run once published — the site's security policy only runs scripts loaded from files. First one: "${snippet}"`,
    file,
    remediation:
      "Move the script into its own file (e.g. public/scripts/) and load it with <script src=\"…\">, passing any settings through data-* attributes.",
  }];
}

/**
 * What a Content-Security-Policy lets through as JavaScript written into HTML attributes — the
 * part of the policy `checkInlineHandlers` needs. Built by `inlineAttributePolicy`.
 */
export interface InlineAttributePolicy {
  /** Event-handler attributes (`onclick="…"`) all run: `'unsafe-inline'` is in effect for them. */
  handlersAllowAll: boolean;
  /** Hashes a handler's value may match. Empty unless the list also has `'unsafe-hashes'`, which
   * CSP requires before a hash can allow an attribute (CSP3 "does element match source list"). */
  handlerHashes: ReadonlySet<string>;
  /** `javascript:` URLs run: `'unsafe-inline'` is in effect for navigations. */
  javascriptURLsAllowAll: boolean;
}

const NO_ATTRIBUTE_CSP: InlineAttributePolicy = { handlersAllowAll: true, handlerHashes: new Set(), javascriptURLsAllowAll: true };

/**
 * Reads the inline-attribute policy out of a CSP header value. Handlers are governed by
 * `script-src-attr`, `javascript:` navigations by `script-src-elem`, each falling back to
 * `script-src` and then `default-src`. `null`, or no directive covering scripts, allows
 * everything (see `inlineScriptPolicy`). A hash never allows a `javascript:` URL here: browsers
 * disagree on what text they hash for one, so the gate doesn't guess.
 */
export function inlineAttributePolicy(csp: string | null): InlineAttributePolicy {
  if (csp === null) return NO_ATTRIBUTE_CSP;
  const directives = cspDirectives(csp);
  const attr = effectiveSources(directives, "script-src-attr");
  const elem = effectiveSources(directives, "script-src-elem");
  const handlers = attr === undefined ? undefined : sourceList(attr);
  return {
    handlersAllowAll: handlers === undefined || handlers.allowsAll,
    handlerHashes: handlers !== undefined && handlers.unsafeHashes ? handlers.hashes : new Set(),
    javascriptURLsAllowAll: elem === undefined || sourceList(elem).allowsAll,
  };
}

/** Elements whose content the tokenizer reads as text, not markup — so a `<button onclick>` written
 * inside one is never an element. `noscript` is included because its content only becomes markup
 * when scripting is off, and then no handler runs anyway. `plaintext` runs to the end of the page. */
const RAW_TEXT_ELEMENTS = new Set([
  "script", "style", "textarea", "title", "xmp", "iframe", "noembed", "noframes", "noscript", "plaintext",
]);

/** URL-valued attributes a `javascript:` URL runs from when followed or submitted. */
const NAVIGATION_URL_ATTRIBUTES = ["href", "xlink:href", "src", "action", "formaction"];

/** Decodes the character references that matter for reading an attribute value as a URL or as
 * handler text: numeric ones and a few named ones. Others are left as written. */
function decodeCharacterReferences(value: string): string {
  if (!value.includes("&")) return value;
  const named: Record<string, string> = {
    amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", colon: ":", tab: "\t", newline: "\n", nbsp: " ",
  };
  return value.replace(/&(?:#(\d{1,7})|#[xX]([0-9a-fA-F]{1,6})|([A-Za-z]{2,8}));?/g, (whole, dec, hex, name) => {
    if (dec !== undefined || hex !== undefined) {
      const code = dec !== undefined ? Number(dec) : parseInt(hex, 16);
      return code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : whole;
    }
    return named[name.toLowerCase()] ?? whole;
  });
}

/**
 * A `javascript:` URL that does something, or `null`. Reads the value the way the URL parser does
 * (leading C0 controls and spaces stripped, tabs and newlines removed anywhere, scheme
 * case-insensitive). The common no-op placeholders — `javascript:`, `javascript:;`,
 * `javascript:void(0)` — are not reported: CSP blocking them changes nothing a visitor sees, since
 * running them does nothing either.
 */
function liveJavascriptURL(raw: string): string | null {
  const url = decodeCharacterReferences(raw).replace(/[\t\n\r]/g, "").replace(/^[\u0000- ]+/, "");
  if (!/^javascript:/i.test(url)) return null;
  const body = url.slice("javascript:".length).replace(/\s+/g, "");
  return /^(?:void(?:\(0\)|0)|)?;?$/i.test(body) ? null : url;
}

/**
 * JavaScript written into HTML attributes of built pages that the site's own CSP would block
 * (#2232): inline event handlers (`<button onclick="…">`) and `javascript:` URLs
 * (`<a href="javascript:…">`). Both deploy fine and then silently do nothing for visitors, like
 * the inline `<script>` bodies `checkInlineScripts` reports (#2228).
 *
 * Only HTML (and inline SVG/MathML) elements are read. A tag name with a `:` is skipped: it is
 * not an element the page's DOM runs handlers for — the template's own
 * `<esi:include … onerror="continue">` is an edge directive, not an event handler. Custom elements
 * (`<my-widget onclick>`) are checked, since the browser does run handlers on them. Comments and
 * raw-text element bodies (`<script>`, `<style>`, `<textarea>`, …) are skipped, attributes are
 * read quote-aware (so `data-onclick` and an `onclick=` inside another attribute's value don't
 * count), and empty handlers are ignored. With `'unsafe-hashes'` and `hash`, a handler whose
 * value's digest is in the policy passes.
 *
 * One error per file, naming how many attributes are affected and quoting the first.
 */
export function checkInlineHandlers(
  content: string,
  file: string,
  policy: InlineAttributePolicy,
  hash?: (algorithm: "sha256" | "sha384" | "sha512", body: string) => string,
): Issue[] {
  if (policy.handlersAllowAll && policy.javascriptURLsAllowAll) return [];
  const algorithms = new Set([...policy.handlerHashes].map((h) => h.slice(0, h.indexOf("-")) as "sha256" | "sha384" | "sha512"));
  const blocked: string[] = [];
  const tagName = /<([A-Za-z][^\s/>]*)/y;
  let position = 0;
  while (position < content.length) {
    const lt = content.indexOf("<", position);
    if (lt === -1) break;
    if (content.startsWith("<!--", lt)) {
      const commentEnd = content.indexOf("-->", lt + 4);
      if (commentEnd === -1) break;
      position = commentEnd + 3;
      continue;
    }
    tagName.lastIndex = lt;
    const m = tagName.exec(content);
    if (m === null) {
      // `</…>`, `<!doctype>`, or a bare `<` in text: not an opening tag.
      position = lt + 1;
      continue;
    }
    const openEnd = tagEnd(content, lt);
    if (openEnd === -1) break;
    position = openEnd + 1;
    const name = m[1].toLowerCase();

    if (!name.includes(":")) {
      const attributes = tagAttributes(content.slice(lt, openEnd + 1));
      for (const [attribute, value] of attributes) {
        if (!/^on[a-z]+$/.test(attribute) || policy.handlersAllowAll) continue;
        const text = decodeCharacterReferences(value);
        if (text.trim() === "") continue;
        if (hash !== undefined && [...algorithms].some((alg) => policy.handlerHashes.has(`${alg}-${hash(alg, text)}`))) continue;
        blocked.push(`<${name} ${attribute}="${text}">`);
      }
      if (!policy.javascriptURLsAllowAll) {
        for (const attribute of NAVIGATION_URL_ATTRIBUTES) {
          const value = attributes.get(attribute);
          const url = value === undefined ? null : liveJavascriptURL(value);
          if (url !== null) blocked.push(`<${name} ${attribute}="${url}">`);
        }
      }
    }

    // Skip a raw-text element's body, so markup written inside a script or textarea isn't read.
    // (A trailing `/` doesn't close these in HTML: `<script/>` still opens a script.)
    if (RAW_TEXT_ELEMENTS.has(name)) {
      if (name === "plaintext") break;
      const closer = new RegExp(`</${name}(?=[\\s/>])`, "gi");
      closer.lastIndex = position;
      const close = closer.exec(content);
      if (close === null) break;
      position = close.index + close[0].length;
    }
  }
  if (blocked.length === 0) return [];
  const first = blocked[0].replace(/\s+/g, " ").trim();
  const snippet = first.length > 80 ? `${first.slice(0, 80)}…` : first;
  const count = blocked.length === 1 ? "A piece of JavaScript" : `${blocked.length} pieces of JavaScript`;
  return [{
    severity: "error",
    category: "csp-misconfigured",
    message: `${count} written into this page's HTML won't run once published — the site's security policy only runs scripts loaded from files. First one: ${snippet}`,
    file,
    remediation:
      "Attach the behavior from a script file instead (e.g. public/scripts/, using addEventListener), and replace javascript: links with a real address or a <button>.",
  }];
}
