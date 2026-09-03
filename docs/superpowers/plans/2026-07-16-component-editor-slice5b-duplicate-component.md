# Component Editor Slice 5b: Duplicate & Modify Component Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Component Editor's palette a "Duplicate & Modify" command on project-component items — the remaining app-only piece of Component Editor slice 5 (issue #495) that needs no plugin/MCP change, since it's a pure file-copy + git-commit operation.

**Architecture:** `NativeContentOperations` (already the native, in-process, MCP-free home for `createPage`/`createPost`/`createComponent`/`duplicatePage`/`duplicatePost` — see `Sources/AnglesiteCore/NativeContentOperations.swift`) gains a `duplicateComponent(siteID:relativePath:)` method following the exact same read-contents/pick-non-colliding-name/write/commit shape as `duplicatePage`. `SiteWindowModel` gains a thin wrapper (mirroring its existing `createComponent(name:)`), `ComponentEditorContext` gains a `duplicateComponent` closure (mirroring its existing `onOpenFile`), `ComponentEditorModel` gains a method that calls it and opens the result, and `ComponentEditorView`'s palette grid item gains a context menu. Design spec §6.3 calls this "duplicate-and-modify from the navigator context menu" — it's surfaced on the Component Editor's own palette rather than `SiteNavigatorView` because `SiteNavigatorView`/`SiteURLTree` deliberately excludes non-page source files (components aren't shown there at all — see `Sources/AnglesiteCore/SiteURLTree.swift`'s file-level doc comment), while the palette already lists every project component by design (spec §4.1).

**Tech Stack:** Swift 6.4 / SwiftUI (macOS 27+), Swift Testing, existing `NativeContentOperations`/`SiteWindowModel`/`ComponentEditorModel`/`ComponentEditorView` types, SwiftGit2-backed `gitCommit` closure (no plugin/MCP round-trip).

## Global Constraints

- Swift 6.4 / macOS 27+ toolchain. `Anglesite.xcodeproj` is gitignored — `xcodegen generate` if missing.
- `ANGLESITE_PLUGIN_SRC=/Users/dwk/Developer/github.com/Anglesite/anglesite` for this worktree's builds (not used by this plan's code, but needed for the app build itself to stage container resources).
- No plugin PR, no MCP schema change — this whole feature is native Swift, matching `createComponent`'s precedent.
- Conventional commits (`feat(component-editor): …`), reference `#495`.
- Manual GUI verification: attempt it, but if GUI automation access is unavailable/denied, say so explicitly in the PR rather than claiming it was done (do not silently skip this disclosure).

---

## File Structure

- **Modify:** `Sources/AnglesiteCore/NativeContentOperations.swift` — new `duplicateComponent(siteID:relativePath:)` method.
- **Modify:** `Tests/AnglesiteCoreTests/NativeContentOperationsTests.swift` — new `NativeContentOperationsDuplicateComponentTests` suite.
- **Modify:** `Sources/AnglesiteApp/SiteWindowModel.swift` — new `duplicateComponent(relativePath:)` wrapper.
- **Modify:** `Tests/AnglesiteAppTests/SiteWindowModelTests.swift` — one no-site no-op test.
- **Modify:** `Sources/AnglesiteApp/SiteWindow.swift` — wire the new closure into `ComponentEditorContext(...)`.
- **Modify:** `Sources/AnglesiteApp/ComponentEditorModel.swift` — new `duplicateComponent(path:)` field on `ComponentEditorContext` + method on `ComponentEditorModel`.
- **Modify:** `Sources/AnglesiteApp/ComponentEditorView.swift` — context menu on palette items.

---

### Task 1: `NativeContentOperations.duplicateComponent`

**Files:**
- Modify: `Sources/AnglesiteCore/NativeContentOperations.swift`
- Test: `Tests/AnglesiteCoreTests/NativeContentOperationsTests.swift`

