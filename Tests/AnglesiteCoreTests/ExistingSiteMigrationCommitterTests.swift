import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct ExistingSiteMigrationCommitterTests {
    private func tmpDirs() -> (source: URL, config: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("Source")
        let config = root.appendingPathComponent("Config")
        try? FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        return (source, config)
    }

    @Test func emptyTouchedPathsIsANoOpThatReturnsTrue() async throws {
        let (source, config) = tmpDirs()
        var callCount = 0
        let result = await ExistingSiteMigrationCommitter.commit(
            touchedPaths: [], sourceDirectory: source, configDirectory: config, message: "test",
            gitCommitBatch: { _, _, _ in callCount += 1; return "deadbeef" }
        )
        #expect(result == true)
        #expect(callCount == 0)
    }

    @Test func successfulCommitClearsThePendingRecord() async throws {
        let (source, config) = tmpDirs()
        try "content".write(to: source.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        let result = await ExistingSiteMigrationCommitter.commit(
            touchedPaths: ["file.txt"], sourceDirectory: source, configDirectory: config, message: "test",
            gitCommitBatch: { _, _, _ in "deadbeef" }
        )

        #expect(result == true)
        #expect(ExistingSiteMigrationPendingCommit.load(from: config).pendingPaths.isEmpty)
    }

    @Test func failedCommitLeavesThePendingRecordSet() async throws {
        let (source, config) = tmpDirs()
        try "content".write(to: source.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        let result = await ExistingSiteMigrationCommitter.commit(
            touchedPaths: ["file.txt"], sourceDirectory: source, configDirectory: config, message: "test",
            gitCommitBatch: { _, _, _ in nil }
        )

        #expect(result == false)
        #expect(ExistingSiteMigrationPendingCommit.load(from: config).pendingPaths == ["file.txt"])
    }

    @Test func aTrackedPathRemovedFromDiskIsKeptSoItsDeletionIsCommitted() async throws {
        // #1960: `DeployStateRelocation` deletes `Source/wrangler.toml`; the removal must reach
        // the commit, so a path that's gone from disk but still tracked stays in the batch.
        let (source, config) = tmpDirs()
        try "content".write(to: source.appendingPathComponent("real.txt"), atomically: true, encoding: .utf8)

        var committedPaths: [String] = []
        let result = await ExistingSiteMigrationCommitter.commit(
            touchedPaths: ["real.txt", "wrangler.toml", "never-tracked.txt"],
            sourceDirectory: source, configDirectory: config, message: "test",
            gitCommitBatch: { _, paths, _ in committedPaths = paths; return "deadbeef" },
            isTracked: { _, path in path == "wrangler.toml" }
        )

        #expect(result == true)
        #expect(committedPaths == ["real.txt", "wrangler.toml"])
    }

    @Test func pathsThatDoNotExistOnDiskAreExcludedFromTheCommit() async throws {
        let (source, config) = tmpDirs()
        try "content".write(to: source.appendingPathComponent("real.txt"), atomically: true, encoding: .utf8)

        var committedPaths: [String] = []
        let result = await ExistingSiteMigrationCommitter.commit(
            touchedPaths: ["real.txt", "never-written.txt"], sourceDirectory: source, configDirectory: config, message: "test",
            gitCommitBatch: { _, paths, _ in committedPaths = paths; return "deadbeef" }
        )

        #expect(result == true)
        #expect(committedPaths == ["real.txt"])
    }

    @Test func retryPendingCommitIsANoOpWhenNothingIsPending() async throws {
        let (source, config) = tmpDirs()
        var callCount = 0
        let result = await ExistingSiteMigrationCommitter.retryPendingCommit(
            sourceDirectory: source, configDirectory: config, message: "test",
            gitCommitBatch: { _, _, _ in callCount += 1; return "deadbeef" }
        )
        #expect(result == true)
        #expect(callCount == 0)
    }

    @Test func retryPendingCommitRetriesAndClearsAPriorFailure() async throws {
        let (source, config) = tmpDirs()
        try "content".write(to: source.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try ExistingSiteMigrationPendingCommit(pendingPaths: ["file.txt"]).save(to: config)

        let result = await ExistingSiteMigrationCommitter.retryPendingCommit(
            sourceDirectory: source, configDirectory: config, message: "test",
            gitCommitBatch: { _, _, _ in "deadbeef" }
        )

        #expect(result == true)
        #expect(ExistingSiteMigrationPendingCommit.load(from: config).pendingPaths.isEmpty)
    }

    @Test func aStillPendingPathFromOneFlowSurvivesAnUnrelatedFlowsSuccessfulCommit() async throws {
        // #1958 review finding: this record now has two independent writers (site-open migration
        // and the deploy-time app-owned-scripts gate). A naive `save(pendingPaths: touchedPaths)`
        // would silently overwrite a still-unretried path from one flow's earlier failed commit
        // the moment the other flow calls `commit` with its own, unrelated paths. `commit` must
        // fold the existing record in instead, so nothing already pending is lost to a second
        // writer's success.
        let (source, config) = tmpDirs()
        try "content".write(to: source.appendingPathComponent("foo.ts"), atomically: true, encoding: .utf8)
        try "content".write(to: source.appendingPathComponent("bar.ts"), atomically: true, encoding: .utf8)
        // Flow A (e.g. site-open migration) wrote foo.ts but its commit failed, leaving it pending.
        try ExistingSiteMigrationPendingCommit(pendingPaths: ["foo.ts"]).save(to: config)

        // Flow B (e.g. the deploy-time gate) restores an unrelated bar.ts and commits it.
        var committedPaths: [String] = []
        let result = await ExistingSiteMigrationCommitter.commit(
            touchedPaths: ["bar.ts"], sourceDirectory: source, configDirectory: config, message: "test",
            gitCommitBatch: { _, paths, _ in committedPaths = paths; return "deadbeef" }
        )

        #expect(result == true)
        // foo.ts rides along in the same commit rather than being dropped from the record...
        #expect(committedPaths == ["bar.ts", "foo.ts"])
        // ...so it's genuinely committed now, and the pending record correctly clears entirely.
        #expect(ExistingSiteMigrationPendingCommit.load(from: config).pendingPaths.isEmpty)
    }

    @Test func aStillPendingPathFromOneFlowIsPreservedWhenAnUnrelatedFlowsCommitFails() async throws {
        let (source, config) = tmpDirs()
        try "content".write(to: source.appendingPathComponent("foo.ts"), atomically: true, encoding: .utf8)
        try "content".write(to: source.appendingPathComponent("bar.ts"), atomically: true, encoding: .utf8)
        try ExistingSiteMigrationPendingCommit(pendingPaths: ["foo.ts"]).save(to: config)

        let result = await ExistingSiteMigrationCommitter.commit(
            touchedPaths: ["bar.ts"], sourceDirectory: source, configDirectory: config, message: "test",
            gitCommitBatch: { _, _, _ in nil }
        )

        #expect(result == false)
        // The merged record survives the failure — foo.ts is not lost even though this call never
        // asked to commit it itself.
        #expect(ExistingSiteMigrationPendingCommit.load(from: config).pendingPaths == ["bar.ts", "foo.ts"])
    }

    @Test func retryPendingCommitClearsStaleRecordWhenAllPathsHaveDisappeared() async throws {
        let (source, config) = tmpDirs()
        try ExistingSiteMigrationPendingCommit(pendingPaths: ["vanished.txt"]).save(to: config)

        let result = await ExistingSiteMigrationCommitter.retryPendingCommit(
            sourceDirectory: source, configDirectory: config, message: "test",
            gitCommitBatch: { _, _, _ in "deadbeef" }
        )

        #expect(result == true)
        #expect(ExistingSiteMigrationPendingCommit.load(from: config).pendingPaths.isEmpty)
    }
}
