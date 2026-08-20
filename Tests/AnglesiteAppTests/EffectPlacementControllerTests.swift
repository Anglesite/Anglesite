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

    /// The placement HUD's before/after toggle has to actually reach `PlacementMatcher`
    /// (#768 final review, Finding 6) — `resolve` hardcoded "after" before this.
    @Test func inlinePositionReachesTheResolvedInsertionIndex() async {
        let inlineEntry = EffectCatalogEntry(
            component: "MagneticButton", title: "Magnetic Button", ownerDescription: "d",
            category: .cursorReactive, keyProps: [:], snippet: "s",
            placement: .init(kind: .inline, allowedParents: nil))
        let click = PlacementPickMessage(
            path: "/", element: .init(tag: "SECTION", id: nil, classes: ["hero"], nthChild: 1, ancestors: [], dataAnglesiteId: nil, dataTestId: nil, role: nil, ariaLabel: nil, textContent: nil))

        func indexApplied(for position: PlacementMatcher.InlinePosition) async -> Int? {
            var applied: Int?
            let controller = EffectPlacementController(
                path: "src/pages/index.astro",
                pageModelClient: PageModelClient { _, _ in
                    MCPClient.ToolCallResult(content: [.init(type: "text", text: Self.modelJSON)], isError: false)
                },
                editRouter: TestEditRouter { message in
                    if case .object(let component)? = message.component, case .int(let index)? = component["index"] {
                        applied = index
                    }
                    return EditReply(id: message.id, status: .applied, message: nil)
                })
            controller.inlinePosition = position
            controller.startPlacement(for: inlineEntry, enterOverlayMode: {}, exitOverlayMode: {})
            await controller.handlePick(click)
            return applied
        }

        // The clicked SECTION is `<body>`'s only child (index 0 in the fixture tree).
        #expect(await indexApplied(for: .after) == 1)
        #expect(await indexApplied(for: .before) == 0)
    }

    // MARK: - acknowledge()

    @Test func acknowledgeReturnsToIdleFromSucceeded() async {
        let controller = await makeControllerAtTerminalState(applyReply: EditReply(id: "x", status: .applied, message: nil))
        guard case .succeeded = controller.state else {
            Issue.record("expected .succeeded before acknowledge()")
            return
        }
        controller.acknowledge()
        #expect(controller.state == .idle)
    }

    @Test func acknowledgeReturnsToIdleFromFailed() async {
        let controller = await makeControllerAtTerminalState(applyReply: EditReply(id: "x", status: .failed, message: "nope"))
        guard case .failed = controller.state else {
            Issue.record("expected .failed before acknowledge()")
            return
        }
        controller.acknowledge()
        #expect(controller.state == .idle)
    }

    @Test func acknowledgeIsNoOpFromIdle() {
        let controller = EffectPlacementController(
            path: "src/pages/index.astro",
            pageModelClient: PageModelClient { _, _ in MCPClient.ToolCallResult(content: [], isError: false) },
            editRouter: TestEditRouter { _ in EditReply(id: "x", status: .applied, message: nil) })
        #expect(controller.state == .idle)
        controller.acknowledge()
        #expect(controller.state == .idle)
    }

    @Test func acknowledgeIsNoOpFromPicking() {
        let controller = EffectPlacementController(
            path: "src/pages/index.astro",
            pageModelClient: PageModelClient { _, _ in MCPClient.ToolCallResult(content: [], isError: false) },
            editRouter: TestEditRouter { _ in EditReply(id: "x", status: .applied, message: nil) })
        controller.startPlacement(for: Self.entry, enterOverlayMode: {}, exitOverlayMode: {})
        controller.acknowledge()
        guard case .picking = controller.state else {
            Issue.record("expected acknowledge() to leave .picking untouched")
            return
        }
    }

    @Test func acknowledgeIsNoOpFromApplying() async {
        // Gate the model fetch on a manually-controlled `AsyncStream` so the test can observe
        // `.applying` and call `acknowledge()` mid-flight, deterministically, rather than racing
        // a fixed sleep against `handlePick`'s internal awaits.
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let pageModelClient = PageModelClient { _, _ in
            for await _ in stream { break }
            return MCPClient.ToolCallResult(content: [.init(type: "text", text: Self.modelJSON)], isError: false)
        }
        let controller = EffectPlacementController(
            path: "src/pages/index.astro", pageModelClient: pageModelClient,
            editRouter: TestEditRouter { _ in EditReply(id: "x", status: .applied, message: nil) })
        controller.startPlacement(for: Self.entry, enterOverlayMode: {}, exitOverlayMode: {})

        let click = PlacementPickMessage(
            path: "/", element: .init(tag: "SECTION", id: nil, classes: ["hero"], nthChild: 1, ancestors: [], dataAnglesiteId: nil, dataTestId: nil, role: nil, ariaLabel: nil, textContent: nil))
        let handlePickTask = Task { await controller.handlePick(click) }

        await pollUntil(timeout: .seconds(5)) {
            if case .applying = controller.state { return true }
            return false
        }
        guard case .applying = controller.state else {
            Issue.record("expected .applying before acknowledge()")
            continuation.finish()
            await handlePickTask.value
            return
        }

        controller.acknowledge()
        #expect(controller.state == .applying)

        continuation.finish()
        await handlePickTask.value
    }

    /// Drives a controller through a full pick → apply flow to land it on `.succeeded`/`.failed`,
    /// per `applyReply.status`, for the `acknowledge()` terminal-state tests above.
    private func makeControllerAtTerminalState(applyReply: EditReply) async -> EffectPlacementController {
        let pageModelClient = PageModelClient { _, _ in
            MCPClient.ToolCallResult(content: [.init(type: "text", text: Self.modelJSON)], isError: false)
        }
        let controller = EffectPlacementController(
            path: "src/pages/index.astro", pageModelClient: pageModelClient,
            editRouter: TestEditRouter { _ in applyReply })
        controller.startPlacement(for: Self.entry, enterOverlayMode: {}, exitOverlayMode: {})
        let click = PlacementPickMessage(
            path: "/", element: .init(tag: "SECTION", id: nil, classes: ["hero"], nthChild: 1, ancestors: [], dataAnglesiteId: nil, dataTestId: nil, role: nil, ariaLabel: nil, textContent: nil))
        await controller.handlePick(click)
        return controller
    }

    private func pollUntil(timeout: Duration, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Minimal `EditRouter` test double, matching the shape of per-suite doubles elsewhere in this
/// target (e.g. `ComponentEditorModelStructureEditTests.RecordingRouter`) but closure-based since
/// this suite only needs to observe the last applied op, not a full recording surface.
private struct TestEditRouter: EditRouter {
    let onApply: (EditMessage) -> EditReply
    func apply(_ message: EditMessage) async -> EditReply { onApply(message) }
}
