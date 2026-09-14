import Foundation

/// Runs every existing-site migration step — app-owned script-file sync (`scripts/`, `src/lib/`)
/// and `SecurityTxtMigrationChecker`/`Applier` — for both the windowed site-open path
/// (`SiteWindowModel.loadAndStart()`) and the headless App Intents/Shortcuts/Siri path
/// (`SiteOperations`). One implementation, one set of decisions (#1962, owner decision D1,
/// 2026-09-08):
///
/// - Every app-owned file the app knows the right answer for is applied without asking — a
///   missing file is created, a stale-but-untouched one refreshed, and one whose site copy had
///   been changed is **restored** to the app's copy (#1053: "the app advises; it does not
///   delegate the decision"). There is no keep-mine (D5) — these files are the app's build and
///   security machinery, not the owner's content. What changed is reported back in ``Report`` so
///   the caller can tell the owner in consequences ("Anglesite updated the parts of this site it
///   maintains"), never through a blocking sheet.
/// - `security.txt` is the one genuinely ambiguous item (a hand-authored file the app can't
///   positively classify) and the one decision still put to the owner: `securityTxtDecision` is
///   how the windowed path asks (a sheet), and the headless path answers Preserve.
///
/// Best-effort throughout — a failure at any step is logged and does not stop the rest, since
/// this runs ahead of a preview boot or a deploy that should still proceed whenever possible.
public enum ExistingSiteMigration {
    /// The commit message every migration commit uses.
    public static let commitMessage = "chore: migrate existing site to current template baseline"

    /// What one pass changed, for the caller's owner-facing notice and runtime refresh.
    public struct Report: Sendable, Equatable {
        /// App-owned files created or refreshed silently (`TemplateScriptsSyncAction`).
        public var refreshedPaths: [String] = []
        /// App-owned files whose site copy had been changed and were restored to the app's copy.
        public var restoredPaths: [String] = []
        /// App-owned files the app couldn't write — left as they were, retried on the next pass.
        public var failedPaths: [String] = []
        /// Non-script paths this pass touched (`.site-config`, `.gitignore`,
        /// `public/.well-known/security.txt`).
        public var otherTouchedPaths: [String] = []
        /// `true` when the owner was asked about `security.txt` (or the headless default answered
        /// for them) and chose/was defaulted to Preserve — the one item left as theirs.
        public var securityTxtPreserved = false
        /// `false` only when something was written and the git commit for it failed (a durable
        /// retry record is left in `Config/`, see `ExistingSiteMigrationCommitter`).
        public var committed = true

        /// Creates an empty report.
        public init() {}

        /// Every path written this pass — what the committer staged.
        public var touchedPaths: [String] { refreshedPaths + restoredPaths + otherTouchedPaths }
        /// `true` when nothing at all was written.
        public var isEmpty: Bool { touchedPaths.isEmpty }
    }

