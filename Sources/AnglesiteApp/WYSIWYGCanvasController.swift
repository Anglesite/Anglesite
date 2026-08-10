import Foundation
import Observation
import AnglesiteCore

/// App-side orchestrator for one mounted WYSIWYG canvas (#1225). Owns the transport and current
/// block selection; menu commands (`FormatCommands`, Edit-menu Duplicate/Delete) and
/// `WYSIWYGUndoCoordinator` talk to this, not to the transport directly.
@MainActor @Observable
final class WYSIWYGCanvasController {
    private(set) var model: BlockModel
    var selectedBlockId: BlockId?
    private let transport: any WYSIWYGHostTransport

    /// Bridges this canvas's applied ops into the window's `UndoManager` for real ⌘Z/⇧⌘Z (#1225,
    /// Task 9). Wired to `onOpApplied` below at `init` time, so callers (`PreviewModel`) don't
    /// need to know about undo at all — they only set `undoCoordinator.undoManager`. `lazy`,
    /// same reason as `SiteWindowModel.contentUndoCoordinator`: its `perform` closure captures
    /// `self`, which isn't available yet inside `init` before all stored properties are set.
    /// `@ObservationIgnored`: not view-relevant state, same as `SiteWindowModel`'s coordinators.
    ///
    /// Awaits `apply(_:)` — not `submit(_:)` — to completion and reports whether the op actually
    /// landed. Using `apply(_:)` (which skips `onOpApplied`) is load-bearing, not a style choice:
    /// `WYSIWYGUndoCoordinator.register` already re-registers the opposite undo/redo direction
    /// itself once this `Performer` returns `true`. If this replayed through `submit(_:)`
    /// instead, `submit`'s own `onOpApplied` firing would *also* call `registerApplied`, double-
    /// registering the same step and corrupting `UndoManager`'s undo/redo stacks. `.applied` vs.
    /// `.rejected` (e.g. a version-mismatch conflict) decides `true`/`false`, so a rejection that
    /// left the document unchanged never re-registers a (now-wrong) next step either.
    @ObservationIgnored
    lazy var undoCoordinator = WYSIWYGUndoCoordinator { [weak self] op in
        guard let self else { return false }
        switch await self.apply(op) {
        case .applied:
            return true
        case .rejected:
            return false
        }
    }

    /// Fires after every successfully applied op, with its inverse — set at `init` time to feed
    /// `undoCoordinator`. Still overridable by tests/other callers that need their own hook,
    /// same seam as before Task 9.
    var onOpApplied: ((Op, Op, BlockModel) -> Void)?

    /// Test-only seam: overrides the `targetVersion` a submitted envelope carries, so a test can
    /// force a version-mismatch rejection without needing two controllers racing a real one.
    var forceTargetVersion: String?

    init(initialModel: BlockModel, transport: any WYSIWYGHostTransport) {
        self.model = initialModel
        self.transport = transport
        onOpApplied = { [weak self] op, inverse, _ in
            self?.undoCoordinator.registerApplied(op: op, inverse: inverse)
        }
    }

    @discardableResult
    func submit(_ op: Op) async -> OpResult {
        let result = await apply(op)
        if case .applied(let newModel) = result {
            onOpApplied?(op, WYSIWYGOpInverter.invert(op), newModel)
        }
        return result
    }

    /// Sends `op` to the transport and updates `model` — the shared core of `submit(_:)`, minus
    /// the `onOpApplied` notification. `submit(_:)` is for ops with a *new* opposite direction to
    /// register (user edits, JS-originated ops via `sendOp(_:)`); `undoCoordinator`'s `Performer`
    /// calls this directly instead, since undo/redo replays must not re-fire `onOpApplied` — see
    /// `undoCoordinator`'s doc comment for why that would double-register.
    private func apply(_ op: Op) async -> OpResult {
        let envelope = OpEnvelope(id: UUID().uuidString, targetVersion: forceTargetVersion ?? model.version, op: op)
        let result = await transport.sendOp(envelope)
        switch result {
        case .applied(let newModel):
            model = newModel
        case .rejected(_, _, let freshModel):
            if let freshModel { model = freshModel }
        }
        return result
    }
}

/// Lets `PreviewView` register `WYSIWYGScriptHandler` directly against the controller instead of
/// reaching into its private `transport` — the handler only ever needs the `WYSIWYGHostTransport`
/// surface, and routing submitted ops through `submit(_:)` keeps `model`/`onOpApplied` in sync
/// with ops that arrive from JS, exactly like ops submitted natively (menu commands, Task 9's
/// undo coordinator).
extension WYSIWYGCanvasController: WYSIWYGHostTransport {
    func sendOp(_ envelope: OpEnvelope) async -> OpResult {
        await submit(envelope.op)
    }

    /// No-op for now: PR1 has no host-initiated push into an already-mounted controller (no
    /// external-edit trigger exists yet — see `StubWYSIWYGHostTransport.onModelUpdate`). `async`
    /// to match `WYSIWYGHostTransport`'s protocol requirement.
    func onModelUpdate(_ listener: @escaping @Sendable (BlockModel) -> Void) async -> @Sendable () -> Void {
        {}
    }
}
