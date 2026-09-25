import test from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  MAX_EXTERNAL_REFERENCES,
  NoBuiltPagesError,
  classify,
  collectSiteInputs,
  exitCodeFor,
  formatReport,
  parseAttributes,
  redirectSourcesFromCloudflareFile,
  resolvePath,
  routeForDistPath,
  runtimeRoutesFromWorkerSource,
  scan,
  siteHostsFromDomain,
  urlPathForDistPath,
  type BrokenLinkProblem,
  type ScanOptions,
} from "./broken-links";

/** A throwaway `dist/` populated from `files` (relative path → contents). */
function makeDist(files: Record<string, string>): string {
  const root = mkdtempSync(join(tmpdir(), "anglesite-broken-links-"));
  for (const [path, contents] of Object.entries(files)) {
    mkdirSync(dirname(join(root, path)), { recursive: true });
    writeFileSync(join(root, path), contents);
  }
  return root;
}

function scanFiles(files: Record<string, string>, options: ScanOptions = {}) {
  const root = makeDist(files);
  try {
    return scan(root, options);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

const problem = (kind: BrokenLinkProblem["kind"], page: string, reference: string, resolvedPath: string): BrokenLinkProblem => ({
  kind,
  page,
  reference,
  resolvedPath,
});

// ---------------------------------------------------------------------------
// Resolution against dist/
// ---------------------------------------------------------------------------

test("a root-relative link to a directory-style page resolves via index.html", () => {
  const report = scanFiles({
    "index.html": '<a href="/about/">About</a> <a href="/about">Also</a>',
    "about/index.html": "<h1>About</h1>",
  });
  assert.deepEqual(report.problems, []);
  assert.equal(report.pagesScanned, 2);
  assert.equal(report.referencesChecked, 2);
});

test("a link to a page nothing serves is a missing target on the referencing page", () => {
  const report = scanFiles({ "index.html": '<a href="/gone/">Gone</a>' });
  assert.deepEqual(report.problems, [problem("missing-target", "/", "/gone/", "/gone/")]);
});

test("relative references resolve against the page's own directory, including ../", () => {
  const report = scanFiles({
    "blog/hello/index.html": '<img src="../hero.png"> <img src="./missing.png"> <a href="../../about/">x</a>',
    "blog/hero.png": "png",
    "about/index.html": "<h1>About</h1>",
  });
  assert.deepEqual(report.problems, [problem("missing-target", "/blog/hello/", "./missing.png", "/blog/hello/missing.png")]);
});

test("query strings are ignored and percent-encoded paths are decoded before lookup", () => {
  const report = scanFiles({
    "index.html": '<a href="/docs/?v=2">d</a> <img src="/images/my%20photo.jpg">',
    "docs/index.html": "",
    "images/my photo.jpg": "jpg",
  });
  assert.deepEqual(report.problems, []);
});

test("file-style pages (about.html) are served for both /about and /about.html", () => {
  const report = scanFiles({ "index.html": '<a href="/about">a</a> <a href="/about.html">b</a>', "about.html": "" });
  assert.deepEqual(report.problems, []);
});

test("hidden output such as .well-known is linkable", () => {
  const report = scanFiles({
    "index.html": '<a href="/.well-known/security.txt">s</a>',
    ".well-known/security.txt": "Contact: mailto:x@example.com",
  });
  assert.deepEqual(report.problems, []);
});

// ---------------------------------------------------------------------------
// Skips and coverage
// ---------------------------------------------------------------------------

test("mailto, tel, javascript, data and off-site http links are never flagged", () => {
  const report = scanFiles({
    "index.html": `
      <a href="mailto:me@example.com">m</a>
      <a href="tel:+15551234567">t</a>
      <a href="javascript:void(0)">j</a>
      <img src="data:image/png;base64,AAAA">
      <a href="https://other.example/page">o</a>
      <a href="//cdn.example/x.js">p</a>`,
  });
  assert.deepEqual(report.problems, []);
  assert.equal(report.referencesChecked, 0);
  assert.equal(report.externalReferencesSkipped, 2);
});

// ---------------------------------------------------------------------------
// External references (#2026)
// ---------------------------------------------------------------------------

test("externalReferences lists each distinct off-site URL once while the count stays per occurrence", () => {
  const report = scanFiles({
    "index.html": `
      <a href="https://other.example/page">1</a>
      <a href="https://other.example/page">2</a>
      <a href="https://other.example/page#section">3</a>`,
  });
  assert.equal(report.externalReferencesSkipped, 3);
  assert.deepEqual(report.externalReferences, ["https://other.example/page"]);
});

test("externalReferences folds scheme and host case but keeps the path's", () => {
  const report = scanFiles({
    "a.html": '<a href="HTTPS://Other.EXAMPLE/Path">1</a>',
    "b.html": '<a href="https://other.example/Path">2</a> <a href="https://other.example/path">3</a>',
  });
  assert.deepEqual(report.externalReferences, ["https://other.example/Path", "https://other.example/path"]);
  assert.equal(report.externalReferencesSkipped, 3);
});

test("externalReferences keeps first-seen order across pages, the query and the path's case", () => {
  const report = scanFiles({
    "a.html": '<a href="https://z.example/Path?q=1">z</a> <a href="//cdn.example/lib.js">c</a>',
    "b.html": '<a href="https://z.example/Path?q=2">z2</a> <a href="https://z.example/Path?q=1">again</a>',
  });
  assert.deepEqual(report.externalReferences, [
    "https://z.example/Path?q=1",
    "https://cdn.example/lib.js",
    "https://z.example/Path?q=2",
  ]);
  assert.equal(report.externalReferencesSkipped, 4);
});

test("a scan with no off-site links reports an empty externalReferences", () => {
  const report = scanFiles({ "index.html": '<a href="/">home</a> <a href="mailto:me@example.com">m</a>' });
  assert.deepEqual(report.externalReferences, []);
  assert.equal(report.externalReferencesSkipped, 0);
});

test("externalReferences is capped while the count stays exact", () => {
  const total = MAX_EXTERNAL_REFERENCES + 25;
  const links = Array.from({ length: total }, (_, i) => `<a href="https://other.example/p${i}">${i}</a>`).join("");
  const report = scanFiles({ "index.html": links });
  assert.equal(report.externalReferences.length, MAX_EXTERNAL_REFERENCES);
  assert.equal(report.externalReferences[0], "https://other.example/p0");
  assert.equal(report.externalReferences.at(-1), `https://other.example/p${MAX_EXTERNAL_REFERENCES - 1}`);
  assert.equal(report.externalReferencesSkipped, total);
});

test("absolute links to the site's own host are checked like root-relative ones", () => {
  const report = scanFiles(
    {
      "index.html": '<a href="https://www.example.com/missing/">m</a> <a href="HTTPS://EXAMPLE.COM:443/ok/">k</a>',
      "ok/index.html": "",
    },
    { siteHosts: new Set(["example.com", "www.example.com"]) },
  );
  assert.deepEqual(report.problems, [problem("missing-target", "/", "https://www.example.com/missing/", "/missing/")]);
  assert.equal(report.externalReferencesSkipped, 0);
});

test("references inside <script> blocks and HTML comments are not scanned", () => {
  const report = scanFiles({
    "index.html": `
      <script type="module">const x = '<a href="/phantom/">'; fetch("/api/nope");</script>
      <!-- <img src="/old.png"> -->
      <p>fine</p>`,
  });
  assert.deepEqual(report.problems, []);
  assert.equal(report.referencesChecked, 0);
});

test("script and style end tags with whitespace or attributes after the name still close the block", () => {
  // `</script\t\n bar>` is a valid end tag per the HTML tokenizer; a strip that only accepted
  // `</script\s*>` would treat the rest of the page as script and drop its real references —
  // or, the other way round, let a script payload's fake tags leak out (CodeQL js/bad-tag-filter).
  const report = scanFiles({
    "index.html": [
      "<script>const t = '<a href=\"/phantom/\">';</script\t\n bar>",
      '<a href="/real-missing/">r</a>',
      "<style>.x { background: url(/from-style.png) }</style \n>",
      "<SCRIPT TYPE=module>x</SCRIPT >",
      '<a href="/also-real/">r</a>',
    ].join("\n"),
  });
  assert.deepEqual(
    report.problems.map((p) => p.resolvedPath),
    ["/also-real/", "/from-style.png", "/real-missing/"],
  );
});

test("a reference covered by a redirect source is not a missing target", () => {
  const report = scanFiles(
    { "index.html": '<a href="/old-page/">o</a> <a href="/old-page">o2</a> <a href="/legacy/deep/thing">s</a> <a href="/really-gone/">g</a>' },
    { redirectSources: new Set(["/old-page", "/legacy/*"]) },
  );
  assert.deepEqual(report.problems, [problem("missing-target", "/", "/really-gone/", "/really-gone/")]);
});

test("a reference to a Worker-served runtime route is not a missing target", () => {
  const report = scanFiles(
    {
      "index.html":
        '<link rel="indieauth-metadata" href="/.well-known/oauth-authorization-server"> <a href="/pod/notes/1">p</a> <a href="/pod">root</a> <a href="/webmention/">w</a> <a href="/podcast/">c</a>',
    },
    {
      runtimeRoutes: [
        { path: "/.well-known/oauth-authorization-server", prefix: false },
        { path: "/pod", prefix: true },
        { path: "/webmention", prefix: false },
      ],
    },
  );
  assert.deepEqual(report.problems, [problem("missing-target", "/", "/podcast/", "/podcast/")]);
});

test("srcset candidates, poster, object data, link href and inline style url() are all checked", () => {
  const report = scanFiles({
    "index.html": `
      <img srcset="/a.png 1x, /b.png 2x" src="/a.png">
      <video poster="/poster.jpg"></video>
      <object data="/doc.pdf"></object>
      <link rel="stylesheet" href="/_astro/site.css">
      <div style="background: url('/bg.png')"></div>
      <style>.hero { background-image: url(/hero.webp); }</style>`,
    "a.png": "",
    "_astro/site.css": "",
  });
  assert.deepEqual(
    report.problems.map((p) => p.resolvedPath),
    ["/b.png", "/bg.png", "/doc.pdf", "/hero.webp", "/poster.jpg"],
  );
});

test("url() references in built stylesheets resolve relative to the stylesheet", () => {
  const report = scanFiles({
    "index.html": "",
    "_astro/site.css": '@font-face { src: url("../fonts/brand.woff2"); } .x { background: url(missing.png) }',
    "fonts/brand.woff2": "",
  });
  assert.deepEqual(report.problems, [problem("missing-target", "/_astro/site.css", "missing.png", "/_astro/missing.png")]);
});

test("the same dead reference repeated on one page is reported once", () => {
  const report = scanFiles({ "index.html": '<a href="/x/">1</a><a href="/x/">2</a><a href="/x">3</a>' });
  assert.equal(report.problems.length, 2); // `/x/` and `/x` resolve differently; each once
  assert.equal(report.referencesChecked, 2);
});

// ---------------------------------------------------------------------------
// Anchors
// ---------------------------------------------------------------------------

test("a fragment that matches an id or <a name> on the target page is fine", () => {
  const report = scanFiles({
    "index.html": '<a href="/about/#team">t</a> <a href="#here">h</a> <a href="/about/#top">top</a> <p id="here"></p>',
    "about/index.html": '<h2 id="team">Team</h2> <a name="legacy"></a>',
  });
  assert.deepEqual(report.problems, []);
});

test("a fragment with no matching id is a missing anchor, on the same page or another", () => {
  const report = scanFiles({
    "index.html": '<a href="/about/#nope">n</a> <a href="#local">l</a>',
    "about/index.html": '<h2 id="team">Team</h2>',
  });
  assert.deepEqual(report.problems, [
    problem("missing-anchor", "/", "#local", "/#local"),
    problem("missing-anchor", "/", "/about/#nope", "/about/#nope"),
  ]);
});

test("fragments on non-HTML targets are not anchor-checked", () => {
  const report = scanFiles({ "index.html": '<img src="/icons.svg#star">', "icons.svg": "<svg></svg>" });
  assert.deepEqual(report.problems, []);
});

// ---------------------------------------------------------------------------
// Fail-closed
// ---------------------------------------------------------------------------

test("a dist with no HTML throws rather than reporting a clean scan", () => {
  const root = makeDist({ "_astro/site.css": "" });
  try {
    assert.throws(() => scan(root), NoBuiltPagesError);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("a missing dist directory throws the same way", () => {
  assert.throws(() => scan(join(tmpdir(), "anglesite-broken-links-missing-" + process.pid)), NoBuiltPagesError);
});

// ---------------------------------------------------------------------------
// Pure helpers
// ---------------------------------------------------------------------------

test("resolvePath collapses dot segments and keeps trailing slashes", () => {
  assert.equal(resolvePath("/a/b", "/x/"), "/a/b");
  assert.equal(resolvePath("c", "/x/y/"), "/x/y/c");
  assert.equal(resolvePath("../c/", "/x/y/"), "/x/c/");
  assert.equal(resolvePath("../../../c", "/x/"), "/c");
  assert.equal(resolvePath("./", "/x/y/"), "/x/y/");
  assert.equal(resolvePath("c", "/x/page.html"), "/x/c");
  assert.equal(resolvePath("", "/x/"), "/x/");
});

test("routeForDistPath and urlPathForDistPath derive owner-facing labels from dist paths", () => {
  assert.equal(routeForDistPath("index.html"), "/");
  assert.equal(routeForDistPath("blog/x/index.html"), "/blog/x/");
  assert.equal(routeForDistPath("about.html"), "/about");
  assert.equal(routeForDistPath("_astro/a.css"), "/_astro/a.css");
  assert.equal(urlPathForDistPath("about.html"), "/about.html");
});

test("classify splits scheme, host, query and fragment", () => {
  const hosts = new Set(["example.com"]);
  assert.deepEqual(classify("", hosts), { kind: "skip" });
  assert.deepEqual(classify("mailto:a@b.c", hosts), { kind: "skip" });
  assert.deepEqual(classify("https://other.example/x", hosts), { kind: "external", url: "https://other.example/x" });
  assert.deepEqual(classify("//cdn.example/A.js?v=1#top", hosts), { kind: "external", url: "https://cdn.example/A.js?v=1" });
  assert.deepEqual(classify("https://example.com", hosts), { kind: "internal", path: "/", fragment: null });
  assert.deepEqual(classify("https://user@example.com:8443/p?q#f", hosts), { kind: "internal", path: "/p", fragment: "f" });
  assert.deepEqual(classify("/a?b=c#d", hosts), { kind: "internal", path: "/a", fragment: "d" });
  assert.deepEqual(classify("#only", hosts), { kind: "internal", path: "", fragment: "only" });
  assert.deepEqual(classify(" /trimmed ", hosts), { kind: "internal", path: "/trimmed", fragment: null });
});

test("parseAttributes handles double, single, bare and boolean forms", () => {
  const attrs = parseAttributes(` HREF="/a" src='/b' data-x=/c hidden`);
  assert.deepEqual(
    attrs,
    [
      ["href", "/a"],
      ["src", "/b"],
      ["data-x", "/c"],
      ["hidden", null],
    ],
  );
});

test("siteHostsFromDomain pairs apex and www either way round and strips scheme/path noise", () => {
  assert.deepEqual([...siteHostsFromDomain("Example.com")].sort(), ["example.com", "www.example.com"]);
  assert.deepEqual([...siteHostsFromDomain("www.example.com")].sort(), ["example.com", "www.example.com"]);
  assert.deepEqual([...siteHostsFromDomain("https://example.com/")].sort(), ["example.com", "www.example.com"]);
  assert.equal(siteHostsFromDomain("").size, 0);
  assert.equal(siteHostsFromDomain(undefined).size, 0);
});

test("redirectSourcesFromCloudflareFile keeps sources and ignores comments and junk", () => {
  const sources = redirectSourcesFromCloudflareFile(`# moved
/old /new 301
/splat/* /elsewhere/:splat 302
not-a-path /x
/lonely
`);
  assert.deepEqual([...sources].sort(), ["/old", "/splat/*"]);
});

test("runtimeRoutesFromWorkerSource ignores non-path strings, dedupes, and tolerates comments between fields", () => {
  const routes = runtimeRoutesFromWorkerSource(`
    const x = { path: "not-absolute", match: "exact" };
    [{
      // a comment between the fields, as in the template
      path: "/media",
      match: "exact",
    }, { path: "/media", match: "prefix" }, { path: "/media", match: "exact" }]
    { path: "/orphan-without-match" }
    { path: "/late", handler: () => {}, match: "prefix" }
  `);
  assert.deepEqual(routes, [
    { path: "/media", prefix: false },
    { path: "/media", prefix: true },
  ]);
});

test("the real Worker route table parses into the runtime routes the layout links on every page", () => {
  // BaseLayout.astro links these unconditionally or when the feature is on; if the regex ever
  // stopped pairing path/match in worker.ts's ROUTES literal, every audit would go red.
  const here = dirname(fileURLToPath(import.meta.url));
  const routes = runtimeRoutesFromWorkerSource(readFileSync(join(here, "..", "worker", "worker.ts"), "utf-8"));
  const has = (path: string, prefix: boolean) => routes.some((r) => r.path === path && r.prefix === prefix);
  assert.ok(has("/.well-known/oauth-authorization-server", false));
  assert.ok(has("/webmention", false));
  assert.ok(has("/micropub", false));
  assert.ok(has("/pod", true));
  assert.ok(routes.length >= 20, `only ${routes.length} routes parsed`);
  assert.ok(routes.every((r) => r.path.startsWith("/")));
});

test("collectSiteInputs reads DOMAIN, redirects.json, dist/_redirects and worker/worker.ts from a site root", () => {
  const root = makeDist({
    ".site-config": "SITE_NAME=Acme\nDOMAIN=example.com\n",
    "redirects.json": JSON.stringify([{ source: "/moved", destination: "/new/", code: 301 }]),
    "dist/_redirects": "/also-moved/ /new/ 301\n",
    "worker/worker.ts": 'export const ROUTES = [{ path: "/webmention", match: "exact" }];',
  });
  try {
    const inputs = collectSiteInputs(root, join(root, "dist"));
    assert.deepEqual([...(inputs.siteHosts ?? [])].sort(), ["example.com", "www.example.com"]);
    assert.deepEqual([...(inputs.redirectSources ?? [])].sort(), ["/also-moved/", "/moved"]);
    assert.deepEqual(inputs.runtimeRoutes, [{ path: "/webmention", prefix: false }]);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("formatReport and exitCodeFor summarize a report", () => {
  const clean = {
    version: 1 as const, pagesScanned: 2, referencesChecked: 3, externalReferencesSkipped: 0, externalReferences: [], problems: [],
  };
  assert.equal(exitCodeFor(clean), 0);
  assert.match(formatReport(clean), /every internal reference resolves/);
  const dirty = { ...clean, externalReferencesSkipped: 4, problems: [problem("missing-target", "/", "/x", "/x")] };
  assert.equal(exitCodeFor(dirty), 1);
  assert.match(formatReport(dirty), /4 off-site link\(s\) not checked/);
  assert.match(formatReport(dirty), /missing target \/x/);
});
