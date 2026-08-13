import Foundation
import Testing
@testable import AnglesiteCore

@Suite("ContrastGate")
struct ContrastGateTests {
    @Test("flags a token pair below the 4.5:1 AA ratio")
    func flagsLowContrastPair() throws {
        let context = GateContext(resolvedTokens: ["color-text": "#777777", "color-background": "#888888"], internalRoutes: [], assetRoot: URL(fileURLWithPath: "/tmp"))
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: [], blocks: [:])

        let findings = try ContrastGate.analyze(model: model, context: context)

        #expect(findings.map(\.id) == ["\(rootParentID)::contrast::color-text"])
    }

    @Test("does not flag a token pair that meets AA")
    func doesNotFlagGoodContrast() throws {
        let context = GateContext(resolvedTokens: ["color-text": "#000000", "color-background": "#ffffff"], internalRoutes: [], assetRoot: URL(fileURLWithPath: "/tmp"))
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: [], blocks: [:])

        let findings = try ContrastGate.analyze(model: model, context: context)

        #expect(findings.isEmpty)
    }

    @Test("skips a pair when either token is missing from resolvedTokens")
    func skipsMissingTokens() throws {
        let context = GateContext(resolvedTokens: [:], internalRoutes: [], assetRoot: URL(fileURLWithPath: "/tmp"))
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: [], blocks: [:])

        let findings = try ContrastGate.analyze(model: model, context: context)

        #expect(findings.isEmpty)
    }

    @Test("parseCSSCustomProperties extracts --name: value pairs from arbitrary CSS text")
    func parsesCustomProperties() {
        let css = """
        :root {
          --color-text: #222222;
          --color-background: #ffffff;
        }
        .unrelated { color: red; }
        """

        let tokens = ContrastGate.parseCSSCustomProperties(from: css)

        #expect(tokens["color-text"] == "#222222")
        #expect(tokens["color-background"] == "#ffffff")
        #expect(tokens.count == 2)
    }
}
