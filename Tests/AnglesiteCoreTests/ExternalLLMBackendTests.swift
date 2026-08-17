import Testing
import Foundation
@testable import AnglesiteCore

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
