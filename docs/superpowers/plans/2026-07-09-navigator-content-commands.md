# Navigator Content Commands Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Delete Page/Post, Duplicate Page/Post, New Post…, and New Component… to the Site Navigator's context menu and the app's menu bar (Edit menu for Delete/Duplicate, File ▸ New for Post…/Component…).

**Architecture:** Extend `AnglesiteCore/NativeContentOperations` with four new operations (`deleteContent`, `duplicatePage`, `duplicatePost`, `createComponent`), each following the existing validate → mutate filesystem → `gitCommit`/`gitDelete` shape `createPage`/`createPost` already use. Wrap them in `ContentCreationWorkflow` so they get the same post-mutation `SiteContentGraph` rescan as every existing create. Wire them into `SiteWindowModel`/`SiteNavigatorModel` (gating, confirmation, editor/inspector-discard-before-delete — mirroring the existing `ProjectCleanupModel`/`deleteCleanupCandidate` precedent) and expose them through the navigator's context menu, the Edit menu (Delete/Duplicate), and File ▸ New (Post…/Component…).

**Tech Stack:** Swift 6.4, SwiftUI, Swift Testing (`@Suite`/`@Test`), `swift test --package-path .`.

**Spec:** [`docs/superpowers/specs/2026-07-09-navigator-content-commands-design.md`](../specs/2026-07-09-navigator-content-commands-design.md)

## Global Constraints

