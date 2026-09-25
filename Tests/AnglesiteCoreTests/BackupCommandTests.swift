import Testing
import Foundation
@testable import AnglesiteCore

/// Tests for `BackupCommand` — the deterministic add/commit/push path that replaces
/// the chat-routed `/anglesite:backup` for one-click backups (#85).
///
/// Style matches `DeployCommandTests`: real `ProcessSupervisor` + `LogCenter` instances,
/// shell-fixture closures injected via the `runner`/`streamer` seams. The `clock` seam
/// makes commit-message timestamps deterministic.
struct BackupCommandTests {

    private let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    private let fixedClock: @Sendable () -> Date = {
        Date(timeIntervalSince1970: 1_780_000_000)  // 2026-06-08 ~14:13 UTC
    }

    // MARK: Builder

    private func makeCommand(
        runner: @escaping BackupCommand.GitRunner,
        streamer: @escaping BackupCommand.GitStreamer = { _, _, _ in (0, "") },
        gate: SourcePublishGate = .passing
    ) -> BackupCommand {
        BackupCommand(runner: runner, streamer: streamer, clock: fixedClock, gate: gate)
    }

    /// Fake runner that dispatches on the first git argument so each test can script multiple
    /// subcommands (`status`, `rev-parse`, `remote`) in one closure without nested switches.
    ///
    /// Note: the `"rev-parse"` entry answers BOTH `rev-parse --is-inside-work-tree` (step 0,
    /// where only `exitCode == 0` matters — it means "is a repo") and `rev-parse --abbrev-ref
    /// HEAD` (step 1, whose stdout is the branch name). Tests that want to reach the branch/
    /// remote/status steps therefore give `"rev-parse"` an exit-0 entry.
    private func runner(
        _ table: [String: (stdout: String, exitCode: Int32)]
    ) -> BackupCommand.GitRunner {
        return { _, args in
            let key = args.first ?? ""
            guard let entry = table[key] else {
                return ProcessSupervisor.RunResult(stdout: "", stderr: "unmocked git \(args.joined(separator: " "))", exitCode: 1)
            }
            return ProcessSupervisor.RunResult(stdout: entry.stdout, stderr: "", exitCode: entry.exitCode)
        }
    }

    // MARK: Non-repo refusal

    @Test("Refuses outside a git repository with a clear, actionable message")
    func refusesOutsideGitRepo() async {
        // `git rev-parse --is-inside-work-tree` exits non-zero on a plain directory. The
        // command must stop here — before branch/remote/status — with a git-init remediation.
        let cmd = makeCommand(runner: { _, args in
            if args.contains("--is-inside-work-tree") {
                return .init(stdout: "", stderr: "fatal: not a git repository", exitCode: 128)
            }
            Issue.record("no git command should run after the work-tree check fails: \(args)")
            return .init(stdout: "", stderr: "unexpected", exitCode: 1)
        })
        let result = await cmd.backup(siteID: "site", siteDirectory: tmpDir)
        guard case .failed(let reason, let exit) = result else {
            Issue.record("expected .failed, got \(result)")
            return
        }
        #expect(reason.lowercased().contains("git repository"), "reason should name the missing repo: \(reason)")
        #expect(exit == nil, "non-repo refusal is pre-spawn — no exit code")
    }

    // MARK: noChanges

    @Test("Returns .noChanges when the tree is clean and in sync with origin")
    func returnsNoChangesWhenCleanAndInSync() async {
        // Clean tree (empty status) and HEAD not ahead of origin/<branch> (rev-list count 0)
        // → genuinely nothing to back up.
        let cmd = makeCommand(runner: runner([
            "status": ("", 0),
            "rev-parse": ("draft\n", 0),
            "remote": ("git@github.com:owner/site.git\n", 0),
            "rev-list": ("0\n", 0)
        ]))
        let result = await cmd.backup(siteID: "site", siteDirectory: tmpDir)
        #expect(result == .noChanges)
    }

