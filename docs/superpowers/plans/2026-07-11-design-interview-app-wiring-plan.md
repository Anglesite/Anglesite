# Design Interview App Wiring (#631) Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the design-interview feature (shipped fully unit-tested in PR #633, but with zero reachable entry points) two working front doors — a GUI sheet on the site window, and a Siri intent that opens the app to it — so at least one, and in fact both, of "GUI" and "Siri" reach a live `DesignInterviewModel` conversation in the running app.

**Architecture:** Follow the exact "fresh model built on demand from `site`" sheet-presentation pattern already used for `CopyEditReportModel`/`SocialPlanModel`/`RepurposeModel` on `SiteWindowModel`, and the exact "request → `WindowRouter` → consume on window resolve" pattern already used by `PreviewSiteIntent`/`OpenSiteIntent`. No new abstractions — this task is entirely "wire the existing pieces together the way sibling features already do."

**Tech Stack:** Swift 6.4 / SwiftUI (macOS 27 target), Swift Testing (`@Suite`/`@Test`/`#expect`), `AppIntents`.

## Global Constraints

- Toolchain: `swift test`/`swift build` must run with `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` — the default CommandLineTools `swift` is too old (< 6.4) and its `swift-package` is broken.
- No new frameworks or third-party dependencies — Apple's own APIs only, matching every existing sheet/intent in this codebase.
- Follow established naming: `canOpen<Feature>` boolean gate, `present<Feature>()` builder, `<feature>Model: <Feature>Model?` state var — exactly as `copyEditModel`/`canOpenCopyEdit`/`presentCopyEdit()` already do.
- **Out of scope (deliberately deferred):** wiring `DesignInterviewTool` into `FoundationModelAssistant.conversationTools(for:includeSpotlight:)` (the chat front door). That factory has no parameter through which a per-conversation, `@MainActor`-isolated `DesignInterviewModel` can flow in today; doing it properly means adding per-conversation state to an `actor` that currently only holds window-lifetime singletons (`themeCatalog`, `session`), which is a real design decision, not a wiring job. Issue #631's acceptance criteria explicitly allows shipping "at least one front door... incrementally" — this plan ships two (GUI + Siri) and Task 6 below files a scoped follow-up for the third, mirroring how #631 itself was split out of PR #633.
- Do **not** touch `Sources/AnglesiteCore/DesignInterviewModel.swift`, `DesignInterviewTool.swift`, `DesignInterviewDraft.swift`, or `DesignInterviewPanel.swift` — every type this plan needs from them already exists with the right signature. This plan only adds call sites.

---

### Task 1: `WindowRouter` — pending design-interview request

**Files:**
- Modify: `Sources/AnglesiteIntents/WindowRouter.swift`
- Test: `Tests/AnglesiteIntentsTests/WindowRouterTests.swift`

**Interfaces:**
- Produces: `WindowRouter.requestDesignInterview(siteID: String)`, `WindowRouter.consumeDesignInterviewRequest(for siteID: String) -> Bool`, `WindowRouter.pendingDesignInterview: Set<String>` (read-only) — consumed by Task 2 (the intent) and Task 4 (`SiteWindowModel`).

- [ ] **Step 1: Write the failing tests**

Add to `Tests/AnglesiteIntentsTests/WindowRouterTests.swift`, inside the `WindowRouterTests` struct:

```swift
    @Test("requestDesignInterview sets the open trigger and records a pending request once")
    func requestDesignInterviewSetsPendingRequest() {
        let router = freshRouter()
        router.requestDesignInterview(siteID: "siteA")
        #expect(router.requested == "siteA")
        #expect(router.consumeDesignInterviewRequest(for: "siteA"))
        #expect(!router.consumeDesignInterviewRequest(for: "siteA"))   // consumed once → false
    }

    @Test("a design-interview request for one site is not consumed by another")
    func designInterviewRequestIsPerSite() {
        let router = freshRouter()
        router.requestDesignInterview(siteID: "siteA")
        #expect(!router.consumeDesignInterviewRequest(for: "siteB"))
        #expect(router.consumeDesignInterviewRequest(for: "siteA"))
    }
```

