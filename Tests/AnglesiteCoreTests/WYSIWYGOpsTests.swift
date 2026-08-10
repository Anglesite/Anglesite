import Foundation
import Testing
@testable import AnglesiteCore

@Suite("WYSIWYG ops Codable round-trip")
struct WYSIWYGOpsTests {
    @Test("insertBlock encodes with a flat kind discriminator matching the JS wire shape")
    func insertBlockWireShape() throws {
        let op = Op.insertBlock(
            parentId: rootParentID, slot: "main", index: 0, newId: "b1",
            block: BlockNodeContent(kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0], richText: nil)
        )
        let data = try JSONEncoder().encode(op)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["kind"] as? String == "insertBlock")
        #expect(json?["parentId"] as? String == rootParentID)
        #expect(json?["newId"] as? String == "b1")
        #expect((json?["block"] as? [String: Any])?["id"] == nil, "insertBlock's block payload must omit id, matching TS's Omit<BlockNode, \"id\">")
    }

    @Test("Op round-trips through encode/decode for every kind")
    func allKindsRoundTrip() throws {
        let content = BlockNodeContent(kind: .astro, componentName: "Testimonial", props: ["quote": .string("hi")], slots: [:], sourceSpan: [10, 20], richText: nil)
        let node = BlockNode(id: "b2", kind: .astro, componentName: "Testimonial", props: [:], slots: [:], sourceSpan: [0, 5], richText: nil)
        let ops: [Op] = [
            .insertBlock(parentId: rootParentID, slot: "main", index: 0, newId: "b1", block: content),
            .deleteBlock(parentId: rootParentID, slot: "main", index: 0, blockId: "b2", block: node),
            .moveBlock(blockId: "b1", fromParentId: rootParentID, fromSlot: "main", fromIndex: 0, toParentId: rootParentID, toSlot: "main", toIndex: 1),
            .setProp(blockId: "b1", propName: "title", value: .string("new"), previousValue: .string("old")),
            .editText(blockId: "b1", runs: [RichTextRun(kind: .text, text: "hi")], previousRuns: []),
            .setDesignToken(tokenName: "color.primary", value: "#000", previousValue: "#fff"),
        ]
        for op in ops {
            let data = try JSONEncoder().encode(op)
            let decoded = try JSONDecoder().decode(Op.self, from: data)
            #expect(decoded == op)
        }
    }

    @Test("OpResult applied/rejected round-trip with a flat status discriminator")
    func opResultWireShape() throws {
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: [], blocks: [:])
        let applied = OpResult.applied(model: model)
        let appliedData = try JSONEncoder().encode(applied)
        #expect(try JSONDecoder().decode(OpResult.self, from: appliedData) == applied)

        let rejected = OpResult.rejected(reason: .versionMismatch, message: "stale", freshModel: model)
        let rejectedJSON = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(rejected)) as? [String: Any]
        #expect(rejectedJSON?["status"] as? String == "rejected")
        #expect(rejectedJSON?["reason"] as? String == "version-mismatch")
    }
}