    @Test("Returns .noChanges when ahead-count can't be determined (no remote-tracking ref)")
    func returnsNoChangesWhenAheadCountUnknown() async {
        // A branch that was never pushed has no `origin/<branch>` ref, so
        // `git rev-list --count origin/<branch>..HEAD` exits non-zero. With a clean tree we
        // preserve the historical .noChanges rather than erroring or pushing blindly.
        let pushed = LockedSourceList()
        let cmd = makeCommand(
            runner: runner([
                "status": ("", 0),
                "rev-parse": ("draft\n", 0),
                "remote": ("git@github.com:owner/site.git\n", 0),
                "rev-list": ("", 128)  // fatal: ambiguous argument 'origin/draft..HEAD'
            ]),
            streamer: { _, args, _ in pushed.add(args.first ?? ""); return (0, "") }
        )
        let result = await cmd.backup(siteID: "site", siteDirectory: tmpDir)
        #expect(result == .noChanges)
        #expect(pushed.snapshot().isEmpty, "must not push when ahead-count is unknown")
    }

    // MARK: Clean-but-ahead push (#246)

    @Test("Pushes the pending commit when the tree is clean but ahead of origin")
    func pushesPendingCommitWhenCleanButAhead() async {
        // The cancelled-after-commit case: a prior backup committed but never pushed, so the
        // tree is clean yet HEAD is ahead of origin/<branch>. Backup must push the pending
        // commit and report .succeeded — not mask it behind .noChanges.
        let pushed = LockedSourceList()
        let runner: BackupCommand.GitRunner = { _, args in
            switch args.first {
            case "status":   return .init(stdout: "", stderr: "", exitCode: 0)  // clean tree
            case "remote":   return .init(stdout: "git@github.com:owner/site.git\n", stderr: "", exitCode: 0)
            case "rev-list": return .init(stdout: "1\n", stderr: "", exitCode: 0) // 1 commit ahead
            case "rev-parse":
                if args.contains("--abbrev-ref") {
                    return .init(stdout: "draft\n", stderr: "", exitCode: 0)
                }
                return .init(stdout: "abc1234deadbeef0000000000000000000000000\n", stderr: "", exitCode: 0)
            default:
                return .init(stdout: "", stderr: "unmocked", exitCode: 1)
            }
        }
        let cmd = makeCommand(runner: runner, streamer: { _, args, _ in pushed.add(args.first ?? ""); return (0, "") })

        let result = await cmd.backup(siteID: "site", siteDirectory: tmpDir)
        guard case .succeeded(let sha, let branch, let remote) = result else {
            Issue.record("expected .succeeded for the unpushed commit, got \(result)")
            return
        }
        #expect(sha == "abc1234deadbeef0000000000000000000000000")
        #expect(branch == "draft")
        #expect(remote == "git@github.com:owner/site.git")
        // Only a push runs — no add/commit, since there's nothing new to commit.
        #expect(pushed.snapshot() == ["push"], "expected a single push of the pending commit, got \(pushed.snapshot())")
    }

    @Test("Cancelling during the clean-but-ahead path prevents the pending push")
    func cancelPreventsPendingPush() async {
        // Park at the first git call until the test has captured the task handle, so the cancel
        // lands deterministically before the push guard — no reliance on scheduling races.
        let pushed = LockedSourceList()
        let holder = CancelHolder()
        let runner: BackupCommand.GitRunner = { _, args in
            switch args.first {
            case "status":   return .init(stdout: "", stderr: "", exitCode: 0)  // clean tree
            case "remote":   return .init(stdout: "git@github.com:owner/site.git\n", stderr: "", exitCode: 0)
            case "rev-list":
                await holder.cancelSelf()  // task is held by now → cancels before the push guard
                return .init(stdout: "1\n", stderr: "", exitCode: 0)
            case "rev-parse":
                if args.contains("--is-inside-work-tree") {
                    await holder.awaitHeld()  // step 0 — park until the handle is stored
                    return .init(stdout: "true\n", stderr: "", exitCode: 0)
                }
                if args.contains("--abbrev-ref") {
                    return .init(stdout: "draft\n", stderr: "", exitCode: 0)
                }
                return .init(stdout: "abc1234\n", stderr: "", exitCode: 0)
            default:
                return .init(stdout: "", stderr: "unmocked", exitCode: 1)
            }
        }
        let cmd = makeCommand(runner: runner, streamer: { _, args, _ in pushed.add(args.first ?? ""); return (0, "") })

        let task = Task { await cmd.backup(siteID: "site", siteDirectory: tmpDir) }
        await holder.hold(task)
        let result = await task.value

        guard case .failed(let reason, let exit) = result else {
            Issue.record("expected .failed on cancellation, got \(result)")
            return
        }
        #expect(reason.contains("canceled"), "reason should name the cancellation: \(reason)")
        #expect(exit == nil, "cancellation is pre-spawn for the push — no exit code")
        #expect(pushed.snapshot().isEmpty, "must not push the pending commit once cancelled, got \(pushed.snapshot())")
    }