Also update `freshRouter()` in the same file to reset the new state, so these tests (and every other test in the suite) start from a clean slate:

```swift
    private func freshRouter() -> WindowRouter {
        let router = WindowRouter.shared
        router.requested = nil
        for id in ["siteA", "siteB", "siteC"] {
            _ = router.consumeNavigation(for: id)
            _ = router.consumeDesignInterviewRequest(for: id)
        }
        return router
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcrun swift test --filter WindowRouterTests
```
Expected: build FAILURE — `value of type 'WindowRouter' has no member 'requestDesignInterview'` (and `consumeDesignInterviewRequest`).

- [ ] **Step 3: Implement**

In `Sources/AnglesiteIntents/WindowRouter.swift`, add after `consumeNavigation(for:)`:

```swift
    /// Pending "open the design-interview sheet" request per site, set by
    /// `StartDesignInterviewIntent` and consumed once by that site's window — mirrors
    /// `pendingNavigation`'s set-then-consume shape. Kept as its own `Set` (not folded into
    /// `pendingNavigation`) because it targets a different surface (the design-interview sheet,
    /// not the preview's page route) and carries no route value of its own.
    public private(set) var pendingDesignInterview: Set<String> = []

    /// Requests that `siteID`'s window open (or focus), then present the design-interview sheet.
    public func requestDesignInterview(siteID: String) {
        pendingDesignInterview.insert(siteID)
        requested = siteID
    }

    /// Take (and clear) the pending design-interview request for `siteID`. `true` when one was
    /// pending, `false` otherwise.
    public func consumeDesignInterviewRequest(for siteID: String) -> Bool {
        pendingDesignInterview.remove(siteID) != nil
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```sh
xcrun swift test --filter WindowRouterTests
```
Expected: PASS (all tests in the suite, including the pre-existing navigation ones).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteIntents/WindowRouter.swift Tests/AnglesiteIntentsTests/WindowRouterTests.swift
git commit -m "feat(intents): add pending design-interview request to WindowRouter"
```

---

### Task 2: Wire `StartDesignInterviewIntent.perform()` to the router

**Files:**
- Modify: `Sources/AnglesiteIntents/DesignInterviewIntents.swift`
- Create: `Tests/AnglesiteIntentsTests/DesignInterviewIntentsTests.swift`

**Interfaces:**
- Consumes: `WindowRouter.shared.requestDesignInterview(siteID:)` and `.consumeDesignInterviewRequest(for:)` (Task 1); `AppIntentsTests.aSite` (`Tests/AnglesiteIntentsTests/ContentEntitiesTests.swift`); `TestStore.site(id:name:)` and `SiteEntity.init(_:)` (existing test/production helpers).
- Produces: `StartDesignInterviewIntent.perform()` now has an observable side effect other tasks don't depend on directly.

- [ ] **Step 1: Write the failing test**

Create `Tests/AnglesiteIntentsTests/DesignInterviewIntentsTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore
@testable import AnglesiteIntents

extension AppIntentsTests {
    @Suite("DesignInterviewIntents")
    @MainActor
    struct DesignInterviewIntentsTests {
        private func entity(_ siteID: String = AppIntentsTests.aSite, name: String = "Alpha") -> SiteEntity {
            SiteEntity(TestStore.site(id: siteID, name: name))
        }

        @Test("StartDesignInterviewIntent opens the site window and records a pending design-interview request")
        func startRequestsWindowAndInterview() async throws {
            WindowRouter.shared.requested = nil
            _ = WindowRouter.shared.consumeDesignInterviewRequest(for: AppIntentsTests.aSite)

            var intent = StartDesignInterviewIntent()
            intent.site = entity()
            _ = try await intent.perform()

            #expect(WindowRouter.shared.requested == AppIntentsTests.aSite)
            #expect(WindowRouter.shared.consumeDesignInterviewRequest(for: AppIntentsTests.aSite))
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcrun swift test --filter DesignInterviewIntentsTests
```
Expected: FAIL — `WindowRouter.shared.requested` is `nil` (the current `perform()` never calls `requestDesignInterview`).

