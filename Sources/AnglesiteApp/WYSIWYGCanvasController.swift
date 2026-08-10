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

    /// Fires after every successfully applied op, with its inverse — `WYSIWYGUndoCoordinator`
    /// (Task 9) registers one `NSUndoManager` action per firing.
    var onOpApplied: ((Op, Op, BlockModel) -> Void)?

    /// Test-only seam: overrides the `targetVersion` a submitted envelope carries, so a test can
    /// force a version-mismatch rejection without needing two controllers racing a real one.
    var forceTargetVersion: String?

    init(initialModel: BlockModel, transport: any WYSIWYGHostTransport) {
        self.model = initialModel
        self.transport = transport
    }

    @discardableResult
    func submit(_ op: Op) async -> OpResult {
        let envelope = OpEnvelope(id: UUID().uuidString, targetVersion: forceTargetVersion ?? model.version, op: op)
        let result = await transport.sendOp(envelope)
        switch result {
        case .applied(let newModel):
            model = newModel
            onOpApplied?(op, WYSIWYGOpInverter.invert(op), newModel)
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
