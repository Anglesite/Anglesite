import Testing
@testable import AnglesiteAppCore
@testable import AnglesiteCore

@Suite("WYSIWYGCanvasController")
@MainActor
struct WYSIWYGCanvasControllerTests {
    @Test("submit applies an op, updates model, and reports the applied op + inverse")
    func submitAppliesAndReportsInverse() async {
        let initial = BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: [], blocks: [:])
        let transport = StubWYSIWYGHostTransport(model: initial)
        let controller = WYSIWYGCanvasController(initialModel: initial, transport: transport)
        var reported: (op: Op, inverse: Op, model: BlockModel)?
        controller.onOpApplied = { op, inverse, model in reported = (op, inverse, model) }

        let op = Op.insertBlock(parentId: rootParentID, slot: "main", index: 0, newId: "b1", block: BlockNodeContent(kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0]))
        let result = await controller.submit(op)

        #expect(result.isApplied)
        #expect(controller.model.rootIds == ["b1"])
        #expect(reported?.op == op)
        #expect(reported?.inverse == WYSIWYGOpInverter.invert(op))
    }

    @Test("submit adopts the fresh model on a version-mismatch rejection without calling onOpApplied")
    func submitAdoptsFreshModelOnRejection() async {
        let initial = BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: [], blocks: [:])
        let transport = StubWYSIWYGHostTransport(model: initial)
        let controller = WYSIWYGCanvasController(initialModel: initial, transport: transport)
        controller.forceTargetVersion = "stale" // test-only seam, see Step 3
        var applied = false
        controller.onOpApplied = { _, _, _ in applied = true }

        let op = Op.setDesignToken(tokenName: "t", value: "a", previousValue: "b")
        let result = await controller.submit(op)

        guard case .rejected = result else {
            Issue.record("expected .rejected, got \(result)")
            return
        }
        #expect(applied == false)
    }

    @Test("duplicateSelectedBlock submits an insertBlock op for a copy of the selected block")
    func duplicateSelectedBlockSubmitsInsert() async {
        let existing = BlockNode(id: "b1", kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0])
        let initial = BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: ["b1"], blocks: ["b1": existing])
        let transport = StubWYSIWYGHostTransport(model: initial)
        let controller = WYSIWYGCanvasController(initialModel: initial, transport: transport)
        controller.selectedBlockId = "b1"

        await controller.duplicateSelectedBlock()

        #expect(controller.model.rootIds.count == 2)
    }

    @Test("deleteSelectedBlock submits a deleteBlock op and clears the selection")
    func deleteSelectedBlockSubmitsDelete() async {
        let existing = BlockNode(id: "b1", kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0])
        let initial = BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: ["b1"], blocks: ["b1": existing])
        let transport = StubWYSIWYGHostTransport(model: initial)
        let controller = WYSIWYGCanvasController(initialModel: initial, transport: transport)
        controller.selectedBlockId = "b1"

        await controller.deleteSelectedBlock()

        #expect(controller.model.rootIds.isEmpty)
        #expect(controller.selectedBlockId == nil)
    }
}

private extension OpResult {
    var isApplied: Bool { if case .applied = self { true } else { false } }
}
