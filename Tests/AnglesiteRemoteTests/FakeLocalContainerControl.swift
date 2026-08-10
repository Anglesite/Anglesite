import Foundation
import AnglesiteCore

/// A small, `AnglesiteRemoteTests`-local `LocalContainerControl` fake — deliberately not shared
/// with `AnglesiteCoreTests`' own `FakeLocalContainerControl` (which is internal to that test
/// target, with no `startCallCount`/`stopCallCount`, and there's no existing precedent in this
/// codebase for one test target depending on another test target's types). Only implements
/// enough of the protocol to support `RemoteContainerSessionTests`' boot-or-reuse assertions;
/// every other requirement either has a protocol-extension default (`suspend`, the 4-arg
/// `startWorkersDev`, `resetNetworking`) or is a trivial not-exercised stub.
actor FakeLocalContainerControl: LocalContainerControl {
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    /// Fixed session handed back by every `start()` call — `RemoteContainerSession` republishes
    /// these exact URLs into the claim it publishes, so tests can assert against them directly.
    var session = LocalContainerSession(
        previewURL: URL(string: "http://127.0.0.1:4321")!,
        mcpURL: URL(string: "http://127.0.0.1:4399")!
    )

    func start(
        siteID: String,
        sourceRepo: URL,
        ref: String,
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> LocalContainerSession {
        startCallCount += 1
        return session
    }

    func stop(siteID: String) async throws {
        stopCallCount += 1
    }

    func exec(
        siteID: String,
        argv: [String],
        environment: [String: String],
        workingDirectory: String,
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> ContainerExecResult {
        ContainerExecResult(exitCode: 0, stdout: "", stderr: "")
    }

    func execInteractive(
        siteID: String,
        argv: [String],
        environment: [String: String],
        workingDirectory: String,
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> InteractiveExecHandle {
        InteractiveExecHandle(write: { _ in }, terminate: {})
    }

    func startWorkersDev(
        siteID: String,
        workers: [WorkerDescriptor],
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> URL {
        URL(string: "http://127.0.0.1:51003")!
    }

    func stopWorkersDev(siteID: String) async throws {}
}