    // MARK: Main-branch refusal

    @Test("Refuses when current branch is main")
    func refusesOnMain() async {
        let cmd = makeCommand(runner: runner([
            "status": (" M src/pages/index.astro\n", 0),
            "rev-parse": ("main\n", 0),
            "remote": ("git@github.com:owner/site.git\n", 0)
        ]))
        let result = await cmd.backup(siteID: "site", siteDirectory: tmpDir)
        guard case .failed(let reason, let exit) = result else {
            Issue.record("expected .failed, got \(result)")
            return
        }
        #expect(reason.contains("main"), "reason should explain the main-branch rule: \(reason)")
        #expect(exit == nil, "main-branch refusal is pre-spawn — no exit code")
    }

    // MARK: Missing-remote refusal

    @Test("Refuses when origin remote is not configured")
    func refusesWhenNoRemote() async {
        // git emits an empty stdout and non-zero exit when the remote doesn't exist.
        let cmd = makeCommand(runner: runner([
            "status": (" M src/pages/index.astro\n", 0),
            "rev-parse": ("draft\n", 0),
            "remote": ("", 2)
        ]))
        let result = await cmd.backup(siteID: "site", siteDirectory: tmpDir)
        guard case .failed(let reason, _) = result else {
            Issue.record("expected .failed, got \(result)")
            return
        }
        #expect(reason.lowercased().contains("remote"), "reason should mention the missing remote: \(reason)")
    }

    // MARK: Happy path

    @Test("Succeeds and returns commit SHA + branch + remote")
    func succeedsAndReturnsStructuredResult() async {
        // status/rev-parse/remote answer up-front; after commit, rev-parse HEAD returns the SHA.
        // The dispatcher returns whatever's at the keyed first arg, so HEAD is dispatched via "rev-parse"
        // — that's fine because we run branch-detection (rev-parse --abbrev-ref HEAD) before the
        // commit, and HEAD-SHA (rev-parse HEAD) after. The fake distinguishes them by args length.
        let runner: BackupCommand.GitRunner = { _, args in
            switch args.first {
            case "status":   return .init(stdout: " M src/pages/index.astro\n", stderr: "", exitCode: 0)
            case "remote":   return .init(stdout: "git@github.com:owner/site.git\n", stderr: "", exitCode: 0)
            case "rev-parse":
                // `git rev-parse --abbrev-ref HEAD` for branch detection, `git rev-parse HEAD` for SHA.
                if args.contains("--abbrev-ref") {
                    return .init(stdout: "draft\n", stderr: "", exitCode: 0)
                }
                return .init(stdout: "abc1234deadbeef0000000000000000000000000\n", stderr: "", exitCode: 0)
            default:
                return .init(stdout: "", stderr: "unmocked", exitCode: 1)
            }
        }
        let cmd = makeCommand(runner: runner, streamer: { _, _, _ in (0, "") })

        let result = await cmd.backup(siteID: "site", siteDirectory: tmpDir)
        guard case .succeeded(let sha, let branch, let remote) = result else {
            Issue.record("expected .succeeded, got \(result)")
            return
        }
        #expect(sha == "abc1234deadbeef0000000000000000000000000")
        #expect(branch == "draft")
        #expect(remote == "git@github.com:owner/site.git")
    }

    // MARK: Push failure

