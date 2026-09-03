# Quick Look preview + thumbnail extensions Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Quick Look preview extension (⌥Space) and a Quick Look thumbnail extension (Finder icon/grid views) for `.anglesite` packages, so Finder shows site name, dates, and content stats instead of a generic folder.

**Architecture:** A new SPM library (`AnglesiteQuickLookSupport`) does all the filesystem/marker reading in a testable, UI-free way. Two new `appex` Xcode targets (`AnglesiteQuickLookPreview`, `AnglesiteQuickLookThumbnail`) consume it and are embedded into the `Anglesite` app target via xcodegen.

**Tech Stack:** Swift 5.10 (SPM targets) / Xcode 27 (appex targets), Quick Look framework (`QLPreviewingController`, `QLThumbnailProvider`), SwiftUI (preview UI), Core Graphics + Core Text (thumbnail drawing), Swift Testing (`import Testing`, `@Test`, `#expect` — matches existing suites).

## Global Constraints

- Deployment target: macOS 27.0 (matches the app target and `Package.swift`'s `platforms: [.macOS("27.0")]`).
- Swift tools version 5.10; new SPM targets use the existing `strictConcurrency` setting (`.enableUpcomingFeature("StrictConcurrency")`) like every other target in `Package.swift`.
- Both appex targets are sandboxed (`com.apple.security.app-sandbox` only) — no bookmarks, no other entitlements. QuickLook grants transient read access to the previewed URL itself.
- Neither the support module nor either extension links `AnglesiteCore` — only `AnglesiteSiteModel`. No dev server, no container runtime, no Node in this feature.
- Bundle identifiers must be prefixed by the app's own (`io.dwk.anglesite`): `io.dwk.anglesite.QuickLookPreview`, `io.dwk.anglesite.QuickLookThumbnail`.
- `swift test` (CI) must stay green with no new environment variables required — `AnglesiteQuickLookSupport` and its tests build unconditionally, same tier as `AnglesiteSiteModel`.
- Test framework: Swift Testing (`import Testing`, `struct FooTests`, `@Test("description")`, `#expect(...)`) — not XCTest. Matches `Tests/AnglesiteSiteModelTests/*`.

---

### Task 1: `AnglesitePackage.quickLookThumbnailURL`

**Files:**
- Modify: `Sources/AnglesiteSiteModel/AnglesitePackage.swift` (add one computed property in the "Layout" section, near `syncBundleURL`)
- Test: `Tests/AnglesiteSiteModelTests/AnglesitePackageTests.swift` (add one test)

**Interfaces:**
- Produces: `AnglesitePackage.quickLookThumbnailURL: URL` — `Config/quicklook-thumbnail.png`. Consumed by Task 2's `PackagePreviewSummary.summarize` and by Task 5's `ThumbnailProvider`.

- [ ] **Step 1: Write the failing test**

Open `Tests/AnglesiteSiteModelTests/AnglesitePackageTests.swift` and add this test inside `struct AnglesitePackageTests`, next to the existing `layoutURLs` test:

```swift
    @Test("quickLookThumbnailURL resolves under Config/")
    func quickLookThumbnailURLResolves() throws {
        let pkgURL = URL(fileURLWithPath: "/tmp/Acme.anglesite", isDirectory: true)
        let pkg = AnglesitePackage(url: pkgURL)
        #expect(pkg.quickLookThumbnailURL.lastPathComponent == "quicklook-thumbnail.png")
        #expect(pkg.quickLookThumbnailURL.deletingLastPathComponent().path == pkg.configURL.path)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter AnglesitePackageTests`
Expected: FAIL — `value of type 'AnglesitePackage' has no member 'quickLookThumbnailURL'`

- [ ] **Step 3: Add the property**

In `Sources/AnglesiteSiteModel/AnglesitePackage.swift`, add this immediately after `syncBundleURL` (still inside the "Layout" `// MARK:` section, before `// MARK: - Marker`):

```swift
    /// Cached home-page thumbnail (nice-to-have, #621). Nothing writes this file yet — a future
    /// feature (e.g. captured on deploy) will populate it. The Quick Look preview and thumbnail
    /// extensions (`AnglesiteQuickLookPreview` / `AnglesiteQuickLookThumbnail`) read it if present
    /// and fall back to a generated placeholder otherwise.
    public var quickLookThumbnailURL: URL {
        configURL.appendingPathComponent("quicklook-thumbnail.png", isDirectory: false)
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter AnglesitePackageTests`
Expected: PASS (all tests in the file, including the new one)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteSiteModel/AnglesitePackage.swift Tests/AnglesiteSiteModelTests/AnglesitePackageTests.swift
git commit -m "feat(site-model): add AnglesitePackage.quickLookThumbnailURL (#621)"
```

---

### Task 2: `AnglesiteQuickLookSupport` module — `PackagePreviewSummary`

**Files:**
- Create: `Sources/AnglesiteQuickLookSupport/PackagePreviewSummary.swift`
- Create: `Tests/AnglesiteQuickLookSupportTests/PackagePreviewSummaryTests.swift`
- Modify: `Package.swift` (new target, test target, product)

**Interfaces:**
- Consumes: `AnglesitePackage` (Task 1's `quickLookThumbnailURL`, existing `sourceURL`, `configURL`, `readMarker`, `PackageError`) from `AnglesiteSiteModel`.
- Produces:
  - `PackagePreviewSummary` struct with fields `displayName: String`, `createdDate: Date`, `pageCount: Int`, `collectionCounts: [PackagePreviewSummary.CollectionCount]`, `sourceLastModified: Date?`, `cachedThumbnailURL: URL?`.
  - `PackagePreviewSummary.CollectionCount` struct with `name: String`, `count: Int`.
  - `static func PackagePreviewSummary.summarize(_ package: AnglesitePackage, fileManager: FileManager = .default) throws -> PackagePreviewSummary`.
  - Consumed by Task 4's `PreviewViewController`/`PreviewContentView` and Task 5's `ThumbnailProvider`.

- [ ] **Step 1: Wire the new target/product into `Package.swift`**

In `Package.swift`, add the new library target right after the `AnglesiteSiteModel` target definition (which ends at line 65 with `swiftSettings: strictConcurrency`, before the `AnglesiteCore` target):

```swift
    .target(
        name: "AnglesiteQuickLookSupport",
        dependencies: ["AnglesiteSiteModel"],
        path: "Sources/AnglesiteQuickLookSupport",
        swiftSettings: strictConcurrency
    ),
```

Add its test target right after `AnglesiteSiteModelTests` (which ends around line 103, before `AnglesiteCoreTests`):

```swift
    .testTarget(
        name: "AnglesiteQuickLookSupportTests",
        dependencies: ["AnglesiteQuickLookSupport"],
        path: "Tests/AnglesiteQuickLookSupportTests",
        swiftSettings: strictConcurrency
    ),
```

Add the product to `packageProducts` right after the `AnglesiteSiteModel` library entry:

```swift
    .library(name: "AnglesiteQuickLookSupport", targets: ["AnglesiteQuickLookSupport"]),
```

Also add both new target names to the Linux-portability filter set (`Sources/AnglesiteSiteModel` is pure Foundation and so is this new target — no Darwin-only imports):

```swift
var portableTargets: Set<String> = ["AnglesiteSiteModel", "AnglesiteSiteModelTests", "AnglesiteQuickLookSupport", "AnglesiteQuickLookSupportTests"]
```

- [ ] **Step 2: Create empty source/test directories with a stub so the target resolves**

```bash
mkdir -p Sources/AnglesiteQuickLookSupport Tests/AnglesiteQuickLookSupportTests
```

Create `Sources/AnglesiteQuickLookSupport/PackagePreviewSummary.swift` with just the type declarations (no `summarize` yet — that's the next step's failing test target):

```swift
import Foundation
import AnglesiteSiteModel

/// Cheap, synchronous summary of a `.anglesite` package's identity and content-layout facts,
/// built for the Quick Look preview/thumbnail extensions (#621). Reads only the `Info.plist`
/// marker and file-layout counts — never parses content, never touches a dev server or container.
public struct PackagePreviewSummary: Sendable, Equatable {
    public let displayName: String
    public let createdDate: Date
    public let pageCount: Int
    /// One entry per subdirectory of `Source/src/content/`, ordered by directory name.
    public let collectionCounts: [CollectionCount]
    public let sourceLastModified: Date?
    /// Set only when `Config/quicklook-thumbnail.png` actually exists — no writer for this cache
    /// exists yet; this is the read-if-present path for a future feature.
    public let cachedThumbnailURL: URL?

    public struct CollectionCount: Sendable, Equatable {
        public let name: String
        public let count: Int

        public init(name: String, count: Int) {
            self.name = name
            self.count = count
        }
    }

    public init(
        displayName: String,
        createdDate: Date,
        pageCount: Int,
        collectionCounts: [CollectionCount],
        sourceLastModified: Date?,
        cachedThumbnailURL: URL?
    ) {
        self.displayName = displayName
        self.createdDate = createdDate
        self.pageCount = pageCount
        self.collectionCounts = collectionCounts
        self.sourceLastModified = sourceLastModified
        self.cachedThumbnailURL = cachedThumbnailURL
    }
}
```

- [ ] **Step 3: Run `swift build` to confirm the new target compiles standalone**

Run: `swift build --target AnglesiteQuickLookSupport`
Expected: Build succeeds (no `summarize` yet, so nothing depends on it).

- [ ] **Step 4: Write the failing tests**

Create `Tests/AnglesiteQuickLookSupportTests/PackagePreviewSummaryTests.swift`:

```swift
import Testing
import Foundation
import AnglesiteSiteModel
@testable import AnglesiteQuickLookSupport

/// Tests for `PackagePreviewSummary.summarize` (#621): the stats-gathering used by both the
/// Quick Look preview and thumbnail extensions.
struct PackagePreviewSummaryTests {
    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ql-summary-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds a package skeleton plus a fake Astro `src/pages` and `src/content/<collection>`
    /// layout so `summarize` has real files to count.
    private func makeFixturePackage(at root: URL, pageNames: [String], collections: [String: [String]]) throws -> AnglesitePackage {
        let pkgURL = root.appendingPathComponent("Fixture.anglesite", isDirectory: true)
        let (pkg, _) = try AnglesitePackage.createSkeleton(at: pkgURL, displayName: "Fixture Site")

        let pagesURL = pkg.sourceURL.appendingPathComponent("src/pages", isDirectory: true)
        try FileManager.default.createDirectory(at: pagesURL, withIntermediateDirectories: true)
        for name in pageNames {
            FileManager.default.createFile(atPath: pagesURL.appendingPathComponent(name).path, contents: Data())
        }

        let contentURL = pkg.sourceURL.appendingPathComponent("src/content", isDirectory: true)
        for (collection, items) in collections {
            let collectionURL = contentURL.appendingPathComponent(collection, isDirectory: true)
            try FileManager.default.createDirectory(at: collectionURL, withIntermediateDirectories: true)
            for item in items {
                FileManager.default.createFile(atPath: collectionURL.appendingPathComponent(item).path, contents: Data())
            }
        }

        return pkg
    }

    @Test("counts pages and collections, orders collections by name")
    func countsPagesAndCollections() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let pkg = try makeFixturePackage(
            at: root,
            pageNames: ["index.astro", "about.astro"],
            collections: ["notes": ["a.md", "b.md", "c.md"], "bookmarks": ["x.md"]]
        )

        let summary = try PackagePreviewSummary.summarize(pkg)

        #expect(summary.displayName == "Fixture Site")
        #expect(summary.pageCount == 2)
        #expect(summary.collectionCounts == [
            PackagePreviewSummary.CollectionCount(name: "bookmarks", count: 1),
            PackagePreviewSummary.CollectionCount(name: "notes", count: 3)
        ])
    }

    @Test("missing marker throws markerMissing")
    func missingMarkerThrows() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let pkgURL = root.appendingPathComponent("NotAPackage.anglesite", isDirectory: true)
        try FileManager.default.createDirectory(at: pkgURL, withIntermediateDirectories: true)
        let pkg = AnglesitePackage(url: pkgURL)

        #expect(throws: AnglesitePackage.PackageError.self) {
            _ = try PackagePreviewSummary.summarize(pkg)
        }
    }

    @Test("cachedThumbnailURL is nil when absent, set when present")
    func cachedThumbnailURLPresence() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let pkg = try makeFixturePackage(at: root, pageNames: [], collections: [:])

        let withoutThumbnail = try PackagePreviewSummary.summarize(pkg)
        #expect(withoutThumbnail.cachedThumbnailURL == nil)

        FileManager.default.createFile(atPath: pkg.quickLookThumbnailURL.path, contents: Data([0x89]))
        let withThumbnail = try PackagePreviewSummary.summarize(pkg)
        #expect(withThumbnail.cachedThumbnailURL == pkg.quickLookThumbnailURL)
    }

    @Test("node_modules and .git are excluded from the last-modified scan")
    func excludesGeneratedDirectoriesFromModificationScan() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let pkg = try makeFixturePackage(at: root, pageNames: ["index.astro"], collections: [:])

        // A file inside node_modules with a far-future modification date must not win.
        let nodeModulesURL = pkg.sourceURL.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: nodeModulesURL, withIntermediateDirectories: true)
        let noisyFile = nodeModulesURL.appendingPathComponent("noisy.js")
        FileManager.default.createFile(atPath: noisyFile.path, contents: Data())
        let farFuture = Date(timeIntervalSinceNow: 60 * 60 * 24 * 365)
        try FileManager.default.setAttributes([.modificationDate: farFuture], ofItemAtPath: noisyFile.path)

        let summary = try PackagePreviewSummary.summarize(pkg)
        #expect(summary.sourceLastModified != nil)
        #expect(summary.sourceLastModified! < farFuture)
    }
}
```

- [ ] **Step 5: Run tests to verify they fail**

Run: `swift test --filter PackagePreviewSummaryTests`
Expected: FAIL to build — `type 'PackagePreviewSummary' has no member 'summarize'`

- [ ] **Step 6: Implement `summarize`**

Replace the contents of `Sources/AnglesiteQuickLookSupport/PackagePreviewSummary.swift` with (keeping the struct declarations from Step 2 and adding the implementation below them, inside the same `public struct PackagePreviewSummary` body, plus one private static helper section after the closing brace):

```swift
import Foundation
import AnglesiteSiteModel

