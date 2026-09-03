# iOS SiteEntity iCloud Source Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give iOS's `SiteEntity` AppIntents resolution a real backing — the same iCloud-discovered `.anglesite` packages `SitePickerModel` already lists in production — instead of the macOS-only `SiteStore.shared`, which is always empty on iOS.

**Architecture:** Split the work into a pure, platform-neutral mapping layer (`SiteEntityUbiquitySource`, fully `swift test`-able) and a thin `#if os(iOS)` `EntityStringQuery` wrapper (`SiteEntityQueryIOS`) that does only container-resolution/discovery orchestration and delegates all mapping/matching logic to the pure layer. `SiteEntity.defaultQuery` picks the right query per platform.

**Tech Stack:** Swift 6.4 / Xcode 27, AppIntents (`EntityStringQuery`), `AnglesiteSiteModel` (`AnglesitePackage`), `AnglesiteIOS` (`UbiquityContainerResolving`, `UbiquitousPackageDiscovering`), SwiftPM conditional target dependencies.

## Global Constraints

- `SiteEntityUbiquitySource` (the pure mapping layer) must carry **no platform gate at all** — this is what makes it testable under plain `swift test` on the macOS host. Only the thin wrapper (`SiteEntityQueryIOS`) is `#if os(iOS)`.
- `SiteEntityQueryIOS` is not exercised by `swift test` (its `#if os(iOS)` gate excludes it on a macOS host, same limitation `PreviewAnnotationProviderUIElementsIOS` carried before #1386 merged it away) — verified only by `xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMobile -configuration Debug -destination 'generic/platform=iOS Simulator' build`.
- Existing macOS `SiteEntityQuery` (`SiteStore`-backed) stays functionally unchanged; only gains an explicit `#if os(macOS)` gate for symmetry with the new iOS query.
- `AnglesiteIntents`'s new dependency on `AnglesiteIOS` must be `.when(platforms: [.iOS])`-conditioned in `Package.swift`, so macOS's `Anglesite` app target does not link `AnglesiteIOS` code it will never use.
- Conventional commits, ≤72-char subject, reference `#1394` (this issue) and `#71`.

---

### Task 1: `SiteEntityUbiquitySource` — pure mapping layer

**Files:**
- Create: `Sources/AnglesiteIntents/SiteEntityUbiquitySource.swift`
- Create: `Tests/AnglesiteIntentsTests/SiteEntityUbiquitySourceTests.swift`
- Modify: `Package.swift` (add `"AnglesiteSiteModel"` to `AnglesiteIntentsTests`'s `dependencies:` array, currently `["AnglesiteIntents", "AnglesiteCore"]` at the `.testTarget(name: "AnglesiteIntentsTests", ...)` block)

**Interfaces:**
- Consumes: `AnglesitePackage(url:)`, `AnglesitePackage.readMarker(fileManager:) throws -> Marker` (`Marker.siteID: UUID`, `Marker.displayName: String`), `AnglesitePackage.sourceURL: URL`, `AnglesitePackage.createSkeleton(at:displayName:)` (test fixtures only) — all existing, `Sources/AnglesiteSiteModel/AnglesitePackage.swift`. `SiteEntity.init(id:name:creationDate:modificationDate:directory:)` — existing, `Sources/AnglesiteIntents/SiteEntity.swift`.
- Produces: `SiteEntityUbiquitySource.siteEntities(fromPackageURLs:fileManager:) -> [SiteEntity]`, `.entities(for:in:fileManager:) -> [SiteEntity]`, `.entities(matching:in:fileManager:) -> [SiteEntity]`, `.defaultResult(in:fileManager:) -> SiteEntity?` — Task 3's `SiteEntityQueryIOS` calls these by exact name.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import AnglesiteIntents
import AnglesiteSiteModel

/// A `final class` (not `struct`) so `deinit` can clean up the scratch directory — mirrors
/// `SitePickerModelTests`' pattern (`Tests/AnglesiteIOSTests/SitePickerModelTests.swift`).
final class SiteEntityUbiquitySourceTests {
    private let scratchRoot: URL

    init() {
        scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SiteEntityUbiquitySourceTests-\(UUID().uuidString)", isDirectory: true)
    }

    deinit {
        let root = scratchRoot
        try? FileManager.default.removeItem(at: root)
    }

    private func makePackage(displayName: String) throws -> URL {
        let url = scratchRoot.appendingPathComponent("\(displayName).anglesite", isDirectory: true)
        _ = try AnglesitePackage.createSkeleton(at: url, displayName: displayName)
        return url
    }

    @Test("A well-formed package maps to a SiteEntity with matching id and name")
    func wellFormedPackageMapsToEntity() throws {
        let url = try makePackage(displayName: "My Blog")
        let entities = SiteEntityUbiquitySource.siteEntities(fromPackageURLs: [url])
        #expect(entities.count == 1)
        #expect(entities.first?.name == "My Blog")
        #expect(entities.first?.directory == url)
    }

    @Test("A package with no marker (malformed) is dropped, not thrown")
    func malformedPackageIsDropped() throws {
        let url = scratchRoot.appendingPathComponent("Not A Package.anglesite", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let entities = SiteEntityUbiquitySource.siteEntities(fromPackageURLs: [url])
        #expect(entities.isEmpty)
    }

    @Test("Multiple packages all map, one bad package among good ones is skipped")
    func mixedGoodAndBadPackages() throws {
        let good = try makePackage(displayName: "Good Site")
        let bad = scratchRoot.appendingPathComponent("Bad.anglesite", isDirectory: true)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        let entities = SiteEntityUbiquitySource.siteEntities(fromPackageURLs: [good, bad])
        #expect(entities.count == 1)
        #expect(entities.first?.name == "Good Site")
    }

    @Test("entities(for:) returns only ids that match")
    func entitiesForIdentifiersFilters() throws {
        let a = try makePackage(displayName: "Site A")
        let b = try makePackage(displayName: "Site B")
        let all = SiteEntityUbiquitySource.siteEntities(fromPackageURLs: [a, b])
        let targetID = all.first { $0.name == "Site A" }!.id
        let filtered = SiteEntityUbiquitySource.entities(for: [targetID], in: [a, b])
        #expect(filtered.count == 1)
        #expect(filtered.first?.name == "Site A")
    }

    @Test("entities(matching:) is a case-insensitive substring match")
    func entitiesMatchingIsCaseInsensitiveSubstring() throws {
        let url = try makePackage(displayName: "My Portfolio Site")
        let matches = SiteEntityUbiquitySource.entities(matching: "portfolio", in: [url])
        #expect(matches.count == 1)
        let noMatches = SiteEntityUbiquitySource.entities(matching: "nonexistent", in: [url])
        #expect(noMatches.isEmpty)
    }

    @Test("defaultResult() returns the single site when exactly one exists")
    func defaultResultReturnsSingleSite() throws {
        let url = try makePackage(displayName: "Only Site")
        #expect(SiteEntityUbiquitySource.defaultResult(in: [url])?.name == "Only Site")
    }

    @Test("defaultResult() returns nil when zero or multiple sites exist")
    func defaultResultReturnsNilWhenNotExactlyOne() throws {
        #expect(SiteEntityUbiquitySource.defaultResult(in: []) == nil)
        let a = try makePackage(displayName: "Site A")
        let b = try makePackage(displayName: "Site B")
        #expect(SiteEntityUbiquitySource.defaultResult(in: [a, b]) == nil)
    }
}
```

- [ ] **Step 2: Add `AnglesiteSiteModel` to the test target's dependencies**

In `Package.swift`, find:
```swift
packageTargets.append(
    .testTarget(
        name: "AnglesiteIntentsTests",
        dependencies: ["AnglesiteIntents", "AnglesiteCore"],
        path: "Tests/AnglesiteIntentsTests",
```
Change the `dependencies:` line to:
```swift
        dependencies: ["AnglesiteIntents", "AnglesiteCore", "AnglesiteSiteModel"],
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test --package-path . --filter SiteEntityUbiquitySourceTests`
Expected: FAIL to compile — `SiteEntityUbiquitySource` doesn't exist yet.

- [ ] **Step 4: Write the implementation**

```swift
import AnglesiteSiteModel
import Foundation

/// Pure, platform-neutral mapping from discovered `.anglesite` package URLs to `SiteEntity`
/// values. Deliberately carries **no** discovery of its own and **no** platform gate: callers own
/// resolving the URL list (macOS's `SiteEntityQuery` doesn't use this at all — it stays
/// `SiteStore`-backed; iOS's `SiteEntityQueryIOS` resolves the list via
/// `UbiquityContainerResolving`/`UbiquitousPackageDiscovering` and hands it here). Keeping this
/// logic gate-free is what makes it exercisable by plain `swift test` on the macOS host, unlike
/// the `#if os(iOS)`-gated wrapper that calls it.
enum SiteEntityUbiquitySource {
    /// Reads each URL's package marker and builds a `SiteEntity`. A package whose marker fails to
    /// read (mid-materializing iCloud item, corrupt or missing `Info.plist`) is dropped, not
    /// thrown — matches `SitePickerModel.refresh()`'s existing behavior
    /// (`Sources/AnglesiteIOS/SitePickerModel.swift`).
    static func siteEntities(
        fromPackageURLs urls: [URL], fileManager: FileManager = .default
    ) -> [SiteEntity] {
        urls.compactMap { url in
            let package = AnglesitePackage(url: url)
            guard let marker = try? package.readMarker(fileManager: fileManager) else {
                return nil
            }
            let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey]
            let values = try? package.sourceURL.resourceValues(forKeys: keys)
            return SiteEntity(
                id: marker.siteID.uuidString,
                name: marker.displayName,
                creationDate: values?.creationDate,
                modificationDate: values?.contentModificationDate,
                directory: url
            )
        }
    }

    /// Exact-id resolution — the path Shortcuts uses to re-resolve a previously captured entity.
    /// Unknown ids are silently dropped (deleted/renamed sites), not errors.
    static func entities(
        for identifiers: [String], in urls: [URL], fileManager: FileManager = .default
    ) -> [SiteEntity] {
        siteEntities(fromPackageURLs: urls, fileManager: fileManager)
            .filter { identifiers.contains($0.id) }
    }

    /// Case-insensitive substring match on the site name, for Siri utterances like "my portfolio
    /// site".
    static func entities(
        matching string: String, in urls: [URL], fileManager: FileManager = .default
    ) -> [SiteEntity] {
        let needle = string.lowercased()
        return siteEntities(fromPackageURLs: urls, fileManager: fileManager)
            .filter { $0.name.lowercased().contains(needle) }
    }

    /// The single site when there is exactly one, so Siri can skip the "which site?" prompt
    /// entirely; `nil` (forcing disambiguation) in every other case.
    static func defaultResult(in urls: [URL], fileManager: FileManager = .default) -> SiteEntity? {
        let sites = siteEntities(fromPackageURLs: urls, fileManager: fileManager)
        return sites.count == 1 ? sites.first : nil
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --package-path . --filter SiteEntityUbiquitySourceTests`
Expected: PASS, all 8 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteIntents/SiteEntityUbiquitySource.swift Tests/AnglesiteIntentsTests/SiteEntityUbiquitySourceTests.swift Package.swift
git commit -m "feat(#1394): add pure SiteEntityUbiquitySource mapping layer"
```

---

### Task 2: `Package.swift` — conditional `AnglesiteIOS` dependency for `AnglesiteIntents`

**Files:**
- Modify: `Package.swift` (the `AnglesiteIntents` target's `dependencies:`)

**Interfaces:**
- Produces: `Sources/AnglesiteIntents/*.swift` can now `import AnglesiteIOS` when compiled for iOS. No behavior change yet — nothing uses it until Task 3.

- [ ] **Step 1: Add the conditional dependency**

Find:
```swift
    .target(
        name: "AnglesiteIntents",
        dependencies: ["AnglesiteCore"],
        path: "Sources/AnglesiteIntents",
        swiftSettings: strictConcurrency
    ),
```
Replace with:
```swift
    .target(
        name: "AnglesiteIntents",
        dependencies: [
            "AnglesiteCore",
            .target(name: "AnglesiteIOS", condition: .when(platforms: [.iOS])),
        ],
        path: "Sources/AnglesiteIntents",
        swiftSettings: strictConcurrency
    ),
```
(`.target(name:condition:)`, not `.product(name:package:condition:)` — `AnglesiteIOS` is a target in this same package, not an external product.)

- [ ] **Step 2: Verify the macOS build is unaffected**

Run: `swift test --package-path . --filter SiteEntityUbiquitySourceTests`
Expected: PASS, same 8 tests as Task 1 — confirms the conditional edge doesn't disturb a macOS-host build (the condition excludes `AnglesiteIOS` on macOS, so nothing changes there).

- [ ] **Step 3: Verify the iOS app target still builds**

Run: `xcodegen generate --quiet` then `xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMobile -configuration Debug -destination 'generic/platform=iOS Simulator' build`
Expected: `** BUILD SUCCEEDED **` (nothing uses the new dependency edge yet, so this just confirms the graph resolves).

- [ ] **Step 4: Commit**

```bash
git add Package.swift
git commit -m "feat(#1394): conditionally link AnglesiteIOS into AnglesiteIntents"
```

---

### Task 3: `SiteEntityQueryIOS` wrapper + platform-conditional `defaultQuery`

**Files:**
- Create: `Sources/AnglesiteIntents/SiteEntityQueryIOS.swift`
- Modify: `Sources/AnglesiteIntents/SiteEntity.swift`

**Interfaces:**
- Consumes: `SiteEntityUbiquitySource.entities(for:in:)`, `.entities(matching:in:)`, `.defaultResult(in:)` (Task 1, exact names above). `UbiquityContainerResolving.url(forUbiquityContainerIdentifier:)`, `UbiquitousPackageDiscovering.discoverPackages()`, `NSMetadataQueryPackageDiscovery()` (existing, `AnglesiteIOS`). `AppSettings.ubiquityContainerIdentifier` (existing, `AnglesiteCore`, value `"iCloud.io.dwk.anglesite"`).
- Produces: `SiteEntityQueryIOS` conforms to `EntityStringQuery`; becomes `SiteEntity.defaultQuery`'s iOS branch. Nothing else depends on this type directly.

- [ ] **Step 1: Write `SiteEntityQueryIOS`**

```swift
#if os(iOS)
import AppIntents
import AnglesiteCore
import AnglesiteIOS
import Foundation

/// Resolves `SiteEntity`s on iOS by discovering `.anglesite` packages in the app's iCloud
/// ubiquity container — the same mechanism `SitePickerModel` uses in production
/// (`Sources/AnglesiteIOS/SitePickerModel.swift`). All mapping/matching logic lives in
/// `SiteEntityUbiquitySource`; this type's only job is resolving the discovered `[URL]` list and
/// handing it off. Not exercised by `swift test` (excluded on a macOS host by this `#if
/// os(iOS)` gate) — verified by `xcodebuild ... -scheme AnglesiteMobile ... build` only.
public struct SiteEntityQueryIOS: EntityStringQuery {
    private let containerResolver: any UbiquityContainerResolving
    private let packageDiscovery: any UbiquitousPackageDiscovering

    /// The no-argument initializer AppIntents requires — binds to the real iCloud container
    /// resolver and `NSMetadataQuery`-backed discovery, matching every other production call
    /// site.
    public init() {
        self.containerResolver = FileManager.default
        self.packageDiscovery = NSMetadataQueryPackageDiscovery()
    }

    /// Test seam: bind the query to fakes instead of real iCloud state.
    public init(
        containerResolver: any UbiquityContainerResolving,
        packageDiscovery: any UbiquitousPackageDiscovering
    ) {
        self.containerResolver = containerResolver
        self.packageDiscovery = packageDiscovery
    }

    /// Ubiquity container check, then package discovery. `nil` container → `[]`, matching
    /// `SitePickerModel.refresh()`'s `.iCloudUnavailable` short-circuit (this type has no
    /// equivalent state to publish, so an empty result is the only signal available).
    private func discoveredURLs() async -> [URL] {
        guard containerResolver.url(
            forUbiquityContainerIdentifier: AppSettings.ubiquityContainerIdentifier
        ) != nil else {
            return []
        }
        return await packageDiscovery.discoverPackages()
    }

    public func entities(for identifiers: [String]) async throws -> [SiteEntity] {
        SiteEntityUbiquitySource.entities(for: identifiers, in: await discoveredURLs())
    }

    public func entities(matching string: String) async throws -> [SiteEntity] {
        SiteEntityUbiquitySource.entities(matching: string, in: await discoveredURLs())
    }

    public func suggestedEntities() async throws -> [SiteEntity] {
        SiteEntityUbiquitySource.siteEntities(fromPackageURLs: await discoveredURLs())
    }

    public func defaultResult() async -> SiteEntity? {
        SiteEntityUbiquitySource.defaultResult(in: await discoveredURLs())
    }
}
#endif
```

- [ ] **Step 2: Gate the existing `SiteEntityQuery` and update `defaultQuery`**

In `Sources/AnglesiteIntents/SiteEntity.swift`, the existing `SiteEntityQuery` struct (the one backed by `SiteStore`) gets wrapped in `#if os(macOS)` / `#endif` — no changes to its body, just the wrapping. Find:

```swift
/// Resolves sites by id (Shortcuts re-resolution) and by name (Siri "my portfolio site").
/// `load()` is called first so a cold background intent process sees the persisted registry.
public struct SiteEntityQuery: EntityStringQuery {
```

Add `#if os(macOS)` immediately above that doc comment, and `#endif` after the struct's closing brace (the end of the file).

Then change:
```swift
    public static let defaultQuery = SiteEntityQuery()
```
to:
```swift
    #if os(macOS)
    public static let defaultQuery = SiteEntityQuery()
    #elseif os(iOS)
    public static let defaultQuery = SiteEntityQueryIOS()
    #endif
```

- [ ] **Step 3: Verify the macOS build and tests are unaffected**

Run: `swift test --package-path . --filter SiteEntityUbiquitySourceTests`
Expected: PASS, same 8 tests. Also re-run `Tests/AnglesiteIntentsTests/SiteEntityQueryTests.swift` (8 cases covering the macOS `SiteStore`-backed query, whose behavior is unchanged — only newly gated). *(Corrected after the fact: this step originally claimed no such test file existed. It does, and it did run and pass; the claim was a documentation error, not a missed check.)*

Run: `swift build --package-path .`
Expected: succeeds — confirms `SiteEntity.swift`'s macOS branch still compiles cleanly with the new `#if os(macOS)` wrapping.

- [ ] **Step 4: Verify the iOS app target builds and actually uses the new query**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMobile -configuration Debug -destination 'generic/platform=iOS Simulator' build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteIntents/SiteEntityQueryIOS.swift Sources/AnglesiteIntents/SiteEntity.swift
git commit -m "feat(#1394): iOS SiteEntity.defaultQuery resolves via iCloud"
```

---

### Task 4: Full verification pass + PR

**Files:** none (verification only)

**Interfaces:** none

- [ ] **Step 1: Run the full SwiftPM test suite**

Run: `swift test --package-path .`
Expected: all suites PASS (or the documented pre-existing flakes/skips from `CLAUDE.md` — nothing new).

- [ ] **Step 2: Full iOS app build**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMobile -configuration Debug -destination 'generic/platform=iOS Simulator' build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Full macOS app build**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: succeeds — this is the one target that would actually regress if `AnglesiteIOS` leaked into the macOS link graph or `SiteEntity.swift`'s macOS branch broke.

- [ ] **Step 4: `project.yml` ↔ `.xcodeproj` sync check**

Run: `scripts/check-xcodeproj-sync.sh`
Expected: exits 0 (this task added no new Xcode targets or file-membership changes beyond what `xcodegen generate` already produced in Task 2/3's steps, but re-verify after all commits).

- [ ] **Step 5: Open the PR**

Use `.github/PULL_REQUEST_TEMPLATE.md`'s exact headings (Summary, Paired PR check, Test plan). Body must include `Closes #1394`. Paired PR check: self-contained to `Anglesite/Anglesite`. In the Summary or an appended "Design notes" section, note explicitly:
- This is sub-project A of the larger gap #1386's final review surfaced (linking `AnglesiteIntents` into `AnglesiteMobile` exposes `AnglesiteShortcuts` + ~28 intents with no iOS dependency bootstrap). Sub-projects B (iOS `ContentOperationsService`), C (iOS `IntegrationOperationsService`), D (`EditContentIntent` iOS wiring), and E (platform-gating the intents that can never run on iOS) are separate, unfiled follow-ups — this PR does not resolve the Siri-crash risk on its own, only the `SiteEntity` resolution gap underneath it.
- `SiteEntityQueryIOS`'s container-resolution/discovery orchestration has no automated test coverage (verified by compile only); the mapping/matching logic it delegates to (`SiteEntityUbiquitySource`) does.
