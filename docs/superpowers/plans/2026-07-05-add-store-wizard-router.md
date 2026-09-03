# Add Store Wizard Router Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a deterministic "Add a Store" router — reachable from the GUI integration wizard and from Siri — that asks 1-2 questions about what the owner is selling and routes into the existing `buyButton`/`donations`/`lemonSqueezy`/`snipcart`/`shopifyBuyButton`/`paddle` wizard flows, per #462.

**Architecture:** A pure routing function in `AnglesiteCore` (`AddStoreRouter`) computes an `IntegrationID` + optional preset provider from the answers. `IntegrationWizardModel` gains one method to jump straight into an existing integration's flow from a resolved route. The GUI adds an intake sheet in front of the existing picker. `AnglesiteIntents` adds a Siri-reachable `AddStoreIntent` that asks the same questions via `AppEnum` parameters, then reuses the existing `SetupIntegrationTool`-style free-form `config` string for whatever fields the resolved integration still needs.

**Tech Stack:** Swift 6.4 / Xcode 27, SwiftUI, AppIntents, Swift Testing (`@Test`/`@Suite`/`#expect`).

## Global Constraints

- Build/test with the Xcode 27 toolchain, not the default CommandLineTools one: `export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` before any `swift build`/`swift test` command.
- No new `IntegrationID`, `IntegrationDescriptor`, `Condition`, or `Operation` case — this feature routes to integrations that already exist in `IntegrationCatalog`.
- Follow the existing per-integration-intent pattern in `Sources/AnglesiteIntents/IntegrationIntents.swift` (typed `@Parameter`s, `@Dependency private var ops`, a `confirmAndApplyForTesting()` test seam) rather than inventing a new shape.
- Do **not** register `AddStoreIntent` in `AnglesiteShortcuts.appShortcuts` — that provider is capped at 10 curated phrases and is already full (see the `NOTE` comment above `EditContentIntent`'s shortcut in `AnglesiteShortcuts.swift`). The intent is still fully Siri/Shortcuts-invocable by name; it just has no curated phrase, exactly like `AddBookingIntent`/`AddDonationsIntent`/`AddGiscusIntent`.
- Swift Testing, not XCTest, for all new tests (matches every file touched in this plan).

---

### Task 1: `AddStoreRouter` — pure routing logic

**Files:**
- Create: `Sources/AnglesiteCore/AddStoreRouter.swift`
- Test: `Tests/AnglesiteCoreTests/AddStoreRouterTests.swift`

**Interfaces:**
- Produces: `public enum StoreCategory: String, CaseIterable, Sendable { case service, donations, digitalDownloads, physicalGoods, software }`
- Produces: `public enum DigitalPreference: String, CaseIterable, Sendable { case polar, lemonSqueezy }`
- Produces: `public enum CatalogSize: String, CaseIterable, Sendable { case few, catalog }`
- Produces: `public enum AddStoreRouter { public struct Route: Sendable, Equatable { public let integrationID: IntegrationID; public let presetProvider: String? }; public static func route(category: StoreCategory, digitalPreference: DigitalPreference? = nil, catalogSize: CatalogSize? = nil) -> Route }`
- Consumes: `IntegrationID` from `Sources/AnglesiteCore/IntegrationDescriptor.swift` (already has `.buyButton`, `.donations`, `.lemonSqueezy`, `.snipcart`, `.shopifyBuyButton`, `.paddle`).

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/AddStoreRouterTests.swift`:

```swift
// Tests/AnglesiteCoreTests/AddStoreRouterTests.swift
import Testing
@testable import AnglesiteCore

@Suite struct AddStoreRouterTests {
    @Test func serviceRoutesToStripeBuyButton() {
        let route = AddStoreRouter.route(category: .service)
        #expect(route == AddStoreRouter.Route(integrationID: .buyButton, presetProvider: "stripe"))
    }

    @Test func donationsRoutesToDonationsDescriptor() {
        let route = AddStoreRouter.route(category: .donations)
        #expect(route == AddStoreRouter.Route(integrationID: .donations, presetProvider: nil))
    }

    @Test func digitalDownloadsDefaultsToPolar() {
        let route = AddStoreRouter.route(category: .digitalDownloads)
        #expect(route == AddStoreRouter.Route(integrationID: .buyButton, presetProvider: "polar"))
    }

    @Test func digitalDownloadsExplicitPolar() {
        let route = AddStoreRouter.route(category: .digitalDownloads, digitalPreference: .polar)
        #expect(route == AddStoreRouter.Route(integrationID: .buyButton, presetProvider: "polar"))
    }

    @Test func digitalDownloadsLemonSqueezy() {
        let route = AddStoreRouter.route(category: .digitalDownloads, digitalPreference: .lemonSqueezy)
        #expect(route == AddStoreRouter.Route(integrationID: .lemonSqueezy, presetProvider: nil))
    }

    @Test func physicalGoodsDefaultsToSnipcart() {
        let route = AddStoreRouter.route(category: .physicalGoods)
        #expect(route == AddStoreRouter.Route(integrationID: .snipcart, presetProvider: nil))
    }

    @Test func physicalGoodsFewIsSnipcart() {
        let route = AddStoreRouter.route(category: .physicalGoods, catalogSize: .few)
        #expect(route == AddStoreRouter.Route(integrationID: .snipcart, presetProvider: nil))
    }

    @Test func physicalGoodsCatalogIsShopify() {
        let route = AddStoreRouter.route(category: .physicalGoods, catalogSize: .catalog)
        #expect(route == AddStoreRouter.Route(integrationID: .shopifyBuyButton, presetProvider: nil))
    }

    @Test func softwareRoutesToPaddle() {
        let route = AddStoreRouter.route(category: .software)
        #expect(route == AddStoreRouter.Route(integrationID: .paddle, presetProvider: nil))
    }

    @Test func followUpParametersIgnoredOutsideTheirCategory() {
        // catalogSize only matters for .physicalGoods — passing it alongside .service must not
        // change the result.
        let route = AddStoreRouter.route(category: .service, catalogSize: .catalog)
        #expect(route == AddStoreRouter.Route(integrationID: .buyButton, presetProvider: "stripe"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail (type doesn't exist yet)**

Run:
```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcrun swift test --filter AddStoreRouterTests
```
Expected: FAIL — `error: cannot find 'AddStoreRouter' in scope` (or similar, since the type doesn't exist yet).

- [ ] **Step 3: Implement `AddStoreRouter`**

Create `Sources/AnglesiteCore/AddStoreRouter.swift`:

```swift
// Sources/AnglesiteCore/AddStoreRouter.swift

/// What the owner is selling — mirrors the plugin's `add-store` skill intake question.
public enum StoreCategory: String, CaseIterable, Sendable {
    case service, donations, digitalDownloads, physicalGoods, software
}

/// Digital-download platform preference — only relevant when `category == .digitalDownloads`.
public enum DigitalPreference: String, CaseIterable, Sendable {
    case polar, lemonSqueezy
}

/// Physical-goods catalog size — only relevant when `category == .physicalGoods`.
public enum CatalogSize: String, CaseIterable, Sendable {
    case few, catalog
}

/// Deterministic routing for the "Add a Store" wizard entry point: given what the owner is
/// selling (and, where relevant, one follow-up answer), decides which existing
/// `IntegrationDescriptor` to open and with which provider preset. Mirrors the plugin's
/// `add-store` skill routing table, minus the revenue-tracking webhook step (deferred — see
/// docs/superpowers/specs/2026-07-05-add-store-wizard-router-design.md).
public enum AddStoreRouter {
    public struct Route: Sendable, Equatable {
        public let integrationID: IntegrationID
        public let presetProvider: String?
        public init(integrationID: IntegrationID, presetProvider: String?) {
            self.integrationID = integrationID
            self.presetProvider = presetProvider
        }
    }

    public static func route(
        category: StoreCategory,
        digitalPreference: DigitalPreference? = nil,
        catalogSize: CatalogSize? = nil
    ) -> Route {
        switch category {
        case .service:
            return Route(integrationID: .buyButton, presetProvider: "stripe")
        case .donations:
            return Route(integrationID: .donations, presetProvider: nil)
        case .digitalDownloads:
            switch digitalPreference {
            case .lemonSqueezy:
                return Route(integrationID: .lemonSqueezy, presetProvider: nil)
            case .polar, .none:
                return Route(integrationID: .buyButton, presetProvider: "polar")
            }
        case .physicalGoods:
            switch catalogSize {
            case .catalog:
                return Route(integrationID: .shopifyBuyButton, presetProvider: nil)
            case .few, .none:
                return Route(integrationID: .snipcart, presetProvider: nil)
            }
        case .software:
            return Route(integrationID: .paddle, presetProvider: nil)
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```sh
xcrun swift test --filter AddStoreRouterTests
```
Expected: PASS (all 10 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/AddStoreRouter.swift Tests/AnglesiteCoreTests/AddStoreRouterTests.swift
git commit -m "feat(#462): add AddStoreRouter deterministic routing"
```

---

### Task 2: `IntegrationWizardModel.startFromRouter`

**Files:**
- Modify: `Sources/AnglesiteCore/IntegrationWizardModel.swift`
- Test: `Tests/AnglesiteCoreTests/IntegrationWizardModelTests.swift`

**Interfaces:**
- Consumes: `AddStoreRouter.Route` from Task 1.
- Produces: `public func startFromRouter(_ route: AddStoreRouter.Route)` on `IntegrationWizardModel`. Sets `selectedID`, seeds `answers["provider"]` when the route has a preset, and jumps `step` to `.fields` (when a provider is resolved or the target has none) or `.pickProvider` (when the target has providers but none is preset — e.g. `.donations`).

- [ ] **Step 1: Write the failing tests**

Add to `Tests/AnglesiteCoreTests/IntegrationWizardModelTests.swift` (inside the existing `IntegrationWizardModelTests` suite, alongside the other `@Test` methods):

```swift
    @Test func startFromRouterWithPresetProviderJumpsToFields() {
        let m = IntegrationWizardModel(service: FakeService(), siteID: "s")
        m.startFromRouter(AddStoreRouter.Route(integrationID: .buyButton, presetProvider: "stripe"))
        #expect(m.selectedID == .buyButton)
        #expect(m.answers["provider"] == "stripe")
        #expect(m.step == .fields)
    }

    @Test func startFromRouterWithNoProvidersJumpsToFields() {
        let m = IntegrationWizardModel(service: FakeService(), siteID: "s")
        m.startFromRouter(AddStoreRouter.Route(integrationID: .snipcart, presetProvider: nil))
        #expect(m.selectedID == .snipcart)
        #expect(m.step == .fields)
    }

    @Test func startFromRouterWithUnresolvedProviderGoesToPickProvider() {
        let m = IntegrationWizardModel(service: FakeService(), siteID: "s")
        m.startFromRouter(AddStoreRouter.Route(integrationID: .donations, presetProvider: nil))
        #expect(m.selectedID == .donations)
        #expect(m.answers["provider"] == nil)
        #expect(m.step == .pickProvider)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```sh
xcrun swift test --filter IntegrationWizardModelTests
```
Expected: FAIL — `value of type 'IntegrationWizardModel' has no member 'startFromRouter'`.

- [ ] **Step 3: Implement `startFromRouter`**

In `Sources/AnglesiteCore/IntegrationWizardModel.swift`, add this method to the `IntegrationWizardModel` class (near `back()`, before `apply()`):

```swift
    /// Entry point for the "Add a Store" router: jumps straight to `.fields` (or `.pickProvider`
    /// if the router didn't resolve a provider, e.g. `.donations`) instead of going through
    /// `.pickIntegration`/`.pickProvider` in order — the router already answered those questions.
    public func startFromRouter(_ route: AddStoreRouter.Route) {
        selectedID = route.integrationID
        if let provider = route.presetProvider {
            answers["provider"] = provider
        }
        step = (descriptor?.providers.isEmpty == true || route.presetProvider != nil) ? .fields : .pickProvider
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```sh
xcrun swift test --filter IntegrationWizardModelTests
```
Expected: PASS (all tests in the suite, including the 3 new ones).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/IntegrationWizardModel.swift Tests/AnglesiteCoreTests/IntegrationWizardModelTests.swift
git commit -m "feat(#462): IntegrationWizardModel.startFromRouter for the add-store entry point"
```

---

### Task 3: GUI — "Add a Store" entry point + intake sheet

**Files:**
- Create: `Sources/AnglesiteApp/AddStoreIntakeView.swift`
- Modify: `Sources/AnglesiteApp/IntegrationWizard.swift`

**Interfaces:**
- Consumes: `AddStoreRouter`, `StoreCategory`, `DigitalPreference`, `CatalogSize` (Task 1), `IntegrationWizardModel.startFromRouter(_:)` (Task 2).
- Produces: `struct AddStoreIntakeView: View` with `init(onRoute: @escaping (AddStoreRouter.Route) -> Void)`.

No new unit tests in this task — SwiftUI view bodies aren't unit-tested in this codebase (verified: no XCUITest target exists); Task 5 verifies this manually in the running app.

- [ ] **Step 1: Create the intake view**

Create `Sources/AnglesiteApp/AddStoreIntakeView.swift`:

```swift
// Sources/AnglesiteApp/AddStoreIntakeView.swift
import SwiftUI
import AnglesiteCore

/// Short intake for the "Add a Store" router: what the owner is selling, plus the one follow-up
/// question the plugin's `add-store` skill asks for that category. Calls `onRoute` with the
/// resolved `AddStoreRouter.Route`, then the caller dismisses this sheet and hands the route to
/// `IntegrationWizardModel.startFromRouter(_:)`.
struct AddStoreIntakeView: View {
    let onRoute: (AddStoreRouter.Route) -> Void

    @State private var category: StoreCategory = .service
    @State private var digitalPreference: DigitalPreference = .polar
    @State private var catalogSize: CatalogSize = .few
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("What are you selling?", selection: $category) {
                    Text("A service or one-off").tag(StoreCategory.service)
                    Text("Donations or fundraising").tag(StoreCategory.donations)
                    Text("Digital downloads").tag(StoreCategory.digitalDownloads)
                    Text("Physical goods").tag(StoreCategory.physicalGoods)
                    Text("Software or SaaS").tag(StoreCategory.software)
                }
                if category == .digitalDownloads {
                    Picker("Which platform?", selection: $digitalPreference) {
                        Text("Polar").tag(DigitalPreference.polar)
                        Text("Lemon Squeezy").tag(DigitalPreference.lemonSqueezy)
                    }
                }
                if category == .physicalGoods {
                    Picker("How many products?", selection: $catalogSize) {
                        Text("Just a few").tag(CatalogSize.few)
                        Text("A full, growing catalog").tag(CatalogSize.catalog)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Continue") {
                    onRoute(AddStoreRouter.route(
                        category: category,
                        digitalPreference: category == .digitalDownloads ? digitalPreference : nil,
                        catalogSize: category == .physicalGoods ? catalogSize : nil
                    ))
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 420, idealWidth: 420, minHeight: 260, idealHeight: 300)
    }
}
```

- [ ] **Step 2: Wire the entry point into `IntegrationWizard`**

In `Sources/AnglesiteApp/IntegrationWizard.swift`, add a state property to the `IntegrationWizard` struct (right after the existing `let onClose: () -> Void` on line 7):

```swift
    @State private var showingAddStore = false
```

Then replace the entire `pickIntegration` computed property (lines 26-35) with:

```swift
    private var pickIntegration: some View {
        VStack(spacing: 0) {
            Button {
                showingAddStore = true
            } label: {
                HStack {
                    Image(systemName: "cart")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Add a Store").font(.headline)
                        Text("Answer a couple of questions and we'll pick the right commerce integration.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider()
            List(model.descriptorsForPicker, id: \.id,
                 selection: Binding(get: { model.selectedID }, set: { model.selectedID = $0 })) { d in
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.displayName).font(.headline)
                    Text(d.summary).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .sheet(isPresented: $showingAddStore) {
            AddStoreIntakeView { route in
                showingAddStore = false
                model.startFromRouter(route)
            }
        }
    }
```

- [ ] **Step 3: Build to verify it compiles**

Run:
```sh
xcodegen generate
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -40
```
Expected: `** BUILD SUCCEEDED **`. If `xcodegen` isn't on PATH, install via `brew install xcodegen` first (per the repo's worktree setup notes in `CLAUDE.md`).

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteApp/AddStoreIntakeView.swift Sources/AnglesiteApp/IntegrationWizard.swift
git commit -m "feat(#462): add-store GUI entry point and intake sheet"
```

---

### Task 4: Siri — `AddStoreIntent`

**Files:**
- Modify: `Sources/AnglesiteIntents/IntegrationIntents.swift`
- Modify: `Sources/AnglesiteIntents/OperationDescriptor.swift`
- Modify: `Tests/AnglesiteIntentsTests/OperationDescriptorTests.swift`
- Modify: `Tests/AnglesiteIntentsTests/IntegrationIntentsTests.swift`

**Interfaces:**
- Consumes: `AddStoreRouter`, `StoreCategory`, `DigitalPreference`, `CatalogSize` (Task 1); `applyIntegration(ops:id:answers:site:)` (file-private helper already in `IntegrationIntents.swift`); `SetupIntegrationArguments.parseConfig(_:)` / `.reply(for:descriptor:)` (already in `AnglesiteCore`, used today by the FM chat tool).
- Produces: `public struct AddStoreIntent: AppIntent` with `@Parameter`s `site: SiteEntity`, `category: StoreCategoryAppEnum`, `digitalPreference: DigitalPreferenceAppEnum?`, `catalogSize: CatalogSizeAppEnum?`, `config: String?`; a test-only `confirmAndApplyForTesting() async throws -> String`.
- Produces: `public enum StoreCategoryAppEnum/DigitalPreferenceAppEnum/CatalogSizeAppEnum: String, AppEnum` mirroring the `AnglesiteCore` enums, each with a `var core: <CoreEnum>`.
- Produces: an `OperationDescriptor` entry with `operationID: "add-store"`, `intentTypeName: "AddStoreIntent"`.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/AnglesiteIntentsTests/IntegrationIntentsTests.swift`, inside the existing `IntegrationIntentsTests` suite:

```swift
    @Test func addStoreIntentRoutesServiceToStripeBuyButton() async throws {
        let intent = AddStoreIntent()
        intent.site = SiteEntity(id: "s1", name: "Acme", creationDate: nil, modificationDate: nil)
        intent.category = .service
        intent.config = "checkoutUrl=https://buy.stripe.com/test"
        let dialog = try await IntegrationOperationsOverride.$scoped.withValue(FakeService(terminal: .done(integrationID: "buyButton"))) {
            try await intent.confirmAndApplyForTesting()
        }
        #expect(dialog.contains("buyButton") || dialog.contains("Acme"))
    }

    @Test func addStoreIntentRoutesDigitalDownloadsLemonSqueezy() async throws {
        let intent = AddStoreIntent()
        intent.site = SiteEntity(id: "s1", name: "Acme", creationDate: nil, modificationDate: nil)
        intent.category = .digitalDownloads
        intent.digitalPreference = .lemonSqueezy
        intent.config = "checkoutUrl=https://acme.lemonsqueezy.com/checkout/buy/xyz"
        let dialog = try await IntegrationOperationsOverride.$scoped.withValue(FakeService(terminal: .done(integrationID: "lemonSqueezy"))) {
            try await intent.confirmAndApplyForTesting()
        }
        #expect(dialog.contains("lemonSqueezy") || dialog.contains("Acme"))
    }

    @Test func addStoreIntentRepromptsWhenARequiredFieldIsMissing() async throws {
        struct MissingFieldService: IntegrationOperationsService {
            func descriptors() -> [IntegrationDescriptor] { IntegrationCatalog.all }
            func plan(integrationID: IntegrationID, answers: Answers, siteID: String) async -> Result<OperationPlan, IntegrationError> {
                .failure(.missingRequiredField(key: "checkoutUrl"))
            }
            func apply(_ plan: OperationPlan, siteID: String) async -> IntegrationScaffolder.SetupStep {
                .done(integrationID: plan.integrationID.rawValue)
            }
        }
        let intent = AddStoreIntent()
        intent.site = SiteEntity(id: "s1", name: "Acme", creationDate: nil, modificationDate: nil)
        intent.category = .service
        let dialog = try await IntegrationOperationsOverride.$scoped.withValue(MissingFieldService()) {
            try await intent.confirmAndApplyForTesting()
        }
        #expect(dialog.contains("Checkout link"))
    }
```

Add to `Tests/AnglesiteIntentsTests/OperationDescriptorTests.swift`, inside `declaredFields()`'s `expected` dictionary (anywhere in the literal, e.g. right after the `"delete-dns-record"` line):

```swift
                "add-store": .init(sideEffect: .createsContent, requiresConfirmation: true, isCancellable: false, resultShape: .none),
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```sh
xcrun swift test --filter IntegrationIntentsTests
xcrun swift test --filter OperationDescriptorTests
```
Expected: both FAIL — `IntegrationIntentsTests` with `cannot find 'AddStoreIntent' in scope`; `OperationDescriptorTests.declaredFields` with a count mismatch (`expected.count` now one higher than `AnglesiteOperations.all.count`).

- [ ] **Step 3: Implement the `AppEnum`s and `AddStoreIntent`**

In `Sources/AnglesiteIntents/IntegrationIntents.swift`, add this after the `AddGiscusIntent` struct (after line 162, before the `// MARK: - Test-only helpers` comment):

```swift
// MARK: - Add Store (router)

public enum StoreCategoryAppEnum: String, AppEnum, Sendable, CaseIterable {
    case service, donations, digitalDownloads, physicalGoods, software

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Store Category" }
    public static let caseDisplayRepresentations: [StoreCategoryAppEnum: DisplayRepresentation] = [
        .service: "A service or one-off",
        .donations: "Donations or fundraising",
        .digitalDownloads: "Digital downloads",
        .physicalGoods: "Physical goods",
        .software: "Software or SaaS",
    ]

    var core: StoreCategory { StoreCategory(rawValue: rawValue)! }
}

public enum DigitalPreferenceAppEnum: String, AppEnum, Sendable, CaseIterable {
    case polar, lemonSqueezy

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Digital Platform" }
    public static let caseDisplayRepresentations: [DigitalPreferenceAppEnum: DisplayRepresentation] = [
        .polar: "Polar", .lemonSqueezy: "Lemon Squeezy",
    ]

    var core: DigitalPreference { DigitalPreference(rawValue: rawValue)! }
}

public enum CatalogSizeAppEnum: String, AppEnum, Sendable, CaseIterable {
    case few, catalog

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Catalog Size" }
    public static let caseDisplayRepresentations: [CatalogSizeAppEnum: DisplayRepresentation] = [
        .few: "Just a few", .catalog: "A full, growing catalog",
    ]

    var core: CatalogSize { CatalogSize(rawValue: rawValue)! }
}

public struct AddStoreIntent: AppIntent {
    public static let title: LocalizedStringResource = "Add a Store"
    public static let description = IntentDescription(
        "Answer a couple of questions and Anglesite sets up the right commerce integration."
    )

    @Parameter(title: "Site") public var site: SiteEntity
    @Parameter(title: "What are you selling?") public var category: StoreCategoryAppEnum
    @Parameter(title: "Digital platform", description: "polar or lemonSqueezy — only used for digital downloads.")
    public var digitalPreference: DigitalPreferenceAppEnum?
    @Parameter(title: "Catalog size", description: "few or catalog — only used for physical goods.")
    public var catalogSize: CatalogSizeAppEnum?
    @Parameter(title: "Details", description: "Remaining field values as key=value pairs, e.g. checkoutUrl=https://buy.stripe.com/xyz.")
    public var config: String?
    @Dependency private var ops: any IntegrationOperationsService

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Add a store to \(\.$site)")
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let svc = IntegrationOperationsOverride.scoped ?? ops
        let (route, descriptor, answers) = resolvedRoute()
        let planResult = await svc.plan(integrationID: route.integrationID, answers: answers, siteID: site.id)
        if case .failure = planResult {
            let reply = SetupIntegrationArguments.reply(for: planResult, descriptor: descriptor)
            return .result(dialog: IntentDialog(stringLiteral: reply))
        }
        if IntegrationOperationsOverride.scoped == nil {
            try await requestConfirmation(
                dialog: "Set up \(descriptor.displayName) on \(site.displayName)?"
            )
        }
        let dialog = await applyIntegration(ops: svc, id: route.integrationID, answers: answers, site: site)
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }

    /// Pure: computes the route, its descriptor, and the merged answers dict. Shared by
    /// `perform()` and `confirmAndApplyForTesting()` so the two stay in lockstep.
    private func resolvedRoute() -> (AddStoreRouter.Route, IntegrationDescriptor, Answers) {
        let route = AddStoreRouter.route(
            category: category.core,
            digitalPreference: digitalPreference?.core,
            catalogSize: catalogSize?.core
        )
        var answers = SetupIntegrationArguments.parseConfig(config)
        if let preset = route.presetProvider {
            answers["provider"] = preset
        }
        let descriptor = IntegrationCatalog.descriptor(for: route.integrationID)
        return (route, descriptor, answers)
    }
}
```

Then add this to the `// MARK: - Test-only helpers` section at the bottom of the file (after the existing `AddGiscusIntent` extension):

```swift
extension AddStoreIntent {
    /// Drives plan→(reprompt|apply) without the AppIntents confirmation gate. Only callable when
    /// `IntegrationOperationsOverride.scoped` is bound.
    func confirmAndApplyForTesting() async throws -> String {
        guard let svc = IntegrationOperationsOverride.scoped else {
            fatalError("confirmAndApplyForTesting requires a bound IntegrationOperationsOverride.scoped")
        }
        let (route, descriptor, answers) = resolvedRoute()
        let planResult = await svc.plan(integrationID: route.integrationID, answers: answers, siteID: site.id)
        if case .failure = planResult {
            return SetupIntegrationArguments.reply(for: planResult, descriptor: descriptor)
        }
        return await applyIntegration(ops: svc, id: route.integrationID, answers: answers, site: site)
    }
}
```

In `Sources/AnglesiteIntents/OperationDescriptor.swift`, add this entry to `AnglesiteOperations.all`, right after the `"delete-dns-record"` entry (before the closing `]`):

```swift
        OperationDescriptor(
            operationID: "add-store", displayName: "Add Store",
            intentTypeName: "AddStoreIntent", sideEffect: .createsContent,
            requiresConfirmation: true, isCancellable: false,
            resultShape: .none
        ),
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```sh
xcrun swift test --filter IntegrationIntentsTests
xcrun swift test --filter OperationDescriptorTests
xcrun swift test --filter AppIntentsTests
```
Expected: all PASS.

- [ ] **Step 5: Run the full test suite to catch any regressions**

Run:
```sh
xcrun swift test --package-path .
```
Expected: PASS (no regressions in `AnglesiteCoreTests`, `AnglesiteBridgeTests`, `AnglesiteIntentsTests`).

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteIntents/IntegrationIntents.swift Sources/AnglesiteIntents/OperationDescriptor.swift \
        Tests/AnglesiteIntentsTests/IntegrationIntentsTests.swift Tests/AnglesiteIntentsTests/OperationDescriptorTests.swift
git commit -m "feat(#462): add Siri-reachable AddStoreIntent"
```

---

### Task 5: Manual verification in the running app

**Files:** none (verification only).

- [ ] **Step 1: Build and launch**

Run:
```sh
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -40
open build/Debug/Anglesite.app 2>/dev/null || xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -showBuildSettings | grep -m1 TARGET_BUILD_DIR
```
(Use whichever build output path Xcode reports; or run the app directly from Xcode with ⌘R against an existing test site.)

- [ ] **Step 2: Walk the GUI happy path**

Open a site, open the integration wizard (the entry point used for `openIntegrationWizard()` in `SiteWindow`/`SiteWindowModel`). Confirm:
- An "Add a Store" row with a cart icon appears above the integration list.
- Tapping it opens a sheet with the category picker.
- Selecting "Physical goods" reveals the catalog-size follow-up; selecting "A full, growing catalog" then "Continue" lands directly on the `.fields` screen for Shopify Buy Button (shop domain / storefront token / product id) — not on a provider-picker screen.
- Selecting "Donations or fundraising" then "Continue" lands on the `.pickProvider` screen for Donations (Stripe/Liberapay/GitHub Sponsors), since the router doesn't preset a provider there.
- Cancel from the intake sheet returns to the plain integration list with no `selectedID` set.

- [ ] **Step 3: Note results**

If any step behaves differently than described, fix the relevant task's code before considering this plan complete — do not report success without having actually observed this in the running app.