/// Cheap, synchronous summary of a `.anglesite` package's identity and content-layout facts,
/// built for the Quick Look preview/thumbnail extensions (#621). Reads only the `Info.plist`
/// marker and file-layout counts — never parses content, never touches a dev server or container.
public struct PackagePreviewSummary: Sendable, Equatable {
    public let displayName: String
    public let createdDate: Date
    public let pageCount: Int
    /// One entry per subdirectory of `Source/src/content/`, ordered by directory name.
    public let collectionCounts: [CollectionCount]
    public let sourceLastModified: Date?
    /// Set only when `Config/quicklook-thumbnail.png` actually exists — no writer for this cache
    /// exists yet; this is the read-if-present path for a future feature.
    public let cachedThumbnailURL: URL?

    public struct CollectionCount: Sendable, Equatable {
        public let name: String
        public let count: Int

        public init(name: String, count: Int) {
            self.name = name
            self.count = count
        }
    }

    public init(
        displayName: String,
        createdDate: Date,
        pageCount: Int,
        collectionCounts: [CollectionCount],
        sourceLastModified: Date?,
        cachedThumbnailURL: URL?
    ) {
        self.displayName = displayName
        self.createdDate = createdDate
        self.pageCount = pageCount
        self.collectionCounts = collectionCounts
        self.sourceLastModified = sourceLastModified
        self.cachedThumbnailURL = cachedThumbnailURL
    }

