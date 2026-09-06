// Tests/AnglesiteCoreTests/ACPClientTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

// `.timeLimit`: the only wall-clock bound in this file, and deliberately so — it exists purely to
// fail a test that regresses into hanging (e.g. a `stop()` guard removed) rather than blocking CI
// forever, per the sibling `VsockTCPProxyTests` convention. Individual tests assert on events/thrown
// errors, not elapsed time.
@Suite(.timeLimit(.minutes(1))) struct ACPClientTests {
    /// In-process fake `ACPTransport`, mirroring `MCPClientTests`'s `FakeMCPServerTransport`:
    /// responses/notifications are yielded synchronously from `send(_:)`, no subprocess, no
    /// wall-clock dependency.
    private actor FakeACPAgentTransport: ACPTransport {
        private var continuation: AsyncStream<JSONValue>.Continuation?
        private let stream: AsyncStream<JSONValue>
        /// Extra `session/update` notifications to emit right after the `session/prompt` response
        /// this test wants to exercise (set per test before calling `sendPrompt`).
        private var updatesToEmitBeforePromptResult: [JSONValue] = []
        private(set) var sentMethods: [String] = []
        private(set) var sentMessages: [JSONValue] = []

        init() {
            var cont: AsyncStream<JSONValue>.Continuation!
            stream = AsyncStream { cont = $0 }
            continuation = cont
        }

        func setUpdatesToEmit(_ updates: [JSONValue]) {
            updatesToEmitBeforePromptResult = updates
        }

        /// Pushes an unsolicited message onto `inbound()`, as if the agent sent it — used to
        /// simulate a server-initiated request (`session/request_permission`) arriving outside the
        /// normal request/response flow this fake otherwise drives from `send(_:)`.
        func injectInbound(_ message: JSONValue) {
            continuation?.yield(message)
        }

        func open() async throws {}
        nonisolated func inbound() -> AsyncStream<JSONValue> { stream }
        func close() async { continuation?.finish() }

        func send(_ message: JSONValue) async throws {
            sentMessages.append(message)
            guard case .object(let obj) = message, case .string(let method)? = obj["method"] else { return }
            sentMethods.append(method)
            guard case .int(let id)? = obj["id"] else { return }  // notifications get no response
            switch method {
            case "initialize":
                continuation?.yield(.object(["jsonrpc": .string("2.0"), "id": .int(id), "result": .object([:])]))
            case "session/new":
                continuation?.yield(.object(["jsonrpc": .string("2.0"), "id": .int(id), "result": .object(["sessionId": .string("sess-1")])]))
            case "session/prompt":
                for update in updatesToEmitBeforePromptResult { continuation?.yield(update) }
                continuation?.yield(.object(["jsonrpc": .string("2.0"), "id": .int(id), "result": .object(["stopReason": .string("end_turn")])]))
            default:
                break
            }
        }
    }

    @Test func initializeSucceedsAgainstAConformingAgent() async throws {
        let client = ACPClient(transport: FakeACPAgentTransport())
        try await client.initialize()
    }

    @Test func newSessionReturnsTheAgentAssignedSessionID() async throws {
        let client = ACPClient(transport: FakeACPAgentTransport())
        try await client.initialize()
        let sessionID = try await client.newSession(cwd: "/workspace/site")
        #expect(sessionID == "sess-1")
    }

    @Test func sendPromptStreamsTextDeltasThenTurnComplete() async throws {
        let transport = FakeACPAgentTransport()
        await transport.setUpdatesToEmit([
            .object(["jsonrpc": .string("2.0"), "method": .string("session/update"), "params": .object([
                "sessionId": .string("sess-1"),
                "update": .object(["sessionUpdate": .string("agent_message_chunk"), "content": .object(["type": .string("text"), "text": .string("Hello")])]),
            ])]),
        ])
        let client = ACPClient(transport: transport)
        try await client.initialize()
        let sessionID = try await client.newSession(cwd: "/workspace/site")
        let events = try await client.sendPrompt(sessionID: sessionID, text: "hi")
        var collected: [AssistantEvent] = []
        for await event in events { collected.append(event) }
        #expect(collected.contains(.textDelta("Hello")))
        #expect(collected.contains(.turnComplete(nil)))
    }

    // MARK: stop() lifecycle guard

    @Test func callsAfterStopFailFastInsteadOfHangingOnAClosedTransport() async throws {
        let client = ACPClient(transport: FakeACPAgentTransport())
        try await client.initialize()
        await client.stop()

        await #expect(throws: ACPClient.ACPError.stopped) {
            try await client.initialize()
        }
    }

    @Test func sendPromptAfterStopFinishesTheStreamWithFailedInsteadOfHanging() async throws {
        let transport = FakeACPAgentTransport()
        let client = ACPClient(transport: transport)
        try await client.initialize()
        let sessionID = try await client.newSession(cwd: "/workspace/site")
        await client.stop()

        // Before the fix, this `sendPrompt` would register a pending continuation and call
        // `transport.send` on an already-closed transport that never answers, hanging the `for
        // await` below forever (bounded only by the suite `.timeLimit`). After the fix, the
        // `session/prompt` request throws `.stopped` immediately, so the stream still terminates.
        let events = try await client.sendPrompt(sessionID: sessionID, text: "hi")
        var collected: [AssistantEvent] = []
        for await event in events { collected.append(event) }
        #expect(collected.contains(.started(model: nil, toolNames: [])))
        #expect(collected.contains { if case .failed = $0 { return true } else { return false } })
        #expect(!collected.contains(.turnComplete(nil)))
    }

    // MARK: server-initiated request id types

    @Test func autoDeclinesPermissionRequestsWithStringIds() async throws {
        let transport = FakeACPAgentTransport()
        let client = ACPClient(transport: transport)
        try await client.initialize()

        // Inject an unsolicited server-initiated request with a STRING id (JSON-RPC permits this;
        // only `.int` was previously matched, so this would have been silently dropped instead of
        // declined, leaving a conformant agent's request hanging forever).
        await transport.injectInbound(.object([
            "jsonrpc": .string("2.0"),
            "id": .string("perm-1"),
            "method": .string("session/request_permission"),
            "params": .object([:]),
        ]))

        // `newSession` afterward: since the reader task processes `inbound()` strictly in FIFO
        // order, the injected message above is guaranteed to have already been handled by the
        // time this resolves — no polling needed.
        _ = try await client.newSession(cwd: "/workspace/site")

        let sent = await transport.sentMessages
        let declined = sent.contains { message in
            guard case .object(let obj) = message,
                  case .string("perm-1")? = obj["id"],
                  case .object(let result)? = obj["result"],
                  case .object(let outcome)? = result["outcome"],
                  case .string("cancelled")? = outcome["outcome"]
            else { return false }
            return true
        }
        #expect(declined)
    }

    // MARK: sendRequest timeout (crashed-agent backstop)

    /// Mirrors a real crash: answers `initialize`/`session/new` normally, then goes silent on
    /// `session/prompt` — as if the in-container agent process died mid-turn — and never finishes
    /// its `inbound()` stream either, matching `ACPContainerExecTransport`'s current behavior when
    /// the underlying process exits without anything explicitly closing the transport.
    private actor FakeACPAgentTransportThatHangsOnPrompt: ACPTransport {
        private var continuation: AsyncStream<JSONValue>.Continuation?
        private let stream: AsyncStream<JSONValue>

        init() {
            var cont: AsyncStream<JSONValue>.Continuation!
            stream = AsyncStream { cont = $0 }
            continuation = cont
        }

        func open() async throws {}
        nonisolated func inbound() -> AsyncStream<JSONValue> { stream }
        func close() async { continuation?.finish() }

        func send(_ message: JSONValue) async throws {
            guard case .object(let obj) = message, case .string(let method)? = obj["method"] else { return }
            guard case .int(let id)? = obj["id"] else { return }  // notifications get no response
            switch method {
            case "initialize":
                continuation?.yield(.object(["jsonrpc": .string("2.0"), "id": .int(id), "result": .object([:])]))
            case "session/new":
                continuation?.yield(.object(["jsonrpc": .string("2.0"), "id": .int(id), "result": .object(["sessionId": .string("sess-1")])]))
            case "session/prompt":
                break  // the agent "crashed": no response, ever
            default:
                break
            }
        }
    }

    @Test func sendPromptTimesOutAndYieldsFailedWhenTheAgentCrashesMidTurn() async throws {
        let transport = FakeACPAgentTransportThatHangsOnPrompt()
        let client = ACPClient(transport: transport)
        try await client.initialize()
        let sessionID = try await client.newSession(cwd: "/workspace/site")
        // Short test-only override — proves the timeout mechanism without waiting out the 120s
        // production default for `session/prompt`.
        await client.setRequestTimeoutOverrideForTesting(0.05)

        let events = try await client.sendPrompt(sessionID: sessionID, text: "hi")
        var collected: [AssistantEvent] = []
        for await event in events { collected.append(event) }
        #expect(collected.contains(.started(model: nil, toolNames: [])))
        #expect(collected.contains { event in
            if case .failed(let message) = event { return message.contains("timeout") }
            return false
        })
        #expect(!collected.contains(.turnComplete(nil)))
    }

    // MARK: sendNotification timeout

    /// A transport whose `send` never returns — models `ACPHTTPTransport`'s real hang risk for a
    /// notification (no request `id` to match a response against, so its SSE read loop would
    /// otherwise wait for the stream to end, which isn't guaranteed to happen promptly).
    private actor FakeACPAgentTransportThatHangsOnSend: ACPTransport {
        func open() async throws {}
        nonisolated func inbound() -> AsyncStream<JSONValue> { AsyncStream { _ in } }
        func close() async {}
        func send(_ message: JSONValue) async throws {
            try await Task.sleep(nanoseconds: .max)  // sleep-is-subject: models a transport that never returns
        }
    }

    @Test func cancelSessionDoesNotHangForeverWhenTheTransportNeverReturns() async throws {
        let client = ACPClient(transport: FakeACPAgentTransportThatHangsOnSend())
        // `cancelSession` reuses the same test-only override as `sendRequest`'s timeout tests, so
        // this proves the bound without waiting out the 10s production default.
        await client.setRequestTimeoutOverrideForTesting(0.05)
        await client.cancelSession(sessionID: "sess-1")  // must return, not hang forever
    }
}
