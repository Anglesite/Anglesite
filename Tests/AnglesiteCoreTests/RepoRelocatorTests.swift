#if canImport(Darwin)
import Testing
import Foundation
import AnglesiteSiteModel
import AnglesiteTestSupport
import SwiftGit2
@testable import AnglesiteCore

/// `RepoRelocator` moves an embedded `Source/.git` directory to `Config/repo.nosync/` and
/// replaces it with a relative gitfile (#875/#877). Fixtures use real subprocess `git` (tests run
/// unsandboxed) to build embedded repos; the subject under test is `RepoRelocator` itself, and
/// `Repository.at` (SwiftGit2/libgit2) verifies the resulting gitfile actually resolves — matching
/// the cross-check style established by `InProcessGitTests`.
///
/// .serialized: libgit2 isn't safe for uncoordinated concurrent use (see the fork's specs).
@Suite("RepoRelocator", .serialized) struct RepoRelocatorTests {

    // MARK: - Fixtures

    private func makePackageSkeleton() throws -> AnglesitePackage {
        let root = try makeTempDir(prefix: "repo-relocator")
        let pkgURL = root.appendingPathComponent("Test.anglesite", isDirectory: true)
        let (pkg, _) = try AnglesitePackage.createSkeleton(at: pkgURL, displayName: "Test")
        return pkg
    }

    @discardableResult
    private func git(_ arguments: [String], in dir: URL) async throws -> ProcessSupervisor.RunResult {
        let result = try await ProcessSupervisor.shared.run(
            source: "test",
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["git"] + arguments,
            currentDirectoryURL: dir
        )
        #expect(result.exitCode == 0, "fixture git \(arguments.joined(separator: " ")) exited \(result.exitCode): \(result.stderr)")
        return result
    }

    /// A package whose `Source/` is a real, embedded (unmigrated) git repo with one commit.
    private func makeEmbeddedRepoPackage() async throws -> AnglesitePackage {
        let pkg = try makePackageSkeleton()
        try await git(["init"], in: pkg.sourceURL)
        try await git(["config", "user.email", "t@t.io"], in: pkg.sourceURL)
        try await git(["config", "user.name", "t"], in: pkg.sourceURL)
        try "seed".write(to: pkg.sourceURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await git(["add", "-A"], in: pkg.sourceURL)
        try await git(["commit", "-m", "seed"], in: pkg.sourceURL)
        return pkg
    }

    // MARK: - migrate: embedded -> split

    @Test("migrates an embedded Source/.git directory to Config/repo.nosync and writes the gitfile")
    func migratesEmbeddedRepo() async throws {
        let pkg = try await makeEmbeddedRepoPackage()
        let fm = FileManager.default
        let gitPath = pkg.sourceURL.appendingPathComponent(".git")

        let result = try RepoRelocator.migrate(package: pkg)

        #expect(result == .migrated)
        var isDir: ObjCBool = false
        #expect(fm.fileExists(atPath: gitPath.path, isDirectory: &isDir) && !isDir.boolValue, "Source/.git is now a gitfile, not a directory")
        let gitfile = try String(contentsOf: gitPath, encoding: .utf8)
        #expect(gitfile == "gitdir: ../Config/repo.nosync\n")
        #expect(fm.fileExists(atPath: pkg.liveRepositoryURL.appendingPathComponent("HEAD").path), "the real repo now lives in Config/repo.nosync")

        // libgit2 must resolve the gitfile transparently.
        SwiftGit2Bootstrap.ensureInitialized
        guard case .success(let repo) = Repository.at(pkg.sourceURL) else {
            Issue.record("Repository.at(sourceURL) failed to follow the migrated gitfile")
            return
        }
        #expect((try? repo.HEAD().get())?.oid != nil)
    }

    @Test("migrate is idempotent: a second call on an already-split package is a no-op")
    func idempotentOnAlreadySplit() async throws {
        let pkg = try await makeEmbeddedRepoPackage()
        #expect(try RepoRelocator.migrate(package: pkg) == .migrated)

        let gitPath = pkg.sourceURL.appendingPathComponent(".git")
        let contentsBefore = try String(contentsOf: gitPath, encoding: .utf8)

        let second = try RepoRelocator.migrate(package: pkg)

        #expect(second == .alreadySplit)
        #expect(try String(contentsOf: gitPath, encoding: .utf8) == contentsBefore)
    }

    @Test("migrate heals an interrupted migration: repo already moved, gitfile never written")
    func healsInterruptedMigration() async throws {
        let pkg = try await makeEmbeddedRepoPackage()
        let fm = FileManager.default
        let gitPath = pkg.sourceURL.appendingPathComponent(".git")

        // Simulate a crash between the directory move and the gitfile write: do the move by hand,
        // leave no gitfile behind.
        try fm.moveItem(at: gitPath, to: pkg.liveRepositoryURL)
        #expect(!fm.fileExists(atPath: gitPath.path))

        let result = try RepoRelocator.migrate(package: pkg)

        #expect(result == .migrated)
        #expect(try String(contentsOf: gitPath, encoding: .utf8) == "gitdir: ../Config/repo.nosync\n")
    }

    @Test("migrate heals a corrupted or foreign gitfile when the live repo is present")
    func healsCorruptedGitfile() async throws {
        let pkg = try await makeEmbeddedRepoPackage()
        try RepoRelocator.migrate(package: pkg)
        let gitPath = pkg.sourceURL.appendingPathComponent(".git")
        try "gitdir: /somewhere/else\n".write(to: gitPath, atomically: true, encoding: .utf8)

        let result = try RepoRelocator.migrate(package: pkg)

        #expect(result == .migrated)
        #expect(try String(contentsOf: gitPath, encoding: .utf8) == "gitdir: ../Config/repo.nosync\n")
    }

    @Test("migrate is a no-op on a fresh skeleton with no repository at all")
    func noRepositoryIsNoOp() throws {
        let pkg = try makePackageSkeleton()
        let result = try RepoRelocator.migrate(package: pkg)
        #expect(result == .noRepository)
        #expect(!FileManager.default.fileExists(atPath: pkg.sourceURL.appendingPathComponent(".git").path))
        #expect(!FileManager.default.fileExists(atPath: pkg.liveRepositoryURL.path))
    }

    @Test("migrate throws danglingGitfile when the gitfile's target repo doesn't exist locally")
    func throwsOnDanglingGitfile() throws {
        let pkg = try makePackageSkeleton()
        try "gitdir: ../Config/repo.nosync\n".write(
            to: pkg.sourceURL.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        #expect(throws: RepoRelocator.RelocationError.self) {
            try RepoRelocator.migrate(package: pkg)
        }
    }

    @Test("migrate throws conflictingRepositories when both an embedded dir and a live repo exist")
    func throwsOnConflictingRepositories() async throws {
        let pkg = try await makeEmbeddedRepoPackage()
        // Fabricate the conflict: a second repo already sitting at Config/repo.nosync.
        try FileManager.default.createDirectory(at: pkg.liveRepositoryURL, withIntermediateDirectories: true)
        try await git(["init"], in: pkg.liveRepositoryURL)

        #expect(throws: RepoRelocator.RelocationError.self) {
            try RepoRelocator.migrate(package: pkg)
        }
    }
}
#endif
