import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteAppCore

#if compiler(>=6.4)
import FoundationModels
#endif

/// Actor-based capture, not a plain `var` mutated inside `Task { }` — the assistant-builder
/// closure runs synchronously but needs to await the (async) snapshot provider, so the capture
/// itself must be safe to mutate from that detached `Task`. Matches the `CapturingConversationalAssistant`
/// idiom already used in `KnowledgeAugmentedAssistantTests`.
private actor SnapshotCapture {
    private(set) var received: SiteGraphExplorerSnapshot?
    func capture(_ snapshot: SiteGraphExplorerSnapshot) { received = snapshot }
}

@Suite("SiteAssistantSessionFactory")
@MainActor
struct SiteAssistantSessionFactoryTests {
    @Test("makeSession forwards the graph snapshot provider to the assistant builder")
    func forwardsGraphSnapshotProvider() async throws {
        let expected = SiteGraphExplorerSnapshot(
            nodes: [SiteGraphNode(id: "n1", kind: .page, title: "Home", detail: nil, filePath: "src/pages/index.astro", route: "/")],
            edges: []
        )
        let capture = SnapshotCapture()
        var dependencies = SiteAssistantSessionFactory.Dependencies.live
        dependencies.assistant = { _, _, _, _, _, _, _, _, _, _, graphSnapshotProvider in
            Task {
                let snapshot = await graphSnapshotProvider()
                await capture.capture(snapshot)
            }
            return StubConversationalAssistant()
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        _ = SiteAssistantSessionFactory.makeSession(
            siteID: "site-1",
            sourceDirectory: root,
            configDirectory: root,
            mcpClient: { nil },
            containerControlProvider: { nil },
            contentGraph: SiteContentGraph(),
            knowledgeIndex: SiteKnowledgeIndex(),
            semanticRanker: nil,
            conventionsEngine: nil,
            integrationService: IntegrationOperations.live(),
            wysiwygBlockAccess: { nil },
            dependencies: dependencies,
            graphSnapshotProvider: { expected }
        )

        while await capture.received == nil { await Task.yield() }
        #expect(await capture.received == expected)
    }

    /// Runs `makeSession` with a builder that only records whether a design-interview factory
    /// arrived, returning that observation (#665).
    private func interviewFactoryPresence(packageURL: URL?) -> Bool {
        // The builder closure is `@Sendable`, so it can't mutate a captured local directly —
        // but it runs synchronously inside `makeSession`, so an unchecked box is race-free here.
        final class Observed: @unchecked Sendable { var factoryPresent = false }
        let observed = Observed()
        var dependencies = SiteAssistantSessionFactory.Dependencies.live
        dependencies.assistant = { _, _, _, _, _, _, _, _, designInterviewFactory, _, _ in
            observed.factoryPresent = designInterviewFactory != nil
            return StubConversationalAssistant()
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        _ = SiteAssistantSessionFactory.makeSession(
            siteID: "site-1",
            sourceDirectory: root,
            configDirectory: root,
            packageURL: packageURL,
            mcpClient: { nil },
            containerControlProvider: { nil },
            contentGraph: SiteContentGraph(),
            knowledgeIndex: SiteKnowledgeIndex(),
            semanticRanker: nil,
            conventionsEngine: nil,
            integrationService: IntegrationOperations.live(),
            wysiwygBlockAccess: { nil },
            dependencies: dependencies,
            graphSnapshotProvider: { SiteGraphExplorerSnapshot(nodes: [], edges: []) }
        )
        return observed.factoryPresent
    }

    @Test("a packageURL yields a design-interview factory for the chat assistant (#665)")
    func packageURLYieldsDesignInterviewFactory() {
        let packageURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(interviewFactoryPresence(packageURL: packageURL))
    }

    @Test("no packageURL means no design-interview factory (#665)")
    func missingPackageURLMeansNoFactory() {
        #expect(!interviewFactoryPresence(packageURL: nil))
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
