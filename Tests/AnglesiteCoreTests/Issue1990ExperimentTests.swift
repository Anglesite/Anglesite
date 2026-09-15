#if canImport(Darwin)
import Testing
import Foundation
import SwiftGit2
@testable import AnglesiteCore

/// DIAGNOSTIC (#1990, delete before merge). Each test is run alone in its own `swift test
/// --filter` invocation on CI so a task-allocator abort in one can't mask the others.
@Suite struct Issue1990ExperimentTests {
    private func tmpDirs() -> (source: URL, config: URL, template: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("Source")
        let config = root.appendingPathComponent("Config")
        let template = root.appendingPathComponent("Template")
        for d in [source, config, template] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        return (source, config, template)
    }

    private func writeFile(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A real repo with `a.txt` committed and then deleted from the working tree.
    private func makeRepoWithTrackedDeletedFile(at source: URL) throws {
        SwiftGit2Bootstrap.ensureInitialized
        guard case .success(let repo) = Repository.create(at: source) else { throw NSError(domain: "x", code: 1) }
        try writeFile("a", to: source.appendingPathComponent("a.txt"))
        guard case .success = repo.add(path: "a.txt") else { throw NSError(domain: "x", code: 2) }
        guard case .success = repo.commit(message: "init", signature: Signature(name: "t", email: "t@example.com")) else {
            throw NSError(domain: "x", code: 3)
        }
        try FileManager.default.removeItem(at: source.appendingPathComponent("a.txt"))
    }

    // A2's shape (commit directly, missing path, default isTracked) — passed on CI in A2.
    @Test func x1_commitDirectMissingPathDefaultIsTracked() async throws {
        let (source, config, _) = tmpDirs()
        let result = await ExistingSiteMigrationCommitter.commit(
            touchedPaths: ["never-written.txt"], sourceDirectory: source, configDirectory: config, message: "m",
            gitCommitBatch: { _, _, _ in "sha" }
        )
        #expect(result == true)
    }

    // The default-argument thunk's shape, built by hand in the test module.
    @Test func x2_isTrackedViaClosureValueNonRepo() async throws {
        let (source, _, _) = tmpDirs()
        let f: @Sendable (URL, String) async -> Bool = InboxSubmissionCommitter.isTracked
        let r = await f(source, "x.txt")
        #expect(r == false)
    }

    @Test func x3_isTrackedDirectNonRepo() async throws {
        let (source, _, _) = tmpDirs()
        let r = await InboxSubmissionCommitter.isTracked(source, "x.txt")
        #expect(r == false)
    }

    // The crashing ExistingSiteMigrationTests test, but with gitCommitBatch injected.
    @Test func x4_runNoninteractivelyLegacyStateInjectedCommitBatch() async throws {
        let (source, config, template) = tmpDirs()
        try writeFile("shared", to: template.appendingPathComponent("scripts/pre-deploy-check.ts"))
        try writeFile("shared", to: source.appendingPathComponent("scripts/pre-deploy-check.ts"))
        try writeFile("name = \"acme\"\n", to: source.appendingPathComponent("wrangler.toml"))
        try writeFile("SECURITY_TXT_MODE=disabled\nCF_PROJECT_NAME=acme\nCF_WORKER_DEPLOYED=true\n", to: source.appendingPathComponent(".site-config"))
        try writeFile("node_modules/\n", to: source.appendingPathComponent(".gitignore"))
        await ExistingSiteMigration.runNoninteractively(
            sourceDirectory: source, configDirectory: config, templateDirectory: template,
            source: "test", logCenter: LogCenter(), gitCommitBatch: { _, _, _ in nil }
        )
        #expect(WranglerConfigFile.read(configDirectory: config) == "name = \"acme\"\n")
    }

    // Only wrangler.toml relocates (no markers, no .gitignore), injected gitCommitBatch.
    @Test func x5_runNoninteractivelyWranglerOnlyInjectedCommitBatch() async throws {
        let (source, config, template) = tmpDirs()
        try writeFile("shared", to: template.appendingPathComponent("scripts/pre-deploy-check.ts"))
        try writeFile("shared", to: source.appendingPathComponent("scripts/pre-deploy-check.ts"))
        try writeFile("SECURITY_TXT_MODE=disabled\n", to: source.appendingPathComponent(".site-config"))
        try writeFile("name = \"acme\"\n", to: source.appendingPathComponent("wrangler.toml"))
        await ExistingSiteMigration.runNoninteractively(
            sourceDirectory: source, configDirectory: config, templateDirectory: template,
            source: "test", logCenter: LogCenter(), gitCommitBatch: { _, _, _ in nil }
        )
        #expect(WranglerConfigFile.read(configDirectory: config) == "name = \"acme\"\n")
    }

    @Test func x6_processGitCommitBatchDirectNonRepo() async throws {
        let (source, _, _) = tmpDirs()
        let r = await InboxSubmissionCommitter.processGitCommitBatch(source, ["a.txt"], "m")
        #expect(r == nil)
    }

    // The status() success path: a real repo with a tracked-but-deleted file.
    @Test func x7_isTrackedDirectRealRepoTrackedDeleted() async throws {
        let (source, _, _) = tmpDirs()
        try makeRepoWithTrackedDeletedFile(at: source)
        let r = await InboxSubmissionCommitter.isTracked(source, "a.txt")
        #expect(r == true)
    }

    // Same, through commit's default-argument thunk.
    @Test func x8_commitDirectRealRepoDefaultIsTracked() async throws {
        let (source, config, _) = tmpDirs()
        try makeRepoWithTrackedDeletedFile(at: source)
        var committed: [String] = []
        let result = await ExistingSiteMigrationCommitter.commit(
            touchedPaths: ["a.txt"], sourceDirectory: source, configDirectory: config, message: "m",
            gitCommitBatch: { _, paths, _ in committed = paths; return "sha" }
        )
        #expect(result == true)
        #expect(committed == ["a.txt"])
    }

    // The crashing test verbatim, but with the wrangler.toml relocation happening in a real repo
    // (so isTracked's status() path runs) and the real default gitCommitBatch.
    @Test func x9_runNoninteractivelyLegacyStateRealRepoDefaults() async throws {
        let (source, config, template) = tmpDirs()
        try makeRepoWithTrackedDeletedFile(at: source)
        try writeFile("shared", to: template.appendingPathComponent("scripts/pre-deploy-check.ts"))
        try writeFile("shared", to: source.appendingPathComponent("scripts/pre-deploy-check.ts"))
        try writeFile("name = \"acme\"\n", to: source.appendingPathComponent("wrangler.toml"))
        try writeFile("SECURITY_TXT_MODE=disabled\nCF_PROJECT_NAME=acme\nCF_WORKER_DEPLOYED=true\n", to: source.appendingPathComponent(".site-config"))
        try writeFile("node_modules/\n", to: source.appendingPathComponent(".gitignore"))
        await ExistingSiteMigration.runNoninteractively(
            sourceDirectory: source, configDirectory: config, templateDirectory: template,
            source: "test", logCenter: LogCenter()
        )
        #expect(WranglerConfigFile.read(configDirectory: config) == "name = \"acme\"\n")
    }
}
#endif
