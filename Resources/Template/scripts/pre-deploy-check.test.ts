import test from "node:test";
import assert from "node:assert/strict";
import {
  checkHeaders,
  checkMixedContent,
  checkSRI,
  checkExternalLinkRel,
  checkArtifactPresence,
  checkPII,
  checkMTAStsPolicy,
  checkSecurityTxt,
  checkEmbedMedia,
  checkAnglesiteConfig,
  checkExperiments,
  checkRSL,
  checkNoRestrictedContentInSource,
  checkNoRestrictedContentInDist,
  runningExperimentControlDistPath,
  runningExperimentVariantDistPath,
} from "./pre-deploy-check";
import { MTA_STS_MARKER, SECURITY_TXT_MARKER } from "./edge-artifacts";
import { GOAL_BEACON_SCRIPT_PATH } from "./experiments-paths";

const GOOD = `/*
  Content-Security-Policy: default-src 'self'; frame-src 'self' js.stripe.com
`;

test("missing _headers is an error", () => {
  const issues = checkHeaders(null, "");
  assert.equal(issues.length, 1);
  assert.equal(issues[0].severity, "error");
  assert.equal(issues[0].category, "csp-misconfigured");
  assert.match(issues[0].message, /not enforced/);
});

test("_headers without a CSP is an error", () => {
  const issues = checkHeaders("/*\n  X-Frame-Options: DENY\n", "");
  assert.equal(issues.length, 1);
  assert.equal(issues[0].category, "csp-misconfigured");
  assert.match(issues[0].message, /no Content-Security-Policy/);
});

test("configured domain missing from CSP is an error naming the domain", () => {
  const issues = checkHeaders(GOOD, "SCRIPT_ALLOW=js.stripe.com,giscus.app");
  assert.equal(issues.length, 1);
  assert.equal(issues[0].category, "csp-misconfigured");
  assert.match(issues[0].message, /giscus\.app/);
});

test("CSP covering all configured domains passes", () => {
  assert.deepEqual(checkHeaders(GOOD, "SCRIPT_ALLOW=js.stripe.com"), []);
});

test("no SCRIPT_ALLOW: a present CSP passes", () => {
  assert.deepEqual(checkHeaders(GOOD, ""), []);
});

test("multiple configured domains missing from CSP each produce an error", () => {
  const issues = checkHeaders(GOOD, "SCRIPT_ALLOW=giscus.app,assets.calendly.com");
  assert.equal(issues.length, 2);
  assert.ok(issues.every((i) => i.severity === "error"));
  assert.ok(issues.every((i) => i.category === "csp-misconfigured"));
  assert.ok(issues.some((i) => /giscus\.app/.test(i.message)));
  assert.ok(issues.some((i) => /assets\.calendly\.com/.test(i.message)));
});

test("substring of an allowed domain does not satisfy coverage", () => {
  const headers = `/*\n  Content-Security-Policy: default-src 'self'; frame-src 'self' app.cal.com\n`;
  const issues = checkHeaders(headers, "SCRIPT_ALLOW=cal.com");
  assert.equal(issues.length, 1);
  assert.equal(issues[0].severity, "error");
  assert.match(issues[0].message, /cal\.com/);
});

test("checkPII: flags a bare email in page content", () => {
  const issues = checkPII("<p>Contact us at hello@example.com</p>", "dist/index.html");
  assert.equal(issues.length, 1);
  assert.equal(issues[0].severity, "error");
  assert.equal(issues[0].category, "pii-email");
  assert.match(issues[0].message, /email/);
});

test("checkPII: does not flag an email that only appears as a mailto: link target", () => {
  const issues = checkPII('<a href="mailto:hello@example.com">Email us</a>', "dist/contact.html");
  assert.deepEqual(issues, []);
});

test("checkPII: still flags a bare email elsewhere on a page that also has a mailto link", () => {
  const html = '<a href="mailto:hello@example.com">Email us</a><p>debug: admin@internal.example.com</p>';
  const issues = checkPII(html, "dist/contact.html");
  assert.equal(issues.length, 1);
  assert.equal(issues[0].category, "pii-email");
  assert.match(issues[0].message, /email/);
});

test("checkPII: still flags phone numbers regardless of mailto content", () => {
  const issues = checkPII('<a href="mailto:hello@example.com">Email</a> Call 555-123-4567', "dist/contact.html");
  assert.equal(issues.length, 1);
  assert.equal(issues[0].category, "pii-phone");
  assert.match(issues[0].message, /phone/);
});

test("checkPII: flags an SSN with the pii-ssn category", () => {
  const issues = checkPII("<p>SSN: 123-45-6789</p>", "dist/contact.html");
  assert.equal(issues.length, 1);
  assert.equal(issues[0].category, "pii-ssn");
});

test("checkNoRestrictedContentInSource: flags YAML frontmatter visibility: contacts", () => {
  const file = "src/content/notes/leaked.md";
  const content = "---\npublishDate: 2026-08-18\nvisibility: contacts\n---\nBody text.\n";
  const issues = checkNoRestrictedContentInSource(file, content);
  assert.equal(issues.length, 1);
  assert.equal(issues[0].severity, "error");
  assert.equal(issues[0].category, "restricted-content-in-source");
  assert.equal(issues[0].file, file);
});

test("checkNoRestrictedContentInSource: flags a quoted visibility value too", () => {
  const content = '---\nvisibility: "contacts"\n---\nBody.\n';
  const issues = checkNoRestrictedContentInSource("src/content/notes/leaked.md", content);
  assert.equal(issues.length, 1);
});

test("checkNoRestrictedContentInSource: does not flag ordinary content with no visibility field", () => {
  const content = "---\npublishDate: 2026-08-18\ntags: [\"hello\"]\n---\nThis is your first note.\n";
  const issues = checkNoRestrictedContentInSource("src/content/notes/hello-note.md", content);
  assert.deepEqual(issues, []);
});

test("checkNoRestrictedContentInSource: does not flag public visibility", () => {
  const content = "---\nvisibility: public\n---\nBody.\n";
  const issues = checkNoRestrictedContentInSource("src/content/notes/hello-note.md", content);
  assert.deepEqual(issues, []);
});

test("checkNoRestrictedContentInDist: flags a leaked mf2 JSON property array in built output", () => {
  const file = "dist/notes/leaked/index.html";
  const content = '<script type="application/json">{"properties":{"visibility":["contacts"]}}</script>';
  const issues = checkNoRestrictedContentInDist(file, content);
  assert.equal(issues.length, 1);
  assert.equal(issues[0].severity, "error");
  assert.equal(issues[0].category, "restricted-content-in-dist");
  assert.equal(issues[0].file, file);
});

test("checkNoRestrictedContentInDist: flags a JSON string form", () => {
  const content = '{"visibility":"contacts"}';
  const issues = checkNoRestrictedContentInDist("dist/api/posts.json", content);
  assert.equal(issues.length, 1);
});

