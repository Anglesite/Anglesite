# Share extension: post the current Safari page — Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user share the current Safari page into Anglesite (Save Draft or Publish as a link post) without the main app being frontmost, via a new macOS Share Extension target.

**Architecture:** A new `app-extension` Xcode target (`AnglesiteShareExtension`, mirroring the existing `AnglesiteQuickLookPreview`/`AnglesiteQuickLookThumbnail` extensions) runs as a separate sandboxed process embedded in `Anglesite.app`. It has no visibility into the main app's own sandbox container, so it can't read `SiteStore`'s `recents.json` or resolve the bookmarks stored there. Instead: an App Group (`group.io.dwk.anglesite`) gives the main app and the extension a shared container. Whenever `SiteStore` persists a bookmark, it also best-effort publishes a trimmed `{id, name, bookmarkData, lastSeen}` manifest into that shared container (the canonical Apple pattern for handing a sandboxed extension direct file access to a resource the container app already has permission for — approved by the owner on issue #1450, 2026-08-15). The extension reads that manifest to list sites and resolve a chosen site's folder access, then writes the entry through the same `ContentCreationWorkflow`/`LinkPostImageCapture` path the app's own Quick Capture launcher flow already uses (#531), via a shared `LinkPostCreation` helper extracted from `QuickCapture.createLinkPost` so both callers run identical logic.

**Tech Stack:** Swift 6.4 / SwiftUI (extension UI), AppKit (`NSExtensionRequestHandling`), Swift Testing (Core-layer tests), XcodeGen (`project.yml`).

## Global Constraints

- macOS 27+ / Xcode 27+ (Swift 6.4) — matches the rest of the app (`AGENTS.md`/`CLAUDE.md` ▸ "Build target").
- No third-party frameworks — Apple frameworks only (`CONTRIBUTING.md` ▸ "Code guidelines").
- The default Debug entitlements files must stay buildable with **no Apple Developer account** (`CONTRIBUTING.md`/`README.md` promise). Any entitlement that needs a real Apple Developer portal capability (App Groups, like the existing iCloud/associated-domains/keychain-sharing capabilities) must be opt-in via the `xcconfig/Signing-Debug.local.xcconfig` indirection pattern, never in the default file.
- Conventional commits, ≤72-char subject, PR body from `.github/PULL_REQUEST_TEMPLATE.md`'s exact headings (Summary / Paired PR check / Test plan), `Closes #1450` (`CONTRIBUTING.md` ▸ "Commits and pull requests").
- Every spawned subprocess's output stays visible — not applicable here (no new subprocess spawning), but any new logging must not silently swallow output (`CONTRIBUTING.md` ▸ "Code guidelines").
- Failures in the sharing/publish path must be **best-effort** — never turn a bookmark mutation, or a link-post create, into a hard failure just because sharing itself failed (mirrors `LinkPostImageCapture`'s established rule in this codebase).
- This plan produces working, testable Core-layer software (Tasks 1–4) independent of the Xcode/entitlements/UI work (Tasks 5–8) — Tasks 1–4 can be verified with `swift test` alone before touching `project.yml`.
- **Real MAS-signed verification is out of scope for this plan.** Registering the `group.io.dwk.anglesite` App Group capability in the Apple Developer portal, and confirming the extension actually appears in Safari's Share menu and can resolve bookmarks end-to-end, requires a real signing Team and can only be done by the repo owner on a real device (per the owner's own issue comment: "Final MAS-signing behavior should be verified on a real signed build before ship"). This plan's Task 9 documents exactly what that manual follow-up needs to check.

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/AnglesiteCore/ShareExtension/SharedContainer.swift` | Resolves the App Group container URL (nil-safe: nil when the entitlement/capability isn't present). |
| `Sources/AnglesiteCore/ShareExtension/SharedSiteRegistry.swift` | `SharedSite` model + pure publish/read of the JSON manifest against an injected directory URL. |
| `Sources/AnglesiteCore/ShareExtension/ShareExtensionSiteAccess.swift` | Extension-side counterpart to `SiteAccess`: lists shared sites, brackets bookmark-resolved folder access. |
| `Sources/AnglesiteCore/LinkPostCreation.swift` | The create-entry-plus-card-image logic, extracted so the app and the extension share one implementation. |
| `Sources/AnglesiteCore/SiteStore.swift` | *(modify)* `persist()` also best-effort republishes the shared manifest; new `sharedRegistryDirectory` init param. |
| `Sources/AnglesiteApp/QuickCaptureSheet.swift` | *(modify)* `QuickCapture.createLinkPost` becomes a thin wrapper over `LinkPostCreation.create`. |
| `Sources/AnglesiteShareExtension/ShareViewController.swift` | `NSExtensionRequestHandling` entry point: extracts the shared URL/title, hosts the SwiftUI compose view. |
| `Sources/AnglesiteShareExtension/ShareExtensionInputExtractor.swift` | Pulls a URL + title out of the `NSExtensionContext` Safari hands the extension. |
| `Sources/AnglesiteShareExtension/ShareComposeModel.swift` | `@Observable` state: site list, metadata fetch, create/publish orchestration. |
| `Sources/AnglesiteShareExtension/ShareComposeView.swift` | SwiftUI compose UI (title, commentary, site picker, Cancel/Save Draft/Publish). |
| `Resources/ShareExtension/Info.plist` | `NSExtension` descriptor: share-services extension point, web-page activation rule. |
| `Resources/ShareExtension/AnglesiteShareExtension.entitlements` | Release entitlements (includes the App Group). |
| `Resources/ShareExtension/AnglesiteShareExtension-Debug.entitlements` | Default, CI-safe Debug entitlements (no App Group). |
| `Resources/ShareExtension/AnglesiteShareExtension-Debug-AppGroup.entitlements` | Opt-in Debug entitlements (with App Group) for a local real-Team build. |
| `Resources/Anglesite.entitlements`, `Resources/Anglesite-Debug-iCloud.entitlements` | *(modify)* add the same App Group array. |
| `project.yml` | *(modify)* new `AnglesiteShareExtension` target, embedded in `Anglesite`. |
| `xcconfig/Signing-Debug.xcconfig`, `xcconfig/Signing-Debug.local.xcconfig.example` | *(modify)* new `ANGLESITE_SHARE_EXTENSION_DEBUG_ENTITLEMENTS` indirection + documentation. |

---

### Task 1: `SharedContainer` + `SharedSiteRegistry` (Core, portable)

**Files:**
- Create: `Sources/AnglesiteCore/ShareExtension/SharedContainer.swift`
- Create: `Sources/AnglesiteCore/ShareExtension/SharedSiteRegistry.swift`
- Test: `Tests/AnglesiteCoreTests/SharedSiteRegistryTests.swift`

**Interfaces:**
- Produces: `public enum SharedContainer { static let appGroupIdentifier: String; static func url(fileManager: FileManager = .default) -> URL? }`
- Produces: `public struct SharedSite: Sendable, Codable, Equatable, Identifiable { let id: String; let name: String; let bookmarkData: Data; let lastSeen: Date }`
- Produces: `public enum SharedSiteRegistry { static func publish(_ sites: [SharedSite], to directory: URL, fileManager: FileManager = .default); static func read(from directory: URL, fileManager: FileManager = .default) -> [SharedSite] }`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/AnglesiteCoreTests/SharedSiteRegistryTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

struct SharedSiteRegistryTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anglesite-shared-registry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("read returns empty array when nothing has been published")
    func readEmptyByDefault() throws {
        let dir = try tempDir()
        #expect(SharedSiteRegistry.read(from: dir).isEmpty)
    }

    @Test("publish then read round-trips, sorted most-recently-seen first")
    func publishReadRoundTrip() throws {
        let dir = try tempDir()
        let older = SharedSite(id: "a", name: "Alpha", bookmarkData: Data([1]), lastSeen: Date(timeIntervalSince1970: 100))
        let newer = SharedSite(id: "b", name: "Bravo", bookmarkData: Data([2]), lastSeen: Date(timeIntervalSince1970: 200))
        SharedSiteRegistry.publish([older, newer], to: dir)
        let read = SharedSiteRegistry.read(from: dir)
        #expect(read.map(\.id) == ["b", "a"])
        #expect(read.first?.bookmarkData == Data([2]))
    }

    @Test("publish overwrites a previous manifest rather than appending")
    func publishOverwrites() throws {
        let dir = try tempDir()
        SharedSiteRegistry.publish([SharedSite(id: "a", name: "Alpha", bookmarkData: Data(), lastSeen: Date())], to: dir)
        SharedSiteRegistry.publish([SharedSite(id: "b", name: "Bravo", bookmarkData: Data(), lastSeen: Date())], to: dir)
        #expect(SharedSiteRegistry.read(from: dir).map(\.id) == ["b"])
    }

    @Test("publish to an unwritable directory does not throw")
    func publishBestEffort() throws {
        // A file (not a directory) at this path makes createDirectory fail — publish must swallow it.
        let dir = try tempDir()
        let blocker = dir.appendingPathComponent("blocked")
        try Data().write(to: blocker)
        let blockedDir = blocker.appendingPathComponent("nested", isDirectory: true)
        SharedSiteRegistry.publish([SharedSite(id: "a", name: "Alpha", bookmarkData: Data(), lastSeen: Date())], to: blockedDir)
        // No crash/throw reaching here is the assertion.
    }

    @Test("SharedContainer.url returns nil without the App Group entitlement")
    func containerURLNilInTests() {
        // Test/CI processes never carry the application-groups entitlement.
        #expect(SharedContainer.url() == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter SharedSiteRegistryTests`
