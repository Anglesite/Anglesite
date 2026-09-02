import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteAppCore

/// `PreviewModel`'s convenience init constructs its runtime eagerly via `makeRuntime` (not lazily
/// on `startDevServer()`), so this factory must hand back a real, safe-to-construct `SiteRuntime`
/// rather than fatal-erroring. `UnavailableSiteRuntime` is the same inert runtime
/// `LiveSiteRuntimeFactory` falls back to in production when no container runtime is available:
/// its `start()` just settles to `.failed` rather than spawning anything, so it stays inert for
/// every test in this file — none of them call `preview.startDevServer()`. If a future test needs
/// a working fake runtime, extend this rather than adding a second fake type.
struct NeverStartedSiteRuntimeFactory: SiteRuntimeFactory {
    func makeRuntime(
        contentGraph: SiteContentGraph?,
        knowledgeIndex: SiteKnowledgeIndex?,
        semanticRanker: SemanticRanker?,
        conventionsEngine: ProjectConventionsEngine?
    ) -> any SiteRuntime {
        UnavailableSiteRuntime(reason: "NeverStartedSiteRuntimeFactory should not be started in this test suite")
    }
}

/// Construction smoke test + `deleteCleanupCandidate` coverage for `SiteWindowModel` (issue
/// #555). `SiteWindowModel` is the mega-coordinator this whole cluster is trying to make
/// testable, so this file is deliberately narrow: it proves the model can be built with real
/// (if empty) dependencies, and that `deleteCleanupCandidate` runs its guard chain end-to-end
/// without needing a live preview/runtime.
@Suite("SiteWindowModel")
@MainActor
struct SiteWindowModelTests {
    private func makeModel(contentGraph: SiteContentGraph = SiteContentGraph()) -> SiteWindowModel {
        SiteWindowModel(
            contentGraph: contentGraph,
            knowledgeIndex: SiteKnowledgeIndex(),
            semanticRanker: nil,
            conventionsEngine: ProjectConventionsEngine(),
            runtimeFactory: NeverStartedSiteRuntimeFactory(),
            contentIndexerStore: ContentIndexerStore()
        )
    }

    @Test("constructs with all dependencies wired")
    func constructs() {
        let model = makeModel()
        #expect(model.site == nil)
        #expect(model.mainPaneMode == .preview)
    }

    @Test("returnToCanvas switches the main pane back to Preview from a takeover")
    func returnToCanvasSwitchesToPreview() async throws {
        let model = makeModel()
        model.mainPaneMode = .cleanup

        model.returnToCanvas()

        while model.mainPaneMode != .preview { await Task.yield() }
        #expect(model.mainPaneMode == .preview)
    }

    /// `SiteWindow`'s `mainPaneMode` `.onChange` calls this directly (#1748) — see its doc comment.
    @Test("focusNavigatorIfTakeoverDismissed requests navigator focus when leaving a takeover for a different kind")
    func focusNavigatorIfTakeoverDismissedFromTakeover() {
        let model = makeModel()
        let navigator = SiteNavigatorModel(graph: SiteContentGraph())
        model.navigator = navigator
        let before = navigator.focusRequestToken

        model.focusNavigatorIfTakeoverDismissed(from: .graph, to: .preview)
        #expect(navigator.focusRequestToken == before + 1)

        model.focusNavigatorIfTakeoverDismissed(from: .cleanup, to: .reader)
        #expect(navigator.focusRequestToken == before + 2, "switching straight into a different takeover still counts as a dismissal")
    }

    @Test("focusNavigatorIfTakeoverDismissed is a no-op leaving .preview or switching files within .editor")
    func focusNavigatorIfTakeoverDismissedNoOp() {
        let model = makeModel()
        let navigator = SiteNavigatorModel(graph: SiteContentGraph())
        model.navigator = navigator
        let before = navigator.focusRequestToken
        let fileA = FileRef(url: URL(fileURLWithPath: "/tmp/a.astro"), group: .pages, name: "a.astro")
        let fileB = FileRef(url: URL(fileURLWithPath: "/tmp/b.astro"), group: .pages, name: "b.astro")

        model.focusNavigatorIfTakeoverDismissed(from: .preview, to: .graph)
        model.focusNavigatorIfTakeoverDismissed(from: .editor(fileA), to: .editor(fileB))

        #expect(navigator.focusRequestToken == before)
    }

    /// Mirrors `presentCleanupAbortsOnEditorConflict`'s fixture: a dirty editor whose file changed
    /// on disk under it makes `flushBeforeLeaving()` (invoked via `leaveCurrentEditor()`) return
    /// `false`, so `returnToCanvas()` should abort before touching `mainPaneMode`. This exact guard
    /// was previously only reachable through the untested `setPaneSelection(0)` branch — closing a
    /// real coverage gap, not just moving existing coverage.
    @Test("returnToCanvas doesn't switch panes when leaveCurrentEditor aborts on an editor conflict")
    func returnToCanvasAbortsOnEditorConflict() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let model = makeModel()
        let editedFile = root.appendingPathComponent("conflict.txt")
        try Data("original".utf8).write(to: editedFile)
        let fileRef = FileRef(url: editedFile, group: .components, name: "conflict.txt")
        let editorModel = FileEditorModel(file: fileRef)
        await editorModel.load()
        editorModel.text = "dirty edit"
        try Data("changed on disk".utf8).write(to: editedFile)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: editedFile.path
        )
        model.mainPaneMode = .editor(fileRef)
        model.activeEditor = .text(editorModel)

        model.returnToCanvas()

        var iterations = 0
        while editorModel.conflictDiskContents == nil, iterations < 10_000 {
            await Task.yield()
            iterations += 1
        }
        guard editorModel.conflictDiskContents != nil else {
            Issue.record("flushBeforeLeaving never surfaced the external conflict")
            return
        }

        #expect(model.mainPaneMode == .editor(fileRef))
        #expect(model.activeEditor != nil)
    }

    @Test("close retains its sudden-termination lease until a dirty editor is saved")
    func closeRetainsLeaseUntilEditorSaveFinishes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("site-window-close-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("page.astro")
        try Data("original".utf8).write(to: fileURL)
        let editor = FileEditorModel(
            file: FileRef(url: fileURL, group: .pages, name: "page.astro")
        )
        await editor.load()
        editor.text = "saved during close"

        let model = makeModel()
        model.activeEditor = .text(editor)
        let controller = SuddenTerminationController(disable: {}, enable: {})
        let lease = controller.acquire()

        model.close(suddenTerminationLease: lease)
        while controller.activeLeaseCount > 0 {
            await Task.yield()
        }

        let saved = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(saved == "saved during close")
        #expect(controller.activeLeaseCount == 0)
    }
}

extension SiteWindowModelTests {
    @Test("deleteCleanupCandidate no-ops safely when there is no open site")
    func deleteCleanupCandidateNoSiteIsNoOp() async {
        let model = makeModel()
        // model.site is nil (no loadAndStart() ran) — deleteCleanupCandidate's first guard
        // (`guard let site else { return }`, SiteWindowModel.swift:643) must return immediately
        // without touching activeEditor/inspectorContext/cleanup.
        let candidate = DeadAssetScanner.CleanupCandidate(
            id: "public/images/ghost.png", path: "public/images/ghost.png",
            kind: .image, lastModified: Date(timeIntervalSince1970: 0), referenceCount: 0
        )

        await model.deleteCleanupCandidate(candidate)

        #expect(model.activeEditor == nil)
        #expect(model.cleanup.candidates.isEmpty)
        #expect(model.cleanup.deleteError == nil)
    }

    @Test("deleteCleanupCandidate refuses a candidate not in the live cleanup list, even with a real site set")
    func deleteCleanupCandidateRefusesUnknownCandidate() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("site-window-model-\(UUID().uuidString)")
        let sourceDirectory = root.appendingPathComponent("Test.anglesite/Source")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let model = makeModel()
        model.site = SiteStore.Site(
            id: "site-a", name: "Test", packageURL: root.appendingPathComponent("Test.anglesite"),
            isValid: true, missingSentinels: [], lastSeen: Date(), bookmarkData: nil
        )
        // `deleteCleanupCandidate` never calls `cleanup.configure` itself — that only happens in
        // `loadAndStart()` (SiteWindowModel.swift:841), which this test does not run. Without it,
        // `cleanup.sourceDirectory` stays nil and `ProjectCleanupModel.delete`'s *first* guard
        // (`guard let sourceDirectory, !isBusy else { return false }`, ProjectCleanupModel.swift:96)
        // would short-circuit before ever reaching the stale-candidate check this test targets —
        // exactly the trap Task 4's fix-cycle flagged. Configure it directly so execution reaches
        // the second guard.
        model.cleanup.configure(site: CurrentSite(id: "site-a", packageURL: sourceDirectory, sourceDirectory: sourceDirectory))
        let candidate = DeadAssetScanner.CleanupCandidate(
            id: "public/images/ghost.png", path: "public/images/ghost.png",
            kind: .image, lastModified: Date(timeIntervalSince1970: 0), referenceCount: 0
        )

        // model.cleanup.candidates is still empty (no scan() ran) — cleanup.delete's own
        // stale-candidate guard (Task 4) refuses, so this exercises the two guards composing
        // correctly end-to-end through SiteWindowModel rather than ProjectCleanupModel alone.
        await model.deleteCleanupCandidate(candidate)

        #expect(model.cleanup.deleteError?.contains("no longer in the Cleanup list") == true)
    }
}

extension SiteWindowModelTests {
    @Test("createPost no-ops safely when there is no open site")
    func createPostNoSiteReturnsSiteNotFound() async {
        let model = makeModel()
        let result = await model.createPost(title: "Hello")
        #expect(result == .siteNotFound)
    }

    @Test("createComponent no-ops safely when there is no open site")
    func createComponentNoSiteReturnsSiteNotFound() async {
        let model = makeModel()
        let result = await model.createComponent(name: "Widget")
        #expect(result == .siteNotFound)
    }

    @Test("duplicateComponent no-ops safely when there is no open site")
    func duplicateComponentNoSiteReturnsSiteNotFound() async {
        let model = makeModel()
        let result = await model.duplicateComponent(relativePath: "src/components/Card.astro")
        #expect(result == .siteNotFound)
    }

    @Test("confirmDelete clears deleteConfirmation and no-ops when there is no open site")
    func confirmDeleteNoSiteIsNoOp() async {
        let model = makeModel()
        model.deleteConfirmation = NavigatorItem(id: "site-1:page:/about", title: "About", target: .route("/about"))

        await model.confirmDelete()

        #expect(model.deleteConfirmation == nil)
    }

    @Test("duplicate no-ops safely when there is no open site")
    func duplicateNoSiteIsNoOp() async {
        let model = makeModel()
        await model.duplicate(id: "site-1:page:/about")
        // No crash, no error surfaced — there's nothing to duplicate without an open site.
        #expect(model.contentActionError == nil)
    }

    /// `confirmDelete`'s post branch now resolves `deletedRoute` via `postRoute(for:)` (#584)
    /// instead of leaving it `nil` — this exercises that the lookup + route derivation for a real,
    /// graph-registered post runs cleanly (finds the post, computes its route, proceeds to the
    /// delete call) rather than crashing or mis-typing. It stops short of proving the route reaches
    /// `pendingRedirectOfferRoute`, because that only happens on a real `.deleted` result, and
    /// `ContentCreationWorkflow.native`'s `siteDirectory` resolver is hardwired to `SiteStore.shared`
    /// (`SiteWindowModel.swift`'s `contentCreation` init) — a real process-wide singleton that
    /// persists to the developer's actual `recents.json`. There's no test seam to redirect it to a
    /// throwaway location, and registering a fake site into the real one would risk corrupting real
    /// user data. That's a pre-existing gap shared with the page case (#530 never had this coverage
    /// either), not one #584 introduces; `postRoute(for:)` itself is covered in `NavigatorTreeTests`,
    /// and the full end-to-end behavior is left to manual GUI verification (#586).
    @Test("confirmDelete resolves a registered post's route without crashing, even though delete itself can't succeed here")
    func confirmDeletePostRouteResolvesCleanly() async {
        let graph = SiteContentGraph()
        let model = makeModel(contentGraph: graph)
        model.site = SiteStore.Site(
            id: "site-a", name: "Test", packageURL: URL(fileURLWithPath: "/tmp/nonexistent.anglesite"),
            isValid: true, missingSentinels: [], lastSeen: Date(), bookmarkData: nil
        )
        let post = SiteContentGraph.Post(
            id: "site-a:post:hello-world", siteID: "site-a", collection: "blog", slug: "hello-world",
            title: "Hello World", draft: false, publishDate: nil, tags: [],
            filePath: "src/content/blog/hello-world.md", lastModified: Date()
        )
        await graph.upsertPost(post)
        model.deleteConfirmation = NavigatorItem(id: post.id, title: "Hello World", target: .route(postRoute(for: post)))

        await model.confirmDelete()

        #expect(model.deleteConfirmation == nil)
        // `SiteStore.shared` doesn't know "site-a" — `deleteContent` resolves `.siteNotFound`, so no
        // redirect offer (correctly: nothing was actually deleted) and `contentActionError` reports
        // it (#987 — this used to be a silent no-op here too).
        #expect(model.pendingRedirectOfferRoute == nil)
        #expect(model.contentActionError == "This site is no longer available.")
    }

