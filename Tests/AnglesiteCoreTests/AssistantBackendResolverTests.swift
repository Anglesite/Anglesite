import Testing
import Foundation
@testable import AnglesiteCore
import AnglesiteTestSupport

final class AssistantBackendResolverTests {
    private let tempDir: URL
    private let persistenceURL: URL
    private let fileManager = FileManager.default
    private let scratch = TemporaryUserDefaults()
    private var defaults: UserDefaults { scratch.defaults }

    init() throws {
        tempDir = fileManager.temporaryDirectory.appendingPathComponent("assistant-backend-resolver-\(UUID().uuidString)", isDirectory: true)
        persistenceURL = tempDir.appendingPathComponent("acp-agents.json")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    deinit {
        try? fileManager.removeItem(at: tempDir)
        scratch.cleanup()
    }

    @Test("activeAgentID parses a well-formed acp: prefix") func activeAgentIDParsesWellFormedPrefix() {
        let id = UUID()
        #expect(AssistantBackendResolver.activeAgentID(from: "acp:\(id.uuidString)") == id)
    }

    @Test("activeAgentID returns nil for foundationModels") func activeAgentIDReturnsNilForFoundationModels() {
        #expect(AssistantBackendResolver.activeAgentID(from: "foundationModels") == nil)
    }

    @Test("activeAgentID returns nil for a malformed UUID") func activeAgentIDReturnsNilForMalformedUUID() {
        #expect(AssistantBackendResolver.activeAgentID(from: "acp:not-a-uuid") == nil)
    }

    @Test("resolveActiveACPAssistant returns nil when backend is foundationModels") func resolveReturnsNilWhenBackendIsFoundationModels() {
        let settings = AppSettings(defaults: defaults)
        settings.activeAssistantBackend = "foundationModels"
        let resolved = AssistantBackendResolver.resolveActiveACPAssistant(
            siteID: "site-1", sourceDirectory: URL(fileURLWithPath: "/tmp/site-1"),
            containerControlProvider: { nil },
            agentStore: ACPAgentStore(persistenceURL: persistenceURL), appSettings: settings
        )
        #expect(resolved == nil)
    }

    @Test("resolveActiveACPAssistant returns nil when the referenced agent is missing") func resolveReturnsNilWhenAgentMissing() {
        let settings = AppSettings(defaults: defaults)
        settings.activeAssistantBackend = "acp:\(UUID().uuidString)"
        let resolved = AssistantBackendResolver.resolveActiveACPAssistant(
            siteID: "site-1", sourceDirectory: URL(fileURLWithPath: "/tmp/site-1"),
            containerControlProvider: { nil },
            agentStore: ACPAgentStore(persistenceURL: persistenceURL), appSettings: settings
        )
        #expect(resolved == nil)
    }

    @Test("resolveActiveACPAssistant returns an assistant when the referenced agent exists") func resolveReturnsAssistantWhenAgentExists() throws {
        let store = ACPAgentStore(persistenceURL: persistenceURL)
        let connection = ACPAgentConnection(id: UUID(), name: "Test Agent", transport: .remote(url: URL(string: "https://example.com")!))
        try store.add(connection)
        let settings = AppSettings(defaults: defaults)
        settings.activeAssistantBackend = "acp:\(connection.id.uuidString)"
        let resolved = AssistantBackendResolver.resolveActiveACPAssistant(
            siteID: "site-1", sourceDirectory: URL(fileURLWithPath: "/tmp/site-1"),
            containerControlProvider: { nil },
            agentStore: store, appSettings: settings
        )
        #expect(resolved != nil)
        #expect(resolved?.capabilities.providerName == "Test Agent")
    }

    @Test("resolveActiveExternalLLMAssistant returns nil when backend is not externalLLM")
    func resolveExternalLLMReturnsNilWhenNotSelected() {
        let settings = AppSettings(defaults: defaults)
        settings.activeAssistantBackend = "foundationModels"
        settings.externalLLMBaseURL = URL(string: "https://api.example.com/v1")
        settings.externalLLMModel = "gpt-4o-mini"
        let resolved = AssistantBackendResolver.resolveActiveExternalLLMAssistant(appSettings: settings)
        #expect(resolved == nil)
    }

    @Test("resolveActiveExternalLLMAssistant returns nil when no base URL is configured")
    func resolveExternalLLMReturnsNilWhenNoBaseURL() {
        let settings = AppSettings(defaults: defaults)
        settings.activeAssistantBackend = "externalLLM"
        settings.externalLLMModel = "gpt-4o-mini"
        let resolved = AssistantBackendResolver.resolveActiveExternalLLMAssistant(appSettings: settings)
        #expect(resolved == nil)
    }

    @Test("resolveActiveExternalLLMAssistant returns nil when the model is blank")
    func resolveExternalLLMReturnsNilWhenModelBlank() {
        let settings = AppSettings(defaults: defaults)
        settings.activeAssistantBackend = "externalLLM"
        settings.externalLLMBaseURL = URL(string: "https://api.example.com/v1")
        settings.externalLLMModel = "   "
        let resolved = AssistantBackendResolver.resolveActiveExternalLLMAssistant(appSettings: settings)
        #expect(resolved == nil)
    }

    @Test("resolveActiveExternalLLMAssistant returns a configured assistant when fully set up")
    func resolveExternalLLMReturnsAssistantWhenConfigured() {
        let settings = AppSettings(defaults: defaults)
        settings.activeAssistantBackend = "externalLLM"
        settings.externalLLMBaseURL = URL(string: "https://api.example.com/v1")
        settings.externalLLMModel = "gpt-4o-mini"
        let secretStore = InMemorySecretStore()
        try? secretStore.writeExternalLLMAPIKey("sk-test")
        let resolved = AssistantBackendResolver.resolveActiveExternalLLMAssistant(appSettings: settings, secretStore: secretStore)
        #expect(resolved != nil)
        #expect(resolved?.capabilities.providerName == "Custom (gpt-4o-mini)")
    }
}
