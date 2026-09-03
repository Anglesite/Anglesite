# Bucket 3 — Integration Wizard Framework Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the prose integration skills with a deterministic Swift framework that sets up the stateless integrations (booking, donations, giscus) via one engine exposed through a GUI wizard, App Intents, and a Foundation Models chat tool.

**Architecture:** Each integration is a static `IntegrationDescriptor` (declarative data). A pure `IntegrationPlanner.plan(...)` validates collected answers, resolves the descriptor's gated operations with `{{token}}` substitution, and returns an `Equatable` `OperationPlan`. The `IntegrationScaffolder` actor applies that plan idempotently (file copy, `.site-config` upsert, CSP-domain union, marker-anchor injection), streaming `SetupStep`s. Three thin front-doors collect answers and call `plan()` then `apply()` through one `IntegrationOperationsService` seam.

**Tech Stack:** Swift 6.4 / Xcode 27, SwiftUI + Observation, Swift Testing (`@Test`), AppIntents, FoundationModels (gated `#if compiler(>=6.4)`).

## Global Constraints

- **ES/Swift module style:** all new code is Swift; no third-party deps (Apple frameworks only).
- **Engine lives in `AnglesiteCore`** — descriptors, planner, scaffolder, service, FM tool, and the wizard *model* — so it is unit-testable on CI without a hosted app. Only the SwiftUI view lives in `AnglesiteApp`; only the App Intents live in `AnglesiteIntents`.
- **No new sidecar tool.** Pure Swift scaffolder. CSP *generation* stays in the site's build-time `template/scripts/csp.ts`; the wizard only writes provider domains into `.site-config`.
- **Tests are Swift Testing `@Test`** in `Tests/AnglesiteCoreTests` and `Tests/AnglesiteIntentsTests`. Run with `swift test --package-path .` (set `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` if the default toolchain is too old — see memory `swift-toolchain-developer-dir`).
- **FoundationModels code is gated** `#if compiler(>=6.4)` (absent at runtime on CI), matching `ApplyEditTool.swift` / `SearchContentTool.swift`.
- **Confirm-before-write:** every front-door shows the `OperationPlan` summary and applies only after explicit confirmation.
- **`.anglesite` package layout:** a site's editable files are under `package.sourceURL` (the `Source/` dir). `.site-config` lives in `Source/`. All writes target `Source/`.
- **Commit message trailer** on every commit: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- **Work on branch** `feat/bucket3-wizard-framework` (branched from `main`), or a worktree per CLAUDE.md. Run `xcodegen generate` + `scripts/copy-plugin.sh` first in a fresh worktree (see memory `worktree-app-build-copy-plugin`).

---

## File structure

**`Sources/AnglesiteCore/` (new):**
- `IntegrationDescriptor.swift` — `IntegrationID`, `IntegrationDescriptor`, `Provider`, `Field`, `FieldKind`, `Choice`, `Condition`, `Operation`, `TemplateRef`, `Template`, `ConfigEntry`.
- `IntegrationCatalog.swift` — the three static descriptors + `IntegrationCatalog.all` / `.descriptor(for:)`.
- `IntegrationPlan.swift` — `OperationPlan`, `PlannedStep`, `PlanWarning`, `IntegrationError`, `Answers`.
- `IntegrationPlanner.swift` — pure `plan(descriptor:answers:site:fileManager:) -> Result<OperationPlan, IntegrationError>` + derived-input reads.
- `MarkerInjector.swift` — pure string insertion/replacement at a named anchor (idempotent).
- `SiteConfigFile.swift` — `.site-config` upsert + CSP-domain union helpers (pure transform + IO).
- `IntegrationScaffolder.swift` — actor; `apply(_:in:) -> AsyncStream<SetupStep>`.
- `IntegrationOperationsService.swift` — protocol + `IntegrationOperations` live impl.
- `IntegrationWizardModel.swift` — `@MainActor @Observable` model.
- `SetupIntegrationTool.swift` — FM `Tool` (gated).

**`Sources/AnglesiteApp/` (new):**
- `IntegrationWizard.swift` — SwiftUI view rendering fields generically.

**`Sources/AnglesiteIntents/` (new):**
- `IntegrationIntents.swift` — `AddBookingIntent`, `AddDonationsIntent`, `AddGiscusIntent`, `IntegrationDialogs`, `IntegrationEntity`.
- `IntegrationOperationsOverride.swift` — `@TaskLocal` test seam.

**Modified:**
- `Sources/AnglesiteIntents/Bootstrap.swift` — register `IntegrationOperationsService` with `AppDependencyManager`.
- `Sources/AnglesiteCore/FoundationModelAssistant.swift` — optional `integrationService` dep; attach `SetupIntegrationTool` in `makeSession`; add to `attachedToolNames`.
- `Sources/AnglesiteApp/SiteWindow.swift` (or `SiteActions.swift`) — menu/command to present `IntegrationWizard`.
- `Resources/Template/` — anchors in `BaseLayout.astro` + blog-post layout; ensure component + page templates exist.

**Tests (new):**
- `Tests/AnglesiteCoreTests/IntegrationTemplateTests.swift`
- `Tests/AnglesiteCoreTests/MarkerInjectorTests.swift`
- `Tests/AnglesiteCoreTests/SiteConfigFileTests.swift`
- `Tests/AnglesiteCoreTests/IntegrationCatalogTests.swift`
- `Tests/AnglesiteCoreTests/IntegrationPlannerTests.swift`
- `Tests/AnglesiteCoreTests/IntegrationScaffolderTests.swift`
- `Tests/AnglesiteCoreTests/IntegrationWizardModelTests.swift`
- `Tests/AnglesiteCoreTests/SetupIntegrationToolTests.swift` (gated)
- `Tests/AnglesiteIntentsTests/IntegrationIntentsTests.swift`

---

## Task 1: Descriptor model + `Template` substitution

**Files:**
- Create: `Sources/AnglesiteCore/IntegrationDescriptor.swift`
- Test: `Tests/AnglesiteCoreTests/IntegrationTemplateTests.swift`

**Interfaces:**
- Produces: the descriptor value types consumed by every later task, and `Template.resolve(_:)`.

```swift
public enum IntegrationID: String, Sendable, CaseIterable { case booking, donations, giscus }

public struct Template: Sendable, Equatable, ExpressibleByStringLiteral {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public init(stringLiteral raw: String) { self.raw = raw }
    public func resolve(_ tokens: [String: String]) -> String { /* Task 1 */ }
}

public struct Choice: Sendable, Equatable { public let value: String; public let label: String
    public init(value: String, label: String) { self.value = value; self.label = label } }

public enum FieldKind: Sendable, Equatable {
    case text, email, url
    case choice([Choice])
    case bool
}

public enum Condition: Sendable, Equatable {
    case always
    case providerIs(String)
    case fieldEquals(key: String, value: String)
}

public struct Field: Sendable, Equatable, Identifiable {
    public let key: String
    public let label: String
    public let kind: FieldKind
    public let isOptional: Bool
    public let defaultValue: String?
    public let help: String?
    public let visibleWhen: Condition
    public var id: String { key }
    public init(key: String, label: String, kind: FieldKind, isOptional: Bool = false,
                defaultValue: String? = nil, help: String? = nil, visibleWhen: Condition = .always) {
        self.key = key; self.label = label; self.kind = kind; self.isOptional = isOptional
        self.defaultValue = defaultValue; self.help = help; self.visibleWhen = visibleWhen
    }
}

public struct Provider: Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let cspDomains: [String]
    public init(id: String, displayName: String, cspDomains: [String]) {
        self.id = id; self.displayName = displayName; self.cspDomains = cspDomains
    }
}

public struct ConfigEntry: Sendable, Equatable {
    public let key: String
    public let value: Template
    public init(key: String, value: Template) { self.key = key; self.value = value }
}

/// A relative path under the website template root (Resources/Template/).
public struct TemplateRef: Sendable, Equatable { public let path: String
    public init(_ path: String) { self.path = path } }

public enum Operation: Sendable, Equatable {
    case copyFile(from: TemplateRef, to: Template, when: Condition)
    case writeConfig([ConfigEntry], when: Condition)
    case addCSPDomains(fromProvider: Bool, extra: [String], when: Condition)
    case injectAtAnchor(file: Template, anchor: String, snippet: Template, when: Condition)
}

public struct IntegrationDescriptor: Sendable, Equatable, Identifiable {
    public let id: IntegrationID
    public let displayName: String
    public let summary: String
    public let providers: [Provider]
    public let fields: [Field]
    public let operations: [Operation]
    public init(id: IntegrationID, displayName: String, summary: String,
                providers: [Provider], fields: [Field], operations: [Operation]) {
        self.id = id; self.displayName = displayName; self.summary = summary
        self.providers = providers; self.fields = fields; self.operations = operations
    }
}
```

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/IntegrationTemplateTests.swift
import Testing
@testable import AnglesiteCore

@Suite struct IntegrationTemplateTests {
    @Test func substitutesKnownTokens() {
        let t = Template("https://cal.com/{{username}}/{{eventSlug}}")
        #expect(t.resolve(["username": "jane", "eventSlug": "30min"]) == "https://cal.com/jane/30min")
    }

    @Test func leavesUnknownTokensVerbatim() {
        // Unknown tokens are left as-is (planner guarantees required tokens are present).
        let t = Template("{{a}}-{{missing}}")
        #expect(t.resolve(["a": "x"]) == "x-{{missing}}")
    }

