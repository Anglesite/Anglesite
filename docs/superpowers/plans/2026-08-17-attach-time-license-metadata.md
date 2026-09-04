# Attach-Time License Metadata Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `Insert ▸ Image…`'s file-open panel grows a checkbox + license picker; when checked, the picked image's bytes get the chosen license embedded (via `LicenseMetadataEmbedder`) before insertion. The choice persists as the last-used selection. Non-asserting collections (bookmarks/replies/likes/reviews, with no explicit per-collection override) suppress the control entirely — issue #999, scope items 2 (consumer) and 3 ("Attach-time application").

**Architecture:** `InsertCommands.insertImage(into:)` (the only image-import entry point in the app today — drag-and-drop onto the WKWebView is a separate, JS-driven path with no native file-open step, out of scope here and covered by a future "drop-and-inspect" plan) gains an `NSOpenPanel.accessoryView` with a plain `NSButton` checkbox and `NSPopUpButton`, mirroring the existing accessory-view idiom in `Sources/AnglesiteApp/SiteActions.swift:196-201`. The checkbox/popup *state* is extracted into a plain, unit-testable struct (`InsertImageLicenseChoice`), matching the established pattern in `LicenseGateSheetView.Selection` — AppKit control reads/writes stay in the thin glue, all actual logic is testable without a hosted view.

**Tech Stack:** Swift 6.4, AppKit (`NSOpenPanel`, `NSButton`, `NSPopUpButton`), AnglesiteCore (`LicenseMetadataEmbedder`, `LicensingStore`, `LicensingPolicy`, `LicenseCatalog`, `AppSettings`), Swift Testing.

## Global Constraints

- **Depends on the embedded-license-metadata plan** (`docs/superpowers/plans/2026-08-17-embedded-license-metadata.md`) — `LicenseMetadataEmbedder` must exist before Task 3 of this plan. Tasks 1-2 (model/persistence additions) have no such dependency and can land first.
- **Non-asserting collections suppress the control entirely**, per the owner decision recorded on issue #999 (2026-08-13 comment): "The four non-asserting collections (bookmarks, replies, likes, reviews) suppress embedded license metadata — consistent with those collections not asserting a license claim over content the owner didn't create." An *explicit* per-collection license override still allows embedding — only the *default* non-asserting behavior suppresses it.
- **The selection persists as the last-used choice**, per issue #999 scope item 3. Follows the existing `AppSettings` `UserDefaults`-backed-key pattern (`Sources/AnglesiteCore/AppSettings.swift`), not a new storage mechanism.
- **No custom-license text entry in this compact accessory view.** `NSPopUpButton` doesn't lend itself to free-form URL/name entry the way `LicenseGateSheetView`'s SwiftUI sheet does. This plan's picker offers "Don't embed a license" (checkbox off) plus every `LicenseCatalog.entries` catalog license. A custom per-file license is out of scope for this plan; note this explicitly in the PR description as a scope cut, not a silent gap.
- Apple frameworks only. No new third-party dependencies.
- Conventional commits, subject ≤72 chars, reference `#999`.

---

### Task 1: `LicensingPolicy.resolvedLicense(for:)`, `suppressesFileEmbedding(for:)`, and `LicensableCollection(routePath:)`

**Files:**
- Modify: `Sources/AnglesiteCore/LicensingStore.swift`
- Test: `Tests/AnglesiteCoreTests/LicensingStoreTests.swift`

**Interfaces:**
- Consumes: `LicensingPolicy`, `LicensableCollection`, `CollectionLicenseRule`, `LicenseRef` (all existing in this file).
- Produces:
  ```swift
  extension LicensingPolicy {
      public func resolvedLicense(for collection: LicensableCollection?) -> LicenseRef?
      public func suppressesFileEmbedding(for collection: LicensableCollection?) -> Bool
  }
  extension LicensableCollection {
      public init?(routePath: String)
  }
  ```

- [ ] **Step 1: Write the failing tests**

Add to `Tests/AnglesiteCoreTests/LicensingStoreTests.swift` (inside the existing `@Suite` struct):