- [ ] **Step 3: Implement**

Replace the whole doc comment + `perform()` in `Sources/AnglesiteIntents/DesignInterviewIntents.swift`:

```swift
/// Opens (or focuses) `site`'s window and requests its design-interview sheet
/// (`SiteWindowModel.presentDesignInterview()`, consumed via
/// `WindowRouter.consumeDesignInterviewRequest(for:)`) — the same request/consume shape
/// `PreviewSiteIntent` uses for its page-route navigation. The interview itself runs in the GUI
/// panel, not as a multi-turn App Intent — Siri's role is only the entry point.
public struct StartDesignInterviewIntent: AppIntent {
    public static let title: LocalizedStringResource = "Start Design Interview"
    public static let description = IntentDescription("Start a conversation to design your site's look and feel.")
    public static let openAppWhenRun = true

    @Parameter(title: "Site") public var site: SiteEntity

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Start a design interview for \(\.$site)")
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        WindowRouter.shared.requestDesignInterview(siteID: site.id)
        return .result(dialog: IntentDialog(stringLiteral: "Let's design \(site.displayName). Opening chat…"))
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```sh
xcrun swift test --filter DesignInterviewIntentsTests
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteIntents/DesignInterviewIntents.swift Tests/AnglesiteIntentsTests/DesignInterviewIntentsTests.swift
git commit -m "feat(intents): route StartDesignInterviewIntent through WindowRouter"
```

---

### Task 3: Register the operation descriptor + Siri phrase

**Files:**
- Modify: `Sources/AnglesiteIntents/OperationDescriptor.swift`
- Modify: `Sources/AnglesiteIntents/AnglesiteShortcuts.swift`
- Modify: `Tests/AnglesiteIntentsTests/OperationDescriptorTests.swift`
- Modify: `Tests/AnglesiteIntentsTests/SmokeMatrixTests.swift`

**Interfaces:**
- Consumes: `StartDesignInterviewIntent` (Task 2) — must exist and compile, which it already does.
- Produces: nothing new consumed by later tasks — this task is pure registry/metadata sync, required because three existing tests cross-check `AnglesiteOperations.all`, `AnglesiteShortcuts.appShortcuts`/`.phraseExposedIntentNames`, and `SmokeMatrixTests.workflows` for 1:1 correspondence. Skipping this task would not fail to compile, but would leave the Siri phrase unregistered and, if added without the matching registry/test entries, would break `OperationDescriptorTests.declaredFields`, `SmokeMatrixTests.everyOperationIsInTheMatrix`, and `OperationDescriptorTests.anchorSync`.

- [ ] **Step 1: Write the failing tests**

In `Tests/AnglesiteIntentsTests/OperationDescriptorTests.swift`, add one line to the `expected` dictionary inside `declaredFields()` (anywhere in the dict; here placed right after `"preview-site"` for locality with its closest analog):

```swift
                "preview-site": .init(sideEffect: .readOnly, requiresConfirmation: false, isCancellable: false, resultShape: .none),
                "start-design-interview": .init(sideEffect: .readOnly, requiresConfirmation: false, isCancellable: false, resultShape: .none),
