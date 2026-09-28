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

const PII_PATTERNS = [
  { name: "email", pattern: /[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/g },
  { name: "phone", pattern: /\b\d{3}[-.]?\d{3}[-.]?\d{4}\b/g },
  { name: "SSN", pattern: /\b\d{3}-\d{2}-\d{4}\b/g },
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
const BLOCKED_SCRIPTS = [
  /facebook\.net.*fbevents/i,
  /hotjar\.com/i,
];

const BLOCKED_ROUTES = [/\/keystatic(?:\/|$)/i, /\/api\/keystatic/i];

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
  for (const pattern of BLOCKED_SCRIPTS) {
    if (pattern.test(content)) {
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
  for (const { name, pattern } of PII_PATTERNS) {
    if (name === "email" && emailExempt) continue;
    pattern.lastIndex = 0;
    const haystack = name === "email" ? withoutMailtoLinks : content;
    if (pattern.test(haystack)) {
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
  const urlContextPattern =
    /\b(?:src|srcset)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))|url\(\s*(?:"([^"]*)"|'([^']*)'|([^)\s]+))\s*\)/gi;
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
  const tagPattern = /<(script|link)\b[^>]*>/gi;
  let m: RegExpExecArray | null;
  while ((m = tagPattern.exec(content)) !== null) {
    const tag = m[0];
    const isScript = m[1].toLowerCase() === "script";
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
  const anchorPattern = /<a\b[^>]*>/gi;
  let m: RegExpExecArray | null;
  while ((m = anchorPattern.exec(content)) !== null) {
    const tag = m[0];
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
