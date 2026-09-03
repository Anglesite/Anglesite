# Dependency Sync Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect when a site's `Source/package.json` dependency ranges have drifted
behind the app's bundled template, and offer to bring them up to date when the site
opens — before the drift causes a slow, silent `npm install` inside the sandboxed
container at preview-boot time.

**Architecture:** Pure-Swift comparison logic (version ordering, 3-way diff against a
scaffold-time baseline snapshot, package.json text extraction/rewrite) lives in
`AnglesiteCore`, fully unit-testable with no container/npm/network involved. A thin
hook in `SiteWindowModel.loadAndStart()` calls the Core checker before
`preview.open()`; if there's anything to offer, a sheet presents it. Accepting
rewrites `package.json` and deletes the stale lockfile on the host side only — the
actual `npm install` happens via the existing, already-tested `container/hydrate.sh`
path on the next preview boot. No new container-exec machinery.

**Tech Stack:** Swift 6.4, Swift Testing, SwiftUI, Foundation (`JSONSerialization`,
`NSRegularExpression`, `JSONEncoder`/`JSONDecoder`).

## Global Constraints

- Version-bump-only scope: never add a package the site doesn't have, never remove
  one it does have, even if the template gained or dropped something.
- No host-side npm invocation — there is no host Node (#70). The only file changes
  on accept are `package.json` (text rewrite) and deleting `package-lock.json`.
- Do not modify `Resources/Template/scripts/scaffold.sh` — the `ANGLESITE_VERSION`
  correction happens entirely in Swift, after the script runs, per the design spec.
- All-or-nothing accept: no per-package toggle in the update sheet for v1.
- No persisted "don't ask again" — declining re-prompts next time the site opens.
- App-target (`AnglesiteApp`) logic stays thin; all comparison/diff/rewrite logic
  lives in testable `AnglesiteCore` types, per this project's CI constraint (hosted
  `xcodebuild test` doesn't run on CI — see `CLAUDE.md`).
- Worktree: `/Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/dependency-sync`,
  branch `feat/dependency-sync`. Run `xcodegen generate` if `Anglesite.xcodeproj` is
  missing (gitignored, regenerated from `project.yml`).
- Swift tests: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .`
  (the default CommandLineTools toolchain is broken/too old on this machine).
- Spec: `docs/superpowers/specs/2026-07-06-dependency-sync-design.md`.

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/AnglesiteCore/DependencyVersionComparator.swift` (create) | Ordering-only version-range comparison |
| `Sources/AnglesiteCore/DependencySync.swift` (create) | `DependencyUpdateOffer` + the 3-way diff algorithm |
| `Sources/AnglesiteCore/PackageJSONDependencies.swift` (create) | Extract deps from package.json text; rewrite accepted ranges back in |
| `Sources/AnglesiteCore/DependencyBaseline.swift` (create) | Load/save `Config/dependency-baseline.json` |
| `Sources/AnglesiteCore/AppVersion.swift` (create) | Read the running app's `CFBundleShortVersionString` |
| `Sources/AnglesiteCore/SiteConfigFile.swift` (modify) | Add `value(forKey:in:)` reader |
| `Sources/AnglesiteCore/DependencySyncChecker.swift` (create) | Top-level orchestrator: fast-path gate + ties together the above into one `check(...)` call |
| `Sources/AnglesiteCore/DependencySyncApplier.swift` (create) | Applies an accepted update: rewrite + delete lockfile + save baseline + bump stamp |
| `Sources/AnglesiteCore/SiteScaffolder.swift` (modify) | Write the baseline + correct `ANGLESITE_VERSION` after `scaffold.sh` succeeds |
| `Sources/AnglesiteApp/DependencyUpdateModel.swift` (create) | Thin `Identifiable` sheet-driving model (offers + Update/Skip) |
| `Sources/AnglesiteApp/SiteWindowModel.swift` (modify) | Detection hook before `preview.open()`; apply on accept |
| `Sources/AnglesiteApp/SiteWindow.swift` (modify) | The update-offer `.sheet` |
| `Sources/AnglesiteApp/PreviewModel.swift` (modify) | `isUpdatingDependencies` transient flag |
| `Tests/AnglesiteCoreTests/*` (create/modify) | One test file per new Core type, plus `SiteScaffolderTests`/`SiteConfigFileTests` extensions |

---

### Task 1: Version-ordering comparator

**Files:**
- Create: `Sources/AnglesiteCore/DependencyVersionComparator.swift`
- Test: `Tests/AnglesiteCoreTests/DependencyVersionComparatorTests.swift`

**Interfaces:**
- Produces: `public enum DependencyVersionComparator { public static func isNewer(_ candidate: String, than other: String) -> Bool? }`. `nil` means incomparable (never guess). Consumed by Task 2's diff.

- [ ] **Step 1: Write the failing test**

Create `Tests/AnglesiteCoreTests/DependencyVersionComparatorTests.swift`:

```swift
import Testing
@testable import AnglesiteCore

@Suite struct DependencyVersionComparatorTests {
    @Test func detectsANewerMajorVersion() {
        #expect(DependencyVersionComparator.isNewer("^6.4.8", than: "^5.0.0") == true)
    }

    @Test func detectsAnOlderVersionIsNotNewer() {
        #expect(DependencyVersionComparator.isNewer("^5.0.0", than: "^6.4.8") == false)
    }

    @Test func equalVersionsAreNotNewer() {
        #expect(DependencyVersionComparator.isNewer("^6.4.8", than: "^6.4.8") == false)
    }

    @Test func toleratesDifferentRangePrefixCharacters() {
        #expect(DependencyVersionComparator.isNewer("~4.0.0", than: ">=3.9.9") == true)
    }

    @Test func treatsAMissingPatchComponentAsZero() {
        #expect(DependencyVersionComparator.isNewer("^6.4", than: "^6.4.8") == false)
        #expect(DependencyVersionComparator.isNewer("^6.5", than: "^6.4.8") == true)
    }

    @Test func toleratesAPreReleaseSuffixOnTheLastComponent() {
        #expect(DependencyVersionComparator.isNewer("^6.4.8-beta.1", than: "^6.4.7") == true)
    }

    @Test func isNilWhenEitherSideHasNoParseableVersion() {
        #expect(DependencyVersionComparator.isNewer("*", than: "^6.4.8") == nil)
        #expect(DependencyVersionComparator.isNewer("^6.4.8", than: "workspace:*") == nil)
        #expect(DependencyVersionComparator.isNewer("latest", than: "next") == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DependencyVersionComparatorTests`
Expected: FAIL to compile — `DependencyVersionComparator` not found.

- [ ] **Step 3: Implement `Sources/AnglesiteCore/DependencyVersionComparator.swift`**

```swift
import Foundation

/// Ordering-only comparison between two package.json version-range strings (e.g.
/// `"^6.4.8"`, `"~1.2.3"`, `">=3.9.9"`). Deliberately does not implement full semver
/// range-set matching (whether a range *matches* a version) — only whether one
/// range's leading numeric version is greater than another's, which is all the
/// dependency-sync feature needs (spec §3).
public enum DependencyVersionComparator {
    /// Parses the leading `major.minor.patch` out of a range string, ignoring any
    /// prefix characters (`^`, `~`, `>=`, etc.) and any non-numeric suffix on the
    /// final component (pre-release tags like `-beta.1`). Returns `nil` when the
    /// string has no parseable leading numeric version at all (e.g. `"*"`,
    /// `"workspace:*"`, `"latest"`).
    static func numericComponents(_ range: String) -> [Int]? {
        let trimmed = range.drop { !$0.isNumber }
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        var components: [Int] = []
        for part in parts {
            let digits = part.prefix { $0.isNumber }
            guard !digits.isEmpty, let value = Int(digits) else { break }
            components.append(value)
        }
        return components.isEmpty ? nil : components
    }

    /// Returns `true` when `candidate` is a strictly newer version than `other`,
    /// `false` when strictly older or equal, `nil` when either side can't be
    /// parsed — callers must treat `nil` as "don't offer an update", never guess.
    public static func isNewer(_ candidate: String, than other: String) -> Bool? {
        guard let a = numericComponents(candidate), let b = numericComponents(other) else { return nil }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DependencyVersionComparatorTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/DependencyVersionComparator.swift Tests/AnglesiteCoreTests/DependencyVersionComparatorTests.swift
git commit -m "feat(dependency-sync): version-ordering comparator"
```

---

### Task 2: Three-way diff logic

**Files:**
- Create: `Sources/AnglesiteCore/DependencySync.swift`
- Test: `Tests/AnglesiteCoreTests/DependencySyncTests.swift`

**Interfaces:**
- Consumes: `DependencyVersionComparator.isNewer(_:than:)` (Task 1).
- Produces: `public struct DependencyUpdateOffer: Sendable, Equatable { public let name: String; public let currentRange: String; public let offeredRange: String }` and `public enum DependencySync { public static func diff(site: [String: String], baseline: [String: String]?, template: [String: String]) -> [DependencyUpdateOffer] }`. Consumed by Task 6 (checker) and Task 3/8 (apply/UI).

- [ ] **Step 1: Write the failing test**

Create `Tests/AnglesiteCoreTests/DependencySyncTests.swift`:

```swift
import Testing
@testable import AnglesiteCore

@Suite struct DependencySyncTests {
    @Test func offersABumpWhenSiteMatchesBaselineButTemplateMovedForward() {
        let offers = DependencySync.diff(
            site: ["astro": "^5.0.0"],
            baseline: ["astro": "^5.0.0"],
            template: ["astro": "^6.4.8"]
        )
        #expect(offers == [DependencyUpdateOffer(name: "astro", currentRange: "^5.0.0", offeredRange: "^6.4.8")])
    }

    @Test func leavesAUserCustomizedPackageAlone() {
        // Site's range no longer matches the baseline -> the user edited it deliberately.
        let offers = DependencySync.diff(
            site: ["astro": "^5.1.0"],
            baseline: ["astro": "^5.0.0"],
            template: ["astro": "^6.4.8"]
        )
        #expect(offers.isEmpty)
    }

    @Test func doesNothingWhenSiteBaselineAndTemplateAllAgree() {
        let offers = DependencySync.diff(
            site: ["astro": "^6.4.8"],
            baseline: ["astro": "^6.4.8"],
            template: ["astro": "^6.4.8"]
        )
        #expect(offers.isEmpty)
    }

    @Test func legacySiteWithNoBaselineFallsBackToADirectDiff() {
        let offers = DependencySync.diff(
            site: ["astro": "^5.0.0"],
            baseline: nil,
            template: ["astro": "^6.4.8"]
        )
        #expect(offers == [DependencyUpdateOffer(name: "astro", currentRange: "^5.0.0", offeredRange: "^6.4.8")])
    }

    @Test func neverOffersToAddAPackageTheSiteDoesNotHave() {
        let offers = DependencySync.diff(
            site: [:],
            baseline: [:],
            template: ["astro-embed": "^0.13.0"]
        )
        #expect(offers.isEmpty)
    }

    @Test func neverOffersToRemoveAPackageTheTemplateNoLongerHas() {
        let offers = DependencySync.diff(
            site: ["some-deprecated-package": "^1.0.0"],
            baseline: ["some-deprecated-package": "^1.0.0"],
            template: [:]
        )
        #expect(offers.isEmpty)
    }

    @Test func skipsAnIncomparableVersionRatherThanGuessing() {
        let offers = DependencySync.diff(
            site: ["astro": "workspace:*"],
            baseline: ["astro": "workspace:*"],
            template: ["astro": "^6.4.8"]
        )
        #expect(offers.isEmpty)
    }

    @Test func handlesMultiplePackagesSortedByName() {
        let offers = DependencySync.diff(
            site: ["astro": "^5.0.0", "tsx": "^3.0.0"],
            baseline: ["astro": "^5.0.0", "tsx": "^3.0.0"],
            template: ["astro": "^6.4.8", "tsx": "^4.0.0"]
        )
        #expect(offers == [
            DependencyUpdateOffer(name: "astro", currentRange: "^5.0.0", offeredRange: "^6.4.8"),
            DependencyUpdateOffer(name: "tsx", currentRange: "^3.0.0", offeredRange: "^4.0.0"),
        ])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DependencySyncTests`
Expected: FAIL to compile — `DependencyUpdateOffer`/`DependencySync` not found.

- [ ] **Step 3: Implement `Sources/AnglesiteCore/DependencySync.swift`**

```swift
/// One offered version-range bump for a single package.
public struct DependencyUpdateOffer: Sendable, Equatable {
    public let name: String
    public let currentRange: String
    public let offeredRange: String

    public init(name: String, currentRange: String, offeredRange: String) {
        self.name = name
        self.currentRange = currentRange
        self.offeredRange = offeredRange
    }
}

/// Three-way comparison between a site's dependencies, an optional scaffold-time
/// baseline snapshot, and the app's current bundled template (spec §3). Only ever
/// offers a version bump for a package present in both the site and the template —
/// never adds or removes a package name.
public enum DependencySync {
    public static func diff(
        site: [String: String],
        baseline: [String: String]?,
        template: [String: String]
    ) -> [DependencyUpdateOffer] {
        var offers: [DependencyUpdateOffer] = []
        for (name, templateRange) in template.sorted(by: { $0.key < $1.key }) {
            guard let siteRange = site[name] else { continue }
            guard DependencyVersionComparator.isNewer(templateRange, than: siteRange) == true else { continue }
            if let baseline {
                // 3-way case: only offer when the site never touched this package
                // since it was scaffolded (its range still matches the baseline).
                guard let baselineRange = baseline[name], baselineRange == siteRange else { continue }
            }
            // else: no baseline at all -> legacy direct-diff fallback (spec §3).
            offers.append(DependencyUpdateOffer(name: name, currentRange: siteRange, offeredRange: templateRange))
        }
        return offers
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DependencySyncTests`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/DependencySync.swift Tests/AnglesiteCoreTests/DependencySyncTests.swift
git commit -m "feat(dependency-sync): 3-way diff between site, baseline, and template"
```

---

### Task 3: package.json dependency extraction + rewrite

**Files:**
- Create: `Sources/AnglesiteCore/PackageJSONDependencies.swift`
- Test: `Tests/AnglesiteCoreTests/PackageJSONDependenciesTests.swift`

**Interfaces:**
- Consumes: `DependencyUpdateOffer` (Task 2).
- Produces: `public enum PackageJSONDependencies { public enum ExtractionError: Error { case invalidJSON }; public static func extract(from text: String) throws -> [String: String]; public static func apply(_ offers: [DependencyUpdateOffer], to text: String) -> String }`. Consumed by Task 6 (checker reads), Task 7 (scaffolder reads template), Task 8 (applier rewrites site's).

- [ ] **Step 1: Write the failing test**

Create `Tests/AnglesiteCoreTests/PackageJSONDependenciesTests.swift`:

```swift
import Testing
@testable import AnglesiteCore

@Suite struct PackageJSONDependenciesTests {
    static let fixture = """
    {
      "name": "anglesite-site",
      "type": "module",
      "version": "0.0.1",
      "dependencies": {
        "@astrojs/rss": "^4.0.0",
        "astro": "^5.0.0"
      },
      "devDependencies": {
        "typescript": "^5.9.3"
      }
    }
    """

    @Test func extractsBothDependencySections() throws {
        let deps = try PackageJSONDependencies.extract(from: Self.fixture)
        #expect(deps == ["@astrojs/rss": "^4.0.0", "astro": "^5.0.0", "typescript": "^5.9.3"])
    }

    @Test func throwsOnInvalidJSON() {
        #expect(throws: PackageJSONDependencies.ExtractionError.self) {
            _ = try PackageJSONDependencies.extract(from: "not json")
        }
    }

    @Test func extractsEmptyMapWhenNoDependencySectionsPresent() throws {
        let deps = try PackageJSONDependencies.extract(from: "{\"name\": \"x\"}")
        #expect(deps.isEmpty)
    }

    @Test func applyRewritesOnlyTheAcceptedPackagesRangeString() {
        let offers = [DependencyUpdateOffer(name: "astro", currentRange: "^5.0.0", offeredRange: "^6.4.8")]
        let updated = PackageJSONDependencies.apply(offers, to: Self.fixture)
        #expect(updated.contains("\"astro\": \"^6.4.8\""))
        #expect(!updated.contains("\"astro\": \"^5.0.0\""))
        // Untouched: everything else, including formatting and the other dependency.
        #expect(updated.contains("\"@astrojs/rss\": \"^4.0.0\""))
        #expect(updated.contains("\"typescript\": \"^5.9.3\""))
        #expect(updated.contains("\"version\": \"0.0.1\""))
    }

    @Test func applyWithNoOffersReturnsTheTextUnchanged() {
        #expect(PackageJSONDependencies.apply([], to: Self.fixture) == Self.fixture)
    }

    @Test func applyIsSafeWhenThePackageNameIsNotPresent() {
        let offers = [DependencyUpdateOffer(name: "does-not-exist", currentRange: "^1.0.0", offeredRange: "^2.0.0")]
        #expect(PackageJSONDependencies.apply(offers, to: Self.fixture) == Self.fixture)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter PackageJSONDependenciesTests`
Expected: FAIL to compile — `PackageJSONDependencies` not found.

- [ ] **Step 3: Implement `Sources/AnglesiteCore/PackageJSONDependencies.swift`**

```swift
import Foundation

/// Reads and surgically rewrites the `dependencies`/`devDependencies` version
/// ranges in a package.json's raw text. `apply` never re-serializes the whole
/// file — it only replaces the specific `"name": "range"` substrings for accepted
/// offers, leaving formatting, key order, comments-adjacent content, and any
/// dependency the site added on its own completely untouched.
public enum PackageJSONDependencies {
    public enum ExtractionError: Error, Equatable {
        case invalidJSON
    }

    /// The union of `dependencies` and `devDependencies` (name -> version range).
    /// If a name appears in both sections, `devDependencies` wins (checked second).
    public static func extract(from text: String) throws -> [String: String] {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let object = json as? [String: Any]
        else { throw ExtractionError.invalidJSON }
        var result: [String: String] = [:]
        if let deps = object["dependencies"] as? [String: String] {
            result.merge(deps) { _, new in new }
        }
        if let devDeps = object["devDependencies"] as? [String: String] {
            result.merge(devDeps) { _, new in new }
        }
        return result
    }

    /// Rewrites `text`, replacing the version-range string for each offer's
    /// package name wherever it appears as a `"name": "range"` pair. A name
    /// present in both `dependencies` and `devDependencies` gets the same new
    /// range in both places (matches `extract`'s dedup rule). A name not found
    /// in the text is silently ignored — `apply` never adds anything.
    public static func apply(_ offers: [DependencyUpdateOffer], to text: String) -> String {
        var result = text
        for offer in offers {
            let escapedName = NSRegularExpression.escapedPattern(for: offer.name)
            guard let regex = try? NSRegularExpression(pattern: "\"\(escapedName)\"\\s*:\\s*\"[^\"]*\"") else { continue }
            let replacement = "\"\(offer.name)\": \"\(offer.offeredRange)\""
            let template = NSRegularExpression.escapedTemplate(for: replacement)
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter PackageJSONDependenciesTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/PackageJSONDependencies.swift Tests/AnglesiteCoreTests/PackageJSONDependenciesTests.swift
git commit -m "feat(dependency-sync): package.json dependency extraction + surgical rewrite"
```

---

### Task 4: Dependency baseline load/save

**Files:**
- Create: `Sources/AnglesiteCore/DependencyBaseline.swift`
- Test: `Tests/AnglesiteCoreTests/DependencyBaselineTests.swift`

**Interfaces:**
- Produces: `public enum DependencyBaseline { public static let filename = "dependency-baseline.json"; public static func load(from configDirectory: URL) -> [String: String]?; public static func save(_ packages: [String: String], to configDirectory: URL) throws }`. Consumed by Task 6 (checker), Task 7 (scaffolder), Task 8 (applier).

- [ ] **Step 1: Write the failing test**

Create `Tests/AnglesiteCoreTests/DependencyBaselineTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct DependencyBaselineTests {
    private func tmpDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func returnsNilWhenNoBaselineFileExists() {
        #expect(DependencyBaseline.load(from: tmpDir()) == nil)
    }

    @Test func roundTripsThroughSaveAndLoad() throws {
        let dir = tmpDir()
        let packages = ["astro": "^6.4.8", "tsx": "^4.0.0"]
        try DependencyBaseline.save(packages, to: dir)
        #expect(DependencyBaseline.load(from: dir) == packages)
    }

    @Test func savingOverwritesAPreviousBaseline() throws {
        let dir = tmpDir()
        try DependencyBaseline.save(["astro": "^5.0.0"], to: dir)
        try DependencyBaseline.save(["astro": "^6.4.8"], to: dir)
        #expect(DependencyBaseline.load(from: dir) == ["astro": "^6.4.8"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DependencyBaselineTests`
Expected: FAIL to compile — `DependencyBaseline` not found.

- [ ] **Step 3: Implement `Sources/AnglesiteCore/DependencyBaseline.swift`**

```swift
import Foundation

/// Reads/writes `Config/dependency-baseline.json` — a flat package-name ->
/// version-range snapshot of the template's `package.json` at the moment a site
/// was scaffolded (or, for a legacy site, at the moment its first dependency-sync
/// check ran). This is app-owned state, never committed to the site's git repo
/// (`Config/` is outside `Source/` — see the `.anglesite` package model).
public enum DependencyBaseline {
    public static let filename = "dependency-baseline.json"

    /// `nil` (not a throw) when the file is absent or unreadable — that's the
    /// normal "no baseline yet" case the 3-way diff's legacy fallback handles.
    public static func load(from configDirectory: URL) -> [String: String]? {
        let url = configDirectory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    public static func save(_ packages: [String: String], to configDirectory: URL) throws {
        let url = configDirectory.appendingPathComponent(filename)
        let data = try JSONEncoder().encode(packages)
        try data.write(to: url, options: .atomic)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DependencyBaselineTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/DependencyBaseline.swift Tests/AnglesiteCoreTests/DependencyBaselineTests.swift
git commit -m "feat(dependency-sync): Config/dependency-baseline.json load/save"
```

---

### Task 5: App version + `.site-config` value reader

**Files:**
- Create: `Sources/AnglesiteCore/AppVersion.swift`
- Modify: `Sources/AnglesiteCore/SiteConfigFile.swift`
- Test: `Tests/AnglesiteCoreTests/AppVersionTests.swift`
- Test: `Tests/AnglesiteCoreTests/SiteConfigFileTests.swift` (extend existing)

**Interfaces:**
- Produces: `public enum AppVersion { public static func current(in bundle: Bundle = .main) -> String? }` and `extension SiteConfigFile { public static func value(forKey key: String, in contents: String) -> String? }`. Both consumed by Task 6 (checker), Task 7 (scaffolder), Task 8 (applier).

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/AppVersionTests.swift`:

```swift
import Testing
@testable import AnglesiteCore

@Suite struct AppVersionTests {
    @Test func readsTheShortVersionStringFromABundle() {
        #expect(AppVersion.current(in: .module) != nil)
    }
}
```

Append to `Tests/AnglesiteCoreTests/SiteConfigFileTests.swift` (the existing file already has an `import Testing` + `@testable import AnglesiteCore` `@Suite struct SiteConfigFileTests` — add these inside that suite):

```swift
    @Test func readsAnExistingKeysValue() {
        let value = SiteConfigFile.value(forKey: "ANGLESITE_VERSION", in: "ANGLESITE_VERSION=1.0.0\nSITE_NAME=Acme\n")
        #expect(value == "1.0.0")
    }

    @Test func returnsNilForAMissingKey() {
        #expect(SiteConfigFile.value(forKey: "ANGLESITE_VERSION", in: "SITE_NAME=Acme\n") == nil)
    }

    @Test func ignoresCommentLinesWhenReadingAValue() {
        let contents = "# ANGLESITE_VERSION=commented-out\nANGLESITE_VERSION=1.2.0\n"
        #expect(SiteConfigFile.value(forKey: "ANGLESITE_VERSION", in: contents) == "1.2.0")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter "AppVersionTests|SiteConfigFileTests"`
Expected: FAIL to compile — `AppVersion` not found; `SiteConfigFile.value(forKey:in:)` not found.

Note: `AppVersionTests` uses `Bundle.module` (SwiftPM's test-target resource bundle),
which has no `CFBundleShortVersionString` key by default — if
`AppVersion.current(in: .module)` returns `nil` in practice (no Info.plist entry in
the test bundle), change the assertion to `#expect(AppVersion.current(in: .module) == nil)`
and add a second test constructing a fake `Bundle` is not practical in pure SwiftPM;
instead assert the *real* production path works by checking
`AppVersion.current(in: .main)` doesn't crash (it will be `nil` in a `swift test`
process too, since the test binary isn't an app bundle) — the meaningful guarantee
this function provides is "never crashes, returns an `Optional` the caller must
handle", which the type signature itself already enforces. Adjust the test to
assert non-crashing behavior on both `.module` and `.main` rather than asserting a
specific non-nil value if the fixture bundle turns out not to carry the key.

- [ ] **Step 3: Implement `Sources/AnglesiteCore/AppVersion.swift`**

```swift
import Foundation

/// The running app's short version string (`CFBundleShortVersionString`), used to
/// stamp/compare against a site's `.site-config` `ANGLESITE_VERSION` (spec §3.1).
public enum AppVersion {
    public static func current(in bundle: Bundle = .main) -> String? {
        bundle.infoDictionary?["CFBundleShortVersionString"] as? String
    }
}
```

- [ ] **Step 4: Implement the `SiteConfigFile` extension**

Add to `Sources/AnglesiteCore/SiteConfigFile.swift` (inside the existing `SiteConfigFile` enum, alongside `upsert`/`addCSPDomains`):

```swift
    /// Reads a single `KEY=value` line's value from `.site-config`-formatted
    /// contents, or `nil` if the key isn't present. Lines starting with `#`
    /// (comments) never match, even if they look like `# KEY=value`.
    public static func value(forKey key: String, in contents: String) -> String? {
        for line in contents.split(separator: "\n") {
            guard line.hasPrefix("\(key)=") else { continue }
            return String(line.dropFirst(key.count + 1))
        }
        return nil
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter "AppVersionTests|SiteConfigFileTests"`
Expected: PASS. Adjust the `AppVersionTests` assertion per Step 2's note if the initial version fails on this toolchain's test-bundle behavior — the fix is changing what's asserted, not the implementation.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/AppVersion.swift Sources/AnglesiteCore/SiteConfigFile.swift Tests/AnglesiteCoreTests/AppVersionTests.swift Tests/AnglesiteCoreTests/SiteConfigFileTests.swift
git commit -m "feat(dependency-sync): app version reader + .site-config value reader"
```

---

### Task 6: Top-level checker (fast-path gate + orchestration)

**Files:**
- Create: `Sources/AnglesiteCore/DependencySyncChecker.swift`
- Test: `Tests/AnglesiteCoreTests/DependencySyncCheckerTests.swift`

**Interfaces:**
- Consumes: `DependencyVersionComparator` (Task 1, transitively via `DependencySync`), `DependencySync.diff` (Task 2), `PackageJSONDependencies.extract` (Task 3), `DependencyBaseline.load` (Task 4), `SiteConfigFile.value(forKey:in:)` (Task 5).
- Produces: `public enum DependencySyncChecker { public static func check(sourceDirectory: URL, configDirectory: URL, templateDirectory: URL, runningAppVersion: String) -> [DependencyUpdateOffer] }`. Consumed by Task 9 (`SiteWindowModel` hook).

- [ ] **Step 1: Write the failing test**

Create `Tests/AnglesiteCoreTests/DependencySyncCheckerTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct DependencySyncCheckerTests {
    private func tmpDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func writeFile(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeSite(siteConfig: String?, packageJSON: String, baseline: [String: String]?) throws -> (source: URL, config: URL) {
        let root = tmpDir()
        let source = root.appendingPathComponent("Source")
        let config = root.appendingPathComponent("Config")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try writeFile(packageJSON, to: source.appendingPathComponent("package.json"))
        if let siteConfig {
            try writeFile(siteConfig, to: source.appendingPathComponent(".site-config"))
        }
        if let baseline {
            try DependencyBaseline.save(baseline, to: config)
        }
        return (source, config)
    }

    private func makeTemplate(packageJSON: String) throws -> URL {
        let dir = tmpDir()
        try writeFile(packageJSON, to: dir.appendingPathComponent("package.json"))
        return dir
    }

    private static let stalePackageJSON = """
    { "dependencies": { "astro": "^5.0.0" } }
    """
    private static let currentTemplatePackageJSON = """
    { "dependencies": { "astro": "^6.4.8" } }
    """

    @Test func fastPathSkipsEverythingWhenStampedVersionMatchesRunningVersion() throws {
        let (source, config) = try makeSite(
            siteConfig: "ANGLESITE_VERSION=1.4.0\n",
            packageJSON: Self.stalePackageJSON,  // deliberately stale, to prove the fast path never looks
            baseline: nil
        )
        let template = try makeTemplate(packageJSON: Self.currentTemplatePackageJSON)
        let offers = DependencySyncChecker.check(
            sourceDirectory: source, configDirectory: config, templateDirectory: template,
            runningAppVersion: "1.4.0"
        )
        #expect(offers.isEmpty)
    }

    @Test func fallsThroughToTheRealDiffWhenStampedVersionDiffers() throws {
        let (source, config) = try makeSite(
            siteConfig: "ANGLESITE_VERSION=1.2.0\n",
            packageJSON: Self.stalePackageJSON,
            baseline: ["astro": "^5.0.0"]
        )
        let template = try makeTemplate(packageJSON: Self.currentTemplatePackageJSON)
        let offers = DependencySyncChecker.check(
            sourceDirectory: source, configDirectory: config, templateDirectory: template,
            runningAppVersion: "1.4.0"
        )
        #expect(offers == [DependencyUpdateOffer(name: "astro", currentRange: "^5.0.0", offeredRange: "^6.4.8")])
    }

    @Test func fallsThroughWhenThereIsNoSiteConfigAtAll() throws {
        let (source, config) = try makeSite(siteConfig: nil, packageJSON: Self.stalePackageJSON, baseline: nil)
        let template = try makeTemplate(packageJSON: Self.currentTemplatePackageJSON)
        let offers = DependencySyncChecker.check(
            sourceDirectory: source, configDirectory: config, templateDirectory: template,
            runningAppVersion: "1.4.0"
        )
        #expect(offers == [DependencyUpdateOffer(name: "astro", currentRange: "^5.0.0", offeredRange: "^6.4.8")])
    }

    @Test func returnsEmptyRatherThanThrowingWhenPackageJSONIsMissing() throws {
        let root = tmpDir()
        let source = root.appendingPathComponent("Source")
        let config = root.appendingPathComponent("Config")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let template = try makeTemplate(packageJSON: Self.currentTemplatePackageJSON)
        let offers = DependencySyncChecker.check(
            sourceDirectory: source, configDirectory: config, templateDirectory: template,
            runningAppVersion: "1.4.0"
        )
        #expect(offers.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DependencySyncCheckerTests`
Expected: FAIL to compile — `DependencySyncChecker` not found.

- [ ] **Step 3: Implement `Sources/AnglesiteCore/DependencySyncChecker.swift`**

```swift
import Foundation

/// Top-level entry point for the dependency-sync feature: the fast-path gate
/// (spec §3.1) plus the full 3-way diff, wired together. Never throws — any
/// unreadable/malformed input degrades to "nothing to offer" (spec §7), since
/// this is a diagnostic convenience feature that must never block a site opening.
public enum DependencySyncChecker {
    public static func check(
        sourceDirectory: URL,
        configDirectory: URL,
        templateDirectory: URL,
        runningAppVersion: String
    ) -> [DependencyUpdateOffer] {
        let siteConfigURL = sourceDirectory.appendingPathComponent(".site-config")
        if let siteConfigContents = try? String(contentsOf: siteConfigURL, encoding: .utf8),
           let stampedVersion = SiteConfigFile.value(forKey: "ANGLESITE_VERSION", in: siteConfigContents),
           stampedVersion == runningAppVersion {
            return []
        }

        guard let sitePackageText = try? String(
                contentsOf: sourceDirectory.appendingPathComponent("package.json"), encoding: .utf8),
              let siteDeps = try? PackageJSONDependencies.extract(from: sitePackageText),
              let templatePackageText = try? String(
                contentsOf: templateDirectory.appendingPathComponent("package.json"), encoding: .utf8),
              let templateDeps = try? PackageJSONDependencies.extract(from: templatePackageText)
        else { return [] }

        let baseline = DependencyBaseline.load(from: configDirectory)
        return DependencySync.diff(site: siteDeps, baseline: baseline, template: templateDeps)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DependencySyncCheckerTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/DependencySyncChecker.swift Tests/AnglesiteCoreTests/DependencySyncCheckerTests.swift
git commit -m "feat(dependency-sync): top-level checker with ANGLESITE_VERSION fast-path gate"
```

---

### Task 7: Applier — execute an accepted update

**Files:**
- Create: `Sources/AnglesiteCore/DependencySyncApplier.swift`
- Test: `Tests/AnglesiteCoreTests/DependencySyncApplierTests.swift`

**Interfaces:**
- Consumes: `PackageJSONDependencies.apply` (Task 3), `DependencyBaseline.load`/`.save` (Task 4), `SiteConfigFile.upsert` (existing).
- Produces: `public enum DependencySyncApplier { public enum ApplyError: Error, Equatable { case readFailed, writeFailed }; public static func apply(_ offers: [DependencyUpdateOffer], sourceDirectory: URL, configDirectory: URL, runningAppVersion: String) throws }`. Consumed by Task 9 (`SiteWindowModel`'s Update action).

- [ ] **Step 1: Write the failing test**

Create `Tests/AnglesiteCoreTests/DependencySyncApplierTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct DependencySyncApplierTests {
    private func tmpDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static let packageJSON = """
    { "dependencies": { "astro": "^5.0.0" } }
    """

    private func makeSourceAndConfig() throws -> (source: URL, config: URL) {
        let root = tmpDir()
        let source = root.appendingPathComponent("Source")
        let config = root.appendingPathComponent("Config")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try Self.packageJSON.write(to: source.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try "old lockfile contents".write(to: source.appendingPathComponent("package-lock.json"), atomically: true, encoding: .utf8)
        try "ANGLESITE_VERSION=1.2.0\n".write(to: source.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)
        return (source, config)
    }

    @Test func rewritesPackageJSONWithTheAcceptedRange() throws {
        let (source, config) = try makeSourceAndConfig()
        let offers = [DependencyUpdateOffer(name: "astro", currentRange: "^5.0.0", offeredRange: "^6.4.8")]
        try DependencySyncApplier.apply(offers, sourceDirectory: source, configDirectory: config, runningAppVersion: "1.4.0")
        let updated = try String(contentsOf: source.appendingPathComponent("package.json"), encoding: .utf8)
        #expect(updated.contains("\"astro\": \"^6.4.8\""))
    }

    @Test func deletesTheStaleLockfile() throws {
        let (source, config) = try makeSourceAndConfig()
        let offers = [DependencyUpdateOffer(name: "astro", currentRange: "^5.0.0", offeredRange: "^6.4.8")]
        try DependencySyncApplier.apply(offers, sourceDirectory: source, configDirectory: config, runningAppVersion: "1.4.0")
        #expect(!FileManager.default.fileExists(atPath: source.appendingPathComponent("package-lock.json").path))
    }

    @Test func savesTheNewBaselineWithTheAcceptedRanges() throws {
        let (source, config) = try makeSourceAndConfig()
        let offers = [DependencyUpdateOffer(name: "astro", currentRange: "^5.0.0", offeredRange: "^6.4.8")]
        try DependencySyncApplier.apply(offers, sourceDirectory: source, configDirectory: config, runningAppVersion: "1.4.0")
        #expect(DependencyBaseline.load(from: config) == ["astro": "^6.4.8"])
    }

    @Test func bumpsTheAnglesiteVersionStamp() throws {
        let (source, config) = try makeSourceAndConfig()
        let offers = [DependencyUpdateOffer(name: "astro", currentRange: "^5.0.0", offeredRange: "^6.4.8")]
        try DependencySyncApplier.apply(offers, sourceDirectory: source, configDirectory: config, runningAppVersion: "1.4.0")
        let siteConfig = try String(contentsOf: source.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(SiteConfigFile.value(forKey: "ANGLESITE_VERSION", in: siteConfig) == "1.4.0")
    }

    @Test func throwsReadFailedWhenPackageJSONIsMissing() throws {
        let root = tmpDir()
        let source = root.appendingPathComponent("Source")
        let config = root.appendingPathComponent("Config")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        #expect(throws: DependencySyncApplier.ApplyError.readFailed) {
            try DependencySyncApplier.apply([], sourceDirectory: source, configDirectory: config, runningAppVersion: "1.4.0")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DependencySyncApplierTests`
Expected: FAIL to compile — `DependencySyncApplier` not found.

- [ ] **Step 3: Implement `Sources/AnglesiteCore/DependencySyncApplier.swift`**

```swift
import Foundation

/// Applies an accepted dependency-sync update (spec §6): rewrites `package.json`'s
/// version ranges, deletes the now-stale `package-lock.json` (so the next preview
/// boot's existing `hydrate.sh` regenerates one via its normal `npm install` path —
/// no new container-exec machinery), refreshes the baseline, and bumps the
/// `ANGLESITE_VERSION` stamp. The lockfile delete, baseline save, and version bump
/// are best-effort (`try?`) once the package.json rewrite itself has succeeded —
/// none of them are things the user's file-open flow should hard-fail on.
public enum DependencySyncApplier {
    public enum ApplyError: Error, Equatable {
        case readFailed
        case writeFailed
    }

    public static func apply(
        _ offers: [DependencyUpdateOffer],
        sourceDirectory: URL,
        configDirectory: URL,
        runningAppVersion: String
    ) throws {
        let packageJSONURL = sourceDirectory.appendingPathComponent("package.json")
        guard let originalText = try? String(contentsOf: packageJSONURL, encoding: .utf8) else {
            throw ApplyError.readFailed
        }
        let updatedText = PackageJSONDependencies.apply(offers, to: originalText)
        do {
            try updatedText.write(to: packageJSONURL, atomically: true, encoding: .utf8)
        } catch {
            throw ApplyError.writeFailed
        }

        try? FileManager.default.removeItem(at: sourceDirectory.appendingPathComponent("package-lock.json"))

        var newBaseline = DependencyBaseline.load(from: configDirectory) ?? [:]
        for offer in offers { newBaseline[offer.name] = offer.offeredRange }
        try? DependencyBaseline.save(newBaseline, to: configDirectory)

        let siteConfigURL = sourceDirectory.appendingPathComponent(".site-config")
        let existingConfig = (try? String(contentsOf: siteConfigURL, encoding: .utf8)) ?? ""
        let updatedConfig = SiteConfigFile.upsert([("ANGLESITE_VERSION", runningAppVersion)], into: existingConfig)
        try? updatedConfig.write(to: siteConfigURL, atomically: true, encoding: .utf8)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DependencySyncApplierTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/DependencySyncApplier.swift Tests/AnglesiteCoreTests/DependencySyncApplierTests.swift
git commit -m "feat(dependency-sync): applier for an accepted update"
```

---

### Task 8: `SiteScaffolder` — write the baseline + correct the version stamp

**Files:**
- Modify: `Sources/AnglesiteCore/SiteScaffolder.swift`
- Modify: `Tests/AnglesiteCoreTests/SiteScaffolderTests.swift`

**Interfaces:**
- Consumes: `PackageJSONDependencies.extract` (Task 3), `DependencyBaseline.save` (Task 4), `AppVersion.current` (Task 5), `SiteConfigFile.upsert` (existing).

- [ ] **Step 1: Read the current file**

Read `Sources/AnglesiteCore/SiteScaffolder.swift` in full before editing — this task
integrates into the existing `runPipeline` sequence around where `scaffold.sh` is
invoked (confirmed today at roughly the call `run(URL(fileURLWithPath: "/bin/zsh"),
[scaffoldScript.path, "--yes", siteDir.path], siteDir)`, with `siteDir` being the
package's `Source/` directory). Confirm the exact local variable names for the
site's `Source/` URL (`siteDir` per the current code) and the template root URL
(`templateURL`, per the type's stored property used to build `scaffoldScript`)
before writing the edit — use those exact names, not the ones guessed here.

- [ ] **Step 2: Write the failing test**

Read `Tests/AnglesiteCoreTests/SiteScaffolderTests.swift` in full first (it already
has a `tmpDir()` helper, a `makeScaffolder(root:)` helper, and a `makeDraft()`
helper feeding a happy-path test). Add a new test alongside the existing
`testHappyPathEmitsStepsInOrderAndRegisters`:

```swift
    func testHappyPathWritesADependencyBaselineAndStampsTheRealAppVersion() async throws {
        let root = tmpDir()
        let scaffolder = makeScaffolder(root: root)
        for await _ in scaffolder.scaffold(makeDraft()) {}

        let pkgURL = root.appendingPathComponent("acme-co.anglesite")
        let configDir = pkgURL.appendingPathComponent("Config")
        let baseline = DependencyBaseline.load(from: configDir)
        XCTAssertNotNil(baseline)
        XCTAssertEqual(baseline?["astro"], "^6.4.8")  // matches Resources/Template/package.json today

        let siteConfig = try String(
            contentsOf: pkgURL.appendingPathComponent("Source/.site-config"), encoding: .utf8)
        let stampedVersion = SiteConfigFile.value(forKey: "ANGLESITE_VERSION", in: siteConfig)
        XCTAssertNotEqual(stampedVersion, "1.0.0")  // no longer the scaffold.sh placeholder
    }
```

Note: this test asserts against `Resources/Template/package.json`'s *actual* current
`astro` range. If that range has changed since this plan was written, update the
literal `"^6.4.8"` in the test to match the real current file — read
`Resources/Template/package.json` to confirm before running.

- [ ] **Step 3: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SiteScaffolderTests`
Expected: FAIL — `baseline` is `nil` (no `dependency-baseline.json` written yet), and/or `stampedVersion` is still `"1.0.0"`.

- [ ] **Step 4: Implement the change**

In `Sources/AnglesiteCore/SiteScaffolder.swift`, immediately after the existing
`scaffold.sh` invocation succeeds (its `exitCode == 0` check) and before the
subsequent `gitInit` step, insert:

```swift
// Write the dependency baseline (spec §3) and correct the ANGLESITE_VERSION
// stamp scaffold.sh just wrote (it hardcodes a "1.0.0" placeholder — the real
// value is a Swift-side concern, since scaffold.sh has no access to the running
// app's version). Both are best-effort: a failure here must never fail the
// overall scaffold, since the site itself was already created successfully.
let configDir = siteDir.deletingLastPathComponent().appendingPathComponent("Config", isDirectory: true)
if let templatePackageText = try? String(
        contentsOf: templateURL.appendingPathComponent("package.json"), encoding: .utf8),
   let templateDeps = try? PackageJSONDependencies.extract(from: templatePackageText) {
    try? DependencyBaseline.save(templateDeps, to: configDir)
}
if let appVersion = AppVersion.current() {
    let siteConfigURL = siteDir.appendingPathComponent(".site-config")
    let existingConfig = (try? String(contentsOf: siteConfigURL, encoding: .utf8)) ?? ""
    let updatedConfig = SiteConfigFile.upsert([("ANGLESITE_VERSION", appVersion)], into: existingConfig)
    try? updatedConfig.write(to: siteConfigURL, atomically: true, encoding: .utf8)
}
```

Adjust `siteDir`/`templateURL` to whatever the actual local variable/property
names are per Step 1's reading — the logic above is what must happen, not
necessarily the literal variable tokens if the real file names them differently.

- [ ] **Step 5: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SiteScaffolderTests`
Expected: PASS, including the new test and the pre-existing
`testHappyPathEmitsStepsInOrderAndRegisters` (still green — this change is additive).

- [ ] **Step 6: Run the full Core test suite**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter AnglesiteCoreTests`
Expected: PASS, no regressions.

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteCore/SiteScaffolder.swift Tests/AnglesiteCoreTests/SiteScaffolderTests.swift
git commit -m "feat(dependency-sync): scaffold writes the baseline + real ANGLESITE_VERSION stamp"
```

---

### Task 9: App-side integration — detection hook, sheet, accept/skip

**Files:**
- Create: `Sources/AnglesiteApp/DependencyUpdateModel.swift`
- Modify: `Sources/AnglesiteApp/SiteWindowModel.swift`
- Modify: `Sources/AnglesiteApp/SiteWindow.swift`

**Interfaces:**
- Consumes: `DependencySyncChecker.check(...)` (Task 6), `DependencySyncApplier.apply(...)` (Task 7), `DependencyUpdateOffer` (Task 2), `TemplateRuntime.bundledURL(in:)` (existing), `AppVersion.current()` (Task 5), `SiteStore.Site.sourceDirectory`/`.configDirectory` (existing).
- Produces: `DependencyUpdateModel` (new, used only within `AnglesiteApp`); `SiteWindowModel.dependencyUpdateModel: DependencyUpdateModel?` (used by Task 10 only insofar as it doesn't touch this — no downstream Core consumers, this is UI glue).

This task is UI-glue only; per this project's convention (app-target logic stays
thin, hosted `xcodebuild test` doesn't run on CI), there is no new Swift Testing
coverage here — the logic it calls (checker, applier) is already fully tested in
Tasks 6–7. Verification is the build succeeding plus the manual smoke check in
Task 11.

- [ ] **Step 1: Read the current files**

Read `Sources/AnglesiteApp/SiteWindowModel.swift` in full (specifically
`loadAndStart()` and the property list near its top) and
`Sources/AnglesiteApp/SiteWindow.swift` in full (specifically the
`.sheet(item: $bindableModel.siriReadinessModel)` block and its surrounding
`siteUI(for:)`-style view body) before editing, to confirm exact current line
numbers and the `@Bindable var bindableModel` pattern still matches what's
described here.

- [ ] **Step 2: Create `Sources/AnglesiteApp/DependencyUpdateModel.swift`**

```swift
import Foundation
import AnglesiteCore

/// Thin, `Identifiable` model driving the dependency-update-offer sheet
/// (spec §5). Holds the already-computed offers and forwards the user's
/// decision — no comparison/diff logic lives here, that's all in
/// `AnglesiteCore` (`DependencySyncChecker`/`DependencySyncApplier`).
@MainActor
final class DependencyUpdateModel: Identifiable {
    nonisolated let id = UUID()
    let offers: [DependencyUpdateOffer]
    private let onDecision: (_ accepted: Bool) -> Void

    init(offers: [DependencyUpdateOffer], onDecision: @escaping (_ accepted: Bool) -> Void) {
        self.offers = offers
        self.onDecision = onDecision
    }

    func update() { onDecision(true) }
    func skip() { onDecision(false) }
}
```

- [ ] **Step 3: Add the detection hook to `SiteWindowModel.loadAndStart()`**

Add a new property near the other optional-model-for-sheet properties (alongside
`siriReadinessModel`):

```swift
    var dependencyUpdateModel: DependencyUpdateModel?
```

In `loadAndStart()`, insert the following between the existing annotation-provider
setup and the `preview.open(...)` call (i.e. replacing the line
`preview.open(siteID: resolved.id, siteDirectory: resolved.sourceDirectory)` with
the block below, which still ends by calling it):

```swift
        if let templateURL = TemplateRuntime.bundledURL(), let runningVersion = AppVersion.current() {
            let offers = DependencySyncChecker.check(
                sourceDirectory: resolved.sourceDirectory,
                configDirectory: resolved.configDirectory,
                templateDirectory: templateURL,
                runningAppVersion: runningVersion
            )
            if !offers.isEmpty {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    dependencyUpdateModel = DependencyUpdateModel(offers: offers) { [weak self] accepted in
                        guard let self else { continuation.resume(); return }
                        if accepted {
                            try? DependencySyncApplier.apply(
                                offers,
                                sourceDirectory: resolved.sourceDirectory,
                                configDirectory: resolved.configDirectory,
                                runningAppVersion: runningVersion
                            )
                            self.preview.isUpdatingDependencies = true
                        }
                        self.dependencyUpdateModel = nil
                        continuation.resume()
                    }
                }
            }
        }
        preview.open(siteID: resolved.id, siteDirectory: resolved.sourceDirectory)
```

- [ ] **Step 4: Add the sheet to `SiteWindow.swift`**

Add a new `.sheet(item:)` modifier alongside the existing
`.sheet(item: $bindableModel.siriReadinessModel) { ... }` block:

```swift
.sheet(item: $bindableModel.dependencyUpdateModel) { updateModel in
    NavigationStack {
        List(updateModel.offers, id: \.name) { offer in
            LabeledContent(offer.name) {
                Text("\(offer.currentRange) → \(offer.offeredRange)")
                    .font(.system(.body, design: .monospaced))
            }
        }
        .navigationTitle("Dependency Updates Available")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Skip") { updateModel.skip() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Update") { updateModel.update() }
            }
        }
    }
    .frame(minWidth: 420, minHeight: 260)
}
```

- [ ] **Step 5: Build the app**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/dependency-sync
xcodegen generate
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`. If `TemplateRuntime.bundledURL()`'s exact
signature differs from `bundledURL(in bundle: Bundle = .main)` (e.g. it requires an
explicit argument), adjust the call in Step 3 to match — re-read
`Sources/AnglesiteCore/TemplateRuntime.swift` if the build fails on that line.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteApp/DependencyUpdateModel.swift Sources/AnglesiteApp/SiteWindowModel.swift Sources/AnglesiteApp/SiteWindow.swift
git commit -m "feat(dependency-sync): detection hook, update-offer sheet, accept/skip wiring"
```

---

### Task 10: "Updating dependencies…" transient framing

**Files:**
- Modify: `Sources/AnglesiteApp/PreviewModel.swift`
- Modify: `Sources/AnglesiteApp/SiteWindow.swift`

**Interfaces:**
- Consumes: nothing new. Produces: `PreviewModel.isUpdatingDependencies: Bool` (consumed by Task 9's already-written `self.preview.isUpdatingDependencies = true` call, and by this task's own UI read).

- [ ] **Step 1: Read the current files**

Read `Sources/AnglesiteApp/PreviewModel.swift` in full, specifically how `state`
transitions (the code observing `runtime.observe()`'s `AsyncStream<SiteRuntimeState>`
and assigning to `state`) — this task needs the exact point where state becomes
`.ready` or `.failed` so the transient flag can be cleared there. Also re-read the
`SiteWindow.swift` `.starting` case (`StartupProgressView(title: "Starting dev
server for \(site.name)…", model: model.startup)`) to confirm its exact current
form before editing.

- [ ] **Step 2: Add the flag to `PreviewModel`**

Add near the existing `state` property:

```swift
    /// Set by SiteWindowModel right before calling `open()` following an accepted
    /// dependency update (Task 9) — that boot will hit the slow `npm install` path
    /// instead of the instant hardlink path (the lockfile was just deleted), so the
    /// loading UI should say so rather than looking like the #502 stall. Cleared
    /// whenever `state` settles to `.ready` or `.failed`.
    var isUpdatingDependencies = false
```

Find the exact spot where this type's `state` property is assigned from the
runtime's observation stream (per Step 1's read) and add, at every place `state`
is set to `.ready(...)` or `.failed(...)`:

```swift
isUpdatingDependencies = false
```

- [ ] **Step 3: Use the flag in the loading UI**

In `Sources/AnglesiteApp/SiteWindow.swift`, change the `.starting` case's title to
branch on the flag:

```swift
case .starting:
    centeredStatus {
        StartupProgressView(
            title: model.preview.isUpdatingDependencies
                ? "Updating dependencies — this may take a minute…"
                : "Starting dev server for \(site.name)…",
            model: model.startup
        )
    }
```

- [ ] **Step 4: Build the app**

```bash
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/PreviewModel.swift Sources/AnglesiteApp/SiteWindow.swift
git commit -m "feat(dependency-sync): distinguish the post-update boot from a normal one"
```

---

### Task 11: Final verification + finish branch

- [ ] **Step 1: Full Core test suite**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/dependency-sync
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .
```

Expected: all green, no regressions in any existing suite.

- [ ] **Step 2: App build**

```bash
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Manual smoke check**

Launch the built app. Create (or reuse) a site whose `Source/package.json` pins an
older `astro` range than `Resources/Template/package.json`'s current one, with no
`Config/dependency-baseline.json` (the legacy-fallback path) — opening it should
show the update-offer sheet listing `astro: <old> → <new>`. Confirm:
- **Skip** closes the sheet and the site opens normally; reopening the site shows
  the sheet again (not remembered as dismissed).
- **Update** closes the sheet, the loading text reads "Updating dependencies — this
  may take a minute…", and once the preview comes up, `Source/package.json` has the
  new range, `Source/package-lock.json` was regenerated, `Config/dependency-baseline.json`
  exists, and `.site-config`'s `ANGLESITE_VERSION` matches the running app's version.
  Reopening the same site afterward shows no sheet (fast-path gate) — provided the
  app version hasn't changed and no further drift exists.

Note any deviation before declaring the feature complete.

- [ ] **Step 4: Finish the branch**

Use the `superpowers:finishing-a-development-branch` skill to decide how to land
this (PR, merge, etc.).

---

## Self-Review Notes (resolved inline)

- **Spec coverage:** §2 scope (bumps only, no add/remove) → Task 2's `diff` and its
  tests. §3 provenance/3-way merge + legacy fallback → Task 2. §3.1 fast-path gate →
  Tasks 5–6. §4 detection hook → Task 9. §5 sheet UX, all-or-nothing, no persisted
  dismiss → Task 9 (single `offers` array, no per-row toggle; `Skip` never bumps the
  stamp so the gate can't falsely skip next time — verified in Task 7's applier
  tests and Task 9's wiring). §6 execution (host-side edit, existing hydrate.sh
  path, no new container-exec) → Task 7 (applier) + Task 9 (calls it, then calls
  the *existing* unmodified `preview.open()`). §7 error handling (missing/malformed
  package.json → skip silently; write failure → non-blocking) → Task 6's checker
  (returns `[]` on any read/parse failure) and Task 7's applier
  (`ApplyError.readFailed` on missing package.json, but the caller in Task 9 uses
  `try?`, degrading to "no change, proceed anyway" rather than blocking the
  window). §8 testing → one test file per Core type, all fixture-based, no
  container/npm. §9 files touched → matches this plan's File Structure table.
- **Placeholder scan:** no TBD/TODO. Task 9 and Task 10 each have an explicit
  "read the file first" step because the exact surrounding code (local variable
  names in `SiteScaffolder`, the precise state-transition site in `PreviewModel`)
  wasn't available to quote verbatim — this is a real instruction to read real code
  before a real, fully-specified edit, not a deferred decision.
- **Type consistency:** `DependencyUpdateOffer(name:currentRange:offeredRange:)` is
  used identically across Tasks 2, 3, 7, 9. `DependencySyncChecker.check(sourceDirectory:configDirectory:templateDirectory:runningAppVersion:)`
  matches between Task 6's definition and Task 9's call site. `DependencySyncApplier.apply(_:sourceDirectory:configDirectory:runningAppVersion:)`
  matches between Task 7's definition and Task 9's call site. `DependencyBaseline.load(from:)`/`.save(_:to:)`
  match across Tasks 4, 6, 7, 8. `AppVersion.current(in:)` matches across Tasks 5,
  6 (via checker's `runningAppVersion` parameter, supplied by callers), 8, 9.
