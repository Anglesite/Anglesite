import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct ExistingSiteMigrationTests {
    private func tmpDirs() -> (source: URL, config: URL, template: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("Source")
        let config = root.appendingPathComponent("Config")
        let template = root.appendingPathComponent("Template")
        for d in [source, config, template] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        return (source, config, template)
    }

    private func writeFile(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A commit seam that records what was staged instead of touching git — these temp dirs are
    /// not repositories.
    private final class CommitRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var batches: [[String]] = []
        func record(_ paths: [String]) {
            lock.lock(); batches.append(paths); lock.unlock()
        }
    }

    @Test func cleanSiteWithNothingToMigrateCommitsNothingAndLogsNothing() async throws {
        let (source, config, template) = tmpDirs()
        let logCenter = LogCenter()
        try writeFile("shared", to: template.appendingPathComponent("scripts/pre-deploy-check.ts"))
        try writeFile("shared", to: source.appendingPathComponent("scripts/pre-deploy-check.ts"))
        // SECURITY_TXT_MODE must already be set for this to be a genuinely "nothing to migrate"
        // site — an absent key (even with no security.txt file) is itself a silent-backfill case
        // per `SecurityTxtMigrationChecker.check`, which would touch `.site-config` and defeat
        // this test's "commits nothing" premise.
        try writeFile("SECURITY_TXT_MODE=disabled\n", to: source.appendingPathComponent(".site-config"))
        let recorder = CommitRecorder()

        let report = await ExistingSiteMigration.runNoninteractively(
            sourceDirectory: source, configDirectory: config, templateDirectory: template,
            source: "test", logCenter: logCenter, gitCommitBatch: { _, paths, _ in recorder.record(paths); return "sha" }
        )

        #expect(report.isEmpty)
        #expect(report.committed)
        #expect(recorder.batches.isEmpty)
        let lines = await logCenter.snapshot()
        #expect(lines.isEmpty)
    }

    @Test func unbaselinedChangedScriptFileIsRestoredToTheAppsCopyAndCommitted() async throws {
        // #1962 (owner decision D1): the pre-#1962 behavior preserved a changed app-owned file
        // ("keep mine" by default on the headless path). The app now restores its own copy — the
        // gate script is the app's machinery, not the owner's content — and commits the restore.
        let (source, config, template) = tmpDirs()
        let logCenter = LogCenter()
        try writeFile("new template content", to: template.appendingPathComponent("scripts/pre-deploy-check.ts"))
        try writeFile("owner's content", to: source.appendingPathComponent("scripts/pre-deploy-check.ts"))
        try writeFile("SECURITY_TXT_MODE=disabled\n", to: source.appendingPathComponent(".site-config"))
        let recorder = CommitRecorder()

        let report = await ExistingSiteMigration.runNoninteractively(
            sourceDirectory: source, configDirectory: config, templateDirectory: template,
            source: "test", logCenter: logCenter, gitCommitBatch: { _, paths, _ in recorder.record(paths); return "sha" }
        )

        let restored = try String(contentsOf: source.appendingPathComponent("scripts/pre-deploy-check.ts"), encoding: .utf8)
        #expect(restored == "new template content")
        #expect(report.restoredPaths == ["scripts/pre-deploy-check.ts"])
        #expect(report.refreshedPaths.isEmpty)
        #expect(report.committed)
        #expect(recorder.batches == [["scripts/pre-deploy-check.ts"]])
        let lines = await logCenter.snapshot()
        #expect(lines.contains { $0.text.contains("scripts/pre-deploy-check.ts") && $0.text.contains("restored") })
    }

    @Test func aRestoredFileIsANoOpOnTheNextRun() async throws {
        let (source, config, template) = tmpDirs()
        try writeFile("new template content", to: template.appendingPathComponent("scripts/pre-deploy-check.ts"))
        try writeFile("owner's content", to: source.appendingPathComponent("scripts/pre-deploy-check.ts"))
        try writeFile("SECURITY_TXT_MODE=disabled\n", to: source.appendingPathComponent(".site-config"))

        _ = await ExistingSiteMigration.runNoninteractively(
            sourceDirectory: source, configDirectory: config, templateDirectory: template,
            source: "test", logCenter: LogCenter(), gitCommitBatch: { _, _, _ in "sha" }
        )
        let second = await ExistingSiteMigration.runNoninteractively(
            sourceDirectory: source, configDirectory: config, templateDirectory: template,
            source: "test", logCenter: LogCenter(), gitCommitBatch: { _, _, _ in "sha" }
        )

        #expect(second.isEmpty)
        let content = try String(contentsOf: source.appendingPathComponent("scripts/pre-deploy-check.ts"), encoding: .utf8)
        #expect(content == "new template content")
    }

    @Test func missingAndStaleFilesAreReportedAsRefreshedNotRestored() async throws {
        let (source, config, template) = tmpDirs()
        try writeFile("template a", to: template.appendingPathComponent("scripts/a.ts"))
        try writeFile("template b v2", to: template.appendingPathComponent("scripts/b.ts"))
        try writeFile("template b v1", to: source.appendingPathComponent("scripts/b.ts"))
        var baseline = TemplateScriptsBaseline()
        baseline.files["scripts/b.ts"] = .init(baselineHash: VectorMath.stableHash("template b v1"))
        try baseline.save(to: config)
        try writeFile("SECURITY_TXT_MODE=disabled\n", to: source.appendingPathComponent(".site-config"))

        let report = await ExistingSiteMigration.runNoninteractively(
            sourceDirectory: source, configDirectory: config, templateDirectory: template,
            source: "test", logCenter: LogCenter(), gitCommitBatch: { _, _, _ in "sha" }
        )

        #expect(report.refreshedPaths.sorted() == ["scripts/a.ts", "scripts/b.ts"])
        #expect(report.restoredPaths.isEmpty)
    }

    @Test func aFailedCommitIsReportedAndLeavesTheRetryRecord() async throws {
        let (source, config, template) = tmpDirs()
        let logCenter = LogCenter()
        try writeFile("template a", to: template.appendingPathComponent("scripts/a.ts"))
        try writeFile("SECURITY_TXT_MODE=disabled\n", to: source.appendingPathComponent(".site-config"))

        let report = await ExistingSiteMigration.runNoninteractively(
            sourceDirectory: source, configDirectory: config, templateDirectory: template,
            source: "test", logCenter: logCenter, gitCommitBatch: { _, _, _ in nil }
        )

        #expect(report.refreshedPaths == ["scripts/a.ts"])
        #expect(!report.committed)
        #expect(ExistingSiteMigrationPendingCommit.load(from: config).pendingPaths == ["scripts/a.ts"])
        let lines = await logCenter.snapshot()
        #expect(lines.contains { $0.text.contains("couldn't commit") })
    }

    @Test func unmarkedSecurityTxtNeedingDecisionDefaultsToPreserveOnTheHeadlessPath() async throws {
        let (source, config, template) = tmpDirs()
        let logCenter = LogCenter()
        try writeFile("SECURITY_CONTACT=security@example.com\n", to: source.appendingPathComponent(".site-config"))
        try writeFile("Contact: mailto:someone-else@example.com\n", to: source.appendingPathComponent("public/.well-known/security.txt"))

        let report = await ExistingSiteMigration.runNoninteractively(
            sourceDirectory: source, configDirectory: config, templateDirectory: template,
            source: "test", logCenter: logCenter, gitCommitBatch: { _, _, _ in "sha" }
        )

        let unchanged = try String(contentsOf: source.appendingPathComponent("public/.well-known/security.txt"), encoding: .utf8)
        #expect(unchanged == "Contact: mailto:someone-else@example.com\n")
        let siteConfig = try String(contentsOf: source.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(siteConfig.contains("SECURITY_TXT_MODE=manual"))
        #expect(report.securityTxtPreserved)
        let lines = await logCenter.snapshot()
        #expect(lines.contains { $0.text.contains("public/.well-known/security.txt") })
    }

    @Test func theSecurityTxtDecisionSeamIsAskedOnlyForTheAmbiguousCaseAndItsAnswerIsApplied() async throws {
        // The windowed path's one remaining question: `run` calls the seam for `.needsDecision`
        // and applies whatever it answers — here Adopt, the opposite of the headless default.
        let (source, config, template) = tmpDirs()
        try writeFile("SECURITY_CONTACT=security@example.com\n", to: source.appendingPathComponent(".site-config"))
        try writeFile("Contact: mailto:someone-else@example.com\n", to: source.appendingPathComponent("public/.well-known/security.txt"))
        let asked = CommitRecorder()

        let report = await ExistingSiteMigration.run(
            sourceDirectory: source, configDirectory: config, templateDirectory: template,
            securityTxtDecision: { asked.record(["asked"]); return .adopt },
            source: "test", logCenter: LogCenter(), gitCommitBatch: { _, _, _ in "sha" }
        )

        #expect(asked.batches.count == 1)
        #expect(!report.securityTxtPreserved)
        let siteConfig = try String(contentsOf: source.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(siteConfig.contains("SECURITY_TXT_MODE=generated"))
    }

    @Test func silentBackfillsCommitWithoutAskingOrLoggingAFinding() async throws {
        let (source, config, template) = tmpDirs()
        let logCenter = LogCenter()
        try writeFile("SECURITY_CONTACT=security@example.com\n", to: source.appendingPathComponent(".site-config"))
        let asked = CommitRecorder()

        let report = await ExistingSiteMigration.run(
            sourceDirectory: source, configDirectory: config, templateDirectory: template,
            securityTxtDecision: { asked.record(["asked"]); return .preserve },
            source: "test", logCenter: logCenter, gitCommitBatch: { _, _, _ in "sha" }
        )

        #expect(asked.batches.isEmpty)
        let siteConfig = try String(contentsOf: source.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(siteConfig.contains("SECURITY_TXT_MODE=generated"))
        #expect(report.otherTouchedPaths == [".site-config"])
        let lines = await logCenter.snapshot()
        #expect(!lines.contains { $0.text.contains("unresolved") || $0.text.contains("restored") })
    }
}
