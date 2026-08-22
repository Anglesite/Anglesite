import Foundation
import Testing
@testable import AnglesiteAppCore
@testable import AnglesiteCore

/// Proves the full vertical slice this PR (#1225 PR1 "Plumbing") exists to deliver: a
/// controller-submitted op crosses the (in-process, same-target) dispatcher, applies against
/// `StubWYSIWYGHostTransport`, updates `WYSIWYGCanvasController.model`, and registers on a real
/// `UndoManager` with working undo/redo. Tasks 1-14 each unit-test one link in this chain
/// (`WYSIWYGCanvasControllerTests`, `WYSIWYGUndoCoordinatorTests`, `StubWYSIWYGHostTransportTests`,
/// ...); this suite is the only one that exercises them wired together end-to-end.
///
/// Module note: the brief this task was written from sketches `@testable import AnglesiteApp`,
/// but `WYSIWYGCanvasController.swift` actually lives in the `AnglesiteAppCore` library target
/// (see `Package.swift`'s `AnglesiteAppCore` target, `path: "Sources/AnglesiteApp"`) — `AnglesiteApp`
/// is the (untestable, hosted) hook-up target. `Tests/AnglesiteAppTests`'s existing
/// `WYSIWYGCanvasControllerTests.swift` already imports `AnglesiteAppCore`, matched here.
@Suite("WYSIWYG plumbing end-to-end")
@MainActor
struct WYSIWYGPlumbingIntegrationTests {
    @Test("a submitted op round-trips through the stub transport into the model and is undoable/redoable through a real UndoManager")
    func insertRoundTripsAndUndoes() async {
        let initial = BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: [], blocks: [:])
        let controller = WYSIWYGCanvasController(initialModel: initial, transport: StubWYSIWYGHostTransport(model: initial))

        // Mirrors SiteWindowModel.swift's real wiring: `preview.wysiwygCanvas?.undoCoordinator
        // .undoManager = windowUndoManager` — the controller's `undoCoordinator` is `lazy`,
        // constructed with its `Performer` closure at `init` time, so the test only needs to
        // attach a real `UndoManager` to it, not construct a coordinator of its own.
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false // no run loop in a test; see WYSIWYGUndoCoordinator's doc
        controller.undoCoordinator.undoManager = undoManager

        // A directly-submitted op stands in for a menu-triggered one (e.g. Insert menu ->
        // `insertBlock(_:)`, Format menu -> `applyFormat(_:)`'s JS round trip, or Edit menu's
        // `deleteSelectedBlock()`): all of them funnel through `submit(_:)`, the same entry point
        // exercised here, so this is the representative seam for "menu-triggered op."
        let op = Op.insertBlock(
            parentId: rootParentID, slot: "main", index: 0, newId: "b1",
            block: BlockNodeContent(kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0]))
        let result = await controller.submit(op)

        #expect(result.isApplied)
        #expect(controller.model.rootIds == ["b1"])
        #expect(undoManager.canUndo)

        undoManager.undo()
        // Task 9's fix rounds made undo/redo registration synchronous (so `UndoManager` files the
        // opposite-direction registration on the right stack) but the actual document mutation —
        // `WYSIWYGUndoCoordinator`'s `Performer`, which calls back into `controller.apply(_:)` —
        // still runs on a detached `Task` (see that type's `register(op:redoOp:)` doc comment).
        // `pendingPerform` is exposed by the coordinator specifically so tests can await that
        // in-flight `Task` deterministically instead of guessing at a `Task.sleep` duration — the
        // same event-driven pattern `WYSIWYGUndoCoordinatorTests.swift` already uses for the
        // coordinator in isolation; here it's exercised through the real controller instead of a
        // bare `Performer` closure.
        await controller.undoCoordinator.pendingPerform?.value
        #expect(controller.model.rootIds.isEmpty)
        #expect(undoManager.canRedo)

        undoManager.redo()
        await controller.undoCoordinator.pendingPerform?.value
        #expect(controller.model.rootIds == ["b1"])
        #expect(controller.model.blocks["b1"]?.componentName == "p")
    }

    /// Task 5 (#1222): proves the production seam — `PreviewModel.enterEditMode(path:)` really
    /// fetches through `PageModelClient`/`get_page_model` and adapts the result via
    /// `PageModelBlockAdapter`, rather than seeding the canvas with a placeholder model. Uses
    /// ``makeFakeGetPageModelClient(pageModel:)`` (below) to give `UnavailableSiteRuntime` a real,
    /// started `MCPClient` backed by an in-process fake transport — the same shape
    /// `MCPClientTests.FakeMCPServerTransport` establishes, scoped to just `get_page_model` since
    /// that's the only tool this call path exercises (`enterEditMode` never calls `editRouter
    /// .apply` itself; that only happens once an op is submitted through the mounted canvas).
    @Test("enterEditMode fetches the real page model through PageModelClient and wires SidecarWYSIWYGHostTransport")
    func enterEditModeFetchesRealModelThroughSidecarTransport() async throws {
        let canned = PageModel(
            version: "sha256:canned0000", path: "src/pages/index.astro",
            tree: .init(
                id: "root", kind: .fragment, tag: nil, attrs: [], span: .init(start: 0, end: 0),
                loc: nil, text: nil, children: [], block: nil))
        let client = try await makeFakeGetPageModelClient(pageModel: canned)
        let previewModel = PreviewModel(runtime: UnavailableSiteRuntime(
            reason: "no runtime needed — this test only exercises the get_page_model fetch",
            mcpClient: client))

        await previewModel.enterEditMode(path: "src/pages/index.astro", undoManager: nil)

        #expect(previewModel.isEditModeEnabled)
        #expect(previewModel.wysiwygCanvas?.model.path == "src/pages/index.astro")
        #expect(previewModel.wysiwygCanvas?.model.version == "sha256:canned0000")
    }
}

