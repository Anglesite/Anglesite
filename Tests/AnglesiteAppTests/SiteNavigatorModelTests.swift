import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteAppCore

/// Flattens the tree so tests can find a node by title regardless of nesting depth.
private func flatten(_ nodes: [URLTreeNode]) -> [URLTreeNode] {
    nodes.flatMap { [$0] + flatten($0.children ?? []) }
}

@Suite("SiteNavigatorModel")
@MainActor
struct SiteNavigatorModelTests {
    @Test("canDelete and canDuplicate are true for a route (page/post) target")
    func canDeleteAndDuplicateRouteTarget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let graph = SiteContentGraph()
        await graph.load(
            siteID: "site-1",
            pages: [SiteContentGraph.Page(
                id: "site-1:page:/about", siteID: "site-1", route: "/about",
                filePath: "src/pages/about.astro", title: "About", lastModified: Date())],
            posts: [], images: []
        )
        let model = SiteNavigatorModel(graph: graph)
        model.start(site: CurrentSite(id: "site-1", packageURL: root, sourceDirectory: root))
        while model.nodes.isEmpty { await Task.yield() }

        let id = try #require(flatten(model.nodes).first { $0.title == "About" }?.id)

        #expect(model.canDelete(id) == true)
        #expect(model.canDuplicate(id) == true)
    }

    /// Components/styles no longer appear in the tree at all (#714 slice 1 — they move to the
    /// Website Settings surface in a later slice), so the non-content-row case this used to cover
    /// with a component file is now exercised via a directory row, the only remaining non-route
    /// (`.directory`) target once the pinned website row was also removed (#714 v2 slice 1).
    @Test("canDelete and canDuplicate are false for a directory row")
    func canDeleteAndDuplicateDirectoryRowIsFalse() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let graph = SiteContentGraph()
        await graph.load(
            siteID: "site-1",
            pages: [],
            posts: [SiteContentGraph.Post(
                id: "site-1:post:hello", siteID: "site-1", collection: "notes", slug: "hello",
                title: "Hello", draft: false, publishDate: Date(), tags: [],
                filePath: "src/content/notes/hello.md", lastModified: Date())],
            images: []
        )
        let model = SiteNavigatorModel(graph: graph)
        model.start(site: CurrentSite(id: "site-1", packageURL: root, sourceDirectory: root))
        while model.nodes.isEmpty { await Task.yield() }

        let id = try #require(model.nodes.first { if case .directory = $0.kind { return true }; return false }?.id)

        #expect(model.canDelete(id) == false)
        #expect(model.canDuplicate(id) == false)
    }

    @Test("canDelete and canDuplicate are false for an unknown id")
    func canDeleteAndDuplicateUnknownIDIsFalse() {
        let model = SiteNavigatorModel(graph: SiteContentGraph())
        #expect(model.canDelete("nonexistent") == false)
        #expect(model.canDuplicate("nonexistent") == false)
    }

    /// #1714: the home row (`URLTreeNode.Kind.home`, `src/pages/index.astro`) is a page for
    /// Rename and Duplicate — both leave the site's front door in place — but never for Delete:
    /// removing `/` leaves the site with no home page, and `create_page` refuses to scaffold the
    /// root, so ⌘Z would be the only way back. Gating on the row's *kind* (not its `.route`
    /// target, which home shares with every other page) is what keeps the context menu, Edit ▸
    /// Duplicate, and Edit ▸ Delete reading the same answer for the same row.
    @Test("home row: renamable and duplicable, never deletable")
    func homeRowIsNotDeletable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let graph = SiteContentGraph()
        await graph.load(
            siteID: "site-1",
            pages: [
                SiteContentGraph.Page(
                    id: "site-1:page:/", siteID: "site-1", route: "/",
                    filePath: "src/pages/index.astro", title: "Welcome", lastModified: Date()),
                SiteContentGraph.Page(
                    id: "site-1:page:/about", siteID: "site-1", route: "/about",
                    filePath: "src/pages/about.astro", title: "About", lastModified: Date()),
            ],
            posts: [], images: []
        )
        let model = SiteNavigatorModel(graph: graph)
        model.start(site: CurrentSite(id: "site-1", packageURL: root, sourceDirectory: root))
        while model.nodes.isEmpty { await Task.yield() }
        let home = try #require(model.nodes.first { $0.kind == .home })

        #expect(model.canRename(home.id) == true)
        #expect(model.canDuplicate(home.id) == true)
        #expect(model.canDelete(home.id) == false)

        model.selection = home.id
        #expect(model.deletableSelection() == nil)
        model.stop()
    }

    /// The other half of the #1714 kind-based rule: a collection entry (post) row is an ordinary
    /// page for every verb, same as a `src/pages/` page — the `.home` carve-out is home-only.
    @Test("post row: renamable, duplicable, and deletable")
    func postRowSupportsAllVerbs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let graph = SiteContentGraph()
        await graph.load(
            siteID: "site-1",
            pages: [],
            posts: [SiteContentGraph.Post(
                id: "site-1:post:hello", siteID: "site-1", collection: "notes", slug: "hello",
                title: "Hello", draft: false, publishDate: Date(), tags: [],
                filePath: "src/content/notes/hello.md", lastModified: Date())],
            images: []
        )
        let model = SiteNavigatorModel(graph: graph)
        model.start(site: CurrentSite(id: "site-1", packageURL: root, sourceDirectory: root))
        while model.nodes.isEmpty { await Task.yield() }
        let post = try #require(flatten(model.nodes).first { $0.title == "Hello" })

        #expect(model.canRename(post.id) == true)
        #expect(model.canDuplicate(post.id) == true)
        #expect(model.canDelete(post.id) == true)

        model.selection = post.id
        #expect(model.deletableSelection()?.id == post.id)
        model.stop()
    }

    /// Folder rows (#1714): no verb at all — not just Delete/Duplicate, Rename too.
    @Test("directory row: no rename, duplicate, or delete")
    func directoryRowSupportsNoVerbs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let graph = SiteContentGraph()
        await graph.load(
            siteID: "site-1",
            pages: [],
            posts: [SiteContentGraph.Post(
                id: "site-1:post:hello", siteID: "site-1", collection: "notes", slug: "hello",
                title: "Hello", draft: false, publishDate: Date(), tags: [],
                filePath: "src/content/notes/hello.md", lastModified: Date())],
            images: []
        )
        let model = SiteNavigatorModel(graph: graph)
        model.start(site: CurrentSite(id: "site-1", packageURL: root, sourceDirectory: root))
        while model.nodes.isEmpty { await Task.yield() }
        let dir = try #require(model.nodes.first { if case .directory = $0.kind { return true }; return false })

        #expect(model.canRename(dir.id) == false)
        #expect(model.canDuplicate(dir.id) == false)
        #expect(model.canDelete(dir.id) == false)
        model.stop()
    }

    /// #674: the bare Delete key on the navigator list should act on whatever
    /// `deletableSelection()` returns — nil disables it, non-nil is the item to delete.
    @Test("deletableSelection returns the selected content row")
    func deletableSelectionReturnsSelectedContentRow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let graph = SiteContentGraph()
        await graph.load(
            siteID: "site-1",
            pages: [SiteContentGraph.Page(
                id: "site-1:page:/about", siteID: "site-1", route: "/about",
                filePath: "src/pages/about.astro", title: "About", lastModified: Date())],
            posts: [], images: []
        )
        let model = SiteNavigatorModel(graph: graph)
        model.start(site: CurrentSite(id: "site-1", packageURL: root, sourceDirectory: root))
        while model.nodes.isEmpty { await Task.yield() }
        let id = try #require(flatten(model.nodes).first { $0.title == "About" }?.id)

        model.selection = id

        #expect(model.deletableSelection()?.id == id)
    }

    @Test("deletableSelection is nil with no selection")
    func deletableSelectionNilWithNoSelection() {
        let model = SiteNavigatorModel(graph: SiteContentGraph())
        #expect(model.deletableSelection() == nil)
    }

    @Test("deletableSelection is nil while inline-renaming the selection")
    func deletableSelectionNilWhileEditing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let graph = SiteContentGraph()
        await graph.load(
            siteID: "site-1",
            pages: [SiteContentGraph.Page(
                id: "site-1:page:/about", siteID: "site-1", route: "/about",
                filePath: "src/pages/about.astro", title: "About", lastModified: Date())],
            posts: [], images: []
        )
        let model = SiteNavigatorModel(graph: graph)
        model.start(site: CurrentSite(id: "site-1", packageURL: root, sourceDirectory: root))
        while model.nodes.isEmpty { await Task.yield() }
        let id = try #require(flatten(model.nodes).first { $0.title == "About" }?.id)
        model.selection = id

        model.beginEditing(id)

        #expect(model.deletableSelection() == nil)
    }

    @Test("deletableSelection is nil for the non-deletable directory row")
    func deletableSelectionNilForDirectoryRow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let graph = SiteContentGraph()
        await graph.load(
            siteID: "site-1",
            pages: [],
            posts: [SiteContentGraph.Post(
                id: "site-1:post:hello", siteID: "site-1", collection: "notes", slug: "hello",
                title: "Hello", draft: false, publishDate: Date(), tags: [],
                filePath: "src/content/notes/hello.md", lastModified: Date())],
            images: []
        )
        let model = SiteNavigatorModel(graph: graph)
        model.start(site: CurrentSite(id: "site-1", packageURL: root, sourceDirectory: root))
        while model.nodes.isEmpty { await Task.yield() }
        let id = try #require(model.nodes.first { if case .directory = $0.kind { return true }; return false }?.id)
        model.selection = id

        #expect(model.deletableSelection() == nil)
    }

    // MARK: renameableSelection (#1732)

    @Test("renameableSelection returns the selected page row")
    func renameableSelectionReturnsPageRow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let graph = SiteContentGraph()
        await graph.load(
            siteID: "site-1",
            pages: [SiteContentGraph.Page(
                id: "site-1:page:/about", siteID: "site-1", route: "/about",
                filePath: "src/pages/about.astro", title: "About", lastModified: Date())],
            posts: [], images: []
        )
        let model = SiteNavigatorModel(graph: graph)
        model.start(site: CurrentSite(id: "site-1", packageURL: root, sourceDirectory: root))
        while model.nodes.isEmpty { await Task.yield() }
        let id = try #require(flatten(model.nodes).first { $0.title == "About" }?.id)
        model.selection = id

        #expect(model.renameableSelection() == id)
    }

    @Test("renameableSelection is nil with no selection")
    func renameableSelectionNilWithoutSelection() {
        let model = SiteNavigatorModel(graph: SiteContentGraph())
        #expect(model.renameableSelection() == nil)
    }

    /// Return while already inline-renaming must reach the focused TextField (commit), not
    /// restart the rename — the same guard `deletableSelection()` applies for Delete.
    @Test("renameableSelection is nil while inline-renaming the selection")
    func renameableSelectionNilWhileEditing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let graph = SiteContentGraph()
        await graph.load(
            siteID: "site-1",
            pages: [SiteContentGraph.Page(
                id: "site-1:page:/about", siteID: "site-1", route: "/about",
                filePath: "src/pages/about.astro", title: "About", lastModified: Date())],
            posts: [], images: []
        )
        let model = SiteNavigatorModel(graph: graph)
        model.start(site: CurrentSite(id: "site-1", packageURL: root, sourceDirectory: root))
        while model.nodes.isEmpty { await Task.yield() }
        let id = try #require(flatten(model.nodes).first { $0.title == "About" }?.id)
        model.selection = id

        model.beginEditing(id)

        #expect(model.renameableSelection() == nil)
    }

    @Test("renameableSelection is nil for the non-renameable directory row")
    func renameableSelectionNilForDirectoryRow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let graph = SiteContentGraph()
        await graph.load(
            siteID: "site-1",
            pages: [],
            posts: [SiteContentGraph.Post(
                id: "site-1:post:hello", siteID: "site-1", collection: "notes", slug: "hello",
                title: "Hello", draft: false, publishDate: Date(), tags: [],
                filePath: "src/content/notes/hello.md", lastModified: Date())],
            images: []
        )
        let model = SiteNavigatorModel(graph: graph)
        model.start(site: CurrentSite(id: "site-1", packageURL: root, sourceDirectory: root))
        while model.nodes.isEmpty { await Task.yield() }
        let id = try #require(model.nodes.first { if case .directory = $0.kind { return true }; return false }?.id)
        model.selection = id

        #expect(model.renameableSelection() == nil)
    }

    @Test("fileURL(for:) resolves a route (page) target to its sourceDirectory-relative file")
    func fileURLResolvesRouteTarget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let graph = SiteContentGraph()
        await graph.load(
            siteID: "site-1",
            pages: [SiteContentGraph.Page(
                id: "site-1:page:/about", siteID: "site-1", route: "/about",
                filePath: "src/pages/about.astro", title: "About", lastModified: Date())],
            posts: [], images: []
        )
        let model = SiteNavigatorModel(graph: graph)
        model.start(site: CurrentSite(id: "site-1", packageURL: root, sourceDirectory: root))
        while model.nodes.isEmpty { await Task.yield() }
        let id = try #require(flatten(model.nodes).first { $0.title == "About" }?.id)

        #expect(model.fileURL(for: id) == root.appendingPathComponent("src/pages/about.astro"))
    }

    @Test("fileURL(for:) resolves a route (post) target to its sourceDirectory-relative file")
    func fileURLResolvesPostRouteTarget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let graph = SiteContentGraph()
        await graph.load(
            siteID: "site-1",
            pages: [],
            posts: [SiteContentGraph.Post(
                id: "site-1:post:hello", siteID: "site-1", collection: "blog", slug: "hello",
                title: "Hello", draft: false, publishDate: Date(), tags: [],
                filePath: "src/content/blog/hello.md", lastModified: Date())],
            images: []
        )
        let model = SiteNavigatorModel(graph: graph)
        model.start(site: CurrentSite(id: "site-1", packageURL: root, sourceDirectory: root))
        while model.nodes.isEmpty { await Task.yield() }
        let id = try #require(flatten(model.nodes).first { $0.title == "Hello" }?.id)

        #expect(model.fileURL(for: id) == root.appendingPathComponent("src/content/blog/hello.md"))
    }

    @Test("fileURL(for:) is nil for a directory row")
    func fileURLNilForDirectoryRow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let graph = SiteContentGraph()
        await graph.load(
            siteID: "site-1",
            pages: [],
            posts: [SiteContentGraph.Post(
                id: "site-1:post:hello", siteID: "site-1", collection: "notes", slug: "hello",
                title: "Hello", draft: false, publishDate: Date(), tags: [],
                filePath: "src/content/notes/hello.md", lastModified: Date())],
            images: []
        )
        let model = SiteNavigatorModel(graph: graph)
        model.start(site: CurrentSite(id: "site-1", packageURL: root, sourceDirectory: root))
        while model.nodes.isEmpty { await Task.yield() }
        let id = try #require(model.nodes.first { if case .directory = $0.kind { return true }; return false }?.id)

        #expect(model.fileURL(for: id) == nil)
    }

    @Test("fileURL(for:) is nil for an unknown id")
    func fileURLNilForUnknownID() {
        let model = SiteNavigatorModel(graph: SiteContentGraph())
        #expect(model.fileURL(for: "nonexistent") == nil)
    }

    @Test("requestFocus bumps focusRequestToken, once per call, so SiteNavigatorView's onChange fires (#1748)")
    func requestFocusBumpsToken() {
        let model = SiteNavigatorModel(graph: SiteContentGraph())
        let initial = model.focusRequestToken
        model.requestFocus()
        #expect(model.focusRequestToken == initial + 1)
        model.requestFocus()
        #expect(model.focusRequestToken == initial + 2, "a second dismissal in a row must still register as a change")
    }
}

