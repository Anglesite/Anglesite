import Testing
import Foundation
@testable import AnglesiteCore

/// .serialized: libgit2 isn't safe for uncoordinated concurrent use (see the fork's specs).
/// Each test drives `InProcessGit.run` (SwiftGit2 / in-process libgit2), so Swift Testing's
/// default concurrent-within-struct execution is a documented crash hazard here — see
/// `InProcessGitTests`'s identical `.serialized` trait.
@Suite("SourceBundleStatus", .serialized) struct SourceBundleStatusTests {
    private func makeGitRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceBundleStatusTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "hello".write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["sh", "-c", "git init -q && git config user.email t@example.com && git config user.name Test && git add -A && git commit -q -m init"]
        process.currentDirectoryURL = dir
        try process.run()
        process.waitUntilExit()
        return dir
    }

    private func currentHEAD(of dir: URL) async -> String {
        let result = await InProcessGit.run(siteDirectory: dir, arguments: ["rev-parse", "HEAD"])
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test("no sourceBundleBucket in settings reports .notConfigured")
    func notConfigured() async throws {
        let siteDir = try makeGitRepo()
        defer { try? FileManager.default.removeItem(at: siteDir) }
        let status = await SourceBundleStatus.check(siteDirectory: siteDir, settings: SiteSettings())
        #expect(status == .notConfigured)
    }

    @Test("a legacy CF_SOURCE_BUCKET left in .site-config is not consulted (#1960 — the bucket lives in settings)")
    func legacySiteConfigKeyIsIgnored() async throws {
        let siteDir = try makeGitRepo()
        defer { try? FileManager.default.removeItem(at: siteDir) }
        try "CF_SOURCE_BUCKET=my-site-source\n".write(
            to: siteDir.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)
        let status = await SourceBundleStatus.check(siteDirectory: siteDir, settings: SiteSettings())
        #expect(status == .notConfigured)
    }

    @Test("configured but never uploaded reports .notYetUploaded")
    func notYetUploaded() async throws {
        let siteDir = try makeGitRepo()
        defer { try? FileManager.default.removeItem(at: siteDir) }

        let status = await SourceBundleStatus.check(
            siteDirectory: siteDir, settings: SiteSettings(sourceBundleBucket: "my-site-source"))
        #expect(status == .notYetUploaded)
    }

    @Test("uploaded commit matching current HEAD reports .upToDate")
    func upToDate() async throws {
        let siteDir = try makeGitRepo()
        defer { try? FileManager.default.removeItem(at: siteDir) }
        let head = await currentHEAD(of: siteDir)

        let status = await SourceBundleStatus.check(
            siteDirectory: siteDir,
            settings: SiteSettings(deployedSourceBundleCommit: head, sourceBundleBucket: "my-site-source")
        )
        #expect(status == .upToDate)
    }

    @Test("uploaded commit older than current HEAD reports .dirty with both SHAs")
    func dirty() async throws {
        let siteDir = try makeGitRepo()
        defer { try? FileManager.default.removeItem(at: siteDir) }
        let uploadedCommit = await currentHEAD(of: siteDir)

        // A new commit lands after the upload.
        try "changed".write(to: siteDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let commitProcess = Process()
        commitProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        commitProcess.arguments = ["sh", "-c", "git add -A && git commit -q -m update"]
        commitProcess.currentDirectoryURL = siteDir
        try commitProcess.run()
        commitProcess.waitUntilExit()
        let currentCommit = await currentHEAD(of: siteDir)

        let status = await SourceBundleStatus.check(
            siteDirectory: siteDir,
            settings: SiteSettings(deployedSourceBundleCommit: uploadedCommit, sourceBundleBucket: "my-site-source")
        )
        #expect(status == .dirty(uploadedCommit: uploadedCommit, currentCommit: currentCommit))
    }
}
