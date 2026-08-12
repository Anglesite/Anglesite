import Foundation
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
        controller.addOpAppliedListener { op, inverse, model in reported = (op, inverse, model) }

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
        controller.addOpAppliedListener { _, _, _ in applied = true }

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

    @Test("duplicateSelectedBlock no-ops for a nested (non-root) block instead of misplacing a copy at the root")
    func duplicateSelectedBlockNoOpsForNestedBlock() async {
        let nested = BlockNode(id: "b2", kind: .text, componentName: "span", props: [:], slots: [:], sourceSpan: [10, 20])
        let container = BlockNode(id: "b1", kind: .astro, componentName: "Container", props: [:], slots: ["main": ["b2"]], sourceSpan: [0, 30])
        let initial = BlockModel(
            path: "src/pages/index.astro", version: "v0", rootIds: ["b1"],
            blocks: ["b1": container, "b2": nested])
        let transport = StubWYSIWYGHostTransport(model: initial)
        let controller = WYSIWYGCanvasController(initialModel: initial, transport: transport)
        controller.selectedBlockId = "b2" // exists in model.blocks, but not in model.rootIds

        await controller.duplicateSelectedBlock()

        #expect(controller.model == initial)
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

    @Test("sendOp forwards the envelope's own targetVersion verbatim instead of re-deriving from model.version")
    func sendOpForwardsRealTargetVersion() async {
        let initial = BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: [], blocks: [:])
        let transport = StubWYSIWYGHostTransport(model: initial)
        let controller = WYSIWYGCanvasController(initialModel: initial, transport: transport)
        // Simulate the model having moved on natively (e.g. a menu-driven edit) since the JS
        // engine last synced — its stale envelope should be rejected as a version mismatch, not
        // silently re-targeted against the controller's current `model.version` and accepted.
        await controller.submit(.setDesignToken(tokenName: "t", value: "a", previousValue: "b"))
        let currentVersion = controller.model.version
        #expect(currentVersion != "v0")

        let staleOp = Op.insertBlock(parentId: rootParentID, slot: "main", index: 0, newId: "b1", block: BlockNodeContent(kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0]))
        let staleEnvelope = OpEnvelope(id: "req-1", targetVersion: "v0", op: staleOp) // stale: model has since moved to `currentVersion`
        let result = await controller.sendOp(staleEnvelope)

        guard case .rejected(let reason, _, _) = result else {
            Issue.record("expected .rejected for a stale targetVersion, got \(result)")
            return
        }
        #expect(reason == .versionMismatch)
        #expect(controller.model.rootIds.isEmpty) // the stale insert must not have landed

        // A correctly-versioned envelope still applies and fires onOpApplied with the real op.
        var reported: (op: Op, inverse: Op)?
        controller.addOpAppliedListener { op, inverse, _ in reported = (op, inverse) }
        let freshEnvelope = OpEnvelope(id: "req-2", targetVersion: controller.model.version, op: staleOp)
        let freshResult = await controller.sendOp(freshEnvelope)

        #expect(freshResult.isApplied)
        #expect(controller.model.rootIds == ["b1"])
        #expect(reported?.op == staleOp)
        #expect(reported?.inverse == WYSIWYGOpInverter.invert(staleOp))
    }

    @Test("mountScript(for:) builds a mount(...) call carrying the model's exact JSON encoding")
    func mountScriptBuildsCall() throws {
        let node = BlockNode(id: "b1", kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 5])
        let model = BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: ["b1"], blocks: ["b1": node])

        let script = WYSIWYGCanvasController.mountScript(for: model)

        #expect(script.hasPrefix("window.__anglesiteWysiwygMount?.mount("))
        #expect(script.hasSuffix(")"))
        // Round-trip the embedded JSON back through BlockModel to prove it's a faithful encoding,
        // not just a prefix/suffix match on the wrapper string.
        let jsonStart = script.index(script.startIndex, offsetBy: "window.__anglesiteWysiwygMount?.mount(".count)
        let json = String(script[jsonStart..<script.index(before: script.endIndex)])
        let decoded = try JSONDecoder().decode(BlockModel.self, from: Data(json.utf8))
        #expect(decoded == model)
    }

    @Test("unmountScript is the literal unmount() call")
    func unmountScriptLiteral() {
        #expect(WYSIWYGCanvasController.unmountScript == "window.__anglesiteWysiwygMount?.unmount?.()")
    }

    @Test("insertBlock inserts the palette entry's component at the page root")
    func insertBlockFromPalette() async {
        let initial = BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: [], blocks: [:])
        let controller = WYSIWYGCanvasController(initialModel: initial, transport: StubWYSIWYGHostTransport(model: initial))
        let entry = WYSIWYGBlockPaletteEntry(id: UUID(), displayName: "Paragraph", kind: .text, componentName: "p")

        await controller.insertBlock(entry)

        #expect(controller.model.rootIds.count == 1)
        let insertedId = controller.model.rootIds[0]
        #expect(controller.model.blocks[insertedId]?.componentName == "p")
    }
}

private extension OpResult {
    var isApplied: Bool { if case .applied = self { true } else { false } }
}
