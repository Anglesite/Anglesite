import Testing
import Foundation
@testable import AnglesiteCore

/// #1958 (owner decision D5): the app-owned script set is verified against the app's own copy
/// before every deploy; any mismatch refuses the deploy, restores the app's copy, and commits it.
@Suite struct AppOwnedScriptsGateTests {
    private func tmpDirs() -> (source: URL, config: URL, template: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gate-\(UUID().uuidString)")
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

    /// A template with the gate script plus one `src/lib/` module it imports, and a site whose
    /// copies match exactly.
    private func makeIntactFixture() throws -> (source: URL, config: URL, template: URL) {
        let dirs = tmpDirs()
        for relativePath in ["scripts/pre-deploy-check.ts", "src/lib/rsl.ts"] {
            try writeFile("app copy of \(relativePath)", to: dirs.template.appendingPathComponent(relativePath))
            try writeFile("app copy of \(relativePath)", to: dirs.source.appendingPathComponent(relativePath))
        }
        return dirs
    }

    private final class CommitRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var batches: [(paths: [String], message: String)] = []
        var succeed = true
        func record(_ paths: [String], _ message: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            batches.append((paths, message))
            return succeed ? "deadbeef" : nil
        }
    }

    /// A scripted runtime copy: answers `digests` with a canned value and records what `restore`
    /// was asked to write.
    private final class RuntimeRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var digestCalls = 0
        private(set) var restoredPaths: [String] = []
        var restoreSucceeds = true
        let answer: AppOwnedScriptsGate.RuntimeCopy.Digests
        init(answer: AppOwnedScriptsGate.RuntimeCopy.Digests) { self.answer = answer }