test("checkNoRestrictedContentInDist: does not flag ordinary built HTML", () => {
  const content = "<html><body><p>Hello world.</p></body></html>";
  const issues = checkNoRestrictedContentInDist("dist/index.html", content);
  assert.deepEqual(issues, []);
});

test("checkNoRestrictedContentInDist: does not flag public visibility", () => {
  const content = '{"visibility":"public"}';
  const issues = checkNoRestrictedContentInDist("dist/api/posts.json", content);
  assert.deepEqual(issues, []);
});

// Pagefind's UI bundle embeds its translators' contact addresses as `thanks_to` credits. Those
// are the dependency's own attribution, not the site owner's data escaping into the build, and
// the owner authors nothing under dist/pagefind/ — so the email pattern would only ever fire
// there as a false positive that blocks every deploy (#974).
test("checkPII: does not flag emails inside a vendored search-index bundle", () => {
  const bundle = 'var pa="Jan Claasen <jan@cloudcannon.com>",Ba="",ha="ltr"';
  assert.deepEqual(checkPII(bundle, "dist/pagefind/pagefind-component-ui.js"), []);
});

test("checkPII: the vendored exemption covers emails only", () => {
  const bundle = 'thanks_to="Jan Claasen <jan@cloudcannon.com>"; support="555-123-4567"';
  const issues = checkPII(bundle, "dist/pagefind/pagefind-ui.js");
  assert.equal(issues.length, 1);
  assert.equal(issues[0].category, "pii-phone");
});

// The exemption is anchored to the vendored directory, not matched loosely anywhere in the
// path — an owner-authored page merely named "pagefind" stays fully scanned.
test("checkPII: the vendored exemption does not leak to owner-authored paths", () => {
  const issues = checkPII("<p>hello@example.com</p>", "dist/blog/pagefind/index.html");
  assert.equal(issues.length, 1);
  assert.equal(issues[0].category, "pii-email");
});

test("checkMixedContent: flags an insecure src", () => {
  const issues = checkMixedContent('<img src="http://example.com/a.png">', "dist/index.html");
  assert.equal(issues.length, 1);
  assert.equal(issues[0].severity, "warning");
  assert.equal(issues[0].category, "mixed-content");
  assert.match(issues[0].message, /mixed content/i);
  assert.equal(issues[0].file, "dist/index.html");
});

test("checkMixedContent: flags an insecure url() in CSS", () => {
  const issues = checkMixedContent("body { background: url(http://x.com/bg.png); }", "dist/a.css");
  assert.equal(issues.length, 1);
});

test("checkMixedContent: https and relative refs are clean", () => {
  const ok = '<img src="https://x.com/a.png"><script src="/local.js"></script>';
  assert.deepEqual(checkMixedContent(ok, "dist/index.html"), []);
});

test("checkMixedContent: svg xmlns http URL is not flagged", () => {
  const svg = '<svg xmlns="http://www.w3.org/2000/svg"></svg>';
  assert.deepEqual(checkMixedContent(svg, "dist/index.html"), []);
});

test("checkMixedContent: at most one issue per file", () => {
  const two = '<img src="http://a.com/1.png"><img src="http://b.com/2.png">';
  assert.equal(checkMixedContent(two, "dist/index.html").length, 1);
});

test("checkSRI: external script without integrity is a warning", () => {
  const issues = checkSRI('<script src="https://cdn.x.com/a.js"></script>', "dist/index.html");
  assert.equal(issues.length, 1);
  assert.equal(issues[0].severity, "warning");
  assert.equal(issues[0].category, "sri-missing");
  assert.match(issues[0].message, /integrity/i);
});

test("checkSRI: external script with integrity AND crossorigin is clean", () => {
  const ok = '<script src="https://cdn.x.com/a.js" integrity="sha384-abc" crossorigin="anonymous"></script>';
  assert.deepEqual(checkSRI(ok, "dist/index.html"), []);
});

test("checkSRI: integrity without crossorigin is a warning (CORS would block it)", () => {
  const issues = checkSRI('<script src="https://cdn.x.com/a.js" integrity="sha384-abc"></script>', "dist/index.html");
  assert.equal(issues.length, 1);
  assert.match(issues[0].message, /crossorigin/i);
});

test("checkSRI: relative script is clean", () => {
  assert.deepEqual(checkSRI('<script src="/local.js"></script>', "dist/index.html"), []);
});

test("checkSRI: external stylesheet link without integrity is a warning", () => {
  const issues = checkSRI('<link rel="stylesheet" href="https://cdn.x.com/a.css">', "dist/index.html");
  assert.equal(issues.length, 1);
});

test("checkSRI: non-stylesheet link is ignored", () => {
  assert.deepEqual(checkSRI('<link rel="preconnect" href="https://x.com">', "dist/index.html"), []);
});

test("checkExternalLinkRel: target=_blank without rel=noopener is a warning", () => {
  const issues = checkExternalLinkRel('<a href="https://x.com" target="_blank">x</a>', "dist/index.html");
  assert.equal(issues.length, 1);
  assert.equal(issues[0].severity, "warning");
  assert.equal(issues[0].category, "external-link-rel");
  assert.match(issues[0].message, /noopener/i);
});

test("checkExternalLinkRel: rel=noopener is clean", () => {
  const ok = '<a href="https://x.com" target="_blank" rel="noopener">x</a>';
  assert.deepEqual(checkExternalLinkRel(ok, "dist/index.html"), []);
});

test("checkExternalLinkRel: rel with noopener among others is clean", () => {
  const ok = '<a href="https://x.com" target="_blank" rel="noopener noreferrer">x</a>';
  assert.deepEqual(checkExternalLinkRel(ok, "dist/index.html"), []);
});

test("checkExternalLinkRel: rel=noreferrer alone is clean (implies noopener)", () => {
  const ok = '<a href="https://x.com" target="_blank" rel="noreferrer">x</a>';
  assert.deepEqual(checkExternalLinkRel(ok, "dist/index.html"), []);
});

test("checkExternalLinkRel: link without target=_blank is ignored", () => {
  assert.deepEqual(checkExternalLinkRel('<a href="https://x.com">x</a>', "dist/index.html"), []);
});

test("checkArtifactPresence: robots.txt present is clean", () => {
  const paths = ["dist/index.html", "dist/robots.txt", "dist/.well-known/security.txt"];
  assert.deepEqual(checkArtifactPresence(paths), []);
});

test("checkArtifactPresence: missing robots.txt is a warning", () => {
  const issues = checkArtifactPresence(["dist/index.html", "dist/.well-known/security.txt"]);
  assert.equal(issues.length, 1);
  assert.equal(issues[0].severity, "warning");
  assert.equal(issues[0].category, "missing-security-artifact");
  assert.match(issues[0].message, /robots\.txt/);
});

