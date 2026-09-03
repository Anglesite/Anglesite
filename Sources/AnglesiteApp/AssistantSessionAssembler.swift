import Foundation
import AnglesiteCore

/// Assembles the per-site `SiteAssistantSession`: the MCP-client and container-control closures
/// `PreviewModel` exposes, the theme catalog `SetupThemeTool` needs, and the call into
/// `SiteAssistantSessionFactory.makeSession` itself.
///
/// Extracted from `SiteWindowModel.loadAndStart` (#822) as the fourth of its four embedded
/// subsystems. This is pure assembly with no state of its own to own across calls — a stateless
/// namespace, not a composed controller like `InvisiblePublishCoordinator`/
/// `SecurityScopedGrantController` — `loadAndStart` calls it once per site open/replay and keeps
/// only the resulting `SiteAssistantSession`.
///
/// Takes `preview: PreviewModel` directly (not just its `mcpClient`/`activeContainerControl`
/// results) because both closures must stay *lazy*: `SiteAssistantSessionFactory`'s
/// `containerControlProvider` is resolved at the moment a deploy/assistant call actually runs
/// (#823), not at session-assembly time — capturing `preview` and calling through it on each
/// invocation preserves that, matching what `loadAndStart` did inline before this extraction.
@MainActor
enum AssistantSessionAssembler {
    static func makeSession(
        for site: CurrentSite,
        preview: PreviewModel,
        contentGraph: SiteContentGraph,
        knowledgeIndex: SiteKnowledgeIndex,
        semanticRanker: SemanticRanker?,
        conventionsEngine: ProjectConventionsEngine,
        integrationService: any IntegrationOperationsService,
        graphSnapshotProvider: @escaping SiteAssistantSessionFactory.GraphSnapshotProvider
    ) async -> SiteAssistantSession {
        let mcpClient: @Sendable () async -> MCPClient? = { [preview] in
            await preview.mcpClient()
        }
        let containerControlProvider: SiteAssistantSessionFactory.ContainerControlProvider = { [preview] in
            await preview.activeContainerControl()
        }
        // Resolved lazily, same reasoning as `mcpClient`/`containerControlProvider` above: the
        // canvas mounts/unmounts as the owner toggles Site ▸ Edit Page, so this must re-check
        // `preview.wysiwygCanvas` at call time, not capture a possibly-nil snapshot now (#1227 PR 2).
        let wysiwygBlockAccess: @Sendable () async -> (any WYSIWYGBlockTextAccess)? = { [preview] in
            await preview.wysiwygCanvas
        }
        // Best-effort: SetupThemeTool only attaches to the chat assistant when a catalog loads
        // successfully. A missing/unreadable template must not block opening the site — the
        // assistant simply runs without the theme-apply tool, same as before this catalog existed.
        let themeCatalog: ThemeCatalog? = {
            guard let templateURL = TemplateRuntime.resolve().url else { return nil }
            return try? ThemeCatalog.load(templateURL: templateURL)
        }()
        return await SiteAssistantSessionFactory.makeSession(
            siteID: site.id,
            sourceDirectory: site.sourceDirectory,
            configDirectory: site.configDirectory,
            packageURL: site.packageURL,
            mcpClient: mcpClient,
            containerControlProvider: containerControlProvider,
            contentGraph: contentGraph,
            knowledgeIndex: knowledgeIndex,
            semanticRanker: semanticRanker,
            conventionsEngine: conventionsEngine,
            integrationService: integrationService,
            themeCatalog: themeCatalog,
            wysiwygBlockAccess: wysiwygBlockAccess,
            graphSnapshotProvider: graphSnapshotProvider
        )
    }
}
