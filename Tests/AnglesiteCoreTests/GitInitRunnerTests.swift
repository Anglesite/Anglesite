import Testing
import Foundation
@testable import AnglesiteCore

/// Regression coverage for #548: production wiring in `SitesLauncherView` used to discard the
/// result of `git init` entirely (`_ = try await ...run(...)`), so a failure never surfaced as an
/// error or even a warning — the scaffolder's "non-fatal" git-init step silently believed it had
/// succeeded. `GitInitRunner` centralizes the failure check so it can't regress.
///
/// Runs against SwiftGit2 (in-process libgit2, #640) rather than a subprocess — there's no
/// injectable command runner to fake exit codes with anymore, so these exercise the real thing
/// against real temp directories.
struct GitInitRunnerTests {
    @Test("succeeds and creates a .git directory")
    func succeedsAndCreatesAGitDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gitinitrunner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try GitInitRunner.run(in: dir)

        var isDirectory: ObjCBool = false
        let gitDirExists = FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path, isDirectory: &isDirectory)
        #expect(gitDirExists)
        #expect(isDirectory.boolValue)
    }

    @Test("throws GitInitError when the target is not a directory")
    func throwsGitInitErrorWhenTargetIsNotADirectory() throws {
        // git_repository_init requires a directory; pointing it at a plain file must fail.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("gitinitrunner-\(UUID().uuidString)-not-a-dir")
        try Data("not a directory".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect {
            try GitInitRunner.run(in: file)
        } throws: { error in
            guard let gitError = error as? GitInitError else { return false }
            guard case .failed(let message) = gitError else { return false }
            return !message.isEmpty && gitError.errorDescription == "git init failed: \(message)"
        }
    }
}
