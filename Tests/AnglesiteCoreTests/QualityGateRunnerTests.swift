import Foundation
import Testing
@testable import AnglesiteCore

@Suite("QualityGateRunner")
struct QualityGateRunnerTests {
    @Test("aggregates findings from every checker that has something to report")
    func aggregatesFindings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 0, count: 600 * 1024).write(to: root.appendingPathComponent("photo.jpg"))

        let image = BlockNode(id: "img1", kind: .astro, componentName: "Image", props: ["src": .string("/photo.jpg")], slots: [:], sourceSpan: [0, 0])
        let h2 = BlockNode(id: "h2block", kind: .text, componentName: "h2", props: [:], slots: [:], sourceSpan: [0, 0])
        let h4 = BlockNode(id: "h4block", kind: .text, componentName: "h4", props: [:], slots: [:], sourceSpan: [0, 0])
        let brokenLink = BlockNode(id: "p1", kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0], richText: [RichTextRun(kind: .link, text: "here", href: "/missing")])
        let model = BlockModel(
            path: "src/pages/index.astro", version: "v1",
            rootIds: ["img1", "h2block", "h4block", "p1"],
            blocks: ["img1": image, "h2block": h2, "h4block": h4, "p1": brokenLink])
        let context = GateContext(resolvedTokens: ["color-text": "#777777", "color-background": "#888888"], internalRoutes: [], assetRoot: root)

        let result = QualityGateRunner.analyze(model: model, context: context)

        let categories = Set(result.findings.map(\.category))
        #expect(categories == [.contrast, .altText, .headingOrder, .linkIntegrity, .imageWeight])
        #expect(result.failedCategories.isEmpty)
    }
}
