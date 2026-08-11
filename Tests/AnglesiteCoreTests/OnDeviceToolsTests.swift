import Testing
import Foundation
@testable import AnglesiteCore

// Gated like the types under test — FoundationModels is unavailable at runtime on CI (#128).
// These tests need no live model: the tools' `call(...)` is pure mapping/routing/query logic.
#if compiler(>=6.4) && canImport(FoundationModels)
import FoundationModels
import AnglesiteTestSupport

/// Records the EditMessage it receives and returns a canned reply.
private actor FakeEditRouter: EditRouter {
    private(set) var received: EditMessage?
    private let reply: EditReply
    init(reply: EditReply) { self.reply = reply }
    func apply(_ message: EditMessage) async -> EditReply {
        received = message
        return reply
    }
}

private func makeBridge(_ router: FakeEditRouter) -> IntentEditBridge {
    IntentEditBridge(routerProvider: { _ in router }, makeID: { "test-id" })
}

@Suite("On-device tools: ApplyEditTool")
struct ApplyEditToolTests {

    @Test("context selector is used verbatim; value is wrapped; path is forwarded")
    func usesContextSelectorAndMapsOp() async throws {
        let router = FakeEditRouter(reply: EditReply(id: "test-id", status: .applied, message: "ok"))
        let element: JSONValue = .object([
            "tag": .string("h1"), "classes": .array([]), "nthChild": .int(1),
        ])
        let tool = ApplyEditTool(bridge: makeBridge(router), siteID: "site1", contextSelector: element)
        let cmd = GeneratedEditCommand(
            filePath: "src/pages/about.md",
            selector: "ignored-by-tool",
            operation: .replaceText,
            value: "New Title",
            explanation: "rename heading"
        )

        let out = try await tool.call(arguments: cmd)

        // Op-string mapping is exhaustively asserted in `mapsEveryOperationToItsOpString`.
        let msg = await router.received
        #expect(msg?.selector == element)
        #expect(msg?.value == .string("New Title"))
        #expect(msg?.path == "src/pages/about.md")
        #expect(out.contains("Applied"))
    }

    /// The op-vocabulary bridge between #154 (`EditOperation`) and #156 (`ApplyEditTool`):
    /// every `EditOperation` case must map onto its `EditMessage.Op` string. Single source of
    /// truth for that mapping (see the C.11 audit, #161).
    @Test("every EditOperation maps to its EditMessage.Op string", arguments: [
        (EditOperation.replaceText, EditMessage.Op.replaceText),
        (EditOperation.replaceAttr, EditMessage.Op.replaceAttr),
        (EditOperation.replaceImageSrc, EditMessage.Op.replaceImageSrc),
        (EditOperation.applyInstruction, EditMessage.Op.applyInstruction),
    ])
    func mapsEveryOperationToItsOpString(operation: EditOperation, expectedOp: String) async throws {
        let router = FakeEditRouter(reply: EditReply(id: "test-id", status: .applied, message: "ok"))
        let element: JSONValue = .object([
            "tag": .string("h1"), "classes": .array([]), "nthChild": .int(1),
        ])
        let tool = ApplyEditTool(bridge: makeBridge(router), siteID: "site1", contextSelector: element)
        let cmd = GeneratedEditCommand(
            filePath: "src/pages/about.md",
            selector: "ignored-by-tool",
            operation: operation,
            value: "value",
            explanation: "x"
        )

        _ = try await tool.call(arguments: cmd)

        let msg = await router.received
        #expect(msg?.op == expectedOp)
    }

    /// #1410: without a real overlay selection, the bare-tag fallback has no `textContent` — and
    /// the sidecar's `.astro` resolver locates the target element by searching for its *current*
    /// text/attribute value for every op except `applyInstruction` (`patcher.mjs`'s `resolveAstro`
    /// / `getAttrSearchValue`). Sending that incomplete selector downstream was guaranteed to fail
    /// with a confusing message; refusing here up front is both correct and clearer.
    @Test("no context selector + bare-tag selector refuses ops that need the element's current text", arguments: [
        EditOperation.replaceText, EditOperation.replaceAttr, EditOperation.replaceImageSrc,
    ])
    func bareTagRefusesOpsThatNeedCurrentText(operation: EditOperation) async throws {
        let router = FakeEditRouter(reply: EditReply(id: "test-id", status: .applied, message: nil))
        let tool = ApplyEditTool(bridge: makeBridge(router), siteID: "site1", contextSelector: nil)
        let cmd = GeneratedEditCommand(
            filePath: "src/pages/index.md",
            selector: "H1",
            operation: operation,
            value: "hello",
            explanation: "x"
        )

        let out = try await tool.call(arguments: cmd)

        #expect(await router.received == nil)
        #expect(out.contains("Select it in the preview"))
    }