    /// Directories skipped when scanning `Source/` for the most recent modification time —
    /// generated/vendored trees whose churn doesn't reflect the author's own edits.
    private static let modificationScanExclusions: Set<String> = ["node_modules", ".git", "dist"]

    /// Builds a summary from `package`. Throws `AnglesitePackage.PackageError` if the marker is
    /// missing or unreadable — callers treat that as "not a readable Anglesite site".
    public static func summarize(
        _ package: AnglesitePackage,
        fileManager: FileManager = .default
    ) throws -> PackagePreviewSummary {
        let marker = try package.readMarker(fileManager: fileManager)

        let pagesURL = package.sourceURL
            .appendingPathComponent("src", isDirectory: true)
            .appendingPathComponent("pages", isDirectory: true)
        let pageCount = (try? fileManager.contentsOfDirectory(atPath: pagesURL.path))?.count ?? 0

        let contentURL = package.sourceURL
            .appendingPathComponent("src", isDirectory: true)
            .appendingPathComponent("content", isDirectory: true)
        let collections = collectionCounts(under: contentURL, fileManager: fileManager)

        let lastModified = mostRecentModificationDate(under: package.sourceURL, fileManager: fileManager)

        var thumbnailURL: URL?
        if fileManager.fileExists(atPath: package.quickLookThumbnailURL.path) {
            thumbnailURL = package.quickLookThumbnailURL
        }

        return PackagePreviewSummary(
            displayName: marker.displayName,
            createdDate: marker.createdDate,
            pageCount: pageCount,
            collectionCounts: collections,
            sourceLastModified: lastModified,
            cachedThumbnailURL: thumbnailURL
        )
    }

