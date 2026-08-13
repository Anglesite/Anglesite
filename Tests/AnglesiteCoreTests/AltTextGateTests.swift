import Foundation
import Testing
@testable import AnglesiteCore

@Suite("AltTextGate")
struct AltTextGateTests {
    private var emptyContext: GateContext { GateContext(resolvedTokens: [:], internalRoutes: [], assetRoot: URL(fileURLWithPath: "/tmp")) }

    @Test("flags an image block with a src prop but no alt prop at all")
    func flagsMissingAlt() throws {
        let image = BlockNode(id: "img1", kind: .astro, componentName: "Image", props: ["src": .string("/photo.jpg")], slots: [:], sourceSpan: [0, 0])
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: ["img1"], blocks: ["img1": image])

        let findings = try AltTextGate.analyze(model: model, context: emptyContext)

        #expect(findings.map(\.id) == ["img1::altText"])
    }

    @Test("does not flag an empty alt — intentionally decorative")
    func doesNotFlagEmptyAlt() throws {
        let image = BlockNode(id: "img1", kind: .astro, componentName: "Image", props: ["src": .string("/photo.jpg"), "alt": .string("")], slots: [:], sourceSpan: [0, 0])
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: ["img1"], blocks: ["img1": image])

        let findings = try AltTextGate.analyze(model: model, context: emptyContext)

        #expect(findings.isEmpty)
    }

    @Test("flags placeholder alt text like \"photo\"")
    func flagsPlaceholderAlt() throws {
        let image = BlockNode(id: "img1", kind: .astro, componentName: "Image", props: ["src": .string("/photo.jpg"), "alt": .string("Photo")], slots: [:], sourceSpan: [0, 0])
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: ["img1"], blocks: ["img1": image])

        let findings = try AltTextGate.analyze(model: model, context: emptyContext)

        #expect(findings.map(\.id) == ["img1::altText"])
    }

    @Test("does not flag a block with no src prop — not image-like")
    func ignoresNonImageBlocks() throws {
        let paragraph = BlockNode(id: "p1", kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0])
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: ["p1"], blocks: ["p1": paragraph])

        let findings = try AltTextGate.analyze(model: model, context: emptyContext)

        #expect(findings.isEmpty)
    }
}
