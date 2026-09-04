import Testing
import Foundation
import AnglesiteTestSupport
@testable import AnglesiteCore

/// Runs the REAL `pre-deploy-check.ts --json` (not a hand-authored JSON string) against a small
/// fixture `dist/` and decodes its actual stdout through `PreDeployCheck.parse` — the
/// producer→consumer test #742 exists to add. Every other test in this suite hand-authors JSON in
/// the Swift-expected shape, which is exactly how the envelope mismatch this issue fixes went
/// uncaught for so long.
struct PreDeployCheckFixtureTests {
    /// True when both a Node binary is available and `tsx` is resolvable via `npx` *without*
    /// hitting the network. `Resources/Template` has no installed `node_modules` in this repo, so
    /// gating on a local `tsx` install (like the render-smoke suites gate on `node_modules/astro`)
    /// would make this test skip almost always, defeating its purpose. Instead this checks whether
    /// `npx` can resolve `tsx` from a global install or its own on-disk cache — the state that lets
    /// the test run cleanly without a live registry fetch.
    static var buildable: Bool {
        guard E2EPrerequisites.locateNode() != nil else { return false }
        return tsxResolvableOffline
    }

    /// Runs `npx --offline tsx --version` and reports whether it exits zero.
    ///
    /// `--offline` puts npm's cache resolution in `only-if-cached` mode, so a cache hit (global
    /// install or npx's package cache) succeeds immediately and a cache miss fails immediately with
    /// `ENOTCACHED` — no registry request either way. This is deliberately `--offline` rather than
    /// the more commonly suggested `--no-install`: recent npm (tested here against npm 11) no
    /// longer honors `--no-install` as a hard "don't touch the network" switch — a cache miss with
    /// `--no-install` still fell through to a live `GET https://registry.npmjs.org/...` in local
    /// testing, which is exactly the network dependency this gate exists to avoid.
    private static var tsxResolvableOffline: Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["npx", "--offline", "tsx", "--version"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

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

    @Test("Real script output with a PII hit decodes to .blocked with the pii-email category",
          .enabled(if: PreDeployCheckFixtureTests.buildable))
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

    @Test("Real script output with no issues decodes to .passed",
          .enabled(if: PreDeployCheckFixtureTests.buildable))
    func realScriptWithNoIssuesDecodesToPassed() throws {
        let siteDir = try makeFixtureDist(html: "<html><body><p>Nothing sensitive here.</p></body></html>")
        defer { try? FileManager.default.removeItem(at: siteDir) }
        // A CSP-satisfying _headers file, robots.txt, and a valid hand-authored (manual-mode)
        // security.txt, so this fixture is fully clean under the state-aware check (#743).
        try "/*\n  Content-Security-Policy: default-src 'self'\n".write(
            to: siteDir.appendingPathComponent("dist/_headers"), atomically: true, encoding: .utf8)
        try "User-agent: *\n".write(
            to: siteDir.appendingPathComponent("dist/robots.txt"), atomically: true, encoding: .utf8)
        try "SECURITY_TXT_MODE=manual\n".write(
            to: siteDir.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)
        let wellKnown = siteDir.appendingPathComponent("dist/.well-known", isDirectory: true)
        try FileManager.default.createDirectory(at: wellKnown, withIntermediateDirectories: true)
        try "Contact: mailto:security@example.com\nExpires: 2099-01-01T00:00:00.000Z\n".write(
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

    @Test("Real script: SECURITY_TXT_MODE=disabled but a published security.txt is a mode/file contradiction",
          .enabled(if: PreDeployCheckFixtureTests.buildable))
    func realScriptFlagsDisabledModeContradiction() throws {
        let siteDir = try makeFixtureDist(html: "<html><body><p>Nothing sensitive here.</p></body></html>")
        defer { try? FileManager.default.removeItem(at: siteDir) }
        try "/*\n  Content-Security-Policy: default-src 'self'\n".write(
            to: siteDir.appendingPathComponent("dist/_headers"), atomically: true, encoding: .utf8)
        try "User-agent: *\n".write(
            to: siteDir.appendingPathComponent("dist/robots.txt"), atomically: true, encoding: .utf8)
        try "SECURITY_TXT_MODE=disabled\n".write(
            to: siteDir.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)
        let wellKnown = siteDir.appendingPathComponent("dist/.well-known", isDirectory: true)
        try FileManager.default.createDirectory(at: wellKnown, withIntermediateDirectories: true)
        try "Contact: mailto:security@example.com\nExpires: 2099-01-01T00:00:00.000Z\n".write(
            to: wellKnown.appendingPathComponent("security.txt"), atomically: true, encoding: .utf8)

        let result = try runRealScript(siteDir: siteDir)
        #expect(result.exitCode == 0) // security-txt-issue is a warning, not a blocking failure

        let outcome = PreDeployCheck.parse(output: result.stdout, exitCode: result.exitCode)
        guard case .passed(let warnings) = outcome else {
            Issue.record("expected .passed(warnings:), got \(outcome) — raw stdout: \(result.stdout)")
            return
        }
        #expect(warnings.contains { $0.category == .securityTxtIssue })
    }

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
        try "SECURITY_TXT_MODE=manual\n".write(
            to: siteDir.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)
        let wellKnown = siteDir.appendingPathComponent("dist/.well-known", isDirectory: true)
        try FileManager.default.createDirectory(at: wellKnown, withIntermediateDirectories: true)
        try "Contact: mailto:security@example.com\nExpires: 2099-01-01T00:00:00.000Z\n".write(
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
        // NOTE (#799 concern, not fixed here — out of scope for this task): `ScanFailure.Category`
        // (Sources/AnglesiteCore/Cloudflare/PreDeployCheck.swift, pre-existing #742 code) has no
        // `.missingSecurityArtifact` case — that raw value only exists on `ScanWarning.Category`.
        // When `--strict` promotes a "missing-security-artifact" warning into the JSON `failures`
        // array, `PreDeployCheck.parse` decodes it as a `ScanFailure`, whose `Category.init(from:)`
        // falls back unrecognized raw values to `.other` — the specific category is silently lost
        // on the failures side. Asserting on `.other` here (plus the message text) documents that
        // real, current behavior rather than asserting a category value that can't compile.
        #expect(failures.contains { $0.category == .other && $0.message.contains("Missing security artifact") })
        #expect(warnings.isEmpty)   // --strict moves everything into failures
    }
}
