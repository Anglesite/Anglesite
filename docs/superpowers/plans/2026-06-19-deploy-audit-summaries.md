# On-device Deploy + Audit Summaries Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a deterministic one-line audit-findings summary and an on-device Foundation Models summary for *failed* deploys.

**Architecture:** All public/view-facing types are non-gated and live in `AnglesiteCore` for CI coverage; only the code that imports `FoundationModels` is wrapped in `#if compiler(>=6.4)`. A non-gated `DeployFailureSummarizing` protocol (taking plain `siteID`/`siteDirectory`) is the seam; the gated conformer builds an `AssistantContext` internally and calls the existing `FoundationModelAssistant.generateStructured`. `DeployModel`'s trigger logic is extracted into a CI-testable Core function, mirroring the `TokenOnboarding` precedent.

**Tech Stack:** Swift 6.4 / SwiftUI (macOS 27), Swift Testing (`@Test`/`#expect`), Apple FoundationModels (guided generation via `@Generable`).

## Global Constraints

- **`AnglesiteCore` must compile on the CI runner where `FoundationModels` is absent.** Anything that imports `FoundationModels`, uses `@Generable`/`@Guide`, or references `AssistantContext` MUST be inside `#if compiler(>=6.4)`. (Source: `ContentAssistant.swift` header comment; CLAUDE.md "swift test runs on CI's older runners".)
- **ES Modules / vanilla** — N/A (Swift only here).
- **Process spawning** — N/A (no subprocesses added).
- **No third-party deps** — Apple frameworks only.
- **Test framework:** Swift Testing (`import Testing`, `@Test`, `#expect`) — match the existing `AnglesiteCoreTests` style.
- **Run tests with:** `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter <TestName>` (the default CommandLineTools swift is too old — see memory `swift-toolchain-developer-dir`).
- **Commit style:** Conventional Commits; scope `(#93)`. End every commit body with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- **Existing types referenced (do not redefine):**
  - `AuditReport` with `findings: [Finding]`, `runnersExecuted: [Finding.Category]`, `runnersSkipped: [SkippedRunner]`; `Finding.Category` is `CaseIterable` in declaration order `[security, accessibility, performance, seo]` (rawValues lowercased); `Finding.Severity` is `[critical, warning, info]`. `Finding.init(category:severity:title:detail:remediation:location:)`. `SkippedRunner` has `category: Finding.Category`, `reason: String`.
  - `FoundationModelAssistant(tier: .onDevice).generateStructured(prompt:context:resultType:)` throws `AssistantError.unavailable(String)` when Apple Intelligence is off. (`AssistantError` and `AssistantContext` are both `#if compiler(>=6.4)`-gated.)
  - `AssistantContext(siteID:siteDirectory:)` (other params default).
  - `DeployModel` (`@MainActor @Observable`, `Sources/AnglesiteApp/DeployModel.swift`): `Phase.failed(reason:exitCode:)`, `Phase.succeeded(url:duration:)`, `logText: String`, `init(command:logCenter:keychain:verifier:)`.

---

### Task 1: Deterministic `AuditReport.summary`

**Files:**
- Modify: `Sources/AnglesiteCore/AuditReport.swift` (append an extension)
- Modify: `Sources/AnglesiteApp/AuditSheetView.swift` (render the summary line)
- Test: `Tests/AnglesiteCoreTests/AuditReportSummaryTests.swift` (create)

**Interfaces:**
- Consumes: existing `AuditReport`, `Finding.Category`, `SkippedRunner`.
- Produces: `var AuditReport.summary: String` — total (never throws), deterministic, stable for a given report.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/AuditReportSummaryTests.swift`:

```swift
import Testing
@testable import AnglesiteCore

private func finding(_ category: AuditReport.Finding.Category) -> AuditReport.Finding {
    AuditReport.Finding(category: category, severity: .warning, title: "t", detail: "d", remediation: nil, location: nil)
}

