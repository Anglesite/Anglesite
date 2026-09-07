// Tests/AnglesiteCoreTests/DeployCommandProgressTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite(.serialized)
struct DeployCommandProgressTests {
    @Test("a blocked deploy still emits building then preflight milestones")
    func milestonesUpToBlock() async {
        let recorder = ProgressRecorder()
        // Build succeeds (exit 0); preflight JSON blocks so we stop early without reaching wrangler.
        let exec = BlockingPreflightExecutor()
        let cmd = DeployCommand(target: CloudflareDeployTarget(tokenSource: { "token" }), executor: exec)
        _ = await cmd.deploy(siteID: "s", siteDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
                             onProgress: { recorder.record($0) })
        let phases = recorder.phases()
        #expect(phases.prefix(2) == ["building", "preflightScan"])
    }
}

/// Fake executor: build passes, preflight emits a `ok:false` blocking report, wrangler never runs.
private struct BlockingPreflightExecutor: DeployExecutor {
    func run(step: DeployStep, siteDirectory: URL, environment: [String: String], source: String) async -> DeployStepResult {
        switch step {
        case .build:
            return DeployStepResult(exitCode: 0, output: "")
        case .preflight:
            return DeployStepResult(exitCode: 0, output: #"{"version":1,"ok":false,"failures":[],"warnings":[]}"#)
        case .wrangler:
            return DeployStepResult(exitCode: 0, output: "")
        case .bundleUpload:
            return DeployStepResult(exitCode: 0, output: "")
        case .githubPagesPublish:
            return DeployStepResult(exitCode: 0, output: "")
        case .wranglerSubcommand:
            return DeployStepResult(exitCode: 0, output: "")
        }
    }
}

/// Collects `OperationProgress` from the synchronous `ProgressHandler` sink. The handler is
/// `@Sendable (OperationProgress) -> Void` and runs inline inside the emitting actor's isolation,
/// so it can't `await` — which rules out making this an actor (that would force `Task { await
/// record(...) }`, and `Task` ordering is non-deterministic, breaking the phase-order assertions).
/// A plain lock is the right tool for a synchronous concurrent sink; `record`/`phases` have no
/// suspension points, so neither is `async`.
final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [OperationProgress] = []
    func record(_ p: OperationProgress) { lock.lock(); items.append(p); lock.unlock() }
    func phases() -> [String] { lock.lock(); defer { lock.unlock() }; return items.map(\.phase) }
}