    @Test("Surfaces push failure with exit code and git's stderr")
    func surfacesPushFailureWithExitCode() async {
        let runner: BackupCommand.GitRunner = { _, args in
            switch args.first {
            case "status":   return .init(stdout: " M src/pages/index.astro\n", stderr: "", exitCode: 0)
            case "remote":   return .init(stdout: "git@github.com:owner/site.git\n", stderr: "", exitCode: 0)
            case "rev-parse":
                if args.contains("--abbrev-ref") {
                    return .init(stdout: "draft\n", stderr: "", exitCode: 0)
                }
                return .init(stdout: "abc1234\n", stderr: "", exitCode: 0)
            default:
                return .init(stdout: "", stderr: "unmocked", exitCode: 1)
            }
        }
        let streamer: BackupCommand.GitStreamer = { _, args, _ in
            // Fail only on `git push` (with a realistic rejection on stderr); add/commit succeed.
            args.first == "push"
                ? (128, "! [rejected] draft -> draft (fetch first)\nerror: failed to push some refs")
                : (0, "")
        }
        let cmd = makeCommand(runner: runner, streamer: streamer)

        let result = await cmd.backup(siteID: "site", siteDirectory: tmpDir)
        guard case .failed(let reason, let exit) = result else {
            Issue.record("expected .failed, got \(result)")
            return
        }
        #expect(reason.lowercased().contains("push"), "reason should mention which step failed: \(reason)")
        #expect(reason.contains("rejected"), "reason should embed git's stderr so the user sees why: \(reason)")
        #expect(exit == 128)
    }

    // MARK: Commit message format

    @Test("Commit message uses ISO-8601 timestamp from injected clock")
    func commitMessageUsesISO8601Timestamp() async {
        // Capture the commit message by intercepting the streamer's args.
        let captured = LockedCapture()
        let runner: BackupCommand.GitRunner = { _, args in
            switch args.first {
            case "status":   return .init(stdout: " M file\n", stderr: "", exitCode: 0)
            case "remote":   return .init(stdout: "origin-url\n", stderr: "", exitCode: 0)
            case "rev-parse":
                if args.contains("--abbrev-ref") {
                    return .init(stdout: "draft\n", stderr: "", exitCode: 0)
                }
                return .init(stdout: "abc\n", stderr: "", exitCode: 0)
            default:
                return .init(stdout: "", stderr: "unmocked", exitCode: 1)
            }
        }
        let streamer: BackupCommand.GitStreamer = { _, args, _ in
            if args.first == "commit" {
                captured.set(args)
            }
            return (0, "")
        }
        let cmd = makeCommand(runner: runner, streamer: streamer)

        _ = await cmd.backup(siteID: "site", siteDirectory: tmpDir)
        let committed = captured.get()
        // `git commit -m "Backup <ISO timestamp>"` — find the message after -m.
        guard let mIdx = committed.firstIndex(of: "-m"), mIdx + 1 < committed.count else {
            Issue.record("expected -m flag in commit args, got \(committed)")
            return
        }
        let message = committed[mIdx + 1]
        #expect(message.hasPrefix("Backup "), "message should start with 'Backup ': \(message)")
        // The fixed clock is 2026-06-08T~14:13Z; check the year/month land in the message.
        #expect(message.contains("2026"), "message should contain ISO year: \(message)")
    }

    // MARK: Source tagging

    @Test("Streams every action step under backup:<siteID>")
    func streamsActionsUnderBackupSiteIDSource() async {
        let sources = LockedSourceList()
        let runner: BackupCommand.GitRunner = { _, args in
            switch args.first {
            case "status":   return .init(stdout: " M file\n", stderr: "", exitCode: 0)
            case "remote":   return .init(stdout: "origin-url\n", stderr: "", exitCode: 0)
            case "rev-parse":
                if args.contains("--abbrev-ref") {
                    return .init(stdout: "draft\n", stderr: "", exitCode: 0)
                }
                return .init(stdout: "abc\n", stderr: "", exitCode: 0)
            default:
                return .init(stdout: "", stderr: "unmocked", exitCode: 1)
            }
        }
        let streamer: BackupCommand.GitStreamer = { _, _, source in
            sources.add(source)
            return (0, "")
        }
        let cmd = makeCommand(runner: runner, streamer: streamer)
        _ = await cmd.backup(siteID: "mysite", siteDirectory: tmpDir)

        let seen = sources.snapshot()
        #expect(seen.allSatisfy { $0 == "backup:mysite" }, "every streamed step must carry the site-specific source tag, got \(seen)")
        #expect(seen.count == 3, "expected add + commit + push, got \(seen.count): \(seen)")
    }

