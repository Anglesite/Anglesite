# Website Import — Transform Stage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the transform stage of website import (#1615): a pure-Swift pipeline that turns a crawled `ImportSnapshot` of an external site into content files in a scaffolded Anglesite `Source/` tree, plus the JS extraction engine the crawl stage will inject.

**Architecture:** A new `Sources/AnglesiteCore/SiteImport/` module of pure, `Sendable` value types and static functions — snapshot in, files + report out — with zero WebKit/network dependency so everything is SwiftPM-testable from JSON fixtures. A sibling `JS/import-engine/` subproject (Readability + Turndown + microformats-parser, esbuild IIFE bundle) does all HTML→Markdown work at capture time; the Swift side only ever sees Markdown and structured records.

**Tech Stack:** Swift 6.4 / Swift Testing (AnglesiteCore + AnglesiteCoreTests), CryptoKit (SHA-256), Foundation `XMLParser` (feed parsing); TypeScript + esbuild + vitest/jsdom + oxlint (JS engine, mirroring `JS/safari-extension/`).

**Spec:** `docs/superpowers/specs/2026-08-21-website-import-transform-design.md`

**Deliberate deferrals (per spec):** the crawl stage itself, the **File ▸ Import from URL…** menu item, and the summary *screen* land with the crawl-stage plan. This plan ends at `ImportTransform.run(...)` + `ImportSummaryModel` (the screen's data source), both fully testable from fixtures.

## Global Constraints

- Swift targets macOS 27, Swift 6.4; all new Swift code goes in `Sources/AnglesiteCore/SiteImport/` and compiles into the SwiftPM `AnglesiteCore` target (CI runs `swift test` on macos-26 — do not call macOS-27-only symbols at runtime; see CLAUDE.md ▸ Build).
- Tests use **Swift Testing** (`import Testing`, `@Test`, `#expect`), in `Tests/AnglesiteCoreTests/SiteImport*.swift`.
- Run tests with: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter <SuiteName>` (the default CLT toolchain is broken; `--filter` still compiles the whole package).
- **No new Swift dependencies.** The only approved new JS dependencies are `@mozilla/readability` (Apache-2.0), `turndown` (MIT), `microformats-parser` (MIT) — runtime deps of `JS/import-engine/` only.
- JS subproject follows `JS/safari-extension/` conventions exactly: `"type": "module"`, esbuild `--bundle --format=iife`, vitest + jsdom, oxlint, `"engines": {"node": ">=22"}`, best-effort bash build script that exits 0 without npm.
- Frontmatter must match the template's `.strict()` zod schemas **verbatim** (fields listed in Task 8) — an unknown key is a site build error.
- Doc comments follow `docs/comment-style-guide.md` (DocC; CI fails on broken symbol links; never write a partial `- Parameters:` block).
- Conventional commits, subject ≤72 chars, scoped `feat(#1615): …` / `test(#1615): …`. #1615 is a multi-PR tracking issue — do **not** use `fix(#1615):` (closing-keyword collision, CONTRIBUTING.md).
- No `Process()` outside ProcessSupervisor; nothing in this plan spawns processes.
- Hard caps are reported, never silent.

## File Structure

| Path | Responsibility |
|---|---|
| `Sources/AnglesiteCore/SiteImport/ImportSnapshot.swift` | Crawl→transform contract: `Codable` snapshot types, URL normalization, HTML→Markdown conversion lookup |
| `Sources/AnglesiteCore/SiteImport/ImportItem.swift` | The unit of imported content + `ImportProblem` |
| `Sources/AnglesiteCore/SiteImport/WordPressRESTRung.swift` | Ladder rung 1: WP REST payloads → items |
| `Sources/AnglesiteCore/SiteImport/FeedRung.swift` | Ladder rung 2: RSS/Atom/JSON Feed → items, excerpt-only detection |
| `Sources/AnglesiteCore/SiteImport/MicroformatsRung.swift` | Ladder rung 3: mf2 JSON → items with post-kind hints |
| `Sources/AnglesiteCore/SiteImport/ImportSourceResolver.swift` | Ladder orchestration, dedupe, archive-URL skips, homepage split |
| `Sources/AnglesiteCore/SiteImport/ContentClassifier.swift` | Item → collection/page destination |
| `Sources/AnglesiteCore/SiteImport/ImportEmitter.swift` | Destination → file path + frontmatter + body (strict schemas) |
| `Sources/AnglesiteCore/SiteImport/AssetLocalizer.swift` | Captured images → `public/images/`, Markdown URL rewrite |
| `Sources/AnglesiteCore/SiteImport/RedirectsEmitter.swift` | Changed routes → `redirects.json` 301 entries |
| `Sources/AnglesiteCore/SiteImport/ImportSiteConfig.swift` | Homepage seeds → `.site-config` KEY=value rewrite |
| `Sources/AnglesiteCore/SiteImport/ImportPlan.swift` | Plan (pre-write summary) + `ImportReport` (post-write, persisted) |
| `Sources/AnglesiteCore/SiteImport/ImportTransform.swift` | Orchestrator: snapshot → files + report, step streaming |
| `Sources/AnglesiteCore/SiteImport/ImportSummaryModel.swift` | Owner-language strings for the future summary screen |
| `JS/import-engine/` | `package.json`, `tsconfig.json`, `vitest.config.ts`, `src/extract.ts`, `src/global.ts`, `test/extract.test.ts` |
| `scripts/build-import-engine.sh` | esbuild → `Resources/ImportEngine/import-engine.js` |
| `Tests/AnglesiteCoreTests/SiteImport*.swift` | One test file per component |
| `Tests/AnglesiteCoreTests/Fixtures/SiteImport/` | JSON snapshot fixtures + golden `Source/` trees |

---

### Task 1: ImportSnapshot contract

**Files:**
- Create: `Sources/AnglesiteCore/SiteImport/ImportSnapshot.swift`
- Test: `Tests/AnglesiteCoreTests/SiteImportSnapshotTests.swift`

**Interfaces:**
- Consumes: nothing (root of the module).
- Produces (every later task depends on these exact names):

```swift
public struct ImportSnapshot: Codable, Sendable, Equatable {
    public var siteURL: String
    public var probes: SiteProbes
    public var pages: [CapturedPage]
    public var assets: [CapturedAsset]
    /// SHA-256 hex of a UTF-8 HTML string → the Markdown the capture engine produced for it.
    public var conversions: [String: String]
    public init(siteURL: String, probes: SiteProbes, pages: [CapturedPage],
                assets: [CapturedAsset], conversions: [String: String])
    public static func htmlKey(_ html: String) -> String
    public func markdown(forHTML html: String) -> String?
    public static func normalizeURL(_ raw: String) -> String
    public func page(forURL url: String) -> CapturedPage?
    public func asset(forURL url: String) -> CapturedAsset?
}
public struct SiteProbes: Codable, Sendable, Equatable {
    public var wpPostsJSON: String?
    public var wpPagesJSON: String?
    public var feeds: [CapturedFeed]
    public init(wpPostsJSON: String? = nil, wpPagesJSON: String? = nil, feeds: [CapturedFeed] = [])
}
public struct CapturedFeed: Codable, Sendable, Equatable {
    public var url: String
    public var body: String
    public init(url: String, body: String)
}
public struct CapturedPage: Codable, Sendable, Equatable {
    public var url: String
    public var extraction: ExtractionRecord
    public init(url: String, extraction: ExtractionRecord)
}
public struct ExtractionRecord: Codable, Sendable, Equatable {
    public var title: String?
    public var byline: String?
    public var publishedISO: String?
    public var lang: String?
    public var canonical: String?
    public var markdown: String
    public var excerpt: String?
    public var images: [String]
    public var mf2JSON: String?
    public var feedLinks: [String]
    public init(title: String? = nil, byline: String? = nil, publishedISO: String? = nil,
                lang: String? = nil, canonical: String? = nil, markdown: String,
                excerpt: String? = nil, images: [String] = [], mf2JSON: String? = nil,
                feedLinks: [String] = [])
}
public struct CapturedAsset: Codable, Sendable, Equatable {
    public var sourceURL: String
    /// Path of the downloaded bytes relative to the snapshot directory (e.g. `assets/ab12….jpg`).
    public var relativePath: String
    public init(sourceURL: String, relativePath: String)
}
```

`normalizeURL` rules: trim whitespace; lowercase scheme and host; drop fragment; drop a single trailing `/` unless the path is `/` or empty; keep the query string. `page(forURL:)` matches on `normalizeURL` of the page's `canonical ?? url`. `asset(forURL:)` matches on `normalizeURL(sourceURL)`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import AnglesiteCore

@Suite struct SiteImportSnapshotTests {
    @Test func normalizeURLDropsFragmentAndTrailingSlash() {
        #expect(ImportSnapshot.normalizeURL("HTTPS://Example.COM/Blog/Post/#x")
            == "https://example.com/Blog/Post")
        #expect(ImportSnapshot.normalizeURL("https://example.com/") == "https://example.com/")
        #expect(ImportSnapshot.normalizeURL("https://example.com/p?p=12") == "https://example.com/p?p=12")
    }

    @Test func htmlKeyIsStableSHA256Hex() {
        // echo -n "<p>hi</p>" | shasum -a 256
        #expect(ImportSnapshot.htmlKey("<p>hi</p>")
            == "89d9eb1e46781e94aab52a54366a25f5b3f2f6cbd42956a5a3ba26be6c4dfa39")
    }

    @Test func conversionLookupAndPageLookupRoundTrip() throws {
        let html = "<p>Body</p>"
        let page = CapturedPage(
            url: "https://example.com/about/",
            extraction: ExtractionRecord(title: "About", markdown: "Body"))
        let snapshot = ImportSnapshot(
            siteURL: "https://example.com", probes: SiteProbes(), pages: [page],
            assets: [CapturedAsset(sourceURL: "https://example.com/a.jpg", relativePath: "assets/a.jpg")],
            conversions: [ImportSnapshot.htmlKey(html): "Body"])
        #expect(snapshot.markdown(forHTML: html) == "Body")
        #expect(snapshot.page(forURL: "https://example.com/about") != nil)
        #expect(snapshot.asset(forURL: "https://example.com/a.jpg")?.relativePath == "assets/a.jpg")
        let data = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(ImportSnapshot.self, from: data) == snapshot)
    }
}
```

Before writing the expected `htmlKey` hash, compute it: `printf '%s' '<p>hi</p>' | shasum -a 256` and paste the real value into the test (the hex above is illustrative — replace it with the computed one).

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SiteImportSnapshotTests`
Expected: compile failure — `ImportSnapshot` not found.

