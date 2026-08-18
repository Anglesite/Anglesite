import Testing
import Foundation
@testable import AnglesiteIntents
@testable import AnglesiteCore

/// Covers `AddEffectIntent`: the pure `defaultInsertion` placement math (Step 2 of the task
/// brief), the pure `EffectDialogs` strings, and `run()`'s plan → confirm → apply flow driven
/// through `performForTesting()` with `EffectCatalogOverride` (mirrors `ThemeCatalogOverride`)
/// and `AddEffectSiteConnectionOverride` standing in for the `@Dependency`-resolved catalog and
/// the site's `PageModelClient`/`EditRouter` registries, respectively.
@Suite struct EffectIntentsTests {
    // MARK: - Fixtures

    /// Local duplicate of `PlacementMatcherTests.fixtureModel()` (Task 7,
    /// `Tests/AnglesiteCoreTests/PlacementMatcherTests.swift`) — test targets don't depend on
    /// each other, so this is intentionally re-declared here rather than imported.
    /// `<body>` with three element children: HEADER, SECTION (class "hero"), FOOTER.
    static func fixtureModelWithBody() -> PageModel {
        func node(_ id: String, kind: PageModel.Node.Kind, tag: String?, attrs: [PageModel.Attr] = [], children: [PageModel.Node] = []) -> PageModel.Node {
            PageModel.Node(id: id, kind: kind, tag: tag, attrs: attrs, span: .init(start: nil, end: nil), loc: nil, text: nil, children: children, block: nil)
        }
        let body = node("n1", kind: .element, tag: "BODY", attrs: [.init(name: "id", value: "body")], children: [
            node("n2", kind: .element, tag: "HEADER"),
            node("n3", kind: .element, tag: "SECTION", attrs: [.init(name: "class", value: "hero")]),
            node("n4", kind: .element, tag: "FOOTER"),
        ])
        let root = node("n0", kind: .fragment, tag: nil, children: [body])
        return PageModel(version: "v1", path: "src/pages/index.astro", tree: root)
    }

    /// A tree with no `<body>` anywhere, to exercise `defaultInsertion`'s tree-root fallback.
    static func fixtureModelWithoutBody() -> PageModel {
        func node(_ id: String, kind: PageModel.Node.Kind, tag: String?, children: [PageModel.Node] = []) -> PageModel.Node {
            PageModel.Node(id: id, kind: kind, tag: tag, attrs: [], span: .init(start: nil, end: nil), loc: nil, text: nil, children: children, block: nil)
        }
        let root = node("n0", kind: .fragment, tag: nil, children: [node("n1", kind: .element, tag: "MAIN")])
        return PageModel(version: "v1", path: "src/pages/index.astro", tree: root)
    }

    /// A `PageModelClient` whose `fetch(path:)` always succeeds with `model`.
    static func fakePageModelClient(returning model: PageModel) -> PageModelClient {
        PageModelClient(toolCaller: { name, _ in
            #expect(name == "get_page_model")
            let data = try JSONEncoder().encode(model)
            return MCPClient.ToolCallResult(content: [.init(type: "text", text: String(data: data, encoding: .utf8)!)], isError: false)
        })
    }

    /// A fixed-outcome `EditRouter`, echoing the originating message's id.
    actor StubRouter: EditRouter {
        let status: EditReply.Status
        let message: String?
        init(status: EditReply.Status, message: String? = nil) {
            self.status = status
            self.message = message
        }
        func apply(_ message: EditMessage) async -> EditReply {
            EditReply(id: message.id, status: status, message: self.message)
        }
    }

    static func particleFieldEntry(kind: EffectCatalogEntry.Placement.Kind = .background, allowedParents: [String]? = nil) -> EffectCatalogEntry {
        EffectCatalogEntry(
            component: "ParticleField", title: "Particle Field", ownerDescription: "d",
            category: .canvasBackground, keyProps: [:], snippet: "s",
            placement: .init(kind: kind, allowedParents: allowedParents))
    }

    /// Binds both `AddEffectIntent` overrides (catalog + site connection) around
    /// `intent.performForTesting()`, since `run()` needs both bound to skip
    /// `requestConfirmation` and to resolve without a live registry/template. Nesting the two
    /// separate `@TaskLocal`s here keeps individual tests focused on what varies.
    static func runForTesting(
        _ intent: AddEffectIntent, catalog: EffectCatalog,
        pageModelClient: PageModelClient?, editRouter: EditRouter?
    ) async throws -> String {
        try await EffectCatalogOverride.$scoped.withValue(catalog) {
            try await AddEffectSiteConnectionOverride.$scoped.withValue(
                AddEffectSiteConnection(pageModelClient: pageModelClient, editRouter: editRouter)
            ) {
                try await intent.performForTesting()
            }
        }
    }