```

In `Tests/AnglesiteIntentsTests/SmokeMatrixTests.swift`, add one line to the `workflows` array (right after the "Preview a page" row):

```swift
            Workflow(label: "Preview a page", operationID: "preview-site", sideEffect: .readOnly, confirmsAtRuntime: false),
            Workflow(label: "Start a design interview", operationID: "start-design-interview", sideEffect: .readOnly, confirmsAtRuntime: false),
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcrun swift test --filter OperationDescriptorTests
xcrun swift test --filter SmokeMatrixTests
```
Expected: `OperationDescriptorTests.declaredFields` FAILS (`expected.count == AnglesiteOperations.all.count` — 19 vs 18). `SmokeMatrixTests.everyWorkflowHasADescriptor` FAILS (`start-design-interview` isn't a shipped operation yet), and `SmokeMatrixTests.everyOperationIsInTheMatrix` also FAILS (`documented` now has one more id than `shipped`). All three are expected to fail until Step 3.

- [ ] **Step 3: Implement**

In `Sources/AnglesiteIntents/OperationDescriptor.swift`, add to `AnglesiteOperations.all` (right after the `"preview-site"` entry):

```swift
        OperationDescriptor(
            operationID: "preview-site", displayName: "Preview Site",
            intentTypeName: "PreviewSiteIntent", sideEffect: .readOnly,
            requiresConfirmation: false, isCancellable: false,
            resultShape: .none
        ),
        OperationDescriptor(
            // `.readOnly`: like `preview-site`, this only opens/focuses the app to a conversation
            // surface — it persists nothing itself. The interview's eventual `confirmAndApply()`
            // write happens later, inside the GUI panel, not as part of this intent.
            operationID: "start-design-interview", displayName: "Start Design Interview",
            intentTypeName: "StartDesignInterviewIntent", sideEffect: .readOnly,
            requiresConfirmation: false, isCancellable: false,
            resultShape: .none
        ),
```

In `Sources/AnglesiteIntents/AnglesiteShortcuts.swift`, add a 10th `AppShortcut` (right after the `EditContentIntent` one, before the `NOTE:` comment about the 10-phrase budget):

```swift
        AppShortcut(
            intent: EditContentIntent(),
            phrases: [
                "Edit this with \(.applicationName)",
                "Change this with \(.applicationName)",
            ],
            shortTitle: "Edit Content",
            systemImageName: "pencil"
        )
        AppShortcut(
            intent: StartDesignInterviewIntent(),
            phrases: [
                "Redesign my site with \(.applicationName)",
                "Design my site with \(.applicationName)",
            ],
            shortTitle: "Design Interview",
            systemImageName: "paintpalette"
        )
        // NOTE: the Bucket 3 integration intents ...
```

And update the comment + `phraseExposedIntentNames` set right below it:

```swift
        // NOTE: the Bucket 3 integration intents (AddBookingIntent / AddDonationsIntent /
        // AddGiscusIntent) are deliberately NOT registered as `AppShortcut`s. `AppShortcutsProvider`
        // allows at most 10 curated phrases and the ten above already fill the budget. The
        // integration intents remain fully first-class — they keep their `OperationDescriptor`s,
        // are invocable from the Shortcuts app, the FM chat tool (`SetupIntegrationTool`), and the
        // GUI "Add Integration…" wizard. Only the zero-setup Siri phrase is omitted. Reinstate a
        // phrase (and drop a less voice-natural one to stay within 10) if a future iteration wants
        // Siri-first integration setup. See PR discussion.
    }
}