test("checkArtifactPresence: security.txt presence/absence is not this check's concern (see checkSecurityTxt)", () => {
  assert.deepEqual(checkArtifactPresence(["dist/index.html", "dist/robots.txt"]), []);
});

test("checkArtifactPresence: backslash paths are normalized", () => {
  const paths = ["dist\\robots.txt"];
  assert.deepEqual(checkArtifactPresence(paths), []);
});

test("--strict promotes warnings into failures for exit-code purposes (unit-level check on the promotion helper)", () => {
  // checkArtifactPresence always returns warnings (missing-security-artifact) — this test
  // documents the contract main() relies on: in --strict mode, ALL warnings (not just this
  // category) become failures. The end-to-end exit-code behavior is covered by the real-script
  // fixture tests in PreDeployCheckFixtureTests.swift (Swift side, #799 Task 3), since --strict's
  // effect lives in main()'s promotion logic, not in an exported pure function.
  const warnings = checkArtifactPresence([]);
  assert.equal(warnings.length, 1);
  assert.ok(warnings.every((w) => w.severity === "warning"));
});

const NOW = new Date("2026-07-20T12:00:00Z");

function validSecurityTxt(): string {
  return `${SECURITY_TXT_MARKER}\nContact: mailto:security@example.com\nExpires: 2027-01-01T00:00:00.000Z\nCanonical: https://example.com/.well-known/security.txt\n`;
}

test("checkSecurityTxt: disabled mode with no file is silent", () => {
  assert.deepEqual(checkSecurityTxt(null, "SECURITY_TXT_MODE=disabled", NOW), []);
});

test("checkSecurityTxt: disabled mode with a published file is a contradiction", () => {
  const issues = checkSecurityTxt("Contact: mailto:s@example.com\n", "SECURITY_TXT_MODE=disabled", NOW);
  assert.equal(issues.length, 1);
  assert.equal(issues[0].category, "security-txt-issue");
  assert.match(issues[0].message, /disabled but .* was published/);
});

test("checkSecurityTxt: generated mode with a valid, marker-owned file passes silently", () => {
  const config = "SECURITY_TXT_MODE=generated\nSECURITY_CONTACT=security@example.com\nSITE_URL=https://example.com";
  assert.deepEqual(checkSecurityTxt(validSecurityTxt(), config, NOW), []);
});