    private static func collectionCounts(under contentURL: URL, fileManager: FileManager) -> [CollectionCount] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: contentURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }
        let directories = entries.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
        return directories
            .map { url -> CollectionCount in
                let count = (try? fileManager.contentsOfDirectory(atPath: url.path))?.count ?? 0
                return CollectionCount(name: url.lastPathComponent, count: count)
            }
            .sorted { $0.name < $1.name }
    }

    private static func mostRecentModificationDate(under root: URL, fileManager: FileManager) -> Date? {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        var mostRecent: Date?
        for case let url as URL in enumerator {
            if modificationScanExclusions.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]),
                  values.isDirectory != true,
                  let modified = values.contentModificationDate
            else {
                continue
            }
            if mostRecent == nil || modified > mostRecent! {
                mostRecent = modified
            }
        }
        return mostRecent
    }
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `swift test --filter PackagePreviewSummaryTests`
Expected: PASS — all 4 tests green.

- [ ] **Step 8: Run the full test suite to confirm no regressions**

Run: `swift test`
Expected: PASS (existing suites unaffected; new target/tests included).

- [ ] **Step 9: Commit**

```bash
git add Package.swift Sources/AnglesiteQuickLookSupport Tests/AnglesiteQuickLookSupportTests
git commit -m "feat: add AnglesiteQuickLookSupport with PackagePreviewSummary (#621)"
```

