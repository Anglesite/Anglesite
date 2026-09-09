import Testing
@testable import AnglesiteCore

@Suite("OwnerPhrasing")
struct OwnerPhrasingTests {
    // MARK: Sync

    @Test("sync reasons map to owner-facing kinds", arguments: [
        ("waiting for iCloud to finish syncing this site's history before pushing.", OwnerPhrasing.SyncKind.waitingForICloud),
        ("this site has no commits yet — nothing to sync.", .nothingToSync),
        ("the working tree has uncommitted changes — commit them before syncing.", .unsavedEdits),
        ("couldn't snapshot local changes before syncing: index locked", .unsavedEdits),
        ("the repo is in a detached-HEAD state — check out a branch before syncing.", .historyInUnexpectedState),
        ("push paused for an unresolved conflict on main", .couldNotCombineChanges),
        ("couldn't merge sync/main into main: conflicts in 3 paths", .couldNotCombineChanges),
        ("couldn't fast-forward main to sync/main.", .couldNotCombineChanges),
        ("internal error: reconciliation found no changes despite a detected divergence", .couldNotCombineChanges),
        ("merged main locally but couldn't push the result: disk full", .cloudWriteFailed),
        ("the artifact's packfile is corrupt: missing the packfile's \"PACK\" signature", .cloudCopyUnreadable),
        ("the file isn't a git bundle (bad signature line: # v9)", .cloudCopyUnreadable),
        ("the freshly written sync artifact failed verification: truncated header", .cloudCopyUnreadable),
        ("couldn't create the sync directory: permission denied", .cloudWriteFailed),
        ("couldn't write the sync artifact into the package: disk full", .cloudWriteFailed),
        ("couldn't fetch the synced history: timeout", .cloudReadFailed),
        ("no synced history found yet at source.bundle.", .cloudReadFailed),
        ("something entirely new happened", .unknown),
    ])
    func syncKinds(reason: String, expected: OwnerPhrasing.SyncKind) {
        #expect(OwnerPhrasing.syncKind(for: reason) == expected)
    }

    // MARK: Backup

    @Test("backup reasons map to owner-facing kinds", arguments: [
        ("this site isn't a git repository — run `git init` and add an `origin` remote, or use /anglesite:backup in chat to set it up.", OwnerPhrasing.BackupKind.notConnected),
        ("no `origin` remote configured — run /anglesite:backup in chat to set one up.", .notConnected),
        ("the `origin` remote is configured but empty.", .notConnected),
        ("backup canceled", .canceled),
        ("`git push` failed (exit 128): fatal: unable to access 'https://github.com/me/site.git': Could not resolve host", .uploadFailed),
        ("`git push` failed (exit 1): error: failed to push some refs to 'origin'", .uploadFailed),
        ("`git commit` failed (exit 128): Author identity unknown", .recordFailed),
        ("couldn't spawn `git add`: launch path not accessible", .recordFailed),
        ("couldn't read current branch (`git rev-parse` exit 128)", .historyUnreadable),
        ("`git status` exited 128", .historyUnreadable),
        ("couldn't read commit SHA: some error", .historyUnreadable),
        ("couldn't check the git repository: boom", .historyUnreadable),
        ("mystery", .unknown),
    ])
    func backupKinds(reason: String, expected: OwnerPhrasing.BackupKind) {
        #expect(OwnerPhrasing.backupKind(for: reason) == expected)
    }

    // MARK: Publish / audit

    @Test("deploy and audit reasons map to owner-facing kinds", arguments: [
        ("npm run build failed (exit 1)", OwnerPhrasing.OperationKind.buildFailed),
        ("build failed", .buildFailed),
        ("build was terminated", .buildInterrupted),
        ("wrangler exited with code 1", .publishRejected),
        ("wrangler exited successfully (code 0), but no deployed URL could be found in its output", .publishRejected),
        ("wrangler was terminated", .publishInterrupted),
        ("pre-deploy scan could not run: node missing", .safetyCheckUnavailable),
        ("couldn't read Cloudflare API token: keychain locked", .cloudflareSignInUnreadable),
        ("audit canceled", .canceled),
        ("Worker name \"site\" is already in use on your Cloudflare account — rename it in the app and publish again.", .unknown),
    ])
    func operationKinds(reason: String, expected: OwnerPhrasing.OperationKind) {
        #expect(OwnerPhrasing.operationKind(for: reason) == expected)
    }

    // MARK: Detail

    @Test("detail appends the exit code once")
    func detailAppendsExitCode() {
        #expect(OwnerPhrasing.detail(reason: "build failed", exitCode: 2) == "build failed (exit code 2)")
        #expect(OwnerPhrasing.detail(reason: "build failed", exitCode: nil) == "build failed")
    }

    @Test("detail doesn't duplicate an exit code the reason already spells out")
    func detailDoesNotDuplicateExitCode() {
        #expect(OwnerPhrasing.detail(reason: "npm run build failed (exit 1)", exitCode: 1) == "npm run build failed (exit 1)")
        #expect(OwnerPhrasing.detail(reason: "wrangler exited with code 1", exitCode: 1) == "wrangler exited with code 1")
    }

    @Test("detail with an empty reason is just the exit code")
    func detailEmptyReason() {
        #expect(OwnerPhrasing.detail(reason: "  ", exitCode: 3) == "exit code 3")
    }

    // MARK: Backup destination

    @Test("backup destination label names the host the owner signed in to", arguments: [
        ("https://github.com/me/site.git", "GitHub"),
        ("https://GitHub.com/me/site", "GitHub"),
        ("git@github.com:me/site.git", "GitHub"),
        ("https://gitlab.com/me/site.git", "GitLab"),
        ("https://codeberg.org/me/site.git", "Codeberg"),
        ("https://git.example.net/me/site.git", "git.example.net"),
        ("/Volumes/Backup/site.git", "/Volumes/Backup/site.git"),
        ("", ""),
    ])
    func backupDestinationLabel(remote: String, expected: String) {
        #expect(OwnerPhrasing.backupDestinationLabel(remote: remote) == expected)
    }
}
