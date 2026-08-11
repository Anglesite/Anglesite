import Testing
@testable import AnglesiteCore

@Suite("StubWYSIWYGHostTransport")
struct StubWYSIWYGHostTransportTests {
    static func emptyModel() -> BlockModel {
        BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: [], blocks: [:])
    }

    @Test("rejects an op targeting a stale version")
    func rejectsStaleVersion() async {
        let transport = StubWYSIWYGHostTransport(model: Self.emptyModel())
        let op = Op.insertBlock(parentId: rootParentID, slot: "main", index: 0, newId: "b1", block: BlockNodeContent(kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0]))
        let result = await transport.sendOp(OpEnvelope(id: "1", targetVersion: "wrong-version", op: op))
        guard case .rejected(let reason, _, let freshModel) = result else {
            Issue.record("expected .rejected, got \(result)")
            return
        }
        #expect(reason == .versionMismatch)
        #expect(freshModel?.version == "v0")
    }

    @Test("applies insertBlock at the page root and bumps the version")
    func appliesInsertAtRoot() async {
        let transport = StubWYSIWYGHostTransport(model: Self.emptyModel())
        let op = Op.insertBlock(parentId: rootParentID, slot: "main", index: 0, newId: "b1", block: BlockNodeContent(kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0]))
        let result = await transport.sendOp(OpEnvelope(id: "1", targetVersion: "v0", op: op))
        guard case .applied(let model) = result else {
            Issue.record("expected .applied, got \(result)")
            return
        }
        #expect(model.rootIds == ["b1"])
        #expect(model.blocks["b1"]?.componentName == "p")
        #expect(model.version != "v0")
    }

    @Test("deleteBlock removes the block and its root entry")
    func appliesDelete() async {
        let inserted = BlockNode(id: "b1", kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0])
        let seeded = BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: ["b1"], blocks: ["b1": inserted])
        let transport = StubWYSIWYGHostTransport(model: seeded)
        let op = Op.deleteBlock(parentId: rootParentID, slot: "main", index: 0, blockId: "b1", block: inserted)
        let result = await transport.sendOp(OpEnvelope(id: "1", targetVersion: "v0", op: op))
        guard case .applied(let model) = result else {
            Issue.record("expected .applied, got \(result)")
            return
        }
        #expect(model.rootIds.isEmpty)
        #expect(model.blocks["b1"] == nil)
    }

    @Test("deleteBlock targeting an unknown block is rejected as invalid-target")
    func rejectsInvalidTarget() async {
        let transport = StubWYSIWYGHostTransport(model: Self.emptyModel())
        let ghost = BlockNode(id: "ghost", kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0])
        let op = Op.deleteBlock(parentId: rootParentID, slot: "main", index: 0, blockId: "ghost", block: ghost)
        let result = await transport.sendOp(OpEnvelope(id: "1", targetVersion: "v0", op: op))
        guard case .rejected(let reason, _, _) = result else {
            Issue.record("expected .rejected, got \(result)")
            return
        }
        #expect(reason == .invalidTarget)
    }
}