@Suite struct AuditReportSummaryTests {
    @Test func emptyReportSaysNoIssues() {
        let report = AuditReport(findings: [], runnersExecuted: [.seo], runnersSkipped: [])
        #expect(report.summary == "No issues found.")
    }

    @Test func singleFindingIsSingular() {
        let report = AuditReport(findings: [finding(.seo)], runnersExecuted: [.seo], runnersSkipped: [])
        #expect(report.summary == "1 SEO issue.")
    }

    @Test func countsByCategoryInCanonicalOrder() {
        let report = AuditReport(
            findings: [finding(.seo), finding(.seo), finding(.seo), finding(.accessibility)],
            runnersExecuted: [.accessibility, .seo],
            runnersSkipped: []
        )
        #expect(report.summary == "1 accessibility issue, 3 SEO issues.")
    }

    @Test func appendsSingleSkippedRunner() {
        let report = AuditReport(
            findings: [finding(.security), finding(.security)],
            runnersExecuted: [.security],
            runnersSkipped: [.init(category: .performance, reason: "Lighthouse missing")]
        )
        #expect(report.summary == "2 security issues. The performance check couldn't run.")
    }

    @Test func emptyFindingsWithSkippedRunners() {
        let report = AuditReport(
            findings: [],
            runnersExecuted: [.security],
            runnersSkipped: [.init(category: .performance, reason: "x"), .init(category: .seo, reason: "y")]
        )
        #expect(report.summary == "No issues found in the checks that ran. The performance and SEO checks couldn't run.")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter AuditReportSummaryTests`
Expected: FAIL — `value of type 'AuditReport' has no member 'summary'`.

- [ ] **Step 3: Implement `AuditReport.summary`**

Append to `Sources/AnglesiteCore/AuditReport.swift` (after the closing `}` of `AuditReport`):

```swift
public extension AuditReport {
    /// A deterministic one-line overview of the findings — never throws, stable for a given report.
    /// e.g. "1 accessibility issue, 3 SEO issues. The performance check couldn't run."
    var summary: String {
        if findings.isEmpty && runnersSkipped.isEmpty {
            return "No issues found."
        }
        let clauses: [String] = Finding.Category.allCases.compactMap { category in
            let count = findings.filter { $0.category == category }.count
            guard count > 0 else { return nil }
            return "\(count) \(Self.displayName(category)) issue\(count == 1 ? "" : "s")"
        }
        var sentence = clauses.isEmpty ? "No issues found in the checks that ran" : clauses.joined(separator: ", ")
        sentence += "."
        if !runnersSkipped.isEmpty {
            sentence += " " + Self.skippedClause(runnersSkipped.map { Self.displayName($0.category) })
        }
        return sentence
    }

    private static func displayName(_ category: Finding.Category) -> String {
        category == .seo ? "SEO" : category.rawValue
    }

    private static func skippedClause(_ names: [String]) -> String {
        let joined: String
        if names.count == 1 {
            joined = names[0]
        } else {
            joined = names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        }
        let verb = names.count == 1 ? "check couldn't" : "checks couldn't"
        return "The \(joined) \(verb) run."
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter AuditReportSummaryTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Render the summary in `AuditSheetView`**

In `Sources/AnglesiteApp/AuditSheetView.swift`, in `private func findingsList(_ report:)`, add the summary as the first row inside the non-empty branch. Locate the `List { ... }` that holds `ForEach(groupedFindings(report) ...)` (around line 142) and insert immediately before that `ForEach`:

```swift
Section {
    Text(report.summary)
        .font(.callout)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .accessibilityLabel("Audit summary: \(report.summary)")
}
```

- [ ] **Step 6: Build the app target to confirm the view compiles**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build -quiet`
Expected: BUILD SUCCEEDED. (If `Anglesite.xcodeproj` is missing, run `xcodegen generate` and `scripts/copy-plugin.sh` first — see CLAUDE.md / memory `worktree-app-build-copy-plugin`.)

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteCore/AuditReport.swift Sources/AnglesiteApp/AuditSheetView.swift Tests/AnglesiteCoreTests/AuditReportSummaryTests.swift
git commit -m "feat(#93): deterministic audit-findings summary line

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `DeployLogDigest.extract`

**Files:**
- Create: `Sources/AnglesiteCore/DeployLogDigest.swift`
- Test: `Tests/AnglesiteCoreTests/DeployLogDigestTests.swift`

**Interfaces:**
- Produces: `DeployLogDigest.extract(from logText: String) -> String` (non-gated, pure) and `DeployLogDigest.maxCharacters: Int`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/DeployLogDigestTests.swift`:

```swift
import Testing
@testable import AnglesiteCore

@Suite struct DeployLogDigestTests {
    @Test func dropsBuildNoiseKeepsError() {
        let raw = """
        > astro build
        npm run build
        vite v5.0 building for production...
        ✓ 42 modules transformed
        Publishing to Cloudflare...
        ✘ [ERROR] Could not resolve "./missing"
        """
        let digest = DeployLogDigest.extract(from: raw)
        #expect(digest.contains("Could not resolve"))
        #expect(digest.contains("Publishing to Cloudflare"))
        #expect(!digest.contains("astro build"))
        #expect(!digest.contains("npm run build"))
        #expect(!digest.contains("modules transformed"))
    }

    @Test func emptyInputReturnsEmpty() {
        #expect(DeployLogDigest.extract(from: "   \n  ").isEmpty)
    }

    @Test func capsToTail() {
        let long = String(repeating: "x", count: DeployLogDigest.maxCharacters + 500)
        let digest = DeployLogDigest.extract(from: long)
        #expect(digest.count == DeployLogDigest.maxCharacters)
        #expect(digest == String(long.suffix(DeployLogDigest.maxCharacters)))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DeployLogDigestTests`
Expected: FAIL — `cannot find 'DeployLogDigest' in scope`.

- [ ] **Step 3: Implement `DeployLogDigest`**

Create `Sources/AnglesiteCore/DeployLogDigest.swift`:

```swift
import Foundation

/// Reduces a raw deploy log to the deploy-relevant portion before it is summarized on-device.
/// Drops `npm run build` / bundler progress noise, then keeps the tail (where failures surface),
/// capped to fit comfortably inside the on-device model's ~4k-token window.
public enum DeployLogDigest {
    /// Character budget for the digest. The on-device window is ~4,096 tokens (≈16k chars);
    /// 6,000 leaves ample room for the prompt and the guided-generation schema.
    public static let maxCharacters = 6_000

    /// Extract the deploy-relevant text from a raw log. Pure and total.
    public static func extract(from logText: String) -> String {
        let lines = logText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let kept = lines.filter { !isBuildNoise($0) }
        var digest = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if digest.count > maxCharacters {
            digest = String(digest.suffix(maxCharacters))
        }
        return digest
    }

    /// Conservative: only drops lines that are unambiguously build/bundler progress, so a
    /// wrangler error line (which never matches these) always survives.
    private static func isBuildNoise(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("npm run build") { return true }
        if trimmed.hasPrefix("> ") { return true }                 // npm script echo, e.g. "> astro build"
        if trimmed.hasPrefix("✓ ") { return true }                 // Vite "✓ N modules transformed"
        if trimmed.lowercased().hasPrefix("vite v") { return true } // Vite banner
        if trimmed.lowercased().hasPrefix("transforming") { return true }
        return false
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DeployLogDigestTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/DeployLogDigest.swift Tests/AnglesiteCoreTests/DeployLogDigestTests.swift
git commit -m "feat(#93): deploy-log digest for on-device summarization

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `DeployFailureSummary` value + summarizer seam

**Files:**
- Create: `Sources/AnglesiteCore/DeployFailureSummary.swift`
- Test: `Tests/AnglesiteCoreTests/DeployFailureSummaryTests.swift`

**Interfaces:**
- Produces (all non-gated):
  - `struct DeployFailureSummary: Equatable, Sendable { let summary, likelyCause, suggestedFix: String; init(...) }`
  - `protocol DeployFailureSummarizing: Sendable { func summarize(failureLog: String, siteID: String, siteDirectory: URL) async -> DeployFailureSummary? }`
  - `struct NoopDeploySummarizer: DeployFailureSummarizing` — always returns `nil`.

- [ ] **Step 1: Write the failing test**

Create `Tests/AnglesiteCoreTests/DeployFailureSummaryTests.swift`:

```swift
import Foundation
import Testing
@testable import AnglesiteCore

@Suite struct DeployFailureSummaryTests {
    @Test func noopSummarizerReturnsNil() async {
        let summarizer = NoopDeploySummarizer()
        let result = await summarizer.summarize(
            failureLog: "anything",
            siteID: "s",
            siteDirectory: URL(fileURLWithPath: "/tmp/s")
        )
        #expect(result == nil)
    }

    @Test func valueIsEquatable() {
        let a = DeployFailureSummary(summary: "s", likelyCause: "c", suggestedFix: "f")
        let b = DeployFailureSummary(summary: "s", likelyCause: "c", suggestedFix: "f")
        #expect(a == b)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DeployFailureSummaryTests`
Expected: FAIL — `cannot find 'NoopDeploySummarizer' in scope`.

- [ ] **Step 3: Implement the types**

Create `Sources/AnglesiteCore/DeployFailureSummary.swift`:

```swift
import Foundation

/// Plain, view-facing result of summarizing a failed deploy. Non-gated so `DeployModel`,
/// `DeployDrawerView`, and CI-run `AnglesiteCore` tests can all reference it; the `@Generable`
/// counterpart (`GeneratedDeployFailureSummary`) lives behind the FoundationModels gate.
public struct DeployFailureSummary: Equatable, Sendable {
    public let summary: String
    public let likelyCause: String
    public let suggestedFix: String

    public init(summary: String, likelyCause: String, suggestedFix: String) {
        self.summary = summary
        self.likelyCause = likelyCause
        self.suggestedFix = suggestedFix
    }
}

/// Seam for producing a `DeployFailureSummary`. Takes plain `siteID`/`siteDirectory` (not the
/// gated `AssistantContext`) so the protocol stays compilable on CI. A `nil` return means the
/// on-device model was unavailable or generation failed — callers fall back to the raw log.
public protocol DeployFailureSummarizing: Sendable {
    func summarize(failureLog: String, siteID: String, siteDirectory: URL) async -> DeployFailureSummary?
}

/// Fallback conformer used when `FoundationModels` isn't compiled in (CI / pre-Xcode-27).
public struct NoopDeploySummarizer: DeployFailureSummarizing {
    public init() {}
    public func summarize(failureLog: String, siteID: String, siteDirectory: URL) async -> DeployFailureSummary? {
        nil
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DeployFailureSummaryTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/DeployFailureSummary.swift Tests/AnglesiteCoreTests/DeployFailureSummaryTests.swift
git commit -m "feat(#93): deploy-failure summary value + summarizer seam

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: `DeployFailureSummaryRequest` orchestration (CI-testable trigger)

**Files:**
- Create: `Sources/AnglesiteCore/DeployFailureSummaryRequest.swift`
- Test: `Tests/AnglesiteCoreTests/DeployFailureSummaryRequestTests.swift`

**Interfaces:**
- Consumes: `DeployLogDigest.extract` (Task 2), `DeployFailureSummarizing` / `DeployFailureSummary` (Task 3).
- Produces: `DeployFailureSummaryRequest.run(logText:siteID:siteDirectory:using:) async -> DeployFailureSummary?` — digests the log, short-circuits to `nil` on empty, otherwise delegates to the summarizer. This is the unit `DeployModel` calls, so its behavior is covered on CI without an app test target (mirrors the `TokenOnboarding` extraction).

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/DeployFailureSummaryRequestTests.swift`:

```swift
import Foundation
import Testing
@testable import AnglesiteCore

private actor SpySummarizer: DeployFailureSummarizing {
    private(set) var receivedLog: String?
    let stub: DeployFailureSummary?
    init(stub: DeployFailureSummary?) { self.stub = stub }
    func summarize(failureLog: String, siteID: String, siteDirectory: URL) async -> DeployFailureSummary? {
        receivedLog = failureLog
        return stub
    }
    func loggedSomething() -> Bool { receivedLog != nil }
}

@Suite struct DeployFailureSummaryRequestTests {
    private let dir = URL(fileURLWithPath: "/tmp/site")

    @Test func emptyLogSkipsSummarizer() async {
        let spy = SpySummarizer(stub: DeployFailureSummary(summary: "x", likelyCause: "y", suggestedFix: "z"))
        let result = await DeployFailureSummaryRequest.run(
            logText: "   \n ", siteID: "s", siteDirectory: dir, using: spy
        )
        #expect(result == nil)
        #expect(await spy.loggedSomething() == false)
    }

    @Test func nonEmptyLogPassesDigestThrough() async {
        let expected = DeployFailureSummary(summary: "boom", likelyCause: "c", suggestedFix: "f")
        let spy = SpySummarizer(stub: expected)
        let result = await DeployFailureSummaryRequest.run(
            logText: "✘ [ERROR] Could not resolve \"./x\"", siteID: "s", siteDirectory: dir, using: spy
        )
        #expect(result == expected)
        #expect(await spy.receivedLog?.contains("Could not resolve") == true)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DeployFailureSummaryRequestTests`
Expected: FAIL — `cannot find 'DeployFailureSummaryRequest' in scope`.

- [ ] **Step 3: Implement the orchestration**

Create `Sources/AnglesiteCore/DeployFailureSummaryRequest.swift`:

```swift
import Foundation

/// Trigger logic extracted from `DeployModel` so it is covered by `swift test` on CI (the app
/// target has no CI-run test bundle). Digests the raw log and short-circuits empty input before
/// touching the model.
public enum DeployFailureSummaryRequest {
    public static func run(
        logText: String,
        siteID: String,
        siteDirectory: URL,
        using summarizer: any DeployFailureSummarizing
    ) async -> DeployFailureSummary? {
        let digest = DeployLogDigest.extract(from: logText)
        guard !digest.isEmpty else { return nil }
        return await summarizer.summarize(failureLog: digest, siteID: siteID, siteDirectory: siteDirectory)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DeployFailureSummaryRequestTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/DeployFailureSummaryRequest.swift Tests/AnglesiteCoreTests/DeployFailureSummaryRequestTests.swift
git commit -m "feat(#93): CI-testable deploy-failure summary trigger

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: FoundationModels conformer (`@Generable` + summarizer + factory)

**Files:**
- Modify: `Sources/AnglesiteCore/GenerableTypes.swift` (add `GeneratedDeployFailureSummary` inside the existing `#if compiler(>=6.4)` block)
- Create: `Sources/AnglesiteCore/FoundationModelDeploySummarizer.swift`
- Test: `Tests/AnglesiteCoreTests/FoundationModelDeploySummarizerTests.swift`

**Interfaces:**
- Consumes: `DeployFailureSummary` / `DeployFailureSummarizing` (Task 3); `FoundationModelAssistant.generateStructured`, `AssistantContext`, `AssistantError` (existing, gated).
- Produces: `@Generable GeneratedDeployFailureSummary`; `FoundationModelDeploySummarizer: DeployFailureSummarizing` (gated); `DeploySummarizerFactory.makeDefault() -> any DeployFailureSummarizing` (non-gated, picks conformer via `#if`); `FoundationModelDeploySummarizer.prompt(for:) -> String` (gated, internal — exposed for tests).

- [ ] **Step 1: Add the `@Generable` type**

In `Sources/AnglesiteCore/GenerableTypes.swift`, inside the `#if compiler(>=6.4)` block (e.g. after `ContentSummary`, before the closing `#endif`):

```swift
/// On-device guided-generation result for a failed deploy. Mapped to the non-gated
/// `DeployFailureSummary` before it crosses the FoundationModels gate.
@Generable
public struct GeneratedDeployFailureSummary: Equatable, Sendable {
    @Guide(description: "One or two plain-language sentences explaining what went wrong with the deploy.")
    public var summary: String

    @Guide(description: "The single most likely root cause of the failure, in one sentence.")
    public var likelyCause: String

    @Guide(description: "A concrete next step the site owner can take to fix it. Empty string if none is clear.")
    public var suggestedFix: String
}
```

- [ ] **Step 2: Write the failing tests**

Create `Tests/AnglesiteCoreTests/FoundationModelDeploySummarizerTests.swift`:

```swift
import Foundation
import Testing
@testable import AnglesiteCore

// FoundationModels is absent on the CI runner; these only compile/run under Xcode 27.
#if compiler(>=6.4)
@Suite struct FoundationModelDeploySummarizerTests {
    @Test func promptIncludesTheLog() {
        let prompt = FoundationModelDeploySummarizer.prompt(for: "✘ [ERROR] Could not resolve \"./x\"")
        #expect(prompt.contains("Could not resolve"))
        #expect(prompt.lowercased().contains("deploy"))
    }

    @Test func emptyLogReturnsNilWithoutModel() async {
        // Whitespace-only log must short-circuit to nil and never invoke the on-device model,
        // so this is deterministic on machines with or without Apple Intelligence.
        let result = await FoundationModelDeploySummarizer().summarize(
            failureLog: "   ", siteID: "s", siteDirectory: URL(fileURLWithPath: "/tmp/s")
        )
        #expect(result == nil)
    }
}
#endif

@Suite struct DeploySummarizerFactoryTests {
    // The factory's product differs per toolchain (real conformer under Xcode 27, Noop on CI),
    // but BOTH short-circuit a whitespace-only log to nil before touching any model — a real
    // behavioral assertion that holds everywhere and never invokes Apple Intelligence.
    @Test func makeDefaultProductShortCircuitsEmptyLog() async {
        let result = await DeploySummarizerFactory.makeDefault().summarize(
            failureLog: "   ", siteID: "s", siteDirectory: URL(fileURLWithPath: "/tmp/s")
        )
        #expect(result == nil)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter FoundationModelDeploySummarizerTests`
Expected: FAIL — `cannot find 'FoundationModelDeploySummarizer'` (and `DeploySummarizerFactory`).

- [ ] **Step 4: Implement the conformer + factory**

Create `Sources/AnglesiteCore/FoundationModelDeploySummarizer.swift`:

```swift
import Foundation

/// Chooses the deploy-failure summarizer for the current toolchain. Non-gated so `DeployModel`
/// can default its dependency without importing FoundationModels.
public enum DeploySummarizerFactory {
    public static func makeDefault() -> any DeployFailureSummarizing {
        #if compiler(>=6.4)
        return FoundationModelDeploySummarizer()
        #else
        return NoopDeploySummarizer()
        #endif
    }
}

#if compiler(>=6.4)
import FoundationModels

/// On-device summarizer: runs the digested failure log through the macOS 27 model via guided
/// generation, then maps the result to the non-gated `DeployFailureSummary`. Any failure —
/// including `AssistantError.unavailable` when Apple Intelligence is off — collapses to `nil`
/// so the caller falls back to showing the raw log.
public struct FoundationModelDeploySummarizer: DeployFailureSummarizing {
    public init() {}

    public func summarize(failureLog: String, siteID: String, siteDirectory: URL) async -> DeployFailureSummary? {
        guard !failureLog.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let context = AssistantContext(siteID: siteID, siteDirectory: siteDirectory)
        do {
            let generated = try await FoundationModelAssistant(tier: .onDevice).generateStructured(
                prompt: Self.prompt(for: failureLog),
                context: context,
                resultType: GeneratedDeployFailureSummary.self
            )
            return DeployFailureSummary(
                summary: generated.summary,
                likelyCause: generated.likelyCause,
                suggestedFix: generated.suggestedFix
            )
        } catch {
            return nil
        }
    }

    static func prompt(for log: String) -> String {
        """
        A website deploy to Cloudflare failed. Read the deploy log below and explain the failure \
        for a non-expert site owner. Be concise and specific to this log — do not invent details \
        that are not present in the log.

        Deploy log:
        \(log)
        """
    }
}
#endif
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter FoundationModelDeploySummarizerTests && DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DeploySummarizerFactoryTests`
Expected: PASS. (On a dev Mac with Xcode 27 both suites run; `emptyLogReturnsNilWithoutModel` passes regardless of Apple Intelligence state because it short-circuits before the model call.)

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/GenerableTypes.swift Sources/AnglesiteCore/FoundationModelDeploySummarizer.swift Tests/AnglesiteCoreTests/FoundationModelDeploySummarizerTests.swift
git commit -m "feat(#93): on-device deploy-failure summarizer (Foundation Models)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Wire summarization into `DeployModel`

**Files:**
- Modify: `Sources/AnglesiteApp/DeployModel.swift`

**Interfaces:**
- Consumes: `DeployFailureSummaryRequest.run` (Task 4), `DeploySummarizerFactory.makeDefault` (Task 5), `DeployFailureSummary` / `DeployFailureSummarizing` (Task 3).
- Produces: `DeployModel.failureSummary: DeployFailureSummary?` and `DeployModel.summarizing: Bool` (both `private(set)`), consumed by Task 7's view.

- [ ] **Step 1: Add stored state + injected dependency**

In `Sources/AnglesiteApp/DeployModel.swift`, add observable state next to `currentMilestone` (after the `logLines` / `currentMilestone` declarations near line 24):

```swift
/// On-device summary of the most recent *failed* deploy, or nil if none/unavailable.
private(set) var failureSummary: DeployFailureSummary?
/// True while the failure summary is being generated (drives a spinner in the drawer).
private(set) var summarizing: Bool = false
```

Add the dependency to the stored properties (next to `private let command`):

```swift
private let summarizer: any DeployFailureSummarizing
```

Update `init` to accept and store it (add the parameter after `verifier:`):

```swift
init(
    command: DeployCommand = DeployCommand(),
    logCenter: LogCenter = .shared,
    keychain: KeychainStore = KeychainStore(),
    verifier: TokenVerifying = WranglerTokenVerifier(),
    summarizer: any DeployFailureSummarizing = DeploySummarizerFactory.makeDefault()
) {
    self.command = command
    self.logCenter = logCenter
    self.keychain = keychain
    self.onboarding = TokenOnboarding(verifier: verifier)
    self.summarizer = summarizer
}
```

- [ ] **Step 2: Reset summary state when a new deploy starts**

In the same file, find where a deploy actually begins streaming (the body of the run task, immediately before `let subscription = ...`/`logLines` is first cleared for the run). Add:

```swift
failureSummary = nil
summarizing = false
```

(If `logLines` is reset at the start of the run, place these two lines adjacent to that reset so all per-run state clears together.)

- [ ] **Step 3: Trigger summarization on failure**

In the terminal `switch result` block, replace the `.failed` case:

```swift
case .failed(let reason, let exit):
    phase = .failed(reason: reason, exitCode: exit)
    summarizing = true
    failureSummary = await DeployFailureSummaryRequest.run(
        logText: logText,
        siteID: siteID,
        siteDirectory: siteDirectory,
        using: summarizer
    )
    summarizing = false
```

(`siteID` and `siteDirectory` are the parameters of the enclosing deploy function and are in scope here.)

- [ ] **Step 4: Build the app target**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build -quiet`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Build the MAS target (chat/Foundation Models path must compile sandboxed)**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build -quiet`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteApp/DeployModel.swift
git commit -m "feat(#93): generate failure summary on deploy failure

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Render the failure summary in `DeployDrawerView`

**Files:**
- Modify: `Sources/AnglesiteApp/DeployDrawerView.swift`

**Interfaces:**
- Consumes: `DeployModel.failureSummary`, `DeployModel.summarizing` (Task 6).

- [ ] **Step 1: Add a summary section to the failed state**

In `Sources/AnglesiteApp/DeployDrawerView.swift`, add a view that renders only for the failed state. Place this helper in the view (near the other `private func`/`@ViewBuilder` section builders):

```swift
@ViewBuilder
private var failureSummarySection: some View {
    if case .failed = model.phase {
        if model.summarizing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Summarizing…").font(.callout).foregroundStyle(.secondary)
            }
        } else if let s = model.failureSummary {
            VStack(alignment: .leading, spacing: 6) {
                Text(s.summary).font(.callout)
                if !s.likelyCause.isEmpty {
                    Text("Likely cause: \(s.likelyCause)").font(.callout).foregroundStyle(.secondary)
                }
                if !s.suggestedFix.isEmpty {
                    Text("Suggested fix: \(s.suggestedFix)").font(.callout).foregroundStyle(.secondary)
                }
            }
            .textSelection(.enabled)
            .accessibilityElement(children: .combine)
        }
        // failureSummary == nil && !summarizing → render nothing; the raw reason/log already shows.
    }
}
```

- [ ] **Step 2: Place the section in the body**

In `body`, insert `failureSummarySection` immediately above the log section (the `ScrollView`/log list that iterates `model.logLines`, around line 100), so the summary sits between the failure banner and the raw log:

```swift
failureSummarySection
```

- [ ] **Step 3: Build the app target**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build -quiet`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Full test sweep (no regressions)**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .`
Expected: PASS — all suites green, including the four new ones.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/DeployDrawerView.swift
git commit -m "feat(#93): show on-device summary for failed deploys

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Manual verification (post-implementation)

These can't run on CI (need a Mac with Apple Intelligence enabled):

- [ ] Trigger a deploy that fails (e.g. invalid Cloudflare token or a build error). Confirm the drawer shows "Summarizing…" then a summary with cause + fix, and the raw log remains visible/copyable below it.
- [ ] Disable Apple Intelligence (System Settings → Apple Intelligence & Siri) and fail a deploy again. Confirm the drawer falls back to the raw reason/log with no summary and no hang.
- [ ] Run an audit with mixed findings and a skipped runner (e.g. Lighthouse not installed). Confirm the summary line reads correctly at the top of the sheet.

## Self-Review

- **Spec coverage:** Audit deterministic summary → Task 1. Deploy log filtering → Task 2. `DeployFailureSummary` plain type + summarizer seam → Task 3. CI-testable trigger (TokenOnboarding precedent) → Task 4. `@Generable` + Foundation Models conformer + availability fallback → Task 5. Auto-on-failure-only wiring → Task 6. Distinct cause/fix rendering + graceful fallback → Task 7. Success path untouched (no task needed — confirmed in spec). Both targets build (Task 6 Steps 4–5). ✔
- **Placeholder scan:** every code step contains full code; no TBD/TODO. ✔
- **Type consistency:** `DeployFailureSummarizing.summarize(failureLog:siteID:siteDirectory:)` is identical across Tasks 3, 4, 5, 6; `DeployFailureSummary(summary:likelyCause:suggestedFix:)` identical across Tasks 3, 5, 7; `DeployFailureSummaryRequest.run(logText:siteID:siteDirectory:using:)` matches between Tasks 4 and 6; `DeploySummarizerFactory.makeDefault()` matches Tasks 5 and 6. ✔
