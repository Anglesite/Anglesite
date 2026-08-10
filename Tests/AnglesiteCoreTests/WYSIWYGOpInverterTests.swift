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
}
