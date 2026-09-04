// Tests/AnglesiteAppTests/SiteWindowModelInspectorSaveSyncTests.swift
import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteAppCore

/// #1851: an inspector save (`GenericPageInspectorModel`/`PageMetadataModel`/
/// `TypedEntryEditorModel`) commits straight to host `Source/` HEAD but — unlike New Page/Post/
/// Duplicate/Delete/Publish/Undo/Cleanup — never routed through `refreshAfterContentMutation()`,
/// so a running container's guest clone fell behind host HEAD. `InProcessEditPersistence` is
/// fast-forward-only, so the next in-preview overlay edit's exported commit no longer had HEAD as
/// its parent and was silently refused: the preview showed the change, but nothing landed in
/// `Source/`. `saveAllEdits()` (File ▸ Save) and `leaveCurrentInspector()` (auto-save-on-leave,
/// the everyday path — it fires on nearly every Navigator selection change) are the only two
/// places a dirty inspector model gets flushed while the site stays open, so both now sync the
/// guest to host HEAD after a successful dirty save.
private actor SyncTrackingContainerRuntime: SiteRuntime, SiteRuntimeContainerCapability {
    let mcpClient = MCPClient(supervisor: ProcessSupervisor(), logCenter: LogCenter())

    nonisolated var containerCapability: (any SiteRuntimeContainerCapability)? { self }

    func start(siteID: String, siteDirectory: URL) async {}
    func stop() async {}
    func observe() -> AsyncStream<SiteRuntimeState> { AsyncStream<SiteRuntimeState> { _ in } }

    func containerSnapshot() async -> (control: any LocalContainerControl, siteID: String)? { nil }
    func resetNetworking() async {}
    func persistEdit(commit: String?) async throws {}
    func updateActiveWorkers(_ settings: SiteSettings) async {}

    private(set) var syncFromHostCallCount = 0
    func syncFromHost() async throws { syncFromHostCallCount += 1 }
}

private struct SyncTrackingRuntimeFactory: SiteRuntimeFactory {
    let runtime: SyncTrackingContainerRuntime
    func makeRuntime(
        contentGraph: SiteContentGraph?,
        knowledgeIndex: SiteKnowledgeIndex?,
        semanticRanker: SemanticRanker?,
        conventionsEngine: ProjectConventionsEngine?
    ) -> any SiteRuntime { runtime }
}

@Suite("SiteWindowModel inspector save → guest sync (#1851)")
@MainActor
struct SiteWindowModelInspectorSaveSyncTests {
    private func makeInspectorModel(in dir: URL) throws -> GenericPageInspectorModel {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src/pages"), withIntermediateDirectories: true)
        let pageURL = dir.appendingPathComponent("src/pages/index.astro")
        try "---\nconst title = \"Home\";\n---\n<h1>{title}</h1>\n".write(to: pageURL, atomically: true, encoding: .utf8)
        let file = FileRef(url: pageURL, group: .pages, name: "index.astro")
        return GenericPageInspectorModel(
            file: file, route: "/", sourceDirectory: dir,
            gitCommit: { _, _, _ in "deadbeef" }
        )
    }

    private func makeModel(runtime: SyncTrackingContainerRuntime) -> SiteWindowModel {
        SiteWindowModel(
            contentGraph: SiteContentGraph(),
            knowledgeIndex: SiteKnowledgeIndex(),
            semanticRanker: nil,
            conventionsEngine: ProjectConventionsEngine(),
            runtimeFactory: SyncTrackingRuntimeFactory(runtime: runtime),
            contentIndexerStore: ContentIndexerStore()
        )
    }

    @Test("saveAllEdits syncs the guest to host HEAD after a dirty inspector save")
    func saveAllEditsSyncsAfterDirtyInspectorSave() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SiteWindowModelInspectorSaveSyncTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let inspectorModel = try makeInspectorModel(in: dir)
        await inspectorModel.load()
        inspectorModel.noindexBinding().wrappedValue = true
        #expect(inspectorModel.isDirty)

        let runtime = SyncTrackingContainerRuntime()
        let model = makeModel(runtime: runtime)
        model.inspectorContext = .generic(inspectorModel)

        await model.saveAllEdits()

        #expect(await runtime.syncFromHostCallCount == 1)
        #expect(!inspectorModel.isDirty)
    }

    @Test("saveAllEdits does not sync when the inspector had nothing to save")
    func saveAllEditsSkipsSyncWhenClean() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SiteWindowModelInspectorSaveSyncTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let inspectorModel = try makeInspectorModel(in: dir)
        await inspectorModel.load()
        #expect(!inspectorModel.isDirty)

        let runtime = SyncTrackingContainerRuntime()
        let model = makeModel(runtime: runtime)
        model.inspectorContext = .generic(inspectorModel)

        await model.saveAllEdits()

        #expect(await runtime.syncFromHostCallCount == 0)
    }

    @Test("leaveCurrentInspector syncs the guest after auto-saving a dirty inspector (the everyday selection-change path)")
    func leaveCurrentInspectorSyncsAfterDirtyFlush() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SiteWindowModelInspectorSaveSyncTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let inspectorModel = try makeInspectorModel(in: dir)
        await inspectorModel.load()
        inspectorModel.disallowCrawlBinding().wrappedValue = true

        let runtime = SyncTrackingContainerRuntime()
        let model = makeModel(runtime: runtime)
        model.inspectorContext = .generic(inspectorModel)

        let left = await model.leaveCurrentInspector()

        #expect(left)
        #expect(await runtime.syncFromHostCallCount == 1)
    }

    @Test("leaveCurrentInspector does not sync when there is no inspector open")
    func leaveCurrentInspectorSkipsSyncWithNoInspector() async throws {
        let runtime = SyncTrackingContainerRuntime()
        let model = makeModel(runtime: runtime)

        let left = await model.leaveCurrentInspector()

        #expect(left)
        #expect(await runtime.syncFromHostCallCount == 0)
    }
}
