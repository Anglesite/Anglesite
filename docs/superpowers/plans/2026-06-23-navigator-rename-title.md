# Navigator Page/Post Re-titling Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user re-title a page or post in the project navigator by control-clicking the name and editing it in place (Finder-style), writing the new title to the correct location for the file type without moving the file or changing its URL.

**Architecture:** A pure, fully-tested `PageTitleEditor` (AnglesiteCore) rewrites a file's title in memory — frontmatter `title:` for markdown, the `title="…"` attribute for `.astro`/`.html`. A `NavigatorRenameService` (AnglesiteCore) wires load → rewrite → save → best-effort git commit behind injected I/O seams so it is unit-testable. The app-target `SiteNavigatorModel` adds thin edit-state glue (begin/cancel/commit, `canRename`, error surface) and reflects the new title into `SiteContentGraph` via `upsertPage`/`upsertPost`; `SiteNavigatorView` renders an inline `TextField` plus a Rename context menu and Return-key path.

**Tech Stack:** Swift 6.4 / SwiftUI (macOS 27), Swift Testing (`@Test`), the existing `SiteContentGraph` actor, `FileDocumentIO`, and `NativeContentOperations.processGitCommit`.

## Global Constraints

- **Toolchain:** Xcode 27+ / Swift 6.4. `xcode-select -p` is already `/Applications/Xcode-beta.app/Contents/Developer`; if a run picks the wrong toolchain, prefix with `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`.
- **Run Core tests with:** `swift test --package-path . --filter <Name>` from the worktree root `/Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/navigator-rename`.
- **App-target build check:** `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`. The xcodeproj is generated; run `xcodegen generate` first if it is missing, and run `scripts/copy-plugin.sh` (with `ANGLESITE_PLUGIN_SRC` pointing at the real plugin checkout) if the build complains about `Resources/plugin`.
- **ES Modules / vanilla:** N/A — this is pure Swift; no new third-party deps.
- **Tests:** Swift Testing `@Test` in `@Suite` structs (see `Tests/AnglesiteCoreTests/ContentScannerTests.swift` for the temp-dir helper pattern). No XCTest.
- **Commits:** Conventional commits, one per task. End every commit message body with:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- **Title-only invariant:** never change a file's path, name, or route. Only the title text changes.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `Sources/AnglesiteCore/PageTitleEditor.swift` | Pure title rewrite per file type | 1 |
| `Tests/AnglesiteCoreTests/PageTitleEditorTests.swift` | Unit tests for the rewrite | 1 |
| `Sources/AnglesiteCore/NavigatorRenameService.swift` | load → rewrite → save → best-effort commit | 2 |
| `Tests/AnglesiteCoreTests/NavigatorRenameServiceTests.swift` | Unit tests for the flow | 2 |
| `Sources/AnglesiteApp/SiteNavigatorModel.swift` | Edit-state glue, `canRename`, graph upsert, error surface, `sourceDirectory` | 3 |
| `Sources/AnglesiteApp/SiteWindow.swift` | Pass `sourceDirectory` into `start(...)` | 3 |
| `Sources/AnglesiteApp/SiteNavigatorView.swift` | Inline `TextField`, Rename menu, Return key, error alert | 4 |

---

## Task 1: `PageTitleEditor` (pure rewrite core)

**Files:**
- Create: `Sources/AnglesiteCore/PageTitleEditor.swift`
- Test: `Tests/AnglesiteCoreTests/PageTitleEditorTests.swift`

**Interfaces:**
- Consumes: nothing (pure, stdlib only).
- Produces:
  ```swift
  public enum PageTitleEditor {
      public enum RewriteError: Error, Equatable { case emptyTitle, noEditableLocation }
      public static func rewrite(contents: String, fileExtension: String, newTitle: String)
          -> Result<String, RewriteError>
  }
  ```
  `fileExtension` is the lowercased extension **without** a leading dot (e.g. `"astro"`, `"md"`). Markdown family = `md`, `mdx`, `mdoc`, `markdown`. Attribute family = `astro`, `html`. Returns the full rewritten file contents on success.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/PageTitleEditorTests.swift`:

```swift
// Tests/AnglesiteCoreTests/PageTitleEditorTests.swift
import Testing
@testable import AnglesiteCore

