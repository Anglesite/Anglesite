# `.anglesite` Package Model — Phase 1 (Format Core) Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish the `.anglesite` package on-disk format — a `Source/` + `Config/` + `Info.plist`-marker layout with stable-UUID identity and a format-version gate — plus the macOS type declarations (UTI + `CFBundleDocumentTypes`) that make Finder treat it as an editable package.

**Architecture:** A single `AnglesitePackage` value type in `AnglesiteCore` owns all knowledge of the package's internal layout and marker (`Info.plist`) read/write/create. Everything later (recents registry, scaffold/deploy cwd, config store) resolves paths through it, so the layout lives in exactly one file. Type declarations land in both targets' `Info.plist` files.

**Tech Stack:** Swift 5.10 / SwiftPM (`AnglesiteCore` library), Swift Testing (`@Test`), `PropertyListEncoder`/`Decoder` for the marker, XcodeGen (`project.yml`) for the app targets.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-06-19-anglesite-package-model-design.md`. This is Phase 1 (P1) of that spec. Phases P2–P5 are separate plans.
- **Toolchain:** prefix every `swift test` / `xcodegen` / `xcodebuild` command with `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` — the default `xcode-select` can't run `swift test`.
- **ES Modules / Swift 6 concurrency:** `SWIFT_STRICT_CONCURRENCY: complete`. New types crossing actor/task boundaries must be `Sendable`.
- **Testing framework:** new tests use **Swift Testing** (`import Testing`, `@Test`, `#expect`), not XCTest. Tests live in `Tests/AnglesiteCoreTests/`, run on CI (no hosted app target), and inject a temp `FileManager`/URL — never touch real user dirs.
- **Layout (verbatim from spec §1):** package dir `<Name>.anglesite` with `LSTypeIsPackage`; children `Info.plist` (marker), `Source/` (git repo, the Astro project), `Config/` (app-owned, not in git).
- **Marker keys (verbatim from spec §1):** `AnglesiteFormatVersion` (Int), `AnglesiteSiteID` (String UUID), `AnglesiteDisplayName` (String), `AnglesiteCreatedDate` (Date).
- **UTI (verbatim from spec §2):** exported type `dev.anglesite.site`, conforms to `com.apple.package` + `public.composite-content`, filename extension `anglesite`; a `CFBundleDocumentTypes` Editor entry with `LSTypeIsPackage` and `LSItemContentTypes = [dev.anglesite.site]`. Added to **both** targets (`Resources/Info.plist` and `Resources/AnglesiteMAS-Info.plist`).
- **Branch:** `feat/242-anglesite-package-model` (already created).
- **Commit style:** Conventional Commits; scope `(#242)`. End each commit body with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

### Task 1: `AnglesitePackage` layout + marker round-trip

Create the core type with its layout URLs and `Info.plist` marker read/write.

**Files:**
- Create: `Sources/AnglesiteCore/AnglesitePackage.swift`
- Test: `Tests/AnglesiteCoreTests/AnglesitePackageTests.swift`

**Interfaces:**
- Consumes: `ProjectValidator` (existing, `Sources/AnglesiteCore/ProjectValidator.swift`).
- Produces (relied on by later tasks and P2+):
  - `struct AnglesitePackage: Sendable, Equatable { let url: URL; init(url: URL) }`
  - `static let packageExtension = "anglesite"`
  - `static let currentFormatVersion = 1`
  - `var infoPlistURL: URL`, `var sourceURL: URL`, `var configURL: URL`
  - `struct AnglesitePackage.Marker: Sendable, Codable, Equatable` with `formatVersion: Int`, `siteID: UUID`, `displayName: String`, `createdDate: Date`
  - `func readMarker(fileManager:) throws -> Marker`
  - `func writeMarker(_:fileManager:) throws`

- [ ] **Step 1: Write the failing test**