    @Test("no context selector + bare-tag selector still forwards apply-instruction (no current text needed)")
    func bareTagAllowsApplyInstruction() async throws {
        let router = FakeEditRouter(reply: EditReply(id: "test-id", status: .applied, message: nil))
        let tool = ApplyEditTool(bridge: makeBridge(router), siteID: "site1", contextSelector: nil)
        let cmd = GeneratedEditCommand(
            filePath: "src/pages/index.md",
            selector: "H1",
            operation: .applyInstruction,
            value: "make it punchier",
            explanation: "x"
        )

        _ = try await tool.call(arguments: cmd)

        let msg = await router.received
        #expect(msg?.selector == .object([
            "tag": .string("h1"), "classes": .array([]), "nthChild": .int(1),
        ]))
        // Op-string mapping is exhaustively asserted in `mapsEveryOperationToItsOpString`.
    }

    @Test("no context selector + complex selector fails gracefully without calling the bridge")
    func complexSelectorFailsGracefully() async throws {
        let router = FakeEditRouter(reply: EditReply(id: "test-id", status: .applied, message: "ok"))
        let tool = ApplyEditTool(bridge: makeBridge(router), siteID: "site1", contextSelector: nil)
        let cmd = GeneratedEditCommand(
            filePath: "src/pages/index.md",
            selector: "p:nth-of-type(2)",
            operation: .replaceText,
            value: "x",
            explanation: "x"
        )

        let out = try await tool.call(arguments: cmd)

        #expect(await router.received == nil)
        #expect(out.contains("Couldn't identify"))
    }

    @Test("a failed reply surfaces its message in the tool output")
    func failedReplySurfacesMessage() async throws {
        let router = FakeEditRouter(reply: EditReply(id: "test-id", status: .failed, message: "no router for this site"))
        let element: JSONValue = .object(["tag": .string("h1"), "classes": .array([]), "nthChild": .int(1)])
        let tool = ApplyEditTool(bridge: makeBridge(router), siteID: "site1", contextSelector: element)
        let cmd = GeneratedEditCommand(
            filePath: "src/pages/about.md", selector: "h1",
            operation: .applyInstruction, value: "make it punchier", explanation: "x"
        )

        let out = try await tool.call(arguments: cmd)

        #expect(out.contains("failed"))
        #expect(out.contains("no router for this site"))
    }

    @Test("an ambiguous reply returns a distinct, recoverable message")
    func ambiguousReplyIsDistinct() async throws {
        let router = FakeEditRouter(reply: EditReply(id: "test-id", status: .ambiguous, message: "3 elements matched."))
        let element: JSONValue = .object(["tag": .string("p"), "classes": .array([]), "nthChild": .int(1)])
        let tool = ApplyEditTool(bridge: makeBridge(router), siteID: "site1", contextSelector: element)
        let cmd = GeneratedEditCommand(
            filePath: "src/pages/about.md", selector: "p",
            operation: .replaceText, value: "x", explanation: "x"
        )

        let out = try await tool.call(arguments: cmd)

        #expect(out.contains("more than one element"))
        #expect(out.contains("3 elements matched."))
        #expect(!out.contains("Edit failed"))
    }
}

@Suite("On-device tools: SearchContentTool")
struct SearchContentToolTests {

    private func makeGraph() async -> SiteContentGraph {
        let graph = SiteContentGraph()
        await graph.upsertPage(.init(
            id: "site1:page:/about", siteID: "site1", route: "/about",
            filePath: "src/pages/about.md", title: "About Us",
            lastModified: Date(timeIntervalSince1970: 0)
        ))
        await graph.upsertPost(.init(
            id: "site1:post:hello", siteID: "site1", collection: "posts", slug: "hello-world",
            title: "Hello World", draft: true, publishDate: nil, tags: ["intro"],
            filePath: "src/posts/hello.md", lastModified: Date(timeIntervalSince1970: 0)
        ))
        return graph
    }

    @Test("finds a page by title and formats it")
    func findsPageByTitle() async throws {
        let tool = SearchContentTool(contentGraph: await makeGraph(), siteID: "site1")
        let out = try await tool.call(arguments: .init(query: "about"))
        #expect(out.contains("PAGE"))
        #expect(out.contains("/about"))
        #expect(out.contains("src/pages/about.md"))
    }