extension AnglesiteShortcuts {
    /// Intent type names that have a curated Siri phrase in `appShortcuts` above. Kept beside the
    /// phrase definitions so adding/removing a phrase naturally updates this — it is the anchor for
    /// operation-descriptor coverage (`OperationDescriptorTests`). Apple's `appShortcuts` is a
    /// type-erased `[AppShortcut]` with no public way to read back the intent type, so this hand
    /// list is required; a sync-guard test asserts its size matches `appShortcuts.count`.
    static let phraseExposedIntentNames: Set<String> = [
        "DeploySiteIntent",
        "BackupSiteIntent",
        "AuditSiteIntent",
        "SearchContentIntent",
        "SiteStatusIntent",
        "AddPageIntent",
        "AddPostIntent",
        "PreviewSiteIntent",
        "EditContentIntent",
        "StartDesignInterviewIntent",
    ]
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```sh
xcrun swift test --filter OperationDescriptorTests
xcrun swift test --filter SmokeMatrixTests
```
Expected: PASS for both suites (all tests, not just the two touched above — `anchorSync`, `coverage`, `phraseSurfaceIsConsistent`, `phraseExposedIntentsAreDocumented` all cross-check the same three lists and must stay green).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteIntents/OperationDescriptor.swift Sources/AnglesiteIntents/AnglesiteShortcuts.swift \
    Tests/AnglesiteIntentsTests/OperationDescriptorTests.swift Tests/AnglesiteIntentsTests/SmokeMatrixTests.swift
git commit -m "feat(intents): register StartDesignInterviewIntent as an operation + Siri phrase"
```

---

### Task 4: `SiteWindowModel` — present the design-interview sheet

**Files:**
- Modify: `Sources/AnglesiteApp/SiteWindowModel.swift`
- Test: `Tests/AnglesiteAppTests/SiteWindowModelTests.swift`

**Interfaces:**
- Consumes: `WindowRouter.requestDesignInterview(siteID:)`/`.consumeDesignInterviewRequest(for:)` (Task 1); `DesignInterviewModel.init(businessType:assistant:package:siteID:)`, `SiteBusinessType.read(sourceDirectory:) -> String?`, `FoundationModelAssistant.init(tier:)`, `AnglesitePackage.init(url:)` (all pre-existing in `AnglesiteCore`/`AnglesiteSiteModel`, re-exported by `AnglesiteCore`).
- Produces: `SiteWindowModel.designInterviewModel: DesignInterviewModel?`, `.canOpenDesignInterview: Bool`, `.presentDesignInterview()`, `.applyPendingDesignInterviewRequest(for siteID: String)` — consumed by Task 5 (`SiteWindow.swift`) and Task 6 (`SiteMenuCommands.swift`).

- [ ] **Step 1: Write the failing tests**

Add to `Tests/AnglesiteAppTests/SiteWindowModelTests.swift`, as a new extension at the end of the file:

```swift
extension SiteWindowModelTests {
    private func siteWithNonexistentPackage(id: String = "site-a") -> SiteStore.Site {
        SiteStore.Site(
            id: id, name: "Test",
            packageURL: URL(fileURLWithPath: "/tmp/site-window-model-\(UUID().uuidString).anglesite"),
            isValid: true, missingSentinels: [], lastSeen: Date(), bookmarkData: nil
        )
    }

    @Test("presentDesignInterview builds a fresh model from the open site, defaulting business type to empty when the site has no .site-config")
    func presentDesignInterviewBuildsModel() {
        let model = makeModel()
        model.site = siteWithNonexistentPackage()

        model.presentDesignInterview()

        #expect(model.designInterviewModel != nil)
        #expect(model.designInterviewModel?.draft.businessType == "")
    }

    @Test("presentDesignInterview no-ops when there is no open site")
    func presentDesignInterviewNoSiteIsNoOp() {
        let model = makeModel()

        model.presentDesignInterview()

        #expect(model.designInterviewModel == nil)
    }

    @Test("presentDesignInterview doesn't replace an already-presented model")
    func presentDesignInterviewDoesNotReplaceExisting() {
        let model = makeModel()
        model.site = siteWithNonexistentPackage()
        model.presentDesignInterview()
        let first = model.designInterviewModel

        model.presentDesignInterview()

        #expect(model.designInterviewModel === first)
    }

    @Test("applyPendingDesignInterviewRequest presents the sheet when a request is pending for this site")
    func applyPendingDesignInterviewRequestConsumesPendingRequest() {
        let model = makeModel()
        model.site = siteWithNonexistentPackage()
        model.router.requestDesignInterview(siteID: "site-a")

        model.applyPendingDesignInterviewRequest(for: "site-a")

        #expect(model.designInterviewModel != nil)
    }

