#if canImport(Darwin)
import Testing
import Foundation
import AnglesiteTestSupport
@testable import AnglesiteCore

/// `InProcessGit` executes `BackupCommand`'s exact git vocabulary via SwiftGit2 (in-process
/// libgit2) so the deterministic backup path works under the MAS App Sandbox, where
/// `/usr/bin/git` cannot execute at all (#640/#653).
///
/// These tests run unsandboxed, so fixtures are built — and results independently verified —
/// with real subprocess `git`, while the subject under test is the in-process implementation.
/// That cross-checks "InProcessGit matches subprocess git semantics" rather than the
/// implementation against itself.
///
/// .serialized: libgit2 isn't safe for uncoordinated concurrent use (see the fork's specs).
@Suite("InProcessGit", .serialized) struct InProcessGitTests {

    // MARK: - Fixtures (subprocess git — tests are unsandboxed)

    @discardableResult
    private func git(_ arguments: [String], in dir: URL) async throws -> String {
        let result = try await ProcessSupervisor.shared.run(
            source: "test",
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["git"] + arguments,
            currentDirectoryURL: dir
        )
        guard result.exitCode == 0 else {
            Issue.record("fixture git \(arguments.joined(separator: " ")) exited \(result.exitCode): \(result.stderr)")
            throw FixtureError.gitFailed
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum FixtureError: Error { case gitFailed }

    /// Repo on branch `draft` with local identity configured and one commit of `hello.txt`.
    private func makeRepo() async throws -> URL {
        let dir = try makeTempDir(prefix: "inprocessgit-work")
        try await git(["init", "-b", "draft"], in: dir)
        try await git(["config", "user.name", "Test"], in: dir)
        try await git(["config", "user.email", "test@example.com"], in: dir)
        try "hello".write(to: dir.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "-A"], in: dir)
        try await git(["commit", "-m", "first"], in: dir)
        return dir
    }

    /// Bare repo registered as `origin` of `repo`, with the current `draft` already pushed.
    private func addPushedOrigin(to repo: URL) async throws -> URL {
        let remote = try makeTempDir(prefix: "inprocessgit-origin")
        try await git(["init", "--bare"], in: remote)
        try await git(["remote", "add", "origin", remote.absoluteString], in: repo)
        try await git(["push", "origin", "draft"], in: repo)
        return remote
    }

    // MARK: - run (introspection commands)

    @Test("rev-parse --is-inside-work-tree exits 0 in a repo, non-zero in a plain directory")
    func isInsideWorkTree() async throws {
        let repo = try await makeRepo()
        let inRepo = await InProcessGit.run(siteDirectory: repo, arguments: ["rev-parse", "--is-inside-work-tree"])
        #expect(inRepo.exitCode == 0)

        let plain = try makeTempDir(prefix: "inprocessgit-plain")
        let outside = await InProcessGit.run(siteDirectory: plain, arguments: ["rev-parse", "--is-inside-work-tree"])
        #expect(outside.exitCode != 0)
    }

    @Test("rev-parse --abbrev-ref HEAD returns the current branch name")
    func currentBranch() async throws {
        let repo = try await makeRepo()
        let result = await InProcessGit.run(siteDirectory: repo, arguments: ["rev-parse", "--abbrev-ref", "HEAD"])
        #expect(result.exitCode == 0)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "draft")
    }

    @Test("rev-parse HEAD returns the commit SHA subprocess git agrees on")
    func headSHA() async throws {
        let repo = try await makeRepo()
        let expected = try await git(["rev-parse", "HEAD"], in: repo)
        let result = await InProcessGit.run(siteDirectory: repo, arguments: ["rev-parse", "HEAD"])
        #expect(result.exitCode == 0)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == expected)
    }

    @Test("remote get-url origin returns the URL, or non-zero when unset")
    func remoteGetURL() async throws {
        let repo = try await makeRepo()
        let missing = await InProcessGit.run(siteDirectory: repo, arguments: ["remote", "get-url", "origin"])
        #expect(missing.exitCode != 0)

        try await git(["remote", "add", "origin", "https://github.com/example/site.git"], in: repo)
        let present = await InProcessGit.run(siteDirectory: repo, arguments: ["remote", "get-url", "origin"])
        #expect(present.exitCode == 0)
        #expect(present.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "https://github.com/example/site.git")
    }

    @Test("status --porcelain is empty on a clean tree, non-empty once a file changes")
    func statusPorcelain() async throws {
        let repo = try await makeRepo()
        let clean = await InProcessGit.run(siteDirectory: repo, arguments: ["status", "--porcelain"])
        #expect(clean.exitCode == 0)
        #expect(clean.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        try "changed".write(to: repo.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
        try "new".write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        let dirty = await InProcessGit.run(siteDirectory: repo, arguments: ["status", "--porcelain"])
        #expect(dirty.exitCode == 0)
        #expect(!dirty.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("status --porcelain reports real XY codes, not a fabricated ?? for everything")
    func statusPorcelainRealCodes() async throws {
        let repo = try await makeRepo()

        // Untracked (no index side at all): "??".
        try "new".write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        // Modified in the worktree, not yet staged: " M".
        try "hello v2".write(to: repo.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)

        let beforeStaging = await InProcessGit.run(siteDirectory: repo, arguments: ["status", "--porcelain"])
        let beforeLines = Set(beforeStaging.stdout.split(separator: "\n").map(String.init))
        #expect(beforeLines.contains("?? new.txt"))
        #expect(beforeLines.contains(" M hello.txt"))

        // Staged with subprocess git: the new file is "A ", the modification is "M ".
        try await git(["add", "-A"], in: repo)
        let afterStaging = await InProcessGit.run(siteDirectory: repo, arguments: ["status", "--porcelain"])
        let afterLines = Set(afterStaging.stdout.split(separator: "\n").map(String.init))
        #expect(afterLines.contains("A  new.txt"))
        #expect(afterLines.contains("M  hello.txt"))
    }

    @Test("rev-list --count origin/<branch>..HEAD counts unpushed commits, non-zero exit when the remote ref is unknown")
    func revListCount() async throws {
        let repo = try await makeRepo()

        // No origin/draft ref yet: subprocess git exits non-zero here, and BackupCommand
        // depends on that to preserve `.noChanges` (#246).
        let unknown = await InProcessGit.run(siteDirectory: repo, arguments: ["rev-list", "--count", "origin/draft..HEAD"])
        #expect(unknown.exitCode != 0)

        _ = try await addPushedOrigin(to: repo)
        let synced = await InProcessGit.run(siteDirectory: repo, arguments: ["rev-list", "--count", "origin/draft..HEAD"])
        #expect(synced.exitCode == 0)
        #expect(synced.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "0")

        try "more".write(to: repo.appendingPathComponent("more.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "-A"], in: repo)
        try await git(["commit", "-m", "unpushed"], in: repo)
        let ahead = await InProcessGit.run(siteDirectory: repo, arguments: ["rev-list", "--count", "origin/draft..HEAD"])
        #expect(ahead.exitCode == 0)
        #expect(ahead.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1")
    }

    @Test("an unsupported invocation fails loudly instead of guessing")
    func unsupportedCommand() async throws {
        let repo = try await makeRepo()
        let result = await InProcessGit.run(siteDirectory: repo, arguments: ["stash"])
        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("unsupported"))
    }

    // MARK: - stream (mutating commands)

    @Test("add -A stages additions AND deletions like subprocess git")
    func addAll() async throws {
        let repo = try await makeRepo()
        try "new".write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: repo.appendingPathComponent("hello.txt"))

        let (exit, _) = await InProcessGit.stream(siteDirectory: repo, arguments: ["add", "-A"], source: "test")
        #expect(exit == 0)

        // Verify the staged state with subprocess git: both entries staged, none unstaged.
        let status = try await git(["status", "--porcelain"], in: repo)
        #expect(status.contains("A  new.txt"))
        #expect(status.contains("D  hello.txt"))
    }

    @Test("commit -m creates the commit subprocess git can read back")
    func commit() async throws {
        let repo = try await makeRepo()
        try "more".write(to: repo.appendingPathComponent("more.txt"), atomically: true, encoding: .utf8)
        _ = await InProcessGit.stream(siteDirectory: repo, arguments: ["add", "-A"], source: "test")

        let (exit, stderr) = await InProcessGit.stream(siteDirectory: repo, arguments: ["commit", "-m", "Backup 2026-07-10T12:00:00Z"], source: "test")
        #expect(exit == 0, "commit failed: \(stderr)")
        let subject = try await git(["log", "-1", "--format=%s"], in: repo)
        #expect(subject == "Backup 2026-07-10T12:00:00Z")
    }

    @Test("push origin <branch> updates the remote and the remote-tracking ref")
    func push() async throws {
        let repo = try await makeRepo()
        let remote = try await addPushedOrigin(to: repo)

        try "more".write(to: repo.appendingPathComponent("more.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "-A"], in: repo)
        try await git(["commit", "-m", "second"], in: repo)
        let localHEAD = try await git(["rev-parse", "HEAD"], in: repo)

        let (exit, stderr) = await InProcessGit.stream(siteDirectory: repo, arguments: ["push", "origin", "draft"], source: "test")
        #expect(exit == 0, "push failed: \(stderr)")

        // The remote moved…
        let remoteHEAD = try await git(["rev-parse", "draft"], in: remote)
        #expect(remoteHEAD == localHEAD)
        // …and the local remote-tracking ref moved with it, so the next backup's
        // ahead-count check (#246) sees a synced branch rather than phantom unpushed commits.
        let trackingRef = try await git(["rev-parse", "origin/draft"], in: repo)
        #expect(trackingRef == localHEAD)
    }

    @Test("a rejected push (non-fast-forward) exits non-zero with git's reason in stderr")
    func pushRejected() async throws {
        let repo = try await makeRepo()
        let remote = try await addPushedOrigin(to: repo)

        // Move the remote ahead behind our back, so our next push can't fast-forward.
        let other = try makeTempDir(prefix: "inprocessgit-other")
        try await git(["clone", remote.absoluteString, "checkout"], in: other)
        let otherRepo = other.appendingPathComponent("checkout")
        try await git(["config", "user.name", "Other"], in: otherRepo)
        try await git(["config", "user.email", "other@example.com"], in: otherRepo)
        try await git(["checkout", "draft"], in: otherRepo)
        try "racing".write(to: otherRepo.appendingPathComponent("race.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "-A"], in: otherRepo)
        try await git(["commit", "-m", "raced"], in: otherRepo)
        try await git(["push", "origin", "draft"], in: otherRepo)

        try "mine".write(to: repo.appendingPathComponent("mine.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "-A"], in: repo)
        try await git(["commit", "-m", "mine"], in: repo)

        let (exit, stderr) = await InProcessGit.stream(siteDirectory: repo, arguments: ["push", "origin", "draft"], source: "test")
        #expect(exit != 0)
        #expect(!stderr.isEmpty)
    }

    @Test("pushing to an HTTPS remote with no stored GitHub token fails fast with an actionable message")
    func pushHTTPSWithoutToken() async throws {
        let repo = try await makeRepo()
        try await git(["remote", "add", "origin", "https://github.com/example/site.git"], in: repo)

        let (exit, stderr) = await InProcessGit.stream(
            siteDirectory: repo,
            arguments: ["push", "origin", "draft"],
            source: "test",
            tokenProvider: { nil }
        )
        #expect(exit != 0)
        #expect(stderr.contains("GitHub"))
        #expect(stderr.contains("Settings"))
    }

    @Test("a push failure's stderr never contains the raw token")
    func pushFailureNeverLeaksToken() async throws {
        let repo = try await makeRepo()
        let secretToken = "ghp_SuperSecretTokenShouldNeverLeak12345"
        // Port 1 refuses the connection immediately (nothing can bind it without root) — a real
        // push attempt through libgit2's HTTPS transport that fails fast without a DNS timeout.
        try await git(["remote", "add", "origin", "https://127.0.0.1:1/nonexistent.git"], in: repo)

        let (exit, stderr) = await InProcessGit.stream(
            siteDirectory: repo,
            arguments: ["push", "origin", "draft"],
            source: "test",
            tokenProvider: { secretToken }
        )
        #expect(exit != 0)
        #expect(!stderr.contains(secretToken), "push failure stderr must never echo the raw token: \(stderr)")
    }
}
#endif
