# iOS Site Discovery via iCloud Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the iOS app (`AnglesiteMobile`) a real entry point that lists the user's `.anglesite`
packages from their iCloud ubiquity container — via `NSMetadataQuery`, the App-Sandbox/iCloud-
appropriate mechanism — instead of the manual "type a Worker URL" flow it has today, with explicit
empty and iCloud-unavailable states and fixtured unit tests. Closes #866.

**Architecture:** A testable `SitePickerModel` (`@MainActor @Observable`) lives in the `AnglesiteIOS`
SwiftPM library alongside a small protocol seam (`UbiquitousPackageDiscovering`) wrapping
`NSMetadataQuery`, mirroring the existing `UbiquityContainerResolving`/`FakeUbiquityContainerResolver`
seam that `AnglesiteCore`'s `AppSettings.sitesRoot` already uses for the Mac's iCloud default storage
(#865). Because `AnglesiteIOS` is a plain SwiftPM target (unlike `AnglesiteMobile`, which is an
Xcode-only app target with no `swift test` coverage — see `CLAUDE.md`'s note on keeping app-target
logic thin and pushed into a testable library), this is where all the real logic and its tests live.
`AnglesiteMobile` gets only a thin SwiftUI screen (`SitePickerScreen`) that renders `SitePickerModel`'s
state and becomes `AnglesiteMobileApp`'s new root scene.

**Tech Stack:** Swift 6.4 / SwiftUI, `Foundation.NSMetadataQuery`, Swift Testing (`import Testing`),
XcodeGen (`project.yml`), SwiftPM (`Package.swift`).

## Global Constraints

- Toolchain: Xcode 27+ / Swift 6.4 (per `CLAUDE.md`).
- `AnglesiteIOS` and its new test target are Darwin-only — never added to `Package.swift`'s
  `portableTargets` set (the Linux CI leg), so no `#if canImport(Darwin)` gating is needed inside
  their new files.