test("checkSecurityTxt: generated mode with an unmarked (not-ours) file is a contradiction", () => {
  const config = "SECURITY_TXT_MODE=generated\nSECURITY_CONTACT=security@example.com";
  const issues = checkSecurityTxt("Contact: mailto:hand-authored@example.com\n", config, NOW);
  assert.equal(issues.length, 1);
  assert.match(issues[0].message, /wasn't generated by Anglesite/);
});

test("checkSecurityTxt: generated mode missing the file is a finding", () => {
  const config = "SECURITY_TXT_MODE=generated\nSECURITY_CONTACT=security@example.com";
  const issues = checkSecurityTxt(null, config, NOW);
  assert.equal(issues.length, 1);
  assert.match(issues[0].message, /is missing/);
});

test("checkSecurityTxt: manual mode with a valid hand-authored file passes silently", () => {
  const config = "SECURITY_TXT_MODE=manual";
  const content = "Contact: mailto:security@example.com\nExpires: 2027-01-01T00:00:00.000Z\n";
  assert.deepEqual(checkSecurityTxt(content, config, NOW), []);
});

test("checkSecurityTxt: manual mode missing the file is a finding", () => {
  assert.equal(checkSecurityTxt(null, "SECURITY_TXT_MODE=manual", NOW).length, 1);
});

test("checkSecurityTxt: missing Contact is a finding", () => {
  const content = "Expires: 2027-01-01T00:00:00.000Z\n";
  const issues = checkSecurityTxt(content, "SECURITY_TXT_MODE=manual", NOW);
  assert.ok(issues.some((i) => /no Contact field/.test(i.message)));
});

test("checkSecurityTxt: zero or multiple Expires fields is a finding", () => {
  const zero = checkSecurityTxt("Contact: mailto:s@example.com\n", "SECURITY_TXT_MODE=manual", NOW);
  assert.ok(zero.some((i) => /exactly one Expires/.test(i.message)));
  const two = checkSecurityTxt(
    "Contact: mailto:s@example.com\nExpires: 2027-01-01T00:00:00.000Z\nExpires: 2028-01-01T00:00:00.000Z\n",
    "SECURITY_TXT_MODE=manual",
    NOW,
  );
  assert.ok(two.some((i) => /exactly one Expires/.test(i.message)));
});

test("checkSecurityTxt: an Expires date in the past is stale", () => {
  const content = "Contact: mailto:s@example.com\nExpires: 2020-01-01T00:00:00.000Z\n";
  const issues = checkSecurityTxt(content, "SECURITY_TXT_MODE=manual", NOW);
  assert.ok(issues.some((i) => /stale/.test(i.message)));
});

test("checkSecurityTxt: an unparseable Expires value is a finding", () => {
  const content = "Contact: mailto:s@example.com\nExpires: not-a-date\n";
  const issues = checkSecurityTxt(content, "SECURITY_TXT_MODE=manual", NOW);
  assert.ok(issues.some((i) => /not a valid date/.test(i.message)));
});

test("checkSecurityTxt: a Canonical whose origin doesn't match SITE_URL is a finding", () => {
  const config = "SECURITY_TXT_MODE=manual\nSITE_URL=https://example.com";
  const content = "Contact: mailto:s@example.com\nExpires: 2027-01-01T00:00:00.000Z\nCanonical: https://wrong-origin.example/.well-known/security.txt\n";
  const issues = checkSecurityTxt(content, config, NOW);
  assert.ok(issues.some((i) => /does not match SITE_URL/.test(i.message)));
});

test("checkSecurityTxt: an insecure http:// Canonical is a finding", () => {
  const content = "Contact: mailto:s@example.com\nExpires: 2027-01-01T00:00:00.000Z\nCanonical: http://example.com/.well-known/security.txt\n";
  const issues = checkSecurityTxt(content, "SECURITY_TXT_MODE=manual", NOW);
  assert.ok(issues.some((i) => /must be a valid HTTPS URL/.test(i.message)));
});

test("checkSecurityTxt: an unrecognized SECURITY_TXT_MODE value is flagged and falls back to inference", () => {
  const config = "SECURITY_TXT_MODE=Generated\nSECURITY_CONTACT=security@example.com";
  const issues = checkSecurityTxt(null, config, NOW);
  // No usable contact-matching content published, and the typo'd mode still infers "generated"
  // (SECURITY_CONTACT is set) — so both the typo finding and the missing-file finding fire.
  assert.ok(issues.some((i) => /not a recognized value/.test(i.message)));
  assert.ok(issues.some((i) => /is missing/.test(i.message)));
});

test("checkSecurityTxt: an unrecognized mode is still flagged even when disabled-inferred and absent", () => {
  const issues = checkSecurityTxt(null, "SECURITY_TXT_MODE=bogus", NOW);
  assert.equal(issues.length, 1);
  assert.match(issues[0].message, /not a recognized value/);
});

test("checkSecurityTxt: an empty SECURITY_TXT_MODE value is treated as unset, not a typo", () => {
  assert.deepEqual(checkSecurityTxt(null, "SECURITY_TXT_MODE=", NOW), []);
});

test("checkSecurityTxt: missing final newline is a finding", () => {
  const content = "Contact: mailto:s@example.com\nExpires: 2027-01-01T00:00:00.000Z";
  const issues = checkSecurityTxt(content, "SECURITY_TXT_MODE=manual", NOW);
  assert.ok(issues.some((i) => /final newline/.test(i.message)));
});

const validMTASts = () => `version: STSv1\nmode: testing\nmx: mx.example.com\nmax_age: 604800\n${MTA_STS_MARKER}\n`;

test("checkMTAStsPolicy: disabled and absent is clean, but a published policy is a contradiction", () => {
  assert.deepEqual(checkMTAStsPolicy(null, "MTA_STS_MODE=disabled"), []);
  assert.equal(checkMTAStsPolicy(validMTASts(), "MTA_STS_MODE=disabled").length, 1);
});

test("checkMTAStsPolicy: a generated testing policy with an MX host is clean", () => {
  assert.deepEqual(checkMTAStsPolicy(validMTASts(), "MTA_STS_MODE=testing\nMTA_STS_MX=mx.example.com"), []);
});

test("checkMTAStsPolicy: duplicate MX entries in a marker-owned policy are invalid", () => {
  const duplicateMX = `version: STSv1\nmode: testing\nmx: mx.example.com\nmx: MX.EXAMPLE.COM\nmax_age: 604800\n${MTA_STS_MARKER}\n`;
  const issues = checkMTAStsPolicy(duplicateMX, "MTA_STS_MODE=testing\nMTA_STS_MX=mx.example.com");
  assert.ok(issues.some((issue) => /unique mx field/.test(issue.message)));
});

test("checkMTAStsPolicy: reports missing, hand-authored, and malformed enabled policies", () => {
  assert.ok(checkMTAStsPolicy(null, "MTA_STS_MODE=enforce\nMTA_STS_MX=mx.example.com").some((i) => /missing/.test(i.message)));
  assert.ok(checkMTAStsPolicy("version: STSv1\nmode: enforce\nmx: mx.example.com\nmax_age: 604800\n", "MTA_STS_MODE=enforce\nMTA_STS_MX=mx.example.com").some((i) => /not generated/.test(i.message)));
  assert.ok(checkMTAStsPolicy(validMTASts(), "MTA_STS_MODE=enforce\nMTA_STS_MX=not a host").some((i) => /no valid MX host/.test(i.message)));
});

const RSL_URL = "https://example.com/rsl.xml";
const ROBOTS_WITH_LICENSE = `User-agent: *\nDisallow:\n\nLicense: ${RSL_URL}\n`;
const HEADERS_WITH_RSL_LINK = `/*\n  Link: <${RSL_URL}>; rel="license"; type="application/rsl+xml"\n`;
const VALID_RSL_XML = `<?xml version="1.0" encoding="UTF-8"?>\n<rsl xmlns="https://rslstandard.org/rsl">\n  <content url="/"><license><permits type="usage">search</permits></license></content>\n</rsl>\n`;

test("checkRSL: inactive and nothing published is clean", () => {
  assert.deepEqual(checkRSL(false, null, null, "User-agent: *\nDisallow:\n", "/*\n"), []);
});

test("checkRSL: inactive but rsl.xml or the robots License: directive was published is a contradiction", () => {
  assert.ok(checkRSL(false, null, VALID_RSL_XML, "User-agent: *\nDisallow:\n", "/*\n").length > 0);
  assert.ok(checkRSL(false, null, null, ROBOTS_WITH_LICENSE, "/*\n").length > 0);
});

test("checkRSL: active with all four projections consistent is clean", () => {
  assert.deepEqual(
    checkRSL(true, RSL_URL, VALID_RSL_XML, ROBOTS_WITH_LICENSE, HEADERS_WITH_RSL_LINK),
    [],
  );
});

test("checkRSL: active but rsl.xml missing is a warning, not silent", () => {
  const issues = checkRSL(true, RSL_URL, null, ROBOTS_WITH_LICENSE, HEADERS_WITH_RSL_LINK);
  assert.ok(issues.some((i) => i.severity === "warning" && /missing/.test(i.message)));
});

test("checkRSL: active but rsl.xml has no RSL namespace is an error", () => {
  const bad = `<?xml version="1.0"?>\n<rsl>\n  <content url="/"><license/></content>\n</rsl>\n`;
  const issues = checkRSL(true, RSL_URL, bad, ROBOTS_WITH_LICENSE, HEADERS_WITH_RSL_LINK);
  assert.ok(issues.some((i) => i.severity === "error" && /namespace/.test(i.message)));
});

test("checkRSL: active but robots.txt has no License: directive is a warning", () => {
  const issues = checkRSL(true, RSL_URL, VALID_RSL_XML, "User-agent: *\nDisallow:\n", HEADERS_WITH_RSL_LINK);
  assert.ok(issues.some((i) => i.severity === "warning" && /License:/.test(i.message)));
});

test("checkRSL: active but _headers has no Link header is a warning", () => {
  const issues = checkRSL(true, RSL_URL, VALID_RSL_XML, ROBOTS_WITH_LICENSE, "/*\n");
  assert.ok(issues.some((i) => i.severity === "warning" && /Link:/.test(i.message)));
});

test("checkRSL: robots License: pointing at a different URL than rsl.xml's is an error", () => {
  const mismatched = `User-agent: *\nDisallow:\n\nLicense: https://example.com/wrong.xml\n`;
  const issues = checkRSL(true, RSL_URL, VALID_RSL_XML, mismatched, HEADERS_WITH_RSL_LINK);
  assert.ok(issues.some((i) => i.severity === "error" && /doesn't match/.test(i.message) && i.file === "dist/robots.txt"));
});

test("checkRSL: _headers Link pointing at a different URL than rsl.xml's is an error", () => {
  const mismatched = `/*\n  Link: <https://example.com/wrong.xml>; rel="license"; type="application/rsl+xml"\n`;
  const issues = checkRSL(true, RSL_URL, VALID_RSL_XML, ROBOTS_WITH_LICENSE, mismatched);
  assert.ok(issues.some((i) => i.severity === "error" && /doesn't match/.test(i.message) && i.file === "dist/_headers"));
});

test("checkEmbedMedia: a hotlinked platform image is an error", () => {
  const issues = checkEmbedMedia('<img src="https://pbs.twimg.com/media/x.jpg">', "dist/index.html");
  assert.equal(issues.length, 1);
  assert.equal(issues[0].severity, "error");
  assert.equal(issues[0].category, "embed-media-hotlink");
});

test("checkEmbedMedia: every known platform media host is caught", () => {
  for (const host of [
    "pbs.twimg.com",
    "scontent.cdninstagram.com",
    "cdn.bsky.app",
    "files.mastodon.social",
    "i.ytimg.com",
  ]) {
    assert.equal(checkEmbedMedia(`<img src="https://${host}/a.jpg">`, "f.html").length, 1, host);
  }
});

test("checkEmbedMedia: self-hosted embed media passes", () => {
  assert.deepEqual(checkEmbedMedia('<img src="/embeds/abc123/asset-0.png">', "dist/index.html"), []);
});

test("checkEmbedMedia: srcset and CSS url() are caught too", () => {
  assert.equal(checkEmbedMedia('<img srcset="https://pbs.twimg.com/a.jpg 2x">', "f.html").length, 1);
  assert.equal(checkEmbedMedia("a{background:url(https://cdn.bsky.app/x.png)}", "f.css").length, 1);
});

test("checkEmbedMedia: a permalink to the platform is not media and must pass", () => {
  assert.deepEqual(checkEmbedMedia('<a href="https://x.com/jack/status/20">View original</a>', "f.html"), []);
});

test("checkEmbedMedia: the youtube-nocookie iframe is not a media hotlink", () => {
  assert.deepEqual(checkEmbedMedia('<iframe src="https://www.youtube-nocookie.com/embed/a"></iframe>', "f.html"), []);
});

// Regression guard for #682 finding 1: the dedup pass that used to sit on top of a per-host,
// file-wide boolean test silently dropped a genuine second hotlink whenever it only matched via
// the same generic host entry as an earlier, more-specific-looking match. This must fail against
// that dedup implementation.
test("checkEmbedMedia: two distinct hotlinks in one file both count, even via the same generic host", () => {
  const issues = checkEmbedMedia(
    '<img src="https://scontent.cdninstagram.com/a.jpg"><img src="https://scontent-lax3-2.cdninstagram.com/b.jpg">',
    "f.html",
  );
  assert.equal(issues.length, 2);
});

test("checkEmbedMedia: an unquoted src attribute value is still flagged", () => {
  const issues = checkEmbedMedia("<img src=https://pbs.twimg.com/a.jpg>", "f.html");
  assert.equal(issues.length, 1);
  assert.equal(issues[0].category, "embed-media-hotlink");
});

test("checkEmbedMedia: an unquoted src value does not swallow a following href", () => {
  const issues = checkEmbedMedia(
    '<img src=/local/self-hosted.jpg href="https://pbs.twimg.com/media/x.jpg">',
    "f.html",
  );
  assert.deepEqual(issues, []);
});

test("checkEmbedMedia: an href with a real listed host is never flagged", () => {
  assert.deepEqual(checkEmbedMedia('<a href="https://pbs.twimg.com/media/x.jpg">original</a>', "f.html"), []);
});

// Regression guard for #682 finding (round 2): the per-occurrence rewrite's host check used
// JS `includes`, which is case-sensitive, so an upper-cased hostname (accidental paste, or a CMS
// that changes case) slipped through even though DNS hostnames are case-insensitive.
test("checkEmbedMedia: an upper-case host in src is flagged", () => {
  const issues = checkEmbedMedia('<img src="https://PBS.TWIMG.COM/media/x.jpg">', "f.html");
  assert.equal(issues.length, 1);
  assert.equal(issues[0].category, "embed-media-hotlink");
});

test("checkEmbedMedia: a mixed-case host in src is flagged", () => {
  const issues = checkEmbedMedia('<img src="https://Pbs.TwImg.CoM/media/x.jpg">', "f.html");
  assert.equal(issues.length, 1);
  assert.equal(issues[0].category, "embed-media-hotlink");
});

test("checkEmbedMedia: an upper-case host in srcset is flagged", () => {
  const issues = checkEmbedMedia('<img srcset="https://PBS.TWIMG.COM/a.jpg 1x">', "f.html");
  assert.equal(issues.length, 1);
});

test("checkEmbedMedia: an upper-case host in a CSS url() is flagged", () => {
  const issues = checkEmbedMedia("a{background:url(https://CDN.BSKY.APP/x.png)}", "f.css");
  assert.equal(issues.length, 1);
});

test("checkEmbedMedia: an upper-case host in href is still not flagged", () => {
  assert.deepEqual(checkEmbedMedia('<a href="https://PBS.TWIMG.COM/media/x.jpg">original</a>', "f.html"), []);
});

test("checkAnglesiteConfig: a missing file (null) is clean — no declarations yet", () => {
  assert.deepEqual(checkAnglesiteConfig(null), []);
});

test("checkAnglesiteConfig: a well-formed, versioned file is clean", () => {
  assert.deepEqual(checkAnglesiteConfig(JSON.stringify({ version: 1, domain: { hostname: "example.com" } })), []);
});

test("checkAnglesiteConfig: a file with no version field defaults to 1 and is clean", () => {
  assert.deepEqual(checkAnglesiteConfig(JSON.stringify({ domain: { hostname: "example.com" } })), []);
});

test("checkAnglesiteConfig: invalid JSON is an error with a fix-it", () => {
  const issues = checkAnglesiteConfig("{ not json");
  assert.equal(issues.length, 1);
  assert.equal(issues[0].severity, "error");
  assert.equal(issues[0].category, "anglesite-config-invalid");
  assert.match(issues[0].message, /not valid JSON/);
  assert.ok(issues[0].remediation);
});

test("checkAnglesiteConfig: a JSON array root is an error", () => {
  const issues = checkAnglesiteConfig("[1, 2, 3]");
  assert.equal(issues.length, 1);
  assert.match(issues[0].message, /must contain a JSON object/);
});

test("checkAnglesiteConfig: a JSON primitive root is an error", () => {
  const issues = checkAnglesiteConfig("42");
  assert.equal(issues.length, 1);
  assert.match(issues[0].message, /must contain a JSON object/);
});

test("checkAnglesiteConfig: a non-numeric version is an error", () => {
  const issues = checkAnglesiteConfig(JSON.stringify({ version: "1" }));
  assert.equal(issues.length, 1);
  assert.match(issues[0].message, /"version" must be a number/);
});

test("checkAnglesiteConfig: an unrecognized version number is an error naming the supported set", () => {
  const issues = checkAnglesiteConfig(JSON.stringify({ version: 99 }));
  assert.equal(issues.length, 1);
  assert.match(issues[0].message, /version 99/);
  assert.match(issues[0].message, /supported: 1/);
});

test("checkAnglesiteConfig: unknown top-level keys are tolerated (hand-edit rule)", () => {
  assert.deepEqual(checkAnglesiteConfig(JSON.stringify({ version: 1, somethingFromANewerApp: true })), []);
});

const VALID_ACTIVE = [
  {
    id: "homepage-hero",
    name: "Homepage headline",
    page: "/",
    variant: { id: "b", name: "Fresh eggs headline", page: "/x/homepage-hero/b/" },
    split: 0.5,
    goal: { kind: "pageview", path: "/contact/thanks/" },
    status: "running",
    startedAt: "2026-08-16",
  },
];

const VALID_VARIANT_HTML =
  '<html><head><link rel="canonical" href="https://example.com/"><meta name="robots" content="noindex"></head><body></body></html>';

function distFilesFor(paths: string[]): Set<string> {
  return new Set(paths);
}

test("runningExperimentVariantDistPath: null config returns null", () => {
  assert.equal(runningExperimentVariantDistPath(null), null);
});

test("runningExperimentVariantDistPath: invalid JSON returns null", () => {
  assert.equal(runningExperimentVariantDistPath("not json"), null);
});

test("runningExperimentVariantDistPath: no running experiment returns null", () => {
  const active = [{ ...VALID_ACTIVE[0], status: "draft" }];
  assert.equal(runningExperimentVariantDistPath(JSON.stringify({ version: 1, experiments: { active } })), null);
});

test("runningExperimentVariantDistPath: more than one running experiment returns null", () => {
  const active = [VALID_ACTIVE[0], { ...VALID_ACTIVE[0], id: "second-test" }];
  assert.equal(runningExperimentVariantDistPath(JSON.stringify({ version: 1, experiments: { active } })), null);
});

test("runningExperimentVariantDistPath: a well-formed running experiment resolves its variant's dist path", () => {
  assert.equal(
    runningExperimentVariantDistPath(JSON.stringify({ version: 1, experiments: { active: VALID_ACTIVE } })),
    "dist/x/homepage-hero/b/index.html",
  );
});

test("runningExperimentVariantDistPath: a malformed variant.page returns null rather than throwing", () => {
  const active = [{ ...VALID_ACTIVE[0], variant: { ...VALID_ACTIVE[0].variant, page: 42 } }];
  assert.equal(runningExperimentVariantDistPath(JSON.stringify({ version: 1, experiments: { active } })), null);
});

test("checkExperiments: null config returns no issues", () => {
  assert.deepEqual(checkExperiments(null, new Set(), null, null), []);
});

test("checkExperiments: no experiments section returns no issues", () => {
  assert.deepEqual(checkExperiments(JSON.stringify({ version: 1 }), new Set(), null, null), []);
});

test("checkExperiments: experiments.active must be an array", () => {
  const issues = checkExperiments(JSON.stringify({ version: 1, experiments: { active: "nope" } }), new Set(), null, null);
  assert.equal(issues.length, 1);
  assert.equal(issues[0].category, "experiments-invalid");
});

test("checkExperiments: rejects a malformed id", () => {
  const active = [{ ...VALID_ACTIVE[0], id: "not valid!" }];
  const issues = checkExperiments(JSON.stringify({ version: 1, experiments: { active } }), new Set(), null, null);
  assert.ok(issues.some((i) => i.message.includes(".id must match")));
});

test("checkExperiments: rejects split outside (0,1)", () => {
  const active = [{ ...VALID_ACTIVE[0], split: 1.5 }];
  const issues = checkExperiments(JSON.stringify({ version: 1, experiments: { active } }), new Set(), null, null);
  assert.ok(issues.some((i) => i.message.includes(".split must be")));
});

test("checkExperiments: rejects an unrecognized goal kind", () => {
  const active = [{ ...VALID_ACTIVE[0], goal: { kind: "bogus", path: "/x/" } }];
  const issues = checkExperiments(JSON.stringify({ version: 1, experiments: { active } }), new Set(), null, null);
  assert.ok(issues.some((i) => i.message.includes("goal.kind must be one of")));
});

test("checkExperiments: rejects a scroll goal with a non-numeric depth", () => {
  const active = [{ ...VALID_ACTIVE[0], goal: { kind: "scroll", depth: "75" } }];
  const issues = checkExperiments(JSON.stringify({ version: 1, experiments: { active } }), new Set(), null, null);
  assert.ok(issues.some((i) => i.message.includes(".goal.depth must be")));
});

test("checkExperiments: rejects a scroll goal with an out-of-range depth", () => {
  const active = [{ ...VALID_ACTIVE[0], goal: { kind: "scroll", depth: 150 } }];
  const issues = checkExperiments(JSON.stringify({ version: 1, experiments: { active } }), new Set(), null, null);
  assert.ok(issues.some((i) => i.message.includes(".goal.depth must be")));
});

test("checkExperiments: accepts an in-range scroll depth (no goal-parameter issue)", () => {
  const active = [{ ...VALID_ACTIVE[0], goal: { kind: "scroll", depth: 75 } }];
  const issues = checkExperiments(JSON.stringify({ version: 1, experiments: { active } }), new Set(), null, null);
  assert.ok(!issues.some((i) => i.message.includes(".goal.depth") || i.message.includes(".goal.selector")));
});

test("checkExperiments: rejects a visible goal missing a selector", () => {
  const active = [{ ...VALID_ACTIVE[0], goal: { kind: "visible" } }];
  const issues = checkExperiments(JSON.stringify({ version: 1, experiments: { active } }), new Set(), null, null);
  assert.ok(issues.some((i) => i.message.includes(".goal.selector must be")));
});

test("checkExperiments: rejects a visible goal with an empty/whitespace selector", () => {
  const active = [{ ...VALID_ACTIVE[0], goal: { kind: "visible", selector: "   " } }];
  const issues = checkExperiments(JSON.stringify({ version: 1, experiments: { active } }), new Set(), null, null);
  assert.ok(issues.some((i) => i.message.includes(".goal.selector must be")));
});

test("checkExperiments: accepts a non-empty visible selector (no goal-parameter issue)", () => {
  const active = [{ ...VALID_ACTIVE[0], goal: { kind: "visible", selector: "#testimonials" } }];
  const issues = checkExperiments(JSON.stringify({ version: 1, experiments: { active } }), new Set(), null, null);
  assert.ok(!issues.some((i) => i.message.includes(".goal.depth") || i.message.includes(".goal.selector")));
});

test("checkExperiments: rejects more than one running experiment", () => {
  const active = [VALID_ACTIVE[0], { ...VALID_ACTIVE[0], id: "second-test" }];
  const issues = checkExperiments(JSON.stringify({ version: 1, experiments: { active } }), new Set(), null, null);
  assert.ok(issues.some((i) => i.message.includes("Only one experiment may be")));
});

test("checkExperiments: rejects a variant.id that fails the id pattern", () => {
  const active = [{ ...VALID_ACTIVE[0], variant: { ...VALID_ACTIVE[0].variant, id: "not valid; nope" } }];
  const issues = checkExperiments(JSON.stringify({ version: 1, experiments: { active } }), new Set(), null, null);
  assert.ok(issues.some((i) => i.message.includes(".variant.id must match")));
});

test('checkExperiments: rejects variant.id "control" as reserved for the unmodified page', () => {
  const active = [{ ...VALID_ACTIVE[0], variant: { ...VALID_ACTIVE[0].variant, id: "control" } }];
  const issues = checkExperiments(JSON.stringify({ version: 1, experiments: { active } }), new Set(), null, null);
  assert.ok(
    issues.some((i) => i.category === "experiments-invalid" && i.message.includes('"control" is reserved for the unmodified page')),
  );
});

test("checkExperiments: rejects a running experiment's page without a trailing slash", () => {
  const active = [{ ...VALID_ACTIVE[0], page: "/pricing" }];
  const issues = checkExperiments(JSON.stringify({ version: 1, experiments: { active } }), new Set(), null, null);
  assert.ok(issues.some((i) => i.message.includes('.page must end with "/"')));
});

test("checkExperiments: rejects a running experiment's variant.page without a trailing slash", () => {
  const active = [{ ...VALID_ACTIVE[0], variant: { ...VALID_ACTIVE[0].variant, page: "/x/homepage-hero/b" } }];
  const issues = checkExperiments(JSON.stringify({ version: 1, experiments: { active } }), new Set(), null, null);
  assert.ok(issues.some((i) => i.message.includes('.variant.page must end with "/"')));
});

test("checkExperiments: rejects a pageview goal path without a trailing slash", () => {
  const active = [{ ...VALID_ACTIVE[0], goal: { kind: "pageview", path: "/contact/thanks" } }];
  const issues = checkExperiments(JSON.stringify({ version: 1, experiments: { active } }), new Set(), null, null);
  assert.ok(issues.some((i) => i.message.includes('.goal.path must end with "/"')));
});

test("checkExperiments: accepts a route goal path without a trailing slash (regression)", () => {
  const active = [{ ...VALID_ACTIVE[0], goal: { kind: "route", path: "/api/contact" } }];
  const issues = checkExperiments(JSON.stringify({ version: 1, experiments: { active } }), new Set(), null, null);
  assert.ok(!issues.some((i) => i.message.includes("goal.path must end")));
});

test("checkExperiments: a well-formed draft-only config (nothing running) has no dist-dependent issues", () => {
  const active = [{ ...VALID_ACTIVE[0], status: "draft" }];
  const issues = checkExperiments(JSON.stringify({ version: 1, experiments: { active } }), new Set(), null, null);
  assert.deepEqual(issues, []);
});

test("checkExperiments: flags a running experiment's page missing from dist/", () => {
  const issues = checkExperiments(
    JSON.stringify({ version: 1, experiments: { active: VALID_ACTIVE } }),
    distFilesFor(["dist/x/homepage-hero/b/index.html"]),
    VALID_VARIANT_HTML,
    "<urlset></urlset>",
  );
  assert.ok(issues.some((i) => i.category === "experiments-not-built" && i.message.includes('"/")')));
});

test("checkExperiments: flags a running experiment's pageview goal path missing from dist/", () => {
  const issues = checkExperiments(
    JSON.stringify({ version: 1, experiments: { active: VALID_ACTIVE } }),
    distFilesFor(["dist/index.html", "dist/x/homepage-hero/b/index.html"]),
    VALID_VARIANT_HTML,
    "<urlset></urlset>",
  );
  assert.ok(issues.some((i) => i.category === "experiments-not-built" && i.message.includes("pageview goal")));
});

test("checkExperiments: flags a variant page missing rel=canonical to the control page", () => {
  const html = '<html><head><meta name="robots" content="noindex"></head></html>';
  const issues = checkExperiments(
    JSON.stringify({ version: 1, experiments: { active: VALID_ACTIVE } }),
    distFilesFor(["dist/index.html", "dist/x/homepage-hero/b/index.html", "dist/contact/thanks/index.html"]),
    html,
    "<urlset></urlset>",
  );
  assert.ok(issues.some((i) => i.category === "experiments-variant-seo" && i.message.includes("canonical")));
});

test("checkExperiments: flags a variant page missing noindex", () => {
  const html = '<html><head><link rel="canonical" href="https://example.com/"></head></html>';
  const issues = checkExperiments(
    JSON.stringify({ version: 1, experiments: { active: VALID_ACTIVE } }),
    distFilesFor(["dist/index.html", "dist/x/homepage-hero/b/index.html", "dist/contact/thanks/index.html"]),
    html,
    "<urlset></urlset>",
  );
  assert.ok(issues.some((i) => i.category === "experiments-variant-seo" && i.message.includes("noindex")));
});

test("checkExperiments: flags a variant page present in the sitemap", () => {
  const issues = checkExperiments(
    JSON.stringify({ version: 1, experiments: { active: VALID_ACTIVE } }),
    distFilesFor(["dist/index.html", "dist/x/homepage-hero/b/index.html", "dist/contact/thanks/index.html"]),
    VALID_VARIANT_HTML,
    "<urlset><url><loc>https://example.com/x/homepage-hero/b/</loc></url></urlset>",
  );
  assert.ok(issues.some((i) => i.category === "experiments-variant-seo" && i.message.includes("sitemap")));
});

test("checkExperiments: a fully well-formed, fully built running experiment has no issues", () => {
  const issues = checkExperiments(
    JSON.stringify({ version: 1, experiments: { active: VALID_ACTIVE } }),
    distFilesFor(["dist/index.html", "dist/x/homepage-hero/b/index.html", "dist/contact/thanks/index.html"]),
    VALID_VARIANT_HTML,
    "<urlset></urlset>",
  );
  assert.deepEqual(issues, []);
});

test("checkExperiments: recognizes rel=canonical even when href precedes rel in the tag", () => {
  const html =
    '<html><head><link href="https://example.com/" rel="canonical"><meta name="robots" content="noindex"></head><body></body></html>';
  const issues = checkExperiments(
    JSON.stringify({ version: 1, experiments: { active: VALID_ACTIVE } }),
    distFilesFor(["dist/index.html", "dist/x/homepage-hero/b/index.html", "dist/contact/thanks/index.html"]),
    html,
    "<urlset></urlset>",
  );
  assert.deepEqual(issues, []);
});

test("checkExperiments: recognizes noindex even when content precedes name in the tag", () => {
  const html =
    '<html><head><link rel="canonical" href="https://example.com/"><meta content="noindex" name="robots"></head><body></body></html>';
  const issues = checkExperiments(
    JSON.stringify({ version: 1, experiments: { active: VALID_ACTIVE } }),
    distFilesFor(["dist/index.html", "dist/x/homepage-hero/b/index.html", "dist/contact/thanks/index.html"]),
    html,
    "<urlset></urlset>",
  );
  assert.deepEqual(issues, []);
});

const SCROLL_GOAL_ACTIVE = [{ ...VALID_ACTIVE[0], goal: { kind: "scroll", depth: 75 } }];
const BEACON_SCRIPT_TAG = `<script src="${GOAL_BEACON_SCRIPT_PATH}" defer data-experiment="homepage-hero" data-kind="scroll" data-depth="75"></script>`;
const VARIANT_WITH_BEACON_HTML = `<html><head><link rel="canonical" href="https://example.com/"><meta name="robots" content="noindex">${BEACON_SCRIPT_TAG}</head><body></body></html>`;
const CONTROL_WITH_BEACON_HTML = `<html><head>${BEACON_SCRIPT_TAG}</head><body></body></html>`;
const NO_BEACON_TAG_HTML = "<html><head></head><body></body></html>";

test("checkExperiments: flags a running client-side-goal experiment missing the built beacon script", () => {
  const issues = checkExperiments(
    JSON.stringify({ version: 1, experiments: { active: SCROLL_GOAL_ACTIVE } }),
    distFilesFor(["dist/index.html", "dist/x/homepage-hero/b/index.html"]),
    VARIANT_WITH_BEACON_HTML,
    "<urlset></urlset>",
    CONTROL_WITH_BEACON_HTML,
  );
  assert.ok(issues.some((i) => i.category === "experiments-goal-beacon" && i.message.includes("goal beacon script")));
});

test("checkExperiments: flags a control page missing the beacon <script> tag for a client-side goal", () => {
  const issues = checkExperiments(
    JSON.stringify({ version: 1, experiments: { active: SCROLL_GOAL_ACTIVE } }),
    distFilesFor(["dist/index.html", "dist/x/homepage-hero/b/index.html", "dist/x/goal-beacon.js"]),
    VARIANT_WITH_BEACON_HTML,
    "<urlset></urlset>",
    NO_BEACON_TAG_HTML,
  );
  assert.ok(
    issues.some(
      (i) => i.category === "experiments-goal-beacon" && i.message.includes("control page") && i.message.includes("beacon"),
    ),
  );
});

test("checkExperiments: flags a variant page missing the beacon <script> tag for a client-side goal", () => {
  const issues = checkExperiments(
    JSON.stringify({ version: 1, experiments: { active: SCROLL_GOAL_ACTIVE } }),
    distFilesFor(["dist/index.html", "dist/x/homepage-hero/b/index.html", "dist/x/goal-beacon.js"]),
    NO_BEACON_TAG_HTML,
    "<urlset></urlset>",
    CONTROL_WITH_BEACON_HTML,
  );
  assert.ok(
    issues.some(
      (i) => i.category === "experiments-goal-beacon" && i.message.includes("variant page") && i.message.includes("beacon"),
    ),
  );
});

test("checkExperiments: a fully built client-side-goal experiment (script + both tags) has no issues", () => {
  const issues = checkExperiments(
    JSON.stringify({ version: 1, experiments: { active: SCROLL_GOAL_ACTIVE } }),
    distFilesFor(["dist/index.html", "dist/x/homepage-hero/b/index.html", "dist/x/goal-beacon.js"]),
    VARIANT_WITH_BEACON_HTML,
    "<urlset></urlset>",
    CONTROL_WITH_BEACON_HTML,
  );
  assert.deepEqual(issues, []);
});

test("checkExperiments: does not require the beacon script/tag for an edge-visible goal (regression)", () => {
  const issues = checkExperiments(
    JSON.stringify({ version: 1, experiments: { active: VALID_ACTIVE } }),
    distFilesFor(["dist/index.html", "dist/x/homepage-hero/b/index.html", "dist/contact/thanks/index.html"]),
    VALID_VARIANT_HTML,
    "<urlset></urlset>",
    NO_BEACON_TAG_HTML,
  );
  assert.ok(!issues.some((i) => i.category === "experiments-goal-beacon"));
});

test("checkExperiments: skips the beacon-tag check when control HTML wasn't captured (older call sites)", () => {
  const issues = checkExperiments(
    JSON.stringify({ version: 1, experiments: { active: SCROLL_GOAL_ACTIVE } }),
    distFilesFor(["dist/index.html", "dist/x/homepage-hero/b/index.html", "dist/x/goal-beacon.js"]),
    VARIANT_WITH_BEACON_HTML,
    "<urlset></urlset>",
  );
  assert.ok(!issues.some((i) => i.message.includes("control page")));
});

const VISIBLE_GOAL_ACTIVE = [{ ...VALID_ACTIVE[0], goal: { kind: "visible", selector: "#reviews" } }];

test("checkExperiments: flags a visible-goal selector that matches neither built page", () => {
  const controlHtml = `<html><head>${BEACON_SCRIPT_TAG}</head><body><h1>Home</h1></body></html>`;
  const variantHtml = `<html><head><link rel="canonical" href="https://example.com/"><meta name="robots" content="noindex">${BEACON_SCRIPT_TAG}</head><body><h1>Home (variant)</h1></body></html>`;
  const issues = checkExperiments(
    JSON.stringify({ version: 1, experiments: { active: VISIBLE_GOAL_ACTIVE } }),
    distFilesFor(["dist/index.html", "dist/x/homepage-hero/b/index.html", "dist/x/goal-beacon.js"]),
    variantHtml,
    "<urlset></urlset>",
    controlHtml,
  );
  assert.ok(issues.some((i) => i.category === "experiments-goal-beacon" && i.message.includes("#reviews")));
});

test("checkExperiments: passes a visible-goal selector present in both built pages", () => {
  const controlHtml = `<html><head>${BEACON_SCRIPT_TAG}</head><body><section id="reviews">Great</section></body></html>`;
  const variantHtml = `<html><head><link rel="canonical" href="https://example.com/"><meta name="robots" content="noindex">${BEACON_SCRIPT_TAG}</head><body><section id="reviews">Great</section></body></html>`;
  const issues = checkExperiments(
    JSON.stringify({ version: 1, experiments: { active: VISIBLE_GOAL_ACTIVE } }),
    distFilesFor(["dist/index.html", "dist/x/homepage-hero/b/index.html", "dist/x/goal-beacon.js"]),
    variantHtml,
    "<urlset></urlset>",
    controlHtml,
  );
  assert.deepEqual(issues, []);
});

test("runningExperimentControlDistPath: a well-formed running experiment resolves its own dist path", () => {
  assert.equal(
    runningExperimentControlDistPath(JSON.stringify({ version: 1, experiments: { active: VALID_ACTIVE } })),
    "dist/index.html",
  );
});

test("runningExperimentControlDistPath: no running experiment returns null", () => {
  const active = [{ ...VALID_ACTIVE[0], status: "draft" }];
  assert.equal(runningExperimentControlDistPath(JSON.stringify({ version: 1, experiments: { active } })), null);
});