    // MARK: - ⌘Z for structural content operations (#675)
    //
    // The one-shot post-delete "Undo" alert (#586) was retired here in favour of the window
    // `UndoManager`, so its `pendingDeleteUndo`/`dismissDeleteUndo` tests are replaced by the
    // coverage below. The same seam limit called out on `confirmDeletePostRouteResolvesCleanly`
    // applies: `ContentCreationWorkflow.native`'s resolver is hardwired to `SiteStore.shared`, so
    // no test here can drive a *successful* delete or restore. What is reachable — and what these
    // cover — is the guard/rollback wiring around them; the write paths themselves are covered by
    // `ContentUndoCoordinatorTests` and `NativeContentOperationsTests`.

    @Test("applyContentUndo reports failure rather than crashing when there is no open site")
    func applyContentUndoNoSiteFails() async {
        let model = makeModel()

        let outcome = await model.applyContentUndo(ContentUndoCoordinator.Mutation(
            relativePath: "src/pages/about.astro", before: "restored", after: nil,
            actionName: "Delete \u{201C}About\u{201D}"))

        // `.failed` (not a silent `.applied`) is what makes the coordinator re-arm the record, so
        // a ⌘Z fired at a window whose site went away stays retryable instead of being consumed.
        #expect(outcome == .failed)
        #expect(model.contentActionError == nil)
    }

    @Test("handleSiteChanged drops pending content-undo records")
    func siteChangeInvalidatesContentUndo() {
        let model = makeModel()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        model.windowUndoManager = undoManager
        model.contentUndoCoordinator.register(ContentUndoCoordinator.Mutation(
            relativePath: "src/pages/about.astro", before: "old", after: "new",
            actionName: "Rename"))
        #expect(undoManager.canUndo)

        model.handleSiteChanged()

        // Records are site-relative paths plus captured contents — applying one after a site
        // replay would write the old site's bytes into the new site.
        #expect(!undoManager.canUndo)
    }

    @Test("a failed delete reopens the editor it closed")
    func failedDeleteReopensEditor() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("site-window-undo-\(UUID().uuidString)")
        let sourceDirectory = root.appendingPathComponent("Test.anglesite/Source/src/pages")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = sourceDirectory.appendingPathComponent("about.astro")
        try Data("<h1>About</h1>".utf8).write(to: fileURL)

        let graph = SiteContentGraph()
        let model = makeModel(contentGraph: graph)
        model.site = SiteStore.Site(
            id: "site-a", name: "Test", packageURL: root.appendingPathComponent("Test.anglesite"),
            isValid: true, missingSentinels: [], lastSeen: Date(), bookmarkData: nil
        )
        let page = SiteContentGraph.Page(
            id: "site-a:page:/about", siteID: "site-a", route: "/about",
            filePath: "src/pages/about.astro", title: "About", lastModified: Date())
        await graph.upsertPage(page)

        let editor = FileEditorModel(file: FileRef(url: fileURL, group: .pages, name: "about.astro"))
        model.activeEditor = .text(editor)
        model.mainPaneMode = .editor(editor.file)
        model.deleteConfirmation = NavigatorItem(id: page.id, title: "About", target: .route("/about"))

        await model.confirmDelete()

        // `SiteStore.shared` doesn't know "site-a", so the delete resolves `.siteNotFound` and
        // never touches the file. The editor was closed *before* the delete call (so a suspended
        // flush couldn't resurrect the file), which means the model owes it back — leaving the
        // user on Preview with their buffer discarded for a delete that didn't happen would be a
        // silent data loss.
        #expect(model.activeEditor != nil)
        #expect(model.mainPaneMode == .editor(editor.file))
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(model.contentActionError == "This site is no longer available.")
    }
}

extension SiteWindowModelTests {
    // MARK: - #987: content-action failure paths must surface `contentActionError`
    //
    // Distinct from the "no open site" no-op already covered above (`duplicateNoSiteIsNoOp`,
    // `applyContentUndoNoSiteFails`) — that one stays a silent no-op by design (nothing to act
    // on). These cover the two classes #987 flagged as actually reachable: a Navigator row that
    // outlived its `SiteContentGraph` entry, and `contentCreation`'s own `.siteNotFound` (the
    // site left `SiteStore.shared` mid-session).

    private func makeUnregisteredSite() -> SiteStore.Site {
        SiteStore.Site(
            id: "site-a", name: "Test", packageURL: URL(fileURLWithPath: "/tmp/nonexistent.anglesite"),
            isValid: true, missingSentinels: [], lastSeen: Date(), bookmarkData: nil
        )
    }

    @Test("duplicate reports an error when the row has no matching page or post")
    func duplicateUnresolvedRowReportsError() async {
        let model = makeModel()
        model.site = makeUnregisteredSite()

        await model.duplicate(id: "site-a:page:/ghost")

        #expect(model.contentActionError == "This item is no longer part of this site's content.")
    }

    @Test("publish reports an error when the row has no matching post")
    func publishUnresolvedRowReportsError() async {
        let model = makeModel()
        model.site = makeUnregisteredSite()

        await model.publish(id: "site-a:post:ghost")

        #expect(model.contentActionError == "This item is no longer part of this site's content.")
    }

    @Test("unpublish reports an error when the row has no matching post")
    func unpublishUnresolvedRowReportsError() async {
        let model = makeModel()
        model.site = makeUnregisteredSite()

        await model.unpublish(id: "site-a:post:ghost")

        #expect(model.contentActionError == "This item is no longer part of this site's content.")
    }

    @Test("duplicate reports an error when contentCreation resolves .siteNotFound")
    func duplicateSiteNotFoundReportsError() async {
        let graph = SiteContentGraph()
        let model = makeModel(contentGraph: graph)
        model.site = makeUnregisteredSite()
        let page = SiteContentGraph.Page(
            id: "site-a:page:/about", siteID: "site-a", route: "/about",
            filePath: "src/pages/about.astro", title: "About", lastModified: Date())
        await graph.upsertPage(page)

        await model.duplicate(id: page.id)

        // `SiteStore.shared` doesn't know "site-a" — `duplicatePage` resolves `.siteNotFound`.
        #expect(model.contentActionError == "This site is no longer available.")
    }

    @Test("publish reports an error when contentCreation resolves .siteNotFound")
    func publishSiteNotFoundReportsError() async {
        let graph = SiteContentGraph()
        let model = makeModel(contentGraph: graph)
        model.site = makeUnregisteredSite()
        let post = SiteContentGraph.Post(
            id: "site-a:post:hello-world", siteID: "site-a", collection: "blog", slug: "hello-world",
            title: "Hello World", draft: true, publishDate: nil, tags: [],
            filePath: "src/content/blog/hello-world.md", lastModified: Date()
        )
        await graph.upsertPost(post)

        await model.publish(id: post.id)

        #expect(model.contentActionError == "This site is no longer available.")
    }

    @Test("unpublish reports an error when contentCreation resolves .siteNotFound")
    func unpublishSiteNotFoundReportsError() async {
        let graph = SiteContentGraph()
        let model = makeModel(contentGraph: graph)
        model.site = makeUnregisteredSite()
        let post = SiteContentGraph.Post(
            id: "site-a:post:hello-world", siteID: "site-a", collection: "blog", slug: "hello-world",
            title: "Hello World", draft: false, publishDate: nil, tags: [],
            filePath: "src/content/blog/hello-world.md", lastModified: Date()
        )
        await graph.upsertPost(post)

        await model.unpublish(id: post.id)

        #expect(model.contentActionError == "This site is no longer available.")
    }

    @Test("applyContentUndo's delete branch reports an error when contentCreation resolves .siteNotFound")
    func applyContentUndoDeleteBranchSiteNotFoundReportsError() async {
        let model = makeModel()
        model.site = makeUnregisteredSite()

        let outcome = await model.applyContentUndo(ContentUndoCoordinator.Mutation(
            relativePath: "src/pages/about.astro", before: nil, after: "<h1>About</h1>",
            actionName: "Create \u{201C}About\u{201D}"))

        #expect(outcome == .failed)
        #expect(model.contentActionError == "This site is no longer available.")
    }

    @Test("applyContentUndo's restore branch reports an error when contentCreation resolves .siteNotFound")
    func applyContentUndoRestoreBranchSiteNotFoundReportsError() async {
        let model = makeModel()
        model.site = makeUnregisteredSite()

        let outcome = await model.applyContentUndo(ContentUndoCoordinator.Mutation(
            relativePath: "src/pages/about.astro", before: "<h1>About</h1>", after: nil,
            actionName: "Delete \u{201C}About\u{201D}"))

        #expect(outcome == .failed)
        #expect(model.contentActionError == "This site is no longer available.")
    }
}

extension SiteWindowModelTests {
    @Test("revealCitationInGraph returns true and switches to the graph pane for a matching path")
    func revealCitationInGraphMatches() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let contentGraph = SiteContentGraph()
        await contentGraph.load(
            siteID: "site-1",
            pages: [SiteContentGraph.Page(
                id: "site-1:page:/about", siteID: "site-1", route: "/about",
                filePath: "src/pages/about.astro", title: "About", lastModified: Date()
            )],
            posts: [], images: []
        )
        let model = makeModel(contentGraph: contentGraph)
        model.graphExplorer.start(site: CurrentSite(id: "site-1", packageURL: root, sourceDirectory: root))
        while model.graphExplorer.snapshot.nodes.isEmpty { await Task.yield() }

        let handled = model.revealCitationInGraph("src/pages/about.astro")

        #expect(handled)
        while model.mainPaneMode != .graph { await Task.yield() }
        #expect(model.graphExplorer.selectedNodeID == model.graphExplorer.snapshot.nodes.first?.id)
    }

    @Test("revealCitationInGraph returns false and does not switch panes for an unknown path")
    func revealCitationInGraphNoMatch() {
        let model = makeModel()

        let handled = model.revealCitationInGraph("src/pages/unknown.astro")

        #expect(!handled)
        #expect(model.mainPaneMode == .preview)
    }

    /// Review finding: `revealCitationInGraph`'s deferred `Task` used to call `revealNode`
    /// unconditionally, even when `showGraph()` aborted (e.g. an unresolved external-file
    /// conflict), mutating `graphExplorer`'s selection/search state while the user was still
    /// looking at the editor's conflict dialog. `showGraph()` now reports whether it actually
    /// switched, and `revealCitationInGraph` only reveals the node when it did.
    @Test("revealCitationInGraph doesn't touch graph state when showGraph aborts on an editor conflict")
    func revealCitationInGraphSkipsRevealWhenShowGraphAborts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let contentGraph = SiteContentGraph()
        await contentGraph.load(
            siteID: "site-1",
            pages: [SiteContentGraph.Page(
                id: "site-1:page:/about", siteID: "site-1", route: "/about",
                filePath: "src/pages/about.astro", title: "About", lastModified: Date()
            )],
            posts: [], images: []
        )
        let model = makeModel(contentGraph: contentGraph)
        model.graphExplorer.start(site: CurrentSite(id: "site-1", packageURL: root, sourceDirectory: root))
        while model.graphExplorer.snapshot.nodes.isEmpty { await Task.yield() }

        // A dirty editor whose file changed externally under it — `flushBeforeLeaving()`'s real
        // conflict path (same technique as `EditableFileSessionTests`'s `writeExternally`).
        let editedFile = root.appendingPathComponent("conflict.txt")
        try Data("original".utf8).write(to: editedFile)
        let fileRef = FileRef(url: editedFile, group: .components, name: "conflict.txt")
        let editorModel = FileEditorModel(file: fileRef)
        await editorModel.load()
        editorModel.text = "dirty edit"
        try Data("changed on disk".utf8).write(to: editedFile)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: editedFile.path
        )
        model.mainPaneMode = .editor(fileRef)
        model.activeEditor = .text(editorModel)

        let handled = model.revealCitationInGraph("src/pages/about.astro")
        #expect(handled)

        // Bounded poll (not unbounded) for the conflict to surface — the signal that
        // `showGraph()`'s deferred Task has finished running and aborted.
        var iterations = 0
        while editorModel.conflictDiskContents == nil, iterations < 10_000 {
            await Task.yield()
            iterations += 1
        }
        guard editorModel.conflictDiskContents != nil else {
            Issue.record("flushBeforeLeaving never surfaced the external conflict")
            return
        }

        #expect(model.mainPaneMode == .editor(fileRef))
        #expect(model.graphExplorer.selectedNodeID == nil)
    }
}

