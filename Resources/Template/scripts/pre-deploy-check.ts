#!/usr/bin/env npx tsx
/**
 * Pre-deploy security scan. Runs from the scaffolded site directory (not the template).
 *
 * Checks:
 * - No PII patterns (emails, phone numbers) in generated output
 * - No exposed API tokens or secrets
 * - No third-party tracking scripts
 * - No Keystatic admin routes in production output
 * - `anglesite.json` (if present) parses, is a JSON object, and declares a recognized schema
 *   version (#1173) — structural only; stays network-free, no declared-vs-live comparison here
 *
 * Usage: npx tsx scripts/pre-deploy-check.ts [--json] [--strict]
 *
 * Exit code 0: all clear. Exit code 1: issues found.
 * With --json: prints the versioned {version, ok, failures, warnings} envelope (#742).
 * With --strict: warnings are promoted into `failures` (both in the --json envelope and for
 * exit-code purposes) — used by `npm run build:ci`, the single entry point for non-interactive
 * runners (#799), where a warning-only issue must still block an automated bake/deploy.
 */

import { readdir, readFile, stat } from "node:fs/promises";
import { join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseAllowedDomains } from "./csp";
import { readConfigFromString } from "./config";
import { isMTAStsMarkerOwned, isSecurityTxtMarkerOwned, normalizeMTAStsMX, readLicensingPolicy, resolveMTAStsMode, resolveSecurityTxtMode } from "./edge-artifacts";
import { ANGLESITE_CONFIG_RECOGNIZED_VERSIONS } from "./anglesite-config";
import { rslActive, rslFileUrl } from "../src/lib/rsl.ts";
import { GOAL_BEACON_SCRIPT_PATH } from "./experiments-paths.ts";

interface Issue {
  severity: "error" | "warning";
  category: string;
  message: string;
  file?: string;
  /// The scan's suggested fix, when it has one — mirrors `PreDeployCheck.ScanFailure`/
  /// `ScanWarning`'s optional `remediation` field on the Swift side (#742/#1173). No existing
  /// check populates this yet; `checkAnglesiteConfig` is the first producer.
  remediation?: string;
}

interface ScanReport {
  version: 1;
  ok: boolean;
  failures: Issue[];
  warnings: Issue[];
}

const JSON_MODE = process.argv.includes("--json");
const STRICT_MODE = process.argv.includes("--strict");
const DIST_DIR = join(process.cwd(), "dist");
const HEADERS_FILE = join(DIST_DIR, "_headers");
const CONFIG_FILE = join(process.cwd(), ".site-config");
const ANGLESITE_CONFIG_FILE = join(process.cwd(), "anglesite.json");
const SOURCE_CONTENT_DIR = join(process.cwd(), "src", "content");

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

async function* walk(dir: string): AsyncGenerator<string> {
  const entries = await readdir(dir, { withFileTypes: true });
  for (const entry of entries) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) yield* walk(full);
    else yield full;
  }
}

/**
 * Validate the generated CSP. Returns one error Issue per problem:
 * missing _headers, no CSP directive, or a configured SCRIPT_ALLOW domain
 * absent from the CSP.
 */
