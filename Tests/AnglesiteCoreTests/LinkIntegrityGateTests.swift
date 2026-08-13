import Foundation
import Testing
@testable import AnglesiteCore

@Suite("LinkIntegrityGate")
struct LinkIntegrityGateTests {
    @Test("flags an internal href not present in internalRoutes")
    func flagsBrokenInternalLink() throws {
        let run = RichTextRun(kind: .link, text: "Read more", href: "/blog/missing")
        let paragraph = BlockNode(id: "p1", kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0], richText: [run])
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: ["p1"], blocks: ["p1": paragraph])
        let context = GateContext(resolvedTokens: [:], internalRoutes: ["/blog/hello-world"], assetRoot: URL(fileURLWithPath: "/tmp"))

        let findings = try LinkIntegrityGate.analyze(model: model, context: context)

        #expect(findings.map(\.id) == ["p1::linkIntegrity::richText.run.0"])
    }

    @Test("does not flag an internal href that resolves")
    func doesNotFlagResolvingLink() throws {
        let run = RichTextRun(kind: .link, text: "Read more", href: "/blog/hello-world")
        let paragraph = BlockNode(id: "p1", kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0], richText: [run])
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: ["p1"], blocks: ["p1": paragraph])
        let context = GateContext(resolvedTokens: [:], internalRoutes: ["/blog/hello-world"], assetRoot: URL(fileURLWithPath: "/tmp"))

        let findings = try LinkIntegrityGate.analyze(model: model, context: context)

        #expect(findings.isEmpty)
    }

    @Test("does not flag an external href — outside this gate's job")
    func doesNotFlagExternalLink() throws {
        let run = RichTextRun(kind: .link, text: "Anthropic", href: "https://anthropic.com")
        let paragraph = BlockNode(id: "p1", kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0], richText: [run])
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: ["p1"], blocks: ["p1": paragraph])
        let context = GateContext(resolvedTokens: [:], internalRoutes: [], assetRoot: URL(fileURLWithPath: "/tmp"))

        let findings = try LinkIntegrityGate.analyze(model: model, context: context)

        #expect(findings.isEmpty)
    }

    @Test("flags a broken href prop on an astro-kind link/button block")
    func flagsBrokenHrefProp() throws {
        let button = BlockNode(id: "btn1", kind: .astro, componentName: "Button", props: ["href": .string("/missing")], slots: [:], sourceSpan: [0, 0])
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: ["btn1"], blocks: ["btn1": button])
        let context = GateContext(resolvedTokens: [:], internalRoutes: [], assetRoot: URL(fileURLWithPath: "/tmp"))

        let findings = try LinkIntegrityGate.analyze(model: model, context: context)

        #expect(findings.map(\.id) == ["btn1::linkIntegrity::hrefProp"])
    }
}
