import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
// Same toolchain/runtime gate as `ContentAssistant.swift` — `Generable` (used only by the
// `generateStructured` conformance below) comes from FoundationModels, which is absent from
// GitHub's macos-15 CI runner at *load* time even when the SDK has the symbol at compile time.
#if compiler(>=6.4) && canImport(FoundationModels)
import FoundationModels
#endif

/// `URLSession`-based backend speaking a single OpenAI-compatible chat-completions protocol
/// against a user-configured endpoint (#1482) — covers hosted providers and self-hosted local
/// servers (Ollama, llama.cpp, vLLM) with one wire format. Unlike `FoundationModelAssistant`,
/// unconditionally compiled: plain `URLSession` has no platform gate, which is what makes this
/// backend the fastest route to assistant parity off-Darwin (cross-platform design §8).
///
/// See docs/superpowers/specs/2026-08-16-external-llm-backend-design.md for the full design.
public actor ExternalLLMBackend: ConversationalAssistant {
    /// The user-configured endpoint. `baseURL` should NOT include the `/chat/completions`
    /// suffix — a trailing slash, if present, is trimmed and the suffix appended at request time.
    public struct Configuration: Sendable, Equatable {
        public let baseURL: URL
        public let model: String
        public let apiKey: String?

        public init(baseURL: URL, model: String, apiKey: String?) {
            self.baseURL = baseURL
            self.model = model
            self.apiKey = apiKey
        }
    }

    /// Setup-time failures — thrown by `converse` before any event is yielded, per
    /// `ConversationalAssistant`'s documented "outer throws covers setup failure" contract.
    /// Mid-stream failures (connection drop, malformed chunk) surface as `.failed` instead.
    public enum HTTPError: Error, Sendable, Equatable {
        case http(status: Int, body: String?)
        case badResponse
        /// A single SSE line (the bytes accumulated since the last newline) exceeded
        /// `maxLineBytes` — guards against unbounded memory growth from an
        /// endpoint that never emits a newline. This backend's endpoint is *user-configured* and
        /// unvetted (a typo'd URL, a hostile host, or a plain non-SSE response all reach here), so
        /// the read is bounded rather than trusted. Mirrors
        /// `ACPHTTPTransport.HTTPError.lineTooLong`. Raised mid-stream, so it surfaces as a
        /// `.failed` event, not a throw out of ``converse(prompt:context:)``.
        case lineTooLong
    }

    /// One entry in the actor-held conversation history. A private wire shape, deliberately
    /// distinct from the public `AssistantMessage` so the request format can change without
    /// affecting callers.
    struct ChatMessage: Sendable, Equatable {
        let role: String
        let content: String
    }

    static let systemInstruction = "You are an assistant helping edit and improve a website."
    static let maxPageContentCharacters = 2_000
    /// Oldest non-system messages are dropped once history exceeds this count (design doc §4.1)
    /// — bounds request payload/cost on a paid API. The system instruction (always index 0) is
    /// never counted or dropped.
    static let maxHistoryMessages = 40
    /// Default upper bound on one accumulated SSE line's byte size (see `HTTPError.lineTooLong`).
    /// Generous for a real chat-completion chunk, but not unbounded. Same value as
    /// `ACPHTTPTransport`'s.
    static let defaultMaxLineBytes = 1 << 20  // 1 MiB

    let configuration: Configuration
    let urlSession: URLSession
    let maxLineBytes: Int
    var messages: [ChatMessage] = []

    public init(configuration: Configuration, urlSession: URLSession = .shared) {
        self.init(configuration: configuration, urlSession: urlSession, maxLineBytes: Self.defaultMaxLineBytes)
    }

    /// Test seam: same as ``init(configuration:urlSession:)`` but with a caller-chosen SSE line
    /// bound, so the `HTTPError.lineTooLong` path can be exercised with a few dozen bytes instead
    /// of a megabyte. Internal — the shipping bound is not a user-facing knob.
    init(configuration: Configuration, urlSession: URLSession, maxLineBytes: Int) {
        self.configuration = configuration
        self.urlSession = urlSession
        self.maxLineBytes = maxLineBytes
    }

    /// Static, connection-independent capabilities. No tool calling or structured output (those
    /// are FoundationModels/ACP-specific); `providerName` surfaces the configured model so the
    /// chat panel's error messages ("couldn't start Custom (gpt-4o-mini): …") are legible.
    public nonisolated var capabilities: AssistantCapabilities {
        AssistantCapabilities(
            supportsStreaming: true,
            supportsStructuredOutput: false,
            supportsVision: false,
            supportsTools: false,
            maxContextTokens: nil,
            providerName: "Custom (\(configuration.model))"
        )
    }

    var activeRelay: TurnRelay?
    var activeDrainTask: Task<Void, Never>?
    /// Monotonic id of the most recently *started* turn. Bumped synchronously by `converse()`,
    /// `cancel()`, and `resetSession()` — the three things that can end a turn's claim on this
    /// actor — so any turn holding an older value is, by definition, logically superseded and must
    /// not mutate `messages` or hand out a stream (#1482 review).
    ///
    /// Replaces the earlier `activeRelay === relay` identity check, which could only see a turn
    /// that had already reached its post-`await` relay assignment. A turn suspended in
    /// `converse()`'s network `await` has no relay yet, so identity couldn't distinguish it from a
    /// live turn: a `resetSession()` landing in that window cleared `messages` and the resuming
    /// turn then appended its reply to the emptied array (permanently losing the system
    /// instruction, since `seedHistoryIfNeeded` only reseeds when `messages` is empty). A counter
    /// is set before the suspension and so covers the whole turn, relay or not.
    var turnGeneration = 0

    /// Test seam: bumps `turnGeneration` alone, without the rest of `cancel()`'s teardown (in
    /// particular, without cancelling `activeSetupTask`) — lets a test simulate "this turn was
    /// superseded" in isolation, for cases where also invoking the real setup-task cancellation
    /// would race and mask the specific behavior under test.
    func bumpTurnGenerationForTesting() {
        turnGeneration &+= 1
    }
#if canImport(Darwin)
    /// The in-flight setup-phase network call (`urlSession.bytes(for:)`, wrapped in a `Task` so it
    /// can be cancelled), retained only between `converse()` issuing the request and either
    /// throwing or handing off to `activeDrainTask`. Without this, `cancel()`/`resetSession()` —
    /// separate actor calls, not a cancellation of *this* call's own enclosing `Task` — have
    /// nothing to cancel while a turn is still waiting on response headers: `activeRelay`/
    /// `activeDrainTask` don't exist yet, so a direct `await backend.cancel()` left the underlying
    /// `URLSessionTask` running silently to its own timeout instead of tearing it down promptly,
    /// contradicting `cancel()`'s own doc comment (#1482 review). Mirrors `activeRunner`'s role
    /// for the exact same window off-Darwin.
    var activeSetupTask: Task<(URLSession.AsyncBytes, URLResponse), Error>?

    /// Test seam: lets `ExternalLLMBackendConversationTests` inject an arbitrary sentinel task
    /// into `activeSetupTask` and assert `cancel()` actually cancels it, deterministically —
    /// driving this specific race through real HTTP timing proved unreliable for the sibling
    /// stale-turn guard (see `finishTurn`'s doc comment), and the underlying stub's `stopLoading()`
    /// can't observe real cancellation either, so there's no reliable end-to-end alternative.
    func setActiveSetupTaskForTesting(_ task: Task<(URLSession.AsyncBytes, URLResponse), Error>?) {
        activeSetupTask = task
    }
#else
    // `HTTPStreamingRunner` only exists off-Darwin (see its type doc); retaining it here lets
    // `cancel()`/`resetSession()` actually tear down the in-flight network read on that platform
    // instead of merely cancelling the drain `Task`, which — unlike the Darwin `AsyncBytes` path
    // — does not by itself stop `URLSessionDataTask` from continuing to fill `bodyStream` (#1482
    // review).
    var activeRunner: HTTPStreamingRunner?
#endif

    // MARK: ConversationalAssistant

    /// `ContentAssistant`'s plain-text path, implemented by flattening ``converse(prompt:context:)``'s
    /// event stream — same shape as `ACPAssistant.generate`.
    public func generate(prompt: String, context: AssistantContext) async throws -> AsyncThrowingStream<String, Error> {
        let events = try await converse(prompt: prompt, context: context)
        return AsyncThrowingStream { continuation in
            Task {
                for await event in events {
                    switch event {
                    case .textDelta(let text): continuation.yield(text)
                    case .failed(let message): continuation.finish(throwing: AssistantError.streamFailed(message)); return
                    case .turnComplete, .backendExited: continuation.finish(); return
                    default: break
                    }
                }
                continuation.finish()
            }
        }
    }

#if compiler(>=6.4) && canImport(FoundationModels)
    /// Always throws: guided generation is defined by FoundationModels' `Generable` machinery,
    /// which a plain HTTP chat-completions endpoint can't participate in.
    public func generateStructured<T: Generable & Sendable>(prompt: String, context: AssistantContext, resultType: T.Type) async throws -> T {
        throw AssistantError.unsupported("External LLM endpoints do not support FoundationModels guided generation")
    }
#endif

    /// Streams one conversational turn. Performs the HTTP request and validates the initial
    /// response *before* returning the stream — a bad response (auth failure, wrong model, DNS
    /// failure) is a setup failure per `ConversationalAssistant`'s documented contract, not an
    /// in-band `.failed` event. Only a failure *after* streaming begins (dropped connection,
    /// malformed chunk) becomes `.failed`.
    ///
    /// - Important: The turn's user message is *staged locally* for the outgoing request and only
    ///   joins `messages` in `finishTurn`, paired with the assistant reply it earned. Appending
    ///   it up front (as an earlier version did) left it behind whenever the turn didn't complete
    ///   — a cancel, a bad API key, a mid-stream drop — so history accumulated unpaired `user`
    ///   entries that were re-sent on every later request (and that some OpenAI-*compatible*
    ///   servers reject outright as consecutive same-role messages). Staging makes a failed turn
    ///   leave no trace, which is also what "the turn didn't happen" should mean to the owner
    ///   (#1482 review).
    /// - Throws: `CancellationError` if the turn is superseded while its request is in flight; see
    ///   `turnGeneration`.
    public func converse(prompt: String, context: AssistantContext) async throws -> AsyncStream<AssistantEvent> {
        // Claim a new generation *before* the network `await` below, so this turn is identifiable
        // (and supersedable) for its whole lifetime rather than only after the relay exists.
        turnGeneration &+= 1
        let myGeneration = turnGeneration

        // Clear `activeRelay`/`activeDrainTask` synchronously here (not just cancel the old
        // relay/task) so a still-draining previous turn can't deliver into a relay this actor no
        // longer considers current.
        activeRelay?.cancel()
        activeRelay = nil
        activeDrainTask?.cancel()
        activeDrainTask = nil
#if canImport(Darwin)
        activeSetupTask?.cancel()
        activeSetupTask = nil
#else
        activeRunner?.cancel()
        activeRunner = nil
#endif

        seedHistoryIfNeeded(context: context)
        let userMessage = ChatMessage(role: "user", content: Self.turnPrompt(for: prompt, context: context))
        let request = try makeURLRequest(messages: Self.trimmed(messages + [userMessage]))

#if canImport(Darwin)
        // Wrapped in its own `Task` (rather than a bare `try await urlSession.bytes(for:
        // request)`) so `cancel()`/`resetSession()` have something to actually cancel while this
        // turn is still in its setup phase — see `activeSetupTask`'s doc comment. Cancelling this
        // task propagates into the underlying `URLSessionTask` (documented `URLSession` async-API
        // cancellation behavior), tearing the connection down instead of leaving it to run silently
        // to its own timeout (#1482 review).
        let setupTask = Task { try await urlSession.bytes(for: request) }
        activeSetupTask = setupTask
        let asyncBytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (asyncBytes, response) = try await setupTask.value
        } catch {
            activeSetupTask = nil
            // A real network failure (DNS, connection refused) and a cancellation this actor
            // itself triggered both surface here as *some* thrown error — normalize to the same
            // `CancellationError()` the staleness check below throws for a superseded turn, so a
            // cancelled/superseded turn never surfaces a confusing raw network error to the caller.
            throw turnGeneration == myGeneration ? error : CancellationError()
        }
        activeSetupTask = nil
#else
        let runner = HTTPStreamingRunner()
        activeRunner = runner
        let response = try await runner.start(request, configuration: urlSession.configuration)
#endif
        guard let http = response as? HTTPURLResponse else { throw HTTPError.badResponse }

        // Check staleness *before* interpreting the response status: a turn that was
        // cancelled/superseded while its request was in flight (actor isolation only serializes
        // *between* `await` points) must always discard silently as `CancellationError`, never
        // surface as a misleading HTTP error (e.g. a stray 401) for a request the caller already
        // gave up on. Checking status first would let a non-2xx response for an already-abandoned
        // turn masquerade as a real failure (#1482 review).
        // Check staleness *before* interpreting the response status: a turn that was
        // cancelled/superseded while its request was in flight (actor isolation only serializes
        // *between* `await` points) must always discard silently as `CancellationError`, never
        // surface as a misleading HTTP error (e.g. a stray 401) for a request the caller already
        // gave up on. Checking status first would let a non-2xx response for an already-abandoned
        // turn masquerade as a real failure (#1482 review).
        guard turnGeneration == myGeneration else {
#if canImport(Darwin)
            asyncBytes.task.cancel()  // off-Darwin the superseder already cancelled `activeRunner`
#endif
            throw CancellationError()
        }

        guard (200...299).contains(http.statusCode) else {
#if canImport(Darwin)
            let body = await Self.readBounded(asyncBytes)
#else
            let body = await Self.readBounded(runner)
#endif
            throw HTTPError.http(status: http.statusCode, body: body)
        }

        let (stream, continuation) = AsyncStream.makeStream(of: AssistantEvent.self)
        let relay = TurnRelay(continuation)
        activeRelay = relay
        relay.deliver(.started(model: configuration.model, toolNames: []))

#if canImport(Darwin)
        let drainTask = Task { [asyncBytes] in
            await self.drainSSE(asyncBytes: asyncBytes, userMessage: userMessage, generation: myGeneration, relay: relay)
        }
#else
        let drainTask = Task { [runner] in
            await self.drainSSE(runner: runner, userMessage: userMessage, generation: myGeneration, relay: relay)
        }
#endif
        activeDrainTask = drainTask
        continuation.onTermination = { _ in relay.detach() }
        return stream
    }

    /// Ends the current turn for the consumer (`.cancelled`) and stops the underlying network
    /// read — unlike `FoundationModelAssistant.cancel()`, which must leave the on-device stream
    /// running (cancelling it mid-flight traps the process), cancelling a plain HTTP read is safe
    /// and frees the connection promptly.
    ///
    /// The cancelled turn contributes nothing to `messages`: its user message was never staged
    /// into history, and the generation bump keeps its `finishTurn` from committing the partial
    /// reply the consumer already stopped seeing.
    public func cancel() async {
        turnGeneration &+= 1
        activeRelay?.cancel()
        activeRelay = nil
        activeDrainTask?.cancel()
        activeDrainTask = nil
#if canImport(Darwin)
        activeSetupTask?.cancel()
        activeSetupTask = nil
#else
        activeRunner?.cancel()
        activeRunner = nil
#endif
    }

    public func resetSession() async {
        turnGeneration &+= 1
        activeRelay?.cancel()
        activeRelay = nil
        activeDrainTask?.cancel()
        activeDrainTask = nil
#if canImport(Darwin)
        activeSetupTask?.cancel()
        activeSetupTask = nil
#else
        activeRunner?.cancel()
        activeRunner = nil
#endif
        messages = []
    }

    // MARK: History

    /// Seeds the fixed system instruction (and any pre-populated `context.conversationHistory`,
    /// for a caller that supplies it — the primary chat-panel call site never does, per the
    /// design doc §3) the first time this session is used. A no-op on every later turn.
    func seedHistoryIfNeeded(context: AssistantContext) {
        guard messages.isEmpty else { return }
        messages.append(ChatMessage(role: "system", content: Self.systemInstruction))
        for turn in context.conversationHistory {
            messages.append(ChatMessage(role: turn.role.externalLLMWireRole, content: turn.content))
        }
    }

    /// Drops the oldest non-system messages once history exceeds `maxHistoryMessages` — the
    /// system instruction at index 0 is always kept.
    static func trimmed(_ messages: [ChatMessage]) -> [ChatMessage] {
        let cap = maxHistoryMessages + 1 // +1 for the always-kept system instruction
        guard messages.count > cap else { return messages }
        var trimmed = messages
        trimmed.removeSubrange(1..<(1 + (messages.count - cap)))
        return trimmed
    }

    func trimHistoryIfNeeded() {
        messages = Self.trimmed(messages)
    }

    /// Commits the turn — appends its user message and the completed assistant reply as a pair (so
    /// the next request carries both), trims if needed, and ends the turn with `.turnComplete`.
    ///
    /// - Important: Guarded on `generation` still being `turnGeneration` — `drainSSE`'s
    ///   normal-completion path (the SSE body ends, with or without a `[DONE]` sentinel) calls
    ///   this with no prior `Task.checkCancellation()` check, so a `resetSession()`/`cancel()`/
    ///   superseding `converse()` that raced this same turn (actor isolation only serializes
    ///   *between* `await` points, and `drainSSE` suspends at every byte it awaits) can already
    ///   have ended it by the time this runs. Unguarded, this would still mutate `messages` —
    ///   after `resetSession()` cleared it, that means a history with no system instruction,
    ///   permanently (`seedHistoryIfNeeded` only reseeds when `messages` is empty); racing a
    ///   superseding `converse()` instead, it would interleave the old turn's pair into the new
    ///   turn's history. All three bump `turnGeneration` synchronously, so the comparison is
    ///   exactly "is this turn still current" (#1482 review).
    /// - Note: Internal rather than `private` — same testability pattern as
    ///   `seedHistoryIfNeeded`/`trimHistoryIfNeeded`/`makeURLRequest` below — so
    ///   `ExternalLLMBackendConversationTests` can exercise the guard above directly and
    ///   deterministically, alongside the end-to-end
    ///   `resetSessionDuringSetupAwaitLeavesNoHistory` test that drives the *pre*-relay half of
    ///   the same race through a gated `URLProtocol` stub.
    func finishTurn(userMessage: ChatMessage, accumulatedText: String, usage: AssistantUsage?, generation: Int, relay: TurnRelay) {
        guard turnGeneration == generation else {
            // Belt-and-braces: whoever superseded this turn already cancelled its relay (it was
            // `activeRelay` at the time), but ending it here too guarantees no consumer is left
            // waiting on a stream that will never produce a terminal event.
            relay.cancel()
            return
        }
        messages.append(userMessage)
        messages.append(ChatMessage(role: "assistant", content: accumulatedText))
        trimHistoryIfNeeded()
        relay.complete(.turnComplete(usage))
    }

    // MARK: SSE draining

