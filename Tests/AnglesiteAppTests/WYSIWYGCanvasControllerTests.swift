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

    @Test("mountScript(for:displayNames:) builds a mount(...) call carrying the model's and display names' exact JSON")
    func mountScriptBuildsCall() throws {
        let node = BlockNode(id: "b1", kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 5])
        let model = BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: ["b1"], blocks: ["b1": node])
        let displayNames = ["p": "Paragraph"]

        let script = WYSIWYGCanvasController.mountScript(for: model, displayNames: displayNames)

        let prefix = "window.__anglesiteWysiwygMount?.mount("
        #expect(script.hasPrefix(prefix))
        #expect(script.hasSuffix(")"))
        // `JSONEncoder`'s key order is not guaranteed stable across separate `encode()` calls of an
        // equivalent value (confirmed on this toolchain: five back-to-back encodes of the identical
        // `BlockNode` produced five different key orderings) — so, same as the pre-Task-7 version of
        // this test, round-trip both JSON blobs back through their types instead of string-comparing
        // against a freshly-encoded reference. `mount.ts`'s wrapper is the only place a bare ", "
        // (comma-space) can appear in this string — the default `JSONEncoder` output has no
        // whitespace around any of its own commas — so splitting on it isolates the two arguments.
        let inner = script.dropFirst(prefix.count).dropLast()
        let separator = try #require(inner.range(of: ", "), "expected a ', ' separator between the two JSON arguments")
        let modelJSON = String(inner[inner.startIndex..<separator.lowerBound])
        let namesJSON = String(inner[separator.upperBound...])
        let decodedModel = try JSONDecoder().decode(BlockModel.self, from: Data(modelJSON.utf8))
        let decodedNames = try JSONDecoder().decode([String: String].self, from: Data(namesJSON.utf8))
        #expect(decodedModel == model)
        #expect(decodedNames == displayNames)
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
    @Test("applying an op re-runs quality gates when a context is set")
    func appliedOpTriggersQualityGates() async {
        let node = BlockNode(id: "img1", kind: .astro, componentName: "Image", props: ["src": .string("/photo.jpg")], slots: [:], sourceSpan: [0, 0])
        let initial = BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: ["img1"], blocks: ["img1": node])
        let transport = StubWYSIWYGHostTransport(model: initial)
        let controller = WYSIWYGCanvasController(initialModel: initial, transport: transport)
        controller.qualityGateContext = GateContext(resolvedTokens: [:], internalRoutes: [], assetRoot: URL(fileURLWithPath: "/tmp"))

        _ = await controller.submit(.setDesignToken(tokenName: "t", value: "a", previousValue: "b"))

        #expect(controller.lastQualityGateResult?.findings.contains { $0.category == .altText } == true)
    }

    @Test("undoing an applied op re-runs quality gates against the reverted model")
    func undoReTriggersQualityGates() async {
        // h2 followed by h4 — a heading skip HeadingOrderGate flags, with a `level` prop so it
        // carries a one-tap fix. Applying the fix clears the chip; undoing has to bring it back.
        let h2 = BlockNode(id: "h2", kind: .astro, componentName: "Heading", props: ["level": .number(2)], slots: [:], sourceSpan: [0, 0])
        let h4 = BlockNode(id: "h4", kind: .astro, componentName: "Heading", props: ["level": .number(4)], slots: [:], sourceSpan: [1, 2])
        let initial = BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: ["h2", "h4"], blocks: ["h2": h2, "h4": h4])
        let controller = WYSIWYGCanvasController(initialModel: initial, transport: StubWYSIWYGHostTransport(model: initial))
        controller.qualityGateContext = GateContext(resolvedTokens: [:], internalRoutes: [], assetRoot: URL(fileURLWithPath: "/tmp"))
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false // no run loop in a test; see WYSIWYGUndoCoordinator's doc
        controller.undoCoordinator.undoManager = undoManager

        _ = await controller.submit(.setProp(blockId: "h4", propName: "level", value: .number(3), previousValue: .number(4)))
        #expect(controller.lastQualityGateResult?.findings.contains { $0.category == .headingOrder } == false)

        undoManager.undo()
        await controller.undoCoordinator.pendingPerform?.value

        // The skip is back in the model, so its chip has to be back too — the undo path bypasses
        // the applied-op listener list, which is exactly where the gates used to be wired.
        #expect(controller.model.blocks["h4"]?.props["level"] == .number(4))
        #expect(controller.lastQualityGateResult?.findings.contains { $0.category == .headingOrder } == true)
    }

    @Test("a nil qualityGateContext means quality gates never run")
    func noContextMeansNoAnalysis() async {
        let initial = BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: [], blocks: [:])
        let transport = StubWYSIWYGHostTransport(model: initial)
        let controller = WYSIWYGCanvasController(initialModel: initial, transport: transport)

        _ = await controller.submit(.setDesignToken(tokenName: "t", value: "a", previousValue: "b"))

        #expect(controller.lastQualityGateResult == nil)
    }

    @Test("pushQualityFindingsScript(for:) builds a _handleQualityFindings call carrying the findings' exact JSON encoding")
    func pushQualityFindingsScriptBuildsCall() throws {
        let finding = Finding(blockId: "img1", category: .imageWeight, severity: .warning, message: "big")

        let script = WYSIWYGCanvasController.pushQualityFindingsScript(for: [finding])

        #expect(script.hasPrefix("window.__anglesiteWysiwygHost?._handleQualityFindings?.("))
        #expect(script.hasSuffix(")"))
        let jsonStart = script.index(script.startIndex, offsetBy: "window.__anglesiteWysiwygHost?._handleQualityFindings?.(".count)
        let json = String(script[jsonStart..<script.index(before: script.endIndex)])
        let decoded = try JSONDecoder().decode([Finding].self, from: Data(json.utf8))
        #expect(decoded == [finding])
    }
}

private extension OpResult {
    var isApplied: Bool { if case .applied = self { true } else { false } }
}
