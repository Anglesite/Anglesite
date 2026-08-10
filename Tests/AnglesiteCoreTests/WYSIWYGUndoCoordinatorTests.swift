import Testing
import Foundation
@testable import AnglesiteCore

@Suite("WYSIWYGUndoCoordinator")
@MainActor
struct WYSIWYGUndoCoordinatorTests {
    @Test("registering an applied op sets a truthful action name and undoing calls perform with the inverse")
    func undoCallsPerformWithInverse() async {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        var performed: [Op] = []
        let coordinator = WYSIWYGUndoCoordinator { op in
            performed.append(op)
            return true
        }
        coordinator.undoManager = undoManager

        let op = Op.setDesignToken(tokenName: "t", value: "a", previousValue: "b")
        let inverse = WYSIWYGOpInverter.invert(op)
        coordinator.registerApplied(op: op, inverse: inverse)

        // `undoActionName` is the bare name ("Edit"); the "Undo " prefix only appears on the
        // localized menu title — verified against a real `UndoManager` instance, contra the
        // task brief's sample assertion.
        #expect(undoManager.undoMenuItemTitle == "Undo Edit")
        undoManager.undo()
        await coordinator.pendingPerform?.value
        #expect(performed == [inverse])
    }

    @Test("undoing then redoing performs the inverse then the original op")
    func redoPerformsOriginal() async {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        var performed: [Op] = []
        let coordinator = WYSIWYGUndoCoordinator { op in
            performed.append(op)
            return true
        }
        coordinator.undoManager = undoManager

        let op = Op.setDesignToken(tokenName: "t", value: "a", previousValue: "b")
        coordinator.registerApplied(op: op, inverse: WYSIWYGOpInverter.invert(op))

        undoManager.undo()
        await coordinator.pendingPerform?.value
        undoManager.redo()
        await coordinator.pendingPerform?.value

        #expect(performed == [WYSIWYGOpInverter.invert(op), op])
    }

    @Test("a rejected perform does not leave a stale opposite-direction step on the stack")
    func rejectedPerformDoesNotReRegister() async {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        var performed: [Op] = []
        let coordinator = WYSIWYGUndoCoordinator { op in
            performed.append(op)
            return false // simulates a rejected op, e.g. a version-mismatch conflict
        }
        coordinator.undoManager = undoManager

        let op = Op.setDesignToken(tokenName: "t", value: "a", previousValue: "b")
        let inverse = WYSIWYGOpInverter.invert(op)
        coordinator.registerApplied(op: op, inverse: inverse)

        undoManager.undo()
        await coordinator.pendingPerform?.value

        #expect(performed == [inverse])
        #expect(undoManager.canRedo == false)
    }
}