```swift
    @Test("resolvedLicense falls through inherit to the site default")
    func resolvedLicenseInheritsSiteDefault() {
        var policy = LicensingPolicy(defaultLicense: ccBY)
        #expect(policy.resolvedLicense(for: .notes) == ccBY)
        // A nil collection (a page outside every collection) also gets the site default.
        #expect(policy.resolvedLicense(for: nil) == ccBY)
        policy.setRule(.assertNothing, for: .notes)
        #expect(policy.resolvedLicense(for: .notes) == nil)
    }

    @Test("resolvedLicense asserts nothing for non-asserting collections by default")
    func resolvedLicenseNonAsserting() {
        let policy = LicensingPolicy(defaultLicense: ccBY)
        #expect(policy.resolvedLicense(for: .bookmarks) == nil)
        #expect(policy.resolvedLicense(for: .replies) == nil)
        #expect(policy.resolvedLicense(for: .likes) == nil)
        #expect(policy.resolvedLicense(for: .reviews) == nil)
        #expect(policy.resolvedLicense(for: .notes) == ccBY)
    }

    @Test("resolvedLicense honors an explicit override on a non-asserting collection")
    func resolvedLicenseExplicitOverrideWins() {
        var policy = LicensingPolicy(defaultLicense: nil)
        policy.setRule(.license(ccBY), for: .bookmarks)
        #expect(policy.resolvedLicense(for: .bookmarks) == ccBY)
    }

    @Test("suppressesFileEmbedding is true only for non-asserting collections with no override")
    func suppressesFileEmbedding() {
        var policy = LicensingPolicy(defaultLicense: ccBY)
        #expect(policy.suppressesFileEmbedding(for: .bookmarks) == true)
        #expect(policy.suppressesFileEmbedding(for: .notes) == false)
        #expect(policy.suppressesFileEmbedding(for: nil) == false)
        policy.setRule(.license(ccBY), for: .bookmarks)
        #expect(policy.suppressesFileEmbedding(for: .bookmarks) == false)
        policy.setRule(.assertNothing, for: .bookmarks)
        #expect(policy.suppressesFileEmbedding(for: .bookmarks) == true)
    }

    @Test("LicensableCollection(routePath:) reads the route's first path segment")
    func collectionFromRoutePath() {
        #expect(LicensableCollection(routePath: "/notes/my-slug/") == .notes)
        #expect(LicensableCollection(routePath: "photos/my-slug") == .photos)
        #expect(LicensableCollection(routePath: "/") == nil)
        #expect(LicensableCollection(routePath: "/about/") == nil)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter LicensingStoreTests`
Expected: FAIL to build — `resolvedLicense`, `suppressesFileEmbedding`, and `LicensableCollection(routePath:)` don't exist yet.

- [ ] **Step 3: Implement the three additions**

In `Sources/AnglesiteCore/LicensingStore.swift`, add after the closing brace of the `LicensingPolicy` struct's `setRule(_:for:)` method (immediately before the struct's closing `}`, i.e. right after the existing `rule(for:)`/`setRule(_:for:)` pair described in the file):

```swift

    /// The license that applies to `collection`, or nil when nothing should be asserted.
    /// Mirrors `resolveLicense` in `Resources/Template/src/lib/licensing.ts` exactly — this is
    /// the Swift-side port of the same precedence rule (explicit per-collection entry, including
    /// an explicit null, wins; then the non-asserting default; then the site default) — needed
    /// app-side for the first time by the attach-time license picker (#999), which has to know
    /// what a file's containing collection would resolve to *before* the file is written, not
    /// just at template build time.
    ///
    /// `collection == nil` means a page outside every collection (e.g. a static `.astro` page) —
    /// it resolves straight to the site default, since no per-collection rule can apply.
    public func resolvedLicense(for collection: LicensableCollection?) -> LicenseRef? {
        guard let collection else { return defaultLicense }
        switch rule(for: collection) {
        case .inherit:
            return collection.assertsNothingByDefault ? nil : defaultLicense
        case .assertNothing:
            return nil
        case .license(let ref):
            return ref
        }
    }

    /// Whether a per-file embedding control (the attach-time picker, and later the drop-and-
    /// inspect picker) should be suppressed entirely for `collection` — the owner-locked rule
    /// (#999, 2026-08-13): the four non-asserting collections don't get an embedding choice
    /// offered at all, *unless* the site owner has explicitly overridden that collection with a
    /// real license, in which case the override wins the same way it wins in `resolvedLicense`.
    public func suppressesFileEmbedding(for collection: LicensableCollection?) -> Bool {
        guard let collection else { return false }
        if case .license = rule(for: collection) { return false }
        return collection.assertsNothingByDefault
    }
```