    /// Runs the migration. `templateDirectory` is `nil` when the app's template can't be resolved
    /// (matches the existing `TemplateRuntime` guards); script-file migration is skipped in that
    /// case, but `security.txt`/`.gitignore` migration still runs since it needs no template.
    /// `securityTxtDecision` is only invoked for `SecurityTxtMigrationPlan.needsDecision`.
    public static func run(
        sourceDirectory: URL,
        configDirectory: URL,
        templateDirectory: URL?,
        securityTxtDecision: @Sendable () async -> SecurityTxtMigrationApplier.Decision,
        source: String,
        logCenter: LogCenter = .shared,
        gitCommitBatch: @escaping @Sendable (URL, [String], String) async -> String? = InboxSubmissionCommitter.processGitCommitBatch
    ) async -> Report {
        // #745: retry a commit an interrupted prior migration didn't finish, before looking for
        // any new work — otherwise a stale pending commit could sit alongside a fresh one.
        await ExistingSiteMigrationCommitter.retryPendingCommit(
            sourceDirectory: sourceDirectory, configDirectory: configDirectory, message: commitMessage,
            gitCommitBatch: gitCommitBatch
        )

        var report = Report()

        if let templateDirectory {
            let plan = TemplateScriptsSyncChecker.check(
                sourceDirectory: sourceDirectory, configDirectory: configDirectory, templateDirectory: templateDirectory
            )
            // Applied one action at a time, not as a single batch: `applyQueued` throws on the
            // first file it can't process but leaves every earlier write (and its baseline entry)
            // intact — batching the call would silently drop those already-landed files from the
            // report, so they'd never reach the committer or its pending-commit retry record.
            for action in plan.toApply {
                do {
                    try TemplateScriptsSyncApplier.applyQueued(
                        [action], sourceDirectory: sourceDirectory, configDirectory: configDirectory,
                        templateDirectory: templateDirectory
                    )
                    report.refreshedPaths.append(action.relativePath)
                } catch {
                    report.failedPaths.append(action.relativePath)
                    await logCenter.append(
                        source: source, stream: .stderr,
                        text: "Existing-site migration couldn't refresh \(action.relativePath) (\(error)) — it will be retried on the next open."
                    )
                }
            }
            // A divergence is an app-owned file whose site copy had been changed. Restored, not
            // kept: the pre-#1962 "keep my version" path is gone (D1/D5), and leaving a changed
            // copy of e.g. the pre-deploy gate in place is exactly what #1958's deploy-time
            // verification exists to refuse.
            for divergence in plan.divergences {
                do {
                    try TemplateScriptsSyncApplier.restore(
                        divergence, sourceDirectory: sourceDirectory, configDirectory: configDirectory,
                        templateDirectory: templateDirectory
                    )
                    report.restoredPaths.append(divergence.relativePath)
                } catch {
                    report.failedPaths.append(divergence.relativePath)
                    await logCenter.append(
                        source: source, stream: .stderr,
                        text: "Existing-site migration couldn't restore \(divergence.relativePath) (\(error)) — it will be retried on the next open."
                    )
                }
            }
        }

        switch SecurityTxtMigrationChecker.check(sourceDirectory: sourceDirectory) {
        case .nothingToDo:
            break
        case .silentBackfillMode(let mode):
            report.otherTouchedPaths += SecurityTxtMigrationApplier.applyBackfill(mode: mode, sourceDirectory: sourceDirectory)
        case .silentAdopt:
            // The app already positively resolved this — marker-owned, or an unmarked file that
            // exactly matches the old generator's shape — so it applies the same way an
            // unmodified `scripts/` file silently refreshes, no decision needed.
            report.otherTouchedPaths += SecurityTxtMigrationApplier.applyDecision(.adopt, sourceDirectory: sourceDirectory)
        case .needsDecision:
            let decision = await securityTxtDecision()
            report.otherTouchedPaths += SecurityTxtMigrationApplier.applyDecision(decision, sourceDirectory: sourceDirectory)
            report.securityTxtPreserved = decision == .preserve
        }

        report.committed = await ExistingSiteMigrationCommitter.commit(
            touchedPaths: report.touchedPaths, sourceDirectory: sourceDirectory, configDirectory: configDirectory,
            message: commitMessage, gitCommitBatch: gitCommitBatch
        )
        if !report.committed {
            await logCenter.append(
                source: source, stream: .stderr,
                text: "Existing-site migration wrote files but couldn't commit them — they'll be retried on the next open."
            )
        }
        if !report.restoredPaths.isEmpty {
            await logCenter.append(
                source: source, stream: .stdout,
                text: "Existing-site migration restored \(report.restoredPaths.count) app-owned file(s) that had been changed: \(report.restoredPaths.joined(separator: ", "))."
            )
        }
        if report.securityTxtPreserved {
            await logCenter.append(
                source: source, stream: .stdout,
                text: "Existing-site migration left public/.well-known/security.txt as hand-authored (SECURITY_TXT_MODE=manual)."
            )
        }
        return report
    }

    /// ``run(sourceDirectory:configDirectory:templateDirectory:securityTxtDecision:source:logCenter:gitCommitBatch:)``
    /// for a caller with no UI to ask through — `SiteOperations`'s headless App Intents/Shortcuts/
    /// Siri path (design doc "Noninteractive flows"). App-owned files are applied exactly as in the
    /// windowed path; only the one owner-facing question (`security.txt`) defaults, to Preserve.
    @discardableResult
    public static func runNoninteractively(
        sourceDirectory: URL,
        configDirectory: URL,
        templateDirectory: URL?,
        source: String,
        logCenter: LogCenter = .shared,
        gitCommitBatch: @escaping @Sendable (URL, [String], String) async -> String? = InboxSubmissionCommitter.processGitCommitBatch
    ) async -> Report {
        await run(
            sourceDirectory: sourceDirectory, configDirectory: configDirectory, templateDirectory: templateDirectory,
            securityTxtDecision: { .preserve }, source: source, logCenter: logCenter, gitCommitBatch: gitCommitBatch
        )
    }
}
