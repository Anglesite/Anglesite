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