@Suite("PageTitleEditor")
struct PageTitleEditorTests {
    private func ok(_ r: Result<String, PageTitleEditor.RewriteError>) -> String {
        guard case let .success(s) = r else { Issue.record("expected success, got \(r)"); return "" }
        return s
    }

    @Test("markdown: replaces an existing frontmatter title")
    func mdReplace() {
        let src = "---\ntitle: \"Old\"\npubDate: 2026-01-01\n---\n\nBody\n"
        let out = ok(PageTitleEditor.rewrite(contents: src, fileExtension: "md", newTitle: "New"))
        #expect(out == "---\ntitle: \"New\"\npubDate: 2026-01-01\n---\n\nBody\n")
    }

    @Test("markdown: inserts title when frontmatter has none")
    func mdInsert() {
        let src = "---\npubDate: 2026-01-01\n---\n\nBody\n"
        let out = ok(PageTitleEditor.rewrite(contents: src, fileExtension: "mdx", newTitle: "New"))
        #expect(out == "---\ntitle: \"New\"\npubDate: 2026-01-01\n---\n\nBody\n")
    }

    @Test("markdown: synthesizes a frontmatter block when absent")
    func mdSynthesize() {
        let src = "Just body, no frontmatter.\n"
        let out = ok(PageTitleEditor.rewrite(contents: src, fileExtension: "markdown", newTitle: "New"))
        #expect(out == "---\ntitle: \"New\"\n---\n\nJust body, no frontmatter.\n")
    }

    @Test("astro: replaces a double-quoted title attribute, preserving the rest")
    func astroDouble() {
        let src = "---\nimport BaseLayout from \"../layouts/BaseLayout.astro\";\n---\n\n<BaseLayout title=\"Old Home\" description=\"d\">\n"
        let out = ok(PageTitleEditor.rewrite(contents: src, fileExtension: "astro", newTitle: "New Home"))
        #expect(out.contains("title=\"New Home\""))
        #expect(out.contains("description=\"d\""))
        #expect(!out.contains("Old Home"))
    }

    @Test("astro: replaces a single-quoted title attribute")
    func astroSingle() {
        let src = "<BaseLayout title='Old' />"
        let out = ok(PageTitleEditor.rewrite(contents: src, fileExtension: "astro", newTitle: "New"))
        #expect(out.contains("title='New'"))
    }

    @Test("html: replaces a title attribute")
    func htmlAttr() {
        let src = "<x title=\"Old\">"
        let out = ok(PageTitleEditor.rewrite(contents: src, fileExtension: "html", newTitle: "New"))
        #expect(out == "<x title=\"New\">")
    }

    @Test("astro: no title attribute → noEditableLocation")
    func astroNoAttr() {
        let r = PageTitleEditor.rewrite(contents: "<BaseLayout description=\"d\" />", fileExtension: "astro", newTitle: "New")
        #expect(r == .failure(.noEditableLocation))
    }

    @Test("empty or whitespace title → emptyTitle for any type")
    func empty() {
        #expect(PageTitleEditor.rewrite(contents: "---\ntitle: \"x\"\n---\n", fileExtension: "md", newTitle: "  ") == .failure(.emptyTitle))
        #expect(PageTitleEditor.rewrite(contents: "<a title=\"x\">", fileExtension: "astro", newTitle: "") == .failure(.emptyTitle))
    }

    @Test("markdown: YAML-escapes quotes and backslashes")
    func mdEscape() {
        let out = ok(PageTitleEditor.rewrite(contents: "---\ntitle: \"x\"\n---\n", fileExtension: "md", newTitle: "a\"b\\c"))
        #expect(out.contains("title: \"a\\\"b\\\\c\""))
    }