extension SiteWindowModelTests {
    private func siteWithNonexistentPackage(id: String = "site-a") -> SiteStore.Site {
        SiteStore.Site(
            id: id, name: "Test",
            packageURL: URL(fileURLWithPath: "/tmp/site-window-model-\(UUID().uuidString).anglesite"),
            isValid: true, missingSentinels: [], lastSeen: Date(), bookmarkData: nil
        )
    }

    @Test("presentDesignInterview builds a fresh model from the open site, defaulting business type to empty when the site has no .site-config")
    func presentDesignInterviewBuildsModel() {
        let model = makeModel()
        model.site = siteWithNonexistentPackage()

        model.presentDesignInterview()

        #expect(model.designInterviewModel != nil)
        #expect(model.designInterviewModel?.draft.businessType == "")
    }

    @Test("presentDesignInterview no-ops when there is no open site")
    func presentDesignInterviewNoSiteIsNoOp() {
        let model = makeModel()

        model.presentDesignInterview()

        #expect(model.designInterviewModel == nil)
    }

    @Test("presentDesignInterview doesn't replace an already-presented model")
    func presentDesignInterviewDoesNotReplaceExisting() {
        let model = makeModel()
        model.site = siteWithNonexistentPackage()
        model.presentDesignInterview()
        let first = model.designInterviewModel

        model.presentDesignInterview()

        #expect(model.designInterviewModel === first)
    }

    @Test("canOpenThemeApplyWizard requires both an open site and a resolvable bundled template")
    func canOpenThemeApplyWizardTracksSite() {
        let model = makeModel()
        #expect(model.canOpenThemeApplyWizard == false)

        model.site = siteWithNonexistentPackage()
        // No bundled/override template resolves in this test process, so a site alone must not
        // enable the menu item — the #1181 review flagged the earlier version of this check
        // (`site != nil` only) for exactly that drift: enabled, but a click silently no-ops.
        #expect(model.canOpenThemeApplyWizard == false)
    }

    @Test("openThemeApplyWizard no-ops when there is no open site")
    func openThemeApplyWizardNoSiteIsNoOp() {
        let model = makeModel()

        model.openThemeApplyWizard()

        #expect(model.themeApplyWizardModel == nil)
    }

    @Test("openThemeApplyWizard no-ops when the bundled template can't be resolved")
    func openThemeApplyWizardNoTemplateIsNoOp() throws {
        let model = makeModel()
        model.site = siteWithNonexistentPackage()
        let (settings, cleanup) = try makeIsolatedSettings()
        defer { cleanup() }
        let bareDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-apply-wizard-bare-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bareDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bareDir) }
        settings.templatePathOverride = bareDir // exists, but isn't a template directory

        model.openThemeApplyWizard(settings: settings)

        #expect(model.themeApplyWizardModel == nil)
    }

    @Test("openThemeApplyWizard builds a fresh model from the open site when the template resolves")
    func openThemeApplyWizardBuildsModel() throws {
        let model = makeModel()
        model.site = siteWithNonexistentPackage()
        let (settings, cleanup) = try makeIsolatedSettings()
        defer { cleanup() }
        let template = try makeFixtureThemeTemplate()
        defer { try? FileManager.default.removeItem(at: template) }
        settings.templatePathOverride = template

        model.openThemeApplyWizard(settings: settings)

        #expect(model.themeApplyWizardModel != nil)
        #expect(model.themeApplyWizardModel?.catalog.themes.map(\.id) == ["classic"])
        #expect(model.themeApplyWizardModel?.businessType == "")
    }

    /// An isolated `AppSettings` backed by its own `UserDefaults` suite, mirroring
    /// `TemplateRuntimeTests`' setup — never mutate `AppSettings.shared` directly, since that's a
    /// real singleton other tests/suites could observe.
    private func makeIsolatedSettings() throws -> (AppSettings, cleanup: () -> Void) {
        let suiteName = "test-anglesite-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (AppSettings(defaults: defaults), { defaults.removePersistentDomain(forName: suiteName) })
    }

    /// A minimal on-disk template — `scripts/themes.ts` (what `TemplateRuntime.isTemplateDirectory`
    /// checks for) plus `scripts/themes.json` (what `ThemeCatalog.load` actually reads) — good
    /// enough for `openThemeApplyWizard` to resolve a real one-theme catalog.
    private func makeFixtureThemeTemplate() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-apply-wizard-\(UUID().uuidString)")
        let scriptsDir = root.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        try Data("export const THEMES".utf8).write(to: scriptsDir.appendingPathComponent("themes.ts"))
        let themesJSON = """
        [
          {
            "id": "classic",
            "displayName": "Classic",
            "description": "Traditional, trustworthy, professional",
            "bestFor": ["legal"],
            "vars": { "color-primary": "#1e3a5f", "color-accent": "#c8a951" }
          }
        ]
        """
        try Data(themesJSON.utf8).write(to: scriptsDir.appendingPathComponent("themes.json"))
        return root
    }

    @Test("applyPendingDesignInterviewRequest presents the sheet when a request is pending for this site")
    func applyPendingDesignInterviewRequestConsumesPendingRequest() {
        let model = makeModel()
        model.site = siteWithNonexistentPackage()
        model.router.requestDesignInterview(siteID: "site-a")

        model.applyPendingDesignInterviewRequest(for: "site-a")

        #expect(model.designInterviewModel != nil)
    }

    @Test("applyPendingDesignInterviewRequest no-ops when nothing is pending for this site")
    func applyPendingDesignInterviewRequestNoPendingRequestIsNoOp() {
        let model = makeModel()
        model.site = siteWithNonexistentPackage()
        _ = model.router.consumeDesignInterviewRequest(for: "site-a")   // defensive: clear any stale request

        model.applyPendingDesignInterviewRequest(for: "site-a")

        #expect(model.designInterviewModel == nil)
    }

    /// #660: `loadAndStart` should warm the content graph at site-open rather than leaving
    /// `isPopulated` false until the first create/delete. This exercises the scan-and-load step
    /// directly (bypassing `loadAndStart`'s `SiteStore.shared` dependency, same seam gap noted
    /// throughout this file) against a real temp source directory.
    @Test("refreshContentGraph scans a real source directory and marks the site's content graph populated")
    func refreshContentGraphPopulatesFromSourceDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("site-window-model-\(UUID().uuidString)")
        let pagesDir = root.appendingPathComponent("src/pages")
        try FileManager.default.createDirectory(at: pagesDir, withIntermediateDirectories: true)
        try Data().write(to: pagesDir.appendingPathComponent("about.astro"))
        defer { try? FileManager.default.removeItem(at: root) }

        let graph = SiteContentGraph()
        let model = makeModel(contentGraph: graph)
        #expect(await graph.isPopulated(siteID: "site-a") == false)

        await model.refreshContentGraph(siteID: "site-a", sourceDirectory: root)

        #expect(await graph.isPopulated(siteID: "site-a") == true)
        let pages = await graph.pages(for: "site-a")
        #expect(pages.map(\.route) == ["/about"])
    }
}

extension SiteWindowModelTests {
    /// #714 slice 1, Task 3 review finding: `applyNavigatorSelection`'s `.directory` case had zero
    /// coverage. The tests below drive a real `SiteNavigatorModel` built from `buildSiteURLTree`
    /// (not a hand-rolled `NavigatorItem` stub), so `navigator.target(for:)` resolves through the
    /// same code path the live sidebar uses — and each asserts the target really is `.directory`
    /// before exercising the selection, so a future change to the tree builder can't silently turn
    /// these into a no-op. (`.websiteSettings` coverage moved to `openWebsiteSettingsOpensInfoPlist`
    /// below once the URL tree's pinned website row — the only source of a `.websiteSettings`
    /// navigator target — was removed in #714 v2 slice 1.)
    private func makeSitePackage(named name: String = "Test") throws -> (root: URL, packageURL: URL, package: AnglesitePackage) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("site-window-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let packageURL = root.appendingPathComponent("\(name).anglesite", isDirectory: true)
        let (package, _) = try AnglesitePackage.createSkeleton(at: packageURL, displayName: name)
        return (root, packageURL, package)
    }

    @Test("canOpenWebsiteSettings requires an open site")
    func canOpenWebsiteSettingsRequiresSite() {
        let model = makeModel()
        #expect(model.canOpenWebsiteSettings == false)
    }

    @Test("openWebsiteSettings opens the same package Info.plist as the navigator's .websiteSettings row (#959)")
    func openWebsiteSettingsOpensInfoPlist() async throws {
        let (root, packageURL, package) = try makeSitePackage()
        defer { try? FileManager.default.removeItem(at: root) }

        let model = makeModel()
        model.site = SiteStore.Site(
            id: "site-a", name: "Test", packageURL: packageURL,
            isValid: true, missingSentinels: [], lastSeen: Date(), bookmarkData: nil
        )
        #expect(model.canOpenWebsiteSettings)

        model.openWebsiteSettings()

        while model.activeEditor == nil { await Task.yield() }
        guard case .plist(let plistModel) = model.activeEditor else {
            Issue.record("expected the Info.plist to open as a .plist editor")
            return
        }
        #expect(plistModel.file.url == package.infoPlistURL)
        #expect(plistModel.file.group == .metadata)
    }

    /// Review finding on PR #1304: a declined leave (`leaveCurrentEditor`/`leaveCurrentInspector`
    /// returning `false` on an external conflict) used to return from `openFile`'s guard without
    /// clearing `pendingWebsiteSettingsTab`, so the stashed tab request would spuriously apply to
    /// the *next*, unrelated `.plist` editor open. Same real-conflict fixture as
    /// `presentCleanupAbortsOnEditorConflict`, but on `openWebsiteSettings(landOn:)`.
    @Test("openWebsiteSettings(landOn:) clears the pending tab when leaveCurrentEditor aborts, so a later unrelated open doesn't inherit it")
    func openWebsiteSettingsLandOnClearsPendingTabOnAbort() async throws {
        let (root, packageURL, package) = try makeSitePackage()
        defer { try? FileManager.default.removeItem(at: root) }

        let model = makeModel()
        model.site = SiteStore.Site(
            id: "site-a", name: "Test", packageURL: packageURL,
            isValid: true, missingSentinels: [], lastSeen: Date(), bookmarkData: nil
        )

        let editedFile = root.appendingPathComponent("conflict.txt")
        try Data("original".utf8).write(to: editedFile)
        let fileRef = FileRef(url: editedFile, group: .components, name: "conflict.txt")
        let editorModel = FileEditorModel(file: fileRef)
        await editorModel.load()
        editorModel.text = "dirty edit"
        try Data("changed on disk".utf8).write(to: editedFile)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: editedFile.path
        )
        model.mainPaneMode = .editor(fileRef)
        model.activeEditor = .text(editorModel)

        model.openWebsiteSettings(landOn: .securityReports)

        var iterations = 0
        while editorModel.conflictDiskContents == nil, iterations < 10_000 {
            await Task.yield()
            iterations += 1
        }
        guard editorModel.conflictDiskContents != nil else {
            Issue.record("flushBeforeLeaving never surfaced the external conflict")
            return
        }
        #expect(model.mainPaneMode == .editor(fileRef))
        #expect(model.activeEditor != nil)

        // Simulate the conflict being resolved (e.g. the user dismissed the alert and moved on)
        // by clearing the editor directly, then open Website Settings again with no tab request —
        // exactly like clicking the navigator's Website Settings row afterward. If
        // `pendingWebsiteSettingsTab` had leaked past the aborted call above, this unrelated open
        // would spuriously land on `.securityReports` instead of the default (`nil`) tab.
        model.activeEditor = nil
        model.mainPaneMode = .preview

        model.openWebsiteSettings()