    // MARK: #1959 — the source push gate

    private final class Pushed: @unchecked Sendable {
        private let lock = NSLock()
        private var pushed = false
        func mark() { lock.lock(); pushed = true; lock.unlock() }
        var didPush: Bool { lock.lock(); defer { lock.unlock() }; return pushed }
    }

    @Test("A blocked source scan refuses the push after the commit, with the scan's findings")
    func blockedGateRefusesPush() async {
        let failure = PreDeployCheck.ScanFailure(category: .exposedToken, message: "Possible AWS key exposed", file: "src/content/x.md")
        let pushed = Pushed()
        let cmd = makeCommand(
            runner: runner([
                "rev-parse": ("draft\n", 0),
                "remote": ("git@example.com:me/site.git\n", 0),
                "status": (" M index.md\n", 0),
            ]),
            streamer: { _, args, _ in
                if args.first == "push" { pushed.mark() }
                return (0, "")
            },
            gate: .canned(.blocked(failures: [failure], warnings: []))
        )
        // `rev-parse HEAD` shares the "rev-parse" entry above; its stdout is treated as a SHA.
        let result = await cmd.backup(siteID: "site", siteDirectory: tmpDir)
        #expect(result == .blocked(failures: [failure], warnings: []))
        #expect(!pushed.didPush, "a refused backup must never push")
    }

    @Test("A gate that cannot run fails the backup closed before the push")
    func gateErrorFailsClosed() async {
        let pushed = Pushed()
        let cmd = makeCommand(
            runner: runner([
                "rev-parse": ("draft\n", 0),
                "remote": ("git@example.com:me/site.git\n", 0),
                "status": (" M index.md\n", 0),
            ]),
            streamer: { _, args, _ in
                if args.first == "push" { pushed.mark() }
                return (0, "")
            },
            gate: .canned(.error(reason: "no runtime"))
        )
        let result = await cmd.backup(siteID: "site", siteDirectory: tmpDir)
        guard case .failed(let reason, _) = result else { Issue.record("expected .failed, got \(result)"); return }
        #expect(reason.contains("couldn't run its safety check"))
        #expect(!pushed.didPush)
    }

    @Test("The ahead-of-origin recovery push is gated too")
    func aheadOfOriginRecoveryIsGated() async {
        let failure = PreDeployCheck.ScanFailure(category: .exposedToken, message: "leak")
        let pushed = Pushed()
        let cmd = makeCommand(
            runner: runner([
                "rev-parse": ("draft\n", 0),
                "remote": ("git@example.com:me/site.git\n", 0),
                "status": ("", 0),
                "rev-list": ("1\n", 0),
            ]),
            streamer: { _, args, _ in
                if args.first == "push" { pushed.mark() }
                return (0, "")
            },
            gate: .canned(.blocked(failures: [failure], warnings: []))
        )
        let result = await cmd.backup(siteID: "site", siteDirectory: tmpDir)
        #expect(result == .blocked(failures: [failure], warnings: []))
        #expect(!pushed.didPush)
    }

}

// MARK: - Sendable capture helpers
//
// Swift Testing closures are @Sendable so plain `var` doesn't work for cross-closure capture.
// These thin wrappers use NSLock for the small mutation the tests need.

private final class LockedCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String] = []
    func set(_ v: [String]) { lock.lock(); value = v; lock.unlock() }
    func get() -> [String] { lock.lock(); defer { lock.unlock() }; return value }
}

private final class LockedSourceList: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ v: String) { lock.lock(); values.append(v); lock.unlock() }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return values }
}

/// Lets a test cancel the very `backup()` task it's awaiting, deterministically: the runner
/// parks at the first git call via `awaitHeld()` until the test stores the handle with `hold(_:)`,
/// then a later runner step calls `cancelSelf()` to cancel before the push guard is reached.
private actor CancelHolder {
    private var task: Task<BackupCommand.Result, Never>?
    private var held = false
    private var waiter: CheckedContinuation<Void, Never>?

    func hold(_ t: Task<BackupCommand.Result, Never>) {
        task = t
        held = true
        waiter?.resume()
        waiter = nil
    }

    func awaitHeld() async {
        if held { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func cancelSelf() { task?.cancel() }
}