    @Test("marks a draft post and includes its file path")
    func findsDraftPost() async throws {
        let tool = SearchContentTool(contentGraph: await makeGraph(), siteID: "site1")
        let out = try await tool.call(arguments: .init(query: "hello"))
        #expect(out.contains("POST"))
        #expect(out.contains("hello-world"))
        #expect(out.contains("[draft]"))
        #expect(out.contains("src/posts/hello.md"))
    }

    @Test("an empty query is rejected without dumping all content")
    func emptyQueryIsRejected() async throws {
        let tool = SearchContentTool(contentGraph: await makeGraph(), siteID: "site1")
        let out = try await tool.call(arguments: .init(query: "   "))
        #expect(out == "Provide a search term — a word from a page title, route, post slug, or tag.")
        #expect(!out.contains("PAGE"))
        #expect(!out.contains("POST"))
    }

    @Test("no matches on an unpopulated index says so and doesn't assert non-existence")
    func noMatchesOnUnpopulatedIndexIsExplicit() async throws {
        // makeGraph() seeds via upsert*, never load(siteID:...), so the graph is unpopulated for
        // site1 — the same "runtime never ran a scan" state as #658.
        let tool = SearchContentTool(contentGraph: await makeGraph(), siteID: "site1")
        let out = try await tool.call(arguments: .init(query: "zzz-no-such-thing"))
        #expect(out.contains("hasn't been loaded yet"))
        // #658: a search miss must not read as proof the content doesn't exist — filesystem-backed
        // tools (repurposePost, reviewCopy) can still succeed against an unpopulated index.
        #expect(out.contains("does not mean the content doesn't exist"))
    }

    @Test("no matches on a populated index is reported as reliable")
    func noMatchesOnPopulatedIndexIsReliable() async throws {
        let graph = SiteContentGraph()
        await graph.load(
            siteID: "site1",
            pages: [.init(
                id: "site1:page:/about", siteID: "site1", route: "/about", filePath: "src/pages/about.md",
                title: "About Us", lastModified: Date(timeIntervalSince1970: 0))],
            posts: [], images: [])
        let tool = SearchContentTool(contentGraph: graph, siteID: "site1")
        let out = try await tool.call(arguments: .init(query: "zzz-no-such-thing"))
        #expect(out.contains("index is loaded and current"))
        #expect(!out.contains("hasn't been loaded yet"))
    }

    @Test("a flood of pages does not silently exclude posts; truncation is reported per category")
    func truncationIsFairAndReportedPerCategory() async throws {
        let graph = SiteContentGraph()
        // 20 matching pages + 3 matching posts = 23 > the 20-result cap.
        for i in 0..<20 {
            let n = String(format: "%02d", i)
            await graph.upsertPage(.init(
                id: "site1:page:/p\(n)", siteID: "site1", route: "/p\(n)",
                filePath: "src/pages/p\(n).md", title: "Page \(n)",
                lastModified: Date(timeIntervalSince1970: 0)
            ))
        }
        for i in 0..<3 {
            await graph.upsertPost(.init(
                id: "site1:post:post\(i)", siteID: "site1", collection: "posts", slug: "post-\(i)",
                title: "Post \(i)", draft: false, publishDate: nil, tags: [],
                filePath: "src/posts/post\(i).md", lastModified: Date(timeIntervalSince1970: 0)
            ))
        }
        let tool = SearchContentTool(contentGraph: graph, siteID: "site1")
        // "p" matches every page route (/pNN) and every post slug (post-N).
        let out = try await tool.call(arguments: .init(query: "p"))

        // The bug being fixed: posts must NOT be crowded out by the 20 pages.
        let postCount = out.split(separator: "\n").filter { $0.hasPrefix("POST") }.count
        #expect(postCount == 3)
        // 17 pages shown, 3 hidden; all 3 posts shown, 0 hidden — reported per category.
        #expect(out.contains("+3 more pages"))
        #expect(!out.contains("more post"))
        #expect(out.contains("refine your query to narrow results."))
    }
}

@Suite("On-device tools: SearchKnowledgeTool")
struct SearchKnowledgeToolTests {

    @Test("formats cited project excerpts")
    func formatsCitedProjectExcerpts() async throws {
        let root = try! writeSiteTree(prefix: "knowledge-tool", [
            "src/pages/pricing.astro": "---\ntitle: Pricing\n---\n# Pricing\nTeam plans mention annual billing.",
        ])
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "site1", projectRoot: root)
        let tool = SearchKnowledgeTool(index: index, siteID: "site1")

