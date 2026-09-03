# `.anglesite` Package Model — Phase 3 (Import / Export) Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add **File ▸ Import** (copy a plain Anglesite directory into a new `.anglesite` package's `Source/`, the migration path for pre-package sites) and **File ▸ Export** (copy a package's `Source/` working tree back out to a plain directory).

**Architecture:** Two pure, testable `AnglesiteCore` functions — `PackageTransfer.importDirectory(...)` and `PackageTransfer.exportSource(...)` — do all filesystem work with an injected `FileManager`. Thin SwiftUI menu glue runs the panels and records the imported package via `SiteStore`.

**Tech Stack:** Swift 5.10 / SwiftPM, Swift Testing, `FileManager` copy APIs, SwiftUI `CommandGroup`, `NSOpenPanel`/`NSSavePanel`.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-06-19-anglesite-package-model-design.md` §5 (Import/Export).
- **Depends on P1** (`AnglesitePackage`) and **P2** (`SiteStore.record`, package-shaped `Site`).
- **Toolchain:** prefix `swift test`/`xcodebuild`/`xcodegen` with `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`.
- **CI reality:** logic in `AnglesiteCore` (Swift Testing); App glue verified by build, not unit tests.
- **Import semantics (verbatim from spec §5):** copy the chosen directory's tree into the new package's `Source/`, **preserving an existing `.git`**; migrate any `<dir>/.anglesite/` into the package's `Config/`; write a fresh `Info.plist` (new UUID); leave the original directory untouched.
- **Export semantics (verbatim from spec §5):** copy `<pkg>/Source/` to a chosen plain directory; **default excludes `node_modules/`**; option to include or exclude `.git`.
- **Commit style:** Conventional Commits, scope `(#242)`, body ends `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

## File Structure

- `Sources/AnglesiteCore/PackageTransfer.swift` — **create**: `importDirectory`, `exportSource`.
- `Tests/AnglesiteCoreTests/PackageTransferTests.swift` — **create**.
- `Sources/AnglesiteApp/SiteActions.swift` — **modify**: add `importPackage()` and `exportSource(of:)` panel helpers.
- `Sources/AnglesiteApp/AnglesiteApp.swift` — **modify**: add File ▸ Import / File ▸ Export menu items.

---

### Task 1: `PackageTransfer.importDirectory`

**Files:**
- Create: `Sources/AnglesiteCore/PackageTransfer.swift`
- Test: `Tests/AnglesiteCoreTests/PackageTransferTests.swift`

**Interfaces:**
- Consumes: `AnglesitePackage` (P1).
- Produces: `enum PackageTransfer { static func importDirectory(_ sourceDir: URL, toPackageAt packageURL: URL, displayName: String, fileManager: FileManager) throws -> AnglesitePackage }`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import AnglesiteCore

struct PackageTransferTests {
    private func tempDir() throws -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pkg-transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test("import copies the dir tree into Source/, preserves .git, migrates .anglesite/ to Config/, writes a fresh marker, leaves the original untouched")
    func importCopiesIntoSource() throws {
        let fm = FileManager.default
        let root = try tempDir(); defer { try? fm.removeItem(at: root) }

        // A plain Anglesite site dir with a git repo, sentinels, and a legacy .anglesite/ history.
        let src = root.appendingPathComponent("legacy-site", isDirectory: true)
        try fm.createDirectory(at: src.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("[core]".utf8).write(to: src.appendingPathComponent(".git/config"))
        for s in ProjectValidator.requiredSentinels {
            try Data("{}".utf8).write(to: src.appendingPathComponent(s))
        }
        try fm.createDirectory(at: src.appendingPathComponent(".anglesite"), withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: src.appendingPathComponent(".anglesite/chat-history.jsonl"))

        let pkgURL = root.appendingPathComponent("Imported.anglesite", isDirectory: true)
        let pkg = try PackageTransfer.importDirectory(src, toPackageAt: pkgURL, displayName: "Imported", fileManager: fm)

        // Source/ holds the copied tree incl. .git; sentinels present.
        #expect(fm.fileExists(atPath: pkg.sourceURL.appendingPathComponent(".git/config").path))
        #expect(pkg.sourceValidation(fileManager: fm).isValid)
        // Legacy .anglesite/ migrated to Config/, and removed from Source/.
        #expect(fm.fileExists(atPath: pkg.configURL.appendingPathComponent("chat-history.jsonl").path))
        #expect(!fm.fileExists(atPath: pkg.sourceURL.appendingPathComponent(".anglesite").path))
        // Fresh marker.
        #expect((try? pkg.readMarker().displayName) == "Imported")
        // Original untouched.
        #expect(fm.fileExists(atPath: src.appendingPathComponent(".anglesite/chat-history.jsonl").path))
    }

    @Test("import throws when the source is not a directory")
    func importRejectsNonDirectory() throws {
        let fm = FileManager.default
        let root = try tempDir(); defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("not-a-dir.txt")
        try Data("x".utf8).write(to: file)
        #expect(throws: (any Error).self) {
            _ = try PackageTransfer.importDirectory(file, toPackageAt: root.appendingPathComponent("X.anglesite"), displayName: "X", fileManager: fm)
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter PackageTransferTests`
Expected: FAIL — no `PackageTransfer`.

- [ ] **Step 3: Implement `Sources/AnglesiteCore/PackageTransfer.swift`**

```swift
import Foundation

/// Copies between plain Anglesite directories and `.anglesite` packages (spec §5).
///
/// Import (dir → package) and Export (package → dir) are the symmetric migration paths: the app
/// never edits a plain directory in place, so Import copies into a fresh package and Export copies
/// the package's `Source/` working tree back out.
public enum PackageTransfer {
    public enum TransferError: Error, Equatable, Sendable {
        case sourceNotADirectory(URL)
        case destinationExists(URL)
    }

    /// Copy `sourceDir`'s tree into a new package's `Source/`, preserving an existing `.git`,
    /// migrating any `<sourceDir>/.anglesite/` into the package's `Config/`, and stamping a fresh
    /// `Info.plist` marker. The original `sourceDir` is left untouched.
    @discardableResult
    public static func importDirectory(
        _ sourceDir: URL,
        toPackageAt packageURL: URL,
        displayName: String,
        fileManager: FileManager = .default
    ) throws -> AnglesitePackage {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceDir.path, isDirectory: &isDir), isDir.boolValue else {
            throw TransferError.sourceNotADirectory(sourceDir)
        }
        guard !fileManager.fileExists(atPath: packageURL.path) else {
            throw TransferError.destinationExists(packageURL)
        }

        let pkg = AnglesitePackage(url: packageURL)
        try fileManager.createDirectory(at: pkg.url, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: pkg.configURL, withIntermediateDirectories: true)

        // Copy the whole tree (incl. .git) into Source/. copyItem creates Source/.
        try fileManager.copyItem(at: sourceDir, to: pkg.sourceURL)

        // Migrate a legacy hidden .anglesite/ dir from Source/ into Config/.
        let legacy = pkg.sourceURL.appendingPathComponent(".anglesite", isDirectory: true)
        if fileManager.fileExists(atPath: legacy.path) {
            let contents = try fileManager.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)
            for item in contents {
                let dest = pkg.configURL.appendingPathComponent(item.lastPathComponent)
                if fileManager.fileExists(atPath: dest.path) { try fileManager.removeItem(at: dest) }
                try fileManager.moveItem(at: item, to: dest)
            }
            try fileManager.removeItem(at: legacy)
        }

        try pkg.writeMarker(.init(displayName: displayName), fileManager: fileManager)
        return pkg
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter PackageTransferTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/PackageTransfer.swift Tests/AnglesiteCoreTests/PackageTransferTests.swift
git commit -m "$(cat <<'EOF'
feat(#242): PackageTransfer.importDirectory (plain dir -> .anglesite package)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `PackageTransfer.exportSource`

**Files:**
- Modify: `Sources/AnglesiteCore/PackageTransfer.swift`
- Test: `Tests/AnglesiteCoreTests/PackageTransferTests.swift` (append)

**Interfaces:**
- Produces: `static func exportSource(of package: AnglesitePackage, to destinationDir: URL, includeGit: Bool, fileManager: FileManager) throws`

- [ ] **Step 1: Write the failing tests** (append, inside the struct)

```swift
    private func makePackageWithSource(in root: URL) throws -> AnglesitePackage {
        let fm = FileManager.default
        let (pkg, _) = try AnglesitePackage.createSkeleton(at: root.appendingPathComponent("Acme.anglesite", isDirectory: true), displayName: "Acme")
        try Data("// astro".utf8).write(to: pkg.sourceURL.appendingPathComponent("astro.config.ts"))
        try fm.createDirectory(at: pkg.sourceURL.appendingPathComponent("node_modules/foo"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: pkg.sourceURL.appendingPathComponent("node_modules/foo/index.js"))
        try fm.createDirectory(at: pkg.sourceURL.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("[core]".utf8).write(to: pkg.sourceURL.appendingPathComponent(".git/config"))
        return pkg
    }

    @Test("export copies Source/ out, always excluding node_modules; .git excluded by default")
    func exportExcludesByDefault() throws {
        let fm = FileManager.default
        let root = try tempDir(); defer { try? fm.removeItem(at: root) }
        let pkg = try makePackageWithSource(in: root)
        let dest = root.appendingPathComponent("exported", isDirectory: true)

        try PackageTransfer.exportSource(of: pkg, to: dest, includeGit: false, fileManager: fm)

        #expect(fm.fileExists(atPath: dest.appendingPathComponent("astro.config.ts").path))
        #expect(!fm.fileExists(atPath: dest.appendingPathComponent("node_modules").path))
        #expect(!fm.fileExists(atPath: dest.appendingPathComponent(".git").path))
    }

    @Test("export keeps .git when includeGit is true")
    func exportKeepsGitWhenRequested() throws {
        let fm = FileManager.default
        let root = try tempDir(); defer { try? fm.removeItem(at: root) }
        let pkg = try makePackageWithSource(in: root)
        let dest = root.appendingPathComponent("exported-git", isDirectory: true)

        try PackageTransfer.exportSource(of: pkg, to: dest, includeGit: true, fileManager: fm)

        #expect(fm.fileExists(atPath: dest.appendingPathComponent(".git/config").path))
        #expect(!fm.fileExists(atPath: dest.appendingPathComponent("node_modules").path))
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter PackageTransferTests`
Expected: FAIL — no `exportSource`.

- [ ] **Step 3: Implement `exportSource` in `PackageTransfer.swift`** (add to the enum)

```swift
    /// Copy `package`'s `Source/` working tree to `destinationDir`. Always omits `node_modules/`;
    /// omits `.git` unless `includeGit`. `destinationDir` must not already exist.
    public static func exportSource(
        of package: AnglesitePackage,
        to destinationDir: URL,
        includeGit: Bool,
        fileManager: FileManager = .default
    ) throws {
        guard !fileManager.fileExists(atPath: destinationDir.path) else {
            throw TransferError.destinationExists(destinationDir)
        }
        // Copy wholesale, then prune the excluded top-level entries — simpler and safer than a
        // filtered deep enumerate, and the excluded dirs are always top-level in an Astro project.
        try fileManager.copyItem(at: package.sourceURL, to: destinationDir)
        let nodeModules = destinationDir.appendingPathComponent("node_modules", isDirectory: true)
        if fileManager.fileExists(atPath: nodeModules.path) { try fileManager.removeItem(at: nodeModules) }
        if !includeGit {
            let git = destinationDir.appendingPathComponent(".git", isDirectory: true)
            if fileManager.fileExists(atPath: git.path) { try fileManager.removeItem(at: git) }
        }
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter PackageTransferTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/PackageTransfer.swift Tests/AnglesiteCoreTests/PackageTransferTests.swift
git commit -m "$(cat <<'EOF'
feat(#242): PackageTransfer.exportSource (package Source/ -> plain dir)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: File ▸ Import / File ▸ Export menu glue

**Files:**
- Modify: `Sources/AnglesiteApp/SiteActions.swift` (add helpers)
- Modify: `Sources/AnglesiteApp/AnglesiteApp.swift:121-143` (add menu items)

**Interfaces:**
- Consumes: `PackageTransfer`, `SiteStore.record`, `AppSettings.sitesRoot`.

- [ ] **Step 1: Add `importPackage()` to `SiteActions`**

```swift
    /// Pick a plain Anglesite directory, choose where to save the new package, copy it in, and
    /// register the package. Returns the new site, or nil if either panel was cancelled.
    static func importPackage() async throws -> SiteStore.Site? {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        picker.prompt = "Choose"
        picker.message = "Choose an existing Anglesite site folder to import."
        guard picker.runModal() == .OK, let sourceDir = picker.url else { return nil }

        let name = sourceDir.deletingPathExtension().lastPathComponent
        let save = NSSavePanel()
        save.message = "Save the imported site package."
        save.nameFieldStringValue = "\(name).anglesite"
        save.directoryURL = AppSettings.shared.sitesRoot
        guard save.runModal() == .OK, let dest = save.url else { return nil }

        do {
            let pkg = try PackageTransfer.importDirectory(sourceDir, toPackageAt: dest, displayName: name)
            let site = try await SiteStore.shared.record(pkg)
            #if ANGLESITE_MAS
            if let bm = try? SecurityScopedBookmark.create(for: pkg.url) {
                try await SiteStore.shared.setBookmark(bm, for: site.id)
            }
            #endif
            return site
        } catch {
            throw ImportError(folderName: sourceDir.lastPathComponent, underlying: error)
        }
    }

    /// Export the given site's source tree to a chosen folder.
    static func exportSource(of site: SiteStore.Site, includeGit: Bool) {
        let save = NSSavePanel()
        save.message = "Export this site's source files to a folder."
        save.nameFieldStringValue = site.name
        guard save.runModal() == .OK, let dest = save.url else { return }
        do {
            try PackageTransfer.exportSource(of: AnglesitePackage(url: site.packageURL), to: dest, includeGit: includeGit)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
```

- [ ] **Step 2: Add the menu items in `AnglesiteApp.swift`**

Inside the `CommandGroup(replacing: .newItem)` block (after the "Open Recent" menu, before the group closes), add:

```swift
                Divider()
                Button("Import Site…") {
                    Task { @MainActor in
                        if let site = try? await SiteActions.importPackage() {
                            openWindow(value: site.id)
                        }
                    }
                }
```

Export operates on the focused site window; add it via a `CommandGroup(after: .saveItem)` (a site window exposes its `SiteStore.Site` through the existing focused-value/router mechanism the app already uses — wire it to whatever the window exposes; if no focused-site value exists yet, gate Export behind the launcher's current selection). Minimum viable: add the menu item and disable it when no site is focused.

```swift
        .commands {
            CommandGroup(after: .importExport) {
                Button("Export Site Source…") {
                    if let site = WindowRouter.shared.focusedSite {   // see note
                        SiteActions.exportSource(of: site, includeGit: false)
                    }
                }
                .disabled(WindowRouter.shared.focusedSite == nil)
            }
        }
```

> **Note for the implementer:** the app has no `focusedSite` accessor today. Either (a) add a `@Published var focusedSite: SiteStore.Site?` to `WindowRouter` that `SiteWindow` sets in `loadAndStart`/clears in `onDisappear`, or (b) put Export in the site window's own toolbar/menu instead of the global File menu. Pick (a) if a global menu item is wanted; it's a few lines. Confirm with the controller if unsure.

- [ ] **Step 3: Build both targets**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodegen generate && DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build && DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build`
Expected: BUILD SUCCEEDED for both.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteApp
git commit -m "$(cat <<'EOF'
feat(#242): File menu Import (dir->package) and Export (package->dir)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage:** §5 Import (copy into Source/, preserve .git, migrate .anglesite/→Config/, fresh marker, original untouched) → Task 1. §5 Export (copy Source/ out, exclude node_modules, optional .git) → Task 2. Menu wiring → Task 3.

**Placeholder scan:** none in Core tasks (full code + tests). Task 3 contains ONE flagged design choice (`focusedSite` accessor) with two concrete options and a "confirm with controller" — resolve it during implementation; not a silent placeholder.

**Risk flags:** `copyItem` fails if the destination exists — both functions guard with `destinationExists`. Import preserves `.git` by copying the whole tree (no filtering on import, unlike export). On MAS, Import's `NSSavePanel` destination carries a user grant; the bookmark is minted on the package URL.

## Handoff to P4

P4 (config store) consumes the migrated `Config/` layout this phase produces on import. It adds `SiteConfigStore` (`Config/settings.plist`) and repoints `ChatHistoryStore` to `Config/chat-history.jsonl` (where import now places legacy history).
