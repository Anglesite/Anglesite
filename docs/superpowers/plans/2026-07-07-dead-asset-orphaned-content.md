# Dead Asset & Orphaned Content Detection Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an on-demand "Project Cleanup" scan that detects unused Astro components/layouts,
unused `public/images` assets, and orphaned pages, surfaced in a new Navigator sidebar section
with git-tracked Open/Ignore/Delete actions.

**Architecture:** Two new pure, fixture-testable `AnglesiteCore` types (`DeadAssetScanner` for the
new import/asset reference-graph analysis, `ProjectCleanupReport` to merge its output with the
already-existing `LinkGraph.orphanPages`) feed a thin `ProjectCleanupModel` in `AnglesiteApp`,
rendered as a new section in `SiteNavigatorView`. Delete reuses the existing
`NativeContentOperations.processGitCommit` shape via a new sibling `processGitDelete`
(`git rm` + `git commit`), so removal is git-tracked and git itself is the undo/archive story.

**Tech Stack:** Swift 6.4 (macOS 27 target), Swift Testing (`@Suite`/`@Test`/`#expect`),
`NSRegularExpression` for text extraction, `ProcessSupervisor` for git subprocess calls.

**Design doc:** [`docs/superpowers/specs/2026-07-07-dead-asset-orphaned-content-design.md`](../specs/2026-07-07-dead-asset-orphaned-content-design.md)

## Global Constraints

