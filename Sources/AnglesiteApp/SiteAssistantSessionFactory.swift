import Foundation
import AnglesiteCore

/// The per-site assistant/edit bundle that `SiteWindow` installs into the preview session.
@MainActor
struct SiteAssistantSession {
    let chat: ChatModel
    let editObserver: MCPApplyEditRouter.EditObserver
    let editPostProcessor: MCPApplyEditRouter.PostProcessor?
}

/// Builds the cross-cutting assistant surface for one open site: chat, annotations, undo,
/// edit-recording, and best-effort alt-text post-processing.
@MainActor
enum SiteAssistantSessionFactory {
    typealias MCPClientProvider = @Sendable () async -> MCPClient?
    typealias EditRouterProvider = @Sendable (_ siteID: String) async -> (any EditRouter)?
    typealias GraphSnapshotProvider = @Sendable () async -> SiteGraphExplorerSnapshot
    typealias ContainerControlProvider = @Sendable () async -> (siteID: String, control: any LocalContainerControl)?
    typealias WYSIWYGBlockAccessProvider = @Sendable () async -> (any WYSIWYGBlockTextAccess)?
    typealias AssistantBuilder = @Sendable (
        _ editBridge: IntentEditBridge,
        _ contentGraph: SiteContentGraph,
        _ knowledgeIndex: SiteKnowledgeIndex,
        _ semanticRanker: SemanticRanker?,
        _ integrationService: any IntegrationOperationsService,
        _ conventionsEngine: ProjectConventionsEngine?,
        _ conventionsStore: ProjectConventionsStore,
        _ themeCatalog: ThemeCatalog?,
        _ designInterviewFactory: FoundationModelAssistant.DesignInterviewModelFactory?,
        _ wysiwygBlockAccess: @escaping WYSIWYGBlockAccessProvider,
        _ graphSnapshotProvider: @escaping GraphSnapshotProvider
    ) -> any ConversationalAssistant

    struct Dependencies {
        var annotationFeed: @Sendable (_ sourceDirectory: URL) -> AnnotationFeed
        var resolveAnnotation: @Sendable (_ sourceDirectory: URL, _ id: String) async throws -> Void
        var undoCommand: @Sendable (_ mcpClient: @escaping MCPClientProvider) -> UndoCommand
        var editRouterProvider: EditRouterProvider
        var assistant: AssistantBuilder
        #if compiler(>=6.4)
        // `AltTextGenerator` is only declared under `#if compiler(>=6.4)`
        // (Sources/AnglesiteCore/AltTextGenerator.swift) — the field itself has to be gated,
        // not just its `.live` initializer, or an older toolchain can't even parse the type.
        var altTextGenerator: @Sendable (
            _ siteID: String,
            _ sourceDirectory: URL,
            _ mcpClient: @escaping MCPClientProvider,
            _ conventionsEngine: ProjectConventionsEngine?
        ) -> AltTextGenerator
        #endif

