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

        #expect(findings.map(\.id) == ["\(rootParentID)::contrast::color-text-on-color-background"])
    }

    @Test("two failing pairs that share a foreground token get distinct finding ids")
    func distinctIdsForPairsSharingAForeground() throws {
        // color-text/color-background and color-text/color-surface both fail here; a
        // foreground-only discriminator collapsed them into one id and the engine's keyed diff
        // silently dropped the second.
        let context = GateContext(
            resolvedTokens: ["color-text": "#777777", "color-background": "#888888", "color-surface": "#8a8a8a"],
            internalRoutes: [], assetRoot: URL(fileURLWithPath: "/tmp"))
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: [], blocks: [:])

        let findings = try ContrastGate.analyze(model: model, context: context)

        #expect(findings.count == 2)
        #expect(Set(findings.map(\.id)).count == 2)
        #expect(findings.map(\.id).contains("\(rootParentID)::contrast::color-text-on-color-background"))
        #expect(findings.map(\.id).contains("\(rootParentID)::contrast::color-text-on-color-surface"))
    }

    @Test("a multi-word label is sentence-cased, not title-cased, in the owner-facing message")
    func labelIsSentenceCased() throws {
        let context = GateContext(
            resolvedTokens: ["color-primary": "#777777", "color-background": "#888888"],
            internalRoutes: [], assetRoot: URL(fileURLWithPath: "/tmp"))
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: [], blocks: [:])

        let findings = try ContrastGate.analyze(model: model, context: context)

        #expect(findings.first?.message.hasPrefix("Links and buttons is hard to read") == true)
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

    @Test("parseCSSCustomProperties keeps the first declaration, so a dark-scheme override never wins")
    func firstDeclarationWins() {
        // Mirrors Resources/Template/src/styles/global.css's shape: the light palette at the
        // top-level :root, then a complete dark override in a later @media block that the
        // design-apply flow never rewrites.
        let css = """
        :root {
          --color-text: #1e293b;
          --color-background: #ffffff;
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --color-text: #e2e8f0;
            --color-background: #0f172a;
          }
        }
        """

        let tokens = ContrastGate.parseCSSCustomProperties(from: css)

        #expect(tokens["color-text"] == "#1e293b")
        #expect(tokens["color-background"] == "#ffffff")
    }
}