- [ ] **Step 3: Implement `ImportSnapshot.swift`**

`htmlKey` via CryptoKit:

```swift
import CryptoKit
import Foundation

// (types as declared in Interfaces above, with doc comments per docs/comment-style-guide.md)

extension ImportSnapshot {
    public static func htmlKey(_ html: String) -> String {
        SHA256.hash(data: Data(html.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func markdown(forHTML html: String) -> String? { conversions[Self.htmlKey(html)] }

    public static func normalizeURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else { return trimmed }
        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.path.count > 1, components.path.hasSuffix("/") {
            components.path = String(components.path.dropLast())
        }
        return components.string ?? trimmed
    }

    public func page(forURL url: String) -> CapturedPage? {
        let key = Self.normalizeURL(url)
        return pages.first { Self.normalizeURL($0.extraction.canonical ?? $0.url) == key }
    }

    public func asset(forURL url: String) -> CapturedAsset? {
        let key = Self.normalizeURL(url)
        return assets.first { Self.normalizeURL($0.sourceURL) == key }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: same command. Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SiteImport/ImportSnapshot.swift Tests/AnglesiteCoreTests/SiteImportSnapshotTests.swift
git commit -m "feat(#1615): add ImportSnapshot crawl-to-transform contract"
```

---

### Task 2: JS/import-engine subproject

**Files:**
- Create: `JS/import-engine/package.json`, `JS/import-engine/tsconfig.json`, `JS/import-engine/vitest.config.ts`, `JS/import-engine/src/extract.ts`, `JS/import-engine/src/global.ts`, `JS/import-engine/test/extract.test.ts`
- Create: `scripts/build-import-engine.sh` (mode 755)
- Modify: `.gitignore` (add `Resources/ImportEngine/`), `project.yml` (app target `preBuildScripts`, next to the existing `build-wysiwyg-engine.sh` entry around line 90: `- name: Build import engine` / `script: "\"${PROJECT_DIR}/scripts/build-import-engine.sh\""` / `basedOnDependencyAnalysis: false`)

**Interfaces:**
- Consumes: nothing Swift-side yet (the crawl stage will inject the bundle).
- Produces: `extractPage(doc: Document, url: string): ExtractionRecord` (TS), and a global `window.__anglesiteImportExtract(): string` returning the record as JSON. The TS `ExtractionRecord` fields mirror Task 1's Swift struct exactly: `title, byline, publishedISO, lang, canonical, markdown, excerpt, images, mf2JSON, feedLinks` (nullable fields are `string | null`, `images`/`feedLinks` are `string[]`).

- [ ] **Step 1: Scaffold the package**

`JS/import-engine/package.json` (deps are the three approved libraries; devDeps mirror `JS/safari-extension/package.json`):

```json
{
  "name": "@anglesite/import-engine",
  "version": "0.1.0",
  "private": true,
  "description": "Injected extraction engine for website import (#1615): Readability article extraction, Turndown HTML-to-Markdown, microformats2 parsing. Runs in the capture WKWebView. Spec: docs/superpowers/specs/2026-08-21-website-import-transform-design.md",
  "type": "module",
  "scripts": {
    "build": "esbuild src/global.ts --bundle --format=iife --target=es2022 --outfile=../../Resources/ImportEngine/import-engine.js",
    "typecheck": "tsc --noEmit",
    "lint": "oxlint src test",
    "test": "vitest run",
    "test:watch": "vitest"
  },
  "dependencies": {
    "@mozilla/readability": "^0.6.0",
    "microformats-parser": "^2.0.2",
    "turndown": "^7.2.1"
  },
  "devDependencies": {
    "@types/node": "^26.2.0",
    "@types/turndown": "^5.0.5",
    "esbuild": "^0.28.1",
    "jsdom": "^30.0.1",
    "oxlint": "^1.77.0",
    "typescript": "^7.0.2",
    "vitest": "^4.1.10"
  },
  "engines": { "node": ">=22" }
}
```

Copy `tsconfig.json` and `vitest.config.ts` from `JS/safari-extension/` (vitest `environment: "jsdom"`). Version pins: run `npm view <pkg> version` for each of the three runtime deps and use the current major — the carets above are floors, not gospel.

- [ ] **Step 2: Write the failing test**

`JS/import-engine/test/extract.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { JSDOM } from "jsdom";
import { extractPage } from "../src/extract.ts";

const ARTICLE = `<!doctype html><html lang="en"><head><title>Hello — My Site</title>
<link rel="canonical" href="https://example.com/blog/hello">
<link rel="alternate" type="application/rss+xml" href="/feed.xml"></head>
<body><article class="h-entry"><h1 class="p-name">Hello</h1>
<time class="dt-published" datetime="2024-05-01T10:00:00Z">May 1</time>
<div class="e-content"><p>First <strong>post</strong>.</p>
<img src="https://example.com/images/cat.jpg" alt="a cat"></div></article>
<footer>© nav cruft that Readability should drop</footer></body></html>`;

describe("extractPage", () => {
  it("extracts title, markdown, images, mf2, and feed links", () => {
    const dom = new JSDOM(ARTICLE, { url: "https://example.com/blog/hello/" });
    const record = extractPage(dom.window.document, "https://example.com/blog/hello/");
    expect(record.title).toBe("Hello");
    expect(record.lang).toBe("en");
    expect(record.canonical).toBe("https://example.com/blog/hello");
    expect(record.markdown).toContain("First **post**.");
    expect(record.images).toContain("https://example.com/images/cat.jpg");
    expect(record.feedLinks).toEqual(["https://example.com/feed.xml"]);
    const mf2 = JSON.parse(record.mf2JSON ?? "{}");
    expect(mf2.items[0].type).toContain("h-entry");
    expect(record.publishedISO).toBe("2024-05-01T10:00:00Z");
  });
});
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd JS/import-engine && npm install && npm test`
Expected: FAIL — `src/extract.ts` does not exist.

- [ ] **Step 4: Implement `src/extract.ts` and `src/global.ts`**

```ts
// src/extract.ts
import { Readability } from "@mozilla/readability";
import { mf2 } from "microformats-parser";
import TurndownService from "turndown";

export interface ExtractionRecord {
  title: string | null;
  byline: string | null;
  publishedISO: string | null;
  lang: string | null;
  canonical: string | null;
  markdown: string;
  excerpt: string | null;
  images: string[];
  mf2JSON: string | null;
  feedLinks: string[];
}

const FEED_TYPES = new Set([
  "application/rss+xml", "application/atom+xml", "application/feed+json", "application/json",
]);

export function extractPage(doc: Document, url: string): ExtractionRecord {
  const html = doc.documentElement.outerHTML;
  const canonical =
    doc.querySelector<HTMLLinkElement>('link[rel="canonical"]')?.href ?? null;
  const feedLinks = [...doc.querySelectorAll<HTMLLinkElement>('link[rel="alternate"]')]
    .filter((l) => FEED_TYPES.has(l.type))
    .map((l) => l.href);
  const publishedISO =
    doc.querySelector<HTMLTimeElement>("time[datetime]")?.dateTime ??
    doc.querySelector<HTMLMetaElement>('meta[property="article:published_time"]')?.content ?? null;

  // Readability mutates its input — parse a clone.
  const article = new Readability(doc.cloneNode(true) as Document).parse();
  const turndown = new TurndownService({ headingStyle: "atx", codeBlockStyle: "fenced" });
  const bodyHTML = article?.content ?? doc.body.innerHTML;
  const markdown = turndown.turndown(bodyHTML);

  const container = doc.createElement("div");
  container.innerHTML = bodyHTML;
  const images = [...container.querySelectorAll<HTMLImageElement>("img[src]")].map((i) => i.src);

  let mf2JSON: string | null = null;
  try {
    mf2JSON = JSON.stringify(mf2(html, { baseUrl: url }));
  } catch {
    mf2JSON = null; // malformed markup: mf2 is an enhancement, not a requirement
  }

  return {
    title: article?.title || doc.title.split(/\s+[—|–-]\s+/)[0] || null,
    byline: article?.byline ?? null,
    publishedISO,
    lang: doc.documentElement.lang || null,
    canonical,
    markdown,
    excerpt: article?.excerpt ?? null,
    images,
    mf2JSON,
    feedLinks,
  };
}
```