        static let live: Dependencies = {
            let annotationFeed: @Sendable (URL) -> AnnotationFeed = { sourceDirectory in
                AnnotationFeedFactory.native(directory: sourceDirectory)
            }
            let resolveAnnotation: @Sendable (URL, String) async throws -> Void = { sourceDirectory, id in
                try AnnotationStore.resolve(in: sourceDirectory, id: id)
            }
            let undoCommand: @Sendable (@escaping MCPClientProvider) -> UndoCommand = { mcpClient in
                UndoCommand(mcpClient: mcpClient)
            }
            let editRouterProvider: EditRouterProvider = { siteID in
                await EditRouterRegistry.shared.router(for: siteID)
            }
            let assistant: AssistantBuilder = { editBridge, contentGraph, knowledgeIndex, semanticRanker, integrationService, conventionsEngine, conventionsStore, themeCatalog, designInterviewFactory, wysiwygBlockAccess, graphSnapshotProvider in
                CombinedAugmentedAssistant(
                    base: FoundationModelAssistant(
                        tier: .onDevice,
                        editBridge: editBridge,
                        contentGraph: contentGraph,
                        knowledgeIndex: knowledgeIndex,
                        semanticRanker: semanticRanker,
                        integrationService: integrationService,
                        conventionsEngine: conventionsEngine,
                        conventionsStore: conventionsStore,
                        copyEditAuditor: CopyEditAuditorFactory.makeDefault(),
                        socialMediaPlanner: SocialMediaPlannerFactory.makeDefault(),
                        postRepurposer: PostRepurposerFactory.makeDefault(),
                        wysiwygBlockAccessProvider: wysiwygBlockAccess,
                        themeCatalog: themeCatalog,
                        designInterviewFactory: designInterviewFactory
                    ),
                    index: knowledgeIndex,
                    graphSnapshotProvider: graphSnapshotProvider
                )
            }
            #if compiler(>=6.4)
            return Dependencies(
                annotationFeed: annotationFeed,
                resolveAnnotation: resolveAnnotation,
                undoCommand: undoCommand,
                editRouterProvider: editRouterProvider,
                assistant: assistant,
                altTextGenerator: { siteID, sourceDirectory, _, conventionsEngine in
                    AltTextGenerator(
                        siteID: siteID,
                        siteDirectory: sourceDirectory,
                        isEnabled: { AppSettings.shared.autoGenerateAltText },
                        produce: { imageURL, context in
                            let conventions = await conventionsEngine?.conventions(siteID: siteID)
                            let prompt = AltTextPromptBuilder.build(
                                basePrompt: AltTextPromptBuilder.defaultBasePrompt,
                                conventions: conventions
                            )
                            return try await FoundationModelAssistant(tier: .onDevice).generateStructured(
                                prompt: prompt,
                                imageURL: imageURL,
                                context: context,
                                resultType: GeneratedAltText.self
                            )
                        },
                        apply: { edit in
                            // Reuse the window's registered router so generated alt-text edits go
                            // through the same awaited runtime-to-Source persistence hook as the
                            // originating image edit (#718).
                            let reply = await EditRouterRegistry.shared.router(for: siteID)?.apply(edit)
                                ?? EditReply(
                                    id: edit.id,
                                    status: .failed,
                                    message: "no active edit router for \(siteID)"
                                )
                            if reply.status == .failed {
                                await LogCenter.shared.append(
                                    source: "alt-text:\(siteID)", stream: .stderr,
                                    text: "applying generated alt text failed: \(reply.message ?? "unknown error")"
                                )
                            }
                        },
                        log: { message in
                            await LogCenter.shared.append(
                                source: "alt-text:\(siteID)", stream: .stderr, text: message)
                        }
                    )
                }
            )
            #else
            return Dependencies(
                annotationFeed: annotationFeed,
                resolveAnnotation: resolveAnnotation,
                undoCommand: undoCommand,
                editRouterProvider: editRouterProvider,
                assistant: assistant
            )
            #endif
        }()
    }

