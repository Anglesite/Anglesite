import Foundation

/// `URLSession`-based backend speaking a single OpenAI-compatible chat-completions protocol
/// against a user-configured endpoint (#1482) — covers hosted providers and self-hosted local
/// servers (Ollama, llama.cpp, vLLM) with one wire format. Unlike `FoundationModelAssistant`,
/// unconditionally compiled: plain `URLSession` has no platform gate, which is what makes this
/// backend the fastest route to assistant parity off-Darwin (cross-platform design §8).
///
/// See docs/superpowers/specs/2026-08-16-external-llm-backend-design.md for the full design.
/// `ConversationalAssistant` conformance (converse/cancel/resetSession/generate/generateStructured)
/// is added in a later slice of this same file's history — see that type's doc comment once added.
public actor ExternalLLMBackend {
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

    let configuration: Configuration
    let urlSession: URLSession
    var messages: [ChatMessage] = []

    public init(configuration: Configuration, urlSession: URLSession = .shared) {
        self.configuration = configuration
        self.urlSession = urlSession
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
