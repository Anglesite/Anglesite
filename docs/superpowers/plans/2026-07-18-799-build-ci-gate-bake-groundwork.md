# build:ci gate + CMS bake groundwork (#799) Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every non-interactive builder (future Worker-triggered bake container, Workers Builds, and — proven now — the Swift test suite) a single `build:ci` entry point whose JSON envelope the app can parse out of a noisy log, add the pluggable content-layer loader seam CMS mode will need, and start uploading a one-way `Source/` snapshot to R2 on every desktop deploy so the contracts are proven before any Worker consumes them.

**Architecture:** Five independent-but-related surfaces, each following an existing in-repo pattern rather than inventing a new one: (1) the template's `pre-deploy-check.ts` gains a `--strict` flag and `package.json` gains a `build:ci` script that chains build + strict scan; (2) a new `BuildLogEnvelope` type in `AnglesiteCore` extracts `PreDeployCheck`'s versioned JSON envelope out of a larger, noisier log (falling back to a raw excerpt), reusing `PreDeployCheck.parse` rather than re-implementing decoding; (3) `src/content.config.ts` gains a loader-selection seam (`glob()` vs. a new Worker content-API loader) for the `blog` collection, chosen via the existing `.site-config`/`readConfig` convention; (4) `DeployCommand` gains a fourth `DeployStep` (`.bundleUpload`) that tars `Source/` and uploads it to R2 via `wrangler r2 object put`, gated on an as-yet-unprovisioned `.site-config` key (`CF_SOURCE_BUCKET`) so it's a documented no-op today and activates the moment V-3 provisioning starts writing that key; (5) a small `SourceBundleStatus` helper plus one line of `DeployDrawerView` UI surfaces "code changes not yet deployed" by comparing the persisted uploaded commit SHA (via `SiteConfigStore`) against `Source/`'s current HEAD (via `InProcessGit`).

**Tech Stack:** Swift 6.4 (AnglesiteCore, AnglesiteApp, Swift Testing), TypeScript/Node (Astro 6 template, `node:test` + `node:assert/strict` for `scripts/*.test.ts`).

## Global Constraints

