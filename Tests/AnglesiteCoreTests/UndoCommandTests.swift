import Testing
import Foundation
@testable import AnglesiteCore

struct UndoCommandTests {
    @Test("undo success parses the new commit")
    func undoSuccessParsesNewCommit() async {
        let fake = FakeMCPCaller(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: #"{"status":"undone","newCommit":"abcd1234"}"#)],
            isError: false
        )))
        let cmd = UndoCommand(caller: fake.asCaller)
        let result = await cmd.undo(commit: "current-head", force: false)
        guard case .success(let newCommit) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(newCommit == "abcd1234")
        #expect(fake.lastArgs == .object([
            "commit": .string("current-head"),
            "force": .bool(false),
        ]))
    }

    @Test("undo with a working-tree-modified refusal returns typed files")
    func undoWorkingTreeModifiedReturnsTypedFiles() async {
        let fake = FakeMCPCaller(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: #"{"status":"refused","reason":"working-tree-modified","files":["src/pages/about.astro"]}"#)],
            isError: true
        )))
        let cmd = UndoCommand(caller: fake.asCaller)
        let result = await cmd.undo(commit: "current-head", force: false)
        guard case .workingTreeModified(let files) = result else {
            Issue.record("expected .workingTreeModified, got \(result)")
            return
        }
        #expect(files == ["src/pages/about.astro"])
    }

    @Test("undo forwards the force flag")
    func undoForwardsForceFlag() async {
        let fake = FakeMCPCaller(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: #"{"status":"undone","newCommit":"abcd1234"}"#)],
            isError: false
        )))
        let cmd = UndoCommand(caller: fake.asCaller)
        _ = await cmd.undo(commit: "current-head", force: true)
        guard case .object(let dict) = fake.lastArgs,
              case .bool(let force)? = dict["force"]
        else {
            Issue.record("unexpected args shape: \(fake.lastArgs)")
            return
        }
        #expect(force)
    }

    @Test("undo failed maps to a failed reason")
    func undoFailedMapsToFailedReason() async {
        let fake = FakeMCPCaller(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: #"{"status":"refused","reason":"initial-commit"}"#)],
            isError: true
        )))
        let cmd = UndoCommand(caller: fake.asCaller)
        let result = await cmd.undo(commit: "current-head", force: false)
        guard case .failed(let reason, _) = result else {
            Issue.record("expected .failed, got \(result)")
            return
        }
        #expect(reason == "initial-commit")
    }

    @Test("a thrown error maps to failed")
    func undoThrownErrorMapsToFailed() async {
        struct OopsError: LocalizedError {
            var errorDescription: String? { "oops: something broke" }
        }
        let fake = FakeMCPCaller(result: .failure(OopsError()))
        let cmd = UndoCommand(caller: fake.asCaller)
        let result = await cmd.undo(commit: "current-head", force: false)
        guard case .failed(let reason, let detail) = result else {
            Issue.record("expected .failed, got \(result)")
            return
        }
        #expect(reason == "mcp-error")
        #expect(detail == "oops: something broke")
    }
}

private final class FakeMCPCaller: @unchecked Sendable {
    private let result: Result<MCPClient.ToolCallResult, Error>
    private(set) var lastArgs: JSONValue = .null
    private let lock = NSLock()

    init(result: Result<MCPClient.ToolCallResult, Error>) {
        self.result = result
    }

    func call(name: String, arguments: JSONValue) async throws -> MCPClient.ToolCallResult {
        lock.withLock { lastArgs = arguments }
        switch result {
        case .success(let r): return r
        case .failure(let e): throw e
        }
    }

    /// Bridges the class method to a `@Sendable` closure that matches `UndoCommand`'s
    /// `caller` parameter. An unbound `fake.call` reference isn't `@Sendable`, so
    /// each test wraps through this property instead.
    var asCaller: @Sendable (String, JSONValue) async throws -> MCPClient.ToolCallResult {
        { name, args in try await self.call(name: name, arguments: args) }
    }
}