---

### Task 3: Xcode project scaffolding for both `appex` targets

**Files:**
- Create: `Resources/QuickLookPreview/Info.plist`
- Create: `Resources/QuickLookPreview/AnglesiteQuickLookPreview.entitlements`
- Create: `Sources/AnglesiteQuickLookPreview/PreviewViewController.swift` (stub — real logic in Task 4)
- Create: `Resources/QuickLookThumbnail/Info.plist`
- Create: `Resources/QuickLookThumbnail/AnglesiteQuickLookThumbnail.entitlements`
- Create: `Sources/AnglesiteQuickLookThumbnail/ThumbnailProvider.swift` (stub — real logic in Task 5)
- Modify: `project.yml` (two new targets, embed into `Anglesite`)

**Interfaces:**
- Consumes: `AnglesiteQuickLookSupport` product (Task 2) via SPM package dependency in `project.yml`.
- Produces: buildable, embedded, sandboxed `appex` bundles that Finder can discover (empty/stub behavior for now — Task 4 and Task 5 fill in the real controllers).

This task has no automated test (it's Xcode project wiring); verification is `xcodegen generate` + `xcodebuild build` succeeding and the two `.appex` bundles landing in `Contents/PlugIns/`.

- [ ] **Step 1: Create the Preview extension's `Info.plist`**

```bash
mkdir -p Resources/QuickLookPreview Resources/QuickLookThumbnail Sources/AnglesiteQuickLookPreview Sources/AnglesiteQuickLookThumbnail
```

Create `Resources/QuickLookPreview/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>AnglesiteQuickLookPreview</string>
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
			<key>QLSupportedContentTypes</key>
			<array>
				<string>io.dwk.anglesite.site</string>
			</array>
			<key>PreviewsMainViewOnly</key>
			<true/>
		</dict>
		<key>NSExtensionPointIdentifier</key>
		<string>com.apple.quicklook.preview</string>
		<key>NSExtensionPrincipalClass</key>
		<string>$(PRODUCT_MODULE_NAME).PreviewViewController</string>
	</dict>
</dict>
</plist>
```

- [ ] **Step 2: Create the Preview extension's entitlements**

Create `Resources/QuickLookPreview/AnglesiteQuickLookPreview.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
</dict>
</plist>
```

- [ ] **Step 3: Create a stub `PreviewViewController`**

Create `Sources/AnglesiteQuickLookPreview/PreviewViewController.swift`:

```swift
import Cocoa
import Quartz

/// Real preview logic lands in Task 4 of docs/superpowers/plans/2026-07-10-quicklook-extension.md.
final class PreviewViewController: NSViewController, QLPreviewingController {
    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        view = NSView()
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        handler(nil)
    }
}
```

- [ ] **Step 4: Create the Thumbnail extension's `Info.plist`**

Create `Resources/QuickLookThumbnail/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>AnglesiteQuickLookThumbnail</string>
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
			<key>QLSupportedContentTypes</key>
			<array>
				<string>io.dwk.anglesite.site</string>
			</array>
			<key>QLThumbnailMinimumDimension</key>
			<integer>32</integer>
		</dict>
		<key>NSExtensionPointIdentifier</key>
		<string>com.apple.quicklook.thumbnail</string>
		<key>NSExtensionPrincipalClass</key>
		<string>$(PRODUCT_MODULE_NAME).ThumbnailProvider</string>
	</dict>
</dict>
</plist>
```

- [ ] **Step 5: Create the Thumbnail extension's entitlements**

Create `Resources/QuickLookThumbnail/AnglesiteQuickLookThumbnail.entitlements` (identical to Step 2's file):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
</dict>
</plist>
```

- [ ] **Step 6: Create a stub `ThumbnailProvider`**

Create `Sources/AnglesiteQuickLookThumbnail/ThumbnailProvider.swift`:

```swift
import Quartz

/// Real thumbnail-drawing logic lands in Task 5 of docs/superpowers/plans/2026-07-10-quicklook-extension.md.
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        handler(nil, nil)
    }
}
```

- [ ] **Step 7: Add both targets to `project.yml`**

In `project.yml`, add two new target entries under `targets:`, after the existing `Anglesite:` target block (which ends right before the `schemes:` key):

```yaml
  AnglesiteQuickLookPreview:
    type: app-extension
    platform: macOS
    sources:
      - path: Sources/AnglesiteQuickLookPreview
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: io.dwk.anglesite.QuickLookPreview
        PRODUCT_NAME: AnglesiteQuickLookPreview
        INFOPLIST_FILE: Resources/QuickLookPreview/Info.plist
        GENERATE_INFOPLIST_FILE: NO
        CODE_SIGN_ENTITLEMENTS: Resources/QuickLookPreview/AnglesiteQuickLookPreview.entitlements
        ENABLE_HARDENED_RUNTIME: YES
        MACOSX_DEPLOYMENT_TARGET: "27.0"
        SWIFT_VERSION: "5.10"
        CURRENT_PROJECT_VERSION: 1
        MARKETING_VERSION: "0.1.0"
        SKIP_INSTALL: YES
      configs:
        Debug:
          CODE_SIGN_STYLE: Manual
          CODE_SIGN_IDENTITY: "-"
        Release:
          CODE_SIGN_STYLE: Manual
          CODE_SIGN_IDENTITY: "Apple Distribution"
    dependencies:
      - package: Anglesite
        product: AnglesiteQuickLookSupport

  AnglesiteQuickLookThumbnail:
    type: app-extension
    platform: macOS
    sources:
      - path: Sources/AnglesiteQuickLookThumbnail
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: io.dwk.anglesite.QuickLookThumbnail
        PRODUCT_NAME: AnglesiteQuickLookThumbnail
        INFOPLIST_FILE: Resources/QuickLookThumbnail/Info.plist
        GENERATE_INFOPLIST_FILE: NO
        CODE_SIGN_ENTITLEMENTS: Resources/QuickLookThumbnail/AnglesiteQuickLookThumbnail.entitlements
        ENABLE_HARDENED_RUNTIME: YES
        MACOSX_DEPLOYMENT_TARGET: "27.0"
        SWIFT_VERSION: "5.10"
        CURRENT_PROJECT_VERSION: 1
        MARKETING_VERSION: "0.1.0"
        SKIP_INSTALL: YES
      configs:
        Debug:
          CODE_SIGN_STYLE: Manual
          CODE_SIGN_IDENTITY: "-"
        Release:
          CODE_SIGN_STYLE: Manual
          CODE_SIGN_IDENTITY: "Apple Distribution"
    dependencies:
      - package: Anglesite
        product: AnglesiteQuickLookSupport
