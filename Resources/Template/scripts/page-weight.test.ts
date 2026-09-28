import test from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import {
  HEAVY_PAGE_BYTES,
  NoBuiltPagesError,
  OVERSIZED_IMAGE_BYTES,
  VERY_HEAVY_PAGE_BYTES,
  exitCodeFor,
  extractPageReferences,
  formatBytes,
  formatReport,
  scan,
  type ScanOptions,
} from "./page-weight";

const KB = 1024;

/** A throwaway `dist/` populated from `files` (relative path → contents, or a byte count of filler). */
function makeDist(files: Record<string, string | number>): string {
  const root = mkdtempSync(join(tmpdir(), "anglesite-page-weight-"));
  for (const [path, contents] of Object.entries(files)) {
    mkdirSync(dirname(join(root, path)), { recursive: true });
    writeFileSync(join(root, path), typeof contents === "number" ? Buffer.alloc(contents) : contents);
  }
  return root;
}

function scanFiles(files: Record<string, string | number>, options: ScanOptions = {}) {
  const root = makeDist(files);
  try {
    return scan(root, options);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

const img = (src: string) => `<img src="${src}" width="10" height="10" alt="">`;

// ---------------------------------------------------------------------------
// Clean site
// ---------------------------------------------------------------------------

test("a small site with dimensioned images has no problems", () => {
  const report = scanFiles({
    "index.html": `<link rel="stylesheet" href="/style.css">${img("/a.png")}`,
    "style.css": 2 * KB,
    "a.png": 10 * KB,
  });
  assert.deepEqual(report.problems, []);
  assert.equal(report.pagesScanned, 1);
  assert.equal(exitCodeFor(report), 0);
  assert.match(formatReport(report), /within its weight budget/);
});

// ---------------------------------------------------------------------------
// Page weight
// ---------------------------------------------------------------------------

test("page weight is the HTML plus every distinct same-site asset it references", () => {
  const html = `<link rel="stylesheet" href="/s.css"><link rel="stylesheet" href="s.css"><script src="/app.js"></script>${img("/a.png")}`;
  const report = scanFiles({ "index.html": html, "s.css": 1000, "app.js": 2000, "a.png": 3000 });
  assert.equal(report.heaviestPageBytes, Buffer.byteLength(html) + 1000 + 2000 + 3000);
});

test("a page over 1.5 MB is heavy, and one over 4 MB is very heavy", () => {
  const report = scanFiles({
    "index.html": `<script src="/big.js"></script>`,
    "big.js": HEAVY_PAGE_BYTES,
    "huge/index.html": `<script src="/huge.js"></script>`,
    "huge.js": VERY_HEAVY_PAGE_BYTES,
  });
  const kinds = report.problems.map((p) => [p.kind, p.page]);
  assert.deepEqual(kinds, [
    ["heavy-page", "/"],
    ["very-heavy-page", "/huge/"],
  ]);
  assert.equal(exitCodeFor(report), 1);
});

test("a shared asset counts toward every page that uses it", () => {
  const report = scanFiles({
    "index.html": `<script src="/big.js"></script>`,
    "about/index.html": `<script src="/big.js"></script>`,
    "big.js": HEAVY_PAGE_BYTES,
  });
  assert.deepEqual(report.problems.map((p) => p.page), ["/", "/about/"]);
});

test("srcset candidates count once, as the largest", () => {
  const html = `<img src="/s.jpg" srcset="/s.jpg 400w, /m.jpg 800w, /l.jpg 1600w" width="1" height="1" alt="">`;
  const report = scanFiles({ "index.html": html, "s.jpg": 100, "m.jpg": 200, "l.jpg": 300 });
  assert.equal(report.heaviestPageBytes, Buffer.byteLength(html) + 300);
});

test("a <picture> counts once, as its largest source", () => {
  const html = `<picture><source srcset="/a.avif" type="image/avif"><source srcset="/a.webp 1x, /a2.webp 2x"><img src="/a.jpg" width="1" height="1" alt=""></picture>`;
  const report = scanFiles({ "index.html": html, "a.avif": 100, "a.webp": 200, "a2.webp": 250, "a.jpg": 400 });
  assert.equal(report.heaviestPageBytes, Buffer.byteLength(html) + 400);
});

test("off-site references count as 0 and are reported as skipped", () => {
  const html = `<script src="https://cdn.example/x.js"></script><link rel="stylesheet" href="https://mysite.example/s.css">`;
  const report = scanFiles({ "index.html": html, "s.css": 500 }, { siteHosts: new Set(["mysite.example"]) });
  assert.equal(report.externalReferencesSkipped, 1);
  assert.equal(report.heaviestPageBytes, Buffer.byteLength(html) + 500);
});

test("a reference to a missing file counts as 0", () => {
  const html = `<script src="/gone.js"></script>`;
  const report = scanFiles({ "index.html": html });
  assert.equal(report.heaviestPageBytes, Buffer.byteLength(html));
});

test("commented-out and inline-script markup carries no weight", () => {
  const refs = extractPageReferences(
    `<!-- <script src="/old.js"></script> --><script>const s = '<link rel="stylesheet" href="/x.css">';</script>`,
  );
  assert.deepEqual(refs, { single: [], groups: [], images: [] });
});

// ---------------------------------------------------------------------------
// Images
// ---------------------------------------------------------------------------

test("an image over 500 KB is reported once, grouped by asset, with the pages using it", () => {
  const report = scanFiles({
    "index.html": img("/hero.jpg"),
    "about/index.html": img("../hero.jpg"),
    "hero.jpg": OVERSIZED_IMAGE_BYTES + 1,
    "ok.jpg": OVERSIZED_IMAGE_BYTES,
  });
  assert.deepEqual(report.problems, [
    { kind: "oversized-image", asset: "/hero.jpg", bytes: OVERSIZED_IMAGE_BYTES + 1, pages: ["/", "/about/"] },
  ]);
});

test("BMP, TIFF and HEIC files are critical wherever they sit in dist/, referenced or not", () => {
  const report = scanFiles({
    "index.html": img("/photo.heic"),
    "photo.heic": 10,
    "scan.tiff": 10,
    "old.BMP": 10,
  });
  assert.deepEqual(
    report.problems.map((p) => [p.kind, p.asset, p.pages]),
    [
      ["non-web-image-format", "/old.BMP", []],
      ["non-web-image-format", "/photo.heic", ["/"]],
      ["non-web-image-format", "/scan.tiff", []],
    ],
  );
});

test("an oversized non-web image is reported only as a non-web format", () => {
  const report = scanFiles({ "index.html": img("/big.bmp"), "big.bmp": OVERSIZED_IMAGE_BYTES * 2 });
  assert.deepEqual(report.problems.map((p) => p.kind), ["non-web-image-format"]);
});

test("images without width or height are one problem per page, with up to three examples", () => {
  const report = scanFiles({
    "index.html": ["/1.png", "/2.png", "/3.png", "/4.png"].map((src) => `<img src="${src}" alt="">`).join("") + img("/ok.png"),
    "about/index.html": `<img src="/5.png" width="10" alt="">`,
  });
  assert.deepEqual(report.problems, [
    { kind: "img-missing-dimensions", page: "/", count: 4, examples: ["/1.png", "/2.png", "/3.png"] },
  ]);
});

test("page problems come first, sorted by page, then asset problems by asset", () => {
  const report = scanFiles({
    "z/index.html": `<img src="/b.png" alt="">`,
    "index.html": `<img src="/a.png" alt="">`,
    "b.png": OVERSIZED_IMAGE_BYTES + 1,
    "a.png": OVERSIZED_IMAGE_BYTES + 1,
  });
  assert.deepEqual(
    report.problems.map((p) => p.page ?? p.asset),
    ["/", "/z/", "/a.png", "/b.png"],
  );
});

// ---------------------------------------------------------------------------
// Reporting and CLI
// ---------------------------------------------------------------------------

test("formatBytes uses KB under a megabyte and one decimal of MB above", () => {
  assert.equal(formatBytes(512 * KB), "512 KB");
  assert.equal(formatBytes(1.5 * 1024 * KB), "1.5 MB");
});

test("a dist/ with no HTML throws NoBuiltPagesError", () => {
  assert.throws(() => scanFiles({ "style.css": "x" }), NoBuiltPagesError);
});
