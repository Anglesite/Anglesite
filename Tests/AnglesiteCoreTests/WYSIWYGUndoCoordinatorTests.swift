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
        var performed: [WYSIWYGReversal] = []
        let coordinator = WYSIWYGUndoCoordinator { step in
            performed.append(step)
            return .applied(freshInverse: nil)
        }
        coordinator.undoManager = undoManager

        let op = Op.setDesignToken(tokenName: "t", value: "a", previousValue: "b")
        let inverse = WYSIWYGOpInverter.invert(op)
        coordinator.registerApplied(op: op, inverse: .op(inverse))

        // `undoActionName` is the bare name ("Edit"); the "Undo " prefix only appears on the
        // localized menu title — verified against a real `UndoManager` instance, contra the
        // task brief's sample assertion.
        #expect(undoManager.undoMenuItemTitle == "Undo Edit")
        undoManager.undo()
        await coordinator.pendingPerform?.value
        #expect(performed == [.op(inverse)])
    }

    @Test("undoing then redoing performs the inverse then the original op")
    func redoPerformsOriginal() async {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        var performed: [WYSIWYGReversal] = []
        let coordinator = WYSIWYGUndoCoordinator { step in
            performed.append(step)
            return .applied(freshInverse: nil)
        }
        coordinator.undoManager = undoManager

        let op = Op.setDesignToken(tokenName: "t", value: "a", previousValue: "b")
        coordinator.registerApplied(op: op, inverse: .op(WYSIWYGOpInverter.invert(op)))

        undoManager.undo()
        await coordinator.pendingPerform?.value
        undoManager.redo()
        await coordinator.pendingPerform?.value

        #expect(performed == [.op(WYSIWYGOpInverter.invert(op)), .op(op)])
    }

    @Test("a rejected perform does not leave a stale opposite-direction step on the stack")
    func rejectedPerformDoesNotReRegister() async {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        var performed: [WYSIWYGReversal] = []
        let coordinator = WYSIWYGUndoCoordinator { step in
            performed.append(step)
            return .rejected // simulates a rejected op, e.g. a version-mismatch conflict
        }
        coordinator.undoManager = undoManager

        let op = Op.setDesignToken(tokenName: "t", value: "a", previousValue: "b")
        let inverse = WYSIWYGOpInverter.invert(op)
        coordinator.registerApplied(op: op, inverse: .op(inverse))

        undoManager.undo()
        await coordinator.pendingPerform?.value

        #expect(performed == [.op(inverse)])
        #expect(undoManager.canRedo == false)
    }

    @Test("coalesces consecutive same-session editText commits into a single undo entry (#1225 Finding 5)")
    func coalescesSameSessionEditTextCommits() async {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        var performed: [WYSIWYGReversal] = []
        let coordinator = WYSIWYGUndoCoordinator { step in
            performed.append(step)
            return .applied(freshInverse: nil)
        }
        coordinator.undoManager = undoManager

        // Three debounced commits from the SAME `RichTextEditor.enter()` session: each carries the
        // identical `previousRuns` (the session's fixed baseline, per that type's doc comment) —
        // only `runs` (the live text) advances.
        let baseline = [RichTextRun(kind: .text, text: "Hello")]
        let tick1 = [RichTextRun(kind: .text, text: "Hello,")]
        let tick2 = [RichTextRun(kind: .text, text: "Hello, w")]
        let tick3 = [RichTextRun(kind: .text, text: "Hello, world")]

        let op1 = Op.editText(blockId: "b1", runs: tick1, previousRuns: baseline)
        coordinator.registerApplied(op: op1, inverse: .op(WYSIWYGOpInverter.invert(op1)))
        let op2 = Op.editText(blockId: "b1", runs: tick2, previousRuns: baseline)
        coordinator.registerApplied(op: op2, inverse: .op(WYSIWYGOpInverter.invert(op2)))
        let op3 = Op.editText(blockId: "b1", runs: tick3, previousRuns: baseline)
        coordinator.registerApplied(op: op3, inverse: .op(WYSIWYGOpInverter.invert(op3)))

        // One entry, not three: a single undo restores all the way back to the session's original
        // baseline in one step.
        undoManager.undo()
        await coordinator.pendingPerform?.value
        #expect(performed == [.op(WYSIWYGOpInverter.invert(op3))])
        #expect(undoManager.canUndo == false) // nothing left to undo past the coalesced entry
        #expect(undoManager.canRedo == true)

        undoManager.redo()
        await coordinator.pendingPerform?.value
        #expect(performed == [.op(WYSIWYGOpInverter.invert(op3)), .op(op3)])
    }

    @Test("does not coalesce editText commits from two separate sessions on the same block")
    func doesNotCoalesceAcrossSeparateSessions() async {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        var performed: [WYSIWYGReversal] = []
        let coordinator = WYSIWYGUndoCoordinator { step in
            performed.append(step)
            return .applied(freshInverse: nil)
        }
        coordinator.undoManager = undoManager

        // Session 1: baseline "Hello" -> "Hello, world".
        let sessionOneBaseline = [RichTextRun(kind: .text, text: "Hello")]
        let sessionOneFinal = [RichTextRun(kind: .text, text: "Hello, world")]
        let op1 = Op.editText(blockId: "b1", runs: sessionOneFinal, previousRuns: sessionOneBaseline)
        coordinator.registerApplied(op: op1, inverse: .op(WYSIWYGOpInverter.invert(op1)))

        // Session 2 (a later, separate `enter()`): its baseline is session 1's FINAL text (enter()
        // re-reads the live model) — a genuinely different edit, not a continuation.
        let sessionTwoFinal = [RichTextRun(kind: .text, text: "Hello, world!!")]
        let op2 = Op.editText(blockId: "b1", runs: sessionTwoFinal, previousRuns: sessionOneFinal)
        coordinator.registerApplied(op: op2, inverse: .op(WYSIWYGOpInverter.invert(op2)))

        // Two entries, not one: undoing once only reverts session 2, leaving session 1's edit
        // still on the stack and still recoverable.
        undoManager.undo()
        await coordinator.pendingPerform?.value
        #expect(performed == [.op(WYSIWYGOpInverter.invert(op2))])
        #expect(undoManager.canUndo == true)

        undoManager.undo()
        await coordinator.pendingPerform?.value
        #expect(performed == [.op(WYSIWYGOpInverter.invert(op2)), .op(WYSIWYGOpInverter.invert(op1))])
    }

    @Test("does not coalesce editText commits for two different blocks")
    func doesNotCoalesceAcrossDifferentBlocks() async {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        var performed: [WYSIWYGReversal] = []
        let coordinator = WYSIWYGUndoCoordinator { step in
            performed.append(step)
            return .applied(freshInverse: nil)
        }
        coordinator.undoManager = undoManager

        let baseline = [RichTextRun(kind: .text, text: "Hi")]
        let opA = Op.editText(blockId: "a", runs: [RichTextRun(kind: .text, text: "Hi there")], previousRuns: baseline)
        coordinator.registerApplied(op: opA, inverse: .op(WYSIWYGOpInverter.invert(opA)))
        let opB = Op.editText(blockId: "b", runs: [RichTextRun(kind: .text, text: "Hi you")], previousRuns: baseline)
        coordinator.registerApplied(op: opB, inverse: .op(WYSIWYGOpInverter.invert(opB)))

        undoManager.undo()
        await coordinator.pendingPerform?.value
        #expect(performed == [.op(WYSIWYGOpInverter.invert(opB))])
        #expect(undoManager.canUndo == true) // block "a"'s edit is still a separate entry
    }

    @Test("a coalesced entry does not resurrect after an intervening undo/redo")
    func coalescingStopsAfterUndoRedo() async {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        var performed: [WYSIWYGReversal] = []
        let coordinator = WYSIWYGUndoCoordinator { step in
            performed.append(step)
            return .applied(freshInverse: nil)
        }
        coordinator.undoManager = undoManager

        let baseline = [RichTextRun(kind: .text, text: "Hi")]
        let tick1 = [RichTextRun(kind: .text, text: "Hi!")]
        let op1 = Op.editText(blockId: "b1", runs: tick1, previousRuns: baseline)
        coordinator.registerApplied(op: op1, inverse: .op(WYSIWYGOpInverter.invert(op1)))

        undoManager.undo()
        await coordinator.pendingPerform?.value
        undoManager.redo()
        await coordinator.pendingPerform?.value

        // A further same-block, same-baseline commit arriving after the undo/redo round trip must
        // NOT coalesce into the entry the redo just re-registered — it starts a fresh entry.
        let tick2 = [RichTextRun(kind: .text, text: "Hi!!")]
        let op2 = Op.editText(blockId: "b1", runs: tick2, previousRuns: baseline)
        coordinator.registerApplied(op: op2, inverse: .op(WYSIWYGOpInverter.invert(op2)))

        undoManager.undo()
        await coordinator.pendingPerform?.value
        #expect(performed.last == .op(WYSIWYGOpInverter.invert(op2)))
        #expect(undoManager.canUndo == true) // op1's redo-registered entry is still there beneath it
    }

    @Test("undoing a step whose registered reversal is a WireInverse replays it verbatim (#1602 item 2)")
    func undoReplaysWireInverseVerbatim() async {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        var performed: [WYSIWYGReversal] = []
        let coordinator = WYSIWYGUndoCoordinator { step in
            performed.append(step)
            return .applied(freshInverse: nil)
        }
        coordinator.undoManager = undoManager

        let op = Op.deleteBlock(
            parentId: rootParentID, slot: "main", index: 0, blockId: "n5",
            block: BlockNode(id: "n5", kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0]))
        let wireInverse = WireInverse(
            op: "insertBlock",
            component: .object(["parentId": .string(rootParentID), "index": .int(0), "node": .object(["kind": .string("raw"), "markup": .string("<p>hi</p>")])]))
        coordinator.registerApplied(op: op, inverse: .wire(wireInverse))

        undoManager.undo()
        await coordinator.pendingPerform?.value

        #expect(performed == [.wire(wireInverse)])
    }

    @Test("a freshInverse reported by perform replaces the optimistically-registered next step (#1602 item 2)")
    func freshInverseCorrectsNextRegisteredStep() async {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        var performed: [WYSIWYGReversal] = []
        let staleGuess = WireInverse(op: "deleteBlock", component: .object(["nodeId": .string("stale-n5")]))
        let freshAnswer = WireInverse(op: "deleteBlock", component: .object(["nodeId": .string("real-n7")]))
        let coordinator = WYSIWYGUndoCoordinator { step in
            performed.append(step)
            // The very first perform (undoing the original insert) reports back the server's real
            // post-write inverse, correcting the redo step the registration guessed at.
            if performed.count == 1 {
                return .applied(freshInverse: .wire(freshAnswer))
            }
            return .applied(freshInverse: nil)
        }
        coordinator.undoManager = undoManager

        let op = Op.insertBlock(
            parentId: rootParentID, slot: "main", index: 0, newId: "n5",
            block: BlockNodeContent(kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0]))
        coordinator.registerApplied(op: op, inverse: .wire(staleGuess))

        undoManager.undo() // performs .wire(staleGuess); its reply corrects the next (redo) step
        await coordinator.pendingPerform?.value
        undoManager.redo() // must perform the CORRECTED reversal, not the original `op`
        await coordinator.pendingPerform?.value

        #expect(performed == [.wire(staleGuess), .wire(freshAnswer)])
    }
}
