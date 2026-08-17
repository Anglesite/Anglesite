import Testing
import Foundation
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
    }
    nonisolated(unsafe) static var queue: [Response] = []
    nonisolated(unsafe) static var capturedRequests: [URLRequest] = []

    static func reset() { queue = []; capturedRequests = [] }

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
        let http = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        if !r.body.isEmpty { client?.urlProtocol(self, didLoad: r.body) }
        client?.urlProtocolDidFinishLoading(self)
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
    private func makeBackend(apiKey: String? = nil) -> ExternalLLMBackend {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ExternalLLMStubURLProtocol.self]
        let session = URLSession(configuration: config)
        return ExternalLLMBackend(
            configuration: .init(baseURL: URL(string: "https://api.example.com/v1")!, model: "test-model", apiKey: apiKey),
            urlSession: session
        )
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
