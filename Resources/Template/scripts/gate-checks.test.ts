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
    "checkInlineScripts",
    "inlineScriptPolicy",
    "checkInlineHandlers",
    "inlineAttributePolicy",
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

const strictPolicy = gate.inlineScriptPolicy("default-src 'self'; script-src 'self' 'sha256-AAAA'");
const strictAttributePolicy = gate.inlineAttributePolicy("default-src 'self'; script-src 'self' 'unsafe-hashes' 'sha256-AAAA'");

test("every content check stays fast on adversarial input", () => {
  const size = 200_000;
  const shapes: Record<string, string> = {
    "url( + url(! repeated": "url(" + "url(!".repeat(size / 5),
    "<script with no >": "<script".repeat(size / 7),
    "<link with no >": "<link".repeat(size / 5),
    "<script> with no closing tag": "<script>x".repeat(size / 9),
    "<script type= with no value end": "<script" + " type=".repeat(size / 6) + ">x",
    "<!-- before every <script": "<!--<script>".repeat(size / 12),
    "many scripts, one late comment": "<script src=/a.js></script>".repeat(size / 27) + "<!-- -->",
    "<script with quoted > in attributes": '<script a=">"'.repeat(size / 13) + ">",
    "<script with an unterminated quote": '<script a="' + "x".repeat(size),
    "<a with no >": "<a ".repeat(size / 3),
    "address characters, no @": "a".repeat(size),
    "a@ repeated": "a@".repeat(size / 2),
    "a@ then a long domain run": "a@" + "a".repeat(size),
    "a@a. repeated": "a@a.".repeat(size / 4),
    "facebook.net repeated": "facebook.net".repeat(size / 12),
    "facebook.net per line, fbevents at the end": "facebook.net\n".repeat(size / 13) + "fbevents",
    "facebook.net on one line, fbevents on the next": "facebook.net".repeat(size / 6) + "\nfbevents",
    "<a onclick= repeated, no >": "<a onclick=".repeat(size / 11),
    "<b onclick=x> repeated": "<b onclick=x>".repeat(size / 13),
    "<a href=javascript:x> repeated": "<a href=javascript:x>".repeat(size / 21),
    "<textarea> with no closing tag": "<textarea>".repeat(size / 10),
    "<style></style> repeated": "<style></style>".repeat(size / 15),
    "bare < repeated": "<".repeat(size),
    "<!-- with no end": "<!--" + "<a onclick=x>".repeat(size / 13),
  };
  const checks = [gate.checkSecrets, gate.checkPII, gate.checkEmbedMedia, gate.checkMixedContent, gate.checkSRI,
    gate.checkExternalLinkRel, gate.checkBlockedScripts, gate.checkBlockedRoutes];
  for (const [name, input] of Object.entries(shapes)) {
    const started = performance.now();
    for (const check of checks) check(input, "f");
    gate.checkNoRestrictedContentInDist("f", input);
    gate.checkInlineScripts(input, "f", strictPolicy, () => "");
    gate.checkInlineHandlers(input, "f", strictAttributePolicy, () => "");
    const elapsed = performance.now() - started;
    // The quadratic originals took 2–30 s on inputs this size; linear scans take milliseconds.
    assert.ok(elapsed < 1000, `${name}: ${elapsed.toFixed(0)} ms`);
  }
});

// --- Inline scripts the site's own CSP would block (#2228) ------------------------------------

const TEMPLATE_CSP =
  "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; object-src 'none'";

test("inlineScriptPolicy: reads script-src-elem, then script-src, then default-src", () => {
  assert.equal(gate.inlineScriptPolicy(TEMPLATE_CSP).allowsAll, false);
  assert.equal(gate.inlineScriptPolicy("default-src 'self' 'unsafe-inline'").allowsAll, true);
  assert.equal(gate.inlineScriptPolicy("default-src 'unsafe-inline'; script-src 'self'").allowsAll, false);
  assert.equal(gate.inlineScriptPolicy("script-src 'unsafe-inline'; script-src-elem 'self'").allowsAll, false);
  // style-src 'unsafe-inline' says nothing about scripts.
  assert.equal(gate.inlineScriptPolicy("script-src 'self'; style-src 'unsafe-inline'").allowsAll, false);
});

test("inlineScriptPolicy: no CSP, or no directive covering scripts, allows everything", () => {
  assert.equal(gate.inlineScriptPolicy(null).allowsAll, true);
  assert.equal(gate.inlineScriptPolicy("frame-ancestors 'none'").allowsAll, true);
});

