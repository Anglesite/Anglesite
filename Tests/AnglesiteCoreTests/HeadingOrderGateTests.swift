import Foundation
import Testing
@testable import AnglesiteCore

@Suite("HeadingOrderGate")
struct HeadingOrderGateTests {
    private var emptyContext: GateContext { GateContext(resolvedTokens: [:], internalRoutes: [], assetRoot: URL(fileURLWithPath: "/tmp")) }

    @Test("flags a skip from h2 to h4 in document order")
    func flagsSkip() throws {
        let h2 = BlockNode(id: "h2block", kind: .text, componentName: "h2", props: [:], slots: [:], sourceSpan: [0, 0])
        let h4 = BlockNode(id: "h4block", kind: .text, componentName: "h4", props: [:], slots: [:], sourceSpan: [0, 0])
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: ["h2block", "h4block"], blocks: ["h2block": h2, "h4block": h4])

        let findings = try HeadingOrderGate.analyze(model: model, context: emptyContext)

        #expect(findings.map(\.id) == ["h4block::headingOrder"])
    }

    @Test("does not flag consecutive levels")
    func doesNotFlagConsecutive() throws {
        let h2 = BlockNode(id: "h2block", kind: .text, componentName: "h2", props: [:], slots: [:], sourceSpan: [0, 0])
        let h3 = BlockNode(id: "h3block", kind: .text, componentName: "h3", props: [:], slots: [:], sourceSpan: [0, 0])
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: ["h2block", "h3block"], blocks: ["h2block": h2, "h3block": h3])

        let findings = try HeadingOrderGate.analyze(model: model, context: emptyContext)

        #expect(findings.isEmpty)
    }

    @Test("offers a setProp fix when the skipped heading carries a level prop")
    func offersFixForLevelProp() throws {
        let h2 = BlockNode(id: "h2block", kind: .astro, componentName: "Heading", props: ["level": .number(2)], slots: [:], sourceSpan: [0, 0])
        let h4 = BlockNode(id: "h4block", kind: .astro, componentName: "Heading", props: ["level": .number(4)], slots: [:], sourceSpan: [0, 0])
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: ["h2block", "h4block"], blocks: ["h2block": h2, "h4block": h4])

        let findings = try HeadingOrderGate.analyze(model: model, context: emptyContext)

        #expect(findings.first?.fix == .setProp(blockId: "h4block", propName: "level", value: .number(3), previousValue: .number(4)))
    }

    @Test("offers no fix when the skipped heading has no level prop to rewrite")
    func noFixForTagEncodedLevel() throws {
        let h2 = BlockNode(id: "h2block", kind: .text, componentName: "h2", props: [:], slots: [:], sourceSpan: [0, 0])
        let h4 = BlockNode(id: "h4block", kind: .text, componentName: "h4", props: [:], slots: [:], sourceSpan: [0, 0])
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: ["h2block", "h4block"], blocks: ["h2block": h2, "h4block": h4])

        let findings = try HeadingOrderGate.analyze(model: model, context: emptyContext)

        #expect(findings.first?.fix == nil)
    }
}
