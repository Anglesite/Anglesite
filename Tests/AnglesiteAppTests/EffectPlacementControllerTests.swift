import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteAppCore

@Suite @MainActor struct EffectPlacementControllerTests {
    static let entry = EffectCatalogEntry(
        component: "ParticleField", title: "Particle Field", ownerDescription: "d",
        category: .canvasBackground, keyProps: [:], snippet: "s",
        placement: .init(kind: .background, allowedParents: nil))

    static let modelJSON = """
    {"version":"sha256:x","path":"src/pages/index.astro","tree":{"id":"n0","kind":"fragment","tag":null,"attrs":[],"span":[0,1],"loc":null,"children":[
      {"id":"n1","kind":"element","tag":"BODY","attrs":[],"span":[0,1],"loc":null,"children":[
        {"id":"n2","kind":"element","tag":"SECTION","attrs":[{"name":"class","value":"hero"}],"span":[0,1],"loc":null,"children":[]}
      ]}
    ]}}
    """

    @Test func fullFlowAppliesInsertBlock() async {
        var appliedOp: String?
        var enteredOverlay = false
        var exitedOverlay = false
        let router = TestEditRouter { message in
            appliedOp = message.op
            return EditReply(id: message.id, status: .applied, message: nil)
        }
        let pageModelClient = PageModelClient { _, _ in
            MCPClient.ToolCallResult(content: [.init(type: "text", text: Self.modelJSON)], isError: false)
        }
        let controller = EffectPlacementController(
            path: "src/pages/index.astro", pageModelClient: pageModelClient, editRouter: router)

        controller.startPlacement(for: Self.entry, enterOverlayMode: { enteredOverlay = true }, exitOverlayMode: { exitedOverlay = true })
        #expect(enteredOverlay)
        guard case .picking = controller.state else {
            Issue.record("expected .picking")
            return
        }

        let click = PlacementPickMessage(
            path: "/", element: .init(tag: "SECTION", id: nil, classes: ["hero"], nthChild: 1, ancestors: [], dataAnglesiteId: nil, dataTestId: nil, role: nil, ariaLabel: nil, textContent: nil))
        await controller.handlePick(click)

        #expect(exitedOverlay)
        #expect(appliedOp == "insertBlock")
        #expect(controller.state == .succeeded)
    }

    @Test func noMatchSetsFailedState() async {
        let router = TestEditRouter { _ in Issue.record("apply should not be called"); return EditReply(id: "x", status: .failed, message: nil) }
        let pageModelClient = PageModelClient { _, _ in
            MCPClient.ToolCallResult(content: [.init(type: "text", text: Self.modelJSON)], isError: false)
        }
        let controller = EffectPlacementController(path: "src/pages/index.astro", pageModelClient: pageModelClient, editRouter: router)
        controller.startPlacement(for: Self.entry, enterOverlayMode: {}, exitOverlayMode: {})

        let click = PlacementPickMessage(
            path: "/", element: .init(tag: "ARTICLE", id: nil, classes: [], nthChild: 9, ancestors: [], dataAnglesiteId: nil, dataTestId: nil, role: nil, ariaLabel: nil, textContent: nil))
        await controller.handlePick(click)

        guard case .failed = controller.state else {
            Issue.record("expected .failed")
            return
        }
    }

    @Test func cancelReturnsToIdleAndExitsOverlay() {
        var exited = false
        let controller = EffectPlacementController(
            path: "src/pages/index.astro",
            pageModelClient: PageModelClient { _, _ in MCPClient.ToolCallResult(content: [], isError: false) },
            editRouter: TestEditRouter { _ in EditReply(id: "x", status: .applied, message: nil) })
        controller.startPlacement(for: Self.entry, enterOverlayMode: {}, exitOverlayMode: { exited = true })
        controller.cancel()
        #expect(exited)
        #expect(controller.state == .idle)
    }
}

/// Minimal `EditRouter` test double, matching the shape of per-suite doubles elsewhere in this
/// target (e.g. `ComponentEditorModelStructureEditTests.RecordingRouter`) but closure-based since
/// this suite only needs to observe the last applied op, not a full recording surface.
private struct TestEditRouter: EditRouter {
    let onApply: (EditMessage) -> EditReply
    func apply(_ message: EditMessage) async -> EditReply { onApply(message) }
}