#if canImport(Darwin)
    private func drainSSE(asyncBytes: URLSession.AsyncBytes, userMessage: ChatMessage, generation: Int, relay: TurnRelay) async {
        var dataLines: [String] = []
        var pendingLineBytes = Data()
        var accumulatedText = ""
        var usage: AssistantUsage?

        func handleLine(_ line: String) -> Bool {
            if line.isEmpty {
                guard !dataLines.isEmpty else { return false }
                let payload = dataLines.joined(separator: "\n")
                dataLines = []
                if payload == "[DONE]" { return true }
                guard let chunk = Self.decodeChunk(payload) else { return false }
                if let delta = chunk.choices?.first?.delta?.content, !delta.isEmpty {
                    accumulatedText += delta
                    relay.deliver(.textDelta(delta))
                }
                if let chunkUsage = chunk.usage {
                    usage = AssistantUsage(inputTokens: chunkUsage.promptTokens, outputTokens: chunkUsage.completionTokens)
                }
                return false
            }
            if line.hasPrefix("data:") {
                let v = line.dropFirst("data:".count)
                dataLines.append(v.hasPrefix(" ") ? String(v.dropFirst()) : String(v))
            }
            return false
        }

        do {
            for try await byte in asyncBytes {
                try Task.checkCancellation()
                pendingLineBytes.append(byte)
                guard byte == 0x0A else {
                    guard pendingLineBytes.count <= maxLineBytes else { throw HTTPError.lineTooLong }
                    continue
                }
                var line = String(decoding: pendingLineBytes.dropLast(), as: UTF8.self)
                if line.hasSuffix("\r") { line.removeLast() }
                pendingLineBytes.removeAll(keepingCapacity: true)
                if handleLine(line) {
                    finishTurn(userMessage: userMessage, accumulatedText: accumulatedText, usage: usage, generation: generation, relay: relay)
                    return
                }
            }
        } catch {
            relay.complete(.failed(message: "\(error)"))
            return
        }
        if !pendingLineBytes.isEmpty {
            _ = handleLine(String(decoding: pendingLineBytes, as: UTF8.self))
        }
        finishTurn(userMessage: userMessage, accumulatedText: accumulatedText, usage: usage, generation: generation, relay: relay)
    }

    private static func readBounded(_ bytes: URLSession.AsyncBytes, limit: Int = 4_096) async -> String? {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= limit { break }
            }
        } catch {
            // A partial read is still useful for an error message below.
        }
        // Whether we stopped at `limit` or the stream ended naturally, there's nothing more this
        // caller wants — cancel proactively so a large or never-ending body (from a misconfigured
        // or hostile user-supplied endpoint) doesn't keep arriving into a stream nothing reads
        // (#1482 review). A no-op if the task already finished.
        bytes.task.cancel()
        return data.isEmpty ? nil : String(decoding: data, as: UTF8.self)
    }