        while model.activeEditor == nil { await Task.yield() }
        guard case .plist(let plistModel) = model.activeEditor else {
            Issue.record("expected the Info.plist to open as a .plist editor")
            return
        }
        #expect(plistModel.file.url == package.infoPlistURL)
        #expect(plistModel.requestedTab == nil)
    }

    /// Review finding on PR #1304 (#1312, finding 3): `pendingWebsiteSettingsTab` is a single
    /// shared `var`, and `openFile` spawns an independent `Task` per call with no de-duplication —
    /// two `openWebsiteSettings(landOn:)` calls issued back-to-back (e.g. a rapid double-click on
    /// the security-reports badge's "View all" button) each stash their tab and each spawn a `Task`
    /// that builds its own `PlistEditorModel`. Pre-fix, whichever `Task` assigns `activeEditor`
    /// last wins outright — discarding the other's model — and by then `pendingWebsiteSettingsTab`
    /// has already been consumed by whichever `Task` got there first, so the surviving editor lands
    /// on neither request. Fix: `openFile` coalesces a second call for the *same* file onto the
    /// already-in-flight `Task` instead of racing a second one against it.
    @Test("openWebsiteSettings(landOn:) issued twice back-to-back for the same file lands on the second (most recent) tab, not neither")
    func openWebsiteSettingsLandOnDoubleInvocationKeepsLatestTab() async throws {
        let (root, packageURL, package) = try makeSitePackage()
        defer { try? FileManager.default.removeItem(at: root) }

        let model = makeModel()
        model.site = SiteStore.Site(
            id: "site-a", name: "Test", packageURL: packageURL,
            isValid: true, missingSentinels: [], lastSeen: Date(), bookmarkData: nil
        )

        model.openWebsiteSettings(landOn: .analytics)
        model.openWebsiteSettings(landOn: .securityReports)

        while model.activeEditor == nil { await Task.yield() }
        // Give a pre-fix second `Task` every chance to also finish and overwrite `activeEditor`
        // with its own, tab-less model before asserting the settled state (same technique as
        // `applyNavigatorSelectionDirectoryNavigatesPreview`'s stale-task drain below).
        for _ in 0..<2_000 { await Task.yield() }

        guard case .plist(let plistModel) = model.activeEditor else {
            Issue.record("expected the Info.plist to open as a .plist editor")
            return
        }
        #expect(plistModel.file.url == package.infoPlistURL)
        #expect(plistModel.requestedTab == .securityReports)
    }

    @Test("applyNavigatorSelection navigates the preview to a directory's route for .directory, clearing any open editor/inspector")
    func applyNavigatorSelectionDirectoryNavigatesPreview() async throws {
        let (root, packageURL, package) = try makeSitePackage()
        defer { try? FileManager.default.removeItem(at: root) }

        let graph = SiteContentGraph()
        await graph.load(
            siteID: "site-a", pages: [],
            posts: [SiteContentGraph.Post(
                id: "site-a:post:hello", siteID: "site-a", collection: "notes", slug: "hello",
                title: "Hello", draft: false, publishDate: nil, tags: [],
                filePath: "src/content/notes/hello.md", lastModified: Date()
            )],
            images: []
        )
        let model = makeModel(contentGraph: graph)
        model.site = SiteStore.Site(
            id: "site-a", name: "Test", packageURL: packageURL,
            isValid: true, missingSentinels: [], lastSeen: Date(), bookmarkData: nil
        )
        // Seed a real open editor + inspector first, so the post-selection assertions prove
        // `.directory` actually clears them rather than trivially finding them already nil.
        let priorFile = FileRef(url: root.appendingPathComponent("dummy.astro"), group: .components, name: "dummy.astro")
        model.activeEditor = .text(FileEditorModel(file: priorFile))
        model.mainPaneMode = .editor(priorFile)
        model.inspectorContext = .page(PageMetadataModel(file: priorFile, route: "/dummy/", sourceDirectory: package.sourceURL))

        let navModel = SiteNavigatorModel(graph: graph)
        navModel.start(site: CurrentSite(id: "site-a", packageURL: packageURL, sourceDirectory: package.sourceURL))
        let directoryID = "dir:/notes/"
        // Poll for the tree actually resolving this row's target, not a node count — the pinned
        // website row that used to guarantee >= 2 top-level nodes is gone (#714 v2 slice 1), so a
        // count-based wait can spin forever on a fixture (like this one) whose only top-level row
        // is the directory itself.
        while navModel.target(for: directoryID) == nil { await Task.yield() }
        #expect(navModel.target(for: directoryID) == .directory(collection: "notes", route: "/notes/"))
        model.navigator = navModel

        // #714 final review, Important 3: `applyNavigatorSelection`'s `.directory` branch only
        // assigns `collectionInspection` once `navigator.selection` still matches the requested
        // id when its awaits resolve — the same liveness check `SiteNavigatorView`'s List binding
        // (which writes `selection`) and `SiteWindow`'s `.onChange(of: navigator.selection)`
        // (which then calls `applyNavigatorSelection`) provide together in production. Set it
        // first here to mirror that real sequencing.
        navModel.selection = directoryID
        model.applyNavigatorSelection(directoryID)

        // `.directory`'s body runs inside its own `Task { ... }`, same reasoning as the
        // `.websiteSettings` test above — poll for the final state rather than asserting inline.
        while model.mainPaneMode != .preview { await Task.yield() }
        #expect(model.activeEditor == nil)
        #expect(model.inspectorContext == nil)
        #expect(model.preview.activeRoute == "/notes/")

        // #714 slice 3: a directory selection populates the collection context.
        while model.collectionInspection == nil { await Task.yield() }
        let inspection = try #require(model.collectionInspection)
        #expect(inspection.collection == "notes")
        #expect(inspection.route == "/notes/")
        #expect(inspection.entryCount == 1)
        #expect(inspection.contentTypeName
            == ContentTypeRegistry.default.descriptor(forCollection: "notes")?.displayName)
    }

    @Test("the collection context carries probed feed routes, and a route selection clears it")
    func collectionInspectionFeedsAndClearing() async throws {
        let (root, packageURL, package) = try makeSitePackage()
        defer { try? FileManager.default.removeItem(at: root) }

        let graph = SiteContentGraph()
        await graph.load(
            siteID: "site-a",
            pages: [SiteContentGraph.Page(
                id: "site-a:page:/about", siteID: "site-a", route: "/about",
                filePath: "src/pages/about.md", title: "About", lastModified: Date()
            )],
            posts: [SiteContentGraph.Post(
                id: "site-a:post:hello", siteID: "site-a", collection: "notes", slug: "hello",
                title: "Hello", draft: false, publishDate: nil, tags: [],
                filePath: "src/content/notes/hello.md", lastModified: Date()
            )],
            images: []
        )
        let model = makeModel(contentGraph: graph)
        model.site = SiteStore.Site(
            id: "site-a", name: "Test", packageURL: packageURL,
            isValid: true, missingSentinels: [], lastSeen: Date(), bookmarkData: nil
        )
        // Materialize two of the three feed route modules the probe looks for.
        let notesPages = package.sourceURL.appendingPathComponent("src/pages/notes")
        try FileManager.default.createDirectory(at: notesPages, withIntermediateDirectories: true)
        try Data().write(to: notesPages.appendingPathComponent("rss.xml.ts"))
        try Data().write(to: notesPages.appendingPathComponent("atom.xml.ts"))

        let navModel = SiteNavigatorModel(graph: graph)
        navModel.start(
            site: CurrentSite(id: "site-a", packageURL: packageURL, sourceDirectory: package.sourceURL))
        while navModel.nodes.isEmpty { await Task.yield() }
        model.navigator = navModel
        let dirID = try #require(navModel.nodes.first(where: {
            if case .directory = $0.kind { return true } else { return false }
        })?.id)

        navModel.selection = dirID
        model.applyNavigatorSelection(dirID)
        while model.collectionInspection == nil { await Task.yield() }
        #expect(model.collectionInspection?.feeds.map(\.kind) == [.rss, .atom])

        // Selecting a routed page again clears the collection context. The `.route` branch also
        // guards its `collectionInspection = nil` on `navigator.selection` still matching the
        // request (#714 final review, Important 3 follow-up), so this must be set here too, same
        // as the directory selection above.
        navModel.selection = "site-a:page:/about"
        model.applyNavigatorSelection("site-a:page:/about")
        while model.collectionInspection != nil { await Task.yield() }
        #expect(model.collectionInspection == nil)
    }

    @Test("a stale .directory selection task never clobbers a newer selection's collection context (#714 final review, Important 3)")
    func applyNavigatorSelectionDirectoryStaleTaskDoesNotClobberNewerSelection() async throws {
        let (root, packageURL, package) = try makeSitePackage()
        defer { try? FileManager.default.removeItem(at: root) }

        let graph = SiteContentGraph()
        await graph.load(
            siteID: "site-a", pages: [],
            posts: [SiteContentGraph.Post(
                id: "site-a:post:hello", siteID: "site-a", collection: "notes", slug: "hello",
                title: "Hello", draft: false, publishDate: nil, tags: [],
                filePath: "src/content/notes/hello.md", lastModified: Date()
            )],
            images: []
        )
        let model = makeModel(contentGraph: graph)
        model.site = SiteStore.Site(
            id: "site-a", name: "Test", packageURL: packageURL,
            isValid: true, missingSentinels: [], lastSeen: Date(), bookmarkData: nil
        )
        let navModel = SiteNavigatorModel(graph: graph)
        navModel.start(
            site: CurrentSite(id: "site-a", packageURL: packageURL, sourceDirectory: package.sourceURL))
        let directoryID = "dir:/notes/"
        // Poll for the tree actually resolving this row's target, not a node count — see the
        // matching comment in `applyNavigatorSelectionDirectoryNavigatesPreview` above.
        while navModel.target(for: directoryID) == nil { await Task.yield() }
        #expect(navModel.target(for: directoryID) == .directory(collection: "notes", route: "/notes/"))
        model.navigator = navModel

        // `makeCollectionInspection` (invoked by the `.directory` Task below) awaits the
        // content-graph actor and a detached feed probe for a real collection like "notes" — real
        // suspension points. Simulate a faster subsequent selection landing in that window by
        // moving `navigator.selection` away *before yielding at all*: exactly what
        // `SiteWindow`'s `.onChange(of: navigator.selection)` does the instant a newer row is
        // clicked, and this synchronous call returns before the `.directory` Task's body has run
        // at all (it's merely enqueued), so there is no timing race to get wrong here.
        model.applyNavigatorSelection(directoryID)
        navModel.selection = "site-a:post:hello"

        // Give the stale task's awaits every chance to resolve and (pre-fix) assign anyway.
        for _ in 0..<2_000 { await Task.yield() }

        // Pre-fix, the `.directory` Task unconditionally assigned `collectionInspection` once its
        // awaits resolved, regardless of whether the selection had since moved on — and
        // `.collection` outranks `.page` in `inspectorSelection`, so it would have silently
        // shadowed whatever the newer selection put in the inspector. The fix bails unless
        // `navigator.selection` still matches the request, so this must stay nil.
        #expect(model.collectionInspection == nil)
    }

    @Test("a stale .route selection task never installs a stale page context over a newer selection (#714 final review, Important 3 follow-up)")
    func applyNavigatorSelectionRouteStaleTaskDoesNotClobberNewerSelection() async throws {
        let (root, packageURL, package) = try makeSitePackage()
        defer { try? FileManager.default.removeItem(at: root) }

        let graph = SiteContentGraph()
        await graph.load(
            siteID: "site-a",
            pages: [SiteContentGraph.Page(
                id: "site-a:page:/about", siteID: "site-a", route: "/about",
                filePath: "src/pages/about.md", title: "About", lastModified: Date()
            )],
            posts: [SiteContentGraph.Post(
                id: "site-a:post:hello", siteID: "site-a", collection: "notes", slug: "hello",
                title: "Hello", draft: false, publishDate: nil, tags: [],
                filePath: "src/content/notes/hello.md", lastModified: Date()
            )],
            images: []
        )
        let model = makeModel(contentGraph: graph)
        model.site = SiteStore.Site(
            id: "site-a", name: "Test", packageURL: packageURL,
            isValid: true, missingSentinels: [], lastSeen: Date(), bookmarkData: nil
        )
        let navModel = SiteNavigatorModel(graph: graph)
        navModel.start(
            site: CurrentSite(id: "site-a", packageURL: packageURL, sourceDirectory: package.sourceURL))
        let routeID = "site-a:page:/about"
        let directoryID = "dir:/notes/"
        // Poll for the tree actually resolving both rows' targets, not a node count — see the
        // matching comment in `applyNavigatorSelectionDirectoryNavigatesPreview` above.
        while navModel.target(for: routeID) == nil || navModel.target(for: directoryID) == nil {
            await Task.yield()
        }
        #expect(navModel.target(for: routeID) == .route("/about"))
        #expect(navModel.target(for: directoryID) == .directory(collection: "notes", route: "/notes/"))
        model.navigator = navModel

        // Select route A first — its Task awaits `leaveCurrentEditor`/`leaveCurrentInspector` and
        // then the content-graph actor inside `makeInspectorContext`, real suspension points — then
        // move `navigator.selection` to the directory *before yielding at all*: this synchronous
        // call returns before the `.route` Task's body has run at all (it's merely enqueued), so
        // there is no timing race to get wrong here, mirroring the `.directory` stale-task test
        // above (this is the reverse case — the `.route` branch's own `collectionInspection = nil`
        // is the unguarded mirror of that bug).
        navModel.selection = routeID
        model.applyNavigatorSelection(routeID)
        navModel.selection = directoryID

        // Give the stale task's awaits every chance to resolve and (pre-fix) assign anyway.
        for _ in 0..<2_000 { await Task.yield() }

        // Pre-fix, the `.route` Task unconditionally installed `inspectorContext` once its awaits
        // resolved, regardless of whether the selection had since moved on to a directory — this
        // fixture's `/about` page has frontmatter, so it would have become a live `.page` context.
        // The fix bails unless `navigator.selection` still matches the request, so the stale page
        // context must never install.
        #expect(model.inspectorContext == nil)
    }

    @Test("the collection context for a plain nested-page folder (no collection) counts child pages, not graph posts")
    func collectionInspectionPlainFolderHasNoCollectionOrFeeds() async throws {
        let (root, packageURL, package) = try makeSitePackage()
        defer { try? FileManager.default.removeItem(at: root) }

        let graph = SiteContentGraph()
        await graph.load(
            siteID: "site-a",
            pages: [
                SiteContentGraph.Page(
                    id: "site-a:page:/blog", siteID: "site-a", route: "/blog",
                    filePath: "src/pages/blog/index.astro", title: "Blog", lastModified: Date()
                ),
                SiteContentGraph.Page(
                    id: "site-a:page:/blog/hello", siteID: "site-a", route: "/blog/hello",
                    filePath: "src/pages/blog/hello.astro", title: "Hello", lastModified: Date()
                ),
            ],
            posts: [], images: []
        )
        let model = makeModel(contentGraph: graph)
        model.site = SiteStore.Site(
            id: "site-a", name: "Test", packageURL: packageURL,
            isValid: true, missingSentinels: [], lastSeen: Date(), bookmarkData: nil
        )

        let navModel = SiteNavigatorModel(graph: graph)
        navModel.start(
            site: CurrentSite(id: "site-a", packageURL: packageURL, sourceDirectory: package.sourceURL))
        while navModel.nodes.isEmpty { await Task.yield() }
        model.navigator = navModel
        let dirID = "dir:/blog/"
        #expect(navModel.target(for: dirID) == .directory(collection: nil, route: "/blog/"))
        let expectedEntryCount = navModel.node(for: dirID)?.children?.count ?? 0

        navModel.selection = dirID
        model.applyNavigatorSelection(dirID)
        while model.collectionInspection == nil { await Task.yield() }
        let inspection = try #require(model.collectionInspection)
        #expect(inspection.collection == nil)
        #expect(inspection.feeds.isEmpty)
        #expect(inspection.contentTypeName == nil)
        #expect(inspection.microformat == nil)
        #expect(inspection.entryCount == expectedEntryCount)
    }

    @Test("applyNavigatorSelection populates a read-only inspector for a plain .astro page (#1100)")
    func applyNavigatorSelectionPlainAstroPageGetsGenericInspector() async throws {
        let (root, packageURL, package) = try makeSitePackage()
        defer { try? FileManager.default.removeItem(at: root) }

        // Most of a real site's pages are plain .astro (only the "about" singleton and content
        // collection entries get a typed/markdown editor) — Home is the common case that made the
        // View ▸ Inspector ▸ Show Inspector command look permanently disabled (#1100).
        let graph = SiteContentGraph()
        await graph.load(
            siteID: "site-a",
            pages: [SiteContentGraph.Page(
                id: "site-a:page:/", siteID: "site-a", route: "/",
                filePath: "src/pages/index.astro", title: "Home", lastModified: Date()
            )],
            posts: [], images: []
        )
        let model = makeModel(contentGraph: graph)
        model.site = SiteStore.Site(
            id: "site-a", name: "Test", packageURL: packageURL,
            isValid: true, missingSentinels: [], lastSeen: Date(), bookmarkData: nil
        )
        let navModel = SiteNavigatorModel(graph: graph)
        navModel.start(site: CurrentSite(id: "site-a", packageURL: packageURL, sourceDirectory: package.sourceURL))
        while navModel.nodes.isEmpty { await Task.yield() }
        model.navigator = navModel

        navModel.selection = "site-a:page:/"
        model.applyNavigatorSelection("site-a:page:/")

        while model.inspectorContext == nil { await Task.yield() }
        guard case .generic(let generic) = model.inspectorContext else {
            Issue.record("expected a .generic read-only inspector context for a plain .astro page")
            return
        }
        #expect(generic.route == "/")
        #expect(generic.file.url == package.sourceURL.appendingPathComponent("src/pages/index.astro"))
        #expect(generic.isDirty == false)
    }
}