test("inlineScriptPolicy: a hash, nonce or 'strict-dynamic' switches 'unsafe-inline' off", () => {
  for (const extra of ["'sha256-abc='", "'nonce-xyz'", "'strict-dynamic'"]) {
    assert.equal(gate.inlineScriptPolicy(`script-src 'self' 'unsafe-inline' ${extra}`).allowsAll, false, extra);
  }
  const policy = gate.inlineScriptPolicy("script-src 'self' 'SHA256-abc=' 'sha384-def'");
  assert.deepEqual([...policy.hashes].sort(), ["sha256-abc=", "sha384-def"]);
  assert.equal(gate.inlineScriptPolicy("script-src 'self' 'inline-speculation-rules'").allowsSpeculationRules, true);
});

test("checkInlineScripts: an inline script body is one error naming the page and the script", () => {
  const html = '<head><script>document.documentElement.dataset.theme = "dark";</script></head>';
  const issues = gate.checkInlineScripts(html, "dist/index.html", gate.inlineScriptPolicy(TEMPLATE_CSP));
  assert.equal(issues.length, 1);
  assert.equal(issues[0].severity, "error");
  assert.equal(issues[0].category, "csp-misconfigured");
  assert.equal(issues[0].file, "dist/index.html");
  assert.match(issues[0].message, /^A script on this page won't run/);
  assert.match(issues[0].message, /dataset\.theme/);
  assert.ok(issues[0].remediation);
});

test("checkInlineScripts: every executable type is checked, case-insensitively", () => {
  const policy = gate.inlineScriptPolicy(TEMPLATE_CSP);
  for (const open of [
    "<script>", "<SCRIPT>", '<script type="">', '<script type="module">', "<script type=module>",
    '<script type="text/javascript">', "<script type=' Text/JavaScript '>",
    '<script type="importmap">', '<script type="speculationrules">', '<script language="JavaScript">',
  ]) {
    assert.equal(gate.checkInlineScripts(`${open}x()</script>`, "f", policy).length, 1, open);
  }
});

test("checkInlineScripts: external scripts, data blocks and empty bodies pass", () => {
  const policy = gate.inlineScriptPolicy(TEMPLATE_CSP);
  for (const html of [
    '<script type="module" src="/pagefind/pagefind-component-ui.js"></script>',
    "<script src=/a.js>ignored()</script>",
    '<script type="application/ld+json">{"@context":"https://schema.org"}</script>',
    '<script type="application/json" id="data">{"a":1}</script>',
    '<script type="text/template"><p>{{x}}</p></script>',
    '<script language="vbscript">x</script>',
    "<script>   \n  </script>",
    // A MIME type with parameters isn't a JavaScript MIME type essence match (HTML §4.12.1).
    '<script type="text/javascript; charset=utf-8">x()</script>',
    // A `>` inside a quoted attribute value doesn't end the tag, so `src` is still seen.
    '<script data-cfg="a>b" src="/x.js"></script>',
  ]) {
    assert.deepEqual(gate.checkInlineScripts(html, "f", policy), [], html);
  }
});

test("checkInlineScripts: counts every blocked script on a page in its one error", () => {
  const html = "<script>a()</script><p>text</p><script>b()</script><script src=/c.js></script>";
  const [issue] = gate.checkInlineScripts(html, "f", gate.inlineScriptPolicy(TEMPLATE_CSP));
  assert.match(issue.message, /^2 scripts on this page/);
  assert.match(issue.message, /"a\(\)"/);
});

test("checkInlineScripts: a <script inside a script's own string isn't a second element", () => {
  const html = '<script>document.write("<script src=x></" + "script>")</script>';
  const [issue] = gate.checkInlineScripts(html, "f", gate.inlineScriptPolicy(TEMPLATE_CSP));
  assert.match(issue.message, /^A script on this page/);
});

test("checkInlineScripts: 'unsafe-inline' or allowed speculation rules pass", () => {
  const html = "<script>a()</script>";
  assert.deepEqual(gate.checkInlineScripts(html, "f", gate.inlineScriptPolicy("script-src 'self' 'unsafe-inline'")), []);


  const speculation = '<script type="speculationrules">{"prerender":[{"where":{"href_matches":"/*"}}]}</script>';
  assert.equal(gate.checkInlineScripts(speculation, "f", gate.inlineScriptPolicy(TEMPLATE_CSP)).length, 1);
  assert.deepEqual(
    gate.checkInlineScripts(speculation, "f", gate.inlineScriptPolicy("script-src 'self' 'inline-speculation-rules'")),
    [],
  );
});

test("checkInlineScripts: a real sha256 hash in the CSP allows exactly that script", () => {
  const body = "a()";
  const digest = preDeploy.cspScriptHash("sha256", body);
  const policy = gate.inlineScriptPolicy(`script-src 'self' 'sha256-${digest}'`);
  assert.deepEqual(gate.checkInlineScripts(`<script>${body}</script>`, "f", policy, preDeploy.cspScriptHash), []);
  assert.equal(gate.checkInlineScripts("<script>a() </script>", "f", policy, preDeploy.cspScriptHash).length, 1);
  // Without a hasher the hash can't be verified, so the script is reported.
  assert.equal(gate.checkInlineScripts(`<script>${body}</script>`, "f", policy).length, 1);
});

test("the deploy scan blocks an inline script against the served CSP, and passes 'unsafe-inline'", async () => {
  const run = promisify(execFile);
  const scan = async (csp: string) => {
    const site = await mkdtemp(join(tmpdir(), "gate-inline-"));
    try {
      await mkdir(join(site, "dist"), { recursive: true });
      await writeFile(join(site, "dist", "_headers"), `/*\n  Content-Security-Policy: ${csp}\n`);
      await writeFile(join(site, "dist", "index.html"), "<!doctype html><script>a()</script>");
      const result = await run(process.execPath, [tsxCli, join(here, "pre-deploy-check.ts"), "--json"], { cwd: site })
        .catch((error: { stdout?: string }) => ({ stdout: error.stdout ?? "" }));
      return JSON.parse(result.stdout) as { failures: Array<{ category: string; file?: string; message: string }> };
    } finally {
      await rm(site, { recursive: true, force: true });
    }
  };
  const strict = await scan(TEMPLATE_CSP);
  assert.ok(strict.failures.some((i) => i.file === "dist/index.html" && /won't run once published/.test(i.message)));
  const lax = await scan("default-src 'self'; script-src 'self' 'unsafe-inline'");
  assert.ok(!lax.failures.some((i) => /won't run once published/.test(i.message)));
});

test("checkInlineScripts: an src= inside another attribute's value isn't an src attribute", () => {
  const html = '<script data-note="src=/x.js">a()</script>';
  assert.equal(gate.checkInlineScripts(html, "f", gate.inlineScriptPolicy(TEMPLATE_CSP)).length, 1);
});

test("checkInlineScripts: custom elements named script-* are not scripts", () => {
  // Review repro on #2229: the opener used to match <script-loader> and run on to the next
  // real </script>, taking the markup in between as an inline body.
  const html = '<script-loader>hello</script-loader><script src="/a.js"></script>';
  assert.deepEqual(gate.checkInlineScripts(html, "f", gate.inlineScriptPolicy("script-src 'self'")), []);
  // A real inline script after one is still found, and closing tags with attributes or spaces end it.
  const both = "<script-x>y</script-x><script>a()</script ><script\tsrc=/b.js></script>";
  assert.equal(gate.checkInlineScripts(both, "f", gate.inlineScriptPolicy("script-src 'self'")).length, 1);
});

test("checkInlineScripts: commented-out scripts are skipped, live ones after them are not", () => {
  const policy = gate.inlineScriptPolicy("script-src 'self'");
  assert.deepEqual(gate.checkInlineScripts("<!-- <script>alert(1)</script> -->", "f", policy), []);
  assert.deepEqual(gate.checkInlineScripts("<!-- unterminated <script>alert(1)</script>", "f", policy), []);
  const [issue] = gate.checkInlineScripts("<!-- <script>old()</script> --><script>live()</script>", "f", policy);
  assert.match(issue.message, /"live\(\)"/);
});

test("checkInlineScripts: a CRLF script matches the hash of its LF-normalized text", () => {
  // Review repro on #2229: the browser hashes the tokenizer's LF-normalized text, not raw bytes.
  const digest = preDeploy.cspScriptHash("sha256", "a();\nb();");
  const policy = gate.inlineScriptPolicy(`script-src 'self' 'sha256-${digest}'`);
  for (const body of ["a();\r\nb();", "a();\rb();", "a();\nb();"]) {
    assert.deepEqual(gate.checkInlineScripts(`<script>${body}</script>`, "f", policy, preDeploy.cspScriptHash), [], JSON.stringify(body));
  }
});

// --- Inline event handlers and javascript: URLs the site's own CSP would block (#2232) --------

test("inlineAttributePolicy: script-src-attr governs handlers, script-src-elem javascript: URLs", () => {
  const template = gate.inlineAttributePolicy(TEMPLATE_CSP);
  assert.equal(template.handlersAllowAll, false);
  assert.equal(template.javascriptURLsAllowAll, false);
  const attrOnly = gate.inlineAttributePolicy("script-src 'self'; script-src-attr 'unsafe-inline'");
  assert.equal(attrOnly.handlersAllowAll, true);
  assert.equal(attrOnly.javascriptURLsAllowAll, false);
  const elemOnly = gate.inlineAttributePolicy("script-src 'self'; script-src-elem 'unsafe-inline'");
  assert.equal(elemOnly.handlersAllowAll, false);
  assert.equal(elemOnly.javascriptURLsAllowAll, true);
  assert.equal(gate.inlineAttributePolicy(null).handlersAllowAll, true);
  assert.equal(gate.inlineAttributePolicy("frame-ancestors 'none'").javascriptURLsAllowAll, true);
});

test("inlineAttributePolicy: a hash allows a handler only alongside 'unsafe-hashes'", () => {
  assert.equal(gate.inlineAttributePolicy("script-src 'self' 'sha256-abc='").handlerHashes.size, 0);
  assert.deepEqual([...gate.inlineAttributePolicy("script-src 'self' 'unsafe-hashes' 'sha256-abc='").handlerHashes], ["sha256-abc="]);
  // A hash still switches 'unsafe-inline' off.
  assert.equal(gate.inlineAttributePolicy("script-src 'unsafe-inline' 'sha256-abc='").handlersAllowAll, false);
});

test("checkInlineHandlers: a real <button onclick> is one error naming the page and the handler", () => {
  const html = '<button type="button" onclick="toggleMenu()">Menu</button>';
  const issues = gate.checkInlineHandlers(html, "dist/index.html", gate.inlineAttributePolicy(TEMPLATE_CSP));
  assert.equal(issues.length, 1);
  assert.equal(issues[0].severity, "error");
  assert.equal(issues[0].category, "csp-misconfigured");
  assert.equal(issues[0].file, "dist/index.html");
  assert.match(issues[0].message, /^A piece of JavaScript written into this page's HTML won't run/);
  assert.match(issues[0].message, /<button onclick="toggleMenu\(\)">/);
  assert.ok(issues[0].remediation);
});

test("checkInlineHandlers: javascript: URLs are reported however they're written", () => {
  const policy = gate.inlineAttributePolicy(TEMPLATE_CSP);
  for (const html of [
    '<a href="javascript:openChat()">Chat</a>',
    "<a HREF='JavaScript:openChat()'>",
    '<a href=" javascript:openChat()">',
    '<a href="java\tscript:openChat()">',
    '<a href="javascript&#58;openChat()">',
    '<a href="javascript&colon;openChat()">',
    '<form action="javascript:send()"></form>',
    '<button formaction="javascript:send()">',
    '<iframe src="javascript:draw()"></iframe>',
    '<svg><a xlink:href="javascript:go()"><text>x</text></a></svg>',
  ]) {
    assert.equal(gate.checkInlineHandlers(html, "f", policy).length, 1, html);
  }
});

test("checkInlineHandlers: ESI directives, data-on*, quoted values, comments and raw text pass", () => {
  const policy = gate.inlineAttributePolicy(TEMPLATE_CSP);
  for (const html of [
    // The template's own ESI component output: an edge directive, not a DOM event handler.
    '<esi:include src="/fragments/count" onerror="continue"/>',
    '<button data-onclick="toggleMenu">Menu</button>',
    '<div title="onclick=alert(1)">x</div>',
    '<div title=\'<a onclick="x()">\'>x</div>',
    '<!-- <button onclick="old()">x</button> -->',
    '<script>document.body.innerHTML = \'<b onclick="x()">\';</script>',
    '<textarea><a href="javascript:x()">sample</a></textarea>',
    '<style>/* <a onclick="x()"> */</style>',
    '<noscript><a href="javascript:x()">x</a></noscript>',
    '<button onclick="">x</button>',
    // No-op placeholders: blocked or not, clicking them does nothing.
    '<a href="javascript:void(0)">x</a>',
    '<a href="javascript:void 0;">x</a>',
    '<a href="javascript:;">x</a>',
    '<a href="javascript:">x</a>',
    '<a href="/javascript:x">x</a>',
    "<p>Use onclick=\"x()\" sparingly &lt;a onclick=x&gt;</p>",
  ]) {
    assert.deepEqual(gate.checkInlineHandlers(html, "f", policy), [], html);
  }
});

test("checkInlineHandlers: handlers on custom elements and SVG are checked; live ones after raw text are found", () => {
  const policy = gate.inlineAttributePolicy(TEMPLATE_CSP);
  assert.equal(gate.checkInlineHandlers('<my-widget onclick="go()"></my-widget>', "f", policy).length, 1);
  assert.equal(gate.checkInlineHandlers('<svg onload="draw()"></svg>', "f", policy).length, 1);
  assert.equal(gate.checkInlineHandlers('<script onload="ready()" src="/a.js"></script>', "f", policy).length, 1);
  const html = '<script>"<b onclick=x>"</script><textarea>t</textarea><img src=a.png onerror="fallback(this)">';
  const [issue] = gate.checkInlineHandlers(html, "f", policy);
  assert.match(issue.message, /<img onerror="fallback\(this\)">/);
});

test("checkInlineHandlers: counts every blocked attribute on a page in its one error", () => {
  const html = '<body onload="init()"><a href="javascript:openChat()">x</a><button onclick="a()">y</button>';
  const issues = gate.checkInlineHandlers(html, "f", gate.inlineAttributePolicy(TEMPLATE_CSP));
  assert.equal(issues.length, 1);
  assert.match(issues[0].message, /^3 pieces of JavaScript/);
  assert.match(issues[0].message, /<body onload="init\(\)">/);
});

test("checkInlineHandlers: 'unsafe-inline' allows them; 'unsafe-hashes' + a matching hash allows that handler", () => {
  const html = '<button onclick="a()">x</button>';
  assert.deepEqual(gate.checkInlineHandlers(html, "f", gate.inlineAttributePolicy("script-src 'self' 'unsafe-inline'")), []);
  const digest = preDeploy.cspScriptHash("sha256", "a()");
  const hashed = gate.inlineAttributePolicy(`script-src 'self' 'unsafe-hashes' 'sha256-${digest}'`);
  assert.deepEqual(gate.checkInlineHandlers(html, "f", hashed, preDeploy.cspScriptHash), []);
  // Character references are decoded before hashing, as the browser does.
  const quoted = preDeploy.cspScriptHash("sha256", 'a("x")');
  const quotedPolicy = gate.inlineAttributePolicy(`script-src 'self' 'unsafe-hashes' 'sha256-${quoted}'`);
  assert.deepEqual(gate.checkInlineHandlers('<b onclick="a(&quot;x&quot;)">', "f", quotedPolicy, preDeploy.cspScriptHash), []);
  assert.equal(gate.checkInlineHandlers('<button onclick="b()">x</button>', "f", hashed, preDeploy.cspScriptHash).length, 1);
  // Without 'unsafe-hashes' the same hash doesn't allow the handler.
  const noUnsafeHashes = gate.inlineAttributePolicy(`script-src 'self' 'sha256-${digest}'`);
  assert.equal(gate.checkInlineHandlers(html, "f", noUnsafeHashes, preDeploy.cspScriptHash).length, 1);
  // A hash never allows a javascript: URL.
  assert.equal(gate.checkInlineHandlers('<a href="javascript:a()">x</a>', "f", hashed, preDeploy.cspScriptHash).length, 1);
});

test("the deploy scan blocks an inline handler against the served CSP, and passes the ESI directive", async () => {
  const run = promisify(execFile);
  const site = await mkdtemp(join(tmpdir(), "gate-handler-"));
  try {
    await mkdir(join(site, "dist"), { recursive: true });
    await writeFile(join(site, "dist", "_headers"), `/*\n  Content-Security-Policy: ${TEMPLATE_CSP}\n`);
    await writeFile(join(site, "dist", "index.html"), '<!doctype html><button onclick="a()">x</button>');
    await writeFile(join(site, "dist", "esi.html"), '<!doctype html><esi:include src="/f" onerror="continue"/>');
    const result = await run(process.execPath, [tsxCli, join(here, "pre-deploy-check.ts"), "--json"], { cwd: site })
      .catch((error: { stdout?: string }) => ({ stdout: error.stdout ?? "" }));
    const { failures } = JSON.parse(result.stdout) as { failures: Array<{ file?: string; message: string }> };
    const handlerFailures = failures.filter((i) => /written into this page's HTML/.test(i.message));
    assert.deepEqual(handlerFailures.map((i) => i.file), ["dist/index.html"]);
  } finally {
    await rm(site, { recursive: true, force: true });
  }
});