/// `saveRedirect` writes through `RedirectsStore` to `Source/redirects.json` (#530) — the
/// model-level append used by the "Add Redirect?" prompt `SiteWindow` shows after
/// `SiteWindowModel.confirmDelete()` deletes a page. Deletion itself is #516's (tested above via
/// `canDelete`/`canDuplicate`, and in `SiteWindowModelTests`); this suite only covers the
/// redirect-save path this model still owns.
@Suite("SiteNavigatorModel saveRedirect (#530)")
@MainActor
struct SiteNavigatorModelRedirectsTests {
    private func tempSourceDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SiteNavigatorModelRedirectsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeModel(
        sourceDirectory: URL,
        gitCommit: @escaping NativeContentOperations.GitCommit = NativeContentOperations.processGitCommit
    ) -> SiteNavigatorModel {
        let graph = SiteContentGraph()
        let model = SiteNavigatorModel(graph: graph, gitCommit: gitCommit)
        model.start(
            site: CurrentSite(id: "site1", packageURL: sourceDirectory, sourceDirectory: sourceDirectory))
        return model
    }

    @Test("saveRedirect on success writes the entry to redirects.json")
    func saveRedirectSuccess() async throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(sourceDirectory: dir)

        let saved = await model.saveRedirect(source: "/old", destination: "/new", code: .permanent)
        #expect(saved == true)

