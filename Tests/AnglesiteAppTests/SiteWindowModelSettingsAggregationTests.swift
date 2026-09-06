import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteAppCore

/// #741: `SiteWindowModel.hasUnsavedEdits`/`editCommandInFlight`/`saveAllEdits`/
/// `confirmRevertToSaved` used to hand-check `PlistEditorModel.isDirty || isAnalyticsDirty`,
/// omitting Redirects (#530) entirely — so File ▸ Save, Revert, and the window-edited indicator
/// could disagree with an actual Redirects edit. These tests drive `SiteWindowModel` with a real
/// `.plist` editor whose *only* dirty facet is Redirects, proving the aggregate accessors now
/// pick it up via `PlistEditorModel.hasAnyUnsavedEdits`/`isAnySaving`/`saveAllDirty()`.
/// `.timeLimit`: see #1349 — the full `AnglesiteAppTests` target has hung indefinitely under
/// local machine contention (many concurrent `swift test` runs oversubscribing the cooperative
/// thread pool), with this suite one of the observed stall points. A wedged test now fails as an
/// unambiguous time-limit violation instead of hanging the whole run forever.
@Suite("SiteWindowModel settings aggregation (#741)", .timeLimit(.minutes(1)))
@MainActor
struct SiteWindowModelSettingsAggregationTests {
    private static let emptyPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict/></plist>
        """

    private func makeSiteWindowModel() -> SiteWindowModel {
        SiteWindowModel(
            contentGraph: SiteContentGraph(),
            knowledgeIndex: SiteKnowledgeIndex(),
            semanticRanker: nil,
            conventionsEngine: ProjectConventionsEngine(),
            runtimeFactory: NeverStartedSiteRuntimeFactory(),
            contentIndexerStore: ContentIndexerStore()
        )
    }

    /// Builds a real `PlistEditorModel` (same fixture shape as `PlistEditorModelRedirectsTests`)
    /// against a fresh temp `sourceDirectory`, loads it, and dirties Redirects alone — Website and
    /// Analytics both stay clean, so any test passing here can only be exercising the Redirects
    /// facet specifically, not accidentally passing via the already-working Website/Analytics path.
    private func makeRedirectsDirtyPlistModel() throws -> (model: PlistEditorModel, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SiteWindowModelSettingsAggregationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let plistURL = root.appendingPathComponent("Info.plist")
        try Self.emptyPlist.write(to: plistURL, atomically: true, encoding: .utf8)
        let file = FileRef(url: plistURL, group: .metadata, name: "Info.plist")
        let plistModel = PlistEditorModel(file: file, websiteTitle: "Test Site", sourceDirectory: root)
        return (plistModel, root)
    }

    @Test("hasUnsavedEdits is true when only the Redirects facet is dirty")
    func hasUnsavedEditsReflectsRedirectsOnly() async throws {
        let (plistModel, root) = try makeRedirectsDirtyPlistModel()
        defer { try? FileManager.default.removeItem(at: root) }
        await plistModel.load()
        plistModel.redirectEntries.append(RedirectsStore.RedirectEntry(source: "/old", destination: "/new", code: .permanent))

        let model = makeSiteWindowModel()
        model.activeEditor = .plist(plistModel)

        #expect(model.hasUnsavedEdits == true)
    }

    @Test("editCommandInFlight is true while a Redirects-only save is in flight")
    func editCommandInFlightReflectsRedirectsSaving() async throws {
        let (plistModel, root) = try makeRedirectsDirtyPlistModel()
        defer { try? FileManager.default.removeItem(at: root) }
        await plistModel.load()
        plistModel.redirectEntries.append(RedirectsStore.RedirectEntry(source: "/old", destination: "/new", code: .permanent))

        let model = makeSiteWindowModel()
        model.activeEditor = .plist(plistModel)

        async let saveTask: Void = model.saveAllEdits()
        var sawInFlight = false
        for _ in 0..<1000 where !sawInFlight {
            if model.editCommandInFlight { sawInFlight = true }
            await Task.yield()
        }
        await saveTask
        #expect(sawInFlight)
        #expect(model.editCommandInFlight == false)
    }

    @Test("saveAllEdits persists a Redirects-only edit and clears hasUnsavedEdits")
    func saveAllEditsPersistsRedirectsOnlyEdit() async throws {
        let (plistModel, root) = try makeRedirectsDirtyPlistModel()
        defer { try? FileManager.default.removeItem(at: root) }
        await plistModel.load()
        plistModel.redirectEntries.append(RedirectsStore.RedirectEntry(source: "/old", destination: "/new", code: .permanent))

        let model = makeSiteWindowModel()
        model.activeEditor = .plist(plistModel)

        await model.saveAllEdits()

        #expect(model.hasUnsavedEdits == false)
        #expect(try RedirectsStore(sourceDirectory: root).load() == plistModel.redirectEntries)
    }

    @Test("confirmRevertToSaved discards a Redirects-only edit")
    func confirmRevertToSavedDiscardsRedirectsOnlyEdit() async throws {
        let (plistModel, root) = try makeRedirectsDirtyPlistModel()
        defer { try? FileManager.default.removeItem(at: root) }
        await plistModel.load()
        plistModel.redirectEntries.append(RedirectsStore.RedirectEntry(source: "/old", destination: "/new", code: .permanent))

        let model = makeSiteWindowModel()
        model.activeEditor = .plist(plistModel)

        await model.confirmRevertToSaved()

        #expect(model.hasUnsavedEdits == false)
        #expect(plistModel.redirectEntries.isEmpty)
    }

    /// Prior to #741, `close()`'s best-effort teardown save (`persistEditorBufferBestEffort`) only
    /// ever inspected `PlistEditorModel.isDirty` (the Website facet) — a Redirects-only edit was
    /// silently dropped on window close with no error and no save. This proves the fix by closing
    /// the window and reading `redirects.json` back off disk (not just checking the in-memory
    /// model, since a stale in-memory flag can't prove a real write happened).
    @Test("close() flushes a Redirects-only edit to disk, not just the Website facet")
    func closeFlushesRedirectsOnlyEditToDisk() async throws {
        let (plistModel, root) = try makeRedirectsDirtyPlistModel()
        defer { try? FileManager.default.removeItem(at: root) }
        await plistModel.load()
        plistModel.redirectEntries.append(RedirectsStore.RedirectEntry(source: "/old", destination: "/new", code: .permanent))

        let model = makeSiteWindowModel()
        model.activeEditor = .plist(plistModel)
        let controller = SuddenTerminationController(disable: {}, enable: {})
        let lease = controller.acquire()

        model.close(suddenTerminationLease: lease)
        while controller.activeLeaseCount > 0 { await Task.yield() }

        #expect(try RedirectsStore(sourceDirectory: root).load() == [
            RedirectsStore.RedirectEntry(source: "/old", destination: "/new", code: .permanent),
        ])
    }
}