- Follow `CONTRIBUTING.md`: conventional commits referencing `#799`, keep the PR focused, no new dependencies without approval (this plan adds none).
- No LLM in the loop anywhere in this slice (per #459 direction) — everything here is deterministic Swift/TypeScript.
- `PreDeployCheck.parse`/`DeployCommand.parseScanReport` remain the single JSON-envelope decoder (#742) — the new log-extraction utility must delegate to `PreDeployCheck.parse`, never re-declare the envelope shape.
- `.site-config` reads go through the existing helpers: TypeScript via `readConfig()` (`scripts/config.ts`), Swift via `SiteConfigFile.value(forKey:in:)` (`Sources/AnglesiteCore/SiteConfigFile.swift`). Never hand-roll a second config parser.
- The app cannot bypass the pre-deploy security gate (CLAUDE.md) — nothing in this plan adds an override path.
- `swift test --package-path .` and `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build` must stay green after every Swift task. `Resources/Template` changes additionally need `npm run build` (from `Resources/Template`) to stay green, per CONTRIBUTING.md's "if you touch `Resources/Template/`, run `swift test` too."

---

## File Structure

New files:

- `Sources/AnglesiteCore/BuildLogEnvelope.swift` — extracts the `PreDeployCheck` JSON envelope from a larger log string.
- `Tests/AnglesiteCoreTests/BuildLogEnvelopeTests.swift` — unit tests for the extractor.
- `Sources/AnglesiteCore/SourceBundleStatus.swift` — dirty-state helper (persisted commit SHA vs. current HEAD).
- `Tests/AnglesiteCoreTests/SourceBundleStatusTests.swift` — unit tests for the helper.
- `Resources/Template/src/lib/content-loader.ts` — the CMS content-API `Loader` (Astro Content Layer API), selected alongside `glob()`.
- `Resources/Template/src/lib/content-loader.test.ts` — `node:test` unit tests for the loader.

Modified files:

- `Resources/Template/scripts/pre-deploy-check.ts` — `--strict` flag.
- `Resources/Template/scripts/pre-deploy-check.test.ts` — tests for `--strict`.
- `Resources/Template/package.json` — `build:ci` script.
- `Resources/Template/src/content.config.ts` — loader-selection seam for `blog`.
- `Tests/AnglesiteCoreTests/PreDeployCheckFixtureTests.swift` — producer/consumer tests for `build:ci`.
- `Sources/AnglesiteCore/DeployExecutor.swift` — new `DeployStep.bundleUpload` case + argv mapping + default host resolver.
- `Sources/AnglesiteCore/DeployCommand.swift` — orchestrates the bundle-upload step post-deploy; persists the uploaded commit SHA.
- `Sources/AnglesiteCore/SiteConfigStore.swift` — new optional `SiteSettings.deployedSourceBundleCommit` field.
- `Tests/AnglesiteCoreTests/DeployCommandTests.swift` — `FakeExecutor` gains the new step; new orchestration tests.
- `Sources/AnglesiteApp/DeployDrawerView.swift` — one line surfacing "code changes not yet deployed."

---

## Task 1: `--strict` flag + `build:ci` script (template)

**Files:**
- Modify: `Resources/Template/scripts/pre-deploy-check.ts`
- Modify: `Resources/Template/scripts/pre-deploy-check.test.ts`
- Modify: `Resources/Template/package.json`

**Interfaces:**
- Produces: `npm run build:ci` (chains `npm run build` then `npx tsx scripts/pre-deploy-check.ts --json --strict`, non-zero exit on any blocker). `--strict` CLI flag on `pre-deploy-check.ts` — when present, warnings are promoted into the `failures` array of the `--json` envelope (and cause a non-zero exit), while `--json`'s human-readable mode (no `--strict`) is unaffected. Consumed by Task 3's producer test.

- [ ] **Step 1: Write the failing test for `--strict` promoting warnings to failures**

Add to `Resources/Template/scripts/pre-deploy-check.test.ts` (append at end of file):

```ts
import { checkArtifactPresence } from "./pre-deploy-check";

test("--strict promotes warnings into failures for exit-code purposes (unit-level check on the promotion helper)", () => {
  // checkArtifactPresence always returns warnings (missing-security-artifact) — this test
  // documents the contract main() relies on: in --strict mode, ALL warnings (not just this
  // category) become failures. The end-to-end exit-code behavior is covered by the real-script
  // fixture tests in PreDeployCheckFixtureTests.swift (Swift side, #799 Task 3), since --strict's
  // effect lives in main()'s promotion logic, not in an exported pure function.
  const warnings = checkArtifactPresence([]);
  assert.equal(warnings.length, 2);
  assert.ok(warnings.every((w) => w.severity === "warning"));
});
```

This is a light unit-level placeholder — the real behavioral proof (`--strict` flips exit code) is a real-script fixture test, which needs a real `dist/` and belongs in Task 3 on the Swift side (matching how `PreDeployCheckFixtureTests.swift` already tests the *real* script, not a reimplementation). Run it now to confirm it passes trivially (it exercises existing code) — this step exists to lock the `checkArtifactPresence` contract this task's `main()` change depends on before touching `main()`.

- [ ] **Step 2: Run test to verify it passes (baseline, no `main()` change yet)**

Run: `cd Resources/Template && node --import tsx --test scripts/pre-deploy-check.test.ts`
Expected: `# pass 33` (32 existing + 1 new), `# fail 0`.

- [ ] **Step 3: Add the `--strict` flag to `pre-deploy-check.ts`**

In `Resources/Template/scripts/pre-deploy-check.ts`, update the usage comment and flag parsing (around line 11-14 and 36):

```ts
/**
 * Usage: npx tsx scripts/pre-deploy-check.ts [--json] [--strict]
 *
 * Exit code 0: all clear. Exit code 1: issues found.
 * With --json: prints the versioned {version, ok, failures, warnings} envelope (#742).
 * With --strict: warnings are promoted into `failures` (both in the --json envelope and for
 * exit-code purposes) — used by `npm run build:ci`, the single entry point for non-interactive
 * runners (#799), where a warning-only issue must still block an automated bake/deploy.
 */
```

```ts
const JSON_MODE = process.argv.includes("--json");
const STRICT_MODE = process.argv.includes("--strict");
```

Update `main()` (currently lines 307-328) to promote warnings when `STRICT_MODE` is set, and reflect it in the JSON output:

```ts
async function main() {
  const issues = await scan();
  let failures = issues.filter((i) => i.severity === "error");
  let warnings = issues.filter((i) => i.severity === "warning");

  if (STRICT_MODE) {
    failures = failures.concat(warnings);
    warnings = [];
  }

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
```

Note: `failures`/`warnings` change from `const` to `let` here since `--strict` reassigns them.

- [ ] **Step 4: Add `build:ci` to `package.json`**

In `Resources/Template/package.json`, add to the `scripts` block (after `"check"`):

```jsonc
"check": "npx tsx scripts/pre-deploy-check.ts",
"build:ci": "npm run build && npx tsx scripts/pre-deploy-check.ts --json --strict",
"test:worker": "vitest run --config vitest.config.ts"
```

- [ ] **Step 5: Run the template's own build to confirm nothing broke**

Run: `cd Resources/Template && npm run build`
Expected: exits 0 (this only exercises `astro check && astro build && check-microformats` — `build:ci` itself needs `dist/` populated by this same `build` step, verified end-to-end in Task 3).

Run: `cd Resources/Template && node --import tsx --test scripts/pre-deploy-check.test.ts`
Expected: `# pass 33`, `# fail 0`.

- [ ] **Step 6: Commit**

```bash
git add Resources/Template/scripts/pre-deploy-check.ts Resources/Template/scripts/pre-deploy-check.test.ts Resources/Template/package.json
git commit -m "feat(template): add --strict flag and build:ci script (#799)"
```

---

## Task 2: `BuildLogEnvelope` — extract the JSON envelope from a noisy log

**Files:**
- Create: `Sources/AnglesiteCore/BuildLogEnvelope.swift`
- Test: `Tests/AnglesiteCoreTests/BuildLogEnvelopeTests.swift`

**Interfaces:**
- Consumes: `PreDeployCheck.parse(output:exitCode:) -> PreDeployCheck.Outcome` (`Sources/AnglesiteCore/PreDeployCheck.swift:127`).
- Produces: `BuildLogEnvelope.extract(fromLog:exitCode:) -> BuildLogEnvelope.Result`, where `Result` is `.outcome(PreDeployCheck.Outcome)` (envelope found and decoded) or `.rawExcerpt(String)` (no envelope found — the caller renders the tail of the log instead of the `Phase.blocked` sheet). Consumed by Task 3's fixture test today; the future Worker-bake status consumer (slice 4, blocked on V-3) will call the same function.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/BuildLogEnvelopeTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

struct BuildLogEnvelopeTests {
    private let passedJSON = #"{"version": 1, "ok": true, "failures": [], "warnings": []}"#
    private let blockedJSON = #"""
    {"version": 1, "ok": false, "failures": [{"severity":"error","category":"pii-email","message":"Possible email found","file":"index.html"}], "warnings": []}
    """#

    @Test("A log with build noise before the trailing envelope decodes to .outcome(.passed)")
    func passedEnvelopeAfterBuildNoise() {
        let log = """
        > astro build
        building client (vite)
        13 page(s) built in 842ms
        \(passedJSON)
        """
        let result = BuildLogEnvelope.extract(fromLog: log, exitCode: 0)
        guard case .outcome(.passed(let warnings)) = result else {
            Issue.record("expected .outcome(.passed), got \(result)")
            return
        }
        #expect(warnings.isEmpty)
    }

    @Test("A log with build noise before the trailing envelope decodes to .outcome(.blocked)")
    func blockedEnvelopeAfterBuildNoise() {
        let log = """
        > astro build
        building client (vite)
        13 page(s) built in 842ms
        \(blockedJSON)
        """
        let result = BuildLogEnvelope.extract(fromLog: log, exitCode: 1)
        guard case .outcome(.blocked(let failures, _)) = result else {
            Issue.record("expected .outcome(.blocked), got \(result)")
            return
        }
        #expect(failures.contains { $0.category == .piiEmail })
    }

    @Test("A log with no JSON envelope at all falls back to a raw excerpt")
    func noEnvelopeFallsBackToRawExcerpt() {
        let log = """
        > astro build
        Error: Cannot find module 'astro-embed'
        npm ERR! code MODULE_NOT_FOUND
        """
        let result = BuildLogEnvelope.extract(fromLog: log, exitCode: 1)
        guard case .rawExcerpt(let excerpt) = result else {
            Issue.record("expected .rawExcerpt, got \(result)")
            return
        }
        #expect(excerpt.contains("MODULE_NOT_FOUND"))
    }

    @Test("An empty log falls back to a raw excerpt, not a crash")
    func emptyLogFallsBackToRawExcerpt() {
        let result = BuildLogEnvelope.extract(fromLog: "", exitCode: 1)
        guard case .rawExcerpt(let excerpt) = result else {
            Issue.record("expected .rawExcerpt, got \(result)")
            return
        }
        #expect(excerpt.isEmpty)
    }

    @Test("The raw excerpt is capped to the last N lines for a very long non-JSON log")
    func rawExcerptIsCappedForLongLogs() {
        let lines = (1...500).map { "build noise line \($0)" }
        let log = lines.joined(separator: "\n")
        let result = BuildLogEnvelope.extract(fromLog: log, exitCode: 1)
        guard case .rawExcerpt(let excerpt) = result else {
            Issue.record("expected .rawExcerpt, got \(result)")
            return
        }
        let excerptLineCount = excerpt.split(separator: "\n", omittingEmptySubsequences: false).count
        #expect(excerptLineCount <= BuildLogEnvelope.rawExcerptLineLimit)
        #expect(excerpt.contains("build noise line 500"))
        #expect(!excerpt.contains("build noise line 1\n"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter BuildLogEnvelopeTests`
Expected: FAIL — `BuildLogEnvelope` does not exist (compile error).

- [ ] **Step 3: Implement `BuildLogEnvelope`**

Create `Sources/AnglesiteCore/BuildLogEnvelope.swift`:

```swift
import Foundation

/// Extracts the versioned `pre-deploy-check.ts --json` envelope (#742) out of a larger, noisier
/// log — the shape `npm run build:ci` (#799) produces when a non-interactive runner (a future
/// Worker-triggered bake container, or Workers Builds) captures combined build + scan stdout in
/// one stream, unlike `DeployCommand`'s own `.preflight` step, which already runs the scan in
/// isolation and hands `PreDeployCheck.parse` a clean envelope directly.
///
/// This type does not re-implement decoding — `PreDeployCheck.parse` remains the single decoder
/// (#742). It only locates the envelope's boundaries within a larger string, then defers to
/// `PreDeployCheck.parse` for everything after that.
public enum BuildLogEnvelope {
    public enum Result: Sendable, Equatable {
        /// A `{"version":...}` JSON object was located and decoded (successfully or not — an
        /// unsupported/malformed envelope still surfaces as `.outcome(.error(...))`, matching
        /// `PreDeployCheck.parse`'s own contract).
        case outcome(PreDeployCheck.Outcome)
        /// No JSON envelope could be located in the log at all — an ordinary build failure (a
        /// missing module, a syntax error) rather than a gate-blocked scan. Callers render this as
        /// a plain log excerpt instead of the `Phase.blocked` sheet.
        case rawExcerpt(String)
    }

    /// Cap on the number of trailing lines kept in a `.rawExcerpt` fallback, so a build that fails
    /// early in a very long log (e.g. a dependency install trace) still surfaces something
    /// readable instead of megabytes of noise.
    public static let rawExcerptLineLimit = 200

    /// Scans `log` for the last top-level `{...}` object whose first key is `"version"` — the
    /// shape `pre-deploy-check.ts --json` always emits as the final thing it prints (main(),
    /// `Resources/Template/scripts/pre-deploy-check.ts`). Searching from the end (rather than the
    /// start) matters because build tool output can itself contain unrelated `{...}` fragments
    /// (e.g. a stack trace or a JSON config dump) earlier in the log.
    public static func extract(fromLog log: String, exitCode: Int32?) -> Result {
        guard let envelopeRange = lastVersionedJSONObjectRange(in: log) else {
            return .rawExcerpt(rawExcerpt(of: log))
        }
        let envelope = String(log[envelopeRange])
        return .outcome(PreDeployCheck.parse(output: envelope, exitCode: exitCode))
    }

    /// Finds the range of the last substring in `log` that is both valid JSON and an object whose
    /// top-level `version` key is present — a cheap, allocation-light way to say "this looks like
    /// our envelope" without fully decoding `ScanReport` twice (`PreDeployCheck.parse` does the
    /// real decode). Scans backward from each `{` found from the end, trying the substring from
    /// that `{` to the end of the string; the pre-deploy-check script's envelope is always the last
    /// thing printed, so the first `{` (scanning backward) that parses as `{"version": ...}` is it.
    private static func lastVersionedJSONObjectRange(in log: String) -> Range<String.Index>? {
        var searchEnd = log.endIndex
        while let openBrace = log.range(of: "{", options: .backwards, range: log.startIndex..<searchEnd) {
            let candidate = log[openBrace.lowerBound...]
            if looksLikeVersionedEnvelope(candidate) {
                return openBrace.lowerBound..<log.endIndex
            }
            searchEnd = openBrace.lowerBound
        }
        return nil
    }

    private static func looksLikeVersionedEnvelope(_ candidate: Substring) -> Bool {
        let data = Data(candidate.utf8)
        struct VersionProbe: Decodable { let version: Int }
        return (try? JSONDecoder().decode(VersionProbe.self, from: data)) != nil
    }

    private static func rawExcerpt(of log: String) -> String {
        let lines = log.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > rawExcerptLineLimit else { return log }
        return lines.suffix(rawExcerptLineLimit).joined(separator: "\n")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter BuildLogEnvelopeTests`
Expected: PASS — 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/BuildLogEnvelope.swift Tests/AnglesiteCoreTests/BuildLogEnvelopeTests.swift
git commit -m "feat(app): extract PreDeployCheck envelope from a noisy build log (#799)"
```

---

## Task 3: Producer/consumer fixture tests for `build:ci`

**Files:**
- Modify: `Tests/AnglesiteCoreTests/PreDeployCheckFixtureTests.swift`

**Interfaces:**
- Consumes: `BuildLogEnvelope.extract(fromLog:exitCode:)` (Task 2), the real `Resources/Template/package.json` `build:ci` script and `pre-deploy-check.ts --strict` (Task 1).
- Produces: nothing new for other tasks — this is the terminal proof that Tasks 1 and 2 compose correctly against the real script, extending the existing #742 producer→consumer fixture lane per the issue's Testing section ("fresh scaffold with a seeded PII blocker → `build:ci` exits non-zero after building; clean scaffold exits zero").

This extends `PreDeployCheckFixtureTests.swift` rather than running a full `SiteScaffolder` + `npm install` + `astro build` (that needs the container runtime and a live npm registry, gated behind `ANGLESITE_CONTAINER_TESTS=1` elsewhere in the suite — out of scope for a fast unit-style test). Instead, following the file's own existing philosophy ("seed `dist/` directly, run the real script"), the fixture's `package.json` gives `build:ci` a trivial, deterministic `build` script (`"build": "true"`) so the *real* `pre-deploy-check.ts --json --strict` still runs for real against a seeded `dist/`, proving the `build:ci` chaining and `--strict` behavior end-to-end without requiring a real Astro toolchain.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/AnglesiteCoreTests/PreDeployCheckFixtureTests.swift` (inside `struct PreDeployCheckFixtureTests`, after `realScriptWithNoIssuesDecodesToPassed`):

```swift
    /// Writes a fixture `package.json` whose `build` step is a no-op (`true`) and whose `build:ci`
    /// chains that no-op build with the REAL `pre-deploy-check.ts --json --strict`, exactly as
    /// `Resources/Template/package.json` does (#799). `dist/` is pre-seeded by the caller, standing
    /// in for a real `astro build` output — this test proves `build:ci`'s chaining and `--strict`
    /// promotion against the real script, not a reimplementation of it.
    private func writeFixturePackageJSON(in siteDir: URL) throws {
        let packageJSON = """
        {
          "name": "build-ci-fixture",
          "type": "module",
          "scripts": {
            "build": "true",
            "build:ci": "npm run build && npx tsx \(Self.templateScriptsDirectory.appendingPathComponent("pre-deploy-check.ts").path) --json --strict"
          }
        }
        """
        try packageJSON.write(to: siteDir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    }

    /// Runs `npm run build:ci` with `siteDir` as cwd and returns captured stdout + exit code.
    private func runBuildCI(siteDir: URL) throws -> (stdout: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["npm", "run", "build:ci"]
        process.currentDirectoryURL = siteDir
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe   // npm's own "> build:ci" banner goes to stderr; merge so the
                                        // envelope-extraction test below has real noise to skip past.
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (stdout: String(data: data, encoding: .utf8) ?? "", exitCode: process.terminationStatus)
    }

    @Test("build:ci on a fixture with a seeded PII blocker exits non-zero after building",
          .enabled(if: PreDeployCheckFixtureTests.buildable))
    func buildCIWithPIIBlockerExitsNonZero() throws {
        let siteDir = try makeFixtureDist(html: "<html><body><p>Contact us at hello@example.com</p></body></html>")
        defer { try? FileManager.default.removeItem(at: siteDir) }
        try writeFixturePackageJSON(in: siteDir)

        let result = try runBuildCI(siteDir: siteDir)
        #expect(result.exitCode != 0)

        let extracted = BuildLogEnvelope.extract(fromLog: result.stdout, exitCode: result.exitCode)
        guard case .outcome(.blocked(let failures, _)) = extracted else {
            Issue.record("expected .outcome(.blocked) extracted from the combined log, got \(extracted) — raw: \(result.stdout)")
            return
        }
        #expect(failures.contains { $0.category == .piiEmail })
    }

    @Test("build:ci on a clean fixture exits zero",
          .enabled(if: PreDeployCheckFixtureTests.buildable))
    func buildCIOnCleanFixtureExitsZero() throws {
        let siteDir = try makeFixtureDist(html: "<html><body><p>Nothing sensitive here.</p></body></html>")
        defer { try? FileManager.default.removeItem(at: siteDir) }
        try "/*\n  Content-Security-Policy: default-src 'self'\n".write(
            to: siteDir.appendingPathComponent("dist/_headers"), atomically: true, encoding: .utf8)
        try "User-agent: *\n".write(
            to: siteDir.appendingPathComponent("dist/robots.txt"), atomically: true, encoding: .utf8)
        let wellKnown = siteDir.appendingPathComponent("dist/.well-known", isDirectory: true)
        try FileManager.default.createDirectory(at: wellKnown, withIntermediateDirectories: true)
        try "Contact: mailto:security@example.com\n".write(
            to: wellKnown.appendingPathComponent("security.txt"), atomically: true, encoding: .utf8)
        try writeFixturePackageJSON(in: siteDir)

        let result = try runBuildCI(siteDir: siteDir)
        #expect(result.exitCode == 0)
    }

    @Test("build:ci's --strict promotes a warning-only fixture to non-zero",
          .enabled(if: PreDeployCheckFixtureTests.buildable))
    func buildCIStrictPromotesWarningsToFailure() throws {
        // Deliberately missing dist/_headers/robots.txt/security.txt: `pre-deploy-check.ts --json`
        // (no --strict) would still exit 1 here because a missing _headers is itself an ERROR
        // (checkHeaders), so to isolate the --strict promotion this fixture supplies a passing
        // _headers but omits robots.txt/security.txt, which are WARNINGS (missing-security-artifact)
        // — exit 0 without --strict, exit 1 with it.
        let siteDir = try makeFixtureDist(html: "<html><body><p>Nothing sensitive here.</p></body></html>")
        defer { try? FileManager.default.removeItem(at: siteDir) }
        try "/*\n  Content-Security-Policy: default-src 'self'\n".write(
            to: siteDir.appendingPathComponent("dist/_headers"), atomically: true, encoding: .utf8)
        try writeFixturePackageJSON(in: siteDir)

        let result = try runBuildCI(siteDir: siteDir)
        #expect(result.exitCode != 0)

        let extracted = BuildLogEnvelope.extract(fromLog: result.stdout, exitCode: result.exitCode)
        guard case .outcome(.blocked(let failures, let warnings)) = extracted else {
            Issue.record("expected .outcome(.blocked), got \(extracted) — raw: \(result.stdout)")
            return
        }
        #expect(failures.contains { $0.category == .missingSecurityArtifact })
        #expect(warnings.isEmpty)   // --strict moves everything into failures
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter PreDeployCheckFixtureTests`
Expected: FAIL — `npm run build:ci` doesn't exist yet if Task 1 weren't already applied. Since Task 1 already landed by this point in the plan, this instead verifies compile success and that `BuildLogEnvelope` (Task 2) resolves — if Tasks 1-2 are both already committed, this step should largely PASS already; run it anyway to confirm before Step 3, since the point of TDD here is confirming the fixture *setup* (package.json content, npm invocation) is exercised, not that the underlying feature is missing.

- [ ] **Step 3: No implementation step — this task only adds tests against Tasks 1 and 2's real code**

(N/A — if Step 2 failed for a reason other than environment gating, fix the fixture code above; there is no separate production-code change in this task.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter PreDeployCheckFixtureTests`
Expected: PASS — 5 tests pass (2 existing + 3 new), or all SKIP if `PreDeployCheckFixtureTests.buildable` is false in this environment (no offline `tsx`) — in which case verify manually: `cd Resources/Template && npm run build:ci` against a real scaffolded site once `node_modules` is installed, per Task 1 Step 5's build check.

- [ ] **Step 5: Commit**

```bash
git add Tests/AnglesiteCoreTests/PreDeployCheckFixtureTests.swift
git commit -m "test(app): extend #742 fixture lane to prove build:ci end-to-end (#799)"
```

---

## Task 4: Content-layer loader seam (template)

**Files:**
- Create: `Resources/Template/src/lib/content-loader.ts`
- Create: `Resources/Template/src/lib/content-loader.test.ts`
- Modify: `Resources/Template/src/content.config.ts`

**Interfaces:**
- Produces: `createContentAPILoader(collectionName: string): Loader` — an Astro Content Layer `Loader` that fetches entries from a Worker content API (paginated, per spec §C.4's "bulk content read endpoint") and validates each through the collection's own zod schema via `parseData`. Selected in `content.config.ts` only when `.site-config`'s `CMS_CONTENT_API_URL` is set; `glob()` remains the default and only path for un-provisioned sites (unchanged).

This is deliberately scoped to the `blog` collection only (matching Part B of the design doc: "`blog` and `articles` both stay") — the same `createContentAPILoader` factory applies to the other 11 collections in slice 4 once a real Worker content API exists to point it at; wiring all 12 now would be speculative churn against an endpoint that doesn't exist yet.

- [ ] **Step 1: Write the failing tests**

Create `Resources/Template/src/lib/content-loader.test.ts`:

```ts
import test from "node:test";
import assert from "node:assert/strict";
import { createContentAPILoader } from "./content-loader";

function fakeContext(overrides: Partial<Record<string, unknown>> = {}) {
  const stored: Array<{ id: string; data: unknown; digest?: string }> = [];
  return {
    stored,
    context: {
      store: {
        clear: () => { stored.length = 0; },
        set: (entry: { id: string; data: unknown; digest?: string }) => { stored.push(entry); },
      },
      parseData: async ({ id, data }: { id: string; data: unknown }) => data,
      generateDigest: (data: unknown) => JSON.stringify(data),
      logger: { info: () => {}, warn: () => {}, error: () => {} },
      config: {},
      ...overrides,
    },
  };
}

test("loads entries from a paginated content API into the store", async () => {
  const fetchCalls: string[] = [];
  const fakeFetch = async (url: string) => {
    fetchCalls.push(url);
    if (url.includes("cursor=")) {
      return new Response(JSON.stringify({ items: [], nextCursor: null }), { status: 200 });
    }
    return new Response(
      JSON.stringify({
        items: [{ id: "hello-world", title: "Hello World", pubDate: "2026-07-18", draft: false }],
        nextCursor: null,
      }),
      { status: 200 },
    );
  };

  const loader = createContentAPILoader("blog", { apiURL: "https://example.workers.dev/api", fetchImpl: fakeFetch });
  const { context, stored } = fakeContext();
  await loader.load(context as any);

  assert.equal(stored.length, 1);
  assert.equal(stored[0].id, "hello-world");
  assert.equal((stored[0].data as { title: string }).title, "Hello World");
});

test("follows the cursor across multiple pages", async () => {
  const pages: Record<string, unknown> = {
    "https://example.workers.dev/api/blog?": {
      items: [{ id: "post-1", title: "Post 1", pubDate: "2026-07-01", draft: false }],
      nextCursor: "page-2",
    },
    "https://example.workers.dev/api/blog?cursor=page-2": {
      items: [{ id: "post-2", title: "Post 2", pubDate: "2026-07-02", draft: false }],
      nextCursor: null,
    },
  };
  const fakeFetch = async (url: string) => {
    const body = pages[url];
    if (!body) throw new Error(`unexpected URL: ${url}`);
    return new Response(JSON.stringify(body), { status: 200 });
  };

  const loader = createContentAPILoader("blog", { apiURL: "https://example.workers.dev/api", fetchImpl: fakeFetch });
  const { context, stored } = fakeContext();
  await loader.load(context as any);

  assert.equal(stored.length, 2);
  assert.deepEqual(stored.map((e) => e.id).sort(), ["post-1", "post-2"]);
});

test("draft entries are filtered server-side but the loader doesn't crash if one leaks through", async () => {
  const fakeFetch = async () =>
    new Response(
      JSON.stringify({
        items: [
          { id: "published", title: "Published", pubDate: "2026-07-18", draft: false },
          { id: "still-draft", title: "Still Draft", pubDate: "2026-07-18", draft: true },
        ],
        nextCursor: null,
      }),
      { status: 200 },
    );

  const loader = createContentAPILoader("blog", { apiURL: "https://example.workers.dev/api", fetchImpl: fakeFetch });
  const { context, stored } = fakeContext();
  await loader.load(context as any);

  // The loader itself doesn't filter drafts (the Worker's bulk-read endpoint is draft-filtered
  // server-side per §C.4) — it stores whatever it's handed, same as glob() stores every file it
  // finds. Draft filtering for rendering is the collection consumer's job, unchanged from today.
  assert.equal(stored.length, 2);
});

test("a non-2xx response fails the build loudly instead of yielding an empty collection", async () => {
  const fakeFetch = async () => new Response("service unavailable", { status: 503 });
  const loader = createContentAPILoader("blog", { apiURL: "https://example.workers.dev/api", fetchImpl: fakeFetch });
  const { context } = fakeContext();

  await assert.rejects(() => loader.load(context as any), /CMS content API unreachable.*503/s);
});

test("a network failure fails the build loudly", async () => {
  const fakeFetch = async () => { throw new Error("getaddrinfo ENOTFOUND"); };
  const loader = createContentAPILoader("blog", { apiURL: "https://example.workers.dev/api", fetchImpl: fakeFetch });
  const { context } = fakeContext();

  await assert.rejects(() => loader.load(context as any), /CMS content API unreachable/);
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Resources/Template && node --import tsx --test src/lib/content-loader.test.ts`
Expected: FAIL — `./content-loader` module not found.

- [ ] **Step 3: Implement the loader**

Create `Resources/Template/src/lib/content-loader.ts`:

```ts
import type { Loader, LoaderContext } from "astro/loaders";

/** One page of the Worker's bulk content-read endpoint (§C.4 of the publishing design). */
interface ContentAPIPage {
  items: Array<{ id: string; [key: string]: unknown }>;
  nextCursor: string | null;
}

export interface ContentAPILoaderOptions {
  /** Base URL of the site's per-site Worker content API, e.g. `https://example.workers.dev/api`. */
  apiURL: string;
  /** Injectable for tests; defaults to the global `fetch`. */
  fetchImpl?: typeof fetch;
}

/**
 * A Content Layer `Loader` that reads a collection's entries from the per-site Worker's bulk
 * content-read endpoint instead of the filesystem — the CMS-mode counterpart to `glob()`
 * (#799, groundwork for slice 4's CMS mode, spec §C.4). Selected in `content.config.ts` only
 * when `.site-config`'s `CMS_CONTENT_API_URL` is set; un-provisioned sites keep `glob()`
 * unchanged. The same zod schema validates entries from either loader via Astro's `parseData`.
 *
 * Draft filtering happens server-side (the bulk endpoint is documented as "draft-filtered
 * server-side" per §C.4) — this loader stores whatever the API returns, same as `glob()` stores
 * every file it finds regardless of a `draft: true` frontmatter field.
 *
 * A non-2xx response or a network failure throws (not returns empty) — "CMS-unreachable fails
 * the build loudly," per the issue's explicit contract, so a Worker outage can never silently
 * ship a site with an empty blog instead of failing the build.
 */
export function createContentAPILoader(collectionName: string, options: ContentAPILoaderOptions): Loader {
  const fetchImpl = options.fetchImpl ?? fetch;
  const baseURL = options.apiURL.endsWith("/") ? options.apiURL.slice(0, -1) : options.apiURL;

  return {
    name: `content-api:${collectionName}`,
    load: async ({ store, parseData, generateDigest, logger }: LoaderContext) => {
      store.clear();
      let cursor: string | null = null;
      let pageCount = 0;

      do {
        const url = cursor
          ? `${baseURL}/${collectionName}?cursor=${encodeURIComponent(cursor)}`
          : `${baseURL}/${collectionName}?`;

        let response: Response;
        try {
          response = await fetchImpl(url);
        } catch (error) {
          throw new Error(`CMS content API unreachable for "${collectionName}" — ${String(error)}`);
        }
        if (!response.ok) {
          throw new Error(
            `CMS content API unreachable for "${collectionName}" — ${url} returned ${response.status}`,
          );
        }

        const page = (await response.json()) as ContentAPIPage;
        for (const item of page.items) {
          const { id, ...data } = item;
          const parsed = await parseData({ id, data });
          const digest = generateDigest(parsed);
          store.set({ id, data: parsed, digest });
        }

        cursor = page.nextCursor;
        pageCount += 1;
        if (pageCount > 1000) {
          // Belt-and-suspenders against a misbehaving endpoint that never returns a null cursor.
          throw new Error(`CMS content API for "${collectionName}" did not terminate after 1000 pages`);
        }
      } while (cursor !== null);

      logger.info(`content-api:${collectionName}: loaded ${pageCount} page(s)`);
    },
  };
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Resources/Template && node --import tsx --test src/lib/content-loader.test.ts`
Expected: `# pass 5`, `# fail 0`.

- [ ] **Step 5: Wire the seam into `content.config.ts`**

In `Resources/Template/src/content.config.ts`, add the imports and loader-selection helper near the top (after the existing imports):

```ts
import { defineCollection } from "astro:content";
import { glob } from "astro/loaders";
import { z } from "astro/zod";
import { readConfig } from "../scripts/config.ts";
import { createContentAPILoader } from "./lib/content-loader";

/**
 * Picks the CMS content-API loader when `.site-config`'s `CMS_CONTENT_API_URL` is set (CMS mode,
 * slice 4), otherwise the existing `glob()` loader (today's behavior, unchanged for every
 * un-provisioned site). Same zod schema validates entries from either loader (#799 §C.4).
 */
function collectionLoader(name: string) {
  const apiURL = readConfig("CMS_CONTENT_API_URL");
  return apiURL ? createContentAPILoader(name, { apiURL }) : glob({ pattern: "**/*.md", base: `./src/content/${name}` });
}
```

Then change the `blog` collection's `loader:` line (currently `loader: glob({ pattern: "**/*.md", base: "./src/content/blog" }),`) to:

```ts
const blog = defineCollection({
  loader: collectionLoader("blog"),
  schema: z.object({
    ...socialFields,
    title: z.string(),
    pubDate: z.coerce.date(),
    description: z.string().optional(),
    draft: z.boolean().default(false),
  }).strict(),
});
```

Leave every other collection (`notes`, `articles`, `photos`, `albums`, `bookmarks`, `replies`, `likes`, `announcements`, `events`, `reviews`, `members`) on its existing direct `glob(...)` call — only `blog` gets the seam in this slice.

- [ ] **Step 6: Verify the template still builds with the seam wired but unselected**

Run: `cd Resources/Template && npm run build`
Expected: exits 0 — no `.site-config` in the template's own dev tree means `readConfig("CMS_CONTENT_API_URL")` returns `undefined`, so `collectionLoader("blog")` resolves to the same `glob(...)` call as before. This is the critical regression check: today's un-provisioned build path must be byte-for-byte unaffected.

- [ ] **Step 7: Commit**

```bash
git add Resources/Template/src/lib/content-loader.ts Resources/Template/src/lib/content-loader.test.ts Resources/Template/src/content.config.ts
git commit -m "feat(template): content-layer loader seam for CMS mode (#799)"
```

---

## Task 5: `DeployStep.bundleUpload` — new deploy step + argv mapping

**Files:**
- Modify: `Sources/AnglesiteCore/DeployExecutor.swift`
- Modify: `Tests/AnglesiteCoreTests/DeployCommandTests.swift`
- Modify: `Tests/AnglesiteAppTests/DeployModelTests.swift`
- Modify: `Tests/AnglesiteCoreTests/DeployCommandProgressTests.swift`

**Interfaces:**
- Consumes: `SiteConfigFile.value(forKey:in:)` (`Sources/AnglesiteCore/SiteConfigFile.swift:35`).
- Produces: `DeployStep.bundleUpload` case, consumed by Task 6's `DeployCommand.deploy` orchestration. `ContainerDeployExecutor`'s per-step argv now takes `siteDirectory` so it can read `.site-config`'s `CF_SOURCE_BUCKET`.

- [ ] **Step 1: Write the failing test — FakeExecutor recognizes the new step**

In `Tests/AnglesiteCoreTests/DeployCommandTests.swift`, update `FakeExecutor.key(_:)` (currently lines ~26-30) to add the new case:

```swift
        private func key(_ step: DeployStep) -> String {
            switch step {
            case .build: return "build"
            case .preflight: return "preflight"
            case .wrangler: return "wrangler"
            case .bundleUpload: return "bundleUpload"
            }
        }
```

Add a new test in the same file (append near the other executor-mapping tests, or at file scope inside `struct DeployCommandTests`):

```swift
    @Test("ContainerDeployExecutor maps .bundleUpload to a tar+wrangler-r2-put argv naming the configured bucket")
    func bundleUploadArgvNamesConfiguredBucket() throws {
        let siteDir = tmpDir.appendingPathComponent("bundle-upload-argv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: siteDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: siteDir) }
        try "CF_SOURCE_BUCKET=my-site-source\n".write(
            to: siteDir.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)

        let argv = ContainerDeployExecutorTestHook.guestArgv(for: .bundleUpload, siteDirectory: siteDir)
        #expect(argv.contains { $0.contains("my-site-source") })
        #expect(argv.contains { $0.contains("wrangler") })
    }
```

This test needs a test-only seam onto `ContainerDeployExecutor`'s private `guestArgv` — add it in Step 3 alongside the implementation (Swift `private` methods aren't visible to `@testable import` at the file level when declared `private` inside the struct; expose a `package`-visibility or `internal` static test hook instead, matching how the codebase already exposes internals to `@testable import AnglesiteCore` elsewhere via plain `internal`, the default).

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter DeployCommandTests`
Expected: FAIL — `DeployStep.bundleUpload` doesn't exist; `ContainerDeployExecutorTestHook` doesn't exist.

- [ ] **Step 3: Add the `DeployStep` case and argv mapping**

In `Sources/AnglesiteCore/DeployExecutor.swift`, update `DeployStep` (lines 6-13):

```swift
/// Identifies one logical step in the deploy sequence.
public enum DeployStep: Sendable {
    /// `npm run build` — produces `dist/`.
    case build
    /// `npx tsx scripts/pre-deploy-check.ts --json` — the bundled plugin's security scan.
    case preflight
    /// `wrangler deploy` — publishes the built site to Cloudflare Workers.
    case wrangler
    /// Tars `Source/` and uploads it to the site's configured R2 bucket via `wrangler r2 object
    /// put` — the code side of a future Worker-triggered bake (#799, spec §C.4). Only reached
    /// when `.site-config`'s `CF_SOURCE_BUCKET` is set; `DeployCommand.deploy` skips this step
    /// entirely otherwise (today, for every site — no provisioning flow writes that key yet).
    case bundleUpload
}
```

Change `guestArgv(for:)` on `ContainerDeployExecutor` (currently a bare `private func guestArgv(for step: DeployStep) -> [String]`, lines ~150-158) to take `siteDirectory` and add the new case, and update its one call site (`run(step:siteDirectory:...)`, line ~85: `let argv = guestArgv(for: step)` → `let argv = Self.guestArgv(for: step, siteDirectory: siteDirectory)`):

```swift
    // MARK: argv mapping

    static func guestArgv(for step: DeployStep, siteDirectory: URL) -> [String] {
        switch step {
        case .build:
            return ["npm", "run", "build"]
        case .preflight:
            return ["npx", "tsx", "scripts/pre-deploy-check.ts", "--json"]
        case .wrangler:
            return ["npx", "wrangler", "deploy"]
        case .bundleUpload:
            let bucket = bundleUploadBucket(siteDirectory: siteDirectory) ?? ""
            return [
                "sh", "-c",
                "tar czf /tmp/source-bundle.tar.gz -C /workspace/site --exclude=dist --exclude=node_modules . " +
                "&& npx wrangler r2 object put \(bucket)/source/$(basename \(bucket) 2>/dev/null; true).tar.gz " +
                "--file=/tmp/source-bundle.tar.gz --remote"
            ]
        }
    }

    /// Reads `.site-config`'s `CF_SOURCE_BUCKET` from the HOST `siteDirectory` (the guest's copy is
    /// a clone of the same repo, so the value is identical) — `nil` when unset, which
    /// `DeployCommand.deploy` treats as "skip this step" before it ever reaches the executor.
    private static func bundleUploadBucket(siteDirectory: URL) -> String? {
        let configURL = siteDirectory.appendingPathComponent(".site-config")
        guard let config = try? String(contentsOf: configURL, encoding: .utf8) else { return nil }
        return SiteConfigFile.value(forKey: "CF_SOURCE_BUCKET", in: config)
    }
```

Change the call site inside `run(step:siteDirectory:environment:source:)` (around line 85):

```swift
        // `siteDirectory` is the HOST path — the guest always uses /workspace/site.
        let argv = Self.guestArgv(for: step, siteDirectory: siteDirectory)
```

Update `HostDeployExecutor.defaultResolver` (lines ~271-280) to explicitly refuse the new step too (host path is retired, matching the other three cases):

```swift
    public static let defaultResolver: @Sendable (DeployStep) -> DeployCommand.CommandResolver = { step in
        switch step {
        case .build:
            return DeployCommand.resolveBuildCommand
        case .preflight:
            return preflightResolver
        case .wrangler:
            return DeployCommand.resolveWranglerCommand
        case .bundleUpload:
            return { _ in .unavailable(reason: HostNodeRetirement.reason("source bundle upload")) }
        }
    }
```

Two existing fake `DeployExecutor` conformances elsewhere in the test suite also `switch` exhaustively over `DeployStep` with no `default`, and will fail to compile once `.bundleUpload` exists. Fix both now rather than discovering them via the Step 4 build check:

In `Tests/AnglesiteAppTests/DeployModelTests.swift`, `GatedDeployExecutor.run` (the `switch step { case .build: ...; case .preflight: ...; case .wrangler: ... }` block) gains:

```swift
        case .wrangler:
            return DeployStepResult(
                exitCode: 0,
                output: "Published test (0.1 sec)\n  https://test.example.workers.dev"
            )
        case .bundleUpload:
            return DeployStepResult(exitCode: 0, output: "")
        }
```

In `Tests/AnglesiteCoreTests/DeployCommandProgressTests.swift`, `BlockingPreflightExecutor.run` gains:

```swift
        case .wrangler:
            return DeployStepResult(exitCode: 0, output: "")
        case .bundleUpload:
            return DeployStepResult(exitCode: 0, output: "")
        }
```

Neither test exercises the bundle-upload step's behavior (no `.site-config` with `CF_SOURCE_BUCKET` is written in either fixture, so `DeployCommand.uploadSourceBundleIfConfigured` — Task 6 — never actually calls `executor.run(step: .bundleUpload, ...)` in these tests regardless); the added case only exists to keep the `switch` exhaustive.

Add the test-only hook at the bottom of `DeployExecutor.swift` (or a new small file `Sources/AnglesiteCore/DeployExecutor+TestHooks.swift` if the project prefers splitting test seams out — follow whichever convention `grep -rn "TestHook" Sources/AnglesiteCore` shows; if none exists, keep it inline):

```swift
/// Test-only visibility onto `ContainerDeployExecutor`'s argv mapping — `guestArgv` itself is
/// `static` and package-internal so `@testable import AnglesiteCore` sees it directly; this
/// wrapper exists only so tests don't depend on `ContainerDeployExecutor`'s internal method name
/// staying `guestArgv` specifically. Kept minimal since it's exercised by exactly one test.
enum ContainerDeployExecutorTestHook {
    static func guestArgv(for step: DeployStep, siteDirectory: URL) -> [String] {
        ContainerDeployExecutor.guestArgv(for: step, siteDirectory: siteDirectory)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter DeployCommandTests`
Expected: PASS.

Run full suite to catch any other exhaustive `switch` over `DeployStep` this change missed:

Run: `swift build --package-path . 2>&1 | grep -i "switch must be exhaustive\|error:"`
Expected: no output. If any exhaustive-switch error appears (a call site this plan didn't anticipate), add a `.bundleUpload` case there mirroring the nearest existing case's intent, then re-run.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/DeployExecutor.swift Tests/AnglesiteCoreTests/DeployCommandTests.swift Tests/AnglesiteAppTests/DeployModelTests.swift Tests/AnglesiteCoreTests/DeployCommandProgressTests.swift
git commit -m "feat(app): add DeployStep.bundleUpload for the deployed-source snapshot (#799)"
```

---

## Task 6: Orchestrate the bundle upload in `DeployCommand.deploy` + persist the uploaded commit

**Files:**
- Modify: `Sources/AnglesiteCore/SiteConfigStore.swift`
- Modify: `Sources/AnglesiteCore/DeployCommand.swift`
- Modify: `Tests/AnglesiteCoreTests/DeployCommandTests.swift`

**Interfaces:**
- Consumes: `DeployStep.bundleUpload` (Task 5), `InProcessGit.run(siteDirectory:arguments:) -> ProcessSupervisor.RunResult` (`Sources/AnglesiteCore/InProcessGit.swift:49`, supports `["rev-parse", "HEAD"]`), `SiteConfigStore(configDirectory:).save(_:)` (`Sources/AnglesiteCore/SiteConfigStore.swift:94`).
- Produces: `SiteSettings.deployedSourceBundleCommit: String?` — the git commit SHA of `Source/` at the time of the last successful bundle upload. Consumed by Task 7's `SourceBundleStatus`.

- [ ] **Step 1: Write the failing test**

Add to `SiteSettings`'s existing round-trip test file — find it first:

Run: `grep -rln "struct SiteSettings\|SiteConfigStoreTests" Tests/AnglesiteCoreTests/`

Add a test to the located `SiteConfigStoreTests.swift` (mirroring the file's existing per-field round-trip test style — read the file first to match its exact `@Test` naming convention before adding):

```swift
    @Test("deployedSourceBundleCommit round-trips through save/load")
    func deployedSourceBundleCommitRoundTrips() async throws {
        let configDir = try makeTempConfigDirectory()
        defer { try? FileManager.default.removeItem(at: configDir) }
        let store = SiteConfigStore(configDirectory: configDir)

        var settings = try await store.load()
        #expect(settings.deployedSourceBundleCommit == nil)

        settings.deployedSourceBundleCommit = "abc123def456"
        try await store.save(settings)

        let reloaded = try await store.load()
        #expect(reloaded.deployedSourceBundleCommit == "abc123def456")
    }
```

(If `SiteConfigStoreTests.swift` has its own `makeTempConfigDirectory()`-style helper under a different name, use that helper instead — match the file's existing pattern rather than introducing a second one.)

Add a `DeployCommand` orchestration test to `Tests/AnglesiteCoreTests/DeployCommandTests.swift`:

```swift
    @Test("a successful deploy uploads the source bundle when CF_SOURCE_BUCKET is configured")
    func successfulDeployUploadsBundleWhenBucketConfigured() async throws {
        let siteDir = try makeGitRepo()   // see Step 1a below for this helper
        defer { try? FileManager.default.removeItem(at: siteDir) }
        try "CF_SOURCE_BUCKET=my-site-source\n".write(
            to: siteDir.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)
        let configDir = tmpDir.appendingPathComponent("deploy-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: configDir) }

        let executor = FakeExecutor()
            .set(.build, exitCode: 0, output: "")
            .set(.preflight, exitCode: 0, output: scanJSON(ok: true))
            .set(.wrangler, exitCode: 0, output: "Deployed my-site (1.2 sec)\n https://my-site.example.workers.dev")
            .set(.bundleUpload, exitCode: 0, output: "")
        let command = DeployCommand(tokenSource: { "test-token" }, executor: executor)

        let result = await command.deploy(siteID: "test", siteDirectory: siteDir, configDirectory: configDir)
        guard case .succeeded = result else {
            Issue.record("expected .succeeded, got \(result)")
            return
        }
        #expect(executor.ran(.bundleUpload))

        let settings = try await SiteConfigStore(configDirectory: configDir).load()
        #expect(settings.deployedSourceBundleCommit != nil)
    }

    @Test("a successful deploy skips the bundle-upload step when CF_SOURCE_BUCKET is not configured")
    func successfulDeploySkipsBundleUploadWithoutBucket() async throws {
        let siteDir = try makeGitRepo()
        defer { try? FileManager.default.removeItem(at: siteDir) }
        // No .site-config at all — matches every real site today (no provisioning writes CF_SOURCE_BUCKET yet).
        let configDir = tmpDir.appendingPathComponent("deploy-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: configDir) }

        let executor = FakeExecutor()
            .set(.build, exitCode: 0, output: "")
            .set(.preflight, exitCode: 0, output: scanJSON(ok: true))
            .set(.wrangler, exitCode: 0, output: "Deployed my-site (1.2 sec)\n https://my-site.example.workers.dev")
        let command = DeployCommand(tokenSource: { "test-token" }, executor: executor)

        let result = await command.deploy(siteID: "test", siteDirectory: siteDir, configDirectory: configDir)
        guard case .succeeded = result else {
            Issue.record("expected .succeeded, got \(result)")
            return
        }
        #expect(!executor.ran(.bundleUpload))
    }

    /// A minimal real git repo (`git init` + one commit) at a fresh temp directory — the
    /// bundle-upload orchestration reads `Source/`'s HEAD SHA via `InProcessGit`, which needs a
    /// real repository, not just a directory.
    private func makeGitRepo() throws -> URL {
        let dir = tmpDir.appendingPathComponent("deploy-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "hello".write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["sh", "-c", "git init -q && git config user.email t@example.com && git config user.name Test && git add -A && git commit -q -m init"]
        process.currentDirectoryURL = dir
        try process.run()
        process.waitUntilExit()
        return dir
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter DeployCommandTests`
Expected: FAIL — `SiteSettings.deployedSourceBundleCommit` doesn't exist; `.bundleUpload` never runs (`executor.ran(.bundleUpload)` is `false` in the first test).

- [ ] **Step 3: Add the `SiteSettings` field**

In `Sources/AnglesiteCore/SiteConfigStore.swift`, add the field to `SiteSettings` (after `blueskyPDSURL`):

```swift
    public var blueskyPDSURL: String?

    /// Git commit SHA of `Source/`'s `HEAD` at the time of the last successful deployed-source
    /// bundle upload to R2 (#799, spec §C.4 — the code side of a future Worker-triggered bake).
    /// `nil` until the first successful upload. Compared against the current `HEAD` (via
    /// `InProcessGit`) by `SourceBundleStatus` to surface "code changes not yet deployed."
    public var deployedSourceBundleCommit: String?

    public init(
        displayName: String? = nil,
        inboxCaptureAccountID: String? = nil,
        inboxCaptureKVNamespaceID: String? = nil,
        mastodonBaseURL: String? = nil,
        blueskyIdentifier: String? = nil,
        blueskyPDSURL: String? = nil,
        deployedSourceBundleCommit: String? = nil
    ) {
        self.displayName = displayName
        self.inboxCaptureAccountID = inboxCaptureAccountID
        self.inboxCaptureKVNamespaceID = inboxCaptureKVNamespaceID
        self.mastodonBaseURL = mastodonBaseURL
        self.blueskyIdentifier = blueskyIdentifier
        self.blueskyPDSURL = blueskyPDSURL
        self.deployedSourceBundleCommit = deployedSourceBundleCommit
    }
```

- [ ] **Step 4: Orchestrate the step in `DeployCommand.deploy`**

In `Sources/AnglesiteCore/DeployCommand.swift`, after the `wrangler` step succeeds and before `return .succeeded(...)` (currently lines 212-219), insert the bundle-upload call. The existing code:

```swift
        if code == 0 {
            if let url = Self.extractDeployedURL(from: wranglerResult.output) {
                if let configDirectory {
                    try? DeployedRoutesSnapshot.save(currentRoutes, to: configDirectory)
                }
                Self.persistSiteURL(url, siteDirectory: siteDirectory)
                Self.persistWorkerDeployed(siteDirectory: siteDirectory)
                return .succeeded(url: url, duration: duration)
            }
```

becomes:

```swift
        if code == 0 {
            if let url = Self.extractDeployedURL(from: wranglerResult.output) {
                if let configDirectory {
                    try? DeployedRoutesSnapshot.save(currentRoutes, to: configDirectory)
                }
                Self.persistSiteURL(url, siteDirectory: siteDirectory)
                Self.persistWorkerDeployed(siteDirectory: siteDirectory)
                if let configDirectory {
                    await Self.uploadSourceBundleIfConfigured(
                        siteDirectory: siteDirectory, configDirectory: configDirectory,
                        environment: baseEnvironment, executor: executor, siteID: siteID
                    )
                }
                return .succeeded(url: url, duration: duration)
            }
```

Add the new method near `persistWorkerDeployed` (MARK: comment area, after line 322):

```swift
    /// Uploads `Source/`'s snapshot to R2 (`DeployStep.bundleUpload`) when `.site-config`'s
    /// `CF_SOURCE_BUCKET` is set, then persists the uploaded commit SHA into `Config/settings.plist`
    /// (#799, spec §C.4 — the code side of a future Worker-triggered bake). A no-op today for every
    /// real site — no provisioning flow writes `CF_SOURCE_BUCKET` yet — and the executor call is
    /// skipped entirely rather than run-and-ignore-the-result, so a redeploy on an unprovisioned
    /// site pays no extra subprocess cost. Best-effort like `persistSiteURL`/`persistWorkerDeployed`:
    /// a failure here must never turn a successful deploy into a failed one.
    static func uploadSourceBundleIfConfigured(
        siteDirectory: URL,
        configDirectory: URL,
        environment: [String: String],
        executor: any DeployExecutor,
        siteID: String
    ) async {
        let configURL = siteDirectory.appendingPathComponent(WebsiteAnalyticsAsset.configRelativePath)
        let config = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        guard SiteConfigFile.value(forKey: "CF_SOURCE_BUCKET", in: config) != nil else { return }

        let uploadResult = await executor.run(
            step: .bundleUpload,
            siteDirectory: siteDirectory,
            environment: environment,
            source: "deploy:\(siteID):bundle"
        )
        guard uploadResult.exitCode == 0 else { return }

        let headResult = await InProcessGit.run(siteDirectory: siteDirectory, arguments: ["rev-parse", "HEAD"])
        guard headResult.exitCode == 0 else { return }
        let commitSHA = headResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commitSHA.isEmpty else { return }

        let store = SiteConfigStore(configDirectory: configDirectory)
        guard var settings = try? await store.load() else { return }
        settings.deployedSourceBundleCommit = commitSHA
        try? await store.save(settings)
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --package-path . --filter DeployCommandTests`
Expected: PASS.

Run: `swift test --package-path . --filter SiteConfigStoreTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/SiteConfigStore.swift Sources/AnglesiteCore/DeployCommand.swift Tests/AnglesiteCoreTests/DeployCommandTests.swift Tests/AnglesiteCoreTests/SiteConfigStoreTests.swift
git commit -m "feat(app): upload the deployed-source bundle to R2 on successful deploy (#799)"
```

---

## Task 7: `SourceBundleStatus` — dirty-state helper

**Files:**
- Create: `Sources/AnglesiteCore/SourceBundleStatus.swift`
- Test: `Tests/AnglesiteCoreTests/SourceBundleStatusTests.swift`

**Interfaces:**
- Consumes: `InProcessGit.run(siteDirectory:arguments:)` (`["rev-parse", "HEAD"]`), `SiteSettings.deployedSourceBundleCommit` (Task 6).
- Produces: `SourceBundleStatus.check(siteDirectory:settings:) async -> SourceBundleStatus.State`, where `State` is `.notConfigured` (no `CF_SOURCE_BUCKET` — nothing to report), `.notYetUploaded` (configured but never uploaded), `.upToDate`, or `.dirty(uploadedCommit: String, currentCommit: String)`. Consumed by Task 8's `DeployDrawerView` line.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/SourceBundleStatusTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

struct SourceBundleStatusTests {
    private func makeGitRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceBundleStatusTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "hello".write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["sh", "-c", "git init -q && git config user.email t@example.com && git config user.name Test && git add -A && git commit -q -m init"]
        process.currentDirectoryURL = dir
        try process.run()
        process.waitUntilExit()
        return dir
    }

    private func currentHEAD(of dir: URL) async -> String {
        let result = await InProcessGit.run(siteDirectory: dir, arguments: ["rev-parse", "HEAD"])
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test("no CF_SOURCE_BUCKET configured reports .notConfigured")
    func notConfigured() async throws {
        let siteDir = try makeGitRepo()
        defer { try? FileManager.default.removeItem(at: siteDir) }
        // No .site-config at all.
        let status = await SourceBundleStatus.check(siteDirectory: siteDir, settings: SiteSettings())
        #expect(status == .notConfigured)
    }

    @Test("configured but never uploaded reports .notYetUploaded")
    func notYetUploaded() async throws {
        let siteDir = try makeGitRepo()
        defer { try? FileManager.default.removeItem(at: siteDir) }
        try "CF_SOURCE_BUCKET=my-site-source\n".write(
            to: siteDir.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)

        let status = await SourceBundleStatus.check(siteDirectory: siteDir, settings: SiteSettings())
        #expect(status == .notYetUploaded)
    }

    @Test("uploaded commit matching current HEAD reports .upToDate")
    func upToDate() async throws {
        let siteDir = try makeGitRepo()
        defer { try? FileManager.default.removeItem(at: siteDir) }
        try "CF_SOURCE_BUCKET=my-site-source\n".write(
            to: siteDir.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)
        let head = await currentHEAD(of: siteDir)

        let status = await SourceBundleStatus.check(
            siteDirectory: siteDir,
            settings: SiteSettings(deployedSourceBundleCommit: head)
        )
        #expect(status == .upToDate)
    }

    @Test("uploaded commit older than current HEAD reports .dirty with both SHAs")
    func dirty() async throws {
        let siteDir = try makeGitRepo()
        defer { try? FileManager.default.removeItem(at: siteDir) }
        try "CF_SOURCE_BUCKET=my-site-source\n".write(
            to: siteDir.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)
        let uploadedCommit = await currentHEAD(of: siteDir)

        // A new commit lands after the upload.
        try "changed".write(to: siteDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let commitProcess = Process()
        commitProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        commitProcess.arguments = ["sh", "-c", "git add -A && git commit -q -m update"]
        commitProcess.currentDirectoryURL = siteDir
        try commitProcess.run()
        commitProcess.waitUntilExit()
        let currentCommit = await currentHEAD(of: siteDir)

        let status = await SourceBundleStatus.check(
            siteDirectory: siteDir,
            settings: SiteSettings(deployedSourceBundleCommit: uploadedCommit)
        )
        #expect(status == .dirty(uploadedCommit: uploadedCommit, currentCommit: currentCommit))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter SourceBundleStatusTests`
Expected: FAIL — `SourceBundleStatus` does not exist.

- [ ] **Step 3: Implement `SourceBundleStatus`**

Create `Sources/AnglesiteCore/SourceBundleStatus.swift`:

```swift
import Foundation

/// "Code changes not yet deployed" (#799, spec §C.4 error-handling section): compares the git
/// commit SHA recorded at the last successful deployed-source bundle upload
/// (`SiteSettings.deployedSourceBundleCommit`) against `Source/`'s current `HEAD`. Surfaced as
/// existing dirty-state UI (`DeployDrawerView`), never as a bake error — a stale bundle is
/// correct-but-stale by design, not a failure.
public enum SourceBundleStatus: Sendable, Equatable {
    /// `.site-config` has no `CF_SOURCE_BUCKET` — the deployed-source bundle feature isn't active
    /// for this site (today: every site, since no provisioning flow writes that key yet).
    case notConfigured
    /// A bucket is configured but no upload has ever succeeded (`deployedSourceBundleCommit` is
    /// `nil`).
    case notYetUploaded
    /// The last uploaded commit matches `Source/`'s current `HEAD` — nothing to surface.
    case upToDate
    /// `Source/` has commits after the last uploaded bundle.
    case dirty(uploadedCommit: String, currentCommit: String)

    public static func check(siteDirectory: URL, settings: SiteSettings) async -> SourceBundleStatus {
        let configURL = siteDirectory.appendingPathComponent(".site-config")
        let config = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        guard SiteConfigFile.value(forKey: "CF_SOURCE_BUCKET", in: config) != nil else { return .notConfigured }
        guard let uploadedCommit = settings.deployedSourceBundleCommit else { return .notYetUploaded }

        let headResult = await InProcessGit.run(siteDirectory: siteDirectory, arguments: ["rev-parse", "HEAD"])
        guard headResult.exitCode == 0 else { return .upToDate }   // can't determine HEAD — fail quiet, not alarming
        let currentCommit = headResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        return currentCommit == uploadedCommit
            ? .upToDate
            : .dirty(uploadedCommit: uploadedCommit, currentCommit: currentCommit)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter SourceBundleStatusTests`
Expected: PASS — 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SourceBundleStatus.swift Tests/AnglesiteCoreTests/SourceBundleStatusTests.swift
git commit -m "feat(app): dirty-state check for the deployed-source bundle (#799)"
```

---

## Task 8: Surface "code changes not yet deployed" in `DeployDrawerView`

**Files:**
- Modify: `Sources/AnglesiteApp/DeployModel.swift`
- Modify: `Sources/AnglesiteApp/DeployDrawerView.swift`

**Interfaces:**
- Consumes: `SourceBundleStatus.check(siteDirectory:settings:)` (Task 7), `SiteConfigStore(configDirectory:).load()`.
- Produces: `DeployModel.sourceBundleStatus: SourceBundleStatus?` — refreshed after every successful deploy; `nil` before any deploy has run in this session. Read by `DeployDrawerView`.

- [ ] **Step 1: Add the observable property and refresh call to `DeployModel`**

In `Sources/AnglesiteApp/DeployModel.swift`, add the property near `failureSummary` (after line 29):

```swift
    /// On-device summary of the most recent *failed* deploy, or nil if none/unavailable.
    private(set) var failureSummary: DeployFailureSummary?
    /// "Code changes not yet deployed" status for the deployed-source bundle (#799). Refreshed
    /// after every successful deploy; `nil` before any deploy has completed this session or when
    /// the check couldn't be performed. `.notConfigured` (no `CF_SOURCE_BUCKET`) is the expected
    /// value for every site today — the drawer only renders a line for `.dirty`.
    private(set) var sourceBundleStatus: SourceBundleStatus?
```

In `runDeploy`'s `.succeeded` case (currently lines 425-445), add a status refresh right after the transition:

```swift
        case .succeeded(let url, let duration):
            // Astro's build above regenerates RSS/Atom/JSON feeds. Social delivery is ordered
            // after the deployed canonical pages exist, and completion is notified only after
            // both best-effort passes finish.
            emitPostDeployMilestone(.deployWebmentions, siteID: siteID)
            await webmentionCommand.send(
                siteID: siteID,
                siteDirectory: siteDirectory,
                configDirectory: configDirectory,
                siteBase: url
            )
            emitPostDeployMilestone(.deploySyndicating, siteID: siteID)
            await posseCommand.syndicate(
                siteID: siteID,
                siteDirectory: siteDirectory,
                configDirectory: configDirectory,
                siteBase: url
            )
            currentMilestone = nil
            workerNameConflictPresented = false
            if let settings = try? await SiteConfigStore(configDirectory: configDirectory).load() {
                sourceBundleStatus = await SourceBundleStatus.check(siteDirectory: siteDirectory, settings: settings)
            }
            transition(siteID: siteID, to: .succeeded(url: url, duration: duration))
```

- [ ] **Step 2: Add the UI line to `DeployDrawerView`**

Read `Sources/AnglesiteApp/DeployDrawerView.swift` in full first to find the exact `if case .succeeded(let url, _) = model.phase { ... }` block (referenced at line 48 in the research above) and match its existing `VStack`/`Text` styling exactly. Inside that block, after whatever renders the URL, add:

```swift
if case .dirty = model.sourceBundleStatus {
    Text("Code changes not yet deployed to the CMS bundle.")
        .font(.caption)
        .foregroundStyle(.secondary)
}
```

(Match indentation and the surrounding `VStack`'s `spacing`/`alignment` to the block you find — do not introduce a new container view for one line.)

- [ ] **Step 3: Build and manually verify**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: build succeeds.

Manual check (per CLAUDE.md's UI-change rule — this is a real UI change): since `CF_SOURCE_BUCKET` is unconfigured for every real site today (no provisioning flow writes it — Task 6/7 note this explicitly), `sourceBundleStatus` will be `.notConfigured` after any real deploy in this app version, so the new line correctly never renders yet. Confirm this by running a real deploy in the app (any existing test site) and checking the deploy drawer shows no new text — the absence is the expected, correct behavior until a future provisioning flow starts writing `CF_SOURCE_BUCKET`.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteApp/DeployModel.swift Sources/AnglesiteApp/DeployDrawerView.swift
git commit -m "feat(ui): surface deployed-source bundle staleness in the deploy drawer (#799)"
```

---

## Final verification (before opening the PR)

- [ ] Run the full Swift suite: `swift test --package-path .` — expect all green (container/e2e-gated suites skip as usual).
- [ ] Run the full app build: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build` — expect success.
- [ ] Run the template's test:worker + build: `cd Resources/Template && npm run test:worker && npm run build` — expect success.
- [ ] Run the template's `node:test` script suites touched by this plan: `cd Resources/Template && node --import tsx --test scripts/pre-deploy-check.test.ts src/lib/content-loader.test.ts` — expect all pass.
- [ ] Re-read the issue body (`gh issue view 799`) and confirm all five scope bullets are covered: `build:ci` script ✅ (Task 1), envelope-from-log parsing feeding `Phase.blocked` ✅ (Task 2, consumed by Task 3's fixture proof; the live UI consumer is slice 4), content-layer loader seam ✅ (Task 4), deployed-source bundle upload + dirty-state UI ✅ (Tasks 5-8), producer test ✅ (Task 3).
- [ ] Remove the `🛠️ In Progress` label once the PR opens: `gh issue edit 799 --remove-label "🛠️ In Progress"`.
