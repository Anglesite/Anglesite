// Tests/AnglesiteCoreTests/MCPClientCancellationTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

/// Transport that answers the `server/discover` ready probe (to let `start` complete) and records
/// every send, but never replies to any other request — so a `callTool` hangs until cancelled.
private actor HangingTransport: MCPTransport {
    private(set) var sentMethods: [String] = []
    private var continuation: AsyncStream<JSONValue>.Continuation?
    private let stream: AsyncStream<JSONValue>

    /// Fires the first time a `tools/call` message passes through `send(_:)`.
    /// Awaiting one element from this stream guarantees the `callTool` continuation is already
    /// registered in `MCPClient.pending` (because `pending[id] = cont` is set synchronously
    /// before the detached send task runs).
    let sentSignal: AsyncStream<Void>
    private let sentSignalContinuation: AsyncStream<Void>.Continuation

    init() {
        var inboundCont: AsyncStream<JSONValue>.Continuation!
        stream = AsyncStream { inboundCont = $0 }
        continuation = inboundCont

        var signalCont: AsyncStream<Void>.Continuation!
        sentSignal = AsyncStream { signalCont = $0 }
        sentSignalContinuation = signalCont
    }
    func sentMethodsSnapshot() -> [String] { sentMethods }
    func open() async throws {}
    nonisolated func inbound() -> AsyncStream<JSONValue> { stream }
    func close() async { continuation?.finish() }
    func send(_ message: JSONValue) async throws {
        guard case .object(let obj) = message,
              case .string(let method)? = obj["method"] else { return }
        sentMethods.append(method)
        if method == "server/discover", case .int(let id)? = obj["id"] {
            // Minimal discover response so the ready probe completes.
            continuation?.yield(.object([
                "jsonrpc": .string("2.0"),
                "id": .int(id),
                "result": .object(["supportedVersions": .array([.string(MCPClient.protocolVersion)])]),
            ]))
        } else if method == "tools/call" {
            // Signal that the send has fired — the pending continuation is already registered.
            sentSignalContinuation.yield(())
        }
        // tools/call: deliberately no response.
    }
}

@Suite(.serialized)
struct MCPClientCancellationTests {
    private func makeInitializedClient() async throws -> (MCPClient, HangingTransport) {
        let transport = HangingTransport()
        let client = MCPClient(supervisor: .shared)
        try await client.startWithTransport(transport, readyTimeout: 5, clientName: "test", clientVersion: "0")
        return (client, transport)
    }

    @Test("a call whose task is cancelled mid-flight throws CancellationError, not timeout")
    func inFlightCancel() async throws {
        let (client, transport) = try await makeInitializedClient()
        let task = Task { try await client.callTool(name: "echo", arguments: .object([:])) }
        // Wait until `tools/call` has been sent — at that point the pending continuation is
        // provably registered in MCPClient (pending[id] = cont runs before the detached send).
        // This is deterministic: no fixed sleep that can race on a loaded CI runner.
        var sentIter = transport.sentSignal.makeAsyncIterator()
        _ = await sentIter.next()
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test("a call whose task is cancelled before it runs never sends tools/call")
    func preCancelledSendsNothing() async throws {
        let (client, transport) = try await makeInitializedClient()
        // Gate the task so we can cancel it *before* callTool runs — deterministic, no sleep race.
        let gate = Gate()
        let task = Task {
            await gate.wait()   // suspends here; resumes only after release()
            return try await client.callTool(name: "echo", arguments: .object([:]))
        }
        task.cancel()           // task is parked at gate.wait(), so this lands before the call
        await gate.release()     // now callTool runs and its pre-call checkCancellation() fires
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let sent = await transport.sentMethodsSnapshot()
        #expect(sent.contains("tools/call") == false)
        #expect(sent.contains("server/discover"))   // ready probe still happened
    }
}

/// One-shot await/resume barrier with no cancellation check of its own, so a task parked on
/// `wait()` stays parked (and cancellable) until `release()`.
private actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
