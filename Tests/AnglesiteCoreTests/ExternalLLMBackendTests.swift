import Testing
import Foundation
import AnglesiteTestSupport
@testable import AnglesiteCore
#if compiler(>=6.4) && canImport(FoundationModels)
import FoundationModels
#endif

/// A dedicated `URLProtocol` stub for `ExternalLLMBackend` tests — modeled on `ACPStubURLProtocol`.
final class ExternalLLMStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response {
        let status: Int
        let headers: [String: String]
        let body: Data
        /// When set, nothing (not even the response head) is delivered until the semaphore is
        /// signalled — the seam that parks a `converse()` call inside its network `await` so a
        /// test can land a `resetSession()`/superseding `converse()` in that exact window.
        let gate: DispatchSemaphore?
        /// Ends the connection with an error *after* the body instead of finishing cleanly —
        /// the "connection dropped mid-stream" case, which must surface as a `.failed` event
        /// rather than a throw out of `converse()`.
        let failsAfterBody: Bool

        init(status: Int, headers: [String: String], body: Data, gate: DispatchSemaphore? = nil, failsAfterBody: Bool = false) {
            self.status = status
            self.headers = headers
            self.body = body
            self.gate = gate
            self.failsAfterBody = failsAfterBody
        }
    }
    nonisolated(unsafe) static var queue: [Response] = []
    nonisolated(unsafe) static var capturedRequests: [URLRequest] = []
    /// How many gated requests have reached `startLoading` (i.e. are parked on their semaphore).
    /// Tests poll this to know a `converse()` is genuinely suspended mid-request before racing it.
    nonisolated(unsafe) static var gatedRequestsEntered = 0

    static func reset() { queue = []; capturedRequests = []; gatedRequestsEntered = 0 }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // `URLSession.bytes(for:)` (used by `ExternalLLMBackend.converse`) transports an
        // `httpBody` via `httpBodyStream` instead, so by the time this stub sees the request,
        // `httpBody` reads back `nil` and the encoded JSON only exists on the (one-shot) stream.
        // Drain it back into `httpBody` on the captured copy so tests can assert on the request
        // body the same way `ACPStubURLProtocol`-style stubs do for non-streaming sends.
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            captured.httpBody = Self.drain(stream)
        }
        Self.capturedRequests.append(captured)
        let r = Self.queue.isEmpty ? Response(status: 500, headers: [:], body: Data()) : Self.queue.removeFirst()
        let deliver = { [self] in
            let http = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers)!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            if !r.body.isEmpty { client?.urlProtocol(self, didLoad: r.body) }
            if r.failsAfterBody {
                // Delayed so `converse()`'s setup `await` has certainly returned and the drain is
                // parked on the byte stream: the contract under test is specifically a failure
                // *after* streaming begins.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [self] in
                    client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                }
            } else {
                client?.urlProtocolDidFinishLoading(self)
            }
        }
        guard let gate = r.gate else { return deliver() }
        // Park on a *global-queue* thread, never the URL loading thread — blocking the latter
        // would stop the session from starting the second, ungated request the race tests need.
        Self.gatedRequestsEntered += 1
        DispatchQueue.global().async {
            gate.wait()
            deliver()
        }
    }
    override func stopLoading() {}

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

@Suite("ExternalLLMBackend wire format")
struct ExternalLLMBackendWireFormatTests {
    private func makeBackend(apiKey: String? = "sk-test") -> ExternalLLMBackend {
        ExternalLLMBackend(configuration: .init(
            baseURL: URL(string: "https://api.example.com/v1")!,
            model: "test-model",
            apiKey: apiKey
        ))
    }

    @Test("capabilities reflect the configured model, no tools/vision/structured output")
    func capabilitiesReflectConfiguration() {
        let backend = makeBackend()
        let caps = backend.capabilities
        #expect(caps.providerName == "Custom (test-model)")
        #expect(caps.supportsStreaming == true)
        #expect(caps.supportsStructuredOutput == false)
        #expect(caps.supportsVision == false)
        #expect(caps.supportsTools == false)
        #expect(caps.maxContextTokens == nil)
    }

