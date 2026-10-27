import test from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createRequire } from "node:module";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import * as gate from "./gate-checks";
import * as preDeploy from "./pre-deploy-check";

const here = dirname(fileURLToPath(import.meta.url));
// Resolved from this file, not the temp site the scan runs in (which has no node_modules).
const tsxCli = createRequire(import.meta.url).resolve("tsx/cli");

test("gate-checks.ts stays runtime-neutral: no imports, no Node globals", async () => {
  // The Workers-side consumers (#2055 slices 3–4) run this module outside Node, so it must not
  // reach for anything a Worker lacks. Checked against the source rather than trusted.
  const source = await readFile(join(here, "gate-checks.ts"), "utf-8");
  const code = source.replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/.*$/gm, "");
  assert.doesNotMatch(code, /^\s*import\b/m);
  assert.doesNotMatch(code, /\brequire\s*\(/);
  assert.doesNotMatch(code, /\bprocess\./);
  assert.doesNotMatch(code, /["']node:/);
});

test("pre-deploy-check re-exports the gate module's checks, not copies", () => {
  for (const name of [
    "checkSecrets",
    "checkBlockedScripts",
    "checkBlockedRoutes",
    "checkPII",
    "checkEmbedMedia",
    "checkMixedContent",
    "checkSRI",
    "checkExternalLinkRel",
    "checkNoRestrictedContentInSource",
    "checkNoRestrictedContentInDist",
  ] as const) {
    assert.equal(preDeploy[name], gate[name], name);
  }
});

test("checkBlockedScripts: warns once per matching tracker, passes clean HTML", () => {
  const html = '<script src="https://static.hotjar.com/c/hotjar-1.js"></script>'
    + '<script src="https://connect.facebook.net/en_US/fbevents.js"></script>';
  const issues = gate.checkBlockedScripts(html, "dist/index.html");
  assert.equal(issues.length, 2);
  for (const issue of issues) {
    assert.equal(issue.severity, "warning");
    assert.equal(issue.category, "third-party-script");
    assert.equal(issue.file, "dist/index.html");
  }
  assert.deepEqual(gate.checkBlockedScripts('<script src="/app.js"></script>', "dist/index.html"), []);
});

test("checkBlockedRoutes: a Keystatic admin route is an error; unrelated paths pass", () => {
  const issues = gate.checkBlockedRoutes('<a href="/keystatic/">Admin</a>', "dist/index.html");
  assert.equal(issues.length, 1);
  assert.equal(issues[0].severity, "error");
  assert.equal(issues[0].category, "keystatic-route");
  assert.equal(issues[0].message, "Keystatic admin route found in production output");
  // `/api/keystatic/` matches both patterns — one issue per matching pattern, as before extraction.
  assert.equal(gate.checkBlockedRoutes('<script src="/api/keystatic/config"></script>', "f").length, 2);
  assert.deepEqual(gate.checkBlockedRoutes('<a href="/keystatic-notes/">Notes</a>', "f"), []);
});

test("the deploy scan still reports blocked scripts and routes after the extraction", async () => {
  const site = await mkdtemp(join(tmpdir(), "gate-checks-"));
  try {
    await mkdir(join(site, "dist"), { recursive: true });
    await writeFile(
      join(site, "dist", "index.html"),
      '<!doctype html><script src="https://static.hotjar.com/c/hotjar-1.js"></script><a href="/keystatic/">x</a>',
    );
    const run = promisify(execFile);
    const result = await run(process.execPath, [tsxCli, join(here, "pre-deploy-check.ts"), "--json"], { cwd: site })
      .catch((error: { stdout?: string }) => ({ stdout: error.stdout ?? "" }));
    const report = JSON.parse(result.stdout) as {
      failures: Array<{ category: string; file?: string }>;
      warnings: Array<{ category: string; file?: string }>;
    };
    assert.ok(report.failures.some((i) => i.category === "keystatic-route" && i.file === "dist/index.html"));
    assert.ok(report.warnings.some((i) => i.category === "third-party-script" && i.file === "dist/index.html"));
  } finally {
    await rm(site, { recursive: true, force: true });
  }
});

// --- Linear-time matchers (#2054, CodeQL js/polynomial-redos) --------------------------------
// The publish gate runs these checks on writer-supplied drafts, so a pattern that goes quadratic
// on crafted input can stall a publish. Each check's regex was replaced by a linear scan; the
// oracles below are the original implementations, and the fuzz compares them output for output
// on random inputs small enough for the originals to stay fast.

/** `checkPII`'s email test before the rewrite, including its `mailto:`-link stripping. */
function oracleEmail(content: string): boolean {
  const withoutMailtoLinks = content.replace(/mailto:[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/g, "");
  return /[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/.test(withoutMailtoLinks);
}

function oracleSRI(content: string, file: string): gate.Issue[] {
  const issues: gate.Issue[] = [];
  const tagPattern = /<(script|link)\b[^>]*>/gi;
  let m: RegExpExecArray | null;
  while ((m = tagPattern.exec(content)) !== null) {
    const tag = m[0];
    const isScript = m[1].toLowerCase() === "script";
    const urlAttr = isScript ? /\bsrc\s*=\s*["'](?:https?:)?\/\//i : /\bhref\s*=\s*["'](?:https?:)?\/\//i;
    if (!urlAttr.test(tag)) continue;
    if (!isScript && !/\brel\s*=\s*["'][^"']*stylesheet/i.test(tag)) continue;
    const kind = isScript ? "script" : "stylesheet";
    if (!/\bintegrity\s*=/i.test(tag)) {
      issues.push({ severity: "warning", category: "sri-missing", message: `External ${kind} without subresource integrity (SRI)`, file });
    } else if (!/\scrossorigin\b/i.test(tag)) {
      issues.push({ severity: "warning", category: "sri-missing", message: `External ${kind} has integrity but is missing crossorigin (will fail CORS)`, file });
    }
  }
  return issues;
}

function oracleExternalLinkRel(content: string, file: string): gate.Issue[] {
  const issues: gate.Issue[] = [];
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

/** The original embed scan's hotlink count, and whether any unquoted `url(...)` value it matched
 * held a `(` — the one input shape where the linear pattern deliberately differs. */
function oracleEmbedMedia(content: string): { count: number; unquotedParen: boolean } {
  const pattern = /\b(?:src|srcset)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))|url\(\s*(?:"([^"]*)"|'([^']*)'|([^)\s]+))\s*\)/gi;
  const hosts = ["pbs.twimg.com", "cdninstagram.com"];
  let count = 0;
  let unquotedParen = false;
  let m: RegExpExecArray | null;
  while ((m = pattern.exec(content)) !== null) {
    const value = m[1] ?? m[2] ?? m[3] ?? m[4] ?? m[5] ?? m[6] ?? "";
    if (m[6]?.includes("(")) unquotedParen = true;
    if (hosts.some((h) => value.toLowerCase().includes(h))) count++;
  }
  return { count, unquotedParen };
}

/** Deterministic PRNG (mulberry32), so a failing fuzz case reproduces. */
function rng(seed: number): () => number {
  return () => {
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function fuzz(pieces: string[], seed: number, cases: number, check: (input: string) => void): void {
  const next = rng(seed);
  for (let i = 0; i < cases; i++) {
    const length = Math.floor(next() * 24);
    let input = "";
    for (let j = 0; j < length; j++) input += pieces[Math.floor(next() * pieces.length)];
    check(input);
  }
}

test("email detection matches the original regex on random inputs", () => {
  fuzz(["a", "Z", "1", ".", "-", "_", "%", "+", "@", " ", ":", "mailto:", "co", "x.io", "\n"], 1, 20000, (input) => {
    const expected = oracleEmail(input);
    const actual = gate.checkPII(input, "f").some((i) => i.category === "pii-email");
    assert.equal(actual, expected, JSON.stringify(input));
  });
});

test("SRI and link-rel scans match the original tag regexes on random inputs", () => {
  const pieces = ["<script", "<SCRIPT", "<link", "<a", "<a ", "<abbr", ">", " ", "src=\"//cdn.x/y.js\"", "href='https://x/s.css'",
    "rel=\"stylesheet\"", "integrity=\"sha\"", " crossorigin", "target=\"_blank\"", "rel='noopener'", "\"", "'", "x", "\n"];
  fuzz(pieces, 2, 20000, (input) => {
    assert.deepEqual(gate.checkSRI(input, "f"), oracleSRI(input, "f"), JSON.stringify(input));
    assert.deepEqual(gate.checkExternalLinkRel(input, "f"), oracleExternalLinkRel(input, "f"), JSON.stringify(input));
  });
});

test("Facebook-pixel detection matches the original regex on random inputs", () => {
  const pieces = ["facebook.net", "FACEBOOK.NET", "fbevents", "FbEvents", "facebook", ".net", "x", " ", "\n", "\r", " ", " "];
  fuzz(pieces, 3, 20000, (input) => {
    const expected = /facebook\.net.*fbevents/i.test(input);
    const actual = gate.checkBlockedScripts(input, "f").some((i) => i.message.includes("facebook"));
    assert.equal(actual, expected, JSON.stringify(input));
  });
});

test("embed-media detection matches the original regex on random inputs", () => {
  const pieces = ["url(", ")", "(", "\"", "'", " ", "src=", "srcset=", "https://pbs.twimg.com/a.jpg", "cdninstagram.com", "!", "x", ">"];
  fuzz(pieces, 4, 20000, (input) => {
    // An unquoted `url(...)` value holding `(` is the one intended difference: invalid CSS, and
    // exactly the shape that made the original quadratic. Whenever the original matched no such
    // value, the new pattern (a strict subset of it) finds exactly the same matches.
    const expected = oracleEmbedMedia(input);
    if (expected.unquotedParen) return;
    assert.equal(gate.checkEmbedMedia(input, "f").length, expected.count, JSON.stringify(input));
  });
});

test("every content check stays fast on adversarial input", () => {
  const size = 200_000;
  const shapes: Record<string, string> = {
    "url( + url(! repeated": "url(" + "url(!".repeat(size / 5),
    "<script with no >": "<script".repeat(size / 7),
    "<link with no >": "<link".repeat(size / 5),
    "<a with no >": "<a ".repeat(size / 3),
    "address characters, no @": "a".repeat(size),
    "a@ repeated": "a@".repeat(size / 2),
    "a@ then a long domain run": "a@" + "a".repeat(size),
    "a@a. repeated": "a@a.".repeat(size / 4),
    "facebook.net repeated": "facebook.net".repeat(size / 12),
    "facebook.net per line, fbevents at the end": "facebook.net\n".repeat(size / 13) + "fbevents",
    "facebook.net on one line, fbevents on the next": "facebook.net".repeat(size / 6) + "\nfbevents",
  };
  const checks = [gate.checkSecrets, gate.checkPII, gate.checkEmbedMedia, gate.checkMixedContent, gate.checkSRI,
    gate.checkExternalLinkRel, gate.checkBlockedScripts, gate.checkBlockedRoutes];
  for (const [name, input] of Object.entries(shapes)) {
    const started = performance.now();
    for (const check of checks) check(input, "f");
    gate.checkNoRestrictedContentInDist("f", input);
    const elapsed = performance.now() - started;
    // The quadratic originals took 2–30 s on inputs this size; linear scans take milliseconds.
    assert.ok(elapsed < 1000, `${name}: ${elapsed.toFixed(0)} ms`);
  }
});