```

- [ ] **Step 8: Embed both extensions into the `Anglesite` app target**

In `project.yml`, find the `Anglesite` target's `dependencies:` list (currently ending with `- package: Anglesite / product: AnglesiteContainer`) and append:

```yaml
      - target: AnglesiteQuickLookPreview
        embed: true
      - target: AnglesiteQuickLookThumbnail
        embed: true
```

- [ ] **Step 9: Regenerate the Xcode project and build**

```bash
xcodegen generate
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
```

Expected: Build succeeds. Verify both extensions landed in the app bundle:

```bash
find ~/Library/Developer/Xcode/DerivedData -path "*Anglesite.app/Contents/PlugIns/AnglesiteQuickLookPreview.appex" -maxdepth 10 2>/dev/null | head -1
find ~/Library/Developer/Xcode/DerivedData -path "*Anglesite.app/Contents/PlugIns/AnglesiteQuickLookThumbnail.appex" -maxdepth 10 2>/dev/null | head -1
```

Expected: both `find` commands print a path.

- [ ] **Step 10: Commit**

```bash
git add project.yml Resources/QuickLookPreview Resources/QuickLookThumbnail Sources/AnglesiteQuickLookPreview Sources/AnglesiteQuickLookThumbnail
git commit -m "feat: scaffold AnglesiteQuickLookPreview + AnglesiteQuickLookThumbnail appex targets (#621)"
```

---

### Task 4: `AnglesiteQuickLookPreview` real implementation

**Files:**
- Create: `Sources/AnglesiteQuickLookPreview/PreviewContentView.swift`
- Modify: `Sources/AnglesiteQuickLookPreview/PreviewViewController.swift`

**Interfaces:**
- Consumes: `PackagePreviewSummary.summarize(_:)` (Task 2), `AnglesitePackage(url:)` (existing).
- Produces: a working `QLPreviewingController` that renders real content in ⌥Space.

No automated test (hosted extension UI, not testable under `swift test` per the plan's Global Constraints and CLAUDE.md's existing note on hosted-target limits). Verified by manual GUI smoke in Task 6.

- [ ] **Step 1: Write the SwiftUI content view**

Create `Sources/AnglesiteQuickLookPreview/PreviewContentView.swift`:

```swift
import SwiftUI
import AnglesiteQuickLookSupport

