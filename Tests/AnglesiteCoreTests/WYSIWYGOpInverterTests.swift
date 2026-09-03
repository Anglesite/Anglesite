import Testing
@testable import AnglesiteCore

@Suite("WYSIWYG op inversion")
struct WYSIWYGOpInverterTests {
    @Test("insertBlock inverts to deleteBlock at the same position")
    func insertInverts() {
        let content = BlockNodeContent(kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0])
        let op = Op.insertBlock(parentId: rootParentID, slot: "main", index: 2, newId: "b9", block: content)
        let inverse = WYSIWYGOpInverter.invert(op)
        #expect(inverse == .deleteBlock(
            parentId: rootParentID, slot: "main", index: 2, blockId: "b9",
            block: BlockNode(id: "b9", kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0])))
    }

    @Test("inverting an op twice returns an op equivalent to the original")
    func doubleInversionRoundTrips() {
        let op = Op.setProp(blockId: "b1", propName: "title", value: .string("new"), previousValue: .string("old"))
        #expect(WYSIWYGOpInverter.invert(WYSIWYGOpInverter.invert(op)) == op)
    }

    @Test("moveBlock inversion swaps from/to")
    func moveInverts() {
        let op = Op.moveBlock(blockId: "b1", fromParentId: rootParentID, fromSlot: "main", fromIndex: 0, toParentId: rootParentID, toSlot: "main", toIndex: 2)
        let inverse = WYSIWYGOpInverter.invert(op)
        #expect(inverse == .moveBlock(blockId: "b1", fromParentId: rootParentID, fromSlot: "main", fromIndex: 2, toParentId: rootParentID, toSlot: "main", toIndex: 0))
    }

    @Test("editText inversion swaps runs/previousRuns")
    func editTextInverts() {
        let runs = [RichTextRun(kind: .text, text: "new")]
        let previousRuns = [RichTextRun(kind: .text, text: "old")]
        let op = Op.editText(blockId: "b1", runs: runs, previousRuns: previousRuns)
        let inverse = WYSIWYGOpInverter.invert(op)
        #expect(inverse == .editText(blockId: "b1", runs: previousRuns, previousRuns: runs))
    }

    @Test("setDesignToken inversion swaps value/previousValue")
    func setDesignTokenInverts() {
        let op = Op.setDesignToken(tokenName: "color-primary", value: "#FF0000", previousValue: "#00FF00")
        let inverse = WYSIWYGOpInverter.invert(op)
        #expect(inverse == .setDesignToken(tokenName: "color-primary", value: "#00FF00", previousValue: "#FF0000"))
    }

    @Test("insertBlock/deleteBlock round-trip preserves richText")
    func richTextPreservedInRoundTrip() {
        let richText = [RichTextRun(kind: .strong, text: "bold"), RichTextRun(kind: .em, text: "italic")]
        let content = BlockNodeContent(kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0], richText: richText)
        let insertOp = Op.insertBlock(parentId: rootParentID, slot: "main", index: 2, newId: "b9", block: content)

        let deleteOp = WYSIWYGOpInverter.invert(insertOp)
        if case .deleteBlock(_, _, _, _, let block) = deleteOp {
            #expect(block.richText == richText)
        } else {
            #expect(Bool(false), "Expected deleteBlock but got \(deleteOp)")
        }

        let roundTrip = WYSIWYGOpInverter.invert(deleteOp)
        if case .insertBlock(_, _, _, _, let roundTripContent) = roundTrip {
            #expect(roundTripContent.richText == richText)
        } else {
            #expect(Bool(false), "Expected insertBlock but got \(roundTrip)")
        }
    }

    @Test("insertBlock/deleteBlock round-trip preserves manifestName")
    func manifestNamePreservedInRoundTrip() {
        let content = BlockNodeContent(kind: .astro, componentName: "Hcard", props: [:], slots: [:], sourceSpan: [0, 0], manifestName: "H-Card")
        let insertOp = Op.insertBlock(parentId: rootParentID, slot: "main", index: 0, newId: "b9", block: content)

        let deleteOp = WYSIWYGOpInverter.invert(insertOp)
        guard case .deleteBlock(_, _, _, _, let block) = deleteOp else {
            Issue.record("Expected deleteBlock but got \(deleteOp)"); return
        }
        #expect(block.manifestName == "H-Card")

        let roundTrip = WYSIWYGOpInverter.invert(deleteOp)
        guard case .insertBlock(_, _, _, _, let roundTripContent) = roundTrip else {
            Issue.record("Expected insertBlock but got \(roundTrip)"); return
        }
        #expect(roundTripContent.manifestName == "H-Card")
    }
}
