#if canImport(Darwin)
import Testing
import Foundation
import AnglesiteSiteModel
import AnglesiteTestSupport
@testable import AnglesiteCore

/// Proves the migrated gitfile isn't just a libgit2-specific trick: real system `git` must follow
/// it too, and a real `git clone` of the migrated `Source/` must succeed — the acceptance bar from
/// issue #877 ("git status/git log in Source/ work via system git, git clone … succeeds").
@Suite("RepoRelocator system-git interop")
struct RepoRelocatorInteropTests {
    static var gitAvailable: Bool { FileManager.default.isExecutableFile(atPath: "/usr/bin/git") }

    @discardableResult
    private func git(_ arguments: [String], in dir: URL) async throws -> ProcessSupervisor.RunResult {
        try await ProcessSupervisor.shared.run(
            source: "test",
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["git"] + arguments,
            currentDirectoryURL: dir
        )
    }

    @Test(
        "system git status/log/clone all work against a migrated Source/",
        .enabled(if: RepoRelocatorInteropTests.gitAvailable, "requires /usr/bin/git")
    )
    func systemGitFollowsTheGitfile() async throws {
        let root = try makeTempDir(prefix: "repo-relocator-interop")
        let pkgURL = root.appendingPathComponent("Test.anglesite", isDirectory: true)
        let (pkg, _) = try AnglesitePackage.createSkeleton(at: pkgURL, displayName: "Test")

        try await git(["init"], in: pkg.sourceURL)
        try await git(["config", "user.email", "t@t.io"], in: pkg.sourceURL)
        try await git(["config", "user.name", "t"], in: pkg.sourceURL)
        try "seed".write(to: pkg.sourceURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await git(["add", "-A"], in: pkg.sourceURL)
        try await git(["commit", "-m", "seed"], in: pkg.sourceURL)

        #expect(try RepoRelocator.migrate(package: pkg) == .migrated)

        let status = try await git(["status", "--porcelain"], in: pkg.sourceURL)
        #expect(status.exitCode == 0)

        let log = try await git(["log", "--oneline"], in: pkg.sourceURL)
        #expect(log.exitCode == 0)
        #expect(log.stdout.contains("seed"))

        let cloneDest = root.appendingPathComponent("cloned", isDirectory: true)
        let clone = try await git(["clone", pkg.sourceURL.path, cloneDest.path], in: root)
        #expect(clone.exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: cloneDest.appendingPathComponent("README.md").path))
        // The clone must be a fully independent, real repo — not another gitfile pointing back
        // into the original package.
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: cloneDest.appendingPathComponent(".git").path, isDirectory: &isDir) && isDir.boolValue)
    }
}
#endif