Create `Tests/AnglesiteCoreTests/AnglesitePackageTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

/// Tests for `AnglesitePackage` (#242, P1): the `.anglesite` package on-disk format —
/// layout URLs and the `Info.plist` marker round-trip.
struct AnglesitePackageTests {
    /// A fresh temp directory per test; caller removes it.
    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("anglesite-pkg-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("layout URLs resolve under the package directory")
    func layoutURLs() throws {
        let pkgURL = URL(fileURLWithPath: "/tmp/Acme.anglesite", isDirectory: true)
        let pkg = AnglesitePackage(url: pkgURL)
        #expect(pkg.infoPlistURL.lastPathComponent == "Info.plist")
        #expect(pkg.sourceURL.lastPathComponent == "Source")
        #expect(pkg.configURL.lastPathComponent == "Config")
        #expect(pkg.sourceURL.deletingLastPathComponent().path == pkgURL.path)
    }

    @Test("marker written to Info.plist round-trips through read")
    func markerRoundTrips() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pkg = AnglesitePackage(url: dir.appendingPathComponent("Acme.anglesite", isDirectory: true))

        let marker = AnglesitePackage.Marker(
            siteID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            displayName: "Acme",
            createdDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try pkg.writeMarker(marker)

        #expect(FileManager.default.fileExists(atPath: pkg.infoPlistURL.path))
        let read = try pkg.readMarker()
        #expect(read == marker)
        #expect(read.formatVersion == AnglesitePackage.currentFormatVersion)
    }

    @Test("Info.plist uses the spec's exact marker keys")
    func markerUsesSpecKeys() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pkg = AnglesitePackage(url: dir.appendingPathComponent("Acme.anglesite", isDirectory: true))
        try pkg.writeMarker(.init(displayName: "Acme"))

        let plist = try #require(NSDictionary(contentsOf: pkg.infoPlistURL))
        #expect(plist["AnglesiteFormatVersion"] != nil)
        #expect(plist["AnglesiteSiteID"] != nil)
        #expect(plist["AnglesiteDisplayName"] as? String == "Acme")
        #expect(plist["AnglesiteCreatedDate"] != nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter AnglesitePackageTests`
Expected: FAIL — `cannot find 'AnglesitePackage' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/AnglesiteCore/AnglesitePackage.swift`:

