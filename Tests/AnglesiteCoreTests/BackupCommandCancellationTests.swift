// Tests/AnglesiteCoreTests/BackupCommandCancellationTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite(.serialized)
struct BackupCommandCancellationTests {
    @Test("cancelling after staging prevents the commit and push steps")
    func cancelBeforeCommit() async throws {
        let streamed = StreamRecorder()
        let runner: BackupCommand.GitRunner = { _, args in
            // Pass all pre-flight introspection so we reach the streamed action steps.
            switch args.first {
            case "rev-parse" where args.contains("--is-inside-work-tree"):
                return .init(stdout: "true", stderr: "", exitCode: 0)
            case "rev-parse" where args.contains("--abbrev-ref"):
                return .init(stdout: "draft", stderr: "", exitCode: 0)
            case "remote":
                return .init(stdout: "git@example.com:me/site.git", stderr: "", exitCode: 0)
            case "status":
                return .init(stdout: " M index.html", stderr: "", exitCode: 0)
            case "rev-parse":   // rev-parse HEAD
                return .init(stdout: "abc1234", stderr: "", exitCode: 0)
            default:
                return .init(stdout: "", stderr: "", exitCode: 0)
            }
        }
        let cancelHolder = TaskHolder()
        let streamer: BackupCommand.GitStreamer = { _, args, _ in
            await streamed.record(args.joined(separator: " "))
            if args.first == "add" { await cancelHolder.cancel() }   // cancel right after staging
            return (0, "")
        }
        let cmd = BackupCommand(runner: runner, streamer: streamer, gate: .passing)
        let task = Task { await cmd.backup(siteID: "s", siteDirectory: URL(fileURLWithPath: "/tmp/s")) }
        await cancelHolder.hold(task)
        let result = await task.value

        let recorded = await streamed.snapshot()
        #expect(recorded.contains { $0.hasPrefix("add") })
        #expect(recorded.contains { $0.hasPrefix("commit") } == false)
        #expect(recorded.contains { $0.hasPrefix("push") } == false)
        #expect(result == .failed(reason: "backup canceled", exitCode: nil))
    }
}

/// Records streamed git invocations.
private actor StreamRecorder {
    private var calls: [String] = []
    func record(_ c: String) { calls.append(c) }
    func snapshot() -> [String] { calls }
}

/// Lets a streamer closure cancel the backup task once it has a handle to it.
private actor TaskHolder {
    private var pending = false
    private var task: Task<BackupCommand.Result, Never>?
    func cancel() { pending = true; task?.cancel() }
    func hold(_ t: Task<BackupCommand.Result, Never>) { task = t; if pending { t.cancel() } }
}
