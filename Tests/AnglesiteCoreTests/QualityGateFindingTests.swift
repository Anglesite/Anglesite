import Foundation
import Testing
@testable import AnglesiteCore

@Suite("Finding id derivation")
struct FindingTests {
    @Test("id is blockId::category without a discriminator")
    func idWithoutDiscriminator() {
        let finding = Finding(blockId: "b1", category: .altText, severity: .warning, message: "m")
        #expect(finding.id == "b1::altText")
    }

    @Test("id appends the discriminator when one block can carry multiple findings in a category")
    func idWithDiscriminator() {
        let finding = Finding(blockId: "b1", category: .linkIntegrity, discriminator: "run.0", severity: .warning, message: "m")
        #expect(finding.id == "b1::linkIntegrity::run.0")
    }
}

@Suite("BlockModel.orderedBlocks")
struct BlockModelTraversalTests {
    @Test("visits root blocks in rootIds order, then each block's slot children before its siblings")
    func documentOrder() {
        let child = BlockNode(id: "child", kind: .text, componentName: "span", props: [:], slots: [:], sourceSpan: [0, 0])
        let container = BlockNode(id: "container", kind: .astro, componentName: "Box", props: [:], slots: ["main": ["child"]], sourceSpan: [0, 0])
        let sibling = BlockNode(id: "sibling", kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0])
        let model = BlockModel(
            path: "src/pages/index.astro", version: "v1", rootIds: ["container", "sibling"],
            blocks: ["container": container, "child": child, "sibling": sibling])

        #expect(model.orderedBlocks.map(\.id) == ["container", "child", "sibling"])
    }

    @Test("skips a block id that isn't in the blocks dictionary instead of crashing")
    func missingBlockIsSkipped() {
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: ["ghost"], blocks: [:])
        #expect(model.orderedBlocks.isEmpty)
    }
}
