# `.anglesite` Package Model — Phase 4 (Per-Site Config Store) Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give each package an app-owned per-site config store in `Config/` — a `SiteConfigStore` over `Config/settings.plist` — and move chat history from the legacy `<site>/.anglesite/` location into `Config/chat-history.jsonl`, so app-owned state lives in the package (outside the `Source/` git repo) rather than app-global or in the source tree.

**Architecture:** A new `SiteConfigStore` actor reads/writes a small `SiteSettings` Codable as a plist in `Config/`. `ChatHistoryStore` is repointed from `siteDirectory/.anglesite/` to the package's `Config/` directory. Both are pure `AnglesiteCore` types with Swift Testing coverage; the App passes `site.configDirectory` (from P2) instead of `site.path`.

**Tech Stack:** Swift 5.10 / SwiftPM, Swift Testing, `PropertyListEncoder`/`Decoder`, `AnglesiteCore` actors.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-06-19-anglesite-package-model-design.md` §4 (per-site config store).
- **Depends on P1** (`AnglesitePackage.configURL`), **P2** (`Site.configDirectory`/`sourceDirectory`), **P3** (import migrates legacy `.anglesite/`→`Config/`).
- **Toolchain:** prefix with `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`.
- **CI reality:** logic + tests in `AnglesiteCore`; App glue verified by build.
- **`.site-config` stays in `Source/`** — it is template/plugin-owned (the plugin's pre-deploy check reads it). The app does NOT read it back today (only the scaffolder writes it). "Folding into the marker" (spec §4) means the **app's** per-site identity/preferences live in `Info.plist`/`settings.plist`; do NOT delete or relocate `.site-config`, or the plugin breaks.
- **Forward-looking schema:** `SiteSettings` starts minimal (spec §4: "mostly empty today"). Add fields only when a feature needs them — YAGNI.
- **Commit style:** Conventional Commits, scope `(#242)`, body ends `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

## File Structure

- `Sources/AnglesiteCore/SiteConfigStore.swift` — **create**: `SiteSettings` + `SiteConfigStore`.
- `Tests/AnglesiteCoreTests/SiteConfigStoreTests.swift` — **create**.
- `Sources/AnglesiteCore/ChatHistoryStore.swift` — **modify**: init takes `configDirectory:`; file path → `Config/chat-history.jsonl`.
- `Tests/AnglesiteCoreTests/ChatHistoryStoreTests.swift` — **modify**: update the `.anglesite/...` path assertions to `Config/...` (note: this is an XCTest holdout file; keep it XCTest, just update paths).
- `Sources/AnglesiteApp/SiteWindow.swift` — **modify**: construct `ChatHistoryStore(configDirectory: resolved.configDirectory)`.

---

### Task 1: `SiteConfigStore` over `Config/settings.plist`

**Files:**
- Create: `Sources/AnglesiteCore/SiteConfigStore.swift`
- Test: `Tests/AnglesiteCoreTests/SiteConfigStoreTests.swift`

**Interfaces:**
- Produces:
  - `struct SiteSettings: Sendable, Codable, Equatable { var displayName: String?; init(displayName: String? = nil) }`
  - `actor SiteConfigStore { init(configDirectory: URL, fileManager: FileManager = .default); func load() throws -> SiteSettings; func save(_ settings: SiteSettings) throws }`
  - `load()` returns a default (empty) `SiteSettings` when the file is absent.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import AnglesiteCore

struct SiteConfigStoreTests {
    private func tempConfigDir() throws -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("siteconfig-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Config", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test("load returns empty settings when the file is absent")
    func loadDefaultsWhenMissing() async throws {
        let dir = try tempConfigDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let store = SiteConfigStore(configDirectory: dir)
        let settings = try await store.load()
        #expect(settings == SiteSettings())
    }

    @Test("save then load round-trips settings through settings.plist")
    func saveLoadRoundTrips() async throws {
        let dir = try tempConfigDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let store = SiteConfigStore(configDirectory: dir)
        try await store.save(SiteSettings(displayName: "Acme HQ"))

        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("settings.plist").path))
        let loaded = try await store.load()
        #expect(loaded.displayName == "Acme HQ")
    }

    @Test("save creates the Config directory if it does not exist")
    func saveCreatesConfigDir() async throws {
        let parent = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("siteconfig-\(UUID().uuidString)", isDirectory: true)
        let dir = parent.appendingPathComponent("Config", isDirectory: true)   // not yet created
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = SiteConfigStore(configDirectory: dir)
        try await store.save(SiteSettings(displayName: "X"))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("settings.plist").path))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SiteConfigStoreTests`
Expected: FAIL — no `SiteConfigStore`/`SiteSettings`.

- [ ] **Step 3: Implement `Sources/AnglesiteCore/SiteConfigStore.swift`**

```swift
import Foundation

/// App-owned, per-site settings persisted inside the package's `Config/` directory (spec §4).
/// Deliberately minimal today — it exists so per-site state attaches to the package rather than
/// app-global `UserDefaults`. Add fields as features need them (YAGNI).
public struct SiteSettings: Sendable, Codable, Equatable {
    /// Owner-facing display name override. `nil` falls back to the package marker's displayName.
    public var displayName: String?

    public init(displayName: String? = nil) {
        self.displayName = displayName
    }
}