extension SiteWindowModelTests {
    /// Review finding (#714 slice 1, Task 4): `presentCleanup()` — the Site ▸ Cleanup… entry
    /// point that replaced the old sidebar Cleanup row — had zero coverage. Mirrors `showGraph()`'s
    /// leave-current-surface-first guard, so these tests follow the same conventions as the
    /// `.websiteSettings`/`.directory` `applyNavigatorSelection` tests above (real package fixture,
    /// poll for the async `Task { ... }` body to land) and the `revealCitationInGraph` conflict test
    /// (real dirty-editor-with-external-change fixture to prove the guard actually aborts).
    @Test("presentCleanup switches the main pane to Cleanup, clearing any open editor/inspector")
    func presentCleanupSwitchesPane() async throws {
        let (root, packageURL, package) = try makeSitePackage()
        defer { try? FileManager.default.removeItem(at: root) }

        let model = makeModel()
        model.site = SiteStore.Site(
            id: "site-a", name: "Test", packageURL: packageURL,
            isValid: true, missingSentinels: [], lastSeen: Date(), bookmarkData: nil
        )
        // Seed a real open editor + inspector first, so the post-call assertions prove
        // `presentCleanup()` actually clears them rather than trivially finding them already nil
        // (same anti-tautology technique as `applyNavigatorSelectionDirectoryNavigatesPreview`).
        let priorFile = FileRef(url: root.appendingPathComponent("dummy.astro"), group: .components, name: "dummy.astro")
        model.activeEditor = .text(FileEditorModel(file: priorFile))
        model.mainPaneMode = .editor(priorFile)
        model.inspectorContext = .page(PageMetadataModel(file: priorFile, route: "/dummy/", sourceDirectory: package.sourceURL))

        model.presentCleanup()

        // `presentCleanup()`'s body runs inside its own `Task { ... }` after awaiting
        // `leaveCurrentEditor()`/`leaveCurrentInspector()` — both no-ops here, but still real
        // suspension points, so poll rather than assert inline (same pattern as
        // `applyNavigatorSelection`'s `.websiteSettings`/`.directory` tests).
        while model.mainPaneMode != .cleanup { await Task.yield() }
        #expect(model.activeEditor == nil)
        #expect(model.inspectorContext == nil)
    }