- Every mutation self-commits immediately via `git` (no "let Backup commit" — see spec's "Existing precedent" section). Delete reuses the existing `NativeContentOperations.processGitDelete` (`git rm` + commit) — **no `FileManager.trashItem`/Trash involved.**
- Delete/Duplicate apply only to pages and posts (`.route` navigator targets) — not components/styles/metadata. This matches `SiteNavigatorModel.canRename`'s existing gating exactly.
- New Component… scaffolds a minimal blank `.astro` file; no semantic editing (that's epic #496, out of scope).
- All new `AnglesiteCore` code must be covered by Swift Testing suites in `Tests/AnglesiteCoreTests`. `SiteWindowModel`/`SiteNavigatorModel` additions are covered in `Tests/AnglesiteAppTests` (target `AnglesiteAppCore`, per `Package.swift:152-163`) — mirror `ProjectCleanupModelTests.swift`/`SiteWindowModelTests.swift`'s existing patterns.
- Run `swift test --package-path .` after every task. Run a full `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build` after the SwiftUI-facing tasks (8–11), since `swift test` alone doesn't prove the `.app` links (per project convention).
- Commit after every task.

---

### Task 1: `ContentDeleteResult` + `NativeContentOperations.deleteContent`

**Files:**
- Modify: `Sources/AnglesiteCore/ContentOperationsService.swift` (add `ContentDeleteResult` enum, after `ContentCreateResult`, line 39)
- Modify: `Sources/AnglesiteCore/NativeContentOperations.swift` (add `gitDelete` stored property + init param, add `deleteContent` method)
- Test: `Tests/AnglesiteCoreTests/NativeContentOperationsTests.swift` (create if it doesn't already exist — check first with `ls Tests/AnglesiteCoreTests/ | grep -i nativecontent`; if a file already covers `createPage`/`createPost`, add to it instead)

**Interfaces:**
- Produces: `public enum ContentDeleteResult: Sendable, Equatable { case deleted(filePath: String); case siteNotFound; case failed(reason: String) }`
- Produces: `NativeContentOperations.deleteContent(siteID: String, relativePath: String) async -> ContentDeleteResult`
- Consumes: `NativeContentOperations.GitDelete` (already declared, `NativeContentOperations.swift:11`), `NativeContentOperations.processGitDelete` (already implemented, `NativeContentOperations.swift:239-278`)

- [ ] **Step 1: Confirm the target test file**

`Tests/AnglesiteCoreTests/NativeContentOperationsTests.swift` already exists (covers `createPage`/`createPost`/`createTyped`). Append the new suite below to the bottom of that file — it already has the `import Testing`, `import Foundation`, `@testable import AnglesiteCore` header, so the new `@Suite` struct below doesn't repeat them.

- [ ] **Step 2: Write the failing test**

```swift
@Suite("NativeContentOperations.deleteContent")
struct NativeContentOperationsDeleteTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-content-ops-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("deletes an existing file via the injected gitDelete closure")
    func deletesExistingFile() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let relPath = "src/pages/about.astro"
        let abs = root.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: abs.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("stub".utf8).write(to: abs)

        var deletedArgs: (URL, String, String)?
        let ops = NativeContentOperations(
            siteDirectory: { _ in root },
            gitDelete: { projectRoot, path, message in
                deletedArgs = (projectRoot, path, message)
                return "deadbeef"
            }
        )

        let result = await ops.deleteContent(siteID: "site-1", relativePath: relPath)

        #expect(result == .deleted(filePath: relPath))
        #expect(deletedArgs?.0 == root)
        #expect(deletedArgs?.1 == relPath)
    }

    @Test("fails when the file does not exist")
    func failsWhenMissing() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ops = NativeContentOperations(
            siteDirectory: { _ in root },
            gitDelete: { _, _, _ in "deadbeef" }
        )

        let result = await ops.deleteContent(siteID: "site-1", relativePath: "src/pages/missing.astro")

        guard case .failed = result else { Issue.record("expected .failed, got \(result)"); return }
    }

    @Test("fails when gitDelete refuses (dirty tree, no HEAD copy, etc.)")
    func failsWhenGitDeleteRefuses() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let relPath = "src/pages/about.astro"
        let abs = root.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: abs.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("stub".utf8).write(to: abs)
        let ops = NativeContentOperations(
            siteDirectory: { _ in root },
            gitDelete: { _, _, _ in nil }
        )

        let result = await ops.deleteContent(siteID: "site-1", relativePath: relPath)

        guard case .failed = result else { Issue.record("expected .failed, got \(result)"); return }
    }

    @Test("reports siteNotFound when siteDirectory resolves nil")
    func siteNotFound() async {
        let ops = NativeContentOperations(
            siteDirectory: { _ in nil },
            gitDelete: { _, _, _ in "deadbeef" }
        )

        let result = await ops.deleteContent(siteID: "missing-site", relativePath: "src/pages/about.astro")

        #expect(result == .siteNotFound)
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test --package-path . --filter NativeContentOperationsDeleteTests`
Expected: FAIL to compile — `ContentDeleteResult` and `deleteContent` don't exist yet, and `NativeContentOperations.init` has no `gitDelete` parameter.

- [ ] **Step 4: Add `ContentDeleteResult` to `ContentOperationsService.swift`**

Insert after the existing `ContentCreateResult` enum (after line 39 — the closing `}` of that enum):

```swift
/// Outcome of a `delete_content` call.
public enum ContentDeleteResult: Sendable, Equatable {
    case deleted(filePath: String)
    /// The site id didn't resolve to a known site directory.
    case siteNotFound
    /// The file didn't exist, or the git delete+commit failed (dirty tree, no HEAD copy,
    /// rejecting hook, git missing).
    case failed(reason: String)
}
```

- [ ] **Step 5: Add `gitDelete` to `NativeContentOperations`**

In `Sources/AnglesiteCore/NativeContentOperations.swift`, add a stored property next to `gitCommit` (after line 14):

```swift
    private let gitCommit: GitCommit
    private let gitDelete: GitDelete
```

Add the init parameter (after the existing `gitCommit` param, in the `init` starting at line 22):

```swift
    public init(
        siteDirectory: @escaping @Sendable (_ siteID: String) async -> URL?,
        gitCommit: @escaping GitCommit = NativeContentOperations.processGitCommit,
        gitDelete: @escaping GitDelete = NativeContentOperations.processGitDelete,
        now: @escaping @Sendable () -> Date = { Date() },
        copyGenerator: any PageCopyGenerating = NoopPageCopyGenerator(),
        fileManager: FileManager = .default
    ) {
        self.siteDirectory = siteDirectory
        self.gitCommit = gitCommit
        self.gitDelete = gitDelete
        self.now = now
        self.copyGenerator = copyGenerator
        self.fileManager = fileManager
    }
```

- [ ] **Step 6: Add `deleteContent` to `NativeContentOperations`**

Insert after `createTypedSingleton` (after line 210, before the `private func write` helper):

```swift
    /// Delete a page/post/component file: `git rm` + commit via the injected `gitDelete` closure
    /// (default `processGitDelete`). No Trash involved — git history is the sole undo mechanism,
    /// matching `ProjectCleanupModel.delete`'s existing precedent for dead-asset deletion.
    public func deleteContent(siteID: String, relativePath: String) async -> ContentDeleteResult {
        guard let root = await siteDirectory(siteID) else { return .siteNotFound }
        let abs = root.appendingPathComponent(relativePath)
        guard fileManager.fileExists(atPath: abs.path) else {
            return .failed(reason: "No file exists at \(relativePath)")
        }
        guard await gitDelete(root, relativePath, "anglesite: delete \(relativePath)") != nil else {
            return .failed(reason: "Couldn't delete \(relativePath). Check for uncommitted changes and try again.")
        }
        return .deleted(filePath: relativePath)
    }
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `swift test --package-path . --filter NativeContentOperationsDeleteTests`
Expected: PASS (4 tests)

- [ ] **Step 8: Run the full AnglesiteCoreTests suite to check for regressions**

Run: `swift test --package-path . --filter AnglesiteCoreTests`
Expected: PASS (existing `createPage`/`createPost`/`createTyped` tests unaffected — `gitDelete` has a default value, so no existing call site breaks)

- [ ] **Step 9: Commit**

```bash
git add Sources/AnglesiteCore/ContentOperationsService.swift Sources/AnglesiteCore/NativeContentOperations.swift Tests/AnglesiteCoreTests/NativeContentOperationsTests.swift
git commit -m "feat(core): add NativeContentOperations.deleteContent (#516)"
```

---

### Task 2: `NativeContentOperations.duplicatePage` / `duplicatePost`

**Files:**
- Modify: `Sources/AnglesiteCore/NativeContentOperations.swift`
- Test: `Tests/AnglesiteCoreTests/NativeContentOperationsTests.swift` (same file as Task 1)

**Interfaces:**
- Consumes: `ContentScaffold.slugify(_:)`, `ContentScaffold.normalizeRoute(_:)`, `ContentScaffold.pageRelativePath(normalizedRoute:)`, `ContentScaffold.postRelativePath(collection:slug:)` (all `Sources/AnglesiteCore/ContentScaffold.swift`), `PageTitleEditor.rewrite(contents:fileExtension:newTitle:)` (`Sources/AnglesiteCore/PageTitleEditor.swift:18`), `FileDocumentIO.load(_:fileManager:)` (`Sources/AnglesiteCore/FileDocumentIO.swift:21`)
- Produces: `NativeContentOperations.duplicatePage(siteID: String, relativePath: String, title: String) async -> ContentCreateResult`
- Produces: `NativeContentOperations.duplicatePost(siteID: String, relativePath: String, collection: String, title: String) async -> ContentCreateResult`

- [ ] **Step 1: Write the failing tests**

Add to `Tests/AnglesiteCoreTests/NativeContentOperationsTests.swift`:

```swift
@Suite("NativeContentOperations.duplicatePage/duplicatePost")
struct NativeContentOperationsDuplicateTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-content-ops-dup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("duplicatePage writes a -copy suffixed file with the retitled contents")
    func duplicatesPage() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let relPath = "src/pages/about.astro"
        let abs = root.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: abs.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = ContentScaffold.renderPage(title: "About", layoutImport: "../layouts/BaseLayout.astro")
        try original.write(to: abs, atomically: true, encoding: .utf8)

        let ops = NativeContentOperations(
            siteDirectory: { _ in root },
            gitCommit: { _, _, _ in "deadbeef" }
        )

        let result = await ops.duplicatePage(siteID: "site-1", relativePath: relPath, title: "About")

        guard case .created(let filePath, let identifier) = result else {
            Issue.record("expected .created, got \(result)"); return
        }
        #expect(filePath == "src/pages/about-copy.astro")
        #expect(identifier == "/about-copy")
        let copied = try String(contentsOf: root.appendingPathComponent(filePath), encoding: .utf8)
        #expect(copied.contains("title=\"About Copy\""))
    }

    @Test("duplicatePage bumps the suffix on collision")
    func duplicatesPageWithCollision() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let relPath = "src/pages/about.astro"
        let abs = root.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: abs.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ContentScaffold.renderPage(title: "About", layoutImport: "../layouts/BaseLayout.astro")
            .write(to: abs, atomically: true, encoding: .utf8)
        try ContentScaffold.renderPage(title: "About Copy", layoutImport: "../layouts/BaseLayout.astro")
            .write(to: root.appendingPathComponent("src/pages/about-copy.astro"), atomically: true, encoding: .utf8)

        let ops = NativeContentOperations(
            siteDirectory: { _ in root },
            gitCommit: { _, _, _ in "deadbeef" }
        )

        let result = await ops.duplicatePage(siteID: "site-1", relativePath: relPath, title: "About")

        guard case .created(let filePath, _) = result else { Issue.record("expected .created, got \(result)"); return }
        #expect(filePath == "src/pages/about-copy-2.astro")
    }

    @Test("duplicatePost writes into the same collection with a -copy slug")
    func duplicatesPost() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let relPath = "src/content/posts/hello-world.md"
        let abs = root.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: abs.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ContentScaffold.renderPost(title: "Hello World", now: Date(timeIntervalSince1970: 0))
            .write(to: abs, atomically: true, encoding: .utf8)

        let ops = NativeContentOperations(
            siteDirectory: { _ in root },
            gitCommit: { _, _, _ in "deadbeef" }
        )

        let result = await ops.duplicatePost(siteID: "site-1", relativePath: relPath, collection: "posts", title: "Hello World")

        guard case .created(let filePath, let identifier) = result else {
            Issue.record("expected .created, got \(result)"); return
        }
        #expect(filePath == "src/content/posts/hello-world-copy.md")
        #expect(identifier == "hello-world-copy")
        let copied = try String(contentsOf: root.appendingPathComponent(filePath), encoding: .utf8)
        #expect(copied.contains("title: \"Hello World Copy\""))
    }

    @Test("duplicatePage fails when the source file does not exist")
    func duplicateMissingSourceFails() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ops = NativeContentOperations(siteDirectory: { _ in root })

        let result = await ops.duplicatePage(siteID: "site-1", relativePath: "src/pages/missing.astro", title: "Missing")

        guard case .failed = result else { Issue.record("expected .failed, got \(result)"); return }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path . --filter NativeContentOperationsDuplicateTests`
Expected: FAIL to compile — `duplicatePage`/`duplicatePost` don't exist yet.

- [ ] **Step 3: Implement `duplicatePage` and `duplicatePost`**

Insert into `Sources/AnglesiteCore/NativeContentOperations.swift`, after `deleteContent` (added in Task 1):

```swift
    /// Duplicate an existing page: read its contents, retitle to `"<title> Copy"` (bumping to
    /// `"<title> Copy 2"`, `"<title> Copy 3"`… on route collision — which slugifies to the
    /// `-copy`/`-copy-2` file-name convention), write the new file, commit. Title rewrite reuses
    /// `PageTitleEditor` (same transform `NavigatorRenameService` uses for Rename); if the source
    /// has no editable title location, the contents are duplicated verbatim.
    public func duplicatePage(siteID: String, relativePath: String, title: String) async -> ContentCreateResult {
        guard let root = await siteDirectory(siteID) else { return .siteNotFound }
        let sourceAbs = root.appendingPathComponent(relativePath)
        guard fileManager.fileExists(atPath: sourceAbs.path) else {
            return .failed(reason: "No page exists at \(relativePath)")
        }
        let contents: String
        do { contents = try FileDocumentIO.load(sourceAbs, fileManager: fileManager).contents }
        catch { return .failed(reason: "\(error)") }

        let baseTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let copyTitle = baseTitle.isEmpty ? "Copy" : "\(baseTitle) Copy"
        var attempt = 1
        var route = ContentScaffold.normalizeRoute(ContentScaffold.slugify(copyTitle))
        var relPath = ContentScaffold.pageRelativePath(normalizedRoute: route)
        while attempt < 1000, fileManager.fileExists(atPath: root.appendingPathComponent(relPath).path) {
            attempt += 1
            route = ContentScaffold.normalizeRoute(ContentScaffold.slugify("\(copyTitle) \(attempt)"))
            relPath = ContentScaffold.pageRelativePath(normalizedRoute: route)
        }

        let ext = (relativePath as NSString).pathExtension
        let rewritten: String
        switch PageTitleEditor.rewrite(contents: contents, fileExtension: ext, newTitle: copyTitle) {
        case .success(let s): rewritten = s
        case .failure: rewritten = contents
        }

        do { try write(rewritten, to: root.appendingPathComponent(relPath)) }
        catch { return .failed(reason: "\(error)") }

        _ = await gitCommit(root, relPath, "anglesite: duplicate page \(route)")
        return .created(filePath: relPath, identifier: route)
    }

    /// Duplicate an existing post within the same `collection`. Same retitle/collision/commit
    /// shape as `duplicatePage`, but derives a slug (not a route) and writes via
    /// `ContentScaffold.postRelativePath`.
    public func duplicatePost(siteID: String, relativePath: String, collection: String, title: String) async -> ContentCreateResult {
        guard let root = await siteDirectory(siteID) else { return .siteNotFound }
        let sourceAbs = root.appendingPathComponent(relativePath)
        guard fileManager.fileExists(atPath: sourceAbs.path) else {
            return .failed(reason: "No \(collection) entry exists at \(relativePath)")
        }
        let contents: String
        do { contents = try FileDocumentIO.load(sourceAbs, fileManager: fileManager).contents }
        catch { return .failed(reason: "\(error)") }

        let baseTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let copyTitle = baseTitle.isEmpty ? "Copy" : "\(baseTitle) Copy"
        var attempt = 1
        var slug = ContentScaffold.slugify(copyTitle)
        var relPath = ContentScaffold.postRelativePath(collection: collection, slug: slug)
        while attempt < 1000, fileManager.fileExists(atPath: root.appendingPathComponent(relPath).path) {
            attempt += 1
            slug = ContentScaffold.slugify("\(copyTitle) \(attempt)")
            relPath = ContentScaffold.postRelativePath(collection: collection, slug: slug)
        }

        let ext = (relativePath as NSString).pathExtension
        let rewritten: String
        switch PageTitleEditor.rewrite(contents: contents, fileExtension: ext, newTitle: copyTitle) {
        case .success(let s): rewritten = s
        case .failure: rewritten = contents
        }

        do { try write(rewritten, to: root.appendingPathComponent(relPath)) }
        catch { return .failed(reason: "\(error)") }

        _ = await gitCommit(root, relPath, "anglesite: duplicate \(collection) \(slug)")
        return .created(filePath: relPath, identifier: slug)
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path . --filter NativeContentOperationsDuplicateTests`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/NativeContentOperations.swift Tests/AnglesiteCoreTests/NativeContentOperationsTests.swift
git commit -m "feat(core): add NativeContentOperations.duplicatePage/duplicatePost (#516)"
```

---

### Task 3: `ContentScaffold.renderComponent` + `NativeContentOperations.createComponent`

**Files:**
- Modify: `Sources/AnglesiteCore/ContentScaffold.swift`
- Modify: `Sources/AnglesiteCore/NativeContentOperations.swift`
- Test: `Tests/AnglesiteCoreTests/ContentScaffoldTests.swift` (check with `ls Tests/AnglesiteCoreTests/ | grep -i contentscaffold`; add to it if it exists) and `Tests/AnglesiteCoreTests/NativeContentOperationsTests.swift`

**Interfaces:**
- Produces: `ContentScaffold.renderComponent(name: String) -> String` (pure)
- Produces: `NativeContentOperations.createComponent(siteID: String, name: String) async -> ContentCreateResult`

- [ ] **Step 1: Write the failing tests**

`Tests/AnglesiteCoreTests/ContentScaffoldTests.swift` already exists with `@Suite("ContentScaffold") struct ContentScaffoldTests { ... }`. Add this `@Test` method inside that existing struct (alongside its existing `slugifyBasics` test etc.):

```swift
@Test("renderComponent produces a minimal blank .astro component")
func renderComponentIsMinimal() {
    let rendered = ContentScaffold.renderComponent(name: "MyWidget")
    #expect(rendered.contains("MyWidget"))
    #expect(rendered.hasPrefix("---"))
}
```

Add to `Tests/AnglesiteCoreTests/NativeContentOperationsTests.swift`:

```swift
@Suite("NativeContentOperations.createComponent")
struct NativeContentOperationsComponentTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-content-ops-component-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("creates a PascalCase-named blank component")
    func createsComponent() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ops = NativeContentOperations(siteDirectory: { _ in root }, gitCommit: { _, _, _ in "deadbeef" })

        let result = await ops.createComponent(siteID: "site-1", name: "call to action")

        guard case .created(let filePath, let identifier) = result else {
            Issue.record("expected .created, got \(result)"); return
        }
        #expect(filePath == "src/components/CallToAction.astro")
        #expect(identifier == "CallToAction")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(filePath).path))
    }

    @Test("fails when a component already exists at that path")
    func failsOnCollision() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("src/components/CallToAction.astro")
        try FileManager.default.createDirectory(at: existing.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("stub".utf8).write(to: existing)
        let ops = NativeContentOperations(siteDirectory: { _ in root })

        let result = await ops.createComponent(siteID: "site-1", name: "Call To Action")

        guard case .failed = result else { Issue.record("expected .failed, got \(result)"); return }
    }

    @Test("fails on an empty name")
    func failsOnEmptyName() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ops = NativeContentOperations(siteDirectory: { _ in root })

        let result = await ops.createComponent(siteID: "site-1", name: "   ")

        guard case .failed = result else { Issue.record("expected .failed, got \(result)"); return }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path . --filter "renderComponentIsMinimal|NativeContentOperationsComponentTests"`
Expected: FAIL to compile — `renderComponent`/`createComponent` don't exist yet.

- [ ] **Step 3: Implement `ContentScaffold.renderComponent`**

Insert into `Sources/AnglesiteCore/ContentScaffold.swift`, after `renderSingleton` (after line 203, before the `// MARK: - Escaping` comment):

```swift
    /// A minimal blank `.astro` component scaffold (V-1 of New Component…, #516). No props, no
    /// markup beyond a placeholder — semantic authoring arrives with the Component Editor (#496).
    public static func renderComponent(name: String) -> String {
        """
        ---
        export interface Props {}
        ---

        <div>
          <!-- \(escapeHTML(name)) -->
        </div>
        """ + "\n"
    }
```

- [ ] **Step 4: Implement `NativeContentOperations.createComponent`**

Insert into `Sources/AnglesiteCore/NativeContentOperations.swift`, after `duplicatePost` (added in Task 2):

```swift
    /// Scaffold a minimal blank `.astro` component into `src/components/`. Derives a PascalCase
    /// file name from `name` (Astro convention) via the same `ContentScaffold.slugify` used for
    /// pages/posts, then title-cases each hyphenated segment.
    public func createComponent(siteID: String, name: String) async -> ContentCreateResult {
        guard let root = await siteDirectory(siteID) else { return .siteNotFound }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return .failed(reason: "New Component requires a non-empty name") }

        let slug = ContentScaffold.slugify(cleanName)
        guard !slug.isEmpty else { return .failed(reason: "Couldn't derive a file name from \"\(cleanName)\"") }
        let fileName = slug.split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined()

        let relPath = "src/components/\(fileName).astro"
        let abs = root.appendingPathComponent(relPath)
        if fileManager.fileExists(atPath: abs.path) {
            return .failed(reason: "A component already exists at \(relPath)")
        }

        let contents = ContentScaffold.renderComponent(name: fileName)
        do { try write(contents, to: abs) }
        catch { return .failed(reason: "\(error)") }

        _ = await gitCommit(root, relPath, "anglesite: add component \(fileName)")
        return .created(filePath: relPath, identifier: fileName)
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path . --filter "renderComponentIsMinimal|NativeContentOperationsComponentTests"`
Expected: PASS (4 tests)

- [ ] **Step 6: Run the full AnglesiteCoreTests suite**

Run: `swift test --package-path . --filter AnglesiteCoreTests`
Expected: PASS, no regressions

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteCore/ContentScaffold.swift Sources/AnglesiteCore/NativeContentOperations.swift Tests/AnglesiteCoreTests/ContentScaffoldTests.swift Tests/AnglesiteCoreTests/NativeContentOperationsTests.swift
git commit -m "feat(core): add ContentScaffold.renderComponent + NativeContentOperations.createComponent (#516)"
```

---

### Task 4: Wire the four operations into `ContentCreationWorkflow`

**Files:**
- Modify: `Sources/AnglesiteCore/ContentCreationWorkflow.swift`
- Test: `Tests/AnglesiteCoreTests/ContentCreationWorkflowTests.swift`

**Interfaces:**
- Consumes: `NativeContentOperations.deleteContent`/`duplicatePage`/`duplicatePost`/`createComponent` (Tasks 1–3), `ContentDeleteResult` (Task 1)
- Produces: `ContentCreationWorkflow.deleteContent(siteID: String, relativePath: String) async -> ContentDeleteResult`
- Produces: `ContentCreationWorkflow.duplicatePage(siteID: String, relativePath: String, title: String) async -> ContentCreateResult`
- Produces: `ContentCreationWorkflow.duplicatePost(siteID: String, relativePath: String, collection: String, title: String) async -> ContentCreateResult`
- Produces: `ContentCreationWorkflow.createComponent(siteID: String, name: String) async -> ContentCreateResult`

This task also refactors `refreshContentGraphIfCreated` to extract a shared `refreshContentGraph(siteID:)` helper, reused by the new `deleteContent` method (which needs an unconditional rescan-on-success, unlike the create paths which are gated on `.created`). This is a same-behavior refactor — Step 1's failing test locks in that the existing create-refresh behavior doesn't regress, before Step 3 touches it.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/AnglesiteCoreTests/ContentCreationWorkflowTests.swift` (mirror the existing `FakeCreateOperations` helper already in that file — check its definition near the bottom of the file with `grep -n "FakeCreateOperations" Tests/AnglesiteCoreTests/ContentCreationWorkflowTests.swift` and reuse the same `operations:` param in these tests):

```swift
@Test("successful delete reloads content graph so the deleted page is gone")
func deleteContentRefreshesGraph() async throws {
    let root = try makeSite([
        "src/pages/about.astro": ContentScaffold.renderPage(title: "About", layoutImport: "../layouts/BaseLayout.astro"),
    ])
    let graph = SiteContentGraph()
    await graph.load(
        siteID: Self.siteID,
        pages: ContentScanner.scan(projectRoot: root, siteID: Self.siteID).pages,
        posts: [],
        images: []
    )
    #expect(await graph.pages(for: Self.siteID).count == 1)
    try FileManager.default.removeItem(at: root.appendingPathComponent("src/pages/about.astro"))

    let operations = FakeCreateOperations { _, _, _ in .failed(reason: "unexpected") }
        createPost: { _, _, _, _ in .failed(reason: "unexpected") }
        createTyped: { _, _, _, _ in .failed(reason: "unexpected") }
    let workflow = ContentCreationWorkflow(
        operations: operations,
        contentGraph: graph,
        siteDirectory: { _ in root },
        contentDeleter: { _, relPath in .deleted(filePath: relPath) }
    )

    let result = await workflow.deleteContent(siteID: Self.siteID, relativePath: "src/pages/about.astro")

    #expect(result == .deleted(filePath: "src/pages/about.astro"))
    #expect(await graph.pages(for: Self.siteID).isEmpty)
}

@Test("failed delete leaves content graph unchanged")
func failedDeleteDoesNotRefreshGraph() async throws {
    let root = try makeSite([
        "src/pages/about.astro": ContentScaffold.renderPage(title: "About", layoutImport: "../layouts/BaseLayout.astro"),
    ])
    let graph = SiteContentGraph()
    await graph.load(
        siteID: Self.siteID,
        pages: ContentScanner.scan(projectRoot: root, siteID: Self.siteID).pages,
        posts: [],
        images: []
    )
    let operations = FakeCreateOperations { _, _, _ in .failed(reason: "unexpected") }
        createPost: { _, _, _, _ in .failed(reason: "unexpected") }
        createTyped: { _, _, _, _ in .failed(reason: "unexpected") }
    let workflow = ContentCreationWorkflow(
        operations: operations,
        contentGraph: graph,
        siteDirectory: { _ in root },
        contentDeleter: { _, _ in .failed(reason: "dirty tree") }
    )

    let result = await workflow.deleteContent(siteID: Self.siteID, relativePath: "src/pages/about.astro")

    guard case .failed = result else { Issue.record("expected .failed, got \(result)"); return }
    #expect(await graph.pages(for: Self.siteID).count == 1)
}

@Test("duplicatePage reloads content graph with the new page")
func duplicatePageRefreshesGraph() async throws {
    let root = try makeSite()
    let graph = SiteContentGraph()
    let operations = FakeCreateOperations { _, _, _ in .failed(reason: "unexpected") }
        createPost: { _, _, _, _ in .failed(reason: "unexpected") }
        createTyped: { _, _, _, _ in .failed(reason: "unexpected") }
    let workflow = ContentCreationWorkflow(
        operations: operations,
        contentGraph: graph,
        siteDirectory: { _ in root },
        pageDuplicator: { _, _, _ in
            let relPath = "src/pages/about-copy.astro"
            let url = root.appendingPathComponent(relPath)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? ContentScaffold.renderPage(title: "About Copy", layoutImport: "../layouts/BaseLayout.astro")
                .write(to: url, atomically: true, encoding: .utf8)
            return .created(filePath: relPath, identifier: "/about-copy")
        }
    )

    let result = await workflow.duplicatePage(siteID: Self.siteID, relativePath: "src/pages/about.astro", title: "About")

    #expect(result == .created(filePath: "src/pages/about-copy.astro", identifier: "/about-copy"))
    #expect(await graph.pages(for: Self.siteID).map(\.route) == ["/about-copy"])
}

@Test("createComponent does not require content graph access and returns the operation's result")
func createComponentPassesThrough() async throws {
    let root = try makeSite()
    let operations = FakeCreateOperations { _, _, _ in .failed(reason: "unexpected") }
        createPost: { _, _, _, _ in .failed(reason: "unexpected") }
        createTyped: { _, _, _, _ in .failed(reason: "unexpected") }
    let workflow = ContentCreationWorkflow(
        operations: operations,
        contentGraph: nil,
        siteDirectory: { _ in root },
        componentCreator: { _, name in .created(filePath: "src/components/\(name).astro", identifier: name) }
    )

    let result = await workflow.createComponent(siteID: Self.siteID, name: "Widget")

    #expect(result == .created(filePath: "src/components/Widget.astro", identifier: "Widget"))
}

@Test("deleteContent reports failed when the workflow has no contentDeleter configured")
func deleteContentUnconfigured() async throws {
    let root = try makeSite()
    let operations = FakeCreateOperations { _, _, _ in .failed(reason: "unexpected") }
        createPost: { _, _, _, _ in .failed(reason: "unexpected") }
        createTyped: { _, _, _, _ in .failed(reason: "unexpected") }
    let workflow = ContentCreationWorkflow(operations: operations, contentGraph: nil, siteDirectory: { _ in root })

    let result = await workflow.deleteContent(siteID: Self.siteID, relativePath: "src/pages/about.astro")

    guard case .failed = result else { Issue.record("expected .failed, got \(result)"); return }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path . --filter ContentCreationWorkflowTests`
Expected: FAIL to compile — `ContentCreationWorkflow.init` has no `contentDeleter`/`pageDuplicator`/`componentCreator` params, and `deleteContent`/`duplicatePage`/`createComponent` don't exist on it.

- [ ] **Step 3: Refactor `refreshContentGraphIfCreated` and add the new closures + methods**

In `Sources/AnglesiteCore/ContentCreationWorkflow.swift`, add four new typealiases after `TypedSlugCreator` (after line 24):

```swift
    public typealias ContentDeleter = @Sendable (_ siteID: String, _ relativePath: String) async -> ContentDeleteResult
    public typealias PageDuplicator = @Sendable (_ siteID: String, _ relativePath: String, _ title: String) async -> ContentCreateResult
    public typealias PostDuplicator = @Sendable (_ siteID: String, _ relativePath: String, _ collection: String, _ title: String) async -> ContentCreateResult
    public typealias ComponentCreator = @Sendable (_ siteID: String, _ name: String) async -> ContentCreateResult
```

Add four stored properties after `typedSlugCreator` (after line 31):

```swift
    private let contentDeleter: ContentDeleter?
    private let pageDuplicator: PageDuplicator?
    private let postDuplicator: PostDuplicator?
    private let componentCreator: ComponentCreator?
```

Replace the `init` (lines 33–47) with:

```swift
    public init(
        operations: any ContentOperationsService,
        contentGraph: SiteContentGraph?,
        knowledgeIndex: SiteKnowledgeIndex? = nil,
        siteDirectory: @escaping SiteDirectoryResolver,
        pageTemplateCreator: PageTemplateCreator? = nil,
        typedSlugCreator: TypedSlugCreator? = nil,
        contentDeleter: ContentDeleter? = nil,
        pageDuplicator: PageDuplicator? = nil,
        postDuplicator: PostDuplicator? = nil,
        componentCreator: ComponentCreator? = nil
    ) {
        self.operations = operations
        self.contentGraph = contentGraph
        self.knowledgeIndex = knowledgeIndex
        self.siteDirectory = siteDirectory
        self.pageTemplateCreator = pageTemplateCreator
        self.typedSlugCreator = typedSlugCreator
        self.contentDeleter = contentDeleter
        self.pageDuplicator = pageDuplicator
        self.postDuplicator = postDuplicator
        self.componentCreator = componentCreator
    }
```

Replace `refreshContentGraphIfCreated` (lines 179–195) with:

```swift
    private func refreshContentGraphIfCreated(_ result: ContentCreateResult, siteID: String) async {
        guard case let .created(filePath, _) = result else { return }
        await refreshContentGraph(siteID: siteID, indexFilePath: filePath)
    }

    /// Rescan and publish the site's content graph. Shared by every successful create *and*
    /// `deleteContent` — a delete has no `filePath` to index (nothing to add to the knowledge
    /// index for a file that's gone), so `indexFilePath` is optional and only creates pass it.
    private func refreshContentGraph(siteID: String, indexFilePath: String? = nil) async {
        guard let root = await siteDirectory(siteID) else { return }
        if let contentGraph {
            let listing = await Task.detached(priority: .utility) {
                ContentScanner.scan(projectRoot: root, siteID: siteID)
            }.value
            await contentGraph.load(
                siteID: siteID,
                pages: listing.pages,
                posts: listing.posts,
                images: listing.images
            )
        }
        if let indexFilePath {
            await knowledgeIndex?.upsertFile(siteID: siteID, projectRoot: root, relativePath: indexFilePath)
        }
    }
```

Add the four new public methods at the end of the type, before the closing `}` (after the now-refactored `refreshContentGraph`):

```swift
    public func deleteContent(siteID: String, relativePath: String) async -> ContentDeleteResult {
        guard let contentDeleter else { return .failed(reason: "Delete is not configured for this workflow") }
        let result = await contentDeleter(siteID, relativePath)
        if case .deleted = result {
            await refreshContentGraph(siteID: siteID)
        }
        return result
    }

    public func duplicatePage(siteID: String, relativePath: String, title: String) async -> ContentCreateResult {
        guard let pageDuplicator else { return .failed(reason: "Duplicate is not configured for this workflow") }
        let result = await pageDuplicator(siteID, relativePath, title)
        await refreshContentGraphIfCreated(result, siteID: siteID)
        return result
    }

    public func duplicatePost(siteID: String, relativePath: String, collection: String, title: String) async -> ContentCreateResult {
        guard let postDuplicator else { return .failed(reason: "Duplicate is not configured for this workflow") }
        let result = await postDuplicator(siteID, relativePath, collection, title)
        await refreshContentGraphIfCreated(result, siteID: siteID)
        return result
    }

    /// Components aren't part of `SiteContentGraph` (pages/posts/images only), so — matching the
    /// existing precedent for dead-asset Cleanup deletes, which also don't touch the graph — no
    /// graph refresh happens here. The app-layer caller is responsible for refreshing the
    /// Navigator's filesystem-backed sections (`SiteNavigatorModel.refreshNow()`).
    public func createComponent(siteID: String, name: String) async -> ContentCreateResult {
        guard let componentCreator else { return .failed(reason: "Component creation is not configured for this workflow") }
        return await componentCreator(siteID, name)
    }
```

- [ ] **Step 4: Wire the real closures into `.native()`**

In `Sources/AnglesiteCore/ContentCreationWorkflow.swift`, extend the `ContentCreationWorkflow(...)` returned by `.native()` (lines 59–83) — add four trailing arguments after `typedSlugCreator`:

```swift
        return ContentCreationWorkflow(
            operations: native,
            contentGraph: contentGraph,
            knowledgeIndex: knowledgeIndex,
            siteDirectory: siteDirectory,
            pageTemplateCreator: { siteID, title, route, template, onProgress in
                await native.createPage(
                    siteID: siteID,
                    name: title,
                    route: route,
                    template: template,
                    onProgress: onProgress
                )
            },
            typedSlugCreator: { siteID, typeID, title, slug, onProgress in
                await native.createTyped(
                    siteID: siteID,
                    typeID: typeID,
                    title: title,
                    slug: slug,
                    onProgress: onProgress
                )
            },
            contentDeleter: { siteID, relativePath in
                await native.deleteContent(siteID: siteID, relativePath: relativePath)
            },
            pageDuplicator: { siteID, relativePath, title in
                await native.duplicatePage(siteID: siteID, relativePath: relativePath, title: title)
            },
            postDuplicator: { siteID, relativePath, collection, title in
                await native.duplicatePost(siteID: siteID, relativePath: relativePath, collection: collection, title: title)
            },
            componentCreator: { siteID, name in
                await native.createComponent(siteID: siteID, name: name)
            }
        )
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path . --filter ContentCreationWorkflowTests`
Expected: PASS (existing tests + 5 new tests)

- [ ] **Step 6: Run the full AnglesiteCoreTests suite**

Run: `swift test --package-path . --filter AnglesiteCoreTests`
Expected: PASS, no regressions

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteCore/ContentCreationWorkflow.swift Tests/AnglesiteCoreTests/ContentCreationWorkflowTests.swift
git commit -m "feat(core): wire delete/duplicate/createComponent into ContentCreationWorkflow (#516)"
```

---

### Task 5: `SiteNavigatorModel.canDelete` / `canDuplicate`

**Files:**
- Modify: `Sources/AnglesiteApp/SiteNavigatorModel.swift`
- Test: `Tests/AnglesiteAppTests/SiteNavigatorModelTests.swift` (check with `ls Tests/AnglesiteAppTests/ | grep -i navigator`; create if absent)

**Interfaces:**
- Produces: `SiteNavigatorModel.canDelete(_ id: String) -> Bool`
- Produces: `SiteNavigatorModel.canDuplicate(_ id: String) -> Bool`
- Consumes: `SiteNavigatorModel.target(for:)` (existing, `SiteNavigatorModel.swift:71-76`)

- [ ] **Step 1: Check for an existing SiteNavigatorModel test file**

Run: `ls Tests/AnglesiteAppTests/ | grep -i navigator`

If absent, create `Tests/AnglesiteAppTests/SiteNavigatorModelTests.swift` with:

```swift
import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteAppCore

@Suite("SiteNavigatorModel")
@MainActor
struct SiteNavigatorModelTests {
}
```

- [ ] **Step 2: Write the failing tests**

Add inside the suite (or in an `extension SiteNavigatorModelTests` if the file already existed):

```swift
@Test("canDelete and canDuplicate are true for a route (page/post) target")
func canDeleteAndDuplicateRouteTarget() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let graph = SiteContentGraph()
    await graph.load(
        siteID: "site-1",
        pages: [SiteContentGraph.Page(
            id: "site-1:page:/about", siteID: "site-1", route: "/about",
            filePath: "src/pages/about.astro", title: "About", lastModified: Date())],
        posts: [], images: []
    )
    let model = SiteNavigatorModel(graph: graph)
    model.start(siteID: "site-1", siteRoot: root, sourceDirectory: root, websiteTitle: "Test")
    while model.sections.isEmpty { await Task.yield() }

    let id = try #require(model.sections.flatMap(\.items).first { $0.title == "About" }?.id)

    #expect(model.canDelete(id) == true)
    #expect(model.canDuplicate(id) == true)
}