#else
    private func drainSSE(runner: HTTPStreamingRunner, userMessage: ChatMessage, generation: Int, relay: TurnRelay) async {
        var dataLines: [String] = []
        var pendingLineBytes = Data()
        var accumulatedText = ""
        var usage: AssistantUsage?

        func handleLine(_ line: String) -> Bool {
            if line.isEmpty {
                guard !dataLines.isEmpty else { return false }
                let payload = dataLines.joined(separator: "\n")
                dataLines = []
                if payload == "[DONE]" { return true }
                guard let chunk = Self.decodeChunk(payload) else { return false }
                if let delta = chunk.choices?.first?.delta?.content, !delta.isEmpty {
                    accumulatedText += delta
                    relay.deliver(.textDelta(delta))
                }
                if let chunkUsage = chunk.usage {
                    usage = AssistantUsage(inputTokens: chunkUsage.promptTokens, outputTokens: chunkUsage.completionTokens)
                }
                return false
            }
            if line.hasPrefix("data:") {
                let v = line.dropFirst("data:".count)
                dataLines.append(v.hasPrefix(" ") ? String(v.dropFirst()) : String(v))
            }
            return false
        }

        do {
            for try await chunk in runner.bodyStream {
                try Task.checkCancellation()
                for byte in chunk {
                    pendingLineBytes.append(byte)
                    guard byte == 0x0A else {
                        guard pendingLineBytes.count <= maxLineBytes else { throw HTTPError.lineTooLong }
                        continue
                    }
                    var line = String(decoding: pendingLineBytes.dropLast(), as: UTF8.self)
                    if line.hasSuffix("\r") { line.removeLast() }
                    pendingLineBytes.removeAll(keepingCapacity: true)
                    if handleLine(line) {
                        finishTurn(userMessage: userMessage, accumulatedText: accumulatedText, usage: usage, generation: generation, relay: relay)
                        return
                    }
                }
            }
        } catch {
            relay.complete(.failed(message: "\(error)"))
            return
        }
        if !pendingLineBytes.isEmpty {
            _ = handleLine(String(decoding: pendingLineBytes, as: UTF8.self))
        }
        finishTurn(userMessage: userMessage, accumulatedText: accumulatedText, usage: usage, generation: generation, relay: relay)
    }

    private static func readBounded(_ runner: HTTPStreamingRunner, limit: Int = 4_096) async -> String? {
        var data = Data()
        do {
            for try await chunk in runner.bodyStream {
                data.append(chunk)
                if data.count >= limit { break }
            }
        } catch {
            // A partial read is still useful for an error message below.
        }
        // See the Darwin variant's comment — cancel proactively regardless of why the loop ended
        // (#1482 review). `HTTPStreamingRunner.cancel()` is documented idempotent.
        runner.cancel()
        return data.isEmpty ? nil : String(decoding: data, as: UTF8.self)
    }
