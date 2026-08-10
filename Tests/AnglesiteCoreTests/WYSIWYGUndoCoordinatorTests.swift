import Testing
import Foundation
@testable import AnglesiteCore

@Suite("WYSIWYGUndoCoordinator")
@MainActor
struct WYSIWYGUndoCoordinatorTests {
    @Test("registering an applied op sets a truthful action name and undoing calls perform with the inverse")
    func undoCallsPerformWithInverse() {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        var performed: [Op] = []
        let coordinator = WYSIWYGUndoCoordinator { op in performed.append(op) }
        coordinator.undoManager = undoManager

        let op = Op.setDesignToken(tokenName: "t", value: "a", previousValue: "b")
        let inverse = WYSIWYGOpInverter.invert(op)
        coordinator.registerApplied(op: op, inverse: inverse)

        // `undoActionName` is the bare name ("Edit"); the "Undo " prefix only appears on the
        // localized menu title — verified against a real `UndoManager` instance, contra the
        // task brief's sample assertion.
        #expect(undoManager.undoMenuItemTitle == "Undo Edit")
        undoManager.undo()
        #expect(performed == [inverse])
    }

    @Test("undoing then redoing performs the inverse then the original op")
    func redoPerformsOriginal() {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        var performed: [Op] = []
        let coordinator = WYSIWYGUndoCoordinator { op in performed.append(op) }
        coordinator.undoManager = undoManager

        let op = Op.setDesignToken(tokenName: "t", value: "a", previousValue: "b")
        coordinator.registerApplied(op: op, inverse: WYSIWYGOpInverter.invert(op))

        undoManager.undo()
        undoManager.redo()

        #expect(performed == [WYSIWYGOpInverter.invert(op), op])
    }
}
