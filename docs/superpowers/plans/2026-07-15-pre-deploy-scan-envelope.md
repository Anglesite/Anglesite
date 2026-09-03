# Pre-deploy Scan JSON Envelope Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `pre-deploy-check.ts --json` and both Swift decoders agree on one versioned JSON envelope, so a real deploy's pre-deploy scan actually decodes (today it always fails to decode and maps to `.error`), and add a real producer→consumer test so this can't silently drift again.

**Architecture:** Define `{version: 1, ok, failures: Finding[], warnings: Finding[]}` (`Finding = {severity, category, message, file?, detail?, remediation?}`) as the shared shape. `PreDeployCheck.parse(output:exitCode:)` becomes the single Swift decoder; `PreDeployCheck.check` and `DeployCommand.parseScanReport` both delegate to it. `Category` decodes unknown raw values to `.other` instead of throwing. No legacy-array fallback — Anglesite is pre-1.0.

**Tech Stack:** Swift 6 (Testing framework, `Codable`), TypeScript (`tsx`, `node:test`).

## Global Constraints

- No legacy `Issue[]` fallback decoding — pre-1.0, no shipped sites to support (per spec's "No legacy fallback" section).
- Don't reclassify any check's severity (e.g. `third-party-script` stays a warning) — preserve current exit-code semantics.
- `detail`/`remediation` are optional on every finding; don't write remediation copy for every check in this pass.
- One shared Swift decoder (`PreDeployCheck.parse`) — no duplicate `RawReport`-style structs.
- Full design: [`docs/superpowers/specs/2026-07-15-pre-deploy-scan-envelope-design.md`](../specs/2026-07-15-pre-deploy-scan-envelope-design.md).

---

### Task 1: Rewrite scan-result types, consolidate the decoder, migrate `AnglesiteCoreTests`

**Files:**
- Modify: `Sources/AnglesiteCore/PreDeployCheck.swift` (full rewrite)
- Modify: `Sources/AnglesiteCore/DeployCommand.swift:205-235` (`parseScanReport`)
- Modify: `Sources/AnglesiteCore/RouteCoverageScanner.swift:17-22`
- Modify: `Tests/AnglesiteCoreTests/PreDeployCheckTests.swift` (full rewrite)
- Modify: `Tests/AnglesiteCoreTests/DeployCommandTests.swift:69-72,274,506`
- Modify: `Tests/AnglesiteCoreTests/HealthModelTests.swift:174-180`
- Modify: `Tests/AnglesiteCoreTests/SiteOperationsTests.swift:118-120,204-209`

**Interfaces:**
- Produces: `PreDeployCheck.ScanFailure(category:message:file:detail:remediation:)`, `PreDeployCheck.ScanWarning(category:message:file:detail:remediation:)` — `message` required, `file`/`detail`/`remediation` default to `nil`. `PreDeployCheck.ScanFailure.Category` / `PreDeployCheck.ScanWarning.Category` — `String`-backed enums that decode any unrecognized raw value to `.other`. `PreDeployCheck.parse(output: String, exitCode: Int32?) -> PreDeployCheck.Outcome` — the one shared decoder.
- Consumes: nothing from other tasks (this is the foundation task).

This task changes a type used across `Sources/AnglesiteCore`, so partial compilation isn't possible — all of `AnglesiteCore` and `AnglesiteCoreTests` must be updated together for the target to build. `AnglesiteApp`/`AnglesiteIntents` targets (Task 2/3) will still fail to build after this task — that's expected until those tasks land.

- [ ] **Step 1: Rewrite `Sources/AnglesiteCore/PreDeployCheck.swift`**

```swift
import Foundation

/// Runs the bundled plugin's pre-deploy scans against a site directory and
/// returns a structured outcome the app can render.
///
/// The four mandatory blockers (PII, exposed tokens, third-party scripts,
/// Keystatic admin routes) come from `template/scripts/pre-deploy-check.ts`
/// invoked with `--json`. The JSON contract is owned by the plugin — this
/// actor is just a typed shell around `JSONDecoder` and a script invocation.
///
/// `PreDeployCheck` is intentionally minimal: no Cloudflare token resolution,
/// no `npm run build`, no UI. Callers (today: `DeployCommand`) decide what to
/// do with the `Outcome`. The build step lands with the deploy-flow polish in
/// #22; this actor presumes `dist/` already exists and surfaces a `.error`
/// outcome when it does not.
public actor PreDeployCheck {
    public enum Outcome: Sendable, Equatable {
        case passed(warnings: [ScanWarning])
        case blocked(failures: [ScanFailure], warnings: [ScanWarning])
        /// Script error — couldn't run the scan at all (missing tsx, missing
        /// dist/, malformed JSON, unsupported envelope version). Distinct from
        /// `.blocked` so callers can surface the right remediation.
        case error(reason: String)
    }

    public struct ScanFailure: Sendable, Equatable, Codable {
        public enum Category: String, Sendable, Codable, CaseIterable {
            case piiEmail = "pii-email"
            case piiPhone = "pii-phone"
            case piiSSN = "pii-ssn"
            case exposedToken = "exposed-token"
            case thirdPartyScript = "third-party-script"
            case keystaticRoute = "keystatic-route"
            case cspMisconfigured = "csp-misconfigured"
            /// Any category code this build doesn't recognize yet — decoding falls back here
            /// instead of throwing, so a future/typo'd category can't crash the whole scan (#742).
            case other = "other"

            public init(from decoder: Decoder) throws {
                let raw = try decoder.singleValueContainer().decode(String.self)
                self = Category(rawValue: raw) ?? .other
            }
        }
        public let category: Category
        public let message: String
        /// Repo-relative path of the file where the issue was found, when known.
        public let file: String?
        public let detail: String?
        public let remediation: String?

        public init(
            category: Category,
            message: String,
            file: String? = nil,
            detail: String? = nil,
            remediation: String? = nil
        ) {
            self.category = category
            self.message = message
            self.file = file
            self.detail = detail
            self.remediation = remediation
        }
    }

    public struct ScanWarning: Sendable, Equatable, Codable {
        public enum Category: String, Sendable, Codable, CaseIterable {
            case missingOgImage = "missing-og-image"
            case maintenanceOverdue = "maintenance-overdue"
            case seoCritical = "seo-critical"
            case seoWarning = "seo-warning"
            /// A route published by the previous deploy is no longer published and has no
            /// `redirects.json` entry covering it. Computed by `RouteCoverageScanner`, not the
            /// JS-side scan script — merged into the `Outcome` by `DeployCommand.deploy`.
            case orphanedRoute = "orphaned-route"
            case mixedContent = "mixed-content"
            case sriMissing = "sri-missing"
            case externalLinkRel = "external-link-rel"
            case missingSecurityArtifact = "missing-security-artifact"
            case thirdPartyScript = "third-party-script"
            /// Any category code this build doesn't recognize yet — decoding falls back here
            /// instead of throwing, so a future/typo'd category can't crash the whole scan (#742).
            case other = "other"

            public init(from decoder: Decoder) throws {
                let raw = try decoder.singleValueContainer().decode(String.self)
                self = Category(rawValue: raw) ?? .other
            }
        }
        public let category: Category
        public let message: String
        public let file: String?
        public let detail: String?
        public let remediation: String?

        public init(
            category: Category,
            message: String,
            file: String? = nil,
            detail: String? = nil,
            remediation: String? = nil
        ) {
            self.category = category
            self.message = message
            self.file = file
            self.detail = detail
            self.remediation = remediation
        }
    }

    /// The versioned JSON envelope emitted by `pre-deploy-check.ts --json` (#742).
    struct ScanReport: Decodable {
        let version: Int
        let ok: Bool
        let failures: [ScanFailure]
        let warnings: [ScanWarning]
    }

    /// Checked before a full `ScanReport` decode so an unsupported future envelope version
    /// reports a specific remediation instead of a generic malformed-JSON error.
    private struct VersionProbe: Decodable { let version: Int }

    /// The single decoder for `pre-deploy-check.ts --json` output (#742). Both `check` below and
    /// `DeployCommand.parseScanReport` call this — neither re-declares its own JSON shape.
    /// Anglesite is pre-1.0, so there is no legacy bare-array fallback: anything that isn't the
    /// current versioned envelope is an explicit `.error`.
    public static func parse(output: String, exitCode: Int32?) -> Outcome {
        let data = Data(output.utf8)
        guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: data) else {
            return .error(reason: decodeErrorReason(exitCode: exitCode))
        }
        guard probe.version == 1 else {
            return .error(reason: "pre-deploy scan emitted an unsupported envelope version (\(probe.version)) — run `/anglesite:update`")
        }
        guard let report = try? JSONDecoder().decode(ScanReport.self, from: data) else {
            return .error(reason: decodeErrorReason(exitCode: exitCode))
        }
        return report.ok
            ? .passed(warnings: report.warnings)
            : .blocked(failures: report.failures, warnings: report.warnings)
    }

    /// No parseable envelope at all — either fully malformed JSON, or well-formed JSON missing
    /// `version` (including the pre-#742 bare-array shape, which has no `version` key).
    private static func decodeErrorReason(exitCode: Int32?) -> String {
        let exit = exitCode ?? -1
        return exit == 0
            ? "pre-deploy scan emitted no JSON (exit 0) — is the site's scripts/pre-deploy-check.ts up to date?"
            : "pre-deploy scan failed (exit \(exit)) — run `npm run build` and try again, or run `/anglesite:update` if the script is outdated"
    }

    /// Spawns the scan script and returns its stdout + exit code. Tests inject
    /// a fake; the default invoker shells out to `npx tsx scripts/pre-deploy-check.ts --json`
    /// with `siteDirectory` as cwd.
    public typealias ScriptInvoker = @Sendable (_ siteDirectory: URL) async throws -> (stdout: String, exitCode: Int32)

    private let invoke: ScriptInvoker

    public init(invoke: @escaping ScriptInvoker) {
        self.invoke = invoke
    }

    public func check(siteID: String, siteDirectory: URL) async -> Outcome {
        let result: (stdout: String, exitCode: Int32)
        do {
            result = try await invoke(siteDirectory)
        } catch {
            return .error(reason: "couldn't run pre-deploy scan: \(error)")
        }
        return Self.parse(output: result.stdout, exitCode: result.exitCode)
    }
}
```

- [ ] **Step 2: Update `Sources/AnglesiteCore/DeployCommand.swift`'s `parseScanReport` to delegate**

Replace lines 205-235 (the `// MARK: Scan report parsing` block through the end of `parseScanReport`) with:

```swift
    // MARK: Scan report parsing

    /// Parses the captured stdout of the pre-deploy scan (`scripts/pre-deploy-check.ts --json`)
    /// into a `PreDeployCheck.Outcome`. Thin forwarding wrapper — `PreDeployCheck.parse` is the
    /// one real decoder (#742); this keeps the existing public call-site signature stable.
    public static func parseScanReport(output: String, exitCode: Int32?) -> PreDeployCheck.Outcome {
        PreDeployCheck.parse(output: output, exitCode: exitCode)
    }
```

- [ ] **Step 3: Update `Sources/AnglesiteCore/RouteCoverageScanner.swift`'s construction call**

Replace the `return vanished.sorted().map { ... }` body with:

```swift
        return vanished.sorted().map { route in
            PreDeployCheck.ScanWarning(
                category: .orphanedRoute,
                message: "\(route) is no longer published and has no redirect covering it.",
                remediation: "Add a redirect for \(route) in Site Settings → Redirects, or ignore if the removal is intentional."
            )
        }
```

- [ ] **Step 4: Verify the library targets build**

Run: `swift build --package-path .`
Expected: `Build complete!` — `AnglesiteCore`'s library target compiles cleanly. (Test targets will not build yet; that's expected until this task's remaining steps land.)

- [ ] **Step 5: Rewrite `Tests/AnglesiteCoreTests/PreDeployCheckTests.swift`**

```swift
import Testing
import Foundation
@testable import AnglesiteCore

struct PreDeployCheckTests {
    private let siteDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

    // MARK: Happy path

    @Test("Returns passed when script emits ok-true JSON") func returnsPassedWhenScriptEmitsOkTrueJSON() async {
        let json = #"{"version": 1, "ok": true, "failures": [], "warnings": []}"#
        let check = PreDeployCheck(invoke: { _ in (stdout: json, exitCode: 0) })

        let outcome = await check.check(siteID: "mysite", siteDirectory: siteDir)

        guard case .passed(let warnings) = outcome else {
            Issue.record("expected .passed, got \(outcome)")
            return
        }
        #expect(warnings == [])
    }

    // MARK: Blocked

    @Test("Returns blocked when script emits ok-false with failures") func returnsBlockedWhenScriptEmitsOkFalseWithFailures() async {
        let json = """
        {
          "version": 1,
          "ok": false,
          "failures": [
            {
              "category": "pii-email",
              "message": "Possible email address: jane@yourbusiness.com",
              "file": "dist/index.html",
              "remediation": "Wrap the address in a `mailto:` link if it should be published, or add it to PII_EMAIL_ALLOW in .site-config."
            }
          ],
          "warnings": []
        }
        """
        let check = PreDeployCheck(invoke: { _ in (stdout: json, exitCode: 1) })

        let outcome = await check.check(siteID: "mysite", siteDirectory: siteDir)

        guard case .blocked(let failures, _) = outcome else {
            Issue.record("expected .blocked, got \(outcome)")
            return
        }
        #expect(failures.count == 1)
        #expect(failures[0].category == .piiEmail)
        #expect(failures[0].file == "dist/index.html")
        #expect(failures[0].message.contains("jane@yourbusiness.com"))
        #expect(failures[0].remediation?.contains("PII_EMAIL_ALLOW") == true)
    }

    @Test("Parses all five failure categories") func parsesAllFiveFailureCategories() async {
        let json = """
        {
          "version": 1,
          "ok": false,
          "failures": [
            {"category": "pii-email", "message": "m", "file": "a", "remediation": "r"},
            {"category": "pii-phone", "message": "m", "file": "a", "remediation": "r"},
            {"category": "exposed-token", "message": "m", "file": "a", "remediation": "r"},
            {"category": "third-party-script", "message": "m", "file": "a", "remediation": "r"},
            {"category": "keystatic-route", "message": "m", "file": "a", "remediation": "r"}
          ],
          "warnings": []
        }
        """
        let check = PreDeployCheck(invoke: { _ in (stdout: json, exitCode: 1) })

        guard case .blocked(let failures, _) = await check.check(siteID: "mysite", siteDirectory: siteDir) else {
            Issue.record("expected .blocked")
            return
        }
        #expect(
            Set(failures.map(\.category)) == Set([.piiEmail, .piiPhone, .exposedToken, .thirdPartyScript, .keystaticRoute])
        )
    }

    @Test("Unknown category decodes to .other instead of failing the scan") func unknownCategoryDecodesToOther() async {
        let json = """
        {
          "version": 1,
          "ok": false,
          "failures": [
            {"category": "some-future-category", "message": "m", "file": "a"}
          ],
          "warnings": [
            {"category": "another-future-category", "message": "m"}
          ]
        }
        """
        let check = PreDeployCheck(invoke: { _ in (stdout: json, exitCode: 1) })

        guard case .blocked(let failures, let warnings) = await check.check(siteID: "mysite", siteDirectory: siteDir) else {
            Issue.record("expected .blocked")
            return
        }
        #expect(failures.first?.category == .other)
        #expect(warnings.first?.category == .other)
    }

    // MARK: Error paths

    @Test("Returns error when invoker throws") func returnsErrorWhenInvokerThrows() async {
        struct SpawnFailed: Error {}
        let check = PreDeployCheck(invoke: { _ in throw SpawnFailed() })

        let outcome = await check.check(siteID: "mysite", siteDirectory: siteDir)

        guard case .error(let reason) = outcome else {
            Issue.record("expected .error, got \(outcome)")
            return
        }
        #expect(reason.contains("couldn't run"), "\(reason)")
    }

    @Test("Returns error when stdout is not parseable JSON") func returnsErrorWhenStdoutIsNotParseableJSON() async {
        // tsx not installed → "command not found" on stderr, no stdout, exit 127
        let check = PreDeployCheck(invoke: { _ in (stdout: "", exitCode: 127) })

        guard case .error(let reason) = await check.check(siteID: "mysite", siteDirectory: siteDir) else {
            Issue.record("expected .error")
            return
        }
        #expect(reason.contains("exit 127") || reason.contains("npm run build") || reason.contains("update"), "\(reason)")
    }

    @Test("Returns error when JSON is malformed") func returnsErrorWhenJSONIsMalformed() async {
        let check = PreDeployCheck(invoke: { _ in (stdout: "not json at all", exitCode: 0) })

        guard case .error = await check.check(siteID: "mysite", siteDirectory: siteDir) else {
            Issue.record("expected .error")
            return
        }
    }

    @Test("Returns error when the version field is missing (no legacy-array fallback)") func returnsErrorWhenVersionIsMissing() async {
        // Pre-#742 shape: a bare array, no envelope at all.
        let json = #"[{"severity":"error","message":"Possible email found","file":"dist/index.html"}]"#
        let check = PreDeployCheck(invoke: { _ in (stdout: json, exitCode: 1) })

        guard case .error = await check.check(siteID: "mysite", siteDirectory: siteDir) else {
            Issue.record("expected .error for pre-envelope legacy array output")
            return
        }
    }

    @Test("Returns error when the envelope version is unsupported") func returnsErrorWhenVersionIsUnsupported() async {
        let json = #"{"version": 2, "ok": true, "failures": [], "warnings": []}"#
        let check = PreDeployCheck(invoke: { _ in (stdout: json, exitCode: 0) })

        guard case .error(let reason) = await check.check(siteID: "mysite", siteDirectory: siteDir) else {
            Issue.record("expected .error")
            return
        }
        #expect(reason.contains("unsupported envelope version"), "\(reason)")
    }

    // MARK: Warnings pass-through

    @Test("Warnings are returned alongside passed and blocked outcomes") func warningsAreReturnedAlongsidePassedAndBlockedOutcomes() async {
        let warningJSON = """
        "warnings": [
          {"category": "missing-og-image", "message": "No og:image meta tag.", "remediation": "Run `npm run ai-images`."}
        ]
        """
        let passedJSON = "{ \"version\": 1, \"ok\": true, \"failures\": [], \(warningJSON) }"
        let blockedJSON = """
        { "version": 1, "ok": false,
          "failures": [{"category": "pii-email", "message": "m", "file": "a", "remediation": "r"}],
          \(warningJSON) }
        """

        let passedCheck = PreDeployCheck(invoke: { _ in (stdout: passedJSON, exitCode: 0) })
        guard case .passed(let pw) = await passedCheck.check(siteID: "mysite", siteDirectory: siteDir) else {
            Issue.record("expected .passed")
            return
        }
        #expect(pw.count == 1)
        #expect(pw[0].category == .missingOgImage)

        let blockedCheck = PreDeployCheck(invoke: { _ in (stdout: blockedJSON, exitCode: 1) })
        guard case .blocked(_, let bw) = await blockedCheck.check(siteID: "mysite", siteDirectory: siteDir) else {
            Issue.record("expected .blocked")
            return
        }
        #expect(bw.count == 1)
        #expect(bw[0].category == .missingOgImage)
    }
}
```

- [ ] **Step 6: Update `Tests/AnglesiteCoreTests/DeployCommandTests.swift`**

First, a project-wide-in-file replace: every occurrence of the literal `{"ok":true,"failures":[],"warnings":[]}` becomes `{"version":1,"ok":true,"failures":[],"warnings":[]}` (this covers `scanJSON(ok: true)` and all three `/bin/sh` echo fixtures at once, since they share the exact substring).

Then replace the `scanJSON` helper (originally lines 69-72) with:

```swift
    /// Build the JSON payload the plugin's `pre-deploy-check.ts --json` emits.
    private func scanJSON(ok: Bool) -> String {
        ok ? #"{"version":1,"ok":true,"failures":[],"warnings":[]}"#
           : #"{"version":1,"ok":false,"failures":[{"category":"pii-email","message":"email","file":"dist/index.html","remediation":"wrap it"}],"warnings":[]}"#
    }
```

Then replace the inline fixture (originally line 274):

```swift
            .set(.preflight, exitCode: 0, output: #"{"version":1,"ok":true,"failures":[],"warnings":[{"category":"missing-og-image","message":"no og image","remediation":"add one"}]}"#)
```

Then replace the assertion (originally line 506):

```swift
        #expect(warnings.contains { $0.category == .orphanedRoute && $0.message.contains("/old-page") })
```

- [ ] **Step 7: Update `Tests/AnglesiteCoreTests/HealthModelTests.swift`'s fixtures**

Replace (originally lines 174-180):

```swift
    private var sampleFailure: PreDeployCheck.ScanFailure {
        .init(category: .exposedToken, message: "token in src", file: "src/x.astro", remediation: "remove it")
    }

    private var sampleWarning: PreDeployCheck.ScanWarning {
        .init(category: .missingOgImage, message: "no og image", remediation: "add one")
    }
```

- [ ] **Step 8: Update `Tests/AnglesiteCoreTests/SiteOperationsTests.swift`'s two construction sites**

Replace (originally lines 118-120):

```swift
        let failure = PreDeployCheck.ScanFailure(
            category: .exposedToken, message: "API key committed", file: "src/index.md", remediation: "Remove it"
        )
```

Replace (originally lines 204-209):

```swift
        let failure = PreDeployCheck.ScanFailure(
            category: .exposedToken,
            message: "API key committed",
            file: "dist/index.html",
            remediation: "Remove it"
        )
```

- [ ] **Step 9: Run the `AnglesiteCore` test suite**

Run: `swift test --package-path . --filter AnglesiteCoreTests`
Expected: all tests pass, including the 3 new tests added in Step 5 (`unknownCategoryDecodesToOther`, `returnsErrorWhenVersionIsMissing`, `returnsErrorWhenVersionIsUnsupported`).

- [ ] **Step 10: Commit**

```bash
git add Sources/AnglesiteCore/PreDeployCheck.swift Sources/AnglesiteCore/DeployCommand.swift Sources/AnglesiteCore/RouteCoverageScanner.swift Tests/AnglesiteCoreTests/PreDeployCheckTests.swift Tests/AnglesiteCoreTests/DeployCommandTests.swift Tests/AnglesiteCoreTests/HealthModelTests.swift Tests/AnglesiteCoreTests/SiteOperationsTests.swift
git commit -m "feat(core): unify pre-deploy scan JSON envelope for #742

Replace the two divergent Swift decoders with one PreDeployCheck.parse,
add the versioned {version,ok,failures,warnings} envelope shape, and
make category decoding forward-compatible (unknown -> .other)."
```

---

### Task 2: Migrate `AnglesiteApp` (UI + `DeployModelTests`)

**Files:**
- Modify: `Sources/AnglesiteApp/BlockedDeploySheetView.swift`
- Modify: `Sources/AnglesiteApp/HealthBadgeView.swift:182,186,199,200`
- Modify: `Tests/AnglesiteAppTests/DeployModelTests.swift:22`

**Interfaces:**
- Consumes: `PreDeployCheck.ScanFailure`/`ScanWarning` from Task 1 (`message` required, `file`/`detail`/`remediation` optional; `Category` includes `.other`).
- Produces: nothing new — this task only fixes call sites broken by Task 1's type change.

- [ ] **Step 1: Update `Sources/AnglesiteApp/BlockedDeploySheetView.swift`**

Replace `FailureCard`'s body text and category functions:

```swift
private struct FailureCard: View {
    let failure: PreDeployCheck.ScanFailure

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: categoryIcon(failure.category))
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                Text(categoryLabel(failure.category))
                    .font(.subheadline).fontWeight(.semibold)
                if let file = failure.file {
                    Text(file)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        // Path is middle-truncated for layout; read the whole thing aloud.
                        .accessibilityLabel("File")
                        .accessibilityValue(file)
                }
            }
            Text(failure.detail ?? failure.message).font(.callout)
            if let remediation = failure.remediation {
                Text(remediation)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.red.opacity(0.25)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func categoryIcon(_ category: PreDeployCheck.ScanFailure.Category) -> String {
        switch category {
        case .piiEmail, .piiPhone, .piiSSN: return "person.crop.circle.badge.exclamationmark"
        case .exposedToken: return "key.fill"
        case .thirdPartyScript: return "network"
        case .keystaticRoute: return "lock.shield"
        case .cspMisconfigured: return "shield.slash"
        case .other: return "exclamationmark.triangle"
        }
    }

    private func categoryLabel(_ category: PreDeployCheck.ScanFailure.Category) -> String {
        switch category {
        case .piiEmail: return "PII — email address"
        case .piiPhone: return "PII — phone number"
        case .piiSSN: return "PII — SSN"
        case .exposedToken: return "Exposed token"
        case .thirdPartyScript: return "Third-party script"
        case .keystaticRoute: return "Keystatic admin route"
        case .cspMisconfigured: return "CSP misconfigured"
        case .other: return "Other"
        }
    }
```

Replace `WarningCard`'s body text and category label:

```swift
private struct WarningCard: View {
    let warning: PreDeployCheck.ScanWarning

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(categoryLabel(warning.category))
                    .font(.subheadline).fontWeight(.semibold)
            }
            Text(warning.detail ?? warning.message).font(.callout)
            if let remediation = warning.remediation {
                Text(remediation)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.orange.opacity(0.25)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func categoryLabel(_ category: PreDeployCheck.ScanWarning.Category) -> String {
        switch category {
        case .missingOgImage: return "Missing OG image"
        case .maintenanceOverdue: return "Maintenance overdue"
        case .seoCritical: return "SEO — critical"
        case .seoWarning: return "SEO — warning"
        case .orphanedRoute: return "Orphaned route"
        case .mixedContent: return "Mixed content"
        case .sriMissing: return "Missing subresource integrity"
        case .externalLinkRel: return "Missing rel=noopener"
        case .missingSecurityArtifact: return "Missing security artifact"
        case .thirdPartyScript: return "Third-party script"
        case .other: return "Other"
        }
    }
}
```

- [ ] **Step 2: Update `Sources/AnglesiteApp/HealthBadgeView.swift`'s `findingsList`**

Replace lines 171-206 (`findingsList`) with:

```swift
    @ViewBuilder
    private func findingsList(failures: [PreDeployCheck.ScanFailure], warnings: [PreDeployCheck.ScanWarning]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !failures.isEmpty {
                Text("Blocking (\(failures.count))").font(.subheadline.weight(.semibold))
                ForEach(failures.indices, id: \.self) { i in
                    let f = failures[i]
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.detail ?? f.message).font(.callout)
                            if let file = f.file {
                                Text(file).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            if let remediation = f.remediation {
                                Text(remediation).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if !warnings.isEmpty {
                Text("Warnings (\(warnings.count))").font(.subheadline.weight(.semibold))
                ForEach(warnings.indices, id: \.self) { i in
                    let w = warnings[i]
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(w.detail ?? w.message).font(.callout)
                            if let remediation = w.remediation {
                                Text(remediation).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
```

- [ ] **Step 3: Update `Tests/AnglesiteAppTests/DeployModelTests.swift`'s fixture**

Replace line 22:

```swift
                output: #"{"version":1,"ok":true,"failures":[],"warnings":[]}"#
```

- [ ] **Step 4: Run the `AnglesiteApp` test suite**

Run: `swift test --package-path . --filter AnglesiteAppTests`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/BlockedDeploySheetView.swift Sources/AnglesiteApp/HealthBadgeView.swift Tests/AnglesiteAppTests/DeployModelTests.swift
git commit -m "fix(app): render optional detail/remediation and .other category for #742"
```

---

### Task 3: Migrate `AnglesiteIntentsTests`

**Files:**
- Modify: `Tests/AnglesiteIntentsTests/DeploySiteIntentTests.swift:31-36`

**Interfaces:**
- Consumes: `PreDeployCheck.ScanFailure(category:message:file:detail:remediation:)` from Task 1.

- [ ] **Step 1: Update the construction site**

Replace (originally lines 31-36):

```swift
            let failure = PreDeployCheck.ScanFailure(
                category: .exposedToken,
                message: "API key committed",
                file: "src/index.md",
                remediation: "Remove it"
            )
```

- [ ] **Step 2: Run the `AnglesiteIntents` test suite**

Run: `swift test --package-path . --filter AnglesiteIntentsTests`
Expected: all tests pass. (Per CLAUDE.md, `AnglesiteIntentsTests` requires Swift 6.4+/Xcode 27 — if the toolchain doesn't support it, this filter yields no tests to run; that's expected in that environment, not a failure.)

- [ ] **Step 3: Commit**

```bash
git add Tests/AnglesiteIntentsTests/DeploySiteIntentTests.swift
git commit -m "fix(intents): migrate ScanFailure fixture to the #742 envelope shape"
```

---

### Task 4: Update `pre-deploy-check.ts` to emit the versioned envelope

**Files:**
- Modify: `Resources/Template/scripts/pre-deploy-check.ts` (full rewrite)
- Modify: `Resources/Template/scripts/pre-deploy-check.test.ts`

**Interfaces:**
- Produces: `npx tsx scripts/pre-deploy-check.ts --json` now prints `{"version":1,"ok":bool,"failures":[...],"warnings":[...]}` instead of a flat array. Each finding has `severity`, `category`, `message`, optional `file`.
- Consumes: nothing from earlier tasks (independent toolchain; only Task 5's fixture test bridges the two).

- [ ] **Step 1: Rewrite `Resources/Template/scripts/pre-deploy-check.ts`**

```typescript
#!/usr/bin/env npx tsx
/**
 * Pre-deploy security scan. Runs from the scaffolded site directory (not the template).
 *
 * Checks:
 * - No PII patterns (emails, phone numbers) in generated output
 * - No exposed API tokens or secrets
 * - No third-party tracking scripts
 * - No Keystatic admin routes in production output
 *
 * Usage: npx tsx scripts/pre-deploy-check.ts [--json]
 *
 * Exit code 0: all clear. Exit code 1: issues found.
 * With --json: prints the versioned {version, ok, failures, warnings} envelope (#742).
 */

import { readdir, readFile, stat } from "node:fs/promises";
import { join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseAllowedDomains } from "./csp";

interface Issue {
  severity: "error" | "warning";
  category: string;
  message: string;
  file?: string;
}

interface ScanReport {
  version: 1;
  ok: boolean;
  failures: Issue[];
  warnings: Issue[];
}

const JSON_MODE = process.argv.includes("--json");
const DIST_DIR = join(process.cwd(), "dist");
const HEADERS_FILE = join(DIST_DIR, "_headers");
const CONFIG_FILE = join(process.cwd(), ".site-config");

const PII_PATTERNS = [
  { name: "email", pattern: /[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/g },
  { name: "phone", pattern: /\b\d{3}[-.]?\d{3}[-.]?\d{4}\b/g },
  { name: "SSN", pattern: /\b\d{3}-\d{2}-\d{4}\b/g },
];

const SECRET_PATTERNS = [
  { name: "API key", pattern: /(?:api[_-]?key|apikey)\s*[:=]\s*["']?[a-zA-Z0-9_-]{20,}/gi },
  { name: "AWS key", pattern: /AKIA[0-9A-Z]{16}/g },
  { name: "private key", pattern: /-----BEGIN (?:RSA |EC )?PRIVATE KEY-----/g },
];

// Trackers with no first-party integration in this catalog. Google Analytics/Tag
// Manager are deliberately absent — the `tracking` integration (ga4 provider) makes
// them a supported, owner-opted-in choice, the same way Plausible/Fathom always were.
const BLOCKED_SCRIPTS = [
  /facebook\.net.*fbevents/i,
  /hotjar\.com/i,
];

const BLOCKED_ROUTES = [/\/keystatic(?:\/|$)/i, /\/api\/keystatic/i];

async function* walk(dir: string): AsyncGenerator<string> {
  const entries = await readdir(dir, { withFileTypes: true });
  for (const entry of entries) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) yield* walk(full);
    else yield full;
  }
}

/**
 * Validate the generated CSP. Returns one error Issue per problem:
 * missing _headers, no CSP directive, or a configured SCRIPT_ALLOW domain
 * absent from the CSP.
 */
export function checkHeaders(headersContent: string | null, configContent: string): Issue[] {
  const issues: Issue[] = [];
  if (headersContent === null) {
    issues.push({ severity: "error", category: "csp-misconfigured", message: "No dist/_headers — CSP is not enforced.", file: "_headers" });
    return issues;
  }
  const cspLine = headersContent
    .split("\n")
    .map((l) => l.trim())
    .find((l) => l.startsWith("Content-Security-Policy:"));
  if (!cspLine) {
    issues.push({ severity: "error", category: "csp-misconfigured", message: "dist/_headers has no Content-Security-Policy.", file: "_headers" });
    return issues;
  }
  const cspTokens = new Set(
    cspLine
      .replace(/^Content-Security-Policy:/, "")
      .split(/[\s;]+/)
      .filter((t) => t.length > 0),
  );
  const allow = parseAllowedDomains(configContent);
  for (const domain of allow) {
    if (!cspTokens.has(domain)) {
      issues.push({
        severity: "error",
        category: "csp-misconfigured",
        message: `Configured integration domain "${domain}" is missing from the CSP.`,
        file: "_headers",
      });
    }
  }
  return issues;
}

/**
 * Scan built content for likely PII (email, phone, SSN). An email that appears only as a
 * `mailto:` link target is published intent — e.g. a contact-form fallback the site owner
 * deliberately configured — not accidental exposure, so it's stripped before the email check.
 * Phone/SSN patterns are unaffected. One issue per pattern per file, matching the prior inline
 * scan's behavior.
 */
export function checkPII(content: string, file: string): Issue[] {
  const issues: Issue[] = [];
  const withoutMailtoLinks = content.replace(
    /mailto:[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/g,
    "",
  );
  for (const { name, pattern } of PII_PATTERNS) {
    pattern.lastIndex = 0;
    const haystack = name === "email" ? withoutMailtoLinks : content;
    if (pattern.test(haystack)) {
      issues.push({
        severity: "error",
        category: `pii-${name.toLowerCase()}`,
        message: `Possible ${name} found`,
        file,
      });
    }
  }
  return issues;
}

/**
 * Insecure (http://) subresource references in built HTML/CSS. Targets resource
 * attributes (`src`) and CSS `url(...)` only — NOT `href` — so anchor links and
 * `xmlns="http://..."` declarations do not false-positive. Advisory: slice A's
 * `upgrade-insecure-requests` auto-upgrades these at runtime. One issue per file.
 */
export function checkMixedContent(content: string, file: string): Issue[] {
  const patterns = [/\bsrc\s*=\s*["']http:\/\//i, /url\(\s*["']?http:\/\//i];
  for (const pattern of patterns) {
    if (pattern.test(content)) {
      return [{ severity: "warning", category: "mixed-content", message: "Mixed content: insecure http:// resource reference", file }];
    }
  }
  return [];
}

/**
 * External (absolute or protocol-relative) <script> and stylesheet <link> tags
 * with a subresource-integrity problem: either missing `integrity`, or carrying
 * `integrity` without the `crossorigin` attribute it requires — the browser
 * blocks the response on CORS before integrity is evaluated, so the resource
 * silently fails to load. Heuristic tag-level regex match; multi-line tag
 * attributes are not matched. One issue per offending tag.
 */
export function checkSRI(content: string, file: string): Issue[] {
  const issues: Issue[] = [];
  const tagPattern = /<(script|link)\b[^>]*>/gi;
  let m: RegExpExecArray | null;
  while ((m = tagPattern.exec(content)) !== null) {
    const tag = m[0];
    const isScript = m[1].toLowerCase() === "script";
    const urlAttr = isScript
      ? /\bsrc\s*=\s*["'](?:https?:)?\/\//i
      : /\bhref\s*=\s*["'](?:https?:)?\/\//i;
    if (!urlAttr.test(tag)) continue;
    if (!isScript && !/\brel\s*=\s*["'][^"']*stylesheet/i.test(tag)) continue;
    const kind = isScript ? "script" : "stylesheet";
    if (!/\bintegrity\s*=/i.test(tag)) {
      issues.push({ severity: "warning", category: "sri-missing", message: `External ${kind} without subresource integrity (SRI)`, file });
    } else if (!/\scrossorigin\b/i.test(tag)) {
      issues.push({
        severity: "warning",
        category: "sri-missing",
        message: `External ${kind} has integrity but is missing crossorigin (will fail CORS)`,
        file,
      });
    }
  }
  return issues;
}

/**
 * Anchors that open a new tab (`target="_blank"`) without `rel="noopener"`,
 * which can expose `window.opener`. `rel="noreferrer"` also implies noopener
 * (per the HTML spec and all modern browsers), so either token is accepted.
 * Advisory — modern browsers imply noopener, but explicit is safer. One issue
 * per offending anchor.
 */
export function checkExternalLinkRel(content: string, file: string): Issue[] {
  const issues: Issue[] = [];
  const anchorPattern = /<a\b[^>]*>/gi;
  let m: RegExpExecArray | null;
  while ((m = anchorPattern.exec(content)) !== null) {
    const tag = m[0];
    if (!/\btarget\s*=\s*["']_blank["']/i.test(tag)) continue;
    const relMatch = tag.match(/\brel\s*=\s*["']([^"']*)["']/i);
    const rel = relMatch ? relMatch[1].toLowerCase() : "";
    if (!/\bnoopener\b|\bnoreferrer\b/.test(rel)) {
      issues.push({ severity: "warning", category: "external-link-rel", message: 'Link with target="_blank" missing rel="noopener"', file });
    }
  }
  return issues;
}

/**
 * Warn when expected security artifacts are absent from the built output.
 * `scripts/edge-artifacts.ts` (C1) generates these at build: robots.txt always,
 * security.txt only when `SECURITY_CONTACT` is set in `.site-config`.
 */
export function checkArtifactPresence(relPaths: string[]): Issue[] {
  const set = new Set(relPaths.map((p) => p.replace(/\\/g, "/")));
  const required = ["dist/robots.txt", "dist/.well-known/security.txt"];
  const issues: Issue[] = [];
  for (const path of required) {
    if (!set.has(path)) {
      issues.push({
        severity: "warning",
        category: "missing-security-artifact",
        message: `Missing security artifact: ${path.replace(/^dist\//, "")}`,
        file: path,
      });
    }
  }
  return issues;
}

async function scan(): Promise<Issue[]> {
  const issues: Issue[] = [];

  try {
    await stat(DIST_DIR);
  } catch {
    issues.push({ severity: "warning", category: "missing-security-artifact", message: "No dist/ directory found — nothing to scan." });
    return issues;
  }

  const headersContent = await readFile(HEADERS_FILE, "utf-8").catch((e: NodeJS.ErrnoException) =>
    e.code === "ENOENT" ? null : Promise.reject(e),
  );
  const configContent = await readFile(CONFIG_FILE, "utf-8").catch((e: NodeJS.ErrnoException) =>
    e.code === "ENOENT" ? "" : Promise.reject(e),
  );
  issues.push(...checkHeaders(headersContent, configContent));

  const relPaths: string[] = [];

  for await (const file of walk(DIST_DIR)) {
    if (!/\.(html?|js|css|json|xml|txt)$/i.test(file)) continue;
    const content = await readFile(file, "utf-8");
    const rel = relative(process.cwd(), file);
    relPaths.push(rel);

    issues.push(...checkPII(content, rel));

    for (const { name, pattern } of SECRET_PATTERNS) {
      pattern.lastIndex = 0;
      if (pattern.test(content)) {
        issues.push({ severity: "error", category: "exposed-token", message: `Possible ${name} exposed`, file: rel });
      }
    }

    if (/\.(html?|css)$/i.test(file)) {
      issues.push(...checkMixedContent(content, rel));
    }

    if (/\.html?$/i.test(file)) {
      for (const pattern of BLOCKED_SCRIPTS) {
        if (pattern.test(content)) {
          issues.push({
            severity: "warning",
            category: "third-party-script",
            message: `Third-party tracking script detected: ${pattern.source}`,
            file: rel,
          });
        }
      }

      for (const pattern of BLOCKED_ROUTES) {
        if (pattern.test(content)) {
          issues.push({
            severity: "error",
            category: "keystatic-route",
            message: "Keystatic admin route found in production output",
            file: rel,
          });
        }
      }

      issues.push(...checkSRI(content, rel));
      issues.push(...checkExternalLinkRel(content, rel));
    }
  }

  issues.push(...checkArtifactPresence(relPaths));

  return issues;
}

async function main() {
  const issues = await scan();
  const failures = issues.filter((i) => i.severity === "error");
  const warnings = issues.filter((i) => i.severity === "warning");

  if (JSON_MODE) {
    const report: ScanReport = { version: 1, ok: failures.length === 0, failures, warnings };
    process.stdout.write(JSON.stringify(report, null, 2) + "\n");
  } else {
    if (issues.length === 0) {
      console.log("Pre-deploy check passed — no issues found.");
    } else {
      for (const issue of issues) {
        const prefix = issue.severity === "error" ? "ERROR" : "WARN";
        const loc = issue.file ? ` (${issue.file})` : "";
        console.log(`[${prefix}] ${issue.message}${loc}`);
      }
    }
  }

  process.exit(failures.length > 0 ? 1 : 0);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main();
}
```

- [ ] **Step 2: Update `Resources/Template/scripts/pre-deploy-check.test.ts` with category assertions**

Add a `category` assertion to each test that previously only checked `severity`/`message`. Replace the full file contents:

```typescript
import test from "node:test";
import assert from "node:assert/strict";
import { checkHeaders, checkMixedContent, checkSRI, checkExternalLinkRel, checkArtifactPresence, checkPII } from "./pre-deploy-check";

const GOOD = `/*
  Content-Security-Policy: default-src 'self'; frame-src 'self' js.stripe.com
`;

test("missing _headers is an error", () => {
  const issues = checkHeaders(null, "");
  assert.equal(issues.length, 1);
  assert.equal(issues[0].severity, "error");
  assert.equal(issues[0].category, "csp-misconfigured");
  assert.match(issues[0].message, /not enforced/);
});

test("_headers without a CSP is an error", () => {
  const issues = checkHeaders("/*\n  X-Frame-Options: DENY\n", "");
  assert.equal(issues.length, 1);
  assert.equal(issues[0].category, "csp-misconfigured");
  assert.match(issues[0].message, /no Content-Security-Policy/);
});

test("configured domain missing from CSP is an error naming the domain", () => {
  const issues = checkHeaders(GOOD, "SCRIPT_ALLOW=js.stripe.com,giscus.app");
  assert.equal(issues.length, 1);
  assert.equal(issues[0].category, "csp-misconfigured");
  assert.match(issues[0].message, /giscus\.app/);
});

test("CSP covering all configured domains passes", () => {
  assert.deepEqual(checkHeaders(GOOD, "SCRIPT_ALLOW=js.stripe.com"), []);
});

test("no SCRIPT_ALLOW: a present CSP passes", () => {
  assert.deepEqual(checkHeaders(GOOD, ""), []);
});

test("multiple configured domains missing from CSP each produce an error", () => {
  const issues = checkHeaders(GOOD, "SCRIPT_ALLOW=giscus.app,assets.calendly.com");
  assert.equal(issues.length, 2);
  assert.ok(issues.every((i) => i.severity === "error"));
  assert.ok(issues.every((i) => i.category === "csp-misconfigured"));
  assert.ok(issues.some((i) => /giscus\.app/.test(i.message)));
  assert.ok(issues.some((i) => /assets\.calendly\.com/.test(i.message)));
});

test("substring of an allowed domain does not satisfy coverage", () => {
  const headers = `/*\n  Content-Security-Policy: default-src 'self'; frame-src 'self' app.cal.com\n`;
  const issues = checkHeaders(headers, "SCRIPT_ALLOW=cal.com");
  assert.equal(issues.length, 1);
  assert.equal(issues[0].severity, "error");
  assert.match(issues[0].message, /cal\.com/);
});

test("checkPII: flags a bare email in page content", () => {
  const issues = checkPII("<p>Contact us at hello@example.com</p>", "dist/index.html");
  assert.equal(issues.length, 1);
  assert.equal(issues[0].severity, "error");
  assert.equal(issues[0].category, "pii-email");
  assert.match(issues[0].message, /email/);
});

test("checkPII: does not flag an email that only appears as a mailto: link target", () => {
  const issues = checkPII('<a href="mailto:hello@example.com">Email us</a>', "dist/contact.html");
  assert.deepEqual(issues, []);
});

test("checkPII: still flags a bare email elsewhere on a page that also has a mailto link", () => {
  const html = '<a href="mailto:hello@example.com">Email us</a><p>debug: admin@internal.example.com</p>';
  const issues = checkPII(html, "dist/contact.html");
  assert.equal(issues.length, 1);
  assert.equal(issues[0].category, "pii-email");
  assert.match(issues[0].message, /email/);
});

test("checkPII: still flags phone numbers regardless of mailto content", () => {
  const issues = checkPII('<a href="mailto:hello@example.com">Email</a> Call 555-123-4567', "dist/contact.html");
  assert.equal(issues.length, 1);
  assert.equal(issues[0].category, "pii-phone");
  assert.match(issues[0].message, /phone/);
});

test("checkPII: flags an SSN with the pii-ssn category", () => {
  const issues = checkPII("<p>SSN: 123-45-6789</p>", "dist/contact.html");
  assert.equal(issues.length, 1);
  assert.equal(issues[0].category, "pii-ssn");
});

test("checkMixedContent: flags an insecure src", () => {
  const issues = checkMixedContent('<img src="http://example.com/a.png">', "dist/index.html");
  assert.equal(issues.length, 1);
  assert.equal(issues[0].severity, "warning");
  assert.equal(issues[0].category, "mixed-content");
  assert.match(issues[0].message, /mixed content/i);
  assert.equal(issues[0].file, "dist/index.html");
});

test("checkMixedContent: flags an insecure url() in CSS", () => {
  const issues = checkMixedContent("body { background: url(http://x.com/bg.png); }", "dist/a.css");
  assert.equal(issues.length, 1);
});

test("checkMixedContent: https and relative refs are clean", () => {
  const ok = '<img src="https://x.com/a.png"><script src="/local.js"></script>';
  assert.deepEqual(checkMixedContent(ok, "dist/index.html"), []);
});

test("checkMixedContent: svg xmlns http URL is not flagged", () => {
  const svg = '<svg xmlns="http://www.w3.org/2000/svg"></svg>';
  assert.deepEqual(checkMixedContent(svg, "dist/index.html"), []);
});

test("checkMixedContent: at most one issue per file", () => {
  const two = '<img src="http://a.com/1.png"><img src="http://b.com/2.png">';
  assert.equal(checkMixedContent(two, "dist/index.html").length, 1);
});

test("checkSRI: external script without integrity is a warning", () => {
  const issues = checkSRI('<script src="https://cdn.x.com/a.js"></script>', "dist/index.html");
  assert.equal(issues.length, 1);
  assert.equal(issues[0].severity, "warning");
  assert.equal(issues[0].category, "sri-missing");
  assert.match(issues[0].message, /integrity/i);
});

test("checkSRI: external script with integrity AND crossorigin is clean", () => {
  const ok = '<script src="https://cdn.x.com/a.js" integrity="sha384-abc" crossorigin="anonymous"></script>';
  assert.deepEqual(checkSRI(ok, "dist/index.html"), []);
});

test("checkSRI: integrity without crossorigin is a warning (CORS would block it)", () => {
  const issues = checkSRI('<script src="https://cdn.x.com/a.js" integrity="sha384-abc"></script>', "dist/index.html");
  assert.equal(issues.length, 1);
  assert.match(issues[0].message, /crossorigin/i);
});

test("checkSRI: relative script is clean", () => {
  assert.deepEqual(checkSRI('<script src="/local.js"></script>', "dist/index.html"), []);
});

test("checkSRI: external stylesheet link without integrity is a warning", () => {
  const issues = checkSRI('<link rel="stylesheet" href="https://cdn.x.com/a.css">', "dist/index.html");
  assert.equal(issues.length, 1);
});

test("checkSRI: non-stylesheet link is ignored", () => {
  assert.deepEqual(checkSRI('<link rel="preconnect" href="https://x.com">', "dist/index.html"), []);
});

test("checkExternalLinkRel: target=_blank without rel=noopener is a warning", () => {
  const issues = checkExternalLinkRel('<a href="https://x.com" target="_blank">x</a>', "dist/index.html");
  assert.equal(issues.length, 1);
  assert.equal(issues[0].severity, "warning");
  assert.equal(issues[0].category, "external-link-rel");
  assert.match(issues[0].message, /noopener/i);
});

test("checkExternalLinkRel: rel=noopener is clean", () => {
  const ok = '<a href="https://x.com" target="_blank" rel="noopener">x</a>';
  assert.deepEqual(checkExternalLinkRel(ok, "dist/index.html"), []);
});

test("checkExternalLinkRel: rel with noopener among others is clean", () => {
  const ok = '<a href="https://x.com" target="_blank" rel="noopener noreferrer">x</a>';
  assert.deepEqual(checkExternalLinkRel(ok, "dist/index.html"), []);
});

test("checkExternalLinkRel: rel=noreferrer alone is clean (implies noopener)", () => {
  const ok = '<a href="https://x.com" target="_blank" rel="noreferrer">x</a>';
  assert.deepEqual(checkExternalLinkRel(ok, "dist/index.html"), []);
});

test("checkExternalLinkRel: link without target=_blank is ignored", () => {
  assert.deepEqual(checkExternalLinkRel('<a href="https://x.com">x</a>', "dist/index.html"), []);
});

test("checkArtifactPresence: both present is clean", () => {
  const paths = ["dist/index.html", "dist/robots.txt", "dist/.well-known/security.txt"];
  assert.deepEqual(checkArtifactPresence(paths), []);
});

test("checkArtifactPresence: missing robots.txt is a warning", () => {
  const issues = checkArtifactPresence(["dist/index.html", "dist/.well-known/security.txt"]);
  assert.equal(issues.length, 1);
  assert.equal(issues[0].severity, "warning");
  assert.equal(issues[0].category, "missing-security-artifact");
  assert.match(issues[0].message, /robots\.txt/);
});

test("checkArtifactPresence: missing both yields two warnings", () => {
  const issues = checkArtifactPresence(["dist/index.html"]);
  assert.equal(issues.length, 2);
});

test("checkArtifactPresence: backslash paths are normalized", () => {
  const paths = ["dist\\robots.txt", "dist\\.well-known\\security.txt"];
  assert.deepEqual(checkArtifactPresence(paths), []);
});
```

- [ ] **Step 3: Run the TS test suite**

Run: `cd Resources/Template && npx tsx --test scripts/pre-deploy-check.test.ts`
Expected: all tests pass (32 tests — the 31 existing plus the new `pii-ssn` category test).

- [ ] **Step 4: Manually verify the envelope shape against a real fixture**

Run:
```bash
cd /tmp && rm -rf pdc-verify && mkdir -p pdc-verify/dist && cd pdc-verify
echo '<html><body><p>Contact us at hello@example.com</p></body></html>' > dist/index.html
npx --prefix /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/focused-shaw-9f716a/Resources/Template tsx /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/focused-shaw-9f716a/Resources/Template/scripts/pre-deploy-check.ts --json
```
Expected output (exit code 1):
```json
{
  "version": 1,
  "ok": false,
  "failures": [
    { "severity": "error", "category": "csp-misconfigured", "message": "No dist/_headers — CSP is not enforced.", "file": "_headers" },
    { "severity": "error", "category": "pii-email", "message": "Possible email found", "file": "dist/index.html" }
  ],
  "warnings": [
    { "severity": "warning", "category": "missing-security-artifact", "message": "Missing security artifact: robots.txt", "file": "dist/robots.txt" },
    { "severity": "warning", "category": "missing-security-artifact", "message": "Missing security artifact: .well-known/security.txt", "file": "dist/.well-known/security.txt" }
  ]
}
```
Then clean up: `rm -rf /tmp/pdc-verify`

- [ ] **Step 5: Commit**

```bash
git add Resources/Template/scripts/pre-deploy-check.ts Resources/Template/scripts/pre-deploy-check.test.ts
git commit -m "feat(template): emit the versioned pre-deploy scan envelope for #742

Every Issue now carries a stable category code; main() wraps the flat
issue list into {version, ok, failures, warnings} for --json output.
Human-readable output and exit-code semantics are unchanged."
```

---

### Task 5: Add the producer→consumer fixture test

**Files:**
- Create: `Tests/AnglesiteCoreTests/PreDeployCheckFixtureTests.swift`

**Interfaces:**
- Consumes: `PreDeployCheck.parse(output:exitCode:)` (Task 1), the real `Resources/Template/scripts/pre-deploy-check.ts` (Task 4) — this is the test that proves those two agree.

This is the gap #742 exists to close: every other test hand-authors JSON in the Swift-expected shape. This test runs the actual TypeScript script and feeds its actual stdout through the actual Swift decoder.

- [ ] **Step 1: Write the fixture test**

```swift
import Testing
import Foundation
@testable import AnglesiteCore

/// Runs the REAL `pre-deploy-check.ts --json` (not a hand-authored JSON string) against a small
/// fixture `dist/` and decodes its actual stdout through `PreDeployCheck.parse` — the
/// producer→consumer test #742 exists to add. Every other test in this suite hand-authors JSON in
/// the Swift-expected shape, which is exactly how the envelope mismatch this issue fixes went
/// uncaught for so long.
struct PreDeployCheckFixtureTests {
    private static var templateScriptsDirectory: URL {
        // Tests/AnglesiteCoreTests/PreDeployCheckFixtureTests.swift -> repo root -> Resources/Template/scripts
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Template/scripts", isDirectory: true)
    }

    private func makeFixtureDist(html: String) throws -> URL {
        let siteDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreDeployCheckFixtureTests-\(UUID().uuidString)", isDirectory: true)
        let distDir = siteDir.appendingPathComponent("dist", isDirectory: true)
        try FileManager.default.createDirectory(at: distDir, withIntermediateDirectories: true)
        try html.write(to: distDir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        return siteDir
    }

    /// Runs `npx tsx <template>/scripts/pre-deploy-check.ts --json` with `siteDir` as cwd and
    /// returns captured stdout + exit code.
    private func runRealScript(siteDir: URL) throws -> (stdout: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["npx", "tsx", Self.templateScriptsDirectory.appendingPathComponent("pre-deploy-check.ts").path, "--json"]
        process.currentDirectoryURL = siteDir
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (stdout: String(data: data, encoding: .utf8) ?? "", exitCode: process.terminationStatus)
    }

    @Test("Real script output with a PII hit decodes to .blocked with the pii-email category")
    func realScriptWithPIIDecodesToBlocked() throws {
        let siteDir = try makeFixtureDist(html: "<html><body><p>Contact us at hello@example.com</p></body></html>")
        defer { try? FileManager.default.removeItem(at: siteDir) }

        let result = try runRealScript(siteDir: siteDir)
        #expect(result.exitCode == 1)

        let outcome = PreDeployCheck.parse(output: result.stdout, exitCode: result.exitCode)
        guard case .blocked(let failures, let warnings) = outcome else {
            Issue.record("expected .blocked, got \(outcome) — raw stdout: \(result.stdout)")
            return
        }
        #expect(failures.contains { $0.category == .piiEmail })
        // No dist/_headers in this minimal fixture — CSP misconfiguration is also expected.
        #expect(failures.contains { $0.category == .cspMisconfigured })
        // No robots.txt / security.txt in this minimal fixture.
        #expect(warnings.contains { $0.category == .missingSecurityArtifact })
    }

    @Test("Real script output with no issues decodes to .passed")
    func realScriptWithNoIssuesDecodesToPassed() throws {
        let siteDir = try makeFixtureDist(html: "<html><body><p>Nothing sensitive here.</p></body></html>")
        defer { try? FileManager.default.removeItem(at: siteDir) }
        // A CSP-satisfying _headers file and both security artifacts, so this fixture is fully clean.
        try "/*\n  Content-Security-Policy: default-src 'self'\n".write(
            to: siteDir.appendingPathComponent("dist/_headers"), atomically: true, encoding: .utf8)
        try "User-agent: *\n".write(
            to: siteDir.appendingPathComponent("dist/robots.txt"), atomically: true, encoding: .utf8)
        let wellKnown = siteDir.appendingPathComponent("dist/.well-known", isDirectory: true)
        try FileManager.default.createDirectory(at: wellKnown, withIntermediateDirectories: true)
        try "Contact: mailto:security@example.com\n".write(
            to: wellKnown.appendingPathComponent("security.txt"), atomically: true, encoding: .utf8)

        let result = try runRealScript(siteDir: siteDir)
        #expect(result.exitCode == 0)

        let outcome = PreDeployCheck.parse(output: result.stdout, exitCode: result.exitCode)
        guard case .passed(let warnings) = outcome else {
            Issue.record("expected .passed, got \(outcome) — raw stdout: \(result.stdout)")
            return
        }
        #expect(warnings.isEmpty)
    }
}
```

- [ ] **Step 2: Run it**

Run: `swift test --package-path . --filter PreDeployCheckFixtureTests`
Expected: both tests pass. (Requires `npx`/`tsx` to be resolvable on `PATH`, same as the rest of the deploy pipeline's dev dependency — if `npx` isn't available in this environment, these two tests will fail with a spawn error; that's an environment gap, not a logic bug, and matches how `HostExecutorParity` in `DeployCommandTests.swift` already depends on `/bin/sh` being present.)

- [ ] **Step 3: Commit**

```bash
git add Tests/AnglesiteCoreTests/PreDeployCheckFixtureTests.swift
git commit -m "test(core): add real producer->consumer fixture test for #742

Runs the actual pre-deploy-check.ts --json and decodes its actual
stdout through PreDeployCheck.parse, closing the gap where every other
test hand-authored JSON in the Swift-expected shape."
```

---

### Task 6: Full verification and wrap-up

**Files:** none (verification only)

- [ ] **Step 1: Run the full Swift test suite**

Run: `swift test --package-path .`
Expected: all suites pass (`AnglesiteSiteModelTests`, `AnglesiteCoreTests`, `AnglesiteBridgeTests`, `AnglesiteAppTests`, and `AnglesiteIntentsTests` if the toolchain supports it per CLAUDE.md). If any failure is unrelated to this change (e.g. a known-flaky FM/live-model test), note it explicitly rather than treating the run as failed.

- [ ] **Step 2: Run the TS test suite once more**

Run: `cd Resources/Template && npx tsx --test scripts/pre-deploy-check.test.ts`
Expected: all tests pass.

- [ ] **Step 3: Confirm `xcodebuild` still builds the app target**

Run: `xcodegen generate && xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: `** BUILD SUCCEEDED **` — confirms `BlockedDeploySheetView`/`HealthBadgeView`'s UI changes compile in the real app target, not just the SwiftPM test targets.

- [ ] **Step 4: Update the GitHub issue**

```bash
gh issue edit 742 --remove-label status:in-progress
```

(Leave the actual issue-closing to the PR — per repo convention, "Closes #742" belongs in the PR description, not a manual close here.)