/// Rendered inside `PreviewViewController`'s hosting controller. `summary == nil` covers every
/// "not a readable Anglesite site" case (missing/corrupt marker) — Quick Look has no good
/// error-surfacing UI of its own, so this in-view fallback is preferable to throwing.
struct PreviewContentView: View {
    let summary: PackagePreviewSummary?

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        if let summary {
            VStack(alignment: .leading, spacing: 12) {
                header(for: summary)
                Divider()
                stats(for: summary)
                Spacer()
            }
            .padding(20)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "questionmark.folder")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("Not a readable Anglesite site")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func header(for summary: PackagePreviewSummary) -> some View {
        HStack(spacing: 12) {
            if let thumbnailURL = summary.cachedThumbnailURL, let image = NSImage(contentsOf: thumbnailURL) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 32))
                    .frame(width: 64, height: 64)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.displayName)
                    .font(.title2)
                    .bold()
                Text("Created \(Self.dateFormatter.string(from: summary.createdDate))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func stats(for summary: PackagePreviewSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(summary.pageCount) page\(summary.pageCount == 1 ? "" : "s")")
            ForEach(summary.collectionCounts, id: \.name) { collection in
                Text("\(collection.count) \(collection.name)")
            }
            if let lastModified = summary.sourceLastModified {
                Text("Last modified \(Self.dateFormatter.string(from: lastModified))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.body)
    }
}
```

- [ ] **Step 2: Wire the real controller**

Replace `Sources/AnglesiteQuickLookPreview/PreviewViewController.swift` with:

```swift
import Cocoa
import Quartz
import SwiftUI
import AnglesiteSiteModel
import AnglesiteQuickLookSupport

final class PreviewViewController: NSViewController, QLPreviewingController {
    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        view = NSView()
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        let package = AnglesitePackage(url: url)
        let summary = try? PackagePreviewSummary.summarize(package)

        let hosting = NSHostingController(rootView: PreviewContentView(summary: summary))
        addChild(hosting)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.width, .height]
        view.addSubview(hosting.view)

        handler(nil)
    }
}
```

- [ ] **Step 3: Build**

```bash
xcodegen generate
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
```

Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteQuickLookPreview
git commit -m "feat: implement AnglesiteQuickLookPreview content view (#621)"
```

---

### Task 5: `AnglesiteQuickLookThumbnail` real implementation

**Files:**
- Modify: `Sources/AnglesiteQuickLookThumbnail/ThumbnailProvider.swift`

**Interfaces:**
- Consumes: `AnglesitePackage(url:)`, `AnglesitePackage.readMarker()`, `AnglesitePackage.quickLookThumbnailURL` (Task 1).
- Produces: a working `QLThumbnailProvider` that renders real thumbnails in Finder icon/grid views.

No automated test (same rationale as Task 4). Verified by manual GUI smoke in Task 6.

- [ ] **Step 1: Implement the provider**

Replace `Sources/AnglesiteQuickLookThumbnail/ThumbnailProvider.swift` with:

