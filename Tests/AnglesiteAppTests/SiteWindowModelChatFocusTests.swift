import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteAppCore
#if compiler(>=6.4)
import FoundationModels
#endif

/// View ▸ Show/Hide Chat (⌃⌘K) and the toolbar Chat button both go through
/// `SiteWindowModel.toggleChat()` / `showChat()`, which present the pane *and* ask `ChatModel`
/// to put keyboard focus in the prompt input (#1640). The focus request is a latched flag on
/// `ChatModel` that `ChatView` consumes, because the pane is usually not mounted yet when the
/// command fires — these tests pin down the latch semantics the view relies on.
@Suite("SiteWindowModel chat focus (#1640)")
@MainActor
struct SiteWindowModelChatFocusTests {
    private func makeModel() -> SiteWindowModel {
        SiteWindowModel(
            contentGraph: SiteContentGraph(),
            knowledgeIndex: SiteKnowledgeIndex(),
            semanticRanker: nil,
            conventionsEngine: ProjectConventionsEngine(),
            runtimeFactory: NeverStartedSiteRuntimeFactory(),
            contentIndexerStore: ContentIndexerStore()
        )
    }

    private func makeChat() -> ChatModel {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-focus-\(UUID().uuidString)", isDirectory: true)
        return ChatModel(
            siteID: "test",
            siteDirectory: dir,
            configDirectory: dir,
            assistant: StubConversationalAssistant()
        )
    }

    @Test("toggleChat presents the pane, then hides it again")
    func toggleFlipsPresentation() {
        let model = makeModel()
        #expect(model.chatPresented == false)
        model.toggleChat()
        #expect(model.chatPresented == true)
        model.toggleChat()
        #expect(model.chatPresented == false)
    }

    @Test("toggleChat tolerates a not-yet-created ChatModel")
    func toggleWithoutChatModel() {
        let model = makeModel()
        #expect(model.chat == nil)
        model.toggleChat()
        #expect(model.chatPresented == true)
    }

    // View ▸ Show Chat is enabled as soon as the window model exists, before `loadAndStart` has
    // created `chat` — the request must survive until the model is assigned (review on #1720).
    @Test("showChat before ChatModel exists requests focus once chat is assigned")
    func showBeforeChatExistsRequestsFocusOnAssignment() {
        let model = makeModel()
        model.showChat()
        #expect(model.chat == nil)
        #expect(model.chatPresented == true)

        let chat = makeChat()
        #expect(chat.inputFocusRequested == false)
        model.chat = chat
        #expect(chat.inputFocusRequested == true)
        // ChatView's appear-time `.task` consumes it exactly once when the pane first mounts.
        #expect(chat.consumeInputFocusRequest() == true)
        #expect(chat.consumeInputFocusRequest() == false)
    }

    @Test("hiding the pane again before ChatModel exists cancels the deferred focus request")
    func hideBeforeChatExistsCancelsDeferredFocus() {
        let model = makeModel()
        model.toggleChat()
        model.toggleChat()
        #expect(model.chatPresented == false)

        let chat = makeChat()
        model.chat = chat
        #expect(chat.inputFocusRequested == false)
    }

    @Test("assigning ChatModel with the pane never requested does not request focus")
    func assignChatWithoutShowDoesNotRequestFocus() {
        let model = makeModel()
        let chat = makeChat()
        model.chat = chat
        #expect(model.chatPresented == false)
        #expect(chat.inputFocusRequested == false)
    }

    @Test("showing the pane requests input focus; hiding it does not")
    func showRequestsFocusHideDoesNot() {
        let model = makeModel()
        let chat = makeChat()
        model.chat = chat

        model.toggleChat()
        #expect(model.chatPresented == true)
        #expect(chat.inputFocusRequested == true)

        // ChatView consumes the request once it has moved focus.
        #expect(chat.consumeInputFocusRequest() == true)
        #expect(chat.inputFocusRequested == false)

        model.toggleChat()
        #expect(model.chatPresented == false)
        #expect(chat.inputFocusRequested == false)
    }

    @Test("showChat on an already-open pane keeps it open and re-requests focus")
    func showChatWhenAlreadyPresented() {
        let model = makeModel()
        let chat = makeChat()
        model.chat = chat

        model.showChat()
        _ = chat.consumeInputFocusRequest()
        #expect(chat.inputFocusRequested == false)

        model.showChat()
        #expect(model.chatPresented == true)
        #expect(chat.inputFocusRequested == true)
    }

    @Test("consuming a focus request is one-shot")
    func consumeIsOneShot() {
        let chat = makeChat()
        #expect(chat.consumeInputFocusRequest() == false)
        chat.requestInputFocus()
        #expect(chat.consumeInputFocusRequest() == true)
        #expect(chat.consumeInputFocusRequest() == false)
    }
}

private actor StubConversationalAssistant: ConversationalAssistant {
    nonisolated var capabilities: AssistantCapabilities {
        AssistantCapabilities(
            supportsStreaming: true, supportsStructuredOutput: false, supportsVision: false,
            supportsTools: false, maxContextTokens: nil, providerName: "Stub"
        )
    }

    func converse(prompt: String, context: AssistantContext) async throws -> AsyncStream<AssistantEvent> {
        AsyncStream { $0.finish() }
    }

    func generate(prompt: String, context: AssistantContext) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    #if compiler(>=6.4)
    func generateStructured<T: Generable & Sendable>(prompt: String, context: AssistantContext, resultType: T.Type) async throws -> T {
        throw AssistantError.unsupported("stub")
    }
    #endif

    func cancel() async {}
    func resetSession() async {}
}