private extension OpResult {
    var isApplied: Bool { if case .applied = self { true } else { false } }
}

// MARK: - Shared fake `get_page_model` MCP transport

/// In-process fake `MCPTransport` answering `get_page_model` (`tools/call`) with a canned
/// `PageModel`, encoded exactly like a real sidecar reply (`content: [{type: "text", text:
/// <json>}], isError: false`). Mirrors `MCPClientTests.FakeMCPServerTransport`'s pattern (no
/// subprocess, no wall-clock dependency, responses yielded synchronously from `send(_:)`) but
/// scoped to the one tool this feature's tests need. `internal` (not `private`) so both this
/// file's own test above and `PreviewModelWYSIWYGTests.swift` can share it instead of each
/// re-implementing a fake MCP server.
actor FakeGetPageModelTransport: MCPTransport {
    private var continuation: AsyncStream<JSONValue>.Continuation?
    private let stream: AsyncStream<JSONValue>
    private let pageModelJSON: String

    init(pageModel: PageModel) {
        var cont: AsyncStream<JSONValue>.Continuation!
        stream = AsyncStream { cont = $0 }
        continuation = cont
        let data = try! JSONEncoder().encode(pageModel) // fixed, always-encodable model — force_try is safe here
        pageModelJSON = String(data: data, encoding: .utf8)!
    }

    func open() async throws {}
    nonisolated func inbound() -> AsyncStream<JSONValue> { stream }
    func close() async { continuation?.finish() }

    func send(_ message: JSONValue) async throws {
        guard case .object(let obj) = message, case .string(let method)? = obj["method"] else { return }
        guard case .int(let id)? = obj["id"] else { return } // notifications get no response
        switch method {
        case "tools/call":
            continuation?.yield(.object([
                "jsonrpc": .string("2.0"),
                "id": .int(id),
                "result": .object([
                    "content": .array([.object(["type": .string("text"), "text": .string(pageModelJSON)])]),
                    "isError": .bool(false),
                ]),
            ]))
        default:
            // Covers the `server/discover` ready probe too: any JSON-RPC response (error
            // included) proves liveness, per `MCPClient.probeServerReady()`.
            continuation?.yield(.object([
                "jsonrpc": .string("2.0"),
                "id": .int(id),
                "error": .object(["code": .int(-32601), "message": .string("method not found")]),
            ]))
        }
    }
}

/// Builds a started `MCPClient` backed by ``FakeGetPageModelTransport``. `internal` for the same
/// cross-file sharing reason as the transport above.
func makeFakeGetPageModelClient(pageModel: PageModel) async throws -> MCPClient {
    let client = MCPClient(supervisor: .shared)
    try await client.startWithTransport(
        FakeGetPageModelTransport(pageModel: pageModel), readyTimeout: 5, clientName: "test", clientVersion: "0")
    return client
}
