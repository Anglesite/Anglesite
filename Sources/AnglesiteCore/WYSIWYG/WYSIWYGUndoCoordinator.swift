// UndoManager is a Darwin-only Foundation type — see EditUndoCoordinator.swift's header for the
// same rationale; this coordinator compiles out on non-Darwin for the identical reason.
#if canImport(Darwin)
import Foundation

/// Bridges applied WYSIWYG ops into a window's `UndoManager` with **real redo** — unlike
/// `EditUndoCoordinator` (git-revert LIFO, no redo), every op ships its own inverse (spec §3.2),
/// so undoing an action re-registers the forward op as the next redo/undo step: standard
/// `UndoManager` usage for a redo-capable client.
@MainActor
public final class WYSIWYGUndoCoordinator {
    /// Applies one op against the live canvas — the injected effect side. Typically
    /// `WYSIWYGCanvasController.submit(_:)` wrapped to discard its `OpResult`.
    public typealias Performer = @MainActor (Op) -> Void

    /// The focused window's undo manager. Weak: the window owns it.
    public weak var undoManager: UndoManager?

    private let perform: Performer

    public init(perform: @escaping Performer) {
        self.perform = perform
    }

    /// Registers one applied op on the undo stack. Call from
    /// `WYSIWYGCanvasController.onOpApplied`. No-op when no `undoManager` is attached.
    public func registerApplied(op: Op, inverse: Op) {
        guard let undoManager else { return }
        register(op: inverse, redoOp: op, on: undoManager)
    }

    /// Registers `op` as the action a future `undo()`/`redo()` performs; when it fires, applies
    /// `op` and re-registers `redoOp` as the next step in the opposite direction — this is what
    /// gives `UndoManager` real redo instead of a one-shot revert.
    ///
    /// Explicit group per registration: without one, `registerUndo` throws under
    /// `groupsByEvent = false` ("must begin a group before registering undo") — unit tests and
    /// any other run-loop-free caller set that, since no implicit event group is ever open. Under
    /// the app's default `groupsByEvent = true` this nests harmlessly inside the enclosing event
    /// group, same as `EditUndoCoordinator.registerApplied(_:)`.
    private func register(op: Op, redoOp: Op, on undoManager: UndoManager) {
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { coordinator in
            coordinator.perform(op)
            coordinator.register(op: redoOp, redoOp: op, on: undoManager)
        }
        // Named while the group is still open — the name attaches to the open group; after
        // `endUndoGrouping` there may be no group left to attach to.
        undoManager.setActionName("Edit")
        undoManager.endUndoGrouping()
    }
}
#endif