@Test("canDelete and canDuplicate are false for a file (component/style/metadata) target")
func canDeleteAndDuplicateFileTargetIsFalse() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("src/components"), withIntermediateDirectories: true)
    try Data().write(to: root.appendingPathComponent("src/components/Widget.astro"))
    defer { try? FileManager.default.removeItem(at: root) }
    let graph = SiteContentGraph()
    let model = SiteNavigatorModel(graph: graph)
    model.start(siteID: "site-1", siteRoot: root, sourceDirectory: root, websiteTitle: "Test")
    while model.sections.isEmpty { await Task.yield() }

    let id = try #require(model.sections.flatMap(\.items).first { $0.title == "Widget.astro" }?.id)

    #expect(model.canDelete(id) == false)
    #expect(model.canDuplicate(id) == false)
}

@Test("canDelete and canDuplicate are false for an unknown id")
func canDeleteAndDuplicateUnknownIDIsFalse() {
    let model = SiteNavigatorModel(graph: SiteContentGraph())
    #expect(model.canDelete("nonexistent") == false)
    #expect(model.canDuplicate("nonexistent") == false)
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --package-path . --filter SiteNavigatorModelTests`
Expected: FAIL to compile — `canDelete`/`canDuplicate` don't exist yet.

- [ ] **Step 4: Implement `canDelete`/`canDuplicate`, refactoring the shared predicate out of `canRename`**

In `Sources/AnglesiteApp/SiteNavigatorModel.swift`, replace `canRename` (lines 93–100) with:

```swift
    /// A row is renamable/deletable/duplicable iff it is a page or post (route target). File rows
    /// (components/styles/metadata) carry a `.file` target and are out of scope. The
    /// astro-without-title case is caught at commit, not pre-disabled (pre-checking would read
    /// every page file per refresh).
    private func isContentRow(_ id: String) -> Bool {
        guard let target = target(for: id) else { return false }
        if case .route = target { return true }
        return false
    }

    func canRename(_ id: String) -> Bool { isContentRow(id) }

    /// Delete/Duplicate (#516) share Rename's gating exactly — pages and posts only.
    func canDelete(_ id: String) -> Bool { isContentRow(id) }
    func canDuplicate(_ id: String) -> Bool { isContentRow(id) }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path . --filter SiteNavigatorModelTests`
Expected: PASS

- [ ] **Step 6: Run the full AnglesiteAppTests suite**

Run: `swift test --package-path . --filter AnglesiteAppTests`
Expected: PASS, no regressions (rename behavior unchanged — same predicate, just renamed/shared)

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteApp/SiteNavigatorModel.swift Tests/AnglesiteAppTests/SiteNavigatorModelTests.swift
git commit -m "feat(app): add SiteNavigatorModel.canDelete/canDuplicate (#516)"
```

---

### Task 6: `SiteWindowModel` delete/duplicate/createPost/createComponent

**Files:**
- Modify: `Sources/AnglesiteApp/SiteWindowModel.swift`
- Test: `Tests/AnglesiteAppTests/SiteWindowModelTests.swift`

**Interfaces:**
- Consumes: `ContentCreationWorkflow.deleteContent`/`duplicatePage`/`duplicatePost`/`createComponent` (Task 4), `SiteNavigatorModel.canDelete`/`canDuplicate` (Task 5), `NavigatorItem` (`Sources/AnglesiteCore/NavigatorTree.swift:9-16`)
- Produces: `SiteWindowModel.newPostPresented: Bool`, `SiteWindowModel.newComponentPresented: Bool`, `SiteWindowModel.deleteConfirmation: NavigatorItem?`, `SiteWindowModel.contentActionError: String?`
- Produces: `SiteWindowModel.createPost(title: String) async -> ContentCreateResult`
- Produces: `SiteWindowModel.createComponent(name: String) async -> ContentCreateResult`
- Produces: `SiteWindowModel.confirmDelete() async`
- Produces: `SiteWindowModel.duplicate(id: String) async`

- [ ] **Step 1: Write the failing tests**

Add to `Tests/AnglesiteAppTests/SiteWindowModelTests.swift` (reuse the file's existing `makeModel()` helper):

```swift
extension SiteWindowModelTests {
    @Test("createPost no-ops safely when there is no open site")
    func createPostNoSiteReturnsSiteNotFound() async {
        let model = makeModel()
        let result = await model.createPost(title: "Hello")
        #expect(result == .siteNotFound)
    }

    @Test("createComponent no-ops safely when there is no open site")
    func createComponentNoSiteReturnsSiteNotFound() async {
        let model = makeModel()
        let result = await model.createComponent(name: "Widget")
        #expect(result == .siteNotFound)
    }

    @Test("confirmDelete clears deleteConfirmation and no-ops when there is no open site")
    func confirmDeleteNoSiteIsNoOp() async {
        let model = makeModel()
        model.deleteConfirmation = NavigatorItem(id: "site-1:page:/about", title: "About", target: .route("/about"))

        await model.confirmDelete()

        #expect(model.deleteConfirmation == nil)
    }

    @Test("duplicate no-ops safely when there is no open site")
    func duplicateNoSiteIsNoOp() async {
        let model = makeModel()
        await model.duplicate(id: "site-1:page:/about")
        // No crash, no error surfaced — there's nothing to duplicate without an open site.
        #expect(model.contentActionError == nil)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path . --filter SiteWindowModelTests`
Expected: FAIL to compile — `createPost`, `createComponent`, `deleteConfirmation`, `confirmDelete`, `contentActionError`, `duplicate(id:)` don't exist yet.

- [ ] **Step 3: Add the new published properties**

In `Sources/AnglesiteApp/SiteWindowModel.swift`, after `newCollectionPresented` (line 103):

```swift
    var newPagePresented = false
    var newCollectionPresented = false
    var newPostPresented = false
    var newComponentPresented = false
    /// Non-nil ⟺ the Delete confirmation dialog is showing for this navigator item (#516).
    /// Hosted in `SiteWindow` (mirrors `revertConfirmationPresented`'s alert-hosting pattern) —
    /// set from both the navigator's row context menu and the Edit ▸ Delete menu command.
    var deleteConfirmation: NavigatorItem?
    /// Surfaces a Delete/Duplicate failure — mirrors `cleanup.deleteError`, but for content
    /// (page/post) delete/duplicate rather than Cleanup's dead-asset delete.
    var contentActionError: String?
```

- [ ] **Step 4: Implement `createPost` and `createComponent`**

After `createCollectionEntry` (find its closing brace — it starts at line 719 in the pre-existing file; insert immediately after that method's closing `}`):

```swift
    func createPost(title: String) async -> ContentCreateResult {
        guard let site else { return .siteNotFound }
        return await contentCreation.createPost(siteID: site.id, title: title, collection: nil, slug: nil)
    }

    /// Components aren't tracked in `SiteContentGraph`, so — unlike `createPage`/`createPost`/
    /// `createCollectionEntry`, whose graph rescan already triggers the Navigator's own
    /// change-stream refresh — this force-refreshes the Navigator directly on success. Same
    /// reasoning as `deleteCleanupCandidate`'s force-refresh for non-graph-tracked files.
    func createComponent(name: String) async -> ContentCreateResult {
        guard let site else { return .siteNotFound }
        let result = await contentCreation.createComponent(siteID: site.id, name: name)
        if case .created = result {
            await navigator?.refreshNow()
        }
        return result
    }
```

- [ ] **Step 5: Implement `confirmDelete`**

Insert immediately after `createComponent`:

```swift
    /// Resolves `deleteConfirmation` to its page/post record, deletes via
    /// `contentCreation.deleteContent`, and clears the confirmation. Mirrors
    /// `deleteCleanupCandidate`'s ordering exactly: editor/inspector state open on the file being
    /// deleted is discarded *before* the delete call (not after), so a suspended flush across the
    /// git subprocess calls can't resurrect the file.
    @MainActor
    func confirmDelete() async {
        guard let item = deleteConfirmation else { return }
        deleteConfirmation = nil
        guard let site, case .route = item.target else { return }

        let relPath: String
        if let page = await contentGraph.page(id: item.id) {
            relPath = page.filePath
        } else if let post = await contentGraph.post(id: item.id) {
            relPath = post.filePath
        } else {
            return
        }

        let deletedURL = site.sourceDirectory.appendingPathComponent(relPath)
        if activeEditorFile?.url == deletedURL {
            activeEditor = nil
            mainPaneMode = .preview
        }
        if inspectorContext?.model.file.url == deletedURL {
            inspectorContext = nil
        }

        let result = await contentCreation.deleteContent(siteID: site.id, relativePath: relPath)
        switch result {
        case .deleted:
            if navigator?.selection == item.id { navigator?.selection = nil }
        case .failed(let reason):
            contentActionError = reason
        case .siteNotFound:
            break
        }
    }
```

- [ ] **Step 6: Implement `duplicate(id:)`**

Insert immediately after `confirmDelete`:

```swift
    /// Duplicates the page/post at `id`. Non-destructive, so no confirmation. On success, refreshes
    /// the Navigator (deterministic — doesn't rely on `SiteContentGraph`'s change-stream having
    /// already been drained by the time this returns) and selects the new item, whose id follows
    /// the documented `SiteContentGraph.Page`/`Post` format (`"{siteID}:page:{route}"` /
    /// `"{siteID}:post:{slug}"`) — `identifier` in `ContentCreateResult.created` is exactly the
    /// route (page) or slug (post) per that type's own doc comment.
    @MainActor
    func duplicate(id: String) async {
        guard let site else { return }

        let result: ContentCreateResult
        let isPost: Bool
        if let page = await contentGraph.page(id: id) {
            isPost = false
            result = await contentCreation.duplicatePage(
                siteID: site.id, relativePath: page.filePath, title: page.title ?? page.route)
        } else if let post = await contentGraph.post(id: id) {
            isPost = true
            result = await contentCreation.duplicatePost(
                siteID: site.id, relativePath: post.filePath, collection: post.collection, title: post.title)
        } else {
            return
        }

        switch result {
        case .created(_, let identifier):
            await navigator?.refreshNow()
            navigator?.selection = isPost ? "\(site.id):post:\(identifier)" : "\(site.id):page:\(identifier)"
        case .failed(let reason):
            contentActionError = reason
        case .siteNotFound:
            break
        }
    }
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `swift test --package-path . --filter SiteWindowModelTests`
Expected: PASS

- [ ] **Step 8: Run the full AnglesiteAppTests suite**

Run: `swift test --package-path . --filter AnglesiteAppTests`
Expected: PASS, no regressions

- [ ] **Step 9: Commit**

```bash
git add Sources/AnglesiteApp/SiteWindowModel.swift Tests/AnglesiteAppTests/SiteWindowModelTests.swift
git commit -m "feat(app): add SiteWindowModel delete/duplicate/createPost/createComponent (#516)"
```

---

### Task 7: `FocusedSite.swift` — new focused values and commands

**Files:**
- Modify: `Sources/AnglesiteApp/FocusedSite.swift`

**Interfaces:**
- Consumes: `SiteWindowModel.newPostPresented`/`newComponentPresented` (Task 6, set via closures), `NavigatorSelectionActions` delete/duplicate closures (wired in Task 9)
- Produces: `NewContentActions.newPost: @MainActor () -> Void`, `NewContentActions.newComponent: @MainActor () -> Void`
- Produces: `NavigatorSelectionActions { let delete: (@MainActor () -> Void)?; let duplicate: (@MainActor () -> Void)? }`
- Produces: `FocusedValues.navigatorSelectionActions: NavigatorSelectionActions?`
- Produces: `NavigatorEditCommands: Commands` (new type)

No test file — this is a pure `Commands`/`FocusedValueKey` declaration with no unit-testable behavior; verified via the full `xcodebuild` build in Task 11 and manual GUI verification.

- [ ] **Step 1: Extend `NewContentActions` and add `NavigatorSelectionActions`**

In `Sources/AnglesiteApp/FocusedSite.swift`, replace lines 6–24 with:

```swift
private struct FocusedSiteIDKey: FocusedValueKey { typealias Value = String }
private struct FocusedNewContentActionsKey: FocusedValueKey { typealias Value = NewContentActions }
private struct FocusedNavigatorSelectionActionsKey: FocusedValueKey { typealias Value = NavigatorSelectionActions }

struct NewContentActions {
    let newPage: @MainActor () -> Void
    let newCollection: @MainActor () -> Void
    let newPost: @MainActor () -> Void
    let newComponent: @MainActor () -> Void
}

/// Delete/Duplicate acting on the Navigator's current selection (#516). Each action is `nil` when
/// there is no selection, or the selection isn't a page/post (`SiteNavigatorModel.canDelete`/
/// `canDuplicate`) — that's what lets the Edit-menu items enable/disable correctly without the
/// menu needing to know Navigator internals.
struct NavigatorSelectionActions {
    let delete: (@MainActor () -> Void)?
    let duplicate: (@MainActor () -> Void)?
}

extension FocusedValues {
    var siteID: String? {
        get { self[FocusedSiteIDKey.self] }
        set { self[FocusedSiteIDKey.self] = newValue }
    }

    var newContentActions: NewContentActions? {
        get { self[FocusedNewContentActionsKey.self] }
        set { self[FocusedNewContentActionsKey.self] = newValue }
    }

    var navigatorSelectionActions: NavigatorSelectionActions? {
        get { self[FocusedNavigatorSelectionActionsKey.self] }
        set { self[FocusedNavigatorSelectionActionsKey.self] = newValue }
    }
}
```

- [ ] **Step 2: Add Post…/Component… to the File ▸ New menu**

In `NewContentCommands.body`, inside the `Menu("New")` block, after the `Button("Collection…")` (after line 51's closing brace, before the `Menu("New")`'s own closing brace):

```swift
                Button("Collection…") {
                    focusedActions?.newCollection()
                }
                .disabled(focusedActions == nil)

                Button("Post…") {
                    focusedActions?.newPost()
                }
                .disabled(focusedActions == nil)

                Button("Component…") {
                    focusedActions?.newComponent()
                }
                .disabled(focusedActions == nil)
            }
```

- [ ] **Step 3: Add `NavigatorEditCommands`**

Insert a new `Commands` type after `NewContentCommands` (after its closing `}`, before `ExportSiteCommands`):

```swift
/// Edit ▸ Delete (⌘⌫) / Duplicate (⌘D) for the focused window's Navigator selection (#516).
/// Placed in the Edit menu next to Cut/Copy/Paste — the macOS convention for selection-scoped
/// destructive/duplicate actions — rather than the File menu.
struct NavigatorEditCommands: Commands {
    @FocusedValue(\.navigatorSelectionActions) private var actions

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button("Delete") {
                actions?.delete?()
            }
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(actions?.delete == nil)

            Button("Duplicate") {
                actions?.duplicate?()
            }
            .keyboardShortcut("d", modifiers: [.command])
            .disabled(actions?.duplicate == nil)
        }
    }
}
```

- [ ] **Step 4: Build to verify it compiles**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -40`