```ts
// src/global.ts — the injected entry point
import { extractPage } from "./extract.ts";
declare global { interface Window { __anglesiteImportExtract: () => string } }
window.__anglesiteImportExtract = () =>
  JSON.stringify(extractPage(document, document.location.href));
```

- [ ] **Step 5: Run test, typecheck, lint to verify pass**

Run: `cd JS/import-engine && npm test && npm run typecheck && npm run lint`
Expected: PASS / clean. Adjust the title-splitting or mf2 expectations only if the real library output differs — assert on real behavior, don't loosen to `toBeTruthy()`.

- [ ] **Step 6: Add the build script + wiring**

`scripts/build-import-engine.sh`: copy `scripts/build-safari-extension.sh`'s structure verbatim (same best-effort npm guard, `set -euo pipefail`), with `EXT_DIR="$REPO_ROOT/JS/import-engine"`, `DEST_DIR="$REPO_ROOT/Resources/ImportEngine"`, an added `mkdir -p "$DEST_DIR"` (this destination is fully generated), and `npm run build` as the build command. Add `Resources/ImportEngine/` to `.gitignore`. Add the pre-build script entry to `project.yml` as listed in **Files**. Run `xcodegen generate` and `scripts/build-import-engine.sh`; verify `Resources/ImportEngine/import-engine.js` appears.

- [ ] **Step 7: Commit**

```bash
git add JS/import-engine scripts/build-import-engine.sh .gitignore project.yml
git commit -m "feat(#1615): add JS/import-engine extraction bundle"
```

---

### Task 3: ImportItem + WordPress REST rung

**Files:**
- Create: `Sources/AnglesiteCore/SiteImport/ImportItem.swift`, `Sources/AnglesiteCore/SiteImport/WordPressRESTRung.swift`
- Test: `Tests/AnglesiteCoreTests/SiteImportWordPressRungTests.swift`

**Interfaces:**
- Consumes: `ImportSnapshot`, `ImportSnapshot.markdown(forHTML:)`, `ImportSnapshot.page(forURL:)` (Task 1).
- Produces:

```swift
public struct ImportProblem: Codable, Sendable, Equatable {
    public var sourceURL: String
    public var message: String
    public init(sourceURL: String, message: String)
}
public struct ImportItem: Sendable, Equatable {
    public enum Rung: String, Codable, Sendable {
        case wpREST = "wp-rest", feed, microformats, readability
    }
    public enum Hint: Sendable, Equatable {
        case wpPost, wpPage
        case note, article
        case photo(image: String)
        case bookmark(of: String)
        case like(of: String)
        case reply(to: String)
        case none
    }
    public var sourceURL: String        // normalized
    public var title: String?
    public var published: Date?
    public var lang: String?
    public var markdown: String
    public var excerpt: String?
    public var images: [String]
    public var tags: [String]
    public var rung: Rung
    public var hint: Hint
    public init(sourceURL: String, title: String? = nil, published: Date? = nil,
                lang: String? = nil, markdown: String, excerpt: String? = nil,
                images: [String] = [], tags: [String] = [], rung: Rung, hint: Hint)
}
public enum WordPressRESTRung {
    public static func items(from snapshot: ImportSnapshot)
        -> (items: [ImportItem], problems: [ImportProblem])
}
```

WP REST decoding: `wpPostsJSON`/`wpPagesJSON` are JSON arrays of objects with `link` (String), `date_gmt` (String, `yyyy-MM-dd'T'HH:mm:ss`), `title.rendered` (String, HTML-entity-bearing), `content.rendered` (String, HTML), `excerpt.rendered` (String, HTML). Body resolution order: `snapshot.markdown(forHTML: content.rendered)` → else the crawled page's `extraction.markdown` via `snapshot.page(forURL: link)` → else emit an `ImportProblem("no markdown conversion for …")` and skip the item. Titles: decode the five predefined XML entities plus numeric entities (`&#8217;` etc.) with a small local `decodeHTMLEntities(_:)` helper (do not pull in AttributedString HTML import — it is main-thread WebKit).

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import AnglesiteCore

@Suite struct SiteImportWordPressRungTests {
    private func makeSnapshot(postsJSON: String, conversions: [String: String] = [:]) -> ImportSnapshot {
        ImportSnapshot(siteURL: "https://example.com",
                       probes: SiteProbes(wpPostsJSON: postsJSON),
                       pages: [], assets: [], conversions: conversions)
    }

    @Test func decodesPostWithConvertedMarkdown() {
        let html = "<p>Hello <em>world</em></p>"
        let posts = """
        [{"link":"https://example.com/2024/05/01/hello/","date_gmt":"2024-05-01T10:00:00",
          "title":{"rendered":"Hello &#8212; again"},
          "content":{"rendered":"\(html.replacingOccurrences(of: "\"", with: "\\\""))"},
          "excerpt":{"rendered":"<p>Hello</p>"}}]
        """
        let snapshot = makeSnapshot(postsJSON: posts,
                                    conversions: [ImportSnapshot.htmlKey(html): "Hello *world*"])
        let result = WordPressRESTRung.items(from: snapshot)
        #expect(result.problems.isEmpty)
        #expect(result.items.count == 1)
        let item = result.items[0]
        #expect(item.title == "Hello — again")
        #expect(item.markdown == "Hello *world*")
        #expect(item.rung == .wpREST)
        #expect(item.hint == .wpPost)
        #expect(item.published != nil)
    }

    @Test func missingConversionFallsBackToCrawledPageThenProblem() {
        let posts = """
        [{"link":"https://example.com/p/","date_gmt":"2024-01-01T00:00:00",
          "title":{"rendered":"P"},"content":{"rendered":"<p>x</p>"},"excerpt":{"rendered":""}}]
        """
        var snapshot = makeSnapshot(postsJSON: posts)
        // No conversion, no page → problem.
        #expect(WordPressRESTRung.items(from: snapshot).problems.count == 1)
        // Crawled page exists → its readability markdown is used.
        snapshot.pages = [CapturedPage(url: "https://example.com/p/",
                                       extraction: ExtractionRecord(markdown: "x from page"))]
        let result = WordPressRESTRung.items(from: snapshot)
        #expect(result.items.first?.markdown == "x from page")
    }

