import Foundation

/// Commits relative paths written by this issue's migration steps (script-file sync's create/
/// refresh/divergence-resolve, and `SecurityTxtMigrationApplier`) to the site's `Source/` git
/// repo, and retries a commit that didn't happen last time (design doc "Resumability without a
/// transaction log").
///
/// `touchedPaths` is only what gets `git add`-ed, not necessarily all of what gets committed:
/// `InboxSubmissionCommitter.processGitCommitBatch` isn't strictly path-scoped on Darwin — it
/// stages the named paths but ultimately commits whatever the index has staged. If the owner's
/// `Source/` repo already has unrelated changes staged through an external tool (VS Code, a bare
/// `git add`) at the moment a site opens, those would be swept into this migration commit too.
public enum ExistingSiteMigrationCommitter {
    /// Commits `touchedPaths` **plus** whatever `Config/existing-site-migration-pending-commit.json`
    /// already lists (deduplicated and filtered to paths that actually exist on disk — a path a
    /// failed write never produced would abort the whole batch commit in
    /// `InboxSubmissionCommitter.processGitCommitBatch`, since a failed `git add` on a missing
    /// path fails the entire call) via `gitCommitBatch`. Records the merged paths as pending
    /// *before* attempting the commit and clears the record only on success, so a crash between
    /// "files written" and "commit succeeded" leaves a durable retry list.
    ///
    /// The merge matters because this record has more than one writer (site-open migration and,
    /// since #1958, the deploy-time app-owned-scripts gate): without it, a still-unretried pending
    /// path from one flow's earlier failed commit would be silently overwritten — and therefore
    /// permanently forgotten by `retryPendingCommit` — by whichever flow calls `commit` next,
    /// even though its files are still sitting uncommitted in the working tree. Folding the old
    /// record into this attempt instead means either both sets land together (success clears both
    /// as committed) or the merged record survives failure intact, so nothing already pending is
    /// ever lost to a second writer's success or failure.
    ///
    /// Returns `true` when there was nothing to commit, or the commit succeeded; `false` only when
    /// there was something to commit and it failed.
    @discardableResult
    public static func commit(
        touchedPaths: [String],
        sourceDirectory: URL,
        configDirectory: URL,
        message: String,
        gitCommitBatch: @Sendable (URL, [String], String) async -> String? = InboxSubmissionCommitter.processGitCommitBatch
    ) async -> Bool {
        let alreadyPending = ExistingSiteMigrationPendingCommit.load(from: configDirectory).pendingPaths
        let paths = Array(Set(touchedPaths).union(alreadyPending))
            .filter { FileManager.default.fileExists(atPath: sourceDirectory.appendingPathComponent($0).path) }
            .sorted()
        guard !paths.isEmpty else {
            try? ExistingSiteMigrationPendingCommit().save(to: configDirectory)
            return true
        }

        try? ExistingSiteMigrationPendingCommit(pendingPaths: paths).save(to: configDirectory)
        guard await gitCommitBatch(sourceDirectory, paths, message) != nil else { return false }
        try? ExistingSiteMigrationPendingCommit().save(to: configDirectory)
        return true
    }

    /// Retries committing whatever's left in `Config/existing-site-migration-pending-commit.json`
    /// from a prior interrupted or failed run. A no-op when the list is empty (the common case,
    /// every site-open). Callers should run this *before* checking for new migration work, so a
    /// stale pending commit doesn't sit alongside a fresh one from the same pass.
    @discardableResult
    public static func retryPendingCommit(
        sourceDirectory: URL,
        configDirectory: URL,
        message: String,
        gitCommitBatch: @Sendable (URL, [String], String) async -> String? = InboxSubmissionCommitter.processGitCommitBatch
    ) async -> Bool {
        let pending = ExistingSiteMigrationPendingCommit.load(from: configDirectory)
        guard !pending.pendingPaths.isEmpty else { return true }
        return await commit(
            touchedPaths: pending.pendingPaths,
            sourceDirectory: sourceDirectory,
            configDirectory: configDirectory,
            message: message,
            gitCommitBatch: gitCommitBatch
        )
    }
}