    static func makeSession(
        siteID: String,
        sourceDirectory: URL,
        configDirectory: URL,
        packageURL: URL? = nil,
        mcpClient: @escaping MCPClientProvider,
        containerControlProvider: @escaping ContainerControlProvider,
        contentGraph: SiteContentGraph,
        knowledgeIndex: SiteKnowledgeIndex,
        semanticRanker: SemanticRanker?,
        conventionsEngine: ProjectConventionsEngine?,
        integrationService: any IntegrationOperationsService,
        themeCatalog: ThemeCatalog? = nil,
        wysiwygBlockAccess: @escaping WYSIWYGBlockAccessProvider,
        dependencies: Dependencies = .live,
        graphSnapshotProvider: @escaping GraphSnapshotProvider
    ) -> SiteAssistantSession {
        let editBridge = IntentEditBridge(routerProvider: dependencies.editRouterProvider)
        // A second `ProjectConventionsStore` instance pointed at the same `configDirectory` as
        // `SiteWindowModel`'s Style Guide store (rather than threading that instance through this
        // factory's parameter list) — harmless because all writes now flow through the shared
        // `conventionsEngine` (#465): `BrandVoiceWriter`/`ProjectConventionsModel` only ever persist
        // the engine's merged snapshot to whichever store instance they hold, so a second store
        // pointed at the same `conventions.json` never observes a stale value.
        let conventionsStore = ProjectConventionsStore(configDirectory: configDirectory)
        // The chat front door's design-interview factory (#665), invoked lazily by
        // `FoundationModelAssistant` on `DesignInterviewTool`'s first call. Mirrors
        // `SiteWindowModel.presentDesignInterview()`: a **standalone** on-device assistant, because
        // the interview is its own model conversation — routing it through the hosting chat
        // assistant would both append interview turns to the chat session's transcript and
        // re-enter that actor's single-flight session mid-drain.
        let designInterviewFactory: FoundationModelAssistant.DesignInterviewModelFactory? = packageURL.map { packageURL in
            {
                // Read off the main actor — only DesignInterviewModel's init needs MainActor,
                // and `.site-config` may live on slow (e.g. iCloud-backed) storage.
                let businessType = SiteBusinessType.read(sourceDirectory: sourceDirectory) ?? ""
                return await MainActor.run {
                    DesignInterviewModel(
                        businessType: businessType,
                        assistant: FoundationModelAssistant(tier: .onDevice),
                        package: AnglesitePackage(url: packageURL),
                        siteID: siteID
                    )
                }
            }
        }
        let resolvedAssistant: any ConversationalAssistant = AssistantBackendResolver.resolveActiveExternalLLMAssistant()
            ?? AssistantBackendResolver.resolveActiveACPAssistant(
                siteID: siteID,
                sourceDirectory: sourceDirectory,
                containerControlProvider: containerControlProvider
            ) ?? dependencies.assistant(
            editBridge,
            contentGraph,
            knowledgeIndex,
            semanticRanker,
            integrationService,
            conventionsEngine,
            conventionsStore,
            themeCatalog,
            designInterviewFactory,
            wysiwygBlockAccess,
            graphSnapshotProvider
        )
        let chat = ChatModel(
            siteID: siteID,
            siteDirectory: sourceDirectory,
            configDirectory: configDirectory,
            assistant: resolvedAssistant,
            annotationFeed: dependencies.annotationFeed(sourceDirectory),
            annotationResolver: { [resolveAnnotation = dependencies.resolveAnnotation] id in
                try await resolveAnnotation(sourceDirectory, id)
            },
            undoCommand: dependencies.undoCommand(mcpClient)
        )

        #if compiler(>=6.4)
        let altTextGenerator = dependencies.altTextGenerator(siteID, sourceDirectory, mcpClient, conventionsEngine)
        let postProcessor: MCPApplyEditRouter.PostProcessor? = { reply, message in
            await altTextGenerator.postProcess(reply: reply, message: message)
        }
        #else
        // No `AltTextGenerator` on this toolchain (see the `Dependencies.altTextGenerator` gate
        // above) — alt-text post-processing is simply unavailable rather than a hard build failure.
        let postProcessor: MCPApplyEditRouter.PostProcessor? = nil
        #endif

        return SiteAssistantSession(
            chat: chat,
            // The router may retain this observer for the preview lifetime. Capture weakly to avoid
            // a PreviewModel -> editRouter -> observer -> ChatModel cycle; SiteWindow stores the
            // returned chat model immediately, so normal window ownership still keeps it alive.
            editObserver: { [weak chat] reply in
                Task { @MainActor in
                    chat?.recordEdit(reply)
                }
            },
            editPostProcessor: postProcessor
        )
    }
}