    // MARK: - defaultInsertion (Step 2 of the task brief)

    @Test func backgroundPlacementDefaultsToEndOfBody() {
        let entry = Self.particleFieldEntry(kind: .background)
        let model = Self.fixtureModelWithBody()
        let insertion = AddEffectIntent.defaultInsertion(for: entry, in: model)
        #expect(insertion?.parentId == model.tree.children.first?.id)
        #expect(insertion?.index == model.tree.children.first?.children.count) // end of <body>'s 3 children
    }

    @Test func backgroundPlacementFallsBackToTreeRootWhenNoBodyExists() {
        let entry = Self.particleFieldEntry(kind: .background)
        let model = Self.fixtureModelWithoutBody()
        let insertion = AddEffectIntent.defaultInsertion(for: entry, in: model)
        #expect(insertion?.parentId == model.tree.id)
        #expect(insertion?.index == model.tree.children.count)
    }

    @Test func inlinePlacementWithAllowedParentsDefaultsToFirstChildOfMatch() {
        let entry = Self.particleFieldEntry(kind: .inline, allowedParents: ["FOOTER"])
        let model = Self.fixtureModelWithBody()
        let insertion = AddEffectIntent.defaultInsertion(for: entry, in: model)
        let footerID = model.tree.children.first?.children.last?.id
        #expect(insertion?.parentId == footerID)
        #expect(insertion?.index == 0)
    }

    @Test func inlinePlacementWithUnmatchedAllowedParentsFallsBackToFragmentRoot() {
        let entry = Self.particleFieldEntry(kind: .inline, allowedParents: ["MAIN"]) // no MAIN in the fixture
        let model = Self.fixtureModelWithBody()
        let insertion = AddEffectIntent.defaultInsertion(for: entry, in: model)
        #expect(insertion?.parentId == model.tree.id)
        #expect(insertion?.index == model.tree.children.count)
    }

    @Test func inlinePlacementWithNoAllowedParentsDefaultsToFragmentRoot() {
        let entry = Self.particleFieldEntry(kind: .inline, allowedParents: nil)
        let model = Self.fixtureModelWithBody()
        let insertion = AddEffectIntent.defaultInsertion(for: entry, in: model)
        #expect(insertion?.parentId == model.tree.id)
        #expect(insertion?.index == model.tree.children.count)
    }

    // MARK: - EffectDialogs (pure)

    @Test func dialogsCoverSuccessAndFailure() {
        #expect(EffectDialogs.applied(effectTitle: "Particle Field", siteName: "Acme").contains("Acme"))
        #expect(EffectDialogs.applied(effectTitle: "Particle Field", siteName: "Acme").contains("Particle Field"))
        #expect(EffectDialogs.failed(effectTitle: "Particle Field", siteName: "Acme", reason: "nope").contains("nope"))
        #expect(EffectDialogs.siteNotOpen(siteName: "Acme").contains("Acme"))
        #expect(EffectDialogs.notPlaceable(effectTitle: "Fade-in text").contains("Fade-in text"))
        #expect(EffectDialogs.unknownEffect(title: "Nope").contains("Nope"))
    }

    // MARK: - run() via performForTesting()

    @Test func appliesTheEffectAndReportsSuccess() async throws {
        let intent = AddEffectIntent()
        intent.site = SiteEntity(id: "s1", name: "Acme", creationDate: nil, modificationDate: nil)
        intent.effect = .particleField
        let dialog = try await Self.runForTesting(
            intent, catalog: EffectCatalog(entries: [Self.particleFieldEntry()]),
            pageModelClient: Self.fakePageModelClient(returning: Self.fixtureModelWithBody()),
            editRouter: StubRouter(status: .applied))
        #expect(dialog == "Added Particle Field to Acme.")
    }

    @Test func reportsFailureWhenTheRouterRefuses() async throws {
        let intent = AddEffectIntent()
        intent.site = SiteEntity(id: "s1", name: "Acme", creationDate: nil, modificationDate: nil)
        intent.effect = .particleField
        let dialog = try await Self.runForTesting(
            intent, catalog: EffectCatalog(entries: [Self.particleFieldEntry()]),
            pageModelClient: Self.fakePageModelClient(returning: Self.fixtureModelWithBody()),
            editRouter: StubRouter(status: .failed, message: "stale version"))
        #expect(dialog.contains("stale version"))
        #expect(dialog.contains("Acme"))
    }

    @Test func repromptsWithoutConfirmingWhenTheSiteIsntOpen() async throws {
        let intent = AddEffectIntent()
        intent.site = SiteEntity(id: "s1", name: "Acme", creationDate: nil, modificationDate: nil)
        intent.effect = .particleField
        let dialog = try await Self.runForTesting(
            intent, catalog: EffectCatalog(entries: [Self.particleFieldEntry()]),
            pageModelClient: nil, editRouter: nil)
        #expect(dialog == "Open Acme in Anglesite first, then try adding this effect again.")
    }

