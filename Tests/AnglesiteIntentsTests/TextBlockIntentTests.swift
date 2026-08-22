import Testing
import Foundation
@testable import AnglesiteIntents
@testable import AnglesiteCore

/// Covers `AddTextBlockIntent`: the pure `TextBlockDialogs` strings and `run()`'s
/// fetch → confirm → apply flow driven through `performForTesting()` with
/// `SiteConnectionOverride` standing in for the site's `PageModelClient`/`EditRouter`
/// registries — mirrors `EffectIntentsTests`.
@Suite struct TextBlockIntentTests {
    // MARK: - Fixtures

    /// Local duplicate of `EffectIntentsTests.fixtureModelWithBody()` — test targets don't depend
    /// on each other, so this is intentionally re-declared here rather than imported.
    static func fixtureModelWithBody() -> PageModel {
        func node(_ id: String, kind: PageModel.Node.Kind, tag: String?, children: [PageModel.Node] = []) -> PageModel.Node {
            PageModel.Node(id: id, kind: kind, tag: tag, attrs: [], span: .init(start: nil, end: nil), loc: nil, text: nil, children: children, block: nil)
        }
        let body = node("n1", kind: .element, tag: "BODY", children: [
            node("n2", kind: .element, tag: "HEADER"),
            node("n3", kind: .element, tag: "FOOTER"),
        ])
        let root = node("n0", kind: .fragment, tag: nil, children: [body])
        return PageModel(version: "v1", path: "src/pages/index.astro", tree: root)
    }

    static func fakePageModelClient(returning model: PageModel) -> PageModelClient {
        PageModelClient(toolCaller: { name, _ in
            #expect(name == "get_page_model")
            let data = try JSONEncoder().encode(model)
            return MCPClient.ToolCallResult(content: [.init(type: "text", text: String(data: data, encoding: .utf8)!)], isError: false)
        })
    }

    /// Replies `.applied` (with the `inverseNodeId`/`postWriteVersion` the insert's `richText`
    /// follow-up needs) for the initial `insertBlock`, and `.applied` for its `editText`
    /// follow-up — unless `insertStatus` is overridden to exercise a router refusal.
    actor TextRouter: EditRouter {
        let insertStatus: EditReply.Status
        let insertMessage: String?
        init(insertStatus: EditReply.Status = .applied, insertMessage: String? = nil) {
            self.insertStatus = insertStatus
            self.insertMessage = insertMessage
        }
        func apply(_ message: EditMessage) async -> EditReply {
            switch message.op {
            case EditMessage.Op.insertBlock:
                return EditReply(
                    id: message.id, status: insertStatus, message: insertMessage,
                    inverseNodeId: "n99", postWriteVersion: "sha256:postwrite1")
            case EditMessage.Op.editText:
                return EditReply(id: message.id, status: .applied, message: nil, postWriteVersion: "sha256:postwrite2")
            default:
                return EditReply(id: message.id, status: .applied, message: nil)
            }
        }
    }

    static func runForTesting(
        _ intent: AddTextBlockIntent, pageModelClient: PageModelClient?, editRouter: EditRouter?
    ) async throws -> String {
        try await SiteConnectionOverride.$scoped.withValue(
            SiteConnection(pageModelClient: pageModelClient, editRouter: editRouter)
        ) {
            try await intent.performForTesting()
        }
    }

    // MARK: - TextBlockDialogs (pure)

    @Test func dialogsCoverSuccessAndFailure() {
        #expect(TextBlockDialogs.applied(siteName: "Acme").contains("Acme"))
        #expect(TextBlockDialogs.failed(siteName: "Acme", reason: "nope").contains("nope"))
        #expect(TextBlockDialogs.siteNotOpen(siteName: "Acme").contains("Acme"))
    }

    // MARK: - run() via performForTesting()

    @Test func appliesTheTextBlockAndReportsSuccess() async throws {
        let intent = AddTextBlockIntent()
        intent.site = SiteEntity(id: "s1", name: "Acme", creationDate: nil, modificationDate: nil)
        intent.text = "Hello world"
        let dialog = try await Self.runForTesting(
            intent,
            pageModelClient: Self.fakePageModelClient(returning: Self.fixtureModelWithBody()),
            editRouter: TextRouter())
        #expect(dialog == "Added a paragraph to Acme.")
    }

    @Test func reportsFailureWhenTheRouterRefuses() async throws {
        let intent = AddTextBlockIntent()
        intent.site = SiteEntity(id: "s1", name: "Acme", creationDate: nil, modificationDate: nil)
        intent.text = "Hello world"
        let dialog = try await Self.runForTesting(
            intent,
            pageModelClient: Self.fakePageModelClient(returning: Self.fixtureModelWithBody()),
            editRouter: TextRouter(insertStatus: .failed, insertMessage: "stale version"))
        #expect(dialog.contains("stale version"))
        #expect(dialog.contains("Acme"))
    }

    @Test func repromptsWithoutConfirmingWhenTheSiteIsntOpen() async throws {
        let intent = AddTextBlockIntent()
        intent.site = SiteEntity(id: "s1", name: "Acme", creationDate: nil, modificationDate: nil)
        intent.text = "Hello world"
        let dialog = try await Self.runForTesting(intent, pageModelClient: nil, editRouter: nil)
        #expect(dialog == "Open Acme in Anglesite first, then try adding this text again.")
    }

    @Test func reportsAFriendlyMessageWhenTheModelFailsToLoad() async throws {
        let intent = AddTextBlockIntent()
        intent.site = SiteEntity(id: "s1", name: "Acme", creationDate: nil, modificationDate: nil)
        intent.text = "Hello world"
        let notConnectedClient = PageModelClient(toolCaller: { _, _ in
            throw PageModelClient.ModelError.notConnected
        })
        let dialog = try await Self.runForTesting(
            intent, pageModelClient: notConnectedClient, editRouter: TextRouter())
        #expect(dialog.contains("Acme"))
        #expect(dialog.contains("not running"))
    }

    /// Mirrors `AddEffectIntent`'s equivalent regression test: the sidecar's `get_page_model` and
    /// `insertBlock` both reject a route outright, so the intent must fetch/edit the project-
    /// relative `.astro` source path, never `"/"`.
    /// Records the `path` argument `AddTextBlockIntent` sends to `get_page_model`.
    actor PathRecorder {
        private(set) var fetchedPath: String?
        func recordFetch(_ path: String) { fetchedPath = path }
    }

    @Test func fetchesAndEditsTheHomePageSourcePathNotARoute() async throws {
        let model = Self.fixtureModelWithBody()
        let recorder = PathRecorder()
        let client = PageModelClient(toolCaller: { name, arguments in
            #expect(name == "get_page_model")
            if case .object(let object) = arguments, case .string(let path)? = object["path"] {
                await recorder.recordFetch(path)
            }
            let data = try JSONEncoder().encode(model)
            return MCPClient.ToolCallResult(content: [.init(type: "text", text: String(data: data, encoding: .utf8)!)], isError: false)
        })
        let intent = AddTextBlockIntent()
        intent.site = SiteEntity(id: "s1", name: "Acme", creationDate: nil, modificationDate: nil)
        intent.text = "Hello world"
        _ = try await Self.runForTesting(intent, pageModelClient: client, editRouter: TextRouter())

        let fetched = await recorder.fetchedPath
        #expect(fetched == "src/pages/index.astro")
        #expect(PageSourcePath.isValidPageSourcePath(fetched ?? "/"))
    }
}