export function checkHeaders(headersContent: string | null, configContent: string): Issue[] {
  const issues: Issue[] = [];
  if (headersContent === null) {
    issues.push({ severity: "error", category: "csp-misconfigured", message: "No dist/_headers — CSP is not enforced.", file: "_headers" });
    return issues;
  }
  const cspLine = headersContent
    .split("\n")
    .map((l) => l.trim())
    .find((l) => l.startsWith("Content-Security-Policy:"));
  if (!cspLine) {
    issues.push({ severity: "error", category: "csp-misconfigured", message: "dist/_headers has no Content-Security-Policy.", file: "_headers" });
    return issues;
  }
  const cspTokens = new Set(
    cspLine
      .replace(/^Content-Security-Policy:/, "")
      .split(/[\s;]+/)
      .filter((t) => t.length > 0),
  );
  const allow = parseAllowedDomains(configContent);
  for (const domain of allow) {
    if (!cspTokens.has(domain)) {
      issues.push({
        severity: "error",
        category: "csp-misconfigured",
        message: `Configured integration domain "${domain}" is missing from the CSP.`,
        file: "_headers",
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
 * Warn when expected security artifacts are absent from the built output.
 * `scripts/edge-artifacts.ts` (C1) always generates robots.txt at build. security.txt's
 * lifecycle is mode-aware (`SECURITY_TXT_MODE`) and is checked separately by
 * `checkSecurityTxt`, since presence alone is not conformance for that file.
 */
export function checkArtifactPresence(relPaths: string[]): Issue[] {
  const set = new Set(relPaths.map((p) => p.replace(/\\/g, "/")));
  const required = ["dist/robots.txt"];
  const issues: Issue[] = [];
  for (const path of required) {
    if (!set.has(path)) {
      issues.push({
        severity: "warning",
        category: "missing-security-artifact",
        message: `Missing security artifact: ${path.replace(/^dist\//, "")}`,
        file: path,
      });
    }
  }
  return issues;
}

interface SecurityTxtFields {
  contactCount: number;
  expiresValues: string[];
  canonicalValues: string[];
  hasFinalNewline: boolean;
  hasReplacementChar: boolean;
}

function parseSecurityTxtFields(content: string): SecurityTxtFields {
  const lines = content.split("\n");
  const fieldValues = (name: string) =>
    lines
      .filter((l) => new RegExp(`^${name}:`, "i").test(l.trim()))
      .map((l) => l.trim().replace(new RegExp(`^${name}:\\s*`, "i"), ""));
  return {
    contactCount: fieldValues("Contact").length,
    expiresValues: fieldValues("Expires"),
    canonicalValues: fieldValues("Canonical"),
    hasFinalNewline: content.endsWith("\n"),
    hasReplacementChar: content.includes("�"),
  };
}

/**
 * State-aware security.txt check (#743): validates against the resolved `SECURITY_TXT_MODE`
 * rather than requiring unconditional presence. disabled-and-absent is silent; a mode/file
 * contradiction (disabled-but-published, generated-but-not-Anglesite's-own-output) is one
 * finding; otherwise the published content is parsed for RFC 9116 conformance — Contact present,
 * exactly one (non-expired) Expires, at most one Canonical (matching `SITE_URL`'s origin when
 * both are set), and a final newline.
 */
const RECOGNIZED_SECURITY_TXT_MODES = new Set(["generated", "manual", "disabled"]);

export function checkSecurityTxt(content: string | null, configContent: string, now: Date): Issue[] {
  const file = "dist/.well-known/security.txt";
  const rawMode = readConfigFromString(configContent, "SECURITY_TXT_MODE");
  const mode = resolveSecurityTxtMode(rawMode, readConfigFromString(configContent, "SECURITY_CONTACT"));

  // An unset key legitimately falls back to inference (see resolveSecurityTxtMode's own doc
  // comment) — but a non-empty, unrecognized value (e.g. a typo like "Generated") silently gets
  // the same fallback with no signal that the key was ignored. Surface that distinctly, then keep
  // evaluating with the inferred mode rather than short-circuiting on it.
  const modeIssues: Issue[] =
    rawMode !== undefined && rawMode.trim().length > 0 && !RECOGNIZED_SECURITY_TXT_MODES.has(rawMode)
      ? [
          {
            severity: "warning",
            category: "security-txt-issue",
            message: `SECURITY_TXT_MODE="${rawMode}" is not a recognized value (generated|manual|disabled) — falling back to inferring from SECURITY_CONTACT.`,
            file,
          },
        ]
      : [];

  if (mode === "disabled") {
    if (content === null) return modeIssues;
    return [
      ...modeIssues,
      {
        severity: "warning",
        category: "security-txt-issue",
        message: "SECURITY_TXT_MODE=disabled but dist/.well-known/security.txt was published.",
        file,
      },
    ];
  }

  if (mode === "generated" && content !== null && !isSecurityTxtMarkerOwned(content)) {
    return [
      ...modeIssues,
      {
        severity: "warning",
        category: "security-txt-issue",
        message: "SECURITY_TXT_MODE=generated but the published security.txt wasn't generated by Anglesite.",
        file,
      },
    ];
  }

  if (content === null) {
    return [
      ...modeIssues,
      {
        severity: "warning",
        category: "security-txt-issue",
        message:
          mode === "generated"
            ? "SECURITY_TXT_MODE=generated but dist/.well-known/security.txt is missing — check SECURITY_CONTACT is set to a usable contact."
            : "SECURITY_TXT_MODE=manual but dist/.well-known/security.txt is missing.",
        file,
      },
    ];
  }

  const issues: Issue[] = [...modeIssues];
  const fields = parseSecurityTxtFields(content);

  if (fields.contactCount === 0) {
    issues.push({ severity: "warning", category: "security-txt-issue", message: "security.txt has no Contact field.", file });
  }

  if (fields.expiresValues.length !== 1) {
    issues.push({
      severity: "warning",
      category: "security-txt-issue",
      message: `security.txt must have exactly one Expires field (found ${fields.expiresValues.length}).`,
      file,
    });
  } else {
    const expires = new Date(fields.expiresValues[0]);
    if (Number.isNaN(expires.getTime())) {
      issues.push({ severity: "warning", category: "security-txt-issue", message: "security.txt Expires value is not a valid date.", file });
    } else if (expires.getTime() < now.getTime()) {
      issues.push({ severity: "warning", category: "security-txt-issue", message: "security.txt Expires date has passed (stale).", file });
    }
  }

  if (fields.canonicalValues.length > 1) {
    issues.push({ severity: "warning", category: "security-txt-issue", message: "security.txt has more than one Canonical field.", file });
  } else if (fields.canonicalValues.length === 1) {
    let canonicalOrigin: string | null = null;
    try {
      const parsed = new URL(fields.canonicalValues[0]);
      canonicalOrigin = parsed.protocol === "https:" ? parsed.origin : null;
    } catch {
      canonicalOrigin = null;
    }
    if (canonicalOrigin === null) {
      issues.push({ severity: "warning", category: "security-txt-issue", message: "security.txt Canonical must be a valid HTTPS URL.", file });
    } else {
      const siteUrl = readConfigFromString(configContent, "SITE_URL");
      let siteOrigin: string | null = null;
      if (siteUrl) {
        try {
          siteOrigin = new URL(siteUrl).origin;
        } catch {
          siteOrigin = null;
        }
      }
      if (siteOrigin && siteOrigin !== canonicalOrigin) {
        issues.push({
          severity: "warning",
          category: "security-txt-issue",
          message: `security.txt Canonical origin (${canonicalOrigin}) does not match SITE_URL (${siteOrigin}).`,
          file,
        });
      }
    }
  }

  if (!fields.hasFinalNewline) {
    issues.push({ severity: "warning", category: "security-txt-issue", message: "security.txt does not end with a final newline.", file });
  }
  if (fields.hasReplacementChar) {
    issues.push({ severity: "warning", category: "security-txt-issue", message: "security.txt contains invalid UTF-8 (replacement character found).", file });
  }

  return issues;
}

/**
 * RFC 8461 MTA-STS policy check. A disabled site must not accidentally publish a policy; enabled
 * modes require an Anglesite-owned policy with exactly one version/mode/max_age, at least one MX,
 * and a max_age within the RFC's one-year upper bound. DNS is checked by the Domain settings
 * workflow because a static build has no authority to inspect the authoritative zone.
 */
export function checkMTAStsPolicy(content: string | null, configContent: string): Issue[] {
  const file = "dist/.well-known/mta-sts.txt";
  const rawMode = readConfigFromString(configContent, "MTA_STS_MODE");
  const mode = resolveMTAStsMode(rawMode);
  const issues: Issue[] = [];
  if (rawMode !== undefined && rawMode.trim().length > 0 && !["disabled", "testing", "enforce"].includes(rawMode)) {
    issues.push({ severity: "warning", category: "mta-sts-issue", message: `MTA_STS_MODE=\"${rawMode}\" is not a recognized value (disabled|testing|enforce).`, file });
  }
  if (mode === "disabled") {
    if (content !== null) issues.push({ severity: "warning", category: "mta-sts-issue", message: "MTA_STS_MODE=disabled but dist/.well-known/mta-sts.txt was published.", file });
    return issues;
  }
  if (normalizeMTAStsMX(readConfigFromString(configContent, "MTA_STS_MX")).length === 0) {
    issues.push({ severity: "warning", category: "mta-sts-issue", message: `MTA_STS_MODE=${mode} but MTA_STS_MX has no valid MX host.`, file });
  }
  if (content === null) {
    issues.push({ severity: "warning", category: "mta-sts-issue", message: `MTA_STS_MODE=${mode} but dist/.well-known/mta-sts.txt is missing.`, file });
    return issues;
  }
  if (!isMTAStsMarkerOwned(content)) {
    issues.push({ severity: "warning", category: "mta-sts-issue", message: "MTA_STS_MODE is enabled but the published MTA-STS policy was not generated by Anglesite.", file });
  }
  const values = (field: string) => content.split("\n")
    .filter((line) => new RegExp(`^${field}:`, "i").test(line.trim()))
    .map((line) => line.trim().replace(new RegExp(`^${field}:\\s*`, "i"), ""));
  const version = values("version");
  const policyMode = values("mode");
  const mx = values("mx");
  const maxAge = values("max_age");
  const normalizedMX = mx.map((host) => normalizeMTAStsMX(host));
  const mxHosts = normalizedMX.flat();
  if (version.length !== 1 || version[0] !== "STSv1") issues.push({ severity: "warning", category: "mta-sts-issue", message: "MTA-STS policy must contain exactly one version: STSv1 field.", file });
  if (policyMode.length !== 1 || policyMode[0] !== mode) issues.push({ severity: "warning", category: "mta-sts-issue", message: `MTA-STS policy mode must match MTA_STS_MODE=${mode}.`, file });
  if (mx.length === 0 || normalizedMX.some((hosts) => hosts.length !== 1) || new Set(mxHosts).size !== mxHosts.length) issues.push({ severity: "warning", category: "mta-sts-issue", message: "MTA-STS policy needs one valid, unique mx field per permitted MX host.", file });
  if (maxAge.length !== 1 || !/^\d{1,10}$/.test(maxAge[0]) || Number(maxAge[0]) > 31_557_600) issues.push({ severity: "warning", category: "mta-sts-issue", message: "MTA-STS policy must contain one max_age from 0 through 31557600.", file });
  if (!content.endsWith("\n")) issues.push({ severity: "warning", category: "mta-sts-issue", message: "MTA-STS policy does not end with a final newline.", file });
  return issues;
}

/**
 * RSL conformance check (#992). Unlike security.txt/MTA-STS, there's no lifecycle mode to
 * validate against — `rslActive` is a pure function of `publishRSL` and `SITE_URL`, so this only
 * checks that the four projections (`rsl.xml`, robots.txt `License:`, the `Link:` header, and —
 * implicitly — the pointer they all share) actually agree with each other and with that gate.
 * `BaseLayout.astro`'s `<link>` isn't checked here: it's per-page HTML, not a single build
 * artifact, and `licensing.build.test.ts` already asserts it end-to-end against a real build.
 */
export function checkRSL(
  rslActiveNow: boolean,
  expectedRslUrl: string | null,
  rslXmlContent: string | null,
  robotsContent: string,
  headersContent: string | null,
): Issue[] {
  const issues: Issue[] = [];
  const file = "dist/rsl.xml";
  const licenseDirective = robotsContent
    .split("\n")
    .find((line) => /^License:/i.test(line.trim()))
    ?.replace(/^License:\s*/i, "")
    .trim();
  const rslLinkHeader = headersContent?.includes('rel="license"; type="application/rsl+xml"')
    ? headersContent.match(/Link:\s*<([^>]+)>;\s*rel="license";\s*type="application\/rsl\+xml"/)?.[1]
    : undefined;

  if (!rslActiveNow) {
    if (rslXmlContent !== null) {
      issues.push({
        severity: "warning",
        category: "rsl-issue",
        message: "dist/rsl.xml was published, but RSL isn't active (publishRSL is off, or SITE_URL isn't a usable https URL).",
        file,
      });
    }
    if (licenseDirective) {
      issues.push({
        severity: "warning",
        category: "rsl-issue",
        message: "robots.txt has a License: directive, but RSL isn't active.",
        file: "dist/robots.txt",
      });
    }
    return issues;
  }

  if (rslXmlContent === null) {
    issues.push({
      severity: "warning",
      category: "rsl-issue",
      message: "publishRSL is on but dist/rsl.xml is missing — the policy may have nothing to declare (no default license and no stated usage preference).",
      file,
    });
  } else if (!/<rsl\s[^>]*xmlns="https:\/\/rslstandard\.org\/rsl"/.test(rslXmlContent)) {
    issues.push({
      severity: "error",
      category: "rsl-issue",
      message: "dist/rsl.xml doesn't declare the RSL namespace (xmlns=\"https://rslstandard.org/rsl\") on its root element.",
      file,
    });
  }

  if (!licenseDirective) {
    issues.push({
      severity: "warning",
      category: "rsl-issue",
      message: "RSL is active but robots.txt has no License: directive.",
      file: "dist/robots.txt",
    });
  } else if (expectedRslUrl && licenseDirective !== expectedRslUrl) {
    issues.push({
      severity: "error",
      category: "rsl-issue",
      message: `robots.txt License: (${licenseDirective}) doesn't match the site's rsl.xml URL (${expectedRslUrl}).`,
      file: "dist/robots.txt",
    });
  }

  if (!rslLinkHeader) {
    issues.push({
      severity: "warning",
      category: "rsl-issue",
      message: 'RSL is active but dist/_headers has no Link: rel="license" header.',
      file: "dist/_headers",
    });
  } else if (expectedRslUrl && rslLinkHeader !== expectedRslUrl) {
    issues.push({
      severity: "error",
      category: "rsl-issue",
      message: `dist/_headers Link: header (${rslLinkHeader}) doesn't match the site's rsl.xml URL (${expectedRslUrl}).`,
      file: "dist/_headers",
    });
  }

  return issues;
}

/**
 * Structural validation of `Source/anglesite.json` (#1173): the file parses as JSON, is a JSON
 * object, and declares a recognized schema version. Deliberately shallow — per-section field
 * validation is `DomainConfigStore`'s job (Swift-side, #1169) and the #1171 drift audit's; this
 * check exists only to fail loudly on a hand-edit that broke the file outright, since
 * `readAnglesiteConfig`'s tolerant reader would otherwise silently fall back to defaults and the
 * owner's declarations would vanish with no signal. `raw` is `null` when the file doesn't exist
 * — the normal "no declarations yet" case, not an issue. Returns at most one issue: each
 * structural problem is a prerequisite for checking the next (can't validate a version that
 * didn't parse), so there's nothing to gain from accumulating more than one.
 */
export function checkAnglesiteConfig(raw: string | null): Issue[] {
  const file = "anglesite.json";
  if (raw === null) return [];

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    return [{
      severity: "error",
      category: "anglesite-config-invalid",
      message: `anglesite.json is not valid JSON: ${err instanceof Error ? err.message : String(err)}`,
      file,
      remediation: "Fix the JSON syntax, or delete the file to reset your domain configuration declarations.",
    }];
  }

  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    return [{
      severity: "error",
      category: "anglesite-config-invalid",
      message: "anglesite.json must contain a JSON object.",
      file,
      remediation: "Wrap the file's contents in a single JSON object (\"{ ... }\"), or delete it to reset your domain configuration declarations.",
    }];
  }

  const config = parsed as Record<string, unknown>;
  if ("version" in config && typeof config.version !== "number") {
    return [{
      severity: "error",
      category: "anglesite-config-invalid",
      message: `anglesite.json's "version" must be a number (found ${typeof config.version}).`,
      file,
      remediation: "Fix the \"version\" field, or remove it to default to the current schema version.",
    }];
  }

  const version = typeof config.version === "number" ? config.version : 1;
  if (!ANGLESITE_CONFIG_RECOGNIZED_VERSIONS.has(version)) {
    return [{
      severity: "error",
      category: "anglesite-config-invalid",
      message: `anglesite.json declares version ${version}, which this build doesn't recognize (supported: ${[...ANGLESITE_CONFIG_RECOGNIZED_VERSIONS].join(", ")}).`,
      file,
      remediation: "Update Anglesite to a version that supports this schema, or hand-edit \"version\" back to a supported value.",
    }];
  }

  return [];
}

/**
 * Validates `anglesite.json`'s `experimental.mcp` field when present (#1576): the flag gates a
 * real unauthenticated request-handling surface (the site's MCP server), so a malformed value
 * should fail loudly rather than the tolerant reader silently treating it as falsy. Mirrors
 * `checkAnglesiteConfig`'s shallow-validation shape; only runs meaningfully once that check has
 * already confirmed the document is well-formed JSON.
 */
export function checkExperimentalSection(raw: string | null): Issue[] {
  if (raw === null) return [];

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return []; // checkAnglesiteConfig already reports invalid JSON.
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) return [];

  const experimental = (parsed as Record<string, unknown>).experimental;
  if (experimental === undefined) return [];
  if (typeof experimental !== "object" || experimental === null || Array.isArray(experimental)) {
    return [
      {
        severity: "error",
        category: "experimental-invalid",
        message: 'anglesite.json\'s "experimental" must be an object.',
        file: "anglesite.json",
        remediation: 'Wrap experimental flags in an object, e.g. "experimental": { "mcp": true }.',
      },
    ];
  }

  const mcp = (experimental as Record<string, unknown>).mcp;
  if (mcp !== undefined && typeof mcp !== "boolean") {
    return [
      {
        severity: "error",
        category: "experimental-invalid",
        message: `anglesite.json's "experimental.mcp" must be a boolean (found ${typeof mcp}).`,
        file: "anglesite.json",
        remediation: 'Set "experimental.mcp" to true or false, or remove it to leave the feature off.',
      },
    ];
  }

  return [];
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

const EXPERIMENT_ID_PATTERN = /^[A-Za-z0-9-]+$/;
const KNOWN_GOAL_KINDS = new Set(["pageview", "route", "scroll", "visible"]);
const CLIENT_GOAL_KINDS = new Set(["scroll", "visible"]);
const GOAL_BEACON_SCRIPT_DIST_PATH = `dist${GOAL_BEACON_SCRIPT_PATH}`;
const GOAL_BEACON_SCRIPT_TAG_PATTERN = new RegExp(
  `<script\\b[^>]*\\bsrc\\s*=\\s*["']${escapeRegExp(GOAL_BEACON_SCRIPT_PATH)}["'][^>]*>`,
  "i",
);

/**
 * `requireTrailingSlash` covers page routes: this template's Astro build emits directory-format
 * output (`distPathFor` maps both "/pricing" and "/pricing/" to the same
 * `dist/pricing/index.html`), so the gate's dist-file check passes either way — but at the edge,
 * `worker.ts` and `matchesGoal` do an exact `pathname ===` match against the *runtime* request
 * path, which Cloudflare's default trailing-slash canonicalization always gives a trailing slash
 * for a directory-format route. A page/variant.page/pageview-goal path missing the slash passes
 * this gate today but the experiment silently never fires at the edge. Route-kind goal paths
 * (API/action endpoints like "/api/contact") are a different shape — this codebase's convention
 * for them has no trailing slash (see worker.ts's ROUTES table) — so callers must NOT set this for
 * those.
 */
function experimentPathProblem(path: unknown, opts?: { requireTrailingSlash?: boolean }): string | null {
  if (typeof path !== "string" || path.length === 0) return "must be a non-empty string";
  if (!path.startsWith("/")) return 'must start with "/"';
  if (path.includes("..")) return 'must not contain ".."';
  if (path.includes("%")) return "must not contain percent-encoding";
  if (opts?.requireTrailingSlash && !path.endsWith("/")) {
    return 'must end with "/" (page routes build to a directory\'s index.html, and the runtime request path is canonicalized to match)';
  }
  return null;
}

function distPathFor(routePath: string): string {
  const withTrailingSlash = routePath.endsWith("/") ? routePath : `${routePath}/`;
  return withTrailingSlash === "/" ? "dist/index.html" : `dist${withTrailingSlash}index.html`;
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function tryParsePathname(href: string): string | null {
  try {
    return new URL(href, "https://experiments.invalid").pathname;
  } catch {
    return null;
  }
}

// Isolates each whole tag first, then tests attributes independently within it — same idiom as
// checkSRI/checkExternalLinkRel above — so a single regex spanning two attributes never depends
// on which one appears first in the source markup.
function findCanonicalHref(html: string): string | null {
  const tagPattern = /<link\b[^>]*>/gi;
  let m: RegExpExecArray | null;
  while ((m = tagPattern.exec(html)) !== null) {
    const tag = m[0];
    if (!/\brel\s*=\s*["']canonical["']/i.test(tag)) continue;
    const hrefMatch = tag.match(/\bhref\s*=\s*["']([^"']+)["']/i);
    if (hrefMatch) return hrefMatch[1];
  }
  return null;
}

function hasNoindexRobotsMeta(html: string): boolean {
  const tagPattern = /<meta\b[^>]*>/gi;
  let m: RegExpExecArray | null;
  while ((m = tagPattern.exec(html)) !== null) {
    const tag = m[0];
    if (!/\bname\s*=\s*["']robots["']/i.test(tag)) continue;
    const contentMatch = tag.match(/\bcontent\s*=\s*["']([^"']*)["']/i);
    if (contentMatch && /\bnoindex\b/i.test(contentMatch[1])) return true;
  }
  return false;
}

// Leaf (last, target) simple-selector shapes GoalSelectorBuilder's Swift-side picker can produce.
// A trailing `:nth-child(n)` structural pseudo-class carries no attribute/content signal a regex
// can verify, so it's stripped before matching and falls through to the bare-tag check below.
const LEAF_PSEUDO_SUFFIX_PATTERN = /:nth-child\(\d+\)$/;
const LEAF_ATTR_PATTERN = /^\[([\w-]+)="([^"]*)"\]$/;
const LEAF_ID_PATTERN = /^#([\w-]+)$/;
const LEAF_ROLE_ARIA_PATTERN = /^\[role="([^"]*)"\]\[aria-label="([^"]*)"\]$/;
const LEAF_TAG_CLASSES_PATTERN = /^([a-z0-9]+)((?:\.[\w-]+)*)$/;

/**
 * Best-effort check that `selector`'s LAST (leaf) simple-selector component resolves against
 * `html` — same regex-tag-isolation idiom as `findCanonicalHref`/`hasNoindexRobotsMeta` above,
 * deliberately not a full CSS selector engine (no new dependency; see CONTRIBUTING.md's
 * no-new-dependencies rule). This only verifies the target element's own attributes/id/classes/tag
 * name appear somewhere in the built HTML — it does not verify the combinator chain's ancestor
 * relationships (e.g. a "ul > li.item" selector only confirms an `li.item` exists *somewhere*, not
 * that it's a child of a `ul`). That's an intentional, documented simplification: the beacon's
 * `document.querySelector` needs the leaf element to exist at all for the goal to ever have a
 * chance of firing, which is the failure class this check guards against.
 */
function selectorLikelyMatchesHtml(html: string, selector: string): boolean {
  const leaf = (selector.split(" > ").pop() ?? selector).replace(LEAF_PSEUDO_SUFFIX_PATTERN, "");
  const tagPattern = /<[a-zA-Z][^>]*>/g;
  let m: RegExpExecArray | null;

  const attrMatch = leaf.match(LEAF_ATTR_PATTERN);
  const idMatch = leaf.match(LEAF_ID_PATTERN);
  const roleAriaMatch = leaf.match(LEAF_ROLE_ARIA_PATTERN);
  const tagClassesMatch = leaf.match(LEAF_TAG_CLASSES_PATTERN);

  while ((m = tagPattern.exec(html)) !== null) {
    const tag = m[0];
    if (attrMatch && new RegExp(`\\b${attrMatch[1]}\\s*=\\s*["']${escapeRegExp(attrMatch[2])}["']`).test(tag)) return true;
    if (idMatch && new RegExp(`\\bid\\s*=\\s*["']${escapeRegExp(idMatch[1])}["']`).test(tag)) return true;
    if (
      roleAriaMatch &&
      new RegExp(`\\brole\\s*=\\s*["']${escapeRegExp(roleAriaMatch[1])}["']`).test(tag) &&
      new RegExp(`\\baria-label\\s*=\\s*["']${escapeRegExp(roleAriaMatch[2])}["']`).test(tag)
    )
      return true;
    if (tagClassesMatch) {
      const [, tagName, dotClasses] = tagClassesMatch;
      const classes = dotClasses.split(".").filter(Boolean);
      const tagMatches = new RegExp(`^<${tagName}\\b`, "i").test(tag);
      const classMatch = tag.match(/\bclass\s*=\s*["']([^"']*)["']/i);
      const tagClasses = classMatch ? classMatch[1].split(/\s+/) : [];
      if (tagMatches && classes.every((c) => tagClasses.includes(c))) return true;
      if (tagMatches && classes.length === 0) return true; // bare tag / tag:nth-child(n) fallback
    }
  }
  return false;
}

/**
 * Parses just enough of `anglesiteConfigRaw` to find the one well-formed running experiment's
 * `page`/`variant.page` pair, or `null` on ANY problem (missing, malformed JSON, no experiments,
 * zero or multiple running, malformed page/variant/variant.page, etc.) — a cheap, best-effort
 * lookup for `scan()` to decide what dist files are worth reading, not a second validator. Full
 * validation of the config, including of `page`/`variant.page` themselves, still happens in
 * `checkExperiments`. Shared by `runningExperimentControlDistPath`/`runningExperimentVariantDistPath`
 * below so both resolve the same running experiment.
 */
function parseSingleRunningExperiment(anglesiteConfigRaw: string | null): { page: string; variantPage: string } | null {
  if (anglesiteConfigRaw === null) return null;
  try {
    const parsed: unknown = JSON.parse(anglesiteConfigRaw);
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) return null;

    const experimentsSection = (parsed as Record<string, unknown>).experiments;
    if (typeof experimentsSection !== "object" || experimentsSection === null) return null;

    const active = (experimentsSection as Record<string, unknown>).active;
    if (!Array.isArray(active)) return null;

    const runningEntries = active.filter(
      (entry): entry is Record<string, unknown> =>
        typeof entry === "object" && entry !== null && !Array.isArray(entry) && entry.status === "running",
    );
    if (runningEntries.length !== 1) return null;

    const running = runningEntries[0];
    const page = running.page;
    if (typeof page !== "string" || page.length === 0) return null;

    const variant = running.variant;
    if (typeof variant !== "object" || variant === null || Array.isArray(variant)) return null;

    const variantPage = (variant as Record<string, unknown>).page;
    if (typeof variantPage !== "string" || variantPage.length === 0) return null;

    return { page, variantPage };
  } catch {
    return null;
  }
}

/** The built dist path of the running experiment's own (control) page — see
 *  `parseSingleRunningExperiment`'s doc comment for the resolution/error contract. */
export function runningExperimentControlDistPath(anglesiteConfigRaw: string | null): string | null {
  const running = parseSingleRunningExperiment(anglesiteConfigRaw);
  return running ? distPathFor(running.page) : null;
}

/** The built dist path of the running experiment's variant page — see
 *  `parseSingleRunningExperiment`'s doc comment for the resolution/error contract. */
export function runningExperimentVariantDistPath(anglesiteConfigRaw: string | null): string | null {
  const running = parseSingleRunningExperiment(anglesiteConfigRaw);
  return running ? distPathFor(running.variantPage) : null;
}

/**
 * Validates the `experiments` section of `anglesite.json` (#1270 slices 1-2) and, for the one
 * running experiment (if any), that its edge machinery is actually built and wired — a page,
 * variant, or pageview-goal path that doesn't exist in `dist/`, a variant missing its
 * canonical/noindex/sitemap-exclusion, or (for a "scroll"/"visible" goal) either arm missing the
 * goal beacon script/tag, is exactly the class of misconfiguration that burns real traffic
 * silently for a week before anyone notices (design doc §6). Runs after `checkAnglesiteConfig` has
 * already confirmed the document parses as a JSON object with a recognized version — this function
 * re-parses defensively but returns no issues of its own for a document `checkAnglesiteConfig`
 * already flagged, so the two never double-report the same root cause.
 */
export function checkExperiments(
  anglesiteConfigRaw: string | null,
  distFiles: Set<string>,
  variantHtmlContent: string | null,
  sitemapContent: string | null,
  controlHtmlContent: string | null = null,
): Issue[] {
  if (anglesiteConfigRaw === null) return [];

  let parsed: unknown;
  try {
    parsed = JSON.parse(anglesiteConfigRaw);
  } catch {
    return []; // checkAnglesiteConfig already reports invalid JSON.
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) return [];

  const config = parsed as Record<string, unknown>;
  const experimentsSection = config.experiments;
  if (typeof experimentsSection !== "object" || experimentsSection === null) return [];

  const active = (experimentsSection as Record<string, unknown>).active;
  if (active === undefined) return [];
  if (!Array.isArray(active)) {
    return [
      {
        severity: "error",
        category: "experiments-invalid",
        message: 'anglesite.json\'s "experiments.active" must be an array.',
        file: "anglesite.json",
        remediation: 'Wrap the experiment entries in an array, or remove "experiments" to disable A/B testing.',
      },
    ];
  }

  const issues: Issue[] = [];
  const runningExperiments: Record<string, unknown>[] = [];

  active.forEach((rawEntry, index) => {
    const label = `experiments.active[${index}]`;
    if (typeof rawEntry !== "object" || rawEntry === null || Array.isArray(rawEntry)) {
      issues.push({ severity: "error", category: "experiments-invalid", message: `${label} must be an object.`, file: "anglesite.json" });
      return;
    }
    const entry = rawEntry as Record<string, unknown>;

    if (typeof entry.id !== "string" || !EXPERIMENT_ID_PATTERN.test(entry.id)) {
      issues.push({
        severity: "error",
        category: "experiments-invalid",
        message: `${label}.id must match ${EXPERIMENT_ID_PATTERN} (found ${JSON.stringify(entry.id)}).`,
        file: "anglesite.json",
      });
    }

    const pageProblem = experimentPathProblem(entry.page, { requireTrailingSlash: true });
    if (pageProblem) {
      issues.push({ severity: "error", category: "experiments-invalid", message: `${label}.page ${pageProblem}.`, file: "anglesite.json" });
    }

    const variant = entry.variant as Record<string, unknown> | undefined;
    if (typeof variant !== "object" || variant === null) {
      issues.push({ severity: "error", category: "experiments-invalid", message: `${label}.variant must be an object.`, file: "anglesite.json" });
    } else {
      if (typeof variant.id !== "string" || !EXPERIMENT_ID_PATTERN.test(variant.id)) {
        issues.push({
          severity: "error",
          category: "experiments-invalid",
          message: `${label}.variant.id must match ${EXPERIMENT_ID_PATTERN} (found ${JSON.stringify(variant.id)}).`,
          file: "anglesite.json",
        });
      } else if (variant.id === "control") {
        issues.push({
          severity: "error",
          category: "experiments-invalid",
          message: `${label}.variant.id must not be "control" — "control" is reserved for the unmodified page. A variant sharing that id is indistinguishable from control once assigned, silently breaking assignment stickiness.`,
          file: "anglesite.json",
        });
      }
      const variantPageProblem = experimentPathProblem(variant.page, { requireTrailingSlash: true });
      if (variantPageProblem) {
        issues.push({
          severity: "error",
          category: "experiments-invalid",
          message: `${label}.variant.page ${variantPageProblem}.`,
          file: "anglesite.json",
        });
      }
    }

    if (typeof entry.split !== "number" || entry.split <= 0 || entry.split >= 1) {
      issues.push({
        severity: "error",
        category: "experiments-invalid",
        message: `${label}.split must be a number strictly between 0 and 1 (found ${JSON.stringify(entry.split)}).`,
        file: "anglesite.json",
      });
    }

    if (entry.status !== "draft" && entry.status !== "running") {
      issues.push({
        severity: "error",
        category: "experiments-invalid",
        message: `${label}.status must be "draft" or "running" (found ${JSON.stringify(entry.status)}).`,
        file: "anglesite.json",
      });
    }

    const goal = entry.goal as Record<string, unknown> | undefined;
    if (typeof goal !== "object" || goal === null) {
      issues.push({ severity: "error", category: "experiments-invalid", message: `${label}.goal must be an object.`, file: "anglesite.json" });
    } else if (!KNOWN_GOAL_KINDS.has(goal.kind as string)) {
      issues.push({
        severity: "error",
        category: "experiments-invalid",
        message: `${label}.goal.kind must be one of pageview, route, scroll, visible (found ${JSON.stringify(goal.kind)}).`,
        file: "anglesite.json",
      });
    } else if (goal.kind === "pageview" || goal.kind === "route") {
      // Only "pageview" goals are page routes (Astro directory-format output); "route" goals are
      // API/action endpoints, which this codebase never gives a trailing slash (see worker.ts's
      // ROUTES table) — see experimentPathProblem's doc comment.
      const goalPathProblem = experimentPathProblem(goal.path, { requireTrailingSlash: goal.kind === "pageview" });
      if (goalPathProblem) {
        issues.push({ severity: "error", category: "experiments-invalid", message: `${label}.goal.path ${goalPathProblem}.`, file: "anglesite.json" });
      }
    } else if (goal.kind === "scroll") {
      if (typeof goal.depth !== "number" || goal.depth < 1 || goal.depth > 100) {
        issues.push({
          severity: "error",
          category: "experiments-invalid",
          message: `${label}.goal.depth must be a number between 1 and 100 (found ${JSON.stringify(goal.depth)}).`,
          file: "anglesite.json",
        });
      }
    } else {
      // goal.kind === "visible"
      if (typeof goal.selector !== "string" || goal.selector.trim().length === 0) {
        issues.push({
          severity: "error",
          category: "experiments-invalid",
          message: `${label}.goal.selector must be a non-empty string (found ${JSON.stringify(goal.selector)}).`,
          file: "anglesite.json",
        });
      }
    }

    if (entry.status === "running") runningExperiments.push(entry);
  });

  if (runningExperiments.length > 1) {
    issues.push({
      severity: "error",
      category: "experiments-invalid",
      message: `Only one experiment may be "running" at a time (found ${runningExperiments.length}).`,
      file: "anglesite.json",
      remediation: "Conclude or pause the other running experiments before starting a new one.",
    });
  }

  const running = runningExperiments[0];
  if (!running || issues.some((issue) => issue.severity === "error")) return issues;

  // Below here, `running`'s own fields are already known well-formed (no error pushed for it
  // above), so it's safe to build dist-file checks against them.
  const page = running.page as string;
  const variant = running.variant as Record<string, unknown>;
  const variantPage = variant.page as string;
  const goal = running.goal as Record<string, unknown>;

  for (const [routePath, roleLabel] of [
    [page, "page"],
    [variantPage, "variant.page"],
  ] as const) {
    const distPath = distPathFor(routePath);
    if (!distFiles.has(distPath)) {
      issues.push({
        severity: "error",
        category: "experiments-not-built",
        message: `Running experiment's ${roleLabel} ("${routePath}") has no built page at ${distPath}.`,
        file: distPath,
        remediation: "Build the site before deploying, or check the route matches an actual page.",
      });
    }
  }

  if (goal.kind === "pageview") {
    const goalPath = goal.path as string;
    const goalDistPath = distPathFor(goalPath);
    if (!distFiles.has(goalDistPath)) {
      issues.push({
        severity: "error",
        category: "experiments-not-built",
        message: `Running experiment's pageview goal ("${goalPath}") has no built page at ${goalDistPath}.`,
        file: goalDistPath,
        remediation: "Build the site before deploying, or check the goal path matches an actual page.",
      });
    }
  }

  if (variantHtmlContent !== null) {
    const canonicalHref = findCanonicalHref(variantHtmlContent);
    const canonicalPath = canonicalHref ? tryParsePathname(canonicalHref) : null;
    if (canonicalPath !== page) {
      issues.push({
        severity: "error",
        category: "experiments-variant-seo",
        message: `Variant page ("${variantPage}") must carry rel="canonical" pointing at the control page ("${page}").`,
        file: distPathFor(variantPage),
        remediation: 'Add <link rel="canonical"> to the variant page pointing at the control page.',
      });
    }
    if (!hasNoindexRobotsMeta(variantHtmlContent)) {
      issues.push({
        severity: "error",
        category: "experiments-variant-seo",
        message: `Variant page ("${variantPage}") must carry a noindex robots meta tag.`,
        file: distPathFor(variantPage),
        remediation: 'Add <meta name="robots" content="noindex"> to the variant page.',
      });
    }
  }

  if (sitemapContent !== null && new RegExp(escapeRegExp(variantPage)).test(sitemapContent)) {
    issues.push({
      severity: "error",
      category: "experiments-variant-seo",
      message: `Variant page ("${variantPage}") must be excluded from the sitemap.`,
      file: "dist/sitemap.xml",
      remediation: "Exclude the variant route from sitemap generation.",
    });
  }

  // Client-side goals (#1270 slice 2) can never fire without the beacon script actually built and
  // referenced from both arms — a variant/control page missing the tag is the same class of
  // silent-traffic-burn misconfiguration the checks above guard against for edge-visible goals.
  if (CLIENT_GOAL_KINDS.has(goal.kind as string)) {
    if (!distFiles.has(GOAL_BEACON_SCRIPT_DIST_PATH)) {
      issues.push({
        severity: "error",
        category: "experiments-goal-beacon",
        message: `Running experiment's "${goal.kind}" goal needs the goal beacon script, but no built file exists at ${GOAL_BEACON_SCRIPT_DIST_PATH}.`,
        file: GOAL_BEACON_SCRIPT_DIST_PATH,
        remediation: "Confirm public/x/goal-beacon.js ships with the site and rebuild.",
      });
    }

    for (const [html, roleLabel, distPath] of [
      [controlHtmlContent, "control page", distPathFor(page)],
      [variantHtmlContent, "variant page", distPathFor(variantPage)],
    ] as const) {
      if (html !== null && !GOAL_BEACON_SCRIPT_TAG_PATTERN.test(html)) {
        issues.push({
          severity: "error",
          category: "experiments-goal-beacon",
          message: `Running experiment's ${roleLabel} ("${roleLabel === "control page" ? page : variantPage}") must include the goal beacon <script src="${GOAL_BEACON_SCRIPT_PATH}"> tag — its "${goal.kind}" goal can never fire without it.`,
          file: distPath,
          remediation: "Confirm the page renders through BaseLayout, so the beacon is injected for a running client-side-goal experiment.",
        });
      }
    }
  }

  // A "visible" goal's selector must actually resolve against BOTH built pages — the owner picks
  // it against the dev-server preview (Anglesite app, #1270 slice 5), which is not guaranteed to
  // match the production build's DOM 1:1 (Astro's dev-time scoped-class hashes, in particular). A
  // selector that only ever matched the preview is a goal that silently never fires — the same
  // failure class the beacon-tag check above guards against.
  if (goal.kind === "visible" && typeof goal.selector === "string") {
    const selector = goal.selector;
    for (const [html, roleLabel, distPath] of [
      [controlHtmlContent, "control page", distPathFor(page)],
      [variantHtmlContent, "variant page", distPathFor(variantPage)],
    ] as const) {
      if (html !== null && !selectorLikelyMatchesHtml(html, selector)) {
        issues.push({
          severity: "error",
          category: "experiments-goal-beacon",
          message: `Running experiment's "visible" goal selector (${JSON.stringify(selector)}) doesn't match anything in the built ${roleLabel} ("${roleLabel === "control page" ? page : variantPage}") — this goal can never fire.`,
          file: distPath,
          remediation: "Re-pick the element in the app, or hand-edit the selector to match markup that exists in the built page.",
        });
      }
    }
  }

  return issues;
}

async function scan(): Promise<Issue[]> {
  const issues: Issue[] = [];

  // Independent of dist/ — anglesite.json lives at the site root, so this runs even when
  // there's nothing built yet to scan below.
  const anglesiteConfigContent = await readFile(ANGLESITE_CONFIG_FILE, "utf-8").catch(
    (e: NodeJS.ErrnoException) => (e.code === "ENOENT" ? null : Promise.reject(e)),
  );
  issues.push(...checkAnglesiteConfig(anglesiteConfigContent));
  issues.push(...checkExperimentalSection(anglesiteConfigContent));

  try {
    for await (const file of walk(SOURCE_CONTENT_DIR)) {
      if (!/\.(md|mdx|json)$/i.test(file)) continue;
      const content = await readFile(file, "utf-8");
      issues.push(...checkNoRestrictedContentInSource(relative(process.cwd(), file), content));
    }
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw e;
  }

  try {
    await stat(DIST_DIR);
  } catch {
    issues.push({ severity: "warning", category: "missing-security-artifact", message: "No dist/ directory found — nothing to scan." });
    return issues;
  }

  const headersContent = await readFile(HEADERS_FILE, "utf-8").catch((e: NodeJS.ErrnoException) =>
    e.code === "ENOENT" ? null : Promise.reject(e),
  );
  const configContent = await readFile(CONFIG_FILE, "utf-8").catch((e: NodeJS.ErrnoException) =>
    e.code === "ENOENT" ? "" : Promise.reject(e),
  );
  issues.push(...checkHeaders(headersContent, configContent));

  const securityTxtContent = await readFile(join(DIST_DIR, ".well-known", "security.txt"), "utf-8").catch(
    (e: NodeJS.ErrnoException) => (e.code === "ENOENT" ? null : Promise.reject(e)),
  );
  issues.push(...checkSecurityTxt(securityTxtContent, configContent, new Date()));
  const mtaStsContent = await readFile(join(DIST_DIR, ".well-known", "mta-sts.txt"), "utf-8").catch(
    (e: NodeJS.ErrnoException) => (e.code === "ENOENT" ? null : Promise.reject(e)),
  );
  issues.push(...checkMTAStsPolicy(mtaStsContent, configContent));

  const robotsContent = await readFile(join(DIST_DIR, "robots.txt"), "utf-8").catch(
    (e: NodeJS.ErrnoException) => (e.code === "ENOENT" ? "" : Promise.reject(e)),
  );
  const rslXmlContent = await readFile(join(DIST_DIR, "rsl.xml"), "utf-8").catch(
    (e: NodeJS.ErrnoException) => (e.code === "ENOENT" ? null : Promise.reject(e)),
  );
  const { policy: licensingPolicy } = readLicensingPolicy(process.cwd());
  const siteUrl = readConfigFromString(configContent, "SITE_URL");
  issues.push(
    ...checkRSL(
      rslActive(licensingPolicy, siteUrl),
      rslFileUrl(siteUrl),
      rslXmlContent,
      robotsContent,
      headersContent,
    ),
  );

  const sitemapContent = await readFile(join(DIST_DIR, "sitemap.xml"), "utf-8").catch(
    (e: NodeJS.ErrnoException) => (e.code === "ENOENT" ? null : Promise.reject(e)),
  );
  // Only ever two files' content is needed out of the whole walk below — the running
  // experiment's own (control) page and its variant page, if there is one — so these are
  // computed up front rather than retaining every built HTML file's content in memory (#1513
  // final review). The control page's content is only used by the client-side-goal beacon-tag
  // check (§6); every other running-experiment check only ever needed the variant's.
  const controlDistPath = runningExperimentControlDistPath(anglesiteConfigContent);
  const variantDistPath = runningExperimentVariantDistPath(anglesiteConfigContent);
  let controlHtmlContent: string | null = null;
  let variantHtmlContent: string | null = null;

  const relPaths: string[] = [];

  for await (const file of walk(DIST_DIR)) {
    if (!/\.(html?|js|css|json|xml|txt)$/i.test(file)) continue;
    const content = await readFile(file, "utf-8");
    const rel = relative(process.cwd(), file);
    relPaths.push(rel);

    issues.push(...checkPII(content, rel));
    issues.push(...checkNoRestrictedContentInDist(rel, content));

    const isHtmlOrCss = /\.(html?|css)$/i.test(file);
    if (controlDistPath !== null && rel === controlDistPath) controlHtmlContent = content;
    if (variantDistPath !== null && rel === variantDistPath) variantHtmlContent = content;
    if (isHtmlOrCss) {
      issues.push(...checkEmbedMedia(content, rel));
    }

    for (const { name, pattern } of SECRET_PATTERNS) {
      pattern.lastIndex = 0;
      if (pattern.test(content)) {
        issues.push({ severity: "error", category: "exposed-token", message: `Possible ${name} exposed`, file: rel });
      }
    }

    if (isHtmlOrCss) {
      issues.push(...checkMixedContent(content, rel));
    }

    if (/\.html?$/i.test(file)) {
      for (const pattern of BLOCKED_SCRIPTS) {
        if (pattern.test(content)) {
          issues.push({
            severity: "warning",
            category: "third-party-script",
            message: `Third-party tracking script detected: ${pattern.source}`,
            file: rel,
          });
        }
      }

      for (const pattern of BLOCKED_ROUTES) {
        if (pattern.test(content)) {
          issues.push({
            severity: "error",
            category: "keystatic-route",
            message: "Keystatic admin route found in production output",
            file: rel,
          });
        }
      }

      issues.push(...checkSRI(content, rel));
      issues.push(...checkExternalLinkRel(content, rel));
    }
  }

  issues.push(...checkArtifactPresence(relPaths));

  issues.push(
    ...checkExperiments(anglesiteConfigContent, new Set(relPaths), variantHtmlContent, sitemapContent, controlHtmlContent),
  );

  return issues;
}

async function main() {
  const issues = await scan();
  let failures = issues.filter((i) => i.severity === "error");
  let warnings = issues.filter((i) => i.severity === "warning");

  if (STRICT_MODE) {
    failures = failures.concat(warnings);
    warnings = [];
  }

  if (JSON_MODE) {
    const report: ScanReport = { version: 1, ok: failures.length === 0, failures, warnings };
    process.stdout.write(JSON.stringify(report, null, 2) + "\n");
  } else {
    if (issues.length === 0) {
      console.log("Pre-deploy check passed — no issues found.");
    } else {
      for (const issue of issues) {
        const prefix = issue.severity === "error" ? "ERROR" : "WARN";
        const loc = issue.file ? ` (${issue.file})` : "";
        console.log(`[${prefix}] ${issue.message}${loc}`);
      }
    }
  }

  process.exit(failures.length > 0 ? 1 : 0);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main();
}
