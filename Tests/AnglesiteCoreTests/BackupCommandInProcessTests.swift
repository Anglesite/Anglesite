#if canImport(Darwin)
import Testing
import Foundation
import AnglesiteTestSupport
@testable import AnglesiteCore

/// End-to-end coverage for #653: `BackupCommand` with its **default** seams must run the whole
/// add → commit → push flow via `InProcessGit` (SwiftGit2/libgit2) on Darwin — under the MAS
/// App Sandbox `/usr/bin/git` can't execute at all, so the subprocess defaults these replaced
/// were dead code there. Fixtures + independent verification use subprocess git (tests run
/// unsandboxed); the subject under test is the default-wired command.
///
/// .serialized: libgit2 isn't safe for uncoordinated concurrent use.
@Suite("BackupCommand in-process defaults", .serialized) struct BackupCommandInProcessTests {

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

    @Test("default seams run the full backup — add, commit, push — in-process")
    func backupEndToEndInProcess() async throws {
        // Site repo on `draft` with identity, one commit, and a bare file:// origin.
        let site = try makeTempDir(prefix: "backup-e2e-site")
        try await git(["init", "-b", "draft"], in: site)
        try await git(["config", "user.name", "Test"], in: site)
        try await git(["config", "user.email", "test@example.com"], in: site)
        try "hello".write(to: site.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "-A"], in: site)
        try await git(["commit", "-m", "first"], in: site)
        let remote = try makeTempDir(prefix: "backup-e2e-origin")
        try await git(["init", "--bare"], in: remote)
        try await git(["remote", "add", "origin", remote.absoluteString], in: site)
        try await git(["push", "origin", "draft"], in: site)

        // A change to back up.
        try "hello v2".write(to: site.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)

        let siteID = "e2e-\(UUID().uuidString)"
        let result = await BackupCommand().backup(siteID: siteID, siteDirectory: site)

        guard case .succeeded(let sha, let branch, let remoteURL) = result else {
            Issue.record("expected .succeeded, got \(result)")
            return
        }
        #expect(branch == "draft")
        #expect(remoteURL == remote.absoluteString)

        // Independent verification: subprocess git agrees the commit landed on the remote.
        let remoteHEAD = try await git(["rev-parse", "draft"], in: remote)
        #expect(remoteHEAD == sha)

        // And the run went through the in-process path: its step lines — not subprocess git
        // output — are what landed in LogCenter under this backup's source.
        let lines = await LogCenter.shared.snapshot()
            .filter { $0.source == "backup:\(siteID)" }
            .map(\.text)
        #expect(lines.contains { $0.contains("staged all changes (add -A)") })
        #expect(lines.contains { $0.contains("push complete") })
    }

    @Test("default seams surface a clean tree with no unpushed commits as .noChanges")
    func backupNoChangesInProcess() async throws {
        let site = try makeTempDir(prefix: "backup-e2e-site")
        try await git(["init", "-b", "draft"], in: site)
        try await git(["config", "user.name", "Test"], in: site)
        try await git(["config", "user.email", "test@example.com"], in: site)
        try "hello".write(to: site.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "-A"], in: site)
        try await git(["commit", "-m", "first"], in: site)
        let remote = try makeTempDir(prefix: "backup-e2e-origin")
        try await git(["init", "--bare"], in: remote)
        try await git(["remote", "add", "origin", remote.absoluteString], in: site)
        try await git(["push", "origin", "draft"], in: site)

        let result = await BackupCommand().backup(siteID: "e2e-clean", siteDirectory: site)
        #expect(result == .noChanges)
    }

    @Test("default seams push a stranded commit on a clean tree (#246)")
    func backupPushesStrandedCommit() async throws {
        let site = try makeTempDir(prefix: "backup-e2e-site")
        try await git(["init", "-b", "draft"], in: site)
        try await git(["config", "user.name", "Test"], in: site)
        try await git(["config", "user.email", "test@example.com"], in: site)
        try "hello".write(to: site.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "-A"], in: site)
        try await git(["commit", "-m", "first"], in: site)
        let remote = try makeTempDir(prefix: "backup-e2e-origin")
        try await git(["init", "--bare"], in: remote)
        try await git(["remote", "add", "origin", remote.absoluteString], in: site)
        try await git(["push", "origin", "draft"], in: site)

        // A committed-but-never-pushed change: clean tree, HEAD ahead of origin/draft.
        try "stranded".write(to: site.appendingPathComponent("stranded.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "-A"], in: site)
        try await git(["commit", "-m", "stranded"], in: site)
        let localHEAD = try await git(["rev-parse", "HEAD"], in: site)

        let result = await BackupCommand().backup(siteID: "e2e-stranded", siteDirectory: site)

        guard case .succeeded(let sha, _, _) = result else {
            Issue.record("expected .succeeded, got \(result)")
            return
        }
        #expect(sha == localHEAD)
        let remoteHEAD = try await git(["rev-parse", "draft"], in: remote)
        #expect(remoteHEAD == localHEAD)
    }
}
#endif