        var copy: AppOwnedScriptsGate.RuntimeCopy {
            AppOwnedScriptsGate.RuntimeCopy(
                digests: { _ in
                    self.lock.withLock { self.digestCalls += 1 }
                    return self.answer
                },
                restore: { pins in
                    self.lock.withLock {
                        self.restoredPaths = pins.map(\.relativePath)
                        return self.restoreSucceeds
                    }
                })
        }
    }

    private func sha256(_ text: String) -> String { PortableSHA256.hexDigest(of: Data(text.utf8)) }

    // MARK: pins + verify

    @Test func pinsCoverEveryManifestFileWithItsBytesAndDigest() throws {
        let (_, _, template) = try makeIntactFixture()
        let pins = AppOwnedScriptsGate.pins(templateDirectory: template)
        #expect(pins.map(\.relativePath) == ["scripts/pre-deploy-check.ts", "src/lib/rsl.ts"])
        #expect(pins[0].content == Data("app copy of scripts/pre-deploy-check.ts".utf8))
        #expect(pins[0].sha256 == sha256("app copy of scripts/pre-deploy-check.ts"))
    }

    @Test func anUntouchedSiteVerifiesIntact() throws {
        let (source, _, template) = try makeIntactFixture()
        let verification = AppOwnedScriptsGate.verify(
            sourceDirectory: source, pins: AppOwnedScriptsGate.pins(templateDirectory: template))
        #expect(verification.isIntact)
        #expect(verification.intactPaths.sorted() == ["scripts/pre-deploy-check.ts", "src/lib/rsl.ts"])
    }

    @Test func aTamperedGateScriptAndAMissingLibModuleAreBothMismatches() throws {
        let (source, _, template) = try makeIntactFixture()
        try writeFile("export {} // scan disabled", to: source.appendingPathComponent("scripts/pre-deploy-check.ts"))
        try FileManager.default.removeItem(at: source.appendingPathComponent("src/lib/rsl.ts"))

        let verification = AppOwnedScriptsGate.verify(
            sourceDirectory: source, pins: AppOwnedScriptsGate.pins(templateDirectory: template))
        #expect(!verification.isIntact)
        #expect(verification.modifiedPaths == ["scripts/pre-deploy-check.ts"])
        #expect(verification.missingPaths == ["src/lib/rsl.ts"])
        #expect(verification.mismatchedPaths == ["scripts/pre-deploy-check.ts", "src/lib/rsl.ts"])
    }

    @Test func aScaffoldOnlyTemplateFileIsNotPartOfTheVerifiedSet() throws {
        // `scaffold.sh`/`themes.ts` never ship into a site (TemplateScriptsManifest excludes them),
        // so their absence from the site is not a mismatch.
        let (source, _, template) = try makeIntactFixture()
        try writeFile("#!/bin/sh", to: template.appendingPathComponent("scripts/scaffold.sh"))
        try writeFile("export const THEMES", to: template.appendingPathComponent("scripts/themes.ts"))
        #expect(AppOwnedScriptsGate.verify(
            sourceDirectory: source, pins: AppOwnedScriptsGate.pins(templateDirectory: template)).isIntact)
    }

    @Test func runtimeDigestsAreComparedCaseInsensitivelyAndAbsentPathsAreMissing() throws {
        let (_, _, template) = try makeIntactFixture()
        let pins = AppOwnedScriptsGate.pins(templateDirectory: template)
        let verification = AppOwnedScriptsGate.verify(
            digests: ["scripts/pre-deploy-check.ts": sha256("app copy of scripts/pre-deploy-check.ts").uppercased()],
            pins: pins)
        #expect(verification.intactPaths == ["scripts/pre-deploy-check.ts"])
        #expect(verification.missingPaths == ["src/lib/rsl.ts"])
        let tampered = AppOwnedScriptsGate.verify(
            digests: ["scripts/pre-deploy-check.ts": sha256("x"), "src/lib/rsl.ts": nil], pins: pins)
        #expect(tampered.modifiedPaths == ["scripts/pre-deploy-check.ts"])
        #expect(tampered.missingPaths == ["src/lib/rsl.ts"])
    }

    // MARK: enforce — host copy

    @Test func intactScriptsPassWithoutWritingOrCommitting() async throws {
        let (source, config, template) = try makeIntactFixture()
        let recorder = CommitRecorder()
        let outcome = await AppOwnedScriptsGate.enforce(
            sourceDirectory: source, configDirectory: config, templateDirectory: template,
            source: "test", logCenter: LogCenter(), gitCommitBatch: { _, p, m in recorder.record(p, m) })
        #expect(outcome == .intact)
        #expect(recorder.batches.isEmpty)
    }

    @Test func aTamperedGateBlocksRestoresTheAppsCopyAndCommitsIt() async throws {
        let (source, config, template) = try makeIntactFixture()
        try writeFile("export {} // scan disabled", to: source.appendingPathComponent("scripts/pre-deploy-check.ts"))
        let recorder = CommitRecorder()
        let logCenter = LogCenter()

        let outcome = await AppOwnedScriptsGate.enforce(
            sourceDirectory: source, configDirectory: config, templateDirectory: template,
            source: "test", logCenter: logCenter, gitCommitBatch: { _, p, m in recorder.record(p, m) })

        #expect(outcome == .blocked(restored: ["scripts/pre-deploy-check.ts"], unrestorable: [], committed: true))
        let restored = try String(contentsOf: source.appendingPathComponent("scripts/pre-deploy-check.ts"), encoding: .utf8)
        #expect(restored == "app copy of scripts/pre-deploy-check.ts")
        #expect(recorder.batches.count == 1)
        #expect(recorder.batches[0].paths == ["scripts/pre-deploy-check.ts"])
        #expect(recorder.batches[0].message == AppOwnedScriptsGate.commitMessage)
        // The baseline follows the restore, so the next site open sees a reconciled file rather
        // than re-flagging it.
        #expect(TemplateScriptsBaseline.load(from: config).files["scripts/pre-deploy-check.ts"]?.baselineHash
            == VectorMath.stableHash("app copy of scripts/pre-deploy-check.ts"))
        let lines = await logCenter.snapshot()
        #expect(lines.contains { $0.text.contains("had been changed") && $0.text.contains("scripts/pre-deploy-check.ts") })
        // And the same site now verifies intact — the next deploy proceeds.
        let again = await AppOwnedScriptsGate.enforce(
            sourceDirectory: source, configDirectory: config, templateDirectory: template,
            source: "test", logCenter: logCenter, gitCommitBatch: { _, p, m in recorder.record(p, m) })
        #expect(again == .intact)
    }

    @Test func aMissingLibModuleIsRestoredToo() async throws {
        let (source, config, template) = try makeIntactFixture()
        try FileManager.default.removeItem(at: source.appendingPathComponent("src/lib/rsl.ts"))
        let recorder = CommitRecorder()

        let outcome = await AppOwnedScriptsGate.enforce(
            sourceDirectory: source, configDirectory: config, templateDirectory: template,
            source: "test", logCenter: LogCenter(), gitCommitBatch: { _, p, m in recorder.record(p, m) })

        #expect(outcome == .blocked(restored: ["src/lib/rsl.ts"], unrestorable: [], committed: true))
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("src/lib/rsl.ts").path))
    }

    @Test func withoutAConfigDirectoryTheRestoreStillCommitsDirectly() async throws {
        // The non-primary deploy paths pass no `Config/` (#530); the gate must not weaken there —
        // it commits straight through the batch seam instead of via the pending record.
        let (source, _, template) = try makeIntactFixture()
        try writeFile("tampered", to: source.appendingPathComponent("scripts/pre-deploy-check.ts"))
        let recorder = CommitRecorder()

        let outcome = await AppOwnedScriptsGate.enforce(
            sourceDirectory: source, configDirectory: nil, templateDirectory: template,
            source: "test", logCenter: LogCenter(), gitCommitBatch: { _, p, m in recorder.record(p, m) })

        #expect(outcome == .blocked(restored: ["scripts/pre-deploy-check.ts"], unrestorable: [], committed: true))
        #expect(recorder.batches.count == 1)
    }

    @Test func aFailedCommitIsReportedButTheFileIsStillRestored() async throws {
        let (source, config, template) = try makeIntactFixture()
        try writeFile("tampered", to: source.appendingPathComponent("scripts/pre-deploy-check.ts"))
        let recorder = CommitRecorder()
        recorder.succeed = false

        let outcome = await AppOwnedScriptsGate.enforce(
            sourceDirectory: source, configDirectory: config, templateDirectory: template,
            source: "test", logCenter: LogCenter(), gitCommitBatch: { _, p, m in recorder.record(p, m) })

        #expect(outcome == .blocked(restored: ["scripts/pre-deploy-check.ts"], unrestorable: [], committed: false))
        let restored = try String(contentsOf: source.appendingPathComponent("scripts/pre-deploy-check.ts"), encoding: .utf8)
        #expect(restored == "app copy of scripts/pre-deploy-check.ts")
        #expect(ExistingSiteMigrationPendingCommit.load(from: config).pendingPaths == ["scripts/pre-deploy-check.ts"])
    }

    @Test func aMissingTemplateIsUnverifiableAndLoggedNotSilentlyIntact() async throws {
        let (source, config, _) = try makeIntactFixture()
        let logCenter = LogCenter()
        let outcome = await AppOwnedScriptsGate.enforce(
            sourceDirectory: source, configDirectory: config, templateDirectory: nil,
            source: "test", logCenter: logCenter, gitCommitBatch: { _, _, _ in "x" })
        guard case .unverifiable = outcome else {
            Issue.record("expected .unverifiable, got \(outcome)"); return
        }
        let lines = await logCenter.snapshot()
        #expect(lines.contains { $0.stream == .stderr && $0.text.contains("couldn't find its own copy") })
    }

    @Test func aTemplateWithNoAppOwnedScriptsIsUnverifiableToo() async throws {
        let (source, config, _) = try makeIntactFixture()
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("gate-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let outcome = await AppOwnedScriptsGate.enforce(
            sourceDirectory: source, configDirectory: config, templateDirectory: empty,
            source: "test", logCenter: LogCenter(), gitCommitBatch: { _, _, _ in "x" })
        guard case .unverifiable = outcome else {
            Issue.record("expected .unverifiable, got \(outcome)"); return
        }
    }

    // MARK: enforce — runtime copy

    @Test func aRuntimeCopyThatMatchesTheHostAddsNothing() async throws {
        let (source, config, template) = try makeIntactFixture()
        let pins = AppOwnedScriptsGate.pins(templateDirectory: template)
        let runtime = RuntimeRecorder(answer: .digests(Dictionary(uniqueKeysWithValues: pins.map { ($0.relativePath, $0.sha256) })))
        let outcome = await AppOwnedScriptsGate.enforce(
            sourceDirectory: source, configDirectory: config, templateDirectory: template,
            runtimeCopy: runtime.copy, source: "test", logCenter: LogCenter(), gitCommitBatch: { _, _, _ in "x" })
        #expect(outcome == .intact)
        #expect(runtime.digestCalls == 1)
        #expect(runtime.restoredPaths.isEmpty)
    }

    @Test func aTamperedRuntimeCopyBlocksAndIsRestoredEvenThoughTheHostIsIntact() async throws {
        // The in-guest edit case: the host repo never saw the change, but the guest's clone —
        // where the scan actually runs — did.
        let (source, config, template) = try makeIntactFixture()
        let pins = AppOwnedScriptsGate.pins(templateDirectory: template)
        var digests: [String: String?] = Dictionary(uniqueKeysWithValues: pins.map { ($0.relativePath, Optional($0.sha256)) })
        digests["scripts/pre-deploy-check.ts"] = sha256("export {} // disabled in the guest")
        let runtime = RuntimeRecorder(answer: .digests(digests))
        let recorder = CommitRecorder()

        let outcome = await AppOwnedScriptsGate.enforce(
            sourceDirectory: source, configDirectory: config, templateDirectory: template,
            runtimeCopy: runtime.copy, source: "test", logCenter: LogCenter(), gitCommitBatch: { _, p, m in recorder.record(p, m) })

        #expect(outcome == .blocked(restored: ["scripts/pre-deploy-check.ts"], unrestorable: [], committed: true))
        #expect(runtime.restoredPaths == ["scripts/pre-deploy-check.ts"])
        #expect(recorder.batches.isEmpty, "nothing changed on the host, so nothing is committed there")
    }

    @Test func aHostRestoreIsPushedIntoTheRuntimeCopyInTheSameAttempt() async throws {
        // Host tampered, guest merely behind (it still reports the old app copy): the host is
        // restored and committed, and the runtime copy is asked to catch up now — not on the
        // owner's next attempt.
        let (source, config, template) = try makeIntactFixture()
        try writeFile("tampered", to: source.appendingPathComponent("scripts/pre-deploy-check.ts"))
        let runtime = RuntimeRecorder(answer: .digests([
            "scripts/pre-deploy-check.ts": sha256("tampered"),
            "src/lib/rsl.ts": sha256("app copy of src/lib/rsl.ts"),
        ]))
        let recorder = CommitRecorder()

        let outcome = await AppOwnedScriptsGate.enforce(
            sourceDirectory: source, configDirectory: config, templateDirectory: template,
            runtimeCopy: runtime.copy, source: "test", logCenter: LogCenter(), gitCommitBatch: { _, p, m in recorder.record(p, m) })

        #expect(outcome == .blocked(restored: ["scripts/pre-deploy-check.ts"], unrestorable: [], committed: true))
        #expect(recorder.batches.count == 1)
        #expect(runtime.restoredPaths == ["scripts/pre-deploy-check.ts"])
    }

    @Test func aRuntimeRestoreThatFailsIsReportedAsUnrestorable() async throws {
        let (source, config, template) = try makeIntactFixture()
        let runtime = RuntimeRecorder(answer: .digests(["scripts/pre-deploy-check.ts": nil, "src/lib/rsl.ts": nil]))
        runtime.restoreSucceeds = false
        let outcome = await AppOwnedScriptsGate.enforce(
            sourceDirectory: source, configDirectory: config, templateDirectory: template,
            runtimeCopy: runtime.copy, source: "test", logCenter: LogCenter(), gitCommitBatch: { _, _, _ in "x" })
        #expect(outcome == .blocked(restored: [], unrestorable: ["scripts/pre-deploy-check.ts", "src/lib/rsl.ts"], committed: true))
    }

    @Test func aRuntimeCopyThatCannotBeReadRefusesTheDeployWithoutRestoringAnything() async throws {
        let (source, config, template) = try makeIntactFixture()
        let runtime = RuntimeRecorder(answer: .failed(reason: "container exec failed"))
        let logCenter = LogCenter()
        let outcome = await AppOwnedScriptsGate.enforce(
            sourceDirectory: source, configDirectory: config, templateDirectory: template,
            runtimeCopy: runtime.copy, source: "test", logCenter: logCenter, gitCommitBatch: { _, _, _ in "x" })
        #expect(outcome == .runtimeUnverifiable(reason: "container exec failed"))
        #expect(runtime.restoredPaths.isEmpty)
        #expect(AppOwnedScriptsGate.scanFailure(for: outcome) == nil)
        #expect(AppOwnedScriptsGate.failureReason(for: outcome)?.contains("try publishing again") == true)
        let lines = await logCenter.snapshot()
        #expect(lines.contains { $0.stream == .stderr && $0.text.contains("container exec failed") })
    }

    @Test func aRuntimeCopyReportingSameAsHostIsNotAskedToRestore() async throws {
        let (source, config, template) = try makeIntactFixture()
        try writeFile("tampered", to: source.appendingPathComponent("scripts/pre-deploy-check.ts"))
        let runtime = RuntimeRecorder(answer: .sameAsHost)
        let outcome = await AppOwnedScriptsGate.enforce(
            sourceDirectory: source, configDirectory: config, templateDirectory: template,
            runtimeCopy: runtime.copy, source: "test", logCenter: LogCenter(), gitCommitBatch: { _, _, _ in "x" })
        #expect(outcome == .blocked(restored: ["scripts/pre-deploy-check.ts"], unrestorable: [], committed: true))
        #expect(runtime.restoredPaths.isEmpty)
    }

    // MARK: owner-facing failure

    @Test func theBlockedFailureIsPhrasedForTheOwnerWithPathsOnlyInDetail() throws {
        let failure = try #require(AppOwnedScriptsGate.scanFailure(
            for: .blocked(restored: ["scripts/pre-deploy-check.ts"], unrestorable: [], committed: true)))
        #expect(failure.category == .appOwnedScriptRestored)
        #expect(failure.message == "Anglesite's safety check on this site had been changed. It has been restored.")
        #expect(failure.file == nil)
        #expect(!failure.message.contains("scripts/"))
        #expect(failure.detail == "Restored: scripts/pre-deploy-check.ts")
        #expect(failure.remediation?.contains("Publish again") == true)
    }

    @Test func anUncommittedRestoreSaysSoWithoutChangingTheRemediation() throws {
        let failure = try #require(AppOwnedScriptsGate.scanFailure(
            for: .blocked(restored: ["scripts/pre-deploy-check.ts"], unrestorable: [], committed: false)))
        #expect(failure.message.contains("It has been restored"))
        #expect(failure.message.contains("couldn't be recorded"))
        #expect(failure.remediation?.contains("Publish again") == true)
    }

    @Test func anUnrestorableFileChangesTheRemediation() throws {
        let failure = try #require(AppOwnedScriptsGate.scanFailure(
            for: .blocked(restored: [], unrestorable: ["scripts/pre-deploy-check.ts"], committed: true)))
        #expect(failure.message.contains("couldn't be restored"))
        #expect(failure.remediation?.contains("writable") == true)
        #expect(failure.detail == "Couldn't restore: scripts/pre-deploy-check.ts")
    }

    @Test func intactAndUnverifiableOutcomesProduceNoFailure() {
        #expect(AppOwnedScriptsGate.scanFailure(for: .intact) == nil)
        #expect(AppOwnedScriptsGate.scanFailure(for: .unverifiable(reason: "x")) == nil)
        #expect(AppOwnedScriptsGate.failureReason(for: .intact) == nil)
        #expect(AppOwnedScriptsGate.failureReason(for: .unverifiable(reason: "x")) == nil)
    }
}