    @Test func substitutesRepeatedAndAdjacentTokens() {
        let t = Template("{{x}}{{x}}")
        #expect(t.resolve(["x": "ab"]) == "abab")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter IntegrationTemplateTests`
Expected: FAIL — `cannot find 'Template' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/AnglesiteCore/IntegrationDescriptor.swift` with all the types in the Interfaces block above. Implement `Template.resolve`:

```swift
public func resolve(_ tokens: [String: String]) -> String {
    var out = raw
    for (key, value) in tokens {
        out = out.replacingOccurrences(of: "{{\(key)}}", with: value)
    }
    return out
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter IntegrationTemplateTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/IntegrationDescriptor.swift Tests/AnglesiteCoreTests/IntegrationTemplateTests.swift
git commit -m "feat(bucket3): integration descriptor model + Template substitution

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `MarkerInjector` — idempotent anchor insertion

**Files:**
- Create: `Sources/AnglesiteCore/MarkerInjector.swift`
- Test: `Tests/AnglesiteCoreTests/MarkerInjectorTests.swift`

**Interfaces:**
- Produces: `MarkerInjector.inject(snippet:withID:atAnchor:into:) -> Result<String, MarkerInjector.Failure>` — pure string transform. Consumed by Task 7 (`injectAnchor` step).

```swift
public enum MarkerInjector {
    public enum Failure: Error, Equatable { case anchorNotFound(String) }
    /// Insert (or replace) a delimited block for `id` immediately after the `anchor` comment.
    /// Re-running with the same id replaces the existing block, so applying twice yields one copy.
    public static func inject(snippet: String, withID id: String, atAnchor anchor: String,
                              into content: String) -> Result<String, Failure>
}
```

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/MarkerInjectorTests.swift
import Testing
@testable import AnglesiteCore

@Suite struct MarkerInjectorTests {
    let anchor = "<!-- anglesite:body-end -->"
    func doc(_ inner: String) -> String { "<body>\n  <slot />\n  \(inner)\(anchor)\n</body>\n" }

    @Test func insertsBlockAfterAnchor() {
        let result = try! MarkerInjector.inject(
            snippet: "<Booking />", withID: "booking", atAnchor: anchor, into: doc("")).get()
        #expect(result.contains("<!-- anglesite:booking:start -->\n<Booking />\n<!-- anglesite:booking:end -->"))
        #expect(result.contains(anchor))
    }

    @Test func isIdempotent() {
        let once = try! MarkerInjector.inject(snippet: "<Booking />", withID: "booking", atAnchor: anchor, into: doc("")).get()
        let twice = try! MarkerInjector.inject(snippet: "<Booking />", withID: "booking", atAnchor: anchor, into: once).get()
        #expect(once == twice)
        // Exactly one block.
        #expect(twice.components(separatedBy: "<!-- anglesite:booking:start -->").count == 2)
    }

    @Test func replacesChangedSnippet() {
        let once = try! MarkerInjector.inject(snippet: "<Old />", withID: "booking", atAnchor: anchor, into: doc("")).get()
        let updated = try! MarkerInjector.inject(snippet: "<New />", withID: "booking", atAnchor: anchor, into: once).get()
        #expect(updated.contains("<New />"))
        #expect(!updated.contains("<Old />"))
    }

    @Test func failsWhenAnchorMissing() {
        let result = MarkerInjector.inject(snippet: "<X />", withID: "booking", atAnchor: anchor, into: "<body></body>")
        #expect(result == .failure(.anchorNotFound(anchor)))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter MarkerInjectorTests`
Expected: FAIL — `cannot find 'MarkerInjector' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/AnglesiteCore/MarkerInjector.swift
import Foundation

public enum MarkerInjector {
    public enum Failure: Error, Equatable { case anchorNotFound(String) }

    public static func inject(snippet: String, withID id: String, atAnchor anchor: String,
                              into content: String) -> Result<String, Failure> {
        let start = "<!-- anglesite:\(id):start -->"
        let end = "<!-- anglesite:\(id):end -->"
        let block = "\(start)\n\(snippet)\n\(end)"

        // Replace an existing delimited block if present (idempotent re-run).
        if let r = content.range(of: start), let e = content.range(of: end) {
            let replaced = content.replacingCharacters(in: r.lowerBound..<e.upperBound, with: block)
            return .success(replaced)
        }
        // Otherwise insert immediately before the anchor comment.
        guard let a = content.range(of: anchor) else { return .failure(.anchorNotFound(anchor)) }
        let inserted = content.replacingCharacters(in: a.lowerBound..<a.lowerBound, with: "\(block)\n")
        return .success(inserted)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter MarkerInjectorTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/MarkerInjector.swift Tests/AnglesiteCoreTests/MarkerInjectorTests.swift
git commit -m "feat(bucket3): idempotent marker-anchor injector

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `SiteConfigFile` — `.site-config` upsert + CSP union

**Files:**
- Create: `Sources/AnglesiteCore/SiteConfigFile.swift`
- Test: `Tests/AnglesiteCoreTests/SiteConfigFileTests.swift`

**Interfaces:**
- Produces: pure transforms `SiteConfigFile.upsert(_:into:)` and `SiteConfigFile.addCSPDomains(_:into:)`, consumed by Task 7. Existing `SiteScaffolder.appendSiteConfig` only sets-if-absent; this task adds true upsert (replace-or-append) and a comma-set union for the CSP key.

```swift
public enum SiteConfigFile {
    public static let cspKey = "SCRIPT_ALLOW"
    /// Replace-or-append each KEY=value, preserving all other lines and their order.
    public static func upsert(_ entries: [(key: String, value: String)], into contents: String) -> String
    /// Union `domains` into the comma-separated SCRIPT_ALLOW value (dedup, stable order: existing then new).
    public static func addCSPDomains(_ domains: [String], into contents: String) -> String
}
```

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/SiteConfigFileTests.swift
import Testing
@testable import AnglesiteCore

@Suite struct SiteConfigFileTests {
    @Test func appendsNewKey() {
        let out = SiteConfigFile.upsert([("BOOKING_PROVIDER", "cal")], into: "SITE_NAME=Acme\n")
        #expect(out == "SITE_NAME=Acme\nBOOKING_PROVIDER=cal\n")
    }

    @Test func replacesExistingKeyInPlace() {
        let out = SiteConfigFile.upsert([("BOOKING_PROVIDER", "calendly")],
                                        into: "BOOKING_PROVIDER=cal\nSITE_NAME=Acme\n")
        #expect(out == "BOOKING_PROVIDER=calendly\nSITE_NAME=Acme\n")
    }

    @Test func upsertIsIdempotent() {
        let once = SiteConfigFile.upsert([("K", "v")], into: "")
        let twice = SiteConfigFile.upsert([("K", "v")], into: once)
        #expect(once == twice)
    }

    @Test func unionsCSPDomainsWithoutDuplicates() {
        let out = SiteConfigFile.addCSPDomains(["app.cal.com", "app.cal.com"],
                                               into: "SCRIPT_ALLOW=existing.com\n")
        #expect(out == "SCRIPT_ALLOW=existing.com,app.cal.com\n")
    }

    @Test func cspUnionIsIdempotent() {
        let once = SiteConfigFile.addCSPDomains(["app.cal.com"], into: "")
        let twice = SiteConfigFile.addCSPDomains(["app.cal.com"], into: once)
        #expect(once == twice)
        #expect(twice == "SCRIPT_ALLOW=app.cal.com\n")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter SiteConfigFileTests`
Expected: FAIL — `cannot find 'SiteConfigFile' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/AnglesiteCore/SiteConfigFile.swift
import Foundation

public enum SiteConfigFile {
    public static let cspKey = "SCRIPT_ALLOW"

    public static func upsert(_ entries: [(key: String, value: String)], into contents: String) -> String {
        var lines = contents.isEmpty ? [] : contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }  // normalize trailing newline
        for (key, value) in entries {
            let line = "\(key)=\(value)"
            if let i = lines.firstIndex(where: { $0.hasPrefix("\(key)=") }) {
                lines[i] = line
            } else {
                lines.append(line)
            }
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    public static func addCSPDomains(_ domains: [String], into contents: String) -> String {
        let existingLine = contents.split(separator: "\n").first { $0.hasPrefix("\(cspKey)=") }
        let existing = existingLine.map { String($0.dropFirst(cspKey.count + 1)) }
            .map { $0.split(separator: ",").map(String.init) } ?? []
        var merged = existing
        for d in domains where !merged.contains(d) { merged.append(d) }
        return upsert([(cspKey, merged.joined(separator: ","))], into: contents)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter SiteConfigFileTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SiteConfigFile.swift Tests/AnglesiteCoreTests/SiteConfigFileTests.swift
git commit -m "feat(bucket3): .site-config upsert + CSP-domain union helpers

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: `IntegrationCatalog` — the three descriptors + validation

**Files:**
- Create: `Sources/AnglesiteCore/IntegrationCatalog.swift`
- Test: `Tests/AnglesiteCoreTests/IntegrationCatalogTests.swift`

**Interfaces:**
- Consumes: all types from Task 1.
- Produces: `IntegrationCatalog.all: [IntegrationDescriptor]`, `IntegrationCatalog.descriptor(for: IntegrationID) -> IntegrationDescriptor`, and `IntegrationDescriptor.validate() -> [String]` (returns a list of structural problems; empty == valid).

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/IntegrationCatalogTests.swift
import Testing
@testable import AnglesiteCore

@Suite struct IntegrationCatalogTests {
    @Test func hasAllThreeIntegrations() {
        #expect(Set(IntegrationCatalog.all.map(\.id)) == Set([.booking, .donations, .giscus]))
    }

    @Test(arguments: IntegrationCatalog.all)
    func eachDescriptorIsStructurallyValid(_ descriptor: IntegrationDescriptor) {
        #expect(descriptor.validate() == [], "\(descriptor.id) has problems: \(descriptor.validate())")
    }

    @Test func bookingHasStyleChoiceDrivingPlacement() {
        let booking = IntegrationCatalog.descriptor(for: .booking)
        let style = booking.fields.first { $0.key == "style" }
        guard case .choice(let choices)? = style?.kind else { Issue.record("no style choice"); return }
        #expect(Set(choices.map(\.value)) == Set(["inline", "floating", "button"]))
    }

    @Test func validateCatchesDanglingProviderReference() {
        let bad = IntegrationDescriptor(
            id: .booking, displayName: "x", summary: "x",
            providers: [Provider(id: "cal", displayName: "Cal", cspDomains: [])],
            fields: [Field(key: "u", label: "U", kind: .text, visibleWhen: .providerIs("nope"))],
            operations: [])
        #expect(bad.validate().contains { $0.contains("nope") })
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter IntegrationCatalogTests`
Expected: FAIL — `cannot find 'IntegrationCatalog' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/AnglesiteCore/IntegrationCatalog.swift`. Include `validate()` and the three descriptors. (Template relative paths must match the files confirmed/added in Task 12.)

```swift
import Foundation

public extension IntegrationDescriptor {
    /// Structural self-check (no I/O): conditions reference real fields/providers, choices are
    /// non-empty, provider-driven CSP ops only appear when providers exist. Empty == valid.
    func validate() -> [String] {
        var problems: [String] = []
        let fieldKeys = Set(fields.map(\.key))
        let providerIDs = Set(providers.map(\.id))

        func check(_ condition: Condition, _ context: String) {
            switch condition {
            case .always: break
            case .providerIs(let p) where !providerIDs.contains(p):
                problems.append("\(context): condition references unknown provider \"\(p)\"")
            case .fieldEquals(let key, _) where !fieldKeys.contains(key):
                problems.append("\(context): condition references unknown field \"\(key)\"")
            default: break
            }
        }
        for f in fields {
            check(f.visibleWhen, "field \(f.key)")
            if case .choice(let choices) = f.kind, choices.isEmpty {
                problems.append("field \(f.key): choice has no options")
            }
        }
        for (i, op) in operations.enumerated() {
            switch op {
            case .copyFile(_, _, let w), .writeConfig(_, let w), .injectAtAnchor(_, _, _, let w):
                check(w, "operation \(i)")
            case .addCSPDomains(let fromProvider, _, let w):
                check(w, "operation \(i)")
                if fromProvider && providers.isEmpty {
                    problems.append("operation \(i): addCSPDomains(fromProvider:) but integration has no providers")
                }
            }
        }
        return problems
    }
}

public enum IntegrationCatalog {
    public static let all: [IntegrationDescriptor] = [booking, donations, giscus]

    public static func descriptor(for id: IntegrationID) -> IntegrationDescriptor {
        all.first { $0.id == id }!
    }

    // MARK: booking
    static let booking = IntegrationDescriptor(
        id: .booking,
        displayName: "Booking",
        summary: "Let visitors book a time with you (Cal.com or Calendly).",
        providers: [
            Provider(id: "cal", displayName: "Cal.com", cspDomains: ["app.cal.com"]),
            Provider(id: "calendly", displayName: "Calendly", cspDomains: ["assets.calendly.com", "calendly.com"]),
        ],
        fields: [
            Field(key: "username", label: "Username / slug", kind: .text,
                  help: "Your Cal.com or Calendly username."),
            Field(key: "eventSlug", label: "Event type", kind: .text, isOptional: true,
                  help: "Optional event slug, e.g. “30min”."),
            Field(key: "style", label: "Placement", kind: .choice([
                Choice(value: "inline", label: "On a /book page"),
                Choice(value: "floating", label: "Floating button (site-wide)"),
                Choice(value: "button", label: "Inline button"),
            ]), defaultValue: "inline"),
            Field(key: "buttonText", label: "Button text", kind: .text, isOptional: true,
                  defaultValue: "Book a time", visibleWhen: .fieldEquals(key: "style", value: "floating")),
        ],
        operations: [
            .copyFile(from: TemplateRef("src/components/BookingWidget.astro"),
                      to: "src/components/BookingWidget.astro", when: .always),
            .copyFile(from: TemplateRef("src/pages/book.astro"),
                      to: "src/pages/book.astro", when: .fieldEquals(key: "style", value: "inline")),
            .injectAtAnchor(file: "src/layouts/BaseLayout.astro", anchor: "<!-- anglesite:body-end -->",
                            snippet: "<BookingWidget provider=\"{{provider}}\" username=\"{{username}}\" eventSlug=\"{{eventSlug}}\" style=\"floating\" buttonText=\"{{buttonText}}\" client:load />",
                            when: .fieldEquals(key: "style", value: "floating")),
            .writeConfig([
                ConfigEntry(key: "BOOKING_PROVIDER", value: "{{provider}}"),
                ConfigEntry(key: "BOOKING_USERNAME", value: "{{username}}"),
                ConfigEntry(key: "BOOKING_STYLE", value: "{{style}}"),
            ], when: .always),
            .addCSPDomains(fromProvider: true, extra: [], when: .always),
        ])

    // MARK: donations
    static let donations = IntegrationDescriptor(
        id: .donations,
        displayName: "Donations",
        summary: "Add a donation button (Stripe, Liberapay, or GitHub Sponsors).",
        providers: [
            Provider(id: "stripe", displayName: "Stripe", cspDomains: ["js.stripe.com"]),
            Provider(id: "liberapay", displayName: "Liberapay", cspDomains: ["liberapay.com"]),
            Provider(id: "githubSponsors", displayName: "GitHub Sponsors", cspDomains: ["github.com"]),
        ],
        fields: [
            Field(key: "link", label: "Donation link", kind: .url,
                  help: "Your Stripe Payment Link, Liberapay, or GitHub Sponsors URL."),
            Field(key: "buttonText", label: "Button text", kind: .text, isOptional: true, defaultValue: "Donate"),
        ],
        operations: [
            .copyFile(from: TemplateRef("src/components/DonationButton.astro"),
                      to: "src/components/DonationButton.astro", when: .always),
            .copyFile(from: TemplateRef("src/pages/donate.astro"),
                      to: "src/pages/donate.astro", when: .always),
            .writeConfig([
                ConfigEntry(key: "DONATIONS_PROVIDER", value: "{{provider}}"),
                ConfigEntry(key: "DONATIONS_LINK", value: "{{link}}"),
                ConfigEntry(key: "DONATIONS_BUTTON_TEXT", value: "{{buttonText}}"),
            ], when: .always),
            .addCSPDomains(fromProvider: true, extra: [], when: .always),
        ])

    // MARK: giscus
    static let giscus = IntegrationDescriptor(
        id: .giscus,
        displayName: "Comments (giscus)",
        summary: "Add GitHub-Discussions-backed comments to blog posts.",
        providers: [],
        fields: [
            Field(key: "repo", label: "Repository", kind: .text, help: "owner/repo for the discussions backend."),
            Field(key: "repoId", label: "Repository ID", kind: .text),
            Field(key: "category", label: "Discussion category", kind: .text, defaultValue: "Announcements"),
            Field(key: "categoryId", label: "Category ID", kind: .text),
            Field(key: "mapping", label: "Mapping", kind: .choice([
                Choice(value: "pathname", label: "By page pathname"),
                Choice(value: "title", label: "By page title"),
            ]), defaultValue: "pathname"),
        ],
        operations: [
            .copyFile(from: TemplateRef("src/components/Comments.astro"),
                      to: "src/components/Comments.astro", when: .always),
            .injectAtAnchor(file: "src/layouts/BlogPost.astro", anchor: "<!-- anglesite:comments -->",
                            snippet: "<Comments repo=\"{{repo}}\" repoId=\"{{repoId}}\" category=\"{{category}}\" categoryId=\"{{categoryId}}\" mapping=\"{{mapping}}\" client:visible />",
                            when: .always),
            // `repoId`/`categoryId` are injected as component props in the snippet above, NOT
            // written to `.site-config`. Verified against the plugin's `Comments.astro`, which
            // reads `repoId`/`categoryId`/`category`/`mapping` from `Astro.props` (not
            // `import.meta.env`). `.site-config` only persists `GISCUS_REPO`/`GISCUS_CATEGORY`
            // for human reference + the pre-deploy CSP scan; the build needs nothing more.
            .writeConfig([
                ConfigEntry(key: "GISCUS_REPO", value: "{{repo}}"),
                ConfigEntry(key: "GISCUS_CATEGORY", value: "{{category}}"),
            ], when: .always),
            .addCSPDomains(fromProvider: false, extra: ["giscus.app"], when: .always),
        ])
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter IntegrationCatalogTests`
Expected: PASS (the parameterized validity test runs once per descriptor).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/IntegrationCatalog.swift Tests/AnglesiteCoreTests/IntegrationCatalogTests.swift
git commit -m "feat(bucket3): integration catalog (booking, donations, giscus) + validation

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: `IntegrationPlanner` — pure plan() with validation + resolution

**Files:**
- Create: `Sources/AnglesiteCore/IntegrationPlan.swift`
- Create: `Sources/AnglesiteCore/IntegrationPlanner.swift`
- Test: `Tests/AnglesiteCoreTests/IntegrationPlannerTests.swift`

**Interfaces:**
- Consumes: Task 1 types, Task 4 catalog.
- Produces:

```swift
// IntegrationPlan.swift
public typealias Answers = [String: String]   // field key → value; chosen provider under "provider"

public enum PlannedStep: Sendable, Equatable {
    case createFile(relativePath: String, contents: String)
    case upsertConfig([ConfigKV])                  // ConfigKV { key, value }
    case injectAnchor(relativeFile: String, anchor: String, id: String, snippet: String)
    case addCSP([String])
}
public struct ConfigKV: Sendable, Equatable { public let key: String; public let value: String
    public init(key: String, value: String) { self.key = key; self.value = value } }

public struct PlanWarning: Sendable, Equatable { public let message: String
    public init(_ message: String) { self.message = message } }

public struct OperationPlan: Sendable, Equatable {
    public let integrationID: IntegrationID
    public let steps: [PlannedStep]
    public let warnings: [PlanWarning]
    public var summary: String { /* Task 6 */ "" }
}

public enum IntegrationError: Error, Equatable, Sendable {
    case missingRequiredField(key: String)
    case invalidValue(key: String, reason: String)
    case unknownProvider(String)
    case providerRequired
}

// IntegrationPlanner.swift
public enum IntegrationPlanner {
    /// Pure: no writes. Reads `global.css`/`Info.plist` for derived tokens only.
    public static func plan(descriptor: IntegrationDescriptor, answers: Answers,
                            sourceDirectory: URL,
                            fileManager: FileManager = .default) -> Result<OperationPlan, IntegrationError>
}
```

Note `copyFile` is resolved in the planner by reading the **template** file's contents (so the
plan is a fully-resolved `createFile`). The planner therefore also needs the template root; thread it
in via a second parameter `templateDirectory: URL`. Update the signature to:
`plan(descriptor:answers:sourceDirectory:templateDirectory:fileManager:)`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/IntegrationPlannerTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct IntegrationPlannerTests {
    /// Builds a throwaway template dir with the component/page files the planner copies.
    func makeTemplate() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tmpl-\(UUID().uuidString)")
        for p in ["src/components/BookingWidget.astro", "src/pages/book.astro",
                  "src/components/DonationButton.astro", "src/pages/donate.astro",
                  "src/components/Comments.astro"] {
            let url = root.appendingPathComponent(p)
            try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! "TEMPLATE \(p)".write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }
    func makeSource() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("src-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func missingRequiredFieldFails() {
        let r = IntegrationPlanner.plan(descriptor: IntegrationCatalog.descriptor(for: .booking),
                                        answers: ["provider": "cal"],  // no username
                                        sourceDirectory: makeSource(), templateDirectory: makeTemplate())
        #expect(r == .failure(.missingRequiredField(key: "username")))
    }

    @Test func badURLFails() {
        let r = IntegrationPlanner.plan(descriptor: IntegrationCatalog.descriptor(for: .donations),
                                        answers: ["provider": "stripe", "link": "not a url"],
                                        sourceDirectory: makeSource(), templateDirectory: makeTemplate())
        if case .failure(.invalidValue(let key, _)) = r { #expect(key == "link") } else { Issue.record("expected invalidValue") }
    }

    @Test func bookingInlineProducesBookPageNotAnchorInjection() {
        let r = try! IntegrationPlanner.plan(descriptor: IntegrationCatalog.descriptor(for: .booking),
            answers: ["provider": "cal", "username": "jane", "style": "inline"],
            sourceDirectory: makeSource(), templateDirectory: makeTemplate()).get()
        #expect(r.steps.contains { if case .createFile(let p, _) = $0 { return p == "src/pages/book.astro" }; return false })
        #expect(!r.steps.contains { if case .injectAnchor = $0 { return true }; return false })
    }

    @Test func bookingFloatingInjectsIntoLayout() {
        let r = try! IntegrationPlanner.plan(descriptor: IntegrationCatalog.descriptor(for: .booking),
            answers: ["provider": "cal", "username": "jane", "style": "floating"],
            sourceDirectory: makeSource(), templateDirectory: makeTemplate()).get()
        #expect(r.steps.contains { if case .injectAnchor(let f, _, _, let s) = $0 { return f.contains("BaseLayout") && s.contains("jane") }; return false })
        #expect(!r.steps.contains { if case .createFile(let p, _) = $0 { return p == "src/pages/book.astro" }; return false })
    }

    @Test func providerSwitchSwapsCSPDomains() {
        func csp(_ provider: String) -> [String] {
            let r = try! IntegrationPlanner.plan(descriptor: IntegrationCatalog.descriptor(for: .booking),
                answers: ["provider": provider, "username": "j", "style": "inline"],
                sourceDirectory: makeSource(), templateDirectory: makeTemplate()).get()
            for case .addCSP(let d) in r.steps { return d }
            return []
        }
        #expect(csp("cal") == ["app.cal.com"])
        #expect(Set(csp("calendly")) == Set(["assets.calendly.com", "calendly.com"]))
    }

    @Test func missingProviderForProviderBackedIntegrationFails() {
        let r = IntegrationPlanner.plan(descriptor: IntegrationCatalog.descriptor(for: .booking),
            answers: ["username": "jane", "style": "inline"],  // no provider
            sourceDirectory: makeSource(), templateDirectory: makeTemplate())
        #expect(r == .failure(.providerRequired))
    }

    @Test func missingGlobalCSSWarnsNotThrows() {
        // giscus has no {{brandColor}} use, so use a source dir with no global.css and confirm a plan
        // still returns; the warning path is asserted via booking which references brandColor only if used.
        let r = IntegrationPlanner.plan(descriptor: IntegrationCatalog.descriptor(for: .giscus),
            answers: ["repo": "o/r", "repoId": "R", "category": "General", "categoryId": "C", "mapping": "pathname"],
            sourceDirectory: makeSource(), templateDirectory: makeTemplate())
        #expect((try? r.get()) != nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter IntegrationPlannerTests`
Expected: FAIL — `cannot find 'IntegrationPlanner' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `IntegrationPlan.swift` (types above, with `summary` returning `""` for now — Task 6 fills it). Create `IntegrationPlanner.swift`:

```swift
import Foundation

public enum IntegrationPlanner {
    public static func plan(descriptor: IntegrationDescriptor, answers: Answers,
                            sourceDirectory: URL, templateDirectory: URL,
                            fileManager: FileManager = .default) -> Result<OperationPlan, IntegrationError> {
        var warnings: [PlanWarning] = []

        // 1. Provider.
        let providerID = answers["provider"]
        if !descriptor.providers.isEmpty {
            guard let p = providerID, !p.isEmpty else { return .failure(.providerRequired) }
            guard descriptor.providers.contains(where: { $0.id == p }) else { return .failure(.unknownProvider(p)) }
        }

        // 2. Validate visible fields.
        for field in descriptor.fields where isVisible(field.visibleWhen, answers: answers, providerID: providerID) {
            let value = answers[field.key] ?? field.defaultValue ?? ""
            if value.isEmpty {
                if field.isOptional { continue }
                return .failure(.missingRequiredField(key: field.key))
            }
            switch field.kind {
            case .email where !value.contains("@"):
                return .failure(.invalidValue(key: field.key, reason: "not an email address"))
            case .url where URL(string: value)?.scheme == nil:
                return .failure(.invalidValue(key: field.key, reason: "not a URL"))
            case .choice(let choices) where !choices.contains(where: { $0.value == value }):
                return .failure(.invalidValue(key: field.key, reason: "not one of the allowed choices"))
            default: break
            }
        }

        // 3. Tokens = answers (with field defaults filled) + derived inputs.
        var tokens = answers
        for field in descriptor.fields where tokens[field.key]?.isEmpty != false {
            tokens[field.key] = answers[field.key] ?? field.defaultValue ?? ""
        }
        if let brand = brandColor(sourceDirectory: sourceDirectory, fileManager: fileManager) {
            tokens["brandColor"] = brand
        } else {
            tokens["brandColor"] = "#000000"
            // Only warn if any operation actually references the token.
            if descriptor.operations.contains(where: { operationReferences("brandColor", $0) }) {
                warnings.append(PlanWarning("Couldn't read the site's brand color; used a default."))
            }
        }

        // 4. Resolve operations into concrete steps.
        var steps: [PlannedStep] = []
        for op in descriptor.operations {
            switch op {
            case .copyFile(let from, let to, let when):
                guard isVisible(when, answers: answers, providerID: providerID) else { continue }
                let dest = to.resolve(tokens)
                let src = templateDirectory.appendingPathComponent(from.path)
                guard let contents = try? String(contentsOf: src, encoding: .utf8) else {
                    warnings.append(PlanWarning("Template file missing: \(from.path)")); continue
                }
                steps.append(.createFile(relativePath: dest, contents: contents))
            case .writeConfig(let entries, let when):
                guard isVisible(when, answers: answers, providerID: providerID) else { continue }
                steps.append(.upsertConfig(entries.map { ConfigKV(key: $0.key, value: $0.value.resolve(tokens)) }))
            case .addCSPDomains(let fromProvider, let extra, let when):
                guard isVisible(when, answers: answers, providerID: providerID) else { continue }
                var domains = extra
                if fromProvider, let p = providerID,
                   let provider = descriptor.providers.first(where: { $0.id == p }) {
                    domains = provider.cspDomains + extra
                }
                if !domains.isEmpty { steps.append(.addCSP(domains)) }
            case .injectAtAnchor(let file, let anchor, let snippet, let when):
                guard isVisible(when, answers: answers, providerID: providerID) else { continue }
                steps.append(.injectAnchor(relativeFile: file.resolve(tokens), anchor: anchor,
                                           id: descriptor.id.rawValue, snippet: snippet.resolve(tokens)))
            }
        }
        return .success(OperationPlan(integrationID: descriptor.id, steps: steps, warnings: warnings))
    }

    static func isVisible(_ condition: Condition, answers: Answers, providerID: String?) -> Bool {
        switch condition {
        case .always: return true
        case .providerIs(let p): return providerID == p
        case .fieldEquals(let key, let value):
            let resolved = answers[key] ?? ""
            return resolved == value
        }
    }

    private static func operationReferences(_ token: String, _ op: Operation) -> Bool {
        let needle = "{{\(token)}}"
        switch op {
        case .copyFile(_, let to, _): return to.raw.contains(needle)
        case .writeConfig(let entries, _): return entries.contains { $0.value.raw.contains(needle) }
        case .injectAtAnchor(let file, _, let snippet, _): return file.raw.contains(needle) || snippet.raw.contains(needle)
        case .addCSPDomains: return false
        }
    }

    private static func brandColor(sourceDirectory: URL, fileManager: FileManager) -> String? {
        let css = sourceDirectory.appendingPathComponent("src/styles/global.css")
        guard let text = try? String(contentsOf: css, encoding: .utf8) else { return nil }
        // Find `--color-primary: <value>;`
        guard let r = text.range(of: "--color-primary:") else { return nil }
        let rest = text[r.upperBound...]
        guard let semi = rest.firstIndex(of: ";") else { return nil }
        return rest[..<semi].trimmingCharacters(in: .whitespaces)
    }
}
```

The default-fill loop fills field defaults into `tokens` so `fieldEquals` conditions on
defaulted fields (e.g. `style` defaulting to `inline`) resolve. To make `isVisible` see defaults,
**also resolve defaults into a working copy of answers before resolution.** Adjust Step 3 to compute
`var effective = answers` then fill defaults into `effective`, and pass `effective` (not `answers`)
to `isVisible` in the operations loop and to the field-validation loop. Update the test expectation
accordingly (defaults already covered by the inline/floating tests).

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter IntegrationPlannerTests`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/IntegrationPlan.swift Sources/AnglesiteCore/IntegrationPlanner.swift Tests/AnglesiteCoreTests/IntegrationPlannerTests.swift
git commit -m "feat(bucket3): pure integration planner (validate, resolve, derive)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: `OperationPlan.summary` — human preview

**Files:**
- Modify: `Sources/AnglesiteCore/IntegrationPlan.swift`
- Test: `Tests/AnglesiteCoreTests/IntegrationPlannerTests.swift` (add to existing suite)

**Interfaces:**
- Produces: `OperationPlan.summary: String` — the confirmation text shown by all three front-doors.

- [ ] **Step 1: Write the failing test**

```swift
// Append to IntegrationPlannerTests.swift
@Test func summaryDescribesEachStepKind() {
    let r = try! IntegrationPlanner.plan(descriptor: IntegrationCatalog.descriptor(for: .booking),
        answers: ["provider": "cal", "username": "jane", "style": "inline"],
        sourceDirectory: makeSource(), templateDirectory: makeTemplate()).get()
    let s = r.summary
    #expect(s.contains("Create src/components/BookingWidget.astro"))
    #expect(s.contains("Create src/pages/book.astro"))
    #expect(s.contains("Set 3 config keys"))
    #expect(s.contains("Allow 1 domain"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter "IntegrationPlannerTests/summaryDescribesEachStepKind"`
Expected: FAIL — `summary` returns `""`.

- [ ] **Step 3: Write minimal implementation**

Replace the `summary` stub in `IntegrationPlan.swift`:

```swift
public var summary: String {
    var lines: [String] = []
    for step in steps {
        switch step {
        case .createFile(let path, _): lines.append("Create \(path)")
        case .upsertConfig(let kvs): lines.append("Set \(kvs.count) config key\(kvs.count == 1 ? "" : "s")")
        case .injectAnchor(let file, _, _, _): lines.append("Add a component to \(file)")
        case .addCSP(let domains): lines.append("Allow \(domains.count) domain\(domains.count == 1 ? "" : "s") in the site's security policy")
        }
    }
    for w in warnings { lines.append("⚠︎ \(w.message)") }
    return lines.joined(separator: "\n")
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter IntegrationPlannerTests`
Expected: PASS (all 9 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/IntegrationPlan.swift Tests/AnglesiteCoreTests/IntegrationPlannerTests.swift
git commit -m "feat(bucket3): OperationPlan human-readable summary

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: `IntegrationScaffolder` — idempotent apply

**Files:**
- Create: `Sources/AnglesiteCore/IntegrationScaffolder.swift`
- Test: `Tests/AnglesiteCoreTests/IntegrationScaffolderTests.swift`

**Interfaces:**
- Consumes: `OperationPlan`/`PlannedStep` (Task 5), `MarkerInjector` (Task 2), `SiteConfigFile` (Task 3).
- Produces:

```swift
public actor IntegrationScaffolder {
    public enum SetupStep: Sendable, Equatable {
        case writingFiles, configuring, done(integrationID: String)
        case warning(step: String, message: String)
        case failed(step: String, message: String)
    }
    public init(fileManager: FileManager = .default)
    public nonisolated func apply(_ plan: OperationPlan, in sourceDirectory: URL) -> AsyncStream<SetupStep>
}
```

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/IntegrationScaffolderTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct IntegrationScaffolderTests {
    func makeSource(withLayout: Bool = false) -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("apply-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root.appendingPathComponent("src/layouts"), withIntermediateDirectories: true)
        if withLayout {
            try! "<body>\n<slot/>\n<!-- anglesite:body-end -->\n</body>\n"
                .write(to: root.appendingPathComponent("src/layouts/BaseLayout.astro"), atomically: true, encoding: .utf8)
        }
        return root
    }
    func collect(_ stream: AsyncStream<IntegrationScaffolder.SetupStep>) async -> [IntegrationScaffolder.SetupStep] {
        var out: [IntegrationScaffolder.SetupStep] = []
        for await s in stream { out.append(s) }
        return out
    }

    @Test func appliesCreateFileAndConfig() async {
        let src = makeSource()
        let plan = OperationPlan(integrationID: .donations, steps: [
            .createFile(relativePath: "src/components/DonationButton.astro", contents: "BTN"),
            .upsertConfig([ConfigKV(key: "DONATIONS_PROVIDER", value: "stripe")]),
            .addCSP(["js.stripe.com"]),
        ], warnings: [])
        let steps = await collect(IntegrationScaffolder().apply(plan, in: src))
        #expect(steps.contains(.done(integrationID: "donations")))
        #expect(try! String(contentsOf: src.appendingPathComponent("src/components/DonationButton.astro"), encoding: .utf8) == "BTN")
        let cfg = try! String(contentsOf: src.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(cfg.contains("DONATIONS_PROVIDER=stripe"))
        #expect(cfg.contains("SCRIPT_ALLOW=js.stripe.com"))
    }

    @Test func injectAnchorIsIdempotent() async {
        let src = makeSource(withLayout: true)
        let plan = OperationPlan(integrationID: .booking, steps: [
            .injectAnchor(relativeFile: "src/layouts/BaseLayout.astro", anchor: "<!-- anglesite:body-end -->",
                          id: "booking", snippet: "<BookingWidget/>"),
        ], warnings: [])
        _ = await collect(IntegrationScaffolder().apply(plan, in: src))
        _ = await collect(IntegrationScaffolder().apply(plan, in: src))  // twice
        let layout = try! String(contentsOf: src.appendingPathComponent("src/layouts/BaseLayout.astro"), encoding: .utf8)
        #expect(layout.components(separatedBy: "<!-- anglesite:booking:start -->").count == 2)  // exactly one block
    }

    @Test func injectAnchorFailsWhenAnchorMissing() async {
        let src = makeSource(withLayout: false)
        try! "<body></body>".write(to: src.appendingPathComponent("src/layouts/BaseLayout.astro"), atomically: true, encoding: .utf8)
        let plan = OperationPlan(integrationID: .booking, steps: [
            .injectAnchor(relativeFile: "src/layouts/BaseLayout.astro", anchor: "<!-- anglesite:body-end -->",
                          id: "booking", snippet: "<X/>"),
        ], warnings: [])
        let steps = await collect(IntegrationScaffolder().apply(plan, in: src))
        #expect(steps.contains { if case .failed = $0 { return true }; return false })
    }

    @Test func warnsRatherThanClobberingHandEditedFile() async {
        let src = makeSource()
        let path = src.appendingPathComponent("src/components/DonationButton.astro")
        try! FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! "HAND EDITED".write(to: path, atomically: true, encoding: .utf8)
        let plan = OperationPlan(integrationID: .donations, steps: [
            .createFile(relativePath: "src/components/DonationButton.astro", contents: "NEW"),
        ], warnings: [])
        let steps = await collect(IntegrationScaffolder().apply(plan, in: src))
        #expect(steps.contains { if case .warning = $0 { return true }; return false })
        #expect(try! String(contentsOf: path, encoding: .utf8) == "HAND EDITED")  // not clobbered
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter IntegrationScaffolderTests`
Expected: FAIL — `cannot find 'IntegrationScaffolder' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/AnglesiteCore/IntegrationScaffolder.swift
import Foundation

public actor IntegrationScaffolder {
    public enum SetupStep: Sendable, Equatable {
        case writingFiles, configuring, done(integrationID: String)
        case warning(step: String, message: String)
        case failed(step: String, message: String)
    }

    private let fileManager: FileManager
    public init(fileManager: FileManager = .default) { self.fileManager = fileManager }

    public nonisolated func apply(_ plan: OperationPlan, in sourceDirectory: URL) -> AsyncStream<SetupStep> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            Task {
                await self.run(plan, in: sourceDirectory) { continuation.yield($0) }
                continuation.finish()
            }
        }
    }

    private func run(_ plan: OperationPlan, in source: URL, emit: @Sendable (SetupStep) -> Void) async {
        for w in plan.warnings { emit(.warning(step: "plan", message: w.message)) }
        emit(.writingFiles)
        for step in plan.steps {
            switch step {
            case .createFile(let rel, let contents):
                let url = source.appendingPathComponent(rel)
                do {
                    if fileManager.fileExists(atPath: url.path) {
                        let existing = try String(contentsOf: url, encoding: .utf8)
                        if existing != contents {
                            emit(.warning(step: "writingFiles", message: "Left your edited \(rel) untouched."))
                            continue
                        }
                    } else {
                        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    }
                    try contents.write(to: url, atomically: true, encoding: .utf8)
                } catch { return emit(.failed(step: "writingFiles", message: humanize(error))) }

            case .injectAnchor(let rel, let anchor, let id, let snippet):
                let url = source.appendingPathComponent(rel)
                do {
                    let content = try String(contentsOf: url, encoding: .utf8)
                    switch MarkerInjector.inject(snippet: snippet, withID: id, atAnchor: anchor, into: content) {
                    case .success(let updated): try updated.write(to: url, atomically: true, encoding: .utf8)
                    case .failure(let f): return emit(.failed(step: "writingFiles", message: "\(rel): \(f)"))
                    }
                } catch { return emit(.failed(step: "writingFiles", message: humanize(error))) }

            case .upsertConfig(let kvs):
                emit(.configuring)
                let url = source.appendingPathComponent(".site-config")
                let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                let updated = SiteConfigFile.upsert(kvs.map { ($0.key, $0.value) }, into: current)
                do { try updated.write(to: url, atomically: true, encoding: .utf8) }
                catch { return emit(.failed(step: "configuring", message: humanize(error))) }

            case .addCSP(let domains):
                emit(.configuring)
                let url = source.appendingPathComponent(".site-config")
                let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                let updated = SiteConfigFile.addCSPDomains(domains, into: current)
                do { try updated.write(to: url, atomically: true, encoding: .utf8) }
                catch { return emit(.failed(step: "configuring", message: humanize(error))) }
            }
        }
        emit(.done(integrationID: plan.integrationID.rawValue))
    }

    private func humanize(_ error: Error) -> String { (error as NSError).localizedDescription }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter IntegrationScaffolderTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/IntegrationScaffolder.swift Tests/AnglesiteCoreTests/IntegrationScaffolderTests.swift
git commit -m "feat(bucket3): idempotent integration scaffolder (apply)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: `IntegrationOperationsService` + live `IntegrationOperations`

**Files:**
- Create: `Sources/AnglesiteCore/IntegrationOperationsService.swift`
- Test: `Tests/AnglesiteCoreTests/IntegrationScaffolderTests.swift` (add `IntegrationOperationsTests` suite in same file, or a new file `IntegrationOperationsTests.swift`)

**Interfaces:**
- Consumes: Task 4 catalog, Task 5 planner, Task 7 scaffolder.
- Produces: the single seam all three front-doors depend on.

```swift
public protocol IntegrationOperationsService: Sendable {
    func descriptors() -> [IntegrationDescriptor]
    func plan(integrationID: IntegrationID, answers: Answers, siteID: String) async -> Result<OperationPlan, IntegrationError>
    func apply(_ plan: OperationPlan, siteID: String) async -> IntegrationScaffolder.SetupStep   // terminal step (.done/.failed)
}

public struct IntegrationOperations: IntegrationOperationsService {
    public init(sourceDirectory: @escaping @Sendable (String) async -> URL?,
                templateDirectory: @escaping @Sendable () -> URL?)
}
```

`sourceDirectory` resolves a site id to its `Source/` URL (production:
`{ id in await SiteStore.shared.find(id: id)?.sourceDirectory }`, mirroring
`NativeContentOperations` in `Bootstrap.swift`). `templateDirectory` resolves the template root
(production: `{ TemplateRuntime.resolve().url }`).

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/IntegrationOperationsTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct IntegrationOperationsTests {
    func makeTemplate() -> URL { /* same helper as IntegrationPlannerTests.makeTemplate */
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tmpl-\(UUID().uuidString)")
        for p in ["src/components/Comments.astro"] {
            let url = root.appendingPathComponent(p)
            try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! "C".write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }
    func makeSource(withBlogLayout: Bool) -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("src-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root.appendingPathComponent("src/layouts"), withIntermediateDirectories: true)
        if withBlogLayout {
            try! "<article><slot/><!-- anglesite:comments --></article>\n"
                .write(to: root.appendingPathComponent("src/layouts/BlogPost.astro"), atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test func descriptorsExposesCatalog() {
        let ops = IntegrationOperations(sourceDirectory: { _ in nil }, templateDirectory: { nil })
        #expect(ops.descriptors().count == 3)
    }

    @Test func planThenApplySucceedsForGiscus() async {
        let src = makeSource(withBlogLayout: true)
        let tmpl = makeTemplate()
        let ops = IntegrationOperations(sourceDirectory: { _ in src }, templateDirectory: { tmpl })
        let answers: Answers = ["repo": "o/r", "repoId": "R", "category": "General", "categoryId": "C", "mapping": "pathname"]
        guard case .success(let plan) = await ops.plan(integrationID: .giscus, answers: answers, siteID: "s1") else {
            Issue.record("plan failed"); return
        }
        let terminal = await ops.apply(plan, siteID: "s1")
        #expect(terminal == .done(integrationID: "giscus"))
        let layout = try! String(contentsOf: src.appendingPathComponent("src/layouts/BlogPost.astro"), encoding: .utf8)
        #expect(layout.contains("<Comments"))
    }

    @Test func planFailsWhenSiteNotFound() async {
        let ops = IntegrationOperations(sourceDirectory: { _ in nil }, templateDirectory: { self.makeTemplate() })
        let r = await ops.plan(integrationID: .giscus, answers: [:], siteID: "missing")
        #expect(r == .failure(.providerRequired) || { if case .failure = r { return true }; return false }())
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter IntegrationOperationsTests`
Expected: FAIL — `cannot find 'IntegrationOperations' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/AnglesiteCore/IntegrationOperationsService.swift
import Foundation

public protocol IntegrationOperationsService: Sendable {
    func descriptors() -> [IntegrationDescriptor]
    func plan(integrationID: IntegrationID, answers: Answers, siteID: String) async -> Result<OperationPlan, IntegrationError>
    func apply(_ plan: OperationPlan, siteID: String) async -> IntegrationScaffolder.SetupStep
}

public struct IntegrationOperations: IntegrationOperationsService {
    public enum OpError: Error, Equatable { case siteNotFound, templateMissing }

    private let sourceDirectory: @Sendable (String) async -> URL?
    private let templateDirectory: @Sendable () -> URL?
    private let scaffolder: IntegrationScaffolder

    public init(sourceDirectory: @escaping @Sendable (String) async -> URL?,
                templateDirectory: @escaping @Sendable () -> URL?) {
        self.sourceDirectory = sourceDirectory
        self.templateDirectory = templateDirectory
        self.scaffolder = IntegrationScaffolder()
    }

    public func descriptors() -> [IntegrationDescriptor] { IntegrationCatalog.all }

    public func plan(integrationID: IntegrationID, answers: Answers, siteID: String) async -> Result<OperationPlan, IntegrationError> {
        guard let source = await sourceDirectory(siteID) else { return .failure(.providerRequired) /* see note */ }
        guard let template = templateDirectory() else { return .failure(.providerRequired) /* see note */ }
        return IntegrationPlanner.plan(descriptor: IntegrationCatalog.descriptor(for: integrationID),
                                       answers: answers, sourceDirectory: source, templateDirectory: template)
    }

    public func apply(_ plan: OperationPlan, siteID: String) async -> IntegrationScaffolder.SetupStep {
        guard let source = await sourceDirectory(siteID) else {
            return .failed(step: "resolve", message: "Couldn't find that site.")
        }
        var terminal: IntegrationScaffolder.SetupStep = .failed(step: "apply", message: "No steps ran.")
        for await s in scaffolder.apply(plan, in: source) {
            if case .done = s { terminal = s }
            if case .failed = s { terminal = s }
        }
        return terminal
    }
}
```

- [ ] **Step 3a: Add the two new `IntegrationError` cases (required before this compiles)**

`IntegrationError` (defined in Task 5's `IntegrationPlan.swift`) has only `missingRequiredField`,
`invalidValue`, `unknownProvider`, `providerRequired`. The `IntegrationOperations.plan`/`apply`
above need site- and template-resolution failures, and Task 10's `reply(for:)` switches
exhaustively over `IntegrationError`. Add both cases to the enum in `IntegrationPlan.swift`:

```swift
public enum IntegrationError: Error, Equatable, Sendable {
    case missingRequiredField(key: String)
    case invalidValue(key: String, reason: String)
    case unknownProvider(String)
    case providerRequired
    case siteNotFound          // <-- add
    case templateUnavailable   // <-- add
}
```

Then in `IntegrationOperations.plan`, return `.failure(.siteNotFound)` when `sourceDirectory(siteID)`
is nil and `.failure(.templateUnavailable)` when `templateDirectory()` is nil (replace the
placeholder `.providerRequired` returns shown above). Set the `planFailsWhenSiteNotFound` test to
`#expect(r == .failure(.siteNotFound))`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter "IntegrationOperationsTests IntegrationPlannerTests"`
Expected: PASS (both suites — the added enum cases don't break existing planner tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/IntegrationOperationsService.swift Sources/AnglesiteCore/IntegrationPlan.swift Tests/AnglesiteCoreTests/IntegrationOperationsTests.swift
git commit -m "feat(bucket3): IntegrationOperationsService seam + live impl

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: `IntegrationWizardModel` — observable step machine

**Files:**
- Create: `Sources/AnglesiteCore/IntegrationWizardModel.swift`
- Test: `Tests/AnglesiteCoreTests/IntegrationWizardModelTests.swift`

**Interfaces:**
- Consumes: Task 1 types, Task 8 service.
- Produces: the model the GUI view (Task 13) binds to. Mirrors `NewSiteWizardModel` conventions (`@MainActor @Observable`, `Step: Int, CaseIterable`, `advance()/back()`, `build(using:)`).

```swift
@MainActor @Observable
public final class IntegrationWizardModel {
    public enum Step: Int, CaseIterable { case pickIntegration, pickProvider, fields, review, applying }
    public var step: Step
    public var selectedID: IntegrationID?
    public var answers: Answers
    public private(set) var plan: OperationPlan?
    public private(set) var progress: [IntegrationScaffolder.SetupStep]
    public init(service: any IntegrationOperationsService, siteID: String)
    public var descriptor: IntegrationDescriptor? { get }
    public var visibleFields: [Field] { get }     // fields whose visibleWhen passes for current answers
    public var canContinue: Bool { get }
    public func advance() async                   // on entering .review, computes plan via service
    public func back()
    public func apply() async                     // runs service.apply; appends terminal step
}
```

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/IntegrationWizardModelTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@MainActor @Suite struct IntegrationWizardModelTests {
    /// Fake service: returns a fixed plan and terminal step without touching disk.
    struct FakeService: IntegrationOperationsService {
        func descriptors() -> [IntegrationDescriptor] { IntegrationCatalog.all }
        func plan(integrationID: IntegrationID, answers: Answers, siteID: String) async -> Result<OperationPlan, IntegrationError> {
            .success(OperationPlan(integrationID: integrationID, steps: [.addCSP(["x.com"])], warnings: []))
        }
        func apply(_ plan: OperationPlan, siteID: String) async -> IntegrationScaffolder.SetupStep {
            .done(integrationID: plan.integrationID.rawValue)
        }
    }

    @Test func visibleFieldsHonorConditions() {
        let m = IntegrationWizardModel(service: FakeService(), siteID: "s")
        m.selectedID = .booking
        m.answers = ["provider": "cal", "style": "inline"]
        #expect(!m.visibleFields.contains { $0.key == "buttonText" })  // floating-only
        m.answers["style"] = "floating"
        #expect(m.visibleFields.contains { $0.key == "buttonText" })
    }

    @Test func advanceToReviewComputesPlan() async {
        let m = IntegrationWizardModel(service: FakeService(), siteID: "s")
        m.selectedID = .booking
        m.step = .fields
        m.answers = ["provider": "cal", "username": "jane", "style": "inline"]
        await m.advance()  // fields -> review
        #expect(m.step == .review)
        #expect(m.plan != nil)
    }

    @Test func applyRecordsTerminalStep() async {
        let m = IntegrationWizardModel(service: FakeService(), siteID: "s")
        m.selectedID = .giscus
        m.plan = OperationPlan(integrationID: .giscus, steps: [], warnings: [])
        await m.apply()
        #expect(m.progress.contains(.done(integrationID: "giscus")))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter IntegrationWizardModelTests`
Expected: FAIL — `cannot find 'IntegrationWizardModel' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/AnglesiteCore/IntegrationWizardModel.swift
import Foundation
import Observation

@MainActor @Observable
public final class IntegrationWizardModel {
    public enum Step: Int, CaseIterable { case pickIntegration, pickProvider, fields, review, applying }

    public var step: Step = .pickIntegration
    public var selectedID: IntegrationID?
    public var answers: Answers = [:]
    public private(set) var plan: OperationPlan?
    public private(set) var progress: [IntegrationScaffolder.SetupStep] = []

    private let service: any IntegrationOperationsService
    private let siteID: String

    public init(service: any IntegrationOperationsService, siteID: String) {
        self.service = service
        self.siteID = siteID
    }

    public var descriptor: IntegrationDescriptor? {
        guard let id = selectedID else { return nil }
        return service.descriptors().first { $0.id == id }
    }

    public var visibleFields: [Field] {
        guard let descriptor else { return [] }
        let provider = answers["provider"]
        return descriptor.fields.filter { IntegrationPlanner.isVisible($0.visibleWhen, answers: answers, providerID: provider) }
    }

    public var canContinue: Bool {
        switch step {
        case .pickIntegration: return selectedID != nil
        case .pickProvider: return descriptor?.providers.isEmpty == true || answers["provider"] != nil
        case .fields:
            return visibleFields.allSatisfy { $0.isOptional || !($0.value(in: answers)).isEmpty }
        case .review: return plan != nil
        case .applying: return false
        }
    }

    public func advance() async {
        // Skip the provider step for provider-less integrations (e.g. giscus).
        if step == .pickIntegration, descriptor?.providers.isEmpty == true {
            step = .fields; return
        }
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        step = next
        if step == .review, let id = selectedID {
            if case .success(let p) = await service.plan(integrationID: id, answers: answers, siteID: siteID) {
                plan = p
            }
        }
    }

    public func back() { if let prev = Step(rawValue: step.rawValue - 1) { step = prev } }

    public func apply() async {
        guard let plan else { return }
        step = .applying
        let terminal = await service.apply(plan, siteID: siteID)
        progress.append(terminal)
    }
}

private extension Field {
    func value(in answers: Answers) -> String { answers[key] ?? defaultValue ?? "" }
}
```

`IntegrationPlanner.isVisible` is currently declared `static` but file-internal (`static func`).
Make it `public static` so the model (same module, but referenced from a `public` computed
property's body — fine) — it is already `internal`; keep `internal` since the model is in the same
module. No change needed if both are in `AnglesiteCore` (they are). Confirm `isVisible` is not
`private`; in Task 5 it is declared `static func` (internal) — leave as is.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter IntegrationWizardModelTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/IntegrationWizardModel.swift Tests/AnglesiteCoreTests/IntegrationWizardModelTests.swift
git commit -m "feat(bucket3): IntegrationWizardModel observable step machine

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: `SetupIntegrationTool` — FM chat front-door

**Files:**
- Create: `Sources/AnglesiteCore/SetupIntegrationTool.swift`
- Test: `Tests/AnglesiteCoreTests/SetupIntegrationToolTests.swift`

**Interfaces:**
- Consumes: Task 8 service.
- Produces: a FoundationModels `Tool` (gated `#if compiler(>=6.4)`) that plans (re-prompting for
  missing fields) and returns the plan summary **without auto-applying** (confirm-in-chat parity).

```swift
#if compiler(>=6.4)
public struct SetupIntegrationTool: Tool, Sendable {
    public static let toolName = "setupIntegration"
    public let name = SetupIntegrationTool.toolName
    public let description: String
    @Generable public struct Arguments {
        @Guide(description: "Integration to add: 'booking', 'donations', or 'giscus'.") public var integrationType: String
        @Guide(description: "Provider id when the integration needs one (e.g. 'cal', 'calendly', 'stripe').") public var provider: String?
        @Guide(description: "Field values as key=value pairs, comma-separated (e.g. 'username=jane,style=inline').") public var config: String?
    }
    public init(service: any IntegrationOperationsService, siteID: String)
    public func call(arguments: Arguments) async throws -> String
}
#endif
```

The tool is gated, so its tests are gated too (they run only on the Xcode-27 toolchain). The
`call` logic that builds `answers` from the `config` string and decides re-prompt-vs-summary is
factored into a **non-gated** pure helper so it's testable on CI.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/SetupIntegrationToolTests.swift
import Testing
@testable import AnglesiteCore

@Suite struct SetupIntegrationToolTests {
    @Test func parsesConfigString() {
        let a = SetupIntegrationArguments.parseConfig("username=jane, style=inline ,empty=")
        #expect(a["username"] == "jane")
        #expect(a["style"] == "inline")
        #expect(a["empty"] == "")
    }

    @Test func mapsIntegrationTypeToID() {
        #expect(SetupIntegrationArguments.id(for: "booking") == .booking)
        #expect(SetupIntegrationArguments.id(for: "Comments") == nil)  // only exact ids
    }

    @Test func describesMissingFieldAsPrompt() {
        // Given a planner failure, the tool turns it into a user-facing re-prompt string.
        let s = SetupIntegrationArguments.reply(for: .failure(.missingRequiredField(key: "username")),
                                                descriptor: IntegrationCatalog.descriptor(for: .booking))
        #expect(s.contains("Username"))
    }

    @Test func describesPlanAsConfirmation() {
        let plan = OperationPlan(integrationID: .giscus, steps: [.addCSP(["giscus.app"])], warnings: [])
        let s = SetupIntegrationArguments.reply(for: .success(plan),
                                                descriptor: IntegrationCatalog.descriptor(for: .giscus))
        #expect(s.contains("Allow 1 domain"))
        #expect(s.lowercased().contains("confirm") || s.lowercased().contains("apply"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter SetupIntegrationToolTests`
Expected: FAIL — `cannot find 'SetupIntegrationArguments' in scope`.

- [ ] **Step 3: Write minimal implementation**

Put the pure helper **outside** the compiler gate (so CI compiles/tests it), and the `Tool`
conformance **inside** the gate.

```swift
// Sources/AnglesiteCore/SetupIntegrationTool.swift
import Foundation

/// Pure, non-gated helpers for the FM tool, so the parse/reply logic is unit-testable on CI.
public enum SetupIntegrationArguments {
    public static func parseConfig(_ raw: String?) -> Answers {
        guard let raw, !raw.isEmpty else { return [:] }
        var out: Answers = [:]
        for pair in raw.split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { continue }
            out[kv[0].trimmingCharacters(in: .whitespaces)] = kv[1].trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    public static func id(for type: String) -> IntegrationID? { IntegrationID(rawValue: type) }

    /// Turn a plan result into a chat reply: re-prompt on missing field, else a confirm-before-apply summary.
    public static func reply(for result: Result<OperationPlan, IntegrationError>,
                             descriptor: IntegrationDescriptor) -> String {
        switch result {
        case .success(let plan):
            return "Here's what I'll set up:\n\(plan.summary)\n\nConfirm to apply, or tell me what to change."
        case .failure(.missingRequiredField(let key)):
            let label = descriptor.fields.first { $0.key == key }?.label ?? key
            return "I need the \(label) to continue."
        case .failure(.providerRequired):
            let names = descriptor.providers.map(\.displayName).joined(separator: ", ")
            return "Which provider would you like? Options: \(names)."
        case .failure(.unknownProvider(let p)):
            return "I don't recognize the provider \"\(p)\"."
        case .failure(.invalidValue(let key, let reason)):
            let label = descriptor.fields.first { $0.key == key }?.label ?? key
            return "The \(label) looks off — \(reason)."
        case .failure(.siteNotFound):
            return "I couldn't find that site."
        case .failure(.templateUnavailable):
            return "The site template isn't available right now."
        }
    }
}

#if compiler(>=6.4)
import FoundationModels

public struct SetupIntegrationTool: Tool, Sendable {
    public static let toolName = "setupIntegration"
    public let name = SetupIntegrationTool.toolName
    public let description = "Set up a website integration (booking, donations, or giscus comments). Returns a plan to confirm before applying."

    @Generable
    public struct Arguments {
        @Guide(description: "Integration to add: 'booking', 'donations', or 'giscus'.")
        public var integrationType: String
        @Guide(description: "Provider id when the integration needs one (e.g. 'cal', 'calendly', 'stripe').")
        public var provider: String?
        @Guide(description: "Field values as key=value pairs, comma-separated (e.g. 'username=jane,style=inline').")
        public var config: String?
    }

    private let service: any IntegrationOperationsService
    private let siteID: String
    public init(service: any IntegrationOperationsService, siteID: String) {
        self.service = service; self.siteID = siteID
    }

    public func call(arguments: Arguments) async throws -> String {
        guard let id = SetupIntegrationArguments.id(for: arguments.integrationType) else {
            return "I can set up booking, donations, or giscus comments. Which one?"
        }
        var answers = SetupIntegrationArguments.parseConfig(arguments.config)
        if let p = arguments.provider { answers["provider"] = p }
        let result = await service.plan(integrationID: id, answers: answers, siteID: siteID)
        return SetupIntegrationArguments.reply(for: result, descriptor: IntegrationCatalog.descriptor(for: id))
    }
}
#endif
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter SetupIntegrationToolTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SetupIntegrationTool.swift Tests/AnglesiteCoreTests/SetupIntegrationToolTests.swift
git commit -m "feat(bucket3): SetupIntegrationTool (FM front-door) + pure reply helpers

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 11: App Intents + dialogs + override seam

**Files:**
- Create: `Sources/AnglesiteIntents/IntegrationIntents.swift`
- Create: `Sources/AnglesiteIntents/IntegrationOperationsOverride.swift`
- Test: `Tests/AnglesiteIntentsTests/IntegrationIntentsTests.swift`

**Interfaces:**
- Consumes: Task 8 service (`@Dependency`), Task 1 `IntegrationID`.
- Produces: `AddBookingIntent`, `AddDonationsIntent`, `AddGiscusIntent`; `IntegrationDialogs` (pure);
  `IntegrationOperationsOverride.scoped` (`@TaskLocal`). Mirrors `AddPageIntent` + `ContentDialogs` +
  `ContentOperationsOverride`.

**Notes for the implementer:**
- `SiteEntity` already exists at `Sources/AnglesiteIntents/SiteEntity.swift` (used by the existing
  `SiteIntents`/`ContentIntents`). Reuse it — do not define a new one. It carries `id` and
  `displayName`.
- **Deliberate API reduction:** `AddGiscusIntent` hardcodes `category: "Announcements"` and
  `mapping: "pathname"` rather than exposing them as `@Parameter`s, to keep the Siri surface
  small. This does NOT delegate to the descriptor's `defaultValue`s (those drive the GUI/FM
  paths only). If a later iteration wants Siri control over category/mapping, add the
  `@Parameter`s then. Keep this simplification for v1 and leave a code comment saying so.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteIntentsTests/IntegrationIntentsTests.swift
import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteIntents

@Suite struct IntegrationIntentsTests {
    struct FakeService: IntegrationOperationsService {
        let terminal: IntegrationScaffolder.SetupStep
        func descriptors() -> [IntegrationDescriptor] { IntegrationCatalog.all }
        func plan(integrationID: IntegrationID, answers: Answers, siteID: String) async -> Result<OperationPlan, IntegrationError> {
            .success(OperationPlan(integrationID: integrationID, steps: [.addCSP(["x"])], warnings: []))
        }
        func apply(_ plan: OperationPlan, siteID: String) async -> IntegrationScaffolder.SetupStep { terminal }
    }

    @Test func bookingIntentBuildsAnswersAndReportsSuccess() async throws {
        let intent = AddBookingIntent()
        intent.site = SiteEntity(id: "s1", displayName: "Acme")
        intent.username = "jane"
        intent.provider = "cal"
        intent.style = "inline"
        let dialog = try await IntegrationOperationsOverride.$scoped.withValue(FakeService(terminal: .done(integrationID: "booking"))) {
            try await intent.confirmAndApplyForTesting()  // test-only helper that skips requestConfirmation
        }
        #expect(dialog.contains("booking") || dialog.contains("Acme"))
    }

    @Test func dialogsCoverSuccessAndFailure() {
        #expect(IntegrationDialogs.applied(integration: "booking", siteName: "Acme").contains("Acme"))
        #expect(IntegrationDialogs.failed(reason: "nope", siteName: "Acme").contains("nope"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter IntegrationIntentsTests`
Expected: FAIL — `cannot find 'AddBookingIntent' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/AnglesiteIntents/IntegrationOperationsOverride.swift
import AnglesiteCore
public enum IntegrationOperationsOverride {
    @TaskLocal public static var scoped: (any IntegrationOperationsService)?
}
```

```swift
// Sources/AnglesiteIntents/IntegrationIntents.swift
import AppIntents
import AnglesiteCore
import Foundation

public enum IntegrationDialogs {
    public static func applied(integration: String, siteName: String) -> String {
        "Set up \(integration) on \(siteName)."
    }
    public static func failed(reason: String, siteName: String) -> String {
        "Couldn’t finish that on \(siteName): \(reason)"
    }
    public static func planPrompt(summary: String) -> String { "Here’s the plan:\n\(summary)" }
}

public struct AddBookingIntent: AppIntent {
    public static let title: LocalizedStringResource = "Add Booking"
    public static let description = IntentDescription("Add a Cal.com or Calendly booking widget to a site.")
    @Parameter(title: "Site") public var site: SiteEntity
    @Parameter(title: "Provider", description: "cal or calendly.") public var provider: String
    @Parameter(title: "Username") public var username: String
    @Parameter(title: "Placement", description: "inline, floating, or button.") public var style: String?
    @Dependency private var ops: any IntegrationOperationsService
    public init() {}
    public static var parameterSummary: some ParameterSummary { Summary("Add booking to \(\.$site)") }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let answers: Answers = ["provider": provider, "username": username, "style": style ?? "inline"]
        return try await Self.run(ops: IntegrationOperationsOverride.scoped ?? ops, id: .booking,
                                  answers: answers, site: site, requestConfirm: { try await $0() })
    }

    // Shared runner: plan -> (confirm) -> apply -> dialog. `requestConfirm` is injected so tests skip the AppIntents gate.
    static func run(ops: any IntegrationOperationsService, id: IntegrationID, answers: Answers,
                    site: SiteEntity, requestConfirm: (@escaping () async throws -> Void) async throws -> Void)
    async throws -> some IntentResult & ProvidesDialog {
        switch await ops.plan(integrationID: id, answers: answers, siteID: site.id) {
        case .failure(let e):
            return .result(dialog: IntentDialog(stringLiteral: IntegrationDialogs.failed(reason: "\(e)", siteName: site.displayName)))
        case .success(let plan):
            try await requestConfirm { /* confirmation acknowledged */ }
            let terminal = await ops.apply(plan, siteID: site.id)
            switch terminal {
            case .done(let integrationID):
                return .result(dialog: IntentDialog(stringLiteral: IntegrationDialogs.applied(integration: integrationID, siteName: site.displayName)))
            case .failed(_, let message):
                return .result(dialog: IntentDialog(stringLiteral: IntegrationDialogs.failed(reason: message, siteName: site.displayName)))
            default:
                return .result(dialog: IntentDialog(stringLiteral: IntegrationDialogs.failed(reason: "incomplete", siteName: site.displayName)))
            }
        }
    }
}

// AddDonationsIntent and AddGiscusIntent follow the same shape: build `answers` from their
// @Parameters, call `AddBookingIntent.run(ops:id:.donations/.giscus:...)`.
public struct AddDonationsIntent: AppIntent {
    public static let title: LocalizedStringResource = "Add Donations"
    public static let description = IntentDescription("Add a donation button to a site.")
    @Parameter(title: "Site") public var site: SiteEntity
    @Parameter(title: "Provider", description: "stripe, liberapay, or githubSponsors.") public var provider: String
    @Parameter(title: "Donation link") public var link: String
    @Dependency private var ops: any IntegrationOperationsService
    public init() {}
    public static var parameterSummary: some ParameterSummary { Summary("Add donations to \(\.$site)") }
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let answers: Answers = ["provider": provider, "link": link]
        return try await AddBookingIntent.run(ops: IntegrationOperationsOverride.scoped ?? ops, id: .donations,
                                              answers: answers, site: site, requestConfirm: { try await $0() })
    }
}

public struct AddGiscusIntent: AppIntent {
    public static let title: LocalizedStringResource = "Add Comments"
    public static let description = IntentDescription("Add giscus comments to a site’s blog posts.")
    @Parameter(title: "Site") public var site: SiteEntity
    @Parameter(title: "Repository", description: "owner/repo.") public var repo: String
    @Parameter(title: "Repository ID") public var repoId: String
    @Parameter(title: "Category ID") public var categoryId: String
    @Dependency private var ops: any IntegrationOperationsService
    public init() {}
    public static var parameterSummary: some ParameterSummary { Summary("Add comments to \(\.$site)") }
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let answers: Answers = ["repo": repo, "repoId": repoId, "category": "Announcements",
                                "categoryId": categoryId, "mapping": "pathname"]
        return try await AddBookingIntent.run(ops: IntegrationOperationsOverride.scoped ?? ops, id: .giscus,
                                              answers: answers, site: site, requestConfirm: { try await $0() })
    }
}

// Test-only convenience matching the test in Step 1.
extension AddBookingIntent {
    func confirmAndApplyForTesting() async throws -> String {
        let answers: Answers = ["provider": provider, "username": username, "style": style ?? "inline"]
        let ops = IntegrationOperationsOverride.scoped!
        guard case .success(let plan) = await ops.plan(integrationID: .booking, answers: answers, siteID: site.id) else { return "plan failed" }
        let terminal = await ops.apply(plan, siteID: site.id)
        if case .done(let id) = terminal { return IntegrationDialogs.applied(integration: id, siteName: site.displayName) }
        return "failed"
    }
}
```

Note: production `perform()` must use the real AppIntents `requestConfirmation(...)`. The injected
`requestConfirm` closure here is a seam so the unit test can drive plan→apply without the AppIntents
runtime. In production wiring (no override bound), replace the `requestConfirm` closure body with a
real `try await requestConfirmation(result: .result(dialog: ...))` call — do this when integrating,
and keep the override path test-only. Register the three intents in `AnglesiteShortcuts.swift`
(add `AppShortcut` entries) so Siri surfaces them.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter IntegrationIntentsTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteIntents/IntegrationIntents.swift Sources/AnglesiteIntents/IntegrationOperationsOverride.swift Tests/AnglesiteIntentsTests/IntegrationIntentsTests.swift
git commit -m "feat(bucket3): booking/donations/giscus App Intents + dialogs

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 12: Template anchors + component/page files

**Files:**
- Modify: `Resources/Template/src/layouts/BaseLayout.astro` (add `<!-- anglesite:body-end -->` before `</body>`)
- Modify (or create): `Resources/Template/src/layouts/BlogPost.astro` (add `<!-- anglesite:comments -->`)
- Verify/create: `Resources/Template/src/components/BookingWidget.astro`, `DonationButton.astro`, `Comments.astro`
- Verify/create: `Resources/Template/src/pages/book.astro`, `donate.astro`
- Test: `Tests/AnglesiteCoreTests/IntegrationTemplateAssetsTests.swift`

**Interfaces:**
- Consumes: `TemplateRuntime.resolve()` to locate the template root.
- Produces: the on-disk assets that Task 5's `copyFile` reads and Task 7's `injectAnchor` targets.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/IntegrationTemplateAssetsTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct IntegrationTemplateAssetsTests {
    /// Resolves the bundled/override template; skips with a clear message only if absent (mirrors
    /// the project's e2e tests that require the template to be present).
    func templateRoot() throws -> URL {
        guard let url = TemplateRuntime.resolve().url else {
            throw TemplateMissing.notFound
        }
        return url
    }
    enum TemplateMissing: Error { case notFound }

    @Test func requiredAssetsExist() throws {
        let root = try templateRoot()
        for p in ["src/components/BookingWidget.astro", "src/components/DonationButton.astro",
                  "src/components/Comments.astro", "src/pages/book.astro", "src/pages/donate.astro"] {
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(p).path), "missing \(p)")
        }
    }

    @Test func layoutsHaveAnchors() throws {
        let root = try templateRoot()
        let base = try String(contentsOf: root.appendingPathComponent("src/layouts/BaseLayout.astro"), encoding: .utf8)
        #expect(base.contains("<!-- anglesite:body-end -->"))
        let blog = try String(contentsOf: root.appendingPathComponent("src/layouts/BlogPost.astro"), encoding: .utf8)
        #expect(blog.contains("<!-- anglesite:comments -->"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter IntegrationTemplateAssetsTests`
Expected: FAIL — anchors absent and/or component files missing. (If `TemplateRuntime.resolve()`
returns `.missing` in the SwiftPM test context, set the Settings template override path or run with
the bundled resources available; the test throws `TemplateMissing.notFound`, which Swift Testing
records as an issue — matching how the project's other template-dependent tests behave.)

- [ ] **Step 3: Make the changes**

1. In `Resources/Template/src/layouts/BaseLayout.astro`, add the anchor immediately before `</body>`:

```astro
  <!-- anglesite:body-end -->
</body>
```

2. Ensure `Resources/Template/src/layouts/BlogPost.astro` exists and contains the comments anchor at
the end of the article body:

```astro
  <slot />
  <!-- anglesite:comments -->
</article>
```

3. Port the three components and two pages from the plugin template into `Resources/Template/`.
The plugin checkout path is **`$ANGLESITE_PLUGIN_SRC`** (per CLAUDE.md — do not hardcode an
absolute path; it differs per machine and is unset in CI). Sources:
`$ANGLESITE_PLUGIN_SRC/template/src/components/BookingWidget.astro`,
`$ANGLESITE_PLUGIN_SRC/template/src/components/DonationButton.astro`,
`$ANGLESITE_PLUGIN_SRC/template/src/components/Comments.astro`, and the `book`/`donate` pages
under `$ANGLESITE_PLUGIN_SRC/template/src/pages/`. Each component reads its props from
`Astro.props` (already provider-aware in the plugin template — verified for `Comments.astro`). If
a component is absent in the plugin, create a minimal Astro component that renders the provider
embed from props — full embed code is in the plugin's `template/scripts/booking.ts` / `donations`
helpers; copy those helpers' output verbatim into the component.

4. The `book.astro` / `donate.astro` pages import and render the component:

```astro
---
import BaseLayout from "../layouts/BaseLayout.astro";
import BookingWidget from "../components/BookingWidget.astro";
---
<BaseLayout title="Book a time">
  <BookingWidget provider={import.meta.env.BOOKING_PROVIDER} username={import.meta.env.BOOKING_USERNAME} style="inline" client:load />
</BaseLayout>
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter IntegrationTemplateAssetsTests`
Expected: PASS (2 tests), assuming the template resolves in the test environment.

- [ ] **Step 5: Commit**

```bash
git add Resources/Template Tests/AnglesiteCoreTests/IntegrationTemplateAssetsTests.swift
git commit -m "feat(bucket3): template anchors + booking/donations/giscus assets

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 13: Wire-up — Bootstrap, FM assistant, GUI wizard

**Files:**
- Modify: `Sources/AnglesiteIntents/Bootstrap.swift` (register `IntegrationOperationsService`)
- Modify: `Sources/AnglesiteCore/FoundationModelAssistant.swift` (optional `integrationService`; attach tool)
- Create: `Sources/AnglesiteApp/IntegrationWizard.swift` (SwiftUI view)
- Modify: `Sources/AnglesiteApp/SiteActions.swift` (menu command to present the wizard)

**Interfaces:**
- Consumes: everything from Tasks 8–10.
- Produces: the running app surfaces. This task is **app-target wiring** — not CI-tested (hosted-app
  limitation). Verification is a clean build of both schemes.

- [ ] **Step 1: Add a single `IntegrationOperations.live` factory, then register it in `Bootstrap.swift`**

To avoid two divergent construction sites (the App Intents DI registration and the GUI), define
ONE production factory in `AnglesiteCore` (in `IntegrationOperationsService.swift`) and use it from
both front-doors:

```swift
public extension IntegrationOperations {
    /// The production instance: resolves a site id to its `Source/` dir via `SiteStore.shared`
    /// and the template root via `TemplateRuntime`. Single construction path for every front-door.
    static func live() -> IntegrationOperations {
        IntegrationOperations(
            sourceDirectory: { id in await SiteStore.shared.find(id: id)?.sourceDirectory },
            templateDirectory: { TemplateRuntime.resolve().url }
        )
    }
}
```

Then in `Bootstrap.swift`, after the `NativeContentOperations` registration block:

```swift
AppDependencyManager.shared.add { () -> any IntegrationOperationsService in
    IntegrationOperations.live()
}
```

- [ ] **Step 2: Attach `SetupIntegrationTool` in `FoundationModelAssistant.swift`**

Add a stored `private let integrationService: (any IntegrationOperationsService)?` and an `init`
parameter `integrationService: (any IntegrationOperationsService)? = nil`. In `makeSession`, after the
`editBridge`/`contentGraph` block:

```swift
if let integrationService {
    tools.append(SetupIntegrationTool(service: integrationService, siteID: context.siteID))
}
```

In `attachedToolNames`, append `SetupIntegrationTool.toolName` when `integrationService != nil`.
Pass the service from `ChatModel` where the assistant is constructed.

- [ ] **Step 3: Create the GUI wizard view**

```swift
// Sources/AnglesiteApp/IntegrationWizard.swift
import SwiftUI
import AnglesiteCore

struct IntegrationWizard: View {
    @Bindable var model: IntegrationWizardModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            switch model.step {
            case .pickIntegration: pickIntegration
            case .pickProvider: pickProvider
            case .fields: fields
            case .review: review
            case .applying: applying
            }
            Divider()
            footer
        }
        .frame(width: 520, height: 460)
    }

    private var pickIntegration: some View {
        List(model.descriptorsForPicker, id: \.id, selection: Binding(
            get: { model.selectedID }, set: { model.selectedID = $0 })) { d in
            VStack(alignment: .leading) { Text(d.displayName).font(.headline); Text(d.summary).font(.caption) }
        }
    }
    private var pickProvider: some View {
        Picker("Provider", selection: Binding(
            get: { model.answers["provider"] ?? "" }, set: { model.answers["provider"] = $0 })) {
            ForEach(model.descriptor?.providers ?? [], id: \.id) { Text($0.displayName).tag($0.id) }
        }.pickerStyle(.inline)
    }
    private var fields: some View {
        Form {
            ForEach(model.visibleFields) { field in
                fieldRow(field)
            }
        }
    }
    @ViewBuilder private func fieldRow(_ field: Field) -> some View {
        let binding = Binding(get: { model.answers[field.key] ?? field.defaultValue ?? "" },
                              set: { model.answers[field.key] = $0 })
        switch field.kind {
        case .text, .email, .url: TextField(field.label, text: binding)
        case .bool: Toggle(field.label, isOn: Binding(get: { binding.wrappedValue == "true" },
                                                      set: { binding.wrappedValue = $0 ? "true" : "false" }))
        case .choice(let choices):
            Picker(field.label, selection: binding) { ForEach(choices, id: \.value) { Text($0.label).tag($0.value) } }
        }
    }
    private var review: some View {
        ScrollView { Text(model.plan?.summary ?? "…").frame(maxWidth: .infinity, alignment: .leading).padding() }
    }
    private var applying: some View {
        VStack { ProgressView(); Text("Setting up…") }
    }

    @ViewBuilder private var footer: some View {
        HStack {
            if model.step != .pickIntegration && model.step != .applying { Button("Back") { model.back() } }
            Spacer()
            Button("Cancel") { onClose() }
            switch model.step {
            case .review:
                Button("Set Up") { Task { await model.apply(); onClose() } }
                    .keyboardShortcut(.defaultAction).disabled(!model.canContinue)
            case .applying: EmptyView()
            default:
                Button("Continue") { Task { await model.advance() } }
                    .keyboardShortcut(.defaultAction).disabled(!model.canContinue)
            }
        }.padding(.horizontal, 16).padding(.vertical, 10)
    }
}
```

Add a small accessor on the model for the picker list:

```swift
// Add to IntegrationWizardModel
public var descriptorsForPicker: [IntegrationDescriptor] { service.descriptors() }
```

- [ ] **Step 4: Present the wizard from a menu command**

In `SiteActions.swift` (or the site window's toolbar/menu), add a command that constructs the model
and presents the sheet:

```swift
// Where site commands are built (needs the focused site's id):
Button("Add Integration…") {
    // Use the SAME single production factory the Bootstrap DI registration uses — do NOT
    // re-inline the closures here (that would duplicate construction and drift from the
    // registered service). The model takes `service:` so tests inject a fake; production
    // passes `.live()`.
    let model = IntegrationWizardModel(service: IntegrationOperations.live(), siteID: focusedSiteID)
    // present `IntegrationWizard(model: model, onClose: { dismiss sheet })` via the window's sheet state
}
```

(Follow the exact sheet-presentation pattern already used for `NewSiteWizard` / `PublishSheet` in the
site window — a `@State` flag gating `.sheet(isPresented:)`. `NewSiteWizard` likewise constructs its
model with shared collaborators in the app target; routing both the GUI and DI through
`IntegrationOperations.live()` keeps a single construction path while staying consistent with that
established wizard pattern.)

- [ ] **Step 5: Build both schemes to verify wiring**

Run:
```bash
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build
```
Expected: BUILD SUCCEEDED for both. (MAS compiles chat out, so the FM-tool wiring must stay behind
the existing chat gating; the App Intent + GUI wizard front-doors remain in MAS.)

- [ ] **Step 6: Run the full Core + Intents test suites**

Run: `swift test --package-path .`
Expected: all prior suites green; new suites included.

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteIntents/Bootstrap.swift Sources/AnglesiteCore/FoundationModelAssistant.swift Sources/AnglesiteApp/IntegrationWizard.swift Sources/AnglesiteApp/SiteActions.swift Sources/AnglesiteCore/IntegrationWizardModel.swift
git commit -m "feat(bucket3): wire integration wizard into Bootstrap, FM chat, and GUI

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**1. Spec coverage:** (all `§` references below are sections of the design doc,
`docs/superpowers/specs/2026-06-20-bucket3-wizard-framework-design.md`, not this plan.)
- §3 architecture (one capability, three front-doors, Core engine) → Tasks 5–11, 13. ✓
- §4 descriptor model (all types) → Task 1; catalog → Task 4. ✓
- §5 plan→apply, OperationPlan, idempotency, failure model → Tasks 5–7. ✓
- §6 three front-doors (GUI/Intents/FM tool), shared service seam, confirm-before-write → Tasks 8–11, 13. ✓
- §7 template anchors + assets → Task 12. ✓
- §8 testing (descriptor validation, pure planner, plan equality/preview, apply idempotency, front-door thinness) → Tasks 4, 5, 6, 7, 9, 10, 11. ✓
- §9 out-of-scope honored: no Worker/secrets, no apply_edit reuse, no removal, only three integrations. ✓

**2. Placeholder scan:** No "TBD/handle errors/etc." — each step carries concrete code. Two
"see note" callouts (Task 5 `effective`-answers adjustment; Task 8 `IntegrationError` new cases)
are explicit instructions with the exact change, not vague placeholders.

**3. Type consistency checks performed & fixed inline:**
- `IntegrationError` cases used in Task 10's `reply(...)` (`siteNotFound`, `templateUnavailable`)
  are added in Task 8 — Task 8's note adds `siteNotFound` and `templateUnavailable`. ✓ (Names match.)
- `IntegrationScaffolder.SetupStep` `.done(integrationID:)` / `.failed(step:message:)` used
  consistently across Tasks 7, 8, 9, 11. ✓
- `Answers` typealias used identically in Tasks 5, 8, 9, 10, 11. ✓
- `IntegrationPlanner.isVisible(_:answers:providerID:)` referenced by Task 9 model — same module,
  internal visibility OK. ✓
- `OperationPlan(integrationID:steps:warnings:)` initializer shape consistent across test
  construction sites (Tasks 7, 9, 11). It needs a `public init` — **add a `public init` to
  `OperationPlan` in Task 5's `IntegrationPlan.swift`** (the struct's memberwise init is internal by
  default for a public struct). Likewise `PlannedStep`/`ConfigKV`/`PlanWarning` need public access;
  `ConfigKV`/`PlanWarning` already have public inits in Task 5. Add the `OperationPlan` public init
  during Task 5 implementation.

(One fix applied above: noted the required `OperationPlan` public init in Task 5.)

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-20-bucket3-wizard-framework.md`. Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.
