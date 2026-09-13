// Tests/AnglesiteCoreTests/BackupCommandProgressTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite(.serialized)
struct BackupCommandProgressTests {
    @Test("a successful backup emits staging, committing, pushing")
    func milestones() async {
        let recorder = ProgressRecorder()
        let runner: BackupCommand.GitRunner = { _, args in
            switch args.first {
            case "rev-parse" where args.contains("--is-inside-work-tree"): return .init(stdout: "true", stderr: "", exitCode: 0)
            case "rev-parse" where args.contains("--abbrev-ref"): return .init(stdout: "draft", stderr: "", exitCode: 0)
            case "remote": return .init(stdout: "git@x:me/s.git", stderr: "", exitCode: 0)
            case "status": return .init(stdout: " M a", stderr: "", exitCode: 0)
            default: return .init(stdout: "abc1234", stderr: "", exitCode: 0)
            }
        }
        let streamer: BackupCommand.GitStreamer = { _, _, _ in (0, "") }
        let cmd = BackupCommand(runner: runner, streamer: streamer, gate: .passing)
        _ = await cmd.backup(siteID: "s", siteDirectory: URL(fileURLWithPath: "/tmp/s"),
                            onProgress: { recorder.record($0) })
        #expect(recorder.phases() == ["staging", "committing", "pushing"])
    }
}