Expected: build fails — `SiteWindow.swift` doesn't yet supply `newPost`/`newComponent` in its `NewContentActions(...)` construction (Task 10 fixes this), and `NavigatorEditCommands` isn't registered in `AnglesiteApp.swift`'s `.commands` block yet (Task 10 fixes this too). Confirm the failure is specifically about those two gaps and not a syntax error in this task's edits — if `xcodegen generate` hasn't been run yet in this worktree, run it first per the project's worktree setup.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/FocusedSite.swift
git commit -m "feat(app): add NavigatorSelectionActions + Edit-menu Delete/Duplicate commands (#516)"
```

---

### Task 8: `NewPostSheet` and `NewComponentSheet`

**Files:**
- Modify: `Sources/AnglesiteApp/NewContentSheets.swift`

**Interfaces:**
- Consumes: `ContentCreateResult` (`Sources/AnglesiteCore/ContentOperationsService.swift`)
- Produces: `NewPostSheet(onCreate: (String) async -> ContentCreateResult)`
- Produces: `NewComponentSheet(onCreate: (String) async -> ContentCreateResult)`

No test file — SwiftUI view bodies with no independently testable logic; verified via the full `xcodebuild` build in Task 11 and manual GUI verification.

- [ ] **Step 1: Add `NewPostSheet`**

Append to `Sources/AnglesiteApp/NewContentSheets.swift`, after the closing `}` of `NewPageSheet` (after line 154):

```swift
struct NewPostSheet: View {
    let onCreate: (String) async -> ContentCreateResult

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Post") {
                    TextField("Title", text: $title)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 380, minHeight: 160)
            .navigationTitle("New Post")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isCreating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isCreating ? "Creating…" : "Create") {
                        create()
                    }
                    .disabled(isCreating || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func create() {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        isCreating = true
        errorMessage = nil
        Task {
            let result = await onCreate(cleanTitle)
            await MainActor.run {
                isCreating = false
                switch result {
                case .created:
                    dismiss()
                case .siteNotFound:
                    errorMessage = "This site is no longer available."
                case .failed(let reason):
                    errorMessage = reason
                }
            }
        }
    }
}
```

- [ ] **Step 2: Add `NewComponentSheet`**

Append immediately after `NewPostSheet`:

```swift
struct NewComponentSheet: View {
    let onCreate: (String) async -> ContentCreateResult

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Component") {
                    TextField("Name", text: $name, prompt: Text("MyComponent"))
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 380, minHeight: 160)
            .navigationTitle("New Component")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isCreating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isCreating ? "Creating…" : "Create") {
                        create()
                    }
                    .disabled(isCreating || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func create() {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        isCreating = true
        errorMessage = nil
        Task {
            let result = await onCreate(cleanName)
            await MainActor.run {
                isCreating = false
                switch result {
                case .created:
                    dismiss()
                case .siteNotFound:
                    errorMessage = "This site is no longer available."
                case .failed(let reason):
                    errorMessage = reason
                }
            }
        }
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteApp/NewContentSheets.swift
git commit -m "feat(app): add NewPostSheet and NewComponentSheet (#516)"
```

---

### Task 9: `SiteNavigatorView.swift` — Delete/Duplicate context menu items

**Files:**
- Modify: `Sources/AnglesiteApp/SiteNavigatorView.swift`

**Interfaces:**
- Consumes: `SiteNavigatorModel.canDelete`/`canDuplicate` (Task 5)
- Produces: two new closure params on `SiteNavigatorView`: `onDeleteRequested: (NavigatorItem) -> Void`, `onDuplicateRequested: (NavigatorItem) -> Void`

No test file — SwiftUI view body; verified via the full `xcodebuild` build in Task 11 and manual GUI verification.

- [ ] **Step 1: Add the two new closure properties**

In `Sources/AnglesiteApp/SiteNavigatorView.swift`, after `onDeleteCleanupCandidate` (line 10):

```swift
    var onOpenCleanupCandidate: (DeadAssetScanner.CleanupCandidate) -> Void
    var onDeleteCleanupCandidate: (DeadAssetScanner.CleanupCandidate) async -> Void
    var onDeleteRequested: (NavigatorItem) -> Void
    var onDuplicateRequested: (NavigatorItem) -> Void
```

- [ ] **Step 2: Add Delete/Duplicate to the row context menu**

Replace the `.contextMenu` block inside `row(for:in:)` (lines 127–131) with:

```swift
                .contextMenu {
                    if model.canRename(item.id) {
                        Button("Rename") { model.beginEditing(item.id) }
                    }
                    if model.canDuplicate(item.id) {
                        Button("Duplicate") { onDuplicateRequested(item) }
                    }
                    if model.canDelete(item.id) {
                        Button("Delete", role: .destructive) { onDeleteRequested(item) }
                    }
                }
```

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteApp/SiteNavigatorView.swift
git commit -m "feat(app): add Delete/Duplicate to the navigator context menu (#516)"
```

---

### Task 10: Wire everything in `SiteWindow.swift` and register `NavigatorEditCommands`

**Files:**
- Modify: `Sources/AnglesiteApp/SiteWindow.swift`
- Modify: `Sources/AnglesiteApp/AnglesiteApp.swift`

**Interfaces:**
- Consumes: everything produced in Tasks 6–9

- [ ] **Step 1: Add `contentDeleteTitle` state and the `navigatorSelectionActions(for:)` helper**

In `Sources/AnglesiteApp/SiteWindow.swift`, add a new `@State` property after `inspectorShown` (after line 24):

```swift
    @SceneStorage("siteInspector.shown") private var inspectorShown = true
    /// The title shown in the content-delete confirmation dialog. Held separately from
    /// `model.deleteConfirmation` so the title stays stable through the dismiss animation —
    /// mirrors `SiteNavigatorView`'s `candidateToDeleteTitle` for the same reason.
    @State private var contentDeleteTitle: String = ""
```

Add a new private helper method near the bottom of the type, after `centeredStatus` (after its closing `}`, before the final closing `}` of `struct SiteWindow`):

```swift
    /// Builds the Edit-menu Delete/Duplicate actions for the current Navigator selection, or nil
    /// when there's no site or no selection. `delete`/`duplicate` are individually nil when the
    /// selected row isn't a page/post (`canDelete`/`canDuplicate`), which is what disables the
    /// individual menu items rather than hiding the whole group.
    private func navigatorSelectionActions(for model: SiteWindowModel) -> NavigatorSelectionActions? {
        guard model.site != nil, let navigator = model.navigator, let id = navigator.selection else {
            return nil
        }
        return NavigatorSelectionActions(
            delete: navigator.canDelete(id) ? {
                guard let item = navigator.sections.flatMap(\.items).first(where: { $0.id == id }) else { return }
                contentDeleteTitle = "Delete “\(item.title)”?"
                model.deleteConfirmation = item
            } : nil,
            duplicate: navigator.canDuplicate(id) ? {
                Task { await model.duplicate(id: id) }
            } : nil
        )
    }
```

- [ ] **Step 2: Extend `NewContentActions` construction and add `navigatorSelectionActions`**

Replace the `.focusedSceneValue(\.newContentActions, ...)` modifier (lines 90–93) with:

```swift
        .focusedSceneValue(\.newContentActions, model.site == nil ? nil : NewContentActions(
            newPage: { model.newPagePresented = true },
            newCollection: { model.newCollectionPresented = true },
            newPost: { model.newPostPresented = true },
            newComponent: { model.newComponentPresented = true }
        ))
        .focusedSceneValue(\.navigatorSelectionActions, navigatorSelectionActions(for: model))
```

- [ ] **Step 3: Wire `onDeleteRequested`/`onDuplicateRequested` into `SiteNavigatorView`**

Replace the `SiteNavigatorView(...)` construction (lines 128–133) with:

```swift
                SiteNavigatorView(
                    model: navigator,
                    cleanup: model.cleanup,
                    onOpenCleanupCandidate: { model.openCleanupCandidate($0) },
                    onDeleteCleanupCandidate: { await model.deleteCleanupCandidate($0) },
                    onDeleteRequested: { item in
                        contentDeleteTitle = "Delete “\(item.title)”?"
                        model.deleteConfirmation = item
                    },
                    onDuplicateRequested: { item in
                        Task { await model.duplicate(id: item.id) }
                    }
                )
```

- [ ] **Step 4: Add the confirmation dialog and failure alert**

After the `.alert("Revert to the last saved version?", ...)` block (after line 542, before `.sheet(isPresented: $bindableModel.newPagePresented)`), add:

```swift
        .confirmationDialog(
            contentDeleteTitle,
            isPresented: Binding(
                get: { bindableModel.deleteConfirmation != nil },
                set: { if !$0 { model.deleteConfirmation = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { Task { await model.confirmDelete() } }
            Button("Cancel", role: .cancel) { model.deleteConfirmation = nil }
        } message: {
            Text("This content will be removed from the working tree. This can be undone via git.")
        }
        .alert(
            "Delete failed",
            isPresented: Binding(
                get: { model.contentActionError != nil },
                set: { if !$0 { model.contentActionError = nil } }),
            presenting: model.contentActionError
        ) { _ in
            Button("OK", role: .cancel) { model.contentActionError = nil }
        } message: { msg in
            Text(msg)
        }
```

- [ ] **Step 5: Wire the two new sheets**

After the `.sheet(isPresented: $bindableModel.newCollectionPresented) { ... }` block (after line 554), add:

```swift
        .sheet(isPresented: $bindableModel.newPostPresented) {
            NewPostSheet { title in
                await model.createPost(title: title)
            }
        }
        .sheet(isPresented: $bindableModel.newComponentPresented) {
            NewComponentSheet { name in
                await model.createComponent(name: name)
            }
        }
```

- [ ] **Step 6: Register `NavigatorEditCommands` in `AnglesiteApp.swift`**

In `Sources/AnglesiteApp/AnglesiteApp.swift`, after `NewContentCommands()` (line 203), add:

```swift
            NewContentCommands()
            // Edit ▸ Delete ⌘⌫ / Duplicate ⌘D for the focused window's Navigator selection (#516).
            NavigatorEditCommands()
```

- [ ] **Step 7: Run the full build**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -60`

Expected: BUILD SUCCEEDED. If `Anglesite.xcodeproj` doesn't exist in this worktree yet, run `xcodegen generate` first (per this project's worktree convention), and if the plugin resources aren't populated, ensure `ANGLESITE_PLUGIN_SRC` points at the sibling `anglesite` checkout before building (also a worktree convention — see the project's `CLAUDE.md`).

- [ ] **Step 8: Run the full test suite one more time**

Run: `swift test --package-path .`
Expected: PASS, no regressions across `AnglesiteSiteModelTests`, `AnglesiteCoreTests`, `AnglesiteBridgeTests`, `AnglesiteAppTests` (and `AnglesiteIntentsTests` on Swift 6.4+/Xcode 27).

- [ ] **Step 9: Commit**

```bash
git add Sources/AnglesiteApp/SiteWindow.swift Sources/AnglesiteApp/AnglesiteApp.swift
git commit -m "feat(app): wire Delete/Duplicate/New Post/New Component into SiteWindow (#516)"
```

---

### Task 11: Manual GUI verification

**Files:** none (verification only)

- [ ] **Step 1: Launch the app against a real site**

Run the app (`⌘R` in Xcode, or per the project's `run` skill) and open a site with at least one page and one post.

- [ ] **Step 2: Verify New Post…**

File ▸ New ▸ Post… — enter a title, Create. Confirm: the sheet dismisses, the new post appears under the Navigator's Posts section, and `git log` in the site's `Source/` directory shows a new commit for it.

- [ ] **Step 3: Verify New Component…**

File ▸ New ▸ Component… — enter a name (e.g. "call to action"), Create. Confirm: the sheet dismisses, `CallToAction.astro` appears under the Navigator's Components section, and it's committed.

- [ ] **Step 4: Verify Duplicate (context menu and Edit menu)**

Right-click a page in the Navigator ▸ Duplicate. Confirm: a `<title>-copy` entry appears and is selected. Then select a post and choose Edit ▸ Duplicate (⌘D) — confirm the same behavior via the menu bar path, and that ⌘D is disabled when a non-page/post row (e.g. a component) is selected.

- [ ] **Step 5: Verify Delete (context menu and Edit menu)**

Right-click a page ▸ Delete — confirm the confirmation dialog shows the page's title, Delete removes it from the Navigator, and `git log` shows the delete commit. Repeat via Edit ▸ Delete (⌘⌫) on a post. Confirm ⌘⌫ is disabled when a non-page/post row is selected, and when nothing is selected.

- [ ] **Step 6: Verify editor/inspector discard-on-delete**

Open a page in the editor (double-click or select it so it shows in the Inspector), then delete that same page via the Navigator context menu. Confirm the editor pane returns to Preview and the Inspector clears, rather than showing a stale/dirty buffer for a file that's gone.

- [ ] **Step 7: Verify delete failure surfaces an alert**

With a page selected, make the site's `Source/` git working tree dirty in a way that would make `git commit` fail (e.g. an unrelated staged conflict, or temporarily `chmod -w .git` — clean this up after the test), then attempt Delete. Confirm a "Delete failed" alert appears with a reason, and the file is *not* removed from the Navigator.