```swift
import Quartz
import AppKit
import AnglesiteSiteModel

final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        let package = AnglesitePackage(url: request.fileURL)
        guard let marker = try? package.readMarker() else {
            // Missing/corrupt marker: fall back to Quick Look's default folder icon rather than
            // drawing a misleading placeholder for something that isn't a readable site.
            handler(nil, nil)
            return
        }

        if FileManager.default.fileExists(atPath: package.quickLookThumbnailURL.path) {
            handler(QLThumbnailReply(imageFileURL: package.quickLookThumbnailURL), nil)
            return
        }

        let displayName = marker.displayName
        let reply = QLThumbnailReply(contextSize: request.maximumSize) {
            Self.drawMonogram(for: displayName, size: request.maximumSize)
            return true
        }
        handler(reply, nil)
    }

    /// Draws a rounded-rect badge with the site's first-letter monogram — the fallback shown
    /// until a real cached home-page thumbnail (`Config/quicklook-thumbnail.png`) exists.
    private static func drawMonogram(for displayName: String, size: CGSize) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = CGRect(origin: .zero, size: size)
        let inset = min(size.width, size.height) * 0.05
        let cornerRadius = min(size.width, size.height) * 0.12

        let backgroundPath = CGPath(
            roundedRect: rect.insetBy(dx: inset, dy: inset),
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.addPath(backgroundPath)
        context.fillPath()

        let monogram = String(displayName.prefix(1)).uppercased()
        guard !monogram.isEmpty else { return }
        let fontSize = size.height * 0.4
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let attributedString = NSAttributedString(string: monogram, attributes: attributes)
        let textSize = attributedString.size()
        let textOrigin = CGPoint(
            x: rect.midX - textSize.width / 2,
            y: rect.midY - textSize.height / 2
        )
        attributedString.draw(at: textOrigin)
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodegen generate
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
```

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteQuickLookThumbnail
git commit -m "feat: implement AnglesiteQuickLookThumbnail monogram drawing (#621)"
```

---

### Task 6: Manual GUI smoke test + full verification

**Files:** none (verification only)

- [ ] **Step 1: Run the full test suite one more time**

```bash
swift test
```

Expected: PASS, including `AnglesiteSiteModelTests` and `AnglesiteQuickLookSupportTests`.

- [ ] **Step 2: Build and install the app locally**

```bash
xcodegen generate
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
```

Locate the built `.app` under DerivedData and copy or symlink it somewhere Finder/Quick Look will index it (e.g. `open` it once so LaunchServices registers the extensions, or use `pluginkit -m` to confirm registration):

```bash
pluginkit -m -p com.apple.quicklook.preview | grep -i anglesite
pluginkit -m -p com.apple.quicklook.thumbnail | grep -i anglesite
```

Expected: both commands list the respective bundle identifiers (`io.dwk.anglesite.QuickLookPreview`, `io.dwk.anglesite.QuickLookThumbnail`). If neither appears, launch the built `Anglesite.app` once (LaunchServices registers extensions on first launch) and re-check.

- [ ] **Step 3: Create a real `.anglesite` package to test against**

Use the running app (File ▸ New Site, or Import an existing site directory) to produce a real `.anglesite` package with some pages/content under `Source/src/pages` and `Source/src/content/*`.

- [ ] **Step 4: Verify the Preview extension**

In Finder, select the `.anglesite` package and press Space (⌥Space for the larger preview). Confirm the popup shows: display name, created date, page count, per-collection counts, and last-modified date — not a generic folder preview.

- [ ] **Step 5: Verify the Thumbnail extension**

In Finder, switch to icon or grid view on the folder containing the `.anglesite` package. Confirm the package's icon shows the generated blue monogram badge instead of the generic folder icon. (It may take a moment / a Finder relaunch — `killall Finder` — for the thumbnail cache to refresh.)

- [ ] **Step 6: Verify the "unreadable site" fallback**

Create a plain empty directory named `Fake.anglesite` (no `Info.plist`) via Terminal (`mkdir /tmp/Fake.anglesite`), rename it in Finder if needed so the extension is invoked, and press Space on it. Confirm the preview shows "Not a readable Anglesite site" rather than crashing or showing stale/wrong data.

- [ ] **Step 7: Note results in the PR description**

When opening the PR, include a short manual-smoke checklist (Steps 4–6 above, pass/fail) per this plan's testing approach — matches the pattern used for other GUI-only verifications in this repo (e.g. #491, #586).
