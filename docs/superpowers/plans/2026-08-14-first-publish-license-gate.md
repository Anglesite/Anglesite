# First-Publish License Gate Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Block a site's first deploy on an explicit content-license choice — including "All rights reserved" — shown as a Creative Commons comparison table with an AI-interpretation column.

**Architecture:** `LicensingPolicy` gains one new persisted field, `licenseChosen: Bool`, so the model can distinguish "never asked" from "explicitly chose All rights reserved" (both currently collapse to `defaultLicense == nil`). `DeployModel.deploy(...)` gets a new precondition guard — identical in shape to its existing `hasUsableToken()` guard — that parks the deploy and presents a new `LicenseGateSheetView` when `licenseChosen` is false; confirming a choice there saves the policy and resumes the parked deploy. `deployAutomatically(...)` (the background invisible-publish path) defers instead of presenting UI, matching how it already defers on a missing token.

**Tech Stack:** Swift 6.4, SwiftUI, Swift Testing (`@Test`/`@Suite`), existing `LicensingStore`/`LicenseCatalog` (`AnglesiteCore`).

## Global Constraints

- No third-party frameworks — Apple frameworks only.
- No migration path for existing sites' `licensing.json` — Anglesite is pre-TestFlight; `licenseChosen` simply decodes to `false` when the key is absent (see `no-migration-before-testflight` memory).
- The gate is a hard block with no dismiss: the sheet cannot be swiped/Esc-dismissed without an explicit choice.
- This plan covers #999 item 1 only (the publish gate). Per-file embedded license metadata (items 2-4) is a separate, later plan — do not implement it here.
- Work happens in the existing worktree `.claude/worktrees/999-first-publish-license-gate/` on branch `999-first-publish-license-gate`, which already carries the approved design spec commit (`199e413b`). Every command below assumes cwd = that worktree.

---

### Task 1: `licenseChosen` field on `LicensingPolicy`

**Files:**
- Modify: `Sources/AnglesiteCore/LicensingStore.swift:232-275` (struct + init), `:277-386` (Codable)
- Test: `Tests/AnglesiteCoreTests/LicensingStoreTests.swift`