    @Test("makeURLRequest appends /chat/completions and trims a trailing slash on baseURL")
    func makeURLRequestAppendsPath() async throws {
        let backend = ExternalLLMBackend(configuration: .init(
            baseURL: URL(string: "https://api.example.com/v1/")!, model: "m", apiKey: nil
        ))
        let request = try await backend.makeURLRequest(messages: [])
        #expect(request.url?.absoluteString == "https://api.example.com/v1/chat/completions")
    }

    @Test("makeURLRequest sends a Bearer header only when an API key is configured")
    func makeURLRequestAuthHeader() async throws {
        let withKey = try await makeBackend(apiKey: "sk-test").makeURLRequest(messages: [])
        #expect(withKey.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")

        let withoutKey = try await makeBackend(apiKey: nil).makeURLRequest(messages: [])
        #expect(withoutKey.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("makeURLRequest encodes model, messages, and stream_options.include_usage")
    func makeURLRequestEncodesBody() async throws {
        let backend = makeBackend()
        let request = try await backend.makeURLRequest(messages: [.init(role: "user", content: "hello")])
        let body = try #require(request.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["model"] as? String == "test-model")
        #expect(json?["stream"] as? Bool == true)
        let messages = try #require(json?["messages"] as? [[String: String]])
        #expect(messages == [["role": "user", "content": "hello"]])
        let streamOptions = try #require(json?["stream_options"] as? [String: Bool])
        #expect(streamOptions["include_usage"] == true)
    }

    @Test("decodeChunk parses a text delta")
    func decodeChunkParsesTextDelta() {
        let chunk = ExternalLLMBackend.decodeChunk(#"{"choices":[{"delta":{"content":"Hi"}}]}"#)
        #expect(chunk?.choices?.first?.delta?.content == "Hi")
    }

    @Test("decodeChunk parses a usage object")
    func decodeChunkParsesUsage() {
        let chunk = ExternalLLMBackend.decodeChunk(#"{"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5}}"#)
        #expect(chunk?.usage?.promptTokens == 10)
        #expect(chunk?.usage?.completionTokens == 5)
    }

    @Test("decodeChunk returns nil for unparsable input")
    func decodeChunkReturnsNilForGarbage() {
        #expect(ExternalLLMBackend.decodeChunk("not json") == nil)
    }

    @Test("turnPrompt folds route and page content ahead of the prompt")
    func turnPromptFoldsContext() {
        let context = AssistantContext(
            siteID: "s1", siteDirectory: URL(fileURLWithPath: "/tmp/s1"),
            currentPageRoute: "/about", currentPageContent: "About us."
        )
        let prompt = ExternalLLMBackend.turnPrompt(for: "Make it shorter", context: context)
        #expect(prompt == "The user is viewing the page at /about.\nCurrent page content:\nAbout us.\nMake it shorter")
    }

    @Test("turnPrompt is just the prompt when context carries no page info")
    func turnPromptWithNoContext() {
        let context = AssistantContext(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/tmp/s1"))
        #expect(ExternalLLMBackend.turnPrompt(for: "hello", context: context) == "hello")
    }

    @Test("truncatedPageContent caps at 2,000 characters with an ellipsis")
    func truncatedPageContentCaps() {
        let long = String(repeating: "a", count: 2_500)
        let truncated = ExternalLLMBackend.truncatedPageContent(long)
        #expect(truncated.count == 2_001) // 2000 chars + "…"
        #expect(truncated.hasSuffix("…"))
    }
}

@Suite("ExternalLLMBackend conversation", .serialized)
struct ExternalLLMBackendConversationTests {
    private func makeBackend(apiKey: String? = nil, maxLineBytes: Int = ExternalLLMBackend.defaultMaxLineBytes) -> ExternalLLMBackend {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ExternalLLMStubURLProtocol.self]
        let session = URLSession(configuration: config)
        return ExternalLLMBackend(
            configuration: .init(baseURL: URL(string: "https://api.example.com/v1")!, model: "test-model", apiKey: apiKey),
            urlSession: session,
            maxLineBytes: maxLineBytes
        )
    }

    /// Suspends until `count` gated requests have reached the stub's `startLoading` — i.e. that
    /// many `converse()` calls are genuinely parked inside their network `await`.
    private func awaitGatedRequests(_ count: Int) async throws {
        try await waitUntil("\(count) gated request(s) to start") {
            ExternalLLMStubURLProtocol.gatedRequestsEntered >= count
        }
    }

    /// The `messages` array of the last request the stub captured, as role/content pairs.
    private func lastRequestMessages() throws -> [[String: String]] {
        let body = try #require(ExternalLLMStubURLProtocol.capturedRequests.last?.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        return try #require(json?["messages"] as? [[String: String]])
    }

    private func sseBody(_ events: [String]) -> Data {
        (events.map { "data: \($0)\n\n" }.joined() + "data: [DONE]\n\n").data(using: .utf8)!
    }

    private func context() -> AssistantContext {
        AssistantContext(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/tmp/s1"))
    }

    @Test("converse streams text deltas in order and completes")
    func conversesStreamsTextDeltas() async throws {
        ExternalLLMStubURLProtocol.reset()
        let body = sseBody([
            #"{"choices":[{"delta":{"role":"assistant"}}]}"#,
            #"{"choices":[{"delta":{"content":"Hel"}}]}"#,
            #"{"choices":[{"delta":{"content":"lo"}}]}"#
        ])
        ExternalLLMStubURLProtocol.queue.append(.init(status: 200, headers: ["Content-Type": "text/event-stream"], body: body))
        let backend = makeBackend()
        let stream = try await backend.converse(prompt: "hi", context: context())

        var events: [AssistantEvent] = []
        for await event in stream { events.append(event) }

        #expect(events.first == .started(model: "test-model", toolNames: []))
        #expect(events.contains(.textDelta("Hel")))
        #expect(events.contains(.textDelta("lo")))
        #expect(events.last == .turnComplete(nil))
    }

    @Test("usage on the final chunk produces AssistantUsage on turnComplete")
    func usageProducesAssistantUsage() async throws {
        ExternalLLMStubURLProtocol.reset()
        let body = sseBody([
            #"{"choices":[{"delta":{"content":"Hi"}}]}"#,
            #"{"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":3}}"#
        ])
        ExternalLLMStubURLProtocol.queue.append(.init(status: 200, headers: ["Content-Type": "text/event-stream"], body: body))
        let backend = makeBackend()
        let stream = try await backend.converse(prompt: "hi", context: context())

        var usage: AssistantUsage?
        for await event in stream {
            if case .turnComplete(let u) = event { usage = u }
        }
        #expect(usage == AssistantUsage(inputTokens: 12, outputTokens: 3))
    }

    @Test("a non-2xx initial response throws before any event is yielded")
    func nonTwoHundredThrows() async throws {
        ExternalLLMStubURLProtocol.reset()
        ExternalLLMStubURLProtocol.queue.append(.init(
            status: 401, headers: [:], body: #"{"error":{"message":"bad key"}}"#.data(using: .utf8)!
        ))
        let backend = makeBackend()
        await #expect(throws: (any Error).self) {
            _ = try await backend.converse(prompt: "hi", context: context())
        }
    }

    @Test("Authorization header carries the configured API key")
    func authorizationHeaderCarriesKey() async throws {
        ExternalLLMStubURLProtocol.reset()
        ExternalLLMStubURLProtocol.queue.append(.init(status: 200, headers: ["Content-Type": "text/event-stream"], body: sseBody([])))
        let backend = makeBackend(apiKey: "sk-test")
        _ = try await backend.converse(prompt: "hi", context: context())
        #expect(ExternalLLMStubURLProtocol.capturedRequests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
    }

    @Test("resetSession clears history so the next turn's request carries only the fresh system instruction")
    func resetSessionClearsHistory() async throws {
        ExternalLLMStubURLProtocol.reset()
        ExternalLLMStubURLProtocol.queue.append(.init(status: 200, headers: ["Content-Type": "text/event-stream"], body: sseBody([#"{"choices":[{"delta":{"content":"Hi"}}]}"#])))
        ExternalLLMStubURLProtocol.queue.append(.init(status: 200, headers: ["Content-Type": "text/event-stream"], body: sseBody([#"{"choices":[{"delta":{"content":"Yo"}}]}"#])))
        let backend = makeBackend()

        let first = try await backend.converse(prompt: "hi", context: context())
        for await _ in first {}

        await backend.resetSession()

        let second = try await backend.converse(prompt: "again", context: context())
        for await _ in second {}

        let secondRequestBody = try #require(ExternalLLMStubURLProtocol.capturedRequests.last?.httpBody)
        let json = try JSONSerialization.jsonObject(with: secondRequestBody) as? [String: Any]
        let messages = try #require(json?["messages"] as? [[String: String]])
        // Just the system instruction + the new user turn — the first turn's user/assistant
        // pair is gone.
        #expect(messages.count == 2)
        #expect(messages[0]["role"] == "system")
        #expect(messages[1]["content"]?.hasSuffix("again") == true)
    }

    @Test("history is capped at maxHistoryMessages, oldest turns dropped first, system instruction kept")
    func historyIsCapped() async throws {
        ExternalLLMStubURLProtocol.reset()
        let backend = makeBackend()
        // 25 turns * 2 messages/turn (user+assistant) = 50 > maxHistoryMessages (40), forcing a drop.
        for i in 0..<25 {
            ExternalLLMStubURLProtocol.queue.append(.init(status: 200, headers: ["Content-Type": "text/event-stream"], body: sseBody([#"{"choices":[{"delta":{"content":"ok"}}]}"#])))
            let stream = try await backend.converse(prompt: "turn \(i)", context: context())
            for await _ in stream {}
        }
        let lastRequestBody = try #require(ExternalLLMStubURLProtocol.capturedRequests.last?.httpBody)
        let json = try JSONSerialization.jsonObject(with: lastRequestBody) as? [String: Any]
        let messages = try #require(json?["messages"] as? [[String: String]])
        #expect(messages.count <= 41) // system + maxHistoryMessages
        #expect(messages.first?["role"] == "system")
        #expect(!messages.contains { $0["content"] == "turn 0" })
    }

    @Test("cancel stops delivering further events without corrupting the next turn")
    func cancelStopsDelivery() async throws {
        ExternalLLMStubURLProtocol.reset()
        ExternalLLMStubURLProtocol.queue.append(.init(status: 200, headers: ["Content-Type": "text/event-stream"], body: sseBody([#"{"choices":[{"delta":{"content":"Hi"}}]}"#])))
        ExternalLLMStubURLProtocol.queue.append(.init(status: 200, headers: ["Content-Type": "text/event-stream"], body: sseBody([#"{"choices":[{"delta":{"content":"Yo"}}]}"#])))
        let backend = makeBackend()

        let first = try await backend.converse(prompt: "hi", context: context())
        await backend.cancel()
        var firstEvents: [AssistantEvent] = []
        for await event in first { firstEvents.append(event) }
        #expect(firstEvents.last == .cancelled)

        let second = try await backend.converse(prompt: "again", context: context())
        var sawTextDelta = false
        for await event in second {
            if case .textDelta = event { sawTextDelta = true }
        }
        #expect(sawTextDelta)
    }

    @Test("finishTurn is a no-op when its turn has been superseded (regression: #1482 stale-turn guard)")
    func finishTurnSkipsStaleTurn() async throws {
        // The *post*-relay half of the race, exercised directly: a drain that reaches its
        // normal-completion `finishTurn` after `resetSession()`/`cancel()`/a superseding
        // `converse()` has already moved the actor on. Driving that half end-to-end proved
        // unreliable — `URLSession.AsyncBytes` observes `Task` cancellation promptly enough that
        // an artificially delayed SSE stream throws out through `drainSSE`'s `catch` (the
        // harmless `.failed` path) instead of reaching the vulnerable fall-through. Calling
        // `finishTurn` with a stale generation reproduces the exact state deterministically. The
        // *pre*-relay half — the window this guard's predecessor missed — is covered end-to-end
        // by `resetSessionDuringSetupAwaitLeavesNoHistory` below.
        let backend = makeBackend()
        let (_, continuation) = AsyncStream.makeStream(of: AssistantEvent.self)
        let staleRelay = TurnRelay(continuation)

        let before = await backend.messages
        #expect(before.isEmpty)
        let staleGeneration = await backend.turnGeneration - 1
        await backend.finishTurn(
            userMessage: .init(role: "user", content: "orphaned prompt"),
            accumulatedText: "orphaned",
            usage: nil,
            generation: staleGeneration,
            relay: staleRelay
        )
        let after = await backend.messages
        // Unguarded, this would corrupt `messages` — e.g. permanently losing the system
        // instruction on a session `resetSession()` had just cleared, since
        // `seedHistoryIfNeeded` only reseeds when `messages` is empty.
        #expect(after.isEmpty)
    }

    @Test("resetSession landing inside converse's setup await leaves no history behind (regression: #1482 pre-relay race)")
    func resetSessionDuringSetupAwaitLeavesNoHistory() async throws {
        ExternalLLMStubURLProtocol.reset()
        let gate = DispatchSemaphore(value: 0)
        // Turn 1 is parked before its response head is delivered — `converse()` is suspended in
        // `urlSession.bytes(for:)`, past the point where it staged its user turn and before it
        // ever assigns `activeRelay`. That window is where the relay-identity guard was blind.
        ExternalLLMStubURLProtocol.queue.append(.init(
            status: 200, headers: ["Content-Type": "text/event-stream"],
            body: sseBody([#"{"choices":[{"delta":{"content":"Hi"}}]}"#]), gate: gate
        ))
        ExternalLLMStubURLProtocol.queue.append(.init(
            status: 200, headers: ["Content-Type": "text/event-stream"],
            body: sseBody([#"{"choices":[{"delta":{"content":"Yo"}}]}"#])
        ))
        let backend = makeBackend()

        let firstTurn = Task { try await backend.converse(prompt: "hi", context: context()) }
        try await awaitGatedRequests(1)
        await backend.resetSession()
        gate.signal()

        // The superseded turn never hands out a stream — a consumer attached to one would be
        // waiting on a turn nothing will terminate.
        await #expect(throws: CancellationError.self) { _ = try await firstTurn.value }
        let afterReset = await backend.messages
        #expect(afterReset.isEmpty)

        // Before the fix, the resuming turn appended its reply to the array `resetSession()` had
        // just emptied, so this second request went out as [assistant, user] — no system
        // instruction (`seedHistoryIfNeeded` only reseeds an empty history) and carrying content
        // from the conversation the owner had just cleared.
        let second = try await backend.converse(prompt: "again", context: context())
        for await _ in second {}
        let messages = try lastRequestMessages()
        #expect(messages.count == 2)
        #expect(messages[0]["role"] == "system")
        #expect(messages[1]["role"] == "user")
        #expect(messages[1]["content"] == "again")
    }

    @Test("a converse superseded inside its setup await neither strands its consumer nor its user message (regression: #1482)")
    func supersedingConverseDuringSetupAwaitIsClean() async throws {
        ExternalLLMStubURLProtocol.reset()
        let gate = DispatchSemaphore(value: 0)
        ExternalLLMStubURLProtocol.queue.append(.init(
            status: 200, headers: ["Content-Type": "text/event-stream"],
            body: sseBody([#"{"choices":[{"delta":{"content":"first"}}]}"#]), gate: gate
        ))
        ExternalLLMStubURLProtocol.queue.append(.init(
            status: 200, headers: ["Content-Type": "text/event-stream"],
            body: sseBody([#"{"choices":[{"delta":{"content":"second"}}]}"#])
        ))
        ExternalLLMStubURLProtocol.queue.append(.init(
            status: 200, headers: ["Content-Type": "text/event-stream"],
            body: sseBody([#"{"choices":[{"delta":{"content":"third"}}]}"#])
        ))
        let backend = makeBackend()

        let firstTurn = Task { try await backend.converse(prompt: "first prompt", context: context()) }
        try await awaitGatedRequests(1)

        // Supersedes the parked turn before it ever reached its relay assignment.
        let second = try await backend.converse(prompt: "second prompt", context: context())
        for await _ in second {}
        gate.signal()

        // Previously the parked turn returned a stream whose relay was never `activeRelay`, so
        // nothing ever completed it — a consumer of that stream hung forever.
        await #expect(throws: CancellationError.self) { _ = try await firstTurn.value }

        // And its user message never entered history, so the surviving turn's pair is intact and
        // unpolluted by the abandoned prompt.
        let third = try await backend.converse(prompt: "third prompt", context: context())
        for await _ in third {}
        let messages = try lastRequestMessages()
        #expect(messages.map { $0["role"] } == ["system", "user", "assistant", "user"])
        #expect(messages[1]["content"] == "second prompt")
        #expect(messages[2]["content"] == "second")
        #expect(!messages.contains { $0["content"] == "first prompt" })
    }

    @Test("an assistant reply is carried into the next turn's request")
    func assistantReplyEntersHistory() async throws {
        ExternalLLMStubURLProtocol.reset()
        ExternalLLMStubURLProtocol.queue.append(.init(
            status: 200, headers: ["Content-Type": "text/event-stream"],
            body: sseBody([#"{"choices":[{"delta":{"content":"Hel"}}]}"#, #"{"choices":[{"delta":{"content":"lo"}}]}"#])
        ))
        ExternalLLMStubURLProtocol.queue.append(.init(
            status: 200, headers: ["Content-Type": "text/event-stream"], body: sseBody([])
        ))
        let backend = makeBackend()

        let first = try await backend.converse(prompt: "hi", context: context())
        for await _ in first {}
        let second = try await backend.converse(prompt: "and again", context: context())
        for await _ in second {}

        // `historyIsCapped` would pass even if replies never reached history at all — this is the
        // test that actually pins the multi-turn contract.
        let messages = try lastRequestMessages()
        #expect(messages.map { $0["role"] } == ["system", "user", "assistant", "user"])
        #expect(messages[1]["content"] == "hi")
        #expect(messages[2]["content"] == "Hello")
        #expect(messages[3]["content"] == "and again")
    }

    @Test("a cancelled turn leaves no unpaired user message in history")
    func cancelLeavesNoUnpairedUserMessage() async throws {
        ExternalLLMStubURLProtocol.reset()
        ExternalLLMStubURLProtocol.queue.append(.init(status: 200, headers: ["Content-Type": "text/event-stream"], body: sseBody([#"{"choices":[{"delta":{"content":"Hi"}}]}"#])))
        ExternalLLMStubURLProtocol.queue.append(.init(status: 200, headers: ["Content-Type": "text/event-stream"], body: sseBody([#"{"choices":[{"delta":{"content":"Yo"}}]}"#])))
        let backend = makeBackend()

        let first = try await backend.converse(prompt: "cancelled prompt", context: context())
        await backend.cancel()
        for await _ in first {}

        let second = try await backend.converse(prompt: "next prompt", context: context())
        for await _ in second {}

        let messages = try lastRequestMessages()
        // The cancelled turn produced no assistant reply, so its user message must not linger:
        // two consecutive `user` entries are rejected outright by some OpenAI-compatible servers
        // and re-send the discarded prompt's page content on every later turn.
        #expect(messages.map { $0["role"] } == ["system", "user"])
        #expect(messages[1]["content"] == "next prompt")
    }

    @Test("a setup failure leaves no unpaired user message in history")
    func setupFailureLeavesNoUnpairedUserMessage() async throws {
        ExternalLLMStubURLProtocol.reset()
        // Two rejected attempts (a bad API key, retried) then a good one.
        for _ in 0..<2 {
            ExternalLLMStubURLProtocol.queue.append(.init(status: 401, headers: [:], body: #"{"error":{"message":"bad key"}}"#.data(using: .utf8)!))
        }
        ExternalLLMStubURLProtocol.queue.append(.init(status: 200, headers: ["Content-Type": "text/event-stream"], body: sseBody([#"{"choices":[{"delta":{"content":"Hi"}}]}"#])))
        let backend = makeBackend()

        for _ in 0..<2 {
            await #expect(throws: (any Error).self) {
                _ = try await backend.converse(prompt: "rejected prompt", context: context())
            }
        }
        let stream = try await backend.converse(prompt: "accepted prompt", context: context())
        for await _ in stream {}

        let messages = try lastRequestMessages()
        #expect(messages.map { $0["role"] } == ["system", "user"])
        #expect(messages[1]["content"] == "accepted prompt")
    }

    @Test("an SSE line larger than maxLineBytes fails the turn instead of growing without bound")
    func oversizedSSELineFailsTheTurn() async throws {
        ExternalLLMStubURLProtocol.reset()
        // A 2xx response with the right content type, then a body that never emits a newline —
        // a hostile or simply non-SSE endpoint. Without the bound this accumulates until the app
        // is OOM-killed; the endpoint here is user-configured and unvetted.
        let neverEnding = Data(repeating: UInt8(ascii: "a"), count: 4_096)
        ExternalLLMStubURLProtocol.queue.append(.init(
            status: 200, headers: ["Content-Type": "text/event-stream"], body: neverEnding
        ))
        let backend = makeBackend(maxLineBytes: 64)

        let stream = try await backend.converse(prompt: "hi", context: context())
        var events: [AssistantEvent] = []
        for await event in stream { events.append(event) }

        // A failure after streaming begins is an in-band `.failed`, never a throw.
        guard case .failed(let message)? = events.last else {
            Issue.record("expected a .failed terminal event, got \(String(describing: events.last))")
            return
        }
        #expect(message.contains("lineTooLong"))
        // The failed turn contributed nothing to history.
        let messages = await backend.messages
        #expect(messages.map(\.role) == ["system"])
    }

    @Test("a connection dropped mid-stream surfaces as .failed, not a throw")
    func midStreamConnectionDropFails() async throws {
        ExternalLLMStubURLProtocol.reset()
        // A well-formed start (2xx + one complete SSE event, so streaming has genuinely begun),
        // then the connection dies without a `[DONE]` sentinel or a clean EOF.
        let partial = "data: \(#"{"choices":[{"delta":{"content":"Hi"}}]}"#)\n\n".data(using: .utf8)!
        ExternalLLMStubURLProtocol.queue.append(.init(
            status: 200, headers: ["Content-Type": "text/event-stream"], body: partial, failsAfterBody: true
        ))
        ExternalLLMStubURLProtocol.queue.append(.init(
            status: 200, headers: ["Content-Type": "text/event-stream"], body: sseBody([#"{"choices":[{"delta":{"content":"Yo"}}]}"#])
        ))
        let backend = makeBackend()

        let stream = try await backend.converse(prompt: "dropped prompt", context: context())
        var events: [AssistantEvent] = []
        for await event in stream { events.append(event) }

        #expect(events.contains(.textDelta("Hi")))
        guard case .failed? = events.last else {
            Issue.record("expected a .failed terminal event, got \(String(describing: events.last))")
            return
        }

        // The half-delivered turn is not committed — neither the discarded partial reply nor its
        // now-unanswered user message.
        let next = try await backend.converse(prompt: "next prompt", context: context())
        for await _ in next {}
        let messages = try lastRequestMessages()
        #expect(messages.map { $0["role"] } == ["system", "user"])
        #expect(messages[1]["content"] == "next prompt")
    }

#if canImport(Darwin)
    @Test("cancel() cancels a pending setup-phase network task instead of leaving it running (regression: #1482 Darwin proactive-cancel)")
    func cancelCancelsActiveSetupTask() async throws {
        // End-to-end HTTP timing tests for this exact race proved unreliable for the sibling
        // stale-turn guard (see `finishTurnSkipsStaleTurn`'s comment): this stub's gate blocks a
        // raw GCD thread, not a cancellable async operation, so racing real network timing can't
        // deterministically prove "was the underlying request actually torn down." Testing the
        // wiring directly instead: does `cancel()` actually cancel whatever `Task` is parked in
        // `activeSetupTask`, rather than merely leaving it to run to its own timeout — which is
        // the exact gap the review found (`cancel()`'s own doc comment claims it "frees the
        // connection promptly," which was false during this window before the fix).
        let backend = makeBackend()
        let sentinel = Task<(URLSession.AsyncBytes, URLResponse), Error> {
            try await Task.sleep(nanoseconds: .max)
            fatalError("unreachable — Task.sleep(nanoseconds: .max) never returns normally")
        }
        await backend.setActiveSetupTaskForTesting(sentinel)
        await backend.cancel()
        // A cancelled `Task.sleep` throws promptly — if `cancel()` never actually cancelled the
        // sentinel, this would hang instead of finishing.
        _ = try? await sentinel.value
        #expect(sentinel.isCancelled)
    }
#endif

    @Test("a non-2xx response for an already-superseded turn discards as CancellationError, not HTTPError (regression: #1482 staleness-before-status ordering)")
    func nonTwoHundredForSupersededTurnDiscardsSilently() async throws {
        ExternalLLMStubURLProtocol.reset()
        let gate = DispatchSemaphore(value: 0)
        ExternalLLMStubURLProtocol.queue.append(.init(
            status: 401, headers: [:], body: #"{"error":{"message":"bad key"}}"#.data(using: .utf8)!, gate: gate
        ))
        let backend = makeBackend()

        let turn = Task { try await backend.converse(prompt: "hi", context: context()) }
        try await awaitGatedRequests(1)
        // Bumps `turnGeneration` directly rather than calling `cancel()`/`resetSession()`, which
        // would *also* cancel `activeSetupTask` (Darwin) — that cancellation races the stub's
        // gated response and empirically wins, throwing `CancellationError` from the setup-task
        // catch block before the response is even interpreted, which would make this test pass
        // regardless of whether the ordering fix under test exists. Bumping the generation alone
        // isolates that: the response still arrives normally through the gate, and only the
        // staleness-vs-status ordering below determines what it turns into.
        await backend.bumpTurnGenerationForTesting()
        gate.signal()

        // Without the fix, the non-2xx status is interpreted *before* the staleness check, so this
        // throws `HTTPError.http(status: 401, ...)` — a misleading "auth failure" for a request
        // the caller already gave up on — instead of the same `CancellationError` every other
        // superseded turn discards as.
        await #expect(throws: CancellationError.self) { _ = try await turn.value }
        let messages = await backend.messages
        #expect(messages.map(\.role) == ["system"])
    }

    @Test("generate flattens converse's event stream to plain text")
    func generateFlattensToText() async throws {
        ExternalLLMStubURLProtocol.reset()
        let body = sseBody([
            #"{"choices":[{"delta":{"content":"Hel"}}]}"#,
            #"{"choices":[{"delta":{"content":"lo"}}]}"#
        ])
        ExternalLLMStubURLProtocol.queue.append(.init(status: 200, headers: ["Content-Type": "text/event-stream"], body: body))
        let backend = makeBackend()
        let stream = try await backend.generate(prompt: "hi", context: context())
        var text = ""
        for try await chunk in stream { text += chunk }
        #expect(text == "Hello")
    }

#if compiler(>=6.4) && canImport(FoundationModels)
    @Test("generateStructured always throws unsupported")
    func generateStructuredThrows() async throws {
        let backend = makeBackend()
        await #expect(throws: (any Error).self) {
            _ = try await backend.generateStructured(prompt: "hi", context: context(), resultType: GeneratedPageMeta.self)
        }
    }
#endif
}