        let out = try await tool.call(arguments: .init(query: "annual billing"))

        #expect(out.contains("PAGE"))
        #expect(out.contains("src/pages/pricing.astro"))
        #expect(out.contains(":"))
        #expect(out.contains("annual billing"))
    }

    @Test("empty query is rejected without dumping context")
    func emptyQueryIsRejected() async throws {
        let tool = SearchKnowledgeTool(index: SiteKnowledgeIndex(), siteID: "site1")
        let out = try await tool.call(arguments: .init(query: "   "))
        #expect(out == "Provide a project search query.")
    }
}

@Suite("FoundationModelAssistant tool wiring")
struct FoundationModelAssistantToolWiringTests {

    @Test("supportsTools is always true (SpotlightSearchTool is unconditional)")
    func capabilitiesAlwaysSupportTools() async {
        let router = FakeEditRouter(reply: EditReply(id: "x", status: .applied, message: nil))
        let bridge = makeBridge(router)
        let graph = SiteContentGraph()

        let withTools = FoundationModelAssistant(
            tier: .onDevice,
            editBridge: bridge,
            contentGraph: graph,
            knowledgeIndex: SiteKnowledgeIndex()
        )
        #expect(withTools.capabilities.supportsTools == true)

        let withoutTools = FoundationModelAssistant(tier: .onDevice)
        #expect(withoutTools.capabilities.supportsTools == true)  // SpotlightSearchTool is unconditional (C.8, #158)

        let partial = FoundationModelAssistant(tier: .onDevice, editBridge: bridge, contentGraph: nil)
        #expect(partial.capabilities.supportsTools == true)  // SpotlightSearchTool is unconditional (C.8, #158)

        let partialGraph = FoundationModelAssistant(tier: .onDevice, editBridge: nil, contentGraph: graph)
        #expect(partialGraph.capabilities.supportsTools == true)  // SpotlightSearchTool is unconditional (C.8, #158)
    }

    private func modelAvailable() -> Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    @Test("converse .started reports Spotlight tool unconditionally, and edit/search tools when wired")
    func startedReportsToolNames() async throws {
        guard modelAvailable() else { return }
        let router = FakeEditRouter(reply: EditReply(id: "x", status: .applied, message: nil))
        let assistant = FoundationModelAssistant(
            tier: .onDevice,
            editBridge: makeBridge(router),
            contentGraph: SiteContentGraph(),
            knowledgeIndex: SiteKnowledgeIndex()
        )
        let context = AssistantContext(siteID: "site-1", siteDirectory: URL(fileURLWithPath: "/tmp/site"))

        var startedToolNames: [String]?
        for await event in try await assistant.converse(prompt: "Say hi.", context: context) {
            if case .started(_, let toolNames) = event {
                startedToolNames = toolNames
                break  // the names are fixed at turn open; no need to drain the model's response
            }
        }
        // SpotlightSearchTool is unconditional; edit/search pair is conditional on both deps (C.8, #158)
        #expect(startedToolNames == [
            "spotlightSearch",
            ApplyEditTool.toolName,
            SearchContentTool.toolName,
            SearchKnowledgeTool.toolName,
            SuggestLinksTool.toolName,
            FindLinkOpportunitiesTool.toolName,
        ])
    }

    @Test("a semantic ranker is accepted and the knowledge tool is still advertised (#312)")
    func startedReportsKnowledgeToolWithRanker() async throws {
        guard modelAvailable() else { return }
        let router = FakeEditRouter(reply: EditReply(id: "x", status: .applied, message: nil))
        let assistant = FoundationModelAssistant(
            tier: .onDevice,
            editBridge: makeBridge(router),
            contentGraph: SiteContentGraph(),
            knowledgeIndex: SiteKnowledgeIndex(),
            semanticRanker: SemanticRanker(provider: FakeEmbeddingProvider(dimension: 8), cache: nil)
        )
        let context = AssistantContext(siteID: "site-1", siteDirectory: URL(fileURLWithPath: "/tmp/site"))

        var startedToolNames: [String]?
        for await event in try await assistant.converse(prompt: "Say hi.", context: context) {
            if case .started(_, let toolNames) = event {
                startedToolNames = toolNames
                break
            }
        }
        // The ranker is wired into SearchKnowledgeTool without changing the advertised tool set.
        #expect(startedToolNames?.contains(SearchKnowledgeTool.toolName) == true)
    }
}
#endif