    /// Mirrors `revealCitationInGraphSkipsRevealWhenShowGraphAborts`'s real external-conflict
    /// fixture: a dirty editor whose file changed on disk under it makes `flushBeforeLeaving()`
    /// (invoked via `leaveCurrentEditor()`) return `false`, so `presentCleanup()`'s guard should
    /// abort before touching `mainPaneMode`/`activeEditor`.
    @Test("presentCleanup doesn't switch panes when leaveCurrentEditor aborts on an editor conflict")
    func presentCleanupAbortsOnEditorConflict() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let model = makeModel()
        let editedFile = root.appendingPathComponent("conflict.txt")
        try Data("original".utf8).write(to: editedFile)
        let fileRef = FileRef(url: editedFile, group: .components, name: "conflict.txt")
        let editorModel = FileEditorModel(file: fileRef)
        await editorModel.load()
        editorModel.text = "dirty edit"
        try Data("changed on disk".utf8).write(to: editedFile)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: editedFile.path
        )
        model.mainPaneMode = .editor(fileRef)
        model.activeEditor = .text(editorModel)

        model.presentCleanup()

        // Bounded poll for the conflict to surface — the signal that `presentCleanup()`'s
        // deferred Task has finished running and aborted (same bounded-poll reasoning as
        // `revealCitationInGraphSkipsRevealWhenShowGraphAborts`, since on the abort path there's
        // no discriminating state change other than the editor's own conflict flag to poll on).
        var iterations = 0
        while editorModel.conflictDiskContents == nil, iterations < 10_000 {
            await Task.yield()
            iterations += 1
        }
        guard editorModel.conflictDiskContents != nil else {
            Issue.record("flushBeforeLeaving never surfaced the external conflict")
            return
        }

        #expect(model.mainPaneMode == .editor(fileRef))
        #expect(model.activeEditor != nil)
    }

    /// Mirrors `presentCleanupSwitchesPane` for `presentReader()` (V-4.3, #365) — same
    /// leave-current-surface-first guard.
    @Test("presentReader switches the main pane to Reader, clearing any open editor/inspector")
    func presentReaderSwitchesPane() async throws {
        let (root, packageURL, package) = try makeSitePackage()
        defer { try? FileManager.default.removeItem(at: root) }

        let model = makeModel()
        model.site = SiteStore.Site(
            id: "site-a", name: "Test", packageURL: packageURL,
            isValid: true, missingSentinels: [], lastSeen: Date(), bookmarkData: nil
        )
        let priorFile = FileRef(url: root.appendingPathComponent("dummy.astro"), group: .components, name: "dummy.astro")
        model.activeEditor = .text(FileEditorModel(file: priorFile))
        model.mainPaneMode = .editor(priorFile)
        model.inspectorContext = .page(PageMetadataModel(file: priorFile, route: "/dummy/", sourceDirectory: package.sourceURL))

        model.presentReader()

        while model.mainPaneMode != .reader { await Task.yield() }
        #expect(model.activeEditor == nil)
        #expect(model.inspectorContext == nil)
    }

    /// Mirrors `presentCleanupAbortsOnEditorConflict` for `presentReader()`.
    @Test("presentReader doesn't switch panes when leaveCurrentEditor aborts on an editor conflict")
    func presentReaderAbortsOnEditorConflict() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let model = makeModel()
        let editedFile = root.appendingPathComponent("conflict.txt")
        try Data("original".utf8).write(to: editedFile)
        let fileRef = FileRef(url: editedFile, group: .components, name: "conflict.txt")
        let editorModel = FileEditorModel(file: fileRef)
        await editorModel.load()
        editorModel.text = "dirty edit"
        try Data("changed on disk".utf8).write(to: editedFile)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: editedFile.path
        )
        model.mainPaneMode = .editor(fileRef)
        model.activeEditor = .text(editorModel)

        model.presentReader()

        var iterations = 0
        while editorModel.conflictDiskContents == nil, iterations < 10_000 {
            await Task.yield()
            iterations += 1
        }
        guard editorModel.conflictDiskContents != nil else {
            Issue.record("flushBeforeLeaving never surfaced the external conflict")
            return
        }

        #expect(model.mainPaneMode == .editor(fileRef))
        #expect(model.activeEditor != nil)
    }

    @Test("ensureComponentEditorLoaded creates the hoisted editor for a component file, and rebuilds for a different file")
    func ensureComponentEditorLifecycle() async throws {
        let (root, packageURL, package) = try makeSitePackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel()
        model.site = SiteStore.Site(
            id: "site-a", name: "Test", packageURL: packageURL,
            isValid: true, missingSentinels: [], lastSeen: Date(), bookmarkData: nil
        )
        let card = FileRef(
            url: package.sourceURL.appendingPathComponent("src/components/Card.astro"),
            group: .components, name: "Card.astro")
        model.activeEditor = .text(FileEditorModel(file: card))
        model.mainPaneMode = .editor(card)

        await model.ensureComponentEditorLoaded()
        let first = try #require(model.componentEditor)
        #expect(first.file.id == card.id)

        // A same-file, same-baseURL repeat call is deliberately not asserted as idempotent here:
        // this harness has no live MCP client, so `load()` never succeeds and `first` is never
        // healthy — see `ensureComponentEditorLoadedRebuildsAfterUnhealthyLoad` below, which
        // exercises exactly that "unhealthy → rebuild" behavior instead (#714 final review,
        // Important 2).

        let badge = FileRef(
            url: package.sourceURL.appendingPathComponent("src/components/Badge.astro"),
            group: .components, name: "Badge.astro")
        model.activeEditor = .text(FileEditorModel(file: badge))
        model.mainPaneMode = .editor(badge)
        await model.ensureComponentEditorLoaded()
        #expect(model.componentEditor !== first)
        #expect(model.componentEditor?.file.id == badge.id)
    }

    @Test("ensureComponentEditorLoaded rebuilds after an unhealthy load instead of wedging the same broken instance forever")
    func ensureComponentEditorLoadedRebuildsAfterUnhealthyLoad() async throws {
        let (root, packageURL, package) = try makeSitePackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel()
        model.site = SiteStore.Site(
            id: "site-a", name: "Test", packageURL: packageURL,
            isValid: true, missingSentinels: [], lastSeen: Date(), bookmarkData: nil
        )
        let card = FileRef(
            url: package.sourceURL.appendingPathComponent("src/components/Card.astro"),
            group: .components, name: "Card.astro")
        model.activeEditor = .text(FileEditorModel(file: card))
        model.mainPaneMode = .editor(card)

        await model.ensureComponentEditorLoaded()
        let first = try #require(model.componentEditor)
        // No dev server is live in this test harness (`NeverStartedSiteRuntimeFactory` never
        // starts a real runtime), but its `UnavailableSiteRuntime.mcpClient` is still a real,
        // non-nil (just never-`start()`ed) `MCPClient` — so the fetch doesn't fail with
        // `ComponentModelClient.ModelError.notConnected`, it fails when that client's own
        // `callTool` throws `MCPError.notInitialized`, which isn't a `ComponentModelClient
        // .ModelError` at all and so lands in `load()`'s generic `catch` as `.other`. Confirm
        // that's really what happened — and that it left the model unhealthy — before relying on
        // it to exercise the guard below, rather than assuming.
        #expect(first.loadErrorReason == .other)
        #expect(first.loadError != nil)
        #expect(first.model == nil)

        // Same file, same (nil) baseURL — the pre-fix early return kept `first` forever purely on
        // that identity match, regardless of whether its load actually succeeded (#714 final
        // review, Important 2 — a `CancellationError` from a pane toggle mid-load lands in the
        // exact same generic `catch` as `.other`, so this failure mode is a faithful stand-in for
        // that one too). The fix only takes the early return when the existing model is healthy,
        // so this unhealthy `first` must be rebuilt, not returned again.
        await model.ensureComponentEditorLoaded()
        #expect(model.componentEditor !== first)
        #expect(model.componentEditor?.file.id == card.id)
    }

    @Test("ensureComponentEditorLoaded clears the hoisted editor for a non-component file")
    func ensureComponentEditorClearsForNonComponent() async throws {
        let (root, packageURL, package) = try makeSitePackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel()
        model.site = SiteStore.Site(
            id: "site-a", name: "Test", packageURL: packageURL,
            isValid: true, missingSentinels: [], lastSeen: Date(), bookmarkData: nil
        )
        let card = FileRef(
            url: package.sourceURL.appendingPathComponent("src/components/Card.astro"),
            group: .components, name: "Card.astro")
        model.activeEditor = .text(FileEditorModel(file: card))
        model.mainPaneMode = .editor(card)
        await model.ensureComponentEditorLoaded()
        #expect(model.componentEditor != nil)

        let style = FileRef(
            url: package.sourceURL.appendingPathComponent("src/styles/global.css"),
            group: .styles, name: "global.css")
        model.activeEditor = .text(FileEditorModel(file: style))
        model.mainPaneMode = .editor(style)
        await model.ensureComponentEditorLoaded()
        #expect(model.componentEditor == nil)
    }

    @Test("inspectorSelection surfaces the component editor only while its file is the open editor pane")
    func inspectorSelectionComponentGating() async throws {
        let (root, packageURL, package) = try makeSitePackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel()
        model.site = SiteStore.Site(
            id: "site-a", name: "Test", packageURL: packageURL,
            isValid: true, missingSentinels: [], lastSeen: Date(), bookmarkData: nil
        )
        let card = FileRef(
            url: package.sourceURL.appendingPathComponent("src/components/Card.astro"),
            group: .components, name: "Card.astro")
        model.activeEditor = .text(FileEditorModel(file: card))
        model.mainPaneMode = .editor(card)
        await model.ensureComponentEditorLoaded()

        guard case .component = model.inspectorSelection else {
            Issue.record("expected .component while the component file is the open editor")
            return
        }
        // The model survives the Preview toggle (same lifetime as the editor buffer) but stops
        // surfacing as the inspector's subject.
        model.mainPaneMode = .preview
        #expect(model.componentEditor != nil)
        #expect(model.inspectorSelection == nil)
    }

    @Test("inspectorSelection memoizes the WYSIWYGInspectorModel per blockId+src, rebuilding only when either changes (#1672 final review)")
    func inspectorSelectionMemoizesWYSIWYGInspectorModel() async throws {
        let (root, packageURL, _) = try makeSitePackage()
        defer { try? FileManager.default.removeItem(at: root) }

        // Two real `img` nodes, seeded directly in the fetched page model (rather than inserted
        // through a submitted op) — `enterEditMode` wires a real `SidecarWYSIWYGHostTransport`,
        // and `FakeGetPageModelTransport` only answers `get_page_model`, not `apply_edit`, so a
        // submitted op would just be rejected. Seeding both blocks up front lets this test drive
        // the cache purely by moving `selectedBlockId` — the same direct-write pattern the
        // `applyNavigatorSelection...ClearsStaleWYSIWYGSelection` tests above already use.
        let pageModel = PageModel(
            version: "sha256:test00000000", path: "src/pages/index.astro",
            tree: .init(
                id: "root", kind: .fragment, tag: nil, attrs: [], span: .init(start: 0, end: 0),
                loc: nil, text: nil,
                children: [
                    .init(
                        id: "b1", kind: .element, tag: "img",
                        attrs: [.init(name: "src", value: "/images/test.png")],
                        span: .init(start: 0, end: 0), loc: nil, text: nil, children: [], block: nil),
                    .init(
                        id: "b2", kind: .element, tag: "img",
                        attrs: [.init(name: "src", value: "/images/other.png")],
                        span: .init(start: 0, end: 0), loc: nil, text: nil, children: [], block: nil),
                ],
                block: nil))
        let client = try await makeFakeGetPageModelClient(pageModel: pageModel)
        let model = SiteWindowModel(
            contentGraph: SiteContentGraph(),
            knowledgeIndex: SiteKnowledgeIndex(),
            semanticRanker: nil,
            conventionsEngine: ProjectConventionsEngine(),
            runtimeFactory: FakeGetPageModelSiteRuntimeFactory(mcpClient: client),
            contentIndexerStore: ContentIndexerStore()
        )
        model.site = SiteStore.Site(
            id: "site-a", name: "Test", packageURL: packageURL,
            isValid: true, missingSentinels: [], lastSeen: Date(), bookmarkData: nil
        )

        await model.preview.enterEditMode(path: "src/pages/index.astro", undoManager: nil)
        model.preview.wysiwygCanvas?.selectedBlockId = "b1"

        guard case .wysiwygBlock(let first) = model.inspectorSelection else {
            Issue.record("expected .wysiwygBlock while a block is selected")
            return
        }
        // A second access with nothing changed must reuse the exact same instance — this is what
        // stops the license section's file read + XMP parse from re-running on every render pass.
        guard case .wysiwygBlock(let second) = model.inspectorSelection else {
            Issue.record("expected .wysiwygBlock on the second access")
            return
        }
        #expect(first === second)

        // Selecting a different block (a different blockId AND a different src, exactly like the
        // cache-key tuple's two independent fields) must rebuild rather than keep serving the
        // first block's model.
        model.preview.wysiwygCanvas?.selectedBlockId = "b2"

        guard case .wysiwygBlock(let third) = model.inspectorSelection else {
            Issue.record("expected .wysiwygBlock after selecting a different block")
            return
        }
        #expect(third !== first)
    }

    @Test("applyNavigatorSelection's .route branch clears a stale WYSIWYG block selection, so it can't shadow the new page context (#1588 Task 8 follow-up)")
    func applyNavigatorSelectionRouteClearsStaleWYSIWYGSelection() async throws {
        let (root, packageURL, package) = try makeSitePackage()
        defer { try? FileManager.default.removeItem(at: root) }

        let graph = SiteContentGraph()
        await graph.load(
            siteID: "site-a",
            pages: [SiteContentGraph.Page(
                id: "site-a:page:/about", siteID: "site-a", route: "/about",
                filePath: "src/pages/about.md", title: "About", lastModified: Date()
            )],
            posts: [], images: []
        )
        // `enterEditMode(path:)` (#1222) needs a started `MCPClient` answering `get_page_model` —
        // `makeModel(contentGraph:)`'s `NeverStartedSiteRuntimeFactory` leaves the client
        // unstarted, so the fetch would fail and `wysiwygCanvas` would never mount. Wire the same
        // fake transport `PreviewModelWYSIWYGTests`/`WYSIWYGPlumbingIntegrationTests` use instead.
        let pageModel = PageModel(
            version: "sha256:test00000000", path: "src/pages/about.md",
            tree: .init(
                id: "root", kind: .fragment, tag: nil, attrs: [], span: .init(start: 0, end: 0),
                loc: nil, text: nil, children: [], block: nil))
        let client = try await makeFakeGetPageModelClient(pageModel: pageModel)
        let model = SiteWindowModel(
            contentGraph: graph,
            knowledgeIndex: SiteKnowledgeIndex(),
            semanticRanker: nil,
            conventionsEngine: ProjectConventionsEngine(),
            runtimeFactory: FakeGetPageModelSiteRuntimeFactory(mcpClient: client),
            contentIndexerStore: ContentIndexerStore()
        )
        model.site = SiteStore.Site(
            id: "site-a", name: "Test", packageURL: packageURL,
            isValid: true, missingSentinels: [], lastSeen: Date(), bookmarkData: nil
        )

        // Turn on edit mode and select a block — mirrors the owner clicking a block in the
        // canvas before navigating elsewhere in the sidebar. Edit mode is a toggle independent of
        // `mainPaneMode`/navigator selection, so nothing about the navigation below touches it on
        // its own; `applyNavigatorSelection` must clear `selectedBlockId` explicitly.
        await model.preview.enterEditMode(path: "src/pages/about.md", undoManager: nil)
        model.preview.wysiwygCanvas?.selectedBlockId = "b1"
        guard case .wysiwygBlock = model.inspectorSelection else {
            Issue.record("expected .wysiwygBlock while a block is selected in edit mode")
            return
        }

        let navModel = SiteNavigatorModel(graph: graph)
        navModel.start(
            site: CurrentSite(id: "site-a", packageURL: packageURL, sourceDirectory: package.sourceURL))
        while navModel.nodes.isEmpty { await Task.yield() }
        let routeID = "site-a:page:/about"
        #expect(navModel.target(for: routeID) == .route("/about"))
        model.navigator = navModel

        navModel.selection = routeID
        model.applyNavigatorSelection(routeID)

        // `.route`'s body runs inside its own `Task { ... }` — poll for the final state rather
        // than asserting inline, same technique as the other `applyNavigatorSelection` tests above.
        while model.inspectorContext == nil { await Task.yield() }
        #expect(model.preview.wysiwygCanvas?.selectedBlockId == nil)
        guard case .page = model.inspectorSelection else {
            Issue.record("expected the stale .wysiwygBlock selection to no longer shadow the new .page context")
            return
        }
    }

    @Test("applyNavigatorSelection's .directory branch clears a stale WYSIWYG block selection, so it can't shadow the new collection context (#1588 Task 8 follow-up)")
    func applyNavigatorSelectionDirectoryClearsStaleWYSIWYGSelection() async throws {
        let (root, packageURL, package) = try makeSitePackage()
        defer { try? FileManager.default.removeItem(at: root) }

        let graph = SiteContentGraph()
        await graph.load(
            siteID: "site-a", pages: [],
            posts: [SiteContentGraph.Post(
                id: "site-a:post:hello", siteID: "site-a", collection: "notes", slug: "hello",
                title: "Hello", draft: false, publishDate: nil, tags: [],
                filePath: "src/content/notes/hello.md", lastModified: Date()
            )],
            images: []
        )
        // See the `.route` test above for why this test needs a started fake `get_page_model`
        // client rather than `makeModel(contentGraph:)`'s never-started runtime.
        let pageModel = PageModel(
            version: "sha256:test00000000", path: "src/pages/index.astro",
            tree: .init(
                id: "root", kind: .fragment, tag: nil, attrs: [], span: .init(start: 0, end: 0),
                loc: nil, text: nil, children: [], block: nil))
        let client = try await makeFakeGetPageModelClient(pageModel: pageModel)
        let model = SiteWindowModel(
            contentGraph: graph,
            knowledgeIndex: SiteKnowledgeIndex(),
            semanticRanker: nil,
            conventionsEngine: ProjectConventionsEngine(),
            runtimeFactory: FakeGetPageModelSiteRuntimeFactory(mcpClient: client),
            contentIndexerStore: ContentIndexerStore()
        )
        model.site = SiteStore.Site(
            id: "site-a", name: "Test", packageURL: packageURL,
            isValid: true, missingSentinels: [], lastSeen: Date(), bookmarkData: nil
        )

        await model.preview.enterEditMode(path: "src/pages/index.astro", undoManager: nil)
        model.preview.wysiwygCanvas?.selectedBlockId = "b1"
        guard case .wysiwygBlock = model.inspectorSelection else {
            Issue.record("expected .wysiwygBlock while a block is selected in edit mode")
            return
        }

        let navModel = SiteNavigatorModel(graph: graph)
        navModel.start(site: CurrentSite(id: "site-a", packageURL: packageURL, sourceDirectory: package.sourceURL))
        // One post in one collection ("notes") and no pages builds exactly one top-level
        // directory node (`buildSiteURLTree`'s `buildTopLevel`), so polling for `nodes.count`
        // to reach 2 would spin forever — poll for non-empty instead, matching the `.route` test
        // above.
        while navModel.nodes.isEmpty { await Task.yield() }
        let directoryID = "dir:/notes/"
        #expect(navModel.target(for: directoryID) == .directory(collection: "notes", route: "/notes/"))
        model.navigator = navModel

        navModel.selection = directoryID
        model.applyNavigatorSelection(directoryID)

        while model.collectionInspection == nil { await Task.yield() }
        #expect(model.preview.wysiwygCanvas?.selectedBlockId == nil)
        guard case .collection = model.inspectorSelection else {
            Issue.record("expected the stale .wysiwygBlock selection to no longer shadow the new .collection context")
            return
        }
    }

    @Test("ensureWebsiteInspectorLoaded creates the website inspector once and clears it on site change (#714 v2 slice 1)")
    func websiteInspectorLifecycle() async throws {
        let (root, packageURL, _) = try makeSitePackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel()
        model.site = SiteStore.Site(
            id: "site-a", name: "Test", packageURL: packageURL,
            isValid: true, missingSentinels: [], lastSeen: Date(), bookmarkData: nil
        )

        model.ensureWebsiteInspectorLoaded()
        let first = try #require(model.websiteInspector)
        #expect(first.packageURL == packageURL)

        model.ensureWebsiteInspectorLoaded()
        #expect(model.websiteInspector === first)

        model.handleSiteChanged()
        #expect(model.websiteInspector == nil)
    }

    /// Waits (bounded) for `ensureWebsiteInspectorLoaded()`'s fire-and-forget `load()` `Task` to
    /// land, using the same title-becomes-nonempty signal `WebsiteInspectorModelTests` doesn't
    /// need (it awaits `load()` directly) but this file does, since the load here runs on a
    /// detached `Task` this test has no handle to.
    private func waitForWebsiteInspectorLoad(_ inspector: WebsiteInspectorModel) async {
        var iterations = 0
        while inspector.title.isEmpty, iterations < 10_000 {
            await Task.yield()
            iterations += 1
        }
        // Hardens the helper itself (fix round 2 re-review): distinguishes "load landed" from
        // "the bounded loop gave up with the title still empty" — a fixture whose title happens
        // to be empty, or a load that silently fails, would otherwise let every caller proceed
        // as if loading had succeeded.
        #expect(!inspector.title.isEmpty)
    }

    @Test("close(...) flushes a dirty websiteInspector before clearing it, retaining the sudden-termination lease until the save finishes (fix round 1, Important 2)")
    func closeFlushesAndClearsDirtyWebsiteInspector() async throws {
        let (root, packageURL, _) = try makeSitePackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel()
        model.site = SiteStore.Site(
            id: "site-a", name: "Test", packageURL: packageURL,
            isValid: true, missingSentinels: [], lastSeen: Date(), bookmarkData: nil
        )
        model.ensureWebsiteInspectorLoaded()
        let inspector = try #require(model.websiteInspector)
        await waitForWebsiteInspectorLoad(inspector)
        inspector.title = "Renamed via inspector"
        #expect(inspector.isDirty)

        let controller = SuddenTerminationController(disable: {}, enable: {})
        let lease = controller.acquire()
        model.close(suddenTerminationLease: lease)

        // Cleared synchronously, in the same transaction as `close(...)` — the review's finding
        // was that this already happened, just three lines below a flush that never occurred.
        #expect(model.websiteInspector == nil)

        while controller.activeLeaseCount > 0 {
            await Task.yield()
        }

        let reread = WebsiteInspectorModel(packageURL: packageURL)
        await reread.load()
        #expect(reread.title == "Renamed via inspector")
    }

    @Test("hasUnsavedEdits is true while the website inspector has a dirty field (fix round 1, Important 2)")
    func hasUnsavedEditsReflectsDirtyWebsiteInspector() async throws {
        let (root, packageURL, _) = try makeSitePackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel()
        model.site = SiteStore.Site(
            id: "site-a", name: "Test", packageURL: packageURL,
            isValid: true, missingSentinels: [], lastSeen: Date(), bookmarkData: nil
        )
        model.ensureWebsiteInspectorLoaded()
        let inspector = try #require(model.websiteInspector)
        await waitForWebsiteInspectorLoad(inspector)
        #expect(!model.hasUnsavedEdits)

        inspector.title = "Dirtied"
        #expect(model.hasUnsavedEdits)
    }

    @Test("handleSiteChanged flushes a dirty websiteInspector before clearing it (fix round 1, Important 2)")
    func handleSiteChangedFlushesDirtyWebsiteInspector() async throws {
        let (root, packageURL, _) = try makeSitePackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel()
        model.site = SiteStore.Site(
            id: "site-a", name: "Test", packageURL: packageURL,
            isValid: true, missingSentinels: [], lastSeen: Date(), bookmarkData: nil
        )
        model.ensureWebsiteInspectorLoaded()
        let inspector = try #require(model.websiteInspector)
        await waitForWebsiteInspectorLoad(inspector)
        inspector.title = "Renamed on replay"

        model.handleSiteChanged()
        #expect(model.websiteInspector == nil)

        var iterations = 0
        while inspector.isDirty, iterations < 10_000 {
            await Task.yield()
            iterations += 1
        }
        #expect(!inspector.isDirty)

        let reread = WebsiteInspectorModel(packageURL: packageURL)
        await reread.load()
        #expect(reread.title == "Renamed on replay")
    }

    @Test("saveAllEdits (File ▸ Save) persists a dirty websiteInspector title to disk (fix round 2, Important)")
    func saveAllEditsPersistsDirtyWebsiteInspectorTitle() async throws {
        let (root, packageURL, package) = try makeSitePackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel()
        model.site = SiteStore.Site(
            id: "site-a", name: "Test", packageURL: packageURL,
            isValid: true, missingSentinels: [], lastSeen: Date(), bookmarkData: nil
        )
        model.ensureWebsiteInspectorLoaded()
        let inspector = try #require(model.websiteInspector)
        await waitForWebsiteInspectorLoad(inspector)
        inspector.title = "Saved via File Save"
        #expect(model.hasUnsavedEdits)

        await model.saveAllEdits()

        #expect(!inspector.isDirty)
        #expect(!model.hasUnsavedEdits)

        let loaded = try PlistDocumentIO.load(package.infoPlistURL)
        guard let entry = loaded.entries.first(where: PlistEditorModel.isWebsiteTitleEntry),
              case .string(let value) = entry.value else {
            Issue.record("expected a website-title entry in Info.plist")
            return
        }
        #expect(value == "Saved via File Save")
    }

    @Test("confirmRevertToSaved (File ▸ Revert to Saved) restores a dirty websiteInspector from disk without writing (fix round 2, Important)")
    func confirmRevertToSavedRestoresDirtyWebsiteInspector() async throws {
        let (root, packageURL, package) = try makeSitePackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel()
        model.site = SiteStore.Site(
            id: "site-a", name: "Test", packageURL: packageURL,
            isValid: true, missingSentinels: [], lastSeen: Date(), bookmarkData: nil
        )
        model.ensureWebsiteInspectorLoaded()
        let inspector = try #require(model.websiteInspector)
        await waitForWebsiteInspectorLoad(inspector)
        let originalTitle = inspector.title
        let onDiskBefore = try PlistDocumentIO.load(package.infoPlistURL)

        inspector.title = "Discarded edit"
        #expect(model.hasUnsavedEdits)

        await model.confirmRevertToSaved()

        #expect(inspector.title == originalTitle)
        #expect(!inspector.isDirty)
        #expect(!model.hasUnsavedEdits)

        // Revert is a re-read, never a write — the file on disk must be byte-for-byte the same
        // document as before the discarded edit (the review's failure mode: the discarded edit
        // silently landing on disk on next focus loss).
        let onDiskAfter = try PlistDocumentIO.load(package.infoPlistURL)
        #expect(onDiskAfter.entries == onDiskBefore.entries)
    }

    /// The model half of File ▸ Save / Revert To ▸ Revert to Saved *enablement*, which the two
    /// command structs spell as `hasUnsavedEdits != true || editCommandInFlight == true`
    /// (`SaveCommands.swift`, `FileItemCommands.swift`). The sibling tests above cover what the
    /// commands *do* once invoked; this pins that they are reachable at all when the website
    /// inspector is the only dirty surface — including `requestRevertToSaved()`'s own guard, which
    /// re-checks the same pair and would silently swallow the click if they disagreed.
    ///
    /// A GUI smoke reported this menu item as permanently disabled for a dirty inspector Title.
    /// Re-running it live disproved that: the failing observation was made with no key window (in
    /// the same screenshot, File ▸ Close, Save, Rename…, and Reveal in Finder were all disabled
    /// too), so `@FocusedValue(\.siteWindowModel)` was nil and *every* window-scoped File item was
    /// off — nothing to do with dirtiness. Kept as a regression pin for the enablement inputs,
    /// which no test covered before.
    @Test("File ▸ Save / Revert to Saved are enabled and reachable for a website-inspector-only dirty field")
    func editCommandGateOpensForDirtyWebsiteInspector() async throws {
        let (root, packageURL, _) = try makeSitePackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel()
        model.site = SiteStore.Site(
            id: "site-a", name: "Test", packageURL: packageURL,
            isValid: true, missingSentinels: [], lastSeen: Date(), bookmarkData: nil
        )
        model.ensureWebsiteInspectorLoaded()
        let inspector = try #require(model.websiteInspector)
        await waitForWebsiteInspectorLoad(inspector)

        // Clean: both items disabled, and the action is inert if a stale menu item fires anyway.
        #expect(!model.hasUnsavedEdits)
        model.requestRevertToSaved()
        #expect(!model.revertConfirmationPresented)

        // Dirty, with no main-pane editor and no selection inspector — the exact state the smoke
        // exercised: the website inspector alone must open the gate.
        inspector.title = "Dirty title, nothing else open"
        #expect(model.activeEditor == nil)
        #expect(model.inspectorContext == nil)
        #expect(model.hasUnsavedEdits)
        #expect(!model.editCommandInFlight)

        model.requestRevertToSaved()
        #expect(model.revertConfirmationPresented, "Revert to Saved must reach its confirmation")
    }

    /// One half of the ordering contract every caller of `ensureWebsiteInspectorLoaded()` depends
    /// on: the model is non-nil the instant the call returns, with no suspension point in
    /// between, so a caller can flip `activeInspector`/`inspectorShown` in the very next statement
    /// and have the panel build from a populated model.
    ///
    /// Scope note (fix round 4, Minor 4 — this comment used to overstate what the test proves):
    /// all it catches is the assignment moving back inside the fire-and-forget `Task`. That the
    /// call actually *happens*, and happens before the activation flips, is pinned elsewhere —
    /// `InspectorActivationPolicyTests` for the toggle path, and
    /// `handleSiteChangedRebuildsPresentedWebsiteInspector`/`...WhenSiteArrivesLater` below for
    /// the paths no toggle press covers.
    @Test("ensureWebsiteInspectorLoaded populates websiteInspector with no suspension point between call and return (fix round 3)")
    func ensureWebsiteInspectorLoadedIsSynchronous() throws {
        let (root, packageURL, _) = try makeSitePackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel()
        model.site = SiteStore.Site(
            id: "site-a", name: "Test", packageURL: packageURL,
            isValid: true, missingSentinels: [], lastSeen: Date(), bookmarkData: nil
        )

        #expect(model.websiteInspector == nil)
        model.ensureWebsiteInspectorLoaded()
        // No `await` above this line and none needed below it — the assertion holds the instant
        // the call returns, proving a caller can safely flip `activeInspector`/`inspectorShown`
        // (or read `model.websiteInspector` for any other reason) in the very next statement.
        #expect(model.websiteInspector != nil)
        #expect(model.websiteInspector?.packageURL == packageURL)
    }

    /// Fix round 4, Critical 2: swapping the site while the website inspector is presented used to
    /// tear the model down with nothing synchronously rebuilding it, leaving the panel presented
    /// over a nil model — permanently blank, and (if any staleness survived in the view binding)
    /// a route for an edit to land in the PREVIOUS site's `Info.plist`. The rebuild has to happen
    /// inside `handleSiteChanged()` itself, synchronously, because the panel's content is built
    /// from whatever the model holds at that moment.
    @Test("handleSiteChanged rebuilds a presented website inspector against the new site (fix round 4)")
    func handleSiteChangedRebuildsPresentedWebsiteInspector() throws {
        let (rootA, packageA, _) = try makeSitePackage(named: "A")
        let (rootB, packageB, _) = try makeSitePackage(named: "B")
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }
        let model = makeModel()
        model.site = SiteStore.Site(
            id: "site-a", name: "A", packageURL: packageA,
            isValid: true, missingSentinels: [], lastSeen: Date(), bookmarkData: nil
        )
        model.websiteInspectorPresented = true
        model.ensureWebsiteInspectorLoaded()
        let first = try #require(model.websiteInspector)

        // The swap the window model sees: `SiteWindow`'s `.onChange(of: model.site?.id)` fires
        // after `site` already holds the new value.
        model.site = SiteStore.Site(
            id: "site-b", name: "B", packageURL: packageB,
            isValid: true, missingSentinels: [], lastSeen: Date(), bookmarkData: nil
        )
        model.handleSiteChanged()

        let rebuilt = try #require(model.websiteInspector, "presented panel left with a nil model")
        #expect(rebuilt !== first)
        #expect(rebuilt.packageURL == packageB)
    }

    /// Fix round 4, Critical 1: the two activations that never involve a toggle press with a site
    /// already in hand — scene restoration onto a persisted `.website` activation, and ⌥⌘J pressed
    /// while the window still shows "Loading site…" (the menu item is enabled then). Both arrive
    /// here as "presented, but `site` only became non-nil now", and both used to leave the model
    /// nil forever: the panel's own `.task` was attached to a subtree that renders nothing while
    /// the model is nil, so it could never fire to create it.
    @Test("handleSiteChanged creates the website inspector when it was already presented before the site loaded (fix round 4)")
    func handleSiteChangedCreatesWebsiteInspectorWhenSiteArrivesLater() throws {
        let (root, packageURL, _) = try makeSitePackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel()

        // Presented before any site resolves — `SiteWindow` mirrors this from its `initial: true`
        // scene-state handlers, ahead of the load.
        model.websiteInspectorPresented = true
        model.ensureWebsiteInspectorLoaded()
        #expect(model.websiteInspector == nil, "nothing to build against with no site open")

        model.site = SiteStore.Site(
            id: "site-a", name: "Test", packageURL: packageURL,
            isValid: true, missingSentinels: [], lastSeen: Date(), bookmarkData: nil
        )
        model.handleSiteChanged()

        let inspector = try #require(model.websiteInspector, "presented panel left with a nil model")
        #expect(inspector.packageURL == packageURL)
    }

    /// The other side of the two tests above: a site change with the panel *not* presented must
    /// still tear the model down (and not eagerly rebuild one nothing is showing).
    @Test("handleSiteChanged leaves the website inspector nil when the panel is not presented (fix round 4)")
    func handleSiteChangedDoesNotRebuildHiddenWebsiteInspector() throws {
        let (root, packageURL, _) = try makeSitePackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel()
        model.site = SiteStore.Site(
            id: "site-a", name: "Test", packageURL: packageURL,
            isValid: true, missingSentinels: [], lastSeen: Date(), bookmarkData: nil
        )
        model.ensureWebsiteInspectorLoaded()
        #expect(model.websiteInspector != nil)

        #expect(!model.websiteInspectorPresented)
        model.handleSiteChanged()
        #expect(model.websiteInspector == nil)
    }

    /// Fix round 5, Critical: the #1126 settle in `clearInspectorThenSwitchPane` only buys a
    /// separate SwiftUI transaction for a dismissal that has actually *started*. The website
    /// inspector's presentation lives in `SiteWindow`'s scene storage, so nothing this model did
    /// began one — the pane swapped under a presented panel and AppKit aborted in
    /// `_postWindowNeedsUpdateConstraints`. This pins the ordering the fix restores: suspend,
    /// then settle, then swap — and (fix round 6) resume once the swap is done, so the panel the
    /// user opened comes back on its own.
    @Test("a main-pane switch suspends a presented website inspector, then restores it after the swap (fix round 6)")
    func paneSwitchSuspendsPresentedWebsiteInspectorThenRestoresIt() async {
        let model = makeModel()
        model.websiteInspectorPresented = true

        var edges: [Bool] = []
        var paneModeAtEdge: [MainPaneMode] = []
        model.setWebsiteInspectorSuspended = { [unowned model] suspended in
            edges.append(suspended)
            paneModeAtEdge.append(model.mainPaneMode)
            // What `SiteWindow.suspendWebsiteInspector(_:)` mirrors back synchronously.
            model.websiteInspectorPresented = !suspended
        }

        #expect(await model.showGraph())

        #expect(edges == [true, false], "the panel must be suspended and then put back")
        #expect(paneModeAtEdge.first == .preview, "suspension must precede the pane swap")
        #expect(paneModeAtEdge.last == .graph, "the restore must follow it")
        #expect(model.mainPaneMode == .graph)
        #expect(model.websiteInspectorPresented, "the user's panel must not be left withheld")
    }

    /// The complement: with the website panel hidden there is nothing to withhold, so the seam
    /// must stay untouched — including its restoring edge, which would otherwise clear a
    /// suspension this switch never armed.
    @Test("a main-pane switch leaves the website-inspector suspension seam alone when it isn't presented (fix round 5)")
    func paneSwitchSkipsSuspensionWhenWebsiteInspectorHidden() async {
        let model = makeModel()
        var edges: [Bool] = []
        model.setWebsiteInspectorSuspended = { edges.append($0) }

        #expect(await model.showGraph())

        #expect(edges.isEmpty)
        #expect(model.mainPaneMode == .graph)
    }

    /// Fix round 6, Important 3: suspending the panel unmounts its `Form`, and a `TextField`
    /// that never loses focus never commits — so a Title typed but not tabbed out of was silently
    /// dropped by the pane switch. The flush has to land *before* the suspension, which the
    /// `isDirty` reading taken inside the seam pins; the on-disk assertion (a second model loaded
    /// from the same package) proves the flush was a real write, not just a state reset.
    @Test("a main-pane switch flushes a dirty website inspector to disk before suspending it (fix round 6)")
    func paneSwitchFlushesDirtyWebsiteInspector() async throws {
        let (root, packageURL, _) = try makeSitePackage(named: "Flush")
        defer { try? FileManager.default.removeItem(at: root) }

        let model = makeModel()
        model.site = SiteStore.Site(
            id: "site-a", name: "Flush", packageURL: packageURL,
            isValid: true, missingSentinels: [], lastSeen: Date(), bookmarkData: nil
        )
        model.websiteInspectorPresented = true
        model.ensureWebsiteInspectorLoaded()
        let inspector = try #require(model.websiteInspector)
        // `ensureWebsiteInspectorLoaded()` is synchronous by design and kicks its load off in a
        // detached task; typing into the fields before that lands would just be overwritten.
        while inspector.title != "Flush" { await Task.yield() }

        // The unflushed edit: the field's binding is updated, its commit-on-blur never runs.
        inspector.title = "Flushed By Pane Switch"
        #expect(inspector.isDirty)

        var dirtyWhenSuspended: Bool?
        model.setWebsiteInspectorSuspended = { [unowned model] suspended in
            if suspended, dirtyWhenSuspended == nil { dirtyWhenSuspended = inspector.isDirty }
            model.websiteInspectorPresented = !suspended
        }

        #expect(await model.showGraph())

        #expect(dirtyWhenSuspended == false, "the flush must precede the panel's unmount")
        #expect(!inspector.isDirty)

        let reloaded = WebsiteInspectorModel(packageURL: packageURL)
        await reloaded.load()
        #expect(reloaded.title == "Flushed By Pane Switch", "the edit never reached Info.plist")
    }
}