Expected: FAIL — `SharedSiteRegistry`/`SharedSite`/`SharedContainer` not found in scope.

- [ ] **Step 3: Write `SharedContainer.swift`**

```swift
import Foundation

/// Resolves the App Group container both the main app and the share extension are members of
/// (#1450). `nil` whenever the App Group entitlement/capability isn't present — every ad-hoc/
/// no-Team Debug build, and any environment (including `swift test`) without the real
/// provisioning profile this needs. Every caller treats `nil` as "sharing is unavailable right
/// now", never a crash — matches this codebase's established best-effort rule for optional
/// capabilities.
public enum SharedContainer {
    /// Must match `com.apple.security.application-groups` in both
    /// `Resources/Anglesite*.entitlements` and
    /// `Resources/ShareExtension/AnglesiteShareExtension*.entitlements`.
    public static let appGroupIdentifier = "group.io.dwk.anglesite"

    /// The directory the shared site manifest lives in, or `nil` if the App Group isn't
    /// available to this process.
    public static func url(fileManager: FileManager = .default) -> URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent("Library/Application Support/Anglesite", isDirectory: true)
    }
}
```

- [ ] **Step 4: Write `SharedSiteRegistry.swift`**

```swift
import Foundation

/// One entry in the share-extension-visible site manifest — the trimmed subset of
/// `SiteStore.Site` a share extension needs to list sites and resolve folder access (#1450).
public struct SharedSite: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let bookmarkData: Data
    public let lastSeen: Date

    public init(id: String, name: String, bookmarkData: Data, lastSeen: Date) {
        self.id = id
        self.name = name
        self.bookmarkData = bookmarkData
        self.lastSeen = lastSeen
    }
}

/// Publishes/reads the share-extension site manifest, a single JSON file in the App Group
/// container. The main app calls `publish` whenever `SiteStore` persists; the share extension —
/// a separate sandboxed process with no visibility into the main app's own container — calls
/// `read` to list sites and resolve a chosen site's bookmark.
///
/// Deliberately dumb: no actor, no caching — every operation is a single file read/write against
/// an injected directory URL, so tests exercise it against a plain temp directory with no App
/// Group entitlement required.
public enum SharedSiteRegistry {
    private static let manifestFilename = "shared-sites.json"

    /// Best-effort publish, most-recently-seen first (mirrors `SiteStore`'s own MRU order, so the
    /// extension's default site pick matches the app's). Never throws: a write failure (e.g. the
    /// App Group container is unavailable, as on every ad-hoc Debug build with no real Team) just
    /// means the extension has nothing to list, not a broken app.
    public static func publish(_ sites: [SharedSite], to directory: URL, fileManager: FileManager = .default) {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let sorted = sites.sorted { $0.lastSeen > $1.lastSeen }
            let data = try encoder.encode(sorted)
            try data.write(to: directory.appendingPathComponent(manifestFilename), options: [.atomic])
        } catch {
            // Best-effort (#1450, mirrors LinkPostImageCapture's rule): sharing is a bonus
            // feature, never a reason to fail whatever bookmark mutation triggered this publish.
        }
    }

    /// Reads the manifest. Empty array (never throws) when the file is absent or unreadable — the
    /// extension shows "no sites" rather than crashing when the app hasn't published yet, or the
    /// App Group isn't provisioned.
    public static func read(from directory: URL, fileManager: FileManager = .default) -> [SharedSite] {
        let url = directory.appendingPathComponent(manifestFilename)
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? decoder.decode([SharedSite].self, from: data)) ?? []
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --package-path . --filter SharedSiteRegistryTests`
Expected: PASS (5 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/ShareExtension/SharedContainer.swift \
        Sources/AnglesiteCore/ShareExtension/SharedSiteRegistry.swift \
        Tests/AnglesiteCoreTests/SharedSiteRegistryTests.swift
git commit -m "feat(#1450): add share-extension site manifest publish/read"
```

---

### Task 2: Wire `SiteStore` to publish the shared manifest

**Files:**
- Modify: `Sources/AnglesiteCore/SiteStore.swift`
- Test: `Tests/AnglesiteCoreTests/SiteStoreTests.swift`

**Interfaces:**
- Consumes: `SharedSite` / `SharedSiteRegistry.publish` (Task 1), `SharedContainer.url` (Task 1).
- Produces: `SiteStore.init(persistenceURL:fileManager:sharedRegistryDirectory:)` — new optional trailing param, defaults to `SharedContainer.url(fileManager: fileManager)` when omitted.

- [ ] **Step 1: Write the failing test**

Add to `Tests/AnglesiteCoreTests/SiteStoreTests.swift` (same file, same fixtures as the existing tests — `tempDir`/`fileManager`/`makeValidPackage` already exist there):

```swift
    @Test("setBookmark republishes the shared manifest for sites with a bookmark")
    func setBookmarkPublishesSharedManifest() async throws {
        let pkg = try makeValidPackage(named: "alpha")
        let sharedDir = tempDir.appendingPathComponent("shared", isDirectory: true)
        let store = SiteStore(persistenceURL: persistenceURL, sharedRegistryDirectory: sharedDir)
        let site = try await store.record(pkg)

        // record() alone (no bookmark yet) must not publish an entry for this site.
        #expect(SharedSiteRegistry.read(from: sharedDir).isEmpty)

        try await store.setBookmark(Data([9, 9]), for: site.id)

        let shared = SharedSiteRegistry.read(from: sharedDir)
        #expect(shared.map(\.id) == [site.id])
        #expect(shared.first?.bookmarkData == Data([9, 9]))
        #expect(shared.first?.name == "alpha")
    }

    @Test("removing a site drops it from the shared manifest")
    func removePublishesSharedManifest() async throws {
        let pkg = try makeValidPackage(named: "alpha")
        let sharedDir = tempDir.appendingPathComponent("shared", isDirectory: true)
        let store = SiteStore(persistenceURL: persistenceURL, sharedRegistryDirectory: sharedDir)
        let site = try await store.record(pkg)
        try await store.setBookmark(Data([1]), for: site.id)
        #expect(SharedSiteRegistry.read(from: sharedDir).count == 1)

        try await store.remove(id: site.id)
        #expect(SharedSiteRegistry.read(from: sharedDir).isEmpty)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter SiteStoreTests`
Expected: FAIL — `SiteStore.init` has no `sharedRegistryDirectory` parameter (compile error).

- [ ] **Step 3: Modify `SiteStore.swift`**

Change the initializer (around line 174) and add a private property + helper, then call the helper from `persist()`:

```swift
    private let fileManager: FileManager
    private let persistenceURL: URL
    /// Where to best-effort mirror the registry for the share extension (#1450). `nil` means
    /// sharing is unavailable (no App Group entitlement) — every publish call becomes a no-op.
    private let sharedRegistryDirectory: URL?
```

```swift
    public init(
        persistenceURL: URL? = nil,
        fileManager: FileManager = .default,
        sharedRegistryDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.persistenceURL = persistenceURL ?? Self.defaultPersistenceURL(fileManager: fileManager)
        self.sharedRegistryDirectory = sharedRegistryDirectory ?? SharedContainer.url(fileManager: fileManager)
    }
```

Then at the end of `persist()`:

```swift
    private func persist() throws {
        let dir = persistenceURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(sites)
        try data.write(to: persistenceURL, options: [.atomic])
        publishSharedRegistry()
    }

    /// Best-effort mirror of the registry into the App Group container so the share extension
    /// (#1450) can list sites and resolve their bookmarks — a completely separate sandboxed
    /// process with no visibility into this app's own container. No-op when
    /// `sharedRegistryDirectory` is `nil`. Never throws: sharing is a bonus, never a reason to
    /// fail whatever mutation just called `persist()`.
    private func publishSharedRegistry() {
        guard let sharedRegistryDirectory else { return }
        let shared = sites.compactMap { site -> SharedSite? in
            guard let bookmarkData = site.bookmarkData else { return nil }
            return SharedSite(id: site.id, name: site.name, bookmarkData: bookmarkData, lastSeen: site.lastSeen)
        }
        SharedSiteRegistry.publish(shared, to: sharedRegistryDirectory, fileManager: fileManager)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter SiteStoreTests`
Expected: PASS (all `SiteStoreTests` cases, including the two new ones).

- [ ] **Step 5: Run the full Core suite to check for regressions**

Run: `swift test --package-path .`
Expected: PASS — `SiteStoreRecentsTests`, `SiteAccessTests`, etc. unaffected (they construct `SiteStore` without the new param, which defaults through `SharedContainer.url()` → `nil` in the test environment, so `publishSharedRegistry()` is a no-op for them).

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/SiteStore.swift Tests/AnglesiteCoreTests/SiteStoreTests.swift
git commit -m "feat(#1450): publish shared site manifest on every SiteStore persist"
```

---

### Task 3: `ShareExtensionSiteAccess`

**Files:**
- Create: `Sources/AnglesiteCore/ShareExtension/ShareExtensionSiteAccess.swift`
- Test: `Tests/AnglesiteCoreTests/ShareExtensionSiteAccessTests.swift`

**Interfaces:**
- Consumes: `SharedSite`, `SharedSiteRegistry.read` (Task 1); `SecurityScopedBookmark`/`PlatformSecurityScopedBookmark` (existing, `Sources/AnglesiteCore/Platform/SecurityScopedBookmark.swift`); `AnglesitePackage` (`AnglesiteSiteModel`).
- Produces: `public enum ShareExtensionSiteAccess { enum AccessError: Error, Sendable, Equatable { case unavailable, siteNotFound, noGrant(String) }; static func listSites(directory: URL? = SharedContainer.url(), fileManager: FileManager = .default) -> [SharedSite]; static func withScopedAccess<T: Sendable>(toSiteID: String, directory: URL? = SharedContainer.url(), fileManager: FileManager = .default, _ body: (URL) async -> T) async throws -> T }`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/AnglesiteCoreTests/ShareExtensionSiteAccessTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

struct ShareExtensionSiteAccessTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anglesite-share-access-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("listSites returns an empty array when the directory is nil")
    func listSitesNilDirectory() {
        #expect(ShareExtensionSiteAccess.listSites(directory: nil).isEmpty)
    }

    @Test("listSites reflects a published manifest")
    func listSitesReadsManifest() throws {
        let dir = try tempDir()
        SharedSiteRegistry.publish(
            [SharedSite(id: "a", name: "Alpha", bookmarkData: Data(), lastSeen: Date())], to: dir)
        let sites = ShareExtensionSiteAccess.listSites(directory: dir)
        #expect(sites.map(\.id) == ["a"])
    }

    @Test("withScopedAccess throws unavailable when the directory is nil")
    func withScopedAccessNilDirectory() async {
        await #expect(throws: ShareExtensionSiteAccess.AccessError.unavailable) {
            _ = try await ShareExtensionSiteAccess.withScopedAccess(toSiteID: "a", directory: nil) { _ in }
        }
    }

    @Test("withScopedAccess throws siteNotFound for an unknown id")
    func withScopedAccessUnknownSite() async throws {
        let dir = try tempDir()
        SharedSiteRegistry.publish(
            [SharedSite(id: "a", name: "Alpha", bookmarkData: Data(), lastSeen: Date())], to: dir)
        await #expect(throws: ShareExtensionSiteAccess.AccessError.siteNotFound) {
            _ = try await ShareExtensionSiteAccess.withScopedAccess(toSiteID: "does-not-exist", directory: dir) { _ in }
        }
    }

    @Test("withScopedAccess throws noGrant for unresolvable bookmark data")
    func withScopedAccessBadBookmark() async throws {
        let dir = try tempDir()
        SharedSiteRegistry.publish(
            [SharedSite(id: "a", name: "Alpha", bookmarkData: Data([0xFF, 0x00]), lastSeen: Date())], to: dir)
        do {
            _ = try await ShareExtensionSiteAccess.withScopedAccess(toSiteID: "a", directory: dir) { _ in }
            Issue.record("expected noGrant to be thrown")
        } catch ShareExtensionSiteAccess.AccessError.noGrant {
            // expected
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter ShareExtensionSiteAccessTests`
Expected: FAIL — `ShareExtensionSiteAccess` not found in scope.

- [ ] **Step 3: Write `ShareExtensionSiteAccess.swift`**

```swift
import Foundation
import AnglesiteSiteModel

/// Share-extension-side counterpart to `SiteAccess`: resolves a site's folder access from the
/// App-Group-published manifest instead of the main app's own `SiteStore`/`recents.json` — the
/// extension runs as a separate sandboxed process (#1450) that can't see the app's container.
public enum ShareExtensionSiteAccess {
    /// Failures acquiring scoped access from the extension side. Cases carry ready-to-show
    /// messages — the extension's compose sheet has no window chrome to elaborate further.
    public enum AccessError: Error, Sendable, Equatable {
        /// The App Group container isn't reachable — no entitlement/provisioning profile, or the
        /// main app has never published a bookmark to share.
        case unavailable
        /// The manifest has no entry for the requested site (stale/removed since the picker last
        /// refreshed).
        case siteNotFound
        /// The bookmark exists but couldn't be resolved or started. Carries a user-facing message.
        case noGrant(String)
    }

    /// The sites currently shared by the main app, most-recently-seen first — for the extension's
    /// site picker. Empty (never throws) when sharing is unavailable.
    public static func listSites(
        directory: URL? = SharedContainer.url(),
        fileManager: FileManager = .default
    ) -> [SharedSite] {
        guard let directory else { return [] }
        return SharedSiteRegistry.read(from: directory, fileManager: fileManager)
    }

    /// Run `body` with read/write access to `siteID`'s source directory, resolved from the shared
    /// manifest. Mirrors `SiteAccess.withScopedAccess`'s bracketed-grant shape: starts access,
    /// hands `body` the site's `Source/` directory, then stops access before returning.
    public static func withScopedAccess<T: Sendable>(
        toSiteID siteID: String,
        directory: URL? = SharedContainer.url(),
        fileManager: FileManager = .default,
        _ body: (URL) async -> T
    ) async throws -> T {
        guard let directory else { throw AccessError.unavailable }
        let sites = SharedSiteRegistry.read(from: directory, fileManager: fileManager)
        guard let site = sites.first(where: { $0.id == siteID }) else {
            throw AccessError.siteNotFound
        }
        let bookmarker = PlatformSecurityScopedBookmark.make()
        guard let resolved = try? bookmarker.resolve(site.bookmarkData) else {
            throw AccessError.noGrant(
                "Couldn't access \(site.name)'s folder. Open it once in Anglesite, then try again.")
        }
        guard bookmarker.startAccessing(resolved.url) else {
            throw AccessError.noGrant(
                "Couldn't access \(site.name)'s folder. Open it once in Anglesite, then try again.")
        }
        defer { bookmarker.stopAccessing(resolved.url) }
        let sourceDirectory = AnglesitePackage(url: resolved.url).sourceURL
        return await body(sourceDirectory)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter ShareExtensionSiteAccessTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/ShareExtension/ShareExtensionSiteAccess.swift \
        Tests/AnglesiteCoreTests/ShareExtensionSiteAccessTests.swift
git commit -m "feat(#1450): add ShareExtensionSiteAccess for extension-side bookmark resolve"
```

---

### Task 4: Extract `LinkPostCreation`, reuse it from `QuickCapture`

**Files:**
- Create: `Sources/AnglesiteCore/LinkPostCreation.swift`
- Modify: `Sources/AnglesiteApp/QuickCaptureSheet.swift:200-238`
- Test: `Tests/AnglesiteCoreTests/LinkPostCreationTests.swift`

**Interfaces:**
- Consumes: `ContentCreationWorkflow.native` (existing, `Sources/AnglesiteCore/ContentCreationWorkflow.swift:107`), `LinkPostImageCapture` (existing), `ContentCreateResult` (existing).
- Produces: `public enum LinkPostCreation { static func fieldValues(urlString: String, commentary: String, draft: Bool) -> [String: String]; static func create(siteID: String, title: String, urlString: String, commentary: String, imageURL: String?, draft: Bool, sourceDirectory: URL?) async -> ContentCreateResult }`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/LinkPostCreationTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

struct LinkPostCreationTests {
    @Test("fieldValues carries bookmarkOf, draft, and body")
    func fieldValuesShape() {
        let values = LinkPostCreation.fieldValues(urlString: "https://example.com", commentary: "hi", draft: true)
        #expect(values["bookmarkOf"] == "https://example.com")
        #expect(values["draft"] == "true")
        #expect(values["body"] == "hi")
    }

    @Test("fieldValues always supplies body, even when commentary is empty")
    func fieldValuesEmptyBody() {
        let values = LinkPostCreation.fieldValues(urlString: "https://example.com", commentary: "", draft: false)
        #expect(values["body"] == "")
        #expect(values["draft"] == "false")
    }

    @Test("create with a nil sourceDirectory fails without crashing")
    func createNilSourceDirectory() async {
        let result = await LinkPostCreation.create(
            siteID: "missing-site", title: "Title", urlString: "https://example.com",
            commentary: "", imageURL: nil, draft: true, sourceDirectory: nil)
        guard case .failed = result else {
            Issue.record("expected .failed for a nil sourceDirectory, got \(result)")
            return
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter LinkPostCreationTests`
Expected: FAIL — `LinkPostCreation` not found in scope.

- [ ] **Step 3: Write `LinkPostCreation.swift`**

```swift
import Foundation

/// Writes a link post (bookmark) entry given an already-resolved site source directory — the
/// windowless write path shared by the app's Quick Capture launcher flow and the share extension
/// (#1450). Both callers resolve `sourceDirectory` their own way (`SiteStore` for the app,
/// `ShareExtensionSiteAccess` for the extension) and hand it in here, so the create-plus-card-
/// image logic lives in exactly one place.
public enum LinkPostCreation {
    /// The `fieldValues` a link post writes through `createTyped`. `body` is always supplied —
    /// commentary text, or `""` meaning "no body" — so a published link post never contains the
    /// scaffold's placeholder text (quick-capture spec §4.1's supplied-but-empty rule).
    public static func fieldValues(urlString: String, commentary: String, draft: Bool) -> [String: String] {
        [
            "bookmarkOf": urlString,
            "draft": draft ? "true" : "false",
            "body": commentary,
        ]
    }

    /// Creates the entry, then best-effort captures its card image (#1451) — a failure there
    /// leaves a perfectly good link post, so its result is ignored.
    public static func create(
        siteID: String, title: String, urlString: String, commentary: String,
        imageURL: String?, draft: Bool, sourceDirectory: URL?
    ) async -> ContentCreateResult {
        let workflow = ContentCreationWorkflow.native(
            contentGraph: nil,
            siteDirectory: { _ in sourceDirectory }
        )
        let result = await workflow.createTyped(
            siteID: siteID, typeID: "bookmark", title: title, slug: nil,
            fieldValues: fieldValues(urlString: urlString, commentary: commentary, draft: draft))
        _ = await LinkPostImageCapture().capture(
            imageURL: imageURL, createResult: result, siteDirectory: sourceDirectory)
        return result
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter LinkPostCreationTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Update `QuickCaptureSheet.swift` to delegate to `LinkPostCreation`**

Replace lines 200–238 of `Sources/AnglesiteApp/QuickCaptureSheet.swift` (the `fieldValues` static func and `createLinkPost`) with:

```swift
    /// Windowless create for the launcher flow: same native path the intents use
    /// (`Bootstrap.swift`'s resolver), no content graph (the site has no open window to
    /// refresh; an open window's file watcher picks the new file up on its own). Delegates the
    /// actual create+card-image logic to `LinkPostCreation` (#1450), shared with the share
    /// extension's compose flow.
    static func createLinkPost(
        siteID: String, title: String, urlString: String, commentary: String,
        imageURL: String?, draft: Bool
    ) async -> ContentCreateResult {
        // Resolved once and shared with LinkPostCreation — re-querying SiteStore after the write
        // would be a second actor hop, and a site closed in between the two lookups would
        // silently skip the card image for an entry the first lookup just wrote (#1451).
        let sourceDirectory = await SiteStore.shared.find(id: siteID)?.sourceDirectory
        return await LinkPostCreation.create(
            siteID: siteID, title: title, urlString: urlString, commentary: commentary,
            imageURL: imageURL, draft: draft, sourceDirectory: sourceDirectory)
    }
```

- [ ] **Step 6: Build the app target to confirm no call sites broke**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED. (`SitesLauncherView.swift`'s call to `QuickCapture.createLinkPost` keeps its existing signature, so it needs no change.)

- [ ] **Step 7: Run the full Core suite**

Run: `swift test --package-path .`
Expected: PASS — no regressions.

- [ ] **Step 8: Commit**

```bash
git add Sources/AnglesiteCore/LinkPostCreation.swift \
        Sources/AnglesiteApp/QuickCaptureSheet.swift \
        Tests/AnglesiteCoreTests/LinkPostCreationTests.swift
git commit -m "refactor(#1450): extract LinkPostCreation, reuse from QuickCapture"
```

---

### Task 5: Extension target scaffolding (`project.yml`, entitlements, `xcconfig`)

**Files:**
- Create: `Resources/ShareExtension/Info.plist`
- Create: `Resources/ShareExtension/AnglesiteShareExtension.entitlements`
- Create: `Resources/ShareExtension/AnglesiteShareExtension-Debug.entitlements`
- Create: `Resources/ShareExtension/AnglesiteShareExtension-Debug-AppGroup.entitlements`
- Modify: `Resources/Anglesite.entitlements`
- Modify: `Resources/Anglesite-Debug-iCloud.entitlements`
- Modify: `xcconfig/Signing-Debug.xcconfig`
- Modify: `xcconfig/Signing-Debug.local.xcconfig.example`
- Modify: `project.yml`

**Interfaces:**
- Produces: a buildable (but, without a real Team, functionally inert) `AnglesiteShareExtension` app-extension target embedded in `Anglesite.app`, ready for Task 6's source files.
- This task's extension has no Swift sources yet — add a placeholder `Sources/AnglesiteShareExtension/ShareViewController.swift` stub (Task 6 replaces it) so `xcodegen generate` + a Debug build succeed before Task 6 lands.

- [ ] **Step 1: Create the placeholder extension source**

```swift
// Sources/AnglesiteShareExtension/ShareViewController.swift
// Placeholder — replaced in full by Task 6 of docs/superpowers/plans/2026-08-16-share-extension-quick-capture-plan.md.
import Cocoa

final class ShareViewController: NSViewController, NSExtensionRequestHandling {
    override var nibName: NSNib.Name? { nil }
    override func loadView() { view = NSView() }

    func beginRequest(with context: NSExtensionContext) {
        context.cancelRequest(withError: NSError(domain: "AnglesiteShareExtension", code: -1))
    }
}
```

- [ ] **Step 2: Write `Resources/ShareExtension/Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>Post to Anglesite</string>
	<key>CFBundleExecutable</key>
	<string>$(EXECUTABLE_NAME)</string>
	<key>CFBundleIdentifier</key>
	<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$(PRODUCT_NAME)</string>
	<key>CFBundlePackageType</key>
	<string>XPC!</string>
	<key>CFBundleShortVersionString</key>
	<string>$(MARKETING_VERSION)</string>
	<key>CFBundleVersion</key>
	<string>$(CURRENT_PROJECT_VERSION)</string>
	<key>NSExtension</key>
	<dict>
		<key>NSExtensionAttributes</key>
		<dict>
			<key>NSExtensionActivationRule</key>
			<dict>
				<key>NSExtensionActivationSupportsWebPageWithMaxCount</key>
				<integer>1</integer>
			</dict>
		</dict>
		<key>NSExtensionPointIdentifier</key>
		<string>com.apple.share-services</string>
		<key>NSExtensionPrincipalClass</key>
		<string>$(PRODUCT_MODULE_NAME).ShareViewController</string>
	</dict>
</dict>
</plist>
```

- [ ] **Step 3: Write the three entitlements files**

```xml
<!-- Resources/ShareExtension/AnglesiteShareExtension.entitlements (Release) -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
	<key>com.apple.security.files.bookmarks.app-scope</key>
	<true/>
	<!-- Shares the site registry/bookmarks Anglesite.app publishes (Resources/Anglesite.entitlements
	     carries the identical array) — the canonical Apple pattern for handing a sandboxed
	     extension direct file access to a resource the container app already has permission for
	     (#1450). Requires a real provisioning profile, same class of capability as the main app's
	     iCloud/associated-domains entitlements below. -->
	<key>com.apple.security.application-groups</key>
	<array>
		<string>group.io.dwk.anglesite</string>
	</array>
</dict>
</plist>
```

```xml
<!-- Resources/ShareExtension/AnglesiteShareExtension-Debug.entitlements -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<!-- Default, CI-safe Debug entitlements for the share extension (#1450): NO
	     application-groups here — that capability needs a real Apple Developer provisioning
	     profile even under ad-hoc/Manual signing (mirrors Resources/Anglesite-Debug.entitlements'
	     reasoning for iCloud/associated-domains). The extension still builds and installs without
	     it; it just can't reach the shared site registry, so its compose sheet shows no sites
	     until a contributor opts into ANGLESITE_SHARE_EXTENSION_DEBUG_ENTITLEMENTS locally (see
	     xcconfig/Signing-Debug.local.xcconfig.example). -->
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
	<key>com.apple.security.files.bookmarks.app-scope</key>
	<true/>
</dict>
</plist>
```

```xml
<!-- Resources/ShareExtension/AnglesiteShareExtension-Debug-AppGroup.entitlements -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<!-- Opt-in Debug entitlements (#1450): identical to AnglesiteShareExtension-Debug.entitlements
	     plus the App Group, for contributors with a real Team who want to exercise share-extension
	     bookmark sharing locally. Point ANGLESITE_SHARE_EXTENSION_DEBUG_ENTITLEMENTS at this file
	     from xcconfig/Signing-Debug.local.xcconfig, and also opt the main app in via
	     ANGLESITE_DEBUG_ENTITLEMENTS = Resources/Anglesite-Debug-iCloud.entitlements — the group
	     has to be on both bundle IDs or nothing is shared. -->
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
	<key>com.apple.security.files.bookmarks.app-scope</key>
	<true/>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>group.io.dwk.anglesite</string>
	</array>
</dict>
</plist>
```

- [ ] **Step 4: Add the App Group array to the main app's entitlements**

In `Resources/Anglesite.entitlements`, add (near the other capability arrays, before the closing `</dict>`):

```xml
	<!-- Share extension App Group (#1450): shares this app's site bookmarks with
	     AnglesiteShareExtension so it can post directly without the app frontmost — the array
	     must match Resources/ShareExtension/AnglesiteShareExtension.entitlements' exactly. -->
	<key>com.apple.security.application-groups</key>
	<array>
		<string>group.io.dwk.anglesite</string>
	</array>
```

In `Resources/Anglesite-Debug-iCloud.entitlements`, add the identical block (same comment, same location) — this is the opt-in Debug file, so a contributor with a real Team who points `ANGLESITE_DEBUG_ENTITLEMENTS` here also gets the App Group.

- [ ] **Step 5: Add the `xcconfig` indirection**

In `xcconfig/Signing-Debug.xcconfig`, after the existing `ANGLESITE_REMOTE_DEBUG_ENTITLEMENTS` line and before `#include? "Signing-Debug.local.xcconfig"`:

```
// The AnglesiteShareExtension target's CODE_SIGN_ENTITLEMENTS (Debug config) reads this
// indirection (#1450, mirrors ANGLESITE_REMOTE_DEBUG_ENTITLEMENTS above) so a local override can
// point at Resources/ShareExtension/AnglesiteShareExtension-Debug-AppGroup.entitlements without
// editing this tracked file. Must stay the no-app-group file by default:
// com.apple.security.application-groups requires a real provisioning profile even under the
// ad-hoc signing above, which breaks the no-Apple-account Debug build promise.
ANGLESITE_SHARE_EXTENSION_DEBUG_ENTITLEMENTS = Resources/ShareExtension/AnglesiteShareExtension-Debug.entitlements
```

In `xcconfig/Signing-Debug.local.xcconfig.example`, after the existing keychain-access-groups comment block:

```
// Optional (#1450): only if you want to exercise the Safari share extension's site access in
// local Debug builds. Requires a real Team above — application-groups needs an Apple Developer
// portal capability + provisioning profile that ad-hoc signing can't self-grant.
// Uncomment BOTH lines or nothing is shared: the group has to be on both bundle IDs.
// ANGLESITE_DEBUG_ENTITLEMENTS = Resources/Anglesite-Debug-iCloud.entitlements
// ANGLESITE_SHARE_EXTENSION_DEBUG_ENTITLEMENTS = Resources/ShareExtension/AnglesiteShareExtension-Debug-AppGroup.entitlements
```

- [ ] **Step 6: Add the target to `project.yml`**

Add a new target entry after the `AnglesiteQuickLookThumbnail` target (before the `AnglesiteRemote` comment block):

```yaml
  # Safari share extension (#1450, spec: docs/superpowers/plans/2026-08-16-share-extension-quick-capture-plan.md):
  # posts the current Safari page as a link post without the app frontmost. See
  # AnglesiteCore/ShareExtension/ for the App-Group bookmark-sharing design.
  AnglesiteShareExtension:
    type: app-extension
    platform: macOS
    sources:
      - path: Sources/AnglesiteShareExtension
    # See the Anglesite target's matching comment on configFiles above. Extensions embedded in
    # the host app need matching signing style/team for automatic signing to resolve.
    configFiles:
      Debug: xcconfig/Signing-Debug.xcconfig
      Release: xcconfig/Signing-Release.xcconfig
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: io.dwk.anglesite.ShareExtension
        PRODUCT_NAME: AnglesiteShareExtension
        INFOPLIST_FILE: Resources/ShareExtension/Info.plist
        GENERATE_INFOPLIST_FILE: NO
        CODE_SIGN_ENTITLEMENTS: Resources/ShareExtension/AnglesiteShareExtension.entitlements
        ENABLE_HARDENED_RUNTIME: YES
        MACOSX_DEPLOYMENT_TARGET: "27.0"
        SWIFT_VERSION: "5.10"
        CURRENT_PROJECT_VERSION: 1
        MARKETING_VERSION: "0.1.0"
        SKIP_INSTALL: YES
        # Matches AnglesiteRemote: the extension only ever runs embedded in the MAS-distributed
        # host app, so its Core-layer bookmark-resolution code should take the ANGLESITE_MAS
        # branch, not the DevID/test fallback.
        SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) ANGLESITE_MAS"
      configs:
        Debug:
          # See the AnglesiteRemote target's matching comment on this indirection pattern.
          CODE_SIGN_ENTITLEMENTS: $(ANGLESITE_SHARE_EXTENSION_DEBUG_ENTITLEMENTS)
    dependencies:
      - package: Anglesite
        product: AnglesiteCore
```

Then add it to the `Anglesite` app target's `dependencies:` list, immediately after the existing `AnglesiteQuickLookThumbnail` entry (around line 164–167):

```yaml
      - target: AnglesiteQuickLookThumbnail
        embed: true
      - target: AnglesiteShareExtension
        embed: true
```

- [ ] **Step 7: Regenerate the Xcode project and build**

Run: `xcodegen generate`
Expected: no errors; `Anglesite.xcodeproj` now lists `AnglesiteShareExtension`.

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED — the extension builds and embeds with the placeholder controller and no App Group (Debug default).

- [ ] **Step 8: Commit**

```bash
git add Resources/ShareExtension Resources/Anglesite.entitlements Resources/Anglesite-Debug-iCloud.entitlements \
        xcconfig/Signing-Debug.xcconfig xcconfig/Signing-Debug.local.xcconfig.example project.yml \
        Sources/AnglesiteShareExtension/ShareViewController.swift
git commit -m "feat(#1450): scaffold AnglesiteShareExtension target and entitlements"
```

---

### Task 6: Extension UI — input extraction, compose model, compose view

**Files:**
- Create: `Sources/AnglesiteShareExtension/ShareExtensionInputExtractor.swift`
- Create: `Sources/AnglesiteShareExtension/ShareComposeModel.swift`
- Create: `Sources/AnglesiteShareExtension/ShareComposeView.swift`
- Modify: `Sources/AnglesiteShareExtension/ShareViewController.swift` (replace the Task 5 placeholder)

**Interfaces:**
- Consumes: `ShareExtensionSiteAccess` (Task 3), `LinkPostCreation` (Task 4), `LinkMetadataFetcher`/`LinkMetadata` (existing, `Sources/AnglesiteCore/LinkMetadata.swift`), `ContentCreateResult` (existing).
- This target has no hosted CI tests (matches the rest of `AnglesiteApp`'s app-layer code per `CONTRIBUTING.md` ▸ "Testing" — CI never executes hosted app-target tests); correctness here is verified by Task 5/7's builds plus Task 9's manual signed-build check.

- [ ] **Step 1: Write `ShareExtensionInputExtractor.swift`**

```swift
import Foundation
import UniformTypeIdentifiers

/// What Safari's share sheet hands the extension for the current page: the page URL (required —
/// its presence is what the `NSExtensionActivationRule` in Info.plist already guaranteed) and a
/// best-effort title (Safari supplies the page title as the extension item's content text; a
/// missing/empty value just means `ShareComposeModel` falls back to a metadata fetch, exactly
/// like the app's own Quick Capture sheet does for a page with no reachable title).
struct ShareExtensionInput: Sendable, Equatable {
    let urlString: String
    let title: String
}

enum ShareExtensionInputExtractor {
    static func extract(from context: NSExtensionContext) async -> ShareExtensionInput? {
        guard let item = context.inputItems.first as? NSExtensionItem,
              let attachments = item.attachments else { return nil }

        var urlString: String?
        for provider in attachments where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let value = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                urlString = value.absoluteString
                break
            }
        }
        guard let urlString else { return nil }

        let title = item.attributedContentText?.string.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ShareExtensionInput(urlString: urlString, title: title)
    }
}
```

- [ ] **Step 2: Write `ShareComposeModel.swift`**

```swift
import Foundation
import Observation
import AnglesiteCore

/// State and orchestration for the share extension's compose sheet (#1450) — the extension's
/// counterpart to the app's `QuickCaptureModel`, thin per repo convention: logic stays in
/// `AnglesiteCore` (`ShareExtensionSiteAccess`, `LinkPostCreation`, `LinkMetadataFetcher`); this
/// type just holds UI state and wires them together.
@MainActor
@Observable
final class ShareComposeModel {
    let urlString: String
    var title: String
    var commentary = ""
    var isFetchingMetadata = false
    var metadataImageURL: String?
    var sites: [SharedSite] = []
    var selectedSiteID: String?
    var isBusy = false
    var errorMessage: String?

    private let onFinish: () -> Void
    private let onCancel: () -> Void
    private let fetchMetadata: (URL) async throws -> LinkMetadata
    private let listSites: () -> [SharedSite]
    private let createLinkPost: (String, String, String, String, String?, Bool) async throws -> ContentCreateResult

    init(
        urlString: String,
        initialTitle: String,
        onFinish: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        fetchMetadata: @escaping (URL) async throws -> LinkMetadata = { try await LinkMetadataFetcher().fetch(url: $0) },
        listSites: @escaping () -> [SharedSite] = { ShareExtensionSiteAccess.listSites() },
        createLinkPost: @escaping (String, String, String, String, String?, Bool) async throws -> ContentCreateResult = {
            siteID, title, urlString, commentary, imageURL, draft in
            try await ShareExtensionSiteAccess.withScopedAccess(toSiteID: siteID) { sourceDirectory in
                await LinkPostCreation.create(
                    siteID: siteID, title: title, urlString: urlString, commentary: commentary,
                    imageURL: imageURL, draft: draft, sourceDirectory: sourceDirectory)
            }
        }
    ) {
        self.urlString = urlString
        self.title = initialTitle
        self.onFinish = onFinish
        self.onCancel = onCancel
        self.fetchMetadata = fetchMetadata
        self.listSites = listSites
        self.createLinkPost = createLinkPost
    }

    /// Loads the site picker and, when Safari didn't supply a usable title, fetches page
    /// metadata to fill it — same best-effort behavior as the app's Quick Capture sheet (a fetch
    /// failure just leaves the title blank and editable, never blocks the sheet).
    func onAppear() async {
        sites = listSites()
        selectedSiteID = sites.first?.id
        guard title.isEmpty, let url = URL(string: urlString) else { return }
        isFetchingMetadata = true
        defer { isFetchingMetadata = false }
        if let metadata = try? await fetchMetadata(url) {
            if title.isEmpty { title = metadata.title ?? "" }
            metadataImageURL = metadata.imageURL
        }
    }

    func cancel() { onCancel() }

    func save(draft: Bool) async {
        guard let selectedSiteID else {
            errorMessage = "Choose a site for this link post."
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await createLinkPost(
                selectedSiteID, title, urlString, commentary, metadataImageURL, draft)
            switch result {
            case .created:
                onFinish()
            case .siteNotFound:
                errorMessage = "That site isn't available right now."
            case .failed(let reason):
                errorMessage = reason
            }
        } catch ShareExtensionSiteAccess.AccessError.noGrant(let message) {
            errorMessage = message
        } catch {
            errorMessage = "Couldn't access that site's folder. Open it once in Anglesite, then try again."
        }
    }
}
```

- [ ] **Step 3: Write `ShareComposeView.swift`**

```swift
import SwiftUI
import AnglesiteCore

struct ShareComposeView: View {
    @Bindable var model: ShareComposeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.urlString)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)

            HStack {
                TextField("Title", text: $model.title)
                if model.isFetchingMetadata {
                    ProgressView().controlSize(.small)
                }
            }

            TextEditor(text: $model.commentary)
                .frame(minHeight: 80)
                .overlay(alignment: .topLeading) {
                    if model.commentary.isEmpty {
                        Text("Add a comment…")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }

            if model.sites.isEmpty {
                Text("Open a site in Anglesite at least once to post here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Site", selection: $model.selectedSiteID) {
                    ForEach(model.sites) { site in
                        Text(site.name).tag(Optional(site.id))
                    }
                }
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Spacer()

            HStack {
                Button("Cancel") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Draft") { Task { await model.save(draft: true) } }
                    .disabled(model.isBusy || model.sites.isEmpty)
                Button("Publish") { Task { await model.save(draft: false) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isBusy || model.sites.isEmpty)
            }
        }
        .padding()
        .frame(width: 420, height: 480)
        .task { await model.onAppear() }
    }
}
```

- [ ] **Step 4: Replace the `ShareViewController.swift` placeholder**

```swift
import Cocoa
import SwiftUI
import AnglesiteCore

final class ShareViewController: NSViewController, NSExtensionRequestHandling {
    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 480))
    }

    func beginRequest(with context: NSExtensionContext) {
        Task { @MainActor in
            let input = await ShareExtensionInputExtractor.extract(from: context)
            presentCompose(input: input, context: context)
        }
    }

    @MainActor
    private func presentCompose(input: ShareExtensionInput?, context: NSExtensionContext) {
        guard let input else {
            context.cancelRequest(withError: ShareExtensionError.noURL)
            return
        }
        let model = ShareComposeModel(
            urlString: input.urlString,
            initialTitle: input.title,
            onFinish: { context.completeRequest(returningItems: [], completionHandler: nil) },
            onCancel: { context.cancelRequest(withError: ShareExtensionError.cancelled) }
        )
        let hosting = NSHostingController(rootView: ShareComposeView(model: model))
        addChild(hosting)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.width, .height]
        view.addSubview(hosting.view)
    }
}

enum ShareExtensionError: Error {
    case noURL
    case cancelled
}
```

- [ ] **Step 5: Regenerate and build**

Run: `xcodegen generate && scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteShareExtension
git commit -m "feat(#1450): build the share extension's compose UI"
```

---

### Task 7: Full verification pass

**Files:** none new — verification only.

- [ ] **Step 1: Run the full Core/Bridge/SiteModel/Intents test suite**

Run: `swift test --package-path .`
Expected: PASS. `ANGLESITE_CONTAINER_TESTS`/`ANGLESITE_CONTAINER_E2E`/`ANGLESITE_PLUGIN_PATH`-gated suites skip cleanly as usual (per `CONTRIBUTING.md` ▸ "Testing").

- [ ] **Step 2: Clean Debug build of the full app (with the extension)**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug clean build`
Expected: BUILD SUCCEEDED. Confirm `AnglesiteShareExtension.appex` exists under the built product's `Contents/PlugIns/`.

- [ ] **Step 3: Confirm the `project.yml` ↔ `.xcodeproj` sync check would pass**

Run: `xcodegen generate --quiet && git status --short Anglesite.xcodeproj`
Expected: no diff (the regenerated project matches what's tracked — this is what CI's sync-check lane verifies, per `CONTRIBUTING.md` ▸ "Testing").

- [ ] **Step 4: Confirm REUSE compliance for the new files**

Run: `uvx reuse lint` (or `pipx run reuse lint`)
Expected: PASS — `REUSE.toml`'s top-level `path = "**"` annotation covers the new files automatically; no per-file headers needed (`CONTRIBUTING.md` ▸ "License").

- [ ] **Step 5: No commit for this task** — it only verifies Tasks 1–6.

---

### Task 8: PR preparation

**Files:** none new.

- [ ] **Step 1: Re-read `CONTRIBUTING.md` ▸ "Commits and pull requests" and `.github/PULL_REQUEST_TEMPLATE.md`**

Confirm the PR body will use the template's exact headings (Summary, Paired PR check, Test plan), and that the commit subjects used across Tasks 1–6 are all ≤72 characters.

- [ ] **Step 2: Push the branch and open the PR**

```bash
git push -u origin HEAD
gh pr create --title "feat(#1450): Safari share extension for link posts" --body "$(cat <<'EOF'
## Summary
- Add a Safari share extension (`AnglesiteShareExtension`) so a page can be posted as a link
  post without the app frontmost — Tier 3 of the quick-capture flow (#531).
- Share the App Group `group.io.dwk.anglesite` between the app and the extension; the app
  best-effort publishes a trimmed site/bookmark manifest on every `SiteStore` persist, and the
  extension reads it to list sites and resolve folder access (the canonical Apple pattern for
  sharing a sandboxed resource with an extension).
- Extract `LinkPostCreation` from `QuickCapture.createLinkPost` so the app and the extension
  write entries through identical logic.

## Paired PR check
No MCP message schema changes — this PR is app-only (new Xcode target, Core-layer sharing
logic, and template-independent extension UI). No paired `anglesite-skills` PR needed.

## Test plan
- [x] `swift test --package-path .` — full Core/Bridge/SiteModel/Intents suite passes,
      including new `SharedSiteRegistryTests`, `ShareExtensionSiteAccessTests`,
      `LinkPostCreationTests`, and the two new `SiteStoreTests` cases.
- [x] `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug clean build`
      — the app and the extension both build; `AnglesiteShareExtension.appex` is embedded.
- [x] `xcodegen generate` produces no diff against the tracked `.xcodeproj`.
- [x] `uvx reuse lint` passes.
- [ ] **Manual, real-Team follow-up (cannot be done in this environment):** register the
      `group.io.dwk.anglesite` App Group capability in the Apple Developer portal for both the
      `io.dwk.anglesite` and `io.dwk.anglesite.ShareExtension` App IDs, build with a real signing
      Team (`ANGLESITE_DEBUG_ENTITLEMENTS = Resources/Anglesite-Debug-iCloud.entitlements` +
      `ANGLESITE_SHARE_EXTENSION_DEBUG_ENTITLEMENTS = Resources/ShareExtension/AnglesiteShareExtension-Debug-AppGroup.entitlements`
      in a local `Signing-Debug.local.xcconfig`), and confirm on a real device that "Post to
      Anglesite" appears in Safari's Share menu for a web page, lists the right sites, and a
      Save Draft / Publish actually lands the entry in the site's `bookmarks` collection.

Closes #1450
EOF
)"
```

- [ ] **Step 3: Leave the `🛠️ In Progress` label in place** (per `CONTRIBUTING.md` — the closing keyword in the PR body drops the issue from the claimed-issue search once merged).

---

## Self-Review Notes

- **Spec coverage:** issue #1450's three bullet points (app extension target, app group / shared container, MAS sandbox design for sharing the per-package bookmark) map to Tasks 5 (target scaffolding), 1–3 (App Group manifest + extension-side bookmark resolution), and the sandbox design is exactly Tasks 1–3's mechanism. The owner's approved design ("app group container... per-package security-scoped bookmarks re-minted for the shared container... canonical Apple pattern") maps to Task 2 (`SiteStore` republishes on every persist) and Task 3 (extension resolves from the shared copy). "Compose in the share sheet, save as draft or publish" maps to Task 6.
- **Placeholder scan:** every step carries complete, concrete code — no "TBD"/"add error handling"/"similar to Task N". The one deliberately deferred item (Task 8's unchecked manual-verification line) is not a placeholder; it's flagged as genuinely out of scope for this environment, matching the owner's own comment.
- **Type consistency:** `SharedSite` (Task 1) is used identically in Tasks 2, 3, and 6. `LinkPostCreation.create`'s signature (Task 4) matches its call site in Task 6's `ShareComposeModel` default `createLinkPost` closure. `ShareExtensionSiteAccess.AccessError` cases (Task 3) match the `catch` in Task 6's `ShareComposeModel.save`.