    @Test func wpPagesGetPageHint() {
        var snapshot = makeSnapshot(postsJSON: "[]")
        snapshot.probes.wpPagesJSON = """
        [{"link":"https://example.com/about/","date_gmt":"2024-01-01T00:00:00",
          "title":{"rendered":"About"},"content":{"rendered":"<p>a</p>"},"excerpt":{"rendered":""}}]
        """
        snapshot.conversions = [ImportSnapshot.htmlKey("<p>a</p>"): "a"]
        #expect(WordPressRESTRung.items(from: snapshot).items.first?.hint == .wpPage)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SiteImportWordPressRungTests`
Expected: compile failure — `ImportItem` not found.

- [ ] **Step 3: Implement**

`ImportItem.swift` exactly as in Interfaces. `WordPressRESTRung.swift`:

```swift
import Foundation

public enum WordPressRESTRung {
    private struct WPEntry: Decodable {
        struct Rendered: Decodable { var rendered: String }
        var link: String
        var date_gmt: String
        var title: Rendered
        var content: Rendered
        var excerpt: Rendered
    }

    public static func items(from snapshot: ImportSnapshot)
        -> (items: [ImportItem], problems: [ImportProblem]) {
        var items: [ImportItem] = []
        var problems: [ImportProblem] = []
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")

        for (json, hint) in [(snapshot.probes.wpPostsJSON, ImportItem.Hint.wpPost),
                             (snapshot.probes.wpPagesJSON, ImportItem.Hint.wpPage)] {
            guard let json else { continue }
            guard let entries = try? JSONDecoder().decode([WPEntry].self, from: Data(json.utf8)) else {
                problems.append(ImportProblem(sourceURL: snapshot.siteURL,
                                              message: "Unreadable WordPress API payload"))
                continue
            }
            for entry in entries {
                let markdown = snapshot.markdown(forHTML: entry.content.rendered)
                    ?? snapshot.page(forURL: entry.link)?.extraction.markdown
                guard let markdown else {
                    problems.append(ImportProblem(sourceURL: entry.link,
                                                  message: "No Markdown conversion for this entry"))
                    continue
                }
                items.append(ImportItem(
                    sourceURL: ImportSnapshot.normalizeURL(entry.link),
                    title: decodeHTMLEntities(entry.title.rendered),
                    published: formatter.date(from: entry.date_gmt),
                    markdown: markdown,
                    excerpt: snapshot.markdown(forHTML: entry.excerpt.rendered),
                    rung: .wpREST, hint: hint))
            }
        }
        return (items, problems)
    }
}

/// Decodes the five predefined XML entities plus decimal/hex numeric character references.
func decodeHTMLEntities(_ value: String) -> String {
    var result = value
    for (entity, char) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                           ("&quot;", "\""), ("&#039;", "'"), ("&apos;", "'")] {
        result = result.replacingOccurrences(of: entity, with: char)
    }
    while let range = result.range(of: "&#[xX]?[0-9a-fA-F]+;", options: .regularExpression) {
        let body = result[range].dropFirst(2).dropLast()
        let scalar: UInt32? = body.hasPrefix("x") || body.hasPrefix("X")
            ? UInt32(body.dropFirst(), radix: 16) : UInt32(body)
        let replacement = scalar.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ""
        result.replaceSubrange(range, with: replacement)
    }
    return result
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SiteImport/ImportItem.swift Sources/AnglesiteCore/SiteImport/WordPressRESTRung.swift Tests/AnglesiteCoreTests/SiteImportWordPressRungTests.swift
git commit -m "feat(#1615): add ImportItem and WordPress REST rung"
```

---

### Task 4: Feed rung (RSS / Atom / JSON Feed)

**Files:**
- Create: `Sources/AnglesiteCore/SiteImport/FeedRung.swift`
- Test: `Tests/AnglesiteCoreTests/SiteImportFeedRungTests.swift`

**Interfaces:**
- Consumes: `ImportSnapshot`, `ImportItem`, `ImportProblem` (Tasks 1, 3).
- Produces: `public enum FeedRung { public static func items(from snapshot: ImportSnapshot) -> (items: [ImportItem], problems: [ImportProblem]) }`

Behavior: for each `CapturedFeed`, detect format — body starting with `{` → JSON Feed (`Codable`: `items[].url`, `items[].title`, `items[].content_html`, `items[].date_published` ISO8601); otherwise `XMLParser` for RSS 2.0 (`item` → `link`, `title`, `pubDate` RFC822, `content:encoded` else `description`) and Atom (`entry` → `link[rel=alternate]/@href` else first `link/@href`, `title`, `published` else `updated` ISO8601, `content` else `summary`). Body HTML → `snapshot.markdown(forHTML:)`. **Excerpt-only detection:** if the crawled page for the item URL exists and `feedMarkdown.count * 2 < pageMarkdown.count`, use the page's `extraction.markdown` as the body and keep the feed's metadata (title/date). Items produced with `rung: .feed, hint: .none`. Feed items with no resolvable URL are skipped with a problem entry.

- [ ] **Step 1: Write the failing tests** — three cases with inline fixture strings:

```swift
import Foundation
import Testing
@testable import AnglesiteCore

@Suite struct SiteImportFeedRungTests {
    @Test func parsesRSS2WithContentEncoded() {
        let html = "<p>Full <b>body</b> here</p>"
        let rss = """
        <?xml version="1.0"?><rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/">
        <channel><title>Feed</title><item>
        <title>Post One</title><link>https://example.com/one/</link>
        <pubDate>Wed, 01 May 2024 10:00:00 +0000</pubDate>
        <content:encoded><![CDATA[\(html)]]></content:encoded>
        </item></channel></rss>
        """
        let snapshot = ImportSnapshot(
            siteURL: "https://example.com", probes: SiteProbes(feeds: [CapturedFeed(url: "https://example.com/feed", body: rss)]),
            pages: [], assets: [], conversions: [ImportSnapshot.htmlKey(html): "Full **body** here"])
        let result = FeedRung.items(from: snapshot)
        #expect(result.items.count == 1)
        #expect(result.items[0].title == "Post One")
        #expect(result.items[0].markdown == "Full **body** here")
        #expect(result.items[0].rung == .feed)
        #expect(result.items[0].published != nil)
    }

    @Test func excerptOnlyFeedFallsBackToPageBody() {
        let excerptHTML = "<p>Teaser…</p>"
        let rss = """
        <?xml version="1.0"?><rss version="2.0"><channel><item>
        <title>Long Post</title><link>https://example.com/long/</link>
        <description><![CDATA[\(excerptHTML)]]></description>
        </item></channel></rss>
        """
        let longBody = String(repeating: "A full paragraph of real content. ", count: 20)
        let snapshot = ImportSnapshot(
            siteURL: "https://example.com",
            probes: SiteProbes(feeds: [CapturedFeed(url: "https://example.com/feed", body: rss)]),
            pages: [CapturedPage(url: "https://example.com/long/",
                                 extraction: ExtractionRecord(markdown: longBody))],
            assets: [], conversions: [ImportSnapshot.htmlKey(excerptHTML): "Teaser…"])
        let result = FeedRung.items(from: snapshot)
        #expect(result.items.first?.markdown == longBody)
        #expect(result.items.first?.title == "Long Post")
    }

    @Test func parsesJSONFeed() {
        let html = "<p>json body</p>"
        let feed = """
        {"version":"https://jsonfeed.org/version/1.1","title":"F",
         "items":[{"url":"https://example.com/j/","title":"J",
                   "date_published":"2024-05-01T10:00:00Z","content_html":"\(html.replacingOccurrences(of: "\"", with: "\\\""))"}]}
        """
        let snapshot = ImportSnapshot(
            siteURL: "https://example.com",
            probes: SiteProbes(feeds: [CapturedFeed(url: "https://example.com/feed.json", body: feed)]),
            pages: [], assets: [], conversions: [ImportSnapshot.htmlKey(html): "json body"])
        #expect(FeedRung.items(from: snapshot).items.first?.markdown == "json body")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SiteImportFeedRungTests`
Expected: compile failure — `FeedRung` not found.

- [ ] **Step 3: Implement `FeedRung.swift`**

One public entry + two internal parsers. The XML side is a single `XMLParserDelegate` class handling both RSS and Atom (element names don't collide: `item`/`entry`, `pubDate`/`published`). Structure:

```swift
import Foundation

public enum FeedRung {
    public static func items(from snapshot: ImportSnapshot)
        -> (items: [ImportItem], problems: [ImportProblem]) {
        var items: [ImportItem] = []
        var problems: [ImportProblem] = []
        for feed in snapshot.probes.feeds {
            let entries: [RawFeedEntry]
            if feed.body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
                entries = JSONFeedParser.entries(from: feed.body)
            } else {
                entries = FeedXMLParser.entries(from: feed.body)
            }
            if entries.isEmpty {
                problems.append(ImportProblem(sourceURL: feed.url, message: "Feed could not be read"))
            }
            for entry in entries {
                guard let url = entry.url else {
                    problems.append(ImportProblem(sourceURL: feed.url, message: "Feed entry without a link"))
                    continue
                }
                var markdown = entry.bodyHTML.flatMap(snapshot.markdown(forHTML:))
                if let page = snapshot.page(forURL: url) {
                    let pageMarkdown = page.extraction.markdown
                    if markdown == nil || markdown!.count * 2 < pageMarkdown.count {
                        markdown = pageMarkdown  // excerpt-only feed: metadata from feed, body from page
                    }
                }
                guard let markdown else {
                    problems.append(ImportProblem(sourceURL: url, message: "No Markdown conversion for this entry"))
                    continue
                }
                items.append(ImportItem(sourceURL: ImportSnapshot.normalizeURL(url),
                                        title: entry.title, published: entry.published,
                                        markdown: markdown, rung: .feed, hint: .none))
            }
        }
        return (items, problems)
    }
}

struct RawFeedEntry { var url: String?; var title: String?; var published: Date?; var bodyHTML: String? }
```

`JSONFeedParser`: `Decodable` structs, ISO8601 dates (`ISO8601DateFormatter`). `FeedXMLParser`: `XMLParser` delegate accumulating per-`item`/`entry` text for `title`, `link` (RSS text node; Atom `href` attribute, preferring `rel="alternate"`), `pubDate` (RFC822 via `DateFormatter` `"EEE, dd MMM yyyy HH:mm:ss Z"`, `en_US_POSIX`), `published`/`updated` (ISO8601), `content:encoded` → else `description` (RSS), `content` → else `summary` (Atom). CDATA arrives via `parser(_:foundCDATA:)` — decode as UTF-8 and append to the current text buffer.

- [ ] **Step 4: Run tests to verify they pass**

Run: same command. Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SiteImport/FeedRung.swift Tests/AnglesiteCoreTests/SiteImportFeedRungTests.swift
git commit -m "feat(#1615): add feed rung with excerpt-only detection"
```

---

### Task 5: Microformats rung

**Files:**
- Create: `Sources/AnglesiteCore/SiteImport/MicroformatsRung.swift`
- Test: `Tests/AnglesiteCoreTests/SiteImportMicroformatsRungTests.swift`

**Interfaces:**
- Consumes: `ImportSnapshot`, `ImportItem`, `ImportProblem`.
- Produces: `public enum MicroformatsRung { public static func items(from snapshot: ImportSnapshot) -> (items: [ImportItem], problems: [ImportProblem]) }`

Behavior: for each `CapturedPage` whose `extraction.mf2JSON` parses to canonical mf2 JSON (`{"items":[{"type":["h-entry"],"properties":{…}}], …}`), take each top-level `h-entry` (also look one level into an `h-feed`'s `children`). Property → hint mapping, first match wins:
`bookmark-of` → `.bookmark(of:)`, `like-of` → `.like(of:)`, `in-reply-to` → `.reply(to:)`, `photo` present *and* `content` absent-or-short(<50 chars) → `.photo(image:)`, `name` absent/empty → `.note`, else → `.article`. mf2 property values may be strings or `{"value": …}` objects — handle both. Body: `properties.content[0].html` → `snapshot.markdown(forHTML:)`, else `content[0].value` (or the `content[0]` string) as plain text, else the page's `extraction.markdown`. `published` via `ISO8601DateFormatter` (try with and without fractional seconds). Item URL: `properties.url[0]` else the page URL. `rung: .microformats`. Pages with no h-entry produce nothing (not a problem — most pages aren't posts).

- [ ] **Step 1: Write the failing tests** — cover a note (no name), a bookmark, and a photo:

```swift
import Foundation
import Testing
@testable import AnglesiteCore

@Suite struct SiteImportMicroformatsRungTests {
    private func page(mf2: String, url: String = "https://example.com/x/") -> CapturedPage {
        CapturedPage(url: url, extraction: ExtractionRecord(markdown: "fallback", mf2JSON: mf2))
    }
    private func snapshot(_ pages: [CapturedPage], conversions: [String: String] = [:]) -> ImportSnapshot {
        ImportSnapshot(siteURL: "https://example.com", probes: SiteProbes(),
                       pages: pages, assets: [], conversions: conversions)
    }

    @Test func titleLessEntryIsANote() {
        let mf2 = """
        {"items":[{"type":["h-entry"],"properties":{
          "content":[{"html":"<p>hi</p>","value":"hi"}],
          "published":["2024-05-01T10:00:00Z"],
          "url":["https://example.com/note-1/"]}}]}
        """
        let result = MicroformatsRung.items(from: snapshot(
            [page(mf2: mf2)], conversions: [ImportSnapshot.htmlKey("<p>hi</p>"): "hi"]))
        #expect(result.items.first?.hint == .note)
        #expect(result.items.first?.markdown == "hi")
        #expect(result.items.first?.sourceURL == "https://example.com/note-1")
    }

    @Test func bookmarkOfWins() {
        let mf2 = """
        {"items":[{"type":["h-entry"],"properties":{
          "name":["Cool link"],"bookmark-of":["https://other.example/post"],
          "content":[{"html":"<p>c</p>","value":"c"}],"url":["https://example.com/b-1/"]}}]}
        """
        let result = MicroformatsRung.items(from: snapshot(
            [page(mf2: mf2)], conversions: [ImportSnapshot.htmlKey("<p>c</p>"): "c"]))
        #expect(result.items.first?.hint == .bookmark(of: "https://other.example/post"))
        #expect(result.items.first?.title == "Cool link")
    }

    @Test func photoEntryCarriesImage() {
        let mf2 = """
        {"items":[{"type":["h-entry"],"properties":{
          "photo":["https://example.com/images/p.jpg"],
          "url":["https://example.com/p-1/"]}}]}
        """
        let result = MicroformatsRung.items(from: snapshot([page(mf2: mf2)]))
        #expect(result.items.first?.hint == .photo(image: "https://example.com/images/p.jpg"))
        #expect(result.items.first?.markdown == "fallback")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SiteImportMicroformatsRungTests`
Expected: compile failure — `MicroformatsRung` not found.

- [ ] **Step 3: Implement `MicroformatsRung.swift`** using `JSONSerialization` (mf2 JSON is heterogeneous — strings and objects in the same array — so `Codable` fights it; `[String: Any]` traversal with small typed accessors is clearer). Internal helpers: `stringValue(_ any: Any) -> String?` (string, or `["value"]` of a dict), `htmlValue(_ any: Any) -> String?` (`["html"]` of a dict).

- [ ] **Step 4: Run tests to verify they pass**

Run: same command. Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SiteImport/MicroformatsRung.swift Tests/AnglesiteCoreTests/SiteImportMicroformatsRungTests.swift
git commit -m "feat(#1615): add microformats2 rung with post-kind hints"
```

---

### Task 6: ImportSourceResolver (the ladder)

**Files:**
- Create: `Sources/AnglesiteCore/SiteImport/ImportSourceResolver.swift`
- Test: `Tests/AnglesiteCoreTests/SiteImportResolverTests.swift`

**Interfaces:**
- Consumes: `WordPressRESTRung.items(from:)`, `FeedRung.items(from:)`, `MicroformatsRung.items(from:)`, `ImportSnapshot`.
- Produces:

```swift
public struct ResolvedContent: Sendable, Equatable {
    public var items: [ImportItem]
    public var homepage: CapturedPage?
    public var skippedURLs: [String]
    public var problems: [ImportProblem]
}
public enum ImportSourceResolver {
    public static func resolve(_ snapshot: ImportSnapshot) -> ResolvedContent
}
```

Behavior, in order:
1. Run all three rungs; collect problems from each.
2. Merge items keyed by `sourceURL` (already normalized). Rung priority `wpREST > feed > microformats` — first writer wins in that order, later rungs never overwrite.
3. The homepage: the `CapturedPage` whose normalized URL equals `normalizeURL(snapshot.siteURL)` (path `/` or empty). It never becomes an item; it goes in `homepage`.
4. Readability fallback: every remaining `CapturedPage` not claimed by an item (match on normalized `canonical ?? url`) and not the homepage becomes an item — **unless** its URL path matches an archive pattern, in which case its URL goes to `skippedURLs`. Archive patterns (regex on the path): `^/(tag|tags|category|categories|author|page|search)(/|$)`, `/page/[0-9]+(/|$)$`, `^/(feed|rss|atom)(\.|/|$)`. Fallback items: `rung: .readability, hint: .none`, fields straight from `ExtractionRecord` (`publishedISO` parsed with `ISO8601DateFormatter`, with-and-without fractional seconds).
5. Sort `items` by `published` descending, `nil` dates last (stable, deterministic output).

- [ ] **Step 1: Write the failing tests** — a snapshot with one WP item, a feed item for the same URL (must not duplicate), one plain page, one `/tag/foo/` page, and a homepage:

```swift
import Foundation
import Testing
@testable import AnglesiteCore

@Suite struct SiteImportResolverTests {
    @Test func laddersDeduplicatesAndSkipsArchives() {
        let postHTML = "<p>wp</p>"
        let posts = """
        [{"link":"https://example.com/one/","date_gmt":"2024-05-01T10:00:00",
          "title":{"rendered":"One"},"content":{"rendered":"<p>wp</p>"},"excerpt":{"rendered":""}}]
        """
        let rss = """
        <?xml version="1.0"?><rss version="2.0"><channel><item>
        <title>One (from feed)</title><link>https://example.com/one/</link>
        <description><![CDATA[<p>feed</p>]]></description></item></channel></rss>
        """
        let snapshot = ImportSnapshot(
            siteURL: "https://example.com/",
            probes: SiteProbes(wpPostsJSON: posts,
                               feeds: [CapturedFeed(url: "https://example.com/feed", body: rss)]),
            pages: [
                CapturedPage(url: "https://example.com/",
                             extraction: ExtractionRecord(title: "My Site", markdown: "home")),
                CapturedPage(url: "https://example.com/one/",
                             extraction: ExtractionRecord(title: "One", markdown: "wp page")),
                CapturedPage(url: "https://example.com/contact/",
                             extraction: ExtractionRecord(title: "Contact", markdown: "call me")),
                CapturedPage(url: "https://example.com/tag/foo/",
                             extraction: ExtractionRecord(title: "Tag: foo", markdown: "archive")),
            ],
            assets: [],
            conversions: [ImportSnapshot.htmlKey(postHTML): "wp",
                          ImportSnapshot.htmlKey("<p>feed</p>"): "feed"])
        let resolved = ImportSourceResolver.resolve(snapshot)
        #expect(resolved.homepage?.extraction.title == "My Site")
        #expect(resolved.skippedURLs == ["https://example.com/tag/foo/"])
        #expect(resolved.items.count == 2) // "one" (wpREST wins) + "contact" fallback
        let one = resolved.items.first { $0.sourceURL == "https://example.com/one" }
        #expect(one?.rung == .wpREST)
        #expect(one?.markdown == "wp")
        let contact = resolved.items.first { $0.sourceURL == "https://example.com/contact" }
        #expect(contact?.rung == .readability)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SiteImportResolverTests`
Expected: compile failure — `ImportSourceResolver` not found.

- [ ] **Step 3: Implement `ImportSourceResolver.swift`** per the numbered behavior above (an `[String: ImportItem]` keyed merge, then the page sweep, then the sort).

- [ ] **Step 4: Run test to verify it passes**

Run: same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SiteImport/ImportSourceResolver.swift Tests/AnglesiteCoreTests/SiteImportResolverTests.swift
git commit -m "feat(#1615): add import source ladder resolver"
```

---

### Task 7: ContentClassifier

**Files:**
- Create: `Sources/AnglesiteCore/SiteImport/ContentClassifier.swift`
- Test: `Tests/AnglesiteCoreTests/SiteImportClassifierTests.swift`

**Interfaces:**
- Consumes: `ResolvedContent`, `ImportItem`, `ContentScaffold.slugify`, `ContentScaffold.normalizeRoute` (existing, `Sources/AnglesiteCore/ContentScaffold.swift`).
- Produces:

```swift
public enum ImportDestination: Sendable, Equatable {
    case collection(name: String, slug: String)
    case page(route: String)
}
public struct ClassifiedItem: Sendable, Equatable {
    public var item: ImportItem
    public var destination: ImportDestination
    public init(item: ImportItem, destination: ImportDestination)
}
public enum ContentClassifier {
    public static func classify(_ resolved: ResolvedContent, now: Date) -> [ClassifiedItem]
}
```

Slug: last non-empty path segment of `item.sourceURL`, run through `ContentScaffold.slugify`; if empty, `ContentScaffold.slugFromURL(item.sourceURL, now: now)`. Rules in order (v1 emits **only** into `blog`, `notes`, `photos`, `bookmarks`, `replies`, `likes`, or a page — never the other seven collections):

1. `hint == .wpPost` → `collection("blog", slug)`
2. `hint == .wpPage` → `page(route:)` from the source URL path (`ContentScaffold.normalizeRoute`)
3. `.bookmark` → `collection("bookmarks", slug)`; `.like` → `collection("likes", slug)`; `.reply` → `collection("replies", slug)`; `.photo` → `collection("photos", slug)`; `.note` → `collection("notes", slug)`; `.article` → `collection("blog", slug)`
4. `hint == .none`: path contains `/blog/` or `/posts/` or matches `/[0-9]{4}/[0-9]{2}/` → `collection("blog", slug)`
5. otherwise → `page(route:)` from the source URL path.

Titled blog items with no `published` date get `published = now` at classification time (the emitters require a date; flag nothing — the report's rung breakdown already shows fallback provenance).

- [ ] **Step 1: Write the failing table-driven test**

```swift
import Foundation
import Testing
@testable import AnglesiteCore

@Suite struct SiteImportClassifierTests {
    private func item(url: String, hint: ImportItem.Hint, title: String? = "T") -> ImportItem {
        ImportItem(sourceURL: url, title: title, markdown: "m", rung: .readability, hint: hint)
    }

    @Test(arguments: [
        ("https://e.com/2024/05/01/hi", ImportItem.Hint.wpPost, ImportDestination.collection(name: "blog", slug: "hi")),
        ("https://e.com/about", .wpPage, .page(route: "/about")),
        ("https://e.com/b-1", .bookmark(of: "https://x.com/p"), .collection(name: "bookmarks", slug: "b-1")),
        ("https://e.com/n-1", .note, .collection(name: "notes", slug: "n-1")),
        ("https://e.com/blog/heuristic-post", .none, .collection(name: "blog", slug: "heuristic-post")),
        ("https://e.com/contact", .none, .page(route: "/contact")),
    ])
    func classifies(_ url: String, _ hint: ImportItem.Hint, _ expected: ImportDestination) {
        let resolved = ResolvedContent(items: [item(url: url, hint: hint)],
                                       homepage: nil, skippedURLs: [], problems: [])
        let classified = ContentClassifier.classify(resolved, now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(classified.first?.destination == expected)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SiteImportClassifierTests`
Expected: compile failure.

- [ ] **Step 3: Implement `ContentClassifier.swift`** per the rule table.

- [ ] **Step 4: Run test to verify it passes** — same command, PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SiteImport/ContentClassifier.swift Tests/AnglesiteCoreTests/SiteImportClassifierTests.swift
git commit -m "feat(#1615): add deterministic content classifier"
```

---

### Task 8: ImportEmitter (paths + strict frontmatter)

**Files:**
- Create: `Sources/AnglesiteCore/SiteImport/ImportEmitter.swift`
- Test: `Tests/AnglesiteCoreTests/SiteImportEmitterTests.swift`

**Interfaces:**
- Consumes: `ClassifiedItem`, `ContentScaffold.postRelativePath(collection:slug:)`, `ContentScaffold.pageRelativePath(normalizedRoute:)` (existing).
- Produces:

```swift
public struct ImportFileEmission: Sendable, Equatable {
    public var relativePath: String   // relative to the site's Source/ root
    public var contents: String
}
public enum ImportEmitter {
    public static func emission(for classified: ClassifiedItem) -> ImportFileEmission
    static func yamlString(_ value: String) -> String   // internal, tested
}
```

Frontmatter per collection — these are the template's `.strict()` schemas **verbatim** (`Resources/Template/src/content.config.ts` + `src/lib/content-schemas.ts`); emit only fields with values, dates as `YYYY-MM-DD`:

| Collection | Required | Optional (emit when present) |
|---|---|---|
| `blog` | `title`, `pubDate`, `draft: false` | `description` (from `excerpt`), `lang` |
| `notes` | `publishDate`, `draft: false` | `lang`, `tags` |
| `photos` | `image`, `publishDate`, `draft: false` | `caption` (from `excerpt`), `lang`, `tags` |
| `bookmarks` | `bookmarkOf`, `publishDate`, `draft: false` | `title`, `image`, `lang`, `tags` |
| `replies` | `inReplyTo`, `publishDate`, `draft: false` | `lang` |
| `likes` | `likeOf`, `publishDate`, `draft: false` | `lang` |

`bookmarkOf`/`likeOf`/`inReplyTo` and `photos.image` come from the item's `Hint` payload. Pages emit a Markdown page: path `ContentScaffold.pageRelativePath(normalizedRoute:)` with `.astro` swapped for `.md`, frontmatter `layout: <relative path to BaseLayout>` + `title`, body = item markdown. The layout path depends on nesting depth: for `src/pages/about.md` it is `../layouts/BaseLayout.astro`; each additional route segment adds one `../`. `yamlString` wraps in double quotes and backslash-escapes `"` and `\` whenever the value contains `: `, `#`, `"`, a leading/trailing space, or starts with a YAML indicator character (`-?[]{}&*!|>%@`` `).

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import AnglesiteCore

@Suite struct SiteImportEmitterTests {
    @Test func emitsBlogPostWithStrictFrontmatter() {
        let item = ImportItem(sourceURL: "https://e.com/one", title: "Hello: World",
                              published: Date(timeIntervalSince1970: 1_714_557_600), // 2024-05-01
                              markdown: "Body", excerpt: "A teaser", rung: .wpREST, hint: .wpPost)
        let emission = ImportEmitter.emission(for:
            ClassifiedItem(item: item, destination: .collection(name: "blog", slug: "one")))
        #expect(emission.relativePath == "src/content/blog/one.md")
        #expect(emission.contents == """
        ---
        title: "Hello: World"
        pubDate: 2024-05-01
        description: A teaser
        draft: false
        ---

        Body
        """)
    }

    @Test func emitsBookmarkWithTarget() {
        let item = ImportItem(sourceURL: "https://e.com/b", title: nil,
                              published: Date(timeIntervalSince1970: 1_714_557_600),
                              markdown: "Why I saved this", rung: .microformats,
                              hint: .bookmark(of: "https://other.example/post"))
        let emission = ImportEmitter.emission(for:
            ClassifiedItem(item: item, destination: .collection(name: "bookmarks", slug: "b")))
        #expect(emission.contents.contains("bookmarkOf: https://other.example/post"))
        #expect(emission.contents.contains("publishDate: 2024-05-01"))
        #expect(!emission.contents.contains("title:"))
    }

    @Test func emitsMarkdownPageWithLayout() {
        let item = ImportItem(sourceURL: "https://e.com/about", title: "About",
                              markdown: "Hi", rung: .readability, hint: .none)
        let emission = ImportEmitter.emission(for:
            ClassifiedItem(item: item, destination: .page(route: "/about")))
        #expect(emission.relativePath == "src/pages/about.md")
        #expect(emission.contents.contains("layout: ../layouts/BaseLayout.astro"))
        #expect(emission.contents.contains("title: About"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail** — filter `SiteImportEmitterTests`, expect compile failure.

- [ ] **Step 3: Implement `ImportEmitter.swift`.** Date rendering: `DateFormatter` with `"yyyy-MM-dd"`, `en_US_POSIX`, UTC. Assemble frontmatter as ordered `(key, value)` pairs per the table, then `---\n` + lines + `---\n\n` + markdown body (exact shape asserted in Step 1's first test — match it byte for byte).

- [ ] **Step 4: Run tests to verify they pass** — PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SiteImport/ImportEmitter.swift Tests/AnglesiteCoreTests/SiteImportEmitterTests.swift
git commit -m "feat(#1615): emit strict-schema frontmatter and page files"
```

---

### Task 9: AssetLocalizer

**Files:**
- Create: `Sources/AnglesiteCore/SiteImport/AssetLocalizer.swift`
- Test: `Tests/AnglesiteCoreTests/SiteImportAssetLocalizerTests.swift`

**Interfaces:**
- Consumes: `ImportSnapshot.asset(forURL:)`, `CapturedAsset`, `LinkImageAsset.format(sniffing:)`, `LinkImageAsset.install(bytes:format:slug:siteDirectory:)`, `LinkImageAsset.maximumImageBytes`, `LinkImageAsset.publicURLPath(slug:format:)` (existing, `Sources/AnglesiteCore/LinkImageAsset.swift`), `ImportProblem`.
- Produces:

```swift
public enum AssetLocalizer {
    /// Rewrites remote image URLs in `markdown` to local `/images/…` paths, installing the
    /// captured bytes into the site's `public/images/`. Unmatched or refused images keep
    /// their remote URL and gain a problem entry (the strict CSP will block them at runtime).
    public static func localize(
        markdown: String, imageURLs: [String], itemSlug: String,
        snapshot: ImportSnapshot, snapshotDirectory: URL, siteDirectory: URL
    ) -> (markdown: String, installedPaths: [String], problems: [ImportProblem])
}
```

Behavior: for each URL in `imageURLs` (in order, index `n` from 1): find the `CapturedAsset`; read bytes from `snapshotDirectory.appendingPathComponent(asset.relativePath)`; refuse when bytes are missing, `count > LinkImageAsset.maximumImageBytes`, or `format(sniffing:)` returns nil (SVG and unknown types) — each refusal appends a problem (`"Image could not be imported: …"`) and leaves the URL untouched. Otherwise `LinkImageAsset.install(bytes:format:slug: "\(itemSlug)-\(n)", siteDirectory:)` and replace **all** occurrences of the original URL in the markdown with `LinkImageAsset.publicURLPath(slug:format:)`.

- [ ] **Step 1: Write the failing tests** — use `FileManager.default.temporaryDirectory` fixtures: a real 1×1 PNG (`Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!`) written into a fake snapshot dir, plus one asset entry whose file is absent. Assert: markdown rewritten to `/images/<slug>-1.png`, file exists under `siteDirectory/public/images/`, missing asset yields 1 problem and unchanged URL.

- [ ] **Step 2: Run tests to verify they fail** — filter `SiteImportAssetLocalizerTests`, compile failure.

- [ ] **Step 3: Implement `AssetLocalizer.swift`** per the behavior block (≈40 lines; string `replacingOccurrences(of:with:)` for the rewrite).

- [ ] **Step 4: Run tests to verify they pass.**

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SiteImport/AssetLocalizer.swift Tests/AnglesiteCoreTests/SiteImportAssetLocalizerTests.swift
git commit -m "feat(#1615): localize captured images into public/images"
```

---

### Task 10: RedirectsEmitter

**Files:**
- Create: `Sources/AnglesiteCore/SiteImport/RedirectsEmitter.swift`
- Test: `Tests/AnglesiteCoreTests/SiteImportRedirectsTests.swift`

**Interfaces:**
- Consumes: `ClassifiedItem`, `ImportDestination`, `ContentScaffold.servedRoute` (existing).
- Produces:

```swift
public struct RedirectEntry: Codable, Sendable, Equatable {
    public var source: String
    public var destination: String
    public var code: Int
}
public enum RedirectsEmitter {
    /// New route for a destination: collections serve at "/<name>/<slug>/", pages at their route.
    public static func servedPath(for destination: ImportDestination) -> String
    public static func entries(for classified: [ClassifiedItem]) -> [RedirectEntry]
    /// Merges into the template's redirects.json (a JSON array, `[]` when untouched).
    public static func merge(existingJSON: String, adding: [RedirectEntry]) throws -> String
}
```

`entries` compares each item's source URL *path* with `servedPath`; equal (after trailing-slash normalization) → no entry; different → `{source: <old path>, destination: <new path>, code: 301}`. Deduplicate by `source`. `merge` decodes the existing array, appends entries whose `source` isn't already present, and re-encodes with `.prettyPrinted, .sortedKeys` + trailing newline.

- [ ] **Step 1: Write the failing tests** — a dated WP permalink `/2024/05/01/hello/` classified to `blog`/`hello` must produce `{"source":"/2024/05/01/hello/","destination":"/blog/hello/","code":301}`; an `/about` page classified to route `/about` must produce nothing; merging twice must not duplicate.

- [ ] **Step 2: Run to verify failure** — filter `SiteImportRedirectsTests`.

- [ ] **Step 3: Implement.** Before finalizing `servedPath`, verify the collection URL shapes against the template's route files (`ls Resources/Template/src/pages` — e.g. `blog/[...id].astro` ⇒ `/blog/<slug>/`); adjust the mapping table to the routes that actually exist and mirror any collection that has *no* route page by emitting no redirect for it (only `blog`, `notes`, `photos`, `bookmarks`, `replies`, `likes` matter — Task 7 emits nothing else).

- [ ] **Step 4: Run to verify pass.**

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SiteImport/RedirectsEmitter.swift Tests/AnglesiteCoreTests/SiteImportRedirectsTests.swift
git commit -m "feat(#1615): emit 301 redirects for changed routes"
```

---

### Task 11: ImportSiteConfig (homepage seeds)

**Files:**
- Create: `Sources/AnglesiteCore/SiteImport/ImportSiteConfig.swift`
- Test: `Tests/AnglesiteCoreTests/SiteImportSiteConfigTests.swift`

**Interfaces:**
- Consumes: `ImportSnapshot` (the resolver's `homepage` page), `ExtractionRecord`.
- Produces:

```swift
public struct SiteConfigSeeds: Codable, Sendable, Equatable {
    public var siteName: String?
    public var tagline: String?
    public var lang: String?
}
public enum ImportSiteConfig {
    public static func seeds(fromHomepage homepage: CapturedPage?) -> SiteConfigSeeds
    /// Replace-or-append KEY="value" lines in .site-config text; idempotent; preserves
    /// unrelated lines and comments byte-for-byte.
    public static func apply(_ seeds: SiteConfigSeeds, toConfigText text: String) -> String
}
```

`seeds`: `siteName` = homepage `extraction.title` (already de-suffixed by the engine), `tagline` = `extraction.excerpt`, `lang` = `extraction.lang`. `apply` maps `siteName → SITE_NAME`, `tagline → TAGLINE`, `lang → LANG`; for each non-nil seed, replace an existing `KEY=…` line (commented `#KEY=` lines count as absent) or append `KEY="value"` at the end; values are double-quoted with `"` escaped.

- [ ] **Step 1: Write the failing tests** — replace-existing, append-missing, idempotence (`apply(apply(x)) == apply(x)`), and nil seeds leave text untouched.

- [ ] **Step 2: Run to verify failure** — filter `SiteImportSiteConfigTests`.

- [ ] **Step 3: Implement** (line-based scan; ≈30 lines).

- [ ] **Step 4: Run to verify pass.**

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SiteImport/ImportSiteConfig.swift Tests/AnglesiteCoreTests/SiteImportSiteConfigTests.swift
git commit -m "feat(#1615): seed .site-config from imported homepage"
```

---

### Task 12: ImportPlan + ImportReport

**Files:**
- Create: `Sources/AnglesiteCore/SiteImport/ImportPlan.swift`
- Test: `Tests/AnglesiteCoreTests/SiteImportPlanTests.swift`

**Interfaces:**
- Consumes: `ResolvedContent`, `ClassifiedItem`, `SiteConfigSeeds`, `ImportProblem`.
- Produces:

```swift
public struct ImportPlan: Codable, Sendable, Equatable {
    /// Destination → count, e.g. ["blog": 42, "pages": 6, "notes": 3].
    public var counts: [String: Int]
    public var imageCount: Int
    /// URLs whose content could not be extracted or converted (owner checklist material).
    public var problems: [ImportProblem]
    public var skippedURLs: [String]
    public var rungBreakdown: [String: Int]   // ImportItem.Rung rawValue → count
    public var seeds: SiteConfigSeeds
}
public enum ImportPlanBuilder {
    public static func plan(resolved: ResolvedContent, classified: [ClassifiedItem],
                            seeds: SiteConfigSeeds) -> ImportPlan
}
public struct ImportReport: Codable, Sendable, Equatable {
    public static let fileName = "import-report.json"
    public var plan: ImportPlan
    public var writtenPaths: [String]
    public var installedImagePaths: [String]
    public var redirects: [RedirectEntry]
    public var writeProblems: [ImportProblem]
    public func save(to configDirectory: URL) throws
    public static func load(from configDirectory: URL) throws -> ImportReport
}
```

`counts` keys: collection names for `.collection`, `"pages"` for `.page`. `imageCount` = total of `item.images.count` across classified items. `save`/`load`: pretty-printed sorted-keys JSON at `configDirectory/import-report.json`.

- [ ] **Step 1: Write failing tests** — counts and rung breakdown from a small classified array; report save/load round-trip in a temp dir.
- [ ] **Step 2: Run to verify failure** — filter `SiteImportPlanTests`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to verify pass.**
- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SiteImport/ImportPlan.swift Tests/AnglesiteCoreTests/SiteImportPlanTests.swift
git commit -m "feat(#1615): add ImportPlan summary and persisted ImportReport"
```

---

### Task 13: ImportTransform orchestrator + golden-file test

**Files:**
- Create: `Sources/AnglesiteCore/SiteImport/ImportTransform.swift`
- Create: `Tests/AnglesiteCoreTests/Fixtures/SiteImport/wp-site/snapshot.json` (+ `assets/`), `Tests/AnglesiteCoreTests/Fixtures/SiteImport/wp-site/expected/` (golden `Source/` fragment)
- Test: `Tests/AnglesiteCoreTests/SiteImportTransformTests.swift`
- Modify: `Package.swift` — ensure `Fixtures/SiteImport` is in the `AnglesiteCoreTests` target's `resources` (check how existing fixtures are declared and follow that pattern; if a broad `.copy("Fixtures")` already exists, no change).

**Interfaces:**
- Consumes: everything from Tasks 1–12, by the exact names declared there.
- Produces:

```swift
public enum ImportStep: Sendable, Equatable {
    case resolvingContent
    case classifying(itemCount: Int)
    case writingContent(fileCount: Int)
    case localizingAssets(imageCount: Int)
    case writingRedirects(count: Int)
    case seedingConfig
    case savingReport
    case warning(String)
}
public enum ImportTransformError: Error, Equatable {
    case sourceDirectoryMissing(String)
}
public enum ImportTransform {
    /// Runs the full transform against an already-scaffolded Source/ tree.
    /// Per-item failures become report problems and `.warning` steps — never a throw.
    @discardableResult
    public static func run(
        snapshot: ImportSnapshot, snapshotDirectory: URL,
        sourceDirectory: URL, configDirectory: URL,
        now: Date, onStep: @Sendable (ImportStep) -> Void
    ) throws -> ImportReport
}
```

Sequence: verify `sourceDirectory` exists (throw otherwise) → resolve → classify → for each classified item: localize assets (`AssetLocalizer`), emit (`ImportEmitter`), write file (creating intermediate directories) → merge redirects into `sourceDirectory/redirects.json` → apply seeds to `sourceDirectory/.site-config` (create the file if the scaffold hasn't; append-only path) → build plan, assemble report, `report.save(to: configDirectory)`. Every step emits its `ImportStep` before starting. File-write failures append to `writeProblems` and emit `.warning`, then continue.

- [ ] **Step 1: Build the fixture.** `wp-site/snapshot.json`: a hand-written `ImportSnapshot` JSON with 2 WP posts (one with a dated permalink, one image apiece), 1 WP page, a homepage, one `/tag/…` page, `conversions` for every HTML body, and one asset (the Task 9 base64 PNG written to `assets/cat.png`). `wp-site/expected/`: the exact files the transform should produce (`src/content/blog/*.md`, `src/pages/*.md`, `public/images/*.png`, `redirects.json`, `.site-config`). Author `expected/` by hand from the Task 8/10/11 emitters' documented output — not by running the code first and copying its output (that would test nothing).

- [ ] **Step 2: Write the failing golden test**

```swift
import Foundation
import Testing
@testable import AnglesiteCore

@Suite struct SiteImportTransformTests {
    @Test func wpSiteGoldenRun() throws {
        let fixtures = Bundle.module.url(forResource: "Fixtures/SiteImport/wp-site", withExtension: nil)!
        let snapshot = try JSONDecoder().decode(
            ImportSnapshot.self,
            from: Data(contentsOf: fixtures.appendingPathComponent("snapshot.json")))
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = work.appendingPathComponent("Source", isDirectory: true)
        let config = work.appendingPathComponent("Config", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try "[]\n".write(to: source.appendingPathComponent("redirects.json"), atomically: true, encoding: .utf8)

        var steps: [ImportStep] = []
        let report = try ImportTransform.run(
            snapshot: snapshot, snapshotDirectory: fixtures,
            sourceDirectory: source, configDirectory: config,
            now: Date(timeIntervalSince1970: 1_700_000_000), onStep: { steps.append($0) })

        let expectedRoot = fixtures.appendingPathComponent("expected")
        let enumerator = FileManager.default.enumerator(at: expectedRoot, includingPropertiesForKeys: [.isRegularFileKey])!
        for case let expectedFile as URL in enumerator where try expectedFile.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            let relative = expectedFile.path.replacingOccurrences(of: expectedRoot.path + "/", with: "")
            let produced = source.appendingPathComponent(relative)
            #expect(FileManager.default.contentsEqual(atPath: produced.path, andPath: expectedFile.path),
                    "mismatch at \(relative)")
        }
        #expect(report.writeProblems.isEmpty)
        #expect(steps.first == .resolvingContent)
        #expect(try ImportReport.load(from: config) == report)
    }
}
```

- [ ] **Step 3: Run to verify failure** — filter `SiteImportTransformTests`; compile failure first, then (after implementing) iterate on genuine content mismatches: each mismatch is either a transform bug or a hand-authoring mistake in `expected/` — decide which by reading the diff, never by wholesale copying produced output over `expected/`.

- [ ] **Step 4: Implement `ImportTransform.swift`** per the sequence block.

- [ ] **Step 5: Run to verify pass**, then run the whole import suite: `… swift test --package-path . --filter SiteImport`. Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/SiteImport/ImportTransform.swift Tests/AnglesiteCoreTests/SiteImportTransformTests.swift Tests/AnglesiteCoreTests/Fixtures/SiteImport Package.swift
git commit -m "feat(#1615): add ImportTransform orchestrator with golden test"
```

---

### Task 14: ImportSummaryModel (owner-language strings)

**Files:**
- Create: `Sources/AnglesiteCore/SiteImport/ImportSummaryModel.swift`
- Test: `Tests/AnglesiteCoreTests/SiteImportSummaryModelTests.swift`

**Interfaces:**
- Consumes: `ImportPlan`.
- Produces:

```swift
public struct ImportSummaryModel: Sendable, Equatable {
    public init(plan: ImportPlan)
    /// e.g. ["42 blog posts", "6 pages", "3 notes", "310 images"] — non-zero counts only,
    /// fixed order: blog, pages, notes, photos, bookmarks, replies, likes, then images.
    public var countLines: [String]
    /// e.g. "3 pages couldn't be brought over cleanly" — nil when problems is empty.
    public var attentionLine: String?
    public var skippedLine: String?   // "12 archive pages were left behind (tags, categories)"
}
```

Owner language rules: never say "collection", "frontmatter", "markdown", or a rung name; singular/plural handled ("1 blog post"). Display-name table: `blog → "blog post(s)"`, `pages → "page(s)"`, `notes → "note(s)"`, `photos → "photo(s)"`, `bookmarks → "bookmark(s)"`, `replies → "repl(y/ies)"`, `likes → "like(s)"`.

- [ ] **Step 1: Write failing tests** — full plan → ordered lines; zero counts omitted; singulars; empty problems → `attentionLine == nil`.
- [ ] **Step 2: Run to verify failure** — filter `SiteImportSummaryModelTests`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to verify pass.**
- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SiteImport/ImportSummaryModel.swift Tests/AnglesiteCoreTests/SiteImportSummaryModelTests.swift
git commit -m "feat(#1615): add owner-language import summary model"
```

---

### Task 15: Full verification + PR

**Files:** none new.

- [ ] **Step 1: Full Swift test run** (serialize with any other agents' runs — FM suites contend):

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .`
Expected: all suites pass, including pre-existing ones (Swift tests couple to template markup — nothing in this plan edits the template, so any template-coupled failure is pre-existing; report it, don't fix it here).

- [ ] **Step 2: JS checks**

Run: `cd JS/import-engine && npm test && npm run typecheck && npm run lint && npm run build`
Expected: clean; `Resources/ImportEngine/import-engine.js` produced.

- [ ] **Step 3: App build sanity**

Run: `xcodegen generate && scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: builds (container-artifact warnings are expected in this worktree per the SessionStart preflight).

- [ ] **Step 4: PR.** Re-read `CONTRIBUTING.md` ▸ "Commits and pull requests" first. PR body from `.github/PULL_REQUEST_TEMPLATE.md`'s exact headings — **Summary**, **Paired PR check** (no MCP schema changes → not paired; the new JS deps are app-side only), **Test plan**. Body says "Part of #1615 — transform stage; does **not** close #1615" (crawl + UI still outstanding) — and per the multi-PR rule, no commit in this branch may use a closing type scoped to #1615.

Run:
```bash
gh pr create --repo Anglesite/Anglesite --title "feat(#1615): website-import transform stage" --body-file <template-derived body>
```