- Swift 6.4 / macOS 27 target (per `Package.swift`'s `platforms: [.macOS("27.0")]`).
- Run all SwiftPM commands with the Xcode 27 toolchain, not the default CommandLineTools one:
  `export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` before any
  `swift build`/`swift test`/`xcrun swift test` invocation — the default toolchain's
  `swift-package` is broken and too old for this package.
- Tests use Swift Testing (`@Suite`, `@Test`, `#expect`), matching every existing suite touched by
  this plan (`LinkGraphTests`, `ContentScannerTests`, `NativeContentOperationsTests`) — not XCTest.
- No new third-party dependencies. No container/MCP round-trips anywhere in this feature — all
  file I/O is direct, host-side Swift, matching `ContentScanner`/`SiteKnowledgeIndex`.
- Follow existing file-scanning conventions exactly: a private, per-file `walk(_:)` helper (not a
  shared utility — every existing scanner in this codebase duplicates its own), excluded directory
  names `["node_modules", "dist", ".astro", ".git"]`, sorted directory listings for determinism.
- An unresolved/unresolvable reference must never cause a false "unused" flag — always bias toward
  under-flagging, never over-flagging (see design doc §3.1).

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/AnglesiteCore/DeadAssetScanner.swift` (new) | Regex-based reference extraction (imports, href/src, markdown images, CSS `url()`, `Astro.glob`) + path resolution + full-project scan producing `CleanupCandidate`s for components/layouts/images. |
| `Tests/AnglesiteCoreTests/DeadAssetScannerTests.swift` (new) | Pure extraction unit tests + disk-fixture full-scan tests. |
| `Sources/AnglesiteCore/ProjectCleanupReport.swift` (new) | Merges `DeadAssetScanner` candidates with `LinkGraph.orphanPages` into one sorted list. |
| `Tests/AnglesiteCoreTests/ProjectCleanupReportTests.swift` (new) | Merge-logic unit tests. |
| `Sources/AnglesiteCore/NativeContentOperations.swift` (modify) | Add `processGitDelete` + `GitDelete` typealias, sibling to `processGitCommit`. |
| `Tests/AnglesiteCoreTests/NativeContentOperationsTests.swift` (modify) | Add a git-delete pipeline test, mirroring the existing `realGit` test. |
| `Sources/AnglesiteApp/ProjectCleanupModel.swift` (new) | `@Observable` model: triggers the scan, holds candidates + session-only ignore set, runs delete. |
| `Sources/AnglesiteApp/SiteWindowModel.swift` (modify) | Owns a `ProjectCleanupModel`, configures it in `loadAndStart()`, adds `openCleanupCandidate(_:)`. |
| `Sources/AnglesiteApp/SiteNavigatorView.swift` (modify) | Renders the new "Cleanup" section, context menu (Open/Ignore/Delete), delete confirmation dialog, delete-error alert. |
| `Sources/AnglesiteApp/SiteWindow.swift` (modify) | Threads `model.cleanup` and an open-callback into `SiteNavigatorView`. |

---

### Task 1: `DeadAssetScanner` — reference extraction primitives

**Files:**
- Create: `Sources/AnglesiteCore/DeadAssetScanner.swift`
- Test: `Tests/AnglesiteCoreTests/DeadAssetScannerTests.swift`

**Interfaces:**
- Produces: `enum DeadAssetScanner` with `struct ReferenceSource { let path: String; let fileReferences: Set<String>; let globDirectories: Set<String> }` (internal), and `static func extractReferences(source: String, path: String) -> ReferenceSource` (internal — used directly by this task's tests via `@testable import`, and by Task 2's `scan(projectRoot:images:)`).
- Consumes: nothing from other tasks (first task).

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/DeadAssetScannerTests.swift`:

```swift
import Foundation
import Testing
@testable import AnglesiteCore

@Suite("DeadAssetScanner reference extraction")
struct DeadAssetScannerExtractionTests {

    @Test("extracts import statements and resolves relative paths against the source file's directory")
    func importResolution() {
        let source = """
        ---
        import Header from '../components/Header.astro';
        ---
        <Header />
        """
        let refs = DeadAssetScanner.extractReferences(source: source, path: "src/pages/about.astro")
        #expect(refs.fileReferences.contains("src/components/Header.astro"))
    }

    @Test("extracts href/src attributes and resolves an absolute path against public/")
    func absolutePathResolution() {
        let source = #"<img src="/images/hero.png" alt="hero">"#
        let refs = DeadAssetScanner.extractReferences(source: source, path: "src/pages/index.astro")
        #expect(refs.fileReferences.contains("public/images/hero.png"))
    }

    @Test("extracts markdown image references")
    func markdownImageResolution() {
        let source = "![alt](../../../public/images/photo.jpg)"
        let refs = DeadAssetScanner.extractReferences(source: source, path: "src/content/posts/entry.md")
        #expect(refs.fileReferences.contains("public/images/photo.jpg"))
    }

    @Test("extracts CSS url() references")
    func cssURLResolution() {
        let source = "@font-face { src: url('../fonts/brand.woff2'); }"
        let refs = DeadAssetScanner.extractReferences(source: source, path: "src/styles/global.css")
        #expect(refs.fileReferences.contains("src/fonts/brand.woff2"))
    }

    @Test("Astro.glob marks the resolved directory, not an exact file")
    func globDirectory() {
        let source = "const posts = await Astro.glob('../content/*.md');"
        let refs = DeadAssetScanner.extractReferences(source: source, path: "src/pages/blog.astro")
        #expect(refs.globDirectories.contains("src/content"))
    }

    @Test("bare/unresolvable specifiers are never counted as references")
    func unresolvableSpecifiersSkipped() {
        let source = """
        ---
        import { getCollection } from 'astro:content';
        import Foo from '@components/Foo.astro';
        ---
        """
        let refs = DeadAssetScanner.extractReferences(source: source, path: "src/pages/index.astro")
        #expect(refs.fileReferences.isEmpty)
    }

    @Test("relative path resolution walks up directories for each ..")
    func relativeResolutionWalksUp() {
        let source = "import Base from '../../layouts/Base.astro';"
        let refs = DeadAssetScanner.extractReferences(source: source, path: "src/components/cards/Card.astro")
        #expect(refs.fileReferences.contains("src/layouts/Base.astro"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcrun swift test --filter DeadAssetScannerExtractionTests
```

Expected: FAIL — `DeadAssetScanner` does not exist (compile error).

- [ ] **Step 3: Write `DeadAssetScanner`'s extraction primitives**

Create `Sources/AnglesiteCore/DeadAssetScanner.swift`:

```swift
import Foundation

/// Detects unused `.astro` components/layouts and unused `public/images` assets by building a
/// reference graph from `import` statements, `href`/`src` attributes, markdown image syntax,
/// CSS `url()`, `Astro.glob` calls, and frontmatter `layout:` fields — then finding files with
/// zero resolved inbound references.
///
/// An unresolvable reference (bare specifier, unconfigured path alias) is never counted as proof
/// of use *or* disuse — it is simply skipped. This biases the whole scanner toward
/// under-flagging: the failure mode is "missed a dead file," never "recommended deleting
/// something in use."
public enum DeadAssetScanner {
    public struct CleanupCandidate: Sendable, Equatable, Identifiable {
        public let id: String
        public let path: String
        public let kind: Kind
        public let lastModified: Date
        public let referenceCount: Int

        public enum Kind: String, Sendable, Equatable, CaseIterable {
            case component, layout, image, page
        }

        public init(id: String, path: String, kind: Kind, lastModified: Date, referenceCount: Int) {
            self.id = id
            self.path = path
            self.kind = kind
            self.lastModified = lastModified
            self.referenceCount = referenceCount
        }
    }

    /// Raw references extracted from one source file, already resolved to project-relative paths
    /// where possible. `globDirectories` are directories an `Astro.glob` call covers — every file
    /// under one is treated as referenced, regardless of whether it appears in `fileReferences`.
    struct ReferenceSource: Sendable, Equatable {
        let path: String
        let fileReferences: Set<String>
        let globDirectories: Set<String>
    }

    // MARK: - Regexes (compiled once, matching the style of ContentScanner/SiteKnowledgeIndex)

    private static let importRegex = try! NSRegularExpression(
        pattern: #"import\s+(?:[^'"]+?\s+from\s+)?["']([^"']+)["']"#)
    private static let hrefSrcRegex = try! NSRegularExpression(
        pattern: #"(?:href|src)=["']([^"']+)["']"#, options: [.caseInsensitive])
    private static let markdownImageRegex = try! NSRegularExpression(
        pattern: #"!\[[^\]]*\]\(([^)]+)\)"#)
    private static let cssURLRegex = try! NSRegularExpression(
        pattern: #"url\(\s*['"]?([^'")]+)['"]?\s*\)"#, options: [.caseInsensitive])
    private static let astroGlobRegex = try! NSRegularExpression(
        pattern: #"Astro\.glob\(\s*['"]([^'"]+)['"]"#)

    /// Extracts and resolves every reference in `source`, a file at project-relative `path`.
    static func extractReferences(source: String, path: String) -> ReferenceSource {
        let raw = matches(importRegex, in: source, group: 1)
            + matches(hrefSrcRegex, in: source, group: 1)
            + matches(markdownImageRegex, in: source, group: 1)
            + matches(cssURLRegex, in: source, group: 1)

        var fileRefs = Set<String>()
        for candidate in raw {
            let cleaned = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if let resolved = resolve(cleaned, relativeTo: path) { fileRefs.insert(resolved) }
        }

        var globDirs = Set<String>()
        for pattern in matches(astroGlobRegex, in: source, group: 1) {
            if let dir = resolveGlobDirectory(pattern, relativeTo: path) { globDirs.insert(dir) }
        }

        return ReferenceSource(path: path, fileReferences: fileRefs, globDirectories: globDirs)
    }

    // MARK: - Path resolution

    /// Resolves a raw reference string to a project-relative path, or `nil` if it can't be
    /// resolved (bare specifier, unconfigured alias) — never guessed at.
    static func resolve(_ ref: String, relativeTo sourcePath: String) -> String? {
        if let abs = resolveAbsolutePath(ref) { return abs }
        if let rel = resolveRelativePath(ref, relativeTo: sourcePath) { return rel }
        return nil
    }

    /// `/images/hero.png` → `public/images/hero.png` (Astro serves `public/` at the site root).
    /// Strips a trailing `?query` or `#fragment` first.
    static func resolveAbsolutePath(_ ref: String) -> String? {
        guard ref.hasPrefix("/") else { return nil }
        var clean = String(ref.dropFirst())
        if let cut = clean.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            clean = String(clean[clean.startIndex..<cut])
        }
        guard !clean.isEmpty else { return nil }
        return "public/" + clean
    }

    /// Resolves `./`/`../`-prefixed `ref` against `sourcePath`'s own directory. Strips a trailing
    /// `?query`/`#fragment` first.
    static func resolveRelativePath(_ ref: String, relativeTo sourcePath: String) -> String? {
        guard ref.hasPrefix("./") || ref.hasPrefix("../") else { return nil }
        var clean = ref
        if let cut = clean.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            clean = String(clean[clean.startIndex..<cut])
        }
        var dirComponents = sourcePath.split(separator: "/").dropLast().map(String.init)
        for segment in clean.split(separator: "/") {
            if segment == "." { continue }
            else if segment == ".." { if !dirComponents.isEmpty { dirComponents.removeLast() } }
            else { dirComponents.append(String(segment)) }
        }
        guard !dirComponents.isEmpty else { return nil }
        return dirComponents.joined(separator: "/")
    }

    /// Truncates an `Astro.glob` pattern down to its containing directory (e.g.
    /// `../content/*.md` → the resolved form of `../content`) and resolves that against
    /// `sourcePath`. Only relative glob patterns are handled — Astro.glob never takes an
    /// absolute-from-public pattern.
    static func resolveGlobDirectory(_ pattern: String, relativeTo sourcePath: String) -> String? {
        guard pattern.hasPrefix("./") || pattern.hasPrefix("../") else { return nil }
        var dir = pattern
        if let starIndex = dir.firstIndex(of: "*") {
            dir = String(dir[dir.startIndex..<starIndex])
            if let lastSlash = dir.lastIndex(of: "/") {
                dir = String(dir[dir.startIndex...lastSlash])
            }
        }
        if dir.hasSuffix("/") { dir.removeLast() }
        return resolveRelativePath(dir, relativeTo: sourcePath)
    }

    private static func matches(_ regex: NSRegularExpression, in source: String, group: Int) -> [String] {
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        var out: [String] = []
        for match in regex.matches(in: source, range: range) {
            guard let r = Range(match.range(at: group), in: source) else { continue }
            out.append(String(source[r]))
        }
        return out
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcrun swift test --filter DeadAssetScannerExtractionTests
```

Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/DeadAssetScanner.swift Tests/AnglesiteCoreTests/DeadAssetScannerTests.swift
git commit -m "feat(dead-assets): reference extraction + path resolution primitives"
```

---

### Task 2: `DeadAssetScanner.scan` — full-project candidate detection

**Files:**
- Modify: `Sources/AnglesiteCore/DeadAssetScanner.swift`
- Test: `Tests/AnglesiteCoreTests/DeadAssetScannerTests.swift`

**Interfaces:**
- Consumes: `DeadAssetScanner.ReferenceSource`, `DeadAssetScanner.extractReferences(source:path:)`,
  `DeadAssetScanner.resolve(_:relativeTo:)` from Task 1. `SiteContentGraph.Image` (existing type:
  `id, siteID, relativePath, fileName, byteSize, usedOnPages, lastModified`).
- Produces: `public static func scan(projectRoot: URL, images: [SiteContentGraph.Image]) -> [CleanupCandidate]` — the public entry point Task 5 (`ProjectCleanupModel`) calls.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/AnglesiteCoreTests/DeadAssetScannerTests.swift`:

```swift
@Suite("DeadAssetScanner full scan")
struct DeadAssetScannerScanTests {
    private func makeSite(_ files: [String: String]) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dead-asset-scan-\(UUID().uuidString)", isDirectory: true)
        for (rel, contents) in files {
            let url = root.appendingPathComponent(rel)
            try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! Data(contents.utf8).write(to: url)
        }
        return root
    }

    @Test("dead component is flagged, imported component is not")
    func componentDetection() {
        let root = makeSite([
            "src/pages/index.astro": "---\nimport Header from '../components/Header.astro';\n---\n<Header />",
            "src/components/Header.astro": "<header>Site</header>",
            "src/components/Orphan.astro": "<div>never imported</div>",
        ])
        let candidates = DeadAssetScanner.scan(projectRoot: root, images: [])
        let paths = Set(candidates.map(\.path))
        #expect(paths.contains("src/components/Orphan.astro"))
        #expect(!paths.contains("src/components/Header.astro"))
    }

    @Test("layout referenced only via frontmatter is not flagged")
    func layoutFrontmatterReference() {
        let root = makeSite([
            "src/content/posts/hello.md": "---\ntitle: Hello\nlayout: ../../layouts/Post.astro\n---\nBody",
            "src/layouts/Post.astro": "<slot />",
            "src/layouts/Unused.astro": "<slot />",
        ])
        let candidates = DeadAssetScanner.scan(projectRoot: root, images: [])
        let paths = Set(candidates.map(\.path))
        #expect(!paths.contains("src/layouts/Post.astro"))
        #expect(paths.contains("src/layouts/Unused.astro"))
    }

    @Test("Astro.glob-covered directory suppresses false positives for every file inside it")
    func globCoveredDirectory() {
        let root = makeSite([
            "src/pages/index.astro": "---\nconst widgets = await Astro.glob('../components/widgets/*.astro');\n---\n<div></div>",
            "src/components/widgets/Card.astro": "<div>card</div>",
        ])
        let candidates = DeadAssetScanner.scan(projectRoot: root, images: [])
        #expect(!candidates.map(\.path).contains("src/components/widgets/Card.astro"))
    }

    @Test("unused image (public path) is flagged; referenced image is not")
    func imageDetection() {
        let root = makeSite([
            "src/pages/index.astro": #"<img src="/images/hero.png">"#,
        ])
        let images = [
            SiteContentGraph.Image(
                id: "s:image:public/images/hero.png", siteID: "s",
                relativePath: "public/images/hero.png", fileName: "hero.png",
                byteSize: nil, usedOnPages: [], lastModified: Date(timeIntervalSince1970: 0)),
            SiteContentGraph.Image(
                id: "s:image:public/images/unused.png", siteID: "s",
                relativePath: "public/images/unused.png", fileName: "unused.png",
                byteSize: nil, usedOnPages: [], lastModified: Date(timeIntervalSince1970: 0)),
        ]
        let candidates = DeadAssetScanner.scan(projectRoot: root, images: images)
        let paths = Set(candidates.map(\.path))
        #expect(paths.contains("public/images/unused.png"))
        #expect(!paths.contains("public/images/hero.png"))
    }

    @Test("empty project produces no candidates")
    func emptyProject() {
        let root = makeSite([:])
        #expect(DeadAssetScanner.scan(projectRoot: root, images: []).isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcrun swift test --filter DeadAssetScannerScanTests
```

Expected: FAIL — `DeadAssetScanner.scan` does not exist (compile error).

- [ ] **Step 3: Implement `scan(projectRoot:images:)`**

Append to the `DeadAssetScanner` enum body in `Sources/AnglesiteCore/DeadAssetScanner.swift` (after
the `matches` helper, still inside the closing brace):

```swift
    // MARK: - Full-project scan

    private static let referenceScanExtensions: Set<String> = [
        ".astro", ".md", ".mdx", ".mdoc", ".markdown", ".css",
    ]
    private static let excludedDirNames: Set<String> = ["node_modules", "dist", ".astro", ".git"]

    /// Scans every `.astro`/`.md`/`.mdx`/`.mdoc`/`.markdown`/`.css` file under `projectRoot` for
    /// references, then returns every unused `src/components/**/*.astro`, `src/layouts/**/*.astro`,
    /// and unused entry in `images` (typically `SiteContentGraph.images(for:)`, scoped to
    /// `public/images/**`). Pure over the filesystem snapshot at call time.
    public static func scan(projectRoot: URL, images: [SiteContentGraph.Image]) -> [CleanupCandidate] {
        var fileReferenceCounts: [String: Int] = [:]
        var globDirectories: Set<String> = []

        for abs in walk(projectRoot) {
            let ext = "." + abs.pathExtension.lowercased()
            guard referenceScanExtensions.contains(ext) else { continue }
            guard let source = try? String(contentsOf: abs, encoding: .utf8) else { continue }
            let relPath = relativePosix(abs, from: projectRoot)

            let refs = extractReferences(source: source, path: relPath)
            for ref in refs.fileReferences { fileReferenceCounts[ref, default: 0] += 1 }
            globDirectories.formUnion(refs.globDirectories)

            // Frontmatter `layout:` counts as a reference too — extractReferences only looks at
            // the body, not frontmatter fields.
            let frontmatter = Frontmatter.parse(source)
            if case let .string(layoutRef)? = frontmatter["layout"],
               let resolved = resolve(layoutRef, relativeTo: relPath) {
                fileReferenceCounts[resolved, default: 0] += 1
            }
        }

        func referenceCount(for path: String) -> Int {
            if globDirectories.contains(where: { path.hasPrefix($0 + "/") }) {
                return max(1, fileReferenceCounts[path] ?? 0)
            }
            return fileReferenceCounts[path] ?? 0
        }

        var candidates: [CleanupCandidate] = []

        for abs in walk(projectRoot.appendingPathComponent("src/components"))
        where abs.pathExtension.lowercased() == "astro" {
            let rel = relativePosix(abs, from: projectRoot)
            let count = referenceCount(for: rel)
            if count == 0 {
                candidates.append(CleanupCandidate(
                    id: rel, path: rel, kind: .component, lastModified: mtime(abs), referenceCount: count))
            }
        }
        for abs in walk(projectRoot.appendingPathComponent("src/layouts"))
        where abs.pathExtension.lowercased() == "astro" {
            let rel = relativePosix(abs, from: projectRoot)
            let count = referenceCount(for: rel)
            if count == 0 {
                candidates.append(CleanupCandidate(
                    id: rel, path: rel, kind: .layout, lastModified: mtime(abs), referenceCount: count))
            }
        }
        for image in images {
            let count = referenceCount(for: image.relativePath)
            if count == 0 {
                candidates.append(CleanupCandidate(
                    id: image.relativePath, path: image.relativePath, kind: .image,
                    lastModified: image.lastModified, referenceCount: count))
            }
        }

        return candidates.sorted { $0.path < $1.path }
    }

    /// Recursively collects files under `dir` in sorted order, skipping excluded directories and
    /// symlinks. Missing `dir` → empty. Mirrors `ContentScanner.walk`/`SiteKnowledgeIndex.walk`.
    private static func walk(_ dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []
        ) else { return [] }
        var files: [URL] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = entry.lastPathComponent
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true {
                if excludedDirNames.contains(name) { continue }
                files.append(contentsOf: walk(entry))
            } else {
                files.append(entry)
            }
        }
        return files
    }

    private static func relativePosix(_ url: URL, from base: URL) -> String {
        let urlComponents = url.standardizedFileURL.pathComponents
        let baseComponents = base.standardizedFileURL.pathComponents
        guard urlComponents.starts(with: baseComponents) else { return url.path }
        return urlComponents.dropFirst(baseComponents.count).joined(separator: "/")
    }

    private static func mtime(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? Date(timeIntervalSince1970: 0)
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcrun swift test --filter DeadAssetScannerScanTests
xcrun swift test --filter DeadAssetScannerExtractionTests
```

Expected: PASS (5 new tests, 7 from Task 1 still passing).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/DeadAssetScanner.swift Tests/AnglesiteCoreTests/DeadAssetScannerTests.swift
git commit -m "feat(dead-assets): full-project scan for unused components/layouts/images"
```

---

### Task 2 amendment (post-review fix)

Task 2's review surfaced a real gap in the design's "never over-flag" invariant: a
component/layout referenced *only* via an unresolvable specifier (e.g. a TypeScript/Vite path
alias like `@components/Foo.astro`) was silently dropped with no compensating signal, so it
would be incorrectly flagged as unused. The human chose to close this gap rather than accept the
residual risk (see design doc §3.1). Fix, applied and re-reviewed (approved) in commit
`403d53d8`: `ReferenceSource` gained a purely-additive `unresolvedReferences: Set<String>` field;
two new functions, `loadPathAliases(projectRoot:)` (reads `tsconfig.json`/`jsconfig.json`
`compilerOptions.paths`, degrading safely to `[:]` on any missing/malformed file — no `extends`
chain following, no JSONC comment support) and `resolveAlias(_:aliases:)` (single-`*`-wildcard
prefix/suffix substitution); `scan(projectRoot:images:)` loads aliases once and retries each
file's unresolved references against them. `resolve(_:relativeTo:)` and
`extractReferences(source:path:)`'s signatures were not touched. Two new tests
(`tsconfigPathAlias`, `noAliasConfig`) lock in both the fixed behavior and the documented
no-config fallback.

### Task 3: `ProjectCleanupReport` — merge with orphan pages

**Files:**
- Create: `Sources/AnglesiteCore/ProjectCleanupReport.swift`
- Test: `Tests/AnglesiteCoreTests/ProjectCleanupReportTests.swift`

**Interfaces:**
- Consumes: `DeadAssetScanner.CleanupCandidate` (Task 1/2). `LinkGraph.orphanPages` /
  `SiteKnowledgeIndex.Document` (existing types — `Document` has `id, siteID, path, kind, title,
  frontmatter, headings, internalLinks, excerptText, lastModified`).
- Produces: `public enum ProjectCleanupReport` with `public static func build(deadAssets: [DeadAssetScanner.CleanupCandidate], orphanPages: [SiteKnowledgeIndex.Document]) -> [DeadAssetScanner.CleanupCandidate]` — the function Task 5 (`ProjectCleanupModel.scan()`) calls to produce the final list.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/ProjectCleanupReportTests.swift`:

```swift
import Foundation
import Testing
@testable import AnglesiteCore

@Suite("ProjectCleanupReport")
struct ProjectCleanupReportTests {
    private func doc(_ path: String, kind: SiteKnowledgeIndex.Document.Kind = .page) -> SiteKnowledgeIndex.Document {
        SiteKnowledgeIndex.Document(
            id: "s:knowledge:\(path)", siteID: "s", path: path, kind: kind,
            title: path, frontmatter: [:], headings: [],
            internalLinks: [], excerptText: "",
            lastModified: Date(timeIntervalSince1970: 0))
    }

    @Test("merges dead-asset candidates with orphan pages, sorted by path")
    func mergeSorted() {
        let deadAssets = [
            DeadAssetScanner.CleanupCandidate(
                id: "src/components/Orphan.astro", path: "src/components/Orphan.astro",
                kind: .component, lastModified: Date(timeIntervalSince1970: 0), referenceCount: 0),
        ]
        let orphanPages = [doc("src/pages/hidden.astro")]
        let report = ProjectCleanupReport.build(deadAssets: deadAssets, orphanPages: orphanPages)
        #expect(report.map(\.path) == ["src/components/Orphan.astro", "src/pages/hidden.astro"])
        #expect(report.last?.kind == .page)
        #expect(report.last?.referenceCount == 0)
    }

    @Test("empty inputs produce an empty report")
    func emptyInputs() {
        let report = ProjectCleanupReport.build(deadAssets: [], orphanPages: [])
        #expect(report.isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcrun swift test --filter ProjectCleanupReportTests
```

Expected: FAIL — `ProjectCleanupReport` does not exist (compile error).

- [ ] **Step 3: Implement `ProjectCleanupReport`**

Create `Sources/AnglesiteCore/ProjectCleanupReport.swift`:

```swift
import Foundation

/// Merges `DeadAssetScanner`'s unused-component/layout/image candidates with
/// `LinkGraph.orphanPages` (already computed elsewhere, only ever surfaced per-page in the
/// Related Pages panel until now) into one sorted list for the Navigator's Cleanup section.
public enum ProjectCleanupReport {
    /// `orphanPages` always has zero inbound links by definition, so `referenceCount` is
    /// hardcoded to 0 for every page candidate — not a placeholder, an accurate reflection of
    /// what "orphan" means.
    public static func build(
        deadAssets: [DeadAssetScanner.CleanupCandidate],
        orphanPages: [SiteKnowledgeIndex.Document]
    ) -> [DeadAssetScanner.CleanupCandidate] {
        let pageCandidates = orphanPages.map { doc in
            DeadAssetScanner.CleanupCandidate(
                id: doc.path, path: doc.path, kind: .page,
                lastModified: doc.lastModified, referenceCount: 0)
        }
        return (deadAssets + pageCandidates).sorted { $0.path < $1.path }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcrun swift test --filter ProjectCleanupReportTests
```

Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/ProjectCleanupReport.swift Tests/AnglesiteCoreTests/ProjectCleanupReportTests.swift
git commit -m "feat(dead-assets): merge dead-asset candidates with orphan pages"
```

---

### Task 4: Git-tracked delete (`NativeContentOperations.processGitDelete`)

**Files:**
- Modify: `Sources/AnglesiteCore/NativeContentOperations.swift:219-232` (after `processGitCommit`, before the closing brace of the `NativeContentOperations` struct)
- Modify: `Tests/AnglesiteCoreTests/NativeContentOperationsTests.swift` (append after the existing `realGit` test, before its closing brace)

**Interfaces:**
- Consumes: `ProcessSupervisor.shared.run(executable:arguments:currentDirectoryURL:) -> ProcessSupervisor.RunResult` (existing).
- Produces: `public typealias GitDelete = @Sendable (_ projectRoot: URL, _ relPath: String, _ message: String) async -> String?` and `@Sendable public static func processGitDelete(_ projectRoot: URL, _ relPath: String, _ message: String) async -> String?` on `NativeContentOperations` — the closure Task 5 (`ProjectCleanupModel`) injects and defaults to.

- [ ] **Step 1: Write the failing test**

Append to `Tests/AnglesiteCoreTests/NativeContentOperationsTests.swift`, immediately after the
existing `realGit` test (before the struct's closing brace at the end of the file):

```swift
    @Test("processGitDelete removes and commits the file, nil outside a repo")
    func realGitDelete() async throws {
        // Outside a repo → nil (best-effort), file untouched.
        let bare = FileManager.default.temporaryDirectory.appendingPathComponent("nogit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        try "hi".write(to: bare.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let none = await NativeContentOperations.processGitDelete(bare, "f.txt", "msg")
        #expect(none == nil)
        #expect(FileManager.default.fileExists(atPath: bare.appendingPathComponent("f.txt").path))

        // Inside a repo with a committed file → delete succeeds, returns a 40-char SHA, file gone.
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let git = URL(fileURLWithPath: "/usr/bin/git")
        for args in [["init"], ["config", "user.email", "t@t.io"], ["config", "user.name", "t"]] {
            _ = try await ProcessSupervisor.shared.run(executable: git, arguments: args, currentDirectoryURL: repo)
        }
        let filePath = repo.appendingPathComponent("unused.astro")
        try "<div></div>".write(to: filePath, atomically: true, encoding: .utf8)
        _ = await NativeContentOperations.processGitCommit(repo, "unused.astro", "add unused.astro")

        let sha = await NativeContentOperations.processGitDelete(repo, "unused.astro", "Remove unused component: unused.astro")
        #expect(sha?.count == 40)
        #expect(!FileManager.default.fileExists(atPath: filePath.path))
    }
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcrun swift test --filter NativeContentOperationsTests/realGitDelete
```

Expected: FAIL — `NativeContentOperations.processGitDelete` does not exist (compile error).

- [ ] **Step 3: Implement `processGitDelete`**

In `Sources/AnglesiteCore/NativeContentOperations.swift`, add the `GitDelete` typealias next to
the existing `GitCommit` one (line 10):

```swift
    public typealias GitCommit = @Sendable (_ projectRoot: URL, _ relPath: String, _ message: String) async -> String?
    public typealias GitDelete = @Sendable (_ projectRoot: URL, _ relPath: String, _ message: String) async -> String?
```

Then add `processGitDelete` immediately after `processGitCommit` (after line 231, still inside the
struct):

```swift
    /// Stage-delete and commit exactly `relPath` on the current branch (`git rm` + `git commit`).
    /// Returns the new HEAD SHA, or nil on any failure (not a repo, dirty tree, rejecting hook,
    /// git missing) — best-effort, mirroring `processGitCommit`'s shape exactly. Git history is
    /// the sole undo/archive mechanism for this delete; there is no separate trash/archive path.
    @Sendable public static func processGitDelete(_ projectRoot: URL, _ relPath: String, _ message: String) async -> String? {
        let git = URL(fileURLWithPath: "/usr/bin/git")
        func run(_ args: [String]) async -> ProcessSupervisor.RunResult? {
            let result = try? await ProcessSupervisor.shared.run(executable: git, arguments: args, currentDirectoryURL: projectRoot)
            guard let result, result.exitCode == 0 else { return nil }
            return result
        }
        guard await run(["rev-parse", "--git-dir"]) != nil,
              await run(["rm", "--", relPath]) != nil,
              await run(["commit", "-m", message, "--", relPath]) != nil,
              let head = await run(["rev-parse", "HEAD"]) else { return nil }
        return head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcrun swift test --filter NativeContentOperationsTests
```

Expected: PASS (all existing `NativeContentOperationsTests` tests plus the new `realGitDelete`).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/NativeContentOperations.swift Tests/AnglesiteCoreTests/NativeContentOperationsTests.swift
git commit -m "feat(dead-assets): git-tracked delete (git rm + commit)"
```

---

### Task 5: `ProjectCleanupModel`

**Files:**
- Create: `Sources/AnglesiteApp/ProjectCleanupModel.swift`

**Interfaces:**
- Consumes: `SiteKnowledgeIndex.rebuild(siteID:projectRoot:)` / `.documents(siteID:)` (existing),
  `SiteContentGraph.images(for:)` (existing), `LinkGraph.analyze(documents:)` (existing),
  `DeadAssetScanner.scan(projectRoot:images:)` (Task 2), `ProjectCleanupReport.build(deadAssets:orphanPages:)`
  (Task 3), `NativeContentOperations.GitDelete` / `.processGitDelete` (Task 4).
- Produces: `@MainActor @Observable final class ProjectCleanupModel` with `candidates:
  [DeadAssetScanner.CleanupCandidate]` (read-only), `isScanning: Bool` (read-only), `hasScanned:
  Bool` (read-only), `deleteError: String?` (read-write), `configure(siteID:sourceDirectory:)`,
  `scan() async`, `ignore(_:)`, `delete(_:) async` — all consumed by Task 6/7.

No dedicated unit test for this task: per this codebase's existing convention (see
`RelatedPagesModel`, which has no test file — its logic-under-test lives entirely in
`AnglesiteCore`'s `LinkGraph`), `AnglesiteApp` models are thin glue over already-tested
`AnglesiteCore` functions and are verified via the manual smoke test in Task 8, not a unit suite.

- [ ] **Step 1: Write `ProjectCleanupModel`**

Create `Sources/AnglesiteApp/ProjectCleanupModel.swift`:

```swift
import Foundation
import Observation
import AnglesiteCore

/// Drives the Navigator's "Cleanup" section for one site window: on-demand scan, session-only
/// ignore set, and git-tracked delete. App glue only — all detection/merge logic under test lives
/// in `AnglesiteCore` (`DeadAssetScanner`, `ProjectCleanupReport`).
@MainActor
@Observable
final class ProjectCleanupModel {
    private(set) var candidates: [DeadAssetScanner.CleanupCandidate] = []
    private(set) var isScanning = false
    private(set) var hasScanned = false
    var deleteError: String?

    /// Ids ignored this session only — matches `RelatedPagesModel.ignored`'s "not persisted in
    /// v0" precedent. A fresh app launch re-surfaces a still-unreferenced file.
    private var ignored = Set<String>()
    private var siteID: String?
    private var sourceDirectory: URL?

    private let knowledgeIndex: SiteKnowledgeIndex
    private let contentGraph: SiteContentGraph
    private let gitDelete: NativeContentOperations.GitDelete

    init(
        knowledgeIndex: SiteKnowledgeIndex,
        contentGraph: SiteContentGraph,
        gitDelete: @escaping NativeContentOperations.GitDelete = NativeContentOperations.processGitDelete
    ) {
        self.knowledgeIndex = knowledgeIndex
        self.contentGraph = contentGraph
        self.gitDelete = gitDelete
    }

    /// Records which site this model scans. Cheap — does no I/O. Called once per site open from
    /// `SiteWindowModel.loadAndStart()`.
    func configure(siteID: String, sourceDirectory: URL) {
        self.siteID = siteID
        self.sourceDirectory = sourceDirectory
    }

    /// Runs (or re-runs) the full cleanup scan. On-demand only — never called automatically.
    func scan() async {
        guard let siteID, let sourceDirectory else { return }
        isScanning = true
        defer { isScanning = false }

        await knowledgeIndex.rebuild(siteID: siteID, projectRoot: sourceDirectory)
        let documents = await knowledgeIndex.documents(siteID: siteID)
        let images = await contentGraph.images(for: siteID)

        let report = await Task.detached(priority: .utility) {
            let deadAssets = DeadAssetScanner.scan(projectRoot: sourceDirectory, images: images)
            let orphanPages = LinkGraph.analyze(documents: documents).orphanPages
            return ProjectCleanupReport.build(deadAssets: deadAssets, orphanPages: orphanPages)
        }.value

        candidates = report.filter { !ignored.contains($0.id) }
        hasScanned = true
    }

    /// Dismisses `candidate` for the rest of this session without touching disk.
    func ignore(_ candidate: DeadAssetScanner.CleanupCandidate) {
        ignored.insert(candidate.id)
        candidates.removeAll { $0.id == candidate.id }
    }

    /// Deletes `candidate` via `git rm` + commit. On failure, sets `deleteError` and leaves the
    /// candidate listed and the file untouched — never falls back to a non-git raw delete.
    func delete(_ candidate: DeadAssetScanner.CleanupCandidate) async {
        guard let sourceDirectory else { return }
        let message = "Remove unused \(candidate.kind.rawValue): \(candidate.path)"
        guard await gitDelete(sourceDirectory, candidate.path, message) != nil else {
            deleteError = "Couldn't delete \(candidate.path). Check for uncommitted changes and try again."
            return
        }
        candidates.removeAll { $0.id == candidate.id }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcrun swift build --target AnglesiteApp
```

Expected: build succeeds (no test to run — this task has no dedicated suite, per the rationale
above).

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteApp/ProjectCleanupModel.swift
git commit -m "feat(dead-assets): ProjectCleanupModel scan/ignore/delete glue"
```

---

### Task 6: Wire `ProjectCleanupModel` into `SiteWindowModel`

**Files:**
- Modify: `Sources/AnglesiteApp/SiteWindowModel.swift`

**Interfaces:**
- Consumes: `ProjectCleanupModel` (Task 5), existing `contentGraph: SiteContentGraph`,
  `knowledgeIndex: SiteKnowledgeIndex`, `resolved.id`/`resolved.sourceDirectory` (already in scope
  in `loadAndStart()`), existing `openFile(_ file: FileRef)`.
- Produces: `var cleanup: ProjectCleanupModel` (read from Task 7's view) and `func
  openCleanupCandidate(_ candidate: DeadAssetScanner.CleanupCandidate)` (called from Task 7's
  context menu).

- [ ] **Step 1: Add the `cleanup` property and initialize it**

In `Sources/AnglesiteApp/SiteWindowModel.swift`, add the property near `relatedPages` (after line 68,
`var relatedPagesPresented = false`):

```swift
    var relatedPages: RelatedPagesModel
    var relatedPagesPresented = false
    /// Drives the Navigator's "Cleanup" section. On-demand only — `scan()` is never called
    /// automatically, only from the Navigator's "Scan for Cleanup Opportunities" action.
    var cleanup: ProjectCleanupModel
```

Initialize it in `init(...)` right after `self.relatedPages = RelatedPagesModel(index:
knowledgeIndex, ranker: semanticRanker)` (line 121):

```swift
        self.relatedPages = RelatedPagesModel(index: knowledgeIndex, ranker: semanticRanker)
        self.cleanup = ProjectCleanupModel(knowledgeIndex: knowledgeIndex, contentGraph: contentGraph)
```

- [ ] **Step 2: Configure it per site open in `loadAndStart()`**

In `loadAndStart()`, right after `graphExplorer.start(siteID: resolved.id, sourceDirectory:
resolved.sourceDirectory)` (line 555):

```swift
        graphExplorer.start(siteID: resolved.id, sourceDirectory: resolved.sourceDirectory)
        cleanup.configure(siteID: resolved.id, sourceDirectory: resolved.sourceDirectory)
```

- [ ] **Step 3: Add `openCleanupCandidate`**

Add this method right after `openFile(_:)` (after line 381, before `makeInspectorContext`):

```swift
    /// Routes a Cleanup-section row: components/layouts/pages open in the existing in-app editor
    /// (reusing `openFile`, so `.astro` components still get the rich Component Editor via
    /// `EditorKind.resolve`'s `.components`-group check); images have no in-app editor, so Open
    /// reveals the file in Finder instead.
    @MainActor
    func openCleanupCandidate(_ candidate: DeadAssetScanner.CleanupCandidate) {
        guard let site else { return }
        let url = site.sourceDirectory.appendingPathComponent(candidate.path)
        switch candidate.kind {
        case .image:
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .component, .layout:
            openFile(FileRef(url: url, group: .components, name: url.lastPathComponent))
        case .page:
            openFile(FileRef(url: url, group: .pages, name: url.lastPathComponent))
        }
    }
```

- [ ] **Step 4: Build to verify it compiles**

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcrun swift build --target AnglesiteApp
```

Expected: build succeeds.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/SiteWindowModel.swift
git commit -m "feat(dead-assets): wire ProjectCleanupModel into SiteWindowModel"
```

---

### Task 7: Render the Cleanup section in `SiteNavigatorView`

**Files:**
- Modify: `Sources/AnglesiteApp/SiteNavigatorView.swift`
- Modify: `Sources/AnglesiteApp/SiteWindow.swift:97`

**Interfaces:**
- Consumes: `ProjectCleanupModel` (Task 5/6: `candidates`, `isScanning`, `hasScanned`,
  `deleteError`, `scan()`, `ignore(_:)`, `delete(_:)`), `SiteWindowModel.openCleanupCandidate(_:)`
  (Task 6), `DeadAssetScanner.CleanupCandidate` (Task 1/2, `Identifiable` via `id`).
- Produces: nothing further — last task in the vertical slice.

- [ ] **Step 1: Add the `cleanup` param and Cleanup section to `SiteNavigatorView`**

In `Sources/AnglesiteApp/SiteNavigatorView.swift`, change the struct's properties (lines 6-8):

```swift
struct SiteNavigatorView: View {
    @Bindable var model: SiteNavigatorModel
    @Bindable var cleanup: ProjectCleanupModel
    var onOpenCleanupCandidate: (DeadAssetScanner.CleanupCandidate) -> Void
    @FocusState private var editingFocused: Bool
    @State private var candidateToDelete: DeadAssetScanner.CleanupCandidate?
```

Add the Cleanup section to the `List` body, right after the existing `ForEach(model.sections)`
block (after line 24, before the closing `}` of the `List`):

```swift
            ForEach(model.sections) { section in
                if let title = section.title {
                    Section(title) {
                        ForEach(section.items) { item in
                            row(for: item, in: section)
                        }
                    }
                } else {
                    ForEach(section.items) { item in
                        row(for: item, in: section)
                    }
                }
            }
            // Only shown once the site has real content — an empty new site keeps the plain
            // "No content yet" overlay rather than stacking a Cleanup prompt underneath it.
            if !model.sections.isEmpty {
                Section("Cleanup") {
                    cleanupContent
                }
            }
```

Add the `cleanupContent` view builder and `cleanupIcon` helper as new private members of
`SiteNavigatorView` (e.g. right after the existing `icon(for:)` method):

```swift
    @ViewBuilder
    private var cleanupContent: some View {
        if !cleanup.hasScanned {
            Button {
                Task { await cleanup.scan() }
            } label: {
                Label(
                    cleanup.isScanning ? "Scanning…" : "Scan for Cleanup Opportunities",
                    systemImage: "sparkle.magnifyingglass")
            }
            .disabled(cleanup.isScanning)
        } else if cleanup.candidates.isEmpty {
            Text("No unused files found")
                .foregroundStyle(.secondary)
        } else {
            ForEach(cleanup.candidates) { candidate in
                Label(candidate.path, systemImage: cleanupIcon(for: candidate.kind))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contextMenu {
                        Button("Open") { onOpenCleanupCandidate(candidate) }
                        Button("Ignore") { cleanup.ignore(candidate) }
                        Button("Delete", role: .destructive) { candidateToDelete = candidate }
                    }
            }
            Button {
                Task { await cleanup.scan() }
            } label: {
                Label(cleanup.isScanning ? "Scanning…" : "Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(cleanup.isScanning)
        }
    }

    private func cleanupIcon(for kind: DeadAssetScanner.CleanupCandidate.Kind) -> String {
        switch kind {
        case .component: return "square.stack.3d.up"
        case .layout: return "rectangle.stack"
        case .image: return "photo"
        case .page: return "doc.richtext"
        }
    }
```

Add the delete confirmation dialog and delete-error alert as new `.modifier` calls on the `List` in
`body`, right after the existing `.alert("Rename failed", ...)` block (after line 57, before the
closing `}` of `body`):

```swift
        .confirmationDialog(
            candidateToDelete.map(deleteConfirmationTitle) ?? "",
            isPresented: Binding(
                get: { candidateToDelete != nil },
                set: { if !$0 { candidateToDelete = nil } }),
            titleVisibility: .visible,
            presenting: candidateToDelete
        ) { candidate in
            Button("Delete", role: .destructive) {
                Task { await cleanup.delete(candidate) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { candidate in
            Text(candidate.kind == .page
                ? "This page has no incoming links. Its content will be removed from the working tree. This can be undone via git."
                : "This file appears unused. It will be removed from the working tree. This can be undone via git.")
        }
        .alert(
            "Delete failed",
            isPresented: Binding(
                get: { cleanup.deleteError != nil },
                set: { if !$0 { cleanup.deleteError = nil } }),
            presenting: cleanup.deleteError
        ) { _ in
            Button("OK", role: .cancel) { cleanup.deleteError = nil }
        } message: { msg in
            Text(msg)
        }
```

Add the title helper as a new private method:

```swift
    private func deleteConfirmationTitle(for candidate: DeadAssetScanner.CleanupCandidate) -> String {
        candidate.kind == .page
            ? "Delete “\(candidate.path)”?"
            : "Delete unused \(candidate.kind.rawValue) “\(candidate.path)”?"
    }
```

- [ ] **Step 2: Pass `cleanup` and the open-callback from `SiteWindow`**

In `Sources/AnglesiteApp/SiteWindow.swift:97`, change:

```swift
                SiteNavigatorView(model: navigator)
```

to:

```swift
                SiteNavigatorView(
                    model: navigator,
                    cleanup: model.cleanup,
                    onOpenCleanupCandidate: { model.openCleanupCandidate($0) }
                )
```

- [ ] **Step 3: Build to verify it compiles**

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcrun swift build --target AnglesiteApp
```

Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteApp/SiteNavigatorView.swift Sources/AnglesiteApp/SiteWindow.swift
git commit -m "feat(dead-assets): render the Cleanup section with Open/Ignore/Delete"
```

---

### Task 8: Full test suite + manual smoke verification

**Files:** none (verification only)

**Interfaces:** none — this task only runs and observes.

- [ ] **Step 1: Run the full AnglesiteCore + app build**

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcrun swift test --package-path .
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
```

(`xcodegen generate` first if `Anglesite.xcodeproj` doesn't exist in this worktree yet, and
`scripts/copy-plugin.sh` if `Resources/plugin` is empty — both per this repo's existing worktree
setup requirements.)

Expected: all tests pass, the app builds.

- [ ] **Step 2: Manual smoke test in the running app**

Open a real (or scratch) `.anglesite` site with at least one intentionally-unused component under
`src/components/` and one intentionally-unused image under `public/images/`. In the running app:

1. Open the site window; confirm the sidebar shows a "Cleanup" section with a "Scan for Cleanup
   Opportunities" row.
2. Click it; confirm it lists the unused component and unused image (and any orphaned page, if the
   fixture site has one), each with the correct icon.
3. Right-click a candidate → **Ignore**; confirm it disappears from the list without touching the
   file on disk (`git status` in `Source/` shows nothing).
4. Right-click another candidate → **Delete**; confirm the confirmation dialog appears with
   type-appropriate copy, confirm, and verify: the file is gone from disk, `git log -1` in
   `Source/` shows a new commit removing exactly that file, and the row disappears from the list.
5. Right-click a component candidate → **Open**; confirm it opens in the Component Editor (not the
   plain text editor). Right-click an image candidate → **Open**; confirm Finder opens with the
   image selected.
6. Click **Rescan**; confirm previously-deleted/ignored items don't reappear (deleted: gone from
   disk; ignored: still session-suppressed).

- [ ] **Step 3: Commit only if the smoke test surfaced a fix**

If Step 2 finds nothing to fix, there is nothing to commit — this task is verification-only. If it
does surface a bug, fix it, re-run Steps 1-2, then commit the fix with a message describing what
the smoke test caught.

## Self-Review Notes

- **Spec coverage:** §3 (DeadAssetScanner) → Tasks 1-2. §3.2/`ProjectCleanupReport` → Task 3. §5
  (git-tracked delete) → Task 4. §4 (trigger/data flow) → Task 5 (`ProjectCleanupModel.scan()`).
  §6 (UI) → Tasks 6-7. §7 (error handling) → Task 4's dirty-tree/no-repo test, Task 5's
  `deleteError` path, Task 7's alert. §9 (testing) → covered by each task's own test steps. No gaps
  found.
- **Placeholder scan:** no TBD/TODO/"add error handling" phrasing anywhere in the tasks above —
  every step has complete code.
- **Type consistency:** `CleanupCandidate` (Task 1), `ProjectCleanupReport.build` (Task 3),
  `ProjectCleanupModel` (Task 5), `SiteWindowModel.openCleanupCandidate` (Task 6), and
  `SiteNavigatorView`'s context menu (Task 7) all reference the same
  `DeadAssetScanner.CleanupCandidate` type and `.kind`/`.path`/`.id` field names consistently
  throughout — checked task-by-task while drafting, no drift.

## Final whole-branch review fixes (post-Task 8)

The final whole-branch review found two Important issues that only show up once the whole
feature is viewed together (neither individual task's diff revealed them): (1)
`processGitDelete` could leave a file deleted from disk with no commit if `git commit` failed
after `git rm` already succeeded, violating the "file left untouched on any delete failure"
safety property; (2) deleting a Cleanup candidate open in the in-app editor didn't close that
tab, risking the editor's save-on-leave flow silently resurrecting the just-deleted file. Both
were fixed and re-reviewed clean (commits `cb6362f4`, `321ed097`), alongside two cheap Minor
fixes: the design-mandated 512KB file-size skip guard that had been silently dropped during
implementation, and a doc-comment caveat about the regex scanner's blind spots (brace-bound
dynamic references, dynamic `import()`, re-export barrels) (commit `66765fea`).

Explicitly deferred as follow-ups (not fixed in this slice): untracked (never-committed)
candidates can't be deleted via `git rm` and get a misleading error message; orphan pages open in
the text editor rather than live preview via Cleanup's "Open" (a deliberate simplification, not a
bug); `SiteContentGraph` images aren't force-refreshed as part of `scan()`; Cleanup candidate rows
are selectable/highlightable despite clicks doing nothing (minor UX polish); no dedicated unit
test exists for `ProjectCleanupModel` (`AnglesiteApp` has no SwiftPM test target at all, matching
the existing `RelatedPagesModel` precedent).
