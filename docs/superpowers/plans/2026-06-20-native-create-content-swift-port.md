# Native Swift `create_page` / `create_post` (Bucket 1, Slice 2) Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the `create_page` and `create_post` operations from the Node MCP sidecar into native Swift so content scaffolding runs in-process with no subprocess round-trip, advancing the Claude-Code-removal roadmap's Bucket 1 (hot-path → Swift).

**Architecture:** Two new AnglesiteCore units — `ContentScaffold` (pure functions: slugify, route/path derivation, template rendering, escaping; byte-faithful to the Node templates) and `NativeContentOperations` (a `ContentOperationsService` conformer that validates input, writes the file via `FileManager`, and commits best-effort via an injected git closure). The App Intents dependency registration in `Bootstrap.swift` swaps `ContentOperations` (MCP-routed) for `NativeContentOperations`. The Node `create_page`/`create_post` tools are left in place but no longer called from the app; they are deleted in the roadmap's cleanup slice.

**Tech Stack:** Swift 6.4 / Xcode 27, Swift Testing (`@Test`), `FileManager`, `ProcessSupervisor` for git.

## Global Constraints

- **Swift Testing only** for new tests (`@Test` / `@Suite` / `#expect`) — not XCTest. (Matches the AnglesiteCore convention; the few XCTest holdouts are legacy.)
- **All logic lives in `AnglesiteCore`** so it runs under `swift test` on CI. The only app-side change (Bootstrap DI) is config, verified by build + existing intent tests.
- **No `Process()` outside `ProcessSupervisor`** — git runs via `ProcessSupervisor.shared.run(...)`.
- **Byte-faithful output:** the generated `.astro` / `.md` must be identical to the Node sidecar's output (same templates, same escaping, same trailing newline) so switching backends produces no spurious git churn.
- **Best-effort git:** a git failure (no repo, rejecting hook, git missing) must never fail the create — the file stays on disk and the operation still returns `.created`. (The `ContentCreateResult` carries no commit field, so the SHA is simply discarded, matching today's behavior.)
- **Conventional commits** for each task's commit.
- **Faithful behavior reference:** `…/anglesite/server/create-content.mjs` is the source of truth being ported. Reproduce its validation messages verbatim.

## File Structure

- **Create** `Sources/AnglesiteCore/ContentScaffold.swift` — pure, side-effect-free scaffolding functions. One responsibility: turn inputs into paths + file contents.
- **Create** `Sources/AnglesiteCore/NativeContentOperations.swift` — the `ContentOperationsService` impl: orchestrates dir resolution, validation, file write, git commit, progress.
- **Create** `Tests/AnglesiteCoreTests/ContentScaffoldTests.swift` — pure-function tests (CI).
- **Create** `Tests/AnglesiteCoreTests/NativeContentOperationsTests.swift` — operation tests with temp dirs + a spy git closure, plus one real-git integration test (CI).
- **Modify** `Sources/AnglesiteIntents/Bootstrap.swift:50-51` — register `NativeContentOperations`.

## Reference: behavior being ported (from `create-content.mjs`)

- `slugify`: lowercase → NFKD → strip combining marks U+0300–U+036F → remove `'` `"` → replace `[^a-z0-9]+` with `-` → trim leading/trailing `-`.
- `normalizeRoute`: split on `/`, slugify each segment, drop empties, return `"/" + segments.joined("/")`. (`/About//Us/` → `/about/us`; `About` → `/about`; `/` → `/`.)
- page path: `"src/pages" + normalizedRoute + ".astro"`; layout import depth = segment count of the route (`/about` → `../`, `/a/b` → `../../`).
- post path: `"src/content/\(collection)/\(slug).md"`; collection defaults to `posts`, must match `^[A-Za-z0-9_-]+$`.
- commit messages: page `"anglesite: add page \(route)"`, post `"anglesite: add \(collection) \(slug)"`.

---

### Task 1: `ContentScaffold` pure functions

**Files:**
- Create: `Sources/AnglesiteCore/ContentScaffold.swift`
- Test: `Tests/AnglesiteCoreTests/ContentScaffoldTests.swift`

**Interfaces:**
- Produces (used by Task 2):
  - `enum ContentScaffold` (namespace) with static funcs:
    - `slugify(_ value: String) -> String`
    - `normalizeRoute(_ route: String) -> String`
    - `pageRelativePath(normalizedRoute: String) -> String`
    - `layoutImport(normalizedRoute: String) -> String`
    - `renderPage(title: String, layoutImport: String) -> String`
    - `postRelativePath(collection: String, slug: String) -> String`
    - `renderPost(title: String, now: Date) -> String`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/AnglesiteCoreTests/ContentScaffoldTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("ContentScaffold")
struct ContentScaffoldTests {
    @Test("slugify lowercases, strips diacritics, collapses to hyphens, trims")
    func slugifyBasics() {
        #expect(ContentScaffold.slugify("About Us") == "about-us")
        #expect(ContentScaffold.slugify("Héllo Wörld") == "hello-world")
        #expect(ContentScaffold.slugify("  --Tom's Page--  ") == "toms-page")
        #expect(ContentScaffold.slugify("A/B") == "a-b")
        #expect(ContentScaffold.slugify("\"Quoted\"") == "quoted")
    }

    @Test("normalizeRoute slugifies each segment and joins with slash")
    func normalizeRouteSegments() {
        #expect(ContentScaffold.normalizeRoute("/About//Us/") == "/about/us")
        #expect(ContentScaffold.normalizeRoute("About") == "/about")
        #expect(ContentScaffold.normalizeRoute("/") == "/")
    }

    @Test("layoutImport depth tracks route segment count")
    func layoutImportDepth() {
        #expect(ContentScaffold.layoutImport(normalizedRoute: "/about") == "../layouts/BaseLayout.astro")
        #expect(ContentScaffold.layoutImport(normalizedRoute: "/a/b") == "../../layouts/BaseLayout.astro")
    }

    @Test("path builders match the sidecar layout")
    func paths() {
        #expect(ContentScaffold.pageRelativePath(normalizedRoute: "/about") == "src/pages/about.astro")
        #expect(ContentScaffold.pageRelativePath(normalizedRoute: "/a/b") == "src/pages/a/b.astro")
        #expect(ContentScaffold.postRelativePath(collection: "posts", slug: "hello") == "src/content/posts/hello.md")
    }

    @Test("renderPage escapes attrs and html and ends with one newline")
    func renderPage() {
        let out = ContentScaffold.renderPage(title: "A & \"B\"", layoutImport: "../layouts/BaseLayout.astro")
        #expect(out.contains("import BaseLayout from \"../layouts/BaseLayout.astro\";"))
        #expect(out.contains("<BaseLayout title=\"A &amp; &quot;B&quot;\" description=\"A &amp; &quot;B&quot;.\">"))
        #expect(out.contains("<h1>A &amp; \"B\"</h1>"))
        #expect(out.hasSuffix("</BaseLayout>\n"))
    }

    @Test("renderPost emits a draft with ISO8601 publishDate and YAML-escaped title")
    func renderPost() {
        let date = Date(timeIntervalSince1970: 1_750_000_000) // fixed, deterministic
        let out = ContentScaffold.renderPost(title: "Back\\slash \"quote\"", now: date)
        #expect(out.contains("title: \"Back\\\\slash \\\"quote\\\"\""))
        #expect(out.contains("draft: true"))
        #expect(out.contains("publishDate: 2025-06-15T15:06:40.000Z"))
        #expect(out.hasSuffix("Write your post here.\n"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ContentScaffold`
Expected: FAIL to build — "cannot find 'ContentScaffold' in scope".

- [ ] **Step 3: Write the implementation**

```swift
// Sources/AnglesiteCore/ContentScaffold.swift
import Foundation

/// Pure, side-effect-free scaffolding for new pages and posts. Byte-faithful to the Node
/// sidecar's `create-content.mjs` so switching the create backend produces no git churn.
public enum ContentScaffold {

    /// lowercase → NFKD → strip combining marks → drop quotes → non-alphanumerics to `-` → trim `-`.
    public static func slugify(_ value: String) -> String {
        let lowered = value.lowercased()
        let decomposed = lowered.decomposedStringWithCompatibilityMapping // NFKD
        let stripped = String(decomposed.unicodeScalars.filter { !(0x0300...0x036F ~= $0.value) })
        let noQuotes = stripped
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\"", with: "")
        let hyphenated = noQuotes.replacingOccurrences(
            of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        return hyphenated.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Slugify each `/`-separated segment, drop empties, rejoin with a leading slash.
    public static func normalizeRoute(_ route: String) -> String {
        let segments = route
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { slugify(String($0)) }
            .filter { !$0.isEmpty }
        return "/" + segments.joined(separator: "/")
    }

    public static func pageRelativePath(normalizedRoute: String) -> String {
        "src/pages" + normalizedRoute + ".astro"
    }

    public static func postRelativePath(collection: String, slug: String) -> String {
        "src/content/\(collection)/\(slug).md"
    }

    /// `/about` → `../layouts/BaseLayout.astro`; `/a/b` → `../../layouts/BaseLayout.astro`.
    public static func layoutImport(normalizedRoute: String) -> String {
        let trimmed = normalizedRoute.hasPrefix("/") ? String(normalizedRoute.dropFirst()) : normalizedRoute
        let depth = trimmed.split(separator: "/", omittingEmptySubsequences: false).count
        return String(repeating: "../", count: depth) + "layouts/BaseLayout.astro"
    }

    public static func renderPage(title: String, layoutImport: String) -> String {
        let description = "\(title)."
        return """
        ---
        import BaseLayout from "\(layoutImport)";
        ---

        <BaseLayout title="\(escapeAttr(title))" description="\(escapeAttr(description))">
          <main>
            <h1>\(escapeHTML(title))</h1>
            <p>Add your content here.</p>
          </main>
        </BaseLayout>
        """ + "\n"
    }

    public static func renderPost(title: String, now: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let publishDate = formatter.string(from: now)
        return """
        ---
        title: "\(escapeYAML(title))"
        description: ""
        publishDate: \(publishDate)
        draft: true
        tags: []
        ---

        Write your post here.
        """ + "\n"
    }

    // MARK: - Escaping (order matters: `&` first)

    static func escapeAttr(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func escapeYAML(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ContentScaffold`
Expected: PASS (6 tests). If `publishDate` mismatches, confirm the fixed-date expectation `2025-06-15T15:06:40.000Z` matches `ISO8601DateFormatter` with `.withFractionalSeconds` on this machine and adjust the literal to the observed value.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/ContentScaffold.swift Tests/AnglesiteCoreTests/ContentScaffoldTests.swift
git commit -m "feat(content): native Swift scaffolding functions for pages/posts"
```

---

### Task 2: `NativeContentOperations`

**Files:**
- Create: `Sources/AnglesiteCore/NativeContentOperations.swift`
- Test: `Tests/AnglesiteCoreTests/NativeContentOperationsTests.swift`

**Interfaces:**
- Consumes: `ContentScaffold` (Task 1); `ContentOperationsService` protocol + `ContentCreateResult` enum (existing, `Sources/AnglesiteCore/ContentOperationsService.swift`); the progress milestones `ContentOperations` already emits (`.createResolvingRuntime`, `.createCallingPlugin`, `.createFinalizing` — see `ContentOperations.swift` `create(...)`).
- Produces (used by Task 3):
  - `public struct NativeContentOperations: ContentOperationsService`
  - `public typealias GitCommit = @Sendable (_ projectRoot: URL, _ relPath: String, _ message: String) async -> String?`
  - `public init(siteDirectory: @escaping @Sendable (_ siteID: String) async -> URL?, gitCommit: @escaping GitCommit = NativeContentOperations.processGitCommit, now: @escaping @Sendable () -> Date = { Date() }, fileManager: FileManager = .default)`
  - `public static func processGitCommit(_ projectRoot: URL, _ relPath: String, _ message: String) async -> String?`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/AnglesiteCoreTests/NativeContentOperationsTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("NativeContentOperations")
struct NativeContentOperationsTests {

    /// A temp site dir + a spy git closure that records calls and returns a fake SHA.
    private func makeOps() -> (ops: NativeContentOperations, root: URL, calls: Spy) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-content-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let spy = Spy()
        let ops = NativeContentOperations(
            siteDirectory: { _ in root },
            gitCommit: { proj, rel, msg in await spy.record(proj, rel, msg); return "deadbeef" },
            now: { Date(timeIntervalSince1970: 1_750_000_000) }
        )
        return (ops, root, spy)
    }

    actor Spy {
        private(set) var calls: [(URL, String, String)] = []
        func record(_ a: URL, _ b: String, _ c: String) { calls.append((a, b, c)) }
    }

    @Test("createPage writes the file and returns the normalized route")
    func createPage() async throws {
        let (ops, root, spy) = makeOps()
        let result = await ops.createPage(siteID: "s1", name: "About Us", route: nil)
        #expect(result == .created(filePath: "src/pages/about-us.astro", identifier: "/about-us"))
        let written = try String(contentsOf: root.appendingPathComponent("src/pages/about-us.astro"), encoding: .utf8)
        #expect(written == ContentScaffold.renderPage(title: "About Us", layoutImport: "../layouts/BaseLayout.astro"))
        let calls = await spy.calls
        #expect(calls.count == 1)
        #expect(calls.first?.1 == "src/pages/about-us.astro")
        #expect(calls.first?.2 == "anglesite: add page /about-us")
    }

    @Test("nested route writes under nested dirs with deeper layout import")
    func createNestedPage() async throws {
        let (ops, root, _) = makeOps()
        let result = await ops.createPage(siteID: "s1", name: "ignored", route: "/services/web")
        #expect(result == .created(filePath: "src/pages/services/web.astro", identifier: "/services/web"))
        let written = try String(contentsOf: root.appendingPathComponent("src/pages/services/web.astro"), encoding: .utf8)
        #expect(written.contains("import BaseLayout from \"../../layouts/BaseLayout.astro\";"))
    }

    @Test("createPage refuses the site root")
    func createPageRoot() async {
        let (ops, _, _) = makeOps()
        let result = await ops.createPage(siteID: "s1", name: "/", route: "/")
        guard case let .failed(reason) = result else { Issue.record("expected .failed"); return }
        #expect(reason.contains("site root"))
    }

    @Test("createPage won't overwrite an existing page")
    func createPageExisting() async {
        let (ops, root, _) = makeOps()
        let dir = root.appendingPathComponent("src/pages", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? "x".write(to: dir.appendingPathComponent("about.astro"), atomically: true, encoding: .utf8)
        let result = await ops.createPage(siteID: "s1", name: "About", route: nil)
        guard case let .failed(reason) = result else { Issue.record("expected .failed"); return }
        #expect(reason.contains("already exists"))
    }

    @Test("unknown site returns .siteNotFound")
    func siteNotFound() async {
        let ops = NativeContentOperations(siteDirectory: { _ in nil }, gitCommit: { _, _, _ in nil })
        let result = await ops.createPage(siteID: "missing", name: "About", route: nil)
        #expect(result == .siteNotFound)
    }

    @Test("createPost writes a draft in the default posts collection")
    func createPost() async throws {
        let (ops, root, spy) = makeOps()
        let result = await ops.createPost(siteID: "s1", title: "Hello World", collection: nil, slug: nil)
        #expect(result == .created(filePath: "src/content/posts/hello-world.md", identifier: "hello-world"))
        let written = try String(contentsOf: root.appendingPathComponent("src/content/posts/hello-world.md"), encoding: .utf8)
        #expect(written.contains("draft: true"))
        let calls = await spy.calls
        #expect(calls.first?.2 == "anglesite: add posts hello-world")
    }

    @Test("createPost honors a custom collection")
    func createPostCollection() async {
        let (ops, _, _) = makeOps()
        let result = await ops.createPost(siteID: "s1", title: "Note one", collection: "notes", slug: nil)
        #expect(result == .created(filePath: "src/content/notes/note-one.md", identifier: "note-one"))
    }

    @Test("createPost rejects an unsafe collection name")
    func createPostBadCollection() async {
        let (ops, _, _) = makeOps()
        let result = await ops.createPost(siteID: "s1", title: "X", collection: "../escape", slug: nil)
        guard case let .failed(reason) = result else { Issue.record("expected .failed"); return }
        #expect(reason.contains("Invalid collection name"))
    }

    @Test("processGitCommit returns a SHA in a real repo, nil outside one")
    func realGit() async throws {
        // Outside a repo → nil (best-effort).
        let bare = FileManager.default.temporaryDirectory.appendingPathComponent("nogit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        try "hi".write(to: bare.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let none = await NativeContentOperations.processGitCommit(bare, "f.txt", "msg")
        #expect(none == nil)

        // Inside a repo with an initial commit → a 40-char SHA.
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let git = URL(fileURLWithPath: "/usr/bin/git")
        for args in [["init"], ["config", "user.email", "t@t.io"], ["config", "user.name", "t"]] {
            _ = try await ProcessSupervisor.shared.run(executable: git, arguments: args, currentDirectoryURL: repo)
        }
        try "page".write(to: repo.appendingPathComponent("p.astro"), atomically: true, encoding: .utf8)
        let sha = await NativeContentOperations.processGitCommit(repo, "p.astro", "anglesite: add page /p")
        #expect(sha?.count == 40)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter NativeContentOperations`
Expected: FAIL to build — "cannot find 'NativeContentOperations' in scope".

- [ ] **Step 3: Write the implementation**

```swift
// Sources/AnglesiteCore/NativeContentOperations.swift
import Foundation

/// Native, in-process `create_page` / `create_post`. Byte-faithful to the Node sidecar's
/// `create-content.mjs` (see `ContentScaffold`), but writes the file with `FileManager` and
/// commits best-effort via an injected git closure — no MCP round-trip. Replaces the
/// MCP-routed `ContentOperations` at the App Intents dependency registration.
public struct NativeContentOperations: ContentOperationsService {

    public typealias GitCommit = @Sendable (_ projectRoot: URL, _ relPath: String, _ message: String) async -> String?

    private let siteDirectory: @Sendable (_ siteID: String) async -> URL?
    private let gitCommit: GitCommit
    private let now: @Sendable () -> Date
    private let fileManager: FileManager

    public init(
        siteDirectory: @escaping @Sendable (_ siteID: String) async -> URL?,
        gitCommit: @escaping GitCommit = NativeContentOperations.processGitCommit,
        now: @escaping @Sendable () -> Date = { Date() },
        fileManager: FileManager = .default
    ) {
        self.siteDirectory = siteDirectory
        self.gitCommit = gitCommit
        self.now = now
        self.fileManager = fileManager
    }

    public func createPage(siteID: String, name: String, route: String?, onProgress: ProgressHandler? = nil) async -> ContentCreateResult {
        onProgress?(.createResolvingRuntime)
        guard let root = await siteDirectory(siteID) else { return .siteNotFound }

        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return .failed(reason: "create_page requires a non-empty name") }

        let base = (route?.isEmpty == false) ? route! : ContentScaffold.slugify(title)
        let normalized = ContentScaffold.normalizeRoute(base)
        guard normalized != "/" else {
            return .failed(reason: "create_page can't scaffold the site root; give the page a name or route")
        }

        let relPath = ContentScaffold.pageRelativePath(normalizedRoute: normalized)
        let abs = root.appendingPathComponent(relPath)
        if fileManager.fileExists(atPath: abs.path) {
            return .failed(reason: "A page already exists at \(relPath)")
        }

        onProgress?(.createCallingPlugin)
        let contents = ContentScaffold.renderPage(
            title: title,
            layoutImport: ContentScaffold.layoutImport(normalizedRoute: normalized))
        do { try write(contents, to: abs) }
        catch { return .failed(reason: "\(error)") }

        onProgress?(.createFinalizing)
        _ = await gitCommit(root, relPath, "anglesite: add page \(normalized)")
        return .created(filePath: relPath, identifier: normalized)
    }

    public func createPost(siteID: String, title: String, collection: String?, slug: String?, onProgress: ProgressHandler? = nil) async -> ContentCreateResult {
        onProgress?(.createResolvingRuntime)
        guard let root = await siteDirectory(siteID) else { return .siteNotFound }

        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return .failed(reason: "create_post requires a non-empty title") }

        let trimmedColl = (collection ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let coll = trimmedColl.isEmpty ? "posts" : trimmedColl
        guard coll.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            return .failed(reason: "Invalid collection name: \(coll)")
        }

        let slugSource = (slug?.isEmpty == false) ? slug! : cleanTitle
        let finalSlug = ContentScaffold.slugify(slugSource)
        guard !finalSlug.isEmpty else { return .failed(reason: "create_post could not derive a slug from the title") }

        let relPath = ContentScaffold.postRelativePath(collection: coll, slug: finalSlug)
        let abs = root.appendingPathComponent(relPath)
        if fileManager.fileExists(atPath: abs.path) {
            return .failed(reason: "A \(coll) entry already exists at \(relPath)")
        }

        onProgress?(.createCallingPlugin)
        let contents = ContentScaffold.renderPost(title: cleanTitle, now: now())
        do { try write(contents, to: abs) }
        catch { return .failed(reason: "\(error)") }

        onProgress?(.createFinalizing)
        _ = await gitCommit(root, relPath, "anglesite: add \(coll) \(finalSlug)")
        return .created(filePath: relPath, identifier: finalSlug)
    }

    private func write(_ contents: String, to abs: URL) throws {
        try fileManager.createDirectory(at: abs.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: abs, atomically: true, encoding: .utf8)
    }

    /// Stage and commit exactly `relPath` on the current branch. Returns the new HEAD SHA,
    /// or nil on any failure (not a repo, rejecting hook, git missing) — best-effort, mirroring
    /// the Node sidecar's `commitFile`.
    public static func processGitCommit(_ projectRoot: URL, _ relPath: String, _ message: String) async -> String? {
        let git = URL(fileURLWithPath: "/usr/bin/git")
        func run(_ args: [String]) async -> ProcessSupervisor.RunResult? {
            let result = try? await ProcessSupervisor.shared.run(executable: git, arguments: args, currentDirectoryURL: projectRoot)
            guard let result, result.exitCode == 0 else { return nil }
            return result
        }
        guard await run(["rev-parse", "--git-dir"]) != nil,
              await run(["add", "--", relPath]) != nil,
              await run(["commit", "-m", message, "--", relPath]) != nil,
              let head = await run(["rev-parse", "HEAD"]) else { return nil }
        return head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter NativeContentOperations`
Expected: PASS (9 tests). If `ProgressHandler` / the `.create*` milestone case names differ from `ContentOperations.swift`, match them exactly (read that file's `create(...)` body) — they are the only cross-file names this task reuses.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/NativeContentOperations.swift Tests/AnglesiteCoreTests/NativeContentOperationsTests.swift
git commit -m "feat(content): NativeContentOperations writes + commits pages/posts in-process"
```

---

### Task 3: Register `NativeContentOperations` for the App Intents

**Files:**
- Modify: `Sources/AnglesiteIntents/Bootstrap.swift:50-51`

**Interfaces:**
- Consumes: `NativeContentOperations` (Task 2); `SiteStore.shared.find(id:)?.sourceDirectory` (existing, already used in the current registration).

- [ ] **Step 1: Swap the dependency registration**

Replace the current registration body:

```swift
AppDependencyManager.shared.add { () -> any ContentOperationsService in
    ContentOperations(pool: headlessPool, siteDirectory: { id in await SiteStore.shared.find(id: id)?.sourceDirectory })
}
```

with:

```swift
AppDependencyManager.shared.add { () -> any ContentOperationsService in
    // Native in-process scaffolding (Bucket 1, Slice 2). Replaces the MCP-routed
    // ContentOperations; the Node create_page/create_post tools are retired in the
    // roadmap's cleanup slice. `headlessPool` stays in scope for other dependencies.
    NativeContentOperations(siteDirectory: { id in await SiteStore.shared.find(id: id)?.sourceDirectory })
}
```

- [ ] **Step 2: Verify the build and the existing intent tests still pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter AnglesiteIntentsTests`
Expected: PASS. The content-intent tests inject via `ContentOperationsOverride.scoped`, so they exercise the intent flow independently of this registration; they must remain green. (If `headlessPool` is now unused in `Bootstrap.swift`, remove its now-dead construction only if it has no other consumers — grep first; otherwise leave it.)

- [ ] **Step 3: Full-suite sanity check**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .`
Expected: PASS across AnglesiteCoreTests / AnglesiteIntentsTests / AnglesiteBridgeTests. `ContentOperationsTests` (the MCP-routed type) still exists and still passes — that type is retained until the cleanup slice; this task only changes which impl the intents resolve.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteIntents/Bootstrap.swift
git commit -m "feat(content): route Add Page/Post intents through NativeContentOperations"
```

---

## Self-Review

**1. Spec coverage.** This plan implements roadmap Slice 2 (Bucket 1 hot-path port of `create_page`/`create_post`). It does not cover `list_content` or the annotations tools (the other Bucket 1 items) — those are separate slices/plans, by design. Slice 1 (chat → Foundation Models) is already implemented in the codebase except for flipping the `preferFoundationModels` default; that is a one-line settings change handled outside this plan (see handoff note). No gap within this plan's scope.

**2. Placeholder scan.** No TBD/TODO; every code step shows complete code; both error paths and templates are spelled out. The two "match the existing names" notes (progress milestones in Task 2; `ProgressHandler`) point at a named existing file rather than leaving a blank — acceptable because they are pre-existing symbols this module already shares, not new contracts.

**3. Type consistency.** `ContentScaffold` static-func names are identical between Task 1's definition, its tests, and Task 2's call sites (`slugify`, `normalizeRoute`, `pageRelativePath`, `postRelativePath`, `layoutImport`, `renderPage`, `renderPost`). `NativeContentOperations` init signature, `GitCommit` typealias, and `processGitCommit` match between Task 2's interface block, its tests, and Task 3's call site. `ContentCreateResult` cases (`.created(filePath:identifier:)`, `.siteNotFound`, `.failed(reason:)`) are the existing enum, used consistently.

**4. Faithfulness risk.** The one behavioral subtlety is `publishDate` formatting — Step 4 of Task 1 instructs verifying the fixed-date literal against the machine's `ISO8601DateFormatter` output and adjusting if needed, so a formatter quirk surfaces as a checked assertion rather than silent drift.