**Interfaces:**
- Consumes: `siteDirectory: @Sendable (String) async -> URL?`, `gitCommit: GitCommit`, `fileManager: FileManager`, `write(_:to:)` (all existing private/stored members of `NativeContentOperations`), `FileDocumentIO.load(_:fileManager:)` (existing helper `duplicatePage`/`duplicatePost` already use).
- Produces: `public func duplicateComponent(siteID: String, relativePath: String) async -> ContentCreateResult` — `.created(filePath:identifier:)` where `identifier` is the new PascalCase component name (no leading path, no `.astro`), `filePath` is the new project-relative path. Task 3 (`SiteWindowModel`) calls this.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/AnglesiteCoreTests/NativeContentOperationsTests.swift` (a new suite, placed after the existing `NativeContentOperationsComponentTests` suite at the end of the file):

```swift
@Suite("NativeContentOperations.duplicateComponent")
struct NativeContentOperationsDuplicateComponentTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-content-ops-dup-component-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("duplicateComponent writes a Copy-suffixed file with identical contents")
    func duplicatesComponent() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let relPath = "src/components/Card.astro"
        let abs = root.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: abs.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = "---\ninterface Props { title: string }\n---\n<div>{Astro.props.title}</div>\n"
        try original.write(to: abs, atomically: true, encoding: .utf8)

        let ops = NativeContentOperations(siteDirectory: { _ in root }, gitCommit: { _, _, _ in "deadbeef" })

        let result = await ops.duplicateComponent(siteID: "site-1", relativePath: relPath)

        guard case .created(let filePath, let identifier) = result else {
            Issue.record("expected .created, got \(result)"); return
        }
        #expect(filePath == "src/components/CardCopy.astro")
        #expect(identifier == "CardCopy")
        let copied = try String(contentsOf: root.appendingPathComponent(filePath), encoding: .utf8)
        #expect(copied == original)
    }

    @Test("duplicateComponent bumps the suffix on collision")
    func duplicatesComponentWithCollision() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let relPath = "src/components/Card.astro"
        let abs = root.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: abs.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "original".write(to: abs, atomically: true, encoding: .utf8)
        try "existing copy".write(to: root.appendingPathComponent("src/components/CardCopy.astro"), atomically: true, encoding: .utf8)

        let ops = NativeContentOperations(siteDirectory: { _ in root }, gitCommit: { _, _, _ in "deadbeef" })

        let result = await ops.duplicateComponent(siteID: "site-1", relativePath: relPath)

        guard case .created(let filePath, let identifier) = result else {
            Issue.record("expected .created, got \(result)"); return
        }
        #expect(filePath == "src/components/CardCopy2.astro")
        #expect(identifier == "CardCopy2")
    }

    @Test("duplicateComponent preserves a nested subdirectory")
    func duplicatesNestedComponent() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let relPath = "src/components/esi/EsiInclude.astro"
        let abs = root.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: abs.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "original".write(to: abs, atomically: true, encoding: .utf8)

        let ops = NativeContentOperations(siteDirectory: { _ in root }, gitCommit: { _, _, _ in "deadbeef" })

        let result = await ops.duplicateComponent(siteID: "site-1", relativePath: relPath)

        guard case .created(let filePath, _) = result else { Issue.record("expected .created, got \(result)"); return }
        #expect(filePath == "src/components/esi/EsiIncludeCopy.astro")
    }

    @Test("duplicateComponent fails when the source file does not exist")
    func duplicateMissingComponentFails() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ops = NativeContentOperations(siteDirectory: { _ in root })

        let result = await ops.duplicateComponent(siteID: "site-1", relativePath: "src/components/Missing.astro")

        guard case .failed = result else { Issue.record("expected .failed, got \(result)"); return }
    }

    @Test("unknown site returns .siteNotFound")
    func duplicateComponentSiteNotFound() async {
        let ops = NativeContentOperations(siteDirectory: { _ in nil }, gitCommit: { _, _, _ in nil })
        let result = await ops.duplicateComponent(siteID: "missing", relativePath: "src/components/Card.astro")
        #expect(result == .siteNotFound)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter NativeContentOperationsDuplicateComponentTests`
Expected: FAIL — `duplicateComponent` does not exist on `NativeContentOperations` (compile error).

- [ ] **Step 3: Write the implementation**

In `Sources/AnglesiteCore/NativeContentOperations.swift`, add this method directly after `duplicatePost` (i.e. right before the `/// Scaffold a minimal blank .astro component…` doc comment / `createComponent` method):

```swift
    /// Duplicate an existing `.astro` component: read its contents verbatim (no retitle —
    /// unlike pages/posts, a component has no title to rewrite), derive a "Copy"-suffixed
    /// PascalCase name colliding-safely with `NameCopy`/`NameCopy2`… (mirrors `createComponent`'s
    /// PascalCase convention), write, commit. Preserves the source's subdirectory (e.g.
    /// `src/components/esi/EsiInclude.astro` duplicates to `src/components/esi/EsiIncludeCopy.astro`)
    /// since component grouping directories are meaningful (design spec §4.1's palette groups by
    /// `SiteFileTree`'s components group).
    public func duplicateComponent(siteID: String, relativePath: String) async -> ContentCreateResult {
        guard let root = await siteDirectory(siteID) else { return .siteNotFound }
        let sourceAbs = root.appendingPathComponent(relativePath)
        guard fileManager.fileExists(atPath: sourceAbs.path) else {
            return .failed(reason: "No component exists at \(relativePath)")
        }
        let contents: String
        do { contents = try FileDocumentIO.load(sourceAbs, fileManager: fileManager).contents }
        catch { return .failed(reason: "\(error)") }

        let relDir = (relativePath as NSString).deletingLastPathComponent
        let baseName = ((relativePath as NSString).lastPathComponent as NSString).deletingPathExtension
        func candidatePath(_ name: String) -> String {
            relDir.isEmpty ? "\(name).astro" : "\(relDir)/\(name).astro"
        }
        var attempt = 1
        var candidateName = "\(baseName)Copy"
        var relPath = candidatePath(candidateName)
        while attempt < 1000, fileManager.fileExists(atPath: root.appendingPathComponent(relPath).path) {
            attempt += 1
            candidateName = "\(baseName)Copy\(attempt)"
            relPath = candidatePath(candidateName)
        }
        guard !fileManager.fileExists(atPath: root.appendingPathComponent(relPath).path) else {
            return .failed(reason: "Couldn't find an available name for the duplicate after 1000 attempts")
        }

        do { try write(contents, to: root.appendingPathComponent(relPath)) }
        catch { return .failed(reason: "\(error)") }

        _ = await gitCommit(root, relPath, "anglesite: duplicate component \(candidateName)")
        return .created(filePath: relPath, identifier: candidateName)
    }

```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter NativeContentOperationsDuplicateComponentTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/NativeContentOperations.swift Tests/AnglesiteCoreTests/NativeContentOperationsTests.swift
git commit -m "feat(component-editor): add NativeContentOperations.duplicateComponent (#495)"
```

---

### Task 2: `SiteWindowModel.duplicateComponent` + wire into `ComponentEditorContext`

**Files:**
- Modify: `Sources/AnglesiteApp/SiteWindowModel.swift`
- Modify: `Sources/AnglesiteApp/SiteWindow.swift`
- Test: `Tests/AnglesiteAppTests/SiteWindowModelTests.swift`

**Interfaces:**
- Consumes: `NativeContentOperations.duplicateComponent(siteID:relativePath:)` (Task 1); existing `SiteWindowModel.site`, `SiteWindowModel.contentCreation`, `SiteWindowModel.navigator?.refreshNow()` (all existing members, same as `createComponent`).
- Produces: `func duplicateComponent(relativePath: String) async -> ContentCreateResult` on `SiteWindowModel`. Task 3 wires this into `ComponentEditorContext.duplicateComponent`.

- [ ] **Step 1: Write the failing test**

Add to `Tests/AnglesiteAppTests/SiteWindowModelTests.swift`, in the `extension SiteWindowModelTests` block that already contains `createComponentNoSiteReturnsSiteNotFound` (right after that test):

```swift
    @Test("duplicateComponent no-ops safely when there is no open site")
    func duplicateComponentNoSiteReturnsSiteNotFound() async {
        let model = makeModel()
        let result = await model.duplicateComponent(relativePath: "src/components/Card.astro")
        #expect(result == .siteNotFound)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path . --filter SiteWindowModelTests`
Expected: FAIL — `duplicateComponent` does not exist on `SiteWindowModel` (compile error).

- [ ] **Step 3: Write the implementation**

In `Sources/AnglesiteApp/SiteWindowModel.swift`, add this method directly after `createComponent` (which ends around line 991):

```swift
    /// Duplicates the component at `relativePath` (design spec §6.3: "duplicate-and-modify" —
    /// surfaced on the Component Editor's own palette, since project components aren't tracked
    /// in `SiteContentGraph` or shown in the page-only Navigator). Same force-refresh reasoning
    /// as `createComponent`.
    func duplicateComponent(relativePath: String) async -> ContentCreateResult {
        guard let site else { return .siteNotFound }
        let result = await contentCreation.duplicateComponent(siteID: site.id, relativePath: relativePath)
        if case .created = result {
            await navigator?.refreshNow()
        }
        return result
    }
```

- [ ] **Step 4: Wire it into `ComponentEditorContext(...)`**

In `Sources/AnglesiteApp/SiteWindow.swift`, in `mainPaneContent(for:)`'s `ComponentEditorContext(...)` construction (around line 708-722), add a `duplicateComponent` argument right after `onOpenFile`:

```swift
                    componentContext: ComponentEditorContext(
                        baseURL: model.preview.readyURL,
                        modelClient: ComponentModelClient(mcpClient: { [preview = model.preview] in
                            await preview.mcpClient()
                        }),
                        sourceRoot: site.sourceDirectory,
                        editRouter: model.preview.editRouter,
                        onOpenFile: { file in model.openFile(file) },
                        duplicateComponent: { relativePath in await model.duplicateComponent(relativePath: relativePath) }
                    )
```

(Only the trailing `onOpenFile: { file in model.openFile(file) },` line and the new `duplicateComponent:` line change — everything else in that initializer call stays as-is. Task 3 adds the `duplicateComponent` parameter to `ComponentEditorContext`'s own initializer, which this call now satisfies.)

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --package-path . --filter SiteWindowModelTests`
Expected: This will still FAIL to compile until Task 3 adds the `duplicateComponent` parameter to `ComponentEditorContext` (Step 4 above references a parameter that doesn't exist yet). That's expected — proceed directly to Task 3, then come back and run the full build/test pass at the end of Task 3.

- [ ] **Step 6: Commit** (deferred to the end of Task 3, since Task 2 Step 4 doesn't compile in isolation — see Task 3 Step 4's commit, which covers both)

---

### Task 3: `ComponentEditorContext.duplicateComponent` + `ComponentEditorModel.duplicateComponent(path:)`

**Files:**
- Modify: `Sources/AnglesiteApp/ComponentEditorModel.swift`

**Interfaces:**
- Consumes: `Task 2`'s `SiteWindowModel.duplicateComponent` (via the `context.duplicateComponent` closure); existing `ComponentEditorModel.projectComponents`, `context.sourceRoot`, `context.onOpenFile`, `SiteFileTree.scan(siteRoot:)` (all existing).
- Produces: `ComponentEditorContext.duplicateComponent: ((String) async -> ContentCreateResult)?` (new field, default `nil`); `ComponentEditorModel.duplicateComponent(path: String) async -> ContentCreateResult?` (new method). Task 4 (`ComponentEditorView`) calls the model method.

- [ ] **Step 1: Add the `duplicateComponent` field to `ComponentEditorContext`**

In `Sources/AnglesiteApp/ComponentEditorModel.swift`, in the `ComponentEditorContext` struct (near the top of the file), add a new field right after `onOpenFile`:

```swift
    /// Opens a different file in the main pane — used to implement "double-click a sealed
    /// component instance to edit its own definition" (spec §4.1). `nil` in
    /// tests/previews that don't need navigation.
    var onOpenFile: ((FileRef) -> Void)? = nil
    /// Duplicates a project-relative `.astro` component path, returning the new file's path/name
    /// on success (design spec §6.3: "duplicate-and-modify"). `nil` in tests/previews that don't
    /// need it — `ComponentEditorModel.duplicateComponent(path:)` no-ops when this is `nil`.
    var duplicateComponent: ((String) async -> ContentCreateResult)? = nil
```

- [ ] **Step 2: Add `ComponentEditorModel.duplicateComponent(path:)`**

In the same file, add this method to `ComponentEditorModel` directly after `openReferencedComponent(tag:)`:

```swift
    /// Duplicates `path` (a project-relative `.astro` path, e.g. from a palette item's
    /// `componentPath`) via `context.duplicateComponent` and, on success, refreshes
    /// `projectComponents` and opens the new file through `context.onOpenFile` — "duplicate-and-
    /// modify" (design spec §6.3). No-op (returns `nil`) if duplication isn't wired
    /// (`context.duplicateComponent == nil`, true in tests/previews without write capability).
    @discardableResult
    func duplicateComponent(path: String) async -> ContentCreateResult? {
        guard let duplicateComponent = context.duplicateComponent else { return nil }
        let result = await duplicateComponent(path)
        if case .created(let filePath, _) = result {
            projectComponents = SiteFileTree.scan(siteRoot: context.sourceRoot)[.components] ?? []
            if let match = projectComponents.first(where: { relativePath(for: $0) == filePath }) {
                context.onOpenFile?(match)
            }
        }
        return result
    }

    /// Project-relative path of `file` under `context.sourceRoot` — the general form of the
    /// `relativePath` computed property below (which is always `relativePath(for: self.file)`).
    private func relativePath(for file: FileRef) -> String {
        let root = context.sourceRoot.path(percentEncoded: false)
        let full = file.url.path(percentEncoded: false)
        guard full.hasPrefix(root) else { return file.name }
        return String(full.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
```

- [ ] **Step 3: Simplify the existing `relativePath` computed property to reuse the new helper**

Replace the existing `relativePath` computed property (currently):

```swift
    /// Path of this component relative to the site's Source/ root.
    var relativePath: String {
        let root = context.sourceRoot.path(percentEncoded: false)
        let full = file.url.path(percentEncoded: false)
        guard full.hasPrefix(root) else { return file.name }
        return String(full.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
```

with:

```swift
    /// Path of this component relative to the site's Source/ root.
    var relativePath: String { relativePath(for: file) }
```

- [ ] **Step 4: Build to verify Tasks 2+3 compile together**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`. (`xcodegen generate` first if `Anglesite.xcodeproj` is stale/missing.)

- [ ] **Step 5: Run the full Swift test suite**

Run: `swift test --package-path .`
Expected: PASS, including Task 1's 5 new tests and Task 2's 1 new test.

- [ ] **Step 6: Commit Tasks 2 and 3 together** (Task 2's wiring doesn't compile standalone — see Task 2 Step 5's note)

```bash
git add Sources/AnglesiteApp/SiteWindowModel.swift Sources/AnglesiteApp/SiteWindow.swift Sources/AnglesiteApp/ComponentEditorModel.swift Tests/AnglesiteAppTests/SiteWindowModelTests.swift
git commit -m "feat(component-editor): wire duplicateComponent through SiteWindowModel/ComponentEditorContext (#495)"
```

---

### Task 4: Palette context menu

**Files:**
- Modify: `Sources/AnglesiteApp/ComponentEditorView.swift`

**Interfaces:**
- Consumes: `ComponentEditorModel.duplicateComponent(path:)` (Task 3); `ComponentPalette.Item.kind` (existing, `ComponentStructureEditBuilder.NodeSpec` — `.component(tag: String, componentPath: String)` is the case to match).
- Produces: no new public API — this is `paletteView(_:)`'s rendering only.

No unit test for this step — same reasoning as slice 5a's Tasks 3/4 (SwiftUI view bodies aren't independently unit-tested in this codebase; Task 3 already covers the testable logic). Verified by build (Step 2).

- [ ] **Step 1: Add the context menu**

In `Sources/AnglesiteApp/ComponentEditorView.swift`, in `paletteView(_:)`, find the `ForEach(items) { item in ... }` block:

```swift
                ForEach(items) { item in
                    VStack(spacing: 2) {
                        Image(systemName: item.systemImage)
                        Text(item.label).font(.caption2).lineLimit(1)
                    }
                    .frame(width: 84, height: 44)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    .draggable(OutlineDragPayload.insert(PaletteDragPayload(label: item.label, kind: item.kind)))
                }
```

Replace it with:

```swift
                ForEach(items) { item in
                    VStack(spacing: 2) {
                        Image(systemName: item.systemImage)
                        Text(item.label).font(.caption2).lineLimit(1)
                    }
                    .frame(width: 84, height: 44)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    .draggable(OutlineDragPayload.insert(PaletteDragPayload(label: item.label, kind: item.kind)))
                    .contextMenu {
                        if case .component(_, let componentPath) = item.kind {
                            Button("Duplicate & Modify") {
                                Task { await model.duplicateComponent(path: componentPath) }
                            }
                        }
                    }
                }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Run the full Swift test suite to confirm no regressions**

Run: `swift test --package-path .`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteApp/ComponentEditorView.swift
git commit -m "feat(component-editor): add Duplicate & Modify to palette context menu (#495)"
```

---

### Task 5: Manual GUI verification (best-effort — disclose honestly if blocked)

**Files:** none (verification only).

- [ ] **Step 1: Attempt GUI verification**

Follow the same approach as slice 5a's Task 5 (launch the app, open a site with a project component, right-click a palette item, confirm "Duplicate & Modify" appears only for project components — not for the curated HTML elements or Slot — click it, confirm a new file appears and opens in the editor with identical contents, confirm a second duplicate of the same original bumps to `Copy2`).

If GUI automation access is unavailable or denied (as it was for slice 5a in this session), do not retry the same denied request — record that verification was not completed and say so explicitly in the PR, per this repo's testing guidance (`AGENTS.md`: "if you can't test the UI, say so explicitly rather than claiming success").

---

### Task 6: Open the pull request

**Files:** none (git/gh only).

- [ ] **Step 1: Push the branch**

```bash
git push
```

(Same branch as slice 5a's PR — `claude/issue-495-fd0042` — already tracks `origin`.)

- [ ] **Step 2: Open the PR**

```bash
gh pr create --title "feat(component-editor): duplicate & modify a project component (#495)" --body "$(cat <<'EOF'
## Summary
- Adds "Duplicate & Modify" to the Component Editor palette's context menu for project components (design spec §6.3) — surfaced on the palette rather than `SiteNavigatorView`, since that navigator deliberately excludes non-page source files while the palette already lists every project component.
- Pure native Swift, no plugin/MCP change: `NativeContentOperations.duplicateComponent` follows the exact same read/rename/write/commit shape `duplicatePage`/`duplicatePost`/`createComponent` already use.
- Part of Component Editor slice 5 (#495). Together with the already-merged media-query/viewport PR, this closes out the app-only pieces; the `extract-component` plugin op + its app-side "Extract into Component…" UI remain as a final follow-up.

## Test plan
- [x] `swift test --package-path .` — new `NativeContentOperationsDuplicateComponentTests` (5 tests) and one `SiteWindowModelTests` no-site test pass, plus the full existing suite.
- [x] `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build` succeeds.
- [ ] Manual GUI verification: <fill in based on Task 5's actual outcome — either the steps you drove and observed, or an explicit note that GUI automation access was unavailable/denied and a human reviewer should click through before merging>

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Update issue #495**

This PR plus the already-merged media-query/viewport PR cover every app-only piece of #495. Do NOT remove the `🛠️ In Progress` label yet — the `extract-component` plugin op (sidecar PR, separately in progress) and its app-side consumer are still outstanding. Leave a comment on #495 noting what's landed and what remains, if not already tracked elsewhere.

---

## Self-Review Notes

- **Spec coverage:** design spec §6.3 item 3 ("duplicate-and-modify from the navigator context menu") → Tasks 1-4, with the navigator-vs-palette placement decision explicitly documented above (architecture section) since the spec text is genuinely ambiguous and `SiteNavigatorView` structurally can't show component files without a much larger, out-of-scope change.
- **Naming convention:** `duplicateComponent` deliberately does NOT prompt for a new name upfront (unlike a hypothetical "Save As") — it follows the exact same low-friction "auto-append Copy/CopyN, user renames after via the existing Rename mechanism if they want" convention `duplicatePage`/`duplicatePost` already established, for UX consistency.
- **Out of scope for this plan (tracked separately under #495):** `extract-component` plugin op + "Extract into Component…" UI (in progress in the sidecar repo as of this plan's writing).
