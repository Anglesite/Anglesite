import Testing
import Foundation
@testable import AnglesiteCore

#if compiler(>=6.4) && canImport(FoundationModels)
import FoundationModels
#endif

@Suite("WritingHelpPrompt")
struct WritingHelpPromptTests {
    @Test("prompt contains the instruction, the text, and a verbatim-output directive")
    func promptContainsCoreParts() {
        let p = WritingHelpPrompt.build(
            instruction: "Make this noticeably shorter while keeping the essential meaning.",
            text: "We are so excited to bring you our brand new product line.",
            preamble: nil)
        #expect(p.contains("Make this noticeably shorter"))
        #expect(p.contains("We are so excited to bring you our brand new product line."))
        #expect(p.contains("only the rewritten text"))
    }

    @Test("preamble, when present, is prefixed ahead of the instruction")
    func preambleIsPrefixed() {
        let p = WritingHelpPrompt.build(
            instruction: "Rewrite this to be clearer.", text: "hello",
            preamble: "Match this site's voice:\nWrite in a warm tone.")
        #expect(p.hasPrefix("Match this site's voice:"))
        let preambleRange = p.range(of: "Write in a warm tone.")!
        let instructionRange = p.range(of: "Rewrite this to be clearer.")!
        #expect(preambleRange.lowerBound < instructionRange.lowerBound)
    }
}

// Gated like the type under test — `WritingHelpAssisting`'s default implementation references
// `GeneratedRewrite` (`@Generable`, Xcode-27 only). The logic here is model-free where possible
// (prompt building above); the assistant itself is exercised through a `ContentAssistant` fake.
#if compiler(>=6.4) && canImport(FoundationModels)

@Suite("FoundationModelWritingHelpAssistant")
struct FoundationModelWritingHelpAssistantTests {
    /// Records log messages so tests can verify error logging ("logs are sacred").
    private actor LogRecorder {
        private(set) var messages: [String] = []
        func record(_ message: String) { messages.append(message) }
    }

    private struct FakeAssistant: ContentAssistant {
        var structuredResult: Result<GeneratedRewrite, Error>
        var capabilities: AssistantCapabilities {
            AssistantCapabilities(
                supportsStreaming: false, supportsStructuredOutput: true, supportsVision: false,
                supportsTools: false, maxContextTokens: 4096, providerName: "Fake")
        }
        func generate(prompt: String, context: AssistantContext) async throws -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func generateStructured<T: Generable & Sendable>(
            prompt: String, context: AssistantContext, resultType: T.Type
        ) async throws -> T {
            switch structuredResult {
            case .success(let value):
                guard let typed = value as? T else { fatalError("unexpected resultType in test fake") }
                return typed
            case .failure(let error):
                throw error
            }
        }
    }

    @Test("returns .rewritten with the model's text on success")
    func returnsRewrittenOnSuccess() async {
        let assistant = FoundationModelWritingHelpAssistant(
            assistantFactory: { FakeAssistant(structuredResult: .success(GeneratedRewrite(rewrittenText: "Shorter version."))) })
        let outcome = await assistant.rewrite(
            text: "A much longer original sentence.", instruction: "Tighten this.",
            preamble: nil, siteID: "site-1", siteDirectory: URL(fileURLWithPath: "/tmp/site"))
        #expect(outcome == .rewritten("Shorter version."))
    }

    @Test("returns .unavailable with a clear message when the assistant factory yields nil")
    func returnsUnavailableWhenNoAssistant() async {
        let assistant = FoundationModelWritingHelpAssistant(assistantFactory: { nil })
        let outcome = await assistant.rewrite(
            text: "x", instruction: "y", preamble: nil, siteID: "site-1",
            siteDirectory: URL(fileURLWithPath: "/tmp/site"))
        guard case .unavailable(let message) = outcome else {
            Issue.record("expected .unavailable, got \(outcome)")
            return
        }
        #expect(message.contains("Apple Intelligence") || message.contains("available"))
    }

    @Test("returns .unavailable, not a thrown error, when generateStructured fails")
    func returnsUnavailableOnGenerationFailure() async {
        struct Boom: Error {}
        let assistant = FoundationModelWritingHelpAssistant(
            assistantFactory: { FakeAssistant(structuredResult: .failure(Boom())) })
        let outcome = await assistant.rewrite(
            text: "x", instruction: "y", preamble: nil, siteID: "site-1",
            siteDirectory: URL(fileURLWithPath: "/tmp/site"))
        guard case .unavailable = outcome else {
            Issue.record("expected .unavailable, got \(outcome)")
            return
        }
    }

    @Test("logs the error when generation fails (\"logs are sacred\")")
    func logsErrorOnGenerationFailure() async {
        struct TestError: Error, CustomStringConvertible {
            var description: String { "malformed output" }
        }
        let recorder = LogRecorder()
        let assistant = FoundationModelWritingHelpAssistant(
            assistantFactory: { FakeAssistant(structuredResult: .failure(TestError())) },
            log: { await recorder.record($0) }
        )
        _ = await assistant.rewrite(
            text: "x", instruction: "y", preamble: nil, siteID: "site-1",
            siteDirectory: URL(fileURLWithPath: "/tmp/site"))
        let messages = await recorder.messages
        #expect(messages.count == 1)
        #expect(messages.first?.contains("writing-help generation failed") ?? false)
        #expect(messages.first?.contains("malformed output") ?? false)
    }
}
#endif