/// `isTakeover`/`isSameKind` drive `SiteWindow`'s focus-restoration `.onChange` (#1748) — see its
/// doc comment. Covered in isolation here since that `.onChange` itself needs a live window/scene
/// to exercise.
@Suite("MainPaneMode")
struct MainPaneModeTests {
    private static let fileA = FileRef(url: URL(fileURLWithPath: "/tmp/a.astro"), group: .pages, name: "a.astro")
    private static let fileB = FileRef(url: URL(fileURLWithPath: "/tmp/b.astro"), group: .pages, name: "b.astro")

    @Test(".preview is not a takeover; every other case is")
    func isTakeover() {
        #expect(MainPaneMode.preview.isTakeover == false)
        for mode: MainPaneMode in [
            .editor(Self.fileA), .graph, .cleanup, .reader, .followers, .communities, .moderation, .contacts,
        ] {
            #expect(mode.isTakeover == true, "\(mode) should be a takeover")
        }
    }

    @Test("isSameKind ignores .editor's associated file")
    func isSameKindIgnoresEditorFile() {
        #expect(MainPaneMode.editor(Self.fileA).isSameKind(as: .editor(Self.fileB)) == true)
        #expect(MainPaneMode.editor(Self.fileA).isSameKind(as: .editor(Self.fileA)) == true)
    }