```swift
import Foundation

/// A `.anglesite` package on disk: a Finder-opaque directory (UTI `dev.anglesite.site`,
/// `LSTypeIsPackage`) that wraps a git-tracked `Source/` Astro project, an app-owned `Config/`
/// directory, and an `Info.plist` marker carrying a stable site UUID + a format version.
///
/// This is the single source of truth for the package's internal layout. Recents discovery,
/// scaffold/deploy working directories, and the per-site config store all resolve paths through
/// here so the layout lives in exactly one file (spec §1).
public struct AnglesitePackage: Sendable, Equatable {
    /// Filename extension and package UTI suffix.
    public static let packageExtension = "anglesite"

    /// Current on-disk format. Bump when the layout changes in a way older builds can't safely
    /// write; `Marker.formatVersion` is compared against this on open (see `compatibility(for:)`).
    public static let currentFormatVersion = 1

    /// The package directory (`…/Name.anglesite`).
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    // MARK: - Layout

    public var infoPlistURL: URL { url.appendingPathComponent("Info.plist") }
    public var sourceURL: URL { url.appendingPathComponent("Source", isDirectory: true) }
    public var configURL: URL { url.appendingPathComponent("Config", isDirectory: true) }

    // MARK: - Marker

    /// The `Info.plist` marker: stable identity + format version + provenance. Encoded with
    /// `PropertyListEncoder`, so `createdDate` is a native plist date and `siteID` a plist string.
    public struct Marker: Sendable, Codable, Equatable {
        public var formatVersion: Int
        public var siteID: UUID
        public var displayName: String
        public var createdDate: Date

        public init(
            formatVersion: Int = AnglesitePackage.currentFormatVersion,
            siteID: UUID = UUID(),
            displayName: String,
            createdDate: Date = Date()
        ) {
            self.formatVersion = formatVersion
            self.siteID = siteID
            self.displayName = displayName
            self.createdDate = createdDate
        }

        private enum CodingKeys: String, CodingKey {
            case formatVersion = "AnglesiteFormatVersion"
            case siteID = "AnglesiteSiteID"
            case displayName = "AnglesiteDisplayName"
            case createdDate = "AnglesiteCreatedDate"
        }
    }

    /// Reads and decodes the `Info.plist` marker. (Error cases handled in Task 2.)
    public func readMarker(fileManager: FileManager = .default) throws -> Marker {
        let data = try Data(contentsOf: infoPlistURL)
        return try PropertyListDecoder().decode(Marker.self, from: data)
    }

    /// Writes the marker to `Info.plist` (XML plist, atomic), creating the package dir if needed.
    public func writeMarker(_ marker: Marker, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data = try encoder.encode(marker)
        try data.write(to: infoPlistURL, options: [.atomic])
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter AnglesitePackageTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/AnglesitePackage.swift Tests/AnglesiteCoreTests/AnglesitePackageTests.swift
git commit -m "$(cat <<'EOF'
feat(#242): AnglesitePackage layout + Info.plist marker round-trip

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Marker error handling + format-version gating

Make `readMarker` throw typed errors for a missing/corrupt marker, and add the
forward-compat gate that flags a newer-than-known format as read-only.

**Files:**
- Modify: `Sources/AnglesiteCore/AnglesitePackage.swift`
- Test: `Tests/AnglesiteCoreTests/AnglesitePackageTests.swift`

**Interfaces:**
- Produces:
  - `enum AnglesitePackage.PackageError: Error, Equatable, Sendable { case markerMissing(URL); case markerUnreadable(URL) }`
  - `enum AnglesitePackage.Compatibility: Sendable, Equatable { case current; case readOnlyTooNew }`
  - `static func compatibility(for: Marker) -> Compatibility`

- [ ] **Step 1: Write the failing test**

Append to `Tests/AnglesiteCoreTests/AnglesitePackageTests.swift` (inside the struct):

```swift
    @Test("readMarker throws markerMissing when Info.plist is absent")
    func readMarkerMissing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pkg = AnglesitePackage(url: dir.appendingPathComponent("Empty.anglesite", isDirectory: true))
        #expect(throws: AnglesitePackage.PackageError.markerMissing(pkg.infoPlistURL)) {
            try pkg.readMarker()
        }
    }

    @Test("readMarker throws markerUnreadable when Info.plist is corrupt")
    func readMarkerCorrupt() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pkg = AnglesitePackage(url: dir.appendingPathComponent("Bad.anglesite", isDirectory: true))
        try FileManager.default.createDirectory(at: pkg.url, withIntermediateDirectories: true)
        try Data("not a plist".utf8).write(to: pkg.infoPlistURL)
        #expect(throws: AnglesitePackage.PackageError.markerUnreadable(pkg.infoPlistURL)) {
            try pkg.readMarker()
        }
    }

    @Test("compatibility flags a newer format version as read-only")
    func compatibilityGate() {
        let current = AnglesitePackage.Marker(
            formatVersion: AnglesitePackage.currentFormatVersion, displayName: "A")
        let future = AnglesitePackage.Marker(
            formatVersion: AnglesitePackage.currentFormatVersion + 1, displayName: "B")
        #expect(AnglesitePackage.compatibility(for: current) == .current)
        #expect(AnglesitePackage.compatibility(for: future) == .readOnlyTooNew)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter AnglesitePackageTests`
Expected: FAIL — `cannot find 'PackageError'` / `cannot find 'compatibility'`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/AnglesiteCore/AnglesitePackage.swift`, add the error + compatibility types and update `readMarker`. Add after the `Marker` struct:

```swift
    public enum PackageError: Error, Equatable, Sendable {
        case markerMissing(URL)
        case markerUnreadable(URL)
    }

    /// Forward-compatibility verdict for an opened package's marker.
    public enum Compatibility: Sendable, Equatable {
        /// Same format the app writes — fully editable.
        case current
        /// Written by a newer build than this one. Open read-only and prompt to upgrade rather
        /// than silently rewriting a format we don't understand (spec §9).
        case readOnlyTooNew
    }

    public static func compatibility(for marker: Marker) -> Compatibility {
        marker.formatVersion > currentFormatVersion ? .readOnlyTooNew : .current
    }
```

Replace the body of `readMarker(fileManager:)` with:

```swift
    public func readMarker(fileManager: FileManager = .default) throws -> Marker {
        guard fileManager.fileExists(atPath: infoPlistURL.path) else {
            throw PackageError.markerMissing(infoPlistURL)
        }
        do {
            let data = try Data(contentsOf: infoPlistURL)
            return try PropertyListDecoder().decode(Marker.self, from: data)
        } catch {
            throw PackageError.markerUnreadable(infoPlistURL)
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter AnglesitePackageTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/AnglesitePackage.swift Tests/AnglesiteCoreTests/AnglesitePackageTests.swift
git commit -m "$(cat <<'EOF'
feat(#242): marker error types + format-version compatibility gate

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `createSkeleton`, `isPackage`, source validation

Add package creation (dir + `Source/` + `Config/` + stamped marker), package
detection, and a passthrough to `ProjectValidator` for the `Source/` tree.

**Files:**
- Modify: `Sources/AnglesiteCore/AnglesitePackage.swift`
- Test: `Tests/AnglesiteCoreTests/AnglesitePackageTests.swift`

**Interfaces:**
- Produces:
  - `@discardableResult static func createSkeleton(at: URL, displayName: String, fileManager:) throws -> (AnglesitePackage, Marker)`
  - `static func isPackage(at: URL, fileManager:) -> Bool`
  - `func sourceValidation(fileManager:) -> ProjectValidator.Result`

- [ ] **Step 1: Write the failing test**

Append to `Tests/AnglesiteCoreTests/AnglesitePackageTests.swift` (inside the struct):

```swift
    @Test("createSkeleton lays down Source/, Config/, and a stamped marker")
    func createSkeletonLaysDownLayout() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pkgURL = dir.appendingPathComponent("Acme.anglesite", isDirectory: true)

        let (pkg, marker) = try AnglesitePackage.createSkeleton(at: pkgURL, displayName: "Acme")

        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: pkg.sourceURL.path, isDirectory: &isDir) && isDir.boolValue)
        #expect(FileManager.default.fileExists(atPath: pkg.configURL.path, isDirectory: &isDir) && isDir.boolValue)
        #expect(marker.displayName == "Acme")
        #expect(try pkg.readMarker() == marker)
    }

    @Test("isPackage is true only for an .anglesite dir with a readable marker")
    func isPackageDetection() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = dir.appendingPathComponent("Good.anglesite", isDirectory: true)
        _ = try AnglesitePackage.createSkeleton(at: good, displayName: "Good")
        let wrongExt = dir.appendingPathComponent("Plain", isDirectory: true)
        try FileManager.default.createDirectory(at: wrongExt, withIntermediateDirectories: true)
        let noMarker = dir.appendingPathComponent("Hollow.anglesite", isDirectory: true)
        try FileManager.default.createDirectory(at: noMarker, withIntermediateDirectories: true)

        #expect(AnglesitePackage.isPackage(at: good))
        #expect(!AnglesitePackage.isPackage(at: wrongExt))
        #expect(!AnglesitePackage.isPackage(at: noMarker))
    }

    @Test("sourceValidation reports missing sentinels in Source/")
    func sourceValidationReportsMissing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pkgURL = dir.appendingPathComponent("Acme.anglesite", isDirectory: true)
        let (pkg, _) = try AnglesitePackage.createSkeleton(at: pkgURL, displayName: "Acme")

        // Empty Source/: invalid (all required sentinels missing).
        #expect(!pkg.sourceValidation().isValid)

        // Drop the required sentinels into Source/: now valid.
        for name in ProjectValidator.requiredSentinels {
            try Data("{}".utf8).write(to: pkg.sourceURL.appendingPathComponent(name))
        }
        #expect(pkg.sourceValidation().isValid)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter AnglesitePackageTests`
Expected: FAIL — `cannot find 'createSkeleton'` etc.

- [ ] **Step 3: Write minimal implementation**

In `Sources/AnglesiteCore/AnglesitePackage.swift`, add (after `writeMarker`):

```swift
    // MARK: - Creation

    /// Creates an empty package skeleton: the package dir, `Source/`, `Config/`, and a freshly
    /// stamped `Info.plist`. Does **not** scaffold the Astro project — that runs later with cwd =
    /// `sourceURL` (P2). Returns the package and its new marker.
    @discardableResult
    public static func createSkeleton(
        at url: URL,
        displayName: String,
        fileManager: FileManager = .default
    ) throws -> (AnglesitePackage, Marker) {
        let pkg = AnglesitePackage(url: url)
        try fileManager.createDirectory(at: pkg.sourceURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: pkg.configURL, withIntermediateDirectories: true)
        let marker = Marker(displayName: displayName)
        try pkg.writeMarker(marker, fileManager: fileManager)
        return (pkg, marker)
    }

    // MARK: - Detection & validation

    /// `true` when `url` is a `.anglesite` directory carrying a readable marker.
    public static func isPackage(at url: URL, fileManager: FileManager = .default) -> Bool {
        guard url.pathExtension == packageExtension else { return false }
        return (try? AnglesitePackage(url: url).readMarker(fileManager: fileManager)) != nil
    }

    /// Validates the `Source/` tree against the Anglesite project sentinels.
    public func sourceValidation(fileManager: FileManager = .default) -> ProjectValidator.Result {
        ProjectValidator.validate(sourceURL, fileManager: fileManager)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter AnglesitePackageTests`
Expected: PASS (9 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/AnglesitePackage.swift Tests/AnglesiteCoreTests/AnglesitePackageTests.swift
git commit -m "$(cat <<'EOF'
feat(#242): package skeleton creation, detection, and Source/ validation

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Declare the `.anglesite` package type on both targets

Register the exported UTI and document type so Finder treats `.anglesite` as an
editable package owned by Anglesite. This is `Info.plist` config (no unit test);
verification is plist lint + a clean `xcodegen generate`.

**Files:**
- Modify: `Resources/Info.plist`
- Modify: `Resources/AnglesiteMAS-Info.plist`

**Interfaces:** none (build config only).

- [ ] **Step 1: Add the declarations to `Resources/Info.plist`**

Insert the following two key/value blocks inside the top-level `<dict>` (e.g. immediately
before the closing `</dict>` on the last line). Both targets get the **same** block:

```xml
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeName</key>
			<string>Anglesite Site</string>
			<key>CFBundleTypeRole</key>
			<string>Editor</string>
			<key>LSHandlerRank</key>
			<string>Owner</string>
			<key>LSTypeIsPackage</key>
			<true/>
			<key>LSItemContentTypes</key>
			<array>
				<string>dev.anglesite.site</string>
			</array>
		</dict>
	</array>
	<key>UTExportedTypeDeclarations</key>
	<array>
		<dict>
			<key>UTTypeIdentifier</key>
			<string>dev.anglesite.site</string>
			<key>UTTypeDescription</key>
			<string>Anglesite Site</string>
			<key>UTTypeConformsTo</key>
			<array>
				<string>com.apple.package</string>
				<string>public.composite-content</string>
			</array>
			<key>UTTypeTagSpecification</key>
			<dict>
				<key>public.filename-extension</key>
				<array>
					<string>anglesite</string>
				</array>
			</dict>
		</dict>
	</array>
```

- [ ] **Step 2: Add the identical blocks to `Resources/AnglesiteMAS-Info.plist`**

Insert the same two blocks inside the top-level `<dict>` of `Resources/AnglesiteMAS-Info.plist`.

- [ ] **Step 3: Lint both plists**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer plutil -lint Resources/Info.plist Resources/AnglesiteMAS-Info.plist`
Expected: both report `OK`.

- [ ] **Step 4: Verify the keys are present and well-formed**

Run: `plutil -extract UTExportedTypeDeclarations.0.UTTypeIdentifier raw Resources/Info.plist && plutil -extract CFBundleDocumentTypes.0.LSItemContentTypes.0 raw Resources/AnglesiteMAS-Info.plist`
Expected: prints `dev.anglesite.site` then `dev.anglesite.site`.

- [ ] **Step 5: Regenerate the Xcode project to confirm it still loads**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodegen generate`
Expected: `Created project at .../Anglesite.xcodeproj` with no errors. (The plists are referenced via `INFOPLIST_FILE`; XcodeGen only needs to regenerate cleanly. A full `xcodebuild` is not required for this config-only task and is covered by P2's first build.)

- [ ] **Step 6: Commit**

```bash
git add Resources/Info.plist Resources/AnglesiteMAS-Info.plist
git commit -m "$(cat <<'EOF'
feat(#242): declare dev.anglesite.site package UTI + document type (both targets)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage (P1 scope = spec §1 format + §2 type declarations + §9 format-version gate):**
- §1 layout (`Source/`/`Config/`/`Info.plist`) → Task 1 (URLs) + Task 3 (`createSkeleton`). ✓
- §1 stable-UUID identity in marker → Task 1 (`Marker.siteID: UUID`). ✓
- §1 marker keys verbatim → Task 1 (`markerUsesSpecKeys` test asserts the exact keys). ✓
- §2 UTI + `CFBundleDocumentTypes`, both targets → Task 4. ✓
- §9 unknown/newer format → read-only → Task 2 (`Compatibility.readOnlyTooNew`). ✓
- §9 missing/corrupt marker handled (not crash) → Task 2 (`markerMissing`/`markerUnreadable`). ✓
- §10 tests: round-trip, marker parse + version gating, validation = `Source/` → Tasks 1–3. ✓ (Identity-stability-across-move, recents persistence, Import/Export, cwd are **P2/P3** scope — out of P1.)

**Placeholder scan:** none — every code/test step shows full content; every command has expected output.

**Type consistency:** `AnglesitePackage`, `Marker` (`formatVersion`/`siteID`/`displayName`/`createdDate`), `PackageError` (`markerMissing`/`markerUnreadable`), `Compatibility` (`current`/`readOnlyTooNew`), `createSkeleton`/`isPackage`/`sourceValidation`/`readMarker`/`writeMarker` — names are identical across all tasks. `ProjectValidator.requiredSentinels` / `.validate` / `.Result.isValid` match the real `Sources/AnglesiteCore/ProjectValidator.swift`.

## Handoff to P2

P2 (Open/create + runtime) consumes from P1: `AnglesitePackage` (layout URLs, `createSkeleton`, `readMarker`, `Compatibility`, `Marker.siteID`). P2 converts `SiteStore` from a `~/Sites` scanner into a recents registry keyed by `Marker.siteID`, wires Finder/`onOpenURL` open routing against the new document type, scaffolds new sites into `sourceURL`, and retargets the MAS bookmark + subprocess cwd to the package/`Source/`.