Add after the closing brace of the `LicensableCollection` enum (right after its `assertsNothingByDefault` computed property, before the enum's closing `}`):

```swift

    /// Best-effort collection for a page route like `/notes/my-slug/` — the route's first
    /// non-empty path segment, when it names a licensable collection. `nil` for routes outside
    /// every collection (the home page, static pages), which should resolve straight to the site
    /// default via `LicensingPolicy.resolvedLicense(for: nil)`.
    public init?(routePath: String) {
        guard let segment = routePath.split(separator: "/", omittingEmptySubsequences: true).first,
              let match = LicensableCollection(rawValue: String(segment)) else {
            return nil
        }
        self = match
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter LicensingStoreTests`
Expected: PASS — all cases, including the five new ones.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/LicensingStore.swift Tests/AnglesiteCoreTests/LicensingStoreTests.swift
git commit -m "feat(#999): add LicensingPolicy.resolvedLicense and route-to-collection lookup"
```

---

### Task 2: Last-used file-license choice persistence

**Files:**
- Create: `Sources/AnglesiteCore/FileLicenseSelection.swift`
- Modify: `Sources/AnglesiteCore/AppSettings.swift`
- Test: `Tests/AnglesiteCoreTests/FileLicenseSelectionTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  ```swift
  public struct FileLicenseSelection: Codable, Equatable, Sendable {
      public var isEnabled: Bool
      public var catalogID: String
      public init(isEnabled: Bool, catalogID: String)
  }
  extension AppSettings {
      public var lastUsedFileLicenseSelection: FileLicenseSelection? { get set }
  }
  ```

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/FileLicenseSelectionTests.swift`:

```swift
import Foundation
import Testing
@testable import AnglesiteCore

@Suite("AppSettings.lastUsedFileLicenseSelection (#999)")
struct FileLicenseSelectionTests {
    private func makeSettings() -> AppSettings {
        let suiteName = "FileLicenseSelectionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return AppSettings(defaults: defaults)
    }

    @Test("nil until a choice is ever persisted")
    func absentByDefault() {
        #expect(makeSettings().lastUsedFileLicenseSelection == nil)
    }

    @Test("round-trips a persisted choice")
    func roundTrips() {
        let settings = makeSettings()
        let selection = FileLicenseSelection(isEnabled: true, catalogID: "cc-by-4.0")
        settings.lastUsedFileLicenseSelection = selection
        #expect(settings.lastUsedFileLicenseSelection == selection)
    }

    @Test("clearing writes back to nil")
    func clears() {
        let settings = makeSettings()
        settings.lastUsedFileLicenseSelection = FileLicenseSelection(isEnabled: true, catalogID: "cc0-1.0")
        settings.lastUsedFileLicenseSelection = nil
        #expect(settings.lastUsedFileLicenseSelection == nil)
    }
}
```

Note: this test assumes `AppSettings` has a non-`shared` initializer taking a `UserDefaults` instance directly — confirm this exists (it's implied by the type doc comment "tests should construct their own instance with a scratch `UserDefaults` suite" in `Sources/AnglesiteCore/AppSettings.swift:9-10`); if the initializer's exact label differs from `AppSettings(defaults:)`, match whatever `init` the type already declares instead of introducing a second one.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter FileLicenseSelectionTests`
Expected: FAIL to build — `FileLicenseSelection` and `lastUsedFileLicenseSelection` don't exist yet.

- [ ] **Step 3: Create `FileLicenseSelection`**

Create `Sources/AnglesiteCore/FileLicenseSelection.swift`:

```swift
import Foundation

/// The attach-time license picker's persisted last-used choice (#999) — so a site owner who
/// licenses all their photos the same way sets it once. Deliberately just an on/off flag plus a
/// `LicenseCatalog` id rather than a full `LicenseRef`: this picker offers catalog licenses only
/// (no custom URL entry — see the plan doc's Global Constraints), so a stable catalog id is
/// enough to restore the exact same choice next time, and stays valid even if a catalog entry's
/// display name ever changes.
public struct FileLicenseSelection: Codable, Equatable, Sendable {
    /// Whether the checkbox was on — i.e. whether a license should be embedded at all.
    public var isEnabled: Bool
    /// `LicenseCatalog.Entry.id` of the picked license. Meaningful only when `isEnabled`; kept
    /// even when disabled so re-enabling the checkbox restores the same picker selection.
    public var catalogID: String

    public init(isEnabled: Bool, catalogID: String) {
        self.isEnabled = isEnabled
        self.catalogID = catalogID
    }
}
```

- [ ] **Step 4: Add the `AppSettings` key and computed property**

In `Sources/AnglesiteCore/AppSettings.swift`, add a new key inside `enum Key` (after the existing `externalLLMVerifiedDetail` key, following the file's existing ordering-by-addition convention):

```swift
        /// Backs ``AppSettings/lastUsedFileLicenseSelection`` (#999).
        public static let lastUsedFileLicenseSelection = "anglesite.lastUsedFileLicenseSelection"
```

Add the computed property near the other JSON-backed optional properties (following the exact `externalLLMVerifiedBaseURL`-style optional-with-explicit-remove pattern already in this file):

```swift

    /// The attach-time license picker's last-used choice (#999) — `nil` until the picker has
    /// been used at least once. JSON-encoded because `FileLicenseSelection` is a small struct,
    /// not a primitive `UserDefaults` can store directly.
    public var lastUsedFileLicenseSelection: FileLicenseSelection? {
        get {
            guard let data = defaults.data(forKey: Key.lastUsedFileLicenseSelection) else { return nil }
            return try? JSONDecoder().decode(FileLicenseSelection.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.lastUsedFileLicenseSelection)
            } else {
                defaults.removeObject(forKey: Key.lastUsedFileLicenseSelection)
            }
        }
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --package-path . --filter FileLicenseSelectionTests`
Expected: PASS — all three cases.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/FileLicenseSelection.swift Sources/AnglesiteCore/AppSettings.swift Tests/AnglesiteCoreTests/FileLicenseSelectionTests.swift
git commit -m "feat(#999): persist the attach-time license picker's last-used choice"
```

---

### Task 3: `InsertImageLicenseChoice` (pure picker state)

**Files:**
- Create: `Sources/AnglesiteApp/InsertImageLicenseChoice.swift`
- Test: `Tests/AnglesiteAppTests/InsertImageLicenseChoiceTests.swift`

**Interfaces:**
- Consumes: `LicenseCatalog`, `LicenseRef` (AnglesiteCore), `FileLicenseSelection` (Task 2).
- Produces:
  ```swift
  struct InsertImageLicenseChoice: Equatable {
      var isEnabled: Bool
      var catalogID: String
      func resolvedLicense() -> LicenseRef?
      static func initial(resolvedDefault: LicenseRef?, lastUsed: FileLicenseSelection?) -> InsertImageLicenseChoice
      var persisted: FileLicenseSelection { get }
  }
  ```

- [ ] **Step 1: Write the failing test**

Create `Tests/AnglesiteAppTests/InsertImageLicenseChoiceTests.swift`:

```swift
import Foundation
import Testing
import AnglesiteCore
@testable import AnglesiteApp

@Suite("InsertImageLicenseChoice (#999)")
struct InsertImageLicenseChoiceTests {
    private let ccBY = LicenseRef(url: "https://creativecommons.org/licenses/by/4.0/", name: "CC BY 4.0")

    @Test("resolvedLicense is nil when disabled, regardless of catalogID")
    func disabledResolvesNil() {
        let choice = InsertImageLicenseChoice(isEnabled: false, catalogID: "cc-by-4.0")
        #expect(choice.resolvedLicense() == nil)
    }

    @Test("resolvedLicense looks up the catalog entry when enabled")
    func enabledResolvesCatalogEntry() {
        let choice = InsertImageLicenseChoice(isEnabled: true, catalogID: "cc-by-4.0")
        #expect(choice.resolvedLicense() == ccBY)
    }

    @Test("resolvedLicense is nil for an unrecognized catalogID even when enabled")
    func unknownCatalogIDResolvesNil() {
        let choice = InsertImageLicenseChoice(isEnabled: true, catalogID: "not-a-real-id")
        #expect(choice.resolvedLicense() == nil)
    }

    @Test("initial seeds from lastUsed when present")
    func initialFromLastUsed() {
        let lastUsed = FileLicenseSelection(isEnabled: true, catalogID: "cc0-1.0")
        let choice = InsertImageLicenseChoice.initial(resolvedDefault: ccBY, lastUsed: lastUsed)
        #expect(choice == InsertImageLicenseChoice(isEnabled: true, catalogID: "cc0-1.0"))
    }

    @Test("initial falls back to the resolved collection default, disabled, when no lastUsed exists")
    func initialFromResolvedDefault() {
        let choice = InsertImageLicenseChoice.initial(resolvedDefault: ccBY, lastUsed: nil)
        #expect(choice == InsertImageLicenseChoice(isEnabled: false, catalogID: "cc-by-4.0"))
    }

    @Test("initial falls back to the first catalog entry when there's no resolved default and no lastUsed")
    func initialFallsBackToFirstCatalogEntry() {
        let choice = InsertImageLicenseChoice.initial(resolvedDefault: nil, lastUsed: nil)
        #expect(choice == InsertImageLicenseChoice(isEnabled: false, catalogID: LicenseCatalog.entries[0].id))
    }

    @Test("persisted round-trips through FileLicenseSelection")
    func persistedRoundTrips() {
        let choice = InsertImageLicenseChoice(isEnabled: true, catalogID: "cc-by-sa-4.0")
        #expect(choice.persisted == FileLicenseSelection(isEnabled: true, catalogID: "cc-by-sa-4.0"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter InsertImageLicenseChoiceTests`
Expected: FAIL to build — `InsertImageLicenseChoice` doesn't exist yet.

- [ ] **Step 3: Implement `InsertImageLicenseChoice`**

Create `Sources/AnglesiteApp/InsertImageLicenseChoice.swift`:

```swift
import Foundation
import AnglesiteCore

/// `Insert ▸ Image…`'s license-embedding checkbox + picker, held as a plain value (not directly
/// as AppKit control state) so its resolution logic is unit-testable without a live
/// `NSOpenPanel` — mirrors `LicenseGateSheetView.Selection`'s reasoning exactly. Internal (not
/// `private`) so tests can construct and compare it directly.
struct InsertImageLicenseChoice: Equatable {
    /// Whether the checkbox is on — whether a license should be embedded into the picked file
    /// at all.
    var isEnabled: Bool
    /// The `LicenseCatalog.Entry.id` currently selected in the popup, meaningful only when
    /// `isEnabled` (but always a valid id, so re-enabling the checkbox shows a real choice).
    var catalogID: String

    /// The license to embed, or nil when the checkbox is off or the id doesn't match a known
    /// catalog entry (defensive — the picker only ever offers real ids, so this should not
    /// happen in practice).
    func resolvedLicense() -> LicenseRef? {
        guard isEnabled else { return nil }
        return LicenseCatalog.entries.first { $0.id == catalogID }?.ref
    }

    /// The initial picker state when `Insert ▸ Image…` opens: the persisted last-used choice
    /// when one exists, otherwise the page's resolved collection license as the popup's
    /// starting selection — but with the checkbox left **off**, since embedding is a
    /// destructive edit and this is the very first time the picker has been shown. Falls back
    /// to the catalog's first entry when there is no resolved default to seed from at all (an
    /// untouched site, or a page outside every collection with no site-wide default either) —
    /// the popup must always show a real selection.
    static func initial(resolvedDefault: LicenseRef?, lastUsed: FileLicenseSelection?) -> InsertImageLicenseChoice {
        if let lastUsed {
            return InsertImageLicenseChoice(isEnabled: lastUsed.isEnabled, catalogID: lastUsed.catalogID)
        }
        let fallbackID = LicenseCatalog.entry(for: resolvedDefault)?.id ?? LicenseCatalog.entries[0].id
        return InsertImageLicenseChoice(isEnabled: false, catalogID: fallbackID)
    }

    /// The form this choice is persisted as (`AppSettings.lastUsedFileLicenseSelection`).
    var persisted: FileLicenseSelection {
        FileLicenseSelection(isEnabled: isEnabled, catalogID: catalogID)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter InsertImageLicenseChoiceTests`
Expected: PASS — all seven cases.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/InsertImageLicenseChoice.swift Tests/AnglesiteAppTests/InsertImageLicenseChoiceTests.swift
git commit -m "feat(#999): add pure state for the attach-time license picker"
```

---

### Task 4: Wire the accessory view and embedding call into `Insert ▸ Image…`

**Files:**
- Modify: `Sources/AnglesiteApp/InsertCommands.swift`

**Interfaces:**
- Consumes: `InsertImageLicenseChoice` (Task 3), `LicenseMetadataEmbedder` (embedded-license-metadata plan, Task 1-3 — **hard dependency, must be merged first**), `LicensingStore`/`LicensingPolicy.resolvedLicense(for:)`/`suppressesFileEmbedding(for:)`/`LicensableCollection(routePath:)` (Task 1), `AppSettings.lastUsedFileLicenseSelection` (Task 2).
- This task has no dedicated unit test of its own — `NSOpenPanel.runModal()` cannot be driven headlessly. Its correctness rests on Tasks 1-3's tests (the logic it calls) plus a manual verification pass (Step 4 below). This mirrors how `InsertCommands.insertImage(into:)`'s existing `NSOpenPanel` code has no direct test today either — confirmed by grep, `Tests/AnglesiteAppTests/` has no `InsertCommandsTests.swift`.

- [ ] **Step 1: Manually verify the dependency is in place**

Run: `swift test --package-path . --filter LicenseMetadataEmbedderTests`
Expected: PASS. If this fails to build, stop — the embedded-license-metadata plan's `LicenseMetadataEmbedder` type must exist and pass its own tests before this task can proceed.

- [ ] **Step 2: Replace `insertImage(into:)` with the license-aware version**

In `Sources/AnglesiteApp/InsertCommands.swift`, replace the whole `insertImage(into:)` method (lines 24-56):

```swift
    @MainActor
    private static func insertImage(into preview: PreviewModel) async {
        let route = preview.activeRoute ?? "/"
        let collection = LicensableCollection(routePath: route)

        var policy = LicensingPolicy()
        if let sourceDirectory = preview.openSiteDirectory {
            policy = (try? LicensingStore(sourceDirectory: sourceDirectory).load()) ?? LicensingPolicy()
        }
        let suppressesEmbedding = policy.suppressesFileEmbedding(for: collection)

        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = String(localized: "Insert")
        panel.message = String(localized: "Choose an image to insert into this page.")

        var licenseCheckbox: NSButton?
        var licensePopup: NSPopUpButton?
        var initialChoice = InsertImageLicenseChoice(isEnabled: false, catalogID: LicenseCatalog.entries[0].id)
        if !suppressesEmbedding {
            initialChoice = InsertImageLicenseChoice.initial(
                resolvedDefault: policy.resolvedLicense(for: collection),
                lastUsed: AppSettings.shared.lastUsedFileLicenseSelection)
            let (accessory, checkbox, popup) = makeLicenseAccessory(initial: initialChoice)
            panel.accessoryView = accessory
            licenseCheckbox = checkbox
            licensePopup = popup
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        var bytes: Data
        do {
            bytes = try Data(contentsOf: url)
        } catch {
            presentFailureAlert(detail: error.localizedDescription)
            return
        }

        if !suppressesEmbedding, let checkbox = licenseCheckbox, let popup = licensePopup {
            let choice = InsertImageLicenseChoice(
                isEnabled: checkbox.state == .on,
                catalogID: popup.selectedItem?.representedObject as? String ?? initialChoice.catalogID)
            AppSettings.shared.lastUsedFileLicenseSelection = choice.persisted
            if let license = choice.resolvedLicense(),
               let type = UTType(filenameExtension: url.pathExtension) {
                do {
                    let result = try LicenseMetadataEmbedder.embed(license, into: bytes, type: type)
                    if case .embedded(let embeddedData) = result {
                        bytes = embeddedData
                    }
                } catch {
                    presentFailureAlert(detail: error.localizedDescription)
                    return
                }
            }
        }

        let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let dataURL = InsertImageEditBuilder.dataURL(bytes: bytes, mimeType: mimeType)
        let message = InsertImageEditBuilder.message(
            path: preview.activeRoute ?? "/",
            filename: url.lastPathComponent,
            mimeType: mimeType,
            dataURL: dataURL
        )

        let reply = await preview.editRouter.apply(message)
        if reply.status != .applied {
            presentFailureAlert(detail: reply.message ?? "Unknown error")
        }
    }

    /// Builds the `NSOpenPanel` accessory view for the attach-time license picker (#999): a
    /// checkbox plus a popup of catalog licenses, following the same plain-`NSView`-with-AppKit-
    /// controls idiom `SiteActions.exportSource(of:)` uses for its "Include Git history"
    /// checkbox — no `NSHostingView`/SwiftUI needed for a control this simple, and it keeps this
    /// file's only new AppKit surface consistent with the one other accessory view in the app.
    @MainActor
    private static func makeLicenseAccessory(
        initial: InsertImageLicenseChoice
    ) -> (view: NSView, checkbox: NSButton, popup: NSPopUpButton) {
        let checkbox = NSButton(
            checkboxWithTitle: String(localized: "Embed a license in this file"), target: nil, action: nil)
        checkbox.state = initial.isEnabled ? .on : .off
        checkbox.frame = NSRect(x: 12, y: 32, width: 280, height: 20)

        let popup = NSPopUpButton(frame: NSRect(x: 12, y: 4, width: 280, height: 24), pullsDown: false)
        for entry in LicenseCatalog.entries {
            let item = NSMenuItem(title: entry.name, action: nil, keyEquivalent: "")
            item.representedObject = entry.id
            popup.menu?.addItem(item)
        }
        if let index = LicenseCatalog.entries.firstIndex(where: { $0.id == initial.catalogID }) {
            popup.selectItem(at: index)
        }

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 304, height: 60))
        accessory.addSubview(checkbox)
        accessory.addSubview(popup)
        return (accessory, checkbox, popup)
    }
```

- [ ] **Step 3: Run the full AnglesiteAppTests suite and build the app**

Run: `swift test --package-path . --filter AnglesiteAppTests`
Expected: PASS.

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Manual verification pass**

This step can't be automated (`NSOpenPanel` + real image files). Launch the built app, open a site, and verify by hand:
1. Navigate the preview to a page inside a licensable, asserting collection (e.g. `/notes/...`) with a site default license configured in Settings ▸ Content Licensing. Choose `Insert ▸ Image…`. Confirm the accessory view shows the checkbox (off by default on first use) and the popup pre-selected to the site default's catalog entry.
2. Check the box, pick a different catalog license, insert an image. Confirm the image appears in the page as before (no regression to the existing insert behavior).
3. Choose `Insert ▸ Image…` again. Confirm the checkbox and popup now default to the choice made in step 2 (last-used persistence).
4. Navigate to a page inside `/bookmarks/...` (or another non-asserting collection) with no per-collection override configured. Choose `Insert ▸ Image…`. Confirm **no accessory view appears at all** (suppressed).
5. If feasible, inspect the inserted image's XMP metadata (e.g. via `exiftool` or Finder's Get Info ▸ More Info, if available) to confirm the embedded license is actually present in the file that landed in the site.

Record the outcome of this manual pass in the PR description — this plan's "Test plan" section should say explicitly that steps 1-4 (and ideally 5) were performed and what was observed, per `superpowers:verification-before-completion`.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/InsertCommands.swift
git commit -m "feat(#999): wire attach-time license embedding into Insert > Image"
```

---

## Self-Review Notes

- **Spec coverage:** Issue #999 scope item 3 ("The file open dialog grows a checkbox plus a license selector, applied to the imported file when checked. The selection persists as the last-used choice") is fully covered for the one existing image-import entry point. The "non-asserting collections suppress embedded metadata" owner decision (2026-08-13) is covered by `suppressesFileEmbedding(for:)` and Task 4 Step 2's `suppressesEmbedding` gate.
- **Not covered by this plan, deliberately:**
  - Drag-and-drop onto the WKWebView preview — no native file-open step exists there to attach a checkbox/popup to; that's issue #999 scope item 4 ("drop and inspect"), which also requires resolving a real open question this plan does not attempt: whether an already-inserted site asset's bytes are reachable and rewritable from Swift at all, given inserted files are written by the sidecar container's `processImageDrop`, not by this app directly (see `AGENTS.md` ▸ "Two-repo coordination"). That needs its own investigation before it can get its own bite-sized plan — flag this explicitly to the site owner rather than guessing at an architecture.
  - `Insert ▸ Video`/`Insert ▸ Audio` — both are still `PlannedItem` stubs with no import flow to attach a picker to (confirmed in `InsertCommands.swift:123-124`).
  - Custom (non-catalog) per-file licenses — explicitly cut from this compact accessory view; see Global Constraints.
- **Type consistency check:** `InsertImageLicenseChoice.catalogID`, `FileLicenseSelection.catalogID`, and `LicenseCatalog.Entry.id` are all `String` and refer to the same identifier space throughout Tasks 2-4 — verified by re-reading the three files together before finalizing this plan.