        let loaded = try RedirectsStore(sourceDirectory: dir).load()
        #expect(loaded == [RedirectsStore.RedirectEntry(source: "/old", destination: "/new", code: .permanent)])
    }

    @Test("saveRedirect on validation failure (self-cycle) returns false and sets redirectSaveError")
    func saveRedirectFailure() async throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(sourceDirectory: dir)

        let saved = await model.saveRedirect(source: "/a", destination: "/a", code: .permanent)
        #expect(saved == false)
        #expect(model.redirectSaveError != nil)
    }

    /// A saved redirect must land in git the same way the delete that prompted it did, rather than
    /// sitting as a silent uncommitted `redirects.json` change (#1861).
    @Test("saveRedirect on success commits redirects.json to git")
    func saveRedirectCommitsToGit() async throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spy = SiteNavigatorRedirectCommitSpy()
        let model = makeModel(sourceDirectory: dir, gitCommit: { _, rel, msg in spy.record(rel, msg); return "deadbeef" })

        let saved = await model.saveRedirect(source: "/old", destination: "/new", code: .permanent)
        #expect(saved == true)
        #expect(spy.paths() == ["redirects.json"])
        #expect(spy.messages() == ["anglesite: add redirect /old → /new"])
    }

    /// A validation failure must never reach the git seam — nothing was written to disk to commit.
    @Test("saveRedirect on validation failure does not commit")
    func saveRedirectFailureSkipsCommit() async throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spy = SiteNavigatorRedirectCommitSpy()
        let model = makeModel(sourceDirectory: dir, gitCommit: { _, rel, msg in spy.record(rel, msg); return "deadbeef" })

        _ = await model.saveRedirect(source: "/a", destination: "/a", code: .permanent)
        #expect(spy.paths().isEmpty)
    }
}