- Any new SwiftPM test target that transitively depends on `AnglesiteCore` needs
  `linkerSettings: weakLinkFoundationModels` (see `Package.swift`'s `#541` comment) — otherwise a
  beta-SDK/OS symbol mismatch can abort the test bundle at `dlopen`.
- The iOS Debug build must stay buildable with **no Apple Developer account** (CI's `ios-build` lane
  uses ad-hoc signing via `xcconfig/Signing-Debug.xcconfig`) — the iCloud entitlement requires a real
  provisioning profile, so it must **not** land in the default Debug entitlements file. Mirror the
  Mac target's existing `Resources/Anglesite-Debug.entitlements` /
  `Resources/Anglesite-Debug-iCloud.entitlements` split (#1038) exactly.
- iCloud container identifier is `iCloud.io.dwk.anglesite` everywhere (entitlements, `Info.plist`
  keys, `AppSettings.ubiquityContainerIdentifier`) — must match across Mac and iOS since it's the
  same physical container.
- Out of scope (per the issue): site creation on iOS, and IndieAuth sign-in. Do not build either.
- Do not delete or modify `Sources/AnglesiteMobile/RemoteSessionScreen.swift` /
  `RemoteSessionModel.swift` / their supporting files — they belong to the separate, still-open #71
  "remote sandbox thin client" epic (deferred to v2.0 under #342). This plan only stops referencing
  `RemoteSessionScreen` from `AnglesiteMobileApp`'s root scene, per #800's owner decision
  (2026-07-17) that the Micropub/iCloud-discovery flow is now the default iOS experience — it does
  not remove the older code.

---

## File Structure

- **Modify** `Sources/AnglesiteCore/AppSettings.swift` — widen `ubiquityContainerIdentifier` to
  `public` so `AnglesiteIOS` can reuse the exact same constant instead of duplicating the literal.
- **Create** `Sources/AnglesiteIOS/UbiquitousPackageDiscovering.swift` — the `NSMetadataQuery`
  protocol seam + real implementation.
- **Create** `Sources/AnglesiteIOS/SitePickerModel.swift` — `@MainActor @Observable` model +
  `DiscoveredSite`.
- **Create** `Tests/AnglesiteIOSTests/SitePickerModelTests.swift` — fixtured unit tests (missing
  container, empty container, single site, multiple sites, unreadable marker).
- **Modify** `Package.swift` — `AnglesiteIOS` target dependencies, new `AnglesiteIOSTests` target.
- **Create** `Sources/AnglesiteMobile/SitePickerScreen.swift` — the SwiftUI screen.
- **Modify** `Sources/AnglesiteMobile/AnglesiteMobileApp.swift` — new root scene.
- **Create** `Resources/AnglesiteMobile.entitlements`, `Resources/AnglesiteMobile-Debug.entitlements`,
  `Resources/AnglesiteMobile-Debug-iCloud.entitlements`.
- **Modify** `project.yml` — `AnglesiteMobile` target's `CODE_SIGN_ENTITLEMENTS`.
- **Modify** `xcconfig/Signing-Debug.xcconfig`, `xcconfig/Signing-Debug.local.xcconfig.example` — new
  `ANGLESITE_MOBILE_DEBUG_ENTITLEMENTS` indirection, mirroring `ANGLESITE_DEBUG_ENTITLEMENTS`.
- **Modify** `Resources/Info-iOS.plist` — add `NSUbiquitousContainers`.

---

### Task 1: Expose `AppSettings.ubiquityContainerIdentifier` publicly

**Files:**
- Modify: `Sources/AnglesiteCore/AppSettings.swift:85`

**Interfaces:**
- Produces: `public static let AppSettings.ubiquityContainerIdentifier: String` (was `internal`) —
  Task 2's `SitePickerModel` reads this directly instead of duplicating the container-ID literal.

- [ ] **Step 1: Widen the access modifier**

In `Sources/AnglesiteCore/AppSettings.swift`, change line 85 from:

```swift
    static let ubiquityContainerIdentifier = "iCloud.io.dwk.anglesite"
```

to:

```swift
    /// Public so `AnglesiteIOS`'s site-discovery seam (#866) can reuse the exact same identifier
    /// instead of duplicating this literal — it's the same physical iCloud container on both
    /// platforms.
    public static let ubiquityContainerIdentifier = "iCloud.io.dwk.anglesite"
```

- [ ] **Step 2: Run the existing AppSettings suite to confirm nothing broke**

Run: `swift test --package-path . --filter AppSettingsTests`
Expected: PASS (all existing cases still pass; a wider access modifier can't break internal callers).

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteCore/AppSettings.swift
git commit -m "feat(#866): expose AppSettings.ubiquityContainerIdentifier publicly"
```

---

### Task 2: Site-discovery seam + `SitePickerModel` in `AnglesiteIOS`

**Files:**
- Modify: `Package.swift:134-139` (AnglesiteIOS target dependencies), `Package.swift:190-196` (add
  new test target after `AnglesiteBridgeTests`)
- Create: `Sources/AnglesiteIOS/UbiquitousPackageDiscovering.swift`
- Create: `Sources/AnglesiteIOS/SitePickerModel.swift`
- Create: `Tests/AnglesiteIOSTests/SitePickerModelTests.swift`

**Interfaces:**
- Consumes: `AnglesiteSiteModel.AnglesitePackage` (`init(url:)`, `readMarker(fileManager:) throws ->
  Marker`, `Marker.siteID: UUID`, `Marker.displayName: String`, `static createSkeleton(at:displayName:
  fileManager:) throws -> (AnglesitePackage, Marker)`, `static packageExtension: String`);
  `AnglesiteCore.UbiquityContainerResolving` (`func url(forUbiquityContainerIdentifier:) -> URL?`,
  `FileManager` already conforms); `AnglesiteCore.AppSettings.ubiquityContainerIdentifier: String`
  (Task 1).
- Produces: `public protocol UbiquitousPackageDiscovering { func discoverPackages() async -> [URL] }`;
  `public final class NSMetadataQueryPackageDiscovery: UbiquitousPackageDiscovering`; `public final
  class SitePickerModel` with `public enum State: Equatable { case loading, iCloudUnavailable, empty,
  sites([DiscoveredSite]) }`, `public struct DiscoveredSite: Identifiable, Sendable, Equatable { let
  id: UUID; let displayName: String; let packageURL: URL }`, `public private(set) var state: State`,
  `public init(ubiquityContainerResolver: UbiquityContainerResolving = FileManager.default,
  packageDiscovery: UbiquitousPackageDiscovering = NSMetadataQueryPackageDiscovery(), fileManager:
  FileManager = .default)`, `public func refresh() async`. Task 3's `SitePickerScreen` consumes all
  of this from `AnglesiteMobile`.

- [ ] **Step 1: Wire the new dependencies and test target in `Package.swift`**

Change `Package.swift:134-139` from:

```swift
    .target(
        name: "AnglesiteIOS",
        dependencies: [],
        path: "Sources/AnglesiteIOS",
        swiftSettings: strictConcurrency
    ),
```

to:

```swift
    .target(
        name: "AnglesiteIOS",
        dependencies: ["AnglesiteSiteModel", "AnglesiteCore"],
        path: "Sources/AnglesiteIOS",
        swiftSettings: strictConcurrency
    ),
```

Then, immediately after the `AnglesiteBridgeTests` target definition (`Package.swift:190-196`,
which currently ends the `packageTargets` array literal with `]`), add a new test target so the
array becomes:

```swift
    .testTarget(
        name: "AnglesiteBridgeTests",
        dependencies: ["AnglesiteBridge", "AnglesiteTestSupport"],
        path: "Tests/AnglesiteBridgeTests",
        swiftSettings: strictConcurrency,
        linkerSettings: weakLinkFoundationModels
    ),
    .testTarget(
        name: "AnglesiteIOSTests",
        dependencies: ["AnglesiteIOS", "AnglesiteSiteModel", "AnglesiteCore"],
        path: "Tests/AnglesiteIOSTests",
        swiftSettings: strictConcurrency,
        // Transitively depends on AnglesiteCore (via AnglesiteIOS), so it needs the same #541
        // weak-link workaround as AnglesiteBridgeTests/AnglesiteBridgeCoreTests above.
        linkerSettings: weakLinkFoundationModels
    )
]
```

(i.e. move the closing `]` of the array literal to after the new target, same as the existing
targets' comma-separated style.)

- [ ] **Step 2: Write the failing tests**

Create `Tests/AnglesiteIOSTests/SitePickerModelTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteIOS
import AnglesiteCore
import AnglesiteSiteModel

private struct FakeUbiquityContainerResolver: UbiquityContainerResolving {
    let result: URL?
    func url(forUbiquityContainerIdentifier containerIdentifier: String?) -> URL? { result }
}

private struct FakeUbiquitousPackageDiscovery: UbiquitousPackageDiscovering {
    let urls: [URL]
    func discoverPackages() async -> [URL] { urls }
}

/// A `final class` (not a `struct`) so `deinit` can clean up the scratch directory, mirroring
/// `AppSettingsTests`' scratch-`UserDefaults`-suite pattern.
@MainActor
final class SitePickerModelTests {
    private let scratchRoot: URL
    private let fakeContainer = URL(fileURLWithPath: "/tmp/fake-ubiquity-container", isDirectory: true)

    init() {
        scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SitePickerModelTests-\(UUID().uuidString)", isDirectory: true)
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

    @Test("Missing iCloud container surfaces iCloudUnavailable, not empty")
    func missingContainerSurfacesUnavailable() async {
        let model = SitePickerModel(
            ubiquityContainerResolver: FakeUbiquityContainerResolver(result: nil),
            packageDiscovery: FakeUbiquitousPackageDiscovery(urls: []))
        await model.refresh()
        #expect(model.state == .iCloudUnavailable)
    }

    @Test("Available container with no packages surfaces empty")
    func emptyContainerSurfacesEmpty() async {
        let model = SitePickerModel(
            ubiquityContainerResolver: FakeUbiquityContainerResolver(result: fakeContainer),
            packageDiscovery: FakeUbiquitousPackageDiscovery(urls: []))
        await model.refresh()
        #expect(model.state == .empty)
    }

    @Test("Single discovered package surfaces one site")
    func singleSiteSurfacesInList() async throws {
        let packageURL = try makePackage(displayName: "My Blog")
        let model = SitePickerModel(
            ubiquityContainerResolver: FakeUbiquityContainerResolver(result: fakeContainer),
            packageDiscovery: FakeUbiquitousPackageDiscovery(urls: [packageURL]))
        await model.refresh()
        guard case .sites(let sites) = model.state else {
            Issue.record("expected .sites, got \(model.state)")
            return
        }
        #expect(sites.count == 1)
        #expect(sites.first?.displayName == "My Blog")
        #expect(sites.first?.packageURL == packageURL)
    }

    @Test("Multiple discovered packages surface sorted by display name")
    func multipleSitesSortedByName() async throws {
        let zebra = try makePackage(displayName: "Zebra Site")
        let apple = try makePackage(displayName: "Apple Site")
        let model = SitePickerModel(
            ubiquityContainerResolver: FakeUbiquityContainerResolver(result: fakeContainer),
            packageDiscovery: FakeUbiquitousPackageDiscovery(urls: [zebra, apple]))
        await model.refresh()
        guard case .sites(let sites) = model.state else {
            Issue.record("expected .sites, got \(model.state)")
            return
        }
        #expect(sites.map(\.displayName) == ["Apple Site", "Zebra Site"])
    }

    @Test("A package with no readable Info.plist marker is silently skipped")
    func unreadableMarkerSkipped() async throws {
        let corruptURL = scratchRoot.appendingPathComponent("Corrupt.anglesite", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptURL, withIntermediateDirectories: true)
        let model = SitePickerModel(
            ubiquityContainerResolver: FakeUbiquityContainerResolver(result: fakeContainer),
            packageDiscovery: FakeUbiquitousPackageDiscovery(urls: [corruptURL]))
        await model.refresh()
        #expect(model.state == .empty)
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail (types don't exist yet)**

Run: `swift test --package-path . --filter AnglesiteIOSTests`
Expected: FAIL to build — `SitePickerModel`, `UbiquitousPackageDiscovering`,
`FakeUbiquitousPackageDiscovery`'s conformance target, etc. don't exist yet.

- [ ] **Step 4: Write the discovery seam**

Create `Sources/AnglesiteIOS/UbiquitousPackageDiscovering.swift`:

```swift
import Foundation
import AnglesiteSiteModel

/// Wraps `NSMetadataQuery` so `SitePickerModel` can be tested against fixtured results (#866)
/// instead of the real iCloud state of whatever machine runs `swift test` — mirrors
/// `AnglesiteCore`'s `UbiquityContainerResolving`/`FakeUbiquityContainerResolver` seam (#865).
public protocol UbiquitousPackageDiscovering: Sendable {
    /// Runs a one-shot query for `.anglesite` packages in the app's iCloud ubiquity container
    /// and returns their URLs once the initial gather completes. Callers are expected to have
    /// already confirmed the container is available (`UbiquityContainerResolving`) before calling
    /// this — it does not itself distinguish "no container" from "container has no packages".
    func discoverPackages() async -> [URL]
}

/// Real `NSMetadataQuery`-backed implementation. Scoped to
/// `NSMetadataQueryUbiquitousDocumentsScope` (the app's own ubiquity container's `Documents/`
/// folder — matching `AppSettings.sitesRoot`'s `container/Documents` convention, #865) rather than
/// a raw file-URL scope or a broader ubiquitous-data scope: per `SyncModel.observeBundleChanges`'s
/// prior art (`Sources/AnglesiteApp/SyncModel.swift`), ubiquitous item metadata keys like
/// `NSMetadataItemPathKey` aren't reliably populated until an item is first resolved, so filtering
/// by path prefix is unreliable — the predefined scope constant is the documented-correct way to
/// scope a search to this app's own ubiquitous documents instead.
///
/// No stored mutable state: each call creates and tears down its own query and observer, so
/// concurrent calls can't interfere with each other.
public final class NSMetadataQueryPackageDiscovery: UbiquitousPackageDiscovering, @unchecked Sendable {
    public init() {}

    public func discoverPackages() async -> [URL] {
        await withCheckedContinuation { continuation in
            let query = NSMetadataQuery()
            query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
            query.predicate = NSPredicate(
                format: "%K ENDSWITH %@",
                NSMetadataItemFSNameKey, ".\(AnglesitePackage.packageExtension)"
            )

            var observer: NSObjectProtocol?
            observer = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
            ) { _ in
                query.disableUpdates()
                query.stop()
                if let observer {
                    NotificationCenter.default.removeObserver(observer)
                }
                let urls = (0..<query.resultCount).compactMap { index -> URL? in
                    (query.result(at: index) as? NSMetadataItem)?
                        .value(forAttribute: NSMetadataItemURLKey) as? URL
                }
                continuation.resume(returning: urls)
            }
            query.start()
        }
    }
}
```

- [ ] **Step 5: Write `SitePickerModel`**

Create `Sources/AnglesiteIOS/SitePickerModel.swift`:

```swift
import Foundation
import SwiftUI
import AnglesiteCore
import AnglesiteSiteModel

/// Drives the iOS app's entry point (#866): lists the user's `.anglesite` packages found in their
/// iCloud ubiquity container, in place of the old "type a site URL" flow. `@MainActor` +
/// `@Observable` so `SitePickerScreen` (`AnglesiteMobile`) can bind to it directly, matching
/// `RemoteSessionModel`'s existing convention in this target.
@MainActor
@Observable
public final class SitePickerModel {
    /// A discovered `.anglesite` package, ready to show in the picker.
    public struct DiscoveredSite: Identifiable, Sendable, Equatable {
        /// The package's stable site UUID (`AnglesitePackage.Marker.siteID`) — path-independent,
        /// matching how `SiteStore.Site` identifies sites on the Mac.
        public let id: UUID
        public let displayName: String
        public let packageURL: URL
    }

    /// Distinguishes "iCloud itself isn't available" from "iCloud is available but has no sites
    /// yet" — the design's explicit requirement (spec §4/§7): the empty state's "create a site on
    /// your Mac" message must never show when the real problem is iCloud access.
    public enum State: Equatable {
        case loading
        case iCloudUnavailable
        case empty
        case sites([DiscoveredSite])
    }

    public private(set) var state: State = .loading

    private let ubiquityContainerResolver: UbiquityContainerResolving
    private let packageDiscovery: UbiquitousPackageDiscovering
    private let fileManager: FileManager

    public init(
        ubiquityContainerResolver: UbiquityContainerResolving = FileManager.default,
        packageDiscovery: UbiquitousPackageDiscovering = NSMetadataQueryPackageDiscovery(),
        fileManager: FileManager = .default
    ) {
        self.ubiquityContainerResolver = ubiquityContainerResolver
        self.packageDiscovery = packageDiscovery
        self.fileManager = fileManager
    }

    /// Re-runs discovery from scratch. Safe to call repeatedly (pull-to-refresh, a "Try Again"
    /// button, or the initial `.task` on `SitePickerScreen`).
    public func refresh() async {
        state = .loading
        guard ubiquityContainerResolver.url(
            forUbiquityContainerIdentifier: AppSettings.ubiquityContainerIdentifier
        ) != nil else {
            state = .iCloudUnavailable
            return
        }

        let packageURLs = await packageDiscovery.discoverPackages()
        let sites = packageURLs
            .compactMap { url -> DiscoveredSite? in
                let package = AnglesitePackage(url: url)
                guard let marker = try? package.readMarker(fileManager: fileManager) else {
                    return nil
                }
                return DiscoveredSite(id: marker.siteID, displayName: marker.displayName, packageURL: url)
            }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }

        state = sites.isEmpty ? .empty : .sites(sites)
    }
}
```

(The `import SwiftUI` is unused by this file today but matches `RemoteSessionModel`'s existing
import style for `@Observable` models in this codebase — drop it if `swift build` warns about an
unused import; keep `import Foundation` and `import AnglesiteCore`/`AnglesiteSiteModel` regardless.)

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --package-path . --filter AnglesiteIOSTests`
Expected: PASS — all 5 tests green.

- [ ] **Step 7: Run the full portable + Darwin suite to confirm no regressions**

Run: `swift test --package-path .`
Expected: PASS (existing suites unaffected; this also exercises `AnglesiteIOS`'s new dependency
edges compile cleanly for the macOS host target, which is how `AnglesiteIOS` already builds under
plain `swift test`).

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources/AnglesiteIOS/UbiquitousPackageDiscovering.swift \
  Sources/AnglesiteIOS/SitePickerModel.swift Tests/AnglesiteIOSTests/SitePickerModelTests.swift
git commit -m "feat(#866): add NSMetadataQuery-backed iCloud site discovery to AnglesiteIOS"
```

---

### Task 3: `SitePickerScreen` and new app entry point

**Files:**
- Create: `Sources/AnglesiteMobile/SitePickerScreen.swift`
- Modify: `Sources/AnglesiteMobile/AnglesiteMobileApp.swift`

**Interfaces:**
- Consumes: `AnglesiteIOS.SitePickerModel` (`init()`, `state: State`, `func refresh() async`),
  `SitePickerModel.State`, `SitePickerModel.DiscoveredSite` (Task 2).
- Produces: `struct SitePickerScreen: View` — the new root view referenced by
  `AnglesiteMobileApp.body`.

This task has no `swift test` coverage of its own: `AnglesiteMobile` is an Xcode-only app target
(not a `Package.swift` target), so its build is verified with `xcodebuild`, matching how
`RemoteSessionScreen.swift` (its sibling file) has none either. All the testable logic already
landed in Task 2.

- [ ] **Step 1: Write the screen**

Create `Sources/AnglesiteMobile/SitePickerScreen.swift`:

```swift
import SwiftUI
import AnglesiteIOS

/// The iOS app's entry point (#866): lists `.anglesite` packages discovered in the user's iCloud
/// container instead of asking for a typed site URL. Replaces `RemoteSessionScreen` as
/// `AnglesiteMobileApp`'s root — per #800's owner decision (2026-07-17) that this iCloud-discovery
/// + Micropub flow, not the older remote-sandbox thin client (#71, deferred to v2.0 under #342),
/// is the default iOS experience. Picking a site doesn't do anything yet — that's the sibling
/// IndieAuth-onboarding issue.
struct SitePickerScreen: View {
    @State private var model = SitePickerModel()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(Text("Your Sites"))
                .task { await model.refresh() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView("Finding your sites…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .iCloudUnavailable:
            ContentUnavailableView {
                Label("iCloud Unavailable", systemImage: "icloud.slash")
            } description: {
                Text("Sign in to iCloud and turn on iCloud Drive to see your Anglesite sites.")
            } actions: {
                Button("Try Again") { Task { await model.refresh() } }
                    .buttonStyle(.borderedProminent)
            }
        case .empty:
            ContentUnavailableView {
                Label("No Sites Found", systemImage: "globe")
            } description: {
                Text("No sites found — create a site in Anglesite on your Mac first.")
            } actions: {
                Button("Refresh") { Task { await model.refresh() } }
                    .buttonStyle(.borderedProminent)
            }
        case .sites(let sites):
            List(sites) { site in
                Text(site.displayName)
            }
            .refreshable { await model.refresh() }
        }
    }
}
```

- [ ] **Step 2: Wire it as the app's root scene**

Change `Sources/AnglesiteMobile/AnglesiteMobileApp.swift` from:

```swift
import SwiftUI

/// iOS thin client (#71): a remote-only shell over `RemoteSandboxSiteRuntime`. No local files,
/// no subprocesses, no local containers — the site runs in the user's Cloudflare sandbox and
/// this app is a `WKWebView` plus MCP-over-HTTPS edits (design 2026-06-23).
@main
struct AnglesiteMobileApp: App {
    @State private var model = RemoteSessionModel()

    var body: some Scene {
        WindowGroup {
            RemoteSessionScreen(model: model)
        }
    }
}
```

to:

```swift
import SwiftUI

/// Entry point (#866): lists `.anglesite` packages discovered via iCloud. `RemoteSessionScreen`
/// (the #71 remote-sandbox thin client, deferred to v2.0 under #342) is still in this target but
/// no longer wired to the root scene — see this file's git history, and #800's owner decision
/// (2026-07-17) that the iCloud-discovery + Micropub flow is the default iOS experience now.
@main
struct AnglesiteMobileApp: App {
    var body: some Scene {
        WindowGroup {
            SitePickerScreen()
        }
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteMobile/SitePickerScreen.swift Sources/AnglesiteMobile/AnglesiteMobileApp.swift
git commit -m "feat(#866): make the iCloud site picker the iOS app's entry point"
```

(Building this task is verified together with Task 4's entitlements wiring in Task 5, since
`xcodebuild` for `AnglesiteMobile` needs the entitlements file the next task creates to exist
first — `CODE_SIGN_ENTITLEMENTS` isn't set until Task 4.)

---

### Task 4: iOS iCloud entitlements + `Info-iOS.plist`

**Files:**
- Create: `Resources/AnglesiteMobile.entitlements`
- Create: `Resources/AnglesiteMobile-Debug.entitlements`
- Create: `Resources/AnglesiteMobile-Debug-iCloud.entitlements`
- Modify: `project.yml:156-209` (the `AnglesiteMobile` target block)
- Modify: `xcconfig/Signing-Debug.xcconfig`
- Modify: `xcconfig/Signing-Debug.local.xcconfig.example`
- Modify: `Resources/Info-iOS.plist`

**Interfaces:** None (build configuration only, no Swift symbols).

- [ ] **Step 1: Create the Release/base entitlements file (has iCloud)**

Create `Resources/AnglesiteMobile.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<!-- iCloud site discovery (#866): must match AppSettings.ubiquityContainerIdentifier
	     (AnglesiteCore) and the NSUbiquitousContainers key in Resources/Info-iOS.plist. Same
	     container the Mac app's default site storage (#865) writes into. -->
	<key>com.apple.developer.icloud-container-identifiers</key>
	<array>
		<string>iCloud.io.dwk.anglesite</string>
	</array>
	<key>com.apple.developer.icloud-services</key>
	<array>
		<string>CloudDocuments</string>
	</array>
</dict>
</plist>
```

- [ ] **Step 2: Create the default (CI-safe, no-iCloud) Debug entitlements file**

Create `Resources/AnglesiteMobile-Debug.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<!-- NO iCloud entitlement here (mirrors Resources/Anglesite-Debug.entitlements, #1038): the
	     iCloud capability needs a real provisioning profile even under ad-hoc/no-Team signing,
	     which would break the no-Apple-account Debug build CI's ios-build lane (#864) relies on.
	     SitePickerModel already treats "no ubiquity container" the same as "iCloud unavailable"
	     and shows that state instead of crashing. Contributors with a real Team who want to
	     exercise iCloud discovery locally: point ANGLESITE_MOBILE_DEBUG_ENTITLEMENTS at
	     Resources/AnglesiteMobile-Debug-iCloud.entitlements from
	     xcconfig/Signing-Debug.local.xcconfig (see Signing-Debug.local.xcconfig.example). -->
</dict>
</plist>
```

- [ ] **Step 3: Create the opt-in Debug-with-iCloud entitlements file**

Create `Resources/AnglesiteMobile-Debug-iCloud.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<!-- Opt-in Debug entitlements (mirrors Resources/Anglesite-Debug-iCloud.entitlements, #1038):
	     identical to AnglesiteMobile-Debug.entitlements plus the iCloud capability. Requires a
	     real Team/provisioning profile — see Signing-Debug.local.xcconfig.example. -->
	<key>com.apple.developer.icloud-container-identifiers</key>
	<array>
		<string>iCloud.io.dwk.anglesite</string>
	</array>
	<key>com.apple.developer.icloud-services</key>
	<array>
		<string>CloudDocuments</string>
	</array>
</dict>
</plist>
```

- [ ] **Step 4: Add the `ANGLESITE_MOBILE_DEBUG_ENTITLEMENTS` xcconfig indirection**

In `xcconfig/Signing-Debug.xcconfig`, after the existing `ANGLESITE_DEBUG_ENTITLEMENTS = ...` line
and before the `#include? "Signing-Debug.local.xcconfig"` line, add:

```
// The AnglesiteMobile target's CODE_SIGN_ENTITLEMENTS (Debug config) reads this indirection
// (#866, mirrors ANGLESITE_DEBUG_ENTITLEMENTS above) so a local override can point at
// Resources/AnglesiteMobile-Debug-iCloud.entitlements without editing this tracked file. Must
// stay the no-iCloud file by default — same CI-safe reason as the Mac target above.
ANGLESITE_MOBILE_DEBUG_ENTITLEMENTS = Resources/AnglesiteMobile-Debug.entitlements
```

- [ ] **Step 5: Document the opt-in in the local xcconfig example**

In `xcconfig/Signing-Debug.local.xcconfig.example`, after the existing commented-out
`ANGLESITE_DEBUG_ENTITLEMENTS = ...` line, add:

```
// Same idea for the iOS target (#866):
// ANGLESITE_MOBILE_DEBUG_ENTITLEMENTS = Resources/AnglesiteMobile-Debug-iCloud.entitlements
```

- [ ] **Step 6: Wire `CODE_SIGN_ENTITLEMENTS` into the `AnglesiteMobile` target**

In `project.yml`, inside the `AnglesiteMobile` target's `settings.base` block, add
`CODE_SIGN_ENTITLEMENTS` next to the existing `INFOPLIST_FILE`/`GENERATE_INFOPLIST_FILE` lines:

```yaml
        INFOPLIST_FILE: Resources/Info-iOS.plist
        GENERATE_INFOPLIST_FILE: NO
        # Release keeps the clean iCloud entitlements; Debug overrides to the no-iCloud file by
        # default (#866, mirrors the Anglesite/Mac target's CODE_SIGN_ENTITLEMENTS below).
        CODE_SIGN_ENTITLEMENTS: Resources/AnglesiteMobile.entitlements
```

Then, inside the same target's `settings.configs.Debug` block (create it if it doesn't exist yet;
today only `configs.Release` exists), add the override:

```yaml
      configs:
        Debug:
          CODE_SIGN_ENTITLEMENTS: $(ANGLESITE_MOBILE_DEBUG_ENTITLEMENTS)
        Release:
          CODE_SIGN_STYLE: Manual
          CODE_SIGN_IDENTITY: "Apple Distribution"
```

- [ ] **Step 7: Add `NSUbiquitousContainers` to `Info-iOS.plist`**

In `Resources/Info-iOS.plist`, add this key before the closing `</dict>`:

```xml
	<key>NSUbiquitousContainers</key>
	<dict>
		<key>iCloud.io.dwk.anglesite</key>
		<dict>
			<key>NSUbiquitousContainerIsDocumentScopePublic</key>
			<true/>
			<key>NSUbiquitousContainerSupportedFolderLevels</key>
			<string>Any</string>
			<key>NSUbiquitousContainerName</key>
			<string>Anglesite</string>
		</dict>
	</dict>
```

- [ ] **Step 8: Regenerate the Xcode project and build the iOS target**

Run:
```bash
xcodegen generate --quiet
xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMobile \
  -configuration Debug -destination 'generic/platform=iOS Simulator' build
```
Expected: `BUILD SUCCEEDED` — this is the exact invocation CI's `ios-build` lane runs
(`.github/workflows/ci.yml`), so it proves both this task's entitlements wiring and Task 3's new
root scene compile together under the ad-hoc, no-Apple-account-safe Debug config.

- [ ] **Step 9: Commit**

```bash
git add Resources/AnglesiteMobile.entitlements Resources/AnglesiteMobile-Debug.entitlements \
  Resources/AnglesiteMobile-Debug-iCloud.entitlements Resources/Info-iOS.plist \
  project.yml xcconfig/Signing-Debug.xcconfig xcconfig/Signing-Debug.local.xcconfig.example
git commit -m "feat(#866): add iOS iCloud entitlements for site discovery"
```

---

### Task 5: Full verification pass

**Files:** None (verification only).

**Interfaces:** None.

- [ ] **Step 1: Run the full SwiftPM suite**

Run: `swift test --package-path .`
Expected: PASS, including the new `AnglesiteIOSTests`.

- [ ] **Step 2: Build the macOS app target (confirm the AnglesiteCore access-level change didn't
  break the Mac build)**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Re-confirm the iOS build (already run in Task 4, re-run after the full sequence)**

Run:
```bash
xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMobile \
  -configuration Debug -destination 'generic/platform=iOS Simulator' build
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Diff review against `CONTRIBUTING.md`**

Confirm: commit subjects ≤72 chars; no drive-by unrelated changes; `RemoteSessionScreen.swift` /
`RemoteSessionModel.swift` untouched; String Catalog note acknowledged (no new
`Text`/`Label`/`String(localized:)` literals need catalog merging beyond what `SitePickerScreen.swift`
introduces — note in the PR body that the CLI build can't merge `Localizable.xcstrings` and this
was not done, per `CONTRIBUTING.md`'s caveat, since no interactive Xcode session is available here).

- [ ] **Step 5: Open the PR**

Follow `.github/PULL_REQUEST_TEMPLATE.md`'s exact headings (Summary, Paired PR check, Test plan).
Body must include `Closes #866`. Note in Test plan which commands were run (Steps 1-3 above) and
that `xcstringstool sync` was not run (no interactive Xcode session available).