    @Test("isSameKind is false across different takeovers, and between a takeover and .preview")
    func isSameKindAcrossDifferentKinds() {
        #expect(MainPaneMode.graph.isSameKind(as: .cleanup) == false)
        #expect(MainPaneMode.graph.isSameKind(as: .preview) == false)
        #expect(MainPaneMode.preview.isSameKind(as: .editor(Self.fileA)) == false)
    }

    @Test("isSameKind is true for identical non-editor cases")
    func isSameKindIdenticalCases() {
        #expect(MainPaneMode.preview.isSameKind(as: .preview) == true)
        #expect(MainPaneMode.graph.isSameKind(as: .graph) == true)
    }
}

/// Wraps a pre-started fake `get_page_model` `MCPClient` (`makeFakeGetPageModelClient`,
/// `WYSIWYGPlumbingIntegrationTests.swift`) behind a `SiteRuntimeFactory`, so a `SiteWindowModel`
/// built with it can actually run `preview.enterEditMode(path:)` to completion in a test — unlike
/// `NeverStartedSiteRuntimeFactory` above, whose `MCPClient` is never started and would fail every
/// `get_page_model` fetch.
private struct FakeGetPageModelSiteRuntimeFactory: SiteRuntimeFactory {
    let mcpClient: MCPClient

    func makeRuntime(
        contentGraph: SiteContentGraph?,
        knowledgeIndex: SiteKnowledgeIndex?,
        semanticRanker: SemanticRanker?,
        conventionsEngine: ProjectConventionsEngine?
    ) -> any SiteRuntime {
        UnavailableSiteRuntime(reason: "test: WYSIWYG edit mode via fake get_page_model", mcpClient: mcpClient)
    }
}