/// Records the `(relPath, message)` pairs a model hands its injected `gitCommit`, matching the
/// spy-closure pattern `PageMetadataModelRobotsSettingsTests` uses for this seam.
final class SiteNavigatorRedirectCommitSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(String, String)] = []
    func record(_ rel: String, _ message: String) { lock.lock(); calls.append((rel, message)); lock.unlock() }
    func paths() -> [String] { lock.lock(); defer { lock.unlock() }; return calls.map(\.0) }
    func messages() -> [String] { lock.lock(); defer { lock.unlock() }; return calls.map(\.1) }
}

@Suite("SiteNavigatorModel publish/unpublish gating (#798)")
@MainActor
struct SiteNavigatorModelPublishGatingTests {
    @Test("canPublish/canUnpublish are mutually exclusive for a typed post, false for pages and blog posts")
    func publishGating() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let graph = SiteContentGraph()
        // No `generation:` — nil (the default) applies unconditionally, matching every other
        // test-caller of `load` in this codebase; a non-nil value is guarded against a
        // `beginScan` token this test never claims and would silently discard the load.
        await graph.load(
            siteID: "site-1",
            pages: [],
            posts: [
                SiteContentGraph.Post(
                    id: "site-1:post:draft-note", siteID: "site-1", collection: "notes", slug: "draft-note",
                    title: "Draft note", draft: true, publishDate: nil, tags: [],
                    filePath: "src/content/notes/draft-note.md", lastModified: Date()),
                SiteContentGraph.Post(
                    id: "site-1:post:live-note", siteID: "site-1", collection: "notes", slug: "live-note",
                    title: "Live note", draft: false, publishDate: Date(), tags: [],
                    filePath: "src/content/notes/live-note.md", lastModified: Date()),
                SiteContentGraph.Post(
                    id: "site-1:post:blog-post", siteID: "site-1", collection: "blog", slug: "blog-post",
                    title: "Blog post", draft: true, publishDate: nil, tags: [],
                    filePath: "src/content/blog/blog-post.md", lastModified: Date()),
                SiteContentGraph.Post(
                    id: "site-1:post:event-post", siteID: "site-1", collection: "events", slug: "event-post",
                    title: "Event post", draft: false, publishDate: Date(), tags: [],
                    filePath: "src/content/events/event-post.md", lastModified: Date()),
            ],
            images: []
        )

        let model = SiteNavigatorModel(graph: graph)
        model.start(site: CurrentSite(id: "site-1", packageURL: root, sourceDirectory: root))
        while model.nodes.isEmpty { await Task.yield() }

        #expect(model.canPublish("site-1:post:draft-note") == true)
        #expect(model.canUnpublish("site-1:post:draft-note") == false)
        #expect(model.canPublish("site-1:post:live-note") == false)
        #expect(model.canUnpublish("site-1:post:live-note") == true)
        #expect(model.canPublish("site-1:post:blog-post") == false)
        #expect(model.canUnpublish("site-1:post:blog-post") == false)
        // Business types (event/review/announcement/member) are registry-backed but draftless —
        // explicitly out of #798's scope — so both verbs must stay unavailable (the regression
        // this test guards: descriptor-presence alone used to gate `canUnpublish`, which wrongly
        // returned true here since `post.draft` can never be true without a `draft` field).
        #expect(model.canPublish("site-1:post:event-post") == false)
        #expect(model.canUnpublish("site-1:post:event-post") == false)
        model.stop()
    }
}