#endif

    // MARK: Wire format

    struct WireMessage: Encodable {
        let role: String
        let content: String
    }

    struct ChatCompletionRequest: Encodable {
        let model: String
        let messages: [WireMessage]
        let stream: Bool
        let streamOptions: StreamOptions

        struct StreamOptions: Encodable {
            let includeUsage: Bool
            enum CodingKeys: String, CodingKey { case includeUsage = "include_usage" }
        }
        enum CodingKeys: String, CodingKey {
            case model, messages, stream
            case streamOptions = "stream_options"
        }
    }

    struct ChatCompletionChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String? }
            let delta: Delta?
        }
        struct Usage: Decodable {
            let promptTokens: Int
            let completionTokens: Int
            enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens"
                case completionTokens = "completion_tokens"
            }
        }
        let choices: [Choice]?
        let usage: Usage?
    }

    /// Builds the POST request for one turn: `{baseURL}/chat/completions` (trailing slash on
    /// `baseURL` trimmed first), streaming enabled, `Authorization: Bearer` only when a key is
    /// configured (self-hosted servers often need none).
    func makeURLRequest(messages: [ChatMessage]) throws -> URLRequest {
        var base = configuration.baseURL.absoluteString
        if base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/chat/completions") else { throw HTTPError.badResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let apiKey = configuration.apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let body = ChatCompletionRequest(
            model: configuration.model,
            messages: messages.map { WireMessage(role: $0.role, content: $0.content) },
            stream: true,
            streamOptions: .init(includeUsage: true)
        )
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    /// Decodes one SSE `data:` payload (already joined across its lines) as a chat-completion
    /// chunk. Returns `nil` for anything that doesn't parse — callers treat that as "ignore this
    /// line" rather than a hard failure, since a comment/keep-alive line is valid SSE traffic.
    static func decodeChunk(_ payload: String) -> ChatCompletionChunk? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ChatCompletionChunk.self, from: data)
    }

    /// Folds `context`'s route/current-page-content into the turn's user message, then appends
    /// the caller's prompt — the same shape as `FoundationModelAssistant.turnPrompt`, but
    /// independently implemented: that type's helpers live inside its
    /// `#if compiler(>=6.4) && canImport(FoundationModels)` gate, unavailable to this ungated type.
    static func turnPrompt(for prompt: String, context: AssistantContext) -> String {
        var lines: [String] = []
        if let route = context.currentPageRoute { lines.append("The user is viewing the page at \(route).") }
        if let content = context.currentPageContent {
            lines.append("Current page content:\n\(truncatedPageContent(content))")
        }
        lines.append(prompt)
        return lines.joined(separator: "\n")
    }

    static func truncatedPageContent(_ content: String) -> String {
        guard content.count > maxPageContentCharacters else { return content }
        return String(content.prefix(maxPageContentCharacters)) + "…"
    }
}

/// Maps the provider-neutral `AssistantMessage.Role` onto the chat-completions wire role string
/// — `ExternalLLMBackend`-only, kept next to the type rather than as a general `AssistantMessage`
/// extension since no other backend needs this mapping (both `FoundationModelAssistant` and
/// `ACPAssistant` maintain their own session state instead of round-tripping `AssistantMessage`).
private extension AssistantMessage.Role {
    var externalLLMWireRole: String {
        switch self {
        case .user: return "user"
        case .assistant: return "assistant"
        case .system: return "system"
        }
    }
}