    @Test("astro: HTML-escapes the title value, preserving quote style")
    func astroEscape() {
        let out = ok(PageTitleEditor.rewrite(contents: "<a title=\"x\">", fileExtension: "astro", newTitle: "Tom & \"Jerry\" <b>"))
        // Double-quoted delimiter: escape &, <, and the " delimiter; ' may stay literal.
        #expect(out.contains("title=\"Tom &amp; &quot;Jerry&quot; &lt;b&gt;\""))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path . --filter PageTitleEditor`
Expected: FAIL — `cannot find 'PageTitleEditor' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/AnglesiteCore/PageTitleEditor.swift`:

```swift
import Foundation

/// Rewrites a page/post's *title* in place — frontmatter `title:` for markdown-family files,
/// the first `title="…"`/`title='…'` attribute for `.astro`/`.html`. Pure and I/O-free so the
/// transform is fully unit-testable; `NavigatorRenameService` owns the disk + git side.
///
/// `.astro` files use a JavaScript component script between `---` fences (NOT YAML), so we never
/// write YAML frontmatter there — the title lives in the layout invocation's `title=` prop.
public enum PageTitleEditor {
    public enum RewriteError: Error, Equatable {
        case emptyTitle
        case noEditableLocation
    }

    private static let markdownExts: Set<String> = ["md", "mdx", "mdoc", "markdown"]
    private static let attributeExts: Set<String> = ["astro", "html"]

    public static func rewrite(
        contents: String,
        fileExtension: String,
        newTitle: String
    ) -> Result<String, RewriteError> {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.emptyTitle) }

        let ext = fileExtension.lowercased()
        if markdownExts.contains(ext) { return .success(rewriteMarkdown(contents, title: trimmed)) }
        if attributeExts.contains(ext) { return rewriteAttribute(contents, title: trimmed) }
        // Unknown extension: nowhere defined to write a title.
        return .failure(.noEditableLocation)
    }

    // MARK: - Markdown frontmatter

    /// Replace the `title:` line inside a leading `---` block, insert one if the block lacks it,
    /// or synthesize a block at the top of the file.
    private static func rewriteMarkdown(_ contents: String, title: String) -> String {
        let yaml = "title: \(yamlQuoted(title))"

        // A frontmatter block must start at byte 0 with `---` on its own line.
        guard contents.hasPrefix("---\n") || contents == "---" || contents.hasPrefix("---\r\n") else {
            return "---\n\(yaml)\n---\n\n\(contents)"
        }

        // Normalize to \n for line work; the templates use \n.
        var lines = contents.components(separatedBy: "\n")
        // lines[0] == "---". Find the closing fence.
        guard let close = lines.dropFirst().firstIndex(of: "---") else {
            // Malformed (no closing fence) — treat as no frontmatter and prepend a fresh block.
            return "---\n\(yaml)\n---\n\n\(contents)"
        }

        // Look for an existing top-level `title:` between the fences.
        if let titleIdx = (1..<close).first(where: { lineKey(lines[$0]) == "title" }) {
            lines[titleIdx] = yaml
        } else {
            lines.insert(yaml, at: 1)
        }
        return lines.joined(separator: "\n")
    }

    /// The top-level key of a frontmatter line (`title: "x"` → `title`), or nil for indented /
    /// keyless lines. Mirrors `Frontmatter`'s "top-level keys only" rule.
    private static func lineKey(_ line: String) -> String? {
        guard let first = line.first, first != " ", first != "\t" else { return nil }
        guard let colon = line.firstIndex(of: ":") else { return nil }
        return String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
    }

    /// Double-quote a YAML scalar, escaping `\` then `"`.
    private static func yamlQuoted(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: - Attribute (astro / html)

    /// Port of `ContentScanner.titleAttrRegex` — the first `title="…"` or `title='…'`.
    private static let titleAttrRegex = try! NSRegularExpression(
        pattern: #"\btitle\s*=\s*(?:"([^"]*)"|'([^']*)')"#
    )

    private static func rewriteAttribute(_ contents: String, title: String) -> Result<String, RewriteError> {
        let full = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        guard let match = titleAttrRegex.firstMatch(in: contents, range: full) else {
            return .failure(.noEditableLocation)
        }
        // Which capture group matched tells us the delimiter: group 1 = ", group 2 = '.
        let usesDouble = match.range(at: 1).location != NSNotFound
        let delimiter: Character = usesDouble ? "\"" : "'"
        let replacement = "title=\(delimiter)\(attrEscaped(title, delimiter: delimiter))\(delimiter)"
        guard let whole = Range(match.range, in: contents) else { return .failure(.noEditableLocation) }
        return .success(contents.replacingCharacters(in: whole, with: replacement))
    }

    /// HTML-attribute-escape: always `&` and `<`/`>`, plus the active quote delimiter.
    private static func attrEscaped(_ s: String, delimiter: Character) -> String {
        var out = s.replacingOccurrences(of: "&", with: "&amp;")
                   .replacingOccurrences(of: "<", with: "&lt;")
                   .replacingOccurrences(of: ">", with: "&gt;")
        out = delimiter == "\""
            ? out.replacingOccurrences(of: "\"", with: "&quot;")
            : out.replacingOccurrences(of: "'", with: "&#39;")
        return out
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path . --filter PageTitleEditor`
Expected: PASS (10 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/PageTitleEditor.swift Tests/AnglesiteCoreTests/PageTitleEditorTests.swift
git commit -m "feat: PageTitleEditor — rewrite page/post title per file type

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `NavigatorRenameService` (load → rewrite → save → commit)

**Files:**
- Create: `Sources/AnglesiteCore/NavigatorRenameService.swift`
- Test: `Tests/AnglesiteCoreTests/NavigatorRenameServiceTests.swift`

**Interfaces:**
- Consumes: `PageTitleEditor.rewrite(...)` (Task 1); `FileDocumentIO.load`/`save`; `NativeContentOperations.GitCommit` typealias = `@Sendable (_ projectRoot: URL, _ relPath: String, _ message: String) async -> String?` and `NativeContentOperations.processGitCommit`.
- Produces:
  ```swift
  public struct NavigatorRenameService: Sendable {
      public enum RenameError: Error, Equatable { case emptyTitle, noEditableLocation, io(String) }
      public typealias GitCommit = NativeContentOperations.GitCommit
      public init(
          loadContents: @escaping @Sendable (URL) throws -> String = { try FileDocumentIO.load($0).contents },
          saveContents: @escaping @Sendable (String, URL) throws -> Void = { try FileDocumentIO.save($0, to: $1) },
          gitCommit: @escaping GitCommit = NativeContentOperations.processGitCommit
      )
      public func rename(
          fileURL: URL, fileExtension: String, projectRoot: URL, relativePath: String, newTitle: String
      ) async -> Result<String, RenameError>
  }
  ```
  On success returns the trimmed new title. Git commit is best-effort: a nil result is ignored.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/NavigatorRenameServiceTests.swift`:

```swift
// Tests/AnglesiteCoreTests/NavigatorRenameServiceTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("NavigatorRenameService")
struct NavigatorRenameServiceTests {
    private let url = URL(fileURLWithPath: "/site/src/content/posts/p.md")
    private let root = URL(fileURLWithPath: "/site")

    @Test("success: rewrites markdown title, saves, commits, returns trimmed title")
    func success() async {
        let saved = Locked<String?>(nil)
        let committed = Locked<(String, String)?>(nil)
        let svc = NavigatorRenameService(
            loadContents: { _ in "---\ntitle: \"Old\"\n---\n\nBody\n" },
            saveContents: { contents, _ in saved.set(contents) },
            gitCommit: { _, rel, msg in committed.set((rel, msg)); return "deadbeef" }
        )
        let result = await svc.rename(
            fileURL: url, fileExtension: "md", projectRoot: root,
            relativePath: "src/content/posts/p.md", newTitle: "  New  ")
        #expect(result == .success("New"))
        #expect(saved.get()?.contains("title: \"New\"") == true)
        #expect(committed.get()?.0 == "src/content/posts/p.md")
        #expect(committed.get()?.1.contains("New") == true)
    }

    @Test("emptyTitle: never saves")
    func emptyTitle() async {
        let saved = Locked<Bool>(false)
        let svc = NavigatorRenameService(
            loadContents: { _ in "---\ntitle: \"Old\"\n---\n" },
            saveContents: { _, _ in saved.set(true) },
            gitCommit: { _, _, _ in "x" })
        let r = await svc.rename(fileURL: url, fileExtension: "md", projectRoot: root, relativePath: "p.md", newTitle: " ")
        #expect(r == .failure(.emptyTitle))
        #expect(saved.get() == false)
    }

    @Test("noEditableLocation: astro without a title attribute never saves")
    func noLocation() async {
        let saved = Locked<Bool>(false)
        let svc = NavigatorRenameService(
            loadContents: { _ in "<BaseLayout description=\"d\" />" },
            saveContents: { _, _ in saved.set(true) },
            gitCommit: { _, _, _ in "x" })
        let r = await svc.rename(fileURL: url, fileExtension: "astro", projectRoot: root, relativePath: "p.astro", newTitle: "New")
        #expect(r == .failure(.noEditableLocation))
        #expect(saved.get() == false)
    }

    @Test("io: save failure maps to .io")
    func ioFailure() async {
        struct Boom: Error {}
        let svc = NavigatorRenameService(
            loadContents: { _ in "---\ntitle: \"Old\"\n---\n" },
            saveContents: { _, _ in throw Boom() },
            gitCommit: { _, _, _ in "x" })
        let r = await svc.rename(fileURL: url, fileExtension: "md", projectRoot: root, relativePath: "p.md", newTitle: "New")
        if case .failure(.io) = r {} else { Issue.record("expected .io, got \(r)") }
    }

    @Test("git failure is best-effort: still success and the save happened")
    func gitBestEffort() async {
        let saved = Locked<Bool>(false)
        let svc = NavigatorRenameService(
            loadContents: { _ in "---\ntitle: \"Old\"\n---\n" },
            saveContents: { _, _ in saved.set(true) },
            gitCommit: { _, _, _ in nil })
        let r = await svc.rename(fileURL: url, fileExtension: "md", projectRoot: root, relativePath: "p.md", newTitle: "New")
        #expect(r == .success("New"))
        #expect(saved.get() == true)
    }
}

/// Minimal thread-safe box so the @Sendable injection closures can record calls.
private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock(); private var value: T
    init(_ v: T) { value = v }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path . --filter NavigatorRenameService`
Expected: FAIL — `cannot find 'NavigatorRenameService' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/AnglesiteCore/NavigatorRenameService.swift`:

```swift
import Foundation

/// The page/post re-title pipeline: load the file, rewrite its title via `PageTitleEditor`, save,
/// then commit best-effort. I/O and git are injected so the flow is unit-testable; the defaults are
/// the real `FileDocumentIO` + `NativeContentOperations.processGitCommit`. Lives in AnglesiteCore
/// (not the app-target model) so `swift test` covers it — the same split as `TokenOnboarding`.
public struct NavigatorRenameService: Sendable {
    public enum RenameError: Error, Equatable {
        case emptyTitle
        case noEditableLocation
        case io(String)
    }

    public typealias GitCommit = NativeContentOperations.GitCommit

    private let loadContents: @Sendable (URL) throws -> String
    private let saveContents: @Sendable (String, URL) throws -> Void
    private let gitCommit: GitCommit

    public init(
        loadContents: @escaping @Sendable (URL) throws -> String = { try FileDocumentIO.load($0).contents },
        saveContents: @escaping @Sendable (String, URL) throws -> Void = { try FileDocumentIO.save($0, to: $1) },
        gitCommit: @escaping GitCommit = NativeContentOperations.processGitCommit
    ) {
        self.loadContents = loadContents
        self.saveContents = saveContents
        self.gitCommit = gitCommit
    }

    public func rename(
        fileURL: URL,
        fileExtension: String,
        projectRoot: URL,
        relativePath: String,
        newTitle: String
    ) async -> Result<String, RenameError> {
        let contents: String
        do { contents = try loadContents(fileURL) }
        catch { return .failure(.io("\(error)")) }

        let rewritten: String
        switch PageTitleEditor.rewrite(contents: contents, fileExtension: fileExtension, newTitle: newTitle) {
        case .success(let s): rewritten = s
        case .failure(.emptyTitle): return .failure(.emptyTitle)
        case .failure(.noEditableLocation): return .failure(.noEditableLocation)
        }

        do { try saveContents(rewritten, fileURL) }
        catch { return .failure(.io("\(error)")) }

        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        // Best-effort: a failed commit (not a repo, rejecting hook, git missing) is ignored —
        // the file is saved and is the source of truth. Mirrors NativeContentOperations.
        _ = await gitCommit(projectRoot, relativePath, "anglesite: rename title to \"\(trimmed)\"")
        return .success(trimmed)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path . --filter NavigatorRenameService`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/NavigatorRenameService.swift Tests/AnglesiteCoreTests/NavigatorRenameServiceTests.swift
git commit -m "feat: NavigatorRenameService — load/rewrite/save/best-effort-commit title

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `SiteNavigatorModel` edit-state glue + `sourceDirectory` plumbing

**Files:**
- Modify: `Sources/AnglesiteApp/SiteNavigatorModel.swift`
- Modify: `Sources/AnglesiteApp/SiteWindow.swift:655` (the `navModel.start(...)` call)

**Interfaces:**
- Consumes: `NavigatorRenameService` (Task 2); `SiteContentGraph.page(id:)`/`post(id:)`, `upsertPage(_:)`/`upsertPost(_:)`; `NavigatorTarget` to classify a row.
- Produces (used by Task 4):
  ```swift
  // on SiteNavigatorModel
  var editingItemID: String?     // observable
  var draftTitle: String         // observable
  var renameError: String?       // observable; non-nil → view shows an alert
  func canRename(_ id: String) -> Bool
  func beginEditing(_ id: String)
  func cancelEditing()
  func commitEditing() async
  // start gains a sourceDirectory parameter:
  func start(siteID: String, siteRoot: URL, sourceDirectory: URL)
  ```

This is app-target glue (not under `swift test`); it is verified by the build in Step 4 and by Task 4's manual run.

- [ ] **Step 1: Add stored config + edit state to `SiteNavigatorModel`**

In `Sources/AnglesiteApp/SiteNavigatorModel.swift`, add stored properties after `var selection: String?`:

```swift
    // Inline re-titling (Finder-style). `editingItemID` non-nil → that row shows a TextField.
    var editingItemID: String?
    var draftTitle: String = ""
    var renameError: String?

    private var sourceDirectory: URL?
    private let renameService = NavigatorRenameService()
```

- [ ] **Step 2: Thread `sourceDirectory` through `start`**

Change the `start` signature and capture, storing `sourceDirectory`:

```swift
    func start(siteID: String, siteRoot: URL, sourceDirectory: URL) {
        self.sourceDirectory = sourceDirectory
        observeTask?.cancel()
        observeTask = Task { [weak self, graph, siteID, siteRoot] in
            let stream = await graph.changeStream()
            await self?.refresh(siteID: siteID, siteRoot: siteRoot)
            for await changedSiteID in stream {
                if Task.isCancelled { break }
                if changedSiteID == siteID { await self?.refresh(siteID: siteID, siteRoot: siteRoot) }
            }
        }
    }
```

(`refresh` is unchanged — `SiteFileTree.scan` still uses `siteRoot`/`packageURL`.)

- [ ] **Step 3: Add the edit-state methods**

Add these methods to `SiteNavigatorModel` (after `target(for:)`):

```swift
    /// A row is renamable iff it is a page or post (route target). File rows (components/styles/
    /// metadata) carry a `.file` target and are out of scope. The astro-without-title case is
    /// caught at commit, not pre-disabled (pre-checking would read every page file per refresh).
    func canRename(_ id: String) -> Bool {
        guard let target = target(for: id) else { return false }
        if case .route = target { return true }
        return false
    }

    func beginEditing(_ id: String) {
        guard canRename(id) else { return }
        let current = sections.flatMap(\.items).first { $0.id == id }?.title ?? ""
        draftTitle = current
        editingItemID = id
    }

    func cancelEditing() {
        editingItemID = nil
    }

    /// Resolve the editing row → page/post → file, run the rename service, then reflect the new
    /// title into the graph (which re-emits and rebuilds the sidebar). Always clears edit state.
    func commitEditing() async {
        guard let id = editingItemID, let sourceDirectory else { editingItemID = nil; return }
        editingItemID = nil

        if let page = await graph.page(id: id) {
            let url = sourceDirectory.appendingPathComponent(page.filePath)
            let result = await renameService.rename(
                fileURL: url,
                fileExtension: (page.filePath as NSString).pathExtension,
                projectRoot: sourceDirectory,
                relativePath: page.filePath,
                newTitle: draftTitle)
            switch result {
            case .success(let title):
                await graph.upsertPage(SiteContentGraph.Page(
                    id: page.id, siteID: page.siteID, route: page.route,
                    filePath: page.filePath, title: title, lastModified: page.lastModified))
            case .failure(.emptyTitle):
                break  // no write happened; keep the old title silently
            case .failure(.noEditableLocation):
                renameError = "This page has no editable title to rename."
            case .failure(.io(let msg)):
                renameError = "Couldn't rename: \(msg)"
            }
        } else if let post = await graph.post(id: id) {
            let url = sourceDirectory.appendingPathComponent(post.filePath)
            let result = await renameService.rename(
                fileURL: url,
                fileExtension: (post.filePath as NSString).pathExtension,
                projectRoot: sourceDirectory,
                relativePath: post.filePath,
                newTitle: draftTitle)
            switch result {
            case .success(let title):
                await graph.upsertPost(SiteContentGraph.Post(
                    id: post.id, siteID: post.siteID, collection: post.collection, slug: post.slug,
                    title: title, draft: post.draft, publishDate: post.publishDate, tags: post.tags,
                    filePath: post.filePath, lastModified: post.lastModified))
            case .failure(.emptyTitle):
                break
            case .failure(.noEditableLocation):
                renameError = "This post has no editable title to rename."
            case .failure(.io(let msg)):
                renameError = "Couldn't rename: \(msg)"
            }
        }
    }
```

- [ ] **Step 4: Update the `start` call site in `SiteWindow`**

In `Sources/AnglesiteApp/SiteWindow.swift` (~line 655), change:

```swift
        navModel.start(siteID: resolved.id, siteRoot: resolved.packageURL)
```

to:

```swift
        navModel.start(siteID: resolved.id, siteRoot: resolved.packageURL, sourceDirectory: resolved.sourceDirectory)
```

- [ ] **Step 5: Build the app target to verify it compiles**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`. (If `Anglesite.xcodeproj` is missing, run `xcodegen generate` first; if the build complains about `Resources/plugin`, run `scripts/copy-plugin.sh` with `ANGLESITE_PLUGIN_SRC` set to the real plugin checkout.)

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteApp/SiteNavigatorModel.swift Sources/AnglesiteApp/SiteWindow.swift
git commit -m "feat: navigator model rename glue + sourceDirectory plumbing

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: `SiteNavigatorView` inline editing UI

**Files:**
- Modify: `Sources/AnglesiteApp/SiteNavigatorView.swift`

**Interfaces:**
- Consumes: `model.editingItemID`, `model.draftTitle`, `model.renameError`, `model.canRename(_:)`, `model.beginEditing(_:)`, `model.cancelEditing()`, `model.commitEditing()` (Task 3).
- Produces: no new API (terminal UI task).

This is app-target UI, verified by build + manual run (hosted app tests don't run on CI).

- [ ] **Step 1: Render an inline `TextField` for the editing row, with a Rename context menu**

Replace the `ForEach(section.items)` row body in `Sources/AnglesiteApp/SiteNavigatorView.swift` so a row in edit mode shows a focused `TextField`, otherwise the existing `Label`. Add a `@FocusState` and bind `$model` so its observable edit state is writable:

```swift
struct SiteNavigatorView: View {
    @Bindable var model: SiteNavigatorModel
    @FocusState private var editingFocused: Bool

    var body: some View {
        List(selection: $model.selection) {
            ForEach(model.sections) { section in
                Section(section.title) {
                    ForEach(section.items) { item in
                        row(for: item, in: section)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.sections.isEmpty {
                ContentUnavailableView("No content yet", systemImage: "sidebar.left")
            }
        }
        .alert(
            "Rename failed",
            isPresented: Binding(
                get: { model.renameError != nil },
                set: { if !$0 { model.renameError = nil } }),
            presenting: model.renameError
        ) { _ in
            Button("OK", role: .cancel) { model.renameError = nil }
        } message: { msg in
            Text(msg)
        }
    }

    @ViewBuilder
    private func row(for item: NavigatorItem, in section: NavigatorSection) -> some View {
        if model.editingItemID == item.id {
            TextField("Title", text: $model.draftTitle)
                .textFieldStyle(.plain)
                .focused($editingFocused)
                .onSubmit { Task { await model.commitEditing() } }
                .onExitCommand { model.cancelEditing() }   // Esc
                .onChange(of: editingFocused) { _, focused in
                    // Clicking away ends editing without committing.
                    if !focused && model.editingItemID == item.id { model.cancelEditing() }
                }
                .task { editingFocused = true }
                .tag(item.id)
        } else {
            Label(item.title, systemImage: icon(for: section.id))
                .tag(item.id)
                .lineLimit(1)
                .truncationMode(.middle)
                .contextMenu {
                    if model.canRename(item.id) {
                        Button("Rename") { model.beginEditing(item.id) }
                    }
                }
        }
    }
```

(Leave the `icon(for:)` helper unchanged.)

- [ ] **Step 2: Add a Return-key path to begin renaming the selected row**

Add a hidden keyboard shortcut button to the `List` (inside `body`, e.g. as a `.background`) so pressing Return on the selected renamable row starts editing:

```swift
        .background {
            Button("") {
                if let id = model.selection, model.editingItemID == nil, model.canRename(id) {
                    model.beginEditing(id)
                }
            }
            .keyboardShortcut(.return, modifiers: [])
            .hidden()
        }
```

- [ ] **Step 3: Build the app target to verify it compiles**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Manual smoke test (document the result)**

Launch the app, open a site, and verify in the navigator:
1. Control-click a Page → **Rename** appears → click it → the row becomes an editable field pre-filled with the title.
2. Type a new title, press Return → the row shows the new title; open the `.astro` file and confirm the `title="…"` attribute changed and the file path/URL did not.
3. Repeat for a Post (`.md`) → confirm frontmatter `title:` changed.
4. Press Esc mid-edit → the original title is restored, nothing written.
5. Select a Page and press Return → editing begins (keyboard path).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/SiteNavigatorView.swift
git commit -m "feat: inline page/post rename in the project navigator

Control-click → Rename (or Return on the selected row) edits the title in place,
Finder-style; commit on Return, cancel on Esc.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- Title-only, write-where-it-lives → Task 1 (`PageTitleEditor`: frontmatter vs `title=` attribute). ✓
- Inline edit in place (control-click + Return, commit/cancel) → Task 4. ✓
- File path/URL unchanged → guaranteed: no task touches the path; `PageTitleEditor` only edits the title text. ✓
- Astro-no-attr → `.noEditableLocation` → alert at commit (Tasks 1, 3, 4). ✓
- Best-effort git commit → Task 2. ✓
- `NavigatorRenameService` testable in Core; model glue thin → Tasks 2, 3. ✓
- `sourceDirectory` plumbing (filePath is source-relative, `start` got `packageURL`) → Task 3. ✓
- Scope: pages/posts only (`canRename` = `.route` target) → Task 3. ✓
- Testing matrix (markdown replace/insert/synthesize, astro single/double/none, html, escaping, empty; service success/empty/no-location/io/git-best-effort) → Tasks 1, 2. ✓

**Placeholder scan:** No TBD/TODO; every code step shows full code; commands have expected output. ✓

**Type consistency:** `PageTitleEditor.RewriteError` (`.emptyTitle`/`.noEditableLocation`) is mapped explicitly in `NavigatorRenameService` to `RenameError` (adds `.io`). `start(siteID:siteRoot:sourceDirectory:)` defined in Task 3 Step 2, called in Task 3 Step 4. `SiteContentGraph.Page`/`Post` initializer argument lists match `SiteContentGraph.swift`. `NativeContentOperations.GitCommit` signature matches. ✓
