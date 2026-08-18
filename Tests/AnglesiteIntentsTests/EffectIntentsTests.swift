import Testing
import Foundation
@testable import AnglesiteIntents
@testable import AnglesiteCore

/// Covers `AddEffectIntent`: the pure `defaultInsertion` placement math (Step 2 of the task
/// brief), the pure `EffectDialogs` strings, and `run()`'s plan → confirm → apply flow driven
/// through `performForTesting()` with `AddEffectIntentOverride` fakes standing in for the
/// template-backed catalog and the site's `PageModelClient`/`EditRouter` registries.
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
        let fakes = AddEffectIntentFakes(
            catalog: EffectCatalog(entries: [Self.particleFieldEntry()]),
            pageModelClient: Self.fakePageModelClient(returning: Self.fixtureModelWithBody()),
            editRouter: StubRouter(status: .applied))
        let dialog = try await AddEffectIntentOverride.$scoped.withValue(fakes) {
            try await intent.performForTesting()
        }
        #expect(dialog == "Added Particle Field to Acme.")
    }

    @Test func reportsFailureWhenTheRouterRefuses() async throws {
        let intent = AddEffectIntent()
        intent.site = SiteEntity(id: "s1", name: "Acme", creationDate: nil, modificationDate: nil)
        intent.effect = .particleField
        let fakes = AddEffectIntentFakes(
            catalog: EffectCatalog(entries: [Self.particleFieldEntry()]),
            pageModelClient: Self.fakePageModelClient(returning: Self.fixtureModelWithBody()),
            editRouter: StubRouter(status: .failed, message: "stale version"))
        let dialog = try await AddEffectIntentOverride.$scoped.withValue(fakes) {
            try await intent.performForTesting()
        }
        #expect(dialog.contains("stale version"))
        #expect(dialog.contains("Acme"))
    }

    @Test func repromptsWithoutConfirmingWhenTheSiteIsntOpen() async throws {
        let intent = AddEffectIntent()
        intent.site = SiteEntity(id: "s1", name: "Acme", creationDate: nil, modificationDate: nil)
        intent.effect = .particleField
        let fakes = AddEffectIntentFakes(
            catalog: EffectCatalog(entries: [Self.particleFieldEntry()]),
            pageModelClient: nil,
            editRouter: nil)
        let dialog = try await AddEffectIntentOverride.$scoped.withValue(fakes) {
            try await intent.performForTesting()
        }
        #expect(dialog == "Open Acme in Anglesite first, then try adding this effect again.")
    }

    @Test func repromptsWhenTheMatchedEntryHasNoPlacement() async throws {
        let intent = AddEffectIntent()
        intent.site = SiteEntity(id: "s1", name: "Acme", creationDate: nil, modificationDate: nil)
        intent.effect = .particleField
        let legacyEntry = EffectCatalogEntry(
            component: "ParticleField", title: "Particle Field", ownerDescription: "d",
            category: .canvasBackground, keyProps: [:], snippet: "s", placement: nil)
        let fakes = AddEffectIntentFakes(
            catalog: EffectCatalog(entries: [legacyEntry]),
            pageModelClient: Self.fakePageModelClient(returning: Self.fixtureModelWithBody()),
            editRouter: StubRouter(status: .applied))
        let dialog = try await AddEffectIntentOverride.$scoped.withValue(fakes) {
            try await intent.performForTesting()
        }
        #expect(dialog.contains("Particle Field"))
        #expect(dialog.contains("Effects gallery"))
    }

    @Test func repromptsWhenTheEffectIsntInTheCatalog() async throws {
        let intent = AddEffectIntent()
        intent.site = SiteEntity(id: "s1", name: "Acme", creationDate: nil, modificationDate: nil)
        intent.effect = .dotGridPulse
        let fakes = AddEffectIntentFakes(
            catalog: EffectCatalog(entries: [Self.particleFieldEntry()]), // no "Dot Grid Pulse" entry
            pageModelClient: Self.fakePageModelClient(returning: Self.fixtureModelWithBody()),
            editRouter: StubRouter(status: .applied))
        let dialog = try await AddEffectIntentOverride.$scoped.withValue(fakes) {
            try await intent.performForTesting()
        }
        #expect(dialog.contains("Dot Grid Pulse"))
    }

    @Test func reportsAFriendlyMessageWhenTheModelFailsToLoad() async throws {
        let intent = AddEffectIntent()
        intent.site = SiteEntity(id: "s1", name: "Acme", creationDate: nil, modificationDate: nil)
        intent.effect = .particleField
        let notConnectedClient = PageModelClient(toolCaller: { _, _ in
            throw PageModelClient.ModelError.notConnected
        })
        let fakes = AddEffectIntentFakes(
            catalog: EffectCatalog(entries: [Self.particleFieldEntry()]),
            pageModelClient: notConnectedClient,
            editRouter: StubRouter(status: .applied))
        let dialog = try await AddEffectIntentOverride.$scoped.withValue(fakes) {
            try await intent.performForTesting()
        }
        #expect(dialog.contains("Acme"))
        #expect(dialog.contains("not running"))
    }
}
