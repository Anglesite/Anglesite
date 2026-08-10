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
}

private extension OpResult {
    var isApplied: Bool { if case .applied = self { true } else { false } }
}