    @Test func repromptsWhenTheMatchedEntryHasNoPlacement() async throws {
        let intent = AddEffectIntent()
        intent.site = SiteEntity(id: "s1", name: "Acme", creationDate: nil, modificationDate: nil)
        intent.effect = .particleField
        let legacyEntry = EffectCatalogEntry(
            component: "ParticleField", title: "Particle Field", ownerDescription: "d",
            category: .canvasBackground, keyProps: [:], snippet: "s", placement: nil)
        let dialog = try await Self.runForTesting(
            intent, catalog: EffectCatalog(entries: [legacyEntry]),
            pageModelClient: Self.fakePageModelClient(returning: Self.fixtureModelWithBody()),
            editRouter: StubRouter(status: .applied))
        #expect(dialog.contains("Particle Field"))
        #expect(dialog.contains("Effects gallery"))
    }

    @Test func repromptsWhenTheEffectIsntInTheCatalog() async throws {
        let intent = AddEffectIntent()
        intent.site = SiteEntity(id: "s1", name: "Acme", creationDate: nil, modificationDate: nil)
        intent.effect = .dotGridPulse
        let dialog = try await Self.runForTesting(
            intent, catalog: EffectCatalog(entries: [Self.particleFieldEntry()]), // no "Dot Grid Pulse" entry
            pageModelClient: Self.fakePageModelClient(returning: Self.fixtureModelWithBody()),
            editRouter: StubRouter(status: .applied))
        #expect(dialog.contains("Dot Grid Pulse"))
    }

    /// The one thing every other `run()` test took for granted: the path this front door actually
    /// hands the sidecar. `get_page_model`'s `validPagePath` and `insertBlock`'s own path check
    /// both reject a route, so a hardcoded `"/"` here failed 100% of real invocations with
    /// `invalid-input: not a project-relative .astro path: /` (#768 final review, Finding 1).
    @Test func fetchesAndEditsTheHomePageSourcePathNotARoute() async throws {
        let recorder = PathRecorder()
        let model = Self.fixtureModelWithBody()
        let client = PageModelClient(toolCaller: { name, arguments in
            #expect(name == "get_page_model")
            if case .object(let object) = arguments, case .string(let path)? = object["path"] {
                await recorder.recordFetch(path)
            }
            let data = try JSONEncoder().encode(model)
            return MCPClient.ToolCallResult(content: [.init(type: "text", text: String(data: data, encoding: .utf8)!)], isError: false)
        })
        let router = RecordingRouter()

        let intent = AddEffectIntent()
        intent.site = SiteEntity(id: "s1", name: "Acme", creationDate: nil, modificationDate: nil)
        intent.effect = .particleField
        _ = try await Self.runForTesting(
            intent, catalog: EffectCatalog(entries: [Self.particleFieldEntry()]),
            pageModelClient: client, editRouter: router)

        let fetched = await recorder.fetchedPath
        #expect(fetched == "src/pages/index.astro")
        #expect(PageSourcePath.isValidPageSourcePath(fetched ?? "/"))

        let editedPath = await router.lastComponentPath
        #expect(editedPath == "src/pages/index.astro")
        #expect(PageSourcePath.isValidPageSourcePath(editedPath ?? "/"))
    }

    /// Records the `path` argument `AddEffectIntent` sends to `get_page_model`.
    actor PathRecorder {
        private(set) var fetchedPath: String?
        func recordFetch(_ path: String) { fetchedPath = path }
    }

    /// Applies successfully while capturing the `component.path` of the `insertBlock` edit.
    actor RecordingRouter: EditRouter {
        private(set) var lastComponentPath: String?
        func apply(_ message: EditMessage) async -> EditReply {
            if case .object(let component)? = message.component, case .string(let path)? = component["path"] {
                lastComponentPath = path
            }
            return EditReply(id: message.id, status: .applied, message: nil)
        }
    }

    @Test func reportsAFriendlyMessageWhenTheModelFailsToLoad() async throws {
        let intent = AddEffectIntent()
        intent.site = SiteEntity(id: "s1", name: "Acme", creationDate: nil, modificationDate: nil)
        intent.effect = .particleField
        let notConnectedClient = PageModelClient(toolCaller: { _, _ in
            throw PageModelClient.ModelError.notConnected
        })
        let dialog = try await Self.runForTesting(
            intent, catalog: EffectCatalog(entries: [Self.particleFieldEntry()]),
            pageModelClient: notConnectedClient, editRouter: StubRouter(status: .applied))
        #expect(dialog.contains("Acme"))
        #expect(dialog.contains("not running"))
    }
}