**Interfaces:**
- Produces: `LicensingPolicy.licenseChosen: Bool` (default `false`), threaded through `LicensingPolicy.init(...)` and its `Codable` conformance. Everything downstream (Task 2) reads/writes this via `LicensingStore.load()`/`save(_:)`, unchanged.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/AnglesiteCoreTests/LicensingStoreTests.swift`, immediately before the suite's closing `}` (after the existing `loadAbsentPublishRSL` test):

```swift
    @Test("licenseChosen defaults to false, matching a site with no licensing.json")
    func licenseChosenDefaultsFalse() {
        #expect(LicensingPolicy().licenseChosen == false)
    }

    @Test("save() then load() round-trips licenseChosen true")
    func licenseChosenRoundTrips() throws {
        let dir = try makeDirectory()
        var policy = LicensingPolicy()
        policy.licenseChosen = true
        try LicensingStore(sourceDirectory: dir).save(policy)
        #expect(try LicensingStore(sourceDirectory: dir).load().licenseChosen == true)
    }

    @Test("save() always writes licenseChosen explicitly, even when false")
    func saveAlwaysWritesLicenseChosen() throws {
        let dir = try makeDirectory()
        try LicensingStore(sourceDirectory: dir).save(LicensingPolicy())
        let json = try String(
            contentsOf: dir.appendingPathComponent("src/data/licensing.json"), encoding: .utf8)
        #expect(json.contains("\"licenseChosen\""))
    }

    @Test(
        "load() degrades a non-boolean licenseChosen to false instead of throwing",
        arguments: [
            #"{"licenseChosen":"true"}"#,
            #"{"licenseChosen":1}"#,
            #"{"licenseChosen":null}"#,
        ]
    )
    func loadDegradesNonBooleanLicenseChosen(_ json: String) throws {
        let dir = try makeDirectory()
        try write(json, to: dir)
        #expect(try LicensingStore(sourceDirectory: dir).load().licenseChosen == false)
    }

    @Test("an absent licenseChosen key loads as false, matching a site with no licensing.json")
    func loadAbsentLicenseChosen() throws {
        let dir = try makeDirectory()
        try write(#"{"default":null}"#, to: dir)
        #expect(try LicensingStore(sourceDirectory: dir).load().licenseChosen == false)
    }

    @Test("an explicit true licenseChosen key loads correctly on its own")
    func loadExplicitTrueLicenseChosen() throws {
        let dir = try makeDirectory()
        try write(#"{"licenseChosen":true}"#, to: dir)
        #expect(try LicensingStore(sourceDirectory: dir).load().licenseChosen == true)
    }
```

- [ ] **Step 2: Run the tests to verify they fail to compile**

Run: `swift test --package-path . --filter LicensingStoreTests`
Expected: FAIL — `value of type 'LicensingPolicy' has no member 'licenseChosen'`

- [ ] **Step 3: Add the field and thread it through `init`**

In `Sources/AnglesiteCore/LicensingStore.swift`, in the `LicensingPolicy` struct (around line 243), add the field after `publishRSL`:

```swift
    public var publishRSL: Bool
    /// Whether an explicit license choice has been made — including "All rights reserved" —
    /// distinct from `defaultLicense == nil`, which is also the untouched-scaffold state.
    /// Set by the first-publish license gate (#999); never inferred from the rest of the
    /// policy, so a hand-edited `licensing.json` that merely looks non-empty doesn't count.
    public var licenseChosen: Bool
```

Update the initializer immediately below it:

```swift
    public init(
        defaultLicense: LicenseRef? = nil,
        collections: [LicensableCollection: CollectionLicenseRule] = [:],
        usage: AIUsage = AIUsage(),
        publishRSL: Bool = false,
        licenseChosen: Bool = false
    ) {
        self.defaultLicense = defaultLicense
        self.collections = collections
        self.usage = usage
        self.publishRSL = publishRSL
        self.licenseChosen = licenseChosen
    }
```

- [ ] **Step 4: Update `Codable` conformance**

In the same file's `LicensingPolicy: Codable` extension, add the coding key:

```swift
    private enum CodingKeys: String, CodingKey {
        case `default`, collections, usage, publishRSL, licenseChosen
    }
```

In `init(from decoder:)`, right after the existing `publishRSL` decode line, add the lenient decode and pass it into `self.init(...)`:

```swift
        let publishRSL = ((try? container.decodeIfPresent(Bool.self, forKey: .publishRSL)) ?? nil) ?? false
        // Same lenient-decode treatment as publishRSL: a non-boolean or absent value degrades
        // to false — "never asked" — rather than throwing or inferring "asked" from a
        // present-but-garbage value (#999).
        let licenseChosen = ((try? container.decodeIfPresent(Bool.self, forKey: .licenseChosen)) ?? nil) ?? false
        self.init(defaultLicense: defaultLicense, collections: collections, usage: usage.clamped,
                   publishRSL: publishRSL, licenseChosen: licenseChosen)
```

(This replaces the existing final `self.init(...)` call — same arguments plus `licenseChosen`.)

In `encode(to encoder:)`, right after the existing `publishRSL` encode line, add:

```swift
        try container.encode(publishRSL, forKey: .publishRSL)
        try container.encode(licenseChosen, forKey: .licenseChosen)
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path . --filter LicensingStoreTests`
Expected: PASS (all cases, including the pre-existing ones — `LicensingPolicy`'s synthesized `Equatable` picks up the new field automatically, so `roundTrip()` still passes unmodified)

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/LicensingStore.swift Tests/AnglesiteCoreTests/LicensingStoreTests.swift
git commit -m "feat(#999): add licenseChosen to LicensingPolicy"
```

---

### Task 2: `DeployModel` gate — park, present, confirm

**Files:**
- Modify: `Sources/AnglesiteApp/DeployModel.swift:88` (new properties), `:261-290` (`deploy()`), `:296-337` (`deployAutomatically()`), `:407-411` (new `confirmLicenseChoice` method, after `cancelTokenPrompt()`)
- Test: `Tests/AnglesiteAppTests/DeployModelTests.swift`

**Interfaces:**
- Consumes: `LicensingStore(sourceDirectory: URL)`, `.load() throws -> LicensingPolicy`, `.save(_:) throws` (Task 1); `LicenseCatalog.prefilled(_:for:) -> AIUsage` (existing).
- Produces: `DeployModel.licenseGatePresented: Bool` (read/write, sheet binding), `DeployModel.licenseGateError: String?` (read-only), `DeployModel.confirmLicenseChoice(_ license: LicenseRef?)` — called by `LicenseGateSheetView` (Task 3).

- [ ] **Step 1: Write the failing tests**

Add to `Tests/AnglesiteAppTests/DeployModelTests.swift`, immediately before the suite's closing `}` at line 889:

```swift
    private func makeLicenseGateSiteDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeployModelLicenseGateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("deploy() presents the license gate instead of running when no license has been chosen")
    func deployPresentsLicenseGateWhenUnchosen() throws {
        let executor = GatedDeployExecutor()
        let command = DeployCommand(tokenSource: { "test-token" }, executor: executor)
        let model = DeployModel(
            command: command, logCenter: LogCenter(), keychain: InMemorySecretStore(),
            tokenAvailabilityOverride: { true })
        let directory = try makeLicenseGateSiteDirectory()

        model.deploy(siteID: "s", siteDirectory: directory, configDirectory: directory, currentRoutes: [])

        let licenseGatePresented = model.licenseGatePresented
        let isRunning = model.isRunning
        #expect(licenseGatePresented)
        #expect(!isRunning)
    }

    @Test("confirmLicenseChoice saves the policy and resumes the parked deploy")
    func confirmLicenseChoiceSavesAndResumes() async throws {
        let executor = GatedDeployExecutor()
        let command = DeployCommand(tokenSource: { "test-token" }, executor: executor)
        let model = DeployModel(
            command: command, logCenter: LogCenter(), keychain: InMemorySecretStore(),
            tokenAvailabilityOverride: { true })
        let directory = try makeLicenseGateSiteDirectory()

        model.deploy(siteID: "s", siteDirectory: directory, configDirectory: directory, currentRoutes: [])
        let licenseGatePresentedBeforeConfirm = model.licenseGatePresented
        #expect(licenseGatePresentedBeforeConfirm)

        let ccBY = LicenseCatalog.entries.first { $0.id == "cc-by-4.0" }!.ref
        model.confirmLicenseChoice(ccBY)
        await executor.waitUntilBuildIsParked()
        await executor.resumeBuild()
        while model.isRunning { await Task.yield() }

        let licenseGatePresentedAfterConfirm = model.licenseGatePresented
        #expect(!licenseGatePresentedAfterConfirm)
        guard case .succeeded = model.phase else {
            Issue.record("expected the parked deploy to run after confirming a license, got \(model.phase)")
            return
        }

        let policy = try LicensingStore(sourceDirectory: directory).load()
        #expect(policy.licenseChosen)
        #expect(policy.defaultLicense == ccBY)
        #expect(policy.usage.aiTrain == .yes)
    }

    @Test("confirming All rights reserved (nil) still marks the choice made")
    func confirmAllRightsReservedMarksChosen() async throws {
        let executor = GatedDeployExecutor()
        let command = DeployCommand(tokenSource: { "test-token" }, executor: executor)
        let model = DeployModel(
            command: command, logCenter: LogCenter(), keychain: InMemorySecretStore(),
            tokenAvailabilityOverride: { true })
        let directory = try makeLicenseGateSiteDirectory()

        model.deploy(siteID: "s", siteDirectory: directory, configDirectory: directory, currentRoutes: [])
        model.confirmLicenseChoice(nil)
        await executor.waitUntilBuildIsParked()
        await executor.resumeBuild()
        while model.isRunning { await Task.yield() }

        let policy = try LicensingStore(sourceDirectory: directory).load()
        #expect(policy.licenseChosen)
        #expect(policy.defaultLicense == nil)
    }

    @Test("deployAutomatically defers when a license hasn't been chosen")
    func deployAutomaticallyDefersWithoutLicense() async throws {
        let executor = GatedDeployExecutor()
        let command = DeployCommand(tokenSource: { "test-token" }, executor: executor)
        let model = DeployModel(
            command: command, logCenter: LogCenter(), keychain: InMemorySecretStore(),
            tokenAvailabilityOverride: { true })
        let directory = try makeLicenseGateSiteDirectory()

        let result = await model.deployAutomatically(
            siteID: "s", siteDirectory: directory, configDirectory: directory, currentRoutes: [],
            containerControlProvider: { nil })

        guard case .deferred(let reason) = result else {
            Issue.record("expected .deferred, got \(result)")
            return
        }
        #expect(reason.contains("license"))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path . --filter DeployModelTests`
Expected: FAIL — `value of type 'DeployModel' has no member 'licenseGatePresented'` (and `confirmLicenseChoice`)

- [ ] **Step 3: Add the new properties**

In `Sources/AnglesiteApp/DeployModel.swift`, immediately after `tokenPromptPresented` (line 88), before `workerNameConflictPresented`:

```swift
    /// Bound to a `.sheet` in `SiteWindow` for the first-publish license gate (#999). Set when
    /// `deploy(...)` is invoked and the site's `licensing.json` has never recorded an explicit
    /// license choice. Reuses `pendingDeploy` to park and retry, same as the token-prompt flow.
    /// Unlike the other `pendingDeploy` sheets, this one is wired with
    /// `.interactiveDismissDisabled()` in `SiteWindow` — the design is a hard block, so there is
    /// deliberately no `cancelLicenseGate()` to pair with it.
    var licenseGatePresented: Bool = false
    /// Set when saving the chosen policy fails (e.g. an unsafe custom license URL). Cleared on
    /// every fresh presentation and on a successful `confirmLicenseChoice(_:)`.
    private(set) var licenseGateError: String?
```

- [ ] **Step 4: Add the `deploy()` guard**

In `deploy(...)` (line 261), insert the license check between the existing token guard and the `phase = .running(...)` line:

```swift
        guard !isRunning else { return }
        if !hasUsableToken() {
            pendingDeploy = (siteID, siteDirectory, configDirectory, currentRoutes, containerControlProvider, siteName)
            tokenVerification = .idle
            tokenPromptPresented = true
            return
        }
        if !hasChosenLicense(siteDirectory: siteDirectory) {
            pendingDeploy = (siteID, siteDirectory, configDirectory, currentRoutes, containerControlProvider, siteName)
            licenseGateError = nil
            licenseGatePresented = true
            return
        }
        // Flip `phase` synchronously, before scheduling the Task, so a second `deploy()` call
```

- [ ] **Step 5: Add the `deployAutomatically()` guard**

In `deployAutomatically(...)` (line 296), insert between the `hasUsableToken()` guard and the container-control resolution:

```swift
        guard hasUsableToken() else { return .deferred(reason: "Cloudflare credentials are not configured") }
        guard hasChosenLicense(siteDirectory: siteDirectory) else {
            return .deferred(reason: "a content license hasn't been chosen yet")
        }
        // Resolved once (there's no user-facing prompt gap on this background path to make a
        let resolvedContainerControl = await containerControlProvider()
```

- [ ] **Step 6: Add the `hasChosenLicense` helper next to `hasUsableToken()`**

Immediately after `hasUsableToken()`'s closing brace (after line 583):

```swift
    /// Whether `siteDirectory`'s `licensing.json` records an explicit license choice (#999). A
    /// missing file or an unreadable/malformed document both read as "not chosen" —
    /// `LicensingStore.load()` already degrades every malformed shape to the empty policy, whose
    /// `licenseChosen` is `false`, so this mirrors that same fail-safe default rather than adding
    /// a second one.
    private func hasChosenLicense(siteDirectory: URL) -> Bool {
        (try? LicensingStore(sourceDirectory: siteDirectory).load())?.licenseChosen ?? false
    }
```

- [ ] **Step 7: Add `confirmLicenseChoice(_:)`**

Immediately after `cancelTokenPrompt()` (after line 411):

```swift
    /// Called by `LicenseGateSheetView`'s Continue button. Builds the policy from `license`
    /// (`nil` means "All rights reserved"), fills only unset AI-usage purposes via
    /// `LicenseCatalog.prefilled` (matching `ContentLicensingTab`'s own picker behavior, so this
    /// never clobbers a manual override made later), marks the choice made, and saves — then
    /// resumes the parked deploy. Owns its own `LicensingStore` directly rather than going
    /// through `PlistEditorModel`, so the gate works with no Settings window open.
    func confirmLicenseChoice(_ license: LicenseRef?) {
        guard let pending = pendingDeploy else {
            licenseGateError = "No deploy is waiting — close this and click Deploy again."
            return
        }
        let store = LicensingStore(sourceDirectory: pending.siteDirectory)
        var policy = (try? store.load()) ?? LicensingPolicy()
        policy.defaultLicense = license
        policy.usage = LicenseCatalog.prefilled(policy.usage, for: license)
        policy.licenseChosen = true
        do {
            try store.save(policy)
        } catch {
            licenseGateError = "Couldn't save your license choice: \(error)"
            return
        }
        pendingDeploy = nil
        licenseGateError = nil
        licenseGatePresented = false
        deploy(
            siteID: pending.siteID, siteDirectory: pending.siteDirectory,
            configDirectory: pending.configDirectory, currentRoutes: pending.currentRoutes,
            containerControlProvider: pending.containerControlProvider, siteName: pending.siteName)
    }
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `swift test --package-path . --filter DeployModelTests`
Expected: PASS (all four new tests, and the full existing suite — the license guard sits behind a directory whose `licensing.json` never exists in any prior test, so `hasChosenLicense` returns `false` there too; confirm no prior test now unexpectedly parks on the license gate by running the whole target in Step 9)

- [ ] **Step 9: Run the full app test target**

Run: `swift test --package-path . --filter AnglesiteAppTests`
Expected: PASS. If any pre-existing deploy test now hangs or fails, it means that test's `deploy(...)` call reached the new license guard unexpectedly — check whether it uses a `siteDirectory` where a `licensing.json` with `licenseChosen: true` should be written first, or add `tokenAvailabilityOverride` isn't the relevant fix (it already has one) — the real fix is ensuring that test's directory is unique (not a shared `FileManager.default.temporaryDirectory` reused across tests).

- [ ] **Step 10: Commit**

```bash
git add Sources/AnglesiteApp/DeployModel.swift Tests/AnglesiteAppTests/DeployModelTests.swift
git commit -m "feat(#999): gate DeployModel on an explicit license choice"
```

---

### Task 3: `LicenseGateSheetView`

**Files:**
- Create: `Sources/AnglesiteApp/LicenseGateSheetView.swift`
- Test: `Tests/AnglesiteAppTests/LicenseGateSelectionTests.swift`

**Interfaces:**
- Consumes: `DeployModel.licenseGateError: String?`, `DeployModel.confirmLicenseChoice(_:)` (Task 2); `LicenseCatalog.entries: [LicenseCatalog.Entry]`, `LicenseCatalog.Entry.{id, name, url, permitsAIUse, ref}` (existing).
- Produces: `LicenseGateSheetView` (SwiftUI view, `init(model: DeployModel)`); `LicenseGateSheetView.Selection` (nested pure struct — `choice`, `customURL`, `customName`, `isContinueEnabled`, `resolvedLicense()`), consumed by Task 4's `SiteWindow` wiring only via the view itself.

- [ ] **Step 1: Write the failing tests for the pure selection struct**

Create `Tests/AnglesiteAppTests/LicenseGateSelectionTests.swift`:

```swift
import Foundation
import Testing
import AnglesiteCore
@testable import AnglesiteAppCore

@Suite("LicenseGateSheetView.Selection (#999)")
struct LicenseGateSelectionTests {
    @Test("All rights reserved and a catalog choice are always continue-enabled")
    func nonCustomAlwaysEnabled() {
        var selection = LicenseGateSheetView.Selection()
        #expect(selection.isContinueEnabled)
        selection.choice = .catalog("cc-by-4.0")
        #expect(selection.isContinueEnabled)
    }

    @Test("Custom is disabled until a URL is typed")
    func customRequiresURL() {
        var selection = LicenseGateSheetView.Selection()
        selection.choice = .custom
        #expect(!selection.isContinueEnabled)
        selection.customURL = "https://example.com/license"
        #expect(selection.isContinueEnabled)
    }

    @Test("resolvedLicense maps All rights reserved to nil")
    func allRightsReservedResolvesToNil() {
        let selection = LicenseGateSheetView.Selection()
        #expect(selection.resolvedLicense() == nil)
    }

    @Test("resolvedLicense maps a catalog choice to its catalog LicenseRef")
    func catalogResolvesToCatalogRef() {
        var selection = LicenseGateSheetView.Selection()
        selection.choice = .catalog("cc-by-4.0")
        let expected = LicenseCatalog.entries.first { $0.id == "cc-by-4.0" }?.ref
        #expect(selection.resolvedLicense() == expected)
    }

    @Test("resolvedLicense falls back the custom name to the URL when empty")
    func customFallsBackNameToURL() {
        var selection = LicenseGateSheetView.Selection()
        selection.choice = .custom
        selection.customURL = "https://example.com/license"
        #expect(selection.resolvedLicense() == LicenseRef(
            url: "https://example.com/license", name: "https://example.com/license"))
    }

    @Test("resolvedLicense uses a typed custom name when present")
    func customUsesTypedName() {
        var selection = LicenseGateSheetView.Selection()
        selection.choice = .custom
        selection.customURL = "https://example.com/license"
        selection.customName = "House terms"
        #expect(selection.resolvedLicense() == LicenseRef(
            url: "https://example.com/license", name: "House terms"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail to compile**

Run: `swift test --package-path . --filter LicenseGateSelectionTests`
Expected: FAIL — `cannot find 'LicenseGateSheetView' in scope`

- [ ] **Step 3: Create the view file**

Create `Sources/AnglesiteApp/LicenseGateSheetView.swift`:

```swift
import SwiftUI
import AnglesiteCore

/// The first-publish license gate (#999) — a hard-blocking comparison table shown before a
/// site's first deploy, so "All rights reserved" is a choice the owner made rather than a
/// default they never saw. Confirming resumes the deploy `DeployModel` parked in its
/// `pendingDeploy`. No per-collection overrides or the "Refuse AI crawlers" toggle here — those
/// stay in Settings ▸ Content Licensing; this sheet only needs one decision made.
struct LicenseGateSheetView: View {
    @Bindable var model: DeployModel

    /// One row's pure state: which license is selected, and (for `.custom`) the URL/name typed
    /// so far. A fresh instance per presentation — the gate never shows a prior choice, since it
    /// only appears when none has been recorded yet. Extracted as a plain struct (not held
    /// directly as separate `@State` fields) so `isContinueEnabled`/`resolvedLicense()` are
    /// unit-testable without a hosted SwiftUI render pass, mirroring
    /// `ContentLicensingTab.PendingCustomLicense`. Internal (not `private`) so tests can
    /// construct and mutate it directly.
    struct Selection: Equatable {
        enum Choice: Hashable {
            case allRightsReserved
            case catalog(String)
            case custom
        }

        var choice: Choice = .allRightsReserved
        var customURL: String = ""
        var customName: String = ""

        /// False only for an empty-URL custom selection — every other choice is already
        /// complete the moment it's picked.
        var isContinueEnabled: Bool {
            if case .custom = choice { return !customURL.isEmpty }
            return true
        }

        /// The `LicenseRef?` `DeployModel.confirmLicenseChoice(_:)` should persist for the
        /// current choice, or nil for "All rights reserved."
        func resolvedLicense() -> LicenseRef? {
            switch choice {
            case .allRightsReserved:
                return nil
            case .catalog(let id):
                return LicenseCatalog.entries.first { $0.id == id }?.ref
            case .custom:
                return LicenseRef(url: customURL, name: customName.isEmpty ? customURL : customName)
            }
        }
    }

    @State private var selection = Selection()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose a License")
                .font(.title2.bold())
            Text("Before your first publish, pick what license covers your content. \"All rights reserved\" is a valid choice — Anglesite just never picks it for you silently.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("License")
                    Text("Permits")
                    Text("AI systems")
                }
                .font(.caption.bold())
                .foregroundStyle(.secondary)

                row(title: "All rights reserved", permits: "Nothing without asking", aiNote: nil,
                    choice: .allRightsReserved)

                ForEach(LicenseCatalog.entries) { entry in
                    row(
                        title: entry.name,
                        permits: permitsSummary(for: entry),
                        aiNote: entry.permitsAIUse ? "✅ Permits" : "❔ Unclear",
                        choice: .catalog(entry.id))
                }

                row(title: "Custom…", permits: "Your own terms", aiNote: nil, choice: .custom)
            }

            if selection.choice == .custom {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Address").frame(minWidth: 100, alignment: .leading)
                        TextField("https://example.com/license", text: $selection.customURL)
                            .frame(minWidth: 280)
                    }
                    GridRow {
                        Text("Name").frame(minWidth: 100, alignment: .leading)
                        TextField("My license", text: $selection.customName)
                            .frame(minWidth: 280)
                    }
                }
            }

            if let error = model.licenseGateError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("Continue") {
                    model.confirmLicenseChoice(selection.resolvedLicense())
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!selection.isContinueEnabled)
            }
        }
        .padding(24)
        .frame(minWidth: 520)
    }

    private func row(
        title: String, permits: String, aiNote: String?, choice: Selection.Choice
    ) -> some View {
        GridRow {
            Text(title)
            Text(permits).font(.caption).foregroundStyle(.secondary)
            Text(aiNote ?? "—").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(selection.choice == choice ? Color.accentColor.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { selection.choice = choice }
    }

    /// Plain-language summary of what each catalog license permits — the middle comparison-table
    /// column. Keyed by catalog id rather than re-deriving from `permitsAIUse` so it stays
    /// independent of the AI classification the last column already renders.
    private func permitsSummary(for entry: LicenseCatalog.Entry) -> String {
        switch entry.id {
        case "cc0-1.0": return "Any use, no credit required"
        case "cc-by-4.0": return "Any use, with credit"
        case "cc-by-sa-4.0": return "Any use, with credit, same license"
        case "cc-by-nc-4.0": return "Non-commercial use, with credit"
        case "cc-by-nd-4.0": return "Redistribute unmodified, with credit"
        case "cc-by-nc-sa-4.0": return "Non-commercial use, with credit, same license"
        case "cc-by-nc-nd-4.0": return "Redistribute unmodified, non-commercial, with credit"
        default: return entry.name
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path . --filter LicenseGateSelectionTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/LicenseGateSheetView.swift Tests/AnglesiteAppTests/LicenseGateSelectionTests.swift
git commit -m "feat(#999): add LicenseGateSheetView"
```

---

### Task 4: Wire the sheet into `SiteWindow`

**Files:**
- Modify: `Sources/AnglesiteApp/SiteWindow.swift:651` (after the `domainConfigDriftPresented` sheet, before `audit.sheetPresented`)

**Interfaces:**
- Consumes: `DeployModel.licenseGatePresented` (Task 2, as a `Binding` via `$bindableModel.deploy.licenseGatePresented`), `LicenseGateSheetView(model:)` (Task 3).

- [ ] **Step 1: Add the sheet modifier**

In `Sources/AnglesiteApp/SiteWindow.swift`, immediately after the `.sheet(isPresented: $bindableModel.deploy.domainConfigDriftPresented) { ... }` block (ends at line 662), insert:

```swift
        .sheet(isPresented: $bindableModel.deploy.licenseGatePresented) {
            LicenseGateSheetView(model: model.deploy)
                .interactiveDismissDisabled()
        }
```

`.interactiveDismissDisabled()` is applied to the sheet's *content* (inside the closure), not chained after `.sheet(...)` on `SiteWindow` itself — chaining it on the outer view would target whatever context hosts `SiteWindow`'s own presentation (if any), not this specific sheet, and would risk leaking to the other sheets in this same modifier chain (`blockedPresented`, `tokenPromptPresented`, etc.), which are meant to stay dismissible. Scoping it to the presented content is the standard SwiftUI pattern for exactly this "this one sheet can't be swiped away" case.

- [ ] **Step 2: Build the app target**

Run:
```bash
xcodegen generate
scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
```
Expected: build succeeds with no new warnings from `LicenseGateSheetView.swift` or the `SiteWindow.swift` change.

- [ ] **Step 3: Manually verify in the running app**

Launch the built app, open (or create) a site whose `Source/src/data/licensing.json` is absent or has no `licenseChosen: true`, and click Deploy:
- Confirm the license gate sheet appears instead of the deploy running.
- Confirm it cannot be dismissed with Esc or a swipe.
- Click a catalog row (e.g. CC BY 4.0), confirm it highlights, click Continue — confirm the deploy proceeds and `Source/src/data/licensing.json` now has `"licenseChosen": true` and `"default"` set to the CC BY URL.
- Deploy again — confirm the gate no longer appears.

Report the outcome in the task's completion notes; this step cannot be automated in this plan.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteApp/SiteWindow.swift
git commit -m "feat(#999): present the license gate sheet from SiteWindow"
```

---

### Task 5: Full verification and PR

**Files:** none (verification + PR only)

- [ ] **Step 1: Run the full Swift test suite**

Run: `swift test --package-path .`
Expected: PASS, no regressions.

- [ ] **Step 2: Re-run the app build**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: PASS.

- [ ] **Step 3: Re-read `CONTRIBUTING.md` ▸ "Commits and pull requests" before opening the PR**

Confirm: conventional-commit subjects already used in Tasks 1-4 (all ≤72 chars); the PR body will use `.github/PULL_REQUEST_TEMPLATE.md`'s exact headings (Summary, Paired PR check, Test plan); this PR does **not** close #999 — it implements item 1 of 4, with items 2-4 (per-file embedded license metadata) tracked as follow-up work — so use a non-closing reference (`Relates to #999` / `Part of #999`), not `Closes #999` or `Fixes #999`.

- [ ] **Step 4: Push and open the PR**

```bash
git push -u origin 999-first-publish-license-gate
gh pr create --title "feat(#999): first-publish license gate" --body "$(cat <<'EOF'
## Summary
- Blocks a site's first deploy on an explicit content-license choice (including "All rights reserved"), shown as a CC comparison table with an AI-interpretation column.
- Adds `LicensingPolicy.licenseChosen` to distinguish "never asked" from "explicitly chose All rights reserved."
- Part of #999 (item 1 of 4) — per-file embedded license metadata (items 2-4) is tracked separately.

## Paired PR check
No MCP message schema changes. No paired sidecar PR needed.

## Test plan
- [x] `swift test --package-path .` — new `LicensingStoreTests`, `DeployModelTests`, `LicenseGateSelectionTests` cases pass; full suite has no regressions.
- [x] `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build` succeeds.
- [x] Manually verified in the running app: gate blocks first deploy, cannot be dismissed, choosing a license persists it and lets the deploy proceed, and the gate does not reappear on a subsequent deploy.
EOF
)"
```

- [ ] **Step 5: Report the PR URL and next steps**

Confirm the PR URL, and note that #999 items 2-4 (per-file embedded license metadata, attach-time UI, drop-and-inspect UI) remain open for a separate future brainstorming/plan cycle.