/// Reads/writes `Config/settings.plist` for one package. Per-window; owned by the site window.
public actor SiteConfigStore {
    private let fileURL: URL
    private let fileManager: FileManager

    public init(configDirectory: URL, fileManager: FileManager = .default) {
        self.fileURL = configDirectory.appendingPathComponent("settings.plist")
        self.fileManager = fileManager
    }

    /// Load settings, or a default (empty) `SiteSettings` when the file doesn't exist yet.
    public func load() throws -> SiteSettings {
        guard fileManager.fileExists(atPath: fileURL.path) else { return SiteSettings() }
        let data = try Data(contentsOf: fileURL)
        return try PropertyListDecoder().decode(SiteSettings.self, from: data)
    }

    /// Persist settings to `settings.plist` (XML plist, atomic), creating `Config/` if needed.
    public func save(_ settings: SiteSettings) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data = try encoder.encode(settings)
        try data.write(to: fileURL, options: [.atomic])
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SiteConfigStoreTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SiteConfigStore.swift Tests/AnglesiteCoreTests/SiteConfigStoreTests.swift
git commit -m "$(cat <<'EOF'
feat(#242): SiteConfigStore over Config/settings.plist

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Repoint `ChatHistoryStore` to `Config/`

**Files:**
- Modify: `Sources/AnglesiteCore/ChatHistoryStore.swift:44-56`
- Modify: `Tests/AnglesiteCoreTests/ChatHistoryStoreTests.swift` (path assertions)

**Interfaces:**
- Changes: `ChatHistoryStore.init(configDirectory: URL, fileManager:)` (was `siteDirectory:`); `fileURL` = `configDirectory/chat-history.jsonl` (no nested `.anglesite/`, since `Config/` is already the app-owned dir).

- [ ] **Step 1: Update the test to the new init + path** (`ChatHistoryStoreTests.swift` — XCTest holdout, keep XCTest)

In `setUp`, the temp dir now represents the Config directory. Replace the path assertion in `testAppendCreatesDirectoryAndFile`:

```swift
    func testAppendCreatesDirectoryAndFile() async throws {
        let store = ChatHistoryStore(configDirectory: tmpDir)
        try await store.append(.init(role: .user, content: "Hello"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("chat-history.jsonl").path))
    }
```

And update every other `ChatHistoryStore(siteDirectory: tmpDir)` in the file to `ChatHistoryStore(configDirectory: tmpDir)`. (The `.anglesite/chat-history.jsonl` path in any other assertion becomes `chat-history.jsonl`.)

- [ ] **Step 2: Run to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ChatHistoryStoreTests`
Expected: FAIL — `siteDirectory:` label no longer matches / path mismatch.

- [ ] **Step 3: Update `ChatHistoryStore.init`** (lines 44–56)

```swift
    public init(configDirectory: URL, fileManager: FileManager = .default) {
        // Config/ is already the app-owned per-site dir (no nested .anglesite/ — that was the
        // pre-package layout; P3 import migrates old history into Config/).
        self.fileURL = configDirectory.appendingPathComponent("chat-history.jsonl")
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }
```

The `append` method's directory creation (it currently creates the `.anglesite` parent) still works: it creates `fileURL.deletingLastPathComponent()` = `Config/`. Confirm the create-parent line uses `fileURL.deletingLastPathComponent()`; if it hardcodes `.anglesite`, change it to `fileURL.deletingLastPathComponent()`.

- [ ] **Step 4: Run to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ChatHistoryStoreTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/ChatHistoryStore.swift Tests/AnglesiteCoreTests/ChatHistoryStoreTests.swift
git commit -m "$(cat <<'EOF'
feat(#242): chat history lives in package Config/, not <site>/.anglesite/

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: App wires the config dir into the chat store

**Files:**
- Modify: `Sources/AnglesiteApp/SiteWindow.swift` (ChatModel/ChatHistoryStore construction, ~lines 462-502)

**Interfaces:**
- Consumes: `SiteStore.Site.configDirectory` (P2), `ChatHistoryStore(configDirectory:)`.

- [ ] **Step 1: Update the construction site**

Find where `ChatHistoryStore(siteDirectory:` is built in `SiteWindow.swift` and change it to:

```swift
        let history = ChatHistoryStore(configDirectory: resolved.configDirectory)
```

(Leave content/graph/preview/deploy on `resolved.sourceDirectory` from P2 — only chat history moves to `Config/`.) Grep `ChatHistoryStore(` across `Sources/AnglesiteApp` and `Sources/AnglesiteCore` to catch any other construction sites (e.g. intents/undo) and update each to `configDirectory:` using the relevant `Site.configDirectory`.

- [ ] **Step 2: Build both targets + full suite**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodegen generate && DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build && DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .`
Expected: BUILD SUCCEEDED; all Core/Intents/Bridge suites pass.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteApp Sources/AnglesiteCore
git commit -m "$(cat <<'EOF'
feat(#242): site window constructs ChatHistoryStore from package Config/

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage:** §4 per-site config store (`Config/settings.plist`) → Task 1. §4 chat history → `Config/` → Tasks 2–3. §4 `.site-config` folding → handled by constraint (app uses marker/settings; `.site-config` stays for the plugin) — documented, no code needed beyond P1/P2 already putting identity in the marker.

**Placeholder scan:** none — full code + tests for both Core types; App task is an exact construction-site swap.

**Risk flags:** the `ChatHistoryStore` init label change breaks every caller — grep `ChatHistoryStore(` and fix all. The `append` directory-create must use `fileURL.deletingLastPathComponent()`, not a hardcoded `.anglesite`. `SiteSettings` is intentionally tiny; resist adding speculative fields.

## Handoff to P5

P5 (docs) reconciles CLAUDE.md's "source of truth" wording with the now-shipped package model and updates `~/Sites`/layout references.