    @Test("applyPendingDesignInterviewRequest no-ops when nothing is pending for this site")
    func applyPendingDesignInterviewRequestNoPendingRequestIsNoOp() {
        let model = makeModel()
        model.site = siteWithNonexistentPackage()
        _ = model.router.consumeDesignInterviewRequest(for: "site-a")   // defensive: clear any stale request

        model.applyPendingDesignInterviewRequest(for: "site-a")

        #expect(model.designInterviewModel == nil)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcrun swift test --filter SiteWindowModelTests
```
Expected: build FAILURE — `value of type 'SiteWindowModel' has no member 'presentDesignInterview'` (and `designInterviewModel`, `applyPendingDesignInterviewRequest`).

- [ ] **Step 3: Implement**

In `Sources/AnglesiteApp/SiteWindowModel.swift`, add the state var right after `var repurposeModel: RepurposeModel?`:

```swift
    /// Non-nil ⟺ the Design Interview sheet is presented (`.sheet(item:)`), same fresh-
    /// construction-from-`site` pattern as `copyEditModel`/`socialPlanModel`/`repurposeModel` (#631).
    var designInterviewModel: DesignInterviewModel?
```

Add `canOpenDesignInterview` right after `var canOpenSocialPlan: Bool { site != nil }`:

```swift
    var canOpenDesignInterview: Bool { site != nil }
```

Add `presentDesignInterview()` right after `presentSocialPlan()`:

```swift
    /// Presents the Design Interview sheet (#631), same fresh-construction-from-`site` pattern as
    /// `presentCopyEdit`/`presentSocialPlan`. Builds a standalone `FoundationModelAssistant`
    /// rather than reusing the site's shared `chat` assistant — the interview is its own
    /// independent conversation, not a turn appended to the main chat's session/transcript.
    func presentDesignInterview() {
        guard designInterviewModel == nil, let site else { return }
        designInterviewModel = DesignInterviewModel(
            businessType: SiteBusinessType.read(sourceDirectory: site.sourceDirectory) ?? "",
            assistant: FoundationModelAssistant(tier: .onDevice),
            package: AnglesitePackage(url: site.packageURL),
            siteID: site.id
        )
    }
```

Add `applyPendingDesignInterviewRequest(for:)` right after `applyPendingNavigation(for:)`:

```swift
    /// Apply (and clear) any pending `StartDesignInterviewIntent` request for `siteID`: presents
    /// the design-interview sheet if it isn't already up. Same dual cold/warm calling convention
    /// as `applyPendingNavigation` — called from `loadAndStart` (cold-open) and from
    /// `.onChange(of: router.pendingDesignInterview)` (an already-open window).
    @MainActor
    func applyPendingDesignInterviewRequest(for siteID: String) {
        guard router.consumeDesignInterviewRequest(for: siteID) else { return }
        presentDesignInterview()
    }
```

Finally, wire the cold-open path into `loadAndStart`: find `applyPendingNavigation(for: resolved.id)` and add the new call right after it:

```swift
        applyPendingNavigation(for: resolved.id)
        applyPendingDesignInterviewRequest(for: resolved.id)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```sh
xcrun swift test --filter SiteWindowModelTests
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/SiteWindowModel.swift Tests/AnglesiteAppTests/SiteWindowModelTests.swift
git commit -m "feat(app): present the design-interview sheet from SiteWindowModel"
```

---

### Task 5: `SiteWindow` — sheet presentation + warm-path routing

**Files:**
- Modify: `Sources/AnglesiteApp/SiteWindow.swift`

**Interfaces:**
- Consumes: `SiteWindowModel.designInterviewModel`/`.applyPendingDesignInterviewRequest(for:)` (Task 4); `DesignInterviewPanel` (pre-existing, `Sources/AnglesiteApp/DesignInterviewPanel.swift`, unchanged).

No automated test: this task is pure SwiftUI view wiring with no existing test harness in this codebase (the same gap noted for the theme-apply wizard's own sheet and tracked separately, e.g. #491's "manual GUI smoke... still owed"). Verify manually per Step 3 below.

- [ ] **Step 1: Add the sheet**

In `Sources/AnglesiteApp/SiteWindow.swift`, find:

```swift
        .sheet(item: $bindableModel.repurposeModel) { repurposeModel in
            RepurposeView(model: repurposeModel)
        }
        .sheet(item: $bindableModel.integrationWizardModel) { wizardModel in
```

Replace with:

```swift
        .sheet(item: $bindableModel.repurposeModel) { repurposeModel in
            RepurposeView(model: repurposeModel)
        }
        .sheet(item: $bindableModel.designInterviewModel) { interviewModel in
            DesignInterviewPanel(model: interviewModel)
                .frame(minWidth: 640, minHeight: 420)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { model.designInterviewModel = nil }
                    }
                }
        }
        .sheet(item: $bindableModel.integrationWizardModel) { wizardModel in
```

- [ ] **Step 2: Add the warm-path `.onChange`**

Find:

```swift
        // Warm path: an already-open window reacts to a new `PreviewSiteIntent` request (the
        // cold path is `applyPendingNavigation` in `SiteWindowModel.loadAndStart`).
        .onChange(of: model.router.pendingNavigation) { _, _ in
            if let id = model.site?.id { model.applyPendingNavigation(for: id) }
        }
```

Replace with:

```swift
        // Warm path: an already-open window reacts to a new `PreviewSiteIntent` request (the
        // cold path is `applyPendingNavigation` in `SiteWindowModel.loadAndStart`).
        .onChange(of: model.router.pendingNavigation) { _, _ in
            if let id = model.site?.id { model.applyPendingNavigation(for: id) }
        }
        // Same warm/cold split as above, for `StartDesignInterviewIntent` requests (#631).
        .onChange(of: model.router.pendingDesignInterview) { _, _ in
            if let id = model.site?.id { model.applyPendingDesignInterviewRequest(for: id) }
        }
```

- [ ] **Step 3: Build and manually verify**

Run:
```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcodegen generate
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
```
Expected: `BUILD SUCCEEDED`.

Then, with a site open in the running app: Site ▸ Design Interview… (added in Task 6) should present the sheet with an empty transcript, a message field, axis sliders, and a "Done" button that dismisses it. This manual pass is the acceptance check for the GUI front door — note it as done (or as a follow-up manual-smoke item, matching #491's precedent) in the PR description.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteApp/SiteWindow.swift
git commit -m "feat(app): present the design-interview sheet and route Siri requests to it"
```

---

### Task 6: `SiteMenuCommands` — menu entry point

**Files:**
- Modify: `Sources/AnglesiteApp/SiteMenuCommands.swift`

**Interfaces:**
- Consumes: `SiteWindowModel.presentDesignInterview()`/`.canOpenDesignInterview` (Task 4).

No automated test: sibling menu items (`Review Copy…`, `Social Media Plan…`) have none either — `SiteMenuCommands` is plain `Commands` wiring with no test target coverage in this codebase.

- [ ] **Step 1: Add the menu item**

In `Sources/AnglesiteApp/SiteMenuCommands.swift`, find:

```swift
            Button("Social Media Plan…") { model?.presentSocialPlan() }
                .disabled(model?.canOpenSocialPlan != true)
```

Replace with:

```swift
            Button("Social Media Plan…") { model?.presentSocialPlan() }
                .disabled(model?.canOpenSocialPlan != true)

            Button("Design Interview…") { model?.presentDesignInterview() }
                .disabled(model?.canOpenDesignInterview != true)
```

- [ ] **Step 2: Build**

Run:
```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Manually verify**

With a site open: Site menu ▸ "Design Interview…" is enabled and opens the same sheet as Task 5's manual check.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteApp/SiteMenuCommands.swift
git commit -m "feat(app): add Site ▸ Design Interview… menu item"
```

---

### Task 7: Whole-branch verification + follow-up issue for the chat tool

**Files:** none (verification + bookkeeping only).

- [ ] **Step 1: Run the full test suite**

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcrun swift test --package-path .
```
Expected: PASS, no regressions.

- [ ] **Step 2: Full app build**

```sh
xcodegen generate
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: File the deferred chat-tool follow-up**

Open a new issue (title suggestion: "Wire DesignInterviewTool into FoundationModelAssistant's per-conversation chat tools"), referencing #631 and this plan, describing the actor-isolation gap this plan deliberately left alone: `conversationTools(for:includeSpotlight:)` has no parameter for a per-conversation, `@MainActor`-isolated `DesignInterviewModel`, and `FoundationModelAssistant` (a plain, non-`MainActor` `actor`) would need new stored per-conversation state (plus a decision about session lifetime — one interview per window? per explicit "start new interview" trigger?) to host it safely, mirroring the design work #631 itself required before landing. Do this with `gh issue create`, then close #631 referencing the PR(s) from Tasks 1–6 and the new follow-up issue.

- [ ] **Step 4: No commit** — this task only verifies and files a follow-up; nothing to add to git.
